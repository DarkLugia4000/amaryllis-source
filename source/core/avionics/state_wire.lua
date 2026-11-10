local Mathx = require("avionics.mathx")
-- Section: State transport | Correlated wired frames, source ages and core configuration.
-- State assembly verification v1
-- Read-only sensor transport. Dedicated wired channels; never actuator RPC.
local Wire={CORE_CHANNEL=45130,STATE_CHANNEL=45131,PROTOCOL="amaryllis.state.v1"}
local Sources=require("avionics.vessel_sources")
local SIDES={"top","bottom","left","right","front","back"}
local INPUTS={"left_press","left_lift","right_press","right_lift","prop_forward","prop_reverse","ap_disconnect","altitude_up","altitude_down"}
local finite = Mathx.finite
local function integer(v,a,b) return finite(v) and v%1==0 and v>=a and v<=b end
local function token(v) return type(v)=="string" and #v>0 and #v<=128 and v:match("^[%w_.:%-]+$") end
local function name(v) return type(v)=="string" and #v>0 and #v<=256 and not v:find("[%c]") end
local function vector(v)
    if type(v)=="table" and finite(v.x) and finite(v.y) and finite(v.z) then return {x=v.x,y=v.y,z=v.z} end
end
-- Section: State transport | Correlated wired frames, source ages and core configuration.
-- Summary: Copy bounded table values into independent operation or transport records.
local function copy(value,depth,budget)
    depth=depth or 0;budget=budget or {n=0}
    budget.n=budget.n+1
    if budget.n>4096 or depth>7 then error("STATE FRAME TOO LARGE",0) end
    if type(value)=="number" then if finite(value) then return value end;return nil end
    if type(value)=="boolean" then return value end
    if type(value)=="string" then return value:sub(1,2048) end
    if type(value)~="table" then return nil end
    local out={};local count=0
    for k,v in pairs(value) do
        count=count+1;if count>64 then error("STATE FRAME TABLE TOO LARGE",0) end
        if (type(k)=="string" and #k<=256) or integer(k,-20000000,20000000) then out[k]=copy(v,depth+1,budget) end
    end
    return out
end
Wire.copy=copy
local function ageOK(at,now) return finite(at) and at<=now+.25 and now-at<=120 end
-- The pilot batch has a fixed shape. Copying it never traverses telemetry,
-- diagnostic tables or disk-backed calibration records.
-- Summary: Build a bounded cockpit input frame with observation timestamps.
function Wire.inputFrame(input)
    if type(input)~="table" or input.valid~=true or not finite(input.at) or type(input.raw)~="table" then return nil end
    local raw={}
    for _,key in ipairs(INPUTS) do if not integer(input.raw[key],0,15) then return nil end;raw[key]=input.raw[key] end
    local out={valid=true,at=input.at,raw=raw,errors={},
        sampleDurationSeconds=finite(input.sampleDurationSeconds) and input.sampleDurationSeconds>=0 and input.sampleDurationSeconds or nil}
    -- Optional measurement metadata never participates in freshness/authority.
    local t=input.timing
    if type(t)=="table" and token(t.boot) and integer(t.seq,1,2147483647) and
        finite(t.readStartedAt) and t.readCompletedAt==input.at and
        t.readStartedAt<=t.readCompletedAt and finite(t.sendAttemptAt) and t.sendAttemptAt>=input.at then
        out.timing={boot=t.boot,seq=t.seq,readStartedAt=t.readStartedAt,
            readCompletedAt=t.readCompletedAt,sendAttemptAt=t.sendAttemptAt}
    end
    return out
end
-- Summary: Validate and apply the newest cockpit observations to core input state.
local function commitInput(io,input,now,trace)
    local sample=Wire.inputFrame(input)
    if not sample or not ageOK(sample.at,now) then return false end
    if io.inputs and finite(io.inputs.at) and sample.at<=io.inputs.at then return false end
    if trace and sample.timing and (sample.timing.boot~=trace.boot or
        trace.source=="fast" and sample.timing.seq~=trace.seq) then sample.timing=nil end
    if trace and io.cockpitTrace then
        pcall(io.cockpitTrace.receivedInput,io.cockpitTrace,sample,trace.boot,trace.seq,trace.source,
            trace.entered,io:nowSeconds())
    end
    io.inputs=sample
    if type(io.onCockpitInput)=="function" then
        local ok,issue=pcall(io.onCockpitInput,now)
        if not ok then io.cockpitPriorityError=tostring(issue):sub(1,160) end
    end
    return true
end
-- Summary: Inspect attached modems and separate wired from wireless interfaces.
function Wire.localModems(api)
    local inventory={peripherals={},modems={},wirelessModems={},monitors={},errors={}}
    local wired={}
    for _,side in ipairs(SIDES) do
        local ok,kind=pcall(api.getType,side)
        if ok and kind then
            inventory.peripherals[#inventory.peripherals+1]={name=side,types={kind},methods={}}
            if kind=="modem" then
                local wrapped,m=pcall(api.wrap,side)
                if wrapped and type(m)=="table" and type(m.isWireless)=="function" then
                    local checked,wireless=pcall(m.isWireless)
                    if checked then
                        inventory.modems[#inventory.modems+1]=side
                        if wireless then inventory.wirelessModems[#inventory.wirelessModems+1]=side
                        else wired[#wired+1]={side=side,modem=m} end
                    end
                end
            end
        end
    end
    return inventory,wired
end
-- Summary: Select the wired modem that exposes the configured peer computer.
function Wire.chooseWired(wired,peerID)
    if #wired==1 then return wired[1] end
    -- A separate sensor bus may occupy another modem. Identify the link by
    -- its exposed computer ID once during attachment, not by side ordering.
    for _,entry in ipairs(wired) do
        local m=entry.modem
        if type(m.getNamesRemote)=="function" and type(m.callRemote)=="function" then
            local ok,names=pcall(m.getNamesRemote)
            if ok and type(names)=="table" then
                for _,remote in ipairs(names) do
                    local computer=type(remote)=="string" and remote:match("^computer_")
                    if type(m.getTypeRemote)=="function" then
                        local typed,kind=pcall(m.getTypeRemote,remote)
                        computer=typed and kind=="computer"
                    end
                    if computer then
                        local read,id=pcall(m.callRemote,remote,"getID")
                        if read and id==peerID then return entry end
                    end
                end
            end
        end
    end
end
function Wire.newCore(io,entry)
    assert(entry and integer(entry.id,0,65535) and name(entry.label),"STATE READER IDENTITY UNASSIGNED")
    return setmetatable({id=entry.id,label=entry.label,coreID=io.localID,session=io.session,
        seq=0,retired={},retiredOrder={},phase="WAITING FOR WIRED READER"},{__index=Wire})
end
-- Summary: Attach the state link to its configured wired peer.
function Wire:scanCore(io)
    local inventory,wired=Wire.localModems(io.peripheral)
    io.inventory=inventory
    self.side,self.modem=nil,nil
    local selected=Wire.chooseWired(wired,self.id)
    if selected then
        self.side,self.modem=selected.side,selected.modem
        local ok,reason=pcall(self.modem.open,Wire.CORE_CHANNEL)
        if not ok then self.modem=nil;self.phase="STATE WIRED CHANNEL FAILED: "..tostring(reason) end
    else self.phase=#wired==0 and "STATE WIRED MODEM MISSING" or "STATE WIRED PEER NOT FOUND" end
    return inventory
end
local function metadata(io)
    local p=io.primaryVessel or {}
    return {at=p.at,attitudeBow=p.attitudeBow,attitudeAxisSource=p.attitudeAxisSource,environment=p.environment}
end
function Wire.frame(reader)
    if type(reader.assemblyGate)=="function" then reader:assemblyGate(reader:nowSeconds()) end
    return copy({primary=reader.primaryReadings or {},fallback=reader.fallbackReadings or {},
        metadata=metadata(reader),inputs=reader.inputs,assembly=reader.assemblyTrack,
        fingerprint=reader.hardwareFingerprint,bindings=reader.sensorBindings,
        readers=reader.sampling,pressure=reader.pressureCache or {}})
end
-- Summary: Validate the state reader's bounded sensor-binding description.
local function validateBindings(bindings)
    if type(bindings)~="table" then return nil end
    local result={velocity_sensors={}}
    for _,key in ipairs({"navigation_table","altitude_sensor","gimbal_sensor"}) do
        if bindings[key]~=nil and not name(bindings[key]) then return nil end
        result[key]=bindings[key]
    end
    if type(bindings.velocity_sensors)~="table" or #bindings.velocity_sensors>3 then return nil end
    for _,v in ipairs(bindings.velocity_sensors) do if not name(v) then return nil end;result.velocity_sensors[#result.velocity_sensors+1]=v end
    return result
end
-- Summary: Validate a state frame, preserve source ages and compose accepted vessel data.
function Wire:accept(io,side,channel,packet,now)
    local entry=io.computers and io.computers.state
    if entry and (entry.id~=self.id or entry.label~=self.label) then return false,"STATE ASSIGNMENT CHANGED; RESTART CORE" end
    if side~=self.side or channel~=Wire.CORE_CHANNEL or not self.modem or type(packet)~="table" or
        packet.protocol~=Wire.PROTOCOL or packet.kind~="state_frame" or packet.sender~=self.id or
        packet.target~=self.coreID or packet.session~=self.session or not token(packet.boot) or
        not integer(packet.seq,1,2147483647) or self.retired[packet.boot] then return false,"STATE ENVELOPE REJECTED" end
    if packet.boot==self.boot and packet.seq<=self.seq then return false,"STATE FRAME REPLAY" end
    local ok,data=pcall(copy,packet.data)
    if not ok or type(data)~="table" then return false,"STATE FRAME INVALID" end
    local bindings=validateBindings(data.bindings)
    if not bindings or not (type(data.fingerprint)=="string" and #data.fingerprint>0 and #data.fingerprint<=2048) then
        return false,"STATE SENSOR BINDINGS INVALID"
    end
    if packet.boot~=self.boot then
        if self.boot then self.retired[self.boot]=true;self.retiredOrder[#self.retiredOrder+1]=self.boot end
        if #self.retiredOrder>8 then self.retired[table.remove(self.retiredOrder,1)]=nil end
        self.boot=packet.boot;self.seq=0;self.inputSeq=0;io.stateReaderReset=true
    end
    self.seq=packet.seq;self.lastFrameAt=now;self.phase="CONNECTED"
    self.acceptedFrames=(self.acceptedFrames or 0)+1
    self.frameSentAt=ageOK(packet.sentAt,now) and packet.sentAt or nil
    -- Legacy/full frames retain cockpit compatibility, but pilot input is
    -- consumed before calibration I/O and telemetry composition can yield.
    commitInput(io,data.inputs,now,{boot=packet.boot,source="full",entered=now})
    if io.hardwareFingerprint~=data.fingerprint then
        io.hardwareFingerprint=data.fingerprint;io.fallbackCalibration=nil;Sources.loadCalibration(io)
    end
    io.sensorBindings=bindings;io.sensorBindingError=nil
    local primary=type(data.primary)=="table" and data.primary or {}
    for _,key in ipairs({"uuid","pose","com","velocity","angular","mass"}) do
        local r=primary[key]
        local previous=(io.primaryReadings or {})[key]
        if type(r)=="table" and ageOK(r.at,now) and (not previous or not finite(previous.at) or r.at>=previous.at) then
            Sources.acceptPrimary(io,key,r.value,r.at,"reader")
        end
    end
    local fallback=type(data.fallback)=="table" and data.fallback or {}
    local keys={"uuid","orientation","heading","height","verticalSpeed","pressure","gravity","rates","mass","com"}
    for _,sensor in ipairs(bindings.velocity_sensors) do keys[#keys+1]="velocity:"..sensor end
    for _,key in ipairs(keys) do
        local r=fallback[key]
        if type(r)=="table" and Sources.acceptBackup(io,key,r.value,r.at,now) and type(r.error)=="string" then
            io.fallbackReadings[key].error=r.error:sub(1,160)
        end
    end
    local m=data.metadata
    if type(m)=="table" and ageOK(m.at,now) then
        local env=type(m.environment)=="table" and m.environment or {}
        io.primaryVessel={at=m.at,attitudeBow=vector(m.attitudeBow),
            attitudeAxisSource=type(m.attitudeAxisSource)=="string" and m.attitudeAxisSource:sub(1,128) or nil,
            environment={gravity=vector(env.gravity),universalDrag=finite(env.universalDrag) and env.universalDrag or nil,
                airPressure=finite(env.airPressure) and env.airPressure>0 and env.airPressure or nil}}
    end
    local assembly=data.assembly
    if type(assembly)=="table" and type(assembly.definite)=="boolean" and ageOK(assembly.definiteAt,now) and
        (not io.assemblyTrack or not finite(io.assemblyTrack.definiteAt) or assembly.definiteAt>=io.assemblyTrack.definiteAt) then
        local t={definite=assembly.definite,definiteAt=assembly.definiteAt,assemblers={}}
        for _,key in ipairs({"definiteReason","error"}) do if type(assembly[key])=="string" then t[key]=assembly[key]:sub(1,160) end end
        if ageOK(assembly.errorAt,now) then t.errorAt=assembly.errorAt end
        if type(assembly.assemblers)=="table" then
            for i,v in ipairs(assembly.assemblers) do if i<=8 and name(v) then t.assemblers[#t.assemblers+1]=v end end
        end
        io.assemblyTrack=t
    end
    if type(data.assembly)=="table" and type(data.assembly.error)=="string" then
        io.assemblyTrack=io.assemblyTrack or {}
        io.assemblyTrack.error=data.assembly.error:sub(1,512)
    end
    io.statePressureCache={}
    for key,item in pairs(type(data.pressure)=="table" and data.pressure or {}) do
        if integer(key,-20000000,20000000) and type(item)=="table" and ageOK(item.at,now) and
            finite(item.value) and item.value>0 and finite(item.x) and finite(item.z) then io.statePressureCache[key]=item end
    end
    for _,key in ipairs({"vessel","cockpit","fallback","assembly","assembler"}) do
        local sample=type(data.readers)=="table" and data.readers[key]
        if type(sample)=="table" then
            local result={source=self.label}
            for _,field in ipairs({"phase","stage","lastError","lastTimeoutStage"}) do if type(sample[field])=="string" then result[field]=sample[field]:sub(1,512) end end
            for _,field in ipairs({"failures","duration","completedCount","lastCompletedAt"}) do if finite(sample[field]) and sample[field]>=0 then result[field]=sample[field] end end
            if type(sample.lastTimeoutPending)=="table" then
                result.lastTimeoutPending={}
                for i,v in ipairs(sample.lastTimeoutPending) do if i<=32 and name(v) then result.lastTimeoutPending[#result.lastTimeoutPending+1]=v end end
            end
            io.sampling[key]=result
        end
    end
    Sources.compose(io,now)
    return true
end
-- Summary: Validate and apply a cockpit frame from the assigned state reader.
function Wire:acceptInput(io,side,channel,packet,now)
    local entry=io.computers and io.computers.state
    if not entry or entry.id~=self.id or entry.label~=self.label then return false,"COCKPIT STATE ASSIGNMENT INVALID" end
    if side~=self.side or channel~=Wire.CORE_CHANNEL or not self.modem or type(packet)~="table" or
        packet.protocol~=Wire.PROTOCOL or packet.kind~="cockpit_frame" or packet.sender~=self.id or
        packet.target~=self.coreID or packet.session~=self.session or not token(packet.boot) or
        packet.boot~=self.boot or self.retired[packet.boot] or not integer(packet.seq,1,2147483647) then
        return false,"COCKPIT ENVELOPE REJECTED"
    end
    if packet.seq<=(self.inputSeq or 0) then return false,"COCKPIT FRAME REPLAY" end
    local sample=Wire.inputFrame(packet.input)
    local cockpit=io.config and io.config.cockpit or {}
    local limit=cockpit.input_stale_seconds or cockpit.maximum_input_gap_seconds or
        io.config and io.config.network and io.config.network.sensor_stale_seconds or 6
    if not sample or not finite(now) or sample.at>now or now-sample.at>limit then return false,"COCKPIT SAMPLE INVALID OR STALE" end
    self.inputSeq=packet.seq
    if not commitInput(io,sample,now,{boot=packet.boot,seq=packet.seq,source="fast",entered=now}) then return false,"COCKPIT SAMPLE SUPERSEDED" end
    self.inputReceivedAt=now;self.inputSentAt=ageOK(packet.sentAt,now) and packet.sentAt or nil
    self.acceptedInputFrames=(self.acceptedInputFrames or 0)+1
    return true
end
-- Summary: Report state-link freshness and reader availability from cached observations.
function Wire:probe(io,now)
    now=now or io:nowSeconds()
    local function age(at) return finite(at) and now-at or nil end
    local pose=(io.primaryReadings or {}).pose
    local input=io.inputs or {}
    local sources=(io.vessel or {}).sources or {}
    return {id=self.id,label=self.label,phase=self.phase,boot=self.boot,seq=self.seq,
        checkedAt=now,receivedAt=self.lastFrameAt,ageSeconds=age(self.lastFrameAt),
        sentAt=self.frameSentAt,sentAgeSeconds=age(self.frameSentAt),
        transportSeconds=self.frameSentAt and self.lastFrameAt-self.frameSentAt or nil,
        poseAt=pose and pose.at,poseAgeSeconds=age(pose and pose.at),
        inputAt=input.at,inputAgeSeconds=age(input.at),inputValid=input.valid==true,
        priorityInputSeq=self.inputSeq,priorityInputAgeSeconds=age(self.inputReceivedAt),
        priorityTransportSeconds=self.inputSentAt and self.inputReceivedAt-self.inputSentAt or nil,
        acceptedInputFrames=self.acceptedInputFrames or 0,rejectedInputFrames=self.rejectedInputFrames or 0,
        cockpitProcessedAt=io.cockpitProcessedAt,cockpitProcessedSampleAt=io.cockpitProcessedSampleAt,
        cockpitProcessingAgeSeconds=finite(io.cockpitProcessedAt) and finite(io.cockpitProcessedSampleAt) and
            math.max(0,io.cockpitProcessedAt-io.cockpitProcessedSampleAt) or nil,
        priorityInputError=io.cockpitPriorityError,
        composedMode=sources.mode,composedPrimaryAgeSeconds=sources.primaryAgeSeconds,
        positionAvailable=sources.positionAvailable,contextSendSeconds=self.contextSendSeconds,
        receivedFrames=self.receivedFrames or 0,acceptedFrames=self.acceptedFrames or 0,
        rejectedFrames=self.rejectedFrames or 0,lastReject=self.lastReject}
end
-- Summary: Build the configuration and chamber context supplied to the state reader.
function Wire:context(io)
    local nodes={}
    for _,q in ipairs({"FL","FR","BL","BR"}) do
        local n=io.nodes[q] or {};nodes[q]={altitude=n.altitude,online=io:nodeFresh(q),lastSeen=n.lastSeen}
    end
    local cfg=copy(io.config)
    cfg.hardware.main_monitor=""
    local text=io.json.serializeJSON(cfg)
    local a,b=1,0;for i=1,#text do a=(a+text:byte(i))%65521;b=(b+a)%65521 end
    return {protocol=Wire.PROTOCOL,kind="state_context",sender=self.coreID,target=self.id,
        session=self.session,config=cfg,configTag=string.format("%04X%04X",b,a),nodes=copy(nodes),pressureY=io.statePressureRequest or io.stateTargetAltitude}
end
-- Summary: Receive state frames and periodically publish core sensor configuration.
function Wire:run(io)
    local api=io.os or os
    -- Summary: Receive and validate cockpit frames on the wired state channel.
    local function receiveInputs()
        while true do
            local event,side,channel,reply,packet=api.pullEventRaw()
            if event=="modem_message" and channel==Wire.CORE_CHANNEL and type(packet)=="table" and
                packet.protocol==Wire.PROTOCOL and packet.kind=="cockpit_frame" then
                local accepted,reason=self:acceptInput(io,side,channel,packet,io:nowSeconds())
                if not accepted then
                    self.rejectedInputFrames=(self.rejectedInputFrames or 0)+1;self.lastInputReject=reason
                    if io.cockpitTrace then pcall(io.cockpitTrace.rejectedInput,io.cockpitTrace,reason,io:nowSeconds()) end
                end
            end
        end
    end
    -- Summary: Receive a packet matching the current protocol and peer context.
    local function receive()
        while true do
            local event,side,channel,reply,packet=api.pullEventRaw()
            if event=="modem_message" and channel==Wire.CORE_CHANNEL and type(packet)=="table" and
                packet.protocol==Wire.PROTOCOL and packet.kind=="state_frame" then
                self.receivedFrames=(self.receivedFrames or 0)+1
                local accepted,reason=self:accept(io,side,channel,packet,io:nowSeconds())
                if not accepted then self.rejectedFrames=(self.rejectedFrames or 0)+1;self.lastReject=reason end
            elseif event=="peripheral" or event=="peripheral_detach" then self.modem=nil end
        end
    end
    -- Summary: Send the current correlated packet to its configured peer.
    local function send()
        local nextContext=0
        while true do
            local now=io:nowSeconds()
            if now>=nextContext then
                nextContext=now+1
                if self.lastFrameAt and now-self.lastFrameAt>(io.config.network.sensor_stale_seconds or 6) then self.phase="STATE LINK STALE; RETRYING" end
                if not self.modem then self:scanCore(io) end
                local modem=self.modem
                if modem then
                    local started=io:nowSeconds()
                    local ok=pcall(modem.transmit,Wire.STATE_CHANNEL,Wire.CORE_CHANNEL,self:context(io))
                    self.contextSendSeconds=math.max(0,io:nowSeconds()-started)
                    if not ok and self.modem==modem then self.modem=nil;self.phase="STATE WIRED SEND FAILED" end
                end
                Sources.persistCalibration(io,io:nowSeconds())
            end
            local timer=api.startTimer(.2)
            api.pullEventRaw()
            pcall(api.cancelTimer,timer)
        end
    end
    -- Wired transmit and calibration storage may yield. Keep receiving while
    -- they wait, rather than letting fresh measurements queue behind a send.
    if io.cockpitTrace then
        return (io.parallel or parallel).waitForAny(receiveInputs,receive,send,
            function() io.cockpitTrace:pulseWorker(api) end)
    end
    return (io.parallel or parallel).waitForAny(receiveInputs,receive,send)
end
return Wire
