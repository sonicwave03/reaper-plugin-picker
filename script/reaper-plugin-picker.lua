-- @description Reaper Plugin Picker
-- @author sonicwave03
-- @version 1.0
-- @about
--   A visual, screenshot-based plugin browser for REAPER.
--   * You curate a library of only the plugins you use ("Add plugins")
--   * Plugins are shown as a grid of tiles with screenshots
--   * Groups (tabs), search, keyboard navigation, customizable layout/colors and preset themes
--   * Rename a group from its tab's right-click menu
--   * Adjustable background opacity                    
--   * Font family/size, automatic system theme, and saveable color presets
--   * Optional smoothing for drag previews and keyboard scrolling
--   * Automatic plugin category filters based on plugin names and types
--   * Filter plugins by vendor
--   * Double-click a tile (or press Enter) to add the plugin
--   * Ctrl-click plugins to select multiple and move them into a group together
--   * Screenshot capture (optional) needs the js_ReaScriptAPI extension
--
--   Requires: ReaImGui (ReaPack).  Optional: js_ReaScriptAPI (ReaPack).

if not reaper.ImGui_CreateContext then
  reaper.MB("This script needs the ReaImGui extension.\n\nInstall it via: Extensions > ReaPack > Browse packages > 'ReaImGui', then restart REAPER.", "ReaImGui missing", 0)
  return
end

local r = reaper
local ImGui = setmetatable({}, { __index = function(t, k)
  local f = r['ImGui_' .. k]
  -- flag constants get renamed/removed between ReaImGui versions; a missing one just means "no flag"
  if not f and k:find('Flags_', 1, true) then f = function() return 0 end end
  rawset(t, k, f)
  return f
end })

if r.set_action_options then r.set_action_options(1) end -- re-running the action closes the picker

-- Toggle state: the action (and any toolbar button / menu item bound to it) shows ON while the picker runs
local _, _, ACTION_SECTION, ACTION_CMD = r.get_action_context()
local function set_toggle_state(on)
  if ACTION_CMD and ACTION_CMD ~= 0 then
    r.SetToggleCommandState(ACTION_SECTION, ACTION_CMD, on and 1 or 0)
    r.RefreshToolbar2(ACTION_SECTION, ACTION_CMD)
  end
end

local EXT = 'VisualPluginPicker'
local LEGACY_DIR = r.GetResourcePath() .. '/Data/VisualPluginPicker/'
local user_profile = os.getenv('USERPROFILE')
local DIR = (user_profile and user_profile ~= '')
  and (user_profile .. '/Documents/REAPER Plugin Picker/') or LEGACY_DIR
if DIR ~= LEGACY_DIR and r.RecursiveCreateDirectory(DIR, 0) ~= 0 then
  r.ShowConsoleMsg('Visual Plugin Picker: could not create the Documents data folder; using the REAPER resource folder.\n')
  DIR = LEGACY_DIR
end
local SHOT_DIR = DIR .. 'shots/'
local METADATA_FILE = DIR .. 'plugin-metadata.txt'
r.RecursiveCreateDirectory(SHOT_DIR, 0)
local HAS_JS = (r.JS_LICE_WritePNG ~= nil and r.JS_GDI_Blit ~= nil and r.JS_Window_GetClientRect ~= nil)
local HAS_JS_WINDOW = (r.JS_Window_FromPoint ~= nil and r.JS_Window_GetParent ~= nil
  and r.JS_Window_GetTitle ~= nil)

local function copy_data_file(source, destination)
  local input, err = io.open(source, 'rb')
  if not input then return false, err end
  local output, output_err = io.open(destination, 'wb')
  if not output then
    input:close()
    return false, output_err
  end

  local failure
  while true do
    local chunk, read_err = input:read(65536)
    if not chunk then
      failure = read_err
      break
    end
    local written, write_err = output:write(chunk)
    if not written then
      failure = write_err
      break
    end
  end

  local input_closed, input_err = input:close()
  local output_closed, close_err = output:close()
  if failure or not input_closed or not output_closed then
    os.remove(destination)
    return false, failure or input_err or close_err
  end
  return true
end

local function move_data_file(source, destination, issues)
  if not r.file_exists(source) then return end
  if r.file_exists(destination) then
    issues[#issues + 1] = source .. ' (destination already exists)'
    return
  end
  local moved = os.rename(source, destination)
  if moved then return end
  local copied, err = copy_data_file(source, destination)
  if copied then
    local removed, remove_err = os.remove(source)
    if not removed then
      issues[#issues + 1] = source .. ' (copied but could not remove old file: ' .. tostring(remove_err) .. ')'
    end
  else
    issues[#issues + 1] = source .. ' (' .. tostring(err) .. ')'
  end
end

local function migrate_data_to_documents()
  if DIR == LEGACY_DIR then return end
  local issues = {}
  for _, name in ipairs({ 'library.txt', 'groups.txt', 'themes.txt' }) do
    move_data_file(LEGACY_DIR .. name, DIR .. name, issues)
  end

  local old_shot_dir = LEGACY_DIR .. 'shots/'
  local old_shot_names = {}
  local index = 0
  while true do
    local name = r.EnumerateFiles(old_shot_dir, index)
    if not name then break end
    old_shot_names[#old_shot_names + 1] = name
    index = index + 1
  end
  for _, name in ipairs(old_shot_names) do
    move_data_file(old_shot_dir .. name, SHOT_DIR .. name, issues)
  end

  if #issues > 0 then
    r.ShowConsoleMsg('Visual Plugin Picker: some old data was left in its REAPER resource folder to avoid overwriting existing files:\n'
      .. table.concat(issues, '\n') .. '\n')
  end
end

local ctx = ImGui.CreateContext('Plugin Picker')
local last_err = nil
local drag = nil -- { e = entry, moved = bool } while a tile is being pressed/dragged
local show_colors = false
local hex_edit = {}
local frame_dt = 1 / 30
local last_frame_time = r.time_precise()
local last_picker_x, last_picker_y, last_mouse_x, last_mouse_y
local lightweight_until = 0
local group_tab_dragging = false
local group_tab_drag_source = nil
local group_tab_highlight = nil

---------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------
-- Every color the picker uses. Edited in "Settings > Customize colors..."
local COLOR_DEFS = {
  { section = 'General Colors' },
  { key = 'accent',          label = 'Accent',                 def = 0x46B9FEFF },
  { key = 'window_bg',       label = 'Window background',      def = 0x121212FF },
  { key = 'panel_bg',        label = 'Panel / popup background', def = 0x1A1A1AFF },
  { key = 'title_bg',        label = 'Title bar',              def = 0x1B1B1BFF },
  { key = 'title_bg_active', label = 'Title bar (active)',     def = 0x262626FF },
  { key = 'text',            label = 'Text',                   def = 0xE0E0E0FF },
  { key = 'text_dim',        label = 'Dim text',               def = 0x808080FF },
  { key = 'separator',       label = 'Separator / border',     def = 0x4B4B4BFF },

  { section = 'Tile Colors' },
  { key = 'tile',            label = 'Tile background',        def = 0x1E1E1EFF },
  { key = 'tile_hover',      label = 'Tile hover',             def = 0x2E2E2EFF },
  { key = 'tile_hl',         label = 'Tile highlight (hover / selected / drag)', def = 0x46B9FEFF },
  { key = 'tile_text',       label = 'Tile name text',         def = 0xE0E0E0FF },
  { key = 'tile_placeholder', label = 'Name text without screenshot', def = 0x8A8A8AFF },
  { key = 'tile_missing',    label = 'Not installed text',     def = 0xFF6B6BFF },
  { key = 'drag_dim',        label = 'Dim over tile being dragged', def = 0x000000A0 },

  { section = 'List Colors' },
  { key = 'list_in',         label = 'In-library text (Add plugins)', def = 0x7FD1FFFF },
  { key = 'row_selected',    label = 'Row selected',           def = 0x204860FF },
  { key = 'row_hover',       label = 'Row hover',              def = 0x24516CFF },
  { key = 'row_pressed',     label = 'Row pressed',            def = 0x285977FF },

  { section = 'Controls Colors' },
  { key = 'button',          label = 'Button',                 def = 0x3A3A3AFF },
  { key = 'button_hover',    label = 'Button hover',           def = 0x4A4A4AFF },
  { key = 'button_active',   label = 'Button active',          def = 0x585858FF },
  { key = 'control_bg',      label = 'Control bg',             def = 0x262626FF },
  { key = 'control_hover',   label = 'Control hover',          def = 0x303030FF },
  { key = 'control_active',  label = 'Control active',         def = 0x3A3A3AFF },
  { key = 'scroll_track',    label = 'Scrollbar track',        def = 0x00000000 },
  { key = 'scroll_grab',     label = 'Scrollbar grab',         def = 0x505050FF },
  { key = 'scroll_hover',    label = 'Scrollbar hover',        def = 0x585858FF },
  { key = 'scroll_active',   label = 'Scrollbar active',       def = 0x5D5D5DFF },

  { section = 'Tab Colors' },
  { key = 'tab',             label = 'Tab',                    def = 0x262626FF },
  { key = 'tab_hover',       label = 'Tab hover',              def = 0x3A3A3AFF },
  { key = 'tab_active',      label = 'Tab selected',           def = 0x25506BFF },
}

local COLOR_THEMES = {
  Midnight = {
    accent = 0x72A7FFFF, window_bg = 0x070D1AFF, panel_bg = 0x0C1424FF,
    title_bg = 0x101A2DFF, title_bg_active = 0x182744FF,
    text = 0xE2EAFFFF, text_dim = 0x8594AEFF, separator = 0x2C3D59FF,
    tile = 0x111C30FF, tile_hover = 0x192A44FF, tile_hl = 0x5D9BFFFF,
    tile_text = 0xE8F0FFFF, tile_placeholder = 0x8495B2FF, tile_missing = 0xFF8181FF,
    drag_dim = 0x000000A0, list_in = 0x83C9FFFF,
    row_selected = 0x183252FF, row_hover = 0x204168FF, row_pressed = 0x28517DFF,
    button = 0x1C2A42FF, button_hover = 0x2A3D5AFF, button_active = 0x344D70FF,
    control_bg = 0x15233AFF, control_hover = 0x1B2F4CFF, control_active = 0x223B5EFF,
    scroll_track = 0x00000000, scroll_grab = 0x465A78FF,
    scroll_hover = 0x556B8BFF, scroll_active = 0x627CA3FF,
    tab = 0x16243AFF, tab_hover = 0x233956FF, tab_active = 0x244A78FF,
  },
  Light = {
    accent = 0x1265B5FF, window_bg = 0xF5F7FAFF, panel_bg = 0xEAEFF5FF,
    title_bg = 0xE3EAF2FF, title_bg_active = 0xD6E2EFFF,
    text = 0x1D2838FF, text_dim = 0x657286FF, separator = 0xBCC7D5FF,
    tile = 0xFFFFFFFF, tile_hover = 0xF0F4F8FF, tile_hl = 0x1265B5FF,
    tile_text = 0x1D2838FF, tile_placeholder = 0x64748BFF, tile_missing = 0xC62828FF,
    drag_dim = 0x00000040, list_in = 0x075C9AFF,
    row_selected = 0xD7E9F8FF, row_hover = 0xE7F0F8FF, row_pressed = 0xC8DDEDFF,
    button = 0xE1E7EEFF, button_hover = 0xD3DCE6FF, button_active = 0xC4D0DEFF,
    control_bg = 0xF3F6F9FF, control_hover = 0xE4ECF4FF, control_active = 0xD6E2EFFF,
    scroll_track = 0xDDE3EAFF, scroll_grab = 0xAAB6C4FF,
    scroll_hover = 0x8B99A9FF, scroll_active = 0x718094FF,
    tab = 0xF2F5F9FF, tab_hover = 0xE2EAF2FF, tab_active = 0xD5E7F7FF,
  },
  ['Reaper 7'] = {
    accent = 0x14A08CFF, window_bg = 0x222625FF, panel_bg = 0x333333FF,
    title_bg = 0x22221EFF, title_bg_active = 0x303433FF,
    text = 0xE0E0DEFF, text_dim = 0x8C8C8CFF, separator = 0x4E4E47FF,
    tile = 0x333333FF, tile_hover = 0x414545FF, tile_hl = 0x14A08CFF,
    tile_text = 0xE0E0DEFF, tile_placeholder = 0x848484FF, tile_missing = 0xF07864FF,
    drag_dim = 0x000000A0, list_in = 0x4BC4B0FF,
    row_selected = 0x3E5551FF, row_hover = 0x465D59FF, row_pressed = 0x526B66FF,
    button = 0x3A3C39FF, button_hover = 0x4E4E47FF, button_active = 0x5C5D56FF,
    control_bg = 0x292B29FF, control_hover = 0x3A3D3AFF, control_active = 0x4A4E4AFF,
    scroll_track = 0x00000000, scroll_grab = 0x666A66FF,
    scroll_hover = 0x7C817CFF, scroll_active = 0x919791FF,
    tab = 0x292C2AFF, tab_hover = 0x383D3AFF, tab_active = 0x405853FF,
  },
}
local BUILTIN_COLOR_THEME_NAMES = { 'Default', 'Reaper 7', 'Midnight', 'Light' }
local COLOR_KEYS = {}
for _, def in ipairs(COLOR_DEFS) do
  if def.key then COLOR_KEYS[#COLOR_KEYS + 1] = def.key end
end
local saved_color_themes = {}
local saved_color_theme_names = {}
local theme_name_input = ''
local FONT_FAMILIES = {
  'sans-serif', 'serif', 'monospace', 'cursive', 'fantasy',
  'Segoe UI', 'Arial', 'Consolas',
}

local MIN_TILE_W, MAX_TILE_W = 80, 400

local DEFAULTS = {
  tile_w = 170, view_mode = 'Grid', aspect = 0.75, show_names = true, ui_scale = 1.0, bg_opacity = 90,
  color_theme = 'Default', auto_theme = false,
  font_family = 'sans-serif', font_size = 13,
  smooth_animations = false,
  close_after = false, open_ui = true, auto_capture = false,
  cap_delay = 1.5, cap_method = 0,
  win_w = 780, win_h = 560, target = 0, cur_group = 'All', cur_category = 'All',
  cur_vendor = 'All',
}
for _, d in ipairs(COLOR_DEFS) do
  if d.key then DEFAULTS['c_' .. d.key] = d.def end
end
local cfg = {}

local function apply_color_theme(name)
  local palette = COLOR_THEMES[name] or saved_color_themes[name]
  if name ~= 'Default' and not palette then return end
  for _, def in ipairs(COLOR_DEFS) do
    if def.key then cfg['c_' .. def.key] = (palette and palette[def.key]) or def.def end
  end
  cfg.color_theme = name
  cfg.auto_theme = false
  hex_edit = {}
end

local function load_cfg()
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  local s = r.GetExtState(EXT, 'cfg')
  local has_color_theme = false
  for k, v in s:gmatch('([%w_]+)=([^\n]*)') do
    local d = DEFAULTS[k]
    if d ~= nil then
      if k == 'color_theme' then has_color_theme = true end
      if type(d) == 'number' then cfg[k] = tonumber(v) or d
      elseif type(d) == 'boolean' then cfg[k] = (v == '1')
      else cfg[k] = v end
    end
  end
  if cfg.view_mode ~= 'Grid' and cfg.view_mode ~= 'List' then cfg.view_mode = 'Grid' end
  cfg.tile_w = math.max(MIN_TILE_W, math.min(MAX_TILE_W, cfg.tile_w))
  if cfg.tile_w == MIN_TILE_W then cfg.view_mode = 'List' end
  if not has_color_theme then
    for _, def in ipairs(COLOR_DEFS) do
      if def.key and cfg['c_' .. def.key] ~= def.def then
        cfg.color_theme = 'Custom'
        break
      end
    end
  end
  local known_theme = cfg.color_theme == 'Custom' or saved_color_themes[cfg.color_theme] ~= nil
  for _, name in ipairs(BUILTIN_COLOR_THEME_NAMES) do
    if cfg.color_theme == name then known_theme = true; break end
  end
  if not known_theme then cfg.color_theme = 'Custom' end
end

local function save_cfg()
  local t = {}
  for k, v in pairs(cfg) do
    if type(v) == 'boolean' then v = v and '1' or '0' end
    t[#t + 1] = k .. '=' .. tostring(v)
  end
  r.SetExtState(EXT, 'cfg', table.concat(t, '\n'), true)
end

local BACKGROUND_THEME_COLORS = {
  window_bg = true, panel_bg = true, title_bg = true, title_bg_active = true,
}

local function C(key) return math.floor(cfg['c_' .. key]) end
local function theme_color(key)
  local color = C(key)
  if BACKGROUND_THEME_COLORS[key] then
    local opacity = math.max(70, math.min(100, cfg.bg_opacity or 90))
    local alpha = math.floor((color & 0xFF) * opacity / 100)
    return (color & 0xFFFFFF00) | alpha
  end
  return color
end
local function toolbar_icon_button(id, tooltip, kind)
  local scale = cfg.ui_scale
  local size = 28 * scale
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local clicked = ImGui.InvisibleButton(ctx, id, size, size)
  local hovered = ImGui.IsItemHovered(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local bg = hovered and C('button_hover') or C('button')
  local fg = (kind == 'add') and C('accent') or C('text')
  ImGui.DrawList_AddRectFilled(dl, x, y, x + size, y + size, bg, 5 * scale)
  local cx, cy = x + size / 2, y + size / 2
  if kind == 'add' then
    local half = 6 * scale
    ImGui.DrawList_AddLine(dl, cx - half, cy, cx + half, cy, fg, 2 * scale)
    ImGui.DrawList_AddLine(dl, cx, cy - half, cx, cy + half, fg, 2 * scale)
  else
    for i, knob_pos in ipairs({ 0.36, 0.64, 0.44 }) do
      local ly = y + size * (0.28 + (i - 1) * 0.22)
      ImGui.DrawList_AddLine(dl, x + size * 0.24, ly, x + size * 0.76, ly, fg, 1.6 * scale)
      ImGui.DrawList_AddCircleFilled(dl, x + size * knob_pos, ly, 2.4 * scale, fg, 12)
    end
  end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, tooltip) end
  return clicked
end

local function draw_favorites_star(dl, x, y, size, color)
  local scale = size / 16
  local function line(x1, y1, x2, y2)
    ImGui.DrawList_AddLine(
      dl, x + x1 * scale, y + y1 * scale, x + x2 * scale, y + y2 * scale,
      color, 1.5 * scale)
  end

  local points = {}
  for i = 0, 9 do
    local radius = (i % 2 == 0) and 6.5 or 2.8
    local angle = -math.pi / 2 + i * math.pi / 5
    points[#points + 1] = { 8 + math.cos(angle) * radius, 8 + math.sin(angle) * radius }
  end
  for i, point in ipairs(points) do
    local next_point = points[i % #points + 1]
    line(point[1], point[2], next_point[1], next_point[2])
  end
end

local function random_plugin_button(enabled)
  local scale = cfg.ui_scale
  local size = 44 * scale
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local clicked = ImGui.InvisibleButton(ctx, '##random_plugin', size, size)
  local hovered = enabled and ImGui.IsItemHovered(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local cx, cy = x + size / 2, y + size / 2
  local bg = enabled and (hovered and C('accent') or C('button')) or C('button')
  local fg = C('text')
  ImGui.DrawList_AddCircleFilled(dl, cx, cy, size / 2, bg, 32)
  local die = 19 * scale
  ImGui.DrawList_AddRectFilled(
    dl, cx - die / 2, cy - die / 2, cx + die / 2, cy + die / 2, fg, 3 * scale)
  local dot = C('button')
  local dot_radius = 1.8 * scale
  for _, point in ipairs({
    { -0.28, -0.28 }, { 0.28, -0.28 }, { 0, 0 },
    { -0.28, 0.28 }, { 0.28, 0.28 },
  }) do
    ImGui.DrawList_AddCircleFilled(
      dl, cx + point[1] * die, cy + point[2] * die, dot_radius, dot, 12)
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, enabled and 'Show a random plugin' or 'No matching plugins to pick')
  end
  return clicked and enabled
end

---------------------------------------------------------------------
-- State
---------------------------------------------------------------------
local view = 'grid'            -- 'grid' | 'manage'
local search = ''
local sel = 1
local scroll_random_selection = false
local focus_search = true
local status, status_t = '', 0
local last_cols = 1
local new_group_name = ''
local rename_group_original, rename_group_name = nil, ''
local pending_tab = nil
local msearch, mfilter, mdirty = '', 'All', true
local mfiltered = {}
local mfilters = { 'All' }
local loads_this_frame = 0
local next_auto_theme_check = 0

local library, groups, lib_index = {}, {}, {}
local FAVORITES_GROUP = 'Favorites'
local installed, inst_list, types = {}, {}, {}
local images = {}
local image_sizes = {}
local lbl_cache = {}
local multi_selected = {}
local metadata_overrides = {}
local metadata_edit_name = nil
local metadata_edit_category = 'Automatic'
local metadata_edit_vendor = ''
local rename_plugin_name, rename_plugin_value = nil, ''
local rename_plugin_requested = false
local pending_selected_plugin = nil
local metadata_edit_requested = false

local function set_status(msg) status, status_t = msg, os.time() end

local function normalize_color_theme_name(name)
  name = name:gsub('^%s+', ''):gsub('%s+$', '')
  if name == '' or #name > 64 or name:find('[%c]') then return nil end
  local lower = name:lower()
  if lower == 'auto' or lower == 'custom' or lower == 'unsaved' then return nil end
  for _, builtin in ipairs(BUILTIN_COLOR_THEME_NAMES) do
    if lower == builtin:lower() then return nil end
  end
  return name
end

local function find_saved_color_theme(name)
  local lower = name:lower()
  for saved_name in pairs(saved_color_themes) do
    if saved_name:lower() == lower then return saved_name end
  end
end

local function refresh_saved_color_theme_names()
  saved_color_theme_names = {}
  for name in pairs(saved_color_themes) do
    saved_color_theme_names[#saved_color_theme_names + 1] = name
  end
  table.sort(saved_color_theme_names, function(a, b) return a:lower() < b:lower() end)
end

local function load_saved_color_themes()
  local path = DIR .. 'themes.txt'
  local f, err = io.open(path, 'r')
  if not f then
    if r.file_exists(path) then
      r.ShowConsoleMsg('Visual Plugin Picker: could not read themes: ' .. tostring(err) .. '\n')
    end
    return
  end

  local line_number = 0
  for raw in f:lines() do
    line_number = line_number + 1
    raw = raw:gsub('\r', '')
    local name, values = raw:match('^([^\t]+)\t(.*)$')
    local normalized = name and normalize_color_theme_name(name)
    if normalized and not find_saved_color_theme(normalized) then
      local palette, count, valid = {}, 0, true
      for hex in values:gmatch('[^,]+') do
        count = count + 1
        local color = tonumber(hex, 16)
        local key = COLOR_KEYS[count]
        if not key or not color or color > 0xFFFFFFFF then
          valid = false
          break
        end
        palette[key] = color
      end
      if valid and count == #COLOR_KEYS then
        saved_color_themes[normalized] = palette
      else
        r.ShowConsoleMsg(('Visual Plugin Picker: ignoring invalid theme at line %d.\n'):format(line_number))
      end
    elseif raw ~= '' then
      r.ShowConsoleMsg(('Visual Plugin Picker: ignoring invalid or duplicate theme at line %d.\n'):format(line_number))
    end
  end
  f:close()
  refresh_saved_color_theme_names()
end

local function save_saved_color_themes()
  local path = DIR .. 'themes.txt'
  local f, err = io.open(path, 'w')
  if not f then
    set_status('Could not save themes: ' .. tostring(err))
    r.ShowConsoleMsg('Visual Plugin Picker: could not save themes: ' .. tostring(err) .. '\n')
    return false
  end
  for _, name in ipairs(saved_color_theme_names) do
    local palette, values = saved_color_themes[name], {}
    for _, key in ipairs(COLOR_KEYS) do
      values[#values + 1] = ('%08X'):format(math.floor(palette[key]))
    end
    local ok, write_err = f:write(name, '\t', table.concat(values, ','), '\n')
    if not ok then
      f:close()
      set_status('Could not save themes: ' .. tostring(write_err))
      r.ShowConsoleMsg('Visual Plugin Picker: could not save themes: ' .. tostring(write_err) .. '\n')
      return false
    end
  end
  local ok, close_err = f:close()
  if not ok then
    set_status('Could not save themes: ' .. tostring(close_err))
    r.ShowConsoleMsg('Visual Plugin Picker: could not save themes: ' .. tostring(close_err) .. '\n')
    return false
  end
  return true
end

local function save_current_color_theme(name)
  local normalized = normalize_color_theme_name(name)
  if not normalized then
    set_status('Enter a unique theme name (up to 64 characters).')
    return false
  end
  normalized = find_saved_color_theme(normalized) or normalized

  local palette = {}
  for _, key in ipairs(COLOR_KEYS) do palette[key] = math.floor(cfg['c_' .. key]) end
  local previous = saved_color_themes[normalized]
  saved_color_themes[normalized] = palette
  refresh_saved_color_theme_names()
  if not save_saved_color_themes() then
    saved_color_themes[normalized] = previous
    refresh_saved_color_theme_names()
    return false
  end

  cfg.color_theme = normalized
  cfg.auto_theme = false
  theme_name_input = normalized
  set_status('Saved theme "' .. normalized .. '".')
  return true
end

local function delete_saved_color_theme(name)
  local palette = saved_color_themes[name]
  if not palette then
    set_status('Select a saved theme to delete.')
    return false
  end
  saved_color_themes[name] = nil
  refresh_saved_color_theme_names()
  if not save_saved_color_themes() then
    saved_color_themes[name] = palette
    refresh_saved_color_theme_names()
    return false
  end
  cfg.color_theme = 'Custom'
  cfg.auto_theme = false
  theme_name_input = ''
  set_status('Deleted theme "' .. name .. '".')
  return true
end

local function detect_system_color_theme()
  if not r.GetOS or not r.GetOS():find('Win', 1, true) or not r.ExecProcess then
    return 'Default'
  end
  local output = r.ExecProcess(
    'reg query "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize" /v AppsUseLightTheme',
    1000)
  local value = type(output) == 'string' and output:match('AppsUseLightTheme.-0[xX]([%x]+)')
  return value and tonumber(value, 16) == 1 and 'Light' or 'Default'
end

local function apply_auto_color_theme()
  local name = detect_system_color_theme()
  apply_color_theme(name)
  cfg.auto_theme = true
  return name
end

local font_cache = {}
local function get_picker_font()
  if not r.ImGui_CreateFont then return nil end
  local family = cfg.font_family
  local cached = font_cache[family]
  if cached ~= nil then return cached or nil end

  local ok, font = pcall(r.ImGui_CreateFont, family)
  if not ok or not font then
    font_cache[family] = false
    local err = ok and 'font is unavailable' or tostring(font)
    set_status('Could not load font "' .. family .. '".')
    r.ShowConsoleMsg('Visual Plugin Picker: could not load font "' .. family .. '": ' .. err .. '\n')
    return nil
  end
  if r.ImGui_Attach then
    local attached, attach_err = pcall(r.ImGui_Attach, ctx, font)
    if not attached then
      font_cache[family] = false
      set_status('Could not attach font "' .. family .. '".')
      r.ShowConsoleMsg('Visual Plugin Picker: could not attach font: ' .. tostring(attach_err) .. '\n')
      return nil
    end
  end
  font_cache[family] = font
  return font
end

local function clear_multi_selection()
  multi_selected = {}
end

local function toggle_multi_selection(name)
  if multi_selected[name] then
    multi_selected[name] = nil
  else
    multi_selected[name] = true
  end
end

local function get_multi_selected_entries()
  local selected = {}
  for _, e in ipairs(library) do
    if multi_selected[e.name] then selected[#selected + 1] = e end
  end
  return selected
end

---------------------------------------------------------------------
-- Plugin helpers
---------------------------------------------------------------------
local function parse_name(name)
  local ptype, rest = name:match('^([^:]+):%s*(.*)$')
  if not ptype then return 'Other', name, false end
  local base = ptype:gsub('i$', '')
  return base, rest, base ~= ptype
end

local CATEGORY_FILTERS = {
  'All', 'Effects', 'EQ', 'Dynamics', 'Reverb', 'Delay', 'Modulation',
  'Distortion', 'Utility', 'Instrument', 'Other',
}
local CATEGORY_EDIT_OPTIONS = {
  'Automatic', 'Effects', 'EQ', 'Dynamics', 'Reverb', 'Delay', 'Modulation',
  'Distortion', 'Utility', 'Instrument', 'Other',
}
local CATEGORY_OVERRIDE_MAP = {
  Effects = { 'Effects', 'Other' },
  EQ = { 'Effects', 'EQ' },
  Dynamics = { 'Effects', 'Dynamics' },
  Reverb = { 'Effects', 'Reverb' },
  Delay = { 'Effects', 'Delay' },
  Modulation = { 'Effects', 'Modulation' },
  Distortion = { 'Effects', 'Distortion' },
  Utility = { 'Utility', 'Utility' },
  Instrument = { 'Instrument', 'Instrument' },
  Other = { 'Other', 'Other' },
}
local EFFECT_CATEGORY_ORDER = { 'EQ', 'Dynamics', 'Reverb', 'Delay', 'Modulation', 'Distortion' }

local function has_category_keyword(text, keywords)
  for _, keyword in ipairs(keywords) do
    if text:find(' ' .. keyword .. ' ', 1, true) then return true end
  end
  return false
end

local CATEGORY_KEYWORDS = {
  Instrument = {
    'synth', 'synthesizer', 'sampler', 'piano', 'organ', 'drum machine',
    'drum kit', 'rompler', 'soundfont', 'instrument', 'keyboard', 'workstation',
    'kontakt', 'serum', 'vital', 'omnisphere', 'massive', 'reasynth',
    'reasamplomatic5000',
  },
  Utility = {
    'utility', 'analyzer', 'analyser', 'spectrum', 'meter', 'tuner',
    'oscilloscope', 'phase meter', 'loudness', 'gain', 'trim', 'routing',
    'stereo tool', 'midi monitor', 'volume', 'polarity',
  },
  EQ = {
    'eq', 'equalizer', 'equaliser', 'equalization', 'equalisation',
    'lowpass', 'low pass', 'highpass', 'high pass', 'bandpass', 'band pass',
    'notch filter', 'shelving',
    'reaeq', 'slickeq', 'pro q', 'parametric eq', 'nova',
  },
  Dynamics = {
    'compressor', 'compression', 'limiter', 'maximizer', 'maximiser',
    'expander', 'gate', 'de esser', 'deesser', 'transient', 'leveler',
    'leveller', 'ducking', 'reacomp', 'realimit', 'reagate', 'pro c', 'pro l', 'pro g',
  },
  Reverb = {
    'reverb', 'convolution', 'room', 'hall', 'plate reverb', 'reaverb',
    'valhallaroom', 'valhallavintageverb', 'pro r',
  },
  Delay = {
    'delay', 'echo', 'slapback', 'readelay', 'echoboy', 'replika', 'tape echo',
    'valhalladelay', 'supermassive',
  },
  Modulation = {
    'chorus', 'flanger', 'phaser', 'tremolo', 'vibrato', 'rotary',
    'ring modulator', 'ringmodulator', 'ensemble',
  },
  Distortion = {
    'distortion', 'saturator', 'saturation', 'overdrive', 'fuzz',
    'bitcrusher', 'bit crusher', 'amp sim', 'cabinet simulator',
  },
}

local function classify_plugin(name, ptype, inst)
  local text = ' ' .. name:lower():gsub('[^%w]+', ' ') .. ' '
  if inst or has_category_keyword(text, CATEGORY_KEYWORDS.Instrument) then
    return 'Instrument', 'Instrument'
  end
  if has_category_keyword(text, CATEGORY_KEYWORDS.Utility) then
    return 'Utility', 'Utility'
  end
  for _, category in ipairs(EFFECT_CATEGORY_ORDER) do
    if has_category_keyword(text, CATEGORY_KEYWORDS[category]) then
      return 'Effects', category
    end
  end
  if ptype == 'Other' then return 'Other', 'Other' end
  return 'Effects', 'Other'
end

local function classify_vendor(display, ptype)
  local vendor = display:match('%(([^()]+)%)%s*$')
    or display:match('^([^:]+):%s+.+$')
  if vendor then
    vendor = vendor:gsub('^%s+', ''):gsub('%s+$', '')
    if vendor ~= '' then return vendor end
  end
  return ptype == 'JS' and 'JSFX' or 'Unknown'
end

local function make_entry(name, group_memberships)
  local ty, disp, inst = parse_name(name)
  local category, subcategory = classify_plugin(name, ty, inst)
  local vendor = classify_vendor(disp, ty)
  local override = metadata_overrides[name]
  if override then
    local category_override = CATEGORY_OVERRIDE_MAP[override.category]
    if category_override then category, subcategory = category_override[1], category_override[2] end
    if override.vendor then vendor = override.vendor end
  end
  local display = override and override.display or disp
  local entry_groups, seen = {}, {}
  if type(group_memberships) == 'string' then
    if group_memberships ~= '' then entry_groups[1] = group_memberships end
  elseif type(group_memberships) == 'table' then
    for _, group_name in ipairs(group_memberships) do
      if group_name ~= '' and not seen[group_name] then
        entry_groups[#entry_groups + 1] = group_name
        seen[group_name] = true
      end
    end
  end
  return {
    name = name, groups = entry_groups, type = ty, display = display, inst = inst,
    category = category, subcategory = subcategory, vendor = vendor,
    lower = (name .. ' ' .. display):lower(),
  }
end

local function entry_has_group(entry, group_name)
  for _, name in ipairs(entry.groups) do
    if name == group_name then return true end
  end
  return false
end

local function add_entry_group(entry, group_name)
  if not entry_has_group(entry, group_name) then
    entry.groups[#entry.groups + 1] = group_name
  end
end

local function remove_entry_group(entry, group_name)
  for i = #entry.groups, 1, -1 do
    if entry.groups[i] == group_name then table.remove(entry.groups, i) end
  end
end

local function shot_path(name)
  local safe = name:gsub('[^%w%-_ %.%(%)]', '_')
  return SHOT_DIR .. safe .. '.png'
end

local function load_metadata_overrides()
  metadata_overrides = {}
  local f, err = io.open(METADATA_FILE, 'r')
  if not f then
    if r.file_exists(METADATA_FILE) then
      r.ShowConsoleMsg('Visual Plugin Picker: could not read plugin metadata: ' .. tostring(err) .. '\n')
    end
    return
  end
  for raw in f:lines() do
    local line = raw:gsub('\r', '')
    local name, category, vendor, display = line:match('^([^\t]+)\t([^\t]*)\t([^\t]*)\t([^\t]*)$')
    if not name then
      name, category, vendor = line:match('^([^\t]+)\t([^\t]*)\t(.*)$')
    end
    if name and name ~= '' and (category == '' or CATEGORY_OVERRIDE_MAP[category]) then
      category = category ~= '' and category or nil
      vendor = vendor ~= '' and vendor or nil
      display = display ~= '' and display or nil
      if category or vendor or display then
        metadata_overrides[name] = { category = category, vendor = vendor, display = display }
      end
    end
  end
  f:close()
end

local function save_metadata_overrides()
  local f, err = io.open(METADATA_FILE, 'w')
  if not f then
    set_status('Could not save plugin metadata.')
    r.ShowConsoleMsg('Visual Plugin Picker: could not save plugin metadata: ' .. tostring(err) .. '\n')
    return false
  end
  local names = {}
  for name in pairs(metadata_overrides) do names[#names + 1] = name end
  table.sort(names)
  local failure
  for _, name in ipairs(names) do
    local override = metadata_overrides[name]
    local ok, write_err = f:write(
      name, '\t', override.category or '', '\t', override.vendor or '',
      '\t', override.display or '', '\n')
    if not ok then failure = write_err; break end
  end
  local closed, close_err = f:close()
  if failure or not closed then
    local message = failure or close_err
    set_status('Could not save plugin metadata.')
    r.ShowConsoleMsg('Visual Plugin Picker: could not save plugin metadata: ' .. tostring(message) .. '\n')
    return false
  end
  return true
end

local VENDOR_FILTERS = { 'All' }

local function sort_library()
  table.sort(library, function(a, b) return a.display:lower() < b.display:lower() end)
  lib_index = {}
  for _, e in ipairs(library) do lib_index[e.name] = e end
  local vendors, seen = {}, {}
  for _, e in ipairs(library) do
    local key = e.vendor:lower()
    if not seen[key] then
      vendors[#vendors + 1] = e.vendor
      seen[key] = true
    end
  end
  table.sort(vendors, function(a, b) return a:lower() < b:lower() end)
  VENDOR_FILTERS = { 'All' }
  for _, vendor in ipairs(vendors) do
    VENDOR_FILTERS[#VENDOR_FILTERS + 1] = vendor
  end
  if cfg.cur_vendor ~= 'All' and not seen[cfg.cur_vendor:lower()] then
    cfg.cur_vendor = 'All'
  end
end

local function update_plugin_metadata(name, category_choice, vendor_text, display_text)
  local entry = lib_index[name]
  if not entry then
    set_status('Could not update metadata: plugin is no longer in the library.')
    return false
  end
  if category_choice ~= 'Automatic' and not CATEGORY_OVERRIDE_MAP[category_choice] then
    set_status('Could not update metadata: invalid category.')
    return false
  end

  local vendor = vendor_text:gsub('[%c]', ' '):gsub('^%s+', ''):gsub('%s+$', '')
  if #vendor > 128 then
    set_status('Vendor name must be 128 characters or fewer.')
    return false
  end
  local display
  if display_text ~= nil then
    display = display_text:gsub('[%c]', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if #display > 128 then
      set_status('Plugin display name must be 128 characters or fewer.')
      return false
    end
  end

  local override = {}
  if category_choice ~= 'Automatic' then override.category = category_choice end
  local entry_type, detected_display = parse_name(name)
  local detected_vendor = classify_vendor(detected_display, entry_type)
  if vendor ~= '' and vendor ~= detected_vendor then
    override.vendor = vendor
  end
  if display_text == nil then
    local previous_override = metadata_overrides[name]
    if previous_override and previous_override.display then override.display = previous_override.display end
  elseif display ~= '' and display ~= detected_display then
    override.display = display
  end

  local previous_override = metadata_overrides[name]
  metadata_overrides[name] = (override.category or override.vendor or override.display) and override or nil
  if not save_metadata_overrides() then
    metadata_overrides[name] = previous_override
    return false
  end

  local replacement = make_entry(name, entry.groups)
  for i, current in ipairs(library) do
    if current.name == name then
      library[i] = replacement
      break
    end
  end
  sort_library()
  clear_multi_selection()
  if display_text ~= nil then
    pending_selected_plugin = name
    set_status(('Renamed plugin to "%s".'):format(replacement.display))
  else
    set_status(('Updated metadata for "%s".'):format(replacement.display))
  end
  return true
end

local function save_library()
  local f = io.open(DIR .. 'library.txt', 'w')
  if f then
    for _, e in ipairs(library) do
      f:write(e.name)
      for _, group_name in ipairs(e.groups) do f:write('\t', group_name) end
      f:write('\n')
    end
    f:close()
  end
  local g = io.open(DIR .. 'groups.txt', 'w')
  if g then
    for _, n in ipairs(groups) do g:write(n, '\n') end
    g:close()
  end
end

local function load_library()
  library, groups = {}, {}
  local g = io.open(DIR .. 'groups.txt', 'r')
  if g then
    for raw in g:lines() do
      local line = raw:gsub('\r', '')
      if line ~= '' and line ~= FAVORITES_GROUP then groups[#groups + 1] = line end
    end
    g:close()
  end
  local f = io.open(DIR .. 'library.txt', 'r')
  if f then
    for raw in f:lines() do
      local line = raw:gsub('\r', '')
      local name, rest = line:match('^([^\t]+)\t?(.*)$')
      if name and name ~= '' then
        local memberships = {}
        for group_name in rest:gmatch('[^\t]+') do memberships[#memberships + 1] = group_name end
        library[#library + 1] = make_entry(name, memberships)
      end
    end
    f:close()
  end
  sort_library()
end

-- local function load_installed()
--   installed, inst_list, types = {}, {}, {}
--   local seen = {}
--   local i = 0
--   while true do
--     local ok, name = r.EnumInstalledFX(i)
--     if not ok then break end
--     i = i + 1
--     local e = make_entry(name, '')
--     inst_list[#inst_list + 1] = e
--     installed[name] = true
--     if not seen[e.type] then seen[e.type] = true; types[#types + 1] = e.type end
--   end
--   table.sort(inst_list, function(a, b) return a.display:lower() < b.display:lower() end)
--   table.sort(types)
--   mfilters = { 'All', 'Instruments' }
--   for _, t in ipairs(types) do mfilters[#mfilters + 1] = t end
--   mdirty = true
-- end

local function load_installed()
  installed, inst_list, types = {}, {}, {}
  local seen = {}

  local function add_plugin(name)
    if installed[name] then return end
    local e = make_entry(name, '')
    inst_list[#inst_list + 1] = e
    installed[name] = true
    if not seen[e.type] then seen[e.type] = true; types[#types + 1] = e.type end
  end

  -- 1. Load from REAPER's standard API cache
  local i = 0
  while true do
    local ok, name = r.EnumInstalledFX(i)
    if not ok then break end
    i = i + 1
    add_plugin(name)
  end

  -- 2. Parse reaper-vstplugins64.ini directly to catch newly scanned VST/VST3s without restarting
  local ini_files = { 'reaper-vstplugins64.ini', 'reaper-vstplugins.ini' }
  for _, fname in ipairs(ini_files) do
    local f = io.open(r.GetResourcePath() .. '/' .. fname, 'r')
    if f then
      for line in f:lines() do
        line = line:gsub('\r', '')
        -- Match valid scanned entries: filename=timestamp,id,Plugin Name (Vendor)[!!!VSTi]
        local file, rest = line:match('^([^=]+)=[^,]+,[^,]+,(.+)$')
        if file and rest then
          local is_inst = rest:find('!!!VSTi', 1, true) ~= nil
          local clean_name = rest:gsub('!!!.*$', '')
          local is_vst3 = file:lower():match('%.vst3$') ~= nil
          local prefix = (is_vst3 and 'VST3' or 'VST') .. (is_inst and 'i: ' or ': ')
          add_plugin(prefix .. clean_name)
        end
      end
      f:close()
    end
  end

  table.sort(inst_list, function(a, b) return a.display:lower() < b.display:lower() end)
  table.sort(types)
  mfilters = { 'All', 'Instruments' }
  for _, t in ipairs(types) do mfilters[#mfilters + 1] = t end
  mdirty = true
end

---------------------------------------------------------------------
-- Screenshots (needs js_ReaScriptAPI)
---------------------------------------------------------------------
local cap = { queue = {}, queued = {}, state = 'idle' }

local function enqueue_capture(name, force)
  if not HAS_JS then return end
  if cap.queued[name] then return end
  if not force and r.file_exists(shot_path(name)) then return end
  cap.queue[#cap.queue + 1] = name
  cap.queued[name] = true
end

local function take_screenshot(hwnd, path)
  -- the plugin GUI is usually the biggest visible child of the floating FX window
  local target = hwnd
  local cnt, list = r.JS_Window_ListAllChild(hwnd)
  if cnt and cnt > 0 and list then
    local best, best_area = nil, 0
    for adr in list:gmatch('[^,]+') do
      local ch = r.JS_Window_HandleFromAddress(tonumber(adr))
      if ch and r.JS_Window_IsVisible(ch) then
        local _, l, t, rt, b = r.JS_Window_GetClientRect(ch)
        local a = math.abs(rt - l) * math.abs(b - t)
        if a > best_area then best, best_area = ch, a end
      end
    end
    if best then target = best end
  end

  local _, l, t, rt, b = r.JS_Window_GetClientRect(target)
  local w, h = math.abs(rt - l), math.abs(b - t)
  if w < 20 or h < 20 then return false end

  local bmp = r.JS_LICE_CreateBitmap(true, w, h)
  local dst = r.JS_LICE_GetDC(bmp)
  if cfg.cap_method == 0 then
    -- screen grab: works for GPU-rendered GUIs, window must be unobstructed
    local src = r.JS_GDI_GetScreenDC()
    r.JS_GDI_Blit(dst, 0, 0, src, l, math.min(t, b), w, h, 'SRCCOPY')
    pcall(r.JS_GDI_ReleaseDC, nil, src)
  else
    -- window DC copy: not affected by overlapping windows, may be black for GPU GUIs
    local src = r.JS_GDI_GetClientDC(target)
    r.JS_GDI_Blit(dst, 0, 0, src, 0, 0, w, h, 'SRCCOPY')
    r.JS_GDI_ReleaseDC(target, src)
  end
  local written = r.JS_LICE_WritePNG(path, bmp, false)
  r.JS_LICE_DestroyBitmap(bmp)
  return written and r.file_exists(path)
end

local function capture_step()
  if cap.state == 'idle' then
    if #cap.queue == 0 then return end
    local name = table.remove(cap.queue, 1)
    local idx = r.CountTracks(0)
    r.InsertTrackAtIndex(idx, false)
    local tr = r.GetTrack(0, idx)
    local fx = r.TrackFX_AddByName(tr, name, false, -1)
    if fx < 0 then
      r.DeleteTrack(tr)
      cap.queued[name] = nil
      set_status('Capture failed (could not load): ' .. name)
      return
    end
    r.TrackFX_Show(tr, fx, 3)
    cap.track, cap.fx, cap.name, cap.t0, cap.state = tr, fx, name, r.time_precise(), 'wait'
    local hwnd = r.TrackFX_GetFloatingWindow(tr, fx)
    if hwnd and r.JS_Window_SetZOrder then pcall(r.JS_Window_SetZOrder, hwnd, 'TOPMOST', hwnd) end
    set_status(('Capturing: %s (%d left)'):format(name, #cap.queue))
  elseif cap.state == 'wait' then
    if r.time_precise() - cap.t0 < cfg.cap_delay then return end
    local hwnd = r.TrackFX_GetFloatingWindow(cap.track, cap.fx)
    local ok = false
    if hwnd then
      local pok, res = pcall(take_screenshot, hwnd, shot_path(cap.name))
      ok = pok and res
    end
    r.TrackFX_Show(cap.track, cap.fx, 2)
    r.DeleteTrack(cap.track)
    images[cap.name] = nil
    image_sizes[cap.name] = nil
    cap.queued[cap.name] = nil
    if ok then
      set_status('Captured screenshot: ' .. cap.name)
    else
      set_status('Capture failed: ' .. cap.name)
    end
    cap.track, cap.state = nil, 'idle'
  end
end

---------------------------------------------------------------------
-- Library editing
---------------------------------------------------------------------
local function lib_add(e)
  if lib_index[e.name] then return end
  local grp = (cfg.cur_group ~= 'All') and { cfg.cur_group } or {}
  local ent = make_entry(e.name, grp)
  library[#library + 1] = ent
  lib_index[ent.name] = ent
  if cfg.auto_capture then enqueue_capture(ent.name) end
end

local function lib_remove(name)
  for i, e in ipairs(library) do
    if e.name == name then table.remove(library, i); break end
  end
  lib_index[name] = nil
  multi_selected[name] = nil
end

---------------------------------------------------------------------
-- Adding FX to the project
---------------------------------------------------------------------
local function get_targets()
  local t = {}
  if cfg.target == 0 then
    for i = 0, r.CountSelectedTracks(0) - 1 do t[#t + 1] = { track = r.GetSelectedTrack(0, i) } end
  elseif cfg.target == 1 then
    t[1] = { track = r.GetMasterTrack(0) }
  else
    for i = 0, r.CountSelectedMediaItems(0) - 1 do
      local take = r.GetActiveTake(r.GetSelectedMediaItem(0, i))
      if take then t[#t + 1] = { take = take } end
    end
  end
  return t
end

local function add_fx(e)
  local targets = get_targets()
  if #targets == 0 then
    set_status(cfg.target == 2 and 'No item with a take selected.' or 'No track selected.')
    return false
  end
  local added = 0
  r.Undo_BeginBlock()
  for _, tg in ipairs(targets) do
    local idx
    if tg.track then
      idx = r.TrackFX_AddByName(tg.track, e.name, false, -1)
      if idx >= 0 and cfg.open_ui then r.TrackFX_Show(tg.track, idx, 3) end
    else
      idx = r.TakeFX_AddByName(tg.take, e.name, -1)
      if idx >= 0 and cfg.open_ui then r.TakeFX_Show(tg.take, idx, 3) end
    end
    if idx >= 0 then added = added + 1 end
  end
  r.Undo_EndBlock('Add FX: ' .. e.display, -1)
  if added > 0 then
    set_status(('Added "%s" to %d target(s).'):format(e.display, added))
    return true
  end
  set_status('Could not add "' .. e.display .. '" (is it installed?).')
  return false
end

---------------------------------------------------------------------
-- Drag & drop onto a track (TCP / mixer / arrange lane) or its FX chain
---------------------------------------------------------------------
local function add_fx_to_track(e, tr)
  r.Undo_BeginBlock()
  local idx = r.TrackFX_AddByName(tr, e.name, false, -1)
  if idx >= 0 and cfg.open_ui then r.TrackFX_Show(tr, idx, 3) end
  r.Undo_EndBlock('Add FX: ' .. e.display, -1)
  local _, nm = r.GetTrackName(tr)
  if idx >= 0 then
    set_status(('Added "%s" to %s.'):format(e.display, nm))
    return true
  end
  set_status('Could not add "' .. e.display .. '" (is it installed?).')
  return false
end

local function track_from_fx_chain_window(x, y)
  if not HAS_JS_WINDOW or not r.TrackFX_GetChainVisible then return nil end
  local hwnd = r.JS_Window_FromPoint(x, y)
  for _ = 1, 16 do
    if not hwnd then break end
    local title = r.JS_Window_GetTitle(hwnd) or ''
    local tr
    if title:match('^FX: Master Track') then
      tr = r.GetMasterTrack(0)
    else
      local track_number = tonumber(title:match('^FX: Track (%d+)'))
      if track_number then tr = r.GetTrack(0, track_number - 1) end
    end
    if tr then
      if r.TrackFX_GetChainVisible(tr) ~= -1 then return tr end
      return nil
    end
    hwnd = r.JS_Window_GetParent(hwnd)
  end
  return nil
end

-- call once per frame; returns true when a plugin was dropped and added
local function handle_drag()
  if not drag then return false end
  local mouse_down = ImGui.IsMouseDown(ctx, 0)
  if drag.moved and r.JS_Mouse_GetState then
    -- global button state is more reliable once the cursor has left our window
    mouse_down = (r.JS_Mouse_GetState(1) & 1) == 1
  end
  if not drag.moved then
    if not mouse_down then drag = nil end
    return false
  end

  local x, y = r.GetMousePosition()
  if cfg.smooth_animations then
    local alpha = 1 - math.exp(-frame_dt / 0.035)
    drag.mx = drag.mx and (drag.mx + (x - drag.mx) * alpha) or x
    drag.my = drag.my and (drag.my + (y - drag.my) * alpha) or y
  else
    drag.mx, drag.my = x, y
  end
  local tr = track_from_fx_chain_window(x, y)
  local is_fx_chain = tr ~= nil
  if not tr then tr = r.GetTrackFromPoint(x, y) end
  if tr then
    local _, nm = r.GetTrackName(tr)
    local num = math.floor(r.GetMediaTrackInfo_Value(tr, 'IP_TRACKNUMBER') or 0)
    local label = (num > 0) and ('%d: %s'):format(num, nm) or nm
    drag.target = is_fx_chain and ('FX chain: ' .. label) or label
  else
    drag.target = nil
  end
  if mouse_down then return false end

  local e = drag.e
  drag = nil
  if tr then return add_fx_to_track(e, tr) end
  set_status(HAS_JS_WINDOW
    and 'Drag onto a track or an open track FX chain to add the plugin.'
    or 'Drag onto a track. FX-chain drops require js_ReaScriptAPI.')
  return false
end

---------------------------------------------------------------------
-- Drawing helpers
---------------------------------------------------------------------
local function get_image(e, load_limit)
  local img = images[e.name]
  if img == false then return nil end
  if img then
    if r.ImGui_ValidatePtr(img, 'ImGui_Image*') then
      local size = image_sizes[e.name]
      if size then return img, size[1], size[2] end
      local iw, ih = ImGui.Image_GetSize(img)
      image_sizes[e.name] = { iw, ih }
      return img, iw, ih
    end
    images[e.name] = nil
    image_sizes[e.name] = nil
  end
  if loads_this_frame >= (load_limit or 3) then return nil end
  local p = shot_path(e.name)
  if not r.file_exists(p) then images[e.name] = false; return nil end
  loads_this_frame = loads_this_frame + 1
  local ok, im = pcall(r.ImGui_CreateImage, p)
  if ok and im then
    if r.ImGui_Attach then pcall(r.ImGui_Attach, ctx, im) end
    images[e.name] = im
    local iw, ih = ImGui.Image_GetSize(im)
    image_sizes[e.name] = { iw, ih }
    return im, iw, ih
  end
  images[e.name] = false
  return nil
end

local function fit_text(text, maxw)
  local key = text .. '|' .. math.floor(maxw)
  local c = lbl_cache[key]
  if c then return c end
  local out = text
  if ImGui.CalcTextSize(ctx, out) > maxw then
    local n = #text
    while n > 1 do
      n = n - 1
      out = text:sub(1, n) .. '..'
      if ImGui.CalcTextSize(ctx, out) <= maxw then break end
    end
  end
  lbl_cache[key] = out
  return out
end

local function lighten(c, d)
  c = math.floor(c)
  local rr = math.min(255, ((c >> 24) & 0xFF) + d)
  local gg = math.min(255, ((c >> 16) & 0xFF) + d)
  local bb = math.min(255, ((c >> 8) & 0xFF) + d)
  return (rr << 24) | (gg << 16) | (bb << 8) | (c & 0xFF)
end

local function darken(c, d)
  c = math.floor(c)
  local rr = math.max(0, ((c >> 24) & 0xFF) - d)
  local gg = math.max(0, ((c >> 16) & 0xFF) - d)
  local bb = math.max(0, ((c >> 8) & 0xFF) - d)
  return (rr << 24) | (gg << 16) | (bb << 8) | (c & 0xFF)
end

local function terms_of(s)
  local t = {}
  for w in s:lower():gmatch('%S+') do t[#t + 1] = w end
  return t
end

local function matches_terms(lower, terms)
  for _, term in ipairs(terms) do
    if not lower:find(term, 1, true) then return false end
  end
  return true
end

local function visible_items()
  local items = {}
  local terms = terms_of(search)
  local searching = #terms > 0
  for _, e in ipairs(library) do
    local ok = (cfg.cur_group == 'All') or entry_has_group(e, cfg.cur_group)
    if searching then ok = ok and matches_terms(e.lower, terms) end
    if cfg.cur_category == 'Effects' then
      ok = ok and e.category == 'Effects'
    elseif cfg.cur_category == 'Other' then
      ok = ok and (e.category == 'Other' or e.subcategory == 'Other')
    elseif cfg.cur_category ~= 'All' then
      ok = ok and e.subcategory == cfg.cur_category
    end
    if cfg.cur_vendor ~= 'All' then
      ok = ok and e.vendor:lower() == cfg.cur_vendor:lower()
    end
    if ok then items[#items + 1] = e end
  end
  return items
end

local function set_category_filter(category)
  cfg.cur_category = category or 'All'
  sel = 1
  clear_multi_selection()
end

local function set_vendor_filter(vendor)
  cfg.cur_vendor = vendor or 'All'
  sel = 1
  clear_multi_selection()
end

local function quick_categories()
  local counts = {}
  for _, e in ipairs(library) do
    local category = e.category == 'Effects' and e.subcategory or e.category
    counts[category] = (counts[category] or 0) + 1
  end
  local categories = {}
  for category, count in pairs(counts) do
    categories[#categories + 1] = { name = category, count = count }
  end
  table.sort(categories, function(a, b)
    if a.count == b.count then return a.name:lower() < b.name:lower() end
    return a.count > b.count
  end)

  local quick, seen = {}, {}
  local limit = cfg.cur_vendor == 'All' and 4 or 3
  for i = 1, math.min(limit, #categories) do
    local category = categories[i].name
    quick[#quick + 1] = category
    seen[category] = true
  end
  if cfg.cur_category ~= 'All' and not seen[cfg.cur_category] then
    if #quick >= limit then table.remove(quick) end
    quick[#quick + 1] = cfg.cur_category
  end
  return quick
end

---------------------------------------------------------------------
-- Drag ghost: small preview that follows the cursor while dragging
---------------------------------------------------------------------
local function draw_drag_ghost()
  if not (drag and drag.moved and drag.mx) then return end
  local scale = cfg.ui_scale
  local gx, gy = drag.mx, drag.my
  if r.ImGui_PointConvertNative then
    gx, gy = r.ImGui_PointConvertNative(ctx, gx, gy, false)
  end

  local flags = ImGui.WindowFlags_NoDecoration() | ImGui.WindowFlags_AlwaysAutoResize()
    | ImGui.WindowFlags_NoSavedSettings() | ImGui.WindowFlags_NoInputs()
    | ImGui.WindowFlags_NoFocusOnAppearing() | ImGui.WindowFlags_NoNav()
  if r.ImGui_WindowFlags_TopMost then flags = flags | r.ImGui_WindowFlags_TopMost() end

  -- offset from the cursor so the preview never sits under the drop point
  ImGui.SetNextWindowPos(ctx, gx + 16 * scale, gy + 16 * scale, ImGui.Cond_Always())
  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg(), C('tile'))
  ImGui.PushStyleColor(ctx, ImGui.Col_Border(), C('tile_hl'))
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowBorderSize(), 2 * scale)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding(), 6 * scale)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding(), 6 * scale, 6 * scale)
  local visible = ImGui.Begin(ctx, '##dragghost', nil, flags)
  ImGui.PopStyleVar(ctx, 3)
  ImGui.PopStyleColor(ctx, 2)

  if visible then
    local img, w0, h0 = get_image(drag.e)
    if img then
      local sc = math.min(150 * scale / w0, 110 * scale / h0, 1)
      ImGui.Image(ctx, img, w0 * sc, h0 * sc)
    end
    ImGui.Text(ctx, fit_text(drag.e.display, 170 * scale))
    if drag.target then
      ImGui.TextColored(ctx, C('accent'), '-> ' .. fit_text(drag.target, 170 * scale))
    else
      ImGui.TextDisabled(ctx, HAS_JS_WINDOW and 'Drop on a track or FX chain'
        or 'Drop on a track (FX-chain drops need js_ReaScriptAPI)')
    end
    ImGui.End(ctx)
  end
end

---------------------------------------------------------------------
-- Library browser
---------------------------------------------------------------------
local GAP = 8
local grid_scroll_target = nil
local grid_last_scroll_y = nil
local grid_scroll_velocity = 0
local browser_scroll_reset = false

local function set_grid_tile_size(value)
  local previous_mode = cfg.view_mode
  cfg.tile_w = math.max(MIN_TILE_W, math.min(MAX_TILE_W, math.floor(value + 0.5)))
  cfg.view_mode = cfg.tile_w == MIN_TILE_W and 'List' or 'Grid'
  if cfg.view_mode ~= previous_mode then
    browser_scroll_reset = true
    if cfg.view_mode == 'List' then last_cols = 1 end
  end
end

local function set_browser_view(mode)
  if mode == 'Grid' and cfg.tile_w == MIN_TILE_W then
    set_grid_tile_size(MIN_TILE_W + 1)
  elseif cfg.view_mode ~= mode then
    cfg.view_mode = mode
    browser_scroll_reset = true
    if mode == 'List' then last_cols = 1 end
  end
end

local MODIFIER_VKEYS = {
  Ctrl = { 0x11, 0xA2, 0xA3 },
  Alt = { 0x12, 0xA4, 0xA5 },
}

local function is_modifier_down(name)
  local modifier_name = name == 'Ctrl' and 'Mod_Ctrl' or 'Mod_Alt'
  local modifier_fn = ImGui[modifier_name]
  if modifier_fn and ImGui.GetKeyMods
      and (ImGui.GetKeyMods(ctx) & modifier_fn()) ~= 0 then return true end

  for _, side in ipairs({ 'Left', 'Right' }) do
    local key_fn = r['ImGui_Key_' .. side .. name] or ImGui['Key_' .. side .. name]
    if key_fn and ImGui.IsKeyDown(ctx, key_fn()) then return true end
  end
  if r.JS_VKeys_GetState then
    local state = r.JS_VKeys_GetState(0)
    if type(state) == 'string' then
      for _, key_code in ipairs(MODIFIER_VKEYS[name] or {}) do
        if (state:byte(key_code) or 0) ~= 0 then return true end
      end
    end
  end
  return false
end

local function is_ctrl_down() return is_modifier_down('Ctrl') end

local function queue_screenshots(entries)
  if not HAS_JS then
    set_status('Screenshot capture requires js_ReaScriptAPI.')
    return
  end
  local names, seen = {}, {}
  for _, entry in ipairs(entries) do
    if not seen[entry.name] then
      names[#names + 1] = entry.name
      seen[entry.name] = true
    end
  end
  local queued_count = 0
  for _, name in ipairs(names) do
    if not cap.queued[name] then queued_count = queued_count + 1 end
    enqueue_capture(name, true)
  end
  if queued_count > 0 then
    set_status(('Queued screenshots for %d plugin(s).'):format(queued_count))
  else
    set_status('Screenshot capture is already queued.')
  end
end

local function browser_mode_button(mode)
  local active = cfg.view_mode == mode
  local scale = cfg.ui_scale
  local size = 28 * scale
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local clicked = ImGui.InvisibleButton(ctx, '##browser_mode_' .. mode, size, size)
  local hovered = ImGui.IsItemHovered(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local bg = active and darken(C('button_active'), 18)
    or (hovered and darken(C('button_hover'), 18) or darken(C('button'), 18))
  local fg = active and C('accent') or C('text')
  ImGui.DrawList_AddRectFilled(dl, x, y, x + size, y + size, bg, 5 * scale)
  if mode == 'Grid' then
    local cell, gap = 5 * scale, 3 * scale
    local left, top = x + (size - 2 * cell - gap) / 2, y + (size - 2 * cell - gap) / 2
    for row = 0, 1 do
      for col = 0, 1 do
        local cx, cy = left + col * (cell + gap), top + row * (cell + gap)
        ImGui.DrawList_AddRectFilled(dl, cx, cy, cx + cell, cy + cell, fg, 1 * scale)
      end
    end
  else
    for row = 0, 2 do
      local ly = y + size * (0.3 + row * 0.2)
      ImGui.DrawList_AddCircleFilled(dl, x + size * 0.27, ly, 1.5 * scale, fg, 8)
      ImGui.DrawList_AddLine(dl, x + size * 0.42, ly, x + size * 0.74, ly, fg, 1.8 * scale)
    end
  end
  if clicked then set_browser_view(mode) end
end

local function grid_size_slider()
  local scale = cfg.ui_scale
  local width, height = 180 * scale, 28 * scale
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local clicked = ImGui.InvisibleButton(ctx, '##grid_size', width, height)
  local hovered = ImGui.IsItemHovered(ctx)
  local active = ImGui.IsItemActive(ctx)
  local left, right = x + 10 * scale, x + width - 10 * scale
  local center_y = y + height / 2
  local ratio = (cfg.tile_w - MIN_TILE_W) / (MAX_TILE_W - MIN_TILE_W)

  if clicked or active then
    local mouse_x = ImGui.GetMousePos(ctx)
    ratio = math.max(0, math.min(1, (mouse_x - left) / (right - left)))
    set_grid_tile_size(MIN_TILE_W + ratio * (MAX_TILE_W - MIN_TILE_W))
    ratio = (cfg.tile_w - MIN_TILE_W) / (MAX_TILE_W - MIN_TILE_W)
  end

  local knob_x = left + ratio * (right - left)
  local dl = ImGui.GetWindowDrawList(ctx)
  local track_height = 4 * scale
  ImGui.DrawList_AddRectFilled(
    dl, left, center_y - track_height / 2, right, center_y + track_height / 2,
    C('button'), track_height / 2)
  if ratio > 0 then
    ImGui.DrawList_AddRectFilled(
      dl, left, center_y - track_height / 2, knob_x, center_y + track_height / 2,
      C('accent'), track_height / 2)
  end
  if hovered or active then
    ImGui.DrawList_AddCircleFilled(dl, knob_x, center_y, 10 * scale, (C('accent') & 0xFFFFFF00) | 0x30, 24)
  end
  ImGui.DrawList_AddCircleFilled(dl, knob_x, center_y, 6 * scale, C('accent'), 24)
end

local function filter_icon_button()
  local scale = cfg.ui_scale
  local size = 28 * scale
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local clicked = ImGui.InvisibleButton(ctx, '##filter_options', size, size)
  local hovered = ImGui.IsItemHovered(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local active = cfg.cur_category ~= 'All' or cfg.cur_vendor ~= 'All'
  local bg = active and C('accent') or (hovered and C('button_hover') or C('button'))
  ImGui.DrawList_AddRectFilled(dl, x, y, x + size, y + size, bg, 6 * scale)
  local icon = active and C('window_bg') or C('text_dim')
  ImGui.DrawList_AddLine(dl, x + 7 * scale, y + 8 * scale, x + 21 * scale, y + 8 * scale, icon, 1.6 * scale)
  ImGui.DrawList_AddLine(dl, x + 9 * scale, y + 13 * scale, x + 19 * scale, y + 13 * scale, icon, 1.6 * scale)
  ImGui.DrawList_AddLine(dl, x + 11 * scale, y + 18 * scale, x + 17 * scale, y + 18 * scale, icon, 1.6 * scale)
  ImGui.DrawList_AddLine(dl, x + 14 * scale, y + 18 * scale, x + 14 * scale, y + 21 * scale, icon, 1.6 * scale)
  if hovered then ImGui.SetTooltip(ctx, 'Category and vendor filters') end
  return clicked
end

local function filter_chip(id, label, selected)
  local scale = cfg.ui_scale
  local text_w, text_h = ImGui.CalcTextSize(ctx, label)
  local width, height = text_w + 18 * scale, 26 * scale
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local clicked = ImGui.InvisibleButton(ctx, '##filter_chip_' .. id, width, height)
  local hovered = ImGui.IsItemHovered(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local bg = selected and C('accent') or (hovered and C('button_hover') or C('control_bg'))
  local fg = selected and C('window_bg') or C('text')
  local border = selected and C('accent') or C('separator')
  ImGui.DrawList_AddRectFilled(dl, x, y, x + width, y + height, bg, height / 2)
  ImGui.DrawList_AddRect(dl, x, y, x + width, y + height, border, height / 2, 0, scale)
  ImGui.DrawList_AddText(dl, x + 9 * scale, y + (height - text_h) / 2, fg, label)
  return clicked
end

local function filter_options(filters, placeholder)
  local options, values = { placeholder }, { 'All' }
  for i = 2, #filters do
    options[#options + 1] = filters[i]
    values[#values + 1] = filters[i]
  end
  return options, values
end

local function draw_filter_toolbar()
  if filter_icon_button() then ImGui.OpenPopup(ctx, 'Browser filters') end
  if ImGui.BeginPopup(ctx, 'Browser filters') then
    local category_options, category_values = filter_options(CATEGORY_FILTERS, 'Category')
    local category_index = 0
    for i, value in ipairs(category_values) do
      if value == cfg.cur_category then category_index = i - 1; break end
    end
    ImGui.SetNextItemWidth(ctx, 230 * cfg.ui_scale)
    local category_changed, new_category = ImGui.Combo(
      ctx, '##filter_category', category_index, table.concat(category_options, '\0') .. '\0')
    if category_changed then set_category_filter(category_values[new_category + 1]) end

    local vendor_options, vendor_values = filter_options(VENDOR_FILTERS, 'Vendor')
    local vendor_index = 0
    for i, value in ipairs(vendor_values) do
      if value:lower() == cfg.cur_vendor:lower() then vendor_index = i - 1; break end
    end
    ImGui.SetNextItemWidth(ctx, 230 * cfg.ui_scale)
    local vendor_changed, new_vendor = ImGui.Combo(
      ctx, '##filter_vendor', vendor_index, table.concat(vendor_options, '\0') .. '\0')
    if vendor_changed then set_vendor_filter(vendor_values[new_vendor + 1]) end

    if ImGui.Button(ctx, 'Clear filters') then
      set_category_filter('All')
      set_vendor_filter('All')
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.EndPopup(ctx)
  end

  for _, category in ipairs(quick_categories()) do
    ImGui.SameLine(ctx)
    if filter_chip('category_' .. category, category, cfg.cur_category == category) then
      set_category_filter(cfg.cur_category == category and 'All' or category)
    end
  end
  if cfg.cur_vendor ~= 'All' then
    ImGui.SameLine(ctx)
    local label = fit_text('Vendor: ' .. cfg.cur_vendor, 140 * cfg.ui_scale)
    if filter_chip('active_vendor', label, true) then
      set_vendor_filter('All')
    end
  end
end

local function draw_browser(items, deferred, kb_moved, lightweight, random_moved)
  local want
  local scale = cfg.ui_scale
  local wheel_y = ImGui.GetMouseWheel(ctx)
  local browser_hovered = ImGui.IsWindowHovered(ctx)
  local ctrl_zoom = wheel_y ~= 0 and browser_hovered and is_ctrl_down()
  if ctrl_zoom then
    local previous_scroll = grid_last_scroll_y or ImGui.GetScrollY(ctx)
    set_grid_tile_size(cfg.tile_w + wheel_y * 20)
    grid_scroll_target = nil
    grid_scroll_velocity = 0
    if not browser_scroll_reset then ImGui.SetScrollY(ctx, previous_scroll) end
  end
  local gap = GAP * scale
  local avail_w = math.max(1, ImGui.GetContentRegionAvail(ctx) - 2 * scale)
  local list_mode = cfg.view_mode == 'List'
  local min_tile_w = math.max(1, cfg.tile_w * scale)
  local cols = list_mode and 1 or math.max(1, math.floor((avail_w + gap) / (min_tile_w + gap)))
  last_cols = cols
  local tw = list_mode and math.floor(avail_w)
    or math.max(1, math.floor((avail_w - (cols - 1) * gap) / cols))
  local label_h = not list_mode and cfg.show_names
    and (2 * ImGui.GetTextLineHeight(ctx) + 10 * scale) or 0
  local th
  if list_mode then
    th = math.max(64 * scale, 2 * ImGui.GetTextLineHeight(ctx) + 10 * scale)
  else
    th = math.max(label_h + 1, math.floor(tw * cfg.aspect) + label_h)
  end
  local ah = th - label_h

  local tile_col = C('tile')
  local tile_hover = C('tile_hover')
  local accent = C('tile_hl')

  if #library == 0 then
    ImGui.TextDisabled(ctx, 'Your library is empty.')
    ImGui.TextDisabled(ctx, 'Click "Add plugins" and pick the ones you actually use.')
    return nil
  elseif #items == 0 then
    ImGui.TextDisabled(ctx, 'No plugins here yet (or no matches).')
    return nil
  end

  if browser_scroll_reset then
    ImGui.SetScrollY(ctx, 0)
    grid_scroll_target = nil
    grid_scroll_velocity = 0
    grid_last_scroll_y = 0
    browser_scroll_reset = false
  end

  if cfg.smooth_animations then
    local scroll = ImGui.GetScrollY(ctx)
    if wheel_y ~= 0 and browser_hovered and not ctrl_zoom then
      local previous = grid_last_scroll_y or scroll
      scroll = previous
      ImGui.SetScrollY(ctx, scroll)
      grid_scroll_target = nil
      grid_scroll_velocity = grid_scroll_velocity - wheel_y * 1300
    end
    if grid_scroll_velocity ~= 0 then
      local decay = math.exp(-8 * frame_dt)
      local distance = grid_scroll_velocity * (1 - decay) / 8
      local next_scroll = scroll + distance
      local max_scroll = ImGui.GetScrollMaxY(ctx)
      next_scroll = math.max(0, math.min(next_scroll, max_scroll))
      ImGui.SetScrollY(ctx, next_scroll)
      scroll = next_scroll
      if next_scroll == 0 or next_scroll == max_scroll then
        grid_scroll_velocity = 0
      else
        grid_scroll_velocity = grid_scroll_velocity * decay
        if math.abs(grid_scroll_velocity) < 2 then grid_scroll_velocity = 0 end
      end
    end
  else
    grid_scroll_target = nil
    grid_scroll_velocity = 0
  end

  local _, content_top = ImGui.GetCursorScreenPos(ctx)
  local _, viewport_h = ImGui.GetContentRegionAvail(ctx)
  local scroll = ImGui.GetScrollY(ctx)
  local _, item_spacing_y = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing())
  local row_step = th + item_spacing_y
  local row_count = math.ceil(#items / cols)

  if kb_moved and items[sel] then
    local selected_row = math.floor((sel - 1) / cols)
    local selected_y = content_top + selected_row * row_step
    local viewport_top = content_top + scroll
    local viewport_bottom = viewport_top + viewport_h
    local target = scroll
    if selected_y < viewport_top then
      target = scroll + selected_y - viewport_top
    elseif selected_y + th > viewport_bottom then
      target = scroll + selected_y + th - viewport_bottom
    end
    target = math.max(0, math.min(target, ImGui.GetScrollMaxY(ctx)))
    if random_moved then
      grid_scroll_velocity = 0
      grid_scroll_target = nil
      ImGui.SetScrollY(ctx, target)
    elseif cfg.smooth_animations then
      grid_scroll_velocity = 0
      grid_scroll_target = target
    else
      grid_scroll_target = nil
      ImGui.SetScrollY(ctx, target)
    end
  end

  if cfg.smooth_animations and grid_scroll_target then
    scroll = ImGui.GetScrollY(ctx)
    local next_scroll = scroll + (grid_scroll_target - scroll) * (1 - math.exp(-frame_dt / 0.15))
    if math.abs(grid_scroll_target - next_scroll) < 0.5 then
      next_scroll = grid_scroll_target
      grid_scroll_target = nil
    end
    ImGui.SetScrollY(ctx, next_scroll)
  end

  scroll = ImGui.GetScrollY(ctx)
  local first_row = math.max(0, math.floor(scroll / row_step) - 1)
  local last_row = math.min(row_count - 1, math.floor((scroll + viewport_h) / row_step) + 1)
  local first_item = first_row * cols + 1
  local last_item = math.min(#items, (last_row + 1) * cols)
  if first_item > 1 then
    ImGui.Dummy(ctx, 1, math.max(0, first_row * row_step - item_spacing_y))
  end
  local dl = ImGui.GetWindowDrawList(ctx)

  for i = first_item, last_item do
    local e = items[i]
    if (i - 1) % cols ~= 0 then ImGui.SameLine(ctx, 0, gap) end
    local x, y = ImGui.GetCursorScreenPos(ctx)
    ImGui.InvisibleButton(ctx, '##tile' .. i, tw, th)
    local hovered = ImGui.IsItemHovered(ctx)

    ImGui.DrawList_AddRectFilled(dl, x, y, x + tw, y + th, hovered and tile_hover or tile_col, 6 * scale)

    local image_load_limit = lightweight and 1 or 3
    if drag and drag.e == e then image_load_limit = 3 end
    local img, iw, ih = get_image(e, image_load_limit)
    if img then
      local pad = 4 * scale
      local image_area_w = list_mode and math.min(48 * scale, th - 2 * pad) or tw - 2 * pad
      local image_area_h = list_mode and image_area_w or ah - 2 * pad
      local s = math.min(image_area_w / iw, image_area_h / ih)
      local dw, dh = iw * s, ih * s
      local ix = list_mode and (x + 8 * scale + (image_area_w - dw) / 2) or (x + (tw - dw) / 2)
      local iy = y + (ah - dh) / 2
      ImGui.DrawList_AddImage(dl, img, ix, iy, ix + dw, iy + dh)
    elseif not lightweight then
      if list_mode then
        local box = math.min(48 * scale, th - 8 * scale)
        local bx, by = x + 8 * scale, y + (th - box) / 2
        ImGui.DrawList_AddRectFilled(dl, bx, by, bx + box, by + box, tile_hover, 4 * scale)
        local kind = fit_text(e.type or '', box - 4 * scale)
        local w1, h1 = ImGui.CalcTextSize(ctx, kind)
        ImGui.DrawList_AddText(dl, bx + (box - w1) / 2, by + (box - h1) / 2, C('tile_placeholder'), kind)
      else
        local dn = fit_text(e.display, tw - 14 * scale)
        local w1, h1 = ImGui.CalcTextSize(ctx, dn)
        ImGui.DrawList_AddText(dl, x + (tw - w1) / 2, y + ah / 2 - h1 / 2, C('tile_placeholder'), dn)
      end
    end

    if list_mode then
      local text_x = x + 64 * scale
      local text_w = math.max(1, tw - 74 * scale)
      local name = fit_text(e.display, text_w)
      local _, name_h = ImGui.CalcTextSize(ctx, name)
      local category = (e.category == 'Effects') and ('Effects / ' .. (e.subcategory or '')) or (e.category or '')
      local detail = (e.type or '') .. '  |  ' .. category .. '  |  ' .. e.vendor
      local group_text = table.concat(e.groups, ', ')
      if group_text ~= '' then detail = detail .. '  |  ' .. group_text end
      detail = fit_text(detail, text_w)
      local _, detail_h = ImGui.CalcTextSize(ctx, detail)
      local block_h = name_h + detail_h + 2 * scale
      local name_y = y + (th - block_h) / 2
      local name_col = installed[e.name] and C('tile_text') or C('tile_missing')
      ImGui.DrawList_AddText(dl, text_x, name_y, name_col, name)
      ImGui.DrawList_AddText(dl, text_x, name_y + name_h + 2 * scale, C('text_dim'), detail)
    elseif cfg.show_names then
      local t = fit_text(e.display, tw - 10 * scale)
      local lw, lh = ImGui.CalcTextSize(ctx, t)
      local col = installed[e.name] and C('tile_text') or C('tile_missing')
      local name_y = y + ah + 2 * scale
      ImGui.DrawList_AddText(dl, x + (tw - lw) / 2, name_y, col, t)
      local vendor = fit_text(e.vendor, tw - 10 * scale)
      local vw = ImGui.CalcTextSize(ctx, vendor)
      ImGui.DrawList_AddText(
        dl, x + (tw - vw) / 2, name_y + lh + 2 * scale, C('text_dim'), vendor)
    end

    if drag and drag.moved and drag.e == e then
      ImGui.DrawList_AddRectFilled(dl, x, y, x + tw, y + th, C('drag_dim'), 6)
    end

    if hovered or i == sel or multi_selected[e.name] then
      ImGui.DrawList_AddRect(dl, x, y, x + tw, y + th, accent, 6 * scale, 0, 2 * scale)
    end
    if multi_selected[e.name] then
      local bx, by = x + tw - 19 * scale, y + 4 * scale
      ImGui.DrawList_AddRectFilled(dl, bx, by, bx + 15 * scale, by + 15 * scale, C('accent'), 3 * scale)
      ImGui.DrawList_AddLine(dl, bx + 3 * scale, by + 7 * scale, bx + 6 * scale, by + 10 * scale, C('window_bg'), 1.5 * scale)
      ImGui.DrawList_AddLine(dl, bx + 6 * scale, by + 10 * scale, bx + 12 * scale, by + 4 * scale, C('window_bg'), 1.5 * scale)
    end
    if hovered and not (drag and drag.moved) then
      ImGui.SetTooltip(ctx, e.name)
    end
    local item_activated = ImGui.IsItemActivated(ctx)
    if item_activated then
      local ctrl_down = is_ctrl_down()
      if ctrl_down then
        toggle_multi_selection(e.name)
      else
        clear_multi_selection()
      end
      drag = {
        e = e, moved = false, select_only = ctrl_down,
        double_clicked = not ctrl_down and ImGui.IsMouseDoubleClicked(ctx, 0),
      }
      sel = i
    end
    if drag and drag.e == e and not drag.select_only and not drag.moved and ImGui.IsItemActive(ctx)
       and ImGui.IsMouseDragging(ctx, 0, 6) then
      drag.moved = true
    end
    -- Require a deliberate double-click to add a tile.
    if ImGui.IsItemDeactivated(ctx) and drag and drag.e == e and not drag.moved
       and hovered and drag.double_clicked then
      want = e
    end

    if ImGui.BeginPopupContextItem(ctx) then
      if ImGui.MenuItem(ctx, 'Add to project') then want = e end
      if ImGui.MenuItem(ctx, 'Rename plugin...') then
        rename_plugin_name = e.name
        local override = metadata_overrides[e.name]
        rename_plugin_value = override and override.display or e.display
        rename_plugin_requested = true
      end
      if ImGui.MenuItem(ctx, 'Edit category and vendor...') then
        local override = metadata_overrides[e.name]
        metadata_edit_name = e.name
        metadata_edit_category = override and override.category or 'Automatic'
        metadata_edit_vendor = e.vendor
        metadata_edit_requested = true
      end
      local capture_targets = multi_selected[e.name] and get_multi_selected_entries() or { e }
      local capture_label = #capture_targets > 1
        and ('Capture selected screenshots (' .. #capture_targets .. ')') or 'Capture screenshot'
      if HAS_JS and ImGui.MenuItem(ctx, capture_label) then
        deferred[#deferred + 1] = function()
          queue_screenshots(capture_targets)
        end
      end
      local group_targets = multi_selected[e.name] and get_multi_selected_entries() or { e }
      local group_label = #group_targets > 1
        and ('Groups for selected (' .. #group_targets .. ')') or 'Groups'
      if ImGui.BeginMenu(ctx, group_label) then
        if ImGui.MenuItem(ctx, 'Clear all groups') then
          deferred[#deferred + 1] = function()
            for _, target in ipairs(group_targets) do target.groups = {} end
            save_library()
          end
        end
        local group_names = { FAVORITES_GROUP }
        for _, gname in ipairs(groups) do group_names[#group_names + 1] = gname end
        for _, gname in ipairs(group_names) do
          local all_have, any_have = true, false
          for _, target in ipairs(group_targets) do
            local has_group = entry_has_group(target, gname)
            if has_group then any_have = true else all_have = false end
          end
          local item_label = (any_have and not all_have) and (gname .. ' (some)') or gname
          if ImGui.MenuItem(ctx, item_label, nil, all_have) then
            local add_group, target_group = not all_have, gname
            deferred[#deferred + 1] = function()
              for _, target in ipairs(group_targets) do
                if add_group then add_entry_group(target, target_group)
                else remove_entry_group(target, target_group) end
              end
              save_library()
            end
          end
        end
        ImGui.EndMenu(ctx)
      end
      if ImGui.MenuItem(ctx, 'Remove from library') then
        deferred[#deferred + 1] = function() lib_remove(e.name); save_library() end
      end
      ImGui.EndPopup(ctx)
    end
  end
  local remaining_rows = row_count - last_row - 1
  if remaining_rows > 0 then
    ImGui.Dummy(ctx, 1, math.max(0, remaining_rows * row_step - item_spacing_y))
  end
  grid_last_scroll_y = ImGui.GetScrollY(ctx)
  return want
end

---------------------------------------------------------------------
-- Manage view (choose which plugins are in the library)
---------------------------------------------------------------------
local function refilter_manage()
  mfiltered = {}
  local terms = terms_of(msearch)
  for _, e in ipairs(inst_list) do
    local ok = true
    if mfilter == 'Instruments' then ok = e.inst
    elseif mfilter ~= 'All' then ok = (e.type == mfilter) end
    if ok and matches_terms(e.lower, terms) then mfiltered[#mfiltered + 1] = e end
  end
  mdirty = false
end

local function draw_manage()
  if ImGui.Button(ctx, '< Back') then view = 'grid'; focus_search = true end
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, 'Click a plugin to add it to / remove it from your library.')

  ImGui.SetNextItemWidth(ctx, -170 * cfg.ui_scale)
  local ch, txt = ImGui.InputTextWithHint(ctx, '##msearch', 'Search installed plugins...', msearch)
  if ch then msearch = txt; mdirty = true end
  ImGui.SameLine(ctx)
  local fidx = 0
  for i, f in ipairs(mfilters) do if f == mfilter then fidx = i - 1 end end
  ImGui.SetNextItemWidth(ctx, 150 * cfg.ui_scale)
  local fch, nidx = ImGui.Combo(ctx, '##mfilter', fidx, table.concat(mfilters, '\0') .. '\0')
  if fch then mfilter = mfilters[nidx + 1]; mdirty = true end

  if mdirty then refilter_manage() end

  if ImGui.Button(ctx, 'Add all shown') then
    for _, e in ipairs(mfiltered) do lib_add(e) end
    sort_library(); save_library()
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Remove all shown') then
    for _, e in ipairs(mfiltered) do lib_remove(e.name) end
    sort_library(); save_library()
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Rescan') then
    r.Main_OnCommand(41070, 0) -- Scan for new plugins
    load_installed()
  end
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, ('%d shown / %d installed / %d in library'):format(#mfiltered, #inst_list, #library))

  if ImGui.BeginChild(ctx, '##mlist', 0, 0) then
    -- manual row culling (only draw rows that are on screen), padded with spacers
    local ok, err = pcall(function()
      local lh = ImGui.GetTextLineHeightWithSpacing(ctx)
      local sp = lh - ImGui.GetTextLineHeight(ctx)
      local scroll = ImGui.GetScrollY(ctx)
      local view_h = ImGui.GetWindowHeight(ctx)
      local total = #mfiltered
      local first = math.max(1, math.floor(scroll / lh))
      local last = math.min(total, math.ceil((scroll + view_h) / lh) + 1)
      if first > 1 then ImGui.Dummy(ctx, 1, (first - 1) * lh - sp) end
      for i = first, last do
        local e = mfiltered[i]
        local inlib = lib_index[e.name] ~= nil
        if inlib then ImGui.PushStyleColor(ctx, ImGui.Col_Text(), C('list_in')) end
        local label = ('%s  %s   [%s%s]##m%d'):format(inlib and '[x]' or '[ ]', e.display, e.type, e.inst and 'i' or '', i)
        local clicked = ImGui.Selectable(ctx, label, false)
        if inlib then ImGui.PopStyleColor(ctx) end
        if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, e.name) end
        if clicked then
          if inlib then lib_remove(e.name) else lib_add(e) end
          sort_library(); save_library()
        end
      end
      if last < total then ImGui.Dummy(ctx, 1, (total - last) * lh - sp) end
    end)
    ImGui.EndChild(ctx)
    if not ok and err ~= last_err then
      last_err = err
      r.ShowConsoleMsg('Visual Plugin Picker (manage list): ' .. tostring(err) .. '\n')
    end
  end
end

local function draw_metadata_editor()
  if metadata_edit_requested then
    ImGui.OpenPopup(ctx, 'Edit category and vendor')
    metadata_edit_requested = false
  end
  if not metadata_edit_name then return end

  local visible, open = ImGui.BeginPopupModal(
    ctx, 'Edit category and vendor', true, ImGui.WindowFlags_AlwaysAutoResize())
  if not open then metadata_edit_name = nil end
  if not visible then return end
  if not open then
    ImGui.EndPopup(ctx)
    return
  end

  local entry = lib_index[metadata_edit_name]
  if entry then
    ImGui.TextWrapped(ctx, entry.name)
    ImGui.Separator(ctx)
    local entry_type, detected_display = parse_name(entry.name)
    local detected_vendor = classify_vendor(detected_display, entry_type)

    local category_index = 0
    for i, category in ipairs(CATEGORY_EDIT_OPTIONS) do
      if category == metadata_edit_category then category_index = i - 1; break end
    end
    ImGui.SetNextItemWidth(ctx, 250 * cfg.ui_scale)
    local category_changed, new_category = ImGui.Combo(
      ctx, 'Category', category_index, table.concat(CATEGORY_EDIT_OPTIONS, '\0') .. '\0')
    if category_changed then metadata_edit_category = CATEGORY_EDIT_OPTIONS[new_category + 1] or 'Automatic' end

    ImGui.SetNextItemWidth(ctx, 250 * cfg.ui_scale)
    local vendor_changed, new_vendor = ImGui.InputTextWithHint(
      ctx, 'Vendor', 'Blank uses the detected vendor', metadata_edit_vendor)
    if vendor_changed then metadata_edit_vendor = new_vendor end
    ImGui.TextDisabled(ctx, 'Detected vendor: ' .. detected_vendor)
    if ImGui.Button(ctx, 'Use detected') then
      metadata_edit_vendor = detected_vendor
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'Save') and update_plugin_metadata(
      metadata_edit_name, metadata_edit_category, metadata_edit_vendor) then
      metadata_edit_name = nil
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'Cancel') then
      metadata_edit_name = nil
      ImGui.CloseCurrentPopup(ctx)
    end
  else
    ImGui.TextDisabled(ctx, 'This plugin is no longer in the library.')
    if ImGui.Button(ctx, 'Close') then
      metadata_edit_name = nil
      ImGui.CloseCurrentPopup(ctx)
    end
  end

  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape()) then
    metadata_edit_name = nil
    ImGui.CloseCurrentPopup(ctx)
  end
  ImGui.EndPopup(ctx)
end

local function draw_rename_plugin_editor()
  if rename_plugin_requested then
    ImGui.OpenPopup(ctx, 'Rename plugin')
    rename_plugin_requested = false
  end
  if not rename_plugin_name then return end

  local visible, open = ImGui.BeginPopupModal(
    ctx, 'Rename plugin', true, ImGui.WindowFlags_AlwaysAutoResize())
  if not open then rename_plugin_name = nil end
  if not visible then return end
  if not open then
    ImGui.EndPopup(ctx)
    return
  end

  local entry = lib_index[rename_plugin_name]
  if entry then
    ImGui.TextWrapped(ctx, 'Original name: ' .. entry.name)
    ImGui.SetNextItemWidth(ctx, 300 * cfg.ui_scale)
    local changed, value = ImGui.InputTextWithHint(
      ctx, '##plugin_display_name', 'Blank restores the detected name', rename_plugin_value)
    if changed then rename_plugin_value = value end
    ImGui.TextDisabled(ctx, 'This changes only the name shown in the picker.')

    local save = ImGui.Button(ctx, 'Save')
      or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter())
      or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter())
    if save then
      local override = metadata_overrides[rename_plugin_name]
      local category = override and override.category or 'Automatic'
      local vendor = override and override.vendor or entry.vendor
      if update_plugin_metadata(rename_plugin_name, category, vendor, rename_plugin_value) then
        rename_plugin_name = nil
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'Cancel') then
      rename_plugin_name = nil
      ImGui.CloseCurrentPopup(ctx)
    end
  else
    ImGui.TextDisabled(ctx, 'This plugin is no longer in the library.')
    if ImGui.Button(ctx, 'Close') then
      rename_plugin_name = nil
      ImGui.CloseCurrentPopup(ctx)
    end
  end

  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape()) then
    rename_plugin_name = nil
    ImGui.CloseCurrentPopup(ctx)
  end
  ImGui.EndPopup(ctx)
end

---------------------------------------------------------------------
-- Settings popup
---------------------------------------------------------------------
local function draw_settings()
  if not ImGui.BeginPopup(ctx, 'Settings') then return end
  ImGui.SeparatorText(ctx, 'Layout')
  ImGui.SetNextItemWidth(ctx, 220 * cfg.ui_scale)
  local c, v = ImGui.SliderDouble(ctx, 'UI scale', cfg.ui_scale, 0.75, 1.75, '%.2fx')
  if c then cfg.ui_scale = v end
  ImGui.SetNextItemWidth(ctx, 220 * cfg.ui_scale)
  c, v = ImGui.SliderInt(ctx, 'Background opacity', cfg.bg_opacity, 70, 100, '%d%%')
  if c then cfg.bg_opacity = v end
  ImGui.SetNextItemWidth(ctx, 220 * cfg.ui_scale)
  c, v = ImGui.SliderDouble(ctx, 'Tile height ratio', cfg.aspect, 0.4, 1.5, '%.2f')
  if c then cfg.aspect = v end
  c, v = ImGui.Checkbox(ctx, 'Show plugin names', cfg.show_names)
  if c then cfg.show_names = v end

  ImGui.SeparatorText(ctx, 'Colors')
  if ImGui.Button(ctx, 'Customize colors...') then show_colors = true end

  ImGui.SeparatorText(ctx, 'Behavior')
  c, v = ImGui.Checkbox(ctx, 'Smooth animations', cfg.smooth_animations)
  if c then
    cfg.smooth_animations = v
    grid_scroll_target = nil
    grid_scroll_velocity = 0
  end
  c, v = ImGui.Checkbox(ctx, 'Close after adding', cfg.close_after)
  if c then cfg.close_after = v end
  c, v = ImGui.Checkbox(ctx, 'Open FX window after adding', cfg.open_ui)
  if c then cfg.open_ui = v end

  ImGui.SeparatorText(ctx, 'Screenshots')
  if not HAS_JS then
    ImGui.TextWrapped(ctx, 'Capture needs the js_ReaScriptAPI extension (ReaPack). You can also drop your own PNGs into:')
    ImGui.TextDisabled(ctx, SHOT_DIR)
  else
    c, v = ImGui.Checkbox(ctx, 'Auto-capture when adding to library', cfg.auto_capture)
    if c then cfg.auto_capture = v end
    ImGui.SetNextItemWidth(ctx, 220 * cfg.ui_scale)
    c, v = ImGui.SliderDouble(ctx, 'Wait before capture (s)', cfg.cap_delay, 0.3, 8, '%.1f')
    if c then cfg.cap_delay = v end
    ImGui.SetNextItemWidth(ctx, 220 * cfg.ui_scale)
    c, v = ImGui.Combo(ctx, 'Method', math.floor(cfg.cap_method), 'Screen grab\0Window copy\0')
    if c then cfg.cap_method = v end
    if ImGui.Button(ctx, 'Capture all missing') then
      for _, e in ipairs(library) do enqueue_capture(e.name) end
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'Re-capture all') then
      for _, e in ipairs(library) do enqueue_capture(e.name, true) end
    end
    ImGui.TextDisabled(ctx, 'Capture briefly opens each plugin on a temporary track.')
  end
  if ImGui.Button(ctx, 'Reload images') then images = {}; image_sizes = {} end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Reset settings') then
    local keep_w, keep_h = cfg.win_w, cfg.win_h
    for k, d in pairs(DEFAULTS) do cfg[k] = d end
    hex_edit = {}
    cfg.win_w, cfg.win_h = keep_w, keep_h
  end
  ImGui.EndPopup(ctx)
end

---------------------------------------------------------------------
-- Theme (applies the configurable colors to every ImGui widget)
---------------------------------------------------------------------
local THEME = {
  { 'Col_WindowBg', 'window_bg' }, { 'Col_ChildBg', 'panel_bg' }, { 'Col_PopupBg', 'panel_bg' },
  { 'Col_Border', 'separator' }, { 'Col_Separator', 'separator' },
  { 'Col_TitleBg', 'title_bg' }, { 'Col_TitleBgActive', 'title_bg_active' }, { 'Col_TitleBgCollapsed', 'title_bg' },
  { 'Col_Text', 'text' }, { 'Col_TextDisabled', 'text_dim' },
  { 'Col_Button', 'button' }, { 'Col_ButtonHovered', 'button_hover' }, { 'Col_ButtonActive', 'button_active' },
  { 'Col_FrameBg', 'control_bg' }, { 'Col_FrameBgHovered', 'control_hover' }, { 'Col_FrameBgActive', 'control_active' },
  { 'Col_ScrollbarBg', 'scroll_track' }, { 'Col_ScrollbarGrab', 'scroll_grab' },
  { 'Col_ScrollbarGrabHovered', 'scroll_hover' }, { 'Col_ScrollbarGrabActive', 'scroll_active' },
  { 'Col_Header', 'row_selected' }, { 'Col_HeaderHovered', 'row_hover' }, { 'Col_HeaderActive', 'row_pressed' },
  { 'Col_Tab', 'tab' }, { 'Col_TabHovered', 'tab_hover' },
  { 'Col_TabActive', 'tab_active' }, { 'Col_TabSelected', 'tab_active' },
  { 'Col_TabUnfocused', 'tab' }, { 'Col_TabUnfocusedActive', 'tab_active' },
  { 'Col_TabDimmed', 'tab' }, { 'Col_TabDimmedSelected', 'tab_active' },
  { 'Col_CheckMark', 'accent' }, { 'Col_SliderGrab', 'accent' }, { 'Col_SliderGrabActive', 'accent' },
  { 'Col_ResizeGrip', 'scroll_grab' }, { 'Col_ResizeGripHovered', 'scroll_hover' }, { 'Col_ResizeGripActive', 'scroll_active' },
}
local theme_fns = nil
local UI_SCALE_STYLE_VARS = {
  { 'WindowPadding', true }, { 'FramePadding', true },
  { 'ItemSpacing', true }, { 'ItemInnerSpacing', true },
  { 'IndentSpacing', false }, { 'ScrollbarSize', false }, { 'GrabMinSize', false },
  { 'WindowRounding', false }, { 'ChildRounding', false }, { 'FrameRounding', false },
  { 'PopupRounding', false }, { 'TabRounding', false },
}

local function push_theme()
  local scale_n = 0
  if cfg.ui_scale ~= 1 then
    for _, item in ipairs(UI_SCALE_STYLE_VARS) do
      local get_style_var = r['ImGui_StyleVar_' .. item[1]]
      if get_style_var then
        local var = get_style_var()
        local x, y = ImGui.GetStyleVar(ctx, var)
        if item[2] then
          ImGui.PushStyleVar(ctx, var, x * cfg.ui_scale, y * cfg.ui_scale)
        else
          ImGui.PushStyleVar(ctx, var, x * cfg.ui_scale)
        end
        scale_n = scale_n + 1
      end
    end
  end

  if not theme_fns then
    theme_fns = {}
    for _, t in ipairs(THEME) do
      local f = r['ImGui_' .. t[1]] -- skip colors this ReaImGui version doesn't have
      if f then theme_fns[#theme_fns + 1] = { f(), t[2] } end
    end
  end
  for _, t in ipairs(theme_fns) do ImGui.PushStyleColor(ctx, t[1], theme_color(t[2])) end
  local n = #theme_fns
  if r.ImGui_Col_TextSelectedBg then
    ImGui.PushStyleColor(ctx, r.ImGui_Col_TextSelectedBg(), (C('accent') & 0xFFFFFF00) | 0x60)
    n = n + 1
  end
  return n, scale_n
end

local function pop_theme(n, scale_n)
  if n > 0 then ImGui.PopStyleColor(ctx, n) end
  if scale_n > 0 then ImGui.PopStyleVar(ctx, scale_n) end
end

---------------------------------------------------------------------
-- Colors window ("Customize colors...")
---------------------------------------------------------------------
local function hex_str(col) return ('#%08X'):format(col) end

local function parse_hex(txt)
  local h = txt:match('^%s*#?(%x+)%s*$')
  if not h then return nil end
  if #h == 6 then h = h .. 'FF' end
  if #h ~= 8 then return nil end
  return tonumber(h, 16)
end

local function color_row(def)
  local key = 'c_' .. def.key
  local col = C(def.key)

  -- hex field
  ImGui.SetNextItemWidth(ctx, 100 * cfg.ui_scale)
  local ch, txt = ImGui.InputText(ctx, '##hex_' .. key, hex_edit[key] or hex_str(col))
  if ch then
    hex_edit[key] = txt
    local v = parse_hex(txt)
    if v then
      cfg[key] = v
      cfg.color_theme = 'Custom'
      cfg.auto_theme = false
    end
  end
  if not ImGui.IsItemActive(ctx) then hex_edit[key] = nil end

  -- swatch + picker popup
  ImGui.SameLine(ctx)
  if ImGui.ColorButton(ctx, '##sw_' .. key, C(def.key), ImGui.ColorEditFlags_AlphaPreview(),
    26 * cfg.ui_scale, 20 * cfg.ui_scale) then
    ImGui.OpenPopup(ctx, 'pick_' .. key)
  end
  if ImGui.BeginPopup(ctx, 'pick_' .. key) then
    local pflags = ImGui.ColorEditFlags_AlphaBar() | ImGui.ColorEditFlags_NoSidePreview()
    local c2, v2 = ImGui.ColorPicker4(ctx, '##pk_' .. key, C(def.key), pflags)
    if c2 then
      cfg[key] = v2
      hex_edit[key] = nil
      cfg.color_theme = 'Custom'
      cfg.auto_theme = false
    end
    if ImGui.Button(ctx, 'Reset') then
      cfg[key] = def.def
      hex_edit[key] = nil
      cfg.color_theme = 'Custom'
      cfg.auto_theme = false
    end
    ImGui.EndPopup(ctx)
  end

  ImGui.SameLine(ctx)
  ImGui.Text(ctx, def.label)
end

local function draw_colors_window()
  if not show_colors then return end
  ImGui.SetNextWindowSize(ctx, 420 * cfg.ui_scale, 640 * cfg.ui_scale, ImGui.Cond_FirstUseEver())
  local visible, open = ImGui.Begin(ctx, 'Picker Colors', true)
  if visible then
    ImGui.SeparatorText(ctx, 'Font')
    if r.ImGui_CreateFont then
      local family_idx = 0
      for i, family in ipairs(FONT_FAMILIES) do
        if cfg.font_family == family then family_idx = i - 1; break end
      end
      ImGui.SetNextItemWidth(ctx, 180 * cfg.ui_scale)
      local family_changed, family_choice = ImGui.Combo(
        ctx, 'Family', family_idx, table.concat(FONT_FAMILIES, '\0') .. '\0')
      if family_changed then cfg.font_family = FONT_FAMILIES[family_choice + 1] or 'sans-serif' end
    else
      ImGui.TextDisabled(ctx, 'Font family choices require ReaImGui 0.10 or newer.')
    end
    ImGui.SetNextItemWidth(ctx, 220 * cfg.ui_scale)
    local size_changed, size = ImGui.SliderInt(ctx, 'Size', cfg.font_size, 8, 24, '%d px')
    if size_changed then cfg.font_size = size end

    ImGui.SeparatorText(ctx, 'Theme')
    if ImGui.Button(ctx, cfg.auto_theme and 'Auto (on)' or 'Auto') then
      local theme = apply_auto_color_theme()
      next_auto_theme_check = r.time_precise() + 30
      set_status('Following Windows theme: ' .. theme)
    end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Follow the Windows light/dark appearance') end
    ImGui.SameLine(ctx)

    local theme_options = {}
    for _, name in ipairs(BUILTIN_COLOR_THEME_NAMES) do
      theme_options[#theme_options + 1] = name
    end
    for _, name in ipairs(saved_color_theme_names) do
      theme_options[#theme_options + 1] = name
    end
    theme_options[#theme_options + 1] = 'Unsaved'
    local active_theme = cfg.color_theme == 'Custom' and 'Unsaved' or cfg.color_theme
    local theme_idx = #theme_options - 1
    for i, name in ipairs(theme_options) do
      if active_theme == name then theme_idx = i - 1; break end
    end
    ImGui.SetNextItemWidth(ctx, 200 * cfg.ui_scale)
    local theme_changed, theme_choice = ImGui.Combo(
      ctx, 'Preset', theme_idx, table.concat(theme_options, '\0') .. '\0')
    if theme_changed then
      local name = theme_options[theme_choice + 1]
      if name == 'Unsaved' then
        cfg.color_theme = 'Custom'
        cfg.auto_theme = false
      else
        apply_color_theme(name)
        theme_name_input = saved_color_themes[name] and name or ''
      end
    end

    ImGui.SetNextItemWidth(ctx, 190 * cfg.ui_scale)
    local _, new_theme_name = ImGui.InputTextWithHint(
      ctx, '##theme_name', 'New theme name', theme_name_input)
    theme_name_input = new_theme_name
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'Save') then save_current_color_theme(theme_name_input) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'Delete') then delete_saved_color_theme(cfg.color_theme) end
    if theme_name_input ~= '' and not normalize_color_theme_name(theme_name_input) then
      ImGui.TextDisabled(ctx, 'Use a unique name of up to 64 characters.')
    end
    ImGui.Separator(ctx)

    for _, def in ipairs(COLOR_DEFS) do
      if def.section then
        ImGui.SeparatorText(ctx, def.section)
      else
        color_row(def)
      end
    end
    ImGui.Separator(ctx)
    if ImGui.Button(ctx, 'Reset all colors') then
      apply_color_theme('Default')
    end
    ImGui.End(ctx)
  end
  if not open then show_colors = false end
end

---------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------
local TARGET_ITEMS = 'Selected tracks\0Master track\0Selected items (take FX)\0'

local function loop()
  local now = r.time_precise()
  frame_dt = math.max(0, math.min(now - last_frame_time, 0.1))
  last_frame_time = now
  loads_this_frame = 0
  if cfg.auto_theme and now >= next_auto_theme_check then
    local name = detect_system_color_theme()
    if cfg.color_theme ~= name then
      apply_color_theme(name)
      cfg.auto_theme = true
    end
    next_auto_theme_check = now + 30
  end
  capture_step()

  ImGui.SetNextWindowSize(ctx, cfg.win_w, cfg.win_h, ImGui.Cond_FirstUseEver())
  local font = get_picker_font()
  local theme_n, style_n = push_theme()
  ImGui.PushFont(ctx, font, math.max(8, math.min(24, cfg.font_size)) * cfg.ui_scale)
  local visible, open = ImGui.Begin(ctx, 'Plugin Picker', true, ImGui.WindowFlags_NoCollapse())

  if visible then
    cfg.win_w, cfg.win_h = ImGui.GetWindowSize(ctx)
    local picker_x, picker_y = ImGui.GetWindowPos(ctx)
    local mouse_x, mouse_y = r.GetMousePosition()
    local mouse_down = ImGui.IsMouseDown(ctx, 0)
    if r.JS_Mouse_GetState then mouse_down = (r.JS_Mouse_GetState(1) & 1) == 1 end
    local moved = (last_picker_x and
      (math.abs(picker_x - last_picker_x) > 0.5 or math.abs(picker_y - last_picker_y) > 0.5))
      or (mouse_down and last_mouse_x and
        (math.abs(mouse_x - last_mouse_x) > 1 or math.abs(mouse_y - last_mouse_y) > 1))
    if moved then lightweight_until = now + 0.15 end
    last_picker_x, last_picker_y = picker_x, picker_y
    last_mouse_x, last_mouse_y = mouse_x, mouse_y
    local lightweight = now < lightweight_until
    local deferred, want = {}, nil

    if view == 'manage' then
      draw_manage()
    else
      -- top bar
      if focus_search then ImGui.SetKeyboardFocusHere(ctx); focus_search = false end
      local icon_size = 28 * cfg.ui_scale
      local item_spacing_x = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing())
      ImGui.SetNextItemWidth(ctx, -(2 * icon_size + 2 * item_spacing_x))
      if search ~= '' then ImGui.SetNextItemAllowOverlap(ctx) end
      local ch, txt = ImGui.InputTextWithHint(ctx, '##search', 'Type to search', search)
      if ch then search = txt; sel = 1; clear_multi_selection() end
      local min_x, min_y = ImGui.GetItemRectMin(ctx)
      local max_x, max_y = ImGui.GetItemRectMax(ctx)
      local search_height = max_y - min_y
      local toolbar_y = min_y + (search_height - icon_size) / 2
      if search ~= '' then
        local scale = cfg.ui_scale
        local clear_size = 18 * scale
        local clear_x = max_x - clear_size - 4 * scale
        local clear_y = min_y + ((max_y - min_y) - clear_size) / 2
        ImGui.SetCursorScreenPos(ctx, clear_x, clear_y)
        local clicked = ImGui.InvisibleButton(ctx, '##clear_search', clear_size, clear_size)
        local hovered = ImGui.IsItemHovered(ctx)
        local dl = ImGui.GetWindowDrawList(ctx)
        local color = hovered and C('text') or C('text_dim')
        ImGui.DrawList_AddRectFilled(
          dl, clear_x, clear_y, clear_x + clear_size, clear_y + clear_size,
          C('control_bg'), 3 * scale)
        local inset = 5 * scale
        ImGui.DrawList_AddLine(
          dl, clear_x + inset, clear_y + inset, clear_x + clear_size - inset,
          clear_y + clear_size - inset, color, 1.6 * scale)
        ImGui.DrawList_AddLine(
          dl, clear_x + clear_size - inset, clear_y + inset,
          clear_x + inset, clear_y + clear_size - inset, color, 1.6 * scale)
        if hovered then
          ImGui.SetTooltip(ctx, 'Clear search')
        end
        if clicked then
          search = ''
          sel = 1
          clear_multi_selection()
          focus_search = true
        end
      end
      ImGui.SetCursorScreenPos(ctx, max_x + item_spacing_x, toolbar_y)
      if toolbar_icon_button('##add_plugins', 'Add plugins', 'add') then view = 'manage' end
      ImGui.SameLine(ctx)
      if toolbar_icon_button('##settings', 'Settings', 'settings') then
        ImGui.OpenPopup(ctx, 'Settings')
      end

      draw_settings()

      -- group tabs
      if cfg.cur_group ~= 'All' and cfg.cur_group ~= FAVORITES_GROUP then
        local found = false
        for _, g in ipairs(groups) do if g == cfg.cur_group then found = true end end
        if not found then cfg.cur_group = 'All'; pending_tab = 'All' end
      end
      if pending_tab == nil and not cap.started_tab then
        pending_tab = cfg.cur_group
        cap.started_tab = true
      end
      local rename_requested = false
      local new_group_popup_open = false
      local rename_popup_open = false
      if ImGui.BeginTabBar(ctx, '##groups', ImGui.TabBarFlags_Reorderable()) then
        ImGui.PushStyleColor(ctx, ImGui.Col_Text(), C('text') & 0xFFFFFF00)
        local add_group_clicked = ImGui.TabItemButton(ctx, '+##add_group', ImGui.TabItemFlags_Trailing())
        ImGui.PopStyleColor(ctx)
        local add_group_hovered = ImGui.IsItemHovered(ctx)
        local min_x, min_y = ImGui.GetItemRectMin(ctx)
        local max_x, max_y = ImGui.GetItemRectMax(ctx)
        local icon_x, icon_y = (min_x + max_x) / 2, (min_y + max_y) / 2
        local icon_col = add_group_hovered and C('accent') or C('text_dim')
        local dl = ImGui.GetWindowDrawList(ctx)
        ImGui.DrawList_AddRect(
          dl, icon_x - 6 * cfg.ui_scale, icon_y - 5 * cfg.ui_scale,
          icon_x + 2 * cfg.ui_scale, icon_y + 3 * cfg.ui_scale,
          icon_col, 1.5 * cfg.ui_scale, 0, 1.3 * cfg.ui_scale)
        ImGui.DrawList_AddRect(
          dl, icon_x - 2 * cfg.ui_scale, icon_y - 1 * cfg.ui_scale,
          icon_x + 6 * cfg.ui_scale, icon_y + 7 * cfg.ui_scale,
          icon_col, 1.5 * cfg.ui_scale, 0, 1.3 * cfg.ui_scale)
        ImGui.DrawList_AddCircleFilled(
          dl, icon_x + 5 * cfg.ui_scale, icon_y + 5 * cfg.ui_scale,
          4 * cfg.ui_scale, C('accent'), 16)
        ImGui.DrawList_AddLine(
          dl, icon_x + 5 * cfg.ui_scale, icon_y + 2.5 * cfg.ui_scale,
          icon_x + 5 * cfg.ui_scale, icon_y + 7.5 * cfg.ui_scale, C('window_bg'), 1.2 * cfg.ui_scale)
        ImGui.DrawList_AddLine(
          dl, icon_x + 2.5 * cfg.ui_scale, icon_y + 5 * cfg.ui_scale,
          icon_x + 7.5 * cfg.ui_scale, icon_y + 5 * cfg.ui_scale, C('window_bg'), 1.2 * cfg.ui_scale)
        if add_group_hovered then
          ImGui.SetTooltip(ctx, 'Create a group to organize plugins')
        end
        if add_group_clicked then
          new_group_name = ''
          ImGui.OpenPopup(ctx, 'NewGroup')
        end
        if ImGui.BeginPopup(ctx, 'NewGroup') then
          new_group_popup_open = true
          ImGui.SetNextItemWidth(ctx, 200 * cfg.ui_scale)
          if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
          local _, gtxt = ImGui.InputTextWithHint(ctx, '##gname', 'Group name', new_group_name)
          new_group_name = gtxt
          local create = ImGui.Button(ctx, 'Create') or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter())
          if create and new_group_name ~= '' and new_group_name ~= 'All'
             and new_group_name ~= FAVORITES_GROUP then
            local exists = false
            for _, g in ipairs(groups) do if g == new_group_name then exists = true end end
            if not exists then groups[#groups + 1] = new_group_name; save_library() end
            pending_tab = new_group_name
            ImGui.CloseCurrentPopup(ctx)
          end
          ImGui.EndPopup(ctx)
        end
        local names = { 'All', FAVORITES_GROUP }
        for _, g in ipairs(groups) do names[#names + 1] = g end
        if not ImGui.IsMouseDown(ctx, ImGui.MouseButton_Left()) then
          group_tab_dragging = false
          group_tab_drag_source = nil
          group_tab_highlight = nil
        end
        local group_tab_positions = {}
        for _, gname in ipairs(names) do
          local pinned = gname == 'All' or gname == FAVORITES_GROUP
          local flags = pinned and ImGui.TabItemFlags_NoReorder() or 0
          if pending_tab == gname then flags = flags | ImGui.TabItemFlags_SetSelected() end
          local is_favorites = gname == FAVORITES_GROUP
          local tab_label = (is_favorites and '      ' or '') .. gname .. '###group_tab_' .. gname
          local active = ImGui.BeginTabItem(ctx, tab_label, nil, flags)
          local tab_x, tab_y = ImGui.GetItemRectMin(ctx)
          local tab_max_x, tab_max_y = ImGui.GetItemRectMax(ctx)
          local tab_hovered = ImGui.IsItemHovered(
            ctx, ImGui.HoveredFlags_AllowWhenBlockedByActiveItem())
          if not pinned and ImGui.IsItemActive(ctx)
             and ImGui.IsMouseDragging(ctx, ImGui.MouseButton_Left()) then
            group_tab_dragging = true
            group_tab_drag_source = gname
          end
          if gname ~= 'All' and not is_favorites then
            group_tab_positions[#group_tab_positions + 1] = { name = gname, x = tab_x }
          end
          if group_tab_dragging and not pinned and gname == group_tab_drag_source then
            local dl = ImGui.GetWindowDrawList(ctx)
            ImGui.DrawList_AddRectFilled(
              dl, tab_x + 1, tab_y + 1, tab_max_x - 1, tab_max_y - 1,
              (C('accent') & 0xFFFFFF00) | 0x18, 5 * cfg.ui_scale)
          end
          if group_tab_dragging and not pinned and tab_hovered then
            local target_x, target_y = tab_x, tab_y
            local target_w, target_h = tab_max_x - tab_x, tab_max_y - tab_y
            if not group_tab_highlight then
              group_tab_highlight = {
                x = target_x, y = target_y, w = target_w, h = target_h,
              }
            elseif cfg.smooth_animations then
              local alpha = 1 - math.exp(-frame_dt / 0.045)
              group_tab_highlight.x = group_tab_highlight.x
                + (target_x - group_tab_highlight.x) * alpha
              group_tab_highlight.y = group_tab_highlight.y
                + (target_y - group_tab_highlight.y) * alpha
              group_tab_highlight.w = group_tab_highlight.w
                + (target_w - group_tab_highlight.w) * alpha
              group_tab_highlight.h = group_tab_highlight.h
                + (target_h - group_tab_highlight.h) * alpha
            else
              group_tab_highlight.x, group_tab_highlight.y = target_x, target_y
              group_tab_highlight.w, group_tab_highlight.h = target_w, target_h
            end
            local highlight = group_tab_highlight
            local dl = ImGui.GetWindowDrawList(ctx)
            ImGui.DrawList_AddRectFilled(
              dl, highlight.x + 1, highlight.y + 1,
              highlight.x + highlight.w - 1, highlight.y + highlight.h - 1,
              (C('accent') & 0xFFFFFF00) | 0x24, 5 * cfg.ui_scale)
            ImGui.DrawList_AddRect(
              dl, highlight.x + 1, highlight.y + 1,
              highlight.x + highlight.w - 1, highlight.y + highlight.h - 1,
              C('accent'), 5 * cfg.ui_scale, 0, 1.5 * cfg.ui_scale)
          end
          if not pinned and ImGui.BeginPopupContextItem(ctx) then
            if ImGui.MenuItem(ctx, 'Rename group...') then
              rename_group_original = gname
              rename_group_name = gname
              rename_requested = true
            end
            if ImGui.MenuItem(ctx, 'Delete group "' .. gname .. '"') then
              deferred[#deferred + 1] = function()
                for i, g in ipairs(groups) do if g == gname then table.remove(groups, i); break end end
                for _, e in ipairs(library) do remove_entry_group(e, gname) end
                if cfg.cur_group == gname then cfg.cur_group = 'All'; pending_tab = 'All' end
                save_library()
              end
            end
            ImGui.EndPopup(ctx)
          end
          if is_favorites then
            local scale = cfg.ui_scale
            local star_size = 14 * scale
            local star_x = tab_x + 3 * scale
            local star_y = tab_y + ((tab_max_y - tab_y) - star_size) / 2
            local star_color = active and C('accent')
              or (tab_hovered and C('text') or C('text_dim'))
            draw_favorites_star(
              ImGui.GetWindowDrawList(ctx), star_x, star_y, star_size, star_color)
          end
          if active then
            if cfg.cur_group ~= gname then
              cfg.cur_group = gname
              sel = 1
              clear_multi_selection()
            end
            ImGui.EndTabItem(ctx)
          end
        end
        pending_tab = nil
        ImGui.EndTabBar(ctx)
        if #group_tab_positions == #groups then
          table.sort(group_tab_positions, function(a, b) return a.x < b.x end)
          local changed = false
          for i, tab in ipairs(group_tab_positions) do
            if groups[i] ~= tab.name then changed = true; break end
          end
          if changed then
            for i, tab in ipairs(group_tab_positions) do groups[i] = tab.name end
            save_library()
            set_status('Reordered groups.')
          end
        end
      end

      if rename_requested then ImGui.OpenPopup(ctx, 'RenameGroup') end
      if ImGui.BeginPopup(ctx, 'RenameGroup') then
        rename_popup_open = true
        ImGui.SetNextItemWidth(ctx, 220 * cfg.ui_scale)
        if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
        local _, name = ImGui.InputTextWithHint(ctx, '##rename_group', 'Group name', rename_group_name)
        rename_group_name = name

        local duplicate = false
        for _, group_name in ipairs(groups) do
          if group_name == rename_group_name and group_name ~= rename_group_original then
            duplicate = true
            break
          end
        end
        local reserved = rename_group_name == 'All' or rename_group_name == FAVORITES_GROUP
        local invalid = rename_group_name == '' or reserved or duplicate
        if invalid then
          local message = duplicate and 'That group name already exists.'
            or (reserved and 'That group name is reserved.' or 'Enter a valid group name.')
          ImGui.TextDisabled(ctx, message)
        end

        local commit = ImGui.Button(ctx, 'Rename') or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter())
        if commit and not invalid then
          local found = false
          for i, group_name in ipairs(groups) do
            if group_name == rename_group_original then
              groups[i] = rename_group_name
              found = true
              break
            end
          end
          if found then
            for _, e in ipairs(library) do
              for i, group_name in ipairs(e.groups) do
                if group_name == rename_group_original then
                  e.groups[i] = rename_group_name
                  break
                end
              end
            end
            if cfg.cur_group == rename_group_original then
              cfg.cur_group = rename_group_name
              pending_tab = rename_group_name
            end
            save_library()
            rename_group_original = nil
            rename_group_name = ''
            ImGui.CloseCurrentPopup(ctx)
          else
            ImGui.TextDisabled(ctx, 'The group no longer exists.')
          end
        end
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, 'Cancel') then
          rename_group_original = nil
          rename_group_name = ''
          ImGui.CloseCurrentPopup(ctx)
        end
        ImGui.EndPopup(ctx)
      end

      draw_filter_toolbar()
      ImGui.SameLine(ctx)
      local control_spacing = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing())
      local slider_width = 180 * cfg.ui_scale
      local control_group_width = 2 * 28 * cfg.ui_scale + slider_width + 2 * control_spacing
      local remaining_width = ImGui.GetContentRegionAvail(ctx)
      if remaining_width >= control_group_width then
        ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + remaining_width - control_group_width)
      end
      browser_mode_button('List')
      ImGui.SameLine(ctx)
      grid_size_slider()
      ImGui.SameLine(ctx)
      browser_mode_button('Grid')

      local items = visible_items()
      if pending_selected_plugin then
        for i, item in ipairs(items) do
          if item.name == pending_selected_plugin then sel = i; break end
        end
        pending_selected_plugin = nil
      end
      if sel > #items then sel = #items end
      if sel < 1 then sel = 1 end

      -- keyboard
      local random_moved = scroll_random_selection
      local kb_moved = random_moved
      scroll_random_selection = false
      if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow()) then sel = math.min(sel + last_cols, #items); kb_moved = true end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow()) then sel = math.max(sel - last_cols, 1); kb_moved = true end
      if search == '' and cfg.view_mode == 'Grid' then
        if ImGui.IsKeyPressed(ctx, ImGui.Key_RightArrow()) then sel = math.min(sel + 1, #items); kb_moved = true end
        if ImGui.IsKeyPressed(ctx, ImGui.Key_LeftArrow()) then sel = math.max(sel - 1, 1); kb_moved = true end
      end
      if (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter()) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter()))
         and items[sel] and not new_group_popup_open
         and not rename_popup_open and not metadata_edit_name and not rename_plugin_name then
        want = items[sel]
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape()) then
        if not metadata_edit_name and not rename_plugin_name then
          if search ~= '' then search = ''; sel = 1 else open = false end
        end
      end

      -- browser
      local footer = math.max(ImGui.GetFrameHeightWithSpacing(ctx), 44 * cfg.ui_scale)
        + 6 * cfg.ui_scale
      if ImGui.BeginChild(ctx, '##grid', 0, -footer) then
        local w = draw_browser(items, deferred, kb_moved, lightweight, random_moved)
        want = want or w
        ImGui.EndChild(ctx)
      end
      draw_metadata_editor()
      draw_rename_plugin_editor()
      if handle_drag() and cfg.close_after then open = false end

      -- footer
      local button_size = 44 * cfg.ui_scale
      local button_x = ImGui.GetWindowWidth(ctx) - button_size - 14 * cfg.ui_scale
      local footer_row_y = ImGui.GetCursorPosY(ctx)
      local control_y = footer_row_y + math.max(0, (button_size - ImGui.GetFrameHeight(ctx)) / 2)
      ImGui.SetCursorPosY(ctx, control_y)
      ImGui.SetNextItemWidth(ctx, 190 * cfg.ui_scale)
      local tch, tnew = ImGui.Combo(ctx, '##target', math.floor(cfg.target), TARGET_ITEMS)
      if tch then cfg.target = tnew end
      ImGui.SameLine(ctx)
      local has_status = os.time() - status_t < 5 and status ~= ''
      local footer_text = has_status and status
        or ('%d shown / %d in library'):format(#items, #library)
      local text_width = math.max(1, button_x - ImGui.GetCursorPosX(ctx) - 8 * cfg.ui_scale)
      footer_text = fit_text(footer_text, text_width)
      if has_status then
        ImGui.Text(ctx, footer_text)
      else
        ImGui.TextDisabled(ctx, footer_text)
      end
      ImGui.SameLine(ctx)
      ImGui.SetCursorPosY(ctx, footer_row_y)
      ImGui.SetCursorPosX(ctx, button_x)
      if random_plugin_button(#items > 0) then
        if #items > 1 then
          local random_index = math.random(#items - 1)
          if random_index >= sel then random_index = random_index + 1 end
          sel = random_index
        else
          sel = 1
        end
        clear_multi_selection()
        scroll_random_selection = true
        status = 'Random pick: ' .. items[sel].display
        status_t = os.time()
      end
    end

    for _, fn in ipairs(deferred) do fn() end
    if want and add_fx(want) and cfg.close_after then open = false end

    ImGui.End(ctx)
  end

  draw_colors_window()
  draw_drag_ghost()
  ImGui.PopFont(ctx)
  pop_theme(theme_n, style_n)

  if open then r.defer(loop) end
end

---------------------------------------------------------------------
-- Start
---------------------------------------------------------------------
math.randomseed(os.time())
migrate_data_to_documents()
load_saved_color_themes()
load_cfg()
load_metadata_overrides()
if cfg.auto_theme then
  apply_auto_color_theme()
  next_auto_theme_check = r.time_precise() + 30
end
load_library()
load_installed()
r.atexit(function()
  save_cfg()
  save_library()
  set_toggle_state(false)
end)
set_toggle_state(true)
r.defer(loop)
