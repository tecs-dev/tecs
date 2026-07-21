--- Process-local identity registry for worlds that own a gfx pipeline.
---
--- Public world IDs are generational handles. Sprite's existing 32-bit owner
--- field stores only the live registry slot plus the entity slot; component
--- references are invalid after their pipeline is shut down.

local tecs <const> = require("tecs")
local internal <const> = require("tecs.internal.types")
local IdAllocator <const> = require("tecs.internal.IdAllocator")

-- The 32-bit owner lane is deliberately not widened: 22 entity-slot bits
-- retain the 4M-entity ceiling, 6 bits allow 63 simultaneous render worlds,
-- and 4 generation bits reject stale component references after slot reuse.
local SLOT_BITS <const> = 6
local OWNER_GENERATION_COUNT <const> = 16
local SLOT_COUNT <const>: integer = (2^SLOT_BITS) as integer
local ENTITY_SLOT_COUNT <const>: integer = (2^22) as integer

local record worldregistry
    WORLD_ID: tecs.Key<integer>

    register: function(world: tecs.World): integer
    release: function(worldId: integer)
    resolve: function(worldId: integer): tecs.World
    ownerToken: function(world: tecs.World, entityId: integer): integer
    resolveOwner: function(token: integer): tecs.World, integer
end

worldregistry.WORLD_ID = tecs.newKey("tecs2d.gfx.worldId")

local worlds: {integer: tecs.World} = {}
local generations: {integer: integer} = {}
local freeSlots: {integer} = {}
local nextSlot: integer = 1

local function slotOf(worldId: integer): integer
    return (worldId % SLOT_COUNT) as integer
end

local function generationOf(worldId: integer): integer
    return math.floor(worldId / SLOT_COUNT)
end

function worldregistry.register(world: tecs.World): integer
    if world.resources[worldregistry.WORLD_ID] then
        error("gfx.newPipeline: world already owns a render pipeline", 2)
    end

    local slot: integer
    local freeCount = #freeSlots
    if freeCount > 0 then
        slot = freeSlots[freeCount]
        freeSlots[freeCount] = nil
    else
        if nextSlot >= SLOT_COUNT then
            error("gfx.newPipeline: at most 63 render worlds may be live", 2)
        end
        slot = nextSlot
        nextSlot = nextSlot + 1
    end

    local generation = ((generations[slot] or 0) + 1) as integer
    generations[slot] = generation
    worlds[slot] = world

    local worldId = (slot + generation * SLOT_COUNT) as integer
    world.resources[worldregistry.WORLD_ID] = worldId
    return worldId
end

function worldregistry.release(worldId: integer)
    local slot = slotOf(worldId)
    if slot == 0 or generations[slot] ~= generationOf(worldId) then return end
    local world = worlds[slot]
    if not world then return end
    worlds[slot] = nil
    world.resources[worldregistry.WORLD_ID] = nil
    freeSlots[#freeSlots + 1] = slot
end

function worldregistry.resolve(worldId: integer): tecs.World
    local slot = slotOf(worldId)
    if slot == 0 or generations[slot] ~= generationOf(worldId) then return nil end
    return worlds[slot]
end

function worldregistry.ownerToken(world: tecs.World, entityId: integer): integer
    local worldId = world.resources[worldregistry.WORLD_ID]
    if not worldId then
        error("render component entered a world without a gfx pipeline", 2)
    end
    local entitySlot = IdAllocator.slotOf(entityId)
    local ownerWorld = slotOf(worldId)
        + (generationOf(worldId) % OWNER_GENERATION_COUNT) * SLOT_COUNT
    return (ownerWorld * ENTITY_SLOT_COUNT + entitySlot) as integer
end

function worldregistry.resolveOwner(token: integer): tecs.World, integer
    local ownerWorld = math.floor(token / ENTITY_SLOT_COUNT) as integer
    local worldSlot = (ownerWorld % SLOT_COUNT) as integer
    local ownerGeneration = math.floor(ownerWorld / SLOT_COUNT) as integer
    local entitySlot = (token % ENTITY_SLOT_COUNT) as integer
    local world = worlds[worldSlot]
    if not world or entitySlot == 0
        or (generations[worldSlot] % OWNER_GENERATION_COUNT) ~= ownerGeneration then
        return nil, 0
    end

    local w = world as internal.WorldImpl
    local entity = w._slots[entitySlot]
    if not entity or entity.archetypeId == 0 then return nil, 0 end
    return world, IdAllocator.encodeId(entitySlot, entity.generation)
end

return worldregistry
