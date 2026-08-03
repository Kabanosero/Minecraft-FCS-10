-- test/cmd_test.lua
-- FCS-10 / ATM-PCS :: temporary CLI test tool
--
-- Sends a signed COMMAND to a chosen PLC and waits for its ACK. This is a
-- throwaway manual test harness, NOT a production node script - blocking
-- io.read()/os.pullEvent() calls are fine here, unlike plc.lua/supervisor.lua.
--
-- Exists because sendBurnRateCommand/sendScramCommand live inside
-- supervisor.lua's own running environment and aren't reachable from a
-- separate shell process (CC:Tweaked runs each program in its own
-- environment) - this tool plays the Supervisor's role for one command at
-- a time, driven by a human at the keyboard, so the COMMAND/ACK exchange
-- can be tested directly against a running plc.lua.

local okCfg, config = pcall(dofile, "/lib/config.lua")
if not okCfg then
    print("[TEST] FATAL: failed to load /lib/config.lua: " .. tostring(config))
    return
end

local okMd5, md5 = pcall(dofile, "/lib/md5.lua")
if not okMd5 then
    print("[TEST] FATAL: failed to load /lib/md5.lua: " .. tostring(md5))
    return
end

local okSn, secnet = pcall(dofile, "/lib/secnet.lua")
if not okSn then
    print("[TEST] FATAL: failed to load /lib/secnet.lua: " .. tostring(secnet))
    return
end

local NET = config.NETWORK
local MSG = config.NETWORK.MSG_TYPE

local okOpen, openErr = secnet.open(nil, NET.PROTOCOL_SUPERVISOR)
if not okOpen then
    print("[TEST] WARNING: secnet.open failed (" .. tostring(openErr) .. ") - sends will fail")
end

local ACK_WAIT_S = 2
local nextRequestIdCounter = 0

local function nextRequestId()
    nextRequestIdCounter = nextRequestIdCounter + 1
    return nextRequestIdCounter
end

-- Waits up to ACK_WAIT_S seconds for an ACK whose requestId matches,
-- discarding anything else that arrives meanwhile. A live PLC's own
-- TELEMETRY/HEARTBEAT/SCRAM broadcasts are ALSO tagged PROTOCOL_SUPERVISOR
-- (the "tag = audience's protocol" convention), same as the ACK we're
-- waiting for - a plain secnet.receive(timeout, protocol) would return on
-- the first TELEMETRY packet instead of the actual ACK, since it doesn't
-- filter by message type. This loop keeps the SAME timer running and only
-- returns on a matching ACK or on timeout.
local function waitForAck(requestId)
    local timer = os.startTimer(ACK_WAIT_S)
    while true do
        local event, p1, p2 = os.pullEvent()
        if event == "rednet_message" then
            local fromId, msgType, payload = secnet.handleEvent(p1, p2)
            if fromId and msgType == MSG.ACK and type(payload) == "table" and payload.requestId == requestId then
                return payload
            end
            -- anything else (a different ACK, TELEMETRY, HEARTBEAT, SCRAM,
            -- or a rejected/invalid packet) - ignore, keep waiting
        elseif event == "timer" and p1 == timer then
            return nil
        end
    end
end

local function promptLine(label)
    io.write(label)
    return io.read()
end

local function promptNumber(label)
    local line = promptLine(label)
    return tonumber(line)
end

local function sendCommand(plcId, payload)
    print(("[TEST] sending %s (requestId=%d) to #%d..."):format(payload.action, payload.requestId, plcId))
    local ok, err = secnet.send(plcId, NET.PROTOCOL_PLC, MSG.COMMAND, payload)
    if not ok then
        print("[TEST] send failed: " .. tostring(err))
        return
    end

    print(("[TEST] waiting up to %ds for ACK..."):format(ACK_WAIT_S))
    local ack = waitForAck(payload.requestId)
    if not ack then
        print("[TEST] TIMEOUT - no ACK received")
    elseif ack.accepted then
        print("[TEST] ACK: accepted")
    else
        print("[TEST] ACK: rejected (reason=" .. tostring(ack.reason) .. ")")
    end
end

local function runScram()
    local plcId = promptNumber("Target PLC ID: ")
    if type(plcId) ~= "number" then
        print("[TEST] invalid PLC id")
        return
    end
    sendCommand(plcId, { action = "SCRAM", requestId = nextRequestId() })
end

local function runSetBurnRate()
    local plcId = promptNumber("Target PLC ID: ")
    if type(plcId) ~= "number" then
        print("[TEST] invalid PLC id")
        return
    end
    local rate = promptNumber("Target burn rate (mB/t): ")
    if type(rate) ~= "number" then
        print("[TEST] invalid burn rate")
        return
    end
    sendCommand(plcId, { action = "SET_BURN_RATE", value = rate, requestId = nextRequestId() })
end

print("FCS-10 command test tool.")
while true do
    print("")
    print("1) SCRAM")
    print("2) SET_BURN_RATE")
    print("q) quit")
    local choice = promptLine("> ")

    if choice == "q" or choice == "Q" then
        break
    elseif choice == "1" then
        runScram()
    elseif choice == "2" then
        runSetBurnRate()
    else
        print("[TEST] unrecognized option")
    end
end
