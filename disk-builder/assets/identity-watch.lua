-- Examines received traffic for conflicting core identities and publishes diagnostic observations.
local Watch={};Watch.__index=Watch
local MAX=2147483647
local function finite(v)return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function integer(v,lo,hi)return finite(v) and v%1==0 and v>=lo and v<=hi end
local function token(v)return type(v)=="string" and #v>0 and #v<=128 and v:match("^[%w_%.%-:]+$")~=nil end
local function bounded(v)return type(v)=="string" and #v>0 and #v<=128 and not v:find("[%c]") end
local function registered(io,id)
    for role,entry in pairs(io.computers or {}) do
        if type(entry)=="table" and entry.id==id then return role,entry end
    end
end
function Watch.new()
    return setmetatable({streams={},count=0,lastNow=nil},Watch)
end
-- Summary: Expire old identity claims and enforce the bounded observation history.
function Watch:prune(now)
    if not finite(now) then return false end
    if self.lastNow and now<self.lastNow then self.streams={};self.count=0 end
    self.lastNow=now
    for key,stream in pairs(self.streams) do
        if now-stream.last>20 then self.streams[key]=nil;self.count=self.count-1
        else
            for boot,row in pairs(stream.claims) do
                if now-row.last>20 then stream.claims[boot]=nil end
            end
        end
    end
    return true
end
-- Summary: Validate the received identity claim and extract its bounded comparison fields.
local function shape(io,sender,message)
    if message.v~=1 then return nil end
    local role,entry=registered(io,sender)
    if not role then return nil end
    if message.kind=="fleet_registry" then
        local core=type(message.computers)=="table" and message.computers.core
        if sender~=io.localID or role~="core" or message.coreID~=io.localID or
            message.session==io.session or not token(message.session) or type(core)~="table" or
            core.id~=io.localID or not token(core.label) or #core.label>64 then return nil end
        if message.identitySeq~=nil and not integer(message.identitySeq,1,MAX) then return nil end
        if message.identityEpochMs~=nil and not finite(message.identityEpochMs) then return nil end
        if message.identityVesselUUID~=nil and not bounded(message.identityVesselUUID) then return nil end
        return "core",message.session,message.identitySeq,role,message.identityVesselUUID,true
    end
    local kind=message.kind
    if kind=="role_status" then
        local expected=io.expectedPackages and io.expectedPackages[role]
        if message.role~=role or role=="core" or message.coreID~=io.localID or message.coreSession~=io.session or
            not expected or message.packageId~=expected.packageId or tonumber(message.version)~=expected.version or
            type(message.running)~="boolean" or type(message.hardwareAvailable)~="boolean" or
            type(message.faultSummary)~="string" or #message.faultSummary>384 then return nil end
        return "role:"..role,message.boot,message.seq,role
    elseif kind=="lift_status" then
        local q=message.quadrant;local node=io.nodes and io.nodes[q]
        if not node or node.id~=sender or message.id~=sender or message.session~=io.session then return nil end
        return "lift:"..tostring(q),message.boot,message.statusSeq,role
    elseif kind=="thrust_status" then
        local ids=io.thrust and io.thrust.roleIDs
        if not ids or ids[message.role]~=sender or message.session~=io.session or
            (message.endpointKind~="controller" and message.endpointKind~="sensor") then return nil end
        return "thrust:"..message.role,message.nodeBoot,message.seq,role
    elseif kind=="subsystem_status" then
        local expected=role=="navigator" and "bridge" or
            (role:match("^heading%-") and "heading" or nil)
        if not expected or message.role~=expected or message.label~=entry.label or message.session~=io.session or
            type(message.coreDataFresh)~="boolean" or type(message.monitorAttached)~="boolean" then return nil end
        return "display:"..role,message.boot,message.seq,role
    end
end
-- Summary: Compare competing registered identity claims and update advisory evidence.
function Watch:observe(io,sender,message,protocol,now,epochMs)
    if not io or io.identityReady~=true or not io.config or protocol~=io.config.protocol or
        not integer(sender,0,65535) or type(message)~="table" or not self:prune(now) then return false end
    local family,boot,seq,role,uuid,isCore=shape(io,sender,message)
    if not family or not token(boot) or (not isCore and not integer(seq,1,MAX)) then return false end
    if message.identityEpochMs~=nil then
        if not finite(epochMs) or epochMs<message.identityEpochMs or epochMs-message.identityEpochMs>10000 then return false end
        -- A surviving old packet from before this core started is not another
        -- live core. Repeated current claims from that core still qualify.
        if finite(io.identityStartedEpochMs) and message.identityEpochMs<io.identityStartedEpochMs then return false end
    end
    local key=tostring(sender)..":"..family
    local stream=self.streams[key]
    if not stream then
        if self.count>=64 then return false end
        stream={id=sender,role=role,claims={},last=now,isCore=isCore};self.streams[key]=stream;self.count=self.count+1
        if isCore then stream.localIdentity=io.session end
    end
    local row=stream.claims[boot]
    if row and seq and row.seq and seq<=row.seq then return false end
    if not row then
        local size=0;for _ in pairs(stream.claims)do size=size+1 end
        if size>=4 then return false end
        row={first=now,last=now,count=0};stream.claims[boot]=row
        if not isCore and size>0 then
            stream.overlapAt=now
            for _,claim in pairs(stream.claims) do claim.overlapCount=0;claim.overlapFirst=nil end
        end
    end
    -- Legacy core registries have no sequence. Count no faster than once per
    -- second, so a single burst or multi-modem duplicate cannot trigger it.
    if seq==nil and row.count>0 and now-row.last<1 then return false end
    row.count=math.min(1000,row.count+1);row.last=now;row.seq=seq;row.uuid=uuid
    stream.last=now
    if not isCore then
        if stream.overlapAt then
            row.overlapFirst=row.overlapFirst or now
            row.overlapCount=math.min(1000,(row.overlapCount or 0)+1)
        end
        local mature=0
        for _,claim in pairs(stream.claims) do
            if (claim.overlapCount or 0)>=3 and now-claim.last<=10 and claim.overlapFirst and
                claim.last-claim.overlapFirst>=2 then mature=mature+1 end
        end
        if mature>=2 then stream.conflictAt=now end
    elseif row.count>=3 and row.last-row.first>=2 then stream.conflictAt=now end
    return true
end
-- Summary: Return the current bounded operation state and available status details.
function Watch:snapshot(now)
    local result={active=false,alerts={},advisory=true}
    if not self:prune(now) then return result end
    local keys={};for key in pairs(self.streams)do keys[#keys+1]=key end;table.sort(keys)
    -- Core conflicts are the most useful explanation when an entire copied
    -- fleet is competing. Component streams remain separate evidence.
    table.sort(keys,function(a,b)
        local ca,cb=self.streams[a].isCore==true,self.streams[b].isCore==true
        if ca~=cb then return ca end;return a<b
    end)
    for _,key in ipairs(keys) do
        local stream=self.streams[key]
        if stream.conflictAt and now-stream.conflictAt<=20 then
            local evidence=stream.isCore and "ANOTHER CORE SESSION IS USING THIS ID" or "COMPETING BOOT IDENTITIES ARE REPORTING"
            local alert={id=stream.id,role=stream.role,text="POSSIBLE DUPLICATE ID #"..stream.id,
                detail=evidence,ageSeconds=now-stream.conflictAt,localIdentity=stream.localIdentity,claims={}}
            local boots={};for boot in pairs(stream.claims)do boots[#boots+1]=boot end;table.sort(boots)
            for _,boot in ipairs(boots)do
                local row=stream.claims[boot]
                alert.claims[#alert.claims+1]={identity=boot,sequence=row.seq,ageSeconds=now-row.last,vesselUUID=row.uuid}
            end
            result.alerts[#result.alerts+1]=alert
            if #result.alerts>=8 then break end
        end
    end
    result.active=#result.alerts>0
    if result.active then
        local first=result.alerts[1]
        result.text=first.text;result.id=first.id;result.role=first.role
        result.detail=first.detail.."; CHECK OTHER LOADED COPIES"
    end
    return result
end
return Watch
