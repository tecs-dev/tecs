--- TextureArray Component Registry
--- Creates tag components on-demand for each texture array index.
--- This enables archetype-based grouping by texture array for efficient GPU batching.
---
--- When a sprite is assigned to a texture array (e.g., array index 3), it gets
--- a TextureArray3 tag component. Combined with size tier components (SmallTextureBucket)
--- and blend mode components, this creates archetypes like:
---   {Sprite, Transform, SmallTextureBucket, TextureArray3, BlendAdd}
---
--- Usage:
---   local TextureArray = require("tecs2d.gfx.internal.sprite.TextureArray")
---   local comp = TextureArray.get(3)  -- Gets or creates TextureArray3
---   local idx = TextureArray.getArrayIndex(archetype)  -- Returns 3 if has TextureArray3

local tecs <const> = require("tecs")

local type tecs_Component = tecs.Component
local type tecs_Archetype = tecs.Archetype

local record TextureArray
    --- Get or create a TextureArray tag component for the given array index.
    --- Can also be called as TextureArray(N) via __call metamethod.
    --- @param arrayIndex The 1-based texture array index
    --- @return The tag component for this array index
    get: function(arrayIndex: integer): tecs_Component

    --- Get the array index from an archetype by checking which TextureArray component it has.
    --- @param archetype The archetype to check
    --- @return The array index (1-based) or 0 if not found
    getArrayIndex: function(archetype: tecs_Archetype): integer

    --- Get all registered TextureArray components.
    --- @return Map of arrayIndex to component
    getAll: function(): {integer: tecs_Component}

    --- Callable: TextureArray(N) returns cached component for array index N
    metamethod __call: function(self: TextureArray, arrayIndex: integer): tecs_Component
end

-- Storage for dynamically created TextureArray components
local components: {integer: tecs_Component} = {}

-- Track max array index for efficient lookup
local maxArrayIndex = 0

function TextureArray.get(arrayIndex: integer): tecs_Component
    local comp = components[arrayIndex]
    if not comp then
        comp = tecs.newTagComponent({
            name = "TextureArray" .. arrayIndex,
            transient = true,
        })
        components[arrayIndex] = comp
        if arrayIndex > maxArrayIndex then
            maxArrayIndex = arrayIndex
        end
    end
    return comp
end

function TextureArray.getArrayIndex(archetype: tecs_Archetype): integer
    for arrayIdx = 1, maxArrayIndex do
        local comp = components[arrayIdx]
        if comp and archetype:get(comp) then
            return arrayIdx
        end
    end
    return 0
end

function TextureArray.getAll(): {integer: tecs_Component}
    return components
end

-- Make TextureArray(N) callable, just like ChildOf(N)
local mt: metatable<TextureArray> = {
    __call = function(_self: TextureArray, arrayIndex: integer): tecs_Component
        return TextureArray.get(arrayIndex)
    end
}

return setmetatable(TextureArray, mt)
