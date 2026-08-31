-- The scratchpad, presented as a Quake console: a dimmed overlay that drops
-- down over whatever workspace you are on. Its bindings live in
-- bindings/tiling.lua, and its slide is animated at the bottom of this file.
--
-- Two things are kept in step as outputs come, go, and change shape: the size
-- of the panel, which is the area left by the gaps around it, and the placement
-- of any floating window on the scratchpad, which is remapped so it keeps its
-- place relative to the edges of the work area.

-- How much of the usable screen the console covers, measured from the top.
local share = 0.5

-- A console holding a single tiled window is boxed into a centered panel this
-- many times wider than it is tall, rather than stretched the width of the
-- screen. A second tiled app on the scratchpad gets the full width back: two
-- windows splitting a half-width column is worse than the band this replaced.
-- A floating window does not count toward that.
local box = 2

local SCRATCHPAD = "special:scratchpad"

-- Seed the console with the default agent the first time it opens, rather than
-- at boot, so nothing is running until it is wanted. The exec rule has to pin
-- the workspace itself: Hyprland only tags a spawn with the workspace it came
-- from while misc.initial_workspace_tracking is on, and looknfeel turns it off.
-- Omarchy ships without a default agent, and omarchy-agent exits without
-- opening anything when none is set, so until one is picked this just opens an
-- empty console.
local seed = "[workspace special:scratchpad silent] omarchy-agent"

-- Dimming only applies while a special workspace is open, so the console gets
-- its separation from the workspace underneath without costing anything the
-- rest of the time.
hl.config({
  decoration = {
    dim_special = 0.6,
  },
})

-- Geometry -------------------------------------------------------------------

-- The output's box in layout space, which is the coordinate system both the
-- gaps and window.at use. monitor.x/y are already the layout origin and need
-- not be zero. Width and height are the panel's own physical pixels, so a
-- monitor turned on its side still reports them the way the panel is built; the
-- quarter turns are the odd transforms, and those are the ones that swap the
-- box. Scale comes off last, because everything downstream of here is logical.
--
-- A monitor handle whose output has gone away answers nil to every field, and
-- layout changes are exactly when that happens, so every field is guarded.
local function logical_box(monitor)
  if not monitor then
    return nil
  end

  local scale, width, height = monitor.scale, monitor.width, monitor.height
  if not scale or scale <= 0 or not width or not height then
    return nil
  end
  if (monitor.transform or 0) % 2 == 1 then
    width, height = height, width
  end

  return {
    x = monitor.x or 0,
    y = monitor.y or 0,
    width = width / scale,
    height = height / scale,
  }
end

-- The same box with the bar taken off. reserved is already logical, so unlike
-- width and height it comes off after scale rather than before.
local function work_area(monitor)
  local screen = logical_box(monitor)
  local reserved = screen and monitor.reserved
  if not reserved then
    return nil
  end

  return {
    x = screen.x + reserved.left,
    y = screen.y + reserved.top,
    width = screen.width - reserved.left - reserved.right,
    height = screen.height - reserved.top - reserved.bottom,
  }
end

-- Whether a layout point sits on this output, measured in the same space as
-- work_area so an origin-shift undo can be tested against it.
local function contains(monitor, x, y)
  local screen = logical_box(monitor)
  if not screen then
    return false
  end

  return x >= screen.x and x < screen.x + screen.width and y >= screen.y and y < screen.y + screen.height
end

-- The panel ------------------------------------------------------------------

-- The panel is always flush with the top and always centered, so two numbers
-- describe it: the gap down each side and the gap underneath.
--
-- Refitting replaces the rule in place rather than stacking a new one, but it
-- still schedules a monitor and window state refresh, and monitor.focused fires
-- on every hop between screens. Most of those hops do not change the gaps, so
-- only write the rule when it actually moves.
local beside, below = nil, nil

local function cover(side, bottom)
  if beside == side and below == bottom then
    return false
  end
  beside, below = side, bottom

  hl.workspace_rule({
    workspace = SCRATCHPAD,
    gaps_in = 0,
    gaps_out = { top = 0, right = side, bottom = bottom, left = side },

    -- Nothing to highlight in a console that is only ever focused when it is
    -- open, and the active border reads as a stray frame around a panel that
    -- is already set apart by the dimming behind it.
    no_border = true,

    on_created_empty = seed,
  })

  return true
end

-- One tiled window reads as a console and gets the panel. A second tiled app
-- has turned the scratchpad into a workspace, and a workspace wants the whole
-- width.
local function alone()
  local ws = hl.get_workspace(SCRATCHPAD)
  return not ws or #hl.get_windows({ workspace = SCRATCHPAD, floating = false }) <= 1
end

-- Sizing the console with a window rule would freeze it at whatever the screen
-- measured when it first opened, because Hyprland resolves those expressions
-- once, as the window maps. Rescaling the monitor afterwards would leave a
-- console that is no longer half of anything. Gaps are re-applied by the layout
-- instead, so the console is sized by the area left around it, and that area is
-- recomputed whenever the monitor it opens on changes.
local function fit(monitor)
  local area = work_area(monitor)
  if not area then
    return false
  end

  local tall = math.floor(area.height * share)
  local wide = area.width
  if alone() then
    wide = math.min(area.width, tall * box)
  end

  return cover(math.floor((area.width - wide) / 2), math.floor(area.height - tall))
end

-- Which output ---------------------------------------------------------------

-- Hyprland can keep a stale userdata for an output we are still holding on to.
-- Re-resolve by name so a scale change is visible even when the handle is not.
local function live_monitor(mon)
  if not mon then
    return nil
  end

  if mon.name then
    local fresh = hl.get_monitor(mon.name)
    if fresh and work_area(fresh) then
      return fresh
    end
  end
  if work_area(mon) then
    return mon
  end
  return nil
end

-- The output the workspace itself names, while the console is on screen.
local function shown_monitor()
  local ws = hl.get_workspace(SCRATCHPAD)
  return live_monitor(ws and ws.visible and ws.monitor)
end

-- The console keeps the geometry of the output it is open on: a follow_mouse hop
-- onto another screen must not resize a console that is already showing. While
-- it is hidden there is nothing to size but the output that will show it next.
local function console_monitor()
  return shown_monitor() or hl.get_active_monitor()
end

local function refit(monitor)
  if fit(monitor or console_monitor()) then
    -- Land the new gaps in this pass rather than a frame later, so the console
    -- does not visibly resize itself once it has already dropped down.
    hl.exec_scheduled_prop_refresh_immediately()
  end
end

-- Which output is actually showing the scratchpad, not which one was focused
-- when the event fired. A hop of an already-open console may skip
-- special_active, so the monitor's own tag is the more direct signal.
local function scratchpad_monitor()
  for _, m in ipairs(hl.get_monitors()) do
    local sp = m.active_special_workspace
    if sp and sp.name == SCRATCHPAD then
      return live_monitor(m)
    end
  end
  return shown_monitor()
end

-- Where the floats were last placed ------------------------------------------

-- The output the console was last shown on, and that output's geometry at the
-- time. The live handle updates in place when scale or transform changes, so
-- without the snapshot floats would be measured against the new work area while
-- still carrying their old at.
--
-- Startup fit() is not a showing: that would treat a hidden console as if it
-- had opened on whatever the pointer is over. Window-count recounts also must
-- not record a monitor: Hyprland marks the scratchpad visible on the
-- destination and re-applies rules before workspace.special_active, which would
-- make every hop look like a same-output toggle. A config reload is neither,
-- and is recovered from the workspace at the bottom of this file.
local last_mon = nil
local last_snap = nil

-- Copy geometry off the live handle, since that handle mutates underneath us.
local function snapshot_mon(monitor)
  local area = work_area(monitor)
  if not area or not monitor.name then
    return nil
  end

  local r = monitor.reserved
  return {
    name = monitor.name,
    x = monitor.x or 0,
    y = monitor.y or 0,
    width = monitor.width,
    height = monitor.height,
    scale = monitor.scale,
    transform = monitor.transform or 0,
    reserved = { left = r.left, right = r.right, top = r.top, bottom = r.bottom },
  }
end

local function same_geometry(a, b)
  local ar, br = a.reserved, b.reserved
  return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height
    and a.scale == b.scale and a.transform == b.transform
    and ar.left == br.left and ar.right == br.right and ar.top == br.top and ar.bottom == br.bottom
end

local function remember(monitor)
  if monitor and monitor.name then
    last_mon = monitor
    last_snap = snapshot_mon(monitor)
  end
end

-- After a hop, window.monitor is the destination even when special_active still
-- names the output we scaled on. Coordinates are not that signal: after a
-- scale-up they can sit on the neighbouring output's box without a hop.
local function float_output()
  if not last_snap then
    return nil
  end

  for _, win in ipairs(hl.get_windows({ workspace = SCRATCHPAD, floating = true })) do
    local mon = win.monitor
    if mon and mon.name and mon.name ~= last_snap.name and work_area(mon) then
      return mon
    end
  end

  return nil
end

-- Where the console is now, most direct signal first.
local function current_output()
  return float_output() or scratchpad_monitor()
end

-- Moving the floats ----------------------------------------------------------

local function clamp(n, lo, hi)
  if hi < lo then
    return lo
  end
  return math.min(math.max(n, lo), hi)
end

-- Map a top-left along one axis so the origin edge, far edge, and center stay
-- those places on the destination. Travel is the room the window has to slide
-- inside the work area.
local function map_along(at, src_origin, src_span, dst_origin, dst_span, size)
  local src_travel = src_span - size
  local dst_travel = dst_span - size
  if src_travel <= 0 or dst_travel <= 0 then
    return dst_origin
  end
  return dst_origin + (at - src_origin) / src_travel * dst_travel
end

-- Hyprland origin-shifts floats by dest.origin - src.origin before the hop
-- callback. The shift can leave the window geometrically on the source when
-- that delta is smaller than the window's offset inside it. Undo the shift
-- whenever the undone point still sits on the source; otherwise the live
-- coordinate is already in source space.
local function src_at(at_x, at_y, old_mon, new_mon)
  local undone_x = at_x - (new_mon.x or 0) + (old_mon.x or 0)
  local undone_y = at_y - (new_mon.y or 0) + (old_mon.y or 0)
  if contains(old_mon, undone_x, undone_y) then
    return undone_x, undone_y
  end
  return at_x, at_y
end

-- Keep each float's place relative to the work area: centered stays centered,
-- a corner stays a corner. Clamp so the whole window sits on the destination.
-- ponytail: a hop through a smaller screen can clamp, and the way back
-- restores the clamped offset rather than the original placement. Per-window
-- per-monitor memory is the upgrade if that round-trip starts to matter.
local function place_floats(old_mon, new_mon)
  local src = work_area(old_mon)
  local dst = work_area(new_mon)
  if not src or not dst or src.width <= 0 or src.height <= 0 then
    return
  end

  for _, win in ipairs(hl.get_windows({ workspace = SCRATCHPAD, floating = true })) do
    local at, size = win.at, win.size
    if at and size and at.x and at.y and size.x and size.y then
      local at_x, at_y = src_at(at.x, at.y, old_mon, new_mon)

      local nx = map_along(at_x, src.x, src.width, dst.x, dst.width, size.x)
      local ny = map_along(at_y, src.y, src.height, dst.y, dst.height, size.y)
      nx = math.floor(clamp(nx, dst.x, dst.x + dst.width - size.x))
      ny = math.floor(clamp(ny, dst.y, dst.y + dst.height - size.y))

      if nx ~= at.x or ny ~= at.y then
        hl.dispatch(hl.dsp.window.move({ window = win, x = nx, y = ny }))
      end
    end
  end
end

-- The output we snapshotted may have been rescaled since, so re-resolve that
-- one by name to see it. A hop has to keep the destination handle it was handed,
-- because a lookup by name could hand back the scaled output instead.
local function freshen(dest)
  if dest and last_snap and dest.name == last_snap.name then
    return live_monitor(dest) or dest
  end
  return dest
end

-- Map from the snapshot, not the live handle: after a scale change the handle
-- already has the new geometry, and Hyprland may land the workspace on the
-- destination and re-apply rules before special_active, so last_mon.name can
-- already match dest. Any geometry mismatch is a remap, whether it came from a
-- hop, a scale, or both. Same-output toggles share the snapshot and do nothing.
local function place_from_snap(dest)
  dest = freshen(dest)

  local now = snapshot_mon(dest)
  if not last_snap or not now or same_geometry(last_snap, now) then
    return
  end

  place_floats(last_snap, dest)
  remember(dest)
end

-- Put the floats where the console is now, then size the panel to match.
local function reconcile()
  place_from_snap(current_output())
  refit()
end

local function show_on(monitor)
  local dest = freshen(float_output() or monitor)
  refit(dest)
  place_from_snap(dest)
  -- Only the first show records a snapshot without a remap. Remembering dest
  -- after a skipped remap would freeze the new geometry and skip the next hop.
  if not last_snap then
    remember(dest)
  end
end

-- Reacting -------------------------------------------------------------------

-- Until a monitor can be read, cover the whole work area rather than leaving
-- the console unruled, so it is never seeded without its placement. A reload
-- runs this again with the console already on screen, so it starts from the
-- output the console is on rather than whichever one the pointer is over.
cover(0, 0)
fit(console_monitor())

-- A reload is not a boot: bootstrap.lua drops this module from package.loaded,
-- so the file re-runs with the floats already placed but no memory of which
-- output their coordinates are measured against, and the first hop after that
-- leaves them wherever Hyprland's origin shift dropped them. Changing a
-- monitor's scale rewrites monitors.lua, which is exactly what Hyprland reloads
-- on, so that is the hop it strands. Take the output from the workspace, which
-- owns it whether the console is showing or not, rather than console_monitor(),
-- which answers with the pointer's output while it is hidden. At boot there is
-- no scratchpad to read and this does nothing.
local reloaded_onto = hl.get_workspace(SCRATCHPAD)
remember(reloaded_onto and reloaded_onto.monitor)

hl.on("monitor.layout_changed", function()
  -- Scale mutates the remembered output in place; a hop updates which output
  -- the floats are on. Do both so neither waits on special_active.
  place_from_snap(last_mon)
  reconcile()
end)

hl.on("monitor.focused", reconcile)

-- Special workspaces open on the monitor they are toggled on, not on whichever
-- output last happened to be focused when the rule was written, so these two
-- take the monitor they are handed rather than looking one up.
hl.on("workspace.special_active", function(ws, mon)
  if ws and ws.name == SCRATCHPAD then
    show_on(mon)
  end
end)

hl.on("workspace.move_to_monitor", function(ws, mon)
  if ws and ws.name == SCRATCHPAD then
    show_on(mon)
  end
end)

-- The panel is only centered while the console holds one tiled window, so the
-- count has to be rechecked as tiled apps come and go. window.close still
-- counts the window on its way out; window.open, window.destroy, and
-- window.move_to_workspace run after membership has already moved
-- (moveToWorkspace writes m_workspace before it emits).
--
-- Only while it is on screen, though. A hidden console is refitted on its way in
-- by workspace.special_active, and every window opened anywhere on the desktop
-- would otherwise rewrite the rule.
--
-- Toggling floating is not an open or a destroy. It does re-apply window rules,
-- so window.update_rules covers Super+T and Super+O. Hyprland has a C++
-- window.floating signal that Lua does not expose.
local function recount()
  local ws = hl.get_workspace(SCRATCHPAD)
  if ws and ws.visible then
    -- Rules re-apply after Hyprland has already moved the scratchpad, which is
    -- often the first moment the destination monitor is readable.
    local mon = current_output() or console_monitor()
    place_from_snap(mon)
    refit(mon)
  end
end

hl.on("window.open", recount)
hl.on("window.destroy", recount)
hl.on("window.move_to_workspace", recount)
hl.on("window.update_rules", recount)

-- The direction names the edge the offset is measured from, not where the
-- workspace goes: "slide top" drops it down into view, and "slide bottom"
-- retracts it back up the way a Quake console does.
hl.animation({ leaf = "specialWorkspaceIn", enabled = true, speed = 3, bezier = "easeOutQuint", style = "slide top" })
hl.animation({ leaf = "specialWorkspaceOut", enabled = true, speed = 2, bezier = "easeInOutCubic", style = "slide bottom" })
