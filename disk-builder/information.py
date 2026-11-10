"""Remove generated documentation comments from Lua source before packaging."""


def strip_notes(payload):
    """Recover functional source beneath generated documentation comments."""
    for path,data in list(payload.items()):
        if path.endswith(".lua"):
            payload[path]=b"".join(line for line in data.splitlines(keepends=True)
                if not line.lstrip().startswith((b"-- Summary:",b"-- Section:",b"-- @ama-summary:",b"-- @ama-section:")))
