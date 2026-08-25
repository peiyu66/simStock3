#!/bin/zsh

set -euo pipefail
setopt extendedglob

readonly SCRIPT_DIR="${0:A:h}"
readonly ROOT_DIR="${SCRIPT_DIR:h}"
readonly DEFAULT_SIMULATOR_NAME="iPad Pro 13-inch (M5)"
readonly DEFAULT_TIMEOUT_SECONDS=1800

CANDIDATE_ID=""
CANDIDATE_FLAG=""
SAMPLE=""
RULE_COMMIT=""
SIMULATOR_NAME="${SIMSTOCK_CANDIDATE_SIMULATOR_NAME:-$DEFAULT_SIMULATOR_NAME}"
TIMEOUT_SECONDS="${SIMSTOCK_CANDIDATE_TIMEOUT_SECONDS:-$DEFAULT_TIMEOUT_SECONDS}"
REPLACE_OUTPUT=0

usage() {
    cat <<'EOF'
Usage:
  scripts/run-candidate-backtest.sh \
      --candidate-id CANDIDATE_ID \
      --candidate-flag --candidate-FLAG \
      --sample A|B|C|D \
      --rule-commit FORMAL_RULE_COMMIT \
      [--simulator-name NAME] [--timeout-seconds N] [--replace-output]

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

Environment:
  SIMSTOCK_CANDIDATE_SIMULATOR_NAME   Default Simulator name.
  SIMSTOCK_CANDIDATE_TIMEOUT_SECONDS Completion timeout; default 1800.
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

resolve_simulator_udid() {
    local line udid
    line=$(xcrun simctl list devices available | grep -F "${SIMULATOR_NAME} (" | head -1 || true)
    [[ -n "$line" ]] || fail "Simulator not found: ${SIMULATOR_NAME}"
    udid=$(print -- "$line" | grep -Eo '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1 || true)
    [[ -n "$udid" ]] || fail "Cannot parse Simulator UDID from: ${line}"
    print -- "$udid"
}

json_raw() {
    local path="$1"
    local key="$2"
    plutil -extract "$key" raw -o - "$path"
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
[[ "$SAMPLE" == [ABCD] ]] || fail "--sample must be A, B, C, or D"
[[ -n "$RULE_COMMIT" ]] || fail "--rule-commit is required"
[[ "$TIMEOUT_SECONDS" == <1-> ]] || fail "--timeout-seconds must be a positive integer"

cd "$ROOT_DIR"
require_tool xcodebuild
require_tool xcrun
require_tool plutil
require_tool ditto
require_tool python3

RULE_COMMIT=$(git rev-parse --verify "${RULE_COMMIT}^{commit}" 2>/dev/null) || \
    fail "Formal rule commit does not exist: ${RULE_COMMIT}"

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
readonly DATA_CONTAINER=$(xcrun simctl get_app_container "$SIMULATOR_UDID" "$BUNDLE_ID" data)
[[ -d "$DATA_CONTAINER" ]] || fail "Cannot locate installed App data container"

touch "$MARKER_PATH"
typeset -a launch_arguments
launch_arguments=(
    --run-internal-backtest-report
    --nine-year-ab-baseline
    "--sample-${SAMPLE:l}"
    "$CANDIDATE_FLAG"
    --summary-only
    --record-decision-delta
    --rule-commit
    "$RULE_COMMIT"
)

step "Launching ${CANDIDATE_ID} Sample ${SAMPLE} fixed-three-year replay"
xcrun simctl launch "$SIMULATOR_UDID" "$BUNDLE_ID" "${launch_arguments[@]}"

readonly DELTA_ROOT="${DATA_CONTAINER}/Documents/InternalBacktest/DecisionDeltas"
deadline=$(( EPOCHSECONDS + TIMEOUT_SECONDS ))
delta_complete=""

step "Waiting for DecisionDelta completion (timeout ${TIMEOUT_SECONDS}s)"
while (( EPOCHSECONDS < deadline )); do
    if [[ -d "$DELTA_ROOT" ]]; then
        while IFS= read -r complete_path; do
            [[ -n "$complete_path" ]] || continue
            summary_path="${complete_path:h}/decision-summary.json"
            [[ -f "$summary_path" ]] || continue
            actual_candidate=$(json_raw "$summary_path" candidateID 2>/dev/null || true)
            actual_sample=$(json_raw "$summary_path" sampleID 2>/dev/null || true)
            if [[ "$actual_candidate" == "$CANDIDATE_ID" && "$actual_sample" == "$SAMPLE" ]]; then
                delta_complete="$complete_path"
                break
            fi
        done < <(find "$DELTA_ROOT" -type f -path "*/${CANDIDATE_ID}/.complete" -newer "$MARKER_PATH" -print 2>/dev/null)
    fi
    [[ -n "$delta_complete" ]] && break
    sleep 2
done

if [[ -z "$delta_complete" ]]; then
    print -u2 -- "Recent candidate artifacts:"
    find "${DATA_CONTAINER}/Documents/InternalBacktest" -type f -newer "$MARKER_PATH" -print 2>/dev/null | tail -60 >&2 || true
    fail "Candidate did not produce a matching completion marker within ${TIMEOUT_SECONDS}s. The Simulator remains booted for diagnosis."
fi

readonly SOURCE_DELTA_DIR="${delta_complete:h}"
readonly DECISION_SUMMARY="${SOURCE_DELTA_DIR}/decision-summary.json"
readonly RUN_ID=$(json_raw "$DECISION_SUMMARY" candidateRunID)
readonly DECISION_BASE_ID=$(json_raw "$DECISION_SUMMARY" baselineDecisionBaseID)
readonly SOURCE_RUN_DIR="${DATA_CONTAINER}/Documents/InternalBacktest/Runs/${RUN_ID}"

[[ "$RUN_ID" == *fixed3y* ]] || fail "Run ID does not identify the fixed-three-year profile: ${RUN_ID}"
for required in baseline.json manifest.json periods.csv; do
    [[ -f "${SOURCE_RUN_DIR}/${required}" ]] || fail "Candidate run is incomplete; missing ${required}"
done

actual_run_id=$(json_raw "${SOURCE_RUN_DIR}/manifest.json" runID)
actual_sample=$(json_raw "${SOURCE_RUN_DIR}/manifest.json" sampleID)
[[ "$actual_run_id" == "$RUN_ID" ]] || fail "Manifest run ID mismatch: ${actual_run_id} != ${RUN_ID}"
[[ "$actual_sample" == "$SAMPLE" ]] || fail "Manifest sample mismatch: ${actual_sample} != ${SAMPLE}"

readonly DEST_RUN_DIR="${ROOT_DIR}/exports/backtest-candidate-runs/${RUN_ID}"
readonly DEST_DELTA_DIR="${ROOT_DIR}/exports/backtest-decision-deltas/${DECISION_BASE_ID}/${CANDIDATE_ID}"
prepare_destination "$DEST_RUN_DIR" "$STAMP"
prepare_destination "$DEST_DELTA_DIR" "$STAMP"

step "Copying structured candidate artifacts"
ditto "$SOURCE_RUN_DIR" "$DEST_RUN_DIR"
ditto "$SOURCE_DELTA_DIR" "$DEST_DELTA_DIR"

step "Validating outputs and writing compact summary"
python3 tools/candidate_backtest_summary.py \
    --run-dir "$DEST_RUN_DIR" \
    --delta-dir "$DEST_DELTA_DIR" \
    --expected-candidate-id "$CANDIDATE_ID" \
    --expected-sample "$SAMPLE" \
    --output "${DEST_RUN_DIR}/run-summary.md"

step "Candidate run complete"
print -- "Run: ${RUN_ID}"
print -- "DecisionBase: ${DECISION_BASE_ID}"
print -- "Run artifacts: ${DEST_RUN_DIR}"
print -- "DecisionDelta: ${DEST_DELTA_DIR}"
print -- "Build log: ${BUILD_LOG}"
print -- "Simulator remains booted: ${SIMULATOR_NAME}"
