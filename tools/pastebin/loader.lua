-- Amaryllis loader, kept on Pastebin. Finds the newest Amaryllis release that
-- GitHub Actions built from the source repository and runs its web setup.
--   pastebin run <code>                (this repository)
--   pastebin run <code> <owner>/<repo>  (another repository)
local REPOSITORY="DarkLugia4000/amaryllis-source"
local BRANCH="release"
local repository=... or REPOSITORY
if not http then error("HTTP is disabled in the ComputerCraft config (http.enabled)",0) end
assert(repository:match("^[%w%-%._]+/[%w%-%._]+$"),"Repository must be owner/repo")
-- Pin the release commit, so every computer installs the same build.
local commit
local response=http.get("https://api.github.com/repos/"..repository.."/commits/"..BRANCH,
    {Accept="application/vnd.github.sha"})
if response then
    local text=response.readAll() or "";response.close()
    if #text==40 and text:match("^%x+$") then commit=text end
end
local base="https://raw.githubusercontent.com/"..repository.."/"..(commit or BRANCH).."/media/"
local setup,why=http.get(base.."web-setup.lua")
if not setup then error("Cannot download web-setup.lua from "..base..": "..tostring(why),0) end
local source=setup.readAll();setup.close()
assert(load(source,"=web-setup.lua",nil,_ENV))(base)
