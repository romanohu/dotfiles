#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$TEST_DIR/.." && pwd)

# shellcheck source=test_helpers.sh
. "$TEST_DIR/test_helpers.sh"

mise_tool_entries() {
    awk '
        $0 == "[tools]" { in_tools = 1; next }
        in_tools && /^\[/ { exit }
        in_tools && /^[[:space:]]*[^#[:space:]][^=]*=/ {
            line = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            print line
        }
    ' "$1"
}

mise_lock_tool_entries() {
    awk '
        /^\[\[tools\./ {
            name = $0
            sub(/^\[\[tools\./, "", name)
            sub(/\]\]$/, "", name)
            gsub(/^"|"$/, "", name)
            next
        }
        name != "" && /^version = "/ {
            version = $0
            sub(/^version = "/, "", version)
            sub(/"$/, "", version)
            print name "\t" version
            name = ""
        }
    ' "$1"
}

test_mise_tools_are_exact_and_complete() {
    local expected actual

    expected=$(printf '%s\n' \
        'starship = "1.24.2"' \
        'fzf = "0.71.0"' \
        'ripgrep = "15.1.0"' \
        '"github:eza-community/eza" = "0.23.4"' \
        'bat = "0.26.1"' \
        'fd = "10.4.2"' \
        'gh = "2.89.0"' \
        'uv = "0.11.6"' \
        'tmux = "3.6a"' \
        '"github:Nukesor/pueue" = "4.0.4"' \
        'git-lfs = "3.7.1"' \
        'dua = "2.34.0"' \
        'viddy = "1.3.0"' \
        'jq = "1.7.1"' \
        'node = "24.12.0"' \
        'zoxide = "0.9.8"' \
        'herdr = "0.7.5"' \
        'rust = { version = "1.97.1", profile = "minimal", components = "clippy,rustfmt,rust-analyzer" }')
    actual=$(mise_tool_entries "$REPO_DIR/mise.toml")
    assert_eq "$expected" "$actual" 'mise must manage the exact approved tool set'
}

test_mise_lock_has_supported_platform_artifacts() {
    local lock="$REPO_DIR/mise.lock" platform expected actual

    expected=$(printf '%s\n' \
        $'bat\t0.26.1' \
        $'dua\t2.34.0' \
        $'fd\t10.4.2' \
        $'fzf\t0.71.0' \
        $'gh\t2.89.0' \
        $'git-lfs\t3.7.1' \
        $'github:Nukesor/pueue\t4.0.4' \
        $'github:eza-community/eza\t0.23.4' \
        $'herdr\t0.7.5' \
        $'jq\t1.7.1' \
        $'node\t24.12.0' \
        $'ripgrep\t15.1.0' \
        $'rust\t1.97.1' \
        $'starship\t1.24.2' \
        $'tmux\t3.6a' \
        $'uv\t0.11.6' \
        $'viddy\t1.3.0' \
        $'zoxide\t0.9.8')
    actual=$(mise_lock_tool_entries "$lock")
    assert_eq "$expected" "$actual" \
        'mise.lock must pin the exact configured tool names and versions'

    assert_eq '18' "$(grep -c '^\[\[tools\.' "$lock")" \
        'mise.lock must contain one entry per managed tool'
    for platform in linux-arm64 linux-x64 macos-arm64; do
        assert_eq '17' \
            "$(grep -c "platforms\\.$platform" "$lock")" \
            "all downloadable tools must lock $platform"
    done
    assert_eq '51' "$(grep -c '^url = "https://' "$lock")" \
        '17 downloadable tools times 3 platforms must have URLs'
    assert_file_contains "$lock" '[[tools.rust]]'
    assert_file_contains "$lock" 'components = "clippy,rust-analyzer,rustfmt"'
    assert_file_contains "$lock" 'profile = "minimal"'
}

test_mise_bootstrap_repositories_dotfiles_and_settings_are_exact() {
    local mapping

    assert_file_contains "$REPO_DIR/mise.toml" \
        '"~/.config/zsh/oh-my-zsh" = { url = "https://github.com/ohmyzsh/ohmyzsh.git", ref = "677a4592b18c08ddea737f8aca70bac0e9fc9313" }'
    assert_file_contains "$REPO_DIR/mise.toml" \
        '"~/.config/zsh/custom/plugins/zsh-autosuggestions" = { url = "https://github.com/zsh-users/zsh-autosuggestions.git", ref = "85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5" }'
    assert_file_contains "$REPO_DIR/mise.toml" \
        '"~/.config/zsh/custom/plugins/zsh-syntax-highlighting" = { url = "https://github.com/zsh-users/zsh-syntax-highlighting.git", ref = "1d85c692615a25fe2293bdd44b34c217d5d2bf04" }'
    for mapping in \
        '"~/.config/mise/config.toml" = "mise.toml"' \
        '"~/.config/mise/mise.lock" = "mise.lock"' \
        '"~/.zshenv" = ".zshenv"' \
        '"~/.config/git" = ".config/git"' \
        '"~/.config/herdr" = ".config/herdr"' \
        '"~/.config/zsh/.zshrc" = ".config/zsh/.zshrc"' \
        '"~/.config/zsh/aliases.zsh" = ".config/zsh/aliases.zsh"' \
        '"~/.config/wezterm/wezterm.lua" = ".config/wezterm/wezterm.lua"' \
        '"~/.codex/AGENTS.md" = ".codex/AGENTS.md"' \
        '"~/.claude/CLAUDE.md" = ".claude/CLAUDE.md"'; do
        assert_file_contains "$REPO_DIR/mise.toml" "$mapping"
    done
    assert_file_not_contains "$REPO_DIR/mise.toml" '--force-dotfiles'
    assert_file_contains "$REPO_DIR/mise.toml" 'min_version = "2026.8.9"'
    assert_file_contains "$REPO_DIR/mise.toml" 'locked = true'
    assert_file_contains "$REPO_DIR/mise.toml" \
        'lockfile_platforms = ["macos-arm64", "linux-x64", "linux-arm64"]'
    assert_file_not_contains "$REPO_DIR/mise.toml" 'latest'
}

test_mise_tools_are_exact_and_complete
test_mise_lock_has_supported_platform_artifacts
test_mise_bootstrap_repositories_dotfiles_and_settings_are_exact
printf 'PASS: %s\n' "$(basename "$0")"
