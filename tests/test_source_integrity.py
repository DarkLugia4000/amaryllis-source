"""Explicit package-family guards at source and builder entry points."""
import unittest
import project

class SourceIntegrityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.notes=project.builder_module().source_notes
        cls.files=project.source_files()

    def test_all_eleven_families_and_nine_links(self):
        self.assertEqual(self.notes.validate_package_families(self.files),11)
        self.assertEqual(len(self.notes.PACKAGE_FAMILIES['chamber-link']),9)

    def test_cross_group_executable_drift_rejected(self):
        for path in self.notes.PACKAGE_FAMILIES['chamber-link']:
            with self.subTest(path=path):
                changed=dict(self.files);changed[path]+=b'\nreturn 99\n'
                with self.assertRaisesRegex(ValueError,'chamber-link.*token'):
                    self.notes.validate_package_families(changed)

    def test_comments_allowed_except_normalized_families(self):
        changed=dict(self.files);path=self.notes.PACKAGE_FAMILIES['heading-main'][0]
        changed[path]=b'-- additional purpose detail\n'+changed[path]
        self.assertEqual(self.notes.validate_package_families(changed),11)
        for name in self.notes.BYTE_IDENTICAL_FAMILIES:
            changed=dict(self.files);path=self.notes.PACKAGE_FAMILIES[name][0]
            changed[path]=b'-- inconsistent header\n'+changed[path]
            with self.assertRaisesRegex(ValueError,'normalized comments/bytes'):
                self.notes.validate_package_families(changed)

    def test_missing_family_member_rejected(self):
        changed=dict(self.files);del changed['packages/common/chamber_link.lua']
        with self.assertRaisesRegex(ValueError,'missing packages/common/chamber_link'):
            self.notes.validate_package_families(changed)

    def test_core_console_matches_generated_package_console(self):
        """Reject direct edits to the generated core console copy."""
        import tempfile, shutil
        from pathlib import Path
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "checkout"
            shutil.copytree(project.ROOT / "source", root / "source")
            path = root / "source/core/avionics/common/console.lua"
            path.write_bytes(path.read_bytes() + b"\n-- direct core edit\n")
            with self.assertRaisesRegex(Exception, "differs from the console generated"):
                project.builder_module().collect_project(root)


    def test_runtime_global_catalogue_matches_source(self):
        """Every os.__amaryllis* name in maintained source and assets is documented, and vice versa."""
        import re
        names = set()
        roots = [project.ROOT / "source", project.HOME / "assets"]
        for root in roots:
            for path in root.rglob("*.lua"):
                data = path.read_bytes()
                names.update(re.findall(rb"os\.(__amaryllis\w+)", data))
                names.update(re.findall(rb'RuntimeState\.(?:get|set)\("(__amaryllis\w+)"', data))
        names = {name.decode() for name in names}
        catalogue = (project.ROOT / "docs/architecture/RUNTIME-GLOBALS.md").read_text(encoding="utf-8")
        documented = set(re.findall(r"^\| `(__amaryllis\w+)`", catalogue, re.M))
        self.assertEqual(sorted(names - documented), [], "undocumented runtime globals")
        self.assertEqual(sorted(documented - names), [], "documented runtime globals no longer in source")

    def test_worker_accessor_preserves_shared_identity_and_direct_os_interoperation(self):
        """Old direct writers and separately loaded accessors share the same os values."""
        from tests.test_runtime_bundling import LuaRuntime
        source = self.files["avionics/runtime_state.lua"].decode()
        for bundled in (False, True):
            with self.subTest(bundled=bundled):
                lua = LuaRuntime(unpack_returned_tuples=True)
                lua.execute("fs={exists=function()return false end}")
                if bundled:
                    b = project.builder_module()
                    source_data = b.bundling.pack({
                        "/avionics/main.lua": b"return require('avionics.runtime_state')",
                        "/avionics/runtime_state.lua": source.encode()},
                        (project.HOME / "assets/runtime-loader.lua").read_bytes(),
                        role="runtime-state-test", entry="/avionics/main.lua")
                    lua.globals().Shared = lua.execute(source_data.decode())
                else:
                    lua.globals().Shared = lua.execute(source)
                lua.globals().Other = lua.execute(source)
                lua.execute('''
local key='__amaryllisSamplingContext'
local first={owner='first'};os[key]=first
assert(Shared.get(key)==first and Other.get(key)==first)
local second={owner='second'};Shared.set(key,second)
assert(os[key]==second and Other.get(key)==second and Shared.get(key)~=first)
Other.set(key,nil);assert(os[key]==nil and Shared.get(key)==nil)
''')

    def test_worker_entry_points_keep_current_owner_checks_in_source_and_bundle(self):
        """Actual main entry points execute current owners and reject obsolete owner tokens."""
        from tests.test_runtime_bundling import LuaRuntime
        for bundled in (False, True):
            with self.subTest(bundled=bundled):
                files = {"/avionics/main.lua": self.files["avionics/main.lua"],
                         "/avionics/runtime_state.lua": self.files["avionics/runtime_state.lua"]}
                lua = LuaRuntime(unpack_returned_tuples=True)
                lua.execute("fs={exists=function()return false end}")
                if bundled:
                    files["/avionics/main.lua"] = project.builder_module().bundling.pack(files,
                        (project.HOME / "assets/runtime-loader.lua").read_bytes(),
                        role="worker-entry-test", entry="/avionics/main.lua")
                else:
                    lua.globals().Shared = lua.execute(files["/avionics/runtime_state.lua"].decode())
                    lua.execute("require=function(name) assert(name=='avionics.runtime_state');return Shared end")
                lua.globals().MAIN = files["/avionics/main.lua"].decode()
                lua.execute('''
for _,item in ipairs({{'propulsion-worker','Propulsion'}, {'debug-worker','Debug'},
                     {'sampler','Sampling'}, {'failover-sampler','Failover'}})do
 local called=0;local run=function()called=called+1 end
 local context={owner='current',run=run,jobs={vessel=run}}
 local key='__amaryllis'..item[2]..'Context';os[key]=context
 local entry=assert(load(MAIN))
 if context.jobs and (item[1]=='sampler' or item[1]=='failover-sampler')then
  entry(item[1],'vessel','current')
  assert(not pcall(entry,item[1],'vessel','obsolete'))
 else
  entry(item[1],'current');assert(not pcall(entry,item[1],'obsolete'))
 end
 assert(called==1 and os[key]==context)
 os[key]=nil
end
''')

    def test_every_test_module_is_in_the_project_suite(self):
        """A test file left out of project.SUITES would never run in project.py test or CI."""
        modules = {"tests." + path.stem for path in (project.ROOT / "tests").glob("test_*.py")}
        self.assertEqual(sorted(modules - set(project.SUITES)), [])

    def test_no_program_reseeds_the_shared_random_generator(self):
        """rednet takes message IDs from math.random and drops recently seen IDs; reseeding makes computers collide."""
        import re
        offenders = []
        for root in (project.ROOT / "source", project.HOME / "assets"):
            for path in root.rglob("*.lua"):
                for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                    code = line.split("--", 1)[0]
                    if re.search(r"\bmath\.randomseed\s*\(", code):
                        offenders.append(f"{path.relative_to(project.ROOT)}:{number}")
        self.assertEqual(offenders, [])
