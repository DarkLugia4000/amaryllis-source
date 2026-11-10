-- Amaryllis installer-disk downloader.
-- Fills a disk in an attached disk drive with a release published on the web
-- (a GitHub repository holding the Disk Builder's media folder), in the same
-- layout the builder writes: release.json, library.json, setup.lua, objects/
-- and startup.lua. The finished disk installs her exactly like a built disk.
--
-- Usage:  wget run <raw link to media/download.lua> <user>/<repo>[/<branch>]
--         wget run <raw link to media/download.lua> <https link to the media folder>
--         /disk/download.lua            (later runs: the disk keeps its address)

local INDEX="download.json"
local SOURCE_RECORD="download-source.json"
local PROGRESS_FILES={"deployment.json","role-repair.json"}
local MARGIN_BYTES=16384
local args={...}

local function adler(data)
    local a,b=1,0
    for i=1,#data do a=(a+data:byte(i))%65521;b=(b+a)%65521 end
    return string.format("%04X%04X",b,a)
end
local function readFile(path)
    local h=fs.open(path,"rb");if not h then return nil end
    local data=h.readAll() or "";h.close();return data
end

-- Write through a temporary sibling so a failed write leaves no partial file.
-- Summary: Write and reread a temporary download before replacing the destination file.
local function writeFile(path,data)
    local temp=path..".tmp"
    if fs.exists(temp) then fs.delete(temp) end
    local h,why=fs.open(temp,"wb");if not h then error("Cannot write "..path..": "..tostring(why),0) end
    h.write(data);h.close()
    if readFile(temp)~=data then fs.delete(temp);error("Write check failed: "..path,0) end
    if fs.exists(path) then fs.delete(path) end
    fs.move(temp,path)
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
    return nil,last
end

-- Turn "user/repo[/branch]" or a full link into the address of the media folder.
-- Summary: Turn "user/repo[/branch]" or a full link into the address of the media folder.
local function baseAddress(text)
    if type(text)~="string" or text=="" then return nil end
    if text:match("^https?://") then return (text:gsub("/+$",""))..'/' end
    local user,repo,branch=text:match("^([%w%-%._]+)/([%w%-%._]+)/?(.*)$")
    if not user then return nil end
    branch=branch~="" and branch:gsub("/+$","") or "main"
    return "https://raw.githubusercontent.com/"..user.."/"..repo.."/"..branch.."/media/"
end
local function ask(prompt)
    write(prompt);return read()
end

-- Offer numbered choices and return the chosen key.
-- Summary: Offer numbered choices and return the chosen key.
local function choose(title,options)
    print(title)
    for i,option in ipairs(options) do print(" "..i.."  "..option[2]) end
    while true do
        local n=tonumber(ask("Choose 1-"..#options..": "))
        if n and options[n] then return options[n][1] end
    end
end
local function kb(bytes) return string.format("%d KB",math.ceil(bytes/1024)) end

-- Find disk drives that hold a writable disk; ask when there are several.
-- Summary: Find disk drives that hold a writable disk; ask when there are several.
local function pickDisk()
    local found={}
    for _,name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name)=="drive" and disk.hasData(name) then
            found[#found+1]={name=name,mount=disk.getMountPath(name),label=disk.getLabel(name)}
        end
    end
    if #found==0 then error("Insert a disk into an attached disk drive, then run this again.",0) end
    if #found==1 then return found[1] end
    local options={}
    for i,d in ipairs(found) do options[i]={i,"/"..d.mount.."  ("..d.name..(d.label and ", "..d.label or "")..")"} end
    return found[choose("Several disks are attached. Which one becomes the installer disk?",options)]
end

-- Summary: Accept a version-one disk index with up to 1024 relative file paths and startup.lua last.
local function validIndex(index)
    if type(index)~="table" or index.schemaVersion~=1 or type(index.releaseId)~="string" or type(index.files)~="table" then return false end
    if #index.files==0 or #index.files>1024 then return false end
    for _,f in ipairs(index.files) do
        if type(f)~="table" or type(f.path)~="string" or not f.path:match("^[%w%-%._/]+$") or f.path:find("..",1,true)
            or f.path:sub(1,1)=="/" or type(f.bytes)~="number" or f.bytes<0 or type(f.adler32)~="string" then return false end
    end
    return index.files[#index.files].path=="startup.lua"
end

-- Total bytes of everything under path.
local function usedBytes(path)
    if not fs.exists(path) then return 0 end
    if not fs.isDir(path) then return fs.getSize(path) end
    local total=0
    for _,name in ipairs(fs.list(path)) do total=total+usedBytes(fs.combine(path,name)) end
    return total
end
local function erase(mount)
    for _,name in ipairs(fs.list(mount)) do fs.delete(fs.combine(mount,name)) end
end

-- Describe what the disk holds and let the user decide how to treat it.
-- Summary: Describe what the disk holds and let the user decide how to treat it.
local function decide(mount,index)
    local entries=fs.list(mount)
    if #entries==0 then return "fresh" end
    local release=readFile(fs.combine(mount,"release.json"))
    local old=release and textutils.unserializeJSON(release)
    local progress={}
    for _,name in ipairs(PROGRESS_FILES) do if fs.exists(fs.combine(mount,name)) then progress[#progress+1]=name end end
    print("")
    if type(old)~="table" or type(old.releaseId)~="string" then
        return choose("This disk holds other files ("..#entries.." entries, "..kb(usedBytes(mount))..").",
            {{"replace","Erase the disk and download Amaryllis "..index.releaseId},{"cancel","Cancel"}})
    end
    print("Disk release:     "..old.releaseId)
    print("Download release: "..index.releaseId)
    if #progress>0 then print("Install progress is saved on this disk ("..table.concat(progress,", ")..").") end
    if old.releaseId==index.releaseId then
        return choose("The disk already holds this release.",{
            {"repair","Check the files and download missing or damaged ones"..(#progress>0 and " (keeps progress)" or "")},
            {"replace","Replace the disk contents"..(#progress>0 and " (clears progress)" or "")},
            {"cancel","Cancel"}})
    end
    return choose(#progress>0 and "Saved progress belongs to the disk release and is cleared by a new release."
        or "The disk holds an older or different release.",
        {{"replace","Replace the disk contents with "..index.releaseId},{"cancel","Cancel"}})
end

-- Main flow: address, index, decision, space check, download, verify.
-- Summary: Main flow: address, index, decision, space check, download, verify.
local function main()
    if not http then error("HTTP is disabled in the ComputerCraft config (http.enabled).",0) end
    local target=pickDisk();local mount="/"..target.mount
    local saved=readFile(fs.combine(mount,SOURCE_RECORD));saved=saved and textutils.unserializeJSON(saved)
    local base=baseAddress(args[1]) or (type(saved)=="table" and baseAddress(saved.base))
    while not base do base=baseAddress(ask("Release address (user/repo or link to the media folder): ")) end
    print("Release address: "..base)
    local raw,why=fetch(base..INDEX)
    if not raw then error("Cannot download "..INDEX.." from "..base..": "..tostring(why),0) end
    local index=textutils.unserializeJSON(raw)
    if not validIndex(index) then error(INDEX.." at that address is not an Amaryllis release index.",0) end
    local total=0;for _,f in ipairs(index.files) do total=total+f.bytes end
    print(("Release %s: %d files, %s."):format(index.releaseId,#index.files,kb(total)))

    local action=decide(mount,index)
    if action=="cancel" then print("Cancelled. The disk is unchanged.");return end
    local pending={}
    for _,f in ipairs(index.files) do
        local path=fs.combine(mount,f.path)
        local current=action=="repair" and fs.exists(path) and not fs.isDir(path) and readFile(path)
        if not (current and #current==f.bytes and adler(current)==f.adler32) then pending[#pending+1]=f end
    end
    local needed=0;for _,f in ipairs(pending) do needed=needed+f.bytes end
    local free=fs.getFreeSpace(mount)+(action=="replace" and usedBytes(mount) or 0)
    if needed+MARGIN_BYTES>free then
        error(("The disk needs %s free and has %s. Raise floppy_space_limit in computercraft-server.toml."):format(
            kb(needed+MARGIN_BYTES),kb(free)),0)
    end
    if #pending==0 then print("All files are present and correct. Nothing to download.") end
    if action=="replace" then erase(mount) end
    -- The disk boots only from a complete download: startup.lua is removed first and written last.
    if #pending>0 and pending[#pending]~=index.files[#index.files] then pending[#pending+1]=index.files[#index.files] end
    if #pending>0 and fs.exists(fs.combine(mount,"startup.lua")) then fs.delete(fs.combine(mount,"startup.lua")) end
    for i,f in ipairs(pending) do
        print(("[%d/%d] %s  %s"):format(i,#pending,f.path:sub(1,40),kb(f.bytes)))
        local data,err=fetch(base..f.path)
        if not data then error("Download failed for "..f.path..": "..tostring(err),0) end
        if #data~=f.bytes or adler(data)~=f.adler32 then error("Checksum mismatch for "..f.path..". Run this again to resume.",0) end
        local dir=fs.getDir(fs.combine(mount,f.path))
        if dir~="" and not fs.exists(dir) then fs.makeDir(dir) end
        writeFile(fs.combine(mount,f.path),data)
    end
    for _,f in ipairs(index.files) do
        local data=readFile(fs.combine(mount,f.path))
        if not data or #data~=f.bytes or adler(data)~=f.adler32 then error("Verification failed for "..f.path..". Run this again to repair.",0) end
    end
    writeFile(fs.combine(mount,SOURCE_RECORD),textutils.serializeJSON({base=base,releaseId=index.releaseId}))
    if not disk.getLabel(target.name) then disk.setLabel(target.name,"Amaryllis installer") end
    print("")
    print("Disk ready: "..index.releaseId.." on "..mount..".")
    print("Take it to her computers and boot them with the disk, starting with core.")
end

local ok,issue=pcall(main)
if not ok then printError("Amaryllis download: "..tostring(issue)) end
