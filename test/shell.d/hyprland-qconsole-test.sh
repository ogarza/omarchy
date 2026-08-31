#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

# The console is sized by the gaps around it, recomputed from the monitor,
# because a window rule's size would freeze at whatever the screen measured when
# the console first opened. The arithmetic is what keeps it a half-height panel
# on a scaled display, so it is worth pinning down.
# base-test.sh does not set -e, so the assertions have to fail the file
# themselves rather than leaving the pass below to run regardless.
OMARCHY_PATH="$ROOT" lua - <<'LUA' || fail "the console is a centered panel until a second tiled app joins it"
local rules, handlers, moves = {}, {}, {}
local monitor = nil
local workspace = nil

hl = {
  config = function() end,
  animation = function() end,
  workspace_rule = function(rule) table.insert(rules, rule) end,
  on = function(event, callback) handlers[event] = callback end,
  get_active_monitor = function() return monitor end,
  get_workspace = function() return workspace end,
  get_monitor = function(sel)
    if type(sel) == "table" then
      return sel
    end
    if type(sel) ~= "string" then
      return nil
    end
    if monitor and monitor.name == sel then
      return monitor
    end
    if workspace and workspace.monitor and workspace.monitor.name == sel then
      return workspace.monitor
    end
    return nil
  end,
  get_monitors = function()
    local list, seen = {}, {}
    local function add(m)
      if m and m.name and not seen[m.name] then
        seen[m.name] = true
        table.insert(list, m)
      end
    end
    add(monitor)
    add(workspace and workspace.monitor)
    return list
  end,
  -- Mirrors Hyprland 0.56.2: mapped windows on the queried workspace, filtered
  -- by floating when that key is set. The suite only has one workspace fixture.
  get_windows = function(filters)
    local list = {}
    if not workspace then
      return list
    end
    filters = filters or {}
    for _, win in ipairs(workspace.clients or {}) do
      if filters.floating == nil or win.floating == filters.floating then
        table.insert(list, win)
      end
    end
    return list
  end,
  exec_scheduled_prop_refresh_immediately = function() end,
  dsp = {
    window = {
      move = function(opts)
        table.insert(moves, opts)
        if opts.window and opts.x then
          opts.window.at = { x = opts.x, y = opts.y }
        end
        return opts
      end,
    },
  },
  dispatch = function() end,
}

dofile(os.getenv("OMARCHY_PATH") .. "/default/hypr/bootstrap.lua")
require("default.hypr.qconsole")

local function current()
  return rules[#rules]
end

local function gaps()
  local g = current().gaps_out
  return g.top, g.right, g.bottom, g.left
end

-- Config loads before the outputs are up, so the first pass has no monitor to
-- read. It still has to leave a rule behind, or the console would open unseeded.
assert(#rules > 0, "console is ruled even before a monitor can be read")
assert(current().on_created_empty:find("^%[workspace special:scratchpad silent%] omarchy%-agent"),
  "the seed is the default agent, pinned to the console rather than trusting the spawn to inherit it")
assert(current().workspace == "special:scratchpad")

local function rescale(height, scale, bar)
  monitor = { width = 1920, height = height, scale = scale, transform = 0, reserved = { top = bar, bottom = 0, left = 0, right = 0 } }
  handlers["monitor.layout_changed"]()
  return current().gaps_out.bottom
end

-- Same panel, same logical size, different scale: the console must not care.
assert(rescale(1080, 1, 40) == 520, "half of a 1080p work area, unscaled")
assert(rescale(2160, 2, 40) == 520, "the same half once the monitor is scaled 2x")
assert(rescale(2160, 1.5, 40) == 700, "and at a fractional scale")

-- The bar is already out of the work area; counting it twice would push the
-- console short.
assert(rescale(1440, 1, 0) == 720, "a monitor with nothing reserved")

local final = current()
assert(final.on_created_empty:find("omarchy%-agent"), "refitting keeps the console seeded")
assert(final.no_border == true, "the console drops the active window border")

-- A monitor that cannot be read must not wipe the last good rule.
local before = current().gaps_out.bottom
monitor = nil
handlers["monitor.layout_changed"]()
assert(current().gaps_out.bottom == before, "an absent monitor leaves the console as it was")

-- A monitor handle outliving its output answers nil to everything, which is
-- what a layout change looks like mid-flight. Reading height or reserved off
-- that would throw, so the scale guard has to catch it first.
local expired = setmetatable({}, { __index = function() return nil end })
monitor = expired
handlers["monitor.layout_changed"]()
assert(current().gaps_out.bottom == before, "an expired monitor handle is not read to pieces")

-- Refitting to the size it already is would still cost a state refresh, and
-- monitor.focused fires on every hop between screens.
monitor = { width = 2560, height = 1440, scale = 1, transform = 0, reserved = { top = 0, bottom = 0, left = 0, right = 0 } }
handlers["monitor.layout_changed"]()
local written = #rules
handlers["monitor.focused"]()
handlers["monitor.layout_changed"]()
assert(#rules == written, "refitting to the same size does not rewrite the rule")

-- A centered 2:1 panel, not a full-width drop-down.
monitor = { width = 1920, height = 1080, scale = 1, transform = 0, reserved = { top = 0, bottom = 0, left = 0, right = 0 } }
handlers["monitor.layout_changed"]()
local top, right, bottom, left = gaps()
assert(top == 0 and left == 420 and right == 420 and bottom == 540, "16:9 leaves a 1080x540 panel")

local dell = { name = "DP-1", x = 1920, y = 0, width = 6144, height = 2560, scale = 1, transform = 0, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
monitor = dell
handlers["monitor.layout_changed"]()
top, right, bottom, left = gaps()
assert(left == 1807 and right == 1807 and bottom == 1265, "the same 2:1 panel on 6K")

-- Same logical box at scale 2x (physical 12288x5120): scale does not change the
-- panel's logical size.
monitor = { name = "DP-1", width = 12288, height = 5120, scale = 2, transform = 0, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
handlers["monitor.layout_changed"]()
top, right, bottom, left = gaps()
assert(left == 1807 and right == 1807 and bottom == 1265, "the 6K box is in logical pixels")

-- Same height, different width: the sides have to move even though the bottom
-- gap is identical, so the cache cannot key on height alone.
monitor = { width = 2560, height = 1440, scale = 1, transform = 0, reserved = { top = 0, bottom = 0, left = 0, right = 0 } }
handlers["monitor.layout_changed"]()
written = #rules
monitor = { width = 3440, height = 1440, scale = 1, transform = 0, reserved = { top = 0, bottom = 0, left = 0, right = 0 } }
handlers["monitor.layout_changed"]()
assert(#rules == written + 1, "a same-height ultrawide hop still rewrites the sides")
top, right, bottom, left = gaps()
assert(left == 1000 and right == 1000 and bottom == 720, "3440x1440 leaves a 1440x720 box")

-- A panel wider than the screen is just the screen: a portrait monitor has no
-- room for a 2:1 box and falls back to the full width rather than a negative gap.
monitor = { width = 1080, height = 1920, scale = 1, transform = 0, reserved = { top = 0, bottom = 0, left = 0, right = 0 } }
handlers["monitor.layout_changed"]()
top, right, bottom, left = gaps()
assert(left == 0 and right == 0 and bottom == 960, "a portrait monitor keeps the full width")

-- A monitor turned on its side still reports the panel's own pixels, so the
-- work area has to be turned with it. Measured against Hyprland 0.56.2: a
-- rotated 1920x1080 lays its windows out in 1080x1920 while width and height
-- still read 1920 and 1080. Quarter turns are the odd transforms; a half turn
-- leaves the shape alone.
monitor = { width = 1920, height = 1080, scale = 1, transform = 1, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
handlers["monitor.layout_changed"]()
top, right, bottom, left = gaps()
assert(left == 0 and right == 0 and bottom == 945, "a quarter-turned monitor is sized portrait")

monitor = { width = 1920, height = 1080, scale = 1, transform = 3, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
handlers["monitor.layout_changed"]()
top, right, bottom, left = gaps()
assert(left == 0 and right == 0 and bottom == 945, "and so is the other quarter turn")

monitor = { width = 1920, height = 1080, scale = 1, transform = 2, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
handlers["monitor.layout_changed"]()
top, right, bottom, left = gaps()
assert(left == 435 and right == 435 and bottom == 525, "a half turn is still landscape")

-- Special workspaces open on the monitor they are toggled on, not on whichever
-- output was focused when the rule was last written. Opening on 1080p after a
-- 6K fit has to resize the box.
local acer = { name = "HDMI-A-1", x = 0, y = 0, width = 1920, height = 1080, scale = 1, transform = 0, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
monitor = dell
handlers["monitor.layout_changed"]()
handlers["workspace.special_active"]({ name = "special:scratchpad" }, acer)
top, right, bottom, left = gaps()
assert(left == 435 and right == 435 and bottom == 525, "opening on 1080p after a 6K fit resizes the box")

-- follow_mouse onto another output while the console is already showing must
-- not steal the rule; that is what oversized the open console after a hop.
workspace = { name = "special:scratchpad", visible = true, monitor = acer, windows = 1, clients = { { floating = false } } }
monitor = dell
written = #rules
handlers["monitor.focused"](dell)
assert(#rules == written, "focus on another output does not rewrite an open console")

-- The output the console is showing on can go away mid-layout-change. Its
-- handle then answers nil to everything, and preferring it blindly would leave
-- the console stranded at the gaps of the monitor that is gone. The rule is
-- still the smaller one here, so only refitting on the remaining output can
-- satisfy this.
workspace = { name = "special:scratchpad", visible = true, monitor = expired, windows = 1, clients = { { floating = false } } }
monitor = dell
handlers["monitor.layout_changed"]()
top, right, bottom, left = gaps()
assert(left == 1807 and right == 1807 and bottom == 1265,
  "a console whose output vanished refits on the monitor that is still there")

-- Back onto the 1080p panel for the window-count checks below.
workspace = { name = "special:scratchpad", visible = true, monitor = acer, windows = 1, clients = { { floating = false } } }
monitor = acer
handlers["monitor.layout_changed"]()
top, right, bottom, left = gaps()
assert(left == 435 and right == 435 and bottom == 525, "and refits again once it is back on a live output")

-- One tiled window reads as a console and keeps the panel. A second tiled app
-- has turned the scratchpad into a workspace, and a workspace wants the whole
-- width.
workspace.clients = { { floating = false }, { floating = false } }
workspace.windows = 2
handlers["window.open"]()
top, right, bottom, left = gaps()
assert(left == 0 and right == 0, "a second tiled app on the scratchpad restores the full width")
assert(bottom == 525, "and the console keeps its half-height drop")

workspace.clients = { { floating = false }, { floating = false }, { floating = false } }
workspace.windows = 3
written = #rules
handlers["window.open"]()
assert(#rules == written, "a third tiled app changes nothing that is already full width")

workspace.clients = { { floating = false } }
workspace.windows = 1
handlers["window.destroy"]()
top, right, bottom, left = gaps()
assert(left == 435 and right == 435, "closing back down to one tiled window recenters the panel")

-- A floating window opening on the scratchpad makes the mapped total 2,
-- which is what used to stretch the panel; only the tiled count should.
workspace.clients = { { floating = false }, { floating = true } }
workspace.windows = 2
handlers["window.open"]()
top, right, bottom, left = gaps()
assert(left == 435 and right == 435, "a floating utility on the scratchpad keeps the panel")

-- Super+Shift+1 / Super+Alt+S are moves, not opens or destroys. The window is
-- already on the destination workspace when move_to_workspace fires.
workspace.clients = { { floating = false }, { floating = false } }
workspace.windows = 2
handlers["window.open"]()
top, right, bottom, left = gaps()
assert(left == 0 and right == 0, "two tiled apps still stretch before a move")

workspace.clients = { { floating = false } }
workspace.windows = 1
handlers["window.move_to_workspace"]()
top, right, bottom, left = gaps()
assert(left == 435 and right == 435, "moving a tiled window off the open console recenters the panel")

workspace.clients = { { floating = false }, { floating = false } }
workspace.windows = 2
handlers["window.move_to_workspace"]()
top, right, bottom, left = gaps()
assert(left == 0 and right == 0, "moving a tiled window onto the open console restores the full width")

-- Tiling a float is not an open or a destroy. It re-applies window rules, so
-- window.update_rules is the event Super+T and Super+O ride.
workspace.clients = { { floating = false }, { floating = true } }
workspace.windows = 2
handlers["window.open"]()
workspace.clients = { { floating = false }, { floating = false } }
workspace.windows = 2
handlers["window.update_rules"]()
top, right, bottom, left = gaps()
assert(left == 0 and right == 0, "tiling a float on the open console restores the full width")

workspace.clients = { { floating = false }, { floating = true } }
workspace.windows = 2
handlers["window.update_rules"]()
top, right, bottom, left = gaps()
assert(left == 435 and right == 435, "floating a tiled window on the open console recenters the panel")

-- An empty scratchpad is about to be seeded with a single agent, so it is sized
-- as a console rather than as a workspace.
workspace.clients = {}
workspace.windows = 0
handlers["window.destroy"]()
top, right, bottom, left = gaps()
assert(left == 435 and right == 435, "an empty console is still a console")

-- A hidden console is refitted on its way back in, so the count does not have to
-- be chased while it is off screen; every window on the desktop would otherwise
-- rewrite the rule.
workspace = { name = "special:scratchpad", visible = false, monitor = acer, clients = { { floating = false }, { floating = false }, { floating = false }, { floating = false } }, windows = 4 }
monitor = dell
written = #rules
handlers["window.open"]()
assert(#rules == written, "a window opening elsewhere does not rewrite a hidden console")

-- A scratchpad nothing has opened yet has no workspace to read at all, and is
-- sized as the console the seed is about to put a single agent into.
workspace = nil
monitor = { width = 1920, height = 1080, scale = 1, transform = 0, reserved = { top = 0, bottom = 0, left = 0, right = 0 } }
handlers["monitor.layout_changed"]()
top, right, bottom, left = gaps()
assert(left == 420 and right == 420 and bottom == 540, "a scratchpad that does not exist yet is sized as a console")

-- Floating windows keep global coordinates across a special-workspace hop, and
-- Hyprland only clamps them onto the destination a little each toggle. Remap
-- from the last shown work area in one shot instead, keeping the same place
-- relative to the work area: centered stays centered, a corner stays a corner.
-- The tiled window carries geometry too, so a remap that forgot to filter on
-- floating would move it and show up in the move counts below.
local tiled = { address = "0xtiled", floating = false, at = { x = 100, y = 100 }, size = { x = 400, y = 300 } }
local float = { address = "0xfloat", floating = true, at = { x = 535, y = 80 }, size = { x = 200, y = 100 } }
workspace = { name = "special:scratchpad", visible = true, monitor = acer, windows = 2, clients = { tiled, float } }
monitor = acer
moves = {}
handlers["workspace.special_active"]({ name = "special:scratchpad" }, acer)
assert(#moves == 0, "showing on the output the console already had does not move floats")

handlers["workspace.special_active"]({ name = "special:scratchpad" }, dell)
workspace.monitor = dell
assert(#moves == 1, "a hop to another output moves the float once, and only the float")
assert(moves[1].x == 3768 and moves[1].y == 157, "the float keeps its place relative to the work-area center")

local after_hop = #moves
handlers["workspace.special_active"]({ name = "special:scratchpad" }, dell)
assert(#moves == after_hop, "a second toggle on the same output does not creep the float")

-- A second tiled app stretching the panel must not throw the float around.
workspace.clients = { tiled, { floating = false }, float }
workspace.windows = 3
handlers["window.open"]()
assert(#moves == after_hop, "opening a tiled window on the open console does not move floats")
top, right, bottom, left = gaps()
assert(left == 0 and right == 0, "two tiled apps still restore the full width after a hop")

-- Back to one tiled window so the reverse hop still remaps the float, not the tiled window.
workspace.clients = { tiled, float }
workspace.windows = 2
handlers["window.destroy"]()
assert(#moves == after_hop, "closing back to one tiled window does not move floats")

-- Hyprland origin-shifts before move_to_monitor the same way it does before
-- special_active. A window near the far edge can still sit on the source after
-- that shift, so the live coordinate is not the source offset by itself.
float.at = { x = float.at.x - dell.x + acer.x, y = float.at.y - dell.y + acer.y }
handlers["workspace.move_to_monitor"]({ name = "special:scratchpad" }, acer)
workspace.monitor = acer
assert(#moves == after_hop + 1, "moving the open console to another output remaps the float")
assert(moves[#moves].x == 534 and moves[#moves].y == 79, "an origin-shifted monitor move still maps from the last output")

-- A centered float stays centered on a different-sized output.
float.at = { x = 523, y = 255 }
float.size = { x = 875, y = 600 }
moves = {}
handlers["workspace.special_active"]({ name = "special:scratchpad" }, acer)
handlers["workspace.special_active"]({ name = "special:scratchpad" }, dell)
workspace.monitor = dell
assert(#moves == 1, "a centered hop moves once")
assert(moves[1].x == 4557 and moves[1].y == 995, "a centered float stays centered on the other output")

-- Top-left of the work area stays top-left.
handlers["workspace.special_active"]({ name = "special:scratchpad" }, acer)
workspace.monitor = acer
float.at = { x = 0, y = 30 }
float.size = { x = 200, y = 100 }
moves = {}
handlers["workspace.special_active"]({ name = "special:scratchpad" }, dell)
workspace.monitor = dell
assert(#moves == 1, "a corner hop moves once")
assert(moves[1].x == 1920 and moves[1].y == 30, "a top-left float stays in the top-left corner")

-- A placement that scales past the smaller screen is clamped onto it in that
-- same move, not walked there over later toggles. Park on the wide output first
-- so the overflowing coordinates are read against that work area.
handlers["workspace.special_active"]({ name = "special:scratchpad" }, dell)
workspace.monitor = dell
-- Origin-shifted toward the narrower output, but still geometrically on the wide one.
float.at = { x = 4207, y = 130 }
float.size = { x = 875, y = 600 }
moves = {}
handlers["workspace.special_active"]({ name = "special:scratchpad" }, acer)
workspace.monitor = acer
assert(#moves == 1, "an overflowing hop still moves once")
assert(moves[1].x == 834 and moves[1].y == 53, "the overflow is clamped onto the destination work area")

-- A float in the dimmed margin stays in the margin rather than being sucked
-- into the panel, as long as it still fits on the destination.
float.at = { x = 50, y = 80 }
float.size = { x = 200, y = 100 }
moves = {}
handlers["workspace.special_active"]({ name = "special:scratchpad" }, acer)
handlers["workspace.special_active"]({ name = "special:scratchpad" }, dell)
workspace.monitor = dell
assert(#moves == 1, "a margin float hops once")
assert(moves[1].x == 2092 and moves[1].y == 157, "a margin float stays in the dimmed margin on the new output")

-- Mixed DPI: window.at is layout pixels, so the same logical work area at
-- scale 2x lands at the same layout point as scale 1x.
local dell2x = { name = "DP-1-2x", x = 1920, y = 0, width = 12288, height = 5120, scale = 2, transform = 0, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
handlers["workspace.special_active"]({ name = "special:scratchpad" }, acer)
workspace.monitor = acer
float.at = { x = 535, y = 80 }
float.size = { x = 200, y = 100 }
moves = {}
handlers["workspace.special_active"]({ name = "special:scratchpad" }, dell2x)
assert(#moves == 1, "a scaled hop moves once")
assert(moves[1].x == 3768 and moves[1].y == 157, "a mixed-DPI hop uses the logical work area, not physical pixels")

-- Hyprland origin-shifts floats onto the destination before special_active.
-- A hop that already did that must still land on the analogous spot, not
-- measure the shifted coordinate against the old output.
handlers["workspace.special_active"]({ name = "special:scratchpad" }, acer)
workspace.monitor = acer
float.at = { x = 2455, y = 80 }
float.size = { x = 200, y = 100 }
moves = {}
handlers["workspace.special_active"]({ name = "special:scratchpad" }, dell)
assert(#moves == 1, "an already-shifted hop still moves once")
assert(moves[1].x == 3768 and moves[1].y == 157, "an origin-shifted float is measured in the last output's space")

-- Opposite corners, origin-shifted: the far edge can still sit on the source
-- after a hop toward a smaller origin, and must not be read as a smaller
-- fraction. x and y are mapped independently, so the two opposite corners pin
-- both ends of both axes; the mixed corners would say nothing more.
local function corner(addr, x, y)
  return { address = addr, floating = true, at = { x = x, y = y }, size = { x = 875, y = 600 } }
end
local tl = corner("0xtl", 1920, 30)
local br = corner("0xbr", 7189, 1960)
workspace.clients = { tiled, tl, br }
workspace.windows = 3
handlers["workspace.special_active"]({ name = "special:scratchpad" }, dell)
workspace.monitor = dell
for _, win in ipairs({ tl, br }) do
  win.at = { x = win.at.x - dell.x + acer.x, y = win.at.y - dell.y + acer.y }
end
handlers["workspace.special_active"]({ name = "special:scratchpad" }, acer)
workspace.monitor = acer
assert(tl.at.x == 0 and tl.at.y == 30, "top-left stays top-left on the narrower output")
assert(br.at.x == 1045 and br.at.y == 480, "bottom-right stays bottom-right on the narrower output")

-- Hop back (again origin-shifted) must not walk the far-edge windows inward.
for _, win in ipairs({ tl, br }) do
  win.at = { x = win.at.x - acer.x + dell.x, y = win.at.y - acer.y + dell.y }
end
handlers["workspace.special_active"]({ name = "special:scratchpad" }, dell)
workspace.monitor = dell
assert(tl.at.x == 1920 and tl.at.y == 30, "top-left round-trips")
assert(br.at.x == 7189 and br.at.y == 1960, "bottom-right round-trips without drifting")

-- Three outputs, one with a negative origin. Hops are pairwise, so skipping
-- the middle monitor is the same mapping as any other hop.
local left = { name = "DP-left", x = -1920, y = 0, width = 1920, height = 1080, scale = 1, transform = 0, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
local right = { name = "DP-right", x = 8064, y = 0, width = 1920, height = 1080, scale = 1, transform = 0, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
float.size = { x = 200, y = 100 }
handlers["workspace.special_active"]({ name = "special:scratchpad" }, dell)
workspace.monitor = dell
workspace.clients = { tiled, float }
-- Origin-shifted toward the negative-x output, still on the wide source.
float.at = { x = 4024, y = 30 }
handlers["workspace.special_active"]({ name = "special:scratchpad" }, left)
workspace.monitor = left
assert(float.at.x == -200 and float.at.y == 30, "a far-edge float lands on the far edge of a negative-origin output")

float.at = { x = float.at.x - left.x + right.x, y = float.at.y - left.y + right.y }
handlers["workspace.special_active"]({ name = "special:scratchpad" }, right)
workspace.monitor = right
assert(float.at.x == 9784 and float.at.y == 30, "skipping the middle output still keeps the far edge")

-- Stacked: a bottom-edge float must not be read as a smaller fraction when the
-- destination sits above at a negative y and the origin shift is smaller than
-- the source height.
local above = { name = "DP-above", x = 1920, y = -1080, width = 1920, height = 1080, scale = 1, transform = 0, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
handlers["workspace.special_active"]({ name = "special:scratchpad" }, dell)
workspace.monitor = dell
-- Origin-shifted up, still on the tall source.
float.at = { x = 1920, y = 1380 }
handlers["workspace.special_active"]({ name = "special:scratchpad" }, above)
workspace.monitor = above
assert(float.at.x == 1920 and float.at.y == -100, "a bottom-edge float lands on the bottom edge of a negative-y output")

-- A quarter-turned destination uses the swapped layout box, the same way the panel does.
local portrait = { name = "DVI-portrait", x = 1920, y = 0, width = 1920, height = 1080, scale = 1, transform = 1, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
handlers["workspace.special_active"]({ name = "special:scratchpad" }, acer)
workspace.monitor = acer
float.at = { x = 1720, y = 30 }
handlers["workspace.special_active"]({ name = "special:scratchpad" }, portrait)
workspace.monitor = portrait
assert(float.at.x == 2800 and float.at.y == 30, "top-right on landscape is top-right on a quarter-turned output")

-- Scale mutates the live handle in place. Remap from the snapshot so floats
-- keep their place on the new logical work area.
local scaled = { name = "eDP-1", x = 0, y = 0, width = 1920, height = 1080, scale = 1, transform = 0, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
workspace.clients = { tiled, float }
workspace.windows = 2
workspace.visible = true
workspace.monitor = scaled
monitor = scaled
handlers["workspace.special_active"]({ name = "special:scratchpad" }, scaled)
float.at = { x = 535, y = 80 }
float.size = { x = 200, y = 100 }
moves = {}
handlers["monitor.layout_changed"]()
assert(#moves == 0, "a layout change that does not alter this output leaves floats")
scaled.scale = 2
handlers["monitor.layout_changed"]()
assert(#moves == 1, "a scale change remaps the float once")
assert(float.at.x == 236 and float.at.y == 51, "the float keeps its place on the new logical work area")
local after_scale = #moves
handlers["monitor.layout_changed"]()
assert(#moves == after_scale, "a second layout change at the same scale does not creep")

-- Hyprland can put the workspace on the destination before special_active.
-- layout_changed must hop from the post-scale snapshot, or the floats stay
-- on the old output while the panel refits on the new one.
workspace.monitor = dell
moves = {}
handlers["monitor.layout_changed"]()
assert(float.at.x == 3765 and float.at.y == 154, "a hop after a scale change still maps from the scaled work area")

-- Scaling down enlarges the logical work area. A scale-up can look fine because
-- the compositor clamps windows inward; going the other way has to push them out.
local grow = { name = "eDP-grow", x = 0, y = 0, width = 1920, height = 1080, scale = 2, transform = 0, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
workspace.monitor = grow
monitor = grow
handlers["workspace.special_active"]({ name = "special:scratchpad" }, grow)
float.at = { x = 236, y = 51 }
float.size = { x = 200, y = 100 }
grow.scale = 1
handlers["monitor.layout_changed"]()
assert(float.at.x == 534 and float.at.y == 78, "scaling down pushes the float out onto the larger work area")

-- Same path with 1.3 and corner windows, matching a full-work-area hop.
local small = { name = "HDMI-small", x = 0, y = 0, width = 1920, height = 1080, scale = 1, transform = 0, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
local ctl = corner("0xctl", 0, 30)
local cbr = corner("0xcbr", 1045, 480)
workspace.clients = { tiled, ctl, cbr }
workspace.windows = 3
workspace.monitor = small
monitor = small
handlers["workspace.special_active"]({ name = "special:scratchpad" }, small)
ctl.at, cbr.at = { x = 0, y = 30 }, { x = 1045, y = 480 }
small.scale = 1.3
handlers["monitor.layout_changed"]()
assert(ctl.at.x == 0 and ctl.at.y == 30, "top-left stays top-left after a 1.3 scale")
assert(cbr.at.x == 601 and cbr.at.y == 230, "bottom-right stays bottom-right after a 1.3 scale")
small.scale = 1
handlers["monitor.layout_changed"]()
assert(ctl.at.x == 0 and ctl.at.y == 30, "top-left stays top-left after scaling back down")
assert(cbr.at.x == 1043 and cbr.at.y == 478, "bottom-right is pushed out after scaling back down")
ctl.at, cbr.at = { x = 0, y = 30 }, { x = 1045, y = 480 }
small.scale = 1.3
handlers["monitor.layout_changed"]()
workspace.monitor = dell
handlers["monitor.layout_changed"]()
assert(ctl.at.x == 1920 and ctl.at.y == 30, "top-left hops to the large output after a 1.3 scale")
assert(cbr.at.x == 7180 and cbr.at.y == 1952, "bottom-right hops to the large output after a 1.3 scale")

-- Hyprland can mark the scratchpad visible on the destination and re-apply
-- rules before special_active. The panel then refits on the new output while
-- floats keep the previous at, which is what a scale-then-hop looks like if
-- we wait for special_active.
local wide = { name = "DP-wide", x = 0, y = 0, width = 6144, height = 2560, scale = 1, transform = 0, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
local narrow = { name = "HDMI-narrow", x = 6144, y = 0, width = 1920, height = 1080, scale = 1, transform = 0, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
local ntl = corner("0xntl", 6144, 30)
local nbr = corner("0xnbr", 7189, 480)
workspace.clients = { tiled, ntl, nbr }
workspace.windows = 3
workspace.monitor = narrow
monitor = narrow
handlers["workspace.special_active"]({ name = "special:scratchpad" }, narrow)
ntl.at, nbr.at = { x = 6144, y = 30 }, { x = 7189, y = 480 }
narrow.scale = 1.3
handlers["monitor.layout_changed"]()
assert(ntl.at.x == 6144 and ntl.at.y == 30, "top-left stays top-left after scaling the right-hand output")
assert(nbr.at.x == 6745 and nbr.at.y == 230, "bottom-right stays bottom-right after scaling the right-hand output")
for _, win in ipairs({ ntl, nbr }) do
  win.at = { x = win.at.x - narrow.x + wide.x, y = win.at.y - narrow.y + wide.y }
end
workspace.monitor = wide
monitor = wide
handlers["window.update_rules"]()
assert(ntl.at.x == 0 and ntl.at.y == 30, "a rules re-apply after a scale hop still keeps top-left")
assert(nbr.at.x == 5260 and nbr.at.y == 1952, "a rules re-apply after a scale hop still keeps bottom-right")
local after_rules = { ntl = { ntl.at.x, ntl.at.y }, nbr = { nbr.at.x, nbr.at.y } }
handlers["workspace.special_active"]({ name = "special:scratchpad" }, wide)
assert(ntl.at.x == after_rules.ntl[1] and ntl.at.y == after_rules.ntl[2], "special_active after that hop does not creep top-left")
assert(nbr.at.x == after_rules.nbr[1] and nbr.at.y == after_rules.nbr[2], "special_active after that hop does not creep bottom-right")

-- Scale-up then hop: Hyprland origin-shifts the floats and tags window.monitor
-- with the destination, but may still call special_active with the scaled output.
handlers["workspace.special_active"]({ name = "special:scratchpad" }, narrow)
workspace.monitor = narrow
for _, win in ipairs({ ntl, nbr }) do
  win.monitor = narrow
end
ntl.at, nbr.at = { x = 6144, y = 30 }, { x = 7189, y = 480 }
narrow.scale = 1.25
handlers["monitor.layout_changed"]()
for _, win in ipairs({ ntl, nbr }) do
  win.at = { x = win.at.x - narrow.x + wide.x, y = win.at.y - narrow.y + wide.y }
  win.monitor = wide
end
workspace.monitor = narrow
monitor = wide
handlers["workspace.special_active"]({ name = "special:scratchpad" }, narrow)
assert(ntl.at.x == 0 and ntl.at.y == 30, "a scale-up hop still keeps top-left when special_active names the old output")
assert(nbr.at.x == 5269 and nbr.at.y == 1960, "a scale-up hop still keeps bottom-right when special_active names the old output")

-- Unplug the output the open console is on. The remembered handle dies in
-- place (nil to every field); layout_changed must refit on a remaining output
-- without touching floats, and showing there afterwards must not throw.
local dying = { name = "DP-dying", x = 1920, y = 0, width = 6144, height = 2560, scale = 1, transform = 0, reserved = { top = 30, bottom = 0, left = 0, right = 0 } }
workspace.clients = { tiled, float }
workspace.windows = 2
workspace.visible = true
workspace.monitor = dying
monitor = dying
handlers["workspace.special_active"]({ name = "special:scratchpad" }, dying)
local dying_x, dying_y = dying.x, dying.y
float.at = { x = 4555, y = 995 }
float.size = { x = 875, y = 600 }
moves = {}
for k in pairs(dying) do
  dying[k] = nil
end
setmetatable(dying, { __index = function() return nil end })
monitor = acer
handlers["monitor.layout_changed"]()
top, right, bottom, left = gaps()
assert(left == 435 and right == 435 and bottom == 525, "unplugging the console's output refits on a remaining monitor")
assert(#moves == 0, "unplug does not remap floats from a dead handle")
assert(float.at.x == 4555 and float.at.y == 995, "the float keeps its last coordinates through the unplug")
float.at = { x = 4555 - dying_x + acer.x, y = 995 - dying_y + acer.y }
handlers["workspace.move_to_monitor"]({ name = "special:scratchpad" }, acer)
workspace.monitor = acer
assert(float.at.x == 522 and float.at.y == 255, "relocating onto a remaining output maps from the last snapshot")
moves = {}
handlers["workspace.special_active"]({ name = "special:scratchpad" }, acer)
assert(#moves == 0, "a later toggle on that output is a same-output no-op")

-- Changing a monitor's scale rewrites ~/.config/hypr/monitors.lua, and Hyprland
-- reloads the config when that file changes. bootstrap.lua drops every
-- default.hypr module from package.loaded, so this file re-runs with the
-- console's windows still placed but no memory of the output they are placed
-- on, and the hop after it has to land where a hop without a reload does.
-- The console is parked on acer while the pointer sits on dell, so recovering
-- the output from hl.get_active_monitor() instead of the workspace would read
-- the float's acer coordinates against dell's work area.
workspace = { name = "special:scratchpad", visible = false, monitor = acer, windows = 2, clients = { tiled, float } }
monitor = dell
float.at = { x = 535, y = 80 }
float.size = { x = 200, y = 100 }
package.loaded["default.hypr.qconsole"] = nil
require("default.hypr.qconsole")
moves = {}
float.at = { x = float.at.x - acer.x + dell.x, y = float.at.y - acer.y + dell.y }
float.monitor = dell
handlers["workspace.special_active"]({ name = "special:scratchpad" }, dell)
workspace.monitor = dell
assert(#moves == 1, "the first hop after a config reload remaps the float")
assert(float.at.x == 3768 and float.at.y == 157,
  "a reload takes the console's output back off the workspace, so the hop maps from it")

-- Nothing about the reload makes a later toggle on the same output a remap.
float.monitor = nil
moves = {}
handlers["workspace.special_active"]({ name = "special:scratchpad" }, dell)
assert(#moves == 0, "a same-output toggle after that hop does not creep the float")

-- A console that has never been opened has no workspace to read, so a reload
-- has no output to recover and is just a boot: still ruled, still sized on the
-- output that would show it next.
workspace = nil
monitor = acer
package.loaded["default.hypr.qconsole"] = nil
require("default.hypr.qconsole")
top, right, bottom, left = gaps()
assert(left == 435 and right == 435 and bottom == 525, "a reload with no scratchpad to recover still rules the console")

-- window.close still counts the window on its way out, so a refit from it reads
-- one too many and strands the console at full width. Membership is chased on
-- open, destroy, move, and rule updates instead.
assert(handlers["window.close"] == nil, "window.close counts the window on its way out")
assert(handlers["window.move_to_workspace"] ~= nil, "a move onto or off the open console recounts")
assert(handlers["window.update_rules"] ~= nil, "a float toggle recounts by re-applying rules")
LUA
pass "the console is a centered panel until a second tiled app joins it"
