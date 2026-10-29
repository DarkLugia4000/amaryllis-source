-- @ama-section: Local chamber link | Parent/child transport and shared sensor observations.
-- Chamber/engine transport. No actuator methods are called by this module.
local Link={protocol="amaryllis.v1"}
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function epoch() return os.epoch("utc") end
local function chamberLabel(config)
    local q=config.quadrant or ({chamber_fl="FL",chamber_fr="FR",chamber_bl="BL",chamber_br="BR"})[config.role]
    return ({RL="BL",RR="BR"})[q] or q or "UNKNOWN"
end
local function clone(v) if type(v)~="table" then return v end;local o={};for k,x in pairs(v) do o[k]=clone(x) end;return o end
function Link.peer(config,role)
    local r=os.__amaryllisFleetRegistry
    if type(r)~="table" or r.coreID~=config.coreId or type(r.computers)~="table" then return nil end
    local selfEntry=r.computers[config.role];local peer=r.computers[role]
    if not selfEntry or selfEntry.id~=os.getComputerID() or selfEntry.label~=config.label or not peer then return nil end
    return peer.id,r.session
end
-- @ama-section: Local chamber link | Parent/child transport and shared sensor observations.
-- @ama-summary: Resolve the underlying peripheral facade used by the chamber link.
function Link.unwrap(config,sender,envelope,nowMs)
    if type(envelope)~="table" or envelope.v~=1 or envelope.kind~="chamber_forward" or
        envelope.role~=config.role or type(envelope.packet)~="table" then return nil end
    local peer,session=Link.peer(config,config.coordinatorRole)
    local p=envelope.packet
    if sender~=peer or not peer or envelope.coreID~=config.coreId or p.session~=session then return nil end
    if p.role~=config.role and p.kind~="system_restart" then return nil end
    p=clone(p)
    if p.kind=="thrust_command" then
        if not finite(p.issuedAtEpochMs) or not finite(p.ttlSeconds) then return nil end
        local remaining=(p.issuedAtEpochMs+p.ttlSeconds*1000-nowMs)/1000
        if remaining<=0 or remaining>p.ttlSeconds then return nil end
        p.ttlSeconds=remaining
    elseif p.kind~="thrust_session" and p.kind~="thrust_stop" and p.kind~="system_restart" then return nil end
    return p
end
-- @ama-summary: Build the chamber-side service for its attached child endpoints.
function Link.parent(config)
    local rt=os.__amaryllisRuntime or {};os.__amaryllisRuntime=rt;rt.components=rt.components or {}
    local state={running=true,hardwareAvailable=false,faults={},snapshot={role=config.relayChildRole,phase="WAITING FOR THRUST"}}
    rt.components.thrust=state
    local boot,childLast,childSeq=nil,nil,-1
    local retired,order={},{}
    local altitudeSeq=-1
    -- @ama-summary: Publish the current cached component observations to the configured consumer.
    local function publish()
        local fresh=childLast and os.clock()-childLast<=1.5
        local responding=state.lastResponseAt and os.clock()>=state.lastResponseAt and os.clock()-state.lastResponseAt<=1.5
        state.hardwareAvailable=fresh==true and state.snapshot.bindingReady==true
        state.faults=fresh and (state.snapshot.faults or {}) or {chamberLabel(config).." CHAMBER THRUST "..
            (responding and "STATUS NOT UPDATING" or "COM UNRESPONSIVE")}
        state.controlState=(not fresh or not state.hardwareAvailable or #state.faults>0) and "FAULT" or
            (state.snapshot.thrustControlState or (state.snapshot.ready and "RDY" or "FAULT"))
        state.faultSummary=state.faults[1];state.publishedAt=os.clock()
    end
    -- @ama-summary: Receive and cache the chamber's local altitude observation.
    local function altitudeReceiver()
        while true do
            local event,sender,msg,protocol=os.pullEventRaw()
            local peer=Link.peer(config,config.relayChildRole)
            if event=="rednet_message" and protocol==Link.protocol and sender==peer and peer and
                type(msg)=="table" and msg.v==1 and msg.kind=="chamber_return" and msg.role==config.relayChildRole and
                finite(msg.sentAtEpochMs) and epoch()>=msg.sentAtEpochMs and epoch()-msg.sentAtEpochMs<=1500 and
                type(msg.packet)=="table" then
                local p=msg.packet
                if p.kind=="corner_altitude" and p.nodeBoot==boot and finite(p.seq) and p.seq>altitudeSeq then
                    altitudeSeq=p.seq
                    state.lastResponseAt=os.clock()
                    local a=p.altitude
                    os.__amaryllisCornerAltitude={receivedAt=os.clock(),sampleEpochMs=p.sampleEpochMs,
                        valid=type(a)=="table" and a.valid==true and finite(a.sensorWorldY) and finite(p.sampleEpochMs) and
                            epoch()>=p.sampleEpochMs and epoch()-p.sampleEpochMs<=1500,
                        sensorWorldY=type(a)=="table" and a.sensorWorldY or nil,source=type(a)=="table" and a.source or nil}
                end
            end
        end
    end
    -- @ama-summary: Forward the permitted chamber-link packet to its registered destination.
    local function relay()
    local timer=os.startTimer(.25)
    while true do
        local event,sender,msg,protocol=os.pullEventRaw()
        local peer,session=Link.peer(config,config.relayChildRole)
        if event=="rednet_message" and protocol==Link.protocol and type(msg)=="table" and peer then
            if sender==config.coreId and msg.session==session and
                (msg.kind=="thrust_session" or msg.kind=="thrust_command" or msg.kind=="thrust_stop") and
                msg.role==config.relayChildRole and msg.nodeBoot==boot then
                if msg.kind~="thrust_command" or (finite(msg.issuedAtEpochMs) and finite(msg.ttlSeconds) and
                    epoch()<msg.issuedAtEpochMs+msg.ttlSeconds*1000) then
                    rednet.send(peer,{v=1,kind="chamber_forward",role=config.relayChildRole,coreID=config.coreId,packet=msg},Link.protocol)
                end
            elseif sender==peer and msg.v==1 and msg.kind=="chamber_return" and msg.role==config.relayChildRole and
                finite(msg.sentAtEpochMs) and epoch()>=msg.sentAtEpochMs and epoch()-msg.sentAtEpochMs<=1500 and type(msg.packet)=="table" then
                local p=msg.packet
                if p.kind=="thrust_hello" and p.role==config.relayChildRole and type(p.nodeBoot)=="string" and not retired[p.nodeBoot] then
                    state.lastResponseAt=os.clock()
                    if boot~=p.nodeBoot then
                        if boot then retired[boot]=true;order[#order+1]=boot;if #order>32 then retired[table.remove(order,1)]=nil end end
                        boot=p.nodeBoot;childLast=nil;childSeq=-1;altitudeSeq=-1;os.__amaryllisCornerAltitude=nil
                    end
                    rednet.send(config.coreId,p,Link.protocol)
                elseif p.kind=="thrust_status" and p.role==config.relayChildRole and p.nodeBoot==boot and p.session==session and
                    finite(p.seq) and p.seq>childSeq then
                    state.lastResponseAt=os.clock()
                    childSeq=p.seq;childLast=os.clock();state.snapshot=p
                    if finite(p.readbackAgeSeconds) then p.readbackAgeSeconds=p.readbackAgeSeconds+(epoch()-msg.sentAtEpochMs)/1000 end
                    rednet.send(config.coreId,p,Link.protocol)
                end
            end
        elseif event=="timer" and sender==timer then timer=os.startTimer(.25) end
        publish()
    end
    end
    parallel.waitForAll(relay,altitudeReceiver)
end
-- Sensor reads are read-only and independently retryable. A lost peripheral
-- completion must not strand the stream behind an unbounded getter or sleep.
-- @ama-summary: Read the cached observation for the selected chamber corner.
function Link.readCorner(H,api,sensor)
    local result,completed,terminated=nil,false,false
    local deadline=os.clock()+.75
    local timer=os.startTimer(.75)
    parallel.waitForAny(function()
        local ok,value=pcall(H.sampleAltitude,{altitudeSensor=sensor},api,os.clock())
        completed=true
        result=ok and type(value)=="table" and value or {valid=false,reason="CORNER_ALTITUDE_READ_FAILED"}
    end,function()
        while os.clock()<deadline do
            if os.pullEventRaw()=="terminate" then terminated=true;return end
        end
    end)
    pcall(os.cancelTimer,timer)
    if terminated then return nil end
    return completed and result or {valid=false,reason="CORNER_ALTITUDE_READ_TIMEOUT"}
end
-- @ama-summary: Wait for the next valid observation from the selected chamber corner.
function Link.waitCorner(seconds)
    local deadline=os.clock()+seconds
    local timer=os.startTimer(seconds)
    while os.clock()<deadline do
        if os.pullEventRaw()=="terminate" then pcall(os.cancelTimer,timer);return false end
    end
    pcall(os.cancelTimer,timer)
    return true
end

-- @ama-summary: Connect the child component to its configured chamber-side service.
function Link.child(config,programEnv)
    local realOS,realRednet=os,rednet
    local boot=nil
    local function send(packet)
        local peer=Link.peer(config,config.coordinatorRole)
        if peer then return realRednet.send(peer,{v=1,kind="chamber_return",role=config.role,sentAtEpochMs=epoch(),packet=packet},Link.protocol) end
        return false
    end
    local radio=setmetatable({}, {__index=realRednet})
    function radio.broadcast(packet,protocol)
        if protocol==Link.protocol then if packet.kind=="thrust_hello" then boot=packet.nodeBoot end;return send(packet) end
        return false
    end
    function radio.send(id,packet,protocol)
        if id==config.coreId and protocol==Link.protocol then return send(packet) end
        return false
    end
    local clock=setmetatable({}, {__index=realOS,__newindex=realOS})
    rawset(clock,"pullEventRaw",function(filter)
        while true do
            local e={realOS.pullEventRaw(filter)}
            if e[1]~="rednet_message" then return table.unpack(e) end
            if e[4]==Link.protocol then
                local p=Link.unwrap(config,e[2],e[3],epoch())
                if p then return "rednet_message",config.coreId,p,Link.protocol end
            end
        end
    end)
    local env=setmetatable({os=clock,rednet=radio}, {__index=programEnv});env._G=programEnv._G
    -- @ama-summary: Publish the available chamber-local sensor observations.
    local function sensors()
        local H=require("hardware").lift
        local api=H.remotePeripheral({providerDiscovery={networkSide="back"}})
        local seq=0
        local sensor={name="",lowestPointOffsetBlocks=4,includeVerticalSpeed=false}
        while true do
            local a=Link.readCorner(H,api,sensor)
            if not a then return end
            sensor.name=a.valid and a.source or ""
            seq=seq+1
            if boot then send({kind="corner_altitude",nodeBoot=boot,seq=seq,sampleEpochMs=epoch(),altitude=a}) end
            local r=os.__amaryllisRuntime
            if r then
                r.cornerAltitude=a;r.sampling=r.sampling or {};r.sampling.corner=r.sampling.corner or {}
                local progress=r.sampling.corner
                progress.completedCount=seq;progress.lastCompletedAt=os.clock()
                progress.lastError=a.valid and nil or a.reason
                progress.failures=a.valid and 0 or (progress.failures or 0)+1
            end
            if not Link.waitCorner(a.valid and .25 or .1) then return end
        end
    end
    parallel.waitForAll(function() assert(loadfile("/avionics/thrust.lua",nil,env))() end,sensors)
end
return Link
