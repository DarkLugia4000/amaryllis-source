-- Bootstrap-side client for the Amaryllis v1 install protocol.
-- The JSON config supplies trusted server/client identity. Incoming file names never become paths.
local Installer = {}

local PROTOCOL = "amaryllis.install.v1"
local REGISTRY_PROTOCOL = "amaryllis.v1"
local DEFAULT_CORE_ID = 35
local DESTINATIONS_BY_ROLE = {
  navigator = { "/avionics/main.lua", "/avionics/config.json", "/avionics/storage.lua", "/avionics/ui.lua", "/avionics/common/console.lua", "/avionics/diagnostics.lua" },
  ["heading-left"] = { "/avionics/main.lua", "/avionics/config.json", "/avionics/common/console.lua", "/avionics/diagnostics.lua" },
  ["heading-right"] = { "/avionics/main.lua", "/avionics/config.json", "/avionics/common/console.lua", "/avionics/diagnostics.lua" },
  ["heading-main"] = { "/avionics/main.lua", "/avionics/config.json", "/avionics/common/console.lua", "/avionics/diagnostics.lua" },
}
local PACKAGE_IDS = {
  navigator = "amaryllis.navigator",
  ["heading-left"] = "amaryllis.heading.left",
  ["heading-right"] = "amaryllis.heading.right",
  ["heading-main"] = "amaryllis.heading.main",
}
for _, quadrant in ipairs({ "fl", "fr", "bl", "br" }) do
  local role = "chamber_" .. quadrant
  PACKAGE_IDS[role] = "amaryllis.chamber." .. quadrant
  DESTINATIONS_BY_ROLE[role] = { "/avionics/main.lua", "/avionics/config.json", "/avionics/hardware.lua", "/avionics/lift.lua", "/avionics/thrust.lua", "/avionics/common/console.lua", "/avionics/diagnostics.lua" }
end
for _,suffix in ipairs({"lb","rb","ls","rs"}) do
  local role="thrust-"..suffix
  PACKAGE_IDS[role]="amaryllis.thrust."..suffix
  DESTINATIONS_BY_ROLE[role]={"/avionics/main.lua","/avionics/config.json","/avionics/hardware.lua","/avionics/thrust.lua",
    "/avionics/chamber_link.lua","/avionics/common/console.lua","/avionics/diagnostics.lua"}
end
for _,q in ipairs({"fl","fr","bl","br"}) do
  local paths=DESTINATIONS_BY_ROLE["chamber_"..q]
  paths[#paths+1]="/avionics/relay.lua"
  paths[#paths+1]="/avionics/chamber_link.lua"
end
for _, side in ipairs({ "l", "r" }) do
  local role = "primary_" .. side
  PACKAGE_IDS[role] = "amaryllis.primary." .. side
  DESTINATIONS_BY_ROLE[role] = { "/avionics/main.lua", "/avionics/config.json", "/avionics/hardware.lua", "/avionics/common/console.lua", "/avionics/diagnostics.lua" }
end
local PATH_KEYS = {
  ["/avionics/relay.lua"] = "relay.lua",
  ["/avionics/chamber_link.lua"] = "chamber_link.lua",
  ["/avionics/main.lua"] = "main.lua",
  ["/avionics/config.json"] = "config.json",
  ["/avionics/storage.lua"] = "storage.lua",
  ["/avionics/ui.lua"] = "ui.lua",
  ["/avionics/hardware.lua"] = "hardware.lua",
  ["/avionics/lift.lua"] = "lift.lua",
  ["/avionics/thrust.lua"] = "thrust.lua",
  ["/avionics/common/console.lua"] = "console.lua",
  ["/avionics/diagnostics.lua"] = "diagnostics.lua",
}
local STAGE, BACKUP = {}, {}
for destination, key in pairs(PATH_KEYS) do
  STAGE[destination] = "/installer/stage/" .. key
  BACKUP[destination] = "/installer/backup/" .. key
end
local JOURNAL = "/installer/commit.json"
local STATUS = "/installer/status.json"
local REINSTALL = "/installer/reinstall"
local COUNTER, COUNTER_TMP, COUNTER_BACKUP = "/installer/boot-counter", "/installer/boot-counter.tmp", "/installer/boot-counter.bak"
local ADLER_MOD = 65521
local function integer(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
    and value >= 0 and value == math.floor(value)
end

local function validId(value)
  if type(value) == "string" then return #value > 0 and #value <= 128 end
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Summary: Compute the Adler-32 checksum of the supplied byte string.
function Installer.adler32(data)
  if type(data) ~= "string" then error("Adler-32 input must be a string") end
  local a, b = 1, 0
  for i = 1, #data do
    a = (a + string.byte(data, i)) % ADLER_MOD
    b = (b + a) % ADLER_MOD
  end
  return string.format("%04X%04X", b, a)
end

function Installer.manifestChecksum(files)
  local rows = {}
  for i, file in ipairs(files) do
    rows[i] = file.path .. "\0" .. tostring(file.size) .. "\0" .. file.checksum .. "\n"
  end
  return Installer.adler32(table.concat(rows))
end

local function numberSetting(config, key, fallback, minimum, maximum)
  local value = config[key]
  if not integer(value) or value < minimum or value > maximum then return fallback end
  return value
end

-- Summary: Validate installer role, protocol, retry and package settings.
local function normalizeConfig(raw)
  if type(raw) ~= "table" then return nil, "bootstrap config is missing" end
  local coreID = raw.core_id or raw.server_id or DEFAULT_CORE_ID
  local config = {
    protocol = raw.protocol,
    serverId = coreID,
    roleHint = raw.target_role,
    role = nil,
    packageId = nil,
    chunkBytes = numberSetting(raw, "chunkBytes", 768, 1, 768),
    maxFileBytes = numberSetting(raw, "maxFileBytes", 262144, 1, 524288),
    maxTotalBytes = numberSetting(raw, "maxTotalBytes", 1048576, 1, 2097152),
    retrySeconds = numberSetting(raw, "retrySeconds", 3, 1, 30),
    offerTimeoutSeconds = numberSetting(raw, "offerTimeoutSeconds", 15, 1, 120),
    heartbeatSeconds = numberSetting(raw, "heartbeatSeconds", 5, 1, 60),
  }
  if config.protocol ~= PROTOCOL then return nil, "unsupported installer protocol in config" end
  if not integer(coreID) then return nil, "bootstrap core ID is invalid" end
  if config.roleHint ~= nil and config.roleHint ~= "auto" and
      (type(config.roleHint) ~= "string" or not DESTINATIONS_BY_ROLE[config.roleHint]) then
    return nil, "target_role hint is not installable"
  end
  return config
end
local function validLabel(value)
  return type(value) == "string" and #value >= 1 and #value <= 64 and value:match("^[%w%._%-]+$") ~= nil
end

local function validToken(value)
  return type(value) == "string" and #value > 0 and #value <= 128 and value:match("^[%w_%.%-:]+$") ~= nil
end

-- Summary: Read the current installed role binding used for request authority.
local function activeBinding(role, computerID, label, coreID, coreSession, deps)
  local system = (deps and deps.os) or os
  local registry = system and system.__amaryllisFleetRegistry
  local entry = type(registry) == "table" and registry.coreID == coreID
    and registry.session == coreSession and type(registry.computers) == "table"
    and registry.computers[role] or nil
  return type(entry) == "table" and entry.id == computerID and entry.label == label
end
-- Summary: Resolve the current computer role from its validated registration.
local function assignedRole(registry, computerID)
  if type(registry) ~= "table" or type(registry.computers) ~= "table" then return nil end
  local found
  for role, entry in pairs(registry.computers) do
    if role ~= "core" and type(entry) == "table" and entry.id == computerID then
      if found then return nil end
      if DESTINATIONS_BY_ROLE[role] then found = role end
    end
  end
  return found
end
local function ensureDirs(filesystem)
  for _, path in ipairs({ "/installer", "/installer/stage", "/installer/backup", "/avionics" }) do
    if not filesystem.exists(path) then filesystem.makeDir(path) end
  end
end

-- Summary: Read a bounded installer file and return its content or read error.
local function readFile(filesystem, path)
  if not filesystem.exists(path) then return nil end
  local handle = filesystem.open(path, "r")
  if not handle then return nil end
  local value = handle.readAll()
  handle.close()
  return value
end

local function writeFile(filesystem, path, value)
  local handle = filesystem.open(path, "w")
  if not handle then return false, "could not open " .. path end
  local ok, err = pcall(function() handle.write(value); handle.close() end)
  if not ok then pcall(function() handle.close() end); return false, tostring(err) end
  return true
end

local function jsonEncode(value, deps)
  if deps and type(deps.encodeJSON) == "function" then return deps.encodeJSON(value) end
  local api = (deps and deps.textutils) or textutils
  if api and type(api.serializeJSON) == "function" then return api.serializeJSON(value) end
  return nil, "JSON encoder is unavailable"
end

-- Summary: Decode JSON through the selected runtime API with validation errors.
local function jsonDecode(value, deps)
  if deps and type(deps.decodeJSON) == "function" then
    local ok, result, detail = pcall(deps.decodeJSON, value)
    if ok then return result, detail end
    return nil, tostring(result)
  end
  local api = (deps and deps.textutils) or textutils
  if api and type(api.unserializeJSON) == "function" then
    local ok, result, detail = pcall(api.unserializeJSON, value)
    if ok then return result, detail end
    return nil, tostring(result)
  end
  return nil, "JSON decoder is unavailable"
end

local function escapeJSON(value)
  return '"' .. tostring(value):gsub('[%z\1-\31\\"]', function(character)
    local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    return escapes[character] or string.format('\\u%04X', string.byte(character))
  end) .. '"'
end

-- Summary: Encode the small installer status record with supported JSON values.
local function basicJSON(object)
  local keys, parts = {}, {}
  for key, value in pairs(object) do
    if type(key) == "string" and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then keys[#keys + 1] = key end
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local value = object[key]
    local encoded = type(value) == "string" and escapeJSON(value) or (type(value) == "boolean" and (value and "true" or "false") or tostring(value))
    parts[#parts + 1] = escapeJSON(key) .. ":" .. encoded
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Summary: Obtain the runtime clock used for installer request timing.
local function clockNow(deps)
  if deps and type(deps.now) == "function" then return deps.now() end
  if os and type(os.epoch) == "function" then
    local ok, value = pcall(os.epoch, "utc")
    if ok and type(value) == "number" then return value end
  end
  if os and type(os.clock) == "function" then return math.floor(os.clock() * 1000) end
  return 0
end

-- Summary: Persist bounded installation phase and progress metadata.
local function writeStatus(filesystem, status, deps)
  status.updatedAt = clockNow(deps)
  local encoded = jsonEncode(status, deps)
  if type(encoded) ~= "string" then encoded = basicJSON(status) end
  local temp, backup = STATUS .. ".tmp", STATUS .. ".bak"
  local ok, err = writeFile(filesystem, temp, encoded)
  if not ok then return false, err end
  local moved, moveErr = pcall(function()
    if filesystem.exists(backup) then filesystem.delete(backup) end
    if filesystem.exists(STATUS) then filesystem.move(STATUS, backup) end
    filesystem.move(temp, STATUS)
  end)
  if not moved then
    pcall(function()
      if filesystem.exists(temp) then filesystem.delete(temp) end
      if filesystem.exists(backup) and not filesystem.exists(STATUS) then filesystem.move(backup, STATUS) end
    end)
    return false, tostring(moveErr)
  end
  return true
end

local function reportStatus(filesystem, status, deps)
  local ok, err = writeStatus(filesystem, status, deps)
  if not ok and deps and type(deps.onStatusError) == "function" then pcall(deps.onStatusError, err) end
  return ok, err
end

-- Summary: Read and validate the installed status record.
local function readStatus(filesystem, deps)
  for _, path in ipairs({ STATUS, STATUS .. ".tmp", STATUS .. ".bak" }) do
    local raw = readFile(filesystem, path)
    if raw then
      local value = jsonDecode(raw, deps)
      if type(value) == "table" then return value end
    end
  end
  return nil
end

-- Summary: Retain verified installed progress when receiving a new service observation.
local function preserveInstalledStatus(target, previous)
  if type(previous) ~= "table" then return target end
  local knownInstalled = previous.hasInstalled == true or previous.state == "installed"
  target.hasInstalled = knownInstalled
  target.recoveryRequired = previous.recoveryRequired == true or previous.state == "committing"
  if knownInstalled then
    local fields = {
      "installedInstallID", "installedClientSession", "installedServerSession",
      "installedManifestChecksum", "installedLabel", "installedVersion", "installedRole",
      "installedPackageId", "installedComputerID", "installedCoreID", "installedCoreSession",
    }
    for _, key in ipairs(fields) do
      if previous[key] ~= nil then target[key] = previous[key] end
    end
    if previous.state == "installed" then
      target.installedInstallID = previous.installedInstallID or previous.installID
      target.installedClientSession = previous.installedClientSession or previous.clientSession
      target.installedServerSession = previous.installedServerSession or previous.serverSession
      target.installedManifestChecksum = previous.installedManifestChecksum or previous.manifestChecksum
      target.installedLabel = previous.installedLabel or previous.label
      target.installedVersion = previous.installedVersion or previous.version
      target.installedRole = previous.installedRole or previous.role
    end
  end
  return target
end

-- Summary: Advance the persistent correlation counter for an installation session.
local function nextCounter(filesystem)
  local function readCounter(path)
    return tonumber(readFile(filesystem, path) or "") or 0
  end
  local value = math.max(readCounter(COUNTER), readCounter(COUNTER_TMP), readCounter(COUNTER_BACKUP)) + 1
  local ok, err = writeFile(filesystem, COUNTER_TMP, tostring(value))
  if not ok then return nil, err end
  local moved, moveErr = pcall(function()
    if filesystem.exists(COUNTER_BACKUP) then filesystem.delete(COUNTER_BACKUP) end
    if filesystem.exists(COUNTER) then filesystem.move(COUNTER, COUNTER_BACKUP) end
    filesystem.move(COUNTER_TMP, COUNTER)
  end)
  if not moved then return nil, tostring(moveErr) end
  return value
end

-- Summary: Construct the current computer installation session identifier.
local function makeSession(filesystem, deps)
  if deps and type(deps.newSession) == "function" then
    local value = deps.newSession()
    if validId(value) then return value end
    return nil, "session generator returned an invalid boot ID"
  end
  local count, err = nextCounter(filesystem)
  if not count then return nil, err end
  return tostring(count) .. "-" .. tostring(clockNow(deps)) .. "-" .. tostring(math.random(0, 2147483646))
end

-- Summary: Read and validate the actual ComputerCraft ID.
local function actualComputerId(config, deps)
  if deps and type(deps.getComputerID) == "function" then return deps.getComputerID() end
  local system = (deps and deps.os) or os
  if system and type(system.getComputerID) == "function" then
    local ok, value = pcall(system.getComputerID)
    if ok then return value end
  end
  return nil
end

-- Summary: Open the configured modem network and report attachment errors.
local function ensureNetwork(deps)
  if deps and type(deps.openNetwork) == "function" then return deps.openNetwork() end
  local network = (deps and deps.rednet) or rednet
  local peripherals = (deps and deps.peripheral) or peripheral
  if not network then return false end
  if not peripherals or type(peripherals.getNames) ~= "function" or type(network.open) ~= "function" then return true end
  local ok, names = pcall(peripherals.getNames)
  if not ok or type(names) ~= "table" then return false end
  local opened = false
  for _, name in ipairs(names) do
    if type(peripherals.getType) == "function" then
      local okType, kind = pcall(peripherals.getType, name)
      if okType and kind=="modem" then
        local wrapped,modem=pcall(peripherals.wrap,name)
        local checked,wireless=false,nil
        if wrapped and type(modem)=="table" and type(modem.isWireless)=="function" then checked,wireless=pcall(modem.isWireless) end
        if checked and wireless==true then
          local ok,result=pcall(network.open,name);if ok and result~=false then opened=true end
        elseif checked and wireless==false then pcall(network.close,name) end
      end
    end
  end
  return opened
end

-- Summary: Send an installation protocol packet to its selected recipient.
local function sendPacket(config, packet, deps)
  if deps and type(deps.send) == "function" then return deps.send(config.serverId, packet, config.protocol) end
  local network = (deps and deps.rednet) or rednet
  if not network or type(network.send) ~= "function" then return false end
  ensureNetwork(deps)
  local ok, result = pcall(network.send, config.serverId, packet, config.protocol)
  return ok and result ~= false
end

-- Summary: Receive and validate the next protocol envelope.
local function receivePacket(config, timeout, deps)
  if deps and type(deps.receive) == "function" then return deps.receive(config.protocol, timeout) end
  local network = (deps and deps.rednet) or rednet
  if not network or type(network.receive) ~= "function" then return nil end
  local ok, sender, packet, protocol = pcall(network.receive, config.protocol, timeout)
  if not ok then return nil end
  return sender, packet, protocol
end

local function waitFor(seconds, deps)
  if deps and type(deps.wait) == "function" then return deps.wait(seconds) end
  if os and type(os.sleep) == "function" then return os.sleep(seconds) end
end

local function stopping(deps)
  return deps and type(deps.shouldStop) == "function" and deps.shouldStop() == true
end

-- Summary: Validate offered package identity, paths, sizes and checksums.
local function validateOffer(value, config, clientSession, computerID, deps)
  if type(value) ~= "table" or value.v ~= 1 or value.kind ~= "offer" then return nil, "not an offer" end
  local destinations = DESTINATIONS_BY_ROLE[config.role]
  if type(destinations) ~= "table" or value.role ~= config.role then return nil, "offer role is not assigned to this receiver" end
  -- Bundled layout v1: exact fixed destinations, with the same role/session,
  -- checksums, transaction staging and rollback validation as loose packages.
  if type(value.files)=="table" and #value.files==3 then
    destinations={"/avionics/main.lua","/avionics/config.json","/avionics/common/console.lua"}
  end
  if value.clientSession ~= clientSession then return nil, "offer belongs to a different boot" end
  if not validId(value.requestID) or not validToken(value.serverSession) then return nil, "offer correlation IDs are invalid" end
  if value.coreID ~= config.serverId or value.computerID ~= computerID or not validLabel(value.label)
    or not validToken(value.coreSession) then return nil, "offer identity or trusted core session is invalid" end
  if value.packageId ~= config.packageId or not integer(value.version) or value.version < 2 then
    return nil, "offer package identity or version is invalid"
  end
  if not activeBinding(config.role, computerID, value.label, config.serverId, value.coreSession, deps) then
    return nil, "offer does not match the active core registry binding"
  end
  if not integer(value.chunkBytes) or value.chunkBytes < 1 or value.chunkBytes > config.chunkBytes then return nil, "offer chunk size is invalid" end
  if type(value.files) ~= "table" or #value.files ~= #destinations then return nil, "offer file list is invalid" end
  local files, total = {}, 0
  for index, path in ipairs(destinations) do
    local file = value.files[index]
    if type(file) ~= "table" or file.path ~= path then return nil, "offer contains a non-allowlisted path" end
    if not integer(file.size) or file.size > config.maxFileBytes then return nil, "offered file size is invalid" end
    if type(file.checksum) ~= "string" or not file.checksum:match("^[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]$") then return nil, "offered checksum is malformed" end
    local chunks = math.max(1, math.ceil(file.size / value.chunkBytes))
    if not integer(file.chunks) or file.chunks ~= chunks then return nil, "offered chunk count does not match file size" end
    total = total + file.size
    if total > config.maxTotalBytes then return nil, "offered total size exceeds the limit" end
    files[index] = { path = path, size = file.size, checksum = file.checksum, chunks = file.chunks }
  end
  if type(value.manifestChecksum) ~= "string" or value.manifestChecksum ~= Installer.manifestChecksum(files) then return nil, "manifest checksum does not match" end
  return {
    requestID = value.requestID, serverSession = value.serverSession, clientSession = clientSession,
    role = value.role, label = value.label, computerID = value.computerID, coreID = value.coreID,
    coreSession = value.coreSession, packageId = value.packageId, version = value.version,
    chunkBytes = value.chunkBytes, manifestChecksum = value.manifestChecksum, files = files,
  }
end

Installer.validateOffer = validateOffer

local function matches(transaction, packet)
  return type(packet) == "table" and packet.v == 1
    and packet.clientSession == transaction.clientSession
    and packet.requestID == transaction.requestID
    and packet.serverSession == transaction.serverSession
end

local function packet(kind, transaction, extra)
  local result = { v = 1, kind = kind, clientSession = transaction.clientSession, requestID = transaction.requestID, serverSession = transaction.serverSession }
  for key, value in pairs(extra or {}) do result[key] = value end
  return result
end

-- Summary: Check chunk identity, index and size against the accepted offer.
local function validateChunk(value, transaction, config)
  if type(value) ~= "table" or value.kind ~= "chunk" or not matches(transaction, value) then return nil end
  if not integer(value.fileIndex) or not integer(value.chunkIndex) or not integer(value.chunkCount) then return nil end
  local file = transaction.files[value.fileIndex]
  if not file or value.path ~= file.path or value.chunkCount ~= file.chunks then return nil end
  if value.chunkIndex < 1 or value.chunkIndex > file.chunks or type(value.data) ~= "string" then return nil end
  local expected = transaction.chunkBytes
  if value.chunkIndex == file.chunks then expected = file.size - transaction.chunkBytes * (file.chunks - 1) end
  if #value.data ~= expected or #value.data > config.chunkBytes then return nil end
  return file
end

local function deleteIfPresent(filesystem, path)
  if filesystem.exists(path) then filesystem.delete(path) end
end

-- Summary: Write a staged payload and verify its stored checksum.
local function writeVerifiedStage(filesystem, file, bytes)
  local stagingPath = STAGE[file.path]
  if not stagingPath then return false, "destination is not allowlisted" end
  local handle = filesystem.open(stagingPath, "w")
  if not handle then return false, "could not open fixed staging file" end
  local ok, err = pcall(function() handle.write(bytes); handle.close() end)
  if not ok then pcall(function() handle.close() end); return false, tostring(err) end
  local check = readFile(filesystem, stagingPath)
  if check ~= bytes then return false, "staged file did not verify after write" end
  return true
end

-- Summary: Persist the replacement transaction and its rollback metadata.
local function writeJournal(filesystem, journal, deps)
  local encoded, err = jsonEncode(journal, deps)
  if type(encoded) ~= "string" then return false, err or "could not encode commit journal" end
  local temporary, backup = JOURNAL .. ".tmp", JOURNAL .. ".bak"
  local ok, issue = writeFile(filesystem, temporary, encoded)
  if not ok then return false, issue end
  local moved, moveErr = pcall(function()
    if filesystem.exists(backup) then filesystem.delete(backup) end
    if filesystem.exists(JOURNAL) then filesystem.move(JOURNAL, backup) end
    filesystem.move(temporary, JOURNAL)
  end)
  if not moved then
    pcall(function()
      if filesystem.exists(temporary) then filesystem.delete(temporary) end
      if filesystem.exists(backup) and not filesystem.exists(JOURNAL) then filesystem.move(backup, JOURNAL) end
    end)
    return false, tostring(moveErr)
  end
  return true
end

-- Summary: Read and validate a pending replacement journal.
local function readJournal(filesystem, deps)
  for _, path in ipairs({ JOURNAL, JOURNAL .. ".bak", JOURNAL .. ".tmp" }) do
    local raw = readFile(filesystem, path)
    if raw then
      local journal = jsonDecode(raw, deps)
      if type(journal) == "table" then return journal end
    end
  end
  return nil
end

-- Summary: Remove the completed replacement journal and its bookkeeping.
local function deleteJournal(filesystem)
  local errors = {}
  for _, path in ipairs({ JOURNAL .. ".tmp", JOURNAL, JOURNAL .. ".bak" }) do
    if filesystem.exists(path) then
      local ok, err = pcall(filesystem.delete, path)
      if not ok then errors[#errors + 1] = tostring(err) end
    end
  end
  return #errors == 0, table.concat(errors, "; ")
end

-- Summary: Read or create the verified package receipt for installation acknowledgement.
local function installedReceipt(transaction, config)
  return {
    protocol = config.protocol,
    installID = transaction.requestID,
    clientSession = transaction.clientSession,
    serverSession = transaction.serverSession,
    manifestChecksum = transaction.manifestChecksum,
    serverID = transaction.serverID,
    computerID = transaction.computerID,
    role = transaction.role,
    packageId = transaction.packageId,
    label = transaction.label,
    version = transaction.version,
    coreID = transaction.coreID,
    coreSession = transaction.coreSession,
    heartbeatSeconds = config.heartbeatSeconds,
  }
end

-- Summary: Prepare package files and retained configuration before commit.
local function makePreparedFiles(transaction, config, deps)
  local filesystem = (deps and deps.fs) or fs
  local prepared = {}
  for index, file in ipairs(transaction.files) do
    local data = transaction.fileBytes[index]
    if type(data) ~= "string" or #data ~= file.size or Installer.adler32(data) ~= file.checksum then return nil, "staged payload failed final checksum validation" end
    prepared[file.path] = data
  end
  local object, err = jsonDecode(prepared["/avionics/config.json"], deps)
  if type(object) ~= "table" then return nil, err or "application config is not a JSON object" end
  for key in pairs(object) do if type(key) == "number" then return nil, "application config must be a JSON object" end end
  object.role = transaction.role
  object.fleet_role = transaction.role
  object.core_id, object.coreId, object.coreID = transaction.coreID, transaction.coreID, transaction.coreID
  object.computer_id, object.computerId, object.computerID = transaction.computerID, transaction.computerID, transaction.computerID
  object.label, object.computerLabel, object.computer_label = transaction.label, transaction.label, transaction.label
  object.install = installedReceipt(transaction, config)
  local encoded, encodeErr = jsonEncode(object, deps)
  if type(encoded) ~= "string" then return nil, encodeErr or "application config could not be encoded" end
  prepared["/avionics/config.json"] = encoded
  for _, file in ipairs(transaction.files) do
    local path = STAGE[file.path]
    if not path then return nil, "package contains a destination without a fixed staging path" end
    local handle = filesystem.open(path, "w")
    if not handle then return nil, "could not reopen fixed staging file" end
    local ok, writeErr = pcall(function() handle.write(prepared[file.path]); handle.close() end)
    if not ok then pcall(function() handle.close() end); return nil, tostring(writeErr) end
    if readFile(filesystem, path) ~= prepared[file.path] then return nil, "prepared staging file failed verification" end
  end
  return prepared
end

local restoreLabel

-- Summary: Restore files and labels recorded by the replacement transaction.
local function rollbackJournal(filesystem, journal, deps)
  if type(journal) ~= "table" or type(journal.files) ~= "table"
    or type(DESTINATIONS_BY_ROLE[journal.role]) ~= "table" then return false, "commit journal is invalid" end
  local allowed = {}
  for _, path in ipairs(DESTINATIONS_BY_ROLE[journal.role]) do allowed[path] = true end
  local errors = {}
  for index = #journal.files, 1, -1 do
    local item = journal.files[index]
    if type(item) ~= "table" or not allowed[item.path] or BACKUP[item.path] ~= item.backup then
      errors[#errors + 1] = "commit journal contains an unsafe destination"
    else
      local ok, err = pcall(function()
        if filesystem.exists(item.backup) then
          if filesystem.exists(item.path) then filesystem.delete(item.path) end
          filesystem.move(item.backup, item.path)
        elseif item.hadOld ~= true and filesystem.exists(item.path) then
          filesystem.delete(item.path)
        elseif item.hadOld == true and not filesystem.exists(item.path) then
          error("previous file is missing: " .. item.path)
        end
      end)
      if not ok then errors[#errors + 1] = tostring(err) end
    end
  end
  if type(journal.previousLabel) == "string" then
    local restored, restoreErr = restoreLabel(journal.previousLabel, deps)
    if not restored then errors[#errors + 1] = "could not restore previous computer label: " .. tostring(restoreErr) end
  end
  if #errors > 0 then return false, table.concat(errors, "; ") end
  return true
end

-- Summary: Remove transaction staging and backup files after completion.
local function cleanupJournalFiles(filesystem, journal)
  for _, item in ipairs(journal.files or {}) do
    if type(item) == "table" and STAGE[item.path] then
      deleteIfPresent(filesystem, STAGE[item.path])
      deleteIfPresent(filesystem, BACKUP[item.path])
    end
  end
  return deleteJournal(filesystem)
end

-- Summary: Resume or roll back the recorded interrupted installation transaction.
local function recoverPending(filesystem, status, deps)
  local journal = readJournal(filesystem, deps)
  if not journal then
    if status.recoveryRequired == true and status.state == "installed" and status.hasInstalled == true then
      status.recoveryRequired = false
      return reportStatus(filesystem, status, deps)
    end
    if status.recoveryRequired == true or status.state == "committing" then
      return false, "commit journal is missing while recovery is required"
    end
    return true
  end
  local committed = status.hasInstalled == true and status.state == "installed"
    and status.installedInstallID == journal.installID
    and status.installedRole == journal.role
    and status.installedPackageId == journal.packageId
    and status.installedVersion == journal.version
    and status.installedManifestChecksum == journal.manifestChecksum
    and status.installedComputerID == journal.computerID
    and status.installedCoreID == journal.coreID
    and status.installedLabel == journal.label
  if committed then
    local cleaned, cleanErr = cleanupJournalFiles(filesystem, journal)
    if not cleaned then return false, cleanErr end
    status.recoveryRequired, status.detail = false, nil
    status.state = "installed"
    return reportStatus(filesystem, status, deps)
  end
  local restored, restoreErr = rollbackJournal(filesystem, journal, deps)
  if not restored then
    status.state, status.detail, status.recoveryRequired = "recovery_required", restoreErr, true
    reportStatus(filesystem, status, deps)
    return false, restoreErr
  end
  local cleaned, cleanErr = cleanupJournalFiles(filesystem, journal)
  if not cleaned then
    status.state, status.detail, status.recoveryRequired = "recovery_required", cleanErr, true
    reportStatus(filesystem, status, deps)
    return false, cleanErr
  end
  status.state = status.hasInstalled == true and "installed" or "not_installed"
  status.recoveryRequired, status.detail = false, nil
  local saved, saveErr = reportStatus(filesystem, status, deps)
  if not saved then return false, saveErr end
  return true
end

-- Summary: Replace staged program files under the current transaction journal.
local function replaceFiles(filesystem, transaction, journal, deps)
  local states, journalFiles = {}, {}
  for _, file in ipairs(transaction.files) do
    local path, backup = file.path, BACKUP[file.path]
    if not backup then return nil, "destination is not allowlisted" end
    local state = { path = path, backup = backup, hadOld = filesystem.exists(path) == true }
    states[#states + 1] = state
    journalFiles[#journalFiles + 1] = { path = path, backup = backup, hadOld = state.hadOld }
  end
  journal.files, journal.phase = journalFiles, "replacing"
  local saved, saveErr = writeJournal(filesystem, journal, deps)
  if not saved then return nil, saveErr end
  local ok, err = pcall(function()
    for _, state in ipairs(states) do
      deleteIfPresent(filesystem, state.backup)
      if state.hadOld then filesystem.move(state.path, state.backup) end
      local staging = STAGE[state.path]
      if not staging or not filesystem.exists(staging) then error("verified staged file is missing: " .. state.path) end
      filesystem.move(staging, state.path)
    end
  end)
  if not ok then
    local restored, restoreErr = rollbackJournal(filesystem, journal, deps)
    if not restored then return nil, "replacement failed and rollback failed: " .. tostring(err) .. "; " .. restoreErr end
    cleanupJournalFiles(filesystem, journal)
    return nil, "replacement failed; previous version restored: " .. tostring(err)
  end
  journal.phase = "files_replaced"
  saved, saveErr = writeJournal(filesystem, journal, deps)
  if not saved then return nil, "files replaced but recovery journal could not advance: " .. tostring(saveErr) end
  return states
end

local function readLabel(deps)
  if deps and type(deps.getLabel) == "function" then return deps.getLabel() end
  local system = (deps and deps.os) or os
  if system and type(system.getComputerLabel) == "function" then local ok, value = pcall(system.getComputerLabel); if ok then return value end end
end

local function setLabel(label, deps)
  if deps and type(deps.setLabel) == "function" then return deps.setLabel(label) end
  local system = (deps and deps.os) or os
  if not system or type(system.setComputerLabel) ~= "function" then return false, "computer label API is unavailable" end
  local ok, value = pcall(system.setComputerLabel, label)
  return ok and value ~= false, ok and "computer label was rejected" or tostring(value)
end

-- Summary: Restore the previous computer label from transaction metadata.
restoreLabel = function(previous, deps)
  local setter
  if deps and type(deps.setLabel) == "function" then setter = deps.setLabel end
  local system = (deps and deps.os) or os
  if not setter and system and type(system.setComputerLabel) == "function" then setter = system.setComputerLabel end
  if not setter then return false, "computer label API is unavailable" end
  local ok, result, detail = pcall(setter, previous)
  if not ok then return false, tostring(result) end
  if result == false then return false, tostring(detail or "computer label was rejected") end
  return true
end

-- Summary: Restart the installed application after a successful replacement.
local function reloadApp(transaction, deps)
  if deps and type(deps.onCommitted) == "function" then return pcall(deps.onCommitted, transaction) end
  local system = (deps and deps.os) or os
  if system and type(system.queueEvent) == "function" then
    return pcall(system.queueEvent, "amaryllis_install_committed", transaction.clientSession, transaction.requestID, transaction.serverSession)
  end
  return true
end

-- Summary: Verify staged files, replace programs and publish the installation receipt.
local function commit(filesystem, transaction, config, status, deps)
  local prepared, err = makePreparedFiles(transaction, config, deps)
  if not prepared then return nil, err end
  local wasRecovery = status.recoveryRequired == true
  local oldLabel = readLabel(deps)
  local journal = {
    schemaVersion = 1, role = transaction.role, packageId = transaction.packageId,
    version = transaction.version, installID = transaction.requestID,
    computerID = transaction.computerID, coreID = transaction.coreID, label = transaction.label,
    manifestChecksum = transaction.manifestChecksum, previousLabel = oldLabel,
    phase = "prepared", files = {},
  }
  local journalOK, journalErr = writeJournal(filesystem, journal, deps)
  if not journalOK then return nil, "could not create durable commit journal: " .. tostring(journalErr) end
  status.state, status.detail, status.recoveryRequired = "committing", nil, true
  status.installID, status.serverSession, status.manifestChecksum = tostring(transaction.requestID), transaction.serverSession, transaction.manifestChecksum
  local statusOk, statusErr = reportStatus(filesystem, status, deps)
  if not statusOk then return nil, "could not record commit start: " .. tostring(statusErr) end
  local states, replaceErr = replaceFiles(filesystem, transaction, journal, deps)
  if not states then
    local restored, restoreErr = rollbackJournal(filesystem, journal, deps)
    if restored then cleanupJournalFiles(filesystem, journal) end
    status.state, status.detail = "install-failed", "package replacement failed: " .. tostring(replaceErr)
    status.recoveryRequired = wasRecovery or not restored
    if not restored then status.detail = status.detail .. "; rollback failed: " .. tostring(restoreErr) end
    reportStatus(filesystem, status, deps)
    return nil, status.detail
  end
  journal.phase = "label_pending"
  journalOK, journalErr = writeJournal(filesystem, journal, deps)
  if not journalOK then
    local restored, restoreErr = rollbackJournal(filesystem, journal, deps)
    if restored then cleanupJournalFiles(filesystem, journal) end
    status.state, status.detail = "install-failed", "could not record label commit: " .. tostring(journalErr)
    status.recoveryRequired = wasRecovery or not restored
    if not restored then status.detail = status.detail .. "; rollback failed: " .. tostring(restoreErr) end
    reportStatus(filesystem, status, deps)
    return nil, status.detail
  end
  local labelOk, labelErr = setLabel(transaction.label, deps)
  if not labelOk then
    restoreLabel(oldLabel, deps)
    local restored, restoreErr = rollbackJournal(filesystem, journal, deps)
    if restored then cleanupJournalFiles(filesystem, journal) end
    status.state, status.detail = "install-failed", "could not apply target label: " .. tostring(labelErr)
    status.recoveryRequired = wasRecovery or not restored
    if not restored then status.detail = status.detail .. "; rollback failed: " .. tostring(restoreErr) end
    reportStatus(filesystem, status, deps)
    return nil, status.detail
  end
  status.state, status.detail = "installed", nil
  status.hasInstalled = true
  status.recoveryRequired = true
  status.role, status.label, status.version = transaction.role, transaction.label, transaction.version
  status.packageId, status.installedPackageId = transaction.packageId, transaction.packageId
  status.computerID, status.installedComputerID = transaction.computerID, transaction.computerID
  status.coreID, status.coreSession = transaction.coreID, transaction.coreSession
  -- Persist the complete receipt before any bootstrap can observe installed.
  status.installedCoreID, status.installedCoreSession = transaction.coreID, transaction.coreSession
  status.installID, status.installedInstallID = tostring(transaction.requestID), tostring(transaction.requestID)
  status.serverSession, status.clientSession = transaction.serverSession, transaction.clientSession
  status.installedClientSession, status.installedServerSession = transaction.clientSession, transaction.serverSession
  status.manifestChecksum, status.installedManifestChecksum = transaction.manifestChecksum, transaction.manifestChecksum
  status.installedLabel, status.installedVersion, status.installedRole = transaction.label, transaction.version, transaction.role
  status.installedAt, status.applicationState, status.applicationFault = clockNow(deps), "starting", nil
  statusOk, statusErr = reportStatus(filesystem, status, deps)
  if not statusOk then return nil, "could not record installed package metadata: " .. tostring(statusErr) end
  local cleaned, cleanErr = cleanupJournalFiles(filesystem, journal)
  if not cleaned then return nil, "package is committed but cleanup needs retry: " .. tostring(cleanErr) end
  status.recoveryRequired, status.state, status.detail = false, "installed", nil
  statusOk, statusErr = reportStatus(filesystem, status, deps)
  if not statusOk then return nil, "package is committed but status needs retry: " .. tostring(statusErr) end
  deleteIfPresent(filesystem, REINSTALL)
  reloadApp(transaction, deps)
  return states, prepared
end


-- Summary: Receive verified package chunks and coordinate their staged installation.
local function processOffer(filesystem, config, offer, clientSession, serverID, computerID, deps)
  local transaction = {
    config = config, requestID = offer.requestID, serverSession = offer.serverSession,
    clientSession = clientSession, serverID = serverID, computerID = computerID,
    role = offer.role, label = offer.label, coreID = offer.coreID,
    coreSession = offer.coreSession, packageId = offer.packageId, version = offer.version,
    chunkBytes = offer.chunkBytes, manifestChecksum = offer.manifestChecksum,
    files = offer.files, fileBytes = {}, chunks = {}, completeFiles = {},
    currentFile = 1, currentChunk = 1, lastOutbound = nil,
  }
  for i = 1, #transaction.files do transaction.chunks[i] = {} end
  for _, file in ipairs(transaction.files) do deleteIfPresent(filesystem, STAGE[file.path]) end
  local previous = readStatus(filesystem, deps)
  local status = preserveInstalledStatus({
    state = "downloading", role = config.role, clientID = computerID, clientSession = tostring(clientSession),
    serverID = serverID, installID = tostring(transaction.requestID), serverSession = transaction.serverSession,
    manifestChecksum = transaction.manifestChecksum,
    label = previous and previous.installedLabel or nil,
    version = previous and previous.installedVersion or nil,
  }, previous)
  reportStatus(filesystem, status, deps)
  local ready = packet("ready", transaction, {
    manifestChecksum = transaction.manifestChecksum, role = transaction.role,
    label = transaction.label, computerID = transaction.computerID, coreID = transaction.coreID,
    coreSession = transaction.coreSession, packageId = transaction.packageId,
    version = transaction.version,
  })
  transaction.lastOutbound = ready
  sendPacket(config, ready, deps)
  local retries, maxRetries = 0, 8

  while not stopping(deps) do
    if not activeBinding(transaction.role, transaction.computerID, transaction.label,
      transaction.coreID, transaction.coreSession, deps) then
      status.state, status.detail = "transfer-retired", "active core registry binding changed during transfer"
      reportStatus(filesystem, status, deps)
      return false
    end
    local sender, value = receivePacket(config, config.retrySeconds, deps)
    if sender == nil then
      retries = retries + 1
      if retries > maxRetries then
        status.state, status.detail = "retrying", "transfer timed out; requesting a fresh offer"
        reportStatus(filesystem, status, deps)
        return false
      end
      if transaction.lastOutbound then sendPacket(config, transaction.lastOutbound, deps) end
    elseif sender == serverID and type(value) == "table" then
      if value.kind == "offer" and value.v == 1 and value.clientSession == clientSession
        and value.requestID == transaction.requestID and value.serverSession == transaction.serverSession
        and value.manifestChecksum == transaction.manifestChecksum then
        sendPacket(config, ready, deps)
      elseif value.kind == "chunk" and matches(transaction, value) then
        if not activeBinding(transaction.role, transaction.computerID, transaction.label,
          transaction.coreID, transaction.coreSession, deps) then
          status.state, status.detail = "transfer-retired", "active core registry binding changed during transfer"
          reportStatus(filesystem, status, deps)
          return false
        end
        local file = validateChunk(value, transaction, config)
        if file then
          local fileIndex, chunkIndex = value.fileIndex, value.chunkIndex
          if transaction.completeFiles[fileIndex] and chunkIndex == file.chunks then
            local ack = packet("chunkAck", transaction, { fileIndex = fileIndex, chunkIndex = chunkIndex, path = file.path })
            transaction.lastOutbound = ack; sendPacket(config, ack, deps)
            local complete = packet("fileComplete", transaction, { fileIndex = fileIndex, path = file.path, checksum = file.checksum })
            sendPacket(config, complete, deps); retries = 0
          elseif fileIndex < transaction.currentFile and chunkIndex == file.chunks then
            local ack = packet("chunkAck", transaction, { fileIndex = fileIndex, chunkIndex = chunkIndex, path = file.path })
            transaction.lastOutbound = ack; sendPacket(config, ack, deps)
            local complete = packet("fileComplete", transaction, { fileIndex = fileIndex, path = file.path, checksum = file.checksum })
            sendPacket(config, complete, deps); retries = 0
          elseif fileIndex == transaction.currentFile and chunkIndex < transaction.currentChunk then
            local ack = packet("chunkAck", transaction, { fileIndex = fileIndex, chunkIndex = chunkIndex, path = file.path })
            transaction.lastOutbound = ack; sendPacket(config, ack, deps); retries = 0
          elseif fileIndex == transaction.currentFile and chunkIndex == transaction.currentChunk then
            transaction.chunks[fileIndex][chunkIndex] = value.data
            local ack = packet("chunkAck", transaction, { fileIndex = fileIndex, chunkIndex = chunkIndex, path = file.path })
            transaction.lastOutbound = ack; sendPacket(config, ack, deps); retries = 0
            transaction.currentChunk = transaction.currentChunk + 1
            if transaction.currentChunk > file.chunks then
              local bytes = table.concat(transaction.chunks[fileIndex])
              if #bytes ~= file.size or Installer.adler32(bytes) ~= file.checksum then
                status.state, status.detail = "transfer-rejected", "downloaded file failed size or Adler-32 validation"
                reportStatus(filesystem, status, deps)
                return false
              end
              local ok, stageErr = writeVerifiedStage(filesystem, file, bytes)
              if not ok then status.state, status.detail = "install-failed", stageErr; reportStatus(filesystem, status, deps); return false end
              transaction.fileBytes[fileIndex], transaction.completeFiles[fileIndex] = bytes, true
              local complete = packet("fileComplete", transaction, { fileIndex = fileIndex, path = file.path, checksum = file.checksum })
              transaction.currentFile, transaction.currentChunk = transaction.currentFile + 1, 1
              transaction.lastOutbound = complete; sendPacket(config, complete, deps)
            end
          end
        end
      elseif value.kind == "commit" and matches(transaction, value) and transaction.currentFile > #transaction.files
        and value.manifestChecksum == transaction.manifestChecksum and value.role == transaction.role
        and value.label == transaction.label and value.computerID == transaction.computerID
        and value.coreID == transaction.coreID and value.coreSession == transaction.coreSession
        and value.packageId == transaction.packageId and value.version == transaction.version
        and activeBinding(transaction.role, transaction.computerID, transaction.label,
          transaction.coreID, transaction.coreSession, deps) then
        transaction.commit = { label = value.label, version = value.version, role = value.role }
        if not transaction.localCommitted then
          local states, err = commit(filesystem, transaction, config, status, deps)
          if states then
            transaction.localCommitted = true
            transaction.lastOutbound = packet("installed", transaction, {
              role = transaction.role, label = value.label, version = value.version,
              computerID = transaction.computerID, coreID = transaction.coreID,
              coreSession = transaction.coreSession, packageId = transaction.packageId,
              manifestChecksum = transaction.manifestChecksum,
            })
          else
            status.state, status.detail = "install-failed", err
            reportStatus(filesystem, status, deps)
          end
        end
        if transaction.localCommitted then sendPacket(config, transaction.lastOutbound, deps) end
        retries = 0
      elseif value.kind == "complete" and matches(transaction, value) and transaction.localCommitted
        and value.manifestChecksum == transaction.manifestChecksum and value.role == transaction.role
        and value.label == transaction.commit.label and value.version == transaction.commit.version
        and value.computerID == transaction.computerID and value.coreID == transaction.coreID
        and value.coreSession == transaction.coreSession and value.packageId == transaction.packageId then
        status.state, status.detail = "installed", nil
        status.hasInstalled = true
        status.recoveryRequired = false
        status.label, status.version, status.role = transaction.commit.label, transaction.commit.version, transaction.role
        status.installID, status.serverSession, status.clientSession = tostring(transaction.requestID), transaction.serverSession, clientSession
        status.manifestChecksum = transaction.manifestChecksum
        status.installedInstallID = tostring(transaction.requestID)
        status.installedClientSession, status.installedServerSession = clientSession, transaction.serverSession
        status.installedManifestChecksum, status.installedLabel = transaction.manifestChecksum, transaction.commit.label
        status.installedVersion, status.installedRole = transaction.commit.version, transaction.role
        status.installedPackageId, status.installedComputerID = transaction.packageId, transaction.computerID
        status.installedCoreID, status.installedCoreSession = transaction.coreID, transaction.coreSession
        status.hasInstalled = true
        reportStatus(filesystem, status, deps)
        return true
      end
    end
  end
  return false
end

-- Summary: Read or create the verified package receipt for installation acknowledgement.
local function installedReceipt(filesystem, config, computerID, status, deps)
  for _, path in ipairs({ JOURNAL, JOURNAL .. ".bak", JOURNAL .. ".tmp" }) do
    if filesystem.exists(path) then return nil end
  end
  local raw = readFile(filesystem, "/avionics/config.json")
  local application = raw and jsonDecode(raw, deps) or nil
  local receipt = type(application) == "table" and application.install or nil
  if type(receipt) ~= "table" or receipt.protocol ~= PROTOCOL or receipt.role ~= config.role
    or receipt.packageId ~= config.packageId or not integer(receipt.version) or receipt.version < 2
    or receipt.coreID ~= config.serverId or receipt.computerID ~= computerID
    or not validLabel(receipt.label) or type(receipt.manifestChecksum) ~= "string"
    or type(receipt.installID) ~= "string" or not validToken(receipt.clientSession)
    or not validToken(receipt.serverSession) then return nil end
  if type(status) ~= "table" or status.hasInstalled ~= true
    or status.recoveryRequired == true or status.installedRole ~= receipt.role
    or status.installedPackageId ~= receipt.packageId or status.installedVersion ~= receipt.version
    or status.installedManifestChecksum ~= receipt.manifestChecksum
    or status.installedComputerID ~= computerID or status.installedCoreID ~= config.serverId
    or status.installedLabel ~= receipt.label
    or tostring(status.installedInstallID) ~= tostring(receipt.installID)
    or status.installedClientSession ~= receipt.clientSession
    or status.installedServerSession ~= receipt.serverSession then return nil end
  if readLabel(deps) ~= receipt.label then return nil end
  return receipt
end

-- Summary: Ask the assigned core for the current fleet registry.
local function sendRegistryRequest(config, session, deps)
  local request = { v = 1, kind = "registry_request", coreID = config.serverId, session = session }
  if deps and type(deps.sendRegistry) == "function" then return deps.sendRegistry(config.serverId, request, REGISTRY_PROTOCOL) end
  local network = (deps and deps.rednet) or rednet
  if not network or type(network.send) ~= "function" then return false end
  ensureNetwork(deps)
  local ok, result = pcall(network.send, config.serverId, request, REGISTRY_PROTOCOL)
  return ok and result ~= false
end

-- Older fresh installs could reboot after local commit but before the final
-- acknowledgement filled installedCoreID. Repair that one missing field only
-- after all other receipt checks and the live core binding have passed.
-- Summary: Older fresh installs could reboot after local commit but before the final acknowledgement filled installedCoreID. Repair that one missing field only after all other receipt checks and the live core binding have passed.
local function recoverCommittedCoreID(filesystem,config,computerID,status,registry,deps)
  if status.installedCoreID~=nil or status.hasInstalled~=true or status.recoveryRequired==true
    or status.state=="committing" or status.state=="recovery_required" then return false end
  local candidate={}
  for key,value in pairs(status) do candidate[key]=value end
  candidate.installedCoreID=config.serverId
  local receipt=installedReceipt(filesystem,config,computerID,candidate,deps)
  if not receipt or not validToken(receipt.coreSession) or status.installedCoreSession~=receipt.coreSession
    or type(registry)~="table" or not activeBinding(config.role,computerID,receipt.label,
      config.serverId,registry.session,deps) then return false end
  local ok=reportStatus(filesystem,candidate,deps)
  if not ok then return false end
  status.installedCoreID=candidate.installedCoreID
  return true
end

-- Summary: Verify that the installed application matches its expected package.
local function validCurrent(value, config, session, computerID, receipt, status, deps)
  if type(value) ~= "table" or value.v ~= 1 or value.kind ~= "current"
    or value.clientSession ~= session or not validToken(value.serverSession)
    or value.role ~= config.role or value.coreID ~= config.serverId or value.computerID ~= computerID
    or not validLabel(value.label) or not validToken(value.coreSession)
    or value.packageId ~= config.packageId or not integer(value.version) or value.version < 2
    or type(value.manifestChecksum) ~= "string" then return false end
  if not activeBinding(config.role, computerID, value.label, config.serverId, value.coreSession, deps) then return false end
  return type(receipt) == "table" and type(status) == "table"
    and receipt.role == value.role and receipt.packageId == value.packageId
    and receipt.version == value.version and receipt.label == value.label
    and receipt.manifestChecksum == value.manifestChecksum
    and status.installedPackageId == value.packageId and status.installedVersion == value.version
    and status.installedLabel == value.label and status.installedComputerID == computerID
end

-- Summary: Initialize the role and run its configured display/network service.
function Installer.run(rawConfig, deps)
  local filesystem = (deps and deps.fs) or fs
  if not filesystem then error("ComputerCraft filesystem API is unavailable") end
  ensureDirs(filesystem)
  local config, configErr = normalizeConfig(rawConfig)
  local previous = readStatus(filesystem, deps)
  local status = preserveInstalledStatus({ state = "starting" }, previous)
  if not config then status.state, status.detail = "configuration-error", configErr; reportStatus(filesystem, status, deps); return false, configErr end
  local recovered, recoveryError = recoverPending(filesystem, status, deps)
  if not recovered then
    status.state, status.detail, status.recoveryRequired = "recovery_required", recoveryError, true
    reportStatus(filesystem, status, deps)
    return false, recoveryError
  end
  local computerID = actualComputerId(config, deps)
  if not integer(computerID) or computerID == config.serverId then
    status.state, status.detail = "identity-error", "runtime computer ID is unavailable or conflicts with the server trust anchor"
    reportStatus(filesystem, status, deps)
    return false, status.detail
  end
  local session, sessionErr = makeSession(filesystem, deps)
  if not session then status.state, status.detail = "session-error", sessionErr; reportStatus(filesystem, status, deps); return false, sessionErr end
  status.state, status.role, status.clientID, status.serverID = "listening", config.role, computerID, config.serverId
  status.clientSession, status.label, status.version = tostring(session), status.installedLabel, status.installedVersion
  reportStatus(filesystem, status, deps)
  -- Summary: Build a hello request with current role, package and session metadata.
  local function helloPacket()
    local force = filesystem.exists(REINSTALL)
    local installed = not force and installedReceipt(filesystem, config, computerID, status, deps) or nil
    local message = { v = 1, kind = "hello", role = config.role, clientID = computerID,
      clientSession = session, force = force }
    if installed then
      message.installedRole = installed.role
      message.installedPackageId, message.installedVersion = installed.packageId, installed.version
      message.installedManifestChecksum = installed.manifestChecksum
      message.installedLabel, message.installedComputerID = installed.label, installed.computerID
    end
    return message
  end
  local hello = helloPacket()
  local waiting = 0
  while not stopping(deps) do
    ensureNetwork(deps)
    local registry = deps and deps.os and deps.os.__amaryllisFleetRegistry or os and os.__amaryllisFleetRegistry
    local role = assignedRole(registry, computerID)
    config.role = role
    config.packageId = role and PACKAGE_IDS[role] or nil
    local binding = role and registry.computers[role] or nil
    if type(binding) ~= "table" or binding.id ~= computerID or not validLabel(binding.label)
      or registry.coreID ~= config.serverId or not validToken(registry.session) then
      sendRegistryRequest(config, session, deps)
      status.state, status.detail = "waiting_for_registry", "requesting the current role binding from core"
      reportStatus(filesystem, status, deps)
      waitFor(config.retrySeconds, deps)
    else
      recoverCommittedCoreID(filesystem,config,computerID,status,registry,deps)
      hello = helloPacket()
      sendPacket(config, hello, deps)
    end
    local sender, value = receivePacket(config, config.retrySeconds, deps)
    if sender == config.serverId and type(value) == "table" and value.v == 1 and value.kind == "offer" then
      local offer, offerErr = validateOffer(value, config, session, computerID, deps)
      if offer then
        waiting = 0
        local installed = processOffer(filesystem, config, offer, session, sender, computerID, deps)
        local latest = readStatus(filesystem, deps)
        if type(latest) == "table" then status = latest end
        if not installed and not stopping(deps) then
          local didRecover, retryError = recoverPending(filesystem, status, deps)
          if not didRecover then
            status.state, status.detail, status.recoveryRequired = "recovery_required", retryError, true
            reportStatus(filesystem, status, deps)
            return false, retryError
          end
          local nextSession, nextErr = makeSession(filesystem, deps)
          if nextSession then
            session, hello = nextSession, nil
            hello = helloPacket()
            status.state, status.detail, status.clientSession = "listening", "new client session after incomplete transfer", tostring(session)
            reportStatus(filesystem, status, deps)
          else
            status.state, status.detail = "session-error", nextErr
            reportStatus(filesystem, status, deps)
            return false, nextErr
          end
        end
      else
        status.state, status.detail = "offer-rejected", offerErr
        reportStatus(filesystem, status, deps)
      end
    elseif sender == config.serverId and validCurrent(value, config, session, computerID,
      installedReceipt(filesystem, config, computerID, status, deps), status, deps) then
      status.state, status.detail = "installed", nil
      status.coreSession, status.serverSession = value.coreSession, value.serverSession
      status.activePackageVersion, status.activePackageId = value.version, value.packageId
      reportStatus(filesystem, status, deps)
      waitFor(config.retrySeconds, deps)
    elseif sender == config.serverId and type(value) == "table" and value.v == 1
      and value.kind == "complete" and value.clientSession == session then
      -- The core replays completion for duplicate hellos; throttle this acknowledgement loop.
      waiting = 0
      waitFor(config.retrySeconds, deps)
    else
      waiting = waiting + config.retrySeconds
      if waiting >= config.offerTimeoutSeconds then
        status.state, status.detail = "listening", "waiting for the configured installer server"
        reportStatus(filesystem, status, deps)
        waiting = 0
      end
    end
  end
  return true
end

function Installer.readJSON(path, deps)
  local filesystem = (deps and deps.fs) or fs
  if not filesystem then return nil, "ComputerCraft filesystem API is unavailable" end
  local raw = readFile(filesystem, path)
  if not raw then return nil, "file not found" end
  return jsonDecode(raw, deps)
end

Installer.PROTOCOL = PROTOCOL
Installer.DESTINATIONS_BY_ROLE = DESTINATIONS_BY_ROLE
Installer.DESTINATIONS = DESTINATIONS_BY_ROLE.navigator
return Installer
