--- Process-wide unique component-ID allocator.
---
--- Lives in its own tiny module so both `tecs.internal.components` and
--- `tecs.internal.ffi.FFIStorage` can pull from the same
--- counter without creating a circular require.

local componentIds = {}

local AUTO_COMPONENT_ID = 0

function componentIds.allocate(): integer
    AUTO_COMPONENT_ID = AUTO_COMPONENT_ID + 1
    return AUTO_COMPONENT_ID
end

return componentIds
