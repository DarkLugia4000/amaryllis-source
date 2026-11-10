-- Section: Worker ownership | Shared in-memory contexts for core worker programs.
local RuntimeState = {}

-- Summary: Read the current shared value under its existing os-table key.
function RuntimeState.get(name)
    return os[name]
end

-- Summary: Publish or clear a shared value under its existing os-table key.
function RuntimeState.set(name, value)
    os[name] = value
end

return RuntimeState
