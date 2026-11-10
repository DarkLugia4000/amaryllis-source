-- Bundle-local loader. Every shell task receives its own environment/module cache.
-- JSON, hardware, os events and shared supervisor contexts remain native.
local base=_ENV
local nativeFS,nativeShell=fs,shell
local function physicalAttributes()
    if not nativeFS.attributes then return nil end
    local ok,value=pcall(nativeFS.attributes,bundlePath)
    return ok and value or nil
end
local loadedAttributes=physicalAttributes()
local env=setmetatable({},{__index=base})
env._G=env
-- Summary: Resolve relative paths from the shell directory and collapse dot segments.
local function path(value)
    if type(value)~="string" then return nil end
    if value:sub(1,1)~="/" then
        local cwd=nativeShell and nativeShell.dir and nativeShell.dir() or ""
        value=cwd.."/"..value
    end
    local parts={}
    for part in value:gmatch("[^/]+") do
        if part==".." then parts[#parts]=nil elseif part~="." then parts[#parts+1]=part end
    end
    return "/"..table.concat(parts,"/")
end
local directories={}
for name in pairs(sources) do
    local parent=name:match("^(.*)/[^/]+$")
    while parent and parent~="" do directories[parent]=true;parent=parent:match("^(.*)/[^/]+$") end
end
-- Summary: Expose embedded source bytes as a file handle with a read cursor and close state.
local function memoryFile(data,binary)
    local offset,closed=1,false
    local function active() assert(not closed,"attempt to use a closed file") end
    return {
        readAll=function() active();local value=data:sub(offset);offset=#data+1;return value end,
        read=function(count)
            active();if offset>#data then return nil end
            if binary and count==nil then local n=data:byte(offset);offset=offset+1;return n end
            count=count or 1;assert(type(count)=="number" and count>=0,"invalid read count")
            local value=data:sub(offset,offset+count-1);offset=offset+#value;return value
        end,
        -- Summary: Return the next line from embedded bytes and optionally include its newline.
        readLine=function(trailing)
            active();if offset>#data then return nil end
            local ending=data:find("\n",offset,true)
            local value=data:sub(offset,ending and (trailing and ending or ending-1) or #data)
            offset=ending and ending+1 or #data+1
            if not trailing then value=value:gsub("\r$","") end
            return value
        end,
        seek=function(whence,amount)
            active();whence=whence or "cur";amount=amount or 0
            local origin=whence=="set" and 0 or (whence=="cur" and offset-1 or (whence=="end" and #data))
            assert(origin,"invalid seek origin");if origin+amount<0 then return nil,"negative seek" end
            offset=origin+amount+1;return offset-1
        end,
        close=function() closed=true;data="" end
    }
end
env.fs={};for k,v in pairs(nativeFS) do env.fs[k]=v end
env.fs.exists=function(name) local p=path(name);return sources[p]~=nil or directories[p]==true or nativeFS.exists(name) end
env.fs.isDir=function(name) local p=path(name);if sources[p] then return false end;return directories[p]==true or nativeFS.isDir(name) end
env.fs.isReadOnly=function(name) if sources[path(name)] then return true end;return nativeFS.isReadOnly(name) end
-- Summary: Serve embedded modules as in-memory read handles and delegate other files to native storage.
env.fs.open=function(name,mode)
    local data=sources[path(name)]
    if data then
        if mode~="r" and mode~="rb" then return nil,"Bundled source is read only; rebuild the installer to change it" end
        return memoryFile(data,mode=="rb")
    end
    return nativeFS.open(name,mode)
end
env.fs.getSize=function(name) local data=sources[path(name)];if data then return #data end;return nativeFS.getSize(name) end
env.fs.attributes=function(name)
    local p=path(name);if sources[p] or directories[p] then return {size=sources[p] and #sources[p] or 0,isDir=directories[p]==true,created=0,modified=0} end
    return nativeFS.attributes(name)
end
env.fs.list=function(name)
    local p=path(name);local found={}
    if nativeFS.exists(name) and nativeFS.isDir(name) then for _,child in ipairs(nativeFS.list(name)) do found[child]=true end end
    local prefix=p=="/" and "/" or p.."/"
    for source in pairs(sources) do if source:sub(1,#prefix)==prefix then found[source:sub(#prefix+1):match("^[^/]+")]=true end end
    local result={};for child in pairs(found) do result[#result+1]=child end;table.sort(result);return result
end
for _,method in ipairs({"delete","move","copy"}) do
    local operation=method
    if nativeFS[operation] then env.fs[operation]=function(first,second)
        assert(not sources[path(first)] and not sources[path(second)],"Bundled source is read only")
        return nativeFS[operation](first,second)
    end end
end
-- Summary: Compile embedded Lua with its original module path or delegate to the native loader.
env.loadfile=function(name,mode,target)
    local p=path(name);local data=sources[p]
    -- A resident console may survive an application update. Its next runtime
    -- launch must enter the newly committed physical bundle with a fresh cache.
    if data and loadedAttributes and (p==defaultEntry or p=="/avionics/main.lua") then
        local current=physicalAttributes()
        if not current then return nil,"Runtime bundle unavailable during replacement" end
        if current.size~=loadedAttributes.size or current.modified~=loadedAttributes.modified then
            local chunk,issue=base.loadfile(bundlePath,mode or "t",base)
            if not chunk then return nil,issue end
            return function(...) return chunk("__amaryllis_bundle_entry_v1",p,...) end
        end
    end
    if data then return load(data,"@"..p,mode or "t",target or env) end
    -- The permanent package updater verifies/writes physical files, including
    -- this bundle. It must not see virtual source files in the application view.
    return base.loadfile(name,mode,p=="/installer.lua" and base or (target or env))
end
env.dofile=function(name) return assert(env.loadfile(name))() end
env.package={};for k,v in pairs(base.package or {}) do env.package[k]=v end
env.package.loaded={};env.package.preload={}
local loading={}
-- Summary: Resolve modules through the bundle environment and cache their exports per execution environment.
env.require=function(name)
    assert(type(name)=="string","module name must be a string")
    if env.package.loaded[name]~=nil then return env.package.loaded[name] end
    local modulePath=name:gsub("%.","/")
    local candidates={"/"..modulePath..".lua","/avionics/"..modulePath..".lua"}
    for template in (env.package.path or "/avionics/?.lua"):gmatch("[^;]+") do candidates[#candidates+1]=path(template:gsub("%?",modulePath)) end
    local selected
    for _,candidate in ipairs(candidates) do if sources[candidate] then selected=candidate;break end end
    if not selected then return base.require(name) end
    assert(not loading[name],"circular bundled module: "..name);loading[name]=true
    local chunk,issue=env.loadfile(selected,"t",env);assert(chunk,issue)
    local ok,value=pcall(chunk,name,selected);loading[name]=nil
    if not ok then error(value,0) end
    if value==nil then value=env.package.loaded[name];if value==nil then value=true end end
    env.package.loaded[name]=value;return value
end
env.shell={};for k,v in pairs(nativeShell or {}) do env.shell[k]=v end
local function redirect(name,...)
    local p=path(name)
    if not sources[p] and sources[p..".lua"] then p=p..".lua" end
    if sources[p] then return bundlePath,"__amaryllis_bundle_entry_v1",p,... end
    return name,...
end
if nativeShell and nativeShell.openTab then env.shell.openTab=function(name,...) return nativeShell.openTab(redirect(name,...)) end end
if nativeShell and nativeShell.run then env.shell.run=function(name,...) return nativeShell.run(redirect(name,...)) end end
local args={...};local entry=defaultEntry
if args[1]=="__amaryllis_bundle_entry_v1" then
    entry=path(args[2]);table.remove(args,1);table.remove(args,1)
end
assert(sources[entry],"Unknown bundled entry point: "..tostring(entry))
env.shell.getRunningProgram=function() return entry end
return assert(env.loadfile(entry,"t",env))(table.unpack(args))
