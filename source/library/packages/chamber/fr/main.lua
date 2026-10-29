-- @ama-section: Chamber coordinator | Supervised lift, propulsion relay and shared observations.
package.path = "/avionics/?.lua;/avionics/common/?.lua;" .. package.path
local programEnv = _ENV

local Supervisor = {}
local runtime = os.__amaryllisRuntime or {}
runtime.components = runtime.components or {}
runtime.faults = runtime.faults or {}
runtime.startedAt = runtime.startedAt or os.clock()
runtime.running = true
os.__amaryllisRuntime = runtime

local function clean(value)
    return tostring(value or "unknown"):gsub("[%c]", " "):sub(1, 96)
end

local function ensureRuntime()
    runtime = os.__amaryllisRuntime or runtime
    runtime.components = runtime.components or {}
    return runtime
end

-- @ama-section: Chamber coordinator | Supervised lift, propulsion relay and shared observations.
-- @ama-summary: Publish the current cached component observations to the configured consumer.
local function publish()
    local current = ensureRuntime()
    local faults, available = {}, false
    for _, name in ipairs({ "lift", "thrust" }) do
        local item = current.components[name] or {}
        if item.hardwareAvailable == true then available = true end
        for _, fault in ipairs(item.faults or {}) do
            if #faults < 8 then faults[#faults + 1] = name .. ":" .. clean(fault) end
        end
    end
    current.hardwareAvailable = available
    current.faults = faults
    current.faultSummary = #faults > 0 and table.concat(faults, "; "):sub(1, 384) or nil
    current.publishedAt = os.clock()
end

local function runProgram(path)
    local chunk, loadError = loadfile(path, nil, programEnv)
    if not chunk then error(loadError or ("could not load " .. path), 0) end
    return chunk()
end

-- @ama-summary: Run one role component and record its completion or exception.
local function componentAttempt(name, path, execute)
    local current = ensureRuntime()
    local component = current.components[name] or {}
    current.components[name] = component
    component.running = true
    component.startedAt = os.clock()
    component.faults = component.faults or {}
    publish()

    local runner = execute or runProgram
    local ok, result = pcall(runner, path)

    current = ensureRuntime()
    component = current.components[name] or {}
    current.components[name] = component
    component.running = false
    component.hardwareAvailable = false
    component.faults = { ok and (result == false and "COMPONENT_NOT_READY" or "COMPONENT_RETURNED") or clean(result) }
    component.faultSummary = component.faults[1]
    publish()
    return ok, result
end

-- @ama-summary: Run a component with logged completion and paced restart.
local function supervise(name, path)
    local delay = 1
    while true do
        local ok, result = componentAttempt(name, path)
        local current = ensureRuntime()
        local component = current.components[name] or {}
        print(name .. " component restarted after " .. clean(component.faultSummary or (ok and result) or result))
        sleep(delay)
        delay = math.min(delay * 2, 30)
    end
end

local function publishLoop()
    while true do publish(); sleep(0.5) end
end

Supervisor.componentAttempt = componentAttempt
Supervisor.publish = publish
if rawget(_ENV, "__CHAMBER_SUPERVISOR_TEST") then return Supervisor end

parallel.waitForAll(
    function() supervise("lift", "/avionics/lift.lua") end,
    function() supervise("thrust", "/avionics/relay.lua") end,
    publishLoop
)
