# Dotfiles Hardening, Cleanup, and Herdr Integration Design

**Date:** 2026-07-23

**Status:** Approved for implementation

## Purpose

Make the dotfiles installer safe and repeatable, remove unused Neovim and Pet configuration, purge historical shell runtime data from the public Git repository, and install a pinned Herdr release with a minimal tracked configuration.

## Goals

- Prevent the installer from deleting editor state, shell state, or unrelated user configuration.
- Back up replaced paths without overwriting earlier backups.
- Pin bootstrap inputs and managed packages closely enough for repeatable machine setup.
- Replace the placeholder test command with an automated, offline-safe test suite.
- Remove missing-command failures from the WezTerm monitoring layout.
- Remove Neovim and Pet from the current configuration.
- Install Herdr through the existing Devbox global environment.
- Remove committed Zsh history, sessions, and completion dumps from all published Git refs.
- Keep macOS, Linux, and WSL setup behavior explicit and documented.

## Non-goals

- Migrating the repository to Home Manager, GNU Stow, or another dotfiles framework.
- Purging historical Neovim files, which were not identified as sensitive.
- Managing a complete Herdr configuration or suppressing its first-run onboarding.
- Automatically installing graphical applications or fonts on every platform.
- Supporting automatic installation in native Windows shells.

## Constraints

- Existing user files must not be overwritten or deleted without a recoverable backup.
- Tests must not modify the real home directory, Nix profile, Devbox environment, or remote Git repository.
- The pre-existing `lazy-lock.json` modification may be discarded because the entire Neovim configuration is being removed at the user's request.
- The Git history rewrite must be verified in a temporary mirror before any force-push.
- Herdr stable releases support Linux and macOS. WSL uses the Linux build; native Windows remains outside the automatic setup scope.

## Chosen Approach

Keep the existing Bash installer and Devbox global environment, but separate target paths, external bootstrap operations, linking, and migration behavior into testable functions. Use pinned versions and a committed Devbox lockfile. Add a pure-Bash test harness that exercises the installer against an isolated target directory with stubbed external commands.

This approach preserves the current repository structure while correcting the identified safety and reproducibility problems. A Home Manager migration would provide stronger declarative guarantees but would be a substantially larger and unrelated change.

## Installer Architecture

### Target isolation

Introduce `DOTFILES_TARGET_HOME`, defaulting to the real `HOME`. Every managed destination, backup path, Devbox global path, and migration target is derived from this value. Tests set only `DOTFILES_TARGET_HOME`; they never replace or repurpose `HOME`.

Guard the `main` call so the installer can be sourced by tests without performing setup.

### Linking and backups

Continue using absolute symlinks for tracked configuration. Before replacing a file, directory, or symbolic link, move that exact path into a unique backup directory below `<target-home>/.dotfiles-backup/`.

An already-correct symlink is a no-op. Re-running the installer must not create a backup for a correct managed link. Backup directory creation must fail rather than reuse and overwrite an existing run directory.

### Zsh migration

If `<target-home>/.config/zsh` is a symbolic link, back up the link before creating a real directory. Never delete or mutate the link target. If the link points to the repository's former all-in-one Zsh directory, copy recognized runtime state such as history, sessions, and completion dumps into the new directory without removing it from the old target. Unrelated contents remain recoverable through the backup or original target.

Tracked Zsh files are linked individually into the real directory so history, sessions, completion dumps, logs, and third-party checkouts remain outside the repository.

### Neovim removal

Delete the tracked `.config/nvim/` tree and `nvim.log`. Remove Neovim and its dedicated Tree-sitter package from Devbox, remove Neovim from the installer link list, and remove all Neovim migration cleanup code.

The installer may remove `<target-home>/.config/nvim` only when it is a symbolic link whose resolved target is the removed repository path. It must not remove a regular file, directory, or link to any other target.

### Pet removal

Delete `.config/zsh/pet.zsh`, remove its Zsh source statement, remove it from the installer link list and `.gitignore` exceptions, and remove the `pet` Devbox package. Tests ensure no active tracked configuration references Pet.

### npm configuration

Remove the installer step that runs `npm config set prefix` and remove the corresponding `.npm-global/bin` PATH entry. The dotfiles installer will not create or rewrite `.npmrc`; npm package management remains under the user's selected Node.js tooling.

## Bootstrap and Dependency Integrity

### Nix

Use Determinate Nix Installer `v3.21.2` from `https://install.determinate.systems/nix/tag/v3.21.2/nix-installer.sh`. Download it to a private temporary directory, verify SHA-256 `4141f93485a16d600b995d02b2bdd296fb69af30ea3665037677b8d56f703b56`, and execute it only after successful verification. A hash mismatch or unavailable hash tool is a hard failure. Temporary files are removed through a trap.

### Devbox

Install Devbox `0.17.3` through `github:jetify-com/devbox/0.17.3` after Nix is available, rather than piping the floating Devbox installer into Bash. If an existing Devbox binary reports another version, warn and preserve it; do not silently replace an unrelated manually managed binary. New installations use the pinned flake release.

### Oh My Zsh and plugins

Fetch third-party Zsh code from these fixed commits:

- Oh My Zsh: `677a4592b18c08ddea737f8aca70bac0e9fc9313`
- `zsh-autosuggestions`: `85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5`
- `zsh-syntax-highlighting`: `1d85c692615a25fe2293bdd44b34c217d5d2bf04`

A new checkout is detached at the configured commit. If an existing checkout is at another commit, warn and leave it untouched rather than destroying possible local changes.

### Devbox packages

Commit `devbox.lock` and remove all `latest` selectors. Preserve the existing exact package versions, change Node.js from `nodejs@24` to the currently locked `nodejs@24.12.0`, and remove Neovim, Tree-sitter, and Pet. Add `nvtopPackages.apple@3.3.2` on Apple silicon and `nvtopPackages.full@3.3.2` on supported Linux platforms. If a monitoring command is unavailable on another platform, the pane prints a clear message instead of failing silently.

Graphical WezTerm installation and the preferred font are documented platform prerequisites. WSL documentation explains that the Windows-hosted terminal configuration is not installed automatically from inside WSL.

## Herdr Integration

Add the fixed GitHub flake reference `github:ogulcancelik/herdr/v0.7.5` to the Devbox package list and record its resolved input in `devbox.lock`.

Add `.config/herdr/config.toml` with only:

```toml
[terminal]
default_shell = "zsh"
```

Link the complete `.config/herdr` directory to `<target-home>/.config/herdr`. Leave `onboarding` unset so Herdr retains its supported first-run flow. Verify installation with `herdr --version` inside the Devbox environment without launching an interactive Herdr session.

## Test Design

Create a pure-Bash test runner under `tests/`. Each test creates its own temporary target directory and command-stub directory. No test contacts the network or writes to the real home directory.

Required cases:

1. An existing Zsh symlink is backed up, its target and contents remain unchanged, and recognized runtime state is copied into the new directory.
2. A correct managed link is idempotent and creates no backup on a second run.
3. A hash mismatch prevents execution of the downloaded installer.
4. A valid hash allows the verified script to run through a controlled test double.
5. A managed legacy Neovim link is removed, while an unrelated Neovim path is preserved.
6. No current installer or configuration references Neovim or Pet after their removal.
7. The Herdr directory is linked and its minimal TOML configuration is present.
8. Devbox JSON parses, has no `latest` selector, includes pinned Herdr and `nvtop`, and invokes the real test runner.
9. Shell and Lua configuration syntax checks pass where their interpreters are available.

The Devbox `test` script calls the same repository test runner through `DEVBOX_PROJECT_ROOT`. From the repository root, the exact command is `devbox run --config .config/devbox/global test`. Tests are written and observed failing before each corresponding production change.

## Git History Rewrite

The published repository currently contains historical `.zsh_history`, `.zsh_sessions/**`, and `.zcompdump*` objects. Rewrite all affected local branches and tags in a temporary mirror clone using `git-filter-repo` or an equivalently auditable path filter.

Before force-pushing, verify:

- No reachable object path matches the sensitive Zsh runtime paths.
- A high-confidence credential-pattern scan reports no findings.
- The rewritten tip tree matches the intended current tree.
- Only the expected branch and tag object IDs changed.
- The destination remote is exactly the configured `romanohu/dotfiles` repository.

Perform the history rewrite only after the hardening, Pet removal, Herdr integration, lockfile update, and final tests are committed. Force-push only the explicitly verified branch and tag refs so the rewritten remote tip contains the complete intended result rather than an intermediate tree. Then fetch the rewritten refs into the working repository and move the local branch to the rewritten tip without discarding uncommitted user work. Document that existing clones must re-clone or reset to the rewritten history and that unreachable copies may remain in third-party forks or caches.

## Error Handling

- Missing required commands produce an actionable error before mutation begins.
- External downloads fail closed on transport or checksum errors.
- Existing configuration is backed up before replacement.
- Existing third-party Git checkouts with unexpected commits are preserved and reported.
- Cleanup targets are explicit paths derived from `DOTFILES_TARGET_HOME`; no broad or unresolved recursive target is allowed.
- The history force-push is the final repository publication action and occurs only after all feature work and mirror verification.

## Implementation Order

1. Add the test harness and observe the safety and reproducibility tests fail.
2. Harden the installer, remove Neovim, pin bootstrap dependencies, commit the initial Devbox lockfile, and make the tests pass.
3. Add failing Pet-removal checks, remove Pet, and make them pass.
4. Add failing Herdr integration checks, add the pinned package and minimal configuration, and make them pass.
5. Regenerate the final Devbox lockfile and run the full offline test suite, Devbox test command, syntax checks, package checks, and final secret/path scans.
6. Rewrite and verify Git history, then force-push the complete sanitized result.

## Success Criteria

- The installer cannot delete existing Neovim state or an unrelated Zsh target.
- Re-running link setup is idempotent.
- All external bootstrap inputs are fixed and verified or resolved by the committed lockfile.
- `devbox run --config .config/devbox/global test` succeeds.
- Neovim and Pet have no active tracked configuration or managed package.
- `herdr --version` succeeds through the Devbox global environment.
- Historical Zsh runtime files are unreachable from the published repository's branches and tags.
- The working tree contains no unintended changes after verification.

## References

- [Herdr installation](https://herdr.dev/docs/install/)
- [Herdr configuration](https://herdr.dev/docs/configuration/)
- [Devbox configuration and flake packages](https://www.jetify.com/docs/devbox/configuration/)
- [Devbox global environments](https://www.jetify.com/docs/devbox/devbox-global/)
- [Determinate Nix Installer](https://github.com/DeterminateSystems/nix-installer)
