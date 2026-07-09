local tecs <const> = require("tecs")
local pipeline_key <const> = require("tecs2d.gfx.internal.pipeline_key")
local gpuBuffer <const> = require("tecs2d.gfx.internal.gpu.buffer")
local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")
local shaderUtils <const> = require("tecs2d.gfx.internal.gpu.shaders")
local C <const> = require("ffi")

local Transform <const> = tecs.builtins.Transform

-- Compile light cull shader (handles both visibility culling and tile assignment)
local lightCullShader <const> = love.graphics.newComputeShader(shaderUtils.LIGHT_CULL)

local LOGGER <const> = require("tecs.utils.logging").getLogger("tecs2d.gfx.light")

--- Configuration table for Light component
local record LightConfig
    --- Light radius (falloff distance). Default: 200
    radius: number
    --- Light intensity multiplier. Default: 1.0
    intensity: number
    --- Light height above 2D plane (0.0 - 1.0, normalized). Default: 0.15
    --- Higher values create more uniform lighting; lower values create dramatic side-lighting.
    height: number
    --- Red color component (0-1). Default: 1.0
    r: number
    --- Green color component (0-1). Default: 1.0
    g: number
    --- Blue color component (0-1). Default: 1.0
    b: number
    --- Spotlight direction angle in radians (0 = right, pi/2 = down). Default: 0
    direction: number
    --- Spotlight outer cone half-angle in radians (0 = point light). Default: 0
    coneAngle: number
    --- Spotlight inner cone half-angle for soft edges. Default: 0
    innerConeAngle: number
    --- Shadow penumbra softness (0-1). Default: 0.5
    --- 0 = hard shadows, 1 = maximum softness.
    penumbra: number
    --- Cookie ID (integer) or name (string). 0 = no cookie. Default: 0
    cookie: integer | string
    --- Cookie rotation in radians. Default: 0
    cookieRotation: number
    --- Cookie scale factor (1.0 = fills light radius). Default: 1.0
    cookieScale: number
    --- Auto-add spotlight direction to cookieRotation. Default: false
    cookieAlignToCone: boolean
end

local record light
    --- Light component for dynamic lights (point lights and spotlights).
    --- Point light: omnidirectional (coneAngle = 0 or nil)
    --- Spotlight: directional cone (coneAngle > 0)
    ---
    --- Can be constructed with a config table or positional arguments:
    ---   Light.new({ radius = 200, intensity = 1.5, height = 0.3 })
    ---   Light(200, 1.5, 0.3)  -- radius, intensity, height
    record Light is tecs.Component
        --- Light radius (falloff distance)
        radius: number

        --- Light intensity multiplier
        intensity: number

        --- Light height above 2D plane (0.0 - 1.0, normalized)
        height: number

        --- Light color (RGB, 0-1)
        r: number
        g: number
        b: number

        --- Spotlight: direction angle in radians (0 = right, pi/2 = down)
        --- Ignored for point lights (when coneAngle is 0 or nil)
        direction: number

        --- Spotlight: outer cone half-angle in radians (0 = point light)
        --- Example: math.pi/6 = 30 degree cone (60 degrees total)
        coneAngle: number

        --- Spotlight: inner cone half-angle for soft edges (0 = hard edge)
        --- Light is full intensity inside inner cone, fades to outer cone
        innerConeAngle: number

        --- Shadow penumbra softness multiplier (default: 0.5).
        --- Higher values = softer shadow edges, lower values = harder edges.
        --- 0 produces fully hard shadows.
        penumbra: number

        --- Cookie ID (integer) or name (string, resolved during GPUSync). 0 = no cookie.
        cookie: integer | string

        --- Cookie rotation in radians.
        cookieRotation: number

        --- Cookie scale factor (1.0 = fills light radius).
        cookieScale: number

        --- Auto-add spotlight direction to cookieRotation.
        cookieAlignToCone: boolean

        metamethod __call: function(
            self,
            radius?: number,
            intensity?: number,
            height?: number,
            r?: number,
            g?: number,
            b?: number
        ): Light

        new: function(config: LightConfig): Light
    end

    LightConfig: LightConfig

    plugin: function(world: tecs.World)
end

local Light <const> = light.Light

tecs.newComponent({
    name = "Light",
    container = Light,
    fields = {
        "radius", "intensity", "height", "r", "g", "b",
        "direction", "coneAngle", "innerConeAngle", "penumbra",
        "cookie", "cookieRotation", "cookieScale", "cookieAlignToCone"
    },
    defaults = {200, 1.0, 0.15, 1.0, 1.0, 1.0, 0, 0, 0, 0.5, 0, 0, 1.0, false},
    new = function(config: {string: any}): Light
        local c = config as LightConfig
        return {
            radius = c.radius or 200,
            intensity = c.intensity or 1.0,
            height = c.height or 0.15,
            r = c.r or 1.0,
            g = c.g or 1.0,
            b = c.b or 1.0,
            direction = c.direction or 0,
            coneAngle = c.coneAngle or 0,
            innerConeAngle = c.innerConeAngle or 0,
            penumbra = c.penumbra or 0.5,
            cookie = c.cookie or 0,
            cookieRotation = c.cookieRotation or 0,
            cookieScale = c.cookieScale or 1.0,
            cookieAlignToCone = c.cookieAlignToCone or false,
        }
    end,
})

-- FFI light instance record (matches GPULightInstance in gpu/types.tl)
local record LightInstanceFFI
    x: number
    y: number
    z: number      -- height
    radius: number
    intensity: number
    r: number
    g: number
    b: number
    -- Spotlight properties (vec4 2): precomputed direction + cone cosines
    spotDirX: number           -- cos(direction), precomputed on CPU
    spotDirY: number           -- sin(direction), precomputed on CPU
    cosConeAngle: number       -- cos(outer cone half-angle), 1.0 = point light
    cosInnerConeAngle: number  -- cos(inner cone half-angle) for soft edges
    -- Extra params (vec4 3)
    penumbra: number
    cookieSlice: number
    cookieScaleRotX: number
    cookieScaleRotY: number
end

function light.plugin(world: tecs.World)
    local pipelineInstance <const> = world.resources[pipeline_key.PIPELINE as tecs.Key<gpuTypes.PipelineInternal>]
    if not pipelineInstance then
        LOGGER:error("No render pipeline found in world resources")
        return
    end

    -- Get the GPU renderer from pipeline
    local renderer = pipelineInstance:getRenderer()
    if not renderer then
        LOGGER:error("No GPU renderer available")
        return
    end

    -- Entity ID -> GPU slot mapping
    local entitySlots: {integer: integer} = {}

    local lg <const> = love.graphics
    local ceil <const> = math.ceil
    local gpuRenderer = renderer as gpuTypes.Renderer
    local DEFAULT_CAPACITY <const> = 256
    local initialCapacity = gpuRenderer.config.sizeHints["lights"] or DEFAULT_CAPACITY

    -- Create light buffers locally (plugin-owned)
    local lightBuffer = gpuBuffer.new(gpuTypes.LIGHT_FORMAT, initialCapacity, gpuTypes.LIGHT_CTYPE)
    local lightOutputBuffer = lg.newBuffer(gpuTypes.LIGHT_FORMAT, initialCapacity, {usage = "dynamic", shaderstorage = true})
    local lightVisibleCountBuffer = lg.newBuffer({{format = "uint32"}}, 1, {usage = "dynamic", shaderstorage = true})

    -- Create light visible count reset data (single uint32 = 0)
    local lightCountResetData = love.data.newByteData(4)
    local lightCountPtr = C.cast("uint32_t*", lightCountResetData:getFFIPointer()) as {integer}
    lightCountPtr[0] = 0

    -- Growth callback: resize output buffer when input buffer grows
    lightBuffer.onGrow = function(_: integer, newCap: integer)
        lightOutputBuffer = lg.newBuffer(gpuTypes.LIGHT_FORMAT, newCap, {usage = "dynamic", shaderstorage = true})
        -- Update renderer reference so renderLighting sees the new buffer
        gpuRenderer.lightOutputBuffer = lightOutputBuffer
    end

    -- Store references on renderer for renderLighting (cross-cutting concern)
    gpuRenderer.lightOutputBuffer = lightOutputBuffer
    gpuRenderer.lightVisibleCountBuffer = lightVisibleCountBuffer

    -- Register light render plugin (upload + cull + tile binning)
    gpuRenderer:registerPlugin({
        name = "Light",
        upload = function(_r: gpuTypes.Renderer)
            lightBuffer:upload()
        end,
        resetIndirect = nil,
        cull = function(r: gpuTypes.Renderer, _cullParamsBuffer: love.graphics.Buffer)
            -- Screen-space layers are always unlit; skip light culling to preserve
            -- world-phase tile data (needed by sprite cull for drop shadows next frame)
            if r._renderPhase == "screen" then return end

            -- Always reset tile counts (even with 0 lights, so fragment shader sees zeros)
            r.tileLightCountBuffer:setArrayData(r.tileCountResetData)

            local lightCount = lightBuffer.count
            if lightCount > 0 then
                -- Single-pass: cull + tile assignment in one dispatch
                -- (avoids cross-dispatch memory barrier issues on Metal)
                lightVisibleCountBuffer:setArrayData(lightCountResetData)
                lightCullShader:send("TotalLights", lightCount)
                lightCullShader:send("CameraViewport", r._cullViewport)
                lightCullShader:send("TileViewport", r._tileViewport)
                lightCullShader:send("ShadowMargin", r.config.shadowMargin or 200.0)
                lightCullShader:send("LightInput", lightBuffer.handle)
                lightCullShader:send("LightOutput", lightOutputBuffer)
                lightCullShader:send("VisibleCount", lightVisibleCountBuffer)
                lightCullShader:send("TileLightCounts", r.tileLightCountBuffer)
                lightCullShader:send("TileLightIndices", r.tileLightIndexBuffer)
                lightCullShader:send("TileGridDims", {r._effectiveTileGridW, r._effectiveTileGridH})
                lg.dispatchThreadgroups(lightCullShader, ceil(lightCount / 256), 1, 1)
            end
        end,
    })

    -- Helper function to write light instance data to FFI buffer
    -- NOTE: We access lightBuffer.dataPtr fresh each time because the buffer can grow
    -- and reallocate, which would invalidate any cached pointer.
    -- Uses Teal's `as` assertion (zero cost) instead of C.cast() (creates new cdata object).
    local cos <const> = math.cos
    local sin <const> = math.sin

    local function writeLightInstance(
        slot: integer,
        x: number, y: number, height: number, radius: number,
        intensity: number, r: number, g: number, b: number,
        direction: number, coneAngle: number, innerConeAngle: number,
        penumbra: number,
        cookieId: integer, cookieRotation: number, cookieScale: number,
        cookieAlignToCone: boolean, gameTime: number
    )
        local dataPtr = lightBuffer.dataPtr as {integer: LightInstanceFFI}
        local inst = dataPtr[slot]
        -- Floor position to prevent pixel snaking
        inst.x = math.floor(x)
        inst.y = math.floor(y)
        -- Clamp numeric inputs to non-negative values. Negative radius/
        -- intensity/height/penumbra produce meaningless GPU behavior.
        inst.z = height < 0 and 0 or height
        inst.radius = radius < 0 and 0 or radius
        inst.intensity = intensity < 0 and 0 or intensity
        inst.r = r
        inst.g = g
        inst.b = b
        -- Precompute direction vector + cone cosines for GPU (avoids trig in fragment shader)
        -- cos(0)=1.0 for cosConeAngle signals point light to the shader.
        -- Clamp coneAngle >= 0 and ensure innerConeAngle <= coneAngle so the
        -- spotlight falloff doesn't invert.
        if coneAngle < 0 then coneAngle = 0 end
        if innerConeAngle < 0 then innerConeAngle = 0 end
        if innerConeAngle > coneAngle then innerConeAngle = coneAngle end
        inst.spotDirX = cos(direction)
        inst.spotDirY = sin(direction)
        inst.cosConeAngle = cos(coneAngle)
        inst.cosInnerConeAngle = cos(innerConeAngle)
        inst.penumbra = penumbra < 0 and 0 or penumbra

        -- Cookie (gobo) projection data
        if cookieId > 0 then
            local cookieRegistry = gpuRenderer._cookieRegistry
            local cookieData = cookieRegistry and cookieRegistry[cookieId]
            if cookieData then
                local sliceIndex: integer
                if cookieData.frameCount > 1 and cookieData.tagName then
                    local frame = cookieData.sheet:getAnimationFrame(cookieData.tagName, gameTime)
                    sliceIndex = cookieData.baseSlice + frame - 1
                else
                    sliceIndex = cookieData.baseSlice
                end
                inst.cookieSlice = sliceIndex as number
                local rot = cookieRotation
                if cookieAlignToCone then
                    rot = direction + rot
                end
                -- Clamp cookieScale away from zero to avoid divide-by-zero.
                local safeScale = cookieScale
                if safeScale < 1e-6 then safeScale = 1e-6 end
                local invScale = 1.0 / safeScale
                inst.cookieScaleRotX = cos(rot) * invScale
                inst.cookieScaleRotY = sin(rot) * invScale
            else
                inst.cookieSlice = -1.0
                inst.cookieScaleRotX = 0.0
                inst.cookieScaleRotY = 0.0
            end
        else
            inst.cookieSlice = -1.0
            inst.cookieScaleRotX = 0.0
            inst.cookieScaleRotY = 0.0
        end
    end

    -- Query for lights with transforms. The removal hook fires when an
    -- entity stops matching (Light or Transform removed, Disabled added,
    -- or despawn), so the GPU slot is freed in every case; without it a
    -- removed light kept rendering forever because the cull shader's
    -- TotalLights still counted its slot.
    local lightQuery = world:query({
        name = "light.GPUSync",
        include = {Light, Transform},
        onEntitiesRemoved = function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
            local entities = archetype.entities
            for row = firstRow, lastRow do
                local slot = entitySlots[entities[row]]
                if slot then
                    lightBuffer:free(slot)
                    entitySlots[entities[row]] = nil
                end
            end
        end,
    })

    -- Sync light data to GPU buffer each frame
    world:addSystem({
        name = "light.GPUSync",
        phase = tecs.phases.PreRender,
        run = function()
            local gameTime = gpuRenderer._cullGlobalTime or 0.0
            local cookieNameToId = gpuRenderer._cookieNameToId
            for archetype, len, entities in lightQuery:iter() do
                local lights = archetype:get(Light)
                local transforms = archetype:get(Transform)

                for i = 1, len do
                    local entityId = entities[i]
                    local lightComp = lights[i]
                    local transform = transforms[i]

                    -- Get or allocate GPU slot
                    local slot = entitySlots[entityId]
                    if not slot then
                        slot = lightBuffer:allocate()
                        entitySlots[entityId] = slot
                    end

                    -- Resolve cookie: string -> integer ID
                    local cookieId: integer = 0
                    local cookie = lightComp.cookie
                    if cookie then
                        if type(cookie) == "string" then
                            cookieId = (cookieNameToId and cookieNameToId[cookie as string]) or 0
                        else
                            cookieId = cookie as integer
                        end
                    end

                    -- Write to GPU buffer
                    writeLightInstance(
                        slot,
                        transform.x, transform.y,
                        lightComp.height, lightComp.radius,
                        lightComp.intensity,
                        lightComp.r, lightComp.g, lightComp.b,
                        lightComp.direction or 0,
                        lightComp.coneAngle or 0,
                        lightComp.innerConeAngle or 0,
                        lightComp.penumbra,
                        cookieId,
                        lightComp.cookieRotation or 0,
                        lightComp.cookieScale or 1.0,
                        lightComp.cookieAlignToCone or false,
                        gameTime
                    )

                    -- Mark dirty
                    lightBuffer:markDirty(slot)
                end
            end
        end
    })

end

return light
