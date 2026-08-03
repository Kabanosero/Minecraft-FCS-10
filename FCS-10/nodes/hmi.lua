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

local NET = config.NETWORK
local MSG = config.NETWORK.MSG_TYPE

local TITLE = "FCS-10 HMI"
local STATUS_TOP = 15  -- first row of the reserved status console (bottom of screen)

-- ===========================================================================
-- THEMING
-- ===========================================================================
-- Button labels are drawn in headerText, not text: headerText is already
-- the key meant to contrast against a filled/colored surface (same role it
-- plays against headerBg), so it reads correctly on both the saturated
-- "classic" button fills and the grayscale "mono" fills below without
-- needing an 8th theme key just for button label color.
local themes = {
    classic = {
        bg         = colors.lightGray,
        text       = colors.black,
        headerBg   = colors.gray,
        headerText = colors.white,
        btnDanger  = colors.red,
        btnSafe    = colors.green,
        btnNeutral = colors.lightBlue,
    },
    mono = {
        bg         = colors.black,
        text       = colors.white,
        headerBg   = colors.white,
        headerText = colors.black,
        btnDanger  = colors.white,
        btnSafe    = colors.lightGray,
        btnNeutral = colors.gray,
    },
}

local currentTheme = themes.classic

local secnetOpen = false -- true once secnet.open() has ever succeeded (see tryOpenSecnet)

-- ===========================================================================
-- BUTTON REGISTRY
-- ===========================================================================
-- colorKey is a theme key, not a resolved color, so re-theming (setting
-- currentTheme to a different palette) re-colors every button automatically.
local buttons = {
    { id = "startup", label = "STARTUP", x = 3,  y = 5, width = 12, colorKey = "btnSafe"    },
    { id = "scram",   label = "SCRAM",   x = 17, y = 5, width = 12, colorKey = "btnDanger"  },
    { id = "exit",    label = "EXIT",    x = 31, y = 5, width = 12, colorKey = "btnNeutral" },
}

-- ===========================================================================
-- RENDERING
-- ===========================================================================
local function drawHeader(w)
    term.setBackgroundColor(currentTheme.headerBg)
    term.setTextColor(currentTheme.headerText)
    term.setCursorPos(1, 1)
    term.write(string.rep(" ", w))
    term.setCursorPos(2, 1)
    term.write(TITLE)
end

local function drawButton(btn)
    term.setBackgroundColor(currentTheme[btn.colorKey])
    term.setTextColor(currentTheme.headerText)
    term.setCursorPos(btn.x, btn.y)
    term.write(string.rep(" ", btn.width))
    term.setCursorPos(btn.x + math.floor((btn.width - #btn.label) / 2), btn.y)
    term.write(btn.label)
end

local function drawStatusBox(w, h)
    term.setBackgroundColor(currentTheme.headerBg)
    term.setTextColor(currentTheme.headerText)
    for row = STATUS_TOP, h do
        term.setCursorPos(1, row)
        term.write(string.rep(" ", w))
    end
end

local function drawUI()
    term.setBackgroundColor(currentTheme.bg)
    term.setTextColor(currentTheme.text)
    term.clear()

    local w, h = term.getSize()
    drawHeader(w)
    drawStatusBox(w, h)

    for _, btn in ipairs(buttons) do
        drawButton(btn)
    end
end

-- ===========================================================================
-- STATUS CONSOLE
-- ===========================================================================
-- All event feedback must go through here, never raw print() - print()
-- writes at the shell cursor and scrolls the terminal on overflow, which
-- would tear up the header/button chrome drawn above. logStatus always
-- targets the same fixed row and blanks it first, so it can never bleed
-- outside the reserved status box or leave stale characters behind.
local function logStatus(msg)
    local w, h = term.getSize()
    if h < STATUS_TOP then return end

    term.setBackgroundColor(currentTheme.headerBg)
    term.setTextColor(currentTheme.headerText)
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

-- Called BEFORE drawUI(): loadSecret() prints a raw (non-logStatus) warning
-- when /secret.key is missing, since lib/secnet.lua is a shared library
-- with no awareness of any particular node's UI conventions. Every other
-- node is headless/log-only, where that's fine - but here, calling
-- secnet.open() first lets any such raw print happen during the plain boot
-- scroll, before drawUI()'s full term.clear() + redraw wipes it clean.
-- Calling it after drawUI() (as this file used to) let that raw print land
-- mid-chrome, tearing up the button grid exactly the way the STATUS
-- CONSOLE comment above warns about.
local okOpen, openErr = tryOpenSecnet()

drawUI()

if not okOpen then
    logStatus("[HMI] WARNING: secnet.open failed (" .. tostring(openErr) .. ") - will keep retrying")
end

while true do
    local event, p1, p2, p3 = os.pullEvent()

    if event == "mouse_click" then
        local btn = hitTest(p2, p3)
        if btn then
            logStatus("[HMI] " .. btn.label .. " CLICKED")
            sendCommand(btn.id)
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
