"""The installer disk's startup.lua runs setup.lua the way ComputerCraft runs programs."""
import unittest

from lupa.lua52 import LuaRuntime

import project

# ComputerCraft gives each program its own environment holding shell and multishell; _G does not
# have them, and loadfile() without an environment argument loads into _G.
HARNESS = r"""
fs = {getDir = function(p) return p:match("^(.*)/") or "" end,
      combine = function(a, b) return a .. "/" .. b end}
printError = function(message) ERROR = message end
local real_load = load
loadfile = function(path, mode, env)
    assert(path == "disk/setup.lua", "unexpected path " .. tostring(path))
    return real_load(SETUP, "@" .. path, "t", env or _G)
end
SETUP = [[
local Setup = {}
function Setup.main(media)
    STARTED = {media = media, shell = shell ~= nil and shell.run("/startup.lua")}
end
return Setup
]]
local program_env = setmetatable({shell = {
    getRunningProgram = function() return "disk/startup.lua" end,
    run = function(path) RAN = path; return true end,
}}, {__index = _G})
PROGRAM_ENV = program_env
LAUNCH = function(source) return assert(real_load(source, "@disk/startup.lua", "t", program_env))() end
"""


class DiskLauncherTests(unittest.TestCase):
    def test_setup_receives_the_program_shell(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(HARNESS)
        lua.globals().LAUNCH((project.HOME / "assets/startup.lua").read_text(encoding="utf-8"))
        self.assertIsNone(lua.globals().ERROR)
        started = lua.globals().PROGRAM_ENV.STARTED or lua.globals().STARTED
        self.assertEqual(started.media, "disk")
        self.assertIs(started.shell, True, "setup.lua could not see shell")
        self.assertEqual(lua.globals().RAN, "/startup.lua")
        self.assertIsNone(lua.globals().shell, "the harness must not expose shell as a global")


if __name__ == "__main__":
    unittest.main()
