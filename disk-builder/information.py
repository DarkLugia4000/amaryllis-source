"""Guarded navigator information, assembly continuity and heading overlays."""
import re

def change(text, old, new, label, count=1):
    """Replace a supported source block or accept its completed replacement."""
    if new and new in text:
        return text
    if text.count(old) != count:
        raise ValueError("Unsupported information source: "+label)
    return text.replace(old,new)

def section(text,start,end,replacement,label):
    """Replace a source section bounded by unique anchors."""
    if text.count(start)!=1 or text.count(end)!=1:
        raise ValueError("Unsupported information section: "+label)
    a=text.index(start);b=text.index(end,a)
    return text[:a]+replacement+text[b:]

def module(payload,path,marker,transform):
    """Apply one idempotent source revision before bundling."""
    text=payload[path].decode("utf-8")
    if marker not in text:
        payload[path]=(marker+"\n"+transform(text)).encode("utf-8")

def strip_notes(payload):
    """Recover functional source beneath generated documentation comments."""
    for path,data in list(payload.items()):
        if path.endswith(".lua"):
            payload[path]=b"".join(line for line in data.splitlines(keepends=True)
                if not line.lstrip().startswith((b"-- @ama-summary:",b"-- @ama-section:")))

def frequencies(text):
    """Validate configured namespace:item pairs and preserve pair uniqueness."""
    text=change(text,'string.match(value, "^minecraft:[a-z0-9_]+_concrete$")',
        'string.match(value, "^[^:]+:[^:]+$")',"frequency item shape")
    text=text.replace("must contain two concrete item IDs","must contain two item IDs in namespace:item form")
    return section(text,"    local expected = {\n","    if not object(config.hardware)","","configured frequency pairs")

def recovery(text):
    """Expose continuing lift recovery with actual command-attempt counts."""
    text=change(text,'    recovery.failed=now-recovery.since>=120','    recovery.failed=false',"recovery elapsed state")
    text=text.replace('state=recovery.failed and "FAILED" or "RETRYING"',
        'state="RETRYING ("..tostring(recovery.attemptCount or 0)..")"')
    start='    if recovery.failed then\n        s.reason="AUXILIARY RECOVERY FAILED AFTER 120 SECONDS: "'
    if start in text:
        a=text.index(start);b=text.index("    return true,s.reason",a);text=text[:a]+text[b:]
    return text

def navigation_retry(text,name):
    """Count paced guidance recovery attempts and reset on successful guidance."""
    old='    self.state=reason=="ABSOLUTE POSITION UNAVAILABLE; SENSOR FALLBACK" and "PAUSED" or (now-self.since>=120 and "RECOVERY_FAILED" or "RECOVERING")'
    new='    self.recoveryAttempts=(self.recoveryAttempts or 0)+1\n    self.nextRecoveryAttemptAt=now+2\n    self.state="RETRYING ("..self.recoveryAttempts..")"'
    text=change(text,old,new,name+" retry count")
    old='    log(self,(self.state=="RECOVERY_FAILED" and "RECOVERY FAILED AFTER 120 SECONDS; RETRYING: " or "RETRYING: ")..reason)'
    text=change(text,old,'    log(self,self.state..": "..reason)',name+" retry log")
    text=text.replace('    self.since=nil;self.reason=nil','    self.since=nil;self.reason=nil;self.recoveryAttempts=0')
    text=text.replace('self.reason=nil;self.since=nil;', 'self.reason=nil;self.since=nil;self.recoveryAttempts=0;self.nextRecoveryAttemptAt=nil;')
    update="function "+("Anchor" if name=="anchor" else "AP")+":update(io,now,controls)"
    at=text.index(update);end=text.index("\n",text.index("if not self.active then",at))+1
    return text[:end]+'    if self.since and self.nextRecoveryAttemptAt and now<self.nextRecoveryAttemptAt and self.recoveryObservedAt==(io.vessel or {}).at then return nil,self.reason end\n    self.recoveryObservedAt=(io.vessel or {}).at\n'+text[end:]

def startup(text):
    """Track initial-acquisition presentation separately from physical control."""
    text=change(text,'    self.systemsRun={phase="PROBING",',
        '    self.initialAcquisitionEnded=false\n    self.initialAcquisitionTarget=prepared.target\n    self.systemsRun={phase="PROBING",',"initial acquisition lifecycle")
    text=change(text,'    s.phase="READY";s.phaseStartedAt=now;s.lastControlAt=now',
        '    self.initialAcquisitionEnded=true\n    s.phase="READY";s.phaseStartedAt=now;s.lastControlAt=now',"capture display completion")
    old='    if self.systemsRun then\n        snapshot.systemsStartup.target=self.systemsRun.target'
    new='''    if self.systemsRun then
        local s=self.systemsRun
        local selected=self.controls and self.controls.targets and self.controls.targets.altitude
        local presentationTarget=self.initialAcquisitionTarget or s.target
        if finite(selected) and selected~=presentationTarget then self.initialAcquisitionEnded=true end
        local displayPhase=s.phase
        if s.phase=="READY" then displayPhase="READY"
        elseif s.phase=="CONTROL_START" then displayPhase="OPENING STEAM VENTS"
        elseif s.phase=="BUILDING_LIFT" then
            if self.initialAcquisitionEnded or s.airborneStart then displayPhase="READY"
            else displayPhase=s.launchMotionVerified and "ACQUIRING SEL ALT" or "STATIC INFLATION" end
        end
        snapshot.systemsStartup.displayPhase=displayPhase
        snapshot.systemsStartup.target=self.systemsRun.target'''
    text=change(text,old,new,"startup display")
    text=change(text,'            snapshot.systemsStartup.phase="LAUNCH"',
        '            snapshot.systemsStartup.phase="LAUNCH"\n            snapshot.systemsStartup.displayPhase="CAPTURING PITCH ZERO"',"settling presentation")
    anchor='    snapshot.anchorControl=io.positionAnchor and io.positionAnchor:snapshot() or {active=false,state="OFF"}'
    return change(text,anchor,anchor+'\n    if type(io.assemblyGate)=="function" then\n        local _,_,assembly=io:assemblyGate(now);snapshot.assembly=assembly\n    end\n',"assembly warning snapshot")

def apply_assembly(payload):
    """Apply Sable-first assembly verification and retained identity adoption."""
    def io_patch(text):
        return section(text,'function IO:assemblyGate(now)\n',
            '-- Normal runtime discovery wakes all four lift nodes.',ASSEMBLY_GATE,"Sable-first assembly gate")
    module(payload,"/avionics/io.lua","-- Sable-first assembly verification v1",io_patch)
    # Select retained identity and fresh fallback fields under the assembly rule.
    def sources(text):
        old='''    local id=primaryID or backupID
    local assembled=not track or (track.definite==true and fresh(now,track.definiteAt,18))
    local identityConflict=primaryID and backupID and primaryID~=backupID
    if identityConflict or not assembled then id=nil end'''
        new='''    local id=primaryID or backupID or io.retainedVesselUUID or
        (io.fallbackCalibration and io.fallbackCalibration.uuid)
    if primaryID or backupID then io.retainedVesselUUID=primaryID or backupID end
    local assemblerFresh=track and fresh(now,track.definiteAt,limit)
    if not primaryID and assemblerFresh and track.definite==false then id=nil end'''
        text=change(text,old,new,"peripheral fallback retained identity")
        old_block='''    if track and track.definite==false then
        io.fallbackCalibration=nil;io.primaryVessel=nil;io.primaryReadings={}
        io.vessel={valid=false,at=now,reason="VESSEL DISASSEMBLED",positionUnavailable=true,sources={mode="UNAVAILABLE"}}
        return io.vessel
    end'''
        text=change(text,old_block,"","early assembler observation")
        anchor='    if not primaryID and assemblerFresh and track.definite==false then id=nil end'
        text=change(text,anchor,anchor+'\n'+old_block.replace('if track and track.definite==false then',
            'if not primaryID and assemblerFresh and track.definite==false then'),"confirmed disassembly source")
        text=text.replace('identityConflict and "VESSEL IDENTITY SOURCES DISAGREE" or ','')
        old='    io.primaryReadings=io.primaryReadings or {}\n    local old=io.primaryReadings.uuid'
        new='    io.primaryReadings=io.primaryReadings or {}\n    local previous=io.primaryReadings[key]\n    if not finite(at) or (previous and finite(previous.at) and (at<previous.at or (key=="uuid" and at==previous.at and previous.value~=checked))) then return false end\n    local old=io.primaryReadings.uuid'
        text=change(text,old,new,"primary observation ordering")
        return text.replace('v.sources.identitySource=primaryID and "SABLE" or "PHYSICS ASSEMBLER"',
            'v.sources.identitySource=primaryID and "SABLE" or (backupID and "PHYSICS ASSEMBLER" or "RETAINED ASSOCIATION")')
    module(payload,"/avionics/vessel_sources.lua","-- Retained vessel association v1",sources)
    def flight(text):
        anchor='function Flight:update(io,now)\n'
        return change(text,anchor,ADOPT+anchor+'    self:adoptVesselIdentity(io,now)\n',"coordinated vessel association")
    module(payload,"/avionics/flight.lua","-- Vessel association adoption v1",flight)
    # Carry assembler read errors and advance state-side verification timing.
    def wire(text):
        old='function Wire.frame(reader)\n    return copy({primary=reader.primaryReadings or {},fallback=reader.fallbackReadings or {},'
        new='function Wire.frame(reader)\n    if type(reader.assemblyGate)=="function" then reader:assemblyGate(reader:nowSeconds()) end\n    return copy({primary=reader.primaryReadings or {},fallback=reader.fallbackReadings or {},'
        text=change(text,old,new,"state verification clock")
        old='    io.statePressureCache={}'
        new='''    if type(data.assembly)=="table" and type(data.assembly.error)=="string" then
        io.assemblyTrack=io.assemblyTrack or {}
        io.assemblyTrack.error=data.assembly.error:sub(1,512)
    end
    io.statePressureCache={}'''
        return change(text,old,new,"assembly read errors")
    module(payload,"/avionics/state_wire.lua","-- State assembly verification v1",wire)

def apply_ui(payload):
    """Apply startup labels, message colours and local current-issue navigation."""
    # Add current-issue rendering and intercept its local navigation touches.
    def ui(text):
        text=change(text,'local UI = {}','local UI = {}\nlocal Info',"issue helper scope")
        text=section(text,'local function emergencyLift(snapshot, live)\n',
            'local function balancedLift(snapshot)',KILL,"kill state messages")
        text=text.replace('"HOLD OFF","gray"','"ALT OFFLINE","gray"')
        old='''        local phaseText = systems.phase == "BUILDING_LIFT" and "BUILD" or tostring(systems.phase or "STARTING")
        local detail = "SYSTEMS " .. phaseText'''
        new='''        local phaseText=systems.displayPhase or (systems.phase=="BUILDING_LIFT" and "BUILD" or tostring(systems.phase or "STARTING"))
        local detail=systems.displayPhase and phaseText or ("SYSTEMS "..phaseText)'''
        text=change(text,old,new,"startup phase label")
        text=change(text,'if phase=="ABORTED" then return "ABORTED","red" end',
            'if systems and systems.displayPhase=="READY" then return "READY","cyan" end\n    if phase=="ABORTED" then return "ABORTED","red" end',"initial acquisition completed indicator")
        text=change(text,'        button(29,16,27,"DEBUG MODE",view("DEBUG"))',
            '        button(2,16,26,"CURRENT ISSUES",view("ISSUES"))\n        button(29,16,27,"DEBUG MODE",view("DEBUG"))',"issues settings entry")
        text=change(text,'function UI.new(monitor, config)',UI_HELPER+'\nfunction UI.new(monitor, config)',"issue helpers")
        text=change(text,'    local actionSnapshot=snapshot','    local actionSnapshot=snapshot\n    self.informationSnapshot=snapshot',"raw issue observations")
        text=change(text,'        surface = drawSystemsMenu(surface,self,actionSnapshot)',
            '''        surface = drawSystemsMenu(surface,self,actionSnapshot)
        if not self.killReview and not actionSnapshot.systemsStopReview and not self.systemsMenu then
            surface=Info.warning(surface,self,snapshot,now)
            surface=Info.draw(surface,self,snapshot,now)
        end''',"shared warnings and issues")
        anchor='    if x<1 or x>width or y<1 or y>height or x%1~=0 or y%1~=0 then return nil end'
        return change(text,anchor,anchor+'\n    if Info.touch(self,x,y,snapshot,width) then return nil end',"warning touch interception")
    module(payload,"/packages/navigation/ui.lua","-- Navigator information pages v1",ui)
    payload["/avionics/flight.lua"]=payload["/avionics/flight.lua"].replace(b'"MAX CLIMB"',b'"MAX CLB"').replace(b'"LIFT SUPPORT"',b'"V/S DEMAND LIM"')
    def display(text):
        return change(text,'{"active","phase","abortReason"}','{"active","phase","displayPhase","abortReason"}',"heading phase transport")
    module(payload,"/avionics/display_payload.lua","-- Information heading transport v1",display)
    # Carry initial-acquisition completion through the heading sanitizer.
    def heading(text):
        text=text.replace('"HOLD OFF"','"ALT OFFLINE"')
        text=change(text,'    if phase=="ABORTED" then return "ABORTED","red" end',
            '    if systems and systems.displayPhase=="READY" then return "READY","cyan" end\n    if phase=="ABORTED" then return "ABORTED","red" end',"heading acquisition complete")
        anchor='        result.systemsStartup={}'
        return change(text,anchor,anchor+'\n        local labels={["OPENING STEAM VENTS"]=true,["STATIC INFLATION"]=true,["CAPTURING PITCH ZERO"]=true,["ACQUIRING SEL ALT"]=true,READY=true}\n        if labels[systems.displayPhase] then result.systemsStartup.displayPhase=systems.displayPhase end',"heading display sanitizer")
    for side in ("left","right","main"):
        module(payload,"/packages/heading/"+side+"/main.lua","-- Information heading labels v1",heading)

def apply(payload):
    """Upgrade validated editable modules before the documentation and bundle passes."""
    module(payload,"/avionics/storage.lua","-- Navigator information frequency revision v1",frequencies)
    module(payload,"/avionics/telemetry_recovery.lua","-- Navigator information retry revision v1",recovery)
    module(payload,"/avionics/autopilot.lua","-- Navigator information AP retry revision v1",lambda text:navigation_retry(text,"AP"))
    module(payload,"/avionics/anchor.lua","-- Navigator information anchor retry revision v1",lambda text:navigation_retry(text,"anchor"))
    module(payload,"/avionics/flight.lua","-- Navigator information startup revision v1",startup)
    apply_assembly(payload)
    apply_ui(payload)


ASSEMBLY_GATE = '''function IO:assemblyGate(now)
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

'''


ADOPT = '''-- Rebind a fresh Sable association across retained control references.
function Flight:adoptVesselIdentity(io,now)
    local v=io.vessel or {}
    local observed=(io.primaryReadings or {}).uuid
    local stale=(io.config.network or {}).sensor_stale_seconds or 18
    if v.valid~=true or not observed or observed.value~=v.uuid or not finite(observed.at) or
        now<observed.at or now-observed.at>stale or
        (self.vesselAdoptedAt and observed.at<=self.vesselAdoptedAt) then return end
    local old=self.uuid or (self.systemsRun or {}).uuid or (self.controls or {}).uuid
    if not old or old==v.uuid then return end
    local track=io.assemblyTrack
    local uncertain=not track or track.error~=nil or not finite(track.definiteAt) or
        now-track.definiteAt>stale
    if not uncertain then return end
    self.vesselAdoptedAt=observed.at
    local function rebind(value,depth,seen)
        if type(value)~="table" or depth>8 or seen[value] then return end
        seen[value]=true
        for key,item in pairs(value) do
            if (key=="uuid" or key=="headingTargetUuid" or key=="speedTargetUuid") and item==old then
                value[key]=v.uuid
            elseif type(item)=="table" then rebind(item,depth+1,seen) end
        end
    end
    for _,value in ipairs({self,self.controls,io.autopilot or {},io.positionAnchor or {},
        io.controlPresets or {}}) do rebind(value,0,{}) end
    if self.restart and self.restart.saved then self.restart:write(self.restart.saved) end
    if io.controlPresets then io.controlPresets:update(io,self,now) end
    if type(os.__amaryllisLog)=="function" then os.__amaryllisLog("Vessel association updated: "..old.." -> "..v.uuid,"core.identity") end
end

'''


KILL = '''local function emergencyLift(snapshot, live)
    local lift=type(snapshot.emergencyLift)=="table" and snapshot.emergencyLift or {}
    local request=type(snapshot.bridgeRequest)=="table" and snapshot.bridgeRequest or {}
    local phase=string.upper(tostring(lift.phase or ""))
    local latched=live and (lift.latched==true or lift.complete==true or phase=="KILL CONFIRMED")
    local disarming=live and (lift.disarming==true or
        (request.actionType=="disarm_lift_kill" and requestWaiting(request)))
    if disarming then return {disarm=true,pending=true,label="DISARMING",
        message="DISARMING KILL; SYSTEMS STOPPED",tone="yellow"} end
    if live and phase=="KILL INCOMPLETE" then return {disarm=latched,failed=true,label=latched and "DISARM KILL" or "KILL LIFT",
        message="KILL LIFT INCOMPLETE "..tostring(lift.reason or ""),tone="yellow"} end
    if live and (lift.pending==true or phase=="KILLING" or phase=="RECHECKING AFTER REBOOT") then
        return {disarm=latched,pending=true,label="KILL LIFT",message="KILL LIFT PENDING",tone="yellow"}
    end
    if latched then return {disarm=true,label="DISARM KILL",
        message="KILL LIFT ARMED; DISARM BEFORE START",tone="red"} end
    if request.actionType=="emergency_kill_lift" then
        if requestWaiting(request) then return {pending=true,label="KILL LIFT",message="KILL LIFT PENDING",tone="yellow"} end
        if request.status=="ACCEPTED" then return {accepted=true,label="KILL LIFT",message="KILL REQUEST ACCEPTED",tone="yellow"} end
        if request.status=="REJECTED" then return {failed=true,label="KILL LIFT",
            message="KILL LIFT FAILED "..tostring(request.reason or ""),tone="red"} end
        if request.status=="UNKNOWN" or request.status=="CANCELLED" then return {failed=true,label="KILL LIFT",
            message="KILL NOT CONFIRMED; CHECK CORE",tone="yellow"} end
    end
    return {label="KILL LIFT"}
end
'''


UI_HELPER = '''-- Navigator current issues and warning navigation v1
Info={}
-- Collect active notices from the same cached snapshot used by navigation.
function Info.collect(renderer,snapshot)
    local live=isLive(snapshot);local items,seen={},{}
    local function add(id,message,tone,source,detail)
        if type(message)~="string" or message=="" or seen[id] then return end
        seen[id]=true
        items[#items+1]={id=id,text=message,tone=tone or "yellow",source=source,detail=detail}
    end
    local kill=emergencyLift(snapshot,live)
    add("kill",kill.message,kill.tone,"core")
    local assembly=assemblyProblem(snapshot,live)
    if assembly then add("assembly-lock",assembly.message or assembly.reason or "VESSEL DISASSEMBLED","red","state") end
    local check=snapshot.assembly or {}
    if live then add("assembly-unverified",check.warning,"yellow","state",
        check.unverifiedSeconds and ("UNVERIFIED "..math.floor(check.unverifiedSeconds).."s")) end
    local fleet=fleetBootProblem(snapshot,live)
    if fleet then add("fleet",fleet.reason or "FLEET NOT READY","red","core") end
    local conflict=snapshot.identityConflict or {}
    if live and conflict.active then add("duplicate-id",conflict.text,"red","core",conflict.detail) end
    add("altitude-abort",altitudeAbortMessage(snapshot,live),"red","core")
    add("lift-capacity",balancedLiftWarning(snapshot,live),"red","core")
    local v=snapshot.vessel or {}
    if sensorAvailable(snapshot,v,"altitude",live) and v.altitude>=290 then
        add("air-pressure","ALTITUDE AIR PRESSURE WARNING","red","core")
    end
    local motion=snapshot.motionWarnings or {}
    if live and motion.active then add("motion",motion.text,motion.tone,"core") end
    local systems=snapshot.systemsStartup or {};local recovery=systems.recovery or {}
    if systems.phase=="SUSPENDED" and recovery.state then
        add("lift-recovery","LIFT "..recovery.state,"yellow","core",recovery.reason)
    end
    for _,key in ipairs({"autopilot","anchorControl"}) do
        local r=snapshot[key] or {};local state=tostring(r.state or "")
        if r.active and state:find("RETRYING",1,true) then
            add(key.."-recovery",(key=="autopilot" and "AP " or "ANCHOR ")..state,
                "yellow","core",r.reason)
        end
    end
    local issue=firstThrustIssue(snapshot,live)
    local duplicate=false
    for _,fault in ipairs(snapshot.faults or {}) do
        if issue==tostring(fault) or issue=="FAULT "..tostring(fault) then duplicate=true end
    end
    local endpointIssue=false
    if live then
        local thrust=thrustSnapshot(snapshot)
        for _,spec in ipairs({{thrust.roles,thrustControllerLabels,true},{thrust.units,thrustDataLabels,false}}) do
            if type(spec[1])=="table" then
                for _,label in ipairs(spec[2]) do
                    local role=spec[1][label]
                    local status=roleDisplayStatus(role,live,spec[3])
                    if status~="RDY" and status~="CMD" and status~="LIVE" then
                        endpointIssue=true
                        local detail=roleFaultText(role) or (type(role)=="table" and role.reason)
                        add("endpoint-"..label,label.." "..status,status=="FAULT" and "red" or "yellow",label,detail)
                    end
                end
            end
        end
    end
    if issue and not duplicate and not endpointIssue then
        add("propulsion",issue,issue:find("FAULT",1,true) and "red" or "yellow","core")
    end
    local cockpit=snapshot.cockpitControl or {}
    if live and cockpit.reason then add("cockpit",cockpit.reason,"yellow","core")
    elseif live and (cockpit.headingWaitingForNeutral or cockpit.throttleWaitingForNeutral or cockpit.altitudeWaitingForNeutral) then
        add("neutral","RETURN CONTROLS TO NEUTRAL","yellow","core")
    end
    add("command",requestNotice(snapshot.bridgeRequest),"yellow","bridge")
    local anchor=snapshot.anchorControl or {}
    if anchor.active and renderer.anchorInputNoticeUntil and (os.clock()<=renderer.anchorInputNoticeUntil) then
        add("anchor-input","ANCHOR ENGAGED - RELEASE ANCHOR TO USE CONTROLS","yellow","core")
    end
    for n,fault in ipairs(snapshot.faults or {}) do
        add("reported-fault:"..tostring(fault),tostring(fault),"red","core")
    end
    for _,q in ipairs({"FL","FR","RL","RR"}) do
        local node=(snapshot.nodes or {})[q] or {}
        local source="chamber-"..({FL="fl",FR="fr",RL="bl",RR="br"})[q]
        for n,fault in ipairs(node.faults or (node.status or {}).faults or {}) do
            add(source.."-fault:"..tostring(fault),tostring(fault),"red",source)
        end
    end
    add("action",renderer.actionNotice,"yellow","bridge")
    return items
end
-- Choose the rotating warning while retaining a stable per-issue age.
function Info.choose(renderer,items,now)
    local ages=renderer.issueAges or {};renderer.issueAges=ages
    local active,top,rank={},0,{red=3,yellow=2,green=1}
    for _,item in ipairs(items) do
        active[item.id]=true;ages[item.id]=ages[item.id] or now;item.since=ages[item.id]
        top=math.max(top,rank[item.tone] or 2)
    end
    for id in pairs(ages) do if not active[id] then ages[id]=nil end end
    local eligible={}
    for _,item in ipairs(items) do if (rank[item.tone] or 2)==top then eligible[#eligible+1]=item end end
    local current,index=renderer.warningID,nil
    for n,item in ipairs(eligible) do if item.id==current then index=n end end
    if not index then index=1;renderer.warningChangedAt=now
    elseif now-(renderer.warningChangedAt or now)>=3 then
        index=index%#eligible+1;renderer.warningChangedAt=now
    end
    local chosen=eligible[index]
    renderer.warningID=chosen and chosen.id or nil
    return chosen
end
-- Record the displayed touch target and draw plain warning text.
function Info.warning(surface,renderer,snapshot,now)
    local items=Info.collect(renderer,renderer.informationSnapshot or snapshot)
    renderer.currentIssues=items
    local chosen=Info.choose(renderer,items,now)
    renderer.warningRegion=nil
    if chosen then
        fillRect(surface,1,21,surface.width,1,"black","white")
        local text=clampText(chosen.text,surface.width-2)
        put(surface,2,21,text,chosen.tone)
        renderer.warningRegion={x1=2,x2=1+#text,y=21,id=chosen.id}
    end
    return finishSurface(surface)
end
-- Open the shared issues page and retain its invoking view.
function Info.open(renderer,id)
    renderer.issuesParent={page=renderer.page,settingsView=renderer.settingsView,
        settingsOffset=renderer.settingsOffset,shipView=renderer.shipView,navView=renderer.navView}
    renderer.issuesOpen=true;renderer.issuesOffset=0;renderer.issueFocus=id
    for n,item in ipairs(renderer.currentIssues or {}) do if item.id==id then renderer.issuesOffset=math.floor((n-1)/4)*4 end end
end
-- Render active issues in four readable entries with cached status details.
function Info.draw(surface,renderer,snapshot,now)
    if not renderer.issuesOpen then return surface end
    renderer.systemsMenu=nil;renderer.warningRegion=nil
    fillRect(surface,1,5,surface.width,17,"black","white")
    centered(surface,5,"CURRENT ISSUES","cyan")
    local items=renderer.currentIssues or {}
    local offset=math.max(0,math.min(renderer.issuesOffset or 0,math.max(0,math.floor((#items-1)/4)*4)))
    renderer.issuesOffset=offset
    if #items==0 then centered(surface,10,"NO CURRENT ISSUES","green") end
    for n=1,4 do
        local item=items[offset+n]
        if item then
            local y=6+(n-1)*3
            put(surface,2,y,(item.id==renderer.issueFocus and "> " or "")..clampText(item.text,surface.width-4),item.tone)
            local lines=wrapErrorText(item.detail or "",surface.width-2)
            if lines[1] then put(surface,2,y+1,lines[1],"lightGray") end
            put(surface,2,y+2,tostring(item.source or "core").." | ACTIVE "..math.floor(math.max(0,now-(item.since or now))).."s","gray")
        end
    end
    drawButton(surface,2,5,15,"< BACK","enabled")
    drawButton(surface,19,19,16,"< PREVIOUS",offset>0 and "enabled" or "disabled")
    drawButton(surface,37,19,surface.width-38,"NEXT >",offset+4<#items and "enabled" or "disabled")
    centered(surface,20,tostring(#items).." ACTIVE | "..tostring(math.floor(offset/4)+1).."/"..tostring(math.max(1,math.ceil(#items/4))),"gray")
    return finishSurface(surface)
end
-- Handle issue navigation locally before underlying cockpit touch targets.
function Info.touch(renderer,x,y,snapshot,width)
    if renderer.killReview or snapshot.systemsStopReview then return false end
    if renderer.issuesOpen then
        if y==5 and x>=2 and x<=16 then
            local parent=renderer.issuesParent or {}
            renderer.issuesOpen=false
            for _,key in ipairs({"page","settingsView","settingsOffset","shipView","navView"}) do renderer[key]=parent[key] end
        elseif y==19 and x>=19 and x<=34 then renderer.issuesOffset=math.max(0,(renderer.issuesOffset or 0)-4)
        elseif y==19 and x>=37 then renderer.issuesOffset=(renderer.issuesOffset or 0)+4 end
        return true
    end
    local r=renderer.warningRegion
    if r and y==r.y and x>=r.x1 and x<=r.x2 then Info.open(renderer,r.id);return true end
    if renderer.page=="SETTINGS" and (renderer.settingsView or "GENERAL")=="GENERAL" and y==16 and x>=2 and x<=27 then
        Info.open(renderer);return true
    end
    return false
end
'''
