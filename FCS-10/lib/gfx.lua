-- lib/gfx.lua
-- CC:Graphics-backed data-visualization helpers for FCS-10's SCADA-style
-- screens: bar-meter gauges, small trend arrows, status LEDs, AND (see
-- gfx.drawText below) a full bitmap-font text renderer, all drawn as real
-- sub-character pixels instead of plain text/ASCII glyphs. Every drawing
-- function here has a graceful plain-text fallback baked in, so a call site
-- never needs its own if/else - a node with CC:Graphics missing, disabled,
-- or erroring just gets today's text rendering back, unchanged.
--
-- WHY drawText EXISTS: CC:Graphics' graphics mode is a whole-screen toggle
-- (confirmed in-game - see VERIFICATION STATUS below and this project's own
-- history) - a screen that enters it can no longer show anything drawn with
-- plain term.write, since only one buffer (text OR graphics) is ever
-- displayed at a time. A screen that wants BOTH real pixel gauges and
-- labels/numbers/headers therefore has to draw literally everything,
-- including every character, as pixels - gfx.drawText is what makes that
-- practical: it renders a string via the small bitmap FONT table below,
-- using the exact same "solid filled rectangle" drawPixels calls already
-- proven to render correctly (gfx.drawBarMeter's gauges were confirmed
-- visible in-game before this function existed), so a caller can build an
-- entire screen out of gfx.drawText/gfx.drawBarMeter calls with no
-- remaining term.write calls at all, and that screen still degrades
-- automatically to today's plain text if CC:Graphics isn't available.
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

-- Diagnostic-only, not used by any drawing function above - reports which
-- specific named functions are/aren't present on `term` right now, so a
-- Network screen (or anywhere else) can show exactly what's missing rather
-- than a single opaque yes/no. Useful precisely because this module's own
-- header notes CC:Graphics' own docs were never found - this is the
-- cheapest way to see what a live install actually exposes.
function gfx.diagnose()
    return {
        available        = available(),
        setGraphicsMode  = type(term.setGraphicsMode) == "function",
        getGraphicsMode  = type(term.getGraphicsMode) == "function",
        setPixel         = type(term.setPixel) == "function",
        drawPixels       = type(term.drawPixels) == "function",
        getPixels        = type(term.getPixels) == "function",
        setFrozen        = type(term.setFrozen) == "function",
    }
end

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
        -- Explicit, not inherited: a caller building a whole screen out of
        -- gfx.* calls (see gfx.drawText's header note) may have last set the
        -- text color for something else entirely (e.g. a label drawn just
        -- before this bar) - fillColor is this bar's own severity color and
        -- must always win here, not bleed over from whatever drew last.
        term.setTextColor(fillColor or colors.white)
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
        term.setTextColor(fillColor or colors.white)
        term.write(fallbackText or "")
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Bitmap font - a classic 5x7 dot-matrix font (uppercase letters, digits,
-- and the punctuation this project's SCADA screens actually use). Each
-- glyph is 5 pixels wide x 7 tall, positioned with a 1px left/top margin
-- inside the standard 6x9 character cell - the blank right column (1px) and
-- the blank top+bottom rows (1px each) are what give adjacent characters/
-- lines their spacing, the same idea as a real terminal font's own advance
-- width. Authored by
-- hand for this module (not lifted from a specific external font file), so
-- treat individual glyph shapes as approximate/legible rather than
-- typographically precise - see VERIFICATION STATUS at the top of this file:
-- like everything else here, actual on-screen appearance is UNCONFIRMED
-- until checked in-game.
--
-- UPPERCASE ONLY, BY DESIGN: gfx.drawText upper-cases every string before
-- looking up glyphs (string.upper) rather than doubling this table's size
-- with a lowercase set - a deliberate choice for an authentic SCADA/CRT
-- panel look (many real plant panels are uppercase-only), not just a
-- shortcut. A character with no entry in FONT (an unsupported symbol, or
-- rare punctuation from an arbitrary error string landing in the on-screen
-- log) silently renders as a blank cell rather than erroring - this
-- project's fail-safe-not-fail-loud convention applied to font coverage
-- gaps.
-- ---------------------------------------------------------------------------
local FONT = {
    ["0"] = { ".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###." },
    ["1"] = { "..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###." },
    ["2"] = { ".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####" },
    ["3"] = { ".###.", "#...#", "....#", "..##.", "....#", "#...#", ".###." },
    ["4"] = { "...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#." },
    ["5"] = { "#####", "#....", "####.", "....#", "....#", "#...#", ".###." },
    ["6"] = { "..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###." },
    ["7"] = { "#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..." },
    ["8"] = { ".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###." },
    ["9"] = { ".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.." },
    A = { "..#..", ".#.#.", "#...#", "#...#", "#####", "#...#", "#...#" },
    B = { "####.", "#...#", "#...#", "####.", "#...#", "#...#", "####." },
    C = { ".####", "#....", "#....", "#....", "#....", "#....", ".####" },
    D = { "####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####." },
    E = { "#####", "#....", "#....", "####.", "#....", "#....", "#####" },
    F = { "#####", "#....", "#....", "####.", "#....", "#....", "#...." },
    G = { ".####", "#....", "#....", "#..##", "#...#", "#...#", ".###." },
    H = { "#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#" },
    I = { "#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####" },
    J = { "..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.." },
    K = { "#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#" },
    L = { "#....", "#....", "#....", "#....", "#....", "#....", "#####" },
    M = { "#...#", "##.##", "#.#.#", "#...#", "#...#", "#...#", "#...#" },
    N = { "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#" },
    O = { ".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###." },
    P = { "####.", "#...#", "#...#", "####.", "#....", "#....", "#...." },
    Q = { ".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#" },
    R = { "####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#" },
    S = { ".####", "#....", "#....", ".###.", "....#", "....#", "####." },
    T = { "#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.." },
    U = { "#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###." },
    V = { "#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.." },
    W = { "#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#." },
    X = { "#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#" },
    Y = { "#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.." },
    Z = { "#####", "....#", "...#.", "..#..", ".#...", "#....", "#####" },
    [" "] = { ".....", ".....", ".....", ".....", ".....", ".....", "....." },
    ["%"] = { "##..#", "##.#.", "...#.", "..#..", ".#...", ".#.##", "#..##" },
    [":"] = { ".....", "..#..", "..#..", ".....", "..#..", "..#..", "....." },
    ["."] = { ".....", ".....", ".....", ".....", ".....", "..##.", "..##." },
    ["-"] = { ".....", ".....", ".....", "#####", ".....", ".....", "....." },
    ["/"] = { "....#", "....#", "...#.", "..#..", ".#...", "#....", "#...." },
    ["#"] = { ".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#." },
    ["<"] = { "...#.", "..#..", ".#...", "#....", ".#...", "..#..", "...#." },
    [">"] = { ".#...", "..#..", "...#.", "....#", "...#.", "..#..", ".#..." },
    ["("] = { "...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#." },
    [")"] = { ".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..." },
    ["+"] = { ".....", "..#..", "..#..", "#####", "..#..", "..#..", "....." },
    ["_"] = { ".....", ".....", ".....", ".....", ".....", ".....", "#####" },
    ["!"] = { "..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.." },
    ["?"] = { ".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.." },
    [","] = { ".....", ".....", ".....", ".....", ".....", "..#..", ".#..." },
    ["="] = { ".....", ".....", "#####", ".....", "#####", ".....", "....." },
    ["'"] = { "..#..", "..#..", ".....", ".....", ".....", ".....", "....." },
    ["*"] = { ".....", "#.#.#", ".###.", "#####", ".###.", "#.#.#", "....." },
}
local FONT_H = 7

-- Returns a list of {startCol0, len} runs of '#' within one 5-char glyph row
-- string, or nil if the row is blank. Computed on the fly rather than
-- precomputed/cached - cheap (5 characters to scan), and this project's
-- screens redraw at 1Hz at most (see gfx.beginFrame's doc comment on redraw
-- cadence), so there is no meaningful cost to re-deriving it every frame.
local function glyphRowRuns(rowStr)
    local runs, runStart = nil, nil
    for col = 1, #rowStr do
        local on = rowStr:sub(col, col) == "#"
        if on and not runStart then
            runStart = col
        elseif not on and runStart then
            runs = runs or {}
            runs[#runs + 1] = { runStart - 1, col - runStart }
            runStart = nil
        end
    end
    if runStart then
        runs = runs or {}
        runs[#runs + 1] = { runStart - 1, #rowStr - runStart + 1 }
    end
    return runs
end

-- ---------------------------------------------------------------------------
-- gfx.drawText - draws `text` as real pixels starting at character-cell
-- (x, y) (1-indexed, same convention as term.setCursorPos), one glyph per
-- 6x9 cell, so it drops straight into layout code originally written for
-- term.write with no column-math changes. `bgColor`, if given, fills the
-- text's whole cell-block background first in ONE drawPixels call spanning
-- the full string width - this is how a caller recreates a filled status
-- bar (e.g. a colored STATE band) purely out of text calls. Falls back to
-- plain term.write (setting background too, if given) when graphics mode
-- isn't active - same dual-mode contract as every other function in this
-- module, so a screen built entirely from gfx.drawText/gfx.drawBarMeter
-- calls degrades to plain text automatically if CC:Graphics is missing.
-- ---------------------------------------------------------------------------
function gfx.drawText(x, y, text, fgColor, bgColor)
    text = tostring(text or "")
    if not (inFrame and available()) then
        term.setCursorPos(x, y)
        if bgColor then
            term.setBackgroundColor(bgColor)
        end
        term.setTextColor(fgColor or colors.white)
        term.write(text)
        return false
    end

    local px0 = (x - 1) * PX_PER_COL
    local py0 = (y - 1) * PX_PER_ROW

    local ok = pcall(function()
        if bgColor then
            term.drawPixels(px0, py0, bgColor, #text * PX_PER_COL, PX_PER_ROW)
        end
        local upper = text:upper()
        for i = 1, #upper do
            local glyph = FONT[upper:sub(i, i)]
            if glyph then
                local cx = px0 + (i - 1) * PX_PER_COL + 1
                for row = 1, FONT_H do
                    local runs = glyphRowRuns(glyph[row])
                    if runs then
                        for _, run in ipairs(runs) do
                            term.drawPixels(cx + run[1], py0 + row, fgColor, run[2], 1)
                        end
                    end
                end
            end
        end
    end)

    if not ok then
        -- Same "treat as unavailable for the rest of this frame" fallback
        -- gfx.drawBarMeter uses.
        term.setCursorPos(x, y)
        if bgColor then
            term.setBackgroundColor(bgColor)
        end
        term.setTextColor(fgColor or colors.white)
        term.write(text)
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- gfx.clear - fills the whole screen with `bgColor`. In graphics mode this
-- is one full-screen drawPixels call rather than term.clear() (whose effect
-- on the graphics-mode pixel buffer is UNCONFIRMED - see VERIFICATION STATUS
-- above on never asserting an unverified engine fact); falls back to plain
-- term.clear() in text mode, identical to every screen's existing
-- boilerplate.
-- ---------------------------------------------------------------------------
function gfx.clear(bgColor)
    if inFrame and available() then
        local w, h = term.getSize()
        local ok = pcall(term.drawPixels, 0, 0, bgColor, w * PX_PER_COL, h * PX_PER_ROW)
        if ok then
            return true
        end
    end
    term.setBackgroundColor(bgColor)
    term.clear()
    return false
end

-- ---------------------------------------------------------------------------
-- gfx.drawBevel - a flat filled rectangle (character-cell x, y, w, h, same
-- units as gfx.drawBarMeter) with a 1px light highlight along its top+left
-- edge and a 1px dark shadow along its bottom+right edge - the classic
-- Windows 95 / Netscape 4 "raised button" look, built from the same solid-
-- fill drawPixels calls already confirmed working for the bar meters (see
-- header). Falls back to a plain filled rectangle with no bevel in text
-- mode - a sub-character pixel edge has no text-mode equivalent, same
-- "graceful degradation, not graceful imitation" contract every other
-- function here already uses.
-- ---------------------------------------------------------------------------
function gfx.drawBevel(x, y, w, h, bg, highlight, shadow)
    if not (inFrame and available()) then
        for row = 0, h - 1 do
            term.setCursorPos(x, y + row)
            term.setBackgroundColor(bg)
            term.write(string.rep(" ", w))
        end
        return false
    end

    local px = (x - 1) * PX_PER_COL
    local py = (y - 1) * PX_PER_ROW
    local pw = w * PX_PER_COL
    local ph = h * PX_PER_ROW

    local ok = pcall(function()
        term.drawPixels(px, py, bg, pw, ph)
        term.drawPixels(px, py, highlight, pw - 1, 1)   -- top edge
        term.drawPixels(px, py, highlight, 1, ph - 1)   -- left edge
        term.drawPixels(px, py + ph - 1, shadow, pw, 1) -- bottom edge
        term.drawPixels(px + pw - 1, py, shadow, 1, ph) -- right edge
    end)

    if not ok then
        for row = 0, h - 1 do
            term.setCursorPos(x, y + row)
            term.setBackgroundColor(bg)
            term.write(string.rep(" ", w))
        end
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
