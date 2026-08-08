#!/usr/bin/env bash

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    return 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="${3:-expected '$expected', got '$actual'}"

    [ "$expected" = "$actual" ] || fail "$message"
}

assert_path_exists() {
    local path="$1"
    [ -e "$path" ] || [ -L "$path" ] || fail "expected path to exist: $path"
}

assert_path_missing() {
    local path="$1"
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail "expected path to be missing: $path"
}

assert_file_contains() {
    local path="$1"
    local expected="$2"

    grep -F -q -- "$expected" "$path" || fail "expected $path to contain: $expected"
}

assert_file_not_contains() {
    local path="$1"
    local unexpected="$2"

    if grep -F -q -- "$unexpected" "$path"; then
        fail "expected $path not to contain: $unexpected"
    fi
}

make_test_dir() {
    mktemp -d "${TMPDIR:-/tmp}/dotfiles-test.XXXXXX"
}
