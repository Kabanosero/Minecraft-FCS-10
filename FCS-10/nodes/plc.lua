-- nodes/plc.lua
-- FCS-10 / ATM-PCS :: Core Programmable Logic Controller
--
-- Runs on the computer wired directly to the reactor's
-- fissionReactorLogicAdapter. This is the Autonomous Local Protection
-- System (LPS) - the last automated line of defense against core damage,
-- and it must keep working even if the network, the Supervisor, or both
-- are gone. Nothing in this file may block for longer than a single
-- os.pullEvent() wait, and nothing here may crash: an uncaught error in
-- this process is, in effect, an unmonitored reactor.
--
-- TRIP PHILOSOPHY (NUREG-1433 / IAEA SSG-76 aligned): trips LATCH. Once
-- doScram() fires, the plant stays in SCRAMMED until a deliberate operator
-- reset - a real protection system does not silently un-trip itself just
-- because a reading crept back under threshold a moment later. There is
-- no reset action implemented in this draft (stubbed as a comment for a
-- future "RESET" COMMAND).
--
-- WHY ALL FOUR SETPOINTS TRIP LOCALLY: config.SETPOINTS names damage,
-- temperature, coolant, AND waste setpoints ending in _SCRAM. A real LPS
-- must be a fully autonomous, hardwired line of defense that never depends
-- on network reachability or a remote Supervisor - coolant depletion in
-- particular causes near-instant temperature spikes in Mekanism, so
-- waiting on a network round-trip before reacting is a real risk. All four
-- are evaluated locally, in this file, independent of comms health.
--
-- WHY 1Hz POLLING: TELEMETRY_INTERVAL_S doubles as the LPS scan rate here
-- (one reactor read feeds both the trip evaluation and the telemetry send
-- - polling twice at different rates would just double peripheral calls
-- for no safety benefit). 1 second is far slower than a real plant's
-- millisecond-scale RPS scan rate, but this is Mekanism game physics, not
-- real neutronics - damage/temperature accrue gradually per server tick
-- with heat-capacity buffering, so a 1-second reaction time is adequate,
-- and config.lua does not define a separate faster cadence to fork from.
--
-- PROTOCOL ADDRESSING (easy to get backwards, read this before editing):
-- PROTOCOL_PLC is what THIS node hosts/listens on for inbound
-- COMMAND/HEARTBEAT. Everything this node SENDS (TELEMETRY, its own
-- outbound HEARTBEAT, SCRAM, ACK) is tagged PROTOCOL_SUPERVISOR - the
-- audience's protocol, not this node's own.
--
-- SCOPE: this project uses one shared network-wide HMAC secret (see
-- lib/secnet.lua). That proves "sender holds the secret", not "sender is
-- specifically the Supervisor" - so COMMAND is accepted from any
-- authenticated sender. That is a conscious, already-documented v1
-- limitation, not something this file attempts to fix.
--
-- LOTO (LOCKOUT/TAGOUT) PHILOSOPHY (IAEA SSG-76 aligned, v1 simplification):
-- Mekanism's fission reactor is one monolithic peripheral - no valves or
-- sub-components exist to tag individually - so a tag applies to the whole
-- PLC/reactor, the only real isolation point this hardware model has. This
-- is also a single-tag-slot model, not a multi-lock stack: see lotoTag
-- below and the COMMAND contract doc-comment for exact idempotency
-- behavior. Gated by the Shift Supervisor key (see lib/rbac.lua) - a
-- SEPARATE secret from the network HMAC secret above, carrying the same
-- conscious "proves role, not individual identity" limitation that secret
-- already has for node identity. A tag NEVER blocks SCRAM (doScram() is
-- completely untouched by LOTO) but DOES unconditionally block
-- SET_BURN_RATE while active, even for a Shift Supervisor re-supplying the
-- key - the tag must be explicitly removed first, no bypass.
--
-- OPERATING MODES: a plant-lifecycle phase (Cold Start/Bypass, Run-Up, Hot
-- Standby, Normal Operation, Auto-Runback), orthogonal to reactorState's
-- plantState (which is safety/alarm status, not lifecycle phase) - derived
-- automatically each poll from burn rate and core temperature, never from
-- a human declaration. "Hot Standby" here (not actively producing power,
-- but core still above the ~200F Hot/Cold boundary) and real Tech-Spec-
-- style "Hot Shutdown" definitions describe the same physical condition;
-- this file uses the operator-facing "Hot Standby" name. Auto-Runback is a
-- genuinely new protective automation: an automated, one-time burn-rate
-- reduction on a HIGH_ALARM-tier fault, short of a full SCRAM - it bypasses
-- LOTO entirely (a protective power reduction must never be blocked by an
-- administrative tag, same reasoning as SCRAM bypassing LOTO) and does not
-- auto-restore burn rate afterward (an operator must deliberately ramp
-- back up). Steam bypass / testing mode / EPG are simulated-only flags (no
-- real Mekanism turbine/generator/speaker peripheral exists in this
-- project) - opening/closing the steam bypass is an Operator-tier "non-
-- critical valve" action (no RBAC gate); entering/exiting Testing mode
-- requires the Shift Supervisor key, matching real plant practice for
-- authorizing a safety-test regime.

local REACTOR_TYPE = "fissionReactorLogicAdapter"

-- ---------------------------------------------------------------------------
-- Safe library load - a failure here has no meaningful degraded mode (the
-- rest of this script is undefined without config/secnet), so it's a
-- logged, controlled exit. This is the ONE failure mode in this file that
-- does not fall through into the always-running event loop below.
-- ---------------------------------------------------------------------------
local okCfg, config = pcall(dofile, "/lib/config.lua")
if not okCfg then
    print("[PLC] FATAL: failed to load /lib/config.lua: " .. tostring(config))
    return
end

local okSn, secnet = pcall(dofile, "/lib/secnet.lua")
if not okSn then
    print("[PLC] FATAL: failed to load /lib/secnet.lua: " .. tostring(secnet))
    return
end

local okShell, os_shell = pcall(dofile, "/lib/os_shell.lua")
if not okShell then
    print("[PLC] FATAL: failed to load /lib/os_shell.lua: " .. tostring(os_shell))
    return
end

-- rbac (Shift Supervisor key check) load is intentionally NON-FATAL, unlike
-- config/secnet above: SCRAM and the LPS trip logic must never depend on
-- it. If it fails to load, `rbac` stays nil and checkSupervisorGate() below
-- fails CLOSED on every SET_BURN_RATE/APPLY_TAG/REMOVE_TAG/ENTER_TESTING/
-- EXIT_TESTING (reason "rbac-unavailable") until fixed - a controls gate
-- that's down should refuse controls, not silently allow them.
local okRbac, rbacModule = pcall(dofile, "/lib/rbac.lua")
local rbac = okRbac and rbacModule or nil
if not okRbac then
    print("[PLC] WARNING: failed to load /lib/rbac.lua: " .. tostring(rbacModule) ..
          " - SET_BURN_RATE/APPLY_TAG/REMOVE_TAG/ENTER_TESTING/EXIT_TESTING will be rejected until fixed")
end

-- gfx (CC:Graphics gauges/pixel-text) load is also NON-FATAL, same reasoning
-- as rbac above: reactor telemetry must never depend on an optional visual
-- mod. gfxLoadFailed is tracked separately from `gfx` itself: if the real
-- module fails to load, `gfx` is reassigned below to a minimal shim that
-- mimics its own text-mode fallback behavior (same call signatures, always
-- routes to plain term.write) - this way drawScadaScreen never needs a
-- separate "gfx missing entirely" branch, only the drawNetworkScreen
-- diagnostic (which needs to tell the two cases apart for the operator)
-- checks gfxLoadFailed directly.
local okGfx, gfxModule = pcall(dofile, "/lib/gfx.lua")
local gfxLoadFailed = not okGfx
local gfx = okGfx and gfxModule or nil
if gfxLoadFailed then
    print("[PLC] WARNING: failed to load /lib/gfx.lua: " .. tostring(gfxModule) ..
          " - SCADA screen will render as plain text")
    gfx = {
        beginFrame = function() return false end,
        endFrame   = function() end,
        clear      = function(bg) term.setBackgroundColor(bg); term.clear() end,
        drawText   = function(x, y, text, fg, bg)
            term.setCursorPos(x, y)
            if bg then term.setBackgroundColor(bg) end
            term.setTextColor(fg or colors.white)
            term.write(tostring(text or ""))
        end,
        drawBarMeter = function(x, y, w, h, pct, fillColor, bgColor, fallbackText)
            term.setCursorPos(x, y)
            term.setTextColor(fillColor or colors.white)
            term.write(fallbackText or "")
        end,
    }
end

local NET    = config.NETWORK
local MSG    = config.NETWORK.MSG_TYPE
local SP     = config.SETPOINTS
local STATES = config.STATES

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------
local reactor            = nil    -- wrapped peripheral handle, or nil if unbound
local reactorSide         = nil    -- side/name reactor was wrapped from, for detach matching
local peripheralPresent   = false  -- true only while `reactor` is a live, working handle
local reactorState        = config.newDefaultReactorState() -- reused SSOT shape, mutated in place
local lastScramActuationConfirmed = nil -- nil until the first SCRAM ever fires

local lotoTag         = nil -- nil = untagged; else { reason, appliedAt, appliedBy }
local operatingMode   = config.OPERATING_MODES.COLD_START_BYPASS -- see header "OPERATING MODES"
local steamBypassOpen = true  -- simulated valve, Operator-tier (no RBAC gate)
local testingMode     = false -- simulated flag, Shift-Supervisor-gated
local epgActive       = false -- simulated flag, set true on first SCRAM, never reset
local inRunback       = false -- edge-detection latch for Auto-Runback entry/exit

local secnetOpen = false -- true once secnet.open() has ever succeeded (see tryOpenSecnet)

-- currentScreen drives ONLY which draw function runs and where mouse_click
-- is routed - see "VISUAL DASHBOARD / DESKTOP SHELL" below. It has zero
-- effect on the poll/broadcast/trip logic above, which runs identically no
-- matter what's on screen.
local currentScreen    = "desktop" -- "desktop" | "scada" | "settings" | "network"
local lastDesktopIcons = {}        -- laid-out icon hit-regions from the last drawDesktopScreen()

-- Forward-declared (defined below unbindReactor, which needs to call it)
-- so it stays a proper local rather than leaking into _G.
local broadcastTelemetry

-- ===========================================================================
-- VISUAL DASHBOARD / DESKTOP SHELL - a continuously-redrawn, screen-based
-- UI built on lib/os_shell.lua's shared boot-splash/desktop/chrome helpers,
-- same move nodes/hmi.lua/supervisor.lua already made away from a plain
-- print() scroll. Every print() call site below this point (i.e. everything
-- reachable once main() draws the first frame) is replaced with logLine()
-- instead: print() writes at the shell cursor and scrolls the terminal on
-- overflow, which would tear up this drawn screen exactly the way
-- nodes/hmi.lua's own STATUS CONSOLE comment already documents for that
-- file - a full-screen dashboard and raw print() cannot coexist. The
-- handful of print()s ABOVE this point (config/secnet/os_shell FATAL, the
-- rbac WARNING) are deliberately left as raw prints: they happen during the
-- plain boot scroll before the first draw() below wipes the screen clean,
-- the same idiom hmi.lua already established for its own pre-drawUI()
-- secnet.open() warning.
--
-- INTERACTIVE, but navigation-only: clicking desktop icons or the HOME
-- button in sub-screen chrome only changes currentScreen (a purely local
-- display choice) - it never issues a reactor command. There is still NO
-- SCRAM/burn-rate/LOTO button anywhere on this screen: an operator standing
-- at THIS terminal issuing reactor commands would bypass the network-
-- authenticated COMMAND path every real control surface (Supervisor/HMI/
-- test harness) goes through. The desktop's UPDATE icon is the one
-- exception that does something beyond navigation - it shells out to the
-- existing installer.lua (see launchUpdater()), not a reactor action.
-- ===========================================================================
local LOG_LINES = 6
local uiLog = {}

local function logLine(msg)
    uiLog[#uiLog + 1] = msg
    while #uiLog > LOG_LINES do
        table.remove(uiLog, 1)
    end
end

local function fmtAge(ms)
    if ms < 0 then
        ms = 0
    end
    local s = ms / 1000
    if s < 60 then
        return string.format("%.0fs", s)
    end
    return string.format("%.0fm", s / 60)
end

local STATE_COLOR = {
    [STATES.NORMAL]   = colors.green,
    [STATES.ANOMALY]  = colors.orange,
    [STATES.SCRAMMED] = colors.red,
}

local homeHitRegion = nil -- HOME button hit-region from the last sub-screen chrome draw

-- ---------------------------------------------------------------------------
-- SCADA screen - drawn ENTIRELY through lib/gfx.lua's gfx.drawText/
-- gfx.drawBarMeter (real pixels via CC:Graphics when available, plain text
-- otherwise - see each function's own fallback contract), never a bare
-- term.write. This is the fix for a regression this project hit and
-- reverted earlier: CC:Graphics' graphics mode is a confirmed whole-screen
-- toggle, not a per-widget overlay - the instant it's active, ANY plain
-- term.write on this screen (header, labels, numbers, LOG) gets buffered
-- into a hidden text layer and never displays, since only one buffer (text
-- OR graphics) is shown at a time. The earlier version of this screen
-- called gfx.beginFrame() but still used term.write for everything except
-- the bar meters, so entering graphics mode blanked every label - it had to
-- be reverted to ASCII-only bars until gfx.drawText (a full bitmap-font text
-- renderer) existed to close that gap. Now that it does, gfx.beginFrame()
-- is safe to call again: every remaining draw call below goes through gfx.*,
-- so nothing left on this screen can vanish. bandColor picks the same
-- green/yellow/red severity a real SCADA gauge would, using this file's own
-- SP.* setpoint bands (config.lua SETPOINTS) rather than inventing new
-- thresholds - see lib/config.lua for the exact numbers.
-- ---------------------------------------------------------------------------
local GAUGE_LABEL_W, GAUGE_VALUE_W = 5, 7

-- `invert=true` means LOWER is worse (coolant%) - everything else here is
-- HIGHER is worse.
local function bandColor(value, warn, high, invert)
    if invert then
        if value <= high then return colors.red end
        if value <= warn then return colors.yellow end
        return colors.green
    end
    if value >= high then return colors.red end
    if value >= warn then return colors.yellow end
    return colors.green
end

-- Draws one labeled gauge row at `row`: "LABEL" + a bar-meter spanning the
-- middle of the line + the exact numeric value right-aligned at the end.
-- `pct` (0-100, clamped) drives the bar fill; `valueText` is the precise
-- human-readable value shown regardless of graphics mode - an operator
-- needs the real number, a bar alone is never precise enough on its own.
-- `theme` is threaded through purely so the label/value text always paints
-- an explicit background (theme.bg) rather than inheriting whatever the
-- terminal's "current" background happens to be - see gfx.drawText's
-- fallback contract: in plain-text mode there's no separate pixel buffer to
-- isolate calls from each other, so every call site here sets its own
-- background explicitly rather than risk one row's color bleeding into the
-- next (this is exactly the kind of bug the STATE band below would cause if
-- left implicit).
local function drawMetricGauge(w, dataColor, row, label, pct, valueText, fillColor, theme)
    gfx.drawText(1, row, ("%-" .. GAUGE_LABEL_W .. "s"):format(label), dataColor, theme.bg)

    local gaugeX = GAUGE_LABEL_W + 1
    local gaugeW = math.max(1, w - gaugeX - GAUGE_VALUE_W - 1)
    local clamped = math.max(0, math.min(100, pct or 0))
    local filled = math.floor(gaugeW * clamped / 100 + 0.5)
    local asciiBar = string.rep("#", filled) .. string.rep("-", gaugeW - filled)

    gfx.drawBarMeter(gaugeX, row, gaugeW, 1, clamped, fillColor, colors.gray, asciiBar)

    gfx.drawText(w - GAUGE_VALUE_W + 1, row, ("%" .. GAUGE_VALUE_W .. "s"):format(valueText), dataColor, theme.bg)
end

local function drawScadaScreen()
    local w, h = term.getSize()
    local theme = os_shell.THEME

    -- gfx.beginFrame() turns on real graphics mode when CC:Graphics is
    -- present; when it's not (or lib/gfx.lua itself failed to load - see
    -- the gfxLoadFailed shim above), it returns false and every gfx.* call
    -- below silently falls back to today's plain text rendering instead -
    -- this function never needs to know which case it's in.
    gfx.beginFrame()
    gfx.clear(theme.bg)

    -- Header row: a HOME "button" (filled accent box + black text) plus the
    -- screen title, replacing os_shell.drawScreenHeader()'s ASCII bezel -
    -- this screen no longer calls it, since its term.write calls would
    -- vanish the instant graphics mode is active. os_shell.isHomeClick(x, y)
    -- checks a fixed (1,1)-(8,1) region regardless of what's drawn there, so
    -- this button's exact 8-column width is what keeps the visual and the
    -- click target aligned; homeHitRegion itself only needs to be non-nil
    -- (it's just the "a header was drawn this session" guard main() checks).
    gfx.drawText(1, 1, " <HOME> ", colors.black, theme.accent)
    gfx.drawText(10, 1, ("SCADA - PLC #%d"):format(os.getComputerID()), theme.text, theme.bg)
    homeHitRegion = { x = 1, y = 1, w = 8, h = 1 }

    -- Colored status bar, same convention as supervisor.lua's SYSTEM line -
    -- plantState is the safety/alarm status, operatingMode the lifecycle
    -- phase (see file header "OPERATING MODES") - both matter enough to an
    -- operator to always be visible, never tabbed away. Black text on a
    -- semantic status color (not a theme color) so it stays fixed across
    -- palettes on purpose.
    local stateLine = (" STATE: %s   MODE: %s "):format(
        reactorState.plantState, (operatingMode or "?"):gsub("_", " "))
    stateLine = stateLine .. string.rep(" ", math.max(0, w - #stateLine))
    gfx.drawText(1, 2, stateLine, colors.black, STATE_COLOR[reactorState.plantState] or colors.gray)

    -- dataColor: "fresh" reads as the theme's normal text color, "stale"
    -- stays semantically orange regardless of theme.
    local dataColor = reactorState.online and theme.text or colors.orange

    -- Rows 4-7: DMG/T-K/CLT/WST gauges.
    drawMetricGauge(w, dataColor, 4, "DMG", reactorState.damagePct,
        ("%.1f%%"):format(reactorState.damagePct),
        bandColor(reactorState.damagePct, SP.DAMAGE.WARNING, SP.DAMAGE.HIGH_ALARM), theme)
    drawMetricGauge(w, dataColor, 5, "T-K", reactorState.coreTempK / SP.CORE_TEMP_K.SCRAM * 100,
        ("%.0fK"):format(reactorState.coreTempK),
        bandColor(reactorState.coreTempK, SP.CORE_TEMP_K.WARNING, SP.CORE_TEMP_K.HIGH_ALARM), theme)
    drawMetricGauge(w, dataColor, 6, "CLT", reactorState.coolantPct,
        ("%.1f%%"):format(reactorState.coolantPct),
        bandColor(reactorState.coolantPct, SP.COOLANT_PCT.LOW_WARNING, SP.COOLANT_PCT.LOW_ALARM, true), theme)
    drawMetricGauge(w, dataColor, 7, "WST", reactorState.wastePct,
        ("%.1f%%"):format(reactorState.wastePct),
        bandColor(reactorState.wastePct, SP.WASTE_PCT.HIGH_WARNING, SP.WASTE_PCT.HIGH_ALARM), theme)

    local ageText = reactorState.lastUpdate > 0
        and fmtAge(os.epoch("utc") - reactorState.lastUpdate) or "--"
    gfx.drawText(1, 8, ("BURN %5.1f mB/t   HW: %-7s  AGE: %s"):format(
        reactorState.burnRateMbT, peripheralPresent and "PRESENT" or "ABSENT", ageText), dataColor, theme.bg)

    if lotoTag then
        gfx.drawText(1, 10, ("LOTO: TAGGED - %s"):format(lotoTag.reason), colors.red, theme.bg)
    else
        gfx.drawText(1, 10, "LOTO: none", theme.text, theme.bg)
    end

    gfx.drawText(1, 11, ("TESTING: %-3s  EPG: %-6s  ACT: %s"):format(
        testingMode and "ON" or "off",
        epgActive and "ACTIVE" or "--",
        lastScramActuationConfirmed == nil and "--"
            or (lastScramActuationConfirmed and "CONFIRMED" or "UNCONFIRMED")), theme.text, theme.bg)

    gfx.drawText(1, 13, "LOG:", theme.dim, theme.bg)
    for i, line in ipairs(uiLog) do
        local row = 13 + i
        if row > h then
            break
        end
        local text = line
        if #text > w then
            text = text:sub(1, w)
        end
        gfx.drawText(1, row, text, theme.text, theme.bg)
    end
end

-- Desktop icons - "SCADA" is this node's core reactor screen (the function
-- above); SETTINGS/NETWORK are read-only info screens; UPDATE isn't a
-- screen at all, see launchUpdater() below.
local DESKTOP_ICONS = {
    { key = "scada",    label = "SCADA",    color = colors.red },
    { key = "settings", label = "SETTINGS", color = colors.gray },
    { key = "network",  label = "NETWORK",  color = colors.cyan },
    { key = "update",   label = "UPDATE",   color = colors.blue },
}

local function drawDesktopScreen()
    lastDesktopIcons = os_shell.drawDesktop({
        title       = ("FCS-10 PLC #%d"):format(os.getComputerID()),
        statusRight = ("STATE: %s"):format(reactorState.plantState),
        statusColor = STATE_COLOR[reactorState.plantState] or os_shell.THEME.text,
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
        { label = "Role",           value = "PLC" },
        { label = "Computer ID",    value = os.getComputerID() },
        { label = "Reactor HW",     value = peripheralPresent and "PRESENT" or "ABSENT",
          color = peripheralPresent and colors.green or colors.red },
        { label = "Plant state",    value = reactorState.plantState,
          color = STATE_COLOR[reactorState.plantState] or theme.text },
        { label = "Operating mode", value = (operatingMode or "?"):gsub("_", " ") },
        { label = "LOTO",           value = lotoTag and ("TAGGED: " .. lotoTag.reason) or "none",
          color = lotoTag and colors.red or theme.text },
        { label = "Testing mode",   value = testingMode and "ON" or "off" },
        { label = "EPG",            value = epgActive and "ACTIVE" or "--" },
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
    local ageText = reactorState.lastUpdate > 0
        and fmtAge(os.epoch("utc") - reactorState.lastUpdate) or "--"
    -- CC:Graphics diagnostic - see lib/gfx.lua's diagnose(): reports which
    -- specific named functions are/aren't present on `term` right now, not
    -- just a single available/not-available bit, since this integration is
    -- still unverified against CC:Graphics' own docs (none could be found).
    local diagRows = {
        { label = "secnet",         value = secnetOpen and "OPEN" or "NOT OPEN",
          color = secnetOpen and colors.green or colors.red },
        { label = "Hosts on",       value = NET.PROTOCOL_PLC },
        { label = "Sends to",       value = NET.PROTOCOL_SUPERVISOR },
        { label = "Last reading age", value = ageText },
        { label = "Heartbeat every",  value = NET.HEARTBEAT_INTERVAL_S .. "s" },
        { label = "Watchdog timeout", value = NET.HEARTBEAT_TIMEOUT_S .. "s" },
    }
    if not gfxLoadFailed then
        local d = gfx.diagnose()
        diagRows[#diagRows + 1] = { label = "CC:Graphics", value = d.available and "AVAILABLE" or "NOT AVAILABLE",
            color = d.available and colors.green or colors.red }
        diagRows[#diagRows + 1] = { label = "  setGraphicsMode", value = tostring(d.setGraphicsMode) }
        diagRows[#diagRows + 1] = { label = "  setPixel",        value = tostring(d.setPixel) }
        diagRows[#diagRows + 1] = { label = "  drawPixels",      value = tostring(d.drawPixels) }
        diagRows[#diagRows + 1] = { label = "  setFrozen",       value = tostring(d.setFrozen) }
    else
        diagRows[#diagRows + 1] = { label = "CC:Graphics", value = "lib/gfx.lua failed to load", color = colors.red }
    end
    os_shell.drawKeyValueList(diagRows, 3)
    local _, h = term.getSize()
    os_shell.drawScreenFrame(1, h)
end

-- Single dispatch point every draw call site below goes through - which
-- screen function actually runs depends only on currentScreen, a purely
-- local display choice with no effect on the poll/trip logic above (see
-- module state comment). Screens themselves never sleep or block.
local function draw()
    -- Unconditional, every tick, BEFORE branching: guarantees the terminal
    -- starts this draw from a known text-mode state no matter which screen
    -- ran last tick (or whether it left graphics mode on because it hit an
    -- error - see lib/gfx.lua's own doc comment on this exact pattern).
    -- drawScadaScreen() is the only screen that turns graphics mode back on,
    -- and only for itself. `gfx` is never nil here (real module or the
    -- gfxLoadFailed shim - see the load block above), so this is always safe
    -- to call unconditionally.
    gfx.endFrame()

    if currentScreen == "scada" then
        drawScadaScreen()
    elseif currentScreen == "settings" then
        drawSettingsScreen()
    elseif currentScreen == "network" then
        drawNetworkScreen()
    else
        drawDesktopScreen()
    end
end

-- Dedicated pcall boundary, same reasoning as supervisor.lua's safeRedraw():
-- drawing must never be allowed to kill this node's main loop. Falls back
-- to a raw print() on failure since a broken draw() means the on-screen log
-- panel itself may not be trustworthy right now.
local function safeDraw()
    local ok, err = pcall(draw)
    if not ok then
        print("[PLC] draw failed (non-fatal): " .. tostring(err))
    end
end

-- Shells out to the existing installer.lua (already proven CLI: see
-- installer.lua's "update" action) to check/update this node's own files.
-- Deliberately targets role "plc" directly rather than the interactive
-- "start" GUI - this desktop's UPDATE icon should only ever do the one
-- thing it's labeled for, not also expose Install/Clear from inside a live
-- reactor controller. shell.run() blocks until installer.lua exits, during
-- which this node's own os.pullEvent() loop is NOT running - poll/heartbeat
-- timers already queued still fire the instant control returns (CC:Tweaked
-- timers are wall-clock, not pump-driven), and if the pause runs past
-- HEARTBEAT_TIMEOUT_S the watchdog will correctly trip on resume: that is
-- the fail-safe working as designed, not a bug, which is why this is
-- clearly logged before launching rather than silently swallowed. Never
-- auto-reboots (installer.lua's own "update" action only prints a
-- reminder) - a live PLC's files changing on disk does not affect the
-- already-running process until a deliberate, separate reboot.
local function launchUpdater()
    logLine("UPDATE: opening installer - reactor polling pauses until it returns")
    safeDraw()
    pcall(function()
        shell.run("/installer.lua", "update", "plc")
        os.sleep(2) -- brief, bounded pause so the printed result is readable, never indefinite
    end)
    logLine("UPDATE: installer closed, resuming normal operation")
    safeDraw()
end

-- ===========================================================================
-- Peripheral loss / reacquisition
-- ===========================================================================
-- Shared transition-handler for "we no longer have a working reactor
-- handle" - called from a failed metrics read, a failed actuation pcall,
-- or a matching peripheral_detach event. Idempotent (only acts on the
-- present -> absent edge) and latch-aware (never overwrites an existing
-- SCRAMMED plant state with ANOMALY - if the plant was already tripped,
-- losing the peripheral doesn't make it less tripped).
local function unbindReactor(reason)
    if not peripheralPresent then
        return -- already unbound (or never bound) - nothing to transition
    end

    reactor, reactorSide, peripheralPresent = nil, nil, false
    reactorState.online = false -- NOTE: other metrics are deliberately left as-is
                                 -- (last known values), never zeroed - reporting
                                 -- "damage 0%" while blind would be a lie, not a status
    if reactorState.plantState ~= STATES.SCRAMMED then
        reactorState.plantState = STATES.ANOMALY
    end

    logLine("reactor peripheral lost: " .. tostring(reason))
    safeDraw()

    -- Immediate out-of-cycle broadcast (in addition to the regular 1s
    -- cadence) so the Supervisor learns about hardware loss as fast as
    -- possible rather than waiting for the next scheduled tick.
    broadcastTelemetry()
end

-- Shared TELEMETRY broadcast, used by every call site that needs an
-- immediate out-of-cycle update (this function, doScram-adjacent LOTO/mode
-- changes below) as well as pollAndEvaluate's regular per-tick broadcast.
-- lotoTag/operatingMode/steamBypassOpen/testingMode/epgActive are all
-- orthogonal to reactorState (see header) so they ride alongside it here
-- rather than being folded into the shared SSOT state shape.
broadcastTelemetry = function()
    return secnet.broadcast(NET.PROTOCOL_SUPERVISOR, MSG.TELEMETRY, {
        state              = reactorState,
        peripheralPresent  = peripheralPresent,
        actuationConfirmed = lastScramActuationConfirmed,
        plcId              = os.getComputerID(),
        role               = "PLC",
        loto               = lotoTag,
        operatingMode      = operatingMode,
        steamBypassOpen    = steamBypassOpen,
        testingMode        = testingMode,
        epgActive          = epgActive,
    })
end

-- Attempts to (re)bind the reactor peripheral. `sideHint` is the side name
-- from a "peripheral" attach event (validated against REACTOR_TYPE, since
-- that event fires for ANY peripheral attaching on ANY side - a monitor or
-- disk drive attaching must never be mistaken for the reactor); pass nil to
-- do a fresh peripheral.find() sweep instead (used at boot and as an
-- opportunistic per-tick retry). No-ops if already bound - never clobbers
-- a working handle.
local function tryBindReactor(sideHint)
    if reactor then
        return
    end

    local side, wrapped

    if sideHint then
        local okType, ptype = pcall(peripheral.getType, sideHint)
        if okType and ptype == REACTOR_TYPE then
            local okWrap, w = pcall(peripheral.wrap, sideHint)
            if okWrap and w then
                side, wrapped = sideHint, w
            end
        end
    else
        local okFind, found = pcall(peripheral.find, REACTOR_TYPE)
        if okFind and found then
            wrapped = found
            local okName, name = pcall(peripheral.getName, found)
            if okName then
                side = name
            end
        end
    end

    if wrapped and side then
        reactor, reactorSide, peripheralPresent = wrapped, side, true
        reactorState.online = true
        logLine("reactor bound on side " .. side)
        safeDraw()
    end
end

-- Attempts to open secnet if it hasn't succeeded yet. secnet.open()'s only
-- failure mode is "no modem found this call" (see lib/secnet.lua), which is
-- often just a boot-order race - a modem peripheral can attach a tick or
-- two after the computer itself starts running, so a single attempt at
-- boot can miss a modem that is physically present and will be found on
-- the very next retry. No-ops once secnetOpen is true - never re-hosts an
-- already-open protocol. Called at boot, opportunistically every poll tick,
-- and on every "peripheral" attach event (same belt-and-suspenders pattern
-- tryBindReactor uses for the reactor).
local function tryOpenSecnet()
    if secnetOpen then
        return true
    end
    local ok, err = secnet.open(nil, NET.PROTOCOL_PLC)
    if ok then
        secnetOpen = true
        logLine("secnet opened")
        safeDraw()
    end
    return ok, err
end

-- ===========================================================================
-- doScram - one shared, latched, idempotent trip function
-- ===========================================================================
-- Used by every trip path in this file: the four LPS setpoint trips, the
-- heartbeat-timeout fail-safe, and a manual SCRAM COMMAND. Latches on
-- first call (see file header) - safe to call repeatedly.
local function doScram(reason)
    if reactorState.plantState == STATES.SCRAMMED then
        return -- already latched: no re-actuation, no duplicate broadcast
    end

    -- Latch BEFORE attempting actuation, so that if an actuation pcall
    -- below fails and triggers unbindReactor(), its latch-check already
    -- sees SCRAMMED and correctly refuses to downgrade to ANOMALY.
    reactorState.plantState = STATES.SCRAMMED

    local hadReactor = reactor ~= nil
    local burnOk, scramOk = false, false
    if hadReactor then
        local ok1, err1 = pcall(reactor.setBurnRate, 0)
        local ok2, err2 = pcall(reactor.scram)

        -- Mekanism throws "Scram requires the reactor to be active" when the
        -- reactor is already inactive (not producing) - that is not a
        -- hardware failure, it's the reactor already sitting at SCRAM's
        -- target state (tripped/not running). Treating it as an actuation
        -- failure would incorrectly unbind a perfectly healthy peripheral
        -- every time the fail-safe watchdog fires against an idle reactor
        -- (e.g. during Cold Start/Bypass with burn rate 0) - count it as a
        -- successful trip instead.
        local alreadyInactive = not ok2 and type(err2) == "string"
            and err2:find("requires the reactor to be active", 1, true) ~= nil

        burnOk, scramOk = ok1, ok2 or alreadyInactive
        if not (ok1 and scramOk) then
            unbindReactor("actuation failure during SCRAM: " .. tostring(err1 or err2))
        end
    end

    -- ATWS-style distinction (Anticipated Transient Without Scram): "we
    -- declared a trip" and "we confirmed it actuated" are not the same
    -- fact. secnet.broadcast is fire-and-forget with no delivery
    -- guarantee, and a network blackout is literally one of the scenarios
    -- this system defends against, so this flag is carried in every
    -- subsequent TELEMETRY tick too, not just the one-shot SCRAM broadcast.
    lastScramActuationConfirmed = hadReactor and burnOk and scramOk
    reactorState.burnRateMbT = 0

    -- Simulated flag only (no real Mekanism generator/redstone peripheral
    -- integration exists in this project - see header). Never reset, same
    -- as SCRAM itself has no reset mechanism yet either.
    epgActive = true

    logLine(("SCRAM (%s): %s"):format(
        lastScramActuationConfirmed and "actuation confirmed" or "**ACTUATION UNCONFIRMED**",
        reason))
    safeDraw()

    secnet.broadcast(NET.PROTOCOL_SUPERVISOR, MSG.SCRAM, {
        reason = reason,
        metrics = {
            damagePct   = reactorState.damagePct,
            coreTempK   = reactorState.coreTempK,
            coolantPct  = reactorState.coolantPct,
            wastePct    = reactorState.wastePct,
            burnRateMbT = reactorState.burnRateMbT,
            online      = reactorState.online,
        },
        actuationConfirmed = lastScramActuationConfirmed,
        plcId = os.getComputerID(),
        ts    = os.epoch("utc"),
    })
end

-- ===========================================================================
-- Poll + LPS evaluate + telemetry (one timer tick, see file header)
-- ===========================================================================
local function pollAndEvaluate()
    if reactor then
        local ok1, damage  = pcall(reactor.getDamagePercent)
        local ok2, temp    = pcall(reactor.getTemperature)
        local ok3, burn    = pcall(reactor.getBurnRate)
        local ok4, coolant = pcall(reactor.getCoolant)
        local ok5, waste   = pcall(reactor.getWaste)

        if not (ok1 and ok2 and ok3 and ok4 and ok5) then
            unbindReactor("metrics read failed")
        else
            reactorState.damagePct   = damage
            reactorState.coreTempK   = temp
            reactorState.burnRateMbT = burn

            -- getCoolant()/getWaste() return raw {amount, capacity} tank
            -- tables, not a percentage - compute it here, guarding against
            -- a transient capacity==0 (e.g. right after a structure change)
            -- rather than dividing by zero.
            if type(coolant) == "table" and type(coolant.capacity) == "number" and coolant.capacity > 0 then
                reactorState.coolantPct = coolant.amount / coolant.capacity * 100
            end
            if type(waste) == "table" and type(waste.capacity) == "number" and waste.capacity > 0 then
                reactorState.wastePct = waste.amount / waste.capacity * 100
            end

            reactorState.online     = true
            reactorState.lastUpdate = os.epoch("utc")
            reactorState.seq        = reactorState.seq + 1

            -- Latched: once SCRAMMED, never re-evaluate thresholds again
            -- (readings are still recorded/reported above, just never used
            -- to move plantState away from SCRAMMED).
            if reactorState.plantState ~= STATES.SCRAMMED then
                if reactorState.damagePct >= SP.DAMAGE.SCRAM then
                    doScram(("PRIMARY TRIP: damage %.1f%% >= SCRAM setpoint %d%%"):format(
                        reactorState.damagePct, SP.DAMAGE.SCRAM))
                elseif reactorState.coreTempK >= SP.CORE_TEMP_K.SCRAM then
                    doScram(("SECONDARY TRIP: core temp %.1fK >= SCRAM setpoint %dK"):format(
                        reactorState.coreTempK, SP.CORE_TEMP_K.SCRAM))
                elseif reactorState.coolantPct <= SP.COOLANT_PCT.LOW_SCRAM then
                    doScram(("TERTIARY TRIP: coolant %.1f%% <= SCRAM setpoint %d%%"):format(
                        reactorState.coolantPct, SP.COOLANT_PCT.LOW_SCRAM))
                elseif reactorState.wastePct >= SP.WASTE_PCT.HIGH_SCRAM then
                    doScram(("QUATERNARY TRIP: waste %.1f%% >= SCRAM setpoint %d%%"):format(
                        reactorState.wastePct, SP.WASTE_PCT.HIGH_SCRAM))
                else
                    reactorState.plantState = STATES.NORMAL
                end
            end

            -- Auto-Runback + Operating Mode derivation - only meaningful
            -- while not SCRAMMED (a latched trip freezes operatingMode at
            -- its last value, same "don't recompute past a trip"
            -- philosophy as the block above; doScram() above may have just
            -- fired this same tick, hence re-checking plantState here).
            if reactorState.plantState ~= STATES.SCRAMMED then
                local highAlarm = reactorState.damagePct >= SP.DAMAGE.HIGH_ALARM
                    or reactorState.coreTempK >= SP.CORE_TEMP_K.HIGH_ALARM
                    or reactorState.coolantPct <= SP.COOLANT_PCT.LOW_ALARM
                    or reactorState.wastePct >= SP.WASTE_PCT.HIGH_ALARM
                local recovered = reactorState.damagePct < SP.DAMAGE.WARNING
                    and reactorState.coreTempK < SP.CORE_TEMP_K.WARNING
                    and reactorState.coolantPct > SP.COOLANT_PCT.LOW_WARNING
                    and reactorState.wastePct < SP.WASTE_PCT.HIGH_WARNING

                -- Edge-triggered: reduce burn rate ONCE on entry, not every
                -- tick spent in alarm (that would exponentially decay it).
                -- Hysteresis on exit (must drop below WARNING, not just
                -- below HIGH_ALARM) avoids flapping right at the boundary.
                if highAlarm and not inRunback then
                    inRunback = true
                    if reactor and reactorState.burnRateMbT > 0 then
                        local newRate = reactorState.burnRateMbT * SP.RUNBACK.REDUCTION_FACTOR
                        local okRunback = pcall(reactor.setBurnRate, newRate)
                        if okRunback then
                            logLine(("AUTO-RUNBACK: burn rate reduced to %.1f mB/t"):format(newRate))
                        end
                    end
                elseif inRunback and recovered then
                    inRunback = false
                    logLine("AUTO-RUNBACK cleared - conditions recovered")
                end

                if inRunback then
                    operatingMode = config.OPERATING_MODES.AUTO_RUNBACK
                elseif reactorState.burnRateMbT > 0 then
                    operatingMode = config.OPERATING_MODES.NORMAL_OPERATION
                elseif reactorState.coreTempK > SP.CORE_TEMP_K.HOT_COLD_BOUNDARY then
                    operatingMode = config.OPERATING_MODES.HOT_STANDBY
                elseif steamBypassOpen then
                    operatingMode = config.OPERATING_MODES.COLD_START_BYPASS
                else
                    operatingMode = config.OPERATING_MODES.RUN_UP
                end
            end
        end
    else
        tryBindReactor(nil) -- opportunistic retry; peripheral event handles the common case
    end

    tryOpenSecnet() -- opportunistic retry; peripheral event handles the common case (see tryOpenSecnet)

    local ok, err = broadcastTelemetry()
    if not ok then
        logLine("telemetry broadcast failed: " .. tostring(err))
    end

    -- Single point of control for the per-tick screen refresh: this
    -- function runs on every poll (1Hz) plus once immediately at boot (see
    -- main()), so putting safeDraw() here covers the continuously-changing
    -- telemetry values (damage/temp/coolant/waste/burn/age) without needing
    -- a separate redraw timer, the same way supervisor.lua's uiTimerId
    -- drives its own periodic safeRedraw().
    safeDraw()
end

-- ===========================================================================
-- COMMAND handling
-- ===========================================================================
-- Inbound COMMAND payload contract (established here - nodes/supervisor.lua
-- and test/cmd_test.lua both must match this):
--   { action = "SET_BURN_RATE" | "SCRAM" | "APPLY_TAG" | "REMOVE_TAG" |
--              "OPEN_STEAM_BYPASS" | "CLOSE_STEAM_BYPASS" |
--              "ENTER_TESTING" | "EXIT_TESTING",
--     value         = <number, mB/t, required for SET_BURN_RATE>,
--     supervisorKey = <string, required for SET_BURN_RATE/APPLY_TAG/
--                      REMOVE_TAG/ENTER_TESTING/EXIT_TESTING - checked
--                      against lib/rbac.lua's Shift Supervisor key, a
--                      SEPARATE secret from the network HMAC secret>,
--     reason        = <string, required non-empty for APPLY_TAG>,
--     requestId     = <optional, echoed back verbatim> }
-- Outbound ACK (sent back to the commander, tagged PROTOCOL_SUPERVISOR):
--   { action = <echoed>, accepted = true|false,
--     reason = <only when accepted==false>: "invalid-value" |
--       "no-reactor-hardware" | "reactor-scrammed" | "actuation-failed" |
--       "unauthorized-role" | "equipment-tagged-out" | "rbac-unavailable" |
--       "unknown-action" | "malformed-command",
--     requestId = <echoed> }
-- LOTO / Operating Modes: see file header for full philosophy. SCRAM and
-- the steam bypass toggle are ungated (Operator-tier); SET_BURN_RATE/
-- APPLY_TAG/REMOVE_TAG/ENTER_TESTING/EXIT_TESTING all require the Shift
-- Supervisor key.
-- Future extension point: a "RESET"/"CLEAR_SCRAM" action to un-latch a
-- trip is intentionally NOT implemented in this draft (see file header).
local function sendAck(fromId, action, accepted, reason, requestId)
    secnet.send(fromId, NET.PROTOCOL_SUPERVISOR, MSG.ACK, {
        action    = action,
        accepted  = accepted,
        reason    = reason,
        requestId = requestId,
    })
end

-- Shared gate for the five Shift-Supervisor-key-gated actions
-- (SET_BURN_RATE, APPLY_TAG, REMOVE_TAG, ENTER_TESTING, EXIT_TESTING). On
-- false it has already sent the rejecting ACK itself - callers just return.
local function checkSupervisorGate(fromId, action, payload, requestId)
    if not rbac then
        sendAck(fromId, action, false, "rbac-unavailable", requestId)
        return false
    end
    if not rbac.checkSupervisorKey(payload.supervisorKey) then
        sendAck(fromId, action, false, "unauthorized-role", requestId)
        return false
    end
    return true
end

local function handleCommand(fromId, payload)
    if type(payload) ~= "table" or type(payload.action) ~= "string" then
        sendAck(fromId, nil, false, "malformed-command", type(payload) == "table" and payload.requestId or nil)
        return
    end

    local action, requestId = payload.action, payload.requestId

    if action == "SCRAM" then
        doScram(("MANUAL SCRAM via COMMAND from #%d"):format(fromId))
        -- Idempotent: the requested end-state (tripped) is true whether
        -- this call caused it or an earlier trip already did.
        sendAck(fromId, action, true, nil, requestId)
        return
    end

    if action == "SET_BURN_RATE" then
        if type(payload.value) ~= "number" or payload.value < 0 then
            sendAck(fromId, action, false, "invalid-value", requestId)
            return
        end
        if not checkSupervisorGate(fromId, action, payload, requestId) then
            return
        end
        if lotoTag then
            -- Reactivity cannot be commanded on tagged-out equipment, even
            -- by a Shift Supervisor re-supplying the key - the tag must be
            -- explicitly removed first (see file header).
            sendAck(fromId, action, false, "equipment-tagged-out", requestId)
            return
        end
        if reactorState.plantState == STATES.SCRAMMED then
            -- Burn rate cannot be commanded out of a latched trip.
            sendAck(fromId, action, false, "reactor-scrammed", requestId)
            return
        end
        if not reactor then
            sendAck(fromId, action, false, "no-reactor-hardware", requestId)
            return
        end

        local ok, err = pcall(reactor.setBurnRate, payload.value)
        if not ok then
            unbindReactor("actuation failure: " .. tostring(err))
            sendAck(fromId, action, false, "actuation-failed", requestId)
            return
        end

        sendAck(fromId, action, true, nil, requestId)
        return
    end

    if action == "APPLY_TAG" then
        if type(payload.reason) ~= "string" or payload.reason == "" then
            sendAck(fromId, action, false, "invalid-value", requestId)
            return
        end
        if not checkSupervisorGate(fromId, action, payload, requestId) then
            return
        end

        -- Single-tag-slot model (v1 simplification - see file header):
        -- re-applying while already tagged overwrites reason/timestamp/
        -- appliedBy, it does not stack.
        lotoTag = { reason = payload.reason, appliedAt = os.epoch("utc"), appliedBy = fromId }
        logLine(("LOTO TAG APPLIED by #%d: %s"):format(fromId, payload.reason))
        broadcastTelemetry() -- immediate out-of-cycle update, same pattern as unbindReactor()
        safeDraw()

        sendAck(fromId, action, true, nil, requestId)
        return
    end

    if action == "REMOVE_TAG" then
        if not checkSupervisorGate(fromId, action, payload, requestId) then
            return
        end

        -- Idempotent-success on an already-untagged reactor - mirrors
        -- doScram()'s idempotent-latch philosophy: the requested end-state
        -- (untagged) is already true.
        lotoTag = nil
        logLine(("LOTO TAG REMOVED by #%d"):format(fromId))
        broadcastTelemetry()
        safeDraw()

        sendAck(fromId, action, true, nil, requestId)
        return
    end

    if action == "OPEN_STEAM_BYPASS" then
        -- Operator-tier "non-critical valve" - no RBAC gate, no interlocks
        -- (deliberately simple: this is a simulated valve, see header).
        steamBypassOpen = true
        logLine(("Steam bypass OPENED via COMMAND from #%d"):format(fromId))
        broadcastTelemetry()
        safeDraw()
        sendAck(fromId, action, true, nil, requestId)
        return
    end

    if action == "CLOSE_STEAM_BYPASS" then
        steamBypassOpen = false
        logLine(("Steam bypass CLOSED via COMMAND from #%d"):format(fromId))
        broadcastTelemetry()
        safeDraw()
        sendAck(fromId, action, true, nil, requestId)
        return
    end

    if action == "ENTER_TESTING" then
        if not checkSupervisorGate(fromId, action, payload, requestId) then
            return
        end
        testingMode = true
        logLine(("TESTING MODE ENTERED by #%d"):format(fromId))
        broadcastTelemetry()
        safeDraw()
        sendAck(fromId, action, true, nil, requestId)
        return
    end

    if action == "EXIT_TESTING" then
        if not checkSupervisorGate(fromId, action, payload, requestId) then
            return
        end
        testingMode = false
        logLine(("TESTING MODE EXITED by #%d"):format(fromId))
        broadcastTelemetry()
        safeDraw()
        sendAck(fromId, action, true, nil, requestId)
        return
    end

    sendAck(fromId, action, false, "unknown-action", requestId)
end

-- ===========================================================================
-- Main event loop - strictly non-blocking: a single os.pullEvent() wait
-- per iteration, three os.startTimer()-driven cadences, never sleep(),
-- never an un-yielded while true.
-- ===========================================================================
local function main()
    -- One-time boot splash, before the main loop (and its "never block past
    -- one os.pullEvent()" rule) starts - see file header. Purely cosmetic:
    -- os_shell.drawBootSplash() itself never blocks, the fixed os.sleep()
    -- here is what holds it on screen briefly.
    os_shell.drawBootSplash({
        title    = "FCS-10",
        subtitle = "Core Programmable Logic Controller",
        role     = "PLC",
        accent   = colors.red,
    })
    os.sleep(1.2)

    -- Logged (not printed) before anything else runs, so it's already the
    -- oldest entry in the log panel by the time the first draw() happens -
    -- tryBindReactor()/tryOpenSecnet() below may each trigger their own
    -- safeDraw() immediately if they succeed on the first try.
    logLine("FCS-10 Core PLC booting on computer #" .. os.getComputerID())

    tryBindReactor(nil)
    if not reactor then
        reactorState.plantState = STATES.ANOMALY
        logLine("WARNING: no " .. REACTOR_TYPE .. " found at startup - LPS running in hardware-absent mode")
    end

    local okOpen, openErr = tryOpenSecnet()
    if not okOpen then
        logLine("WARNING: secnet.open failed (" .. tostring(openErr) .. ") - will keep retrying as peripherals attach")
    end

    pollAndEvaluate() -- immediate first pass, don't wait a full cadence before the first LPS check

    -- No os.cancelTimer exists in CC:Tweaked - the standard idiom is to
    -- reassign the tracked "current" timer id to a freshly-started timer;
    -- a stale timer's eventual fire compares unequal to the (already
    -- reassigned) id and is simply ignored below.
    local pollTimerId    = os.startTimer(NET.TELEMETRY_INTERVAL_S)
    local hbSendTimerId  = os.startTimer(NET.HEARTBEAT_INTERVAL_S)
    -- Armed immediately, even before any Supervisor has ever been seen, so
    -- a PLC that boots before the Supervisor exists still fails safe.
    local watchdogTimerId = os.startTimer(NET.HEARTBEAT_TIMEOUT_S)

    while true do
        local event, p1, p2, p3 = os.pullEvent() -- yields every iteration; never a busy-spin

        -- Outer per-iteration pcall: the highest-value single line of
        -- defense in this file. Nothing above should throw, but an
        -- unanticipated bug here (e.g. a malformed payload's nil-index)
        -- must never be allowed to kill the main loop of a reactor
        -- controller.
        local ok, err = pcall(function()
            if event == "timer" then
                if p1 == pollTimerId then
                    pollAndEvaluate()
                    pollTimerId = os.startTimer(NET.TELEMETRY_INTERVAL_S)
                elseif p1 == hbSendTimerId then
                    secnet.broadcast(NET.PROTOCOL_SUPERVISOR, MSG.HEARTBEAT, {})
                    hbSendTimerId = os.startTimer(NET.HEARTBEAT_INTERVAL_S)
                elseif p1 == watchdogTimerId then
                    doScram("FAIL-SAFE: no Supervisor heartbeat within " .. NET.HEARTBEAT_TIMEOUT_S .. "s")
                    watchdogTimerId = os.startTimer(NET.HEARTBEAT_TIMEOUT_S)
                end
            elseif event == "rednet_message" then
                local fromId, msgType, payload = secnet.handleEvent(p1, p2)
                if fromId then
                    if msgType == MSG.HEARTBEAT then
                        watchdogTimerId = os.startTimer(NET.HEARTBEAT_TIMEOUT_S)
                    elseif msgType == MSG.COMMAND then
                        handleCommand(fromId, payload)
                    end
                end
                -- rejections (nil, reason) from secnet.handleEvent are not
                -- errors - ignore and keep the loop running.
            elseif event == "peripheral" then
                tryBindReactor(p1)
                tryOpenSecnet() -- a modem attaching this tick is exactly what "peripheral" fires for
            elseif event == "peripheral_detach" then
                if p1 == reactorSide then
                    unbindReactor("peripheral_detach on side " .. tostring(p1))
                end
            elseif event == "mouse_click" and p1 == 1 then
                -- Navigation-only - see "VISUAL DASHBOARD / DESKTOP SHELL"
                -- header comment. No branch here ever calls a reactor
                -- action function.
                local x, y = p2, p3
                if currentScreen == "desktop" then
                    local key = os_shell.hitTestIcons(lastDesktopIcons, x, y)
                    if key == "update" then
                        launchUpdater()
                    elseif key == "scada" or key == "settings" or key == "network" then
                        currentScreen = key
                        safeDraw()
                    end
                elseif currentScreen == "settings" and os_shell.isPointIn(themeButtonRegion, x, y) then
                    os_shell.cycleTheme()
                    safeDraw()
                elseif homeHitRegion and os_shell.isHomeClick(x, y) then
                    currentScreen = "desktop"
                    safeDraw()
                end
            end
        end)

        if not ok then
            logLine("event handler error (non-fatal, loop continues): " .. tostring(err))
            safeDraw()
        end
    end
end

main()
