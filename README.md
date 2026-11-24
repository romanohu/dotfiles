# dotfiles

Personal dotfiles for reproducible macOS and Linux setup with mise.

## Requirements

Git and Zsh are preinstalled prerequisites. Bootstrap also requires Bash,
curl, tar, and sha256sum or shasum. The installer verifies the pinned mise 2026.10.17
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

Run `nvim` to open LazyVim with a transparent Tokyonight theme, including
sidebars and floating windows. The first launch downloads plugins and builds
syntax parsers, so it requires network access and a C compiler.
LazyVim installs Pyright through Mason for Python. C/C++ support uses `clangd`
from `PATH`, and Rust support uses `rust-analyzer` from the mise toolchain.

## Repository layout

```text
.
├── .config
│   ├── git
│   ├── herdr
│   ├── nvim
│   ├── opencode
│   ├── wezterm
│   └── zsh
├── .zshenv
├── install.sh
├── mise.lock
├── mise.toml
└── README.md
```
