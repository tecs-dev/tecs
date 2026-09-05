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
}

local flatcolorExports = {}
for index = 1, #hostExports do
    flatcolorExports[index] = hostExports[index]
end
flatcolorExports[#flatcolorExports + 1] = "flatcolor.create"

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
                    "tecs.assets",
                    "tecs.ecs",
                    "tecs.data",
                    "tecs.events",
                    "tecs.gfx",
                    "tecs.host",
                    "tecs.input",
                    "tecs.log",
                    "tecs.platform.events",
                    "tecs.platform.window",
                    "tecs.internal.archetype",
                    "tecs.internal.componentids",
                    "tecs.internal.components",
                    "tecs.internal.events",
                    "tecs.internal.framepump",
                    "tecs.internal.framepacket",
                    "tecs.internal.hostcancellation",
                    "tecs.internal.idallocator",
                    "tecs.internal.inverseindex",
                    "tecs.internal.phases",
                    "tecs.internal.query",
                    "tecs.internal.rendercomponents",
                    "tecs.internal.snapshotvalue",
                    "tecs.internal.store",
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
        },
    },

    test = {
        build = "headless",
        argv = {"nupp", "test-runner"},
    },
}
