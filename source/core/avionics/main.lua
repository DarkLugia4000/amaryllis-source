-- @ama-section: Core runtime | Role setup, prioritized supervision and independent workers.
-- Amaryllis core telemetry runtime; identity comes from /fleet.json.
-- Owns sensors, cockpit reads, lift aggregation and explicitly engaged altitude
-- authority. Retained running intent can resume after validation; coordinated
-- restarts also restore their explicit one-shot checkpoint.
-- The "monitor" entry point renders cached state in a separate terminal tab.
-- Sections: read-only console view, role identity, sampling, status publishing.
local Monitor = { pages = {"VESSEL", "SENSORS", "INPUTS", "LIFT", "SUBSYS", "COMPUTERS", "FAULTS"} }
local function shown(value, decimals)
    if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then return "--" end
    return string.format("%." .. (decimals or 1) .. "f", value)
end
local function clean(value)
    return tostring(value or "--"):gsub("[%c]", " ")
end
local function validComputerID(value)
    return type(value)=="number" and value==value and math.abs(value)<math.huge and
        value%1==0 and value>=0 and value<=65535
end
-- @ama-section: Core runtime | Role setup, prioritized supervision and independent workers.
-- @ama-summary: Format a selected core diagnostic page from the cached snapshot.
function Monitor.rows(page, snapshot, capture)
    snapshot = snapshot or {}
    local vessel, rows = snapshot.vessel or {}, {}
    local conflict=snapshot.identityConflict or {}
    if conflict.active then
        rows[#rows+1]="IDENTITY WARNING: "..clean(conflict.text)
        rows[#rows+1]=clean(conflict.detail)
        for _,alert in ipairs(conflict.alerts or {}) do
            rows[#rows+1]="#"..tostring(alert.id).." "..clean(alert.role)..": "..clean(alert.detail)
            if alert.localIdentity then rows[#rows+1]="  Local: "..clean(alert.localIdentity) end
            for _,claim in ipairs(alert.claims or {}) do
                rows[#rows+1]="  Seen: "..clean(claim.identity).." / seq "..clean(claim.sequence)
            end
        end
    end
    local function row(label, value) rows[#rows+1] = label .. ": " .. clean(value) end
    if page == "VESSEL" then
        local assembly = snapshot.assembly or {}
        row("Assembly", (assembly.state or "UNKNOWN")..(assembly.reason and (" / "..assembly.reason) or ""))
        local identity=snapshot.coreIdentity or {}
        row("Core identity",tostring(identity.id or "--").." / "..clean(identity.label or "UNLABELLED"))
        row("Registry identity",identity.verified and "MATCHED" or (identity.reason or "UNVERIFIED"))
        local position = vessel.position or {}
        row("CoM X / Y / Z", shown(position.x).." / "..shown(position.y).." / "..shown(position.z))
        row("Altitude world Y", shown(vessel.altitude)); row("Altitude source", vessel.altitudeSource)
        row("Heading / pitch / roll", shown(vessel.heading).." / "..shown(vessel.pitch).." / "..shown(vessel.roll))
        row("Forward speed b/s", shown(vessel.forwardSpeed)); row("Vertical speed b/s", shown(vessel.verticalSpeed))
        row("Mass kg", shown(vessel.mass)); row("Sensor sample age s", shown(vessel.sampleAgeSeconds,2))
        local control=snapshot.altitudeControl or {}
        row("Altitude control",control.enabled and "READY" or "DISENGAGED")
        row("Altitude control reason",control.reason or "--")
        local emergency=snapshot.emergencyLift or {}
        row("Emergency lift interlock",emergency.phase or (emergency.latched and "KILL REQUIRED" or "IDLE"))
        if emergency.persistenceWarning then row("Emergency lock warning",emergency.persistenceWarning) end
        local startup=snapshot.systemsStartup or {}
        row("Start systems",startup.phase or "NOT STARTED")
        row("Systems reason",startup.reason or "--")
        if startup.curve then
            local demand=startup.demandProgress or {}
            row("Gas vs lift demand",startup.curve.." / FL "..shown((demand.FL or 0)*100,0).."% FR "..
                shown((demand.FR or 0)*100,0).."% RL "..shown((demand.RL or 0)*100,0).."% RR "..
                shown((demand.RR or 0)*100,0).."%")
        end
        if startup.warning then row("Systems warning",startup.warning) end
        row("Altitude target",shown((snapshot.targets or {}).altitude))
        row("Control limited",tostring(control.saturated==true))
        row("Vessel UUID", vessel.uuid); row("Reading status", vessel.reason or (vessel.valid and "AVAILABLE" or "UNAVAILABLE"))
        row("AP / anchor", clean(snapshot.ap).." / "..clean(snapshot.anchor))
        local tuning=snapshot.tuning or {};local result=tuning.result or {}
        row("PID tuning",tuning.active and (clean(tuning.mode).." / "..clean(tuning.phase)) or "INACTIVE")
        row("Test target / seconds left",shown(tuning.target).." / "..shown(tuning.remaining))
        row("Test peak / RMS error",shown(tuning.peakError or result.peakError,3).." / "..shown(tuning.rmsError or result.rmsError,3))
        row("Last tuning result",result.status or tuning.reason)
    elseif page == "SENSORS" then
        local sensors = vessel.sensors or {}
        local alt, nav, gimbal = sensors.altitude or {}, sensors.navigation or {}, sensors.gimbal or {}
        local gravity, rates, body = gimbal.gravity or {}, gimbal.angularRates or {}, sensors.bodyVelocity or {}
        row("CoM altitude", shown(vessel.altitude)); row("Source", vessel.altitudeSource)
        row("Backup sensor Y", shown(alt.worldY)); row("Backup sensor V/S", shown(alt.verticalSpeed))
        row("Bow heading", shown(vessel.heading)); row("Heading source", vessel.headingSource)
        row("Nav raw +Z heading", shown(nav.rawHeading))
        row("Body velocity X/Y/Z", shown(body.x).." / "..shown(body.y).." / "..shown(body.z))
        row("Gravity X/Y/Z", shown(gravity.x).." / "..shown(gravity.y).." / "..shown(gravity.z))
        row("Angular rates X/Y/Z", shown(rates.x).." / "..shown(rates.y).." / "..shown(rates.z))
        for _, issue in ipairs(vessel.telemetryErrors or {}) do row("Sensor fault", issue) end
    elseif page == "INPUTS" then
        local inputs = snapshot.inputs or {}
        row("Cockpit samples", inputs.valid and "VALID" or "UNAVAILABLE / STALE")
        local names = {{"A left press","left_press"},{"Y left lift","left_lift"},
            {"D right press","right_press"},{"C right lift","right_lift"},
            {"W forward","prop_forward"},{"S reverse","prop_reverse"},
            {"LMB AP disconnect","ap_disconnect"},{"R altitude up","altitude_up"},{"F altitude down","altitude_down"}}
        for _, item in ipairs(names) do row(item[1], inputs.valid and shown((inputs.raw or {})[item[2]],0) or "--") end
        local cockpit=snapshot.cockpitControl or {}
        local modes=snapshot.modes or {}
        row("Heading / throttle mode",clean(modes.heading).." / "..clean(modes.throttle))
        row("Yaw / propulsion request %",shown(cockpit.yawRequestPercent).." / "..shown(cockpit.propulsionRequestPercent))
        row("Neutral required H/T/Y",tostring(cockpit.headingWaitingForNeutral).." / "..
            tostring(cockpit.throttleWaitingForNeutral).." / "..tostring(cockpit.altitudeWaitingForNeutral))
        row("Cockpit reason",cockpit.reason or "READY")
        row("Propulsion reason",cockpit.propulsionReason)
        for key, issue in pairs(inputs.errors or {}) do row(key, issue) end
    elseif page == "LIFT" then
        for _, quadrant in ipairs({"FL","FR","RL","RR"}) do
            local node = (snapshot.nodes or {})[quadrant] or {}
            row(quadrant .. " #" .. clean(node.id), node.online and "ONLINE" or "OFFLINE")
            row("  Ready / armed", tostring(node.ready==true).." / "..tostring(node.armed==true))
            row("  Gas m3/tick", node.totalGasOutputValid and shown(node.totalGasOutput,2) or "--")
            local balloon=node.balloon or {}
            row("  Filled / target", shown(balloon.filledVolume,1).." / "..shown(balloon.targetVolume,1))
            if balloon.gasMixValid then
                for _,gas in ipairs({"steam","default"}) do
                    row("  Gas "..gas,shown((balloon.gasMix or {})[gas],1).." / "..
                        shown(100*((balloon.gasFractions or {})[gas] or 0),1).."%")
                end
            else row("  Composition","UNAVAILABLE") end
            row("  Status age s", shown(node.statusAgeSeconds,2))
            for _, issue in ipairs(node.faults or {}) do row("  Fault", issue) end
        end
    elseif page == "SUBSYS" then
        rows[#rows+1] = "SUBSYSTEMS / ONBOARD COMPUTERS"
        for _, system in ipairs(snapshot.subsystems or {}) do
            row("#"..clean(system.id).." "..clean(system.label), system.status or "UNKNOWN")
            row("  Role",system.role)
            if system.localNode then row("  Source","LOCAL CORE")
            else row("  Report age s",shown(system.ageSeconds,2)) end
            if system.detail then row("  Detail",system.detail) end
        end
        if not snapshot.subsystems then rows[#rows+1] = "Waiting for core subsystem inventory" end
    elseif page == "COMPUTERS" then
        local registry=snapshot.fleetRegistry or {}
        local computers=registry.computers or {}
        local identity=snapshot.coreIdentity or {}
        row("Fleet schema",registry.schemaVersion or "--")
        row("Core ID / registry identity",tostring(identity.id or "--").." / "..
            (identity.verified and "MATCHED" or "MISMATCH"))
        if registry.error then row("Registry issue",registry.error) end
        for _,role in ipairs({"core","navigator","heading-left","heading-right","heading-main",
            "chamber_fl","chamber_fr","chamber_bl","chamber_br","primary_l","primary_r"}) do
            local entry=computers[role] or {}
            local health=(snapshot.roleHealth or {})[role] or {}
            local id=entry.id==nil and "UNASSIGNED" or tostring(entry.id)
            row(role,id.." / "..clean(entry.label or "NO LABEL"))
            if role~="core" then
                local readiness=health.online and (health.running and
                    (health.hardwareAvailable and "READY" or "RUNNING / HARDWARE UNAVAILABLE") or "STOPPED") or
                    "NO FRESH ROLE REPORT"
                if health.error then readiness="PACKAGE MANIFEST ERROR" end
                if health.online and health.running and health.hardwareAvailable and
                    (not health.faultSummary or health.faultSummary=="") then readiness="READY"
                elseif health.online and health.running then readiness="DEGRADED" end
                row("  Runtime",readiness)
                if health.faultSummary and health.faultSummary~="" then row("  Fault",health.faultSummary) end
            end
        end
        row("Edit IDs","Press E, enter a role key, then an ID. Leave ID blank to unassign.")
    else
        for _, issue in ipairs(snapshot.faults or {}) do row("Fault", issue) end
        for _, issue in ipairs(vessel.telemetryErrors or {}) do row("Sensor", issue) end
        if #rows==0 then row("Faults", "No reported faults") end
        rows[#rows+1] = "--- Recent core console ---"
        local console = capture and capture.console or {}
        for i=math.max(1,#console-19),#console do rows[#rows+1]=clean(console[i].text) end
    end
    return rows
end
function Monitor.fresh(runtime, now)
    return type(runtime)=="table" and runtime.running~=false and type(runtime.publishedAt)=="number" and
        now>=runtime.publishedAt and now-runtime.publishedAt<=2
end
local REQUIRED_PEER_ROLES={"navigator","heading-left","heading-right","heading-main",
    "chamber_fl","chamber_fr","chamber_bl","chamber_br","primary_l","primary_r"}
-- @ama-summary: Determine whether required computer assignments need operator setup.
function Monitor.needsComputerSetup(runtime)
    if type(runtime)~="table" then return nil end
    if runtime.registryError then return true end
    if type(runtime.computers)~="table" then return nil end
    for _,role in ipairs(REQUIRED_PEER_ROLES) do
        local entry=runtime.computers[role]
        if type(entry)~="table" or entry.id==nil then return true end
    end
    return false
end
-- @ama-summary: Refresh the selected core diagnostic view and handle its local navigation.
function Monitor.run()
    -- Ownership prevents repeated manual launches from leaving duplicate viewers.
    local owner = {}; os.__amaryllisCoreMonitorOwner=owner
    if multishell and multishell.setTitle and multishell.getCurrent then
        multishell.setTitle(multishell.getCurrent(),"core monitor")
    end
    local display=term
    if type(term.current)=="function" then
        local ok,current=pcall(term.current)
        if ok and current then display=current end
    end
    local function optional(method,...)
        if type(display[method])~="function" then return nil end
        local ok,value=pcall(display[method],...)
        if ok then return value end
    end
    local oldX,oldY
    if type(display.getCursorPos)=="function" then
        local ok,x,y=pcall(display.getCursorPos)
        if ok then oldX,oldY=x,y end
    end
    local oldTextColor,oldBackgroundColor=optional("getTextColor"),optional("getBackgroundColor")
    local oldCursorBlink=optional("getCursorBlink")
    local function restoreColors(textColor,backgroundColor)
        if textColor~=nil and type(display.setTextColor)=="function" then display.setTextColor(textColor) end
        if backgroundColor~=nil and type(display.setBackgroundColor)=="function" then display.setBackgroundColor(backgroundColor) end
    end
    local function restoreCursor(x,y,blink)
        if x and y and type(display.setCursorPos)=="function" then display.setCursorPos(x,y) end
        if blink~=nil and type(display.setCursorBlink)=="function" then display.setCursorBlink(blink) end
    end
    local page, offset, timer = 1, 0, nil
    local initialSetup=Monitor.needsComputerSetup(os.__amaryllisRuntime)
    local setupState=initialSetup
    local pendingSetupCheck=initialSetup==nil
    local cachedRows,cachedWidth,cachedHeight=nil,nil,nil
    local hex="0123456789abcdef"
    -- @ama-summary: Map a display colour value to its terminal blit digit.
    local function colorCode(color)
        if colors and type(colors.toBlit)=="function" then
            local ok,value=pcall(colors.toBlit,color)
            if ok and type(value)=="string" and #value==1 then return value end
        end
        local value,index=color,0
        while type(value)=="number" and value>1 and value%2==0 do
            value=value/2;index=index+1
        end
        return hex:sub(index+1,index+1)
    end
    if initialSetup then page=6 end
    -- @ama-summary: Render the current view into its configured terminal or monitor.
    local function draw(force)
        local width,height = display.getSize()
        local runtime = os.__amaryllisRuntime
        local fresh = Monitor.fresh(runtime,os.clock())
        local snapshot = runtime and runtime.snapshot or {}
        local rows = Monitor.rows(Monitor.pages[page],snapshot,os.__amaryllisDiagnostics)
        local available = math.max(0,height-5)
        offset=math.min(offset,math.max(0,#rows-available))
        if cachedWidth~=width or cachedHeight~=height then force=true end
        local frame={}
        local blankFG,blankBG=colorCode(colors.white),colorCode(colors.black)
        for y=1,height do
            local row={chars={},fg={},bg={},fgCode={},bgCode={}}
            for x=1,width do
                row.chars[x]=" ";row.fg[x]=colors.white;row.bg[x]=colors.black
                row.fgCode[x]=blankFG;row.bgCode[x]=blankBG
            end
            frame[y]=row
        end
        -- @ama-summary: Write bounded text cells with the selected foreground colour.
        local function put(y,x,text,fg,bg)
            if y<1 or y>height or x>width then return end
            fg,bg=fg or colors.white,bg or colors.black
            local clipped=clean(text):sub(1,math.max(0,width-x+1))
            local row=frame[y]
            for i=1,#clipped do
                local col=x+i-1
                row.chars[col]=clipped:sub(i,i);row.fg[col]=fg;row.bg[col]=bg
                row.fgCode[col]=colorCode(fg);row.bgCode[col]=colorCode(bg)
            end
        end
        put(1,1,"A.E.V. AMARYLLIS / CORE #"..tostring(runtime and runtime.coreID or os.getComputerID()),colors.cyan)
        local age = runtime and type(runtime.publishedAt)=="number" and os.clock()-runtime.publishedAt or nil
        put(2,1,(fresh and "LIVE" or "STALE / CORE STOPPED").."  age "..
            shown(age,2).."s",fresh and colors.green or colors.red)
        local menuCount = #Monitor.pages
        for i,name in ipairs(Monitor.pages) do
            local left,right = math.floor((i-1)*width/menuCount)+1,math.floor(i*width/menuCount)
            local selected=i==page
            if right>=left then
                put(3,left,(name..string.rep(" ",right-left+1)):sub(1,right-left+1),
                    selected and colors.black or colors.white,selected and colors.cyan or colors.gray)
            end
        end
        for i=1,available do if rows[offset+i] then put(4+i,1,rows[offset+i],fresh and colors.white or colors.gray) end end
        put(height,1,"1-7 menu | arrows/scroll | E edit computer IDs",colors.gray)

        local nextCache={}
        for y=1,height do
            local row=frame[y]
            local text,fg,bg=table.concat(row.chars),table.concat(row.fgCode),table.concat(row.bgCode)
            local signature=text.."\0"..fg.."\0"..bg
            if force or not cachedRows or cachedRows[y]~=signature then
                display.setCursorPos(1,y)
                if type(display.blit)=="function" then
                    display.blit(text,fg,bg)
                else
                    local x=1
                    while x<=width do
                        local first=x;local textColor,backgroundColor=row.fg[x],row.bg[x]
                        x=x+1
                        while x<=width and row.fg[x]==textColor and row.bg[x]==backgroundColor do x=x+1 end
                        display.setCursorPos(first,y)
                        display.setBackgroundColor(backgroundColor);display.setTextColor(textColor)
                        display.write(table.concat(row.chars,"",first,x-1))
                    end
                end
            end
            nextCache[y]=signature
        end
        cachedRows,cachedWidth,cachedHeight=nextCache,width,height
        restoreColors(colors.white,colors.black)
        restoreCursor(oldX,oldY,false)
    end
    -- @ama-summary: Refresh the computer-assignment setup view from the current registry.
    local function updateSetup()
        local current=Monitor.needsComputerSetup(os.__amaryllisRuntime)
        if current==nil then return false end
        if pendingSetupCheck then
            pendingSetupCheck=false;setupState=current
            if current then page=6;offset=0 end
            return true
        end
        if current~=setupState then
            setupState=current
            if current then page=6;offset=0 end
            return true
        end
        return false
    end
    -- @ama-summary: Open the fleet-assignment editor using the current stored registry.
    local function editRegistry()
        local runtime=os.__amaryllisRuntime
        local _,height=display.getSize()
        local promptRow=math.max(1,height-1)
        -- @ama-summary: Read the displayed operator prompt and return the entered value.
        local function prompt(message)
            display.setCursorPos(1,promptRow);display.clearLine();display.setTextColor(colors.yellow)
            display.write(message)
            if type(display.setCursorBlink)=="function" then display.setCursorBlink(true) end
            local readOK,value=pcall(read)
            if type(display.setCursorBlink)=="function" then display.setCursorBlink(false) end
            return readOK,value
        end
        local roleOK,role=prompt("Role key: ")
        if roleOK and role then
            local idOK,raw=prompt("New ID (blank to unassign): ")
            if idOK and raw then
                local id
                if raw=="" then id=nil else id=tonumber(raw) end
                local validID=raw=="" or validComputerID(id)
                if not validID then
                    display.setCursorPos(1,promptRow);display.clearLine();display.setTextColor(colors.red)
                    display.write("Fleet edit failed: enter an integer from 0 to 65535")
                elseif runtime and type(runtime.editComputerID)=="function" then
                    local edited,issue=runtime.editComputerID(role,id)
                    if not edited then
                        display.setCursorPos(1,promptRow);display.clearLine();display.setTextColor(colors.red)
                        display.write("Fleet edit failed: "..tostring(issue))
                    end
                end
            end
        end
        -- read() may consume the monitor timer while waiting for input. Start
        -- a fresh one and discard the prompt's visible text from the row cache.
        timer=os.startTimer(0.25)
        cachedRows=nil
        restoreColors(colors.white,colors.black)
        if type(display.setCursorBlink)=="function" then display.setCursorBlink(false) end
    end
    local ok, reason = pcall(function()
        if type(display.setCursorBlink)=="function" then display.setCursorBlink(false) end
        draw(true); timer=os.startTimer(0.25)
        while os.__amaryllisCoreMonitorOwner==owner do
            local event,a,b,c = os.pullEventRaw()
            local redraw=false
            local force=false
            -- This persistent status tab deliberately consumes Ctrl+T and Q.
            -- Exiting it must not be an operator action; power-off still stops it.
            local menuCount = #Monitor.pages
            local selectedPage
            if event=="char" and type(a)=="string" then selectedPage=tonumber(a) end
            if selectedPage and selectedPage>=1 and selectedPage<=menuCount then
                if page~=selectedPage or offset~=0 then page=selectedPage;offset=0;redraw=true;force=true end
            elseif event=="char" and type(a)=="string" and string.lower(a)=="e" and Monitor.pages[page]=="COMPUTERS" then
                editRegistry();redraw=true;force=true
            elseif event=="key" then
                local oldPage,oldOffset=page,offset
                if a==keys.left then page=(page-2)%menuCount+1; offset=0
                elseif a==keys.right then page=page%menuCount+1; offset=0
                elseif a==keys.up then offset=math.max(0,offset-1)
                elseif a==keys.down then offset=offset+1
                elseif a==keys.pageUp then offset=math.max(0,offset-5)
                elseif a==keys.pageDown then offset=offset+5 end
                if page~=oldPage or offset~=oldOffset then redraw=true;force=true end
            elseif event=="mouse_scroll" then
                local oldOffset=offset;offset=math.max(0,offset+a)
                if offset~=oldOffset then redraw=true;force=true end
            elseif event=="mouse_click" and a==1 and c==3 then
                local width=display.getSize()
                for i=1,menuCount do
                    if b>=math.floor((i-1)*width/menuCount)+1 and b<=math.floor(i*width/menuCount) then
                        if page~=i or offset~=0 then page=i;offset=0;redraw=true;force=true end
                        break
                    end
                end
            end
            if event=="timer" and a==timer then timer=os.startTimer(0.25);redraw=true end
            if event=="term_resize" then redraw=true;force=true end
            if updateSetup() then redraw=true;force=true end
            if redraw then draw(force) end
            -- Ctrl+T belongs to this view. The core runtime is supervised in
            -- another tab, and the monitor itself stays available for status
            -- and registry edits until the computer is restarted.
        end
    end)
    if os.__amaryllisCoreMonitorOwner==owner then os.__amaryllisCoreMonitorOwner=nil end
    restoreColors(oldTextColor,oldBackgroundColor)
    restoreCursor(oldX,oldY,oldCursorBlink)
    if not ok then error("Core monitor: "..tostring(reason),0) end
end
-- Fake-hardware tests exercise the viewer without starting the flight runtime.
if rawget(_G,"__AMARYLLIS_MONITOR_TEST") then return Monitor end
local arguments={...}
if arguments[1]=="monitor" then Monitor.run(); return end
if arguments[1]=="propulsion-worker" then
    local context=os.__amaryllisPropulsionContext
    if type(context)~="table" or context.owner~=arguments[2] then error("Propulsion worker has no current owner",0) end
    context.run();return
end
if arguments[1]=="debug-worker" then
    local context=os.__amaryllisDebugContext
    if type(context)~="table" or context.owner~=arguments[2] then error("Debug worker has no current owner",0) end
    context.run();return
end
if arguments[1]=="failover-sampler" then
    local context=os.__amaryllisFailoverContext
    local name,owner=arguments[2],arguments[3]
    if type(context)~="table" or context.owner~=owner or type(context.jobs[name])~="function" then
        error("Failover reader has no current core owner",0)
    end
    context.jobs[name]();return
end
if arguments[1]=="sampler" then
    local context=os.__amaryllisSamplingContext
    local name,owner=arguments[2],arguments[3]
    if type(context)~="table" or context.owner~=owner or type(context.jobs[name])~="function" then
        error("Sampling worker has no current core owner",0)
    end
    context.jobs[name]();return
end
package.path = "/?.lua;/?/init.lua;" .. (package.path or "")
local Storage = require("avionics.storage")
local IO = require("avionics.io")
local Flight = require("avionics.flight")
local Restart = require("avionics.restart")
local Fleet = require("avionics.fleet")
local config, reason = Storage.loadConfig("/avionics/config.json")
if not config then error(reason, 0) end
local localID=os.getComputerID()
local localLabel=os.getComputerLabel()
local fleet=Fleet.new({coreID=localID,coreLabel=localLabel})
local io = IO.new(config,{fleet=fleet})
local stateEntry=io.computers and io.computers.state
if stateEntry and type(stateEntry.id)=="number" then
    io.stateLink=require("avionics.state_wire").newCore(io,stateEntry)
end
local flight = Flight.new(config)
local remoteAP=require("avionics.remote_ap").new(io,flight)
io.remoteAP=remoteAP
os.__amaryllisRemoteAP={
    request=function(sender,pair,packet) return remoteAP:request(sender,pair,packet) end,
    status=function(pair) return remoteAP:status(pair) end,
    enable=function(value) return remoteAP:setEnabled(value) end}
flight.storage=Storage
flight:configureEmergencyLock(Storage,{fs=fs,textutils=textutils})
flight:configureLevelMemory(Storage,{fs=fs,textutils=textutils})
flight:configureHoverMemory(Storage,{fs=fs,textutils=textutils})
flight.restart=Restart.new(Storage,{fs=fs,textutils=textutils})
flight.restart:load()
local ControlPresets=require("avionics.control_presets")
local controlPresets=ControlPresets.new(config,Storage,{fs=fs,textutils=textutils})
io.controlPresets=controlPresets
if flight.restart.saved then controlPresets:cancelRestore() end
if shell and type(shell.openTab)=="function" and not os.__amaryllisCoreMonitorOwner and not os.__amaryllisPagedConsole then
    local opened, tab=pcall(shell.openTab,"/avionics/main.lua","monitor")
    if not opened then print("Could not open Core Monitor: "..tostring(tab)) end
end
local function refresh()
    io:scanHardware()
    local ok, issue = io:openModems()
    if not ok then print("Core network: " .. tostring(issue)) end
end
-- @ama-summary: Validate an entered computer ID and save the selected role assignment.
local function editComputerID(role,id)
    local ok,issue=fleet:editID(role,id)
    if not ok then io:logState("registry edit",issue);return false,issue end
    local updated,updateIssue=io:setRegistry(fleet.computers)
    if not updated then io:logState("registry edit",updateIssue);return false,updateIssue end
    io:logState("registry edit",nil)
    return true
end
-- @ama-summary: Build core sensor and modem availability from the latest hardware inventory.
local function coreHardwareHealth(snapshot)
    local available=false
    local faults,seen={},{}
    local function add(value)
        if type(value)~="string" or value=="" or seen[value] then return end
        seen[value]=true
        if #faults<6 then faults[#faults+1]=clean(value):sub(1,96) end
    end
    if snapshot then
        local vessel=snapshot.vessel or {}
        local inputs=snapshot.inputs or {}
        available=vessel.valid==true or inputs.valid==true
        if not vessel.valid then add(vessel.reason or "SABLE SENSOR DATA UNAVAILABLE") end
        if not inputs.valid then add(inputs.reason or "COCKPIT INPUT DATA UNAVAILABLE") end
        for _,issue in ipairs(snapshot.faults or {}) do add(issue) end
        local startup=snapshot.systemsStartup or {}
        if startup.warning then add(startup.warning) end
        local emergency=snapshot.emergencyLift or {}
        if emergency.persistenceWarning then add(emergency.persistenceWarning) end
    else
        add("Core sensors have not been sampled")
    end
    for _,issue in ipairs(io.inventory and io.inventory.errors or {}) do add(issue) end
    return available,table.concat(faults,"; "):sub(1,160)
end
local timingOK,Timing=pcall(require,"avionics.cockpit_timing")
local cockpitTiming
if timingOK and type(Timing)=="table" and type(Timing.new)=="function" then
    local ok,value=pcall(Timing.new,"core",io.session,function() return io:nowSeconds() end)
    if ok and type(value)=="table" then cockpitTiming=value end
end
io.cockpitTrace=cockpitTiming
os.__amaryllisCockpitTiming=cockpitTiming
-- @ama-summary: Publish the latest cached runtime snapshot and worker status.
local function publishRuntime(snapshot,running)
    local computers=Fleet.clone(io.computers or {})
    local hardwareAvailable,faultSummary=coreHardwareHealth(snapshot)
    local runtime={publishedAt=os.clock(),snapshot=snapshot,running=running~=false,sampling=io.sampling,
        coreID=io.localID,session=io.session,computers=computers,
        identityValid=io.identityReady==true,registryError=fleet.error,
        hardwareAvailable=hardwareAvailable,faultSummary=faultSummary,
        editComputerID=editComputerID,
        stateProbe=io.stateLink and function() return io.stateLink:probe(io,io:nowSeconds()) end or nil}
    os.__amaryllisFleetRegistry={coreID=runtime.coreID,session=runtime.session,
        computers=Fleet.clone(computers)}
    local core=computers.core or {}
    os.__amaryllisIdentity={role="core",computerID=io.localID,label=io.localLabel,
        coreID=io.localID,registryLabel=core.label,verified=io.identityReady==true}
    os.__amaryllisRuntime=runtime
end
publishRuntime(nil,true)
local Sampling=require("avionics.sampling")
local DebugRecorder=require("avionics.debug_recorder")
local debugRecorder=DebugRecorder.new()
local metrics=require("avionics.runtime_metrics").new(nil,cockpitTiming)
local progressWatchdog=require("avionics.progress_watchdog").new()
local physicsMonitor=require("avionics.physics_monitor").new()
local motionWarnings=require("avionics.motion_warnings").new({config=config.motion_warnings})
io.motionWarnings=motionWarnings
io.runtimeMetrics=metrics
io.debugRecorder=debugRecorder
io.sampling={vessel={},cockpit={},assembly={},fallback={},assembler={}}
io.independentVesselSources=true
io.independentAssemblerSources=true
local samplingContext
-- Per-job activity guards. Failover readers (started when the state computer
-- stops delivering) carry their own context so they can be stopped alone.
local samplerGuards={}
-- @ama-summary: Run the named sensor sampling loop with completion and retry tracking.
local function sampler(name,operation,timeout,interval,validate)
    Sampling.run(name,operation,{state=io.sampling[name],timeout=timeout,interval=interval,
        validate=validate,recover=function()
            -- Slow responses do not invalidate known hardware. Avoid a full
            -- peripheral scan competing with the reads on every retry cycle.
            if (name=="cockpit" and not io.bridge) or not io.sensorBindings or io.sensorBindingError then io:scanHardware() end
        end,
        isActive=function()
            local guard=samplerGuards[name]
            if guard then return guard() end
            return not samplingContext or os.__amaryllisSamplingContext==samplingContext
        end})
end
-- @ama-summary: Perform the selected sensor read and publish its completed observation.
local function sample()
    -- Vessel reads have taken up to ~4 s under load; allow 10 s (inside the
    -- 12 s telemetry grace) before discarding an in-progress sample.
    sampler("vessel",function() return io:sampleVessel(io:nowSeconds()) end,10,
        config.network.sample_interval_seconds,function(value)
            if value and value.valid==false then return value.reason or "VESSEL SAMPLE INVALID" end
        end)
end
local function fallbackSample()
    sampler("fallback",function() return io:sampleFallback(io:nowSeconds()) end,4,
        config.network.sample_interval_seconds)
end
local function assemblerDataSample()
    -- Allow main-thread replies to complete independently of the fast backup
    -- batch. Values commit individually and retain their actual receipt times.
    sampler("assembler",function() return require("avionics.vessel_sources").sampleAssembler(io) end,6,2)
end
local function stateSample() return io.stateLink:run(io) end
local lastCockpitInput,lastCockpitService
-- @ama-summary: Consume the newest cockpit sample and update flight/propulsion demand.
local function serviceCockpit(now)
    if not flight.controls or flight.restart.saved then return end
    now=now or io:nowSeconds()
    if io.stateReaderReset then flight.controls:clear();io.stateReaderReset=nil;lastCockpitInput=nil;lastCockpitService=nil end
    if io.inputs==lastCockpitInput and lastCockpitService and now>=lastCockpitService and now-lastCockpitService<.1 then return end
    local tracedInput,previousSample=io.inputs,flight.controls.lastSample
    local ok,issue=pcall(flight.controls.update,flight.controls,io,now)
    local finished=io:nowSeconds()
    if io.cockpitTrace then pcall(io.cockpitTrace.service,io.cockpitTrace,tracedInput,now,finished,flight.controls.lastSample) end
    if ok then
        lastCockpitInput,lastCockpitService=io.inputs,io:nowSeconds();io.cockpitPriorityError=nil
        if flight.controls.lastSample~=previousSample and flight.controls.lastSample~=nil and
            io.cockpitProcessedSampleAt~=flight.controls.lastSample then
            io.cockpitProcessedAt=lastCockpitService
            io.cockpitProcessedSampleAt=flight.controls.lastSample
        end
    else io.cockpitPriorityError=tostring(issue):sub(1,160) end
end
io.onCockpitInput=serviceCockpit
-- @ama-summary: Read and publish the current cockpit input batch.
local function cockpitSample()
    sampler("cockpit",function()
        local now=io:nowSeconds()
        local value=io:readInputs(now)
        serviceCockpit(io:nowSeconds())
        return value
    -- 5 s: link reads queue behind the core's other peripheral calls.
    end,5,config.cockpit and config.cockpit.input_interval_seconds or config.network.sample_interval_seconds,
        function(value) if value and value.valid==false then return value.reason or "COCKPIT SAMPLE INVALID" end end)
end
local lastPresetLog
-- @ama-summary: Initialize the role's runtime context and start its supervised workers.
local function runtime()
    refresh()
    print("A.E.V. AMARYLLIS core active. "..(flight.restart.saved and
        "Saved airborne restart awaits fresh telemetry." or "Altitude control starts disengaged."))
    local nextHello, nextPublish, nextHousekeeping, nextScan = 0, 0, 0, 0
    local scanPending=false
    -- A peripheral call waits for its own task event, and CC discards every
    -- other event that reaches that coroutine meanwhile. A separate receiver
    -- queues rednet messages so chamber ACKs arriving while the supervisor
    -- waits on a peripheral are processed afterwards instead of being lost.
    local RadioInbox=require("avionics.radio_inbox")
    local inbox=RadioInbox.new(config.protocol,128,function(sender,message)
        return RadioInbox.corePriority(io,flight.systemsRun,sender,message)
    end)
    -- @ama-summary: Receive network traffic and enqueue validated work for the runtime supervisor.
    local function receiver()
        while true do
            local _,from,payload,channel=os.pullEventRaw("rednet_message")
            -- No wake-up event is queued per message: the supervisor's 0.1 s
            -- timer drains the inbox, and extra events risk filling CC's
            -- bounded event queue, where a dropped timer can stall a worker.
            -- Identity conflict receiver v1: observe before routine coalescing; never yield.
            local receivedAt,receivedEpoch=io:nowSeconds(),os.epoch("utc")
            pcall(io.observeIdentityClaim,io,from,payload,channel,receivedAt,receivedEpoch)
            inbox:push(from,payload,channel,receivedAt,receivedEpoch)
        end
    end
    -- @ama-summary: Dispatch a received packet to the matching protocol/session handler.
    local function handleMessage(sender,message,protocol,now,radioTiming)
            if radioTiming then radioTiming.handlerEpochMs=os.epoch("utc") end
            metrics:measure("receive",io.processMessage,io,sender, message, protocol, now,radioTiming)
            flight.restart:ack(sender,message,protocol,io)
            if protocol==config.protocol then flight:maintenanceAck(io,sender,message,now) end
            if io.identityReady==true and sender == config.bridge_id and protocol == config.protocol and
                type(message) == "table" and message.v == 1 and message.kind == "bridge_request" and
                message.session == io.session and IO.isInteger(message.seq, 1, config.network.max_sequence) then
                local accepted,reason=flight:bridgeRequest(io,message,io:nowSeconds())
                rednet.send(sender, {v=1,kind="bridge_ack",session=io.session,seq=message.seq,
                    boot=message.boot,
                    accepted=accepted,reason=reason}, config.protocol)
            end
    end
    -- @ama-summary: Service prioritized requests and advance the current runtime operations.
    local function supervisor()
    local timer = os.startTimer(0.1)
    -- Event-queue lag probe: a queued event is stamped with the real clock
    -- and timed when it comes out. Everything the core receives waits in the
    -- same queue, so this is how old its incoming data is on arrival.
    local nextProbe,probeWindowAt=0,0
    while true do
        local event, sender, message, protocol = os.pullEventRaw()
        local now = io:nowSeconds()
        if event=="amaryllis_lag_probe" and type(sender)=="number" then
            local lag=math.max(0,(os.epoch("utc")-sender)/1000)
            io.eventLagSeconds=lag
            if now>=probeWindowAt then probeWindowAt=now+10;io.eventLagMaxSeconds=lag
            else io.eventLagMaxSeconds=math.max(io.eventLagMaxSeconds or 0,lag) end
        end
        if now>=nextProbe then nextProbe=now+1;os.queueEvent("amaryllis_lag_probe",os.epoch("utc")) end
        if event == "terminate" then
            -- Closing a terminal view cannot stop the independent core runtime.
            -- A computer restart remains the explicit way to stop supervision.
        elseif event == "peripheral" or event == "peripheral_detach" then
            if sender==io.bridgeName or sender==(io.inventory and io.inventory.linkBridge) then
                io:invalidateBridge("COCKPIT LINK BRIDGE "..string.upper(event))
            end
            -- Bursts of network/peripheral events request one bounded scan.
            scanPending=true
        end
        local passStarted=io:nowSeconds()
        if cockpitTiming then pcall(cockpitTiming.beginWork,cockpitTiming,"supervisor_pass",passStarted) end
        -- Consume the newest pilot batch before routine radio work, discovery,
        -- recovery, UI publication or remote operations can occupy this pass.
        serviceCockpit(io:nowSeconds())
        local received=false
        -- Bound one drain so incoming bursts cannot indefinitely postpone
        -- sensor supervision and control freshness checks.
        for _=1,32 do
            local item=inbox:pop()
            if not item then break end
            received=true
            serviceCockpit(io:nowSeconds())
            handleMessage(item[1],item[2],item[3],item[4],item[5])
        end
        -- Event processing can call yielding peripherals. Refresh the clock
        -- before any worker evaluates freshness or control gates.
        now=io:nowSeconds()
        if scanPending and now>=nextScan then
            scanPending=false;nextScan=now+2
            metrics:measure("discovery",refresh)
            now=io:nowSeconds()
        end
        if now>=nextHousekeeping then
            nextHousekeeping=now+.1
            serviceCockpit(now)
            metrics:measure("restart_restore",flight.restart.restore,flight.restart,flight,io,now)
            metrics:measure("source_refresh",io.refreshVesselSources,io,now)
            -- The cockpit reader also updates controls; doing it here keeps the
            -- control state current even if that reader stalls. Each lever
            -- sample is still consumed only once.
            serviceCockpit(io:nowSeconds())
            local remoteOK,remoteIssue=pcall(metrics.measure,metrics,"remote_ap",remoteAP.step,remoteAP,io:nowSeconds())
            if not remoteOK then
                remoteAP.enabled=false
                if type(os.__amaryllisLog)=="function" then pcall(os.__amaryllisLog,"Remote AP worker: "..tostring(remoteIssue),"core.remote-ap") end
            end
            io.stateTargetAltitude=flight.controls and flight.controls.targets and flight.controls.targets.altitude or flight.target
            local presetOK,presetIssue=pcall(metrics.measure,metrics,"presets",controlPresets.update,controlPresets,io,flight,now)
            if not presetOK then controlPresets.saveError="CONTROL PRESETS ERROR: "..tostring(presetIssue) end
            -- Only completed supervisor work refreshes propulsion authority.
            io.propulsionHeartbeat=io:nowSeconds()
            if type(io.propulsionWatchdog)=="function" then pcall(io.propulsionWatchdog,io:nowSeconds()) end
            if type(io.debugWatchdog)=="function" then pcall(io.debugWatchdog,io:nowSeconds()) end
            pcall(progressWatchdog.update,progressWatchdog,io,flight,io:nowSeconds())
            pcall(physicsMonitor.update,physicsMonitor,io,flight,io:nowSeconds())
            if type(io.stateFailoverCheck)=="function" then
                local ok,issue=pcall(io.stateFailoverCheck,io:nowSeconds())
                if not ok and type(os.__amaryllisLog)=="function" then
                    pcall(os.__amaryllisLog,"State failover check error: "..tostring(issue),"core.failover")
                end
            end
        end
        now=io:nowSeconds()
        if now >= nextHello then
            metrics:measure("hello_send",io.sendHello,io)
            now=io:nowSeconds()
            nextHello = now + config.network.hello_interval_seconds
        end
        if now >= nextPublish then
            if flight.restart.saved then
                flight.systemsSnapshot={active=true,available=false,phase="RESTARTING",pending=true,
                    target=flight.restart.saved.controls.targets.altitude,reason=flight.restart.reason}
            else metrics:measure("lift_control",flight.update,flight,io,now) end
            now=io:nowSeconds()
            local snapshot = metrics:measure("snapshot",function() return flight:decorate(io:buildSnapshot(now),io,now) end)
            snapshot.radio=inbox:snapshot()
            if io.stateLink then
                snapshot.stateReader=io.stateLink:probe(io,io:nowSeconds())
                local failover=io.stateFailover
                if failover then
                    snapshot.stateReader.failoverActive=failover.active==true
                    snapshot.stateReader.failoverReason=failover.reason
                    snapshot.stateReader.failoverSince=failover.since
                end
            end
            if io.thrust then metrics:measure("thrust_snapshot",io.thrust.decorate,io.thrust,snapshot,now,io,flight.controls) end
            local motionOK,motionState=pcall(motionWarnings.update,motionWarnings,snapshot,io,now)
            if not motionOK then
                local errorText=tostring(motionState):gsub("[%c]"," "):sub(1,160)
                if motionWarnings.runtimeError~=errorText and type(os.__amaryllisLog)=="function" then
                    pcall(os.__amaryllisLog,"Motion warning monitor: "..errorText,"core.motion-warning")
                end
                motionWarnings.runtimeError=errorText
                pcall(motionWarnings.reset,motionWarnings,"MONITOR ERROR")
            else motionWarnings.runtimeError=nil end
            snapshot.motionWarnings=motionOK and motionState or {available=false,active=false,gate="WARNING MONITOR ERROR"}
            local captured,issue=pcall(debugRecorder.capture,debugRecorder,snapshot,io,now,flight)
            if not captured then
                debugRecorder.enabled=false;debugRecorder.state="ERROR";debugRecorder.reason="DEBUG CAPTURE FAILED: "..tostring(issue)
            end
            snapshot.progressStalls=progressWatchdog:snapshot()
            snapshot.physicsCheck=physicsMonitor:snapshot(io)
            snapshot.debugMode=debugRecorder:snapshot()
            snapshot.controlPresets=controlPresets:snapshot()
            -- A preset restore hold is not shown on displays (core log only).
            -- Only an actionable case - a lever that must return to neutral
            -- before the restore - is still displayed.
            local presets=snapshot.controlPresets
            local presetReason=presets.reason
            if presetReason~=lastPresetLog then
                lastPresetLog=presetReason
                if presetReason and type(os.__amaryllisLog)=="function" then
                    pcall(os.__amaryllisLog,"Control presets: "..tostring(presetReason),"core.presets")
                end
            end
            if (presets.pending or presets.awaitingSystems) and type(snapshot.cockpitControl)=="table" then
                local cockpit=snapshot.cockpitControl
                if type(presetReason)=="string" and presetReason:find("NOT NEUTRAL",1,true) then
                    cockpit.reason=presetReason
                else
                    cockpit.headingWaitingForNeutral=false;cockpit.throttleWaitingForNeutral=false
                    cockpit.altitudeWaitingForNeutral=false
                    if cockpit.reason==nil or tostring(cockpit.reason):find("PRESETS",1,true) then cockpit.reason=nil end
                end
            end
            snapshot.performance=metrics:snapshot()
            snapshot.remoteAP=remoteAP:status()
            publishRuntime(snapshot,true)
            metrics:measure("display_send",io.broadcastDisplayStatus,io,snapshot)
            nextPublish = now + config.network.broadcast_interval_seconds
        end
        if event=="timer" or received then flight.restart:tick(flight,io,io:nowSeconds(),os.reboot) end
        if event == "timer" and sender == timer then timer = os.startTimer(0.1) end
        if cockpitTiming then pcall(cockpitTiming.finishWork,cockpitTiming,"supervisor_pass",passStarted,io:nowSeconds()) end
    end
    end
    parallel.waitForAny(receiver,supervisor)
end
-- Assembly gate input: physics_assembler.isAssembled(), kept on its own
-- schedule so a slow vessel sample cannot delay the gate.
-- @ama-summary: Refresh the current assembler observation in its independent sampling worker.
local function assemblySample()
    -- isAssembled() has taken up to ~2 s under server load; a 2 s timeout
    -- discarded those answers and let the gate go stale.
    -- Only an explicit false matters, so every 2 s is plenty and keeps the
    -- core's per-tick peripheral budget for the vessel and cockpit readers.
    sampler("assembly",function() return io:sampleAssembly() end,6,2,
        function(value) if value and value.error then return value.error end end)
end
local PropulsionWorker=require("avionics.propulsion_worker")
local function coreLog(text,source)
    if type(os.__amaryllisLog)=="function" then pcall(os.__amaryllisLog,text,source or "core.propulsion")
    else print(text) end
end
-- The propulsion worker is the only caller of autopilot and anchor updates.
-- An uncaught error used to end its tab silently, freezing the autopilot at
-- ACQ with no target. Errors are now caught, logged, published and retried
-- with backoff; propulsion is commanded to stop while the step is failing.
-- sleep() waits only for its own timer event; if that event is ever dropped
-- the caller never wakes. This wait also ends on any later event past the
-- deadline, and radio traffic arrives several times a second.
-- @ama-summary: Yield until the requested repeat interval or an incoming runtime event.
local function pause(seconds)
    local deadline=os.clock()+seconds
    local timer=os.startTimer(seconds)
    while os.clock()<deadline do
        local event,id=os.pullEventRaw()
        if event=="timer" and id==timer then break end
    end
end
-- @ama-summary: Run the independent propulsion-control cadence and publish completion progress.
local function propulsionWorker(context)
    local failures=0
    io.propulsionWorkerBeat=io:nowSeconds()
    while os.__amaryllisPropulsionContext==context do
        local ok,issue=pcall(metrics.measure,metrics,"propulsion",PropulsionWorker.step,io,flight,io:nowSeconds(),io.propulsionHeartbeat)
        if os.__amaryllisPropulsionContext~=context then break end
        io.propulsionWorkerBeat=io:nowSeconds()
        if ok then
            if io.propulsionWorkerError then coreLog("Core propulsion worker recovered") end
            io.propulsionWorkerError=nil;failures=0
        else
            failures=failures+1
            io.propulsionWorkerError=tostring(issue):gsub("[%c]"," "):sub(1,160)
            if failures==1 or failures%50==0 then
                coreLog("Core propulsion worker error ("..failures.."): "..io.propulsionWorkerError)
            end
            pcall(function() if io.thrust then io.thrust:stop(io,"PROPULSION WORKER ERROR") end end)
        end
        pause(failures>0 and math.min(2,0.1*2^math.min(failures,5)) or .1)
    end
end
local function newPropulsionContext()
    local context={owner=io.session}
    context.run=function() propulsionWorker(context) end
    os.__amaryllisPropulsionContext=context
    return context
end
local propulsionContext=newPropulsionContext()
-- Same failure mode as the propulsion worker: sleep() never returns if its
-- timer event is dropped, leaving a debug request stuck at CHECKING DISK.
-- Use the tolerant pause, publish a heartbeat, and let the watchdog replace
-- a stalled worker.
-- @ama-summary: Run paced removable-media debug writes from cached runtime data.
local function debugWorker(context)
    io.debugWorkerBeat=io:nowSeconds()
    while os.__amaryllisDebugContext==context do
        pcall(debugRecorder.step,debugRecorder,io)
        io.debugWorkerBeat=io:nowSeconds()
        pause(.5)
    end
end
local function newDebugContext()
    local context={owner=io.session}
    context.run=function() debugWorker(context) end
    os.__amaryllisDebugContext=context
    return context
end
local debugContext=newDebugContext()
if shell and type(shell.openTab)=="function" and multishell then
    local jobs={vessel=sample,cockpit=cockpitSample,assembly=assemblySample,fallback=fallbackSample,assembler=assemblerDataSample}
    local names={"cockpit","vessel","assembly","fallback","assembler"}
    if io.stateLink then jobs={state=stateSample};names={"state"};io.sampling.state={} end
    samplingContext={owner=io.session,jobs=jobs}
    os.__amaryllisSamplingContext=samplingContext
    for _,name in ipairs(names) do
        local ok,tab=pcall(shell.openTab,"/avionics/main.lua","sampler",name,samplingContext.owner)
        if not ok or type(tab)~="number" then
            os.__amaryllisSamplingContext=nil
            error("Could not start independent "..name.." reader: "..tostring(tab),0)
        end
        if multishell.setTitle then pcall(multishell.setTitle,tab,name.." reader") end
        io.sampling[name].tab=tab
    end
    if io.stateLink then
        -- State computer failover. All sensor and cockpit data arrives in the
        -- state computer's frames; if it stops (crash, unload, cable), the
        -- core would be steering on nothing. After FAILOVER_AFTER seconds
        -- without an accepted frame the core starts its own readers (the
        -- pre-split path, same peripherals on the shared network). Once
        -- frames have flowed again for RECOVER_AFTER seconds the local
        -- readers are stopped and the state computer takes back over.
        local FAILOVER_AFTER,RECOVER_AFTER,BOOT_GRACE=5,5,15
        -- @ama-summary: Refresh the local vessel observation in its sampling context.
        local localJobs={vessel=function()
                -- Bind the sensors and cockpit link locally before reading.
                local ok,issue=pcall(io.scanHardware,io)
                if not ok then coreLog("Failover hardware scan failed: "..tostring(issue),"core.failover")
                else
                    local errors=(io.inventory and io.inventory.errors) or {}
                    if #errors>0 then coreLog("Failover hardware scan: "..tostring(table.concat(errors,"; ")):sub(1,200),"core.failover") end
                end
                sample()
            end,cockpit=cockpitSample,assembly=assemblySample,
            fallback=fallbackSample,assembler=assemblerDataSample}
        local localNames={"cockpit","vessel","assembly","fallback","assembler"}
        local bootAt=io:nowSeconds()
        local generation=0
        local failover={active=false}
        io.stateFailover=failover
        -- @ama-summary: Start core's local sensor workers for state-computer failover.
        local function startLocal(now,age)
            generation=generation+1
            local context={owner=io.session..":failover:"..generation,jobs=localJobs}
            os.__amaryllisFailoverContext=context
            io.stateFailoverScan=true
            local started,failed=0,nil
            for _,name in ipairs(localNames) do
                io.sampling[name]=type(io.sampling[name])=="table" and io.sampling[name] or {}
                io.sampling[name].source="CORE (FAILOVER)"
                samplerGuards[name]=function() return os.__amaryllisFailoverContext==context end
                local ok,tab=pcall(shell.openTab,"/avionics/main.lua","failover-sampler",name,context.owner)
                if ok and type(tab)=="number" then
                    started=started+1
                    if multishell.setTitle then pcall(multishell.setTitle,tab,name.." (failover)") end
                else failed=tostring(tab) end
            end
            if failover.lastRecoveredAt and now-failover.lastRecoveredAt<120 then failover.flaps=(failover.flaps or 0)+1
            else failover.flaps=0 end
            failover.active=true;failover.since=now;failover.recoveringSince=nil
            failover.reason="STATE COMPUTER SILENT "..string.format("%.0f",age).." S; CORE READING SENSORS"
            coreLog("State computer #"..tostring(io.stateLink.id).." silent for "..string.format("%.1f",age)..
                " s; core started "..started.." local readers"..(failed and (" (failed: "..failed..")") or ""),"core.failover")
        end
        -- @ama-summary: Retire the active local sensor workers when state service recovers.
        local function stopLocal(now)
            -- Guards stay installed: they compare against the now-cleared
            -- context, so each failover reader exits after its current read.
            os.__amaryllisFailoverContext=nil;io.stateFailoverScan=nil
            coreLog("State computer #"..tostring(io.stateLink.id).." frames restored; local readers stopped after "..
                string.format("%.0f",now-(failover.since or now)).." s","core.failover")
            failover.active=false;failover.since=nil;failover.recoveringSince=nil;failover.reason=nil
            failover.lastRecoveredAt=now
        end
        -- @ama-summary: Evaluate state-frame freshness and coordinate local-reader takeover or handback.
        io.stateFailoverCheck=function(now)
            local link=io.stateLink
            local last=link.lastFrameAt
            local age=type(last)=="number" and now-last or now-bootAt
            if not failover.active then
                if now-bootAt>=BOOT_GRACE and age>=FAILOVER_AFTER then
                    -- A backed-up core event queue also delays frames. Then the
                    -- state computer is fine and extra local reads would only
                    -- deepen the backlog, so wait for the core to catch up.
                    local lag=io.eventLagSeconds
                    if type(lag)=="number" and lag>2 then
                        if not failover.deferLogged then
                            failover.deferLogged=true
                            coreLog("State frames "..string.format("%.1f",age).." s old but core event lag is "..
                                string.format("%.1f",lag).." s; failover deferred","core.failover")
                        end
                        return
                    end
                    failover.deferLogged=nil
                    startLocal(now,age)
                end
                return
            end
            -- An intermittent state computer must not flap the readers on and
            -- off: each failover that follows a recovery within 2 minutes
            -- doubles the clean-frame time needed to hand back (up to 60 s).
            local needed=RECOVER_AFTER*2^math.min(failover.flaps or 0,4)
            if age<1 then
                failover.recoveringSince=failover.recoveringSince or now
                if now-failover.recoveringSince>=needed then stopLocal(now) end
            else failover.recoveringSince=nil end
        end
    end
    -- Watchdog: if the worker stops completing steps (its tab ended or it is
    -- blocked), replace it with a fresh tab. The old loop exits on its next
    -- resume because the current context no longer matches.
    local nextPropulsionRelaunch=0
    -- @ama-summary: Monitor propulsion worker completion and schedule paced worker replacement.
    io.propulsionWatchdog=function(now)
        local beat=io.propulsionWorkerBeat
        if not beat or now-beat<5 or now<nextPropulsionRelaunch then return end
        nextPropulsionRelaunch=now+15
        coreLog("Core propulsion worker stalled for "..string.format("%.0f",now-beat).." s; restarting it")
        io.propulsionWorkerError=io.propulsionWorkerError or "PROPULSION WORKER STALLED; RESTARTING"
        pcall(function() if io.thrust then io.thrust:stop(io,"PROPULSION WORKER STALLED") end end)
        newPropulsionContext()
        io.propulsionWorkerBeat=now
        local ok,tab=pcall(shell.openTab,"/avionics/main.lua","propulsion-worker",io.session)
        if ok and type(tab)=="number" and multishell.setTitle then pcall(multishell.setTitle,tab,"propulsion runtime") end
        if not ok or type(tab)~="number" then coreLog("Core propulsion worker restart failed: "..tostring(tab)) end
    end
    io.propulsionWorkerBeat=io.propulsionWorkerBeat or io:nowSeconds()
    local propulsionOK,propulsionTab=pcall(shell.openTab,"/avionics/main.lua","propulsion-worker",io.session)
    if not propulsionOK or type(propulsionTab)~="number" then
        os.__amaryllisPropulsionContext=nil
        error("Could not start independent propulsion controller",0)
    end
    if multishell.setTitle then pcall(multishell.setTitle,propulsionTab,"propulsion runtime") end
    local nextDebugRelaunch=0
    -- @ama-summary: Monitor debug worker completion and schedule paced worker replacement.
    io.debugWatchdog=function(now)
        local beat=io.debugWorkerBeat
        if not beat or now-beat<5 or now<nextDebugRelaunch then return end
        nextDebugRelaunch=now+15
        coreLog("Core debug worker stalled for "..string.format("%.0f",now-beat).." s; restarting it","core.debug")
        newDebugContext();io.debugWorkerBeat=now
        local relaunched,newTab=pcall(shell.openTab,"/avionics/main.lua","debug-worker",io.session)
        if relaunched and type(newTab)=="number" and multishell.setTitle then pcall(multishell.setTitle,newTab,"debug recorder") end
    end
    io.debugWorkerBeat=io.debugWorkerBeat or io:nowSeconds()
    local ok,tab=pcall(shell.openTab,"/avionics/main.lua","debug-worker",io.session)
    debugRecorder.workerAvailable=ok and type(tab)=="number"
    if debugRecorder.workerAvailable then
        if multishell.setTitle then pcall(multishell.setTitle,tab,"debug recorder") end
    else debugRecorder.state="ERROR";debugRecorder.reason="DEBUG WORKER UNAVAILABLE" end
    runtime()
else
    if io.stateLink then parallel.waitForAny(runtime,stateSample,debugContext.run,propulsionContext.run)
    else parallel.waitForAny(runtime, sample, cockpitSample, assemblySample, fallbackSample, assemblerDataSample, debugContext.run, propulsionContext.run,
        function()
            if cockpitTiming then cockpitTiming:pulseWorker(os) end
            while true do os.pullEventRaw() end
        end) end
end
