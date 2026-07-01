local table_clear <const> = require("table.clear")
local table_new <const> = require("table.new") as function(integer, integer): {any}
local C <const> = require("ffi")
local schema <const> = require("tecs.internal.ffi.schema")
local FFIEvents <const> = require("tecs.internal.ffi.FFIEvents")
local types <const> = require("tecs.types")
local pool <const> = require("tecs.utils.pool")

local type Event = types.events.Event
local type EventInit = types.events.EventInit

--- The next event ID to assign when the next event type is created.
local NEXT_ID: integer = 1

local NOOP_INIT <const> = function(_instance: any) end

local record events

    --- Configure an event to have an appropriate __call based constructor.
    ---
    --- The event's `.init` callback configures each event instance.
    --- It should not assign a metatable as that's handled by this method automatically.
    ---
    --- @param event The event instance to configure.
    newEvent: function<E is Event>(event: E)

    --- Configure an FFI event to have an appropriate __call based constructor.
    ---
    --- The event's `.init` callback configures each event instance.
    ---
    --- @param event The event type to configure.
    --- @param fields Field definitions in format {{"name", "type"}, ...}
    --- @param structName Optional struct name (auto-generated if not provided)
    newFFIEvent: function<E is Event>(
        event: E,
        fields: {{string, string}},
        structName?: string
    )

    --- Centralized message bus for address-based event routing.
    --- Addresses are integers: 0 for world-level events, entity IDs for entity events.
    record MessageBus is types.events.MessageBus
        -- address -> eventId -> {id_or_false, cb, id_or_false, cb, ...}
        -- callbacks[0] stores the logical size of the interleaved array.
        _observers: {integer: {integer: {any}}}
        -- Total live observer count across all addresses/events.
        -- Used as a zero-observer fast-path in `hasObservers`: when
        -- no observer has ever been registered (or all have been
        -- removed), we skip the per-address hashmap lookup entirely.
        -- Single field read + int comparison vs hashmap walk -- hot
        -- per-entity despawn path reads this on every iteration to
        -- decide whether OnDespawn fan-out is needed.
        _totalObservers: integer
        -- Reentrant emit depth counter.
        _emitDepth: integer
        -- lazy, staggered: {address, eventId, idOrCb, address, eventId, idOrCb, ...}
        _deferredUnsubscribes: {any}
        -- Pool of reusable interleaved callbacks arrays. Clear-on-release so
        -- released arrays promptly drop observer closures (which may root
        -- captured state). Per-bus so event churn doesn't pollute other
        -- subsystems' sizing.
        _callbacksPool: pool.TablePool
        -- Pool of reusable eventId -> callbacks maps. Clear-on-acquire: the
        -- maps hold plain integer keys and array refs, clearing a large
        -- hash part on every release would waste work on pool entries that
        -- may never be reused.
        _byAddressPool: pool.TablePool

        --- Create a new MessageBus.
        new: function(): MessageBus

        --- Observe an event type at a specific address.
        --- Address 0 is for world-level events, entity IDs for entity events.
        observe: function<E is Event>(
            self: MessageBus,
            address: integer,
            eventType: E,
            observer: function(E), id?: string
        )

        --- Observe an event type at a specific address, at most once.
        observeOnce: function<E is Event>(
            self: MessageBus,
            address: integer,
            eventType: E,
            observer: function(E)
        )

        --- Stop observing an event type at a specific address.
        stopObserving: function<E is Event>(
            self: MessageBus,
            address: integer,
            eventType: E,
            observerOrId: function(E)|string
        )

        --- Emit an event to all observers at the specified address.
        emit: function<E is Event>(self: MessageBus, address: integer, event: E)

        --- Check if any observers exist for an event type at an address.
        hasObservers: function<E is Event>(self: MessageBus, address: integer, eventType: E): boolean

        --- Clear all observers for an address (used on entity despawn).
        clearAddress: function(self: MessageBus, address: integer)

        --- Clear per-entity observers (all addresses except global 0),
        --- preserving global subscriptions like queries' ArchetypeCreated observer.
        clearEntityObservers: function(self: MessageBus)

        --- Reset the entire message bus.
        reset: function(self: MessageBus)
    end
end

function events.newEvent<E is Event>(event: E)
    if event.eventId then
        error("Event has already been configured: " .. tostring(event) .. " : " .. event.eventId)
    end

    local id <const> = NEXT_ID
    NEXT_ID = NEXT_ID + 1
    event.eventId = id
    local MT <const> = { __index = event }
    local eventAny = event as {string: any}
    local init = eventAny.init as EventInit<E> or NOOP_INIT as EventInit<E>
    eventAny.init = init

    eventAny.__tecs_mt = MT
    setmetatable(event, {
        __call = function(_self: E, ...: any): E
            local instance = setmetatable({eventId = id}, MT) as E
            init(instance, ...)
            return instance
        end
    })
end

function events.newFFIEvent<E is Event>(
    event: E,
    fields: {{string, string}},
    structName?: string
)
    if event.eventId then
        error("Event has already been configured: " .. tostring(event) .. " : " .. event.eventId)
    end

    schema.validateFields(fields, {eventId = true, typeId = true})

    local resolvedStructName = structName

    -- Inject eventId as first field
    local nFields <const> = #fields
    local ffiFields: {{string, string}} = table_new(nFields + 1, 0) as {{string, string}}
    ffiFields[1] = {"eventId", "int32_t"}
    for i = 1, nFields do
        ffiFields[i + 1] = fields[i]
    end

    -- Precompute field names for the constructor
    local fieldNames: {string} = table_new(nFields, 0) as {string}
    for i = 1, nFields do
        fieldNames[i] = fields[i][1]
    end

    -- Register the schema globally so the struct is defined once and all
    -- worlds can allocate this event type from their leased FFI slice.
    local ffiManager = FFIEvents.global()
    local ffiTypeId = ffiManager:registerEvent(event, ffiFields, resolvedStructName)
    resolvedStructName = ffiManager.registrations[event].structName

    local id <const> = NEXT_ID
    NEXT_ID = NEXT_ID + 1
    event.eventId = id
    local eventAny = event as {string: any}
    eventAny.__tecs_ffi = true
    eventAny.__tecs_ffi_fields = ffiFields
    eventAny.__tecs_ffi_structName = resolvedStructName
    eventAny.__tecs_ffi_typeId = ffiTypeId

    local init = eventAny.init as EventInit<E>
    if not init then
        init = function(instance: E, ...: any)
            local anyInstance = instance as {string:any}
            local args = {...}
            for i = 1, #args do
                anyInstance[fieldNames[i]] = args[i]
            end
        end
        eventAny.init = init
    end

    setmetatable(event, {
        __call = function(_self: E, ...: any): E
            local instance = C.new(resolvedStructName as string) as {string:any}
            instance.eventId = id
            instance.typeId = ffiTypeId
            init(instance as E, ...)
            return instance as E
        end
    })
end

-------------------------------------------------------------------------------
-- MessageBus implementation
-------------------------------------------------------------------------------

local MessageBus <const> = events.MessageBus

local MESSAGE_BUS_MT <const>: metatable<events.MessageBus> = {
    __index = MessageBus
}

function MessageBus.new(): events.MessageBus
    local bus: events.MessageBus = {
        _observers = {},
        _totalObservers = 0,
        _emitDepth = 0,
        _callbacksPool = pool.newTablePool({ clearOn = "release" }),
        _byAddressPool = pool.newTablePool({ clearOn = "acquire" }),
    }
    return setmetatable(bus, MESSAGE_BUS_MT)
end

function MessageBus:observe<E is Event>(address: integer, eventType: E, observer: function(E), id?: string)
    local eventId = assert(eventType.eventId, "Event type must be registered with newEvent or newFFIEvent")

    local byAddress = self._observers[address]
    if not byAddress then
        byAddress = self._byAddressPool:acquire() as {integer: {any}}
        self._observers[address] = byAddress
    end

    local callbacks = byAddress[eventId]
    if not callbacks then
        callbacks = self._callbacksPool:acquire() as {any}
        callbacks[0] = 0
        byAddress[eventId] = callbacks
    end

    local n = callbacks[0] as integer
    callbacks[n + 1] = id or false
    callbacks[n + 2] = observer
    callbacks[0] = n + 2
    self._totalObservers = self._totalObservers + 1
end

function MessageBus:observeOnce<E is Event>(address: integer, eventType: E, observer: function(E))
    local wrappedFunction: function(E)
    wrappedFunction = function(e: E)
        self:stopObserving(address, eventType, wrappedFunction)
        observer(e)
    end
    self:observe(address, eventType, wrappedFunction)
end

--- Remove a pair at index (interleaved format: id at idx, callback at idx+1).
--- Caller must update callbacks[0] after removal.
local function removeAtIndex(callbacks: {any}, idx: integer, size: integer)
    -- Swap-pop: move last pair to this position
    if idx < size - 1 then
        callbacks[idx] = callbacks[size - 1]
        callbacks[idx + 1] = callbacks[size]
    end
    callbacks[size - 1] = nil
    callbacks[size] = nil
end

function MessageBus:stopObserving<E is Event>(address: integer, eventType: E, observerOrId: function(E)|string)
    local eventId = assert(eventType.eventId, "Event type must be registered with newEvent or newFFIEvent")

    -- If we're emitting, defer the removal
    if self._emitDepth > 0 then
        local deferred = self._deferredUnsubscribes
        if not deferred then
            deferred = {}
            self._deferredUnsubscribes = deferred
        end
        local n = deferred[0] as integer or 0
        deferred[n + 1] = address
        deferred[n + 2] = eventId
        deferred[n + 3] = observerOrId
        deferred[0] = n + 3
        return
    end

    local byAddress = self._observers[address]
    if not byAddress then
        return
    end

    local callbacks = byAddress[eventId]
    if not callbacks then
        return
    end

    local size = callbacks[0] as integer
    if size == 0 then
        return
    end
    local originalSize = size

    -- Interleaved format: {id, cb, id, cb, ...}
    if observerOrId is string then
        -- Search by ID (at odd indices)
        for i = 1, size - 1, 2 do
            if callbacks[i] == observerOrId then
                removeAtIndex(callbacks, i, size)
                size = size - 2
                break
            end
        end
    else
        -- Search by function (at even indices), remove all matches
        local i = size - 1
        while i >= 1 do
            if callbacks[i + 1] == observerOrId then
                removeAtIndex(callbacks, i, size)
                size = size - 2
            end
            i = i - 2
        end
    end

    callbacks[0] = size
    -- Size is observers × 2 (interleaved id+cb).
    self._totalObservers = self._totalObservers - math.floor((originalSize - size) / 2)

    if size == 0 then
        self._callbacksPool:release(callbacks)
        byAddress[eventId] = nil
        -- Clean up empty address entry
        if next(byAddress) == nil then
            self._byAddressPool:release(byAddress)
            self._observers[address] = nil
        end
    end
end

local function processDeferredUnsubscribes(self: events.MessageBus)
    local deferred = self._deferredUnsubscribes
    if not deferred then
        return
    end

    local dSize = deferred[0] as integer or 0
    if dSize == 0 then
        return
    end

    local observers = self._observers

    -- Staggered format: {address, eventId, idOrCb, address, eventId, idOrCb, ...}
    for i = 1, dSize - 2, 3 do
        local address = deferred[i] as integer
        local eventId = deferred[i + 1] as integer
        local observerOrId = deferred[i + 2] as function(Event) | string

        local byAddress = observers[address]
        if byAddress then
            local callbacks = byAddress[eventId]
            if callbacks then
                local size = callbacks[0] as integer
                if size > 0 then
                    local originalSize = size
                    if observerOrId is string then
                        for j = 1, size - 1, 2 do
                            if callbacks[j] == observerOrId then
                                removeAtIndex(callbacks, j, size)
                                size = size - 2
                                break
                            end
                        end
                    else
                        local j = size - 1
                        while j >= 1 do
                            if callbacks[j + 1] == observerOrId then
                                removeAtIndex(callbacks, j, size)
                                size = size - 2
                            end
                            j = j - 2
                        end
                    end
                    callbacks[0] = size
                    self._totalObservers = self._totalObservers - math.floor((originalSize - size) / 2)
                    if size == 0 then
                        self._callbacksPool:release(callbacks)
                        byAddress[eventId] = nil
                        if next(byAddress) == nil then
                            self._byAddressPool:release(byAddress)
                            observers[address] = nil
                        end
                    end
                end
            end
        end
    end

    deferred[0] = 0
    table_clear(deferred)
end

function MessageBus:emit<E is Event>(address: integer, event: E)
    local byAddress = self._observers[address]
    if not byAddress then
        return
    end

    local callbacks = byAddress[event.eventId]
    if not callbacks then
        return
    end

    local size = callbacks[0] as integer
    if size == 0 then
        return
    end

    self._emitDepth = self._emitDepth + 1

    -- Callbacks are at even indices (2, 4, 6, ...)
    for i = 2, size, 2 do
        (callbacks[i] as function(Event))(event)
    end

    self._emitDepth = self._emitDepth - 1

    if self._emitDepth == 0 then
        processDeferredUnsubscribes(self)
    end
end

function MessageBus:hasObservers<E is Event>(address: integer, eventType: E): boolean
    -- Fast path: when the bus has no observers at all, skip the
    -- two hashmap lookups. Read one integer field + branch.
    if self._totalObservers == 0 then return false end
    local byAddress = self._observers[address]
    if not byAddress then
        return false
    end
    local callbacks = byAddress[eventType.eventId]
    return callbacks ~= nil and callbacks[0] as integer > 0
end

function MessageBus:clearAddress(address: integer)
    local byAddress = self._observers[address]
    if byAddress then
        local removed = 0
        for _, callbacks in pairs(byAddress) do
            removed = removed + math.floor((callbacks[0] as integer) / 2)
            self._callbacksPool:release(callbacks as {any})
        end
        self._byAddressPool:release(byAddress)
        self._observers[address] = nil
        self._totalObservers = self._totalObservers - removed
    end
end

-- Clear per-entity observers (every address except the global address 0),
-- preserving global subscriptions. world:clearEntities uses this so the query
-- infrastructure (each query's ArchetypeCreated subscription at address 0) and
-- global user observers survive the clear; a full reset() would unsubscribe
-- them, leaving queries unable to match archetypes created after the clear.
function MessageBus:clearEntityObservers()
    if self._totalObservers == 0 then return end
    local addresses: {integer} = {}
    local n = 0
    for address in pairs(self._observers) do
        if address ~= 0 then
            n = n + 1
            addresses[n] = address
        end
    end
    for i = 1, n do
        self:clearAddress(addresses[i])
    end
end

function MessageBus:reset()
    if self._totalObservers > 0 then
        for _, byAddress in pairs(self._observers) do
            for _, callbacks in pairs(byAddress) do
                self._callbacksPool:release(callbacks as {any})
            end
            self._byAddressPool:release(byAddress)
        end
        table_clear(self._observers)
        self._totalObservers = 0
    end

    self._emitDepth = 0
    if self._deferredUnsubscribes then
        self._deferredUnsubscribes[0] = 0
        table_clear(self._deferredUnsubscribes)
    end
end

return events
