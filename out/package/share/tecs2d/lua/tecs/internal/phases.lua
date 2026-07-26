local types = require("tecs.types")






local phases = { AllGroups = {}, MainGroup = {}, PreStartup = {}, Startup = {}, PostStartup = {}, StartupGroup = {}, First = {}, PreUpdate = {}, FixedFirst = {}, FixedPreUpdate = {}, FixedUpdate = {}, FixedPostUpdate = {}, FixedLast = {}, FixedUpdateGroup = {}, Update = {}, PostUpdate = {}, RenderFirst = {}, PreRender = {}, Render = {}, Draw = {}, PostRender = {}, RenderLast = {}, RenderGroup = {}, Last = {}, PreShutdown = {}, Shutdown = {}, PostShutdown = {}, ShutdownGroup = {} }
























































































































local function setPhaseNames()
   for k, v in pairs(phases) do
      if type(v) == "table" then
         local phase = v
         if phase.position then
            phase.name = k
         end
      end
   end
end

phases.StartupGroup.children = {
   phases.PreStartup,
   phases.Startup,
   phases.PostStartup,
}

phases.MainGroup.children = {
   phases.First,
   phases.PreUpdate,
   phases.FixedUpdateGroup,
   phases.Update,
   phases.PostUpdate,
   phases.RenderGroup,
   phases.Last,
}

phases.FixedUpdateGroup.children = {
   phases.FixedFirst,
   phases.FixedPreUpdate,
   phases.FixedUpdate,
   phases.FixedPostUpdate,
   phases.FixedLast,
}

phases.RenderGroup.children = {
   phases.RenderFirst,
   phases.PreRender,
   phases.Render,
   phases.PostRender,
   phases.RenderLast,
}

phases.ShutdownGroup.children = {
   phases.PreShutdown,
   phases.Shutdown,
   phases.PostShutdown,
}

phases.AllGroups.children = {
   phases.StartupGroup,
   phases.MainGroup,
   phases.ShutdownGroup,
}

phases.index = {}

local function addPhases(phase)
   if not phase.children then
      phases.index[#phases.index + 1] = phase
      phase.position = #phases.index
   else
      for i = 1, #phase.children do
         addPhases(phase.children[i])
      end
   end
end

addPhases(phases.AllGroups)


setPhaseNames()


phases.Draw.name = "Draw"

return phases
