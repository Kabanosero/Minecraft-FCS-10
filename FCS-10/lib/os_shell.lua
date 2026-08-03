-- lib/os_shell.lua
-- Shared "little OS" chrome for FCS-10 node terminals: a boot splash, a
-- desktop icon launcher, and small reusable screen furniture (a header bar
-- with a HOME button, and a key/value info-row renderer) - the pieces every
-- node's own desktop/Settings/Network screens are built from.
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

local os_shell = {}

os_shell.THEME = {
    bg       = colors.black,
    text     = colors.white,
    barBg    = colors.gray,
    barText  = colors.white,
    iconText = colors.white,
    accent   = colors.lightBlue,
    dim      = colors.lightGray,
}

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
    term.setBackgroundColor(colors.black)
    term.clear()

    local title = opts.title or "FCS-10"
    term.setTextColor(opts.accent or colors.lightBlue)
    term.setCursorPos(math.max(1, math.floor((w - #title) / 2) + 1), math.floor(h / 2) - 1)
    term.write(title)

    local sub = opts.subtitle
    if sub and #sub > 0 then
        term.setTextColor(colors.white)
        term.setCursorPos(math.max(1, math.floor((w - #sub) / 2) + 1), math.floor(h / 2))
        term.write(sub)
    end

    local idLine = ("ID %d  ::  %s"):format(os.getComputerID(), opts.role or "NODE")
    term.setTextColor(colors.lightGray)
    term.setCursorPos(math.max(1, math.floor((w - #idLine) / 2) + 1), math.floor(h / 2) + 2)
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

-- opts: { title, statusRight, statusColor, icons, footer }. Returns the
-- laid-out icon list (with hit regions) for the caller to pass into
-- hitTestIcons. statusColor lets the caller (e.g. a plant-state chip)
-- recolor just the statusRight text against the bar's own background,
-- without needing a second draw pass at the same position.
function os_shell.drawDesktop(opts)
    opts = opts or {}
    local w, h = term.getSize()
    local theme = os_shell.THEME

    term.setBackgroundColor(theme.bg)
    term.setTextColor(theme.text)
    term.clear()

    term.setBackgroundColor(theme.barBg)
    term.setTextColor(theme.barText)
    term.setCursorPos(1, 1)
    term.write(string.rep(" ", w))
    term.setCursorPos(2, 1)
    term.write(opts.title or "")
    if opts.statusRight then
        local x = math.max(2, w - #opts.statusRight)
        term.setCursorPos(x, 1)
        term.setTextColor(opts.statusColor or theme.barText)
        term.write(opts.statusRight)
        term.setTextColor(theme.barText)
    end

    local icons = layoutIcons(opts.icons or {}, w, 3)
    for _, icon in ipairs(icons) do
        term.setBackgroundColor(icon.color or theme.accent)
        term.setTextColor(theme.iconText)
        for row = 0, icon.h - 1 do
            term.setCursorPos(icon.x, icon.y + row)
            term.write(string.rep(" ", icon.w))
        end
        local label = icon.label or icon.key
        if #label > icon.w then
            label = label:sub(1, icon.w)
        end
        term.setCursorPos(icon.x + math.max(0, math.floor((icon.w - #label) / 2)), icon.y + math.floor(icon.h / 2))
        term.write(label)
    end

    if opts.footer then
        term.setBackgroundColor(theme.bg)
        term.setTextColor(theme.dim)
        term.setCursorPos(2, h)
        term.write(opts.footer)
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

    term.setBackgroundColor(theme.barBg)
    term.setTextColor(theme.barText)
    term.setCursorPos(1, 1)
    term.write(string.rep(" ", w))

    term.setTextColor(theme.accent)
    term.setCursorPos(HOME_BTN.x, 1)
    term.write("<HOME")

    term.setTextColor(theme.barText)
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

-- ---------------------------------------------------------------------------
-- Generic key/value info body, used by every node's Settings/Network screen.
-- rows: list of { label, value, color }, starting at (2, startRow).
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
end

return os_shell
