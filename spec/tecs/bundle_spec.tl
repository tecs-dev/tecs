require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

-- Type alias for bundle type (world:newBundle returns any to avoid circular deps)
local type Bundle = tecs.Bundle

describe(
    "bundle",
    function()
        local world: tecs.World

        before_each(function() world = tecs.newWorld() end)

        describe(
            "creation",
            function()
                it(
                    "creates a bundle with no components",
                    function()
                        local bundle = world:newBundle("TestBundle1") as Bundle
                        luassert.is_not_nil(bundle, "Bundle should not be nil")
                        luassert.is_function(bundle.spawn, "Bundle should have spawn method")
                    end
                )

                it(
                    "creates a bundle with defaulted components",
                    function()
                        local Tag1 = tecs.newTagComponent({name = "BundleTag1"})
                        local Tag2 = tecs.newTagComponent({name = "BundleTag2"})

                        local bundle = world:newBundle(
                            "TestBundle2",
                            {
                                with = {
                                    [Tag1] = true,
                                    [Tag2] = true,
                                },
                            }
                        ) as Bundle

                        luassert.is_not_nil(bundle, "Bundle should be created")
                        luassert.is_function(bundle.spawn, "Bundle should have spawn method")
                    end
                )

                it(
                    "creates a bundle with metadata",
                    function()
                        local Tag3 = tecs.newTagComponent({name = "BundleTag3"})

                        local bundle = world:newBundle(
                            "TestBundle3",
                            {
                                with = {
                                    [Tag3] = true,
                                },
                            }
                        ) as Bundle

                        luassert.is_not_nil(bundle, "Bundle should be created")
                        luassert.is_equal(bundle.name, "TestBundle3", "Bundle should have name")
                        luassert.is_table(bundle.required, "Bundle should have required list")
                        luassert.is_table(bundle.defaulted, "Bundle should have defaulted list")
                        luassert.is_function(bundle.spawn, "Bundle should have spawn method")
                    end
                )

                it(
                    "registers bundle with world",
                    function()
                        local Tag = tecs.newTagComponent({name = "RegisteredBundleTag"})

                        world:newBundle(
                            "RegisteredBundle",
                            {
                                with = {
                                    [Tag] = true,
                                },
                            }
                        )

                        local bundles = world:getBundles() as {string: Bundle}
                        luassert.is_not_nil(bundles["RegisteredBundle"], "Bundle should be registered by name")
                        bundles["RegisteredBundle"] = nil
                        luassert.is_not_nil(
                            world:getBundle("RegisteredBundle"),
                            "mutating the returned map must not change the world's registry"
                        )
                    end
                )
            end
        )

        describe(
            "bundle functionality",
            function()
                it(
                    "calls factories when no overrides provided",
                    function()
                        local record BundleTestComponent1 is tecs.Component
                            value: number
                        end

                        local TC = tecs.newComponent({
                            name = "BundleTestComponent1",
                            container = BundleTestComponent1,
                            fields = {"value"},
                            init = function(instance: BundleTestComponent1, value: number)
                                instance.value = value or 0
                            end,
                        })

                        local Tag4 = tecs.newTagComponent({name = "BundleTag4"})

                        local factoryCalled = 0
                        local bundle = world:newBundle(
                            "TestBundle4",
                            {
                                with = {
                                    [TC] = function(): BundleTestComponent1
                                        factoryCalled = factoryCalled + 1
                                        return TC(42)
                                    end,
                                    [Tag4] = true,
                                },
                            }
                        ) as Bundle

                        local entityId = bundle:spawn()
                        world:commit()

                        luassert.is_equal(factoryCalled, 1, "Factory should be called once")
                        local comp = world:get(entityId, TC) as BundleTestComponent1
                        luassert.is_not_nil(comp)
                        luassert.is_equal(comp.value, 42, "Component should have correct value")
                        luassert.is_true((world:get(entityId, Tag4) ~= nil), "Should have Tag4")
                    end
                )

                it(
                    "creates fresh instances on each spawn",
                    function()
                        local record TestComponent3 is tecs.Component
                            id: integer
                        end

                        local TC3 = tecs.newComponent({
                            name = "BundleTestComponent3",
                            container = TestComponent3,
                            fields = {"id"},
                            init = function(instance: TestComponent3, id: integer) instance.id = id or 0 end,
                        })

                        local callCount = 0
                        local bundle = world:newBundle(
                            "TestBundle6",
                            {
                                with = {
                                    [TC3] = function(): TestComponent3
                                        callCount = callCount + 1
                                        return TC3(callCount)
                                    end,
                                },
                            }
                        ) as Bundle

                        local id1 = bundle:spawn()
                        local id2 = bundle:spawn()
                        world:commit()

                        luassert.is_equal(callCount, 2, "Factory should be called twice")
                        local c1 = world:get(id1, TC3) as TestComponent3
                        local c2 = world:get(id2, TC3) as TestComponent3
                        luassert.is_not_equal(c1, c2, "Should create different instances")
                        luassert.is_equal(c1.id, 1, "First spawn should have id 1")
                        luassert.is_equal(c2.id, 2, "Second spawn should have id 2")
                    end
                )

                it(
                    "handles empty bundle",
                    function()
                        local bundle = world:newBundle("EmptyBundle") as Bundle
                        local entityId = bundle:spawn()
                        world:commit()
                        luassert.is_true(world:isAlive(entityId), "Empty bundle should still spawn a bare entity")
                    end
                )
            end
        )

        describe(
            "type safety",
            function()
                it(
                    "enforces type-safe factories",
                    function()
                        local record TypedComponent is tecs.Component
                            x: number
                            y: number
                        end

                        local TC = tecs.newComponent({
                            name = "BundleTestComponent4",
                            container = TypedComponent,
                            fields = {"x", "y"},
                            init = function(instance: TypedComponent, x: number, y: number)
                                instance.x = x or 0
                                instance.y = y or 0
                            end,
                        })

                        -- This demonstrates type safety - the factory must return the correct type.
                        local bundle = world:newBundle(
                            "TypedBundle",
                            {
                                with = {
                                    [TC] = function(): TypedComponent return TC(10, 20) end,
                                },
                            }
                        ) as Bundle

                        local entityId = bundle:spawn()
                        world:commit()
                        local comp = world:get(entityId, TC) as TypedComponent
                        luassert.is_equal(comp.x, 10, "Should have correct x")
                        luassert.is_equal(comp.y, 20, "Should have correct y")
                    end
                )
            end
        )

        describe(
            "required components",
            function()
                it(
                    "allows marking components as required",
                    function()
                        local Tag1 = tecs.newTagComponent({name = "RequiredTag1"})
                        local Tag2 = tecs.newTagComponent({name = "RequiredTag2"})

                        local bundle = world:newBundle(
                            "RequiredBundle1",
                            {
                                required = {Tag1, Tag2},
                            }
                        ) as Bundle

                        luassert.is_not_nil(bundle, "Bundle should be created with required components")
                        luassert.is_function(bundle.spawn, "Bundle should have spawn method")
                    end
                )

                it(
                    "tracks required vs defaulted in metadata",
                    function()
                        local record RC is tecs.Component
                            id: integer
                        end

                        local RequiredComp = tecs.newComponent({
                            name = "MetadataRequiredComp",
                            container = RC,
                            fields = {"id"},
                            init = function(instance: RC, id: integer) instance.id = id or 0 end,
                        })

                        local record DC is tecs.Component
                            name: string
                        end

                        local DefaultedComp = tecs.newComponent({
                            name = "MetadataDefaultedComp",
                            container = DC,
                            fields = {"name"},
                            init = function(instance: DC, name: string) instance.name = name or "" end,
                        })

                        local bundle = world:newBundle(
                            "MetadataBundle",
                            {
                                required = {RequiredComp},
                                with = {
                                    [DefaultedComp] = function(): DC return DefaultedComp("default") end,
                                },
                            }
                        ) as Bundle

                        luassert.is_equal(#bundle.required, 1, "Should have 1 required")
                        luassert.is_equal(#bundle.defaulted, 1, "Should have 1 defaulted")
                        luassert.is_equal(bundle.required[1], "MetadataRequiredComp", "Required should be tracked")
                        luassert.is_equal(bundle.defaulted[1], "MetadataDefaultedComp", "Defaulted should be tracked")
                    end
                )

                it(
                    "validates all required components are provided",
                    function()
                        local record RequiredBundleTestComponent is tecs.Component
                            value: number
                        end

                        local TC = tecs.newComponent({
                            name = "RequiredBundleTestComponent",
                            container = RequiredBundleTestComponent,
                            fields = {"value"},
                            init = function(instance: RequiredBundleTestComponent, value: number)
                                instance.value = value or 0
                            end,
                        })

                        local Tag3 = tecs.newTagComponent({name = "RequiredTag3"})

                        local bundle = world:newBundle(
                            "RequiredBundle2",
                            {
                                required = {TC, Tag3},
                            }
                        ) as Bundle

                        local entityId = bundle:spawn(TC(42), Tag3())
                        world:commit()

                        local comp = world:get(entityId, TC) as RequiredBundleTestComponent
                        luassert.is_not_nil(comp, "Should have required TC")
                        luassert.is_equal(comp.value, 42, "TC should have correct value")
                        luassert.is_true((world:get(entityId, Tag3) ~= nil), "Should have required Tag3")
                    end
                )

                it(
                    "errors when a required component is missing at spawn",
                    function()
                        local record TestComponent2 is tecs.Component
                            name: string
                        end

                        local TC2 = tecs.newComponent({
                            name = "RequiredBundleTestComponent2",
                            container = TestComponent2,
                            fields = {"name"},
                            init = function(instance: TestComponent2, name: string) instance.name = name or "" end,
                        })

                        local Tag4 = tecs.newTagComponent({name = "RequiredTag4"})
                        local bundle = world:newBundle(
                            "RequiredBundle3",
                            {
                                required = {TC2, Tag4},
                            }
                        ) as Bundle

                        -- Only 1 required arg passed, second slot is nil, codegen errors.
                        luassert.has_error(function()
                            bundle:spawn(TC2("hi"))
                        end, "Required component missing: RequiredTag4"
                        )
                    end
                )

                it(
                    "works with mixed required and optional components",
                    function()
                        local record RequiredComp is tecs.Component
                            id: integer
                        end

                        local RC = tecs.newComponent({
                            name = "RequiredBundleComponent3",
                            container = RequiredComp,
                            fields = {"id"},
                            init = function(instance: RequiredComp, id: integer) instance.id = id or 0 end,
                        })

                        local record OptionalComp is tecs.Component
                            name: string
                        end

                        local OC = tecs.newComponent({
                            name = "OptionalBundleComponent",
                            container = OptionalComp,
                            fields = {"name"},
                            init = function(instance: OptionalComp, name: string)
                                instance.name = name or "default"
                            end,
                        })

                        local Tag6 = tecs.newTagComponent({name = "OptionalTag6"})

                        local bundle = world:newBundle(
                            "MixedBundle",
                            {
                                required = {RC},
                                with = {
                                    [OC] = function(): OptionalComp return OC("default_name") end,
                                    [Tag6] = true,
                                },
                            }
                        ) as Bundle

                        -- Required value is positional; optional slots always use factory.
                        local entityId = bundle:spawn(RC(100))
                        world:commit()

                        local rc = world:get(entityId, RC) as RequiredComp
                        luassert.is_not_nil(rc)
                        luassert.is_equal(rc.id, 100)

                        local oc = world:get(entityId, OC) as OptionalComp
                        luassert.is_not_nil(oc)
                        luassert.is_equal(oc.name, "default_name")

                        luassert.is_true((world:get(entityId, Tag6) ~= nil))
                    end
                )

                it(
                    "supports mixed required and with components",
                    function()
                        local Tag7 = tecs.newTagComponent({name = "BundleChainTag7"})
                        local Tag8 = tecs.newTagComponent({name = "BundleChainTag8"})
                        local Tag9 = tecs.newTagComponent({name = "BundleChainTag9"})

                        local bundle = world:newBundle(
                            "ChainBundle",
                            {
                                required = {Tag7, Tag9},
                                with = {
                                    [Tag8] = true,
                                },
                            }
                        ) as Bundle

                        -- Required args are positional in declaration order: Tag7, Tag9.
                        local entityId = bundle:spawn(Tag7(), Tag9())
                        world:commit()
                        luassert.is_true((world:get(entityId, Tag7) ~= nil))
                        luassert.is_true((world:get(entityId, Tag8) ~= nil))
                        luassert.is_true((world:get(entityId, Tag9) ~= nil))

                        -- Missing second required arg errors with that component's name.
                        luassert.has_error(function()
                            bundle:spawn(Tag7())
                        end, "Required component missing: BundleChainTag9"
                        )
                    end
                )

                it(
                    "handles bundles with only required components",
                    function()
                        local Tag10 = tecs.newTagComponent({name = "EmptyBundleTag"})

                        local bundle = world:newBundle(
                            "EmptyRequiredBundle",
                            {
                                required = {Tag10},
                            }
                        ) as Bundle

                        local entityId = bundle:spawn(Tag10())
                        world:commit()
                        luassert.is_true((world:get(entityId, Tag10) ~= nil))

                        luassert.has_error(function() bundle:spawn() end, "Required component missing: EmptyBundleTag")
                    end
                )
            end
        )

        describe(
            "spawn functionality",
            function()
                it(
                    "spawns entity via bundle:spawn()",
                    function()
                        local record SpawnTestComp is tecs.Component
                            value: number
                        end

                        local TC = tecs.newComponent({
                            name = "BundleSpawnTestComp",
                            container = SpawnTestComp,
                            fields = {"value"},
                            init = function(instance: SpawnTestComp, value: number) instance.value = value or 0 end,
                        })

                        local bundle = world:newBundle(
                            "SpawnBundle",
                            {
                                required = {TC},
                            }
                        ) as Bundle

                        local entityId = bundle:spawn(TC(42))
                        luassert.is_number(entityId, "Should return entity ID")
                        luassert.is_true(entityId > 0, "Entity ID should be positive")

                        -- Commit and verify entity exists
                        world:commit()
                        luassert.is_true(world:isAlive(entityId), "Entity should be alive")

                        local comp = world:get(entityId, TC)
                        luassert.is_not_nil(comp, "Entity should have component")
                        luassert.is_equal(comp.value, 42, "Component should have correct value")
                    end
                )

                it(
                    "spawns entity via world:spawnBundle()",
                    function()
                        local record SpawnTestComp2 is tecs.Component
                            name: string
                        end

                        local TC = tecs.newComponent({
                            name = "WorldSpawnTestComp",
                            container = SpawnTestComp2,
                            fields = {"name"},
                            init = function(instance: SpawnTestComp2, name: string) instance.name = name or "" end,
                        })

                        world:newBundle(
                            "WorldSpawnBundle",
                            {
                                required = {TC},
                            }
                        )

                        local entityId = world:spawnBundle("WorldSpawnBundle", TC("test"))
                        luassert.is_number(entityId, "Should return entity ID")

                        world:commit()
                        luassert.is_true(world:isAlive(entityId), "Entity should be alive")

                        local comp = world:get(entityId, TC)
                        luassert.is_not_nil(comp, "Entity should have component")
                        luassert.is_equal(comp.name, "test", "Component should have correct value")
                    end
                )

                it(
                    "errors on unknown bundle name",
                    function()
                        luassert.has_error(function()
                            world:spawnBundle("NonExistentBundle")
                        end, "Unknown bundle: NonExistentBundle"
                        )
                    end
                )
            end
        )

        describe(
            "deferred spawn semantics",
            function()
                -- Note: bundle:spawn is immediate outside of a defer scope (matches
                -- world:spawn). These tests verify deferred semantics by wrapping
                -- bundle spawns in world:defer() / world:commit().
                it(
                    "defers placement until commit",
                    function()
                        local record DC1 is tecs.Component
                            x: integer
                        end
                        local Comp = tecs.newComponent({
                            name = "DeferComp1",
                            container = DC1,
                            fields = {"x"},
                        })
                        local bundle = world:newBundle(
                            "DeferBundle1",
                            {
                                required = {Comp},
                            }
                        ) as Bundle

                        world:defer()
                        local id = bundle:spawn(Comp(42))
                        -- Before commit: entity not yet placed in entityIndex.
                        luassert.is_false(world:isAlive(id), "Entity should not be alive before commit")

                        world:commit()
                        luassert.is_true(world:isAlive(id), "Entity should be alive after commit")
                        local comp = world:get(id, Comp) as DC1
                        luassert.is_equal(comp.x, 42)
                    end
                )

                it(
                    "drains multiple bundle spawns in insertion order",
                    function()
                        local record DC2 is tecs.Component
                            x: integer
                        end
                        local Comp = tecs.newComponent({
                            name = "DeferComp2",
                            container = DC2,
                            fields = {"x"},
                        })
                        local bundle = world:newBundle(
                            "DeferBundle2",
                            {
                                required = {Comp},
                            }
                        ) as Bundle

                        world:defer()
                        local ids: {integer} = {}
                        for i = 1, 100 do
                            ids[i] = bundle:spawn(Comp(i))
                        end
                        world:commit()

                        for i = 1, 100 do
                            luassert.is_true(world:isAlive(ids[i]))
                            local c = world:get(ids[i], Comp) as DC2
                            luassert.is_equal(c.x, i, "Entity " .. i .. " should have x=" .. i)
                        end
                    end
                )

                it(
                    "supports world:set on a bundle-spawned id before commit",
                    function()
                        local record DC3Pos is tecs.Component
                            x: integer
                            y: integer
                        end
                        local record DC3Health is tecs.Component
                            hp: integer
                        end
                        local Pos = tecs.newComponent({
                            name = "DeferPos3",
                            container = DC3Pos,
                            fields = {"x", "y"},
                        })
                        local Health = tecs.newComponent({
                            name = "DeferHealth3",
                            container = DC3Health,
                            fields = {"hp"},
                        })

                        local bundle = world:newBundle(
                            "DeferBundle3",
                            {
                                required = {Pos},
                            }
                        ) as Bundle

                        -- Inside a defer scope: bundle spawn queues, world:set stages.
                        -- The ledger walker transitions the bundle-placed entity from
                        -- its target arch (just Pos) to (Pos + Health) at commit.
                        world:defer()
                        local id = bundle:spawn(Pos(10, 20))
                        world:set(id, Health(100))
                        world:commit()

                        luassert.is_true(world:isAlive(id))
                        local p = world:get(id, Pos) as DC3Pos
                        luassert.is_equal(p.x, 10)
                        luassert.is_equal(p.y, 20)
                        local h = world:get(id, Health) as DC3Health
                        luassert.is_equal(h.hp, 100)
                    end
                )

                it(
                    "interleaves bundle spawns across different bundles in one commit",
                    function()
                        local record DC4A is tecs.Component
                            v: integer
                        end
                        local record DC4B is tecs.Component
                            v: integer
                        end
                        local CompA = tecs.newComponent({
                            name = "DeferA4",
                            container = DC4A,
                            fields = {"v"},
                        })
                        local CompB = tecs.newComponent({
                            name = "DeferB4",
                            container = DC4B,
                            fields = {"v"},
                        })

                        local bundleA = world:newBundle("DeferBundle4A", {required = {CompA}}) as Bundle
                        local bundleB = world:newBundle("DeferBundle4B", {required = {CompB}}) as Bundle

                        world:defer()
                        local idA1 = bundleA:spawn(CompA(1))
                        local idB1 = bundleB:spawn(CompB(10))
                        local idA2 = bundleA:spawn(CompA(2))
                        local idB2 = bundleB:spawn(CompB(20))
                        world:commit()

                        luassert.is_equal((world:get(idA1, CompA) as DC4A).v, 1)
                        luassert.is_equal((world:get(idA2, CompA) as DC4A).v, 2)
                        luassert.is_equal((world:get(idB1, CompB) as DC4B).v, 10)
                        luassert.is_equal((world:get(idB2, CompB) as DC4B).v, 20)
                    end
                )

                it(
                    "handles dense relationships as required components",
                    function()
                        local record DenseRelData is tecs.Relationship
                            strength: number
                            metamethod __call: function(self, target: integer, strength: number): DenseRelData
                        end
                        local DenseRel = tecs.newRelationship({
                            name = "DeferDenseRel",
                            container = DenseRelData,
                            fields = {"strength"},
                            init = function(instance: DenseRelData, _target: integer, strength: number)
                                instance.strength = strength or 1
                            end,
                        })

                        local target = world:spawn()
                        world:commit()

                        local bundle = world:newBundle(
                            "DenseRelBundle",
                            {
                                required = {DenseRel},
                            }
                        ) as Bundle

                        local src = bundle:spawn(DenseRel(target, 7))
                        world:commit()

                        luassert.is_true(world:isAlive(src))
                        -- Dense rel container is a wildcard tag; presence is observable via get on container.
                        luassert.is_not_nil(world:get(src, DenseRel), "source should carry the DenseRel container tag")
                    end
                )

                it(
                    "routes sparse relationships through setSparse",
                    function()
                        local SparseRel = tecs.newRelationship({
                            name = "DeferChildOf",
                            exclusive = true,
                            sparse = true,
                            reverseIndex = true,
                        })
                        local record DCPos is tecs.Component
                            x: integer
                            y: integer
                        end
                        local PosComp = tecs.newComponent({
                            name = "DeferChildPos",
                            container = DCPos,
                            fields = {"x", "y"},
                        })

                        local parent = world:spawn(PosComp(0, 0))
                        world:commit()

                        local bundle = world:newBundle(
                            "SparseChildBundle",
                            {
                                required = {SparseRel, PosComp},
                            }
                        ) as Bundle

                        local child = bundle:spawn(SparseRel(parent), PosComp(5, 10))
                        world:commit()

                        luassert.is_true(world:isAlive(child))
                        local pos = world:get(child, PosComp) as DCPos
                        luassert.is_equal(pos.x, 5)
                        luassert.is_equal(pos.y, 10)

                        -- Reverse index should see the child via the parent.
                        local found = false
                        world:targets(
                            parent,
                            SparseRel,
                            function(sourceId)
                                if sourceId == child then
                                    found = true
                                end
                            end
                        )
                        luassert.is_true(found, "parent's reverse index should include child")
                    end
                )

                it(
                    "survives world:clearEntities between commits",
                    function()
                        local record DC5 is tecs.Component
                            v: integer
                        end
                        local Comp = tecs.newComponent({
                            name = "DeferComp5",
                            container = DC5,
                            fields = {"v"},
                        })
                        local bundle = world:newBundle(
                            "DeferBundle5",
                            {
                                required = {Comp},
                            }
                        ) as Bundle

                        -- First commit: spawn and commit.
                        local id1 = bundle:spawn(Comp(1))
                        world:commit()
                        luassert.is_true(world:isAlive(id1))

                        -- clearEntities drops entities + queues but preserves the bundle
                        -- registration (and the pipeline, systems, queries).
                        world:clearEntities()
                        luassert.is_false(world:isAlive(id1))

                        -- The same bundle handle keeps working -- no re-registration needed.
                        local id2 = bundle:spawn(Comp(42))
                        world:commit()
                        luassert.is_true(world:isAlive(id2))
                        luassert.is_equal((world:get(id2, Comp) as DC5).v, 42)
                    end
                )
            end
        )

        describe(
            "column cache invalidation",
            function()
                local record GenComp is tecs.Component
                    x: number
                end

                local GC = tecs.newFFIComponent({
                    name = "BundleGenCacheComp",
                    container = GenComp,
                    fields = {{"x", "float"}},
                })

                local function newCountingBundle(name: string): Bundle, function(): number
                    local nextVal = 0
                    local bundle = world:newBundle(
                        name,
                        {
                            with = {
                                [GC] = function(): GenComp nextVal = nextVal + 1; return GC(nextVal) end,
                            },
                        }
                    ) as Bundle
                    return bundle, function(): number return nextVal end
                end

                local function getX(id: integer): number
                    return (world:get(id, GC) as GenComp).x
                end

                it(
                    "immediate spawn survives external archetype growth",
                    function()
                        local bundle = newCountingBundle("GenCacheImmediate")

                        local first = bundle:spawn()
                        -- Grow the same archetype through the plain spawn path so its
                        -- columns reallocate behind the bundle's cache.
                        local others: {integer} = {}
                        for i = 1, 300 do
                            others[i] = world:spawn(GC(1000 + i))
                        end
                        world:commit()

                        local second = bundle:spawn()
                        world:commit()

                        luassert.equals(1, getX(first))
                        luassert.equals(2, getX(second))
                        for i = 1, 300 do
                            luassert.equals(1000 + i, getX(others[i]))
                        end
                    end
                )

                it(
                    "deferred drain survives external archetype growth",
                    function()
                        local bundle = newCountingBundle("GenCacheDrain")

                        local first = bundle:spawn()
                        local others: {integer} = {}
                        for i = 1, 300 do
                            others[i] = world:spawn(GC(1000 + i))
                        end
                        world:commit()

                        world:defer()
                        local second = bundle:spawn()
                        world:commit()

                        luassert.equals(1, getX(first))
                        luassert.equals(2, getX(second))
                        for i = 1, 300 do
                            luassert.equals(1000 + i, getX(others[i]))
                        end
                    end
                )
            end
        )

        describe(
            "spawn-path parity",
            function()
                it(
                    "expands requires like other spawn paths",
                    function()
                        local record ReqBase is tecs.Component
                            v: number
                        end
                        local Base = tecs.newComponent({
                            name = "BundleReqBase",
                            container = ReqBase,
                            fields = {"v"},
                            defaults = {41},
                        })
                        local record ReqTop is tecs.Component
                            t: number
                        end
                        local Top = tecs.newComponent({
                            name = "BundleReqTop",
                            container = ReqTop,
                            fields = {"t"},
                            defaults = {0},
                            requires = {Base},
                        })

                        local bundle = world:newBundle(
                            "RequiresBundle",
                            {
                                with = {
                                    [Top] = function(): ReqTop return Top(7) end,
                                },
                            }
                        ) as Bundle

                        -- Immediate path.
                        local e1 = bundle:spawn()
                        world:commit()
                        luassert.equals(7, (world:get(e1, Top) as ReqTop).t)
                        luassert.is_not_nil(world:get(e1, Base), "requires must add the base component")
                        luassert.equals(41, (world:get(e1, Base) as ReqBase).v, "requires default must be written")

                        -- Deferred path.
                        world:defer()
                        local e2 = bundle:spawn()
                        world:commit()
                        luassert.equals(7, (world:get(e2, Top) as ReqTop).t)
                        luassert.equals(41, (world:get(e2, Base) as ReqBase).v)
                    end
                )

                it(
                    "adds the wildcard container for dense relationship instances",
                    function()
                        local Owes = tecs.newRelationship({
                            name = "BundleWildcardOwes",
                        })
                        local target = world:spawn()
                        world:commit()
                        local instance = Owes(target) as tecs.Component

                        local bundle = world:newBundle(
                            "WildcardBundle",
                            {
                                with = {
                                    [instance] = function(): tecs.Component return instance end,
                                },
                            }
                        ) as Bundle

                        local e = bundle:spawn()
                        world:commit()

                        -- Wildcard queries match through the container marker.
                        local q = world:query({include = {Owes as tecs.Component}, temp = true})
                        local found = false
                        for _, len, entities in q:iter() do
                            for r = 1, len do
                                if entities[r] == e then
                                    found = true
                                end
                            end
                        end
                        luassert.is_true(found, "bundle spawn must add the wildcard container")
                    end
                )

                it(
                    "a despawn staged before commit wins over the bundle drain",
                    function()
                        local Tag = tecs.newTagComponent({name = "BundleDespawnWinsTag"})
                        local bundle = world:newBundle(
                            "DespawnWinsBundle",
                            {
                                with = {[Tag] = true},
                            }
                        ) as Bundle

                        world:defer()
                        local id = bundle:spawn()
                        world:despawn(id)
                        world:commit()

                        luassert.is_false(world:isAlive(id), "the bundle drain must not resurrect a despawned entity")
                    end
                )

                it(
                    "applies sparse relationship values immediately at scope depth 0",
                    function()
                        local Follows = tecs.newRelationship({
                            name = "BundleSparseFollows",
                            sparse = true,
                            exclusive = true,
                        })
                        local target = world:spawn()
                        world:commit()

                        local bundle = world:newBundle(
                            "SparseBundle",
                            {
                                with = {
                                    [Follows as tecs.Component] = function(): tecs.Component
                                        return Follows(target) as tecs.Component
                                    end,
                                },
                            }
                        ) as Bundle

                        local e = bundle:spawn()
                        local rel = world:getFirstRelationship(e, Follows)
                        luassert.is_not_nil(rel, "immediate bundle spawn must commit sparse values")
                        luassert.equals(target, rel.target)
                    end
                )

                it(
                    "places each burst into its enqueue-time state archetype",
                    function()
                        local Tag = tecs.newTagComponent({name = "BundleStateMixTag"})
                        local stateA = world:createState("BundleStateA")
                        local stateB = world:createState("BundleStateB")
                        local bundle = world:newBundle(
                            "StateMixBundle",
                            {
                                with = {[Tag] = true},
                            }
                        ) as Bundle

                        world:pushState("BundleStateA")
                        world:defer()
                        local e1 = bundle:spawn()
                        world:pushState("BundleStateB")
                        local e2 = bundle:spawn()
                        world:commit()

                        luassert.is_not_nil(world:get(e1, stateA), "first burst keeps state A")
                        luassert.is_nil(world:get(e1, stateB))
                        luassert.is_not_nil(world:get(e2, stateB), "second burst takes state B")
                    end
                )
            end
        )
    end
)
