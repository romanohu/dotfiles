#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$TEST_DIR/.." && pwd)

# shellcheck source=test_helpers.sh
. "$TEST_DIR/test_helpers.sh"

TEST_ROOT=$(make_test_dir)
TEST_SHELL_BASHPID="${BASHPID:-$$}"
TEST_STATUS=0

cleanup() {
    [ "${BASHPID:-$$}" = "$TEST_SHELL_BASHPID" ] || return 0
    rm -rf "$TEST_ROOT"
}

trap cleanup EXIT

create_fixture() {
    local fixture_bin="$TEST_ROOT/bin"

    mkdir -p "$fixture_bin"
    : > "$TEST_ROOT/herdr.log"
    printf '%s\n' \
        '# Commands available to ha' \
        '' \
        'codex' \
        '' \
        '# A second permitted command' \
        'claude' > "$TEST_ROOT/agents.local"

    for command in codex claude; do
        printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fixture_bin/$command"
        chmod +x "$fixture_bin/$command"
    done

    cat > "$fixture_bin/herdr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"

case "$1 $2" in
    'workspace list')
        if [ -n "${FAKE_HERDR_WORKSPACE_LIST_JSON:-}" ]; then
            printf '%s\n' "$FAKE_HERDR_WORKSPACE_LIST_JSON"
        else
            printf '%s\n' '{"result":{"workspaces":[]}}'
        fi
        ;;
    'workspace create')
        printf '%s\n' '{"result":{"workspace":{"workspace_id":"w1","cwd":"/tmp/project"},"root_pane":{"pane_id":"w1:p1"}}}'
        ;;
    'pane list')
        printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","label":"agent-1"}]}}'
        ;;
    'pane split')
        printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2"}}}'
        ;;
    'pane run')
        if [ -n "${FAKE_HERDR_PANE_RUN_RESPONSE:-}" ]; then
            printf '%s\n' "$FAKE_HERDR_PANE_RUN_RESPONSE"
        else
            printf '%s\n' '{"result":{}}'
        fi
        ;;
    'pane rename')
        if [ -n "${FAKE_HERDR_PANE_RENAME_RESPONSE:-}" ]; then
            printf '%s\n' "$FAKE_HERDR_PANE_RENAME_RESPONSE"
        else
            printf '%s\n' '{"result":{}}'
        fi
        ;;
esac
EOF
    chmod +x "$fixture_bin/herdr"
}

run_ha() {
    local output="$1"
    shift

    PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
        FAKE_HERDR_LOG="$TEST_ROOT/herdr.log" \
        HA_CONFIG_PATH="$TEST_ROOT/agents.local" \
        HERDR_WORKSPACE_ID='w1' \
        HERDR_PANE_ID='w1:p1' \
        HERDR_ACTIVE_PANE_CWD='/tmp/project' \
        "$REPO_DIR/bin/ha" "$@" > "$output" 2>&1
}

run_ha_without_workspace() {
    local output="$1"
    shift

    mkdir -p "$TEST_ROOT/project"
    (
        cd "$TEST_ROOT/project"
        PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
            FAKE_HERDR_LOG="$TEST_ROOT/herdr.log" \
            HA_CONFIG_PATH="$TEST_ROOT/agents.local" \
            HERDR_WORKSPACE_ID='' \
            HERDR_PANE_ID='' \
            HERDR_ACTIVE_PANE_CWD='' \
            "$REPO_DIR/bin/ha" "$@"
    ) > "$output" 2>&1
}

record_failure() {
    printf 'FAIL: %s\n' "$*" >&2
    TEST_STATUS=1
}

assert_ha_succeeds() {
    local description="$1"
    local output="$2"
    shift 2

    if ! run_ha "$output" "$@"; then
        record_failure "$description: $(cat "$output")"
    fi
}

assert_file_contains_or_record() {
    if ! assert_file_contains "$1" "$2"; then
        TEST_STATUS=1
    fi
}

assert_no_herdr_calls() {
    if ! assert_eq '' "$(cat "$TEST_ROOT/herdr.log")" \
        'ha must not call Herdr before validation succeeds'; then
        TEST_STATUS=1
    fi
}

assert_herdr_pane_operation_order() {
    local actual

    actual=$(awk '$1 " " $2 ~ /^(workspace create|pane split|pane run|pane rename)$/ { print $1 " " $2 }' "$TEST_ROOT/herdr.log")
    if ! assert_eq "pane split
pane run
pane rename" "$actual" \
        'ha must split, run, then rename exactly one pane'; then
        TEST_STATUS=1
    fi
}

test_ha_dry_run_does_not_call_herdr() {
    local output="$TEST_ROOT/dry-run.out"

    create_fixture
    assert_ha_succeeds 'ha --dry-run must succeed' "$output" --dry-run codex

    assert_no_herdr_calls
    assert_file_contains_or_record "$output" 'codex'
}

test_ha_rejects_missing_agent_before_mutation() {
    local output="$TEST_ROOT/missing-agent.out"

    create_fixture
    if run_ha "$output" missing-agent; then
        record_failure 'ha must reject an executable that is not on PATH'
    fi

    assert_no_herdr_calls
    assert_file_contains_or_record "$output" 'missing-agent'
}

test_ha_rejects_unconfigured_agent_before_mutation() {
    local output="$TEST_ROOT/unconfigured-agent.out"

    create_fixture
    if ! PATH="$TEST_ROOT/bin:/usr/bin:/bin" command -v sh >/dev/null 2>&1; then
        record_failure 'test fixture must expose an existing unconfigured sh command'
    fi
    if run_ha "$output" sh; then
        record_failure 'ha must reject an existing executable absent from agents.local'
    fi

    assert_no_herdr_calls
}

test_ha_rejects_empty_explicit_command_before_mutation() {
    local output="$TEST_ROOT/empty-command.out"

    create_fixture
    if run_ha "$output" ''; then
        record_failure 'ha must reject an explicitly empty command name'
    fi

    assert_no_herdr_calls
}

test_ha_uses_explicit_command() {
    local output="$TEST_ROOT/explicit-command.out"

    create_fixture
    assert_ha_succeeds 'ha must accept an explicit configured command' "$output" claude

    assert_herdr_pane_operation_order
    assert_file_contains_or_record "$TEST_ROOT/herdr.log" 'claude'
}

test_ha_selects_first_configured_command_without_fzf() {
    local output="$TEST_ROOT/default-command.out"

    create_fixture
    assert_ha_succeeds \
        'ha must ignore blank and comment lines and choose the first configured command without fzf' \
        "$output"

    assert_herdr_pane_operation_order
    assert_file_contains_or_record "$TEST_ROOT/herdr.log" 'codex'
}

test_ha_splits_active_pane_and_runs_one_command() {
    local output="$TEST_ROOT/active-pane.out"

    create_fixture
    assert_ha_succeeds 'ha must split the active pane for a configured command' "$output" codex

    assert_herdr_pane_operation_order
    assert_file_contains_or_record "$TEST_ROOT/herdr.log" \
        'pane split --current --direction right --no-focus'
    assert_file_contains_or_record "$TEST_ROOT/herdr.log" 'pane run w1:p2 codex'
    assert_file_contains_or_record "$TEST_ROOT/herdr.log" 'pane rename w1:p2 agent-2'
}

test_ha_creates_workspace_for_current_directory_before_splitting() {
    local output="$TEST_ROOT/no-workspace.out"
    local project_dir="$TEST_ROOT/project"
    local physical_project_dir
    local expected_create
    local create_line split_line

    create_fixture
    mkdir -p "$project_dir"
    physical_project_dir=$(CDPATH= cd -P -- "$project_dir" && pwd -P)
    if ! run_ha_without_workspace "$output" codex; then
        record_failure \
            "ha must create a workspace for the current directory when none is active: $(cat "$output")"
    fi

    expected_create="workspace create --cwd $physical_project_dir --label $(basename "$physical_project_dir") --no-focus"
    assert_file_contains_or_record "$TEST_ROOT/herdr.log" 'workspace list'
    assert_file_contains_or_record "$TEST_ROOT/herdr.log" "$expected_create"
    assert_file_contains_or_record "$TEST_ROOT/herdr.log" 'pane split w1:p1 --direction right --no-focus'

    create_line=$(grep -n -F -- "$expected_create" "$TEST_ROOT/herdr.log" | head -n 1 | cut -d: -f1 || true)
    split_line=$(grep -n -F -- 'pane split w1:p1 --direction right --no-focus' "$TEST_ROOT/herdr.log" | head -n 1 | cut -d: -f1 || true)
    if [ -z "$create_line" ] || [ -z "$split_line" ] || [ "$create_line" -ge "$split_line" ]; then
        record_failure 'ha must create the workspace before splitting its root pane'
    fi
}

test_ha_rejects_matching_workspace_without_id_before_mutation() {
    local output="$TEST_ROOT/missing-workspace-id.out"
    local project_dir="$TEST_ROOT/project"
    local physical_project_dir

    create_fixture
    mkdir -p "$project_dir"
    physical_project_dir=$(CDPATH= cd -P -- "$project_dir" && pwd -P)
    (
        export FAKE_HERDR_WORKSPACE_LIST_JSON
        FAKE_HERDR_WORKSPACE_LIST_JSON=$(printf '{"result":{"workspaces":[{"cwd":"%s"}]}}' "$physical_project_dir")
        if run_ha_without_workspace "$output" codex; then
            record_failure 'ha must reject a matching Herdr workspace without an ID'
        fi
    )

    if ! assert_eq 'workspace list' "$(cat "$TEST_ROOT/herdr.log")" \
        'ha must not create or mutate a workspace when its ID is missing'; then
        TEST_STATUS=1
    fi
}

test_ha_rejects_malformed_pane_run_response() {
    local output="$TEST_ROOT/malformed-run.out"

    create_fixture
    export FAKE_HERDR_PANE_RUN_RESPONSE='not JSON'
    if run_ha "$output" codex; then
        record_failure 'ha must reject a malformed pane run response'
    fi
    unset FAKE_HERDR_PANE_RUN_RESPONSE

    if ! assert_eq "pane split
pane run" "$(awk '$1 " " $2 ~ /^(workspace create|pane split|pane run|pane rename)$/ { print $1 " " $2 }' "$TEST_ROOT/herdr.log")" \
        'ha must not rename a pane after a malformed pane run response'; then
        TEST_STATUS=1
    fi
}

test_ha_rejects_malformed_pane_rename_response() {
    local output="$TEST_ROOT/malformed-rename.out"

    create_fixture
    export FAKE_HERDR_PANE_RENAME_RESPONSE='not JSON'
    if run_ha "$output" codex; then
        record_failure 'ha must reject a malformed pane rename response'
    fi
    unset FAKE_HERDR_PANE_RENAME_RESPONSE
}

for test_name in \
    test_ha_dry_run_does_not_call_herdr \
    test_ha_rejects_missing_agent_before_mutation \
    test_ha_rejects_unconfigured_agent_before_mutation \
    test_ha_rejects_empty_explicit_command_before_mutation \
    test_ha_uses_explicit_command \
    test_ha_selects_first_configured_command_without_fzf \
    test_ha_splits_active_pane_and_runs_one_command \
    test_ha_creates_workspace_for_current_directory_before_splitting \
    test_ha_rejects_matching_workspace_without_id_before_mutation \
    test_ha_rejects_malformed_pane_run_response \
    test_ha_rejects_malformed_pane_rename_response; do
    printf 'RUN: %s\n' "$test_name"
    "$test_name"
done
if [ "$TEST_STATUS" -ne 0 ]; then
    exit "$TEST_STATUS"
fi
printf 'PASS: %s\n' "$(basename "$0")"
