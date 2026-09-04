#!/bin/zsh

set -euo pipefail
setopt extendedglob
unsetopt BG_NICE

readonly SCRIPT_DIR="${0:A:h}"
readonly ROOT_DIR="${SCRIPT_DIR:h}"
readonly SIMULATOR_NAME="${SIMSTOCK_BASELINE_SIMULATOR_NAME:-iPad Pro 13-inch (M5)}"
readonly RULE_COMMIT="${SIMSTOCK_BASELINE_RULE_COMMIT:-ead1b082576a52143ca567aff1219dc4bf2a12d9}"
readonly TIMEOUT_SECONDS="${SIMSTOCK_BASELINE_TIMEOUT_SECONDS:-1800}"
readonly DERIVED_DATA="${SIMSTOCK_BASELINE_DERIVED_DATA:-${TMPDIR:-/tmp}/simStock3-formal-market-baseline-derived}"
readonly BUNDLE_ID="com.peiyou.simStock3"
readonly RULE_VERSION="s33-sp08-market-stock-peak-late-high-sell-20260904"
readonly MARKET_PRICE_PATH_SOURCE="${ROOT_DIR}/exports/market-data/taiex/research/mkt-pp-p1-taiex-price-path-f712b360c322/market-price-path.csv"
readonly MARKET_PRICE_PATH_SHA256="f9e1f41c8ba74dd94b970460a148983d7763b108985be55b11cfba64fc03d17f"

fail() {
    print -u2 -- "ERROR: $*"
    exit 1
}

step() {
    print -- "\n==> $*"
}

json_raw() {
    plutil -extract "$2" raw -o - "$1"
}

[[ -f "$MARKET_PRICE_PATH_SOURCE" ]] || fail "Missing frozen market price path: ${MARKET_PRICE_PATH_SOURCE}"
actual_market_sha=$(shasum -a 256 "$MARKET_PRICE_PATH_SOURCE" | awk '{print $1}')
[[ "$actual_market_sha" == "$MARKET_PRICE_PATH_SHA256" ]] || \
    fail "Frozen market price-path hash mismatch: ${actual_market_sha}"

simulator_line=$(xcrun simctl list devices available | grep -F "${SIMULATOR_NAME} (" | head -1 || true)
[[ -n "$simulator_line" ]] || fail "Simulator not found: ${SIMULATOR_NAME}"
simulator_udid=$(print -- "$simulator_line" | grep -Eo '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1 || true)
[[ -n "$simulator_udid" ]] || fail "Cannot parse Simulator UDID: ${simulator_line}"
readonly SIMULATOR_UDID="$simulator_udid"

resolved_rule_commit=$(git -C "$ROOT_DIR" rev-parse --verify "${RULE_COMMIT}^{commit}") || \
    fail "Formal rule commit does not exist: ${RULE_COMMIT}"
[[ "$resolved_rule_commit" == "$RULE_COMMIT" ]] || fail "Rule commit is not a full exact commit"
git -C "$ROOT_DIR" merge-base --is-ancestor "$RULE_COMMIT" HEAD || \
    fail "Formal rule commit is not an ancestor of HEAD: ${RULE_COMMIT}"

step "Booting ${SIMULATOR_NAME} (${SIMULATOR_UDID})"
xcrun simctl boot "$SIMULATOR_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b

step "Building one Debug App for all formal Baseline v22 runs"
xcodebuild build \
    -project "${ROOT_DIR}/simStock3.xcodeproj" \
    -scheme simStock3 \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO

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
staged_market_sha=$(shasum -a 256 "${MARKET_TARGET_DIR}/market-price-path.csv" | awk '{print $1}')
[[ "$staged_market_sha" == "$MARKET_PRICE_PATH_SHA256" ]] || \
    fail "Staged market price-path hash mismatch: ${staged_market_sha}"

for sample in A B C D E; do
    sample_lower="${sample:l}"
    sample_flag=("--sample-${sample_lower}")
    profile_id="abcd9-v3"
    [[ "$sample" == E ]] && profile_id="abcde9-v3"
    decision_base_id="${sample_lower}-${profile_id}-${RULE_VERSION}-t3-s40-${RULE_COMMIT[1,12]}-fixed3y-20260722-v8"

    for window in fixed3y fullstress; do
        window_id="9y-${window}"
        run_id="baseline-${sample_lower}-v22-s33-sp08-market-stock-peak-late-high-sell-t3s40-${window_id}-600w-20260904"
        run_dir="${INTERNAL_ROOT}/Runs/${run_id}"
        complete_marker="${run_dir}/.complete"
        args=(
            --run-internal-backtest-report
            --nine-year-ab-baseline
            --formal-market-baseline-v22
            "${sample_flag[@]}"
            --rule-commit "$RULE_COMMIT"
        )
        if [[ "$window" == fixed3y ]]; then
            args+=(--record-decision-base)
        else
            args+=(--full-window-stress)
        fi

        step "Running Sample ${sample} ${window_id}"
        xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
        rm -f "$FAILURE_MARKER" "$complete_marker"
        xcrun simctl launch "$SIMULATOR_UDID" "$BUNDLE_ID" "${args[@]}" >/dev/null
        deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
        while [[ ! -f "$complete_marker" ]]; do
            if [[ -f "$FAILURE_MARKER" ]]; then
                fail "$(<"$FAILURE_MARKER")"
            fi
            (( $(date +%s) < deadline )) || fail "Timed out waiting for ${run_id}"
            sleep 2
        done

        [[ "$(<"$complete_marker")" == "$run_id" ]] || fail "Completion marker mismatch: ${run_id}"
        manifest="${run_dir}/manifest.json"
        [[ -f "$manifest" ]] || fail "Missing manifest: ${run_id}"
        [[ "$(json_raw "$manifest" runID)" == "$run_id" ]] || fail "Run ID mismatch: ${run_id}"
        [[ "$(json_raw "$manifest" sampleID)" == "$sample" ]] || fail "Sample mismatch: ${run_id}"
        [[ "$(json_raw "$manifest" dataRuleVersion)" == "T3/S40" ]] || fail "T/S mismatch: ${run_id}"
        [[ "$(json_raw "$manifest" ruleVersion)" == "$RULE_VERSION" ]] || fail "Rule version mismatch: ${run_id}"
        [[ "$(json_raw "$manifest" ruleCommit)" == "$RULE_COMMIT" ]] || fail "Rule commit mismatch: ${run_id}"
        for required in baseline.json periods.csv report.html browse.store .complete; do
            [[ -f "${run_dir}/${required}" ]] || fail "Missing ${required}: ${run_id}"
        done
        [[ "$(sqlite3 "${run_dir}/browse.store" 'PRAGMA integrity_check;')" == "ok" ]] || \
            fail "browse.store integrity failed: ${run_id}"

        destination="${ROOT_DIR}/exports/backtest-reports/${run_id}"
        [[ ! -e "$destination" ]] || fail "Output already exists: ${destination}"
        ditto "$run_dir" "$destination"
        print -- "Completed ${run_id}"
    done

    decision_base_source="${INTERNAL_ROOT}/DecisionBases/${decision_base_id}"
    [[ -f "${decision_base_source}/.complete" ]] || fail "Missing DecisionBase completion: ${decision_base_id}"
    [[ "$(<"${decision_base_source}/.complete")" == "$decision_base_id" ]] || \
        fail "DecisionBase completion mismatch: ${decision_base_id}"
    [[ "$(sqlite3 "${decision_base_source}/decisions.sqlite" 'PRAGMA integrity_check;')" == "ok" ]] || \
        fail "DecisionBase SQLite integrity failed: ${decision_base_id}"
    step "Profiling Sample ${sample} DecisionBase v8"
    xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -f "${decision_base_source}/.p4b-complete"
    xcrun simctl launch "$SIMULATOR_UDID" "$BUNDLE_ID" \
        --profile-internal-backtest-decision-base \
        --decision-base-id "$decision_base_id" >/dev/null
    profile_marker="${decision_base_source}/.p4b-complete"
    profile_deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
    while [[ ! -f "$profile_marker" ]]; do
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
done

step "Comparing formal Baseline v22 with adopted MKT-PP-S02 evidence"
for sample in A B C D E; do
    sample_lower="${sample:l}"
    for window in fixed3y fullstress; do
        candidate="${ROOT_DIR}/exports/backtest-candidate-runs/mkt-pp-s02-${sample_lower}-high-grade-prior-market-stock-peak-late-sell-plus1-t3s39-9y-${window}-600w-20260904/periods.csv"
        formal="${ROOT_DIR}/exports/backtest-reports/baseline-${sample_lower}-v22-s33-sp08-market-stock-peak-late-high-sell-t3s40-9y-${window}-600w-20260904/periods.csv"
        cmp -s "$candidate" "$formal" || fail "Formal output differs from adopted candidate: Sample ${sample} ${window}"
        print -- "MATCH Sample ${sample} ${window}: $(shasum -a 256 "$formal" | awk '{print $1}')"
    done
done

[[ "$(git -C "$ROOT_DIR" rev-parse --verify "${RULE_COMMIT}^{commit}")" == "$RULE_COMMIT" ]] || \
    fail "Formal rule commit changed during execution"

step "Formal Baseline v22 and DecisionBase v8 outputs complete"
