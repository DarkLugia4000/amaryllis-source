package.path="/avionics/?.lua;"..package.path
local config,reason=require("hardware").lift.loadConfig("/avionics/config.json")
assert(config,reason)
assert(config.relayChildRole,"CHAMBER THRUST PAIR NOT CONFIGURED")
require("chamber_link").parent(config)
