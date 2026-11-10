"""Disk Builder, bundling and the shared Lua test runtime."""

# ======================================================================
# From test_runtime_bundling: Bundle loader, installed-file boundaries, library expansion and export tests.
# ======================================================================
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zlib

from lupa.lua52 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
HOME = ROOT / "disk-builder"
bundled_spec = importlib.util.spec_from_file_location("bundled_builder", HOME / "builder.py")
bundled_builder = importlib.util.module_from_spec(bundled_spec)
bundled_spec.loader.exec_module(bundled_builder)
bundle = bundled_builder.bundling
LOADER = (HOME / "assets/runtime-loader.lua").read_bytes()
SOURCE = ROOT


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


class RuntimeBundlingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="bundle-export-tests-", dir=ROOT)
        cls.work = Path(cls.temp.name)
        cls.export, cls.report = bundled_builder.build(SOURCE, cls.work)
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
        module = json.loads(self.objects("library")["/packages/" + bundled_builder.FOLDERS[role] + "/manifest.json"])
        registry = {"coreID": 90, "session": "core-session", "computers": {role: {"id": 91, "label": release.roles[role].label}}}
        lua.globals().os["__amaryllisFleetRegistry"] = table(lua, registry)
        config = table(lua, {"role": role, "serverId": 90, "packageId": module["packageId"], "chunkBytes": 768,
                             "maxFileBytes": 524288, "maxTotalBytes": 1048576, "protocol": "amaryllis.install.v1", "heartbeatSeconds": 5})
        payload = self.objects("library")
        contents = [payload["/packages/" + bundled_builder.FOLDERS[role] + "/main.lua"].decode(),
                    payload["/packages/" + bundled_builder.FOLDERS[role] + "/config.json"].decode(),
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
        for role in bundled_builder.FOLDERS:
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
        for role in bundled_builder.FOLDERS:
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
        for role in bundled_builder.FOLDERS:
            self.assertEqual(self.report["bundling"][role]["after"], 3)
        for entry in self.manifest["library"]:
            self.assertLessEqual(entry["bytes"], 524288)

    def test_bundled_core_can_adopt_matching_library(self):
        lua, files, setup, release, label, _ = self.install_fixture()
        lua.globals().sleep = lua.eval("function()end")
        setup.installCore("/disk", release, 90)
        fleet = json.loads(files["/fleet.json"])
        next_id = 91
        for role in bundled_builder.ROLES:
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
        original = bundled_builder.collect_project(SOURCE)
        expanded = bundle.library_source(self.objects("library"), bundled_builder.FOLDERS, LOADER)
        for role, folder in bundled_builder.FOLDERS.items():
            prefix = "/packages/" + folder + "/"
            original_manifest = json.loads(original["library"][prefix + "manifest.json"])
            self.assertEqual(json.loads(expanded[prefix + "manifest.json"]), original_manifest)
            for dest in original_manifest["files"]:
                origin = {"/avionics/common/console.lua": "/packages/common/console.lua", "/avionics/diagnostics.lua": "/packages/common/diagnostics.lua"}.get(dest, prefix + dest.rsplit("/", 1)[-1])
                self.assertEqual(expanded[origin], original["library"][origin], origin)


# ======================================================================
# From test_bundling_compatibility: Lua quoting compatibility checks requiring only the Python standard library.
# ======================================================================
from pathlib import Path
import importlib.util,unittest
ROOT=Path(__file__).resolve().parents[1]
compat_spec=importlib.util.spec_from_file_location('compat_bundling',ROOT/'disk-builder/bundling.py')
compat_bundling=importlib.util.module_from_spec(compat_spec);compat_spec.loader.exec_module(compat_bundling)
class QuotingTests(unittest.TestCase):
 def test_exact_escape_bytes(self):
  self.assertEqual(compat_bundling.quote(b'\x00\t\n\r"\\\x1f\x7fAZ'),b'"\\000\\009\\010\\013\\"\\\\\\031\\127AZ"')
 def test_every_byte_roundtrips_and_matches_reference(self):
  data=bytes(range(256))*4;expected=bytearray(b'"')
  for n in data:
   if n<32 or n==127:expected.extend(('\\%03d'%n).encode('ascii'))
   elif n in (34,92):expected.extend(bytes([92,n]))
   else:expected.append(n)
  expected.append(34)
  self.assertEqual(compat_bundling.quote(data),bytes(expected));self.assertEqual(compat_bundling.unquote(compat_bundling.quote(data)),data)
 def test_empty_and_utf8(self):
  for data in [b'','Amaryllis: é ß →'.encode('utf-8'),b'"\\'*1000]:
   self.assertEqual(compat_bundling.unquote(compat_bundling.quote(data)),data)
 def test_large_lua_repeated_pack_is_stable(self):
  data=(b'-- repeated realistic Lua source\r\nlocal s="text\\n"\n'*20000)+b'return true\n'
  expected=compat_bundling.quote(data)
  for _ in range(12):self.assertEqual(compat_bundling.quote(data),expected)
  self.assertEqual(compat_bundling.unquote(expected),data)
class ReadableSourceTests(unittest.TestCase):
 def pack(self,data,**kw):
  return compat_bundling.pack({'/avionics/main.lua':data},b'-- loader\n',role='test',entry='/avionics/main.lua',**kw)
 def test_readable_default_preserves_lines_and_literals(self):
  source=b'-- Section: purpose\nlocal function sample()\n    return "quoted" .. "\\\\path"\nend\nreturn sample()\n'
  packed=self.pack(source)
  self.assertIn(source,packed)
  self.assertNotIn(b'\\010',packed)
  self.assertEqual(compat_bundling.unpack(packed,b'-- loader\n')[1]['/avionics/main.lua'],source)
 def test_newline_control_and_delimiter_roundtrips(self):
  for source in [b'',b'\n',b'\n\nreturn 1',b'return 1\n',b'return 1\r\n',b'\r\nreturn 1\r\n',
                 b'one\r\ntwo\nthree\rfour',b'-- ]=] ]==] ]===]\nreturn 1 -- ]=',b'-- nul\x00tab\tend\x7f\n',
                 'return "é ß →"\n'.encode('utf-8')]:
   with self.subTest(source=source):
    packed=self.pack(source)
    self.assertEqual(compat_bundling.unpack(packed,b'-- loader\n')[1]['/avionics/main.lua'],source)
    self.assertEqual(packed,self.pack(source))
 def test_legacy_format_remains_exact_and_readable(self):
  source=b'-- legacy\r\nreturn "x"\n'
  packed=self.pack(source,source_format='escaped-v1')
  self.assertNotIn(b'"sourceFormat"',packed)
  self.assertIn(compat_bundling.quote(source),packed)
  index,files=compat_bundling.unpack(packed,b'-- loader\n')
  self.assertEqual(files['/avionics/main.lua'],source)
  self.assertNotIn('encoding',index['files'][0])
 def test_readable_source_tampering_is_rejected(self):
  packed=self.pack(b'-- source\nreturn 123\n')
  for damaged in [packed.replace(b'return 123',b'return 124'),packed.replace(b'"long-lf"',b'"unknown"'),
                  packed.replace(b'"readable-v1"',b'"unknown-v1"'),packed+b'\n']:
   with self.subTest(damaged=damaged[:80]):
    with self.assertRaises(ValueError):compat_bundling.unpack(damaged,b'-- loader\n')
 def test_unknown_format_refused(self):
  with self.assertRaises(ValueError):self.pack(b'return 1',source_format='future')


# ======================================================================
# From test_python_bundle: The installer zip carries a Windows Python runtime that the helper launchers prefer.
# ======================================================================
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import project

SPEC = importlib.util.spec_from_file_location("builder_python_bundle", project.ROOT / "disk-builder/builder.py")
builder = importlib.util.module_from_spec(SPEC)
sys.modules["builder_python_bundle"] = builder
SPEC.loader.exec_module(builder)


class PythonBundleTests(unittest.TestCase):
    def test_launchers_try_the_bundled_python_first(self):
        for script, gui in (("cc_settings.py", True), ("updater.py", False)):
            text = builder.helper_launcher(script, gui).decode()
            bundled = text.index("..\\python\\pythonw.exe")
            self.assertLess(bundled, text.index("pyw.exe"))
            self.assertIn('"%~dp0' + script + '"', text)
            self.assertTrue(text.startswith("@echo off\r\nsetlocal\r\n"))
            self.assertNotIn("\n", text.replace("\r\n", ""))
        self.assertNotIn("--gui", builder.helper_launcher("cc_settings.py", True).decode())

    def test_runtime_is_skipped_away_from_windows_python(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            result, note = builder.bundle_python_runtime(folder / "python", base=folder, windows=False)
            self.assertIsNone(result)
            self.assertIn("not bundled", note)
            self.assertFalse((folder / "python").exists())

    def test_runtime_copies_only_what_the_helpers_need(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder) / "base"
            for name in ("python.exe", "pythonw.exe", "python312.dll", "vcruntime140.dll", "LICENSE.txt", "unins000.exe",
                         "DLLs/_tkinter.pyd", "DLLs/tcl86t.dll", "tcl/tcl8.6/init.tcl", "Lib/os.py", "Lib/test/test_x.py",
                         "Lib/site-packages/pkg.py", "Lib/__pycache__/os.pyc", "libs/python312.lib", "Scripts/pip.exe"):
                (base / name).parent.mkdir(parents=True, exist_ok=True)
                (base / name).write_bytes(b"x")
            ok = mock.Mock(returncode=0, stderr=b"")
            with mock.patch.object(builder.subprocess, "run", return_value=ok) as run:
                result, note = builder.bundle_python_runtime(Path(folder) / "python", base=base, windows=True)
            self.assertEqual(result, Path(folder) / "python")
            self.assertIn("bundled", note)
            self.assertIn("tkinter", run.call_args.args[0][-1])
            found = {p.relative_to(result).as_posix() for p in result.rglob("*") if p.is_file()}
            self.assertEqual(found, {"python.exe", "pythonw.exe", "python312.dll", "vcruntime140.dll", "LICENSE.txt",
                                     "DLLs/_tkinter.pyd", "DLLs/tcl86t.dll", "tcl/tcl8.6/init.tcl", "Lib/os.py"})

    def test_failed_tk_check_removes_the_runtime(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder) / "base"
            for name in ("python.exe", "tcl/init.tcl"):
                (base / name).parent.mkdir(parents=True, exist_ok=True)
                (base / name).write_bytes(b"x")
            bad = mock.Mock(returncode=1, stderr=b"No module named tkinter")
            with mock.patch.object(builder.subprocess, "run", return_value=bad):
                result, note = builder.bundle_python_runtime(Path(folder) / "python", base=base, windows=True)
            self.assertIsNone(result)
            self.assertIn("tkinter", note)
            self.assertFalse((Path(folder) / "python").exists())


# ======================================================================
# From test_windows_builder: Project-source build validation and failure-path tests. All edits are inside disposable project copies.
# ======================================================================
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import time
import unittest
from unittest.mock import patch
import zipfile

HERE = Path(__file__).resolve().parents[1]
windows_spec = importlib.util.spec_from_file_location("windows_builder", HERE / "disk-builder/builder.py")
windows_builder = importlib.util.module_from_spec(windows_spec)
windows_spec.loader.exec_module(windows_builder)
# These regression cases inspect the editable/loose export format explicitly.
# Bundled exports and their receiver/loader behavior are covered separately.
_build = windows_builder.build
def build_loose(*args, **kwargs):
    kwargs["bundle"] = False
    return _build(*args, **kwargs)
windows_builder.build = build_loose


class WindowsBuilderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = tempfile.TemporaryDirectory(prefix="windows-builder-tests-", dir=HERE / ".cache")
        cls.base_path = Path(cls.base.name).resolve()
        assert cls.base_path.is_relative_to(HERE)

    @classmethod
    def tearDownClass(cls):
        # TemporaryDirectory owns only the checked, newly created fixture path.
        cls.base.cleanup()

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(prefix="case-", dir=self.base_path))
        self.project = self.case / "project"
        shutil.copytree(HERE / "source", self.project / "source")
        self.core = self.project / "source/core"
        self.library = self.project / "source/library"
        self.calibration = self.project / "source/calibration"
        self.output = self.case / "exports"
        self.output.mkdir()

    def write_json(self, path, value):
        path.write_bytes(windows_builder.encode(value))

    def read_json(self, path):
        return json.loads(path.read_bytes())

    def hashes(self):
        return {str(p.relative_to(self.project)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in self.project.rglob("*") if p.is_file()}

    def test_missing_source_rejected_without_output(self):
        with self.assertRaises(windows_builder.BuildError):
            windows_builder.build(self.case / "missing", self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_incomplete_or_malformed_packages(self):
        path = self.library / "packages/navigation/manifest.json"
        original = self.read_json(path)
        for files in ([{}], [None], ["/avionics/../escape.lua"], ["/avionics/missing.lua"],
                      ["/avionics/config.json", "/avionics/config.json"]):
            value = copy.deepcopy(original)
            value["files"] = files
            self.write_json(path, value)
            with self.assertRaises(windows_builder.BuildError):
                windows_builder.collect_project(self.project)
        value = copy.deepcopy(original)
        value["role"] = "state"
        self.write_json(path, value)
        with self.assertRaisesRegex(windows_builder.BuildError, "Unsupported package manifest"):
            windows_builder.collect_project(self.project)

    def test_invalid_json(self):
        (self.core / "avionics/config.json").write_text('{"x":NaN}')
        with self.assertRaisesRegex(windows_builder.BuildError, "Invalid JSON"):
            windows_builder.collect_project(self.project)

    def test_destination_path_validation(self):
        for value in (None, {}, 5, "/avionics//x.lua", "/avionics/../x", "/avionics/C:x", "outside"):
            with self.assertRaises(windows_builder.BuildError):
                windows_builder.portable_path(value)

    def test_identity_removal_settings_preservation_and_runtime_exclusion(self):
        path = self.core / "avionics/config.json"
        config = self.read_json(path)
        config.update(computer_id=321, bridge_id=322, node_ids={"test": 333}, role_ids={"test": 334}, display_ids=[335])
        config["thrust"]["enabled"] = True
        config["commissioning"]["enabled"] = True
        config["altitude_control"]["builder_test_setting"] = 0.321
        self.write_json(path, config)
        for relative in ("avionics/data/checkpoint.json", "avionics/tests/example.lua"):
            p = self.core / relative
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("{}")
        result = windows_builder.collect_project(self.project)
        portable = json.loads(result["payload"]["/avionics/config.json"])
        self.assertEqual(portable["altitude_control"], config["altitude_control"])
        for field in ("computer_id", "bridge_id", "node_ids", "role_ids", "display_ids"):
            self.assertNotIn(field, portable)
        self.assertFalse(portable["thrust"]["enabled"])
        self.assertFalse(portable["commissioning"]["enabled"])
        self.assertTrue(portable["hardware"]["discover"])
        self.assertFalse(any("/data/" in p or "/tests/" in p for p in result["payload"]))
        self.assertEqual(set(result["calibration"]), set(windows_builder.LEARNING.values()))

    def test_partial_learning_can_be_explicitly_excluded(self):
        (self.calibration / "avionics/data/level-bias.json").unlink()
        with self.assertRaisesRegex(windows_builder.BuildError, "Only one learning"):
            windows_builder.collect_project(self.project)
        self.assertEqual(windows_builder.collect_project(self.project, False)["calibration"], {})

    def test_no_learning_is_supported(self):
        for path in windows_builder.LEARNING.values():
            (self.calibration / path.lstrip("/")).unlink()
        result = windows_builder.collect_project(self.project)
        self.assertEqual(result["calibration"], {})
        self.assertIn("No saved", result["notes"][0])

    def test_invalid_learning_fails_with_actionable_error(self):
        level = self.read_json(self.calibration / "avionics/data/level-bias.json")
        hover = self.read_json(self.calibration / "avionics/data/hover-offset.json")
        for invalid in ({}, {**level, "roll": 10001}, {**level, "roll": True}):
            with self.assertRaises(windows_builder.BuildError):
                windows_builder.validate_learning(hover, invalid)
        bad_hover = copy.deepcopy(hover)
        bad_hover["bands"]["0200"] = {"offset": 0, "samples": 1}
        with self.assertRaises(windows_builder.BuildError):
            windows_builder.validate_learning(bad_hover, level)

    def test_learning_is_from_project_calibration(self):
        path = self.calibration / "avionics/data/level-bias.json"
        level = self.read_json(path)
        level["roll"] = 12.345
        self.write_json(path, level)
        data = windows_builder.collect_project(self.project)["calibration"][windows_builder.LEARNING["level"]]
        self.assertEqual(json.loads(data)["roll"], 12.345)

    def test_output_inside_source_is_refused_without_source_changes(self):
        before = self.hashes()
        with self.assertRaisesRegex(windows_builder.BuildError, "outside editable source"):
            windows_builder.build(self.project, self.core)
        self.assertEqual(self.hashes(), before)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_asset_corruption_is_refused(self):
        fake_home = self.case / "utility"
        shutil.copytree(windows_builder.HOME / "assets", fake_home / "assets")
        for name in [p.name for p in windows_builder.HOME.glob("*.py")] + ["Start Builder.cmd"]:
            shutil.copy2(windows_builder.HOME / name, fake_home / name)
        (fake_home / "assets/setup.lua").write_text("broken")
        with patch.object(windows_builder, "HOME", fake_home), self.assertRaisesRegex(windows_builder.BuildError, "damaged"):
            windows_builder.build(self.project, self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_snapshot_rechecks_parent_links(self):
        snap = windows_builder.Snapshot(self.core)
        snap.read(self.core / "startup.lua")
        real_linked = windows_builder.linked
        with patch.object(windows_builder, "linked", side_effect=lambda path: path == self.core / "startup.lua" or real_linked(path)):
            with self.assertRaisesRegex(windows_builder.BuildError, "linked"):
                snap.check_unchanged()

    def test_successful_exports_are_verified_private_and_never_overwritten(self):
        before = self.hashes()
        first, report = windows_builder.build(self.project, self.output)
        second, again = windows_builder.build(self.project, self.output)
        self.assertNotEqual(first, second)
        self.assertEqual(report["releaseId"], again["releaseId"])
        self.assertEqual(self.hashes(), before)
        self.assertFalse((first / "INCOMPLETE.txt").exists())
        self.assertEqual(report["learningFiles"], 2)
        with zipfile.ZipFile(first / "amaryllis-installer.zip") as archive:
            self.assertNotIn("build-report.json", archive.namelist())
            self.assertIsNone(archive.testzip())
            manifest = json.loads(archive.read("media/release.json"))
            self.assertTrue(all(set(role) == {"label"} for role in manifest["roles"].values()))
            self.assertNotIn(str(self.project), archive.read("README.md").decode())
            self.assertIn("Software source: maintained project", archive.read("README.md").decode())
            self.assertEqual(archive.read("windows-settings/cc_settings.py"), (windows_builder.HOME / "cc_settings.py").read_bytes())
            self.assertIn(b"cc_settings.py", archive.read("windows-settings/Configure ComputerCraft.cmd"))
            self.assertFalse(any("cc_settings" in item["path"] for item in manifest["core"] + manifest["bootstrap"]))
        self.assertTrue((first / "build-report.json").is_file())
        self.assertFalse(report["validation"]["luaCompiled"])

    def test_without_learning_produces_no_calibration_group(self):
        result, report = windows_builder.build(self.project, self.output, False)
        manifest = json.loads((result / "media/release.json").read_bytes())
        self.assertNotIn("calibration", manifest)
        self.assertEqual(report["learningFiles"], 0)

    def test_core_progress_asset_is_exported_with_core(self):
        result, report = windows_builder.build(self.project, self.output)
        manifest = json.loads((result / "media/release.json").read_bytes())
        entries = {entry["path"]: entry for entry in manifest["core"]}
        def data(path):
            return (result / "media/objects" / entries[path]["object"]).read_bytes()
        self.assertFalse(any(p.startswith("/packages/") for p in entries))
        self.assertIn("/avionics/common/console.lua", entries)
        self.assertEqual([v[0] for v in windows_builder.source_notes.tokens(data("/installer/progress.lua").decode())],
                         [v[0] for v in windows_builder.source_notes.tokens((windows_builder.HOME / "assets/core-progress.lua").read_text())])
        self.assertEqual(report["builderOverrides"]["/installer/progress.lua"], windows_builder.sha(data("/installer/progress.lua")))

    def test_unsupported_installer_display_hooks_fail_before_output(self):
        (self.core / "installer/server.lua").write_text("return {}")
        with self.assertRaisesRegex(windows_builder.BuildError, "supported progress interface"):
            windows_builder.build(self.project, self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_gui_build_with_real_tk_event_loop(self):
        import tkinter as tk
        from tkinter import messagebox
        real_tk = tk.Tk
        root = real_tk()
        root.withdraw()
        def descendants(widget):
            return [item for child in widget.winfo_children() for item in [child] + descendants(child)]
        def run_hidden():
            widgets = descendants(root)
            entries = [w for w in widgets if w.winfo_class() == "TEntry"]
            self.assertEqual(len(entries), 1)
            self.assertEqual(root.title(), "Amaryllis Disk Builder " + windows_builder.VERSION)
            root.setvar(entries[0].cget("textvariable"), str(self.project))
            buttons = {str(w.cget("text")): w for w in widgets if w.winfo_class() == "TButton"}
            buttons["Build installer"].invoke()
            deadline = time.monotonic() + 20
            while str(buttons["Open result"].cget("state")) == "disabled" and time.monotonic() < deadline:
                root.update()
                time.sleep(.01)
            self.assertEqual(str(buttons["Open result"].cget("state")), "normal")
            self.assertEqual(str(buttons["Build installer"].cget("state")), "normal")
            self.assertEqual(len(list(self.output.glob("Amaryllis-*"))), 1)
        try:
            with patch.object(windows_builder, "DEFAULT_OUTPUT", self.output), \
                 patch.object(tk, "Tk", return_value=root), patch.object(root, "mainloop", side_effect=run_hidden), \
                 patch.object(messagebox, "showerror") as error:
                windows_builder.gui()
                error.assert_not_called()
        finally:
            for timer in root.tk.call("after", "info"):
                root.after_cancel(timer)
            root.destroy()


if __name__ == "__main__":
    import unittest
    unittest.main()
