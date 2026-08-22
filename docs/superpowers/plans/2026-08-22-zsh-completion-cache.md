# Zsh Completion Cache Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce the repeated startup cost of WezTerm tabs by giving Oh My Zsh's completion system a stable, user-writable cache and compdump location while keeping completion and its security checks enabled.

**Architecture:** Configure `ZSH_CACHE_DIR` and a version-specific `ZSH_COMPDUMP` before `oh-my-zsh.sh` is sourced. Add offline configuration assertions that verify both exports and their ordering, then validate the improvement with a writable temporary home. Leave WezTerm Lua, plugin selection, aliases, mise activation, and the user's existing `.zshrc` changes untouched.

**Tech Stack:** Zsh, Bash test harness, Oh My Zsh, WezTerm, Git.

## Global Constraints

- Preserve the user's existing `# opencode` PATH block in `.config/zsh/.zshrc`; it must remain unstaged if it is unrelated to this change.
- Do not disable `compaudit`/`compinit` security checks, lazy-load completion, remove plugins, delete existing compdump files, or modify `.config/wezterm/wezterm.lua`.
- Keep the change limited to the two cache exports, focused regression coverage, and this plan unless verification exposes a necessary correction.
- Do not encode a fragile wall-clock threshold in the repository tests; timing is evidence for the manual verification step only.

---

## Task 1: Add a failing regression test for completion-cache configuration (TDD RED)

**Files:** `tests/test_configuration.sh`

- [ ] Extend `test_shell_uses_mise_without_devbox_or_cargo_path` (or add a focused test next to it) to require these exact lines in `.config/zsh/.zshrc`:
  ```zsh
  export ZSH_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/oh-my-zsh"
  export ZSH_COMPDUMP="$ZSH_CACHE_DIR/.zcompdump-${ZSH_VERSION}"
  ```
- [ ] Assert that the cache exports occur before `source "$ZSH/oh-my-zsh.sh"` so they affect Oh My Zsh initialization. Use line-number comparison rather than a brittle whole-file snapshot.
- [ ] Assert that `ZSH_DISABLE_COMPFIX=true` is absent, preserving the existing security behavior.
- [ ] Run `bash tests/test_configuration.sh` and confirm it fails because the production exports are not present. Run `zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh` to ensure the test-only edit did not introduce syntax errors.

## Task 2: Configure the stable, user-writable cache (TDD GREEN)

**Files:** `.config/zsh/.zshrc`

- [ ] Add the two exact exports immediately after `export ZSH_CUSTOM=...` and before `ZSH_THEME`/the Oh My Zsh source block:
  ```zsh
  export ZSH_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/oh-my-zsh"
  export ZSH_COMPDUMP="$ZSH_CACHE_DIR/.zcompdump-${ZSH_VERSION}"
  ```
- [ ] Preserve every existing configuration line, including the user's `# opencode` PATH block.
- [ ] Re-run the focused configuration test and Zsh syntax checks; both must pass.
- [ ] Measure startup in a temporary writable home with the repository's Zsh configuration and a pre-created cache directory. Record that subsequent `zsh -ic exit` launches reuse the cache; do not turn the measurement into a hard timing assertion.

## Task 3: Verify, review, and commit only the requested change

- [ ] Review `git diff` and confirm the user's existing `.config/zsh/.zshrc` block is still present and is not staged with this feature.
- [ ] Run the repository gates:
  ```sh
  bash tests/run.sh
  bash -n install.sh tests/*.sh
  zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
  git diff --check
  ```
- [ ] Stage only the cache-export hunk from `.config/zsh/.zshrc` (for example with `git add -p`), leaving unrelated user edits unstaged; inspect both `git diff --cached` and `git diff` before committing.
- [ ] Commit the focused implementation as `perf: stabilize Zsh completion cache`.
- [ ] After committing, report the measured behavior and the fact that the user's unrelated `.zshrc` edit remains preserved and unstaged. Do not push until explicitly requested.
