"""Deterministic Lua source bundles with verified, lossless source extraction."""
import base64
import hashlib
import json
import re

HEADER = b"-- Amaryllis runtime bundle v1\n"
MAGIC = "__amaryllis_bundle_entry_v1"
PATHS = ["/avionics/main.lua", "/avionics/config.json", "/avionics/common/console.lua"]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(path):
    return isinstance(path, str) and re.fullmatch(r"/(?:avionics|installer)/[A-Za-z0-9_./-]+\.lua|/startup\.lua", path) and all(
        p not in ("", ".", "..") for p in path.split("/")[1:])


def alias(bundle_path, entry):
    return ("-- Amaryllis bundled entry v1\nreturn assert(loadfile(" + json.dumps(bundle_path) +
            ",nil,_ENV))(" + json.dumps(MAGIC) + "," + json.dumps(entry) + ",...)\n").encode()


# Encode arbitrary bytes as a Lua quoted string with stable escape rules.
def quote(data):
    # Avoid the bytes.join(generator) failure reproduced on Python 3.14.7.
    # Preserve the existing byte-for-byte Lua string representation.
    encoded = bytearray(b'"')
    for n in data:
        if n < 32 or n == 127:
            encoded.extend(b"\\%03d" % n)
        elif n in (34, 92):
            encoded.append(92)
            encoded.append(n)
        else:
            encoded.append(n)
    encoded.append(34)
    return bytes(encoded)


# Decode the supported legacy Lua string escapes to exact source bytes.
def unquote(data):
    if data[:1] != b'"' or data[-1:] != b'"':
        raise ValueError("Invalid bundled source string")
    result = bytearray(); i = 1
    while i < len(data) - 1:
        n = data[i]; i += 1
        if n == 92:
            n = data[i]; i += 1
            if 48 <= n <= 57:
                digits = bytes([n]) + data[i:i+2]
                if len(digits) != 3 or not digits.isdigit() or int(digits) > 255:
                    raise ValueError("Invalid source escape")
                n = int(digits); i += 2
            elif n not in (34, 92):
                raise ValueError("Unsupported source escape")
        result.append(n)
    return bytes(result)


def source_quote(data):
    """Readable Lua literals; recover every original source byte exactly."""
    normalized = data.replace(b"\r\n", b"\n")
    mixed_endings = b"\r" in data and (
        b"\r" in normalized or data.count(b"\n") != data.count(b"\r\n"))
    controls = any(n < 32 and n not in (9, 10, 13) or n == 127 for n in data)
    if mixed_endings or controls:
        # Unusual source bytes retain escaped strings, one physical line each.
        chunks = data.splitlines(keepends=True)
        return (b"table.concat({\n" + b"".join(
            b"    " + quote(chunk) + b",\n" for chunk in chunks) + b"})",
            "quoted-lines")
    equals = b"="
    while b"]" + equals + b"]" in normalized:
        equals += b"="
    # Lua ignores the opening newline. Remove our closing padding newline so
    # empty sources and sources without a final newline also round-trip.
    encoded = (b"([" + equals + b"[\n" + normalized + b"\n]" +
               equals + b"]):sub(1,-2)")
    if b"\r\n" in data:
        return encoded + b':gsub("\\n","\\r\\n")', "long-crlf"
    return encoded, "long-lf"


def source_unquote(data, encoding):
    """Decode readable source without executing any Lua."""
    if encoding == "quoted-lines":
        prefix, suffix = b"table.concat({\n", b"})"
        if not data.startswith(prefix) or not data.endswith(suffix):
            raise ValueError("Invalid readable source framing")
        lines = data[len(prefix):-len(suffix)].splitlines()
        if any(not line.startswith(b"    ") or not line.endswith(b",") for line in lines):
            raise ValueError("Invalid readable source line")
        return b"".join(unquote(line[4:-1]) for line in lines)
    if encoding not in ("long-lf", "long-crlf"):
        raise ValueError("Unsupported readable source encoding")
    opening = re.match(rb"\(\[(=+)\[\n", data)
    if not opening:
        raise ValueError("Invalid readable source opening")
    suffix = b"\n]" + opening[1] + b"]):sub(1,-2)"
    if encoding == "long-crlf":
        suffix += b':gsub("\\n","\\r\\n")'
    if not data.endswith(suffix):
        raise ValueError("Invalid readable source closing")
    source = data[opening.end():-len(suffix)]
    return source.replace(b"\n", b"\r\n") if encoding == "long-crlf" else source

# Build a deterministic readable module bundle and its verified source index.
def pack(files, loader, *, role, entry, bundle_path="/avionics/main.lua", original_manifest=None, recovery_packages=None, source_format="readable-v1"):
    if not files or len(files) > 128 or not all(safe_path(p) and isinstance(d, bytes) for p, d in files.items()):
        raise ValueError("Unsupported bundled source paths")
    if entry not in files or not safe_path(bundle_path):
        raise ValueError("Invalid bundle entry")
    index = {"schemaVersion": 1, "role": role, "entry": entry, "bundlePath": bundle_path,
             "loaderSHA256": digest(loader), "files": []}
    if source_format not in ("escaped-v1", "readable-v1"):
        raise ValueError("Unsupported bundle source format")
    if source_format == "readable-v1":
        index["sourceFormat"] = source_format
    body = [b"local sources={\n"]
    for path, data in sorted(files.items()):
        data.decode("utf-8")
        encoded, encoding = source_quote(data) if source_format == "readable-v1" else (quote(data), None)
        record = {"path": path, "bytes": len(data), "sha256": digest(data), "encodedBytes": len(encoded)}
        if encoding is not None:
            record["encoding"] = encoding
        index["files"].append(record)
        body += [b"[" + json.dumps(path).encode() + b"]=", encoded, b",\n"]
    if original_manifest is not None:
        index["originalManifest"] = original_manifest
    if recovery_packages is not None:
        if not isinstance(recovery_packages, list) or not 1 <= len(recovery_packages) <= 14:
            raise ValueError("Invalid package recovery metadata")
        index["recoveryPackages"] = recovery_packages
    metadata = json.dumps(index, sort_keys=True, separators=(",", ":")).encode()
    if len(metadata) > 65536:
        raise ValueError("Bundle index exceeds metadata limits")
    return HEADER + b"-- index:" + metadata + b"\n" + b"".join(body) + b"}\nlocal bundlePath=" + json.dumps(bundle_path).encode() + b"\nlocal defaultEntry=" + json.dumps(entry).encode() + b"\n" + loader


# Verify a bundle index and recover each embedded source byte for byte.
def unpack(data, loader):
    if not data.startswith(HEADER):
        return None
    line, _, _ = data[len(HEADER):].partition(b"\n")
    if not line.startswith(b"-- index:") or len(line) > 65536:
        raise ValueError("Invalid bundle index")
    index = json.loads(line[len(b"-- index:"):])
    if index.get("schemaVersion") != 1 or index.get("loaderSHA256") != digest(loader):
        raise ValueError("Unsupported or damaged bundle loader")
    source_format = index.get("sourceFormat", "escaped-v1")
    if source_format not in ("escaped-v1", "readable-v1"):
        raise ValueError("Unsupported bundle source format")
    entries = index.get("files")
    if not isinstance(entries, list) or not 1 <= len(entries) <= 128:
        raise ValueError("Invalid bundle file count")
    offset = len(HEADER) + len(line) + 1 + len(b"local sources={\n")
    result = {}
    for entry in entries:
        p, size, encoded_size = entry.get("path"), entry.get("bytes"), entry.get("encodedBytes")
        if not safe_path(p) or p in result or type(size) is not int or not 0 <= size <= 4_000_000 or type(encoded_size) is not int or not 2 <= encoded_size <= 4_000_000:
            raise ValueError("Unsafe bundle index entry")
        marker = b"[" + json.dumps(p).encode() + b"]="
        if data[offset:offset + len(marker)] != marker:
            raise ValueError("Bundle source index mismatch")
        offset += len(marker)
        encoded = data[offset:offset + encoded_size]
        source = (source_unquote(encoded, entry.get("encoding"))
                  if source_format == "readable-v1" else unquote(encoded))
        if len(source) != size or digest(source) != entry.get("sha256"):
            raise ValueError("Bundle source checksum mismatch: " + p)
        result[p] = source
        offset += encoded_size + 2
    expected = pack(result, loader, role=index.get("role"), entry=index.get("entry"), bundle_path=index.get("bundlePath"),
                    original_manifest=index.get("originalManifest"),
                    recovery_packages=index.get("recoveryPackages"), source_format=source_format)
    if expected != data:
        raise ValueError("Bundle framing or loader verification failed")
    return index, result


def expand(mapping, loader):
    """Expand one installed computer's source view; preserve writable files."""
    result = dict(mapping)
    bundles = [(p, unpack(d, loader)) for p, d in mapping.items() if d.startswith(HEADER)]
    if len(bundles) > 1:
        raise ValueError("Several bundles in one computer source")
    for bundle_path, (index, files) in bundles:
        if index["bundlePath"] != bundle_path:
            raise ValueError("Bundle is at an unexpected path")
        result.pop(bundle_path)
        for p, data in list(result.items()):
            if p in files and data == alias(bundle_path, p):
                result.pop(p)
        for p, data in files.items():
            if p in result and result[p] != data:
                raise ValueError("Bundled and loose source conflict: " + p)
            result[p] = data
    return result


# Adapt package serving to the bundled library layout.
def server_overlay(data):
    text = data.decode()
    marker = "-- Bundled package destinations v1\n"
    if marker in text:
        return data
    hook = 'M.PROTOCOL = "amaryllis.install.v1"'
    if text.count(hook) != 1:
        raise ValueError("Unsupported package server for bundling")
    addition = marker + '''for _,definition in pairs(ROLE_FILES) do
    definition.paths={"/avionics/main.lua","/avionics/config.json","/avionics/common/console.lua"}
    definition.sources={["/avionics/main.lua"]="main.lua",["/avionics/config.json"]="config.json",
        ["/avionics/common/console.lua"]="/packages/common/console.lua"}
end
'''
    return text.replace(hook, addition + hook).encode()


# Recover the original package server from its supported bundle overlay.
def server_source(data):
    text = data.decode()
    start = text.find("-- Bundled package destinations v1\n")
    if start < 0:
        return data
    end = text.find('M.PROTOCOL = "amaryllis.install.v1"', start)
    if end < 0:
        raise ValueError("Damaged bundled package server")
    return (text[:start] + text[end:]).encode()


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=True) + "\n").encode()


# Validate the saved package manifest for a recovered bundled role.
def package_recovery(index, role):
    records = index.get("recoveryPackages")
    if records is None:return None
    if not isinstance(records, list) or not 1 <= len(records) <= 14:
        raise ValueError("Invalid package recovery metadata")
    found = {};configs = {}
    for record in records:
        if not isinstance(record, dict) or set(record) != {"manifest", "configBase64"} or not isinstance(record["manifest"], dict):
            raise ValueError("Invalid package recovery entry")
        original = record["manifest"];name = original.get("role")
        if not isinstance(name, str) or name in found:
            raise ValueError("Duplicate package recovery role")
        config = base64.b64decode(record["configBase64"], validate=True)
        if len(config) > 32768:raise ValueError("Package recovery config exceeds limits")
        found[name] = original;configs[name] = config
    if role not in found:raise ValueError("Missing package recovery role: " + role)
    return found[role], configs[role]


def recover_library(catalog, folders, loader, read_role, legacy=None):
    """Recover exact catalog objects without executing installed Lua.

    read_role validates registration and receipt before returning a bundle.
    Legacy metadata holds original JSON defaults/manifests by content hash.
    """
    import zlib
    entries = {e["path"]: e for e in catalog["files"]}
    result = {}

    def add(path, data):
        e = entries.get(path, {})
        if (digest(data) != e.get("object") or len(data) != e.get("bytes") or
                f"{zlib.adler32(data):08X}" != e.get("adler32")):
            raise ValueError("Installed package does not match core's catalog: " + path)
        result[path] = data

    for role, folder in folders.items():
        prefix = "/packages/" + folder + "/"
        data = read_role(role, catalog["roles"][role], [entries[prefix + p] for p in ("main.lua", "config.json")] +
                         [entries["/packages/common/console.lua"]])
        add(prefix + "main.lua", data)
        decoded = unpack(data, loader)
        if decoded is None or decoded[0].get("role") != "auxiliary":
            raise ValueError("Installed package is not a supported auxiliary bundle: " + role)
        index, files = decoded
        recovered = package_recovery(index, role)
        if recovered is not None:
            original, config = recovered
            manifest = dict(original, files=PATHS[:], version=original.get("version", -1) + 1,
                            sourceManifest=original)
            add(prefix + "manifest.json", encoded(manifest))
            add(prefix + "config.json", config)
        else:
            if callable(legacy):legacy = legacy()
            for name in ("manifest.json", "config.json"):
                path = prefix + name
                raw = (legacy or {}).get(entries[path]["object"])
                if raw is None:
                    raise ValueError("Older bundle lacks original package defaults for " + role +
                                     "; automatic media discovery or a matching library is needed")
                add(path, base64.b64decode(raw, validate=True))
        manifest = json.loads(result[prefix + "manifest.json"])
        if ({k: manifest.get(k) for k in ("packageId", "version")} != catalog["roles"][role] or
                manifest.get("role") != role or manifest.get("files") != PATHS or
                set(files) != {p for p in manifest.get("sourceManifest", {}).get("files", []) if p.endswith(".lua")}):
            raise ValueError("Recovered package identity or module inventory mismatch: " + role)
    add("/packages/common/console.lua", alias("/avionics/main.lua", "/avionics/common/console.lua"))
    if set(result) != set(entries):
        raise ValueError("Core catalog has unsupported recovery destinations")
    return result


# Expand bundled role programs and reconstruct their editable package library.
def library_source(mapping, folders, loader):
    result = dict(mapping)
    for role, folder in folders.items():
        prefix = "/packages/" + folder + "/"
        manifest = json.loads(mapping[prefix + "manifest.json"])
        if "sourceManifest" not in manifest:
            continue
        decoded = unpack(mapping[prefix + "main.lua"], loader)
        if decoded is None:
            raise ValueError("Bundled package source missing: " + role)
        index, files = decoded
        original = manifest["sourceManifest"]
        if (index["role"] != "auxiliary" or original.get("role") != role or
                manifest.get("files") != PATHS or original.get("packageId") != manifest.get("packageId") or
                manifest.get("version") != original.get("version", 0) + 1):
            raise ValueError("Bundled package source manifest mismatch: " + role)
        recovered = package_recovery(index, role)
        if recovered is not None and (recovered[0] != original or recovered[1] != mapping[prefix + "config.json"]):
            raise ValueError("Bundled package recovery metadata mismatch: " + role)
        expected = {p for p in original["files"] if p.endswith(".lua")}
        if set(files) != expected:
            raise ValueError("Bundled package module inventory mismatch: " + role)
        result.pop(prefix + "main.lua")
        result[prefix + "manifest.json"] = encoded(original)
        for destination, data in files.items():
            source = {"/avionics/common/console.lua": "/packages/common/console.lua",
                      "/avionics/diagnostics.lua": "/packages/common/diagnostics.lua"}.get(destination, prefix + destination.rsplit("/", 1)[-1])
            existing = result.get(source)
            if existing is not None and existing != data and existing != alias("/avionics/main.lua", destination):
                raise ValueError("Conflicting recovered package source: " + source)
            result[source] = data
    return result


def prepare(source, folders):
    """Bundle generated payloads only; collect() keeps its editable source view."""
    import copy
    source = dict(source)
    loader = source["assets"]["runtime-loader.lua"]
    counts = {}
    for key, role, entry in (("payload", "core", "/avionics/main.lua"), ("state", "state", "/avionics/state_reader.lua")):
        original = source[key]
        files = {p: d for p, d in original.items() if p.endswith(".lua")}
        counts[role] = {"before": len(original), "luaBefore": len(files)}
        if role == "core":
            files["/installer/server.lua"] = server_overlay(files["/installer/server.lua"])
        result = {p: d for p, d in original.items() if not p.endswith(".lua")}
        if role == "core":
            transfer = json.loads(result["/installer/config.json"])
            transfer["max_file_bytes"] = 524288
            transfer["max_total_bytes"] = max(1048576, transfer["max_total_bytes"])
            result["/installer/config.json"] = encoded(transfer)
        result["/avionics/main.lua"] = pack(files, loader, role=role, entry=entry)
        result["/startup.lua"] = alias("/avionics/main.lua", "/startup.lua")
        counts[role].update(after=len(result), luaAfter=2)
        source[key] = result
    library = {"/packages/common/console.lua": alias("/avionics/main.lua", "/avionics/common/console.lua")}
    candidates = {};shared_metadata = {}
    for role, folder in folders.items():
        prefix = "/packages/" + folder + "/"
        manifest = json.loads(source["library"][prefix + "manifest.json"])
        files = {}
        for destination in manifest["files"]:
            if not destination.endswith(".lua"):
                continue
            origin = {"/avionics/common/console.lua": "/packages/common/console.lua",
                      "/avionics/diagnostics.lua": "/packages/common/diagnostics.lua"}.get(destination, prefix + destination.rsplit("/", 1)[-1])
            files[destination] = source["library"][origin]
        # Metadata must be identical for roles sharing the same executable
        # bundle, preserving content-addressed object deduplication on media.
        group = digest(pack(files, loader, role="auxiliary", entry="/avionics/main.lua"))
        candidates[role] = (files, manifest, group)
        shared_metadata.setdefault(group, []).append({"manifest": manifest,
            "configBase64": base64.b64encode(source["library"][prefix + "config.json"]).decode("ascii")})
    for records in shared_metadata.values():records.sort(key=lambda record:record["manifest"]["role"])
    versions = {}
    for role, folder in folders.items():
        prefix = "/packages/" + folder + "/"
        files, manifest, group = candidates[role]
        bundle = pack(files, loader, role="auxiliary", entry="/avionics/main.lua",
                      recovery_packages=shared_metadata[group])
        if len(bundle) > 524288:
            raise ValueError("Bundled package exceeds receiver file limit: " + role)
        result_manifest = copy.deepcopy(manifest)
        if not 1 <= manifest["version"] < 65535:
            raise ValueError("Package version cannot be advanced for bundling: " + role)
        result_manifest.update(files=PATHS[:], version=manifest["version"] + 1, sourceManifest=manifest)
        library[prefix + "main.lua"] = bundle
        library[prefix + "config.json"] = source["library"][prefix + "config.json"]
        library[prefix + "manifest.json"] = encoded(result_manifest)
        versions[role] = result_manifest["version"]
        counts[role] = {"before": len(manifest["files"]), "luaBefore": len(files), "after": 3, "luaAfter": 2}
    source["library"] = library
    source["versions"] = versions
    source["bundleCounts"] = counts
    return source
