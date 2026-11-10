local Mathx = require("avionics.mathx")
-- Section: Input response | Selected-target rates and held-input acceleration.
-- Selected-target input response only; no actuator limits or PID gains.
local T={fields={}}
local finite = Mathx.finite
local function field(group,key,label,minimum,maximum,step)
    T.fields[#T.fields+1]={group=group,key=key,label=label,min=minimum,max=maximum,step=step}
end
field("SEL HEADING","heading_selection_rate","Heading start deg/s",.1,900,1)
field("SEL HEADING","heading_selection_acceleration","Heading hold accel deg/s^2",0,360,1)
field("SEL HEADING","heading_selection_max_rate","Heading max deg/s",.1,900,5)
field("SEL THROTTLE","speed_selection_acceleration","Speed hold accel (b/s)/s^2",0,10,.1)
field("SEL THROTTLE","speed_selection_max_rate","Speed max (b/s)/s",.01,10,.1)
-- Section: Input response | Selected-target rates and held-input acceleration.
-- Summary: Validate and populate selected-target input response settings.
function T.ensure(c)
    if type(c)~="table" then return false,"cockpit input settings are missing" end
    local legacyRate=finite(c.coarse_heading_degrees) and finite(c.heading_repeat_seconds) and
        c.heading_repeat_seconds>0 and c.coarse_heading_degrees/c.heading_repeat_seconds or 40
    local defaults={heading_selection_rate=legacyRate,heading_selection_acceleration=0,
        heading_selection_max_rate=math.max(180,legacyRate),speed_selection_acceleration=0,
        speed_selection_max_rate=10}
    for _,f in ipairs(T.fields) do
        if c[f.key]==nil then c[f.key]=defaults[f.key] end
        if not finite(c[f.key]) or c[f.key]<f.min or c[f.key]>f.max then
            return false,"cockpit."..f.key.." is outside its documented bounds"
        end
    end
    if c.heading_selection_rate>c.heading_selection_max_rate or
        (finite(c.speed_selection_blocks_per_second_per_second) and
         c.speed_selection_blocks_per_second_per_second>c.speed_selection_max_rate) then
        return false,"input start rate must not exceed its maximum rate"
    end
    return true
end
-- Exact area under a linearly increasing input rate with a hard rate cap.
-- Integrating, rather than multiplying by the final rate, makes response
-- independent of the number of fresh input samples.
function T.area(seconds,initial,acceleration,maximum)
    seconds=math.max(0,seconds)
    if acceleration<=0 or initial>=maximum then return math.min(initial,maximum)*seconds end
    local ramp=math.min(seconds,(maximum-initial)/acceleration)
    return initial*ramp+.5*acceleration*ramp*ramp+maximum*(seconds-ramp)
end
return T
