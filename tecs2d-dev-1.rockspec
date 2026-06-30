rockspec_format = "3.0"
package = "tecs2d"
version = "dev-1"

source = {
    url = "git+https://github.com/tecs-dev/tecs.git",
    branch = "main"
}

description = {
    summary = "LÖVE2D game-engine layer for the Tecs ECS framework",
    detailed = [[
Tecs2D is the LÖVE2D-facing game-engine layer built on top of the Tecs ECS core.
It provides a GPU-driven render pipeline (LÖVE 12), input, audio, tweens, a
controller plugin, tiled-map support, a UI plugin, and MCP tooling for
introspection and live editing.

The renderer-agnostic ECS core is shipped separately in the `tecs` rock and is
declared as a dependency.
    ]],
    homepage = "https://tecs.dev",
    license = "MIT"
}

dependencies = {
    "lua >= 5.1, < 5.5",
    "tecs == dev-1",
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
        ROCK = "tecs2d",
    },
    modules = {},
    install = {}
}
