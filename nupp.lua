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
                description = "Build the headless Tecs rewrite",
                entries = {
                    "tecs.application",
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
            host = {
                kind = "component",
                description = "Build the Tecs component for the Rust winit host",
                entries = { "tecs.host" },
                exports = hostExports,
            },
            flatcolor = {
                kind = "component",
                description = "Build the animated flat-color Nupp example",
                entries = { "tecs.host", "flatcolor" },
                exports = flatcolorExports,
            },
            sprites = {
                kind = "component",
                description = "Build the camera and textured sprite Nupp example",
                entries = { "tecs.host", "sprites" },
                exports = spritesExports,
            },
            lighting = {
                kind = "component",
                description = "Build the deferred lighting, shadow and bloom Nupp example",
                entries = { "tecs.host", "lighting" },
                exports = lightingExports,
            },
            -- The component `cargo xtask test-package` runs against an
            -- installed release. It is a component rather than a script
            -- because a package ships no Nupp compiler, so the only Nupp a
            -- release can execute is one already compiled into a component.
            nativesmoke = {
                kind = "component",
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
                github = "https://github.com/mtdowling/tecs",
                logo = "images/logo.svg",
                favicon = "images/favicon.svg",
                public = "docs/public",
                pages = { { glob = "docs/**.md" } },
            },
        },
    },

    test = { build = "headless", argv = { "nupp", "test-runner" } },
}
