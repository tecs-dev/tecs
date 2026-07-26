--- Things outside the sequencer a program can wait for.
---
--- A subsystem registers `{isPending = fn}` under a name, and an `await` step
--- parks a cursor until that name reports the work is done. This is what lets
--- a program wait for a sprite animation without the sequencer knowing what a
--- sprite is: the dependency points inward, and `tecs2d.gfx` requires the
--- sequencer rather than the other way round.
---
--- Registered globally, like evaluators and for the same reason: a provider is
--- code, and a snapshot carries the name it was registered under.

local tecs <const> = require("tecs")

local type World = tecs.World

local record awaitables
    --- What a name has to answer.
    record Provider
        --- Whether the work named by `entity` and `key` is still going.
        ---
        --- Called at a step boundary for every cursor parked on this name, so
        --- it must be cheap and must not mutate the world. Returning false
        --- for something that never started is correct: a program waiting for
        --- an animation that is already over should carry on, not hang.
        isPending: function(world: World, entity: integer, key: string): boolean
    end

    --- Register a provider. Registering a name twice replaces it, which is
    --- what a hot reload wants.
    register: function(name: string, provider: Provider)

    --- Look one up, or nil.
    get: function(name: string): Provider
end

local byName: {string: awaitables.Provider} = {}

function awaitables.register(name: string, provider: awaitables.Provider)
    if type(name) ~= "string" or name == "" then
        error("sequence: an awaitable needs a non-empty name", 2)
    end
    if type(provider) ~= "table" or provider.isPending == nil then
        error("sequence: an awaitable needs an isPending function", 2)
    end
    byName[name] = provider
end

function awaitables.get(name: string): awaitables.Provider
    return byName[name]
end

return awaitables
