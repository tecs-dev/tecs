require("busted")
local tecs <const> = require("tecs")
local Archetype <const> = require("tecs.internal.Archetype")
local ffi <const> = require("tecs.internal.ffi")
local luassert <const> = require("luassert")

-- Carries a field so it uses table-backed dense columns with per-target
-- registered instances, which is the representation this white-box archetype
-- test pokes directly. (A name-only relationship folds to FFI storage, whose
-- instances aren't registered per-target; that path is covered end-to-end via
-- ChildOf in relationships_spec.)
local TestRel <const> = tecs.ecs.newRelationship({name = "TestRel", fields = {"weight"}})

describe(
    "Archetype tests",
    function()
        describe(
            "creation",
            function()
                it(
                    "creates a new archetype with components",
                    function()
                        local componentTypes: {tecs.ecs.Component} = {tecs.ecs.Name, tecs.ecs.TTL}
                        local arch = Archetype.new(componentTypes)

                        luassert.is_not_nil(arch, "Expected Archetype.new() to return a non-nil value")
                        luassert.is_equal(2, arch.columnsCount, "Expected columnsCount to be 2")
                        luassert.is_not_nil(arch.entities, "Expected entities to exist")
                        luassert.is_equal(0, arch.entities[0], "Expected entities to be empty")

                        -- Should have columns for both components
                        luassert.is_not_nil(arch.columns[tecs.ecs.Name], "Expected Name column to exist")
                        luassert.is_not_nil(arch.columns[tecs.ecs.TTL], "Expected TTL column to exist")
                        luassert.is_nil(arch.columns[tecs.Transform2D], "Expected Transform2D column to not exist")
                    end
                )

                it(
                    "assigns unique IDs to archetypes",
                    function()
                        local arch1 = Archetype.new({tecs.ecs.Name}, 1)
                        local arch2 = Archetype.new({tecs.ecs.Name}, 1)

                        luassert.not_equal(arch1.id, arch2.id, "Expected different IDs for different archetypes")
                    end
                )
            end
        )

        describe(
            "__tostring",
            function()
                it(
                    "returns a readable string representation",
                    function()
                        local arch = Archetype.new({tecs.ecs.Name, tecs.ecs.TTL}, 123)
                        local str = tostring(arch)

                        luassert.is_true(str:find("Archetype%(%[") ~= nil, "Expected to start with 'Archetype(['")
                        luassert.is_true(str:find("Name") ~= nil, "Expected to contain 'Name'")
                        luassert.is_true(str:find("TTL") ~= nil, "Expected to contain 'TTL'")
                    end
                )
            end
        )

        describe(
            "Finds matching relationships",
            function()
                it(
                    "ignore invalid components",
                    function()
                        local arch = Archetype.new({tecs.ecs.Name}, 123)

                        luassert.is_nil(arch:getFirstRelationship(TestRel, 10), "Expected no rel to be found")
                    end
                )

                it(
                    "finds relationship instances",
                    function()
                        local firstExpected = TestRel(1)
                        local arch = Archetype.new({TestRel, firstExpected}, 123)
                        (arch.entities as {integer})[1] = 1
                        ffi.setDoubleArraySize(arch.entities, 1)
                        arch.columns[TestRel][1] = TestRel
                        arch.columns[firstExpected as tecs.ecs.Component][1] = firstExpected -- TODO: Teal self bugs

                        local firstRel = arch:getFirstRelationship(TestRel, 1)
                        luassert.is_equal(firstRel, firstExpected, "Expected to be TestRel(1)")
                    end
                )

                it(
                    "finds all elationship instances",
                    function()
                        local firstExpected, secondExpected = TestRel(1), TestRel(2)
                        local arch = Archetype.new({TestRel, firstExpected, secondExpected}, 123)

                        (arch.entities as {integer})[1] = 1
                        ffi.setDoubleArraySize(arch.entities, 1)
                        arch.columns[TestRel][1] = TestRel
                        arch.columns[firstExpected as tecs.ecs.Component][1] = firstExpected -- TODO: Teal self bugs
                        arch.columns[secondExpected as tecs.ecs.Component][1] = secondExpected -- TODO: Teal self bugs

                        local rels = {}
                        arch:forEachRelationship(
                            TestRel,
                            1,
                            function(matchingRel: any)
                                table.insert(rels, matchingRel)
                                if matchingRel == TestRel then
                                    error("Expected to not find the TestRel instance")
                                end
                            end
                        )

                        luassert.is_equal(#rels, 2, "Expected to find 2 relationships")
                    end
                )
            end
        )

        describe(
            "entity observers",
            function()
                it(
                    "supports a typed public observer on a queried archetype",
                    function()
                        local w = tecs.ecs.newWorld()
                        local Tag = tecs.ecs.newTagComponent({
                            name = "PublicObsTag" .. math.random(1, 1000000),
                        })
                        w:spawn(Tag())
                        w:enqueueCommit()

                        local query = w:newQuery({include = {Tag}})
                        local observed: tecs.ecs.Archetype = nil
                        for arch in query:iter() do
                            observed = arch
                        end
                        luassert.is_not_nil(observed)

                        local added = 0
                        local observer: tecs.ecs.ArchetypeEntityObserver = {
                            onEntitiesAdded = function(
                                _self: tecs.ecs.ArchetypeEntityObserver,
                                arch: tecs.ecs.Archetype,
                                firstRow: integer,
                                lastRow: integer,
                                count: integer,
                                sourceArchetype?: tecs.ecs.Archetype
                            )
                                added = added + count
                                luassert.equals(observed, arch)
                                luassert.equals(2, firstRow)
                                luassert.equals(2, lastRow)
                                luassert.is_nil(sourceArchetype)
                            end,
                        }
                        observed:addEntityObserver(observer)

                        w:spawn(Tag())
                        w:enqueueCommit()

                        luassert.equals(1, added)
                    end
                )

                it(
                    "notifies a move-only observer on swap-pop",
                    function()
                        local WorldImpl <const> = require("tecs.internal.world")
                        local w = tecs.ecs.newWorld()
                        local Tag = tecs.ecs.newTagComponent({name = "MoveObsTag" .. math.random(1, 1000000)})
                        local e1 = w:spawn(Tag())
                        local e2 = w:spawn(Tag())
                        w:enqueueCommit()

                        local moves = 0
                        local arch = (w as WorldImpl):currentArchetype(e1)
                        arch:addEntityObserver({
                            onEntityMove = function(
                                _self: any, _arch: any, entity: integer, _from: integer, to: integer
                            )
                                moves = moves + 1
                                luassert.equals(e2, entity, "the swapped-in entity is reported")
                                luassert.equals(0, to, "e2 moves into e1's row")
                            end,
                        } as any)

                        -- Despawning e1 swap-pops e2 into its row.
                        w:despawn(e1)
                        w:enqueueCommit()

                        luassert.equals(1, moves, "an observer defining only onEntityMove must hear swap-pop moves")
                    end
                )
            end
        )
    end
)
