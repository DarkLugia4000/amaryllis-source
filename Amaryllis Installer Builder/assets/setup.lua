-- Commission computers and reset their registered commissioning assignments.
-- Installation updates local program files and disk assignment records.
local Setup={}
local TITLES={core="Core controller",state="State reader",navigator="Bridge navigator",
    ["heading-left"]="Left heading display",["heading-right"]="Right heading display",["heading-main"]="Main heading display",
    chamber_fl="Front-left lift chamber",chamber_fr="Front-right lift chamber",
    chamber_bl="Rear-left lift chamber",chamber_br="Rear-right lift chamber",
    primary_l="Left primary controller",primary_r="Right primary controller",
    ["thrust-lb"]="Rear-left thrust",["thrust-rb"]="Rear-right thrust",
    ["thrust-ls"]="Left-side thrust",["thrust-rs"]="Right-side thrust"}
local NAMES={core="core",state="state",navigator="bridge",["heading-left"]="hdg-l",["heading-right"]="hdg-r",["heading-main"]="hdg-m",
    chamber_fl="chamber-fl",chamber_fr="chamber-fr",chamber_bl="chamber-bl",chamber_br="chamber-br",
    primary_l="primary-l",primary_r="primary-r",["thrust-lb"]="thrust-lb",["thrust-rb"]="thrust-rb",
    ["thrust-ls"]="thrust-ls",["thrust-rs"]="thrust-rs"}
local function title(role)
    if NAMES[role] then return NAMES[role].." | "..TITLES[role] end
    return tostring(role)
end
local function integer(n) return type(n)=="number" and n>=0 and n<=65535 and n%1==0 end
local function adler(data)
    local a,b=1,0
    for i=1,#data do a=(a+data:byte(i))%65521;b=(b+a)%65521 end
    return string.format("%04X%04X",b,a)
end
local function readFile(path)
    local h,why=fs.open(path,"r");if not h then error(why or ("Cannot read "..path),0) end
    local data=h.readAll();h.close();return data
end
local function ownedRecord(path)
    return path=="/amaryllis-install.json" or path=="/fleet.json" or path=="/installer/library.json" or
        path:match("/deployment%.json$") or path:match("/role%-repair%.json$")
end
local function readJSON(path)
    -- Only installer-owned records have recoverable companion names. Restore
    -- the last committed record, or finish a first write with valid staged JSON.
    if ownedRecord(path) then
        local temp=path..".amaryllis-tmp";local backup=path..".amaryllis-backup"
        if not fs.exists(path) then
            local candidate=fs.exists(backup) and backup or (fs.exists(temp) and temp)
            if candidate then
                assert(type(textutils.unserializeJSON(readFile(candidate)))=="table","Invalid recovery record: "..candidate)
                fs.move(candidate,path)
            end
        end
        if fs.exists(path) and (fs.exists(temp) or fs.exists(backup)) then
            assert(type(textutils.unserializeJSON(readFile(path)))=="table","Invalid committed record: "..path)
            if fs.exists(temp) then fs.delete(temp) end
            if fs.exists(backup) then fs.delete(backup) end
        end
    end
    return assert(textutils.unserializeJSON(readFile(path)),"Invalid JSON: "..path)
end
local function write(path,data)
    fs.makeDir(fs.getDir(path))
    local temp=path..".amaryllis-tmp";local backup=path..".amaryllis-backup"
    if ownedRecord(path) and (fs.exists(temp) or fs.exists(backup)) then readJSON(path) end
    if fs.exists(temp) or fs.exists(backup) then error("Unfinished write requires recovery: "..path,0) end
    if fs.exists(path) and readFile(path)==data then return end
    local h,why=fs.open(temp,"w");if not h then error(why or "Write failed",0) end
    h.write(data);h.close()
    if readFile(temp)~=data then error("Write verification failed: "..path,0) end
    local existing=fs.exists(path)
    if existing then fs.move(path,backup) end
    local ok,issue=pcall(fs.move,temp,path)
    if not ok then if existing then fs.move(backup,path) end;error(issue,0) end
    if existing then fs.delete(backup) end
end
local function json(path,value) write(path,textutils.serializeJSON(value)) end
local function validPath(path)
    return type(path)=="string" and path:sub(1,1)=="/" and not path:find("..",1,true)
        and not path:find("\\",1,true) and not path:find("//",1,true)
        and (path:match("^/avionics/") or path:match("^/packages/") or
            path:match("^/installer/") or path=="/startup.lua" or path=="/installer.lua")
end
function Setup.load(media)
    local release=readJSON(fs.combine(media,"release.json"))
    assert(release.schemaVersion==1 and type(release.releaseId)=="string","Unsupported release")
    assert(type(release.core)=="table" and type(release.bootstrap)=="table" and type(release.roles)=="table","Incomplete release")
    return release
end
local function payload(media,entry)
    assert(validPath(entry.path),"Unsafe installation path")
    assert(type(entry.object)=="string" and #entry.object==64 and entry.object:match("^[0-9a-f]+$"),"Invalid object name")
    local data=readFile(fs.combine(media,"objects/"..entry.object))
    assert(#data==entry.bytes and adler(data)==entry.adler32,"Corrupt release object: "..entry.path)
    return data
end
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function keys(value,allowed)
    if type(value)~="table" then return false end
    for k in pairs(value) do if not allowed[k] then return false end end
    return true
end
local function coreEntries(media,release)
    local entries={};for _,entry in ipairs(release.core) do entries[#entries+1]=entry end
    local profile=release.calibration
    if profile==nil then return entries end -- Older installer media has no learning defaults.
    assert(type(profile)=="table" and profile.schemaVersion==1 and type(profile.files)=="table" and
        #profile.files==2,"Invalid calibration defaults")
    local expected={["/avionics/data/hover-offset.json"]=true,["/avionics/data/level-bias.json"]=true}
    local seen={}
    for _,entry in ipairs(profile.files) do
        assert(type(entry)=="table" and expected[entry.path] and not seen[entry.path],"Invalid calibration path")
        seen[entry.path]=true
        assert(type(entry.bytes)=="number" and entry.bytes>0 and entry.bytes<=16384,"Invalid calibration size")
        local data=assert(textutils.unserializeJSON(payload(media,entry)),"Invalid calibration JSON")
        assert(type(data)=="table" and data.schemaVersion==1,"Invalid calibration schema")
        if entry.path=="/avionics/data/level-bias.json" then
            assert(keys(data,{schemaVersion=true,roll=true,pitch=true}) and finite(data.roll) and finite(data.pitch) and
                math.abs(data.roll)<=10000 and math.abs(data.pitch)<=10000,"Invalid leveling defaults")
        else
            assert(keys(data,{schemaVersion=true,bandBlocks=true,bands=true}) and data.bandBlocks==20 and
                type(data.bands)=="table","Invalid hover defaults")
            local count=0
            for band,value in pairs(data.bands) do
                count=count+1;local height=type(band)=="string" and tonumber(band)
                assert(count<=64 and finite(height) and height%20==0 and math.abs(height)<=10240 and
                    tostring(height)==band and keys(value,{offset=true,samples=true}) and finite(value.offset) and
                    math.abs(value.offset)<=.15 and integer(value.samples) and value.samples>=1 and value.samples<=1000,
                    "Invalid hover band default")
            end
            assert(count>0,"Empty hover defaults")
        end
        entries[#entries+1]={path=entry.path,object=entry.object,bytes=entry.bytes,adler32=entry.adler32,defaultsOnly=true}
    end
    return entries
end
local function recordExists(path)
    return fs.exists(path) or fs.exists(path..".amaryllis-tmp") or fs.exists(path..".amaryllis-backup")
end
local function deployment(media,release)
    local path=fs.combine(media,"deployment.json")
    if not recordExists(path) then return {schemaVersion=1,releaseId=release.releaseId,computers={},assignmentRevision=0} end
    local state=readJSON(path)
    assert(state.schemaVersion==1 and state.releaseId==release.releaseId and type(state.computers)=="table","Wrong deployment disk")
    assert(state.assignmentRevision==nil or integer(state.assignmentRevision),"Invalid assignment revision")
    assert(state.imported==nil or type(state.imported)=="boolean","Invalid core import marker")
    local ids={}
    for role,entry in pairs(state.computers) do
        assert(release.roles[role] and integer(entry.id) and entry.label==release.roles[role].label,"Invalid deployment role")
        assert(not ids[entry.id],"Duplicate computer ID in deployment");ids[entry.id]=true
    end
    if state.reset then
        local reset=state.reset
        assert(type(reset)=="table" and integer(reset.coreID) and type(reset.previous)=="table"
            and type(reset.pending)=="boolean","Invalid installation reset record")
        assert(reset.previous.core and reset.previous.core.id==reset.coreID,"Reset core identity differs")
        local previousIDs={}
        for role,entry in pairs(reset.previous) do
            assert(release.roles[role] and integer(entry.id) and entry.label==release.roles[role].label
                and not previousIDs[entry.id],"Invalid previous installation assignment")
            previousIDs[entry.id]=true
        end
    end
    return state
end
local function repair(media)
    local path=fs.combine(media,"role-repair.json")
    return recordExists(path) and readJSON(path) or nil
end
local function noPendingRepair(media)
    local plan=repair(media)
    assert(not plan or plan.pending==false,"Assignment correction is unfinished. Open Assignments to finish it first.")
end
local function register(media,release,state,role,id)
    noPendingRepair(media)
    assert(integer(id) and release.roles[role],"Invalid installation identity")
    local old=state.computers[role]
    assert(not old or old.id==id,title(role).." belongs to #"..tostring(old and old.id)..". Open Assignments to review or correct it.")
    for key,entry in pairs(state.computers) do
        assert(key==role or entry.id~=id,"This computer is registered as "..title(key)..". Open Assignments to correct it.")
    end
    assert(not fs.isReadOnly(media),"Installer disk must be writable to save role assignments")
    state.computers[role]={id=id,label=release.roles[role].label}
    json(fs.combine(media,"deployment.json"),state)
end
local function preflight(media,release,entries,role,id)
    local journalPath="/amaryllis-install.json"
    local journal=fs.exists(journalPath) and readJSON(journalPath) or nil
    local state=deployment(media,release)
    assert(not state.reset or not state.reset.pending,"Finish resetting installation on core #"..tostring(state.reset and state.reset.coreID).." first")
    local previous=state.reset and state.reset.previous[role]
    local retained=previous and previous.id==id and journal and journal.releaseId==release.releaseId
        and journal.role==role and journal.id==id
    if retained and role~="core" then
        assert(state.computers.core and state.computers.core.id==state.reset.coreID,
            "Register the original core #"..state.reset.coreID.." to retain this computer's installation")
    end
    if fs.exists("/startup.lua") or fs.exists("/avionics") or fs.exists("/fleet.json") or fs.exists("/config.json") then
        assert(retained or journal and journal.pending and journal.releaseId==release.releaseId and journal.role==role and journal.id==id,
            "Fresh computers only. Existing installations are not overwritten.")
    end
    local total,largest=16384,0;local seen={}
    for _,entry in ipairs(entries) do
        assert(not seen[entry.path],"Duplicate installation path");seen[entry.path]=true
        local data=payload(media,entry)
        local existing=fs.exists(entry.path)
        local oldBytes=existing and fs.getSize(entry.path) or 0
        -- A fresh file's temporary name becomes its final name; it does not
        -- require a second full copy. Resumed installs can replace existing
        -- files, so reserve that extra write and any positive size growth.
        -- Per-file padding covers CC's minimum file allocation as well.
        local unchanged=existing and (entry.defaultsOnly==true or readFile(entry.path)==data)
        total=total+(unchanged and 0 or math.max(0,entry.bytes-oldBytes)+512)
        if (existing and not unchanged) or entry.path=="/avionics/config.json" then
            -- Core/state identity is written into config after payload copy.
            largest=math.max(largest,entry.bytes+512)
        end
    end
    local free=fs.getFreeSpace("/")
    assert(free=="unlimited" or (type(free)=="number" and free>=total+largest),"Not enough computer space for installation and verified writes")
    return journalPath,retained
end
local function installFiles(media,entries)
    -- Startup is last: interruption cannot boot a partially copied application.
    for _,entry in ipairs(entries) do
        if entry.path~="/startup.lua" and not (entry.defaultsOnly==true and fs.exists(entry.path)) then
            write(entry.path,payload(media,entry))
        end
    end
end
local function finish(media,entries,journalPath,release,role,id,retained)
    if not retained then
        for _,entry in ipairs(entries) do if entry.path=="/startup.lua" then write(entry.path,payload(media,entry)) end end
    end
    json(journalPath,{releaseId=release.releaseId,role=role,id=id,pending=false})
end
function Setup.installCore(media,release,id)
    assert(not os.__amaryllisFleetRegistry,"Close core's runtime before installing core")
    local state=deployment(media,release)
    local assigned=state.computers.core
    local existing=recordExists("/amaryllis-install.json") and readJSON("/amaryllis-install.json") or nil
    assert(not assigned or assigned.id==id and existing and existing.pending==true
        and existing.role=="core" and existing.id==id and existing.releaseId==release.releaseId,
        "Core is already assigned. Use Unassign core to reset installation.")
    local entries=coreEntries(media,release)
    local journal,retained=preflight(media,release,entries,"core",id)
    register(media,release,state,"core",id)
    json(journal,{releaseId=release.releaseId,role="core",id=id,pending=true})
    if not retained then
        installFiles(media,entries)
        local config=readJSON("/avionics/config.json")
        config.computer_id=id;config.label=release.roles.core.label
        config.thrust.enabled=false
        json("/avionics/config.json",config)
    end
    local computers={}
    for role,entry in pairs(release.roles) do computers[role]={label=entry.label} end
    computers.core={id=id,label=release.roles.core.label}
    json("/fleet.json",{schemaVersion=1,computers=computers})
    os.setComputerLabel(release.roles.core.label)
    finish(media,release.core,journal,release,"core",id,retained)
    print(retained and "Core registered. Existing programs and settings retained." or "Core installed, propulsion disabled. Register auxiliaries using this disk.")
    print("Then return the disk here and IMPORT ROLE ASSIGNMENTS before starting core.")
end
function Setup.installAuxiliary(media,release,role,id)
    assert(role~="core" and release.roles[role],"Select an auxiliary role")
    if role=="state" then
        assert(type(release.state)=="table","State reader payload missing")
        local journal,retained=preflight(media,release,release.state,role,id)
        local state=deployment(media,release)
        assert(state.computers.core,"Install core on this disk first")
        register(media,release,state,role,id)
        json(journal,{releaseId=release.releaseId,role=role,id=id,pending=true})
        if not retained then
            installFiles(media,release.state)
            json("/avionics/config.json",{schemaVersion=1,role="state",label=release.roles.state.label,
                computerID=id,coreID=state.computers.core.id})
        end
        os.setComputerLabel(release.roles.state.label)
        finish(media,release.state,journal,release,role,id,retained)
        print("State reader installed. Connect it to core with wired modems.")
        print("Return disk to core and IMPORT ROLE ASSIGNMENTS, then reboot both.")
        return
    end
    local journal,retained=preflight(media,release,release.bootstrap,role,id)
    local state=deployment(media,release)
    assert(state.computers.core,"Install core on this disk first")
    register(media,release,state,role,id)
    json(journal,{releaseId=release.releaseId,role=role,id=id,pending=true})
    if not retained then
        installFiles(media,release.bootstrap)
        json("/config.json",{protocol="amaryllis.install.v1",core_id=state.computers.core.id,
            target_role="auto",chunkBytes=768,maxFileBytes=524288,maxTotalBytes=1048576,
            retrySeconds=3,offerTimeoutSeconds=15,heartbeatSeconds=5})
    end
    os.setComputerLabel(release.roles[role].label)
    finish(media,release.bootstrap,journal,release,role,id,retained)
    print(role.." registered as #"..id..". Remove disk and reboot to wait for core.")
end
function Setup.importFleet(media,release,id)
    noPendingRepair(media)
    local state=deployment(media,release)
    assert(state.computers.core and state.computers.core.id==id,"This is not the deployment's core computer")
    assert(not os.__amaryllisFleetRegistry,"Stop core's runtime before importing the deployment")
    assert(fs.exists("/amaryllis-install.json"),"Core has not been installed")
    local journal=readJSON("/amaryllis-install.json")
    assert(journal.releaseId==release.releaseId and journal.role=="core" and journal.id==id and journal.pending==false,
        "This core's completed installation record does not match this disk")
    local computers={}
    for role,entry in pairs(release.roles) do
        computers[role]=state.computers[role] or {label=entry.label}
        assert(computers[role].id,"Register "..title(role).." before importing assignments")
    end
    -- Set the repair barrier before the fleet write, including if power fails.
    state.imported=true
    state.reset=nil
    json(fs.combine(media,"deployment.json"),state)
    json("/fleet.json",{schemaVersion=1,computers=computers})
    print("Fleet imported. Remove disk and reboot core to distribute role packages.")
    print("Verify hardware and directions while disassembled before enabling flight.")
end
local function clone(value) return assert(textutils.unserializeJSON(textutils.serializeJSON(value))) end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function roleFor(state,id)
    for role,entry in pairs(state.computers) do if entry.id==id then return role end end
end
local function repairable(role) return role and role~="core" and role~="state" end
local function localRepairCheck(release,id,oldRole,newRole)
    assert(not os.__amaryllisFleetRegistry,"Restart from the setup disk with runtimes stopped before correcting assignments")
    assert(not fs.exists("/avionics/config.json") and not fs.exists("/avionics/main.lua"),
        "A role package is already present. This correction mode handles registration only; it will not relabel installed hardware.")
    for _,path in ipairs({"/installer/commit.json","/installer/commit.json.bak","/installer/commit.json.tmp"}) do
        assert(not fs.exists(path),"A package transaction needs recovery before assignment changes")
    end
    if fs.exists("/installer/status.json") then
        local status=readJSON("/installer/status.json")
        assert(status.hasInstalled~=true and status.recoveryRequired~=true and status.state~="committing",
            "Installed or recovering package must not be relabeled")
    end
    assert(recordExists("/amaryllis-install.json"),"This computer has no registration record")
    local journal=readJSON("/amaryllis-install.json")
    assert(journal.releaseId==release.releaseId and journal.id==id and journal.pending==false and
        (journal.role==oldRole or journal.role==newRole),"Local registration does not match this correction")
    return journal
end
function Setup.planRepair(media,release,id,newRole)
    noPendingRepair(media)
    local state=deployment(media,release)
    assert(state.assignmentRevision~=nil and state.imported~=true,
        "Assignments are already imported, or this disk predates correction support. Installed-package migration is not permitted here.")
    assert(state.assignmentRevision<65535,"Assignment revision limit reached; review the deployment before starting a correction")
    local oldRole=roleFor(state,id)
    assert(repairable(oldRole) and repairable(newRole) and release.roles[newRole] and oldRole~=newRole,
        "Choose a different auxiliary role. Core and state assignments cannot be moved by this mode.")
    localRepairCheck(release,id,oldRole,newRole)
    assert(not fs.isReadOnly(media),"Installer disk must be writable")
    local before=clone(state.computers);local after=clone(before)
    local steps={{id=id,oldRole=oldRole,newRole=newRole,applied=false}}
    local displaced=before[newRole]
    after[newRole]={id=id,label=release.roles[newRole].label}
    if displaced then
        after[oldRole]={id=displaced.id,label=release.roles[oldRole].label}
        steps[2]={id=displaced.id,oldRole=newRole,newRole=oldRole,applied=false}
    else after[oldRole]=nil end
    local plan={schemaVersion=1,releaseId=release.releaseId,revision=state.assignmentRevision,
        before=before,after=after,steps=steps,pending=true}
    json(fs.combine(media,"role-repair.json"),plan)
    return plan
end
local function checkedPlan(media,release)
    local plan=repair(media)
    assert(type(plan)=="table" and plan.schemaVersion==1 and plan.releaseId==release.releaseId and
        type(plan.before)=="table" and type(plan.after)=="table" and type(plan.steps)=="table" and
        (#plan.steps==1 or #plan.steps==2) and integer(plan.revision),"Invalid correction plan")
    local state=deployment(media,release)
    assert(state.imported~=true and (state.assignmentRevision==plan.revision or state.assignmentRevision==plan.revision+1),
        "Disk assignment revision changed; correction cannot be applied")
    local expected=clone(plan.before);local ids={};local oldRoles={};local newRoles={}
    for _,step in ipairs(plan.steps) do
        assert(integer(step.id) and not ids[step.id] and repairable(step.oldRole) and repairable(step.newRole) and
            release.roles[step.oldRole] and release.roles[step.newRole] and step.oldRole~=step.newRole and
            not oldRoles[step.oldRole] and not newRoles[step.newRole] and type(step.applied)=="boolean" and
            type(plan.before[step.oldRole])=="table" and plan.before[step.oldRole].id==step.id,"Invalid correction step")
        ids[step.id]=true;oldRoles[step.oldRole]=true;newRoles[step.newRole]=true
        expected[step.oldRole]=nil
    end
    for _,step in ipairs(plan.steps) do
        assert(not expected[step.newRole],"Correction would displace an unacknowledged computer")
        expected[step.newRole]={id=step.id,label=release.roles[step.newRole].label}
    end
    assert(same(expected,plan.after) and (same(state.computers,plan.before) or same(state.computers,plan.after)),
        "Correction snapshot does not match disk assignments")
    return plan,state
end
function Setup.resumeRepair(media,release,id)
    local plan,state=checkedPlan(media,release)
    assert(plan.pending==true,"This correction is already complete")
    local found=false
    for _,step in ipairs(plan.steps) do
        if step.id==id then
            found=true
            local journal=localRepairCheck(release,id,step.oldRole,step.newRole)
            -- The plan and the previous journal are the retained recovery record.
            -- Repeating this step is safe if power failed before disk acknowledgement.
            journal.role=step.newRole
            json("/amaryllis-install.json",journal)
            os.setComputerLabel(release.roles[step.newRole].label)
            step.applied=true
            json(fs.combine(media,"role-repair.json"),plan)
        end
    end
    assert(found,"Take this disk to one of the computers listed in the correction plan")
    local complete=true
    for _,step in ipairs(plan.steps) do if not step.applied then complete=false end end
    if complete then
        assert(plan.revision<65535,"Assignment revision limit reached; review the deployment")
        state.computers=plan.after;state.assignmentRevision=plan.revision+1
        json(fs.combine(media,"deployment.json"),state)
        plan.pending=false
        json(fs.combine(media,"role-repair.json"),plan)
        print("Correction complete. Updated assignments are ready to import.")
    else
        print("Local role corrected. Finish the other computer before importing.")
    end
    return plan
end
function Setup.cancelRepair(media,release)
    local plan=checkedPlan(media,release)
    assert(plan.pending==true,"No pending correction")
    assert(#plan.steps==1,"A two-computer correction must be finished on both computers; cancellation cannot verify the remote computer")
    for _,step in ipairs(plan.steps) do assert(not step.applied,"A correction has started. Resume the listed computers to finish it.") end
    -- A crash may have changed the current computer before its disk ack. Do not
    -- offer cancellation from another computer where that cannot be established.
    local id=os.getComputerID();local own
    for _,step in ipairs(plan.steps) do if step.id==id then own=step end end
    assert(own and readJSON("/amaryllis-install.json").role==own.oldRole,"Resume correction; local outcome cannot be confirmed")
    plan.pending=false;plan.cancelled=true
    json(fs.combine(media,"role-repair.json"),plan)
end
function Setup.overview(media,release)
    local state=deployment(media,release)
    local order={"core"};for _,r in ipairs(release.roleOrder) do order[#order+1]=r end
    local count=0
    for _,role in ipairs(order) do
        local item=state.computers[role];if item then count=count+1 end
        print((item and ("#"..item.id) or "--").."  "..title(role))
        if _%7==0 then print("Enter for next page");read() end
    end
    print(count.."/"..#order.." roles registered (not package verification).")
    print(state.imported and "Assignments imported into core." or "Assignments not yet imported.")
    local plan=repair(media)
    if plan and plan.pending then
        print("CORRECTION UNFINISHED - IMPORT BLOCKED")
        for _,step in ipairs(plan.steps) do print("#"..step.id.." -> "..title(step.newRole)..(step.applied and " [DONE]" or " [VISIT]")) end
    end
end
-- Clear commissioning assignments on the disk and registered core. The retained
-- roster authorizes the same installed computers to register again with their
-- programs, configuration and learned records preserved. A pending disk record
-- keeps an interrupted reset resumable on its original core.
function Setup.unassignCore(media,release,id)
    assert(not os.__amaryllisFleetRegistry,"Close core's runtime before resetting installation")
    local state=deployment(media,release)
    local pending=state.reset and state.reset.pending
    local core=pending and {id=state.reset.coreID} or state.computers.core
    assert(core and core.id==id,"Insert this disk into core #"..tostring(core and core.id or "?").." to reset installation.")
    local journal=readJSON("/amaryllis-install.json")
    assert(journal.role=="core" and journal.id==id and journal.releaseId==release.releaseId,
        "The core installation record does not match this disk")
    assert(not fs.isReadOnly(media) and not fs.isReadOnly("/"),"Core and installer disk must be writable")
    if recordExists("/fleet.json") then
        local fleet=readJSON("/fleet.json")
        assert(fleet.computers and fleet.computers.core and fleet.computers.core.id==id,
            "Core fleet identity differs from this disk")
    end
    if not pending then
        local previous=clone(state.computers)
        state={schemaVersion=1,releaseId=release.releaseId,computers={},assignmentRevision=0,imported=false,
            reset={coreID=id,previous=previous,pending=true}}
        json(fs.combine(media,"deployment.json"),state)
    end
    for _,path in ipairs({"/fleet.json",fs.combine(media,"role-repair.json")}) do
        for _,suffix in ipairs({"",".bak",".tmp",".amaryllis-tmp",".amaryllis-backup"}) do
            local target=path..suffix
            if fs.exists(target) then fs.delete(target) end
        end
    end
    state.reset.pending=false
    json(fs.combine(media,"deployment.json"),state)
    local count=0;for _ in pairs(release.roles)do count=count+1 end
    print("Installation assignments cleared.")
    print("Install core, then register all "..count.." computers again.")
end
function Setup.adoptLibrary(media,release,id)
    assert(not os.__amaryllisFleetRegistry,"Stop core before adopting a package library")
    local fleet=readJSON("/fleet.json")
    local core=fleet.computers and fleet.computers.core
    assert(core and core.id==id and core.label==os.getComputerLabel(),"This is not the registered core")
    for role,expected in pairs(release.roles) do
        local registered=fleet.computers[role]
        assert(registered and integer(registered.id) and registered.label==expected.label,"Fleet roles/labels differ from this disk")
    end
    assert(fs.exists("/installer/media.lua") or (fs.exists("/avionics/main.lua") and fs.exists("/installer/library.json")),
        "This core needs an offline upgrade to disk-library support first")
    local catalogRaw=readFile(fs.combine(media,"library.json"))
    local catalog=assert(textutils.unserializeJSON(catalogRaw),"Invalid disk catalog")
    assert(catalog.schemaVersion==1 and catalog.libraryId==release.libraryId and
        type(catalog.files)=="table" and #catalog.files>0 and #catalogRaw<=65536,"Unsupported disk library")
    -- This action updates auxiliary packages only. A changed core runtime needs
    -- a separate offline upgrade, rather than a silent partial core update.
    local catalogEntry
    for _,entry in ipairs(release.core) do
        local data=payload(media,entry)
        if entry.path=="/installer/library.json" then catalogEntry=data
        elseif entry.path~="/avionics/config.json" then
            assert(fs.exists(entry.path) and readFile(entry.path)==data,
                "Core runtime differs; an offline core upgrade is needed before using this library: "..entry.path)
        end
    end
    assert(catalogEntry==catalogRaw,"Disk catalog does not match its release")
    assert(type(release.library)=="table" and #release.library==#catalog.files,"Incomplete library")
    local seen={}
    for _,entry in ipairs(release.library) do
        assert(entry.path:match("^/packages/") and not seen[entry.path],"Invalid library path")
        seen[entry.path]=entry
        payload(media,entry) -- Verify every source object before changing metadata.
        sleep(0)
    end
    for _,entry in ipairs(catalog.files) do assert(same(entry,seen[entry.path]),"Catalog/library mismatch") end
    assert(type(catalog.roles)=="table","Missing role version metadata")
    for role in pairs(release.roles) do
        if role~="core" and role~="state" then
            local expected=catalog.roles[role]
            assert(type(expected)=="table" and type(expected.packageId)=="string" and integer(expected.version),"Missing package version")
        end
    end
    write("/installer/library.json",catalogRaw)
    print("Library adopted. Start core with this disk to install, update or repair auxiliaries.")
end
function Setup.startCore(media,release,id)
    assert(not os.__amaryllisFleetRegistry,"Core is already running")
    local state=deployment(media,release)
    local journal=readJSON("/amaryllis-install.json")
    local fleet=readJSON("/fleet.json")
    assert(journal.role=="core" and journal.id==id and journal.pending==false and
        fleet.computers and fleet.computers.core and fleet.computers.core.id==id,"This core is not fully installed")
    for role in pairs(release.roles) do
        assert(fleet.computers[role] and integer(fleet.computers[role].id),"Complete role assignments are required before starting core")
    end
    assert(state.imported==true or journal.releaseId~=release.releaseId,"Import role assignments before starting core")
    local plan=repair(media);assert(not plan or not plan.pending,"Finish assignment corrections first")
    assert(readFile("/installer/library.json")==readFile(fs.combine(media,"library.json")),"Adopt this disk's library before starting core with it")
    assert(shell.run("/startup.lua"),"Core startup failed")
end
-- Keyboard commissioning UI. Navigation changes no assignment records.
local keyCodes=_ENV.keys
local PAGES={"Setup","Chambers","Thrust","Displays","State","Assignments"}
local WHITE,BLACK,GRAY,CYAN,MUTED,YELLOW,RED=1,32768,128,512,256,16,16384
local function clean(value)return tostring(value or ""):gsub("[%c]"," ")end
local function wrap(text,width)
    local rows={};text=clean(text);width=math.max(1,width)
    while #text>width do
        local at=text:sub(1,width+1):match("^.*() ")
        if not at or at<math.floor(width/2)then at=width+1 end
        rows[#rows+1]=text:sub(1,at-1);text=text:sub(at):gsub("^ +","")
    end
    rows[#rows+1]=text;return rows
end
local function put(x,y,text,width,fg,bg)
    local w,h=term.getSize();if y<1 or y>h or x>w then return end
    width=math.max(0,math.min(width or w-x+1,w-x+1))
    term.setCursorPos(x,y);term.setTextColor(fg or WHITE);term.setBackgroundColor(bg or BLACK)
    term.write((clean(text)..string.rep(" ",width)):sub(1,width))
end
local function clear()
    term.setBackgroundColor(BLACK);term.setTextColor(WHITE);term.setCursorBlink(false);term.clear()
end
local function key()
    while true do
        local event,code=os.pullEvent()
        if event=="key"then return code elseif event=="term_resize"then return "resize"end
    end
end
local function enter(code)return code==keyCodes.enter or keyCodes.numPadEnter and code==keyCodes.numPadEnter end
local function dialog(heading,messages,confirmation,destructive)
    if type(messages)=="string"then messages={messages}end
    local yes=false;local offset=0
    while true do
        local w,h=term.getSize();clear()
        put(2,2,heading,w-2,destructive and RED or CYAN)
        local rows={}
        for _,text in ipairs(messages)do for _,part in ipairs(wrap(text,w-4))do rows[#rows+1]=part end end
        local capacity=math.max(1,h-8);local maximum=math.max(0,#rows-capacity)
        offset=math.max(0,math.min(maximum,offset))
        for i=1,capacity do put(3,4+i-1,rows[offset+i]or"",w-4)end
        if maximum>0 then put(w-16,h-4,(offset+1).."-"..math.min(#rows,offset+capacity).."/"..#rows,15,MUTED)end
        if confirmation then
            local first=destructive and 3 or math.max(3,math.floor(w/2)-8)
            if destructive then
                put(first,h-3,yes and"> RESET INSTALLATION"or"  RESET INSTALLATION",21,RED)
                put(first+22,h-3,yes and"  CANCEL"or"> CANCEL",9,WHITE)
            else
                put(first,h-3,yes and"> YES"or"  YES",7,WHITE)
                put(first+9,h-3,yes and"  NO"or"> NO",6,WHITE)
            end
            put(2,h-1,"Left/Right: choose  Enter: confirm",w-2,MUTED)
            put(2,h,"Esc: cancel  Up/Down: scroll",w-2,MUTED)
        else
            put(2,h-2,"> Back",w-2)
            put(2,h,"Enter/Esc: back  Up/Down: scroll",w-2,MUTED)
        end
        local code=key()
        if code==keyCodes.escape then return false
        elseif enter(code)then return confirmation and yes or false
        elseif code==keyCodes.left and confirmation then yes=true
        elseif code==keyCodes.right and confirmation then yes=false
        elseif code==keyCodes.up then offset=math.max(0,offset-1)
        elseif code==keyCodes.down then offset=math.min(maximum,offset+1)end
    end
end
local function operation(heading,action)
    local messages={};local original,originalError=print,printError
    local function capture(...)
        local words={};for i=1,select("#",...)do words[#words+1]=tostring(select(i,...))end
        messages[#messages+1]=table.concat(words," ")
    end
    print,printError=capture,capture
    local ok,issue=pcall(action)
    print,printError=original,originalError
    if not ok then messages={tostring(issue)}end
    if #messages==0 then messages[1]=ok and"Completed."or"Unable to complete this action."end
    dialog(ok and heading or"Action unavailable",messages,false)
    return ok
end
local function order(release)
    local roles={"core"};local seen={core=true}
    for _,role in ipairs(release.roleOrder)do if not seen[role]then roles[#roles+1]=role;seen[role]=true end end
    return roles
end
local function registrationAvailability(state,release,role,id,journal)
    local assigned=state.computers[role]
    if assigned then
        local resume=assigned.id==id and type(journal)=="table"and journal.pending==true and
            journal.releaseId==release.releaseId and journal.role==role and journal.id==id
        if resume then return false,"Resume this computer's interrupted installation."end
        return true,"Already assigned to #"..assigned.id.."."
    end
    local own=roleFor(state,id)
    if own then return true,"This computer is "..(NAMES[own]or own)..". Use Assignments to correct it."end
    if not state.computers.core then return true,"Install core first."end
    return false,nil
end
local function rowsFor(page,release,state,id,journal)
    if page==1 then
        local core=state.computers.core
        local pendingReset=state.reset and state.reset.pending
        local coreID=pendingReset and state.reset.coreID or core and core.id
        local resume=core and core.id==id and journal and journal.pending==true
            and journal.role=="core" and journal.releaseId==release.releaseId
        local reset=coreID~=nil and not resume
        return{
            {label="Register this computer",action="register",disabled=not core or pendingReset,reason=not core and"Install core first."or nil},
            {label=pendingReset and"Resume installation reset"or reset and"Unassign core"or resume and"Resume core installation"or"Install core",
                action=reset and"unassign"or"core",danger=reset,disabled=coreID and coreID~=id,
                reason=coreID and coreID~=id and("Insert this disk into core #"..coreID.." to reset installation.")or nil},
            {label="Assignments",action="assignments"},
            {label="Import assignments into core",action="import"},
            {label="Start core with disk",action="start"},
            {label="Adopt auxiliary package library",action="library"},
            {label="Leave installer",action="leave"}}
    end
    local rows={}
    for _,role in ipairs(order(release))do
        local included=page==6 or(page==2 and role:match("^chamber_"))or
            (page==3 and(role:match("^thrust%-")or role:match("^primary_")))or
            (page==4 and(role=="navigator"or role:match("^heading%-")))or(page==5 and role=="state")
        if included then
            local disabled,reason=false,nil
            if page~=6 then disabled,reason=registrationAvailability(state,release,role,id,journal)
            elseif not repairable(role)then disabled=true;reason="To change assignments, please revisit the desired computer with this disk."end
            rows[#rows+1]={role=role,label=NAMES[role]or role,description=TITLES[role]or role,
                assigned=state.computers[role],disabled=disabled,reason=reason}
        end
    end
    return rows
end
local function showPlanRows(plan)
    local rows={}
    for _,step in ipairs(plan.steps)do
        rows[#rows+1]="#"..step.id..": "..(NAMES[step.oldRole]or step.oldRole).." -> "..(NAMES[step.newRole]or step.newRole)..
            (step.applied and" [DONE]"or" [VISIT]")
    end
    return rows
end
local function pendingCorrection(media,release,id)
    while true do
        local plan=repair(media)
        if not plan or not plan.pending then return end
        local lines=showPlanRows(plan)
        local applicable=false
        for _,step in ipairs(plan.steps)do if step.id==id then applicable=true end end
        local actions={{label="Apply correction on this computer",action="finish",disabled=not applicable},
            {label="Cancel unstarted correction",action="cancel"},{label="Back",action="back"}}
        local selected=1
        while true do
            local w,h=term.getSize();clear();put(2,2,"Assignment correction",w-2,CYAN)
            for i,line in ipairs(lines)do put(2,3+i,line,w-2)end
            local first=math.max(8,h-7)
            for i,item in ipairs(actions)do put(2,first+i-1,(i==selected and"> "or"  ")..item.label,w-2,item.disabled and GRAY or WHITE)end
            put(2,h-2,applicable and"Finish every listed computer before import."or"Take this disk to a listed computer.",w-2,MUTED)
            put(2,h,"Up/Down: select  Enter: choose  Esc: back",w-2,MUTED)
            local code=key()
            if code==keyCodes.escape then return
            elseif code==keyCodes.up then selected=math.max(1,selected-1)
            elseif code==keyCodes.down then selected=math.min(#actions,selected+1)
            elseif enter(code)then
                local chosen=actions[selected]
                if chosen.action=="back"then return
                elseif not chosen.disabled then
                    if chosen.action=="finish"then
                        if dialog("Apply correction",lines,true)then operation("Correction saved",function()Setup.resumeRepair(media,release,id)end);return end
                    elseif dialog("Cancel correction",{"Cancel this unstarted correction?","A started swap must be finished on both computers."},true)then
                        operation("Correction cancelled",function()Setup.cancelRepair(media,release)end);return
                    end
                end
            end
        end
    end
end
local function correctAssignment(media,release,state,id,newRole)
    local plan=repair(media)
    if plan and plan.pending then pendingCorrection(media,release,id);return end
    local old=roleFor(state,id)
    if not old then dialog("No local assignment","Register this computer from its role page first.",false);return end
    if old==newRole then dialog("Assignment unchanged","This computer is already "..(NAMES[old]or old)..".",false);return end
    local ok,issue=pcall(function()
        assert(state.assignmentRevision~=nil and state.imported~=true,"Assignments are already imported. Registration corrections are locked.")
        assert(repairable(old)and repairable(newRole),"Core and state assignments cannot be moved here.")
        localRepairCheck(release,id,old,newRole)
    end)
    if not ok then dialog("Correction unavailable",tostring(issue),false);return end
    local lines={"#"..id..": "..(NAMES[old]or old).." -> "..(NAMES[newRole]or newRole)}
    local other=state.computers[newRole]
    if other then
        lines[#lines+1]="#"..other.id..": "..(NAMES[newRole]or newRole).." -> "..(NAMES[old]or old)
        lines[#lines+1]="Swap: visit both computers to finish."
    end
    if not dialog("Save assignment correction",lines,true)then return end
    operation("Assignment correction",function()
        local planned=Setup.planRepair(media,release,id,newRole)
        Setup.resumeRepair(media,release,id)
        if planned.pending then
            for _,step in ipairs(planned.steps)do if not step.applied then print("Take this disk to computer #"..step.id..".")end end
        end
    end)
end
function Setup.main(media)
    local release=Setup.load(media);local page=1;local selections={};local offsets={}
    while true do
        local id=os.getComputerID();local state=deployment(media,release)
        local current=roleFor(state,id)
        local journal=recordExists("/amaryllis-install.json")and readJSON("/amaryllis-install.json")or nil
        local rows=rowsFor(page,release,state,id,journal)
        local selected=math.max(1,math.min(#rows,selections[page]or 1));selections[page]=selected
        local w,h=term.getSize();local first=7;local capacity=math.max(1,h-11)
        local offset=math.max(0,math.min(math.max(0,#rows-capacity),offsets[page]or 0))
        if selected<=offset then offset=selected-1 elseif selected>offset+capacity then offset=selected-capacity end
        offsets[page]=offset
        clear()
        put(2,1,"AMARYLLIS SETUP | #"..id,w-2,CYAN)
        put(2,3,"< "..PAGES[page].."  "..page.."/"..#PAGES.." >",w-2)
        put(2,4,"This computer: "..(current and(NAMES[current]or current)or"unassigned"),w-2,MUTED)
        if page~=1 then
            put(4,6,"Computer",14,MUTED);put(19,6,"Role",math.max(1,w-27),MUTED);put(w-6,6,"ID",6,MUTED)
        end
        for i=offset+1,math.min(#rows,offset+capacity)do
            local item=rows[i];local y=first+i-offset-1
            local fg=page==6 and item.assigned and item.assigned.id==id and YELLOW or item.disabled and GRAY or item.danger and RED or WHITE
            put(2,y,i==selected and">"or" ",1,fg)
            if page==1 then put(4,y,item.label,w-4,fg)
            else
                put(4,y,item.label,14,fg);put(19,y,item.description,math.max(1,w-27),fg)
                put(w-6,y,item.assigned and("#"..item.assigned.id)or"-",6,fg)
            end
        end
        local chosen=rows[selected]
        local pending=repair(media)
        local notice=chosen and chosen.reason or page==6 and"Enter: correct this computer to the selected role."or
            page~=1 and"Left/right are viewed facing the bow."or"Choose an action."
        if page==6 and pending and pending.pending then notice="Correction pending. Enter to view or finish it."end
        for i,line in ipairs(wrap(notice,w-3))do if i<=3 then put(2,h-4+i-1,line,w-2,chosen and chosen.disabled and WHITE or MUTED)end end
        if #rows>capacity then put(w-15,5,(offset+1).."-"..math.min(#rows,offset+capacity).."/"..#rows,14,MUTED)end
        put(2,h-1,"Left/Right: pages  Up/Down: select",w-2,MUTED)
        put(2,h,"Enter: choose  Esc: back",w-2,MUTED)
        local code=key()
        if code==keyCodes.left then page=(page-2)%#PAGES+1
        elseif code==keyCodes.right then page=page%#PAGES+1
        elseif code==keyCodes.up then selections[page]=math.max(1,selected-1)
        elseif code==keyCodes.down then selections[page]=math.min(#rows,selected+1)
        elseif code==keyCodes.escape then
            if page==1 then clear();return else page=1 end
        elseif enter(code)and chosen then
            if page==6 and pending and pending.pending then pendingCorrection(media,release,id)
            elseif chosen.disabled then
                -- Focus exposes the owner ID; activation cannot register it.
            elseif page==6 then correctAssignment(media,release,state,id,chosen.role)
            elseif page~=1 then
                if dialog("Register computer",{"Assign "..chosen.label.." to computer #"..id.."?",chosen.description},true)then
                    operation("Computer registered",function()Setup.installAuxiliary(media,release,chosen.role,id)end)
                end
            elseif chosen.action=="leave"then clear();return
            elseif chosen.action=="register"then page=2
            elseif chosen.action=="assignments"then page=6
            elseif chosen.action=="core"then
                if dialog("Install core","Install core on computer #"..id.."?",true)then operation("Core installed",function()Setup.installCore(media,release,id)end)end
            elseif chosen.action=="unassign"then
                local count=0;for _ in pairs(release.roles)do count=count+1 end
                if dialog("Reset installation?",{
                    "This will clear all computer assignments from this disk and core #"..id..".",
                    "You will need to register all "..count.." computers again."},true,true)then
                    operation("Installation reset",function()Setup.unassignCore(media,release,id)end)
                end
            elseif chosen.action=="import"then
                if dialog("Import assignments","Import this disk's assignments into core #"..id.."?",true)then operation("Assignments imported",function()Setup.importFleet(media,release,id)end)end
            elseif chosen.action=="library"then
                if dialog("Adopt auxiliary library",{"Use this disk's auxiliary library on core #"..id.."?","Core must be stopped."},true)then operation("Library adopted",function()Setup.adoptLibrary(media,release,id)end)end
            elseif chosen.action=="start"then
                local ok,issue=pcall(Setup.startCore,media,release,id)
                if ok then return else dialog("Core startup unavailable",tostring(issue),false)end
            end
        end
    end
end
Setup.adler32=adler
Setup.validPath=validPath
return Setup
