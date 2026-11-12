# Flight and thrust tuning reference

Values below are shipped values from `source/core/avionics/config.json`. They are not universal flight-tested operating ranges. The tables below are generated from `source/core/avionics/config_registry.lua`, which records each setting's unit, accepted bound, the place that enforces it and the fallback used when the setting is absent. `tests/test_state.py` checks the registry against `config.json`, `Storage.validateConfig`, the cockpit settings editor and the control code, and fails if these tables are not regenerated. Regenerate with `python tools/config_registry.py --write`. Explicit installed tuning is preserved.

## Units and controller scales

Altitude PID maps block error to requested b/s. Vertical-speed PID maps b/s error to fractional feed effort. Trim PID maps leveling error to provider-ceiling correction. Speed PID maps b/s error to normalized primary drive. Heading rate PID maps deg/s error to normalized yaw demand. For each PID: kp is output/input, ki is output/(input*s), kd is output*s/input, integral_limit is input*s, derivative_filter_seconds is seconds. PID validation accepts gains/limits in [0,100] and a positive derivative filter.

## Physical model evidence

Longitudinal drag time constant: 5.5 s, prior measured estimate with exact fit window unestablished. Vertical resistance: 0.019 of vessel weight per b/s, referenced to October 22 observations; exact fitting window remains unestablished. Gas response: the October 24 SABLE AERO window gives a coarse 1 s aggregate lag and zero additional delay on the tested fit grid; RMSE 362.23 m3. Command ACK delay is separate. See [plant model](FLIGHT-MODEL.md) and [pressure evidence](../diagnostics/PRESSURE-EVIDENCE.md).

## Configuration ordering

altitude_ceiling must be above minimum_world_y. Startup speed and hard guard are separately bounded. Command TTL is at most network.node_stale_seconds. Verified/enabled control flags impose the corresponding geometry, gain and hardware prerequisites. The schema validator remains authoritative for cross-field constraints.

<!-- BEGIN generated settings tables: python tools/config_registry.py --write -->

## altitude_control

| Key | Shipped | Fallback when absent | Unit | Bound (enforced by) | Effect | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| `altitude_ceiling` | 280 | required | block Y | [-2048, 2048] (config validation) | Highest selectable altitude target. must be above minimum_world_y | configured value |
| `altitude_pid.derivative_filter_seconds` | 1 | required | seconds | (0, 100] (config validation) | altitude pid derivative filter seconds | configured value |
| `altitude_pid.integral_limit` | 20 | required | input-seconds | [0, 100] (config validation) | altitude pid integral limit | configured value |
| `altitude_pid.kd` | 0.05 | required | output-seconds per input | [0, 100] (config validation) | altitude pid kd | configured value |
| `altitude_pid.ki` | 0.001 | required | output per input-second | [0, 100] (config validation) | altitude pid ki | configured value |
| `altitude_pid.kp` | 0.06 | required | output per input | [0, 100] (config validation) | altitude pid kp | configured value |
| `ceiling_fast_rate` | 0.08 | required | fraction per second | [0.02, 0.25] (config validation) | Vent fast rate (fraction/s) | configured value |
| `ceiling_rise_rate` | 0.02 | required | fraction per second | [0.005, 0.1] (config validation) | Vent rise rate (fraction/s) | configured value |
| `ceiling_soft_start_rate` | 0.005 | required | fraction per second | [0.0005, 0.05] (config validation) | Vent soft-start rate (fraction/s) | configured value |
| `climb_trim_boost` | 2 | 1 | multiplier | [1, 20] (config validation) | Leveling boost while building lift (x) | configured value |
| `enabled` | true | required |  | boolean (config validation) | Enable altitude control | configured value |
| `hover_capture_seconds` | 5 | 5 | seconds | [1, 60] (config validation) | Hover capture and control-response horizon | configured value |
| `hover_max_vertical_speed` | 0.2 | 0.2 | b/s | [0.01, 0.5] (config validation) | Maximum vertical speed for hover capture | configured value |
| `launch_settle_seconds` | 10 | required | seconds | [0, 60] integer (config validation) | Startup settling interval | configured value |
| `level_boost_max` | 10 | 10 | multiplier | [1, 20] (config validation) | Large-tilt boost maximum (x) | configured value |
| `level_boost_start_blocks` | 0.5 | 0.5 | blocks | [0.05, 10] (config validation) | Large-tilt boost start (blocks) | configured value |
| `level_damping_gain` | 3 | 1 | multiplier | [0, 10] (config validation) | Leveling damping (x) | configured value |
| `level_lead_seconds` | 6 | required | seconds | [0, 60] (config validation) | Leveling look-ahead (s, 0 = measured lag) | configured value |
| `lift_balance_tolerance_fraction` | 0.2 | 0.2 | fraction | [0.01, 0.25] (config validation) | Support-ratio correction bound | configured value |
| `manual_fore_aft_trim_blocks` | 0 | required | blocks | [-2, 2] (config validation) | Fore/aft leveling offset | configured value |
| `max_feed_fraction` | 0.15 | 0.15 | fraction | [0.001, 0.25] (config validation) | Inner speed-loop effort bound | configured value |
| `max_trim_ceiling_change` | 25 | required | ceiling | [0, 100] (config validation) | Largest leveling trim applied to one chamber ceiling | configured value |
| `max_vertical_speed` | 5 | 1 | b/s | [0.01, 5] (config validation) | Maximum requested hold vertical speed | configured value |
| `minimum_world_y` | 100 | required | block Y | [-2048, 2048] (config validation) | Lower selected-altitude bound | configured value |
| `startup_acceleration_seconds` | 20 | required | seconds | [5, 600] (config validation) | Time to reach startup climb V/S (s) | configured value |
| `startup_braking_lookahead_seconds` | 15 | required | seconds | [5, 120] (config validation) | Braking look-ahead (s) | configured value |
| `startup_gas_target_m3_per_chamber` | 12000 | required | m3 per chamber | [0, 100000] integer (config validation) | Initial bulk-gas target per chamber | configured value |
| `startup_max_vertical_speed` | 5 | required | b/s | [0.01, 20] (config validation) | Climb vertical-speed target while building lift | configured value |
| `startup_vertical_speed_limit` | 20 | required | b/s | [0.01, 20] (config validation) | Hard vertical-speed guard while building lift | configured value |
| `trim_ceiling_per_block` | 5 | 0 | ceiling per block | [0, 50] (config validation) | Leveling trim per block of corner altitude error | configured value |
| `trim_deadband_blocks` | 0.15 | required | blocks | [0, 10] (config validation) | Corner altitude error ignored by leveling trim | configured value |
| `trim_pid.derivative_filter_seconds` | 2 | required | seconds | (0, 100] (config validation) | trim pid derivative filter seconds | configured value |
| `trim_pid.integral_limit` | 100 | required | input-seconds | [0, 100] (config validation) | trim pid integral limit | configured value |
| `trim_pid.kd` | 1 | required | output-seconds per input | [0, 100] (config validation) | trim pid kd | configured value |
| `trim_pid.ki` | 0.25 | required | output per input-second | [0, 100] (config validation) | trim pid ki | configured value |
| `trim_slew_ceiling_per_second` | 1 | 0 | ceiling per second | [0.01, 10] (config validation) | Rate limit for leveling trim changes | configured value |
| `tuning_confirmed` | false | required |  | boolean (config validation) | Owner confirmation that altitude tuning is commissioned | configured value |
| `vertical_drag_support_per_bps` | not shipped | 0.019 | fraction of weight per b/s | [0, 0.05] (runtime clamp) | Vertical-speed feedforward: extra support per commanded b/s to overcome vertical drag | measured estimate (October 22 recordings) |
| `vertical_speed_pid.derivative_filter_seconds` | 1 | required | seconds | (0, 100] (config validation) | vertical speed pid derivative filter seconds | configured value |
| `vertical_speed_pid.integral_limit` | 80 | required | input-seconds | [0, 100] (config validation) | vertical speed pid integral limit | configured value |
| `vertical_speed_pid.kd` | 0 | required | output-seconds per input | [0, 100] (config validation) | vertical speed pid kd | configured value |
| `vertical_speed_pid.ki` | 0.0015 | required | output per input-second | [0, 100] (config validation) | vertical speed pid ki | configured value |
| `vertical_speed_pid.kp` | 0.012 | required | output per input | [0, 100] (config validation) | vertical speed pid kp | configured value |

## thrust

| Key | Shipped | Fallback when absent | Unit | Bound (enforced by) | Effect | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| `command_ttl_seconds` | 1 | 1 | seconds | [0.1, 3] (config validation) | Primary/lateral command lease duration. Config validation allows up to network.node_stale_seconds; propulsion refuses commands above 3 s | configured value |
| `direct_max_request` | 1 | 0.25 | fraction of drive range | (0, 1] (config validation) | Primary drive-request scale | configured value |
| `drag_time_constant_seconds` | not shipped | 5.5 | seconds | [1, 60] (runtime clamp) | Horizontal drag time constant used for speed prediction and anchor braking | measured estimate (recorded coast-down) |
| `enabled` | false | required |  | boolean (config validation) | Enable core propulsion commands | configured value |
| `front_back_strafe_percent` | 100 | 100 | percent | [50, 150] (runtime clamp) | Front lateral output during strafe, as a percentage of the back groups | configured value |
| `heading_control.heading_rate_per_degree` | 0.5 | required | (deg/s) per deg | (0, 10] (config validation) | Commanded yaw rate per degree of heading error | configured value |
| `heading_control.maximum_yaw_rate_degrees_per_second` | 10 | required | deg/s | [0.1, 90] (config validation) | Largest commanded yaw rate | configured value |
| `heading_control.output_slew_per_second` | 0.25 | required | yaw demand per second | [0.01, 1] (config validation) | Rate limit for yaw demand changes | configured value |
| `heading_control.rate_filter_seconds` | 0.5 | required | seconds | [0.05, 5] (config validation) | Measured yaw-rate filter time constant | configured value |
| `heading_control.rate_pid.derivative_filter_seconds` | 1 | required | seconds | (0, 100] (config validation) | rate pid derivative filter seconds | configured value |
| `heading_control.rate_pid.integral_limit` | 20 | required | input-seconds | [0, 100] (config validation) | rate pid integral limit | configured value |
| `heading_control.rate_pid.kd` | 0 | required | output-seconds per input | [0, 100] (config validation) | rate pid kd | configured value |
| `heading_control.rate_pid.ki` | 0.005 | required | output per input-second | [0, 100] (config validation) | rate pid ki | configured value |
| `heading_control.rate_pid.kp` | 0.05 | required | output per input | [0, 100] (config validation) | rate pid kp | configured value |
| `heading_control_enabled` | true | required |  | boolean (config validation) | Enable heading control | configured value |
| `heading_control_verified` | false | required |  | boolean (config validation) | Owner verification gate for heading control | configured value |
| `lateral_max_rpm` | 256 | required | RPM | [1, 256] integer (config validation) | Maximum lateral shaft request | configured value |
| `limits_verified` | true | required |  | boolean (config validation) | Owner verification gate for limits | configured value |
| `manual_acceleration.maximum` | 0.1 | required | b/s^2 | (0, inf] (config validation) | Forward acceleration limit for held throttle | configured value |
| `manual_acceleration.minimum` | -0.1 | required | b/s^2 | [-inf, 0) (config validation) | Reverse acceleration limit for held throttle | configured value |
| `manual_acceleration_enabled` | true | required |  | boolean (config validation) | Enable manual acceleration | configured value |
| `manual_acceleration_pid.derivative_filter_seconds` | 1 | required | seconds | (0, 100] (config validation) | manual acceleration pid derivative filter seconds | configured value |
| `manual_acceleration_pid.integral_limit` | 5 | required | input-seconds | [0, 100] (config validation) | manual acceleration pid integral limit | configured value |
| `manual_acceleration_pid.kd` | 0 | required | output-seconds per input | [0, 100] (config validation) | manual acceleration pid kd | configured value |
| `manual_acceleration_pid.ki` | 0.08 | required | output per input-second | [0, 100] (config validation) | manual acceleration pid ki | configured value |
| `manual_acceleration_pid.kp` | 0.2 | required | output per input | [0, 100] (config validation) | manual acceleration pid kp | configured value |
| `manual_acceleration_verified` | false | required |  | boolean (config validation) | Owner verification gate for manual acceleration | configured value |
| `manual_speed_hold_gain` | 0.5 | 0.5 | drive per b/s | [0.01, 10] (config validation) | Manual speed-hold gain | configured value |
| `mapping_verified` | true | required |  | boolean (config validation) | Owner verification gate for mapping | configured value |
| `mixer_verified` | true | required |  | boolean (config validation) | Owner verification gate for mixer | configured value |
| `primary_input_rpm` | 256 | required | RPM | [256, 256] integer (config validation) | Verified primary supply speed | configured value |
| `primary_max_rpm` | 256 | required | RPM | [1, 256] integer (config validation) | Maximum primary shaft request | configured value |
| `reverse_brake_margin_bps` | not shipped | disabled | b/s | [0, inf] (runtime clamp) | Overspeed margin before reverse braking at cruise; absent disables reverse braking | configured value |
| `speed_control_enabled` | true | required |  | boolean (config validation) | Enable speed control | configured value |
| `speed_control_verified` | false | required |  | boolean (config validation) | Owner verification gate for speed control | configured value |
| `speed_feedforward_per_bps` | not shipped | 0.031 | drive x pressure per b/s | none (not bounded) | Initial cruise feedforward before learned bands exist (normalised at reference pressure) | measured estimate (cruise thrust at pressure 0.55) |
| `speed_integrate_band_bps` | not shipped | 2 | b/s | none (not bounded) | Speed error band inside which the speed PID integrates | configured value |
| `speed_lead_seconds` | not shipped | 2 | seconds | [0, 5] (runtime clamp) | Target-ramp lead for selected-speed changes | configured value |
| `speed_output_slew_per_second` | 0.25 | 0.25 | drive per second | [0.01, 1] (config validation) | General speed-loop output slew | configured value |
| `speed_overspeed_release_per_second` | 0.1 | required | drive per second | [0.01, 1] (config validation) | Same-direction overspeed thrust-release slew | configured value |
| `speed_pid.derivative_filter_seconds` | 1 | required | seconds | (0, 100] (config validation) | speed pid derivative filter seconds | configured value |
| `speed_pid.integral_limit` | 100 | required | input-seconds | [0, 100] (config validation) | speed pid integral limit | configured value |
| `speed_pid.kd` | 0 | required | output-seconds per input | [0, 100] (config validation) | speed pid kd | configured value |
| `speed_pid.ki` | 0.004 | required | output per input-second | [0, 100] (config validation) | speed pid ki | configured value |
| `speed_pid.kp` | 0.03 | required | output per input | [0, 100] (config validation) | speed pid kp | configured value |
| `speed_target_rate_bps2` | 0.5 | required | b/s^2 | (0, 10] (config validation) | Selected-speed target ramp | configured value |
| `speed_trim_down_limit` | not shipped | 0.3 | fraction of cruise drive | [0, 1] (runtime clamp) | Lowest PID trim, as a fraction of cruise feedforward, before reverse is allowed | configured value |
| `status_stale_seconds` | 10 | required | seconds | [0.1, 10] (config validation) | Thrust status freshness limit | configured value |
| `zero_brake_gain` | not shipped | 0.06 | drive per b/s | [0, 1] (runtime clamp) | SEL 0 proportional brake: reverse drive per b/s of predicted speed | configured value |
| `zero_brake_stop_bps` | 2 | 2 | b/s | [0, inf] (runtime clamp) | SEL 0 coast entry speed; braking stops below this speed | configured value |
| `zero_hold_capture_speed` | not shipped | 0.1 | b/s | [0, inf] (runtime clamp) | Speed below which zero-speed hold captures | configured value |

## Fallbacks that differ from the shipped value

A fallback applies only when the setting is absent. For a required setting, configuration validation rejects a config without it, so the fallback cannot be reached while the config is valid. These differences are recorded for a separate behavioral decision; Delivery 5 did not change them.

| Setting | Shipped | Fallback | Reachable |
| --- | --- | --- | --- |
| `altitude_control.climb_trim_boost` | 2 | 1 | yes, when the setting is removed |
| `altitude_control.level_damping_gain` | 3 | 1 | yes, when the setting is removed |
| `altitude_control.max_vertical_speed` | 5 | 1 | no: required setting |
| `altitude_control.trim_ceiling_per_block` | 5 | 0 | no: required setting |
| `altitude_control.trim_slew_ceiling_per_second` | 1 | 0 | no: required setting |
| `thrust.direct_max_request` | 1 | 0.25 | yes, when the setting is removed |

<!-- END generated settings tables -->
