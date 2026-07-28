--- Global FFI-backed event registry plus leased per-world arena slices.
--- Event schemas and stable type IDs are registered once; each world
--- acquires a slice ID and allocates FFI events from that slice.

local C <const> = require("ffi")
local type Arena = require("tecs.internal.ffi.EpochArena")

local DEFAULT_ARENA_PAGE_SIZE <const> = 64

local record FFIEvents
    interface FFIEvent
        typeId: integer
    end

    record EventRegistration
        typeId: integer
        structName: string
        size: integer
        arenasBySlice: {integer: Arena<any>}
    end

    record Manager
        nextTypeId: integer
        registrations: {any: EventRegistration}
        registrationsById: {integer: EventRegistration}
        nextSliceId: integer
        freeSlices: {integer}
        freeSliceCount: integer
        -- sliceId -> arenas that slice has allocated. clearSlice runs per
        -- world per frame; walking this list touches only what the slice
        -- used instead of every registered event type.
        arenasPerSlice: {integer: {Arena<any>}}
    end

    new: function(): Manager
    global: function(): Manager

    registerEvent: function(manager: Manager, eventType: any, fields: {{string, string}}, structName?: string): integer
    acquireSlice: function(manager: Manager): integer
    releaseSlice: function(manager: Manager, sliceId: integer)
    clearSlice: function(manager: Manager, sliceId: integer)
    vendEvent: function<T>(manager: Manager, sliceId: integer, eventType: T): T
    getTypeId: function(manager: Manager, eventType: any): integer
end

local definedStructs: {string: string} = {}
local structCounter = 0
local GLOBAL_MANAGER: FFIEvents.Manager = nil

local function generateStructDef(name: string, fields: {{string, string}}): string
    local parts: {string} = {"typedef struct { int32_t typeId; "}

    for i = 1, #fields do
        local tuple = fields[i]
        local fieldName = tuple[1]
        local fieldType = tuple[2]
        local baseType, arraySize = fieldType:match("^([^%[]+)%[(%d+)%]$")
        if baseType and arraySize then
            parts[#parts + 1] = baseType .. " " .. fieldName .. "[" .. arraySize .. "]; "
        else
            parts[#parts + 1] = fieldType .. " " .. fieldName .. "; "
        end
    end

    parts[#parts + 1] = "} " .. name .. ";"
    return table.concat(parts)
end

local function ensureSliceArena(
    manager: FFIEvents.Manager, registration: FFIEvents.EventRegistration, sliceId: integer
): Arena<any>
    local arena = registration.arenasBySlice[sliceId]
    if not arena then
        arena = Arena.new(registration.structName, DEFAULT_ARENA_PAGE_SIZE) as Arena<any>
        registration.arenasBySlice[sliceId] = arena
        local list = manager.arenasPerSlice[sliceId]
        if not list then
            list = {}
            manager.arenasPerSlice[sliceId] = list
        end
        list[#list + 1] = arena
    end
    return arena
end

local FFI_EVENTS_MANAGER_MT <const> = {__index = FFIEvents.Manager}

function FFIEvents.new(): FFIEvents.Manager
    local manager: FFIEvents.Manager = {
        nextTypeId = 1,
        registrations = {},
        registrationsById = {},
        nextSliceId = 1,
        freeSlices = {},
        freeSliceCount = 0,
        arenasPerSlice = {},
    }
    return setmetatable(manager, FFI_EVENTS_MANAGER_MT)
end

function FFIEvents.global(): FFIEvents.Manager
    if not GLOBAL_MANAGER then
        GLOBAL_MANAGER = FFIEvents.new()
    end
    return GLOBAL_MANAGER
end

function FFIEvents.Manager:registerEvent(eventType: any, fields: {{string, string}}, structName?: string): integer
    local existing = self.registrations[eventType]
    if existing then
        return existing.typeId
    end

    if not structName then
        structCounter = structCounter + 1
        structName = "FFIEvent" .. structCounter
    end

    local structDef = generateStructDef(structName, fields)
    local existingDef = definedStructs[structName]
    if existingDef then
        if existingDef ~= structDef then
            error("FFI struct name collision: '" .. structName .. "' already defined with a different layout")
        end
    else
        C.cdef(structDef)
        definedStructs[structName] = structDef
    end

    local typeId = self.nextTypeId
    self.nextTypeId = typeId + 1

    local registration: FFIEvents.EventRegistration = {
        typeId = typeId,
        structName = structName,
        size = C.sizeof(structName),
        arenasBySlice = {},
    }

    self.registrations[eventType] = registration
    self.registrationsById[typeId] = registration
    return typeId
end

function FFIEvents.Manager:acquireSlice(): integer
    local count = self.freeSliceCount
    if count > 0 then
        local sliceId = self.freeSlices[count] as integer
        self.freeSlices[count] = nil
        self.freeSliceCount = count - 1
        return sliceId
    end

    local sliceId = self.nextSliceId
    self.nextSliceId = sliceId + 1
    return sliceId
end

function FFIEvents.Manager:clearSlice(sliceId: integer)
    local list = self.arenasPerSlice[sliceId]
    if not list then
        return
    end
    for i = 1, #list do
        list[i]:clear()
    end
end

function FFIEvents.Manager:releaseSlice(sliceId: integer)
    self:clearSlice(sliceId)
    local nextIndex = self.freeSliceCount + 1
    self.freeSlices[nextIndex] = sliceId
    self.freeSliceCount = nextIndex
end

function FFIEvents.Manager:vendEvent<T>(sliceId: integer, eventType: T): T
    local registration = self.registrations[eventType]
    if not registration then
        error("Event type not registered for FFI events")
    end

    local arena = ensureSliceArena(self, registration, sliceId)
    local data, index = arena:allocate()
    local event = (data as {integer: any})[index]
    C.fill(event as C.CData, registration.size, 0)
    (event as {string: any}).typeId = registration.typeId
    return event as T
end

function FFIEvents.Manager:getTypeId(eventType: any): integer
    local registration = self.registrations[eventType]
    if not registration then
        return 0
    end
    return registration.typeId
end

return FFIEvents
