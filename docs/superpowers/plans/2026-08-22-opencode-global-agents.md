# OpenCode Global AGENTS.md Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a repository-managed global OpenCode `AGENTS.md` with the same shared implementation rules used by Codex and Claude.

**Architecture:** Track `.config/opencode/AGENTS.md` as an independent copy of `.codex/AGENTS.md`. Add it to mise's `[dotfiles]` mappings and to `install.sh`'s existing conflict-safe preflight list so bootstrap links it to `~/.config/opencode/AGENTS.md` without overwriting unmanaged state.

**Tech Stack:** Markdown instruction files, Bash installer/tests, TOML mise configuration, existing offline shell test helpers.

## Global Constraints

- Keep `.config/opencode/AGENTS.md` content identical to `.codex/AGENTS.md`.
- Add the exact mise mapping: `"~/.config/opencode/AGENTS.md" = ".config/opencode/AGENTS.md"`.
- Preserve the installer rule that existing files, directories, unrelated symlinks, and symlinked ancestors are rejected rather than overwritten.
- Increase the managed-target count from 12 to 13 everywhere it is asserted.
- Do not change `.codex/AGENTS.md`, `.claude/CLAUDE.md`, `.config/opencode/opencode.jsonc`, `.config/opencode/tui.json`, permission/plugin settings, WezTerm, Codex, Claude, or shell configuration.
- Preserve the existing user-owned uncommitted `.config/zsh/.zshrc` change; never stage it.

---

### Task 1: Add failing regression coverage for the OpenCode global rules file

**Files:**
- Modify: `tests/test_configuration.sh:218-245, invocation list`
- Modify: `tests/test_mise_configuration.sh:205-230`
- Modify: `tests/test_installer.sh:554-629`

**Interfaces:**
- Tests consume the future `.config/opencode/AGENTS.md` source, its mise mapping, and its managed-target preflight entry.
- Later production work must satisfy the exact assertions and 13-target fixture lists introduced here.

- [ ] **Step 1: Add the failing configuration assertion**

Add a test beside the existing OpenCode tests that compares the new file byte-for-byte with the shared Codex rules:

```bash
test_opencode_global_agents_is_shared() {
    local config="$REPO_DIR/.config/opencode/AGENTS.md"
    local source="$REPO_DIR/.codex/AGENTS.md"

    assert_path_exists "$config"
    assert_path_exists "$source"
    assert_eq "$(cat "$source")" "$(cat "$config")" \
        'OpenCode global AGENTS.md must match the shared rules'
}
```

Invoke it with the other OpenCode configuration tests. Extend the README assertions to require `all thirteen managed targets`, `~/.config/opencode/AGENTS.md`, and a phrase documenting OpenCode global rules.

- [ ] **Step 2: Require the exact mise mapping**

Add this line to the expected `[dotfiles]` block in `test_mise_bootstrap_repositories_dotfiles_and_settings_are_exact`:

```text
"~/.config/opencode/AGENTS.md" = ".config/opencode/AGENTS.md"
```

- [ ] **Step 3: Extend installer preflight fixtures**

Add the new relative target/source pair after the existing OpenCode TUI pair in both fixture lists:

```text
'.config/opencode/AGENTS.md' '.config/opencode/AGENTS.md'
```

Change the repeated-link count and preflight fixture count from `12` to `13`. Add an `assert_link_points_to` check for the new target alongside the existing Claude assertion.

- [ ] **Step 4: Run the RED checks**

Run:

```sh
bash tests/test_configuration.sh
bash tests/test_mise_configuration.sh
bash tests/test_installer.sh
```

Expected failures are the missing OpenCode AGENTS source, missing mise mapping, and omitted installer preflight target. Do not change production files in this task.

- [ ] **Step 5: Commit the failing tests**

```sh
git add tests/test_configuration.sh tests/test_mise_configuration.sh tests/test_installer.sh
git commit -m "test: cover OpenCode global rules"
```

### Task 2: Implement and document the managed global rules file

**Files:**
- Create: `.config/opencode/AGENTS.md`
- Modify: `mise.toml:[dotfiles]`
- Modify: `install.sh:preflight_managed_dotfiles`
- Modify: `README.md:managed targets/OpenCode permissions`

**Interfaces:**
- `.config/opencode/AGENTS.md` produces the global OpenCode rules content.
- `mise.toml` maps it to `~/.config/opencode/AGENTS.md`.
- `preflight_managed_dotfiles` validates the target/source before bootstrap.

- [ ] **Step 1: Create the exact shared rules file**

Copy `.codex/AGENTS.md` byte-for-byte into `.config/opencode/AGENTS.md`; do not edit either existing source file.

- [ ] **Step 2: Add the mise mapping**

Add this exact entry to `[dotfiles]` after the existing OpenCode mappings:

```toml
"~/.config/opencode/AGENTS.md" = ".config/opencode/AGENTS.md"
```

- [ ] **Step 3: Add installer preflight validation**

Immediately after the existing OpenCode TUI validation in `preflight_managed_dotfiles`, add:

```bash
    validate_managed_dotfile_target \
        "$TARGET_HOME/.config/opencode/AGENTS.md" \
        "$DOT_DIR/.config/opencode/AGENTS.md" || return 1
```

- [ ] **Step 4: Update README without changing unrelated claims**

Change the managed-target count to thirteen. In the OpenCode section, document that the repository also manages `~/.config/opencode/AGENTS.md` as OpenCode's global rules file and that its shared implementation guidelines match the Codex/Claude rules. Preserve the existing permission, superpowers plugin, system theme, and user-owned Codex statements.

- [ ] **Step 5: Run focused GREEN checks**

Run:

```sh
bash tests/test_configuration.sh
bash tests/test_mise_configuration.sh
bash tests/test_installer.sh
jq empty .config/opencode/tui.json
bash -n install.sh tests/*.sh
zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
git diff --check
```

Expected result: all focused tests and syntax checks pass; WezTerm and existing OpenCode JSONC remain unchanged.

- [ ] **Step 6: Commit production and documentation changes**

```sh
git add .config/opencode/AGENTS.md mise.toml install.sh README.md
git commit -m "feat: manage OpenCode global rules"
```

### Task 3: Run the complete verification and inspect boundaries

**Files:**
- Verify only: `.config/opencode/AGENTS.md`, `mise.toml`, `install.sh`, `README.md`, and the three test files.

**Interfaces:**
- The branch must expose the 13-target managed configuration with passing offline tests and a valid locked mise configuration.

- [ ] **Step 1: Run the complete offline verification**

```sh
bash tests/run.sh
bash -n install.sh tests/*.sh
zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
jq empty .config/opencode/tui.json
git diff --check
mise install --locked --dry-run
```

Confirm `PASS: 4 test file(s)` and that the locked mise dry run does not add an untracked tool.

- [ ] **Step 2: Review final diff boundaries**

Confirm the feature diff contains only the new OpenCode rules file, mise mapping, installer preflight, README, and the three regression-test files. Confirm `.config/zsh/.zshrc` remains unstaged and unchanged by this feature; confirm `.codex/AGENTS.md`, `.claude/CLAUDE.md`, WezTerm, and OpenCode JSON/TUI configuration are unchanged.

- [ ] **Step 3: Commit only if verification changes remain**

If Task 1 and Task 2 already produced the two focused commits and no changes remain, do not create an empty commit. Otherwise stage only the listed feature files and commit with a focused message.

