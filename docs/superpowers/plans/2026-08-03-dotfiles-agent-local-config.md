# Dotfiles agent workflow and private config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-demand generic Herdr agent launcher, split private WezTerm settings from the public config, safely manage declarative Codex/Claude files, and improve daily shell/Git workflows with offline-safe validation.

**Architecture:** Keep portable files in the repository and install only selected files into real user-owned directories. `ha` is a small shell command that validates one user-selected executable, then uses Herdr's CLI to create exactly one generic agent pane in the current project workspace. WezTerm loads an optional local Lua table for SSH hosts; Herdr and agent credentials remain outside the repository.

**Tech Stack:** Bash, Zsh, Lua (WezTerm), TOML (Herdr), JSON (Devbox), jq, fzf, zoxide, GitHub Actions, and the existing shell test harness.

## Global Constraints

- Do not run `devbox install`, `devbox run`, Nix commands, Herdr, or any real agent during implementation or verification.
- Do not install or authenticate Codex, Claude, Gemini, or any other agent.
- Do not track or link whole `$HOME/.codex` or `$HOME/.claude` directories.
- Never store API keys, session identifiers, transcripts, history, caches, project indexes, or private SSH data in Git.
- Herdr is pinned to `github:ogulcancelik/herdr/v0.7.5`; all package changes must update the manifest and lock together.
- `ha` adds one agent at a time; agent panes are generic and are not assigned service-specific roles.
- Preserve existing user-owned files through the installer backup mechanism and keep macOS, Linux, and WSL behavior intact.

---

### Task 1: Define the `ha` command contract with isolated tests

**Files:**
- Create: `tests/test_agent.sh`
- Create: `.config/dotfiles/agents.local.example`
- Modify: `tests/run.sh`
- Test fixture only: `tests/fixtures/fake-herdr/` created and removed by the test

**Interfaces:**
- Consumes: `HA_CONFIG_PATH`, `HERDR_WORKSPACE_ID`, `HERDR_PANE_ID`, `HERDR_ACTIVE_PANE_CWD`, and a fake `herdr` executable on `PATH`.
- Produces: executable contract for `ha [--dry-run] [COMMAND]`, one command per non-comment line in `agents.local`, and JSON responses for workspace creation and pane splitting.

- [ ] **Step 1: Add failing tests for command selection and no-mutation dry runs.**

  In `tests/test_agent.sh`, create a temporary `bin` directory containing fake `codex`, `claude`, and `herdr` executables. The fake Herdr appends every invocation to `$FAKE_HERDR_LOG` and returns these exact JSON responses:

  ```json
  {"result":{"workspace":{"workspace_id":"w1","cwd":"/tmp/project"},"root_pane":{"pane_id":"w1:p1"}}}
  ```

  for `workspace create`, and:

  ```json
  {"result":{"pane":{"pane_id":"w1:p2"}}}
  ```

  for `pane split`.

  Add tests named `test_ha_dry_run_does_not_call_herdr`, `test_ha_rejects_missing_agent_before_mutation`, `test_ha_uses_explicit_command`, `test_ha_selects_first_configured_command_without_fzf`, and `test_ha_splits_active_pane_and_runs_one_command`. Assert the exact Herdr call order: `pane split`, `pane run`, then `pane rename`.

- [ ] **Step 2: Run the focused test and verify it fails because `bin/ha` is absent.**

  Run:

  ```sh
  bash tests/test_agent.sh
  ```

  Expected: FAIL with a missing `bin/ha` or equivalent command-not-found error.

- [ ] **Step 3: Add the safe local command example.**

  Write `.config/dotfiles/agents.local.example` with comments and exactly two executable names, `codex` and `claude`, one per line. State in comments that the file is copied to `$XDG_CONFIG_HOME/dotfiles/agents.local`, must contain command names only, and must not contain API keys or arguments.

- [ ] **Step 4: Include the focused test in the repository runner.**

  Add `bash "$TEST_DIR/test_agent.sh"` to `tests/run.sh` after the existing configuration and installer tests, preserving `set -euo pipefail` and the existing PASS summary format.

- [ ] **Step 5: Run the focused test again and confirm the failure is now the unimplemented command behavior.**

  Run `bash tests/test_agent.sh`; the test must still fail, but the fixture and contract assertions must execute.

- [ ] **Step 6: Commit the contract tests.**

  ```sh
  git add tests/test_agent.sh tests/run.sh .config/dotfiles/agents.local.example
  git commit -m "test: define generic Herdr agent launcher contract"
  ```

### Task 2: Implement `ha` and expose it through the installer

**Files:**
- Create: `bin/ha`
- Modify: `install.sh:588-599` (`setup_dotfiles_links`)
- Modify: `tests/test_agent.sh`
- Modify: `tests/test_installer.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `ha [--dry-run] [COMMAND]`, `agents.local`, `herdr workspace list/create`, `herdr pane split/run/rename`, and the Herdr environment variables documented in the design.
- Produces: an executable `$HOME/.local/bin/ha` that adds one generic pane and returns nonzero before any Herdr mutation when validation fails.

- [ ] **Step 1: Extend tests for the active-pane and no-workspace paths.**

  Assert that `HERDR_PANE_ID=w1:p1` uses `herdr pane split --current --direction right --no-focus`, parses `.result.pane.pane_id`, runs only the validated command string, and renames the pane to the next `agent-N` label. Add a fixture for `workspace list` that returns no match and verify `workspace create --cwd "$PWD" --label "$(basename "$PWD")" --no-focus` precedes the split.

- [ ] **Step 2: Run `bash tests/test_agent.sh` and confirm the new cases fail.**

- [ ] **Step 3: Implement argument and config parsing in `bin/ha`.**

  Parse at most one positional command and the `--dry-run` flag. Reject unknown options, more than one command, empty command names, names containing characters outside `[A-Za-z0-9._+-]`, and local config lines containing whitespace. Read the local config from `${HA_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/agents.local}`, ignoring blank and `#` comment lines. With no explicit command, choose the first valid configured command when `fzf` is unavailable; with `fzf`, present the validated command list and use the selected line.

- [ ] **Step 4: Implement preflight and Herdr orchestration.**

  Use `command -v` to validate both the selected agent and Herdr before any mutation. Query `herdr workspace list` when no `HERDR_WORKSPACE_ID` is available, reuse a workspace whose `cwd` is the physical current directory, and otherwise create one with `workspace create --cwd "$PWD" --label "$(basename "$PWD")" --no-focus`. Split the current/root pane, run the single executable name through `herdr pane run`, and rename the new pane to the next available `agent-N`. Parse each response with `jq -e` and fail without continuing if a required pane or workspace ID is missing.

- [ ] **Step 5: Implement `--dry-run` as a side-effect-free path.**

  Print the selected command, resolved config path, current directory, and planned Herdr operations. Do not call `herdr`, create directories, write files, or invoke the selected agent.

- [ ] **Step 6: Link the command into `$HOME/.local/bin` safely.**

  Add `safe_link_or_copy "$DOT_DIR/bin/ha" "$TARGET_HOME/.local/bin/ha"` to `setup_dotfiles_links`, ensure the parent is checked by the existing target-path guard, and keep the source executable. Add an installer fixture that verifies the link points to the physical repository and that an unrelated existing `ha` file is backed up.

- [ ] **Step 7: Add local-file ignore rules.**

  Ignore `.config/dotfiles/agents.local`, `.config/wezterm/local.lua`, and generated local agent state paths. Do not ignore the `.example` files.

- [ ] **Step 8: Run focused verification and commit.**

  ```sh
  bash tests/test_agent.sh
  bash tests/test_installer.sh
  bash -n bin/ha install.sh tests/test_agent.sh
  git diff --check
  git add bin/ha install.sh tests/test_agent.sh tests/test_installer.sh .gitignore
  git commit -m "feat: add on-demand Herdr agent launcher"
  ```

### Task 3: Split WezTerm into portable and local configuration

**Files:**
- Modify: `.config/wezterm/wezterm.lua:1-65`
- Create: `.config/wezterm/local.lua.example`
- Modify: `install.sh:552-599`
- Modify: `tests/test_configuration.sh`
- Modify: `tests/test_installer.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: optional `$HOME/.config/wezterm/local.lua` returning a Lua table with `ssh_hosts` entries.
- Produces: a portable `wezterm.lua` with no real SSH hostnames and an installer that preserves a real local WezTerm directory.

- [ ] **Step 1: Add failing configuration assertions.**

  Test that the tracked portable file contains no `SSH:` domain names, contains an optional `dofile`/protected-import path, and generates bindings from `local.ssh_hosts`. Test that `local.lua.example` contains only placeholder domains and the documented table shape.

- [ ] **Step 2: Add failing installer migration fixtures.**

  Create a target with the old exact symlink `$TARGET_HOME/.config/wezterm -> $physical_source/.config/wezterm`, run `setup_dotfiles_links`, and assert that the target becomes a real directory, `wezterm.lua` links to the physical source, and an unrelated local file remains untouched. Add a case where an unrelated symlinked parent is rejected.

- [ ] **Step 3: Run the focused configuration and installer tests and confirm failure.**

  ```sh
  bash tests/test_configuration.sh
  bash tests/test_installer.sh
  ```

- [ ] **Step 4: Implement the optional local Lua import.**

  Load `$HOME/.config/wezterm/local.lua` with `pcall(dofile, path)` and default to an empty table when the file is absent or invalid. Generate each SSH tab binding only from `local.ssh_hosts`, accepting `{ key, domain, label }` entries and ignoring malformed entries without evaluating arbitrary command strings. Keep all existing portable font, monitoring, split, and navigation behavior.

- [ ] **Step 5: Replace whole-directory WezTerm linking with per-file linking.**

  Add `prepare_wezterm_dir` beside `prepare_zsh_dir`. It must back up only the exact old managed directory symlink, create `$TARGET_HOME/.config/wezterm` as a real directory, and link/copy only `wezterm.lua`. Unrelated real directories and symlinks must be preserved or rejected by the existing safety rules.

- [ ] **Step 6: Document local setup and remove the old host-specific examples.**

  Add a README section showing how to copy the example to `$HOME/.config/wezterm/local.lua`, explain that hostnames remain local, and document the migration backup path. Keep `local.lua` out of tracked files.

- [ ] **Step 7: Run focused checks and commit.**

  ```sh
  bash tests/test_configuration.sh
  bash tests/test_installer.sh
  bash -n install.sh
  git diff --check
  git add .config/wezterm/wezterm.lua .config/wezterm/local.lua.example install.sh tests/test_configuration.sh tests/test_installer.sh README.md
  git commit -m "feat: separate private WezTerm settings"
  ```

### Task 4: Configure Herdr for generic agent panes

**Files:**
- Modify: `.config/herdr/config.toml`
- Modify: `.config/wezterm/wezterm.lua`
- Modify: `tests/test_configuration.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: the `ha` executable and the existing Herdr `terminal.default_shell` setting.
- Produces: a `prefix+a` Herdr command for `ha`, follow-current-directory pane behavior, and a WezTerm leader shortcut that opens Herdr without embedding SSH hostnames.

- [ ] **Step 1: Add failing static configuration tests.**

  Assert `terminal.default_shell = "zsh"`, `terminal.new_cwd = "follow"`, a `[[keys.command]]` entry with `key = "prefix+a"` and `command = "ha"`, and no agent-specific role labels. Assert the WezTerm shortcut invokes `herdr` only.

- [ ] **Step 2: Run `bash tests/test_configuration.sh` and confirm the new assertions fail.**

- [ ] **Step 3: Add the minimal Herdr configuration.**

  Keep the existing terminal setting, add `new_cwd = "follow"`, and add one shell custom command with a description such as `add one generic agent pane`. Do not add integration-install commands, model names, API settings, or service-specific layouts.

- [ ] **Step 4: Add the portable WezTerm Herdr shortcut.**

  Add one leader binding that opens `herdr` in a new tab. Do not reintroduce host-specific SSH bindings.

- [ ] **Step 5: Document workspace and agent operation.**

  Document `herdr workspace create --cwd ... --label ...`, `Ctrl+B` then `Shift+N`, `Ctrl+B` then `W`, `ha`, `ha codex`, and `ha claude`. State that integration installation is manual and optional.

- [ ] **Step 6: Run checks and commit.**

  ```sh
  bash tests/test_configuration.sh
  zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
  git diff --check
  git add .config/herdr/config.toml .config/wezterm/wezterm.lua tests/test_configuration.sh README.md
  git commit -m "feat: add generic Herdr agent shortcuts"
  ```

### Task 5: Add safe Codex and Claude instruction boundaries

**Files:**
- Create: `.codex/AGENTS.md`
- Create: `.claude/CLAUDE.md`
- Modify: `install.sh`
- Modify: `tests/test_configuration.sh`
- Modify: `tests/test_installer.sh`
- Modify: `README.md`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: two public Markdown instruction files and the installer allowlist.
- Produces: individually managed files under real `$HOME/.codex` and `$HOME/.claude` directories, with unrelated runtime state preserved.

- [ ] **Step 1: Add failing boundary tests.**

  Add fixtures containing an existing auth-looking file, a session directory, an unrelated settings file, and the public instruction target. Assert that setup links only the instruction file, leaves all unrelated files byte-for-byte unchanged, rejects symlinked target parents, and never tracks names matching `auth`, `session`, `history`, `transcript`, `cache`, or `projects` under these directories.

- [ ] **Step 2: Run the focused tests and confirm failure because the files and installer mapping do not exist.**

- [ ] **Step 3: Add neutral public instruction files.**

  Write `.codex/AGENTS.md` and `.claude/CLAUDE.md` with the same repository-safe rules: preserve user intent, keep changes scoped, avoid credential/session files, and run the repository's host-independent tests before claiming completion. Do not include a model name, API endpoint, private path, or service-specific pane role.

- [ ] **Step 4: Implement explicit per-file installation.**

  Add `setup_agent_config_links` that creates real target directories and calls `safe_link_or_copy` only for the two Markdown files. Keep the function separate from the whole-directory `devbox`, `git`, and `herdr` links. Do not merge this into the generic directory loop.

- [ ] **Step 5: Add ignore rules and documentation.**

  Ignore runtime/auth/session/cache paths under `.codex` and `.claude`, keep the two Markdown files tracked, and document that settings or hooks are added only after their exact public schema/content is reviewed.

- [ ] **Step 6: Run tests and commit.**

  ```sh
  bash tests/test_configuration.sh
  bash tests/test_installer.sh
  bash -n install.sh
  git diff --check
  git add .codex .claude install.sh tests/test_configuration.sh tests/test_installer.sh README.md .gitignore
  git commit -m "feat: manage safe Codex and Claude instructions"
  ```

### Task 6: Improve daily shell and Git defaults

**Files:**
- Modify: `.config/devbox/global/devbox.json`
- Modify: `.config/devbox/global/devbox.lock`
- Modify: `.config/zsh/.zshrc`
- Modify: `.config/zsh/aliases.zsh`
- Modify: `.config/git/config`
- Modify: `tests/test_configuration.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: existing pinned Devbox package/lock conventions, `fzf`, and Zsh's guarded command initialization.
- Produces: pinned `zoxide`, guarded `z` initialization, safe fzf Git helpers, and conservative Git defaults.

- [ ] **Step 1: Add failing manifest and shell assertions.**

  Assert that `zoxide` is an exact object-form package pin, the lock contains the corresponding package entry, `.zshrc` guards `zoxide init zsh`, and aliases define `gcof` (branch picker) and `glogf` (commit picker) without `eval` or unquoted command substitution.

- [ ] **Step 2: Run the focused configuration test and confirm failure.**

- [ ] **Step 3: Add the pinned package and regenerate only the lock metadata.**

  Add the exact package pin `zoxide@0.9.8` to `devbox.json`, then use the repository's documented `devbox update --no-install --config .config/devbox/global` workflow to resolve the lock. Do not run `devbox install`, `devbox run`, or any build.

- [ ] **Step 4: Add guarded Zsh and fzf helpers.**

  Initialize zoxide only when both `zoxide` and Zsh are available. Implement `gcof` with `git for-each-ref` piped into `fzf`, then pass the selected ref to `git switch`; implement `glogf` with `git log --oneline` and `git show` after selection. Empty selections must return without changing repository state.

- [ ] **Step 5: Add Git defaults.**

  Add `fetch.prune = true`, `rerere.enabled = true`, and `push.autoSetupRemote = true` under their existing sections. Do not change identity, remote URLs, branch history, or repository-local overrides.

- [ ] **Step 6: Run checks and commit.**

  ```sh
  bash tests/test_configuration.sh
  zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
  jq empty .config/devbox/global/devbox.json .config/devbox/global/devbox.lock
  git diff --check
  git add .config/devbox/global/devbox.json .config/devbox/global/devbox.lock .config/zsh/.zshrc .config/zsh/aliases.zsh .config/git/config tests/test_configuration.sh README.md
  git commit -m "feat: improve shell and Git workflow defaults"
  ```

### Task 7: Add CI-equivalent repository checks and finish documentation

**Files:**
- Create: `.github/workflows/validate.yml`
- Modify: `tests/run.sh`
- Modify: `tests/test_configuration.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: the existing test runner and static checks; no Devbox or Herdr runtime.
- Produces: a GitHub Actions job that runs the same host-independent checks as local verification.

- [ ] **Step 1: Add failing tests for the CI command contract and forbidden paths.**

  Assert that the workflow invokes `bash tests/run.sh`, all shell syntax checks, `jq empty` for both Devbox files, and `git diff --check`. Add tracked-file assertions for forbidden Codex/Claude runtime names and known historical WezTerm host bindings.

- [ ] **Step 2: Run the focused tests and confirm failure because the workflow is absent.**

- [ ] **Step 3: Create the workflow with pinned actions.**

  Use a single Ubuntu job with `actions/checkout@v4.2.2`, then run the exact commands from the repository test section. The workflow must not run `devbox install`, Herdr, Nix, agent CLIs, or networked package resolution.

- [ ] **Step 4: Complete README usage and maintenance sections.**

  Document `local.lua`, `agents.local`, `ha`, workspace creation/switching, the safe Codex/Claude boundary, fzf helpers, zoxide, and the CI/local verification command. Keep the existing no-runtime-verification boundary explicit.

- [ ] **Step 5: Run the complete host-side verification and commit.**

  ```sh
  bash tests/run.sh
  bash -n install.sh bin/ha tests/test_helpers.sh tests/test_installer.sh tests/test_configuration.sh tests/test_agent.sh tests/run.sh .config/devbox/global/run-tests.sh
  zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
  jq empty .config/devbox/global/devbox.json .config/devbox/global/devbox.lock
  git diff --check
  git add .github/workflows/validate.yml tests/run.sh tests/test_configuration.sh README.md
  git commit -m "ci: validate private config boundaries"
  ```

### Task 8: Final review and handoff

**Files:**
- Modify only files required by review findings from Tasks 1–7.

**Interfaces:**
- Consumes: all task commits and the approved design at `docs/superpowers/specs/2026-08-03-dotfiles-agent-local-config-design.md`.
- Produces: a clean, reviewable branch with no runtime installation side effects.

- [ ] **Step 1: Compare the implementation against every design section.**

  Confirm that WezTerm hostnames are local-only, `ha` adds one generic pane, Codex/Claude runtime state is excluded, shell/Git fallbacks are safe, and CI uses only static/host tests.

- [ ] **Step 2: Run the final host-side suite.**

  ```sh
  bash tests/run.sh
  bash -n install.sh bin/ha tests/test_helpers.sh tests/test_installer.sh tests/test_configuration.sh tests/test_agent.sh tests/test_runner.sh tests/run.sh .config/devbox/global/run-tests.sh
  zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
  jq empty .config/devbox/global/devbox.json .config/devbox/global/devbox.lock
  git diff --check
  git status --short --branch
  ```

  Expected: all tests pass, no syntax errors, no diff-check output, and only intentional committed changes remain.

- [ ] **Step 3: Review the final diff for secret or state leakage.**

  ```sh
  git diff --cached --check
  git ls-files '.codex/*' '.claude/*' '.config/wezterm/*' '.config/dotfiles/*'
  rg -n 'SSH:|api[_-]?key|token|secret|session|transcript|history|cache' .codex .claude .config/wezterm .config/dotfiles || true
  ```

  Remove any generated state or private hostname before handoff.

- [ ] **Step 4: Commit only review fixes and report the runtime boundary.**

  Do not run or claim a real Herdr/agent/Devbox session. Report that the configuration is ready for the user to apply later.
