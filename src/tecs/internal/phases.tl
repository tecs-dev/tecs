local types <const> = require("tecs.types")

local type Phase = types.Phase

--- Defines the predefined ECS phases, or lifecycle states, of the game and event loop.
---
--- Tecs provides these standard phases but also supports custom pipelines via World.Config.pipelineFactory.
local record phases

    --- Contains all phases that make up the ECS lifecycle.
    record AllGroups is Phase
    end

    --- A meta-phase for the main game loop.
    record MainGroup is Phase
    end

    -------------------------------------------------------------------------------
    -- Startup phases
    -------------------------------------------------------------------------------

    --- Runs once at application start for critical initialization (e.g., logging, core systems).
    record PreStartup is Phase
    end

    --- Runs once at application start for general initialization (e.g., loading assets, creating entities).
    record Startup is Phase
    end

    --- Runs once after startup for final setup (e.g., starting gameplay, enabling systems).
    record PostStartup is Phase
    end

    -- A meta-phase for all startup phases.
    record StartupGroup is Phase
    end

    -------------------------------------------------------------------------------
    -- Update phases
    -------------------------------------------------------------------------------

    --- Runs once at the start of a logical update for sealed platform and
    --- external-service input. Observers run here in event sequence order.
    record Ingress is Phase
    end

    --- Runs at the very start of each frame (e.g., time updates, input polling).
    record First is Phase
    end

    --- Runs before the main update (e.g., physics preparation, event processing).
    record PreUpdate is Phase
    end

    -------------------------------------------------------------------------------
    -- Fixed update phases
    -------------------------------------------------------------------------------

    --- Runs at the start of each fixed timestep iteration (e.g., fixed timer updates).
    record FixedFirst is Phase
    end

    --- Runs before fixed update (e.g., collision detection preparation).
    record FixedPreUpdate is Phase
    end

    --- Runs at fixed timestep intervals for deterministic updates (e.g., physics simulation, gameplay logic).
    record FixedUpdate is Phase
    end

    --- Runs after fixed update (e.g., collision response, constraint solving).
    record FixedPostUpdate is Phase
    end

    --- Runs at the end of each fixed timestep iteration (e.g., state synchronization).
    record FixedLast is Phase
    end

    -- A meta-phase for all fixed-update phases.
    record FixedUpdateGroup is Phase
    end

    -------------------------------------------------------------------------------
    -- More update phases
    -------------------------------------------------------------------------------

    --- Main update phase, runs once per frame for gameplay logic and non-physics updates.
    record Update is Phase
    end

    --- Runs after update and before rendering (e.g., animation, transform updates, camera updates).
    record PostUpdate is Phase
    end

    -------------------------------------------------------------------------------
    -- Render phases
    -------------------------------------------------------------------------------

    --- Runs at the start of rendering (e.g., clearing buffers, setting up render state).
    record RenderFirst is Phase
    end

    --- Runs just before rendering (e.g., culling, sorting, batching).
    record PreRender is Phase
    end

    --- Main rendering phase (e.g., drawing sprites, meshes, UI).
    record Render is Phase
    end

    --- Runs just after rendering (e.g., post-processing effects, screen transitions).
    record PostRender is Phase
    end

    --- Runs at the end of rendering (e.g., presenting frame, GPU synchronization).
    record RenderLast is Phase
    end

    -- A meta-phase for all render phases.
    record RenderGroup is Phase
    end

    -------------------------------------------------------------------------------
    -- Final update phase
    -------------------------------------------------------------------------------

    --- Runs at the very end of each frame (e.g., cleanup, metrics collection, frame timing).
    record Last is Phase
    end

    -------------------------------------------------------------------------------
    -- Shutdown phases
    -------------------------------------------------------------------------------

    --- Runs just before shutdown (e.g., saving game state, closing connections).
    record PreShutdown is Phase
    end

    --- Main shutdown phase (e.g., releasing resources, destroying entities).
    record Shutdown is Phase
    end

    --- Runs after shutdown for final cleanup (e.g., logging shutdown metrics, final cleanup).
    record PostShutdown is Phase
    end

    -- A meta-phase for all shutdown phases.
    record ShutdownGroup is Phase
    end

    --- Read-only. Maps each lifecycle position to its phase definition.
    index: {Phase}
end

-- Set phase names after position assignment
local function setPhaseNames()
    for k, v in pairs(phases as table) do
        if type(v) == "table" then
            local phase = v as Phase
            if phase.position then
                phase.name = k as string
            end
        end
    end
end

phases.StartupGroup.children = {phases.PreStartup, phases.Startup, phases.PostStartup}

phases.MainGroup.children = {
    phases.Ingress,
    phases.First,
    phases.PreUpdate,
    phases.FixedUpdateGroup,
    phases.Update,
    phases.PostUpdate,
    phases.RenderGroup,
    phases.Last,
}

phases.FixedUpdateGroup.children = {
    phases.FixedFirst, phases.FixedPreUpdate, phases.FixedUpdate, phases.FixedPostUpdate, phases.FixedLast
}

phases.RenderGroup.children = {
    phases.RenderFirst, phases.PreRender, phases.Render, phases.PostRender, phases.RenderLast
}

phases.ShutdownGroup.children = {phases.PreShutdown, phases.Shutdown, phases.PostShutdown}

phases.AllGroups.children = {
    phases.StartupGroup,
    phases.MainGroup,
    phases.ShutdownGroup,
}

phases.index = {}

local function addPhases(phase: Phase)
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

-- Set phase names after all positions are assigned
setPhaseNames()

return phases
