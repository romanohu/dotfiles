# Share an allow-by-default OpenCode permission setting

## Status

Approved design. Implementation is intentionally separate from this document.

## Context

OpenCode currently has a local configuration at `~/.config/opencode/opencode.jsonc`
that enables the shared `obra/superpowers` plugin. The file is not managed by
this repository, so a second machine does not receive the same OpenCode
behavior. The requested default is OpenCode's documented `permission =
"allow"` mode. Codex's existing configuration and approval behavior are out
of scope and must remain unchanged.

## Goals

1. Manage the OpenCode configuration from this repository.
2. Preserve the existing JSON schema declaration and superpowers plugin.
3. Set OpenCode's global permission mode to `allow`.
4. Apply the file through the existing mise dotfiles bootstrap path.

## Non-goals

- Changing any Codex configuration, approval policy, sandbox mode, rules, or
  profiles.
- Modifying the user's existing `.config/zsh/.zshrc` change.
- Adding an OpenCode shell wrapper or changing how OpenCode is launched.
- Managing OpenCode package installation or authentication.

## Configuration

Add `.config/opencode/opencode.jsonc` with the existing settings plus the
permission mode:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": ["superpowers@git+https://github.com/obra/superpowers.git"],
  "permission": "allow"
}
```

Register the file in `mise.toml` as a file-level dotfile mapping:

```toml
"~/.config/opencode/opencode.jsonc" = ".config/opencode/opencode.jsonc"
```

This reuses the existing managed-dotfile collision protection and avoids
replacing the whole OpenCode configuration directory.

## Runtime and safety behavior

After `mise bootstrap` applies the dotfiles, OpenCode reads the shared config
and automatically allows its configured actions. Codex remains governed by
the current `~/.codex/config.toml` and rules. Existing conflicting OpenCode
files are not overwritten by a new mechanism; the existing bootstrap
preflight handles them according to the repository's managed-link policy.

## Tests and verification

Add configuration assertions for the exact OpenCode `permission` value, the
preserved superpowers plugin, and the mise dotfile mapping. Run the existing
host-independent suite and static checks:

```sh
bash tests/run.sh
bash -n install.sh tests/*.sh
git diff --check
```

Also parse the new file as JSON (comments are intentionally not used) and
confirm the target mapping is present without changing Codex files or the
pre-existing `.config/zsh/.zshrc` modification.
