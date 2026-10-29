-- @ama-section: Persistent configuration | JSON validation, settings edits and file replacement.
-- Navigator information frequency revision v1
-- JSON configuration and persistent settings for core 35.
-- Keep disk access here so control and display code never silently invents defaults.
local Storage = {}
local NavigationSettings=require("avionics.navigation_settings")
local InputTuning=require("avionics.input_tuning")

local SETTINGS_SCHEMA = 1
local MAX_JSON_BYTES = 262144

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function object(value)
    return type(value) == "table"
end

local function nonEmpty(value, maxLength)
    return type(value) == "string" and #value > 0 and #value <= (maxLength or 128)
end

local function itemId(value)
    return type(value) == "string" and string.match(value, "^[^:]+:[^:]+$") ~= nil
end

function Storage.finite(value)
    return finite(value)
end

-- @ama-section: Persistent configuration | JSON validation, settings edits and file replacement.
-- @ama-summary: Construct the supported initial local display settings.
function Storage.defaultSettings()
    return {
        schema_version = SETTINGS_SCHEMA,
        display_page = "FLIGHT",
        -- Stored selected targets are intentionally absent. A restart never
        -- restores active control authority or starts an actuator.
    }
end

function Storage.validateSettings(settings)
    if not object(settings) then return false, "settings must be a JSON object" end
    if settings.schema_version ~= SETTINGS_SCHEMA then return false, "unsupported settings schema_version" end
    local pages = { FLIGHT = true, NAV = true, SHIP = true, SETTINGS = true }
    if not pages[settings.display_page] then return false, "display_page must be FLIGHT, NAV, SHIP, or SETTINGS" end
    return true
end

-- @ama-summary: Validate required configuration objects, frequency pairs and numeric bounds.
function Storage.validateConfig(config)
    if not object(config) then return false, "configuration must be a JSON object" end
    local navOk,navReason=NavigationSettings.ensure(config)
    if not navOk then return false,navReason end
    if config.schema_version ~= 1 then return false, "unsupported config schema_version (expected 1)" end
    if config.role ~= "core" then return false, "configuration role must be core" end
    if not nonEmpty(config.protocol, 64) then return false, "protocol must be a bounded non-empty string" end

    local ok, reason

    local network = config.network
    if not object(network) then return false, "network settings are missing" end
    for _, name in ipairs({ "hello_interval_seconds", "sample_interval_seconds", "broadcast_interval_seconds",
        "node_stale_seconds", "sensor_stale_seconds", "commission_wait_seconds", "commission_ack_seconds" }) do
        if not finite(network[name]) or network[name] <= 0 or network[name] > 60 then
            return false, "network." .. name .. " must be greater than 0 and at most 60 seconds"
        end
    end
    if not finite(network.max_providers) or network.max_providers < 1 or network.max_providers > 64 or
        network.max_providers % 1 ~= 0 then
        return false, "network.max_providers must be an integer from 1 through 64"
    end
    if not finite(network.max_sequence) or network.max_sequence < 100 or network.max_sequence > 2147483647 or
        network.max_sequence % 1 ~= 0 then
        return false, "network.max_sequence must be an integer from 100 through 2147483647"
    end

    local frequencies = config.input_frequencies
    if not object(frequencies) then return false, "input_frequencies are missing" end
    local required = {
        "left_press", "left_lift", "right_press", "right_lift",
        "prop_forward", "prop_reverse", "ap_disconnect", "altitude_up", "altitude_down",
    }
    local seen = {}
    for _, key in ipairs(required) do
        local pair = frequencies[key]
        if type(pair) ~= "table" or not itemId(pair[1]) or not itemId(pair[2]) then
            return false, "input_frequencies." .. key .. " must contain two item IDs in namespace:item form"
        end
        local encoded = pair[1] .. "\\0" .. pair[2]
        if seen[encoded] then return false, "input frequency pair is duplicated: " .. key end
        seen[encoded] = true
    end
    if not object(config.hardware) then return false, "hardware settings are missing" end
    for _, name in ipairs({"navigation_table", "gimbal_sensor", "altitude_sensor"}) do
        local value = config.hardware[name]
        if value ~= nil and (type(value) ~= "string" or #value == 0 or #value > 128) then
            return false, "hardware." .. name .. " must be an exact bounded peripheral name"
        end
    end
    if config.hardware.velocity_sensors ~= nil then
        if type(config.hardware.velocity_sensors) ~= "table" or #config.hardware.velocity_sensors > 3 then
            return false, "hardware.velocity_sensors must be a list of at most three names"
        end
        local seen = {}
        for _, name in ipairs(config.hardware.velocity_sensors) do
            if type(name) ~= "string" or #name == 0 or #name > 128 or seen[name] then
                return false, "velocity sensor names must be bounded and unique"
            end
            seen[name] = true
        end
    end
    local bridge = config.hardware.link_bridge
    if type(bridge) ~= "string" or #bridge > 128 then
        return false, "hardware.link_bridge must be an empty string for unique discovery or a peripheral name"
    end
    if config.hardware.discover~=nil and type(config.hardware.discover)~="boolean" then
        return false,"hardware.discover must be boolean"
    end
    local mainMonitor = config.hardware.main_monitor
    if type(mainMonitor) ~= "string" or #mainMonitor > 128 then
        return false, "hardware.main_monitor must be an empty string or a peripheral name"
    end

    local geometry = config.geometry
    if not object(geometry) or type(geometry.orientation_verified) ~= "boolean" or
        type(geometry.velocity_frame_verified) ~= "boolean" then
        return false, "geometry verification flags are required"
    end
    if geometry.orientation_verified then
        local bow = geometry.bow_forward
        if not object(bow) or not finite(bow.x) or not finite(bow.y) or not finite(bow.z) then
            return false, "verified orientation requires a numeric geometry.bow_forward"
        end
        local length = math.sqrt(bow.x * bow.x + bow.y * bow.y + bow.z * bow.z)
        if length < 0.999 or length > 1.001 or math.abs(bow.y) > 0.001 then
            return false, "geometry.bow_forward must be a normalized, horizontal, measured local direction"
        end
    end
    if geometry.velocity_forward~=nil then
        local axis=geometry.velocity_forward
        if not object(axis) or not finite(axis.x) or not finite(axis.y) or not finite(axis.z) then
            return false,"geometry.velocity_forward must be a numeric sensor-frame direction"
        end
        local length=math.sqrt(axis.x^2+axis.y^2+axis.z^2)
        if length<.999 or length>1.001 or math.abs(axis.y)>.001 then
            return false,"geometry.velocity_forward must be normalized and horizontal"
        end
    end
    if geometry.velocity_frame_verified and geometry.velocity_unit ~= "blocks_per_second" then
        return false, "verified velocity requires explicit velocity_unit blocks_per_second"
    end

    local commissioning = config.commissioning
    if not object(commissioning) or type(commissioning.enabled) ~= "boolean" or
        type(commissioning.confirm_supported) ~= "boolean" then
        return false, "commissioning gates must be explicit booleans"
    end

    if config.vent_startup_enabled~=nil and type(config.vent_startup_enabled)~="boolean" then
        return false,"vent_startup_enabled must be a boolean"
    end
    if config.vent_startup_ack_seconds~=nil and (not finite(config.vent_startup_ack_seconds) or
        config.vent_startup_ack_seconds<2 or config.vent_startup_ack_seconds>60) then
        return false,"vent_startup_ack_seconds must be between 2 and 60"
    end
    if config.maintenance~=nil then
        local m=config.maintenance
        if not object(m) or not finite(m.restart_altitude_limit) or m.restart_altitude_limit< -2048 or
            m.restart_altitude_limit>2048 or not finite(m.confirmation_seconds) or m.confirmation_seconds<5 or
            m.confirmation_seconds>60 or not finite(m.reconnect_timeout_seconds) or
            m.reconnect_timeout_seconds<5 or m.reconnect_timeout_seconds>60 then return false,"maintenance limits invalid" end
    end
    if config.tuning~=nil then
        local t=config.tuning
        if not object(t) or type(t.enabled)~="boolean" or not finite(t.speed_step) or t.speed_step<=0 or t.speed_step>.1 or
            not finite(t.altitude_step) or t.altitude_step<=0 or t.altitude_step>1 or
            not finite(t.duration_seconds) or t.duration_seconds<5 or t.duration_seconds>30 then return false,"bounded PID tuning limits invalid" end
    end
    local cockpit=config.cockpit
    if cockpit~=nil then
        if not object(cockpit) or not object(config.altitude_control) then return false,"cockpit requires altitude_control bounds" end
        local inputOK,inputReason=InputTuning.ensure(cockpit)
        if not inputOK then return false,inputReason end
        local limits={input_interval_seconds={0.05,0.5},maximum_input_gap_seconds={0.1,10},
            coarse_heading_degrees={1,90},fine_heading_degrees={0.1,10},heading_repeat_seconds={0.1,2},
            repeat_delay_seconds={0.1,2},manual_yaw_sensitivity_percent={1,100},
            altitude_rate_slow={0.1,10},altitude_rate_medium={0.1,20},altitude_rate_fast={0.1,50},
            altitude_medium_after_seconds={1,10},altitude_fast_after_seconds={2,30}}
        for key,bounds in pairs(limits) do
            if not finite(cockpit[key]) or cockpit[key]<bounds[1] or cockpit[key]>bounds[2] then
                return false,"cockpit."..key.." is outside its documented bounds"
            end
        end
        for key,bounds in pairs({lateral_strength_percent={5,100},lateral_offset_step_blocks={.1,10},
            lateral_hold_delay_seconds={.1,3},lateral_adjustment_blocks_per_second={.1,10}}) do
            if cockpit[key]~=nil and (not finite(cockpit[key]) or cockpit[key]<bounds[1] or cockpit[key]>bounds[2]) then
                return false,"cockpit."..key.." is outside its documented bounds"
            end
        end
        if cockpit.input_stale_seconds~=nil and (not finite(cockpit.input_stale_seconds) or
            cockpit.input_stale_seconds<0.1 or cockpit.input_stale_seconds>10) then return false,"cockpit input stale limit invalid" end
        if cockpit.fine_heading_degrees>cockpit.coarse_heading_degrees or
            cockpit.input_interval_seconds>=cockpit.maximum_input_gap_seconds or
            cockpit.altitude_medium_after_seconds>=cockpit.altitude_fast_after_seconds or
            cockpit.altitude_rate_slow>cockpit.altitude_rate_medium or cockpit.altitude_rate_medium>cockpit.altitude_rate_fast then
            return false,"cockpit timing / sensitivity ordering invalid"
        end
        if cockpit.speed_selection_blocks_per_second_per_second~=nil then
            if not finite(cockpit.speed_selection_blocks_per_second_per_second) or
                cockpit.speed_selection_blocks_per_second_per_second<=0 or cockpit.speed_selection_blocks_per_second_per_second>10 or
                not finite(cockpit.minimum_selected_speed) or not finite(cockpit.maximum_selected_speed) or
                cockpit.minimum_selected_speed>=cockpit.maximum_selected_speed or
                math.abs(cockpit.minimum_selected_speed)>100 or math.abs(cockpit.maximum_selected_speed)>100 then
                return false,"cockpit speed selection requires nonnegative finite speed bounds and a finite rate"
            end
        end
    end
    local thrust=config.thrust
    if thrust~=nil then
        if not object(thrust) or type(thrust.enabled)~="boolean" then
            return false,"thrust requires an explicit enabled boolean"
        end
        if thrust.primary_max_rpm~=nil and (not finite(thrust.primary_max_rpm) or
            thrust.primary_max_rpm<1 or thrust.primary_max_rpm>256 or thrust.primary_max_rpm%1~=0) then
            return false,"thrust.primary_max_rpm must be an integer between 1 and 256 RPM"
        end
        if thrust.primary_input_rpm~=nil and thrust.primary_input_rpm~=256 then
            return false,"thrust.primary_input_rpm must match the verified 256 RPM supply"
        end
        if thrust.lateral_max_rpm~=nil and (not finite(thrust.lateral_max_rpm) or
            thrust.lateral_max_rpm<1 or thrust.lateral_max_rpm>256 or thrust.lateral_max_rpm%1~=0) then
            return false,"thrust.lateral_max_rpm must be an integer between 1 and 256 RPM"
        end
        if thrust.manual_speed_hold_gain~=nil and (not finite(thrust.manual_speed_hold_gain) or
            thrust.manual_speed_hold_gain<.01 or thrust.manual_speed_hold_gain>10) then
            return false,"thrust.manual_speed_hold_gain must be between .01 and 10"
        end
        for _,key in ipairs({"limits_verified","mapping_verified","direct_rpm_verified",
            "manual_acceleration_verified","speed_control_verified","mixer_verified","reverse_verified",
            "heading_control_verified","manual_acceleration_enabled","speed_control_enabled","heading_control_enabled"}) do
            if thrust[key]~=nil and type(thrust[key])~="boolean" then return false,"thrust."..key.." must be boolean" end
        end
        if thrust.command_ttl_seconds~=nil and (not finite(thrust.command_ttl_seconds) or
            thrust.command_ttl_seconds<0.1 or thrust.command_ttl_seconds>network.node_stale_seconds) then
            return false,"thrust.command_ttl_seconds must be between 0.1 and node_stale_seconds"
        end
        if thrust.status_stale_seconds~=nil and (not finite(thrust.status_stale_seconds) or
            thrust.status_stale_seconds<0.1 or thrust.status_stale_seconds>10) then
            return false,"thrust.status_stale_seconds must be between 0.1 and 10 seconds"
        end
        if thrust.direct_max_request~=nil and (not finite(thrust.direct_max_request) or
            thrust.direct_max_request<=0 or thrust.direct_max_request>1) then
            return false,"thrust.direct_max_request must be in (0,1] of the configured drive range"
        end
        if thrust.primary_rpm_limits~=nil then
            local limits=thrust.primary_rpm_limits
            if not object(limits) then return false,"thrust.primary_rpm_limits must be an object" end
            for _,drive in ipairs({"primary-left","primary-right"}) do
                local item=limits[drive]
                if not object(item) or not finite(item.minimum) or not finite(item.maximum) or
                    item.minimum>=0 or item.maximum<=0 then return false,"thrust RPM limits require signed bounds for "..drive end
            end
        end
        if thrust.manual_acceleration~=nil then
            local item=thrust.manual_acceleration
            if not object(item) or not finite(item.minimum) or not finite(item.maximum) or
                item.minimum>=0 or item.maximum<=0 then return false,"thrust.manual_acceleration requires negative and positive limits" end
        end
        if thrust.acceleration_drive_limits~=nil then
            if not object(thrust.acceleration_drive_limits) then return false,"thrust.acceleration_drive_limits must be an object" end
            for _,drive in ipairs({"primary-left","primary-right"}) do
                local item=thrust.acceleration_drive_limits[drive]
                if not object(item) or not finite(item.minimum) or not finite(item.maximum) or
                    item.minimum>=0 or item.maximum<=0 then return false,"thrust acceleration scale missing for "..drive end
            end
        end
        if thrust.speed_target_rate_bps2~=nil and (not finite(thrust.speed_target_rate_bps2) or
            thrust.speed_target_rate_bps2<=0 or thrust.speed_target_rate_bps2>10) then
            return false,"thrust.speed_target_rate_bps2 must be in (0,10]"
        end
        if thrust.speed_output_slew_per_second~=nil and (not finite(thrust.speed_output_slew_per_second) or
            thrust.speed_output_slew_per_second<0.01 or thrust.speed_output_slew_per_second>1) then
            return false,"thrust.speed_output_slew_per_second must be in [0.01,1]"
        end
        if thrust.speed_pid~=nil then
            local gains=thrust.speed_pid
            if not object(gains) then return false,"thrust.speed_pid must be an object" end
            for _,key in ipairs({"kp","ki","kd","integral_limit","derivative_filter_seconds"}) do
                if not finite(gains[key]) or gains[key]<0 or gains[key]>100 then return false,"thrust.speed_pid."..key.." invalid" end
            end
            if gains.derivative_filter_seconds<=0 then return false,"thrust.speed_pid requires a positive derivative filter" end
        end
        if thrust.manual_acceleration_pid~=nil then
            local gains=thrust.manual_acceleration_pid
            if not object(gains) then return false,"thrust.manual_acceleration_pid must be an object" end
            for _,key in ipairs({"kp","ki","kd","integral_limit","derivative_filter_seconds"}) do
                if not finite(gains[key]) or gains[key]<0 or gains[key]>100 then
                    return false,"thrust.manual_acceleration_pid."..key.." invalid"
                end
            end
            if gains.derivative_filter_seconds<=0 then
                return false,"thrust.manual_acceleration_pid requires a positive derivative filter"
            end
        end
        if thrust.heading_control~=nil then
            local control=thrust.heading_control
            if not object(control) or not finite(control.maximum_yaw_rate_degrees_per_second) or
                control.maximum_yaw_rate_degrees_per_second<0.1 or control.maximum_yaw_rate_degrees_per_second>90 or
                not finite(control.heading_rate_per_degree) or control.heading_rate_per_degree<=0 or
                control.heading_rate_per_degree>10 or not finite(control.rate_filter_seconds) or
                control.rate_filter_seconds<0.05 or control.rate_filter_seconds>5 or
                not finite(control.output_slew_per_second) or control.output_slew_per_second<0.01 or
                control.output_slew_per_second>1 or not object(control.rate_pid) then
                return false,"thrust.heading_control requires bounded yaw rate, heading gain, filters, slew, and PID"
            end
            local gains=control.rate_pid
            for _,key in ipairs({"kp","ki","kd","integral_limit","derivative_filter_seconds"}) do
                if not finite(gains[key]) or gains[key]<0 or gains[key]>100 then
                    return false,"thrust.heading_control.rate_pid."..key.." invalid"
                end
            end
            if gains.derivative_filter_seconds<=0 then
                return false,"thrust.heading_control.rate_pid requires a positive derivative filter"
            end
        end
        if thrust.lateral_mixer~=nil then
            local mixer=thrust.lateral_mixer
            if not object(mixer) then return false,"thrust.lateral_mixer must be an object" end
            for _,quad in ipairs({"lb","rb","ls","rs"}) do
                local item=mixer[quad]
                if not object(item) or not finite(item.side_gain) or item.side_gain<0 or item.side_gain>1 or
                    (item.side_sign~=1 and item.side_sign~=-1) or not finite(item.yaw_gain) or
                    item.yaw_gain<0 or item.yaw_gain>1 or
                    item.yaw_sign~=((quad=="lb" or quad=="rb") and 1 or -1) then
                    return false,"thrust.lateral_mixer requires bounded side/yaw gains and signs for "..quad
                end
            end
        end
        if thrust.enabled then
            if thrust.limits_verified~=true or thrust.mapping_verified~=true or
                not finite(thrust.command_ttl_seconds) then return false,"enabled thrust requires verified limits/mapping and a command TTL" end
            if not finite(thrust.direct_max_request) then
                return false,"enabled thrust requires direct_max_request; RPM limits do not set controller maxLevel"
            end
        end
        if thrust.direct_rpm_verified and not thrust.primary_rpm_limits then
            return false,"direct RPM requires verified primary_rpm_limits"
        end
        if (thrust.manual_acceleration_verified or thrust.manual_acceleration_enabled) and (not thrust.manual_acceleration or
            not thrust.manual_acceleration_pid) then
            return false,"manual acceleration requires signed setpoint bounds and PID gains"
        end
        if thrust.speed_control_verified or thrust.speed_control_enabled then
            if not thrust.speed_target_rate_bps2 or not thrust.speed_pid or
                config.geometry.velocity_frame_verified~=true then
                return false,"speed control requires verified signed speed, target rate, and gains"
            end
        end
        if thrust.mixer_verified and not thrust.lateral_mixer then
            return false,"verified side/yaw mixing requires per-quadrant lateral_mixer values"
        end
        if (thrust.heading_control_verified or thrust.heading_control_enabled) and (not thrust.heading_control or
            config.geometry.orientation_verified~=true) then
            return false,"heading control requires an orientation measurement and configured feedback limits"
        end
        if thrust.reverse_verified and (thrust.direct_rpm_verified~=true or
            not finite(thrust.reverse_speed_raw_deadband) or thrust.reverse_speed_raw_deadband<0) then
            return false,"reverse requires verified direct RPM, gearshift, and raw-speed rundown bound"
        end
    end
    local control=config.altitude_control
    if control~=nil then
        if not object(control) or type(control.enabled)~="boolean" or type(control.tuning_confirmed)~="boolean" then
            return false,"altitude_control requires explicit enabled and tuning_confirmed booleans"
        end
        local limits={minimum_world_y={-2048,2048},maximum_world_y={-2048,2048},
            target_rate_blocks_per_second={0.01,10},max_vertical_speed={0.01,5},
            max_feed_fraction={0.001,0.25},hover_capture_seconds={1,60},hover_max_vertical_speed={0.01,0.5},
            trim_deadband_blocks={0,10},trim_ceiling_per_block={0,50},max_trim_ceiling_change={0,100},
            trim_slew_ceiling_per_second={0.01,10},lift_balance_tolerance_fraction={0.01,0.25}}
        for name,bounds in pairs(limits) do
            if not finite(control[name]) or control[name]<bounds[1] or control[name]>bounds[2] then
                return false,"altitude_control."..name.." is outside its documented bounds"
            end
        end
        -- These fields were added for the faster BUILDING_LIFT phase. Older
        -- schema-1 configurations inherit the former max-vertical-speed
        -- target and its former max+1 hard guard without changing HOLDING.
        local startupTarget=control.startup_max_vertical_speed
        if startupTarget==nil then startupTarget=control.max_vertical_speed end
        local startupLimit=control.startup_vertical_speed_limit
        if startupLimit==nil then startupLimit=control.max_vertical_speed+1 end
        if not finite(startupTarget) or startupTarget<0.01 or startupTarget>20 then
            return false,"altitude_control.startup_max_vertical_speed must be finite and between 0.01 and 20"
        end
        if not finite(startupLimit) or startupLimit<0.01 or startupLimit>20 then
            return false,"altitude_control.startup_vertical_speed_limit must be finite and between 0.01 and 20"
        end
        if startupTarget>startupLimit then
            return false,"altitude_control.startup_max_vertical_speed cannot exceed startup_vertical_speed_limit"
        end
        local startupShaping={startup_acceleration_seconds={5,600},startup_braking_lookahead_seconds={5,120},
            ceiling_soft_start_rate={0.0005,0.05},ceiling_rise_rate={0.005,0.1},ceiling_fast_rate={0.02,0.25},
            climb_trim_boost={1,20},level_damping_gain={0,10},level_lead_seconds={0,60}}
        for name,bounds in pairs(startupShaping) do
            local value=control[name]
            if value~=nil and (not finite(value) or value<bounds[1] or value>bounds[2]) then
                return false,"altitude_control."..name.." must be between "..bounds[1].." and "..bounds[2]
            end
        end
        local startupGasTarget=control.startup_gas_target_m3_per_chamber
        if control.launch_settle_seconds~=nil and (not finite(control.launch_settle_seconds) or
            control.launch_settle_seconds<0 or control.launch_settle_seconds>60 or control.launch_settle_seconds%1~=0) then
            return false,"altitude_control.launch_settle_seconds must be an integer between 0 and 60 seconds"
        end
        if startupGasTarget~=nil and
            (not finite(startupGasTarget) or startupGasTarget<0 or startupGasTarget>100000 or startupGasTarget%1~=0) then
            return false,"altitude_control.startup_gas_target_m3_per_chamber must be an integer between 0 and 100000 m3 per chamber"
        end
        if control.manual_fore_aft_trim_blocks~=nil and
            (not finite(control.manual_fore_aft_trim_blocks) or
             control.manual_fore_aft_trim_blocks< -2 or control.manual_fore_aft_trim_blocks>2) then
            return false,"altitude_control.manual_fore_aft_trim_blocks must be between -2 and 2 blocks"
        end
        if control.minimum_world_y>=control.maximum_world_y then return false,"altitude world Y bounds are reversed" end
        -- Optional for older installations; Flight supplies conservative
        -- defaults, which the existing settings writer persists as JSON.
        if control.trim_pid~=nil then
            if not object(control.trim_pid) then return false,"altitude_control.trim_pid invalid" end
            for _,key in ipairs({"ki","kd","integral_limit","derivative_filter_seconds"}) do
                local value=control.trim_pid[key]
                if not finite(value) or value<0 or value>100 then return false,"trim_pid."..key.." invalid" end
            end
            if control.trim_pid.derivative_filter_seconds<=0 then return false,"trim_pid requires positive derivative filter seconds" end
        end
        for _,name in ipairs({"altitude_pid","vertical_speed_pid"}) do
            local gains=control[name]
            if not object(gains) then return false,"altitude_control."..name.." is missing" end
            for _,key in ipairs({"kp","ki","kd","integral_limit","derivative_filter_seconds"}) do
                if not finite(gains[key]) or gains[key]<0 or gains[key]>100 then return false,name.."."..key.." invalid" end
            end
            if gains.derivative_filter_seconds<=0 then return false,name.." requires positive derivative filter seconds" end
        end
    end
    return true
end

local function api(dependencies)
    dependencies = dependencies or {}
    return dependencies.fs or fs, dependencies.textutils or textutils
end

-- @ama-summary: Read and decode a JSON document through the configured filesystem dependency.
function Storage.readJson(path, dependencies)
    local fsApi, jsonApi = api(dependencies)
    if not fsApi or type(fsApi.open) ~= "function" or not jsonApi or type(jsonApi.unserializeJSON) ~= "function" then
        return nil, "ComputerCraft filesystem or JSON support is unavailable"
    end
    local okOpen, handle = pcall(fsApi.open, path, "r")
    if not okOpen or not handle then return nil, "could not open " .. path .. ": " .. tostring(handle) end
    local okRead, text = pcall(handle.readAll)
    pcall(handle.close)
    if not okRead or type(text) ~= "string" then return nil, "could not read " .. path .. ": " .. tostring(text) end
    if #text > MAX_JSON_BYTES then return nil, path .. " exceeds the JSON size limit" end
    local okDecode, value = pcall(jsonApi.unserializeJSON, text)
    if not okDecode or type(value) ~= "table" then
        return nil, "invalid JSON in " .. path .. ": " .. tostring(value)
    end
    return value
end

-- @ama-summary: Read the configuration document and validate its schema and fields.
function Storage.loadConfig(path, dependencies)
    local config, reason = Storage.readJson(path or "avionics/config.json", dependencies)
    if not config then return nil, reason end
    local ok, invalid = Storage.validateConfig(config)
    if not ok then return nil, "invalid core configuration: " .. tostring(invalid) end
    if config.thrust then
        config.thrust.primary_max_rpm=config.thrust.primary_max_rpm or
            math.max(1,math.floor((config.thrust.direct_max_request or .25)*256+.5))
        config.thrust.direct_max_request=config.thrust.primary_max_rpm/256
    end
    local control=config.altitude_control
    if control then
        if control.startup_max_vertical_speed==nil then
            control.startup_max_vertical_speed=control.max_vertical_speed
        end
        if control.startup_vertical_speed_limit==nil then
            control.startup_vertical_speed_limit=control.max_vertical_speed+1
        end
        if control.startup_gas_target_m3_per_chamber==nil then
            control.startup_gas_target_m3_per_chamber=0
        end
        if control.launch_settle_seconds==nil then control.launch_settle_seconds=10 end
        local shapingDefaults={startup_acceleration_seconds=60,startup_braking_lookahead_seconds=30,
            ceiling_soft_start_rate=0.002,ceiling_rise_rate=0.02,ceiling_fast_rate=0.08,climb_trim_boost=1,level_damping_gain=1,level_lead_seconds=0}
        for name,value in pairs(shapingDefaults) do
            if control[name]==nil then control[name]=value end
        end
    end
    return config
end

-- @ama-summary: Read validated display settings or construct the supported initial settings.
function Storage.loadSettings(path, dependencies)
    path = path or "avionics/data/settings.json"
    local fsApi = select(1, api(dependencies))
    if not fsApi or type(fsApi.exists) ~= "function" then
        return nil, "ComputerCraft filesystem is unavailable"
    end

    local primary, primaryError
    if fsApi.exists(path) then primary, primaryError = Storage.readJson(path, dependencies) end
    if primary then
        local ok, invalid = Storage.validateSettings(primary)
        if ok then return primary end
        primaryError = "invalid settings: " .. tostring(invalid)
    elseif not primaryError then
        primaryError = "settings file is missing"
    end

    local backupPath = path .. ".bak"
    if fsApi.exists(backupPath) then
        local backup, backupError = Storage.readJson(backupPath, dependencies)
        if backup then
            local ok, invalid = Storage.validateSettings(backup)
            if ok then return backup, "recovered settings from backup after primary failure: " .. tostring(primaryError) end
            backupError = "backup settings are invalid: " .. tostring(invalid)
        end
        return Storage.defaultSettings(), tostring(primaryError) .. "; " .. tostring(backupError) .. "; using safe defaults"
    end
    return Storage.defaultSettings(), tostring(primaryError) .. "; using safe defaults"
end

-- @ama-summary: Serialize and replace a JSON document through its validated storage path.
function Storage.writeJson(path, value, dependencies)
    local fsApi, jsonApi = api(dependencies)
    if not fsApi or type(fsApi.open) ~= "function" or type(fsApi.move) ~= "function" or
        type(fsApi.delete) ~= "function" or type(fsApi.exists) ~= "function" or
        not jsonApi or type(jsonApi.serializeJSON) ~= "function" then
        return false, "ComputerCraft filesystem or JSON serialization is unavailable"
    end
    local okEncode, encoded = pcall(jsonApi.serializeJSON, value)
    if not okEncode or type(encoded) ~= "string" then return false, "could not encode JSON: " .. tostring(encoded) end
    if #encoded > MAX_JSON_BYTES then return false, "JSON exceeds the size limit" end

    local directory = type(fsApi.getDir) == "function" and fsApi.getDir(path) or ""
    if directory ~= "" and type(fsApi.makeDir) == "function" then
        local okDir, dirError = pcall(fsApi.makeDir, directory)
        if not okDir then return false, "could not create settings directory: " .. tostring(dirError) end
    end

    -- A locked/denied backup is a persistence failure, not a reason to stop
    -- the bridge or control runtime. Cleanup must also never throw over the
    -- original write error. Keep the primary untouched if rotation fails.
    -- @ama-summary: Remove the selected stored entry and update its containing collection.
    local function remove(file)
        local okExists,exists=pcall(fsApi.exists,file)
        if not okExists then return false,tostring(exists) end
        if not exists then return true end
        local okDelete,result=pcall(fsApi.delete,file)
        if not okDelete or result==false then return false,tostring(result) end
        return true
    end
    local temporary, backup = path .. ".tmp", path .. ".bak"
    local cleanOk,cleanError=remove(temporary)
    if not cleanOk then return false,"could not remove temporary JSON file: "..tostring(cleanError) end
    local openOk, handle, openReason = pcall(fsApi.open, temporary, "w")
    if not openOk or not handle then
        local detail = not openOk and handle or openReason or "filesystem returned no handle"
        return false, "could not open temporary JSON file: " .. tostring(detail)
    end
    local writeOk, writeResult = pcall(handle.write, encoded)
    pcall(handle.close)
    if not writeOk or writeResult == false then
        remove(temporary)
        return false, "could not write temporary JSON file: " .. tostring(writeResult)
    end
    local readBack, readBackError = Storage.readJson(temporary, dependencies)
    if not readBack then
        remove(temporary)
        return false, "temporary JSON file failed read-back validation: " .. tostring(readBackError)
    end

    local movedOld = false
    if fsApi.exists(path) then
        -- Rotate the current primary only after the new temp file is readable.
        -- If primary is missing, retain an existing recovery backup.
        local removed,removeError=remove(backup)
        if not removed then
            remove(temporary)
            return false,"could not rotate JSON backup: "..tostring(removeError)
        end
        local backupOk, backupError = pcall(fsApi.move, path, backup)
        if not backupOk then
            remove(temporary)
            return false, "could not preserve previous JSON file: " .. tostring(backupError)
        end
        movedOld = true
    end

    local installOk, installError = pcall(fsApi.move, temporary, path)
    if not installOk then
        if movedOld and fsApi.exists(backup) and not fsApi.exists(path) then
            pcall(fsApi.move, backup, path)
        end
        remove(temporary)
        return false, "could not install new JSON file: " .. tostring(installError)
    end
    return true
end

function Storage.saveSettings(settings, path, dependencies)
    local ok, reason = Storage.validateSettings(settings)
    if not ok then return false, reason end
    return Storage.writeJson(path or "avionics/data/settings.json", settings, dependencies)
end

-- Settings save that preserves edits made to the file. Saving one setting
-- used to write the whole in-memory configuration, silently reverting any
-- change made to config.json since boot. This reads the file, applies only
-- the changed keys, validates and writes it. A missing intermediate table is
-- copied from the running configuration. A file that is unreadable or
-- invalid on disk (for example mid-edit) is never overwritten.
-- changes: list of {path={"thrust","speed_pid","kp"}, value=0.03}.
-- Returns ok, reason, fileDiffered (the file held values the running
-- configuration does not; they stay in the file and apply on reboot).
local function deepCopy(value)
    if type(value)~="table" then return value end
    local out={};for k,v in pairs(value) do out[k]=deepCopy(v) end;return out
end
-- @ama-summary: Compare the requested configuration subset with the stored document.
local function subsetDiffers(disk,memory)
    if type(disk)~="table" then
        if type(disk)=="number" and type(memory)=="number" then return math.abs(disk-memory)>1e-12 end
        return disk~=memory
    end
    if type(memory)~="table" then return true end
    for k,v in pairs(disk) do if subsetDiffers(v,memory[k]) then return true end end
    return false
end
-- @ama-summary: Merge accepted settings edits into the current stored configuration.
function Storage.saveConfigChanges(path,memory,changes,dependencies)
    local disk,reason=Storage.readJson(path,dependencies)
    if not disk then return false,"CONFIG FILE UNREADABLE; NOT SAVED: "..tostring(reason) end
    local valid,invalid=Storage.validateConfig(disk)
    if not valid then
        return false,"CONFIG FILE ON DISK IS INVALID ("..tostring(invalid).."); FIX IT BEFORE SAVING SETTINGS"
    end
    local differed=type(memory)=="table" and subsetDiffers(disk,memory) or false
    for _,change in ipairs(changes or {}) do
        local node,mem=disk,memory
        local keys=change.path
        if type(keys)~="table" or #keys<1 then return false,"INVALID SETTING PATH" end
        for i=1,#keys-1 do
            local key=keys[i]
            mem=type(mem)=="table" and mem[key] or nil
            if type(node[key])~="table" then node[key]=type(mem)=="table" and deepCopy(mem) or {} end
            node=node[key]
        end
        node[keys[#keys]]=change.value
    end
    local ok,why=Storage.validateConfig(disk)
    if not ok then return false,why end
    local written,writeReason=Storage.writeJson(path,disk,dependencies)
    if not written then return false,writeReason end
    return true,nil,differed
end
return Storage
