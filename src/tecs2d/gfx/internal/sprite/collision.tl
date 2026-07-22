--- Sprite collision system
---
--- Creates Box2D fixtures from sprite sheet slice data. Enables defining collision boxes
--- visually in Aseprite and having them automatically applied to physics bodies.

local tecs <const> = require("tecs")
local sprite_sheet <const> = require("tecs2d.gfx.internal.sprite.sheet")

local record sprite_collision
    --- Configuration for a single slice-based fixture
    record SliceConfig
        shape: string           -- "circle" or "rectangle"
        sensor: boolean
        categories: integer
        mask: integer
        groupIndex: integer
        restitution: number
        friction: number
    end

    --- Component for sprite-based collision
    --- Add this component alongside a Sprite to enable slice-based physics collision.
    --- Automatically adds Collider and RigidBody/StaticBody components on spawn.
    record SpriteCollision is tecs.Component
        --- Body type: "dynamic" or "static"
        bodyType: string
        --- Whether an auto-attached dynamic rigid body should stay upright.
        fixedRotation: boolean
        --- Map of slice name to config or template name
        slices: {string: SliceConfig | string}
        --- Internal: tracks if fixtures have been created
        _setupComplete: boolean

        --- Register a named collision template usable as a `slices` value.
        addTemplate: function(name: string, config: SliceConfig)

        --- Get a registered collision template by name.
        getTemplate: function(name: string): SliceConfig
    end

    --- Register a named collision template
    addTemplate: function(name: string, config: SliceConfig)

    --- Get a registered collision template by name
    getTemplate: function(name: string): SliceConfig

    --- Setup collision fixtures from slice data
    --- Called after physics body is created
    --- Returns true if collision was set up successfully
    setupFixtures: function(
        world: tecs.World,
        entityId: integer,
        sheetVal: sprite_sheet.SpriteSheet,
        config: SpriteCollision,
        lp: any  -- love.physics module
    ): boolean

    --- Install the SpriteCollision body-init query observer (attaches
    --- StaticBody or RigidBody based on `bodyType`). Called by the
    --- sprite plugin when physics is available.
    plugin: function(world: tecs.World)
end

local SpriteCollision <const> = sprite_collision.SpriteCollision

tecs.newComponent({
    name = "SpriteCollision",
    container = SpriteCollision,
    new = function(raw: {string: any}): sprite_collision.SpriteCollision
        local data = raw as sprite_collision.SpriteCollision
        data.bodyType = data.bodyType or "dynamic"
        if data.fixedRotation == nil then
            data.fixedRotation = true
        end
        data.slices = data.slices or {}
        data._setupComplete = false
        return data
    end,

    -- Collider/body setup is handled by the SpriteCollisionBodyInit
    -- query observer below so the collider gets a real default
    -- instance via `.new({})` rather than the zero-arg hot path.
})

-- Attach StaticBody or RigidBody based on SpriteCollision.bodyType
-- when the component enters an entity. Registered by `sprite_collision.plugin`.
function sprite_collision.plugin(world: tecs.World)
    local physics = require("tecs2d.physics")
    local Collider = physics.Collider
    world:query({
        name = "sprite_collision.BodyInit",
        include = {SpriteCollision},
        onEntitiesAdded = function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
            local sc = archetype:get(SpriteCollision) as {sprite_collision.SpriteCollision}
            local entities = archetype.entities
            for row = firstRow, lastRow do
                local self = sc[row]
                if not self then goto continue end
                local id = entities[row]
                if not world:has(id, Collider) then
                    world:set(id, Collider.new({}))
                end
                if self.bodyType == "static" then
                    if not world:has(id, physics.StaticBody) then
                        world:set(id, physics.StaticBody())
                    end
                else
                    if not world:has(id, physics.RigidBody) then
                        world:set(id, physics.RigidBody.new({
                            fixedRotation = self.fixedRotation,
                        }))
                    end
                end
                ::continue::
            end
        end,
    })
end

-- Module-level template storage
local templates: {string: sprite_collision.SliceConfig} = {}

function sprite_collision.addTemplate(name: string, config: sprite_collision.SliceConfig)
    templates[name] = config
end

function sprite_collision.getTemplate(name: string): sprite_collision.SliceConfig
    return templates[name]
end

-- Public surface: templates register through the component container
-- (`gfx.SpriteCollision.addTemplate(...)`).
SpriteCollision.addTemplate = sprite_collision.addTemplate
SpriteCollision.getTemplate = sprite_collision.getTemplate

-- Resolve config (template name string or inline config table)
local function resolveSliceConfig(configOrName: sprite_collision.SliceConfig | string): sprite_collision.SliceConfig
    if type(configOrName) == "string" then
        local template = templates[configOrName as string]
        if not template then
            error("Unknown collision template: " .. (configOrName as string))
        end
        return template
    end
    return configOrName as sprite_collision.SliceConfig
end

function sprite_collision.setupFixtures(
    world: tecs.World,
    entityId: integer,
    sheetVal: sprite_sheet.SpriteSheet,
    config: sprite_collision.SpriteCollision,
    lp: any
): boolean
    -- Get physics components (Collider must have body created by physics system)
    -- NOTE: Using direct require instead of tecs2d.physics to avoid circular dependency
    local physics = require("tecs2d.physics")
    local Collider = physics.Collider
    local Transform = tecs.builtins.Transform

    local collider = world:get(entityId, Collider)
    if not collider or not collider.body then
        return false
    end

    local transform = world:get(entityId, Transform)
    local body = collider.body
    local spriteW, spriteH = sheetVal:getSpriteSize()
    local pivotX, pivotY = spriteW / 2, spriteH / 2

    -- Ensure shapeList array exists
    if not collider.shapeList then
        collider.shapeList = {}
    end

    -- Cast love.physics for indexing
    local lpFuncs = lp as {string: function(any...): any}

    for sliceName, configOrName in pairs(config.slices) do
        local sliceConfig = resolveSliceConfig(configOrName)
        local slice = sheetVal:getSlice(sliceName)

        if not slice or not slice.keys or not slice.keys[1] then
            error("Collision slice '" .. sliceName .. "' not found in sprite sheet. Add a slice in Aseprite.")
        end

        local key = slice.keys[1]  -- Use first frame only

        -- Calculate offset from sprite center to slice center
        local sliceCenterX = key.x + key.w / 2
        local sliceCenterY = key.y + key.h / 2
        local offsetX = sliceCenterX - pivotX
        local offsetY = sliceCenterY - pivotY

        -- Create shape based on config (Love2D 12 API: shapes are created attached to body)
        local shape: love.physics.Shape
        if sliceConfig.shape == "circle" then
            local radius = math.min(key.w, key.h) / 2
            shape = lpFuncs["newCircleShape"](body, offsetX, offsetY, radius) as love.physics.Shape
        else
            -- Default to rectangle
            shape = lpFuncs["newRectangleShape"](body, offsetX, offsetY, key.w, key.h, 0) as love.physics.Shape
        end

        -- Configure shape (in Love2D 12, shapes have all fixture methods)
        shape:setDensity(1.0)

        -- Set user data for contact callbacks (must match physics.ShapeData structure)
        shape:setUserData({
            entity = entityId,
            layer = transform and transform.layer or 0,
            categories = sliceConfig.categories or collider.categories,
            mask = sliceConfig.mask or collider.mask,
            name = sliceName
        })

        -- Apply shape properties from config
        shape:setSensor(sliceConfig.sensor or false)
        shape:setRestitution(sliceConfig.restitution or 0)
        shape:setFriction(sliceConfig.friction or 0.3)

        -- Apply collision filtering
        if sliceConfig.categories or sliceConfig.mask or sliceConfig.groupIndex then
            shape:setFilterData(
                sliceConfig.categories or 0xFFFF,
                sliceConfig.mask or 0xFFFF,
                sliceConfig.groupIndex or 0
            )
        end

        -- Store shape reference
        collider.shapeList[#collider.shapeList + 1] = shape
    end

    return true
end

return sprite_collision
