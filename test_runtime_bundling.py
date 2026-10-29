"""Bundle loader, installed-file boundaries, source recovery and export tests.

All writes are isolated workspace fixtures. No game commands or live-save writes.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zlib

from lupa.lua52 import LuaRuntime

ROOT = Path(__file__).resolve().parent
HOME = ROOT / "Amaryllis Installer Builder"
spec = importlib.util.spec_from_file_location("bundled_builder", HOME / "builder.py")
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
bundle = b.bundling
LOADER = (HOME / "assets/runtime-loader.lua").read_bytes()
from project import fixture
SOURCE = fixture("legacy")


def table(lua, value):
    if isinstance(value, dict):
        return lua.table_from({k: table(lua, v) for k, v in value.items()})
    if isinstance(value, list):
        return lua.table_from([table(lua, v) for v in value])
    return value


def python_value(value):
    if not hasattr(value, "items"):
        return value
    items = dict(value.items())
    if items and set(items) == set(range(1, len(items) + 1)):
        return [python_value(items[i]) for i in range(1, len(items) + 1)]
    return {k: python_value(v) for k, v in items.items()}


def native_runtime(files=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    files = dict(files or {})
    def exists(p):
        return p in files or any(n.startswith(p.rstrip("/") + "/") for n in files)
    def open_file(p, mode):
        if mode in ("r", "rb"):
            if p not in files:
                return None
            position = [0]
            def read(count=1):
                if position[0] >= len(files[p]):
                    return None
                value = files[p][position[0]:position[0]+count];position[0] += len(value);return value
            return lua.table_from({"readAll": lambda: files[p][position[0]:], "read": read, "close": lambda: None})
        parts = []
        return lua.table_from({"write": parts.append, "close": lambda: files.__setitem__(p, "".join(parts))})
    lua.globals().fs = lua.table_from({
        "open": open_file, "exists": exists, "isDir": lambda p: exists(p) and p not in files,
        "isReadOnly": lambda p: False, "getSize": lambda p: len(files[p]),
        "attributes": lambda p: table(lua, {"size": len(files[p]), "isDir": False}) if p in files else None,
        "list": lambda p: table(lua, sorted({n[len(p.rstrip('/'))+1:].split('/')[0] for n in files if n.startswith(p.rstrip('/')+'/')})),
        "delete": lambda p: files.pop(p, None), "move": lambda a, z: files.__setitem__(z, files.pop(a)),
        "copy": lambda a, z: files.__setitem__(z, files[a]),
        "makeDir": lambda p: None, "getDir": lambda p: p.rsplit("/", 1)[0],
        "combine": lambda a, z: a.rstrip("/") + "/" + z.lstrip("/"),
        "getFreeSpace": lambda p: 4_000_000 - sum(len(s.encode()) for p, s in files.items() if not p.startswith("/disk/")),
    })
    lua.execute('''
shell={dir=function() return '' end,openTab=function(...) lastTab={...};return 7 end,
 run=function(...) lastRun={...};return true end}
loadfile=function(path,mode,env)
 local h=fs.open(path,'r');if not h then return nil,'missing '..path end
 return load(h.readAll(),'@'..path,mode or 't',env or _ENV)
end
''')
    return lua, files


class LoaderTests(unittest.TestCase):
    def generated(self, main, extra=None):
        files = {"/avionics/main.lua": main.encode(), **(extra or {})}
        return bundle.pack(files, LOADER, role="test", entry="/avionics/main.lua")

    def test_lossless_source_roundtrip(self):
        for source in (b"return 1\r\n", b"\nreturn 2\n", 'return "café"\n'.encode(), b'return "\\123" -- ]=] \x00\n'):
            files = {"/avionics/main.lua": source}
            data = bundle.pack(files, LOADER, role="test", entry="/avionics/main.lua")
            self.assertEqual(bundle.unpack(data, LOADER)[1], files)
            self.assertEqual(bundle.expand({"/avionics/main.lua": data, "/config.json": b"{}"}, LOADER), {**files, "/config.json": b"{}"})

    def test_readable_literal_bytes_in_real_lua(self):
        for source in (b"", b"\n", b'-- ]=] ]==]\r\nreturn 1\r\n',
                       b'-- mixed\r\n-- other\nreturn 1\r',
                       b'-- nul\x00\nreturn 1\n', 'return "café"\n'.encode()):
            with self.subTest(source=source):
                encoded,codec=bundle.source_quote(source)
                lua=LuaRuntime(unpack_returned_tuples=True)
                actual=lua.execute("return "+encoded.decode("utf-8"))
                if isinstance(actual,tuple):actual=actual[0]
                self.assertEqual(actual.encode("utf-8"),source)
                self.assertEqual(bundle.source_unquote(encoded,codec),source)
    def test_damage_and_unsafe_paths_rejected(self):
        data = self.generated("return 7")
        for damaged in (data[:-1], data.replace(b"return 7", b"return 8"), data + b"\nreturn 4"):
            with self.assertRaises(ValueError):
                bundle.unpack(damaged, LOADER)
        for path in ("/avionics/../bad.lua", "/avionics//bad.lua", "/config.json", "/outside.lua"):
            with self.assertRaises(ValueError):
                bundle.pack({path: b"return 1"}, LOADER, role="test", entry=path)

    def test_module_cache_is_private_per_execution(self):
        data = self.generated('local a=require("avionics.counter");return a==require("avionics.counter"),a.next()',
                              {"/avionics/counter.lua": b"local n=0;return {next=function() n=n+1;return n end}"})
        lua, _ = native_runtime()
        self.assertEqual(lua.execute(data.decode()), (True, 1))
        self.assertEqual(lua.execute(data.decode()), (True, 1))

    def test_short_require_and_original_error_locations(self):
        lua, _ = native_runtime()
        data = self.generated('return require("hardware").answer', {"/avionics/hardware.lua": b"return {answer=42}"})
        self.assertEqual(lua.execute(data.decode()), 42)
        data = self.generated('require("avionics.broken")', {"/avionics/broken.lua": b'local a=1\nerror("fixture failure")'})
        with self.assertRaisesRegex(Exception, r"avionics/broken.lua:2"):
            lua.execute(data.decode())

    def test_virtual_sources_read_only_json_writes_native(self):
        lua, files = native_runtime({"/avionics/config.json": "original"})
        data = self.generated('''
local h=assert(fs.open('/avionics/helper.lua','r'));local text=h.readAll();h.close()
assert(fs.exists('/avionics/helper.lua') and fs.isDir('/avionics'))
assert(fs.getSize('/avionics/helper.lua')==#text)
assert(fs.open('/avionics/helper.lua','w')==nil)
local ok=pcall(fs.delete,'/avionics/helper.lua');assert(not ok)
local w=assert(fs.open('/avionics/config.json','w'));w.write('changed');w.close()
return text
''', {"/avionics/helper.lua": b"return 99\r\n"})
        self.assertEqual(lua.execute(data.decode()), "return 99\r\n")
        self.assertEqual(files["/avionics/config.json"], "changed")

    def test_worker_dispatch_and_arguments(self):
        data = self.generated("local mode,owner=...;return mode,owner", {"/avionics/worker.lua": b"return ..."})
        lua, _ = native_runtime()
        self.assertEqual(lua.execute(data.decode(), bundle.MAGIC, "/avionics/worker.lua", "sample", "owner-1"), ("sample", "owner-1"))
        with self.assertRaisesRegex(Exception, "Unknown bundled entry"):
            lua.execute(data.decode(), bundle.MAGIC, "/outside.lua")
        data = self.generated('return shell.openTab("/avionics/worker.lua","sample","owner-2")', {"/avionics/worker.lua": b"return ..."})
        self.assertEqual(lua.execute(data.decode()), 7)
        self.assertEqual(list(lua.globals().lastTab.values()), ["/avionics/main.lua", bundle.MAGIC, "/avionics/worker.lua", "sample", "owner-2"])

    def test_updater_sees_physical_bundle(self):
        data = self.generated('return assert(loadfile("/installer.lua",nil,_ENV))()')
        lua, _ = native_runtime({"/avionics/main.lua": data.decode(), "/installer.lua": 'return fs.open("/avionics/main.lua","r").readAll()'})
        self.assertEqual(lua.execute(data.decode()), data.decode())

    def test_resident_console_reloads_newly_committed_bundle(self):
        old = self.generated('return "old",loadfile', {"/avionics/helper.lua": b"return 1"})
        new = self.generated('return "new committed application"')
        lua, files = native_runtime({"/avionics/main.lua": old.decode()})
        name, resident_load = lua.execute(old.decode())
        self.assertEqual(name, "old")
        files["/avionics/main.lua"] = new.decode()
        fresh = resident_load("/avionics/main.lua")
        self.assertEqual(fresh(), "new committed application")

    def test_yield_and_shared_supervisor_context(self):
        data = self.generated('os.sharedBundleTest=17;coroutine.yield("waiting");return os.sharedBundleTest')
        lua, _ = native_runtime()
        lua.globals().runBundle = lua.compile(data.decode())
        lua.execute('worker=coroutine.create(runBundle);ok,value=coroutine.resume(worker);assert(ok and value=="waiting")')
        self.assertEqual(lua.globals().os.sharedBundleTest, 17)
        lua.execute('ok,value=coroutine.resume(worker);assert(ok and value==17)')


class ExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="bundle-export-tests-", dir=ROOT)
        cls.work = Path(cls.temp.name)
        cls.export, cls.report = b.build(SOURCE, cls.work)
        cls.manifest = json.loads((cls.export / "media/release.json").read_bytes())

    @classmethod
    def tearDownClass(cls):
        assert cls.work.resolve().is_relative_to(ROOT.resolve())
        cls.temp.cleanup()

    def objects(self, group):
        return {e["path"]: (self.export / "media/objects" / e["object"]).read_bytes() for e in self.manifest[group]}

    def install_fixture(self, existing=None):
        data = {"/disk/" + p.relative_to(self.export / "media").as_posix(): p.read_bytes().decode()
                for p in (self.export / "media").rglob("*") if p.is_file()}
        data.update(existing or {})
        lua, files = native_runtime(data)
        wrap = lua.eval('function(f)return function(...)return f(...)end end')
        for key, value in list(lua.globals().fs.items()):
            lua.globals().fs[key] = wrap(value)
        label = ["fresh"]
        lua.globals().textutils = table(lua, {
            "unserializeJSON": wrap(lambda s: table(lua, json.loads(s))),
            "serializeJSON": wrap(lambda v: json.dumps(python_value(v), separators=(",", ":"))),
        })
        lua.globals().os.getComputerID = wrap(lambda: 90)
        lua.globals().os.getComputerLabel = wrap(lambda: label[0])
        lua.globals().os.setComputerLabel = wrap(lambda v: label.__setitem__(0, v))
        lua.globals().os.queueEvent = lua.eval('function()end')
        lua.globals().print = lua.eval('function()end')
        setup = lua.execute(files["/disk/setup.lua"])
        release = setup.load("/disk")
        lua.execute('''function up(fn,wanted)
 for i=1,100 do local n,v=debug.getupvalue(fn,i);if not n then break end;if n==wanted then return v end end
 error('Missing upvalue '..wanted)
end''')
        return lua, files, setup, release, label, wrap

    def transaction_fixture(self, role):
        lua, files, setup, release, label, wrap = self.install_fixture()
        setup.installCore("/disk", release, 90)
        disk = {p: s for p, s in files.items() if p.startswith("/disk/")}
        lua, files, setup, release, label, wrap = self.install_fixture()
        files.update(disk)
        setup.installAuxiliary("/disk", release, role, 91)
        installer = lua.execute(files["/installer.lua"])
        module = json.loads(self.objects("library")["/packages/" + b.FOLDERS[role] + "/manifest.json"])
        registry = {"coreID": 90, "session": "core-session", "computers": {role: {"id": 91, "label": release.roles[role].label}}}
        lua.globals().os["__amaryllisFleetRegistry"] = table(lua, registry)
        config = table(lua, {"role": role, "serverId": 90, "packageId": module["packageId"], "chunkBytes": 768,
                             "maxFileBytes": 524288, "maxTotalBytes": 1048576, "protocol": "amaryllis.install.v1", "heartbeatSeconds": 5})
        payload = self.objects("library")
        contents = [payload["/packages/" + b.FOLDERS[role] + "/main.lua"].decode(),
                    payload["/packages/" + b.FOLDERS[role] + "/config.json"].decode(),
                    payload["/packages/common/console.lua"].decode()]
        entries = [{"path": p, "size": len(s.encode()), "checksum": f"{zlib.adler32(s.encode()):08X}",
                    "chunks": max(1, (len(s.encode()) + 767)//768)} for p, s in zip(bundle.PATHS, contents)]
        offer = table(lua, {"v": 1, "kind": "offer", "role": role, "clientSession": "client-session", "serverSession": "server-session",
                            "requestID": "request-1", "coreID": 90, "coreSession": "core-session", "computerID": 91,
                            "label": release.roles[role].label, "packageId": module["packageId"], "version": module["version"],
                            "chunkBytes": 768, "files": entries})
        offer.manifestChecksum = installer.manifestChecksum(offer.files)
        accepted = installer.validateOffer(offer, config, "client-session", 91)
        transaction = accepted[0] if isinstance(accepted, tuple) else accepted
        self.assertIsNotNone(transaction, (role, accepted))
        transaction.fileBytes = table(lua, contents)
        transaction.serverID = 90
        commit = lua.globals().up(lua.globals().up(installer.run, "processOffer"), "commit")
        status = lua.table()
        return lua, files, installer, commit, config, transaction, status

    def test_all_16_roles_install_and_auxiliary_receipts_commit(self):
        lua, files, setup, release, _, _ = self.install_fixture()
        setup.installCore("/disk", release, 90)
        self.assertIn("/avionics/main.lua", files)
        self.assertNotIn("/avionics/flight.lua", files)
        setup_files = {p: s for p, s in files.items() if p.startswith("/disk/")}
        lua, files, setup, release, _, _ = self.install_fixture()
        files.update(setup_files)
        setup.installAuxiliary("/disk", release, "state", 92)
        self.assertIn("/avionics/main.lua", files)
        self.assertNotIn("/avionics/state_reader.lua", files)
        self.assertEqual(json.loads(files["/avionics/config.json"])["coreID"], 90)
        for role in b.FOLDERS:
            with self.subTest(role=role):
                lua, files, installer, commit, config, transaction, status = self.transaction_fixture(role)
                result = commit(lua.globals().fs, transaction, config, status, lua.table())
                self.assertIsNotNone(result[0], result)
                receipt = json.loads(files["/avionics/config.json"])["install"]
                self.assertEqual(receipt["role"], role)
                self.assertEqual(receipt["computerID"], 91)
                self.assertEqual(status.state, "installed")
                self.assertFalse(status.recoveryRequired)
                self.assertNotIn("/installer/commit.json", files)
                self.assertEqual(files["/avionics/main.lua"], transaction.fileBytes[1])

    def test_failed_bundle_replacement_rolls_back_previous_files(self):
        lua, files, _, commit, config, tx, status = self.transaction_fixture("chamber_fl")
        old = {p: "previous " + p for p in bundle.PATHS}
        files.update(old)
        move = lua.globals().fs.move
        failed = [False]
        def interrupt(a, z):
            if a == "/installer/stage/config.json" and not failed[0]:
                failed[0] = True;raise RuntimeError("simulated replacement failure")
            return move(a, z)
        lua.globals().fs.move = lua.eval('function(f)return function(...)return f(...)end end')(interrupt)
        result = commit(lua.globals().fs, tx, config, status, lua.table())
        self.assertIsNone(result[0])
        self.assertTrue(failed[0])
        for p, previous in old.items():
            self.assertEqual(files[p], previous)
        self.assertNotIn("/installer/commit.json", files)

    def test_corrupt_payload_cannot_commit(self):
        lua, files, _, commit, config, tx, status = self.transaction_fixture("navigator")
        tx.fileBytes[1] += "damaged"
        result = commit(lua.globals().fs, tx, config, status, lua.table())
        self.assertIsNone(result[0])
        self.assertNotIn("/avionics/main.lua", files)

    def test_restart_recovers_pending_bundle_rollback(self):
        lua, files, installer, commit, config, tx, status = self.transaction_fixture("thrust-rb")
        old = {p: "previous " + p for p in bundle.PATHS}
        files.update(old)
        move = lua.globals().fs.move
        def unavailable(a, z):
            if a == "/installer/stage/config.json" or a.startswith("/installer/backup/"):
                raise RuntimeError("simulated storage interruption")
            return move(a, z)
        lua.globals().fs.move = lua.eval('function(f)return function(...)return f(...)end end')(unavailable)
        result = commit(lua.globals().fs, tx, config, status, lua.table())
        self.assertIsNone(result[0])
        self.assertIn("/installer/commit.json", files)
        self.assertTrue(status.recoveryRequired)
        lua.globals().fs.move = move
        recover = lua.globals().up(installer.run, "recoverPending")
        result = recover(lua.globals().fs, status, lua.table())
        self.assertTrue(result[0] if isinstance(result, tuple) else result)
        for p, previous in old.items():
            self.assertEqual(files[p], previous)
        self.assertFalse(status.recoveryRequired)
        self.assertNotIn("/installer/commit.json", files)

    def test_installed_core_bundle_serves_all_14_compact_packages(self):
        lua, files, _, _, _, _ = self.install_fixture(existing={p: d.decode() for p, d in self.objects("core").items()})
        lua.globals().files = table(lua, files)
        # Return the embedded server module through its production loader.
        server = lua.execute(files["/avionics/main.lua"], bundle.MAGIC, "/installer/server.lua")
        loader = lua.globals().up(server.run, "loadBundle")
        entries = self.objects("library")
        entries.update({p: s.encode() for p, s in files.items() if not p.startswith("/disk/")})
        for p, data in entries.items():
            files[p] = data.decode()
        config = table(lua, json.loads(files["/installer/config.json"]))
        deps = table(lua, {"fs": lua.globals().fs, "textutils": lua.globals().textutils})
        for role in b.FOLDERS:
            result = loader(deps, config, role, lua.eval('function()return true end'))
            package = result[0] if isinstance(result, tuple) else result
            self.assertIsNotNone(package, (role, result))
            self.assertEqual(len(package.entries), 3)

    def test_every_generated_lua_and_embedded_module_compiles(self):
        lua = LuaRuntime()
        check = lua.eval('function(s,n)local f,e=load(s,"@"..n);return f~=nil,e end')
        for group in ("core", "state", "library", "bootstrap"):
            for path, data in self.objects(group).items():
                if not path.endswith(".lua"):
                    continue
                self.assertTrue(check(data.decode(), path)[0], path)
                decoded = bundle.unpack(data, LOADER)
                if decoded:
                    for name, source in decoded[1].items():
                        self.assertTrue(check(source.decode(), name)[0], name)

    def test_payload_counts_and_capacity(self):
        self.assertEqual(len(self.manifest["core"]), 5)
        self.assertEqual(len(self.manifest["state"]), 3)
        self.assertLess(self.report["minimumMediaCapacityBytes"], 4_000_000)
        self.assertLess(self.report["corePayloadBytes"] + 65536, 4_000_000)
        for role in b.FOLDERS:
            self.assertEqual(self.report["bundling"][role]["after"], 3)
        for entry in self.manifest["library"]:
            self.assertLessEqual(entry["bytes"], 524288)

    def test_bundled_core_can_adopt_matching_library(self):
        lua, files, setup, release, label, _ = self.install_fixture()
        lua.globals().sleep = lua.eval("function()end")
        setup.installCore("/disk", release, 90)
        fleet = json.loads(files["/fleet.json"])
        next_id = 91
        for role in b.ROLES:
            fleet["computers"][role]["id"] = next_id; next_id += 1
        files["/fleet.json"] = json.dumps(fleet)
        self.assertNotIn("/installer/media.lua", files)
        before = dict(files)
        setup.adoptLibrary("/disk", release, 90)
        self.assertEqual(files, before)
        files["/avionics/main.lua"] += "\n-- changed core"
        with self.assertRaisesRegex(Exception, "Core runtime differs"):
            setup.adoptLibrary("/disk", release, 90)

    def test_standalone_updater_is_in_distributable(self):
        import zipfile
        with zipfile.ZipFile(self.export / "amaryllis-installer.zip") as archive:
            for name in ("updater.py", "bundling.py", "cc_settings.py", "assets/runtime-loader.lua", "Update Amaryllis.cmd", "README.md"):
                self.assertIn("windows-update/" + name, archive.namelist())
            self.assertIn(b"updater.py", archive.read("windows-update/Update Amaryllis.cmd"))
        self.assertIn("windows-update/Update Amaryllis.cmd", (self.export / "README.md").read_text())

    def test_library_expansion_preserves_modules_and_versions(self):
        original = b.collect(SOURCE)
        expanded = bundle.library_source(self.objects("library"), b.FOLDERS, LOADER)
        for role, folder in b.FOLDERS.items():
            prefix = "/packages/" + folder + "/"
            original_manifest = json.loads(original["library"][prefix + "manifest.json"])
            self.assertEqual(json.loads(expanded[prefix + "manifest.json"]), original_manifest)
            for dest in original_manifest["files"]:
                origin = {"/avionics/common/console.lua": "/packages/common/console.lua", "/avionics/diagnostics.lua": "/packages/common/diagnostics.lua"}.get(dest, prefix + dest.rsplit("/", 1)[-1])
                self.assertEqual(expanded[origin], original["library"][origin], origin)

    def test_installed_bundled_core_exports_again(self):
        fixture = self.work / "rebuild-save/computercraft/computer/501"
        fixture.mkdir(parents=True)
        for path, data in self.objects("core").items():
            dest = fixture / path.lstrip("/"); dest.parent.mkdir(parents=True, exist_ok=True); dest.write_bytes(data)
        for e in self.manifest.get("calibration", {}).get("files", []):
            dest = fixture / e["path"].lstrip("/"); dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes((self.export / "media/objects" / e["object"]).read_bytes())
        roles = {r: {"id": i, "label": v["label"]} for i, (r, v) in enumerate(self.manifest["roles"].items(), 600)}
        roles["core"]["id"] = 501
        (fixture / "fleet.json").write_bytes(b.encode({"schemaVersion": 1, "computers": roles}))
        config = json.loads((fixture / "avionics/config.json").read_bytes());config["computer_id"] = 501
        (fixture / "avionics/config.json").write_bytes(b.encode(config))
        second, report = b.build(fixture, self.work, library=self.export / "media")
        second_manifest = json.loads((second / "media/release.json").read_bytes())
        self.assertEqual(self.manifest["library"], second_manifest["library"])
        self.assertEqual(self.manifest["core"], second_manifest["core"])
        self.assertEqual(self.manifest["state"], second_manifest["state"])
        self.assertEqual(report["packageVersions"], self.report["packageVersions"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
