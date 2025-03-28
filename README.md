# Tecs

A type-safe ECS for Lua with C-level speed.

Full documentation is available at https://tecs.dev.

## Features

* 📝 **Strongly typed**: Catch errors at compile time, not runtime. Designed from the ground-up for typing with
  [Teal](https://github.com/teal-language/tl).
* ⚡ **Lightning fast ECS**: Fast, archetype-based ECS with FFI components that can handle 4M+ entities at 60 FPS.
* 🧩 **Plugin system**: Share and reuse game mechanics across projects.
* 📨 **Events**: Decouple systems with type-safe events. React to spawn, despawn, state changes, and custom events.
* 🔁 **LuaJIT & Lua 5.1+**: Max performance with LuaJIT and FFI, and seamless fallback compatibility with Lua 5.1+.
* 🕹️ **State machines**: Built-in state management for game flow.
* ❤️ **LÖVE2D bindings**: Tecs2D integrates Tecs with Love2D: game loop, input handling, and Tecs events.
* 🔋 **Batteries included**: Tecs has a render pipeline, pixel-perfect camera, & lighting engine; rebindable
  controllers; async asset loading, and more.

## Installation

Requirements:

* Lua 5.1+ or LuaJIT with FFI support
* [Teal](https://github.com/teal-language/tl) for using Tecs and writing code
* Love2D if using Tecs2D

```bash
luarocks install --tree=src/vendor tecs.tl

# Optional components
luarocks install --tree=src/vendor tecs2d.tl
luarocks install --tree=src/vendor tecs_render.tl
luarocks install --tree=src/vendor tecs_controller.tl
luarocks install --tree=src/vendor tecs_assets.tl
```

## Basic Example

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
        for archetype, len in query() do
            local positions = archetype[Position]
            local velocities = archetype[Velocity]
            for row = 1, len do
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

## Performance

- **FFI components**: Zero-overhead C-style structs with seamless Lua table fallback when FFI unavailable
- **Struct-of-arrays (SoA)**: Component data laid out for optimal access and cache locality
- **Archetype storage**: Entities stored in contiguous arrays by component signature for cache-friendly iteration
- **Bulk operations**: Zero-copy batch commits, bulk clears, and efficient memory transfers
- **Arena allocation**: Page-based FFI memory management eliminates per-component allocations
- **Object pooling**: Table recycling and component reuse reduce garbage collection pressure
- **Deferred transactions**: All mutations staged during frame, then committed in bulk for maximum throughput
- **Query caching**: Archetype matching cached and incrementally updated as entities change
- **Staging archetypes**: New entities batched by component signature before promotion to permanent storage

## Contributing

Contributions are welcome!

1. Write tests for new functionality using Teal and busted
2. Follow the existing code style (4 spaces)
3. Update documentation as needed (Tealdoc comments and Vitepress docs)
4. Run `make test` before submitting to ensure build works

See [CLAUDE.md](CLAUDE.md) for detailed development guidelines.

## Testing

Tecs is thoroughly unit tested with Busted and Teal.

```bash
make -j test

# Run with verbose output
make test VERBOSE=1
```

## License

MIT License. See [LICENSE](LICENSE) file for details.
