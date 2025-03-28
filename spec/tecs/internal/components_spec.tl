require("busted")
local tecs <const> = require("tecs")
local components <const> = require("tecs.internal.components")
local luassert <const> = require("luassert")

describe("components", function()
    describe("creates new components", function()
        it("registeres component", function()
            local container: tecs.Component = {}
            local component = tecs.newComponent({
                name = "MyComponent",
                container = container
            })

            luassert.is_not_nil(component, "MyComponent should not be nil")
            luassert.is_not_nil(component.componentId, "MyComponent should have an ID")
            luassert.is_not_nil(component.componentName, "MyComponent should have a name")
            luassert.is_not_nil(component.componentType, "MyComponent should have a type")
            -- Regular components don't have exclusiveRelationship property - that's only for relationships
            luassert.is_equal(component.componentName, "MyComponent", "MyComponent should have the correct name")
            luassert.is_not_nil(component.getStorage, "MyComponent should have a getStorage method")
        end)

        it("creates instances of components", function()
            local container: tecs.Component = {}
            local component = tecs.newComponent({
                name = "MyComponent2",
                container = container
            })
            local instance = component()

            luassert.is_not_nil(instance, "MyComponent2 should not have made a nil instance")
            luassert.is_not_nil(instance.componentId, "MyComponent2 should have an ID")
            luassert.is_not_nil(instance.componentName, "MyComponent2 should have a name")
            luassert.is_not_nil(instance.componentType, "MyComponent2 should have a type")
            -- Regular components don't have exclusiveRelationship property - that's only for relationships
            luassert.is_equal(instance.componentName, "MyComponent2", "MyComponent2 should have the correct name")
        end)

        it("uses constructor and default metatable", function()
            local record MyComponent3 is tecs.Component
                name: string
            end

            tecs.newComponent({
                name = "MyComponent3",
                container = MyComponent3,
                constructor = function(name: string): MyComponent3
                    luassert.is_not_nil(name, "MyComponent3 constructor should have a name")
                    luassert.is_equal(name, "hello", "MyComponent3 constructor should have the correct name")
                    return {name = name}
                end
            })

            local instance = MyComponent3("hello")

            luassert.is_not_nil(instance, "MyComponent3 should not have made a nil instance")
            luassert.is_not_nil(instance.name, "MyComponent3 should have an ID")
            luassert.is_equal(instance.name, "hello", "MyComponent3 should have the correct name")
        end)

        it("detects when constructor returns nothing", function()
            local record MyComponent4 is tecs.Component end
            tecs.newComponent({
                name = "MyComponent4",
                container = MyComponent4,
                constructor = function(): MyComponent4
                    -- whoops!
                end
            })

            luassert.error_matches(function()
                MyComponent4("hello")
            end, "Component constructor for MyComponent4 returned nil", nil) -- TODO: Why do the types want nil here?
        end)

        it("detects a naming conflict", function()
            local container1 = {}
            local container2 = {}
            tecs.newComponent({
                name = "Hi__World",
                container = container1
            })

            luassert.error_matches(function()
                tecs.newComponent({
                    name = "Hi__World",
                    container = container2
                })
            end, "Component Hi__World already registered", nil) -- TODO: Why do the types want nil here?
        end)
    end)

    describe("registers components manually", function()
        it("detects conflicting names", function()
            local container1: tecs.Component = {componentName = "MyComponent5"}
            container1.componentType = container1

            components.registerComponent(container1)

            luassert.error_matches(function()
                components.registerComponent(container1)
            end, "Component MyComponent5 already registered", nil) -- TODO: Why do the types want nil here?
        end)

        it("assigns componentId if one not set", function()
            local container: tecs.Component = {componentName = "MyComponent6"}
            container.componentType = container

            components.registerComponent(container)

            luassert.is_not_nil(container.componentId, "Component should have an ID")
        end)
    end)

    describe("relationship components", function()
        it("creates relationship component", function()
            local rel = tecs.newRelationship({name = "TestRel2007"})

            luassert.is_not_nil(rel, "TestRel2007 should not be nil")
            luassert.is_not_nil(rel.componentId, "TestRel2007 should have an ID")
            luassert.is_not_nil(rel.componentName, "TestRel2007 should have a name")
            luassert.is_not_nil(rel.componentType, "TestRel2007 should have a type")
            luassert.is_not_nil(rel.exclusiveRelationship, "TestRel2007 should be a relationship")
            luassert.is_equal(rel.componentName, "TestRel2007", "TestRel2007 should have the correct name")
        end)

        it("creates relationship component instances", function()
            local rel = tecs.newRelationship({name = "TestRel2008"})

            local instance1 = rel(2)

            luassert.is_not_nil(instance1, "TestRel2008 should not have made a nil instance")

            luassert.is_equal(instance1.target, 2, "TestRel2008 should have a target of 2")
            luassert.is_equal(instance1, rel(2), "TestRel2008 should have the same instance for the same container")
            luassert.is_not_equal(instance1, rel(3), "TestRel2008 should have different instances for different containers")
            luassert.is_equal(instance1.componentType, rel(2), "TestRel2008 should have a type")

            -- Metatable __index check
            luassert.is_not_nil(instance1.componentId, "TestRel2008 should have an ID")
            luassert.is_not_nil(instance1.componentName, "TestRel2008 should have a name")
            luassert.is_not_nil(instance1.exclusiveRelationship, "TestRel2008 should be a relationship")
        end)

        it("can create relationship instances that have custom records", function()
            local record Attachment is tecs.Relationship
                speed: number
            end

            local rel = tecs.newRelationship({
                name = "Attachment",
                container = Attachment,
                constructor = function(target: integer, speed?: number): Attachment
                    return {target = target, speed = speed or 0}
                end
            }) as function(i: integer, n?: number): Attachment

            local instance = rel(3, 100)

            luassert.is_not_nil(instance, "Attachment should not have made a nil instance")

            luassert.is_equal(instance.speed, 100, "Attachment should have a speed of 100")
            luassert.is_equal(instance.target, 3, "Attachment should have a target of 3")
            luassert.is_equal(instance, rel(3), "Attachment should have the same instance for the same container")
            luassert.is_equal(instance.componentType, rel(3), "Attachment should have a type equal to the rel")
            luassert.is_not_equal(instance, rel(4), "Attachment should have different instances for different containers")

            -- Metatable __index check
            luassert.is_not_nil(instance.componentId, "Attachment should have an ID")
            luassert.is_not_nil(instance.componentName, "Attachment should have a name")
            luassert.is_not_nil(instance.exclusiveRelationship, "Attachment should be a relationship")
        end)

        it("creates simple relationships without data", function()
            local Targeting = tecs.newRelationship({name = "Targeting"})

            luassert.is_not_nil(Targeting, "Targeting should not be nil")
            luassert.is_not_nil(Targeting.componentName, "Targeting should have a name")
            luassert.is_equal(Targeting.componentName, "Targeting", "Targeting should have the correct name")
            luassert.is_not_nil(Targeting.getStorage, "Targeting should have a getStorage method")

            -- Test instances
            local instance1 = Targeting(42)
            luassert.is_not_nil(instance1, "Simple relationship should create instances")
            luassert.is_equal(instance1.target, 42, "Simple relationship instance should have target")

            -- Cache behavior: same target returns same instance
            local instance2 = Targeting(42)
            luassert.is_equal(instance1, instance2, "Same target should return cached instance")

            -- Different targets create different instances
            local instance3 = Targeting(99)
            luassert.is_not_equal(instance1, instance3, "Different targets should create different instances")
        end)


        it("rejects constructor without container", function()
            -- Should error if constructor is provided without container
            luassert.has_error(function()
                tecs.newRelationship({
                    name = "BadRelationship",
                    constructor = function(id: integer): tecs.Relationship
                        return {target = id}
                    end
                })
            end, "Cannot provide constructor for relationship without a container")
        end)

        describe("targeting() method", function()
            it("should return component instance for basic relationships", function()
                local Likes = tecs.newRelationship({name = "LikesTargeting1"})

                local targetEntity = 42
                local result = Likes:targeting(targetEntity)

                luassert.is_not_nil(result, "targeting should return a result")
                luassert.is_equal(result.target, targetEntity, "result should have correct target")
                luassert.is_equal(result, Likes(targetEntity), "targeting should return same as constructor")

                -- Should be same instance (cached)
                local result2 = Likes:targeting(targetEntity)
                luassert.is_equal(result, result2, "targeting should return cached instance")
            end)

            it("should return component type for data relationships", function()
                local record FollowsType is tecs.Relationship
                    delay: number
                end

                local Follows = tecs.newRelationship({
                    name = "FollowsTargeting2",
                    container = FollowsType,
                    constructor = function(id: integer, delay?: number): FollowsType
                        return {target = id, delay = delay or 1.0}
                    end
                })

                local targetEntity = 99
                local result = Follows:targeting(targetEntity)

                -- For data relationships, targeting returns the same as constructor
                local constructedInstance = (Follows as function(integer, number): FollowsType)(targetEntity, 2.5)
                luassert.is_equal(result, constructedInstance, "targeting should return same as constructor for same target")
            end)

            it("should work with world queries", function()
                local world = tecs.newWorld()
                local Likes = tecs.newRelationship({name = "LikesTargeting3"})

                local target = world:spawn()
                local entity1 = world:spawn(Likes:targeting(target) as tecs.Component)
                local _entity2 = world:spawn(Likes(123) as tecs.Component) -- Different target (unused but needed for test setup)
                world:update(0) -- Commit spawns

                -- Query for entities that like the specific target
                local likersQuery = world:query({include = {Likes:targeting(target)}})
                local foundEntities: {integer} = {}

                for _archetype, len, entities in likersQuery() do
                    for i = 1, len do
                        foundEntities[#foundEntities + 1] = entities[i]
                    end
                end

                luassert.is_equal(#foundEntities, 1, "Should find exactly one entity")
                luassert.is_equal(foundEntities[1], entity1, "Should find the entity that likes target")
            end)

            it("should work with world:get", function()
                local world = tecs.newWorld()

                local record FollowsType is tecs.Relationship
                    delay: number
                end

                local Follows = tecs.newRelationship({
                    name = "FollowsTargeting4",
                    container = FollowsType,
                    constructor = function(id: integer, delay?: number): FollowsType
                        return {target = id, delay = delay or 1.0}
                    end
                })

                local target = world:spawn()
                local entity = world:spawn((Follows as function(integer, number): FollowsType)(target, 3.0))
                world:update(0) -- Commit spawns

                -- Get the specific relationship using targeting
                local followComponent = world:get(entity, Follows:targeting(target))
                luassert.is_not_nil(followComponent, "Should find the relationship component")
                luassert.is_equal(followComponent.target, target, "Component should have correct target")
                luassert.is_equal((followComponent as FollowsType).delay, 3.0, "Component should have correct data")
            end)

            it("should require target entity ID", function()
                local Likes = tecs.newRelationship({name = "LikesTargeting5"})

                luassert.has_error(function()
                    Likes:targeting(nil)
                end, "Missing target entity ID")
            end)
        end)
    end)

    describe("tag components", function()
        it("creates tag components", function()
            local Frozen = tecs.newTagComponent({name = "Frozen"})

            luassert.is_not_nil(Frozen, "Frozen tag should not be nil")
            luassert.is_not_nil(Frozen.componentId, "Frozen tag should have an ID")
            luassert.is_not_nil(Frozen.componentName, "Frozen tag should have a name")
            luassert.is_equal(Frozen.componentName, "Frozen", "Frozen tag should have the correct name")
            luassert.is_not_nil(Frozen.getStorage, "Frozen tag should have a getStorage method")
        end)

        it("tag storage uses bitset internally", function()
            local Selected = tecs.newTagComponent({name = "Selected"})
            local storage = Selected:getStorage():new(100)

            luassert.is_not_nil(storage, "Tag storage should not be nil")

            -- Test that storage works like a normal table
            (storage as {boolean})[1] = true
            (storage as {boolean})[5] = true
            (storage as {boolean})[100] = true

            luassert.is_true((storage as {boolean})[1], "Tag storage should store true at index 1")
            luassert.is_true((storage as {boolean})[5], "Tag storage should store true at index 5")
            luassert.is_true((storage as {boolean})[100], "Tag storage should store true at index 100")
            luassert.is_false((storage as {boolean})[2], "Tag storage should return false for unset indices")
            luassert.is_false((storage as {boolean})[50], "Tag storage should return false for unset indices")

            -- Test unsetting
            (storage as {boolean})[5] = false
            luassert.is_false((storage as {boolean})[5], "Tag storage should unset values")
        end)

        it("tag storage handles large indices efficiently", function()
            local BigTag = tecs.newTagComponent({name = "BigTag"})
            local storage = BigTag:getStorage():new(0)

            -- Test with large indices that would be inefficient with regular tables
            (storage as {boolean})[1000] = true
            (storage as {boolean})[10000] = true
            (storage as {boolean})[100000] = true

            luassert.is_true((storage as {boolean})[1000], "Tag storage should handle index 1000")
            luassert.is_true((storage as {boolean})[10000], "Tag storage should handle index 10000")
            luassert.is_true((storage as {boolean})[100000], "Tag storage should handle index 100000")
            luassert.is_false((storage as {boolean})[999], "Tag storage should return false for unset large indices")
        end)

        it("multiple tags have independent storage", function()
            local Tag1 = tecs.newTagComponent({name = "Tag1"})
            local Tag2 = tecs.newTagComponent({name = "Tag2"})

            local storage1 = Tag1:getStorage():new(10)
            local storage2 = Tag2:getStorage():new(10)

            (storage1 as {boolean})[1] = true
            (storage1 as {boolean})[2] = true

            (storage2 as {boolean})[1] = true
            (storage2 as {boolean})[3] = true

            luassert.is_true((storage1 as {boolean})[1], "Tag1 storage should have index 1")
            luassert.is_true((storage1 as {boolean})[2], "Tag1 storage should have index 2")
            luassert.is_false((storage1 as {boolean})[3], "Tag1 storage should not have index 3")

            luassert.is_true((storage2 as {boolean})[1], "Tag2 storage should have index 1")
            luassert.is_false((storage2 as {boolean})[2], "Tag2 storage should not have index 2")
            luassert.is_true(storage2[3], "Tag2 storage should have index 3")
        end)

        it("tag components work as regular components", function()
            local Active = tecs.newTagComponent({name = "Active"})

            -- Should be callable like a regular component
            local instance = Active()

            luassert.is_not_nil(instance, "Tag should be callable")
            -- Tags return an empty table (or themselves with metadata)
            luassert.is_not_nil(instance.componentType, "Tag instance should have componentType")
            luassert.is_equal(instance.componentType, Active, "Tag instance type should be the tag")
        end)
    end)

    describe("component hooks", function()
        local world: tecs.World

        before_each(function()
            world = tecs.newWorld()
        end)

        describe("onAdd", function()
            it("should automatically add dependent components", function()
                -- Define Position component type
                local record PositionType is tecs.Component
                    x: number
                    y: number
                end

                local positionContainer: PositionType = {}
                local Position = tecs.newComponent({
                    name = "Position",
                    container = positionContainer,
                    constructor = function(x: number, y: number): PositionType
                        return {x = x or 0, y = y or 0, componentType = positionContainer}
                    end
                })

                -- Define Velocity component type
                local record VelocityType is tecs.Component
                    vx: number
                    vy: number
                end

                local Velocity = tecs.newComponent({
                    name = "Velocity",
                    container = VelocityType,
                    constructor = function(vx: number, vy: number): VelocityType
                        return {vx = vx or 0, vy = vy or 0}
                    end,
                    onAdd = function(_self: VelocityType, _world: tecs.World, _entityId: integer, changes: tecs.ChangeView)
                        if not changes:has(Position) then
                            changes:set(Position(0, 0))
                        end
                    end
                })

                -- Create entity with only Velocity
                local entity = world:spawn(Velocity(10, 20))

                -- Force changes to be committed (normally done automatically during update)
                world:update(0)

                -- Should automatically have Position
                local pos = world:get(entity, Position)
                local vel = world:get(entity, Velocity)

                luassert.is_not_nil(pos)
                luassert.is_not_nil(vel)
                luassert.equals(0, (pos as PositionType).x)
                luassert.equals(0, (pos as PositionType).y)
                luassert.equals(10, (vel as VelocityType).vx)
                luassert.equals(20, (vel as VelocityType).vy)
            end)

            it("should not override existing components", function()
                local record PositionType2 is tecs.Component
                    x: number
                    y: number
                end

                local Position = tecs.newComponent({
                    name = "Position2",
                    container = PositionType2,
                    constructor = function(x: number, y: number): PositionType2
                        return {x = x or 0, y = y or 0}
                    end
                })

                local record VelocityType2 is tecs.Component
                    vx: number
                    vy: number
                end

                local Velocity = tecs.newComponent({
                    name = "Velocity2",
                    container = VelocityType2,
                    constructor = function(vx: number, vy: number): VelocityType2
                        return {vx = vx or 0, vy = vy or 0}
                    end,
                    onAdd = function(_self: VelocityType2, _world: tecs.World, _entityId: integer, changes: tecs.ChangeView)
                        if not changes:has(Position) then
                            changes:set(Position(999, 999))
                        end
                    end
                })

                -- Create entity with both components
                local entity = world:spawn(Position(5, 10), Velocity(15, 25))

                -- Force changes to be committed
                world:update(0)

                local pos = world:get(entity, Position)
                local vel = world:get(entity, Velocity)

                -- Position should not be overridden
                luassert.equals(5, (pos as PositionType2).x)
                luassert.equals(10, (pos as PositionType2).y)
                luassert.equals(15, (vel as VelocityType2).vx)
                luassert.equals(25, (vel as VelocityType2).vy)
            end)

            it("should work when adding component to existing entity", function()
                local record PositionType3 is tecs.Component
                    x: number
                    y: number
                end

                local Position = tecs.newComponent({
                    name = "Position3",
                    container = PositionType3,
                    constructor = function(x: number, y: number): PositionType3
                        return {x = x or 0, y = y or 0}
                    end
                })

                local record VelocityType3 is tecs.Component
                    vx: number
                    vy: number
                end

                local Velocity = tecs.newComponent({
                    name = "Velocity3",
                    container = VelocityType3,
                    constructor = function(vx: number, vy: number): VelocityType3
                        return {vx = vx or 0, vy = vy or 0}
                    end,
                    onAdd = function(_self: VelocityType3, _world: tecs.World, _entityId: integer, changes: tecs.ChangeView)
                        if not changes:has(Position) then
                            changes:set(Position(100, 200))
                        end
                    end
                })

                -- Create entity without components
                local entity = world:spawn()

                -- Add Velocity later
                world:set(entity, Velocity(30, 40))

                -- Force changes to be committed
                world:update(0)

                -- Should have both components
                local pos = world:get(entity, Position)
                local vel = world:get(entity, Velocity)

                luassert.is_not_nil(pos)
                luassert.is_not_nil(vel)
                luassert.equals(100, (pos as PositionType3).x)
                luassert.equals(200, (pos as PositionType3).y)
                luassert.equals(30, (vel as VelocityType3).vx)
                luassert.equals(40, (vel as VelocityType3).vy)
            end)
        end)

        describe("onRemove", function()
            it("should clean up related components", function()
                local record TrailType is tecs.Component
                    active: boolean
                end

                local Trail = tecs.newComponent({
                    name = "Trail",
                    container = TrailType,
                    constructor = function(active: boolean): TrailType
                        return {active = active == nil and true or active}
                    end
                })

                local record MovementType is tecs.Component
                    speed: number
                end

                local Movement = tecs.newComponent({
                    name = "Movement",
                    container = MovementType,
                    constructor = function(speed: number): MovementType
                        return {speed = speed or 0}
                    end,
                    onRemove = function(_self: MovementType, _world: tecs.World, _entityId: integer, changes: tecs.ChangeView)
                        if changes:has(Trail) then
                            changes:remove(Trail)
                        end
                    end
                })

                -- Create entity with both components
                local entity = world:spawn(Movement(100), Trail(true))

                -- Force changes to be committed
                world:update(0)

                luassert.is_not_nil(world:get(entity, Movement))
                luassert.is_not_nil(world:get(entity, Trail))

                -- Remove Movement should also remove Trail
                world:remove(entity, Movement)

                -- Force changes to be committed
                world:update(0)

                luassert.is_nil(world:get(entity, Movement))
                luassert.is_nil(world:get(entity, Trail))
            end)
        end)

        describe("chained dependencies", function()
            it("should handle multiple levels of dependencies", function()
                local record AType is tecs.Component
                    value: number
                end

                local A = tecs.newComponent({
                    name = "A",
                    container = AType,
                    constructor = function(value: number): AType
                        return {value = value or 1}
                    end
                })

                local record BType is tecs.Component
                    value: number
                end

                local B = tecs.newComponent({
                    name = "B",
                    container = BType,
                    constructor = function(value: number): BType
                        return {value = value or 2}
                    end,
                    onAdd = function(_self: BType, _world: tecs.World, _entityId: integer, changes: tecs.ChangeView)
                        if not changes:has(A) then
                            changes:set(A(10))
                        end
                    end
                })

                local record CType is tecs.Component
                    value: number
                end

                local C = tecs.newComponent({
                    name = "C",
                    container = CType,
                    constructor = function(value: number): CType
                        return {value = value or 3}
                    end,
                    onAdd = function(_self: CType, _world: tecs.World, _entityId: integer, changes: tecs.ChangeView)
                        if not changes:has(B) then
                            changes:set(B(20))
                        end
                    end
                })

                -- Create entity with only C
                local entity = world:spawn(C(30))

                -- Force changes to be committed
                world:update(0)

                -- Should have all three components
                local a = world:get(entity, A)
                local b = world:get(entity, B)
                local c = world:get(entity, C)

                luassert.is_not_nil(a)
                luassert.is_not_nil(b)
                luassert.is_not_nil(c)
                luassert.equals(10, (a as AType).value)
                luassert.equals(20, (b as BType).value)
                luassert.equals(30, (c as CType).value)
            end)
        end)

        describe("computed components", function()
            it("should calculate derived values", function()
                local record HealthType is tecs.Component
                    current: number
                end

                local record MaxHealthType is tecs.Component
                    max: number
                end

                local MaxHealth = tecs.newComponent({
                    name = "MaxHealth",
                    container = MaxHealthType,
                    constructor = function(max: number): MaxHealthType
                        return {max = max or 100}
                    end
                })

                local Health = tecs.newComponent({
                    name = "Health",
                    container = HealthType,
                    constructor = function(current: number): HealthType
                        return {current = current or 100}
                    end
                })

                -- Redefine Health with hook after both types are defined
                Health = tecs.newComponent({
                    name = "Health2",
                    container = HealthType,
                    constructor = function(current: number): HealthType
                        return {current = current or 100}
                    end,
                    onAdd = function(_self: HealthType, _world: tecs.World, _entityId: integer, changes: tecs.ChangeView)
                        local health = changes:get(Health)
                        if health and not changes:has(MaxHealth) then
                            -- Set MaxHealth to current health value
                            changes:set(MaxHealth((health as HealthType).current))
                        end
                    end
                })

                -- Create entity with Health
                local entity = world:spawn(Health(75))

                -- Force changes to be committed
                world:update(0)

                local health = world:get(entity, Health)
                local maxHealth = world:get(entity, MaxHealth)

                luassert.is_not_nil(health)
                luassert.is_not_nil(maxHealth)
                luassert.equals(75, (health as HealthType).current)
                luassert.equals(75, (maxHealth as MaxHealthType).max)
            end)
        end)

        describe("advanced hook usage", function()
            it("should see committed state when querying during hooks", function()
                local record TagType is tecs.Component end

                local Tag = tecs.newComponent({
                    name = "QueryTestTag",
                    container = TagType,
                    constructor = function(): tecs.Component
                        return {}
                    end
                })

                -- First create two entities with the tag
                local _entity1 = world:spawn(Tag())
                local _entity2 = world:spawn(Tag())
                world:update(0)

                -- Now create a component that queries during its hook
                local record TriggerType is tecs.Component end

                local queryCount = 0
                local Trigger = tecs.newComponent({
                    name = "QueryTrigger",
                    container = TriggerType,
                    constructor = function(): tecs.Component
                        return {}
                    end,
                    onAdd = function(_self: TriggerType, _world: tecs.World, _entityId: integer, _changes: tecs.ChangeView)
                        -- Query should see the two committed Tags
                        local query = world:query({include = {Tag}})
                        queryCount = 0
                        for _archetype, len, _entities in query() do
                            for _row = 1, len do
                                queryCount = queryCount + 1
                            end
                        end
                    end
                })

                -- Create a new entity WITHOUT Tag first
                local entity3 = world:spawn()
                world:update(0)

                -- Now add Trigger to it (not during spawn)
                world:set(entity3, Trigger())
                world:update(0)

                -- During the hook, should have seen the 2 existing Tags
                luassert.equals(2, queryCount)

                -- Now add Tag to entity3 as well
                world:set(entity3, Tag())
                world:set(entity3, Trigger())  -- This should trigger the hook again
                world:update(0)

                -- Should still see 2 because entity3's Tag isn't committed during its hook
                luassert.equals(2, queryCount)

                -- After commit, query should see all three
                local query = world:query({include = {Tag}})
                local count = 0
                for _, len, _ in query() do
                    for _ = 1, len do
                        count = count + 1
                    end
                end
                luassert.equals(3, count)
            end)

            it("should allow modifying other entities during hooks", function()
                local record CounterType is tecs.Component
                    count: number
                end

                local record StunnedType is tecs.Component end
                local record EnemyType is tecs.Component end
                local record PowerUpType is tecs.Component end

                local Counter = tecs.newComponent({
                    name = "Counter",
                    container = CounterType,
                    constructor = function(count: number): CounterType
                        return {count = count or 0}
                    end
                })

                local Stunned = tecs.newComponent({
                    name = "Stunned",
                    container = StunnedType,
                    constructor = function(): tecs.Component
                        return {}
                    end
                })

                local Enemy = tecs.newComponent({
                    name = "Enemy",
                    container = EnemyType,
                    constructor = function(): tecs.Component
                        return {}
                    end
                })

                -- Create a counter entity first
                local counterEntity = world:spawn(Counter(0))

                -- Create some enemies
                local enemy1 = world:spawn(Enemy())
                local enemy2 = world:spawn(Enemy())
                local enemy3 = world:spawn(Enemy())

                -- Commit so they exist in the world
                world:update(0)

                local PowerUp = tecs.newComponent({
                    name = "PowerUp",
                    container = PowerUpType,
                    constructor = function(): tecs.Component
                        return {}
                    end,
                    onAdd = function(_self: PowerUpType, _world: tecs.World, _entityId: integer, _changes: tecs.ChangeView)
                        -- When PowerUp is collected, stun all enemies
                        local enemyQuery = world:query({include = {Enemy}})
                        for archetype, len, entities in enemyQuery() do
                            for row = 1, len do
                                local id = entities[row]
                                world:set(id, Stunned())
                            end
                        end

                        -- And increment the counter on the first entity
                        local counter = world:get(counterEntity, Counter)
                        if counter then
                            world:set(counterEntity, Counter((counter as CounterType).count + 1))
                        end
                    end
                })

                -- Verify enemies don't have Stunned yet
                luassert.is_nil(world:get(enemy1, Stunned))
                luassert.is_nil(world:get(enemy2, Stunned))
                luassert.is_nil(world:get(enemy3, Stunned))
                luassert.equals(0, (world:get(counterEntity, Counter) as CounterType).count)

                -- Create player entity first, then add PowerUp
                local player = world:spawn()
                world:update(0)

                -- Now add PowerUp (not during spawn)
                world:set(player, PowerUp())
                world:update(0)

                -- All enemies should now be stunned
                luassert.is_not_nil(world:get(enemy1, Stunned))
                luassert.is_not_nil(world:get(enemy2, Stunned))
                luassert.is_not_nil(world:get(enemy3, Stunned))

                -- Counter should be incremented
                luassert.equals(1, (world:get(counterEntity, Counter) as CounterType).count)
            end)

            -- NOTE: Self-modification during hooks is not allowed.
            -- Components cannot remove or modify themselves during their own onAdd/onRemove hooks.
            -- This restriction ensures predictable behavior and prevents confusing edge cases.
        end)
    end)

    describe("FFI components", function()
        describe("Transform component", function()
            it("should default layer to 1 when not provided", function()
                local transform = tecs.builtins.Transform()
                luassert.is_equal(transform.layer, 1, "Transform should default layer to 1")
            end)

            it("should reject layer 0 as invalid", function()
                luassert.has_error(function()
                    tecs.builtins.Transform(10, 20, 30, 0)
                end, "Transform layer must be greater than 0, got: 0")
            end)

            it("should preserve valid layer values", function()
                local transform = tecs.builtins.Transform(5, 10, 15, 3)
                luassert.is_equal(transform.layer, 3, "Transform should preserve valid layer")
                luassert.is_equal(transform.x, 5, "Transform should preserve x value")
                luassert.is_equal(transform.y, 10, "Transform should preserve y value")
                luassert.is_equal(transform.z, 15, "Transform should preserve z value")
            end)

            it("should reject negative layer values", function()
                luassert.has_error(function()
                    tecs.builtins.Transform(0, 0, 0, -1)
                end, "Transform layer must be greater than 0, got: -1")
            end)

            it("should reject negative layer values with table argument", function()
                luassert.has_error(function()
                    tecs.builtins.Transform({x = 0, y = 0, z = 0, layer = -5})
                end, "Transform layer must be greater than 0, got: -5")
            end)

            it("should default layer to 1 with table argument when layer is nil", function()
                local transform = tecs.builtins.Transform({x = 100, y = 200, z = 300})
                luassert.is_equal(transform.layer, 1, "Transform should default layer to 1 with table argument")
                luassert.is_equal(transform.x, 100, "Transform should preserve x from table")
                luassert.is_equal(transform.y, 200, "Transform should preserve y from table")
                luassert.is_equal(transform.z, 300, "Transform should preserve z from table")
            end)

            it("should reject layer 0 with table argument", function()
                luassert.has_error(function()
                    tecs.builtins.Transform({x = 50, y = 60, z = 70, layer = 0})
                end, "Transform layer must be greater than 0, got: 0")
            end)

            it("should default coordinates to 0 when not provided", function()
                local transform = tecs.builtins.Transform()
                luassert.is_equal(transform.x, 0, "Transform should default x to 0")
                luassert.is_equal(transform.y, 0, "Transform should default y to 0")
                luassert.is_equal(transform.z, 0, "Transform should default z to 0")
                luassert.is_equal(transform.layer, 1, "Transform should default layer to 1")
            end)
        end)
    end)
end)