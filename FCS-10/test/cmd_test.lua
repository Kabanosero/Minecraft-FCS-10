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
--
-- Also covers RBAC/LOTO/Operating-Mode actions (APPLY_TAG/REMOVE_TAG,
-- OPEN/CLOSE_STEAM_BYPASS, ENTER/EXIT_TESTING) - see nodes/plc.lua's
-- COMMAND contract doc-comment for the full action/payload reference.

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

-- Masked input for the Shift Supervisor key, via CC:Tweaked's global
-- read("*") - unlike promptLine's plain io.read(), this doesn't echo the
-- typed characters back to the terminal.
local function promptSecret(label)
    io.write(label)
    return read("*")
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
    local supervisorKey = promptSecret("Shift Supervisor key: ")
    if type(supervisorKey) ~= "string" or supervisorKey == "" then
        print("[TEST] invalid supervisor key")
        return
    end
    sendCommand(plcId, { action = "SET_BURN_RATE", value = rate, supervisorKey = supervisorKey, requestId = nextRequestId() })
end

local function runApplyTag()
    local plcId = promptNumber("Target PLC ID: ")
    if type(plcId) ~= "number" then
        print("[TEST] invalid PLC id")
        return
    end
    local reason = promptLine("LOTO reason: ")
    if type(reason) ~= "string" or reason == "" then
        print("[TEST] invalid reason")
        return
    end
    local supervisorKey = promptSecret("Shift Supervisor key: ")
    if type(supervisorKey) ~= "string" or supervisorKey == "" then
        print("[TEST] invalid supervisor key")
        return
    end
    sendCommand(plcId, { action = "APPLY_TAG", reason = reason, supervisorKey = supervisorKey, requestId = nextRequestId() })
end

local function runRemoveTag()
    local plcId = promptNumber("Target PLC ID: ")
    if type(plcId) ~= "number" then
        print("[TEST] invalid PLC id")
        return
    end
    local supervisorKey = promptSecret("Shift Supervisor key: ")
    if type(supervisorKey) ~= "string" or supervisorKey == "" then
        print("[TEST] invalid supervisor key")
        return
    end
    sendCommand(plcId, { action = "REMOVE_TAG", supervisorKey = supervisorKey, requestId = nextRequestId() })
end

local function runOpenBypass()
    local plcId = promptNumber("Target PLC ID: ")
    if type(plcId) ~= "number" then
        print("[TEST] invalid PLC id")
        return
    end
    sendCommand(plcId, { action = "OPEN_STEAM_BYPASS", requestId = nextRequestId() })
end

local function runCloseBypass()
    local plcId = promptNumber("Target PLC ID: ")
    if type(plcId) ~= "number" then
        print("[TEST] invalid PLC id")
        return
    end
    sendCommand(plcId, { action = "CLOSE_STEAM_BYPASS", requestId = nextRequestId() })
end

local function runEnterTesting()
    local plcId = promptNumber("Target PLC ID: ")
    if type(plcId) ~= "number" then
        print("[TEST] invalid PLC id")
        return
    end
    local supervisorKey = promptSecret("Shift Supervisor key: ")
    if type(supervisorKey) ~= "string" or supervisorKey == "" then
        print("[TEST] invalid supervisor key")
        return
    end
    sendCommand(plcId, { action = "ENTER_TESTING", supervisorKey = supervisorKey, requestId = nextRequestId() })
end

local function runExitTesting()
    local plcId = promptNumber("Target PLC ID: ")
    if type(plcId) ~= "number" then
        print("[TEST] invalid PLC id")
        return
    end
    local supervisorKey = promptSecret("Shift Supervisor key: ")
    if type(supervisorKey) ~= "string" or supervisorKey == "" then
        print("[TEST] invalid supervisor key")
        return
    end
    sendCommand(plcId, { action = "EXIT_TESTING", supervisorKey = supervisorKey, requestId = nextRequestId() })
end

print("FCS-10 command test tool.")
while true do
    print("")
    print("1) SCRAM")
    print("2) SET_BURN_RATE")
    print("3) APPLY TAG (LOTO)")
    print("4) REMOVE TAG (LOTO)")
    print("5) OPEN STEAM BYPASS")
    print("6) CLOSE STEAM BYPASS")
    print("7) ENTER TESTING MODE")
    print("8) EXIT TESTING MODE")
    print("q) quit")
    local choice = promptLine("> ")

    if choice == "q" or choice == "Q" then
        break
    elseif choice == "1" then
        runScram()
    elseif choice == "2" then
        runSetBurnRate()
    elseif choice == "3" then
        runApplyTag()
    elseif choice == "4" then
        runRemoveTag()
    elseif choice == "5" then
        runOpenBypass()
    elseif choice == "6" then
        runCloseBypass()
    elseif choice == "7" then
        runEnterTesting()
    elseif choice == "8" then
        runExitTesting()
    else
        print("[TEST] unrecognized option")
    end
end
