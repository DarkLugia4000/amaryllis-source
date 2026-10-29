-- @ama-section: Boot entry | Load the installed console and role application environment.
local programEnv = _ENV
if type(programEnv) ~= "table" and type(getfenv) == "function" then
    local envOK, currentEnv = pcall(getfenv, 1)
    if envOK then programEnv = currentEnv end
end
local loaded, Console
local loadOK, chunk, loadIssue = pcall(loadfile, "/avionics/common/console.lua", nil, programEnv)
if loadOK and type(chunk) == "function" then
    loaded, Console = pcall(chunk)
else
    loaded, Console = false, loadOK and loadIssue or chunk
end
if not loaded or type(Console) ~= "table" or type(Console.start) ~= "function" then
    printError("Amaryllis common console could not start: " .. tostring(Console))
    return
end
Console.start({ ... })
