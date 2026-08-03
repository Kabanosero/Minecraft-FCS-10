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

-- Forward-declared (defined below unbindReactor, which needs to call it)
-- so it stays a proper local rather than leaking into _G.
local broadcastTelemetry

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

    print("[PLC] reactor peripheral lost: " .. tostring(reason))

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
        print("[PLC] reactor bound on side " .. side)
    end
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
        burnOk, scramOk = ok1, ok2
        if not (ok1 and ok2) then
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

    print(("[PLC] SCRAM (%s): %s"):format(
        lastScramActuationConfirmed and "actuation confirmed" or "**ACTUATION UNCONFIRMED**",
        reason))

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
        ts    = os.epoch("ingame"),
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
            reactorState.lastUpdate = os.epoch("ingame")
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
                            print(("[PLC] AUTO-RUNBACK: burn rate reduced to %.1f mB/t"):format(newRate))
                        end
                    end
                elseif inRunback and recovered then
                    inRunback = false
                    print("[PLC] AUTO-RUNBACK cleared - conditions recovered")
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

    local ok, err = broadcastTelemetry()
    if not ok then
        print("[PLC] telemetry broadcast failed: " .. tostring(err))
    end
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
        lotoTag = { reason = payload.reason, appliedAt = os.epoch("ingame"), appliedBy = fromId }
        print(("[PLC] LOTO TAG APPLIED by #%d: %s"):format(fromId, payload.reason))
        broadcastTelemetry() -- immediate out-of-cycle update, same pattern as unbindReactor()

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
        print(("[PLC] LOTO TAG REMOVED by #%d"):format(fromId))
        broadcastTelemetry()

        sendAck(fromId, action, true, nil, requestId)
        return
    end

    if action == "OPEN_STEAM_BYPASS" then
        -- Operator-tier "non-critical valve" - no RBAC gate, no interlocks
        -- (deliberately simple: this is a simulated valve, see header).
        steamBypassOpen = true
        print(("[PLC] Steam bypass OPENED via COMMAND from #%d"):format(fromId))
        broadcastTelemetry()
        sendAck(fromId, action, true, nil, requestId)
        return
    end

    if action == "CLOSE_STEAM_BYPASS" then
        steamBypassOpen = false
        print(("[PLC] Steam bypass CLOSED via COMMAND from #%d"):format(fromId))
        broadcastTelemetry()
        sendAck(fromId, action, true, nil, requestId)
        return
    end

    if action == "ENTER_TESTING" then
        if not checkSupervisorGate(fromId, action, payload, requestId) then
            return
        end
        testingMode = true
        print(("[PLC] TESTING MODE ENTERED by #%d"):format(fromId))
        broadcastTelemetry()
        sendAck(fromId, action, true, nil, requestId)
        return
    end

    if action == "EXIT_TESTING" then
        if not checkSupervisorGate(fromId, action, payload, requestId) then
            return
        end
        testingMode = false
        print(("[PLC] TESTING MODE EXITED by #%d"):format(fromId))
        broadcastTelemetry()
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
    print("[PLC] FCS-10 Core PLC booting on computer #" .. os.getComputerID())

    tryBindReactor(nil)
    if not reactor then
        reactorState.plantState = STATES.ANOMALY
        print("[PLC] WARNING: no " .. REACTOR_TYPE .. " found at startup - LPS running in hardware-absent mode")
    end

    local okOpen, openErr = secnet.open(nil, NET.PROTOCOL_PLC)
    if not okOpen then
        print("[PLC] WARNING: secnet.open failed (" .. tostring(openErr) .. ") - local LPS protection remains fully active")
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
        local event, p1, p2 = os.pullEvent() -- yields every iteration; never a busy-spin

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
            elseif event == "peripheral_detach" then
                if p1 == reactorSide then
                    unbindReactor("peripheral_detach on side " .. tostring(p1))
                end
            end
        end)

        if not ok then
            print("[PLC] event handler error (non-fatal, loop continues): " .. tostring(err))
        end
    end
end

main()
