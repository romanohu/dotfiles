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

test_ci_runs_only_host_independent_checks() {
    local workflow="$REPO_DIR/.github/workflows/validate.yml"

    assert_file_contains "$workflow" 'actions/checkout@v4.2.2'
    assert_file_contains "$workflow" 'bash tests/run.sh'
    assert_file_contains "$workflow" \
        'bash -n install.sh tests/test_helpers.sh tests/test_installer.sh tests/test_configuration.sh tests/test_mise_configuration.sh tests/test_runner.sh tests/run.sh'
    assert_file_contains "$workflow" \
        'zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh'
    assert_file_contains "$workflow" 'git diff --check'
    assert_file_not_contains "$workflow" 'devbox'
    assert_file_not_contains "$workflow" 'bin/ha'
    assert_file_not_contains "$workflow" 'jq empty'
    assert_file_not_contains "$workflow" 'mise install'
    assert_file_not_contains "$workflow" 'mise bootstrap'
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

test_readme_documents_mise_setup_and_boundaries() {
    local readme="$REPO_DIR/README.md"

    assert_file_contains "$readme" 'mise 2026.8.9'
    assert_file_contains "$readme" 'Git and Zsh'
    assert_file_contains "$readme" 'curl'
    assert_file_contains "$readme" 'tar'
    assert_file_contains "$readme" 'sha256sum or shasum'
    assert_file_contains "$readme" 'without root privileges'
    assert_file_contains "$readme" 'ABCI'
    assert_file_contains "$readme" './install.sh'
    assert_file_contains "$readme" 'bash tests/run.sh'
    assert_file_contains "$readme" 'mise run test'
    assert_file_contains "$readme" \
        'mise lock --platform macos-arm64,linux-x64,linux-arm64'
    assert_file_contains "$readme" 'mise install --locked'
    assert_file_contains "$readme" 'clippy'
    assert_file_contains "$readme" 'rustfmt'
    assert_file_contains "$readme" 'rust-analyzer'
    assert_file_contains "$readme" 'pueue 4.0.4'
    assert_file_contains "$readme" 'pueued 4.0.4'
    assert_file_contains "$readme" 'pueued -d'
    assert_file_contains "$readme" 'pueue status'
    assert_file_contains "$readme" \
        'The bootstrap installs the matching Pueue client and daemon but does not start a background service.'
    assert_file_contains "$readme" 'does not uninstall'
    assert_file_contains "$readme" 'conflict'
    assert_file_contains "$readme" '~/.profile'
    assert_file_contains "$readme" 'Herdr'
    assert_file_contains "$readme" 'OpenCode permissions'
    assert_file_contains "$readme" 'permission mode to'
    assert_file_contains "$readme" 'all eleven managed targets'
    assert_file_contains "$readme" \
        'Codex configuration and approval behavior remain user-owned'
    assert_eq '1' "$(grep -F -x -c -- \
        '`htop` is unmanaged by this repository.' "$readme")" \
        'README must identify htop, and only htop, as unmanaged'
    assert_eq '1' "$(grep -F -x -c -- \
        '`eza`, `hwloc`, `tree`, `xclip`, `nvtop`, and `navi` were removed and are not installation targets.' \
        "$readme")" \
        'README must list the exact removed tools, including eza, on one line'
    assert_eq '1' "$(grep -F -x -c -- \
        '`zoxide` is the backend-specific exception: its three locked platform URLs do not include checksums.' \
        "$readme")" \
        'README must document the three zoxide checksum exceptions exactly'
    assert_file_not_contains "$readme" 'devbox run'
    assert_file_not_contains "$readme" 'devbox install'
    assert_file_not_contains "$readme" 'NIX_INSTALLER'
    assert_file_not_contains "$readme" 'agents.local'
    assert_file_not_contains "$readme" '`ha`'
    assert_file_not_contains "$readme" 'local.lua'
    assert_file_not_contains "$readme" 'SSH'
    assert_file_contains "$readme" 'WezTerm visual settings'
}

test_removed_paths_are_not_active() {
    assert_path_missing "$REPO_DIR/.config/devbox"
    assert_path_missing "$REPO_DIR/.config/dotfiles/agents.local.example"
    assert_path_missing "$REPO_DIR/.config/wezterm/local.lua.example"
    assert_path_missing "$REPO_DIR/bin/ha"
    assert_path_missing "$REPO_DIR/tests/test_agent.sh"
    if grep -F -x -q -- '.config/wezterm/local.lua' "$REPO_DIR/.gitignore"; then
        fail 'WezTerm local configuration must not be ignored'
    fi
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

test_wezterm_keeps_portable_visual_and_startup_behavior() {
    local config="$REPO_DIR/.config/wezterm/wezterm.lua"

    assert_file_not_contains "$config" 'setup_monitoring_layout'
    assert_file_not_contains "$config" "{ key = 's', mods = 'LEADER'"
    assert_file_not_contains "$config" 'split_current_pane'
    assert_file_not_contains "$config" 'pane:split'
    assert_file_not_contains "$config" 'SplitPane'
    assert_file_not_contains "$config" "{ key = 'v', mods = 'LEADER',"
    assert_file_not_contains "$config" "{ key = 'b', mods = 'LEADER',"
    assert_file_not_contains "$config" 'ActivatePaneDirection'
    assert_file_not_contains "$config" 'pcall(dofile'
    assert_file_not_contains "$config" 'local_config'
    assert_file_not_contains "$config" 'local.lua'
    assert_file_not_contains "$config" 'ssh_hosts'
    assert_file_not_contains "$config" 'SpawnTab'
    assert_file_not_contains "$config" 'DomainName'
    assert_file_not_contains "$config" 'SSH:'
    assert_file_contains "$config" 'wezterm.font_with_fallback'
    assert_file_contains "$config" "'JetBrains Mono'"
    assert_file_contains "$config" "'Menlo'"
    assert_file_contains "$config" "'monospace'"
    assert_file_contains "$config" "{ key = 'c', mods = 'LEADER', action = act.QuickSelect }"
    assert_file_contains "$config" 'wezterm.on("gui-startup"'
    assert_file_contains "$config" 'mux.spawn_window'
    assert_file_contains "$config" 'window:gui_window():maximize()'
}

test_opencode_default_permission_is_shared() {
    local config="$REPO_DIR/.config/opencode/opencode.jsonc"
    local expected

    expected=$(printf '%s\n' \
        '{' \
        '  "$schema": "https://opencode.ai/config.json",' \
        '  "plugin": ["superpowers@git+https://github.com/obra/superpowers.git"],' \
        '  "permission": "allow"' \
        '}')
    assert_path_exists "$config"
    assert_eq "$expected" "$(cat "$config")" \
        'OpenCode config must preserve the plugin and set allow permissions'
    assert_file_not_contains "$config" 'approval_policy'
    assert_file_not_contains "$config" 'sandbox_mode'
}

test_unused_shell_shortcuts_are_absent() {
    assert_file_not_contains "$REPO_DIR/.config/zsh/aliases.zsh" "alias memo_on="
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

test_vscode_lightweight_settings_are_exact_and_personal_state_free() {
    local settings="$REPO_DIR/.config/vscode/settings.json"
    local expected

    expected=$(printf '%s\n' \
        '{' \
        '  "files.watcherExclude": {' \
        '    "**/.git/objects/**": true,' \
        '    "**/node_modules/**": true,' \
        '    "**/target/**": true,' \
        '    "**/.venv/**": true,' \
        '    "**/.cache/**": true,' \
        '    "**/dist/**": true,' \
        '    "**/build/**": true' \
        '  },' \
        '  "search.exclude": {' \
        '    "**/.git/objects/**": true,' \
        '    "**/node_modules/**": true,' \
        '    "**/target/**": true,' \
        '    "**/.venv/**": true,' \
        '    "**/.cache/**": true,' \
        '    "**/dist/**": true,' \
        '    "**/build/**": true' \
        '  },' \
        '  "editor.minimap.enabled": false,' \
        '  "breadcrumbs.enabled": false,' \
        '  "editor.codeLens": false,' \
        '  "workbench.startupEditor": "none"' \
        '}')

    assert_path_exists "$settings"
    assert_eq "$expected" "$(cat "$settings")" \
        'VS Code settings must remain the exact lightweight JSON contract'
    assert_eq '0a' "$(tail -c 1 "$settings" | od -An -t x1 | tr -d '[:space:]')" \
        'VS Code settings must end with a newline'
    if [ "$(tail -c 2 "$settings" | od -An -t x1 | tr -d '[:space:]')" = '0a0a' ]; then
        fail 'VS Code settings must end with exactly one newline'
    fi
    assert_file_not_contains "$settings" 'remote.SSH'
    assert_file_not_contains "$settings" 'github.copilot'
    assert_file_not_contains "$settings" 'password'
    assert_file_not_contains "$settings" 'token'
    assert_file_not_contains "$settings" 'hostname'
}

test_readme_documents_vscode_lightweight_scope() {
    local readme="$REPO_DIR/README.md"

    assert_file_contains "$readme" 'VS Code lightweight settings'
    assert_file_contains "$readme" 'files.watcherExclude'
    assert_file_contains "$readme" 'search.exclude'
    assert_file_contains "$readme" 'minimap'
    assert_file_contains "$readme" 'breadcrumbs'
    assert_file_contains "$readme" 'CodeLens'
    assert_file_contains "$readme" 'Profile'
    assert_file_contains "$readme" 'manual'
    assert_file_contains "$readme" 'connection settings'
    assert_file_contains "$readme" 'User directory'
    assert_file_contains "$readme" 'does not delete VS Code cache'
}

test_neovim_configuration_is_not_tracked
test_public_agent_guidance_excludes_runtime_state
test_shell_uses_mise_without_devbox_or_cargo_path
test_ci_runs_only_host_independent_checks
test_herdr_remains_without_ha_command
test_readme_documents_mise_setup_and_boundaries
test_removed_paths_are_not_active
test_daily_shell_and_git_defaults_are_safe_and_pinned
test_wezterm_keeps_portable_visual_and_startup_behavior
test_opencode_default_permission_is_shared
test_unused_shell_shortcuts_are_absent
test_tracked_private_state_and_historical_wezterm_hosts_are_absent
test_vscode_lightweight_settings_are_exact_and_personal_state_free
test_readme_documents_vscode_lightweight_scope
printf 'PASS: %s\n' "$(basename "$0")"
