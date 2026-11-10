-- Section: Navigator service | Status reception and acknowledged cockpit requests.
-- Bridge UI runtime. Receives vessel state from the registry-assigned core.
-- Owns monitor/touch requests only. No sensor reads or actuator writes.
package.path = "/?.lua;/?/init.lua;" .. (package.path or "")
-- Bridge status boundary. Pure receipt-time/session logic, with no sensors.
-- Receipt logic is tested independently from the UI in this consolidated file.
local Receiver = {}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
-- The core snapshot grows with the fleet (every lift provider is reported),
-- so the entry cap scales with vessel size. It only guards against runaway
-- packets; config.status_max_entries can raise it for very large vessels.
local DEFAULT_MAX_ENTRIES=32768
-- Section: Navigator service | Status reception and acknowledged cockpit requests.
-- Summary: Copy bounded table values into independent operation or transport records.
local function copy(value, depth, budget)
    if depth > 8 then error("status nesting limit",0) end
    if type(value)=="number" then if not finite(value) then error("nonfinite status",0) end; return value end
    if type(value)=="string" then if #value>2048 then error("status string limit",0) end; return value end
    if type(value)=="boolean" or value==nil then return value end
    if type(value)~="table" then error("invalid status value",0) end
    local out={}
    for k,v in pairs(value) do
        budget.n=budget.n+1; if budget.n>budget.max then error("status size limit ("..budget.max.." entries)",0) end
        if type(k)~="string" and type(k)~="number" then error("invalid status key",0) end
        if type(k)=="string" and #k>128 then error("status key limit",0) end
        out[k]=copy(v,depth+1,budget)
    end
    return out
end
function Receiver.new(coreId, timeout, maxEntries)
    if not finite(maxEntries) or maxEntries<1 then maxEntries=DEFAULT_MAX_ENTRIES end
    return setmetatable({coreId=coreId,timeout=timeout,maxEntries=math.floor(maxEntries),retired={},order={}}, {__index=Receiver})
end
-- Summary: Validate and accept the newest navigator snapshot from the trusted core.
function Receiver:accept(sender, message, protocol, now)
    if sender~=self.coreId or protocol~="amaryllis.v1" or type(message)~="table" or
        message.v~=1 or message.kind~="display_status" or type(message.state)~="table" or
        type(message.session)~="string" or #message.session==0 or #message.session>128 or
        not message.session:match("^[%w_%.%-:]+$") or not finite(message.seq) or
        message.seq%1~=0 or message.seq<1 or message.seq>2147483647 or not finite(now) then return false end
    -- From here on the packet is a genuine core display_status, so every
    -- rejection is reported instead of silently leaving the display stale.
    if self.managed and not self.registryIdentity then return false,"no fleet registry binding for this navigator" end
    if self.managed and message.session~=self.registrySession then return false,"display session does not match the fleet registry session" end
    if self.retired[message.session] or (self.session==message.session and message.seq<=self.seq) then return false end
    local ok, state=pcall(copy,message.state,0,{n=0,max=self.maxEntries or DEFAULT_MAX_ENTRIES})
    if not ok then return false,"snapshot rejected: "..tostring(state) end
    if self.session and self.session~=message.session then
        self.retired[self.session]=true; self.order[#self.order+1]=self.session
        if #self.order>32 then self.retired[table.remove(self.order,1)]=nil end
    end
    self.session,self.seq,self.state,self.at=message.session,message.seq,state,now
    return true
end
-- Summary: Copy the latest core snapshot and attach display freshness and receipt age in seconds.
function Receiver:snapshot(now,page)
    local state={}
    for k,v in pairs(self.state or {}) do state[k]=v end
    local fresh=self.at~=nil and now>=self.at and now-self.at<=self.timeout
    state.page=page; state.displayStale=not fresh; state.dataFresh=fresh; state.stale=not fresh
    state.displayAgeSeconds=self.at~=nil and now>=self.at and now-self.at or nil
    return state
end
-- Summary: Update navigator routing from the accepted fleet registry.
function Receiver:setRegistry(session, role, computerID, label)
    self.managed=true
    local key
    if type(session)=="string" and type(role)=="string" and type(computerID)=="number" and type(label)=="string" then
        key=table.concat({session,role,tostring(computerID),label},"|")
    end
    if key~=self.registryIdentity then
        if self.session then
            self.retired[self.session]=true;self.order[#self.order+1]=self.session
            if #self.order>32 then self.retired[table.remove(self.order,1)]=nil end
        end
        self.session,self.seq,self.state,self.at=nil,nil,nil,nil
    end
    self.registryIdentity,self.registrySession=key,session
end

-- Restart requests are authority-bearing messages. Keep their validation
-- pure so the exact boundary can be exercised by the offline UI suite.
local function safeRestartToken(value)
    return type(value)=="string" and #value>0 and #value<=128 and
        value:match("^[%w_%.%-:]+$")~=nil
end
-- Summary: Validate a requested reboot against the configured core, session and local boot.
local function validateRestart(sender,message,protocol,coreId,session,nodeBoot,targetLabel)
    if sender~=coreId or protocol~="amaryllis.v1" or type(message)~="table" or
        message.v~=1 or message.kind~="system_restart" then return false end
    if not safeRestartToken(message.session) or message.session~=session then return false end
    if not safeRestartToken(message.nodeBoot) or message.nodeBoot~=nodeBoot then return false end
    if type(message.targetLabel)~="string" or message.targetLabel~=targetLabel then return false end
    if not safeRestartToken(message.bootToken) or not safeRestartToken(message.requestId) then return false end
    return true
end
-- Summary: Acknowledge and execute the validated role restart request.
local function handleRestart(sender,message,protocol,context,sendAck,reboot)
    context=context or {seen={},order={}}
    context.seen=context.seen or {};context.order=context.order or {}
    if not validateRestart(sender,message,protocol,context.coreId,context.session,
        context.nodeBoot,context.targetLabel) or context.seen[message.requestId] then return false end
    local ack={v=1,kind="system_restart_ack",session=message.session,
        nodeBoot=message.nodeBoot,bootToken=message.bootToken,requestId=message.requestId,
        targetLabel=message.targetLabel,accepted=true,detail="RESTARTING"}
    local ok,result=pcall(sendAck,context.coreId,ack,"amaryllis.v1")
    if not ok or result~=true then return false end
    if type(context.getSession)=="function" then
        local sessionOk,currentSession=pcall(context.getSession)
        if not sessionOk or currentSession~=message.session then return false end
    end
    context.seen[message.requestId]=true
    context.order[#context.order+1]=message.requestId
    if #context.order>32 then context.seen[table.remove(context.order,1)]=nil end
    reboot()
    return true
end
local function currentSessionFresh(receiver,timeout,now)
    return type(receiver)=="table" and type(receiver.session)=="string" and receiver.session~="" and
        finite(receiver.at) and finite(timeout) and finite(now) and now>=receiver.at and now-receiver.at<=timeout
end
-- Summary: Match a navigator command acknowledgement to its active request.
local function bridgeAckMatches(sender,protocol,message,coreId,expectedProtocol,receiver,pending,timeout,now)
    return sender==coreId and protocol==expectedProtocol and type(message)=="table" and
        message.v==1 and message.kind=="bridge_ack" and type(pending)=="table" and
        (pending.status=="PENDING" or pending.status=="UNKNOWN") and finite(now) and finite(pending.at) and now>=pending.at and
        type(receiver)=="table" and (not receiver.managed or receiver.registryIdentity~=nil) and
        message.boot==pending.boot and
        pending.session==receiver.session and message.session==pending.session and message.seq==pending.seq
end

-- Bounded volatile outbox. A retry keeps its original identity and deadline;
-- only a matching core result confirms acceptance. No disk I/O or polling.
local Requests={};Requests.__index=Requests
local priority={emergency_kill_lift=true,systems_stop=true,systems_stop_confirm=true,
    altitude_disengage=true,ap_disengage=true,anchor_cancel=true,tuning_stop=true,
    propulsion_disable=true,tuning_cancel=true,maintenance_cancel=true,systems_stop_cancel=true}
local shortLife={emergency_kill_lift=true,disarm_lift_kill=true,restart_systems=true,
    start_systems=true,recover_systems=true,level_reset=true,systems_stop=true,systems_stop_confirm=true,
    maintenance_confirm=true,maintenance_override=true,tuning_confirm=true,altitude_engage=true,
    anchor_engage=true,ap_engage=true,propulsion_enable=true,ap_current=true,destination_save=true}
local function coalesceKey(action)
    if action.type=="setting_update" and type(action.key)=="string" then return "setting:"..action.key end
    if action.type=="cockpit_mode" and type(action.axis)=="string" then return "mode:"..action.axis end
    if action.type=="destination_select" then return "destination_select" end
end
function Requests.new(coreID,protocol,boot,timeout)
    return setmetatable({coreID=coreID,protocol=protocol,boot=boot,timeout=timeout,
        queue={},records={},order={},sequence=0,limit=8},Requests)
end
function Requests:remember(entry)
    self.records[entry.seq]=entry;self.order[#self.order+1]=entry.seq
    if #self.order>32 then self.records[table.remove(self.order,1)]=nil end
end
function Requests:synchronize(session)
    if session==self.session then return end
    if self.active then self.active.status="CANCELLED";self.active.reason="CORE SESSION CHANGED" end
    for _,e in ipairs(self.queue) do e.status="CANCELLED";e.reason="CORE SESSION CHANGED" end
    self.queue,self.records,self.order,self.active={}, {}, {},nil
    self.session=session
end
-- Summary: Queue a pilot action and supersede older replaceable requests.
function Requests:enqueue(action,receiver,now,epoch)
    self:synchronize(receiver.session)
    if not self.session or receiver.managed and not receiver.registryIdentity then return false,"WAITING FOR CURRENT CORE SESSION" end
    if type(action)~="table" or type(action.type)~="string" or not finite(now) or not finite(epoch) then return false,"INVALID COMMAND" end
    local copiedOK,candidate=pcall(copy,action,0,{n=0,max=128})
    if not copiedOK then return false,"COMMAND TOO LARGE" end
    local key=coalesceKey(candidate)
    -- Replace unsent settings only. Relative adjustments retain their order.
    for i=#self.queue,1,-1 do
        local old=self.queue[i]
        if priority[candidate.type] or key and old.key==key then
            old.status="SUPERSEDED";old.reason="REPLACED BY NEWER COMMAND";table.remove(self.queue,i)
        end
    end
    if self.active and key and self.active.key==key and self.active.attempts==0 then
        self.active.status="SUPERSEDED";self.active.reason="REPLACED BY NEWER COMMAND";self.active=nil
    end
    if priority[candidate.type] and self.active then
        self.active.status="SUPERSEDED";self.active.reason="PRIORITY COMMAND SENT NEXT";self.active=nil
    end
    if #self.queue+(self.active and 1 or 0)>=self.limit then return false,"COMMAND QUEUE FULL" end
    local entry={action=candidate,actionType=candidate.type,key=key,session=self.session,boot=self.boot,
        at=now,expiresAt=epoch+(shortLife[candidate.type] and 10 or 30),status="QUEUED",attempts=0}
    self.queue[#self.queue+1]=entry;self.latest=entry
    return true
end
-- Summary: Send or retry the active navigator command within its session and expiry.
function Requests:step(receiver,now,epoch,send)
    self:synchronize(receiver.session)
    if not finite(now) or not finite(epoch) then return end
    for i=#self.queue,1,-1 do
        local e=self.queue[i]
        if epoch>=e.expiresAt then e.status="CANCELLED";e.reason="UNSENT COMMAND EXPIRED";table.remove(self.queue,i) end
    end
    local e=self.active
    if e and epoch>=e.expiresAt then
        e.status=e.attempts>0 and "UNKNOWN" or "CANCELLED"
        e.reason=e.attempts>0 and "NOT CONFIRMED; CHECK CORE" or "UNSENT COMMAND EXPIRED";self.active=nil;e=nil
    end
    if not e then
        e=table.remove(self.queue,1)
        if not e then return end
        if self.sequence>=2147483647 then e.status="CANCELLED";e.reason="REQUEST SEQUENCE EXHAUSTED";return end
        self.sequence=self.sequence+1;e.seq=self.sequence;self.active=e;self:remember(e)
    end
    if not currentSessionFresh(receiver,self.timeout,now) then
        e.reason="WAITING FOR CORE";return
    end
    if e.nextSend and now<e.nextSend then return end
    -- Publish identity before a yielding send. Retried packets are identical.
    e.status="PENDING";e.attempts=e.attempts+1
    e.reason=e.attempts>1 and "WAITING FOR CORE; RETRYING" or "WAITING FOR CORE"
    e.nextSend=now+math.min(5,2^(e.attempts-1))
    local ok,sent=pcall(send,self.coreID,{v=1,kind="bridge_request",session=e.session,boot=e.boot,
        seq=e.seq,expiresAt=e.expiresAt,action=e.action},self.protocol)
    if not ok or sent~=true then e.reason="WAITING FOR CORE LINK" end
end
function Requests:ack(sender,message,protocol,receiver,now)
    local e=type(message)=="table" and self.records[message.seq] or nil
    if not bridgeAckMatches(sender,protocol,message,self.coreID,self.protocol,receiver,e,self.timeout,now) then return false end
    e.status=message.accepted==true and "ACCEPTED" or "REJECTED";e.reason=message.reason
    if self.active==e then self.active=nil end
    return true
end
function Requests:feedback()
    local e=self.latest;if not e then return nil end
    return {status=e.status,reason=e.reason,seq=e.seq,session=e.session,actionType=e.actionType,
        at=e.at,attempts=e.attempts,queuedCount=#self.queue+(self.active and 1 or 0)}
end

-- Test hook exposes receipt logic without starting peripherals or events.
if rawget(_G,"__AMARYLLIS_BRIDGE_TEST") then
    Receiver.validateRestart=validateRestart
    Receiver.handleRestart=handleRestart
    Receiver.currentSessionFresh=currentSessionFresh
    Receiver.bridgeAckMatches=bridgeAckMatches
    Receiver.Requests=Requests
    return Receiver
end
local Storage=require("avionics.storage")
local UI=require("avionics.ui")
local Console=require("avionics.common.console")
local config,issue=Storage.loadConfig("/avionics/config.json")
if not config then error(issue,0) end
local install=config.install
local function validID(value) return type(value)=="number" and value>=0 and value==math.floor(value) and value<math.huge end
if config.role~="navigator" or not validID(config.core_id) or os.getComputerID()~=config.computer_id or os.getComputerLabel()~=config.label then
    error("Navigator identity does not match its installed registry entry",0)
end
if type(install)~="table" or install.packageId~="amaryllis.navigator" or install.role~="navigator" or
    install.computerID~=os.getComputerID() or not validID(install.coreID) or install.coreID~=config.core_id or
    type(install.version)~="number" or install.version<2 or install.version~=math.floor(install.version) then
    error("Navigator install receipt is invalid",0)
end
-- A missing core registry is transient. Render stale data while the event
-- loop waits for a valid binding; live data and commands remain registry-gated.
local settings,notice=Storage.loadSettings("/avionics/data/settings.json")
if not settings then error(notice,0) end
if notice then print(notice) end
local page=settings.display_page
local receiver=Receiver.new(config.core_id,config.status_timeout_seconds,config.status_max_entries)
local receiveIssue
-- Summary: Reconcile the current role identity with a trusted registry announcement.
local function syncRegistry()
    local registry=os.__amaryllisFleetRegistry
    local entry=type(registry)=="table" and registry.coreID==config.core_id and
        type(registry.computers)=="table" and registry.computers[config.role] or nil
    if type(entry)=="table" and entry.id==os.getComputerID() and entry.label==config.label and
        os.getComputerLabel()==config.label then
        receiver:setRegistry(registry.session,config.role,entry.id,entry.label)
    else receiver:setRegistry(nil,nil,nil,nil) end
end
local renderer,monitorName,lastIssue
-- Role health reports travel over onboard rednet, independently of diagnostics.
local heartbeatSeq,nextHeartbeat=0,0
local heartbeatBoot=tostring(config.computer_id).."-"..string.format("%.0f",os.epoch and os.epoch("utc") or os.clock()*1000)
local requests=Requests.new(config.core_id,config.protocol,heartbeatBoot,config.status_timeout_seconds)
local function requestEpoch() return os.epoch("utc")/1000 end
local restartContext={coreId=config.core_id,targetLabel=os.getComputerLabel(),nodeBoot=heartbeatBoot,
    getSession=function()
        if receiver.at and os.clock()>=receiver.at and os.clock()-receiver.at<=config.status_timeout_seconds then return receiver.session end
        return nil
    end,seen={},order={}}
-- Summary: Resolve the current monitor or network attachment for the role.
local function bind()
    renderer,monitorName=nil,nil
    local monitors={}
    for _,name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name,"modem") then
            local modem=peripheral.wrap(name)
            if modem and type(modem.isWireless)=="function" then
                local ok,wireless=pcall(modem.isWireless)
                if ok and wireless then pcall(rednet.open,name) end
            end
        end
        if peripheral.hasType(name,"monitor") then monitors[#monitors+1]=name end
    end
    if config.hardware.main_monitor~="" then
        for _,name in ipairs(monitors) do if name==config.hardware.main_monitor then monitorName=name end end
    elseif #monitors==1 then monitorName=monitors[1] end
    if monitorName then renderer=UI.new(peripheral.wrap(monitorName),config) end
end
-- Summary: Render the current view into its configured terminal or monitor.
local function draw()
    local snapshot=receiver:snapshot(os.clock(),page)
    requests:synchronize(receiver.session)
    snapshot.bridgeRequest=requests:feedback()
    snapshot.displaySettings=settings
    if renderer then renderer.config.trendFilterAlpha=settings.speed_trend_filter_alpha or .3;renderer.config.trendDeadband=settings.speed_trend_deadband or .025 end
    os.__amaryllisRuntime={publishedAt=os.clock(),snapshot=snapshot,running=true,hardwareAvailable=renderer~=nil,faultSummary=lastIssue or receiveIssue}
    if renderer then
        local ok,result,reason=pcall(renderer.draw,renderer,snapshot)
        local fault=(not ok and tostring(result)) or (result==false and tostring(reason)) or nil
        if fault and fault~=lastIssue then print("Bridge display: "..fault) end
        lastIssue=fault
        if fault then renderer=nil end
    end
end
-- Summary: Validate and dispatch received packets for the current role and session.
local function dispatch(action)
    if type(action)~="table" then return end
    if action.type=="page" or action.type=="display_setting" then
        local candidate={};for k,v in pairs(settings) do candidate[k]=v end
        if action.type=="page" then candidate.display_page=action.page
        elseif action.key=="speed_trend_filter_alpha" or action.key=="speed_trend_deadband" then candidate[action.key]=action.value
        else return end
        local ok,reason=Storage.saveSettings(candidate,"/avionics/data/settings.json")
        if ok then settings=candidate;page=settings.display_page
        elseif action.type=="page" then page=action.page end
        if renderer then renderer.settingsNotice=ok and "DISPLAY PREFERENCE SAVED" or ("NOT SAVED: "..tostring(reason)) end
        if not ok then print("Bridge preferences: "..tostring(reason)) end
    else
        local ok,reason=requests:enqueue(action,receiver,os.clock(),requestEpoch())
        if renderer then renderer.settingsNotice=not ok and reason or nil end
        requests:step(receiver,os.clock(),requestEpoch(),rednet.send)
    end
end
local function touch(side,x,y)
    if side~=monitorName or not renderer then return end
    dispatch(renderer:touch(x,y,receiver:snapshot(os.clock(),page)))
end

syncRegistry();pcall(bind); print("Amaryllis navigator waiting for current core data.")
local timer=os.startTimer(0.2)
while true do
    local event,a,b,c=os.pullEventRaw()
    if event=="terminate" then return
    elseif event=="rednet_message" then
        restartContext.session=restartContext.getSession()
        if Console.acceptRegistry(a,b,c,config.role,os.getComputerID(),config.core_id) then
            syncRegistry()
        elseif handleRestart(a,b,c,restartContext,rednet.send,os.reboot) then
            -- Accepted restart requests reboot after their acknowledgement.
        else
            syncRegistry()
            local accepted,why=receiver:accept(a,b,c,os.clock())
            if accepted then
                if receiveIssue then print("Core data restored.") end
                receiveIssue=nil
            elseif why and why~=receiveIssue then
                receiveIssue=why; print("Core data: "..why)
            end
        end
        requests:synchronize(receiver.session)
        if requests:ack(a,b,c,receiver,os.clock()) then
            print("Core request: "..(b.accepted==true and "ACCEPTED" or "REJECTED").." "..tostring(b.reason or ""))
        end
    elseif event=="monitor_touch" then touch(a,b,c)
    elseif (event=="char" or event=="key") and renderer and receiver.at and os.clock()-receiver.at<=config.status_timeout_seconds then dispatch(renderer:input(event,a))
    elseif event=="peripheral" or event=="peripheral_detach" or event=="monitor_resize" then pcall(bind)
    elseif event=="timer" and a==timer then
        if not renderer then pcall(bind) end
        requests:step(receiver,os.clock(),requestEpoch(),rednet.send)
        draw(); timer=os.startTimer(0.2)
        if receiver.session and os.clock()>=nextHeartbeat then
            heartbeatSeq=math.min(heartbeatSeq+1,2147483647)
            pcall(rednet.send,config.core_id,{v=1,kind="subsystem_status",session=receiver.session,
                boot=heartbeatBoot,seq=heartbeatSeq,label=config.label,role="bridge",
                coreDataFresh=not receiver:snapshot(os.clock(),page).displayStale,
                monitorAttached=renderer~=nil},config.protocol)
            nextHeartbeat=os.clock()+1
        end
    end
end

