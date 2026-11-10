-- Read-only package source. Flight never reads removable media through this module.
-- A web-installed core (/installer/web/source.json) fetches package objects from
-- its pinned web release; otherwise they come from the matching installer disk.
local Media={};Media.__index=Media
local WEB_SOURCE="/installer/web/source.json"
local function read(native,path,limit)
    local h=native.open(path,"r");if not h then return nil end
    local ok,value=pcall(h.read,limit+1);pcall(h.close)
    if ok and type(value)=="string" and #value<=limit then return value end
end
local function pathOK(path)
    return type(path)=="string" and path:match("^/packages/[A-Za-z0-9_./%-]+$") and
        not path:find("..",1,true) and not path:find("//",1,true)
end
function Media.new(native,peripherals,disks,json,yield,web)
    local raw=assert(read(native,"/installer/library.json",65536) or
        read(native,"/installer/library.json.amaryllis-backup",65536),"Trusted package catalog unavailable")
    local catalog=assert(json.unserializeJSON(raw),"Invalid trusted package catalog")
    assert(catalog.schemaVersion==1 and type(catalog.files)=="table" and #catalog.files<=256 and
        type(catalog.libraryId)=="string" and #catalog.libraryId==64,"Unsupported package catalog")
    local self=setmetatable({native=native,peripherals=peripherals,disks=disks,json=json,yield=yield,
        raw=raw,entries={},generation=0,issue="Insert the matching installer disk"},Media)
    local source=read(native,WEB_SOURCE,4096);source=source and json.unserializeJSON(source)
    if type(source)=="table" and type(source.base)=="string" and source.base:match("^https://[%w%.%-]+/[%w%.%-_/]+/$") then
        self.webBase=source.base;self.http=web;self.issue=web and "" or "HTTP is disabled; web packages unavailable"
    end
    for _,entry in ipairs(catalog.files) do
        assert(pathOK(entry.path) and not self.entries[entry.path] and type(entry.object)=="string" and
            #entry.object==64 and entry.object:match("^[0-9a-f]+$") and type(entry.bytes)=="number" and
            entry.bytes>0 and entry.bytes<=524288 and entry.bytes%1==0 and
            type(entry.adler32)=="string" and entry.adler32:match("^[0-9A-F]+$") and #entry.adler32==8,"Unsafe catalog entry")
        self.entries[entry.path]=entry
    end
    self.fs={};for k,v in pairs(native) do self.fs[k]=v end
    self.fs.open=function(path,mode)
        if type(path)~="string" or path:sub(1,10)~="/packages/" then return native.open(path,mode) end
        if mode~="r" then return nil,"Package media is read only" end
        return self:open(path)
    end
    self.fs.attributes=function(path)
        if type(path)~="string" or path:sub(1,10)~="/packages/" then return native.attributes(path) end
        local entry=self.entries[path]
        if not entry or not self:valid(self.generation) then return nil end
        return {size=entry.bytes,modified=self.generation,isDir=false}
    end
    self.fs.exists=function(path)
        if type(path)~="string" or path:sub(1,10)~="/packages/" then return native.exists(path) end
        return self.entries[path]~=nil and self:valid(self.generation)
    end
    return self
end
function Media:valid(generation)
    if self.webBase then return self.http~=nil and generation==self.generation end
    local current=self.current
    if not current or generation~=self.generation then return false end
    local mountOK,mount=pcall(self.disks.getMountPath,current.name)
    local idOK,id=pcall(self.disks.getID,current.name)
    if not mountOK or not idOK or mount~=current.mount or id~=current.id or
        not self.native.exists(current.path) then self.current=nil;return false end
    -- Detect catalog edits without rereading it for every wireless chunk.
    local ok,attributes=pcall(self.native.attributes,current.path)
    if not ok or not attributes or attributes.size~=#self.raw or attributes.modified~=current.modified then
        if read(self.native,current.path,65536)~=self.raw then self.current=nil;return false end
    end
    return true
end
function Media:refresh()
    if self.webBase then return self.http~=nil end
    local candidates={}
    local ok,names=pcall(self.peripherals.getNames)
    if ok and type(names)=="table" then
        for index,name in ipairs(names) do
            if index>256 then break end
            local mounted,mount=pcall(self.disks.getMountPath,name)
            local identified,id=pcall(self.disks.getID,name)
            if mounted and identified and type(mount)=="string" and type(id)=="number" then
                local path=self.native.combine(mount,"library.json")
                if read(self.native,path,65536)==self.raw then
                    local attrOK,attributes=pcall(self.native.attributes,path)
                    candidates[#candidates+1]={name=name,mount=mount,id=id,path=path,
                        modified=attrOK and attributes and attributes.modified or nil}
                end
            end
        end
    end
    if #candidates~=1 then
        self.current=nil
        self.issue=#candidates>1 and "Several matching disks: leave one connected" or "Insert the matching installer disk; use disk setup to adopt a newer library"
        return false
    end
    local candidate=candidates[1];local old=self.current
    if not old or old.name~=candidate.name or old.mount~=candidate.mount or old.id~=candidate.id then
        self.generation=self.generation+1
    end
    self.current=candidate;self.issue=""
    return true
end
function Media:open(path)
    local entry=self.entries[path];local generation=self.generation
    if not entry then return nil,"Package is absent from trusted catalog" end
    if not self:valid(generation) then return nil,self.webBase and self.issue or "Installer disk unavailable" end
    if self.webBase then return self:openWeb(entry) end
    local native=self.native
    local h,issue=native.open(native.combine(self.current.mount,"objects/"..entry.object),"r")
    if not h then return nil,issue or "Package object missing from disk" end
    local parts,total,a,b={},0,1,0
    local ok,why=pcall(function()
        while true do
            if not self:valid(generation) then error("Installer disk removed or changed",0) end
            local chunk=h.read(math.min(8192,entry.bytes-total+1))
            if not chunk or chunk=="" then break end
            total=total+#chunk;assert(total<=entry.bytes,"Package object exceeds catalog size")
            parts[#parts+1]=chunk
            for i=1,#chunk do a=(a+chunk:byte(i))%65521;b=(b+a)%65521 end
            self.yield(0)
        end
        assert(self:valid(generation),"Installer disk removed or changed")
        assert(total==entry.bytes and string.format("%04X%04X",b,a)==entry.adler32,"Package object checksum mismatch")
    end)
    pcall(h.close)
    if not ok then return nil,tostring(why) end
    local data=table.concat(parts);local offset=1;local closed=false
    return {read=function(count)
        assert(not closed,"File closed");assert(self:valid(generation),"Installer disk removed or changed")
        if offset>#data then return nil end
        local value=data:sub(offset,offset+(count or 1)-1);offset=offset+#value;return value
    end,readAll=function()
        assert(not closed,"File closed");assert(self:valid(generation),"Installer disk removed or changed")
        local value=data:sub(offset);offset=#data+1;return value
    end,close=function() closed=true;data="" end}
end
function Media:openWeb(entry)
    local response,why=self.http.get({url=self.webBase.."objects/"..entry.object,binary=true})
    if not response then return nil,"Package download failed: "..tostring(why) end
    local code=response.getResponseCode();local data=response.readAll() or "";response.close()
    if code~=200 then return nil,"Package download failed: HTTP "..tostring(code) end
    if #data~=entry.bytes then return nil,"Package object size differs from catalog" end
    local a,b=1,0
    for i=1,#data do
        a=(a+data:byte(i))%65521;b=(b+a)%65521
        if i%65536==0 then self.yield(0) end
    end
    if string.format("%04X%04X",b,a)~=entry.adler32 then return nil,"Package object checksum mismatch" end
    local offset,closed=1,false
    return {read=function(count)
        assert(not closed,"File closed")
        if offset>#data then return nil end
        local value=data:sub(offset,offset+(count or 1)-1);offset=offset+#value;return value
    end,readAll=function()
        assert(not closed,"File closed")
        local value=data:sub(offset);offset=#data+1;return value
    end,close=function() closed=true;data="" end}
end
return Media
