#!/usr/bin/env bash
set -euo pipefail

SCRIPT_TEST_DIR=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR="${DOTFILES_TEST_DIR:-$SCRIPT_TEST_DIR}"
status=0
test_count=0

run_test_file() {
    local test_file="$1"

    [ -f "$test_file" ] || return 0
    test_count=$((test_count + 1))

    if ! bash "$test_file"; then
        status=1
    fi
}

for test_file in \
    "$TEST_DIR/test_configuration.sh" \
    "$TEST_DIR/test_mise_configuration.sh" \
    "$TEST_DIR/test_installer.sh" \
    "$TEST_DIR/test_agent.sh" \
    "$TEST_DIR/test_runner.sh"; do
    run_test_file "$test_file"
done

for test_file in "$TEST_DIR"/test_*.sh; do
    [ -f "$test_file" ] || continue
    case "$(basename "$test_file")" in
        test_helpers.sh|test_configuration.sh|test_mise_configuration.sh|test_installer.sh|test_agent.sh|test_runner.sh)
            continue
            ;;
    esac
    run_test_file "$test_file"
done

if [ "$test_count" -eq 0 ]; then
    printf 'FAIL: no test files found in %s\n' "$TEST_DIR" >&2
    exit 1
fi

if [ "$status" -eq 0 ]; then
    printf 'PASS: %s test file(s)\n' "$test_count"
fi

exit "$status"
