require("busted")
local tecs <const> = require("tecs")
local components <const> = require("tecs.internal.components")
local luassert <const> = require("luassert")

describe(
    "components",
    function()
        describe(
            "creates new components",
            function()
                it(
                    "registeres component",
                    function()
                        local container: tecs.Component = {}
                        local component = tecs.ecs.newComponent({name = "MyComponent", container = container})

                        luassert.is_not_nil(component, "MyComponent should not be nil")
                        luassert.is_not_nil(component.componentId, "MyComponent should have an ID")
                        luassert.is_not_nil(component.componentName, "MyComponent should have a name")
                        luassert.is_not_nil(component.componentType, "MyComponent should have a type")
                        -- Regular components don't have exclusiveRelationship property - that's only for relationships
                        luassert.is_equal(
                            component.componentName, "MyComponent", "MyComponent should have the correct name"
                        )
                        luassert.is_not_nil(component.storage, "MyComponent should have a storage method")
                    end
                )

                it(
                    "creates instances of components",
                    function()
                        local container: tecs.Component = {}
                        local component = tecs.ecs.newComponent({name = "MyComponent2", container = container})
                        local instance = component()

                        luassert.is_not_nil(instance, "MyComponent2 should not have made a nil instance")
                        luassert.is_not_nil(instance.componentId, "MyComponent2 should have an ID")
                        luassert.is_not_nil(instance.componentName, "MyComponent2 should have a name")
                        luassert.is_not_nil(instance.componentType, "MyComponent2 should have a type")
                        -- Regular components don't have exclusiveRelationship property - that's only for relationships
                        luassert.is_equal(
                            instance.componentName, "MyComponent2", "MyComponent2 should have the correct name"
                        )
                    end
                )

                it(
                    "uses init and default metatable",
                    function()
                        local record MyComponent3 is tecs.Component
                            name: string
                        end

                        tecs.ecs.newComponent({
                            name = "MyComponent3",
                            container = MyComponent3,
                            fields = {"name"},
                            init = function(instance: MyComponent3, name: string)
                                luassert.is_not_nil(name, "MyComponent3 init should have a name")
                                luassert.is_equal(name, "hello", "MyComponent3 init should have the correct name")
                                instance.name = name
                            end,
                        })

                        local instance = MyComponent3("hello")

                        luassert.is_not_nil(instance, "MyComponent3 should not have made a nil instance")
                        luassert.is_not_nil(instance.name, "MyComponent3 should have an ID")
                        luassert.is_equal(instance.name, "hello", "MyComponent3 should have the correct name")
                    end
                )

                it(
                    "detects a naming conflict",
                    function()
                        local container1 = {}
                        local container2 = {}
                        tecs.ecs.newComponent({name = "Hi__World", container = container1})

                        luassert.error_matches(function()
                            tecs.ecs.newComponent({name = "Hi__World", container = container2})
                        end, "Component Hi__World already registered",
                        nil) -- TODO: Why do the types want nil here?
                    end
                )
            end
        )

        describe(
            ".new table-form constructor",
            function()
                it(
                    "codegens .new from fields that unpacks by name",
                    function()
                        local record FieldComp is tecs.Component
                            x: number
                            y: number
                            z: number
                        end
                        local comp = tecs.ecs.newComponent({
                            name = "FieldsNewTest",
                            container = FieldComp as tecs.Component,
                            fields = {"x", "y", "z"},
                        })
                        local inst = (comp as any).new({x = 1, y = 2, z = 3}) as {string: number}
                        luassert.is_equal(inst.x, 1)
                        luassert.is_equal(inst.y, 2)
                        luassert.is_equal(inst.z, 3)
                    end
                )

                it(
                    "honors opts.new for custom table-form constructors",
                    function()
                        local record ConfigComp is tecs.Component
                            radius: number
                            cookie: integer
                        end
                        local comp = tecs.ecs.newComponent({
                            name = "ConfigNewTest",
                            container = ConfigComp as tecs.Component,
                            fields = {"radius"},
                            init = function(instance: ConfigComp, radius?: number)
                                instance.radius = radius or 100
                                instance.cookie = 0
                            end,
                            new = function(data: {string: any}): ConfigComp
                                return {
                                    radius = data.radius as number or 100,
                                    cookie = data.cookie as integer or 0,
                                }
                            end,
                        })
                        -- Positional: cookie defaults to 0 (no table handling in ctor).
                        local pos = (comp as any)(42) as {string: any}
                        luassert.is_equal(pos.radius, 42)
                        luassert.is_equal(pos.cookie, 0)
                        -- Table form: .new preserves both fields -- regression for the
                        -- nparams-introspection bug that silently dropped `cookie`.
                        local tab = (comp as any).new({radius = 50, cookie = 7}) as {string: any}
                        luassert.is_equal(tab.radius, 50)
                        luassert.is_equal(tab.cookie, 7)
                    end
                )

                it(
                    "__call is positional-only; table arg is no longer unpacked by name",
                    function()
                        local record PosOnly is tecs.Component
                            first: any
                            second: number
                        end
                        local comp = tecs.ecs.newComponent({
                            name = "PosOnlyTest",
                            container = PosOnly as tecs.Component,
                            fields = {"first", "second"},
                            init = function(instance: PosOnly, first?: any, second?: number)
                                instance.first = first
                                instance.second = second or 0
                            end,
                        })
                        -- Passing a table to __call lands in positional arg #1, not
                        -- unpacked into (first=..., second=...). The ctor author can
                        -- choose to handle it, but the framework no longer silently
                        -- remaps table keys to param names.
                        local inst = (comp as any)({first = "hello", second = 99}) as {string: any}
                        luassert.is_equal(type(inst.first), "table")
                        luassert.is_equal(inst.second, 0)
                    end
                )

                it(
                    "init without fields or new errors at registration",
                    function()
                        local record Broken is tecs.Component
                            value: number
                        end
                        luassert.error_matches(function()
                            tecs.ecs.newComponent({
                                name = "BrokenCtorOnlyTest",
                                container = Broken as tecs.Component,
                                init = function(instance: Broken, v: number) instance.value = v end,
                            })
                        end, "requires either `fields`",
                        nil)
                    end
                )

                it(
                    "fields + init coexist: fields drives .new, init refines __call",
                    function()
                        local record Mixed is tecs.Component
                            value: number
                            validated: boolean
                        end
                        local comp = tecs.ecs.newComponent({
                            name = "MixedFieldsCtorTest",
                            container = Mixed as tecs.Component,
                            fields = {"value"},
                            init = function(instance: Mixed, value: number)
                                instance.value = value
                                instance.validated = true
                            end,
                        })
                        -- __call runs the custom init (sets validated = true).
                        local pos = (comp as any)(10) as {string: any}
                        luassert.is_equal(pos.value, 10)
                        luassert.is_equal(pos.validated, true)
                        -- .new unpacks by field name, routes through __call → init.
                        local tab = (comp as any).new({value = 20}) as {string: any}
                        luassert.is_equal(tab.value, 20)
                        luassert.is_equal(tab.validated, true)
                    end
                )

                it(
                    "custom __call on table components gets defaults but does not auto-run init",
                    function()
                        local initCalls = 0
                        local callCalls = 0

                        local record FancyTable is tecs.Component
                            x: number
                            y: number
                            label: string
                        end

                        local comp = tecs.ecs.newComponent({
                            name = "FancyTableCallTest",
                            container = FancyTable as tecs.Component,
                            fields = {"x", "y"},
                            defaults = {3, 7},
                            __call = function(instance: FancyTable, label: string)
                                callCalls = callCalls + 1
                                luassert.is_equal(3, instance.x)
                                luassert.is_equal(7, instance.y)
                                instance.label = label
                                instance.x = instance.x + 1
                            end,
                            init = function(_instance: FancyTable, _label: string) initCalls = initCalls + 1 end,
                        })

                        local inst = (comp as any)("ok") as {string: any}
                        luassert.is_equal(1, callCalls)
                        luassert.is_equal(0, initCalls)
                        luassert.is_equal(4, inst.x)
                        luassert.is_equal(7, inst.y)
                        luassert.is_equal("ok", inst.label)
                    end
                )

                it(
                    "custom __call on ffi components gets defaults but does not auto-run init",
                    function()
                        local initCalls = 0
                        local callCalls = 0

                        local record FancyFFI is tecs.Component
                            x: integer
                            y: integer
                        end

                        local comp = tecs.ecs.newFFIComponent({
                            name = "FancyFFICallTest",
                            container = FancyFFI as tecs.Component,
                            fields = {
                                {"x", "int32_t"},
                                {"y", "int32_t"},
                            },
                            defaults = {2, 5},
                            __call = function(instance: FancyFFI, delta: integer)
                                callCalls = callCalls + 1
                                luassert.is_equal(2, instance.x)
                                luassert.is_equal(5, instance.y)
                                instance.x = instance.x + delta
                                instance.y = instance.y + delta
                            end,
                            init = function(_instance: FancyFFI, _delta: integer) initCalls = initCalls + 1 end,
                        })

                        local inst = (comp as any)(10) as {string: any}
                        luassert.is_equal(1, callCalls)
                        luassert.is_equal(0, initCalls)
                        luassert.is_equal(12, inst.x)
                        luassert.is_equal(15, inst.y)
                    end
                )
            end
        )

        describe(
            "registers components manually",
            function()
                it(
                    "detects conflicting names",
                    function()
                        local container1: tecs.Component = {componentName = "MyComponent5"}
                        container1.componentType = container1

                        components.registerComponent(container1)

                        luassert.error_matches(function()
                            components.registerComponent(container1)
                        end, "Component MyComponent5 already registered",
                        nil) -- TODO: Why do the types want nil here?
                    end
                )

                it(
                    "assigns componentId if one not set",
                    function()
                        local container: tecs.Component = {componentName = "MyComponent6"}
                        container.componentType = container

                        components.registerComponent(container)

                        luassert.is_not_nil(container.componentId, "Component should have an ID")
                    end
                )
            end
        )

        describe(
            "relationship components",
            function()
                it(
                    "creates relationship component",
                    function()
                        local rel = tecs.ecs.newRelationship({name = "TestRel2007"})

                        luassert.is_not_nil(rel, "TestRel2007 should not be nil")
                        luassert.is_not_nil(rel.componentId, "TestRel2007 should have an ID")
                        luassert.is_not_nil(rel.componentName, "TestRel2007 should have a name")
                        luassert.is_not_nil(rel.componentType, "TestRel2007 should have a type")
                        luassert.is_not_nil(rel.exclusiveRelationship, "TestRel2007 should be a relationship")
                        luassert.is_equal(rel.componentName, "TestRel2007", "TestRel2007 should have the correct name")
                    end
                )

                it(
                    "creates relationship component instances",
                    function()
                        local rel = tecs.ecs.newRelationship({name = "TestRel2008"})

                        local instance1 = rel(2)

                        luassert.is_not_nil(instance1, "TestRel2008 should not have made a nil instance")

                        luassert.is_equal(instance1.target, 2, "TestRel2008 should have a target of 2")
                        luassert.is_equal(
                            instance1, rel(2), "TestRel2008 should have the same instance for the same container"
                        )
                        luassert.is_not_equal(
                            instance1, rel(3), "TestRel2008 should have different instances for different containers"
                        )
                        luassert.is_equal(instance1.componentType, rel(2), "TestRel2008 should have a type")

                        -- Metatable __index check
                        luassert.is_not_nil(instance1.componentId, "TestRel2008 should have an ID")
                        luassert.is_not_nil(instance1.componentName, "TestRel2008 should have a name")
                        luassert.is_not_nil(instance1.exclusiveRelationship, "TestRel2008 should be a relationship")
                    end
                )

                it(
                    "can create relationship instances that have custom records",
                    function()
                        local record Attachment is tecs.Relationship
                            speed: number
                        end

                        local rel = tecs.ecs.newRelationship({
                            name = "Attachment",
                            container = Attachment,
                            fields = {"speed"},
                            init = function(instance: Attachment, target: integer, speed?: number)
                                instance.target = target
                                instance.speed = speed or 0
                            end,
                        }) as function(i: integer, n?: number): Attachment

                        local instance = rel(3, 100)

                        luassert.is_not_nil(instance, "Attachment should not have made a nil instance")

                        luassert.is_equal(instance.speed, 100, "Attachment should have a speed of 100")
                        luassert.is_equal(instance.target, 3, "Attachment should have a target of 3")
                        luassert.is_equal(
                            instance, rel(3), "Attachment should have the same instance for the same container"
                        )
                        luassert.is_equal(
                            instance.componentType, rel(3), "Attachment should have a type equal to the rel"
                        )
                        luassert.is_not_equal(
                            instance, rel(4), "Attachment should have different instances for different containers"
                        )

                        -- Metatable __index check
                        luassert.is_not_nil(instance.componentId, "Attachment should have an ID")
                        luassert.is_not_nil(instance.componentName, "Attachment should have a name")
                        luassert.is_not_nil(instance.exclusiveRelationship, "Attachment should be a relationship")
                    end
                )

                it(
                    "creates simple relationships without data",
                    function()
                        local Follows = tecs.ecs.newRelationship({name = "Follows"})

                        luassert.is_not_nil(Follows, "Follows should not be nil")
                        luassert.is_not_nil(Follows.componentName, "Follows should have a name")
                        luassert.is_equal(Follows.componentName, "Follows", "Follows should have the correct name")
                        luassert.is_not_nil(Follows.storage, "Follows should have a storage method")

                        -- Test instances
                        local instance1 = Follows(42)
                        luassert.is_not_nil(instance1, "Simple relationship should create instances")
                        luassert.is_equal(instance1.target, 42, "Simple relationship instance should have target")

                        -- Cache behavior: same target returns same instance
                        local instance2 = Follows(42)
                        luassert.is_equal(instance1, instance2, "Same target should return cached instance")

                        -- Different targets create different instances
                        local instance3 = Follows(99)
                        luassert.is_not_equal(
                            instance1, instance3, "Different targets should create different instances"
                        )
                    end
                )

                it(
                    "rejects init without container",
                    function()
                        -- Should error if init is provided without container
                        luassert.has_error(function()
                            tecs.ecs.newRelationship({
                                name = "BadRelationship",
                                fields = {},
                                init = function(instance: tecs.Relationship, id: integer) instance.target = id end,
                            })
                        end, "Cannot provide init for relationship without a container")
                    end
                )

                it(
                    "supports fields on relationships",
                    function()
                        local record AttachFields is tecs.Relationship
                            speed: number
                            offset: number
                        end

                        local rel = tecs.ecs.newRelationship({
                            name = "AttachFields",
                            container = AttachFields,
                            fields = {"speed", "offset"},
                        }) as function(id: integer, speed: number, offset: number): AttachFields

                        local instance = rel(5, 100, 25)
                        luassert.is_equal(instance.target, 5)
                        luassert.is_equal(instance.speed, 100)
                        luassert.is_equal(instance.offset, 25)
                        luassert.is_equal(instance.componentName, "AttachFields->5")
                    end
                )

                it(
                    "supports fields with defaults on relationships",
                    function()
                        local record AttachDefaults is tecs.Relationship
                            speed: number
                            drag: number
                        end

                        local rel = tecs.ecs.newRelationship({
                            name = "AttachDefaults",
                            container = AttachDefaults,
                            fields = {"speed", "drag"},
                            defaults = {0, 1},
                        }) as function(id: integer, speed?: number, drag?: number): AttachDefaults

                        -- All defaults
                        local instance1 = rel(10)
                        luassert.is_equal(instance1.target, 10)
                        luassert.is_equal(instance1.speed, 0)
                        luassert.is_equal(instance1.drag, 1)

                        -- Override one
                        local instance2 = rel(20, 50)
                        luassert.is_equal(instance2.target, 20)
                        luassert.is_equal(instance2.speed, 50)
                        luassert.is_equal(instance2.drag, 1)

                        -- Override both
                        local instance3 = rel(30, 99, 5)
                        luassert.is_equal(instance3.target, 30)
                        luassert.is_equal(instance3.speed, 99)
                        luassert.is_equal(instance3.drag, 5)
                    end
                )

                it(
                    "rejects relationship init without fields or new",
                    function()
                        luassert.error_matches(function()
                            tecs.ecs.newRelationship({
                                name = "BadRelCtorOnly",
                                container = {},
                                init = function(_instance: tecs.Relationship, id: integer) end,
                            })
                        end, "requires either `fields`",
                        nil)
                    end
                )

                it(
                    "fields + init coexist on relationships",
                    function()
                        local record RelData is tecs.Relationship
                            speed: number
                            validated: boolean
                        end
                        local rel = tecs.ecs.newRelationship({
                            name = "MixedRelFieldsCtor",
                            container = RelData as tecs.Relationship,
                            fields = {"speed"},
                            init = function(instance: RelData, _id: integer, speed: number)
                                instance.speed = speed or 10
                                instance.validated = true
                            end,
                        })
                        -- positional goes through init
                        local inst = (rel as any)(1, 5) as {string: any}
                        luassert.is_equal(inst.speed, 5)
                        luassert.is_equal(inst.validated, true)
                        -- .new unpacks fields and routes through init
                        local instNew = (rel as any).new({target = 2, speed = 7}) as {string: any}
                        luassert.is_equal(instNew.speed, 7)
                        luassert.is_equal(instNew.validated, true)
                    end
                )

                it(
                    "rejects defaults without fields on relationships",
                    function()
                        luassert.has_error(function()
                            tecs.ecs.newRelationship({
                                name = "BadRelDefaults",
                                container = {},
                                defaults = {0},
                            })
                        end, "Relationship BadRelDefaults: `defaults` requires `fields`")
                    end
                )

                describe(
                    "targeting() method",
                    function()
                        it(
                            "should return component instance for basic relationships",
                            function()
                                local Likes = tecs.ecs.newRelationship({name = "LikesTargeting1"})

                                local targetEntity = 42
                                local result = Likes:targeting(targetEntity)

                                luassert.is_not_nil(result, "targeting should return a result")
                                luassert.is_equal(result.target, targetEntity, "result should have correct target")
                                luassert.is_equal(
                                    result, Likes(targetEntity), "targeting should return same as constructor"
                                )

                                -- Should be same instance (cached)
                                local result2 = Likes:targeting(targetEntity)
                                luassert.is_equal(result, result2, "targeting should return cached instance")
                            end
                        )

                        it(
                            "should return component type for data relationships",
                            function()
                                local record FollowsType is tecs.Relationship
                                    delay: number
                                end

                                local Follows = tecs.ecs.newRelationship({
                                    name = "FollowsTargeting2",
                                    container = FollowsType,
                                    fields = {"delay"},
                                    init = function(instance: FollowsType, id: integer, delay?: number)
                                        instance.target = id
                                        instance.delay = delay or 1.0
                                    end,
                                })

                                local targetEntity = 99
                                local result = Follows:targeting(targetEntity)

                                -- For data relationships, targeting returns the same as positional construction
                                local constructedInstance = (Follows as function(integer, number): FollowsType)(
                                    targetEntity, 2.5
                                )
                                luassert.is_equal(
                                    result,
                                    constructedInstance,
                                    "targeting should return same as positional construction for same target"
                                )
                            end
                        )

                        it(
                            "should work with world queries",
                            function()
                                local world = tecs.ecs.newWorld()
                                local Likes = tecs.ecs.newRelationship({name = "LikesTargeting3"})

                                local target = world:spawn()
                                local entity1 = world:spawn(Likes:targeting(target) as tecs.Component)
                                local _entity2 = world:spawn(
                                    Likes(123) as tecs.Component
                                ) -- Different target (unused but needed for test setup)
                                world:update(0) -- Commit spawns

                                -- Query for entities that like the specific target
                                local likersQuery = world:query({include = {Likes:targeting(target)}})
                                local foundEntities: {integer} = {}

                                for _archetype, len, entities in likersQuery:iter() do
                                    for i = 1, len do
                                        foundEntities[#foundEntities + 1] = entities[i]
                                    end
                                end

                                luassert.is_equal(#foundEntities, 1, "Should find exactly one entity")
                                luassert.is_equal(foundEntities[1], entity1, "Should find the entity that likes target")
                            end
                        )

                        it(
                            "should work with world:get",
                            function()
                                local world = tecs.ecs.newWorld()

                                local record FollowsType is tecs.Relationship
                                    delay: number
                                end

                                local Follows = tecs.ecs.newRelationship({
                                    name = "FollowsTargeting4",
                                    container = FollowsType,
                                    fields = {"delay"},
                                    init = function(instance: FollowsType, id: integer, delay?: number)
                                        instance.target = id
                                        instance.delay = delay or 1.0
                                    end,
                                })

                                local target = world:spawn()
                                local entity = world:spawn(
                                    (Follows as function(integer, number): FollowsType)(target, 3.0)
                                )
                                world:update(0) -- Commit spawns

                                -- Get the specific relationship using targeting
                                local followComponent = world:get(entity, Follows:targeting(target))
                                luassert.is_not_nil(followComponent, "Should find the relationship component")
                                luassert.is_equal(
                                    followComponent.target, target, "Component should have correct target"
                                )
                                luassert.is_equal(
                                    (followComponent as FollowsType).delay, 3.0, "Component should have correct data"
                                )
                            end
                        )

                        it(
                            "should require target entity ID",
                            function()
                                local Likes = tecs.ecs.newRelationship({name = "LikesTargeting5"})

                                luassert.has_error(function() Likes:targeting(nil) end, "Missing target entity ID")
                            end
                        )
                    end
                )
            end
        )

        describe(
            "tag components",
            function()
                it(
                    "creates tag components",
                    function()
                        local Frozen = tecs.ecs.newTagComponent({name = "Frozen"})

                        luassert.is_not_nil(Frozen, "Frozen tag should not be nil")
                        luassert.is_not_nil(Frozen.componentId, "Frozen tag should have an ID")
                        luassert.is_not_nil(Frozen.componentName, "Frozen tag should have a name")
                        luassert.is_equal(Frozen.componentName, "Frozen", "Frozen tag should have the correct name")
                        luassert.is_not_nil(Frozen.storage, "Frozen tag should have a storage method")
                    end
                )

                it(
                    "tag storage reads return the container",
                    function()
                        -- Presence is archetype-defined, not per-row. Any row read yields
                        -- the container; writes are no-ops. Callers only ever index live
                        -- rows, so there is no observable difference at the world level.
                        local Selected = tecs.ecs.newTagComponent({name = "Selected"})
                        local column = Selected.storage:createColumn(100)

                        luassert.is_not_nil(column, "Tag column should not be nil")
                        luassert.equals(Selected, column[1])
                        luassert.equals(Selected, column[9999])

                        -- Writes are no-ops; reads still return the container.
                        (column as {tecs.Component})[5] = Selected
                        luassert.equals(Selected, column[5])
                        (column as {tecs.Component})[5] = nil
                        luassert.equals(Selected, column[5])
                    end
                )

                it(
                    "multiple tags have independent containers",
                    function()
                        local Tag1 = tecs.ecs.newTagComponent({name = "Tag1"})
                        local Tag2 = tecs.ecs.newTagComponent({name = "Tag2"})

                        local column1 = Tag1.storage:createColumn(10)
                        local column2 = Tag2.storage:createColumn(10)

                        luassert.equals(Tag1, column1[1])
                        luassert.equals(Tag2, column2[1])
                        luassert.are_not.equal(column1[1], column2[1])
                    end
                )

                it(
                    "tag components work as regular components",
                    function()
                        local Active = tecs.ecs.newTagComponent({name = "Active"})

                        -- Should be callable like a regular component
                        local instance = Active()

                        luassert.is_not_nil(instance, "Tag should be callable")
                        -- Tags return an empty table (or themselves with metadata)
                        luassert.is_not_nil(instance.componentType, "Tag instance should have componentType")
                        luassert.is_equal(instance.componentType, Active, "Tag instance type should be the tag")
                    end
                )
            end
        )

        describe(
            "FFI components",
            function()
                describe(
                    "Transform component",
                    function()
                        it(
                            "should default layer to 1 when not provided",
                            function()
                                local transform = tecs.Transform()
                                luassert.is_equal(transform.layer, 1, "Transform should default layer to 1")
                            end
                        )

                        it(
                            "should reject layer 0 as invalid",
                            function()
                                luassert.has_error(function()
                                    tecs.Transform(10, 20, 30, 0)
                                end, "Transform layer must be greater than 0, got: 0")
                            end
                        )

                        it(
                            "should preserve valid layer values",
                            function()
                                local transform = tecs.Transform(5, 10, 15, 3)
                                luassert.is_equal(transform.layer, 3, "Transform should preserve valid layer")
                                luassert.is_equal(transform.x, 5, "Transform should preserve x value")
                                luassert.is_equal(transform.y, 10, "Transform should preserve y value")
                                luassert.is_equal(transform.z, 15, "Transform should preserve z value")
                            end
                        )

                        it(
                            "should reject negative layer values",
                            function()
                                luassert.has_error(function()
                                    tecs.Transform(0, 0, 0, -1)
                                end, "Transform layer must be greater than 0, got: -1")
                            end
                        )

                        it(
                            "should reject negative layer values with table argument",
                            function()
                                luassert.has_error(function()
                                    tecs.Transform.new({x = 0, y = 0, z = 0, layer = -5})
                                end, "Transform layer must be greater than 0, got: -5")
                            end
                        )

                        it(
                            "should default layer to 1 with table argument when layer is nil",
                            function()
                                local transform = tecs.Transform.new({x = 100, y = 200, z = 300})
                                luassert.is_equal(
                                    transform.layer, 1, "Transform should default layer to 1 with table argument"
                                )
                                luassert.is_equal(transform.x, 100, "Transform should preserve x from table")
                                luassert.is_equal(transform.y, 200, "Transform should preserve y from table")
                                luassert.is_equal(transform.z, 300, "Transform should preserve z from table")
                            end
                        )

                        it(
                            "should reject layer 0 with table argument",
                            function()
                                luassert.has_error(function()
                                    tecs.Transform.new({x = 50, y = 60, z = 70, layer = 0})
                                end, "Transform layer must be greater than 0, got: 0")
                            end
                        )

                        it(
                            "should default coordinates to 0 when not provided",
                            function()
                                local transform = tecs.Transform()
                                luassert.is_equal(transform.x, 0, "Transform should default x to 0")
                                luassert.is_equal(transform.y, 0, "Transform should default y to 0")
                                luassert.is_equal(transform.z, 0, "Transform should default z to 0")
                                luassert.is_equal(transform.layer, 1, "Transform should default layer to 1")
                            end
                        )

                        it(
                            "should default rotation to 0",
                            function()
                                local transform = tecs.Transform()
                                luassert.is_equal(transform.rotation, 0, "Transform should default rotation to 0")
                            end
                        )

                        it(
                            "should default scale to 1",
                            function()
                                local transform = tecs.Transform()
                                luassert.is_equal(transform.scaleX, 1, "Transform should default scaleX to 1")
                                luassert.is_equal(transform.scaleY, 1, "Transform should default scaleY to 1")
                            end
                        )

                        it(
                            "should preserve rotation when set",
                            function()
                                local transform = tecs.Transform()
                                transform.rotation = math.pi / 4
                                luassert.is_true(
                                    math.abs(transform.rotation - math.pi / 4) < 0.0001,
                                    "Transform should preserve rotation"
                                )
                            end
                        )

                        it(
                            "should preserve scale when set",
                            function()
                                local transform = tecs.Transform()
                                transform.scaleX = 2.5
                                transform.scaleY = 0.5
                                luassert.is_equal(transform.scaleX, 2.5, "Transform should preserve scaleX")
                                luassert.is_equal(transform.scaleY, 0.5, "Transform should preserve scaleY")
                            end
                        )

                        it(
                            "should support rotation with position and layer",
                            function()
                                local transform = tecs.Transform(10, 20, 30, 2)
                                transform.rotation = math.pi / 2
                                luassert.is_equal(transform.x, 10, "Transform should preserve x")
                                luassert.is_equal(transform.y, 20, "Transform should preserve y")
                                luassert.is_true(
                                    math.abs(transform.rotation - math.pi / 2) < 0.0001,
                                    "Transform should preserve rotation"
                                )
                            end
                        )

                        it(
                            "should support scale with position and layer",
                            function()
                                local transform = tecs.Transform(5, 15, 25, 3)
                                transform.scaleX = 3
                                transform.scaleY = 3
                                luassert.is_equal(transform.x, 5, "Transform should preserve x")
                                luassert.is_equal(transform.scaleX, 3, "Transform should preserve scaleX")
                                luassert.is_equal(transform.scaleY, 3, "Transform should preserve scaleY")
                            end
                        )
                    end
                )
            end
        )

        describe(
            "fields codegen",
            function()
                it(
                    "creates instances with positional args",
                    function()
                        local record FieldsComp is tecs.Component
                            x: number
                            y: number
                            metamethod __call: function(self, x: number, y: number): FieldsComp
                        end

                        tecs.ecs.newComponent({
                            name = "FieldsComp",
                            container = FieldsComp,
                            fields = {"x", "y"},
                        })

                        local instance = FieldsComp(10, 20)
                        luassert.is_equal(instance.x, 10)
                        luassert.is_equal(instance.y, 20)
                        luassert.is_equal(instance.componentName, "FieldsComp")
                    end
                )

                it(
                    "passes nil through when no defaults",
                    function()
                        local record FieldsNilComp is tecs.Component
                            a: number
                            b: number
                            metamethod __call: function(self, a: number, b: number): FieldsNilComp
                        end

                        tecs.ecs.newComponent({
                            name = "FieldsNilComp",
                            container = FieldsNilComp,
                            fields = {"a", "b"},
                        })

                        local instance = FieldsNilComp(nil, 5)
                        luassert.is_nil(instance.a)
                        luassert.is_equal(instance.b, 5)
                    end
                )
            end
        )

        describe(
            "fields with defaults",
            function()
                it(
                    "applies defaults for omitted args",
                    function()
                        local record DefaultsComp is tecs.Component
                            x: number
                            y: number
                            z: number
                            metamethod __call: function(self, x?: number, y?: number, z?: number): DefaultsComp
                        end

                        tecs.ecs.newComponent({
                            name = "DefaultsComp",
                            container = DefaultsComp,
                            fields = {"x", "y", "z"},
                            defaults = {0, 0, 0},
                        })

                        local instance = DefaultsComp()
                        luassert.is_equal(instance.x, 0)
                        luassert.is_equal(instance.y, 0)
                        luassert.is_equal(instance.z, 0)
                    end
                )

                it(
                    "supplied args override defaults",
                    function()
                        local record OverrideComp is tecs.Component
                            a: number
                            b: number
                            metamethod __call: function(self, a?: number, b?: number): OverrideComp
                        end

                        tecs.ecs.newComponent({
                            name = "OverrideComp",
                            container = OverrideComp,
                            fields = {"a", "b"},
                            defaults = {10, 20},
                        })

                        local instance = OverrideComp(99, 88)
                        luassert.is_equal(instance.a, 99)
                        luassert.is_equal(instance.b, 88)
                    end
                )

                it(
                    "partially supplied args use defaults for the rest",
                    function()
                        local record PartialComp is tecs.Component
                            x: number
                            y: number
                            z: number
                            metamethod __call: function(self, x?: number, y?: number, z?: number): PartialComp
                        end

                        tecs.ecs.newComponent({
                            name = "PartialComp",
                            container = PartialComp,
                            fields = {"x", "y", "z"},
                            defaults = {1, 2, 3},
                        })

                        local instance = PartialComp(100)
                        luassert.is_equal(instance.x, 100)
                        luassert.is_equal(instance.y, 2)
                        luassert.is_equal(instance.z, 3)
                    end
                )

                it(
                    "nil holes in defaults leave those fields without defaults",
                    function()
                        local record HolesComp is tecs.Component
                            mode: string
                            alpha: string
                            metamethod __call: function(self, mode: string, alpha?: string): HolesComp
                        end

                        tecs.ecs.newComponent({
                            name = "HolesComp",
                            container = HolesComp,
                            fields = {"mode", "alpha"},
                            defaults = {nil, "alphamultiply"},
                        })

                        local instance = HolesComp("add")
                        luassert.is_equal(instance.mode, "add")
                        luassert.is_equal(instance.alpha, "alphamultiply")

                        local instance2 = HolesComp("multiply", "premultiplied")
                        luassert.is_equal(instance2.mode, "multiply")
                        luassert.is_equal(instance2.alpha, "premultiplied")

                        local instance3 = HolesComp(nil)
                        luassert.is_nil(instance3.mode)
                        luassert.is_equal(instance3.alpha, "alphamultiply")
                    end
                )

                it(
                    "string defaults work",
                    function()
                        local record StrDefComp is tecs.Component
                            label: string
                            metamethod __call: function(self, label?: string): StrDefComp
                        end

                        tecs.ecs.newComponent({
                            name = "StrDefComp",
                            container = StrDefComp,
                            fields = {"label"},
                            defaults = {"untitled"},
                        })

                        luassert.is_equal(StrDefComp().label, "untitled")
                        luassert.is_equal(StrDefComp("hello").label, "hello")
                    end
                )

                it(
                    "errors when defaults provided without fields",
                    function()
                        luassert.has_error(function()
                            tecs.ecs.newComponent({
                                name = "BadDefaultsComp",
                                container = {},
                                defaults = {0, 0},
                            })
                        end, "Component BadDefaultsComp: `defaults` requires `fields`")
                    end
                )

                it(
                    "metatable fallback works with defaults",
                    function()
                        local record MetaComp is tecs.Component
                            value: number
                            metamethod __call: function(self, value?: number): MetaComp
                        end

                        tecs.ecs.newComponent({
                            name = "MetaComp",
                            container = MetaComp,
                            fields = {"value"},
                            defaults = {42},
                        })

                        local instance = MetaComp()
                        luassert.is_equal(instance.value, 42)
                        luassert.is_equal(instance.componentName, "MetaComp")
                        luassert.is_equal(instance.componentType, MetaComp)
                    end
                )
            end
        )

        describe(
            "relationship serialization",
            function()
                it(
                    "serializes and deserializes dense relationship instances",
                    function()
                        local record Follows is tecs.Relationship
                            metamethod __call: function(self, target: integer): Follows
                        end
                        local FollowsContainer: Follows = tecs.ecs.newRelationship({
                            name = "SerFollows",
                            exclusive = false,
                        }) as Follows

                        local inst = FollowsContainer(42) as tecs.Relationship
                        local data = FollowsContainer.serialize(inst)
                        luassert.is_equal(42, data.target)

                        local w = tecs.ecs.newWorld()
                        local restored = FollowsContainer.deserialize(w, data)
                        luassert.is_equal(42, (restored as tecs.Relationship).target)
                    end
                )

                it(
                    "serializes sparse relationship values via the container",
                    function()
                        local record Parent is tecs.Relationship
                            metamethod __call: function(self, target: integer): Parent
                        end
                        local ParentOf: Parent = tecs.ecs.newRelationship({
                            name = "SerParentOf",
                            exclusive = true,
                            sparse = true,
                            reverseIndex = true,
                        }) as Parent

                        local w = tecs.ecs.newWorld()
                        local parent = w:spawn()
                        local child = w:spawn(ParentOf(parent))
                        w:commit()

                        -- Sparse: value lives in the per-world store.
                        local stores = (w as {string: any}).relationshipStores as {tecs.Component: any}
                        local store = stores[ParentOf as tecs.Component] as {string: any}
                        local value = store:get(child)
                        luassert.is_not_nil(value, "store should hold the sparse value")

                        local data = ParentOf.serialize(value)
                        luassert.is_equal(parent, data.target)
                    end
                )
            end
        )

        describe(
            "constructor defaults",
            function()
                it(
                    "preserves false defaults",
                    function()
                        local record Flags is tecs.Component
                            flag: boolean
                            n: number
                        end
                        local FlagComp: Flags = tecs.ecs.newComponent({
                            name = "FalseDefaultComp" .. math.random(1, 1000000),
                            container = {} as Flags,
                            fields = {"flag", "n"},
                            defaults = {false, 5},
                        })

                        local a = FlagComp()
                        luassert.equals(false, a.flag, "an omitted argument must take the false default, not nil")
                        luassert.equals(5, a.n)

                        local b = FlagComp(true, 1)
                        luassert.is_true(b.flag)
                        luassert.equals(1, b.n)
                    end
                )
            end
        )
    end
)
