#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$TEST_DIR/.." && pwd)

# shellcheck source=test_helpers.sh
. "$TEST_DIR/test_helpers.sh"

test_neovim_configuration_is_not_tracked() {
    assert_path_missing "$REPO_DIR/.config/nvim"
    assert_path_missing "$REPO_DIR/nvim.log"
}

test_public_agent_guidance_excludes_runtime_state() {
    local guidance
    for guidance in "$REPO_DIR/.codex/AGENTS.md" "$REPO_DIR/.claude/CLAUDE.md"; do
        assert_file_contains "$guidance" 'Prefer the smallest change'
        assert_file_contains "$guidance" 'Minimize the Git diff'
        assert_file_contains "$guidance" 'Preserve existing structure'
        assert_file_not_contains "$guidance" 'https://'
        assert_file_not_contains "$guidance" '/Users/'
    done

    assert_file_contains "$REPO_DIR/.gitignore" '.codex/*'
    assert_file_contains "$REPO_DIR/.gitignore" '!.codex/AGENTS.md'
    assert_file_contains "$REPO_DIR/.gitignore" '.claude/*'
    assert_file_contains "$REPO_DIR/.gitignore" '!.claude/CLAUDE.md'
}

test_shell_uses_mise_without_devbox_or_cargo_path() {
    assert_file_contains "$REPO_DIR/.zshenv" '$HOME/.local/share/mise/shims'
    assert_file_contains "$REPO_DIR/.config/zsh/.zshrc" 'eval "$(mise activate zsh)"'
    assert_file_contains "$REPO_DIR/.config/zsh/.zshrc" \
        'export ZSH_CUSTOM="$HOME/.config/zsh/custom"'
    assert_file_not_contains "$REPO_DIR/.config/zsh/.zshrc" 'devbox'
    assert_file_not_contains "$REPO_DIR/.config/zsh/aliases.zsh" 'cddev'
    assert_file_not_contains "$REPO_DIR/.zshenv" '.cargo/bin'
}

test_herdr_remains_without_ha_command() {
    local config="$REPO_DIR/.config/herdr/config.toml"
    assert_file_contains "$config" 'onboarding = false'
    assert_file_contains "$config" 'default_shell = "zsh"'
    assert_file_contains "$config" 'new_cwd = "follow"'
    assert_file_contains "$config" '[ui]'
    assert_file_contains "$config" 'agent_panel_sort = "spaces"'
    assert_file_not_contains "$config" '[[keys.command]]'
    assert_file_not_contains "$config" 'command = "ha"'
}

test_removed_paths_are_not_active() {
    assert_path_missing "$REPO_DIR/.config/devbox"
    assert_path_missing "$REPO_DIR/.config/dotfiles/agents.local.example"
    assert_path_missing "$REPO_DIR/bin/ha"
    assert_path_missing "$REPO_DIR/tests/test_agent.sh"
    assert_file_not_contains "$REPO_DIR/.config/wezterm/wezterm.lua" \
        'SpawnCommandInNewTab'
}

test_daily_shell_and_git_defaults_are_safe_and_pinned() {
    local zshrc="$REPO_DIR/.config/zsh/.zshrc"
    local aliases="$REPO_DIR/.config/zsh/aliases.zsh"
    local git_config="$REPO_DIR/.config/git/config"

    assert_file_contains "$zshrc" 'command -v zoxide > /dev/null 2>&1'
    assert_file_contains "$zshrc" '[ -n "${ZSH_VERSION:-}" ]'
    assert_file_contains "$zshrc" 'eval "$(zoxide init zsh)"'
    assert_file_contains "$aliases" 'gcof()'
    assert_file_contains "$aliases" 'git for-each-ref'
    assert_file_contains "$aliases" 'git switch -- "$branch"'
    assert_file_contains "$aliases" 'glogf()'
    assert_file_contains "$aliases" 'git log --oneline'
    assert_file_contains "$aliases" 'git show -- "${commit%% *}"'
    assert_file_contains "$aliases" '[ -t 0 ] && [ -t 1 ] || return 0'
    assert_file_not_contains "$aliases" 'eval'
    assert_file_contains "$git_config" '[fetch]'
    assert_file_contains "$git_config" 'name = romanohu'
    assert_file_contains "$git_config" 'email = 158289679+romanohu@users.noreply.github.com'
    assert_file_not_contains "$git_config" '@gmail.com'
    assert_file_contains "$git_config" 'prune = true'
    assert_file_contains "$git_config" '[rerere]'
    assert_file_contains "$git_config" 'enabled = true'
    assert_file_contains "$git_config" 'autoSetupRemote = true'
}

test_wezterm_has_portable_fonts_without_monitoring_layout() {
    local config="$REPO_DIR/.config/wezterm/wezterm.lua"

    assert_file_not_contains "$config" 'setup_monitoring_layout'
    assert_file_not_contains "$config" "{ key = 's', mods = 'LEADER'"
    assert_file_contains "$config" 'wezterm.font_with_fallback'
    assert_file_contains "$config" "'JetBrains Mono'"
    assert_file_contains "$config" "'Menlo'"
    assert_file_contains "$config" "'monospace'"
}

test_unused_shell_shortcuts_are_absent() {
    assert_file_not_contains "$REPO_DIR/.config/zsh/aliases.zsh" "alias memo_on="
}

test_wezterm_loads_private_ssh_bindings_from_local_config() {
    local config="$REPO_DIR/.config/wezterm/wezterm.lua"
    local example="$REPO_DIR/.config/wezterm/local.lua.example"

    assert_file_not_contains "$config" 'SSH:popssh'
    assert_file_not_contains "$config" 'SSH:duffy'
    assert_file_not_contains "$config" 'SSH:hibana'
    assert_file_not_contains "$config" 'SSH:omokage'
    assert_file_not_contains "$config" 'SSH:roko'
    assert_file_contains "$config" 'pcall(dofile'
    assert_file_contains "$config" '.config/wezterm/local.lua'
    assert_file_contains "$config" 'local_config.ssh_hosts'
    assert_file_contains "$config" "'SSH:' .. host.domain"
    assert_file_contains "$example" 'ssh_hosts'
    assert_file_contains "$example" 'example.invalid'
    assert_file_contains "$example" 'key ='
    assert_file_contains "$example" 'domain ='
    assert_file_contains "$example" 'label ='
    assert_file_not_contains "$example" 'popssh'
    assert_file_not_contains "$example" 'duffy'
    assert_file_not_contains "$example" 'hibana'
    assert_file_not_contains "$example" 'omokage'
    assert_file_not_contains "$example" 'roko'
}

test_tracked_private_state_and_historical_wezterm_hosts_are_absent() {
    local tracked_path

    while IFS= read -r tracked_path; do
        case "$tracked_path" in
            *auth*|*session*|*history*|*transcript*|*cache*|*projects*)
                fail "agent runtime state must not be tracked: $tracked_path"
                ;;
        esac
    done < <(git -C "$REPO_DIR" ls-files -- .codex .claude)

    if git -C "$REPO_DIR" grep -n -E 'SSH:(popssh|duffy|hibana|omokage|roko)' -- .config/wezterm; then
        fail 'tracked WezTerm configuration must not contain historical host bindings'
    fi
}

test_neovim_configuration_is_not_tracked
test_public_agent_guidance_excludes_runtime_state
test_shell_uses_mise_without_devbox_or_cargo_path
test_herdr_remains_without_ha_command
test_removed_paths_are_not_active
test_daily_shell_and_git_defaults_are_safe_and_pinned
test_wezterm_has_portable_fonts_without_monitoring_layout
test_unused_shell_shortcuts_are_absent
test_wezterm_loads_private_ssh_bindings_from_local_config
test_tracked_private_state_and_historical_wezterm_hosts_are_absent
printf 'PASS: %s\n' "$(basename "$0")"
