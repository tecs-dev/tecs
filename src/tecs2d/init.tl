--- tecs2d public surface.
---
--- SDL owns the loop. An entry file returns an application and the C host
--- drives it, because iOS never hands control back for a blocking loop to sit
--- in, and one lifecycle beats one per platform.
---
--- Entities are the interface: anything that renders or updates per frame is
--- an entity in a Tecs world.

local clock <const> = require("tecs2d.platform.clock")
local events <const> = require("tecs2d.platform.events")
local Window <const> = require("tecs2d.platform.Window")
local Input <const> = require("tecs2d.platform.Input")
local Device <const> = require("tecs2d.gpu.Device")
local Frame <const> = require("tecs2d.gpu.Frame")
local RenderPass <const> = require("tecs2d.gpu.RenderPass")
local Renderer <const> = require("tecs2d.Renderer")
local Application <const> = require("tecs2d.Application")
local components <const> = require("tecs2d.components")
local tween <const> = require("tecs2d.tween")
local sequence <const> = require("tecs2d.sequence")
local log <const> = require("tecs2d.log")

local record tecs2d
    Application: Application
    Renderer: Renderer
    Window: Window
    Device: Device
    Frame: Frame
    RenderPass: RenderPass
    Input: Input
    clock: clock
    events: events
    components: components
    log: log
    tween: tween
    sequence: sequence
    --- Version of this engine build.
    version: string
end

tecs2d.Application = Application
tecs2d.Renderer = Renderer
tecs2d.Window = Window
tecs2d.Device = Device
tecs2d.Frame = Frame
tecs2d.RenderPass = RenderPass
tecs2d.Input = Input
tecs2d.clock = clock
tecs2d.events = events
tecs2d.components = components
tecs2d.log = log
tecs2d.tween = tween
tecs2d.sequence = sequence
tecs2d.version = "0.1.0"

--- Builds the application the entry chunk returns.
---
--- Not a function that runs until done: an entry file ends with
--- `return tecs2d.application(config)` and the host drives it from there.
function tecs2d.application(config: Application.Config): Application
    return Application.create(config)
end

return tecs2d
