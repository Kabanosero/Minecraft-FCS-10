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
-- WHY NO WATCHDOG / NO COMMAND HANDLING (reactor-related): plc.lua arms a
-- heartbeat watchdog that fail-safe SCRAMs because it is the Local
-- Protection System and must have something to fail INTO. This node has no
-- reactor actuator, so there is nothing for a missed heartbeat to trigger,
-- and pretending otherwise by accepting-and-discarding a reactor-related
-- COMMAND with a fake ACK would be actively misleading. It does still run
-- every inbound rednet_message through secnet.handleEvent (see main()) so
-- authenticated/replay-checked handling stays consistent across every node
-- in the fleet.
--
-- AUXILIARY PERIPHERAL COMMAND HANDLING (narrow, deliberate exception to
-- the above): this node also detects/monitors a set of non-reactor
-- Mekanism machines (turbine, Solar Neutron Activator, Isotopic Centrifuge,
-- Chemical Dissolution Chamber, Pressurized Reaction Chamber, Induction
-- Matrix, SPS, Dynamic Tank, Advanced Peripherals' Environment Detector)
-- plus CC:Tweaked speakers - see "AUXILIARY MEKANISM/AP PERIPHERALS" below.
-- Verified against Mekanism's own generated computer-method reference
-- (mekanism.github.io/computer_data) rather than assumed: exactly two of
-- those have any actuator surface at all - a turbine's dumping-mode cycle,
-- and a speaker's alarm playback. Every other machine listed is monitor-
-- only because Mekanism's own API has no start/stop/setpoint method for it,
-- full stop, regardless of how this node is built. So this node DOES now
-- accept and ACK a narrow two-action COMMAND set (see handleCommand()) -
-- the "sends no ACK for anything" framing above no longer holds
-- universally, just for reactor-related commands (there are none to
-- accept, and still never will be - see plc.lua for that authority).
-- Neither new action touches reactor trip/burn-rate authority in any way.
-- Both are left ungated by the Shift-Supervisor-key RBAC check plc.lua
-- uses for SET_BURN_RATE/tag actions (this node does not load lib/rbac.lua
-- at all), matching plc.lua's own precedent that SCRAM/steam-bypass are
-- "Operator-tier" (ungated) because they're protective/non-reactivity
-- actions - dumping-mode cycling and alarm playback fit that same bucket,
-- not the reactivity-changing bucket SET_BURN_RATE/tag actions are gated
-- for.
--
-- PERIPHERAL CLASSIFICATION: classified by which methods peripheral.
-- getMethods(name) actually reports (a "fingerprint" subset unique to each
-- machine), NOT by peripheral.getType() string. No Mekanism/addon
-- peripheral type-name string was ever confirmed against a live game for
-- this project - only the method lists were (from Mekanism's own docs).
-- Guessing a type-name string on top of that would repeat the exact
-- mistake already made once in this project (the CP437 box-drawing
-- character assumption in lib/os_shell.lua - asserting an unverified
-- engine fact as if confirmed). Fingerprint matching is naming/version-
-- resistant and fails safe: an unrecognized peripheral is logged with its
-- raw getType()/method count, never guessed at or miscontrolled.

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
-- Auxiliary (non-reactor) peripheral telemetry - see "AUXILIARY MEKANISM/AP
-- PERIPHERALS" section below. Rides inside rtuState so it's automatically
-- included in the existing `state = rtuState` TELEMETRY broadcast with no
-- separate payload field needed. Every other node's existing code only
-- reads the specific fields it already knows about, so this addition is
-- harmless to plc.lua/supervisor.lua/hmi.lua.
rtuState.aux = {
    turbines               = {}, -- [peripheralName] = { ...TURBINE fields... }
    snas                   = {}, -- [peripheralName] = { ...SNA fields... }
    centrifuges            = {}, -- [peripheralName] = { ...CENTRIFUGE fields... }
    chemDissolutionChambers = {}, -- [peripheralName] = { ...CHEM_DISSOLUTION fields... }
    prcs                   = {}, -- [peripheralName] = { ...PRC fields... }
    tanks                  = {}, -- [peripheralName] = { ...DYNAMIC_TANK fields... }
    envDetectors           = {}, -- [peripheralName] = { ...ENV_DETECTOR fields... }
    inductionMatrix        = nil, -- singleton: { ...INDUCTION_MATRIX fields... } | nil
    sps                    = nil, -- singleton: { ...SPS fields... } | nil
}

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

-- fmtPct: Mekanism/Advanced Peripherals' own docs are inconsistent about
-- whether a "*FilledPercentage" getter returns a 0-1 fraction or an
-- already-0-100 percentage. <=1 is treated as a fraction and scaled - a
-- deliberate, documented judgment call (not an assumption presented as
-- fact), trivially correctable once real in-game numbers are seen. Used
-- only for display in drawSystemsScreen(), never for any control decision.
local function fmtPct(v)
    if type(v) ~= "number" then
        return "--"
    end
    if v <= 1 then
        v = v * 100
    end
    return string.format("%.1f", v)
end

local function fmtNum(v)
    if type(v) ~= "number" then
        return "--"
    end
    return string.format("%.1f", v)
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

-- Auxiliary (non-reactor) peripheral overview screen - see "AUXILIARY
-- MEKANISM/AP PERIPHERALS" section below for how rtuState.aux gets
-- populated. One compact row per detected unit; rows are capped to what
-- fits the screen with a "+N more" footer, same pattern nodes/supervisor.
-- lua's own PLC table already uses, rather than building new scrolling
-- infrastructure into lib/os_shell.lua for this one screen.
local function drawSystemsScreen()
    local theme = os_shell.THEME
    term.setBackgroundColor(theme.bg)
    term.setTextColor(theme.text)
    term.clear()
    homeHitRegion = os_shell.drawScreenHeader("SYSTEMS")

    local _, h = term.getSize()
    local aux = rtuState.aux
    local rows = {}

    local function addRow(label, value)
        rows[#rows + 1] = { label = label, value = value }
    end

    for name, t in pairs(aux.turbines) do
        addRow("TURBINE " .. name, ("mode=%s flow=%s prod=%s"):format(
            tostring(t.dumpingMode), fmtNum(t.flowRate), fmtNum(t.prodRate)))
    end
    for name, t in pairs(aux.snas) do
        addRow("SNA " .. name, ("in=%s%% out=%s%% sun=%s"):format(
            fmtPct(t.inputPct), fmtPct(t.outputPct), tostring(t.canSeeSun)))
    end
    for name, t in pairs(aux.centrifuges) do
        addRow("CENTRIFUGE " .. name, ("in=%s%% out=%s%%"):format(fmtPct(t.inputPct), fmtPct(t.outputPct)))
    end
    for name, t in pairs(aux.chemDissolutionChambers) do
        addRow("CHEM DISSOL " .. name, ("gas=%s%% out=%s%%"):format(fmtPct(t.gasInputPct), fmtPct(t.outputPct)))
    end
    for name, t in pairs(aux.prcs) do
        addRow("PRC " .. name, ("fluid=%s%% gas=%s%%"):format(fmtPct(t.inputFluidPct), fmtPct(t.inputGasPct)))
    end
    for name, t in pairs(aux.tanks) do
        addRow("TANK " .. name, ("level=%s%%"):format(fmtPct(t.filledPct)))
    end
    for name, t in pairs(aux.envDetectors) do
        addRow("ENV " .. name, ("radiation=%s Sv/h"):format(fmtNum(t.radiationRaw)))
    end
    if aux.inductionMatrix then
        local m = aux.inductionMatrix
        addRow("IND MATRIX", ("in=%s out=%s cells=%s"):format(
            fmtNum(m.lastInput), fmtNum(m.lastOutput), tostring(m.installedCells)))
    end
    if aux.sps then
        local s = aux.sps
        addRow("SPS", ("in=%s%% out=%s%% rate=%s"):format(
            fmtPct(s.inputPct), fmtPct(s.outputPct), fmtNum(s.processRate)))
    end

    if #rows == 0 then
        addRow("No auxiliary peripherals detected", "")
    end

    local maxRows = math.max(0, h - 4) -- header row + blank + room for a footer line
    local shown, truncated = rows, false
    if #rows > maxRows then
        shown = {}
        for i = 1, maxRows do
            shown[i] = rows[i]
        end
        truncated = true
    end

    local nextRow = os_shell.drawKeyValueList(shown, 3)
    if truncated then
        term.setCursorPos(1, nextRow)
        term.setTextColor(theme.dim)
        term.write(("+%d more (see log)"):format(#rows - maxRows))
        term.setTextColor(theme.text)
    end

    os_shell.drawScreenFrame(1, h)
end

-- Desktop icons - "SCADA" is this node's core reactor telemetry screen;
-- "SYSTEMS" is the auxiliary Mekanism/AP peripheral overview above;
-- SETTINGS/NETWORK are read-only info screens; UPDATE isn't a screen at
-- all, see launchUpdater() below.
local DESKTOP_ICONS = {
    { key = "scada",    label = "SCADA",    color = colors.orange },
    { key = "systems",  label = "SYSTEMS",  color = colors.purple },
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
    elseif currentScreen == "systems" then
        drawSystemsScreen()
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
-- AUXILIARY MEKANISM/AP PERIPHERALS - detection, polling, one narrow
-- command surface. See file header "AUXILIARY PERIPHERAL COMMAND HANDLING"
-- and "PERIPHERAL CLASSIFICATION" for the full reasoning behind the
-- fingerprint-based (not getType()-string-based) detection approach.
-- ===========================================================================

-- Checked in priority order (most-specific fingerprint first) - a
-- peripheral is classified as the FIRST class in this list whose entire
-- fingerprint is a subset of its actual peripheral.getMethods() result.
-- Ordering matters: e.g. TURBINE and SPS both expose getCoils, so TURBINE
-- (which also has the unique getDumpingMode/getBlades pair) must be checked
-- before SPS, or a turbine could false-match as an SPS. CENTRIFUGE is the
-- last/fallback entry because its method set is close to a subset of
-- CHEM_DISSOLUTION's - anything with CHEM_DISSOLUTION's extra gas-input
-- methods will already have matched and returned by the time CENTRIFUGE is
-- checked.
local MEK_CLASSES = {
    { id = "DYNAMIC_TANK",      fingerprint = { "getContainerEditMode" },              singleton = false },
    { id = "TURBINE",           fingerprint = { "getDumpingMode", "getBlades" },       singleton = false },
    { id = "INDUCTION_MATRIX",  fingerprint = { "getInstalledCells", "getTransferCap" }, singleton = true },
    { id = "SPS",                fingerprint = { "getProcessRate", "getCoils" },        singleton = true },
    { id = "PRC",                fingerprint = { "getInputFluid", "getInputGas" },      singleton = false },
    { id = "CHEM_DISSOLUTION",  fingerprint = { "getGasInput", "getInputGasItem" },    singleton = false },
    { id = "SNA",                fingerprint = { "canSeeSun" },                         singleton = false },
    { id = "CENTRIFUGE",        fingerprint = { "getEnergyUsage", "getInputItem" },    singleton = false },
}

local MEK_CLASS_BY_ID = {
    -- SPEAKER/ENV_DETECTOR are classified by peripheral.getType() directly
    -- in classifyPeripheral() below, not via the fingerprint loop, so they
    -- never appear in MEK_CLASSES above - but registerUnit()/unregisterUnit()
    -- still need a singleton flag for every class id they might receive,
    -- SPEAKER/ENV_DETECTOR included, or indexing .singleton on a missing
    -- entry would crash. Both are multi-instance (singleton = false).
    SPEAKER      = { id = "SPEAKER",      singleton = false },
    ENV_DETECTOR = { id = "ENV_DETECTOR", singleton = false },
}
for _, def in ipairs(MEK_CLASSES) do
    MEK_CLASS_BY_ID[def.id] = def
end

-- Per-class getter -> rtuState.aux field name map, used by pollUnitFields()
-- below. Every getter call is individually pcall-guarded there (a missing/
-- renamed method on one machine must never crash the whole poll loop) -
-- a field simply stays nil if its getter errors or doesn't exist.
--
-- INDUCTION_MATRIX's energy/maxEnergy/energyPct entries are best-effort and
-- UNCONFIRMED against Mekanism's own docs (see plan notes) - included for
-- the "Total Power" reading the user asked for, but harmless no-ops via the
-- same pcall guard if those methods don't actually exist on this peripheral.
local FIELD_MAP = {
    TURBINE = {
        dumpingMode        = "getDumpingMode",
        flowRate           = "getFlowRate",
        maxFlowRate        = "getMaxFlowRate",
        prodRate           = "getProductionRate",
        maxProdRate        = "getMaxProduction",
        steamPct           = "getSteamFilledPercentage",
        lastSteamInputRate = "getLastSteamInputRate",
    },
    SNA = {
        inputPct     = "getInputFilledPercentage",
        outputPct    = "getOutputFilledPercentage",
        prodRate     = "getProductionRate",
        peakProdRate = "getPeakProductionRate",
        canSeeSun    = "canSeeSun",
    },
    CENTRIFUGE = {
        inputPct    = "getInputFilledPercentage",
        outputPct   = "getOutputFilledPercentage",
        energyUsage = "getEnergyUsage",
    },
    CHEM_DISSOLUTION = {
        gasInputPct = "getGasInputFilledPercentage",
        outputPct   = "getOutputFilledPercentage",
        energyUsage = "getEnergyUsage",
    },
    PRC = {
        inputFluidPct = "getInputFluidFilledPercentage",
        inputGasPct   = "getInputGasFilledPercentage",
        outputGasPct  = "getOutputGasFilledPercentage",
        energyUsage   = "getEnergyUsage",
    },
    INDUCTION_MATRIX = {
        lastInput          = "getLastInput",
        lastOutput         = "getLastOutput",
        installedCells     = "getInstalledCells",
        installedProviders = "getInstalledProviders",
        transferCap        = "getTransferCap",
        energy             = "getEnergy",             -- best-effort, unconfirmed
        maxEnergy          = "getMaxEnergy",           -- best-effort, unconfirmed
        energyPct          = "getEnergyFilledPercentage", -- best-effort, unconfirmed
    },
    SPS = {
        inputPct    = "getInputFilledPercentage",
        outputPct   = "getOutputFilledPercentage",
        processRate = "getProcessRate",
        coils       = "getCoils",
    },
    DYNAMIC_TANK = {
        filledPct    = "getFilledPercentage",
        tankCapacity = "getTankCapacity",
        stored       = "getStored", -- special-cased in pollUnitFields: only .amount is kept
    },
    ENV_DETECTOR = {
        radiationRaw = "getRadiationRaw",
    },
}

-- Placeholder alarm sound for PLAY_ALARM (see handleCommand below) - a
-- configurable choice, not a claim about the API. Swap for a real siren
-- resource location if the pack has one.
local ALARM_SOUND = "minecraft:block.bell.use"

-- detectedUnits: multi-instance classes are [peripheralName] = wrapped
-- handle maps; INDUCTION_MATRIX/SPS are singletons (first-detected wins,
-- see registerUnit) so they're a plain { name=, handle= } table or nil.
local detectedUnits = {
    TURBINE          = {},
    SNA              = {},
    CENTRIFUGE       = {},
    CHEM_DISSOLUTION = {},
    PRC              = {},
    DYNAMIC_TANK     = {},
    ENV_DETECTOR     = {},
    SPEAKER          = {},
    INDUCTION_MATRIX = nil,
    SPS              = nil,
}

local unitClassByName    = {} -- peripheralName -> class id, for O(1) detach cleanup
local unrecognizedLogged = {} -- peripheralName -> true, so unmatched peripherals log once, not every scan

-- Reactor's own peripheral (reactorSide) is deliberately excluded here -
-- it's already owned/managed by tryBindReactor/unbindReactor above and
-- must never be double-classified or double-wrapped.
local function classifyPeripheral(name)
    if name == reactorSide then
        return nil
    end

    local okType, ptype = pcall(peripheral.getType, name)
    if okType and ptype == "speaker" then
        return "SPEAKER"
    end
    -- Version-gated per Advanced Peripherals' own docs: environmentDetector
    -- pre-1.21.1, environment_detector on 1.21.1+. Checking both rather
    -- than hardcoding one avoids guessing which this project's exact game
    -- version uses.
    if okType and (ptype == "environmentDetector" or ptype == "environment_detector") then
        return "ENV_DETECTOR"
    end

    local okMethods, methods = pcall(peripheral.getMethods, name)
    if not okMethods or type(methods) ~= "table" then
        return nil
    end
    local has = {}
    for _, m in ipairs(methods) do
        has[m] = true
    end

    for _, def in ipairs(MEK_CLASSES) do
        local matched = true
        for _, m in ipairs(def.fingerprint) do
            if not has[m] then
                matched = false
                break
            end
        end
        if matched then
            return def.id
        end
    end

    return nil
end

local function registerUnit(name, class)
    local okWrap, handle = pcall(peripheral.wrap, name)
    if not okWrap or not handle then
        return
    end

    local def = MEK_CLASS_BY_ID[class]
    if def.singleton then
        if detectedUnits[class] then
            logLine(("WARNING: multiple %s detected - keeping %s, ignoring %s"):format(
                class, detectedUnits[class].name, name))
            return
        end
        detectedUnits[class] = { name = name, handle = handle }
    else
        detectedUnits[class][name] = handle
    end

    unitClassByName[name] = class
    logLine(class .. " bound: " .. name)
    safeDraw()
end

local function unregisterUnit(name)
    local class = unitClassByName[name]
    if not class then
        return -- not a tracked auxiliary unit (or already removed) - nothing to do
    end
    unitClassByName[name] = nil
    unrecognizedLogged[name] = nil

    local def = MEK_CLASS_BY_ID[class]
    if def.singleton then
        if detectedUnits[class] and detectedUnits[class].name == name then
            detectedUnits[class] = nil
        end
    else
        detectedUnits[class][name] = nil
    end

    logLine(class .. " lost: " .. name)
    safeDraw()
end

-- Opportunistic full sweep, same "retry every tick + on every peripheral
-- event" pattern tryBindReactor/tryOpenSecnet already use. Already-tracked
-- names are skipped cheaply via unitClassByName. An unrecognized peripheral
-- is logged once (not every scan) with its raw getType()/method count so a
-- wrong/missing fingerprint is easy to diagnose from the RTU's own log.
local function scanPeripherals()
    local okNames, names = pcall(peripheral.getNames)
    if not okNames or type(names) ~= "table" then
        return
    end

    for _, name in ipairs(names) do
        if name ~= reactorSide and not unitClassByName[name] then
            local class = classifyPeripheral(name)
            if class then
                registerUnit(name, class)
            elseif not unrecognizedLogged[name] then
                unrecognizedLogged[name] = true
                local okType, ptype   = pcall(peripheral.getType, name)
                local okMethods, methods = pcall(peripheral.getMethods, name)
                logLine(("unrecognized peripheral: %s (type=%s, %d methods)"):format(
                    name, okType and tostring(ptype) or "?",
                    (okMethods and type(methods) == "table") and #methods or 0))
            end
        end
    end
end

-- Polls one unit's configured fields, each individually pcall-guarded.
-- `stored` is special-cased: Mekanism's getStored() returns a raw
-- {amount=, ...} chemical/fluid stack table - only .amount is kept, to
-- keep the broadcast payload small (see plan notes: no raw stack tables).
local function pollUnitFields(handle, fieldMap)
    local out = {}
    for stateField, getterName in pairs(fieldMap) do
        local getter = handle[getterName]
        if type(getter) == "function" then
            local ok, val = pcall(getter)
            if ok then
                if stateField == "stored" and type(val) == "table" then
                    out.stored = val.amount
                else
                    out[stateField] = val
                end
            end
        end
    end
    return out
end

-- Refreshes rtuState.aux from every currently-detected unit. Called from
-- pollAndPublish() each tick, right after scanPeripherals() - rides inside
-- the existing `state = rtuState` TELEMETRY broadcast, no separate payload
-- field needed (see rtuState.aux's own declaration comment above).
local function pollAuxUnits()
    local aux = rtuState.aux

    aux.turbines, aux.snas, aux.centrifuges = {}, {}, {}
    aux.chemDissolutionChambers, aux.prcs   = {}, {}
    aux.tanks, aux.envDetectors             = {}, {}

    for name, handle in pairs(detectedUnits.TURBINE) do
        aux.turbines[name] = pollUnitFields(handle, FIELD_MAP.TURBINE)
    end
    for name, handle in pairs(detectedUnits.SNA) do
        aux.snas[name] = pollUnitFields(handle, FIELD_MAP.SNA)
    end
    for name, handle in pairs(detectedUnits.CENTRIFUGE) do
        aux.centrifuges[name] = pollUnitFields(handle, FIELD_MAP.CENTRIFUGE)
    end
    for name, handle in pairs(detectedUnits.CHEM_DISSOLUTION) do
        aux.chemDissolutionChambers[name] = pollUnitFields(handle, FIELD_MAP.CHEM_DISSOLUTION)
    end
    for name, handle in pairs(detectedUnits.PRC) do
        aux.prcs[name] = pollUnitFields(handle, FIELD_MAP.PRC)
    end
    for name, handle in pairs(detectedUnits.DYNAMIC_TANK) do
        aux.tanks[name] = pollUnitFields(handle, FIELD_MAP.DYNAMIC_TANK)
    end
    for name, handle in pairs(detectedUnits.ENV_DETECTOR) do
        aux.envDetectors[name] = pollUnitFields(handle, FIELD_MAP.ENV_DETECTOR)
    end

    aux.inductionMatrix = detectedUnits.INDUCTION_MATRIX
        and pollUnitFields(detectedUnits.INDUCTION_MATRIX.handle, FIELD_MAP.INDUCTION_MATRIX) or nil
    aux.sps = detectedUnits.SPS
        and pollUnitFields(detectedUnits.SPS.handle, FIELD_MAP.SPS) or nil
end

-- ===========================================================================
-- AUXILIARY COMMAND HANDLING - see file header "AUXILIARY PERIPHERAL
-- COMMAND HANDLING" for the full reasoning (narrow, ungated, never touches
-- reactor authority). Mirrors plc.lua's ACK wire shape exactly (plc.lua's
-- COMMAND handling section documents the full contract).
-- ===========================================================================
local function sendAck(fromId, action, accepted, reason, requestId)
    secnet.send(fromId, NET.PROTOCOL_SUPERVISOR, MSG.ACK, {
        action    = action,
        accepted  = accepted,
        reason    = reason,
        requestId = requestId,
    })
end

-- Inbound COMMAND payload contract:
--   { action = "CYCLE_TURBINE_DUMPING_MODE", target = <turbine peripheral name>, requestId = <optional> }
--   { action = "PLAY_ALARM", requestId = <optional> }
-- Outbound ACK: { action, accepted, reason, requestId } - reasons:
--   "malformed-command" | "unknown-action" | "target-not-found"
--   (CYCLE_TURBINE_DUMPING_MODE, no turbine matches `target`) |
--   "actuation-failed" (peripheral call itself errored) |
--   "no-speaker" (PLAY_ALARM, no speaker peripheral attached).
local function handleCommand(fromId, payload)
    if type(payload) ~= "table" or type(payload.action) ~= "string" then
        sendAck(fromId, nil, false, "malformed-command", type(payload) == "table" and payload.requestId or nil)
        return
    end

    local action, requestId = payload.action, payload.requestId

    if action == "CYCLE_TURBINE_DUMPING_MODE" then
        local handle = type(payload.target) == "string" and detectedUnits.TURBINE[payload.target]
        if not handle then
            sendAck(fromId, action, false, "target-not-found", requestId)
            return
        end
        local ok = pcall(handle.incrementDumpingMode)
        if not ok then
            sendAck(fromId, action, false, "actuation-failed", requestId)
            return
        end
        logLine(("turbine %s dumping mode cycled via COMMAND from #%d"):format(payload.target, fromId))
        safeDraw()
        sendAck(fromId, action, true, nil, requestId)
        return
    end

    if action == "PLAY_ALARM" then
        local any = false
        for _, handle in pairs(detectedUnits.SPEAKER) do
            local ok = pcall(handle.playSound, ALARM_SOUND)
            any = any or ok
        end
        if not any then
            sendAck(fromId, action, false, "no-speaker", requestId)
            return
        end
        logLine(("alarm played via COMMAND from #%d"):format(fromId))
        safeDraw()
        sendAck(fromId, action, true, nil, requestId)
        return
    end

    sendAck(fromId, action, false, "unknown-action", requestId)
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

    scanPeripherals() -- opportunistic retry, same reasoning; "peripheral" event handles the common case
    pollAuxUnits()

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
                -- every other node uses. This node still observes every
                -- msgType it might see (HEARTBEAT/SCRAM/etc addressed to
                -- other nodes too, since rednet protocol tags are not a
                -- delivery filter and this is one shared-secret network -
                -- see header), but only acts on MSG.COMMAND now - see file
                -- header "AUXILIARY PERIPHERAL COMMAND HANDLING".
                local fromId, msgType, payload = secnet.handleEvent(p1, p2)
                if fromId and msgType == MSG.COMMAND then
                    handleCommand(fromId, payload)
                end
            elseif event == "peripheral" then
                tryBindReactor(p1)
                tryOpenSecnet() -- a modem attaching this tick is exactly what "peripheral" fires for
                scanPeripherals()
            elseif event == "peripheral_detach" then
                if p1 == reactorSide then
                    unbindReactor("peripheral_detach on side " .. tostring(p1))
                end
                unregisterUnit(p1) -- no-op if p1 isn't a tracked auxiliary unit
            elseif event == "mouse_click" and p1 == 1 then
                -- Navigation-only, same as nodes/plc.lua - no branch here
                -- ever issues a reactor action (this node has none to issue).
                local x, y = p2, p3
                if currentScreen == "desktop" then
                    local key = os_shell.hitTestIcons(lastDesktopIcons, x, y)
                    if key == "update" then
                        launchUpdater()
                    elseif key == "scada" or key == "systems" or key == "settings" or key == "network" then
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
