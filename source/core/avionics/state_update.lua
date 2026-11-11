-- Section: State reader web update | Stage the state reader's own update when core asks for it.
--
-- During a web update core sends one packet over the wired state link:
--   {protocol="amaryllis.state.v1", kind="state_update", sender=<core ID>,
--    target=<this computer's ID>, base=<release address>, releaseId=<release>}
-- The packet is accepted only from the configured core, addressed to this
-- computer, with a release address on raw.githubusercontent.com that names a
-- full commit (the form the Pastebin loader pins). Staging downloads the
-- release index and the release's web-setup.lua, checks the file's length and
-- Adler-32 checksum against the index, and writes:
--   /amaryllis-web/web-setup.lua      the new release's web setup
--   /amaryllis-web/update.json        {base, releaseId, coreID}
--   /amaryllis-web/state-startup.lua  the state reader's own startup, kept once
--   /startup.lua                      a boot program that runs that web setup
-- The caller then acknowledges and restarts. After the restart web-setup.lua
-- finds update.json, replaces the state reader's programs with its settings
-- kept, and writes the new startup program last. If that fails before any
-- program file changed, web-setup.lua puts the kept startup back.
local StateUpdate={}

local PROTOCOL="amaryllis.state.v1"
local MEDIA="/amaryllis-web"
local MARKER=MEDIA.."/update.json"
local SAVED_STARTUP=MEDIA.."/state-startup.lua"
local BOOT='assert(loadfile("/amaryllis-web/web-setup.lua",nil,_ENV))()\n'
local BASE_PATTERN="^https://raw%.githubusercontent%.com/[%w%-%._]+/[%w%-%._]+/%x+/media/$"
local MAX_SETUP_BYTES=262144

StateUpdate.MEDIA=MEDIA
StateUpdate.MARKER=MARKER
StateUpdate.SAVED_STARTUP=SAVED_STARTUP

-- Adler-32 of data as eight upper-case hex digits, the format release indexes use.
local function adler(data)
    local a,b=1,0
    for i=1,#data do a=(a+data:byte(i))%65521;b=(b+a)%65521 end
    return string.format("%04X%04X",b,a)
end

-- Download url as raw bytes. Returns the body for HTTP 200; otherwise nil and
-- a reason naming the address and the HTTP status or transport error.
local function fetch(http,url)
    local ok,response,why=pcall(http.get,{url=url,binary=true})
    if not ok then return nil,"download failed: "..url.." ("..tostring(response)..")" end
    if not response then return nil,"download failed: "..url.." ("..tostring(why)..")" end
    local code=response.getResponseCode();local data=response.readAll() or "";response.close()
    if code~=200 then return nil,"download failed: "..url.." (HTTP "..tostring(code)..")" end
    return data
end

-- Write data to path, creating its folder. Returns true, or nil and a reason.
local function writeFile(fs,path,data)
    local dir=fs.getDir(path)
    if dir~="" and not fs.exists(dir) then fs.makeDir(dir) end
    local handle,why=fs.open(path,"wb")
    if not handle then return nil,"cannot write "..path.." ("..tostring(why)..")" end
    handle.write(data);handle.close()
    return true
end

-- True when packet is a state_update request this state reader should act on:
-- right protocol and kind, sent by the configured core (cfg.coreID), addressed
-- to this computer (cfg.computerID), with a pinned release address and a
-- release ID of 1 to 128 characters.
function StateUpdate.valid(packet,cfg)
    return type(packet)=="table" and packet.protocol==PROTOCOL and packet.kind=="state_update" and
        type(cfg)=="table" and packet.sender==cfg.coreID and packet.target==cfg.computerID and
        type(packet.base)=="string" and packet.base:match(BASE_PATTERN)~=nil and
        type(packet.releaseId)=="string" and #packet.releaseId>=1 and #packet.releaseId<=128
end

-- Download and check the new web setup, then point this computer's boot at it.
-- Nothing is written until the download is checked. The state reader's own
-- startup is kept in SAVED_STARTUP the first time only, so a repeated request
-- never overwrites it with the boot program. Returns true, or nil and a reason.
function StateUpdate.stage(packet,deps)
    local fs,http,textutils=deps.fs,deps.http,deps.textutils
    if not http then return nil,"HTTP is disabled on the state reader" end
    local rawIndex,why=fetch(http,packet.base.."download.json")
    if not rawIndex then return nil,why end
    local index=textutils.unserializeJSON(rawIndex)
    if type(index)~="table" or index.schemaVersion~=1 or type(index.files)~="table" then
        return nil,"release index unreadable"
    end
    if index.releaseId~=packet.releaseId then return nil,"release index names "..tostring(index.releaseId) end
    local entry
    for _,candidate in ipairs(index.files) do
        if type(candidate)=="table" and candidate.path=="web-setup.lua" then entry=candidate end
    end
    if not entry or type(entry.bytes)~="number" or entry.bytes<1 or entry.bytes>MAX_SETUP_BYTES then
        return nil,"release index lacks web-setup.lua"
    end
    local setup
    setup,why=fetch(http,packet.base.."web-setup.lua")
    if not setup then return nil,why end
    if #setup~=entry.bytes or adler(setup)~=entry.adler32 then return nil,"web-setup.lua checksum mismatch" end
    local ok
    ok,why=writeFile(fs,MEDIA.."/web-setup.lua",setup);if not ok then return nil,why end
    ok,why=writeFile(fs,MARKER,textutils.serializeJSON({base=packet.base,releaseId=packet.releaseId,coreID=packet.sender}))
    if not ok then return nil,why end
    if not fs.exists(SAVED_STARTUP) and fs.exists("/startup.lua") then fs.move("/startup.lua",SAVED_STARTUP) end
    ok,why=writeFile(fs,"/startup.lua",BOOT);if not ok then return nil,why end
    return true
end

-- Handle one wired packet that may be a state_update request. Returns nil for
-- any packet that is not a valid request for this computer (it is ignored and
-- not answered). Otherwise returns the acknowledgement for core,
--   {protocol, kind="state_update_ack", sender=this computer, target=core,
--    releaseId, ok, error}
-- and true when staging succeeded and the caller should restart.
function StateUpdate.handle(packet,cfg,deps)
    if not StateUpdate.valid(packet,cfg) then return nil,false end
    local ok,issue=StateUpdate.stage(packet,deps)
    return {protocol=PROTOCOL,kind="state_update_ack",sender=cfg.computerID,target=cfg.coreID,
        releaseId=packet.releaseId,ok=ok==true,error=not ok and tostring(issue) or nil},ok==true
end

return StateUpdate
