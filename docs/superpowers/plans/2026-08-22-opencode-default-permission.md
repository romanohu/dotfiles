# OpenCode Allow Permission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or superpowers:subagent-driven-development) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manage OpenCode's shared configuration through mise and make its default permission mode `allow` without changing Codex behavior.

**Architecture:** Add one repository-owned JSONC file containing the existing OpenCode schema/plugin settings and the global `permission: "allow"` value. Register that file in mise's `[dotfiles]` map and add it to `install.sh`'s managed-target preflight so the existing collision protection covers the new link. Extend the current offline assertions and README without introducing a shell wrapper or replacing the Codex configuration.

**Tech Stack:** JSONC-compatible JSON, Bash, TOML/mise dotfiles, existing shell test helpers.

## Global Constraints

- Do not modify `~/.codex/config.toml`, Codex rules, Codex profiles, or any other Codex state.
- Preserve the existing superpowers plugin declaration exactly.
- Do not stage or overwrite the user's pre-existing `.config/zsh/.zshrc` modification.
- Use file-level linking for `~/.config/opencode/opencode.jsonc`; do not manage the whole OpenCode directory.
- Reject unmanaged existing targets through the existing `validate_managed_dotfile_target` path.
- Keep host-independent tests free of new runtime/network dependencies.

---

### Task 1: Add failing OpenCode configuration and mapping assertions

**Files:**
- Modify: `tests/test_configuration.sh`
- Modify: `tests/test_mise_configuration.sh`
- Modify: `tests/test_installer.sh`

**Interfaces:**
- Consumes: existing `assert_file_*`, `assert_eq`, `assert_path_*`, and
  `preflight_managed_dotfiles` test patterns.
- Produces: regression coverage for the exact OpenCode file, mise mapping, and
  managed-target preflight count.

- [ ] **Step 1: Add the OpenCode content assertion.**

Add this function before the test-call list in `tests/test_configuration.sh`:

```bash
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
```

Call `test_opencode_default_permission_is_shared` after the existing
configuration tests.

- [ ] **Step 2: Extend the exact mise mapping expectation.**

In `test_mise_bootstrap_repositories_dotfiles_and_settings_are_exact`, add
this line after the WezTerm mapping in the expected block:

```bash
'"~/.config/opencode/opencode.jsonc" = ".config/opencode/opencode.jsonc"' \
```

The test must continue to compare the complete expected block, so an omitted
or extra dotfile mapping fails.

- [ ] **Step 3: Extend installer preflight fixtures for the eleventh target.**

In `test_exact_managed_dotfile_links_are_idempotent`, add the pair:

```bash
'.config/opencode/opencode.jsonc' '.config/opencode/opencode.jsonc' \
```

after the WezTerm pair and change the expected symlink count from `10` to
`11`. In `test_each_managed_dotfile_target_is_preflighted`, add the same
relative target to the loop and change the expected fixture count from `10`
to `11`. These tests must fail before the production preflight list is
updated, proving the new target cannot be silently omitted.

- [ ] **Step 4: Run the focused tests and confirm RED.**

Run:

```sh
bash tests/test_configuration.sh
bash tests/test_mise_configuration.sh
bash tests/test_installer.sh
```

Expected: failures identify the missing OpenCode file/mapping and the
unchanged ten-target installer preflight; no existing user file is modified.

### Task 2: Implement the shared OpenCode configuration and managed link

**Files:**
- Create: `.config/opencode/opencode.jsonc`
- Modify: `mise.toml`
- Modify: `install.sh:385-407`

**Interfaces:**
- Consumes: the existing mise `[dotfiles]` bootstrap and
  `validate_managed_dotfile_target` collision guard.
- Produces: a repository source file that mise links to
  `~/.config/opencode/opencode.jsonc`, with preflight protection before any
  bootstrap mutation.

- [ ] **Step 1: Create the exact OpenCode file.**

Write `.config/opencode/opencode.jsonc` with one trailing newline and no
comments:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": ["superpowers@git+https://github.com/obra/superpowers.git"],
  "permission": "allow"
}
```

- [ ] **Step 2: Register the file in mise.**

Append this entry to the existing `[dotfiles]` table in `mise.toml`, keeping
the current ordering and all other mappings unchanged:

```toml
"~/.config/opencode/opencode.jsonc" = ".config/opencode/opencode.jsonc"
```

- [ ] **Step 3: Add installer preflight coverage.**

In `preflight_managed_dotfiles`, after the WezTerm validation and before the
Codex/Claude validations, add:

```bash
    validate_managed_dotfile_target \
        "$TARGET_HOME/.config/opencode/opencode.jsonc" \
        "$DOT_DIR/.config/opencode/opencode.jsonc" || return 1
```

Do not add a new link-creation mechanism; `run_mise_bootstrap` remains the
single mutating path for the mapping.

- [ ] **Step 4: Run focused tests and verify GREEN.**

Run the three commands from Task 1 again. Expected: all three exit zero,
including the exact content, complete mapping, and eleven-target preflight
assertions.

### Task 3: Update user-facing documentation and run the complete gates

**Files:**
- Modify: `README.md`
- Test: `tests/test_configuration.sh`, `tests/test_mise_configuration.sh`,
  `tests/test_installer.sh`, `tests/run.sh`

**Interfaces:**
- Consumes: the completed shared OpenCode file and mise/installer mapping.
- Produces: documentation and verification evidence that Codex remains
  unchanged and the new configuration is portable.

- [ ] **Step 1: Document the OpenCode boundary and permission.**

Add an `OpenCode permissions` subsection near the Shell/Herdr usage section:

```markdown
## OpenCode permissions

The repository manages `~/.config/opencode/opencode.jsonc`, keeps the shared
superpowers plugin enabled, and sets OpenCode's default permission mode to
`allow`. Codex configuration and approval behavior remain user-owned and are
not changed by this repository.
```

Change the existing README sentence from “all ten managed targets” to “all
eleven managed targets” and add `.config/opencode` to the repository layout
tree.

- [ ] **Step 2: Add README regression assertions.**

In `test_readme_documents_mise_setup_and_boundaries`, assert the README
contains `OpenCode permissions`, `permission mode to`, and
`all eleven managed targets`, and assert it contains `Codex configuration and
approval behavior remain user-owned`. Keep the existing no-secret and no-
Devbox assertions unchanged.

- [ ] **Step 3: Run the complete host-independent verification.**

Run:

```sh
bash tests/run.sh
bash -n install.sh tests/*.sh
zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
jq empty .config/opencode/opencode.jsonc
git diff --check
```

Expected: every test file passes, both shell syntax checks exit zero, the
OpenCode file parses as JSON, and `git diff --check` is silent. Confirm
`git status --short` still shows the pre-existing `.config/zsh/.zshrc`
modification and does not include any Codex file.

- [ ] **Step 4: Commit only the implementation files.**

Stage the new config, `mise.toml`, `install.sh`, README, and the three tests;
leave `.config/zsh/.zshrc` unstaged. Commit with:

```sh
git add .config/opencode/opencode.jsonc mise.toml install.sh README.md \
    tests/test_configuration.sh tests/test_mise_configuration.sh \
    tests/test_installer.sh
git commit -m "feat: manage OpenCode allow permissions"
```

Do not push in this plan; publishing remains a separate explicit action.

## Self-review checklist

- [ ] The exact mapping appears in both `mise.toml` and the tests.
- [ ] The installer preflights all eleven managed targets before mise runs.
- [ ] The OpenCode file preserves superpowers and has only the requested
  permission change.
- [ ] No Codex configuration or rules are edited or staged.
- [ ] No placeholder, network-dependent, or wrapper-based step remains.
