---
description: "Per-archetype per-component dirty bits set by getMut and set, and the systems that read them"
outline: deep
---

# Dirty tracking

Tecs tracks dirty state per archetype and component. One mark means that some
row in the column may have changed. It does not track individual rows.

Incremental consumers such as text layout and hierarchy composition use that signal to skip unchanged
columns. A write that Tecs cannot see leaves those consumers with stale data.

## Declare write intent

Read through `get` and write through `getMut`:

```nupp
for archetype, length in movers:iter() do
    local transforms =
        assert(archetype:getMut(tecs.ecs.Transform2D))
    local velocities = assert(archetype:get(Velocity))
    for row = 1, length as integer do
        local transform = transforms[row]
        local velocity = velocities[row]

        transform.x = transform.x + velocity.x * dt
        transform.y = transform.y + velocity.y * dt
    end
end
```

`getMut` marks the entire component column dirty before returning it. Never
call it speculatively in a loop that might not write.

For a conditional write, read first and mark only when the condition succeeds:

```nupp
local transforms = assert(archetype:get(tecs.ecs.Transform2D))
local changed = false

for row = 1, length as integer do
    if needsCorrection(transforms[row]) then
        correct(transforms[row])
        changed = true
    end
end

if changed then
    archetype:markComponentDirty(tecs.ecs.Transform2D)
end
```

A value read does not declare write intent. A field assignment through
`world:get` or `archetype:get` changes memory without marking it. Prefer
`getMut`; otherwise call `world:markComponentDirty` or the archetype marker
after the write.

## Automatic marks

These paths maintain dirty state:

- `getMut` and `world:set`
- spawn placement
- movement into another archetype
- swap-pop after removal

Spawn and structural movement mark every component on the archetype, because a
row moving in has every column newly written at that row.

Each changed column is marked on its archetype.

`world:update` clears marks after the pipeline runs. A consumer must inspect the columns it reads before those marks clear.

## Retained rendering

The renderer also keeps monotonic write counters, as the original engine did.
Those counters survive the end-of-frame dirty clear. Unchanged renderable
archetype runs keep their packed instances and GPU buffers; a changed run
rewrites and uploads its affected range. Structural changes that move packed
runs rebuild the layout. `getMut`, `set` and explicit dirty marks therefore
reach the next render even when extraction skipped a frame.

Camera movement updates the view and culling while world-space instance data
stays resident. Screen-space geometry and fixed-step interpolation also track
the view and interpolation fraction that affect their presented positions.
