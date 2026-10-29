package.path="/avionics/?.lua;"..package.path
local config,reason=require("hardware").lift.loadConfig("/avionics/config.json")
assert(config,reason)
require("chamber_link").child(config,_ENV)
