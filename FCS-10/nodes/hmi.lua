-- nodes/hmi.lua
-- FCS-10 / ATM-PCS :: Human-Machine Interface (Operator GUI)
--
-- The click-driven operator frontend for the SCADA system. Runs on its own
-- CC:Tweaked Advanced Computer, entirely decoupled from reactor logic - it
-- only ever knows about reactor state via wireless telemetry, never a
-- fissionReactorLogicAdapter.
--
-- SCOPE OF THIS FILE (foundational pass): theming, the button registry, UI
-- rendering, and mouse-click handling only. It does not yet dofile
-- lib/config.lua or lib/secnet.lua, and clicking a button only prints a
-- debug message - it does not send anything over the network. A future
-- pass wires this into secnet using config.NETWORK.PROTOCOL_HMI to receive
-- STATE_BROADCAST/TELEMETRY from the Supervisor and send COMMAND requests
-- back to it (see nodes/supervisor.lua's header: "Interactive operator
-- control is a future HMI node's job").

local TITLE = "FCS-10 Supervisor"

-- ===========================================================================
-- THEMING
-- ===========================================================================
-- Button labels are drawn in headerText, not text: headerText is already
-- the key meant to contrast against a filled/colored surface (same role it
-- plays against headerBg), so it reads correctly on both the saturated
-- "classic" button fills and the grayscale "mono" fills below without
-- needing an 8th theme key just for button label color.
local themes = {
    classic = {
        bg         = colors.lightGray,
        text       = colors.black,
        headerBg   = colors.gray,
        headerText = colors.white,
        btnDanger  = colors.red,
        btnSafe    = colors.green,
        btnNeutral = colors.lightBlue,
    },
    mono = {
        bg         = colors.black,
        text       = colors.white,
        headerBg   = colors.white,
        headerText = colors.black,
        btnDanger  = colors.white,
        btnSafe    = colors.lightGray,
        btnNeutral = colors.gray,
    },
}

local currentTheme = themes.classic

-- ===========================================================================
-- BUTTON REGISTRY
-- ===========================================================================
-- colorKey is a theme key, not a resolved color, so re-theming (setting
-- currentTheme to a different palette) re-colors every button automatically.
local buttons = {
    { id = "startup", label = "STARTUP", x = 3,  y = 5, width = 12, colorKey = "btnSafe"    },
    { id = "scram",   label = "SCRAM",   x = 17, y = 5, width = 12, colorKey = "btnDanger"  },
    { id = "exit",    label = "EXIT",    x = 31, y = 5, width = 12, colorKey = "btnNeutral" },
}

-- ===========================================================================
-- RENDERING
-- ===========================================================================
local function drawHeader(w)
    term.setBackgroundColor(currentTheme.headerBg)
    term.setTextColor(currentTheme.headerText)
    term.setCursorPos(1, 1)
    term.write(string.rep(" ", w))
    term.setCursorPos(2, 1)
    term.write(TITLE)
end

local function drawButton(btn)
    term.setBackgroundColor(currentTheme[btn.colorKey])
    term.setTextColor(currentTheme.headerText)
    term.setCursorPos(btn.x, btn.y)
    term.write(string.rep(" ", btn.width))
    term.setCursorPos(btn.x + math.floor((btn.width - #btn.label) / 2), btn.y)
    term.write(btn.label)
end

local function drawUI()
    term.setBackgroundColor(currentTheme.bg)
    term.setTextColor(currentTheme.text)
    term.clear()

    local w = ({ term.getSize() })[1]
    drawHeader(w)

    for _, btn in ipairs(buttons) do
        drawButton(btn)
    end
end

-- ===========================================================================
-- HIT-TESTING
-- ===========================================================================
local function hitTest(x, y)
    for _, btn in ipairs(buttons) do
        if y == btn.y and x >= btn.x and x < btn.x + btn.width then
            return btn
        end
    end
    return nil
end

-- ===========================================================================
-- MAIN EVENT LOOP
-- ===========================================================================
drawUI()

while true do
    local event, side, x, y = os.pullEvent()

    if event == "mouse_click" then
        local btn = hitTest(x, y)
        if btn then
            print("[HMI] " .. btn.label .. " CLICKED")
        end
    end

    -- Future branches: "timer" (redraw cadence) and "rednet_message"
    -- (secnet telemetry/state updates) once this node is wired to the
    -- network, following supervisor.lua's dispatch-by-event-type pattern.
end
