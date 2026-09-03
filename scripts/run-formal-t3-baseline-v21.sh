#!/bin/zsh

set -euo pipefail
setopt extendedglob
unsetopt BG_NICE

readonly SCRIPT_DIR="${0:A:h}"
readonly ROOT_DIR="${SCRIPT_DIR:h}"
readonly SIMULATOR_NAME="${SIMSTOCK_BASELINE_SIMULATOR_NAME:-iPad Pro 13-inch (M5)}"
readonly RULE_COMMIT="${SIMSTOCK_BASELINE_RULE_COMMIT:-d1a5a81aa2736e1f90830bf7ecd25882e19ffb56}"
readonly TIMEOUT_SECONDS="${SIMSTOCK_BASELINE_TIMEOUT_SECONDS:-1800}"
readonly DERIVED_DATA="${SIMSTOCK_BASELINE_DERIVED_DATA:-${TMPDIR:-/tmp}/simStock3-formal-baseline-derived}"
readonly BUNDLE_ID="com.peiyou.simStock3"
readonly RULE_VERSION="s32-an03-wow-nonbottom-no-ap02-add-penalty-20260901"

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

simulator_line=$(xcrun simctl list devices available | grep -F "${SIMULATOR_NAME} (" | head -1 || true)
[[ -n "$simulator_line" ]] || fail "Simulator not found: ${SIMULATOR_NAME}"
simulator_udid=$(print -- "$simulator_line" | grep -Eo '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1 || true)
[[ -n "$simulator_udid" ]] || fail "Cannot parse Simulator UDID: ${simulator_line}"
readonly SIMULATOR_UDID="$simulator_udid"

resolved_rule_commit=$(git -C "$ROOT_DIR" rev-parse --verify "${RULE_COMMIT}^{commit}") || \
    fail "Formal rule commit does not exist: ${RULE_COMMIT}"
[[ "$resolved_rule_commit" == "$RULE_COMMIT" ]] || fail "Rule commit is not a full exact commit"

step "Booting ${SIMULATOR_NAME} (${SIMULATOR_UDID})"
xcrun simctl boot "$SIMULATOR_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b

step "Building one Debug App for all formal Baseline v21 runs"
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

for sample in A B C D E; do
    sample_lower="${sample:l}"
    sample_flag=()
    [[ "$sample" == A ]] || sample_flag=("--sample-${sample_lower}")
    profile_id="abcd9-v3"
    [[ "$sample" == E ]] && profile_id="abcde9-v3"
    decision_base_id="${sample_lower}-${profile_id}-${RULE_VERSION}-t3-s39-${RULE_COMMIT[1,12]}-fixed3y-20260722-v7"

    for window in fixed3y fullstress; do
        window_id="9y-${window}"
        run_id="baseline-${sample_lower}-v21-s32-an03-wow-nonbottom-no-ap02-add-penalty-t3s39-${window_id}-600w-20260903"
        run_dir="${INTERNAL_ROOT}/Runs/${run_id}"
        complete_marker="${run_dir}/.complete"
        args=(
            --run-internal-backtest-report
            --nine-year-ab-baseline
            --formal-t3-baseline-v21
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
        rm -f "$FAILURE_MARKER"
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
        [[ "$(json_raw "$manifest" dataRuleVersion)" == "T3/S39" ]] || fail "T/S mismatch: ${run_id}"
        [[ "$(json_raw "$manifest" ruleVersion)" == "$RULE_VERSION" ]] || fail "Rule version mismatch: ${run_id}"
        [[ "$(json_raw "$manifest" ruleCommit)" == "$RULE_COMMIT" ]] || fail "Rule commit mismatch: ${run_id}"

        destination="${ROOT_DIR}/exports/backtest-reports/${run_id}"
        [[ ! -e "$destination" ]] || fail "Output already exists: ${destination}"
        ditto "$run_dir" "$destination"
        print -- "Completed ${run_id}"
    done

    decision_base_source="${INTERNAL_ROOT}/DecisionBases/${decision_base_id}"
    [[ -f "${decision_base_source}/.complete" ]] || fail "Missing DecisionBase completion: ${decision_base_id}"
    [[ "$(<"${decision_base_source}/.complete")" == "$decision_base_id" ]] || \
        fail "DecisionBase completion mismatch: ${decision_base_id}"
    step "Profiling Sample ${sample} DecisionBase v7"
    xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$SIMULATOR_UDID" "$BUNDLE_ID" \
        --profile-internal-backtest-decision-base \
        --decision-base-id "$decision_base_id" >/dev/null
    profile_marker="${decision_base_source}/.p4b-complete"
    profile_deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
    while [[ ! -f "$profile_marker" ]]; do
        (( $(date +%s) < profile_deadline )) || fail "Timed out profiling ${decision_base_id}"
        sleep 2
    done
    [[ "$(<"$profile_marker")" == "$decision_base_id" ]] || \
        fail "DecisionBase profile marker mismatch: ${decision_base_id}"
    decision_base_destination="${ROOT_DIR}/exports/backtest-decision-bases/${decision_base_id}"
    [[ ! -e "$decision_base_destination" ]] || fail "DecisionBase output exists: ${decision_base_destination}"
    ditto "$decision_base_source" "$decision_base_destination"
done

step "Comparing Baseline v21 with formal v20"
for sample in A B C D E; do
    sample_lower="${sample:l}"
    for window in fixed3y fullstress; do
        old="${ROOT_DIR}/exports/backtest-reports/baseline-${sample_lower}-v20-s32-an03-wow-nonbottom-no-ap02-add-penalty-t2s39-9y-${window}-600w-20260901/periods.csv"
        new="${ROOT_DIR}/exports/backtest-reports/baseline-${sample_lower}-v21-s32-an03-wow-nonbottom-no-ap02-add-penalty-t3s39-9y-${window}-600w-20260903/periods.csv"
        cmp -s "$old" "$new" || fail "Strategy output changed: Sample ${sample} ${window}"
        print -- "MATCH Sample ${sample} ${window}: $(shasum -a 256 "$new" | awk '{print $1}')"
    done
done

step "Formal Baseline v21 and DecisionBase v7 outputs complete"
