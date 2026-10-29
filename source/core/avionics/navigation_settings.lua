-- @ama-section: Navigation configuration | Defaults, editable fields and numeric bounds.
-- Shared defaults and bounds for the navigation UI, persistence and controllers.
local N={fields={}}
local function field(group,key,label,default,min,max,step)
    N.fields[#N.fields+1]={group=group,key=key,label=label,default=default,min=min,max=max,step=step}
end
field("anchor","position_gain","Position correction gain",.35,.01,2,.05)
field("anchor","maximum_speed","Maximum return speed b/s",2,.1,8,.1)
field("anchor","velocity_kp","Velocity proportional gain",.35,.01,2,.05)
field("anchor","velocity_ki","Velocity integral gain",.06,0,.5,.01)
field("anchor","output_slew","Thrust slew / second",.25,.01,1,.05)
field("anchor","position_tolerance","Position tolerance blocks",.5,.1,5,.1)
field("anchor","speed_tolerance","Settled speed b/s",.05,.01,.5,.01)
field("anchor","settle_seconds","Settling seconds",2,1,30,1)
field("autopilot","cross_gain","Route correction gain",.2,.01,1,.05)
field("autopilot","maximum_cross_speed","Maximum sideways speed b/s",1.5,.1,5,.1)
field("autopilot","velocity_gain","Sideways velocity gain",.35,.01,2,.05)
field("autopilot","output_slew","Lateral slew / second",.25,.01,1,.05)
field("autopilot","speed_ramp","Cruise acceleration b/s^2",.5,.01,2,.1)
field("autopilot","arrival_radius","Anchor handoff distance blocks",12,2,40,1)
-- @ama-section: Navigation configuration | Defaults, editable fields and numeric bounds.
-- @ama-summary: Validate and populate supported navigation configuration defaults.
function N.ensure(config)
    if config.navigation==nil then config.navigation={} end
    if type(config.navigation)~="table" then return false,"navigation must be an object" end
    for _,f in ipairs(N.fields) do
        local root=config.navigation
        if root[f.group]==nil then root[f.group]={} end
        if type(root[f.group])~="table" then return false,"navigation."..f.group.." must be an object" end
        local values=root[f.group]
        if values[f.key]==nil then values[f.key]=f.default end
        local v=values[f.key]
        if type(v)~="number" or v~=v or v<f.min or v>f.max then
            return false,"navigation."..f.group.."."..f.key.." is out of range"
        end
    end
    return true
end
function N.values(config,group)
    local ok,reason=N.ensure(config);assert(ok,reason)
    return config.navigation[group]
end
return N
