-- @description Visual Plugin Picker (grid of plugin screenshots)
-- @version 2.0
-- @about
--   A visual, screenshot-based plugin browser for REAPER.
--   * You curate a library of only the plugins you use ("Add plugins")
--   * Plugins are shown as a grid of tiles with screenshots
--   * Groups (tabs), search, keyboard navigation, customizable layout/colors
--   * Click a tile (or press Enter) to add the plugin
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
local DIR = r.GetResourcePath() .. '/Data/VisualPluginPicker/'
local SHOT_DIR = DIR .. 'shots/'
r.RecursiveCreateDirectory(SHOT_DIR, 0)
local HAS_JS = (r.JS_LICE_WritePNG ~= nil and r.JS_GDI_Blit ~= nil and r.JS_Window_GetClientRect ~= nil)

local ctx = ImGui.CreateContext('Plugin Picker')
local last_err = nil
local drag = nil -- { e = entry, moved = bool } while a tile is being pressed/dragged
local show_colors = false
local hex_edit = {}

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

local DEFAULTS = {
  tile_w = 170, aspect = 0.75, show_names = true,
  close_after = false, open_ui = true, auto_capture = false,
  cap_delay = 1.5, cap_method = 0,
  win_w = 780, win_h = 560, target = 0, cur_group = 'All',
}
for _, d in ipairs(COLOR_DEFS) do
  if d.key then DEFAULTS['c_' .. d.key] = d.def end
end
local cfg = {}

local function load_cfg()
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  local s = r.GetExtState(EXT, 'cfg')
  for k, v in s:gmatch('([%w_]+)=([^\n]*)') do
    local d = DEFAULTS[k]
    if d ~= nil then
      if type(d) == 'number' then cfg[k] = tonumber(v) or d
      elseif type(d) == 'boolean' then cfg[k] = (v == '1')
      else cfg[k] = v end
    end
  end
end

local function save_cfg()
  local t = {}
  for k, v in pairs(cfg) do
    if type(v) == 'boolean' then v = v and '1' or '0' end
    t[#t + 1] = k .. '=' .. tostring(v)
  end
  r.SetExtState(EXT, 'cfg', table.concat(t, '\n'), true)
end

local function C(key) return math.floor(cfg['c_' .. key]) end

---------------------------------------------------------------------
-- State
---------------------------------------------------------------------
local view = 'grid'            -- 'grid' | 'manage'
local search = ''
local sel = 1
local focus_search = true
local status, status_t = '', 0
local last_cols = 1
local new_group_name = ''
local pending_tab = nil
local msearch, mfilter, mdirty = '', 'All', true
local mfiltered = {}
local mfilters = { 'All' }
local loads_this_frame = 0

local library, groups, lib_index = {}, {}, {}
local installed, inst_list, types = {}, {}, {}
local images = {}
local lbl_cache = {}

local function set_status(msg) status, status_t = msg, os.time() end

---------------------------------------------------------------------
-- Plugin helpers
---------------------------------------------------------------------
local function parse_name(name)
  local ptype, rest = name:match('^([^:]+):%s*(.*)$')
  if not ptype then return 'Other', name, false end
  local base = ptype:gsub('i$', '')
  return base, rest, base ~= ptype
end

local function make_entry(name, group)
  local ty, disp, inst = parse_name(name)
  return { name = name, group = group or '', type = ty, display = disp, inst = inst, lower = name:lower() }
end

local function shot_path(name)
  local safe = name:gsub('[^%w%-_ %.%(%)]', '_')
  return SHOT_DIR .. safe .. '.png'
end

local function sort_library()
  table.sort(library, function(a, b) return a.display:lower() < b.display:lower() end)
  lib_index = {}
  for _, e in ipairs(library) do lib_index[e.name] = e end
end

local function save_library()
  local f = io.open(DIR .. 'library.txt', 'w')
  if f then
    for _, e in ipairs(library) do f:write(e.name, '\t', e.group, '\n') end
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
      if line ~= '' then groups[#groups + 1] = line end
    end
    g:close()
  end
  local f = io.open(DIR .. 'library.txt', 'r')
  if f then
    for raw in f:lines() do
      local line = raw:gsub('\r', '')
      local n, grp = line:match('^(.-)\t(.*)$')
      if n and n ~= '' then library[#library + 1] = make_entry(n, grp) end
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
  r.JS_LICE_WritePNG(path, bmp, false)
  r.JS_LICE_DestroyBitmap(bmp)
  return r.file_exists(path)
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
    cap.queued[cap.name] = nil
    if not ok then set_status('Capture failed: ' .. cap.name) end
    cap.track, cap.state = nil, 'idle'
  end
end

---------------------------------------------------------------------
-- Library editing
---------------------------------------------------------------------
local function lib_add(e)
  if lib_index[e.name] then return end
  local grp = (cfg.cur_group ~= 'All') and cfg.cur_group or ''
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
-- Drag & drop onto a track (TCP / mixer / arrange lane)
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
  drag.mx, drag.my = x, y
  local tr = r.GetTrackFromPoint(x, y)
  if tr then
    local _, nm = r.GetTrackName(tr)
    local num = math.floor(r.GetMediaTrackInfo_Value(tr, 'IP_TRACKNUMBER') or 0)
    drag.target = (num > 0) and ('%d: %s'):format(num, nm) or nm
  else
    drag.target = nil
  end
  if mouse_down then return false end

  local e = drag.e
  drag = nil
  if tr then return add_fx_to_track(e, tr) end
  set_status('Drag a plugin onto a track to add it.')
  return false
end

---------------------------------------------------------------------
-- Drawing helpers
---------------------------------------------------------------------
local function get_image(e)
  local img = images[e.name]
  if img == false then return nil end
  if img then
    if r.ImGui_ValidatePtr(img, 'ImGui_Image*') then return img end
    images[e.name] = nil
  end
  if loads_this_frame >= 3 then return nil end
  local p = shot_path(e.name)
  if not r.file_exists(p) then images[e.name] = false; return nil end
  loads_this_frame = loads_this_frame + 1
  local ok, im = pcall(r.ImGui_CreateImage, p)
  if ok and im then
    if r.ImGui_Attach then pcall(r.ImGui_Attach, ctx, im) end
    images[e.name] = im
    return im
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
    local ok
    if searching then
      ok = matches_terms(e.lower, terms)
    else
      ok = (cfg.cur_group == 'All') or (e.group == cfg.cur_group)
    end
    if ok then items[#items + 1] = e end
  end
  return items
end

---------------------------------------------------------------------
-- Drag ghost: small preview that follows the cursor while dragging
---------------------------------------------------------------------
local function draw_drag_ghost()
  if not (drag and drag.moved and drag.mx) then return end
  local gx, gy = drag.mx, drag.my
  if r.ImGui_PointConvertNative then
    gx, gy = r.ImGui_PointConvertNative(ctx, gx, gy, false)
  end

  local flags = ImGui.WindowFlags_NoDecoration() | ImGui.WindowFlags_AlwaysAutoResize()
    | ImGui.WindowFlags_NoSavedSettings() | ImGui.WindowFlags_NoInputs()
    | ImGui.WindowFlags_NoFocusOnAppearing() | ImGui.WindowFlags_NoNav()
  if r.ImGui_WindowFlags_TopMost then flags = flags | r.ImGui_WindowFlags_TopMost() end

  -- offset from the cursor so the preview never sits under the drop point
  ImGui.SetNextWindowPos(ctx, gx + 16, gy + 16, ImGui.Cond_Always())
  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg(), C('tile'))
  ImGui.PushStyleColor(ctx, ImGui.Col_Border(), C('tile_hl'))
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowBorderSize(), 2)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding(), 6)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding(), 6, 6)
  local visible = ImGui.Begin(ctx, '##dragghost', nil, flags)
  ImGui.PopStyleVar(ctx, 3)
  ImGui.PopStyleColor(ctx, 2)

  if visible then
    local img = get_image(drag.e)
    if img then
      local w0, h0 = ImGui.Image_GetSize(img)
      local sc = math.min(150 / w0, 110 / h0, 1)
      ImGui.Image(ctx, img, w0 * sc, h0 * sc)
    end
    ImGui.Text(ctx, fit_text(drag.e.display, 170))
    if drag.target then
      ImGui.TextColored(ctx, C('accent'), '-> ' .. fit_text(drag.target, 170))
    else
      ImGui.TextDisabled(ctx, 'Drop on a track')
    end
    ImGui.End(ctx)
  end
end

---------------------------------------------------------------------
-- Grid view
---------------------------------------------------------------------
local GAP = 8

local function draw_grid(items, deferred, kb_moved)
  local want
  local avail_w = ImGui.GetContentRegionAvail(ctx) - 2
  local cols = math.max(1, math.floor((avail_w + GAP) / (cfg.tile_w + GAP)))
  last_cols = cols
  local tw = math.floor((avail_w - (cols - 1) * GAP) / cols)
  local label_h = cfg.show_names and (ImGui.GetTextLineHeight(ctx) + 8) or 0
  local th = math.floor(tw * cfg.aspect) + label_h
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

  for i, e in ipairs(items) do
    if (i - 1) % cols ~= 0 then ImGui.SameLine(ctx, 0, GAP) end
    local x, y = ImGui.GetCursorScreenPos(ctx)
    ImGui.InvisibleButton(ctx, '##tile' .. i, tw, th)
    local hovered = ImGui.IsItemHovered(ctx)
    local dl = ImGui.GetWindowDrawList(ctx)

    ImGui.DrawList_AddRectFilled(dl, x, y, x + tw, y + th, hovered and tile_hover or tile_col, 6)

    local img = get_image(e)
    if img then
      local iw, ih = ImGui.Image_GetSize(img)
      local pad = 4
      local s = math.min((tw - 2 * pad) / iw, (ah - 2 * pad) / ih)
      local dw, dh = iw * s, ih * s
      local ix, iy = x + (tw - dw) / 2, y + (ah - dh) / 2
      ImGui.DrawList_AddImage(dl, img, ix, iy, ix + dw, iy + dh)
    else
      local dn = fit_text(e.display, tw - 14)
      local w1, h1 = ImGui.CalcTextSize(ctx, dn)
      ImGui.DrawList_AddText(dl, x + (tw - w1) / 2, y + ah / 2 - h1 / 2, C('tile_placeholder'), dn)
    end

    if cfg.show_names then
      local t = fit_text(e.display, tw - 10)
      local lw, lh = ImGui.CalcTextSize(ctx, t)
      local col = installed[e.name] and C('tile_text') or C('tile_missing')
      ImGui.DrawList_AddText(dl, x + (tw - lw) / 2, y + ah + (label_h - lh) / 2 - 1, col, t)
    end

    if drag and drag.moved and drag.e == e then
      ImGui.DrawList_AddRectFilled(dl, x, y, x + tw, y + th, C('drag_dim'), 6)
    end

    if hovered or i == sel then
      ImGui.DrawList_AddRect(dl, x, y, x + tw, y + th, accent, 6, 0, 2)
    end
    if kb_moved and i == sel then ImGui.SetScrollHereY(ctx, 0.5) end

    if hovered and not (drag and drag.moved) then
      ImGui.SetTooltip(ctx, e.name .. (e.group ~= '' and ('\nGroup: ' .. e.group) or ''))
    end
    if ImGui.IsItemActivated(ctx) then drag = { e = e, moved = false }; sel = i end
    if drag and drag.e == e and not drag.moved and ImGui.IsItemActive(ctx)
       and ImGui.IsMouseDragging(ctx, 0, 6) then
      drag.moved = true
    end
    -- a press-and-release without moving is a click
    if ImGui.IsItemDeactivated(ctx) and drag and drag.e == e and not drag.moved and hovered then
      want = e
    end

    if ImGui.BeginPopupContextItem(ctx) then
      if ImGui.MenuItem(ctx, 'Add to project') then want = e end
      if HAS_JS and ImGui.MenuItem(ctx, 'Capture screenshot') then
        deferred[#deferred + 1] = function()
          enqueue_capture(e.name, true)
        end
      end
      if ImGui.BeginMenu(ctx, 'Move to group') then
        if ImGui.MenuItem(ctx, '(none)') then
          deferred[#deferred + 1] = function() e.group = ''; save_library() end
        end
        for _, gname in ipairs(groups) do
          if ImGui.MenuItem(ctx, gname) then
            deferred[#deferred + 1] = function() e.group = gname; save_library() end
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

  ImGui.SetNextItemWidth(ctx, -170)
  local ch, txt = ImGui.InputTextWithHint(ctx, '##msearch', 'Search installed plugins...', msearch)
  if ch then msearch = txt; mdirty = true end
  ImGui.SameLine(ctx)
  local fidx = 0
  for i, f in ipairs(mfilters) do if f == mfilter then fidx = i - 1 end end
  ImGui.SetNextItemWidth(ctx, 150)
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

---------------------------------------------------------------------
-- Settings popup
---------------------------------------------------------------------
local function draw_settings()
  if not ImGui.BeginPopup(ctx, 'Settings') then return end
  ImGui.SeparatorText(ctx, 'Layout')
  ImGui.SetNextItemWidth(ctx, 220)
  local c, v = ImGui.SliderInt(ctx, 'Min tile width', math.floor(cfg.tile_w), 80, 400)
  if c then cfg.tile_w = v end
  ImGui.SetNextItemWidth(ctx, 220)
  c, v = ImGui.SliderDouble(ctx, 'Tile height ratio', cfg.aspect, 0.4, 1.5, '%.2f')
  if c then cfg.aspect = v end
  c, v = ImGui.Checkbox(ctx, 'Show plugin names', cfg.show_names)
  if c then cfg.show_names = v end

  ImGui.SeparatorText(ctx, 'Colors')
  if ImGui.Button(ctx, 'Customize colors...') then show_colors = true end

  ImGui.SeparatorText(ctx, 'Behavior')
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
    ImGui.SetNextItemWidth(ctx, 220)
    c, v = ImGui.SliderDouble(ctx, 'Wait before capture (s)', cfg.cap_delay, 0.3, 8, '%.1f')
    if c then cfg.cap_delay = v end
    ImGui.SetNextItemWidth(ctx, 220)
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
  if ImGui.Button(ctx, 'Reload images') then images = {} end
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

local function push_theme()
  if not theme_fns then
    theme_fns = {}
    for _, t in ipairs(THEME) do
      local f = r['ImGui_' .. t[1]] -- skip colors this ReaImGui version doesn't have
      if f then theme_fns[#theme_fns + 1] = { f(), t[2] } end
    end
  end
  for _, t in ipairs(theme_fns) do ImGui.PushStyleColor(ctx, t[1], C(t[2])) end
  local n = #theme_fns
  if r.ImGui_Col_TextSelectedBg then
    ImGui.PushStyleColor(ctx, r.ImGui_Col_TextSelectedBg(), (C('accent') & 0xFFFFFF00) | 0x60)
    n = n + 1
  end
  return n
end

local function pop_theme(n)
  if n > 0 then ImGui.PopStyleColor(ctx, n) end
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
  ImGui.SetNextItemWidth(ctx, 100)
  local ch, txt = ImGui.InputText(ctx, '##hex_' .. key, hex_edit[key] or hex_str(col))
  if ch then
    hex_edit[key] = txt
    local v = parse_hex(txt)
    if v then cfg[key] = v end
  end
  if not ImGui.IsItemActive(ctx) then hex_edit[key] = nil end

  -- swatch + picker popup
  ImGui.SameLine(ctx)
  if ImGui.ColorButton(ctx, '##sw_' .. key, C(def.key), ImGui.ColorEditFlags_AlphaPreview(), 26, 20) then
    ImGui.OpenPopup(ctx, 'pick_' .. key)
  end
  if ImGui.BeginPopup(ctx, 'pick_' .. key) then
    local pflags = ImGui.ColorEditFlags_AlphaBar() | ImGui.ColorEditFlags_NoSidePreview()
    local c2, v2 = ImGui.ColorPicker4(ctx, '##pk_' .. key, C(def.key), pflags)
    if c2 then cfg[key] = v2; hex_edit[key] = nil end
    if ImGui.Button(ctx, 'Reset') then cfg[key] = def.def; hex_edit[key] = nil end
    ImGui.EndPopup(ctx)
  end

  ImGui.SameLine(ctx)
  ImGui.Text(ctx, def.label)
end

local function draw_colors_window()
  if not show_colors then return end
  ImGui.SetNextWindowSize(ctx, 420, 640, ImGui.Cond_FirstUseEver())
  local visible, open = ImGui.Begin(ctx, 'Picker Colors', true)
  if visible then
    for _, def in ipairs(COLOR_DEFS) do
      if def.section then
        ImGui.SeparatorText(ctx, def.section)
      else
        color_row(def)
      end
    end
    ImGui.Separator(ctx)
    if ImGui.Button(ctx, 'Reset all colors') then
      for _, d in ipairs(COLOR_DEFS) do if d.key then cfg['c_' .. d.key] = d.def end end
      hex_edit = {}
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
  loads_this_frame = 0
  capture_step()

  ImGui.SetNextWindowSize(ctx, cfg.win_w, cfg.win_h, ImGui.Cond_FirstUseEver())
  local theme_n = push_theme()
  local visible, open = ImGui.Begin(ctx, 'Visual Plugin Picker', true)

  if visible then
    cfg.win_w, cfg.win_h = ImGui.GetWindowSize(ctx)
    local deferred, want = {}, nil

    if view == 'manage' then
      draw_manage()
    else
      -- top bar
      if focus_search then ImGui.SetKeyboardFocusHere(ctx); focus_search = false end
      ImGui.SetNextItemWidth(ctx, -250)
      local ch, txt = ImGui.InputTextWithHint(ctx, '##search', 'Type to search (e.g. "fab")...', search)
      if ch then search = txt; sel = 1 end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, '+ Group') then new_group_name = ''; ImGui.OpenPopup(ctx, 'NewGroup') end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Add plugins') then view = 'manage' end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Settings') then ImGui.OpenPopup(ctx, 'Settings') end

      if ImGui.BeginPopup(ctx, 'NewGroup') then
        ImGui.SetNextItemWidth(ctx, 200)
        if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
        local _, gtxt = ImGui.InputTextWithHint(ctx, '##gname', 'Group name', new_group_name)
        new_group_name = gtxt
        local create = ImGui.Button(ctx, 'Create') or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter())
        if create and new_group_name ~= '' and new_group_name ~= 'All' then
          local exists = false
          for _, g in ipairs(groups) do if g == new_group_name then exists = true end end
          if not exists then groups[#groups + 1] = new_group_name; save_library() end
          pending_tab = new_group_name
          ImGui.CloseCurrentPopup(ctx)
        end
        ImGui.EndPopup(ctx)
      end
      draw_settings()

      -- group tabs
      if cfg.cur_group ~= 'All' then
        local found = false
        for _, g in ipairs(groups) do if g == cfg.cur_group then found = true end end
        if not found then cfg.cur_group = 'All'; pending_tab = 'All' end
      end
      if pending_tab == nil and not cap.started_tab then
        pending_tab = cfg.cur_group
        cap.started_tab = true
      end
      if ImGui.BeginTabBar(ctx, '##groups') then
        local names = { 'All' }
        for _, g in ipairs(groups) do names[#names + 1] = g end
        for _, gname in ipairs(names) do
          local flags = 0
          if pending_tab == gname then flags = ImGui.TabItemFlags_SetSelected() end
          local active = ImGui.BeginTabItem(ctx, gname, nil, flags)
          if gname ~= 'All' and ImGui.BeginPopupContextItem(ctx) then
            if ImGui.MenuItem(ctx, 'Delete group "' .. gname .. '"') then
              deferred[#deferred + 1] = function()
                for i, g in ipairs(groups) do if g == gname then table.remove(groups, i); break end end
                for _, e in ipairs(library) do if e.group == gname then e.group = '' end end
                if cfg.cur_group == gname then cfg.cur_group = 'All'; pending_tab = 'All' end
                save_library()
              end
            end
            ImGui.EndPopup(ctx)
          end
          if active then
            if cfg.cur_group ~= gname then cfg.cur_group = gname; sel = 1 end
            ImGui.EndTabItem(ctx)
          end
        end
        pending_tab = nil
        ImGui.EndTabBar(ctx)
      end

      local items = visible_items()
      if sel > #items then sel = #items end
      if sel < 1 then sel = 1 end

      -- keyboard
      local kb_moved = false
      if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow()) then sel = math.min(sel + last_cols, #items); kb_moved = true end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow()) then sel = math.max(sel - last_cols, 1); kb_moved = true end
      if search == '' then
        if ImGui.IsKeyPressed(ctx, ImGui.Key_RightArrow()) then sel = math.min(sel + 1, #items); kb_moved = true end
        if ImGui.IsKeyPressed(ctx, ImGui.Key_LeftArrow()) then sel = math.max(sel - 1, 1); kb_moved = true end
      end
      if (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter()) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter()))
         and items[sel] and not ImGui.IsPopupOpen(ctx, 'NewGroup') then
        want = items[sel]
      end
      if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape()) then
        if search ~= '' then search = ''; sel = 1 else open = false end
      end

      -- grid
      local footer = ImGui.GetFrameHeightWithSpacing(ctx) + 6
      if ImGui.BeginChild(ctx, '##grid', 0, -footer) then
        local w = draw_grid(items, deferred, kb_moved)
        want = want or w
        ImGui.EndChild(ctx)
      end
      if handle_drag() and cfg.close_after then open = false end

      -- footer
      ImGui.SetNextItemWidth(ctx, 190)
      local tch, tnew = ImGui.Combo(ctx, '##target', math.floor(cfg.target), TARGET_ITEMS)
      if tch then cfg.target = tnew end
      ImGui.SameLine(ctx)
      if os.time() - status_t < 5 and status ~= '' then
        ImGui.Text(ctx, status)
      else
        ImGui.TextDisabled(ctx, ('%d shown / %d in library   |   click to add, or drag onto a track'):format(#items, #library))
      end
    end

    for _, fn in ipairs(deferred) do fn() end
    if want and add_fx(want) and cfg.close_after then open = false end

    ImGui.End(ctx)
  end

  draw_colors_window()
  pop_theme(theme_n)

  draw_drag_ghost()

  if open then r.defer(loop) end
end

---------------------------------------------------------------------
-- Start
---------------------------------------------------------------------
load_cfg()
load_library()
load_installed()
r.atexit(function()
  save_cfg()
  save_library()
  set_toggle_state(false)
end)
set_toggle_state(true)
r.defer(loop)
