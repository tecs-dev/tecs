local compat <const> = require("tecs.internal.utils.compat")
local table_clear <const> = compat.clear
local schema <const> = require("tecs.internal.ffi.schema")
local FFIEvents <const> = require("tecs.internal.ffi.FFIEvents")

local record events
    --- Create a new event emitter.
    --- @return a new event emitter.
    newEmitter: function(): Emitter

    --- Configure an event to have an appropriate __call based constructor.
    ---
    --- The initializer is used to configure the state of event instances. The constructor should
    --- not assign a metatable as that's handled by this method automatically.
    ---
    --- @param event The event instance to configure.
    --- @param constructor A function that creates an instance of the event.
    newEvent: function<E is Event>(event: E, constructor: EventConstructor<E>)

    --- Configure an FFI event to have an appropriate __call based constructor.
    ---
    --- The initializer is used to configure the state of event instances.
    ---
    --- @param event The event type to configure.
    --- @param fields Field definitions in format {{"name", "type"}, ...}
    --- @param structName Optional struct name (auto-generated if not provided)
    newFFIEvent: function<E is Event>(event: E, fields: {{string, string}}, structName?: string)

    --- An event that can be emitted.
    interface Event
        --- The unique ID of the event.
        eventId: integer
    end

    --- An event listener that synchronously receives an event of type `E`.
    type EventListener = function<E is Event>(event: E)

    type EventConstructor = function<E is Event>(...: any): E

    --- An event emitter that can observe, stop observing, and emit events.
    interface Emitter
        --- Observes an event by type.
        ---
        --- The callback is called immediately when an event of the given type is emitted.
        ---
        --- @param eventType The type of event to observe.
        --- @param callback The callback to call when the event is emitted
        --- @param id The optional ID used to remove the observer.
        observe: function<E is Event>(self, eventType: E, callback: function(event: E), id?: string)

        --- Observes an event by type, at most once.
        ---
        --- The callback is called immediately when an event of the given type is emitted.
        --- After the callback is called, the observer is removed.
        ---
        --- @param eventType The type of event to observe.
        --- @param callback The callback to call when the event is emitted
        observeOnce: function<E is Event>(self, eventType: E, callback: function(event: E))

        --- Stops observing an event by type.
        ---
        --- @param eventType The type of event to stop observing.
        --- @param callbackOrId The callback to stop observing or the ID of the observer.
        stopObserving: function<E is Event>(self, eventType: E, callbackOrId: function(event: E) | string)

        --- Checks if the world has any observers for the given event type.
        ---
        --- @param eventType The type of event to check for observers.
        --- @return true if the world has observers for the event type.
        hasObservers: function<E is Event>(self, eventType: E): boolean

        --- Emits an event to all observers of the event type.
        ---
        --- @param eventType The type of event to emit.
        emit: function<E is Event>(self, event: E)

        --- Remove all observers.
        reset: function(self)
    end
end

local type Event = events.Event

--- The next event ID to assign when the next event type is created.
local NEXT_ID: integer = 1

--- Global FFI event manager for arena allocation (lazy-initialized)
local __globalFFIManager: FFIEvents.Manager = nil

--- Get or create the global FFI manager
local function _getFFIManager(): FFIEvents.Manager
    if not __globalFFIManager then
        __globalFFIManager = FFIEvents.new()
    end
    return __globalFFIManager
end

function events.newEvent<E is Event>(event: E, constructor: events.EventConstructor<E>)
    if event.eventId then
        error("Event has already been configured: " .. tostring(event) .. " : " .. event.eventId)
    end

    local id <const> = NEXT_ID
    NEXT_ID = NEXT_ID + 1
    event.eventId = id
    local MT <const> = { __index = event }

    setmetatable(event, {
        __call = function(_self: E, ...: any): E
            local instance = assert(constructor(...), "Event constructor must return an instance of the event")
            instance.eventId = id
            return setmetatable(instance, MT) as E
        end
    })
end

function events.newFFIEvent<E is Event>(event: E, fields: {{string, string}}, structName?: string)
    if event.eventId then
        error("Event has already been configured: " .. tostring(event) .. " : " .. event.eventId)
    end

    local id <const> = NEXT_ID
    NEXT_ID = NEXT_ID + 1
    event.eventId = id

    schema.validateFields(fields, false)

    if schema.isFFIAvailable() then
        -- Inject eventId as first field (int32_t for consistency)
        local ffiFields: {{string, string}} = {{"eventId", "int32_t"}}
        for i = 1, #fields do
            table.insert(ffiFields, fields[i])
        end

        -- Arena allocate and create FFI constructor that vends from arena
        _getFFIManager():registerEvent(event, ffiFields, structName)
        setmetatable(event, {
            __call = function(_self: E, ...: any): E
                local instance = _getFFIManager():vendEvent(event)
                instance.eventId = id
                local nargs = select('#', ...)
                for i = 1, nargs do
                    local fieldName = ffiFields[i + 1][1]  -- +1 to skip eventId at position 1
                    (instance as {string:any})[fieldName] = select(i, ...)
                end
                return instance as E
            end
        })
    else
        -- Fallback that uses table-based events with schema defaults
        local fallbackConstructor = schema.createFallbackConstructor(fields)
        setmetatable(event, {
            __call = function(_self: E, ...: any): E
                local instance: E = fallbackConstructor(...) as E
                instance.eventId = id
                return instance
            end
        })
    end
end

-------------------------------------------------------------------------------
-- Event Emitter implementation
-------------------------------------------------------------------------------

local record ObserverContainer
    callbacks: {function(Event)}
    --- Parallel array of IDs (false = no ID)
    ids: {string | boolean}
    size: integer
    --- ID -> index lookup
    indexById: {string: integer}
    --- callback -> set of indices (using any for weak keys)
    indexByFn: {any: {integer: boolean}}
end

local record EventEmitter is events.Emitter
    _eventObservers: {integer: ObserverContainer}
    _isEmitting: boolean
    --- Queue of deferred operations during emit
    _changeQueue: {any}
    _changeQueueSize: integer
end

-- Operation codes for change queue
local OP_OBSERVE <const> = 1
local OP_STOP_OBSERVING <const> = 2

-- Weak key metatable for indexByFn
local WEAK_KEYS_MT <const> = { __mode = "k" }

local EVENT_EMITTER_MT <const>: metatable<EventEmitter> = {
    __index = EventEmitter
}

--- Get or create an observer container for a specific event ID, and cache it
local function getOrCreateContainer(self: EventEmitter, eventId: integer): ObserverContainer
    local container = self._eventObservers[eventId]
    if not container then
        container = {
            callbacks = {},
            ids = {},
            size = 0,
            indexById = {},
            indexByFn = setmetatable({}, WEAK_KEYS_MT)
        }
        self._eventObservers[eventId] = container
    end
    return container
end

function EventEmitter:observe<E is Event>(eventType: E, observer: function(E), id?: string)
    local eventId = assert(eventType.eventId, "Event type must be registered with newEvent or newFFIEvent")

    -- If we're emitting, queue the operation
    -- We do this dance to avoid needing to copy events before emitting to ensure predictability.
    if self._isEmitting then
        local queue = self._changeQueue
        local qSize = self._changeQueueSize
        queue[qSize + 1] = OP_OBSERVE
        queue[qSize + 2] = eventId
        queue[qSize + 3] = observer
        queue[qSize + 4] = id as any or false
        self._changeQueueSize = qSize + 4
        return
    end

    local container = getOrCreateContainer(self, eventId)
    local newIndex = container.size + 1
    container.callbacks[newIndex] = observer
    container.ids[newIndex] = id or false
    container.size = newIndex

    if id then
        container.indexById[id] = newIndex
    end

    local fnIndices = container.indexByFn[observer as any]
    if fnIndices then
        fnIndices[newIndex] = true
    else
        container.indexByFn[observer as any] = {[newIndex] = true}
    end
end

function EventEmitter:observeOnce<E is Event>(eventType: E, observer: function(E))
    local wrappedFunction: function(E)
    wrappedFunction = function(e: E)
        self:stopObserving(eventType, wrappedFunction)
        observer(e)
    end
    self:observe(eventType, wrappedFunction)
end

local function removeAtIndex(container: ObserverContainer, idx: integer)
    local size = container.size
    if idx == nil or idx < 1 or idx > size then
        return
    end

    -- Clean up lookup maps for removed element
    local ids = container.ids
    local removedId = ids[idx]
    if removedId is string then
        container.indexById[removedId as string] = nil
    end

    local callbacks = container.callbacks
    local removedFn = callbacks[idx]
    local fnIndices = container.indexByFn[removedFn as any]
    if fnIndices then
        fnIndices[idx] = nil
        -- Clean up empty set to prevent map bloat
        if next(fnIndices) == nil then
            container.indexByFn[removedFn as any] = nil
        end
    end

    -- Swap-pop: move last element to this position
    if idx < size then
        local lastFn = callbacks[size]
        local lastId = ids[size]
        callbacks[idx] = lastFn
        ids[idx] = lastId

        -- Update lookup maps for moved element
        if lastId is string then
            container.indexById[lastId as string] = idx
        end

        local lastFnIndices = container.indexByFn[lastFn as any]
        if lastFnIndices then
            lastFnIndices[size] = nil
            lastFnIndices[idx] = true
        end
    end

    -- Clear last position
    callbacks[size] = nil
    ids[size] = nil
    container.size = size - 1
end

function EventEmitter:stopObserving<E is Event>(eventType: E, observerOrId: function(E) | string)
    local eventId = assert(eventType.eventId, "Event type must be registered with newEvent or newFFIEvent")

    -- If we're emitting, queue the operation
    if self._isEmitting then
        local queue = self._changeQueue
        local qSize = self._changeQueueSize
        queue[qSize + 1] = OP_STOP_OBSERVING
        queue[qSize + 2] = eventId
        queue[qSize + 3] = observerOrId
        self._changeQueueSize = qSize + 3
        return
    end

    local container = self._eventObservers[eventId]
    if not container or container.size == 0 then
        return
    end

    if observerOrId is string then
        removeAtIndex(container, container.indexById[observerOrId])
    else
        -- Remove all instances of this callback
        local fnSet = container.indexByFn[observerOrId as any]
        if fnSet then
            local idx = next(fnSet)
            while idx do
                removeAtIndex(container, idx)
                idx = next(fnSet)
            end
        end
    end

    if container.size == 0 then
        self._eventObservers[eventId] = nil
    end
end

function EventEmitter:hasObservers<E is Event>(eventType: E): boolean
    assert(eventType.eventId, "Event type must be registered with newEvent or newFFIEvent")
    local container = self._eventObservers[eventType.eventId]
    return container and container.size > 0 or false
end

local function processChangeQueue(self: EventEmitter)
    local qSize = self._changeQueueSize
    if qSize == 0 then
        return
    end

    local i, queue = 1, self._changeQueue
    while i <= qSize do
        local op = queue[i]
        if op == OP_OBSERVE then
            local eventId = queue[i + 1] as integer
            local observer = queue[i + 2] as function(Event)
            local id = queue[i + 3]
            -- Direct container manipulation since we have the integer ID
            local container = getOrCreateContainer(self, eventId)
            local newIndex = container.size + 1
            container.callbacks[newIndex] = observer
            container.ids[newIndex] = id and id ~= false and (id as string) or false
            container.size = newIndex
            if id and id ~= false then
                container.indexById[id as string] = newIndex
            end
            local fnIndices = container.indexByFn[observer as any]
            if fnIndices then
                fnIndices[newIndex] = true
            else
                container.indexByFn[observer as any] = {[newIndex] = true}
            end
            i = i + 4
        elseif op == OP_STOP_OBSERVING then
            local eventId = queue[i + 1] as integer
            local observerOrId = queue[i + 2] as function(Event) | string
            local container = self._eventObservers[eventId]
            if container and container.size > 0 then
                if observerOrId is string then
                    local idx = container.indexById[observerOrId as string]
                    if idx then
                        removeAtIndex(container, idx)
                    end
                else
                    local fnSet = container.indexByFn[observerOrId as any]
                    if fnSet then
                        while true do
                            local anyIdx = next(fnSet)
                            if not anyIdx then break end
                            removeAtIndex(container, anyIdx)
                        end
                    end
                end
                if container.size == 0 then
                    self._eventObservers[eventId] = nil
                end
            end
            i = i + 3
        else
            error("Invalid operation in change queue: " .. tostring(op))
        end
    end

    table_clear(queue)
    self._changeQueueSize = 0
end

function EventEmitter:emit<E is Event>(event: E)
    local container = self._eventObservers[event.eventId]
    if not container then
        return
    end

    local size = container.size
    if size == 0 then
        return
    end

    -- Mark that we're emitting
    local wasEmitting = self._isEmitting
    self._isEmitting = true

    local callbacks = container.callbacks
    for i = 1, size do
        callbacks[i](event)
    end

    -- Restore emit state and process queued changes if we're the top-level emit
    self._isEmitting = wasEmitting
    if not wasEmitting then
        processChangeQueue(self)
    end
end

function EventEmitter:reset()
    for _, container in pairs(self._eventObservers) do
        table_clear(container.callbacks as {any})
        table_clear(container.ids as {any})
        table_clear(container.indexById as {any})
        table_clear(container.indexByFn as {any})
        container.size = 0
    end

    self._isEmitting = false
    self._changeQueueSize = 0
    table_clear(self._changeQueue)
    table_clear(self._eventObservers as {any})
end

function events.newEmitter(): events.Emitter
    local emitter: EventEmitter = {
        _eventObservers = {},
        _isEmitting = false,
        _changeQueue = {},
        _changeQueueSize = 0
    }
    return setmetatable(emitter, EVENT_EMITTER_MT) as events.Emitter
end

return events