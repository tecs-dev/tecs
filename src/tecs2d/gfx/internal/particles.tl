local tecs <const> = require("tecs")
local tecs_assets <const> = require("tecs2d.assets")
local pipelinekey <const> = require("tecs2d.gfx.internal.pipelinekey")
local Unlit <const> = require("tecs2d.gfx.internal.Unlit")

local Transform <const> = tecs.builtins.Transform
local lg <const> = love.graphics
local lg_newParticleSystem <const> = love.graphics.newParticleSystem
local unpack <const> = table.unpack
local abs <const> = math.abs

-- ParticleSystem is a valid Drawable; rawget bypasses Teal's Drawable type
-- narrowing so we can pass it to lg.draw. Hoisted once at module scope to
-- avoid per-frame rawget+cast overhead in the render loop.
local lg_draw <const> = rawget(lg as {any:any}, "draw") as function(any, number, number)

local LOGGER <const> = require("tecs.utils.logging").getLogger("tecs2d.gfx.particle_emitter")

local record particles
    --- Configuration for creating a serializable ParticleEmitter.
    --- All fields except texturePath are optional and use sensible defaults.
    record ParticleEmitterConfig
        --- Path to particle texture image. Required for serialization.
        texturePath: string

        --- Max particles in the system (constructor arg). Default: 1000
        bufferSize: integer

        --- Particles emitted per second (setEmissionRate)
        emissionRate: number

        --- Emission area: {distribution, dx, dy, angle, directionRelativeToCenter}
        emissionArea: {string, number, number, number, boolean}

        --- Particle lifetime range in seconds: {min, max}
        particleLifetime: {number, number}

        --- Emission direction in radians (setDirection)
        direction: number

        --- Emission spread in radians (setSpread)
        spread: number

        --- Particle speed range: {min, max}
        speed: {number, number}

        --- Linear acceleration: {xmin, ymin, xmax, ymax}
        linearAcceleration: {number, number, number, number}

        --- Radial acceleration range: {min, max}
        radialAcceleration: {number, number}

        --- Tangential acceleration range: {min, max}
        tangentialAcceleration: {number, number}

        --- Linear damping range: {min, max}
        linearDamping: {number, number}

        --- Size keyframes, up to 8: {size1, size2, ...}
        sizes: {number}

        --- Size variation (0-1)
        sizeVariation: number

        --- Color keyframes as RGBA arrays: {{r,g,b,a}, {r,g,b,a}, ...}
        colors: {{number, number, number, number}}

        --- Initial rotation range in radians: {min, max}
        rotation: {number, number}

        --- Spin rate range in radians/second: {min, max}
        spin: {number, number}

        --- Spin variation (0-1)
        spinVariation: number

        --- Whether particles rotate with movement direction
        relativeRotation: boolean

        --- Texture offset: {x, y}
        offset: {number, number}

        --- Insert mode: "top", "bottom", or "random"
        insertMode: string
    end

    --- ParticleEmitter component wrapping a Love2D ParticleSystem.
    record ParticleEmitter is tecs.Component
        --- The Love2D ParticleSystem instance.
        system: love.graphics.ParticleSystem

        --- Optional config for serialization. When set, the emitter can be serialized/deserialized.
        config: ParticleEmitterConfig

        --- Creates a new ParticleEmitter from an existing ParticleSystem.
        --- @param system love.graphics.ParticleSystem The particle system to wrap.
        --- @param config? ParticleEmitterConfig Optional config for serialization support.
        --- @return ParticleEmitter The created emitter.
        metamethod __call: function(
            self, system: love.graphics.ParticleSystem, config?: ParticleEmitterConfig
        ): ParticleEmitter

        --- Create a ParticleEmitter from a config, loading the texture and applying all settings.
        --- This is the preferred way to create serializable particle emitters.
        --- @param world tecs.World The world context for loading resources.
        --- @param config ParticleEmitterConfig The configuration to use.
        --- @return ParticleEmitter The created emitter.
        fromConfig: function(world: tecs.World, config: ParticleEmitterConfig): ParticleEmitter
    end

    plugin: function(world: tecs.World)
end

local ParticleEmitter <const> = particles.ParticleEmitter
local ParticleEmitterConfig <const> = particles.ParticleEmitterConfig

--- Apply all config properties to a particle system
local function applyConfig(system: love.graphics.ParticleSystem, config: ParticleEmitterConfig)
    -- Core emission
    if config.emissionRate then
        system:setEmissionRate(config.emissionRate)
    end
    if config.emissionArea then
        system:setEmissionArea(
            config.emissionArea[1] as love.graphics.AreaSpreadDistribution,
            config.emissionArea[2],
            config.emissionArea[3],
            config.emissionArea[4],
            config.emissionArea[5]
        )
    end
    if config.particleLifetime then
        system:setParticleLifetime(config.particleLifetime[1], config.particleLifetime[2])
    end

    -- Movement
    if config.direction then
        system:setDirection(config.direction)
    end
    if config.spread then
        system:setSpread(config.spread)
    end
    if config.speed then
        system:setSpeed(config.speed[1], config.speed[2])
    end
    if config.linearAcceleration then
        system:setLinearAcceleration(
            config.linearAcceleration[1],
            config.linearAcceleration[2],
            config.linearAcceleration[3],
            config.linearAcceleration[4]
        )
    end
    if config.radialAcceleration then
        system:setRadialAcceleration(config.radialAcceleration[1], config.radialAcceleration[2])
    end
    if config.tangentialAcceleration then
        system:setTangentialAcceleration(config.tangentialAcceleration[1], config.tangentialAcceleration[2])
    end
    if config.linearDamping then
        system:setLinearDamping(config.linearDamping[1], config.linearDamping[2])
    end

    -- Appearance
    if config.sizes then
        system:setSizes(unpack(config.sizes))
    end
    if config.sizeVariation then
        system:setSizeVariation(config.sizeVariation)
    end
    if config.colors then
        -- Flatten the colors array for setColors: {{r,g,b,a}, {r,g,b,a}} -> r,g,b,a,r,g,b,a
        local flatColors: {number} = {}
        local colors <const> = config.colors
        for i = 1, #colors do
            local rgba = colors[i]
            for j = 1, #rgba do
                flatColors[#flatColors + 1] = rgba[j]
            end
        end
        system:setColors(unpack(flatColors))
    end
    if config.rotation then
        system:setRotation(config.rotation[1], config.rotation[2])
    end
    if config.spin then
        system:setSpin(config.spin[1], config.spin[2])
    end
    if config.spinVariation then
        system:setSpinVariation(config.spinVariation)
    end
    if config.relativeRotation ~= nil then
        system:setRelativeRotation(config.relativeRotation)
    end

    -- Texture
    if config.offset then
        system:setOffset(config.offset[1], config.offset[2])
    end
    if config.insertMode then
        system:setInsertMode(config.insertMode as love.graphics.ParticleInsertMode)
    end
end

function ParticleEmitter.fromConfig(_world: tecs.World, config: ParticleEmitterConfig): ParticleEmitter
    assert(config.texturePath, "ParticleEmitterConfig.texturePath is required")
    local texture = tecs_assets.loadImage(config.texturePath).value as love.graphics.Texture
    local bufferSize = config.bufferSize or 1000
    local system = lg_newParticleSystem(texture as love.graphics.Image, bufferSize)

    applyConfig(system, config)
    system:start()

    return ParticleEmitter(system, config)
end

tecs.newComponent({
    name = "ParticleEmitter",
    container = ParticleEmitter,
    fields = {"system", "config"},
    init = function(instance: ParticleEmitter, system: love.graphics.ParticleSystem, config?: ParticleEmitterConfig)
        instance.system = assert(system, "Missing ParticleEmitter system")
        instance.config = config
    end,

    serialize = function(instance: ParticleEmitter): {string: any}
        -- Emitters constructed directly from a ParticleSystem (without a
        -- config) cannot be serialized. Returning nil is the "skip this
        -- component" convention: MCP serialization checks the return value
        -- and omits the component when nil, so the entity round-trips
        -- without its emitter. Runtime-only emitters are therefore opt-in
        -- to persistence via the config argument.
        if not instance.config then
            return nil
        end
        return instance.config as {string: any}
    end,

    deserialize = function(world: tecs.World, data: {string: any}): ParticleEmitter
        local config = data as ParticleEmitterConfig
        return ParticleEmitter.fromConfig(world, config)
    end
})

function particles.plugin(world: tecs.World)
    local pipelineInstance <const> = world.resources[pipelinekey.PIPELINE]
    if not pipelineInstance then
        LOGGER:error("No render pipeline found in world resources")
        return
    end

    local emitterQuery = world:query({
        name = "particle_emitter.Query",
        include = {ParticleEmitter, Transform}
    })

    world:addSystem({
        name = "particle_emitter.Update",
        phase = tecs.phases.Update,
        run = function(dt: number)
            for archetype, len in emitterQuery:iter() do
                local emitters <const> = archetype:getMut(ParticleEmitter)
                local transforms <const> = archetype:get(Transform)
                for i = 1, len do
                    local emitter = emitters[i]
                    local transform = transforms[i]
                    local system <const> = emitter.system
                    system:setPosition(transform.x, transform.y)
                    system:update(dt)
                end
            end
        end
    })

    world:addSystem({
        name = "particle_emitter.Render",
        phase = tecs.phases.Draw,
        run = function()
            local cam <const> = pipelineInstance:getCamera()
            local viewW, viewH = cam:getVisibleDimensions()
            local camX, camY = cam:getPosition()

            for archetype, len in emitterQuery:iter() do
                local emitters <const> = archetype:get(ParticleEmitter)
                local transforms <const> = archetype:get(Transform)
                local archUnlit = archetype:get(Unlit) ~= nil

                for i = 1, len do
                    local emitter = emitters[i]
                    local transform = transforms[i]
                    local system = emitter.system

                    -- Heuristic visibility cull based on emitter position only.
                    -- This does NOT consider particle bounds, speed, lifetime, or
                    -- emission area; it's a cheap 2x-view-distance AABB check.
                    -- Fast-moving or long-lived particles spreading far from the
                    -- emitter may be culled visibly; tweak the factor if needed.
                    local tx, ty = transform.x, transform.y
                    local dx, dy = abs(tx - camX), abs(ty - camY)
                    if dx > viewW * 2 or dy > viewH * 2 then
                        goto continue
                    end

                    -- Attach world shader for depth interleaving
                    -- Use emitter position for depth (particles spread around this point)
                    local ws = pipelineInstance:worldShader():at(transform.layer, transform.z, tx, ty)
                    if archUnlit then ws:unlit() end
                    ws:attach()

                    -- Draw at (0, 0) because particles already have world positions
                    -- from setPosition() called in Update. Camera transform is already applied.
                    lg_draw(system, 0, 0)

                    pipelineInstance:detachWorldShader()

                    ::continue::
                end
            end
        end
    })
end

return particles
