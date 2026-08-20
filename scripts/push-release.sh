#!/bin/zsh

set -euo pipefail
setopt extendedglob

readonly SCRIPT_DIR="${0:A:h}"
readonly ROOT_DIR="${SCRIPT_DIR:h}"
readonly PROJECT_FILE="simStock3.xcodeproj/project.pbxproj"
readonly EXPORT_OPTIONS="release/ExportOptions.plist"
readonly MANIFEST_TEMPLATE="release/manifest.plist"
readonly BUNDLE_ID="com.peiyou.simStock3"
readonly RELEASE_TAG="latest"
readonly IPA_NAME="simStock3.ipa"
readonly MANIFEST_NAME="manifest.plist"
readonly DEFAULT_SIMULATOR_NAME="simStock3 iPad 10.2-inch"

MODE=""
COMMIT_MESSAGE=""
BUMP=""
REPLAY=""
PATHS=()

usage() {
    cat <<'EOF'
Usage:
  scripts/push-release.sh git-only --message MESSAGE [--path PATH ...]
  scripts/push-release.sh app --message MESSAGE --bump patch|minor|major|none \
      --replay none|simulation|technical|both [--path PATH ...]
  scripts/push-release.sh release-only --replay none|simulation|technical|both

Environment:
  SIMSTOCK_SIMULATOR_NAME  Simulator used for App tests.

Run this script with network and macOS Keychain access. It intentionally does
not start an interactive GitHub or Apple login flow.
EOF
}

fail() {
    print -u2 -- "ERROR: $*"
    exit 1
}

step() {
    print -- "\n==> $*"
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "Required tool not found: $1"
}

single_build_setting() {
    local key="$1"
    local values
    values=$(sed -n "s/.*${key} = \([^;]*\);/\1/p" "$PROJECT_FILE" | sort -u)
    [[ -n "$values" ]] || fail "Cannot find ${key} in ${PROJECT_FILE}"
    [[ "$values" != *$'\n'* ]] || fail "${key} has inconsistent values: ${values}"
    print -- "$values"
}

stage_requested_paths() {
    if (( ${#PATHS[@]} > 0 )); then
        git add -- "${PATHS[@]}"
    fi
}

require_intentional_index() {
    local unstaged untracked staged
    unstaged=$(git diff --name-only)
    untracked=$(git ls-files --others --exclude-standard)
    staged=$(git diff --cached --name-only)

    [[ -z "$unstaged" ]] || fail "Unstaged files remain:\n${unstaged}"
    [[ -z "$untracked" ]] || fail "Untracked files remain:\n${untracked}"
    [[ -n "$staged" ]] || fail "No staged changes. Pass --path for every intended file."
    git diff --cached --check
}

require_clean_worktree() {
    [[ -z "$(git status --porcelain)" ]] || fail "release-only requires a clean worktree"
}

verify_github_auth() {
    step "Checking GitHub API authentication"
    if ! gh api user --jq .login; then
        fail "GitHub API authentication failed. Rerun with network/Keychain access before considering gh auth login."
    fi
}

verify_apple_signing() {
    step "Checking Apple Distribution identity"
    local identities
    identities=$(security find-identity -v -p codesigning)
    print -- "$identities"
    print -- "$identities" | grep -q 'Apple Distribution:' || \
        fail "No valid Apple Distribution identity. Rerun with Keychain access before changing certificates."
}

fetch_and_require_safe_remote() {
    step "Fetching origin and checking divergence"
    git fetch origin

    local remote_only local_only
    read remote_only local_only <<< "$(git rev-list --left-right --count origin/main...HEAD)"
    print -- "remote-only=${remote_only} local-only=${local_only}"
    (( remote_only == 0 )) || fail "origin/main has new commits. Integrate them before publishing."
}

verify_remote_head() {
    local local_head remote_head
    local_head=$(git rev-parse HEAD)
    remote_head=$(git ls-remote origin refs/heads/main | awk '{print $1}')
    [[ "$local_head" == "$remote_head" ]] || fail "Remote main does not match local HEAD"
    print -- "Remote main: ${remote_head}"
}

bump_project_version() {
    [[ "$BUMP" != "none" ]] || return 0

    local current_version current_build major minor patch new_version new_build
    current_version=$(single_build_setting MARKETING_VERSION)
    current_build=$(single_build_setting CURRENT_PROJECT_VERSION)
    IFS=. read -r major minor patch <<< "$current_version"
    [[ "$major" == <-> && "$minor" == <-> && "$patch" == <-> ]] || \
        fail "MARKETING_VERSION is not semantic: ${current_version}"
    [[ "$current_build" == <-> ]] || fail "CURRENT_PROJECT_VERSION is not numeric: ${current_build}"

    case "$BUMP" in
        patch) (( patch += 1 )) ;;
        minor) (( minor += 1 )); patch=0 ;;
        major) (( major += 1 )); minor=0; patch=0 ;;
        *) fail "Unsupported bump: ${BUMP}" ;;
    esac

    new_version="${major}.${minor}.${patch}"
    new_build=$(( current_build + 1 ))
    sed -i '' \
        -e "s/MARKETING_VERSION = ${current_version};/MARKETING_VERSION = ${new_version};/g" \
        -e "s/CURRENT_PROJECT_VERSION = ${current_build};/CURRENT_PROJECT_VERSION = ${new_build};/g" \
        "$PROJECT_FILE"
    git add -- "$PROJECT_FILE"
    print -- "Version: ${current_version} (${current_build}) -> ${new_version} (${new_build})"
}

resolve_simulator_udid() {
    local simulator_name="$1"
    local line udid
    line=$(xcrun simctl list devices available | grep -F "${simulator_name} (" | head -1 || true)
    [[ -n "$line" ]] || fail "Simulator not found: ${simulator_name}"
    udid=$(print -- "$line" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
    [[ "$udid" == [0-9A-F-]## ]] || fail "Cannot parse Simulator UDID from: ${line}"
    print -- "$udid"
}

run_app_tests() {
    local simulator_name="${SIMSTOCK_SIMULATOR_NAME:-$DEFAULT_SIMULATOR_NAME}"
    local simulator_udid
    simulator_udid=$(resolve_simulator_udid "$simulator_name")

    step "Booting ${simulator_name}"
    xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$simulator_udid" -b

    step "Running release tests"
    xcodebuild test \
        -project simStock3.xcodeproj \
        -scheme simStock3 \
        -destination "platform=iOS Simulator,id=${simulator_udid}" \
        -only-testing:simStock3Tests/StrategyFitTests \
        -only-testing:simStock3Tests/RecalculationTests
}

prepare_workspace() {
    local work_dir
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/simStock3-release.XXXXXX")
    mkdir -p "$work_dir/latest" "$work_dir/export" "$work_dir/inspect"
    print -- "$work_dir"
}

latest_release_build() {
    local work_dir="$1"
    gh release download "$RELEASE_TAG" \
        --pattern "$MANIFEST_NAME" \
        --dir "$work_dir/latest" \
        --clobber
    /usr/libexec/PlistBuddy \
        -c 'Print :items:0:metadata:bundle-version' \
        "$work_dir/latest/$MANIFEST_NAME"
}

archive_and_export() {
    local work_dir="$1"
    step "Archiving signed App"
    xcodebuild archive \
        -project simStock3.xcodeproj \
        -scheme simStock3 \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$work_dir/simStock3.xcarchive" \
        -allowProvisioningUpdates

    step "Exporting IPA"
    xcodebuild -exportArchive \
        -archivePath "$work_dir/simStock3.xcarchive" \
        -exportPath "$work_dir/export" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -allowProvisioningUpdates
}

verify_and_prepare_assets() {
    local work_dir="$1"
    local version="$2"
    local build="$3"
    local ipa_path="$work_dir/export/$IPA_NAME"
    local app_path="$work_dir/inspect/Payload/simStock3.app"
    local info_plist="$app_path/Info.plist"
    local actual_bundle actual_version actual_build

    [[ -f "$ipa_path" ]] || fail "IPA not found: ${ipa_path}"
    ditto -x -k "$ipa_path" "$work_dir/inspect"
    [[ -f "$info_plist" ]] || fail "Exported App not found in IPA"

    actual_bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
    actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
    actual_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")
    [[ "$actual_bundle" == "$BUNDLE_ID" ]] || fail "Unexpected bundle identifier: ${actual_bundle}"
    [[ "$actual_version" == "$version" ]] || fail "Unexpected App version: ${actual_version}"
    [[ "$actual_build" == "$build" ]] || fail "Unexpected App build: ${actual_build}"

    step "Verifying IPA signature"
    codesign --verify --deep --strict --verbose=4 "$app_path"

    cp "$MANIFEST_TEMPLATE" "$work_dir/$MANIFEST_NAME"
    /usr/libexec/PlistBuddy \
        -c "Set :items:0:metadata:bundle-version ${build}" \
        "$work_dir/$MANIFEST_NAME"
    plutil -lint "$work_dir/$MANIFEST_NAME"

    step "Local release hashes"
    shasum -a 256 "$ipa_path" "$work_dir/$MANIFEST_NAME"
}

upload_and_verify_release() {
    local work_dir="$1"
    local ipa_path="$work_dir/export/$IPA_NAME"
    local manifest_path="$work_dir/$MANIFEST_NAME"
    local local_ipa local_manifest remote_ipa remote_manifest

    step "Uploading GitHub latest assets"
    gh release upload "$RELEASE_TAG" "$ipa_path" "$manifest_path" --clobber

    local_ipa=$(shasum -a 256 "$ipa_path" | awk '{print $1}')
    local_manifest=$(shasum -a 256 "$manifest_path" | awk '{print $1}')
    remote_ipa=$(gh release view "$RELEASE_TAG" --json assets \
        --jq ".assets[] | select(.name==\"${IPA_NAME}\") | .digest")
    remote_manifest=$(gh release view "$RELEASE_TAG" --json assets \
        --jq ".assets[] | select(.name==\"${MANIFEST_NAME}\") | .digest")
    [[ "$remote_ipa" == "sha256:${local_ipa}" ]] || fail "Remote IPA digest mismatch"
    [[ "$remote_manifest" == "sha256:${local_manifest}" ]] || fail "Remote manifest digest mismatch"
    print -- "Remote IPA: ${remote_ipa}"
    print -- "Remote manifest: ${remote_manifest}"
}

report_versions() {
    local version="$1"
    local build="$2"
    local technical simulation
    technical=$(sed -n 's/.*currentTechnicalStateVersion[^0-9]*\([0-9][0-9]*\).*/\1/p' simStock3/technical.swift | head -1)
    simulation=$(sed -n 's/.*currentSimulationStateVersion[^0-9]*\([0-9][0-9]*\).*/\1/p' simStock3/technical.swift | head -1)
    print -- "App: v${version} (${build})"
    print -- "Data rules: T${technical:-?}/S${simulation:-?}"
    print -- "Replay declaration: ${REPLAY}"
    print -- "Manual reversals/additions: verify preservation whenever replay is not none"
}

run_git_only() {
    [[ -n "$COMMIT_MESSAGE" ]] || fail "git-only requires --message"
    [[ -z "$BUMP" && -z "$REPLAY" ]] || fail "git-only does not accept --bump or --replay"

    stage_requested_paths
    require_intentional_index
    verify_github_auth
    fetch_and_require_safe_remote

    step "Committing Git-only changes"
    git commit -m "$COMMIT_MESSAGE"
    [[ -z "$(git status --porcelain)" ]] || fail "Commit left unexpected worktree changes"
    git push origin main
    verify_remote_head
}

run_app_release() {
    [[ -n "$COMMIT_MESSAGE" ]] || fail "app requires --message"
    [[ "$BUMP" == (patch|minor|major|none) ]] || fail "app requires --bump patch|minor|major|none"
    [[ "$REPLAY" == (none|simulation|technical|both) ]] || \
        fail "app requires --replay none|simulation|technical|both"

    stage_requested_paths
    bump_project_version
    require_intentional_index
    verify_github_auth
    verify_apple_signing
    fetch_and_require_safe_remote

    local work_dir version build previous_build
    work_dir=$(prepare_workspace)
    version=$(single_build_setting MARKETING_VERSION)
    build=$(single_build_setting CURRENT_PROJECT_VERSION)
    previous_build=$(latest_release_build "$work_dir")
    [[ "$build" == <-> && "$previous_build" == <-> ]] || fail "Build numbers must be numeric"
    (( build > previous_build )) || fail "Build ${build} must exceed latest build ${previous_build}"

    run_app_tests
    archive_and_export "$work_dir"
    verify_and_prepare_assets "$work_dir" "$version" "$build"

    step "Committing validated App release"
    git commit -m "$COMMIT_MESSAGE"
    [[ -z "$(git status --porcelain)" ]] || fail "Commit left unexpected worktree changes"
    git push origin main
    verify_remote_head
    upload_and_verify_release "$work_dir"
    report_versions "$version" "$build"
}

run_release_only() {
    [[ -z "$COMMIT_MESSAGE" && -z "$BUMP" && ${#PATHS[@]} -eq 0 ]] || \
        fail "release-only does not accept --message, --bump, or --path"
    [[ "$REPLAY" == (none|simulation|technical|both) ]] || \
        fail "release-only requires --replay none|simulation|technical|both"

    require_clean_worktree
    verify_github_auth
    verify_apple_signing
    fetch_and_require_safe_remote
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || \
        fail "release-only requires local HEAD to match origin/main"

    local work_dir version build previous_build
    work_dir=$(prepare_workspace)
    version=$(single_build_setting MARKETING_VERSION)
    build=$(single_build_setting CURRENT_PROJECT_VERSION)
    previous_build=$(latest_release_build "$work_dir")
    [[ "$build" == <-> && "$previous_build" == <-> ]] || fail "Build numbers must be numeric"
    (( build >= previous_build )) || fail "Local build ${build} is older than latest build ${previous_build}"

    run_app_tests
    archive_and_export "$work_dir"
    verify_and_prepare_assets "$work_dir" "$version" "$build"
    upload_and_verify_release "$work_dir"
    verify_remote_head
    report_versions "$version" "$build"
}

main() {
    cd "$ROOT_DIR"
    require_tool git
    require_tool gh
    require_tool xcodebuild
    require_tool xcrun
    require_tool codesign
    require_tool plutil

    MODE="${1:-}"
    [[ -n "$MODE" ]] || { usage; exit 2; }
    shift

    while (( $# > 0 )); do
        case "$1" in
            --message)
                (( $# >= 2 )) || fail "--message requires a value"
                COMMIT_MESSAGE="$2"
                shift 2
                ;;
            --bump)
                (( $# >= 2 )) || fail "--bump requires a value"
                BUMP="$2"
                shift 2
                ;;
            --replay)
                (( $# >= 2 )) || fail "--replay requires a value"
                REPLAY="$2"
                shift 2
                ;;
            --path)
                (( $# >= 2 )) || fail "--path requires a value"
                PATHS+=("$2")
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "Unknown argument: $1"
                ;;
        esac
    done

    [[ "$(git branch --show-current)" == "main" ]] || fail "Publishing is restricted to main"
    [[ "$(git remote get-url origin)" == "https://github.com/peiyu66/simStock3.git" ]] || \
        fail "Unexpected origin remote"

    case "$MODE" in
        git-only) run_git_only ;;
        app) run_app_release ;;
        release-only) run_release_only ;;
        *) usage; fail "Unknown mode: ${MODE}" ;;
    esac
}

main "$@"
