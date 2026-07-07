--- Anchor component for viewport-relative positioning.
--- Positions entities relative to viewport bounds using anchor percentages and pixel offsets.
--- Resolves viewport bounds based on the entity's layer coordinate space (screen/virtual/world).

local tecs <const> = require("tecs")
local pipeline_key <const> = require("tecs2d.gfx.internal.pipeline_key")
local bit <const> = require("bit")

local Transform <const> = tecs.builtins.Transform

local type Component = tecs.Component
local type World = tecs.World

--- Positions an entity relative to its viewport using anchor percentages and pixel offsets.
--- `anchorX`/`anchorY` are 0-1 percentages (0=left/top, 0.5=center, 1=right/bottom).
--- `offsetX`/`offsetY` are pixel offsets from the anchor point.
local record Anchor is Component
    --- Horizontal anchor percentage (0=left, 0.5=center, 1=right).
    anchorX: number

    --- Vertical anchor percentage (0=top, 0.5=center, 1=bottom).
    anchorY: number

    --- Horizontal pixel offset from anchor point.
    offsetX: number

    --- Vertical pixel offset from anchor point.
    offsetY: number

    --- Creates a new Anchor component.
    ---
    --- @param anchorX Horizontal anchor (0-1). 0=left, 0.5=center, 1=right.
    --- @param anchorY Vertical anchor (0-1). 0=top, 0.5=center, 1=bottom.
    --- @param offsetX Pixel offset from anchor X (defaults to 0).
    --- @param offsetY Pixel offset from anchor Y (defaults to 0).
    --- @return the created Anchor component.
    metamethod __call: function(
        self,
        anchorX: number,
        anchorY: number,
        offsetX?: number,
        offsetY?: number
    ): Anchor

    --- Plugin to install Anchor systems.
    plugin: function(world: World)
end

tecs.newFFIComponent({
    name = "Anchor",
    container = Anchor,
    fields = {
        {"anchorX", "float"},
        {"anchorY", "float"},
        {"offsetX", "float"},
        {"offsetY", "float"}
    },
    defaults = {0, 0, 0, 0}
})

-- Pipeline type for accessing viewport dimensions
local record PipelineData
    screenWidth: integer
    screenHeight: integer
    virtualWidth: integer
    virtualHeight: integer
    screenSpaceMask: integer
    virtualCoordsMask: integer
    getCamera: function(self): CameraData
end

local record CameraData
    getVisibleCorners: function(self): number, number, number, number
end

function Anchor.plugin(world: World)
    local anchorQuery = world:query({
        name = "ComputeAnchor",
        include = {Anchor, Transform}
    })

    local pipeline: PipelineData

    world:addSystem({
        name = "ui.ComputeAnchor",
        phase = tecs.phases.PostUpdate,
        after = {"ui.ComputeLayoutBox", "ui.ComputeFitContent"},
        before = {"ui.RelativeTransform"},
        run = function()
            -- Lazy-load pipeline resource (not available at registration time)
            if not pipeline then
                pipeline = world.resources[pipeline_key.PIPELINE] as PipelineData
                if not pipeline then return end
            end

            local screenW = pipeline.screenWidth
            local screenH = pipeline.screenHeight
            local virtualW = pipeline.virtualWidth
            local virtualH = pipeline.virtualHeight
            local screenSpaceMask = pipeline.screenSpaceMask
            local virtualCoordsMask = pipeline.virtualCoordsMask

            for archetype, len in anchorQuery:iter() do
                local anchors = archetype:get(Anchor)
                local transforms = archetype:getMut(Transform)

                for row = 1, len do
                    local anchor = anchors[row]
                    local transform = transforms[row]
                    local layer = transform.layer

                    -- Determine viewport bounds from layer space. Layers
                    -- outside 1..32 (e.g. a zero-initialized batchSpawn
                    -- Transform) get no mask bit: LuaJIT masks shift
                    -- counts to 5 bits, so layer 0 would otherwise test
                    -- bit 31 and silently misclassify the space.
                    local vpLeft: number = 0
                    local vpTop: number = 0
                    local vpWidth: number
                    local vpHeight: number
                    local bitIndex = layer - 1
                    local layerBit = 0
                    if bitIndex >= 0 and bitIndex < 32 then
                        layerBit = bit.lshift(1, bitIndex)
                    end

                    local isScreenSpace = bit.band(screenSpaceMask, layerBit) ~= 0
                    if isScreenSpace then
                        local isVirtual = bit.band(virtualCoordsMask, layerBit) ~= 0
                        if isVirtual then
                            vpWidth = virtualW
                            vpHeight = virtualH
                        else
                            vpWidth = screenW
                            vpHeight = screenH
                        end
                    else
                        -- World-space: use camera visible bounds
                        local cam = pipeline:getCamera()
                        local x1, y1, x2, y2 = cam:getVisibleCorners()
                        vpLeft = x1
                        vpTop = y1
                        vpWidth = x2 - x1
                        vpHeight = y2 - y1
                    end

                    transform.x = vpLeft + anchor.anchorX * vpWidth + anchor.offsetX
                    transform.y = vpTop + anchor.anchorY * vpHeight + anchor.offsetY
                end
            end
        end
    })
end

return Anchor
