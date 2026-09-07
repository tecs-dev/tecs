-- Nupp owns the development workflow; Cargo only builds native artifacts.
local developmentTasks = {}
local descriptions = {
    fetch = "Fetch and prepare the pinned Sponza or Bistro example assets",
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
for _, name in ipairs({
    "host",
    "flatcolor",
    "views",
    "postprocess",
    "gltf3d",
    "skinning3d",
    "morph3d",
    "shadows3d",
    "sponza3d",
    "bistro3d",
    "animated3d",
    "scene3d",
    "ibl3d",
    "particles",
    "sprites",
    "lighting",
    "nativesmoke",
    "tiled",
    "ui",
    "uistandalone",
    "shapes",
}) do
    developmentTasks["ex-" .. name] = {
        description = "Build and run the " .. name .. " component",
        build = "ex-" .. name,
        argv = { "nupp", "run", "tools/run.nupp", "host", name },
    }
end
developmentTasks["ex-nativesmoke"].description = "Run the native library loading smoke test"
developmentTasks["ex-shapes"].description = "Show the built-in shape gallery"
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
    "tecs.host.nextCapture",
    "tecs.host.captureResult",
    "tecs.host.nextModelUpload",
}

local flatcolorExports = {}
for index = 1, #hostExports do
    flatcolorExports[index] = hostExports[index]
end
flatcolorExports[#flatcolorExports + 1] = "flatcolor.create"

local viewsExports, postprocessExports = {}, {}
for index = 1, #hostExports do
    viewsExports[index] = hostExports[index]
    postprocessExports[index] = hostExports[index]
end
viewsExports[#viewsExports + 1] = "views.create"
postprocessExports[#postprocessExports + 1] = "postprocess.create"

local scene3dExports, ibl3dExports, particlesExports = {}, {}, {}
for index = 1, #hostExports do
    scene3dExports[index], ibl3dExports[index], particlesExports[index] =
        hostExports[index], hostExports[index], hostExports[index]
end
scene3dExports[#scene3dExports + 1] = "scene3d.create"
ibl3dExports[#ibl3dExports + 1] = "ibl3d.create"
particlesExports[#particlesExports + 1] = "particles.create"
local gltf3dExports = {}
for index = 1, #hostExports do
    gltf3dExports[index] = hostExports[index]
end
gltf3dExports[#gltf3dExports + 1] = "gltf3d.create"

local skinning3dExports = {}
for index = 1, #hostExports do
    skinning3dExports[index] = hostExports[index]
end
skinning3dExports[#skinning3dExports + 1] = "skinning3d.create"

local morph3dExports = {}
for index = 1, #hostExports do
    morph3dExports[index] = hostExports[index]
end
morph3dExports[#morph3dExports + 1] = "morph3d.create"

local shadows3dExports = {}
for index = 1, #hostExports do
    shadows3dExports[index] = hostExports[index]
end
shadows3dExports[#shadows3dExports + 1] = "shadows3d.create"
local sponza3dExports = {}
for index = 1, #hostExports do
    sponza3dExports[index] = hostExports[index]
end
sponza3dExports[#sponza3dExports + 1] = "sponza3d.create"
local bistro3dExports = {}
for index = 1, #hostExports do
    bistro3dExports[index] = hostExports[index]
end
bistro3dExports[#bistro3dExports + 1] = "bistro3d.create"
local animated3dExports = {}
for index = 1, #hostExports do
    animated3dExports[index] = hostExports[index]
end
animated3dExports[#animated3dExports + 1] = "animated3d.create"

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

local shapesExports = {}
for index = 1, #hostExports do
    shapesExports[index] = hostExports[index]
end
shapesExports[#shapesExports + 1] = "shapes.create"

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
                    "tecs.files",
                    "tecs.gfx",
                    "tecs.gfx.animation",
                    "tecs.gfx.frametable",
                    "tecs.gfx.particles",
                    "tecs.gfx.camera3d",
                    "tecs.gfx.flycamera3d",
                    "tecs.gfx.models",
                    "tecs.gfx.clips",
                    "tecs.internal.tilechunk",
                    "tecs.gfx.fonts",
                    "tecs.gfx.images",
                    "tecs.gfx.screenshot",
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
                    "tecs.internal.ffistorage",
                    "tecs.internal.builtins",
                    "tecs.internal.componentids",
                    "tecs.internal.components",
                    "tecs.internal.events",
                    "tecs.internal.framepump",
                    "tecs.internal.framepacket",
                    "tecs.internal.views",
                    "tecs.internal.meshcomponents",
                    "tecs.internal.meshregistry",
                    "tecs.internal.meshpacket",
                    "tecs.internal.viewpacket",
                    "tecs.internal.dirtyranges",
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
                    "tecs.internal.runif",
                    "tecs.internal.randomstreams",
                    "tecs.internal.query",
                    "tecs.internal.rendercomponents",
                    "tecs.internal.sequencecursors",
                    "tecs.internal.sequenceprogram",
                    "tecs.internal.sequenceregistry",
                    "tecs.internal.sequencesnapshot",
                    "tecs.internal.sequencetypes",
                    "tecs.internal.sequencevm",
                    "tecs.internal.snapshotvalue",
                    "tecs.internal.snapshotcodec",
                    "tecs.internal.entitycolumn",
                    "tecs.internal.fixedtracking",
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
            ["ex-views"] = {
                kind = "component",
                output = "out/nupp/views.nuppc",
                description = "Build the split-screen camera example",
                entries = { "tecs.host", "views" },
                exports = viewsExports,
            },
            ["ex-postprocess"] = {
                kind = "component",
                output = "out/nupp/postprocess.nuppc",
                description = "Build the custom WGSL color-grading example",
                entries = { "tecs.host", "postprocess" },
                exports = postprocessExports,
            },
            ["ex-scene3d"] = {
                kind = "component",
                output = "out/nupp/scene3d.nuppc",
                description = "Build the scene3d showcase",
                entries = { "tecs.host", "scene3d" },
                exports = scene3dExports,
            },
            ["ex-ibl3d"] = {
                kind = "component",
                output = "out/nupp/ibl3d.nuppc",
                description = "Build the ibl3d showcase",
                entries = { "tecs.host", "ibl3d" },
                exports = ibl3dExports,
            },
            ["ex-particles"] = {
                kind = "component",
                output = "out/nupp/particles.nuppc",
                description = "Build the particles showcase",
                entries = { "tecs.host", "particles" },
                exports = particlesExports,
            },
            ["ex-gltf3d"] = {
                kind = "component",
                output = "out/nupp/gltf3d.nuppc",
                description = "Build the original gltf3d example",
                entries = { "tecs.host", "gltf3d" },
                exports = gltf3dExports,
            },
            ["ex-skinning3d"] = {
                kind = "component",
                output = "out/nupp/skinning3d.nuppc",
                description = "Build the original skinning3d example",
                entries = { "tecs.host", "skinning3d" },
                exports = skinning3dExports,
            },
            ["ex-morph3d"] = {
                kind = "component",
                output = "out/nupp/morph3d.nuppc",
                description = "Build the original morph3d example",
                entries = { "tecs.host", "morph3d" },
                exports = morph3dExports,
            },
            ["ex-shadows3d"] = {
                kind = "component",
                output = "out/nupp/shadows3d.nuppc",
                description = "Build the original shadows3d example",
                entries = { "tecs.host", "shadows3d" },
                exports = shadows3dExports,
            },
            ["ex-sponza3d"] = {
                kind = "component",
                output = "out/nupp/sponza3d.nuppc",
                description = "Build the original sponza3d example",
                entries = { "tecs.host", "sponza3d" },
                exports = sponza3dExports,
            },
            ["ex-bistro3d"] = {
                kind = "component",
                output = "out/nupp/bistro3d.nuppc",
                description = "Build the original bistro3d example",
                entries = { "tecs.host", "bistro3d" },
                exports = bistro3dExports,
            },
            ["ex-animated3d"] = {
                kind = "component",
                output = "out/nupp/animated3d.nuppc",
                description = "Build the animated glTF hero and morph-cube showcase",
                entries = { "tecs.host", "animated3d" },
                exports = animated3dExports,
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
            ["ex-shapes"] = {
                kind = "component",
                output = "out/nupp/shapes.nuppc",
                description = "Build the built-in shape gallery and rendering benchmark",
                entries = { "tecs.host", "shapes" },
                exports = shapesExports,
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
