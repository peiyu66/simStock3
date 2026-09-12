#!/bin/zsh

set -euo pipefail
setopt extendedglob
unsetopt BG_NICE

readonly SCRIPT_DIR="${0:A:h}"
readonly ROOT_DIR="${SCRIPT_DIR:h}"
readonly SIMULATOR_NAME="${SIMSTOCK_BASELINE_SIMULATOR_NAME:-iPad Pro 13-inch (M5)}"
readonly RULE_COMMIT="${SIMSTOCK_BASELINE_RULE_COMMIT:?Set the exact validated formal rule commit}"
readonly TIMEOUT_SECONDS="${SIMSTOCK_BASELINE_TIMEOUT_SECONDS:-1800}"
readonly DERIVED_DATA="${SIMSTOCK_BASELINE_DERIVED_DATA:-${TMPDIR:-/tmp}/simStock3-formal-late-rebound-baseline-v32-derived}"
readonly BUNDLE_ID="com.peiyou.simStock3"
readonly RULE_VERSION="s44-lp12-late-rebound-20260912"
readonly MARKET_PRICE_PATH_SOURCE="${ROOT_DIR}/exports/market-data/taiex/research/mkt-pp-p1-taiex-price-path-f712b360c322/market-price-path.csv"
readonly MARKET_DAILY_SOURCE="${ROOT_DIR}/exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af/market-daily.csv"
readonly MARKET_DAILY_SHA256="558883f85355b49c1c4402b4346d9a4939411bea69d405275c2b42aa55bb8da4"
readonly MARKET_EXTREMA_SOURCE="${ROOT_DIR}/exports/market-data/taiex/research/mkt-index-extrema9-v2-20260722-6d5519a63bba/market-index-extrema9.csv"
readonly MARKET_EXTREMA_SHA256="6d5519a63bba5dfabab243d7ce35d37a8a8c007ecd0b0ac3703b2fa14922861e"
readonly MARKET_PRICE_PATH_SHA256="f9e1f41c8ba74dd94b970460a148983d7763b108985be55b11cfba64fc03d17f"

fail() {
    print -u2 -- "ERROR: $*"
    exit 1
}

step() {
    print -- "\n==> $*"
}

observe_progress() {
    local fingerprint now
    fingerprint=$(find "$run_dir" "${INTERNAL_ROOT}/DecisionBases/${decision_base_id}" -type f -exec stat -f '%m %z %N' {} \; 2>/dev/null | sort | shasum -a 256 || true)
    now=$(date +%s)
    if [[ "$fingerprint" != "$last_fingerprint" ]]; then
        last_fingerprint="$fingerprint"
        last_progress="$now"
    elif (( now - last_progress > 180 )); then
        if [[ -n "${pending_launch_pid:-}" ]]; then
            kill -TERM "$pending_launch_pid" >/dev/null 2>&1 || true
        fi
        xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
        fail "No output changes for 180 seconds; stopped and preserved ${run_dir} and DecisionBase for diagnosis"
    fi
}

# Observe output while simctl is still waiting for the app launch handshake.
# A returned PID alone is not evidence that the requested run has started.
launch_observed() {
    xcrun simctl launch "$@" >/dev/null &
    pending_launch_pid=$!
    last_fingerprint=""
    last_progress=$(date +%s)
    while kill -0 "$pending_launch_pid" >/dev/null 2>&1; do
        observe_progress
        sleep 2
    done
    wait "$pending_launch_pid" || fail "Simulator launch failed; preserve the run for diagnosis"
    pending_launch_pid=""
}

json_raw() {
    plutil -extract "$2" raw -o - "$1"
}

[[ -f "$MARKET_PRICE_PATH_SOURCE" ]] || fail "Missing frozen market price path: ${MARKET_PRICE_PATH_SOURCE}"
actual_market_sha=$(shasum -a 256 "$MARKET_PRICE_PATH_SOURCE" | awk '{print $1}')
[[ "$actual_market_sha" == "$MARKET_PRICE_PATH_SHA256" ]] || \
    fail "Frozen market price-path hash mismatch: ${actual_market_sha}"

[[ "$(shasum -a 256 "$MARKET_DAILY_SOURCE" | awk '{print $1}')" == "$MARKET_DAILY_SHA256" ]] || fail "Frozen daily OHLC hash mismatch"
[[ "$(shasum -a 256 "$MARKET_EXTREMA_SOURCE" | awk '{print $1}')" == "$MARKET_EXTREMA_SHA256" ]] || fail "Frozen extrema hash mismatch"

simulator_line=$(xcrun simctl list devices available | grep -F "${SIMULATOR_NAME} (" | head -1 || true)
[[ -n "$simulator_line" ]] || fail "Simulator not found: ${SIMULATOR_NAME}"
simulator_udid=$(print -- "$simulator_line" | grep -Eo '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1 || true)
[[ -n "$simulator_udid" ]] || fail "Cannot parse Simulator UDID: ${simulator_line}"
readonly SIMULATOR_UDID="$simulator_udid"
[[ "$SIMULATOR_UDID" == "FE32BA9E-178D-4D6D-B0E0-8ACCD6E7856E" ]] || fail "Use the agreed 13-inch research device"

resolved_rule_commit=$(git -C "$ROOT_DIR" rev-parse --verify "${RULE_COMMIT}^{commit}") || \
    fail "Formal rule commit does not exist: ${RULE_COMMIT}"
[[ "$resolved_rule_commit" == "$RULE_COMMIT" ]] || fail "Rule commit is not a full exact commit"
[[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" == "$RULE_COMMIT" ]] || fail "HEAD must equal the formal rule commit"
git -C "$ROOT_DIR" diff --quiet "$RULE_COMMIT" -- simStock3 simStock3.xcodeproj || fail "App source differs from the formal rule commit"

step "Booting ${SIMULATOR_NAME} (${SIMULATOR_UDID})"
xcrun simctl boot "$SIMULATOR_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b

build_stamp="${DERIVED_DATA}/s51-source.sha256"
source_hash=$(find "${ROOT_DIR}/simStock3" "${ROOT_DIR}/simStock3.xcodeproj" -type f -not -path '*/xcuserdata/*' -exec shasum -a 256 {} \; | sort | shasum -a 256 | awk '{print $1}')
if [[ -f "$build_stamp" && "$(<"$build_stamp")" == "$source_hash" ]]; then
    step "Reusing source-verified formal Debug App"
else
step "Building one Debug App for all formal Baseline v32 runs"
xcodebuild build \
    -project "${ROOT_DIR}/simStock3.xcodeproj" \
    -scheme simStock3 \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO
print -r -- "$source_hash" > "$build_stamp"
fi

readonly APP_PATH="${DERIVED_DATA}/Build/Products/Debug-iphonesimulator/simStock3.app"
[[ -d "$APP_PATH" ]] || fail "Built App not found: ${APP_PATH}"
xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
data_container=$(xcrun simctl get_app_container "$SIMULATOR_UDID" "$BUNDLE_ID" data)
readonly DATA_CONTAINER="$data_container"
readonly INTERNAL_ROOT="${DATA_CONTAINER}/Documents/InternalBacktest"
readonly FAILURE_MARKER="${INTERNAL_ROOT}/.last-run-failure.txt"
readonly MARKET_TARGET_DIR="${INTERNAL_ROOT}/Research/Market"

step "Syncing verified frozen market price path"
mkdir -p "$MARKET_TARGET_DIR"
ditto "$MARKET_PRICE_PATH_SOURCE" "${MARKET_TARGET_DIR}/market-price-path.csv"
ditto "$MARKET_DAILY_SOURCE" "${MARKET_TARGET_DIR}/market-daily.csv"
ditto "$MARKET_EXTREMA_SOURCE" "${MARKET_TARGET_DIR}/market-index-extrema9.csv"
[[ "$(shasum -a 256 "${MARKET_TARGET_DIR}/market-daily.csv" | awk '{print $1}')" == "$MARKET_DAILY_SHA256" ]] || fail "Staged daily OHLC hash mismatch"
[[ "$(shasum -a 256 "${MARKET_TARGET_DIR}/market-index-extrema9.csv" | awk '{print $1}')" == "$MARKET_EXTREMA_SHA256" ]] || fail "Staged extrema hash mismatch"
staged_market_sha=$(shasum -a 256 "${MARKET_TARGET_DIR}/market-price-path.csv" | awk '{print $1}')
[[ "$staged_market_sha" == "$MARKET_PRICE_PATH_SHA256" ]] || \
    fail "Staged market price-path hash mismatch: ${staged_market_sha}"

candidate_directory() {
    local sample_lower="$1" window="$2"
    if [[ "$window" == fixed3y ]]; then
        print -r -- "${ROOT_DIR}/exports/l-rebound-late-p1-20260912/source/exports/backtest-candidate-runs/l-rebound-late-p1-${sample_lower}-candidate-t3s50-fixed3y-600w-20260912"
    else
        print -r -- "${ROOT_DIR}/exports/l-rebound-late-p1-full-20260912/source/exports/backtest-candidate-runs/l-rebound-late-p1-${sample_lower}-candidate-t3s50-9y-fullstress-600w-20260912"
    fi
}

for sample in A B C D E; do
    sample_lower="${sample:l}"
    sample_flag=("--sample-${sample_lower}")
    profile_id="abcd9-v3"
    [[ "$sample" == E ]] && profile_id="abcde9-v3"
    decision_base_id="${sample_lower}-${profile_id}-${RULE_VERSION}-t3-s51-${RULE_COMMIT[1,12]}-fixed3y-20260722-v18"

    for window in fixed3y fullstress; do
        window_id="9y-${window}"
        run_id="baseline-${sample_lower}-v32-s44-lp12-late-rebound-t3s51-${window_id}-600w-20260912"
        run_dir="${INTERNAL_ROOT}/Runs/${run_id}"
        complete_marker="${run_dir}/.complete"
        args=(
            --run-internal-backtest-report
            --nine-year-ab-baseline
            --retain-period-stores
            --formal-late-rebound-baseline-v32
            "${sample_flag[@]}"
            --rule-commit "$RULE_COMMIT"
        )
        if [[ "$window" == fixed3y ]]; then
            args+=(--record-decision-base)
        else
            args+=(--full-window-stress)
        fi

        reference_id="baseline-${sample_lower}-v31-s43-st01c-pullback-profit-t3s50-${window_id}-600w-20260911"
        reference_source="${ROOT_DIR}/exports/backtest-reports/${reference_id}/baseline.json"
        [[ -f "$reference_source" ]] || fail "Missing v31 reference: ${reference_id}"
        mkdir -p "${INTERNAL_ROOT}/Runs/${reference_id}"
        ditto "$reference_source" "${INTERNAL_ROOT}/Runs/${reference_id}/baseline.json"

        # Never overwrite a completed report or erase a partial run on retry.
        [[ ! -e "$run_dir" ]] || fail "Run already exists; inspect and resume explicitly: ${run_dir}"
        [[ ! -e "${ROOT_DIR}/exports/backtest-reports/${run_id}" ]] || fail "Export already exists: ${run_id}"
        step "Running Sample ${sample} ${window_id}"
        xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
        rm -f "$FAILURE_MARKER" "$complete_marker"
        launch_observed "$SIMULATOR_UDID" "$BUNDLE_ID" "${args[@]}"
        last_fingerprint=""
        last_progress=$(date +%s)
        deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
        while [[ ! -f "$complete_marker" ]]; do
            observe_progress
            if [[ -f "$FAILURE_MARKER" ]]; then
                fail "$(<"$FAILURE_MARKER")"
            fi
            (( $(date +%s) < deadline )) || fail "Timed out waiting for ${run_id}"
            xcrun simctl list devices booted | grep -Fq "$SIMULATOR_UDID" || fail "Simulator stopped during ${run_id}; preserve partial run for diagnosis"
            sleep 2
        done

        [[ "$(<"$complete_marker")" == "$run_id" ]] || fail "Completion marker mismatch: ${run_id}"
        manifest="${run_dir}/manifest.json"
        [[ -f "$manifest" ]] || fail "Missing manifest: ${run_id}"
        [[ "$(json_raw "$manifest" runID)" == "$run_id" ]] || fail "Run ID mismatch: ${run_id}"
        [[ "$(json_raw "$manifest" sampleID)" == "$sample" ]] || fail "Sample mismatch: ${run_id}"
        [[ "$(json_raw "$manifest" dataRuleVersion)" == "T3/S51" ]] || fail "T/S mismatch: ${run_id}"
        [[ "$(json_raw "$manifest" ruleVersion)" == "$RULE_VERSION" ]] || fail "Rule version mismatch: ${run_id}"
        [[ "$(json_raw "$manifest" ruleCommit)" == "$RULE_COMMIT" ]] || fail "Rule commit mismatch: ${run_id}"
        for required in baseline.json periods.csv report.html browse.store .complete; do
            [[ -f "${run_dir}/${required}" ]] || fail "Missing ${required}: ${run_id}"
        done
        [[ "$(sqlite3 -readonly "${run_dir}/browse.store" 'PRAGMA integrity_check;')" == "ok" ]] || \
            fail "browse.store integrity failed: ${run_id}"
        negative_count=$(sqlite3 -readonly "${run_dir}/browse.store" 'SELECT COUNT(*) FROM ZTRADE WHERE ZSIMAMTBALANCE < -0.01;')
        [[ "$negative_count" == 0 ]] || fail "Negative cash balance in ${run_id}: ${negative_count} rows; preserve output for diagnosis"

        if [[ "$window" == fixed3y || "$window" == fullstress ]]; then
            adopted="$(candidate_directory "$sample_lower" "$window")/periods.csv"
            cmp -s "$adopted" "${run_dir}/periods.csv" || fail "Formal output differs from adopted L-REBOUND-LATE-P1: ${run_id}"
        fi
        destination="${ROOT_DIR}/exports/backtest-reports/${run_id}"
        [[ ! -e "$destination" ]] || fail "Output already exists: ${destination}"
        ditto "$run_dir" "$destination"
        print -- "Completed ${run_id}"
    done

    decision_base_source="${INTERNAL_ROOT}/DecisionBases/${decision_base_id}"
    [[ -f "${decision_base_source}/.complete" ]] || fail "Missing DecisionBase completion: ${decision_base_id}"
    [[ "$(<"${decision_base_source}/.complete")" == "$decision_base_id" ]] || \
        fail "DecisionBase completion mismatch: ${decision_base_id}"
    [[ "$(sqlite3 -readonly "${decision_base_source}/decisions.sqlite" 'PRAGMA integrity_check;')" == "ok" ]] || \
        fail "DecisionBase SQLite integrity failed: ${decision_base_id}"
    step "Profiling Sample ${sample} DecisionBase v18"
    xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -f "$FAILURE_MARKER" "${decision_base_source}/.p4b-complete"
    launch_observed "$SIMULATOR_UDID" "$BUNDLE_ID" \
        --profile-internal-backtest-decision-base \
        --decision-base-id "$decision_base_id"
    profile_marker="${decision_base_source}/.p4b-complete"
    last_fingerprint=""
    last_progress=$(date +%s)
    profile_deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
    while [[ ! -f "$profile_marker" ]]; do
        observe_progress
        if [[ -f "$FAILURE_MARKER" ]]; then
            fail "$(<"$FAILURE_MARKER")"
        fi
        (( $(date +%s) < profile_deadline )) || fail "Timed out profiling ${decision_base_id}"
        sleep 2
    done
    [[ "$(<"$profile_marker")" == "$decision_base_id" ]] || \
        fail "DecisionBase profile marker mismatch: ${decision_base_id}"
    decision_base_destination="${ROOT_DIR}/exports/backtest-decision-bases/${decision_base_id}"
    [[ ! -e "$decision_base_destination" ]] || fail "DecisionBase output exists: ${decision_base_destination}"
    ditto "$decision_base_source" "$decision_base_destination"
    python3 "${ROOT_DIR}/tools/audit_baseline_v32.py" "$sample"
done

step "Comparing formal Baseline v32 with adopted L-REBOUND-LATE-P1 evidence"
for sample in A B C D E; do
    sample_lower="${sample:l}"
    for window in fixed3y fullstress; do
        candidate="$(candidate_directory "$sample_lower" "$window")/periods.csv"
        formal="${ROOT_DIR}/exports/backtest-reports/baseline-${sample_lower}-v32-s44-lp12-late-rebound-t3s51-9y-${window}-600w-20260912/periods.csv"
        cmp -s "$candidate" "$formal" || fail "Formal output differs from adopted candidate: Sample ${sample} ${window}"
        print -- "MATCH Sample ${sample} ${window}: $(shasum -a 256 "$formal" | awk '{print $1}')"
    done
done

[[ "$(git -C "$ROOT_DIR" rev-parse --verify "${RULE_COMMIT}^{commit}")" == "$RULE_COMMIT" ]] || \
    fail "Formal rule commit changed during execution"

step "Formal Baseline v32 and DecisionBase v18 outputs complete"
