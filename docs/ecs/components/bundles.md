---
description: "Reusable entity templates with world:newBundle and spawnBundle"
outline: deep
---

# Component bundles

A bundle names one reusable component set:

```nupp
local playerBundle = world:newBundle("Player", {
    required = {tecs.ecs.Transform2D, Health},
    with = {
        [tecs.gfx.Tint] = function()
            return tecs.gfx.Tint(1, 1, 1, 1)
        end,
        [tecs.gfx.Renderable2D] = true,
    },
})

local player = playerBundle:spawn(
    tecs.ecs.Transform2D(100, 200),
    Health(100)
)
```

`required` sets the positional arguments to `spawn`. `with` creates the rest
for every entity.

## Required components

Declaration order controls spawn order:

```nupp
local enemyBundle = world:newBundle("Enemy", {
    required = {tecs.ecs.Transform2D, Health, Damage},
})

local enemy = enemyBundle:spawn(
    tecs.ecs.Transform2D(100, 200),
    Health(50),
    Damage(10)
)
```

Every argument must match its declared component. Move any value that varies
per spawn into `required`.

## Bundle defaults

Each `with` value must hold a factory or `true`. A factory runs once per spawn
and returns a fresh instance:

```nupp
local bulletBundle = world:newBundle("Bullet", {
    required = {tecs.ecs.Transform2D},
    with = {
        [Velocity] = function()
            return Velocity(100, 0)
        end,
        [Damage] = function()
            return Damage(25)
        end,
    },
})
```

`true` uses the component's default value. It suits tags and components
whose declared defaults already have the right value:

```nupp
local propBundle = world:newBundle("Prop", {
    required = {tecs.ecs.Transform2D},
    with = {
        [tecs.gfx.Renderable2D] = true,
        [Static] = true,
    },
})
```

A spawn cannot override a component from `with`. Put that component in
`required` when callers need to supply it.

The definition may name each component once across `required` and `with`.
Registration rejects duplicates, invalid `with` values, and duplicate bundle
names.

## Staged spawning

The bundle object and the world registry call the same spawn path:

```nupp
local first = playerBundle:spawn(
    tecs.ecs.Transform2D(0, 0),
    Health(100)
)

local second = world:spawnBundle(
    "Player",
    tecs.ecs.Transform2D(20, 0),
    Health(100)
)
```

Bundle spawns follow `world:spawn` timing. They reserve an ID immediately and
stage placement until the next pipeline barrier. The returned ID works
immediately for later staged operations:

```nupp
for _archetype, _length in query:iter() do
    local id = playerBundle:spawn(
        tecs.ecs.Transform2D(0, 0),
        Health(100)
    )
    world:set(id, Selected)
end
```

## Registry lookup

`world:getBundle(name)` returns one bundle or `nil`.
`world:getBundles()` returns a fresh name-to-bundle map, so changing the map
does not change the registry.
