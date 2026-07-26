---
description: "The gfx.ChangeTag and gfx.AnimationComplete events, their properties, and observer lifetime caveats"
---

# Animation Events

Sprites emit `gfx.ChangeTag` when their animation tag changes, and `gfx.AnimationComplete` when a
`playOnce` animation reaches its last frame.

## Available Events

| Event                   | Address | When It Fires                                 |
| ----------------------- | ------- | --------------------------------------------- |
| `gfx.ChangeTag`         | entity  | The animation tag changes via `setTag()`      |
| `gfx.AnimationComplete` | 0       | A `playOnce` animation reaches its last frame |

## AnimationComplete Event

`playOnce` reports completion as an event rather than a callback, because a correlation that is
data survives a snapshot and a closure does not.

| Property | Type    | Description                        |
| -------- | ------- | ---------------------------------- |
| `entity` | integer | The entity whose animation ended   |
| `tag`    | string  | The tag that finished playing      |

```teal
world:observe(0, gfx.AnimationComplete, function(e)
    if e.tag == "death" then despawnLater(e.entity) end
end)
```

It is emitted at address 0, so an observer rebound by name after a snapshot load hears about an
animation that was still playing when the save was written. See
[Animation](./animation#reacting-to-the-end).

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
