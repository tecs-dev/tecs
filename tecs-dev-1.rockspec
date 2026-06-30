rockspec_format = "3.0"
package = "tecs"
version = "dev-1"

source = {
    url = "git+https://github.com/tecs-dev/tecs.git",
    branch = "main"
}

description = {
    summary = "Typed, high-performance ECS framework for LuaJIT",
    detailed = [[
Tecs is a high-performance Entity Component System (ECS) framework written in Teal,
designed specifically for LuaJIT with FFI. It provides a type-safe, cache-friendly
ECS implementation with immutable spawns, staging archetypes, and frame arena memory
management for zero allocations after warmup.

This rock ships only the renderer-agnostic core. For the LÖVE2D game-engine layer
(rendering, input, audio, tiled maps, tweens, UI, MCP tooling), install the
companion `tecs2d` rock.
    ]],
    homepage = "https://tecs.dev",
    license = "MIT"
}

dependencies = {
    "lua >= 5.1, < 5.5",
}

test_dependencies = {
    "busted",
}

build_dependencies = {
    "cyan >= 0.4.0",
}

test = {
    type = "busted",
    flags = { "--loaders=teal" }
}

build = {
    type = "make",
    build_target = "build",
    install_variables = {
        LUADIR = "$(LUADIR)",
        ROCK = "tecs",
    },
    modules = {},
    install = {}
}
