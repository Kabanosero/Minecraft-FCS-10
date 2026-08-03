-- lib/secnet.lua
-- Authenticated rednet transport for FCS-10 / ATM-PCS.
--
-- Wraps rednet.send/rednet.broadcast/rednet_message events with HMAC-MD5
-- signing so a rogue computer holding no shared secret cannot spoof
-- PLC/RTU/Supervisor/HMI traffic. This module never sleeps and never
-- blocks longer than a single os.pullEvent() wait.
--
-- SCOPE NOTE: this uses one network-wide shared secret (config.SECURITY).
-- That proves "produced by someone holding the secret" - it stops the
-- stated threat (an outside rogue computer) but does NOT stop one
-- legitimate secret-holding node from forging another node's identity.
-- Closing that would need per-node keys derived from the master secret;
-- deliberately out of scope for this draft.
--
-- WIRE FORMAT / WHY WE SIGN A STRING, NOT THE LIVE TABLE:
-- rednet.send() hands your message table across the Lua<->Java peripheral
-- call boundary as a live value (no pre-serialization), and the receiving
-- computer gets back a freshly reconstructed table - not guaranteed to
-- have the same pairs() iteration order as the sender's original, and
-- textutils.serialize() iterates string-keyed fields with plain unsorted
-- pairs(). So two logically-identical envelope tables could serialize to
-- different strings on sender vs. receiver, and signing the table would
-- make legitimate packets fail verification nondeterministically.
-- Fix: the sender serializes the envelope to a string ONCE, signs that
-- string, and transmits {d = serializedString, h = hexHmac}. Strings
-- survive rednet transport byte-for-byte, so the receiver verifies the
-- HMAC over the exact bytes it received and only unserializes afterward.
--
-- ANTI-REPLAY: keyed on (envelope.ts, envelope.seq) rather than a bare
-- monotonic counter. os.epoch("ingame") is ms since world creation, read
-- identically by every computer in the world and unaffected by a single
-- node rebooting (unlike a local counter, which would reset to 1 and
-- permanently lock that node out once a peer's high-water mark is past
-- it). seq is only a same-millisecond tie-breaker.
--
-- MODULE CACHING: unlike require(), dofile() re-executes a file's top
-- level on every call. secnet needs its seq counter / replay cache / secret
-- to stay a single instance for the node's whole lifetime, so this file
-- memoizes itself in _G on first load - dofile-ing it again from another
-- file on the same node returns the same table instead of a divergent copy.
if _G.__fcs10_secnet then
    return _G.__fcs10_secnet
end

local config = dofile("/lib/config.lua")
local md5    = dofile("/lib/md5.lua")

local band, bor, bxor = bit32.band, bit32.bor, bit32.bxor

local secnet = {}

-- module-local state: exactly one instance per node lifetime (see guard above)
local cachedSecret = nil
local mySeq = 0
local lastSeen = {}   -- [envelope.from] = { ts = <ms>, seq = <n> }

-- ---------------------------------------------------------------------------
-- Secret provisioning
-- ---------------------------------------------------------------------------
-- Reads config.SECURITY.SECRET_FILE from local disk if present, else falls
-- back to the dev placeholder (loudly, so a node silently running on the
-- placeholder is visible at boot). Local disk only - never transmitted.
local function loadSecret()
    if cachedSecret then
        return cachedSecret
    end

    local path = config.SECURITY.SECRET_FILE
    if fs.exists(path) and not fs.isDir(path) then
        local h = fs.open(path, "r")
        local contents = h.readAll()
        h.close()
        contents = contents:gsub("%s+$", "") -- trailing newline/whitespace must not differ node-to-node
        if #contents > 0 then
            cachedSecret = contents
            return cachedSecret
        end
    end

    print("[secnet] WARNING: " .. path .. " not found, using DEV_DEFAULT_SECRET")
    cachedSecret = config.SECURITY.DEV_DEFAULT_SECRET
    return cachedSecret
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------
-- Constant-time comparison of two equal-length hex HMACs. Length itself
-- isn't secret (always 32 hex chars for a locally-computed expected value),
-- only the byte content needs a branchless full scan.
local function secureCompare(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        return false
    end
    if #a ~= #b then
        return false
    end
    local diff = 0
    for i = 1, #a do
        diff = bor(diff, bxor(string.byte(a, i), string.byte(b, i)))
    end
    return diff == 0
end

local function sign(str)
    return md5.hmacHex(loadSecret(), str)
end

local function buildWireMessage(msgType, payload)
    mySeq = mySeq + 1
    local envelope = {
        v       = 1,
        t       = msgType,
        from    = os.getComputerID(),
        ts      = os.epoch("ingame"),
        seq     = mySeq,
        payload = payload,
    }
    local d = textutils.serialize(envelope)
    return { d = d, h = sign(d) }
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
-- Opens rednet on `side` (or the first attached modem if side is nil) and,
-- if `protocol` is given, hosts under it as `hostname` (default
-- "node-<id>"). Call once at program start. Returns true, or false + reason.
function secnet.open(side, protocol, hostname)
    if not side then
        local modem = peripheral.find("modem")
        if not modem then
            return false, "no-modem"
        end
        side = peripheral.getName(modem)
    end

    if not rednet.isOpen(side) then
        rednet.open(side)
    end
    if protocol then
        rednet.host(protocol, hostname or ("node-" .. os.getComputerID()))
    end

    loadSecret()
    return true
end

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------
-- Fire-and-forget, exactly like raw rednet: true means a transmit was
-- issued on an open modem, never that the recipient received it. `protocol`
-- is always explicit (never defaulted from open()'s hosted protocol) since
-- a hub node like the Supervisor must address several different protocols.
-- App-level delivery assurance (ACK/retry) is a layer above secnet - see
-- config.NETWORK.COMMAND_ACK_TIMEOUT_S / COMMAND_RETRY_COUNT.
function secnet.send(recipientId, protocol, msgType, payload)
    if not rednet.isOpen() then
        return false, "not-open"
    end
    local ok = rednet.send(recipientId, buildWireMessage(msgType, payload), protocol)
    if not ok then
        return false, "send-failed"
    end
    return true
end

-- Signed broadcast (e.g. STATE_BROADCAST, EAL_DECLARE, SCRAM).
function secnet.broadcast(protocol, msgType, payload)
    if not rednet.isOpen() then
        return false, "not-open"
    end
    rednet.broadcast(buildWireMessage(msgType, payload), protocol)
    return true
end

-- ---------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------
local function handleEventInner(senderId, message)
    if type(message) ~= "table" then
        return nil, "malformed"
    end
    if type(message.d) ~= "string" or type(message.h) ~= "string" then
        return nil, "malformed"
    end
    if #message.h ~= 32 then
        return nil, "malformed"
    end

    if not secureCompare(sign(message.d), message.h) then
        return nil, "bad-hmac"
    end

    local ok, envelope = pcall(textutils.unserialize, message.d)
    if not ok or type(envelope) ~= "table" then
        return nil, "malformed"
    end
    if envelope.v ~= 1
        or type(envelope.t) ~= "string"
        or type(envelope.from) ~= "number"
        or type(envelope.ts) ~= "number"
        or type(envelope.seq) ~= "number"
    then
        return nil, "malformed"
    end

    -- The outer rednet senderId is just a number the sender's own script
    -- supplied (see file header) - exactly as spoofable as envelope.from.
    -- Trust decisions key off envelope.from (HMAC-covered); this is a
    -- cheap additional check, not the primary security boundary.
    if envelope.from ~= senderId then
        return nil, "sender-mismatch"
    end

    local last = lastSeen[envelope.from]
    local isNewer = (last == nil)
        or (envelope.ts > last.ts)
        or (envelope.ts == last.ts and envelope.seq > last.seq)
    if not isNewer then
        return nil, "replay"
    end
    lastSeen[envelope.from] = { ts = envelope.ts, seq = envelope.seq }

    return envelope.from, envelope.t, envelope.payload, envelope.seq
end

-- Call this from your own event loop whenever event == "rednet_message"
-- (pass p1, p2 straight through as senderId, message - the `protocol`
-- event arg is not needed for verification, only for the caller's own
-- routing if it listens on more than one protocol at once).
-- Returns (fromId, msgType, payload, seq) on a verified, fresh packet, or
-- (nil, reason) if the packet was rejected - malformed shape, bad
-- signature, sender/from mismatch, or a replayed/duplicate sequence.
-- Rejections are not errors: the caller should just ignore the packet and
-- keep its loop running. Never throws - the whole check runs under pcall
-- so a garbage or hostile packet can't kill the caller's event loop.
function secnet.handleEvent(senderId, message)
    local ok, a, b, c, d = pcall(handleEventInner, senderId, message)
    if not ok then
        return nil, "internal-error"
    end
    return a, b, c, d
end

-- Convenience blocking-with-timeout receive, built on os.startTimer +
-- os.pullEvent (never sleep()).
--
-- WARNING: only for call sites with nothing else to do while waiting (e.g.
-- a startup handshake). Any node with live responsibilities - especially
-- SCRAM-capable PLC/Supervisor nodes - must run its own os.pullEvent()
-- loop calling secnet.handleEvent() inline instead. Nesting inside this
-- function's wait would delay reacting to anything else arriving
-- concurrently (e.g. a SCRAM broadcast) for up to the whole timeout.
function secnet.receive(timeoutS, protocolFilter)
    local timer = os.startTimer(timeoutS or config.NETWORK.REDNET_RECEIVE_TIMEOUT_S)
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "rednet_message" then
            local senderId, message, protocol = p1, p2, p3
            if not protocolFilter or protocol == protocolFilter then
                local fromId, msgType, payload, seq = secnet.handleEvent(senderId, message)
                if fromId then
                    return fromId, msgType, payload, seq
                end
            end
        elseif event == "timer" and p1 == timer then
            return nil, "timeout"
        end
    end
end

_G.__fcs10_secnet = secnet
return secnet
