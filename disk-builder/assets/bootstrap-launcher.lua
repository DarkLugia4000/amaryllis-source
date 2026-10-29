-- The commissioning screen removes itself only after verified installation.
local pending="/installer/commissioning.lua"
local programEnv=_ENV
if fs.exists(pending) then assert(loadfile(pending,nil,programEnv))({...});return end
assert(loadfile("/avionics/common/console.lua",nil,programEnv))().start({...})
