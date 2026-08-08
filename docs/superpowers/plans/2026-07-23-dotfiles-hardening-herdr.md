# Dotfiles Hardening and Herdr Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the dotfiles setup non-destructive and reproducible, remove Neovim and Pet, add a pinned Herdr installation with minimal Zsh configuration, and publish a sanitized Git history.

**Architecture:** Keep the Bash installer and Devbox global environment. Refactor the installer around an isolated target root and small testable helpers, validate all behavior with offline Bash tests, pin downloaded and Git-sourced dependencies, and perform the public history rewrite only after the final tree passes verification.

**Tech Stack:** Bash 3.2-compatible shell, Zsh, Git, Devbox/Nix, JSON/TOML, Lua/WezTerm, `git-filter-repo` 2.47.0 via `uvx`.

---

## File Structure

**Create**

- `tests/test_helpers.sh` — minimal assertions and per-test temporary-directory lifecycle.
- `tests/test_installer.sh` — functional tests for installer isolation, backup, migration, checksum, and pinned Git checkout behavior.
- `tests/test_configuration.sh` — static and parser-backed checks for tracked configuration, package pins, removed tools, and Herdr.
- `tests/run.sh` — executes every test file and returns a combined status.
- `.config/devbox/global/run-tests.sh` — resolves the physical repository path when invoked through the Devbox global symlink.
- `.config/herdr/config.toml` — minimal Herdr terminal setting.

**Modify**

- `install.sh` — sourceable/testable installer, safe backups, pinned bootstrap, pinned Zsh dependencies, no npm mutation, Neovim-link cleanup, Herdr linking.
- `.config/devbox/global/devbox.json` — exact packages, platform-specific nvtop, working test script, pinned Herdr flake.
- `.config/devbox/global/devbox.lock` — tracked final package and flake resolutions.
- `.config/zsh/.zshrc` — remove npm-global and Pet loading.
- `.config/wezterm/wezterm.lua` — guard monitoring commands and use a font fallback.
- `.gitignore` — track Devbox lockfile and remove the Pet exception.
- `README.md` — accurate platform/prerequisite, test, update, backup, and history-rewrite guidance.

**Delete**

- `.config/nvim/init.lua`
- `.config/nvim/lazy-lock.json`
- `.config/zsh/pet.zsh`
- `nvim.log`

## Pinned Inputs

- Determinate Nix Installer: `v3.21.2`
- Nix installer URL: `https://install.determinate.systems/nix/tag/v3.21.2/nix-installer.sh`
- Nix installer SHA-256: `4141f93485a16d600b995d02b2bdd296fb69af30ea3665037677b8d56f703b56`
- Devbox flake: `github:jetify-com/devbox/0.17.3`
- Oh My Zsh: `677a4592b18c08ddea737f8aca70bac0e9fc9313`
- zsh-autosuggestions: `85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5`
- zsh-syntax-highlighting: `1d85c692615a25fe2293bdd44b34c217d5d2bf04`
- Herdr flake: `github:ogulcancelik/herdr/v0.7.5`
- git-filter-repo: `2.47.0`

### Task 1: Isolate the Work and Add a Safe Test Harness

**Files:**

- Create: `tests/test_helpers.sh`
- Create: `tests/test_installer.sh`
- Create: `tests/run.sh`
- Modify: `install.sh`

- [ ] **Step 1: Preserve the only pre-existing worktree change**

Confirm the only uncommitted tracked change is `.config/nvim/lazy-lock.json`:

```bash
git status --short
git diff -- .config/nvim/lazy-lock.json
```

Expected: the lockfile is the only modified tracked file. It is intentionally obsolete because Neovim will be removed, but stash it until the Neovim-removal commit exists:

```bash
git stash push -m "preexisting nvim lock update; superseded by removal" -- .config/nvim/lazy-lock.json
```

Use `superpowers:using-git-worktrees` to create a dedicated `codex/dotfiles-hardening-herdr` worktree from the current `main` tip. Verify the worktree is clean before editing.

- [ ] **Step 2: Write a failing sourceability test**

Create `tests/test_helpers.sh` with `fail`, `assert_eq`, `assert_path_exists`, `assert_path_missing`, `assert_file_contains`, `assert_file_not_contains`, and `make_test_dir`. Temporary paths must be created with `mktemp -d "${TMPDIR:-/tmp}/dotfiles-test.XXXXXX"` and removed by the test process that created them.

Create `tests/test_installer.sh` with this first test:

```bash
test_installer_has_source_guard() {
    assert_file_contains "$REPO_ROOT/install.sh" \
        'if [[ "${BASH_SOURCE[0]}" == "$0" ]]'
}
```

Create `tests/run.sh` to execute `tests/test_*.sh` except `test_helpers.sh` and return nonzero if any file fails.

- [ ] **Step 3: Run the test and verify RED**

Run:

```bash
bash tests/run.sh
```

Expected: FAIL because `install.sh` still calls `main "$@"` unconditionally.

- [ ] **Step 4: Add only the minimal source guard**

Replace the unconditional call with:

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
```

Do not add target variables yet. This first cycle makes it safe for the next test to source the installer without invoking `main` against the real home directory.

- [ ] **Step 5: Run the sourceability test and verify GREEN**

Run:

```bash
bash tests/run.sh
bash -n install.sh tests/test_helpers.sh tests/test_installer.sh tests/run.sh
```

Expected: the sourceability test passes and all files parse.

- [ ] **Step 6: Write a failing target-isolation test**

Add a second test that creates a temporary source tree and target home, exports `DOTFILES_SOURCE_DIR` and `DOTFILES_TARGET_HOME`, and sources `install.sh`. Before it calls any setup function, it must assert that every resolved installer destination is below the temporary target:

```bash
test_all_managed_destinations_are_isolated() {
    # Create TEST_SOURCE and TEST_HOME beneath one test-owned mktemp directory.
    # Export DOTFILES_SOURCE_DIR="$TEST_SOURCE" and DOTFILES_TARGET_HOME="$TEST_HOME".
    # Source install.sh in a subshell.
    # Assert TARGET_HOME, DEVBOX_DATA_DIR, DEVBOX_GLOBAL_CONFIG, ZSH_HOME_DIR,
    # the Nix user profile destination, and the backup root are each equal to
    # or nested below TEST_HOME. Abort before setup_dotfiles_links on mismatch.
    # Only after those assertions, call setup_dotfiles_links.
    # Assert every created link is below TEST_HOME and points into TEST_SOURCE.
}
```

Also add a static assertion that direct `$HOME` expansion appears only in the default assignment `TARGET_HOME="${DOTFILES_TARGET_HOME:-$HOME}"`; all managed destinations must derive from `TARGET_HOME`. The test process must capture the real home path before exporting overrides and assert that no path below that real home was created, removed, or replaced by the test.

- [ ] **Step 7: Run the target-isolation test and verify RED**

Run:

```bash
bash tests/run.sh
```

Expected: FAIL before any setup function runs because `TARGET_HOME` and the other injectable destinations do not exist yet. The real home directory remains untouched.

- [ ] **Step 8: Add target variables and convert every managed home path**

At the top of `install.sh`, derive paths this way:

```bash
SCRIPT_DOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
DOT_DIR="${DOTFILES_SOURCE_DIR:-$SCRIPT_DOT_DIR}"
TARGET_HOME="${DOTFILES_TARGET_HOME:-$HOME}"
DEVBOX_DATA_DIR="${DEVBOX_DATA_DIR:-$TARGET_HOME/.local/share/devbox}"
DEVBOX_GLOBAL_CONFIG="$TARGET_HOME/.config/devbox/global"
ZSH_HOME_DIR="$TARGET_HOME/.config/zsh"
```

Derive the Nix user profile destination and backup root from `TARGET_HOME` too. Replace every installer-managed use of `$HOME` with the corresponding `TARGET_HOME`-derived variable. `$HOME` may remain only in the default assignment shown above. Do not change installation behavior beyond making all target paths injectable.

- [ ] **Step 9: Run the harness and verify GREEN**

Run:

```bash
bash tests/run.sh
bash -n install.sh tests/test_helpers.sh tests/test_installer.sh tests/run.sh
```

Expected: all tests pass and all files parse.

- [ ] **Step 10: Commit**

```bash
git add install.sh tests/test_helpers.sh tests/test_installer.sh tests/run.sh
git commit -m "test: add isolated dotfiles installer harness"
```

### Task 2: Make Linking and Migration Non-destructive, Then Remove Neovim

**Files:**

- Modify: `tests/test_installer.sh`
- Modify: `tests/test_configuration.sh`
- Modify: `install.sh`
- Delete: `.config/nvim/init.lua`
- Delete: `.config/nvim/lazy-lock.json`
- Delete: `nvim.log`
- Modify: `README.md`

- [ ] **Step 1: Write failing safety tests**

Add functional tests that source `install.sh` in a subshell after exporting `DOTFILES_TARGET_HOME` and `DOTFILES_SOURCE_DIR` to test directories:

```bash
test_zsh_symlink_is_backed_up_without_mutating_target() {
    # Arrange a source tree with tracked zsh files plus history/session/dump fixtures.
    # Point <target>/.config/zsh at that source tree.
    # Call prepare_zsh_dir.
    # Assert the source fixtures are unchanged.
    # Assert the new target directory contains copies of recognized runtime fixtures.
    # Assert the old symlink exists under exactly one unique backup directory.
}

test_correct_link_is_idempotent() {
    # Call safe_link_or_copy twice for the same absolute source and target.
    # Assert no backup directory was created.
}

test_only_managed_legacy_nvim_link_is_removed() {
    # A link to <source>/.config/nvim is removed.
    # A real directory and a link to another target remain unchanged.
}
```

Create `tests/test_configuration.sh` and add checks asserting that `.config/nvim` and `nvim.log` do not exist and that `install.sh` contains no `.local/state/nvim`, `.local/share/nvim`, or `.cache/nvim` deletion targets.

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
bash tests/run.sh
```

Expected failures:

- `prepare_zsh_dir` removes the link without backing it up.
- recognized runtime state is moved rather than copied.
- Neovim files and destructive cleanup code still exist.

- [ ] **Step 3: Implement lazy, unique backup directories**

Replace the timestamp-only global `BACKUP_DIR` with a lazily created directory. Use a function that creates one directory per installer run beneath `$TARGET_HOME/.dotfiles-backup` with `mktemp -d`; never reuse a pre-existing directory. Update `backup_target_if_needed` to derive relative paths from `TARGET_HOME`, not `HOME`.

Keep backup operations limited to the exact destination passed to the function. Do not follow symlinks.

- [ ] **Step 4: Make Zsh migration copy-only**

Update `prepare_zsh_dir`:

1. Read and preserve the old symlink target string.
2. Move the symlink itself through `backup_target_if_needed`.
3. Create a real `$ZSH_HOME_DIR`.
4. Only when the old link targeted `$DOT_DIR/.config/zsh`, copy `.zsh_history`, `.zsh_sessions`, and `.zcompdump*` with metadata preservation.
5. Never remove or modify the source files/directories.

Do not copy `oh-my-zsh`; it is managed separately by the pinned checkout helper.

- [ ] **Step 5: Remove only the legacy managed Neovim link**

Add `cleanup_legacy_managed_links` that removes `$TARGET_HOME/.config/nvim` only when it is a symlink whose stored target is exactly `$DOT_DIR/.config/nvim`, the absolute target created by this installer. Log the removal. Leave every other file, directory, or link unchanged.

Remove `nvim` from the setup link loop. Delete `cleanup_nvim_kickstart_migration_once` and its call.

- [ ] **Step 6: Delete tracked Neovim configuration**

Delete `.config/nvim/init.lua`, `.config/nvim/lazy-lock.json`, and `nvim.log`. Update the README layout and installer description so Neovim is not advertised or managed.

- [ ] **Step 7: Verify GREEN**

Run:

```bash
bash tests/run.sh
bash -n install.sh
git diff --check
rg -n 'nvim|neovim|kickstart|mason' install.sh README.md .config tests || true
```

Expected: tests pass; the final search has only deliberate negative assertions in tests or documentation about removal.

- [ ] **Step 8: Commit**

```bash
git add -A install.sh README.md .config/nvim nvim.log tests
git commit -m "fix: remove destructive Neovim management"
```

### Task 3: Pin Bootstrap and Zsh Dependencies, Remove npm Mutation

**Files:**

- Modify: `tests/test_installer.sh`
- Modify: `tests/test_configuration.sh`
- Modify: `install.sh`
- Modify: `.config/zsh/.zshrc`

- [ ] **Step 1: Write failing checksum and pin tests**

Add tests for this wished-for API:

```bash
test_sha256_accepts_matching_file() {
    # Create a fixture and assert verify_sha256 FILE EXPECTED returns zero.
}

test_sha256_rejects_mismatching_file() {
    # Assert verify_sha256 FILE all-zero-hash returns nonzero.
}

test_verified_installer_is_not_executed_on_checksum_mismatch() {
    # Stub curl so the downloaded script would create EXECUTED_MARKER when run.
    # Call run_verified_installer with an intentionally wrong checksum.
    # Assert nonzero and assert EXECUTED_MARKER is absent.
}

test_verified_installer_executes_after_checksum_match() {
    # Use the same harmless stub script and its actual SHA-256.
    # Call run_verified_installer and assert EXECUTED_MARKER exists.
}

test_preflight_failure_happens_before_any_mutation() {
    # Run main in a subshell with command discovery overridden so git is absent.
    # Replace every mutating setup function with a marker-producing stub.
    # Assert main fails, no marker exists, and no target path was created.
}

test_pinned_checkout_uses_requested_commit() {
    # Create a local Git origin with two commits.
    # Call ensure_pinned_checkout ORIGIN FIRST_COMMIT DESTINATION.
    # Assert DESTINATION HEAD is exactly FIRST_COMMIT and detached.
}

test_existing_checkout_at_another_commit_is_preserved() {
    # Pre-create DESTINATION at SECOND_COMMIT.
    # Call ensure_pinned_checkout for FIRST_COMMIT.
    # Assert HEAD remains SECOND_COMMIT and the function warns.
}
```

Add configuration assertions that `install.sh` contains the exact Nix URL/hash, Devbox flake, and three Zsh commit IDs. Assert it contains neither `curl ... | sh`, floating `git clone`, nor `npm config set prefix`. Assert `.zshrc` does not contain `.npm-global/bin`.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
bash tests/run.sh
```

Expected: checksum, verified-execution, preflight, and checkout functions are undefined; floating bootstrap and npm mutation assertions fail. The verified-installer mismatch case must show that the downloaded fixture was never executed.

- [ ] **Step 3: Implement a mutation-free preflight**

Add `preflight_required_commands` and invoke it as the first statement in `main`, before directory creation, download, package installation, backup, link, or checkout work. It must require at least `bash`, `curl`, `git`, and one supported SHA-256 implementation (`sha256sum` or `shasum`). A missing requirement returns nonzero with an actionable message. Do not attempt to install a prerequisite during preflight.

Run the focused preflight test and confirm that no mutation marker or target path exists after failure.

- [ ] **Step 4: Implement portable SHA-256 verification and gated execution**

Add `sha256_file` with `sha256sum` first and `shasum -a 256` fallback. Add `verify_sha256 FILE EXPECTED` that compares lowercase hex and returns nonzero on mismatch without executing the file.

Add `run_verified_installer URL EXPECTED_SHA256 ...` so download, verification, and execution are one testable unit. The function must return immediately on a verification mismatch; the execution statement must occur only after `verify_sha256` succeeds.

Update Nix installation to:

1. Create a private temporary directory with `mktemp -d`.
2. Download the exact tagged URL using curl with HTTPS/TLS restrictions and an explicit output file.
3. Verify the exact committed SHA-256.
4. Execute only the verified file through `run_verified_installer`.
5. Remove only the validated temporary directory on success or failure.

- [ ] **Step 5: Install pinned Devbox through Nix**

Replace the Devbox curl installer with:

```bash
nix profile install github:jetify-com/devbox/0.17.3
```

If `devbox` already exists, parse `devbox version`. Skip when it is `0.17.3`; otherwise warn and preserve the existing binary.

- [ ] **Step 6: Implement atomic pinned Git checkouts**

Implement `ensure_pinned_checkout URL COMMIT DESTINATION` using a temporary sibling directory, `git init`, `git fetch --depth 1 origin COMMIT`, detached checkout, and final rename. Delete only the temporary directory on failure. Existing destinations at the wrong commit are warned about and preserved.

Use it for Oh My Zsh and both plugins with the pinned values listed above.

- [ ] **Step 7: Remove npm configuration mutation**

Delete `setup_npm_prefix`, its `main` call, and `export PATH=$HOME/.npm-global/bin:$PATH` from `.config/zsh/.zshrc`.

- [ ] **Step 8: Verify GREEN**

Run:

```bash
bash tests/run.sh
bash -n install.sh
zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh .config/zsh/pet.zsh
git diff --check
```

Expected: all tests and syntax checks pass.

- [ ] **Step 9: Commit**

```bash
git add install.sh .config/zsh/.zshrc tests
git commit -m "fix: pin dotfiles bootstrap dependencies"
```

### Task 4: Make the Global Tool Configuration Reproducible

**Files:**

- Modify: `tests/test_configuration.sh`
- Create: `.config/devbox/global/run-tests.sh`
- Modify: `.config/devbox/global/devbox.json`
- Modify: `.config/devbox/global/devbox.lock`
- Modify: `.config/wezterm/wezterm.lua`
- Modify: `.gitignore`
- Modify: `README.md`

- [ ] **Step 1: Write failing configuration tests**

Add assertions that:

- `devbox.lock` is tracked (`git ls-files --error-unmatch`).
- no package selector contains `latest`.
- Node.js is `24.12.0`.
- Neovim and Tree-sitter are absent.
- Zsh is explicitly present.
- Apple silicon uses `nvtopPackages.apple@3.3.2` and Linux uses `nvtopPackages.full@3.3.2`.
- the Devbox test command invokes `$DEVBOX_PROJECT_ROOT/run-tests.sh`.
- WezTerm checks `command -v nvtop` before running it.
- the configured font has at least one fallback.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
bash tests/run.sh
```

Expected: all new reproducibility assertions fail against the old list and ignored lockfile.

- [ ] **Step 3: Convert Devbox packages to an exact map**

Keep existing exact versions, remove Neovim and Tree-sitter, change Node.js to `24.12.0`, and add `zsh@5.9`. Keep Pet until Task 5 to preserve the user-requested order.

Add platform-specific entries:

```json
"nvtopPackages.apple": {
  "version": "3.3.2",
  "platforms": ["aarch64-darwin"]
},
"nvtopPackages.full": {
  "version": "3.3.2",
  "platforms": ["x86_64-linux", "aarch64-linux"]
}
```

Use Devbox's object form for all packages so platform restrictions remain explicit.

- [ ] **Step 4: Add a symlink-safe Devbox test entrypoint**

Create `.config/devbox/global/run-tests.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
exec bash "$REPO_ROOT/tests/run.sh"
```

Set the Devbox `test` script to:

```json
"test": "bash \"$DEVBOX_PROJECT_ROOT/run-tests.sh\""
```

- [ ] **Step 5: Track and regenerate the lockfile**

Remove `.config/devbox/global/devbox.lock` from `.gitignore`. Regenerate from the repository root:

```bash
devbox install --config .config/devbox/global
```

Expected: exit 0 and an updated lockfile containing the exact platform package resolutions. If the command needs network access, request approval rather than changing the package set to avoid it.

- [ ] **Step 6: Guard WezTerm monitoring and add font fallback**

Change the `nvtop` pane command to a shell condition that runs `nvtop` when available and prints an actionable message otherwise. Use `wezterm.font_with_fallback` with `JetBrains Mono`, a macOS fallback, and generic monospace fallback.

- [ ] **Step 7: Document prerequisites and boundaries**

Update README with:

- CLI prerequisites needed before the first run (`bash`, `curl`, and `git`).
- WezTerm/font installation as a graphical prerequisite.
- macOS and Linux behavior.
- WSL CLI support and the fact that Windows-hosted WezTerm config is not installed from WSL.
- backup location and no editor-state deletion.
- exact test command: `devbox run --config .config/devbox/global test`.
- pinned dependency update procedure.
- the history rewrite requires every existing clone to re-clone or explicitly reset to the rewritten `main`; forks, mirrors, pull-request refs, and hosting-provider caches may retain old objects outside this repository's control.

- [ ] **Step 8: Verify GREEN**

Run:

```bash
bash tests/run.sh
jq empty .config/devbox/global/devbox.json .config/devbox/global/devbox.lock
wezterm --config-file "$PWD/.config/wezterm/wezterm.lua" show-keys --lua >/dev/null
devbox run --config .config/devbox/global test
git diff --check
```

Expected: every command exits 0.

- [ ] **Step 9: Commit**

```bash
git add .config/devbox/global .config/wezterm/wezterm.lua .gitignore README.md tests
git commit -m "fix: make global tool setup reproducible"
```

### Task 5: Remove Pet From the Entire Configuration

**Files:**

- Modify: `tests/test_configuration.sh`
- Delete: `.config/zsh/pet.zsh`
- Modify: `.config/zsh/.zshrc`
- Modify: `.config/devbox/global/devbox.json`
- Modify: `.config/devbox/global/devbox.lock`
- Modify: `.gitignore`
- Modify: `install.sh`
- Modify: `README.md`

- [ ] **Step 1: Write a failing Pet-removal test**

Add one test that fails if any tracked non-design/non-plan file path or content references Pet:

```bash
test_pet_is_absent_from_active_configuration() {
    assert_path_missing "$REPO_ROOT/.config/zsh/pet.zsh"
    assert_file_not_contains "$REPO_ROOT/install.sh" 'pet.zsh'
    assert_file_not_contains "$REPO_ROOT/.config/zsh/.zshrc" 'pet.zsh'
    assert_file_not_contains "$REPO_ROOT/.config/devbox/global/devbox.json" '"pet"'
    assert_file_not_contains "$REPO_ROOT/.gitignore" 'pet.zsh'
}
```

Extend the managed-link cleanup test so `$TARGET_HOME/.config/zsh/pet.zsh` is removed only when it points exactly to `$DOT_DIR/.config/zsh/pet.zsh`; unrelated links and regular files must remain.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
bash tests/test_configuration.sh
```

Expected: FAIL at the first remaining Pet path/reference.

- [ ] **Step 3: Remove Pet**

Delete `.config/zsh/pet.zsh`. Remove its source statement, installer link entry, Devbox package, `.gitignore` exception, and any README mention.

- [ ] **Step 4: Regenerate the lockfile and verify GREEN**

Run:

```bash
devbox install --config .config/devbox/global
bash tests/run.sh
zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
rg -n --hidden --glob '!.git/**' --glob '!docs/superpowers/**' -i '\bpet\b|pet\.zsh' . || true
```

Expected: tests pass and the final search is empty.

- [ ] **Step 5: Commit**

```bash
git add -A .config/zsh .config/devbox/global .gitignore install.sh README.md tests
git commit -m "chore: remove pet configuration"
```

### Task 6: Add Pinned Herdr and Minimal Configuration

**Files:**

- Modify: `tests/test_configuration.sh`
- Create: `.config/herdr/config.toml`
- Modify: `.config/devbox/global/devbox.json`
- Modify: `.config/devbox/global/devbox.lock`
- Modify: `install.sh`
- Modify: `README.md`

- [ ] **Step 1: Write failing Herdr tests**

Add checks for:

```bash
test_herdr_is_pinned_and_minimally_configured() {
    assert_file_contains "$REPO_ROOT/.config/devbox/global/devbox.json" \
        'github:ogulcancelik/herdr/v0.7.5'
    assert_file_contains "$REPO_ROOT/.config/herdr/config.toml" \
        'default_shell = "zsh"'
    assert_file_not_contains "$REPO_ROOT/.config/herdr/config.toml" 'onboarding'
    assert_file_contains "$REPO_ROOT/install.sh" 'devbox git herdr wezterm'
}
```

Also add a functional installer test that runs `setup_dotfiles_links` against an isolated target and asserts `.config/herdr` is an absolute symlink to the test source tree.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
bash tests/run.sh
```

Expected: Herdr package, config, and link assertions fail.

- [ ] **Step 3: Add the minimal Herdr configuration**

Create `.config/herdr/config.toml` with exactly:

```toml
[terminal]
default_shell = "zsh"
```

Add `herdr` to the installer directory link loop.

- [ ] **Step 4: Add the pinned flake package**

Add `github:ogulcancelik/herdr/v0.7.5` as a Devbox flake package in the object-form `packages` configuration. Do not add an update channel or disable onboarding.

Regenerate:

```bash
devbox install --config .config/devbox/global
```

Expected: the lockfile contains the Herdr flake revision and package output.

- [ ] **Step 5: Document normal use and package-managed updates**

Add concise README instructions for launching `herdr`, detaching with its documented prefix, and updating the pinned flake by changing the release tag and regenerating `devbox.lock`. State that `herdr update` is not used for a Nix/Devbox-managed installation.

- [ ] **Step 6: Verify GREEN**

Run:

```bash
bash tests/run.sh
jq empty .config/devbox/global/devbox.json .config/devbox/global/devbox.lock
devbox run --config .config/devbox/global test
devbox run --config .config/devbox/global -- herdr --version
git diff --check
```

Expected: tests exit 0 and Herdr reports version `0.7.5` without launching a session.

- [ ] **Step 7: Commit**

```bash
git add .config/herdr .config/devbox/global install.sh README.md tests
git commit -m "feat: add pinned Herdr setup"
```

### Task 7: Full Verification, Review, and Integration Into Main

**Files:**

- Modify only if verification or review finds a defect.

- [ ] **Step 1: Run the complete offline suite**

```bash
bash tests/run.sh
bash -n install.sh tests/test_helpers.sh tests/test_installer.sh tests/test_configuration.sh tests/run.sh .config/devbox/global/run-tests.sh
zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
jq empty .config/devbox/global/devbox.json .config/devbox/global/devbox.lock
git diff --check
```

Expected: all exit 0.

- [ ] **Step 2: Run tool-backed validation**

```bash
devbox run --config .config/devbox/global test
devbox run --config .config/devbox/global -- herdr --version
wezterm --config-file "$PWD/.config/wezterm/wezterm.lua" show-keys --lua >/dev/null
```

Expected: all exit 0; Herdr reports `0.7.5`.

- [ ] **Step 3: Verify removals and secret patterns**

```bash
test ! -e .config/nvim
test ! -e .config/zsh/pet.zsh
test ! -e nvim.log
rg -n --hidden --glob '!.git/**' --glob '!docs/superpowers/**' -i '\bpet\b|pet\.zsh|kickstart|\.local/state/nvim' . || true
git grep -InE '(BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY|GITHUB_TOKEN|GH_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY|PASSWORD[[:space:]]*=|sk-[A-Za-z0-9_-]{16,})' -- ':(top)**' ':(top,exclude)docs/superpowers/**' || true
```

Expected: removal search and the product/configuration high-confidence secret scan are empty. `docs/superpowers/**` is excluded because the implementation plan itself contains the detector literals.

- [ ] **Step 4: Request code review**

Use `superpowers:requesting-code-review`. Fix any blocking findings with a new failing test first, rerun the full suite, and commit the corrections.

- [ ] **Step 5: Integrate the implementation branch**

In the original worktree, verify the stash entry created in Task 1 contains only the obsolete Neovim lockfile change, then drop that exact stash entry. Fast-forward `main` to `codex/dotfiles-hardening-herdr`. Remove the now-merged implementation worktree and delete only the merged implementation branch so the later mirror contains one local branch.

Expected: `main` is clean and contains every implementation commit.

- [ ] **Step 6: Apply only the managed link changes to the real target**

First inspect the exact current paths:

```bash
ls -ld "$HOME/.config/nvim" "$HOME/.config/zsh/pet.zsh" "$HOME/.config/herdr" 2>/dev/null || true
```

Then source the guarded installer and invoke only link setup and legacy managed-link cleanup:

```bash
bash -c 'source /Users/suzuki_f/dotfiles/install.sh; setup_dotfiles_links; cleanup_legacy_managed_links'
```

This write outside the repository requires approval. The functions must remove the Neovim and Pet links only when they point exactly into this repository, and must create the Herdr link through the normal backup-aware helper.

Verify:

```bash
test ! -e "$HOME/.config/nvim" && test ! -L "$HOME/.config/nvim"
test ! -e "$HOME/.config/zsh/pet.zsh" && test ! -L "$HOME/.config/zsh/pet.zsh"
readlink "$HOME/.config/herdr"
```

Expected: Neovim and Pet managed links are absent; Herdr points to `/Users/suzuki_f/dotfiles/.config/herdr`.

### Task 8: Rewrite and Verify Git History

**Files:**

- No tracked file changes. This task rewrites Git object history and the remote `main` ref.

Run Steps 1-8 in one dedicated persistent Bash session so `EXPECTED_MAIN_TREE` and `HISTORY_REWRITE_DIR` cannot be lost or replaced between commands. Start with `set -euo pipefail` and `cd /Users/suzuki_f/dotfiles`. If that shell session ends unexpectedly, stop and restart Task 8 from Step 1 rather than reconstructing either variable from an unvalidated path.

- [ ] **Step 1: Reconfirm destructive-operation scope**

Run from the original repository:

```bash
git status --short --branch
git branch --format='%(refname:short)'
git tag --list
git remote get-url origin
git rev-parse 'main^{tree}'
git ls-remote --heads --tags origin
```

Expected:

- clean `main`
- exactly one local branch to publish: `main`
- no tags
- remote exactly `https://github.com/romanohu/dotfiles.git`
- the remote advertises exactly `refs/heads/main` and no other heads or tags

Stop before creating a mirror if the remote has any additional head or tag. Fetch the confirmed scope explicitly and recheck local remote-tracking refs:

```bash
git fetch --prune origin '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*'
git for-each-ref --format='%(refname)' refs/remotes/origin refs/tags
git symbolic-ref refs/remotes/origin/HEAD
EXPECTED_MAIN_TREE=$(git rev-parse 'main^{tree}')
test -n "$EXPECTED_MAIN_TREE"
```

Expected: exactly `refs/remotes/origin/HEAD` and `refs/remotes/origin/main`, no tags, `origin/HEAD` is a symbolic ref to `refs/remotes/origin/main`, and `EXPECTED_MAIN_TREE` is non-empty. This network recheck requires approval if the sandbox blocks it.

- [ ] **Step 2: Create a private temporary mirror**

Create an explicit temporary directory under `/tmp` with `mktemp -d`, validate its fixed task-specific prefix, set its mode to `700`, and mirror-clone the local repository into it. Do not use `HOME`, `~`, or a broad directory as a cleanup target.

```bash
HISTORY_REWRITE_DIR=$(mktemp -d /tmp/dotfiles-history-rewrite.XXXXXX)
test -n "$HISTORY_REWRITE_DIR"
case "$HISTORY_REWRITE_DIR" in
  /tmp/dotfiles-history-rewrite.*) ;;
  *) exit 1 ;;
esac
chmod 700 "$HISTORY_REWRITE_DIR"
git clone --mirror /Users/suzuki_f/dotfiles "$HISTORY_REWRITE_DIR/dotfiles.git"
```

- [ ] **Step 3: Rewrite with a pinned git-filter-repo**

Inside the bare mirror, run:

```bash
uvx --from 'git-filter-repo==2.47.0' git-filter-repo --force \
  --path '.config/zsh/.zsh_history' \
  --path-glob '.config/zsh/.zsh_sessions/**' \
  --path-glob '.config/zsh/.zcompdump*' \
  --invert-paths
```

Expected: exit 0. This command may require network approval to obtain the pinned tool.

- [ ] **Step 4: Verify the rewritten mirror before adding a remote**

Run:

```bash
git rev-list --all --objects | rg '\.config/zsh/(\.zsh_history|\.zsh_sessions/|\.zcompdump)' || true
git rev-parse 'main^{tree}'
git for-each-ref --format='%(refname)' refs/heads refs/tags
while IFS= read -r revision; do
  grep_status=0
  git grep -IilE '(BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY|GITHUB_TOKEN|GH_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY|GOOGLE_API_KEY|CLIENT[_-]?SECRET|ACCESS[_-]?TOKEN|PASSWORD[[:space:]]*=|sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,})' "$revision" -- ':(top)**' ':(top,exclude)docs/superpowers/**' || grep_status=$?
  case "$grep_status" in
    0|1) ;;
    *) exit "$grep_status" ;;
  esac
done < <(git rev-list --all)
```

Expected:

- no sensitive Zsh runtime path
- rewritten main tree ID exactly equals `EXPECTED_MAIN_TREE`
- only `refs/heads/main`; no tags
- no high-confidence secret match outside the detector-documentation path

If any check differs, stop without adding the GitHub remote or pushing.

- [ ] **Step 5: Force-push only verified main**

Add the exact remote URL to the sanitized mirror, print it, and request approval for this explicit force-push:

```bash
git remote add origin https://github.com/romanohu/dotfiles.git
git remote get-url origin
git push --force origin refs/heads/main:refs/heads/main
```

Expected: remote `main` updates successfully. Do not use `--mirror`, `--all`, or wildcard refspecs.

- [ ] **Step 6: Synchronize the working repository without hard reset**

From `/Users/suzuki_f/dotfiles`:

```bash
git fetch origin main
git switch --detach origin/main
git branch --force main origin/main
git switch main
```

Expected: local `main` and `origin/main` have the rewritten object ID and the worktree tree is unchanged.

- [ ] **Step 7: Re-run published-history verification**

```bash
git rev-list --all --objects | rg '\.config/zsh/(\.zsh_history|\.zsh_sessions/|\.zcompdump)' || true
git status --short --branch
git rev-parse main origin/main
bash tests/run.sh
devbox run --config .config/devbox/global -- herdr --version
```

Expected: no sensitive paths, clean synchronized branch, passing tests, Herdr `0.7.5`.

- [ ] **Step 8: Remove only the validated temporary mirror**

Revalidate the non-empty fixed prefix and the expected mirror child immediately before deleting that exact task directory:

```bash
test -n "$HISTORY_REWRITE_DIR"
case "$HISTORY_REWRITE_DIR" in
  /tmp/dotfiles-history-rewrite.*) ;;
  *) exit 1 ;;
esac
test -d "$HISTORY_REWRITE_DIR/dotfiles.git"
test -f "$HISTORY_REWRITE_DIR/dotfiles.git/HEAD"
rm -rf -- "$HISTORY_REWRITE_DIR"
```

## Final Acceptance Checklist

- [ ] Offline Bash tests pass.
- [ ] `devbox run --config .config/devbox/global test` passes.
- [ ] Bash, Zsh, JSON, and WezTerm syntax/config checks pass.
- [ ] Neovim and Pet are absent from active tracked configuration.
- [ ] No installer step deletes user editor state or rewrites `.npmrc`.
- [ ] Zsh-link migration backs up the link and preserves its target.
- [ ] Nix, Devbox, Oh My Zsh, plugins, ordinary packages, and Herdr use pinned inputs.
- [ ] `devbox.lock` is tracked.
- [ ] `herdr --version` reports `0.7.5` through Devbox.
- [ ] Remote `main` contains no reachable Zsh history/session/completion-dump paths.
- [ ] Local `main` equals `origin/main` and the worktree is clean.
