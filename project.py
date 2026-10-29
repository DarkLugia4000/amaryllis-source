"""Local project commands for portable source builds and isolated regression fixtures."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent
HOME = ROOT / "Amaryllis Installer Builder"
SUITES = ("test_windows_builder", "test_runtime_bundling", "test_bundling_compatibility",
          "test_information", "test_bridge_presentation", "test_persistent_modes", "test_repository")


def digest(data):
    """Return the stable content fingerprint used by fixture caches."""
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
    return result


def fixture(kind="current"):
    """Materialize a synthetic registered ship under the ignored fixture cache."""
    metadata = json.loads((ROOT / "source/baseline.json").read_bytes())
    if kind == "legacy":
        record = json.loads((ROOT / "tests/fixtures/legacy-source.json").read_bytes())
        archive = ROOT / "tests/fixtures/legacy-source-2.7.1.zip"
        if digest(archive.read_bytes()) != record["sha256"]:
            raise ValueError("Legacy fixture archive checksum changed")
        with zipfile.ZipFile(archive) as bundle:
            files = {name: bundle.read(name) for name in bundle.namelist()}
        if {p: digest(d) for p, d in files.items()} != record["files"]:
            raise ValueError("Legacy fixture source checksums changed")
    elif kind == "current":
        files = source_files()
    else:
        raise ValueError("Unknown fixture: " + kind)
    roles = metadata["roles"]
    registry = {"schemaVersion": 1, "computers": {}}
    for number, (role, entry) in enumerate(roles.items()):
        registry["computers"][role] = {"id": number, "label": entry["label"]}
    bootstrap = (HOME / "assets/installer.lua").read_bytes()
    identity = digest(b"".join(name.encode() + b"\0" + data for name, data in sorted(files.items()))
                      + json.dumps(registry, sort_keys=True).encode() + bootstrap)
    cache = ROOT / ".cache/fixtures" / (kind + "-" + identity[:16])
    core_id = registry["computers"]["core"]["id"]
    core = cache / "computercraft/computer" / str(core_id)
    complete = cache / "complete.json"
    if complete.is_file():
        expected = json.loads(complete.read_bytes())
        actual = {p.relative_to(cache).as_posix(): digest(p.read_bytes())
                  for p in cache.rglob("*") if p.is_file() and p != complete}
        if actual != expected:
            raise ValueError("Generated fixture changed: " + str(cache))
        return core
    if cache.exists():
        raise ValueError("Incomplete generated fixture: " + str(cache))
    core.mkdir(parents=True)
    for name, data in files.items():
        path = (core / name).resolve()
        if not path.is_relative_to(core.resolve()):
            raise ValueError("Unsafe fixture path: " + name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    (core / "fleet.json").write_text(json.dumps(registry, indent=2) + "\n", encoding="utf-8")
    nav = cache / "computercraft/computer" / str(registry["computers"]["navigator"]["id"])
    nav.mkdir()
    (nav / "installer.lua").write_bytes(bootstrap)
    hashes = {p.relative_to(cache).as_posix(): digest(p.read_bytes())
              for p in cache.rglob("*") if p.is_file()}
    complete.write_text(json.dumps(hashes, indent=2) + "\n", encoding="utf-8")
    return core


def check():
    """Verify migration fingerprints, portable assets and current build round trips."""
    builder = builder_module()
    baseline = json.loads((ROOT / "source/baseline.json").read_bytes())
    actual = {p.relative_to(ROOT / "source").as_posix(): digest(p.read_bytes())
              for group in ("core", "library", "calibration")
              for p in (ROOT / "source" / group).rglob("*") if p.is_file()}
    collected = builder.collect(fixture())
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


def tests(quick=False):
    """Run the maintained regression suites against isolated portable fixtures."""
    suites = ("test_information", "test_bundling_compatibility", "test_repository") if quick else SUITES
    output = ROOT / "output/tests"
    output.mkdir(parents=True, exist_ok=True)
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromName(name) for name in suites)
    with (output / "results.log").open("w", encoding="utf-8") as stream:
        result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
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
    path, report = builder.build(fixture(), output, log=print)
    print(path)
    print(json.dumps({"releaseId": report["releaseId"], "mediaBytes": report["mediaBytes"]}))
    return path


def cobalt(mod, java):
    """Run actual information scenarios using the engine extracted from a selected CC mod."""
    import ast
    import shutil
    import test_information as cases
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
    config = json.loads((fixture("legacy") / "avionics/config.json").read_bytes())
    tree = ast.parse((ROOT / "test_information.py").read_text(encoding="utf-8"))
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
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    native = commands.add_parser("cobalt")
    native.add_argument("--cc-mod", type=Path, required=True)
    native.add_argument("--java", type=Path)
    test = commands.add_parser("test")
    test.add_argument("--quick", action="store_true")
    release = commands.add_parser("build")
    release.add_argument("--output", type=Path, default=ROOT / "output/installers")
    args = parser.parse_args()
    if args.command == "check":
        check()
    elif args.command == "test":
        raise SystemExit(tests(args.quick))
    elif args.command == "cobalt":
        cobalt(args.cc_mod, args.java)
    elif args.command == "build":
        build(args.output)


if __name__ == "__main__":
    main()
