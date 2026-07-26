





local tecs = require("tecs")






local Transform2D = {}








tecs.newFFIComponent({
   name = "Transform2D",
   container = Transform2D,
   fields = {
      { "x", "float" }, { "y", "float" },
      { "rotation", "float" },
      { "scaleX", "float" }, { "scaleY", "float" },
   },
   defaults = { 0, 0, 0, 1, 1 },
})


local Tint = {}






tecs.newFFIComponent({
   name = "Tint",
   container = Tint,
   fields = {
      { "r", "float" }, { "g", "float" },
      { "b", "float" }, { "a", "float" },
   },
   defaults = { 1, 1, 1, 1 },
})


local PointLight = {}











tecs.newFFIComponent({
   name = "PointLight",
   container = PointLight,
   fields = {
      { "height", "float" }, { "radius", "float" },
      { "r", "float" }, { "g", "float" }, { "b", "float" },
      { "intensity", "float" },
   },
   defaults = { 64, 256, 1, 1, 1, 1 },
})







local Sprite = {}







tecs.newFFIComponent({
   name = "Sprite",
   container = Sprite,
   fields = {
      { "slot", "int32_t" },
      { "u0", "float" }, { "v0", "float" },
      { "u1", "float" }, { "v1", "float" },
   },
   defaults = { 0, 0, 0, 1, 1 },
})



local Renderable = {}

tecs.newComponent({
   name = "Renderable",
   container = Renderable,
})

local components = {}







components.Transform2D = Transform2D
components.Tint = Tint
components.Sprite = Sprite
components.PointLight = PointLight
components.Renderable = Renderable

return components
