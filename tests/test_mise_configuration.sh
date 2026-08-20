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

mise_section_entries() {
    local file="$1"
    local section="$2"

    awk -v section="$section" '
        $0 == section { in_section = 1; next }
        in_section && /^\[/ { exit }
        in_section && /^[[:space:]]*[^#[:space:]][^=]*=/ {
            line = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            print line
        }
    ' "$file"
}

lock_url_sections_without_checksum() {
    awk '
        function emit() {
            if (section != "" && has_url && !has_checksum) print section
        }
        /^\[/ {
            emit()
            section = $0
            has_url = 0
            has_checksum = 0
            next
        }
        /^url = "https:/ { has_url = 1 }
        /^checksum = / { has_checksum = 1 }
        END { emit() }
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
        'bat = "0.26.1"' \
        'fd = "10.4.2"' \
        'gh = "2.89.0"' \
        'uv = "0.11.6"' \
        'tmux = "3.6a"' \
        '"github:Nukesor/pueue" = "4.0.4"' \
        'git-lfs = "3.7.1"' \
        '"cargo:dua-cli" = { version = "2.34.0", depends = ["rust"] }' \
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
    local lock="$REPO_DIR/mise.lock" platform expected actual checksum_shape

    expected=$(printf '%s\n' \
        $'bat\t0.26.1' \
        $'cargo:dua-cli\t2.34.0' \
        $'fd\t10.4.2' \
        $'fzf\t0.71.0' \
        $'gh\t2.89.0' \
        $'git-lfs\t3.7.1' \
        $'github:Nukesor/pueue\t4.0.4' \
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

    assert_eq '17' "$(grep -c '^\[\[tools\.' "$lock")" \
        'mise.lock must contain one entry per managed tool'
    for platform in linux-arm64 linux-x64 macos-arm64; do
        assert_eq '15' \
            "$(grep -c "platforms\\.$platform" "$lock")" \
            "all ordinary downloadable tools must lock $platform"
    done
    assert_eq '45' "$(grep -c '^url = "https://' "$lock")" \
        '15 ordinary downloadable tools times 3 platforms must have URLs'
    checksum_shape=$(awk '
        /^checksum = / {
            count++
            value = $0
            sub(/^checksum = "sha256:/, "", value)
            sub(/"$/, "", value)
            if (length(value) != 64 || value ~ /[^0-9a-f]/) invalid++
        }
        END { print count "\t" (invalid + 0) }
    ' "$lock")
    assert_eq $'42\t0' "$checksum_shape" \
        'mise.lock must contain exactly 42 valid lowercase SHA-256 checksums'
    expected=$(printf '%s\n' \
        '[tools.zoxide."platforms.linux-arm64"]' \
        '[tools.zoxide."platforms.linux-x64"]' \
        '[tools.zoxide."platforms.macos-arm64"]')
    actual=$(lock_url_sections_without_checksum "$lock")
    assert_eq "$expected" "$actual" \
        'only the three zoxide backend platform entries may omit checksums'
    assert_file_contains "$lock" '[[tools."cargo:dua-cli"]]'
    assert_file_contains "$lock" 'backend = "cargo:dua-cli"'
    assert_file_not_contains "$lock" '[tools."cargo:dua-cli"."platforms.'
    assert_file_not_contains "$lock" '[tools.rust."platforms.'
    assert_file_contains "$lock" '[[tools.rust]]'
    assert_file_contains "$lock" 'components = "clippy,rust-analyzer,rustfmt"'
    assert_file_contains "$lock" 'profile = "minimal"'
}

test_mise_bootstrap_repositories_dotfiles_and_settings_are_exact() {
    local expected actual

    expected=$(printf '%s\n' \
        '"~/.config/zsh/oh-my-zsh" = { url = "https://github.com/ohmyzsh/ohmyzsh.git", ref = "677a4592b18c08ddea737f8aca70bac0e9fc9313" }' \
        '"~/.config/zsh/custom/plugins/zsh-autosuggestions" = { url = "https://github.com/zsh-users/zsh-autosuggestions.git", ref = "85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5" }' \
        '"~/.config/zsh/custom/plugins/zsh-syntax-highlighting" = { url = "https://github.com/zsh-users/zsh-syntax-highlighting.git", ref = "1d85c692615a25fe2293bdd44b34c217d5d2bf04" }')
    actual=$(mise_section_entries "$REPO_DIR/mise.toml" '[bootstrap.repos]')
    assert_eq "$expected" "$actual" \
        '[bootstrap.repos] must contain exactly the approved repositories'

    expected=$(printf '%s\n' \
        '"~/.config/mise/config.toml" = "mise.toml"' \
        '"~/.config/mise/mise.lock" = "mise.lock"' \
        '"~/.zshenv" = ".zshenv"' \
        '"~/.config/git" = ".config/git"' \
        '"~/.config/herdr" = ".config/herdr"' \
        '"~/.config/zsh/.zshrc" = ".config/zsh/.zshrc"' \
        '"~/.config/zsh/aliases.zsh" = ".config/zsh/aliases.zsh"' \
        '"~/.config/wezterm/wezterm.lua" = ".config/wezterm/wezterm.lua"' \
        '"~/.codex/AGENTS.md" = ".codex/AGENTS.md"' \
        '"~/.claude/CLAUDE.md" = ".claude/CLAUDE.md"')
    actual=$(mise_section_entries "$REPO_DIR/mise.toml" '[dotfiles]')
    assert_eq "$expected" "$actual" \
        '[dotfiles] must contain exactly the approved mappings'
    assert_file_not_contains "$REPO_DIR/mise.toml" '--force-dotfiles'
    assert_file_not_contains "$REPO_DIR/mise.toml" 'eza'
    assert_file_contains "$REPO_DIR/mise.toml" \
        '"cargo:dua-cli" = { version = "2.34.0", depends = ["rust"] }'
    assert_file_contains "$REPO_DIR/mise.toml" 'min_version = "2026.8.9"'
    assert_file_contains "$REPO_DIR/mise.toml" 'locked = true'
    assert_file_contains "$REPO_DIR/mise.toml" \
        'lockfile_platforms = ["macos-arm64", "linux-x64", "linux-arm64"]'
    assert_file_contains "$REPO_DIR/mise.toml" 'task.run_auto_install = false'
    assert_file_contains "$REPO_DIR/mise.toml" 'dir = "{{cwd}}"'
    assert_file_not_contains "$REPO_DIR/mise.toml" 'latest'
}

test_global_mise_test_task_runs_from_repository() {
    [ "${DOTFILES_MISE_TASK_TEST_CHILD:-}" != 1 ] || return 0
    [ -n "${DOTFILES_TEST_MISE_BIN:-}" ] || return 0
    [ -n "${DOTFILES_TEST_MISE_HOME:-}" ] ||
        fail 'DOTFILES_TEST_MISE_HOME is required with DOTFILES_TEST_MISE_BIN'

    assert_path_missing "$DOTFILES_TEST_MISE_HOME/.local/share/mise/installs"
    (
        unset MISE_TASK_RUN_AUTO_INSTALL
        HOME="$DOTFILES_TEST_MISE_HOME" \
            MISE_GLOBAL_CONFIG_FILE="$REPO_DIR/mise.toml" \
            DOTFILES_MISE_TASK_TEST_CHILD=1 \
            "$DOTFILES_TEST_MISE_BIN" -C "$REPO_DIR" run test
    )
    assert_path_missing "$DOTFILES_TEST_MISE_HOME/.local/share/mise/installs"
}

test_mise_tools_are_exact_and_complete
test_mise_lock_has_supported_platform_artifacts
test_mise_bootstrap_repositories_dotfiles_and_settings_are_exact
test_global_mise_test_task_runs_from_repository
printf 'PASS: %s\n' "$(basename "$0")"
