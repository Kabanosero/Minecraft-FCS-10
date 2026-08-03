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

    print("[RTU] reactor peripheral lost: " .. tostring(reason))

    -- Immediate out-of-cycle broadcast, same reasoning as plc.lua: the
    -- Supervisor should learn about hardware loss as fast as possible
    -- rather than waiting for the next scheduled tick.
    secnet.broadcast(NET.PROTOCOL_SUPERVISOR, MSG.TELEMETRY, {
        state             = rtuState,
        peripheralPresent = peripheralPresent,
        rtuId             = os.getComputerID(),
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
        print("[RTU] reactor bound on side " .. side)
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
            rtuState.lastUpdate = os.epoch("ingame")
            rtuState.seq        = rtuState.seq + 1
        end
    else
        tryBindReactor(nil) -- opportunistic retry; "peripheral" event handles the common case
    end

    local ok, err = secnet.broadcast(NET.PROTOCOL_SUPERVISOR, MSG.TELEMETRY, {
        state             = rtuState,
        peripheralPresent = peripheralPresent,
        rtuId             = os.getComputerID(),
    })
    if not ok then
        print("[RTU] telemetry broadcast failed: " .. tostring(err))
    end
end

-- ===========================================================================
-- Main event loop - strictly non-blocking: a single os.pullEvent() wait per
-- iteration, two os.startTimer()-driven cadences (no watchdog - see header),
-- never sleep(), never an un-yielded while true.
-- ===========================================================================
local function main()
    print("[RTU] FCS-10 Zone RTU booting on computer #" .. os.getComputerID())

    tryBindReactor(nil)
    if not reactor then
        rtuState.plantState = STATES.ANOMALY
        print("[RTU] WARNING: no " .. REACTOR_TYPE .. " found at startup - running in hardware-absent mode")
    end

    local okOpen, openErr = secnet.open(nil, NET.PROTOCOL_RTU)
    if not okOpen then
        print("[RTU] WARNING: secnet.open failed (" .. tostring(openErr) .. ") - telemetry will not reach the network")
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
        local event, p1, p2 = os.pullEvent() -- yields every iteration; never a busy-spin

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
            elseif event == "peripheral_detach" then
                if p1 == reactorSide then
                    unbindReactor("peripheral_detach on side " .. tostring(p1))
                end
            end
        end)

        if not ok then
            print("[RTU] event handler error (non-fatal, loop continues): " .. tostring(err))
        end
    end
end

main()
