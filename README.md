# dotfiles

Personal dotfiles for reproducible macOS and Linux setup with mise.

## Requirements

Git and Zsh are preinstalled prerequisites. Bootstrap also requires Bash,
curl, tar, and sha256sum or shasum. The installer verifies the pinned mise 2026.8.9
installer, places mise under `~/.local/bin`, and runs without root privileges
or sudo. macOS on Apple silicon and Linux on x86_64 and aarch64 are supported.

WezTerm is optional. Its configured font preference is JetBrains Mono, with
Menlo and the system monospace font as fallbacks.

## Install

```sh
git clone <repository-url> ~/dotfiles
cd ~/dotfiles
./install.sh
exec zsh
```

The bootstrap installs the pinned mise release when necessary, links the
managed dotfiles, clones the pinned Zsh framework and plugin sources, and
installs the locked tools for the current platform. It is safe to rerun after
a successful installation.

## Supported and managed tools

mise manages these 17 tools:

- starship 1.24.2, fzf 0.71.0, ripgrep 15.1.0, bat 0.26.1, fd 10.4.2, and gh
  2.89.0;
- uv 0.11.6, tmux 3.6a, pueue 4.0.4, pueued 4.0.4, git-lfs 3.7.1, viddy 1.3.0, jq 1.7.1,
  node 24.12.0, and Herdr 0.7.5;
- dua 2.34.0, built from source by Cargo as `cargo:dua-cli`; and
- Rust 1.97.1 with the minimal profile and the exact `clippy`, `rustfmt`, and
  `rust-analyzer` components.

`htop` is unmanaged by this repository.
`eza`, `hwloc`, `tree`, `xclip`, `nvtop`, and `navi` were removed and are not installation targets.

### Pueue client and daemon

The bootstrap installs the matching Pueue client and daemon but does not start a background service. Start the daemon manually when needed, then
verify the client connection:

```sh
pueued -d
pueue status
```

Keep both binaries at the same pinned version (`4.0.4`). Existing daemons
and sockets are not stopped or removed by this repository.

Most managed tools have per-platform artifact URLs and checksums in
`mise.lock`. Rust uses mise's core rustup backend, and dua is source-built by
Cargo after that pinned Rust installation; therefore those two do not have
per-platform distribution URL/checksum entries in `mise.lock`. The lockfile
does not promise that every managed tool is a prebuilt artifact.

## ABCI and other managed Linux hosts

On ABCI, request Zsh through the site process first. Once the request is
approved, run the bootstrap in an interactive compute environment according to
site policy. This repository does not change or control the login shell.

For other managed Linux hosts, use the same process only where local policy
allows a user-owned installation under the home directory. The installer does
not require administrator access.

## Existing-file conflicts

The installer does not uninstall existing system tools, Nix installations, or
Devbox installations. It also does not uninstall other existing tool copies.

An unmanaged dotfile conflict stops bootstrap. Move or back up that file
manually, then rerun `./install.sh`; the installer will not overwrite it on
your behalf. Before invoking mise, the installer checks all eleven managed targets
and their existing ancestors. It accepts only a missing target or the exact
repository symlink, and rejects symlinked ancestors without traversing them.
It does not edit `~/.profile`.

## OpenCode permissions

The repository manages `~/.config/opencode/opencode.jsonc`, keeps the shared
superpowers plugin enabled, and sets OpenCode's default permission mode to
`allow`. Codex configuration and approval behavior remain user-owned and are
not changed by this repository.

## Shell and Herdr usage

Open a new shell with Zsh after installation. The `gcof` and `glogf` helpers use
fzf when available and otherwise return without changing state.

Start or reattach a project session with:

```sh
herdr
```

Create a workspace explicitly when needed:

```sh
herdr workspace create --cwd /path/to/project --label project
```

Herdr uses the active directory. Agent integrations and credentials remain
manual and user-owned.

## VS Code lightweight settings

The repository manages only `.config/vscode/settings.json`. Its
`files.watcherExclude` and `search.exclude` settings exclude common generated
and dependency directories from file watching and search, and it disables the
minimap, breadcrumbs, and CodeLens. On macOS the installer links it to
`~/Library/Application Support/Code/User/settings.json`; on Linux it uses
`~/.config/Code/User/settings.json`. If the VS Code User directory is absent, the
installer skips this link and does not create VS Code directories.

Existing `settings.json`, connection settings, extensions, profiles, and cache data
remain user-owned. The installer does not merge or delete an existing settings
file and does not delete VS Code cache. Use VS Code's Profiles UI manually to
separate everyday editing from Python/Jupyter or C/C++/Rust work, enabling only
the extensions needed for each workload.

## WezTerm visual settings

The tracked WezTerm configuration contains portable visual settings: the
Solarized dark color scheme, font fallbacks, transparency, tab-bar appearance,
and resizable window decorations. On GUI startup it opens a window and
maximizes it. These settings apply equally on supported machines and do not
contain machine-specific host configuration.

## Tests

The canonical offline entrypoint is independent of mise and managed tools:

```sh
bash tests/run.sh
```

When the pinned mise binary is available, this convenience task invokes the
same offline suite without automatically installing managed tools:

```sh
mise run test
```

Both entrypoints resolve the physical repository path and perform only
host-independent checks; they do not install tools, access the network, or
require secrets.

## Updating pins

Review version changes and their upstream release material first. Update the
relevant exact version in `mise.toml`, regenerate all supported platform
entries, install only from the resulting lockfile, and run the suite:

```sh
mise lock --platform macos-arm64,linux-x64,linux-arm64
mise install --locked
mise run test
```

Commit `mise.toml` and the regenerated `mise.lock` together. Keep the mise
installer version and checksum in `install.sh` aligned with a reviewed mise
release, verifying the downloaded installer checksum before committing any
change.

## Rust notes

mise uses rustup for its core Rust backend. This backend does not add Rust
distribution URL or checksum entries to `mise.lock`; the pinned version,
profile, and components live in `mise.toml`. Cargo builds dua after Rust is
installed, so it likewise has no per-platform artifact URL in the lockfile.

If an older Rust setup left a stale profile line, review it manually before
changing anything. Make a backup, edit the file, and remove only a line that
sources a nonexistent old rustup environment:

```sh
cp ~/.profile ~/.profile.dotfiles-backup
${EDITOR:-vi} ~/.profile
```

`install.sh` never edits this file.

## Repository layout

```text
.
├── .config
│   ├── git
│   ├── herdr
│   ├── opencode
│   ├── vscode
│   ├── wezterm
│   └── zsh
├── .zshenv
├── install.sh
├── mise.lock
├── mise.toml
└── README.md
```
