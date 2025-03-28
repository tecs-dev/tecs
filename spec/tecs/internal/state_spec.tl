require("busted")
local tecs = require("tecs")
local luassert = require("luassert")
local describe <const> = describe
local it <const> = it
local before_each <const> = before_each

describe("State", function()
    local world: tecs.World

    before_each(function()
        world = tecs.newWorld()
    end)

    describe("Basic state operations", function()
        local record TestState is tecs.States<TestState.Value>
            enum Value
                "idle"
                "running"
                "stopped"
            end
        end

        it("should get nil for unset state", function()
            local value = world:getState(TestState)
            luassert.is_nil(value)
        end)

        it("should set and get state", function()
            world:setState(TestState, "idle")
            local value = world:getState(TestState)
            luassert.is_equal("idle", value)
        end)

        it("should check if in state", function()
            world:setState(TestState, "running")
            luassert.is_true(world:inState(TestState, "running"))
            luassert.is_false(world:inState(TestState, "idle"))
            luassert.is_false(world:inState(TestState, "stopped"))
        end)

        it("should transition between states", function()
            world:setState(TestState, "idle")
            luassert.is_equal("idle", world:getState(TestState))

            world:setState(TestState, "running")
            luassert.is_equal("running", world:getState(TestState))

            world:setState(TestState, "stopped")
            luassert.is_equal("stopped", world:getState(TestState))
        end)
    end)

    describe("State with defaults", function()
        local record DefaultState is tecs.DefaultedStates<DefaultState.Value>
            enum Value
                "alpha"
                "beta"
                "gamma"
            end
            default: DefaultState.Value
        end
        DefaultState.default = "alpha"

        it("should return default value when unset", function()
            local value = world:getState(DefaultState)
            luassert.is_equal("alpha", value)
        end)

        it("should override default when set", function()
            world:setState(DefaultState, "beta")
            local value = world:getState(DefaultState)
            luassert.is_equal("beta", value)
        end)
    end)

    describe("State change callbacks", function()
        local record GameState is tecs.States<GameState.Value>
            enum Value
                "menu"
                "play"
                "paused"
                "gameover"
            end
        end

        it("should call onEnterState callback", function()
            local called = false
            local callbackValue: string

            world:onEnterState(GameState, "play", function()
                called = true
                callbackValue = "play"
            end)

            world:setState(GameState, "play")

            luassert.is_true(called)
            luassert.is_equal("play", callbackValue)
        end)

        it("should call onExitState callback", function()
            local called = false
            local callbackValue: string

            world:setState(GameState, "menu")

            world:onExitState(GameState, "menu", function()
                called = true
                callbackValue = "menu"
            end)

            world:setState(GameState, "play")

            luassert.is_true(called)
            luassert.is_equal("menu", callbackValue)
        end)

        it("should call onTransitionState callback", function()
            local called = false
            local fromValue: string
            local toValue: string

            world:setState(GameState, "play")

            world:onTransitionState(GameState, "play", "paused", function()
                called = true
                fromValue = "play"
                toValue = "paused"
            end)

            world:setState(GameState, "paused")

            luassert.is_true(called)
            luassert.is_equal("play", fromValue)
            luassert.is_equal("paused", toValue)
        end)

        it("should not call onExitState for nil initial state", function()
            local called = false

            world:onExitState(GameState, "menu", function()
                called = true
            end)

            -- Transitioning from nil to "play" should not trigger exit callback for "menu"
            world:setState(GameState, "play")

            luassert.is_false(called)
        end)

        it("should call callbacks in correct order", function()
            local order: {string} = {}

            world:setState(GameState, "play")

            world:onExitState(GameState, "play", function()
                table.insert(order, "exit_play")
            end)

            world:onTransitionState(GameState, "play", "paused", function()
                table.insert(order, "transition_play_to_paused")
            end)

            world:onEnterState(GameState, "paused", function()
                table.insert(order, "enter_paused")
            end)

            world:setState(GameState, "paused")

            luassert.are_same({"exit_play", "transition_play_to_paused", "enter_paused"}, order)
        end)

        it("should support multiple callbacks for same state", function()
            local count = 0

            world:onEnterState(GameState, "play", function()
                count = count + 1
            end)

            world:onEnterState(GameState, "play", function()
                count = count + 10
            end)

            world:onEnterState(GameState, "play", function()
                count = count + 100
            end)

            world:setState(GameState, "play")

            luassert.is_equal(111, count)
        end)

        it("should not call callbacks when setting same state", function()
            local exitCalled = false
            local enterCalled = false

            world:setState(GameState, "menu")

            world:onExitState(GameState, "menu", function()
                exitCalled = true
            end)

            world:onEnterState(GameState, "menu", function()
                enterCalled = true
            end)

            -- Setting the same state should not trigger callbacks
            world:setState(GameState, "menu")

            luassert.is_false(exitCalled)
            luassert.is_false(enterCalled)
        end)

        it("should handle complex state transitions", function()
            local transitions: {string} = {}

            -- Set up callbacks for all transitions
            world:onExitState(GameState, "menu", function()
                table.insert(transitions, "exit_menu")
            end)

            world:onExitState(GameState, "play", function()
                table.insert(transitions, "exit_play")
            end)

            world:onExitState(GameState, "paused", function()
                table.insert(transitions, "exit_paused")
            end)

            world:onEnterState(GameState, "menu", function()
                table.insert(transitions, "enter_menu")
            end)

            world:onEnterState(GameState, "play", function()
                table.insert(transitions, "enter_play")
            end)

            world:onEnterState(GameState, "paused", function()
                table.insert(transitions, "enter_paused")
            end)

            world:onEnterState(GameState, "gameover", function()
                table.insert(transitions, "enter_gameover")
            end)

            world:onTransitionState(GameState, "menu", "play", function()
                table.insert(transitions, "menu_to_play")
            end)

            world:onTransitionState(GameState, "play", "paused", function()
                table.insert(transitions, "play_to_paused")
            end)

            world:onTransitionState(GameState, "paused", "play", function()
                table.insert(transitions, "paused_to_play")
            end)

            world:onTransitionState(GameState, "play", "gameover", function()
                table.insert(transitions, "play_to_gameover")
            end)

            -- Perform state transitions
            world:setState(GameState, "menu")
            luassert.are_same({"enter_menu"}, transitions)

            transitions = {}
            world:setState(GameState, "play")
            luassert.are_same({"exit_menu", "menu_to_play", "enter_play"}, transitions)

            transitions = {}
            world:setState(GameState, "paused")
            luassert.are_same({"exit_play", "play_to_paused", "enter_paused"}, transitions)

            transitions = {}
            world:setState(GameState, "play")
            luassert.are_same({"exit_paused", "paused_to_play", "enter_play"}, transitions)

            transitions = {}
            world:setState(GameState, "gameover")
            luassert.are_same({"exit_play", "play_to_gameover", "enter_gameover"}, transitions)
        end)
    end)

    describe("Multiple state types", function()
        local record StateA is tecs.States<StateA.Value>
            enum Value
                "a1"
                "a2"
            end
        end

        local record StateB is tecs.States<StateB.Value>
            enum Value
                "b1"
                "b2"
            end
        end

        it("should manage multiple state types independently", function()
            world:setState(StateA, "a1")
            world:setState(StateB, "b1")

            luassert.is_equal("a1", world:getState(StateA))
            luassert.is_equal("b1", world:getState(StateB))

            world:setState(StateA, "a2")
            luassert.is_equal("a2", world:getState(StateA))
            luassert.is_equal("b1", world:getState(StateB))

            world:setState(StateB, "b2")
            luassert.is_equal("a2", world:getState(StateA))
            luassert.is_equal("b2", world:getState(StateB))
        end)

        it("should handle callbacks for multiple state types", function()
            local aEntered = false
            local bEntered = false

            world:onEnterState(StateA, "a1", function()
                aEntered = true
            end)

            world:onEnterState(StateB, "b1", function()
                bEntered = true
            end)

            world:setState(StateA, "a1")
            luassert.is_true(aEntered)
            luassert.is_false(bEntered)

            world:setState(StateB, "b1")
            luassert.is_true(aEntered)
            luassert.is_true(bEntered)
        end)
    end)

    describe("System integration", function()
        local record AppState is tecs.States<AppState.Value>
            enum Value
                "loading"
                "running"
                "stopped"
            end
        end

        it("should work with system runIf conditions", function()
            local systemRan = false

            world:addSystem({
                name = "TestSystem",
                phase = tecs.phases.Update,
                run = function()
                    systemRan = true
                end,
                runIf = function(_: number, w: tecs.World): boolean
                    return w:inState(AppState, "running")
                end
            })

            -- System should not run when not in "running" state
            world:update(0.016)
            luassert.is_false(systemRan)

            -- System should run when in "running" state
            world:setState(AppState, "running")
            world:update(0.016)
            luassert.is_true(systemRan)

            -- System should not run when no longer in "running" state
            systemRan = false
            world:setState(AppState, "stopped")
            world:update(0.016)
            luassert.is_false(systemRan)
        end)
    end)
end)