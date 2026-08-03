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
local currentTheme = {
    btnSafe    = colors.green,
    btnDanger  = colors.red,
    btnNeutral = colors.lightBlue,
    text       = colors.white,
}

local function drawButton(btn, selected)
    term.setBackgroundColor(selected and colors.white or currentTheme[btn.colorKey])
    term.setTextColor(selected and colors.black or colors.white)
    term.setCursorPos(btn.x, btn.y)
    term.write(string.rep(" ", btn.width))
    term.setCursorPos(btn.x + math.floor((btn.width - #btn.label) / 2), btn.y)
    term.write(btn.label)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
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
local lastRenderedTabs      = {} -- tab bar bounds, same capture pattern as lastRenderedButtons

-- Which of the 3 tabs (see TABS/drawTabBar below) is currently showing.
-- "SVR" is the landing tab: an operator's first question on opening this
-- screen is "is everything OK overall", not "show me every PLC row" -
-- matches aggregateStatus()'s own role as the single system-wide verdict.
local currentTab = "SVR"

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

local function trendGlyph(prev, cur, eps)
    if prev == nil or cur == nil then
        return " "
    end
    local d = cur - prev
    if d > eps then
        return "^"
    elseif d < -eps then
        return "v"
    end
    return "-"
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
-- Tab bar (SVR / PLC / RTU) - row 2, directly under the title. Splitting
-- what used to be one flat screen (5 summary lines + one mixed PLC+RTU
-- table, all fighting for the same rows) into per-category tabs gives each
-- one the whole body of the terminal instead: SVR is the "is everything OK"
-- overview, PLC and RTU are each a dedicated, undiluted table for their own
-- role - and an RTU (no trip/protective authority - see plcBucket() above)
-- no longer visually competes with real PLCs for table rows on a small
-- terminal even though it's already excluded from the PLC count/status.
-- ---------------------------------------------------------------------------
local TABS = { "SVR", "PLC", "RTU" }

local function drawTabBar(w)
    lastRenderedTabs = {}
    local x = 1
    for _, tab in ipairs(TABS) do
        local label = " " .. tab .. " "
        if tab == currentTab then
            term.setBackgroundColor(colors.white)
            term.setTextColor(colors.black)
        else
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.lightGray)
        end
        term.setCursorPos(x, 2)
        term.write(label)
        lastRenderedTabs[#lastRenderedTabs + 1] = { id = tab, x = x, y = 2, width = #label }
        x = x + #label
    end
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    if x <= w then
        term.write(string.rep(" ", w - x + 1))
    end
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
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

    local status = aggregateStatus()
    term.setCursorPos(1, 3)
    term.setBackgroundColor(STATUS_COLOR[status] or colors.gray)
    term.setTextColor(colors.black)
    local headerLine = (" SYSTEM: %s  (%d PLC%s, %d offline) "):format(
        status, plcCount, plcCount == 1 and "" or "s", offlineCount)
    term.write(headerLine .. string.rep(" ", math.max(0, w - #headerLine)))
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)

    term.setCursorPos(1, 4)
    term.write(("HB TX: %s ago (%ds cadence)"):format(fmtAge(os.epoch("utc") - lastHeartbeatSentAt), NET.HEARTBEAT_INTERVAL_S))

    -- Surfaces secnetOpen (tracked for tryOpenSecnet's retry logic - see
    -- module state above) directly to the operator: a Supervisor stuck
    -- unable to open its own modem is the single worst failure mode in
    -- this whole project (every PLC fail-safe SCRAMs once it can't hear a
    -- heartbeat), so it deserves to be visible here, not just in the log.
    term.setCursorPos(1, 5)
    term.write("MODEM: ")
    if secnetOpen then
        term.setTextColor(colors.green)
        term.write("OPEN")
    else
        term.setTextColor(colors.red)
        term.write("NOT OPEN (retrying)")
    end
    term.setTextColor(colors.white)

    term.setCursorPos(1, 6)
    term.write("CMD: " .. formatCommandStatus(lastCommandRef))

    term.setCursorPos(1, 7)
    if lastScramGlobal then
        local scramPlc = plcs[lastScramGlobal.plcId]
        local epgNote = (scramPlc and scramPlc.epgActive) and " (EPG ACTIVE)" or ""
        term.write(("LAST SCRAM: #%d %s ago - %s (%s)%s"):format(
            lastScramGlobal.plcId, fmtAge(os.epoch("utc") - lastScramGlobal.receivedAt),
            tostring(lastScramGlobal.reason),
            lastScramGlobal.actuationConfirmed and "CONFIRMED" or "UNCONFIRMED",
            epgNote))
    else
        term.write("LAST SCRAM: none yet")
    end

    term.setCursorPos(1, 8)
    if lotoCount > 0 then
        term.setTextColor(colors.red)
        term.write(("LOTO: %d reactor%s tagged"):format(lotoCount, lotoCount == 1 and "" or "s"))
        term.setTextColor(colors.white)
    else
        term.write("LOTO: none active")
    end
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

    local tableTop = 3
    if h < tableTop then
        lastRenderedRows = {}
        lastRenderedTableTop = nil
        return -- terminal too short to show the table at all
    end
    -- "ID  " (4 chars, matches "#%-3d") + 2 glyph columns (LOTO "L", Testing
    -- "T", 1 char each) + "STATE" (10 chars, matches "%-10s") = 16 chars
    -- before EAL, matching the per-row writes below exactly.
    term.setCursorPos(1, tableTop)
    term.write("ID    STATE     EAL  DMG%   T-K   CLT%  WST%  BURN  AGE")

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

    for i = 1, shown do
        local plcId = rows[i]
        local rec = plcs[plcId]
        local s, prev = rec.state, rec.prevState
        local online = isOnline(rec)

        lastRenderedRows[i] = plcId

        term.setCursorPos(1, tableTop + i)
        if plcId == selectedPlcId then
            -- Selection highlight: inverted colors on the ID cell only,
            -- so the operator can see the current click-target at a glance.
            term.setBackgroundColor(colors.white)
            term.setTextColor(colors.black)
        else
            term.setTextColor(online and colors.white or colors.orange)
        end
        -- "R" prefix instead of "#" for an RTU row - kept even though each
        -- tab is now role-pure, so a row's own identity stays legible if
        -- it's ever screenshotted/logged out of context.
        term.write(string.format("%s%-3d", rec.role == "RTU" and "R" or "#", plcId))
        term.setBackgroundColor(colors.black)

        -- LOTO / Testing glyphs: last-known value shown regardless of
        -- `online`, same as every other data column (stale-but-last-known
        -- beats blank while offline, per this project's stated philosophy).
        term.setTextColor(colors.red)
        term.write(rec.loto and "L" or " ")
        term.setTextColor(colors.yellow)
        term.write(rec.testingMode and "T" or " ")

        if s.plantState == STATES.SCRAMMED then
            term.setTextColor(colors.red)
        elseif s.plantState == STATES.ANOMALY then
            term.setTextColor(colors.orange)
        else
            term.setTextColor(online and colors.white or colors.orange)
        end
        local stateText = s.plantState
        if s.plantState == STATES.NORMAL and rec.operatingMode then
            stateText = OPERATING_MODE_ABBR[rec.operatingMode] or s.plantState
        end
        term.write(string.format("%-10s", tostring(stateText or "?")))

        local ealColor = rec.activeEAL and TIER_BY_ID[rec.activeEAL] and colors[TIER_BY_ID[rec.activeEAL].color]
        term.setTextColor(ealColor or (online and colors.white or colors.orange))
        term.write(string.format("%-5s", rec.activeEAL or "--"))

        term.setTextColor(online and colors.white or colors.orange)
        term.write(string.format("%5.1f%s ", s.damagePct or 0, trendGlyph(prev and prev.damagePct, s.damagePct, TREND_EPS.damagePct)))
        term.write(string.format("%5.0f%s ", s.coreTempK or 0, trendGlyph(prev and prev.coreTempK, s.coreTempK, TREND_EPS.coreTempK)))
        term.write(string.format("%4.1f%s ", s.coolantPct or 0, trendGlyph(prev and prev.coolantPct, s.coolantPct, TREND_EPS.coolantPct)))
        term.write(string.format("%4.1f%s ", s.wastePct or 0, trendGlyph(prev and prev.wastePct, s.wastePct, TREND_EPS.wastePct)))
        term.write(string.format("%4.0f ", s.burnRateMbT or 0))

        if online then
            term.write(fmtAge(os.epoch("utc") - rec.lastTelemetryTs))
        else
            term.setTextColor(colors.orange)
            term.write("OFFLINE")
        end
    end
    term.setTextColor(colors.white)

    if #rows > shown then
        term.setCursorPos(1, tableTop + shown + 1)
        term.setTextColor(colors.gray)
        term.write(("+%d more (all lower severity)"):format(#rows - shown))
        term.setTextColor(colors.white)
    end
end

-- Full clear + redraw-everything each tick: simplest, most robust choice
-- at a 1Hz cadence on a small CC terminal - no differential rendering.
-- Rows longer than the terminal width are simply clipped by term.write
-- itself (CC terminals don't auto-wrap on write), which is why there is no
-- separate column-dropping logic here: on a narrow terminal the trailing
-- columns (burn rate, age) are what naturally disappear first.
local function redraw()
    local w, h = term.getSize()

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()

    term.setCursorPos(1, 1)
    term.write(("FCS-10 SUPERVISOR #%d"):format(os.getComputerID()))

    drawTabBar(w)

    if currentTab == "PLC" then
        drawRoleTab(h, function(rec) return rec.role ~= "RTU" end, true)
    elseif currentTab == "RTU" then
        drawRoleTab(h, function(rec) return rec.role == "RTU" end, false)
    else
        drawSvrTab(w)
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

-- ---------------------------------------------------------------------------
-- Main event loop - strictly non-blocking, same pattern as plc.lua: a
-- single os.pullEvent() wait per iteration, os.startTimer()-driven
-- cadences, one outer per-iteration pcall as the last line of defense.
-- ---------------------------------------------------------------------------
local function main()
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
                    local tabBtn = hitTestButtons(lastRenderedTabs, x, y)
                    if tabBtn then
                        -- Selection is cleared on tab switch rather than
                        -- carried across: a stale selectedPlcId pointing at
                        -- a row from the tab just left (or one that isn't
                        -- even shown on the new tab) is more confusing than
                        -- just asking the operator to reselect.
                        currentTab = tabBtn.id
                        selectedPlcId = nil
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
                            selectedPlcId = lastRenderedRows[y - lastRenderedTableTop]
                        end
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
