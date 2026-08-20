# Mise-Only Dotfiles Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the repository's Nix/Devbox and `ha` paths with one rootless, exact-version mise bootstrap for macOS and Linux.

**Architecture:** A pinned and SHA-verified `install.sh` installs only mise, removes narrowly proven legacy links, and delegates repositories, dotfile links, and tools to one root `mise.toml`. A tracked `mise.lock` covers macOS ARM64, Linux x86_64, and Linux ARM64; shell activation uses mise shims and `mise activate zsh`.

**Tech Stack:** Bash, Zsh, TOML, mise `2026.8.9`, Git, GitHub Actions, shell-based offline tests.

## Global Constraints

- Support macOS and Linux only; native Windows is out of scope.
- Assume Git and Zsh are already installed; require Bash, curl, tar, and a
  SHA-256 utility for bootstrap; never invoke a system package manager or sudo.
- Install mise `2026.8.9` from `https://github.com/jdx/mise/releases/download/v2026.8.9/install.sh` with SHA-256 `0947cf3dd1eb5d734676a554b4bb8298f8557ffc706f5ed5637e9e68e1218403`.
- Keep exact tool versions and lock `macos-arm64`, `linux-x64`, and `linux-arm64`.
- Manage exactly 17 tools; do not manage `git`, `zsh`, `htop`, `hwloc`, `tree`, `xclip`, `nvtop`, `navi`, or `eza`.
- Manage Rust `1.97.1` with the minimal profile and `clippy,rustfmt,rust-analyzer`.
- Keep Herdr `0.7.5`; remove `ha` and every active `ha` integration.
- Do not uninstall Nix, Devbox, `htop`, or any system software.
- Do not edit `~/.profile` automatically.
- Refuse unmanaged dotfile conflicts; never pass `--force-dotfiles` or create automatic backups.
- Keep `bash tests/run.sh` offline and independent of mise, Nix, Devbox, the network, and host tool versions.
- Preserve current public Codex/Claude guidance and machine-local WezTerm state.

## File Structure

### Create

- `mise.toml` — sole tool, repository, dotfile, and test-task configuration.
- `mise.lock` — generated three-platform tool artifact lock.
- `tests/test_mise_configuration.sh` — offline validation of `mise.toml` and `mise.lock`.

### Replace or substantially rewrite

- `install.sh` — verified mise bootstrapper and narrow legacy-link cleanup only.
- `tests/test_installer.sh` — focused tests for the new installer contract.
- `tests/test_configuration.sh` — active shell, Herdr, WezTerm, Git, documentation, and CI invariants.
- `README.md` — mise-only setup and maintenance guide.

### Modify

- `.zshenv` — mise binary and shim paths.
- `.config/zsh/.zshrc` — pinned repository layout and mise activation.
- `.config/zsh/aliases.zsh` — remove the Devbox alias.
- `.config/herdr/config.toml` — remove the `ha` command block.
- `.config/wezterm/wezterm.lua` — remove the obsolete command-launch shortcut.
- `.config/git/ignore` — remove Nix/Devbox patterns.
- `.gitignore` — remove Devbox and agent-launcher state patterns.
- `tests/run.sh` — add the mise test explicitly and remove the agent test.
- `tests/test_runner.sh` — replace inherited Devbox-state coverage with mise-global isolation coverage.
- `.github/workflows/validate.yml` — remove deleted files and JSON checks.

### Delete

- `.config/devbox/global/devbox.json`
- `.config/devbox/global/devbox.lock`
- `.config/devbox/global/run-tests.sh`
- `.config/dotfiles/agents.local.example`
- `bin/ha`
- `tests/test_agent.sh`

---

### Task 1: Add the declarative mise configuration and lockfile

**Files:**
- Create: `mise.toml`
- Create: `mise.lock`
- Create: `tests/test_mise_configuration.sh`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: none.
- Produces: root `mise.toml`, root `mise.lock`, and the exact paths/constants later installer and shell tasks rely on.

- [ ] **Step 1: Write the failing mise configuration test**

Create `tests/test_mise_configuration.sh` with the existing helper bootstrap and a section extractor that only accepts assignment lines directly under `[tools]`:

```bash
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
```

Add tests that compare the complete `[tools]` output, verify repository refs and dotfile mappings, and check the lockfile shape:

```bash
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
    local lock="$REPO_DIR/mise.lock" platform expected actual

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
    assert_file_contains "$lock" '[[tools."cargo:dua-cli"]]'
    assert_file_contains "$lock" 'backend = "cargo:dua-cli"'
    assert_file_not_contains "$lock" '[tools."cargo:dua-cli"."platforms.'
    assert_file_not_contains "$lock" '[tools.rust."platforms.'
    assert_file_contains "$lock" '[[tools.rust]]'
    assert_file_contains "$lock" 'components = "clippy,rust-analyzer,rustfmt"'
    assert_file_contains "$lock" 'profile = "minimal"'
}
```

Add a separate test that asserts all three repository destinations, URLs, and
full commit refs, plus all ten dotfile mappings shown in Step 3. It must also
reject forced overwrite behavior:

```bash
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
assert_file_not_contains "$REPO_DIR/mise.toml" 'eza'
assert_file_contains "$REPO_DIR/mise.toml" \
    '"cargo:dua-cli" = { version = "2.34.0", depends = ["rust"] }'
```

Also assert the global settings:

```bash
assert_file_contains "$REPO_DIR/mise.toml" 'min_version = "2026.8.9"'
assert_file_contains "$REPO_DIR/mise.toml" 'locked = true'
assert_file_contains "$REPO_DIR/mise.toml" \
    'lockfile_platforms = ["macos-arm64", "linux-x64", "linux-arm64"]'
assert_file_contains "$REPO_DIR/mise.toml" \
    '"~/.config/mise/config.toml" = "mise.toml"'
assert_file_contains "$REPO_DIR/mise.toml" \
    '"~/.config/mise/mise.lock" = "mise.lock"'
assert_file_not_contains "$REPO_DIR/mise.toml" 'latest'
```

List every test function explicitly at the bottom, then print the existing
`PASS: <filename>` line. Add this test to both the ordered list and duplicate
suppression case in `tests/run.sh`.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
bash tests/test_mise_configuration.sh
```

Expected: FAIL because `mise.toml` and `mise.lock` do not exist.

- [ ] **Step 3: Create the exact root `mise.toml`**

Create this configuration:

```toml
min_version = "2026.8.9"

[settings]
lockfile = true
locked = true
lockfile_platforms = ["macos-arm64", "linux-x64", "linux-arm64"]
dotfiles.default_mode = "symlink"

[tools]
starship = "1.24.2"
fzf = "0.71.0"
ripgrep = "15.1.0"
bat = "0.26.1"
fd = "10.4.2"
gh = "2.89.0"
uv = "0.11.6"
tmux = "3.6a"
"github:Nukesor/pueue" = "4.0.4"
git-lfs = "3.7.1"
"cargo:dua-cli" = { version = "2.34.0", depends = ["rust"] }
viddy = "1.3.0"
jq = "1.7.1"
node = "24.12.0"
zoxide = "0.9.8"
herdr = "0.7.5"
rust = { version = "1.97.1", profile = "minimal", components = "clippy,rustfmt,rust-analyzer" }

[bootstrap.repos]
"~/.config/zsh/oh-my-zsh" = { url = "https://github.com/ohmyzsh/ohmyzsh.git", ref = "677a4592b18c08ddea737f8aca70bac0e9fc9313" }
"~/.config/zsh/custom/plugins/zsh-autosuggestions" = { url = "https://github.com/zsh-users/zsh-autosuggestions.git", ref = "85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5" }
"~/.config/zsh/custom/plugins/zsh-syntax-highlighting" = { url = "https://github.com/zsh-users/zsh-syntax-highlighting.git", ref = "1d85c692615a25fe2293bdd44b34c217d5d2bf04" }

[dotfiles]
"~/.config/mise/config.toml" = "mise.toml"
"~/.config/mise/mise.lock" = "mise.lock"
"~/.zshenv" = ".zshenv"
"~/.config/git" = ".config/git"
"~/.config/herdr" = ".config/herdr"
"~/.config/zsh/.zshrc" = ".config/zsh/.zshrc"
"~/.config/zsh/aliases.zsh" = ".config/zsh/aliases.zsh"
"~/.config/wezterm/wezterm.lua" = ".config/wezterm/wezterm.lua"
"~/.codex/AGENTS.md" = ".codex/AGENTS.md"
"~/.claude/CLAUDE.md" = ".claude/CLAUDE.md"

[tasks.test]
run = "bash tests/run.sh"
```

Do not add `[bootstrap.packages]`, `[bootstrap.mise_shell_activate]`, or a
`bootstrap` task.

- [ ] **Step 4: Generate the three-platform lockfile**

Create a temporary generator with the pinned installer. Verify the installer
before executing it, then verify the installed binary before using it:

```bash
MISE_GENERATOR_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-mise-generator.XXXXXX")
MISE_GENERATOR_INSTALLER="$MISE_GENERATOR_ROOT/install.sh"
MISE_GENERATOR_BIN="$MISE_GENERATOR_ROOT/mise"
curl --fail --location --silent --show-error \
    --output "$MISE_GENERATOR_INSTALLER" \
    https://github.com/jdx/mise/releases/download/v2026.8.9/install.sh
if command -v sha256sum > /dev/null 2>&1; then
    MISE_GENERATOR_SHA=$(sha256sum "$MISE_GENERATOR_INSTALLER" | awk '{ print $1 }')
else
    MISE_GENERATOR_SHA=$(shasum -a 256 "$MISE_GENERATOR_INSTALLER" | awk '{ print $1 }')
fi
test "$MISE_GENERATOR_SHA" = \
    0947cf3dd1eb5d734676a554b4bb8298f8557ffc706f5ed5637e9e68e1218403
MISE_INSTALL_PATH="$MISE_GENERATOR_BIN" bash "$MISE_GENERATOR_INSTALLER"
test "$("$MISE_GENERATOR_BIN" --version | awk 'NR == 1 { print $1 }')" = 2026.8.9
MISE_GLOBAL_CONFIG_FILE="$PWD/mise.toml" MISE_LOCKED=0 \
    "$MISE_GENERATOR_BIN" -C "$PWD" lock \
    --platform macos-arm64,linux-x64,linux-arm64
MISE_GLOBAL_CONFIG_FILE="$PWD/mise.toml" \
    "$MISE_GENERATOR_BIN" -C "$PWD" config ls
MISE_GLOBAL_CONFIG_FILE="$PWD/mise.toml" \
    "$MISE_GENERATOR_BIN" -C "$PWD" install --locked --dry-run
```

Expected summary:

```text
Processing 17 tool(s)
Lockfile written to .../mise.lock
```

Inspect the diff. It must contain 17 tool entries, 45 platform URLs for the 15
ordinary downloadable tools, no `navi` or `eza`, and the Rust options. The
Cargo-built `dua` and Rust entries are explicit no-platform-URL exceptions. Do
not hand-edit resolved URLs or checksums.

- [ ] **Step 5: Run the focused tests and static TOML validation**

Run:

```bash
bash tests/test_mise_configuration.sh
```

Expected: the test exits 0. Together with Step 4, this proves that the tracked
configuration parses, the dry run lists all 17 exact versions, and no locked
artifact URL is missing.

- [ ] **Step 6: Commit the declarative configuration**

```bash
git add mise.toml mise.lock tests/test_mise_configuration.sh tests/run.sh
git commit -m "feat: add pinned mise configuration"
```

---

### Task 2: Replace the installer with a verified mise bootstrapper

**Files:**
- Modify: `install.sh`
- Modify: `tests/test_installer.sh`

**Interfaces:**
- Consumes: root `mise.toml` and `mise.lock` from Task 1.
- Produces: `preflight_required_commands`, `sha256_file`, `verify_sha256`, `run_verified_installer`, `install_mise_if_needed`, `cleanup_legacy_managed_links`, `run_mise_bootstrap`, and `main` Bash functions.

- [ ] **Step 1: Replace obsolete installer tests with the new contract**

Keep the source-guard, SHA-256, verified-download, signal-cleanup, preflight,
target-home, and exact-link safety coverage. Delete all tests for Nix, Devbox,
custom dotfile linking/backups, and custom pinned Git checkout concurrency.

The new file must include these focused tests:

```bash
test_install_script_has_source_guard
test_verify_sha256_accepts_match_and_rejects_mismatch
test_sha256_file_rejects_symlinks_and_option_like_paths
test_verified_installer_executes_only_after_hash_match
test_verified_installer_cleans_temporary_directory_on_failure
test_verified_installer_cleans_temporary_directory_on_signal
test_preflight_failure_prevents_main_mutations
test_mise_install_passes_exact_url_hash_and_destination
test_mise_install_requires_exact_version_after_install
test_bootstrap_uses_exact_binary_target_home_and_root_config
test_only_exact_legacy_links_are_removed
test_regular_files_and_unrelated_links_are_preserved
test_invalid_source_or_target_home_fails_before_mutation
```

For the bootstrap call, create a fake executable at `$MISE_BIN` that records
the environment and argv:

```bash
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s|%s|%s\n" "$HOME" "$MISE_GLOBAL_CONFIG_FILE" "$*" >> "$MISE_CALLS"' \
    > "$MISE_BIN"
chmod +x "$MISE_BIN"

MISE_CALLS="$calls" run_mise_bootstrap

assert_file_contains "$calls" \
    "$target_home|$physical_repo/mise.toml|trust --yes $physical_repo/mise.toml"
assert_file_contains "$calls" \
    "$target_home|$physical_repo/mise.toml|-C $physical_repo --locked bootstrap --yes"
```

For the installer pin, override `run_verified_installer` so it records all
arguments and writes an executable fake mise that prints
`2026.8.9 macos-arm64 (2026-08-19)` for `--version`. Assert the exact URL,
digest, `MISE_INSTALL_PATH`, and absence of Nix/Devbox calls.

- [ ] **Step 2: Run the installer test and verify RED**

Run:

```bash
bash tests/test_installer.sh
```

Expected: FAIL because the old installer has no mise constants or bootstrap
functions.

- [ ] **Step 3: Replace `install.sh` with the thin implementation**

Use this public shape and exact constants:

```bash
#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DOT_DIR=$(CDPATH= cd -P -- "$SOURCE_DIR" && pwd -P)
TARGET_HOME="${DOTFILES_TARGET_HOME:-$HOME}"
MISE_VERSION="2026.8.9"
MISE_INSTALLER_URL="https://github.com/jdx/mise/releases/download/v2026.8.9/install.sh"
MISE_INSTALLER_SHA256="0947cf3dd1eb5d734676a554b4bb8298f8557ffc706f5ed5637e9e68e1218403"
MISE_BIN="$TARGET_HOME/.local/bin/mise"
```

Implement these exact responsibilities:

```bash
preflight_required_commands() {
    local required
    for required in bash curl git tar zsh; do
        has_cmd "$required" || fail "Required command not found: $required. Install it and rerun."
    done
    if ! has_cmd sha256sum && ! has_cmd shasum; then
        fail 'Required SHA-256 tool not found. Install sha256sum or shasum and rerun.'
    fi
}

install_mise_if_needed() {
    local installed_version=''
    if [ -x "$MISE_BIN" ]; then
        installed_version=$("$MISE_BIN" --version 2>/dev/null | awk 'NR == 1 { print $1 }')
    fi
    if [ "$installed_version" != "$MISE_VERSION" ]; then
        mkdir -p "$TARGET_HOME/.local/bin"
        MISE_INSTALL_PATH="$MISE_BIN" \
            run_verified_installer "$MISE_INSTALLER_URL" "$MISE_INSTALLER_SHA256"
    fi
    installed_version=$("$MISE_BIN" --version 2>/dev/null | awk 'NR == 1 { print $1 }')
    [ "$installed_version" = "$MISE_VERSION" ] || \
        fail "mise version mismatch: expected $MISE_VERSION, got ${installed_version:-unknown}."
}

run_mise_bootstrap() {
    HOME="$TARGET_HOME" MISE_GLOBAL_CONFIG_FILE="$DOT_DIR/mise.toml" \
        "$MISE_BIN" trust --yes "$DOT_DIR/mise.toml"
    HOME="$TARGET_HOME" MISE_GLOBAL_CONFIG_FILE="$DOT_DIR/mise.toml" \
        "$MISE_BIN" -C "$DOT_DIR" --locked bootstrap --yes
}
```

`run_verified_installer` must run in a subshell, create one private `mktemp -d`
directory, install `EXIT`, `HUP`, `INT`, and `TERM` cleanup traps, download with
`curl --fail --location --silent --show-error --output`, reject non-regular or
symlinked payloads, verify the digest, and only then execute:

```bash
MISE_INSTALL_PATH="$MISE_BIN" bash "$installer_path"
```

Implement `remove_exact_managed_link LINK EXPECTED...` and call it only for:

- `$TARGET_HOME/.local/bin/ha` pointing to `$DOT_DIR/bin/ha`;
- `$TARGET_HOME/.config/devbox` pointing to `$DOT_DIR/.config/devbox`;
- `$TARGET_HOME/.local/share/devbox/global/default` pointing to either
  `$TARGET_HOME/.config/devbox/global` or
  `$DOT_DIR/.config/devbox/global`;
- `$TARGET_HOME/.config/nvim` pointing to `$DOT_DIR/.config/nvim`; and
- `$TARGET_HOME/.config/zsh/pet.zsh` pointing to
  `$DOT_DIR/.config/zsh/pet.zsh`.

Keep those calls in one explicit function:

```bash
cleanup_legacy_managed_links() {
    remove_exact_managed_link \
        "$TARGET_HOME/.local/bin/ha" "$DOT_DIR/bin/ha" || return 1
    remove_exact_managed_link \
        "$TARGET_HOME/.config/devbox" "$DOT_DIR/.config/devbox" || return 1
    remove_exact_managed_link \
        "$TARGET_HOME/.local/share/devbox/global/default" \
        "$TARGET_HOME/.config/devbox/global" \
        "$DOT_DIR/.config/devbox/global" || return 1
    remove_exact_managed_link \
        "$TARGET_HOME/.config/nvim" "$DOT_DIR/.config/nvim" || return 1
    remove_exact_managed_link \
        "$TARGET_HOME/.config/zsh/pet.zsh" \
        "$DOT_DIR/.config/zsh/pet.zsh" || return 1
}
```

Never remove a regular file, real directory, or unmatched symlink. `main` runs
preflight, validates source/target directories and supported OS, installs mise,
cleans legacy links, and runs the bootstrap in that order. Retain the
`BASH_SOURCE[0] == "$0"` source guard.

- [ ] **Step 4: Run focused installer tests**

Run:

```bash
bash tests/test_installer.sh
bash -n install.sh tests/test_installer.sh
```

Expected: PASS and no Nix/Devbox command is executed.

- [ ] **Step 5: Commit the installer replacement**

```bash
git add install.sh tests/test_installer.sh
git commit -m "feat: bootstrap dotfiles with pinned mise"
```

---

### Task 3: Switch active configuration to mise and remove legacy packages and `ha`

**Files:**
- Modify: `.zshenv`
- Modify: `.config/zsh/.zshrc`
- Modify: `.config/zsh/aliases.zsh`
- Modify: `.config/herdr/config.toml`
- Modify: `.config/wezterm/wezterm.lua`
- Modify: `.config/git/ignore`
- Modify: `.gitignore`
- Modify: `tests/test_configuration.sh`
- Modify: `tests/run.sh`
- Modify: `tests/test_runner.sh`
- Delete: `.config/devbox/global/devbox.json`
- Delete: `.config/devbox/global/devbox.lock`
- Delete: `.config/devbox/global/run-tests.sh`
- Delete: `.config/dotfiles/agents.local.example`
- Delete: `bin/ha`
- Delete: `tests/test_agent.sh`

**Interfaces:**
- Consumes: `[bootstrap.repos]`, `[dotfiles]`, and `[tools]` from Task 1; installer target-home behavior from Task 2.
- Produces: the final active shell/Herdr/WezTerm configuration and a Devbox/`ha`-free test runner.

- [ ] **Step 1: Rewrite configuration assertions for the approved state**

Remove the Devbox manifest/lock helpers and tests. Replace stale guidance,
Herdr, shell, and WezTerm assertions with these invariants:

```bash
test_public_agent_guidance_excludes_runtime_state() {
    local guidance
    for guidance in "$REPO_DIR/.codex/AGENTS.md" "$REPO_DIR/.claude/CLAUDE.md"; do
        assert_file_contains "$guidance" 'Prefer the smallest change'
        assert_file_contains "$guidance" 'Minimize the Git diff'
        assert_file_contains "$guidance" 'Preserve existing structure'
        assert_file_not_contains "$guidance" 'https://'
        assert_file_not_contains "$guidance" '/Users/'
    done
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
```

Retain the valuable Git helper, private WezTerm, Neovim absence, Codex/Claude
allowlist, and no-secret assertions. Remove README and CI assertions until
Tasks 4 and 5 add their final forms.

Update `tests/test_runner.sh` so its inherited-environment regression exports
an unrelated `MISE_GLOBAL_CONFIG_FILE` instead of `DEVBOX_DATA_DIR` and confirms
the installer tests still pass.

- [ ] **Step 2: Run the configuration tests and verify RED**

Run:

```bash
bash tests/test_configuration.sh
```

Expected: FAIL on the old Devbox shell block, `ha` Herdr command, or still
present Devbox tree.

- [ ] **Step 3: Apply the shell and UI configuration changes**

Make `.zshenv` contain one PATH export:

```zsh
export TZ=Asia/Tokyo
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export ZDOTDIR="$HOME/.config/zsh"
```

In `.zshrc`:

```zsh
export ZSH="$HOME/.config/zsh/oh-my-zsh"
export ZSH_CUSTOM="$HOME/.config/zsh/custom"
ZSH_THEME="robbyrussell"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
```

Move the existing Homebrew OS block before activation, replace the Devbox block
with:

```zsh
if command -v mise > /dev/null 2>&1; then
    eval "$(mise activate zsh)"
fi
```

Keep Starship and zoxide initialization after mise activation. Keep existing
history options and alias sourcing. Delete only the `cddev` alias from
`aliases.zsh`.

Remove the full `[[keys.command]]` block from Herdr while preserving
`onboarding`, `[terminal]`, and `[ui]`. Remove only the `LEADER|SHIFT` `N`
`SpawnCommandInNewTab` entry from WezTerm.

- [ ] **Step 4: Delete legacy files and active ignore entries**

Delete the six paths listed in this task. In `tests/run.sh`, remove
`test_agent.sh` from both the ordered list and duplicate suppression case.

Remove these root ignore entries:

```text
.config/devbox/global/.devbox/
.config/dotfiles/agents.local
.config/dotfiles/agents.state/
.config/dotfiles/agent-state/
```

Remove this block from `.config/git/ignore`:

```text
# Devbox / Nix
.devbox/
.nix-profile/
```

Do not remove `.worktrees/`, agent-guidance allowlists, WezTerm local config, or
the general Windows filesystem ignore entries.

- [ ] **Step 5: Run configuration, runner, and shell checks**

Run:

```bash
bash tests/test_configuration.sh
bash tests/test_runner.sh
zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
```

Expected: PASS.

- [ ] **Step 6: Commit the active configuration migration**

```bash
git add -A .zshenv .config .gitignore bin tests
git commit -m "refactor: remove devbox and ha configuration"
```

---

### Task 4: Align CI with the host-independent mise repository tests

**Files:**
- Modify: `.github/workflows/validate.yml`
- Modify: `tests/test_configuration.sh`

**Interfaces:**
- Consumes: final script and test filenames from Tasks 1–3.
- Produces: CI that validates the repository without installing mise or managed tools.

- [ ] **Step 1: Add a failing exact-workflow assertion**

Add this test to `tests/test_configuration.sh`:

```bash
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
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
bash tests/test_configuration.sh
```

Expected: FAIL because the workflow still names deleted Devbox and `ha` files.

- [ ] **Step 3: Replace the validation command list**

Use this workflow body while keeping the pinned checkout action:

```yaml
name: Validate

on:
  push:
  pull_request:

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4.2.2
      - run: |
          bash tests/run.sh
          bash -n install.sh tests/test_helpers.sh tests/test_installer.sh tests/test_configuration.sh tests/test_mise_configuration.sh tests/test_runner.sh tests/run.sh
          zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
          git diff --check
```

- [ ] **Step 4: Run the full offline suite**

Run:

```bash
bash tests/run.sh
bash -n install.sh tests/*.sh
zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
git diff --check
```

Expected: PASS for every command.

- [ ] **Step 5: Commit the CI migration**

```bash
git add .github/workflows/validate.yml tests/test_configuration.sh
git commit -m "ci: validate mise-only dotfiles"
```

---

### Task 5: Rewrite setup and maintenance documentation

**Files:**
- Modify: `README.md`
- Modify: `tests/test_configuration.sh`

**Interfaces:**
- Consumes: final commands, versions, limitations, and paths from Tasks 1–4.
- Produces: the user-facing macOS/Linux/ABCI setup and update contract.

- [ ] **Step 1: Add failing documentation assertions**

Add a focused README test that requires the new workflow and forbids the old
one:

```bash
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
    assert_file_contains "$readme" 'mise run test'
    assert_file_contains "$readme" \
        'mise lock --platform macos-arm64,linux-x64,linux-arm64'
    assert_file_contains "$readme" 'mise install --locked'
    assert_file_contains "$readme" 'clippy'
    assert_file_contains "$readme" 'rustfmt'
    assert_file_contains "$readme" 'rust-analyzer'
    assert_file_contains "$readme" 'does not uninstall'
    assert_file_contains "$readme" 'conflict'
    assert_file_contains "$readme" '~/.profile'
    assert_file_contains "$readme" 'Herdr'
    assert_file_not_contains "$readme" 'devbox run'
    assert_file_not_contains "$readme" 'devbox install'
    assert_file_not_contains "$readme" 'NIX_INSTALLER'
    assert_file_not_contains "$readme" 'agents.local'
    assert_file_not_contains "$readme" '`ha`'
}
```

Also assert that the README names `htop` as unmanaged and lists `hwloc`,
`tree`, `xclip`, `nvtop`, and `navi` as removed rather than install targets.

- [ ] **Step 2: Run the documentation test and verify RED**

Run:

```bash
bash tests/test_configuration.sh
```

Expected: FAIL on the old Nix/Devbox commands.

- [ ] **Step 3: Rewrite `README.md` around mise**

Use this section order:

```text
# dotfiles
## Requirements
## Install
## Supported and managed tools
## ABCI and other managed Linux hosts
## Existing-file conflicts
## Shell and Herdr usage
## Local WezTerm settings
## Tests
## Updating pins
## Rust notes
## Repository layout
```

The installation flow must be:

```bash
git clone <repository-url> ~/dotfiles
cd ~/dotfiles
./install.sh
exec zsh
```

Explain that Git and Zsh are preinstalled prerequisites and that Bash, curl,
tar, and either `sha256sum` or `shasum` are bootstrap requirements. mise is
installed under `~/.local/bin`, and no sudo/root path is used. For ABCI, say to
run the bootstrap in an interactive compute environment according to site
policy after the Zsh request is approved; do not claim support for changing the
login shell.

List the 17 managed tools and exact Rust components. State explicitly:

- `htop` is unmanaged;
- `hwloc`, `tree`, `xclip`, `nvtop`, and `navi` were removed;
- existing system copies are not uninstalled;
- existing Nix and Devbox installations are not uninstalled; and
- an unmanaged dotfile conflict stops bootstrap and must be moved or backed up
  manually before rerunning.

Document these update commands:

```bash
mise lock --platform macos-arm64,linux-x64,linux-arm64
mise install --locked
mise run test
```

Document that mise's core Rust backend uses rustup and does not add Rust
distribution URL/checksum entries to `mise.lock`. Give a manual, review-first
procedure for stale profile lines:

```bash
cp ~/.profile ~/.profile.dotfiles-backup
${EDITOR:-vi} ~/.profile
```

Tell the user to remove only a line that sources a nonexistent old rustup env;
never instruct `install.sh` to edit it. Keep the local WezTerm example and
Herdr launch/update guidance, but remove WezTerm's removed Herdr shortcut and
all `ha`/`agents.local` guidance.

- [ ] **Step 4: Run documentation and full offline tests**

Run:

```bash
bash tests/test_configuration.sh
bash tests/run.sh
git diff --check
```

Expected: PASS.

- [ ] **Step 5: Commit the documentation**

```bash
git add README.md tests/test_configuration.sh
git commit -m "docs: document mise-only bootstrap"
```

---

### Task 6: Perform strict-lock and isolated-home verification

**Files:**
- Modify only if verification exposes a defect: files already owned by Tasks 1–5.

**Interfaces:**
- Consumes: completed mise-only repository.
- Produces: evidence that static, dry-run, idempotency, conflict, and version checks pass.

- [ ] **Step 1: Run all offline and static checks from a clean shell**

Run:

```bash
bash tests/run.sh
bash -n install.sh tests/*.sh
zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
git diff --check
```

Expected: every command exits 0.

- [ ] **Step 2: Validate mise parsing and strict lock resolution**

Create an isolated configuration home, install only the pinned mise entry
point through the completed installer functions, and use that exact binary:

```bash
MISE_PARSE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-mise-parse.XXXXXX")
test -n "$MISE_PARSE_HOME"
test -d "$MISE_PARSE_HOME"
HOME="$MISE_PARSE_HOME" DOTFILES_SOURCE_DIR="$PWD" \
    DOTFILES_TARGET_HOME="$MISE_PARSE_HOME" \
    bash -c '. ./install.sh; preflight_required_commands; install_mise_if_needed'
MISE_VERIFY_BIN="$MISE_PARSE_HOME/.local/bin/mise"
test "$("$MISE_VERIFY_BIN" --version | awk 'NR == 1 { print $1 }')" = 2026.8.9
HOME="$MISE_PARSE_HOME" MISE_GLOBAL_CONFIG_FILE="$PWD/mise.toml" \
    "$MISE_VERIFY_BIN" -C "$PWD" config ls
HOME="$MISE_PARSE_HOME" MISE_GLOBAL_CONFIG_FILE="$PWD/mise.toml" \
    "$MISE_VERIFY_BIN" -C "$PWD" install --locked --dry-run
HOME="$MISE_PARSE_HOME" MISE_GLOBAL_CONFIG_FILE="$PWD/mise.toml" \
    "$MISE_VERIFY_BIN" -C "$PWD" bootstrap --dry-run
HOME="$MISE_PARSE_HOME" MISE_GLOBAL_CONFIG_FILE="$PWD/mise.toml" \
    "$MISE_VERIFY_BIN" -C "$PWD" run test
```

Expected: configuration loads once, all 17 tools resolve, dry runs report no
missing platform URL, and the test task passes.

- [ ] **Step 3: Run a real isolated-home bootstrap twice**

Create a dedicated temporary home and ensure the variable is an explicit,
validated path before invoking or later removing it:

```bash
DOTFILES_VERIFY_HOME=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-mise-verify.XXXXXX")
test -n "$DOTFILES_VERIFY_HOME"
test -d "$DOTFILES_VERIFY_HOME"
HOME="$DOTFILES_VERIFY_HOME" DOTFILES_TARGET_HOME="$DOTFILES_VERIFY_HOME" ./install.sh
HOME="$DOTFILES_VERIFY_HOME" DOTFILES_TARGET_HOME="$DOTFILES_VERIFY_HOME" ./install.sh
```

Expected: both runs exit 0; the second reports already-converged repositories,
links, and tools and creates no backup directory.

- [ ] **Step 4: Verify installed tool and link state**

Use the exact isolated mise binary:

```bash
HOME="$DOTFILES_VERIFY_HOME" \
    "$DOTFILES_VERIFY_HOME/.local/bin/mise" -C "$PWD" exec -- \
    sh -c 'cargo --version && rustc --version && cargo clippy --version && rustfmt --version && rust-analyzer --version'
```

Also verify:

```bash
test -L "$DOTFILES_VERIFY_HOME/.config/mise/config.toml"
test -L "$DOTFILES_VERIFY_HOME/.config/mise/mise.lock"
test ! -e "$DOTFILES_VERIFY_HOME/.local/bin/ha"
test ! -e "$DOTFILES_VERIFY_HOME/.config/devbox"
```

Expected: every Rust command reports toolchain `1.97.1`, both mise files are
links to this repository, and obsolete links are absent.

- [ ] **Step 5: Verify conflict preservation with installer fakes**

The automated installer test from Task 2 is authoritative for conflict safety.
Rerun it with tracing only if needed:

```bash
bash -x tests/test_installer.sh
```

Do not run another full 17-tool install merely to reproduce a dotfile conflict.
Expected: regular files and unrelated symlinks remain byte-for-byte unchanged.

- [ ] **Step 6: Inspect the final repository and commit any verified correction**

Run:

```bash
git status --short
git diff --check
git log --oneline --decorate -6
```

If verification required a correction, add only its owning files, rerun the
relevant task's RED/GREEN tests plus Step 1, and commit with a message naming
the corrected behavior. If no correction was required, leave the tree clean
and create no empty commit.
