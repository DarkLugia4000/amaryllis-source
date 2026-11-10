-- Temporary commissioning program. The tiny startup launcher stays in place;
-- this file deletes itself only after the durable package receipt verifies.
local console="/avionics/common/console.lua"

-- Fresh computers have no shared console yet. Receive and validate the
-- trusted core registry concurrently with the package downloader.
local PROTOCOL="amaryllis.v1"
local safeTokenPattern="^[%w_%.%-:]+$"
local function isInteger(value)
    return type(value) == "number" and value == value and value ~= math.huge
        and value ~= -math.huge and value == math.floor(value)
end

local function validToken(value)
    return type(value) == "string" and #value > 0 and #value <= 128
        and value:match(safeTokenPattern) ~= nil
end

local function validLabel(value)
    return type(value) == "string" and #value > 0 and #value <= 64
        and value:match("^[%w%._%-]+$") ~= nil
end

local function acceptRegistry(sender, message, protocol, role, localID, trustedCoreID)
    if not isInteger(trustedCoreID) or sender ~= trustedCoreID or protocol ~= PROTOCOL or type(message) ~= "table"
        or message.v ~= 1 or message.kind ~= "fleet_registry" or message.coreID ~= trustedCoreID
        or not validToken(message.session) or type(message.computers) ~= "table"
        or type(role) ~= "string" or not isInteger(localID) then return false end

    local previous = os.__amaryllisFleetRegistry
    local retired = os.__amaryllisRetiredCoreSessions or {}
    if type(retired) ~= "table" or retired[message.session] then return false end
    local function clearPreviousIdentity()
        if type(previous) ~= "table" or previous.coreID ~= trustedCoreID then return end
        if validToken(previous.session) and previous.session ~= message.session then
            retired[previous.session] = true
            os.__amaryllisRetiredCoreSessions = retired
        end
        os.__amaryllisFleetRegistry = nil
        os.__amaryllisIdentity = nil
        pcall(os.queueEvent, "amaryllis_registry_changed", message.session)
    end

    local ids, labels = {}, {}
    for otherRole, other in pairs(message.computers) do
        if type(otherRole) ~= "string" or type(other) ~= "table" then return false end
        if other.id ~= nil then
            if not isInteger(other.id) or other.id < 0 or ids[other.id] then return false end
            ids[other.id] = otherRole
        end
        if other.label ~= nil then
            if not validLabel(other.label) or labels[other.label] then return false end
            labels[other.label] = otherRole
        end
    end

    local core = message.computers.core
    if type(core) ~= "table" or core.id ~= trustedCoreID or not validLabel(core.label) then return false end
    local resolvedRole = role
    if role == "auto" then
        resolvedRole = nil
        for candidateRole, candidate in pairs(message.computers) do
            if candidateRole ~= "core" and type(candidate) == "table" and candidate.id == localID then
                if resolvedRole ~= nil then return false end
                resolvedRole = candidateRole
            end
        end
    end
    if type(resolvedRole) ~= "string" or resolvedRole == "core" then
        if role == "auto" then clearPreviousIdentity() end
        return false
    end
    local entry = message.computers[resolvedRole]
    if type(entry) ~= "table" or entry.id ~= localID or not validLabel(entry.label) then
        clearPreviousIdentity()
        return false
    end
    if type(previous) == "table" and validToken(previous.session) and previous.session ~= message.session then
        retired[previous.session] = true
        os.__amaryllisRetiredCoreSessions = retired
    end
    local computers = {}
    for otherRole, other in pairs(message.computers) do
        computers[otherRole] = { id = other.id, label = other.label }
    end
    os.__amaryllisFleetRegistry = { coreID = trustedCoreID, session = message.session,
        computers = computers, receivedAt = os.clock() }
    os.__amaryllisIdentity = { role = resolvedRole, computerID = localID, label = entry.label,
        coreID = trustedCoreID }
    if type(previous) == "table" and (previous.session ~= message.session
        or type(previous.computers) ~= "table" or type(previous.computers[resolvedRole]) ~= "table"
        or previous.computers[resolvedRole].id ~= entry.id or previous.computers[resolvedRole].label ~= entry.label) then
        pcall(os.queueEvent, "amaryllis_registry_changed", message.session)
    end
    return true
end


local installer=assert(loadfile("/installer.lua"))()
local config=assert(installer.readJSON("/config.json"))
local function completed()
    local status=installer.readJSON("/installer/status.json")
    local application=installer.readJSON("/avionics/config.json")
    local registration=installer.readJSON("/amaryllis-install.json")
    local receipt=type(application)=="table" and application.install
    if type(status)~="table" or status.state~="installed" or status.hasInstalled~=true or status.recoveryRequired~=false or
        type(receipt)~="table" or receipt.protocol~="amaryllis.install.v1" or
        type(registration)~="table" or registration.id~=os.getComputerID() or registration.pending~=false or
        receipt.role~=registration.role or receipt.computerID~=os.getComputerID() or receipt.coreID~=(config.core_id or config.server_id) or
        type(receipt.version)~="number" or receipt.version<2 or type(receipt.manifestChecksum)~="string" or
        not validToken(receipt.clientSession) or not validToken(receipt.serverSession) or not validToken(receipt.coreSession) or
        not validToken(receipt.installID) or not validLabel(receipt.label) or os.getComputerLabel()~=receipt.label then return false end
    for _,suffix in ipairs({"",".bak",".tmp"}) do if fs.exists("/installer/commit.json"..suffix) then return false end end
    for statusKey,receiptKey in pairs({installedRole="role",installedPackageId="packageId",installedVersion="version",
        installedManifestChecksum="manifestChecksum",installedComputerID="computerID",installedCoreID="coreID",installedLabel="label",
        installedInstallID="installID",installedClientSession="clientSession",installedServerSession="serverSession",installedCoreSession="coreSession"}) do
        if receipt[receiptKey]==nil or status[statusKey]~=receipt[receiptKey] then return false end
    end
    return fs.exists(console) and fs.exists("/avionics/main.lua")
end
local function finishIfComplete()
    if not completed() then return false end
    -- Preserve the updater, trust config, recovery records and receipt. Deleting
    -- one helper is atomic; the permanent launcher already has its normal path.
    fs.delete("/installer/commissioning.lua")
    os.reboot()
    return true
end
-- A completed commit may have survived a restart just before UI cleanup.
-- Check it before starting the downloader, even if core is currently offline.
if finishIfComplete() then return end
parallel.waitForAny(function() installer.run(config) end,function()
    while true do
        if finishIfComplete() then return end
        sleep(.5)
    end
end,function()
    local coreID=config.core_id or config.server_id
    if not isInteger(coreID) or coreID<0 then error("Invalid bootstrap core ID") end
    while true do
        local sender,message,protocol=rednet.receive(PROTOCOL,1)
        acceptRegistry(sender,message,protocol,"auto",os.getComputerID(),coreID)
    end
end,function()
    local labels={waiting_for_registry="Waiting for assignments from core",listening="Waiting for core's package offer",
        downloading="Receiving role package",committing="Verifying and committing package",installed="Checking installation receipt",
        retrying="Retrying transfer",recovery_required="Package recovery needs attention"}
    local roles={navigator="Bridge navigator",["heading-left"]="Left heading display",["heading-right"]="Right heading display",
        ["heading-main"]="Main heading display",chamber_fl="Front-left lift chamber",chamber_fr="Front-right lift chamber",
        chamber_bl="Rear-left lift chamber",chamber_br="Rear-right lift chamber",primary_l="Left primary controller",
        primary_r="Right primary controller",["thrust-lb"]="Front-left thrust",["thrust-rb"]="Front-right thrust",
        ["thrust-ls"]="Rear-left thrust",["thrust-rs"]="Rear-right thrust"}
    while true do
        term.clear();term.setCursorPos(1,1)
        print("AMARYLLIS INSTALLATION | #"..os.getComputerID())
        local registration=installer.readJSON("/amaryllis-install.json") or {}
        print("Role: "..tostring(roles[registration.role] or os.getComputerLabel() or "Unassigned"))
        print("Core: #"..tostring(config.core_id or config.server_id));print("")
        local status=installer.readJSON("/installer/status.json") or {}
        print(labels[status.state] or tostring(status.state or "Starting"))
        if status.detail then print(tostring(status.detail)) end
        print("");print("This screen disappears after verification.")
        print("Wrong role? Hold Ctrl+T and run the loader")
        print("again, or boot the setup disk, before core imports.")
        sleep(1)
    end
end)
