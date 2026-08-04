-- nodes/hmi.lua
-- FCS-10 / ATM-PCS :: Human-Machine Interface (Operator GUI)
--
-- The click-driven operator frontend for the SCADA system. Runs on its own
-- CC:Tweaked Advanced Computer, entirely decoupled from reactor logic - it
-- only ever knows about reactor state via wireless telemetry, never a
-- fissionReactorLogicAdapter.
--
-- NETWORK: hosts on PROTOCOL_HMI (secnet.open), the same "this node's own
-- protocol" role PROTOCOL_PLC/PROTOCOL_SUPERVISOR play for plc.lua/
-- supervisor.lua. Outbound COMMAND messages are tagged PROTOCOL_PLC - the
-- AUDIENCE's protocol, matching the convention plc.lua's/supervisor.lua's
-- headers establish - and broadcast rather than sent to one PLC: this
-- foundational build has no per-PLC registry the way supervisor.lua's
-- `plcs` table does (it doesn't consume TELEMETRY/STATE_BROADCAST yet), so
-- every button press is necessarily fleet-wide. SCRAM as a broadcast
-- emergency-stop is intentional. STARTUP currently sends action =
-- "STARTUP", which plc.lua's handleCommand does not implement (it will ACK
-- back accepted=false, reason="unknown-action") - wired honestly as a
-- placeholder rather than guessing an unreviewed default burn rate for
-- SET_BURN_RATE.
--
-- No ACK-timeout/retry state machine like supervisor.lua's dispatchCommand
-- - broadcasts here are fire-and-forget, and inbound ACKs are only logged
-- to the status console (via logStatus, never raw print/term writes) for
-- operator feedback, not tracked or retried.

local okCfg, config = pcall(dofile, "/lib/config.lua")
if not okCfg then
    print("[HMI] FATAL: failed to load /lib/config.lua: " .. tostring(config))
    return
end

local okSn, secnet = pcall(dofile, "/lib/secnet.lua")
if not okSn then
    print("[HMI] FATAL: failed to load /lib/secnet.lua: " .. tostring(secnet))
    return
end

local okShell, os_shell = pcall(dofile, "/lib/os_shell.lua")
if not okShell then
    print("[HMI] FATAL: failed to load /lib/os_shell.lua: " .. tostring(os_shell))
    return
end

local NET = config.NETWORK
local MSG = config.NETWORK.MSG_TYPE

local TITLE = "FCS-10 HMI"
local STATUS_TOP = 15  -- first row of the reserved status console (bottom of screen)

-- THEMING: colors come from os_shell.THEME/os_shell.THEMES (see
-- lib/os_shell.lua), not a local table - this file used to keep its own
-- separate classic/mono palette here, which meant the console screen's
-- button colors could never actually be switched (nothing ever reassigned
-- the old `currentTheme` local) while the newer Desktop/Settings/Network
-- screens already used the shared, switchable os_shell theme. Reusing
-- os_shell.THEME for everything fixes that split and makes the THEME
-- button on the Settings screen (see drawSettingsScreen) actually re-skin
-- the whole node, console included, not just half of it. headerBg/
-- headerText map to os_shell.THEME's barBg/barText fields.
local secnetOpen = false -- true once secnet.open() has ever succeeded (see tryOpenSecnet)

-- currentScreen drives ONLY which top-level screen function runs and where
-- mouse_click is routed - see "DESKTOP SHELL" below. "console" is this
-- file's pre-existing STARTUP/SCRAM/EXIT button screen; it has zero effect
-- on command dispatch or inbound ACK handling.
local currentScreen    = "desktop" -- "desktop" | "console" | "settings" | "network"
local lastDesktopIcons = {}        -- laid-out icon hit-regions from the last drawDesktopScreen()
local homeHitRegion    = nil       -- HOME button hit-region from the last Settings/Network chrome draw

-- ===========================================================================
-- BUTTON REGISTRY
-- ===========================================================================
-- colorKey is a theme key, not a resolved color, so re-theming (setting
-- os_shell.THEME to a different palette) re-colors every button automatically.
local buttons = {
    { id = "startup", label = "STARTUP", x = 3,  y = 5, width = 12, colorKey = "btnSafe"    },
    { id = "scram",   label = "SCRAM",   x = 17, y = 5, width = 12, colorKey = "btnDanger"  },
    { id = "exit",    label = "EXIT",    x = 31, y = 5, width = 12, colorKey = "btnNeutral" },
}

-- ===========================================================================
-- RENDERING
-- ===========================================================================
local function drawButton(btn)
    local theme = os_shell.THEME
    term.setBackgroundColor(theme[btn.colorKey])
    term.setTextColor(theme.barText)
    term.setCursorPos(btn.x, btn.y)
    term.write(string.rep(" ", btn.width))
    term.setCursorPos(btn.x + math.floor((btn.width - #btn.label) / 2), btn.y)
    term.write(btn.label)
end

local function drawStatusBox(w, h)
    local theme = os_shell.THEME
    term.setBackgroundColor(theme.barBg)
    term.setTextColor(theme.barText)
    for row = STATUS_TOP, h do
        term.setCursorPos(1, row)
        term.write(string.rep(" ", w))
    end
end

-- The pre-existing STARTUP/SCRAM/EXIT button screen, now one of four
-- top-level screens (see "DESKTOP SHELL" below) rather than the only thing
-- this file ever draws. Body unchanged except drawHeader(w) (deleted) is
-- replaced by os_shell.drawScreenHeader, which adds the "<HOME" affordance
-- back out to the desktop shell.
local function drawConsoleScreen()
    term.setBackgroundColor(os_shell.THEME.bg)
    term.setTextColor(os_shell.THEME.text)
    term.clear()

    local w, h = term.getSize()
    homeHitRegion = os_shell.drawScreenHeader(TITLE)
    drawStatusBox(w, h)

    for _, btn in ipairs(buttons) do
        drawButton(btn)
    end
end

-- ---------------------------------------------------------------------------
-- DESKTOP SHELL - built on lib/os_shell.lua's shared boot-splash/desktop/
-- chrome helpers, same move nodes/plc.lua/nodes/rtu.lua/nodes/supervisor.lua
-- make. CONSOLE (the function above) is this node's core operator screen;
-- SETTINGS/NETWORK are read-only info screens; UPDATE isn't a screen at
-- all, see launchUpdater() below. Unlike plc.lua/rtu.lua, this file has no
-- bounded log-buffer panel - logStatus() below writes straight to a fixed
-- terminal row that only exists on the console screen's own chrome, so it's
-- guarded to no-op on the other three screens (see logStatus()).
-- ---------------------------------------------------------------------------
local DESKTOP_ICONS = {
    { key = "console",  label = "CONSOLE",  color = colors.lightBlue },
    { key = "settings", label = "SETTINGS", color = colors.gray },
    { key = "network",  label = "NETWORK",  color = colors.cyan },
    { key = "update",   label = "UPDATE",   color = colors.blue },
}

local function drawDesktopScreen()
    lastDesktopIcons = os_shell.drawDesktop({
        title       = TITLE,
        statusRight = secnetOpen and "NET: OPEN" or "NET: DOWN",
        statusColor = secnetOpen and colors.green or colors.red,
        icons       = DESKTOP_ICONS,
        footer      = "Click an icon to launch a program.",
    })
end

local themeButtonRegion = nil -- theme-toggle hit-region from the last drawSettingsScreen()

local function drawSettingsScreen()
    local theme = os_shell.THEME
    term.setBackgroundColor(theme.bg)
    term.setTextColor(theme.text)
    term.clear()
    homeHitRegion = os_shell.drawScreenHeader("SETTINGS")
    local nextRow = os_shell.drawKeyValueList({
        { label = "Role",        value = "HMI (operator console)" },
        { label = "Computer ID", value = os.getComputerID() },
        { label = "secnet",      value = secnetOpen and "OPEN" or "NOT OPEN",
          color = secnetOpen and colors.green or colors.red },
    }, 3)
    themeButtonRegion = os_shell.drawThemeButton(nextRow + 1)
    local _, h = term.getSize()
    os_shell.drawScreenFrame(1, h)
end

local function drawNetworkScreen()
    local theme = os_shell.THEME
    term.setBackgroundColor(theme.bg)
    term.setTextColor(theme.text)
    term.clear()
    homeHitRegion = os_shell.drawScreenHeader("NETWORK")
    os_shell.drawKeyValueList({
        { label = "secnet",   value = secnetOpen and "OPEN" or "NOT OPEN",
          color = secnetOpen and colors.green or colors.red },
        { label = "Hosts on", value = NET.PROTOCOL_HMI },
        { label = "Sends to", value = NET.PROTOCOL_PLC },
    }, 3)
    -- No peer list here, unlike nodes/supervisor.lua's Network screen: this
    -- node subscribes to no TELEMETRY and keeps no PLC/RTU registry (see
    -- file header "Future") - showing an empty/fake list would be dishonest.
    local _, h = term.getSize()
    os_shell.drawScreenFrame(1, h)
end

-- Single dispatch point - which screen function actually runs depends only
-- on currentScreen, a purely local display choice with no effect on
-- command dispatch or inbound ACK handling above.
local function drawUI()
    if currentScreen == "console" then
        drawConsoleScreen()
    elseif currentScreen == "settings" then
        drawSettingsScreen()
    elseif currentScreen == "network" then
        drawNetworkScreen()
    else
        drawDesktopScreen()
    end
end

-- Dedicated pcall boundary, same reasoning as plc.lua's safeDraw()/
-- supervisor.lua's safeRedraw() - drawing must never be allowed to kill
-- this node's event loop.
local function safeDrawUI()
    local ok, err = pcall(drawUI)
    if not ok then
        print("[HMI] draw failed (non-fatal): " .. tostring(err))
    end
end

-- Shells out to the existing installer.lua (see nodes/plc.lua's
-- launchUpdater() for the full reasoning - identical here, just targeting
-- role "hmi"). This node has no reactor/network responsibility to pause
-- that matters as much as plc.lua's does, but it's still logged clearly
-- before launching for the same honesty reasons.
local function launchUpdater()
    print("[HMI] UPDATE: opening installer - this console pauses until it returns")
    pcall(function()
        shell.run("/installer.lua", "update", "hmi")
        os.sleep(2) -- brief, bounded pause so the printed result is readable, never indefinite
    end)
    print("[HMI] UPDATE: installer closed, resuming normal operation")
    safeDrawUI()
end

-- ===========================================================================
-- STATUS CONSOLE
-- ===========================================================================
-- All event feedback must go through here, never raw print() - print()
-- writes at the shell cursor and scrolls the terminal on overflow, which
-- would tear up the header/button chrome drawn above. logStatus always
-- targets the same fixed row and blanks it first, so it can never bleed
-- outside the reserved status box or leave stale characters behind.
--
-- Guarded to no-op off the console screen: STATUS_TOP is a fixed row
-- belonging to the console screen's own chrome (see "DESKTOP SHELL" above).
-- Without this guard, e.g. secnet finally opening via a "peripheral" event
-- while the operator is browsing Settings would stamp a stray colored bar
-- across whatever Settings happens to be drawing at that row.
local function logStatus(msg)
    if currentScreen ~= "console" then
        return
    end
    local w, h = term.getSize()
    if h < STATUS_TOP then return end

    term.setBackgroundColor(os_shell.THEME.barBg)
    term.setTextColor(os_shell.THEME.barText)
    term.setCursorPos(1, STATUS_TOP)
    term.write(string.rep(" ", w))
    term.setCursorPos(2, STATUS_TOP)
    term.write(msg)
end

-- ===========================================================================
-- COMMAND DISPATCH
-- ===========================================================================
-- Payload contract established by plc.lua's handleCommand (see
-- nodes/plc.lua): { action = "SET_BURN_RATE" | "SCRAM", value = <required
-- for SET_BURN_RATE>, requestId }. Only button ids listed in
-- COMMAND_ACTIONS carry a network action - "exit" has none, so sendCommand
-- silently no-ops for it (a purely local UI button, never wire traffic).
local nextRequestIdCounter = 0
local function nextRequestId()
    nextRequestIdCounter = nextRequestIdCounter + 1
    return nextRequestIdCounter
end

local COMMAND_ACTIONS = {
    startup = "STARTUP",
    scram   = "SCRAM",
}

local function sendCommand(btnId)
    local action = COMMAND_ACTIONS[btnId]
    if not action then
        return
    end

    local ok, err = secnet.broadcast(NET.PROTOCOL_PLC, MSG.COMMAND, {
        action    = action,
        requestId = nextRequestId(),
    })
    if ok then
        logStatus("[HMI] " .. action .. " broadcast sent")
    else
        logStatus("[HMI] " .. action .. " broadcast FAILED: " .. tostring(err))
    end
end

-- ===========================================================================
-- HIT-TESTING
-- ===========================================================================
local function hitTest(x, y)
    for _, btn in ipairs(buttons) do
        if y == btn.y and x >= btn.x and x < btn.x + btn.width then
            return btn
        end
    end
    return nil
end

-- ===========================================================================
-- MAIN EVENT LOOP
-- ===========================================================================
-- secnet.open() handles modem/rednet open AND secret-key loading
-- internally (see lib/secnet.lua's loadSecret(), sourced from
-- config.SECURITY.SECRET_FILE with a loud DEV_DEFAULT_SECRET fallback) -
-- nodes never touch the secret directly, matching plc.lua/supervisor.lua.
-- Non-fatal like both of those: a failed open leaves the local UI usable,
-- it just means every sendCommand() broadcast below will fail too.
--
-- secnet.open()'s only failure mode is "no modem found this call" (see
-- lib/secnet.lua) - often just a boot-order race, since a modem peripheral
-- can attach a tick or two after the computer itself starts running. A
-- single failed attempt at boot must not leave this node permanently unable
-- to send commands, so tryOpenSecnet() is retried on every "peripheral"
-- attach event below (same pattern nodes/plc.lua and nodes/supervisor.lua
-- use).
local function tryOpenSecnet()
    if secnetOpen then
        return true
    end
    local ok, err = secnet.open(nil, NET.PROTOCOL_HMI)
    if ok then
        secnetOpen = true
        logStatus("[HMI] secnet open on " .. NET.PROTOCOL_HMI)
    end
    return ok, err
end

-- One-time boot splash first - see nodes/plc.lua for the identical
-- reasoning. Purely cosmetic and non-blocking on its own; the fixed
-- os.sleep() is what holds it on screen briefly.
os_shell.drawBootSplash({
    title    = "FCS-10",
    subtitle = "Operator Console",
    role     = "HMI",
    accent   = colors.lightBlue,
})
os.sleep(1.2)

-- tryOpenSecnet() called BEFORE safeDrawUI(): loadSecret() prints a raw
-- (non-logStatus) warning when /secret.key is missing, since lib/secnet.lua
-- is a shared library with no awareness of any particular node's UI
-- conventions. Every other node is headless/log-only, where that's fine -
-- but here, calling secnet.open() first lets any such raw print happen
-- during the plain boot scroll, before safeDrawUI()'s full term.clear() +
-- redraw wipes it clean. Calling it after drawUI() (as this file used to)
-- let that raw print land mid-chrome, tearing up the button grid exactly
-- the way the STATUS CONSOLE comment above warns about.
local okOpen, openErr = tryOpenSecnet()

safeDrawUI()

if not okOpen then
    logStatus("[HMI] WARNING: secnet.open failed (" .. tostring(openErr) .. ") - will keep retrying")
end

while true do
    local event, p1, p2, p3 = os.pullEvent()

    if event == "mouse_click" then
        if currentScreen == "desktop" then
            local key = os_shell.hitTestIcons(lastDesktopIcons, p2, p3)
            if key == "update" then
                launchUpdater()
            elseif key == "console" or key == "settings" or key == "network" then
                currentScreen = key
                safeDrawUI()
            end
        elseif currentScreen == "console" then
            local btn = hitTest(p2, p3)
            if btn then
                logStatus("[HMI] " .. btn.label .. " CLICKED")
                sendCommand(btn.id)
            elseif homeHitRegion and os_shell.isHomeClick(p2, p3) then
                currentScreen = "desktop"
                safeDrawUI()
            end
        elseif currentScreen == "settings" and os_shell.isPointIn(themeButtonRegion, p2, p3) then
            os_shell.cycleTheme()
            safeDrawUI()
        elseif homeHitRegion and os_shell.isHomeClick(p2, p3) then
            -- settings/network screens
            currentScreen = "desktop"
            safeDrawUI()
        end
    elseif event == "rednet_message" then
        -- Routed through logStatus exactly like click feedback - never raw
        -- print/term writes here, so an incoming ACK can never corrupt the
        -- button grid or header (see STATUS CONSOLE section above).
        local fromId, msgType, payload = secnet.handleEvent(p1, p2)
        if fromId and msgType == MSG.ACK and type(payload) == "table" then
            logStatus(("[HMI] ACK #%s: %s%s"):format(
                tostring(payload.requestId),
                payload.accepted and "accepted" or "rejected",
                payload.reason and (" (" .. payload.reason .. ")") or ""))
        end
        -- rejections (nil, reason) from secnet.handleEvent are not errors -
        -- ignore and keep the loop running, matching plc.lua/supervisor.lua.
    elseif event == "peripheral" then
        tryOpenSecnet() -- a modem attaching this tick is exactly what "peripheral" fires for
    end

    -- Future: "timer" branch (periodic redraw/re-broadcast) and full
    -- STATE_BROADCAST/TELEMETRY consumption once this node tracks live PLC
    -- state, not just command dispatch.
end
