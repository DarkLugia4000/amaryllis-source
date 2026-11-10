"""Read the flight/thrust settings registry, extract inline fallbacks and render the tuning reference tables."""
import json
import math
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
AVIONICS = ROOT / "source/core/avionics"
REFERENCE = ROOT / "docs/development/TUNING-REFERENCE.md"
BEGIN = "<!-- BEGIN generated settings tables: python tools/config_registry.py --write -->"
END = "<!-- END generated settings tables -->"

# Which config object an expression names in each consuming file. Keys are checked against the
# registry section, so an object listed here that also reads another section is harmless.
OBJECTS = {
    "flight.lua": {"c": "altitude_control", "self.config": "altitude_control", "config.thrust": "thrust"},
    "thrust.lua": {"c": "thrust", "self.config.thrust": "thrust", "config.thrust": "thrust", "config": "thrust"},
    "anchor.lua": {"thrustConfig": "thrust"},
}
NUMBER = r"(?P<val>-?\d*\.?\d+|math\.huge)"
PATTERNS = (
    re.compile(r"(?<![\w.])(?P<obj>[A-Za-z_][\w.]*)\.(?P<key>[a-z][a-z0-9_]+)\s+or\s+" + NUMBER + r"(?![\w.])"),
    re.compile(r"finite\((?P<obj>[A-Za-z_][\w.]*)\.(?P<key>[a-z][a-z0-9_]+)\)\s+and\s+(?P<expr>[^\n]{0,100}?)\s+or\s+" + NUMBER + r"(?![\w.])"),
    re.compile(r"Registry\.number\((?P<obj>[A-Za-z_][\w.]*),\s*\"(?P<sec>altitude_control|thrust)\.(?P<key>[a-z][a-z0-9_.]+)\"\)"),
)


def runtime(root=ROOT):
    """Return a Lua 5.2 runtime whose require() resolves maintained core modules."""
    from lupa.lua52 import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().package.path = str(root / "source/core/?.lua")
    return lua


def lua_value(lua, value):
    """Convert decoded JSON into Lua tables, keeping explicit false and zero."""
    if isinstance(value, dict):
        return lua.table_from({k: lua_value(lua, v) for k, v in value.items()})
    if isinstance(value, list):
        return lua.table_from([lua_value(lua, v) for v in value])
    return value


def registry(root=ROOT):
    """Load config_registry.lua in a plain Lua 5.2 runtime and return its entries as Python dicts."""
    module = runtime(root).eval('require("avionics.config_registry")')
    entries = []
    for item in module.entries.values():
        entry = {}
        for key, value in item.items():
            if key == "fallbacks":
                entry[key] = [float(v) for v in value.values()]
            else:
                entry[key] = value
        entries.append(entry)
    return entries


def fallbacks(root=ROOT):
    """Return {(section, path): {values}} for numeric fallbacks written inline in the consuming modules.

    Registry.number calls are reported with the value None, meaning the registry fallback is used."""
    found = {}
    for name, objects in OBJECTS.items():
        text = (root / "source/core/avionics" / name).read_text(encoding="utf-8")
        for line in text.splitlines():
            if line.lstrip().startswith("--"):
                continue
            for pattern in PATTERNS:
                for match in pattern.finditer(line):
                    section = objects.get(match.group("obj"))
                    if not section:
                        continue
                    expression = match.groupdict().get("expr") or ""
                    if re.search(r"\." + match.group("key") + r"\s*[/*]", expression):
                        # A fallback for a value derived from the setting (for example RPM/256), not the setting.
                        continue
                    named = match.groupdict().get("sec")
                    if named and named != section:
                        raise ValueError(f"{name}: {match.group(0)} reads {named} from a {section} object")
                    raw = match.groupdict().get("val")
                    value = None if raw is None else (math.inf if raw == "math.huge" else float(raw))
                    found.setdefault((section, match.group("key")), set()).add(value)
    return found


def shipped(root=ROOT):
    """Return {(section, path): value} for scalar settings in the shipped core config."""
    config = json.loads((root / "source/core/avionics/config.json").read_bytes())
    result = {}

    def walk(section, prefix, node):
        for key, value in node.items():
            if isinstance(value, dict):
                walk(section, prefix + key + ".", value)
            else:
                result[(section, prefix + key)] = value
    for section in ("altitude_control", "thrust"):
        walk(section, "", config[section])
    return result


def _number(value):
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if value == math.inf:
        return "disabled"
    return format(value, "g")


def _bound(entry):
    if entry["kind"] == "boolean":
        return "boolean"
    lo, hi = entry.get("min"), entry.get("max")
    if lo is None and hi is None:
        text = "none"
    else:
        left = "(" if entry.get("minExclusive") else "["
        right = ")" if entry.get("maxExclusive") else "]"
        text = left + (_number(lo) if lo is not None else "-inf") + ", " + (_number(hi) if hi is not None else "inf") + right
    if entry["kind"] == "integer":
        text += " integer"
    return text


def render(root=ROOT):
    """Render the generated Markdown tables for both settings sections."""
    values = shipped(root)
    lines = [BEGIN, ""]
    entries = registry(root)
    for section in ("altitude_control", "thrust"):
        lines += ["## " + section, "",
                  "| Key | Shipped | Fallback when absent | Unit | Bound (enforced by) | Effect | Evidence |",
                  "| --- | --- | --- | --- | --- | --- | --- |"]
        for entry in sorted((e for e in entries if e["section"] == section), key=lambda e: e["path"]):
            ship = values.get((section, entry["path"]))
            fall = ", ".join(_number(v) for v in entry.get("fallbacks", [])) or "required"
            source = {"schema": "config validation", "runtime": "runtime clamp", "none": "not bounded"}[entry["bound"]]
            effect = entry.get("effect", "") + (". " + entry["note"] if entry.get("note") else "")
            lines.append("| `{}` | {} | {} | {} | {} ({}) | {} | {} |".format(
                entry["path"], _number(ship) if ship is not None else "not shipped", fall, entry.get("unit") or "",
                _bound(entry), source, effect, entry.get("evidence", "")))
        lines.append("")
    lines += ["## Fallbacks that differ from the shipped value", "",
              "A fallback applies only when the setting is absent. For a required setting, configuration validation "
              "rejects a config without it, so the fallback cannot be reached while the config is valid. "
              "These differences are recorded for a separate behavioral decision; Delivery 5 did not change them.", "",
              "| Setting | Shipped | Fallback | Reachable |", "| --- | --- | --- | --- |"]
    for entry in sorted(entries, key=lambda e: (e["section"], e["path"])):
        ship = values.get((entry["section"], entry["path"]))
        falls = entry.get("fallbacks", [])
        if ship is None or not falls or (len(falls) == 1 and falls[0] == ship):
            continue
        reach = "no: required setting" if entry.get("required") else "yes, when the setting is removed"
        lines.append("| `{}.{}` | {} | {} | {} |".format(entry["section"], entry["path"], _number(ship),
                                                     ", ".join(_number(v) for v in falls), reach))
    lines += ["", END]
    return "\n".join(lines)


def write(root=ROOT):
    """Replace the generated block in the tuning reference."""
    path = root / "docs/development/TUNING-REFERENCE.md"
    text = path.read_text(encoding="utf-8")
    start, end = text.index(BEGIN), text.index(END) + len(END)
    path.write_text(text[:start] + render(root) + text[end:], encoding="utf-8")


if __name__ == "__main__":
    import sys
    if "--write" in sys.argv:
        write()
    else:
        print(render())
