-- lib/gfx.lua
-- CC:Graphics-backed data-visualization helpers for FCS-10's SCADA-style
-- screens: bar-meter gauges, small trend arrows, and status LEDs, all drawn
-- as real sub-character pixels instead of plain text/ASCII glyphs. Every
-- drawing function here has a graceful plain-text fallback baked in, so a
-- call site never needs its own if/else - a node with CC:Graphics missing,
-- disabled, or erroring just gets today's text rendering back, unchanged.
--
-- WHY A SEPARATE MODULE FROM lib/os_shell.lua: os_shell.lua is scoped to
-- shared CHROME (desktop/header/theme/frame) - the same furniture every
-- screen uses regardless of what data it shows. This module is scoped to
-- DATA-VISUALIZATION WIDGETS used inside a node's own SCADA/status screens
-- (which metric gets a bar, what a trend arrow looks like) - a different
-- concern, kept in its own file the same way this project already keeps
-- config/secnet/os_shell/rbac/md5 each in their own single-purpose file.
--
-- VERIFICATION STATUS - READ BEFORE TRUSTING ANY OF THIS IN-GAME: this
-- module is built against CC:Graphics' own CurseForge listing (which names
-- term.setGraphicsMode/setPixel/drawPixels/getPixels/setFrozen as present)
-- plus CraftOS-PC's own documented graphics-mode API, which CC:Graphics
-- claims parity with but which has NOT been independently confirmed against
-- CC:Graphics' own source/docs (no CC:Graphics-specific documentation could
-- be found). Treat every numeric/behavioral assumption below (the 6x/9x
-- pixel-per-character ratio, drawPixels' solid-fill call shape, whether
-- setFrozen actually prevents visible tearing) as UNVERIFIED until checked
-- in-game - matching this project's own established rule (see
-- lib/os_shell.lua's CP437 lesson) of never asserting an unverified engine
-- fact as confirmed. gfx.available() existing and returning true only means
-- "the functions exist", not "they behave exactly as documented here."
--
-- COLOR ARGUMENT NOTE: term.setPixel/term.drawPixels' single-color solid-
-- fill form take a plain `colors.*` constant directly in 16-color graphics
-- mode (mode 1) - the same argument CC:Tweaked's term.setTextColor/
-- setBackgroundColor already take everywhere else in this codebase. This
-- module deliberately never uses drawPixels' per-pixel STRING/table row
-- form (which needs a raw 0-15 palette index, not a colors.* bitmask value,
-- and would need colors.toBlit() conversion) - everything here is either a
-- solid-color rectangle (drawBarMeter's fill/track) or built from individual
-- setPixel calls (drawTrendArrow/drawStatusLed), both of which take
-- colors.* constants directly, so no index conversion is needed anywhere in
-- this file.

local gfx = {}

-- ---------------------------------------------------------------------------
-- Capability detection - checked once, cached. pcall-guarded throughout this
-- file (not just here) since none of this has been proven against a live
-- CC:Graphics install yet.
-- ---------------------------------------------------------------------------
local capChecked, capAvailable = false, false
local function available()
    if capChecked then
        return capAvailable
    end
    capChecked = true
    capAvailable = type(term.setGraphicsMode) == "function"
        and type(term.drawPixels) == "function"
        and type(term.setPixel) == "function"
    return capAvailable
end
gfx.available = available

-- Pixel-grid ratio - per CraftOS-PC's docs, graphics mode is exactly 6x the
-- text terminal's width and 9x its height, in pixels. UNVERIFIED for
-- CC:Graphics specifically - see header.
local PX_PER_COL, PX_PER_ROW = 6, 9

-- ---------------------------------------------------------------------------
-- Mode lifecycle - gfx.beginFrame()/gfx.endFrame() bracket ONE screen's draw
-- pass. Every node's central draw() dispatcher (the single place that picks
-- which screen function runs) calls gfx.endFrame() unconditionally as its
-- very first action, BEFORE branching to whichever screen draws next - so
-- no matter what ran last tick, every tick starts from a known text-mode
-- state. A screen that wants graphics calls gfx.beginFrame() itself right
-- after clearing. This means a crash mid-gauge-draw (still caught by the
-- node's own outer safeDraw()/safeRedraw() pcall, unrelated to this module)
-- can leave the terminal in graphics mode for at most one tick - the very
-- next scheduled redraw self-heals via that same dispatcher-level
-- gfx.endFrame() call, so nothing ever gets permanently stuck.
-- ---------------------------------------------------------------------------
local inFrame = false

-- Returns true if graphics mode is actually active (caller should only draw
-- pixels if this returns true; otherwise fall back to text).
function gfx.beginFrame()
    if not available() then
        return false
    end
    local ok = pcall(term.setGraphicsMode, 1)
    if not ok then
        return false
    end
    inFrame = true
    pcall(term.setFrozen, true) -- batch draws, flip once at endFrame - avoids visible tearing
    return true
end

-- Always safe to call even if beginFrame was never called or already failed
-- (idempotent no-op) - see gfx.available()'s doc comment above for why every
-- node's dispatcher calls this unconditionally on every tick.
function gfx.endFrame()
    if not inFrame then
        return
    end
    pcall(term.setFrozen, false)
    pcall(term.setGraphicsMode, 0)
    inFrame = false
end

-- ---------------------------------------------------------------------------
-- Bar-meter gauge - a horizontal filled bar sized to a character-cell
-- region (x, y, w, h - same 1-indexed units every other term.* call in this
-- codebase already uses), showing `pct` (0-100, clamped) filled from the
-- left in `fillColor` against a `bgColor` track. Falls back to plain text
-- (`fallbackText`, e.g. "DMG   5.1%") written at (x, y) if graphics mode
-- isn't active - the caller supplies the exact fallback string so this
-- function stays agnostic to each screen's own text formatting convention.
-- ---------------------------------------------------------------------------
function gfx.drawBarMeter(x, y, w, h, pct, fillColor, bgColor, fallbackText)
    if not (inFrame and available()) then
        term.setCursorPos(x, y)
        term.write(fallbackText or "")
        return false
    end

    pct = math.max(0, math.min(100, pct or 0))

    local px = (x - 1) * PX_PER_COL
    local py = (y - 1) * PX_PER_ROW
    local pw = w * PX_PER_COL
    local ph = h * PX_PER_ROW
    local filledW = math.floor(pw * pct / 100 + 0.5)

    local ok = pcall(function()
        term.drawPixels(px, py, bgColor, pw, ph)
        if filledW > 0 then
            term.drawPixels(px, py, fillColor, filledW, ph)
        end
    end)

    if not ok then
        -- drawPixels itself failed despite passing the capability check -
        -- treat as unavailable for the rest of this frame and fall back.
        term.setCursorPos(x, y)
        term.write(fallbackText or "")
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Trend arrow - a small filled triangle inside a SINGLE character cell (so
-- it drops into a column that today holds one ASCII glyph, e.g.
-- supervisor.lua's trendGlyph "^"/"v"/"-", with no layout/column-width
-- change needed). direction: "up" | "down" | "flat". Falls back to the
-- equivalent ASCII character if graphics mode isn't active.
-- ---------------------------------------------------------------------------
local FALLBACK_GLYPH = { up = "^", down = "v", flat = "-" }

-- Per-row pixel spans (inclusive x0-x1, 0-indexed within the 6-wide cell)
-- for each shape, top row first. "up": narrow apex at the top widening to a
-- full-width base at the bottom, one row left blank for visual spacing.
-- "down" is the same rows reversed. "flat": a single mid-height bar.
local ARROW_ROWS = {
    up   = { {2,3}, {1,4}, {0,5}, nil, nil, nil, nil, nil, nil },
    down = { nil, nil, nil, nil, nil, nil, {0,5}, {1,4}, {2,3} },
    flat = { nil, nil, nil, {0,5}, {0,5}, {0,5}, nil, nil, nil },
}

function gfx.drawTrendArrow(x, y, direction, color)
    local rows = ARROW_ROWS[direction]
    if not (inFrame and available() and rows) then
        term.setCursorPos(x, y)
        term.setTextColor(color or (term.getTextColor and term.getTextColor()) or colors.white)
        term.write(FALLBACK_GLYPH[direction] or "-")
        return false
    end

    local px0 = (x - 1) * PX_PER_COL
    local py0 = (y - 1) * PX_PER_ROW

    local ok = pcall(function()
        for rowIdx = 0, PX_PER_ROW - 1 do
            local span = rows[rowIdx + 1]
            if span then
                term.drawPixels(px0 + span[1], py0 + rowIdx, color, span[2] - span[1] + 1, 1)
            end
        end
    end)

    if not ok then
        term.setCursorPos(x, y)
        term.setTextColor(color or colors.white)
        term.write(FALLBACK_GLYPH[direction] or "-")
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Status LED - a small filled square "indicator light" inside a single
-- character cell, standing in for a plain colored letter/word (e.g. a
-- HW PRESENT/ABSENT flag). Falls back to a single colored fallbackChar.
-- ---------------------------------------------------------------------------
function gfx.drawStatusLed(x, y, color, fallbackChar)
    if not (inFrame and available()) then
        term.setCursorPos(x, y)
        term.setTextColor(color or colors.white)
        term.write(fallbackChar or "*")
        return false
    end

    local px = (x - 1) * PX_PER_COL + 1 -- inset by 1px so it reads as a dot, not a full block
    local py = (y - 1) * PX_PER_ROW + 2
    local ok = pcall(term.drawPixels, px, py, color, PX_PER_COL - 2, PX_PER_ROW - 4)

    if not ok then
        term.setCursorPos(x, y)
        term.setTextColor(color or colors.white)
        term.write(fallbackChar or "*")
        return false
    end
    return true
end

return gfx
