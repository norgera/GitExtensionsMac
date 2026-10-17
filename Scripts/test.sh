#!/bin/bash
set -euo pipefail

suite="${1:-all}"
selection=(-parallel-testing-enabled YES -parallel-testing-worker-count 1)
case "$suite" in
    unit) selection+=(-only-testing:GitExtensionsMacTests/UnitTests) ;;
    git) selection+=(-only-testing:GitExtensionsMacTests/GitIntegrationTests) ;;
    ui) selection+=(-only-testing:GitExtensionsMacTests/UIIntegrationTests) ;;
    all) ;;
    *) echo "Usage: $0 [unit|git|ui|all] [xcodebuild options...]" >&2; exit 2 ;;
esac
if (( $# > 0 )); then shift; fi

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"
results_root="${TEST_RESULTS_DIR:-$repository_root/.build/test-results}"
mkdir -p "$results_root"
run_directory="$(mktemp -d "$results_root/$suite.XXXXXX")"
export TEST_RUNNER_GITEXTENSIONS_TEST_SHOW_WINDOWS="${GITEXTENSIONS_TEST_SHOW_WINDOWS:-0}"
echo "Test results: $run_directory/Tests.xcresult"
xcodebuild test \
    -project GitExtensionsMac.xcodeproj \
    -scheme GitExtensionsMacTests \
    -destination 'platform=macOS' \
    -derivedDataPath "${TEST_DERIVED_DATA:-$repository_root/.build/DerivedData}" \
    -resultBundlePath "$run_directory/Tests.xcresult" \
    -jobs "${TEST_BUILD_JOBS:-2}" \
    CODE_SIGNING_ALLOWED=NO \
    "${selection[@]}" "$@" 2>&1 | tee "$run_directory/xcodebuild.log"
