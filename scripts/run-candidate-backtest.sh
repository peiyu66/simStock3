#!/bin/zsh

set -euo pipefail
setopt extendedglob
unsetopt BG_NICE

readonly SCRIPT_DIR="${0:A:h}"
readonly ROOT_DIR="${SCRIPT_DIR:h}"
readonly DEFAULT_SIMULATOR_NAME="iPad Pro 13-inch (M5)"
readonly DEFAULT_TIMEOUT_SECONDS=1800
readonly DEFAULT_SIMCTL_TIMEOUT_SECONDS=120

CANDIDATE_ID=""
CANDIDATE_FLAG=""
SAMPLE=""
RULE_COMMIT=""
SIMULATOR_NAME="${SIMSTOCK_CANDIDATE_SIMULATOR_NAME:-$DEFAULT_SIMULATOR_NAME}"
TIMEOUT_SECONDS="${SIMSTOCK_CANDIDATE_TIMEOUT_SECONDS:-$DEFAULT_TIMEOUT_SECONDS}"
SIMCTL_TIMEOUT_SECONDS="${SIMSTOCK_CANDIDATE_SIMCTL_TIMEOUT_SECONDS:-$DEFAULT_SIMCTL_TIMEOUT_SECONDS}"
REPLACE_OUTPUT=0
CONTROL_MODE=0

usage() {
    cat <<'EOF'
Usage:
  scripts/run-candidate-backtest.sh \
      --candidate-id CANDIDATE_ID \
      --candidate-flag --candidate-FLAG \
      --sample A|B|C|D|E \
      --rule-commit FORMAL_RULE_COMMIT \
      [--control] [--simulator-name NAME] [--timeout-seconds N] [--replace-output]

Example:
  scripts/run-candidate-backtest.sh \
      --candidate-id nr2A2 \
      --candidate-flag --candidate-nr2-a2 \
      --sample A \
      --rule-commit 73003cf8f39cbf3a673792957324f508261bd731

This command builds and installs the Debug App, runs exactly one authorized
fixed-three-year candidate sample with DecisionDelta, waits for completion,
copies structured artifacts into exports, validates them, and writes a compact
run-summary.md. It never starts another sample, commits, pushes, or adopts a rule.
Use --control with candidate ID p3-z-baseline-control for a Baseline zero-difference replay.

Environment:
  SIMSTOCK_CANDIDATE_SIMULATOR_NAME   Default Simulator name.
  SIMSTOCK_CANDIDATE_TIMEOUT_SECONDS Completion timeout; default 1800.
  SIMSTOCK_CANDIDATE_SIMCTL_TIMEOUT_SECONDS  get_app_container/launch timeout; default 120.
  SIMSTOCK_CANDIDATE_DERIVED_DATA    Reusable DerivedData path.
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

require_value() {
    (( $# >= 2 )) || fail "Missing value after $1"
}

run_with_timeout() {
    local timeout_seconds="$1"
    shift
    local command_pid command_status deadline
    "$@" &
    command_pid=$!
    deadline=$(( $(date +%s) + timeout_seconds ))
    while kill -0 "$command_pid" >/dev/null 2>&1; do
        if (( $(date +%s) >= deadline )); then
            kill "$command_pid" >/dev/null 2>&1 || true
            wait "$command_pid" >/dev/null 2>&1 || true
            print -u2 -- "Command timed out after ${timeout_seconds}s: $*"
            return 124
        fi
        sleep 1
    done
    if wait "$command_pid"; then
        return 0
    fi
    command_status=$?
    return "$command_status"
}

resolve_simulator_udid() {
    local line udid
    line=$(xcrun simctl list devices available | grep -F "${SIMULATOR_NAME} (" | head -1 || true)
    [[ -n "$line" ]] || fail "Simulator not found: ${SIMULATOR_NAME}"
    udid=$(print -- "$line" | grep -Eo '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1 || true)
    [[ -n "$udid" ]] || fail "Cannot parse Simulator UDID from: ${line}"
    print -- "$udid"
}

json_raw() {
    local json_path="$1"
    local key="$2"
    plutil -extract "$key" raw -o - "$json_path"
}

prepare_destination() {
    local destination="$1"
    local stamp="$2"
    if [[ -e "$destination" ]]; then
        (( REPLACE_OUTPUT == 1 )) || fail \
            "Output already exists: ${destination}. Use --replace-output for an intentional rerun."
        mv "$destination" "${destination}.replaced-${stamp}"
    fi
    mkdir -p "${destination:h}"
}

resolve_decision_base_dir() {
    local manifest source_dir manifest_sample manifest_commit
    typeset -a matches
    matches=()
    for manifest in "${ROOT_DIR}"/exports/backtest-decision-bases/*/manifest.json(N); do
        manifest_sample=$(json_raw "$manifest" sampleID 2>/dev/null || true)
        manifest_commit=$(json_raw "$manifest" ruleCommit 2>/dev/null || true)
        [[ "$manifest_sample" == "$SAMPLE" && "$manifest_commit" == "$RULE_COMMIT" ]] || continue
        source_dir="${manifest:h}"
        [[ "${source_dir:t}" != *.summary-only-* ]] || continue
        [[ -f "${source_dir}/.complete" ]] || continue
        [[ -f "${source_dir}/.p4b-complete" ]] || continue
        [[ -f "${source_dir}/decisions.sqlite" ]] || continue
        matches+=("$source_dir")
    done
    if (( ${#matches} != 1 )); then
        print -u2 -- "ERROR: Expected exactly one complete Sample ${SAMPLE} DecisionBase for ${RULE_COMMIT}; found ${#matches}"
        return 1
    fi
    print -- "${matches[1]}"
}

while (( $# > 0 )); do
    case "$1" in
        --candidate-id)
            require_value "$@"
            CANDIDATE_ID="$2"
            shift 2
            ;;
        --candidate-flag)
            require_value "$@"
            CANDIDATE_FLAG="$2"
            shift 2
            ;;
        --sample)
            require_value "$@"
            SAMPLE="${2:u}"
            shift 2
            ;;
        --rule-commit)
            require_value "$@"
            RULE_COMMIT="$2"
            shift 2
            ;;
        --simulator-name)
            require_value "$@"
            SIMULATOR_NAME="$2"
            shift 2
            ;;
        --timeout-seconds)
            require_value "$@"
            TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --replace-output)
            REPLACE_OUTPUT=1
            shift
            ;;
        --control)
            CONTROL_MODE=1
            shift
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

[[ -n "$CANDIDATE_ID" ]] || fail "--candidate-id is required"
[[ "$CANDIDATE_ID" != *'/'* && "$CANDIDATE_ID" != *'..'* ]] || fail "Unsafe candidate ID"
[[ "$CANDIDATE_FLAG" == --candidate-* ]] || fail "--candidate-flag must begin with --candidate-"
[[ "$SAMPLE" == [ABCDE] ]] || fail "--sample must be A, B, C, D, or E"
[[ -n "$RULE_COMMIT" ]] || fail "--rule-commit is required"
[[ "$TIMEOUT_SECONDS" == <1-> ]] || fail "--timeout-seconds must be a positive integer"
[[ "$SIMCTL_TIMEOUT_SECONDS" == <1-> ]] || \
    fail "SIMSTOCK_CANDIDATE_SIMCTL_TIMEOUT_SECONDS must be a positive integer"
if (( CONTROL_MODE == 1 )); then
    [[ "$CANDIDATE_ID" == "p3-z-baseline-control" ]] || \
        fail "--control requires --candidate-id p3-z-baseline-control"
fi

readonly MARKET_VOTE_SNAPSHOT_DIR="${ROOT_DIR}/exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af"
readonly MARKET_VOTE_SNAPSHOT_FILE="${MARKET_VOTE_SNAPSHOT_DIR}/market-technical.csv"
readonly MARKET_VOTE_SNAPSHOT_SHA256="a00beac8d4af55668f977a4aca74b3e6c71e60bee6e456544a5a833d4ee95084"
typeset -i USES_MARKET_VOTE_SNAPSHOT=0
case "$CANDIDATE_FLAG" in
    --candidate-market-vote-never|--candidate-market-vote-pulse-h|--candidate-market-vote-pulse-l|--candidate-market-vote-pulse-s|--candidate-market-vote-pulse-a)
        USES_MARKET_VOTE_SNAPSHOT=1
        ;;
esac
if (( USES_MARKET_VOTE_SNAPSHOT == 1 )); then
    [[ -f "$MARKET_VOTE_SNAPSHOT_FILE" ]] || \
        fail "Missing frozen market vote snapshot: ${MARKET_VOTE_SNAPSHOT_FILE}"
    actual_market_sha=$(shasum -a 256 "$MARKET_VOTE_SNAPSHOT_FILE" | awk '{print $1}')
    [[ "$actual_market_sha" == "$MARKET_VOTE_SNAPSHOT_SHA256" ]] || \
        fail "Frozen market vote snapshot hash mismatch: ${actual_market_sha}"
fi

cd "$ROOT_DIR"
require_tool xcodebuild
require_tool xcrun
require_tool plutil
require_tool ditto
require_tool python3
require_tool sqlite3

RULE_COMMIT=$(git rev-parse --verify "${RULE_COMMIT}^{commit}" 2>/dev/null) || \
    fail "Formal rule commit does not exist: ${RULE_COMMIT}"

SOURCE_DECISION_BASE_DIR=$(resolve_decision_base_dir) || exit $?
readonly SOURCE_DECISION_BASE_DIR
readonly DECISION_BASE_ID="${SOURCE_DECISION_BASE_DIR:t}"
[[ "$(sqlite3 "${SOURCE_DECISION_BASE_DIR}/decisions.sqlite" 'PRAGMA integrity_check;')" == "ok" ]] || \
    fail "Source DecisionBase SQLite integrity failed: ${SOURCE_DECISION_BASE_DIR}"

readonly STAMP=$(date '+%Y%m%d-%H%M%S')
readonly WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/simStock3-candidate.XXXXXX")
readonly MARKER_PATH="${WORK_DIR}/launch.marker"
readonly DERIVED_DATA="${SIMSTOCK_CANDIDATE_DERIVED_DATA:-${TMPDIR:-/tmp}/simStock3-candidate-derived}"
readonly LOG_DIR="${ROOT_DIR}/exports/backtest-run-logs"
readonly BUILD_LOG="${LOG_DIR}/${STAMP}-${CANDIDATE_ID}-${SAMPLE:l}-build.log"
mkdir -p "$LOG_DIR"
trap 'rm -f "$MARKER_PATH"; rmdir "$WORK_DIR" >/dev/null 2>&1 || true' EXIT

readonly SIMULATOR_UDID=$(resolve_simulator_udid)

step "Booting ${SIMULATOR_NAME} (${SIMULATOR_UDID})"
xcrun simctl boot "$SIMULATOR_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b

step "Building Debug App"
if ! xcodebuild build \
    -project simStock3.xcodeproj \
    -scheme simStock3 \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" \
    -derivedDataPath "$DERIVED_DATA" >"$BUILD_LOG" 2>&1; then
    tail -80 "$BUILD_LOG" >&2
    fail "Build failed. Full log: ${BUILD_LOG}"
fi

readonly APP_PATH="${DERIVED_DATA}/Build/Products/Debug-iphonesimulator/simStock3.app"
readonly INFO_PLIST="${APP_PATH}/Info.plist"
[[ -f "$INFO_PLIST" ]] || fail "Built App not found: ${APP_PATH}"
readonly BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")
[[ -n "$BUNDLE_ID" ]] || fail "Built App has no bundle identifier"

step "Installing ${BUNDLE_ID} without deleting Simulator data"
xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
DATA_CONTAINER=$(run_with_timeout "$SIMCTL_TIMEOUT_SECONDS" \
    xcrun simctl get_app_container "$SIMULATOR_UDID" "$BUNDLE_ID" data) || \
    fail "Cannot query installed App data container within ${SIMCTL_TIMEOUT_SECONDS}s"
readonly DATA_CONTAINER
[[ -d "$DATA_CONTAINER" ]] || fail "Cannot locate installed App data container"
readonly FAILURE_MARKER="${DATA_CONTAINER}/Documents/InternalBacktest/.last-run-failure.txt"
rm -f "$FAILURE_MARKER"

if (( USES_MARKET_VOTE_SNAPSHOT == 1 )); then
    readonly MARKET_VOTE_TARGET_DIR="${DATA_CONTAINER}/Documents/InternalBacktest/Research/Market"
    readonly MARKET_VOTE_STAGING_DIR="${DATA_CONTAINER}/Documents/InternalBacktest/Research/.Market.staging-${STAMP}"
    step "Syncing frozen market vote snapshot"
    mkdir -p "${MARKET_VOTE_STAGING_DIR}"
    ditto "$MARKET_VOTE_SNAPSHOT_FILE" "${MARKET_VOTE_STAGING_DIR}/market-technical.csv"
    staged_market_sha=$(shasum -a 256 "${MARKET_VOTE_STAGING_DIR}/market-technical.csv" | awk '{print $1}')
    [[ "$staged_market_sha" == "$MARKET_VOTE_SNAPSHOT_SHA256" ]] || \
        fail "Staged market vote snapshot hash mismatch: ${staged_market_sha}"
    if [[ -e "$MARKET_VOTE_TARGET_DIR" ]]; then
        mv "$MARKET_VOTE_TARGET_DIR" "${MARKET_VOTE_TARGET_DIR}.replaced-${STAMP}"
    fi
    mv "$MARKET_VOTE_STAGING_DIR" "$MARKET_VOTE_TARGET_DIR"
fi

readonly DECISION_BASE_ROOT="${DATA_CONTAINER}/Documents/InternalBacktest/DecisionBases"
readonly TARGET_DECISION_BASE_DIR="${DECISION_BASE_ROOT}/${DECISION_BASE_ID}"
readonly STAGED_DECISION_BASE_DIR="${DECISION_BASE_ROOT}/.${DECISION_BASE_ID}.staging-${STAMP}"
step "Syncing verified Baseline DecisionBase ${DECISION_BASE_ID}"
mkdir -p "$DECISION_BASE_ROOT"
ditto "$SOURCE_DECISION_BASE_DIR" "$STAGED_DECISION_BASE_DIR"
[[ -f "${STAGED_DECISION_BASE_DIR}/.complete" ]] || fail "Staged DecisionBase lacks .complete"
[[ -f "${STAGED_DECISION_BASE_DIR}/.p4b-complete" ]] || fail "Staged DecisionBase lacks .p4b-complete"
[[ "$(sqlite3 "${STAGED_DECISION_BASE_DIR}/decisions.sqlite" 'PRAGMA integrity_check;')" == "ok" ]] || \
    fail "Staged DecisionBase SQLite integrity failed"
if [[ -e "$TARGET_DECISION_BASE_DIR" ]]; then
    mv "$TARGET_DECISION_BASE_DIR" "${TARGET_DECISION_BASE_DIR}.replaced-${STAMP}"
fi
mv "$STAGED_DECISION_BASE_DIR" "$TARGET_DECISION_BASE_DIR"

touch "$MARKER_PATH"
typeset -a launch_arguments
launch_arguments=(
    --run-internal-backtest-report
    --nine-year-ab-baseline
    "--sample-${SAMPLE:l}"
    "$CANDIDATE_FLAG"
    --summary-only
    --rule-commit
    "$RULE_COMMIT"
)
if (( CONTROL_MODE == 1 )); then
    launch_arguments+=(--record-decision-delta-control)
else
    launch_arguments+=(--record-decision-delta)
fi

step "Launching ${CANDIDATE_ID} Sample ${SAMPLE} fixed-three-year replay"
run_with_timeout "$SIMCTL_TIMEOUT_SECONDS" \
    xcrun simctl launch "$SIMULATOR_UDID" "$BUNDLE_ID" "${launch_arguments[@]}" || \
    fail "Simulator launch failed or exceeded ${SIMCTL_TIMEOUT_SECONDS}s; restart the device and rerun the same authorized candidate."

readonly DELTA_ROOT="${DATA_CONTAINER}/Documents/InternalBacktest/DecisionDeltas"
deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
delta_complete=""
DELTA_MATCHED_CANDIDATE_ID=""

step "Waiting for DecisionDelta completion (timeout ${TIMEOUT_SECONDS}s)"
while (( $(date +%s) < deadline )); do
    if [[ -s "$FAILURE_MARKER" ]]; then
        failure_message=$(<"$FAILURE_MARKER")
        fail "App reported backtest failure: ${failure_message}"
    fi
    if [[ -d "$DELTA_ROOT" ]]; then
        typeset -a sample_matches=()
        exact_match_path=""
        exact_match_candidate=""
        while IFS= read -r complete_path; do
            [[ -n "$complete_path" ]] || continue
            summary_path="${complete_path:h}/decision-summary.json"
            [[ -f "$summary_path" ]] || continue
            actual_candidate=$(json_raw "$summary_path" candidateID 2>/dev/null || true)
            actual_sample=$(json_raw "$summary_path" sampleID 2>/dev/null || true)
            [[ -n "$actual_candidate" && -n "$actual_sample" ]] || continue
            if [[ "$actual_sample" == "$SAMPLE" ]]; then
                is_zero_delta=$(json_raw "$summary_path" isZeroDecisionDelta 2>/dev/null || true)
                analysis_complete="${complete_path:h}/.analysis-complete"
                analysis_summary="${complete_path:h}/analysis-summary.json"
                if [[ "$is_zero_delta" == "true" ]] || \
                    [[ -f "$analysis_complete" && -f "$analysis_summary" ]]; then
                    if [[ "$actual_candidate" == "$CANDIDATE_ID" ]]; then
                        exact_match_path="$complete_path"
                        exact_match_candidate="$actual_candidate"
                        break
                    fi
                    sample_matches+=("${actual_candidate}|${complete_path}")
                fi
            fi
        done < <(find "$DELTA_ROOT" -type f -name ".complete" -newer "$MARKER_PATH" -print 2>/dev/null)
        if [[ -z "$exact_match_path" ]]; then
            if (( ${#sample_matches[@]} == 1 )); then
                exact_match_candidate="${sample_matches[1]%|*}"
                exact_match_path="${sample_matches[1]#*|}"
            elif (( ${#sample_matches[@]} > 1 )); then
                print -u2 -- "Recent same-sample completion markers:"
                print -u2 -- "${sample_matches[@]}"
                fail "Found multiple sample ${SAMPLE} candidate completions after launch; please rerun with the exact candidate folder id."
            fi
        fi
        if [[ -n "$exact_match_path" ]]; then
            matched_summary_path="${exact_match_path:h}/decision-summary.json"
            matched_run_id=$(json_raw "$matched_summary_path" candidateRunID 2>/dev/null || true)
            matched_run_complete="${DATA_CONTAINER}/Documents/InternalBacktest/Runs/${matched_run_id}/.complete"
            if [[ -n "$matched_run_id" && -f "$matched_run_complete" \
                && "$(<"$matched_run_complete")" == "$matched_run_id" ]]; then
                delta_complete="$exact_match_path"
                DELTA_MATCHED_CANDIDATE_ID="$exact_match_candidate"
                if [[ "$DELTA_MATCHED_CANDIDATE_ID" != "$CANDIDATE_ID" ]]; then
                    print -- "INFO: Requested candidate '${CANDIDATE_ID}' produced completion marker under candidate '${DELTA_MATCHED_CANDIDATE_ID}'."
                fi
                break
            fi
        fi
    fi
    simulator_state=$(xcrun simctl list devices available 2>/dev/null \
        | grep -F "(${SIMULATOR_UDID})" \
        | head -1 || true)
    if [[ "$simulator_state" != *"(Booted)"* ]]; then
        print -u2 -- "Simulator state while waiting: ${simulator_state:-unavailable}"
        print -u2 -- "Recent candidate artifacts:"
        find "${DATA_CONTAINER}/Documents/InternalBacktest" -type f -newer "$MARKER_PATH" -print 2>/dev/null \
            | tail -60 >&2 || true
        fail "Simulator stopped before the candidate produced a matching completion marker. Boot it and rerun the same authorized candidate."
    fi
    sleep 2
done

if [[ -z "$delta_complete" ]]; then
    print -u2 -- "Recent candidate artifacts:"
    find "${DATA_CONTAINER}/Documents/InternalBacktest" -type f -newer "$MARKER_PATH" -print 2>/dev/null | tail -60 >&2 || true
    fail "Candidate did not produce a matching completion marker within ${TIMEOUT_SECONDS}s. The Simulator remains booted for diagnosis."
fi

readonly SOURCE_DELTA_DIR="${delta_complete:h}"
readonly DECISION_SUMMARY="${SOURCE_DELTA_DIR}/decision-summary.json"
readonly SUMMARY_CANDIDATE_ID=$(json_raw "$DECISION_SUMMARY" candidateID)
readonly RUN_ID=$(json_raw "$DECISION_SUMMARY" candidateRunID)
readonly ACTUAL_DECISION_BASE_ID=$(json_raw "$DECISION_SUMMARY" baselineDecisionBaseID)
readonly SOURCE_RUN_DIR="${DATA_CONTAINER}/Documents/InternalBacktest/Runs/${RUN_ID}"

[[ "$ACTUAL_DECISION_BASE_ID" == "$DECISION_BASE_ID" ]] || \
    fail "DecisionBase mismatch: ${ACTUAL_DECISION_BASE_ID} != ${DECISION_BASE_ID}"

[[ "$RUN_ID" == *fixed3y* ]] || fail "Run ID does not identify the fixed-three-year profile: ${RUN_ID}"
for required in baseline.json manifest.json periods.csv .complete; do
    [[ -f "${SOURCE_RUN_DIR}/${required}" ]] || fail "Candidate run is incomplete; missing ${required}"
done

actual_run_id=$(json_raw "${SOURCE_RUN_DIR}/manifest.json" runID)
actual_sample=$(json_raw "${SOURCE_RUN_DIR}/manifest.json" sampleID)
[[ "$actual_run_id" == "$RUN_ID" ]] || fail "Manifest run ID mismatch: ${actual_run_id} != ${RUN_ID}"
[[ "$actual_sample" == "$SAMPLE" ]] || fail "Manifest sample mismatch: ${actual_sample} != ${SAMPLE}"
[[ "$(<"${SOURCE_RUN_DIR}/.complete")" == "$RUN_ID" ]] || \
    fail "Candidate run completion marker mismatch: ${SOURCE_RUN_DIR}/.complete"

readonly DEST_RUN_DIR="${ROOT_DIR}/exports/backtest-candidate-runs/${RUN_ID}"
readonly DEST_DELTA_DIR="${ROOT_DIR}/exports/backtest-decision-deltas/${ACTUAL_DECISION_BASE_ID}/${CANDIDATE_ID}"
prepare_destination "$DEST_RUN_DIR" "$STAMP"
prepare_destination "$DEST_DELTA_DIR" "$STAMP"

step "Copying structured candidate artifacts"
ditto "$SOURCE_RUN_DIR" "$DEST_RUN_DIR"
ditto "$SOURCE_DELTA_DIR" "$DEST_DELTA_DIR"

step "Validating outputs and writing compact summary"
python3 tools/candidate_backtest_summary.py \
    --run-dir "$DEST_RUN_DIR" \
    --delta-dir "$DEST_DELTA_DIR" \
    --expected-candidate-id "$SUMMARY_CANDIDATE_ID" \
    --expected-sample "$SAMPLE" \
    --output "${DEST_RUN_DIR}/run-summary.md"

step "Candidate run complete"
print -- "Run: ${RUN_ID}"
print -- "DecisionBase: ${ACTUAL_DECISION_BASE_ID}"
print -- "Run artifacts: ${DEST_RUN_DIR}"
print -- "DecisionDelta: ${DEST_DELTA_DIR}"
print -- "Build log: ${BUILD_LOG}"
print -- "Simulator remains booted: ${SIMULATOR_NAME}"
