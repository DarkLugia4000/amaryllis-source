local Mathx = require("avionics.mathx")
local Registry = require("avionics.config_registry")
-- Section: Propulsion authority | Drive discovery, feedback, interlocks and command delivery.
-- Dynamic propulsion discovery, telemetry, and explicitly bounded commands.
local Thrust = {}
local CONTROLLERS = {"thrust-lb", "thrust-rb", "thrust-ls", "thrust-rs"}
local UNITS = {"primary-left", "primary-right"}
local DRIVES = {"primary-left", "primary-right", "lateral-lb-p", "lateral-lb-s",
    "lateral-rb-p", "lateral-rb-s", "lateral-ls-p", "lateral-ls-s", "lateral-rs-p", "lateral-rs-s"}
local CONTROLLER_DRIVES = {
    ["thrust-lb"]={"lateral-lb-p","lateral-lb-s"},
    ["thrust-rb"]={"lateral-rb-p","lateral-rb-s"},
    ["thrust-ls"]={"primary-left","lateral-ls-p","lateral-ls-s"},
    ["thrust-rs"]={"primary-right","lateral-rs-p","lateral-rs-s"},
}
local UNIT_CONTROLLER = {
    ["primary-left"]="thrust-ls", ["primary-right"]="thrust-rs",
}
local DRIVE_CONTROLLER = {
    ["primary-left"]="thrust-ls", ["primary-right"]="thrust-rs",
    ["lateral-lb-p"]="thrust-lb", ["lateral-lb-s"]="thrust-lb",
    ["lateral-rb-p"]="thrust-rb", ["lateral-rb-s"]="thrust-rb",
    ["lateral-ls-p"]="thrust-ls", ["lateral-ls-s"]="thrust-ls",
    ["lateral-rs-p"]="thrust-rs", ["lateral-rs-s"]="thrust-rs",
}
local ACCELERATION_MEASUREMENT_NOTE="Derived from signed speed at the sensor point; vessel rotation can affect it."
local ROLE_KIND = {}
for _,role in ipairs(CONTROLLERS) do ROLE_KIND[role]="controller" end
for _,role in ipairs(UNITS) do ROLE_KIND[role]="sensor" end

local finite = Mathx.finite
local function measurementAt(v,field)
    local entry=(((v.sources or {}).fields or {})[field] or {})
    return finite(entry.at) and entry.at or v.at
end
local function integer(v,lo,hi) return finite(v) and v%1==0 and v>=lo and v<=hi end
local function bounded(v,n) return type(v)=="string" and #v>0 and #v<=n end
local clamp = Mathx.clamp
local function clean(v,n) return tostring(v or ""):gsub("[%c]"," "):sub(1,n or 160) end
-- Section: Endpoint context | Configuration, discovery and command identity.
-- Summary: Write a bounded event to the core log with its operation scope.
local function emitCoreLog(message,key)
    local logger=type(os)=="table" and os.__amaryllisLog or nil
    if type(logger)=="function" then
        local ok,recorded=pcall(logger,message,key)
        if ok and recorded==true then return true end
    end
    print(message)
    return false
end
-- Summary: Record a changed propulsion issue and its associated controller context.
local function logPropulsionIssue(self,reason)
    reason=clean(reason,160)
    if reason=="" then return false end
    self.coreLogIssues=self.coreLogIssues or {}
    if self.coreLogIssues.propulsion==reason then return false end
    self.coreLogIssues.propulsion=reason
    return emitCoreLog("Core propulsion stopped: "..reason,"core.thrust.propulsion:"..reason)
end
-- Summary: Clear the recorded propulsion issue and publish its recovery log entry.
local function clearPropulsionIssue(self,message)
    if not self.coreLogIssues or not self.coreLogIssues.propulsion then return false end
    self.coreLogIssues.propulsion=nil
    return emitCoreLog(message or "Core propulsion recovered","core.thrust.propulsion:recovered")
end
local RAW_ABS_LIMIT=1000000000000 -- Wire-format guard only; raw readings have no assigned physical units.
-- Summary: Validate the shape and bounded length of an indexed array.
local function arrayLength(value,maximum)
    if type(value)~="table" then return nil end
    local count=0
    for key in pairs(value) do
        if not integer(key,1,maximum) then return nil end
        count=count+1
        if count>maximum then return nil end
    end
    for i=1,count do if value[i]==nil then return nil end end
    return count
end
-- Summary: Normalize a received fault list into bounded text entries.
local function faultList(value)
    if value==nil then return {} end
    local count=arrayLength(value,16)
    if count==nil then return nil end
    local out={}
    for i=1,count do
        if not bounded(value[i],128) then return nil end
        out[i]=clean(value[i],128)
    end
    return out
end
local function inList(list,value)
    for _,item in ipairs(list or {}) do if item==value then return true end end
    return false
end
local function copy(value)
    if type(value)~="table" then return value end
    local out={}; for k,v in pairs(value) do out[k]=copy(v) end; return out
end
local DEFAULT_SPEED_GAINS={kp=0.02,ki=0.02,kd=0.005,integral_limit=40,derivative_filter_seconds=1}
-- Section: Drive demand | Bounded feedback and maneuver mixing.
-- Summary: Read and validate the configured selected-speed PID gains.
local function configuredSpeedGains(config)
    local c=config and config.thrust or {}
    local source=type(c.speed_pid)=="table" and "CONFIGURED" or "DEFAULTS"
    local gains=type(c.speed_pid)=="table" and c.speed_pid or DEFAULT_SPEED_GAINS
    return {kp=gains.kp,ki=gains.ki,kd=gains.kd,integralLimit=gains.integral_limit,
        derivativeFilterSeconds=gains.derivative_filter_seconds,source=source,
        verified=c.speed_control_verified==true}
end
local function roleAllowed(role,drive)
    return inList(CONTROLLER_DRIVES[role],drive)
end
local function endpoint(role)
    return role and ROLE_KIND[role]
end
local function validBoot(value)
    return bounded(value,128) and value:match("^[%w_%.%-:]+$")~=nil
end

-- Section: Endpoint context | Configuration, discovery and command identity.
-- Summary: Check drive names and bounds against the configured controller inventory.
local function validateDrives(role, drives)
    if drives==nil then return {} end
    local count=arrayLength(drives,10)
    if count==nil then return nil end
    local seen,out={},{}
    for i=1,count do
        local drive=drives[i]
        if not bounded(drive,48) or not roleAllowed(role,drive) or seen[drive] then return nil end
        seen[drive]=true; out[#out+1]=drive
    end
    return out
end

-- Section: Readbacks | Timestamped physical observations and status.
-- Summary: Validate received propulsion readings and retain their field-validity flags.
local function normalizeReadings(readings)
    local count=arrayLength(readings,32)
    if count==nil then return nil end
    local out,names={},{}
    for i=1,count do
        local source=readings[i]
        if type(source)~="table" or not bounded(source.name,128) or names[source.name] then return nil end
        names[source.name]=true
        local validity=type(source.validity)=="table" and source.validity or {}
        local item={name=clean(source.name,128),validity={}}
        for _,key in ipairs({"speedRaw","thrustRaw"}) do
            local isValid=validity[key]
            if isValid~=nil and type(isValid)~="boolean" then return nil end
            item.validity[key]=isValid==true
            if isValid==true and finite(source[key]) and math.abs(source[key])<=RAW_ABS_LIMIT then item[key]=source[key]
            elseif isValid==true then return nil
            elseif source[key]~=nil and (not finite(source[key]) or math.abs(source[key])>RAW_ABS_LIMIT) then return nil end
        end
        local handednessValid=validity.thrustHandedness
        if handednessValid~=nil and type(handednessValid)~="boolean" then return nil end
        item.validity.thrustHandedness=handednessValid==true
        if handednessValid==true then
            if source.thrustHandedness~="left_handed" and source.thrustHandedness~="right_handed" then return nil end
            item.thrustHandedness=source.thrustHandedness
        elseif source.thrustHandedness~=nil and source.thrustHandedness~="left_handed" and
            source.thrustHandedness~="right_handed" then return nil end
        local vector=source.thrustVector
        local vectorValid=validity.thrustVector
        if vectorValid~=nil and type(vectorValid)~="boolean" then return nil end
        item.validity.thrustVector=vectorValid==true
        if vectorValid==true then
            if type(vector)~="table" then return nil end
            local named=vector.x~=nil or vector.y~=nil or vector.z~=nil
            local positional=vector[1]~=nil or vector[2]~=nil or vector[3]~=nil
            if named==positional then return nil end
            local x,y,z
            if named then x,y,z=vector.x,vector.y,vector.z
            else x,y,z=vector[1],vector[2],vector[3] end
            if not finite(x) or not finite(y) or not finite(z) or
                math.abs(x)>RAW_ABS_LIMIT or math.abs(y)>RAW_ABS_LIMIT or math.abs(z)>RAW_ABS_LIMIT then return nil end
            item.thrustVector={x=x,y=y,z=z}
        end
        local assembled=source.assembled
        local assembledValid=validity.assembled
        if assembledValid~=nil and type(assembledValid)~="boolean" then return nil end
        item.validity.assembled=assembledValid==true
        if assembledValid==true then
            if type(assembled)~="boolean" then return nil end
            item.assembled=assembled
        end
        out[#out+1]=item
    end
    return out
end

-- Section: Endpoint context | Configuration, discovery and command identity.
-- Summary: Validate the normalized per-drive demand map.
local function normalizedMap(role, drives, value)
    if type(value)~="table" then return {} end
    local out,count={},0
    for drive,n in pairs(value) do
        count=count+1
        if count>3 then return nil end
        if not inList(drives,drive) or not finite(n) or
            (drive:match("^primary%-") and (n< -1 or n>1)) or
            (drive:match("^lateral%-") and (n<0 or n>1)) then return nil end
        out[drive]=n
    end
    return out
end

-- Section: Readbacks | Timestamped physical observations and status.
-- Summary: Validate the reported drive readback map and its observation values.
local function readbackMap(drives,value)
    if type(value)~="table" then return {} end
    local out,count={},0
    for drive,item in pairs(value) do
        count=count+1
        if count>3 then return nil end
        if not inList(drives,drive) or type(item)~="table" then return nil end
        if item.valid==true then
            if not integer(item.shiftLevel,0,256) then return nil end
            out[drive]={shiftLevel=item.shiftLevel,valid=true}
        elseif item.valid==false then out[drive]={valid=false}
        else return nil end
    end
    return out
end

local function appendRetired(node,boot)
    node.retired=node.retired or {}; node.retiredOrder=node.retiredOrder or {}
    if boot then
        node.retired[boot]=true; node.retiredOrder[#node.retiredOrder+1]=boot
        if #node.retiredOrder>32 then node.retired[table.remove(node.retiredOrder,1)]=nil end
    end
end

-- Section: Endpoint context | Configuration, discovery and command identity.
-- Summary: Construct core propulsion routing, controller caches and feedback-loop state.
function Thrust.new(config)
    if config.thrust and finite(config.thrust.primary_max_rpm) then
        config.thrust.direct_max_request=config.thrust.primary_max_rpm/256
    end
    return setmetatable({config=config,controllers={},units={},bySender={},nextRoleSeq=0,
        mode="MANUAL",request={},requested={},reason="THRUST ENDPOINTS NOT DISCOVERED",
        active=false,saturated=false,lastCommandAt=nil,reversal={},lastSpeedAt=nil,
        lastThrottleMode="MANUAL",speedLoop={integral=0,derivative=0},
        speedControl={state="DISABLED",controlStatus="UNAVAILABLE",available=false,
            reason="THROTTLE MODE NOT SEL",saturated=false},
        lastHeadingMode="MANUAL",headingLoop={integral=0,rateDerivative=0},
        headingControl={state="DISABLED",available=false,mode="MANUAL",reason="HEADING CONTROL IDLE",saturated=false},
        accelerationLoop={integral={left=0,right=0},derivative={left=0,right=0}},
        manualAcceleration={state="DISABLED",available=false,reason="THROTTLE MODE NOT MANUAL",
            measurementNote=ACCELERATION_MEASUREMENT_NOTE,
            saturated=false}},
        {__index=Thrust})
end

-- Summary: Update propulsion role routing from the accepted fleet registry.
function Thrust:setRegistry(roleIDs, io)
    self.roleIDs = type(roleIDs)=="table" and copy(roleIDs) or {}
    for _, role in ipairs(CONTROLLERS) do
        local node=self.controllers[role]
        local id=self.roleIDs[role]
        if node and node.id~=id then
            if io and next(node.requested or {}) then self:sendStopTo(io,node,"FLEET ROLE ID CHANGED") end
            if node.id then self.bySender[node.id]=nil end
            node.retired=node.retired or {}; node.retiredOrder=node.retiredOrder or {}
            appendRetired(node,node.boot)
            node.id,node.boot,node.status,node.statusAt,node.statusSeq=id,nil,nil,nil,nil
            node.statusReason="REGISTRY CHANGED"; node.requested={}; node.lastIssuedSeq=0
        end
    end
    for _, role in ipairs(UNITS) do
        local node=self.units[role]
        local id=self.roleIDs[role]
        if node and node.id~=id then
            if node.id then self.bySender[node.id]=nil end
            node.retired=node.retired or {}; node.retiredOrder=node.retiredOrder or {}
            appendRetired(node,node.boot)
            node.id,node.boot,node.status,node.statusAt,node.statusSeq=id,nil,nil,nil,nil
            node.statusReason="REGISTRY CHANGED"
        end
    end
end

function Thrust:staleSeconds()
    local network=self.config.network or {}
    local value=self.config.thrust and self.config.thrust.status_stale_seconds
    return finite(value) and value or network.node_stale_seconds or 3
end

function Thrust:fresh(node,now)
    return node and finite(node.statusAt) and finite(now) and now>=node.statusAt and
        now-node.statusAt<=self:staleSeconds()
end

-- Stale propulsion data is named with its age once it has been stale for
-- more than STALE_NOTICE_SECONDS; shorter gaps read as WAITING FOR <subject>.
Thrust.STALE_NOTICE_SECONDS=10
-- Summary: Word stale propulsion data as WAITING FOR <subject> up to 10 s, then as <subject> <what> STALE with its age.
function Thrust.staleText(subject,what,age)
    if not finite(age) then return subject.." "..what.." UNAVAILABLE" end
    if age<=Thrust.STALE_NOTICE_SECONDS then return "WAITING FOR "..subject.." "..what end
    return string.format("%s %s STALE %.0f S",subject,what,age)
end

function Thrust:sendSession(io,sender,node)
    if not io.rednet or type(io.rednet.send)~="function" then return false,"rednet send unavailable" end
    local packet={v=1,kind="thrust_session",session=io.session,role=node.role,nodeBoot=node.boot}
    local ok,sent=pcall(io.rednet.send,sender,packet,self.config.protocol)
    if not ok or sent==false then return false,"thrust session reply failed" end
    return true
end

-- Section: Output operations | Verified targets applied under current authority.
-- Summary: Send the selected propulsion endpoint its current-session stop command.
function Thrust:sendStopTo(io,node,reason)
    if not node or not node.id or not validBoot(node.boot) or not io.rednet or
        type(io.rednet.send)~="function" then return false end
    if io.identityReady==false then return false end
    local seq=(node.lastIssuedSeq or 0)+1
    local maxSeq=(self.config.network or {}).max_sequence or 2147483647
    if not integer(seq,1,maxSeq) then return false end
    node.lastIssuedSeq=seq
    local packet={v=1,kind="thrust_stop",session=io.session,seq=seq,nodeBoot=node.boot,role=node.role,
        reason=clean(reason or "PROPULSION STOP",160)}
    local ok,sent=pcall(io.rednet.send,node.id,packet,self.config.protocol)
    if ok and sent~=false then node.requested={}; node.lastCommandAt=io:nowSeconds(); return true end
    return false
end

-- Section: Endpoint context | Configuration, discovery and command identity.
-- Summary: Record why a propulsion hello or status was refused, for the role page and the core log.
function Thrust:rejected(io,kind,role,sender,reason)
    local key=bounded(role,32) and role or ("#"..tostring(sender))
    self.rejections=self.rejections or {}
    local entry=self.rejections[key] or {count=0}
    entry.count=math.min(2147483647,entry.count+1)
    entry.kind,entry.sender,entry.reason=kind,sender,clean(reason,120)
    entry.at=io and type(io.nowSeconds)=="function" and io:nowSeconds() or nil
    self.rejections[key]=entry
    if io and type(io.logState)=="function" then
        io:logState("propulsion "..kind.." "..key,clean(reason,120).." (from #"..tostring(sender)..")")
    end
    return false,entry.reason
end

-- Summary: Clear the logged refusal once the same role's message is accepted again.
function Thrust:accepted(io,kind,role)
    if io and type(io.logState)=="function" and bounded(role,32) then io:logState("propulsion "..kind.." "..role,nil) end
end

-- Summary: Validate a propulsion endpoint's Hello and bind its current boot.
function Thrust:acceptHello(io,sender,message,now)
    local role=message.role; local kind=endpoint(role)
    if not integer(sender,0,65535) or not kind or message.v~=1 then
        return self:rejected(io,"hello",role,sender,not kind and "UNKNOWN ROLE" or "INVALID HELLO")
    end
    if message.endpointKind~=kind then return self:rejected(io,"hello",role,sender,"ENDPOINT KIND "..clean(message.endpointKind,16).." NOT "..kind) end
    if not validBoot(message.nodeBoot) or not finite(now) then return self:rejected(io,"hello",role,sender,"INVALID NODE BOOT") end
    if self.roleIDs and self.roleIDs[role]~=sender then
        return self:rejected(io,"hello",role,sender,"SENDER #"..tostring(sender).." IS NOT FLEET ID #"..tostring(self.roleIDs[role]))
    end
    local drives={}
    if kind=="controller" then
        drives=validateDrives(role,message.drives)
        if not drives then return self:rejected(io,"hello",role,sender,"INVALID DRIVE LIST") end
    elseif message.drives~=nil and type(message.drives)~="table" then return self:rejected(io,"hello",role,sender,"INVALID DRIVE LIST") end
    local registry=kind=="controller" and self.controllers or self.units
    -- Radio sender IDs are dynamic routing addresses, not authenticated identities.
    local node=registry[role]
    local owner=self.bySender[sender]
    if owner and owner~=role then return self:rejected(io,"hello",role,sender,"SENDER ALREADY BOUND TO "..clean(owner,32)) end
    if node and node.id~=sender then
        if now-node.lastSeen<=self:staleSeconds() then
            node.quarantined=true; node.quarantineAt=now
            node.status,node.statusAt,node.statusSeq=nil,nil,nil
            node.statusReason="DUPLICATE ROLE CLAIM"
            if kind=="controller" then
                if next(node.requested or {}) then self:sendStopTo(io,node,"DUPLICATE ROLE") end
                node.requested={}
            end
            return self:rejected(io,"hello",role,sender,"DUPLICATE ROLE CLAIM")
        end
        if kind=="controller" and next(node.requested or {}) then self:sendStopTo(io,node,"ROLE REPLACED") end
        self.bySender[node.id]=nil
        node=nil
    end
    if node and node.quarantined then
        if not finite(node.quarantineAt) or now-node.quarantineAt<=self:staleSeconds() then
            return self:rejected(io,"hello",role,sender,"ROLE QUARANTINED")
        end
        node.quarantined=false; node.quarantineAt=nil
    end
    if node and node.retired and node.retired[message.nodeBoot] and message.nodeBoot~=node.boot then
        return self:rejected(io,"hello",role,sender,"RETIRED NODE BOOT")
    end
    if node and node.boot~=message.nodeBoot then
        appendRetired(node,node.boot)
        node.status,node.statusAt,node.statusSeq=nil,nil,nil
        node.statusReason="NODE REBOOTED"
        node.lastIssuedSeq=0; node.requested={}
    end
    if not node then
        node={role=role,kind=kind,id=sender,retired={},lastIssuedSeq=0,requested={}}
        registry[role]=node
    end
    node.id,node.role,node.kind,node.boot,node.lastSeen=sender,role,kind,message.nodeBoot,now
    if kind=="controller" then node.drives=drives end
    self.bySender[sender]=role
    local ok,reason=self:sendSession(io,sender,node)
    if not ok then node.statusReason=reason end
    self:accepted(io,"hello",role)
    return true
end

-- Section: Readbacks | Timestamped physical observations and status.
-- Summary: Validate and cache a propulsion endpoint's status and readbacks.
function Thrust:acceptStatus(io,sender,message,now)
    local role=type(message)=="table" and message.role or nil; local kind=endpoint(role)
    if not integer(sender,0,65535) or type(message)~="table" or message.v~=1 or not finite(now) then
        return self:rejected(io,"status",role,sender,"INVALID STATUS")
    end
    if message.session~=io.session then return self:rejected(io,"status",role,sender,"STALE CORE SESSION") end
    local registry=kind=="controller" and self.controllers or (kind=="sensor" and self.units or nil)
    local node=registry and registry[role]
    if not node then return self:rejected(io,"status",role,sender,"NO ACCEPTED HELLO FOR THIS ROLE") end
    if node.id~=sender then return self:rejected(io,"status",role,sender,"SENDER #"..tostring(sender).." IS NOT BOUND NODE #"..tostring(node.id)) end
    if message.endpointKind~=kind then return self:rejected(io,"status",role,sender,"ENDPOINT KIND MISMATCH") end
    if message.nodeBoot~=node.boot then return self:rejected(io,"status",role,sender,"NODE BOOT DOES NOT MATCH ITS HELLO") end
    if not integer(message.seq,1,(self.config.network or {}).max_sequence or 2147483647) then
        return self:rejected(io,"status",role,sender,"INVALID SEQUENCE")
    end
    if node.quarantined then return self:rejected(io,"status",role,sender,"ROLE QUARANTINED") end
    if node.statusSeq and message.seq<=node.statusSeq then return self:rejected(io,"status",role,sender,"OLD SEQUENCE") end
    if node.retired and node.retired[message.nodeBoot] then return self:rejected(io,"status",role,sender,"RETIRED NODE BOOT") end
    -- Endpoint's own CC:Sable assembly check; nil means it could not tell.
    if message.assembled~=nil and type(message.assembled)~="boolean" then return self:rejected(io,"status",role,sender,"INVALID ASSEMBLY FLAG") end
    if kind=="sensor" then
        if type(message.available)~="boolean" then return self:rejected(io,"status",role,sender,"INVALID AVAILABLE FLAG") end
        local readings=normalizeReadings(message.readings or {})
        local faults=faultList(message.faults)
        if not readings then return self:rejected(io,"status",role,sender,"READINGS FAILED VALIDATION") end
        if not faults then return self:rejected(io,"status",role,sender,"FAULT LIST FAILED VALIDATION") end
        node.status={available=message.available,reason=bounded(message.reason,160) and clean(message.reason) or nil,
            faults=faults,readings=readings,seq=message.seq,assembled=message.assembled}
    else
        for _,key in ipairs({"ready","enabled","configValid","bindingReady","writerEnabled"}) do
            if type(message[key])~="boolean" then return self:rejected(io,"status",role,sender,"CONTROLLER STATUS FAILED VALIDATION") end
        end
        local controlState=message.thrustControlState
        if controlState~=nil and controlState~="CMD" and controlState~="RDY" and controlState~="FAULT" then return self:rejected(io,"status",role,sender,"CONTROLLER STATUS FAILED VALIDATION") end
        local requested=normalizedMap(role,node.drives,message.requestedTargets or {})
        local applied=normalizedMap(role,node.drives,message.applied or {})
        local readbacks=readbackMap(node.drives,message.readbacks or {})
        local faults=faultList(message.faults)
        if not requested or not applied or not readbacks or not faults then return self:rejected(io,"status",role,sender,"CONTROLLER STATUS FAILED VALIDATION") end
        local maxSeq=(self.config.network or {}).max_sequence or 2147483647
        for _,key in ipairs({"lastReceivedSeq","lastAppliedSeq","ackSeq"}) do
            local value=message[key]
            if value~=nil and (not integer(value,-1,maxSeq) or value>(node.lastIssuedSeq or 0)) then return self:rejected(io,"status",role,sender,"CONTROLLER STATUS FAILED VALIDATION") end
        end
        if message.ackAccepted~=nil and type(message.ackAccepted)~="boolean" then return self:rejected(io,"status",role,sender,"CONTROLLER STATUS FAILED VALIDATION") end
        if message.saturated~=nil and type(message.saturated)~="boolean" then return self:rejected(io,"status",role,sender,"CONTROLLER STATUS FAILED VALIDATION") end
        if message.readbackAgeSeconds~=nil and (not finite(message.readbackAgeSeconds) or
            message.readbackAgeSeconds<0 or message.readbackAgeSeconds>3600) then return self:rejected(io,"status",role,sender,"CONTROLLER STATUS FAILED VALIDATION") end
        if message.leaseRemainingSeconds~=nil and (not finite(message.leaseRemainingSeconds) or
            message.leaseRemainingSeconds<0 or message.leaseRemainingSeconds>3600) then return self:rejected(io,"status",role,sender,"CONTROLLER STATUS FAILED VALIDATION") end
        if message.directionVerified~=nil and type(message.directionVerified)~="boolean" then return self:rejected(io,"status",role,sender,"CONTROLLER STATUS FAILED VALIDATION") end
        if message.directionPhase~=nil and not bounded(message.directionPhase,32) then return self:rejected(io,"status",role,sender,"CONTROLLER STATUS FAILED VALIDATION") end
        if message.directionSignal~=nil and not integer(message.directionSignal,0,15) then return self:rejected(io,"status",role,sender,"CONTROLLER STATUS FAILED VALIDATION") end
        if message.direction~=nil and message.direction~="forward" and message.direction~="reverse" and
            message.direction~="unknown" then return self:rejected(io,"status",role,sender,"CONTROLLER STATUS FAILED VALIDATION") end
        node.status={thrustControlState=controlState,ready=message.ready,enabled=message.enabled,configValid=message.configValid,
            bindingReady=message.bindingReady,writerEnabled=message.writerEnabled,
            phase=bounded(message.phase,64) and clean(message.phase,64) or nil,
            reason=bounded(message.reason,160) and clean(message.reason) or nil,
            faults=faults,
            requested=requested,applied=applied,readbacks=readbacks,
            lastReceivedSeq=message.lastReceivedSeq,lastAppliedSeq=message.lastAppliedSeq,
            ackSeq=message.ackSeq,ackAccepted=message.ackAccepted,saturated=message.saturated,
            leaseRemainingSeconds=message.leaseRemainingSeconds,
            direction=message.direction,directionVerified=message.directionVerified,
            directionPhase=message.directionPhase,directionSignal=message.directionSignal,
            readbackAgeSeconds=message.readbackAgeSeconds,seq=message.seq,assembled=message.assembled}
    end
    node.statusSeq,node.statusAt,node.lastSeen=message.seq,now,now
    node.statusReason=nil
    self:accepted(io,"status",role)
    return true
end

function Thrust:processMessage(io,sender,message,protocol,now)
    if protocol~=self.config.protocol or type(message)~="table" then return false end
    now=now or io:nowSeconds()
    if message.kind=="thrust_hello" then return self:acceptHello(io,sender,message,now) end
    if message.kind=="thrust_status" then return self:acceptStatus(io,sender,message,now) end
    return false
end

-- Section: Endpoint context | Configuration, discovery and command identity.
-- Summary: Validate the configured direct-drive mapping and operating limits.
local function directConfigReason(config)
    local c=config.thrust
    if type(c)~="table" or c.enabled~=true then return "PROPULSION DISABLED IN CONFIG" end
    if c.limits_verified~=true then return "PROPULSION LIMITS UNVERIFIED" end
    if c.mapping_verified~=true then return "PROPULSION MAPPING UNVERIFIED" end
    if not finite(c.command_ttl_seconds) or c.command_ttl_seconds<=0 or c.command_ttl_seconds>3 then
        return "PROPULSION LEASE LIMIT UNSET"
    end
    -- This is a fraction of the controller's configured range, not a shaft
    -- speed ratio. RPM limits cannot determine the controller's maxLevel.
    if not finite(c.direct_max_request) or c.direct_max_request<=0 or c.direct_max_request>1 then
        return "DIRECT MAXIMUM DRIVE REQUEST UNSET"
    end
end

-- Section: Readbacks | Timestamped physical observations and status.
-- Summary: Evaluate controller identity, status freshness and write readiness.
function Thrust:controllerReady(role,now)
    local node=self.controllers[role]
    local s=node and node.status
    if node and node.quarantined then return false,"DUPLICATE ROLE QUARANTINED" end
    if not node or not s then return false,"NO CONTROLLER STATUS" end
    if not self:fresh(node,now) then
        local age=finite(node.statusAt) and finite(now) and now>=node.statusAt and now-node.statusAt or nil
        return false,Thrust.staleText(string.upper(role),"STATUS",age)
    end
    if s.ready~=true then return false,s.reason or "CONTROLLER NOT READY" end
    if s.enabled~=true or s.writerEnabled~=true then return false,s.reason or "CONTROLLER DISABLED" end
    if s.configValid~=true or s.bindingReady~=true then return false,s.reason or "CONTROLLER BINDING UNVERIFIED" end
    -- ACK disagreement is repaired by the next absolute command. Physical
    -- readiness below remains mandatory; a rejected old ACK is not a lock.
    local readbackAge=finite(s.readbackAgeSeconds) and now>=node.statusAt and
        s.readbackAgeSeconds+(now-node.statusAt) or nil
    if not finite(readbackAge) or readbackAge>self:staleSeconds() then
        return false,Thrust.staleText(string.upper(role),"READBACK",readbackAge)
    end
    for _,drive in ipairs(CONTROLLER_DRIVES[role]) do
        if not inList(node.drives,drive) then return false,"DRIVE NOT MAPPED: "..drive end
        local readback=s.readbacks and s.readbacks[drive]
        if not readback or readback.valid~=true then return false,"CONTROLLER DRIVE READBACK INVALID: "..drive end
    end
    return true
end

-- Section: Endpoint context | Configuration, discovery and command identity.
-- Summary: Retry pending propulsion commands and reconcile endpoint acknowledgements.
function Thrust:updateCommandRecovery(node,now)
    if not node then return end
    if (node.lastIssuedSeq or 0)<=0 or not next(node.requested or {}) then
        node.commandRecovery=nil;node.commandHistory=nil;node.lastVerifiedSeq=nil;return
    end
    local status=node.status
    local issued=status and node.commandHistory and node.commandHistory[status.ackSeq]
    local verified=issued and status.ackAccepted==true and self:fresh(node,now)
    if verified then
        for drive,value in pairs(issued) do
            if not status.requested or status.requested[drive]~=value then verified=false;break end
        end
    end
    if verified and (status.ackSeq==node.lastIssuedSeq or status.ackSeq~=(node.lastVerifiedSeq or -1)) then
        node.lastVerifiedSeq=status.ackSeq
        if node.commandRecovery and (now-node.commandRecovery.since>=3) then
            emitCoreLog("Core propulsion "..node.role.." recovered; authoritative command confirmed",
                "core.thrust.reslave."..node.role)
        end
        node.commandRecovery=nil
        return
    end
    local recovery=node.commandRecovery or {since=now,attempts=0}
    node.commandRecovery=recovery
    recovery.reason="REAPPLYING CORE PROPULSION TARGETS; RETRYING ("..(recovery.attempts or 0)..")"
    local acknowledgementWindow=self.config.thrust.command_ttl_seconds or 1
    if now-recovery.since>=acknowledgementWindow and not recovery.loggedRetry then
        recovery.loggedRetry=true
        emitCoreLog("Core propulsion "..node.role..": "..recovery.reason,
            "core.thrust.reslave."..node.role)
    end
end

local function zeroTargets()
    local targets={}
    for _,drive in ipairs(DRIVES) do targets[drive]=0 end
    return targets
end

local LATERAL_QUADS={"lb","rb","ls","rs"}
local YAW_SIGN={lb=1,rb=1,ls=-1,rs=-1}
-- Section: Drive demand | Front and back strafe balance.
-- The combined line of action of the lateral thrusters can sit ahead of or behind the
-- center of mass, which yaws the vessel during a strafe. This setting scales the
-- sideways gain of the front pair (lb, rb) against the back pair (ls, rs). At 100
-- percent both pairs share the request equally. Below 100 the front pair is reduced;
-- above 100 the back pair is reduced, keeping every gain within the verified 0 to 1 range.
-- Yaw gains stay as configured.
-- Summary: Return a mixer copy with the front pair side gains balanced against the back pair.
function Thrust.balanceStrafe(mixer,percent)
    if type(mixer)~="table" or not finite(percent) or percent<=0 then return mixer end
    local ratio=percent/100
    local frontScale=math.min(1,ratio)
    local backScale=math.min(1,1/ratio)
    local balanced={}
    for _,quad in ipairs(LATERAL_QUADS) do
        local entry=mixer[quad]
        if type(entry)=="table" then
            local scaled={}
            for key,value in pairs(entry) do scaled[key]=value end
            if finite(scaled.side_gain) then
                scaled.side_gain=scaled.side_gain*((quad=="lb" or quad=="rb") and frontScale or backScale)
            end
            balanced[quad]=scaled
        else
            balanced[quad]=entry
        end
    end
    return balanced
end

-- Section: Drive demand | Bounded feedback and maneuver mixing.
-- Summary: Mix yaw and sideways demand into the configured lateral drive targets.
function Thrust.mixLateral(sideDemand,yawDemand,mixer)
    if not finite(sideDemand) or not finite(yawDemand) or math.abs(sideDemand)>1 or math.abs(yawDemand)>1 then
        return nil,"LATERAL DEMAND OUT OF BOUNDS"
    end
    local outputs,saturated={},false
    for _,quad in ipairs(LATERAL_QUADS) do
        outputs["lateral-"..quad.."-p"]=0
        outputs["lateral-"..quad.."-s"]=0
    end
    if math.abs(sideDemand)<0.000001 and math.abs(yawDemand)<0.000001 then return outputs,false end
    if type(mixer)~="table" then return nil,"LATERAL MIXER UNCOMMISSIONED" end
    for _,quad in ipairs(LATERAL_QUADS) do
        local c=mixer[quad]
        if type(c)~="table" or not finite(c.side_gain) or c.side_gain<0 or c.side_gain>1 or
            (c.side_sign~=1 and c.side_sign~=-1) or not finite(c.yaw_gain) or c.yaw_gain<0 or c.yaw_gain>1 or
            c.yaw_sign~=YAW_SIGN[quad] then return nil,"LATERAL MIXER CONFIG INVALID: "..quad end
        -- Positive demand remains a right turn in the cockpit and heading PID.
        -- The confirmed engine response is inverted from the original layout:
        -- right turns use front right blobs and rear left blobs. Invert yaw
        -- at the actuator mixer only, leaving sideways demand unchanged.
        local signed=c.side_gain*c.side_sign*sideDemand-c.yaw_gain*YAW_SIGN[quad]*yawDemand
        if math.abs(signed)>1 then saturated=true end
        signed=clamp(signed,-1,1)
        if signed>0 then outputs["lateral-"..quad.."-p"]=signed
        elseif signed<0 then outputs["lateral-"..quad.."-s"]=-signed end
    end
    return outputs,saturated
end

-- Summary: Clear speed-loop integral and derivative history for the next transfer.
function Thrust:resetSpeedLoop()
    self.speedLoop={integral=0,derivative=0}
end

-- Summary: Reset speed feedback and publish the unavailable measurement or target reason.
function Thrust:setSpeedUnavailable(reason,target,measured)
    self:resetSpeedLoop()
    self.speedControl={state="UNAVAILABLE",controlStatus="UNAVAILABLE",available=false,
        reason=clean(reason or "SPEED CONTROL UNAVAILABLE",160),targetSpeed=finite(target) and target or nil,
        measuredSpeed=finite(measured) and measured or nil,
        error=finite(target) and finite(measured) and target-measured or nil,output=nil,saturated=false}
end

local function controlStatusFor(target,error,output)
    if target==0 then return error and math.abs(error)>.02 and "BRAKING" or "HOLDING" end
    if error and error~=0 and output==0 then return "OVERSPEED_COAST" end
    if output and math.abs(output)>0 then return error and output*error>0 and "ACCELERATING" or "HOLDING" end
    return "COASTING"
end

-- Summary: Resolve the currently observed primary drive output for speed feedback.
function Thrust:speedApplied(now)
    local applied={}
    for _,side in ipairs({"left","right"}) do
        local role=side=="left" and "thrust-ls" or "thrust-rs"
        local drive="primary-"..side
        local node=self.controllers[role]
        local status=node and node.status
        local rb=status and status.readbacks and status.readbacks[drive]
        local readbackAge=status and finite(status.readbackAgeSeconds) and node and finite(node.statusAt) and
            now>=node.statusAt and status.readbackAgeSeconds+(now-node.statusAt) or nil
        if self:fresh(node,now) and finite(readbackAge) and readbackAge<=self:staleSeconds() and rb and rb.valid==true and
            status.applied and finite(status.applied[drive]) then
            applied[side]=clamp(status.applied[drive],-1,1)
        end
    end
    return applied
end

-- Summary: Detect sustained selected-speed demand at the configured or maximum thrust limit.
function Thrust:updateSpeedLimit(now,measured,error,output)
 local loop=self.speedLoop;local c=self.config.thrust
 local applied=self:speedApplied(now);local maximum=c.direct_max_request
 local sign=output<0 and -1 or 1
 local confirmed=math.abs(output)>=.99 and error*sign>.25 and finite(applied.left) and finite(applied.right)
     and applied.left*sign>=maximum-1/256 and applied.right*sign>=maximum-1/256
 for _,role in ipairs({"thrust-ls","thrust-rs"}) do
  local node=self.controllers[role];local status=node and node.status
  if not node or not finite(node.statusAt) or now-node.statusAt>1.5 or not status
      or status.reason or (finite(status.leaseRemainingSeconds) and status.leaseRemainingSeconds<=0) then confirmed=false end
 end
 if not confirmed then loop.limitSince=nil;loop.limitSpeed=nil;loop.limitDirection=nil;return end
 local alongSpeed=measured*sign
 if not loop.limitSince or loop.limitDirection~=sign or alongSpeed>(loop.limitSpeed or alongSpeed)+.25 then
  loop.limitSince=now;loop.limitSpeed=alongSpeed;loop.limitDirection=sign
 end
 if now-loop.limitSince>=8 then
  local fullRange=c.primary_max_rpm==256
  self.speedControl.controlStatus=fullRange and "MAX_THRUST" or "CONFIG_THRUST"
  self.speedControl.reason=fullRange and "UNABLE TO REACH TARGET: MAX THRUST" or
      "UNABLE TO REACH TARGET: CONFIG THRUST"
 end
end

-- Summary: Build the current selected-speed control measurements and limits.
function Thrust:speedSnapshot(now)
    local result=copy(self.speedControl or {})
    local gains=configuredSpeedGains(self.config)
    result.gains=gains
    result.gainsVerified=gains.verified
    result.appliedPrimary=self:speedApplied(now)
    local left,right=result.appliedPrimary.left,result.appliedPrimary.right
    result.appliedThrottle=finite(left) and finite(right) and (left+right)/2 or nil
    result.outputUnit="fraction_of_direct_maximum_request"
    return result
end

local FEEDFORWARD_PATH="/avionics/data/speed-feedforward-v2.json"
-- Cruise thrust per b/s. Propeller thrust scales with air pressure while her
-- drag does not (0.031/b/s at Y 200, pressure 0.55; 0.077/b/s near Y 306,
-- pressure 0.21), so the value is learned as thrust x pressure per b/s and
-- divided by the current pressure. It is also not linear in speed, so it is
-- kept in 4 b/s bands, interpolated, with one overall value as a fallback.
local FF_BAND=4
local REFERENCE_PRESSURE=0.55
local function ffLimit(g) return finite(g) and g>0.002 and g<0.08 end
-- Summary: Validate persisted pressure-normalised cruise gains and speed bands.
local function validFeedforward(value)
    if type(value) ~= "table" or not finite(value.gain) or value.gain < 0.002 or value.gain > 0.08 then
        return false, "invalid cruise feedforward gain"
    end
    if value.unit ~= nil and value.unit ~= "thrust_x_pressure_per_bps" then
        return false, "invalid cruise feedforward unit"
    end
    if value.bands ~= nil then
        if type(value.bands) ~= "table" then return false, "invalid cruise feedforward bands" end
        for key, gain in pairs(value.bands) do
            local index = tonumber(key)
            if not index or index < 0 or index >= 16 or index % 1 ~= 0 or
                not finite(gain) or gain < 0.002 or gain > 0.08 then
                return false, "invalid cruise feedforward band"
            end
        end
    end
    return true
end

-- Summary: Load the persisted speed-to-drive feedforward calibration.
function Thrust:loadSpeedFeedforward()
    if self.speedFeedforwardLoaded then return end
    self.speedFeedforwardLoaded=true
    local c=self.config.thrust or {}
    local base=Registry.number(c,"thrust.speed_feedforward_per_bps")
    self.speedFeedforward=base*REFERENCE_PRESSURE
    self.speedFeedforwardBands={}
    local ok, stored, reason = pcall(function()
        return require("avionics.storage").readValidatedJson(FEEDFORWARD_PATH, validFeedforward)
    end)
    if ok then self.speedFeedforwardLoadReason = reason
    else self.speedFeedforwardLoadReason = tostring(stored) end
    if ok and stored then
        self.speedFeedforward = stored.gain
        for key, gain in pairs(stored.bands or {}) do
            self.speedFeedforwardBands[tonumber(key)] = gain
        end
    end
end
function Thrust:feedforwardPressure()
    local p=self.airPressure
    if finite(p) and p>0.02 and p<5 then return p end
    return REFERENCE_PRESSURE
end
-- Pressure-normalised value for a speed (thrust x pressure per b/s).
-- Summary: Pressure-normalised value for a speed (thrust x pressure per b/s).
function Thrust:speedFeedforwardNormalised(speed)
    self:loadSpeedFeedforward()
    if not finite(speed) then return self.speedFeedforward end
    local x=math.abs(speed);local i=math.floor(x/FF_BAND)
    local bands=self.speedFeedforwardBands
    local g=bands[i] or self.speedFeedforward
    local centre=i*FF_BAND+FF_BAND/2
    local j=x<centre and i-1 or i+1
    local other=(j>=0 and bands[j]) or g
    local w=math.min(1,math.abs(x-centre)/FF_BAND)
    return g*(1-w)+other*w
end
function Thrust:speedFeedforwardGain(speed)
    return self:speedFeedforwardNormalised(speed)/self:feedforwardPressure()
end
-- Summary: Update bounded feedforward bands from current speed-control observations.
function Thrust:learnSpeedFeedforward(speed,sample,now)
    self:loadSpeedFeedforward()
    if not finite(sample) or not finite(speed) then return end
    local normalised=sample*self:feedforwardPressure()
    if not ffLimit(normalised) then return end
    local i=math.floor(math.abs(speed)/FF_BAND)
    if i>=16 then return end
    local current=self.speedFeedforwardBands[i] or self:speedFeedforwardNormalised(speed)
    self.speedFeedforwardBands[i]=clamp(current+0.2*(normalised-current),0.002,0.08)
    self.speedFeedforward=clamp(self.speedFeedforward+0.05*(normalised-self.speedFeedforward),0.002,0.08)
    if finite(self.speedFeedforwardSavedAt) and now>=self.speedFeedforwardSavedAt and now-self.speedFeedforwardSavedAt<30 then return end
    self.speedFeedforwardSavedAt=now
    local bands={}
    for index,g in pairs(self.speedFeedforwardBands) do bands[tostring(index)]=g end
    local ok, saved, reason = pcall(function()
        return require("avionics.storage").writeJson(FEEDFORWARD_PATH,
            {gain=self.speedFeedforward, bands=bands, unit="thrust_x_pressure_per_bps"}, nil, validFeedforward)
    end)
    if ok then self.speedFeedforwardSaveReason = not saved and reason or nil
    else self.speedFeedforwardSaveReason = tostring(saved) end
end

-- Summary: Limit thrust release during selected-speed overspeed correction in either travel direction.
local function speedOutputSlew(config,target,measured,previous,goal)
    local rate=finite(config.speed_output_slew_per_second) and config.speed_output_slew_per_second or .25
    local direction=target>0 and 1 or -1
    if target~=0 and (measured-target)*direction>0 and
        previous*direction>0 and goal*direction>=0 and goal*direction<previous*direction then
        local release=config.speed_overspeed_release_per_second
        release=finite(release) and release>0 and release or .10
        rate=math.min(rate,release)
    end
    return rate
end

-- Summary: Apply SEL 0 coast hysteresis and speed-proportional braking through the output slew.
local function zeroSelectedSpeedDrive(self,c,loop,measured,sampleAt,now,directMaximum)
    -- SEL 0 brake. Her drag alone slows her at about v/5 per second, and
    -- a reversal takes 5-8 s, so full reverse arrived when she was nearly
    -- stopped and drove her backwards. Instead: thrust is cut, and once
    -- the shafts have reversed the brake is proportional to speed
    -- (zero_brake_gain per b/s, default 0.06), so it fades to zero thrust
    -- as she stops. It brakes against the original direction of travel
    -- only; below 2 b/s, or if she has reversed, it latches to a coast
    -- (re-armed only if she later moves faster than 3 b/s). Brake output
    -- never exceeds the speed-proportional value, so it cannot start her
    -- moving the other way.
    local applied=self:speedApplied(now)
    local previous=loop.output or (finite(applied.left) and finite(applied.right) and
        clamp((applied.left+applied.right)/2/directMaximum,-1,1)) or 0
    local dt=finite(loop.outputAt) and now>loop.outputAt and math.min(1,now-loop.outputAt) or 0
    loop.outputAt=now
    local stopBand=Registry.number(c,"thrust.zero_brake_stop_bps")
    local gain=Registry.number(c,"thrust.zero_brake_gain")
    -- Brake on the speed she has now, not the speed in the (often
    -- seconds old) sample: project it forward over the sample age with
    -- her drag (v/tau) and the thrust actually on the shafts. A shaft
    -- still reversing counts as no thrust.
    local tau=Registry.number(c,"thrust.drag_time_constant_seconds")
    local accelPerThrust=1/(tau*self:speedFeedforwardGain(measured))
    local appliedNorm=finite(applied.left) and finite(applied.right) and
        clamp((applied.left+applied.right)/2/directMaximum,-1,1) or 0
    local thrust=(appliedNorm*previous>0) and previous or 0
    local age=clamp(now-sampleAt,0,10)
    local predicted=measured
    local remaining=age
    while remaining>0 do
        local h=math.min(.25,remaining);remaining=remaining-h
        local nextSpeed=predicted+(accelPerThrust*thrust-predicted/tau)*h
        -- Drag never reverses her; it only brings her to rest.
        if thrust==0 and nextSpeed*predicted<0 then nextSpeed=0 end
        predicted=nextSpeed
    end
    measured=predicted
    if loop.zeroCoast==nil then
        -- New SEL 0: brake against the current direction of travel.
        loop.zeroCoast=math.abs(measured)<=stopBand
        loop.brakeSign=measured>0 and 1 or -1
    end
    if not loop.zeroCoast and (measured*loop.brakeSign<=stopBand) then loop.zeroCoast=true end
    -- Re-arm only for a real new movement (above 3 b/s either way).
    if loop.zeroCoast and math.abs(measured)>math.max(3,stopBand) then
        loop.zeroCoast=false;loop.brakeSign=measured>0 and 1 or -1
    end
    local coast=loop.zeroCoast==true
    local desired=0
    if not coast then desired=-loop.brakeSign*clamp(gain*(math.abs(measured)-stopBand),0,1) end
    local step=(c.speed_output_slew_per_second or .25)*dt
    local output=clamp(desired,previous-step,previous+step)
    loop.integral=0;loop.derivative=0;loop.limitSince=nil;loop.goal=nil
    loop.output=output;loop.driveRequest=output*directMaximum;loop.initialized=true
    loop.lastSampleAt=sampleAt;loop.lastMeasurement=measured;loop.saturated=false
    local braking=desired~=0 or output~=0
    self.speedControl={state=braking and "BRAKING" or "COASTING",controlStatus=braking and "BRAKING" or "COASTING",
        available=true,targetSpeed=0,measuredSpeed=measured,error=-measured,output=output,
        zeroCoast=coast,coastThresholdBps=stopBand,saturated=false}
    return loop.driveRequest
end

-- Summary: Advance retained speed-output slew between distinct measurements and publish its status.
local function advanceSpeedGoal(self,c,loop,target,measured,error,now,directMaximum)
    -- Between vessel samples, keep ramping toward the last computed goal
    -- at the configured slew rate, so thrust changes smoothly instead of
    -- jumping once per sample.
    local output=loop.output or 0
    if finite(loop.goal) and finite(loop.outputAt) and now>loop.outputAt then
        local slewRate=speedOutputSlew(c,target,measured,output,loop.goal)
        local step=slewRate*math.min(1,now-loop.outputAt)
        output=clamp(loop.goal,output-step,output+step)
        loop.output=output;loop.driveRequest=output*directMaximum
    end
    loop.outputAt=now
    local overspeed=target~=0 and error~=0 and output==0
    self.speedControl={state=overspeed and "OVERSPEED_COAST" or (loop.saturated and "SATURATED" or "ACTIVE"),
        controlStatus=controlStatusFor(target,error,output),available=true,
        targetSpeed=target,measuredSpeed=measured,error=error,output=output,
        saturated=loop.saturated==true,
        reason=overspeed and "OVERSPEED; ZERO THRUST AND COAST" or nil}
    self:updateSpeedLimit(now,measured,error,output)
    return loop.driveRequest or output*directMaximum
end

-- Summary: Transfer speed feedback history, calculate bounded drive and update steady-cruise learning.
local function updateSpeedFeedback(self,c,loop,vessel,target,measured,sampleAt,error,now,directMaximum,unavailable)
    if loop.lastSampleAt and sampleAt<loop.lastSampleAt then
        return unavailable("SPEED SAMPLE TIME MOVED BACKWARDS")
    end

    local gains=c.speed_pid
    local dt
    if loop.lastSampleAt then
        local rawDt=sampleAt-loop.lastSampleAt
        if rawDt<=0 then return unavailable("SPEED SAMPLE TIME MOVED BACKWARDS") end
        if rawDt>(self.config.network.sensor_stale_seconds or 3) then
            -- A fresh sample after a long gap starts a new derivative/integral
            -- history and transfers from current primary readbacks again.
            self:resetSpeedLoop()
            loop=self.speedLoop;loop.uuid=vessel.uuid
        else dt=math.min(rawDt,1.0) end
    end
    local derivative=loop.derivative or 0
    if loop.lastMeasurement and dt then
        local rawDerivative=-(measured-loop.lastMeasurement)/dt
        local filter=gains.derivative_filter_seconds
        local alpha=dt/(filter+dt)
        derivative=derivative+alpha*(rawDerivative-derivative)
    else derivative=0 end
    -- Lead: with this much inertia, 1-2 s old speed samples and propeller
    -- spin-up, steer on the speed predicted a moment ahead from measured
    -- acceleration (derivative is -dv/dt). A coming slowdown is answered
    -- with thrust before she drops below the selected speed.
    local leadSeconds=Registry.number(c,"thrust.speed_lead_seconds")
    error=target-(measured-derivative*leadSeconds)

    local applied=self:speedApplied(now)
    local initialOutput
    if not loop.initialized then
        if finite(applied.left) and finite(applied.right) then
            initialOutput=clamp(((applied.left+applied.right)/2)/directMaximum,-1,1)
        else initialOutput=0 end
    end
    -- Drag feed-forward. Her drag balances thrust at about 0.04 output per
    -- b/s, so the loop is built around the thrust that holds the selected
    -- speed: output = feed-forward + PID trim. An overspeed lowers thrust
    -- toward (at most trim_down below) that cruise thrust and lets drag
    -- take the speed off, so she swings into a continuous cruise output
    -- instead of cutting thrust and re-accelerating.
    -- While the target ramps, she lags it by about tau*rate (her drag time
    -- constant); feeding the thrust for that lead speed keeps her on the
    -- ramp instead of letting the trim wind up and overshoot at its end.
    local tau=Registry.number(c,"thrust.drag_time_constant_seconds")
    if finite(loop.targetAt) and now>loop.targetAt then
        local rate=clamp((target-(loop.lastTarget or target))/(now-loop.targetAt),-2,2)
        loop.targetRate=(loop.targetRate or 0)+0.5*(rate-(loop.targetRate or 0))
    else loop.targetRate=0 end
    loop.lastTarget,loop.targetAt=target,now
    local ffSpeed=target+tau*(loop.targetRate or 0)
    if ffSpeed*target<0 then ffSpeed=0 end
    local ffGain=self:speedFeedforwardGain(ffSpeed)
    local ff=clamp(ffGain*ffSpeed,-1,1)
    local oldIntegral=loop.integral or 0
    local candidate=oldIntegral
    -- The trim integrates only near the target. During a large speed change
    -- the feed-forward and proportional terms do the work; integrating the
    -- whole change wound up a trim that overshot the new speed.
    local integrateBand=Registry.number(c,"thrust.speed_integrate_band_bps")
    -- Outside the band she may also have settled at a wrong speed: proportional thrust alone
    -- balanced drag 2 b/s off target. After 3 s of steady speed (|dv/dt| < 0.05 b/s^2) the
    -- trim integrates whatever the error, so a steady miss is corrected.
    if dt and math.abs(derivative)<0.05 then loop.steadySpeedSeconds=(loop.steadySpeedSeconds or 0)+dt
    else loop.steadySpeedSeconds=0 end
    if dt and (math.abs(error)<=integrateBand or loop.steadySpeedSeconds>=3) then
        candidate=clamp(oldIntegral+error*dt,-gains.integral_limit,gains.integral_limit)
    end
    if not loop.initialized and gains.ki>0 then
        -- Near the target, seed the trim from actual primary readbacks so a
        -- handover is bumpless. Far from it the feed-forward is the better
        -- estimate: a seed cancelling a large proportional term left a big
        -- negative trim that took a minute to unwind. The output slew still
        -- ramps from the current thrust either way.
        candidate=0
        if math.abs(error)<1.5 then
            candidate=clamp((initialOutput-ff-gains.kp*error-gains.kd*derivative)/gains.ki,
                -gains.integral_limit,gains.integral_limit)
        end
    end
    -- Reverse braking needs a full gearshift reversal (5-8 s) while drag
    -- alone sheds speed at roughly v/5 per second, so it is not used with a
    -- speed selected in her direction of travel unless
    -- thrust.reverse_brake_margin_bps is configured (with hysteresis).
    local lo,hi=-1,1
    local trimDown=Registry.number(c,"thrust.speed_trim_down_limit")
    if target~=0 then
        local margin=Registry.number(c,"thrust.reverse_brake_margin_bps")
        local over=(measured-target)*(target>0 and 1 or -1)
        if over>margin then loop.reverseBrake=true elseif over<margin/3 then loop.reverseBrake=nil end
        if not loop.reverseBrake then
            if target>0 then lo=math.max(0,ff-trimDown) else hi=math.min(0,ff+trimDown) end
        end
    else loop.reverseBrake=nil end
    -- The thrust nodes ramp slowly. While the commanded output is already
    -- well ahead of the applied thrust in the error's direction, further
    -- integration only winds up (and later overshoots).
    local appliedNorm=finite(applied.left) and finite(applied.right) and directMaximum and directMaximum>0 and
        clamp(((applied.left+applied.right)/2)/directMaximum,-1,1) or nil
    if dt and loop.initialized and appliedNorm and finite(loop.output) then
        local lead=loop.output-appliedNorm
        if math.abs(lead)>0.25 and lead*error>0 then candidate=oldIntegral end
    end
    local function pid(i) return ff+gains.kp*error+gains.ki*i+gains.kd*derivative end
    local raw=pid(candidate)
    local bounded=clamp(raw,lo,hi)
    local previous=loop.initialized and (loop.output or initialOutput or 0) or initialOutput
    -- Overspeed corrections ease the existing thrust toward zero at the
    -- release limit; acceleration and reverse braking use the normal slew.
    local slew=speedOutputSlew(c,target,measured,previous,bounded)
    -- Slew on real time since the output last moved (ticks also move it).
    local elapsed=finite(loop.outputAt) and now>loop.outputAt and math.min(1,now-loop.outputAt) or dt
    local maxStep=dt and slew*(elapsed or dt) or 0
    local output=dt and clamp(bounded,previous-maxStep,previous+maxStep) or previous
    -- Saturation means the controller asks for more than full output; the
    -- slew ramp catching up is not saturation.
    local saturated=raw<=-1 or raw>=1
    -- Clamp integration to the output boundary (the hard limit, or the
    -- cruise-thrust floor) only when error pushes farther into it.
    local drivingSaturation=dt~=nil and ((raw>=hi and error>0) or (raw<=lo and error<0))
    if drivingSaturation then
        if gains.ki>0 then
            local boundary=raw>=hi and hi or lo
            candidate=clamp((boundary-ff-gains.kp*error-gains.kd*derivative)/gains.ki,
                -gains.integral_limit,gains.integral_limit)
        else candidate=oldIntegral end
        raw=pid(candidate)
        bounded=clamp(raw,lo,hi)
        output=dt and clamp(bounded,previous-maxStep,previous+maxStep) or previous
        saturated=raw<=-1 or raw>=1
    end
    -- Learn the cruise thrust from any equilibrium: speed not changing for
    -- 5 s with the applied thrust steady. Then thrust balances drag at that
    -- speed, whatever the target. The trim takes over each change so the
    -- output does not step; the learned value serves the next speed change.
    if dt and appliedNorm and math.abs(measured)>1 and measured*appliedNorm>0 and math.abs(derivative)<0.05 and
        finite(loop.output) and math.abs(loop.output-appliedNorm)<0.03 then
        loop.steadySince=loop.steadySince or now
        if now-loop.steadySince>=5 then
            self:learnSpeedFeedforward(measured,appliedNorm/measured,now)
            local updated=clamp(self:speedFeedforwardGain(ffSpeed)*ffSpeed,-1,1)
            if gains.ki>0 then candidate=clamp(candidate-(updated-ff)/gains.ki,-gains.integral_limit,gains.integral_limit) end
            ff=updated
        end
    else loop.steadySince=nil end
    loop.goal=bounded;loop.outputAt=now
    loop.integral,loop.derivative= candidate,derivative
    loop.lastSampleAt,loop.lastMeasurement,loop.initialized=sampleAt,measured,true
    loop.output,loop.driveRequest,loop.saturated=output,output*directMaximum,saturated
    self.lastSpeedAt=sampleAt
    local overspeed=target~=0 and error~=0 and output==0
    self.speedControl={state=overspeed and "OVERSPEED_COAST" or (saturated and "SATURATED" or "ACTIVE"),
        controlStatus=controlStatusFor(target,error,output),available=true,
        targetSpeed=target,measuredSpeed=measured,error=error,output=output,
        saturated=saturated,feedforward=ff,feedforwardGain=ffGain,
        reason=overspeed and "OVERSPEED; ZERO THRUST AND COAST" or nil}
    self:updateSpeedLimit(now,measured,error,output)
    return loop.driveRequest
end

-- Summary: Compute selected-speed drive demand using measured speed and configured limits.
function Thrust:speedDriveRequest(io,now,controls)
    local c=self.config.thrust or {}
    local target=controls.targets and controls.targets.speed
    local vessel=io.vessel or {}
    local sampleAt=measurementAt(vessel,"forwardSpeed")
    local measured=finite(vessel.forwardSpeed) and vessel.forwardSpeed or nil
    local function unavailable(reason)
        self:setSpeedUnavailable(reason,target,measured)
        return nil,reason
    end
    local reason=directConfigReason(self.config)
    if reason then
        self:resetSpeedLoop()
        self.speedControl={state=reason=="PROPULSION DISABLED IN CONFIG" and "DISABLED" or "UNAVAILABLE",
            controlStatus="UNAVAILABLE",available=false,reason=reason,
            targetSpeed=finite(target) and target or nil,measuredSpeed=measured,
            error=finite(target) and finite(measured) and target-measured or nil,output=nil,saturated=false}
        return nil,reason
    end
    if c.speed_control_verified~=true and c.speed_control_enabled~=true then return unavailable("SPEED CONTROL NOT VERIFIED") end
    if not (self.config.geometry and self.config.geometry.velocity_frame_verified==true) then
        return unavailable("VERIFIED SIGNED SPEED AXIS REQUIRED")
    end
    if not finite(c.speed_target_rate_bps2) or c.speed_target_rate_bps2<=0 or
        type(c.speed_pid)~="table" then return unavailable("SPEED CONTROL LIMITS UNSET") end
    if not finite(target) then return unavailable("SPEED TARGET UNAVAILABLE") end
    local cockpit=self.config.cockpit or {}
    if not finite(cockpit.minimum_selected_speed) or not finite(cockpit.maximum_selected_speed) or
        cockpit.minimum_selected_speed>=cockpit.maximum_selected_speed then
        return unavailable("SPEED TARGET LIMITS UNSET")
    end
    if target<cockpit.minimum_selected_speed or target>cockpit.maximum_selected_speed then
        return unavailable("SPEED TARGET OUTSIDE CONFIGURED BOUNDS")
    end
    if vessel.valid~=true or vessel.velocityFrameVerified~=true or not finite(sampleAt) or
        now<sampleAt or now-sampleAt>(self.config.network.sensor_stale_seconds or 3) or
        not finite(measured) then return unavailable("FRESH VERIFIED SIGNED SPEED REQUIRED") end
    if type(vessel.uuid)~="string" or vessel.uuid=="" then
        return unavailable("VESSEL ID UNAVAILABLE")
    end
    if controls.speedTargetUuid~=vessel.uuid then
        return unavailable("SPEED TARGET NOT SELECTED FOR THIS VESSEL")
    end
    if self.speedLoop and self.speedLoop.uuid and self.speedLoop.uuid~=vessel.uuid then
        return unavailable("VESSEL CHANGED; RESELECT SPEED MODE")
    end
    for _,role in ipairs({"thrust-ls","thrust-rs"}) do
        local ready,why=self:controllerReady(role,now)
        if not ready then return unavailable(why) end
    end

    local error=target-measured
    local loop=self.speedLoop or {integral=0,derivative=0}
    self.speedLoop=loop
    loop.uuid=vessel.uuid
    local directMaximum=c.direct_max_request
    local pilotZero=target==0 and not controls.routeSpeedAuthority and not controls.anchorAuthority
    if pilotZero then
        return zeroSelectedSpeedDrive(self,c,loop,measured,sampleAt,now,directMaximum)
    end
    loop.zeroCoast=nil
    local newSample=loop.lastSampleAt~=sampleAt
    if not newSample and loop.initialized then
        return advanceSpeedGoal(self,c,loop,target,measured,error,now,directMaximum)
    end
    return updateSpeedFeedback(self,c,loop,vessel,target,measured,sampleAt,error,now,directMaximum,unavailable)
end

-- Summary: Clear heading-loop integral and rate-derivative history.
function Thrust:resetHeadingLoop()
    self.headingLoop={integral=0,rateDerivative=0}
end

-- Summary: Reset heading feedback and publish unavailable heading-control status.
function Thrust:setHeadingUnavailable(reason,mode,target,measured)
    self:resetHeadingLoop()
    self.headingControl={state="UNAVAILABLE",available=false,mode=mode or "MANUAL",
        reason=clean(reason or "HEADING CONTROL UNAVAILABLE",160),
        targetHeading=finite(target) and target%360 or nil,
        measuredHeading=finite(measured) and measured%360 or nil,saturated=false}
end

local function headingWaiting(self,reason,target,measured,error)
    self.headingControl={state="WAITING",available=false,mode="SEL",
        reason=clean(reason,160),targetHeading=finite(target) and target%360 or nil,
        measuredHeading=finite(measured) and measured%360 or nil,
        headingError=finite(error) and error or nil,saturated=false}
end

local function wrapDegrees(value)
    return (value+180)%360-180
end

-- Summary: Compute manual or selected-heading yaw demand from current vessel observations.
function Thrust:headingDriveDemand(io,now,controls)
    local mode=controls.modes and controls.modes.heading or "MANUAL"
    local demand=finite(controls.yaw) and clamp(controls.yaw,-1,1) or 0
    local c=self.config.thrust or {}
    local vessel=io.vessel or {}
    local sampleAt=measurementAt(vessel,"heading")
    -- Restored presets hold propulsion until START SYSTEMS is READY.
    if controls.holdPropulsion==true then
        self:resetHeadingLoop()
        self.headingControl={state="HELD",available=true,mode=mode,yawDemand=0,
            reason=controls.holdReason or "PROPULSION HELD",saturated=false}
        return 0
    end
    if mode~="SEL" then
        local reason=directConfigReason(self.config)
        if reason then self:setHeadingUnavailable(reason,"MANUAL"); return 0 end
        if c.mixer_verified~=true or type(c.lateral_mixer)~="table" then
            self:setHeadingUnavailable("LATERAL MIXER NOT VERIFIED","MANUAL")
            return 0
        end
        self.headingControl={state="MANUAL",available=true,mode="MANUAL",
            reason=nil,yawDemand=demand,targetYawRate=nil,
            measuredHeading=finite(vessel.heading) and vessel.heading%360 or nil,
            saturated=false}
        return demand
    end

    local target=controls.targets and controls.targets.heading
    local function unavailable(reason)
        self:setHeadingUnavailable(reason,"SEL",target,vessel.heading)
        return 0
    end
    local reason=directConfigReason(self.config)
    if reason then return unavailable(reason) end
    if c.mixer_verified~=true or type(c.lateral_mixer)~="table" then
        return unavailable("LATERAL MIXER NOT VERIFIED")
    end
    local config=c.heading_control
    if (c.heading_control_verified~=true and c.heading_control_enabled~=true) or
        type(config)~="table" or type(config.rate_pid)~="table" then
        return unavailable("HEADING CONTROL NOT VERIFIED")
    end
    local stale=(self.config.network or {}).sensor_stale_seconds or 3
    if vessel.valid~=true or vessel.geometryVerified~=true or not finite(vessel.heading) or
        not finite(sampleAt) or now<sampleAt or now-sampleAt>stale then
        return unavailable("FRESH HEADING REQUIRED")
    end
    if type(vessel.uuid)~="string" or vessel.uuid=="" or controls.headingTargetUuid~=vessel.uuid then
        return unavailable("HEADING TARGET NOT SELECTED FOR THIS VESSEL")
    end
    if not finite(target) or target<0 or target>=360 then return unavailable("HEADING TARGET UNAVAILABLE") end

    local loop=self.headingLoop or {integral=0,rateDerivative=0}
    self.headingLoop=loop
    if loop.uuid and loop.uuid~=vessel.uuid then
        self:resetHeadingLoop(); loop=self.headingLoop
    end
    loop.uuid=vessel.uuid
    local measuredHeading=vessel.heading%360
    local error=wrapDegrees(target-measuredHeading)
    local newSample=loop.lastSampleAt~=sampleAt
    if not newSample and loop.initialized then
        self.headingControl={state=loop.saturated and "SATURATED" or
            (math.abs(loop.output or 0)>0.000001 and "TURNING" or "HOLDING"),
            available=true,mode="SEL",targetHeading=target,measuredHeading=measuredHeading,
            headingError=error,measuredYawRate=loop.measuredYawRate,
            targetYawRate=loop.targetYawRate,yawDemand=loop.output,
            saturated=loop.saturated==true}
        return loop.output or 0
    end
    if not newSample then
        headingWaiting(self,"WAITING FOR A SECOND HEADING SAMPLE",target,measuredHeading,
            wrapDegrees(target-measuredHeading))
        return 0
    end
    if loop.lastSampleAt and sampleAt<loop.lastSampleAt then
        return unavailable("HEADING SAMPLE TIME MOVED BACKWARDS")
    end
    if not loop.lastSampleAt then
        loop.lastSampleAt,loop.lastMeasurement=sampleAt,measuredHeading
        headingWaiting(self,"WAITING FOR A SECOND HEADING SAMPLE",target,measuredHeading,
            wrapDegrees(target-measuredHeading))
        return 0
    end

    local rawDt=sampleAt-loop.lastSampleAt
    if rawDt<=0 then return unavailable("HEADING SAMPLE TIME MOVED BACKWARDS") end
    if rawDt>stale then
        self:resetHeadingLoop(); loop=self.headingLoop
        loop.uuid,loop.lastSampleAt,loop.lastMeasurement=vessel.uuid,sampleAt,measuredHeading
        headingWaiting(self,"WAITING FOR FRESH HEADING RATE",target,measuredHeading,
            wrapDegrees(target-measuredHeading))
        return 0
    end
    local dt=math.min(rawDt,1)
    local rawRate=wrapDegrees(measuredHeading-loop.lastMeasurement)/rawDt
    local alpha=dt/(config.rate_filter_seconds+dt)
    local measuredRate=loop.measuredYawRate and
        loop.measuredYawRate+alpha*(rawRate-loop.measuredYawRate) or rawRate
    -- AP acquisition leads the heading by four seconds of measured rotation
    -- to brake before alignment.
    local acquisition=controls.apAcquisition==true
    local steeringError=acquisition and (error-measuredRate*4) or error
    local targetRateRaw=steeringError*config.heading_rate_per_degree
    local targetRate=clamp(targetRateRaw,-config.maximum_yaw_rate_degrees_per_second,
        config.maximum_yaw_rate_degrees_per_second)
    local rateError=targetRate-measuredRate
    local gains=config.rate_pid
    local rawDerivative=loop.measuredYawRate and -(measuredRate-loop.measuredYawRate)/dt or 0
    local derivativeAlpha=dt/(gains.derivative_filter_seconds+dt)
    local derivative=(loop.rateDerivative or 0)+derivativeAlpha*(rawDerivative-(loop.rateDerivative or 0))
    local oldIntegral=loop.integral or 0
    if acquisition and oldIntegral*rateError<0 then oldIntegral=0 end
    local candidate=clamp(oldIntegral+rateError*dt,-gains.integral_limit,gains.integral_limit)
    -- SEL needs the same rate-loop authority as AP acquisition. With the
    -- previous half gain, a 10 deg/s request at 1 deg/s could stall near 55%
    -- output even after the integral reached its limit.
    local rateKp=gains.kp*2
    local raw=rateKp*rateError+gains.ki*candidate+gains.kd*derivative
    local bounded=clamp(raw,-1,1)
    local previous=loop.initialized and (loop.output or 0) or 0
    local maxStep=config.output_slew_per_second*dt
    local output=clamp(bounded,previous-maxStep,previous+maxStep)
    local saturated=raw<=-1 or raw>=1 or output~=bounded or targetRate~=targetRateRaw
    local drivesSaturation=(raw>=1 and rateError>0) or (raw<=-1 and rateError<0)
    if drivesSaturation then
        if gains.ki>0 then
            local edge=raw>=1 and 1 or -1
            candidate=clamp((edge-rateKp*rateError-gains.kd*derivative)/gains.ki,
                -gains.integral_limit,gains.integral_limit)
        else candidate=oldIntegral end
        raw=rateKp*rateError+gains.ki*candidate+gains.kd*derivative
        bounded=clamp(raw,-1,1)
        output=clamp(bounded,previous-maxStep,previous+maxStep)
        saturated=raw<=-1 or raw>=1 or output~=bounded or targetRate~=targetRateRaw
    end
    loop.integral,loop.rateDerivative=candidate,derivative
    loop.lastSampleAt,loop.lastMeasurement,loop.measuredYawRate=sampleAt,measuredHeading,measuredRate
    loop.targetYawRate,loop.output,loop.saturated,loop.initialized=targetRate,output,saturated,true
    local state=saturated and "SATURATED" or
        (math.abs(output)>0.000001 and "TURNING" or "HOLDING")
    self.headingControl={state=state,available=true,mode="SEL",targetHeading=target,
        measuredHeading=measuredHeading,headingError=error,measuredYawRate=measuredRate,
        targetYawRate=targetRate,yawDemand=output,saturated=saturated}
    return output
end

-- Summary: Clear both primary acceleration integrals and derivatives.
function Thrust:resetManualAccelerationLoop()
    self.accelerationLoop={integral={left=0,right=0},derivative={left=0,right=0}}
end

-- Summary: Record the observation or configuration reason blocking acceleration feedback.
function Thrust:setManualAccelerationUnavailable(reason,target,measured)
    self:resetManualAccelerationLoop()
    self.manualAcceleration={state="UNAVAILABLE",available=false,
        reason=clean(reason or "MANUAL ACCELERATION UNAVAILABLE",160),
        targetAcceleration=finite(target) and target or nil,
        measuredAcceleration=finite(measured) and measured or nil,
        measurementNote=ACCELERATION_MEASUREMENT_NOTE,
        saturated=false}
end

local function manualAccelerationWaiting(self,reason,target,turnYawRate)
    self.manualAcceleration={state="WAITING",available=false,
        reason=clean(reason,160),targetAcceleration=finite(target) and target or nil,
        turnYawRate=turnYawRate,
        measurementNote=ACCELERATION_MEASUREMENT_NOTE,
        saturated=false}
end

-- Choose the signed drive range for MAN. A neutral hold coasts above its
-- captured speed. Counter-thrust needs both fresh zero readbacks for two
-- seconds and a persistent error large enough to justify a gear change.
function Thrust.manualDriveBounds(loop,target,speed,measured,applied,sampleAt)
    local held=loop.zeroAccelerationSpeed
    local direction=target~=0 and (target>0 and 1 or -1) or
        (held and held~=0 and (held>0 and 1 or -1) or (speed>=0 and 1 or -1))
    local excess=held and (speed-held)*direction or 0
    local coasting=held~=nil and (held==0 or excess>.5)
    local needsBrake
    if held~=nil then
        needsBrake=excess>2 and measured*direction>=-.1
    else
        needsBrake=speed*direction>2 and (measured-target)*direction>.15
    end
    coasting=coasting or needsBrake
    if loop.manualBrakeDirection~=direction or loop.manualBrakeTarget~=target then
        loop.manualBrakeSince=nil;loop.manualBrakeAllowed=false
    end
    loop.manualBrakeDirection,loop.manualBrakeTarget=direction,target
    if not needsBrake or not finite(applied.left) or not finite(applied.right) then
        loop.manualBrakeSince=nil;loop.manualBrakeAllowed=false
    elseif not loop.manualBrakeAllowed then
        if applied.left==0 and applied.right==0 then
            loop.manualBrakeSince=loop.manualBrakeSince or sampleAt
            loop.manualBrakeAllowed=sampleAt-loop.manualBrakeSince>=2
        else
            loop.manualBrakeSince=nil
        end
    end
    local withDrive=coasting and 0 or 1
    local counter=loop.manualBrakeAllowed and .15 or 0
    if direction>0 then return -counter,withDrive,coasting end
    return -withDrive,counter,coasting
end

-- Track absolute yaw from distinct heading measurements in degrees per second.
-- Rates above 0.5 start a pause. A full second below 0.25 ends it.
-- Heading gaps clear the settling interval and require a new rate pair.
function Thrust:manualTurnState(vessel,headingAt,now,stale)
    local turn=self.manualTurn or {}
    if turn.uuid~=vessel.uuid then turn={uuid=vessel.uuid} end
    self.manualTurn=turn
    if not finite(vessel.heading) or not finite(headingAt) or now<headingAt or now-headingAt>stale then
        turn.heading,turn.at,turn.rate,turn.settledSince=nil,nil,nil,nil
        return turn
    end
    if headingAt==turn.at then return turn end
    local dt=turn.at and headingAt-turn.at
    local rate=dt and dt>0 and dt<=stale and math.abs(wrapDegrees(vessel.heading-turn.heading)/dt) or nil
    turn.heading,turn.at,turn.rate=vessel.heading,headingAt,rate
    if rate and rate>.5 then turn.active=true end
    if turn.active and rate and rate<.25 then
        -- Each rate describes the interval between the two heading samples.
        turn.settledSince=turn.settledSince or headingAt-dt
        if headingAt-turn.settledSince>=1 then
            turn.active=false
            turn.settledSince=nil
        end
    else
        turn.settledSince=nil
    end
    return turn
end

-- Summary: Compute bounded primary-drive demand for the selected manual acceleration.
function Thrust:manualAccelerationDriveRequest(io,now,controls)
    local c=self.config.thrust or {}
    local mode=controls.modes and controls.modes.throttle or "MANUAL"
    local target
    local demand=finite(controls.request) and clamp(controls.request,-1,1) or 0
    local limits=c.manual_acceleration
    if type(limits)=="table" and finite(limits.minimum) and finite(limits.maximum) and
        limits.minimum<0 and limits.maximum>0 then
        target=demand>=0 and demand*limits.maximum or math.abs(demand)*limits.minimum
    end
    local vessel=io.vessel or {}
    local sampleAt=measurementAt(vessel,"forwardSpeed")
    local headingAt=measurementAt(vessel,"heading")
    local function unavailable(reason,measured)
        self:setManualAccelerationUnavailable(reason,target,measured)
        return {left=0,right=0}
    end
    local reason=directConfigReason(self.config)
    if reason then return unavailable(reason) end
    if mode~="MANUAL" then return unavailable("THROTTLE MODE NOT MANUAL") end
    if (c.manual_acceleration_verified~=true and c.manual_acceleration_enabled~=true) or
        not target or type(c.manual_acceleration_pid)~="table" then
        return unavailable("MANUAL ACCELERATION CONTROL NOT VERIFIED")
    end
    if target==0 and io.propulsionHoldSuppressed then
        self:resetManualAccelerationLoop()
        self.manualAcceleration={state="IDLE",available=true,targetAcceleration=0,
            driveOutput=0,driveOutputBySide={left=0,right=0},measurementNote=ACCELERATION_MEASUREMENT_NOTE,
            saturated=false,reason=io.propulsionHoldSuppressed}
        return {left=0,right=0}
    end
    if not (self.config.geometry and self.config.geometry.velocity_frame_verified==true) then
        return unavailable("VERIFIED SIGNED SPEED AXIS REQUIRED")
    end
    local stale=(self.config.network or {}).sensor_stale_seconds or 3
    if vessel.valid~=true or vessel.velocityFrameVerified~=true or not finite(vessel.forwardSpeed) or
        not finite(sampleAt) or now<sampleAt or now-sampleAt>stale then
        return unavailable("FRESH SIGNED SPEED REQUIRED")
    end
    if type(vessel.uuid)~="string" or vessel.uuid=="" then return unavailable("VESSEL ID UNAVAILABLE") end
    -- Rotation changes the projection of drift onto the bow. Pause neutral
    -- drive during measured turns and capture the settled forward speed.
    local turn=self:manualTurnState(vessel,headingAt,now,stale)
    if target==0 and turn.active then
        self:resetManualAccelerationLoop()
        self.manualAcceleration={state="TURNING",available=true,targetAcceleration=0,
            driveOutput=0,driveOutputBySide={left=0,right=0},saturated=false,
            reason="NEUTRAL CORRECTION PAUSED UNTIL TURN SETTLES",
            turnYawRate=turn.rate,
            measurementNote=ACCELERATION_MEASUREMENT_NOTE}
        return {left=0,right=0}
    end
    local loop=self.accelerationLoop or {integral={left=0,right=0},derivative={left=0,right=0}}
    self.accelerationLoop=loop
    if loop.uuid and loop.uuid~=vessel.uuid then
        self:resetManualAccelerationLoop(); loop=self.accelerationLoop
    end
    loop.uuid=vessel.uuid
    -- Zero acceleration means retain the speed present when the pilot releases
    -- the acceleration input. Acceleration feedback alone can settle at a much
    -- lower speed after its initial drag transient, so restore that speed with
    -- a bounded correction rather than treating neutral as propeller stop.
    if target==0 then
        if not finite(loop.zeroAccelerationSpeed) then
            -- Releasing the lever while practically stopped means "stay
            -- stopped", not "keep this residual drift".
            local capture=Registry.number(c,"thrust.zero_hold_capture_speed")
            loop.zeroAccelerationSpeed=math.abs(vessel.forwardSpeed)<capture and 0 or vessel.forwardSpeed
        end
    else loop.zeroAccelerationSpeed=nil end
    local newSample=loop.lastSampleAt~=sampleAt
    if not newSample and loop.initialized then
        local output=loop.driveOutput or {left=0,right=0}
        -- Keep ramping toward the last goal between vessel samples.
        if type(loop.goal)=="table" and finite(loop.outputAt) and now>loop.outputAt then
            local slewRate=finite(c.speed_output_slew_per_second) and c.speed_output_slew_per_second or 0.25
            local step=slewRate*math.min(1,now-loop.outputAt)
            local moved={}
            for _,side in ipairs({"left","right"}) do
                local current=output[side] or 0
                local goal=loop.lastPilotAcceleration==target and loop.goal[side] or 0
                moved[side]=clamp(goal,current-step,current+step)
            end
            output=moved;loop.driveOutput=moved
        end
        loop.outputAt=now
        self.manualAcceleration={state=loop.state or "HOLDING",available=true,
            targetAcceleration=target,measuredAcceleration=loop.measuredAcceleration,
            turnYawRate=turn.rate,
            holdingSpeed=loop.zeroAccelerationSpeed,
            driveOutput=(output.left+output.right)/2,driveOutputBySide=copy(output),
            measurementNote=ACCELERATION_MEASUREMENT_NOTE,
            saturated=loop.saturated==true,reason=loop.reason}
        return {left=output.left*c.direct_max_request,right=output.right*c.direct_max_request}
    end
    if not newSample then
        manualAccelerationWaiting(self,"WAITING FOR A SECOND SPEED SAMPLE",target,turn.rate)
        return {left=0,right=0}
    end
    if loop.lastSampleAt and sampleAt<loop.lastSampleAt then
        return unavailable("SPEED SAMPLE TIME MOVED BACKWARDS",loop.measuredAcceleration)
    end
    if not loop.lastSampleAt then
        loop.lastSampleAt,loop.lastMeasurement=sampleAt,vessel.forwardSpeed
        manualAccelerationWaiting(self,"WAITING FOR A SECOND SPEED SAMPLE",target,turn.rate)
        return {left=0,right=0}
    end
    local rawDt=sampleAt-loop.lastSampleAt
    if rawDt<=0 then return unavailable("SPEED SAMPLE TIME MOVED BACKWARDS",loop.measuredAcceleration) end
    if rawDt>stale then
        self:resetManualAccelerationLoop(); loop=self.accelerationLoop
        loop.uuid,loop.lastSampleAt,loop.lastMeasurement=vessel.uuid,sampleAt,vessel.forwardSpeed
        manualAccelerationWaiting(self,"WAITING FOR FRESH ACCELERATION",target,turn.rate)
        return {left=0,right=0}
    end
    local dt=math.min(rawDt,1)
    local rawAcceleration=(vessel.forwardSpeed-loop.lastMeasurement)/rawDt
    if not finite(rawAcceleration) or math.abs(rawAcceleration)>1000 then
        return unavailable("ACCELERATION SAMPLE OUT OF BOUNDS",loop.measuredAcceleration)
    end
    local gains=c.manual_acceleration_pid
    local filter=gains.derivative_filter_seconds
    local accelerationAlpha=dt/(filter+dt)
    local measured=finite(loop.measuredAcceleration) and
        loop.measuredAcceleration+accelerationAlpha*(rawAcceleration-loop.measuredAcceleration) or rawAcceleration
    local derivativeRaw=finite(loop.measuredAcceleration) and -(measured-loop.measuredAcceleration)/dt or 0
    local derivativeAlpha=dt/(filter+dt)
    local derivative=loop.derivative or {left=0,right=0}
    local derivativeNext={}
    local outputNext={}
    local saturated=false
    local applied=self:speedApplied(now)
    local low,high,coasting=Thrust.manualDriveBounds(loop,target,vessel.forwardSpeed,measured,applied,sampleAt)
    local controlAcceleration=target
    if finite(loop.zeroAccelerationSpeed) then
        local error=loop.zeroAccelerationSpeed-vessel.forwardSpeed
        local outsideBand=math.max(0,math.abs(error)-.5)
        local holdGain=finite(c.manual_speed_hold_gain) and c.manual_speed_hold_gain or .5
        controlAcceleration=clamp((error<0 and -outsideBand or outsideBand)*holdGain,limits.minimum,limits.maximum)
    end
    local accelerationError=controlAcceleration-measured
    local slew=finite(c.speed_output_slew_per_second) and c.speed_output_slew_per_second or 0.25
    local elapsed=finite(loop.outputAt) and now>loop.outputAt and math.min(1,now-loop.outputAt) or dt
    local maxStep=slew*elapsed
    local goals={}
    for _,side in ipairs({"left","right"}) do
        local filteredDerivative=(derivative[side] or 0)+derivativeAlpha*(derivativeRaw-(derivative[side] or 0))
        derivativeNext[side]=filteredDerivative
        local oldIntegral=(loop.integral and loop.integral[side]) or 0
        local candidate=oldIntegral
        local previous
        if loop.initialized then previous=loop.driveOutput[side] or 0
        elseif finite(applied[side]) then previous=clamp(applied[side]/c.direct_max_request,-1,1)
        else previous=0 end
        -- Seed the integral from the current readback on a mode handover. The
        -- feedback gains then follow measured acceleration without assuming
        -- one universal engine-level-to-acceleration relationship.
        if not loop.initialized and gains.ki>0 and finite(applied[side]) then
            candidate=clamp((previous-gains.kp*accelerationError-gains.kd*filteredDerivative)/gains.ki,
                -gains.integral_limit,gains.integral_limit)
        end
        -- Integrate once the fresh transmission readback tracks the previous
        -- goal within 3% drive, or when the correction closes that gap.
        local priorGoal=(loop.goal or {})[side] or previous
        if finite(applied[side]) and math.abs(accelerationError)>.02 then
            local trackingError=priorGoal-applied[side]/c.direct_max_request
            if math.abs(trackingError)<=.03 or trackingError*accelerationError<0 then
                candidate=clamp(candidate+accelerationError*dt,-gains.integral_limit,gains.integral_limit)
            end
        end
        local raw=gains.kp*accelerationError+gains.ki*candidate+gains.kd*filteredDerivative
        local bounded=clamp(raw,low,high)
        if (raw-bounded)*accelerationError>0 then
            candidate=oldIntegral
        end
        -- Release stored effort when coasting or changing drive direction.
        candidate=clamp(candidate,low<0 and -gains.integral_limit or 0,high>0 and gains.integral_limit or 0)
        raw=gains.kp*accelerationError+gains.ki*candidate+gains.kd*filteredDerivative
        bounded=clamp(raw,low,high)
        local output=clamp(bounded,previous-maxStep,previous+maxStep)
        local driveSaturated=raw<=-1 or raw>=1
        goals[side]=bounded
        loop.integral=loop.integral or {left=0,right=0}
        loop.integral[side]=candidate
        outputNext[side]=output
        saturated=saturated or driveSaturated
    end
    loop.derivative=derivativeNext
    loop.lastSampleAt,loop.lastMeasurement,loop.measuredAcceleration=sampleAt,vessel.forwardSpeed,measured
    loop.driveOutput=outputNext
    loop.goal=goals;loop.outputAt=now
    loop.lastPilotAcceleration=target
    loop.initialized=true
    local tolerance=math.max(0.02,(limits.maximum-limits.minimum)*0.02)
    local withinTolerance=math.abs(accelerationError)<=tolerance
    local coastState=coasting and math.abs(goals.left)<=0.000001 and math.abs(goals.right)<=0.000001
    local state=coastState and "COASTING" or (saturated and "SATURATED" or
        (withinTolerance and "HOLDING" or "ACCELERATING"))
    local controlReason=nil
    loop.state,loop.saturated,loop.reason=state,saturated,controlReason
    self.manualAcceleration={state=state,available=true,targetAcceleration=target,
        measuredAcceleration=measured,driveOutput=(outputNext.left+outputNext.right)/2,
        turnYawRate=turn.rate,
        holdingSpeed=loop.zeroAccelerationSpeed,
        driveOutputBySide=copy(outputNext),
        measurementNote=ACCELERATION_MEASUREMENT_NOTE,
        saturated=saturated,reason=controlReason}
    return {left=outputNext.left*c.direct_max_request,right=outputNext.right*c.direct_max_request}
end

-- Section: Endpoint context | Configuration, discovery and command identity.
-- Summary: Validate the live input and vessel context before propulsion commands.
local function commandGate(io,now)
    if type(io.routeAllowed)=="function" then
        local allowed,why=io:routeAllowed()
        if not allowed then return false,why end
    elseif io.identityReady==false then return false,io.identityReason or "CORE IDENTITY UNVERIFIED" end
    if type(io.assemblyGate)=="function" then
        local assembled,why=io:assemblyGate(now)
        if not assembled then return false,why end
    end
    return true
end

-- Section: Readbacks | Timestamped physical observations and status.
-- Summary: Check configuration, input and controller readiness for propulsion engagement.
function Thrust:activationReady(io,now,controls)
    local open,why=commandGate(io,now)
    if not open then return false,why end
    if io.anchor=="ANCHORED" or io.anchor=="BRAKING" then return false,"ANCHOR SUPPRESSES PROPULSION" end
    if not controls or type(controls.usable)~="function" then return false,"COCKPIT CONTROLS UNAVAILABLE" end
    local usable,usableReason=controls:usable(io,now)
    if not usable then return false,usableReason end
    local c=self.config.thrust or {}
    if c.limits_verified~=true or c.mapping_verified~=true or c.mixer_verified~=true or
        c.primary_input_rpm~=256 then return false,"PROPULSION HARDWARE MODEL NOT CONFIGURED" end
    for _,role in ipairs(CONTROLLERS) do
        local ready,reason=self:controllerReady(role,now)
        if not ready then return false,role..": "..reason end
    end
    for _,primary in ipairs(UNITS) do
        local controller=self.controllers[UNIT_CONTROLLER[primary]]
        if controller.status.directionVerified~=true then return false,primary..": DIRECTION LINK UNVERIFIED" end
        local sensor=self.units[primary]
        if not self:fresh(sensor,now) or not sensor.status or sensor.status.available~=true or
            #sensor.status.readings==0 then return false,primary..": SHAFT SPEED UNAVAILABLE" end
        for _,reading in ipairs(sensor.status.readings) do
            if not reading.validity or reading.validity.speedRaw~=true or not finite(reading.speedRaw) then
                return false,primary..": SHAFT SPEED UNAVAILABLE"
            end
        end
    end
    return true
end

-- Section: Endpoint context | Configuration, discovery and command identity.
-- Summary: Apply the accepted propulsion-enabled state, saved to config.json, and its control handover.
function Thrust:setEnabled(io,now,controls,enabled,storage,dependencies,reason)
    if enabled then
        -- Propulsion stays off until START SYSTEMS reaches READY (io.systemsReady).
        if io.systemsReady~=true then return false,"START SYSTEMS NOT READY" end
        local ready,why=self:activationReady(io,now,controls)
        if not ready then return false,why end
    end
    if not enabled then self:stop(io,reason or "PROPULSION DISABLED BY OPERATOR") end
    if not storage then return false,"CONFIGURATION STORAGE UNAVAILABLE" end
    local candidate=copy(io.config);candidate.thrust.enabled=enabled==true
    local ok,reason=storage.validateConfig(candidate)
    if ok then
        if type(storage.saveConfigChanges)=="function" then
            ok,reason=storage.saveConfigChanges("/avionics/config.json",io.config,
                {{path={"thrust","enabled"},value=enabled==true}},dependencies)
        else ok,reason=storage.writeJson("/avionics/config.json",candidate,dependencies) end
    end
    if not ok then
        if not enabled then self.config.thrust.enabled=false end
        return false,"PROPULSION SETTING NOT SAVED: "..tostring(reason)
    end
    self.config.thrust.enabled=enabled==true
    self:resetSpeedLoop();self:resetManualAccelerationLoop();self:resetHeadingLoop()
    if enabled then
        -- Levers act at their current position; a held throttle raises THRUST NOT NEUTRAL.
        controls.request=0;controls.yaw=0;controls.holds={}
        if type(controls.noteHandover)=="function" then controls:noteHandover() end
    end
    return true,enabled and "PROPULSION ENABLED" or "PROPULSION DISABLED"
end

-- Section: Drive demand | Bounded feedback and maneuver mixing.
-- Summary: Apply the configured primary-propeller turn assistance to mixed demands.
function Thrust.assistPrimaryTurn(left,right,yaw)
    yaw=-yaw -- Match the corrected physical steering direction.
    local reduction=.05*clamp((math.abs(yaw)-.75)/.25,0,1)
    local adjustedLeft,adjustedRight=left,right
    -- Remove a little opposing yaw torque. Reverse thrust swaps the engine
    -- to reduce; this never reverses, increases or starts a primary engine.
    if yaw*left<0 then adjustedLeft=left*(1-reduction) end
    if yaw*right>0 then adjustedRight=right*(1-reduction) end
    return adjustedLeft,adjustedRight,reduction
end

-- Section: Endpoint context | Configuration, discovery and command identity.
-- Summary: Build bounded per-controller drive targets from current cockpit and guidance demand.
function Thrust:makeTargets(io,now,controls,sideDemand)
    local mode=controls and controls.modes and controls.modes.throttle or "MANUAL"
    local c=self.config.thrust or {}
    self.request={}; self.saturated=false
    if controls and finite(controls.request) then self.request.pilotDemand=clamp(controls.request,-1,1) end
    local gateOpen,gateReason=commandGate(io,now)
    if not gateOpen then return nil,gateReason end
    if not controls or controls.available~=true then return nil,controls and controls.reason or "COCKPIT INPUTS UNAVAILABLE" end
    if io.anchor=="ANCHORED" or io.anchor=="BRAKING" then return nil,"ANCHOR SUPPRESSES PROPULSION" end
    local configReason=directConfigReason(self.config)
    if configReason then return nil,configReason end
    local side=sideDemand
    if side==nil then side=controls.sideways or 0 end
    if not finite(side) or math.abs(side)>1 then return nil,"LATERAL DEMAND OUT OF BOUNDS" end
    self.request.sideDemand=side
    local yaw=self:headingDriveDemand(io,now,controls)
    if not finite(yaw) or math.abs(yaw)>1 then return nil,"YAW DEMAND OUT OF BOUNDS" end
    self.request.yawDemand=yaw
    if controls.lateral and not controls.anchorAuthority and not controls.routeLateralAuthority and sideDemand==nil then
        side=controls.lateral:evaluate(io,now,controls,yaw)
        self.request.sideDemand=side
    end
    local mixer=c.mixer_verified==true and c.lateral_mixer or nil
    if (controls.anchorAuthority or controls.routeLateralAuthority or controls.lateral) and mixer then
        mixer=copy(mixer)
        -- Manual sideways input was previously disabled by zero side gains.
        -- Anchor uses the same verified fixed-direction pairs for translation.
        for _,quad in ipairs(LATERAL_QUADS) do if mixer[quad] then mixer[quad].side_gain=1 end end
    end
    -- The balance applies to every sideways source and runs before the route
    -- authority reserves yaw capacity, so the reservation uses the balanced gains.
    if mixer then
        mixer=Thrust.balanceStrafe(mixer,Registry.number(c,"thrust.front_back_strafe_percent"))
    end
    if controls.routeLateralAuthority and mixer then
        -- Reserve the differential yaw demand first. Translation receives only
        -- the remaining capacity, avoiding asymmetric clipping and unwanted yaw.
        local sideLimit=1
        for _,quad in ipairs(LATERAL_QUADS) do
            local entry=mixer[quad]
            if entry and entry.side_gain>0 then
                sideLimit=math.min(sideLimit,math.max(0,1-math.abs(entry.yaw_gain*yaw))/entry.side_gain)
            end
        end
        side=clamp(side,-sideLimit,sideLimit)
        self.request.sideDemand=side
    end
    local lateral,limited=Thrust.mixLateral(side,yaw,mixer)
    if not lateral then
        self:setHeadingUnavailable(limited,controls.modes and controls.modes.heading or "MANUAL",
            controls.targets and controls.targets.heading,io.vessel and io.vessel.heading)
        lateral={}
        for _,quad in ipairs(LATERAL_QUADS) do
            lateral["lateral-"..quad.."-p"]=0; lateral["lateral-"..quad.."-s"]=0
        end
    end
    self.saturated=limited==true
    local lateralMaximum=finite(c.lateral_max_rpm) and c.lateral_max_rpm/256 or 1
    for drive,value in pairs(lateral) do lateral[drive]=value*lateralMaximum end
    local targets=zeroTargets()
    if controls.apPrimaryIdle==true then
        if not self.apPrimaryIdle then
            self:resetSpeedLoop()
            self:resetManualAccelerationLoop()
        end
        self.request.primaryIdle=true
        self.request.directDriveRequest=0
        self.request.throttleReason="PRIMARY ENGINES IDLE"
        self.speedControl={state="IDLE",controlStatus="IDLE",available=true,
            output=0,measuredSpeed=(io.vessel or {}).forwardSpeed}
    elseif controls.holdPropulsion==true then
        self:resetSpeedLoop();self:resetManualAccelerationLoop()
        self.request.throttleReason=controls.holdReason or "PROPULSION HELD"
    elseif mode=="MANUAL" then
        local output=self:manualAccelerationDriveRequest(io,now,controls)
        targets["primary-left"],targets["primary-right"]=
            output.left,output.right
        self.request.manualDriveOutput={left=output.left,right=output.right}
        self.request.manualAcceleration=self.manualAcceleration.targetAcceleration
        self.request.measuredAcceleration=self.manualAcceleration.measuredAcceleration
        self.request.manualAccelerationOutput=self.manualAcceleration.driveOutput
        self.request.manualAccelerationState=self.manualAcceleration.state
    elseif mode=="SEL" then
        local driveRequest,why=self:speedDriveRequest(io,now,controls)
        if driveRequest==nil then
            targets["primary-left"],targets["primary-right"]=0,0
            self.request.throttleReason=why
        else targets["primary-left"],targets["primary-right"]=driveRequest,driveRequest end
        self.request.speedTarget=controls.targets.speed
        self.request.speedTargetRate=c.speed_target_rate_bps2
        self.request.speedOutput=self.speedControl.output
        self.request.speedDriveRequest=driveRequest
    elseif mode=="DIRECT" then
        local reason=directConfigReason(self.config)
        local demand=finite(controls.request) and clamp(controls.request,-1,1) or 0
        local driveRequest=0
        if reason then self.request.throttleReason=reason
        else
            driveRequest=demand*c.direct_max_request
            if not finite(driveRequest) or driveRequest< -1 or driveRequest>1 then
                self.request.throttleReason="DIRECT DRIVE REQUEST OUT OF BOUNDS"; driveRequest=0
            end
        end
        targets["primary-left"],targets["primary-right"]=driveRequest,driveRequest
        self.request.directDriveRequest=driveRequest
    else return nil,"UNKNOWN THROTTLE MODE" end
    self.apPrimaryIdle=controls.apPrimaryIdle==true
    -- START SYSTEMS idle: until the systems run reaches HOLDING, the primary
    -- propellers do not try to hold a speed (MANUAL neutral or SEL near 0).
    -- Climb, pitch and drift distort the speed readings during launch and
    -- made the speed loops reverse the whole time. Deliberate pilot input
    -- (lever off neutral, a non-zero selected speed, or DIRECT) still drives.
    local idleReason=nil
    if io.propulsionHoldSuppressed and mode~="DIRECT" then
        local pilot=finite(controls.request) and math.abs(controls.request) or 0
        local selected=controls.targets and controls.targets.speed
        local neutral=(mode=="MANUAL" and pilot<0.05) or
            (mode=="SEL" and (not finite(selected) or math.abs(selected)<0.1))
        if neutral then
            targets["primary-left"],targets["primary-right"]=0,0
            self:resetSpeedLoop();self:resetManualAccelerationLoop()
            idleReason=io.propulsionHoldSuppressed.." ("..mode..")"
            self.request.throttleReason=idleReason
        end
    end
    if type(io.logState)=="function" then io:logState("propulsion idle",idleReason) end
    local left,right,reduction=Thrust.assistPrimaryTurn(targets["primary-left"],targets["primary-right"],yaw)
    -- Preserve primary idle through the final turn-assist output selection.
    if controls.apPrimaryIdle==true or idleReason or (mode=="SEL" and self.speedControl.zeroCoast==true) then left,right,reduction=0,0,0 end
    targets["primary-left"],targets["primary-right"]=left,right
    self.request.primaryTurnAssist={reductionFraction=reduction,left=left,right=right}
    if mode=="DIRECT" then
        self.request.directRpm=(left+right)*128
        self.request.directRpmBySide={left=left*256,right=right*256}
    end
    for drive,value in pairs(lateral) do targets[drive]=value end
    if limited then self.saturated=true end
    return targets
end

-- Section: Output operations | Verified targets applied under current authority.
-- Summary: Release active propulsion demand and send endpoint stop commands.
function Thrust:stop(io,reason)
    self.commandGeneration=(self.commandGeneration or 0)+1
    local sent=false
    for _,role in ipairs(CONTROLLERS) do
        local node=self.controllers[role]
        if node and (self.active or next(node.requested or {})) then
            sent=self:sendStopTo(io,node,reason or "PROPULSION STOP") or sent
        end
    end
    self.active=false; self.available=false; self.saturated=false; self.lastCommandAt=nil
    self.reversal={}
    self.requested={}; self.reason=clean(reason or "PROPULSION STOP",160)
    if self.reason=="ZERO PROPULSION DEMAND" then
        clearPropulsionIssue(self,"Core propulsion recovered: zero demand is available")
    elseif self.reason~="PROPULSION STOP" and self.reason~="EMERGENCY LIFT KILL" then
        logPropulsionIssue(self,self.reason)
    end
    return sent
end

-- Summary: Validate and transmit the current drive target maps.
function Thrust:send(io,now,targets)
    local generation=self.commandGeneration or 0
    local gateOpen,gateReason=commandGate(io,now)
    if not gateOpen then return false,gateReason end
    if not io.rednet or type(io.rednet.send)~="function" then
        self:stop(io,"THRUST RADIO UNAVAILABLE"); return false,"THRUST RADIO UNAVAILABLE"
    end
    local selected={}
    for _,role in ipairs(CONTROLLERS) do selected[role]={} end
    local expected=0
    for _,drive in ipairs(DRIVES) do
        local value=targets[drive]
        if not finite(value) then return false,"INCOMPLETE SEMANTIC DRIVE MAP" end
        local isPrimary=drive:match("^primary%-")~=nil
        if (isPrimary and (value< -1 or value>1)) or (not isPrimary and (value<0 or value>1)) then
            return false,"PROPULSION DEMAND OUT OF BOUNDS"
        end
        expected=expected+1
        selected[DRIVE_CONTROLLER[drive]][drive]=value
    end
    local count=0
    for drive in pairs(targets) do if not inList(DRIVES,drive) then return false,"UNKNOWN SEMANTIC DRIVE" end; count=count+1 end
    if count~=expected then return false,"INCOMPLETE SEMANTIC DRIVE MAP" end
    local function hasNonzero(map)
        for _,value in pairs(map or {}) do if math.abs(value)>0.000001 then return true end end
        return false
    end
    local sendRoles={}
    for _,role in ipairs(CONTROLLERS) do
        local node=self.controllers[role]
        local roleTargets=selected[role]
        local requested=hasNonzero(roleTargets)
        local wasActive=hasNonzero(node and node.requested)
        if requested then
            local ready,reason=self:controllerReady(role,now)
            if not ready then self:stop(io,reason); return false,reason end
            sendRoles[#sendRoles+1]=role
        elseif wasActive and node then
            local ready=self:controllerReady(role,now)
            if ready then sendRoles[#sendRoles+1]=role
            else self:sendStopTo(io,node,"ZERO TARGET / STATUS UNAVAILABLE") end
        elseif node then
            local ready=self:controllerReady(role,now)
            if ready then sendRoles[#sendRoles+1]=role end
        end
    end
    local sentRoles={}
    local maxSeq=(self.config.network or {}).max_sequence or 2147483647
    for _,role in ipairs(sendRoles) do
        if generation~=(self.commandGeneration or 0) then return false,"PROPULSION COMMAND CANCELLED" end
        local roleTargets=selected[role]
        local node=self.controllers[role]
        self:updateCommandRecovery(node,now)
        local seq=(node.lastIssuedSeq or 0)+1
        if not integer(seq,1,maxSeq) then self:stop(io,"THRUST COMMAND SEQUENCE EXHAUSTED"); return false,"THRUST COMMAND SEQUENCE EXHAUSTED" end
        local packet={v=1,kind="thrust_command",session=io.session,seq=seq,nodeBoot=node.boot,
            role=role,targets=roleTargets,issuedAtEpochMs=os.epoch and os.epoch("utc") or nil,ttlSeconds=self.config.thrust.command_ttl_seconds}
        local primary=role=="thrust-ls" and "primary-left" or (role=="thrust-rs" and "primary-right" or nil)
        if primary then
            local target=roleTargets[primary] or 0
            local current=node.status and node.status.direction
            local phase=node.status and node.status.directionPhase
            local desired=target>0.000001 and "forward" or (target< -0.000001 and "reverse" or nil)
            if desired and node.status.directionVerified~=true then
                local reason="PRIMARY DIRECTION LINK UNVERIFIED: "..primary
                self:stop(io,reason);return false,reason
            end
            if phase=="FAULT" then
                local reason="PRIMARY DIRECTION CONTROL FAULT: "..primary
                self:stop(io,reason);return false,reason
            end
            local changing=desired~=nil and (phase=="SWITCHING" or
                (current~="forward" and current~="reverse") or current~=desired)
            local sensor=self.units[primary]
            local sensorStatus=sensor and sensor.status
            local zeroReady=false
            if changing and self:fresh(sensor,now) and sensorStatus and sensorStatus.available==true and
                type(sensorStatus.readings)=="table" and #sensorStatus.readings>0 then
                zeroReady=true
                for _,reading in ipairs(sensorStatus.readings) do
                    if not reading.validity or reading.validity.speedRaw~=true or reading.speedRaw~=0 then
                        zeroReady=false;break
                    end
                end
            end
            -- Keep issuing the signed desired target while permission is
            -- false. The chamber's direction worker ramps this shaft to zero,
            -- waits its one-second dwell and switches only with fresh zero-RPM
            -- permission. Steering remains independently commanded throughout.
            self.reversal[primary]=changing and {state=zeroReady and "ZERO_DWELL" or "RAMPING_TO_ZERO",
                desiredDirection=desired,reason=zeroReady and "WAITING FOR GEARSHIFT DWELL" or
                    "WAITING FOR FRESH ZERO SHAFT SPEED"} or nil
            packet.primaryDirectionReady=zeroReady
        end
        local ok,result=pcall(io.rednet.send,node.id,packet,self.config.protocol)
        if not ok or result==false then
            self:stop(io,"THRUST RADIO SEND FAILED")
            return false,"THRUST RADIO SEND FAILED"
        end
        if generation~=(self.commandGeneration or 0) then
            self:sendStopTo(io,node,"PROPULSION COMMAND CANCELLED");return false,"PROPULSION COMMAND CANCELLED"
        end
        node.lastIssuedSeq,node.requested,node.lastCommandAt=seq,copy(roleTargets),now
        node.commandHistory=node.commandHistory or {}
        node.commandHistory[seq]=copy(roleTargets)
        node.commandHistory[seq-64]=nil
        if node.commandRecovery then node.commandRecovery.attempts=node.commandRecovery.attempts+1 end
        sentRoles[#sentRoles+1]=role
    end
    self.requested=copy(targets); self.active=true; self.reason=nil; self.lastCommandAt=now
    self.available=true
    clearPropulsionIssue(self,"Core propulsion recovered: drive command accepted")
    return true,sentRoles
end

-- Position guidance pauses while fresh backup heading and signed speed
-- continue to brake the vessel. Route and anchor points remain unchanged.
-- Section: Endpoint context | Configuration, discovery and command identity.
-- Summary: Position guidance pauses while fresh backup heading and signed speed continue to brake the vessel. Route and anchor points remain unchanged.
function Thrust:positionFallbackControls(io,now,controls,headingTarget)
    local v=io.vessel or {}
    if io.identityReady~=true or v.positionUnavailable~=true or not v.valid or not finite(v.heading) or not finite(v.forwardSpeed) or
        not finite(v.at) or now<v.at or now-v.at>(self.config.network.sensor_stale_seconds or 6) or
        not controls or controls.available~=true then return nil end
    local proxy={};for k,x in pairs(controls) do proxy[k]=x end
    proxy.modes=copy(controls.modes);proxy.targets=copy(controls.targets)
    proxy.modes.heading="SEL";proxy.modes.throttle="SEL"
    if not self.positionPauseHeading or self.positionPauseUuid~=v.uuid then self.positionPauseHeading=v.heading;self.positionPauseUuid=v.uuid end
    proxy.targets.heading=finite(headingTarget) and headingTarget or self.positionPauseHeading;proxy.targets.speed=0
    proxy.headingTargetUuid=v.uuid;proxy.speedTargetUuid=v.uuid
    proxy.holdPropulsion=false;proxy.request=0;proxy.yaw=0;proxy.sideways=0
    proxy.routeSpeedAuthority=nil;proxy.routeLateralAuthority=true
    return proxy
end
-- Summary: Advance propulsion feedback, reversal handling and endpoint command delivery.
function Thrust:update(io,now,controls,sideDemand)
    local environment=(io.vessel or {}).environment
    if environment and finite(environment.airPressure) and environment.airPressure>0 then self.airPressure=environment.airPressure end
    if not (io.vessel or {}).positionUnavailable then self.positionPauseHeading=nil;self.positionPauseUuid=nil end
    if not finite(now) then return false,"INVALID CLOCK" end
    if io.autopilot and io.autopilot.active then
        local effective,why=io.autopilot:update(io,now,controls)
        if effective then self.routeHold={controls=effective,at=now}
        elseif why=="ABSOLUTE POSITION UNAVAILABLE; SENSOR FALLBACK" then
            -- A short position gap keeps the last route guidance (heading and
            -- speed) instead of braking; every brake-and-resume cycle cost
            -- 10+ s of thrust reversal. Longer gaps still brake.
            local hold=self.routeHold
            local limit=finite((self.config.navigation or {}).position_gap_hold_seconds) and
                self.config.navigation.position_gap_hold_seconds or 8
            if hold and now>=hold.at and now-hold.at<=limit then effective=hold.controls
            else self.routeHold=nil;effective=self:positionFallbackControls(io,now,controls,io.autopilot.headingTarget) end
        else self.routeHold=nil end
        if not effective then self:stop(io,why);return false,why end
        controls=effective;sideDemand=effective.sideways
    end
    if io.positionAnchor and io.positionAnchor.active then
        local effective,why=io.positionAnchor:update(io,now,controls)
        if not effective and why=="ABSOLUTE POSITION UNAVAILABLE; SENSOR FALLBACK" then effective=self:positionFallbackControls(io,now,controls,controls.targets and controls.targets.heading) end
        if not effective then self:stop(io,why);return false,why end
        controls=effective;sideDemand=effective.sideways
    end
    if type(io.assemblyGate)=="function" then
        local assembled,why=io:assemblyGate(now)
        if not assembled then
            self.available=false;self.reason=clean(why or "VESSEL DISASSEMBLED",160)
            self:stop(io,self.reason)
            return false,self.reason
        end
    end
    local newMode=controls and controls.modes and controls.modes.throttle or "MANUAL"
    if newMode~=self.lastThrottleMode then
        self:resetSpeedLoop()
        self:resetManualAccelerationLoop()
        if newMode~="SEL" then
            self.speedControl={state="DISABLED",controlStatus="UNAVAILABLE",available=false,
                reason="THROTTLE MODE NOT SEL",saturated=false}
        else
            self.manualAcceleration={state="UNAVAILABLE",available=false,
                reason="THROTTLE MODE NOT MANUAL",saturated=false}
        end
        self.lastThrottleMode=newMode
    end
    local newHeadingMode=controls and controls.modes and controls.modes.heading or "MANUAL"
    if newHeadingMode~=self.lastHeadingMode then
        self:resetHeadingLoop()
        self.lastHeadingMode=newHeadingMode
    end
    self.mode=newMode
    local targets,reason=self:makeTargets(io,now,controls,sideDemand)
    if not targets then
        if self.mode=="SEL" then
            self:setSpeedUnavailable(reason,controls and controls.targets and controls.targets.speed,
                io.vessel and io.vessel.forwardSpeed)
        end
        self:setHeadingUnavailable(reason,newHeadingMode,
            controls and controls.targets and controls.targets.heading,io.vessel and io.vessel.heading)
        if newMode=="MANUAL" then
            self:setManualAccelerationUnavailable(reason,self.manualAcceleration.targetAcceleration,
                self.manualAcceleration.measuredAcceleration)
        end
        self:stop(io,reason)
        return false,reason
    end
    local hasDemand=false
    for _,value in pairs(targets) do if math.abs(value)>0.000001 then hasDemand=true end end
    if not hasDemand then
        -- An idle core can boot before any peer is discovered. Once peers are
        -- known, renew zero commands instead of turning idle into a stop fault.
        local same=true
        for _,drive in ipairs(DRIVES) do if targets[drive]~=self.requested[drive] then same=false;break end end
        local interval=math.min(.2,(self.config.thrust.command_ttl_seconds or 1)/4)
        local renewalDue=not same or not finite(self.lastCommandAt) or now<self.lastCommandAt or now-self.lastCommandAt>=interval
        if next(self.controllers) and renewalDue then
            local sent,why=self:send(io,now,targets)
            if not sent then return false,why end
        end
        self.active=false
        clearPropulsionIssue(self,"Core propulsion recovered: zero demand is available")
        self.available=true; self.reason="ZERO PROPULSION DEMAND"
        return true
    end
    local interval=math.min(.2,(self.config.thrust.command_ttl_seconds or 1)/4)
    local same=self.active
    for _,drive in ipairs(DRIVES) do if targets[drive]~=self.requested[drive] then same=false; break end end
    if same and finite(self.lastCommandAt) and now>=self.lastCommandAt and now-self.lastCommandAt<interval then
        self.available=true; self.reason=nil
        return true
    end
    local sent,detail=self:send(io,now,targets)
    if not sent and self.mode=="SEL" then
        self:setSpeedUnavailable(detail,controls.targets and controls.targets.speed,
            io.vessel and io.vessel.forwardSpeed)
    end
    if not sent then
        self:setHeadingUnavailable(detail,newHeadingMode,
            controls.targets and controls.targets.heading,io.vessel and io.vessel.heading)
        if newMode=="MANUAL" then
            self:setManualAccelerationUnavailable(detail,self.manualAcceleration.targetAcceleration,
                self.manualAcceleration.measuredAcceleration)
        end
    end
    return sent,detail
end

local function backgroundRenewal(reason)
    return type(reason)=="string" and
        (reason:find("COMMAND LEASE EXPIRED",1,true) or reason:find("COMMAND_LEASE_EXPIRED",1,true) or
         reason:find("COMMAND RENEWAL FAILED",1,true) or reason:find("COMMAND RECOVERY FAILED",1,true) or
         reason:find("REAPPLYING CORE PROPULSION TARGETS",1,true))~=nil
end
-- Section: Readbacks | Timestamped physical observations and status.
-- Summary: Build one controller's status, command and readback details.
function Thrust:controllerSnapshot(role,now)
    local node=self.controllers[role]
    self:updateCommandRecovery(node,now)
    local status=node and node.status or nil
    local fresh=self:fresh(node,now)
    local ready,reason=self:controllerReady(role,now)
    local readbackAge=status and finite(status.readbackAgeSeconds) and node and finite(node.statusAt) and
        now>=node.statusAt and status.readbackAgeSeconds+(now-node.statusAt) or nil
    local readbackFresh=finite(readbackAge) and readbackAge<=self:staleSeconds() or false
    if readbackFresh then
        for _,drive in ipairs(CONTROLLER_DRIVES[role]) do
            local value=status.readbacks and status.readbacks[drive]
            if not value or value.valid~=true then readbackFresh=false; break end
        end
    end
    local statusReason=status and status.reason or nil
    local statusFaults=status and copy(status.faults or {}) or {}
    if statusReason=="NEW CORE SESSION" and fresh then
        statusReason=nil
        local faults={}
        for _,fault in ipairs(statusFaults) do
            if fault~="NEW CORE SESSION" then faults[#faults+1]=fault end
        end
        statusFaults=faults
        if not ready then
            if status.configValid~=true then reason="CONTROLLER CONFIG INVALID"
            elseif status.bindingReady~=true then reason="CONTROLLER BINDING UNVERIFIED"
            elseif status.enabled~=true or status.writerEnabled~=true then reason="CONTROLLER DISABLED"
            elseif not finite(readbackAge) or readbackAge>self:staleSeconds() then
                reason=Thrust.staleText(string.upper(role),"READBACK",readbackAge)
            else
                for _,drive in ipairs(CONTROLLER_DRIVES[role]) do
                    local value=status.readbacks and status.readbacks[drive]
                    if not value or value.valid~=true then
                        reason="CONTROLLER DRIVE READBACK INVALID: "..drive
                        break
                    end
                end
                if reason=="NEW CORE SESSION" then reason="CONTROLLER NOT READY" end
            end
        end
    end
    local statusAge=node and node.statusAt and now>=node.statusAt and math.max(0,now-node.statusAt) or nil
    local out={label=role,role=role,endpointKind="controller",nodeId=node and node.id,discovered=node~=nil,
        online=fresh,available=ready,statusFresh=fresh,statusAgeSeconds=statusAge,
        readbackAgeSeconds=status and status.readbackAgeSeconds or nil,readbackFresh=readbackFresh,
        readbackStaleAfterSeconds=self:staleSeconds(),staleAfterSeconds=self:staleSeconds(),boot=node and node.boot,drives=copy(node and node.drives or {}),
        requested=copy(node and node.requested or {}),reason=node and node.quarantined and "DUPLICATE ROLE QUARANTINED" or
            (not fresh and (node and node.statusReason or (status and Thrust.staleText(string.upper(role),"STATUS",statusAge) or
                string.upper(role).." NO STATUS SINCE CORE START")) or (ready and nil or reason))}
    out.lastRejected=self.rejections and copy(self.rejections[role]) or nil
    if node and node.commandRecovery then
        local recovery=node.commandRecovery
        out.recovery={state="RETRYING ("..(recovery.attempts or 0)..")",reason=recovery.reason,
            elapsedSeconds=math.max(0,now-recovery.since),attempts=recovery.attempts}
        out.recovery.background=true -- Diagnostics only; retries do not create a bridge fault.
    end
    out.thrustControlState="FAULT"
    if status then
        out.thrustControlState=(fresh and ready and readbackFresh) and (status.thrustControlState or "RDY") or "FAULT"
        out.ready=fresh and status.ready or false; out.enabled=status.enabled; out.configValid=status.configValid
        out.bindingReady=status.bindingReady; out.writerEnabled=status.writerEnabled; out.phase=status.phase
        out.applied=readbackFresh and copy(status.applied) or nil; out.readbacks=copy(status.readbacks)
        out.saturated=status.saturated; out.direction=status.direction; out.directionVerified=status.directionVerified
        out.faults=statusFaults; out.fault=out.fault or out.reason or statusReason or out.faults[1]
        out.lastReceivedSeq=status.lastReceivedSeq; out.lastAppliedSeq=status.lastAppliedSeq
        out.ackSeq=status.ackSeq; out.ackAccepted=status.ackAccepted; out.statusSeq=status.seq
        out.lastIssuedSeq=node.lastIssuedSeq or 0
        out.commandPending=(out.lastIssuedSeq>0 and (status.ackSeq or -1)<out.lastIssuedSeq) or false
        out.commandAcknowledged=(out.lastIssuedSeq>0 and status.ackSeq==out.lastIssuedSeq and status.ackAccepted==true) or false
        local primary=role=="thrust-ls" and "primary-left" or (role=="thrust-rs" and "primary-right" or nil)
        local readback=primary and status.readbacks and status.readbacks[primary]
        if fresh and readbackFresh and readback and readback.valid==true then
            out.appliedTransmissionLevel=readback.shiftLevel
            out.appliedTransmissionLevelValid=true
            out.appliedTransmissionLevelUnit="incremental_level_0_to_256"
        else out.appliedTransmissionLevelValid=false end
    end
    if backgroundRenewal(out.reason) then out.reason=nil end
    if backgroundRenewal(out.fault) then out.fault=nil end
    if type(out.faults)=="table" then
        local visible={}
        for _,fault in ipairs(out.faults) do if not backgroundRenewal(fault) then visible[#visible+1]=fault end end
        out.faults=visible
        out.fault=out.fault or visible[1]
    end
    return out
end

-- Summary: Build one propulsion-data unit's cached reading and freshness report.
function Thrust:unitSnapshot(role,now)
    local node=self.units[role]
    local status=node and node.status or nil
    local fresh=self:fresh(node,now)
    local statusAge=node and node.statusAt and now>=node.statusAt and math.max(0,now-node.statusAt) or nil
    return {label=role,role=role,endpointKind="sensor",associatedController=UNIT_CONTROLLER[role],
        discovered=node~=nil,online=fresh,available=fresh and status and status.available==true or false,
        reason=node and node.quarantined and "DUPLICATE ROLE QUARANTINED" or
            (not fresh and (node and node.statusReason or (status and Thrust.staleText(string.upper(role),"STATUS",statusAge) or
                string.upper(role).." NO STATUS SINCE CORE START")) or (status and status.reason)),
        statusFresh=fresh,statusAgeSeconds=statusAge,
        staleAfterSeconds=self:staleSeconds(),boot=node and node.boot,seq=status and status.seq,
        readings=status and copy(status.readings) or {},faults=status and copy(status.faults) or {},
        lastRejected=self.rejections and copy(self.rejections[role]) or nil}
end

-- Summary: Expose the configured propulsion settings and verified operating limits.
function Thrust:settingsSnapshot(now)
    local c=self.config.thrust or {}
    local manual=type(c.manual_acceleration)=="table" and c.manual_acceleration or {}
    local rpmLimits=type(c.primary_rpm_limits)=="table" and c.primary_rpm_limits or {}
    local requestVerified=c.enabled==true and c.limits_verified==true and c.mapping_verified==true and
        finite(c.direct_max_request) and c.direct_max_request>0 and c.direct_max_request<=1
    local speedControl=self.speedControl or {}
    local result={enabled=c.enabled==true,limitsVerified=c.limits_verified==true,mappingVerified=c.mapping_verified==true,
        directMaximumDriveRequest=requestVerified and c.direct_max_request or nil,
        directDriveRequestUnit="fraction_of_configured_drive_range",
        directRpmVerified=c.primary_input_rpm==256,directRpmCalibrationAvailable=c.primary_input_rpm==256,
        primaryMaximumRpm=c.primary_max_rpm,primaryInputRpm=c.primary_input_rpm,
        primaryTurnAssistMaximumPercent=5,primaryTurnAssistThresholdPercent=75,
        manualAccelerationVerified=c.manual_acceleration_verified==true,
        manualAccelerationConfigured=c.manual_acceleration_enabled==true or c.manual_acceleration_verified==true,
        manualAccelerationAvailable=self.manualAcceleration.available==true,
        manualAccelerationState=self.manualAcceleration.state,
        manualAccelerationReason=self.manualAcceleration.reason,
        speedControlVerified=c.speed_control_verified==true,
        speedControlConfigured=false,speedControlAvailable=speedControl.available==true,
        speedControlState=speedControl.state or "DISABLED",speedControlReason=speedControl.reason,
        headingControlVerified=c.heading_control_verified==true,
        headingControlAvailable=self.headingControl.available==true,
        headingControlState=self.headingControl.state,
        headingControlReason=self.headingControl.reason,
        mixerVerified=c.mixer_verified==true,lateralMixerVerified=c.mixer_verified==true,
        commandTtlSeconds=c.command_ttl_seconds,statusStaleSeconds=self:staleSeconds(),
        reverseVerified=false,primaryRpmLimits=copy(c.primary_rpm_limits),roles={},lateralMaximumRpm=c.lateral_max_rpm}
    if not result.speedControlAvailable and not result.speedControlReason then
        result.speedControlReason="THROTTLE MODE NOT SEL"
    end
    if result.manualAccelerationConfigured and finite(manual.minimum) and finite(manual.maximum) then
        result.manualMinimumAccelerationBps2=manual.minimum
        result.manualMaximumAccelerationBps2=manual.maximum
    end
    local cockpit=self.config.cockpit or {}
    result.speedControlConfigured=(result.speedControlVerified or c.speed_control_enabled==true) and self.config.geometry and
        self.config.geometry.velocity_frame_verified==true and finite(c.speed_target_rate_bps2) and
        c.speed_target_rate_bps2>0 and type(c.speed_pid)=="table" and finite(c.speed_pid.kp) and
        finite(c.speed_pid.ki) and finite(c.speed_pid.kd) and finite(c.speed_pid.integral_limit) and
        c.speed_pid.integral_limit>0 and finite(c.speed_pid.derivative_filter_seconds) and
        c.speed_pid.derivative_filter_seconds>0 and finite(cockpit.minimum_selected_speed) and
        finite(cockpit.maximum_selected_speed) and
        cockpit.minimum_selected_speed<cockpit.maximum_selected_speed or false
    if result.speedControlConfigured then
        result.speedTargetRateBps2=c.speed_target_rate_bps2
    end
    if type(rpmLimits["primary-left"])=="table" and type(rpmLimits["primary-right"])=="table" and
        finite(rpmLimits["primary-left"].minimum) and finite(rpmLimits["primary-right"].minimum) and
        finite(rpmLimits["primary-left"].maximum) and finite(rpmLimits["primary-right"].maximum) then
        result.primaryRpmMinimum={left=rpmLimits["primary-left"].minimum,right=rpmLimits["primary-right"].minimum}
        result.primaryRpmMaximum={left=rpmLimits["primary-left"].maximum,right=rpmLimits["primary-right"].maximum}
        result.primaryRpmUnit="rpm"
    end
    local reverseReady=true
    for _,role in ipairs({"thrust-ls","thrust-rs"}) do
        local node=self.controllers[role]
        if not self:fresh(node,now) or not node.status or node.status.directionVerified~=true then reverseReady=false end
    end
    result.reverseVerified=reverseReady
    if c.primary_input_rpm==256 and finite(c.primary_max_rpm) then
        result.primaryRpmMinimum={left=-c.primary_max_rpm,right=-c.primary_max_rpm}
        result.primaryRpmMaximum={left=c.primary_max_rpm,right=c.primary_max_rpm}
        result.primaryRpmUnit="rpm"
    end
    for _,role in ipairs(CONTROLLERS) do
        local node=self.controllers[role]
        result.roles[role]={discovered=node~=nil,configValid=node and node.status and node.status.configValid or false,
            bindingReady=node and node.status and node.status.bindingReady or false,
            enabled=node and node.status and node.status.enabled or false,
            reason=node and (node.statusReason or node.status and node.status.reason) or "NO CONTROLLER STATUS"}
    end
    return result
end

-- Summary: Return the current bounded operation state and available status details.
function Thrust:snapshot(now)
    local result={mode=self.mode,available=false,reason=self.reason,saturated=self.saturated==true,
        request=copy(self.request),requested=copy(self.requested),roles={},units={},
        speedControl=self:speedSnapshot(now),
        headingControl=copy(self.headingControl or {}),
        manualAcceleration=copy(self.manualAcceleration or {}),reversal=copy(self.reversal)}
    for _,role in ipairs(CONTROLLERS) do result.roles[role]=self:controllerSnapshot(role,now) end
    for _,role in ipairs(UNITS) do result.units[role]=self:unitSnapshot(role,now) end
    result.available=self.available==true
    return result
end

-- Section: Endpoint context | Configuration, discovery and command identity.
-- Summary: Attach propulsion settings, feedback and role status to the display snapshot.
function Thrust:decorate(snapshot,now,io,controls)
    snapshot.thrust=self:snapshot(now)
    snapshot.settings=snapshot.settings or {}
    snapshot.settings.thrust=self:settingsSnapshot(now)
    if io and controls then
        local ready,why=self:activationReady(io,now,controls)
        if ready and io.systemsReady~=true then ready,why=false,"START SYSTEMS NOT READY" end
        if (snapshot.emergencyLift or {}).latched==true then
            ready=false;why="EMERGENCY LIFT KILL LATCHED"
        end
        snapshot.settings.thrust.enableAvailable=ready
        snapshot.settings.thrust.enableReason=why
    end
    local entries=snapshot.settings.entries
    if type(entries)=="table" then
        local values={
            {key="propulsion_manual_max_acceleration",label="Manual maximum acceleration",value=snapshot.settings.thrust.manualAccelerationVerified
                and snapshot.settings.thrust.manualMaximumAccelerationBps2 or nil,unit="blocks_per_second_squared"},
            {key="propulsion_speed_target_rate",label="Speed target rate",value=snapshot.settings.thrust.speedControlVerified
                and snapshot.settings.thrust.speedTargetRateBps2 or nil,unit="blocks_per_second_squared"},
            {key="propulsion_direct_rpm_min",label="Direct minimum RPM",value=snapshot.settings.thrust.primaryRpmMinimum,unit="rpm"},
            {key="propulsion_direct_rpm_max",label="Direct maximum RPM",value=snapshot.settings.thrust.primaryRpmMaximum,unit="rpm"},
        }
        for _,entry in ipairs(values) do entry.group="PROPULSION"; entries[#entries+1]=entry end
    end
    local control=snapshot.cockpitControl or {}
    control.propulsionAvailable=snapshot.thrust.available
    control.propulsionReason=snapshot.thrust.reason or (snapshot.thrust.available and "READY" or "PROPULSION DISENGAGED")
    control.headingControlAvailable=snapshot.thrust.headingControl.available==true
    control.headingControlReason=snapshot.thrust.headingControl.reason or
        (control.headingControlAvailable and "READY" or "HEADING CONTROL UNAVAILABLE")
    local direct=snapshot.thrust.request and snapshot.thrust.request.directRpm
    if finite(direct) then control.directRpm=direct end
    snapshot.cockpitControl=control
    return snapshot
end

Thrust.CONTROLLERS=CONTROLLERS
Thrust.UNITS=UNITS
Thrust.DRIVES=DRIVES
Thrust.CONTROLLER_DRIVES=CONTROLLER_DRIVES
Thrust.UNIT_CONTROLLER=UNIT_CONTROLLER
Thrust.normalizeReadings=normalizeReadings
Thrust.mixLateral=Thrust.mixLateral
return Thrust
