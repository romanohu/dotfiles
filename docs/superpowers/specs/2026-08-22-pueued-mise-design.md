# Add the Pueue daemon to the mise-managed toolset

## Status

Approved design. Implementation is intentionally separate from this document.

## Context

The repository currently installs only the Pueue client through the GitHub
backend. `pueue` is pinned to `4.0.4`, but `pueued` is not installed, so the
client cannot connect to a daemon managed by this repository. Pueue publishes
the client and daemon as separate release assets.

## Goals

1. Install both `pueue` and `pueued` from the same exact Pueue release.
2. Keep the repository on the single mise path and preserve strict lockfile
   installation.
3. Make daemon startup explicit and manual, so bootstrap has no service or
   login-shell side effects.
4. Document and test the client/daemon pair.

## Non-goals

- Starting `pueued` from `install.sh`, mise tasks, launchd, systemd, or a shell
  startup file.
- Stopping or uninstalling an existing Nix/system Pueue daemon or deleting a
  stale socket.
- Supporting different client and daemon versions in the managed configuration.

## Configuration

Replace the single direct `[tools]` entry with two aliases that share the
GitHub backend:

```toml
[tool_alias]
pueue = "github:Nukesor/pueue"
pueued = "github:Nukesor/pueue"

[tools.pueue]
version = "4.0.4"
matching_regex = "^pueue-"

[tools.pueued]
version = "4.0.4"
matching_regex = "^pueued-"
```

The anchored selectors prevent the `pueue` entry from selecting the
`pueued-*` asset. The tracked `mise.lock` is regenerated for the repository's
existing `macos-arm64`, `linux-x64`, and `linux-arm64` platforms and must
contain both binaries' resolved URLs and checksums. No floating or duplicate
single-tool Pueue entry remains.

## Runtime behavior

`mise install --locked` installs both binaries but does not start the daemon.
The documented manual flow is:

```sh
pueued -d
pueue status
```

Both commands resolve through mise shims and therefore use the same pinned
`4.0.4` release. Existing daemons and sockets outside the repository remain
untouched; users can clean those up separately if needed.

## Tests and verification

Configuration tests assert the aliases, exact versions, anchored selectors,
absence of the old direct entry, and lock entries for both binaries. README
tests assert the manual daemon flow and version parity. The normal gates remain:

```sh
bash tests/run.sh
bash -n install.sh tests/*.sh
git diff --check
```

On a networked host, `mise install --locked` is followed by
`pueue --version`, `pueued --version`, `pueued -d`, and `pueue status`.
