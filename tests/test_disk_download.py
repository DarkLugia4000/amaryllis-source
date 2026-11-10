"""The web installer-disk downloader against a built media folder served as a fake web host."""
from pathlib import Path
import json
import tempfile
import unittest

from lupa.lua52 import LuaRuntime
import project

ROOT = project.ROOT
b = project.builder_module()

# Minimal ComputerCraft surface: an in-memory filesystem, one disk drive mounted
# at /disk, http served from Python, scripted keyboard answers.
FAKES = r'''
local FILES,DIRS,OUT,ANSWERS,CAPACITY=...
local function norm(p) p=("/"..p):gsub("/+","/"):gsub("/$","");if p=="" then p="/" end;return p end
local function children(dir)
    local seen,list={},{};local prefix=dir=="/" and "/" or dir.."/"
    local function add(p) local rest=p:sub(#prefix+1);local name=rest:match("^[^/]+")
        if p:sub(1,#prefix)==prefix and name and not seen[name] then seen[name]=true;list[#list+1]=name end end
    for p in pairs(FILES) do add(p) end;for p in pairs(DIRS) do add(p) end
    table.sort(list);return list
end
fs={}
function fs.combine(a,b) return (norm(a.."/"..b):sub(2)) end
function fs.getDir(p) p=norm(p);return (p:match("^(.*)/[^/]*$") or ""):sub(2) end
function fs.exists(p) p=norm(p);return FILES[p]~=nil or DIRS[p]~=nil end
function fs.isDir(p) return DIRS[norm(p)]~=nil end
function fs.list(p) return children(norm(p)) end
function fs.makeDir(p) DIRS[norm(p)]=true end
function fs.getSize(p) return #(FILES[norm(p)] or "") end
local function used() local n=0;for p,d in pairs(FILES) do if p:sub(1,6)=="/disk/" then n=n+#d end end;return n end
function fs.getFreeSpace(p) return CAPACITY-used() end
function fs.delete(p) p=norm(p)
    for k in pairs(FILES) do if k==p or k:sub(1,#p+1)==p.."/" then FILES[k]=nil end end
    for k in pairs(DIRS) do if k==p or k:sub(1,#p+1)==p.."/" then DIRS[k]=nil end end
end
function fs.move(a,b) FILES[norm(b)]=FILES[norm(a)];FILES[norm(a)]=nil end
function fs.open(p,mode) p=norm(p)
    if mode:sub(1,1)=="r" then local d=FILES[p];if not d then return nil end
        return {readAll=function() return d end,close=function() end} end
    local parts={};return {write=function(s) parts[#parts+1]=s end,close=function() FILES[p]=table.concat(parts) end}
end
DIRS["/disk"]=true
peripheral={getNames=function() return {"left"} end,getType=function() return "drive" end}
local label
disk={hasData=function() return true end,getMountPath=function() return "disk" end,
    getLabel=function() return label end,setLabel=function(_,l) label=l end}
function print(...) local t={} for i=1,select("#",...) do t[#t+1]=tostring((select(i,...))) end;OUT(table.concat(t," ")) end
function write(s) OUT(tostring(s)) end
function printError(s) OUT("ERROR "..tostring(s)) end
function read() return ANSWERS() end
function sleep() end
'''


class DiskDownloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="disk-download-", dir=ROOT / ".cache")
        out = Path(cls.temp.name)
        result, _ = b.build(ROOT, out)
        cls.media = result / "media"
        cls.index = json.loads((cls.media / "download.json").read_bytes())
        cls.script = (cls.media / "download.lua").read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_download(self, disk=None, answers=(), capacity=10_000_000, corrupt=None, args=("ama/release",)):
        lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)
        files = lua.table_from({("/disk/" + k).encode(): v for k, v in (disk or {}).items()})
        dirs = lua.table_from({})
        output, queue, requests = [], list(answers), []
        def serve(url):
            url = url.decode()
            requests.append(url)
            prefix = "https://raw.githubusercontent.com/ama/release/main/media/"
            path = self.media / url.removeprefix(prefix)
            if not url.startswith(prefix) or not path.is_file():
                return 404, b""
            data = path.read_bytes()
            if corrupt and url.endswith(corrupt):
                data = data[:-1] + b"?"
            return 200, data
        lua.execute(FAKES, files, dirs, lambda s: output.append(s.decode()), lambda: queue.pop(0).encode(), capacity)
        g = lua.globals()
        g.SERVE = serve
        lua.execute(rb'''
http={get=function(request)
    local code,data=SERVE(request.url)
    return {getResponseCode=function() return code end,readAll=function() return data end,close=function() end}
end}
local cjson={}
textutils={unserializeJSON=function(s) return PYJSON(s) end,serializeJSON=function(t) return '{"base":"'..t.base..'"}' end}
''')
        def pyjson(s):
            def conv(v):
                if isinstance(v, dict):
                    return lua.table_from({k.encode(): conv(x) for k, x in v.items()})
                if isinstance(v, list):
                    return lua.table_from([conv(x) for x in v])
                return v.encode() if isinstance(v, str) else v
            try:
                return conv(json.loads(s))
            except ValueError:
                return None
        g.PYJSON = pyjson
        chunk = lua.eval("function(src,...) return assert(load(src,'=download.lua'))(...) end")
        chunk(self.script, *[a.encode() for a in args])
        disk_after = {k.decode().removeprefix("/disk/"): v for k, v in files.items()}
        return disk_after, "\n".join(output), requests

    def expected(self):
        return {f["path"]: (self.media / f["path"]).read_bytes() for f in self.index["files"]}

    def assert_complete(self, disk):
        for path, data in self.expected().items():
            self.assertEqual(disk.get(path), data, path)

    def test_index_lists_every_media_file_with_startup_last(self):
        listed = [f["path"] for f in self.index["files"]]
        on_disk = sorted(p.relative_to(self.media).as_posix() for p in self.media.rglob("*") if p.is_file())
        self.assertEqual(sorted(listed + ["download.json", "loader.lua"]), on_disk)
        self.assertEqual(listed[-1], "startup.lua")
        self.assertTrue(all(p.startswith("objects/") for p in listed[:-len(b.DOWNLOAD_LAST)]))
        self.assertEqual(listed[-len(b.DOWNLOAD_LAST):], list(b.DOWNLOAD_LAST))

    def test_blank_disk_becomes_a_complete_installer_disk(self):
        disk, out, _ = self.run_download()
        self.assert_complete(disk)
        self.assertIn("Disk ready: " + self.index["releaseId"], out)
        self.assertIn("download-source.json", disk)
        self.assertNotIn("ERROR", out)

    def test_corrupt_download_never_leaves_a_bootable_disk(self):
        bad = next(f["path"] for f in self.index["files"] if f["path"].startswith("objects/"))
        disk, out, _ = self.run_download(corrupt=bad)
        self.assertIn("Checksum mismatch", out)
        self.assertNotIn("startup.lua", disk)

    def test_too_small_disk_is_refused_before_writing(self):
        disk, out, _ = self.run_download(capacity=100_000)
        self.assertIn("floppy_space_limit", out)
        self.assertEqual(disk, {})

    def test_other_files_are_kept_on_cancel(self):
        disk, out, _ = self.run_download({"notes.txt": b"keep"}, answers=["2"])
        self.assertEqual(disk, {"notes.txt": b"keep"})
        self.assertIn("Cancelled", out)

    def test_other_files_are_erased_when_chosen(self):
        disk, _, _ = self.run_download({"notes.txt": b"x"}, answers=["1"])
        self.assertNotIn("notes.txt", disk)
        self.assert_complete(disk)

    def test_same_release_repair_keeps_progress_and_fetches_only_damage(self):
        disk = dict(self.expected())
        damaged = next(p for p in disk if p.startswith("objects/"))
        disk[damaged] = b"broken"
        disk["deployment.json"] = b'{"progress":1}'
        after, out, requests = self.run_download(disk, answers=["1"])
        self.assertIn("keeps progress", out)
        self.assert_complete(after)
        self.assertEqual(after["deployment.json"], b'{"progress":1}')
        fetched = [r.rsplit("/media/", 1)[1] for r in requests]
        self.assertEqual(sorted(fetched), sorted(["download.json", damaged, "startup.lua"]))

    def test_same_release_replace_clears_progress(self):
        disk = dict(self.expected());disk["deployment.json"] = b"{}"
        after, out, _ = self.run_download(disk, answers=["2"])
        self.assertIn("clears progress", out)
        self.assertNotIn("deployment.json", after)
        self.assert_complete(after)

    def test_other_release_with_progress_explains_and_waits_for_choice(self):
        disk = {"release.json": b'{"releaseId":"amaryllis-old"}', "role-repair.json": b"{}", "startup.lua": b"old"}
        after, out, _ = self.run_download(disk, answers=["2"])
        self.assertIn("amaryllis-old", out)
        self.assertIn("cleared by a new release", out)
        self.assertEqual(after["startup.lua"], b"old")

    def test_saved_address_is_used_on_later_runs(self):
        first, _, _ = self.run_download()
        _, out, requests = self.run_download(first, answers=["1"], args=())
        self.assertTrue(requests[0].startswith("https://raw.githubusercontent.com/ama/release/main/media/"))
        self.assertIn("Nothing to download", out)


if __name__ == "__main__":
    unittest.main()
