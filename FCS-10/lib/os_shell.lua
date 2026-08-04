-- lib/os_shell.lua
-- Shared "little OS" chrome for FCS-10 node terminals: a boot splash, a
-- desktop icon launcher, and small reusable screen furniture (a header bar
-- with a HOME button, a key/value info-row renderer, and a panel frame) -
-- the pieces every node's own desktop/Settings/Network screens are built
-- from. Styled as an industrial control-room panel (double-line borders,
-- bordered "keycap" buttons, a hazard-stripe boot accent) rather than a
-- flat modern-app look, to match the reactor-protection-system theme
-- already established across this project's comments (NUREG-1433/IAEA
-- SSG-76 references, LOTO, EAL tiers).
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

-- Single-line (S*) for small elements (icon buttons), double-line
-- (unprefixed, using "=" instead of "-") for full-screen panel frames -
-- still gives a visually heavier outer bezel vs. lighter inset controls
-- even without real box-drawing glyphs.
local CH = {
    h   = "=",
    v   = "|",
    tl  = "+",
    tr  = "+",
    bl  = "+",
    br  = "+",
    Sh  = "-",
    Sv  = "|",
    Stl = "+",
    Str = "+",
    Sbl = "+",
    Sbr = "+",
}

-- ---------------------------------------------------------------------------
-- THEMING - two named palettes, switchable at runtime via cycleTheme(). A
-- real settings control (drawThemeButton, below) is the intended way to
-- reach it, not something a node hardcodes. btnSafe/btnDanger/btnNeutral
-- are semantic action colors (green=safe, red=danger) and stay identical
-- across both palettes on purpose - a cosmetic theme switch must never
-- change what "danger" looks like, only what the background/chrome looks
-- like. "mono" is the pre-existing black-on-white look every node already
-- shipped with, kept as the default so a fresh install's first boot is
-- visually unchanged; "classic" is the lighter alternative (named to match
-- nodes/hmi.lua's own pre-existing theme table, which this module now
-- supersedes - see that file for the migration).
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
    },
    classic = {
        bg        = colors.lightGray,
        text      = colors.black,
        barBg     = colors.gray,
        barText   = colors.white,
        iconText  = colors.black,
        accent    = colors.blue,
        dim       = colors.gray,
        frame     = colors.gray,
        btnSafe   = colors.green,
        btnDanger = colors.red,
        btnNeutral = colors.blue,
    },
}
os_shell.THEME_ORDER = { "mono", "classic" }

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
-- actually is, since they're never computed twice.
local ICON_W, ICON_H = 12, 3
local function layoutIcons(icons, w, top)
    local cols = math.max(1, math.floor(w / (ICON_W + 2)))
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

-- Draws one icon as a single-line-bordered "keycap" button (border in the
-- icon's own accent color, black interior, label centered on the middle
-- row) rather than a flat filled tile - reads as a physical control-panel
-- pushbutton instead of a phone-home-screen icon.
local function drawIconButton(icon, theme)
    local c = icon.color or theme.accent
    term.setBackgroundColor(theme.bg)
    term.setTextColor(c)
    term.setCursorPos(icon.x, icon.y)
    term.write(CH.Stl .. string.rep(CH.Sh, icon.w - 2) .. CH.Str)

    local label = icon.label or icon.key
    if #label > icon.w - 2 then
        label = label:sub(1, icon.w - 2)
    end
    term.setCursorPos(icon.x, icon.y + 1)
    term.write(CH.Sv)
    term.setTextColor(theme.iconText)
    term.setCursorPos(icon.x + 1 + math.max(0, math.floor((icon.w - 2 - #label) / 2)), icon.y + 1)
    term.write(label)
    term.setTextColor(c)
    term.setCursorPos(icon.x + icon.w - 1, icon.y + 1)
    term.write(CH.Sv)

    term.setCursorPos(icon.x, icon.y + 2)
    term.write(CH.Sbl .. string.rep(CH.Sh, icon.w - 2) .. CH.Sbr)
end

-- opts: { title, statusRight, statusColor, icons, footer }. Returns the
-- laid-out icon list (with hit regions) for the caller to pass into
-- hitTestIcons. statusColor lets the caller (e.g. a plant-state chip)
-- recolor just the statusRight text against the title bar's own line,
-- without needing a second draw pass at the same position. Draws its own
-- full double-line panel frame (top/bottom border + side verticals) - a
-- node's desktop screen never needs a separate os_shell.drawScreenFrame()
-- call the way Settings/Network screens do (see that function below).
function os_shell.drawDesktop(opts)
    opts = opts or {}
    local w, h = term.getSize()
    local theme = os_shell.THEME

    term.setBackgroundColor(theme.bg)
    term.setTextColor(theme.text)
    term.clear()

    -- Row 1: double-line top border with title/status embedded.
    term.setTextColor(theme.frame)
    term.setCursorPos(1, 1)
    term.write(CH.tl .. string.rep(CH.h, math.max(0, w - 2)) .. CH.tr)

    -- Title/status sit directly on the plain background (this row is
    -- line-drawn, not a filled bar - see barBg/barText's own comment above),
    -- so they use theme.text for contrast against theme.bg, not barText
    -- (which is paired specifically with barBg elsewhere).
    term.setTextColor(theme.text)
    term.setCursorPos(3, 1)
    term.write(" " .. (opts.title or "") .. " ")

    if opts.statusRight then
        local label = " " .. opts.statusRight .. " "
        local x = math.max(4 + #(opts.title or ""), w - #label - 1)
        term.setTextColor(opts.statusColor or theme.text)
        term.setCursorPos(x, 1)
        term.write(label)
    end

    -- Side verticals + bottom border.
    term.setTextColor(theme.frame)
    for row = 2, h - 1 do
        term.setCursorPos(1, row)
        term.write(CH.v)
        term.setCursorPos(w, row)
        term.write(CH.v)
    end
    term.setCursorPos(1, h)
    term.write(CH.bl .. string.rep(CH.h, math.max(0, w - 2)) .. CH.br)
    if opts.footer then
        term.setTextColor(theme.dim)
        term.setCursorPos(3, h)
        term.write(" " .. opts.footer .. " ")
    end

    local icons = layoutIcons(opts.icons or {}, w, 3)
    for _, icon in ipairs(icons) do
        drawIconButton(icon, theme)
    end

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
    -- theme.bg (drawIconButton's black-ish interior), but this button - like
    -- nodes/hmi.lua's STARTUP/SCRAM/EXIT buttons - is a filled, saturated
    -- surface, exactly what barText is paired with.
    term.setTextColor(theme.barText)
    term.setCursorPos(2, row)
    term.write(label)
    term.setBackgroundColor(theme.bg)
    return { x = 2, y = row, w = #label, h = 1 }
end

return os_shell
