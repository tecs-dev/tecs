rockspec_format = "3.0"
package = "tecs-cli"
version = "0.1.0-1"

source = {
    url = "git+https://github.com/tecs-dev/tecs-cli.git",
    tag = "v0.1.0",
}

description = {
    summary = "Command-line tool for Tecs projects",
    detailed = [[
Tecs CLI creates, builds, checks, tests, and runs fixed-layout Tecs2D projects.
It installs project-local Teal, Tecs, Tecs2D, and Love2D runtime dependencies so
new projects can be bootstrapped with `tecs new` and `tecs run`.
]],
    homepage = "https://github.com/tecs-dev/tecs-cli",
    license = "MIT OR Apache-2.0",
}

-- Tecs targets LuaJIT, which implements Lua 5.1.
dependencies = {
    "lua == 5.1",
    "ansicolors",
    "argparse",
    "luafilesystem",
}

build = {
    type = "builtin",
    modules = {
        ["tecs_cli.cli"] = "tecs_cli/cli.lua",
    },
    copy_directories = {
        "tecs_cli/templates",
    },
    install = {
        bin = {
            tecs = "bin/tecs",
        },
    },
}
