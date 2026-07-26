











local root = os.getenv("TECS2D_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" ..
"../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local tecs = require("tecs")
local tecs2d = require("tecs2d")
local Transform2D = tecs2d.components.Transform2D
local Tint = tecs2d.components.Tint
local PointLight = tecs2d.components.PointLight
local Renderable = tecs2d.components.Renderable

local COUNT = math.floor(tonumber(os.getenv("TECS2D_INSTANCES")) or 4000)



local WORLD = tonumber(os.getenv("TECS2D_WORLD")) or 1.0
local LIGHTS = 3








local function spawnField(world, width, height)
   local centreX = width * 0.5
   local centreY = height * 0.5
   local extent = math.min(width, height) * 0.46 * WORLD
   local golden = 2.39996

   world:batchSpawn(COUNT, { Transform2D, Tint, Renderable },
   function(archetype, firstRow, lastRow)

      local transforms = archetype:getMut(Transform2D)
      local tints = archetype:getMut(Tint)

      for row = firstRow, lastRow do
         local index = row - firstRow
         local angle = index * golden
         local radius = math.sqrt(index / COUNT) * extent
         local size = 6.0 + 10.0 * (1.0 - radius / extent)
         local hue = index / COUNT

         local transform = transforms[row]
         transform.x = centreX + math.cos(angle) * radius
         transform.y = centreY + math.sin(angle) * radius
         transform.rotation = angle
         transform.scaleX = size
         transform.scaleY = size

         local tint = tints[row]
         tint.r = 0.55 + 0.45 * math.cos(6.28318 * hue)
         tint.g = 0.55 + 0.45 * math.cos(6.28318 * (hue + 0.33))
         tint.b = 0.55 + 0.45 * math.cos(6.28318 * (hue + 0.67))
         tint.a = 1.0
      end
   end)
end

local function spawnLights(world, width, height)
   local palette = {
      { 1.0, 0.42, 0.35 },
      { 0.38, 1.0, 0.62 },
      { 0.42, 0.58, 1.0 },
   }
   for index = 1, LIGHTS do
      local colour = palette[index]
      world:spawn(
      Transform2D(width * 0.5, height * 0.5, 0, 1, 1),
      PointLight(120.0, math.min(width, height) * 0.7,
      colour[1], colour[2], colour[3], 3.0))

   end
end

return tecs2d.application({
   window = { title = "tecs2d", width = 1280, height = 720 },
   debug = true,
   ambient = { 0.05, 0.05, 0.08 },
   capacity = COUNT + 16,
   maxEntities = COUNT + 64,
   maxFrames = tonumber(os.getenv("TECS2D_FRAMES")),
   presentMode = os.getenv("TECS2D_PRESENT"),

   load = function(app)
      local width, height = app.window:getPixelSize()
      print(("tecs2d %s"):format(tecs2d.version))
      print(("  driver: %s"):format(app.device.driver))
      print(("  window: %dx%d px"):format(width, height))

      local t0 = tecs2d.clock.now()
      spawnField(app.world, width, height)
      local t1 = tecs2d.clock.now()
      spawnLights(app.world, width, height)
      print(("  spawn: %.0f ms for %d entities"):format((t1 - t0) * 1000, COUNT))

      local elapsed = 0.0




      local static = os.getenv("TECS2D_STATIC") ~= nil
      local spinning = app.world:query({ include = { Transform2D, Renderable } })
      if not static then
         app.world:addSystem({
            name = "demo.Spin",
            phase = tecs.phases.Update,
            run = function(dt)
               elapsed = elapsed + dt
               for archetype, length in spinning:iter() do
                  local transforms = archetype:getMut(Transform2D)
                  for row = 1, length do
                     transforms[row].rotation = transforms[row].rotation + dt * 1.5
                  end
               end
            end,
         })
      end

      local orbiting = app.world:query({ include = { Transform2D, PointLight } })
      app.world:addSystem({
         name = "demo.OrbitLights",
         phase = tecs.phases.Update,
         run = function()
            local index = 0
            for archetype, length in orbiting:iter() do
               local transforms = archetype:getMut(Transform2D)
               for row = 1, length do
                  local angle = elapsed * 0.6 + index * 2.094
                  transforms[row].x = width * (0.5 + 0.3 * math.cos(angle))
                  transforms[row].y = height * (0.5 + 0.3 * math.sin(angle))
                  index = index + 1
               end
            end
         end,
      })

      print(("  %d renderable entities, %d light entities"):format(COUNT, LIGHTS))
      print("  escape or close the window to quit")
   end,

   update = function(app)


      if app.input:isKeyPressed("escape") then
         app.quitRequested = true
      end
   end,

   event = function(_app, event)



      if event.kind == "appWillEnterBackground" then
         print("  backgrounded, simulation suspended")
      end
   end,

   quit = function(app)
      print(("ran %d frames over %.2fs (%.2f ms/frame, %d drawn, %d resynced)"):
      format(app.frame, app.elapsed,
      app.elapsed / math.max(app.frame, 1) * 1000,
      app.renderer.count, app.renderer.rewritten))
   end,
})
