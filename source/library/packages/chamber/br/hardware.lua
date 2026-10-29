-- @ama-section: Chamber hardware | Discovered provider/drive bindings and validated peripheral operations.
-- Combined chamber hardware. Keep lift and thrust adapters isolated so each
-- component has one hardware API and one writer boundary.
local basePeripheralApi = peripheral
local function splitRemote(name)
    if type(name) ~= "string" then return nil end
    local side, remoteName = name:match("^@remote:([^:]+):(.+)$")
    if side and remoteName then return side, remoteName end
end
-- @ama-section: Endpoint context | Configuration, discovery and command identity.
-- @ama-summary: Construct the configured remote-peripheral facade and its method routing.
local function makeRemotePeripheralApi(base, remoteSides, includeLocal)
    base=base or basePeripheralApi
    local sides,modems={},{}
    for _,side in ipairs(remoteSides or {}) do if type(side)=="string" and side:match("^[a-z]+$") then sides[#sides+1]=side end end
    table.sort(sides)
    local function modemFor(side)
        if modems[side] then return modems[side] end
        local ok,obj=pcall(base.wrap,side)
        if ok and type(obj)=="table" and type(obj.getNamesRemote)=="function" then modems[side]=obj;return obj end
    end
    local function remoteNames(side)
        local modem=modemFor(side);if not modem then return {} end
        local ok,names=pcall(modem.getNamesRemote);if not ok or type(names)~="table" then return {} end;return names
    end
    local function route(name)
        local side,remoteName=splitRemote(name);if side and remoteName then return modemFor(side),remoteName,side end
    end
    local function containsType(value,expected)
        if type(value)=="string" then return value==expected end
        if type(value)=="table" then
            for _,kind in ipairs(value) do if kind==expected then return true end end
        end
        return false
    end
    local function returnedTypeMatches(expected,...)
        for i=1,select("#",...) do
            if containsType(select(i,...),expected) then return true end
        end
        return false
    end
    local api={}
    -- @ama-summary: Return the peripheral names exposed by the configured facade.
    function api.getNames()
        local result,seen={},{}
        if includeLocal ~= false then
            local ok,names=pcall(base.getNames);if not ok or type(names)~="table" then return nil,names end
            for _,name in ipairs(names) do if type(name)=="string" and not seen[name] then result[#result+1]=name;seen[name]=true end end
        end
        for _,side in ipairs(sides) do for _,name in ipairs(remoteNames(side)) do if type(name)=="string" then local key="@remote:"..side..":"..name;if not seen[key] then result[#result+1]=key;seen[key]=true end end end end
        table.sort(result);return result
    end
    function api.getRouteSide(name) local _,_,side=route(name);if side then return side end;for _,candidate in ipairs(sides) do if name==candidate then return candidate end end end
    function api.getType(name) local modem,remoteName=route(name);if modem then return modem.getTypeRemote(remoteName) end;return base.getType(name) end
    -- @ama-summary: Check the exposed peripheral's reported type.
    function api.hasType(name,expected)
        local modem,remoteName=route(name)
        if modem then
            if type(modem.hasTypeRemote)=="function" then
                return modem.hasTypeRemote(remoteName,expected)
            end
            return returnedTypeMatches(expected,modem.getTypeRemote(remoteName))
        end
        if type(base.hasType)=="function" then return base.hasType(name,expected) end
        return returnedTypeMatches(expected,base.getType(name))
    end
    function api.getMethods(name) local modem,remoteName=route(name);if modem then return modem.getMethodsRemote(remoteName) end;return base.getMethods(name) end
    function api.call(name,method,...) local modem,remoteName=route(name);if modem then return modem.callRemote(remoteName,method,...) end;return base.call(name,method,...) end
    function api.wrap(name)
        local modem,remoteName=route(name);if not modem then return base.wrap(name) end
        local ok,methods=pcall(modem.getMethodsRemote,remoteName);if not ok or type(methods)~="table" then return nil end
        local object={};for _,method in ipairs(methods) do if type(method)=="string" then object[method]=function(...) return modem.callRemote(remoteName,method,...) end end end;return object
    end
    return api
end
-- @ama-summary: Build getter/setter bindings for the supported lift hardware interface.
local function buildLiftAdapter()--[[
Hardware adapter for the Amaryllis lift quadrant computers.

Responsibilities:
  * Load and validate this node's JSON identity, provider allowlist, and bounds.
  * Inspect peripherals through the installed CC peripheral API.
  * Read telemetry and perform target writes only when main.lua explicitly asks.

Units and assumptions:
  * setTargetAmount/getTargetAmount values are integers. This matches the
    inspected Create Avionics source; installed-version behavior still needs
    in-game verification before commissioning.
  * getGasOutput is reported as supplied by the peripheral (documented as m^3
    per game tick). This module does not turn gas output into lift.
  * A single configured balloonRepresentative supplies balloon telemetry. We
    never add lift values from several gas providers, since they can refer to
    the same balloon.
  * Scanning and sampling are read-only. This adapter's applyTarget wrapper
    is the only function that invokes a setter, and main.lua calls it only
    from the guarded applyCommand path.
]]
local Hardware = {}

local MAX_TARGET = 2147483647
local MAX_CONFIGURED_PROVIDERS = 64
local SYSTEMS_HANDOVER_TIMEOUT_SECONDS = 4
local SYSTEMS_HANDOVER_POLL_INTERVAL_SECONDS = 0.1
local SYSTEMS_HANDOVER_MAX_POLLS = 48
local REQUIRED_PROVIDER_METHODS = {
    "getTargetAmount",
    "setTargetAmount",
    "getGasOutput",
    "getSignalStrength",
    "hasBalloon",
}

local EXPECTED_ROLES = {
    chamber_fl = { quadrant = "FL", first = "minecraft:yellow_wool", second = "minecraft:lime_wool", trim = "minecraft:lime_wool", packageId = "amaryllis.chamber.fl" },
    chamber_fr = { quadrant = "FR", first = "minecraft:red_wool", second = "minecraft:orange_wool", trim = "minecraft:blue_wool", packageId = "amaryllis.chamber.fr" },
    chamber_bl = { quadrant = "RL", first = "minecraft:lime_wool", second = "minecraft:yellow_wool", trim = "minecraft:red_wool", packageId = "amaryllis.chamber.bl" },
    chamber_br = { quadrant = "RR", first = "minecraft:orange_wool", second = "minecraft:red_wool", trim = "minecraft:purple_wool", packageId = "amaryllis.chamber.br" },
}

local function finite(value)
    return type(value) == "number" and value == value and
        value ~= math.huge and value ~= -math.huge
end

local function integer(value)
    return finite(value) and value % 1 == 0
end

local function appendError(errors, message)
    errors[#errors + 1] = message
end

-- @ama-summary: Invoke the selected peripheral method and retain its result or error.
local function callApi(api, functionName, ...)
    local method = api and api[functionName]
    if type(method) ~= "function" then
        return false, "peripheral." .. functionName .. " is unavailable"
    end
    local packed = { pcall(method, ...) }
    if not packed[1] then return false, tostring(packed[2]) end
    return true, packed[2]
end

local function callPeripheral(api, name, method, ...)
    return callApi(api, "call", name, method, ...)
end

local function contains(list, expected)
    for _, value in ipairs(list or {}) do
        if value == expected then return true end
    end
    return false
end

local function sortedCopy(values)
    local result = {}
    for _, value in ipairs(values or {}) do result[#result + 1] = value end
    table.sort(result)
    return result
end

function Hardware.isFiniteNumber(value)
    return finite(value)
end

function Hardware.isInteger(value)
    return integer(value)
end

-- Reads and validates JSON without ever changing a peripheral target.
-- @ama-section: Readbacks | Timestamped physical observations and status.
-- @ama-summary: Read and decode the selected JSON record.
local function readJSON(path)
    if not fs or type(fs.open) ~= "function" then
        return nil, "ComputerCraft filesystem API is unavailable"
    end
    local handle, openError = fs.open(path, "r")
    if not handle then return nil, "cannot open " .. path .. ": " .. tostring(openError) end
    local raw = handle.readAll()
    handle.close()
    if type(raw) ~= "string" then return nil, "configuration file is empty" end

    local decode = textutils and (textutils.unserializeJSON or textutils.unserialiseJSON or textutils.parseJSON)
    if type(decode) ~= "function" then return nil, "JSON decoder is unavailable" end
    local ok, config = pcall(decode, raw)
    if not ok or type(config) ~= "table" then
        return nil, "configuration JSON could not be decoded: " .. tostring(config)
    end
    return config
end

local HARDWARE_PATH = "/avionics/data/chamber-hardware.json"
local hardwareFields={"providerDiscovery","activationFrequency","trimActivationFrequency","altitudeSensor",
    "networks","bindings","primaryDirection","peripherals"}
local function copy(value)
    if type(value)~="table" then return value end
    local out={};for k,v in pairs(value) do out[k]=copy(v) end;return out
end
-- @ama-section: Endpoint context | Configuration, discovery and command identity.
-- @ama-summary: Serialize and save the selected JSON record.
local function saveJSON(path,value)
    local encode=textutils and (textutils.serializeJSON or textutils.serialiseJSON)
    if not encode then return false,"JSON encoder unavailable" end
    local ok,issue=pcall(function()
        fs.makeDir("/avionics/data")
        local h=assert(fs.open(path..".new","w"));h.write(encode(value));h.close()
        local verified=assert(readJSON(path..".new"))
        if fs.exists(path..".bak") then fs.delete(path..".bak") end
        if fs.exists(path) then fs.move(path,path..".bak") end
        fs.move(path..".new",path)
    end)
    if not ok then pcall(function()
        if not fs.exists(path) and fs.exists(path..".bak") then fs.move(path..".bak",path) end
    end) end
    return ok,issue
end
-- @ama-summary: Read the lift/thrust role configuration and validate its structure.
function Hardware.loadConfig(path)
    local config,issue=readJSON(path);if not config then return nil,issue end
    -- Installation identity stays in config.json. User hardware survives package updates.
    if not config.providerDiscovery then return config end
    if not fs.exists(HARDWARE_PATH) and (fs.exists(HARDWARE_PATH..".bak") or fs.exists(HARDWARE_PATH..".new")) then
        return nil,"CHAMBER_HARDWARE_SAVE_INTERRUPTED: restore chamber-hardware.json from .bak or .new"
    end
    local settings
    if fs.exists(HARDWARE_PATH) then
        settings,issue=readJSON(HARDWARE_PATH)
        if not settings then return nil,"CHAMBER_HARDWARE_JSON: "..tostring(issue) end
    else
        settings={schemaVersion=1,role=config.role,peripherals={steamVents={},trimBurner="",activationBridge="",altitudeSensor=""}}
        for _,key in ipairs(hardwareFields) do if config[key]~=nil then settings[key]=copy(config[key]) end end
        local saved,why=saveJSON(HARDWARE_PATH,settings)
        if not saved then return nil,"CHAMBER_HARDWARE_SAVE_FAILED: "..tostring(why) end
    end
    if settings.schemaVersion~=1 or settings.role~=config.role then return nil,"CHAMBER_HARDWARE_IDENTITY_MISMATCH" end
    for _,key in ipairs(hardwareFields) do if settings[key]~=nil then config[key]=copy(settings[key]) end end
    config.hardwareSettingsPath=HARDWARE_PATH
    return config
end
function Hardware.steamCount(config)
    if config.providerDiscovery then return type(config.providerDiscovery)=="table" and config.providerDiscovery.steamCount or 0 end
    local count=0;for _,p in ipairs(config.providers or {}) do if p.controlRole=="bulk" then count=count+1 end end
    return count
end
-- @ama-summary: Persist the resolved hardware bindings into role configuration.
function Hardware.saveDiscovered(config,resolved,fingerprint)
    if not config.hardwareSettingsPath or config.savedHardwareFingerprint==fingerprint then return true end
    local settings,issue=readJSON(config.hardwareSettingsPath);if not settings then return false,issue end
    settings.discovered={steamVents={},trimBurner=resolved.balloonRepresentative,
        activationBridge=resolved.activationBridge,altitudeSensor=resolved.altitudeSensor.name}
    for _,p in ipairs(resolved.providers) do if p.controlRole=="bulk" then
        settings.discovered.steamVents[#settings.discovered.steamVents+1]=p.name
    end end
    local ok,why=saveJSON(config.hardwareSettingsPath,settings)
    if ok then config.savedHardwareFingerprint=fingerprint end
    return ok,why
end

-- Returns all configuration problems so a beginner can correct the JSON in
-- one pass. Empty provider allowlists are valid for read-only inspection, but
-- they can never make a node ready to apply commands.
-- @ama-summary: Validate role configuration, provider/drive definitions and their bounds.
function Hardware.validateConfig(config, actualComputerId)
    local errors = {}
    if type(config) ~= "table" then return false, { "configuration must be a JSON object" } end
    if config.tuningEnabled~=nil and type(config.tuningEnabled)~="boolean" then appendError(errors,"tuningEnabled must be boolean") end
    if config.maintenanceEnabled~=nil and type(config.maintenanceEnabled)~="boolean" then appendError(errors,"maintenanceEnabled must be boolean") end
    if config.compositionProbeEnabled~=nil and type(config.compositionProbeEnabled)~="boolean" then
        appendError(errors,"compositionProbeEnabled must be boolean")
    end
    if config.version ~= 1 then appendError(errors, "version must be 1") end
    if config.protocol ~= "amaryllis.v1" then appendError(errors, 'protocol must be "amaryllis.v1"') end
    local install=config.install
    local role=type(install)=="table" and install.role or config.role
    local expected=EXPECTED_ROLES[role]
    if not expected then appendError(errors,"install role must identify a chamber quadrant") end
    if config.liftRole~="lift" then appendError(errors,'liftRole must be "lift"') end
    if type(install)~="table" or install.protocol~="amaryllis.install.v1" then appendError(errors,"installed package identity is missing") else
        if install.packageId~=(expected and expected.packageId) then appendError(errors,"installed package ID does not match chamber role") end
        if not integer(install.version) or install.version<2 then appendError(errors,"installed package version is invalid") end
        if not integer(install.coreID) or install.coreID<0 or install.coreID>65535 or config.coreId~=install.coreID or
            type(install.coreSession)~="string" or install.coreSession=="" then
            appendError(errors,"core ID does not match installed registry identity")
        end
        if not integer(install.computerID) or config.computerId~=install.computerID then appendError(errors,"computer ID does not match installed identity") end
        if actualComputerId~=nil and install.computerID~=actualComputerId then appendError(errors,"installed computer ID does not match this computer") end
        if type(install.label)=="string" and config.label~=install.label then appendError(errors,"label does not match installed identity") end
    end
    if expected then
        if config.quadrant~=expected.quadrant then appendError(errors,"quadrant does not match installed role") end
    end
    local function frequency(f)
        return type(f)=="table" and type(f.first)=="string" and f.first:match("^[%w_]+:[%w_./-]+$") and
            type(f.second)=="string" and f.second:match("^[%w_]+:[%w_./-]+$")
    end
    if not frequency(config.activationFrequency) then appendError(errors,"activationFrequency requires two item IDs") end
    if config.trimActivationFrequency and not frequency(config.trimActivationFrequency) then appendError(errors,"trimActivationFrequency requires two item IDs") end
    if config.trimActivationFrequency and frequency(config.activationFrequency) and frequency(config.trimActivationFrequency) and
        config.activationFrequency.first==config.trimActivationFrequency.first and config.activationFrequency.second==config.trimActivationFrequency.second then
        appendError(errors,"steam and trim activation frequencies must differ")
    end
    if config.providerDiscovery then
        local d=config.providerDiscovery
        if type(d)~="table" then appendError(errors,"providerDiscovery must be an object");d={} end
        if not integer(d.steamCount) or d.steamCount<1 or d.steamCount>63 or d.trimCount~=1 then
            appendError(errors,"providerDiscovery requires 1..63 steam vents and exactly one trim burner")
        end
        if d.networkSide~=nil and not contains({"front","back","left","right","top","bottom"},d.networkSide) then appendError(errors,"invalid gas network side") end
    end
    if not finite(config.commandTimeoutSeconds) or config.commandTimeoutSeconds < 0.5 or config.commandTimeoutSeconds > 60 then
        appendError(errors, "commandTimeoutSeconds must be between 0.5 and 60")
    end
    if not finite(config.statusIntervalSeconds) or config.statusIntervalSeconds < 0.2 or config.statusIntervalSeconds > 10 then
        appendError(errors, "statusIntervalSeconds must be between 0.2 and 10")
    end

    if type(config.providers) ~= "table" then
        appendError(errors, "providers must be a JSON array")
    else
        if #config.providers > MAX_CONFIGURED_PROVIDERS then
            appendError(errors, "providers array cannot contain more than " .. MAX_CONFIGURED_PROVIDERS .. " entries")
        end
        local names, count = {}, 0
        for key, provider in pairs(config.providers) do
            if not integer(key) or key < 1 then
                appendError(errors, "providers must be an array with numeric indexes")
            else
                count = count + 1
            end
            if type(provider) ~= "table" then
                appendError(errors, "each providers entry must be an object")
            else
                local name = provider.name
                if type(name) ~= "string" or name == "" or #name > 96 or string.find(name, "%s") then
                    appendError(errors, "each provider needs a non-empty peripheral name without spaces")
                elseif names[name] then
                    appendError(errors, "provider name is listed more than once: " .. name)
                else
                    names[name] = true
                end
                if not integer(provider.minTarget) or provider.minTarget < 0 or provider.minTarget > MAX_TARGET then
                    appendError(errors, "minTarget must be a non-negative integer no greater than " .. MAX_TARGET)
                end
                if not integer(provider.maxTarget) or provider.maxTarget < 0 or provider.maxTarget > MAX_TARGET then
                    appendError(errors, "maxTarget must be a non-negative integer no greater than " .. MAX_TARGET)
                end
                if integer(provider.minTarget) and integer(provider.maxTarget) and provider.minTarget > provider.maxTarget then
                    appendError(errors, "minTarget cannot be greater than maxTarget")
                end
                if provider.minimumNonzeroTarget ~= nil and
                    (not integer(provider.minimumNonzeroTarget) or provider.minimumNonzeroTarget < 1 or
                    not integer(provider.maxTarget) or provider.minimumNonzeroTarget > provider.maxTarget) then
                    appendError(errors, "minimumNonzeroTarget must be a positive integer within maxTarget")
                end
                if provider.step ~= 1 then appendError(errors, "provider step must be 1 because targets are integer-only") end
            end
        end
        if count ~= #config.providers then appendError(errors, "providers array has a missing or non-sequential index") end
    end

    -- Optional for older inspection configurations; installed nodes require
    -- the local sensor before accepting outputs. Empty name means unique discovery.
    if config.ventStartupEnabled~=nil and type(config.ventStartupEnabled)~="boolean" then
        appendError(errors,"ventStartupEnabled must be a boolean")
    end
    if config.ventStartupTimeoutSeconds~=nil and (not finite(config.ventStartupTimeoutSeconds) or
        config.ventStartupTimeoutSeconds<1 or config.ventStartupTimeoutSeconds>30) then
        appendError(errors,"ventStartupTimeoutSeconds must be between 1 and 30")
    end
    if config.activationBridge ~= nil and
        (type(config.activationBridge) ~= "string" or config.activationBridge == "" or #config.activationBridge > 96) then
        appendError(errors, "activationBridge must be an exact peripheral name")
    end
    if config.altitudeSensor ~= nil then
        local sensor = config.altitudeSensor
        if type(sensor) ~= "table" or type(sensor.name) ~= "string" or
            #sensor.name > 96 or not finite(sensor.lowestPointOffsetBlocks) or
            sensor.lowestPointOffsetBlocks ~= 4 then
            appendError(errors, "altitudeSensor needs name and lowestPointOffsetBlocks=4")
        end
    end

    if config.balloonRepresentative ~= nil then
        if type(config.balloonRepresentative) ~= "string" then
            appendError(errors, "balloonRepresentative must be omitted or a peripheral name")
        else
            local found = false
            for _, provider in ipairs(config.providers or {}) do
                if type(provider) == "table" and provider.name == config.balloonRepresentative then found = true end
            end
            if not found then appendError(errors, "balloonRepresentative must name one configured provider") end
        end
    end

    return #errors == 0, errors
end

-- Validate a complete demand map before any output is touched. Sparse/partial
-- maps are rejected, preventing one quadrant from silently holding old caps.
-- Empty peripheral selections discover uniquely; explicit selections pin names.
-- @ama-summary: Validate a complete demand map before any output is touched. Sparse/partial maps are rejected, preventing one quadrant from silently holding old caps. Empty peripheral selections discover uniquely; explicit selections pin names.
function Hardware.resolveConfig(config, api)
    if not config.providerDiscovery then return config, nil, "fixed-legacy" end
    local function clone(v)
        if type(v)~="table" then return v end
        local out={} for k,x in pairs(v) do out[k]=clone(x) end return out
    end
    local resolved=clone(config)
    local discovery=config.providerDiscovery
    if type(discovery)~="table" or not integer(discovery.steamCount) or discovery.steamCount<1 or discovery.steamCount>63 or discovery.trimCount~=1 or type(discovery.bulk)~="table" or
        type(discovery.fine)~="table" then return nil,"INVALID_PROVIDER_DISCOVERY_SCHEMA" end
    local ok,names=callApi(api,"getNames")
    if not ok or type(names)~="table" then return nil,"PERIPHERAL_DISCOVERY_FAILED" end
    local steam,burners,bridges,altitudes={},{},{},{}
    for _,name in ipairs(names) do
        local function is(kind) local good,has=callApi(api,"hasType",name,kind); return good and has==true end
        if is("steam_vent") then steam[#steam+1]=name
        elseif is("hot_air_burner") then burners[#burners+1]=name
        elseif is("gas_provider") then return nil,"UNEXPECTED_GAS_PROVIDER_ON_QUADRANT_NETWORK" end
        if is("redstone_link_bridge") then bridges[#bridges+1]=name end
        if is("altitude_sensor") then altitudes[#altitudes+1]=name end
    end
    local pins=config.peripherals or {}
    if type(pins)~="table" then return nil,"PERIPHERALS_MUST_BE_OBJECT" end
    -- @ama-summary: Select discovered peripherals matching the configured role criteria.
    local function selectNames(found,pinned)
        if pinned==nil or pinned=="" or (type(pinned)=="table" and next(pinned)==nil) then return found end
        local chosen=type(pinned)=="string" and {pinned} or pinned
        if type(chosen)~="table" then return nil end
        local result,seen={},{}
        for k,name in pairs(chosen) do
            if not integer(k) or k<1 or type(name)~="string" or seen[name] or not contains(found,name) then return nil end
            seen[name]=true;result[#result+1]=name
        end
        if #result~=#chosen then return nil end
        return result
    end
    steam=selectNames(steam,pins.steamVents);burners=selectNames(burners,pins.trimBurner)
    bridges=selectNames(bridges,pins.activationBridge);altitudes=selectNames(altitudes,pins.altitudeSensor)
    if not steam or not burners or not bridges or not altitudes then return nil,"CONFIGURED_PERIPHERAL_MISSING_OR_WRONG_TYPE" end
    if #steam~=discovery.steamCount or #burners~=1 or #bridges~=1 or
        (not config.relayChildRole and #altitudes~=1) then
        return nil,"DISCOVERY_COUNTS: vents="..#steam.." trim="..#burners.." bridges="..#bridges.." altitude="..#altitudes
    end
    table.sort(steam); resolved.providers={}
    for _,name in ipairs(steam) do
        local p=clone(discovery.bulk); p.name=name; p.controlRole="bulk"
        resolved.providers[#resolved.providers+1]=p
    end
    local fine=clone(discovery.fine); fine.name=burners[1]; fine.controlRole="fine"
    resolved.providers[#resolved.providers+1]=fine
    resolved.balloonRepresentative=burners[1]; resolved.activationBridge=bridges[1]
    resolved.altitudeSensor={name=config.relayChildRole and "relayed-corner" or altitudes[1],lowestPointOffsetBlocks=4}
    local valid,errors=Hardware.validateConfig(resolved,config.computerId)
    if not valid then return nil,table.concat(errors,"; ") end
    steam[#steam+1]=burners[1]; steam[#steam+1]=bridges[1]; steam[#steam+1]=resolved.altitudeSensor.name
    local fingerprint=table.concat(steam,"|")
    local saved,why=Hardware.saveDiscovered(config,resolved,fingerprint)
    if not saved then return nil,"DISCOVERED_HARDWARE_SAVE_FAILED: "..tostring(why) end
    return resolved,nil,fingerprint
end

-- Receiver and sole writer both enforce the captured tuning envelope.
-- @ama-summary: Receiver and sole writer both enforce the captured tuning envelope.
function Hardware.validateTuning(config,targets,baseline,snapshot,first)
 if config.tuningEnabled~=true or not Hardware.validateTargets(config,config.quadrant,targets) or
  not Hardware.validateTargets(config,config.quadrant,baseline) then return false,"INVALID_TUNING_MAP" end
 local bulk,fine=0,0
 for _,definition in ipairs(config.providers) do
  local name=definition.name;local p=snapshot.providers[name];local base=baseline[name];local amount=targets[name]
  if not p or not p.present or not p.writable or not p.targetValid or not p.signalValid or
   (not (definition.controlRole=="fine" and base==0 and amount==0 and p.signalStrength==0) and
   (p.signalStrength~=15 or not p.attachedValid or not p.attached or not p.gasOutputValid or p.gasOutput<=0 or
   (p.activeSupported and (not p.activeValid or not p.active)))) then return false,"TUNING_PROVIDER_NOT_ACTIVE" end
  if first and (base~=p.targetAmount or amount~=base) then return false,"TUNING_BASELINE_CHANGED" end
  if definition.controlRole=="bulk" then
   bulk=bulk+1
   if math.floor(base*.95)<definition.minimumNonzeroTarget or math.ceil(base*1.05)>definition.maxTarget or
    amount<math.ceil(base*.95) or amount>math.floor(base*1.05) then return false,"TUNING_FEED_LIMIT" end
  elseif definition.controlRole=="fine" then
   fine=fine+1;if amount~=base or p.targetAmount~=base then return false,"TUNING_TRIM_CHANGED" end
  else return false,"TUNING_ROLE_INVALID" end
 end
  if bulk~=Hardware.steamCount(config) or fine~=1 then return false,"TUNING_REQUIRES_CONFIGURED_VENTS_ONE_BURNER" end
 return true
end

-- @ama-summary: Validate requested provider targets against configured names and numeric limits.
function Hardware.validateTargets(config, quadrant, targets, options)
    if type(config) ~= "table" or type(config.providers) ~= "table" then
        return false, "CONFIG_INVALID"
    end
    if quadrant ~= config.quadrant then return false, "WRONG_QUADRANT" end
    if type(targets) ~= "table" then return false, "TARGETS_NOT_OBJECT" end
    if #config.providers == 0 then return false, "PROVIDER_ALLOWLIST_EMPTY" end

    local definitions = {}
    for _, provider in ipairs(config.providers) do definitions[provider.name] = provider end

    local targetCount = 0
    for name, value in pairs(targets) do
        targetCount = targetCount + 1
        local provider = definitions[name]
        if not provider then return false, "UNCONFIGURED_PROVIDER" end
        if not integer(value) then return false, "TARGET_MUST_BE_INTEGER" end
        if value < provider.minTarget or value > provider.maxTarget then
            return false, "TARGET_OUT_OF_RANGE"
        end
        local preserveInactive = options and options.allowBelowFloor and options.allowBelowFloor[name] == true
        if value > 0 and value < (provider.minimumNonzeroTarget or provider.minTarget) and not preserveInactive then
            return false, "TARGET_BELOW_NONZERO_FLOOR"
        end
        if provider.step ~= 1 then return false, "UNSUPPORTED_TARGET_STEP" end
    end
    if targetCount ~= #config.providers then return false, "TARGET_MAP_INCOMPLETE" end
    for name in pairs(definitions) do
        if targets[name] == nil then return false, "TARGET_MAP_INCOMPLETE" end
    end
    return true
end

local function expectedTrimFrequency(config)
    local role=type(config and config.install)=="table" and config.install.role or config and config.role
    local expected=EXPECTED_ROLES[role]
    local pair=config and config.trimActivationFrequency
    return expected~=nil and type(pair)=="table" and type(pair.first)=="string" and type(pair.second)=="string"
end

-- Capability is based on the configured module roles and pinned activation
-- frequencies. It does not claim that the live peripherals are currently ready.
-- @ama-summary: Check that the configured hardware exposes the systems-stage operations.
function Hardware.systemsSupported(config)
    if type(config) ~= "table" or not config.compositionProbeEnabled or
        not config.activationBridge or not config.altitudeSensor or
        not expectedTrimFrequency(config) then return false end
    local bulk, fine = 0, 0
    for _, definition in ipairs(config.providers or {}) do
        if definition.controlRole == "bulk" and definition.minimumNonzeroTarget==50 and definition.maxTarget>=50 then bulk = bulk + 1
        elseif definition.controlRole == "fine" and definition.minimumNonzeroTarget == 5 then fine = fine + 1
        else return false end
    end
    return bulk == Hardware.steamCount(config) and fine == 1
end

-- Validate the two START SYSTEMS stages. Probe preserves each exact bulk
-- ceiling and activation state; control requires live envelope telemetry.
-- @ama-summary: Validate the two START SYSTEMS stages. Probe preserves each exact bulk ceiling and activation state; control requires live envelope telemetry.
function Hardware.validateSystemsTargets(config, quadrant, targets, stage, snapshot, priorStage)
    if not Hardware.systemsSupported(config) then return false, "SYSTEMS_NOT_SUPPORTED" end
    if stage ~= "probe" and stage ~= "control" then return false, "INVALID_SYSTEMS_STAGE" end
    if type(targets) ~= "table" then return false, "TARGETS_NOT_OBJECT" end
    snapshot = snapshot or {}
    local allowBelowFloor = {}
    if stage == "probe" then
        for _, definition in ipairs(config.providers or {}) do
            local provider = snapshot.providers and snapshot.providers[definition.name]
            allowBelowFloor[definition.name] = definition.controlRole == "bulk" and provider ~= nil and
                provider.targetValid == true and provider.signalValid == true and
                targets[definition.name] == provider.targetAmount
        end
    end
    local valid, reason = Hardware.validateTargets(config, quadrant, targets,
        { allowBelowFloor = allowBelowFloor })
    if not valid then return false, reason end

    local bulk, fine = 0, 0
    for _, definition in ipairs(config.providers or {}) do
        local provider = snapshot.providers and snapshot.providers[definition.name]
        if not provider or provider.present ~= true or provider.writable ~= true or
            provider.targetValid ~= true or provider.signalValid ~= true then
            return false, "SYSTEMS_PROVIDER_INTERFACE_INVALID:" .. tostring(definition.name)
        end
        local amount = targets[definition.name]
        if definition.controlRole == "bulk" then
            bulk = bulk + 1
            if stage == "probe" then
                if amount ~= provider.targetAmount then
                    return false, "SYSTEMS_PROBE_MUST_PRESERVE_BULK:" .. definition.name
                end
            elseif amount < math.max(50,definition.minimumNonzeroTarget or 1) then
                return false, "SYSTEMS_CONTROL_BULK_BELOW_NONZERO_FLOOR:" .. definition.name
            end
        elseif definition.controlRole == "fine" then
            fine = fine + 1
            if (stage=="probe" or amount>0) and amount < (definition.minimumNonzeroTarget or 5) then
                return false, "SYSTEMS_PROBE_REQUIRES_ACTIVE_TRIM"
            end
        else
            return false, "SYSTEMS_PROVIDER_ROLE_INVALID"
        end
    end
    if bulk ~= Hardware.steamCount(config) or fine ~= 1 then return false, "SYSTEMS_REQUIRES_CONFIGURED_VENTS_ONE_TRIM" end

    if stage == "control" then
        if priorStage ~= "probe" and priorStage ~= "control" then return false, "SYSTEMS_PROBE_REQUIRED" end
        local altitude, balloon = snapshot.altitude, snapshot.balloon
        if not altitude or altitude.valid ~= true then return false, "SYSTEMS_ALTITUDE_INVALID" end
        if not balloon or balloon.hasBalloonValid ~= true or balloon.hasBalloon ~= true or
            balloon.liftValid ~= true or balloon.gasMixValid ~= true then
            return false, "SYSTEMS_ENVELOPE_LIFT_OR_COMPOSITION_INVALID"
        end
    end
    return true
end

-- Locate only real wireless modems. This does not transmit, touch redstone, or
-- alter lift hardware; rednet.open merely makes the wireless network available.
-- @ama-summary: Find attached wireless modem interfaces.
function Hardware.findWirelessModems(api)
    local ok, names = callApi(api, "getNames")
    if not ok or type(names) ~= "table" then return nil, "could not list peripherals: " .. tostring(names) end
    local result = {}
    for _, name in ipairs(sortedCopy(names)) do
        local typeOk, isModem = callApi(api, "hasType", name, "modem")
        if typeOk and isModem == true then
            local wrapOk, modem = callApi(api, "wrap", name)
            if wrapOk and type(modem) == "table" and type(modem.isWireless) == "function" then
                local wirelessOk, wireless = pcall(modem.isWireless)
                if wirelessOk and wireless == true then result[#result + 1] = name end
            end
        end
    end
    if #result == 0 then return nil, "no wireless modem is attached" end
    return result
end

-- @ama-summary: Find and open wireless modems for fleet status reception.
function Hardware.openWirelessModems(names, rednetApi)
    if type(names) ~= "table" then return false, "wireless modem list is invalid" end
    local opened = 0
    local errors = {}
    for _, name in ipairs(names) do
        local alreadyOk, already = callApi(rednetApi, "isOpen", name)
        if not alreadyOk then
            errors[#errors + 1] = name .. ": cannot inspect modem state"
        elseif already then
            opened = opened + 1
        else
            local openOk, openResult = callApi(rednetApi, "open", name)
            if openOk and openResult ~= false then opened = opened + 1
            else errors[#errors + 1] = name .. ": could not open wireless modem: " .. tostring(openResult) end
        end
    end
    if opened == 0 then return false, table.concat(errors, "; ") end
    return true, nil
end

-- @ama-summary: Build the method-name lookup for a peripheral interface.
local function methodSet(api, name)
    local ok, methods = callApi(api, "getMethods", name)
    if not ok or type(methods) ~= "table" then return nil, tostring(methods) end
    local set = {}
    for _, method in ipairs(methods) do
        if type(method) == "string" then set[method] = true end
    end
    return set
end

-- @ama-summary: Read and validate the selected numeric or typed observation.
local function value(api, name, method, expectedType)
    local ok, result = callPeripheral(api, name, method)
    if not ok then return nil, false, tostring(result) end
    if expectedType == "number" then
        if not finite(result) then return nil, false, method .. " did not return a finite number" end
    elseif expectedType == "integer" then
        if not integer(result) then return nil, false, method .. " did not return an integer" end
    elseif expectedType == "boolean" then
        if type(result) ~= "boolean" then return nil, false, method .. " did not return true or false" end
    elseif expectedType == "string" then
        if type(result) ~= "string" then return nil, false, method .. " did not return text" end
    end
    return result, true
end

-- Samples only the explicitly configured allowlist. Unknown gas providers are
-- reported by inspect mode and never become actuators through auto-discovery.
-- @ama-section: Readbacks | Timestamped physical observations and status.
-- @ama-summary: Read the configured providers and retain each getter's validity and result.
function Hardware.sampleConfigured(config, api)
    local snapshot = { providers = {}, faults = {}, ready = true, totalGasOutputValid = true }
    if type(config.providers) ~= "table" or #config.providers == 0 then
        snapshot.ready = false
        snapshot.faults[#snapshot.faults + 1] = "PROVIDER_ALLOWLIST_EMPTY"
        snapshot.totalGasOutputValid = false
        return snapshot
    end

    local totalOutput = 0
    for _, definition in ipairs(config.providers) do
        local errors = {}
        local record = {
            name = definition.name,
            type = "gas_provider",
            minTarget = definition.minTarget,
            minimumNonzeroTarget = definition.minimumNonzeroTarget,
            controlRole = definition.controlRole,
            maxTarget = definition.maxTarget,
            step = 1,
            present = false,
            presenceValid = false,
            presenceState = "UNVERIFIED",
            writable = false,
            writableValid = false,
            targetValid = false,
            signalValid = false,
            gasOutputValid = false,
            attachedValid = false,
            activeSupported = false,
            activeValid = false,
            gasTypeValid = false,
            boilerEfficiencyValid = false,
        }
        snapshot.providers[definition.name] = record

        local typeOk, isProvider = callApi(api, "hasType", definition.name, "gas_provider")
        if not typeOk or type(isProvider)~="boolean" then
            errors[#errors + 1] = "peripheral presence/type unverified: "..tostring(isProvider)
        elseif isProvider ~= true then
            record.presenceValid=true;record.presenceState="MISSING_OR_WRONG_TYPE"
            errors[#errors + 1] = "configured peripheral is missing or is not a gas_provider"
        else
            record.present = true
            record.presenceValid=true;record.presenceState="PRESENT"
            local signal,signalOk,signalError=value(api,definition.name,"getSignalStrength","integer")
            if signalOk and signal>=0 and signal<=15 then
                record.signalStrength=signal;record.signalValid=true
            else errors[#errors+1]=signalError or "getSignalStrength returned a value outside 0 through 15" end
            record.telemetryExpected=record.signalValid and record.signalStrength>1
            local methods, methodsError = methodSet(api, definition.name)
            if not methods then
                errors[#errors + 1] = "could not inspect methods: " .. methodsError
                snapshot.totalGasOutputValid = false
            else
                record.writable = methods.setTargetAmount == true and methods.getTargetAmount == true
                record.writableValid = true
                local missingRequiredMethod = false
                for _, required in ipairs(REQUIRED_PROVIDER_METHODS) do
                    if not methods[required] then
                        errors[#errors + 1] = "missing " .. required
                        missingRequiredMethod = true
                    end
                end
                if missingRequiredMethod then snapshot.totalGasOutputValid = false end

                -- Some Create Avionics providers expose status and gas-kind
                -- getters in addition to the required actuator API. Keep them
                -- optional and explicitly mark unknown values instead of
                -- fabricating false or zero data.
                record.activeSupported = methods.isActive == true
                if record.activeSupported and record.telemetryExpected then
                    local active, activeOk, activeError = value(api, definition.name, "isActive", "boolean")
                    if activeOk then
                        record.active = active
                        record.activeValid = true
                        if active ~= true then errors[#errors + 1] = "provider is inactive" end
                    else
                        errors[#errors + 1] = activeError
                    end
                end

                if methods.getGasType and record.telemetryExpected then
                    local gasType, gasTypeOk, gasTypeError = value(api, definition.name, "getGasType", "string")
                    if gasTypeOk and gasType ~= "" then
                        record.gasType = gasType
                        record.gasTypeValid = true
                    elseif gasTypeOk then
                        record.gasTypeValid = false
                    else
                        record.gasTypeValid = false
                        record.gasTypeError = gasTypeError
                    end
                end

                if methods.getBoilerEfficiency and record.telemetryExpected then
                    local efficiency, efficiencyOk, efficiencyError = value(api, definition.name, "getBoilerEfficiency", "number")
                    if efficiencyOk then
                        record.boilerEfficiency = efficiency
                        record.boilerEfficiencyValid = true
                    else
                        record.boilerEfficiencyValid = false
                        record.boilerEfficiencyError = efficiencyError
                    end
                end
            end

            local target, targetOk, targetError = value(api, definition.name, "getTargetAmount", "integer")
            if targetOk then record.targetAmount = target; record.targetValid = true
            else errors[#errors + 1] = targetError end

            -- Inactive providers are blind. Their actuator interface can be
            -- checked, but no envelope/activity/output getter is meaningful.
            if record.telemetryExpected then
            local output, outputOk, outputError = value(api, definition.name, "getGasOutput", "number")
            if outputOk and output >= 0 then
                record.gasOutput = output
                record.gasOutputValid = true
                totalOutput = totalOutput + output
            elseif outputOk then
                errors[#errors + 1] = "getGasOutput returned a negative rate"
                snapshot.totalGasOutputValid = false
            else errors[#errors + 1] = outputError; snapshot.totalGasOutputValid = false end

            local attached, attachedOk, attachedError = value(api, definition.name, "hasBalloon", "boolean")
            if attachedOk then
                record.attached = attached
                record.attachedValid = true
                if attached ~= true then errors[#errors + 1] = "provider reports no attached balloon" end
            else errors[#errors + 1] = attachedError end
            end
        end

        if #errors > 0 then
            record.error = table.concat(errors, "; ")
            local safeFineOff=record.controlRole=="fine" and record.present and record.writable and
                record.targetValid and record.signalValid and record.signalStrength==0 and
                (record.targetAmount==0 or record.targetAmount>=(record.minimumNonzeroTarget or 1)) and
                type(record.maxTarget)=="number" and record.targetAmount<=record.maxTarget and
                (not record.activeSupported or (record.activeValid and record.active==false))
            if not safeFineOff then snapshot.ready=false end
            -- A dormant bulk vent cannot attach/read its envelope. That is
            -- expected status, not a fault. Preserve strict writer readiness
            -- independently; never fabricate attachment or valid telemetry.
            local report=true
            if record.controlRole=="bulk" or record.controlRole=="fine" then
                local interfaceMissing=not record.present or not record.writable or
                    not record.targetValid or not record.signalValid
                local informationMissing=not record.gasOutputValid or not record.attachedValid or not record.attached
                report=interfaceMissing or (record.signalValid and record.signalStrength>1 and informationMissing)
                record.telemetryExpected=record.signalValid and record.signalStrength>1
            end
            if report then snapshot.faults[#snapshot.faults + 1] =
                "PROVIDER_UNREADY:" .. definition.name.." | "..record.error end
        end
        if record.gasOutputValid ~= true then snapshot.totalGasOutputValid = false end
    end

    if snapshot.totalGasOutputValid then snapshot.totalGasOutput = totalOutput end
    return snapshot
end

-- Each getter waits for a server tick, and a full sample is about nine calls
-- per provider. With 30+ vents a sequential sample took seconds, which made
-- every status report and START SYSTEMS ACK slow. Sample the providers
-- concurrently (same per-provider checks) and merge the results in order.
local sampleConfiguredSequential=Hardware.sampleConfigured
-- @ama-summary: Read the configured providers and retain each getter's validity and result.
function Hardware.sampleConfigured(config, api)
    local providers=type(config)=="table" and config.providers or nil
    if type(providers)~="table" or #providers<2 or type(parallel)~="table" or
        type(parallel.waitForAll)~="function" then
        return sampleConfiguredSequential(config, api)
    end
    local parts,jobs={},{}
    for index,definition in ipairs(providers) do
        jobs[index]=function()
            local ok,result=pcall(sampleConfiguredSequential,{providers={definition}},api)
            if ok then parts[index]=result end
        end
    end
    parallel.waitForAll(table.unpack(jobs))
    local snapshot={providers={},faults={},ready=true,totalGasOutputValid=true}
    local total=0
    for index,definition in ipairs(providers) do
        local part=parts[index]
        if type(part)~="table" or type(part.providers)~="table" or not part.providers[definition.name] then
            return sampleConfiguredSequential(config, api)
        end
        snapshot.providers[definition.name]=part.providers[definition.name]
        for _,fault in ipairs(part.faults or {}) do snapshot.faults[#snapshot.faults+1]=fault end
        if part.ready==false then snapshot.ready=false end
        if part.totalGasOutputValid then total=total+(part.totalGasOutput or 0)
        else snapshot.totalGasOutputValid=false end
    end
    if snapshot.totalGasOutputValid then snapshot.totalGasOutput=total end
    return snapshot
end

-- Read the exact configured wool pair without changing transmission. Startup
-- checks this bridge independently from vent attachment: an inactive vent may
-- need its activation channel before it can establish balloon telemetry.
-- @ama-summary: Read the configured provider activation signals.
function Hardware.sampleActivation(config, api, group, providers)
    local result = { valid = false, source = config.activationBridge }
    local pair = config.activationFrequency
    if group == "fine" then pair = config.trimActivationFrequency end
    if type(pair) ~= "table" or type(pair.first) ~= "string" or pair.first == "" or
        type(pair.second) ~= "string" or pair.second == "" then
        result.reason = "ACTIVATION_FREQUENCY_NOT_CONFIGURED"; return result
    end
    if type(config.activationBridge) ~= "string" or config.activationBridge == "" then
        result.reason = "ACTIVATION_BRIDGE_NOT_CONFIGURED"; return result
    end
    local typeOk, matches = callApi(api, "hasType", config.activationBridge, "redstone_link_bridge")
    local methods = methodSet(api, config.activationBridge)
    if not typeOk or matches ~= true or not methods or
        not methods.getLinkSignal or not methods.sendLinkSignal then
        result.reason = "ACTIVATION_BRIDGE_MISSING"; return result
    end
    result.writable = true
    if providers~=nil then
        local wanted=group=="fine" and "fine" or "bulk"
        local count,level=0,nil
        for _,definition in ipairs(config.providers or {}) do
            if (definition.controlRole=="fine" and "fine" or "bulk")==wanted then
                local p=providers[definition.name]
                if not p or p.present~=true or p.signalValid~=true or not integer(p.signalStrength) or p.signalStrength<0 or p.signalStrength>15 then
                    result.reason="ACTIVATION_PROVIDER_SIGNAL_UNAVAILABLE";return result
                end
                if level~=nil and level~=p.signalStrength then result.reason="ACTIVATION_PROVIDER_SIGNAL_MISMATCH";return result end
                level=p.signalStrength;count=count+1
            end
        end
        if count==0 then result.reason="ACTIVATION_PROVIDER_SIGNAL_UNAVAILABLE";return result end
        result.valid=true;result.signalStrength=level
        result.readbackSource="gas_provider.getSignalStrength";result.providerCount=count
        return result
    end
    local ok,strength
    if type(parallel)=="table" and type(parallel.waitForAny)=="function" then
        local completed=false
        local deadline=os.clock()+.75
        local timer=os.startTimer(.75)
        parallel.waitForAny(function()
            ok,strength=callPeripheral(api,config.activationBridge,"getLinkSignal",pair.first,pair.second)
            completed=true
        end,function()
            while os.clock()<deadline do os.pullEventRaw() end
        end)
        pcall(os.cancelTimer,timer)
        if not completed then
            result.reason="ACTIVATION_BRIDGE_READ_TIMEOUT"
            result.frequency={first=pair.first,second=pair.second}
            return result
        end
    else ok,strength=callPeripheral(api,config.activationBridge,"getLinkSignal",pair.first,pair.second) end
    if not ok or not integer(strength) or strength < 0 or strength > 15 then
        result.reason = "ACTIVATION_BRIDGE_READ_FAILED"; return result
    end
    result.valid = true
    result.signalStrength = strength
    return result
end

-- Emergency stop parks bulk lift while retaining the minimum trim probe. Turn
-- the bulk link off first so probe setup and telemetry reads cannot delay the
-- lift cutoff. Provider ceilings are never set to zero because some
-- peripherals clamp that request to their active floor.
-- @ama-section: Output operations | Verified targets applied under current authority.
-- @ama-summary: Apply the emergency stop sequence and verify its configured output readbacks.
function Hardware.emergencyStop(config, api, isCurrent)
    config = type(config) == "table" and config or {}
    local failures, bulkCount, fineCount = {}, 0, 0
    local function current()
        if type(isCurrent) ~= "function" then return true end
        local ok, value = pcall(isCurrent)
        return ok and value == true
    end
    local function superseded()
        return false, "emergency stop superseded after bulk-off"
    end
    local function fail(message)
        -- Keep the fault string bounded even if a damaged config contains many
        -- duplicate or malformed entries. Every hardware loop below is capped.
        if #failures < 12 then failures[#failures + 1] = tostring(message) end
    end
    local bridge = config.activationBridge
    local bulkPair = config.activationFrequency

    -- This is deliberately the first peripheral operation in the KILL path.
    if type(bridge) == "string" and bridge ~= "" and type(bulkPair) == "table" and
        type(bulkPair.first) == "string" and bulkPair.first ~= "" and
        type(bulkPair.second) == "string" and bulkPair.second ~= "" then
        local ok, result = callPeripheral(api, bridge, "sendLinkSignal",
            bulkPair.first, bulkPair.second, 0)
        if not ok or result == false then fail("bulk link off write failed") end
    else
        fail("bulk link is not configured")
    end
    -- The cutoff is unconditional and first. If discovery changes while that
    -- call yields, do not write a probe against the retired provider map.
    if not current() then return superseded() end

    local providers = type(config.providers) == "table" and config.providers or {}
    local emergencyProviders, seenProviders = {}, {}
    local trim
    local providerCount = #providers
    if providerCount > MAX_CONFIGURED_PROVIDERS then
        fail("provider list exceeds emergency verification limit")
        providerCount = MAX_CONFIGURED_PROVIDERS
    end
    for index = 1, providerCount do
        local definition = providers[index]
        if type(definition) == "table" then
            if type(definition.name) ~= "string" or definition.name == "" then
                fail("provider name is invalid at index " .. index)
            elseif seenProviders[definition.name] then
                fail("provider is duplicated: " .. definition.name)
            else
                seenProviders[definition.name] = true
                emergencyProviders[#emergencyProviders + 1] = definition
                if definition.controlRole == "bulk" then
                    bulkCount = bulkCount + 1
                elseif definition.controlRole == "fine" then
                    fineCount = fineCount + 1
                    if fineCount == 1 then trim = definition end
                else
                    fail("provider role is invalid: " .. definition.name)
                end
            end
        else
            fail("provider definition is missing at index " .. index)
        end
    end
    if bulkCount ~= Hardware.steamCount(config) then fail("expected configured steam vent count") end
    if fineCount ~= 1 then fail("expected exactly one configured trim probe") end

    -- Set the one known trim provider to its hard five-unit floor before
    -- enabling its link, so a stale high ceiling cannot create an output spike.
    local trimTargetReady = false
    if trim and type(trim.name) == "string" and trim.name ~= "" and
        type(trim.maxTarget) == "number" and trim.maxTarget >= 5 and
        type(trim.minimumNonzeroTarget) == "number" and trim.minimumNonzeroTarget == 5 then
        local typeOk, isBurner = callApi(api, "hasType", trim.name, "hot_air_burner")
        local currentTarget, targetValid = value(api, trim.name, "getTargetAmount", "integer")
        if not typeOk or isBurner ~= true then
            fail("trim probe burner is missing")
        elseif not targetValid then
            fail("trim probe target readback failed")
        elseif currentTarget == 5 then
            trimTargetReady = true
        else
            if not current() then return superseded() end
            local targetSet = Hardware.applyTarget(api, trim.name, 5)
            if targetSet then trimTargetReady = true
            else fail("trim probe target could not be set to five") end
        end
    else
        fail("trim probe floor or ceiling is invalid")
    end

    local finePair = config.trimActivationFrequency
    if trimTargetReady and not current() then return superseded() end
    if trimTargetReady and type(bridge) == "string" and bridge ~= "" and
        type(finePair) == "table" and type(finePair.first) == "string" and finePair.first ~= "" and
        type(finePair.second) == "string" and finePair.second ~= "" then
        local ok, result = callPeripheral(api, bridge, "sendLinkSignal",
            finePair.first, finePair.second, 15)
        if not ok or result == false then fail("trim probe activation write failed") end
    elseif trimTargetReady then
        fail("trim probe link is not configured")
    end
    if not current() then return superseded() end

    -- Read both independent links and every configured provider after the
    -- writes, including partial/missing hardware, so KILL status shows what
    -- actually succeeded. No readiness gate or wait loop runs here.
    local bulkLink = Hardware.sampleActivation(config, api, "bulk")
    if not bulkLink.valid then fail("bulk link readback invalid")
    elseif bulkLink.signalStrength ~= 0 then fail("bulk link remains on") end
    local fineLink = Hardware.sampleActivation(config, api, "fine")
    if not fineLink.valid then fail("trim probe link readback invalid")
    elseif fineLink.signalStrength ~= 15 then fail("trim probe link is not strength fifteen") end

    local after = Hardware.sampleConfigured({ providers = emergencyProviders }, api)
    for _, definition in ipairs(emergencyProviders) do
        local provider = after.providers and after.providers[definition.name]
        if definition.controlRole == "bulk" then
            if not provider or provider.present ~= true or provider.targetValid ~= true or
                provider.signalValid ~= true or provider.signalStrength ~= 0 then
                fail(tostring(definition.name) .. " bulk signal is not verified off")
            end
        elseif definition.controlRole == "fine" and trim == definition then
            if not provider or provider.present ~= true or provider.writable ~= true or
                (provider.activeSupported == true and
                    (provider.activeValid ~= true or provider.active ~= true)) or
                provider.targetValid ~= true or
                provider.targetAmount ~= 5 or provider.signalValid ~= true or
                provider.signalStrength ~= 15 or provider.attachedValid ~= true or
                provider.attached ~= true then
                fail("trim probe target, signal, or balloon attachment is not verified")
            end
        end
    end

    local envelope = trim and Hardware.sampleBalloon(config, after.providers, api, "fine") or nil
    if not envelope or envelope.hasBalloonValid ~= true or envelope.hasBalloon ~= true then
        fail("trim probe balloon attachment is unreadable")
    end
    if not envelope or envelope.gasMixValid ~= true then fail("trim probe gas mix is unreadable") end
    if not envelope or envelope.liftValid ~= true or not finite(envelope.lift) then
        fail("trim probe balloon lift is unreadable")
    end

    if #failures > 0 then return false, table.concat(failures, "; "):sub(1, 160), after, envelope end
    return true, nil, after, envelope
end

-- Confirmed shutdown keeps a low trim probe running, then turns steam links off.
-- A zero activation link is the off control; preserve each stored bulk ceiling.
-- @ama-section: Endpoint context | Configuration, discovery and command identity.
-- @ama-summary: Confirmed shutdown keeps a low trim probe running, then turns steam links off. A zero activation link is the off control; preserve each stored bulk ceiling.
function Hardware.shutdown(config,api,isCurrent)
    local failures={}
    local trim
    for _,p in ipairs(config.providers or {}) do if p.controlRole=="fine" then trim=p end end
    if not trim then return false,"SHUTDOWN PROBE MISSING" end
    if not isCurrent() then return false,"SHUTDOWN SUPERSEDED" end
    local set,why=Hardware.applyTarget(api,trim.name,5)
    if not set then return false,"SHUTDOWN PROBE FLOOR FAILED:"..tostring(why) end
    local started,reason=Hardware.activate(config,api,"fine","systems_probe",isCurrent)
    if not started then return false,"SHUTDOWN PROBE ACTIVATION FAILED:"..tostring(reason) end
    local probe=Hardware.sampleBalloon(config,Hardware.sampleConfigured(config,api).providers,api,"fine")
    if not probe or not probe.hasBalloon or not probe.gasMixValid or not probe.liftValid then
        return false,"SHUTDOWN WAITING FOR PROBE ENVELOPE"
    end
    for _,group in ipairs({"bulk"}) do
        if not isCurrent() then return false,"SHUTDOWN SUPERSEDED" end
        local pair=group=="bulk" and config.activationFrequency or config.trimActivationFrequency
        if not pair or not config.activationBridge then failures[#failures+1]=group.." LINK UNAVAILABLE"
        else
            local ok,result=callPeripheral(api,config.activationBridge,"sendLinkSignal",pair.first,pair.second,0)
            if not ok or result==false then failures[#failures+1]=group.." LINK OFF FAILED" end
        end
    end
    if not isCurrent() then return false,"SHUTDOWN SUPERSEDED" end
    local signal=Hardware.sampleActivation(config,api,"bulk")
    if not signal.valid or signal.signalStrength~=0 then failures[#failures+1]="bulk OFF READBACK FAILED" end
    local actual=Hardware.sampleConfigured(config,api)
    for _,provider in ipairs(config.providers or {}) do
        local sample=actual.providers and actual.providers[provider.name]
        if not sample or not sample.targetValid or not sample.signalValid then
            failures[#failures+1]=provider.name..":SHUTDOWN READBACK INVALID"
        elseif provider.controlRole=="bulk" then
            if sample.signalStrength~=0 then failures[#failures+1]=provider.name..":BULK OFF READBACK FAILED" end
            if sample.targetAmount<provider.minTarget or sample.targetAmount>provider.maxTarget then
                failures[#failures+1]=provider.name..":BULK CEILING OUT OF RANGE"
            end
        elseif sample.targetAmount~=5 or sample.signalStrength~=15 then
            failures[#failures+1]=provider.name..":TRIM PROBE READBACK FAILED"
        end
    end
    return #failures==0,table.concat(failures,"; ")
end

-- @ama-summary: Place the fine/probe providers in the configured parked state.
function Hardware.parkTrim(config,api,isCurrent,options)
    options=type(options)=="table" and options or {}
    local current=type(isCurrent)=="function" and isCurrent or function() return false end
    local clockFn=type(options.clockFn)=="function" and options.clockFn or function()
        return type(os)=="table" and type(os.clock)=="function" and os.clock() or 0
    end
    local waitFn=options.waitFn
    if type(waitFn)~="function" then
        waitFn=function(seconds)
            if type(sleep)=="function" then sleep(seconds)
            elseif type(os)=="table" and type(os.sleep)=="function" then os.sleep(seconds) end
        end
    end
    local timeout=finite(options.timeoutSeconds) and options.timeoutSeconds or SYSTEMS_HANDOVER_TIMEOUT_SECONDS
    timeout=math.max(0,math.min(12,timeout))
    local interval=finite(options.pollIntervalSeconds) and options.pollIntervalSeconds or
        SYSTEMS_HANDOVER_POLL_INTERVAL_SECONDS
    interval=math.max(0.01,math.min(1,interval))
    local maxPolls=integer(options.maxPolls) and options.maxPolls or SYSTEMS_HANDOVER_MAX_POLLS
    maxPolls=math.max(1,math.min(128,maxPolls))
    local started=clockFn()
    if not finite(started) then started=0 end
    local waitingReported=false
    local lastReason="steam envelope has not settled"
    local function stillCurrent()
        return current()==true
    end
    local function reportWaiting(reason)
        lastReason=reason
        if type(options.onWaiting)=="function" then
            options.onWaiting(reason,not waitingReported)
        end
        waitingReported=true
    end
    if not stillCurrent() then return false,"TRIM HANDOVER SUPERSEDED" end

    local trim
    for _,p in ipairs(config.providers or {}) do
        if p.controlRole=="fine" then
            if trim then return false,"TRIM PROVIDER AMBIGUOUS" end
            trim=p
        end
    end
    if not trim then return false,"TRIM PROVIDER MISSING" end
    local trimFloor=trim.minimumNonzeroTarget or 5

    -- @ama-summary: Read provider/envelope observations required for the next systems-stage handover.
    local function sampleHandoverReadiness(allowAlreadyParked)
        if not stillCurrent() then return nil,"TRIM HANDOVER SUPERSEDED",true end
        local bulkLink=Hardware.sampleActivation(config,api,"bulk")
        if not stillCurrent() then return nil,"TRIM HANDOVER SUPERSEDED",true end
        local fineLink=Hardware.sampleActivation(config,api,"fine")
        if not stillCurrent() then return nil,"TRIM HANDOVER SUPERSEDED",true end
        local sampled=Hardware.sampleConfigured(config,api)
        if not stillCurrent() then return nil,"TRIM HANDOVER SUPERSEDED",true end

        local trimSample=sampled.providers and sampled.providers[trim.name]
        local probeActive=false
        if not fineLink.valid then
            return nil,"trim probe activation readback failed: "..tostring(fineLink.reason or "unavailable"),true
        elseif fineLink.signalStrength==15 then
            probeActive=true
            if not trimSample or not trimSample.targetValid or trimSample.targetAmount<trimFloor or
                not trimSample.signalValid or trimSample.signalStrength~=15 then
                return nil,"trim probe ceiling or provider signal is not verified",true
            end
        elseif fineLink.signalStrength==0 then
            if allowAlreadyParked and trimSample and trimSample.targetValid and trimSample.targetAmount==trimFloor and
                trimSample.signalValid and trimSample.signalStrength==0 then
                probeActive=false
            else
                return nil,"trim probe is already parked before steam envelope readiness",true
            end
        else
            return nil,"trim probe activation signal is "..tostring(fineLink.signalStrength)..", expected 15",true
        end

        if not bulkLink.valid then
            return nil,"bulk activation readback failed: "..tostring(bulkLink.reason or "unavailable"),not probeActive,probeActive
        end
        if bulkLink.signalStrength~=15 then
            return nil,"bulk activation signal is "..tostring(bulkLink.signalStrength)..", expected 15",not probeActive,probeActive
        end
        for _,definition in ipairs(config.providers or {}) do
            if definition.controlRole=="bulk" then
                local provider=sampled.providers and sampled.providers[definition.name]
                if not provider or provider.present~=true or not provider.signalValid or provider.signalStrength~=15 then
                    return nil,"bulk provider "..tostring(definition.name).." signal is not verified at 15",not probeActive,probeActive
                end
                if not provider.attachedValid or provider.attached~=true then
                    return nil,"bulk provider "..tostring(definition.name).." balloon attachment is not verified",not probeActive,probeActive
                end
            end
        end

        local envelope=Hardware.sampleBalloon(config,sampled.providers,api,"bulk")
        if not stillCurrent() then return nil,"TRIM HANDOVER SUPERSEDED",true end
        if not envelope or envelope.hasBalloonValid~=true or envelope.hasBalloon~=true then
            return nil,"bulk hasBalloon readback is not verified",not probeActive,probeActive
        end
        if envelope.gasMixValid~=true or not finite(envelope.gasMixAmount) or envelope.gasMixAmount<=0 then
            return nil,"bulk gas mix readback is invalid: "..tostring(envelope.gasMixError or "empty or non-finite mix"),not probeActive,probeActive
        end
        if envelope.liftValid~=true or not finite(envelope.lift) then
            return nil,"bulk balloon lift readback is invalid",not probeActive,probeActive
        end
        return {providers=sampled.providers,envelope=envelope,probeActive=probeActive}
    end

    local ready
    local polls=0
    local firstSample=true
    while not ready do
        local result,reason,terminal,probeActive=sampleHandoverReadiness(firstSample)
        firstSample=false
        if reason=="TRIM HANDOVER SUPERSEDED" then return false,reason end
        if result then
            if not result.probeActive then
                if not stillCurrent() then return false,"TRIM HANDOVER SUPERSEDED" end
                return true
            end
            local now=clockFn()
            if not finite(now) or now-started>timeout then
                return false,"STEAM ENVELOPE NOT READY FOR TRIM HANDOVER: timeout; last check: "..lastReason
            end
            ready=result
            break
        end
        lastReason=reason or "steam envelope readback is invalid"
        if terminal or probeActive==false then
            return false,"STEAM ENVELOPE NOT READY FOR TRIM HANDOVER: "..lastReason
        end
        reportWaiting(lastReason)
        polls=polls+1
        local now=clockFn()
        if not finite(now) then now=started+timeout end
        if now-started>=timeout or polls>=maxPolls then
            return false,"STEAM ENVELOPE NOT READY FOR TRIM HANDOVER: timeout; "..lastReason
        end
        if not stillCurrent() then return false,"TRIM HANDOVER SUPERSEDED" end
        waitFn(math.min(interval,math.max(0,timeout-(now-started))))
        if not stillCurrent() then return false,"TRIM HANDOVER SUPERSEDED" end
    end

    if not stillCurrent() then return false,"TRIM HANDOVER SUPERSEDED" end
    local actualTrim=ready.providers and ready.providers[trim.name]
    if not actualTrim or not actualTrim.targetValid then return false,"TRIM PROVIDER READBACK INVALID" end
    if actualTrim.targetAmount~=trimFloor then
        local set,why=Hardware.applyTarget(api,trim.name,trimFloor)
        if not set then return false,"TRIM PARK CEILING FAILED:"..tostring(why) end
        if not stillCurrent() then return false,"TRIM HANDOVER SUPERSEDED" end
    end

    -- The trim link stays on if any readback stops being ready after its safe
    -- floor is confirmed. Re-read immediately before the handover write.
    local finalReadiness,finalReason=sampleHandoverReadiness(false)
    if finalReason=="TRIM HANDOVER SUPERSEDED" then return false,finalReason end
    if not finalReadiness then
        return false,"STEAM ENVELOPE NOT READY FOR TRIM HANDOVER: final readback failed: "..tostring(finalReason)
    end
    if not stillCurrent() then return false,"TRIM HANDOVER SUPERSEDED" end
    local pair=config.trimActivationFrequency
    if type(pair)~="table" then return false,"TRIM OFF FREQUENCY UNAVAILABLE" end
    local ok,result=callPeripheral(api,config.activationBridge,"sendLinkSignal",pair.first,pair.second,0)
    if not ok or result==false then return false,"TRIM OFF FAILED" end
    if not stillCurrent() then return false,"TRIM HANDOVER SUPERSEDED" end
    local signal=Hardware.sampleActivation(config,api,"fine")
    if not stillCurrent() then return false,"TRIM HANDOVER SUPERSEDED" end
    if not signal.valid or signal.signalStrength~=0 then return false,"TRIM OFF READBACK FAILED" end
    local actual=Hardware.sampleConfigured({providers={trim}},api).providers[trim.name]
    if not stillCurrent() then return false,"TRIM HANDOVER SUPERSEDED" end
    if not actual or not actual.targetValid or actual.targetAmount~=trimFloor or
        not actual.signalValid or actual.signalStrength~=0 then return false,"TRIM OFF PROVIDER READBACK FAILED" end
    return true
end

-- @ama-section: Output operations | Verified targets applied under current authority.
-- @ama-summary: Apply the validated demand-driven activation and verify the resulting interface state.
function Hardware.activate(config, api, group, startup, isCurrent)
    local valid = Hardware.validateConfig(config)
    local systemsProbe=startup=="systems_probe" and group=="fine" and Hardware.systemsSupported(config)
    local systemsControl=startup=="systems_control" and
        (group=="bulk" or group=="fine") and Hardware.systemsSupported(config)
    if not valid then return false, "ACTIVATION_CONFIG_INVALID" end
    if systemsProbe or (systemsControl and group=="fine") then
        local trim
        for _,definition in ipairs(config.providers or {}) do
            if definition.controlRole=="fine" then
                if trim then return false,"SYSTEMS_TRIM_AMBIGUOUS" end
                trim=definition
            end
        end
        if not trim or trim.minimumNonzeroTarget~=5 then return false,"SYSTEMS_TRIM_CONFIGURATION_INVALID" end
        local typeOk, isBurner = callApi(api,"hasType",trim.name,"hot_air_burner")
        local target, targetOk = value(api,trim.name,"getTargetAmount","integer")
        if not typeOk or isBurner~=true or not targetOk or target<5 or target>trim.maxTarget then
            return false,"SYSTEMS_TRIM_NOT_READY"
        end
    end
    local current = Hardware.sampleActivation(config, api, group)
    if not current.valid or not current.writable then return false, current.reason end
    if isCurrent and not isCurrent() then return false,"ACTIVATION_AUTHORITY_EXPIRED" end
    if current.signalStrength == 15 then return true end
    local pair = config.activationFrequency
    if group == "fine" then pair = config.trimActivationFrequency end
    if isCurrent and not isCurrent() then return false,"ACTIVATION_AUTHORITY_EXPIRED" end
    local ok, result = callPeripheral(api, config.activationBridge, "sendLinkSignal", pair.first, pair.second, 15)
    if not ok or result == false then return false, "ACTIVATION_WRITE_FAILED" end
    if isCurrent and not isCurrent() then return false,"ACTIVATION_AUTHORITY_EXPIRED" end
    local after = Hardware.sampleActivation(config, api, group)
    if not after.valid or after.signalStrength ~= 15 then return false, "ACTIVATION_READBACK_PENDING" end
    return true
end

-- Explicit minimum-output vent startup, separate from flight commissioning.
-- The network payload cannot choose a larger ceiling or change the probe.
-- @ama-section: Endpoint context | Configuration, discovery and command identity.
-- @ama-summary: Check startup targets against configured provider bounds and current readbacks.
function Hardware.validateVentStartup(config,targets,snapshot)
    if config.ventStartupEnabled~=true or not config.activationBridge then return false,"VENT_STARTUP_DISABLED" end
    local bulk,fine=0,0
    for _,definition in ipairs(config.providers or {}) do
        local p=snapshot.providers[definition.name]
        if not p or not p.present or not p.writable or not p.targetValid or not p.signalValid then
            return false,"VENT_STARTUP_INTERFACE_INVALID"
        end
        if definition.controlRole=="bulk" then
            bulk=bulk+1
            if targets[definition.name]~=50 or definition.minimumNonzeroTarget~=50 or definition.maxTarget<50 then
                return false,"VENT_STARTUP_REQUIRES_50"
            end
            if p.signalStrength>1 and p.targetAmount~=50 then return false,"VENT_ALREADY_OPERATING" end
        elseif definition.controlRole=="fine" then
            fine=fine+1
            if targets[definition.name]~=p.targetAmount or p.targetAmount<5 or
                p.signalStrength~=15 or not p.attachedValid or not p.attached then
                return false,"VENT_STARTUP_REQUIRES_UNCHANGED_ACTIVE_PROBE"
            end
        else return false,"VENT_STARTUP_ROLE_INVALID" end
    end
    if bulk~=Hardware.steamCount(config) or fine~=1 then return false,"VENT_STARTUP_REQUIRES_CONFIGURED_VENTS_ONE_PROBE" end
    return true
end

-- Explicitly authorized bootstrap for envelope telemetry. This narrow path
-- can only start the one pinned hot-air burner at its five-unit floor. It
-- never enables steam, accepts network demand, or grants flight authority.
-- Preserve an already operating burner on restart instead of dropping trim.
-- @ama-summary: Establish the configured low-probe composition observation.
function Hardware.startCompositionProbe(config, api, isCurrent)
    if config.compositionProbeEnabled ~= true then return true, "DISABLED" end
    if not Hardware.validateConfig(config) then return false, "PROBE_CONFIG_INVALID" end
    local role=type(config.install)=="table" and config.install.role or config.role
    local expected=EXPECTED_ROLES[role]
    local pair=config.trimActivationFrequency
    if not expectedTrimFrequency(config) then return false,"PROBE_FREQUENCY_NOT_CONFIGURED" end
    local burner
    for _, definition in ipairs(config.providers) do
        if definition.controlRole == "fine" then
            if burner then return false, "PROBE_BURNER_AMBIGUOUS" end
            burner = definition
        end
    end
    if not burner or burner.minimumNonzeroTarget ~= 5 then return false, "PROBE_FLOOR_INVALID" end
    local ok, matches = callApi(api, "hasType", burner.name, "hot_air_burner")
    if not ok or not matches then return false, "PROBE_BURNER_MISSING" end
    local activation = Hardware.sampleActivation(config, api, "fine")
    local target, targetValid = value(api, burner.name, "getTargetAmount", "integer")
    local signal, signalValid = value(api, burner.name, "getSignalStrength", "integer")
    if not activation.valid or not targetValid or not signalValid then return false, "PROBE_READ_FAILED" end
    if signal > 0 and target>=5 then
        if target > burner.maxTarget then return false, "PROBE_ACTIVE_TARGET_INVALID" end
        return true, "PRESERVED_ACTIVE_BURNER"
    end
    if isCurrent and not isCurrent() then return false,"PROBE_HARDWARE_GENERATION_CHANGED" end
    local applied, reason = Hardware.applyTarget(api, burner.name, 5)
    if not applied then return false, reason end
    if isCurrent and not isCurrent() then return false,"PROBE_HARDWARE_GENERATION_CHANGED" end
    local sent, result = callPeripheral(api, config.activationBridge, "sendLinkSignal", pair.first, pair.second, 15)
    if not sent or result == false then return false, "PROBE_ACTIVATION_FAILED" end
    return true, "PROBE_STARTED_WAITING_FOR_ENVELOPE"
end

-- Read-only local world-Y sample. Each sensor is mounted four blocks above
-- its section's lowest point. Equal mounting references permit direct comparison;
-- this is neither CoM altitude nor a gyro output. Never keep an old good value
-- when a read fails. Ambiguous discovery requires an exact name in JSON.
-- @ama-section: Readbacks | Timestamped physical observations and status.
-- @ama-summary: Read and validate the role's configured altitude observation.
function Hardware.sampleAltitude(config, api, now)
    local result = { valid = false, unit = "world Y", sampledAt = now }
    if config.relayChildRole then
        -- Gas-provider getters yield while the relay receives newer packets.
        -- Validate against the clock now, not the start of that earlier scan.
        now=math.max(now,os.clock())
        result.sampledAt=now
        local a=os.__amaryllisCornerAltitude
        if a and a.valid and finite(a.receivedAt) and now>=a.receivedAt and now-a.receivedAt<=1.5 and
            finite(a.sampleEpochMs) and os.epoch("utc")>=a.sampleEpochMs and os.epoch("utc")-a.sampleEpochMs<=1500 then
            result.valid=true;result.sensorWorldY=a.sensorWorldY;result.lowestPointWorldY=a.sensorWorldY-4
            result.lowestPointOffsetBlocks=4;result.source="thrust:"..tostring(a.source)
        else
            local q=config.quadrant or ({chamber_fl="FL",chamber_fr="FR",chamber_bl="BL",chamber_br="BR"})[config.role]
            q=({RL="BL",RR="BR"})[q] or q or "UNKNOWN"
            local prefix=q.." CHAMBER THRUST "
            local runtime=os.__amaryllisRuntime or {}
            local peer=(runtime.components or {}).thrust or {}
            local function recent(at) return finite(at) and now>=at and now-at<=1.5 end
            local responding=recent(peer.lastResponseAt) or (a and recent(a.receivedAt))
            if not responding then result.reason=prefix.."COM UNRESPONSIVE"
            elseif not a or a.valid~=true then result.reason=prefix.."ALTITUDE UNAVAILABLE"
            else result.reason=prefix.."ALTITUDE NOT UPDATING" end
        end
        return result
    end
    local definition = config.altitudeSensor
    if type(definition) ~= "table" then
        result.reason = "ALTITUDE_SENSOR_NOT_CONFIGURED"
        return result
    end
    local name = definition.name
    if name == "" then
        local ok, names = callApi(api, "getNames")
        local candidates = {}
        if ok and type(names) == "table" then
            for _, candidate in ipairs(names) do
                local typeOk, matches = callApi(api, "hasType", candidate, "altitude_sensor")
                if typeOk and matches == true then candidates[#candidates + 1] = candidate end
            end
        end
        if #candidates ~= 1 then
            result.reason = #candidates > 1 and "ALTITUDE_SENSOR_AMBIGUOUS" or "ALTITUDE_SENSOR_MISSING"
            return result
        end
        name = candidates[1]
    end
    result.source = name
    local typeOk, matches = callApi(api, "hasType", name, "altitude_sensor")
    local methods = methodSet(api, name)
    if not typeOk or matches ~= true or not methods or not methods.getHeight then
        result.reason = "ALTITUDE_SENSOR_METHOD_OR_TYPE_MISSING"
        return result
    end
    local height, valid, reason = value(api, name, "getHeight", "number")
    if not valid then result.reason = "ALTITUDE_SENSOR_INVALID"; result.detail = reason; return result end
    result.valid = true
    result.sensorWorldY = height
    result.lowestPointWorldY = height - definition.lowestPointOffsetBlocks
    result.lowestPointOffsetBlocks = definition.lowestPointOffsetBlocks
    if definition.includeVerticalSpeed~=false and methods.getVerticalSpeed then
        local speed, speedValid = value(api, name, "getVerticalSpeed", "number")
        result.verticalSpeedValid = speedValid
        if speedValid then result.verticalSpeed = speed end
    end
    return result
end

-- Reports a single balloon using one explicitly selected, verified provider.
-- Optional getters are called only when getMethods says that method exists.
-- @ama-summary: Reports a single balloon using one explicitly selected, verified provider. Optional getters are called only when getMethods says that method exists.
local function sampleBalloonSource(config, providers, api)
    local source = config.balloonRepresentative
    if type(source) ~= "string" or source == "" then return nil end
    local provider = providers and providers[source]
    if not provider or provider.present ~= true then return nil end
    if provider.signalValid~=true or not provider.signalStrength or provider.signalStrength<=1 then return nil end

    local methods = methodSet(api, source)
    if not methods then return { source = source, valid = false } end

    local result = { source = source, hasBalloonValid = false, gasMixValid = false }
    if methods.hasBalloon then
        local attached, attachedValid = value(api, source, "hasBalloon", "boolean")
        result.hasBalloonValid = attachedValid
        if attachedValid then result.hasBalloon = attached end
        if not attachedValid or attached ~= true then
            result.valid = false
            result.liftValid = false
            result.filledVolumeValid = false
            result.targetVolumeValid = false
            result.capacityValid = false
            result.heightValid = false
            result.volumeChangeValid = false
            return result
        end
    else
        result.valid = false
        result.liftValid = false
        result.filledVolumeValid = false
        result.targetVolumeValid = false
        result.capacityValid = false
        result.heightValid = false
        result.volumeChangeValid = false
        return result
    end

    local getters = {
        { key = "lift", method = "getBalloonLift", type = "number" },
        { key = "filledVolume", method = "getBalloonFilledVolume", type = "number" },
        { key = "targetVolume", method = "getBalloonTargetVolume", type = "number" },
        { key = "capacity", method = "getBalloonCapacity", type = "number" },
        { key = "height", method = "getBalloonHeight", type = "number" },
        { key = "volumeChange", method = "getBalloonVolumeChange", type = "number" },
    }
    -- One representative reads the entire envelope. Reading every vent and
    -- adding its result would count the same gas eight times. The peripheral
    -- returns a list of {type, amount}, not a map or a percentage.
    if methods.getBalloonGasMix then
        local ok, mix = callPeripheral(api, source, "getBalloonGasMix")
        local clean, total, count, valid = {}, 0, 0, ok and type(mix) == "table"
        if valid then
            for key, item in pairs(mix) do
                count = count + 1
                if count > 16 or not integer(key) or key < 1 or key > #mix or
                    type(item) ~= "table" or type(item.type) ~= "string" or
                    #item.type == 0 or #item.type > 96 or not finite(item.amount) or item.amount < 0 then
                    valid = false; break
                end
                clean[item.type] = (clean[item.type] or 0) + item.amount
                total = total + item.amount
            end
        end
        if valid and count == #mix and finite(total) and total > 0 then
            result.gasMix, result.gasMixAmount, result.gasMixValid = clean, total, true
            result.gasFractions = {}
            for gas, amount in pairs(clean) do result.gasFractions[gas] = amount / total end
        else result.gasMixError = "EMPTY_OR_INVALID_GAS_MIX" end
    else result.gasMixError = "GAS_MIX_METHOD_UNAVAILABLE" end
    local anyValue = false
    for _, getter in ipairs(getters) do
        local validKey = getter.key .. "Valid"
        if methods[getter.method] then
            local sample, valid = value(api, source, getter.method, getter.type)
            result[validKey] = valid
            if valid then result[getter.key] = sample; anyValue = true end
        else
            result[validKey] = false
        end
    end
    result.valid = anyValue
    return result
end

-- @ama-summary: Read envelope composition, volume, lift and representative-balloon status.
function Hardware.sampleBalloon(config,providers,api,role)
    local candidates={}
    for name,p in pairs(providers or {}) do
        if p.present and p.targetValid and p.targetAmount>0 and p.signalValid and p.signalStrength>0 and (not role or p.controlRole==role) then
            candidates[#candidates+1]=name
        end
    end
    table.sort(candidates,function(a,b)
        local pa,pb=providers[a],providers[b]
        if pa.controlRole~=pb.controlRole then return pa.controlRole=="bulk" end
        return a<b
    end)
    local last
    for _,name in ipairs(candidates) do
        local selected={} for k,v in pairs(config) do selected[k]=v end
        selected.balloonRepresentative=name
        local result=sampleBalloonSource(selected,providers,api)
        if result and result.hasBalloonValid and result.hasBalloon and result.liftValid and result.gasMixValid then return result end
        last=result or last
    end
    if role then return last end
    return sampleBalloonSource(config,providers,api) or last
end

-- Read-only inventory for `avionics/main.lua inspect`. It intentionally scans
-- every peripheral so an empty allowlist can be populated from actual evidence.
-- @ama-section: Endpoint context | Configuration, discovery and command identity.
-- @ama-summary: Read-only inventory for `avionics/main.lua inspect`. It intentionally scans every peripheral so an empty allowlist can be populated from actual evidence.
function Hardware.inspectAll(api)
    local ok, names = callApi(api, "getNames")
    if not ok or type(names) ~= "table" then return nil, "could not list peripherals: " .. tostring(names) end
    local inventory = {}
    local probes = {
        { key = "gas_provider", type = "gas_provider" },
        { key = "hot_air_burner", type = "hot_air_burner" },
        { key = "steam_vent", type = "steam_vent" },
        { key = "modem", type = "modem" },
        { key = "altitude_sensor", type = "altitude_sensor" },
    }
    local getters = {
        { "getHeight", "number" },
        { "getVerticalSpeed", "number" },
        { "getTargetAmount", "integer" },
        { "getGasOutput", "number" },
        { "getSignalStrength", "integer" },
        { "hasBalloon", "boolean" },
        { "isActive", "boolean" },
        { "getGasType", "string" },
        { "getBoilerEfficiency", "number" },
        { "getBalloonLift", "number" },
        { "getBalloonFilledVolume", "number" },
        { "getBalloonTargetVolume", "number" },
        { "getBalloonCapacity", "number" },
        { "getBalloonHeight", "number" },
        { "getBalloonVolumeChange", "number" },
    }

    for _, name in ipairs(sortedCopy(names)) do
        local entry = { name = name, types = {}, methods = {}, getters = {} }
        local typeOk, primaryType = callApi(api, "getType", name)
        if typeOk then entry.type = primaryType end
        for _, probe in ipairs(probes) do
            local hasOk, has = callApi(api, "hasType", name, probe.type)
            entry.types[probe.key] = hasOk and has == true
        end
        local methods = methodSet(api, name)
        if methods then
            for method in pairs(methods) do entry.methods[#entry.methods + 1] = method end
            table.sort(entry.methods)
            if entry.types.gas_provider or entry.types.hot_air_burner or entry.types.altitude_sensor then
                for _, getter in ipairs(getters) do
                    if methods[getter[1]] then
                        local sample, valid, err = value(api, name, getter[1], getter[2])
                        entry.getters[getter[1]] = { valid = valid, value = sample, error = err }
                    end
                end
            end
        else
            entry.methodsError = "peripheral.getMethods failed"
        end
        inventory[#inventory + 1] = entry
    end
    return inventory
end

function Hardware.requiredProviderMethods()
    local result = {}
    for _, method in ipairs(REQUIRED_PROVIDER_METHODS) do result[#result + 1] = method end
    return result
end

-- @ama-section: Readbacks | Timestamped physical observations and status.
-- @ama-summary: Collect the configured hardware interlock and output observations.
function Hardware.readSafetyState(api, name)
    -- Recheck physical preconditions immediately before each setter. Keeping
    -- these reads in the adapter makes the actuation boundary easy to audit.
    local typeOk, isProvider = callApi(api, "hasType", name, "gas_provider")
    if not typeOk or isProvider ~= true then return nil, "provider missing or has wrong type" end
    local signal, signalOk, signalError = value(api, name, "getSignalStrength", "integer")
    if not signalOk or signal < 0 or signal > 15 then return nil, signalError or "invalid activation signal" end
    local attached, attachedOk, attachedError = value(api, name, "hasBalloon", "boolean")
    if not attachedOk or attached ~= true then return nil, attachedError or "balloon is not attached" end
    local target, targetOk, targetError = value(api, name, "getTargetAmount", "integer")
    if not targetOk then return nil, targetError end
    local methods, methodsError = methodSet(api, name)
    if not methods then return nil, "could not inspect provider methods: " .. tostring(methodsError) end

    local result = {
        signalStrength = signal,
        attached = attached,
        targetAmount = target,
        activeSupported = methods.isActive == true,
        activeValid = false,
    }
    if result.activeSupported then
        local active, activeOk, activeError = value(api, name, "isActive", "boolean")
        if activeOk then
            result.activeValid = true
            result.active = active
        else
            result.activeError = activeError
        end
    end
    return result
end

-- The single target-write boundary for a lift node. Keep the peripheral API
-- call here so review and fake-hardware tests can find every actuator path in
-- one place. The caller must first validate the complete command, current
-- session, configured bounds, signal strength, and
-- balloon attachment. A setter is accepted only after exact integer readback.
-- @ama-section: Output operations | Verified targets applied under current authority.
-- @ama-summary: The single target-write boundary for a lift node. Keep the peripheral API call here so review and fake-hardware tests can find every actuator path in one place. The caller must first validate the complete command, current session, configured bounds, signal strength, and balloon attachment. A setter is accepted only after exact integer readback.
function Hardware.applyTarget(api, name, target)
    if type(name) ~= "string" or name == "" then
        return false, "provider name is invalid"
    end
    if not integer(target) or target < 0 or target > MAX_TARGET then
        return false, "target must be a non-negative integer"
    end

    local setOk, setResult = callPeripheral(api, name, "setTargetAmount", target)
    if not setOk or setResult == false then
        return false, "setter failed: " .. tostring(setResult)
    end

    local actual, readOk, readError = value(api, name, "getTargetAmount", "integer")
    if not readOk then
        return false, "target read-back failed: " .. tostring(readError)
    end
    if actual ~= target then
        return false, "read-back did not match requested target"
    end
    return true
end

Hardware.localPeripheral = function() return basePeripheralApi end
Hardware.remotePeripheral = function(config)
    local side=config and config.providerDiscovery and config.providerDiscovery.networkSide or "back"
    return makeRemotePeripheralApi(basePeripheralApi,{side},false)
end

return Hardware
end
-- @ama-section: Endpoint context | Configuration, discovery and command identity.
-- @ama-summary: Build bounded drive/readback operations for the supported thrust interface.
local function buildThrustAdapter()-- Read-only discovery and the sole transmission writer for thrust controllers.
-- This adapter uses only APIs checked in the installed Create Propulsion jar
-- and the existing Amaryllis propulsion reference. It never infers RPM or force
-- from a transmission shift-level readback.
local Hardware = {}

local defaultPeripheralApi = peripheral
local configuredPeripheralApi
local TRANSMISSION_TYPE = "redstone_transmission"
local BEARING_TYPE = "propeller_bearing"
local BRIDGE_TYPE = "redstone_link_bridge"
local MAX_SHIFT_LEVEL = 256 -- installed 1.1.5 source: ratio = shift_level / 256
local RAW_VALUE_LIMIT = 1000000000000 -- wire-format bound only; no measurement units are inferred

local function finite(value)
    return type(value) == "number" and value == value and
        value ~= math.huge and value ~= -math.huge
end

local function integer(value)
    return finite(value) and value % 1 == 0
end

-- @ama-summary: Return discovered names in deterministic order.
local function sortedNames(api)
    local ok, names = pcall(api.getNames)
    if not ok or type(names) ~= "table" then
        return nil, "could not list peripherals: " .. tostring(names)
    end
    table.sort(names)
    return names
end

-- @ama-summary: Check the reported peripheral type against the requested interface.
local function hasType(api, name, expected)
    if type(api.hasType) == "function" then
        local ok, result = pcall(api.hasType, name, expected)
        if ok and result == true then return true end
    end
    if type(api.getType) == "function" then
        local values = { pcall(api.getType, name) }
        if values[1] then
            for index = 2, #values do
                if values[index] == expected then return true end
            end
        end
    end
    return false
end

local function wrap(api, name)
    local ok, object = pcall(api.wrap, name)
    if not ok or type(object) ~= "table" then return nil end
    return object
end

local function invoke(object, method, ...)
    local fn = object and object[method]
    if type(fn) ~= "function" then return false, "missing " .. method end
    local result = { pcall(fn, ...) }
    if not result[1] then return false, tostring(result[2]) end
    return true, result[2]
end

local function readOptional(object, method, valid)
    if type(object and object[method]) ~= "function" then return nil, false end
    local ok, value = invoke(object, method)
    if not ok or not valid(value) then return nil, false end
    return value, true
end

local function validVector(value)
    if type(value) ~= "table" then return false end
    local x, y, z = value.x or value[1], value.y or value[2], value.z or value[3]
    return finite(x) and finite(y) and finite(z) and math.abs(x) <= RAW_VALUE_LIMIT and
        math.abs(y) <= RAW_VALUE_LIMIT and math.abs(z) <= RAW_VALUE_LIMIT
end

function Hardware.isFinite(value)
    return finite(value)
end

function Hardware.isInteger(value)
    return integer(value)
end

function Hardware.setPeripheralApi(api) configuredPeripheralApi=api end
-- @ama-summary: Construct the role's configured local/remote peripheral access.
function Hardware.remotePeripheral(config)
    local sides,seen={},{}
    local function add(side) if type(side)=="string" and not seen[side] then sides[#sides+1]=side;seen[side]=true end end
    for _,side in pairs(config and config.networks or {}) do add(side) end
    for _,binding in pairs(config and config.bindings or {}) do add(binding.networkSide) end
    if config and config.primaryDirection and config.primaryDirection.link then add(config.primaryDirection.link.side) end
    add("top")
    return makeRemotePeripheralApi(defaultPeripheralApi,sides)
end

-- @ama-summary: Discover and bind the configured role hardware.
function Hardware.discover(api)
    api = api or configuredPeripheralApi or defaultPeripheralApi
    if type(api) ~= "table" or type(api.getNames) ~= "function" or type(api.wrap) ~= "function" then
        return nil, "ComputerCraft peripheral API is unavailable"
    end
    local names, reason = sortedNames(api)
    if not names then return nil, reason end
    local found = { all = {}, transmissions = {}, bearings = {}, bridges = {} }
    for _, name in ipairs(names) do
        local object = wrap(api, name)
        if object then
            local routeSide = type(api.getRouteSide)=="function" and api.getRouteSide(name) or nil
            local entry = { name = name, object = object, networkSide = routeSide }
            found.all[#found.all + 1] = entry
            if hasType(api, name, TRANSMISSION_TYPE) then
                found.transmissions[#found.transmissions + 1] = entry
            end
            if hasType(api, name, BEARING_TYPE) then
                found.bearings[#found.bearings + 1] = entry
            end
            if hasType(api, name, BRIDGE_TYPE) then
                found.bridges[#found.bridges + 1] = entry
            end
        end
    end
    return found
end

-- @ama-summary: Build the deterministic configured hardware identity used by binding checks.
function Hardware.inventoryFingerprint(role, bindings)
    local rows = { tostring(role or "") }
    local names = {}
    for drive, binding in pairs(bindings or {}) do names[#names + 1] = drive end
    table.sort(names)
    for _, drive in ipairs(names) do
        local binding = bindings[drive] or {}
        rows[#rows + 1] = drive .. "=" .. (binding.networkSide and ("@" .. tostring(binding.networkSide)) or tostring(binding.peripheral or ""))
    end
    return table.concat(rows, "|")
end

-- Sensor role reads only known PropellerBearing getters. Each raw field keeps
-- its getter name and validity flag, so an undocumented unit is never invented.
-- @ama-section: Readbacks | Timestamped physical observations and status.
-- @ama-summary: Read and validate one configured propulsion bearing observation.
function Hardware.readBearing(entry)
    local object = entry and entry.object
    if not object then return nil, "bearing is unavailable" end
    local reading = { name = tostring(entry.name or "unknown"):gsub("[%c]", " "):sub(1, 128), validity = {} }
    local fields = {
        { getter = "getSpeed", field = "speedRaw", valid = function(v) return finite(v) and math.abs(v) <= RAW_VALUE_LIMIT end },
        { getter = "getThrust", field = "thrustRaw", valid = function(v) return finite(v) and math.abs(v) <= RAW_VALUE_LIMIT end },
        { getter = "getThrustVector", field = "thrustVector", valid = validVector },
        { getter = "getThrustHandedness", field = "thrustHandedness", valid = function(v)
            return v == "left_handed" or v == "right_handed"
        end },
        { getter = "isAssembled", field = "assembled", valid = function(v) return type(v) == "boolean" end },
    }
    for _, definition in ipairs(fields) do
        local value, valid = readOptional(object, definition.getter, definition.valid)
        reading.validity[definition.field] = valid
        if valid then reading[definition.field] = value end
    end
    return reading
end

-- @ama-summary: Read the configured propulsion bearing observations.
function Hardware.readBearings(found)
    local readings = {}
    local allThrustAndAxisValid = #((found and found.bearings) or {}) > 0
    local anyUseful = false
    for _, entry in ipairs((found and found.bearings) or {}) do
        if #readings >= 32 then break end -- stay inside the core's bounded packet schema
        local reading = Hardware.readBearing(entry)
        readings[#readings + 1] = reading
        if not reading.validity.thrustRaw or not reading.validity.thrustVector then
            allThrustAndAxisValid = false
        end
        if reading.validity.speedRaw or reading.validity.thrustRaw or reading.validity.thrustVector then
            anyUseful = true
        end
    end
    return readings, allThrustAndAxisValid, anyUseful
end

-- @ama-section: Endpoint context | Configuration, discovery and command identity.
-- @ama-summary: Resolve the configured controller-to-drive hardware bindings.
function Hardware.controllerBindings(config, found)
    local bindings, reasons = {}, {}
    local source = config and config.bindings or {}
    local byName = {}
    for _, entry in ipairs((found and found.transmissions) or {}) do
        byName[entry.name] = entry
    end
    for drive, definition in pairs((config and config.drives) or {}) do
        local binding = source[drive] or {}
        local name = binding.peripheral
        local selected
        if type(binding.networkSide)=="string" then
            local candidates={}
            for _,entry in ipairs((found and found.transmissions) or {}) do
                if entry.networkSide==binding.networkSide then candidates[#candidates+1]=entry end
            end
            if #candidates==1 then selected=candidates[1]
            elseif #candidates>1 then reasons[#reasons+1]="TRANSMISSION_AMBIGUOUS_ON_NETWORK:"..drive end
        elseif type(name)=="string" and name~="" then
            selected=byName[name]
            if not selected and name=="top" then
                local candidates={}
                for _,entry in ipairs((found and found.transmissions) or {}) do if entry.networkSide=="top" then candidates[#candidates+1]=entry end end
                if #candidates==1 then selected=candidates[1] elseif #candidates>1 then reasons[#reasons+1]="TRANSMISSION_AMBIGUOUS_ON_TOP:"..drive end
            end
        end
        if (type(name)~="string" or name=="") and type(binding.networkSide)~="string" then
            reasons[#reasons+1]="UNBOUND_TRANSMISSION:"..drive
        elseif not selected then
            reasons[#reasons+1]="TRANSMISSION_MISSING_OR_WRONG_TYPE:"..drive
        else
            local object=selected.object
            for _,method in ipairs({"getTransmissionMode","setTransmissionMode","getShiftLevel","setShiftLevel"}) do
                if type(object[method])~="function" then reasons[#reasons+1]="TRANSMISSION_METHOD_MISSING:"..drive..":"..method end
            end
            bindings[drive]={name=selected.name,object=object,definition=definition,binding=binding,networkSide=selected.networkSide}
        end
    end
    local used = {}
    for drive, binding in pairs(bindings) do
        if used[binding.name] then reasons[#reasons + 1] = "TRANSMISSION_BOUND_TWICE:" .. drive
        else used[binding.name] = drive end
    end
    return bindings, reasons
end

-- @ama-section: Readbacks | Timestamped physical observations and status.
-- @ama-summary: Read the selected gearshift's current drive level.
function Hardware.readShift(binding, allowed)
    if not binding or not binding.object then return nil, "transmission is not bound" end
    local modeOk, mode = invoke(binding.object, "getTransmissionMode")
    if not modeOk then return nil, "getTransmissionMode failed: " .. tostring(mode) end
    if type(allowed) == "function" and not allowed() then return nil, "command authority expired after reading mode" end
    local levelOk, level = invoke(binding.object, "getShiftLevel")
    if not levelOk then return nil, "getShiftLevel failed: " .. tostring(level) end
    if type(allowed) == "function" and not allowed() then return nil, "command authority expired after reading shift" end
    mode = type(mode) == "string" and mode:lower() or mode
    if mode == "incremental" then
        if not integer(level) or level < 0 or level > MAX_SHIFT_LEVEL then
            return nil, "incremental shift readback is outside 0..256"
        end
    elseif mode == "direct" then
        -- Direct mode reports a 0..15 value. Preserve it as raw readback and
        -- leave controller command readiness false until mode is verified.
        if not integer(level) or level < 0 or level > 15 then
            return nil, "direct shift readback is outside 0..15"
        end
    else
        return nil, "transmission mode readback is invalid"
    end
    return level, nil, mode
end

-- @ama-summary: Read and validate the configured controller drive levels.
function Hardware.readReadbacks(bindings)
    local result = {}
    for drive, binding in pairs(bindings or {}) do
        local level, reason, mode = Hardware.readShift(binding)
        result[drive] = { shiftLevel = level, mode = mode, valid = level ~= nil, reason = reason }
    end
    return result
end

-- Calling setters is deliberately isolated here. The caller must first pass
-- config, session, sole-writer, slew, and opposition checks in main.lua.
-- @ama-section: Output operations | Verified targets applied under current authority.
-- @ama-summary: Calling setters is deliberately isolated here. The caller must first pass config, session, sole-writer, slew, and opposition checks in main.lua.
function Hardware.writeShift(binding, level, allowed)
    if type(allowed) == "function" and not allowed() then return false, "command authority expired" end
    if not integer(level) or level < 0 or level > MAX_SHIFT_LEVEL then
        return false, "shift level must be an integer from 0 through 256"
    end
    local object = binding and binding.object
    if not object then return false, "transmission is not bound" end
    local modeOk, mode = invoke(object, "getTransmissionMode")
    if not modeOk then return false, "getTransmissionMode failed: " .. tostring(mode) end
    if type(allowed) == "function" and not allowed() then return false, "command authority expired after reading mode" end
    mode = type(mode) == "string" and mode:lower() or mode
    if mode ~= "incremental" then return false, "transmission mode must already be incremental" end
    local setOk, setError = invoke(object, "setShiftLevel", level)
    if not setOk then return false, "setShiftLevel failed: " .. tostring(setError) end
    if type(allowed) == "function" and not allowed() then return false, "command authority expired after setting shift level" end
    return true
end

-- Safe zero is allowed after a command lease expires so the controller can
-- ramp down. It still verifies the live mode and shift range on every call.
-- @ama-summary: Safe zero is allowed after a command lease expires so the controller can ramp down. It still verifies the live mode and shift range on every call.
function Hardware.writeSafeZero(binding, allowed)
    local object = binding and binding.object
    if not object then return false, "transmission is not bound" end
    if type(allowed) == "function" and not allowed() then return false, "writer job was superseded" end
    local modeOk, mode = invoke(object, "getTransmissionMode")
    if not modeOk then return false, "getTransmissionMode failed: " .. tostring(mode) end
    if type(allowed) == "function" and not allowed() then return false, "writer job was superseded after reading mode" end
    mode = type(mode) == "string" and mode:lower() or mode
    local levelOk, level = invoke(object, "getShiftLevel")
    if not levelOk then return false, "getShiftLevel failed: " .. tostring(level) end
    if type(allowed) == "function" and not allowed() then return false, "writer job was superseded after reading shift" end
    if mode == "direct" then
        if not integer(level) or level < 0 or level > 15 then return false, "direct shift readback is outside 0..15" end
    elseif mode == "incremental" then
        if not integer(level) or level < 0 or level > MAX_SHIFT_LEVEL then return false, "incremental shift readback is outside 0..256" end
    else
        return false, "transmission mode readback is invalid"
    end
    local zeroOk, zeroError = invoke(object, "setShiftLevel", 0)
    if not zeroOk then return false, "safe zero command failed: " .. tostring(zeroError) end
    if type(allowed) == "function" and not allowed() then return false, "writer job was superseded after safe zero" end
    return true
end

-- One-shot startup commissioning is deliberately separate from the runtime
-- writer. It first validates every transmission, then zeroes every drive and
-- reads all zeros back before changing any mode. The caller runs this before
-- starting network/writer loops, so no command task can race these setters.
-- @ama-summary: Verify configured drive zero and bounded incremental commissioning readbacks.
function Hardware.commissionZeroAndIncremental(bindings, drives, allowed, wait)
    local function stillAllowed()
        return type(allowed) ~= "function" or allowed() == true
    end
    if type(bindings) ~= "table" or type(drives) ~= "table" or #drives == 0 then
        return false, "commissioning has no configured drives"
    end
    local before = {}
    for _, drive in ipairs(drives) do
        if not stillAllowed() then return false, "commissioning authority expired during preflight" end
        local binding = bindings[drive]
        if not binding or not binding.object then return false, "commissioning drive is unbound: " .. tostring(drive) end
        for _, method in ipairs({ "getTransmissionMode", "setTransmissionMode", "getShiftLevel", "setShiftLevel" }) do
            if type(binding.object[method]) ~= "function" then
                return false, "commissioning method missing for " .. tostring(drive) .. ": " .. method
            end
        end
        local level, reason, mode = Hardware.readShift(binding, stillAllowed)
        if level == nil then return false, "commissioning preflight failed for " .. tostring(drive) .. ": " .. tostring(reason) end
        before[drive] = { level = level, mode = mode }
    end

    -- Establish a complete zero baseline before any mode setter is called.
    for _, drive in ipairs(drives) do
        if not stillAllowed() then return false, "commissioning authority expired before zero write" end
        local ok, reason = invoke(bindings[drive].object, "setShiftLevel", 0)
        if not ok then return false, "zero write failed for " .. tostring(drive) .. ": " .. tostring(reason) end
        if not stillAllowed() then return false, "commissioning authority expired after zero write" end
    end
    -- @ama-summary: Verify each configured output against the requested target and current authority.
    local function verifyAll(predicate, description)
        local lastReason
        for attempt = 1, 10 do
            local allVerified = true
            for _, drive in ipairs(drives) do
                if not stillAllowed() then return false, "commissioning authority expired during " .. description end
                local level, reason, mode = Hardware.readShift(bindings[drive], stillAllowed)
                if level == nil or not predicate(level, mode) then
                    allVerified = false
                    lastReason = tostring(reason or ("expected " .. description .. ", got mode=" ..
                        tostring(mode) .. " level=" .. tostring(level) .. " on " .. tostring(drive)))
                end
            end
            if allVerified then return true end
            if attempt < 10 and type(wait) == "function" then
                if not stillAllowed() then return false, "commissioning authority expired before " .. description .. " retry" end
                local ok, reason = pcall(wait, 0.1)
                if not ok then return false, "commissioning wait failed: " .. tostring(reason) end
            end
        end
        return false, description .. " readback timed out: " .. tostring(lastReason)
    end
    local zeroVerified, zeroReason = verifyAll(function(level) return level == 0 end, "zero")
    if not zeroVerified then
        return false, zeroReason
    end

    -- Only after every output reads zero may a direct-mode transmission move
    -- into incremental mode. Already-incremental devices are left untouched.
    for _, drive in ipairs(drives) do
        if before[drive].mode ~= "incremental" then
            if not stillAllowed() then return false, "commissioning authority expired before mode write" end
            local ok, reason = invoke(bindings[drive].object, "setTransmissionMode", "incremental")
            if not ok then return false, "incremental mode write failed for " .. tostring(drive) .. ": " .. tostring(reason) end
            if not stillAllowed() then return false, "commissioning authority expired after mode write" end
        end
    end
    local finalVerified, finalReason = verifyAll(function(level, mode)
        return mode == "incremental" and level == 0
    end, "incremental zero")
    if not finalVerified then
        return false, finalReason
    end
    return true
end

function Hardware.expectedShift(normalized, zeroLevel, fullLevel)
    if not finite(normalized) or normalized < 0 or normalized > 1 then return nil end
    if not integer(zeroLevel) or not integer(fullLevel) or zeroLevel < 0 or fullLevel > MAX_SHIFT_LEVEL or
        fullLevel < zeroLevel then return nil end
    return math.floor(zeroLevel + (fullLevel - zeroLevel) * normalized + 0.5)
end

-- @ama-section: Endpoint context | Configuration, discovery and command identity.
-- @ama-summary: Resolve the configured primary-propeller direction-control link.
function Hardware.primaryDirectionBinding(config, found)
    local definition=config and config.primaryDirection and config.primaryDirection.link
    if type(definition)~="table" or type(definition.side)~="string" then return nil,"DIRECTION_LINK_NOT_CONFIGURED" end
    local matches={}
    for _,entry in ipairs((found and found.bridges) or {}) do if entry.networkSide==definition.side then matches[#matches+1]=entry end end
    if #matches~=1 then return nil,#matches==0 and "DIRECTION_BRIDGE_MISSING" or "DIRECTION_BRIDGE_AMBIGUOUS" end
    local object=matches[1].object
    if type(object.getLinkSignal)~="function" or type(object.sendLinkSignal)~="function" then return nil,"DIRECTION_BRIDGE_METHOD_MISSING" end
    return {object=object,name=matches[1].name,link=definition}
end

function Hardware.readDirectionSignal(binding)
    if not binding or not binding.object then return nil,"DIRECTION_BRIDGE_UNAVAILABLE" end
    local ok,signal=invoke(binding.object,"getLinkSignal",binding.link.itemID1,binding.link.itemID2)
    if not ok or not integer(signal) or (signal~=0 and signal~=15) then return nil,"DIRECTION_SIGNAL_READBACK_INVALID" end
    return signal
end

-- @ama-section: Output operations | Verified targets applied under current authority.
-- @ama-summary: Write the validated direction signal to its configured link.
function Hardware.writeDirectionSignal(binding,signal,allowed,wait)
    if not binding or not binding.object or (signal~=0 and signal~=15) then return false,"DIRECTION_REQUEST_INVALID" end
    if type(allowed)=="function" and not allowed() then return false,"DIRECTION_AUTHORITY_EXPIRED" end
    local sent,reason=invoke(binding.object,"sendLinkSignal",binding.link.itemID1,binding.link.itemID2,signal)
    if not sent then return false,"DIRECTION_LINK_WRITE_FAILED:"..tostring(reason) end
    if type(allowed)=="function" and not allowed() then return false,"DIRECTION_AUTHORITY_EXPIRED_AFTER_WRITE" end
    wait=wait or (os and os.sleep) or rawget(_G,"sleep")
    local readError
    for attempt=1,3 do
        if type(allowed)=="function" and not allowed() then return false,"DIRECTION_AUTHORITY_EXPIRED_AFTER_WRITE" end
        local actual,issue=Hardware.readDirectionSignal(binding)
        readError=issue
        if type(allowed)=="function" and not allowed() then return false,"DIRECTION_AUTHORITY_EXPIRED_AFTER_WRITE" end
        if actual==signal then return true end
        if attempt<3 and type(wait)=="function" then wait(0.05) else break end
    end
    return false,readError or "DIRECTION_SIGNAL_READBACK_MISMATCH"
end
Hardware.constants = {
    transmissionType = TRANSMISSION_TYPE,
    bearingType = BEARING_TYPE,
    bridgeType = BRIDGE_TYPE,
    maxShiftLevel = MAX_SHIFT_LEVEL,
}

return Hardware
end
return { lift = buildLiftAdapter(), thrust = buildThrustAdapter() }
