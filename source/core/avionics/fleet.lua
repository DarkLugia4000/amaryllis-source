local Mathx = require("avionics.mathx")
-- Section: Fleet registry | Role assignment validation and stored computer IDs.
-- Authoritative role registry for core 35. IDs are editable; logical roles and
-- labels travel in the JSON file so runtime routing never depends on IDs.
local Fleet = {}

local ROLE_ORDER = {"core", "navigator", "heading-left", "heading-right", "heading-main",
    "chamber_fl", "chamber_fr", "chamber_bl", "chamber_br", "primary_l", "primary_r",
    "thrust-lb", "thrust-rb", "thrust-ls", "thrust-rs", "state"}
local DEFAULTS = {
    core={label="ama-core"},
    state={label="ama-state"},
    navigator={label="ama-bridge"},
    ["heading-left"]={label="ama-heading-left"},
    ["heading-right"]={label="ama-heading-right"},
    ["heading-main"]={label="ama-heading-main"},
    chamber_fl={label="chamber_fl"}, chamber_fr={label="chamber_fr"},
    chamber_bl={label="chamber_bl"}, chamber_br={label="chamber_br"},
    primary_l={label="primary_l"}, primary_r={label="primary_r"},
    ["thrust-lb"]={label="thrust-lb"},["thrust-rb"]={label="thrust-rb"},
    ["thrust-ls"]={label="thrust-ls"},["thrust-rs"]={label="thrust-rs"},
}
local QUADRANT_ROLE = {FL="chamber_fl", FR="chamber_fr", BL="chamber_bl", BR="chamber_br"}
local CONTROLLER_ROLE = {
    ["thrust-lb"]="chamber_fl", ["thrust-rb"]="chamber_fr",
    ["thrust-ls"]="chamber_bl", ["thrust-rs"]="chamber_br",
    ["primary-left"]="primary_l", ["primary-right"]="primary_r",
}

local function clone(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = clone(item) end
    return out
end

local finite = Mathx.finite

local function validLabel(value)
    return type(value) == "string" and #value > 0 and #value <= 64 and value:match("^[%w_%.%-]+$") ~= nil
end

function Fleet.defaultComputers()
    return clone(DEFAULTS)
end

-- Section: Fleet registry | Role assignment validation and stored computer IDs.
-- Summary: Validate role labels and unique numeric IDs in the fleet registry.
function Fleet.validateComputers(computers)
    if type(computers) ~= "table" then return false, "computers must be an object" end
    for role in pairs(computers) do
        if not DEFAULTS[role] then return false, "unknown fleet role " .. tostring(role) end
    end
    local seen, seenLabels = {}, {}
    for _, role in ipairs(ROLE_ORDER) do
        local entry = computers[role]
        if entry ~= nil then
            if type(entry) ~= "table" then return false, "fleet role " .. role .. " must be an object" end
            local id = entry.id
            if id ~= nil then
                if not finite(id) or id % 1 ~= 0 or id < 0 or id > 65535 then
                    return false, "computer ID for " .. role .. " must be an integer from 0 to 65535"
                end
                if seen[id] then return false, "computer ID " .. tostring(id) .. " is assigned more than once" end
                seen[id] = role
                if not validLabel(entry.label) then return false, "label for " .. role .. " must be a short identifier" end
            elseif entry.label ~= nil and not validLabel(entry.label) then
                return false, "label for " .. role .. " must be a short identifier"
            end
            if entry.label then
                if seenLabels[entry.label] then
                    return false, "label " .. entry.label .. " is assigned to more than one role"
                end
                seenLabels[entry.label] = role
            end
        end
    end
    return true
end

function Fleet.validateDocument(document)
    if type(document) ~= "table" then return false, "fleet registry must be an object" end
    if document.schemaVersion ~= 1 then return false, "fleet schemaVersion must be 1" end
    if document.revision ~= nil then return false, "fleet registry must not contain a revision counter" end
    return Fleet.validateComputers(document.computers)
end

-- Summary: Load the fleet registry and resolve this core's identity.
function Fleet.new(dependencies)
    dependencies = dependencies or {}
    local self = setmetatable({}, {__index=Fleet})
    self.fs = dependencies.fs or fs
    self.json = dependencies.json or textutils
    self.path = dependencies.path or "/fleet.json"
    local coreID=dependencies.coreID
    local osApi=dependencies.os or os
    if coreID==nil and osApi and type(osApi.getComputerID)=="function" then
        local ok,value=pcall(osApi.getComputerID)
        if ok and finite(value) and value%1==0 and value>=0 and value<=65535 then coreID=value end
    end
    self.coreID = coreID
    self.coreLabel = dependencies.coreLabel
    if self.coreLabel==nil and osApi and type(osApi.getComputerLabel)=="function" then
        local ok,value=pcall(osApi.getComputerLabel)
        if ok and validLabel(value) then self.coreLabel=value end
    end
    self.computers = Fleet.defaultComputers()
    self.error = nil
    self.dirty = false
    self.corruptPath = nil
    self:_load()
    self:_ensureLocalCore()
    return self
end

-- Summary: Reconcile the local core computer identity with the registry.
function Fleet:_ensureLocalCore()
    local current=self.computers.core
    if current and current.id~=nil then return true end
    local updated=clone(self.computers)
    local entry=updated.core or {label=DEFAULTS.core.label}
    entry.id=self.coreID
    if self.coreLabel then entry.label=self.coreLabel end
    updated.core=entry
    local valid,reason=Fleet.validateComputers(updated)
    if not valid then self.error="Local core role could not be registered: "..tostring(reason); return false end
    -- A malformed existing primary file stays untouched. The local ID is
    -- still known in memory, but peer routes remain unassigned until an
    -- operator repairs the registry.
    if self.corruptPath then self.computers=updated;return true end
    local previous=self.computers
    self.computers=updated
    local saved,saveReason=self:save()
    if not saved then
        self.computers=previous
        self.error="Local core role is active in memory but could not be saved: "..tostring(saveReason)
        return false
    end
    return true
end

-- Summary: Read and validate the selected registry document.
function Fleet:_read(path)
    if not self.fs or type(self.fs.open) ~= "function" then return nil, "filesystem API unavailable" end
    local ok, handle, reason = pcall(self.fs.open, path, "r")
    if not ok or not handle then return nil, tostring(reason or handle or "could not open fleet registry") end
    local readOK, content = pcall(handle.readAll)
    pcall(handle.close)
    if not readOK or type(content) ~= "string" then return nil, tostring(content or "could not read fleet registry") end
    if #content > 16384 then return nil, "fleet registry exceeds 16 KiB" end
    local decodeOK, document = pcall(self.json.unserializeJSON, content)
    if not decodeOK then return nil, tostring(document) end
    local valid, validationReason = Fleet.validateDocument(document)
    if not valid then return nil, validationReason end
    return clone(document.computers)
end

-- Summary: Load the current registry or its supported fallback record.
function Fleet:_load()
    local computers, reason = self:_read(self.path)
    if computers then
        self.computers = computers
        return true
    end
    local backup, backupReason = self:_read(self.path .. ".bak")
    if backup then
        self.computers = backup
        self.error = "Recovered fleet registry from backup after: " .. tostring(reason)
        self.dirty = true
        if self.fs and self.fs.exists and self.fs.exists(self.path) then
            local kept = self:_preserveCorrupt()
            if not kept then return false, self.error .. "; could not preserve the invalid primary file" end
        end
        local saved, saveReason = self:save()
        if not saved then self.error = self.error .. "; could not restore primary file: " .. tostring(saveReason) end
        return true
    end
    self.error = reason
    local primaryExists = self.fs and self.fs.exists and self.fs.exists(self.path)
    local backupExists = self.fs and self.fs.exists and self.fs.exists(self.path .. ".bak")
    if not primaryExists and not backupExists then
        self.computers = Fleet.defaultComputers()
        local saved, saveReason = self:save()
        if saved then self.error=nil
        else self.error = "Fleet registry missing; using unassigned roles in memory: " .. tostring(saveReason) end
        return true
    end
    if not reason then self.error = backupReason end
    if primaryExists then self.corruptPath = self.path end
    return false, self.error
end

-- Summary: Retain an unreadable registry record before writing its replacement.
function Fleet:_preserveCorrupt()
    if not self.fs or type(self.fs.move) ~= "function" then return false end
    local target = self.path .. ".corrupt"
    local suffix = 1
    while self.fs.exists and self.fs.exists(target) do
        target = self.path .. ".corrupt." .. tostring(suffix)
        suffix = suffix + 1
    end
    local moved, result = pcall(self.fs.move, self.path, target)
    if moved and result~=false then
        self.corruptPath = target
        return true
    end
    return false
end

function Fleet:snapshot()
    return {schemaVersion=1, computers=clone(self.computers)}
end

function Fleet:get(role)
    local entry = self.computers[role]
    return entry and entry.id or nil, entry and entry.label or nil
end

function Fleet:roleForID(id)
    if not finite(id) then return nil end
    for _, role in ipairs(ROLE_ORDER) do
        local entry = self.computers[role]
        if entry and entry.id == id then return role, entry.label end
    end
end

function Fleet:roleIDs()
    local result = {}
    for semantic, role in pairs(CONTROLLER_ROLE) do result[semantic] = self:get(role) end
    return result
end

-- Summary: Validate and stage a role's replacement computer ID.
function Fleet:editID(role, id)
    if not DEFAULTS[role] then return false, "unknown fleet role" end
    if id ~= nil and (not finite(id) or id % 1 ~= 0 or id < 0 or id > 65535) then
        return false, "computer ID must be an integer from 0 to 65535"
    end
    if role == "core" and id ~= self.coreID then return false, "the running core ID cannot be changed here" end
    local updated = clone(self.computers)
    local entry = updated[role] or {label=DEFAULTS[role].label}
    entry.id = id
    entry.label = entry.label or DEFAULTS[role].label
    updated[role] = entry
    local valid, reason = Fleet.validateComputers(updated)
    if not valid then return false, reason end
    local old = self.computers
    self.computers = updated
    local saved, saveReason = self:save()
    if not saved then self.computers = old; self.error = saveReason; return false, saveReason end
    self.error = nil
    return true
end

-- Summary: Write the validated registry document through its persistent storage path.
function Fleet:_write(path, content)
    local ok, handle, reason = pcall(self.fs.open, path, "w")
    if not ok or not handle then return false, tostring(reason or handle or "could not write fleet registry") end
    local writeOK, writeError = pcall(handle.write, content)
    pcall(handle.close)
    if not writeOK then return false, tostring(writeError) end
    return true
end

-- Summary: Persist the accepted role-to-computer registry.
function Fleet:save()
    local document = self:snapshot()
    local valid, reason = Fleet.validateDocument(document)
    if not valid then return false, reason end
    if not self.fs or type(self.fs.open) ~= "function" or type(self.fs.move) ~= "function" then
        return false, "atomic filesystem move unavailable"
    end
    local encodeOK, encoded = pcall(self.json.serializeJSON, document)
    if not encodeOK or type(encoded) ~= "string" then return false, "could not encode fleet registry" end
    if #encoded > 16384 then return false, "fleet registry exceeds 16 KiB" end

    local temp, backup = self.path .. ".tmp", self.path .. ".bak"
    local wrote, writeError = self:_write(temp, encoded)
    if not wrote then return false, writeError end
    local check, checkError = self:_read(temp)
    if not check then
        pcall(self.fs.delete, temp)
        return false, "temporary fleet JSON failed validation: " .. tostring(checkError)
    end

    local hadOriginal = self.fs.exists and self.fs.exists(self.path) or false
    if hadOriginal then
        local old, oldReason = self:_read(self.path)
        if old then
            pcall(self.fs.delete, backup)
            local moved, moveResult = pcall(self.fs.move, self.path, backup)
            if not moved or moveResult==false then pcall(self.fs.delete, temp); return false, tostring(moveResult) end
        else
            local preserved = self:_preserveCorrupt()
            if not preserved then pcall(self.fs.delete, temp); return false, "could not preserve the invalid registry before replacement" end
            self.error = "Replaced invalid registry; prior contents preserved at " .. tostring(self.corruptPath) ..
                " (" .. tostring(oldReason) .. ")"
            hadOriginal = false
        end
    end
    local moved, moveError = pcall(self.fs.move, temp, self.path)
    if not moved or moveError==false then
        if hadOriginal then pcall(self.fs.move, backup, self.path) end
        pcall(self.fs.delete, temp)
        return false, tostring(moveError)
    end
    if hadOriginal then pcall(self.fs.delete, backup) end
    self.dirty = false
    return true
end

Fleet.ROLE_ORDER = ROLE_ORDER
Fleet.DEFAULTS = clone(DEFAULTS)
Fleet.QUADRANT_ROLE = clone(QUADRANT_ROLE)
Fleet.CONTROLLER_ROLE = clone(CONTROLLER_ROLE)
Fleet.clone = clone

return Fleet
