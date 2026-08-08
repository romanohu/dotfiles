# dotfiles

Personal dotfiles for reproducible machine setup with Nix + devbox.

## Prerequisites

The first-run CLI prerequisites are bash, curl, and git. SHA-256 verification
additionally requires sha256sum or shasum. Graphical terminal configuration
requires WezTerm. JetBrains Mono is the preferred font; Menlo and the system
monospace font are configured as fallbacks, so installing JetBrains Mono is
optional.

## What `install.sh` does

`./install.sh` is designed to finish setup in one run.

1. Installs `nix` if missing (skips if already installed)
2. Installs `devbox` if missing (skips if already installed)
3. Links the managed shell and application dotfiles into `$HOME` safely (backs up existing files)
4. Links devbox global config and runs `devbox global install`
5. Installs Oh My Zsh and plugins if missing (skips if already installed)
6. Installs the pinned global command-line tools for the current platform

The script is idempotent: you can run it multiple times. Before replacing a
managed path, it moves the previous content under
`$HOME/.dotfiles-backup/<run-id>/`. It never deletes editor state, including
Neovim state, data, and cache directories.

## Platform support

- macOS and Linux are supported. Devbox selects the matching pinned packages
  for Apple silicon, x86_64 Linux, or aarch64 Linux.
- Windows is supported for CLI setup through WSL. Windows-hosted WezTerm configuration is not installed from WSL.
- Native Windows shells are not supported for automatic Nix installation.

## Quick start

```sh
git clone https://github.com/romanohu/dotfiles.git
cd dotfiles
chmod +x install.sh
./install.sh
```

If this is the first Nix/devbox installation, restart your shell once after setup.

## Herdr

Start or reattach the managed Herdr session from a project directory:

```sh
herdr
```

Press `Ctrl+B`, then `q` to detach while keeping the session running. Run
`herdr` again to reattach. Create a project workspace explicitly when needed:

```sh
herdr workspace create --cwd /path/to/project --label project
```

New panes follow the active directory. Press `Ctrl+A`, then `Shift+N` in WezTerm to open Herdr in a new tab.
Press `Ctrl+B`, then `Shift+N` in Herdr to create a workspace.
Press `Ctrl+B`, then `W` in Herdr to switch or list workspaces.
Press `Ctrl+B`, then `a` in Herdr to run `ha`.

To add one generic agent pane to the current project workspace, use `ha` and
select a locally configured command. Pass one explicitly when useful:

```sh
ha
ha codex
ha claude
```

The allowlist is local-only at `$XDG_CONFIG_HOME/dotfiles/agents.local` (or
`$HOME/.config/dotfiles/agents.local`): use one command name per line. It is
not tracked or installed by this repository.

Agent integrations are manual and optional. This repository does not install
them or manage agent credentials.

## Daily shell and Git helpers

The pinned `zoxide` package enables `z` in Zsh when it is available. The
`gcof` helper interactively selects a local branch with `fzf` and switches to
it; `glogf` selects a commit and shows it. Both return without changing state
when `fzf` is unavailable, the shell is non-interactive, or no item is chosen.

## Agent guidance boundaries

The installer manages only the public instruction files in `$HOME/.codex` and
`$HOME/.claude`, one file at a time. Existing runtime state and unrelated
settings remain user-owned. Add a setting or hook only after its exact public
schema and content have been reviewed.

## Continuous validation

GitHub Actions runs the same host-independent checks as `bash tests/run.sh`:
shell syntax, JSON parsing, and whitespace validation. It does not install or
run Devbox, Nix, Herdr, or agent commands, and it does not require secrets.
Run the same command locally before submitting changes.

## Local WezTerm settings

The tracked WezTerm configuration contains only portable settings. To add SSH
tab bindings for this machine, copy the example and replace its placeholder
host with entries from your local SSH configuration:

```sh
cp /path/to/dotfiles/.config/wezterm/local.lua.example ~/.config/wezterm/local.lua
```

`local.lua` is ignored by Git. Each `ssh_hosts` entry needs a `key`, `domain`,
and `label`; the installer uses the domain only to create the WezTerm SSH tab
binding. Keep real hostnames in this local file.

Existing installations that used the old managed WezTerm directory symlink are
migrated to a real `$HOME/.config/wezterm` directory. The old symlink is backed
up under `$HOME/.dotfiles-backup/<run-id>/.config/wezterm`.

## Tests

Run the complete repository suite through the pinned environment:

```sh
devbox run --config .config/devbox/global test
```

The test entrypoint resolves the physical repository path, so the same command
also works when Devbox uses the global configuration symlink.

To verify that the suite does not depend on host tools, run it in Devbox's pure
environment:

```sh
devbox run --pure --config .config/devbox/global test
```

## Updating pinned dependencies

Edit the package's exact version in `.config/devbox/global/devbox.json`, then
regenerate `.config/devbox/global/devbox.lock` and run the tests:

```sh
devbox install --config .config/devbox/global
devbox run --config .config/devbox/global test
```

Herdr is pinned as the release-tagged flake
`github:ogulcancelik/herdr/v0.7.5`. Its Devbox lock entry is a
platform-independent revision, so it can be updated once from any supported
platform (`aarch64-darwin`, `x86_64-linux`, or `aarch64-linux`). Change the tag
in `devbox.json`, then replace `vX.Y.Z` below with that same exact tag:

```sh
devbox update 'github:ogulcancelik/herdr/vX.Y.Z' --no-install --config .config/devbox/global
```

Rerun the tests after the lock update. Do not run `herdr update` for this
Nix/Devbox-managed installation.

When updating the Linux-only `nvtopPackages.full` pin from another platform,
resolve its Linux lock entry without installing it:

```sh
NIX_CONFIG='system = x86_64-linux' devbox update nvtopPackages.full --no-install --config .config/devbox/global
```

The installer also has exact bootstrap and source pins in `install.sh`. Update
each related group atomically:

- For Determinate Nix, change `NIX_INSTALLER_URL` to the official version-tag
  URL and `NIX_INSTALLER_SHA256` to the digest of that exact script. Fetch the
  official script again and verify the digest before committing:

  ```sh
  curl -fL --proto '=https' --tlsv1.2 \
    https://install.determinate.systems/nix/tag/<version>/nix-installer.sh \
    -o /tmp/nix-installer.sh
  sha256sum /tmp/nix-installer.sh
  # macOS alternative:
  shasum -a 256 /tmp/nix-installer.sh
  ```

  Confirm that the printed digest is exactly `NIX_INSTALLER_SHA256`.
- For Devbox, update `DEVBOX_VERSION` and `DEVBOX_FLAKE` to the same release.
  Update the schema version in `.config/devbox/global/devbox.json` at the same
  time.
- For the shell sources, update `OH_MY_ZSH_COMMIT`,
  `ZSH_AUTOSUGGESTIONS_COMMIT`, and `ZSH_SYNTAX_HIGHLIGHTING_COMMIT` to reviewed
  full commit SHAs from their upstream repositories.

Run every test path after changing any pin:

```sh
bash tests/run.sh
devbox run --config .config/devbox/global test
devbox run --pure --config .config/devbox/global test
```

Commit `install.sh`, the manifest, and the regenerated lockfile together when
their pins change.

## History rewrite notice

After a published `main` history rewrite, existing clones must re-clone or
explicitly reset to the rewritten `main`. Old objects may remain in forks, mirrors, pull request refs, and hosting-provider caches outside this repository's control.

## Repository layout

```text
.
├── .config
│   ├── devbox
│   │   └── global
│   │       ├── devbox.json
│   │       ├── devbox.lock
│   │       └── run-tests.sh
│   ├── git
│   ├── herdr
│   ├── wezterm
│   └── zsh
├── .zshenv
├── install.sh
└── README.md
```
