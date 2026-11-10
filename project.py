"""Local project commands for portable source builds and isolated regression fixtures."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import sys
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent
HOME = ROOT / "disk-builder"
SUITES = ("tests.test_windows_builder", "tests.test_runtime_bundling", "tests.test_bundling_compatibility",
          "tests.test_information", "tests.test_bridge_presentation", "tests.test_persistent_modes", "tests.test_altitude_ceiling", "tests.test_repository",
          "tests.test_disk_setup", "tests.test_project_release", "tests.test_autopilot", "tests.test_persistence",
          "tests.test_source_integrity", "tests.test_flight_model", "tests.test_recordings", "tests.test_recovery",
          "tests.test_presentation", "tests.test_config_registry",
          "tests.test_world_lock", "tests.test_live_update_status", "tests.test_auto_propulsion", "tests.test_python_bundle", "tests.test_vent_balloon_hint", "tests.test_stale_status_text", "tests.test_supervision_text", "tests.test_settings_navigation", "tests.test_lever_handover", "tests.test_bow_axis_lock", "tests.test_heading_glyphs", "tests.test_leveling_boost", "tests.test_speed_source", "tests.test_disk_download", "tests.test_thrust_readback", "tests.test_ap_request_labels", "tests.test_web_setup", "tests.test_gas_mix_fix", "tests.test_disk_launcher",
          "tests.test_propulsion_rejections", "tests.test_control_stages",
          "tests.test_ship_boiler_display", "tests.test_strafe_balance")


def digest(data):
    """Return the SHA-256 content fingerprint used for source and asset checks."""
    return hashlib.sha256(data).hexdigest()


def builder_module():
    """Load the maintained Windows builder from this checkout."""
    sys.path.insert(0, str(HOME))
    import builder
    return builder


def source_files():
    """Map editable current sources to their installed core-relative paths."""
    result = {}
    for group in ("core", "library", "calibration"):
        for path in sorted((ROOT / "source" / group).rglob("*")):
            if path.is_file():
                name = path.relative_to(ROOT / "source" / group).as_posix()
                if name in result:
                    raise ValueError("Source path collision: " + name)
                result[name] = path.read_bytes()
    metadata = json.loads((ROOT / "source/baseline.json").read_bytes())
    for name, asset in metadata.get("assetBackedModules", {}).items():
        if name in result:
            raise ValueError("Asset-backed source is duplicated: " + name)
        result[name] = (HOME / "assets" / asset).read_bytes()
    notes = builder_module().source_notes
    result = notes.expand_shared_modules(result, metadata.get("sharedModules", {}))
    notes.validate_package_families(result)
    return result


def check():
    """Verify migration fingerprints, portable assets and current build round trips."""
    builder = builder_module()
    baseline = json.loads((ROOT / "source/baseline.json").read_bytes())
    actual = {p.relative_to(ROOT / "source").as_posix(): digest(p.read_bytes())
              for group in ("core", "library", "calibration")
              for p in (ROOT / "source" / group).rglob("*") if p.is_file()}
    collected = builder.collect_project(ROOT)
    packed = builder.bundling.prepare(collected, builder.FOLDERS)
    core_hash = digest(packed["payload"]["/avionics/main.lua"])
    record = {"builderVersion": builder.VERSION, "sourceFiles": len(actual),
              "migrationBaselineMatches": actual == baseline["files"],
              "coreBundleMatchesMigrationBaseline": core_hash == baseline["coreBundleSHA256"],
              "corePayloadFiles": len(packed["payload"]), "statePayloadFiles": len(packed["state"])}
    output = ROOT / "output/git-migration"
    output.mkdir(parents=True, exist_ok=True)
    (output / "source-check.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(record, indent=2))
    return record


class ProgressResult(unittest.TextTestResult):
    """Write the detailed log as before and print one progress line per test to the console."""
    total = 0

    def startTest(self, test):
        """Record the start time for the console progress line."""
        self._started = time.monotonic()
        super().startTest(test)

    def _progress(self, outcome, test):
        name = test.id().removeprefix("tests.")
        seconds = time.monotonic() - getattr(self, "_started", time.monotonic())
        print(f"[{self.testsRun}/{self.total}] {outcome:<5} {name} ({seconds:.1f} s)", flush=True)

    def addSuccess(self, test):
        super().addSuccess(test)
        self._progress("ok", test)

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self._progress("FAIL", test)

    def addError(self, test, err):
        super().addError(test, err)
        self._progress("ERROR", test)

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self._progress("skip", test)

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        if err is not None:
            failed = issubclass(err[0], test.failureException)
            print(f"        {'FAIL' if failed else 'ERROR'} in {subtest.id().removeprefix('tests.')}", flush=True)


def tests(quick=False):
    """Run the maintained regression suites against isolated portable fixtures."""
    suites = ("tests.test_information", "tests.test_bundling_compatibility", "tests.test_repository") if quick else SUITES
    output = ROOT / "output/tests"
    output.mkdir(parents=True, exist_ok=True)
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromName(name) for name in suites)
    ProgressResult.total = suite.countTestCases()
    print(f"Running {ProgressResult.total} tests; details in {output / 'results.log'}", flush=True)
    with (output / "results.log").open("w", encoding="utf-8") as stream:
        result = unittest.TextTestRunner(stream=stream, verbosity=2, resultclass=ProgressResult).run(suite)
    record = {"testsRun": result.testsRun, "failures": len(result.failures),
              "errors": len(result.errors), "passed": result.wasSuccessful()}
    (output / "results.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(record))
    if not result.wasSuccessful():
        print((output / "results.log").read_text(encoding="utf-8")[-16000:])
    return 0 if result.wasSuccessful() else 1


def build(output):
    """Build installer media from the checkout's software and shipped defaults."""
    builder = builder_module()
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    path, report = builder.build(ROOT, output, log=print)
    print(path)
    print(json.dumps({"releaseId": report["releaseId"], "mediaBytes": report["mediaBytes"]}))
    return path


def update(target, output, backup=None, apply=False):
    """Build maintained software and preview or apply it with the existing offline updater.

    The world may stay open."""
    if apply and backup is None:
        raise ValueError("Applying requires --backup.")
    builder_module()
    import updater
    plan = updater.preview_project(target, ROOT, workspace=output, log=print)
    try:
        print(plan.report())
        if apply:
            backup = Path(backup).resolve()
            backup.mkdir(parents=True, exist_ok=True)
            print("Backup: " + str(updater.apply(plan, backup)))
        return plan
    except BaseException:
        plan.close()
        raise


def cobalt(mod, java):
    """Run actual information scenarios using the engine extracted from a selected CC mod."""
    import ast
    import shutil
    from tests import test_information as cases
    builder = builder_module()
    output = ROOT / "output/tests/cobalt"
    output.mkdir(parents=True, exist_ok=True)
    pin = json.loads((ROOT / "tests/fixtures/cobalt.json").read_bytes())
    with zipfile.ZipFile(mod) as archive:
        data = archive.read(pin["entry"])
    if digest(data) != pin["sha256"]:
        raise ValueError("Selected CC mod has a different Cobalt engine; review tests/fixtures/cobalt.json")
    jar = output / "cobalt.jar"
    jar.write_bytes(data)
    java = java or shutil.which("java")
    if not java:
        raise ValueError("Java is required; pass --java with the installed Java executable.")
    current = cases.collected()
    ui = current["library"]["/packages/navigation/ui.lua"].decode()
    def literal(value):
        """Encode fixture data as a readable Lua value."""
        if isinstance(value, dict):
            return "{" + ",".join("[" + literal(k) + "]=" + literal(v) for k, v in value.items()) + "}"
        if isinstance(value, list):
            return "{" + ",".join(literal(v) for v in value) + "}"
        if isinstance(value, str):
            return builder.bundling.source_quote(value.encode())[0].decode()
        if value is True:
            return "true"
        if value is False:
            return "false"
        if value is None:
            return "nil"
        return repr(value)
    sources = {p: d.decode() for p, d in current["payload"].items() if p.endswith(".lua")}
    sources["/packages/navigation/ui.lua"] = ui
    config = json.loads((ROOT / "source/core/avionics/config.json").read_bytes())
    tree = ast.parse((ROOT / "tests/test_information.py").read_text(encoding="utf-8"))
    fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "runtime")
    bootstrap = next(n.args[0].value for n in ast.walk(fn) if isinstance(n, ast.Call)
                     and isinstance(n.func, ast.Attribute) and n.func.attr == "execute"
                     and n.args and isinstance(n.args[0], ast.Constant))
    chunks = []
    original = cases.runtime
    class Recorder:
        """Record executed fixture chunks while checking them in Lua 5.2."""
        def __init__(self, runtime):
            self.runtime = runtime
        def globals(self):
            return self.runtime.globals()
        def table(self, *args):
            return self.runtime.table(*args)
        def execute(self, text, *args):
            if text != ui:
                chunks.append(text)
            return self.runtime.execute(text, *args)
    cases.runtime = lambda: Recorder(original())
    script = ["SOURCES=" + literal(sources) + "\nCONFIG=" + literal(config) + "\nlocal completed=0\n"]
    names = []
    try:
        for cls in (cases.InformationTests, cases.InformationUiTests):
            for name in unittest.defaultTestLoader.getTestCaseNames(cls):
                chunks.clear()
                obj = cls(name)
                obj.setUp()
                getattr(obj, name)()
                obj.tearDown()
                if not chunks:
                    continue
                names.append(cls.__name__ + "." + name)
                script.append("\ndo\nos={}\nfs={exists=function()return false end,attributes=function()end}\n")
                script.extend([bootstrap, '\nUI=assert(load(SOURCES["/packages/navigation/ui.lua"]))()\nCAPTURES={}\n'])
                script.extend(text + "\n" for text in chunks)
                script.append("completed=completed+1\nend\n")
    finally:
        cases.runtime = original
    # Persistence fixtures run in the pinned engine with an in-memory filesystem.
    # Native JSON parsing is exercised separately by the Lua 5.2 persistence suite.
    from tests import test_persistence as persistence
    persistence.PersistenceTests.setUpClass()
    persistence_sources = {p: d.decode() for p, d in persistence.PersistenceTests.sources.items()}
    for name, body in persistence.CASES.items():
        names.append("PersistenceTests." + name)
        script.append("\ndo\nos={}\nBUNDLED=false\nSOURCES=" + literal(persistence_sources) + "\n")
        script.append(r'''
local function clone(v)
 if type(v)~="table" then return v end
 local result={};for k,x in pairs(v) do result[k]=clone(x) end;return result
end
local encoded={}
function encode(v)
 local function render(x)
  if type(x)=="string" then return string.format("%q",x) end
  if type(x)~="table" then return tostring(x) end
  local keys={};for k in pairs(x) do keys[#keys+1]=k end
  table.sort(keys,function(a,b)return tostring(a)<tostring(b)end)
  local parts={};for _,k in ipairs(keys) do parts[#parts+1]="["..render(k).."]="..render(x[k]) end
  return "{"..table.concat(parts,",").."}"
 end
 local text=render(v);encoded[text]=clone(v);return text
end
function decode(text) return clone(encoded[text]) end
local loaded={}
function require(name)
 if loaded[name] then return loaded[name] end
 loaded[name]=assert(load(assert(SOURCES["/"..name:gsub("%.","/")..".lua"],name),"@"..name))()
 return loaded[name]
end
''')
        script.append(persistence.HARNESS + "\nModules=assert(load(" +
                      literal(persistence.PersistenceTests.entry.decode()) + "))()\n" + body)
        script.append("\ncompleted=completed+1\nend\n")
    from tests import test_control_stages as stages
    import inspect
    maintained = {p: d.decode() for p, d in persistence.PersistenceTests.sources.items()}
    baseline = json.loads((ROOT / "tests/fixtures/control-stage-baseline.json").read_bytes())
    stage_cases = (("ioCases", stages.io_traces), ("targetCases", stages.target_traces),
                   ("recoveryCases", stages.recovery_traces), ("systemsCases", stages.systems_traces))
    script.append("\nCONTROL_STAGE_SOURCES=" + literal(maintained) + "\n")
    script.append("for path,source in pairs(CONTROL_STAGE_SOURCES) do assert(load(source,'@'..path)) end\n")
    names.append("ControlStageTests.compile_current_modules")
    script.append("completed=completed+1\n")
    for name, scenario in stage_cases:
        tree = ast.parse(inspect.getsource(scenario))
        chunks = [node.args[0].value for node in ast.walk(tree) if isinstance(node, ast.Call)
                  and isinstance(node.func, ast.Attribute) and node.func.attr == "execute"
                  and node.args and isinstance(node.args[0], ast.Constant)
                  and isinstance(node.args[0].value, str)]
        body = max(chunks, key=len)
        names.append("ControlStageTests." + name)
        script.append("\ndo\nos={clock=function()return 0 end}\nBUNDLED=false\nSOURCES=CONTROL_STAGE_SOURCES\n")
        script.append("CONFIG=" + literal(json.loads((ROOT / "source/core/avionics/config.json").read_bytes())) + "\n")
        script.append(r'''
local loaded={}
function require(name)
 if loaded[name] then return loaded[name] end
 loaded[name]=assert(load(assert(SOURCES["/"..name:gsub("%.","/")..".lua"],name),"@"..name))()
 return loaded[name]
end
''')
        script.append(persistence.HARNESS + "\nprint=function()end\n" + body + "\n")
        if name == "targetCases":
            script.append("for _,row in ipairs(TRACES) do row.remainders=textutils.unserializeJSON(row.remainders) end\n")
        script.append("local expected=" + literal(baseline[name]) + "\n")
        script.append(r'''
local function equal(a,b,path)
 assert(type(a)==type(b),path.." type")
 if type(a)=="table" then
  local n,m=0,0
  for k,v in pairs(a) do n=n+1;equal(v,b[k],path.."."..tostring(k)) end
  for k in pairs(b) do m=m+1 end
  assert(n==m,path.." keys")
 elseif type(a)=="number" then
  assert(math.abs(a-b)<=1e-8+math.abs(a)*1e-10,path.." number")
 else assert(a==b,path.." value: "..tostring(a).." / "..tostring(b)) end
end
equal(expected,TRACES,"control trace")
completed=completed+1
end
''')
    # Exercise the real worker entry points with the shared-context accessor.
    tree = ast.parse((ROOT / "tests/test_source_integrity.py").read_text(encoding="utf-8"))
    worker_test = next(node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)
                      and node.name == "test_worker_entry_points_keep_current_owner_checks_in_source_and_bundle")
    chunks = [node.args[0].value for node in ast.walk(worker_test) if isinstance(node, ast.Call)
              and isinstance(node.func, ast.Attribute) and node.func.attr == "execute"
              and node.args and isinstance(node.args[0], ast.Constant)
              and isinstance(node.args[0].value, str)]
    worker_checks = max(chunks, key=len)
    worker_files = {path: persistence.PersistenceTests.sources[path]
                    for path in ("/avionics/main.lua", "/avionics/runtime_state.lua")}
    for bundled in (False, True):
        entry = builder.bundling.pack(worker_files, persistence.PersistenceTests.loader,
            role="worker-entry-test", entry="/avionics/main.lua") if bundled else worker_files["/avionics/main.lua"]
        names.append("RuntimeStateTests.worker_entries_" + ("bundle" if bundled else "source"))
        script.append("\ndo\nos={}\nfs={exists=function()return false end}\npackage={path=''}\n")
        script.append("MAIN=" + literal(entry.decode()) + "\n")
        script.append("local shared=assert(load(CONTROL_STAGE_SOURCES['/avionics/runtime_state.lua']))()\n"
                      "function require(name) assert(name=='avionics.runtime_state');return shared end\n")
        script.append(worker_checks + "\ncompleted=completed+1\nend\n")
    script.append("return completed\n")
    target = output / "scenarios.lua"
    target.write_text("".join(script), encoding="utf-8")
    result = subprocess.run([str(java), "-cp", str(jar), str(ROOT / "tests/CobaltHarness.java"), str(target)],
                            capture_output=True, text=True)
    if result.returncode or result.stdout.strip() != str(len(names)):
        raise ValueError(result.stdout + result.stderr)
    record = {"engine": pin["version"], "sha256": pin["sha256"],
              "scenarios": len(names), "passed": True}
    (output / "results.json").write_text(json.dumps(record, indent=2), encoding="utf-8")
    print(json.dumps(record, indent=2))


def main():
    """Dispatch source verification, regression tests and source-based builds."""
    if sys.version_info[:2] != (3, 12):
        print("Validated interpreter: Python 3.12; running " +
              str(sys.version_info.major) + "." + str(sys.version_info.minor) + ".", file=sys.stderr)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    native = commands.add_parser("cobalt")
    native.add_argument("--cc-mod", type=Path, required=True)
    native.add_argument("--java", type=Path)
    test = commands.add_parser("test")
    test.add_argument("--quick", action="store_true")
    analysis = commands.add_parser("analyze-recording", help="Analyze a recording CSV or directory")
    analysis.add_argument("recording", type=Path)
    analysis.add_argument("--output", type=Path, required=True)
    analysis.add_argument("--gap-seconds", type=float, default=3)
    analysis.add_argument("--error-blocks", type=float, default=2)
    analysis.add_argument("--stall-seconds", type=float, default=20)
    release = commands.add_parser("build")
    release.add_argument("--output", type=Path, default=ROOT / "output/installers")
    upgrade = commands.add_parser("update", help="Build project source and preview an existing-ship update")
    upgrade.add_argument("--target", type=Path, required=True, help="Target save or numeric core folder")
    upgrade.add_argument("--output", type=Path, default=ROOT / ".cache/updates", help="Temporary update workspace parent")
    upgrade.add_argument("--backup", type=Path)
    upgrade.add_argument("--apply", action="store_true")
    commands.add_parser("gui", help="Open the project Disk Builder")
    args = parser.parse_args()
    if args.command == "check":
        check()
    elif args.command == "test":
        raise SystemExit(tests(args.quick))
    elif args.command == "cobalt":
        cobalt(args.cc_mod, args.java)
    elif args.command == "analyze-recording":
        from tools.recordings import write_report
        if min(args.gap_seconds, args.error_blocks, args.stall_seconds) <= 0:
            parser.error("Analysis thresholds must be positive")
        report = write_report(args.recording, args.output, gap_seconds=args.gap_seconds,
                              error_blocks=args.error_blocks, stall_seconds=args.stall_seconds)
        print(json.dumps({"rows": report["rows"], "output": str(args.output)}))
    elif args.command == "build":
        build(args.output)
    elif args.command == "update":
        plan = update(args.target, args.output, args.backup, args.apply)
        plan.close()
    elif args.command == "gui":
        builder_module().gui()


if __name__ == "__main__":
    main()
