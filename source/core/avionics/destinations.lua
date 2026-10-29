-- @ama-section: Destination library | Mounted-media validation, listing and accepted edits.
-- Portable destination library. Never owns flight intent or arbitrary paths.
local Library={}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function copy(v) if type(v)~="table" then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
function Library.validEntry(e)
    return type(e)=="table" and type(e.name)=="string" and #e.name>=1 and #e.name<=40 and
        e.name:match("%S")~=nil and not e.name:find("[%c]") and finite(e.x) and finite(e.z) and
        math.abs(e.x)<=30000000 and math.abs(e.z)<=30000000
end
-- @ama-section: Destination library | Mounted-media validation, listing and accepted edits.
-- @ama-summary: Validate a saved destination document and its entries.
function Library.validate(value)
    if type(value)~="table" or value.schemaVersion~=1 or type(value.destinations)~="table" then return false,"DESTINATION DISK FORMAT INVALID" end
    local count,names=0,{}
    for k,e in pairs(value.destinations) do
        count=count+1
        if type(k)~="number" or k%1~=0 or k<1 or k>64 or not Library.validEntry(e) then return false,"DESTINATION DISK ENTRIES INVALID" end
        if names[e.name:lower()] then return false,"DESTINATION NAME ALREADY EXISTS" end
        names[e.name:lower()]=true
    end
    if count>64 or count~=#value.destinations then return false,"DESTINATION DISK LIMIT / ORDER INVALID" end
    return true
end
function Library.new(deps)
    deps=deps or {}
    return setmetatable({fs=deps.fs or fs,json=deps.json or textutils,peripheral=deps.peripheral or peripheral,
        disk=deps.disk or disk,entries={},available=false},{__index=Library})
end
-- @ama-summary: Resolve the removable-media path used by the destination library.
function Library:mount()
    local p=self.peripheral;local d=self.disk
    if not p or type(p.getNames)~="function" or not d or type(d.getMountPath)~="function" then return nil,"DESTINATION DISK DRIVE UNAVAILABLE" end
    local found
    for _,name in ipairs(p.getNames()) do
        local ok,mount=pcall(d.getMountPath,name)
        if ok and type(mount)=="string" then
            if found then return nil,"MULTIPLE DISKS; LEAVE ONE DESTINATION DISK INSERTED" end
            found={name=name,path=mount,id=type(d.getID)=="function" and d.getID(name) or nil}
        end
    end
    if not found then return nil,"INSERT A DESTINATION DISK" end
    return found
end
-- @ama-summary: Read and validate a saved destination file from mounted media.
function Library:read(path)
    if self.fs.getSize(path)>65536 then return nil,"DESTINATION LIBRARY TOO LARGE" end
    local h,why=self.fs.open(path,"r");if not h then return nil,why or "DISK READ FAILED" end
    local data=h.readAll();h.close()
    local value=self.json.unserializeJSON(data)
    local valid,reason=Library.validate(value)
    if not valid then return nil,reason end
    return value
end
-- @ama-summary: Discover destination documents on currently mounted media.
function Library:scan()
    self.available=false;self.entries={}
    if not self.fs or not self.json then self.reason="DESTINATION DISK API UNAVAILABLE";return false,self.reason end
    local mount,reason=self:mount();self.media=mount
    if not mount then self.reason=reason;return false,reason end
    self.path=self.fs.combine(mount.path,"amaryllis-destinations.json")
    local value={schemaVersion=1,destinations={}}
    if self.fs.exists(self.path) then
        local ok,result,why=pcall(self.read,self,self.path)
        if not ok or not result then self.reason=why or tostring(result);return false,self.reason end
        value=result
    elseif self.fs.exists(self.path..".bak") then
        -- A power loss between renames retains the prior valid library.
        local ok,result,why=pcall(self.read,self,self.path..".bak")
        if not ok or not result then self.reason=why or tostring(result);return false,self.reason end
        value=result
    end
    self.document=copy(value);self.entries=copy(value.destinations);self.available=true
    self.writable=not self.fs.isReadOnly(mount.path)
    self.reason=self.writable and nil or "DESTINATION DISK READ ONLY"
    return true
end
-- @ama-summary: Refresh the cached destination list and its availability reason.
function Library:refresh()
    local ok,accepted,why=pcall(self.scan,self)
    if not ok then
        self.available=false;self.writable=false;self.entries={}
        self.reason="DESTINATION DISK UNAVAILABLE: "..tostring(accepted)
        return false,self.reason
    end
    return accepted,why
end
-- @ama-summary: Apply and persist an accepted destination-library edit.
function Library:change(operation,index,entry)
    if not self:refresh() then return false,self.reason end
    if not self.writable then return false,self.reason end
    local nextEntries=copy(self.entries)
    if operation=="save" then nextEntries[#nextEntries+1]=copy(entry)
    elseif type(index)~="number" or index%1~=0 or not nextEntries[index] then return false,"SELECT A SAVED DESTINATION"
    elseif operation=="rename" then nextEntries[index].name=entry.name
    elseif operation=="delete" then table.remove(nextEntries,index)
    else return false,"UNKNOWN LIBRARY ACTION" end
    local value=copy(self.document or {schemaVersion=1});value.destinations=nextEntries
    local valid,why=Library.validate(value);if not valid then return false,why end
    local encoded=self.json.serializeJSON(value)
    if #encoded>65536 then return false,"DESTINATION LIBRARY TOO LARGE" end
    local free=self.fs.getFreeSpace(self.media.path)
    if free~="unlimited" and (type(free)~="number" or free<#encoded+1024) then return false,"DESTINATION DISK FULL" end
    local expected=self.media
    local ok,issue=pcall(function()
        local temp,backup=self.path..".tmp",self.path..".bak"
        local h=assert(self.fs.open(temp,"w"),"DESTINATION DISK WRITE FAILED")
        h.write(encoded);h.close()
        local checked=assert(self:read(temp))
        assert(#checked.destinations==#nextEntries,"DESTINATION WRITE VERIFICATION FAILED")
        local current=assert(self:mount())
        assert(current.name==expected.name and current.path==expected.path and current.id==expected.id,"DESTINATION DISK CHANGED")
        if self.fs.exists(self.path) then
            if self.fs.exists(backup) then self.fs.delete(backup) end
            self.fs.move(self.path,backup)
        end
        self.fs.move(temp,self.path)
        if self.fs.exists(backup) then self.fs.delete(backup) end
    end)
    if not ok then self:refresh();return false,"DESTINATION SAVE FAILED: "..tostring(issue) end
    self.entries=nextEntries;return true,"DESTINATION LIBRARY SAVED"
end
function Library:snapshot(now)
    if not self.at or now-self.at>=1 then self:refresh();self.at=now end
    return {available=self.available,writable=self.writable,reason=self.reason,entries=copy(self.entries)}
end
return Library
