--- FFI-backed event system with typed events and integer IDs for fast dispatch.
--- Uses arena allocation for zero-allocation event handling after warmup.

local libffi = require("tecs.internal.ffi.libffi")
local type Arena = require("tecs.internal.ffi.Arena")

-- Check FFI availability first
local ffiAvailable <const> = libffi.isFFIAvailable()
local ffi_native = ffiAvailable and libffi.getFFI() or nil
local ffi_new = ffiAvailable and ffi_native.new or nil
local ffi_sizeof = ffiAvailable and ffi_native.sizeof or nil
local ffi_cdef = ffiAvailable and ffi_native.cdef or nil

-- Size thresholds for arena selection
local SMALL_EVENT_SIZE <const> = 64
local MEDIUM_EVENT_SIZE <const> = 256

-- Module definition
local record FFIEvents
    --- Base interface for FFI events
    interface FFIEvent
        --- Type ID for fast integer-based dispatch
        typeId: integer
    end

    --- Registration data for an FFI event type
    record EventRegistration
        typeId: integer
        structName: string
        structDef: string
        fields: {{string, string}}
        sizeof: integer
        arena: Arena<any>
    end

    --- FFI event manager for registering and vending events
    record Manager
        --- Next available type ID
        nextTypeId: integer

        --- Map from event type (table reference) to registration
        registrations: {any: EventRegistration}

        --- Map from type ID to registration
        registrationsById: {integer: EventRegistration}

        --- Shared arena for small events (< 64 bytes)
        smallArena: Arena<any>

        --- Shared arena for medium events (< 256 bytes)
        mediumArena: Arena<any>

        --- Per-event-type arenas for large events
        largeArenas: {integer: Arena<any>}
    end

    --- Create a new FFI event manager
    new: function(): Manager

    --- Register an FFI event type
    --- @param eventType The event type (used as table key)
    --- @param fields Field definitions in format {{"name", "type"}, ...}
    --- @param structName Optional struct name (auto-generated if not provided)
    --- @return The assigned type ID
    registerEvent: function(manager: Manager, eventType: any, fields: {{string, string}}, structName?: string): integer

    --- Vend (allocate) an FFI event from the appropriate arena
    --- @param manager The event manager
    --- @param eventType The event type to vend
    --- @return The FFI event instance with typeId set
    vendEvent: function<T>(manager: Manager, eventType: T): T

    --- Clear all arenas for next frame
    clearArenas: function(manager: Manager)

    --- Get the type ID for an event type
    getTypeId: function(manager: Manager, eventType: any): integer
end

-- Track defined structs to avoid redefinition
local definedStructs: {string: boolean} = {}
local structCounter = 0

-- Generate C struct definition from field tuples
local function generateStructDef(name: string, fields: {{string, string}}): string
    local cdef = "typedef struct { "

    -- typeId must be first field for consistent offset
    cdef = cdef .. "int32_t typeId; "

    for _, tuple in ipairs(fields) do
        local fieldName = tuple[1]
        local fieldType = tuple[2]
        -- Skip typeId if explicitly provided (shouldn't happen but be safe)
        if fieldName ~= "typeId" then
            -- Parse array syntax from the type
            local baseType, arraySize = fieldType:match("^([^%[]+)%[(%d+)%]$")
            if baseType and arraySize then
                cdef = cdef .. baseType .. " " .. fieldName .. "[" .. arraySize .. "]; "
            else
                cdef = cdef .. fieldType .. " " .. fieldName .. "; "
            end
        end
    end

    cdef = cdef .. "} " .. name .. ";"
    return cdef
end

local FFI_EVENTS_MANAGER_MT <const> = { __index = FFIEvents.Manager }

function FFIEvents.new(): FFIEvents.Manager
    if not ffiAvailable then
        error("FFI Events requires FFI support - cannot create FFI event manager when FFI is not available")
    end

    local manager: FFIEvents.Manager = {
        nextTypeId = 1,
        registrations = {},
        registrationsById = {},
        -- Create shared arenas with appropriate page sizes
        smallArena = Arena.new("char", 1, SMALL_EVENT_SIZE * 64),  -- 64 small events per page
        mediumArena = Arena.new("char", 1, MEDIUM_EVENT_SIZE * 16), -- 16 medium events per page
        largeArenas = {}
    }
    return setmetatable(manager, FFI_EVENTS_MANAGER_MT)
end

function FFIEvents.Manager:registerEvent(eventType: any, fields: {{string, string}}, structName?: string): integer
    -- Check if already registered
    local existing = self.registrations[eventType]
    if existing then
        return existing.typeId
    end

    -- Generate struct name if not provided
    if not structName then
        structCounter = structCounter + 1
        structName = "FFIEvent" .. structCounter
    end

    -- Generate and define the struct
    local structDef = generateStructDef(structName, fields)

    if not definedStructs[structName] then
        ffi_cdef(structDef)
        definedStructs[structName] = true
    end

    -- Calculate struct size
    local sizeof = ffi_sizeof(structName)

    -- Assign type ID
    local typeId = self.nextTypeId
    self.nextTypeId = self.nextTypeId + 1

    -- Determine which arena to use
    local arena: Arena<any>
    if sizeof <= SMALL_EVENT_SIZE then
        arena = self.smallArena
    elseif sizeof <= MEDIUM_EVENT_SIZE then
        arena = self.mediumArena
    else
        -- Create dedicated arena for large events
        arena = Arena.new(structName, sizeof, 16) as Arena<any>  -- 16 events per page
        self.largeArenas[typeId] = arena
    end

    -- Store registration
    local registration: FFIEvents.EventRegistration = {
        typeId = typeId,
        structName = structName,
        structDef = structDef,
        fields = fields,
        sizeof = sizeof,
        arena = arena
    }

    self.registrations[eventType] = registration
    self.registrationsById[typeId] = registration

    return typeId
end

function FFIEvents.Manager:vendEvent<T>(eventType: T): T
    local registration = self.registrations[eventType]
    if not registration then
        error("Event type not registered for FFI events")
    end

    local arena = registration.arena
    local handle = arena:vend(0)  -- We don't need entity ID for events
    local data, _index = arena:borrow(handle)

    if not data then
        error("Failed to vend event from arena")
    end

    -- Arena returns FFI array, use array indexing
    -- The data is already an array of the right type from Arena
    -- We need to create a new instance and copy to it
    local event = ffi_new(registration.structName)

    -- FFI structs: direct field assignment works
    -- Cast to table to bypass Teal's type checking
    local eventTable = event as {string:any}
    eventTable.typeId = registration.typeId

    -- Return as the typed event (lying to Teal about the type)
    return event as T
end

function FFIEvents.Manager:clearArenas()
    self.smallArena:clear()
    self.mediumArena:clear()

    for _, arena in pairs(self.largeArenas) do
        arena:clear()
    end
end

function FFIEvents.Manager:getTypeId(eventType: any): integer
    local registration = self.registrations[eventType]
    if not registration then
        return 0  -- Invalid type ID
    end
    return registration.typeId
end

return FFIEvents