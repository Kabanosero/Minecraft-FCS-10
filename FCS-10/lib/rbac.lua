-- lib/rbac.lua
-- FCS-10 / ATM-PCS :: Role-Based Access Control (IAEA SSG-76 aligned)
--
-- Provides the Shift Supervisor key check consumed by nodes/plc.lua to gate
-- reactivity manipulations (SET_BURN_RATE) and LOTO tag apply/remove behind
-- Shift Supervisor clearance. Operator-tier actions (viewing telemetry,
-- SCRAM, operating non-critical valves like the steam bypass) need no key
-- at all and never touch this module.
--
-- SCOPE: like lib/secnet.lua's network secret, this is ONE shared Shift
-- Supervisor passphrase known by every legitimate shift supervisor, not a
-- per-individual credential - it proves "the person issuing this command
-- knows the Shift Supervisor passphrase," not "this specific person is
-- Alice." Attributing actions to a named individual (an audit trail) is out
-- of scope for this draft, the same conscious v1 limitation lib/secnet.lua
-- already documents for node identity.
--
-- This is a SEPARATE secret from lib/secnet.lua's network HMAC secret, for
-- a SEPARATE purpose: the network secret proves "this packet wasn't forged
-- by an outside rogue computer" (transport authenticity, checked by every
-- node before a message is even looked at). This key proves "the human
-- issuing this specific authenticated command holds Shift Supervisor
-- clearance" (application-level authorization, checked only by plc.lua,
-- only for the actions that need it). The two must never be conflated.
--
-- Only nodes/plc.lua ever dofiles this module, once, at boot - unlike
-- lib/secnet.lua, no _G self-memoization is needed here (that pattern
-- exists in secnet.lua to keep its seq counter/replay cache a single
-- instance across multiple dofile call sites on one node; this module has
-- no such multi-call-site risk to guard against).

local config = dofile("/lib/config.lua")

local rbac = {}

local cachedKey = nil

-- Reads config.SECURITY.SUPERVISOR_KEY_FILE from local disk if present,
-- else falls back to DEV_DEFAULT_SUPERVISOR_KEY (loudly, so a node silently
-- running on the placeholder is visible at boot). Mirrors lib/secnet.lua's
-- loadSecret() exactly, for a different secret.
local function loadSupervisorKey()
    if cachedKey then
        return cachedKey
    end

    local path = config.SECURITY.SUPERVISOR_KEY_FILE
    if fs.exists(path) and not fs.isDir(path) then
        local h = fs.open(path, "r")
        local contents = h.readAll()
        h.close()
        contents = contents:gsub("%s+$", "") -- trailing newline/whitespace must not differ node-to-node
        if #contents > 0 then
            cachedKey = contents
            return cachedKey
        end
    end

    print("[rbac] WARNING: " .. path .. " not found, using DEV_DEFAULT_SUPERVISOR_KEY")
    cachedKey = config.SECURITY.DEV_DEFAULT_SUPERVISOR_KEY
    return cachedKey
end

-- Checks a typed key (from a COMMAND payload's `supervisorKey` field)
-- against this node's local reference copy. Plain string equality, NOT
-- constant-time (contrast lib/secnet.lua's secureCompare): this check only
-- ever runs on a payload field that already passed secnet's HMAC
-- verification, so an attacker mounting a timing attack here would need to
-- already hold the network secret - at which point there are bigger holes
-- to exploit than this comparison. A deliberate simplification, not an
-- oversight.
function rbac.checkSupervisorKey(typedKey)
    if type(typedKey) ~= "string" then
        return false
    end
    return typedKey == loadSupervisorKey()
end

return rbac
