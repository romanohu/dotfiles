# Migrate dotfiles bootstrap from Nix and Devbox to mise

## Status

Approved design. Implementation is intentionally separate from this document.

## Context

This repository currently uses Nix and Devbox as the only supported package
path. That works on machines the user controls, but it cannot bootstrap an
ABCI account or another managed host where `/nix`, root access, or administrator
policy is outside the user's control. The repository also contains an unused
Herdr agent launcher (`ha`) and a split Rust installation that does not provide
the expected components consistently.

The replacement uses mise for user-scoped tool installation, pinned Git
checkouts, dotfile linking, and the normal test entry point. It follows the
single-config bootstrap pattern described in
[mise bootstrapのすすめ](https://zenn.dev/takuty/articles/770b88416b5e6c),
while retaining a small verified installer for hosts where mise is not yet
available.

## Goals

1. Bootstrap the supported command-line environment without root privileges on
   macOS and Linux, including ABCI after Zsh is available.
2. Replace Nix and Devbox in the repository with one root `mise.toml` and a
   tracked multi-platform `mise.lock`.
3. Keep every managed tool at an exact version and use strict lockfile installs
   wherever the selected mise backend supports artifact locking.
4. Manage Rust through mise at one exact toolchain version with Clippy,
   rustfmt, and rust-analyzer.
5. Remove the unused `ha` integration while retaining Herdr itself.
6. Preserve the existing offline, host-independent test suite and safe failure
   behavior for conflicting user files.

## Non-goals

- Supporting native Windows.
- Installing Git or Zsh. They are bootstrap prerequisites.
- Installing or managing `htop`.
- Retaining `hwloc`, `tree`, `xclip`, `nvtop`, or `navi` in the repository.
- Uninstalling any existing Nix, Devbox, `htop`, or other system installation.
- Automatically editing the repository-external `~/.profile`.
- Providing full offline installation. The lockfile avoids runtime release
  discovery where supported, but first installation still downloads artifacts.
- Automatically backing up or overwriting unmanaged dotfiles.

## Decisions considered

Three migration shapes were considered:

1. Keep Nix as the primary backend and add mise as a fallback.
2. Keep separate Devbox and mise manifests and test them for parity.
3. Make mise the only repository-managed package and bootstrap path.

The third option is selected. It removes duplicated manifests and the
privilege-dependent path instead of preserving two implementations that can
drift. The root `mise.toml` is both the repository bootstrap configuration and
the source for the global mise configuration.

## Architecture

### 1. Verified mise entry point

`install.sh` remains as a small first-run bootstrapper because `mise.toml`
cannot execute before mise exists. It has these responsibilities only:

1. Resolve the physical repository path and target home.
2. Accept macOS and Linux and verify that Bash, curl, Git, tar, Zsh, and either
   `sha256sum` or `shasum` are available.
3. Download the immutable mise installer to a private temporary path.
4. Verify its SHA-256 before executing it.
5. Install mise at `$TARGET_HOME/.local/bin/mise` without modifying shell files.
6. Remove only obsolete symlinks proven to have been created by this
   repository.
7. Trust the repository `mise.toml` and run the strict bootstrap with the
   pinned mise binary.

The bootstrap pin is:

- mise version: `2026.8.9`
- installer URL:
  `https://github.com/jdx/mise/releases/download/v2026.8.9/install.sh`
- installer SHA-256:
  `0947cf3dd1eb5d734676a554b4bb8298f8557ffc706f5ed5637e9e68e1218403`

The script downloads to a regular file, verifies it, and then invokes Bash. It
never uses `curl | sh`. It calls the exact installed binary rather than another
`mise` found on `PATH`, validates the installed version, and supplies the
repository file as `MISE_GLOBAL_CONFIG_FILE` during the bootstrap so an
unrelated pre-existing global configuration cannot affect the run.

`DOTFILES_TARGET_HOME` remains available for isolated tests. All mise
subprocesses used by the installer are rooted in that target home. Normal use
leaves it unset and therefore targets `$HOME`.

### 2. Single mise configuration

The repository root gains `mise.toml` with:

- `min_version = "2026.8.9"`;
- lockfile and strict locked mode enabled;
- lockfile platforms `macos-arm64`, `linux-x64`, and `linux-arm64`;
- exact `[tools]` entries;
- exact `[bootstrap.repos]` Git refs;
- explicit `[dotfiles]` mappings; and
- a `test` task that runs `bash tests/run.sh`.

The same physical file is linked to `~/.config/mise/config.toml`. The tracked
root `mise.lock` is linked to `~/.config/mise/mise.lock`, which is mise's global
lockfile location. mise canonicalizes the self-linked configuration so running
inside the repository does not load a duplicate copy.

The tracked lockfile contains entries for the three supported platforms. A
backend-provided checksum is retained whenever available. Strict mode requires
pre-resolved platform URLs for ordinary downloadable tools, avoiding release
API discovery during installation.

### 3. Managed tools

The exact tool set is:

| Tool | Version | Backend choice |
| --- | --- | --- |
| starship | `1.24.2` | mise registry |
| fzf | `0.71.0` | mise registry |
| ripgrep | `15.1.0` | mise registry |
| bat | `0.26.1` | mise registry |
| fd | `10.4.2` | mise registry |
| gh | `2.89.0` | mise registry |
| uv | `0.11.6` | mise registry |
| tmux | `3.6a` | mise registry |
| pueue | `4.0.4` | `github:Nukesor/pueue` |
| git-lfs | `3.7.1` | mise registry |
| dua | `2.34.0` | `cargo:dua-cli`, depends on `rust` |
| viddy | `1.3.0` | mise registry |
| jq | `1.7.1` | mise registry |
| node | `24.12.0` | mise core |
| zoxide | `0.9.8` | mise registry |
| herdr | `0.7.5` | mise registry (`aqua:herdrdev/herdr`) |
| rust | `1.97.1` | mise core Rust backend |

The Rust entry uses the minimal profile and requests `clippy`, `rustfmt`, and
`rust-analyzer`. Cargo and rustc come from that toolchain and are not separate
tool entries. `dua` is built through Cargo after the configured Rust tool is
available, so it has no per-platform release artifact entries in the lockfile.

The mise Rust backend uses rustup internally. The exact toolchain and component
set are recorded, but the Rust distribution URLs and checksums are not emitted
as platform entries in `mise.lock`. This is an accepted limitation of choosing
the single mise path and must be documented in the README.

`htop` becomes unmanaged. `hwloc`, `tree`, `xclip`, `nvtop`, and `navi` are
removed from the repository. Nothing attempts to uninstall copies that already
exist on a host.

### 4. Pinned Zsh repositories

`[bootstrap.repos]` replaces the custom Git checkout implementation in
`install.sh`. It manages these exact commits:

| Repository | Destination | Commit |
| --- | --- | --- |
| Oh My Zsh | `~/.config/zsh/oh-my-zsh` | `677a4592b18c08ddea737f8aca70bac0e9fc9313` |
| zsh-autosuggestions | `~/.config/zsh/custom/plugins/zsh-autosuggestions` | `85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5` |
| zsh-syntax-highlighting | `~/.config/zsh/custom/plugins/zsh-syntax-highlighting` | `1d85c692615a25fe2293bdd44b34c217d5d2bf04` |

The plugins are siblings of the Oh My Zsh checkout rather than nested Git
repositories inside it. `.zshrc` sets
`ZSH_CUSTOM="$HOME/.config/zsh/custom"`, matching Oh My Zsh's expected
`$ZSH_CUSTOM/plugins/<plugin>` layout.

mise's repository bootstrap may clone a missing destination or move a clean,
matching checkout to its configured ref. It must fail on dirty repositories,
different origins, and non-Git conflicts; it must never force-reset user work.

### 5. Dotfile mappings

`[dotfiles]` uses symlink mode and manages only the following targets:

- `~/.config/mise/config.toml` from the root `mise.toml`;
- `~/.config/mise/mise.lock` from the root `mise.lock`;
- `~/.zshenv`;
- `~/.config/git` as a directory;
- `~/.config/herdr` as a directory;
- `~/.config/zsh/.zshrc` and `~/.config/zsh/aliases.zsh` as individual files;
- `~/.config/wezterm/wezterm.lua` as an individual file;
- `~/.codex/AGENTS.md` and `~/.claude/CLAUDE.md` as individual files.

The file-level Zsh, WezTerm, Codex, and Claude mappings preserve runtime and
machine-local files beside the managed files. The configuration does not use
`[bootstrap.mise_shell_activate]` because `.zshrc` is already declaratively
managed.

If an unmanaged target already exists, bootstrap fails and identifies the
conflict. Neither `install.sh` nor documented commands pass
`--force-dotfiles`. The user moves or backs up the target explicitly and then
reruns the installer.

### 6. Shell activation

`.zshenv` establishes `ZDOTDIR`, retains the configured time zone, and places
both `$HOME/.local/bin` and `$HOME/.local/share/mise/shims` on `PATH`. Duplicate
`$HOME/.local/bin` entries are removed.

`.zshrc` removes the Devbox shell environment and the obsolete Devbox alias.
Its ordering is:

1. configure and source Oh My Zsh;
2. apply any existing Homebrew shell environment;
3. activate mise;
4. initialize mise-managed Starship and zoxide; and
5. load the existing aliases and history settings.

Running Homebrew setup before mise activation ensures mise shims remain ahead
of system or Homebrew copies. No `$HOME/.cargo/bin` entry is added: mise shims
select the configured Rust toolchain. The installer also does not ask rustup to
modify shell files.

### 7. Remove Nix, Devbox, and `ha`

The repository removes:

- `.config/devbox/` in full;
- all Nix and Devbox constants, installation code, setup code, aliases,
  documentation, tests, and CI arguments;
- Nix and Devbox entries from the managed global Git ignore;
- `bin/ha`;
- `.config/dotfiles/agents.local.example` and its local-state ignore entries;
- the Herdr `[[keys.command]]` block that invokes `ha`;
- the WezTerm command shortcut introduced with the Herdr/agent workflow;
- `tests/test_agent.sh` and its test-runner and CI references; and
- README instructions for `ha` and `agents.local`.

Herdr itself remains managed at version `0.7.5`. Its `onboarding`, `terminal`,
and `ui` settings remain in `.config/herdr/config.toml`.

### 8. Narrow legacy cleanup

The installer retains a small migration step for obsolete links. It removes a
link only when all of the following are true:

1. the target is a symbolic link;
2. `readlink` equals one of the known paths formerly created by this
   repository; and
3. the resolved target is scoped to the selected target home and repository.

The candidates are the old `ha`, Devbox config, Devbox global, Neovim, and Pet
links. Regular files, directories, unrelated symlinks, Nix stores, Devbox data,
and installed executables are never removed. Cleanup is idempotent.

## Execution flow

A normal first run is:

1. Clone the repository.
2. Run `./install.sh` from an interactive macOS or Linux shell.
3. The script installs and validates pinned mise.
4. The script cleans up exact obsolete repository-owned links.
5. The script trusts the physical root `mise.toml`.
6. The script invokes the equivalent of
   `mise -C "$DOT_DIR" --locked bootstrap --yes` with the root file selected as
   the global configuration for that process.
7. mise converges pinned repositories, dotfile links, and tools.
8. A new Zsh session loads the linked global configuration and mise shims.

The declarative steps are rerunnable. Successful work from a partial run is
kept; after correcting the reported problem, rerunning converges the remaining
state instead of rolling everything back.

## Error handling and safety

- Unsupported operating system: fail before downloading or linking anything.
- Missing prerequisite: identify the missing command and fail before mutation.
- Installer checksum mismatch: delete the temporary installer and fail.
- Installed mise version mismatch: fail without falling back to another binary
  on `PATH`.
- Dirty or conflicting pinned repository: preserve it and fail.
- Existing unmanaged dotfile: preserve it and fail.
- Missing locked artifact URL for an ordinary downloadable tool on the active
  platform: fail rather than query a release API or select a different asset.
  The mise core Rust backend is the documented exception because it delegates
  distribution resolution to rustup.
- Interrupted bootstrap: preserve completed declarative state and allow a safe
  rerun.

The external `~/.profile` is not changed automatically. The README explains
how to remove a stale line that sources a nonexistent rustup environment, after
the user has reviewed or backed up that file.

## Update workflow

For a managed tool update:

1. Change its exact version in `mise.toml`.
2. Regenerate `mise.lock` for `macos-arm64`, `linux-x64`, and `linux-arm64`.
3. Review changed URLs and checksums.
4. Run `mise install --locked` and the verification suite.
5. Commit `mise.toml` and `mise.lock` together.

For a mise bootstrap update, change the version, immutable installer URL,
installer SHA-256, and `min_version` together. For a Zsh repository update,
change the full commit ref and run the same tests. No update workflow uses
`latest` or a moving branch.

## Documentation

The README is rewritten around the mise-only workflow. It documents:

- Git, Zsh, Bash, curl, tar, and a SHA-256 utility as prerequisites;
- user-scoped installation and the absence of root requirements;
- macOS and Linux support, with ABCI usage after Zsh is available;
- the exact tool list and deliberately unmanaged or removed tools;
- first installation, rerun, conflict recovery, and update commands;
- Herdr use without `ha`;
- the Rust/rustup lockfile limitation and manual stale `~/.profile` cleanup;
  and
- that removing repository management does not uninstall system software.

## Test design

### Offline and host-independent suite

`bash tests/run.sh` remains independent of mise, Nix, Devbox, network access,
and the host's installed tool versions. Tests use Bash, standard Unix text
tools, and the existing helper patterns.

Configuration tests verify:

- the exact mise installer pin;
- the exact 17-tool set and version values;
- the explicit Rust profile and components;
- the three lockfile platforms and required platform URLs/checksums, with
  explicit backend-specific exceptions;
- exact Git repository commits and destinations;
- explicit dotfile mappings and absence of forced overwrite settings;
- mise-only Zsh activation and PATH setup;
- absence of Nix, Devbox, `ha`, `agents.local`, and every removed package; and
- the retained minimal Herdr configuration.

Installer tests source `install.sh` in a subprocess and replace external
operations with fakes. They verify:

- preflight failure before mutation;
- exact installer URL, SHA-256, and destination;
- checksum and installed-version failure;
- use of the exact mise binary for trust and strict bootstrap;
- isolation to `DOTFILES_TARGET_HOME`;
- removal of exact legacy links; and
- preservation of regular files and unrelated links.

The obsolete `ha` test file is deleted. Devbox manifest and lock tests are
replaced rather than retained. Existing assertions that became stale after the
current agent-guidance and Herdr configuration changes are aligned with the
tracked public files so the suite can reach the new tests.

### Static CI checks

The existing GitHub Actions validation remains host-independent and does not
install the managed tools. It runs:

- `bash tests/run.sh`;
- `bash -n` for the installer and test scripts;
- `zsh -n` for managed Zsh files; and
- `git diff --check`.

Devbox JSON/lock parsing and deleted `ha` arguments are removed from the
workflow.

### mise integration checks

Where pinned mise is available, run:

```sh
mise config ls
mise install --locked --dry-run
mise bootstrap --dry-run
mise run test
```

Before rollout, run `install.sh` twice with an isolated target home. The second
run must complete without creating backups or changing correct links. A fixture
with an unmanaged conflicting target must fail without changing that target.

## Acceptance criteria

1. The repository has no active Nix, Devbox, `ha`, or removed-package path.
2. `./install.sh` can start from a macOS or Linux user account with Git and Zsh
   but without mise or root privileges.
3. All 17 managed tools resolve to the exact declared versions on the three
   supported platforms; Rust exposes Cargo, rustc, Clippy, rustfmt, and
   rust-analyzer from toolchain `1.97.1`.
4. Correct existing state is skipped on a second run.
5. Unmanaged conflicts and dirty repositories are preserved and cause a clear
   failure.
6. Herdr remains installed and configured, while no `ha` command or binding
   remains.
7. `bash tests/run.sh`, static CI-equivalent checks, and the mise integration
   checks pass.
