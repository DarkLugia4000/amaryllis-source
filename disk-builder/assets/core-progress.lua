-- Draws installer progress from cached transfer state.
local Progress={}
Progress.__index=Progress
local titles={navigator="Bridge navigator",["heading-left"]="Left heading display",["heading-right"]="Right heading display",
    ["heading-main"]="Main heading display",chamber_fl="Front-left lift chamber",chamber_fr="Front-right lift chamber",
    chamber_bl="Rear-left lift chamber",chamber_br="Rear-right lift chamber",primary_l="Left primary controller",
    primary_r="Right primary controller",["thrust-lb"]="Front-left thrust",["thrust-rb"]="Front-right thrust",
    ["thrust-ls"]="Rear-left thrust",["thrust-rs"]="Rear-right thrust"}
local labels={starting="Starting installer",waiting_for_modem="Opening wireless modem",
    no_modem="No wireless modem; retrying",waiting_for_client="Waiting for computers",
    offered="Waiting for computer to accept",transferring="Sending package files",
    committing="Verifying and committing package",installed="Package installed",
    current="Package is up to date",transfer_failed="Transfer failed; will retry",
    configuration_error="Installer configuration error",fleet_registry_error="Fleet registration error",
    rejected_hello="Computer identity rejected",bundle_error="Package could not be prepared",
    checking="Checking package files (paced)",paused="Installer paused; flight workers continue",
    waiting_for_media="Insert matching installer disk"}
local rowStates={checking="CHECK",offered="OFFER",transferring="SEND",committing="VERIFY",
    installed="DONE",current="DONE",transfer_failed="FAULT",bundle_error="FAULT"}
local function clean(value) return tostring(value or ""):gsub("[%c]"," ") end
local function finite(value) return type(value)=="number" and value==value and value~=math.huge and value~=-math.huge end
function Progress.new(screen,now)
    return setmetatable({screen=screen,now=now,rows={},order={},lastDraw=-math.huge},Progress)
end
-- Summary: Set the expected role inventory for installer progress.
function Progress:setFleet(fleet,roleFiles)
    local rows,order={},{}
    local computers=fleet and fleet.computers or {}
    local reader=computers.state
    self.stateReaderID=type(reader)=="table" and reader.id or nil
    for role in pairs(roleFiles) do
        local entry=type(computers[role])=="table" and computers[role] or {}
        local id=finite(entry.id) and entry.id>=0 and entry.id%1==0 and entry.id or nil
        local old=self.rows[role]
        rows[role]=old and old.id==id and old.label==entry.label and old or
            {id=id,label=entry.label,role=role,state=id and "WAIT" or "NO ID"}
        order[#order+1]=role
    end
    table.sort(order,function(a,b)
        local first,second=rows[a].id,rows[b].id
        if first==second then return a<b end
        if first==nil then return false elseif second==nil then return true end
        return first<second
    end)
    self.rows,self.order=rows,order
end
-- Summary: Update cached per-role installation progress from receiver status.
function Progress:update(status)
    if status.coreSession and self.coreSession and status.coreSession~=self.coreSession then
        for _,row in pairs(self.rows) do row.state=row.id and "WAIT" or "NO ID";row.reason=nil end
    end
    self.coreSession=status.coreSession or self.coreSession
    local row=self.rows[status.targetRole]
    if row and row.id~=nil and row.id==status.targetID then
        local state=rowStates[status.state]
        if state then row.state=state;row.reason=state=="FAULT" and clean(status.lastError) or nil end
        if (status.state=="paused" or status.state=="waiting_for_media") and row.state~="DONE" then row.state="WAIT";row.reason=nil end
    end
    if status.requestID~=self.requestID then
        self.requestID=status.requestID;self.retryBase=status.retries or 0
    end
end
-- Summary: Build the terminal rows for the current installation progress.
function Progress:frame(status,width,height)
    local lines,tones={},{}
    local function line(y,text,tone) if y>=1 and y<=height then lines[y]=clean(text):sub(1,width);tones[y]=tone end end
    local installed,failed,missing,firstFault=0,0,0,nil
    for _,role in ipairs(self.order) do
        local row=self.rows[role]
        if row.state=="DONE" then installed=installed+1
        elseif row.state=="FAULT" then failed=failed+1;firstFault=firstFault or row
        elseif row.state=="NO ID" then missing=missing+1 end
    end
    line(1,"AMARYLLIS / PACKAGE INSTALLER","cyan")
    line(2,string.format("Verified %d/%d  Waiting %d  Faults %d",installed,#self.order,#self.order-installed-failed,failed))
    local current=self.rows[status.targetRole]
    line(3,current and current.id and string.format("#%d  %s",current.id,titles[current.role] or current.role) or "Waiting for assigned computers")
    local state=labels[status.state] or clean(status.state):gsub("_"," ")
    local fault=status.state=="transfer_failed" or status.state=="bundle_error" or status.state=="configuration_error" or
        status.state=="fleet_registry_error" or status.state=="rejected_hello"
    line(4,state,fault and "red" or (status.state=="installed" or status.state=="current") and "lime" or "yellow")
    local active=status.state=="transferring" or status.state=="committing" or status.state=="offered"
    local complete=#self.order>0 and installed==#self.order and not active and not fault and
        status.state~="checking" and status.state~="paused" and status.state~="no_modem" and status.state~="waiting_for_modem" and status.state~="waiting_for_media"
    if complete then line(4,"ALL "..installed.." PACKAGES VERIFIED","lime") end
    local total=finite(status.bytesTotal) and math.max(0,status.bytesTotal) or 0
    local sent=active and finite(status.bytesSent) and math.max(0,math.min(total,status.bytesSent)) or 0
    if status.state=="installed" or status.state=="current" then sent=total end
    local fraction=total>0 and sent/total or 0
    local file=clean(status.currentPath):match("([^/]+)$") or ""
    if active then
        line(5,string.format("File %d/%d%s",status.fileIndex or 0,status.filesTotal or 0,file~="" and (": "..file) or ""))
        local bar=math.max(1,width-9);local filled=math.floor(bar*fraction)
        line(6,"["..string.rep("#",filled)..string.rep(".",bar-filled).."] "..string.format("%3d%%",math.floor(fraction*100)),"cyan")
        line(7,string.format("%.1f / %.1f KiB   Retries %d",sent/1024,total/1024,math.max(0,(status.retries or 0)-(self.retryBase or 0))))
    end
    line(8,fault and clean(status.lastError) or "DONE = verified package; hardware checked separately",fault and "red" or "lightGray")
    if not fault and firstFault then line(8,"#"..firstFault.id..": "..clean(firstFault.reason),"red") end
    if not fault and missing>0 then line(8,missing.." roles need IDs: import disk assignments on core","yellow") end
    if complete then line(8,"Package setup complete. Verify hardware before flight.","lime") end
    if status.state=="paused" then line(8,"Paused by /installer/paused; remove file to resume","yellow") end
    if status.state=="waiting_for_media" then line(8,"Flight continues. "..clean(status.lastError),"yellow") end
    if status.state=="checking" then line(5,"Initial/changed files; controls keep their turn","lightGray") end
    local cols=width>=46 and 2 or 1
    local count=math.max(0,height-10);local capacity=count*cols
    local start=1
    if capacity>0 and #self.order>capacity then
        start=(math.floor(self.now()/8)%math.ceil(#self.order/capacity))*capacity+1
    end
    local cells={}
    for i=start,math.min(#self.order,start+capacity-1) do
        local n=i-start;local col=math.floor(n/math.max(1,count));local y=10+(n%math.max(1,count))
        local row=self.rows[self.order[i]];local cellWidth=math.floor(width/cols)
        local stateWidth=6;local prefix=((row.id and ("#"..row.id) or "#?").." "..row.role):sub(1,math.max(1,cellWidth-stateWidth-1))
        cells[#cells+1]={x=col*cellWidth+1,y=y,label=prefix,state=row.state,width=cellWidth,
            tone=row.state=="DONE" and "lime" or row.state=="FAULT" and "red" or row.state=="WAIT" and "lightGray" or "yellow"}
    end
    line(9,"COMPUTERS","cyan")
    if self.stateReaderID~=nil then
        line(height,"State #"..self.stateReaderID..": direct disk setup; verify wired link","lightGray")
    else line(height,"State reader: register from disk; verify wired link","yellow") end
    if #self.order>capacity and capacity>0 then
        line(9,"COMPUTERS / PAGE "..math.ceil(start/capacity).." (rotates every 8s)","cyan")
    end
    return {lines=lines,tones=tones,cells=cells,installed=installed,total=#self.order,failed=failed,missing=missing,complete=complete}
end
-- Summary: Render cached installation progress on the installer terminal.
function Progress:draw(status,force)
    local now=self.now()
    -- Configuration can fail before the first yielding loop. Leave the initial
    -- frame budget available for its actionable error rather than a 0/0 flash.
    if not force and status.state=="starting" then return end
    if not force and now-self.lastDraw<0.5 then return end
    local screen=self.screen;local width,height=screen.getSize()
    local frame=self:frame(status,width,height)
    -- Bounded cached presentation data for Panel Home. No UI-side package scans.
    if not self.lastPanelCacheAt or now-self.lastPanelCacheAt>=0.5 then
        local cached={status={},rows={},order={}}
        for key,value in pairs(status)do if type(value)~="table"and type(value)~="function"then cached.status[key]=value end end
        for _,role in ipairs(self.order)do
            cached.order[#cached.order+1]=role;cached.rows[role]={}
            for key,value in pairs(self.rows[role])do if type(value)~="table"and type(value)~="function"then cached.rows[role][key]=value end end
        end
        os.__amaryllisInstallerProgress=cached;self.lastPanelCacheAt=now
    end
    local parts={tostring(width),tostring(height)}
    for y=1,height do parts[#parts+1]=(frame.lines[y] or "")..":"..(frame.tones[y] or "") end
    for _,cell in ipairs(frame.cells) do parts[#parts+1]=cell.label..cell.state..cell.tone end
    local signature=table.concat(parts,"|")
    if not force and signature==self.signature then return end
    self.lastDraw,self.signature=now,signature
    local palette={white=1,lime=32,yellow=16,red=16384,cyan=512,lightGray=256,black=32768}
    if screen.setBackgroundColor then screen.setBackgroundColor(palette.black) end
    for y=1,height do
        screen.setCursorPos(1,y)
        if screen.setTextColor then screen.setTextColor(palette[frame.tones[y] or "white"]) end
        screen.write(string.rep(" ",width));screen.setCursorPos(1,y);screen.write(frame.lines[y] or "")
    end
    for _,cell in ipairs(frame.cells) do
        screen.setCursorPos(cell.x,cell.y)
        if screen.setTextColor then screen.setTextColor(palette.white) end
        screen.write(cell.label)
        screen.setCursorPos(cell.x+cell.width-#cell.state,cell.y)
        if screen.setTextColor then screen.setTextColor(palette[cell.tone]) end
        screen.write(cell.state)
    end
    if screen.setTextColor then screen.setTextColor(palette.white) end
    screen.setCursorPos(1,height)
end
return Progress
