-- @ama-section: Package cache | Verified source-object lookup by fingerprint.
-- Installer-local verified payloads. No fleet identity, receipts or flight state.
local Cache={}
Cache.__index=Cache
local function finite(n) return type(n)=="number" and n==n and n~=math.huge and n~=-math.huge end
-- @ama-section: Package cache | Verified source-object lookup by fingerprint.
-- @ama-summary: Build a deterministic identity string from the configured source inventory.
local function fingerprint(fs,paths)
    if type(fs.attributes)~="function" then return nil end
    local parts={}
    for _,path in ipairs(paths) do
        local ok,a=pcall(fs.attributes,path)
        if not ok or type(a)~="table" or a.isDir~=false or not finite(a.size)
            or a.size<0 or a.size~=math.floor(a.size) or not finite(a.modified) or a.modified<=0 then return nil end
        parts[#parts+1]=path.."\0"..tostring(a.size).."\0"..tostring(a.modified)
    end
    return table.concat(parts,"\n")
end
function Cache.new(fs,now,options)
    options=options or {}
    return setmetatable({fs=fs,now=now,entries={},bytes=0,count=0,serial=0,hits=0,misses=0,
        maxBytes=options.maxBytes or 8388608,maxEntries=options.maxEntries or 14,
        checkSeconds=options.checkSeconds or 5},Cache)
end
function Cache:drop(key)
    local e=self.entries[key]
    if e then self.bytes=self.bytes-e.bundle.totalBytes;self.count=self.count-1;self.entries[key]=nil end
end
-- @ama-summary: Resolve a verified installer object by its content fingerprint.
function Cache:get(key,paths,loader,force)
    self.serial=self.serial+1
    local now=self.now()
    local e=self.entries[key]
    if e and not force and now>=e.checked and now-e.checked<self.checkSeconds then
        e.used=self.serial;self.hits=self.hits+1;return e.bundle,nil,true
    end
    local before=fingerprint(self.fs,paths)
    if e and not force and before and before==e.fingerprint then
        e.checked,e.used=now,self.serial;self.hits=self.hits+1;return e.bundle,nil,true
    end
    self:drop(key)
    self.misses=self.misses+1
    local bundle,issue=loader()
    if not bundle then return nil,issue,false end
    -- Sources may change while the paced loader yields. Never cache/send a mixed generation.
    local after=fingerprint(self.fs,paths)
    if before and after~=before then return nil,"package sources changed during verification; retrying",false end
    if before and after and finite(bundle.totalBytes) and bundle.totalBytes>=0 and bundle.totalBytes<=self.maxBytes then
        while self.count>=self.maxEntries or self.bytes+bundle.totalBytes>self.maxBytes do
            local oldest,used
            for k,v in pairs(self.entries) do if not used or v.used<used then oldest,used=k,v.used end end
            if not oldest then break end
            self:drop(oldest)
        end
        if self.maxEntries>0 then
            self.entries[key]={bundle=bundle,fingerprint=after,checked=self.now(),used=self.serial}
            self.count,self.bytes=self.count+1,self.bytes+bundle.totalBytes
        end
    end
    -- Missing/unsupported metadata uses full paced verification every time.
    return bundle,nil,false
end
return Cache
