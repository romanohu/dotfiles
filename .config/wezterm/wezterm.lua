local wezterm = require 'wezterm'
local mux = wezterm.mux
local act = wezterm.action
local config = wezterm.config_builder()

config.automatically_reload_config = true
config.color_scheme = 'Solarized (dark) (terminal.sexy)'
config.font = wezterm.font_with_fallback {
  'JetBrains Mono',
  'Menlo',
  'monospace',
}
config.font_size = 10.5
config.window_background_opacity = 0.8
config.macos_window_background_blur = 0
config.hide_tab_bar_if_only_one_tab = true
config.use_fancy_tab_bar = false
config.window_decorations = "RESIZE"

config.leader = { key = 'a', mods = 'CTRL', timeout_milliseconds = 3000 }

config.keys = {
  { key = 'c', mods = 'LEADER', action = act.QuickSelect }
}

wezterm.on("gui-startup", function(cmd)
    local _, _, window = mux.spawn_window(cmd or {})
    window:gui_window():maximize()
end)

return config
