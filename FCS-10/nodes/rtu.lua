-- nodes/rtu.lua
-- FCS-10 / ATM-PCS :: Zone RTU (Remote Terminal Unit)
--
-- An independent, MONITOR-ONLY node bound directly to a reactor's
-- fissionReactorLogicAdapter, same as nodes/plc.lua. Unlike the PLC, this
-- node has no actuation capability and no trip/LPS authority - it never
-- calls setBurnRate/scram, never evaluates a setpoint, and never SCRAMs.
-- It exists purely to widen instrumentation coverage (a second/redundant
-- telemetry channel, or a physically separate monitoring point) without
-- being anywhere on the reactor's protection-system critical path. Trip
-- authority stays exclusively with nodes/plc.lua.
--
-- PROTOCOL ADDRESSING (same convention plc.lua/supervisor.lua establish):
-- this node HOSTS on PROTOCOL_RTU (previously reserved in config.lua but
-- unused by any node until this file). Everything it SENDS (TELEMETRY, its
-- own outbound HEARTBEAT) is tagged PROTOCOL_SUPERVISOR - the audience's
-- protocol, not this node's own.
--
-- plantState / activeEAL SEMANTICS: unlike plc.lua, this node's plantState
-- reflects hardware/comms PRESENCE only, never a threshold-evaluated safety
-- judgement - NORMAL while the peripheral is bound and a read just
-- succeeded, ANOMALY while unbound. It never reports SCRAMMED (this node
-- never actuates anything, so claiming that state would be a lie) and never
-- latches (flips straight back to NORMAL the instant a read next succeeds -
-- there is nothing here worth remembering across a transient blip).
-- activeEAL is always left nil: nodes/supervisor.lua's onTelemetry/onScram
-- unconditionally recompute rec.activeEAL from the raw metrics on every
-- packet regardless of sender, so anything placed here would just be
-- discarded. That EAL computation is itself sender-agnostic, so a real
-- high-damage/low-coolant/high-waste reading reported by this node still
-- correctly surfaces a Supervisor-side EAL badge with no setpoint logic
-- needed in this file at all.
--
-- fuelPct: config.newDefaultReactorState() has no fuel-level field, so this
-- node bolts one on after construction. The current supervisor.lua UI does
-- not render it - it's on the wire for a future consumer / manual
-- inspection, not currently displayed.
--
-- KNOWN v1 LIMITATION: nodes/supervisor.lua's plcs table keys generically
-- off any authenticated TELEMETRY sender's computer ID with no role tag, so
-- this node's telemetry will merge into the same table/UI rows as a real,
-- protected PLC with no visual distinction between "protected by an LPS"
-- and "monitor-only, no protection." Not fixed here - out of this file's
-- scope, matching this project's existing habit of documenting cross-file
-- limitations rather than silently patching a file outside the current
-- task (see plc.lua's COMMAND-from-any-sender note, supervisor.lua's EAL
-- mapping notes).
--
-- WHY NO WATCHDOG / NO COMMAND HANDLING: plc.lua arms a heartbeat watchdog
-- that fail-safe SCRAMs because it is the Local Protection System and must
-- have something to fail INTO. This node has no actuator, so there is
-- nothing for a missed heartbeat to trigger, and pretending otherwise by
-- accepting-and-discarding a COMMAND with a fake ACK would be actively
-- misleading. This node sends no ACK for anything. It does still run every
-- inbound rednet_message through secnet.handleEvent (see main()) so
-- authenticated/replay-checked handling stays consistent across every node
-- in the fleet, even though it takes no action on the result.

local REACTOR_TYPE = "fissionReactorLogicAdapter"

-- ---------------------------------------------------------------------------
-- Safe library load - a failure here has no meaningful degraded mode, so
-- it's a logged, controlled exit (matches plc.lua/supervisor.lua/hmi.lua).
-- ---------------------------------------------------------------------------
local okCfg, config = pcall(dofile, "/lib/config.lua")
if not okCfg then
    print("[RTU] FATAL: failed to load /lib/config.lua: " .. tostring(config))
    return
end

local okSn, secnet = pcall(dofile, "/lib/secnet.lua")
if not okSn then
    print("[RTU] FATAL: failed to load /lib/secnet.lua: " .. tostring(secnet))
    return
end

local okShell, os_shell = pcall(dofile, "/lib/os_shell.lua")
if not okShell then
    print("[RTU] FATAL: failed to load /lib/os_shell.lua: " .. tostring(os_shell))
    return
end

local NET    = config.NETWORK
local MSG    = config.NETWORK.MSG_TYPE
local STATES = config.STATES
-- No `local SP = config.SETPOINTS` - this node never evaluates a setpoint,
-- so it deliberately does not even import that table.

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------
local reactor           = nil    -- wrapped peripheral handle, or nil if unbound
local reactorSide        = nil    -- side/name reactor was wrapped from, for detach matching
local peripheralPresent  = false  -- true only while `reactor` is a live, working handle
local rtuState           = config.newDefaultReactorState() -- reused SSOT shape, mutated in place
rtuState.fuelPct = 0 -- RTU-specific extension field, not part of the SSOT shape (see header)

local secnetOpen = false -- true once secnet.open() has ever succeeded (see tryOpenSecnet)

-- currentScreen drives ONLY which draw function runs and where mouse_click
-- is routed - see "VISUAL DASHBOARD / DESKTOP SHELL" below. It has zero
-- effect on the poll/broadcast logic above.
local currentScreen    = "desktop" -- "desktop" | "scada" | "settings" | "network"
local lastDesktopIcons = {}        -- laid-out icon hit-regions from the last drawDesktopScreen()

-- ===========================================================================
-- VISUAL DASHBOARD / DESKTOP SHELL - a continuously-redrawn, screen-based UI
-- built on lib/os_shell.lua's shared boot-splash/desktop/chrome helpers,
-- same move nodes/hmi.lua/supervisor.lua/nodes/plc.lua already made away
-- from a plain print() scroll. Every print() call site below this point is
-- replaced with logLine() instead - print() writes at the shell cursor and
-- scrolls the terminal on overflow, which would tear up this drawn screen
-- exactly the way nodes/hmi.lua's own STATUS CONSOLE comment already
-- documents for that file. The two print()s ABOVE this point (config/secnet/
-- os_shell FATAL) are deliberately left as raw prints: they happen during
-- the plain boot scroll before the first draw() below wipes the screen
-- clean.
--
-- INTERACTIVE, but navigation-only, same as nodes/plc.lua: clicking desktop
-- icons or the HOME button only changes currentScreen. This node has no
-- actuator and no command handling (see header "WHY NO WATCHDOG / NO
-- COMMAND HANDLING") - there is still nothing for an on-screen control to
-- do beyond navigation and the UPDATE icon's installer.lua shell-out.
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

-- Only NORMAL/ANOMALY are possible here (see header "plantState / activeEAL
-- SEMANTICS") - this node never SCRAMs, so there is no red state to color.
local STATE_COLOR = {
    [STATES.NORMAL]  = colors.green,
    [STATES.ANOMALY] = colors.orange,
}

local homeHitRegion = nil -- HOME button hit-region from the last sub-screen chrome draw

local function drawScadaScreen()
    local w, h = term.getSize()
    local theme = os_shell.THEME

    term.setBackgroundColor(theme.bg)
    term.setTextColor(theme.text)
    term.clear()

    homeHitRegion = os_shell.drawScreenHeader(("SCADA - RTU #%d"):format(os.getComputerID()))

    -- Background/black text on the status bar are semantic (a NORMAL/
    -- ANOMALY status color), not theme colors - fixed across both palettes.
    term.setCursorPos(1, 2)
    term.setBackgroundColor(STATE_COLOR[rtuState.plantState] or colors.gray)
    term.setTextColor(colors.black)
    local stateLine = (" STATE: %s   (monitor-only, no trip authority) "):format(rtuState.plantState)
    term.write(stateLine .. string.rep(" ", math.max(0, w - #stateLine)))
    term.setBackgroundColor(theme.bg)
    term.setTextColor(theme.text)

    -- dataColor: "fresh" reads as the theme's normal text color, "stale"
    -- stays semantically orange regardless of theme.
    local dataColor = rtuState.online and theme.text or colors.orange
    term.setTextColor(dataColor)

    term.setCursorPos(1, 4)
    term.write(("DMG  %5.1f%%   T-K  %5.0f   CLT %5.1f%%  WST %5.1f%%"):format(
        rtuState.damagePct, rtuState.coreTempK, rtuState.coolantPct, rtuState.wastePct))

    term.setCursorPos(1, 5)
    term.write(("BURN %5.1f mB/t   FUEL %5.1f%%"):format(rtuState.burnRateMbT, rtuState.fuelPct))

    local ageText = rtuState.lastUpdate > 0
        and fmtAge(os.epoch("utc") - rtuState.lastUpdate) or "--"
    term.setCursorPos(1, 6)
    term.write(("HW: %-7s        AGE: %s"):format(
        peripheralPresent and "PRESENT" or "ABSENT", ageText))
    term.setTextColor(theme.text)

    term.setCursorPos(1, 8)
    term.setTextColor(theme.dim)
    term.write("LOG:")
    term.setTextColor(theme.text)
    for i, line in ipairs(uiLog) do
        local row = 8 + i
        if row > h then
            break
        end
        term.setCursorPos(1, row)
        local text = line
        if #text > w then
            text = text:sub(1, w)
        end
        term.write(text)
    end
end

-- Desktop icons - "SCADA" is this node's core telemetry screen (the
-- function above); SETTINGS/NETWORK are read-only info screens; UPDATE
-- isn't a screen at all, see launchUpdater() below.
local DESKTOP_ICONS = {
    { key = "scada",    label = "SCADA",    color = colors.orange },
    { key = "settings", label = "SETTINGS", color = colors.gray },
    { key = "network",  label = "NETWORK",  color = colors.cyan },
    { key = "update",   label = "UPDATE",   color = colors.blue },
}

local function drawDesktopScreen()
    lastDesktopIcons = os_shell.drawDesktop({
        title       = ("FCS-10 RTU #%d"):format(os.getComputerID()),
        statusRight = ("STATE: %s"):format(rtuState.plantState),
        statusColor = STATE_COLOR[rtuState.plantState] or os_shell.THEME.text,
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
        { label = "Role",        value = "RTU (monitor-only)" },
        { label = "Computer ID", value = os.getComputerID() },
        { label = "Reactor HW",  value = peripheralPresent and "PRESENT" or "ABSENT",
          color = peripheralPresent and colors.green or colors.red },
        { label = "Plant state", value = rtuState.plantState,
          color = STATE_COLOR[rtuState.plantState] or theme.text },
        { label = "Trip authority", value = "NONE - see nodes/plc.lua" },
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
    local ageText = rtuState.lastUpdate > 0
        and fmtAge(os.epoch("utc") - rtuState.lastUpdate) or "--"
    os_shell.drawKeyValueList({
        { label = "secnet",           value = secnetOpen and "OPEN" or "NOT OPEN",
          color = secnetOpen and colors.green or colors.red },
        { label = "Hosts on",         value = NET.PROTOCOL_RTU },
        { label = "Sends to",         value = NET.PROTOCOL_SUPERVISOR },
        { label = "Last reading age", value = ageText },
        { label = "Heartbeat every",  value = NET.HEARTBEAT_INTERVAL_S .. "s" },
    }, 3)
    local _, h = term.getSize()
    os_shell.drawScreenFrame(1, h)
end

-- Single dispatch point every draw call site below goes through - which
-- screen function actually runs depends only on currentScreen, a purely
-- local display choice with no effect on the poll/broadcast logic above.
local function draw()
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

-- Dedicated pcall boundary, same reasoning as supervisor.lua's safeRedraw()/
-- plc.lua's safeDraw(): drawing must never be allowed to kill this node's
-- main loop.
local function safeDraw()
    local ok, err = pcall(draw)
    if not ok then
        print("[RTU] draw failed (non-fatal): " .. tostring(err))
    end
end

-- Shells out to the existing installer.lua (see nodes/plc.lua's
-- launchUpdater() for the full reasoning - identical here, just targeting
-- role "rtu"). This node has no trip authority to pause, unlike the PLC,
-- but its telemetry polling does pause for the duration - logged clearly
-- before launching for the same honesty reasons.
local function launchUpdater()
    logLine("UPDATE: opening installer - telemetry polling pauses until it returns")
    safeDraw()
    pcall(function()
        shell.run("/installer.lua", "update", "rtu")
        os.sleep(2) -- brief, bounded pause so the printed result is readable, never indefinite
    end)
    logLine("UPDATE: installer closed, resuming normal operation")
    safeDraw()
end

-- secnet.open()'s only failure mode is "no modem found this call" (see
-- lib/secnet.lua) - often just a boot-order race, since a modem peripheral
-- can attach a tick or two after the computer itself starts running. Same
-- retry pattern as nodes/plc.lua/nodes/supervisor.lua/nodes/hmi.lua's
-- tryOpenSecnet: retried opportunistically every poll tick and on every
-- "peripheral" attach event, so a transient miss at boot doesn't leave this
-- node's telemetry permanently unreachable.
local function tryOpenSecnet()
    if secnetOpen then
        return true
    end
    local ok, err = secnet.open(nil, NET.PROTOCOL_RTU)
    if ok then
        secnetOpen = true
        logLine("secnet opened")
        safeDraw()
    end
    return ok, err
end

-- ===========================================================================
-- Peripheral loss / reacquisition
-- ===========================================================================
-- Idempotent (only acts on the present -> absent edge). Unlike plc.lua's
-- unbindReactor, there is no SCRAM latch to preserve here - plantState just
-- becomes ANOMALY, full stop.
local function unbindReactor(reason)
    if not peripheralPresent then
        return -- already unbound (or never bound) - nothing to transition
    end

    reactor, reactorSide, peripheralPresent = nil, nil, false
    rtuState.online     = false -- other metrics deliberately left as-is (last known values)
    rtuState.plantState = STATES.ANOMALY

    logLine("reactor peripheral lost: " .. tostring(reason))
    safeDraw()

    -- Immediate out-of-cycle broadcast, same reasoning as plc.lua: the
    -- Supervisor should learn about hardware loss as fast as possible
    -- rather than waiting for the next scheduled tick.
    secnet.broadcast(NET.PROTOCOL_SUPERVISOR, MSG.TELEMETRY, {
        state             = rtuState,
        peripheralPresent = peripheralPresent,
        rtuId             = os.getComputerID(),
        role              = "RTU",
    })
end

-- Attempts to (re)bind the reactor peripheral. Identical logic to plc.lua's
-- tryBindReactor: `sideHint` comes from a "peripheral" attach event
-- (validated against REACTOR_TYPE, since that event fires for ANY
-- peripheral attaching on ANY side); pass nil to do a fresh peripheral.find()
-- sweep instead (used at boot and as an opportunistic per-tick retry).
-- No-ops if already bound - never clobbers a working handle.
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
        rtuState.online = true
        logLine("reactor bound on side " .. side)
        safeDraw()
    end
end

-- ===========================================================================
-- Poll + telemetry publish (one timer tick) - no evaluation step, hence no
-- "Evaluate" in the name (contrast plc.lua's pollAndEvaluate).
-- ===========================================================================
local function pollAndPublish()
    if reactor then
        local ok1, damage  = pcall(reactor.getDamagePercent)
        local ok2, temp    = pcall(reactor.getTemperature)
        local ok3, burn    = pcall(reactor.getBurnRate)
        local ok4, coolant = pcall(reactor.getCoolant)
        local ok5, waste   = pcall(reactor.getWaste)
        local ok6, fuel    = pcall(reactor.getFuel)

        if not (ok1 and ok2 and ok3 and ok4 and ok5 and ok6) then
            unbindReactor("metrics read failed")
        else
            rtuState.damagePct   = damage
            rtuState.coreTempK   = temp
            rtuState.burnRateMbT = burn

            -- getCoolant()/getWaste()/getFuel() return raw {amount, capacity}
            -- tank tables, not a percentage - compute it here, guarding
            -- against a transient capacity==0 rather than dividing by zero.
            if type(coolant) == "table" and type(coolant.capacity) == "number" and coolant.capacity > 0 then
                rtuState.coolantPct = coolant.amount / coolant.capacity * 100
            end
            if type(waste) == "table" and type(waste.capacity) == "number" and waste.capacity > 0 then
                rtuState.wastePct = waste.amount / waste.capacity * 100
            end
            if type(fuel) == "table" and type(fuel.capacity) == "number" and fuel.capacity > 0 then
                rtuState.fuelPct = fuel.amount / fuel.capacity * 100
            end

            rtuState.online     = true
            rtuState.plantState = STATES.NORMAL -- hardware-presence flag only; never latched (see header)
            rtuState.lastUpdate = os.epoch("utc")
            rtuState.seq        = rtuState.seq + 1
        end
    else
        tryBindReactor(nil) -- opportunistic retry; "peripheral" event handles the common case
    end

    tryOpenSecnet() -- opportunistic retry; "peripheral" event handles the common case

    local ok, err = secnet.broadcast(NET.PROTOCOL_SUPERVISOR, MSG.TELEMETRY, {
        state             = rtuState,
        peripheralPresent = peripheralPresent,
        rtuId             = os.getComputerID(),
        role              = "RTU",
    })
    if not ok then
        logLine("telemetry broadcast failed: " .. tostring(err))
    end

    -- Single point of control for the per-tick screen refresh - this
    -- function runs on every poll (1Hz) plus once immediately at boot (see
    -- main()), same reasoning as nodes/plc.lua's pollAndEvaluate.
    safeDraw()
end

-- ===========================================================================
-- Main event loop - strictly non-blocking: a single os.pullEvent() wait per
-- iteration, two os.startTimer()-driven cadences (no watchdog - see header),
-- never sleep(), never an un-yielded while true.
-- ===========================================================================
local function main()
    -- One-time boot splash, before the main loop starts - see nodes/plc.lua
    -- for the identical reasoning. Purely cosmetic and non-blocking on its
    -- own; the fixed os.sleep() is what holds it on screen briefly.
    os_shell.drawBootSplash({
        title    = "FCS-10",
        subtitle = "Zone RTU (monitor-only)",
        role     = "RTU",
        accent   = colors.orange,
    })
    os.sleep(1.2)

    -- Logged (not printed) before anything else runs, so it's already the
    -- oldest entry in the log panel by the time the first draw() happens.
    logLine("FCS-10 Zone RTU booting on computer #" .. os.getComputerID())

    tryBindReactor(nil)
    if not reactor then
        rtuState.plantState = STATES.ANOMALY
        logLine("WARNING: no " .. REACTOR_TYPE .. " found at startup - running in hardware-absent mode")
    end

    local okOpen, openErr = tryOpenSecnet()
    if not okOpen then
        logLine("WARNING: secnet.open failed (" .. tostring(openErr) .. ") - will keep retrying as peripherals attach")
    end

    pollAndPublish() -- immediate first pass, don't wait a full cadence

    -- No os.cancelTimer exists in CC:Tweaked - reassigning the tracked
    -- "current" timer id is the standard idiom; a stale timer's eventual
    -- fire compares unequal to the (already reassigned) id and is ignored.
    local pollTimerId   = os.startTimer(NET.TELEMETRY_INTERVAL_S)
    local hbSendTimerId = os.startTimer(NET.HEARTBEAT_INTERVAL_S)
    -- Deliberately no third watchdog timer: unlike plc.lua, this node has
    -- no actuator, so there is nothing for a missed Supervisor heartbeat to
    -- trigger it into (see header).

    while true do
        local event, p1, p2, p3 = os.pullEvent() -- yields every iteration; never a busy-spin

        -- Outer per-iteration pcall: same last line of defense plc.lua and
        -- supervisor.lua use - an unanticipated bug here must never kill
        -- this node's main loop.
        local ok, err = pcall(function()
            if event == "timer" then
                if p1 == pollTimerId then
                    pollAndPublish()
                    pollTimerId = os.startTimer(NET.TELEMETRY_INTERVAL_S)
                elseif p1 == hbSendTimerId then
                    secnet.broadcast(NET.PROTOCOL_SUPERVISOR, MSG.HEARTBEAT, {})
                    hbSendTimerId = os.startTimer(NET.HEARTBEAT_INTERVAL_S)
                end
            elseif event == "rednet_message" then
                -- Verified/replay-checked via the same authenticated path
                -- every other node uses, even though this node takes no
                -- action on any msgType it might see here - it will also
                -- observe Supervisor -> PLC traffic like HEARTBEAT/COMMAND,
                -- since rednet protocol tags are not a delivery filter and
                -- this is one shared-secret network (see header).
                secnet.handleEvent(p1, p2)
            elseif event == "peripheral" then
                tryBindReactor(p1)
                tryOpenSecnet() -- a modem attaching this tick is exactly what "peripheral" fires for
            elseif event == "peripheral_detach" then
                if p1 == reactorSide then
                    unbindReactor("peripheral_detach on side " .. tostring(p1))
                end
            elseif event == "mouse_click" and p1 == 1 then
                -- Navigation-only, same as nodes/plc.lua - no branch here
                -- ever issues a reactor action (this node has none to issue).
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
