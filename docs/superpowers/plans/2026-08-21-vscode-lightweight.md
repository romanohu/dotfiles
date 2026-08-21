# VS Code Lightweight Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a small, portable VS Code settings set to the dotfiles and safely link it on macOS and Linux without importing personal workspace state.

**Architecture:** Track one strict JSON file at `.config/vscode/settings.json`. Keep it outside mise's platform-independent `[dotfiles]` mappings and add two small installer helpers: one computes the supported VS Code User directory, and one preflights/creates only the exact repository symlink when that User directory already exists. Existing installer preflight runs before any mutation; the new link is applied after mise bootstrap.

**Tech Stack:** Bash 4-compatible installer functions, POSIX-style shell tests, strict JSON configuration, existing `tests/test_helpers.sh` assertions, and `apply_patch` for edits.

## Global Constraints

- Support only the existing macOS (`Darwin`) and Linux installer targets; do not add Windows behavior.
- Manage only the exact JSON keys and generated-directory exclusions specified in the design; do not import existing personal settings.
- Do not write personal hostnames, credentials, Remote-SSH settings, or extension IDs into the repository.
- If the VS Code `User` directory is absent, report `VS Code settings: skipped` and do not create any VS Code directories.
- If an existing target is a regular file, directory, unrelated symlink, or lies below a symlinked ancestor, preserve it and stop before installer mutation.
- Accept a missing target or the exact symlink to `$DOT_DIR/.config/vscode/settings.json`; repeated installation must remain successful and unchanged.
- Do not merge, delete, or rewrite an existing `settings.json`; do not manage VS Code caches, user data, extensions, or Profiles automatically.
- Keep the existing `mise.toml` `[dotfiles]` mappings unchanged; the platform-specific VS Code path is handled by `install.sh`.

---

## File Map

- Create: `.config/vscode/settings.json` — the strict, personal-state-free lightweight settings file.
- Modify: `install.sh` — platform target calculation, safe preflight, and post-bootstrap symlink setup.
- Modify: `tests/test_configuration.sh` — exact JSON and README/config scope assertions.
- Modify: `tests/test_installer.sh` — isolated-home tests for target calculation, skip behavior, conflicts, idempotency, and main ordering.
- Modify: `README.md` — document the managed VS Code settings and manual Profile boundary.
- Do not modify: `mise.toml` or `mise.lock`; VS Code paths cannot be represented portably by the existing mise dotfiles map.

## Interfaces

- `vscode_user_dir_for_platform <Darwin|Linux>` prints the target VS Code `User` directory and returns nonzero for unsupported platforms.
- `vscode_settings_target_for_platform <Darwin|Linux>` prints `<user-dir>/settings.json` and returns nonzero for unsupported platforms.
- `preflight_vscode_settings [platform]` validates the target using `validate_managed_dotfile_target`; it skips only when the User path is absent and never creates directories.
- `setup_vscode_settings [platform]` reuses the preflight, skips an absent User directory, and creates the exact symlink for an existing User directory.

### Task 1: Lock down the lightweight JSON contract

**Files:**
- Create: `.config/vscode/settings.json`
- Modify: `tests/test_configuration.sh`

**Interfaces:**
- Consumes: no installer behavior; the test reads the new tracked JSON file.
- Produces: an exact byte-level JSON contract that later installer tests link without merging.

- [ ] **Step 1: Write the failing configuration test**

Add `test_vscode_lightweight_settings_are_exact_and_personal_state_free` before the test invocation block in `tests/test_configuration.sh`:

```bash
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
    assert_file_not_contains "$settings" 'remote.SSH'
    assert_file_not_contains "$settings" 'github.copilot'
    assert_file_not_contains "$settings" 'password'
    assert_file_not_contains "$settings" 'token'
    assert_file_not_contains "$settings" 'hostname'
}
```

Register it immediately before the final `printf 'PASS: ...'` line.

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `bash tests/test_configuration.sh`

Expected: FAIL because `.config/vscode/settings.json` does not exist yet. Do not change the test to make a missing file pass.

- [ ] **Step 3: Add the minimal strict JSON file**

Create `.config/vscode/settings.json` with exactly the bytes asserted above. Do not add comments, trailing commas, project-specific source exclusions, or user-specific settings.

- [ ] **Step 4: Run the focused test to verify it passes**

Run: `bash tests/test_configuration.sh`

Expected: PASS, including the existing configuration assertions.

- [ ] **Step 5: Commit the configuration contract**

```bash
git add .config/vscode/settings.json tests/test_configuration.sh
git commit -m "feat: add lightweight vscode settings"
```

### Task 2: Add safe platform-aware installer linking

**Files:**
- Modify: `tests/test_installer.sh`
- Modify: `install.sh`

**Interfaces:**
- Consumes: `.config/vscode/settings.json` from Task 1 and the existing `validate_managed_dotfile_target` safety contract.
- Produces: `vscode_user_dir_for_platform`, `vscode_settings_target_for_platform`, `preflight_vscode_settings`, and `setup_vscode_settings`; `main` calls setup only after `run_mise_bootstrap`.

- [ ] **Step 1: Write failing target and skip tests**

Add these tests before the installer test invocation list:

```bash
test_vscode_settings_target_supports_only_macos_and_linux() {
    local target_home="$TEST_ROOT/vscode-target-home"

    mkdir -p "$target_home"
    (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"

        assert_eq "$target_home/Library/Application Support/Code/User" \
            "$(vscode_user_dir_for_platform Darwin)"
        assert_eq "$target_home/.config/Code/User" \
            "$(vscode_user_dir_for_platform Linux)"
        assert_eq "$target_home/Library/Application Support/Code/User/settings.json" \
            "$(vscode_settings_target_for_platform Darwin)"
        assert_eq "$target_home/.config/Code/User/settings.json" \
            "$(vscode_settings_target_for_platform Linux)"
        if vscode_user_dir_for_platform Windows; then
            fail 'VS Code target calculation must reject Windows'
        fi
    )
}

test_vscode_settings_skip_without_user_directory() {
    local target_home="$TEST_ROOT/vscode-skip-home"

    mkdir -p "$target_home"
    (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        preflight_vscode_settings Darwin
        setup_vscode_settings Darwin
    )
    assert_path_missing "$target_home/Library"
}
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run: `bash tests/test_installer.sh`

Expected: FAIL at the first new test with an undefined-function error for `vscode_user_dir_for_platform`. Existing tests must remain runnable up to that failure.

- [ ] **Step 3: Implement platform calculation and skip-safe preflight**

Insert these functions after `validate_managed_dotfile_target` in `install.sh`:

```bash
vscode_user_dir_for_platform() {
    local platform="$1"

    case "$platform" in
        Darwin) printf '%s\n' "$TARGET_HOME/Library/Application Support/Code/User" ;;
        Linux) printf '%s\n' "$TARGET_HOME/.config/Code/User" ;;
        *)
            warn "Unsupported VS Code platform: $platform"
            return 1
            ;;
    esac
}

vscode_settings_target_for_platform() {
    local user_dir

    user_dir="$(vscode_user_dir_for_platform "$1")" || return 1
    printf '%s/settings.json\n' "$user_dir"
}

preflight_vscode_settings() {
    local platform="${1:-$(uname -s)}"
    local user_dir
    local target

    user_dir="$(vscode_user_dir_for_platform "$platform")" || return 1
    target="$user_dir/settings.json"
    validate_managed_dotfile_target \
        "$target" "$DOT_DIR/.config/vscode/settings.json" || return 1
    if [ ! -d "$user_dir" ]; then
        [ ! -e "$user_dir" ] && [ ! -L "$user_dir" ] || {
            warn "Refusing VS Code settings path that is not a directory: $user_dir"
            return 1
        }
        log 'VS Code settings: skipped (User directory is absent)'
    fi
}

setup_vscode_settings() {
    local platform="${1:-$(uname -s)}"
    local user_dir
    local target
    local source="$DOT_DIR/.config/vscode/settings.json"

    preflight_vscode_settings "$platform" || return 1
    user_dir="$(vscode_user_dir_for_platform "$platform")" || return 1
    [ -d "$user_dir" ] || return 0
    target="$user_dir/settings.json"
    [ -L "$target" ] && {
        log "VS Code settings: already linked $target"
        return 0
    }
    ln -s "$source" "$target" || return 1
    log "VS Code settings: linked $target"
}
```

Call `preflight_vscode_settings` at the end of `preflight_managed_dotfiles`, after the ten existing managed targets. Add `[ -f "$DOT_DIR/.config/vscode/settings.json" ] || fail ...` to `validate_environment`. In `main`, call `setup_vscode_settings || return 1` immediately after `run_mise_bootstrap || return 1`.

- [ ] **Step 4: Add failing conflict, ancestor, idempotency, and ordering tests**

Add the following tests to `tests/test_installer.sh`:

```bash
test_vscode_settings_conflicts_are_preserved() {
    local target_home="$TEST_ROOT/vscode-conflict-home"
    local user_dir="$target_home/.config/Code/User"
    local target="$user_dir/settings.json"
    local external="$TEST_ROOT/vscode-conflict-external"

    mkdir -p "$user_dir" "$external"
    printf 'keep settings\n' > "$target"
    (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        if setup_vscode_settings Linux; then
            fail 'VS Code settings conflict was accepted'
        fi
    )
    assert_eq 'keep settings' "$(cat "$target")" \
        'VS Code settings conflict was overwritten'

    rm -f "$target"
    ln -s "$external" "$target"
    if (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        setup_vscode_settings Linux
    ); then
        fail 'unrelated VS Code settings symlink was accepted'
    fi
    assert_link_points_to "$target" "$external"
}

test_vscode_settings_rejects_symlinked_ancestor() {
    local target_home="$TEST_ROOT/vscode-ancestor-home"
    local external="$TEST_ROOT/vscode-ancestor-external"

    mkdir -p "$target_home" "$external/Code/User"
    ln -s "$external" "$target_home/.config"
    if (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        setup_vscode_settings Linux
    ); then
        fail 'VS Code settings below a symlinked ancestor were accepted'
    fi
    assert_link_points_to "$target_home/.config" "$external"
}

test_vscode_settings_link_is_idempotent() {
    local target_home="$TEST_ROOT/vscode-idempotent-home"
    local user_dir="$target_home/Library/Application Support/Code/User"
    local target="$user_dir/settings.json"

    mkdir -p "$user_dir"
    (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        setup_vscode_settings Darwin
        setup_vscode_settings Darwin
    )
    assert_link_points_to "$target" "$REPO_DIR/.config/vscode/settings.json"
}

test_main_sets_up_vscode_after_mise_bootstrap() {
    local target_home="$TEST_ROOT/vscode-main-order-home"
    local calls="$TEST_ROOT/vscode-main-order-calls"

    mkdir -p "$target_home"
    (
        export DOTFILES_TARGET_HOME="$target_home"
        # shellcheck source=/dev/null
        . "$INSTALLER_RUNTIME_PATH"
        preflight_required_commands() { printf 'preflight\n' >> "$calls"; }
        validate_environment() { printf 'environment\n' >> "$calls"; }
        preflight_managed_dotfiles() { printf 'managed\n' >> "$calls"; }
        install_mise_if_needed() { printf 'mise\n' >> "$calls"; }
        cleanup_legacy_managed_links() { printf 'cleanup\n' >> "$calls"; }
        run_mise_bootstrap() { printf 'bootstrap\n' >> "$calls"; }
        setup_vscode_settings() { printf 'vscode\n' >> "$calls"; }
        main
    )
    assert_eq "$(printf '%s\n' preflight environment managed mise cleanup bootstrap vscode)" \
        "$(cat "$calls")" \
        'main must set up VS Code only after mise bootstrap'
}
```

Register all six tests in the invocation list. The first five exercise the public helper behavior directly; the final test protects main's mutation order.

- [ ] **Step 5: Run the focused tests to verify they fail for the missing behavior**

Run: `bash tests/test_installer.sh`

Expected: the new tests fail before the helper is integrated (the setup tests cannot call the missing helper, and the main-order test lacks the `vscode` call). Existing installer tests must still pass.

- [ ] **Step 6: Run the focused tests after the minimal implementation**

Run: `bash tests/test_installer.sh`

Expected: PASS for all installer tests. Confirm that no test creates `Library`, `.config/Code`, or `settings.json` when the corresponding User directory was absent.

- [ ] **Step 7: Commit the installer integration**

```bash
git add install.sh tests/test_installer.sh
git commit -m "feat: link vscode settings safely"
```

### Task 3: Document the managed boundary and manual Profiles

**Files:**
- Modify: `README.md`
- Modify: `tests/test_configuration.sh`

**Interfaces:**
- Consumes: the exact settings and installer behavior from Tasks 1–2.
- Produces: user-facing instructions that distinguish managed lightweight settings from manual Profile and cache decisions.

- [ ] **Step 1: Write the failing documentation assertions**

Add `test_readme_documents_vscode_lightweight_scope` to `tests/test_configuration.sh`:

```bash
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
```

Register the test before the final pass message.

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `bash tests/test_configuration.sh`

Expected: FAIL because README has no VS Code section.

- [ ] **Step 3: Add concise README documentation**

Insert a `## VS Code lightweight settings` section after `## Shell and Herdr usage` with these facts:

```markdown
## VS Code lightweight settings

The repository manages only `.config/vscode/settings.json`. It excludes common
generated and dependency directories from file watching and search, and disables
the minimap, breadcrumbs, and CodeLens. On macOS the installer links it to
`~/Library/Application Support/Code/User/settings.json`; on Linux it uses
`~/.config/Code/User/settings.json`. If the VS Code User directory is absent, the
installer skips this link and does not create VS Code directories.

Existing `settings.json`, connection settings, extensions, profiles, and cache data
remain user-owned. The installer does not merge or delete an existing settings
file and does not delete VS Code cache. Use VS Code's Profiles UI manually to
separate everyday editing from Python/Jupyter or C/C++/Rust work, enabling only
the extensions needed for each workload.
```

Add `.config/vscode` to the repository layout tree. Do not list any hostnames or extension IDs.

- [ ] **Step 4: Run the focused test to verify it passes**

Run: `bash tests/test_configuration.sh`

Expected: PASS, including the exact-line safety assertions already present for README boundaries.

- [ ] **Step 5: Commit the documentation**

```bash
git add README.md tests/test_configuration.sh
git commit -m "docs: explain vscode lightweight settings"
```

### Task 4: Run the complete verification gates

**Files:**
- Verify: `.config/vscode/settings.json`, `install.sh`, `README.md`, `tests/test_configuration.sh`, `tests/test_installer.sh`

**Interfaces:**
- Consumes: all implementation and documentation commits from Tasks 1–3.
- Produces: evidence that the offline suite, shell syntax checks, JSON contract, and diff checks pass together.

- [ ] **Step 1: Run the full offline suite**

Run: `bash tests/run.sh`

Expected: `PASS: 4 test file(s)` with exit status 0.

- [ ] **Step 2: Run syntax and file checks**

Run:

```bash
bash -n install.sh tests/*.sh
zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 3: Verify the tracked settings contract directly**

Run: `test "$(grep -F -c '"files.watcherExclude"' .config/vscode/settings.json)" -eq 1 && test "$(grep -F -c '"search.exclude"' .config/vscode/settings.json)" -eq 1`

Expected: exit status 0; the full byte-level contract remains covered by `test_configuration.sh`.

- [ ] **Step 4: Confirm the final diff is scoped**

Run:

```bash
expected_paths=$(printf '%s\n' \
    '.config/vscode/settings.json' \
    'README.md' \
    'install.sh' \
    'tests/test_configuration.sh' \
    'tests/test_installer.sh')
actual_paths=$(git diff --name-only 1b5c160..HEAD -- . ':(exclude)docs/superpowers/**' | LC_ALL=C sort)
test "$actual_paths" = "$expected_paths"
```

Expected: exit status 0. The complete diff name list, excluding only `docs/superpowers/**` process artifacts, matches exactly the five feature paths; any other non-process-doc file fails the check.
