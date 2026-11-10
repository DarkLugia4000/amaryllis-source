-- Section: Remote AP client | Reviewed destinations and correlated command progress.
-- Paired remote AP: explicit review, queued acknowledgement and read-only progress.
local function readJSON(path)
    local h=fs.open(path,"r");if not h then return nil end
    local data=h.readAll();h.close();return textutils.unserializeJSON(data)
end
local cfg=assert(readJSON("/amaryllis-remote.json"),"Remote pairing missing")
assert(cfg.schemaVersion==1 and type(cfg.coreID)=="number" and type(cfg.token)=="string" and
    type(cfg.pairID)=="string" and cfg.protocol=="amaryllis.remote.v1","Invalid pairing")
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function text(v) return tostring(v or "--"):gsub("[%c]"," ") end
-- Transient Remote CMD compatibility client.
local form={name="Remote CMD",cruiseSpeed=3}
local releaseAnchor=false
local nav={};local boot,pending,timer,refresh,command,review,editor
local online=false;local notice="Connecting...";local sequence=0
-- Section: Remote AP client | Reviewed destinations and correlated command progress.
-- Summary: Find and open the network modems used by the current client.
local function modems()
    local found=false
    for _,name in ipairs(peripheral.getNames()) do if peripheral.hasType(name,"modem") then
        local modem=peripheral.wrap(name);local ok,wireless=pcall(modem.isWireless)
        if ok and wireless then rednet.open(name);found=true end
    end end
    return found
end
-- Summary: Send the current correlated packet to its configured peer.
local function send(action,extra)
    if pending then return false end
    if not modems() then online=false;notice="Attach wireless modem";return false end
    sequence=sequence+1
    local requestID=os.getComputerID()..":"..os.epoch("utc")..":"..sequence
    local p={v=1,pairID=cfg.pairID,token=cfg.token,requestID=requestID,
        sentAt=os.epoch("utc"),boot=boot,action=action}
    for k,v in pairs(extra or {}) do p[k]=v end
    rednet.send(cfg.coreID,p,cfg.protocol)
    pending={id=requestID,action=action};timer=os.startTimer(5);return true
end
local function poll()
    if pending then return end
    if not boot then send("hello")
    elseif command then send("ap_result",{commandID=command.id})
    else send("ap_status") end
end
local function valid()
    if not finite(form.x) or not finite(form.z) or math.abs(form.x)>30000000 or math.abs(form.z)>30000000 then return false,"Enter valid destination X/Z" end
    if not finite(form.altitude) or form.altitude< -64 or form.altitude>320 then return false,"Enter altitude (-64 to 320)" end
    if not finite(form.cruiseSpeed) or form.cruiseSpeed<.1 or form.cruiseSpeed>30 then return false,"Enter speed (0.1 to 30)" end
    return true
end
-- Summary: Capture the requested remote destination for operator review.
local function startReview(cancel)
    if command or pending then notice="Wait for current request";return end
    if not online or not boot or not nav.session then notice="Connect to core first";return end
    if not nav.enabled then notice=nav.reason or "Enable remote AP on core";return end
    if not nav.permitted then notice="Core must allow this remote";return end
    if cancel then
        if not nav.owned then notice="No route owned by this remote";return end
    else
        if nav.active then notice="Active route cannot be replaced";return end
        local ok,why=valid();if not ok then notice=why;return end
    end
    review={cancel=cancel,session=nav.session,generation=nav.generation,
        destination={name=form.name,x=form.x,z=form.z,altitude=form.altitude,cruiseSpeed=form.cruiseSpeed},releaseAnchor=releaseAnchor}
    notice="G confirms / B goes back"
end
-- Summary: Submit the reviewed operation and track its request acknowledgement.
local function confirm()
    if not review or pending or command then return end
    if not online or nav.session~=review.session or nav.generation~=review.generation then review=nil;notice="Authority changed; review again";return end
    sequence=sequence+1
    local commandID=os.getComputerID()..":"..os.epoch("utc")..":"..sequence
    local extra={commandID=commandID,coreSession=review.session,generation=review.generation,
        destination=review.destination,releaseAnchor=review.releaseAnchor}
    local action=review.cancel and "ap_cancel" or "ap_send"
    if send(action,extra) then command={id=commandID,session=review.session};review=nil;notice="PENDING: core must validate" end
end
-- Summary: Render the current view into its configured terminal or monitor.
local function draw()
    local width,height=term.getSize();term.setBackgroundColor(colors.black);term.setTextColor(colors.white);term.clear()
    local function row(y,value,color)
        if y>=1 and y<=height then term.setCursorPos(1,y);term.setTextColor(color or colors.white);term.write(text(value):sub(1,width)) end
    end
    row(1,"AMARYLLIS / REMOTE AP",colors.cyan)
    row(2,online and ("CONNECTED #"..cfg.coreID) or "CORE UNREACHABLE",online and colors.lime or colors.yellow)
    row(3,"Access "..(nav.permitted and "ALLOW" or "DENY").." / "..(nav.enabled and "ENABLED" or "DISABLED"))
    row(4,"AP "..text(nav.state)..(nav.owned and " / YOUR ROUTE" or ""),colors.cyan)
    local d=nav.destination
    row(5,d and ("To X "..text(d.x).." Z "..text(d.z)) or "No active destination")
    row(6,"Dist "..(finite(nav.distance) and string.format("%.1f",nav.distance) or "--").." / V "..
        (finite(nav.speed) and string.format("%.1f",nav.speed) or "--"))
    row(8,review and (review.cancel and "REVIEW: DISENGAGE AP" or "REVIEW: SEND TO") or "DESTINATION",colors.cyan)
    local shown=review and review.destination or form
    row(9,"X: "..text(shown.x));row(10,"Z: "..text(shown.z))
    row(11,"Altitude: "..text(shown.altitude));row(12,"Speed: "..text(shown.cruiseSpeed).." b/s")
    row(13,"Release digital anchor: "..((review and review.releaseAnchor or not review and releaseAnchor) and "YES" or "NO"))
    row(14,"Clear route required",colors.yellow)
    row(15,review and "G CONFIRM / B BACK" or "X/Z/H/S edit, D anchor",colors.cyan)
    row(16,review and "Q exits; route continues" or "Enter review / C disengage")
    -- Put the important result first and wrap it across the available notice area.
    local message=editor and (editor.label..": "..editor.buffer) or notice
    local last=height-1
    for y=17,last do row(y,message:sub((y-17)*width+1,(y-16)*width),colors.yellow) end
    row(height,editor and "Enter save / Esc cancel" or "R refresh / Q back",colors.gray)
end
poll();refresh=os.startTimer(2);draw()
while true do
    local event,a,b,c=os.pullEvent()
    if event=="rednet_message" and pending and a==cfg.coreID and c==cfg.protocol and type(b)=="table" and
        b.v==1 and b.coreID==cfg.coreID and b.requestID==pending.id and type(b.boot)=="string" then
        local kind=pending.action;os.cancelTimer(timer);pending=nil
        if not b.ok then
            online=false;notice=text(b.error)
            if notice:find("reconnect",1,true) then boot=nil end
        elseif kind=="hello" then online=true;boot=b.boot;poll()
        elseif b.boot~=boot then online=false;boot=nil;review=nil;notice="Core restarted; reconnecting"
        elseif kind=="ap_status" then
            online=true;nav=type(b.data)=="table" and b.data or {}
            if form.altitude==nil and finite(nav.selectedAltitude) then form.altitude=nav.selectedAltitude end
            if review and (nav.session~=review.session or nav.generation~=review.generation) then review=nil;notice="Authority changed; review again" end
            if not review and not command then notice=nav.apReason or nav.reason or "Ready for destination" end
        else
            online=true;local result=type(b.data)=="table" and b.data or {}
            notice=text(result.status)..": "..text(result.reason)
            if result.status~="PENDING" then command=nil end
        end
    elseif event=="timer" and a==timer and pending then
        pending=nil;boot=nil;online=false;review=nil
        notice=command and "UNKNOWN: querying command result" or "STALE: no reply from core"
    elseif event=="timer" and a==refresh then refresh=os.startTimer(2);poll()
    elseif editor then
        if event=="char" or event=="paste" then
            local value=tostring(a):gsub("[^%d%+%-%.eE]","")
            editor.buffer=(editor.buffer..value):sub(1,24)
        elseif event=="key" and a==keys.backspace then editor.buffer=editor.buffer:sub(1,-2)
        elseif event=="key" and a==keys.escape then editor=nil
        elseif event=="key" and a==keys.enter then
            local value=tonumber(editor.buffer)
            if finite(value) then form[editor.key]=value;editor=nil;review=nil;notice="Destination updated"
            else notice="Enter a valid number" end
        end
    elseif event=="key" and a==keys.enter then startReview(false)
    elseif event=="char" then
        if a=="q" then return
        elseif a=="r" then poll()
        elseif a=="b" then review=nil;notice="Review cancelled"
        elseif a=="g" then confirm()
        elseif a=="c" then startReview(true)
        elseif not review and not command then
            local field=({x="x",z="z",h="altitude",s="cruiseSpeed"})[a]
            if field then editor={key=field,label=({x="X",z="Z",altitude="Altitude",cruiseSpeed="Speed"})[field],buffer=""}
            elseif a=="d" then releaseAnchor=not releaseAnchor end
        end
    elseif event=="peripheral" then poll() end
    draw()
end
