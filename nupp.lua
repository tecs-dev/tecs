-- Nupp owns the development workflow; Cargo only builds native artifacts.
local developmentTasks = {}
local descriptions = {
    deps = "Install the development formatters",
    run = "Build and run a game component through the native host",
    bench = "Run an optimized benchmark or performance acceptance",
    format = "Format Nupp, Rust, Lua and web sources",
    ["format-check"] = "Check formatting across every source language",
    ["docs-check"] = "Check page metadata and render every documentation link",
    ["docs-dev"] = "Serve the documentation and rebuild on changes",
    verify = "Check sources, tests, docs, Rust and component smokes",
    ["test-tools"] = "Check the development tools and their regression tests",
    clean = "Remove Nupp and native build outputs",
}
for name, description in pairs(descriptions) do
    developmentTasks[name] = {
        description = description,
        argv = { "nupp", "run", "tools/run.nupp", name },
    }
end
for _, name in ipairs({ "host", "flatcolor", "sprites", "lighting", "nativesmoke", "tiled", "ui", "uistandalone" }) do
    developmentTasks["ex-" .. name] = {
        description = "Build and run the " .. name .. " component",
        build = "ex-" .. name,
        argv = { "nupp", "run", "tools/run.nupp", "host", name },
    }
end
developmentTasks["ex-uistandalone"].argv = {
    "nupp",
    "run",
    "tools/run.nupp",
    "host",
    "uistandalone",
    "--width",
    "960",
    "--height",
    "640",
}
developmentTasks["ex-physicssmoke"] = {
    description = "Build native services and run the physics example",
    argv = { "nupp", "run", "tools/run.nupp", "physicssmoke" },
}
for name, description in pairs({
    presets = "List native packaging presets",
    package = "Build and install a relocatable native release",
    ["check-package"] = "Validate an installed native package",
    ["test-package"] = "Build and test a release after relocation",
}) do
    developmentTasks[name] = {
        description = description,
        argv = {
            "cargo",
            "run",
            "--locked",
            "--quiet",
            "-p",
            "tecs-build-support",
            "--bin",
            "tecs-package",
            "--",
            name,
        },
    }
end

local hostExports = {
    "tecs.host.create",
    "tecs.host.init",
    "tecs.host.iterate",
    "tecs.host.shutdown",
    "tecs.host.crashed",
    "tecs.host.renderPacket",
    "tecs.host.setSuspended",
    "tecs.host.attachWindow",
    "tecs.host.applyWindowState",
    "tecs.host.detachWindow",
    "tecs.host.pushQuit",
    "tecs.host.pushClose",
    "tecs.host.pushResize",
    "tecs.host.pushFocus",
    "tecs.host.pushKey",
    "tecs.host.pushPointerMove",
    "tecs.host.pushPointerButton",
    "tecs.host.pushWheel",
    "tecs.host.pushText",
    "tecs.host.pushTouch",
    "tecs.host.nextWindowCommand",
    "tecs.host.windowCommandFailed",
    "tecs.host.nextImageCommand",
    "tecs.host.imageCommandResult",
}

local flatcolorExports = {}
for index = 1, #hostExports do
    flatcolorExports[index] = hostExports[index]
end
flatcolorExports[#flatcolorExports + 1] = "flatcolor.create"

local spritesExports = {}
for index = 1, #hostExports do
    spritesExports[index] = hostExports[index]
end
spritesExports[#spritesExports + 1] = "sprites.create"

local lightingExports = {}
for index = 1, #hostExports do
    lightingExports[index] = hostExports[index]
end
lightingExports[#lightingExports + 1] = "lighting.create"

local nativesmokeExports = {}
for index = 1, #hostExports do
    nativesmokeExports[index] = hostExports[index]
end
nativesmokeExports[#nativesmokeExports + 1] = "nativesmoke.create"

local tiledExports = {}
local uiExports = {}
for index = 1, #hostExports do
    tiledExports[index] = hostExports[index]
    uiExports[index] = hostExports[index]
end
tiledExports[#tiledExports + 1] = "tiled.create"
uiExports[#uiExports + 1] = "ui.create"

local uistandaloneExports = {}
for index = 1, #hostExports do
    uistandaloneExports[index] = hostExports[index]
end
uistandaloneExports[#uistandaloneExports + 1] = "uistandalone.create"

return {
    -- `tests` is included because leaving it out meant `nupp check --strict`
    -- never read a test file. Two suites called `suspension.gather` and
    -- `suspension.all`, neither of which exists, and both passed review: the
    -- checker was never pointed at them, and the test runner's build cache
    -- kept serving artifacts compiled before the calls were wrong. `bench/nupp`
    -- is included for the same reason: the Teal tree checks `bench/` too.
    include = { "src", "examples/nupp", "tests", "bench/nupp" },

    build = {
        outDir = "out/nupp",
        default = "headless",
        targets = {
            headless = {
                kind = "modules",
                description = "Build the headless Tecs modules",
                entries = {
                    "tecs.application",
                    "tecs.ui",
                    "tecs.tiled",
                    "tecs.internal.uinative",
                    "tecs.internal.assetnative",
                    "tecs.assets",
                    "tecs.audio",
                    "tecs.ecs",
                    "tecs.data",
                    "tecs.events",
                    "tecs.files",
                    "tecs.gfx",
                    "tecs.gfx.animation",
                    "tecs.gfx.clips",
                    "tecs.gfx.fonts",
                    "tecs.gfx.images",
                    "tecs.gfx.layers",
                    "tecs.gfx.lighting",
                    "tecs.gfx.sheet",
                    "tecs.gfx.text",
                    "tecs.gfx.truetype",
                    "tecs.gpu.materials",
                    "tecs.gpu.passes",
                    "tecs.host",
                    "tecs.input",
                    "tecs.mcp",
                    "tecs.physics",
                    "tecs.physics.contract",
                    "tecs.physics.rapier",
                    "tecs.platform.audiobackend",
                    "tecs.platform.audionative",
                    "tecs.platform.gamepadbackend",
                    "tecs.platform.gamepadnative",
                    "tecs.platform.events",
                    "tecs.platform.window",
                    "tecs.sequence",
                    "tecs.watch",
                    "tecs.internal.archetype",
                    "tecs.internal.builtins",
                    "tecs.internal.componentids",
                    "tecs.internal.components",
                    "tecs.internal.events",
                    "tecs.internal.framepump",
                    "tecs.internal.framepacket",
                    "tecs.internal.hostcancellation",
                    "tecs.internal.idallocator",
                    "tecs.internal.inverseindex",
                    "tecs.internal.nativelibrary",
                    "tecs.internal.mcpbindings",
                    "tecs.internal.mcpregistry",
                    "tecs.internal.mcpsandbox",
                    "tecs.internal.mcptools",
                    "tecs.internal.mcptransport",
                    "tecs.internal.mcpworld",
                    "tecs.internal.mcpschemas",
                    "tecs.internal.mcpsubsystems",
                    "tecs.internal.cameraselection",
                    "tecs.internal.phases",
                    "tecs.internal.query",
                    "tecs.internal.rendercomponents",
                    "tecs.internal.sequencecursors",
                    "tecs.internal.sequenceprogram",
                    "tecs.internal.sequenceregistry",
                    "tecs.internal.sequencesnapshot",
                    "tecs.internal.sequencetypes",
                    "tecs.internal.sequencevm",
                    "tecs.internal.snapshotvalue",
                    "tecs.internal.store",
                    "tecs.internal.tweeneval",
                    "tecs.internal.tweenrun",
                    "tecs.internal.wakeheap",
                    "tecs.internal.world",
                },
            },
            ["ex-host"] = {
                kind = "component",
                output = "out/nupp/host.nuppc",
                description = "Build the Tecs component for the Rust winit host",
                entries = { "tecs.host" },
                exports = hostExports,
            },
            ["ex-flatcolor"] = {
                kind = "component",
                output = "out/nupp/flatcolor.nuppc",
                description = "Build the animated flat-color Nupp example",
                entries = { "tecs.host", "flatcolor" },
                exports = flatcolorExports,
            },
            ["ex-sprites"] = {
                kind = "component",
                output = "out/nupp/sprites.nuppc",
                description = "Build the camera and textured sprite Nupp example",
                entries = { "tecs.host", "sprites" },
                exports = spritesExports,
            },
            ["ex-lighting"] = {
                kind = "component",
                output = "out/nupp/lighting.nuppc",
                description = "Build the deferred lighting, shadow and bloom Nupp example",
                entries = { "tecs.host", "lighting" },
                exports = lightingExports,
            },
            ["ex-tiled"] = {
                kind = "component",
                output = "out/nupp/tiled.nuppc",
                description = "Build the TMX map example",
                entries = { "tecs.host", "tiled" },
                exports = tiledExports,
            },
            ["ex-uistandalone"] = {
                kind = "component",
                output = "out/nupp/uistandalone.nuppc",
                description = "Build the centered retained UI example",
                entries = { "tecs.host", "uistandalone" },
                exports = uistandaloneExports,
            },
            ["ex-ui"] = {
                kind = "component",
                output = "out/nupp/ui.nuppc",
                description = "Build the retained Taffy UI example",
                entries = { "tecs.host", "ui" },
                exports = uiExports,
            },
            -- The component `nupp task test-package` runs against an
            -- installed release. It is a component rather than a script
            -- because a package ships no Nupp compiler, so the only Nupp a
            -- release can execute is one already compiled into a component.
            ["ex-nativesmoke"] = {
                kind = "component",
                output = "out/nupp/nativesmoke.nuppc",
                description = "Build the packaged native-service smoke component",
                entries = { "tecs.host", "nativesmoke" },
                exports = nativesmokeExports,
            },
            -- The documentation site: the handwritten pages under `docs/`
            -- with the API reference generated from the same declaration
            -- docblocks the checker reads, so a signature has no second copy
            -- to drift from.
            --
            -- `description` here is the site's meta description rather than
            -- this target's blurb, which is why it describes Tecs and not the
            -- render.
            docs = {
                kind = "docs",
                sources = { "src" },
                format = "site",
                outDir = "out/docs",
                title = "Tecs",
                name = "Tecs",
                description = "Typed entity component system and game engine, in Nupp.",
                github = "https://github.com/tecs-dev/tecs",
                logo = "images/controller.svg",
                favicon = "images/favicon.svg",
                public = "docs/public",
                customCss = "docs/site.css",
                pages = { { glob = "docs/**.md" } },
            },
        },
    },

    test = { build = "headless", argv = { "nupp", "run", "tools/run.nupp", "test" } },

    tasks = developmentTasks,
}
