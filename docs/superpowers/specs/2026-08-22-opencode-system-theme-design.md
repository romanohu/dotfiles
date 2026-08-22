# OpenCode system theme design

## Status

Approved design for the shared OpenCode TUI theme configuration.

## Context

The shared OpenCode configuration currently manages permissions and the
superpowers plugin in `.config/opencode/opencode.jsonc`, but it does not set a
TUI theme. OpenCode therefore uses its own built-in `opencode` theme, which
paints an opaque-looking background and hides WezTerm's configured opacity.

OpenCode's official `system` theme is intended to adapt to the terminal. It
uses terminal-default colors, including `none` for the background, so the
terminal emulator remains responsible for the visible background.

## Goals

- Make OpenCode follow the existing WezTerm color and transparency settings.
- Share the theme choice through the dotfiles repository and mise bootstrap.
- Keep the existing shared OpenCode permission mode and superpowers plugin.
- Keep the change portable across supported macOS and Linux hosts.

## Non-goals

- Do not change WezTerm opacity, blur, color scheme, or font settings.
- Do not change OpenCode permissions, plugins, or Codex/Claude configuration.
- Do not define a custom color palette or add project-specific themes.
- Do not edit user-owned shell changes or remove existing system software.

## Design

Add `.config/opencode/tui.json`:

```json
{
  "$schema": "https://opencode.ai/tui.json",
  "theme": "system"
}
```

Add this exact mise dotfile mapping:

```toml
"~/.config/opencode/tui.json" = ".config/opencode/tui.json"
```

The existing `.config/opencode/opencode.jsonc` remains unchanged. OpenCode
loads the TUI theme from the separate `tui.json` file; after bootstrap, users
may restart OpenCode (or select `/theme`) to observe the change.

## Verification

- Configuration tests require the exact `tui.json` content.
- Mise configuration tests require the exact dotfile mapping and reject a
  missing or different theme value.
- `jq empty` validates the JSON file.
- `bash tests/run.sh`, Bash/Zsh syntax checks, and `git diff --check` remain
  green.
- The WezTerm configuration must remain unchanged by the feature.
