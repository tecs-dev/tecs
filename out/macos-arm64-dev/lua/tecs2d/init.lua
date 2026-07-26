








local clock = require("tecs2d.platform.clock")
local events = require("tecs2d.platform.events")
local Window = require("tecs2d.platform.Window")
local Input = require("tecs2d.platform.Input")
local Device = require("tecs2d.gpu.Device")
local Frame = require("tecs2d.gpu.Frame")
local RenderPass = require("tecs2d.gpu.RenderPass")
local Renderer = require("tecs2d.Renderer")
local Application = require("tecs2d.Application")
local components = require("tecs2d.components")

local tecs2d = {}














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
tecs2d.version = "0.1.0"





function tecs2d.application(config)
   return Application.create(config)
end

return tecs2d
