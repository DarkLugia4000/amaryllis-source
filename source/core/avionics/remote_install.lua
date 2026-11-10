-- Section: Remote provisioning | Docked installation, pairing and flight permission.
-- User-triggered provisioning of a docked computer. Never installs on disk events.
local Remote = {}
local Storage = require("avionics.storage")
local REGISTRY = "/avionics/data/remotes.json"
local CLIENT = "/avionics/remote_client.lua"
local OPS_CLIENT = "/avionics/remote_ap_client.lua"
local CONFIG = "amaryllis-remote.json"
local BACKUP = "/remote/original-startup.lua"
local PROTOCOL = "amaryllis.remote.v1"
local BUILD = "amaryllis-remote-panel-v1"
local PAGES = {OVERVIEW=true,FLEET=true,LIFT=true,PROPULSION=true,NAVIGATION=true,LOGS=true}
local function clean(s) return tostring(s or ""):gsub("[%c]"," ") end
local function integer(n) return type(n)=="number" and n>=0 and n<2147483647 and n%1==0 end
local function read(path)
    local h,issue=fs.open(path,"r");assert(h,issue or ("Cannot read "..path))
    local ok,data=pcall(h.readAll);pcall(h.close);assert(ok,data);return data
end
local function json(path)
    if not fs.exists(path) then return nil end
    assert(not fs.isDir(path) and fs.getSize(path)<=131072,"Invalid or oversized JSON: "..path)
    local value=textutils.unserializeJSON(read(path));assert(type(value)=="table","Invalid JSON: "..path)
    return value
end
-- Summary: Write and close the selected file, then verify its stored bytes.
local function write(path,data)
    fs.makeDir(fs.getDir(path));local h,issue=fs.open(path,"w");assert(h,issue or ("Cannot write "..path))
    local ok,why=pcall(h.write,data);local closed,err=pcall(h.close)
    assert(ok,why);assert(closed,err);assert(read(path)==data,"Write verification failed: "..path)
end
-- Section: Remote provisioning | Docked installation, pairing and flight permission.
-- Summary: Replace a verified file through a temporary sibling and retain its backup.
local function atomic(path,data)
    local tmp=path..".remote-tmp";local bak=path..".remote-bak"
    assert(not fs.exists(tmp),"Unfinished write exists: "..tmp)
    write(tmp,data)
    if fs.exists(path) then
        if fs.exists(bak) then fs.delete(bak) end
        fs.move(path,bak)
    end
    local ok,issue=pcall(fs.move,tmp,path)
    if not ok then
        if fs.exists(bak) and not fs.exists(path) then pcall(fs.move,bak,path) end
        error(issue,0)
    end
    assert(read(path)==data,"Committed file failed verification: "..path)
end
-- Summary: Load the current trusted fleet and remote-pairing registry.
local function registry()
    local value,reason,status=Storage.readJson(REGISTRY)
    if not value then
        assert(status=="missing",reason)
        return {schemaVersion=1,coreID=os.getComputerID(),remotes={}}
    end
    assert(value.schemaVersion==1 and value.coreID==os.getComputerID() and type(value.remotes)=="table",
        "Remote registry belongs to another core or has an unsupported format")
    local count=0
    for id,item in pairs(value.remotes) do
        count=count+1
        assert(count<=32 and type(id)=="string" and #id<80 and type(item)=="table" and
            type(item.token)=="string" and #item.token==64 and (item.remoteID==nil or integer(item.remoteID)) and
            (item.flightAllowed==nil or type(item.flightAllowed)=="boolean"),
            "Remote registry contains an invalid pairing")
    end
    return value
end
-- Summary: Atomically persist the paired-remote registry.
local function save(value) assert(Storage.writeJson(REGISTRY,value)) end
local function permissions(value)
    local result={}
    for pair,item in pairs(value.remotes) do result[pair]=item.flightAllowed==true end
    os.__amaryllisRemotePermissions=result
end
-- Summary: Persist the accepted flight permission for a paired remote.
function Remote.setFlightAccess(pair,allowed)
    assert(not os.__amaryllisRemoteInstallLock,"Another remote operation is busy")
    local value=registry();assert(value.remotes[pair],"Unknown remote")
    value.remotes[pair].flightAllowed=allowed==true
    os.__amaryllisRemoteInstallLock=true
    local ok,issue=pcall(save,value)
    os.__amaryllisRemoteInstallLock=nil
    assert(ok,issue);permissions(value);os.queueEvent("amaryllis_remotes_changed")
end
local function randomToken()
    local result={};for i=1,8 do result[i]=string.format("%08x",math.random(0,2147483647)) end
    return table.concat(result)
end
local function checksum(data)
    local a,b=1,0
    for i=1,#data do a=(a+data:byte(i))%65521;b=(b+a)%65521 end
    return string.format("%08x",b*65536+a)
end
local STARTUP="-- AMARYLLIS REMOTE STARTUP\nshell.run(\"/remote/start.lua\")\n"
local LAUNCHER=[=[-- Stable launcher: a failed update retains the previous active application.
local h=assert(fs.open("/remote/active.json","r"),"Remote installation is incomplete")
local active=textutils.unserializeJSON(h.readAll());h.close()
assert(type(active)=="table" and type(active.version)=="string" and active.version:match("^[%w%-]+$"),"Invalid remote application")
shell.run("/remote/releases/"..active.version.."/main.lua")
]=]

-- Summary: Inspect the docked computer and its compatible remote installation.
function Remote.inspect(name)
    assert(peripheral.hasType(name,"drive"),"Selected peripheral is not a disk drive")
    local drive=assert(peripheral.wrap(name),"Drive disconnected")
    assert(drive.isDiskPresent() and drive.hasData(),"Insert a pocket computer into this drive")
    -- getDiskID identifies floppies, not the computer ID of mounted computers.
    assert(drive.getDiskID()==nil,"Floppy disks cannot be provisioned as remotes")
    local mount=drive.getMountPath();assert(type(mount)=="string" and mount~="","Computer storage is not mounted yet")
    mount="/"..mount:gsub("^/+","")
    assert(not fs.isReadOnly(mount),"Mounted computer storage is read-only")
    for _,path in ipairs({"release.json","setup.lua","deployment.json","avionics","installer.lua"}) do
        assert(not fs.exists(fs.combine(mount,path)),"Installer media or an onboard controller cannot be provisioned as a remote")
    end
    local cfg=json(fs.combine(mount,CONFIG))
    if cfg then
        assert(cfg.schemaVersion==1 and cfg.coreID==os.getComputerID() and type(cfg.pairID)=="string",
            "This remote is paired elsewhere; its pairing must be removed deliberately before replacement")
    else
        for _,path in ipairs({"remote/start.lua","remote/active.json"}) do
            assert(not fs.exists(fs.combine(mount,path)),"An unrelated remote installation already uses "..path)
        end
    end
    local startup=fs.combine(mount,"startup.lua")
    local previous=fs.exists(startup) and read(startup) or nil
    return {drive=name,mount=mount,label=clean(drive.getDiskLabel() or "Unlabelled computer"),
        config=cfg,startup=previous,admin=fs.exists(fs.combine(mount,"admin.lua"))}
end

function Remote.drives()
    local names={}
    for _,name in ipairs(peripheral.getNames()) do if peripheral.hasType(name,"drive") then names[#names+1]=name end end
    table.sort(names);return names
end

-- Summary: Provision the docked remote program and its pairing configuration.
function Remote.install(review)
    assert(type(review)=="table","Installation review is required")
    assert(not os.__amaryllisRemoteInstallLock,"Another remote operation is busy; try again")
    local current=Remote.inspect(review.drive)
    assert(current.mount==review.mount and current.label==review.label and current.startup==review.startup and
        textutils.serializeJSON(current.config or {})==textutils.serializeJSON(review.config or {}),
        "Dock contents changed since review; inspect the computer again")
    local app=read(CLIENT);local ops=read(OPS_CLIENT)
    assert(#app+#ops<65536,"Remote application is oversized")
    assert(load(app,"@remote-client","t",_ENV),"Remote application does not compile")
    assert(load(ops,"@remote-ap-client","t",_ENV),"Remote AP application does not compile")
    local free=fs.getFreeSpace(current.mount)
    assert(free=="unlimited" or (type(free)=="number" and free>(#app+#ops)*2+#(current.startup or "")+16384),
        "Insufficient free space on the docked computer")
    local records=registry();local pairID=current.config and current.config.pairID
    if pairID then
        local prior=records.remotes[pairID]
        assert(prior and prior.token==current.config.token,"Pairing is absent from this core; repair the registry before updating")
    else
        local count=0;for _ in pairs(records.remotes) do count=count+1 end
        assert(count<32,"This core already has 32 paired remotes")
        repeat pairID=string.format("remote-%08x-%08x",math.random(0,2147483647),math.random(0,2147483647)) until not records.remotes[pairID]
    end
    local version=BUILD.."-"..checksum(app..ops)
    local token=current.config and current.config.token or randomToken()
    local sentinel=fs.combine(current.mount,"remote/installing.json")
    local nonce=randomToken()
    local originalRegistry=registry()
    local registrySaved=false
    local originals={}
    for _,path in ipairs({"/"..CONFIG,"/remote/active.json","/remote/start.lua","/startup.lua"}) do
        local target=fs.combine(current.mount,(path:gsub("^/","")))
        originals[target]=fs.exists(target) and read(target) or false
    end
    os.__amaryllisRemoteInstallLock=true
    local ok,result=pcall(function()
        assert(not fs.exists(sentinel),"Unfinished installation detected; inspect remote/installing.json before retrying")
        write(sentinel,nonce)
        local function docked()
            local drive=assert(peripheral.wrap(current.drive),"Drive disconnected during installation")
            assert(drive.getMountPath() and "/"..drive.getMountPath():gsub("^/+","")==current.mount and
                fs.exists(sentinel) and read(sentinel)==nonce,"Docked computer changed or was removed; installation stopped")
        end
        local function put(path,data)
            docked();atomic(fs.combine(current.mount,(path:gsub("^/",""))),data);docked()
        end
        if current.startup and current.startup~=STARTUP then
            local backup=fs.combine(current.mount,(BACKUP:gsub("^/","")))
            assert(not fs.exists(backup) or read(backup)==current.startup,
                "Original startup backup already exists; inspect it before replacing another startup")
            if not fs.exists(backup) then put(BACKUP,current.startup) end
        end
        local release="/remote/releases/"..version.."/main.lua"
        local application=fs.combine(current.mount,release:sub(2))
        if fs.exists(application) then assert(read(application)==app,"Existing release contents do not match their version")
        else put(release,app) end
        local opsPath="/remote/releases/"..version.."/ops.lua"
        local opsApplication=fs.combine(current.mount,opsPath:sub(2))
        if fs.exists(opsApplication) then assert(read(opsApplication)==ops,"Existing AP application does not match its version")
        else put(opsPath,ops) end
        local config={schemaVersion=1,coreID=os.getComputerID(),pairID=pairID,token=token,
            protocol=PROTOCOL,build=BUILD}
        records.remotes[pairID]=records.remotes[pairID] or {token=token,createdAt=os.epoch("utc")}
        records.remotes[pairID].label=current.label
        records.remotes[pairID].build=BUILD
        save(records);registrySaved=true;docked()
        put("/"..CONFIG,textutils.serializeJSON(config))
        put("/remote/start.lua",LAUNCHER)
        put("/remote/active.json",textutils.serializeJSON({schemaVersion=1,version=version}))
        -- Startup is the final activation step. All prior user files remain available.
        put("/startup.lua",STARTUP)
        fs.delete(sentinel)
        os.queueEvent("amaryllis_remotes_changed")
        return {pairID=pairID,build=BUILD,remoteID=records.remotes[pairID].remoteID,admin=current.admin}
    end)
    if not ok then
        -- Restore pointers only while the same marked medium is still present.
        local present,same=pcall(function() return fs.exists(sentinel) and read(sentinel)==nonce end)
        if present and same then
            for path,data in pairs(originals) do pcall(function()
                if data==false then if fs.exists(path) then fs.delete(path) end else write(path,data) end
            end) end
            pcall(fs.delete,sentinel)
        end
        -- Failed installs must not replace or discard an existing pairing registry.
        pcall(function()
            if registrySaved then save(originalRegistry) end
        end)
    end
    os.__amaryllisRemoteInstallLock=nil
    assert(ok,result)
    permissions(records)
    return result
end

local function display(title,lines)
    term.setBackgroundColor(colors.black);term.setTextColor(colors.white);term.clear();term.setCursorPos(1,1)
    local width,height=term.getSize()
    term.setTextColor(colors.cyan);term.write(clean(title):sub(1,width));term.setTextColor(colors.white)
    for i,line in ipairs(lines) do if i+2<height then term.setCursorPos(1,i+2);term.write(clean(line):sub(1,width)) end end
    term.setCursorPos(1,height)
end
-- Summary: Run the remote provisioning and pairing-management interface.
function Remote.run()
    while true do
        local names=Remote.drives();local lines={"Insert a pocket into a drive visible to core.","Inserting it never starts installation.",""}
        for i,name in ipairs(names) do lines[#lines+1]=i.."  "..name end
        lines[#lines+1]="";lines[#lines+1]="Type drive number, R refresh, or Q back."
        display("AMARYLLIS / INSTALL REMOTE",lines)
        local choice=_G.read()
        if choice and choice:lower()=="q" then return end
        local index=tonumber(choice)
        if index and names[index] then
            local ok,review=pcall(Remote.inspect,names[index])
            if ok then
                display("REVIEW REMOTE INSTALL",{review.label,"Drive: "..review.drive,
                    "Mount: "..review.mount,"Installs status, REMOTE AP and pairing.",
                    review.startup and "Existing startup is preserved." or "Creates a startup program.",
                    review.admin and "Existing admin tools remain accessible." or "Other files are left in place.",
                    "Flight access needs separate onboard approval.","","Type INSTALL to confirm, or Enter to cancel."})
                if _G.read()=="INSTALL" then
                    local installed,result=pcall(Remote.install,review)
                    display(installed and "REMOTE INSTALLED" or "INSTALL FAILED",{installed and
                        "Remove the pocket, then turn it on." or clean(result),
                        installed and "Attach a wireless modem upgrade to connect." or "Existing startup/pairing preserved where possible.",
                        "","Press any key to return."})
                    os.pullEvent("key")
                end
            else
                display("REMOTE NOT AVAILABLE",{clean(review),"","Press any key to return."});os.pullEvent("key")
            end
        end
    end
end

-- Summary: Run the docked remote administration menu.
function Remote.opsMenu()
    local offset=0
    while true do
        local records=registry();local entries={}
        for pair,item in pairs(records.remotes) do entries[#entries+1]={pair=pair,item=item} end
        table.sort(entries,function(a,b) return a.pair<b.pair end)
        local bridge=os.__amaryllisRemoteAP
        local state=bridge and bridge.status() or {}
        local lines={"REMOTE AP: "..(state.enabled and "ENABLED" or "DISABLED"),
            "E enable for this boot / D disable", "Select a remote to allow/revoke flight:"}
        for i=offset+1,math.min(offset+8,#entries) do
            local item=entries[i].item
            lines[#lines+1]=i.."  #"..tostring(item.remoteID or "unbound").." "..
                clean(item.label):sub(1,18).." / "..(item.flightAllowed and "ALLOW" or "DENY")
        end
        lines[#lines+1]="N next / P previous / Q back"
        lines[#lines+1]=bridge and "Pilot override disables remote AP." or "Load the updated core runtime first."
        display("AMARYLLIS / REMOTE FLIGHT ACCESS",lines)
        local answer=_G.read():lower()
        if answer=="q" then return
        elseif answer=="n" then offset=(offset+8<#entries) and offset+8 or 0
        elseif answer=="p" then offset=math.max(0,offset-8)
        elseif (answer=="e" or answer=="d") and bridge then
            local ok,why=bridge.enable(answer=="e")
            display(ok and "REMOTE AP ACCESS UPDATED" or "ACCESS CHANGE REJECTED",{why,"","Press any key."});os.pullEvent("key")
        else
            local index=tonumber(answer);local selected=index and entries[index]
            if selected then
                local allowing=selected.item.flightAllowed~=true
                local word=allowing and "ALLOW" or "REVOKE"
                display("CONFIRM REMOTE FLIGHT ACCESS",{"Remote #"..tostring(selected.item.remoteID or "unbound"),
                    clean(selected.item.label),"Type "..word.." to confirm, or Enter to cancel."})
                if _G.read()==word then
                    local ok,why=pcall(Remote.setFlightAccess,selected.pair,allowing)
                    if not ok then display("ACCESS CHANGE FAILED",{clean(why),"Press any key."});os.pullEvent("key") end
                end
            end
        end
    end
end

-- Request-driven radio service. Flight requests only enter core's supervisor queue.
-- Summary: Request-driven radio service. Flight requests only enter core's supervisor queue.
function Remote.serve(status,flightRequest)
    local records=registry();permissions(records)
    -- Summary: Find and open the network modems used by the current client.
    local function modems()
        for _,name in ipairs(peripheral.getNames()) do
            if peripheral.hasType(name,"modem") then
                local modem=peripheral.wrap(name)
                local ok,wireless=pcall(modem.isWireless)
                if ok and wireless then pcall(rednet.open,name) end
            end
        end
    end
    modems()
    local boot=randomToken();local last={}
    while true do
        local event,sender,p,protocol=os.pullEventRaw()
        if event=="amaryllis_remotes_changed" then records=registry();permissions(records);last={}
        elseif event=="peripheral" then modems()
        elseif event=="rednet_message" and protocol==PROTOCOL and integer(sender) and type(p)=="table" and
            p.v==1 and type(p.pairID)=="string" and #p.pairID<80 and type(p.requestID)=="string" and #p.requestID<=100 and
            type(p.sentAt)=="number" and math.abs(os.epoch("utc")-p.sentAt)<15000 and not os.__amaryllisRemoteInstallLock then
            local item=records.remotes[p.pairID]
            if item and type(item.token)=="string" and p.token==item.token and (item.remoteID==nil or item.remoteID==sender) then
                local reply={v=1,requestID=p.requestID,boot=boot,coreID=os.getComputerID(),ok=false}
                local allowed=true
                if p.action=="hello" then
                    if item.remoteID==nil then
                        -- Reload before binding so a simultaneous completed install is never lost.
                        local latest=registry();local record=latest.remotes[p.pairID]
                        if record and record.token==p.token and (record.remoteID==nil or record.remoteID==sender) then
                            record.remoteID=sender
                            local saved=pcall(save,latest)
                            if saved then records=latest else allowed=false;reply.error="Cannot save remote identity" end
                        else allowed=false;reply.error="Pairing changed; dock the remote again" end
                    end
                    if allowed then reply.ok=true;reply.data={label=os.getComputerLabel(),build=BUILD} end
                elseif p.boot~=boot then reply.error="Core restarted; reconnect"
                elseif p.action=="status" and PAGES[p.page] then
                    -- Cached remote reads: no read queue and no hardware probes.
                    local at=os.clock();local pages=last[p.pairID]or{};last[p.pairID]=pages
                    local prior=pages[p.page]
                    if prior and at>=prior.at and at-prior.at<.5 then
                        reply.ok=true;reply.data=prior.data;reply.cachedAgeSeconds=at-prior.at
                    else
                        local ok,data=pcall(status,p.page)
                        reply.ok=ok;reply.data=ok and data or nil;reply.error=not ok and "Core status unavailable" or nil
                        if ok then pages[p.page]={at=at,data=data}end
                    end
                elseif flightRequest and (p.action=="ap_status" or p.action=="ap_send" or p.action=="ap_cancel" or p.action=="ap_result") then
                    local ok,data=pcall(flightRequest,sender,p.pairID,p)
                    reply.ok=ok;reply.data=ok and data or nil;reply.error=not ok and "Remote AP service unavailable" or nil
                else reply.error="Unsupported remote action" end
                rednet.send(sender,reply,PROTOCOL)
            end
        end
    end
end

Remote.protocol=PROTOCOL
return Remote
