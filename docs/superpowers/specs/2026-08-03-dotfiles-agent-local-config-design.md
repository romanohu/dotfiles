# Dotfiles agent workflow and private local configuration

## Status

Approved design. Implementation is intentionally separate from this document.

## Goals

1. Keep SSH hostnames and other machine-specific WezTerm settings out of the
   public repository while making new connections easy to add.
2. Make Herdr useful for multiple interchangeable coding agents. Agents are
   added on demand, one at a time, and are not assigned service-specific roles.
3. Manage safe, declarative Codex and Claude configuration without linking or
   committing authentication, sessions, history, or caches.
4. Improve daily shell and Git workflows without adding a second multiplexer or
   an opaque automation layer.
5. Validate the configuration in CI and in the existing isolated test suite.

## Non-goals

- Installing or authenticating Codex, Claude, Gemini, or any other agent.
- Running a real Herdr, Devbox, Nix, or agent session during this change.
- Tracking `$HOME/.codex` or `$HOME/.claude` as whole directories.
- Storing API keys, session identifiers, transcripts, project caches, or SSH
  private data in Git.
- Assigning fixed roles such as “Codex reviewer” or “Claude planner”.

## Architecture

### 1. WezTerm public/private split

The repository continues to track the portable configuration in
`.config/wezterm/wezterm.lua`. It also tracks a schema-only
`.config/wezterm/local.lua.example`.

The installer changes WezTerm management from a whole-directory link to a
managed file link:

- `$HOME/.config/wezterm/` is a real directory.
- `$HOME/.config/wezterm/wezterm.lua` links to the physical repository file.
- `$HOME/.config/wezterm/local.lua` remains a user-owned local file.

`wezterm.lua` loads `local.lua` with a protected optional import. A missing or
invalid local file must leave the portable configuration usable and must emit a
short diagnostic only when the user explicitly asks for configuration help.

The local table contains SSH entries and other machine-specific values. The
portable file generates the leader-key bindings from that table, so adding an
SSH destination requires editing only `local.lua`. No real hostnames or
personal paths are placed in the repository. Existing managed whole-directory
links are migrated through the installer backup mechanism; an existing local
file is preserved.

### 2. Herdr workspace and `ha`

The public command is `ha` (Herdr Agent). It is installed into the existing
`$HOME/.local/bin` path and is also available from the shell configuration.

Behavior:

- `ha` adds exactly one agent pane to the current Herdr workspace.
- `ha codex` and `ha claude` select a command explicitly.
- With no command argument, `ha` selects from a user-owned allowlist, using
  `fzf` when available and a deterministic fallback otherwise.
- If no workspace is active, `ha` creates or attaches to one for the current
  project directory before adding the pane.
- Pane labels are generic (`agent-1`, `agent-2`, and so on). Herdr remains
  responsible for detecting the actual agent and displaying its state.
- `ha --dry-run` validates the selected command and prints the planned Herdr
  operations without creating a workspace or pane.
- The command must validate that the selected executable exists before making
  any Herdr mutation. It never installs an agent or modifies credentials.

The user-owned command list lives outside the repository under
`$XDG_CONFIG_HOME/dotfiles/agents.local` (falling back to
`$HOME/.config/dotfiles/agents.local`). The repository provides a safe example
format only. This keeps the command names and local wrappers adjustable without
putting machine-specific policy into the public Herdr config.

The managed Herdr config keeps `terminal.default_shell = "zsh"`, opts into
following the focused project directory for new panes, and adds one custom
prefix command for `ha`. Agent integration installation remains manual and
optional; the installer never edits Codex or Claude state to enable it.

### 3. Codex and Claude configuration boundaries

The repository mirrors only explicitly approved files under `.codex/` and
`.claude/`. The installer creates the target directories as real directories
and links or copies an allowlisted set of files individually.

The initial allowlist consists of:

- shared instruction files (`AGENTS.md` and `CLAUDE.md`),
- declarative settings whose schema is reviewed before adding them, and
- standalone hook scripts that do not contain secrets or machine-specific
  paths.

The installer must leave unrelated files in both target directories untouched.
The following are always excluded from tracking and linking: auth files,
session stores, transcripts, history, caches, project indexes, generated
extensions, and files containing API endpoints or tokens unless the user has
explicitly marked a value as public.

### 4. Daily workflow improvements

- Add `zoxide` as a pinned Devbox package and initialize it only when the
  command exists.
- Add small `fzf`-backed Git helpers for branch selection and history lookup;
  keep them as shell functions with safe quoting and no destructive defaults.
- Extend the Git config with conservative defaults such as fetch pruning,
  rerere, and automatic upstream setup. Existing user identity and repository
  policy remain authoritative.

These helpers must degrade to ordinary Git and `cd` behavior when their optional
commands are unavailable.

### 5. Reproducibility and safety checks

Add a CI workflow that runs the existing host-independent test suite, shell
syntax checks, JSON/TOML parsing, and `git diff --check`. Extend configuration
tests to verify:

- no forbidden Codex/Claude state files are tracked,
- no WezTerm hostnames are present in portable configuration,
- the local-file fallback is optional,
- `ha --dry-run` performs no mutation, and
- the installer preserves user-owned local files during migration.

CI and local tests use fake Herdr/agent commands where needed. They do not
install runtime dependencies or contact agent services.

## Error handling

- Missing `local.lua`: start WezTerm with portable defaults and document how to
  create the local file.
- Missing `agents.local`: print the example path and supported invocation forms;
  do not guess a command.
- Missing selected agent executable: fail before creating a pane and show the
  command that was not found.
- Existing WezTerm directory symlink: back it up only when it is the exact
  previously managed link; refuse ambiguous or unrelated symlinks.
- Existing Codex/Claude state: preserve it and link only the allowlisted files.

## Verification plan

1. Run the existing `bash tests/run.sh` suite and its shell/JSON/TOML checks.
2. Add isolated installer fixtures for WezTerm directory migration and
   Codex/Claude state preservation.
3. Test `ha --dry-run` with fake Herdr and agent executables, including missing
   command, empty local config, and repeated invocation cases.
4. Run CI-equivalent checks locally without invoking `devbox install`, Herdr,
   Nix, or any real agent.

## Rollout and recovery

The installer keeps its existing per-run backup behavior. If the WezTerm
migration or per-file Codex/Claude links are not wanted, restore the corresponding
backup paths and remove only the managed links. No runtime state or agent
session is deleted by the change.
