---
# https://vitepress.dev/reference/default-theme-home-page
layout: home

hero:
  name: "Tecs"
  text: "Type-safe ECS for Lua with C-level speed"
  image:
    src: /images/desert-home.png
    alt: Tecs
  actions:
    - theme: brand
      text: Get started
      link: /guide/quickstart
    - theme: alt
      text: Reference
      link: /reference/world
    - theme: alt
      text: GitHub
      link: https://github.com/mtdowling/tecs

features:
  - title: Strongly typed
    details: Catch errors at compile time, not runtime. Designed from the ground-up for static typing with <a href="https://github.com/teal-language/tl"><u>Teal</u></a>.
    icon:
      src: /images/teal.svg
  - title: Lightning fast ECS
    details: Tecs is a lightning fast, archetype-based ECS with easy to create FFI components that can handle 4M+ entities at 60 FPS.
    icon: ⚡
  - title: Plugin system
    details: Share and reuse game mechanics across projects. Package systems, components, and resources into self-contained modules.
    icon: 🧩
  - title: Events
    details: Decouple your systems with type-safe events. React to entity lifecycle, state changes, and custom game events.
    icon: 📨
  - title: LuaJIT & Lua 5.1+
    details: Get max performance with LuaJIT and FFI, and seamless compatibility with Lua 5.1+. Same API, no code changes required.
    icon: 🔁
  - title: State machines
    details: Built-in state management for game flow. Conditionally run systems, react to transitions, and organize complex game logic.
    icon: 🕹️
  - title: "LÖVE2D bindings"
    details: Tecs2D integrates Tecs with Love2D. Manages the game loop, input handling, controller bindings, events, and async asset loading.
    icon: ❤️
  - title: Batteries included
    details: Tecs has a render pipeline, pixel-perfect camera, & lighting engine; rebindable controllers; async asset loading, and more.
    icon: 🔋

---

## Example code

```lua
local tecs = require("tecs")

local world = tecs.newWorld()

-- Define typed component records with Teal
local record Position is tecs.Component
    x: number
    y: number
end

local record Velocity is tecs.Component
    x: number
    y: number
end

-- Easily create FFI components for C-like speed and memory
tecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    recycle = true,
    fields = {
        {"x", "float"},
        {"y", "float"}
    }
})

tecs.newFFIComponent({
    name = "Position",
    container = Position,
    recycle = true,
    fields = {
        {"x", "float"},
        {"y", "float"}
    }
})

-- Queries find entities with specific components
local query = world:query({include = {Position, Velocity}})

-- Systems can update entities
world:addSystem({
    phase = tecs.phases.Update,
    run = function(dt: number)
        for archetype, len, entities in query() do
            local positions = archetype[Position]
            local velocities = archetype[Velocity]
            for row = 1, len do
                local id = entities[row]
                local pos = positions[row]
                local vel = velocities[row]
                pos.x = pos.x + vel.x * dt
                pos.y = pos.y + vel.y * dt
            end
        end
    end
})

world:spawn(
    Position(100, 100),
    Velocity(10, 0),
    tecs.builtins.Name("player")
)
```

## Get Started

Ready to build your next game with Tecs?

<div class="vp-doc" style="display: flex; gap: 1rem; margin-top: 2rem;">
  <a href="/guide/quickstart" class="vp-doc" style="display: inline-block; padding: 0.5rem 1.5rem; background: var(--vp-button-brand-bg); color: var(--vp-button-brand-text); border-radius: 8px; text-decoration: none; font-weight: 500;">
    Get Started →
  </a>
  <a href="/guide/love2d-quickstart" class="vp-doc" style="display: inline-block; padding: 0.5rem 1.5rem; background: var(--vp-button-alt-bg); color: var(--vp-button-alt-text); border: 1px solid var(--vp-button-alt-border); border-radius: 8px; text-decoration: none; font-weight: 500;">
    LÖVE2D Quickstart
  </a>
</div>