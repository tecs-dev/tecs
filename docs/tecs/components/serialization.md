---
outline: deep
---

# Component Serialization

Components can be serialized and deserialized, enabling [save games](/tecs/save-games), networking, and AI
integration via the [MCP server](/tecs2d/mcp/). Tecs handles most components automatically; you only provide
custom `serialize`/`deserialize` functions when a component holds state that can't survive a round-trip on its
own (Love2D handles, slab pointers, computed fields, etc.).

If the constructor terminology here feels too implicit, read
[Component Construction](/tecs/components/construction) first. For backend-specific behavior, compare
[table components](/tecs/components/table-components),
[FFI components](/tecs/components/ffi),
[scalar components](/tecs/components/scalar-components), and
[tag components](/tecs/components/tag-components).

## Automatic serialization

Most components work automatically without any configuration.

**Table components** serialize all user-defined fields by default, excluding framework metadata. The deserializer
routes the data table through `Component.new(data)`, which means any component that registers cleanly (`fields`
alone, or `init` paired with `fields`/`new`) round-trips automatically.

```lua
-- This component serializes automatically. Its .new unpacks both fields.
tecs.newComponent({
    name = "Health",
    container = Health,
    fields = {"hp", "maxHp"},
})

-- Serializes to:   {hp = 100, maxHp = 100}
-- Deserializes as: Health.new({hp = 100, maxHp = 100})
```

**FFI components** serialize via their field schema: every declared field is written as raw bytes on save and
memcpy'd back on load. There's nothing to configure; the framework reads the fields you declared.

If you are deciding between these two storage backends in the first place, see
[Table Components](/tecs/components/table-components) and [FFI Components](/tecs/components/ffi).

```lua
tecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {
        {"x", "float"},
        {"y", "float"}
    }
})

-- Serializes to: {x = 5.0, y = 10.0}  (table format)
-- Or memcpy'd as 8 bytes per entity in the binary snapshot.
```

## Custom serialization

For components whose runtime state doesn't round-trip naturally (Love2D textures, GPU handles, cached slab pointers,
derived fields, etc.), provide `serialize` and `deserialize` hooks.

```lua
tecs.newComponent({
    name = "Sprite",
    container = Sprite,
    fields = {"path"},
    init = function(instance: Sprite, path: string)
        instance.path = path
        instance.texture = love.graphics.newImage(path)
    end,
    serialize = function(sprite: Sprite): {string: any}
        -- Save only the path, not the GPU texture.
        return { path = sprite.path }
    end,
    deserialize = function(world: tecs.World, data: {string: any}): Sprite
        -- Reconstruct by reloading the texture through the constructor.
        return Sprite(data.path as string)
    end,
})
```

`deserialize` receives the world so it can call helpers, resolve relationship targets, or spawn side entities while
reconstructing.

### When custom serialization is needed

- **Love2D objects**: textures, fonts, sounds can't be serialized directly
- **GPU / FFI handles**: slab pointers, buffer offsets that only make sense in the current process
- **Circular references**: break cycles by storing IDs instead of references
- **Computed fields**: skip derived values that can be recalculated from other state
- **Version migration**: reshape old payloads into the new record shape on load
- **Large payloads**: compress, or store references to external files

## Skipping a component from snapshots

Return `nil` from `serialize` to omit the component from every snapshot. This is the idiomatic way to mark transient
runtime state (render caches, per-frame scratch, derived indices):

```lua
tecs.newComponent({
    name = "RenderCache",
    container = RenderCache,
    serialize = function(_inst: RenderCache): {string: any} return nil end,
})
```

The framework doesn't write the component value and doesn't try to reconstruct it on load; the entity still gets
restored, just without this particular component.

## Schema fingerprinting & migration

Every FFI component carries a canonical schema fingerprint of the form `field1:type1,field2:type2,...|sizeBytes`. The
save embeds each component's fingerprint in the snapshot prelude; on load the framework compares it against the
current registration.

- **Match** → the bulk memcpy fast path runs (one `memcpy` per column).
- **Mismatch** → the load errors. Per-entity schema migration is a future addition; today you need to either bump your
  game's own save version and translate offline, or switch the component to a custom `serialize` / `deserialize` pair
  (which opts out of the bulk path and lets you reshape the data yourself).

Non-FFI components aren't fingerprinted; they round-trip through their declared `serialize` / `deserialize` every time.
That includes ordinary [table components](/tecs/components/table-components),
[scalar components](/tecs/components/scalar-components), and
[tag components](/tecs/components/tag-components).

## Performance implications

| Path                                      | Cost per entity | When it runs                                                              |
| ----------------------------------------- | --------------- | ------------------------------------------------------------------------- |
| Bulk FFI memcpy                           | ~zero           | FFI component, no custom `serialize`, schema matches on load, binary format. |
| Per-entity structured codec               | small           | FFI component with custom `serialize`, OR non-FFI table component.        |
| Row-major fallback (sparse relationships) | moderate        | Archetype contains a sparse container component.                          |

Custom `serialize` opts the component out of the bulk path **even if** it's FFI-backed. The framework treats your
override as a signal that raw memcpy wouldn't round-trip the runtime state correctly. That's usually the right call
(e.g. `gfx.Text` holds non-portable glyph slab pointers), but it's worth knowing: a hot path of 100K FFI entities
saves ~500× faster on the bulk path than the per-entity path.

## Serialization in component options

| Property      | Description                                                                 |
| ------------- | --------------------------------------------------------------------------- |
| `serialize`   | `function(instance: Component): {string: any}`. Convert a component to a plain table. Return `nil` to omit the component from the snapshot entirely. |
| `deserialize` | `function(world: tecs.World, data: {string: any}): Component`. Reconstruct a component from a plain table. Receives the world for cross-entity lookups. Defaults to `Component.new(data)`. |
| `new`         | `function(data: {string: any}): Component`. Table-form constructor invoked by `Component.new({...})` and the default deserialize. See [Component Construction](/tecs/components/construction#table-construction). |
