-- @ama-section: Core boundary | Hardware observations, trusted fleet packets and bounded commands.
-- Sable-first assembly verification v1
-- Identity conflict advisory v1
local IdentityWatch=require("avionics.identity_watch")
local function steamCount(node) return node and node.steamCount or 8 end
-- Hardware and network boundary for core 35.
-- Startup reads sensors and status only. Bench lift writes require several explicit gates.
local IO = { PROTOCOL = "amaryllis.v1" }
local Thrust = require("avionics.thrust")
local Fleet = require("avionics.fleet")
local VesselSources = require("avionics.vessel_sources")

local ROLE_MANIFESTS={
    navigator="/installer/library.json",
    ["heading-left"]="/installer/library.json",
    ["heading-right"]="/installer/library.json",
    ["heading-main"]="/installer/library.json",
    chamber_fl="/installer/library.json",
    chamber_fr="/installer/library.json",
    chamber_bl="/installer/library.json",
    chamber_br="/installer/library.json",
    primary_l="/installer/library.json",
    primary_r="/installer/library.json",
}

local QUADRANTS = { "FL", "FR", "RL", "RR" }
local QUADRANT_ROLE = {FL="chamber_fl", FR="chamber_fr", RL="chamber_bl", RR="chamber_br"}
local CONTROL_CONTEXT_LEASE_SECONDS = 1.5
local HEADING_ROLES = {
    {key="heading-main", role="heading", description="center heading / altitude"},
    {key="heading-right", role="heading", description="right heading display"},
    {key="heading-left", role="heading", description="left heading display"},
}
local INPUT_ORDER = {
    "left_press", "left_lift", "right_press", "right_lift", "prop_forward",
    "prop_reverse", "ap_disconnect", "altitude_up", "altitude_down",
}

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
    return finite(value) and value % 1 == 0 and value >= minimum and value <= maximum
end

local function diagnosticEpoch()
    if type(os.epoch)~="function" then return nil end
    local ok,value=pcall(os.epoch,"utc")
    if ok and integer(value,0,9007199254740991) then return value end
end
local function liftDebugEvent(io,event)
    local recorder=io.debugRecorder
    if recorder and recorder.enabled and type(recorder.liftEvent)=="function" then
        -- Optional diagnostics must never reject a status or interrupt a send.
        pcall(recorder.liftEvent,recorder,event)
    end
end

local function text(value, limit)
    return string.sub(string.gsub(tostring(value or ""), "[%c]", " "), 1, limit or 160)
end

local function boundedString(value, limit)
    return type(value) == "string" and #value > 0 and #value <= (limit or 128)
end

-- @ama-section: Core context | Registry, hardware discovery and protocol identity.
-- @ama-summary: Add a measured value, source and timestamp to the current vessel snapshot.
local function field(value, name, index)
    if type(value) ~= "table" and type(value) ~= "userdata" then return nil end
    local ok, result = pcall(function() return value[name] end)
    if ok and result ~= nil then return result end
    if index then
        ok, result = pcall(function() return value[index] end)
        if ok then return result end
    end
    return nil
end

local function vector(value)
    local x, y, z = field(value, "x", 1), field(value, "y", 2), field(value, "z", 3)
    if finite(x) and finite(y) and finite(z) then return { x = x, y = y, z = z } end
end

local function safeCall(api, method, ...)
    if type(api) ~= "table" or type(api[method]) ~= "function" then return nil, method .. "() unavailable" end
    local ok, result = pcall(api[method], ...)
    if not ok then return nil, method .. "() failed: " .. text(result) end
    return result
end

-- @ama-summary: Run independent getter jobs and collect their completion results.
local function runParallel(parallelApi, tasks)
    -- Keep peripheral calls in the sampling coroutine. The top-level runtime
    -- runs this worker beside its rednet/event loop, so a yielding API call
    -- cannot consume cockpit touches or network status events.
    local waitForAll=parallelApi and parallelApi.waitForAll
    if type(waitForAll)~="function" then
        for _, task in ipairs(tasks) do task() end
        return true
    end
    local arguments={}
    for index,task in ipairs(tasks) do arguments[index]=task end
    local unpackValues=table.unpack or unpack
    local ok,issue=pcall(waitForAll,unpackValues(arguments,1,#arguments))
    if not ok then return false,text(issue) end
    return true
end

-- @ama-summary: Return the shared runtime clock in seconds.
local function nowSeconds(osApi)
    if osApi and type(osApi.epoch) == "function" then
        local ok, ms = pcall(osApi.epoch, "utc")
        if ok and finite(ms) then return ms / 1000 end
    end
    if osApi and type(osApi.clock) == "function" then
        local ok, value = pcall(osApi.clock)
        if ok and finite(value) then return value end
    end
    return 0
end

-- @ama-summary: Generate the bounded session identifier used to correlate core traffic.
local function newSession(id,osApi)
    local epoch=math.floor(nowSeconds(osApi)*1000)
    local uptime=0
    if osApi and type(osApi.clock)=="function" then
        local ok,value=pcall(osApi.clock)
        if ok and finite(value) then uptime=math.floor(value*1000000) end
    end
    local nonce=""
    if type(math.random)=="function" then
        local ok,value=pcall(math.random,0,2147483646)
        if ok and finite(value) then nonce=tostring(math.floor(value)) end
    end
    if nonce=="" then nonce=tostring({}):gsub("[^%w]","") end
    return tostring(id).."-"..tostring(epoch).."-"..tostring(uptime).."-"..nonce
end

local function inList(list, wanted)
    for _, value in ipairs(list) do if value == wanted then return true end end
    return false
end

-- @ama-summary: Initialize a registered chamber's status, sequence and command state.
local function newNode(id, quadrant)
    return {id=id,quadrant=quadrant,boot=nil,retiredBoots={},statusSeq=nil,lastAppliedSeq=-1,
        lastReceivedSeq=0,lastSeen=nil,ready=false,armed=false,operationBusy=false,faults={"NO STATUS"},providers={},
        balloon=nil,startReady=false,systemsSupported=false,systemsStartReady=false,
        bindingFingerprint=nil,bindingFingerprintValid=false,bindingGeneration=nil,bootReason=nil,
        acceptedBootGeneration=0,bootPrevious=nil,bootChangedAt=nil,bootChangeHelloAt=nil,
        bootRebindTrusted=false,bootRebindTrustedAt=nil,
        systemsStage=nil,systemsProbeReady=false,emergencyStopAppliedSeq=nil,emergencyStopMode=nil,
        emergencyStopLatched=false,emergencyStopVerified=false,emergencyStopFault=nil}
end

-- @ama-summary: Normalize reported peripheral types into a bounded list.
local function typeList(peripheralApi, name)
    if not peripheralApi or type(peripheralApi.getType) ~= "function" then return {} end
    local result = { pcall(peripheralApi.getType, name) }
    local out = {}
    if result[1] then
        for i = 2, #result do if type(result[i]) == "string" then out[#out + 1] = result[i] end end
    end
    return out
end

local function hasMethod(peripheralApi, name, method)
    if not peripheralApi or type(peripheralApi.getMethods) ~= "function" then return false end
    local ok, methods = pcall(peripheralApi.getMethods, name)
    if not ok or type(methods) ~= "table" then return false end
    return inList(methods, method)
end

local function hasPeripheralType(peripheralApi, name, wanted)
    if peripheralApi and type(peripheralApi.hasType) == "function" then
        local ok, result = pcall(peripheralApi.hasType, name, wanted)
        if ok and result then return true end
    end
    return inList(typeList(peripheralApi, name), wanted)
end

-- @ama-summary: Construct core hardware, network and sensor state from the configured fleet.
function IO.new(config, dependencies)
    dependencies = dependencies or {}
    local self = setmetatable({}, { __index = IO })
    self.config = config
    self.os = dependencies.os or os
    self.peripheral = dependencies.peripheral or peripheral
    self.rednet = dependencies.rednet or rednet
    self.sublevel = dependencies.sublevel or sublevel
    self.aero = dependencies.aero or aero
    self.fleet = dependencies.fleet or Fleet.new()
    self.fs=dependencies.fs or fs
    self.json=dependencies.json or textutils
    self.vectorApi = dependencies.vector or rawget(_G,"vector")
    self.parallel = dependencies.parallel or parallel
    self.now = dependencies.now or function() return nowSeconds(self.os) end
    local id=dependencies.computerID
    if id==nil and self.os and type(self.os.getComputerID)=="function" then
        local ok,value=pcall(self.os.getComputerID)
        if ok and integer(value,0,65535) then id=value end
    end
    self.localID=id
    self.localLabel=dependencies.computerLabel
    if self.localLabel==nil and self.os and type(self.os.getComputerLabel)=="function" then
        local ok,value=pcall(self.os.getComputerLabel)
        if ok and type(value)=="string" then self.localLabel=value end
    end
    self.config.computer_id=id
    self.config.label=self.localLabel
    self.identityWatch=IdentityWatch.new()
    local epochOK,epochMs=pcall(function()return self.os.epoch("utc")end)
    self.identityStartedEpochMs=epochOK and epochMs or nil
    self.session = dependencies.session or newSession(id or self.fleet.coreID,self.os)
    self.statusSeq, self.commandSeq, self.lastIssuedSeq = 0, 0, 0
    self.controlContextSeq=0
    self.liftControlContexts={}
    self.lastHelloAt = nil
    self.inventory = { peripherals = {}, modems = {}, wirelessModems = {}, monitors = {}, linkBridge = nil, errors = {} }
    self.nodes = {}
    self.subsystemReports = {}
    self.roleReports = {}
    self.loggedStates = {}
    self.expectedPackages,self.packageErrors={},{}
    self:loadRoleManifests()
    self.thrust = Thrust.new(config)
    for _, quadrant in ipairs(QUADRANTS) do
        self.nodes[quadrant] = newNode(config.node_ids and config.node_ids[quadrant],quadrant)
    end
    self.vessel = { valid = false, reason = "Sable telemetry has not been sampled" }
    self.inputs = { valid = false, reason = "cockpit links have not been sampled", raw = {}, errors = {} }
    if self.fleet then self:setRegistry(self.fleet.computers, true) end
    return self
end

-- @ama-summary: Read expected package identities from the local installer catalog.
function IO:loadRoleManifests()
    local previous=self.expectedPackages or {}
    self.expectedPackages,self.packageErrors={},{}
    -- Disk-library role metadata remains local when media is removed.
    local catalog
    if self.fs and self.json then
        local ok,handle=pcall(self.fs.open,"/installer/library.json","r")
        if not ok or not handle then ok,handle=pcall(self.fs.open,"/installer/library.json.amaryllis-backup","r") end
        if ok and handle then
            local readOK,raw=pcall(handle.readAll);pcall(handle.close)
            if readOK and type(raw)=="string" and #raw<=65536 then
                local decoded,value=pcall(self.json.unserializeJSON,raw)
                if decoded and type(value)=="table" and value.schemaVersion==1 and type(value.roles)=="table" then catalog=value end
            end
        end
    end
    for role,path in pairs(ROLE_MANIFESTS) do
        local manifest=catalog and catalog.roles[role]
        if type(manifest)~="table" or not boundedString(manifest.packageId,64) or not integer(manifest.version,1,65535) then manifest=nil end
        if manifest then self.expectedPackages[role]={packageId=manifest.packageId,version=manifest.version}
        else self.packageErrors[role]="EXPECTED PACKAGE MANIFEST UNAVAILABLE: "..path end
    end
    for role in pairs(ROLE_MANIFESTS) do
        local old,current=previous[role],self.expectedPackages[role]
        if self.roleReports and (not old or not current or old.packageId~=current.packageId or old.version~=current.version) then
            self.roleReports[role]=nil
        end
    end
end

-- @ama-summary: Apply the configured role-to-computer registry to core routing state.
function IO:setRegistry(computers, initial)
    local valid, reason = Fleet.validateComputers(computers)
    if not valid then return false, reason end
    local oldComputers=self.computers or {}
    local oldNodes = self.config.node_ids or {}
    local oldDisplays = self.config.display_ids or {}
    local oldBridge = self.config.bridge_id
    self.computers = Fleet.clone(computers)
    if self.fleet then self.fleet.computers=Fleet.clone(computers) end
    local core=computers.core
    local expectedID=core and core.id or nil
    local expectedLabel=core and core.label or nil
    if expectedID==self.localID and boundedString(expectedLabel,64) and self.localLabel~=expectedLabel and
        self.os and type(self.os.setComputerLabel)=="function" then
        local renamed,result=pcall(self.os.setComputerLabel,expectedLabel)
        if renamed and result~=false then
            self.localLabel=expectedLabel;self.config.label=expectedLabel
        end
    end
    if self.localID==nil or expectedID~=self.localID then
        self.identityReady=false
        self.identityReason="CORE ID DOES NOT MATCH THE FLEET REGISTRY"
    elseif not boundedString(expectedLabel,64) or self.localLabel~=expectedLabel then
        self.identityReady=false
        self.identityReason="CORE LABEL DOES NOT MATCH THE FLEET REGISTRY"
    else
        self.identityReady=true
        self.identityReason=nil
    end
    self.config.label=expectedLabel
    local nodeIds, roleIds, labels = {}, {}, {}
    local function entry(role) return computers[role] end
    local function id(role) local value=entry(role); return value and value.id or nil end
    local function label(role)
        local value=entry(role)
        return value and value.label or nil
    end
    for quadrant, role in pairs(QUADRANT_ROLE) do nodeIds[quadrant]=id(role) end
    roleIds["thrust-lb"],roleIds["thrust-rb"] = id("chamber_fl"),id("chamber_fr")
    roleIds["thrust-ls"],roleIds["thrust-rs"] = id("chamber_bl"),id("chamber_br")
    roleIds["primary-left"],roleIds["primary-right"] = id("primary_l"),id("primary_r")
    for _, role in ipairs(Fleet.ROLE_ORDER) do labels[role]=label(role) end
    self.config.node_ids=nodeIds
    self.config.display_ids={center=id("heading-main"),right=id("heading-right"),left=id("heading-left")}
    self.config.bridge_id=id("navigator")
    self.config.role_ids=roleIds
    self.config.role_labels=labels
    if self.thrust and type(self.thrust.setRegistry) == "function" then self.thrust:setRegistry(roleIds,self) end

    for _, quadrant in ipairs(QUADRANTS) do
        local oldID,newID=oldNodes[quadrant],nodeIds[quadrant]
        if not initial and oldID~=newID then
            local previous=self.nodes[quadrant] or newNode(oldID,quadrant)
            local retired=previous.retiredBoots or {}
            if previous.boot then retired[previous.boot]=true end
            local reset=newNode(newID,quadrant); reset.retiredBoots=retired
            self.nodes[quadrant]=reset
        else
            self.nodes[quadrant]=self.nodes[quadrant] or newNode(newID,quadrant)
            self.nodes[quadrant].id=newID
        end
    end

    if not initial then
        for _, item in ipairs(HEADING_ROLES) do
            local previousID=oldDisplays[item.key=="heading-main" and "center" or
                (item.key=="heading-right" and "right" or "left")]
            local nextID=id(item.key)
            local previousEntry=oldComputers[item.key]
            local nextEntry=computers[item.key]
            local labelChanged=(previousEntry and previousEntry.label or nil)~=
                (nextEntry and nextEntry.label or nil)
            if previousID~=nextID or labelChanged then
                local report=previousID and self.subsystemReports[previousID] or nil
                if report and report.boot then
                    report.retired=report.retired or {}; report.retired[report.boot]=true
                    report.boot,report.seq,report.at=nil,nil,nil
                    if nextID then self.subsystemReports[nextID]=report end
                elseif nextID then self.subsystemReports[nextID]=nil end
                if previousID and previousID~=nextID then self.subsystemReports[previousID]=nil end
            end
        end
        local oldNavigator=oldComputers.navigator
        local newNavigator=computers.navigator
        local navigatorLabelChanged=(oldNavigator and oldNavigator.label or nil)~=
            (newNavigator and newNavigator.label or nil)
        if oldBridge~=id("navigator") or navigatorLabelChanged then
            local report=oldBridge and self.subsystemReports[oldBridge] or nil
            if report and report.boot then
                report.retired=report.retired or {}; report.retired[report.boot]=true
                report.boot,report.seq,report.at=nil,nil,nil
                if id("navigator") then self.subsystemReports[id("navigator")]=report end
            elseif id("navigator") then self.subsystemReports[id("navigator")]=nil end
            if oldBridge and oldBridge~=id("navigator") then self.subsystemReports[oldBridge]=nil end
        end
        for _, role in ipairs(Fleet.ROLE_ORDER) do
            -- Role-health reports describe a package receipt bound to both
            -- the assigned address and its registry label.
            local oldEntry=oldComputers[role]
            local oldRoleID=oldEntry and oldEntry.id or nil
            local newRoleID=id(role)
            local newEntry=computers[role]
            if oldRoleID~=newRoleID or (oldEntry and oldEntry.label or nil)~=(newEntry and newEntry.label or nil) then
                self.roleReports[role]=nil
            end
        end
        self.lastHelloAt=nil
    end
    self:logState("identity",self.identityReason)
    if self.fleet and self.fleet.error then self:logState("registry",self.fleet.error)
    else self:logState("registry",nil) end
    if not initial then self:broadcastFleetRegistry() end
    return true
end

-- @ama-summary: Emit a log entry when the named cached state changes.
function IO:logState(key, issue)
    local previous=self.loggedStates[key]
    issue=type(issue)=="string" and issue or nil
    if previous==issue then return end
    self.loggedStates[key]=issue
    if issue then print("Core "..text(key,48)..": "..text(issue,180))
    elseif previous~=nil then print("Core "..text(key,48).." restored") end
end

function IO:routeAllowed()
    if self.identityReady==true then return true end
    return false,self.identityReason or "CORE IDENTITY IS NOT VERIFIED AGAINST /fleet.json"
end

-- @ama-summary: Build a bounded fleet-registry announcement for the current core session.
function IO:registryPacket()
    self.identityRegistrySeq=((self.identityRegistrySeq or 0)%2147483647)+1
    local ok,epochMs=pcall(function()return self.os.epoch("utc")end)
    local uuid=self.vessel and self.vessel.uuid
    return {v=1,kind="fleet_registry",coreID=self.config.computer_id,session=self.session,
        identitySeq=self.identityRegistrySeq,identityEpochMs=ok and epochMs or nil,
        identityVesselUUID=boundedString(uuid,128) and uuid or nil,
        computers=Fleet.clone(self.computers or {})}
end

function IO:observeIdentityClaim(sender,message,protocol,now,epochMs)
    if self.identityWatch then return self.identityWatch:observe(self,sender,message,protocol,now,epochMs) end
end

-- @ama-section: Commands | Correlated bounded requests and acknowledged application.
-- @ama-summary: Send the current fleet registry to one destination.
function IO:sendRegistry(recipient)
    local allowed,identityReason=self:routeAllowed()
    if not allowed then return false,identityReason end
    if not self.rednet or type(self.rednet.send)~="function" then return false,"rednet send unavailable" end
    local packet=self:registryPacket()
    local ok,sent=pcall(self.rednet.send,recipient,packet,self.config.protocol)
    if not ok or sent==false then return false,"fleet registry send failed: "..text(sent) end
    return true
end

-- @ama-section: Core context | Registry, hardware discovery and protocol identity.
-- @ama-summary: Publish the current registry to the configured fleet.
function IO:broadcastFleetRegistry()
    local allowed,identityReason=self:routeAllowed()
    if not allowed then return false,identityReason end
    local packet=self:registryPacket()
    if self.rednet and type(self.rednet.broadcast)=="function" then
        local ok,sent=pcall(self.rednet.broadcast,packet,self.config.protocol)
        if ok and sent~=false then return true end
    end
    if not self.rednet or type(self.rednet.send)~="function" then return false,"rednet send unavailable" end
    local sent,failures=0,{}
    local seen={}
    for _,entry in pairs(self.computers or {}) do
        local id=type(entry)=="table" and entry.id or nil
        if integer(id,0,65535) and id~=self.config.computer_id and not seen[id] then
            seen[id]=true
            local ok,result=pcall(self.rednet.send,id,packet,self.config.protocol)
            if ok and result~=false then sent=sent+1 else failures[#failures+1]="#"..id end
        end
    end
    if sent>0 then return true end
    return false,#failures>0 and table.concat(failures,", ") or "no assigned peer IDs"
end

-- @ama-summary: Validate a registry request and reply with the current core identity and assignments.
function IO:handleRegistryRequest(sender,message,protocol)
    if protocol~=self.config.protocol or type(message)~="table" or message.v~=1 or
        message.kind~="registry_request" or message.coreID~=self.config.computer_id or
        not boundedString(message.session,128) or not message.session:match("^[%w_%.%-:]+$") then return false end
    if sender==self.config.computer_id or not integer(sender,0,65535) then return false end
    if self.identityReady~=true then return false end
    if not self.fleet or self.fleet:roleForID(sender)==nil then return false end
    self:sendRegistry(sender)
    return true
end

function IO:nowSeconds()
    return self.now()
end

-- A wrapped peripheral is a Lua table, not a persistent hardware identity.
-- Keep it across routine discovery; a real detach/reattach advances generation.
function IO:invalidateBridge(reason)
    self.bridge=nil;self.bridgeName=nil
    self.bridgeGeneration=(self.bridgeGeneration or 0)+1
    self.inputs={valid=false,at=self:nowSeconds(),raw={},errors={bridge=reason},reason=reason}
end
-- @ama-summary: Discover configured sensor, monitor and modem interfaces and record their bindings.
function IO:scanHardware()
    -- During state computer failover the core binds the sensors and cockpit
    -- link itself (the pre-split path); otherwise it only finds its wired link.
    if self.stateLink and not self.stateFailoverScan then return self.stateLink:scanCore(self) end
    -- Keep the last completed bindings while discovery yields. A cancelled
    -- scan must not erase the working sensors used by independent readers.
    local p = self.peripheral
    if not p or type(p.getNames) ~= "function" then
        self:invalidateBridge("PERIPHERAL API UNAVAILABLE")
        self.inventory.errors = { "peripheral API is unavailable" }
        return self.inventory
    end
    local ok, names = pcall(p.getNames)
    if not ok or type(names) ~= "table" then
        self:invalidateBridge("PERIPHERAL DISCOVERY FAILED")
        self.inventory.errors = { "could not list peripherals: " .. text(names) }
        return self.inventory
    end
    local ordered = {}
    for _, name in ipairs(names) do if type(name) == "string" then ordered[#ordered + 1] = name end end
    table.sort(ordered)
    local entries, modems, wirelessModems, monitors, bridges = {}, {}, {}, {}, {}
    for _, name in ipairs(ordered) do
        local types, methods = typeList(p, name), {}
        if type(p.getMethods) == "function" then
            local okMethods, found = pcall(p.getMethods, name)
            if okMethods and type(found) == "table" then
                for _, method in ipairs(found) do if type(method) == "string" then methods[#methods + 1] = method end end
                table.sort(methods)
            end
        end
        local isModem = inList(types, "modem") or inList(types, "wireless_modem") or inList(types, "wired_modem")
        local isWireless = false
        if isModem and type(p.wrap) == "function" then
            local okModem, modem = pcall(p.wrap, name)
            if okModem and modem and type(modem.isWireless) == "function" then
                local okWireless, result = pcall(modem.isWireless)
                isWireless = okWireless and result == true
            end
        end
        local entry = {
            name = name, types = types, methods = methods,
            isModem = isModem, isWireless = isWireless,
            isMonitor = inList(types, "monitor") or
                (inList(methods, "getSize") and inList(methods, "setCursorPos") and inList(methods, "write")),
            -- Prior avionics identified link bridges by their verified method pair.
            isBridge = inList(methods, "getLinkSignal") and inList(methods, "sendLinkSignal"),
        }
        entries[#entries + 1] = entry
        if isModem then modems[#modems + 1] = name end
        if isWireless then wirelessModems[#wirelessModems + 1] = name end
        if entry.isMonitor then monitors[#monitors + 1] = name end
        if entry.isBridge then bridges[#bridges + 1] = name end
    end

    local errors, bridgeName = {}, nil
    if self.config.hardware.discover then
        local bindings={velocity_sensors={}}
        for field,kind in pairs({navigation_table="navigation_table",gimbal_sensor="gimbal_sensor",altitude_sensor="altitude_sensor"}) do
            local matches={}
            for _,entry in ipairs(entries) do if inList(entry.types,kind) then matches[#matches+1]=entry.name end end
            if #matches==1 then bindings[field]=matches[1]
            else errors[#errors+1]="discovery requires one "..kind.."; found "..#matches end
        end
        for _,entry in ipairs(entries) do
            if inList(entry.types,"velocity_sensor") then bindings.velocity_sensors[#bindings.velocity_sensors+1]=entry.name end
        end
        if #bindings.velocity_sensors~=3 then errors[#errors+1]="discovery requires three velocity sensors" end
        local addresses={bindings.navigation_table or "?",bindings.gimbal_sensor or "?",bindings.altitude_sensor or "?"}
        for _,name in ipairs(bindings.velocity_sensors) do addresses[#addresses+1]=name end
        for _,name in ipairs(bridges) do addresses[#addresses+1]=name end
        self.sensorBindings=bindings;self.hardwareFingerprint=table.concat(addresses,"|")
    end
    local configuredBridge = self.config.hardware.link_bridge
    if configuredBridge ~= "" then
        for _, name in ipairs(bridges) do if name == configuredBridge then bridgeName = name end end
        if not bridgeName then errors[#errors + 1] = "configured link bridge is missing verified link-signal methods: " .. configuredBridge end
    elseif #bridges == 1 then
        bridgeName = bridges[1]
    elseif #bridges == 0 then
        errors[#errors + 1] = "no peripheral with getLinkSignal() and sendLinkSignal() is attached"
    else
        errors[#errors + 1] = "multiple link bridges; set hardware.link_bridge to one exact name"
    end
    if bridgeName~=self.bridgeName then
        self:invalidateBridge("COCKPIT LINK BRIDGE CHANGED / UNAVAILABLE")
    end
    if bridgeName and not self.bridge and type(p.wrap)=="function" then
        local okWrap,bridge=pcall(p.wrap,bridgeName)
        if okWrap and bridge and type(bridge.getLinkSignal)=="function" then
            self.bridge=bridge;self.bridgeName=bridgeName
        else
            self:invalidateBridge("COCKPIT LINK BRIDGE WRAP FAILED")
            errors[#errors+1]="selected link bridge does not provide getLinkSignal()"
        end
    end

    local configuredMonitor = self.config.hardware.main_monitor or ""
    self.mainMonitor = nil
    if configuredMonitor ~= "" then
        for _, name in ipairs(monitors) do if name == configuredMonitor then self.mainMonitor = name end end
        if not self.mainMonitor then errors[#errors + 1] = "configured main monitor is not attached: " .. configuredMonitor end
    elseif #monitors == 1 then
        self.mainMonitor = monitors[1]
    elseif #monitors > 1 then
        errors[#errors + 1] = "multiple monitors; set hardware.main_monitor to one exact name"
    end
    self.inventory = {
        peripherals = entries, modems = modems, wirelessModems = wirelessModems,
        monitors = monitors, linkBridge = bridgeName, errors = errors,
    }
    if self.config.hardware.discover then self.sensorBindingError=#errors>0 and table.concat(errors,"; ") or nil end
    return self.inventory
end

-- @ama-summary: Open the configured network channels on discovered modems.
function IO:openModems()
    if not self.inventory or #self.inventory.modems == 0 then self:scanHardware() end
    if not self.rednet or type(self.rednet.open) ~= "function" then return false, "rednet API is unavailable" end
    local opened, errors = 0, {}
    for _, name in ipairs(self.inventory.wirelessModems or {}) do
        local isOpen = false
        if type(self.rednet.isOpen) == "function" then
            local ok, value = pcall(self.rednet.isOpen, name)
            isOpen = ok and value == true
        end
        if isOpen then
            opened = opened + 1
        else
            local ok, reason = pcall(self.rednet.open, name)
            if ok then opened = opened + 1 else errors[#errors + 1] = name .. ": " .. text(reason) end
        end
    end
    if opened == 0 then
        local reason = #errors > 0 and table.concat(errors, "; ") or "no modem could be opened"
        if #(self.inventory.wirelessModems or {}) == 0 then
            reason = "no verified wireless modem is attached; wired modems are not used for rednet"
        end
        return false, reason
    end
    self:broadcastFleetRegistry()
    return true, errors
end

function IO:findMainMonitor()
    if not self.inventory then self:scanHardware() end
    if not self.mainMonitor or not self.peripheral or type(self.peripheral.wrap) ~= "function" then return nil end
    local ok, monitor = pcall(self.peripheral.wrap, self.mainMonitor)
    if ok and monitor then return monitor, self.mainMonitor end
end

-- Read all nine exact concrete frequencies. Raw levels are retained as-is;
-- this phase does not translate them into turns, throttle, targets, or modes.
-- @ama-summary: Read each configured cockpit frequency pair and publish a timestamped input batch.
function IO:readInputs(now)
    local progress=self.sampling and self.sampling.cockpit
    if progress then progress.pending={};progress.stage="COCKPIT LINK READS" end
    local started=now or self:nowSeconds()
    local sampledBridge=self.bridge
    local generation=self.bridgeGeneration
    local raw, errors = {}, {}
    if not self.bridge then
        errors.bridge = "redstone link bridge is unavailable"
    else
        local tasks = {}
        for _, key in ipairs(INPUT_ORDER) do
            tasks[#tasks + 1] = function()
                if progress then progress.pending[key]=true end
                local pair = self.config.input_frequencies[key]
                local ok, value = pcall(sampledBridge.getLinkSignal, pair[1], pair[2])
                if progress then progress.pending[key]=nil end
                if not ok then
                    errors[key] = "getLinkSignal failed: " .. text(value)
                elseif not integer(value, 0, 15) then
                    errors[key] = "signal must be an integer from 0 through 15"
                else
                    raw[key] = value
                end
            end
        end
        local complete,parallelIssue=runParallel(self.parallel,tasks)
        if not complete then errors.parallel="parallel input sample failed: "..text(parallelIssue) end
    end
    local reasons = {}
    -- The batch failure is the cause; missing values below are consequences.
    -- Put it first so bounded console summaries do not hide the useful error.
    if errors.parallel then reasons[#reasons+1]=errors.parallel end
    if errors.bridge then reasons[#reasons+1]=errors.bridge end
    for _, key in ipairs(INPUT_ORDER) do
        if raw[key] == nil and not errors[key] then errors[key] = "signal was not sampled" end
        if errors[key] then reasons[#reasons + 1] = key .. ": " .. errors[key] end
    end
    local valid = next(errors) == nil
    if self.bridge~=sampledBridge or self.bridgeGeneration~=generation then valid=false;errors.bridge="link bridge changed during sampling";reasons[#reasons+1]=errors.bridge end
    local completed=self:nowSeconds()
    local candidate = {
        valid = valid, at = completed, startedAt=started,sampleDurationSeconds=math.max(0,completed-started),raw = raw, errors = errors,
        bridgeGeneration=generation,
        reason = not valid and (#reasons>0 and table.concat(reasons, "; ") or errors.bridge) or nil,
    }
    self.lastInputAttempt=candidate
    -- A failed retry is not a new measurement. Retain the previous coherent
    -- batch at its original timestamp; existing stale/neutral gates still apply.
    local sameBridge=self.bridge==sampledBridge and self.bridgeGeneration==generation
    if valid or not sameBridge or not self.inputs or not self.inputs.valid or self.inputs.bridgeGeneration~=generation then
        self.inputs=candidate
    end
    return candidate
end

-- Maintenance shares the command sequence/session boundary. Only core can
-- request these two fixed operations; no arbitrary program or command is sent.
-- @ama-section: Commands | Correlated bounded requests and acknowledged application.
-- @ama-summary: Send a validated chamber maintenance request with current session correlation.
function IO:sendLiftMaintenance(quadrant,operation)
    local allowed,identityReason=self:routeAllowed()
    if not allowed then return false,identityReason end
    if not self.rednet or type(self.rednet.send)~="function" then return false,"REDNET UNAVAILABLE" end
    local n=self.nodes[quadrant]
    if operation~="restart" and operation~="recheck" then return false,"INVALID MAINTENANCE OPERATION" end
    if not n or not self:nodeFresh(quadrant) or type(n.boot)~="string" then return false,"LIFT NODE STALE" end
    local seq=self.commandSeq+1
    if not integer(seq,1,self.config.network.max_sequence) then return false,"COMMAND SEQUENCE LIMIT" end
    self.commandSeq=seq;self.lastIssuedSeq=seq
    local packet={v=1,kind="lift_maintenance",session=self.session,seq=seq,quadrant=quadrant,
        nodeBoot=n.boot,operation=operation,confirmation=operation=="restart" and "RESTART LIFT CONTROLLER" or nil}
    local ok,sent=pcall(self.rednet.send,n.id,packet,self.config.protocol)
    if not ok or sent==false then return false,"MAINTENANCE SEND FAILED" end
    return true,seq
end

-- Sable's official API gives a logical pose, linear and angular velocity, and
-- mass. Coordinate signs and velocity units remain raw until verified in-game.
local function normalize(value)
    if not value then return nil end
    local length = math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
    if not finite(length) or length < 1e-8 then return nil end
    return { x = value.x / length, y = value.y / length, z = value.z / length }
end

-- @ama-section: Observations | Independent sensor completion and vessel geometry.
-- @ama-summary: Validate and normalize a quaternion-shaped observation.
local function asQuaternion(value)
    local v, a = field(value, "v"), field(value, "a")
    local x, y, z, w
    if v ~= nil and a ~= nil then
        x, y, z, w = field(v, "x", 1), field(v, "y", 2), field(v, "z", 3), a
    else
        x, y, z, w = field(value, "x", 1), field(value, "y", 2), field(value, "z", 3), field(value, "w", 4)
    end
    if not finite(x) or not finite(y) or not finite(z) or not finite(w) then return nil end
    local length = math.sqrt(x * x + y * y + z * z + w * w)
    if not finite(length) or length < 1e-8 then return nil end
    return { x = x / length, y = y / length, z = z / length, w = w / length }
end

-- @ama-section: Core context | Registry, hardware discovery and protocol identity.
-- @ama-summary: Rotate a vector using the supplied quaternion.
local function rotate(q, v)
    local p = { x = v.x, y = v.y, z = v.z, w = 0 }
    local c = { x = -q.x, y = -q.y, z = -q.z, w = q.w }
    -- @ama-summary: Multiply quaternion components in the required composition order.
    local function mul(a, b)
        return {
            x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        }
    end
    local r = mul(mul(q, p), c)
    return { x = r.x, y = r.y, z = r.z }
end

-- @ama-summary: Convert the horizontal forward vector into a normalized compass heading.
local function headingFromForward(forward)
    if forward.x * forward.x + forward.z * forward.z < 1e-4 then return nil end
    local y, x = forward.x, -forward.z
    local angle
    if math.atan2 then
        angle = math.atan2(y, x)
    elseif x > 0 then
        angle = math.atan(y / x)
    elseif x < 0 then
        angle = math.atan(y / x) + (y >= 0 and math.pi or -math.pi)
    elseif y > 0 then
        angle = math.pi / 2
    else
        angle = -math.pi / 2
    end
    return (math.deg(angle) + 360) % 360
end

-- Attitude axis from physical evidence. The four chamber altitude sensors
-- show which way the hull really tilts (front vs rear = pitch, left vs right
-- = roll). The pose-frame horizontal axis whose pitch/roll agree with them is
-- learned, saved to /avionics/data/attitude-axis.json and used from then on.
local ATTITUDE_AXES={{x=1,y=0,z=0},{x=-1,y=0,z=0},{x=0,y=0,z=1},{x=0,y=0,z=-1}}
local ATTITUDE_AXIS_PATH="/avionics/data/attitude-axis.json"
local function axisKey(axis) return tostring(axis.x)..","..tostring(axis.z) end
-- @ama-section: Observations | Independent sensor completion and vessel geometry.
-- @ama-summary: Load the configured or retained vessel attitude-axis calibration.
function IO:loadAttitudeAxis()
    self.attitudeAxisLoaded=true
    if not self.fs or type(self.fs.open)~="function" or not self.json then return end
    local okExists,exists=pcall(self.fs.exists,ATTITUDE_AXIS_PATH)
    if not okExists or not exists then return end
    local ok,handle=pcall(self.fs.open,ATTITUDE_AXIS_PATH,"r")
    if not ok or not handle then return end
    local readOK,raw=pcall(handle.readAll);pcall(handle.close)
    if not readOK or type(raw)~="string" or #raw>1024 then return end
    local decodeOK,value=pcall(self.json.unserializeJSON,raw)
    if decodeOK and type(value)=="table" and value.schemaVersion==1 and type(value.bowKey)=="string" and
        type(value.axis)=="table" then
        for _,axis in ipairs(ATTITUDE_AXES) do
            if value.axis.x==axis.x and value.axis.z==axis.z then
                self.attitudeAxisLearned={axis=axis,bowKey=value.bowKey}
            end
        end
    end
end
-- @ama-summary: Infer the vessel's body-axis orientation from chamber altitude observations.
function IO:chamberAttitudeAxis(pose,bowKey)
    if not self.attitudeAxisLoaded then self:loadAttitudeAxis() end
    local learned=self.attitudeAxisLearned
    if learned and learned.bowKey~=bowKey then learned=nil end
    local function result() return learned and learned.axis or nil,learned and "CHAMBER HEIGHTS" or nil end
    if not pose or type(self.nodes)~="table" then return result() end
    local now=self:nowSeconds()
    local y={}
    for _,q in ipairs({"FL","FR","RL","RR"}) do
        local node=self.nodes[q]
        local value=node and node.altitude and node.altitude.sensorWorldY
        if not self:nodeFresh(q,now) or not finite(value) then return result() end
        y[q]=value
    end
    local pitchBlocks=(y.FL+y.FR-y.RL-y.RR)/4
    local rollBlocks=(y.FL+y.RL-y.FR-y.RR)/4
    if math.abs(pitchBlocks)+math.abs(rollBlocks)<0.3 then return result() end
    local evidence=self.attitudeEvidence or {}
    self.attitudeEvidence=evidence
    for _,axis in ipairs(ATTITUDE_AXES) do
        local forward=normalize(rotate(pose,axis))
        local starboard=normalize(rotate(pose,{x=-axis.z,y=0,z=axis.x}))
        if forward and starboard then
            local p=math.deg(math.asin(math.max(-1,math.min(1,forward.y))))
            local r=math.deg(math.asin(math.max(-1,math.min(1,-starboard.y))))
            local key=axisKey(axis)
            evidence[key]=(evidence[key] or 0)*0.98+p*pitchBlocks+r*rollBlocks
        end
    end
    local bestAxis,best,second
    for _,axis in ipairs(ATTITUDE_AXES) do
        local score=evidence[axisKey(axis)] or 0
        if not best or score>best then second=best;best,bestAxis=score,axis
        elseif not second or score>second then second=score end
    end
    if bestAxis and best>20 and best>2*math.max(second or 0,0) and
        (not learned or axisKey(learned.axis)~=axisKey(bestAxis)) then
        learned={axis=bestAxis,bowKey=bowKey}
        self.attitudeAxisLearned=learned
        print("Core attitude axis learned from chamber heights: pose "..axisKey(bestAxis).." (x,z) is the bow")
        if self.fs and type(self.fs.open)=="function" and self.json and type(self.json.serializeJSON)=="function" then
            pcall(self.fs.makeDir,"/avionics/data")
            local ok,handle=pcall(self.fs.open,ATTITUDE_AXIS_PATH,"w")
            if ok and handle then
                pcall(handle.write,self.json.serializeJSON({schemaVersion=1,bowKey=bowKey,
                    axis={x=bestAxis.x,z=bestAxis.z}}))
                pcall(handle.close)
            end
        end
    end
    return result()
end

-- Each configured sensor is checked by exact name and method at read time.
-- Never infer a missing sensor's value from zero or auto-claim another device.
function IO:readSensor(name, method)
    if type(name) ~= "string" or name == "" then return nil, "sensor not configured" end
    if not hasMethod(self.peripheral, name, method) then return nil, name .. "." .. method .. " unavailable" end
    local ok, wrapped = pcall(self.peripheral.wrap, name)
    if not ok then return nil, text(wrapped) end
    return safeCall(wrapped, method)
end

-- @ama-summary: Read Sable vessel fields and configured sensors with per-observation timestamps.
function IO:sampleVessel(now)
    if self.config.hardware.discover and not self.sensorBindings then self:scanHardware() end
    local progress=self.sampling and self.sampling.vessel
    if progress then progress.pending={};progress.stage="SABLE GRID CHECK" end
    local function tracked(name,fn,...)
        if progress then progress.pending[name]=true end
        local value,reason=fn(...)
        if progress then progress.pending[name]=nil end
        return value,reason
    end
    local hardware, geometry = self.sensorBindings or self.config.hardware, self.config.geometry
    local errors, values = {}, {}
    local valuesAt={}
    local api = self.sublevel
    local inGrid, gridError = tracked("sublevel.isInPlotGrid",safeCall,api,"isInPlotGrid")
    local reads={}
    if inGrid == true then
        for _, item in ipairs({{"uuid","getUniqueId"},{"pose","getLogicalPose"},
            {"com","getCenterOfMass"},{"velocity","getLinearVelocity"},
            {"angular","getAngularVelocity"},{"mass","getMass"}}) do
            local key,method=item[1],item[2]
            reads[#reads+1]=function()
                local value, reason = tracked("sublevel."..method,safeCall,api,method)
                values[key] = value
                if value~=nil then
                    valuesAt[key]=self:nowSeconds()
                    if self.independentVesselSources then VesselSources.acceptPrimary(self,key,value,valuesAt[key]) end
                end
                if reason then errors[#errors+1] = reason end
            end
        end
    else
        errors[#errors+1] = gridError or "computer is not on a Sable sublevel"
    end
    local function sensor(name, method)
        local value, reason = tracked(tostring(name).."."..method,self.readSensor,self,name,method)
        if name and reason then errors[#errors+1] = reason end
        return value
    end
    -- Independent getters share one read window instead of accumulating a
    -- server-tick wait for every sensor before the snapshot can be published.
    -- Peripheral getters share CC's per-computer, per-tick main-thread
    -- budget with the cockpit and assembly readers. Read only what control
    -- needs every sample; diagnostics and the altitude sensor (fallbacks:
    -- heading, attitude, altitude and vertical speed come from Sable) refresh
    -- every 5 s, and a velocity sensor's fixed axis is read once.
    local sampled={}
    local slow=self.vesselSlowReads or {}
    self.vesselSlowReads=slow
    local slowNow=self:nowSeconds()
    local refreshSlow=not finite(slow.at) or slowNow<slow.at or slowNow-slow.at>=5
    if refreshSlow then slow.at=slowNow;slow.values=slow.values or {} end
    local bodyReadings={}
    if self.independentVesselSources then
        sampled,bodyReadings=VesselSources.legacyInputs(self,self:nowSeconds())
    else
    for _,read in ipairs({
        {"orientation",hardware.navigation_table,"getOrientation",false},
        {"heading",hardware.navigation_table,"getHeading",true},
        {"height",hardware.altitude_sensor,"getHeight",true},
        {"verticalSpeed",hardware.altitude_sensor,"getVerticalSpeed",true},
        {"gravity",hardware.gimbal_sensor,"getGravity",true},
        {"angles",hardware.gimbal_sensor,"getAngles",true},
        {"rates",hardware.gimbal_sensor,"getAngularRates",true},
    }) do
        local key,name,method,isSlow=read[1],read[2],read[3],read[4]
        if isSlow and not refreshSlow and slow.values and slow.values[key]~=nil then
            sampled[key]=slow.values[key]
        else
            reads[#reads+1]=function()
                sampled[key]=sensor(name,method)
                if isSlow and slow.values then slow.values[key]=sampled[key] end
            end
        end
    end
    local axisCache=self.velocityAxisCache or {}
    self.velocityAxisCache=axisCache
    for _,name in ipairs(hardware.velocity_sensors or {}) do
        local target={};bodyReadings[#bodyReadings+1]=target
        local peripheralName=name
        local cachedAxis=axisCache[peripheralName]
        if cachedAxis=="x" or cachedAxis=="y" or cachedAxis=="z" then
            target.axis=cachedAxis
        else
            reads[#reads+1]=function()
                target.axis=sensor(peripheralName,"getAxis")
                if target.axis=="x" or target.axis=="y" or target.axis=="z" then axisCache[peripheralName]=target.axis end
            end
        end
        reads[#reads+1]=function() target.speed=sensor(peripheralName,"getVelocity") end
        target.name=peripheralName
    end
    end
    if progress then progress.stage="CONCURRENT SENSOR READS" end
    -- One peripheral call that never answers must not blank every vessel
    -- value. Give the batch its own deadline; values that arrived are used
    -- and the calls still pending are reported as errors.
    local complete,readIssue
    local batchDone=false
    local deadline=os.clock()+4
    if self.parallel and type(self.parallel.waitForAny)=="function" then
        self.parallel.waitForAny(function()
            complete,readIssue=runParallel(self.parallel,reads);batchDone=true
        end,function()
            local timer=os.startTimer(4)
            while os.clock()<deadline do os.pullEventRaw() end
            pcall(os.cancelTimer,timer)
        end)
    else complete,readIssue=runParallel(self.parallel,reads);batchDone=true end
    if not batchDone then
        complete=true
        local pending={}
        for key in pairs(progress and progress.pending or {}) do pending[#pending+1]=key end
        table.sort(pending)
        errors[#errors+1]="vessel reads still pending after 4 s: "..(#pending>0 and table.concat(pending,", ") or "unknown")
        if progress then progress.pending={} end
    end
    if not complete then errors[#errors+1]="vessel read batch failed: "..text(readIssue) end
    local navOrientation=asQuaternion(sampled.orientation)
    local navHeading,height,sensorVS=sampled.heading,sampled.height,sampled.verticalSpeed
    local gravity,angles,rates=vector(sampled.gravity),sampled.angles,vector(sampled.rates)
    local pose = values.pose
    local position, rotationPoint, scale, poseOrientation
    if type(pose) == "table" then
        position, rotationPoint, scale = vector(pose.position), vector(pose.rotationPoint), vector(pose.scale)
        poseOrientation = asQuaternion(pose.orientation)
    end
    local com = vector(values.com)
    local worldCom
    -- Sable Pose3dc.transformPosition: world = position + Q * ((local - rotationPoint) * scale).
    -- getCenterOfMass is a local/plot-space point, not already a world coordinate.
    if com and position and rotationPoint and scale and poseOrientation then
        local offset = rotate(poseOrientation, {x=(com.x-rotationPoint.x)*scale.x,
            y=(com.y-rotationPoint.y)*scale.y,z=(com.z-rotationPoint.z)*scale.z})
        local candidate={x=position.x+offset.x,y=position.y+offset.y,z=position.z+offset.z}
        worldCom=vector(candidate)
    end
    local orientation = navOrientation or poseOrientation
    local bow = geometry.orientation_verified and normalize(geometry.bow_forward) or nil
    local forward, heading, pitch, roll
    if orientation and bow then
        forward=normalize(rotate(orientation,bow))
        if forward then
            heading=headingFromForward(forward)
            pitch=math.deg(math.asin(math.max(-1,math.min(1,forward.y))))
            local down=rotate({x=-orientation.x,y=-orientation.y,z=-orientation.z,w=orientation.w},{x=0,y=-1,z=0})
            local starboard={x=-bow.z,y=0,z=bow.x}
            roll=math.deg(math.asin(math.max(-1,math.min(1,down.x*starboard.x+down.z*starboard.z))))
        end
    end
    -- Attitude uses the vessel transform, independent of the gimbal's mounted
    -- frame. Raw gimbal readings stay in diagnostics; they must not overwrite
    -- vessel pitch/roll or exchange their axes. Prefer Sable's actual pose.
    local attitudeOrientation=poseOrientation or orientation
    local attitudeBow=bow
    -- The frame offset is a fixed property of the build, so it is resolved
    -- once per vessel and then latched; later samples never re-pick an axis.
    local latch=self.attitudeAxisLatch
    local bowKey=bow and (bow.x..","..bow.y..","..bow.z) or nil
    if latch and (latch.uuid~=values.uuid or latch.bowKey~=bowKey) then latch=nil;self.attitudeAxisLatch=nil end
    if latch then attitudeBow=latch.axis
    elseif poseOrientation and navOrientation and forward and bow and boundedString(values.uuid,128) then
        -- The navigation table and the Sable pose can report frames rotated
        -- about the vertical, so the configured bow (valid for the heading
        -- source) can point sideways in the pose frame and swap pitch with
        -- roll. Use the pose-frame horizontal axis that points where the
        -- verified heading forward points. Works for any build orientation.
        local best,bestDot
        for _,axis in ipairs({{x=1,y=0,z=0},{x=-1,y=0,z=0},{x=0,y=0,z=1},{x=0,y=0,z=-1}}) do
            local candidate=rotate(poseOrientation,axis)
            local scale=candidate and math.sqrt(candidate.x^2+candidate.z^2)*math.sqrt(forward.x^2+forward.z^2) or 0
            if scale>1e-6 then
                local dot=(candidate.x*forward.x+candidate.z*forward.z)/scale
                if not bestDot or dot>bestDot then best,bestDot=axis,dot end
            end
        end
        if best and bestDot>0.7 then
            attitudeBow=best
            self.attitudeAxisLatch={uuid=values.uuid,bowKey=bowKey,axis=best}
        end
    end
    local attitudeAxisSource=attitudeBow~=bow and "HEADING MATCH" or "CONFIGURED BOW"
    if poseOrientation then
        local chamberAxis,chamberSource=self:chamberAttitudeAxis(poseOrientation,bowKey)
        if chamberAxis then attitudeBow,attitudeAxisSource=chamberAxis,chamberSource end
    end
    -- Heading and the bow direction used by anchor and autopilot thrust
    -- mapping. The navigation table's frame was found rotated 90 degrees about
    -- vertical from the ship (facing east read ~357). Once the bow axis has
    -- been learned from chamber heights (signed: FL/FR are fore), take the
    -- bow from Sable's pose with that axis, the same frame pitch/roll use.
    local headingSourceText
    if poseOrientation and attitudeAxisSource=="CHAMBER HEIGHTS" and attitudeBow then
        local poseForward=normalize(rotate(poseOrientation,attitudeBow))
        local poseHeading=poseForward and headingFromForward(poseForward)
        if poseHeading then
            forward,heading=poseForward,poseHeading
            headingSourceText="Sable pose / chamber-height bow"
        end
    end
    if attitudeOrientation and attitudeBow then
        local attitudeForward=normalize(rotate(attitudeOrientation,attitudeBow))
        local attitudeStarboard=normalize(rotate(attitudeOrientation,{x=-attitudeBow.z,y=0,z=attitudeBow.x}))
        if attitudeForward and attitudeStarboard then
            pitch=math.deg(math.asin(math.max(-1,math.min(1,attitudeForward.y))))
            roll=math.deg(math.asin(math.max(-1,math.min(1,-attitudeStarboard.y))))
        end
    end
    local body, duplicate = {}, {}
    for _, reading in ipairs(bodyReadings) do
        local name,axis,speed=reading.name,reading.axis,reading.speed
        if axis=="x" or axis=="y" or axis=="z" then
            if body[axis]~=nil then duplicate[axis]=true end
            if finite(speed) then body[axis]=speed end
        else errors[#errors+1]=name..": invalid velocity axis" end
    end
    for axis in pairs(duplicate) do body[axis]=nil; errors[#errors+1]="duplicate velocity axis "..axis end
    local velocity = vector(values.velocity)
    local velocityVerified = geometry.velocity_frame_verified == true and geometry.velocity_unit == "blocks_per_second"
    local forwardSpeed, verticalSpeed
    -- Velocity sensor axes belong to their own frame, not the navigation table.
    local velocityBow=geometry.velocity_forward and normalize(geometry.velocity_forward) or bow
    if velocityBow then
        local sum, complete=0,true
        for _,axis in ipairs({"x","y","z"}) do
            if math.abs(velocityBow[axis])>1e-8 then
                if not finite(body[axis]) then complete=false else sum=sum+body[axis]*velocityBow[axis] end
            end
        end
        if complete then forwardSpeed=sum end
    end
    local fullBody=vector(body)
    if fullBody and orientation then verticalSpeed=rotate(orientation,fullBody).y end
    if velocityVerified and velocity then
        verticalSpeed=verticalSpeed or velocity.y
        if not forwardSpeed and forward then forwardSpeed=velocity.x*forward.x+velocity.y*forward.y+velocity.z*forward.z end
    end
    -- Speed along the hull's bow axis tilts with the ship: while pitched, part
    -- of any climb or descent reads as forward/backward motion and the
    -- propulsion speed hold "corrects" it. Report horizontal forward speed:
    -- along_bow = horizontal*cos(pitch) + vertical*sin(pitch).
    local forwardSpeedSensor=forwardSpeed
    local horizontalForwardSpeed=false
    if headingSourceText and velocityVerified and velocity and forward then
        -- The body velocity sensors measure along their own +X, which shares
        -- the navigation table's rotated frame (it read sideways speed). With
        -- the pose/chamber bow available, use Sable's world velocity along
        -- the horizontal bow: same frame as heading, and free of climb rate.
        local h=math.sqrt(forward.x*forward.x+forward.z*forward.z)
        if h>0.1 then
            forwardSpeed=(velocity.x*forward.x+velocity.z*forward.z)/h
            horizontalForwardSpeed=true
        end
    end
    local forwardSpeedAlongBow=forwardSpeed
    if horizontalForwardSpeed then
        forwardSpeedAlongBow=velocity.x*forward.x+velocity.y*forward.y+velocity.z*forward.z
    end
    local climbRate=finite(verticalSpeed) and verticalSpeed or (finite(sensorVS) and sensorVS or nil)
    if not horizontalForwardSpeed and finite(forwardSpeed) and finite(climbRate) and finite(pitch) and math.abs(pitch)<60 then
        local pitchRad=math.rad(pitch)
        forwardSpeed=(forwardSpeed-climbRate*math.sin(pitchRad))/math.cos(pitchRad)
    end
    local sampledAt=self:nowSeconds()
    -- Tests inject a constant clock; the supplied timestamp is the lower bound.
    sampledAt=math.max(now or sampledAt,sampledAt)
    if worldCom and finite(height) and boundedString(values.uuid,128) then
        self.altitudeOffset={value=worldCom.y-height,at=sampledAt,uuid=values.uuid}
    elseif self.altitudeOffset and values.uuid~=self.altitudeOffset.uuid then
        self.altitudeOffset=nil
    end
    local altitude=worldCom and worldCom.y or nil
    local altitudeSource=altitude and "Sable world CoM" or nil
    -- A recent offset permits a labelled, short-lived estimate, not indefinite
    -- use of stale geometry. Requires the same positively identified vessel.
    local offset=self.altitudeOffset
    if not altitude and finite(height) and offset and values.uuid==offset.uuid and
        sampledAt>=offset.at and sampledAt-offset.at<=self.config.network.sensor_stale_seconds then
        altitude=height+offset.value; altitudeSource="ALT SENSOR / ESTIMATED CoM"
    end
    local environment={valid=false,reason="CC:Sable aero API unavailable"}
    if progress then progress.stage="ENVIRONMENT READS" end
    if type(self.aero)=="table" then
        local gravityWorld,drag,pressure,pressureError
        -- Gravity and universal drag are effectively constant and pressure
        -- depends only on height, so most samples reuse cached values and
        -- skip this second round of peripheral waits entirely. Remaining
        -- getters still run together.
        local envNow=self:nowSeconds()
        local envCache=self.environmentCache
        local envFresh=type(envCache)=="table" and finite(envCache.at) and envNow>=envCache.at and envNow-envCache.at<30
        if envFresh then gravityWorld,drag=envCache.gravity,envCache.drag end
        local pressureKey=worldCom and math.floor(worldCom.y*2+0.5) or nil
        local pressureCache=self.pressureCache
        if type(pressureCache)~="table" then pressureCache={};self.pressureCache=pressureCache end
        local hit=pressureKey and pressureCache[pressureKey]
        if hit and envNow-hit.at<30 and math.abs(hit.x-worldCom.x)<64 and math.abs(hit.z-worldCom.z)<64 then
            pressure=hit.value
        end
        local jobs={}
        if not envFresh then
            jobs[#jobs+1]=function() gravityWorld=tracked("aero.getGravity",safeCall,self.aero,"getGravity") end
            jobs[#jobs+1]=function() drag=tracked("aero.getUniversalDrag",safeCall,self.aero,"getUniversalDrag") end
        end
        if not finite(pressure) then
            jobs[#jobs+1]=function()
                -- Pressure requires a genuine ComputerCraft vector.
                if not worldCom then pressureError="World CoM position unavailable for pressure query"
                elseif type(self.vectorApi)~="table" or type(self.vectorApi.new)~="function" then
                    pressureError="ComputerCraft vector.new() unavailable for pressure query"
                else
                    local made,point=pcall(self.vectorApi.new,worldCom.x,worldCom.y,worldCom.z)
                    if made then pressure,pressureError=tracked("aero.getAirPressure",safeCall,self.aero,"getAirPressure",point)
                    else pressureError="Pressure query vector failed: "..text(point) end
                    if finite(pressure) and pressure>0 and pressureKey then
                        -- Keep the cache small: expire after 30 s and cap at 16
                        -- entries (it is also sent in every state frame).
                        local count=0
                        for k,item in pairs(pressureCache) do
                            if envNow-item.at>=30 then pressureCache[k]=nil else count=count+1 end
                        end
                        if count>=16 then pressureCache={};self.pressureCache=pressureCache end
                        pressureCache[pressureKey]={at=envNow,x=worldCom.x,z=worldCom.z,value=pressure}
                    end
                end
            end
        end
        if #jobs>0 then runParallel(self.parallel,jobs) end
        if not envFresh and vector(gravityWorld)~=nil and finite(drag) then
            self.environmentCache={at=envNow,gravity=gravityWorld,drag=drag}
        end
        if pressureError then errors[#errors+1]=pressureError end
        environment={gravity=vector(gravityWorld),universalDrag=finite(drag) and drag or nil,
            airPressure=finite(pressure) and pressure or nil,
            airPressureError=pressureError,
            valid=vector(gravityWorld)~=nil or finite(drag) or finite(pressure)}
    end
    local valid=finite(altitude) or heading~=nil or worldCom~=nil
    self.vessel={valid=valid,at=sampledAt,reason=not finite(altitude) and "SABLE CoM ALTITUDE UNAVAILABLE" or nil,
        sableReadAt=valuesAt,sableUuid=boundedString(values.uuid,128) and values.uuid or nil,
        sableOrientation=poseOrientation,sablePosePosition=position,sableRotationPoint=rotationPoint,sableScale=scale,
        sableWorldCom=worldCom,sableVelocity=vector(values.velocity),
        sableAngular=vector(values.angular),sableMass=finite(values.mass) and values.mass>0 and values.mass or nil,
        telemetryErrors=errors,uuid=boundedString(values.uuid,128) and values.uuid or nil,
        position=worldCom,posePosition=position,localCenterOfMass=com,
        altitude=altitude,altitudeSource=altitudeSource,altitudeUnit="world Y",
        heading=heading,headingSource=heading and headingSourceText or heading and (navOrientation and "navigation_table orientation / configured bow" or "Sable orientation / configured bow") or nil,
        pitch=pitch,roll=roll,attitudeBow=attitudeBow,attitudeAxisSource=attitudeAxisSource,orientation=orientation,forwardDirection=forward,
        linearVelocity=velocity,angularVelocity=vector(values.angular),
        mass=finite(values.mass) and values.mass>0 and values.mass or nil,
        forwardSpeed=finite(forwardSpeed) and forwardSpeed or nil,verticalSpeed=finite(verticalSpeed) and verticalSpeed or nil,
        forwardSpeedAlongBow=finite(forwardSpeedAlongBow) and forwardSpeedAlongBow or nil,
        forwardSpeedSensor=finite(forwardSpeedSensor) and forwardSpeedSensor or nil,
        forwardSpeedSource=horizontalForwardSpeed and "Sable velocity / pose bow" or "body velocity sensors",
        velocityForward=velocityBow,
        geometryVerified=heading~=nil,velocityFrameVerified=velocityVerified,
        sensors={altitude={worldY=finite(height) and height or nil,verticalSpeed=finite(sensorVS) and sensorVS or nil},
            navigation={rawHeading=finite(navHeading) and navHeading or nil},
            gimbal={angles=type(angles)=="table" and {angles[1],angles[2]} or nil,gravity=gravity,angularRates=rates},bodyVelocity=body},
        environment=environment}
    if progress then progress.stage="COMPLETE" end
    return self.vessel
end

-- Sable and peripheral workers have separate deadlines and share only
-- completed read-only records. A blocked primary never owns backup publication.
local samplePrimaryVessel=IO.sampleVessel
-- @ama-summary: Read Sable vessel fields and configured sensors with per-observation timestamps.
function IO:sampleVessel(now)
    local primary=samplePrimaryVessel(self,now)
    if self.independentVesselSources then
        self.primaryVessel=primary
        VesselSources.compose(self,self:nowSeconds())
    end
    return primary
end
function IO:sampleFallback(now) return VesselSources.sample(self,now or self:nowSeconds()) end
function IO:refreshVesselSources(now)
    if self.independentVesselSources then return VesselSources.compose(self,now or self:nowSeconds()) end
    return self.vessel
end

-- @ama-summary: Resolve the available pressure observation for the requested world altitude.
function IO:airPressureAtWorldY(worldY)
    if self.stateLink then
        if not finite(worldY) then return nil,"STATE PRESSURE TARGET INVALID" end
        local key=math.floor(worldY*2+.5)
        local item=(self.statePressureCache or {})[key]
        local p=self.vessel and self.vessel.position
        local now=self:nowSeconds()
        if item and p and finite(p.x) and finite(p.z) and finite(item.at) and now>=item.at and now-item.at<30 and
            math.abs(item.x-p.x)<64 and math.abs(item.z-p.z)<64 then return item.value end
        self.statePressureRequest=worldY
        return nil,"WAITING FOR STATE READER PRESSURE"
    end
    local vessel=self.vessel
    if vessel and vessel.positionUnavailable then return nil,"TARGET PRESSURE UNAVAILABLE DURING SENSOR FALLBACK" end
    local position=vessel and vessel.position
    if not finite(worldY) or type(position)~="table" or
        not finite(position.x) or not finite(position.z) then
        return nil,"WORLD POSITION UNAVAILABLE FOR PRESSURE QUERY"
    end
    if type(self.vectorApi)~="table" or type(self.vectorApi.new)~="function" then
        return nil,"COMPUTERCRAFT VECTOR API UNAVAILABLE"
    end
    -- Each query is a server-tick peripheral wait on the runtime loop, where
    -- it also delays message handling. Pressure depends on height, and the
    -- queried height (the target) rarely changes, so cache per half block.
    local key=math.floor(worldY*2+0.5)
    local now=self:nowSeconds()
    local cache=self.pressureCache
    if type(cache)~="table" then cache={};self.pressureCache=cache end
    local hit=cache[key]
    if hit and now-hit.at<30 and math.abs(hit.x-position.x)<64 and math.abs(hit.z-position.z)<64 then
        return hit.value
    end
    local made,point=pcall(self.vectorApi.new,position.x,key/2,position.z)
    if not made then return nil,"PRESSURE QUERY VECTOR FAILED: "..text(point) end
    local pressure,reason=safeCall(self.aero,"getAirPressure",point)
    if not finite(pressure) or pressure<=0 then
        return nil,reason or "PRESSURE QUERY RETURNED NO POSITIVE VALUE"
    end
    local count=0
    for k,item in pairs(cache) do
        if now-item.at>=30 then cache[k]=nil else count=count+1 end
    end
    if count>=16 then cache={};self.pressureCache=cache end
    cache[key]={at=now,x=position.x,z=position.z,value=pressure}
    return pressure
end

-- @ama-section: Core context | Registry, hardware discovery and protocol identity.
-- @ama-summary: Validate and bound a received provider-readback map.
local function sanitizeProviders(value, limit)
    if type(value) ~= "table" then return nil, "providers must be an object keyed by peripheral name" end
    local result, count = {}, 0
    for name, item in pairs(value) do
        count = count + 1
        if count > limit then return nil, "provider count exceeds configured limit" end
        if not boundedString(name, 128) or type(item) ~= "table" or item.name ~= name then
            return nil, "provider entry name does not match its object key"
        end
        local minimum, maximum = item.minTarget, item.maxTarget
        if item.minimumNonzeroTarget ~= nil and
            (not finite(maximum) or not integer(item.minimumNonzeroTarget, 1, maximum)) then
            return nil, "provider minimumNonzeroTarget must be within maxTarget"
        end
        if not integer(minimum, 0, math.huge) or not integer(maximum, 0, math.huge) or maximum < minimum then
            return nil, "provider minTarget/maxTarget must be ordered non-negative integers"
        end
        if item.step ~= nil and item.step ~= 1 then return nil, "provider step must equal 1" end
        local activeValid = item.activeValid == true and type(item.active) == "boolean"
        local clean = {
            name = name, minTarget = minimum, maxTarget = maximum, step = 1,
            minimumNonzeroTarget = item.minimumNonzeroTarget,
            controlRole = (item.controlRole == "bulk" or item.controlRole == "fine") and item.controlRole or nil,
            present = item.present == true, writable = item.writable == true,
            presenceValid = item.presenceValid==true or (item.presenceValid==nil and item.present==true),
            presenceState = item.presenceValid==true and (item.present==true and "PRESENT" or "MISSING_OR_WRONG_TYPE") or
                (item.presenceValid==nil and item.present==true and "PRESENT" or "UNVERIFIED"),
            writableValid = item.writableValid==true or (item.writableValid==nil and item.writable==true),
            activeSupported = item.activeSupported == true,
            activeValid = activeValid,
            targetAmount = finite(item.targetAmount) and item.targetAmount or nil,
            targetValid = item.targetValid == true,
            signalStrength = integer(item.signalStrength, 0, 15) and item.signalStrength or nil,
            signalValid = item.signalValid == true,
            gasOutput = finite(item.gasOutput) and item.gasOutput or nil,
            gasOutputValid = item.gasOutputValid == true,
            gasTypeValid = item.gasTypeValid == true and boundedString(item.gasType, 96),
            gasType = item.gasTypeValid == true and boundedString(item.gasType, 96) and text(item.gasType, 96) or nil,
            boilerEfficiencyValid = item.boilerEfficiencyValid == true and finite(item.boilerEfficiency),
            boilerEfficiency = item.boilerEfficiencyValid == true and finite(item.boilerEfficiency) and item.boilerEfficiency or nil,
            attached = item.attached == true, attachedValid = item.attachedValid == true,
            error = type(item.error) == "string" and text(item.error, 100) or nil,
        }
        if activeValid then clean.active = item.active end
        result[name] = clean
    end
    return result
end

-- @ama-summary: Validate and bound a received chamber envelope observation.
local function sanitizeBalloon(value)
    if value == nil then return nil end
    if type(value) ~= "table" then return nil end
    local result = {}
    if type(value.source) == "string" then result.source = text(value.source, 96) end
    if type(value.hasBalloon) == "boolean" then result.hasBalloon = value.hasBalloon end
    result.hasBalloonValid = value.hasBalloonValid == true
    result.gasMixValid = false
    if value.gasMixValid == true and type(value.gasMix) == "table" and result.hasBalloon == true then
        local mix, total, count, valid = {}, 0, 0, true
        for gas, amount in pairs(value.gasMix) do
            count=count+1
            if count>16 or not boundedString(gas,96) or not finite(amount) or amount<0 then valid=false; break end
            mix[gas]=amount; total=total+amount
        end
        if valid and count>0 and finite(total) and total>0 then
            result.gasMixValid=true; result.gasMix=mix; result.gasMixAmount=total
            result.gasFractions={}
            for gas,amount in pairs(mix) do result.gasFractions[gas]=amount/total end
        end
    end
    for _, name in ipairs({ "lift", "filledVolume", "targetVolume", "capacity", "height", "volumeChange" }) do
        if finite(value[name]) then result[name] = value[name] end
        result[name .. "Valid"] = value[name .. "Valid"] == true
    end
    if type(value.error) == "string" then result.error = text(value.error, 100) end
    return result
end

function IO:nodeFresh(quadrant, now)
    local node = self.nodes[quadrant]
    now = now or self:nowSeconds()
    return node ~= nil and node.lastSeen ~= nil and finite(now) and
        now >= node.lastSeen and now - node.lastSeen <= self.config.network.node_stale_seconds
end

-- ===================== ASSEMBLY GATE =====================
-- The whole gate is Create Avionics physics_assembler.isAssembled():
--   fresh Sable UUID       association verified, gate open
--   Sable unavailable       consult the fresh assembler result
--   assembler false         disassembled when Sable association is unavailable
--   unresolved observations gate open, warn after five minutes
-- It is read by its own small worker in main.lua (every 0.25 s), separate
-- from the slower vessel sample. hardware.physics_assembler may name one
-- assembler; otherwise every attached physics_assembler is read and all of
-- them must report true.
-- @ama-summary: ===================== ASSEMBLY GATE ===================== The whole gate is Create Avionics physics_assembler.isAssembled(): fresh Sable UUID       association verified, gate open Sable unavailable       consult the fresh assembler result assembler false         disassembled when Sable association is unavailable unresolved observations gate open, warn after five minutes It is read by its own small worker in main.lua (every 0.25 s), separate from the slower vessel sample. hardware.physics_assembler may name one assembler; otherwise every attached physics_assembler is read and all of them must report true.
function IO:findAssemblers()
    local p=self.peripheral
    local configured=self.config.hardware and self.config.hardware.physics_assembler
    if type(configured)=="string" and configured~="" then return {configured} end
    if not p or type(p.getNames)~="function" then return nil,"PERIPHERAL API UNAVAILABLE" end
    local ok,names=pcall(p.getNames)
    if not ok or type(names)~="table" then return nil,"PERIPHERAL LIST FAILED" end
    local found={}
    for _,name in ipairs(names) do
        if type(name)=="string" and hasPeripheralType(p,name,"physics_assembler") then found[#found+1]=name end
    end
    table.sort(found)
    if #found==0 then return nil,"NO PHYSICS ASSEMBLER FOUND" end
    return found
end
-- Yields: isAssembled() waits for the next server tick.
-- The Sable-first gate evaluates each timestamped assembler result.
-- Successful boolean responses carry their getter completion time.
-- Read errors retain the last definite response and its original timestamp.
-- assemblyGate checks fresh Sable association before fresh assembler evidence.
-- Unresolved verification keeps the gate open and warns after five minutes.
-- Applied lift settings remain retained through verification uncertainty.
-- Every change of gate state or read problem is printed to Status/Logs.
-- @ama-section: Observations | Independent sensor completion and vessel geometry.
-- @ama-summary: Read the available physics assemblers and retain their explicit assembled result.
function IO:sampleAssembly()
    local names,why=self:findAssemblers()
    local definite,reason=nil,why
    if names then
        definite=true
        for _,name in ipairs(names) do
            local value,readError=self:readSensor(name,"isAssembled")
            if value==false then definite,reason=false,text(name,64)..".isAssembled() = false"; break
            elseif value~=true then
                definite,reason=nil,text(readError or (name..".isAssembled() returned "..type(value)),120); break
            end
        end
    end
    local now=self:nowSeconds()
    local t=self.assemblyTrack or {}
    t.assemblers=names
    if definite~=nil then
        t.definite,t.definiteAt,t.definiteReason=definite,now,(not definite) and reason or nil
        t.error,t.errorAt=nil,nil
    else
        t.error,t.errorAt=reason or "PHYSICS ASSEMBLER GAVE NO ANSWER",now
    end
    self.assemblyTrack=t
    local _,message,detail=self:assemblyGate(now)
    local state=detail.state..(message and (" / "..message) or "")
    if type(print)=="function" then
        if state~=self.lastAssemblyState then print("Assembly gate: "..state) end
        -- Read problems are logged once per distinct text, not per read.
        if t.error and t.error~=self.lastAssemblyError then print("Assembly read problem: "..t.error) end
    end
    self.lastAssemblyState=state
    if t.error then self.lastAssemblyError=t.error end
    return t
end
-- Returns gateOpen, message, detail. detail goes into every core snapshot as
-- `assembly`; message is the display/refusal text when the gate is closed.
-- @ama-section: Core context | Registry, hardware discovery and protocol identity.
-- @ama-summary: Verify Sable association first, then assembler state, and time unresolved assembly warnings.
function IO:assemblyGate(now)
    local current=self:nowSeconds()
    if finite(current) and (not finite(now) or current>now) then now=current end
    local limit=(self.config.network or {}).sensor_stale_seconds or 18
    local primary=(self.primaryReadings or {}).uuid
    local association=primary and boundedString(primary.value,128) and finite(primary.at) and
        now>=primary.at and now-primary.at<=limit
    local track=self.assemblyTrack
    local assemblerFresh=track and finite(track.definiteAt) and now>=track.definiteAt and now-track.definiteAt<=limit
    local source=association and "SABLE" or (assemblerFresh and "PHYSICS ASSEMBLER" or "UNVERIFIED")
    local confirmed=association or (assemblerFresh and track.definite==true)
    local disassembled=not association and assemblerFresh and track.definite==false
    local incident=self.assemblyVerification or {}
    self.assemblyVerification=incident
    local detail={state=disassembled and "DISASSEMBLED" or "ASSEMBLED",
        assembled=not disassembled,verified=confirmed==true,source=source,checkedAt=now,
        lastDefiniteAt=track and track.definiteAt,lastReadError=track and track.error,
        staleAfterSeconds=limit,assemblers=track and track.assemblers}
    if confirmed or disassembled then
        incident.since=nil;incident.warning=nil
    else
        incident.since=incident.since or now
        detail.unverifiedSeconds=math.max(0,now-incident.since)
        detail.warning=detail.unverifiedSeconds>=300 and "ASSEMBLY UNVERIFIED; OPERATOR CHECK REQUIRED" or nil
        incident.warning=detail.warning
    end
    if disassembled then
        detail.reason=track.definiteReason or "PHYSICS ASSEMBLER REPORTS DISASSEMBLED"
        detail.message="VESSEL DISASSEMBLED: "..detail.reason
    end
    local note=source..(detail.warning and " / "..detail.warning or "")
    if self.assemblyVerificationNote~=note then
        self.assemblyVerificationNote=note
        if self.localID==nil and type(os.__amaryllisLog)=="function" then os.__amaryllisLog("Assembly verification: "..note,"state.assembly") end
    end
    return not disassembled,detail.message,detail
end

-- Normal runtime discovery wakes all four lift nodes. Bench commissioning
-- passes a quadrant so only the selected node's session is affected.
-- @ama-section: Commands | Correlated bounded requests and acknowledged application.
-- @ama-summary: Normal runtime discovery wakes all four lift nodes. Bench commissioning passes a quadrant so only the selected node's session is affected.
function IO:sendHello(quadrant)
    local packet = { v = 1, kind = "hello", session = self.session }
    local ok, reason
    if quadrant ~= nil then
        local node = self.nodes[quadrant]
        if not node then return false, "quadrant must be FL, FR, RL, or RR" end
        if not integer(node.id,0,65535) then return false,"lift role ID is unassigned" end
        if not self.rednet or type(self.rednet.send) ~= "function" then return false, "rednet send is unavailable" end
        ok, reason = pcall(self.rednet.send, node.id, packet, self.config.protocol)
    else
        if not self.rednet or type(self.rednet.broadcast) ~= "function" then return false, "rednet broadcast is unavailable" end
        ok, reason = pcall(self.rednet.broadcast, packet, self.config.protocol)
    end
    if not ok or reason == false then return false, "hello send failed: " .. text(reason) end
    self.lastHelloAt = self:nowSeconds()
    return true
end

-- @ama-section: Status | Validate incoming observations and publish cached fleet state.
-- @ama-summary: Validate a chamber's lift report before accepting its identity and provider data.
function IO:validateLiftStatus(sender, message, now,radioTiming)
    if type(message) ~= "table" or message.v ~= 1 or message.kind ~= "lift_status" then return false, "invalid status envelope" end
    if message.session ~= self.session then return false, "status belongs to another core session" end
    if not integer(sender, 0, 65535) then return false, "sender ID is invalid" end
    local quadrant = message.quadrant
    local node = self.nodes[quadrant]
    if not node or sender ~= node.id or message.id ~= node.id then return false, "sender ID or quadrant does not match configured identity" end
    if not boundedString(message.boot, 128) then return false, "node boot identity is invalid" end
    if type(message.ready) ~= "boolean" or type(message.armed) ~= "boolean" then return false, "node readiness fields must be booleans" end
    if message.localReady~=nil and type(message.localReady)~="boolean" then return false,"localReady must be a boolean" end
    if message.operationBusy~=nil and type(message.operationBusy)~="boolean" then return false,"operationBusy must be a boolean" end
    if message.systemsSupported~=nil and type(message.systemsSupported)~="boolean" then return false,"systemsSupported must be a boolean" end
    if message.shutdownSupported~=nil and type(message.shutdownSupported)~="boolean" then return false,"shutdownSupported invalid" end
    if message.shutdownAppliedSeq~=nil and not integer(message.shutdownAppliedSeq,1,self.lastIssuedSeq) then return false,"shutdownAppliedSeq invalid" end
    if message.emergencyDisarmAppliedSeq~=nil and not integer(message.emergencyDisarmAppliedSeq,1,self.lastIssuedSeq) then return false,"emergencyDisarmAppliedSeq invalid" end
    for _,key in ipairs({"thrustControlState","liftControlState"}) do
        local v=message[key]
        if v~=nil and v~="CMD" and v~="RDY" and v~="FAULT" then return false,key.." invalid" end
    end
    if message.emergencyStopAppliedSeq~=nil and not integer(message.emergencyStopAppliedSeq,1,self.lastIssuedSeq) then return false,"emergencyStopAppliedSeq invalid" end
    if message.emergencyStopLatched~=nil and type(message.emergencyStopLatched)~="boolean" then return false,"emergencyStopLatched invalid" end
    if message.emergencyStopVerified~=nil and type(message.emergencyStopVerified)~="boolean" then return false,"emergencyStopVerified invalid" end
    if message.emergencyStopMode~=nil and not boundedString(message.emergencyStopMode,64) then return false,"emergencyStopMode invalid" end
    if message.emergencyStopFault~=nil and (type(message.emergencyStopFault)~="string" or #message.emergencyStopFault>160) then return false,"emergencyStopFault invalid" end
    if message.systemsStartReady~=nil and type(message.systemsStartReady)~="boolean" then return false,"systemsStartReady must be a boolean" end
    if message.systemsProbeReady~=nil and type(message.systemsProbeReady)~="boolean" then return false,"systemsProbeReady must be a boolean" end
    if message.systemsStage~=nil and message.systemsStage~="probe" and message.systemsStage~="control" then return false,"systemsStage is invalid" end
    if message.assembled~=nil and type(message.assembled)~="boolean" then return false,"assembled must be a boolean" end
    if message.bindingFingerprintValid~=nil and type(message.bindingFingerprintValid)~="boolean" then
        return false,"bindingFingerprintValid must be a boolean"
    end
    if message.bindingFingerprint~=nil and (not boundedString(message.bindingFingerprint,8192) or
        message.bindingFingerprint:find("[%c]")) then return false,"bindingFingerprint is invalid" end
    if message.bindingGeneration~=nil and not integer(message.bindingGeneration,0,2147483647) then
        return false,"bindingGeneration is invalid"
    end
    local bootReasons={COMPONENT_STARTUP=true,INITIAL_DISCOVERY=true,BINDING_RECOVERY=true,FINGERPRINT_CHANGED=true}
    if message.bootReason~=nil and (type(message.bootReason)~="string" or not bootReasons[message.bootReason]) then
        return false,"bootReason is invalid"
    end

    local maximum = self.config.network.max_sequence
    if not integer(message.statusSeq, 1, maximum) then return false, "statusSeq is invalid" end
    if not integer(message.lastAppliedSeq, -1, self.lastIssuedSeq) then return false, "lastAppliedSeq is invalid or exceeds an issued command" end
    if message.lastReceivedSeq ~= nil and not integer(message.lastReceivedSeq, 0, self.lastIssuedSeq) then
        return false, "lastReceivedSeq is invalid or exceeds an issued command"
    end
    if not finite(now) then return false, "receive time is invalid" end

    if node.boot == message.boot then
        if node.statusSeq and message.statusSeq <= node.statusSeq then return false, "statusSeq replay or regression" end
        if message.lastAppliedSeq < node.lastAppliedSeq then return false, "lastAppliedSeq regressed within this boot" end
        if message.lastReceivedSeq and message.lastReceivedSeq < node.lastReceivedSeq then return false, "lastReceivedSeq regressed within this boot" end
    else
        if node.retiredBoots[message.boot] then return false, "status belongs to a retired node boot" end
        if node.boot and (not self.lastHelloAt or now - self.lastHelloAt > self.config.network.hello_interval_seconds * 2.5) then
            return false, "new boot has not answered a recent core hello"
        end
    end

    local providers, providerError = sanitizeProviders(message.providers, self.config.network.max_providers)
    if not providers then return false, providerError end
    local totalGasOutput, totalGasOutputValid = 0, next(providers) ~= nil
    for _, provider in pairs(providers) do
        if provider.gasOutputValid and finite(provider.gasOutput) then
            totalGasOutput = totalGasOutput + provider.gasOutput
        else
            totalGasOutputValid = false
        end
    end
    local appliedTargets = {}
    if message.appliedTargets ~= nil then
        if type(message.appliedTargets) ~= "table" then return false, "appliedTargets must be an object" end
        local count = 0
        for name, amount in pairs(message.appliedTargets) do
            count = count + 1
            if count > self.config.network.max_providers or not boundedString(name, 128) or not finite(amount) then
                return false, "appliedTargets contains invalid values"
            end
            appliedTargets[name] = amount
        end
    end

    local previousReceived,previousApplied=node.lastReceivedSeq,node.lastAppliedSeq
    local acceptedBootChanged=node.boot~=message.boot
    local priorBoot=node.boot
    local helloInterval=self.config.network.hello_interval_seconds
    local recentHello=finite(self.lastHelloAt) and now>=self.lastHelloAt and
        finite(helloInterval) and now-self.lastHelloAt<=helloInterval*2.5 and self.identityReady==true
    if acceptedBootChanged then
        node.lastSystemsCommand=nil
        if node.boot then node.retiredBoots[node.boot] = true end
        node.statusSeq, node.lastAppliedSeq, node.lastReceivedSeq = nil, -1, 0
        node.emergencyStopAppliedSeq=nil
        node.emergencyStopMode=nil
        node.emergencyStopLatched=false
        node.emergencyStopVerified=false
        node.emergencyStopFault=nil
        node.acceptedBootGeneration=(node.acceptedBootGeneration or 0)+1
        node.bootPrevious=priorBoot
        node.bootChangedAt=now
        node.bootChangeHelloAt=recentHello and self.lastHelloAt or nil
        node.bootRebindTrusted=recentHello
        node.bootRebindTrustedAt=recentHello and now or nil
    elseif recentHello then
        -- A first status may arrive before the periodic Hello, and a long
        -- discovery delay may outlast the first proof. Renew registration only
        -- when this fresh status follows a recent core Hello.
        node.bootRebindTrusted=true
        node.bootChangeHelloAt=self.lastHelloAt
        node.bootRebindTrustedAt=now
    end
    node.boot = message.boot
    node.statusSeq = message.statusSeq
    node.lastAppliedSeq = message.lastAppliedSeq
    node.lastReceivedSeq = message.lastReceivedSeq or node.lastReceivedSeq
    node.lastSeen = now
    node.statusReceivedEpochMs=diagnosticEpoch()
    -- Receiver/handler stamps are internal queue metadata, never packet fields.
    -- Keep their wall-clock deltas diagnostic-only; freshness uses original now.
    radioTiming=type(radioTiming)=="table" and radioTiming or {}
    node.statusReceiverEpochMs=integer(radioTiming.receiverEpochMs,0,9007199254740991) and radioTiming.receiverEpochMs or nil
    node.statusHandlerEpochMs=integer(radioTiming.handlerEpochMs,0,9007199254740991) and radioTiming.handlerEpochMs or nil
    node.statusQueueWaitSeconds=node.statusReceiverEpochMs and node.statusHandlerEpochMs and
        node.statusHandlerEpochMs>=node.statusReceiverEpochMs and
        (node.statusHandlerEpochMs-node.statusReceiverEpochMs)/1000 or nil
    node.statusPriority=integer(radioTiming.priority,0,2) and radioTiming.priority or nil
    node.statusFirstAckReceiverEpochMs=integer(radioTiming.firstAckReceiverEpochMs,0,9007199254740991) and
        radioTiming.firstAckReceiverEpochMs or nil
    node.statusFirstAckQueueWaitSeconds=node.statusFirstAckReceiverEpochMs and node.statusHandlerEpochMs and
        node.statusHandlerEpochMs>=node.statusFirstAckReceiverEpochMs and
        (node.statusHandlerEpochMs-node.statusFirstAckReceiverEpochMs)/1000 or nil
    node.statusAckReportsCoalesced=integer(radioTiming.ackReportsCoalesced,0,2147483647) and radioTiming.ackReportsCoalesced or nil
    node.statusSentEpochMs=integer(message.statusSentEpochMs,0,9007199254740991) and message.statusSentEpochMs or nil
    -- Optional timing is sanitized separately and has no authority effect.
    node.systemsCommandTiming=nil
    local timing=message.systemsCommandTiming
    if type(timing)=="table" and integer(timing.seq,1,node.lastReceivedSeq) and
        (timing.stage=="probe" or timing.stage=="control") then
        node.systemsCommandTiming={seq=timing.seq,stage=timing.stage,
            receivedEpochMs=integer(timing.receivedEpochMs,0,9007199254740991) and timing.receivedEpochMs or nil,
            appliedEpochMs=timing.seq==node.lastAppliedSeq and
                integer(timing.appliedEpochMs,0,9007199254740991) and timing.appliedEpochMs or nil}
    end
    if acceptedBootChanged or previousReceived~=node.lastReceivedSeq or previousApplied~=node.lastAppliedSeq then
        local diagnostic=node.systemsCommandTiming or {}
        liftDebugEvent(self,{kind="status",clock=now,epochMs=node.statusReceivedEpochMs,quadrant=node.quadrant,
            boot=node.boot,seq=diagnostic.seq,stage=diagnostic.stage,statusSeq=node.statusSeq,
            receivedSeq=node.lastReceivedSeq,appliedSeq=node.lastAppliedSeq,
            nodeReceivedEpochMs=diagnostic.receivedEpochMs,nodeAppliedEpochMs=diagnostic.appliedEpochMs,
            statusSentEpochMs=node.statusSentEpochMs,coreReceiverEpochMs=node.statusReceiverEpochMs,
            coreHandlerEpochMs=node.statusHandlerEpochMs,queueWaitSeconds=node.statusQueueWaitSeconds,
            radioPriority=node.statusPriority,firstAckReceiverEpochMs=node.statusFirstAckReceiverEpochMs,
            firstAckQueueWaitSeconds=node.statusFirstAckQueueWaitSeconds,ackReportsCoalesced=node.statusAckReportsCoalesced})
    end
    node.tuningSupported=message.tuningSupported==true
    node.ready, node.armed = message.ready, message.armed
    node.localReady=message.localReady
    node.operationBusy=message.operationBusy==true
    node.startReady=message.startReady==true
    node.systemsSupported=message.systemsSupported==true
    node.shutdownSupported=message.shutdownSupported==true
    node.shutdownAppliedSeq=message.shutdownAppliedSeq
    node.emergencyDisarmAppliedSeq=message.emergencyDisarmAppliedSeq
    node.thrustControlState=message.thrustControlState
    node.liftControlState=message.liftControlState
    node.emergencyStopAppliedSeq=message.emergencyStopAppliedSeq
    node.emergencyStopMode=message.emergencyStopMode and text(message.emergencyStopMode,64) or nil
    node.emergencyStopLatched=message.emergencyStopLatched==true
    node.emergencyStopVerified=message.emergencyStopVerified==true
    node.emergencyStopFault=message.emergencyStopFault and text(message.emergencyStopFault,160) or nil
    node.systemsStartReady=message.systemsStartReady==true
    node.systemsProbeReady=message.systemsProbeReady==true
    node.systemsStage=message.systemsStage
    node.bindingFingerprintValid=message.bindingFingerprintValid==true and
        boundedString(message.bindingFingerprint,8192) and not message.bindingFingerprint:find("[%c]") or false
    node.bindingFingerprint=node.bindingFingerprintValid and message.bindingFingerprint or nil
    node.bindingGeneration=integer(message.bindingGeneration,0,2147483647) and message.bindingGeneration or nil
    node.bootReason=message.bootReason
    -- Local CC:Sable check on the lift computer itself. nil means that node
    -- could not tell; only an explicit false closes the core assembly gate.
    node.assembled=message.assembled
    node.faults = {}
    if type(message.faults) == "table" then
        for index = 1, math.min(#message.faults, 16) do
            if type(message.faults[index]) == "string" then node.faults[#node.faults + 1] = text(message.faults[index], 100) end
        end
    elseif type(message.faults) == "string" and message.faults ~= "" then
        node.faults[1] = text(message.faults, 100)
    end
    node.steamCount = integer(message.steamCount,1,63) and message.steamCount or (message.steamCount==nil and 8 or 0)
    node.providers = providers
    node.totalGasOutput = totalGasOutputValid and totalGasOutput or nil
    node.totalGasOutputValid = totalGasOutputValid
    node.balloon = sanitizeBalloon(message.balloon)
    node.startReady = message.startReady == true
    -- The old commissioning flag is no longer part of lift readiness. Prefer
    -- the explicit validated local readiness field; `ready` is the compatible
    -- fallback for older status senders, and also includes local readiness.
    node.commissioned = message.ready==true and message.localReady~=false
    -- Local section height is distinct from vessel CoM. Only finite, explicitly
    -- valid world-Y samples with the agreed mounting offset enter core state.
    node.phase = type(message.phase) == "string" and text(message.phase, 48) or nil
    node.altitude = { valid = false }
    local localAltitude = message.altitude
    if type(localAltitude) == "table" and localAltitude.valid == true and
        finite(localAltitude.sensorWorldY) and localAltitude.lowestPointOffsetBlocks == 4 then
        node.altitude = {
            valid = true, sensorWorldY = localAltitude.sensorWorldY,
            lowestPointWorldY = localAltitude.sensorWorldY - 4,
            lowestPointOffsetBlocks = 4, unit = "world Y",
            source = type(localAltitude.source) == "string" and text(localAltitude.source, 96) or nil,
        }
    end
    node.appliedTargets = appliedTargets
    return true
end

-- @ama-section: Commands | Correlated bounded requests and acknowledged application.
-- @ama-summary: Resolve a fresh altitude/input authority context for chamber status.
local function validatedLiftControlContext(self,quadrant,context)
    if context==nil then return nil end
    local node=self.nodes[quadrant]
    if type(context)~="table" or not node or not integer(context.contextSeq,1,self.config.network.max_sequence) or
        type(context.pidActive)~="boolean" or type(context.inputsActive)~="boolean" then
        return nil,"control context identity or activity fields are invalid"
    end
    local altitude=context.selectedAltitude
    if altitude~=nil then
        local limits=self.config.altitude_control or {}
        if not finite(altitude) or not finite(limits.minimum_world_y) or not finite(limits.maximum_world_y) or
            altitude<limits.minimum_world_y or altitude>limits.maximum_world_y then
            return nil,"selected altitude in control context is invalid"
        end
    end
    if context.pidActive and context.inputsActive and altitude==nil then
        return nil,"active control context requires a selected altitude"
    end
    return {contextSeq=context.contextSeq,selectedAltitude=altitude,pidActive=context.pidActive,
        inputsActive=context.inputsActive,leaseSeconds=CONTROL_CONTEXT_LEASE_SECONDS}
end

-- @ama-summary: Publish the current selected-altitude and control-activity lease to a chamber.
function IO:sendLiftControlContext(quadrant,context)
    local allowed,identityReason=self:routeAllowed()
    if not allowed then return false,identityReason end
    local node=self.nodes[quadrant]
    if not node or not integer(node.id,0,65535) or not boundedString(node.boot,128) then
        return false,"LIFT NODE IDENTITY UNAVAILABLE"
    end
    if type(context)~="table" or type(context.pidActive)~="boolean" or type(context.inputsActive)~="boolean" then
        return false,"CONTROL CONTEXT INVALID"
    end
    local altitude=context.selectedAltitude
    if altitude~=nil then
        local limits=self.config.altitude_control or {}
        if not finite(altitude) or not finite(limits.minimum_world_y) or not finite(limits.maximum_world_y) or
            altitude<limits.minimum_world_y or altitude>limits.maximum_world_y then
            return false,"SELECTED ALTITUDE INVALID"
        end
    end
    if context.pidActive and context.inputsActive and altitude==nil then
        return false,"ACTIVE CONTROL CONTEXT NEEDS SELECTED ALTITUDE"
    end
    local sequence=self.controlContextSeq+1
    if not integer(sequence,1,self.config.network.max_sequence) then return false,"CONTROL CONTEXT SEQUENCE LIMIT" end
    self.controlContextSeq=sequence
    local packet={v=1,kind="lift_control_context",session=self.session,quadrant=quadrant,
        nodeBoot=node.boot,context={contextSeq=sequence,selectedAltitude=altitude,
            pidActive=context.pidActive,inputsActive=context.inputsActive,
            leaseSeconds=CONTROL_CONTEXT_LEASE_SECONDS}}
    if not self.rednet or type(self.rednet.send)~="function" then return false,"REDNET UNAVAILABLE" end
    local ok,sent=pcall(self.rednet.send,node.id,packet,self.config.protocol)
    if not ok or sent==false then return false,"CONTROL CONTEXT SEND FAILED" end
    packet.context.expiresAt=self:nowSeconds()+CONTROL_CONTEXT_LEASE_SECONDS
    self.liftControlContexts[quadrant]=packet.context
    return true,sequence
end

-- Shared allowlist/sequence boundary for bench, altitude, and the explicitly
-- bounded minimum-output startup profile. The bridge sends requests to core.
-- @ama-summary: Shared allowlist/sequence boundary for bench, altitude, and the explicitly bounded minimum-output startup profile. The bridge sends requests to core.
function IO:buildLiftCommand(quadrant, targets, operatorConfirmation, continuous, controlContext)
    local allowed,identityReason=self:routeAllowed()
    if not allowed then return nil,identityReason end
    local node = self.nodes[quadrant]
    if not node then return nil, "quadrant must be FL, FR, RL, or RR" end
    local startup=continuous=="startup" and self.config.vent_startup_enabled==true and
        operatorConfirmation=="START VENTS AT 50"
    if not startup and (self.config.commissioning.enabled ~= true or self.config.commissioning.confirm_supported ~= true or
        operatorConfirmation ~= "CONFIRM SUPPORTED HARDWARE") then
        return nil, "commissioning is locked; verify hardware, enable both JSON gates, and use the exact confirmation phrase"
    end
    local now = self:nowSeconds()
    if not self:nodeFresh(quadrant, now) then return nil, "lift node status is stale" end
    if node.ready ~= true and node.startReady ~= true then return nil, "lift node is not ready" end
    if (node.armed or node.operationBusy) and not continuous then return nil, "node is already operating; wait for the lift controller to become idle" end
    if startup and (node.armed or node.operationBusy) then return nil,"cannot start vents on an operating controller" end
    local commandContext,contextError
    if controlContext~=nil then
        if startup then return nil,"startup commands cannot claim PID control context" end
        commandContext,contextError=validatedLiftControlContext(self,quadrant,controlContext)
        if not commandContext then return nil,contextError end
    end
    if type(targets) ~= "table" then return nil, "target file must contain a targets object" end

    local count = 0
    for name in pairs(node.providers) do
        count = count + 1
        if targets[name] == nil then return nil, "target file is missing provider " .. name end
    end
    if count == 0 or count > self.config.network.max_providers then return nil, "node has no verified provider allowlist" end
    local checked, targetCount,bulk,fine = {}, 0,0,0
    for name, amount in pairs(targets) do
        targetCount = targetCount + 1
        local provider = node.providers[name]
        if not provider then return nil, "target file includes an unconfigured provider " .. text(name) end
        if not finite(amount) or amount % 1 ~= 0 or amount < provider.minTarget or amount > provider.maxTarget then
            return nil, "target for " .. name .. " must be an integer within the node-reported bounds"
        end
        if amount > 0 and amount < (provider.minimumNonzeroTarget or provider.minTarget) then
            return nil, "target for " .. name .. " is below the minimum nonzero setting"
        end
        if provider.present ~= true or provider.writable ~= true then return nil, "provider " .. name .. " is not present and writable" end
        if startup then
            if not provider.targetValid or not provider.signalValid then return nil,"startup provider readings unavailable" end
            if provider.controlRole=="bulk" then
                bulk=bulk+1
                if amount~=50 or provider.minimumNonzeroTarget~=50 or
                    (provider.signalStrength>1 and provider.targetAmount~=50) then return nil,"startup can only begin idle vents at 50" end
            elseif provider.controlRole=="fine" then
                fine=fine+1
                if amount~=provider.targetAmount or amount<5 or provider.signalStrength~=15 or
                    not provider.attachedValid or not provider.attached then return nil,"startup must preserve the active trim probe" end
            else return nil,"startup provider role invalid" end
        end
        checked[name] = amount
    end
    if targetCount ~= count then return nil, "target file must cover the full provider allowlist" end
    if startup and (bulk~=steamCount(node) or fine~=1 or type(node.boot)~="string") then return nil,"startup requires configured vents, one probe and current boot identity" end

    local seq = self.commandSeq + 1
    if not integer(seq, 1, self.config.network.max_sequence) then return nil, "command sequence limit reached; start a new session" end
    self.commandSeq, self.lastIssuedSeq = seq, seq
    return { v = 1, kind = "lift_command", session = self.session, seq = seq, quadrant = quadrant, targets = checked, enable = true,
        startup=startup or nil,nodeBoot=(startup or commandContext) and node.boot or nil,
        controlContext=commandContext}
end

-- @ama-summary: Send the bounded initial vent command to its configured chamber.
function IO:sendVentStartup(quadrant,targets)
    local packet,reason=self:buildLiftCommand(quadrant,targets,"START VENTS AT 50","startup")
    if not packet then return false,reason end
    if not self.rednet or type(self.rednet.send)~="function" then return false,"rednet unavailable" end
    local ok,sent=pcall(self.rednet.send,self.nodes[quadrant].id,packet,self.config.protocol)
    if not ok or sent==false then return false,"vent startup send failed" end
    return true,packet.seq
end

-- Explicit START SYSTEMS command path. This authority is separate from the
-- commissioning gates because its node receiver enforces the probe/control
-- stages, hardware ceilings, session, boot, sequence, and short renewable lease.
-- @ama-summary: Explicit START SYSTEMS command path. This authority is separate from the commissioning gates because its node receiver enforces the probe/control stages, hardware ceilings, session, boot, sequence, and short renewable lease.
function IO:sendSystemsCommand(quadrant,targets,stage)
    local allowed,identityReason=self:routeAllowed()
    if not allowed then return false,identityReason end
    local node=self.nodes[quadrant]
    if stage~="probe" and stage~="control" then return false,"INVALID SYSTEMS STAGE" end
    if not node or not self:nodeFresh(quadrant) or type(node.boot)~="string" or
        node.systemsSupported~=true then return false,"SYSTEMS INTERFACE UNAVAILABLE" end
    if stage=="probe" and node.systemsStartReady~=true then return false,"SYSTEMS PROBE HARDWARE NOT READY" end
    if stage=="control" and (node.systemsProbeReady~=true or (node.ready~=true and node.startReady~=true)) then
        return false,"SYSTEMS PROBE OR CONTROL HARDWARE NOT READY"
    end
    local ownsSystems=node.systemsStage=="probe" or node.systemsStage=="control"
    if stage=="probe" and (node.armed or node.operationBusy) and not (node.systemsStage=="probe" and node.systemsProbeReady) then
        return false,"LIFT NODE ALREADY ARMED"
    end
    if stage=="control" and (node.armed or node.operationBusy) and not ownsSystems then
        return false,"LIFT NODE HAS ANOTHER CONTROL OWNER"
    end
    if type(targets)~="table" then return false,"TARGET MAP MUST BE AN OBJECT" end
    local checked,count={},0
    for name,provider in pairs(node.providers or {}) do
        count=count+1
        local amount=targets[name]
        local preservedInactiveBulk=stage=="probe" and provider.controlRole=="bulk" and
            provider.signalStrength==0 and amount==provider.targetAmount
        if amount==nil or not integer(amount,provider.minTarget,provider.maxTarget) or
            (amount>0 and amount<(provider.minimumNonzeroTarget or provider.minTarget) and not preservedInactiveBulk) then
            return false,"TARGET OUT OF BOUNDS: "..text(name)
        end
        if provider.present~=true or provider.writable~=true or
            provider.targetValid~=true or provider.signalValid~=true then
            return false,"PROVIDER STATUS UNAVAILABLE: "..text(name)
        end
        if provider.controlRole=="bulk" then
            if stage=="probe" then
                if amount~=provider.targetAmount then
                    return false,"PROBE MUST PRESERVE BULK: "..text(name)
                end
                if amount==0 and provider.signalStrength>0 then return false,"PROBE CANNOT STOP ACTIVE BULK" end
            elseif amount<math.max(50,provider.minimumNonzeroTarget or 1) then
                return false,"CONTROL BULK BELOW MINIMUM: "..text(name)
            end
        elseif provider.controlRole=="fine" then
            if (stage=="probe" or amount>0) and amount<(provider.minimumNonzeroTarget or 5) then return false,"TRIM TARGET BELOW MINIMUM" end
        else return false,"PROVIDER ROLE INVALID: "..text(name) end
        checked[name]=amount
    end
    local entries=0
    for name in pairs(targets) do entries=entries+1;if not node.providers[name] then return false,"UNKNOWN PROVIDER: "..text(name) end end
    if count~=steamCount(node)+1 or entries~=count then return false,"SYSTEMS COMMAND NEEDS CONFIGURED VENTS AND ONE TRIM" end

    local seq=self.commandSeq+1
    if not integer(seq,1,self.config.network.max_sequence) then return false,"COMMAND SEQUENCE LIMIT" end
    self.commandSeq=seq;self.lastIssuedSeq=seq
    local packet={v=1,kind="lift_systems",session=self.session,seq=seq,quadrant=quadrant,
        nodeBoot=node.boot,stage=stage,targets=checked,enable=true}
    local cachedContext=self.liftControlContexts[quadrant]
    if stage=="control" and cachedContext and finite(cachedContext.expiresAt) and self:nowSeconds()<cachedContext.expiresAt then
        local context,contextError=validatedLiftControlContext(self,quadrant,cachedContext)
        if not context then return false,contextError end
        packet.controlContext=context
    end
    if not self.rednet or type(self.rednet.send)~="function" then return false,"REDNET UNAVAILABLE" end
    node.lastSystemsCommand={seq=seq,stage=stage,boot=node.boot,sentAt=self:nowSeconds(),sentEpochMs=diagnosticEpoch()}
    liftDebugEvent(self,{kind="send",clock=node.lastSystemsCommand.sentAt,epochMs=node.lastSystemsCommand.sentEpochMs,
        quadrant=quadrant,boot=node.boot,seq=seq,stage=stage})
    local ok,sent=pcall(self.rednet.send,node.id,packet,self.config.protocol)
    liftDebugEvent(self,{kind="send_result",clock=self:nowSeconds(),epochMs=diagnosticEpoch(),
        quadrant=quadrant,boot=packet.nodeBoot,seq=seq,stage=stage,sendSucceeded=ok and sent~=false})
    if not ok or sent==false then return false,"SYSTEMS COMMAND SEND FAILED" end
    return true,seq
end

-- Cancelling START SYSTEMS removes controller authority and keeps the most
-- recently applied ceilings. It deliberately sends no redstone-off signal.
-- @ama-summary: Send a systems lease release or explicitly requested main-lift shutdown.
function IO:sendSystemsStop(quadrant,zeroLift)
    local allowed,identityReason=self:routeAllowed()
    if not allowed then return false,identityReason end
    local node=self.nodes[quadrant]
    if not node or type(node.boot)~="string" then return false,"LIFT NODE BOOT UNKNOWN" end
    if zeroLift and node.shutdownSupported~=true then return false,"UPDATE LIFT NODE FOR ZERO-LIFT STOP" end
    if not self.rednet or type(self.rednet.send)~="function" then return false,"REDNET UNAVAILABLE" end
    local seq=self.commandSeq+1
    if not integer(seq,1,self.config.network.max_sequence) then return false,"COMMAND SEQUENCE LIMIT" end
    self.commandSeq=seq;self.lastIssuedSeq=seq
    local packet={v=1,kind="lift_systems_stop",session=self.session,seq=seq,quadrant=quadrant,nodeBoot=node.boot}
    if zeroLift then packet.zeroLift=true;packet.confirmation="STOP SYSTEMS ZERO LIFT" end
    local ok,sent=pcall(self.rednet.send,node.id,packet,self.config.protocol)
    if not ok or sent==false then return false,"SYSTEMS STOP SEND FAILED" end
    return true,seq
end

function IO:shutdownWasApplied(quadrant,seq)
    local node=self.nodes[quadrant]
    return node and self:nodeFresh(quadrant) and node.shutdownAppliedSeq==seq and
        node.lastAppliedSeq==seq and node.armed==false
end

-- The emergency lift kill is deliberately independent of assembly, tuning,
-- maintenance and controller readiness. It still requires a verified core
-- identity and a fresh, boot-pinned status from the addressed chamber.
-- @ama-summary: The emergency lift kill is deliberately independent of assembly, tuning, maintenance and controller readiness. It still requires a verified core identity and a fresh, boot-pinned status from the addressed chamber.
function IO:sendEmergencyLiftStop(quadrant,now)
    local allowed,identityReason=self:routeAllowed()
    if not allowed then return false,identityReason end
    local node=self.nodes[quadrant]
    if not node or not self:nodeFresh(quadrant,now) or type(node.boot)~="string" then
        return false,"FRESH LIFT NODE STATUS REQUIRED"
    end
    if not self.rednet or type(self.rednet.send)~="function" then return false,"REDNET UNAVAILABLE" end
    local seq=self.commandSeq+1
    if not integer(seq,1,self.config.network.max_sequence) then return false,"COMMAND SEQUENCE LIMIT" end
    self.commandSeq=seq;self.lastIssuedSeq=seq
    local packet={v=1,kind="lift_emergency_stop",session=self.session,seq=seq,
        quadrant=quadrant,nodeBoot=node.boot,emergencyStopMode="BULK_OFF_PROBE_ON",
        confirmation="KILL LIFT BULK OFF PROBE ON"}
    local ok,sent=pcall(self.rednet.send,node.id,packet,self.config.protocol)
    if not ok or sent==false then return false,"EMERGENCY LIFT STOP SEND FAILED" end
    return true,seq,node.boot
end

-- @ama-summary: Send a session-bound emergency-latch disarm request.
function IO:sendEmergencyLiftDisarm(quadrant,now)
    local allowed,reason=self:routeAllowed()
    if not allowed then return false,reason end
    local node=self.nodes[quadrant]
    if not node or not self:nodeFresh(quadrant,now) or type(node.boot)~="string" then return false,"FRESH LIFT NODE STATUS REQUIRED" end
    if not self.rednet or type(self.rednet.send)~="function" then return false,"REDNET UNAVAILABLE" end
    local seq=self.commandSeq+1
    if not integer(seq,1,self.config.network.max_sequence) then return false,"COMMAND SEQUENCE LIMIT" end
    self.commandSeq=seq;self.lastIssuedSeq=seq
    local packet={v=1,kind="lift_emergency_disarm",session=self.session,seq=seq,
        quadrant=quadrant,nodeBoot=node.boot,confirmation="DISARM LIFT KILL"}
    local ok,sent=pcall(self.rednet.send,node.id,packet,self.config.protocol)
    if not ok or sent==false then return false,"EMERGENCY DISARM SEND FAILED" end
    return true,seq,node.boot
end

-- @ama-section: Core context | Registry, hardware discovery and protocol identity.
-- @ama-summary: Check a chamber's emergency-stop latch and zero-output readbacks.
function IO:emergencyLiftStopStateVerified(quadrant,boot,now)
    local node=self.nodes[quadrant]
    if not node or not self:nodeFresh(quadrant,now) then return false,"LIFT STATUS STALE" end
    if node.boot~=boot then return false,"LIFT BOOT CHANGED" end
    if node.emergencyStopMode~="BULK_OFF_PROBE_ON" then return false,"EMERGENCY STOP MODE NOT VERIFIED" end
    if node.emergencyStopLatched~=true or node.emergencyStopVerified~=true or node.armed~=false then
        return false,node.emergencyStopFault or "EMERGENCY STOP NOT VERIFIED"
    end
    local balloon=node.balloon
    if type(balloon)~="table" or balloon.hasBalloonValid~=true or balloon.hasBalloon~=true or
        balloon.gasMixValid~=true or balloon.liftValid~=true or not finite(balloon.lift) or balloon.lift<0 then
        return false,"ATTACHED BALLOON STATUS NOT VERIFIED"
    end
    local bulk,fine,count=0,0,0
    for name,provider in pairs(node.providers or {}) do
        count=count+1
        if provider.present~=true or provider.targetValid~=true or not finite(provider.targetAmount) or
            provider.signalValid~=true or not integer(provider.signalStrength,0,15) then
            return false,"PROVIDER "..text(name,48).." STATUS INCOMPLETE"
        end
        if provider.controlRole=="bulk" then
            bulk=bulk+1
            if provider.signalStrength~=0 then return false,"BULK PROVIDER "..text(name,48).." SIGNAL NOT OFF" end
        elseif provider.controlRole=="fine" then
            fine=fine+1
            -- A disabled bulk vent can stop exposing attached/output telemetry
            -- once it produces nothing. The probe remains the authoritative
            -- attachment proof for the live balloon envelope above.
            if provider.attachedValid~=true or provider.attached~=true then
                return false,"FINE PROBE ATTACHMENT NOT VERIFIED"
            end
            if provider.minimumNonzeroTarget~=5 or provider.targetAmount~=5 or provider.signalStrength~=15 then
                return false,"FINE PROBE FLOOR / SIGNAL NOT VERIFIED"
            end
        else
            return false,"PROVIDER "..text(name,48).." CONTROL ROLE INVALID"
        end
    end
    if count~=steamCount(node)+1 or bulk~=steamCount(node) or fine~=1 then return false,"EXPECTED CONFIGURED BULK PROVIDERS AND ONE FINE PROBE" end
    return true
end

-- @ama-summary: Correlate a chamber's verified emergency stop with the sent sequence.
function IO:emergencyLiftStopWasApplied(quadrant,seq,boot,now)
    local node=self.nodes[quadrant]
    if not node or not self:nodeFresh(quadrant,now) then return false,"LIFT STATUS STALE" end
    if node.boot~=boot then return false,"LIFT BOOT CHANGED" end
    if node.emergencyStopAppliedSeq~=seq then
        return false,node.emergencyStopFault or "WAITING FOR EMERGENCY STOP ACK"
    end
    return self:emergencyLiftStopStateVerified(quadrant,boot,now)
end

-- Flight has already checked the complete vessel and all four envelopes.
-- Reuse the same exact provider allowlist/bounds and sequence boundary as bench
-- commissioning, while allowing subsequent commands to an armed controller.
-- Tuning has its own bounded packet path. It cannot set commissioning flags,
-- activate links, alter trim, or extend a node's captured lease on later packets.
-- @ama-section: Commands | Correlated bounded requests and acknowledged application.
-- @ama-summary: Send bounded tuning targets under the current test authority.
function IO:sendTuningCommand(quadrant,targets,id,baseline,first)
 local allowed,identityReason=self:routeAllowed();if not allowed then return false,identityReason end
 local n=self.nodes[quadrant]
 if not self.config.tuning or not self.config.tuning.enabled or not n or not self:nodeFresh(quadrant) or
  n.tuningSupported~=true or not boundedString(id,128) or not self.rednet then return false,"TUNING INTERFACE UNAVAILABLE" end
 local checked,count={},0
 for name,p in pairs(n.providers) do
  local amount,base=targets[name],baseline[name];count=count+1
  local parked=p.controlRole=="fine" and base==0 and amount==0 and p.signalStrength==0
  if (not parked and (not integer(base,1,p.maxTarget) or not integer(amount,p.minimumNonzeroTarget,p.maxTarget) or
   p.signalStrength~=15 or not p.attachedValid or not p.attached)) or
   not p.targetValid or not p.signalValid then return false,"TUNING PROVIDER NOT READY" end
  if p.controlRole=="fine" then if amount~=base then return false,"TUNING MUST PRESERVE TRIM" end
  elseif p.controlRole=="bulk" then
   if amount<math.ceil(base*.95) or amount>math.floor(base*1.05) then return false,"TUNING LIMIT EXCEEDED" end
  else return false,"TUNING ROLE INVALID" end
  if first and (base~=p.targetAmount or amount~=base) then return false,"TUNING BASELINE CHANGED" end
  checked[name]=amount
 end
 local entries=0;for name in pairs(targets) do entries=entries+1;if not n.providers[name] then return false,"UNKNOWN TUNING PROVIDER" end end
 if entries~=count or count~=steamCount(n)+1 then return false,"INCOMPLETE TUNING MAP" end
 local seq=self.commandSeq+1;if not integer(seq,1,self.config.network.max_sequence) then return false,"SEQUENCE EXHAUSTED" end
 self.commandSeq=seq;self.lastIssuedSeq=seq
 local packet={v=1,kind="lift_tuning",session=self.session,seq=seq,quadrant=quadrant,nodeBoot=n.boot,
  id=id,first=first==true,targets=checked,baseline=first and baseline or nil}
 local ok,sent=pcall(self.rednet.send,n.id,packet,self.config.protocol)
 if not ok or sent==false then return false,"TUNING SEND FAILED" end
 return true,seq
end
-- @ama-summary: Release the chamber tuning lease for the current session.
function IO:cancelTuning(quadrant,id)
 local allowed=self:routeAllowed();if not allowed then return false end
 local n=self.nodes[quadrant];if not n or not self.rednet then return false end
 local seq=self.commandSeq+1;if not integer(seq,1,self.config.network.max_sequence) then return false end
 self.commandSeq=seq;self.lastIssuedSeq=seq
 local ok,sent=pcall(self.rednet.send,n.id,{v=1,kind="lift_tuning_stop",session=self.session,seq=seq,
  quadrant=quadrant,nodeBoot=n.boot,id=id},self.config.protocol)
 return ok and sent~=false
end

-- @ama-summary: Validate and send a chamber altitude-control command.
function IO:sendAltitudeCommand(quadrant, targets)
    local context=self.liftControlContexts[quadrant]
    if not context or not finite(context.expiresAt) or self:nowSeconds()>=context.expiresAt then context=nil end
    local packet,reason=self:buildLiftCommand(quadrant,targets,"CONFIRM SUPPORTED HARDWARE",true,
        context)
    if not packet then return false,reason end
    if not self.rednet or type(self.rednet.send)~="function" then return false,"rednet unavailable" end
    local ok,sent=pcall(self.rednet.send,self.nodes[quadrant].id,packet,self.config.protocol)
    if not ok or sent==false then return false,"rednet command failed" end
    return true,packet.seq
end

-- @ama-summary: Send the selected chamber's bounded lift target map.
function IO:sendLiftCommand(quadrant, targets, operatorConfirmation)
    local packet, reason = self:buildLiftCommand(quadrant, targets, operatorConfirmation)
    if not packet then return false, reason end
    if not self.rednet or type(self.rednet.send) ~= "function" then return false, "rednet send is unavailable" end
    local ok, sendError = pcall(self.rednet.send, self.nodes[quadrant].id, packet, self.config.protocol)
    if not ok or sendError == false then return false, "lift command send failed: " .. text(sendError) end
    return true, packet.seq
end

-- @ama-summary: Match a chamber's acknowledged applied sequence with the requested command.
function IO:commandWasApplied(quadrant, seq, targets)
    local node = self.nodes[quadrant]
    if not node or node.lastAppliedSeq ~= seq or not self:nodeFresh(quadrant) then return false end
    for name, amount in pairs(targets) do
        local provider = node.providers[name]
        if not provider or provider.targetValid ~= true then return false end
        local applied=node.appliedTargets and node.appliedTargets[name]
        local exact=applied==amount and provider.targetAmount==amount
        -- The trim park command is a logical zero output. Some provider
        -- setters clamp its stored ceiling to the real minimum (normally 5),
        -- while the activation signal remains verifiably off. Keep the intent
        -- at zero for the control loop and accept only that exact readback.
        local parkedFine=amount==0 and provider.controlRole=="fine" and node.systemsStage=="control" and
            provider.signalValid==true and provider.signalStrength==0 and
            provider.targetAmount==(provider.minimumNonzeroTarget or 5) and applied==provider.targetAmount
        if not exact and not parkedFine then return false end
    end
    for name in pairs(node.appliedTargets or {}) do if targets[name] == nil then return false end end
    local command=node.lastSystemsCommand
    if command and command.seq==seq and command.boot==node.boot and command.ackAt==nil then
        command.ackAt=self:nowSeconds();command.ackEpochMs=diagnosticEpoch()
        liftDebugEvent(self,{kind="ack_verified",clock=command.ackAt,epochMs=command.ackEpochMs,
            quadrant=quadrant,boot=node.boot,seq=seq,stage=command.stage,statusSeq=node.statusSeq,
            receivedSeq=node.lastReceivedSeq,appliedSeq=node.lastAppliedSeq})
    end
    return true
end

-- @ama-section: Core context | Registry, hardware discovery and protocol identity.
-- @ama-summary: Validate an incoming fleet packet and dispatch it to its role-specific receiver.
function IO:processMessage(sender, message, protocol, now,radioTiming)
    if protocol ~= self.config.protocol or type(message) ~= "table" then return false end
    if message.kind=="registry_request" then return self:handleRegistryRequest(sender,message,protocol) end
    if self.thrust and self.thrust:processMessage(self,sender,message,protocol,now or self:nowSeconds()) then return true end
    if message.kind == "subsystem_status" then return self:acceptSubsystemStatus(sender,message,now or self:nowSeconds()) end
    if message.kind == "role_status" then return self:acceptRoleStatus(sender,message,now or self:nowSeconds()) end
    if message.kind ~= "lift_status" then return false end
    return self:validateLiftStatus(sender, message, now or self:nowSeconds(),radioTiming)
end

-- These reports describe role/radio health, not proof that all peripherals work.
-- Only known display/bridge senders, the active core session and fresh ordering
-- are accepted. Lift nodes already provide their richer lift_status reports.
-- @ama-section: Status | Validate incoming observations and publish cached fleet state.
-- @ama-summary: Validate and cache a registered subsystem report.
function IO:acceptSubsystemStatus(sender,message,now)
    local role,label
    if self.fleet then role,label=self.fleet:roleForID(sender) end
    local expectedRole=role=="navigator" and "bridge" or
        ((role=="heading-main" or role=="heading-left" or role=="heading-right") and "heading" or nil)
    if not expectedRole or message.v~=1 or message.session~=self.session or
        message.label~=label or message.role~=expectedRole or
        not boundedString(message.boot,128) or not message.boot:match("^[%w_%.%-:]+$") or
        not integer(message.seq,1,self.config.network.max_sequence) or
        type(message.coreDataFresh)~="boolean" or type(message.monitorAttached)~="boolean" or not finite(now) then return false end
    local report=self.subsystemReports[sender] or {retired={},order={}}
    if report.retired[message.boot] or (report.boot==message.boot and message.seq<=(report.seq or 0)) then return false end
    if report.boot and report.boot~=message.boot then
        report.retired[report.boot]=true; report.order[#report.order+1]=report.boot
        if #report.order>32 then report.retired[table.remove(report.order,1)]=nil end
    end
    report.boot,report.seq,report.at=message.boot,message.seq,now
    report.coreDataFresh,report.monitorAttached=message.coreDataFresh,message.monitorAttached
    self.subsystemReports[sender]=report
    return true
end

-- @ama-summary: Validate and cache a registered computer's runtime report.
function IO:acceptRoleStatus(sender,message,now)
    local role
    if self.fleet then role=self.fleet:roleForID(sender) end
    local expected=role and self.expectedPackages[role]
    local version=type(message.version)=="number" and message.version or tonumber(message.version)
    if role and role~="core" and expected and
        (message.packageId~=expected.packageId or version~=expected.version) then
        self:loadRoleManifests()
        expected=self.expectedPackages[role]
        version=type(message.version)=="number" and message.version or tonumber(message.version)
    end
    if not role or role=="core" or not expected or message.v~=1 or message.kind~="role_status" or message.role~=role or
        message.coreID~=self.localID or message.coreSession~=self.session or
        message.packageId~=expected.packageId or version~=expected.version or
        not boundedString(message.boot,128) or not message.boot:match("^[%w_%.%-:]+$") or
        not integer(message.seq,1,self.config.network.max_sequence) or
        type(message.running)~="boolean" or type(message.hardwareAvailable)~="boolean" or
        type(message.faultSummary)~="string" or #message.faultSummary>384 or not finite(now) then return false end
    local report=self.roleReports[role] or {retired={},order={}}
    if report.retired[message.boot] then return false end
    if report.boot==message.boot then
        if message.seq<=(report.seq or 0) then return false end
    elseif report.boot then
        local age=now-report.at
        if age>=0 and age<=self.config.network.node_stale_seconds then return false end
        report.retired[report.boot]=true; report.order[#report.order+1]=report.boot
        if #report.order>32 then report.retired[table.remove(report.order,1)]=nil end
    end
    report.boot,report.seq,report.at=message.boot,message.seq,now
    report.packageId,report.version=message.packageId,expected.version
    report.running,report.hardwareAvailable=message.running,message.hardwareAvailable
    report.faultSummary=text(message.faultSummary,160)
    self.roleReports[role]=report
    return true
end

-- @ama-summary: Assemble subsystem availability and reasons from registered role reports.
function IO:buildSubsystems(now)
    local core=self.computers and self.computers.core or {}
    local systems={{id=self.localID,label=core.label or "core",role=self.stateLink and "flight control authority" or "central telemetry / cockpit",
        status=self.identityReady and "RUNNING" or "IDENTITY ERROR",detail=self.identityReason,localNode=true}}
    local roleStates={}
    local stateRank={ONLINE=0,DEGRADED=1,STOPPED=2,["NO FRESH PACKAGE REPORT"]=3,
        ["PACKAGE MANIFEST ERROR"]=3,UNASSIGNED=4}
    -- @ama-summary: Add one role's validated cached report to the subsystem snapshot.
    local function recordRole(role,id,status)
        local state
        if id==nil then state="UNASSIGNED"
        elseif self.packageErrors[role] then state="PACKAGE MANIFEST ERROR"
        else state=status end
        local previous=roleStates[role]
        if not previous or (stateRank[state] or 2)>(stateRank[previous] or 2) then roleStates[role]=state end
    end
    -- @ama-summary: Resolve the role's expected package identity and installed status.
    local function packageState(role)
        local health=self.roleReports[role]
        local fresh=health and now>=health.at and now-health.at<=self.config.network.node_stale_seconds
        if not fresh then return "NO FRESH PACKAGE REPORT",self.packageErrors[role] or "Expected package is not reporting",nil end
        if not health.running then return "STOPPED",health.faultSummary,health end
        if not health.hardwareAvailable or health.faultSummary~="" then
            return "DEGRADED",health.faultSummary~="" and health.faultSummary or "Hardware unavailable",health
        end
        return "ONLINE",nil,health
    end
    if self.stateLink then
        local link=self.stateLink
        local age=link.lastFrameAt and math.max(0,now-link.lastFrameAt)
        local fresh=age and age<=self.config.network.sensor_stale_seconds
        local status=fresh and "ONLINE" or "DEGRADED"
        systems[#systems+1]={id=link.id,label=link.label,role="wired sensor / cockpit reader",status=status,
            ageSeconds=age,detail=fresh and "Read-only measurements" or link.phase}
        recordRole("state",link.id,status)
    end
    local displayRoles={"navigator","heading-main","heading-right","heading-left"}
    for _,role in ipairs(displayRoles) do
        local id,label
        if self.fleet then id,label=self.fleet:get(role) end
        local report=id and self.subsystemReports[id] or nil
        local age=report and finite(report.at) and math.max(0,now-report.at) or nil
        local fresh=report and age~=nil and now>=report.at and age<=self.config.network.node_stale_seconds
        local status,detail=packageState(role)
        if fresh and not report.monitorAttached and status=="ONLINE" then status="DEGRADED";detail="No attached monitor" end
        if fresh and not report.coreDataFresh and status=="ONLINE" then status="DEGRADED";detail="Core data stale" end
        recordRole(role,id,status)
        local description=role=="navigator" and "bridge touchscreen" or role:gsub("^heading%-","heading ")
        systems[#systems+1]={id=id,label=label or role,role=description,status=status,ageSeconds=age,detail=detail}
    end
    local labels={FL="chamber_fl",FR="chamber_fr",RL="chamber_bl",RR="chamber_br"}
    for _,quadrant in ipairs(QUADRANTS) do
        local node=self.nodes[quadrant]
        local fresh=self:nodeFresh(quadrant,now)
        local role=labels[quadrant]
        local status,detail,health=packageState(role)
        if fresh and node.ready~=true and status=="ONLINE" then status="DEGRADED";detail="Lift controller not ready" end
        recordRole(role,node.id,status)
        systems[#systems+1]={id=node.id,label=self.computers[role] and self.computers[role].label or role,role=quadrant.." combined chamber",
            status=status,
            ageSeconds=node.lastSeen and math.max(0,now-node.lastSeen) or nil,
            detail=detail}
    end
    if self.thrust then
        local propulsion=self.thrust:snapshot(now)
        for _,role in ipairs(Thrust.CONTROLLERS) do
            local node=propulsion.roles[role]
            local fleetRole=Fleet.CONTROLLER_ROLE[role]
            local status,detail,health=packageState(fleetRole)
            if node.discovered and not node.online and status=="ONLINE" then status="DEGRADED";detail=node.reason or "Transmission status stale" end
            recordRole(fleetRole,self.computers[fleetRole] and self.computers[fleetRole].id,status)
            systems[#systems+1]={id=node.nodeId,label=self.computers[fleetRole] and self.computers[fleetRole].label or role,role="thrust transmission controller",
                status=status,ageSeconds=health and math.max(0,now-health.at) or node.statusAgeSeconds,
                detail=detail or node.reason or node.phase}
        end
        for _,role in ipairs(Thrust.UNITS) do
            local node=propulsion.units[role]
            local fleetRole=role=="primary-left" and "primary_l" or "primary_r"
            local status,detail,health=packageState(fleetRole)
            if not node.available and status=="ONLINE" then status="DEGRADED";detail=node.reason or "No valid readings" end
            recordRole(fleetRole,self.computers[fleetRole] and self.computers[fleetRole].id,status)
            systems[#systems+1]={id=self.thrust.units[role] and self.thrust.units[role].id or nil,
                label=self.computers[fleetRole] and self.computers[fleetRole].label or role,role="primary drive telemetry",
                status=status,ageSeconds=health and math.max(0,now-health.at) or node.statusAgeSeconds,
                detail=detail or node.reason or (node.available and "Read-only data" or "No valid readings")}
        end
    end
    for _,role in ipairs(Fleet.ROLE_ORDER) do
        if role~="core" then
            local issue=roleStates[role]
            if issue=="ONLINE" then issue=nil end
            self:logState("computer "..role,issue)
        end
    end
    return systems
end

-- @ama-summary: Build the timestamped vessel, controls, role-health and lift display snapshot.
function IO:buildSnapshot(now, page)
    local clockNow=self:nowSeconds()
    -- Peripheral calls in the runtime may yield while the independent
    -- assembly sampler advances the shared clock. Timestamp the published
    -- snapshot at least as late as that latest sample.
    if finite(clockNow) and (not finite(now) or clockNow>now) then now=clockNow end
    now = now or clockNow
    self.statusSeq = math.min(self.statusSeq + 1, self.config.network.max_sequence)
    local nodes = {}
    for _, quadrant in ipairs(QUADRANTS) do
        local source = self.nodes[quadrant]
        local age = source.lastSeen and math.max(0, now - source.lastSeen) or nil
        local fresh = self:nodeFresh(quadrant, now)
        nodes[quadrant] = {
            id = source.id, quadrant = quadrant, online = fresh,
            ready = fresh and source.ready or false, armed = fresh and source.armed or false,
            operationBusy=fresh and source.operationBusy or false,
            startReady=fresh and source.startReady or false,
            faults = fresh and source.faults or { "STALE STATUS" },
            providers = fresh and source.providers or {}, balloon = fresh and source.balloon or nil,
            phase = fresh and source.phase or nil,
            altitude = fresh and source.altitude or { valid = false },
            totalGasOutput = fresh and source.totalGasOutput or nil,
            totalGasOutputValid = fresh and source.totalGasOutputValid or false,
            gasOutputUnit = "m3/tick",
            systemsSupported=fresh and source.systemsSupported or false,
            systemsStartReady=fresh and source.systemsStartReady or false,
            systemsProbeReady=fresh and source.systemsProbeReady or false,
            systemsStage=fresh and source.systemsStage or nil,
            thrustControlState=fresh and source.thrustControlState or "FAULT",
            liftControlState=fresh and source.liftControlState or "FAULT",
            emergencyDisarmAppliedSeq=fresh and source.emergencyDisarmAppliedSeq or nil,
            emergencyStopAppliedSeq=fresh and source.emergencyStopAppliedSeq or nil,
            emergencyStopMode=fresh and source.emergencyStopMode or nil,
            emergencyStopLatched=fresh and source.emergencyStopLatched or false,
            emergencyStopVerified=fresh and source.emergencyStopVerified or false,
            emergencyStopFault=fresh and source.emergencyStopFault or nil,
            lastAppliedSeq = source.lastAppliedSeq, statusAgeSeconds = age, demand = nil,
        }
        -- Kept outside the constructor: false must survive (and/or would drop it).
        if fresh then nodes[quadrant].assembled = source.assembled end
    end
    local vessel, inputs = self.vessel or {}, self.inputs or {}
    local vesselAge = finite(vessel.at) and math.max(0, now - vessel.at) or nil
    local vesselFresh = vessel.valid == true and vesselAge ~= nil and now >= vessel.at and
        vesselAge <= self.config.network.sensor_stale_seconds
    local inputAge=finite(inputs.at) and now-inputs.at or nil
    local inputsFresh=inputs.valid==true and inputAge~=nil and inputAge>=0 and
        inputAge<=math.min(self.config.network.sensor_stale_seconds,
            self.config.cockpit and (self.config.cockpit.input_stale_seconds or self.config.cockpit.maximum_input_gap_seconds) or self.config.network.sensor_stale_seconds)
    -- Lua's 'condition and value or fallback' cannot preserve a nil reason:
    -- a healthy sample legitimately has no reason. Choose explicitly instead
    -- of labelling every healthy sample stale when that nil selects fallback.
    local vesselReason=vessel.reason
    if not vesselFresh then vesselReason=vessel.valid and "SABLE SENSOR SAMPLE STALE" or vessel.reason end
    local inputReason=inputs.reason
    if not inputs.valid then inputReason=inputs.reason or "COCKPIT INPUT READ FAILED"
    elseif not inputsFresh then inputReason="COCKPIT INPUTS STALE" end
    local readers={}
    for _,name in ipairs({"vessel","cockpit","assembly","fallback","assembler"}) do
        local sample=(self.sampling or {})[name]
        if sample then
            readers[name]={phase=sample.phase,stage=sample.stage,failures=sample.failures,
                lastError=sample.lastError,lastTimeoutStage=sample.lastTimeoutStage,
                lastTimeoutPending=sample.lastTimeoutPending,duration=sample.duration}
        end
    end
    local state = {
        seq = self.statusSeq, updatedAt = now, page = page or "FLIGHT", nodes = nodes,
        readers=readers,
        fleetRegistry={schemaVersion=1,computers=Fleet.clone(self.computers or {}),
            error=self.fleet and self.fleet.error or nil},
        coreIdentity={id=self.localID,label=self.localLabel,registeredLabel=self.config.label,
            verified=self.identityReady==true,reason=self.identityReason},
        roleHealth={},
        thrust = self.thrust and self.thrust:snapshot(now) or nil,
        subsystems = self:buildSubsystems(now),
        vessel = {
            valid = vesselFresh,
            sources=vessel.sources,validFields=vessel.validFields,positionUnavailable=vessel.positionUnavailable,
            reason = vesselReason,
            sampleAgeSeconds = vesselAge,
            telemetryErrors = vesselFresh and vessel.telemetryErrors or {},
            sensors = vesselFresh and vessel.sensors or nil,
            headingSource = vesselFresh and vessel.headingSource or nil,
            altitude = vesselFresh and finite(vessel.altitude) and vessel.altitude or nil,
            altitudeSource = vesselFresh and vessel.altitudeSource or nil,
            altitudeUnit = vesselFresh and vessel.altitudeUnit or nil,
            heading = vesselFresh and finite(vessel.heading) and vessel.heading or nil,
            pitch = vesselFresh and finite(vessel.pitch) and vessel.pitch or nil,
            roll = vesselFresh and finite(vessel.roll) and vessel.roll or nil,
            verticalSpeed = vesselFresh and finite(vessel.verticalSpeed) and vessel.verticalSpeed or nil,
            forwardSpeed = vesselFresh and finite(vessel.forwardSpeed) and vessel.forwardSpeed or nil,
            mass = vesselFresh and finite(vessel.mass) and vessel.mass or nil,
            uuid = vesselFresh and vessel.uuid or nil,
            position = vesselFresh and vessel.position or nil,
            velocity = vesselFresh and vessel.linearVelocity or nil,
            angularVelocity = vesselFresh and vessel.angularVelocity or nil,
            geometryVerified = vesselFresh and vessel.geometryVerified == true,
            velocityFrameVerified = vesselFresh and vessel.velocityFrameVerified == true,
            environment = vesselFresh and vessel.environment or nil,
        },
        inputs = { valid = inputsFresh, raw = inputsFresh and inputs.raw or {},
            errors = inputs.errors or {}, at = inputs.at,sampleAgeSeconds=inputAge,
            sampleDurationSeconds=inputs.sampleDurationSeconds,
            lastReadError=self.lastInputAttempt and self.lastInputAttempt.reason,
            reason = inputReason },
        modes = { heading = "MANUAL", throttle = "MANUAL", altitude = "TGT" },
        targets = {}, anchor = "OFF", ap = "UNAVAILABLE", throttleApplied = nil, faults = {},
        identityConflict=self.identityWatch and self.identityWatch:snapshot(now) or {active=false},
    }
    self:logState("identityConflict",state.identityConflict.active and state.identityConflict.text or nil)
    for role,report in pairs(self.roleReports or {}) do
        local age=now>=report.at and now-report.at or nil
        state.roleHealth[role]={packageId=report.packageId,version=report.version,running=report.running,
            hardwareAvailable=report.hardwareAvailable,faultSummary=report.faultSummary,ageSeconds=age,
            online=age~=nil and age<=self.config.network.node_stale_seconds}
    end
    for role,issue in pairs(self.packageErrors or {}) do
        state.roleHealth[role]={online=false,error=issue,running=false,hardwareAvailable=false}
    end
    local assembled, assemblyMessage, assembly = self:assemblyGate(now)
    state.assembly = assembly
    if not assembled then state.faults[#state.faults + 1] = assemblyMessage end
    if not state.vessel.valid then state.faults[#state.faults + 1] = state.vessel.reason or "VESSEL DATA UNAVAILABLE" end
    if not state.inputs.valid then state.faults[#state.faults + 1] = "COCKPIT INPUT DATA UNAVAILABLE" end
    for _, quadrant in ipairs(QUADRANTS) do if not nodes[quadrant].online then state.faults[#state.faults + 1] = quadrant .. " LIFT STATUS STALE" end end
    for _, quadrant in ipairs(QUADRANTS) do
        if nodes[quadrant].online then
            for _, fault in ipairs(nodes[quadrant].faults or {}) do
                state.faults[#state.faults + 1] = quadrant .. ": " .. fault
            end
        end
    end
    return state
end

-- @ama-summary: Publish cached display data to navigator and heading receivers.
function IO:broadcastDisplayStatus(state)
    -- The bridge needs chamber detail. Heading displays receive only the
    -- fields their renderer consumes, avoiding three extra provider-table copies.
    local allowed,identityReason=self:routeAllowed()
    if not allowed then return false,identityReason end
    if not self.rednet or type(self.rednet.send) ~= "function" then return false, "rednet send unavailable" end
    local packet = { v = 1, kind = "display_status", session = self.session, seq = state.seq, state = state }
    local destinations,seen={},{}
    local headingPacket
    local candidates={self.config.bridge_id,self.config.display_ids and self.config.display_ids.center,
        self.config.display_ids and self.config.display_ids.right,self.config.display_ids and self.config.display_ids.left}
    for index=1,4 do
        local id=candidates[index]
        if integer(id,0,65535) and id~=self.localID and not seen[id] then
            seen[id]=true;destinations[#destinations+1]={id=id,full=index==1}
        end
    end
    local failures={}
    for _,destination in ipairs(destinations) do
        local outgoing=packet
        if not destination.full then
            headingPacket=headingPacket or {v=1,kind="display_status",session=self.session,seq=state.seq,
                state=require("avionics.display_payload").heading(state)}
            outgoing=headingPacket
        end
        local ok,reason=pcall(self.rednet.send,destination.id,outgoing,self.config.protocol)
        if not ok or reason==false then failures[#failures+1]="#"..destination.id..": "..text(reason) end
    end
    if #failures>0 then return false,"display status send failed: "..table.concat(failures,"; ") end
    return true
end

IO.QUADRANTS = QUADRANTS
IO.INPUT_ORDER = INPUT_ORDER
IO.finite = finite
IO.isInteger = integer

return IO
