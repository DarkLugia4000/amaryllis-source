-- @ama-section: Diagnostic client | Bounded inventory, cached status and permitted read requests.
-- Amaryllis's shared diagnostic client, installed locally on every node.
-- Reads inventory, explicitly approved getters, cached runtime state and the
-- bounded console log. It never loads flight code or writes vessel hardware.
-- Sections: identity/limits, safe serialization, readers, request dispatch,
-- WebSocket service and independent reconnect loop. All network calls yield.
local ENDPOINT = "ws://127.0.0.1:8765/computer"
local MAX_FILE_BYTES = 16 * 1024
local MAX_VALUE_DEPTH = 5
local MAX_TABLE_ITEMS = 128
local DIAGNOSTIC_OWNER_KEY = "__amaryllisDiagnosticOwner"
local diagnosticOwner = {}
local ownerStored = false
if type(os) == "table" then
    ownerStored = pcall(function() os[DIAGNOSTIC_OWNER_KEY] = diagnosticOwner end)
end

local function isDiagnosticOwner()
    if not ownerStored then return true end
    local ok, owner = pcall(function() return os[DIAGNOSTIC_OWNER_KEY] end)
    return ok and owner == diagnosticOwner
end

local ROLE_LABELS = {
    ["thrust-lb"]="thrust-lb",["thrust-rb"]="thrust-rb",["thrust-ls"]="thrust-ls",["thrust-rs"]="thrust-rs",
    core="core",state="state",navigator="navigator",["heading-left"]="heading-left",
    ["heading-right"]="heading-right",["heading-main"]="heading-main",
    chamber_fl="chamber_fl",chamber_fr="chamber_fr",chamber_bl="chamber_bl",
    chamber_br="chamber_br",primary_l="primary_l",primary_r="primary_r",
}

-- @ama-section: Diagnostic client | Bounded inventory, cached status and permitted read requests.
-- @ama-summary: Validate this diagnostic client's installed role and computer identity.
local function localIdentity()
    local id,label
    local ok,value=pcall(os.getComputerID);if ok then id=value end
    ok,value=pcall(os.getComputerLabel);if ok then label=value end
    local identity=os.__amaryllisIdentity
    if type(identity)=="table" and identity.computerID==id and identity.label==label and
        type(identity.role)=="string" then
        return identity.role,id,label,identity.verified~=false
    end
    local registry=os.__amaryllisFleetRegistry
    if type(registry)~="table" or type(registry.computers)~="table" then return nil,id,label,false end
    local role=registry.coreID==id and "core" or nil
    local entry=role and registry.computers.core or nil
    if not role then
        for key,item in pairs(registry.computers) do
            if type(item)=="table" and item.id==id then role=key;entry=item;break end
        end
    end
    local valid=role~=nil and role=="core" and entry and entry.label==label or
        role~=nil and role~="core" and entry and entry.label==label
    return role,id,label,valid==true
end

local READ_METHODS = {
    getAngularRates = true,
    getAngles = true,
    getHeading = true,
    getHeight = true,
    getVerticalSpeed = true,
    getSpeed = true,
    getThrustHandedness = true,
    getMass = true,
    isAssembled = true,
    getAirPressure = true,
    getCenterOfMass = true,
    getInertiaTensor = true,
    getGravity = true,
    getLinearAcceleration = true,
    getGasOutput = true,
    isActive = true,
    getSignalStrength = true,
    getGasType = true,
    getTargetAmount = true,
    getBoilerEfficiency = true,
    hasBalloon = true,
    getBalloonLift = true,
    getBalloonHeight = true,
    getBalloonFilledVolume = true,
    getBalloonCapacity = true,
    getBalloonTargetVolume = true,
    getBalloonVolumeChange = true,
    getBalloonGasMix = true,
    getShiftLevel = true,
    getThrustVector = true,
    getThrust = true,
    getVelocity = true, getAxis = true, getOrientation = true,
    getTransmissionMode = true, getAnglesRad = true, getAngularRatesRad = true,
    getRotationSpeed = true, getAirflow = true, isOverstressed = true,
    hasSource = true, hasTarget = true, getBearing = true,
    getDistanceToTarget = true, getClosureRate = true,
    getVerticalOffsetToTarget = true, getTargetType = true, getTargetMetadata = true,
}
local activeSocket
local lastError

local function jsonEncode(value)
    return textutils.serializeJSON(value)
end

local function jsonDecode(value)
    local ok, decoded = pcall(textutils.unserializeJSON, value)
    if not ok then return nil end
    return decoded
end

-- @ama-summary: Convert diagnostic values into bounded serializable fields.
local function safeValue(value, depth, seen)
    local kind = type(value)
    if kind == "nil" or kind == "boolean" then return value end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return tostring(value) end
        return value
    end
    if kind == "string" then return string.sub(value, 1, 4096) end
    if kind ~= "table" then return string.sub(tostring(value), 1, 256) end
    if depth >= MAX_VALUE_DEPTH then return "<maximum depth>" end
    if seen[value] then return "<cycle>" end

    seen[value] = true
    local result, count = {}, 0
    for key, item in pairs(value) do
        if count >= MAX_TABLE_ITEMS then break end
        if type(key) == "string" and #key <= 128 then
            result[key] = safeValue(item, depth + 1, seen)
            count = count + 1
        elseif type(key) == "number" and key % 1 == 0 and key >= 1 and key <= MAX_TABLE_ITEMS then
            result[key] = safeValue(item, depth + 1, seen)
            count = count + 1
        end
    end
    seen[value] = nil
    return result
end

-- @ama-summary: Collect a bounded inventory of attached peripheral names and types.
local function listPeripherals()
    local names = peripheral.getNames()
    table.sort(names)
    local result = {}
    for _, name in ipairs(names) do
        result[#result + 1] = { name = name, type = peripheral.getType(name), types = { peripheral.getType(name) } }
    end
    return result
end

local function peripheralExists(target)
    if type(target) ~= "string" or #target == 0 or #target > 128 then return false end
    for _, name in ipairs(peripheral.getNames()) do
        if name == target then return true end
    end
    return false
end

-- @ama-summary: Validate a diagnostic file path against the permitted read locations.
local function validReadPath(path)
    if type(path) ~= "string" or #path > 256 or string.sub(path, 1, 10) ~= "/avionics/" or
        path:find("\\", 1, true) or path:find("\0", 1, true) or path:find(":", 1, true) or
        path:find("//", 1, true) or path:sub(-1) == "/" then return false end
    for part in path:gmatch("[^/]+") do
        if part == "." or part == ".." or part:lower() == "agents.md" or part:lower() == ".agents" then
            return false
        end
    end
    return true
end

-- @ama-summary: Read a permitted diagnostic file with bounded output.
local function readDiagnosticFile(path)
    if not validReadPath(path) then return nil, "invalid /avionics/ text path" end
    local file, openError = fs.open(path, "r")
    if not file then return nil, tostring(openError or "could not open file") end
    local ok, content = pcall(file.read, MAX_FILE_BYTES + 1)
    pcall(file.close)
    if not ok then return nil, tostring(content) end
    if content == nil then return "" end
    if type(content) ~= "string" then return nil, "file did not return text" end
    if #content > MAX_FILE_BYTES then return nil, "file exceeds 16 KiB" end
    if string.find(content, "\0", 1, true) then return nil, "binary files are not supported" end
    return content
end

-- @ama-summary: Collect the available terminal-tab identities for diagnostics.
local function listMultishellTabs()
    local api = multishell
    if type(api) ~= "table" or type(api.getCount) ~= "function" or type(api.getTitle) ~= "function" then
        return 1, { "<unavailable>" }
    end
    local countOk, count = pcall(api.getCount)
    if not countOk or type(count) ~= "number" or count < 1 or count % 1 ~= 0 then
        return 1, { "<unavailable>" }
    end
    local titles = {}
    for index = 1, math.min(count, 64) do
        local titleOk, title = pcall(api.getTitle, index)
        if titleOk and type(title) == "string" then
            titles[#titles + 1] = string.sub(title, 1, 128)
        else
            titles[#titles + 1] = "<unknown>"
        end
    end
    return count, titles
end

-- @ama-summary: Dispatch a validated diagnostic request to its bounded read handler.
local function execute(command, args)
    if type(command) ~= "string" or type(args) ~= "table" then
        return false, "invalid command envelope"
    end
    -- Validate again onboard, even though the host already validates requests.
    local allowedArgs = ({ peripheral_methods = { name = true },
        peripheral_read = { name = true, method = true }, read_file = { path = true },
        sublevel_read = { method = true } })[command] or {}
    for key in pairs(args) do
        if not allowedArgs[key] then return false, "unexpected diagnostic argument" end
    end
    if command == "ping" then
        return true, { pong = true }
    elseif command == "console" then
        if next(args) ~= nil then return false, "console does not accept args" end
        local cached = os.__amaryllisDiagnostics
        if type(cached) ~= "table" then return false, "restart the role through /startup.lua to capture console" end
        return true, safeValue({ entries = cached.console, running = cached.running }, 0, {})
    elseif command == "runtime_status" then
        local cached = os.__amaryllisRuntime
        if type(cached) ~= "table" then return false, "onboard role has not published runtime status" end
        -- Age is local receipt/publication age. It does not make stale sensor
        -- data fresh; the snapshot's own validity/freshness fields are retained.
        local stateProbe
        if type(cached.stateProbe)=="function" then
            local ok,value=pcall(cached.stateProbe)
            stateProbe=ok and value or {error=tostring(value)}
        end
        return true, safeValue({ snapshot = cached.snapshot, stateProbe=stateProbe,publishedAt = cached.publishedAt,sampling=cached.sampling,
            recoveryProbe=os.__amaryllisRecoveryProbe,
            ageSeconds = os.clock() - cached.publishedAt,
            running = type(os.__amaryllisDiagnostics) == "table" and os.__amaryllisDiagnostics.running == true }, 0, {})
    elseif command == "sublevel_read" then
        local methods = {
            isInPlotGrid = true, getUniqueId = true, getLogicalPose = true,
            getLinearVelocity = true, getAngularVelocity = true, getMass = true,
            getCenterOfMass = true, getInertiaTensor = true,
        }
        local method = args.method
        for key in pairs(args) do
            if key ~= "method" then return false, "sublevel_read only accepts method" end
        end
        if type(method) ~= "string" or not methods[method] then return false, "sublevel getter is not allowed" end
        if type(sublevel) ~= "table" or type(sublevel[method]) ~= "function" then
            return false, "sublevel getter is unavailable"
        end
        local ok, value = pcall(sublevel[method])
        if not ok then return false, tostring(value) end
        return true, safeValue(value, 0, {})
    elseif command == "status" then
        local capabilities = { "peripherals", "peripheral_methods", "peripheral_read", "sublevel_read", "read_file", "console", "runtime_status" }
        local tabCount, tabTitles = listMultishellTabs()
        return true, {
            label = os.getComputerLabel(),
            id = os.getComputerID(),
            uptime = os.clock(),
            diskCapacityBytes=type(fs.getCapacity)=="function" and fs.getCapacity("/") or nil,
            diskFreeBytes=fs.getFreeSpace("/"),
            capabilities = capabilities,
            tabCount = tabCount,
            tabTitles = tabTitles,
        }
    elseif command == "peripherals" then
        local ok, result = pcall(listPeripherals)
        if not ok then return false, tostring(result) end
        return true, result
    elseif command == "peripheral_methods" then
        local name = args.name
        if not peripheralExists(name) then return false, "unknown peripheral" end
        local ok, methods = pcall(peripheral.getMethods, name)
        if not ok then return false, tostring(methods) end
        table.sort(methods)
        return true, methods
    elseif command == "read_file" then
        local content, reason = readDiagnosticFile(args.path)
        if not content then return false, reason end
        return true, { path = args.path, content = content }
    elseif command == "peripheral_read" then
        local name, method = args.name, args.method
        if not peripheralExists(name) then return false, "unknown peripheral" end
        if type(method) ~= "string" or not READ_METHODS[method] then
            return false, "method is not on the read-only allowlist"
        end
        local ok, value = pcall(peripheral.call, name, method)
        if not ok then return false, tostring(value) end
        local result = safeValue(value, 0, {})
        local encodedOk, encoded = pcall(jsonEncode, result)
        if not encodedOk or type(encoded) ~= "string" or #encoded > MAX_FILE_BYTES then
            return false, "peripheral response exceeds 16 KiB or is not JSON-safe"
        end
        return true, result
    end
    return false, "unsupported diagnostic command"
end

local function closeSocket(socket)
    if socket then pcall(socket.close) end
end
-- The basic-computer boot worker may end while this task is waiting. Give
-- startup an explicit socket cleanup hook without granting hardware access.
os.__amaryllisCloseDiagnostic = function() closeSocket(activeSocket) end

-- @ama-summary: Connect the read-only diagnostic client and serve correlated host requests.
local function connectAndServe()
    if not isDiagnosticOwner() then return end
    local role,id,label,identityValid=localIdentity()
    if not role or type(label)~="string" or not identityValid then
        error("computer ID/label does not match the current Amaryllis fleet registry", 0)
    end

    if type(http) ~= "table" or type(http.websocket) ~= "function" then
        error("ComputerCraft WebSocket API is unavailable", 0)
    end
    local socket, reason = http.websocket(ENDPOINT, { ["X-CC-Diagnostic"] = "v1" })
    if not socket then error(tostring(reason or "WebSocket connection failed"), 0) end
    activeSocket = socket
    if not isDiagnosticOwner() then
        closeSocket(socket)
        return
    end

    local hello = {
        type = "hello",
        label = label,
        id = id,
        role = ROLE_LABELS[role],
    }
    local sent, sendError = pcall(socket.send, jsonEncode(hello))
    if not sent then
        closeSocket(socket)
        error(tostring(sendError), 0)
    end

    local nextHeartbeat=os.clock()+3
    local heartbeatTimer=os.startTimer(3)
    while true do
        if not isDiagnosticOwner() then
            closeSocket(socket)
            return
        end
        local currentRole,currentID,currentLabel,currentValid=localIdentity()
        if currentID~=id or currentLabel~=label or currentRole~=role or not currentValid then
            closeSocket(socket)
            return
        end
        -- Receive directly from this tab queue. A timed socket.receive call
        -- can itself become stranded when its timeout event is lost.
        local event,url,message,binary=os.pullEventRaw()
        if event=="terminate" then closeSocket(socket);error("Terminated",0) end
        if event=="websocket_closed" and url==ENDPOINT then
            closeSocket(socket);error(tostring(message or "diagnostic bridge connection closed"),0)
        end
        if event~="websocket_message" or url~=ENDPOINT then message=nil end
        if not isDiagnosticOwner() then
            closeSocket(socket)
            return
        end
        if os.clock()>=nextHeartbeat then
            local heartbeatSent = pcall(socket.send, jsonEncode({ type = "heartbeat" }))
            if not heartbeatSent then
                error("diagnostic bridge connection closed", 0)
            end
            pcall(os.cancelTimer,heartbeatTimer)
            nextHeartbeat=os.clock()+3;heartbeatTimer=os.startTimer(3)
        end
        if message~=nil and not binary then
            local request = jsonDecode(message)
            if type(request) == "table" and request.type == "ready" then
                lastError = nil
                print("Connected to local diagnostic bridge as " .. label .. ".")
            elseif type(request) == "table" and request.type == "command" and
                type(request.id) == "string" and #request.id <= 64 then
                if not isDiagnosticOwner() then
                    closeSocket(socket)
                    return
                end
                local called, ok, result = pcall(execute, request.command, request.args or {})
                if not called then ok, result = false, tostring(ok) end
                local response = { type = "response", id = request.id, ok = ok }
                if ok then
                    response.result = result
                else
                    response.error = tostring(result)
                end
                if not isDiagnosticOwner() then
                    closeSocket(socket)
                    return
                end
                -- Every response has a bounded JSON payload, including status,
                -- inventory and logs. Oversized/unsupported data becomes a fault.
                local encodedOk, encoded = pcall(jsonEncode, response)
                if not encodedOk or type(encoded) ~= "string" or #encoded > 48 * 1024 then
                    encoded = jsonEncode({ type = "response", id = request.id, ok = false,
                        error = "diagnostic response is too large or not JSON-safe" })
                end
                local responseSent = pcall(socket.send, encoded)
                if not responseSent then
                    closeSocket(socket)
                    return
                end
            end
        end
    end
end

-- Fake-hardware tests can inspect dispatch without starting a connection.
if rawget(_G, "__AMARYLLIS_DIAGNOSTIC_TEST") == true then
    return { execute = execute, safeValue = safeValue, validReadPath = validReadPath,
        roles = ROLE_LABELS, readMethods = READ_METHODS }
end

print("Amaryllis read-only diagnostic client started; Ctrl+T stops this task.")
while isDiagnosticOwner() do
    local ok, reason = pcall(connectAndServe)
    closeSocket(activeSocket)
    activeSocket = nil
    if not isDiagnosticOwner() then break end
    if not ok and string.find(tostring(reason), "Terminated", 1, true) then break end
    if not ok then
        local message = tostring(reason)
        if message ~= lastError then
            print("Diagnostic bridge unavailable: " .. message)
            lastError = message
        end
    end
    if not isDiagnosticOwner() then break end
    local retryAt=os.clock()+3
    local retryTimer=os.startTimer(3)
    while isDiagnosticOwner() and os.clock()<retryAt do
        local event=os.pullEventRaw()
        if event=="terminate" then return end
    end
    pcall(os.cancelTimer,retryTimer)
end
print("Amaryllis diagnostic client stopped.")
