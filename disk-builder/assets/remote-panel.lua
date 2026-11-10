-- Amaryllis unified remote panel v1. One application, existing paired protocols.
local App={};App.__index=App
local WHITE,GRAY,LIGHT,BLACK,YELLOW=1,128,256,32768,16
local function clean(v)return tostring(v==nil and "--"or v):gsub("[%c]"," ")end
local function finite(n)return type(n)=="number"and n==n and math.abs(n)<math.huge end
local function copy(v)if type(v)~="table"then return v end;local t={};for k,x in pairs(v)do t[k]=copy(x)end;return t end
local function readJSON(path)
    local h=fs.open(path,"r");if not h then return nil end
    local raw=h.readAll();h.close();return textutils.unserializeJSON(raw)
end
local function age(n)return finite(n)and string.format("%.1fs",math.max(0,n))or"--"end
local function wrap(text,width)
    text=clean(text);local out={}
    while #text>width do
        local at=text:sub(1,width+1):match("^.*() ")
        if not at or at<width/2 then at=width+1 end
        out[#out+1]=text:sub(1,at-1);text=text:sub(at):gsub("^ +","")
    end
    out[#out+1]=text;return out
end
function App.new(cfg)
    assert(type(cfg)=="table"and cfg.schemaVersion==1 and type(cfg.coreID)=="number"and
        type(cfg.token)=="string"and type(cfg.pairID)=="string"and cfg.protocol=="amaryllis.remote.v1","Invalid remote pairing")
    local form={name="Remote CMD",cruiseSpeed=3}
    return setmetatable({cfg=cfg,page="home",focus={},offsets={},cache={},nav={},form=form,sequence=0,
        online=false,notice="Connecting...",links={},releaseAnchor=false},App)
end
function App:modems()
    local found=false
    for _,name in ipairs(peripheral.getNames())do if peripheral.hasType(name,"modem")then
        local m=peripheral.wrap(name);local ok,wireless=pcall(m.isWireless)
        if ok and wireless then rednet.open(name);found=true end
    end end
    return found
end
function App:send(action,extra)
    if self.pending then return false end
    if (action=="status"or action=="ap_status")and self.readAfter and os.clock()<self.readAfter then
        self:deferRead(self.readAfter-os.clock());return false
    end
    if self.readTimer then os.cancelTimer(self.readTimer);self.readTimer=nil end
    if not self:modems()then self.online=false;self.notice="Attach wireless modem";return false end
    self.sequence=self.sequence+1
    local id=os.getComputerID()..":"..os.epoch("utc")..":"..self.sequence
    local p={v=1,pairID=self.cfg.pairID,token=self.cfg.token,requestID=id,sentAt=os.epoch("utc"),boot=self.boot,action=action}
    for k,v in pairs(extra or {})do p[k]=v end
    rednet.send(self.cfg.coreID,p,self.cfg.protocol)
    self.pending={id=id,action=action,page=p.page,at=os.clock()};self.timeout=os.startTimer(5)
    return true
end
function App:statusPage()
    local pages={home="OVERVIEW",overview="OVERVIEW",lift="LIFT",propulsion="PROPULSION",navigation="NAVIGATION",
        computers="FLEET",computer="FLEET",errors="FLEET",details="FLEET",related="FLEET",logs="LOGS"}
    return pages[self.page]
end
function App:deferRead(delay)
    if not self.readTimer then self.readTimer=os.startTimer(math.max(.05,delay or .3))end
end
function App:poll()
    if self.pending then return end
    if not self.boot then self:send("hello")
    elseif self.command then self:send("ap_result",{commandID=self.command.id})
    elseif self.page=="ap"or self.page=="destination"or self.page=="review"or self.page=="route"then self:send("ap_status")
    else
        -- Presentation reads cached publications. Ship work keeps its existing priority.
        local page=self:statusPage()
        if page then self:send("status",{page=page})
        elseif not self.lastReply or os.clock()-self.lastReply>=2 then self:send("status",{page="OVERVIEW"})end
    end
end
function App:choose(page)
    self.page=page;self.links={}
    local target=self:statusPage()
    -- Navigation is local; related views share the same cached fleet reply.
    if not self.boot or not self.command and(target and not self.cache[target] or
        (page=="ap"or page=="route"or page=="destination")and not self.navAt)then self:poll()end
end
function App:back()
    if self.editor then self.editor=nil;return end
    if self.page=="review"then self.review=nil;self.notice="Review cancelled"end
    local parents={overview="status",lift="status",propulsion="status",navigation="status",computer="computers",
        errors="computer",details="computer",related="computer",destination="ap",review="ap",route="ap",connection="tools"}
    self:choose(parents[self.page]or"home")
end
function App:startReview(cancel)
    if self.command or self.pending then self.notice="Wait for current request";return end
    local n=self.nav
    if not self.online or not self.boot or not n.session or not self.navAt or os.clock()-self.navAt>6 then self.notice="Connect to core first";return end
    if not n.enabled then self.notice=n.reason or"Enable remote AP on core";return end
    if not n.permitted then self.notice="Core must allow this remote";return end
    if cancel then
        if not n.owned then self.notice="No route owned by this remote";return end
    else
        if n.active then self.notice="Active route cannot be replaced";return end
        local f=self.form
        if not finite(f.x)or not finite(f.z)or math.abs(f.x)>30000000 or math.abs(f.z)>30000000 then self.notice="Enter valid destination X/Z";return end
        if not finite(f.altitude)or f.altitude< -64 or f.altitude>320 then self.notice="Enter altitude (-64 to 320)";return end
        if not finite(f.cruiseSpeed)or f.cruiseSpeed<.1 or f.cruiseSpeed>30 then self.notice="Enter speed (0.1 to 30)";return end
    end
    self.review={cancel=cancel,session=n.session,generation=n.generation,destination=copy(self.form),releaseAnchor=self.releaseAnchor}
    self.review.destination.name="Remote CMD"
    self.focus.review=2;self:choose("review");self.notice="Review before confirming"
end
function App:confirm()
    local r=self.review
    if not r or self.pending or self.command then self.notice="Wait for current request";return end
    if not self.online or self.nav.session~=r.session or self.nav.generation~=r.generation then
        self.review=nil;self:choose("ap");self.notice="Authority changed; review again";return
    end
    self.sequence=self.sequence+1
    local id=os.getComputerID()..":"..os.epoch("utc")..":"..self.sequence
    if self:send(r.cancel and"ap_cancel"or"ap_send",{commandID=id,coreSession=r.session,generation=r.generation,
        destination=r.destination,releaseAnchor=r.releaseAnchor})then
        self.command={id=id,session=r.session};self.review=nil;self.page="ap";self.notice="PENDING: core must validate"
    end
end
function App:computer()
    local item=self.cache.FLEET
    for _,c in ipairs(item and item.data.computers or{})do if c.role==self.selected then return c end end
end
function App:reportAge(c)
    local cached=self.cache.FLEET
    return finite(c.age)and c.age+math.max(0,os.clock()-(cached and cached.at or os.clock()))or nil
end
function App:activate(action)
    if action:sub(1,3)=="go:"then self:choose(action:sub(4))
    elseif action:sub(1,9)=="computer:"then self.selected=action:sub(10);self:choose("computer")
    elseif action:sub(1,5)=="edit:"then
        if self.command then self.notice="Wait for command result";return end
        local k=action:sub(6);self.editor={key=k,buffer=self.form[k]and tostring(self.form[k])or""}
    elseif action=="back"then self:back()
    elseif action=="review"then self:startReview(false)
    elseif action=="cancel-route"then self:startReview(true)
    elseif action=="confirm"then self:confirm()
    elseif action=="anchor"then if not self.command then self.releaseAnchor=not self.releaseAnchor end
    elseif action=="refresh"then self:poll()
    elseif action=="reconnect"then
        if self.pending then os.cancelTimer(self.timeout)end
        self.pending=nil;self.boot=nil;self.online=false;self.review=nil;self.notice="Reconnecting...";self:poll()
    elseif action=="admin"and fs.exists("/admin.lua")then
        shell.run("/admin.lua")
        if self.pending then os.cancelTimer(self.timeout)end
        self.pending=nil;self.boot=nil;self.online=false;self:poll()
    end
end
function App:draw()
    local w,h=term.getSize();self.links={}
    term.setBackgroundColor(GRAY);term.setTextColor(WHITE);term.clear();term.setCursorBlink(false)
    local function put(x,y,s,width,fg,bg)
        if y<1 or y>h or x>w then return end
        width=math.max(0,math.min(width or w-x+1,w-x+1))
        term.setCursorPos(x,y);term.setTextColor(fg or WHITE);term.setBackgroundColor(bg or GRAY)
        term.write((clean(s)..string.rep(" ",width)):sub(1,width))
    end
    local function button(y,label,action)
        if h==19 and y==16 then y=15 end
        if y>h-4 or y<4 then return end
        self.links[#self.links+1]={x=2,y=y,w=w-2,label=label,action=action}
    end
    local titles={home="HOME",status="STATUS",overview="OVERVIEW",lift="LIFT",propulsion="PROPULSION",navigation="NAVIGATION",
        computers="COMPUTERS",computer="COMPUTER",errors="ERRORS",details="DETAILS",related="RELATED LOGS",logs="LOGS",
        ap="AUTOPILOT",route="ROUTE PROGRESS",destination="DESTINATION",review="REVIEW",tools="TOOLS",connection="CONNECTION"}
    put(1,1,"AMARYLLIS / REMOTE",w,WHITE,BLACK)
    local reachable=self.lastReply and os.clock()>=self.lastReply and os.clock()-self.lastReply<=10
    put(2,2,reachable and ("CONNECTED #"..self.cfg.coreID) or "CORE UNREACHABLE",w-2,reachable and WHITE or YELLOW)
    if self.page~="home"then put(2,3,"< Back",7,BLACK,LIGHT)end
    put(self.page=="home"and 2 or 10,3,titles[self.page]or"REMOTE",w-(self.page=="home"and 2 or 10))
    local function list(rows,first,last,key)
        first=first or 5;last=last or h-5;key=key or self.page
        local rendered={}
        for _,line in ipairs(rows)do for _,part in ipairs(wrap(line,w-3))do rendered[#rendered+1]=part end end
        local cap=math.max(1,last-first+1);local offset=math.max(0,math.min(math.max(0,#rendered-cap),self.offsets[key]or 0))
        self.offsets[key]=offset
        for i=1,cap do put(2,first+i-1,rendered[offset+i]or"",w-2)end
        if #rendered>cap then put(w-9,4,(offset+1).."/"..#rendered,8,LIGHT)end
    end
    local function cached(page)
        local entry=self.cache[page]
        if not entry then return{"Waiting for core..."}end
        local rows={}
        if not self.online or os.clock()-entry.at>6 then rows[1]="STALE: last reported"end
        for _,s in ipairs(entry.data.lines or{})do rows[#rows+1]=s end
        return rows
    end
    if w<26 or h<19 then
        put(2,5,"Requires 26 x 19.",w-2);return
    elseif self.page=="home"then
        for i,item in ipairs({{"Status","status"},{"Computers","computers"},{"Autopilot","ap"},{"Logs","logs"},{"Tools","tools"}})do
            button(4+i*2,item[1].." >", "go:"..item[2])
        end
    elseif self.page=="status"then
        for i,item in ipairs({{"Overview","overview"},{"Lift","lift"},{"Propulsion","propulsion"},{"Navigation","navigation"}})do
            button(4+i*2,item[1].." >","go:"..item[2])
        end
    elseif self.page=="computers"then
        local entry=self.cache.FLEET;local rows=entry and entry.data.computers or{}
        local selected=self.focus.computers or 1;local cap=h-9
        local offset=self.offsets.computers or 0
        if selected<=offset then offset=selected-1 elseif selected>offset+cap then offset=selected-cap end
        offset=math.max(0,math.min(math.max(0,#rows-cap),offset));self.offsets.computers=offset
        if #rows==0 then list(cached("FLEET"))end
        for i=offset+1,math.min(#rows,offset+cap)do
            local c=rows[i]
            local state=c.state or"WAIT"
            if not self.online or entry and os.clock()-entry.at>6 then state="STALE"end
            local label=clean(c.name).." #"..clean(c.id)
            button(5+i-offset,label:sub(1,w-10)..string.rep(" ",math.max(1,w-10-#label))..state,"computer:"..c.role)
        end
        if #rows>cap then put(w-9,4,(offset+1).."-"..math.min(#rows,offset+cap).."/"..#rows,8,LIGHT)end
        self.totalComputers=#rows
        self.visibleOffset=offset
    elseif self.page=="computer"then
        local c=self:computer()
        if not c then list({"Waiting for computer report..."})
        else
            local reported=self.online and self.cache.FLEET and os.clock()-self.cache.FLEET.at<=6 and c.state~="STALE" and c.state~="WAIT"
            put(2,5,clean(c.name).." #"..clean(c.id),w-2)
            put(2,6,"State: "..(reported and clean(c.state)or"STALE"),w-2)
            put(2,7,(reported and"Program: "or"Last prog: ")..(c.running==nil and(c.reporting and"REPORTING"or"--")or c.running and"RUNNING"or"STOPPED"),w-2)
            put(2,8,(reported and"Hardware: "or"Last hw: ")..(c.hardware==nil and"--"or c.hardware and"AVAILABLE"or"UNAVAILABLE"),w-2)
            put(2,9,"Report: "..age(self:reportAge(c)).." ago",w-2)
            put(2,10,"Reply: "..(finite(c.reply)and string.format("%.0fms",c.reply*1000)or"--"),w-2)
            button(12,"Errors ("..#(c.errors or{})..") >","go:errors")
            button(14,"More details >","go:details")
            button(16,"Related logs >","go:related")
        end
    elseif self.page=="errors"or self.page=="details"or self.page=="related"then
        local c=self:computer()
        local rows=c and(self.page=="errors"and c.errors or self.page=="details"and c.details or c.logs)or{}
        if #rows==0 then rows={self.page=="errors"and"No reported errors."or"No related core log events."}end
        list(rows)
    elseif self.page=="ap"then
        local n=self.nav
        put(2,5,"Access: "..(n.permitted and"ALLOWED"or"NOT ALLOWED"),w-2)
        put(2,6,"Remote AP: "..(n.enabled and"ENABLED"or"DISABLED"),w-2)
        put(2,7,"State: "..clean(n.state),w-2)
        put(2,8,n.owned and"Your route"or"No route owned",w-2)
        put(2,9,"Distance: "..(finite(n.distance)and string.format("%.1f",n.distance)or"--"),w-2)
        button(11,"Destination >","go:destination")
        button(13,n.active and"Route progress >"or"Review route >",n.active and"go:route"or"review");button(15,"Disengage route >","cancel-route")
    elseif self.page=="route"then
        local n=self.nav;local d=n.destination or{}
        list({"State: "..clean(n.state),"X: "..clean(d.x),"Z: "..clean(d.z),"Altitude: "..clean(d.altitude),
            "Cruise: "..clean(d.cruiseSpeed).." b/s","Distance: "..clean(n.distance),"Speed: "..clean(n.speed).." b/s",
            n.owned and"Your route"or"Route owned elsewhere",n.apReason or n.reason or""})
    elseif self.page=="destination"then
        for i,item in ipairs({{"X","x"},{"Z","z"},{"Altitude","altitude"},{"Speed","cruiseSpeed"}})do
            button(4+i*2,item[1]..": "..clean(self.form[item[2]])..(item[2]=="cruiseSpeed"and" b/s"or""),"edit:"..item[2])
        end
        button(14,"Release anchor: "..(self.releaseAnchor and"YES"or"NO"),"anchor")
        button(16,"Review route >","review")
    elseif self.page=="review"then
        local r=self.review
        if not r then self.page="ap";return self:draw()end
        list({r.cancel and"Disengage your route?"or"Send Remote CMD?",
            "X "..clean(r.destination.x).." Z "..clean(r.destination.z),
            "Altitude "..clean(r.destination.altitude),"Speed "..clean(r.destination.cruiseSpeed).." b/s",
            "Release anchor: "..(r.releaseAnchor and"YES"or"NO"),"Clear route required."},5,12)
        button(14,"Confirm","confirm");button(16,"Cancel","back")
    elseif self.page=="tools"then
        button(6,"Refresh","refresh");button(8,"Reconnect","reconnect");button(10,"Connection details >","go:connection")
        if fs.exists("/admin.lua")then button(12,"Administration >","admin")end
    elseif self.page=="connection"then
        list({"Core #"..self.cfg.coreID,"Link: "..(reachable and"CONNECTED"or"CORE UNREACHABLE"),
            "Last reply: "..(self.lastReply and age(os.clock()-self.lastReply)or"--"),
            "Round trip: "..(self.roundTrip and string.format("%.0fms",self.roundTrip*1000)or"--"),
            "Protocol: "..self.cfg.protocol})
    else
        local pages={overview="OVERVIEW",lift="LIFT",propulsion="PROPULSION",navigation="NAVIGATION",logs="LOGS"}
        list(cached(pages[self.page]or"OVERVIEW"))
    end
    local focus=math.max(1,math.min(#self.links,self.focus[self.page]or 1))
    if self.page=="computers"then focus=math.max(1,math.min(#self.links,(self.focus.computers or 1)-(self.visibleOffset or 0)))
    else self.focus[self.page]=focus end
    for i,link in ipairs(self.links)do put(link.x,link.y,(i==focus and"> "or"  ")..link.label,link.w,i==focus and BLACK or WHITE,i==focus and LIGHT or GRAY)end
    local message=self.editor and("Edit "..self.editor.key..": "..self.editor.buffer)or self.notice
    local rows=wrap(message or"",w-3)
    local neutral=({Connected=true,["Status received"]=true,["Updating status..."]=true,["Ready for destination"]=true,["Destination updated"]=true,["Review cancelled"]=true})[self.notice]
    local color=self.online and neutral and LIGHT or YELLOW
    for i=1,2 do put(2,h-3+i-1,rows[i]or"",w-2,color)end
    put(2,h,self.editor and"Enter save / Esc cancel"or"Arrows / Enter / Back",w-2,LIGHT)
end
function App:input(event,a,b,c)
    if event=="mouse_click"and a==1 and not self.editor then
        if self.page~="home"and c==3 and b>=2 and b<=8 then self:back();return end
        for _,link in ipairs(self.links)do if c==link.y and b>=link.x and b<link.x+link.w then self:activate(link.action);return end end
    elseif self.editor then
        if event=="char"or event=="paste"then self.editor.buffer=(self.editor.buffer..tostring(a):gsub("[^%d%+%-%.eE]","")):sub(1,24)
        elseif event=="key"and a==keys.backspace then self.editor.buffer=self.editor.buffer:sub(1,-2)
        elseif event=="key"and a==keys.escape then self.editor=nil
        elseif event=="key"and a==keys.enter then
            local n=tonumber(self.editor.buffer)
            if finite(n)then self.form[self.editor.key]=n;self.editor=nil;self.review=nil;self.notice="Destination updated"
            else self.notice="Enter a valid number"end
        end
    elseif event=="key"then
        if a==keys.escape or a==keys.backspace or a==keys.left then if self.page~="home"then self:back()end
        elseif a==keys.up or a==keys.down then
            local delta=a==keys.down and 1 or -1
            if self.page=="computers"then self.focus.computers=math.max(1,math.min(self.totalComputers or 1,(self.focus.computers or 1)+delta))
            elseif #self.links>0 then self.focus[self.page]=math.max(1,math.min(#self.links,(self.focus[self.page]or 1)+delta))
            else self.offsets[self.page]=math.max(0,(self.offsets[self.page]or 0)+delta)end
        elseif a==keys.enter then
            local i=self.focus[self.page]or 1
            if self.page=="computers"then i=i-(self.visibleOffset or 0)end
            local link=self.links[i];if link then self:activate(link.action)end
        end
    elseif event=="mouse_scroll"then
        if self.page=="computers"then self.focus.computers=math.max(1,math.min(self.totalComputers or 1,(self.focus.computers or 1)+a))
        else self.offsets[self.page]=math.max(0,(self.offsets[self.page]or 0)+a)end
    end
end
function App:event(event,a,b,c)
    if event=="rednet_message"and self.pending and a==self.cfg.coreID and c==self.cfg.protocol and type(b)=="table"and
        b.v==1 and b.coreID==self.cfg.coreID and b.requestID==self.pending.id and type(b.boot)=="string"then
        local pending=self.pending;os.cancelTimer(self.timeout);self.pending=nil
        self.lastReply=os.clock()
        if pending.action~="hello"and b.boot~=self.boot then
            self.boot=nil;self.online=false;self.review=nil;self.notice="Core restarted; reconnecting"
        elseif not b.ok and pending.action=="status"and b.error=="Status requested too quickly"then
            -- A throttle reply proves connectivity; it is not a link failure.
            self.online=true;self.lastReply=os.clock()
            self.readAfter=os.clock()+math.max(.3,finite(b.retryAfterSeconds)and math.min(2,b.retryAfterSeconds)or .3)
            self.notice="Updating status...";self:deferRead(self.readAfter-os.clock())
        elseif not b.ok then
            self.online=false;self.notice=clean(b.error)
            if self.notice:find("reconnect",1,true)then self.boot=nil;self.review=nil end
        else
            self.online=true;self.lastReply=os.clock();self.roundTrip=math.max(0,os.clock()-pending.at)
            local d=type(b.data)=="table"and b.data or{}
            if pending.action=="hello"then self.boot=b.boot;self.notice="Connected";self:poll()
            elseif pending.action=="status"then
                self.cache[pending.page]={data=d,at=os.clock()-(finite(b.cachedAgeSeconds)and math.max(0,b.cachedAgeSeconds)or 0)};self.readAfter=os.clock()+.3
                if not self.command then self.notice="Status received"end
                local wanted=self:statusPage()
                if wanted and not self.cache[wanted]then self:deferRead(.3)end
            elseif pending.action=="ap_status"then
                self.nav=d;self.navAt=os.clock();self.readAfter=os.clock()+.3
                if self.form.altitude==nil and finite(d.selectedAltitude)then self.form.altitude=d.selectedAltitude end
                if self.review and(d.session~=self.review.session or d.generation~=self.review.generation)then
                    self.review=nil;if self.page=="review"then self.page="ap"end;self.notice="Authority changed; review again"
                elseif not self.review and not self.command then self.notice=d.apReason or d.reason or"Ready for destination"end
            else
                self.notice=clean(d.status)..": "..clean(d.reason)
                if d.status~="PENDING"then self.command=nil end
            end
        end
    elseif event=="timer"and a==self.timeout and self.pending then
        self.pending=nil;self.boot=nil;self.online=false;self.review=nil
        self.notice=self.command and"UNKNOWN: querying command result"or"STALE: no reply from core"
    elseif event=="timer"and a==self.readTimer then self.readTimer=nil;self:poll()
    elseif event=="timer"and a==self.refresh then self.refresh=os.startTimer(.5);self:poll()
    elseif event=="peripheral"then self:poll()
    else self:input(event,a,b,c)end
end
function App:run()
    self:poll();self.refresh=os.startTimer(.5);self:draw()
    while true do self:event(os.pullEvent());self:draw()end
end
if ...=="__amaryllis_remote_test"then return App end
App.new(assert(readJSON("/amaryllis-remote.json"),"Remote configuration missing")):run()
