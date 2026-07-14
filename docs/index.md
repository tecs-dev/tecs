---
description: "Tecs framework home overview of the typed LuaJIT ECS and GPU-driven Tecs2D engine with AI tooling"
# https://vitepress.dev/reference/default-theme-home-page
layout: home

hero:
  name: "Build 2D games with LuaJIT"
  text: "Typed. GPU-driven. Designed for humans and AI."
  image:
    src: /images/tecs.png
    alt: Tecs
  actions:
    - theme: brand
      text: Learn Tecs
      link: /tecs/
    - theme: brand
      text: Learn Tecs2D
      link: /tecs2d/

features:
  - title: Build with AI
    details: A <a href="/tecs2d/debug">runtime debugger</a> and <a href="/tecs2d/mcp/">built-in MCP server</a> lets humans and agents inspect, freeze, rewind, diff, edit, and replay a running game.
    icon: 🤖
  - title: ECS built for LuaJIT
    details: Tecs is a fast, <a href="/tecs/">archetype-based ECS</a> with easy to create LuaJIT FFI components, handling 4M entities at 200 FPS.<sup>[1]</sup>
    icon: ⚡
  - title: "LÖVE2D on the GPU"
    details: Tecs2D provides GPU-driven culling, cameras, materials, lighting, and <a href="https://www.love2d.org/wiki/12.0">indirect rendering</a> for absurd on-screen scale.
    icon:
      src: /images/love2d-logo.svg
  - title: Static typing
    details: Catch errors at compile time, not runtime. Tecs is designed from the ground up for static typing with <a href="https://github.com/teal-language/tl"><u>Teal</u></a>.
    icon:
      src: /images/teal.svg
---
<small><sup>[1]</sup> On an M1 Mac Mini, running `make example-shape-bench SHAPE=rectangle ENTITIES=4000000`</small>

## Install Tecs CLI

The Tecs CLI includes the compiler, engine sources, type definitions, and
project template. It downloads LÖVE 12 on first use, so you do not need to
install Lua, LuaRocks, Teal, or a C compiler.

::: code-group

```bash [macOS]
brew install tecs-dev/tap/tecs-cli
```

```powershell [Windows]
scoop bucket add tecs https://github.com/tecs-dev/scoop-bucket
scoop install tecs
```

```bash [Linux]
brew install tecs-dev/tap/tecs-cli
```

:::

Prefer a standalone installer? Use the scripts from
[tecs-cli releases](https://github.com/tecs-dev/tecs-cli/releases/latest):
`install.sh` (macOS/Linux) or `install.ps1` (Windows).

Create and run a game:

```bash
tecs new my-game
cd my-game
tecs run
```

## Example code

::: code-group

```teal [Basics]
local tecs = require("tecs")
local world = tecs.newWorld()

-- Define typed components with Teal
local record Position is tecs.Component
    x: number
    y: number
    metamethod __call: function(self, x?: number, y?: number): Position
end

tecs.newFFIComponent({
    name = "Position",
    container = Position,
    fields = {{"x", "float"}, {"y", "float"}},
})

local record Velocity is tecs.Component
    x: number
    y: number
    metamethod __call: function(self, x?: number, y?: number): Velocity
end

tecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {{"x", "float"}, {"y", "float"}},
})

-- Query and update entities
local query = world:query({include = {Position, Velocity}})

world:addSystem({
    phase = tecs.phases.Update,
    run = function(dt: number, _world: tecs.World)
        for archetype, len in query:iter() do
            local positions = archetype:getMut(Position)
            local velocities = archetype:get(Velocity)
            for row = 1, len do
                positions[row].x = positions[row].x + velocities[row].x * dt
            end
        end
    end
})

world:spawn(Position(100, 100), Velocity(10, 0))
```

```teal [Relationships]
local tecs = require("tecs")
local world = tecs.newWorld()
local ChildOf = tecs.builtins.ChildOf

-- Create a parent entity
local parent: integer = world:spawn(
    tecs.builtins.Name("parent"),
    tecs.builtins.Transform(100, 100)
)

-- RelativeTransform auto-adds Transform if missing.
-- ChildOf has cascadeDelete; despawning parent despawns children too.
local child1: integer = world:spawn(
    ChildOf(parent),
    tecs.builtins.RelativeTransform(20, 0)
)

local child2: integer = world:spawn(
    ChildOf(parent),
    tecs.builtins.RelativeTransform(-20, 0)
)

-- Walk children of a specific parent (sparse relationships use world:targets)
world:targets(parent, ChildOf, function(childId: integer)
    print("child:", childId)
end)

-- Despawning parent cascades to child1 and child2
world:despawn(parent)
```

```teal [Events]
local tecs = require("tecs")
local world = tecs.newWorld()

-- Define a custom event
local record DamageEvent is tecs.Event
    target: integer
    amount: number
    metamethod __call: function(self, target: integer, amount: number): DamageEvent
end

-- Wire up the event init hook (it mutates a pre-allocated instance)
DamageEvent.init = function(e: DamageEvent, target: integer, amount: number)
    e.target = target
    e.amount = amount
end
tecs.newEvent(DamageEvent)

-- Observe events anywhere in your game (0 = world-level)
world:observe(0, DamageEvent, function(e: DamageEvent)
    local health: Health = world:get(e.target, Health)
    if health then
        health.current = health.current - e.amount
        if health.current <= 0 then
            world:despawn(e.target)
        end
    end
end)

-- Emit events from systems
world:emit(0, DamageEvent, enemyId, 25)
```

```teal [LÖVE2D]
-- main.tl
local tecs = require("tecs")
local tecs2d = require("tecs2d")

love.run = tecs2d.run({
    fps = 60,
    game = function(world: tecs.World)
        local query: tecs.Query = world:query({include = {Position, Sprite}})

        world:addSystem({
            phase = tecs.phases.Render,
            run = function(_dt: number, _world: tecs.World)
                for arch, len in query:iter() do
                    local positions = arch:get(Position)
                    local sprites = arch:get(Sprite)
                    for row = 1, len do
                        love.graphics.draw(
                            sprites[row].texture,
                            positions[row].x,
                            positions[row].y
                        )
                    end
                end
            end
        })

    end,
    quitOnEscape = true,
})
```

```teal [Camera]
local tecs2d = require("tecs2d")
local gfx = require("tecs2d.gfx")

-- Pixel-perfect camera with smooth movement
love.run = tecs2d.run({
    fps = 60,
    game = function(world: tecs.World)
        local pipeline = world.resources[gfx.PIPELINE]
        local cam = pipeline:getCamera()

        -- Smooth camera follow and zoom
        cam:move(player.x, player.y)
        cam:setZoom(0.8)

        -- Convert mouse to world coordinates
        local worldX, worldY = cam:toWorld(love.mouse.getPosition())

        -- Check if entity is on screen
        if cam:isVisible(enemy.x, enemy.y, 32, 32) then
            enemy:update()
        end
    end,
    render = {
        virtualHeight = 180,
        pixelMode = true,
        lerpSpeed = 8.0,
    },
})
```

```teal [Aseprite]
local tecs = require("tecs")
local gfx = require("tecs2d.gfx")
local assets = require("tecs2d.assets")

-- Load Aseprite sprite sheet (.png + .json) via asset manager
local manager = world.resources[assets]
local sheetHandle = manager:loadSpriteSheet("player.png")

-- Spawn animated entity (.value blocks until loaded)
local entity = world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Sprite.fromSheet(sheetHandle.value, "idle", { speed = 1.0 })
)

-- Change animation based on state
local sprite = world:get(entity, gfx.Sprite)
sprite:setTag("run")
sprite:setTag("jump")

-- React when animation changes
world:observe(entity, gfx.ChangeTag, function(e: gfx.ChangeTag)
    if e.newTag == "jump" then
        print("sprite entered jump animation")
    end
end)
```

```teal [Controller]
local tecs2d = require("tecs2d")
local controller = require("tecs2d.controller")

-- Rebindable controls with keyboard + gamepad
local bindings = {
    controls = {
        jump = {"key:space", "button:a"},
        attack = {"key:z", "button:x"},
        left = {"key:a", "axis:leftx-"},
        right = {"key:d", "axis:leftx+"},
        up = {"key:w", "axis:lefty-"},
        down = {"key:s", "axis:lefty+"}
    },
    pairs = {
        move = {"left", "right", "up", "down"}
    }
}

-- Access the controller manager from world resources
local manager = world.resources[controller]

-- Auto-detects keyboard or gamepad
local player1 = manager:addController(bindings, {auto = true})

-- Unified input across devices
if player1:isPressed("jump") then
    -- handle jump
end

-- Analog movement from keyboard or stick
local moveX, moveY = player1:getPair("move")
velocity.x = moveX * speed
```

```teal [Tweens]
local tween = require("tecs2d.tween")

-- Simple move
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :once()
    :apply(world, entity)

-- Sequence with a serializable named event
tween.timeline()
    :channel("movement")
    :to(0.5, tween.quadOut, tween.translateXY, 200, 100)
    :emit("whoosh")
    :to(0.3, tween.linear, tween.color, 1, 0, 0, 1)
    :once()
    :apply(world, entity)

world:observe(0, tween.TweenEvent, function(ev)
    if ev.name == "whoosh" then
        playSound("whoosh")
    end
end)

-- Reusable timeline with stagger
local pulse = tween.timeline()
    :to(0.8, tween.sineInOut, tween.scaleXY, 1.5, 1.5)
    :pingPong()

for i = 0, 4 do
    pulse:apply(world, buttons[i + 1], 1, i * 0.1)
end
```

:::

## Features

<div class="feature-grid">
<div class="feature-group">

**Core ECS**

- [World](/tecs/world) - central hub for entities, systems, resources
- [Components](/tecs/components/) - data containers with FFI support
- [Systems](/tecs/systems) - update logic with phase ordering
- [Queries](/tecs/queries/) - filter entities by composition
- [Events](/tecs/events) - type-safe pub/sub messaging
- [Relationships](/tecs/relationships/) - entity-to-entity links
- [Plugins](/tecs/plugins) - modular, shareable game mechanics
- [Bundles](/tecs/components/bundles) - reusable entity templates
- [States](/tecs/states) - trackable state machines

**Game Systems**

- [Physics](/tecs2d/physics/) - Box2D integration with collision events
- [Tweens](/tecs2d/tween) - timeline animation with easing, channels, tracking
- [Audio](/tecs2d/audio/) - spatial sound, groups, voice limiting
- [Controllers](/tecs2d/input/controller/) - rebindable keyboard and gamepad
- [UI layout](/tecs2d/rendering/ui/) - boxes, nodes, scrolling, auto-sizing
- [Assets](/tecs2d/assets/) - async loading with thread pool

</div>
<div class="feature-group">

**Rendering**

- [Render pipeline](/tecs2d/rendering/) - GPU-driven rendering
- [Camera](/tecs2d/rendering/camera) - pixel-perfect with smooth following
- [Sprites](/tecs2d/rendering/sprites/) - texture rendering with quads
- [Shapes](/tecs2d/rendering/shapes) - circles, ellipses, rectangles, arcs, lines
- [Text](/tecs2d/rendering/text) - bitmap and MSDF fonts with GPU instancing
- [Particles](/tecs2d/rendering/particles) - Love2D particle systems
- [Layers](/tecs2d/rendering/layers) - z-ordering and layer decorators
- [Lighting](/tecs2d/rendering/lighting) - dynamic lights and shadows
- [Materials](/tecs2d/rendering/materials) - per-entity GPU shader effects
- [Styling](/tecs2d/rendering/styling) - tinting and blend modes

**Integrations**

- [LÖVE2D](/tecs2d/) - game loop, input, graphics, physics, audio
- [Aseprite](/tecs2d/rendering/sprites/) - animation, tags, slices, collision boxes
- [Tiled](/tecs2d/tiled/) - tilemaps, object spawning, automatic material maps
- [MCP server](/tecs2d/mcp/) - AI control, queries, screenshots, hot reload
- [JSON](/tecs/utils/json) - high-performance LuaJIT parser
</div>
</div>

<style>
.feature-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 0 3rem;
  margin-top: 1.5rem;
}

.feature-group strong {
  display: block;
  margin: 1.5rem 0 0.5rem;
  font-size: 1.1rem;
}

.feature-group strong:first-child {
  margin-top: 0;
}

.feature-group ul {
  margin: 0;
  padding-left: 1.25rem;
}

.feature-group li {
  margin: 0.25rem 0;
  line-height: 1.5;
}

@media (max-width: 640px) {
  .feature-grid {
    grid-template-columns: 1fr;
  }
}
</style>
