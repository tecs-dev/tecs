--[=[
Defines statistics shared by rendering domains.

The contract covers extraction only. GPU residency has domain-specific units,
and the renderer owns the device and destruction lifecycle.
]=]

local interface DomainStats
    --- Read-only. Reports instances resident after the last extraction.
    count: integer
    --- Read-only. Reports instances the last extraction could not fit.
    dropped: integer
    --- Read-only. Reports instances rewritten by the last extraction.
    rewritten: integer

    --- Returns the seconds consumed by the last extraction.
    --- @return Returns elapsed seconds, or zero while measurement is inactive.
    extractSeconds: function(self): number
end

return DomainStats
