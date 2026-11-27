-- Section: Navigator graphics | Cached telemetry, pixel pages and operator actions.
-- The navigator owns presentation and requests. Core retains actuator authority.
local P=require('avionics.pixels')
local UI={KILL_REVIEW_SECONDS=10}
UI.PAGES={'FLIGHT','NAV','SHIP','SETTINGS'}
local quads={'FL','FR','BL','BR'}
local roles={FL='lb',FR='rb',BL='ls',BR='rs'}
-- Summary: Validate finite telemetry or editor numbers before arithmetic.
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
-- Summary: Copy small actions and snapshots independently of mutable editor state.
local function copy(v)
    if type(v)~='table' then return v end
    local out={};for k,x in pairs(v) do out[k]=copy(x) end
    return out
end
-- Summary: Format an available measurement, retaining unavailable fields as dashes.
local function number(v,decimals,signed)
    if not finite(v) then return '--' end
    return string.format('%'..(signed and '+' or '')..'.'..(decimals or 1)..'f',v)
end
-- Summary: Resolve receipt freshness without extending control validity.
local function live(s) return s.displayStale~=true and s.dataFresh~=false and s.stale~=true end
-- Summary: Identify explicit disassembly from the core's assembly observations.
local function disassembled(s)
    local a=s.assembly or s.assemblyStatus or {}
    return a.state=='DISASSEMBLED' or a.assembled==false or (s.vessel or {}).assembled==false
end
-- Summary: Read a current vessel field only while its cached sample is valid.
local function vessel(s,key)
    local v=s.vessel or {}
    return live(s) and v.valid~=false and (v.validFields or {})[key]~=false and v[key..'Valid']~=false and v[key] or nil
end
-- Summary: Select the first current issue for the common message line.
-- Reads receipt validity, assembly, emergency, fleet and fault state to choose one current status message.
local function issue(r,s)
    if not live(s) then return 'WAITING FOR FRESH CORE STATUS','yellow' end
    if disassembled(s) then return 'VESSEL DISASSEMBLED','red' end
    local kill=s.emergencyLift or {}
    if kill.latched then return 'KILL LIFT ARMED','red' end
    local fleet=s.fleetBoot or s.fleetStartup or {}
    if fleet.blocked or fleet.ready==false then return fleet.reason or 'FLEET NOT READY','yellow' end
    if (s.identityConflict or {}).active then return s.identityConflict.text or 'IDENTITY CONFLICT','red' end
    if #(s.faults or {})>0 then local fault=tostring(s.faults[1]);return fault,fault:find('CHECK BOILER',1,true) and 'yellow' or 'red' end
    local motion=s.motionWarnings or {}
    if motion.active then return motion.text or 'MOTION WARNING',motion.tone or 'yellow' end
    if (s.bridgeRequest or {}).status=='REJECTED' then return s.bridgeRequest.reason or 'REQUEST REJECTED','yellow' end
    if (s.autopilot or {}).reason then return s.autopilot.reason,'yellow' end
    if r.actionNotice or r.settingsNotice then return r.actionNotice or r.settingsNotice,'yellow' end
    local systems=s.systemsStartup or {}
    if systems.phase=='ABORTED' then return systems.reason or 'SYSTEMS ABORTED','red' end
    return 'STATUS CLEAR','green'
end
-- Summary: Gate outgoing actions against current receipt, assembly and emergency locks.
-- Stop, cancellation and the emergency kill remain available during fleet faults.
local function allowed(s,a)
    if not live(s) then return false end
    local stop={emergency_kill_lift=true,disarm_lift_kill=true,systems_stop=true,systems_stop_confirm=true,
        systems_stop_cancel=true,ap_disengage=true,anchor_cancel=true,tuning_stop=true,tuning_cancel=true,
        maintenance_cancel=true,propulsion_disable=true}
    local kill=s.emergencyLift or {}
    if (a.type=='emergency_kill_lift' or a.type=='disarm_lift_kill') and (kill.pending or kill.disarming or kill.phase=='KILLING' or kill.phase=='RECHECKING AFTER REBOOT') then return false end
    if stop[a.type] then return true end
    if a.type=='start_systems' and ((s.systemsStartup or {}).available~=true or (s.systemsStartup or {}).active) then return false end
    if a.type=='restart_systems' and (s.systemsRestart or {}).available~=true then return false end
    if a.type=='level_reset' and (s.systemsStartup or {}).phase~='READY' then return false end
    if a.type=='manual_trim_adjust' or a.type=='manual_trim_reset' then
        if (s.trimControl or {}).manualTrimAvailable~=true then return false end
    end
    if a.type=='cockpit_mode' and ((s.cockpitControl or {}).available~=true or (s.autopilot or {}).active or (s.anchorControl or {}).active) then return false end
    if disassembled(s) and a.type~='setting_update' and a.type~='debug_mode' then return false end
    local fleet=s.fleetBoot or s.fleetStartup or {}
    if (fleet.blocked or fleet.ready==false) and not ({setting_update=true,debug_mode=true,maintenance_probe_cycle=true})[a.type] then return false end
    if (s.emergencyLift or {}).latched and ({start_systems=true,restart_systems=true,ap_engage=true,ap_route_engage=true})[a.type] then return false end
    return true
end
-- Summary: Construct the graphics renderer and its local editing state.
function UI.new(monitor,config)
    if type(monitor)~='table' or type(monitor.getSize)~='function' or
        type(monitor.drawPixels)~='function' or type(monitor.setGraphicsMode)~='function' then
        return nil,'NAVIGATOR REQUIRES CC: GRAPHICS'
    end
    config=config or {}
    if monitor.setTextScale then monitor.setTextScale(config.textScale or .5) end
    return setmetatable({monitor=monitor,config=config,page='FLIGHT',shipView='PROP',navSection='MAIN',
        navMode='single',settingsView='GENERAL',settingsOffset=0,selectedDestination=1,selectedWaypoint=1,
        listOffset=0,regions={},propellerAngles={}}, {__index=UI})
end
-- Summary: Paint a bounded action using both local availability and core safety gates.
function UI:button(f,x,y,w,h,label,action,s,enabled,selected,danger)
    local active=enabled~=false and (action.localAction or allowed(s,action))
    f:button(x,y,w,h,label,action,active,selected,danger)
end
-- Summary: Build a local navigation action that never leaves the renderer.
local function localAction(kind,fields)
    local a=fields or {};a.localAction=kind
    return a
end
-- Summary: Paint the same vessel, page and status positions on every screen.
-- Reads the active page and systems snapshot, paints shared positions and records the dropdown hit area.
function UI:header(f,s)
    f:rect(5,4,3,3,'purple');f:rect(2,7,3,3,'purple');f:rect(8,7,3,3,'purple');f:rect(5,10,3,3,'purple');f:pixel(6,8,'yellow')
    f:text(17,6,'A.E.V. AMARYLLIS','white');f:text(113,6,'|','gray')
    f:text(125,6,self.page=='NAV' and 'NAVIGATION' or self.page,'cyan')
    local ap=s.autopilot or {};local system=s.systemsStartup or {};local status,tone
    if not live(s) then status='CORE STALE';tone='yellow'
    elseif ap.active then status='AP - '..tostring(ap.state or 'ACQ');tone='purple'
    elseif (s.emergencyLift or {}).latched then status='KILL ARMED';tone='red'
    elseif system.active and system.phase=='READY' then status='SYSTEMS ONLINE';tone='green'
    elseif system.active then status='SYS '..tostring(system.displayPhase or system.phase or 'STARTING');tone='yellow'
    else status='SYSTEMS OFF';tone='gray' end
    f:text(329-math.min(#status*6-1,132),6,status,tone,1,132)
    f:line(333,8,336,11,'gray');f:line(336,11,339,8,'gray');f:line(3,19,338,19)
    f.regions[#f.regions+1]={x=197,y=0,w=145,h=19,action=localAction('systems'),enabled=true}
end
-- Summary: Paint persistent main navigation and retain clickable page regions.
function UI:footer(f)
    f:line(3,195,338,195)
    for i,page in ipairs(UI.PAGES) do
        f:button(3+(i-1)*85,200,81,15,page=='NAV' and 'NAVIGATION' or page,
            localAction('page',{page=page}),true,self.page==page)
    end
end
-- Summary: Place current errors or the empty-state status on the shared bottom line.
function UI:status(f,s)
    local text,tone=issue(self,s)
    f:line(3,178,338,178);f:text(5,184,text,tone,1,330)
end
-- Summary: Read one current chamber control state from its reported state field.
local function chamberControl(status,node,key,current)
    local value=status[key] or node[key]
    if current and ({RDY=true,CMD=true,FAULT=true,INFL=true,DEFL=true})[value] then return value end
    return 'FAULT'
end
-- Summary: Colour chamber readiness and commanded activity consistently.
local function chamberTone(state)
    return state=='FAULT' and 'red' or state=='RDY' and 'green' or state=='OFFLINE' and 'gray' or 'yellow'
end
-- Summary: Resolve a chamber's validated gas total, target and measured lift.
-- Sums provider flow and targets; reads the representative balloon gas amount in m3 and lift, with separate readiness and control states.
local function chamber(s,id)
    local node=(s.nodes or {})[id] or {};local status=node.status or node
    local balloon=status.balloon or node.balloon or {};local gas,target=0,0
    local validGas,validTarget,count=true,true,0
    for _,p in pairs(status.providers or node.providers or {}) do
        count=count+1
        if p.gasOutputValid==true and finite(p.gasOutput) then gas=gas+p.gasOutput else validGas=false end
        if p.targetValid==true and finite(p.targetAmount) then target=target+p.targetAmount else validTarget=false end
    end
    local current=live(s) and node.online==true
    -- Balloon inventory is a single representative reading, independent of provider flow in m3/tick.
    local gasAmount=current and balloon.hasBalloonValid==true and balloon.hasBalloon==true and
        balloon.gasMixValid==true and finite(balloon.gasMixAmount) and balloon.gasMixAmount>=0 and balloon.gasMixAmount or nil
    return {online=current,gasAmount=gasAmount,gas=current and validGas and count>0 and gas or nil,target=current and validTarget and count>0 and target or nil,
        lift=current and balloon.liftValid==true and balloon.lift or nil,
        state=current and ((status.ready or node.ready) and next(status.faults or node.faults or {})==nil and 'RDY' or 'FAULT') or 'OFFLINE',
        thrustState=chamberControl(status,node,'thrustControlState',current),
        liftState=chamberControl(status,node,'liftControlState',current)}
end
-- Summary: Read a fresh signed main-shaft RPM from a validated endpoint sample.
-- Reads endpoint freshness and per-field validity before returning the signed speedRaw observation.
local function rpm(s,side)
    local endpoint=((s.thrust or {}).units or {})['primary-'..side] or {}
    if not live(s) or endpoint.online~=true or endpoint.statusFresh~=true then return nil end
    local readings=endpoint.readings or endpoint
    if (endpoint.validity or readings.validity or {}).speedRaw==true and finite(readings.speedRaw) then return readings.speedRaw end
    for _,sample in ipairs(readings) do
        if (sample.validity or {}).speedRaw==true and finite(sample.speedRaw) then return sample.speedRaw end
    end
end
-- Summary: Distinguish missing engine endpoints from temporary telemetry loss.
-- Reads discovery and fresh sensor inventory; a lost core or stale sample stays yellow rather than declaring hardware missing.
function UI:engineTone(s,side)
    if not live(s) then return 'yellow','WAITING' end
    local endpoint=((s.thrust or {}).units or {})['primary-'..side]
    if not endpoint or endpoint.discovered==false then return 'red','MISSING' end
    if endpoint.online~=true or endpoint.statusFresh~=true then return 'yellow','WAITING' end
    if endpoint.available==false and #(endpoint.readings or {})==0 then return 'red','MISSING' end
    if not finite(rpm(s,side)) then return 'yellow','WAITING' end
    return 'white','READY'
end
-- Summary: Animate a four-blade propeller from RPM and elapsed receipt time.
-- Unavailable RPM freezes the angle in the supplied health colour; the capped visual rate preserves legibility.
function UI:propeller(f,cx,cy,side,value,now,size,tone)
    tone=tone or (finite(value) and 'white' or 'yellow')
    local a=self.propellerAngles[side] or 0
    if finite(value) then
        local dt=math.min(.5,math.max(0,now-(self.propellerAt or now)))
        a=a+(value<0 and -1 or 1)*math.min(math.abs(value)/60,.8)*2*math.pi*dt
        self.propellerAngles[side]=a
    end
    for i=0,3 do
        local angle=a+i*math.pi/2
        f:line(cx+math.cos(angle)*3,cy+math.sin(angle)*3,cx+math.cos(angle)*size,cy+math.sin(angle)*size,tone)
    end
    f:rect(cx-1,cy-1,3,3,tone)
end
-- Summary: Paint mode selectors and gate them while AP or anchor owns control.
-- Reads retained pilot modes and ownership locks and creates the heading, throttle and strafe touch regions.
function UI:modes(f,s)
    local modes=s.modes or {};local unlocked=not (s.autopilot or {}).active and not (s.anchorControl or {}).active and
        (s.cockpitControl or {}).available==true and not (s.lateralControl or {}).locked
    for _,row in ipairs({{axis='heading',y=23,x=5,label='HDG',values={'MANUAL','SEL'},labels={'MANUAL','SEL HDG'}},
        {axis='lateral',y=23,x=172,label='STRAFE',values={'MANUAL','SEL'},labels={'MANUAL','SEL STRAFE'}},
        {axis='throttle',y=37,x=5,label='THR',values={'MANUAL','SEL','DIRECT'},labels={'MAN THR','SEL SPD','DIR RPM'}}}) do
        f:text(row.x,row.y+2,row.label,'cyan')
        local start=row.x+(row.axis=='lateral' and 42 or 24)
        local width=row.axis=='lateral' and 48 or (row.axis=='heading' and 68 or 96)
        for i,mode in ipairs(row.values) do
            local buttonWidth=row.axis=='lateral' and i==2 and 68 or width
            self:button(f,start+(i-1)*(width+3),row.y,buttonWidth,11,row.labels[i],{type='cockpit_mode',axis=row.axis,mode=mode},s,unlocked,modes[row.axis]==mode)
        end
    end
end
-- Summary: Filter fresh speed samples into the local speed trend indication.
-- Reads absolute speed and sample time, resets after stale data and applies the configured smoothing and deadband.
function UI:speedTrend(s)
    local speed=vessel(s,'forwardSpeed')
    local at=(s.vessel or {}).at or s.updatedAt
    if not finite(speed) or not finite(at) then
        self.speedSample=nil;self.speedSlope=nil;return '--','gray'
    end
    local prior=self.speedSample
    if prior and at==prior.at then
        -- Repainting one receipt retains its trend until another observation arrives.
    elseif prior and at>prior.at and at-prior.at<=10 then
        local slope=(math.abs(speed)-prior.speed)/(at-prior.at)
        local alpha=math.max(.05,math.min(1,self.config.trendFilterAlpha or .3))
        self.speedSlope=finite(self.speedSlope) and self.speedSlope*(1-alpha)+slope*alpha or slope
    else self.speedSlope=nil end
    self.speedSample={at=at,speed=math.abs(speed)}
    local threshold=self.config.trendDeadband or .025
    if not finite(self.speedSlope) then return '--','gray' end
    if self.speedSlope>threshold then return 'UP','green' end
    if self.speedSlope< -threshold then return 'DOWN','yellow' end
    return 'STEADY','gray'
end
-- Summary: Render the Flight overview with engine, attitude and envelope telemetry.
-- Reads measured speed, engine output, attitude and chamber fields into the approved overview.
function UI:flight(f,s,now)
    self:modes(f,s)
    f:line(3,52,338,52);f:text(5,59,'SPEED','cyan')
    f:text(5,71,number(vessel(s,'forwardSpeed'),1,true),'white',2,108)
    local trend,tone=self:speedTrend(s)
    f:text(5,91,'B/S','gray');f:text(35,91,trend,tone);f:text(108,59,'MAIN ENGINES','cyan')
    local thrust=s.thrust or {};local requested=thrust.requested or {}
    for i,side in ipairs({'left','right'}) do
        local x=108+(i-1)*40
        local tone=self:engineTone(s,side)
        self:propeller(f,x+10,78,side,rpm(s,side),now,8,tone)
        f:text(x,92,(i==1 and 'L ' or 'R ')..number(live(s) and requested['primary-'..side] and requested['primary-'..side]*100,0),tone,1,45)
    end
    f:line(3,105,178,105);f:text(5,113,'HEADING CONTROL','cyan')
    local hc=thrust.headingControl or {};f:text(5,127,live(s) and (hc.state or hc.reason or '--') or 'UNAVAILABLE','white',1,174)
    f:text(5,146,'HDG '..number(vessel(s,'heading'),1),'white')
    f:text(105,146,'TGT '..number((s.targets or {}).heading,1),'yellow')
    f:text(5,159,'ALT '..number(vessel(s,'altitude'),1)..' V/S '..number(vessel(s,'verticalSpeed'),2,true),'white',1,174)
    f:center(184,59,74,'PITCH '..number(vessel(s,'pitch'),1,true),'white')
    f:center(262,59,74,'ROLL '..number(vessel(s,'roll'),1,true),'white')
    for i,ids in ipairs({{'FL','BL'},{'FR','BR'}}) do
        local x=184+(i-1)*78
        f:envelope(x,76,74,100)
        for j,id in ipairs(ids) do
            local c=chamber(s,id);local y=j==1 and 82 or 132
            f:text(x+7,y,id,'cyan');f:text(x+25,y,c.online and 'ONLINE' or 'OFFLINE',c.online and 'green' or 'red',1,43)
            f:text(x+7,y+8,'THR '..c.thrustState,chamberTone(c.thrustState),1,59)
            f:text(x+7,y+16,'LIFT '..c.liftState,chamberTone(c.liftState),1,63)
            f:text(x+7,y+24,'TGT '..number(c.target,0),'yellow',1,59)
            f:text(x+7,y+32,'GAS '..number(c.gasAmount,0),'white',1,63)
        end
    end
    self:status(f,s)
end
-- Summary: Paint Ship subtabs and the detailed lift, propulsion or trim view.
-- Reads the selected Ship subtab and paints its detailed telemetry, trim actions and status line.
function UI:ship(f,s,now)
    for i,name in ipairs({'LIFT','PROP','TRIM'}) do
        f:button(61+(i-1)*76,24,68,15,name,localAction('ship',{view=name}),true,self.shipView==name)
    end
    f:line(3,44,338,44)
    if self.shipView=='LIFT' then
        f:center(0,50,342,'LIFT CHAMBERS','cyan');f:text(18,50,'BOW','gray')
        f:line(12,53,4,53);f:line(4,53,8,49);f:line(4,53,8,57)
        for i,ids in ipairs({{'FL','BL'},{'FR','BR'}}) do
            local top=i==1 and 65 or 121;local y=top+10
            f:text(14,top,i==1 and 'PORT' or 'STARBOARD','cyan');f:oval(5,y,331,41,true)
            for j,id in ipairs(ids) do
                local x=j==1 and 37 or 187;local c=chamber(s,id)
                f:text(x+30,y+7,id,'cyan');f:text(x+54,y+7,c.state,(c.state=='FAULT' or c.state=='OFFLINE') and 'red' or 'green',1,65)
                f:text(x-5,y+16,'GAS '..number(c.gas,2),'white',1,59)
                f:text(x+55,y+16,'TGT '..number(c.target,0),'yellow',1,76)
                f:text(x+30,y+27,'LIFT '..number(c.lift,0),'white',1,95)
            end
        end
    elseif self.shipView=='TRIM' then
        local t=s.trimControl or {};local available=t.manualTrimAvailable==true
        f:text(5,50,'FORE/AFT TRIM','cyan');f:text(244,50,t.active and 'AUTO TRIM ACTIVE' or 'TRIM IDLE',t.active and 'green' or 'gray',1,94)
        f:text(5,65,'MANUAL BIAS '..number(t.manualForeAftBias,1,true)..' B','yellow')
        f:text(5,79,'TARGET BOW-STERN '..number(t.manualTargetForeAftHeightDifferenceBlocks,2,true)..' B','white',1,210)
        f:text(5,91,'ACTUAL BOW-STERN '..number(t.foreAftHeightDifferenceBlocks or t.foreAftHeightDifference,2,true)..' B','white',1,210)
        f:text(218,70,'PITCH '..number(vessel(s,'pitch'),1,true));f:text(218,83,'ROLL '..number(vessel(s,'roll'),1,true))
        f:line(3,104,338,104)
        for i,delta in ipairs({-.1,.1,-.5,.5}) do
            local x=i%2==1 and 5 or 178;local y=i<=2 and 110 or 131
            local candidate=(t.manualForeAftBias or 0)+delta
            self:button(f,x,y,157,15,(delta<0 and 'STERN UP ' or 'BOW UP ')..number(delta,1,true),{type='manual_trim_adjust',delta=delta},s,
                available and candidate>=(t.manualTrimMinimum or -2) and candidate<=(t.manualTrimMaximum or 2))
        end
        f:text(5,155,'LEARNED ROLL '..number(t.coarseSteamTrimRoll,2,true),'gray')
        f:text(184,155,'PITCH '..number(t.coarseSteamTrimPitch,2,true),'gray')
        self:button(f,5,175,159,15,'RESET BIAS TO ZERO',{type='manual_trim_reset'},s,available)
        self:button(f,178,175,157,15,'RESET LEVELING',localAction('level_review'),s,true)
        return
    else
        local t=s.thrust or {};local requested=t.requested or {}
        f:text(5,50,'MAIN ENGINES','cyan')
        for i,side in ipairs({'left','right'}) do
            local x=i==1 and 5 or 178;local value=rpm(s,side)
            local tone,state=self:engineTone(s,side)
            f:text(x,63,i==1 and 'PORT' or 'STARBOARD',tone=='white' and 'cyan' or tone);self:propeller(f,x+12,85,side,value,now,12,tone)
            f:text(x+32,76,'REQ '..number(live(s) and requested['primary-'..side] and requested['primary-'..side]*100,0)..'%','yellow')
            f:text(x+32,88,'RPM '..number(value,1,true),tone)
            f:text(x+32,100,state,state=='READY' and 'green' or tone,1,132)
        end
        f:line(3,113,338,113);f:text(5,119,'LATERAL DRIVES','cyan');f:text(269,119,'REQ/APPLIED','gray')
        for i,id in ipairs(quads) do
            local x=i%2==1 and 5 or 178;local y=i<=2 and 132 or 154
            local quad=roles[id];local node=(t.roles or {})['thrust-'..quad] or {}
            local current=live(s) and node.online==true and node.statusFresh==true
            f:text(x,y,id,'cyan');f:text(x+24,y,current and (node.thrustControlState or 'WAIT') or 'OFFLINE',current and 'green' or 'gray')
            local line=''
            for _,side in ipairs({'p','s'}) do
                local drive='lateral-'..quad..'-'..side;local req=(node.requested or {})[drive]
                local readback=(node.readbacks or {})[drive] or {}
                local applied=current and node.readbackFresh and readback.valid and readback.shiftLevel or nil
                line=line..string.upper(side)..' '..number(current and finite(req) and req*100,0)..'/'..number(finite(applied) and applied/256*100,0)..'%'..' '
            end
            f:text(x,y+10,line,'white',1,159)
        end
    end
    self:status(f,s)
end
-- Summary: Open an editor bound to a specific draft, saved entry or playlist item.
function UI:openEditor(key,label,value,action)
    self.editor={key=key,label=label,buffer=tostring(value or ''),action=copy(action)}
    self.actionNotice=nil
end
-- Summary: Paint a click-to-edit field using its current value and commit action.
function UI:field(f,x,y,w,label,value,key,action,s)
    f:text(x,y,label,'cyan');f:button(x,y+11,w,22,'',localAction('edit',{key=key,label=label,value=value,commit=action}),live(s))
    f:text(x+6,y+18,number(value,1),'yellow',1,w-12)
end
-- Summary: Show dedicated AP progress in place of Navigation setup while active.
-- Reads active route progress, paints phase chevrons and current and next destination data with cancellation.
function UI:autopilot(f,s)
    local ap=s.autopilot or {};local route=ap.route or {};local entries=route.entries or {};local index=route.index or 1
    local current=entries[index] or ap.destination or {};local nextEntry=entries[index+1]
    local waypoints=route.kind=='waypoints' or #entries>1
    f:phases(ap.state);f:text(5,49,waypoints and ('WAYPOINT '..index..'/'..#entries) or 'DESTINATION','cyan')
    f:text(5,62,current.name or current.label or '--','white',2,330)
    f:text(5,84,'TARGET X '..number(current.x,1)..' Z '..number(current.z,1),'purple',1,330)
    if waypoints and nextEntry then f:text(5,98,'NEXT '..tostring(nextEntry.name or '--')..' X '..number(nextEntry.x,0)..' Z '..number(nextEntry.z,0),'white',1,330) end
    f:line(3,111,338,111)
    for i,data in ipairs({{'DIST B',ap.distance,nil},{'SPD B/S',vessel(s,'forwardSpeed'),ap.requestedSpeed},
        {'HDG DEG',vessel(s,'heading'),ap.requestedHeading},{'ALT Y',vessel(s,'altitude'),(s.targets or {}).altitude}}) do
        local x=({5,94,180,266})[i]
        f:text(x,119,data[1],'cyan');f:text(x,133,number(data[2],1))
        if data[3] then f:text(x,147,'TARGET '..number(data[3],1),'purple',1,76) end
    end
    f:line(3,160,338,160)
    f:text(5,168,ap.reason or ('CROSS-TRACK '..number(ap.crossTrack and math.abs(ap.crossTrack),1)..' B '..(finite(ap.crossTrack) and ap.crossTrack<0 and 'LEFT' or 'RIGHT')),ap.reason and 'yellow' or 'cyan',1,330)
    f:line(5,187,204,187)
    for x=5,205,20 do f:line(x,184,x,190) end
    if finite(ap.crossTrack) then f:rect(104+math.max(-99,math.min(99,ap.crossTrack*2)),181,3,11,'purple') end
    self:button(f,227,174,108,15,'CANCEL AP',{type='ap_disengage'},s)
end
-- Summary: Render destination setup and the independent saved/ordered lists.
-- Reads draft, library and playlist data into independent local lists and binds validated editing actions.
function UI:navigation(f,s)
    local ap=s.autopilot or {}
    if ap.active then self:autopilot(f,s);return end
    local draft=ap.destination or {};local advanced=self.navSection=='ADVANCED'
    f:button(101,24,66,15,'MAIN',localAction('nav_section',{view='MAIN'}),true,not advanced)
    f:button(175,24,66,15,'ADVANCED',localAction('nav_section',{view='ADVANCED'}),true,advanced);f:line(3,44,338,44)
    if not advanced then
        f:text(5,50,'DESTINATION','cyan')
        for _,d in ipairs({{5,65,'X','x'},{184,65,'Z','z'},{5,110,'ALTITUDE','altitude'},{184,110,'SPEED B/S','cruiseSpeed'}}) do
            self:field(f,d[1],d[2],150,d[3],draft[d[4]],d[4],{type='ap_edit',key=d[4]},s)
        end
        self:button(f,5,155,166,15,'USE CURRENT POSITION',{type='ap_current'},s)
        f:button(179,155,156,15,'SAVED DESTINATIONS',localAction('nav_section',{view='ADVANCED'}),true)
        self:button(f,5,177,330,15,'ENGAGE AP',{type='ap_engage'},s,ap.available)
        return
    end
    local route=self.navMode=='route';local picking=self.addFromSaved==true
    f:button(35,49,132,15,'SINGLE DESTINATION',localAction('nav_mode',{mode='single'}),true,not route)
    f:button(175,49,132,15,'WAYPOINT ROUTE',localAction('nav_mode',{mode='route'}),true,route)
    local entries=(route and not picking) and ap.playlist or (ap.library or {}).entries or {}
    entries=entries or {}
    local selected=(route and not picking) and self.selectedWaypoint or self.selectedDestination
    selected=math.max(1,math.min(selected or 1,#entries));local entry=entries[selected]
    if route and not picking then self.selectedWaypoint=selected else self.selectedDestination=selected end
    self.listOffset=math.max(0,math.min(self.listOffset or 0,math.max(0,#entries-3)))
    f:text(5,71,picking and 'ADD FROM SAVED' or route and 'WAYPOINT ROUTE' or 'SAVED DESTINATIONS','cyan')
    f:line(158,86,158,155)
    for i=1,3 do
        local index=(self.listOffset or 0)+i;local item=entries[index]
        if item then f:button(5,88+(i-1)*22,145,19,((route and not picking) and index..' ' or '')..(item.name or '--'),
            localAction('highlight',{index=index,route=route and not picking}),true,false)
            if index==selected then f:rect(5,88+(i-1)*22,145,19,'cyan',true) end
        end
    end
    if #entries>3 then
        f:button(5,152,70,9,'PREV',localAction('list_page',{delta=-3}),true)
        f:button(80,152,70,9,'NEXT',localAction('list_page',{delta=3,count=#entries}),true)
    end
    if entry then
        f:text(168,88,'SELECTED '..(route and not picking and 'WAYPOINT' or 'DESTINATION'),'cyan',1,168)
        local commitType=route and not picking and 'ap_route_edit' or 'destination_edit'
        f:button(168,99,168,13,'',localAction('edit',{key='name',label='NAME',value=entry.name,commit={type=commitType,index=selected,key='name'}}),live(s) and not picking)
        f:text(172,102,entry.name or '--','yellow',1,160)
        for i,key in ipairs({'x','z','altitude','cruiseSpeed'}) do
            local val=entry[key] or draft[key];local y=113+(i-1)*11
            f:text(168,y,({x='X',z='Z',altitude='ALT',cruiseSpeed='SPEED'})[key],'cyan')
            f:button(216,y-2,119,11,'',localAction('edit',{key=key,label=key,value=val,commit={type=commitType,index=selected,key=key}}),live(s) and not picking)
            f:text(222,y,number(val,1),'yellow',1,110)
        end
    end
    if picking then
        f:button(5,175,159,15,'CANCEL',localAction('end_pick'),true)
        self:button(f,178,175,157,15,'ADD WAYPOINT',{type='ap_route_add',destinationIndex=selected},s,entry~=nil)
    elseif route then
        f:button(5,162,138,15,'ADD FROM SAVED',localAction('pick'),true)
        f:button(150,162,52,15,'EDIT',localAction('edit_selected',{route=true}),entry~=nil)
        self:button(f,209,162,66,15,'REMOVE',{type='ap_route_remove',index=selected},s,entry~=nil)
        for i,delta in ipairs({-1,1}) do
            local x=282+(i-1)*29
            self:button(f,x,162,24,15,'',{type='ap_route_move',index=selected,direction=delta},s,entries[selected+delta]~=nil)
            f:line(x+7,delta<0 and 171 or 166,x+12,delta<0 and 166 or 171,'white');f:line(x+12,delta<0 and 166 or 171,x+17,delta<0 and 171 or 166,'white')
        end
        self:button(f,5,179,330,15,'START ROUTE',{type='ap_route_engage'},s,#entries>0)
    else
        self:button(f,5,162,104,15,'ADD',{type='destination_save'},s,(ap.library or {}).writable and draft.x~=nil and draft.z~=nil)
        f:button(116,162,104,15,'EDIT',localAction('edit_selected'),entry~=nil)
        self:button(f,227,162,108,15,'REMOVE',{type='destination_delete',index=selected},s,entry~=nil and (ap.library or {}).writable)
        self:button(f,5,179,330,15,'GO TO',{type='ap_saved_engage',index=selected},s,entry~=nil)
    end
end

-- Section: Settings | Existing configuration groups, numeric edits and diagnostics.
local settingsGroups={
    GENERAL={{'COCKPIT INPUTS','TARGET'},{'PID / LIMITS','PID'},{'NAV / ANCHOR','NAV'},
        {'DISPLAY','DISPLAY'},{'PROPULSION','PROPULSION'},{'LIFT MAINTENANCE','MAINTENANCE'},
        {'CURRENT ISSUES','ISSUES'},{'DEBUG','DEBUG'},{'SYSTEMS','SYSTEMS'}},
    TARGET={{'SEL HEADING','SEL HEADING'},{'SEL THROTTLE','SEL THROTTLE'},
        {'ALTITUDE SELECTOR','INPUT ALTITUDE'},{'STRAFE SETTINGS','STRAFE SETTINGS'},{'GENERAL LIMITS','GENERAL LIMITS'}},
    PID={{'ALTITUDE PID / LIMITS','ALT PID'},{'VERTICAL SPEED PID','VS PID'},
        {'ACTUATOR / HOVER / TRIM','LIMITS'},{'STARTUP SHAPING','STARTUP'},{'TRIM PID','TRIM PID'},{'BOUNDED TESTS','TUNING'}},
    NAV={{'DIGITAL ANCHOR','ANCHOR'},{'ANCHOR SETTINGS','NAV ANCHOR'},{'AUTOPILOT SETTINGS','NAV AUTOPILOT'}},
    ['PROP PID']={{'SPEED PID','PROP SPEED PID'},{'ACCELERATION PID','PROP ACCEL PID'},{'HEADING PID','PROP YAW PID'}},
}
local settingParents={TARGET='GENERAL',PID='GENERAL',NAV='GENERAL',DISPLAY='GENERAL',PROPULSION='GENERAL',MAINTENANCE='GENERAL',
    ISSUES='GENERAL',DEBUG='GENERAL',SYSTEMS='GENERAL',['PROP PID']='PROPULSION',['PROP LIMITS']='PROPULSION',
    ['GENERAL LIMITS']='TARGET',ANCHOR='NAV',['TRIM PID']='PID',['SEL HEADING']='TARGET',['SEL THROTTLE']='TARGET',['INPUT ALTITUDE']='TARGET',['STRAFE SETTINGS']='TARGET',
    ['ALT PID']='PID',['VS PID']='PID',LIMITS='PID',STARTUP='PID',TUNING='PID',['NAV ANCHOR']='NAV',['NAV AUTOPILOT']='NAV',
    ['PROP SPEED PID']='PROP PID',['PROP ACCEL PID']='PROP PID',['PROP YAW PID']='PROP PID'}
-- Summary: Paint existing settings as grouped buttons or paged bounded values.
-- Reads the settings group and core fields, paints bounded controls and records their action regions.
function UI:settings(f,s)
    local sub=self.settingsView or 'GENERAL';local title=sub=='GENERAL' and 'SETTINGS' or sub
    f:center(0,29,342,title,'cyan');f:line(3,42,338,42)
    local groups=settingsGroups[sub]
    if groups then
        for i,entry in ipairs(groups) do
            local full=sub=='GENERAL' and i==9
            local x=full and 5 or i%2==1 and 5 or 178
            local y=sub=='GENERAL' and (50+math.floor((i-1)/2)*29) or (52+math.floor((i-1)/2)*31)
            f:button(x,y,full and 330 or 157,full and 17 or 23,entry[1],localAction('settings',{view=entry[2]}),true)
        end
    elseif sub=='ISSUES' then
        local faults=copy(s.faults or {})
        local current=issue(self,s)
        if current~='STATUS CLEAR' then table.insert(faults,1,current) end
        for i=1,8 do f:text(5,51+(i-1)*15,faults[(self.settingsOffset or 0)+i] or (i==1 and 'STATUS CLEAR' or ''),#faults>0 and 'yellow' or 'green',1,330) end
        self.settingsPageSize=8
        if #faults>8 then f:button(178,175,157,15,'NEXT',localAction('settings_page',{count=#faults}),true) end
    elseif sub=='ANCHOR' then
        local anchor=s.anchorControl or {}
        f:center(5,57,330,anchor.active and 'POSITION HOLD ACTIVE' or 'POSITION HOLD OFF',anchor.active and 'purple' or 'gray')
        f:center(5,82,330,'X '..number((anchor.point or {}).x,1)..' Z '..number((anchor.point or {}).z,1),'white')
        f:center(5,105,330,'SPEED '..number(anchor.horizontalSpeed,1)..' B/S','white')
        self:button(f,5,137,330,24,anchor.active and 'RELEASE ANCHOR' or 'ENGAGE ANCHOR',
            {type=anchor.active and 'anchor_cancel' or 'anchor_engage'},s,anchor.active or anchor.available)
    elseif sub=='DEBUG' then
        local d=s.debugMode or {}
        self:button(f,5,55,330,22,d.enabled and 'STOP DEBUG RECORDING' or 'START DEBUG RECORDING',{type='debug_mode',enabled=not d.enabled},s,not d.pending)
        f:text(5,92,'RUN '..tostring(d.runID or '--'),'white',1,330)
        f:text(5,108,'BYTES '..number(d.bytes,0)..' DROPPED '..number(d.dropped,0),'white',1,330)
        if d.reason then f:text(5,128,d.reason,'yellow',1,330) end
    elseif sub=='SYSTEMS' then
        for i,a in ipairs(self:systemItems(s)) do
            self:button(f,5,48+(i-1)*24,330,20,a.label,a.action,s,a.enabled,false,a.danger)
        end
        f:button(5,147,330,20,'RESET LEVELING',localAction('level_review'),true)
    elseif sub=='MAINTENANCE' then
        local m=s.maintenance or {}
        f:text(5,50,'COM Y '..number(m.altitude,1)..' '..(m.locked and 'LOCKED' or ''),'yellow')
        self:button(f,5,67,159,19,'PROBE RESET',{type='maintenance_probe_cycle',scope='ALL'},s)
        self:button(f,178,67,157,19,'HARDWARE RECHECK',{type='maintenance_recheck',scope='ALL'},s,not m.job)
        for i,scope in ipairs({'ALL','FL','FR','BL','BR'}) do
            self:button(f,5+(i-1)*67,100,63,20,scope,{type='maintenance_review',scope=scope},s,not m.job)
        end
        f:text(5,90,'RESTART LIFT COMPUTERS','cyan')
        f:text(5,139,m.status or 'STATUS CLEAR',m.status and 'yellow' or 'green',1,330)
    elseif sub=='TUNING' then
        local t=s.tuning or {}
        if t.active then
            f:text(5,55,'TEST '..tostring(t.mode)..' '..tostring(t.phase),'yellow')
            f:text(5,80,'TARGET '..number(t.target,2)..' REMAINING '..number(t.remaining,1))
            f:text(5,102,'PEAK '..number(t.peakError,3)..' RMS '..number(t.rmsError,3))
            self:button(f,5,130,330,22,'STOP TEST',{type='tuning_stop'},s)
        else
            for i,d in ipairs({{'V/S +0.1','VS',1},{'V/S -0.1','VS',-1},{'ALTITUDE +1','ALT',1},{'ALTITUDE -1','ALT',-1}}) do
                self:button(f,i%2==1 and 5 or 178,i<=2 and 55 or 90,157,24,d[1],{type='tuning_review',mode=d[2],direction=d[3]},s,t.available)
            end
            if t.reason then f:text(5,132,t.reason,'yellow',1,330) end
            f:text(5,149,(t.result or {}).status or '--','white',1,330)
        end
    else
        local entries={}
        for _,entry in ipairs((s.settings or {}).entries or {}) do if entry.group==(sub=='GENERAL LIMITS' and 'GENERAL' or sub) then entries[#entries+1]=entry end end
        if sub=='DISPLAY' then
            local prefs=s.displaySettings or {}
            entries={{key='speed_trend_filter_alpha',label='Speed trend filter',value=prefs.speed_trend_filter_alpha or .3,min=.05,max=1,step=.05,localSetting=true},
                {key='speed_trend_deadband',label='Speed trend deadband',value=prefs.speed_trend_deadband or .025,min=0,max=1,step=.005,localSetting=true}}
        end
        if sub=='PROPULSION' then
            local t=(s.settings or {}).thrust or {}
            self:button(f,5,48,330,17,t.enabled and 'DISABLE PROPULSION' or 'ENABLE PROPULSION',{type=t.enabled and 'propulsion_disable' or 'propulsion_enable'},s,t.enabled or t.enableAvailable)
            f:button(5,69,159,17,'PID GAINS',localAction('settings',{view='PROP PID'}),true)
            f:button(178,69,157,17,'LIMITS',localAction('settings',{view='PROP LIMITS'}),true)
        end
        local top=sub=='PROPULSION' and 93 or 51
        local offset=self.settingsOffset or 0
        self.settingsPageSize=math.min(6,math.floor((168-top)/19))
        for i=1,self.settingsPageSize do
            local e=entries[offset+i]
            if e then
                local y=top+(i-1)*19;local valid=finite(e.value)
                self:button(f,5,y,24,15,'-',{type=e.localSetting and 'display_setting' or 'setting_update',key=e.key,value=valid and math.max(e.min,e.value-e.step)},s,valid)
                f:button(35,y,270,15,(e.label or e.key)..' '..number(e.value,3),localAction('setting_edit',{entry=e}),live(s) and valid)
                self:button(f,312,y,24,15,'+',{type=e.localSetting and 'display_setting' or 'setting_update',key=e.key,value=valid and math.min(e.max,e.value+e.step)},s,valid)
            end
        end
        if #entries>self.settingsPageSize then f:button(178,175,157,15,'NEXT',localAction('settings_page',{count=#entries}),true) end
    end
    if sub~='GENERAL' then f:button(5,175,159,15,'BACK',localAction('settings',{view=settingParents[sub] or 'GENERAL'}),true) end
    if sub=='GENERAL' then local message,tone=issue(self,s);f:text(5,187,message,tone,1,330) end
end
-- Summary: Paint a single editor with a numeric or QWERTY key layout.
-- Reads editor type and buffer, paints numeric or letter keys and binds local Save and Cancel actions.
function UI:keyboard(f,s)
    local e=self.editor
    f:center(0,28,342,'EDIT '..e.label,'cyan')
    f:rect(5,44,332,25,'gray',true);f:text(14,53,e.buffer,'yellow',1,310)
    local name=e.key=='name'
    if name then
        for row,letters in ipairs({'QWERTYUIOP','ASDFGHJKL','ZXCVBNM'}) do
            local left=row==2 and 22 or 6
            for i=1,#letters do f:button(left+(i-1)*33,79+(row-1)*23,29,19,letters:sub(i,i),localAction('key',{key=letters:sub(i,i)}),true) end
        end
        f:button(249,125,84,19,'DEL',localAction('key',{key='DEL'}),true)
        f:button(5,148,200,19,'SPACE',localAction('key',{key='SPACE'}),true)
        f:button(213,148,122,19,'CLEAR',localAction('key',{key='CLEAR'}),true)
    else
        for row,keys in ipairs({{'7','8','9','-'},{'4','5','6','.'},{'1','2','3','DEL'},{'0','CLEAR'}}) do
            for col,key in ipairs(keys) do f:button(5+(col-1)*85,79+(row-1)*23,76,19,key,localAction('key',{key=key}),true) end
        end
    end
    if self.actionNotice then f:text(5,169,self.actionNotice,'yellow',1,330) end
    f:button(5,176,159,15,'CANCEL',localAction('key',{key='CANCEL'}),true)
    f:button(178,176,157,15,'SAVE',localAction('key',{key='SAVE'}),live(s),true)
end
-- Summary: Resolve Systems menu availability from the fresh core snapshot.
-- Reads current systems and kill state to return the four dropdown actions with availability.
function UI:systemItems(s)
    local sys=s.systemsStartup or {};local restart=s.systemsRestart or {};local kill=s.emergencyLift or {}
    return {{label='START SYSTEMS',action={type='start_systems'},enabled=sys.available==true and not sys.active and not kill.latched},
        {label='STOP SYSTEMS',action={type='systems_stop'},enabled=sys.active or sys.phase=='ABORTED' or (s.altitudeControl or {}).enabled},
        {label='RESTART SYSTEMS',action={type='restart_systems'},enabled=restart.available==true and not kill.latched},
        {label=kill.latched and 'DISARM KILL' or 'KILL LIFT',action=kill.latched and {type='disarm_lift_kill'} or localAction('kill_review'),
            enabled=not kill.pending and not kill.disarming and kill.phase~='KILLING' and kill.phase~='RECHECKING AFTER REBOOT',danger=not kill.latched}}
end
-- Summary: Overlay the centered Systems dropdown without passing touches beneath it.
function UI:menu(f,s)
    f.regions={};f:rect(180,22,160,95,'black');f:rect(180,22,160,95,'gray',true)
    for i,item in ipairs(self:systemItems(s)) do
        self:button(f,186,27+(i-1)*22,148,18,item.label,item.action,s,item.enabled,false,item.danger)
    end
end
-- Summary: Overlay explicit confirmations and preserve token-bearing core reviews.
-- Reads local and token-bearing reviews, captures every hit region and paints the matching confirmation.
function UI:review(f,s,now)
    local review=self.reviewKind;local stop=s.systemsStopReview;local maintenance=(s.maintenance or {}).review;local tuning=(s.tuning or {}).review
    if self.killReview and now-self.killReview>UI.KILL_REVIEW_SECONDS then self.killReview=nil end
    if not self.killReview and not review and not stop and not maintenance and not tuning then return false end
    f.regions={};f:rect(5,48,332,137,'black');f:rect(5,48,332,137,'gray',true)
    local title,lines,confirm,cancel,danger
    if self.killReview then
        title='CONFIRM EMERGENCY LIFT KILL';danger=true
        lines={{'All bulk steam vents switch OFF.','white'},{'Trim probes stay on; balloon data stays live.','white'},
            {'Main buoyancy is removed: the vessel will descend.','yellow'},{'Locks Systems until disarmed.','yellow'},
            {'Closes in '..math.max(0,math.ceil(UI.KILL_REVIEW_SECONDS-(now-self.killReview)))..'s without action.','gray'}}
        confirm={type='emergency_kill_lift'};cancel=localAction('close_review')
    elseif stop then
        title='WARNING: STOP SYSTEMS';danger=true
        lines={{'This action will stop all lift calculations.','white'},{'Steam vents will be reset, Amaryllis will descend.','yellow'}}
        confirm={type='systems_stop_confirm',token=stop.token};cancel={type='systems_stop_cancel',token=stop.token}
    elseif maintenance then
        title='CONFIRM LIFT RESTART';lines={{'SCOPE '..tostring(maintenance.scope),'white'}}
        confirm={type=(s.maintenance or {}).locked and not maintenance.override and 'maintenance_override' or 'maintenance_confirm',token=maintenance.token}
        cancel={type='maintenance_cancel',token=maintenance.token}
    elseif tuning then
        title='CONFIRM BOUNDED PID TEST';lines={{'MODE '..tostring(tuning.mode),'white'},{'DIRECTION '..tostring(tuning.direction),'white'}}
        confirm={type='tuning_confirm',token=tuning.token};cancel={type='tuning_cancel'}
    else
        title='RESET LEVELING';lines={{'LEARNED ROLL '..number((s.trimControl or {}).coarseSteamTrimRoll,2,true),'white'},
            {'LEARNED PITCH '..number((s.trimControl or {}).coarseSteamTrimPitch,2,true),'white'}}
        confirm={type='level_reset'};cancel=localAction('close_review')
    end
    f:center(5,58,332,title,danger and 'red' or 'cyan')
    for i,line in ipairs(lines) do f:center(8,78+(i-1)*15,326,line[1],line[2]) end
    self:button(f,15,163,147,18,'CANCEL',cancel,s,true)
    self:button(f,178,163,149,18,self.killReview and 'KILL LIFT' or 'CONFIRM',confirm,s,true,false,danger)
    return true
end
-- Summary: Compose one graphics frame and send changed pixels to the monitor.
-- Every draw replaces hit regions. Unsupported graphics produces a concise error.
function UI:draw(snapshot)
    local s=type(snapshot)=='table' and snapshot or {};self.page=s.page or self.page
    if not ({FLIGHT=true,NAV=true,SHIP=true,SETTINGS=true})[self.page] then self.page='FLIGHT' end
    local now=os.clock();local f=P.new();self:header(f,s)
    if self.page=='NAV' and (s.autopilot or {}).active then self.editor=nil end
    if self.editor then self:keyboard(f,s)
    elseif disassembled(s) and self.page~='SETTINGS' then
        f:flower(147,55);f:center(5,116,332,'VESSEL DISASSEMBLED','white');f:center(5,137,332,'A.E.V. AMARYLLIS','purple',2)
    elseif self.page=='FLIGHT' then self:flight(f,s,now)
    elseif self.page=='NAV' then self:navigation(f,s)
    elseif self.page=='SHIP' then self:ship(f,s,now)
    else self:settings(f,s) end
    self:footer(f)
    if self.systemsMenu then self:menu(f,s) end
    self:review(f,s,now)
    self.propellerAt=now
    local ok,result,why=pcall(f.flush,f,self)
    if not ok then self.previous=nil;return false,'GRAPHICS ERROR: '..tostring(result) end
    return result,why
end
-- Summary: Apply a local key and return only a validated editor commit action.
function UI:editorKey(key)
    local e=self.editor;if not e then return nil end
    if key=='CANCEL' then self.editor=nil;return nil end
    if key=='CLEAR' then e.buffer=''
    elseif key=='DEL' then e.buffer=e.buffer:sub(1,-2)
    elseif key=='SAVE' then
        local value=e.key=='name' and e.buffer or tonumber(e.buffer)
        if e.key~='name' and not finite(value) then self.actionNotice='ENTER A VALID NUMBER';return nil end
        if e.entry and (value<e.entry.min or value>e.entry.max) then self.actionNotice='VALUE OUT OF RANGE';return nil end
        if e.key=='name' and (#value>40 or value:find('[%c]')) then self.actionNotice='INVALID NAME';return nil end
        local action=copy(e.action);action.value=value;self.editor=nil;self.actionNotice=nil
        return action
    elseif e.key=='name' then
        if key=='SPACE' then key=' ' end
        if #key==1 and not key:find('[%c]') and #e.buffer<40 then e.buffer=e.buffer..key end
    elseif #e.buffer<20 and key:match('^[0-9%.%-]$') then e.buffer=e.buffer..key end
    return nil
end
-- Summary: Resolve a local touch selection or a fresh, still-permitted core action.
-- Reads a touch action and current core snapshot, updates local navigation or returns a gated request.
function UI:activate(a,s)
    local kind=a.localAction
    if kind=='page' then
        self.editor=nil;self.systemsMenu=nil;self.reviewKind=nil;self.killReview=nil;self.actionNotice=nil
        return {type='page',page=a.page}
    elseif kind=='systems' then self.systemsMenu=not self.systemsMenu
    elseif kind=='ship' then self.shipView=a.view
    elseif kind=='nav_section' then self.navSection=a.view;self.listOffset=0
    elseif kind=='nav_mode' then self.navMode=a.mode;self.listOffset=0;self.addFromSaved=nil
    elseif kind=='settings' then self.settingsView=a.view;self.settingsOffset=0
    elseif kind=='settings_page' then local offset=(self.settingsOffset or 0)+(self.settingsPageSize or 6);self.settingsOffset=offset>=a.count and 0 or offset
    elseif kind=='highlight' then if a.route then self.selectedWaypoint=a.index else self.selectedDestination=a.index end
    elseif kind=='list_page' then self.listOffset=math.max(0,math.min(math.max(0,(a.count or 64)-3),(self.listOffset or 0)+a.delta))
    elseif kind=='pick' then self.addFromSaved=true;self.listOffset=0
    elseif kind=='end_pick' then self.addFromSaved=nil;self.listOffset=0
    elseif kind=='edit' then self:openEditor(a.key,a.label,a.value,a.commit)
    elseif kind=='edit_selected' then
        local ap=s.autopilot or {};local entry=(a.route and ap.playlist or (ap.library or {}).entries or {})[a.route and self.selectedWaypoint or self.selectedDestination]
        if entry then self:openEditor('name','NAME',entry.name,{type=a.route and 'ap_route_edit' or 'destination_edit',index=a.route and self.selectedWaypoint or self.selectedDestination,key='name'}) end
    elseif kind=='setting_edit' then
        self:openEditor(a.entry.key,a.entry.label,a.entry.value,{type=a.entry.localSetting and 'display_setting' or 'setting_update',key=a.entry.key})
        self.editor.entry=copy(a.entry)
    elseif kind=='key' then return self:editorKey(a.key)
    elseif kind=='kill_review' then if allowed(s,{type='emergency_kill_lift'}) then self.killReview=os.clock();self.systemsMenu=nil end
    elseif kind=='level_review' then self.reviewKind='level';self.systemsMenu=nil
    elseif kind=='close_review' then self.reviewKind=nil;self.killReview=nil
    elseif not kind then
        if not allowed(s,a) then self.actionNotice='ACTION UNAVAILABLE';return nil end
        self.systemsMenu=nil;self.killReview=nil;self.reviewKind=nil
        if a.type=='ap_route_add' then self.addFromSaved=nil;self.listOffset=0 end
        if a.type=='ap_route_move' then self.selectedWaypoint=a.index+a.direction end
        self.actionNotice=nil
        return copy(a)
    end
end
-- Summary: Map zero-based CC Graphics touches through the current drawing geometry.
-- Reject touches after resize until a fresh frame has supplied matching hit regions.
function UI:touch(x,y,s)
    if not finite(x) or not finite(y) or not self.geometry then return nil end
    if self.killReview and os.clock()-self.killReview>UI.KILL_REVIEW_SECONDS then self.killReview=nil;self.regions={};return nil end
    local w,h=self.monitor.getSize(1);local g=self.geometry
    if w~=g.w or h~=g.h then self.regions={};return nil end
    local px,py=(x-g.x)/g.scale,(y-g.y)/g.scale
    for i=#self.regions,1,-1 do
        local r=self.regions[i]
        if px>=r.x and px<r.x+r.w and py>=r.y and py<r.y+r.h then
            if not r.enabled then self.actionNotice='ACTION UNAVAILABLE';return nil end
            local action=self:activate(r.action,s or {})
            if action and not action.localAction and action.type~='page' and action.type~='display_setting' and not allowed(s or {},action) then return nil end
            return action
        end
    end
    if self.systemsMenu then self.systemsMenu=nil end
    return nil
end
-- Summary: Route physical keyboard input to the same editor and modal state.
function UI:input(event,value)
    if event=='key' and keys and value==keys.escape then
        self.editor=nil;self.systemsMenu=nil;self.reviewKind=nil;self.killReview=nil;return nil
    end
    if self.systemsMenu or self.killReview or self.reviewKind or not self.editor then return nil end
    if event=='char' then return self:editorKey(value) end
    if event=='key' and keys then
        if value==keys.backspace then return self:editorKey('DEL') end
        if value==keys.enter or value==keys.numPadEnter then return self:editorKey('SAVE') end
    end
end
-- Summary: Restore the monitor to text mode on service termination or rebind.
function UI:close()
    if self.monitor.setGraphicsMode then pcall(self.monitor.setGraphicsMode,0) end
    self.previous=nil;self.regions={};self.graphicsActive=false
end
UI.Pixel=P
return UI
