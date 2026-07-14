# Tecs ECS: components, systems, queries

Entities, typed components, and systems that run each frame over queries — the core model. `require("tecs")`.

## Spawning and mutating entities

```teal
local id = world:spawn(Transform(0, 0), gfx.Circle(4))  -- returns entity id
world:set(id, gfx.Color(1, 0, 0, 1))                     -- add / replace a component
world:remove(id, gfx.Color)
world:despawn(id)
local t = world:get(id, Transform)                       -- read (no dirty mark)
local tm = world:getMut(id, Transform)                   -- read + mark dirty before writing
if world:has(id, gfx.Color) then ... end
```

## Systems

```teal
world:addSystem({
    name = "Movement",              -- required; tooling/profiles key on it
    phase = tecs.phases.Update,     -- pick the right phase
    run = function(dt: number, world: tecs.World)
        -- ...
    end,
    runIf = tecs.runif.someGate,    -- optional; prefer over early-returns for state gates
})
```

Phases run in this order each frame: `First`, `PreUpdate`, `FixedUpdate` (fixed timestep, good for
physics/gameplay ticks), `Update`, `PostUpdate`, then render phases `PreRender`, `Render`,
`PostRender`, then `Last`. Startup phases (`PreStartup`/`Startup`/`PostStartup`) run once.
Do game logic in `Update`/`FixedUpdate`, never in render phases.

## Queries

Create queries **once in the plugin**, reuse them; never build a query inside `run`.

```teal
local moving = world:query({
    name = "Moving",
    include = {Transform, Velocity},   -- must have all
    exclude = {tecs.builtins.Paused},  -- must have none
    -- includeAny = {A, B},            -- must have at least one
})

world:addSystem({
    name = "Movement", phase = tecs.phases.Update,
    run = function(dt: number)
        for archetype, len, entities in moving:iter() do
            local transforms = archetype:getMut(Transform)   -- getMut: you will write
            local vels = archetype:get(Velocity)             -- get: read-only
            for row = 1, len do
                transforms[row].x = transforms[row].x + vels[row].x * dt
                -- entities[row] is the entity id
            end
        end
    end,
})
```

Bulk ops beat per-entity loops: `world:batchDespawn(query)`, `world:batchSet(query, Comp)`,
`world:batchRemove(query, Comp)`.

## Defining components

```teal
-- Table storage: fields may hold Lua tables/strings/objects, or when cold.
local record Velocity is tecs.Component
    x: number
    y: number
end
tecs.newComponent({ name = "Velocity", container = Velocity, fields = {"x", "y"} })

-- FFI storage: numeric/boolean data iterated densely (cache-friendly columns).
tecs.newFFIComponent({
    name = "Heat", container = Heat,
    fields = {{"value", "float"}}, defaults = {0},
})

-- Tag: no data; queries match archetypes directly. Great for stable, queried flags.
local Dead = tecs.newTagComponent({ name = "Dead" })
world:spawn(Transform(0,0), Dead)   -- pass the tag container directly

-- Scalar: a single primitive column.
local Score = tecs.newScalarComponent({ name = "Score", kind = "number" })
```

Give every component a `name` matching its record name (queries, MCP, snapshots use it). Keep
components as data; behavior lives in systems.

## Resources and events

- Share globals via `world.resources[key]` keyed by `tecs.newKey()` — no Lua globals.
- React to lifecycle with `world:observe(address, Event, cb)` instead of polling.

See also: `tecs docs tecs-style`, `tecs docs tecs-gotchas`.
