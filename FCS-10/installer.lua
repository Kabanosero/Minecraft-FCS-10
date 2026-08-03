-- installer.lua
-- FCS-10 / ATM-PCS :: Node bootstrap installer
--
-- Pulls the files needed to run a given node role onto a fresh CC:Tweaked
-- computer, straight from the GitHub repo's raw main branch. Every role
-- gets the shared lib/ files plus its own role-specific script.
--
-- Usage: installer install <supervisor|plc|test>

local BASE_URL = "https://raw.githubusercontent.com/Kabanosero/Minecraft-FCS-10/main/FCS-10/"

local COMMON_FILES = {
    "lib/config.lua",
    "lib/md5.lua",
    "lib/secnet.lua",
}

local ROLE_FILES = {
    supervisor = { "nodes/supervisor.lua" },
    plc        = { "nodes/plc.lua" },
    test       = { "test/cmd_test.lua" },
}

-- ---------------------------------------------------------------------------
-- Downloads a single repo-relative path into the matching local path,
-- creating any missing parent directory along the way.
-- ---------------------------------------------------------------------------
local function downloadFile(path)
    local url = BASE_URL .. path

    local response, err = http.get(url)
    if not response then
        print("[INSTALLER] FAILED: " .. path .. " (" .. tostring(err) .. ")")
        return false
    end

    local contents = response.readAll()
    response.close()

    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end

    local file, ferr = fs.open(path, "w")
    if not file then
        print("[INSTALLER] FAILED: could not open " .. path .. " for write (" .. tostring(ferr) .. ")")
        return false
    end

    file.write(contents)
    file.close()

    print("[INSTALLER] OK: " .. path)
    return true
end

local function printUsage()
    print("Usage: installer install <supervisor|plc|test>")
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------
local args = { ... }
local action = args[1]
local role = args[2]

if action == "install" and ROLE_FILES[role] then
    for _, path in ipairs(COMMON_FILES) do
        downloadFile(path)
    end
    for _, path in ipairs(ROLE_FILES[role]) do
        downloadFile(path)
    end
else
    printUsage()
end
