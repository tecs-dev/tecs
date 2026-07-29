---
description: "Per-archetype per-component dirty bits set by getMut and set, and the extractor that reads them"
outline: deep
---

# Dirty tracking

Tecs tracks dirty state per archetype and component. One mark means that some
row in the column may have changed. It does not track individual rows.

Rendering and other incremental consumers use that signal to skip unchanged
columns. A write that Tecs cannot see leaves those consumers with stale data.

## Declare write intent

Read through `get` and write through `getMut`:

```teal
for archetype, length in movers:iter() do
    local transforms <const> =
        archetype:getMut(tecs.Transform)
    local velocities <const> = archetype:get(Velocity)

    for row = 1, length do
        local transform <const> = transforms[row]
        local velocity <const> = velocities[row]

        transform.x = transform.x + velocity.x * dt
        transform.y = transform.y + velocity.y * dt
    end
end
```

`getMut` marks the entire component column dirty before returning it. Never
call it speculatively in a loop that might not write.

For a conditional write, read first and mark only when the condition succeeds:

```teal
local transforms <const> = archetype:get(tecs.Transform)
local changed = false

for row = 1, length do
    if needsCorrection(transforms[row]) then
        correct(transforms[row])
        changed = true
    end
end

if changed then
    archetype:markComponentDirty(tecs.Transform)
end
```

LuaJIT cannot enforce read-only cdata. A field assignment through
`world:get` or `archetype:get` changes memory without marking it. Prefer
`getMut`; otherwise call `world:markComponentDirty` or the archetype marker
after the write.

## Automatic marks

These paths maintain dirty state:

- `getMut`, `world:set`, and `archetype:set`
- spawn placement
- movement into another archetype
- swap-pop after removal

Spawn and structural movement mark every affected component because the
column layout changed.

`world:update` clears marks after the pipeline runs. A consumer can iterate
dirty archetypes, test one component, test any component, or iterate dirty
components. Do not structurally mutate the world while walking
`dirtyArchetypes`.

## Batch initialization

`batchSpawn` reserves rows and calls the fill callback without running
component constructors. FFI defaults do not run. Initialize every field the
batch will use:

```teal
world:batchSpawn(1000, {Position},
    function(archetype, firstRow, lastRow)
        local positions <const> =
            archetype:getMut(Position)

        for row = firstRow, lastRow do
            positions[row].x = 0
            positions[row].y = 0
        end
    end
)
```

Placement already marks the destination columns. The callback still uses
`getMut` to state its write intent clearly.

The [mutation model](/modules/ecs/mutation-model) defines the normative marking rules.
