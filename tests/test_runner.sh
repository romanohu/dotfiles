#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$TEST_DIR/.." && pwd)

# shellcheck source=test_helpers.sh
. "$TEST_DIR/test_helpers.sh"

TEST_ROOT=$(make_test_dir)

cleanup() {
    rm -rf "$TEST_ROOT"
}

trap cleanup EXIT

test_runner_uses_cdpath_without_skipping_tests() {
    local fixture_dir="$TEST_ROOT/cdpath"
    local output

    mkdir -p "$fixture_dir"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "PASS: fixture test\\n"' > "$fixture_dir/test_fixture.sh"

    if ! output=$(cd "$REPO_DIR" && CDPATH="$REPO_DIR" DOTFILES_TEST_DIR="$fixture_dir" bash tests/run.sh); then
        fail "runner failed with inherited CDPATH: $output"
    fi

    case "$output" in
        *'PASS: fixture test'*'PASS: 1 test file(s)'*) ;;
        *) fail "runner did not report the fixture test count with CDPATH: $output" ;;
    esac
}

test_runner_fails_when_no_test_files_execute() {
    local fixture_dir="$TEST_ROOT/empty"
    local output

    mkdir -p "$fixture_dir"
    cp "$TEST_DIR/run.sh" "$fixture_dir/run.sh"

    if output=$(bash "$fixture_dir/run.sh" 2>&1); then
        fail 'runner must fail when no test files execute'
    fi

    case "$output" in
        *'no test files found'*) ;;
        *) fail "runner did not report zero executed test files: $output" ;;
    esac
}

test_installer_ignores_inherited_devbox_data_dir() {
    local output

    if ! output=$(DEVBOX_DATA_DIR=/tmp/preexisting-devbox-data bash "$TEST_DIR/test_installer.sh"); then
        fail "installer isolation test inherited DEVBOX_DATA_DIR: $output"
    fi
}

test_runner_uses_cdpath_without_skipping_tests
test_runner_fails_when_no_test_files_execute
test_installer_ignores_inherited_devbox_data_dir
printf 'PASS: %s\n' "$(basename "$0")"
