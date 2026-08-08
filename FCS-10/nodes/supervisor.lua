-- nodes/supervisor.lua
-- FCS-10 / ATM-PCS :: Central Supervisor
--
-- Aggregates telemetry from every PLC on the network, feeds each PLC's
-- local heartbeat watchdog (see nodes/plc.lua), performs the higher-level
-- Emergency Action Level assessment that lib/config.lua's own comments
-- already assign to this node ("Supervisor's EAL voting logic"), offers a
-- command interface to issue burn-rate/SCRAM commands, and renders a
-- read-only operator terminal. Like plc.lua, this file must never block
-- longer than a single os.pullEvent() wait and must never crash: if the
-- Supervisor goes down, every PLC's own watchdog will fail-safe SCRAM once
-- HEARTBEAT_TIMEOUT_S elapses without a heartbeat - that's the intended,
-- already-shipped failure mode, so this file does not run its own
-- self-watchdog.
--
-- PROTOCOL ADDRESSING (same convention plc.lua established - tag on an
-- outbound message is always the AUDIENCE's protocol, never this node's
-- own): this file hosts on PROTOCOL_SUPERVISOR (secnet.open), but every
-- outbound HEARTBEAT/COMMAND (audience = PLCs) is tagged PROTOCOL_PLC.
-- Getting this backwards would silently mean PLCs never see the heartbeat
-- that is supposed to stop them fail-safe SCRAMming.
--
-- SCOPE: mostly read-only monitoring, split across 3 tabs (SVR/PLC/RTU -
-- see the "Tab bar" section below) so the system-wide summary and the two
-- role-specific tables each get the whole terminal body instead of sharing
-- one screen, plus a click-only command interface (SCRAM / OPEN BYPASS /
-- CLOSE BYPASS buttons, on whichever PLC row is clicked first) and a fuller
-- callable command interface
-- (sendBurnRateCommand/sendApplyTagCommand/etc, all the way up to
-- sendExitTestingCommand) reachable from a REPL pulled into this running
-- script. The buttons are deliberately click-only, never a typed-input
-- prompt: this file must never block longer than a single os.pullEvent()
-- wait (see above), and a blocking read() for a burn-rate value/LOTO
-- reason/Shift Supervisor key could pause this loop past
-- HEARTBEAT_TIMEOUT_S, which would make every PLC's own watchdog assume
-- this node is dead and fail-safe SCRAM the whole fleet. Commands needing
-- typed input stay on test/cmd_test.lua for now - a proper non-blocking
-- on-screen keyboard is a real future feature, not attempted here. Note
-- also that because CC:Tweaked runs each program in its own environment,
-- the callable functions are reachable from other code only if that code
-- lives in (or is pulled into) THIS running script - not from a separate
-- concurrent shell/REPL process on the same computer.
--
-- EAL MAPPING: config.EAL.IC only names keys for damage (all three tiers),
-- coolant (LOSS_OF_COOLANT), and SCRAM_FAILURE. There is no dedicated key
-- for temperature or waste, and RADIATION_RELEASE has no Mekanism
-- telemetry field that could ever drive it. Rather than edit the shared
-- SSOT, this file applies a generic WARNING/HIGH_ALARM -> NOUE/ALERT band
-- mapping (matching config.lua's own doc-comment framing of those bands)
-- to every metric that has one, and reserves config.EAL.IC's two *named*
-- keys for the two things they were actually written for. See computeEAL().

local okCfg, config = pcall(dofile, "/lib/config.lua")
if not okCfg then
    print("[SUP] FATAL: failed to load /lib/config.lua: " .. tostring(config))
    return
end

local okSn, secnet = pcall(dofile, "/lib/secnet.lua")
if not okSn then
    print("[SUP] FATAL: failed to load /lib/secnet.lua: " .. tostring(secnet))
    return
end

local okShell, os_shell = pcall(dofile, "/lib/os_shell.lua")
if not okShell then
    print("[SUP] FATAL: failed to load /lib/os_shell.lua: " .. tostring(os_shell))
    return
end

-- gfx (CC:Graphics gauges/pixel-text/trend arrows) load is NON-FATAL, same
-- reasoning as every other optional lib in this project: a missing/broken
-- visual mod must never take down the Supervisor console. gfxLoadFailed is
-- tracked separately from `gfx` itself: if the real module fails to load,
-- `gfx` is reassigned below to a minimal shim mimicking its own text-mode
-- fallback behavior (same call signatures, always routes to plain
-- term.write) - see nodes/plc.lua's identical load block for the full
-- reasoning (drawConsoleScreen never needs a separate "gfx missing
-- entirely" branch this way; only drawNetworkScreen's diagnostic checks
-- gfxLoadFailed directly, to tell the operator the two failure cases apart).
-- The shim also covers drawTrendArrow/drawStatusLed (drawRoleTab below calls
-- both directly, not just drawText/drawBarMeter) - each mirrors the real
-- module's own text-mode fallback exactly.
local okGfx, gfxModule = pcall(dofile, "/lib/gfx.lua")
local gfxLoadFailed = not okGfx
local gfx = okGfx and gfxModule or nil
if gfxLoadFailed then
    print("[SUP] WARNING: failed to load /lib/gfx.lua: " .. tostring(gfxModule) ..
          " - console will render as plain text")
    local FALLBACK_ARROW = { up = "^", down = "v", flat = "-" }
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
        drawTrendArrow = function(x, y, direction, color)
            term.setCursorPos(x, y)
            term.setTextColor(color or colors.white)
            term.write(FALLBACK_ARROW[direction] or "-")
        end,
        drawStatusLed = function(x, y, color, fallbackChar)
            term.setCursorPos(x, y)
            term.setTextColor(color or colors.white)
            term.write(fallbackChar or "*")
        end,
        drawBevel = function(x, y, w, h, bg)
            for row = 0, h - 1 do
                term.setCursorPos(x, y + row)
                term.setBackgroundColor(bg)
                term.write(string.rep(" ", w))
            end
        end,
    }
end

local NET    = config.NETWORK
local MSG    = config.NETWORK.MSG_TYPE
local SP     = config.SETPOINTS
local STATES = config.STATES

-- Tier id -> priority / full tier table, built once from the SSOT rather
-- than hardcoding "NOUE"/"ALERT"/"SAE"/"GE" priority numbers here.
local TIER_PRIORITY = {}
local TIER_BY_ID    = {}
for _, t in ipairs(config.EAL.TIERS) do
    TIER_PRIORITY[t.id] = t.priority
    TIER_BY_ID[t.id]    = t
end

local STATUS_COLOR = {
    ["AWAITING PLC"] = colors.gray,
    NORMAL           = colors.green,
    WARNING          = colors.yellow,
    SCRAMMED         = colors.red,
    DISCONNECTED     = colors.orange,
}

-- ---------------------------------------------------------------------------
-- CHROME - a retro-browser-window palette (Netscape 4 / Windows 95 raised-
-- button chrome) for the CONSOLE screen only, via drawConsoleScreen below.
-- Deliberately separate from os_shell.THEME: the shared theme (still black
-- bg / white text) is what every OTHER screen on every node still uses
-- (desktop/Settings/Network/SCADA) - this is a one-screen aesthetic choice,
-- not a new site-wide theme, so it gets its own local table rather than a
-- new os_shell.THEMES entry. Content-area text still uses the SAME semantic
-- colors as before (colors.red/orange/green/yellow for status/EAL/stale-
-- data - see drawSvrTab/drawRoleTab below) since those read fine against a
-- light background too; only the "normal, nothing special" text/background
-- pair changes from white-on-black to contentText-on-contentBg.
-- ---------------------------------------------------------------------------
local CHROME = {
    titleBg     = colors.blue,
    titleText   = colors.white,
    barBg       = colors.lightGray,  -- menu bar / toolbar / status bar
    barText     = colors.black,
    barDim      = colors.gray,       -- disabled toolbar buttons / secondary status text
    locBg       = colors.white,      -- location bar "field"
    locText     = colors.black,
    contentBg   = colors.lightGray,
    contentText = colors.black,
}

-- Short display abbreviations for config.OPERATING_MODES, fit to the
-- table's 10-char STATE field - shown in place of the literal "NORMAL"
-- text when plantState is NORMAL (ANOMALY/SCRAMMED keep their own display,
-- see redraw()'s per-row loop).
local OPERATING_MODE_ABBR = {
    COLD_START_BYPASS = "CLD-START",
    RUN_UP            = "RUN-UP",
    HOT_STANDBY       = "HOT-STDBY",
    NORMAL_OPERATION  = "NORMAL",
    AUTO_RUNBACK      = "RUNBACK",
}

-- Epsilon per metric below which a sample-to-sample change is treated as
-- noise rather than a real trend, for the UI-only trend glyph (never feeds
-- the EAL decision - see computeEAL()).
local TREND_EPS = { damagePct = 0.1, coreTempK = 1, coolantPct = 0.5, wastePct = 0.5 }

-- Theme/button pattern ported from nodes/hmi.lua (and installer.lua's GUI
-- wizard, which already duplicated it the same way) - kept local to each
-- file rather than factored into a shared module, consistent with how this
-- codebase has handled it so far. Click-only actions for now (SCRAM/bypass
-- open/close): commands needing typed input (burn rate, LOTO reason, Shift
-- Supervisor key) stay on test/cmd_test.lua, since this file must never
-- block longer than a single os.pullEvent() wait (see file header) - a
-- blocking read() prompt here for more than HEARTBEAT_TIMEOUT_S would cause
-- every PLC's own watchdog to assume this node is dead and fail-safe SCRAM
-- the whole fleet.
--
-- Colors now come from os_shell.THEME rather than a local table (unlike
-- the "keep it local" framing above, which is about the drawButton/
-- hitTestButtons *pattern*, not the palette itself) - so this screen's
-- buttons stay in sync with whatever theme Settings has switched to,
-- instead of being stuck on one fixed palette forever.
-- Routed through gfx.drawBevel (raised-button chrome, matching the retro
-- toolbar look - see drawConsoleScreen/drawToolbar) + gfx.drawText (label
-- only, no background fill of its own - the bevel already painted one)
-- rather than a plain filled rectangle, so this button survives graphics
-- mode on the console screen the same way nodes/plc.lua's/nodes/rtu.lua's
-- gauge rows do, and now LOOKS like the rest of the console's chrome too.
local function drawButton(btn, selected)
    local theme = os_shell.THEME
    local bg = selected and colors.white or theme[btn.colorKey]
    local fg = selected and colors.black or theme.text
    gfx.drawBevel(btn.x, btn.y, btn.width, 1, bg, colors.white, colors.gray)
    local pad = math.max(0, btn.width - #btn.label)
    local leftPad = math.floor(pad / 2)
    gfx.drawText(btn.x + leftPad, btn.y, btn.label, fg, nil)
end

local function hitTestButtons(buttons, x, y)
    for _, btn in ipairs(buttons) do
        if y == btn.y and x >= btn.x and x < btn.x + btn.width then
            return btn
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------
local plcs               = {} -- [plcId] = record, discovered lazily from the first authenticated packet
local pendingCommands     = {} -- [requestId] = pend
local timerToRequest      = {} -- [timerId] = requestId, reverse map for O(1) dispatch on a bare "timer" event
local nextRequestIdCounter = 0
local lastHeartbeatSentAt  = 0
local lastCommandRef       = nil -- most recent pend (pending or resolved), for the header line
local lastScramGlobal      = nil -- most recent SCRAM across all PLCs, for the header line

local selectedPlcId        = nil -- clicked PLC row, target of the click-only action buttons below
-- Captured at the end of each redraw() so the mouse_click handler can map a
-- click's (x,y) back to a plcId / button without duplicating the sort and
-- layout logic that produced them.
local lastRenderedRows      = {}
local lastRenderedTableTop  = nil
local lastRenderedButtons   = {}
local lastRenderedToolbar   = {} -- BACK/FORWARD/HOME/RELOAD/etc. hit regions, same capture pattern
local lastRenderedCloseBox  = nil -- title bar's "X" -> desktop, same capture pattern
local lastRenderedBookmarksButton = nil -- the one real word in the menu bar - see drawMenuBar/drawBookmarksMenu
local lastRenderedBookmarks = {} -- open dropdown's page-list hit regions, valid only while bookmarksOpen

-- True while the Bookmarks dropdown (see drawBookmarksMenu below) is open.
-- Persists across redraws (a 1Hz/click-driven full-screen redraw would
-- otherwise close it every tick) until the operator clicks anything at all -
-- see main()'s click handler, which checks this FIRST, before every other
-- console hit-test, so a click while the menu is open can never also land
-- on whatever's underneath it.
local bookmarksOpen = false

-- Which of the 3 pages (see TABS/cycleTab below) is currently showing.
-- "SVR" is the landing tab: an operator's first question on opening this
-- screen is "is everything OK overall", not "show me every PLC row" -
-- matches aggregateStatus()'s own role as the single system-wide verdict.
local currentTab = "SVR"

-- currentScreen drives ONLY which top-level screen function runs and where
-- mouse_click is routed - see "DESKTOP SHELL" below. "console" is this
-- file's existing SVR/PLC/RTU tabbed view (currentTab, above, picks the
-- tab within it); it has zero effect on the telemetry/command logic.
local currentScreen    = "desktop" -- "desktop" | "console" | "settings" | "network"
local lastDesktopIcons = {}        -- laid-out icon hit-regions from the last drawDesktopScreen()
local homeHitRegion    = nil       -- HOME button hit-region from the last Settings/Network chrome draw

local secnetOpen = false -- true once secnet.open() has ever succeeded (see tryOpenSecnet)

-- secnet.open()'s only failure mode is "no modem found this call" (see
-- lib/secnet.lua) - often just a boot-order race, since a modem peripheral
-- can attach a tick or two after the computer itself starts running. A
-- single failed attempt at boot must not leave this node permanently deaf:
-- every PLC's own watchdog fail-safe SCRAMs on the assumption a live
-- Supervisor would otherwise be heartbeating it, so a Supervisor stuck deaf
-- forever is the worst version of this bug in the whole project. Retried
-- opportunistically every TELEMETRY_INTERVAL_S tick and on every
-- "peripheral" attach event (same belt-and-suspenders pattern
-- nodes/plc.lua's tryBindReactor/tryOpenSecnet use for the reactor/modem).
local function tryOpenSecnet()
    if secnetOpen then
        return true
    end
    local ok, err = secnet.open(nil, NET.PROTOCOL_SUPERVISOR)
    if ok then
        secnetOpen = true
        print("[SUP] secnet opened")
    end
    return ok, err
end

-- ---------------------------------------------------------------------------
-- Per-PLC record lifecycle
-- ---------------------------------------------------------------------------
local function touchPlc(plcId)
    local rec = plcs[plcId]
    if not rec then
        rec = {
            id                 = plcId,
            firstSeenTs        = os.epoch("utc"),
            lastSeenTs         = 0,
            lastTelemetryTs    = 0, -- 0 == "never" -- drives online/offline (see isOnline)
            state              = config.newDefaultReactorState(),
            prevState          = nil, -- previous TELEMETRY .state, for the UI trend glyph only
            peripheralPresent  = false,
            actuationConfirmed = nil,
            activeEAL          = nil, -- Supervisor-computed; a PLC's own copy of this field is always nil
            lastScram          = nil,
            lastCommand        = nil,
            loto               = nil, -- mirrors most recent TELEMETRY's `loto` field; nil = untagged
            operatingMode      = nil,
            steamBypassOpen    = nil,
            testingMode        = nil,
            epgActive          = nil,
            role               = nil, -- "PLC" | "RTU" | nil (genuinely unknown until first TELEMETRY confirms it)
        }
        plcs[plcId] = rec
    end
    rec.lastSeenTs = os.epoch("utc")
    return rec
end

-- A PLC counts as online only if TELEMETRY specifically has arrived
-- recently (per the literal requirement) - not just any authenticated
-- packet. lastTelemetryTs starts at 0, so a PLC that has said hello via
-- HEARTBEAT but never sent TELEMETRY correctly reads as offline.
local function isOnline(rec)
    return (os.epoch("utc") - rec.lastTelemetryTs) < (NET.HEARTBEAT_TIMEOUT_S * 1000)
end

-- ---------------------------------------------------------------------------
-- EAL evaluator
-- ---------------------------------------------------------------------------
-- Generic band->tier helper: WARNING-shaped -> NOUE, HIGH_ALARM-shaped ->
-- ALERT, optional crit -> GE. Matches config.lua's own doc-comments, which
-- already frame a WARNING/HIGH_ALARM crossing as the "trend"/"approaching
-- limit" signal - this is deliberately a plain threshold comparison, not
-- rate-of-change math, so the safety classification stays simple and
-- auditable.
local function bandTier(value, warn, high, crit)
    if crit and value >= crit then
        return "GE"
    end
    if value >= high then
        return "ALERT"
    end
    if value >= warn then
        return "NOUE"
    end
    return nil
end

local function computeEAL(rec)
    local s = rec.state
    local hits = {}

    hits[#hits + 1] = bandTier(s.damagePct, SP.DAMAGE.WARNING, SP.DAMAGE.HIGH_ALARM, SP.DAMAGE.CORE_DAMAGE)
    hits[#hits + 1] = bandTier(s.coreTempK, SP.CORE_TEMP_K.WARNING, SP.CORE_TEMP_K.HIGH_ALARM, nil)
    hits[#hits + 1] = bandTier(s.wastePct, SP.WASTE_PCT.HIGH_WARNING, SP.WASTE_PCT.HIGH_ALARM, nil)

    -- Coolant is inverted (lower = worse). LOSS_OF_COOLANT is keyed to
    -- LOW_ALARM (20%), not LOW_SCRAM (10%): by LOW_SCRAM the PLC's own
    -- hardwired trip has already fired, so an SAE classification at that
    -- point would carry zero lead time. LOW_ALARM gives real supervisory
    -- margin ahead of the trip, which is the whole point of this layer.
    if s.coolantPct <= SP.COOLANT_PCT.LOW_ALARM then
        hits[#hits + 1] = config.EAL.IC.LOSS_OF_COOLANT
    elseif s.coolantPct <= SP.COOLANT_PCT.LOW_WARNING then
        hits[#hits + 1] = "NOUE"
    end

    if rec.lastScram and rec.lastScram.actuationConfirmed == false then
        hits[#hits + 1] = config.EAL.IC.SCRAM_FAILURE
    end

    -- RADIATION_RELEASE (GE) is intentionally never appended here: no
    -- Mekanism telemetry field maps to an actual radiological release, and
    -- reusing e.g. wastePct for that would be a dangerous conflation in a
    -- system modeled on real EAL doctrine. BURN_RATE.OVER_RATE_WARNING is
    -- also unused: it's a ratio against "the reactor's configured max burn
    -- rate," and no such per-reactor max exists anywhere in the shared
    -- state shape to divide by.

    local best, bestPriority = nil, -1
    for _, id in ipairs(hits) do
        local p = id and TIER_PRIORITY[id]
        if p and p > bestPriority then
            best, bestPriority = id, p
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- Inbound message handling (called only after secnet.handleEvent has
-- already verified the packet - see main())
-- ---------------------------------------------------------------------------
-- Short reference reminder printed to the console (the "control room") on
-- an operating-mode transition - the "Checklists on Main Monitor"
-- requirement, realized as a control-room log line rather than a real
-- Monitor peripheral (none exists anywhere in this project).
local OPERATING_MODE_CHECKLIST = {
    COLD_START_BYPASS = "Verify steam bypass OPEN before startup.",
    RUN_UP            = "Confirm bypass CLOSED, monitor temp rise during run-up.",
    HOT_STANDBY       = "Hold at minimal limits - verify coolant/fuel margins before power ascension.",
    NORMAL_OPERATION  = "At power - burn rate may be adjusted per procedure.",
    AUTO_RUNBACK      = "Automatic runback in progress - investigate triggering condition before restoring power.",
}

local function onTelemetry(plcId, payload)
    if type(payload) ~= "table" or type(payload.state) ~= "table" then
        return
    end
    local rec = plcs[plcId]
    rec.prevState          = rec.state
    rec.state              = payload.state
    rec.peripheralPresent  = payload.peripheralPresent
    rec.actuationConfirmed = payload.actuationConfirmed
    rec.lastTelemetryTs    = os.epoch("utc")
    rec.activeEAL          = computeEAL(rec)

    rec.loto            = payload.loto
    rec.steamBypassOpen = payload.steamBypassOpen
    rec.testingMode     = payload.testingMode
    rec.epgActive       = payload.epgActive
    rec.role            = payload.role

    if payload.operatingMode and payload.operatingMode ~= rec.operatingMode then
        print(("[SUP] PLC #%d -> %s: %s"):format(
            plcId, tostring(payload.operatingMode), OPERATING_MODE_CHECKLIST[payload.operatingMode] or ""))
    end
    rec.operatingMode = payload.operatingMode
end

local function onScram(plcId, payload)
    if type(payload) ~= "table" then
        return
    end
    local rec = plcs[plcId]
    rec.lastScram = {
        reason             = payload.reason,
        metrics            = payload.metrics,
        actuationConfirmed = payload.actuationConfirmed,
        ts                 = payload.ts,
        receivedAt         = os.epoch("utc"),
        plcId              = plcId,
    }
    rec.activeEAL  = computeEAL(rec)
    lastScramGlobal = rec.lastScram

    print(("[SUP] SCRAM from #%d: %s (actuation %s)"):format(
        plcId, tostring(payload.reason),
        payload.actuationConfirmed and "confirmed" or "UNCONFIRMED"))
end

local function onAck(plcId, payload)
    if type(payload) ~= "table" or payload.requestId == nil then
        return
    end
    local pend = pendingCommands[payload.requestId]
    if not pend then
        return -- stale/unexpected ACK (e.g. arrived after we already gave up) - ignore
    end

    timerToRequest[pend.timerId] = nil
    pendingCommands[payload.requestId] = nil

    pend.status      = payload.accepted and "acked" or "rejected"
    pend.reason      = payload.reason
    pend.roundTripMs = os.epoch("utc") - pend.firstSentAt

    print(("[SUP] ACK for command #%d (PLC #%d): %s%s"):format(
        payload.requestId, plcId,
        payload.accepted and "accepted" or "rejected",
        payload.reason and (" (" .. payload.reason .. ")") or ""))
end

-- ---------------------------------------------------------------------------
-- Command interface + non-blocking ACK/retry state machine
-- ---------------------------------------------------------------------------
-- COMMAND contract this Supervisor produces (established by plc.lua, which
-- already ships consuming exactly this shape):
--   { action = "SET_BURN_RATE" | "SCRAM" | "APPLY_TAG" | "REMOVE_TAG" |
--              "OPEN_STEAM_BYPASS" | "CLOSE_STEAM_BYPASS" |
--              "ENTER_TESTING" | "EXIT_TESTING",
--     value         = <required for SET_BURN_RATE>,
--     reason        = <required for APPLY_TAG>,
--     supervisorKey = <required for SET_BURN_RATE/APPLY_TAG/REMOVE_TAG/
--                      ENTER_TESTING/EXIT_TESTING - validated for
--                      presence only here; this node has no
--                      /supervisor.key and cannot verify correctness, only
--                      relay whatever the human supplied. Only plc.lua
--                      (via lib/rbac.lua) is the enforcement point>,
--     requestId }
local function nextRequestId()
    nextRequestIdCounter = nextRequestIdCounter + 1
    return nextRequestIdCounter
end

local function dispatchCommand(plcId, payload)
    local sendOk, sendErr = secnet.send(plcId, NET.PROTOCOL_PLC, MSG.COMMAND, payload)

    local timerId = os.startTimer(NET.COMMAND_ACK_TIMEOUT_S)
    local pend = {
        plcId       = plcId,
        payload     = payload,
        attempt     = 1,
        timerId     = timerId,
        firstSentAt = os.epoch("utc"),
        status      = "pending",
    }
    pendingCommands[payload.requestId] = pend
    timerToRequest[timerId] = payload.requestId

    local rec = touchPlc(plcId)
    rec.lastCommand = pend
    lastCommandRef  = pend

    if not sendOk then
        print("[SUP] warning: initial send for command #" .. payload.requestId ..
              " failed (" .. tostring(sendErr) .. "), relying on retry")
    end

    return payload.requestId
end

-- Global on purpose (see file header scope note) - the intended public
-- interface for issuing operator commands from within this script.
function sendBurnRateCommand(plcId, targetRate, supervisorKey)
    local ok, result = pcall(function()
        if type(plcId) ~= "number" then
            error("invalid-plcId", 0)
        end
        if type(targetRate) ~= "number" or targetRate < 0 then
            error("invalid-value", 0)
        end
        if type(supervisorKey) ~= "string" or supervisorKey == "" then
            error("invalid-supervisor-key", 0)
        end
        return dispatchCommand(plcId, {
            action        = "SET_BURN_RATE",
            value         = targetRate,
            supervisorKey = supervisorKey,
            requestId     = nextRequestId(),
        })
    end)
    if not ok then
        return false, result
    end
    return true, result
end

function sendScramCommand(plcId)
    local ok, result = pcall(function()
        if type(plcId) ~= "number" then
            error("invalid-plcId", 0)
        end
        return dispatchCommand(plcId, {
            action    = "SCRAM",
            requestId = nextRequestId(),
        })
    end)
    if not ok then
        return false, result
    end
    return true, result
end

function sendApplyTagCommand(plcId, reason, supervisorKey)
    local ok, result = pcall(function()
        if type(plcId) ~= "number" then
            error("invalid-plcId", 0)
        end
        if type(reason) ~= "string" or reason == "" then
            error("invalid-value", 0)
        end
        if type(supervisorKey) ~= "string" or supervisorKey == "" then
            error("invalid-supervisor-key", 0)
        end
        return dispatchCommand(plcId, {
            action        = "APPLY_TAG",
            reason        = reason,
            supervisorKey = supervisorKey,
            requestId     = nextRequestId(),
        })
    end)
    if not ok then
        return false, result
    end
    return true, result
end

function sendRemoveTagCommand(plcId, supervisorKey)
    local ok, result = pcall(function()
        if type(plcId) ~= "number" then
            error("invalid-plcId", 0)
        end
        if type(supervisorKey) ~= "string" or supervisorKey == "" then
            error("invalid-supervisor-key", 0)
        end
        return dispatchCommand(plcId, {
            action        = "REMOVE_TAG",
            supervisorKey = supervisorKey,
            requestId     = nextRequestId(),
        })
    end)
    if not ok then
        return false, result
    end
    return true, result
end

function sendOpenBypassCommand(plcId)
    local ok, result = pcall(function()
        if type(plcId) ~= "number" then
            error("invalid-plcId", 0)
        end
        return dispatchCommand(plcId, {
            action    = "OPEN_STEAM_BYPASS",
            requestId = nextRequestId(),
        })
    end)
    if not ok then
        return false, result
    end
    return true, result
end

function sendCloseBypassCommand(plcId)
    local ok, result = pcall(function()
        if type(plcId) ~= "number" then
            error("invalid-plcId", 0)
        end
        return dispatchCommand(plcId, {
            action    = "CLOSE_STEAM_BYPASS",
            requestId = nextRequestId(),
        })
    end)
    if not ok then
        return false, result
    end
    return true, result
end

function sendEnterTestingCommand(plcId, supervisorKey)
    local ok, result = pcall(function()
        if type(plcId) ~= "number" then
            error("invalid-plcId", 0)
        end
        if type(supervisorKey) ~= "string" or supervisorKey == "" then
            error("invalid-supervisor-key", 0)
        end
        return dispatchCommand(plcId, {
            action        = "ENTER_TESTING",
            supervisorKey = supervisorKey,
            requestId     = nextRequestId(),
        })
    end)
    if not ok then
        return false, result
    end
    return true, result
end

function sendExitTestingCommand(plcId, supervisorKey)
    local ok, result = pcall(function()
        if type(plcId) ~= "number" then
            error("invalid-plcId", 0)
        end
        if type(supervisorKey) ~= "string" or supervisorKey == "" then
            error("invalid-supervisor-key", 0)
        end
        return dispatchCommand(plcId, {
            action        = "EXIT_TESTING",
            supervisorKey = supervisorKey,
            requestId     = nextRequestId(),
        })
    end)
    if not ok then
        return false, result
    end
    return true, result
end

-- Called for any "timer" event that isn't the heartbeat or UI-redraw
-- timer - i.e. every in-flight command's ACK-timeout timer.
local function onCommandTimer(timerId)
    local requestId = timerToRequest[timerId]
    if not requestId then
        return -- stale timer (already resolved/reassigned) or foreign id - ignore
    end
    timerToRequest[timerId] = nil

    local pend = pendingCommands[requestId]
    if not pend then
        return
    end

    if pend.attempt >= NET.COMMAND_RETRY_COUNT then
        pend.status = "failed"
        pend.reason = "no-ack-after-" .. NET.COMMAND_RETRY_COUNT .. "-attempts"
        pendingCommands[requestId] = nil
        print(("[SUP] command #%d to PLC #%d gave up: %s"):format(requestId, pend.plcId, pend.reason))
    else
        pend.attempt = pend.attempt + 1
        secnet.send(pend.plcId, NET.PROTOCOL_PLC, MSG.COMMAND, pend.payload)
        pend.timerId = os.startTimer(NET.COMMAND_ACK_TIMEOUT_S)
        timerToRequest[pend.timerId] = requestId
        print(("[SUP] command #%d to PLC #%d: no ACK, retry %d/%d"):format(
            requestId, pend.plcId, pend.attempt, NET.COMMAND_RETRY_COUNT))
    end
end

-- ---------------------------------------------------------------------------
-- Aggregated system status
-- ---------------------------------------------------------------------------
-- Per-PLC bucket. A SCRAMMED-but-offline PLC buckets as DISCONNECTED, not
-- SCRAMMED: losing comms means the last-known "safely tripped" snapshot
-- can no longer be confirmed, matching plc.lua's own philosophy of never
-- assuming things are fine (or, here, assuming a trip is still holding)
-- when blind.
local BUCKET_RANK = { NORMAL = 1, WARNING = 2, SCRAMMED = 3, DISCONNECTED = 4 }

local function plcBucket(rec)
    if not isOnline(rec) then
        return "DISCONNECTED"
    end
    if rec.state.plantState == STATES.SCRAMMED then
        return "SCRAMMED"
    end
    if rec.state.plantState == STATES.NORMAL and rec.activeEAL == nil then
        return "NORMAL"
    end
    return "WARNING" -- catches ANOMALY and any active EAL tier
end

-- RTU records are excluded from the worst-bucket computation: an RTU has no
-- trip/protective authority (see nodes/rtu.lua's header), so its own
-- hardware-absent/anomaly state shouldn't drive the SYSTEM banner - that's
-- what PLCs are for. Tracks `foundPlc` rather than reusing next(plcs)==nil
-- so "AWAITING PLC" is also shown correctly when only RTUs are connected.
local function aggregateStatus()
    local worst, foundPlc = "NORMAL", false
    for _, rec in pairs(plcs) do
        if rec.role ~= "RTU" then
            foundPlc = true
            local bucket = plcBucket(rec)
            if BUCKET_RANK[bucket] > BUCKET_RANK[worst] then
                worst = bucket
            end
        end
    end
    if not foundPlc then
        return "AWAITING PLC"
    end
    return worst
end

-- ---------------------------------------------------------------------------
-- Terminal UI
-- ---------------------------------------------------------------------------
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

-- Returns "up"/"down"/"flat" (gfx.drawTrendArrow's direction argument -
-- itself already falls back to the equivalent ASCII "^"/"v"/"-" glyph when
-- graphics mode isn't active, so callers below never need their own text
-- fallback) or nil when there's no previous sample yet to compare against -
-- the caller draws a blank cell for that case rather than calling
-- gfx.drawTrendArrow with a bogus direction.
local function trendDirection(prev, cur, eps)
    if prev == nil or cur == nil then
        return nil
    end
    local d = cur - prev
    if d > eps then
        return "up"
    elseif d < -eps then
        return "down"
    end
    return "flat"
end

local function formatCommandStatus(pend)
    if not pend then
        return "none issued yet"
    end
    if pend.status == "acked" then
        return string.format("%s -> #%d acked (%dms)", pend.payload.action, pend.plcId, pend.roundTripMs or 0)
    elseif pend.status == "rejected" then
        return string.format("%s -> #%d rejected (%s)", pend.payload.action, pend.plcId, tostring(pend.reason))
    elseif pend.status == "failed" then
        return string.format("%s -> #%d FAILED (%s)", pend.payload.action, pend.plcId, tostring(pend.reason))
    end
    return string.format("%s -> #%d awaiting ACK (attempt %d/%d)",
        pend.payload.action, pend.plcId, pend.attempt, NET.COMMAND_RETRY_COUNT)
end

-- ---------------------------------------------------------------------------
-- Non-critical maintenance items - conditions worth an operator's attention
-- that DON'T already get prominent treatment elsewhere (SCRAM/high-EAL-tier
-- units already stand out via the PLC/RTU tables' own colored STATE/EAL
-- columns and the SYSTEM status band - repeating those here would just be
-- noise). Feeds both the MAINTENANCE page (drawMaintenanceTab) and the SVR
-- page's own summary count (drawSvrTab). OFFLINE is checked first and
-- returns immediately - once comms are gone, nothing else about a unit is
-- trustworthy enough to report as a specific condition.
-- ---------------------------------------------------------------------------
local function maintenanceItemsFor(plcId, rec)
    local items = {}
    local label = (rec.role == "RTU" and "RTU #" or "PLC #") .. plcId

    if not isOnline(rec) then
        items[#items + 1] = { text = ("%s OFFLINE (last seen %s ago)"):format(label, fmtAge(os.epoch("utc") - rec.lastSeenTs)),
            color = colors.orange }
        return items
    end

    if rec.state.plantState == STATES.ANOMALY then
        items[#items + 1] = { text = ("%s hardware anomaly (peripheral not present)"):format(label), color = colors.orange }
    end

    if rec.activeEAL == "NOUE" then
        items[#items + 1] = { text = ("%s NOUE - a metric is in its WARNING band"):format(label), color = colors.yellow }
    end

    if rec.testingMode then
        items[#items + 1] = { text = ("%s TESTING MODE active"):format(label), color = colors.yellow }
    end

    if rec.loto then
        local reason = (type(rec.loto) == "table" and rec.loto.reason) and tostring(rec.loto.reason) or "tagged"
        items[#items + 1] = { text = ("%s LOTO applied (%s)"):format(label, reason), color = colors.yellow }
    end

    return items
end

-- ---------------------------------------------------------------------------
-- Retro browser chrome (Netscape 4-style) - title bar / menu bar / toolbar /
-- location bar, rows 1-4, replacing the old flat SVR/PLC/RTU tab strip.
-- SVR/PLC/RTU are still the exact same 3 pages (see TABS) - what changed is
-- how you get between them: a real tab strip became a browser's own
-- BACK/FORWARD (cycle through TABS in order, wrapping) + HOME (jump
-- straight to SVR, this console's own "home page" - matches SVR's existing
-- role as the landing tab, see drawSvrTab's own comment). RELOAD is a real
-- (if trivial) action - forces an immediate redraw. EDIT/IMAGES/OPEN/PRINT/
-- FIND/STOP are decorative-disabled, same as a real browser grays out
-- actions with nothing to act on right now; the File/Edit/View/... menu bar
-- below is entirely decorative (no working menus - a real dropdown menu
-- system is out of scope here, and a menu bar that LOOKS clickable but
-- silently does nothing would be worse than one that's honestly just
-- flavor). The title bar's right-hand close box is the one remaining way
-- back to the desktop shell (closing the "browser" returns you to the
-- "OS") - same role the old tab strip's "<HOME " entry played.
-- ---------------------------------------------------------------------------
local TABS = { "SVR", "PLC", "RTU", "MAINTENANCE" }

local function cycleTab(delta)
    local idx = 1
    for i, t in ipairs(TABS) do
        if t == currentTab then
            idx = i
            break
        end
    end
    idx = ((idx - 1 + delta) % #TABS) + 1
    currentTab = TABS[idx]
    -- Same reasoning as the old tab strip's switch handler: a stale
    -- selectedPlcId pointing at a row from the page just left is more
    -- confusing than just asking the operator to reselect.
    selectedPlcId = nil
end

local CLOSE_BOX_LABEL = " X "

local function drawTitleBar(w)
    local title = ("FCS-10 SUPERVISOR #%d - Netscape"):format(os.getComputerID())
    local closeX = w - #CLOSE_BOX_LABEL + 1
    if #title > closeX - 2 then
        title = title:sub(1, math.max(0, closeX - 2))
    end
    gfx.drawText(1, 1, " " .. title .. string.rep(" ", math.max(0, closeX - 2 - #title)), CHROME.titleText, CHROME.titleBg)
    gfx.drawBevel(closeX, 1, #CLOSE_BOX_LABEL, 1, CHROME.barBg, colors.white, CHROME.barDim)
    gfx.drawText(closeX + 1, 1, "X", colors.black, nil)
    lastRenderedCloseBox = { x = closeX, y = 1, width = #CLOSE_BOX_LABEL }
end

-- Decorative only - see this section's header comment. Truncated to `w`
-- rather than left to overflow: gfx.drawText draws real pixels past the
-- edge of the visible canvas in graphics mode with unconfirmed behavior
-- (see lib/gfx.lua's own "never assert an unverified engine fact" rule),
-- so every full-width string in this file is clamped defensively, not just
-- the ones that visibly needed it before.
local MENU_BAR_TEXT = " File  Edit  View  Go  Bookmarks  Options  Directory  Window  Help"

-- "Bookmarks" is the one word in this bar that's REAL (see
-- drawBookmarksMenu below) - everything else here stays honest-decorative
-- (this section's own header comment explains why a fake-clickable dead
-- menu is worse than an openly inert one). Computed via string.find rather
-- than a hardcoded column so it can never drift out of sync with
-- MENU_BAR_TEXT's own literal spacing if that string is ever edited.
local BOOKMARKS_COL = select(1, MENU_BAR_TEXT:find("Bookmarks"))
local BOOKMARKS_W   = select(2, MENU_BAR_TEXT:find("Bookmarks")) - BOOKMARKS_COL + 1

local function drawMenuBar(w)
    local text = MENU_BAR_TEXT
    if #text > w then
        text = text:sub(1, w)
    end
    gfx.drawText(1, 2, text .. string.rep(" ", math.max(0, w - #text)), CHROME.barText, CHROME.barBg)
    lastRenderedBookmarksButton = { x = BOOKMARKS_COL, y = 2, w = BOOKMARKS_W, h = 1 }
end

-- Real dropdown - the working half of the "Bookmarks" menu item above.
-- Lists every page (TABS) as a clickable row in a small raised panel
-- directly under the word "Bookmarks", opened by clicking it (see
-- lastRenderedBookmarksButton above) and closed by clicking ANYTHING
-- afterward, item or not (see main()'s click handler) - matches how a real
-- dropdown menu dismisses on an outside click. Deliberately overlays
-- whatever's normally drawn at rows 3-6 (part of the toolbar/location bar/
-- content) while open - authentic dropdown behavior, not a layout bug.
local BOOKMARK_MENU_W = 14

local function drawBookmarksMenu()
    local x, y = BOOKMARKS_COL, 3
    gfx.drawBevel(x, y, BOOKMARK_MENU_W, #TABS, colors.white, colors.white, colors.gray)
    lastRenderedBookmarks = {}
    for i, tab in ipairs(TABS) do
        local marker = (tab == currentTab) and "> " or "  "
        gfx.drawText(x, y + i - 1, marker .. tab, colors.black, nil)
        lastRenderedBookmarks[#lastRenderedBookmarks + 1] = { id = tab, x = x, y = y + i - 1, width = BOOKMARK_MENU_W }
    end
end

-- id="back"/"forward" cycle TABS; id="home" jumps to SVR; id="reload" forces
-- a redraw (trivial but real - safeRedraw() already runs after every click
-- regardless, so this is honest rather than a total no-op pretending to be
-- one); the rest are permanently disabled (grayed label, still a real
-- bevel) - decorative, same reasoning as the menu bar above.
local TOOLBAR_BUTTONS = {
    { id = "back",    label = "BACK",    width = 6, enabled = true  },
    { id = "forward", label = "FORWARD", width = 9, enabled = true  },
    { id = "home",    label = "HOME",    width = 6, enabled = true  },
    { id = "edit",    label = "EDIT",    width = 6, enabled = false },
    { id = "reload",  label = "RELOAD",  width = 8, enabled = true  },
    { id = "stop",    label = "STOP",    width = 6, enabled = false },
}

local function drawToolbar(w)
    gfx.drawText(1, 3, string.rep(" ", w), CHROME.barText, CHROME.barBg)
    lastRenderedToolbar = {}
    local x = 1
    for _, def in ipairs(TOOLBAR_BUTTONS) do
        if x + def.width - 1 > w then
            break
        end
        gfx.drawBevel(x, 3, def.width, 1, CHROME.barBg, colors.white, CHROME.barDim)
        local pad = math.max(0, def.width - #def.label)
        local leftPad = math.floor(pad / 2)
        gfx.drawText(x + leftPad, 3, def.label, def.enabled and CHROME.barText or CHROME.barDim, nil)
        lastRenderedToolbar[#lastRenderedToolbar + 1] = { id = def.id, x = x, y = 3, width = def.width, enabled = def.enabled }
        x = x + def.width + 1
    end
end

local function drawLocationBar(w)
    local label = "Location: "
    gfx.drawText(1, 4, label, CHROME.barText, CHROME.barBg)
    local fieldX = #label + 1
    local fieldW = math.max(0, w - fieldX + 1)
    local url = ("supervisor://%d/%s"):format(os.getComputerID(), currentTab:lower())
    local text = " " .. url
    if #text > fieldW then
        text = text:sub(1, fieldW)
    end
    gfx.drawText(fieldX, 4, text .. string.rep(" ", math.max(0, fieldW - #text)), CHROME.locText, CHROME.locBg)
end

-- Persistent Netscape-style status bar, row h, shown on every tab regardless
-- of currentTab (a real UX gain over the old design: an operator on the PLC
-- or RTU tab used to have no visibility into overall SYSTEM status at all
-- without switching back to SVR - now it's always in view). Flat CHROME.barBg
-- with colored TEXT (not a colored band like drawSvrTab's own SYSTEM line
-- uses) - deliberately more subdued, so it never visually competes with that
-- banner on the one tab where both would otherwise be on screen together.
local function drawStatusBar(w, h)
    local status = aggregateStatus()
    gfx.drawText(1, h, string.rep(" ", w), CHROME.barText, CHROME.barBg)
    gfx.drawText(2, h, ("SYSTEM: %s"):format(status), STATUS_COLOR[status] or CHROME.barText, nil)
    local right = "FCS-10 SUPERVISOR"
    local rightX = w - #right
    if rightX > 20 then
        gfx.drawText(rightX, h, right, CHROME.barDim, nil)
    end
end

-- SVR tab: the system-wide summary that used to occupy rows 2-6 of the old
-- single-screen layout, now with the whole body to itself. No table, no
-- action buttons - those live on the PLC tab (see drawRoleTab below), so
-- this tab always clears the row-selection render cache to keep a stray
-- click here from being misread as a table/button hit.
local function drawSvrTab(w)
    lastRenderedRows = {}
    lastRenderedTableTop = nil
    lastRenderedButtons = {}

    -- RTU records are excluded from the "(N PLCs, N offline)" tally - that
    -- count is specifically about the protected reactor fleet, not
    -- supplementary monitoring points (see aggregateStatus() above).
    local plcCount, offlineCount, lotoCount = 0, 0, 0
    for _, rec in pairs(plcs) do
        if rec.role ~= "RTU" then
            plcCount = plcCount + 1
            if not isOnline(rec) then
                offlineCount = offlineCount + 1
            end
        end
        if rec.loto then
            lotoCount = lotoCount + 1
        end
    end

    -- Rows start at 5, not 3: rows 1-4 are now the title/menu/toolbar/
    -- location chrome (see drawConsoleScreen) rather than title+tab-strip.
    local status = aggregateStatus()
    local headerLine = (" SYSTEM: %s  (%d PLC%s, %d offline) "):format(
        status, plcCount, plcCount == 1 and "" or "s", offlineCount)
    headerLine = headerLine .. string.rep(" ", math.max(0, w - #headerLine))
    gfx.drawText(1, 5, headerLine, colors.black, STATUS_COLOR[status] or colors.gray)

    gfx.drawText(1, 6, ("HB TX: %s ago (%ds cadence)"):format(
        fmtAge(os.epoch("utc") - lastHeartbeatSentAt), NET.HEARTBEAT_INTERVAL_S), CHROME.contentText, CHROME.contentBg)

    -- Surfaces secnetOpen (tracked for tryOpenSecnet's retry logic - see
    -- module state above) directly to the operator: a Supervisor stuck
    -- unable to open its own modem is the single worst failure mode in
    -- this whole project (every PLC fail-safe SCRAMs once it can't hear a
    -- heartbeat), so it deserves to be visible here, not just in the log.
    gfx.drawText(1, 7, "MODEM: ", CHROME.contentText, CHROME.contentBg)
    if secnetOpen then
        gfx.drawText(8, 7, "OPEN", colors.green, CHROME.contentBg)
    else
        gfx.drawText(8, 7, "NOT OPEN (retrying)", colors.red, CHROME.contentBg)
    end

    gfx.drawText(1, 8, "CMD: " .. formatCommandStatus(lastCommandRef), CHROME.contentText, CHROME.contentBg)

    local scramLine
    if lastScramGlobal then
        local scramPlc = plcs[lastScramGlobal.plcId]
        local epgNote = (scramPlc and scramPlc.epgActive) and " (EPG ACTIVE)" or ""
        scramLine = ("LAST SCRAM: #%d %s ago - %s (%s)%s"):format(
            lastScramGlobal.plcId, fmtAge(os.epoch("utc") - lastScramGlobal.receivedAt),
            tostring(lastScramGlobal.reason),
            lastScramGlobal.actuationConfirmed and "CONFIRMED" or "UNCONFIRMED",
            epgNote)
    else
        scramLine = "LAST SCRAM: none yet"
    end
    gfx.drawText(1, 9, scramLine, CHROME.contentText, CHROME.contentBg)

    if lotoCount > 0 then
        gfx.drawText(1, 10, ("LOTO: %d reactor%s tagged"):format(lotoCount, lotoCount == 1 and "" or "s"),
            colors.red, CHROME.contentBg)
    else
        gfx.drawText(1, 10, "LOTO: none active", CHROME.contentText, CHROME.contentBg)
    end

    -- Points at the MAINTENANCE page (Bookmarks -> MAINTENANCE) rather than
    -- listing items inline here - see maintenanceItemsFor's own header
    -- comment for why this count deliberately excludes anything that
    -- already gets its own prominent treatment (SCRAM/high-EAL/DISCONNECTED
    -- already drive the SYSTEM band above).
    local maintCount = 0
    for plcId, rec in pairs(plcs) do
        maintCount = maintCount + #maintenanceItemsFor(plcId, rec)
    end
    gfx.drawText(1, 11, ("MAINTENANCE: %d non-critical item%s"):format(maintCount, maintCount == 1 and "" or "s"),
        maintCount > 0 and colors.yellow or colors.green, CHROME.contentBg)
end

-- PLC/RTU tabs: a dedicated table filtered by `predicate(rec)`, worst-first
-- sorted exactly as the old single mixed table was. `showButtons` gates the
-- SCRAM/OPEN BYPASS/CLOSE BYPASS row: only the PLC tab gets it - an RTU has
-- no trip/protective authority (see plcBucket()'s own comment) so there is
-- nothing for those buttons to legitimately act on from the RTU tab.
local function drawRoleTab(h, predicate, showButtons)
    local buttons = {}
    if showButtons then
        buttons = {
            { id = "scram",        label = "SCRAM",        x = 1,  y = h, width = 10, colorKey = "btnDanger"  },
            { id = "open_bypass",  label = "OPEN BYPASS",  x = 12, y = h, width = 14, colorKey = "btnSafe"    },
            { id = "close_bypass", label = "CLOSE BYPASS", x = 27, y = h, width = 15, colorKey = "btnNeutral" },
        }
        for _, btn in ipairs(buttons) do
            drawButton(btn, false)
        end
    end
    lastRenderedButtons = buttons

    -- Starts at 5, not 3: rows 1-4 are now the title/menu/toolbar/location
    -- chrome (see drawConsoleScreen) rather than title+tab-strip. `h` here
    -- is already h-1 as passed by drawConsoleScreen (row h itself is
    -- reserved for the persistent status bar - see drawStatusBar), so every
    -- other use of `h` below (button row, reserved-space math) needs no
    -- change of its own.
    local tableTop = 5
    if h < tableTop then
        lastRenderedRows = {}
        lastRenderedTableTop = nil
        return -- terminal too short to show the table at all
    end
    -- Column budget is deliberately tight: ID(4)+LOTO(1)+TEST(1)+STATE(9)+
    -- EAL(5)+DMG(6)+T-K(5)+CLT(6)+WST(6)+BURN(4)+AGE(4) = 51 columns exactly,
    -- fitting a standard 51-wide Advanced Computer with AGE still visible.
    -- The ORIGINAL 55-char row (ID 4 + LOTO/TEST 2 + STATE 10 + EAL 5 + DMG/
    -- T-K 7 each + CLT/WST 6 each + BURN 5 = 55) silently clipped AGE (and
    -- most of BURN) off the right edge on this hardware the whole time -
    -- this rewrite is the first time that got noticed, since gfx.drawText's
    -- per-call explicit columns (no persistent cursor - see the per-row loop
    -- below) forced writing the column math out instead of leaving it
    -- implicit in a chain of term.write calls that just happened to run off
    -- the edge unnoticed. STATE shrunk 10->9 (still fits every value used -
    -- "CLD-START"/"HOT-STDBY" are the longest at 9, see
    -- OPERATING_MODE_ABBR/config.STATES - no truncation). T-K shrunk to 4
    -- digits (fits temps up to 9999K). DMG/CLT/WST all use %5.1f uniformly
    -- now, not the original's mix of %4.1f/%5.1f: a value AT exactly 100.0
    -- needs the full 5 characters regardless (Lua's string.format width is
    -- a MINIMUM, never a truncation), so the original %4.1f fields were
    -- already silently overflowing by 1 column whenever coolant/waste hit
    -- exactly 100.0% or 0.0% padding edge - not a new behavior, just made
    -- uniform and correct here. AGE shows "OFFL" instead of "OFFLINE" to
    -- fit its 4-column budget.
    gfx.drawText(1, tableTop, "ID  STATE   EAL  DMG%  T-K  CLT% WST% BURN AGE",
        CHROME.contentText, CHROME.contentBg)

    -- Sort worst-first so that on a truncated screen the rows most worth an
    -- operator's attention are always the ones still visible.
    local rows = {}
    for plcId, rec in pairs(plcs) do
        if predicate(rec) then
            rows[#rows + 1] = plcId
        end
    end
    table.sort(rows, function(a, b)
        local ra, rb = plcs[a], plcs[b]
        local ba, bb = plcBucket(ra), plcBucket(rb)
        if ba ~= bb then
            return BUCKET_RANK[ba] > BUCKET_RANK[bb]
        end
        local pa = ra.activeEAL and TIER_PRIORITY[ra.activeEAL] or 0
        local pb = rb.activeEAL and TIER_PRIORITY[rb.activeEAL] or 0
        if pa ~= pb then
            return pa > pb
        end
        return a < b
    end)

    -- Leave room below the table for a possible "+N more" footer, plus the
    -- button row pinned to `h` when this tab has one.
    local reserved = showButtons and 2 or 1
    local maxRows = math.max(0, h - tableTop - reserved)
    local shown = math.min(#rows, maxRows)

    lastRenderedRows = {}
    lastRenderedTableTop = tableTop

    -- Column start positions below are derived directly from the ORIGINAL
    -- term.write format widths (e.g. DMG's old "%5.1f%s " was a 5-char
    -- number + 1-char trend glyph + 1 trailing space = 7 total), so this
    -- reproduces the exact layout sequential term.write calls used to
    -- produce - gfx.drawText has no persistent cursor, so every call needs
    -- its own explicit column instead of just continuing where the last one
    -- left off. Do not try to line these up with the header string above -
    -- that's a hand-typed literal, independent of this math.
    for i = 1, shown do
        local plcId = rows[i]
        local rec = plcs[plcId]
        local s, prev = rec.state, rec.prevState
        local online = isOnline(rec)
        local row = tableTop + i

        lastRenderedRows[i] = plcId

        -- "R" prefix instead of "#" for an RTU row - kept even though each
        -- tab is now role-pure, so a row's own identity stays legible if
        -- it's ever screenshotted/logged out of context. Selection
        -- highlight: inverted colors on the ID cell only, so the operator
        -- can see the current click-target at a glance.
        local idText = string.format("%s%-3d", rec.role == "RTU" and "R" or "#", plcId)
        if plcId == selectedPlcId then
            gfx.drawText(1, row, idText, colors.black, colors.white)
        else
            gfx.drawText(1, row, idText, online and CHROME.contentText or colors.orange, CHROME.contentBg)
        end

        -- LOTO / Testing indicators: small filled status LEDs (real pixels
        -- via CC:Graphics, a plain "L"/"T" letter otherwise - see
        -- gfx.drawStatusLed's own fallback contract) rather than a letter
        -- always drawn as text - each column's fixed position already tells
        -- the operator which flag it is, same as the letter did. Last-known
        -- value shown regardless of `online`, same as every other data
        -- column (stale-but-last-known beats blank while offline, per this
        -- project's stated philosophy).
        if rec.loto then
            gfx.drawStatusLed(5, row, colors.red, "L")
        else
            gfx.drawText(5, row, " ", CHROME.contentText, CHROME.contentBg)
        end
        if rec.testingMode then
            gfx.drawStatusLed(6, row, colors.yellow, "T")
        else
            gfx.drawText(6, row, " ", CHROME.contentText, CHROME.contentBg)
        end

        local stateColor
        if s.plantState == STATES.SCRAMMED then
            stateColor = colors.red
        elseif s.plantState == STATES.ANOMALY then
            stateColor = colors.orange
        else
            stateColor = online and CHROME.contentText or colors.orange
        end
        local stateText = s.plantState
        if s.plantState == STATES.NORMAL and rec.operatingMode then
            stateText = OPERATING_MODE_ABBR[rec.operatingMode] or s.plantState
        end
        gfx.drawText(7, row, string.format("%-9s", tostring(stateText or "?")), stateColor, CHROME.contentBg)

        local ealColor = rec.activeEAL and TIER_BY_ID[rec.activeEAL] and colors[TIER_BY_ID[rec.activeEAL].color]
        gfx.drawText(16, row, string.format("%-5s", rec.activeEAL or "--"),
            ealColor or (online and CHROME.contentText or colors.orange), CHROME.contentBg)

        -- Each metric: the exact numeric value (gfx.drawText) plus a real
        -- pixel trend arrow (gfx.drawTrendArrow - falls back to the
        -- equivalent ASCII "^"/"v"/"-" glyph on its own when graphics mode
        -- isn't active, so no separate text fallback is needed here) in the
        -- single character cell right after the number, matching where the
        -- old "%s" glyph placeholder sat in the original format string.
        -- trendDirection returning nil (no previous sample yet) draws a
        -- blank cell instead of calling gfx.drawTrendArrow with a bogus
        -- direction - preserves the original blank-not-dash behavior for a
        -- PLC's very first reading.
        local dataColor = online and CHROME.contentText or colors.orange

        local function metric(col, numFmt, value, prevValue, eps)
            local numText = numFmt:format(value or 0)
            gfx.drawText(col, row, numText, dataColor, CHROME.contentBg)
            local dir = trendDirection(prevValue, value, eps)
            local arrowCol = col + #numText
            if dir then
                gfx.drawTrendArrow(arrowCol, row, dir, dataColor)
            else
                gfx.drawText(arrowCol, row, " ", dataColor, CHROME.contentBg)
            end
        end

        metric(21, "%5.1f", s.damagePct, prev and prev.damagePct, TREND_EPS.damagePct)
        metric(27, "%4.0f", s.coreTempK, prev and prev.coreTempK, TREND_EPS.coreTempK)
        metric(32, "%5.1f", s.coolantPct, prev and prev.coolantPct, TREND_EPS.coolantPct)
        metric(38, "%5.1f", s.wastePct, prev and prev.wastePct, TREND_EPS.wastePct)

        gfx.drawText(44, row, string.format("%4.0f", s.burnRateMbT or 0), dataColor, CHROME.contentBg)

        if online then
            gfx.drawText(48, row, fmtAge(os.epoch("utc") - rec.lastTelemetryTs), dataColor, CHROME.contentBg)
        else
            gfx.drawText(48, row, "OFFL", colors.orange, CHROME.contentBg)
        end
    end

    if #rows > shown then
        gfx.drawText(1, tableTop + shown + 1, ("+%d more (all lower severity)"):format(#rows - shown),
            colors.gray, CHROME.contentBg)
    end
end

-- MAINTENANCE page: every currently-known PLC/RTU's non-critical items in
-- one place (see maintenanceItemsFor above). Rows are clickable the same
-- way the PLC/RTU tables' rows are - reuses lastRenderedRows/
-- lastRenderedTableTop rather than a separate mechanism (see main()'s click
-- handler, which branches on currentTab to tell the two shapes apart:
-- a plain plcId on the PLC/RTU pages, a {plcId, role} table here, since a
-- click here needs to know which page to jump to as well as which row).
-- Clicking a row jumps straight to that unit's own PLC/RTU page with it
-- selected, ready for SCRAM/bypass if it's a PLC.
local function drawMaintenanceTab(w, h)
    lastRenderedButtons = {}

    local tableTop = 5
    gfx.drawText(1, tableTop, "NON-CRITICAL FACILITY ITEMS", CHROME.contentText, CHROME.contentBg)

    local items = {}
    for plcId, rec in pairs(plcs) do
        for _, item in ipairs(maintenanceItemsFor(plcId, rec)) do
            items[#items + 1] = { plcId = plcId, role = rec.role, text = item.text, color = item.color }
        end
    end
    table.sort(items, function(a, b) return a.plcId < b.plcId end)

    lastRenderedRows = {}
    lastRenderedTableTop = tableTop

    if #items == 0 then
        gfx.drawText(1, tableTop + 2, "No non-critical items - facility nominal.", colors.green, CHROME.contentBg)
        return
    end

    local maxRows = math.max(0, h - tableTop - 1)
    local shown = math.min(#items, maxRows)
    for i = 1, shown do
        local it = items[i]
        local row = tableTop + i
        lastRenderedRows[i] = { plcId = it.plcId, role = it.role }
        local text = it.text
        if #text > w then
            text = text:sub(1, w)
        end
        gfx.drawText(1, row, text, it.color, CHROME.contentBg)
    end

    if #items > shown then
        gfx.drawText(1, tableTop + shown + 1, ("+%d more"):format(#items - shown), colors.gray, CHROME.contentBg)
    end
end

-- The pre-existing SVR/PLC/RTU tabbed view, now one of four top-level
-- screens (see "DESKTOP SHELL" below) rather than the only thing this file
-- ever draws - reskinned as a retro browser window (see the CHROME palette
-- and the title/menu/toolbar/location-bar section above for the full
-- reasoning). Drawn ENTIRELY through gfx.drawText/gfx.drawBevel/
-- gfx.drawTrendArrow/gfx.drawStatusLed (real pixels via CC:Graphics when
-- available, plain text otherwise), never a bare term.write - same
-- reasoning as nodes/plc.lua's/nodes/rtu.lua's SCADA screens: CC:Graphics'
-- graphics mode is a confirmed whole-screen toggle, so a screen that wants
-- real trend arrows/bevels has to draw literally everything else on it
-- (chrome, header, every table cell) as pixels too, or graphics mode blanks
-- the rest. gfx.beginFrame() here is what actually turns that on when
-- CC:Graphics is present; every gfx.* call below still silently falls back
-- to today's plain text otherwise.
--
-- Row layout: 1=title bar, 2=menu bar, 3=toolbar, 4=location bar, 5..h-1=
-- content (SVR summary or PLC/RTU table - see drawSvrTab/drawRoleTab),
-- h=persistent status bar. drawRoleTab is handed `h - 1`, not `h`, so its
-- own button-row/reserved-space math (unchanged otherwise) naturally leaves
-- the true last row exclusively to drawStatusBar below.
local function drawConsoleScreen(w, h)
    gfx.beginFrame()
    gfx.clear(CHROME.contentBg)

    drawTitleBar(w)
    drawMenuBar(w)
    drawToolbar(w)
    drawLocationBar(w)

    if currentTab == "PLC" then
        drawRoleTab(h - 1, function(rec) return rec.role ~= "RTU" end, true)
    elseif currentTab == "RTU" then
        drawRoleTab(h - 1, function(rec) return rec.role == "RTU" end, false)
    elseif currentTab == "MAINTENANCE" then
        drawMaintenanceTab(w, h - 1)
    else
        drawSvrTab(w)
    end

    drawStatusBar(w, h)

    -- Drawn LAST, on top of everything above, and only while open - see
    -- lastRenderedBookmarksButton's own doc comment.
    if bookmarksOpen then
        drawBookmarksMenu()
    end
end

-- ---------------------------------------------------------------------------
-- DESKTOP SHELL - built on lib/os_shell.lua's shared boot-splash/desktop/
-- chrome helpers, same move nodes/plc.lua/nodes/rtu.lua make. CONSOLE (the
-- function above) is this node's core operator screen; SETTINGS/NETWORK are
-- read-only info screens; UPDATE isn't a screen at all, see launchUpdater().
-- ---------------------------------------------------------------------------
local DESKTOP_ICONS = {
    { key = "console",  label = "CONSOLE",  color = colors.lightBlue },
    { key = "settings", label = "SETTINGS", color = colors.gray },
    { key = "network",  label = "NETWORK",  color = colors.cyan },
    { key = "update",   label = "UPDATE",   color = colors.blue },
}

local function drawDesktopScreen()
    local status = aggregateStatus()
    lastDesktopIcons = os_shell.drawDesktop({
        title       = ("FCS-10 SUPERVISOR #%d"):format(os.getComputerID()),
        statusRight = ("SYSTEM: %s"):format(status),
        statusColor = STATUS_COLOR[status] or os_shell.THEME.text,
        icons       = DESKTOP_ICONS,
        footer      = "Click an icon to launch a program.",
    })
end

local themeButtonRegion = nil -- theme-toggle hit-region from the last drawSettingsScreen()

local function drawSettingsScreen()
    homeHitRegion = os_shell.drawScreenHeader("SETTINGS")

    local plcCount, rtuCount = 0, 0
    for _, rec in pairs(plcs) do
        if rec.role == "RTU" then
            rtuCount = rtuCount + 1
        else
            plcCount = plcCount + 1
        end
    end

    local status = aggregateStatus()
    local nextRow = os_shell.drawKeyValueList({
        { label = "Role",          value = "SUPERVISOR" },
        { label = "Computer ID",   value = os.getComputerID() },
        { label = "System status", value = status, color = STATUS_COLOR[status] or os_shell.THEME.text },
        { label = "Known PLCs",    value = plcCount },
        { label = "Known RTUs",    value = rtuCount },
        { label = "Last command",  value = formatCommandStatus(lastCommandRef) },
    }, 3)
    themeButtonRegion = os_shell.drawThemeButton(nextRow + 1)
    local _, h = term.getSize()
    os_shell.drawScreenFrame(1, h)
end

local function drawNetworkScreen()
    homeHitRegion = os_shell.drawScreenHeader("NETWORK")

    -- CC:Graphics diagnostic - see lib/gfx.lua's diagnose(): reports which
    -- specific named functions are/aren't present on `term` right now, not
    -- just a single available/not-available bit, since this integration is
    -- still unverified against CC:Graphics' own docs (none could be found).
    local diagRows = {
        { label = "secnet",     value = secnetOpen and "OPEN" or "NOT OPEN",
          color = secnetOpen and colors.green or colors.red },
        { label = "Hosts on",   value = NET.PROTOCOL_SUPERVISOR },
        { label = "Sends to",   value = NET.PROTOCOL_PLC },
        { label = "HB sent",    value = fmtAge(os.epoch("utc") - lastHeartbeatSentAt) .. " ago" },
        { label = "HB cadence", value = NET.HEARTBEAT_INTERVAL_S .. "s" },
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
    local nextRow = os_shell.drawKeyValueList(diagRows, 3)

    -- Peer list - unlike plc.lua/rtu.lua's Network screens, this node
    -- actually tracks one (the `plcs` table), so it's worth showing here.
    -- Bounded to h - 1, not h: row h is reserved for drawScreenFrame()'s
    -- own closing border below, so a full peer list can never collide with
    -- it (an entry silently overwritten by the border would be worse than
    -- just not showing it). Starts right after the diagnostic rows above
    -- (via drawKeyValueList's own returned next-free-row) rather than a
    -- hardcoded row number, so the two blocks can never collide even as the
    -- diagnostic list above grows/shrinks.
    local _, h = term.getSize()
    local lastRow = h - 1
    local row = nextRow + 1
    if row <= lastRow then
        term.setTextColor(colors.gray)
        term.setCursorPos(2, row)
        term.write("Known peers:")
        term.setTextColor(os_shell.THEME.text)
        row = row + 1
    end

    local ids = {}
    for plcId in pairs(plcs) do
        ids[#ids + 1] = plcId
    end
    table.sort(ids)

    for _, plcId in ipairs(ids) do
        if row > lastRow then
            break
        end
        local rec = plcs[plcId]
        local online = isOnline(rec)
        term.setCursorPos(2, row)
        term.setTextColor(online and os_shell.THEME.text or colors.orange)
        term.write(("%s#%-3d %-4s %s"):format(
            rec.role == "RTU" and "R" or " ", plcId, rec.role or "?", online and "online" or "offline"))
        row = row + 1
    end
    term.setTextColor(os_shell.THEME.text)
    os_shell.drawScreenFrame(1, h)
end

-- Full clear + redraw-everything each tick: simplest, most robust choice
-- at a 1Hz cadence on a small CC terminal - no differential rendering.
-- Rows longer than the terminal width are simply clipped by term.write
-- itself (CC terminals don't auto-wrap on write), which is why there is no
-- separate column-dropping logic here: on a narrow terminal the trailing
-- columns (burn rate, age) are what naturally disappear first. Which
-- screen function actually runs depends only on currentScreen, a purely
-- local display choice with no effect on the telemetry/command logic above.
local function redraw()
    local w, h = term.getSize()

    -- Unconditional, every tick, BEFORE branching - same pattern as
    -- nodes/plc.lua's/nodes/rtu.lua's draw() dispatcher: guarantees a known
    -- text-mode state no matter which screen ran last tick. drawConsoleScreen()
    -- is the only screen that turns graphics mode back on, and only for
    -- itself (it does its own gfx.clear() instead of the generic
    -- term.clear() below - see its own header comment).
    gfx.endFrame()

    if currentScreen == "console" then
        drawConsoleScreen(w, h)
        return
    end

    term.setBackgroundColor(os_shell.THEME.bg)
    term.setTextColor(os_shell.THEME.text)
    term.clear()

    if currentScreen == "settings" then
        drawSettingsScreen()
    elseif currentScreen == "network" then
        drawNetworkScreen()
    else
        drawDesktopScreen()
    end
end

-- The one dedicated pcall boundary beyond the outer per-iteration one (see
-- main()) - added for diagnostic clarity, since redraw() is the one code
-- path here with no equivalent in plc.lua and the most surface area for a
-- "surprising" bug (a nil field access on a display-only path).
local function safeRedraw()
    local ok, err = pcall(redraw)
    if not ok then
        print("[SUP] redraw failed: " .. tostring(err))
    end
end

-- Shells out to the existing installer.lua (see nodes/plc.lua's
-- launchUpdater() for the full reasoning - identical here, just targeting
-- role "supervisor" and using print()/safeRedraw() instead of logLine()/
-- safeDraw(), matching this file's own existing logging convention. Every
-- PLC's own watchdog fail-safe SCRAMs if it hears nothing from this node for
-- HEARTBEAT_TIMEOUT_S - shell.run() blocking this loop for the duration is
-- the fail-safe correctly doing its job if that happens, not a bug, which is
-- why this is clearly logged before launching rather than silently swallowed.
local function launchUpdater()
    print("[SUP] UPDATE: opening installer - this console pauses until it returns")
    safeRedraw()
    pcall(function()
        shell.run("/installer.lua", "update", "supervisor")
        os.sleep(2) -- brief, bounded pause so the printed result is readable, never indefinite
    end)
    print("[SUP] UPDATE: installer closed, resuming normal operation")
    safeRedraw()
end

-- ---------------------------------------------------------------------------
-- Main event loop - strictly non-blocking, same pattern as plc.lua: a
-- single os.pullEvent() wait per iteration, os.startTimer()-driven
-- cadences, one outer per-iteration pcall as the last line of defense.
-- ---------------------------------------------------------------------------
local function main()
    -- One-time boot splash, before the main loop starts - see nodes/plc.lua
    -- for the identical reasoning. Purely cosmetic and non-blocking on its
    -- own; the fixed os.sleep() is what holds it on screen briefly.
    os_shell.drawBootSplash({
        title    = "FCS-10",
        subtitle = "Central Supervisor",
        role     = "SUPERVISOR",
        accent   = colors.lightBlue,
    })
    os.sleep(1.2)

    print("[SUP] FCS-10 Supervisor booting on computer #" .. os.getComputerID())

    local okOpen, openErr = tryOpenSecnet()
    if not okOpen then
        print("[SUP] WARNING: secnet.open failed (" .. tostring(openErr) .. ") - will keep retrying as peripherals attach")
    end

    safeRedraw() -- immediate first paint, don't wait a full cadence

    local hbTimerId = os.startTimer(NET.HEARTBEAT_INTERVAL_S)
    local uiTimerId = os.startTimer(NET.TELEMETRY_INTERVAL_S)

    while true do
        -- 4 values captured (not 3, like plc.lua's loop): mouse_click's
        -- y-coordinate is p3, needed for the button/row hit-testing below.
        local event, p1, p2, p3 = os.pullEvent() -- yields every iteration; never a busy-spin

        local ok, err = pcall(function()
            if event == "timer" then
                if p1 == hbTimerId then
                    secnet.broadcast(NET.PROTOCOL_PLC, MSG.HEARTBEAT, {}) -- audience's protocol, not PROTOCOL_SUPERVISOR
                    lastHeartbeatSentAt = os.epoch("utc")
                    hbTimerId = os.startTimer(NET.HEARTBEAT_INTERVAL_S)
                    safeRedraw()
                elseif p1 == uiTimerId then
                    tryOpenSecnet() -- opportunistic retry; peripheral event handles the common case
                    safeRedraw()
                    uiTimerId = os.startTimer(NET.TELEMETRY_INTERVAL_S)
                else
                    onCommandTimer(p1)
                    safeRedraw()
                end
            elseif event == "peripheral" then
                tryOpenSecnet() -- a modem attaching this tick is exactly what "peripheral" fires for
            elseif event == "rednet_message" then
                local fromId, msgType, payload = secnet.handleEvent(p1, p2)
                if fromId then
                    -- touchPlc() is only called for message types a real
                    -- PLC/RTU actually originates (TELEMETRY/SCRAM/
                    -- HEARTBEAT), NOT unconditionally for every
                    -- authenticated message. rednet.broadcast() (unlike
                    -- rednet.send()) reaches every rednet-open computer
                    -- regardless of its protocol tag - the "protocol"
                    -- string is just metadata unless the receiver
                    -- specifically filters on it, and this loop's raw
                    -- os.pullEvent() doesn't. So this node overhears
                    -- broadcasts that were never meant for it too, most
                    -- notably nodes/hmi.lua's COMMAND broadcasts (tagged
                    -- PROTOCOL_PLC, addressed to PLCs, sent on every
                    -- STARTUP/SCRAM button click). Blindly touchPlc(fromId)
                    -- on those used to create a phantom "PLC" row for the
                    -- HMI's own computer ID - no TELEMETRY ever arrives for
                    -- it (HMI never sends any), so it would show up
                    -- permanently OFFLINE and inflate the PLC/offline
                    -- counts forever. ACK doesn't need touchPlc() here
                    -- either: dispatchCommand() above already touches the
                    -- target PLC's record before sending, so by the time
                    -- any ACK for OUR OWN command arrives the record
                    -- already exists.
                    if msgType == MSG.TELEMETRY then
                        touchPlc(fromId)
                        onTelemetry(fromId, payload)
                        safeRedraw()
                    elseif msgType == MSG.SCRAM then
                        touchPlc(fromId)
                        onScram(fromId, payload)
                        safeRedraw()
                    elseif msgType == MSG.ACK then
                        onAck(fromId, payload)
                        safeRedraw()
                    elseif msgType == MSG.HEARTBEAT then
                        touchPlc(fromId)
                        safeRedraw()
                    end
                end
                -- rejections (nil, reason) from secnet.handleEvent are not
                -- errors - ignore and keep the loop running.
            elseif event == "mouse_click" then
                local button, x, y = p1, p2, p3
                if button == 1 then -- left-click only, same guard installer.lua's wizard uses for consequential actions
                    if currentScreen == "desktop" then
                        local key = os_shell.hitTestIcons(lastDesktopIcons, x, y)
                        if key == "update" then
                            launchUpdater()
                        elseif key == "console" or key == "settings" or key == "network" then
                            currentScreen = key
                        end
                    elseif currentScreen == "console" then
                        if bookmarksOpen then
                            -- Any click closes the dropdown, whether or not
                            -- it landed on an item - matches how a real
                            -- menu dismisses on an outside click. This
                            -- branch is checked FIRST, before every other
                            -- console hit-test, so a click while the menu
                            -- is open can never also land on whatever's
                            -- underneath it.
                            local item = hitTestButtons(lastRenderedBookmarks, x, y)
                            if item then
                                currentTab = item.id
                                selectedPlcId = nil
                            end
                            bookmarksOpen = false
                        elseif lastRenderedCloseBox and os_shell.isPointIn(
                            { x = lastRenderedCloseBox.x, y = lastRenderedCloseBox.y, w = lastRenderedCloseBox.width, h = 1 }, x, y) then
                            currentScreen = "desktop"
                        elseif lastRenderedBookmarksButton and os_shell.isPointIn(lastRenderedBookmarksButton, x, y) then
                            bookmarksOpen = true
                        else
                            local toolBtn = hitTestButtons(lastRenderedToolbar, x, y)
                            if toolBtn and toolBtn.enabled then
                                if toolBtn.id == "back" then
                                    cycleTab(-1)
                                elseif toolBtn.id == "forward" then
                                    cycleTab(1)
                                elseif toolBtn.id == "home" then
                                    currentTab = "SVR"
                                    selectedPlcId = nil
                                end
                                -- "reload"/others: no state change - the
                                -- unconditional safeRedraw() below is the
                                -- entire effect, honestly (see drawToolbar's
                                -- header comment on why that's real, not a
                                -- fake no-op).
                            else
                                local btn = hitTestButtons(lastRenderedButtons, x, y)
                                if btn then
                                    if selectedPlcId then
                                        if btn.id == "scram" then
                                            sendScramCommand(selectedPlcId)
                                        elseif btn.id == "open_bypass" then
                                            sendOpenBypassCommand(selectedPlcId)
                                        elseif btn.id == "close_bypass" then
                                            sendCloseBypassCommand(selectedPlcId)
                                        end
                                    end
                                elseif lastRenderedTableTop and y > lastRenderedTableTop and y <= lastRenderedTableTop + #lastRenderedRows then
                                    local rowSel = lastRenderedRows[y - lastRenderedTableTop]
                                    if currentTab == "MAINTENANCE" then
                                        -- rowSel is {plcId, role} here, not
                                        -- a plain plcId - see
                                        -- drawMaintenanceTab's own comment.
                                        currentTab = rowSel.role == "RTU" and "RTU" or "PLC"
                                        selectedPlcId = rowSel.plcId
                                    else
                                        selectedPlcId = rowSel
                                    end
                                end
                            end
                        end
                    elseif currentScreen == "settings" and os_shell.isPointIn(themeButtonRegion, x, y) then
                        os_shell.cycleTheme()
                    elseif homeHitRegion and os_shell.isHomeClick(x, y) then
                        -- settings/network screens
                        currentScreen = "desktop"
                    end
                    safeRedraw()
                end
            end
        end)

        if not ok then
            print("[SUP] event handler error (non-fatal, loop continues): " .. tostring(err))
        end
    end
end

main()
