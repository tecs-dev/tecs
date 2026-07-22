--- Suspends a world's gameplay while leaving its render phases active.
---
--- Suspension is reference-counted by named holders. This lets loading
--- screens, the debugger, and MCP tools suspend the same world without
--- accidentally resuming one another's hold.

local tecs <const> = require("tecs")
local controller <const> = require("tecs2d.internal.suspension")

local record suspension
    --- Suspend gameplay on behalf of `holder`.
    --- Returns false when that holder already owns a suspension.
    suspend: function(world: tecs.World, holder: string): boolean

    --- Release `holder`'s suspension.
    --- Returns false when the holder did not own one.
    resume: function(world: tecs.World, holder: string): boolean

    --- Whether any holder currently suspends the world.
    isSuspended: function(world: tecs.World): boolean

    --- Whether one named holder currently suspends the world.
    heldBy: function(world: tecs.World, holder: string): boolean
end

local function checkHolder(holder: string)
    assert(holder ~= nil and holder ~= "", "suspension holder must be a non-empty string")
end

function suspension.suspend(world: tecs.World, holder: string): boolean
    checkHolder(holder)
    return controller.ensure(world):suspend(holder)
end

function suspension.resume(world: tecs.World, holder: string): boolean
    checkHolder(holder)
    return controller.ensure(world):resume(holder)
end

function suspension.isSuspended(world: tecs.World): boolean
    return controller.ensure(world):isSuspended()
end

function suspension.heldBy(world: tecs.World, holder: string): boolean
    checkHolder(holder)
    return controller.ensure(world):heldBy(holder)
end

return suspension
