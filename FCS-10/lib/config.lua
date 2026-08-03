-- lib/config.lua
-- FCS-10 / ATM-PCS :: Single Source of Truth (SSOT)
--
-- Shared network protocol IDs, HMAC security parameters, thermodynamic
-- setpoints, EAL tiers, and default state shapes for every node type
-- (PLC / Zone RTU / Supervisor / HMI).
--
-- Regulatory basis:
--   NUREG-1433 Rev.4  - BWR/4 Standard Technical Specifications (thermal limits)
--   NEI 99-01 Rev.6   - Development of Emergency Action Levels
--   IAEA SSG-76       - Conduct of Operations / plant state definitions
--
-- Mapping note: Mekanism's Fission Reactor does not expose RCS pressure or
-- water level like a real BWR. Its telemetry is: damage% (core structural
-- integrity), core temperature (K), coolant tank %, waste tank %, and burn
-- rate (mB/t). Per project convention, damage% is treated as the primary
-- safety parameter (the closest analog to NUREG-1433's fuel-cladding /
-- safety-limit bands) and core temperature as the secondary parameter.
-- The numeric setpoints below are placeholders sized for a typical ATM10
-- Mekanism reactor build and MUST be re-tuned against the specific
-- reactor's rated capacity (max burn rate, casing count, heat capacity)
-- during commissioning - they are not derived from a real BWR core.

local config = {}

config.VERSION = "1.0.0-draft"

-- ===========================================================================
-- NETWORK / PROTOCOL
-- ===========================================================================
config.NETWORK = {
    -- rednet protocol strings (rednet.open/host/lookup)
    PROTOCOL_PLC        = "fcs10.plc",
    PROTOCOL_RTU         = "fcs10.rtu",
    PROTOCOL_SUPERVISOR  = "fcs10.supervisor",
    PROTOCOL_HMI         = "fcs10.hmi",

    -- app-layer message types carried inside every secnet envelope
    MSG_TYPE = {
        TELEMETRY       = "TELEMETRY",        -- PLC/RTU -> Supervisor periodic data
        HEARTBEAT       = "HEARTBEAT",        -- liveness ping
        COMMAND         = "COMMAND",          -- Supervisor -> PLC actuation command
        ACK             = "ACK",              -- command acknowledgement
        STATE_BROADCAST = "STATE_BROADCAST",  -- Supervisor -> HMI/all, current plant state
        EAL_DECLARE     = "EAL_DECLARE",      -- Supervisor -> all, EAL tier change
        SCRAM           = "SCRAM",            -- highest-priority: unconditional trip
    },

    HEARTBEAT_INTERVAL_S     = 2,
    HEARTBEAT_TIMEOUT_S      = 6,   -- ~3 missed beats -> node considered LOST
    TELEMETRY_INTERVAL_S     = 1,
    COMMAND_ACK_TIMEOUT_S    = 3,
    COMMAND_RETRY_COUNT      = 3,
    REDNET_RECEIVE_TIMEOUT_S = 4,   -- default guard for secnet.receive()
}

-- ===========================================================================
-- SECURITY (HMAC-MD5 packet authentication)
-- ===========================================================================
config.SECURITY = {
    HMAC_ALGO = "HMAC-MD5",

    -- secnet.loadSecret() reads this file from the node's local disk first.
    -- Never transmitted over rednet. Falls back to DEV_DEFAULT_SECRET if
    -- the file doesn't exist (fresh dev computers).
    SECRET_FILE = "/secret.key",

    -- Placeholder only. Every deployed node should have a real /secret.key
    -- written to its local drive before leaving the dev world.
    DEV_DEFAULT_SECRET = "FCS10-DEV-PLACEHOLDER-CHANGE-ME",

    -- Shift Supervisor role-authorization key (RBAC / LOTO gate) - a
    -- SEPARATE secret from SECRET_FILE above, for a separate purpose: this
    -- proves "whoever typed this command holds the Shift Supervisor role,"
    -- not "this packet came from a trusted node" (that's still SECRET_FILE's
    -- job, checked first, at the transport layer, before a COMMAND handler
    -- ever runs). See lib/rbac.lua. Only nodes/plc.lua ever loads/checks
    -- this; never transmitted except as a plaintext field inside an
    -- already-HMAC-authenticated COMMAND payload.
    SUPERVISOR_KEY_FILE = "/supervisor.key",

    -- Placeholder only, same caveat as DEV_DEFAULT_SECRET above.
    DEV_DEFAULT_SUPERVISOR_KEY = "FCS10-SUPERVISOR-DEV-PLACEHOLDER-CHANGE-ME",

    -- Reserved for a future sliding-window replay cache if out-of-order
    -- delivery via rednet repeaters turns out to be an issue in practice.
    -- v1 anti-replay is strict-monotonic sequence numbers per sender.
    NONCE_WINDOW = 20,
}

-- ===========================================================================
-- THERMODYNAMIC SETPOINTS (NUREG-1433 mapping onto Mekanism telemetry)
-- ===========================================================================
config.SETPOINTS = {
    -- Core damage %, NUREG-1433 Ch.3.4 fuel-cladding integrity analog
    DAMAGE = {
        NORMAL_MAX  = 0,    -- 0%   : intact, no action
        WARNING     = 5,    -- >5%  : degradation trend, operator awareness (-> NOUE)
        HIGH_ALARM  = 20,   -- >20% : approaching safety-limit analog (-> ALERT)
        SCRAM       = 40,   -- >40% : automatic reactor trip, no operator veto
        CORE_DAMAGE = 80,   -- >80% : core damage imminent (-> GENERAL EMERGENCY)
    },

    -- Core temperature, Kelvin. Mekanism default max safe operating temp: 1200K.
    CORE_TEMP_K = {
        NORMAL_MAX = 900,
        WARNING    = 1000,
        HIGH_ALARM = 1100,
        SCRAM      = 1200,

        -- Hot/Cold Shutdown boundary (~200F), per real PWR Tech-Spec-style
        -- mode tables: not producing power AND above this temp = Hot
        -- Standby (still hot, holding); at/below it = Cold Start/Bypass.
        -- See nodes/plc.lua's Operating Mode derivation.
        HOT_COLD_BOUNDARY = 366,
    },

    COOLANT_PCT = {
        LOW_WARNING = 40,
        LOW_ALARM   = 20,
        LOW_SCRAM   = 10,
    },

    WASTE_PCT = {
        HIGH_WARNING = 80,
        HIGH_ALARM   = 90,
        HIGH_SCRAM   = 95,
    },

    BURN_RATE = {
        -- fraction of the reactor's configured max burn rate; sustained
        -- over-rate is treated as a precursor alarm, not an immediate trip
        OVER_RATE_WARNING = 1.05,
    },

    -- Auto-Runback: automated burn-rate reduction on a partial system
    -- fault (any metric crossing its HIGH_ALARM setpoint), a protective
    -- step short of a full SCRAM. See nodes/plc.lua's pollAndEvaluate().
    RUNBACK = {
        REDUCTION_FACTOR = 0.5, -- fraction of current burn rate commanded on runback entry
    },
}

-- ===========================================================================
-- EMERGENCY ACTION LEVELS (NEI 99-01 tiers)
-- ===========================================================================
config.EAL = {
    TIERS = {
        { id = "NOUE",  name = "Notification of Unusual Event", priority = 1, color = "blue"   },
        { id = "ALERT", name = "Alert",                          priority = 2, color = "yellow" },
        { id = "SAE",   name = "Site Area Emergency",            priority = 3, color = "orange" },
        { id = "GE",    name = "General Emergency",              priority = 4, color = "red"    },
    },

    -- Recognition-category keys consumed by the Supervisor's EAL voting
    -- logic (Step 2+). Maps an initiating condition to its minimum tier.
    IC = {
        DAMAGE_TREND      = "NOUE",
        DAMAGE_HIGH       = "ALERT",
        SCRAM_FAILURE     = "SAE",
        CORE_DAMAGE       = "GE",
        LOSS_OF_COOLANT   = "SAE",
        RADIATION_RELEASE = "GE",
    },
}

-- ===========================================================================
-- PLANT / CONDUCT-OF-OPERATIONS STATES (IAEA SSG-76 aligned)
-- ===========================================================================
config.STATES = {
    NORMAL            = "NORMAL",
    ANOMALY           = "ANOMALY",           -- SSG-76 abnormal-operation state
    ALERT             = "ALERT",
    SITE_EMERGENCY    = "SITE_EMERGENCY",
    GENERAL_EMERGENCY = "GENERAL_EMERGENCY",
    SCRAMMED          = "SCRAMMED",
    MAINTENANCE       = "MAINTENANCE",       -- administrative lockout
    MANUAL_OVERRIDE   = "MANUAL_OVERRIDE",
}

-- ===========================================================================
-- OPERATING MODES (plant lifecycle phase, orthogonal to STATES above -
-- STATES is safety/alarm status, this is "what phase of startup/operation
-- is the plant in"). Derived automatically from telemetry by nodes/plc.lua;
-- never recomputed while SCRAMMED (frozen at last value, same as every
-- other metric on a latched trip).
-- ===========================================================================
config.OPERATING_MODES = {
    COLD_START_BYPASS = "COLD_START_BYPASS", -- steam bypass open, cold, ready to start
    RUN_UP            = "RUN_UP",            -- bypass closed, ramping burn rate up from cold
    HOT_STANDBY       = "HOT_STANDBY",       -- not producing power, but still hot (>200F)
    NORMAL_OPERATION  = "NORMAL_OPERATION",  -- actively producing power
    AUTO_RUNBACK      = "AUTO_RUNBACK",      -- automated burn-rate reduction in progress
}

-- ===========================================================================
-- DEFAULT RUNTIME STATE
-- ===========================================================================
-- Returns a fresh table each call - never share one default table instance
-- across nodes/reactors, or mutations on one will leak into another.
function config.newDefaultReactorState()
    return {
        online      = false,
        damagePct   = 0,
        coreTempK   = 293,
        coolantPct  = 100,
        wastePct    = 0,
        burnRateMbT = 0,
        plantState  = config.STATES.NORMAL,
        activeEAL   = nil,
        lastUpdate  = 0,
        seq         = 0,
    }
end

return config
