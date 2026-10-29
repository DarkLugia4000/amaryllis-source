-- Amaryllis Panel Home. Cached telemetry only; no flight or peripheral writes.
-- This source lives inside core's existing runtime bundle.
local Panel={}
local ORDER={"core","navigator","heading-left","heading-right","heading-main","state",
    "chamber_fl","chamber_fr","chamber_bl","chamber_br","primary_l","primary_r","thrust-lb","thrust-rb","thrust-ls","thrust-rs"}
local NAMES={core="core",navigator="bridge",["heading-left"]="hdg-l",["heading-right"]="hdg-r",["heading-main"]="hdg-m",
    state="state",chamber_fl="chamber-fl",chamber_fr="chamber-fr",chamber_bl="chamber-bl",chamber_br="chamber-br",
    primary_l="primary-l",primary_r="primary-r",["thrust-lb"]="thrust-lb",["thrust-rb"]="thrust-rb",["thrust-ls"]="thrust-ls",["thrust-rs"]="thrust-rs"}
local ROLES={core="FLIGHT CONTROL",navigator="BRIDGE NAVIGATOR",state="VESSEL / COCKPIT TELEMETRY",
    ["heading-left"]="LEFT HEADING DISPLAY",["heading-right"]="RIGHT HEADING DISPLAY",["heading-main"]="MAIN HEADING DISPLAY",
    chamber_fl="FL COMBINED CHAMBER",chamber_fr="FR COMBINED CHAMBER",chamber_bl="BL COMBINED CHAMBER",chamber_br="BR COMBINED CHAMBER",
    primary_l="LEFT PRIMARY TELEMETRY",primary_r="RIGHT PRIMARY TELEMETRY",["thrust-lb"]="REAR-LEFT THRUST",
    ["thrust-rb"]="REAR-RIGHT THRUST",["thrust-ls"]="LEFT-SIDE THRUST",["thrust-rs"]="RIGHT-SIDE THRUST"}
local QUADRANTS={chamber_fl="FL",chamber_fr="FR",chamber_bl="RL",chamber_br="RR"}
local function finite(n)return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function clean(v)return tostring(v==nil and "--" or v):gsub("[%c]"," ")end
local function useful(v)return type(v)=="string" and v~="" and v~="NONE" and v~="none" and v~="--" end
local function age(v)return finite(v) and string.format("%.1fs",math.max(0,v)) or "--" end
local function value(v)return v==nil and "--" or v==true and "YES" or v==false and "NO" or clean(v) end
local function installerLabel(v)
    local labels={waiting_for_media="WAITING FOR DISK",waiting_for_client="WAITING FOR COMPUTERS",checking="CHECKING PACKAGES",
        transferring="SENDING PACKAGES",committing="VERIFYING PACKAGE",installed="PACKAGE INSTALLED",current="UP TO DATE"}
    return labels[v]or clean(v or"WAITING"):gsub("_"," "):upper()
end
local function readJSON(path)
    local h=fs.open(path,"r");if not h then return nil end
    local ok,raw=pcall(h.readAll);pcall(h.close)
    if not ok or type(raw)~="string" or #raw>65536 then return nil end
    local good,object=pcall(textutils.unserializeJSON,raw);return good and object or nil
end
local function wrap(text,width)
    local rows={};text=clean(text);width=math.max(1,width)
    while #text>width do
        local at=text:sub(1,width+1):match("^.*() ");if not at or at<math.floor(width/2) then at=width+1 end
        rows[#rows+1]=text:sub(1,at-1);text=text:sub(at):gsub("^ +","")
    end
    rows[#rows+1]=text;return rows
end
local function flatten(object,prefix,rows,seen,depth)
    if type(object)~="table" then rows[#rows+1]=prefix..": "..value(object);return end
    if seen[object] then return end;seen[object]=true
    local keys={};for k,v in pairs(object)do if type(v)~="function" and type(v)~="userdata" then keys[#keys+1]=k end end
    table.sort(keys,function(a,b)return tostring(a)<tostring(b)end)
    for _,key in ipairs(keys)do
        local name=prefix=="" and clean(key) or prefix.." / "..clean(key)
        if type(object[key])=="table" then
            if depth<8 then flatten(object[key],name,rows,seen,depth+1)else rows[#rows+1]=name..": [nested data]" end
        else rows[#rows+1]=name..": "..value(object[key]) end
        if #rows>=1024 then rows[#rows+1]="Further fields omitted at the diagnostic display limit.";break end
    end
end

function Panel.computers(context)
    local runtime=context.runtime or {};local snap=runtime.snapshot or {}
    local registry=(snap.fleetRegistry or {}).computers or runtime.computers or context.fleet or {}
    local delay=finite(runtime.publishedAt) and math.max(0,(context.now or 0)-runtime.publishedAt) or 0
    local result={}
    for _,role in ipairs(ORDER)do
        local registered=registry[role] or {};local health=(snap.roleHealth or {})[role] or {}
        local sub={};for _,item in ipairs(snap.subsystems or {})do if registered.id~=nil and item.id==registered.id then sub=item;break end end
        local quadrant=QUADRANTS[role]
        local node=quadrant and (snap.nodes or {})[quadrant] or nil
        local components={}
        local semantic=role=="primary_l"and"primary-left"or role=="primary_r"and"primary-right"or role
        for group,items in pairs(snap.thrust or {})do if type(items)=="table"then
            for name,item in pairs(items)do if type(item)=="table"and(name==role or name==semantic or registered.id~=nil and
                (item.nodeId==registered.id or item.id==registered.id or item.computerID==registered.id))then components[clean(group).." / "..clean(name)]=item end end
        end end
        -- Controller packets may be relayed by a chamber and therefore have
        -- that chamber's nodeId. Match the semantic role, not only the child ID.
        local endpoint=(snap.thrust or {}).roles and (snap.thrust.roles[semantic]or snap.thrust.roles[role]) or nil
        if not endpoint and (role=="primary_l"or role=="primary_r")then endpoint=((snap.thrust or {}).units or {})[semantic]end
        local reportAge=health.ageSeconds or (endpoint and endpoint.statusAgeSeconds) or sub.ageSeconds or (node and node.statusAgeSeconds)
        if finite(reportAge)then reportAge=math.max(0,reportAge+delay)end
        local online=health.online
        if online==nil and endpoint then
            online=endpoint.online
            if online==nil then online=endpoint.statusFresh==true end
        end
        if online==nil then online=sub.status=="ONLINE" or sub.status=="RUNNING" or node and node.online==true or false end
        if health.online==nil and endpoint and (endpoint.statusFresh==false or finite(reportAge)and finite(endpoint.staleAfterSeconds)and reportAge>endpoint.staleAfterSeconds)then online=false end
        if delay>5 then online=false end
        local running,hardware=health.running,health.hardwareAvailable
        if running==nil and endpoint and type(endpoint.running)=="boolean"then running=endpoint.running end
        if hardware==nil and endpoint then
            if type(endpoint.hardwareAvailable)=="boolean"then hardware=endpoint.hardwareAvailable
            elseif type(endpoint.bindingReady)=="boolean"then hardware=endpoint.bindingReady
            elseif role=="primary_l"or role=="primary_r"then hardware=endpoint.available end
        end
        local reporting=running==nil and online and (endpoint~=nil or next(sub)~=nil)
        local sourceID=endpoint and endpoint.nodeId or nil;local sourceName
        if sourceID~=nil and sourceID~=registered.id then
            sourceName="#"..clean(sourceID)
            for sourceRole,record in pairs(registry)do if type(record)=="table"and record.id==sourceID then sourceName=(NAMES[sourceRole]or sourceRole).." #"..sourceID;break end end
        end
        if role=="core" then reportAge=finite(runtime.publishedAt)and delay or nil;online=finite(runtime.publishedAt)and delay<=5;running=runtime.running;hardware=runtime.hardwareAvailable end
        local errors,seen={},{}
        local function error(text)
            if useful(text)and not seen[text]then seen[text]=true;errors[#errors+1]=text end
        end
        error(health.error);error(health.faultSummary)
        if role=="core" then error(runtime.faultSummary);error(runtime.registryError);for _,f in ipairs(snap.faults or {})do error(f)end end
        for _,f in ipairs(node and node.faults or {})do error(f)end
        for _,component in pairs(components)do for _,f in ipairs(component.faults or {})do error(f)end end
        if registered.id==nil then error("Computer has no assigned ID")
        elseif not online then error(reportAge and "No fresh status report" or "Waiting for a status report")end
        if online and running==false then error("Role program is stopped")end
        if online and hardware==false then error("Reported hardware unavailable")end
        local state=registered.id==nil and "NO ID" or not online and (reportAge and "STALE" or "WAIT") or
            running==false and "STOPPED" or #errors>0 and "ISSUE" or "ONLINE"
        -- Only an actual measured request/reply duration may populate Reply.
        local reply=health.responseSeconds or health.roundTripSeconds
        result[#result+1]={role=role,name=NAMES[role],id=registered.id,label=registered.label,state=state,
            online=online,running=running,reporting=reporting,hardware=hardware,age=reportAge,reply=finite(reply)and reply or nil,
            endpoint=endpoint,via=sourceName,sourceID=sourceID,
            errors=errors,health=health,node=node,components=components,subsystem=sub,registration=registered,
            package=(context.catalog or {})[role],lastKnown=not online and (reportAge~=nil or running~=nil or hardware~=nil)}
    end
    return result
end

-- Bounded remote presentation data. Existing cached telemetry only.
function Panel.remoteComputers(context)
    local result={}
    local function bounded(v,n)return clean(v):sub(1,n or 120)end
    local function tail(rows,count,width)
        local out={};for i=math.max(1,#rows-count+1),#rows do out[#out+1]=bounded(rows[i],width)end
        return out
    end
    for _,c in ipairs(Panel.computers(context))do
        local details={}
        local function row(label,v)if v~=nil then details[#details+1]=label..": "..bounded(v,96)end end
        row("Report via",c.via);row("Role",ROLES[c.role]);row("ID",c.id)
        local expected=c.package
        if c.health.packageId then row("Package",c.health.packageId.." v"..clean(c.health.version))
        elseif expected and expected.packageId then row("Package (expected)",expected.packageId.." v"..clean(expected.version))end
        if c.node then row("Lift",c.node.liftControlState);row("Thrust",c.node.thrustControlState)end
        if c.endpoint then row("Status fresh",c.endpoint.statusFresh);row("Binding ready",c.endpoint.bindingReady);row("Last ACK",c.endpoint.lastAckSeq)end
        local errors={};for i=1,math.min(8,#c.errors)do errors[i]=bounded(c.errors[i],160)end
        result[#result+1]={role=c.role,name=c.name,id=c.id,state=c.state,running=c.running,reporting=c.reporting,
            hardware=c.hardware,age=c.age,reply=c.reply,via=c.via,errors=errors,details=details,
            logs=tail(Panel.relatedLogs(context,c),4,140)}
    end
    return result
end


function Panel.relatedLogs(context,computer)
    local rows={};local role,label=computer.role,computer.label
    for _,entry in ipairs((context.capture or {}).console or {})do
        local text=clean(entry.text or entry.message or "")
        local match=role=="core"or entry.role==role or computer.id~=nil and (entry.computerID==computer.id or entry.nodeId==computer.id)
        if not match then
            match=text:find(role,1,true)~=nil or label and text:find(label,1,true)~=nil
            if not match and computer.id~=nil then match=text:find("#"..computer.id.."%f[%D]")~=nil end
            local quadrant=QUADRANTS[role]
            if not match and quadrant then match=text:find("%f[%w]"..quadrant.."%f[%W]")~=nil end
        end
        if match then rows[#rows+1]=(entry.timestamp and ("["..clean(entry.timestamp).."] ") or "")..text end
    end
    if #rows==0 then rows[1]="No related core log events."end
    return rows
end

function Panel.new(console,dependencies)
    return setmetatable({console=console,deps=dependencies or {},page="home",offsets={},anchors={},anchorOffsets={},listPage=1,links={},selected="core",previous={}}, {__index=Panel})
end
function Panel:choose(page)
    self.page=page;self.previous={}
end
function Panel:back()
    local parent={status="home",computers="home",installation="home",logs="home",tools="home",services="tools",
        computer="computers",errors="computer",details="computer",related="computer",installDetails="installation",
        overview="status",lift="status",propulsion="status",navigation="status",fleet="status"}
    self:choose(parent[self.page]or "home")
end
function Panel:frame(context,width,height)
    local frame={width=width,height=height,text={},foreground={},background={},links={}}
    self.links={};self.maxScroll,self.scrollKey=0,nil
    local function put(x,y,text,fg,bg,n)
        if y<1 or y>height or x>width then return end
        text=clean(text);n=n or #text;text=(text..string.rep(" ",math.max(0,n-#text))):sub(1,math.min(n,width-x+1))
        if x<1 then text=text:sub(2-x);x=1 end
        local function replace(row,v)return row:sub(1,x-1)..v..row:sub(x+#v)end
        frame.text[y]=replace(frame.text[y],text)
        frame.foreground[y]=replace(frame.foreground[y],string.rep(fg or "0",#text))
        frame.background[y]=replace(frame.background[y],string.rep(bg or "7",#text))
    end
    for y=1,height do frame.text[y]=string.rep(" ",width);frame.foreground[y]=string.rep("0",width);frame.background[y]=string.rep("7",width)end
    local function button(x,y,w,h,label,action)
        for row=y,y+h-1 do put(x,row,"","f","8",w)end
        put(x+math.max(0,math.floor((w-#label)/2)),y+math.floor((h-1)/2),label,"f","8")
        frame.links[#frame.links+1]={x=x,y=y,w=w,h=h,action=action}
    end
    put(1,1,"AMARYLLIS","0","f",width);put(math.max(12,width-10),1,"core #"..clean(context.id or os.getComputerID()),"0","f")
    if width<40 or height<18 then
        put(2,4,"Enlarge this terminal to at least 40 x 18.")
        put(2,6,"Services continue running.")
        return frame
    end
    local titles={home="HOME",status="STATUS",computers="COMPUTERS",computer="COMPUTER",errors="COMPUTER ERRORS",details="COMPUTER DETAILS",
        related="RELATED CORE LOGS",installation="INSTALLATION",installDetails="INSTALLATION DETAILS",logs="LOGS",tools="TOOLS",services="BACKGROUND SERVICES",
        overview="OVERVIEW",lift="FLIGHT / LIFT",propulsion="PROPULSION",navigation="NAVIGATION",fleet="FLEET DIAGNOSTICS"}
    if self.page=="home" then put(2,3,"HOME")else button(2,3,8,1,"< Back","back");put(12,3,titles[self.page]or self.page:upper())end
    local computers=Panel.computers(context);local selected,firstIssue,online,issueCount=nil,nil,0,0
    for _,computer in ipairs(computers)do
        if computer.role==self.selected then selected=computer end
        if computer.online then online=online+1 end
        if #computer.errors>0 then
            issueCount=issueCount+1
            if not firstIssue or firstIssue.role=="core"and computer.role~="core"then firstIssue=computer end
        end
    end
    selected=selected or computers[1]
    local runtime=context.runtime or {};local snap=runtime.snapshot or {};local systems=snap.systemsStartup or {}
    local function pair(y,label,data)
        label=clean(label);data=clean(data);local room=math.max(1,width-#label-5)
        put(2,y,label);put(math.max(#label+4,width-math.min(#data,room)),y,data:sub(1,room))
    end
    local half=math.floor((width-5)/2);local right=half+4
    local function body(rows,first,last)
        first,last=first or 5,last or height-2
        local wrapped={};for _,line in ipairs(rows)do for _,part in ipairs(wrap(line,width-4))do wrapped[#wrapped+1]=part end end
        local key=self.page..":"..self.selected
        local max=math.max(0,#wrapped-(last-first+1));local offset=math.max(0,math.min(max,self.offsets[key]or 0))
        if (self.page=="logs"or self.page=="related")and offset>0 and self.anchorOffsets[key]==offset and self.anchors[key]then
            for at,line in ipairs(wrapped)do if line==self.anchors[key]then offset=math.min(max,at-1);break end end
        end
        self.offsets[key]=offset;self.anchors[key]=wrapped[offset+1];self.anchorOffsets[key]=offset
        self.maxScroll,self.scrollKey=max,key
        for y=first,last do put(2,y,wrapped[offset+y-first+1]or "")end
        if max>0 then put(width-13,height-1,string.format("%d-%d / %d",offset+1,math.min(#wrapped,offset+last-first+1),#wrapped))end
    end
    self.maxScroll,self.scrollKey=0,nil
    if self.page=="home" then
        pair(5,"Systems",systems.phase or "WAITING")
        pair(6,"Fleet",online.."/"..#computers.." ONLINE")
        pair(7,"Installer",installerLabel((context.installer or {}).state))
        local panelHeight=math.max(2,math.floor((height-13)/2));local second=10+panelHeight
        button(2,9,half,panelHeight,"Status","status");button(right,9,half,panelHeight,"Computers","computers")
        button(2,second,half,panelHeight,"Installation","installation");button(right,second,half,panelHeight,"Logs","logs")
        button(2,height-2,half,1,"Tools >","tools")
        if firstIssue then button(right,height-2,half,1,issueCount.." computer issue"..(issueCount==1 and ""or"s").." >","issue")end
    elseif self.page=="computers" then
        local count=math.max(1,height-9);local pages=math.max(1,math.ceil(#computers/count));self.listPage=math.min(pages,math.max(1,self.listPage))
        put(2,5," ID   NAME           STATE   REPLY  ERR")
        for index=(self.listPage-1)*count+1,math.min(#computers,self.listPage*count)do
            local computer=computers[index];local y=7+(index-1)%count
            local reply=computer.reply and string.format("%.0fms",computer.reply*1000)or"--"
            local chosen=computer.role==self.selected
            local line=string.format("%s%-4s %-14s %-7s %-6s %d",chosen and">"or" ",computer.id or "?",computer.name:sub(1,14),computer.state:sub(1,7),reply,#computer.errors)
            put(2,y,line,chosen and"f"or"0",chosen and"8"or index%2==0 and"7"or"f",width-2)
            frame.links[#frame.links+1]={x=2,y=y,w=width-2,h=1,action="computer:"..computer.role}
        end
        button(2,height-2,9,1,"< Prev","prev");put(math.floor(width/2)-3,height-2,self.listPage.." / "..pages);button(width-10,height-2,9,1,"Next >","next")
    elseif self.page=="computer" then
        put(12,3,selected.name.." #"..clean(selected.id),"0","7",width-12)
        pair(5,"Role",ROLES[selected.role]or selected.role);pair(6,"State",selected.state)
        pair(7,selected.lastKnown and "Program (reported)"or"Program",selected.running==nil and(selected.reporting and"REPORTING"or"--")or selected.running and"RUNNING"or"STOPPED")
        pair(8,selected.lastKnown and "Hardware (reported)"or"Hardware",selected.hardware==nil and"--"or selected.hardware and"AVAILABLE"or"UNAVAILABLE")
        pair(9,"Response time",selected.reply and string.format("%.0fms",selected.reply*1000)or"--")
        pair(10,"Last status report",age(selected.age)..(selected.age and" ago"or""))
        local expected=selected.package and type(selected.package.packageId)=="string"and selected.package or nil
        local package=selected.health.packageId and ((selected.health.packageId).." v"..clean(selected.health.version))or
            expected and(expected.packageId.." v"..clean(expected.version))or"--"
        pair(11,selected.health.packageId and"Package"or expected and"Package (expected)"or"Package",package)
        if selected.node then pair(12,"Lift / thrust",value(selected.node.liftControlState).." / "..value(selected.node.thrustControlState))
        elseif selected.via then pair(12,"Report via",selected.via)end
        if selected.lastKnown then put(2,13,"! NO FRESH STATUS REPORT");put(2,14,"Program/hardware values are last reported.")
        elseif #selected.errors>0 then put(2,13,"! "..selected.errors[1]:sub(1,width-4))end
        button(2,height-4,half,1,"Errors ("..#selected.errors..")","errors");button(right,height-4,half,1,"More details","details")
        button(2,height-2,width-3,1,"Related logs","related")
    elseif self.page=="status" then
        local list={{"Overview","overview"},{"Flight / Lift","lift"},{"Propulsion","propulsion"},{"Navigation","navigation"},{"Fleet diagnostics","fleet"}}
        for i,item in ipairs(list)do button(2,4+i*2,width-3,1,item[1].." >",item[2])end
    elseif self.page=="installation" then
        local progress=context.progress or {};local rows=progress.rows or {};local done,total,failed=0,0,0
        for _,row in pairs(rows)do total=total+1;if row.state=="DONE"then done=done+1 elseif row.state=="FAULT"then failed=failed+1 end end
        local status=context.installer or {}
        pair(5,"State",installerLabel(status.state));pair(6,"Verified",done.." / "..total);pair(7,"Faults",failed)
        pair(9,"Current computer",status.targetID and("#"..status.targetID.." "..clean(NAMES[status.targetRole]or status.targetRole))or"--")
        pair(10,"File",status.currentPath or "--")
        local sent,totalBytes=status.bytesSent,status.bytesTotal
        pair(11,"Transfer",finite(totalBytes)and totalBytes>0 and string.format("%d%%",math.min(100,math.floor((sent or 0)*100/totalBytes)))or"--")
        if useful(status.lastError or status.detail)then for i,line in ipairs(wrap(status.lastError or status.detail,width-4))do if i<=3 then put(2,12+i,line)end end end
        button(2,height-2,width-3,1,"Progress and computer details >","installDetails")
    elseif self.page=="tools" then
        put(2,4,"F2: recovery shell")
        local list={{"Shell","shell"},{"Lua","lua"},{"Diagnostic client","diagnostics"},{"Full core view / edit IDs","fleet"},
            {"Install / pair remote","remote-install"},{"Remote flight access","remote-ops"},{"Background services","services"}}
        for i,item in ipairs(list)do
            local y=3+i*2;if y<=height-2 then button(2,y,width-3,1,item[1].." >",item[2]=="services"and"services"or"tool:"..item[2])end
        end
    else
        local rows={}
        if self.page=="errors" then rows=selected.errors;if #rows==0 then rows={"No current errors reported."}end
        elseif self.page=="details" then
            local details={registration=selected.registration,health=selected.health,lift=selected.node,components=selected.components,
                subsystem=selected.subsystem,expectedPackage=selected.package,
                reportSource={nodeId=selected.sourceID,via=selected.via,controller=selected.endpoint}}
            if selected.role=="core"then details.core={sampling=runtime.sampling,identity=snap.coreIdentity,readers=snap.readers,
                systems=snap.systemsStartup,registryError=runtime.registryError,performance=snap.performance}end
            flatten(details,"",rows,{},0)
        elseif self.page=="related" then rows=Panel.relatedLogs(context,selected)
        elseif self.page=="services" then
            rows={"Independent CraftOS processes", ""}
            for _,item in ipairs(context.services or {})do rows[#rows+1]=item.title.." / "..(item.state=="dead"and"STOPPED"or"RUNNING")end
            if #rows==2 then rows[#rows+1]="Service details unavailable."end
        elseif self.page=="installDetails" then
            local progress=context.progress or {}
            for _,role in ipairs(progress.order or {})do local row=(progress.rows or {})[role]or{};rows[#rows+1]="#"..clean(row.id).." "..(NAMES[role]or role)..": "..clean(row.state);if useful(row.reason)then rows[#rows+1]="  "..row.reason end end
            flatten(context.installer or {},"Installer",rows,{},0)
        else
            local legacy=({overview="OVERVIEW",lift="LIFT",propulsion="PROPULSION",navigation="NAVIGATION",fleet="FLEET",logs="LOGS"})[self.page]
            rows=legacy and self.console.pageRows(legacy,"core",context.capture,runtime,context.installer,context.now)or{"No cached data."}
            if self.page=="fleet"then flatten(runtime.computers or {},"Registered computers",rows,{},0)end
        end
        if self.page=="errors"then body(rows,5,height-4);button(2,height-2,width-3,1,"Related logs >","related")else body(rows)end
    end
    local notice=firstIssue and("! "..firstIssue.name..": "..firstIssue.errors[1])or"All reported systems available"
    put(1,height,notice,"0","f",width)
    self.links,self.firstIssue,self.computerCount,self.pageCapacity=frame.links,firstIssue,#computers,math.max(1,height-9)
    return frame
end
function Panel:action(action)
    if action=="back"then self:back()
    elseif action=="next"then self.listPage=math.min(math.ceil((self.computerCount or 16)/(self.pageCapacity or 10)),self.listPage+1);self.previous={}
    elseif action=="prev"then self.listPage=math.max(1,self.listPage-1);self.previous={}
    elseif action=="issue"and self.firstIssue then self.selected=self.firstIssue.role;self:choose("computer")
    elseif action:sub(1,9)=="computer:"then self.selected=action:sub(10);self:choose("computer")
    elseif action:sub(1,5)=="tool:"then if self.deps.tool then self.deps.tool(action:sub(6))end;self.previous={}
    else self:choose(action)end
end
function Panel:input(event,a,b,c)
    if event=="mouse_click"and a==1 then for _,link in ipairs(self.links)do if b>=link.x and b<link.x+link.w and c>=link.y and c<link.y+link.h then self:action(link.action);return true end end
    elseif event=="key"then
        if a==keys.backspace or a==keys.escape then self:back()
        elseif self.scrollKey and(a==keys.up or a==keys.down or a==keys.pageUp or a==keys.pageDown)then
            local step=(a==keys.up and -1)or(a==keys.down and 1)or(a==keys.pageUp and -5)or 5
            self.offsets[self.scrollKey]=math.max(0,math.min(self.maxScroll,(self.offsets[self.scrollKey]or 0)+step))
        end
    elseif event=="mouse_scroll"and self.scrollKey then self.offsets[self.scrollKey]=math.max(0,math.min(self.maxScroll,(self.offsets[self.scrollKey]or 0)+a))
    elseif event=="term_resize"then self.previous={}
    elseif event=="terminate"then self:choose("home")end
end
function Panel:draw(context,screen)
    local w,h=screen.getSize();local frame=self:frame(context,w,h)
    screen.setCursorBlink(false)
    for y=1,h do
        local signature=frame.text[y]..frame.foreground[y]..frame.background[y]
        if self.previous[y]~=signature then screen.setCursorPos(1,y);screen.blit(frame.text[y],frame.foreground[y],frame.background[y]);self.previous[y]=signature end
    end
    return frame
end

-- Keep CraftOS's process scheduler and event filters. Adapt presentation only.
-- No event dispatch is performed by the visible dashboard.
function Panel.hostSource(source)
    -- Resource-pack ROM overrides may preserve Windows line endings.
    source=source:gsub("\r\n","\n"):gsub("\r","\n")
    local function replace(old,new)
        local first,last=source:find(old,1,true);assert(first and not source:find(old,last+1,true),"Unsupported CraftOS console host: "..old:match("[^\n]+"):sub(1,80))
        source=source:sub(1,first-1)..new..source:sub(last+1)
    end
    replace("local tProcesses = {}","local tProcesses = {}\nlocal panelRoot\nlocal panelTools={}")
    replace("local function setMenuVisible(bVis)\n","local function setMenuVisible(bVis)\n    bVis=false\n")
    replace("local function redrawMenu()\n",[=[local function redrawMenu()
    if nCurrentProcess and panelTools[tProcesses[nCurrentProcess]] then
        parentTerm.setCursorPos(1,1);parentTerm.setBackgroundColor(colors.gray);parentTerm.setTextColor(colors.white)
        parentTerm.write((" < Back    "..panelTools[tProcesses[nCurrentProcess]]..string.rep(" ",w)):sub(1,w))
        tProcesses[nCurrentProcess].window.restoreCursor()
    end
]=])
    replace("        local x, y = tProcess.window.getCursorPos()\n        if y > windowHeight then\n            tProcess.window.scroll(y - windowHeight)\n            tProcess.window.setCursorPos(x, windowHeight)",
        "        local processHeight=panelTools[tProcess] and h-1 or windowHeight\n        local x, y = tProcess.window.getCursorPos()\n        if y > processHeight then\n            tProcess.window.scroll(y - processHeight)\n            tProcess.window.setCursorPos(x, processHeight)")
    replace("tProcess.window.reposition(1, windowY, w, windowHeight)",
        "tProcess.window.reposition(1, panelTools[tProcess] and 2 or windowY, w, processHeight)")
    replace("        table.remove(tProcesses, nProcess)","        panelTools[tProcess]=nil\n        table.remove(tProcesses, nProcess)")
    replace("        if nCurrentProcess == nil then\n            if nProcess > 1 then",[=[        if nCurrentProcess == nil then
            for i,process in ipairs(tProcesses)do if process==panelRoot then selectProcess(i);break end end
        end
        if nCurrentProcess == nil then
            if nProcess > 1 then]=])
    replace("-- Begin\n",[=[-- Amaryllis host API, process objects survive numeric index changes.
function multishell.amaryllisRoot(n)panelRoot=tProcesses[n]end
function multishell.amaryllisFocusRoot()
    for i,p in ipairs(tProcesses)do if p==panelRoot then return multishell.setFocus(i)end end
    return false
end
function multishell.amaryllisTool(n,title)
    local process=tProcesses[n];if not process then return false end
    if title=="Recovery shell"then setProcessTitle(n,"tool / shell")end
    panelTools[process]=title;resizeWindows();multishell.setFocus(n)
    return true
end
function multishell.amaryllisServices()
    local out={};for i,p in ipairs(tProcesses)do out[#out+1]={id=i,title=p.sTitle,state=coroutine.status(p.co)}end;return out
end
-- Begin
]=])
    replace('}, "/rom/programs/shell.lua")','}, "/rom/programs/shell.lua", "/startup.lua", "panel")')
    replace('    local sEvent = tEventData[1]\n',[=[    local sEvent = tEventData[1]
    if sEvent=="key" and tEventData[2]==keys.f2 then
        local recovery
        for i,p in ipairs(tProcesses)do
            if panelTools[p]=="shell" or panelTools[p]=="Recovery shell"then recovery=i;break end
        end
        if not recovery then recovery=multishell.launch({shell=shell,multishell=multishell},"/rom/programs/shell.lua")end
        multishell.amaryllisTool(recovery,"Recovery shell")
        if os.__amaryllisPanelOwner then os.__amaryllisPanelOwner.returnToTools=true end
        sEvent="amaryllis_recovery_shell";tEventData={sEvent};tEventData.n=1
    end
    if panelTools[tProcesses[nCurrentProcess]] then
        if (sEvent=="mouse_click" and tEventData[4]==1 and tEventData[3]<=10) or
            (sEvent=="key" and tEventData[2]==keys.f1) then
            for i,p in ipairs(tProcesses)do if p==panelRoot then multishell.setFocus(i);break end end
            sEvent="amaryllis_tool_return";tEventData={sEvent};tEventData.n=1
        elseif sEvent=="mouse_click" or sEvent=="mouse_drag" or sEvent=="mouse_up" or sEvent=="mouse_scroll" then
            if tEventData[4]==1 then sEvent="amaryllis_tool_header";tEventData={sEvent};tEventData.n=1
            else tEventData[4]=tEventData[4]-1 end
        end
    end
]=])
    return source
end
function Panel.host()
    local previous=os.__amaryllisPanelOwner
    if type(previous)=="table"and previous.active then
        if type(previous.focus)=="function"then previous.focus()end
        return
    end
    local path="/rom/programs/advanced/multishell.lua"
    local h=assert(fs.open(path,"r"),"CraftOS application host unavailable")
    local source=h.readAll();h.close();assert(#source<65536,"Unexpected CraftOS application host")
    local adapted=Panel.hostSource(source)
    local owner={active=true};os.__amaryllisPanelOwner=owner
    local outer,outerID=multishell,multishell and multishell.getCurrent and multishell.getCurrent()
    owner.outerFocus=function()if outer and outer.setFocus and outerID then outer.setFocus(outerID)end end
    local ok,issue=pcall(assert(load(adapted,"@amaryllis-console-host","t",_ENV)))
    owner.active=false
    if not ok then error(issue,0)end
end

function Panel.start(console,openTab,reportError)
    os.__amaryllisPagedConsole=true
    local root=multishell and multishell.getCurrent and multishell.getCurrent()
    if root and multishell.amaryllisRoot then multishell.amaryllisRoot(root)end
    if root and multishell.setTitle then multishell.setTitle(root,"amaryllis")end
    local owner=os.__amaryllisPanelOwner
    if owner and multishell and multishell.amaryllisFocusRoot then owner.focus=function()owner.outerFocus();return multishell.amaryllisFocusRoot()end end
    local workers=os.__amaryllisCoreWorkerTabs or {};os.__amaryllisCoreWorkerTabs=workers
    local function find(title)
        if not multishell or not multishell.getCount then return nil end
        for id=1,multishell.getCount()do if multishell.getTitle(id)==title then return id end end
    end
    local function start(mode,title)
        local old=find(title);if old then workers[mode]=old;return old end
        local id,issue=openTab({mode},title);if not id then error("Could not start "..title..": "..clean(issue),0)end
        workers[mode]=id;return id
    end
    start("role","core runtime")
    for _,service in ipairs({{"installer","installer"},{"diagnostics","diagnostics"},{"remote-status","remote status"}})do
        local ok,issue=pcall(start,service[1],service[2]);if not ok then reportError(issue,"panel-service:"..service[1])end
    end
    local admin=readJSON("/amaryllis-admin.json")
    if type(admin)=="table"and type(admin.token)=="string"and #admin.token>=32 then start("remote-admin","remote manager")end
    local app=os.__amaryllisPanelView or Panel.new(console);os.__amaryllisPanelView=app
    app.console=console
    app.deps.tool=function(mode)
        local title=mode=="diagnostics"and"diagnostics"or("tool / "..mode)
        local id=find(title)or start(mode,title)
        if multishell.amaryllisTool then multishell.amaryllisTool(id,mode)
        elseif multishell.setFocus then multishell.setFocus(id)end
    end
    local stored={}
    local cacheAt=-math.huge
    local function context()
        local now=os.clock()
        if owner and owner.returnToTools then app:choose("tools");owner.returnToTools=false end
        if now-cacheAt>=5 then
            local fleet=readJSON("/fleet.json")or{};local catalog=readJSON("/installer/library.json")or{}
            stored={fleet=fleet.computers,catalog=catalog.roles,installer=readJSON("/installer/install_status.json")};cacheAt=now
        end
        local progress=os.__amaryllisInstallerProgress or {}
        local installer={}
        for key,value in pairs(stored.installer or {})do installer[key]=value end
        for key,value in pairs(progress.status or {})do installer[key]=value end
        return {id=os.getComputerID(),now=now,runtime=os.__amaryllisRuntime or {},capture=os.__amaryllisDiagnostics or {},
            installer=installer,progress=progress,fleet=stored.fleet,catalog=stored.catalog,
            services=multishell.amaryllisServices and multishell.amaryllisServices()or{}}
    end
    while true do
        local ok,issue=pcall(function()
            app.previous={};local timer=os.startTimer(1);app:draw(context(),term)
            while true do
                local e,a,b,c=os.pullEventRaw()
                if e=="timer"and a==timer then timer=os.startTimer(1);app:draw(context(),term)
                elseif e=="mouse_click"or e=="mouse_scroll"or e=="key"or e=="term_resize"or e=="terminate"or e=="amaryllis_tool_return"or e=="amaryllis_recovery_shell" then
                    app:input(e,a,b,c);app:draw(context(),term)
                end
            end
        end)
        if not ok then reportError("Console interface recovered: "..clean(issue),"panel-ui");app:choose("home");os.sleep(1)end
    end
end
return Panel
