local wezterm = require 'wezterm'
local mux = wezterm.mux
local act = wezterm.action
local config = wezterm.config_builder()
local local_config_path = (os.getenv 'HOME' or '') .. '/.config/wezterm/local.lua'
local local_config_ok, local_config = pcall(dofile, local_config_path)

if not local_config_ok or type(local_config) ~= 'table' then
  local_config = {}
end

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

local function split_current_pane(direction)
  return wezterm.action_callback(function(_, pane)
    pane:split { direction = direction, size = 0.5, domain = 'CurrentPaneDomain' }
  end)
end

config.keys = {
  { key = 'v', mods = 'LEADER', action = split_current_pane 'Right' } ,
  { key = 'b', mods = 'LEADER', action = split_current_pane 'Bottom' } ,
  { key = 'h', mods = 'LEADER|CTRL', action = act.ActivatePaneDirection 'Left' } ,
  { key = 'l', mods = 'LEADER|CTRL', action = act.ActivatePaneDirection 'Right' } ,
  { key = 'k', mods = 'LEADER|CTRL', action = act.ActivatePaneDirection 'Up' } ,
  { key = 'j', mods = 'LEADER|CTRL', action = act.ActivatePaneDirection 'Down' } ,
  { key = 'N', mods = 'LEADER|SHIFT', action = act.SpawnCommandInNewTab { args = { 'herdr' } } },
  { key = 'c', mods = 'LEADER', action = act.QuickSelect }
}

if type(local_config.ssh_hosts) == 'table' then
  for _, host in ipairs(local_config.ssh_hosts) do
    if type(host) == 'table'
      and type(host.key) == 'string' and host.key ~= ''
      and type(host.domain) == 'string' and host.domain ~= ''
      and type(host.label) == 'string' and host.label ~= '' then
      table.insert(config.keys, {
        key = host.key,
        mods = 'LEADER',
        action = act.SpawnTab { DomainName = 'SSH:' .. host.domain },
      })
    end
  end
end

wezterm.on("gui-startup", function(cmd)
    local _, _, window = mux.spawn_window(cmd or {})
    window:gui_window():maximize()
end)

return config
