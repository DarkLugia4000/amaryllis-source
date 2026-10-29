-- @ama-section: Package service | Trusted removable-media offers and acknowledged transfer.
-- Removable package media v1
local M = {}

local REGISTRY_PROTOCOL = "amaryllis.v1"
local STATUS_PATH = "/installer/install_status.json"
local CONFIG_PATH = "/installer/config.json"
local FLEET_PATH = "/fleet.json"
local PAUSE_PATH = "/installer/paused"
local FLEET_MAX_BYTES = 16384
local REQUIRED_ROLES = {
    "core", "navigator", "heading-left", "heading-right", "heading-main",
    "chamber_fl", "chamber_fr", "chamber_bl", "chamber_br", "primary_l", "primary_r",
    "thrust-lb", "thrust-rb", "thrust-ls", "thrust-rs",
}
local ROLE_FILES = {
    navigator = {
        root = "/packages/navigation", packageId = "amaryllis.navigator",
        paths = { "/avionics/main.lua", "/avionics/config.json", "/avionics/storage.lua", "/avionics/ui.lua", "/avionics/common/console.lua", "/avionics/diagnostics.lua" },
        sources = { ["/avionics/main.lua"] = "main.lua", ["/avionics/config.json"] = "config.json", ["/avionics/storage.lua"] = "storage.lua", ["/avionics/ui.lua"] = "ui.lua", ["/avionics/common/console.lua"] = "/packages/common/console.lua", ["/avionics/diagnostics.lua"] = "/packages/common/diagnostics.lua" },
    },
    ["heading-main"] = {
        root = "/packages/heading/main", packageId = "amaryllis.heading.main",
        paths = { "/avionics/main.lua", "/avionics/config.json", "/avionics/common/console.lua", "/avionics/diagnostics.lua" },
        sources = { ["/avionics/main.lua"] = "main.lua", ["/avionics/config.json"] = "config.json", ["/avionics/common/console.lua"] = "/packages/common/console.lua", ["/avionics/diagnostics.lua"] = "/packages/common/diagnostics.lua" },
    },
    ["heading-left"] = {
        root = "/packages/heading/left", packageId = "amaryllis.heading.left",
        paths = { "/avionics/main.lua", "/avionics/config.json", "/avionics/common/console.lua", "/avionics/diagnostics.lua" },
        sources = { ["/avionics/main.lua"] = "main.lua", ["/avionics/config.json"] = "config.json", ["/avionics/common/console.lua"] = "/packages/common/console.lua", ["/avionics/diagnostics.lua"] = "/packages/common/diagnostics.lua" },
    },
    ["heading-right"] = {
        root = "/packages/heading/right", packageId = "amaryllis.heading.right",
        paths = { "/avionics/main.lua", "/avionics/config.json", "/avionics/common/console.lua", "/avionics/diagnostics.lua" },
        sources = { ["/avionics/main.lua"] = "main.lua", ["/avionics/config.json"] = "config.json", ["/avionics/common/console.lua"] = "/packages/common/console.lua", ["/avionics/diagnostics.lua"] = "/packages/common/diagnostics.lua" },
    },
}
for _, quadrant in ipairs({ "fl", "fr", "bl", "br" }) do
    ROLE_FILES["chamber_" .. quadrant] = {
        root = "/packages/chamber/" .. quadrant, packageId = "amaryllis.chamber." .. quadrant,
        paths = { "/avionics/main.lua", "/avionics/config.json", "/avionics/hardware.lua", "/avionics/lift.lua", "/avionics/thrust.lua", "/avionics/common/console.lua", "/avionics/diagnostics.lua" },
        sources = { ["/avionics/main.lua"] = "main.lua", ["/avionics/config.json"] = "config.json", ["/avionics/hardware.lua"] = "hardware.lua", ["/avionics/lift.lua"] = "lift.lua", ["/avionics/thrust.lua"] = "thrust.lua", ["/avionics/common/console.lua"] = "/packages/common/console.lua", ["/avionics/diagnostics.lua"] = "/packages/common/diagnostics.lua" },
    }
end
for _, suffix in ipairs({"lb","rb","ls","rs"}) do
    ROLE_FILES["thrust-"..suffix]={root="/packages/thrust/"..suffix,packageId="amaryllis.thrust."..suffix,
        paths={"/avionics/main.lua","/avionics/config.json","/avionics/hardware.lua","/avionics/thrust.lua",
            "/avionics/chamber_link.lua","/avionics/common/console.lua","/avionics/diagnostics.lua"},
        sources={["/avionics/main.lua"]="main.lua",["/avionics/config.json"]="config.json",
            ["/avionics/hardware.lua"]="hardware.lua",["/avionics/thrust.lua"]="thrust.lua",
            ["/avionics/chamber_link.lua"]="chamber_link.lua",
            ["/avionics/common/console.lua"]="/packages/common/console.lua",["/avionics/diagnostics.lua"]="/packages/common/diagnostics.lua"}}
end
for _,q in ipairs({"fl","fr","bl","br"}) do
    local definition=ROLE_FILES["chamber_"..q]
    definition.paths[#definition.paths+1]="/avionics/relay.lua"
    definition.paths[#definition.paths+1]="/avionics/chamber_link.lua"
    definition.sources["/avionics/relay.lua"]="relay.lua"
    definition.sources["/avionics/chamber_link.lua"]="chamber_link.lua"
end
for _, side in ipairs({ "l", "r" }) do
    ROLE_FILES["primary_" .. side] = {
        root = "/packages/primary/" .. (side == "l" and "left" or "right"), packageId = "amaryllis.primary." .. side,
        paths = { "/avionics/main.lua", "/avionics/config.json", "/avionics/hardware.lua", "/avionics/common/console.lua", "/avionics/diagnostics.lua" },
        sources = { ["/avionics/main.lua"] = "main.lua", ["/avionics/config.json"] = "config.json", ["/avionics/hardware.lua"] = "hardware.lua", ["/avionics/common/console.lua"] = "/packages/common/console.lua", ["/avionics/diagnostics.lua"] = "/packages/common/diagnostics.lua" },
    }
end

M.PROTOCOL = "amaryllis.install.v1"
M.REGISTRY_PROTOCOL = REGISTRY_PROTOCOL
M.ROLE_FILES = ROLE_FILES
M.REQUIRED_ROLES = REQUIRED_ROLES
M.FLEET_PATH = FLEET_PATH
M.PAUSE_PATH = PAUSE_PATH
local function isInteger(value)
    return type(value) == "number" and value ~= math.huge and value ~= -math.huge
        and value == math.floor(value)
end

-- @ama-section: Package service | Trusted removable-media offers and acknowledged transfer.
-- @ama-summary: Compute the Adler-32 checksum of the supplied byte string.
function M.adler32(data, checkpoint)
    if type(data) ~= "string" then return nil, "data must be a string" end
    local a, b = 1, 0
    for index = 1, #data do
        a = (a + string.byte(data, index)) % 65521
        b = (b + a) % 65521
        if checkpoint and index % 8192 == 0 then
            local ok,issue=checkpoint()
            if ok==false then return nil,issue end
        end
    end
    return string.format("%04X%04X", b, a)
end

-- @ama-summary: Calculate the ordered transfer-manifest checksum.
function M.manifestChecksum(entries)
    if type(entries) ~= "table" then return nil, "manifest must be a table" end
    local parts = {}
    for index, entry in ipairs(entries) do
        if type(entry) ~= "table" or type(entry.path) ~= "string"
            or not isInteger(entry.size) or entry.size < 0
            or type(entry.checksum) ~= "string" then
            return nil, "invalid manifest entry " .. tostring(index)
        end
        parts[#parts + 1] = entry.path .. string.char(0) .. tostring(entry.size)
            .. string.char(0) .. entry.checksum .. "\n"
    end
    return M.adler32(table.concat(parts))
end

-- @ama-summary: Build the bounded destination, size, checksum and chunk manifest.
function M.buildManifest(files, chunkBytes, checkpoint)
    if type(files) ~= "table" or not isInteger(chunkBytes) or chunkBytes < 1 then
        return nil, nil, "invalid files or chunk size"
    end
    local entries = {}
    for index, file in ipairs(files) do
        if type(file) ~= "table" or type(file.path) ~= "string" or type(file.data) ~= "string" then
            return nil, nil, "invalid file " .. tostring(index)
        end
        local checksum, err = M.adler32(file.data,checkpoint)
        if not checksum then return nil, nil, err end
        entries[#entries + 1] = {
            path = file.path,
            size = #file.data,
            checksum = checksum,
            chunks = math.max(1, math.ceil(#file.data / chunkBytes)),
            data = file.data,
        }
    end
    local checksum, err = M.manifestChecksum(entries)
    if not checksum then return nil, nil, err end
    return entries, checksum
end

local function validLabel(value)
    return type(value) == "string" and #value > 0 and #value <= 64
        and string.match(value, "^[%w%._%-]+$") ~= nil
end

-- @ama-summary: Validate the role's required configuration fields and operating bounds.
function M.validateConfig(config)
    if type(config) ~= "table" then return nil, "config is not an object" end
    if config.version ~= 2 then return nil, "unsupported installer config version" end
    if config.protocol ~= M.PROTOCOL then return nil, "installer protocol is invalid" end
    if config.chunk_bytes ~= 768 then return nil, "chunk size must be 768" end
    if not isInteger(config.max_file_bytes) or config.max_file_bytes < 1024
        or config.max_file_bytes > 524288 then return nil, "invalid max_file_bytes" end
    if not isInteger(config.max_total_bytes) or config.max_total_bytes < config.max_file_bytes
        or config.max_total_bytes > 2097152 then return nil, "invalid max_total_bytes" end
    if not isInteger(config.timeout_seconds) or config.timeout_seconds < 1
        or config.timeout_seconds > 10 then return nil, "invalid timeout_seconds" end
    if not isInteger(config.max_retries) or config.max_retries < 1
        or config.max_retries > 8 then return nil, "invalid max_retries" end
    if not isInteger(config.poll_seconds) or config.poll_seconds < 1
        or config.poll_seconds > 10 then return nil, "invalid poll_seconds" end
    if not isInteger(config.retry_delay_seconds) or config.retry_delay_seconds < 1
        or config.retry_delay_seconds > 30 then return nil, "invalid retry_delay_seconds" end
    if not isInteger(config.heartbeat_timeout_seconds) or config.heartbeat_timeout_seconds < 10
        or config.heartbeat_timeout_seconds > 60 then return nil, "invalid heartbeat_timeout_seconds" end
    return config
end
-- @ama-summary: Validate the installer's role-to-computer registry.
function M.validateFleet(registry, localComputerID)
    if type(registry) ~= "table" or registry.schemaVersion ~= 1 or type(registry.computers) ~= "table" then
        return nil, "fleet registry schema or computers object is invalid"
    end
    if not isInteger(localComputerID) or localComputerID < 0 then return nil, "local computer ID is invalid" end
    local normalized = { schemaVersion = 1, computers = {} }
    local ids, labels = {}, {}
    for role, entry in pairs(registry.computers) do
        if type(role) ~= "string" or #role < 1 or #role > 64
            or string.match(role, "^[%a][%w_%-]*$") == nil or not ROLE_FILES[role] and role ~= "core" and role ~= "state" then
            return nil, "fleet registry contains an invalid or unsupported role key"
        end
        if type(entry) ~= "table" then return nil, "fleet entry " .. tostring(role) .. " is invalid" end
        if entry.id ~= nil then
            if not isInteger(entry.id) or entry.id < 0 or ids[entry.id] then
                return nil, "fleet entry " .. tostring(role) .. " has an invalid or duplicate ID"
            end
            ids[entry.id] = role
        end
        if entry.label ~= nil then
            if not validLabel(entry.label) or labels[entry.label] then
                return nil, "fleet entry " .. tostring(role) .. " has an invalid or duplicate label"
            end
            labels[entry.label] = role
        end
        normalized.computers[role] = { id = entry.id, label = entry.label }
    end
    local core = normalized.computers.core
    if type(core) ~= "table" or core.id ~= localComputerID or not validLabel(core.label) then
        return nil, "fleet core ID does not match this computer"
    end
    return normalized
end
-- @ama-summary: Resolve and validate the current installation's trusted core identity.
function M.resolveIdentity(registry, targetRole, localComputerID)
    local valid, err = M.validateFleet(registry, localComputerID)
    if not valid then return nil, err end
    if type(targetRole) ~= "string" or not ROLE_FILES[targetRole] then return nil, "target role is unsupported" end
    local core, target = valid.computers.core, valid.computers[targetRole]
    if type(target) ~= "table" or not isInteger(target.id) or not validLabel(target.label) then
        return nil, "fleet role is not currently assigned: " .. targetRole
    end
    return { serverID = core.id, targetID = target.id, serverLabel = core.label,
        targetLabel = target.label, role = targetRole, target = target, core = core }
end
-- @ama-summary: Compare a transfer packet with the current client/server request tokens.
function M.matchesCorrelation(message, kind, context, extra)
    if type(message) ~= "table" or message.v ~= 1 or message.kind ~= kind then return false end
    if message.requestID ~= context.requestID or message.serverSession ~= context.serverSession
        or message.clientSession ~= context.clientSession then return false end
    if extra then
        for key, value in pairs(extra) do
            if message[key] ~= value then return false end
        end
    end
    return true
end

local function shortText(value, maximum)
    return string.sub(tostring(value or ""), 1, maximum)
end

-- @ama-summary: Return the current epoch timestamp used for request expiry.
local function currentEpoch(deps)
    if type(deps.os.epoch) == "function" then
        local ok, value = pcall(deps.os.epoch, "utc")
        if ok and type(value) == "number" then return value end
    end
    if type(deps.os.clock) == "function" then
        local ok, value = pcall(deps.os.clock)
        if ok and type(value) == "number" then return math.floor(value * 1000) end
    end
    return 0
end

-- @ama-summary: Create the install server's bounded transfer-session token.
local function makeServerSession(deps, serverID)
    local seed = currentEpoch(deps)
    local random = 0
    if type(deps.math.random) == "function" then
        local ok, value = pcall(deps.math.random, 1, 2147483646)
        if ok and type(value) == "number" then random = value end
    end
    return tostring(serverID) .. "-" .. tostring(seed) .. "-" .. tostring(random)
end

-- @ama-summary: Render the cached transfer progress for the current installer operation.
local function displayProgress(deps,status,fleet)
    if not deps.progress then return end
    local ok=pcall(function()
        if fleet then deps.progress:setFleet(fleet,ROLE_FILES) end
        deps.progress:update(status)
        deps.progress:draw(status)
    end)
    if not ok then deps.progress=nil end -- A display failure cannot stop installation.
end

-- @ama-summary: Persist the installer's bounded per-role progress record.
local function saveStatus(deps, status)
    displayProgress(deps,status)
    local ok, serialized = pcall(deps.textutils.serializeJSON, status)
    if not ok or type(serialized) ~= "string" or #serialized > 4096 then return false end
    local opened, handle = pcall(deps.fs.open, STATUS_PATH, "w")
    if not opened or not handle then return false end
    local wrote = pcall(handle.write, serialized)
    pcall(handle.close)
    return wrote
end

local function setState(deps, status, state, message)
    status.state = state
    if message ~= nil then status.lastError = shortText(message, 160) end
    status.updatedAt = currentEpoch(deps)
    saveStatus(deps, status)
end

-- @ama-summary: Load and validate the role's configuration file.
local function readConfig(deps)
    local ok, handle = pcall(deps.fs.open, CONFIG_PATH, "r")
    if not ok or not handle then return nil, "cannot open installer config" end
    local readOk, raw = pcall(handle.read, 4097)
    pcall(handle.close)
    if not readOk or type(raw) ~= "string" or #raw > 4096 then
        return nil, "installer config exceeds 4096 bytes or could not be read"
    end
    local decoded, config = pcall(deps.textutils.unserializeJSON, raw)
    if not decoded then return nil, "installer config JSON failed to parse" end
    local valid, err = M.validateConfig(config)
    if not valid then return nil, err end
    return valid
end

-- @ama-summary: Load the installer's current role assignments and core identity.
local function readFleetRegistry(deps, computerID, injectedRegistry)
    local registry = injectedRegistry
    if registry == nil then
        local ok, handle = pcall(deps.fs.open, FLEET_PATH, "r")
        if not ok or not handle then return nil, "cannot open fleet registry " .. FLEET_PATH end
        local readOk, raw = pcall(handle.read, FLEET_MAX_BYTES + 1)
        pcall(handle.close)
        if not readOk or type(raw) ~= "string" or #raw > FLEET_MAX_BYTES then
            return nil, "fleet registry exceeds 8192 bytes or could not be read"
        end
        local decoded, value = pcall(deps.textutils.unserializeJSON, raw)
        if not decoded then return nil, "fleet registry JSON failed to parse" end
        registry = value
    end
    return M.validateFleet(registry, computerID)
end

-- @ama-summary: Open the configured network channels on discovered modems.
local function openModems(deps)
    local ok, names = pcall(deps.peripheral.getNames)
    if not ok or type(names) ~= "table" then return 0 end
    local count = 0
    for _, name in ipairs(names) do
        local typeOk, kind = pcall(deps.peripheral.getType, name)
        if typeOk and kind=="modem" then
            local wrapped,modem=pcall(deps.peripheral.wrap,name)
            local checked,wireless=false,nil
            if wrapped and type(modem)=="table" and type(modem.isWireless)=="function" then checked,wireless=pcall(modem.isWireless) end
            if checked and wireless==true then
                local openOk,result=pcall(deps.rednet.open,name)
                if openOk and result~=false then count=count+1 end
            elseif checked and wireless==false then pcall(deps.rednet.close,name) end
        end
    end
    return count
end

-- @ama-summary: Check the installer's explicit pause marker.
local function pauseRequested(deps)
    if type(deps.fs.exists)~="function" then return false end
    local ok,value=pcall(deps.fs.exists,PAUSE_PATH)
    local probe=deps.timingProbe
    if probe then
        probe.pauseCheckedAt=currentEpoch(deps);probe.pauseChecks=probe.pauseChecks+1
        local paused=not ok or value==true
        if probe.paused~=paused then
            if paused then probe.pauseSeenAt=probe.pauseCheckedAt else probe.resumeSeenAt=probe.pauseCheckedAt end
        end
        probe.paused=paused;probe.pauseError=not ok and tostring(value):sub(1,160) or nil
    end
    return not ok or value==true
end

-- @ama-summary: Resolve the verified media source paths for a role package.
local function sourcePaths(role)
    local definition=ROLE_FILES[role]
    local paths={definition.root.."/manifest.json"}
    for _,destination in ipairs(definition.paths) do
        local source=definition.sources[destination]
        paths[#paths+1]=source:sub(1,1)=="/" and source or definition.root.."/"..source
    end
    return paths
end

-- @ama-summary: Read and verify the requested role package from matching installer media.
local function loadBundle(deps, config, role, checkpoint)
    local definition = ROLE_FILES[role]
    if not definition then return nil, "no package is defined for role " .. tostring(role) end
    -- @ama-summary: Read and decode the selected JSON record.
    local function readJSON(path, maximum)
        local ok, handle = pcall(deps.fs.open, path, "r")
        if not ok or not handle then return nil, "cannot open " .. path end
        local readOk, raw = pcall(handle.read, maximum + 1)
        pcall(handle.close)
        if not readOk or type(raw) ~= "string" or #raw > maximum then return nil, "cannot read bounded JSON " .. path end
        local decoded, value = pcall(deps.textutils.unserializeJSON, raw)
        if not decoded or type(value) ~= "table" then return nil, "invalid JSON in " .. path end
        return value
    end
    local manifest, manifestErr = readJSON(definition.root .. "/manifest.json", 16384)
    if not manifest then return nil, manifestErr end
    if manifest.schemaVersion ~= 1 or manifest.role ~= role or manifest.packageId ~= definition.packageId
        or not isInteger(manifest.version) or manifest.version < 2 or type(manifest.files) ~= "table"
        or #manifest.files ~= #definition.paths then return nil, "package manifest role, ID, version, or file count is invalid" end
    for index, path in ipairs(definition.paths) do
        if manifest.files[index] ~= path then return nil, "package manifest contains a non-allowlisted or out-of-order path" end
    end
    local files, total = {}, 0
    for index, destination in ipairs(definition.paths) do
        if checkpoint then
            local valid,issue=checkpoint()
            if valid==false then return nil,issue end
        end
        local relativeSource = definition.sources[destination]
        local source = relativeSource:sub(1, 1) == "/" and relativeSource or definition.root .. "/" .. relativeSource
        local ok, handle = pcall(deps.fs.open, source, "r")
        if not ok or not handle then return nil, "cannot open bundled file " .. source end
        local readOk, data = pcall(handle.read, config.max_file_bytes + 1)
        pcall(handle.close)
        if not readOk or type(data) ~= "string" then return nil, "cannot read bundled file " .. source end
        if #data > config.max_file_bytes then return nil, "bundled file exceeds max_file_bytes: " .. source end
        total = total + #data
        if total > config.max_total_bytes then return nil, "bundle exceeds max_total_bytes" end
        files[index] = { path = destination, data = data }
    end
    local entries, manifestHash, err = M.buildManifest(files, config.chunk_bytes,checkpoint)
    if not entries then return nil, err end
    return { role = role, packageId = definition.packageId, version = manifest.version,
        entries = entries, manifestChecksum = manifestHash, totalBytes = total }
end
local function sendPacket(deps, config, packet)
    local ok, sent = pcall(deps.rednet.send, config.target_id, packet, config.protocol)
    return ok and sent == true
end

local function receivePacket(deps, config, timeoutSeconds)
    local ok, sender, message = pcall(deps.rednet.receive, config.protocol, timeoutSeconds or config.poll_seconds)
    if not ok then return nil, nil end
    return sender, message
end

-- @ama-summary: Resolve the active core session used for transfer authorization.
local function currentCoreSession(deps, injected, localComputerID)
    if injected and type(injected.coreSession) == "string" then return injected.coreSession end
    local registry = deps.os.__amaryllisFleetRegistry
    if type(registry) == "table" and registry.coreID == localComputerID and type(registry.session) == "string" then
        return registry.session
    end
    return nil
end

local function sameIdentity(fleet, role, targetID, targetLabel)
    local entry = fleet and fleet.computers and fleet.computers[role]
    return type(entry) == "table" and entry.id == targetID and entry.label == targetLabel
end

-- @ama-summary: Check that the current installed identity still matches the transfer snapshot.
local function snapshotMatches(deps, fleet, localComputerID)
    local snapshot = deps.os.__amaryllisFleetRegistry
    if type(snapshot) ~= "table" or snapshot.coreID ~= localComputerID or type(snapshot.computers) ~= "table"
        or type(snapshot.session) ~= "string" or #snapshot.session < 1 or #snapshot.session > 128
        or snapshot.session:match("^[%w_%.%-:]+$") == nil then return false end
    for role, entry in pairs(fleet.computers) do
        local current = snapshot.computers[role]
        if type(current) ~= "table" or current.id ~= entry.id or current.label ~= entry.label then return false end
    end
    return true
end

-- @ama-summary: Validate the role/core authority associated with the active operation.
local function activeAuthority(deps, injectedRegistry)
    local idOK, localComputerID = pcall(deps.os.getComputerID)
    if not idOK or not isInteger(localComputerID) or localComputerID < 0 then
        return nil, nil, "local core computer ID is unavailable"
    end
    local fleet, err = readFleetRegistry(deps, localComputerID, injectedRegistry)
    if not fleet then return nil, nil, err end
    local coreSession = currentCoreSession(deps, injectedRegistry, localComputerID)
    if type(coreSession) ~= "string" or #coreSession < 1 or #coreSession > 128
        or coreSession:match("^[%w_%.%-:]+$") == nil then return nil, nil, "core runtime session is not ready" end
    if not injectedRegistry and not snapshotMatches(deps, fleet, localComputerID) then return nil, nil, "live core registry does not match /fleet.json" end
    return fleet, coreSession
end

local function findRole(fleet, sender)
    for role, entry in pairs(fleet.computers) do
        if role ~= "core" and type(entry) == "table" and entry.id == sender then return role end
    end
end

-- @ama-summary: Revalidate the current identity/session and transfer authorization.
local function checkAuthority(deps, config, injectedRegistry)
    local fleet, coreSession, err = activeAuthority(deps, injectedRegistry)
    if not fleet then return false, err end
    if coreSession ~= config.core_session or not sameIdentity(fleet, config.target_role, config.target_id, config.target_label) then
        return false, "fleet role assignment changed during package transfer"
    end
    local identity = M.resolveIdentity(fleet, config.target_role, config.server_id)
    if not identity or identity.targetID ~= config.target_id or identity.targetLabel ~= config.target_label then
        return false, "fleet role assignment changed during package transfer"
    end
    return true
end

-- @ama-summary: Receive a protocol packet matching the active transfer correlation.
local function receiveMatching(deps, config, predicate)
    local deadline = deps.os.clock() + config.timeout_seconds
    local ignored = 0
    while ignored < 64 do
        local remaining = deadline - deps.os.clock()
        if remaining <= 0 then return nil end
        local sender, message = receivePacket(deps, config, remaining)
        if sender == nil then return nil end
        if config.authorityCheck then
            local valid, issue = config.authorityCheck()
            if not valid then return nil, issue end
        end
        if predicate(sender, message) then return message end
        ignored = ignored + 1
    end
    return nil
end

-- @ama-summary: Wait for the expected transfer response within its request deadline.
local function waitFor(deps, config, outbound, expectedKind, context, extra, status)
    for attempt = 1, config.max_retries do
        if config.authorityCheck then
            local valid, issue = config.authorityCheck()
            if not valid then return nil, issue end
        end
        if sendPacket(deps, config, outbound) then
            local message, issue = receiveMatching(deps, config, function(sender, received)
                return sender == config.target_id and M.matchesCorrelation(received, expectedKind, context, extra)
            end)
            if message then return message end
            if issue then return nil, issue end
        end
        status.retries = status.retries + 1
        status.updatedAt = currentEpoch(deps)
        saveStatus(deps, status)
    end
    return nil, "timed out waiting for " .. expectedKind
end

local function entryComplete(message, context, entry, index)
    return M.matchesCorrelation(message, "fileComplete", context, {
        fileIndex = index, path = entry.path, checksum = entry.checksum,
    })
end

-- @ama-summary: Wait for the receiver's verified file-completion acknowledgement.
local function waitForFileComplete(deps, config, resendPacket, context, entry, index, status)
    for attempt = 1, config.max_retries do
        if config.authorityCheck then
            local valid, issue = config.authorityCheck()
            if not valid then return false, issue end
        end
        if sendPacket(deps, config, resendPacket) then
            local message, issue = receiveMatching(deps, config, function(sender, received)
                return sender == config.target_id and entryComplete(received, context, entry, index)
            end)
            if message then return true end
            if issue then return false, issue end
        end
        status.retries = status.retries + 1
        status.updatedAt = currentEpoch(deps)
        saveStatus(deps, status)
    end
    return false, "timed out waiting for fileComplete"
end

local function replyReject(deps, config, serverSession, clientSession, requestID, reason)
    local packet = { v = 1, kind = "reject", clientSession = clientSession,
        serverSession = serverSession, reason = shortText(reason, 120) }
    if requestID then packet.requestID = requestID end
    sendPacket(deps, config, packet)
end

local function validHello(sender, message, identity)
    return type(message) == "table" and message.v == 1 and message.kind == "hello"
        and message.role == identity.role and message.clientID == sender and sender == identity.targetID
        and type(message.clientSession) == "string" and #message.clientSession > 0 and #message.clientSession <= 128
        and message.clientSession:match("^[%w_%.%-:]+$") ~= nil
end

-- @ama-summary: Build the role package offer with file bounds and transfer correlation.
local function buildOffer(config, bundle, serverSession, clientSession, requestID)
    local offer = {
        v = 1, kind = "offer", requestID = requestID, serverSession = serverSession,
        clientSession = clientSession, role = config.target_role, label = config.target_label,
        computerID = config.target_id, coreID = config.server_id, coreSession = config.core_session,
        packageId = bundle.packageId, version = bundle.version, chunkBytes = config.chunk_bytes,
        manifestChecksum = bundle.manifestChecksum, files = {},
    }
    for index, entry in ipairs(bundle.entries) do
        offer.files[index] = { path = entry.path, size = entry.size, checksum = entry.checksum, chunks = entry.chunks }
    end
    return offer
end

-- @ama-summary: Send and acknowledge the verified package files through the install transaction.
local function transact(deps, config, bundle, serverSession, clientSession, requestID, status)
    local context = { requestID = requestID, serverSession = serverSession, clientSession = clientSession, coreSession = config.core_session }
    status.requestID, status.clientSession = requestID, clientSession
    status.manifestChecksum, status.packageId = bundle.manifestChecksum, bundle.packageId
    status.filesTotal, status.bytesTotal = #bundle.entries, bundle.totalBytes
    status.filesSent, status.chunkIndex, status.fileIndex = 0, 0, 0
    status.bytesSent, status.currentPath = 0, ""
    status.targetRole, status.targetID, status.targetLabel = config.target_role, config.target_id, config.target_label
    status.packageVersion = bundle.version
    status.lastError = ""
    local offer = buildOffer(config, bundle, serverSession, clientSession, requestID)
    setState(deps, status, "offered")
    local ready, readyError = waitFor(deps, config, offer, "ready", context, {
        manifestChecksum = bundle.manifestChecksum, role = config.target_role,
        packageId = bundle.packageId, version = bundle.version,
    }, status)
    if not ready then return false, readyError end

    for fileIndex, entry in ipairs(bundle.entries) do
        local valid, issue = config.authorityCheck()
        if not valid then return false, issue end
        setState(deps, status, "transferring")
        status.currentPath, status.fileIndex, status.chunkIndex = entry.path, fileIndex, 0
        saveStatus(deps, status)
        local finalChunk
        for chunkIndex = 1, entry.chunks do
            valid, issue = config.authorityCheck()
            if not valid then return false, issue end
            local first = (chunkIndex - 1) * config.chunk_bytes + 1
            local packet = { v = 1, kind = "chunk", requestID = requestID,
                serverSession = serverSession, clientSession = clientSession,
                fileIndex = fileIndex, chunkIndex = chunkIndex, chunkCount = entry.chunks,
                path = entry.path, data = string.sub(entry.data, first, first + config.chunk_bytes - 1) }
            status.chunkIndex = chunkIndex
            saveStatus(deps, status)
            local ack, ackError = waitFor(deps, config, packet, "chunkAck", context, {
                fileIndex = fileIndex, chunkIndex = chunkIndex, path = entry.path,
            }, status)
            if not ack then return false, ackError end
            status.bytesSent=status.bytesSent+#packet.data
            finalChunk = packet
        end
        local complete, completeError = waitForFileComplete(deps, config, finalChunk,
            context, entry, fileIndex, status)
        if not complete then return false, completeError end
        status.filesSent, status.currentPath = fileIndex, ""
        saveStatus(deps, status)
    end

    local valid, issue = config.authorityCheck()
    if not valid then return false, issue end
    local commit = { v = 1, kind = "commit", requestID = requestID,
        serverSession = serverSession, clientSession = clientSession,
        manifestChecksum = bundle.manifestChecksum, role = config.target_role,
        label = config.target_label, computerID = config.target_id, coreID = config.server_id,
        coreSession = config.core_session, packageId = bundle.packageId, version = bundle.version }
    setState(deps, status, "committing")
    local expected = { manifestChecksum = bundle.manifestChecksum, role = config.target_role,
        label = config.target_label, computerID = config.target_id, coreID = config.server_id,
        coreSession = config.core_session, packageId = bundle.packageId, version = bundle.version }
    local installed, installError = waitFor(deps, config, commit, "installed", context, expected, status)
    if not installed then return false, installError end
    valid, issue = config.authorityCheck()
    if not valid then return false, issue end

    status.installID, status.installedLabel = requestID, config.target_label
    status.installedVersion, status.installedPackageId = bundle.version, bundle.packageId
    status.installedManifestChecksum = bundle.manifestChecksum
    status.installedRole, status.installedComputerID = config.target_role, config.target_id
    status.installedAt, status.appState = currentEpoch(deps), "awaiting_role_status"
    status.serverSession, status.clientSession, status.coreSession = serverSession, clientSession, config.core_session
    setState(deps, status, "installed")
    local complete = { v = 1, kind = "complete", requestID = requestID,
        serverSession = serverSession, clientSession = clientSession,
        manifestChecksum = bundle.manifestChecksum, role = config.target_role,
        label = config.target_label, computerID = config.target_id, coreID = config.server_id,
        coreSession = config.core_session, packageId = bundle.packageId, version = bundle.version }
    for attempt = 1, config.max_retries do
        if not config.authorityCheck() then break end
        if sendPacket(deps, config, complete) then break end
        status.retries = status.retries + 1
        status.updatedAt = currentEpoch(deps)
        saveStatus(deps, status)
    end
    return true, { context = context, completePacket = complete, manifestChecksum = bundle.manifestChecksum,
        role = config.target_role, targetID = config.target_id, targetLabel = config.target_label }
end

-- @ama-summary: Build role configuration with the assigned core/computer identity.
local function makeTargetConfig(config, identity, coreSession)
    local result = {}
    for key, value in pairs(config) do result[key] = value end
    result.server_id, result.server_label = identity.serverID, identity.serverLabel
    result.target_id, result.target_label = identity.targetID, identity.targetLabel
    result.target_role, result.core_session = identity.role, coreSession
    return result
end

-- @ama-summary: Compare the installed package receipt with the expected package identity.
local function packageIsCurrent(message, bundle, config, status)
    return message.force ~= true and message.installedPackageId == bundle.packageId
        and message.installedVersion == bundle.version
        and message.installedManifestChecksum == bundle.manifestChecksum
        and message.installedLabel == config.target_label
        and message.installedComputerID == config.target_id
        and message.installedRole == config.target_role
end

-- @ama-summary: Notify the receiver that its verified package is current.
local function sendCurrent(deps, config, bundle, clientSession, serverSession)
    return sendPacket(deps, config, {
        v = 1, kind = "current", clientSession = clientSession,
        serverSession = serverSession, role = config.target_role,
        label = config.target_label, computerID = config.target_id,
        coreID = config.server_id, coreSession = config.core_session,
        packageId = bundle.packageId, version = bundle.version,
        manifestChecksum = bundle.manifestChecksum,
    })
end

local function shouldStop(deps)
    if type(deps.shouldStop) ~= "function" then return false end
    local ok, stop = pcall(deps.shouldStop)
    return ok and stop == true
end

local function removeCacheKey(order, cacheKey)
    for index = #order, 1, -1 do
        if order[index] == cacheKey then table.remove(order, index) end
    end
end

-- @ama-summary: Run the core package service against current fleet authority and removable media.
function M.run(injected)
    injected = injected or {}
    local deps = {
        fs = injected.fs or fs, peripheral = injected.peripheral or peripheral,
        rednet = injected.rednet or rednet, textutils = injected.textutils or textutils,
        os = injected.os or os, math = injected.math or math,
        sleep = injected.sleep or sleep, print = injected.print or print,
        shouldStop = injected.shouldStop, progress=injected.progress,
    }
    if not injected.fs then
        deps.timingProbe={startedAt=currentEpoch(deps),pauseChecks=0}
        os.__amaryllisInstallerProbe=function()
            local out={};for k,v in pairs(deps.timingProbe) do out[k]=v end;return out
        end
    end
    local media
    if not injected.fs then
        media=assert(loadfile("/installer/media.lua",nil,_ENV))().new(deps.fs,peripheral,disk,textutils,sleep)
        deps.fs=media.fs
    end
    local bundleCache=injected.bundleCache
    if not bundleCache and not injected.fs then
        local ok,cache=pcall(function()
            return assert(loadfile("/installer/bundle_cache.lua",nil,_ENV))().new(deps.fs,deps.os.clock)
        end)
        if ok then bundleCache=cache end
    end
    if not deps.progress and not injected.fs and type(term)=="table" then
        local ok,view=pcall(function()
            return assert(loadfile("/installer/progress.lua",nil,_ENV))().new(term,deps.os.clock)
        end)
        if ok then deps.progress=view end
    end
    local idOK, computerID = pcall(deps.os.getComputerID)
    if not idOK or not isInteger(computerID) or computerID < 0 then return false, "installer service needs a valid local computer ID" end
    local status = { schemaVersion = 2, computerID = computerID, protocol = M.PROTOCOL,
        fleetSource = FLEET_PATH, state = "starting", appState = "not_installed",
        bundleCacheEnabled=bundleCache~=nil,
        retries = 0, lastError = "", updatedAt = currentEpoch(deps) }
    saveStatus(deps, status)
    local initialFleet=readFleetRegistry(deps,computerID,injected.registry)
    if initialFleet then displayProgress(deps,status,initialFleet) end
    local config, configError = readConfig(deps)
    if not config then setState(deps, status, "configuration_error", configError); return false, configError end
    config.server_id = computerID
    local serverSession = makeServerSession(deps, computerID)
    status.serverSession = serverSession
    setState(deps, status, "waiting_for_modem")
    local requestCounter, retryCount = 0, 0
    local completed, completedOrder = {}, {}
    local modemCount = 0

    while not shouldStop(deps) do
        if deps.timingProbe then deps.timingProbe.loopAt=currentEpoch(deps);deps.timingProbe.state=status.state end
        displayProgress(deps,status)
        if pauseRequested(deps) then
            if status.state~="paused" then setState(deps,status,"paused","") end
            deps.sleep(2)
        elseif media and not media:refresh() then
            setState(deps,status,"waiting_for_media",media.issue)
            deps.sleep(2)
        else
        modemCount = openModems(deps)
        status.modemCount = modemCount
        if modemCount == 0 then
            retryCount = retryCount + 1
            status.retryCount = retryCount
            setState(deps, status, "no_modem", "no wireless modem; retrying")
            if not deps.progress then pcall(deps.print, "No modem found; retry " .. tostring(retryCount)) end
            pcall(deps.sleep, config.retry_delay_seconds)
        else
            if status.state == "no_modem" or status.state == "waiting_for_modem" or status.state=="paused" or status.state=="waiting_for_media" then setState(deps, status, "waiting_for_client","") end
            local sender, message = receivePacket(deps, config, config.poll_seconds)
            if not pauseRequested(deps) and isInteger(sender) and sender ~= computerID and type(message) == "table" and message.v == 1 then
                if message.kind == "hello" then
                    local fleet, coreSession, authorityError = activeAuthority(deps, injected.registry)
                    if not fleet then
                        setState(deps, status, "fleet_registry_error", authorityError)
                        if type(message.clientSession) == "string" then
                            local rejectConfig = { protocol = config.protocol, target_id = sender }
                            sendPacket(deps, rejectConfig, { v = 1, kind = "reject", clientSession = shortText(message.clientSession, 128), serverSession = serverSession, reason = shortText(authorityError, 120) })
                        end
                    else
                        displayProgress(deps,status,fleet)
                        local role = findRole(fleet, sender)
                        local identity = role and M.resolveIdentity(fleet, role, computerID) or nil
                        if not identity or not validHello(sender, message, identity) then
                            status.rejectedHelloCount = (status.rejectedHelloCount or 0) + 1
                            setState(deps, status, "rejected_hello", "sender ID and role do not match /fleet.json")
                        else
                            local targetConfig = makeTargetConfig(config, identity, coreSession)
                            local mediaGeneration=media and media.generation
                            -- @ama-summary: Recheck the active session and assigned role before the next transfer step.
                            targetConfig.authorityCheck = function()
                                if media and not media:valid(mediaGeneration) then return false,"installer disk removed or changed; transfer retired" end
                                if pauseRequested(deps) then return false,"installer paused; transfer retired" end
                                local freshFleet, freshSession, freshError = activeAuthority(deps, injected.registry)
                                if not freshFleet then return false, freshError end
                                if freshSession ~= coreSession or not sameIdentity(freshFleet, role, sender, identity.targetLabel) then
                                    return false, "fleet assignment changed; transfer retired"
                                end
                                return true
                            end
                            -- @ama-summary: Capture the resumable operation state for an intentional systems restart.
                            local function checkpoint()
                                if deps.timingProbe then deps.timingProbe.workAt=currentEpoch(deps) end
                                if media and not media:valid(mediaGeneration) then return false,"installer disk removed or changed; package verification retired" end
                                if pauseRequested(deps) then return false,"installer paused; package verification retired" end
                                deps.sleep(0)
                                if media and not media:valid(mediaGeneration) then return false,"installer disk removed or changed; package verification retired" end
                                if pauseRequested(deps) then return false,"installer paused; package verification retired" end
                                return true
                            end
                            local function prepareBundle()
                                status.targetID,status.targetRole,status.targetLabel=sender,role,identity.targetLabel
                                status.coreSession=coreSession
                                setState(deps,status,"checking","")
                                return loadBundle(deps,config,role,checkpoint)
                            end
                            local bundle,bundleError
                            if bundleCache then
                                local key=role..":"..config.chunk_bytes..":"..config.max_file_bytes..":"..config.max_total_bytes
                                bundle,bundleError=bundleCache:get(key,sourcePaths(role),prepareBundle,message.force==true)
                                status.bundleCacheHits,status.bundleCacheMisses=bundleCache.hits,bundleCache.misses
                                status.bundleCacheBytes=bundleCache.bytes
                            else bundle,bundleError=prepareBundle() end
                            -- A cached payload cannot grant stale fleet authority after a yielding build.
                            local authorityValid,authorityIssue=targetConfig.authorityCheck()
                            if not authorityValid then bundle,bundleError=nil,authorityIssue end
                            if not bundle then
                                setState(deps, status, pauseRequested(deps) and "paused" or "bundle_error", bundleError)
                            else
                                status.targetID, status.targetRole, status.targetLabel = sender, role, identity.targetLabel
                                status.coreSession, status.packageId, status.packageVersion = coreSession, bundle.packageId, bundle.version
                                status.manifestChecksum, status.bytesTotal = bundle.manifestChecksum, bundle.totalBytes
                                status.filesTotal = #bundle.entries
                                saveStatus(deps, status)
                                local clientSession = message.clientSession
                                local cacheKey = tostring(sender) .. ":" .. clientSession
                                if packageIsCurrent(message, bundle, targetConfig, status) then
                                    sendCurrent(deps, targetConfig, bundle, clientSession, serverSession)
                                    setState(deps, status, "current")
                                else
                                    -- One client boot can install multiple package generations.
                                    -- Retire cached completion/rejection state before evaluating a
                                    -- new offer so changed source checksums, labels, and explicit
                                    -- reinstalls are not pinned to the first request in that boot.
                                    completed[cacheKey] = nil
                                    removeCacheKey(completedOrder, cacheKey)
                                    requestCounter = requestCounter + 1
                                    local requestID = serverSession .. "-" .. tostring(requestCounter)
                                    status.bytesSent,status.filesSent,status.fileIndex,status.chunkIndex,status.currentPath=0,0,0,0,""
                                    setState(deps, status, "transferring")
                                    local ok, result = transact(deps, targetConfig, bundle, serverSession, clientSession, requestID, status)
                                    completedOrder[#completedOrder + 1] = cacheKey
                                    if #completedOrder > 32 then
                                        local expired = table.remove(completedOrder, 1)
                                        completed[expired] = nil
                                    end
                                    if ok then
                                        completed[cacheKey] = result
                                        setState(deps, status, "installed")
                                    else
                                        status.appState = "not_installed"
                                        setState(deps, status, "transfer_failed", result)
                                        replyReject(deps, targetConfig, serverSession, clientSession, requestID, result)
                                    end
                                end
                            end
                        end
                    end
                elseif message.kind == "installed" then
                    local cacheKey = tostring(sender) .. ":" .. tostring(message.clientSession)
                    local prior = completed[cacheKey]
                    local freshFleet, freshSession = activeAuthority(deps, injected.registry)
                    if prior and freshFleet and freshSession == prior.context.coreSession
                        and sameIdentity(freshFleet, prior.role, sender, prior.targetLabel)
                        and M.matchesCorrelation(message, "installed", prior.context, {
                            manifestChecksum = prior.manifestChecksum, role = prior.role,
                            label = prior.targetLabel,
                        }) then
                        local target = { protocol = config.protocol, target_id = sender }
                        sendPacket(deps, target, prior.completePacket)
                    end
                end
            end
        end
        end
    end
    setState(deps, status, "stopped")
    return true, status
end

return M
