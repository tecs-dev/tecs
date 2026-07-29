---
url: /ecs/components/dirty-tracking.md
description: >-
  Per-archetype per-component dirty bits set by getMut and set, and the
  extractor that reads them
---

# Dirty Tracking

Tecs tracks dirty state per archetype, per component. A column whose bytes may have changed since the last
frame is *dirty*, and that bit is the signal an incremental consumer uses to decide what to re-process. The
model is deliberately coarse: granularity stops at the archetype plus component level. There is no per-row
dirty bit.

If you need a refresher on how component values are created and replaced, start with
[Component Construction](/ecs/components/construction). For the component categories this page mentions in
passing, see the [Components overview](/ecs/components/). The [mutation model](/ecs/mutation-model) is the
normative specification of which paths mark what; this page is the reader's side of it.

## Who reads the bits

The extractor, the world-facing half of rendering, is the consumer that makes this model matter. Once per
frame it walks the archetypes holding renderable entities and, for each one, asks whether any of `Transform`,
`Tint`, `Sprite`, `Material`, `Clip` or the sprite sheet's `Pivot` is dirty. Only when one of them is (or when
the archetype's rows moved within the instance buffer, or an interpolated entity's blend factor changed) does
it rewrite that archetype's run of GPU instances.

That gate is what makes a large world affordable: most frames change very little, and an archetype nothing
touched costs a handful of bit tests instead of a rewrite of every row it holds. It also sets the contract in
the other direction. A write the framework cannot see is a write the extractor will not notice, and the
entity keeps drawing where it used to be.

## What sets a dirty bit

A component is marked dirty on its archetype when:

* **`archetype:getMut(Foo)`** is called, inside a query iteration or anywhere else with an archetype handle.
  This is the primary signal: fetching the column for write declares mutation intent. It is idempotent, so N
  writes behind one `getMut` collapse to one mark.
* **`world:getMut(entity, Foo)`** is the per-entity equivalent. Use it whenever you would otherwise write
  `local t = world:get(...)` and then mutate `t`.
* **`world:set(entity, Foo(...))`** writes a value, including the three-argument scalar form
  `world:set(entity, Foo, value)`.
* **`archetype:set(row, Foo(...))`** replaces a single row's value.
* **`world:markComponentDirty(entity, Foo)`** is called explicitly.
* **Spawn, archetype move-in, and swap-pop**: every component on the affected archetype is flagged in one bulk
  operation, because every column has new bytes for at least one row.

Bits are cleared at the end of each `world:update`, after the pipeline has run.

::: warning A `get` plus a cdata write is invisible
`world:get` on an FFI component hands back a cdata reference. Writing through it changes the bytes without any
assignment the framework can observe, so nothing is marked and the GPU never re-syncs. Either fetch with
`world:getMut`, or call `world:markComponentDirty(id, Component)` after the write.
:::

## Reading and writing columns

Two access primitives, distinguished by intent:

* **`archetype:get(Foo)`**: returns the column (or `nil` if the archetype doesn't carry `Foo`). Does not mark
  dirty.
* **`archetype:getMut(Foo)`**: same return; also marks `Foo` dirty on the archetype.

Use `:get` at read sites and `:getMut` at every site you intend to write into the column, whether the write
goes through table assignment or an FFI cdata field. The dirty machinery cannot observe the write itself; the
`:getMut` call is the contract that tells consumers "this column may have changed".

```teal
for archetype, len in query:iter() do
    local transforms = archetype:getMut(Transform)
    local velocities = archetype:get(Velocity)  -- read-only
    for row = 1, len do
        local t = transforms[row]
        local v = velocities[row]
        t.x = t.x + v.vx * dt
        t.y = t.y + v.vy * dt
    end
end
```

Both `:get` and `:getMut` return the same underlying column, so mixing them in one loop is safe; only the
dirty marks differ.

::: danger Don't `getMut` speculatively
Never call `getMut` at the top of a loop that might not write. It marks the whole column dirty on that
archetype, which defeats every dirty-gated consumer downstream: the extractor will rewrite every row of that
archetype, every frame, for nothing. If the write is conditional, hoist the condition, or bind with `:get` and
switch to `:getMut` on the branch that writes.
:::

## Checking dirty state

* **`archetype:isComponentDirty(Foo)`**: true when `Foo` was marked dirty on this archetype since the last
  frame. False when the archetype doesn't carry `Foo` at all.
* **`archetype:anyComponentDirty()`**: true when any component on this archetype is currently dirty. Useful
  for bulk re-sync paths that don't need per-component granularity.
* **`archetype:dirtyComponents()`**: an iterator over the components currently dirty on one archetype.
* **`world:dirtyArchetypes()`**: an iterator over the archetypes with at least one component dirty. The same
  rule as query iteration applies: do not mutate the world while iterating.

```teal
for archetype in world:dirtyArchetypes() do
    if archetype:isComponentDirty(Tint) then
        -- The Tint column was rewritten this frame.
    end
end
```

## Explicit marking

When a write happens through a path the framework can't see, call the marker directly:

* **`archetype:markComponentDirty(Foo)`**: a single component. A no-op if the archetype doesn't carry it.
* **`archetype:markAllComponentsDirty()`**: every component on the archetype. This is what spawn, move-in and
  swap-pop use.
* **`world:markComponentDirty(entity, Foo)`**: the entity-shaped wrapper, for when you only have the id.

`archetype:set(row, value)` and the `world:set` family all mark internally; you only need the explicit form
when you bypass them.

## Lifecycle

Bits are set at write time and cleared by `world:update` after the pipeline runs. The world keeps the set of
archetypes that were marked, so the cost of clearing is proportional to the archetypes that actually changed,
not to the total archetype count.

Newly spawned entities, and entities that move between archetypes, are automatically dirty for every component
on the destination archetype. Removing an entity marks the source archetype too, because a swap-pop rewrites
the bytes of the row it filled.

::: warning batchSpawn writes rows itself
`world:batchSpawn` claims a row range and hands it to your callback rather than running each component's
constructor, so FFI `defaults` are not applied to those rows. Set every field in the callback; the placement
itself has already marked the destination archetype's columns dirty.
:::
