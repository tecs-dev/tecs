---
description: "The gfx.ChangeTag event fired on animation tag changes, its properties, and observer lifetime caveats"
---

# Animation Events

Sprites emit `gfx.ChangeTag` when their animation tag changes. Events are emitted to the entity's address in the
world's event system.

## Available Events

| Event           | When It Fires                                   |
| --------------- | ----------------------------------------------- |
| `gfx.ChangeTag` | When the animation tag changes via `setTag()`   |

## ChangeTag Event

`ChangeTag` fires when `setTag()` is called, including the initial tag set during spawn.

### Event Properties

| Property | Type    | Description                                  |
| -------- | ------- | -------------------------------------------- |
| `entity` | integer | The entity ID                                |
| `oldTag` | string  | Previous animation tag (empty on first load) |
| `newTag` | string  | New animation tag                            |
| `sprite` | Sprite  | Reference to the Sprite component            |

### Examples

```teal
world:observe(entityId, gfx.ChangeTag, function(event: gfx.ChangeTag)
    print("Entity", event.entity, "changed from", event.oldTag, "to", event.newTag)
end)
```

```teal
world:observe(entityId, gfx.ChangeTag, function(event: gfx.ChangeTag)
    if event.newTag == "death" then
        world:remove(entityId, PlayerController)
    end
end)
```

```teal
local sounds = {
    walk = love.audio.newSource("sounds/footsteps.ogg", "static"),
    attack = love.audio.newSource("sounds/sword.ogg", "static"),
}

world:observe(entityId, gfx.ChangeTag, function(event: gfx.ChangeTag)
    local sound = sounds[event.newTag]
    if sound then
        sound:stop()
        sound:play()
    end
end)
```

## Event Lifetimes

Direct constructors such as `gfx.ChangeTag(...)` allocate a fresh event instance. Internal sprite code uses
`world:emit(entityId, gfx.ChangeTag, ...)`, which reuses world-local storage and should be treated as callback-local. Do
not store references to event objects received from observers.

```teal
local lastTag = ""

world:observe(entityId, gfx.ChangeTag, function(event: gfx.ChangeTag)
    lastTag = event.newTag
end)
```
