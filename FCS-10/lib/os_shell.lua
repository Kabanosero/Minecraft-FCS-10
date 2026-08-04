-- lib/os_shell.lua
-- Shared "little OS" chrome for FCS-10 node terminals: a boot splash, a
-- desktop icon launcher, and small reusable screen furniture (a header bar
-- with a HOME button, a key/value info-row renderer, and a panel frame) -
-- the pieces every node's own desktop/Settings/Network screens are built
-- from. The desktop (drawDesktop, below) is styled as a simplified
-- Windows-7-like desktop - a colored wallpaper fill, borderless icon+
-- caption tiles, and a bottom taskbar with a Start-style badge, title,
-- status chip, and clock - while the sub-screen furniture (drawScreenHeader/
-- drawScreenFrame/drawKeyValueList/drawThemeButton, and every node's own
-- SCADA/Settings/Network/Console body) still uses the original industrial
-- control-room panel look (double-line borders, hazard-stripe boot accent)
-- to match the reactor-protection-system theme already established across
-- this project's comments (NUREG-1433/IAEA SSG-76 references, LOTO, EAL
-- tiers). That split is deliberate, not an inconsistency left behind: the
-- desktop got its reskin first, the sub-screens are a separate follow-up.
--
-- Pure rendering + hit-testing only. Never touches rednet/reactor state and
-- never blocks or sleeps, so it cannot delay a node's own control loop by
-- itself - each node file owns a `currentScreen` variable and decides which
-- of its own draw functions (desktop vs its SCADA screen vs Settings vs
-- Network) runs on any given tick; this module has no opinion on that and
-- keeps no state of its own. Unlike lib/secnet.lua, dofile-ing this more
-- than once (even within the same node) is always safe - every function
-- here is a pure function of its arguments and the current terminal.
--
-- SAFETY-CRITICAL NOTE (PLC/RTU): a node's polling/telemetry loop must keep
-- running no matter which screen is on-screen. This module is only ever
-- used as the *draw* layer - it never wraps or owns the event loop itself -
-- so a node switching to "Settings" or "Network" never pauses its own
-- os.pullEvent() loop or the timer-driven poll/broadcast logic inside it.
--
-- BORDER CHARACTERS: plain 7-bit ASCII only (+, -, |, =). An earlier version
-- of this file used string.char() with CP437 code points on the assumption
-- that CC:Tweaked's terminal font follows the classic IBM CP437 layout for
-- byte values 128-255 - it does not (those bytes render as Latin-1/CP1252
-- accented letters instead, confirmed against an actual in-game screenshot).
-- Plain ASCII is guaranteed to render identically regardless of font/
-- charset, at the cost of a less fancy-looking border than true box-drawing
-- glyphs would give.

local os_shell = {}

-- Double-line (using "=" for the horizontal rule) full-screen panel frame
-- glyphs, used by drawBootSplash and the sub-screen header/frame furniture
-- below - still gives a visually heavier bezel even without real box-
-- drawing glyphs. The desktop no longer uses any of these (see drawDesktop
-- below - it's borderless, wallpaper edge-to-edge).
local CH = {
    h  = "=",
    v  = "|",
    tl = "+",
    tr = "+",
    bl = "+",
    br = "+",
}

-- ---------------------------------------------------------------------------
-- THEMING - one active palette, read fresh by every draw function below
-- (never cached), still switchable via cycleTheme()/drawThemeButton for
-- whenever a second look gets added back. btnSafe/btnDanger/btnNeutral are
-- semantic action colors (green=safe, red=danger) that must never change
-- with a cosmetic theme switch. "classic" (a lighter alternative palette)
-- was dropped when the desktop got its Windows-7-style reskin below - every
-- OTHER field here keeps its original "mono" value unchanged on purpose, so
-- the not-yet-redesigned Settings/Network/SCADA/Console screens (which read
-- these directly) stay pixel-identical; only the 6 new desktop-only fields
-- at the bottom are new. THEME_ORDER having a single entry makes
-- cycleTheme() an intentional no-op for now, not a bug.
-- ---------------------------------------------------------------------------
os_shell.THEMES = {
    mono = {
        bg        = colors.black,
        text      = colors.white,
        -- barBg/barText: a genuinely distinct filled-bar pair, used where a
        -- node needs a solid colored strip rather than this module's usual
        -- line-drawn panels (e.g. nodes/hmi.lua's status console box).
        barBg     = colors.gray,
        barText   = colors.white,
        iconText  = colors.white,
        accent    = colors.lightBlue,
        dim       = colors.lightGray,
        frame     = colors.lightGray,
        btnSafe   = colors.green,
        btnDanger = colors.red,
        btnNeutral = colors.lightBlue,

        -- Desktop-only (drawDesktop/layoutIcons/drawIconTile/drawTaskbar) -
        -- nothing else in this module or any node's other screens reads
        -- these. taskbarBg is black rather than gray on purpose: Supervisor's
        -- STATUS_COLOR["AWAITING PLC"] = colors.gray would render invisibly
        -- on a gray bar; black preserves the exact contrast every status
        -- color already has today against theme.bg.
        wallpaperBg    = colors.blue,
        taskbarBg      = colors.black,
        taskbarText    = colors.white,
        startBadgeBg   = colors.lightBlue,
        startBadgeText = colors.white,
        clockText      = colors.lightGray,
    },
}
os_shell.THEME_ORDER = { "mono" }

local currentThemeName = "mono"
os_shell.THEME = os_shell.THEMES[currentThemeName]

function os_shell.currentThemeName()
    return currentThemeName
end

-- Advances to the next palette in THEME_ORDER (wrapping) and reassigns
-- os_shell.THEME to it. Every draw function in this module re-reads
-- os_shell.THEME fresh on each call (never a cached local captured once at
-- load time), so this takes effect the very next time anything redraws -
-- callers still need to trigger that redraw themselves (this module never
-- redraws on its own, matching its "pure draw layer" contract above).
function os_shell.cycleTheme()
    local idx = 1
    for i, name in ipairs(os_shell.THEME_ORDER) do
        if name == currentThemeName then
            idx = i
            break
        end
    end
    idx = (idx % #os_shell.THEME_ORDER) + 1
    currentThemeName = os_shell.THEME_ORDER[idx]
    os_shell.THEME = os_shell.THEMES[currentThemeName]
    return currentThemeName
end

-- Generic hit-test for any {x,y,w,h} region this module hands back
-- (drawScreenHeader's home region, drawThemeButton's button region, ...).
function os_shell.isPointIn(region, x, y)
    return region ~= nil and x >= region.x and x < region.x + region.w and y >= region.y and y < region.y + region.h
end

-- ---------------------------------------------------------------------------
-- Boot splash - draws once and returns immediately (never sleeps). The
-- caller decides how long to leave it up (e.g. a single os.sleep or
-- os.startTimer wait during its own one-time boot sequence, never inside the
-- main loop) so an auto-boot node's first real control-loop tick is delayed
-- by exactly that much and no more.
-- ---------------------------------------------------------------------------
function os_shell.drawBootSplash(opts)
    opts = opts or {}
    local w, h = term.getSize()
    local theme = os_shell.THEME

    term.setBackgroundColor(colors.black)
    term.clear()

    -- Full-screen double-line bezel.
    term.setTextColor(theme.frame)
    term.setCursorPos(1, 1)
    term.write(CH.tl .. string.rep(CH.h, math.max(0, w - 2)) .. CH.tr)
    for row = 2, h - 1 do
        term.setCursorPos(1, row)
        term.write(CH.v)
        term.setCursorPos(w, row)
        term.write(CH.v)
    end
    term.setCursorPos(1, h)
    term.write(CH.bl .. string.rep(CH.h, math.max(0, w - 2)) .. CH.br)

    local title = opts.title or "FCS-10"
    term.setTextColor(opts.accent or theme.accent)
    term.setCursorPos(math.max(2, math.floor((w - #title) / 2) + 1), math.floor(h / 2) - 2)
    term.write(title)

    -- Hazard-stripe divider under the title - a caution-tape motif, fitting
    -- for a reactor protection system's boot screen. Alternating solid
    -- yellow/black cells stand in for a diagonal stripe within one row.
    local stripeRow = math.floor(h / 2) - 1
    for col = 2, w - 1 do
        term.setBackgroundColor(((col % 2) == 0) and colors.yellow or colors.black)
        term.setCursorPos(col, stripeRow)
        term.write(" ")
    end
    term.setBackgroundColor(colors.black)

    local sub = opts.subtitle
    if sub and #sub > 0 then
        term.setTextColor(colors.white)
        term.setCursorPos(math.max(2, math.floor((w - #sub) / 2) + 1), math.floor(h / 2) + 1)
        term.write(sub)
    end

    local idLine = ("ID %d  ::  %s"):format(os.getComputerID(), opts.role or "NODE")
    term.setTextColor(colors.lightGray)
    term.setCursorPos(math.max(2, math.floor((w - #idLine) / 2) + 1), math.floor(h / 2) + 3)
    term.write(idLine)
end

-- ---------------------------------------------------------------------------
-- Desktop icon launcher
-- ---------------------------------------------------------------------------
-- icons: list of { key, label, color }. Laid out into a grid sized to the
-- current terminal, top-anchored at row `top`. Mutates and returns the same
-- list with x/y/w/h filled in - drawDesktop feeds its result straight into
-- hitTestIcons so draw and hit-test can never disagree about where an icon
-- actually is, since they're never computed twice. Driven purely by
-- terminal width/icon count, not hardcoded to today's icon lists, so it
-- scales automatically if a node ever adds more icons.
local ICON_W, ICON_H   = 9, 3   -- tile: 9 cols wide, 3 rows tall (2-row glyph + 1 caption row)
local GLYPH_W, GLYPH_H = 5, 2   -- solid-color glyph rectangle, centered within the tile
local GUTTER_MIN       = 1
local function layoutIcons(icons, w, top)
    local cols = math.max(1, math.floor(w / (ICON_W + GUTTER_MIN)))
    local gutterX = math.max(1, math.floor((w - cols * ICON_W) / (cols + 1)))
    for i, icon in ipairs(icons) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        icon.x = gutterX + col * (ICON_W + gutterX)
        icon.y = top + row * (ICON_H + 1)
        icon.w = ICON_W
        icon.h = ICON_H
    end
    return icons
end

-- Draws one icon as a borderless desktop tile: a solid-color glyph
-- rectangle (built from background-colored spaces - the same zero-font-
-- risk technique drawBootSplash's hazard stripe already uses, no ASCII
-- border glyphs at all) with the caption centered directly beneath it -
-- reads as a real desktop icon+label pair rather than a control-panel
-- pushbutton.
local function drawIconTile(icon, theme)
    local c = icon.color or theme.accent
    local glyphX = icon.x + math.floor((icon.w - GLYPH_W) / 2)

    term.setBackgroundColor(c)
    for row = 0, GLYPH_H - 1 do
        term.setCursorPos(glyphX, icon.y + row)
        term.write(string.rep(" ", GLYPH_W))
    end

    local label = icon.label or icon.key
    if #label > icon.w then
        label = label:sub(1, icon.w)
    end
    term.setBackgroundColor(theme.wallpaperBg)
    term.setTextColor(theme.iconText)
    term.setCursorPos(icon.x + math.max(0, math.floor((icon.w - #label) / 2)), icon.y + GLYPH_H)
    term.write(label)
end

local BADGE_TEXT = "FCS-10"
local CLOCK_FMT, CLOCK_W = "%H:%M:%S", 8

-- os.date is unused anywhere else in this codebase (CC:Tweaked documents it
-- as mirroring standard Lua os.date, but that's never been proven in-game
-- for this project) - guarded and pcall'd per this module's own "never
-- assert an unverified engine fact" rule (see the CP437 lesson in this
-- file's header). Falls back to an os.epoch("utc")-derived clock (a real-
-- world-ms source already proven throughout this codebase, e.g.
-- lib/secnet.lua) if os.date is ever missing or misbehaves - note the
-- fallback reads UTC, not local time, a cosmetic difference only.
local function clockText()
    local ok, text = pcall(os.date, CLOCK_FMT)
    if ok and type(text) == "string" and #text == CLOCK_W then
        return text
    end
    local s = math.floor(os.epoch("utc") / 1000) % 86400
    return string.format("%02d:%02d:%02d", math.floor(s / 3600), math.floor((s % 3600) / 60), s % 60)
end

-- Bottom taskbar: [ FCS-10 ][ title.......][ status chip ][ HH:MM:SS ].
-- opts.footer (still accepted by every call site) is intentionally never
-- read here - there's no equivalent slot in this layout, so it's just
-- inert now, same as cycleTheme() becoming a no-op with one theme.
local function drawTaskbar(opts, theme, w, h)
    local row = h
    local badge = " " .. BADGE_TEXT
    local badgeW = #badge

    term.setBackgroundColor(theme.taskbarBg)
    term.setTextColor(theme.taskbarText)
    term.setCursorPos(1, row)
    term.write(string.rep(" ", w))

    term.setBackgroundColor(theme.startBadgeBg)
    term.setTextColor(theme.startBadgeText)
    term.setCursorPos(1, row)
    term.write(badge)

    local clock = clockText()
    local chip = (opts.statusRight and #opts.statusRight > 0) and ("[" .. opts.statusRight .. "]") or ""
    local middleStart, middleEnd = badgeW + 2, w - CLOCK_W - 1
    local middleW = math.max(0, middleEnd - middleStart + 1)
    if #chip > middleW then
        chip = chip:sub(1, middleW)
    end

    -- Status chip wins the shrink budget over the title - on a reactor
    -- panel, plant state matters more than the cosmetic node title.
    local title = opts.title or ""
    local titleBudget = math.max(0, middleW - #chip - (#chip > 0 and 1 or 0))
    if #title > titleBudget then
        title = title:sub(1, titleBudget)
    end

    term.setBackgroundColor(theme.taskbarBg)
    term.setTextColor(theme.taskbarText)
    term.setCursorPos(middleStart, row)
    term.write(title)

    if #chip > 0 then
        term.setTextColor(opts.statusColor or theme.taskbarText)
        term.setCursorPos(middleEnd - #chip + 1, row)
        term.write(chip)
    end

    term.setTextColor(theme.clockText)
    term.setCursorPos(w - CLOCK_W + 1, row)
    term.write(clock)
end

-- opts: { title, statusRight, statusColor, icons, footer }. Returns the
-- laid-out icon list (with hit regions) for the caller to pass into
-- hitTestIcons. statusColor lets the caller (e.g. a plant-state chip)
-- recolor just the status text in the taskbar. Fills the whole screen with
-- theme.wallpaperBg (edge-to-edge, no bezel) and reserves only the last row
-- for the taskbar - a node's desktop never needs a separate
-- os_shell.drawScreenFrame() call the way Settings/Network screens do (see
-- that function below).
function os_shell.drawDesktop(opts)
    opts = opts or {}
    local w, h = term.getSize()
    local theme = os_shell.THEME

    term.setBackgroundColor(theme.wallpaperBg)
    term.setTextColor(theme.iconText)
    term.clear()

    local icons = layoutIcons(opts.icons or {}, w, 2)
    for _, icon in ipairs(icons) do
        drawIconTile(icon, theme)
    end

    drawTaskbar(opts, theme, w, h)

    return icons
end

function os_shell.hitTestIcons(icons, x, y)
    for _, icon in ipairs(icons) do
        if x >= icon.x and x < icon.x + icon.w and y >= icon.y and y < icon.y + icon.h then
            return icon.key
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Sub-screen chrome: a header bar with a HOME button, shared by every
-- non-desktop screen (a node's own SCADA screen, Settings, Network) across
-- every node file. isHomeClick uses the same fixed region drawScreenHeader
-- always draws, so they can never disagree.
-- ---------------------------------------------------------------------------
local HOME_BTN = { x = 1, w = 8 } -- always row 1; label "<HOME"

function os_shell.drawScreenHeader(title, statusRight)
    local w = term.getSize()
    local theme = os_shell.THEME

    term.setBackgroundColor(theme.bg)
    term.setTextColor(theme.frame)
    term.setCursorPos(1, 1)
    term.write(CH.tl .. string.rep(CH.h, math.max(0, w - 2)) .. CH.tr)

    term.setTextColor(theme.accent)
    term.setCursorPos(HOME_BTN.x, 1)
    term.write("<HOME")

    -- theme.text, not barText, for the same reason as drawDesktop above:
    -- this row is line-drawn, sitting on the plain background, not a
    -- filled bar.
    term.setTextColor(theme.text)
    term.setCursorPos(HOME_BTN.w + 2, 1)
    term.write(title or "")

    if statusRight then
        local x = math.max(HOME_BTN.w + 2, w - #statusRight)
        term.setCursorPos(x, 1)
        term.write(statusRight)
    end

    return { x = HOME_BTN.x, y = 1, w = HOME_BTN.w, h = 1 }
end

function os_shell.isHomeClick(x, y)
    return y == 1 and x >= HOME_BTN.x and x < HOME_BTN.x + HOME_BTN.w
end

-- Closes out a panel opened by drawScreenHeader: draws the left/right
-- vertical border strip for rows top+1..bottom-1, plus a closing double-
-- line bottom border at row `bottom`. Call AFTER all of a screen's body
-- content has been written - it only ever touches column 1, column w, and
-- the full `bottom` row, so it never needs to know what the caller already
-- drew in between (those columns are never used by drawKeyValueList's
-- label/value columns, which start at 2 and 20 respectively).
function os_shell.drawScreenFrame(top, bottom)
    local w = term.getSize()
    local theme = os_shell.THEME
    term.setBackgroundColor(theme.bg)
    term.setTextColor(theme.frame)
    for row = top + 1, bottom - 1 do
        term.setCursorPos(1, row)
        term.write(CH.v)
        term.setCursorPos(w, row)
        term.write(CH.v)
    end
    term.setCursorPos(1, bottom)
    term.write(CH.bl .. string.rep(CH.h, math.max(0, w - 2)) .. CH.br)
end

-- ---------------------------------------------------------------------------
-- Generic key/value info body, used by every node's Settings/Network screen.
-- rows: list of { label, value, color }, starting at (2, startRow). Returns
-- the first unused row below the list, so a caller can place further
-- content (e.g. drawThemeButton below) without duplicating this count.
-- ---------------------------------------------------------------------------
function os_shell.drawKeyValueList(rows, startRow)
    startRow = startRow or 3
    local theme = os_shell.THEME
    for i, row in ipairs(rows) do
        term.setBackgroundColor(theme.bg)
        term.setTextColor(theme.dim)
        term.setCursorPos(2, startRow + i - 1)
        term.write(row.label .. ":")
        term.setTextColor(row.color or theme.text)
        term.setCursorPos(20, startRow + i - 1)
        term.write(tostring(row.value))
    end
    return startRow + #rows
end

-- ---------------------------------------------------------------------------
-- A real, clickable settings control: cycles the shared theme (see THEMING
-- above) and returns its hit region. The node file must still call its own
-- redraw function after a click lands here - cycleTheme() only swaps which
-- palette every subsequent draw call reads, it never redraws by itself.
-- ---------------------------------------------------------------------------
function os_shell.drawThemeButton(row)
    local theme = os_shell.THEME
    local label = (" THEME: %s (click to change) "):format(os_shell.currentThemeName():upper())
    term.setBackgroundColor(theme.accent)
    -- barText, not iconText: iconText is calibrated to contrast against
    -- theme.wallpaperBg (the desktop's icon captions), but this button -
    -- like nodes/hmi.lua's STARTUP/SCRAM/EXIT buttons - is a filled,
    -- saturated surface, exactly what barText is paired with.
    term.setTextColor(theme.barText)
    term.setCursorPos(2, row)
    term.write(label)
    term.setBackgroundColor(theme.bg)
    return { x = 2, y = row, w = #label, h = 1 }
end

return os_shell
