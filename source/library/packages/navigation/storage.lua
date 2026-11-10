-- Section: Navigator preferences | Validated display configuration and JSON persistence.
-- JSON configuration and persistent settings for computer 17.
-- Keep disk access here so control and display code never silently invents defaults.
local Storage = {}

local SETTINGS_SCHEMA = 1
local MAX_JSON_BYTES = 262144

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function object(value)
    return type(value) == "table"
end

function Storage.finite(value)
    return finite(value)
end

-- Section: Navigator preferences | Validated display configuration and JSON persistence.
-- Summary: Construct the supported initial local display settings.
function Storage.defaultSettings()
    return {
        schema_version = SETTINGS_SCHEMA,
        display_page = "FLIGHT",
        -- Stored selected targets are intentionally absent. A restart never
        -- restores active control authority or starts an actuator.
    }
end

-- Summary: Validate the stored display-settings schema and selected page.
function Storage.validateSettings(settings)
    if not object(settings) then return false, "settings must be a JSON object" end
    if settings.schema_version ~= SETTINGS_SCHEMA then return false, "unsupported settings schema_version" end
    local pages = { FLIGHT = true, NAV = true, SHIP = true, SETTINGS = true }
    if not pages[settings.display_page] then return false, "display_page must be FLIGHT, NAV, SHIP, or SETTINGS" end
    for key,bounds in pairs({speed_trend_filter_alpha={.05,1},speed_trend_deadband={0,1}}) do
        if settings[key]~=nil and (not finite(settings[key]) or settings[key]<bounds[1] or settings[key]>bounds[2]) then return false,key.." out of range" end
    end
    return true
end

-- Summary: Validate required configuration objects, frequency pairs and numeric bounds.
function Storage.validateConfig(config)
    if not object(config) or config.schema_version ~= 1 or config.role ~= "navigator" or
        not finite(config.computer_id) or config.computer_id < 0 or config.computer_id ~= math.floor(config.computer_id) or
        not finite(config.core_id) or config.core_id < 0 or config.core_id ~= math.floor(config.core_id) or
        config.protocol ~= "amaryllis.v1" then return false, "navigator identity/core binding is invalid" end
    if not finite(config.status_timeout_seconds) or config.status_timeout_seconds <= 0 or config.status_timeout_seconds > 60 then
        return false, "bridge status timeout must be greater than zero and at most 60 seconds"
    end
    if not object(config.hardware) or type(config.hardware.main_monitor) ~= "string" or #config.hardware.main_monitor > 128 then
        return false, "bridge monitor binding must be an exact name or empty string"
    end
    return true
end

local function api(dependencies)
    dependencies = dependencies or {}
    return dependencies.fs or fs, dependencies.textutils or textutils
end

-- Summary: Read and decode a JSON document through the configured filesystem dependency.
function Storage.readJson(path, dependencies)
    local fsApi, jsonApi = api(dependencies)
    if not fsApi or type(fsApi.open) ~= "function" or not jsonApi or type(jsonApi.unserializeJSON) ~= "function" then
        return nil, "ComputerCraft filesystem or JSON support is unavailable"
    end
    local okOpen, handle = pcall(fsApi.open, path, "r")
    if not okOpen or not handle then return nil, "could not open " .. path .. ": " .. tostring(handle) end
    local okRead, text = pcall(handle.readAll)
    pcall(handle.close)
    if not okRead or type(text) ~= "string" then return nil, "could not read " .. path .. ": " .. tostring(text) end
    if #text > MAX_JSON_BYTES then return nil, path .. " exceeds the JSON size limit" end
    local okDecode, value = pcall(jsonApi.unserializeJSON, text)
    if not okDecode or type(value) ~= "table" then
        return nil, "invalid JSON in " .. path .. ": " .. tostring(value)
    end
    return value
end

function Storage.loadConfig(path, dependencies)
    local config, reason = Storage.readJson(path or "avionics/config.json", dependencies)
    if not config then return nil, reason end
    local ok, invalid = Storage.validateConfig(config)
    if not ok then return nil, "invalid bridge configuration: " .. tostring(invalid) end
    return config
end

-- Summary: Read validated display settings or construct the supported initial settings.
function Storage.loadSettings(path, dependencies)
    path = path or "avionics/data/settings.json"
    local fsApi = select(1, api(dependencies))
    if not fsApi or type(fsApi.exists) ~= "function" then
        return nil, "ComputerCraft filesystem is unavailable"
    end

    local primary, primaryError
    if fsApi.exists(path) then primary, primaryError = Storage.readJson(path, dependencies) end
    if primary then
        local ok, invalid = Storage.validateSettings(primary)
        if ok then return primary end
        primaryError = "invalid settings: " .. tostring(invalid)
    elseif not primaryError then
        primaryError = "settings file is missing"
    end

    local backupPath = path .. ".bak"
    if fsApi.exists(backupPath) then
        local backup, backupError = Storage.readJson(backupPath, dependencies)
        if backup then
            local ok, invalid = Storage.validateSettings(backup)
            if ok then return backup, "recovered settings from backup after primary failure: " .. tostring(primaryError) end
            backupError = "backup settings are invalid: " .. tostring(invalid)
        end
        return Storage.defaultSettings(), tostring(primaryError) .. "; " .. tostring(backupError) .. "; using safe defaults"
    end
    return Storage.defaultSettings(), tostring(primaryError) .. "; using safe defaults"
end

-- Summary: Serialize and replace a JSON document through its validated storage path.
function Storage.writeJson(path, value, dependencies)
    local fsApi, jsonApi = api(dependencies)
    if not fsApi or type(fsApi.open) ~= "function" or type(fsApi.move) ~= "function" or
        type(fsApi.delete) ~= "function" or type(fsApi.exists) ~= "function" or
        not jsonApi or type(jsonApi.serializeJSON) ~= "function" then
        return false, "ComputerCraft filesystem or JSON serialization is unavailable"
    end
    local okEncode, encoded = pcall(jsonApi.serializeJSON, value)
    if not okEncode or type(encoded) ~= "string" then return false, "could not encode JSON: " .. tostring(encoded) end
    if #encoded > MAX_JSON_BYTES then return false, "JSON exceeds the size limit" end

    local directory = type(fsApi.getDir) == "function" and fsApi.getDir(path) or ""
    if directory ~= "" and type(fsApi.makeDir) == "function" then
        local okDir, dirError = pcall(fsApi.makeDir, directory)
        if not okDir then return false, "could not create settings directory: " .. tostring(dirError) end
    end

    -- A locked/denied backup is a persistence failure, not a reason to stop
    -- the bridge or control runtime. Cleanup must also never throw over the
    -- original write error. Keep the primary untouched if rotation fails.
    -- Summary: Remove the selected stored entry and update its containing collection.
    local function remove(file)
        local okExists,exists=pcall(fsApi.exists,file)
        if not okExists then return false,tostring(exists) end
        if not exists then return true end
        local okDelete,result=pcall(fsApi.delete,file)
        if not okDelete or result==false then return false,tostring(result) end
        return true
    end
    local temporary, backup = path .. ".tmp", path .. ".bak"
    local cleanOk,cleanError=remove(temporary)
    if not cleanOk then return false,"could not remove temporary JSON file: "..tostring(cleanError) end
    local openOk, handle = pcall(fsApi.open, temporary, "w")
    if not openOk or not handle then return false, "could not open temporary JSON file: " .. tostring(handle) end
    local writeOk, writeResult = pcall(handle.write, encoded)
    pcall(handle.close)
    if not writeOk or writeResult == false then
        remove(temporary)
        return false, "could not write temporary JSON file: " .. tostring(writeResult)
    end
    local readBack, readBackError = Storage.readJson(temporary, dependencies)
    if not readBack then
        remove(temporary)
        return false, "temporary JSON file failed read-back validation: " .. tostring(readBackError)
    end

    local movedOld = false
    if fsApi.exists(path) then
        -- Rotate the current primary only after the new temp file is readable.
        -- If primary is missing, retain an existing recovery backup.
        local removed,removeError=remove(backup)
        if not removed then
            remove(temporary)
            return false,"could not rotate JSON backup: "..tostring(removeError)
        end
        local backupOk, backupError = pcall(fsApi.move, path, backup)
        if not backupOk then
            remove(temporary)
            return false, "could not preserve previous JSON file: " .. tostring(backupError)
        end
        movedOld = true
    end

    local installOk, installError = pcall(fsApi.move, temporary, path)
    if not installOk then
        if movedOld and fsApi.exists(backup) and not fsApi.exists(path) then
            pcall(fsApi.move, backup, path)
        end
        remove(temporary)
        return false, "could not install new JSON file: " .. tostring(installError)
    end
    return true
end

-- Summary: Validate display settings and save them through JSON replacement.
function Storage.saveSettings(settings, path, dependencies)
    local ok, reason = Storage.validateSettings(settings)
    if not ok then return false, reason end
    return Storage.writeJson(path or "avionics/data/settings.json", settings, dependencies)
end

return Storage
