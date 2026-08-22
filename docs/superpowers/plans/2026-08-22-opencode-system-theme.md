# OpenCode system theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the shared OpenCode TUI inherit WezTerm's colors and transparent background through the official `system` theme.

**Architecture:** Add a separate tracked `.config/opencode/tui.json` containing the `system` theme, map it through mise alongside the existing OpenCode permission file, and include it in installer preflight protection. Extend the offline shell/configuration tests and README without changing WezTerm or the existing `opencode.jsonc`.

**Tech Stack:** OpenCode TUI JSON, mise TOML dotfile mappings, Bash tests, `jq`, Zsh, WezTerm.

## Global Constraints

- Make OpenCode follow the existing WezTerm color and transparency settings.
- Share the theme choice through the dotfiles repository and mise bootstrap.
- Keep the existing shared OpenCode permission mode and superpowers plugin.
- Keep the change portable across supported macOS and Linux hosts.
- Do not change WezTerm opacity, blur, color scheme, or font settings.
- Do not change OpenCode permissions, plugins, or Codex/Claude configuration.
- Do not define a custom color palette or add project-specific themes.
- Do not edit user-owned shell changes or remove existing system software.
- The exact theme file content is:
  ```json
  {
    "$schema": "https://opencode.ai/tui.json",
    "theme": "system"
  }
  ```
- The exact mise mapping is:
  ```toml
  "~/.config/opencode/tui.json" = ".config/opencode/tui.json"
  ```

---

## Task 1: Add failing regression coverage for the shared system theme

**Files:**
- Modify: `tests/test_configuration.sh`
- Modify: `tests/test_mise_configuration.sh`
- Modify: `tests/test_installer.sh`

**Interfaces:**
- The configuration test will validate `.config/opencode/tui.json` independently from `.config/opencode/opencode.jsonc`.
- The mise test will require the new `[dotfiles]` mapping.
- Installer preflight tests will treat `~/.config/opencode/tui.json` as the twelfth managed target.

- [ ] **Step 1: Write the failing configuration assertions**

  Add a focused test beside `test_opencode_default_permission_is_shared` that reads `.config/opencode/tui.json`, requires this exact content, and rejects a theme other than `system`:

  ```bash
  expected=$(printf '%s\n' \
      '{' \
      '  "$schema": "https://opencode.ai/tui.json",' \
      '  "theme": "system"' \
      '}')
  assert_path_exists "$config"
  assert_eq "$expected" "$(cat "$config")" \
      'OpenCode must use the terminal-adaptive system theme'
  ```

  Add the new test name to the invocation list at the bottom of the file. Update the README assertion from eleven to twelve managed targets and require the OpenCode section to mention the system theme.

- [ ] **Step 2: Require the mise mapping and preflight target**

  In `test_mise_bootstrap_repositories_dotfiles_and_settings_are_exact`, add this exact line to the expected `[dotfiles]` list:

  ```text
  "~/.config/opencode/tui.json" = ".config/opencode/tui.json"
  ```

  In `test_exact_managed_dotfile_links_are_idempotent` and
  `test_each_managed_dotfile_target_is_preflighted`, add the new relative target/source pair and change the expected managed-link/fixture count from `11` to `12`.

- [ ] **Step 3: Run the RED checks**

  Run:

  ```sh
  bash tests/test_configuration.sh
  bash tests/test_mise_configuration.sh
  bash tests/test_installer.sh
  ```

  Expected result: each command fails because `tui.json`, its mise mapping, and its installer preflight entry do not exist yet. Do not change production files until these failures are observed.

## Task 2: Implement and document the system theme

**Files:**
- Create: `.config/opencode/tui.json`
- Modify: `mise.toml:[dotfiles]`
- Modify: `install.sh:preflight_managed_dotfiles`
- Modify: `README.md`

**Interfaces:**
- OpenCode reads `.config/opencode/tui.json` as a separate TUI configuration file.
- mise creates `~/.config/opencode/tui.json` from the tracked repository file.
- `preflight_managed_dotfiles` validates the target against the repository source before bootstrap can modify it.

- [ ] **Step 1: Add the exact TUI configuration**

  Create `.config/opencode/tui.json` with exactly:

  ```json
  {
    "$schema": "https://opencode.ai/tui.json",
    "theme": "system"
  }
  ```

- [ ] **Step 2: Link and protect the file**

  Add the exact mapping to the `[dotfiles]` section of `mise.toml`:

  ```toml
  "~/.config/opencode/tui.json" = ".config/opencode/tui.json"
  ```

  Add this validation to `preflight_managed_dotfiles` immediately after the existing OpenCode permission-file validation:

  ```bash
  validate_managed_dotfile_target \
      "$TARGET_HOME/.config/opencode/tui.json" \
      "$DOT_DIR/.config/opencode/tui.json" || return 1
  ```

- [ ] **Step 3: Update the user-facing documentation**

  Change README's managed-target count to twelve and update the OpenCode section to state that the repository also manages `~/.config/opencode/tui.json` with the `system` theme, which inherits terminal colors/background. Keep the existing permission and plugin statements unchanged.

- [ ] **Step 4: Run the GREEN checks**

  Run:

  ```sh
  bash tests/test_configuration.sh
  bash tests/test_mise_configuration.sh
  bash tests/test_installer.sh
  jq empty .config/opencode/tui.json
  bash -n install.sh tests/*.sh
  zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
  ```

  Expected result: all focused tests and syntax/JSON checks pass, with no changes to `.config/wezterm/wezterm.lua` or `.config/opencode/opencode.jsonc`.

## Task 3: Full verification and focused commit

**Files:**
- Verify only: `.config/opencode/tui.json`, `mise.toml`, `install.sh`, `README.md`, and the three test files above.

- [ ] **Step 1: Run the complete offline verification**

  Run:

  ```sh
  bash tests/run.sh
  bash -n install.sh tests/*.sh
  zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
  jq empty .config/opencode/tui.json
  git diff --check
  mise install --locked --dry-run
  ```

  Confirm the suite reports `PASS: 4 test file(s)` and the dry-run accepts the lock without attempting to add an untracked tool.

- [ ] **Step 2: Review the final diff boundaries**

  Confirm `git diff --cached --name-only` contains only the requested theme, installer, README, mise, and test files before committing. Confirm `.config/wezterm/wezterm.lua` and `.config/opencode/opencode.jsonc` are unchanged. Preserve any unrelated user-owned working-tree changes, including a pre-existing `.config/zsh/.zshrc` modification that must not be staged.

- [ ] **Step 3: Commit the implementation**

  Stage only the requested files and commit:

  ```sh
  git add .config/opencode/tui.json mise.toml install.sh README.md \
      tests/test_configuration.sh tests/test_mise_configuration.sh \
      tests/test_installer.sh
  git commit -m "feat: use OpenCode system theme"
  ```

  After the commit, report that users must restart OpenCode (or run `/theme`) to observe the inherited WezTerm background. Do not push until explicitly requested.
