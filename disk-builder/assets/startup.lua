local program=shell.getRunningProgram()
local media=fs.getDir(program)
local ok,issue=pcall(function()
    local setup=assert(loadfile(fs.combine(media,"setup.lua")))()
    setup.main(media)
end)
if not ok then printError("Amaryllis setup: "..tostring(issue)) end
