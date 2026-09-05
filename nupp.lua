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

return {
    include = {"src", "examples/nupp"},

    build = {
        outDir = "out/nupp",
        default = "headless",
        targets = {
            headless = {
                kind = "modules",
                description = "Build the headless Tecs rewrite",
                entries = {
                    "tecs.application",
                    "tecs.audio",
                    "tecs.ecs",
                    "tecs.data",
                    "tecs.events",
                    "tecs.gfx",
                    "tecs.gfx.fonts",
                    "tecs.gfx.images",
                    "tecs.gfx.layers",
                    "tecs.gfx.text",
                    "tecs.gfx.truetype",
                    "tecs.host",
                    "tecs.input",
                    "tecs.mcp",
                    "tecs.physics",
                    "tecs.physics.contract",
                    "tecs.physics.rapier",
                    "tecs.platform.audiobackend",
                    "tecs.platform.audionative",
                    "tecs.platform.events",
                    "tecs.platform.window",
                    "tecs.sequence",
                    "tecs.internal.archetype",
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
                    "tecs.internal.netadapter",
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
                entries = {"tecs.host"},
                exports = hostExports,
            },
            flatcolor = {
                kind = "component",
                description = "Build the animated flat-color Nupp example",
                entries = {"tecs.host", "flatcolor"},
                exports = flatcolorExports,
            },
            sprites = {
                kind = "component",
                description = "Build the camera and textured sprite Nupp example",
                entries = {"tecs.host", "sprites"},
                exports = spritesExports,
            },
        },
    },

    test = {
        build = "headless",
        argv = {"nupp", "test-runner"},
    },
}
