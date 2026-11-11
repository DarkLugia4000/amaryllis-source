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
-- Web update of an installed ship. Core downloads the new release into
-- CORE_NEXT before it restarts, records the update in UPDATE_MARKER and keeps
-- its own startup program in UPDATE_STARTUP. Its boot program then runs the new
-- release's web setup (from CORE_NEXT, or from CORE_MEDIA once the folders are
-- swapped), which finishes the update and puts core's startup back.
local CORE_NEXT="/installer/web-next"
local UPDATE_MARKER="/installer/web-update.json"
local UPDATE_STARTUP="/installer/web-update-startup.lua"
local UPDATE_BOOT='local p="/installer/web-next/web-setup.lua"\n'..
    'if not fs.exists(p) then p="/installer/web/web-setup.lua" end\n'..
    'assert(loadfile(p,nil,_ENV))()\n'
-- The state reader's update is staged by its runtime (avionics/state_update.lua)
-- when core asks for it over the wired state link.
local STATE_MARKER=NODE_MEDIA.."/update.json"
local STATE_STARTUP=NODE_MEDIA.."/state-startup.lua"
local STATE_PROTOCOL,CORE_CHANNEL,STATE_CHANNEL="amaryllis.state.v1",45130,45131
local WHITE,GRAY,CYAN,YELLOW,RED,GREEN=colors.white,colors.gray,colors.cyan,colors.yellow,colors.red,colors.lime

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
-- Show a titled message. Without restartSeconds it waits for any key. With
-- restartSeconds the bottom row counts down and the message closes on its own
-- after that many seconds, or earlier on any key; the caller then restarts the
-- computer. Used where nobody needs to be at the computer: after registration
-- and after an update that finishes on its own.
local function message(title,lines,color,restartSeconds)
    screen(title)
    for i,text in ipairs(lines) do line(2+i,text,color) end
    local _,h=term.getSize()
    if not restartSeconds then line(h,"Press any key",GRAY);os.pullEvent("key");return end
    local remaining=restartSeconds
    while remaining>0 do
        line(h,"Restarting in "..remaining.." s (any key: now)",GRAY)
        local timer=os.startTimer(1)
        while true do
            local event,value=os.pullEvent()
            if event=="key" then pcall(os.cancelTimer,timer);return end
            if event=="timer" and value==timer then break end
        end
        remaining=remaining-1
    end
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
local function readJSONFile(path)
    local data=readFile(path);local value=data and textutils.unserializeJSON(data)
    return type(value)=="table" and value or nil
end
-- True while core's saved systems intent says lift control should be running:
-- START SYSTEMS sets it and a confirmed STOP SYSTEMS clears it. The intent is a
-- section of /avionics/data/vessel-state.json (or its .bak copy); older cores
-- keep it in /avionics/data/systems-intent.json.
local function systemsRunning()
    for _,path in ipairs({"/avionics/data/vessel-state.json","/avionics/data/vessel-state.json.bak"}) do
        local state=readJSONFile(path)
        local intent=state and type(state.sections)=="table" and state.sections.systemsIntent
        if type(intent)=="table" then return intent.active==true end
    end
    local legacy=readJSONFile("/avionics/data/systems-intent.json")
    return legacy~=nil and legacy.active==true
end
-- Start a web update of core: download and check the new release into
-- CORE_NEXT, record the update, keep core's startup in UPDATE_STARTUP and boot
-- into the new release's web setup, which finishes the update after the restart.
local function startCoreUpdate(id,release,latest)
    screen("AMARYLLIS WEB UPDATE | CORE #"..id);line(3,"Downloading "..latest.releaseId.."...")
    if fs.exists(CORE_NEXT) then fs.delete(CORE_NEXT) end
    local _,nextRelease=loadRelease(latest.base,CORE_NEXT)
    writeFile(UPDATE_MARKER,textutils.serializeJSON({base=latest.base,releaseId=nextRelease.releaseId,from=release.releaseId}))
    if not fs.exists(UPDATE_STARTUP) then fs.move("/startup.lua",UPDATE_STARTUP) end
    writeFile("/startup.lua",UPDATE_BOOT)
    message("Updating core",{"Core restarts and installs "..nextRelease.releaseId..".",
        "Settings, calibration and assignments stay."},YELLOW)
    os.reboot()
end
local function roleOrder(release)
    local order={"core"};for _,role in ipairs(release.roleOrder) do order[#order+1]=role end
    return order
end

-- Core's registration screen: answers discovery, records registrations and
-- imports the assignments once every role is held.
-- Summary: Core's registration screen: answers discovery, records registrations and imports the assignments once every role is held.
local function coreScreen(Setup,release,id,releaseBase,latest)
    assert(openModems(),"Attach a modem to core: the other computers register over rednet")
    local order=roleOrder(release);local selected=1
    local notice=latest and ("W: update to "..latest.releaseId) or ""
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
                    computers=state.computers,reset=state.reset,releaseHistory=state.releaseHistory},PROTOCOL)
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
        elseif event=="char" and a:lower()=="w" and latest then
            if state.imported~=true then notice="Import assignments before updating core"
            elseif systemsRunning() then notice="STOP SYSTEMS before updating core"
            elseif confirm("Update core to "..latest.releaseId.."? Core restarts") then
                return startCoreUpdate(id,release,latest)
            end
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
    -- A computer installed under an earlier release of this deployment (before a
    -- web update) counts as installed too.
    local history=type(core.releaseHistory)=="table" and core.releaseHistory or {}
    local known=type(journal)=="table" and journal.releaseId==release.releaseId
    for _,earlier in ipairs(history) do if type(journal)=="table" and journal.releaseId==earlier then known=true end end
    local move=type(journal)=="table" and journal.pending==false and known and journal.role~=role
    if move then
        local allowed,why=pcall(Setup.checkRoleChange,release,id,journal.role,role,history)
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
        releaseId=release.releaseId,computers=core.computers,assignmentRevision=0,reset=core.reset,
        releaseHistory=core.releaseHistory}))
    local result=Setup.installRegistered(NODE_MEDIA,release,role,id,core.coreID)
    fs.delete(NODE_MEDIA)
    message("Registered as "..role,{result=="changed" and "Role changed." or
        result=="retained" and "Existing programs and settings kept." or "Payload installed.",
        role=="state" and "Connect it to core with wired modems." or "It installs its package when core starts."},GREEN,3)
    os.reboot()
end

-- Remove this computer's registration payload, so it can register again: the
-- wireless receiver before its role package arrives, or the state reader's programs.
-- For a receiver, /avionics is removed too: without /avionics/main.lua it holds
-- at most the folder the wireless installer creates and a partly copied package.
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
        {"/startup.lua","/installer.lua","/installer","/config.json","/amaryllis-install.json","/avionics"}
    for _,path in ipairs(paths) do if fs.exists(path) then fs.delete(path) end end
    os.setComputerLabel(nil)
    message("Registration removed",{"Core #"..tostring(coreID).." was asked to clear "..tostring(role)..".",
        "Check core's screen, then register again."},GREEN)
end

-- Ask the state reader, over core's wired modem, to update itself from the new
-- release. Returns one or two lines for core's screen, each short enough for
-- one screen row. The request goes out up to 3 times, waiting 5 seconds for an
-- acknowledgement each time. The state reader acknowledges,
-- stages its own update (avionics/state_update.lua) and restarts; a state
-- reader whose programs predate web updates does not answer.
local function pushStateUpdate(id,marker)
    local deployment=readJSONFile(fs.combine(CORE_MEDIA,"deployment.json"))
    local reader=deployment and type(deployment.computers)=="table" and deployment.computers.state
    if type(reader)~="table" or type(reader.id)~="number" then return {"No state reader is assigned."} end
    local modem
    for _,name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name)=="modem" and peripheral.wrap then
            local ok,candidate=pcall(peripheral.wrap,name)
            if ok and type(candidate)=="table" and type(candidate.isWireless)=="function" and not candidate.isWireless() then
                modem=candidate;break
            end
        end
    end
    if not modem then return {"State reader #"..reader.id.." not reached:","core has no wired modem."} end
    pcall(modem.open,CORE_CHANNEL)
    for _=1,3 do
        modem.transmit(STATE_CHANNEL,CORE_CHANNEL,{protocol=STATE_PROTOCOL,kind="state_update",sender=id,
            target=reader.id,base=marker.base,releaseId=marker.releaseId})
        local deadline=os.clock()+5
        while os.clock()<deadline do
            local timer=os.startTimer(.5)
            local event,_,channel,_,packet=os.pullEvent()
            if event~="timer" then pcall(os.cancelTimer,timer) end
            if event=="modem_message" and channel==CORE_CHANNEL and type(packet)=="table" and
                packet.protocol==STATE_PROTOCOL and packet.kind=="state_update_ack" and packet.sender==reader.id and
                packet.target==id and packet.releaseId==marker.releaseId then
                if packet.ok==true then return {"State reader #"..reader.id.." is updating itself."} end
                return {"State reader #"..reader.id.." could not update:",tostring(packet.error)}
            end
        end
    end
    return {"State reader #"..reader.id.." did not answer.","Run the loader there and choose 4."}
end
-- Finish a web update of core after its restart (UPDATE_MARKER). Each step can
-- run again after an interruption: the release is downloaded and checked again
-- until CORE_MEDIA holds the new release, and an interrupted folder swap is
-- completed first. Core's programs are replaced with settings, calibration and
-- assignments kept; the state reader is asked to update; core's new startup
-- goes back in place and core restarts into it.
local function resumeCoreUpdate(id)
    local marker=readJSONFile(UPDATE_MARKER)
    assert(marker and validBase(marker.base) and type(marker.releaseId)=="string","Invalid core update record")
    screen("AMARYLLIS WEB UPDATE | CORE #"..id)
    if not fs.exists(CORE_MEDIA) and fs.exists(fs.combine(CORE_NEXT,"source.json")) then fs.move(CORE_NEXT,CORE_MEDIA) end
    local current=readJSONFile(fs.combine(CORE_MEDIA,"source.json"))
    if not (current and current.releaseId==marker.releaseId) then
        line(3,"Downloading "..marker.releaseId.."...")
        local Setup,release=loadRelease(marker.base,CORE_NEXT)
        assert(release.releaseId==marker.releaseId,"The release changed during the update; run the loader again")
        line(4,"Installing core's programs...")
        Setup.updateInstalled(CORE_NEXT,release,"core",id,{startup=UPDATE_STARTUP,beforeWrite=function()
            marker.writing=true;writeFile(UPDATE_MARKER,textutils.serializeJSON(marker))
        end})
        Setup.carryDeployment(CORE_NEXT,release,readJSONFile(fs.combine(CORE_MEDIA,"deployment.json")))
        writeFile(fs.combine(CORE_NEXT,"source.json"),textutils.serializeJSON({base=marker.base,releaseId=release.releaseId}))
        local old=CORE_MEDIA.."-old"
        if fs.exists(old) then fs.delete(old) end
        fs.move(CORE_MEDIA,old);fs.move(CORE_NEXT,CORE_MEDIA);fs.delete(old)
    end
    line(5,"Asking the state reader to update...")
    local stateLines=pushStateUpdate(id,marker)
    if fs.exists(UPDATE_STARTUP) then fs.delete("/startup.lua");fs.move(UPDATE_STARTUP,"/startup.lua") end
    fs.delete(UPDATE_MARKER)
    if fs.exists(CORE_NEXT) then fs.delete(CORE_NEXT) end
    local lines={"Settings, calibration and assignments kept."}
    for _,text in ipairs(stateLines) do lines[#lines+1]=text end
    lines[#lines+1]="Core restarts; the other computers take their"
    lines[#lines+1]="new packages from core over wireless."
    message("Core updated to "..marker.releaseId,lines,GREEN,5)
    os.reboot()
end
-- A failed core update. Before any program file changed (marker.writing unset)
-- the update can be cancelled: core's startup goes back and core restarts into
-- its old programs. After that, only a retry is offered, since the programs are
-- part old and part new; the next restart also retries.
local function coreUpdateFailed(id,issue)
    local marker=readJSONFile(UPDATE_MARKER) or {}
    local canCancel=marker.writing~=true
    while true do
        screen("CORE UPDATE STOPPED | CORE #"..id)
        line(3,tostring(issue),RED)
        line(5,"Enter: retry the update",WHITE)
        if canCancel then line(6,"C: cancel; core keeps its current programs",WHITE)
        else line(6,"Programs are partly replaced: retry to finish.",YELLOW) end
        local event,a=os.pullEvent()
        if event=="key" and a==keys.enter then os.reboot() end
        if event=="char" and a:lower()=="c" and canCancel then
            if fs.exists(UPDATE_STARTUP) then fs.delete("/startup.lua");fs.move(UPDATE_STARTUP,"/startup.lua") end
            fs.delete(UPDATE_MARKER)
            if fs.exists(CORE_NEXT) then fs.delete(CORE_NEXT) end
            message("Update cancelled",{"Core restarts into its current programs."},YELLOW)
            os.reboot()
        end
    end
end
-- Finish the state reader's own update (STATE_MARKER, staged by its runtime
-- when core asked, or by option 4 here): download and check the release, replace
-- its programs with its settings kept, then restart into them. Its startup is
-- written last, so an interruption boots back into this update. A failure
-- before any file changed puts the saved startup back, so the state reader
-- returns to its current programs; a later failure retries at the next restart.
local function updateStateReader(id,releaseBase)
    assert(validBase(releaseBase),"Invalid release address")
    screen("AMARYLLIS WEB UPDATE | STATE #"..id);line(3,"Downloading the release...")
    local writing=false
    local ok,issue=pcall(function()
        local Setup,release=loadRelease(releaseBase,NODE_MEDIA)
        line(4,"Installing "..release.releaseId.."...")
        Setup.updateInstalled(NODE_MEDIA,release,"state",id,{beforeWrite=function() writing=true end})
        return release.releaseId
    end)
    if not ok then
        if not writing then
            if fs.exists(STATE_STARTUP) then fs.delete("/startup.lua");fs.move(STATE_STARTUP,"/startup.lua") end
            if fs.exists(NODE_MEDIA) then fs.delete(NODE_MEDIA) end
            message("State reader update failed",{tostring(issue),"It keeps its current programs."},RED,5)
        else
            message("State reader update failed",{tostring(issue),"It retries at the next restart."},RED)
        end
        os.reboot()
    end
    fs.delete(NODE_MEDIA)
    message("State reader updated",{"Now on "..tostring(issue).."."},GREEN,3)
    os.reboot()
end

-- Summary: Continue core registration, or offer core install and computer registration.
local function main()
    assert(http,"HTTP is disabled in the ComputerCraft config (http.enabled)")
    local id=os.getComputerID()
    local journal=readFile("/amaryllis-install.json");journal=journal and textutils.unserializeJSON(journal)
    if type(journal)=="table" and journal.role=="core" and fs.exists(UPDATE_MARKER) then
        local ok,issue=pcall(resumeCoreUpdate,id)
        if not ok then return coreUpdateFailed(id,issue) end
        return
    end
    if type(journal)=="table" and journal.role=="state" and fs.exists(STATE_MARKER) then
        local marker=readJSONFile(STATE_MARKER)
        assert(marker and validBase(marker.base),"Invalid state reader update record")
        return updateStateReader(id,marker.base)
    end
    if type(journal)=="table" and journal.role=="core" then
        local source=readFile(fs.combine(CORE_MEDIA,"source.json"));source=source and textutils.unserializeJSON(source)
        assert(type(source)=="table" and validBase(source.base),"This core was installed from a disk; use the disk setup")
        screen("AMARYLLIS WEB SETUP | CORE #"..id);line(3,"Loading core's release...")
        local Setup,release=loadRelease(source.base,CORE_MEDIA)
        -- The loader passes the newest release; offer it when core runs another one.
        local latest
        if validBase(base) and base~=source.base then
            local ok,index=pcall(function() return textutils.unserializeJSON(fetch(base..INDEX)) end)
            if ok and type(index)=="table" and type(index.releaseId)=="string" and index.releaseId~=release.releaseId then
                latest={base=base,releaseId=index.releaseId}
            end
        end
        if fs.exists(RESET_MARKER) then
            line(4,"Resetting installation...")
            Setup.unassignCore(CORE_MEDIA,release,id)
            Setup.installCore(CORE_MEDIA,release,id)
            fs.delete(RESET_MARKER)
        end
        return coreScreen(Setup,release,id,source.base,latest)
    end
    screen("AMARYLLIS WEB SETUP | #"..id)
    line(3,"1  Install core on this computer")
    line(4,"2  Register this computer with core")
    local registered=type(journal)=="table" and type(journal.role)=="string"
    if registered then line(5,"3  Remove this computer's registration ("..journal.role..")") end
    local stateUpdate=registered and journal.role=="state" and journal.pending==false and validBase(base)
    if stateUpdate then line(6,"4  Update this state reader to the newest release") end
    line(stateUpdate and 7 or registered and 6 or 5,"Q  Cancel")
    while true do
        local _,ch=os.pullEvent("char");ch=ch:lower()
        if ch=="1" then
            if confirm("Install core on computer #"..id.."?") then return installCore(id) end
        elseif ch=="2" then return registerComputer(id)
        elseif ch=="3" and registered then return removeRegistration(id,journal)
        elseif ch=="4" and stateUpdate then
            if confirm("Update this state reader? Update core first") then return updateStateReader(id,base) end
        elseif ch=="q" then term.clear();term.setCursorPos(1,1);return end
    end
end

local ok,issue=pcall(main)
term.setTextColor(colors.white)
if not ok then printError("Amaryllis web setup: "..tostring(issue)) end
