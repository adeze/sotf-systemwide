#!/usr/bin/env bash
# Run the ConfigBar XCTest suites and fail loudly if discovery finds none.
#
# `swift test` on current toolchains picks the swift-testing runner for this
# package and reports "0 tests" for its XCTest targets without failing, so
# the suites silently never ran in the lab recipe. Build the bundles and
# execute them with xctest directly, then require a non-zero executed count.
set -euo pipefail

cd "$(dirname "$0")/.."

scratch_path="${1:-target/configbar-swiftpm}"

swift build --build-tests \
    --package-path swift/configbar \
    --scratch-path "$scratch_path"

failures=0
total=0
for bundle in ConfigBarModelTests ConfigBarUITests; do
    path="$(find "$scratch_path" -name "$bundle.xctest" -maxdepth 6 | head -n 1)"
    if [[ -z "$path" ]]; then
        echo "error: $bundle.xctest not found under $scratch_path" >&2
        exit 1
    fi
    echo "==> $bundle"
    output="$(xcrun xctest "$path" 2>&1)" || failures=1
    echo "$output" | grep -E "Test Suite '.*' (passed|failed)|Executed [0-9]+ tests" || true
    executed="$(echo "$output" | grep -E "Executed [0-9]+ tests" | tail -n 1 | sed -E 's/.*Executed ([0-9]+) tests.*/\1/' || true)"
    if [[ -z "${executed:-}" || "$executed" == "0" ]]; then
        echo "error: $bundle executed 0 tests (discovery regression)" >&2
        exit 1
    fi
    total=$((total + executed))
    if echo "$output" | grep -qE "Executed [0-9]+ tests, with [1-9][0-9]* failures"; then
        failures=1
    fi
done

echo "ConfigBar suites executed $total tests."
exit "$failures"
