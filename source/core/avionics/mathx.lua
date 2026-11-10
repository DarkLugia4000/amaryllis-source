-- Section: Numeric primitives | Finite measurements and ordered bounds.
local Mathx = {}

-- Summary: Accept finite Lua numbers for measurements and controller state.
function Mathx.finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

-- Summary: Apply the upper bound first, then the lower bound, preserving controller clamp order.
function Mathx.clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

return Mathx
