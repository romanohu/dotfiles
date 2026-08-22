# Stabilize the Zsh completion cache for faster WezTerm tabs

## Status

Approved design. Implementation is intentionally separate from this document.

## Context

Each WezTerm tab starts a new interactive Zsh process. The WezTerm Lua file
only defines static presentation and the initial GUI window; the measurable
startup cost is in `.config/zsh/.zshrc`, especially Oh My Zsh's `compinit` and
completion definitions. Oh My Zsh currently chooses its cache directory based
on whether the checked-out framework directory is writable. That makes the
completion search path vary between machines and can force cache regeneration.

## Goals

1. Put Oh My Zsh's runtime cache in the user's XDG-style cache directory.
2. Put the completion dump beside that cache with a stable filename per Zsh
   version.
3. Keep completion available at shell startup and retain Oh My Zsh's security
   checks.
4. Leave WezTerm Lua, plugins, aliases, and mise behavior unchanged.

## Non-goals

- Disabling `compaudit` or allowing insecure completion directories.
- Lazy-loading completion, removing Oh My Zsh, or removing plugins.
- Deleting existing `.zcompdump*` files from the user's home directory.
- Changing any user-owned Codex, OpenCode, or shell startup state outside the
  tracked `.config/zsh/.zshrc` change requested here.

## Configuration

Before sourcing `oh-my-zsh.sh`, add:

```zsh
export ZSH_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/oh-my-zsh"
export ZSH_COMPDUMP="$ZSH_CACHE_DIR/.zcompdump-${ZSH_VERSION}"
```

Oh My Zsh continues to run `compinit -i` and creates the cache/dump when
needed. The first shell after this change may rebuild the dump; subsequent
tabs reuse it. Existing dumps are preserved and can be removed manually only
if the user chooses to do so.

## Tests and verification

Configuration tests assert both exact exports and their placement before the
Oh My Zsh source line. `zsh -n` validates syntax. A temporary-home benchmark
compares repeated startup with a writable cache, and the normal suite remains
offline and host-independent:

```sh
bash tests/run.sh
bash -n install.sh tests/*.sh
zsh -n .zshenv .config/zsh/.zshrc .config/zsh/aliases.zsh
git diff --check
```

The existing user modification to `.config/zsh/.zshrc` is preserved and is
not included in the feature commit unless separately requested.
