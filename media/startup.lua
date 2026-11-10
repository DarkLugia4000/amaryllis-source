local program=shell.getRunningProgram()
local media=fs.getDir(program)
local ok,issue=pcall(function()
    -- Load setup in this program's environment: shell and multishell are not globals in ComputerCraft.
    local setup=assert(loadfile(fs.combine(media,"setup.lua"),nil,_ENV))()
    setup.main(media)
end)
if not ok then printError("Amaryllis setup: "..tostring(issue)) end
