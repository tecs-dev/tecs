---
outline: deep
---

# Dirty Tracking

Tecs tracks dirty state per archetype, per component. A column whose bytes
changed since the last frame is *dirty*; the dirty bit is the signal that
incremental-sync consumers (renderer shadow buffers, save snapshots, reactive
systems) use to decide which columns to re-upload. The model is
deliberately coarse: granularity stops at the archetype + component level.
There is no per-row dirty bitmap.

If you need a refresher on how component values are created and replaced,
start with [Component Construction](/tecs/components/construction). For
the higher-level component categories this page mentions in passing, see
the [Components overview](/tecs/components/).

## What sets a dirty bit

A component is marked dirty on its archetype when:

- **`archetype:getMut(Foo)`** is called inside a query iter (or
  anywhere else with an archetype handle). This is the primary signal:
  fetching the column for write declares mutation intent.
- **`world:getMut(entity, Foo)`** is the per-entity equivalent. Use it
  whenever you'd normally write `local t = world:get(...); t.x = ...`
  but intend to mutate the returned reference; `:get` followed by cdata
  writes silently bypasses the dirty signal.
- **`world:set(entity, Foo(...))`** writes a value, including the
  three-argument scalar form `world:set(entity, Foo, value)`.
- **`archetype:set(row, Foo(...))`** replaces a single row's value.
- **`world:markComponentDirty(entity, Foo)`** is called explicitly. Use
  this when a smart wrapper (e.g. a `Sprite` instance) mutates an
  entity's bytes through a fetched FFI cdata and there's no archetype
  in scope. Prefer `world:getMut` over `world:get` + this call.
- **Spawn / archetype move-in / swap-pop**: every component on the
  destination archetype is flagged dirty in one bulk operation, since
  every column has new bytes for at least one row.

Bits are cleared automatically at the end of each `world:update(...)`,
after every system has run.

## Reading and writing columns

Two access primitives, distinguished by intent:

- **`archetype:get(Foo)`** — returns the column reference (or nil if
  the archetype doesn't carry `Foo`). Does NOT mark dirty.
- **`archetype:getMut(Foo)`** — same return; also marks `Foo`
  dirty on the archetype. Idempotent.

Use `:get` for read sites and `:getMut` at every site you intend to
write into the column, regardless of whether the write goes through
table assignment, FFI cdata field writes, or anything else. The dirty
machinery cannot observe direct cdata writes; the `:getMut` call is
the contract that tells consumers "this column may have changed."

```lua
for archetype: tecs.Archetype, len: integer in query:iter() do
    local transforms = archetype:getMut(Transform)
    local velocities = archetype:get(Velocity)  -- read-only
    for row = 1, len do
        local t = transforms[row]
        local v = velocities[row]
        t.x = t.x + v.x * dt
        t.y = t.y + v.y * dt
    end
end
```

Both `:get` and `:getMut` return the same underlying column, so
mixing them in one loop is safe — only the dirty marks differ.

## Checking dirty state

- **`archetype:isComponentDirty(Foo)`** — true when `Foo` was marked
  dirty on this archetype since the last frame.
- **`archetype:anyComponentDirty()`** — true when any component on this
  archetype is currently dirty. Useful for bulk re-sync paths that
  don't need per-component granularity.
- **`world:dirtyArchetypes()`** — iterator over archetypes with at
  least one component dirty. Drains naturally at frame end.

```lua
for archetype in world:dirtyArchetypes() do
    if archetype:isComponentDirty(Color) then
        -- Color column was rewritten this frame.
    end
end
```

`archetype:dirtyComponents()` returns an iterator over the components
currently dirty on a single archetype.

## Explicit marking

When a write happens through a path the framework can't see, call the
explicit marker:

- **`archetype:markComponentDirty(Foo)`** — single component.
- **`archetype:markAllComponentsDirty()`** — every component on the
  archetype (used internally for spawn/move-in/swap-pop).
- **`world:markComponentDirty(entity, Foo)`** — entity-shaped wrapper
  for cases where you only have the entity id.

`archetype:set(row, value)` and the `world:set` family all mark
internally; you only need the explicit form when you bypass them.

## Lifecycle

Component-dirty bits are set at write time and cleared by `world:update`
after the pipeline runs. The world's `_dirtyArchetypes` set tracks
which archetypes need clearing each frame, so the cost of cleanup is
proportional to the archetypes that actually changed, not the total
archetype count.

Newly spawned entities or entities that transition between archetypes
are automatically considered dirty for every component on the
destination archetype.
