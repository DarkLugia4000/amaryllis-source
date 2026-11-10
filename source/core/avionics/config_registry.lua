-- Section: Settings registry | Units, bounds and fallbacks for altitude_control and thrust settings.
-- One entry per setting. The registry records what the code already does; it does not change tuning.
--   kind     number, integer or boolean.
--   min/max  accepted bounds; minExclusive/maxExclusive mark open ends.
--   bound    schema:  Storage.validateConfig enforces the bound when the config loads.
--            runtime: the consuming module clamps the value when it reads it.
--            none:    no numeric bound; only a finite check.
--   required true when validateConfig rejects the shipped config without this setting.
--   note     cross-setting constraint or other context for the bound.
--   fallbacks values the code uses when the setting is absent. Several values, or a value that
--            differs from the shipped one, are contextual fallbacks kept for a separate decision.
-- tests/test_config_registry.py checks every field against config.json, Storage.validateConfig,
-- the cockpit settings editor and the inline fallbacks in flight.lua, thrust.lua and anchor.lua.
local Registry = {}

Registry.entries = {
    {section="altitude_control",path="altitude_ceiling",kind="number",min=-2048,max=2048,bound="schema",required=true,unit="block Y",effect="Highest selectable altitude target",note="must be above minimum_world_y",evidence="configured value"},
    {section="altitude_control",path="altitude_pid.derivative_filter_seconds",kind="number",min=0,max=100,minExclusive=true,bound="schema",required=true,unit="seconds",effect="altitude pid derivative filter seconds",evidence="configured value"},
    {section="altitude_control",path="altitude_pid.integral_limit",kind="number",min=0,max=100,bound="schema",required=true,unit="input-seconds",effect="altitude pid integral limit",evidence="configured value"},
    {section="altitude_control",path="altitude_pid.kd",kind="number",min=0,max=100,bound="schema",required=true,unit="output-seconds per input",effect="altitude pid kd",evidence="configured value"},
    {section="altitude_control",path="altitude_pid.ki",kind="number",min=0,max=100,bound="schema",required=true,unit="output per input-second",effect="altitude pid ki",evidence="configured value"},
    {section="altitude_control",path="altitude_pid.kp",kind="number",min=0,max=100,bound="schema",required=true,unit="output per input",effect="altitude pid kp",evidence="configured value"},
    {section="altitude_control",path="ceiling_fast_rate",kind="number",min=0.02,max=0.25,bound="schema",unit="fraction per second",effect="Vent fast rate (fraction/s)",evidence="configured value"},
    {section="altitude_control",path="ceiling_rise_rate",kind="number",min=0.005,max=0.1,bound="schema",unit="fraction per second",effect="Vent rise rate (fraction/s)",evidence="configured value"},
    {section="altitude_control",path="ceiling_soft_start_rate",kind="number",min=0.0005,max=0.05,bound="schema",unit="fraction per second",effect="Vent soft-start rate (fraction/s)",evidence="configured value"},
    {section="altitude_control",path="climb_trim_boost",kind="number",min=1,max=20,bound="schema",fallbacks={1},unit="multiplier",effect="Leveling boost while building lift (x)",evidence="configured value"},
    {section="altitude_control",path="enabled",kind="boolean",bound="schema",required=true,effect="Enable altitude control",evidence="configured value"},
    {section="altitude_control",path="hover_capture_seconds",kind="number",min=1,max=60,bound="schema",required=true,fallbacks={5},unit="seconds",effect="Hover capture and control-response horizon",evidence="configured value"},
    {section="altitude_control",path="hover_max_vertical_speed",kind="number",min=0.01,max=0.5,bound="schema",required=true,fallbacks={0.2},unit="b/s",effect="Maximum vertical speed for hover capture",evidence="configured value"},
    {section="altitude_control",path="launch_settle_seconds",kind="integer",min=0,max=60,bound="schema",unit="seconds",effect="Startup settling interval",evidence="configured value"},
    {section="altitude_control",path="level_boost_max",kind="number",min=1,max=20,bound="schema",fallbacks={10},unit="multiplier",effect="Large-tilt boost maximum (x)",evidence="configured value"},
    {section="altitude_control",path="level_boost_start_blocks",kind="number",min=0.05,max=10,bound="schema",fallbacks={0.5},unit="blocks",effect="Large-tilt boost start (blocks)",evidence="configured value"},
    {section="altitude_control",path="level_damping_gain",kind="number",min=0,max=10,bound="schema",fallbacks={1},unit="multiplier",effect="Leveling damping (x)",evidence="configured value"},
    {section="altitude_control",path="level_lead_seconds",kind="number",min=0,max=60,bound="schema",unit="seconds",effect="Leveling look-ahead (s, 0 = measured lag)",evidence="configured value"},
    {section="altitude_control",path="lift_balance_tolerance_fraction",kind="number",min=0.01,max=0.25,bound="schema",required=true,fallbacks={0.2},unit="fraction",effect="Support-ratio correction bound",evidence="configured value"},
    {section="altitude_control",path="manual_fore_aft_trim_blocks",kind="number",min=-2,max=2,bound="schema",unit="blocks",effect="Fore/aft leveling offset",evidence="configured value"},
    {section="altitude_control",path="max_feed_fraction",kind="number",min=0.001,max=0.25,bound="schema",required=true,fallbacks={0.15},unit="fraction",effect="Inner speed-loop effort bound",evidence="configured value"},
    {section="altitude_control",path="max_trim_ceiling_change",kind="number",min=0,max=100,bound="schema",required=true,unit="ceiling",effect="Largest leveling trim applied to one chamber ceiling",evidence="configured value"},
    {section="altitude_control",path="max_vertical_speed",kind="number",min=0.01,max=5,bound="schema",required=true,fallbacks={1},unit="b/s",effect="Maximum requested hold vertical speed",evidence="configured value"},
    {section="altitude_control",path="minimum_world_y",kind="number",min=-2048,max=2048,bound="schema",required=true,unit="block Y",effect="Lower selected-altitude bound",evidence="configured value"},
    {section="altitude_control",path="startup_acceleration_seconds",kind="number",min=5,max=600,bound="schema",unit="seconds",effect="Time to reach startup climb V/S (s)",evidence="configured value"},
    {section="altitude_control",path="startup_braking_lookahead_seconds",kind="number",min=5,max=120,bound="schema",unit="seconds",effect="Braking look-ahead (s)",evidence="configured value"},
    {section="altitude_control",path="startup_gas_target_m3_per_chamber",kind="integer",min=0,max=100000,bound="schema",unit="m3 per chamber",effect="Initial bulk-gas target per chamber",evidence="configured value"},
    {section="altitude_control",path="startup_max_vertical_speed",kind="number",min=0.01,max=20,bound="schema",unit="b/s",effect="Climb vertical-speed target while building lift",evidence="configured value"},
    {section="altitude_control",path="startup_vertical_speed_limit",kind="number",min=0.01,max=20,bound="schema",unit="b/s",effect="Hard vertical-speed guard while building lift",evidence="configured value"},
    {section="altitude_control",path="trim_ceiling_per_block",kind="number",min=0,max=50,bound="schema",required=true,fallbacks={0},unit="ceiling per block",effect="Leveling trim per block of corner altitude error",evidence="configured value"},
    {section="altitude_control",path="trim_deadband_blocks",kind="number",min=0,max=10,bound="schema",required=true,unit="blocks",effect="Corner altitude error ignored by leveling trim",evidence="configured value"},
    {section="altitude_control",path="trim_pid.derivative_filter_seconds",kind="number",min=0,max=100,minExclusive=true,bound="schema",required=true,unit="seconds",effect="trim pid derivative filter seconds",evidence="configured value"},
    {section="altitude_control",path="trim_pid.integral_limit",kind="number",min=0,max=100,bound="schema",required=true,unit="input-seconds",effect="trim pid integral limit",evidence="configured value"},
    {section="altitude_control",path="trim_pid.kd",kind="number",min=0,max=100,bound="schema",required=true,unit="output-seconds per input",effect="trim pid kd",evidence="configured value"},
    {section="altitude_control",path="trim_pid.ki",kind="number",min=0,max=100,bound="schema",required=true,unit="output per input-second",effect="trim pid ki",evidence="configured value"},
    {section="altitude_control",path="trim_slew_ceiling_per_second",kind="number",min=0.01,max=10,bound="schema",required=true,fallbacks={0},unit="ceiling per second",effect="Rate limit for leveling trim changes",evidence="configured value"},
    {section="altitude_control",path="tuning_confirmed",kind="boolean",bound="schema",required=true,effect="Owner confirmation that altitude tuning is commissioned",evidence="configured value"},
    {section="altitude_control",path="vertical_drag_support_per_bps",kind="number",min=0,max=0.05,bound="runtime",fallbacks={0.019},unit="fraction of weight per b/s",effect="Vertical-speed feedforward: extra support per commanded b/s to overcome vertical drag",evidence="measured estimate (October 22 recordings)"},
    {section="altitude_control",path="vertical_speed_pid.derivative_filter_seconds",kind="number",min=0,max=100,minExclusive=true,bound="schema",required=true,unit="seconds",effect="vertical speed pid derivative filter seconds",evidence="configured value"},
    {section="altitude_control",path="vertical_speed_pid.integral_limit",kind="number",min=0,max=100,bound="schema",required=true,unit="input-seconds",effect="vertical speed pid integral limit",evidence="configured value"},
    {section="altitude_control",path="vertical_speed_pid.kd",kind="number",min=0,max=100,bound="schema",required=true,unit="output-seconds per input",effect="vertical speed pid kd",evidence="configured value"},
    {section="altitude_control",path="vertical_speed_pid.ki",kind="number",min=0,max=100,bound="schema",required=true,unit="output per input-second",effect="vertical speed pid ki",evidence="configured value"},
    {section="altitude_control",path="vertical_speed_pid.kp",kind="number",min=0,max=100,bound="schema",required=true,unit="output per input",effect="vertical speed pid kp",evidence="configured value"},
    {section="thrust",path="command_ttl_seconds",kind="number",min=0.1,max=3,bound="schema",note="Config validation allows up to network.node_stale_seconds; propulsion refuses commands above 3 s",fallbacks={1},unit="seconds",effect="Primary/lateral command lease duration",evidence="configured value"},
    {section="thrust",path="direct_max_request",kind="number",min=0,max=1,minExclusive=true,bound="schema",fallbacks={0.25},unit="fraction of drive range",effect="Primary drive-request scale",evidence="configured value"},
    {section="thrust",path="drag_time_constant_seconds",kind="number",min=1,max=60,bound="runtime",fallbacks={5.5},unit="seconds",effect="Horizontal drag time constant used for speed prediction and anchor braking",evidence="measured estimate (recorded coast-down)"},
    {section="thrust",path="enabled",kind="boolean",bound="schema",required=true,effect="Enable core propulsion commands",evidence="configured value"},
    {section="thrust",path="front_back_strafe_percent",kind="number",min=50,max=150,bound="runtime",fallbacks={100},unit="percent",effect="Front lateral output during strafe, as a percentage of the back groups",evidence="configured value"},
    {section="thrust",path="heading_control.heading_rate_per_degree",kind="number",min=0,max=10,minExclusive=true,bound="schema",required=true,unit="(deg/s) per deg",effect="Commanded yaw rate per degree of heading error",evidence="configured value"},
    {section="thrust",path="heading_control.maximum_yaw_rate_degrees_per_second",kind="number",min=0.1,max=90,bound="schema",required=true,unit="deg/s",effect="Largest commanded yaw rate",evidence="configured value"},
    {section="thrust",path="heading_control.output_slew_per_second",kind="number",min=0.01,max=1,bound="schema",required=true,unit="yaw demand per second",effect="Rate limit for yaw demand changes",evidence="configured value"},
    {section="thrust",path="heading_control.rate_filter_seconds",kind="number",min=0.05,max=5,bound="schema",required=true,unit="seconds",effect="Measured yaw-rate filter time constant",evidence="configured value"},
    {section="thrust",path="heading_control.rate_pid.derivative_filter_seconds",kind="number",min=0,max=100,minExclusive=true,bound="schema",required=true,unit="seconds",effect="rate pid derivative filter seconds",evidence="configured value"},
    {section="thrust",path="heading_control.rate_pid.integral_limit",kind="number",min=0,max=100,bound="schema",required=true,unit="input-seconds",effect="rate pid integral limit",evidence="configured value"},
    {section="thrust",path="heading_control.rate_pid.kd",kind="number",min=0,max=100,bound="schema",required=true,unit="output-seconds per input",effect="rate pid kd",evidence="configured value"},
    {section="thrust",path="heading_control.rate_pid.ki",kind="number",min=0,max=100,bound="schema",required=true,unit="output per input-second",effect="rate pid ki",evidence="configured value"},
    {section="thrust",path="heading_control.rate_pid.kp",kind="number",min=0,max=100,bound="schema",required=true,unit="output per input",effect="rate pid kp",evidence="configured value"},
    {section="thrust",path="heading_control_enabled",kind="boolean",bound="schema",effect="Enable heading control",evidence="configured value"},
    {section="thrust",path="heading_control_verified",kind="boolean",bound="schema",effect="Owner verification gate for heading control",evidence="configured value"},
    {section="thrust",path="lateral_max_rpm",kind="integer",min=1,max=256,bound="schema",unit="RPM",effect="Maximum lateral shaft request",evidence="configured value"},
    {section="thrust",path="limits_verified",kind="boolean",bound="schema",effect="Owner verification gate for limits",evidence="configured value"},
    {section="thrust",path="manual_acceleration.maximum",kind="number",min=0,minExclusive=true,bound="schema",required=true,unit="b/s^2",effect="Forward acceleration limit for held throttle",evidence="configured value"},
    {section="thrust",path="manual_acceleration.minimum",kind="number",max=0,maxExclusive=true,bound="schema",required=true,unit="b/s^2",effect="Reverse acceleration limit for held throttle",evidence="configured value"},
    {section="thrust",path="manual_acceleration_enabled",kind="boolean",bound="schema",effect="Enable manual acceleration",evidence="configured value"},
    {section="thrust",path="manual_acceleration_pid.derivative_filter_seconds",kind="number",min=0,max=100,minExclusive=true,bound="schema",required=true,unit="seconds",effect="manual acceleration pid derivative filter seconds",evidence="configured value"},
    {section="thrust",path="manual_acceleration_pid.integral_limit",kind="number",min=0,max=100,bound="schema",required=true,unit="input-seconds",effect="manual acceleration pid integral limit",evidence="configured value"},
    {section="thrust",path="manual_acceleration_pid.kd",kind="number",min=0,max=100,bound="schema",required=true,unit="output-seconds per input",effect="manual acceleration pid kd",evidence="configured value"},
    {section="thrust",path="manual_acceleration_pid.ki",kind="number",min=0,max=100,bound="schema",required=true,unit="output per input-second",effect="manual acceleration pid ki",evidence="configured value"},
    {section="thrust",path="manual_acceleration_pid.kp",kind="number",min=0,max=100,bound="schema",required=true,unit="output per input",effect="manual acceleration pid kp",evidence="configured value"},
    {section="thrust",path="manual_acceleration_verified",kind="boolean",bound="schema",effect="Owner verification gate for manual acceleration",evidence="configured value"},
    {section="thrust",path="manual_speed_hold_gain",kind="number",min=0.01,max=10,bound="schema",fallbacks={0.5},unit="drive per b/s",effect="Manual speed-hold gain",evidence="configured value"},
    {section="thrust",path="mapping_verified",kind="boolean",bound="schema",effect="Owner verification gate for mapping",evidence="configured value"},
    {section="thrust",path="mixer_verified",kind="boolean",bound="schema",effect="Owner verification gate for mixer",evidence="configured value"},
    {section="thrust",path="primary_input_rpm",kind="integer",min=256,max=256,bound="schema",unit="RPM",effect="Verified primary supply speed",evidence="configured value"},
    {section="thrust",path="primary_max_rpm",kind="integer",min=1,max=256,bound="schema",unit="RPM",effect="Maximum primary shaft request",evidence="configured value"},
    {section="thrust",path="reverse_brake_margin_bps",kind="number",min=0,bound="runtime",fallbacks={math.huge},unit="b/s",effect="Overspeed margin before reverse braking at cruise; absent disables reverse braking",evidence="configured value"},
    {section="thrust",path="speed_control_enabled",kind="boolean",bound="schema",effect="Enable speed control",evidence="configured value"},
    {section="thrust",path="speed_control_verified",kind="boolean",bound="schema",effect="Owner verification gate for speed control",evidence="configured value"},
    {section="thrust",path="speed_feedforward_per_bps",kind="number",bound="none",fallbacks={0.031},unit="drive x pressure per b/s",effect="Initial cruise feedforward before learned bands exist (normalised at reference pressure)",evidence="measured estimate (cruise thrust at pressure 0.55)"},
    {section="thrust",path="speed_integrate_band_bps",kind="number",bound="none",fallbacks={2},unit="b/s",effect="Speed error band inside which the speed PID integrates",evidence="configured value"},
    {section="thrust",path="speed_lead_seconds",kind="number",min=0,max=5,bound="runtime",fallbacks={2},unit="seconds",effect="Target-ramp lead for selected-speed changes",evidence="configured value"},
    {section="thrust",path="speed_output_slew_per_second",kind="number",min=0.01,max=1,bound="schema",fallbacks={0.25},unit="drive per second",effect="General speed-loop output slew",evidence="configured value"},
    {section="thrust",path="speed_overspeed_release_per_second",kind="number",min=0.01,max=1,bound="schema",unit="drive per second",effect="Same-direction overspeed thrust-release slew",evidence="configured value"},
    {section="thrust",path="speed_pid.derivative_filter_seconds",kind="number",min=0,max=100,minExclusive=true,bound="schema",required=true,unit="seconds",effect="speed pid derivative filter seconds",evidence="configured value"},
    {section="thrust",path="speed_pid.integral_limit",kind="number",min=0,max=100,bound="schema",required=true,unit="input-seconds",effect="speed pid integral limit",evidence="configured value"},
    {section="thrust",path="speed_pid.kd",kind="number",min=0,max=100,bound="schema",required=true,unit="output-seconds per input",effect="speed pid kd",evidence="configured value"},
    {section="thrust",path="speed_pid.ki",kind="number",min=0,max=100,bound="schema",required=true,unit="output per input-second",effect="speed pid ki",evidence="configured value"},
    {section="thrust",path="speed_pid.kp",kind="number",min=0,max=100,bound="schema",required=true,unit="output per input",effect="speed pid kp",evidence="configured value"},
    {section="thrust",path="speed_target_rate_bps2",kind="number",min=0,max=10,minExclusive=true,bound="schema",required=true,unit="b/s^2",effect="Selected-speed target ramp",evidence="configured value"},
    {section="thrust",path="speed_trim_down_limit",kind="number",min=0,max=1,bound="runtime",fallbacks={0.3},unit="fraction of cruise drive",effect="Lowest PID trim, as a fraction of cruise feedforward, before reverse is allowed",evidence="configured value"},
    {section="thrust",path="status_stale_seconds",kind="number",min=0.1,max=10,bound="schema",unit="seconds",effect="Thrust status freshness limit",evidence="configured value"},
    {section="thrust",path="zero_brake_gain",kind="number",min=0,max=1,bound="runtime",fallbacks={0.06},unit="drive per b/s",effect="SEL 0 proportional brake: reverse drive per b/s of predicted speed",evidence="configured value"},
    {section="thrust",path="zero_brake_stop_bps",kind="number",min=0,bound="runtime",fallbacks={2},unit="b/s",effect="SEL 0 coast entry speed; braking stops below this speed",evidence="configured value"},
    {section="thrust",path="zero_hold_capture_speed",kind="number",min=0,bound="runtime",fallbacks={0.1},unit="b/s",effect="Speed below which zero-speed hold captures",evidence="configured value"},
}

local index = {}
local keys = {}
local numeric = {}
for _, entry in ipairs(Registry.entries) do
    local id = entry.section .. "." .. entry.path
    index[id] = entry
    -- Split once here: Registry.number runs on every control tick.
    local parts = {}
    for key in entry.path:gmatch("[^.]+") do parts[#parts + 1] = key end
    keys[id] = parts
    if entry.bound ~= "schema" and entry.fallbacks and #entry.fallbacks == 1 then numeric[id] = entry end
end

-- Summary: Return the registry entry for a "section.path" id, or nil for an unregistered setting.
function Registry.entry(id)
    return index[id]
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

-- Summary: Check a candidate value against an entry's kind and bounds; return true or false and a reason.
function Registry.check(entry, value)
    local name = entry.section .. "." .. entry.path
    if entry.kind == "boolean" then
        if type(value) ~= "boolean" then return false, name .. " must be true or false" end
        return true
    end
    if not finite(value) then return false, name .. " must be a finite number" end
    if entry.kind == "integer" and value % 1 ~= 0 then return false, name .. " must be a whole number" end
    if entry.min ~= nil and (value < entry.min or (entry.minExclusive and value == entry.min)) then
        return false, name .. (entry.minExclusive and " must be above " or " must be at least ") .. tostring(entry.min)
    end
    if entry.max ~= nil and (value > entry.max or (entry.maxExclusive and value == entry.max)) then
        return false, name .. (entry.maxExclusive and " must be below " or " must be at most ") .. tostring(entry.max)
    end
    return true
end

-- Summary: Read a runtime-bounded or unbounded numeric setting with its registered clamp and fallback.
-- Matches the inline form `finite(x) and clamp(x,min,max) or fallback` used before the registry.
function Registry.number(node, id)
    local entry = numeric[id]
    if entry == nil then
        error("Registry.number serves registered single-fallback runtime settings, not " .. tostring(id), 2)
    end
    local value = node
    for _, key in ipairs(keys[id]) do
        if type(value) ~= "table" then value = nil; break end
        value = value[key]
    end
    if not finite(value) then return entry.fallbacks[1] end
    if entry.max ~= nil then value = math.min(entry.max, value) end
    if entry.min ~= nil then value = math.max(entry.min, value) end
    return value
end

return Registry
