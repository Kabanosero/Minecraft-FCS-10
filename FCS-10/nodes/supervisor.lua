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
-- SCOPE: this draft is read-only monitoring plus a callable command
-- interface (sendBurnRateCommand/sendScramCommand) - there is no
-- keyboard-driven command menu wired into the terminal loop here.
-- Interactive operator control is a future HMI node's job. Note also that
-- because CC:Tweaked runs each program in its own environment, these two
-- functions are reachable from other code only if that code lives in (or
-- is pulled into) THIS running script - not from a separate concurrent
-- shell/REPL process on the same computer.
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

-- ---------------------------------------------------------------------------
-- Per-PLC record lifecycle
-- ---------------------------------------------------------------------------
local function touchPlc(plcId)
    local rec = plcs[plcId]
    if not rec then
        rec = {
            id                 = plcId,
            firstSeenTs        = os.epoch("ingame"),
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
        }
        plcs[plcId] = rec
    end
    rec.lastSeenTs = os.epoch("ingame")
    return rec
end

-- A PLC counts as online only if TELEMETRY specifically has arrived
-- recently (per the literal requirement) - not just any authenticated
-- packet. lastTelemetryTs starts at 0, so a PLC that has said hello via
-- HEARTBEAT but never sent TELEMETRY correctly reads as offline.
local function isOnline(rec)
    return (os.epoch("ingame") - rec.lastTelemetryTs) < (NET.HEARTBEAT_TIMEOUT_S * 1000)
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
    rec.lastTelemetryTs    = os.epoch("ingame")
    rec.activeEAL          = computeEAL(rec)

    rec.loto            = payload.loto
    rec.steamBypassOpen = payload.steamBypassOpen
    rec.testingMode     = payload.testingMode
    rec.epgActive       = payload.epgActive

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
        receivedAt         = os.epoch("ingame"),
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
    pend.roundTripMs = os.epoch("ingame") - pend.firstSentAt

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
        firstSentAt = os.epoch("ingame"),
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

local function aggregateStatus()
    if next(plcs) == nil then
        return "AWAITING PLC"
    end
    local worst = "NORMAL"
    for _, rec in pairs(plcs) do
        local bucket = plcBucket(rec)
        if BUCKET_RANK[bucket] > BUCKET_RANK[worst] then
            worst = bucket
        end
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

    local plcCount, offlineCount, lotoCount = 0, 0, 0
    for _, rec in pairs(plcs) do
        plcCount = plcCount + 1
        if not isOnline(rec) then
            offlineCount = offlineCount + 1
        end
        if rec.loto then
            lotoCount = lotoCount + 1
        end
    end

    local status = aggregateStatus()
    term.setCursorPos(1, 2)
    term.setBackgroundColor(STATUS_COLOR[status] or colors.gray)
    term.setTextColor(colors.black)
    local headerLine = (" SYSTEM: %s  (%d PLC%s, %d offline) "):format(
        status, plcCount, plcCount == 1 and "" or "s", offlineCount)
    term.write(headerLine .. string.rep(" ", math.max(0, w - #headerLine)))
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)

    term.setCursorPos(1, 3)
    term.write(("HB TX: %s ago (%ds cadence)"):format(fmtAge(os.epoch("ingame") - lastHeartbeatSentAt), NET.HEARTBEAT_INTERVAL_S))

    term.setCursorPos(1, 4)
    term.write("CMD: " .. formatCommandStatus(lastCommandRef))

    term.setCursorPos(1, 5)
    if lastScramGlobal then
        local scramPlc = plcs[lastScramGlobal.plcId]
        local epgNote = (scramPlc and scramPlc.epgActive) and " (EPG ACTIVE)" or ""
        term.write(("LAST SCRAM: #%d %s ago - %s (%s)%s"):format(
            lastScramGlobal.plcId, fmtAge(os.epoch("ingame") - lastScramGlobal.receivedAt),
            tostring(lastScramGlobal.reason),
            lastScramGlobal.actuationConfirmed and "CONFIRMED" or "UNCONFIRMED",
            epgNote))
    else
        term.write("LAST SCRAM: none yet")
    end

    term.setCursorPos(1, 6)
    if lotoCount > 0 then
        term.setTextColor(colors.red)
        term.write(("LOTO: %d reactor%s tagged"):format(lotoCount, lotoCount == 1 and "" or "s"))
        term.setTextColor(colors.white)
    else
        term.write("LOTO: none active")
    end

    local tableTop = 8
    if h < tableTop then
        return -- terminal too short to show the PLC table at all
    end
    -- "ID  " (4 chars, matches "#%-3d") + 2 glyph columns (LOTO "L", Testing
    -- "T", 1 char each) + "STATE" (10 chars, matches "%-10s") = 16 chars
    -- before EAL, matching the per-row writes below exactly.
    term.setCursorPos(1, tableTop)
    term.write("ID    STATE     EAL  DMG%   T-K   CLT%  WST%  BURN  AGE")

    -- Sort worst-first so that on a truncated screen the PLCs most worth
    -- an operator's attention are always the ones still visible.
    local rows = {}
    for plcId in pairs(plcs) do
        rows[#rows + 1] = plcId
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

    local maxRows = math.max(0, h - tableTop - 1) -- leave 1 line for a possible footer
    local shown = math.min(#rows, maxRows)

    for i = 1, shown do
        local plcId = rows[i]
        local rec = plcs[plcId]
        local s, prev = rec.state, rec.prevState
        local online = isOnline(rec)

        term.setCursorPos(1, tableTop + i)
        term.setTextColor(online and colors.white or colors.orange)
        term.write(string.format("#%-3d", plcId))

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
            term.write(fmtAge(os.epoch("ingame") - rec.lastTelemetryTs))
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

    local okOpen, openErr = secnet.open(nil, NET.PROTOCOL_SUPERVISOR)
    if not okOpen then
        print("[SUP] WARNING: secnet.open failed (" .. tostring(openErr) .. ")")
    end

    safeRedraw() -- immediate first paint, don't wait a full cadence

    local hbTimerId = os.startTimer(NET.HEARTBEAT_INTERVAL_S)
    local uiTimerId = os.startTimer(NET.TELEMETRY_INTERVAL_S)

    while true do
        local event, p1, p2 = os.pullEvent() -- yields every iteration; never a busy-spin

        local ok, err = pcall(function()
            if event == "timer" then
                if p1 == hbTimerId then
                    secnet.broadcast(NET.PROTOCOL_PLC, MSG.HEARTBEAT, {}) -- audience's protocol, not PROTOCOL_SUPERVISOR
                    lastHeartbeatSentAt = os.epoch("ingame")
                    hbTimerId = os.startTimer(NET.HEARTBEAT_INTERVAL_S)
                    safeRedraw()
                elseif p1 == uiTimerId then
                    safeRedraw()
                    uiTimerId = os.startTimer(NET.TELEMETRY_INTERVAL_S)
                else
                    onCommandTimer(p1)
                    safeRedraw()
                end
            elseif event == "rednet_message" then
                local fromId, msgType, payload = secnet.handleEvent(p1, p2)
                if fromId then
                    touchPlc(fromId)
                    if msgType == MSG.TELEMETRY then
                        onTelemetry(fromId, payload)
                        safeRedraw()
                    elseif msgType == MSG.SCRAM then
                        onScram(fromId, payload)
                        safeRedraw()
                    elseif msgType == MSG.ACK then
                        onAck(fromId, payload)
                        safeRedraw()
                    elseif msgType == MSG.HEARTBEAT then
                        safeRedraw()
                    end
                end
                -- rejections (nil, reason) from secnet.handleEvent are not
                -- errors - ignore and keep the loop running.
            end
        end)

        if not ok then
            print("[SUP] event handler error (non-fatal, loop continues): " .. tostring(err))
        end
    end
end

main()
