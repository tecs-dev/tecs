--- Simple state machine handling for Tecs.
local record state
    --- Create a new state container.
    ---
    --- @return a new state container.
    newStateContainer: function(): StateContainer

    --- The possible states that can be set for a specific kind of state.
    ---
    --- @type V The type of the state. Typically this is an enum.
    interface States<V>
        -- This is typically where you define an enum.
    end

    --- States with a default value.
    ---
    --- @type V The type of the state. Typically this is an enum.
    interface DefaultedStates<V> is States<V>
        --- Default value for the state. Must be a value from the enum V.
        default: V
    end

    --- Contains zero or more states, tracks their current value, and emits events when the state changes.
    interface StateContainer
        --- Get the current value of a state.
        ---
        --- @param state The state container to get the value of.
        --- @return the current value of the state.
        getState: function<V, S is States<V>>(self, state: S): V

        --- Check if a States container is in a specific state.
        ---
        --- @param state The state to check.
        --- @param value The value to check.
        --- @return true if the state is in the given value.
        inState: function<V, S is States<V>>(self, state: S, value: V): boolean

        --- Transitions a State container from its current value to the given state.
        ---
        --- The transition occurs immediately.
        ---
        --- @param state The state to transition.
        --- @param value The value to transition the state to.
        setState: function<V, S is States<V>>(self, state: S, value: V)

        --- Observe when a specific state is exited.
        ---
        --- @param state The state to observe.
        --- @param value The value to observe when exiting the state.
        --- @param callback The callback to call when the state is exited.
        onExitState: function<V, S is States<V>>(self, state: S, value: V, callback: function())

        --- Observe when a specific state is transitioned to another specific state.
        ---
        --- @param state The state to observe.
        --- @param from The value to observe when exiting the state.
        --- @param to The value to observe when entering the state.
        --- @param callback The callback to call when the state is transitioned from `from` to `to`.
        onTransitionState: function<V, S is States<V>>(self, state: S, from: V, to: V, callback: function())

        --- Observe when a specific state is entered.
        ---
        --- @param state The state to observe.
        --- @param value The value to observe when entering the state.
        --- @param callback The callback to call when the state is entered.
        onEnterState: function<V, S is States<V>>(self, state: S, value: V, callback: function())
    end
end

-------------------------------------------------------------------------------
-- State container implementation
-------------------------------------------------------------------------------

local record StateContainer is state.StateContainer
    _states: {any: any}
    _callbacks: {any: {function}}
end

local STATES_CONTAINER_MT <const>: metatable<StateContainer> = {
    __index = StateContainer
}

function state.newStateContainer(): state.StateContainer
    local container: StateContainer = {
        _states = {},
        _callbacks = {},
    }
    return setmetatable(container, STATES_CONTAINER_MT) as state.StateContainer
end

function StateContainer:getState<V, S is state.States<V>>(s: S): V
    local value = self._states[s]
    if value == nil then
        return (s as state.DefaultedStates<V>).default -- attempt to get default
    end
    return value as V
end

function StateContainer:inState<V, S is state.States<V>>(s: S, value: V): boolean
    return self._states[s] == value
end

local function invokeCallbacks(self: StateContainer, key: string)
    local callbacks = self._callbacks[key]
    if callbacks then
        for _, callback in ipairs(callbacks) do
            callback()
        end
    end
end

local function getOnEnterKey<V, S is state.States<V>>(s: S, value: V): string
    return tostring(s) .. "enter" .. tostring(value)
end

local function getOnExitKey<V, S is state.States<V>>(s: S, value: V): string
    return tostring(s) .. "exit" .. tostring(value)
end

local function getOnTransitionKey<V, S is state.States<V>>(s: S, from: V, to: V): string
    return tostring(s) .. "transition" .. tostring(from) .. "to" .. tostring(to)
end

function StateContainer:setState<V, S is state.States<V>>(s: S, value: V)
    local currentState = self._states[s] as V

    if value == currentState then
        return -- do nothing
    end

    if currentState then
        invokeCallbacks(self, getOnExitKey(s, currentState))
    end

    invokeCallbacks(self, getOnTransitionKey(s, currentState, value))
    self._states[s] = value
    invokeCallbacks(self, getOnEnterKey(s, value))
end

local function addCallback(self: StateContainer, key: string, callback: function())
    local callbacks = self._callbacks[key]
    if not callbacks then
        callbacks = {}
        self._callbacks[key] = callbacks
    end
    table.insert(callbacks, callback)
end

function StateContainer:onExitState<V, S is state.States<V>>(s: S, value: V, callback: function())
    addCallback(self, getOnExitKey(s, value), callback)
end

function StateContainer:onTransitionState<V, S is state.States<V>>(s: S, from: V, to: V, callback: function())
    addCallback(self, getOnTransitionKey(s, from, to), callback)
end

function StateContainer:onEnterState<V, S is state.States<V>>(s: S, value: V, callback: function())
    addCallback(self, getOnEnterKey(s, value), callback)
end

return state