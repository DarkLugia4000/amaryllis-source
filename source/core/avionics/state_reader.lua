-- Section: State service | Independent sensor workers and wired telemetry publication.
-- ama-state samples independent sensor fields and publishes timestamped frames to core.
local args={...}
if args[1]=="worker" then
    local context=os.__amaryllisStateWorkers
    if not context or context.owner~=args[3] or type(context.jobs[args[2]])~="function" then error("STATE WORKER OWNER INVALID",0) end
    context.jobs[args[2]]();return
end
package.path="/?.lua;/?/init.lua;"..package.path
local Storage=require("avionics.storage")
local IO=require("avionics.io")
local Sources=require("avionics.vessel_sources")
local Sampling=require("avionics.sampling")
local Wire=require("avionics.state_wire")
local cfg=assert(Storage.readJson("/avionics/config.json"))
assert(cfg.role=="state" and cfg.computerID==os.getComputerID() and type(cfg.coreID)=="number","STATE INSTALL IDENTITY INVALID")
assert(os.getComputerLabel()==cfg.label,"STATE LABEL DOES NOT MATCH INSTALL")
local owner=tostring(os.epoch("utc")).."-"..math.random(1,2147483647)
local boot=tostring(cfg.computerID).."-"..owner
local reader,session,configTag,side,modem,pressureY
local lastCoreAt
local retired,retiredOrder={},{}
local frameSeq=0
local inputSeq=0
local frameError
local scanRequested=true
local workers={owner=owner,jobs={}}
os.__amaryllisStateWorkers=workers
os.__amaryllisIdentity={role="state",computerID=cfg.computerID,label=cfg.label,coreID=cfg.coreID,verified=true}
local function now() return os.epoch("utc")/1000 end
local timingOK,Timing=pcall(require,"avionics.cockpit_timing")
local cockpitTiming
if timingOK and type(Timing)=="table" and type(Timing.new)=="function" then
    local ok,value=pcall(Timing.new,"state",boot,now)
    if ok and type(value)=="table" then cockpitTiming=value end
end
os.__amaryllisCockpitTiming=cockpitTiming
local GETTERS={getLinkSignal=true,getHeight=true,getVerticalSpeed=true,getAirPressure=true,getOrientation=true,
    getHeading=true,getGravity=true,getAngularRates=true,getAxis=true,getVelocity=true,getSubLevelId=true,
    getMass=true,getCenterOfMass=true,isAssembled=true,isWireless=true}
-- Section: State service | Independent sensor workers and wired telemetry publication.
-- Summary: Expose the configured sensor getter methods to the state reader.
local function readOnlyPeripheral(api)
    local out={getNames=api.getNames,getType=api.getType,getMethods=api.getMethods,hasType=api.hasType}
    out.wrap=function(name)
        local original=api.wrap(name)
        if type(original)~="table" then return nil end
        local wrapped={}
        for method in pairs(GETTERS) do if type(original[method])=="function" then wrapped[method]=original[method] end end
        return wrapped
    end
    return out
end
local function pause(seconds)
    local deadline=os.clock()+seconds;local timer=os.startTimer(seconds)
    while os.__amaryllisStateWorkers==workers and os.clock()<deadline do os.pullEventRaw() end
    pcall(os.cancelTimer,timer)
end
-- Summary: Construct state's independent sensor caches and sampling contexts.
local function newReader(config)
    local r=setmetatable({config=config,os=os,peripheral=readOnlyPeripheral(peripheral),sublevel=sublevel,aero=aero,
        fs=fs,json=textutils,vectorApi=vector,parallel=parallel,now=now,nodes={},
        inventory={peripherals={},modems={},wirelessModems={},errors={}},sensorBindings={},
        sensorBindingError="STATE SENSOR DISCOVERY PENDING",bridgeGeneration=0,
        inputs={valid=false,raw={},errors={},reason="STATE COCKPIT NOT SAMPLED"},
        vessel={valid=false,reason="STATE VESSEL NOT SAMPLED"},
        independentVesselSources=true,independentAssemblerSources=true,
        sampling={vessel={},cockpit={},fallback={},assembly={},assembler={},pressure={},discovery={}}},{__index=IO})
    return r
end
local INPUT_LABELS={left_press="Left pedal press",left_lift="Left pedal pull",
    right_press="Right pedal press",right_lift="Right pedal pull",prop_forward="Forward throttle",
    prop_reverse="Reverse throttle",ap_disconnect="AP disconnect",altitude_up="Altitude up",altitude_down="Altitude down"}
-- Summary: Format raw and accepted cockpit readings with input ages and configured frequencies.
local function cockpitLines(r,at,width,height,selected)
    local function clean(value) return tostring(value or "--"):gsub("[%c]"," ") end
    local function age(stamp)
        return type(stamp)=="number" and string.format("%.1fs",math.max(0,at-stamp)) or "--"
    end
    local function level(value)
        return type(value)=="number" and value%1==0 and value>=0 and value<=15 and tostring(value) or "--"
    end
    local order=IO.INPUT_ORDER
    selected=math.max(1,math.min(#order,selected or 1))
    local used=r and r.inputs or {}
    local latest=r and (r.lastInputAttempt or r.inputs) or {}
    local progress=r and r.sampling and r.sampling.cockpit or {}
    local rows={"COCKPIT READINGS / ama-state #"..cfg.computerID,
        clean(progress.phase or "WAITING FOR CORE").." | Used age "..(used.valid and age(used.at) or "--"),
        "Read age "..age(latest.at).." | Duration "..
            (type(latest.sampleDurationSeconds)=="number" and string.format("%.2fs",latest.sampleDurationSeconds) or "--"),
        string.format(" %-22s %4s %4s","INPUT","READ","USED")}
    if not lastCoreAt or os.clock()<lastCoreAt or os.clock()-lastCoreAt>10 then rows[2]="CORE UNREACHABLE" end
    local visible=math.max(1,math.min(#order,height-10))
    local first=math.max(1,math.min(selected-visible+1,#order-visible+1))
    for i=first,first+visible-1 do
        local key=order[i]
        rows[#rows+1]=string.format("%s%-22s %4s %4s",i==selected and ">" or " ",INPUT_LABELS[key] or key,
            level((latest.raw or {})[key]),level(used.valid and (used.raw or {})[key] or nil))
    end
    local key=order[selected]
    local pair=r and r.config and r.config.input_frequencies and r.config.input_frequencies[key] or {}
    local errors=latest.errors or {}
    local error=errors[key] or errors.bridge or errors.parallel or progress.lastError
    if not error and progress.pending and progress.pending[key] then error="READING" end
    local footer={"Bridge: "..clean(r and r.bridgeName),"Freq A: "..clean(pair[1]),"Freq B: "..clean(pair[2]),
        key..": "..clean(error or (latest.valid and "OK" or "NOT SAMPLED")),
        "READ=latest; USED=last valid batch. Raw 0-15.","Up/down: select input and frequency"}
    for _,line in ipairs(footer) do rows[#rows+1]=line end
    for i,line in ipairs(rows) do rows[i]=clean(line):sub(1,width) end
    return rows
end
-- Summary: Refresh state's cockpit diagnostic terminal and handle input selection.
local function cockpitPanel()
    local selected,nextDraw,timer=1,0,nil
    while os.__amaryllisStateWorkers==workers do
        if os.clock()>=nextDraw then
            local width,height=term.getSize()
            local rows=cockpitLines(reader,now(),width,height,selected)
            if term.setBackgroundColor and colors then term.setBackgroundColor(colors.black) end
            if term.setTextColor and colors then term.setTextColor(colors.white) end
            term.setCursorBlink(false)
            for y=1,height do
                term.setCursorPos(1,y);term.clearLine()
                if term.setTextColor and colors then
                    term.setTextColor(y==1 and colors.cyan or (y==4 and colors.lightGray or colors.white))
                end
                term.write(rows[y] or "")
            end
            nextDraw=os.clock()+.2
            if timer then pcall(os.cancelTimer,timer) end
            timer=os.startTimer(.2)
        end
        local event,key=os.pullEventRaw()
        if event=="key" and keys then
            if key==keys.up then selected=math.max(1,selected-1);nextDraw=0
            elseif key==keys.down then selected=math.min(#IO.INPUT_ORDER,selected+1);nextDraw=0 end
        elseif event=="term_resize" then nextDraw=0 end
    end
    if timer then pcall(os.cancelTimer,timer) end
end
-- Summary: Attach state's wired modem to the configured core peer.
local function findLink()
    local _,wired=Wire.localModems(peripheral)
    side,modem=nil,nil
    local selected=Wire.chooseWired(wired,cfg.coreID)
    if selected then
        side,modem=selected.side,selected.modem
        local ok=pcall(modem.open,Wire.STATE_CHANNEL)
        if not ok then modem=nil end
    end
end
-- Summary: Validate the wired core context and update the state reader configuration, node roster and pressure request.
local function context(packet)
    if type(packet)~="table" or packet.protocol~=Wire.PROTOCOL or packet.kind~="state_context" or
        packet.sender~=cfg.coreID or packet.target~=cfg.computerID or type(packet.session)~="string" or
        #packet.session<1 or #packet.session>128 or retired[packet.session] or type(packet.configTag)~="string" then return false end
    local ok,config=pcall(Wire.copy,packet.config)
    if not ok or type(config)~="table" then return false end
    local valid=Storage.validateConfig(config)
    if not valid then return false end
    if session~=packet.session then
        if session then retired[session]=true;retiredOrder[#retiredOrder+1]=session end
        if #retiredOrder>8 then retired[table.remove(retiredOrder,1)]=nil end
        session=packet.session
    end
    if not reader or configTag~=packet.configTag then
        reader=newReader(config);configTag=packet.configTag;scanRequested=true
        print("State sensor configuration accepted from core #"..cfg.coreID)
    end
    local copied,nodes=pcall(Wire.copy,packet.nodes)
    if copied and type(nodes)=="table" then reader.nodes=nodes end
    if type(packet.pressureY)=="number" and packet.pressureY==packet.pressureY and math.abs(packet.pressureY)<20000000 then pressureY=packet.pressureY end
    lastCoreAt=os.clock()
    os.__amaryllisCoreLink={coreID=cfg.coreID,session=session,receivedAt=lastCoreAt,timeout=10,transport="wired"}
    return true
end
-- Summary: Publish timestamped state frames and accept current core configuration.
local function network()
    local nextFrame,nextFind=0,0
    findLink()
    while os.__amaryllisStateWorkers==workers do
        local at=now()
        local reachable=lastCoreAt~=nil and os.clock()>=lastCoreAt and os.clock()-lastCoreAt<=10
        local networkState=reachable and "CONNECTED" or "CORE UNREACHABLE"
        local current=os.__amaryllisRuntime or {}
        current.networkState=networkState
        current.faultSummary=not reachable and "CORE UNREACHABLE" or frameError
        os.__amaryllisRuntime=current
        if not modem and at>=nextFind then nextFind=at+2;findLink() end
        if at>=nextFrame then
            nextFrame=at+.2
            local framed,payload=false,nil
            if reader then framed,payload=pcall(Wire.frame,reader) end
            if reader and not framed then
                -- A malformed frame is skipped (and shown) instead of ending
                -- the sender; the next frame is built from fresh readings.
                local issue=tostring(payload):sub(1,160)
                if issue~=frameError then print("State frame skipped: "..issue) end
                frameError=issue
            elseif reader then
                frameError=nil
                frameSeq=frameSeq+1
                local sentAt
                if modem and session then
                    sentAt=now()
                    local ok=pcall(modem.transmit,Wire.CORE_CHANNEL,Wire.STATE_CHANNEL,
                        {protocol=Wire.PROTOCOL,kind="state_frame",sender=cfg.computerID,target=cfg.coreID,
                            session=session,boot=boot,seq=frameSeq,sentAt=sentAt,data=payload})
                    if not ok then modem=nil end
                end
                os.__amaryllisRuntime={running=true,publishedAt=os.clock(),sampling=reader.sampling,
                    networkState=networkState,faultSummary=not reachable and "CORE UNREACHABLE" or nil,
                    snapshot={role="state",coreID=cfg.coreID,frameSeq=frameSeq,frameSentAt=sentAt,linked=modem~=nil and session~=nil,
                        readers=reader.sampling,vessel=reader.vessel,inputs=reader.inputs,assembly=reader.assemblyTrack}}
            end
        end
        local timer=os.startTimer(.2)
        local event,a,b,c,d=os.pullEventRaw()
        pcall(os.cancelTimer,timer)
        if event=="modem_message" and a==side and b==Wire.STATE_CHANNEL then context(d)
        elseif event=="peripheral" or event=="peripheral_detach" then modem=nil;scanRequested=true end
    end
end
-- Summary: Run a named sensor sampling operation with its deadline and repeat interval.
local function job(name,operation,timeout,interval)
    return function()
        while os.__amaryllisStateWorkers==workers do
            local current=reader
            if not current then pause(.2)
            else
                Sampling.run(name,function() return operation(current) end,{state=current.sampling[name],timeout=timeout,
                    interval=interval,log=name=="cockpit" and shell and shell.openTab and multishell and function() end or nil,
                    validate=function(value)
                        if name=="cockpit" or name=="vessel" then
                            if type(value)=="table" and value.valid==false then return value.reason or "STATE SAMPLE INVALID" end
                        elseif name=="assembly" and type(value)=="table" then return value.error end
                    end,isActive=function() return reader==current and os.__amaryllisStateWorkers==workers end})
            end
        end
    end
end
-- Summary: Read and publish a complete cockpit input sample.
local function sampleCockpit(r)
    local readStarted=now()
    local sample=r:readInputs(readStarted)
    local readCompleted=now()
    local traceRow
    if cockpitTiming then
        local ok,value=pcall(cockpitTiming.read,cockpitTiming,sample,boot,nil,readStarted,readCompleted)
        if ok then traceRow=value end
    end
    local input=Wire.inputFrame(sample)
    if input and reader==r and modem and session and inputSeq<2147483647 then
        inputSeq=inputSeq+1
        local link=modem
        local sentAt=now()
        sample.timing={boot=boot,seq=inputSeq,readStartedAt=readStarted,
            readCompletedAt=sample.at,sendAttemptAt=sentAt}
        input=Wire.inputFrame(sample)
        if traceRow then traceRow.seq=inputSeq end
        local ok=pcall(link.transmit,Wire.CORE_CHANNEL,Wire.STATE_CHANNEL,
            {protocol=Wire.PROTOCOL,kind="cockpit_frame",sender=cfg.computerID,target=cfg.coreID,
                session=session,boot=boot,seq=inputSeq,sentAt=sentAt,input=input})
        if cockpitTiming then pcall(cockpitTiming.sent,cockpitTiming,traceRow,sentAt,now(),ok) end
        if not ok and modem==link then modem=nil end
    end
    return sample
end
workers.jobs.vessel=job("vessel",function(r) return r:sampleVessel(now()) end,10,.5)
workers.jobs.cockpit=job("cockpit",sampleCockpit,5,.2)
workers.jobs.fallback=job("fallback",function(r) return r:sampleFallback(now()) end,4,.5)
workers.jobs.assembly=job("assembly",function(r) return r:sampleAssembly() end,6,2)
workers.jobs.assembler=job("assembler",function(r) return Sources.sampleAssembler(r) end,6,2)
workers.jobs.pressure=job("pressure",function(r) if pressureY then return r:airPressureAtWorldY(pressureY) end end,5,.5)
workers.jobs.discovery=job("discovery",function(r)
    if scanRequested then r:scanHardware();scanRequested=false end
end,10,2)
if shell and shell.openTab and multishell then
    local sampleCockpit=workers.jobs.cockpit
    workers.jobs.cockpit=function() return parallel.waitForAny(sampleCockpit,cockpitPanel) end
end
if rawget(_G,"__AMARYLLIS_STATE_TEST") then return {newReader=newReader,context=context,workers=workers,
    readOnlyPeripheral=readOnlyPeripheral,cockpitLines=cockpitLines,sampleCockpit=sampleCockpit} end
print("ama-state #"..cfg.computerID.." read-only sensor module; waiting for wired core #"..cfg.coreID)
if shell and shell.openTab and multishell then
    for _,name in ipairs({"cockpit","vessel","fallback","assembly","assembler","pressure","discovery"}) do
        local ok,tab=pcall(shell.openTab,"/avionics/state_reader.lua","worker",name,owner)
        assert(ok and type(tab)=="number","STATE READER WORKER FAILED: "..name)
        pcall(multishell.setTitle,tab,name.." reader")
    end
    if fs.exists("/avionics/diagnostics.lua") then pcall(shell.openTab,"/avionics/diagnostics.lua") end
    parallel.waitForAny(network,function()
        if cockpitTiming then cockpitTiming:pulseWorker(os,function()return os.__amaryllisStateWorkers==workers end) end
        while os.__amaryllisStateWorkers==workers do os.pullEventRaw() end
    end)
else
    local tasks={workers.jobs.cockpit,network,function()
        if cockpitTiming then cockpitTiming:pulseWorker(os,function()return os.__amaryllisStateWorkers==workers end) end
        while os.__amaryllisStateWorkers==workers do os.pullEventRaw() end
    end}
    for _,name in ipairs({"vessel","fallback","assembly","assembler","pressure","discovery"}) do tasks[#tasks+1]=workers.jobs[name] end
    parallel.waitForAny(table.unpack(tasks))
end
