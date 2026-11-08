#!/bin/bash
# Runs every tests/test_*.sh and exits non-zero if any failed. Runs them all (instead of
# stopping at the first failure) so one CI run reports every broken test.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
failed_tests=()

for test_file in "$TESTS_DIR"/test_*.sh; do
    echo "=== $(basename "$test_file")"
    if bash "$test_file"; then
        echo "--- ok"
    else
        echo "--- FAILED"
        failed_tests+=("$(basename "$test_file")")
    fi
done

if [ "${#failed_tests[@]}" -gt 0 ]; then
    echo "Shell tests failed: ${failed_tests[*]}"
    exit 1
fi
echo "All shell tests passed."
