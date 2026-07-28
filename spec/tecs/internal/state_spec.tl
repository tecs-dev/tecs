require("busted")
local tecs = require("tecs")
local luassert = require("luassert")
local describe <const> = describe
local it <const> = it
local before_each <const> = before_each

describe(
    "State Stack",
    function()
        local world: tecs.World

        before_each(function() world = tecs.ecs.newWorld() end)

        describe(
            "createState",
            function()
                it(
                    "should create a state and return a component",
                    function() local comp = world:createState("game"); luassert.is_not_nil(comp) end
                )

                it(
                    "should error if state already exists",
                    function()
                        world:createState("game")
                        luassert.error_matches(function() world:createState("game") end, "already exists")
                    end
                )
            end
        )

        describe(
            "pushState / popState / peekState",
            function()
                it("should return nil when stack is empty", function() luassert.is_nil(world:peekState()) end)

                it(
                    "should push and peek state",
                    function()
                        world:createState("game")
                        world:pushState("game")
                        luassert.is_equal("game", world:peekState())
                    end
                )

                it(
                    "should error when pushing unknown state",
                    function() luassert.error_matches(function() world:pushState("unknown") end, "not found") end
                )

                it(
                    "should pop state and return to previous",
                    function()
                        world:createState("game")
                        world:createState("paused")
                        world:pushState("game")
                        world:pushState("paused")
                        luassert.is_equal("paused", world:peekState())
                        world:popState()
                        luassert.is_equal("game", world:peekState())
                    end
                )

                it(
                    "should error when popping empty stack",
                    function() luassert.error_matches(function() world:popState() end, "empty") end
                )
            end
        )

        describe(
            "State events",
            function()
                it(
                    "should emit StateEnter on push",
                    function()
                        world:createState("game")
                        local entered: string = nil
                        world:observe(0, tecs.ecs.StateEnter, function(e: tecs.ecs.StateEnter) entered = e.state end)
                        world:pushState("game")
                        luassert.is_equal("game", entered)
                    end
                )

                it(
                    "should emit StateExit on pop",
                    function()
                        world:createState("game")
                        world:pushState("game")
                        local exited: string = nil
                        world:observe(0, tecs.ecs.StateExit, function(e: tecs.ecs.StateExit) exited = e.state end)
                        world:popState()
                        luassert.is_equal("game", exited)
                    end
                )

                it(
                    "should emit StateBlur when pushing on top",
                    function()
                        world:createState("game")
                        world:createState("paused")
                        world:pushState("game")
                        local blurred: string = nil
                        local pushed: string = nil
                        world:observe(
                            0,
                            tecs.ecs.StateBlur,
                            function(e: tecs.ecs.StateBlur) blurred = e.state; pushed = e.pushed end
                        )
                        world:pushState("paused")
                        luassert.is_equal("game", blurred)
                        luassert.is_equal("paused", pushed)
                    end
                )

                it(
                    "should emit StateFocus when state above is popped",
                    function()
                        world:createState("game")
                        world:createState("paused")
                        world:pushState("game")
                        world:pushState("paused")
                        local focused: string = nil
                        local popped: string = nil
                        world:observe(
                            0,
                            tecs.ecs.StateFocus,
                            function(e: tecs.ecs.StateFocus) focused = e.state; popped = e.popped end
                        )
                        world:popState()
                        luassert.is_equal("game", focused)
                        luassert.is_equal("paused", popped)
                    end
                )
            end
        )

        describe(
            "Auto-tagging",
            function()
                it(
                    "should auto-tag entities spawned during a state",
                    function()
                        local gameComponent = world:createState("game")
                        world:pushState("game")
                        local entity = world:spawn(tecs.Transform(0, 0))
                        world:commit()
                        local stateTag = world:get(entity, gameComponent)
                        luassert.is_not_nil(stateTag)
                    end
                )

                it(
                    "should not auto-tag entities spawned before any state",
                    function()
                        local gameComponent = world:createState("game")
                        local entity = world:spawn(tecs.Transform(0, 0))
                        world:commit()
                        local stateTag = world:get(entity, gameComponent)
                        luassert.is_nil(stateTag)
                    end
                )
            end
        )

        describe(
            "Policies",
            function()
                it(
                    "should despawn entities on exit by default",
                    function()
                        world:createState("game")
                        world:pushState("game")
                        local entity = world:spawn(tecs.Transform(0, 0))
                        world:commit()
                        luassert.is_true(world:isAlive(entity))
                        world:popState()
                        world:commit()
                        luassert.is_false(world:isAlive(entity))
                    end
                )

                it(
                    "should pause entities on blur with pause policy",
                    function()
                        world:createState(
                            "game",
                            {
                                onBlur = "pause",
                                onFocus = "resume",
                            }
                        )
                        world:createState("paused")
                        world:pushState("game")
                        local entity = world:spawn(tecs.Transform(0, 0))
                        world:commit()
                        -- Push paused state, game.onBlur should add Paused
                        world:pushState("paused")
                        world:commit()
                        local paused = world:get(entity, tecs.ecs.Paused)
                        luassert.is_not_nil(paused)
                    end
                )

                it(
                    "should resume entities on focus with resume policy",
                    function()
                        world:createState(
                            "game",
                            {
                                onBlur = "pause",
                                onFocus = "resume",
                            }
                        )
                        world:createState("paused")
                        world:pushState("game")
                        local entity = world:spawn(tecs.Transform(0, 0))
                        world:commit()
                        world:pushState("paused")
                        world:commit()
                        -- Pop paused, game.onFocus should remove Paused
                        world:popState()
                        world:commit()
                        local paused = world:get(entity, tecs.ecs.Paused)
                        luassert.is_nil(paused)
                    end
                )

                it(
                    "should call custom function policy",
                    function()
                        local called = false
                        world:createState("game", {onEnter = function(_w: tecs.World) called = true end})
                        world:pushState("game")
                        luassert.is_true(called)
                    end
                )
            end
        )
    end
)
