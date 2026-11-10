-- Section: Web setup | Core install and registration over rednet from a pinned web release.
-- Amaryllis web setup. The Pastebin loader runs this with the address of a
-- pinned web release (the Disk Builder's media folder, built by GitHub Actions).
--   Core: downloads and installs its own programs, then keeps the deployment
--   record and registers the other computers over rednet until every role is
--   assigned; importing the assignments starts core, which then serves role
--   packages from the same web release.
--   Every other computer: finds core over rednet, takes core's release, lets
--   you pick its role, registers with core, then installs its payload.
local base=...
local PROTOCOL="amaryllis.setup.v1"
local CORE_MEDIA="/installer/web"
local NODE_MEDIA="/amaryllis-web"
local INDEX="download.json"
local RELEASE_FILES={"release.json","library.json","setup.lua","web-setup.lua"}
-- Until import, core boots into this registration screen; its own startup is kept here.
local CORE_STARTUP=CORE_MEDIA.."/core-startup.lua"
-- Reset installation runs after a reboot into the registration screen, with core's runtime stopped.
local RESET_MARKER=CORE_MEDIA.."/reset-pending.json"
local REGISTRATION_STARTUP='assert(loadfile("/installer/web/web-setup.lua",nil,_ENV))()\n'
local WHITE,GRAY,CYAN,YELLOW,RED,GREEN=colors.white,colors.gray,colors.cyan,colors.yellow,colors.red,colors.lime

-- Section: Web setup | Core install and registration over rednet from a pinned web release.
-- Summary: Compute the Adler-32 checksum, yielding on large files.
local function adler(data)
    local a,b=1,0
    for i=1,#data do
        a=(a+data:byte(i))%65521;b=(b+a)%65521
        if i%65536==0 then os.queueEvent("amaryllis_yield");os.pullEvent("amaryllis_yield") end
    end
    return string.format("%04X%04X",b,a)
end

-- Download one file as raw bytes, three attempts, refusing anything but HTTP 200.
-- Summary: Download one file as raw bytes, three attempts, refusing anything but HTTP 200.
local function fetch(url)
    local last
    for attempt=1,3 do
        local response,why,failed=http.get({url=url,binary=true})
        if response then
            local code=response.getResponseCode();local data=response.readAll() or "";response.close()
            if code==200 then return data end
            last="HTTP "..tostring(code)
        else
            last=tostring(why);if failed then pcall(failed.close) end
        end
        if attempt<3 then sleep(attempt) end
    end
    error("Download failed: "..url.." ("..tostring(last)..")",0)
end
local function writeFile(path,data)
    local dir=fs.getDir(path);if dir~="" and not fs.exists(dir) then fs.makeDir(dir) end
    local h=assert(fs.open(path,"wb"),"Cannot write "..path);h.write(data);h.close()
end
local function readFile(path)
    local h=fs.open(path,"rb");if not h then return nil end
    local data=h.readAll() or "";h.close();return data
end
local function validBase(text)
    return type(text)=="string" and text:match("^https://[%w%.%-]+/[%w%.%-_/]+/$")~=nil
end

-- Fetch the release index and the release files into dir, each checked against the index.
-- Summary: Fetch the release index and the release files into dir, each checked against the index.
local function loadRelease(releaseBase,dir)
    local index=textutils.unserializeJSON(fetch(releaseBase..INDEX))
    assert(type(index)=="table" and index.schemaVersion==1 and type(index.files)=="table","Release index unavailable")
    local entries={};for _,f in ipairs(index.files) do entries[f.path]=f end
    for _,name in ipairs(RELEASE_FILES) do
        local entry=assert(entries[name],"Release index lacks "..name)
        local data=fetch(releaseBase..name)
        assert(#data==entry.bytes and adler(data)==entry.adler32,"Checksum mismatch for "..name)
        writeFile(fs.combine(dir,name),data)
    end
    local Setup=assert(loadfile(fs.combine(dir,"setup.lua"),nil,_ENV))()
    -- Package objects come from the web release; the payload check in setup.lua
    -- verifies each one against release.json.
    local cache={}
    Setup.readObject=function(_,object)
        cache[object]=cache[object] or fetch(releaseBase.."objects/"..object)
        return cache[object]
    end
    return Setup,Setup.load(dir),index.releaseId
end

local function openModems()
    local any=false
    for _,name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name)=="modem" then rednet.open(name);any=true end
    end
    return any
end
local function line(y,text,color)
    local w=term.getSize();term.setCursorPos(1,y);term.clearLine()
    term.setTextColor(color or WHITE);term.write(tostring(text):sub(1,w))
end
local function screen(title)
    term.setBackgroundColor(colors.black);term.clear()
    line(1,title,CYAN)
end
-- Letter and digit commands read "char" events, which carry the typed character.
-- "key" events carry the physical key position named after the US layout, so on
-- a QWERTZ keyboard the key marked Y arrives as keys.z.
local function confirm(prompt)
    local _,h=term.getSize();line(h,prompt.." (y/n)",YELLOW)
    while true do
        local _,ch=os.pullEvent("char");ch=ch:lower()
        if ch=="y" then return true elseif ch=="n" then return false end
    end
end
local function message(title,lines,color)
    screen(title)
    for i,text in ipairs(lines) do line(2+i,text,color) end
    local _,h=term.getSize();line(h,"Press any key",GRAY);os.pullEvent("key")
end
-- Boot core into the registration screen; its own startup waits in CORE_STARTUP.
local function bootIntoRegistration()
    if not fs.exists(CORE_STARTUP) then
        fs.move("/startup.lua",CORE_STARTUP);writeFile("/startup.lua",REGISTRATION_STARTUP)
    end
end
-- Remove every Amaryllis file from core: programs, records and learned data.
-- Summary: Remove every Amaryllis file from core: programs, records and learned data.
local function uninstallCore()
    for _,path in ipairs({"/startup.lua","/avionics","/installer","/fleet.json","/amaryllis-install.json"}) do
        if fs.exists(path) then fs.delete(path) end
    end
    for _,name in ipairs(fs.list("/")) do
        if name:match("%.amaryllis%-tmp$") or name:match("%.amaryllis%-backup$") then fs.delete("/"..name) end
    end
    os.setComputerLabel(nil)
end
local function roleOrder(release)
    local order={"core"};for _,role in ipairs(release.roleOrder) do order[#order+1]=role end
    return order
end

-- Core's registration screen: answers discovery, records registrations and
-- imports the assignments once every role is held.
-- Summary: Core's registration screen: answers discovery, records registrations and imports the assignments once every role is held.
local function coreScreen(Setup,release,id,releaseBase)
    assert(openModems(),"Attach a modem to core: the other computers register over rednet")
    local order=roleOrder(release);local selected=1;local notice=""
    while true do
        local state=Setup.deployment(CORE_MEDIA,release)
        local count=0;for _ in pairs(state.computers) do count=count+1 end
        local complete=count==#order
        screen("AMARYLLIS WEB SETUP | CORE #"..id)
        line(2,count.."/"..#order.." registered. Run the loader on each computer.",complete and GREEN or WHITE)
        local _,h=term.getSize();local rows=h-6
        local first=math.max(1,math.min(selected-math.floor(rows/2),#order-rows+1))
        for i=first,math.min(#order,first+rows-1) do
            local role=order[i];local entry=state.computers[role]
            line(3+i-first,(i==selected and "> " or "  ")..(entry and ("#"..entry.id) or "--").."  "..Setup.title(role),
                entry and WHITE or GRAY)
        end
        line(h-2,notice,YELLOW)
        line(h-1,complete and "Enter: import assignments and start core" or "Waiting for registrations",complete and GREEN or GRAY)
        line(h,"Up/Dn Bksp:clear R:reset U:uninstall Q:leave",GRAY)
        local event,a,b,c=os.pullEvent()
        if event=="rednet_message" and c==PROTOCOL and type(b)=="table" and b.v==1 then
            if b.kind=="discover" then
                rednet.send(a,{v=1,kind="core",coreID=id,releaseId=release.releaseId,base=releaseBase,
                    computers=state.computers,reset=state.reset},PROTOCOL)
            elseif b.kind=="register" and b.releaseId==release.releaseId and type(b.role)=="string" then
                local ok,issue=pcall(Setup.registerRole,CORE_MEDIA,release,b.role,a,b.move==true)
                rednet.send(a,{v=1,kind="registered",ok=ok,error=not ok and tostring(issue) or nil,role=b.role,coreID=id},PROTOCOL)
                notice=ok and ("#"..a.." registered as "..b.role) or ("#"..a.." refused: "..tostring(issue))
            elseif b.kind=="unregister" and type(b.role)=="string" then
                local holder=state.computers[b.role]
                if holder and holder.id==a and b.role~="core" and pcall(Setup.clearRole,CORE_MEDIA,release,b.role) then
                    notice="#"..a.." removed its registration as "..b.role
                end
            end
        elseif event=="char" and a:lower()=="q" then return
        elseif event=="char" and a:lower()=="r" then
            if confirm("Reset installation? Every role registers again") then
                writeFile(RESET_MARKER,"{}");bootIntoRegistration()
                message("Resetting installation",{"Core restarts into registration and clears","every assignment. Programs and settings stay."},YELLOW)
                os.reboot()
            end
        elseif event=="char" and a:lower()=="u" then
            if state.imported==true then notice="Reset installation (R) before uninstalling core"
            elseif confirm("Uninstall core from #"..id.."? Its files are deleted") then
                uninstallCore()
                return message("Core uninstalled",{"Remove the registration on every computer that","registered with this core, then install core again."},YELLOW)
            end
        elseif event=="key" then
            if a==keys.up then selected=math.max(1,selected-1)
            elseif a==keys.down then selected=math.min(#order,selected+1)
            elseif a==keys.backspace and order[selected]~="core" and state.computers[order[selected]] then
                local role=order[selected]
                if confirm("Clear "..role.." (#"..state.computers[role].id..")?") then
                    local ok,issue=pcall(Setup.clearRole,CORE_MEDIA,release,role)
                    notice=ok and (role.." cleared; register that computer again") or tostring(issue)
                end
            elseif a==keys.enter and complete then
                if confirm("Import assignments and start core?") then
                    local ok,issue=pcall(Setup.importFleet,CORE_MEDIA,release,id)
                    if ok and fs.exists(CORE_STARTUP) then
                        fs.delete("/startup.lua");fs.move(CORE_STARTUP,"/startup.lua")
                    end
                    if ok then
                        message("Assignments imported",{"Core restarts and installs each computer's","role package over wireless."},GREEN)
                        os.reboot()
                    end
                    notice=tostring(issue)
                end
            end
        end
    end
end

-- Summary: Download the release into core, install core and open its registration screen.
local function installCore(id)
    assert(validBase(base),"Run this through the Amaryllis loader")
    screen("AMARYLLIS WEB SETUP | CORE #"..id);line(3,"Downloading release...")
    local Setup,release,releaseId=loadRelease(base,CORE_MEDIA)
    writeFile(fs.combine(CORE_MEDIA,"source.json"),textutils.serializeJSON({base=base,releaseId=releaseId}))
    line(4,"Installing core "..releaseId.."...")
    Setup.installCore(CORE_MEDIA,release,id)
    bootIntoRegistration()
    return coreScreen(Setup,release,id,base)
end

-- Ask every reachable core to answer; returns their replies.
-- Summary: Ask every reachable core to answer; returns their replies.
local function discover()
    rednet.broadcast({v=1,kind="discover"},PROTOCOL)
    local found,deadline={},os.clock()+3
    while os.clock()<deadline do
        local sender,reply=rednet.receive(PROTOCOL,math.max(.1,deadline-os.clock()))
        if sender and type(reply)=="table" and reply.v==1 and reply.kind=="core" and reply.coreID==sender
            and validBase(reply.base) then found[#found+1]=reply end
    end
    return found
end
-- Summary: Let the operator choose this computer's role from core's current assignments.
local function pickRole(Setup,release,core,id)
    local order={};for _,role in ipairs(release.roleOrder) do order[#order+1]=role end
    local selected=1
    while true do
        screen("REGISTER #"..id.." WITH CORE #"..core.coreID)
        local _,h=term.getSize();local rows=h-4
        local first=math.max(1,math.min(selected-math.floor(rows/2),#order-rows+1))
        for i=first,math.min(#order,first+rows-1) do
            local role=order[i];local holder=core.computers[role]
            line(1+i-first+1,(i==selected and "> " or "  ")..(holder and ("#"..holder.id) or "--").."  "..Setup.title(role),
                holder and (holder.id==id and YELLOW or GRAY) or WHITE)
        end
        line(h,"Up/Down  Enter: register  Q: cancel",GRAY)
        local event,key=os.pullEvent()
        if event=="char" and key:lower()=="q" then return nil
        elseif event~="key" then
        elseif key==keys.up then selected=math.max(1,selected-1)
        elseif key==keys.down then selected=math.min(#order,selected+1)
        elseif key==keys.enter then
            local holder=core.computers[order[selected]]
            if holder and holder.id~=id then
                message("Role taken",{order[selected].." belongs to #"..holder.id..".","Clear it on core's screen first."},YELLOW)
            elseif confirm("Register as "..order[selected].."?") then return order[selected] end
        end
    end
end
-- Summary: Find core, take its release, register the chosen role and install its payload.
local function registerComputer(id)
    assert(openModems(),"Attach a modem: this computer registers with core over rednet")
    screen("AMARYLLIS WEB SETUP | #"..id);line(3,"Looking for core...")
    local cores=discover()
    if #cores==0 then
        return message("No core found",{"Install core first and leave it on its","registration screen, in modem range."},RED)
    end
    local core=cores[1]
    if #cores>1 then
        screen("Several cores answered")
        for i,c in ipairs(cores) do line(2+i,i..": core #"..c.coreID.."  "..c.releaseId) end
        local _,h=term.getSize();line(h,"Press the number",GRAY)
        repeat local _,ch=os.pullEvent("char");core=cores[tonumber(ch)] until core
    end
    line(4,"Downloading core #"..core.coreID.."'s release...")
    local Setup,release=loadRelease(core.base,NODE_MEDIA)
    local role=pickRole(Setup,release,core,id)
    if not role then fs.delete(NODE_MEDIA);return end
    local journal=readFile("/amaryllis-install.json");journal=journal and textutils.unserializeJSON(journal)
    local move=type(journal)=="table" and journal.pending==false and journal.releaseId==release.releaseId and journal.role~=role
    if move then
        local allowed,why=pcall(Setup.checkRoleChange,release,id,journal.role,role)
        if not allowed then fs.delete(NODE_MEDIA);return message("Role change refused",{tostring(why)},RED) end
    end
    local reply
    for _=1,3 do
        rednet.send(core.coreID,{v=1,kind="register",role=role,releaseId=release.releaseId,move=move},PROTOCOL)
        local sender,value=rednet.receive(PROTOCOL,5)
        if sender==core.coreID and type(value)=="table" and value.kind=="registered" and value.role==role then reply=value;break end
    end
    if not reply then fs.delete(NODE_MEDIA);return message("Core did not answer",{"Check core's registration screen and range."},RED) end
    if not reply.ok then fs.delete(NODE_MEDIA);return message("Core refused",{tostring(reply.error)},RED) end
    line(5,"Installing "..role.."...")
    -- Core's record lets a computer keep its programs after a reset of the same core.
    writeFile(fs.combine(NODE_MEDIA,"deployment.json"),textutils.serializeJSON({schemaVersion=1,
        releaseId=release.releaseId,computers=core.computers,assignmentRevision=0,reset=core.reset}))
    local result=Setup.installRegistered(NODE_MEDIA,release,role,id,core.coreID)
    fs.delete(NODE_MEDIA)
    message("Registered as "..role,{result=="changed" and "Role changed." or
        result=="retained" and "Existing programs and settings kept." or "Payload installed.",
        role=="state" and "Connect it to core with wired modems." or "It installs its package when core starts.",
        "Rebooting."},GREEN)
    os.reboot()
end

-- Remove this computer's registration payload, so it can register again: the
-- wireless receiver before its role package arrives, or the state reader's programs.
-- Summary: Remove this computer's registration payload, so it can register again: the wireless receiver before its role package arrives, or the state reader's programs.
local function removeRegistration(id,journal)
    local role=journal.role
    if role~="state" and fs.exists("/avionics/main.lua") then
        return message("Role package installed",{"This computer already runs its role package.","Reset installation on core to reassign it."},RED)
    end
    if not confirm("Remove registration as "..tostring(role).." from #"..id.."?") then return end
    local config=readFile(role=="state" and "/avionics/config.json" or "/config.json")
    config=config and textutils.unserializeJSON(config)
    local coreID=type(config)=="table" and (config.coreID or config.core_id)
    if type(coreID)=="number" and openModems() then rednet.send(coreID,{v=1,kind="unregister",role=role},PROTOCOL) end
    local paths=role=="state" and {"/startup.lua","/avionics","/amaryllis-install.json"} or
        {"/startup.lua","/installer.lua","/installer","/config.json","/amaryllis-install.json"}
    for _,path in ipairs(paths) do if fs.exists(path) then fs.delete(path) end end
    os.setComputerLabel(nil)
    message("Registration removed",{"Core #"..tostring(coreID).." was asked to clear "..tostring(role)..".",
        "Check core's screen, then register again."},GREEN)
end

-- Summary: Continue core registration, or offer core install and computer registration.
local function main()
    assert(http,"HTTP is disabled in the ComputerCraft config (http.enabled)")
    local id=os.getComputerID()
    local journal=readFile("/amaryllis-install.json");journal=journal and textutils.unserializeJSON(journal)
    if type(journal)=="table" and journal.role=="core" then
        local source=readFile(fs.combine(CORE_MEDIA,"source.json"));source=source and textutils.unserializeJSON(source)
        assert(type(source)=="table" and validBase(source.base),"This core was installed from a disk; use the disk setup")
        screen("AMARYLLIS WEB SETUP | CORE #"..id);line(3,"Loading core's release...")
        local Setup,release=loadRelease(source.base,CORE_MEDIA)
        if fs.exists(RESET_MARKER) then
            line(4,"Resetting installation...")
            Setup.unassignCore(CORE_MEDIA,release,id)
            Setup.installCore(CORE_MEDIA,release,id)
            fs.delete(RESET_MARKER)
        end
        return coreScreen(Setup,release,id,source.base)
    end
    screen("AMARYLLIS WEB SETUP | #"..id)
    line(3,"1  Install core on this computer")
    line(4,"2  Register this computer with core")
    local registered=type(journal)=="table" and type(journal.role)=="string"
    if registered then line(5,"3  Remove this computer's registration ("..journal.role..")") end
    line(registered and 6 or 5,"Q  Cancel")
    while true do
        local _,ch=os.pullEvent("char");ch=ch:lower()
        if ch=="1" then
            if confirm("Install core on computer #"..id.."?") then return installCore(id) end
        elseif ch=="2" then return registerComputer(id)
        elseif ch=="3" and registered then return removeRegistration(id,journal)
        elseif ch=="q" then term.clear();term.setCursorPos(1,1);return end
    end
end

local ok,issue=pcall(main)
term.setTextColor(colors.white)
if not ok then printError("Amaryllis web setup: "..tostring(issue)) end
