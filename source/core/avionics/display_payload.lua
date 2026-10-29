-- @ama-section: Display transport | Compact cached fields for heading instruments.
-- Information heading transport v1
-- Only the fields consumed by the heading displays' snapshot sanitizer.
-- The navigation bridge continues receiving the complete core snapshot.
local Payload={}
-- @ama-section: Display transport | Compact cached fields for heading instruments.
-- @ama-summary: Copy the specified bounded scalar fields into a transport view.
local function pick(source,keys)
    local out={};if type(source)~="table" then return out end
    for _,key in ipairs(keys) do
        local v=source[key]
        if type(v)=="number" or type(v)=="boolean" then out[key]=v
        elseif type(v)=="string" then out[key]=v:sub(1,2048) end
    end
    return out
end
-- @ama-summary: Build the compact cached status packet consumed by heading displays.
function Payload.heading(state)
    local result=pick(state,{"seq","updatedAt","anchor","authorityReady","dataFresh","displayStale","stale","valid","vesselValid"})
    local fields={"altitude","heading","pitch","roll","verticalSpeed","forwardSpeed","mass"}
    local vessel=state.vessel or {}
    result.vessel=pick(vessel,{"valid","reason","sampleAgeSeconds","altitudeSource","headingSource","altitudeUnit"})
    if type(vessel.validFields)=="table" then result.vessel.validFields=pick(vessel.validFields,fields) end
    for _,field in ipairs(fields) do
        result.vessel[field]=vessel[field];result.vessel[field.."Valid"]=vessel[field.."Valid"]
    end
    result.targets=pick(state.targets,{"altitude","heading","speed"})
    if type(state.modes)=="table" then result.modes=pick(state.modes,{"heading","throttle","altitude"}) end
    if type(state.thrust)=="table" and type(state.thrust.headingControl)=="table" then
        result.thrust={headingControl=pick(state.thrust.headingControl,{"measuredYawRate","targetYawRate"})}
    end
    if type(state.autopilot)=="table" then
        local ap=state.autopilot
        result.autopilot=pick(ap,{"active","distance","crossTrack","cruiseSpeed","requestedSpeed","requestedHeading","state","reason"})
        local route=type(ap.route)=="table" and ap.route or {}
        local entry=type(route.entries)=="table" and route.entries[route.index or 1]
        if type(entry)=="table" and type(entry.name)=="string" then
            result.autopilot.route={index=1,entries={{name=entry.name:sub(1,40)}}}
        end
    end
    if type(state.lateralControl)=="table" then result.lateralControl=pick(state.lateralControl,{"active","mode","offset","remaining","sidewaysSpeed","state"}) end
    if type(state.systemsStartup)=="table" then result.systemsStartup=pick(state.systemsStartup,{"active","phase","displayPhase","abortReason"}) end
    if type(state.altitudeControl)=="table" then result.altitudeControl=pick(state.altitudeControl,{"enabled"}) end
    if type(state.assembly)=="table" then result.assembly=pick(state.assembly,{"state","reason"}) end
    if type(state.fleetBoot)=="table" then result.fleetBoot=pick(state.fleetBoot,{"ready","phase","current","completed","total","reason"}) end
    return result
end
return Payload
