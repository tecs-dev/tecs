require("busted")

local luassert <const> = require("luassert")
local tecs <const> = require("tecs")
local objects <const> = require("tecs2d.tiled.internal.objects")
local parser <const> = require("tecs2d.tiled.internal.parser")

local Transform <const> = tecs.builtins.Transform
local ChildOf <const> = tecs.builtins.ChildOf

local record Health is tecs.Component
    amount: number
    metamethod __call: function(self, amount: number): Health
end

tecs.newComponent({
    name = "TiledObjectsHealth",
    container = Health,
    fields = {"amount"},
    defaults = {1},
})

local function mapWithObjects(objectList: {{string: any}}): objects.TilemapData
    return parser.parseTiledMap({
        width = 4,
        height = 4,
        tilewidth = 16,
        tileheight = 16,
        tilesets = {},
        layers = {
            {
                type = "objectgroup",
                name = "spawns",
                visible = true,
                opacity = 1,
                objects = objectList,
            },
        },
    })
end

describe("tiled object bindings", function()
    local world: tecs.World

    before_each(function()
        world = tecs.newWorld()
        world:newBundle("TiledEnemy", {required = {Transform, Health}})
    end)

    describe("registration", function()
        it("rejects an empty class", function()
            luassert.has_error(function()
                objects.register(world, "", {bundle = "TiledEnemy"})
            end)
        end)

        it("rejects a binding without a bundle", function()
            luassert.has_error(function()
                objects.register(world, "enemy", {} as objects.Binding)
            end)
        end)

        it("reports an unbound class as nil", function()
            luassert.is_nil(objects.binding(world, "enemy"))
        end)

        it("keeps bindings separate per world", function()
            local other = tecs.newWorld()
            other:newBundle("TiledEnemy", {required = {Transform}})

            objects.register(world, "enemy", {bundle = "TiledEnemy"})

            luassert.is_not_nil(objects.binding(world, "enemy"))
            luassert.is_nil(objects.binding(other, "enemy"))
        end)
    end)

    describe("object center", function()
        it("centers a rectangle from its top-left anchor", function()
            local x, y = objects.center({x = 10, y = 20, width = 8, height = 4} as objects.ObjectData)
            luassert.equals(14, x)
            luassert.equals(22, y)
        end)

        it("centers a tile object from its bottom-left anchor", function()
            local x, y = objects.center(
                {x = 10, y = 20, width = 8, height = 4, gid = 5} as objects.ObjectData)
            luassert.equals(14, x)
            luassert.equals(18, y)
        end)
    end)

    describe("spawning", function()
        it("spawns nothing when no class is bound", function()
            local map = mapWithObjects({
                {id = 1, name = "a", type = "enemy", x = 0, y = 0, width = 16, height = 16},
            })

            luassert.equals(0, objects.spawnAll(world, map, 0, 0, 1, world:spawn()))
        end)

        it("spawns bound objects through the bundle", function()
            objects.register(world, "enemy", {
                bundle = "TiledEnemy",
                values = function(_w: tecs.World, object: objects.ObjectData): {tecs.Component}
                    return {Health(object.properties.health as number or 10)}
                end,
            })

            local map = mapWithObjects({
                {
                    id = 1, name = "grunt", type = "enemy",
                    x = 0, y = 0, width = 16, height = 16,
                    properties = {{name = "health", type = "int", value = 42}},
                },
                {id = 2, name = "prop", type = "decor", x = 32, y = 32, width = 16, height = 16},
            })

            local mapEntity = world:spawn()
            luassert.equals(1, objects.spawnAll(world, map, 0, 0, 1, mapEntity))
            world:commit()

            local found = 0
            for archetype, len in world:query({include = {Transform, Health}}):iter() do
                local healths = archetype:get(Health)
                local transforms = archetype:get(Transform)
                for row = 1, len do
                    found = found + 1
                    luassert.equals(42, healths[row].amount)
                    luassert.equals(8, transforms[row].x)
                    luassert.equals(8, transforms[row].y)
                end
            end
            luassert.equals(1, found, "expected one spawned enemy")
        end)

        it("parents spawned objects to the map entity", function()
            objects.register(world, "enemy", {
                bundle = "TiledEnemy",
                values = function(): {tecs.Component} return {Health(1)} end,
            })

            local map = mapWithObjects({
                {id = 1, name = "grunt", type = "enemy", x = 0, y = 0, width = 16, height = 16},
            })
            local mapEntity = world:spawn()
            objects.spawnAll(world, map, 0, 0, 1, mapEntity)
            world:commit()

            local children = 0
            world:targets(mapEntity, ChildOf, function(_child: integer)
                children = children + 1
            end)
            luassert.equals(1, children)

            world:despawn(mapEntity)
            world:commit()

            local remaining = 0
            for _archetype, len in world:query({include = {Health}}):iter() do
                remaining = remaining + len
            end
            luassert.equals(0, remaining, "despawning the map despawns its objects")
        end)

        it("offsets objects by the map origin and layer offset", function()
            objects.register(world, "enemy", {
                bundle = "TiledEnemy",
                values = function(): {tecs.Component} return {Health(1)} end,
            })

            local map = mapWithObjects({
                {id = 1, name = "grunt", type = "enemy", x = 0, y = 0, width = 0, height = 0},
            })
            objects.spawnAll(world, map, 100, 200, 1, world:spawn())
            world:commit()

            for archetype, len in world:query({include = {Transform, Health}}):iter() do
                local transforms = archetype:get(Transform)
                for row = 1, len do
                    luassert.equals(100, transforms[row].x)
                    luassert.equals(200, transforms[row].y)
                end
            end
        end)

        it("raises when the bound bundle is not registered", function()
            objects.register(world, "enemy", {bundle = "Missing"})
            local map = mapWithObjects({
                {id = 1, name = "grunt", type = "enemy", x = 0, y = 0, width = 16, height = 16},
            })

            luassert.has_error(function()
                objects.spawnAll(world, map, 0, 0, 1, world:spawn())
            end)
        end)

        it("raises when the bundle does not require Transform first", function()
            world:newBundle("BadEnemy", {required = {Health, Transform}})
            objects.register(world, "enemy", {bundle = "BadEnemy"})
            local map = mapWithObjects({
                {id = 1, name = "grunt", type = "enemy", x = 0, y = 0, width = 16, height = 16},
            })

            luassert.has_error(function()
                objects.spawnAll(world, map, 0, 0, 1, world:spawn())
            end)
        end)
    end)
end)
