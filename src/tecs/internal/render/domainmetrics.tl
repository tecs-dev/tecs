-- Shared statistics contract and publication for rendering domains.

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

local interface FrameStats
    count: integer
    dropped: integer
    rewritten: integer
end

local record domainmetrics
    type Stats = DomainStats
    type Frame = FrameStats

    publish: function(target: DomainStats, frame: FrameStats)
end

--- Copies the dimension-independent counters published by every domain.
function domainmetrics.publish(target: DomainStats, frame: FrameStats)
    target.count = frame.count
    target.dropped = frame.dropped
    target.rewritten = frame.rewritten
end

return domainmetrics
