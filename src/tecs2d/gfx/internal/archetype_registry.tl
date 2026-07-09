--- Renderer-side per-archetype state tracking. Each renderer that needs
--- per-archetype shadow buffers (circles, rects, ellipses, ...) creates
--- one of these. The registry:
---
--- 1. Walks existing archetypes at install time and tests each against a
---    caller-supplied predicate. Matching archetypes get a fresh state
---    object via the caller's factory.
--- 2. Subscribes to `ArchetypeCreated` so future matching archetypes are
---    registered the same way.
--- 3. Attaches the state object as an `ArchetypeEntityObserver` so the
---    state receives `onEntitiesAdded` / `onEntitiesRemoved` /
---    `onEntityMove` / `onActivated` / `onDeactivated` /
---    `onArchetypeDestroyed` directly.
--- 4. Auto-removes destroyed archetypes from its tracking table.
---
--- This keeps the entire ownership boundary inside the renderer plugin.
--- The state object is keyed by archetype identity; component handles flow
--- through registration arguments, not through monkey-patching shared
--- component definitions.

local tecs <const> = require("tecs")
local tecs_types <const> = require("tecs.types")

local type ArchetypeEntityObserver = tecs_types.ArchetypeEntityObserver

-- The state interface that callers must implement. Listed here for
-- documentation; the registry interacts with these methods via dynamic
-- dispatch so we don't enforce a strict Teal interface on the state type.
--
--   onEntitiesAdded(self, archetype, firstRow, lastRow, count, sourceArch?)
--   onEntitiesRemoved(self, archetype, firstRow, lastRow, count, destArch?)
--   onEntityMove(self, archetype, entity, fromRow, toRow)   -- optional
--   onActivated(self, archetype)                            -- optional
--   onDeactivated(self, archetype)                          -- optional
--   onArchetypeDestroyed(self, archetype)                   -- optional
--   flush(self)                                             -- called by uploader

local type StateIterator = function({tecs.Archetype: any}, tecs.Archetype): (tecs.Archetype, any)

local record archetype_registry
    type StateIterator = StateIterator

    record Options
        --- Logging label for this registry.
        name: string
        --- Predicate run on each archetype. Return true to register.
        matches: function(tecs.Archetype): boolean
        --- Factory: build the per-archetype state object. The returned
        --- object becomes the archetype's observer and is what
        --- `flush()` is called on.
        create: function(tecs.Archetype): any
    end

    record Registry
        world: tecs.World
        name: string
        matches: function(tecs.Archetype): boolean
        create: function(tecs.Archetype): any
        --- Per-archetype state map. Iteration via `archetypes()`.
        states: {tecs.Archetype: any}

        --- Iterator over (archetype, state) pairs. Stable while
        --- archetypes aren't destroyed mid-iteration; consumers should
        --- treat it like a query iterator. Stateless (returns `next` +
        --- the state map), so per-frame callers allocate nothing.
        archetypes: function(self): (StateIterator, {tecs.Archetype: any})
        --- Convenience: invoke `state:flush()` for every registered
        --- archetype. Per-shape uploaders typically use this directly
        --- after walking their own dirty state.
        flushAll: function(self)
        --- Lookup. Returns nil for unmatched archetypes.
        get: function(self, archetype: tecs.Archetype): any
    end

    new: function(world: tecs.World, opts: Options): Registry
end

local Registry <const> = archetype_registry.Registry
local REGISTRY_MT <const>: metatable<Registry> = {__index = Registry}

local ArchetypeCreated <const> = tecs.builtins.ArchetypeCreated
local Disabled <const> = tecs.builtins.Disabled

--- Wraps the user-supplied state to intercept `onArchetypeDestroyed`.
--- The registry needs to remove the state from its tracking table when
--- the archetype is destroyed; the user's state may also have its own
--- cleanup. Both fire (registry cleanup runs after user code).
local function wrapState(state: any, registry: Registry, archetype: tecs.Archetype): any
    local stateAny = state as {string:any}
    local userOnDestroyed = stateAny.onArchetypeDestroyed as function(any, tecs.Archetype)
    stateAny.onArchetypeDestroyed = function(self: any, arch: tecs.Archetype)
        if userOnDestroyed then userOnDestroyed(self, arch) end
        registry.states[archetype] = nil
    end
    return state
end

local function consider(self: Registry, arch: tecs.Archetype)
    if self.states[arch] then return end
    -- Every registry consumer is render-side, and disabled entities must
    -- never render. Queries auto-exclude Disabled; this path bypasses the
    -- query engine, so mirror that rule here rather than in each caller's
    -- predicate. Disabling moves an entity into a Disabled-bearing
    -- archetype, which stays unregistered; re-enabling moves it back into
    -- a tracked one, re-syncing it through onEntitiesAdded.
    if arch:get(Disabled) ~= nil then return end
    if not self.matches(arch) then return end

    local state = self.create(arch)
    if state == nil then return end
    wrapState(state, self, arch)
    self.states[arch] = state
    arch:addEntityObserver(state as ArchetypeEntityObserver)
end

function archetype_registry.new(world: tecs.World, opts: archetype_registry.Options): Registry
    local self: Registry = setmetatable({
        world = world,
        name = opts.name,
        matches = opts.matches,
        create = opts.create,
        states = {},
    }, REGISTRY_MT)

    -- Walk existing archetypes. Plugins typically install before any
    -- entities are spawned, but worlds can be partially populated by
    -- the time gfx is attached (e.g., loaded snapshot, late plugin).
    world:forEachArchetype(function(arch: tecs.Archetype)
        consider(self, arch)
    end)

    -- Subscribe to future archetype creations.
    local observe = (world as {string:any}).observe as function(any, integer, any, function(any))
    observe(world, 0, ArchetypeCreated, function(event: any)
        consider(self, (event as {string:any}).archetype as tecs.Archetype)
    end)

    return self
end

local nextState <const> = next as StateIterator

function Registry:archetypes(): StateIterator, {tecs.Archetype: any}
    return nextState, self.states
end

function Registry:flushAll()
    for _, state in pairs(self.states) do
        local fn = (state as {string:any}).flush as function(any)
        if fn then fn(state) end
    end
end

function Registry:get(archetype: tecs.Archetype): any
    return self.states[archetype]
end

return archetype_registry
