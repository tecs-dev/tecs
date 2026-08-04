local types <const> = require("tecs.types")

local table_clear <const> = require("table.clear")
local table_new <const> = require("table.new")

local type Component = types.components.Component
local type ComponentAllocator = types.components.ComponentAllocator

local record storage
    --- Storage kind discriminator. Internal: components carry this on
    --- `ComponentInternal.storageType` to pick zero-branch hot paths.
    enum StorageType
        "tag"
        "ffi"
        "table"
        "scalar"
    end

    --- Storage interface -- pluggable per-component column backend. Internal
    --- only; users pick a component kind via the `newX` factories and never
    --- implement Storage themselves. Lives here rather than in
    --- `internal/types.tl` because the FFI and Archetype modules need to
    --- reference it, and internal/types.tl can't import them (cycle).
    interface Storage
        storageType: StorageType
        createColumn: function(self, size: integer): {Component}
        clear: function(self, column: {Component})
        ensureCapacity: function(self, column: {Component}, needed: integer): {Component}
        adjustCapacity: function(self, column: {Component}, usedCount: integer): {Component} | nil
        createComponent: function(self, container: Component): ComponentAllocator<Component>
    end

    --- Basic table storage with automatic growth.
    newTableStorage: function(): Storage

    --- Scalar storage: column values are raw Lua scalars.
    newScalarStorage: function(kind: string, defaultValue: any): Storage

    --- Tag storage. Presence is archetype-defined (no per-row state);
    --- reads return the container for any row, writes are no-ops. Its
    --- snapshot codec writes an empty payload and reads any payload back
    --- as the container, so a tag costs its presence and nothing else.
    --- @param container The component to return on any read.
    newBitsetStorage: function(container: Component): Storage

    --- High-performance FFI storage with automatic fallback to table storage.
    --- @param def Configuration including fields, recycling options
    newFFIStorage: function(def: {string: any}): Storage

    --- Install container metadata on FFI storage so cdata instances expose
    --- the same relationship and hook fields as table-backed instances.
    --- No-op for non-FFI storage.
    syncMetadataToFFI: function(s: Storage, container: Component)
end

local type Storage = storage.Storage

-- Initialize component with optional table argument copying
local function initializeComponentFromArgs<C is Component>(component: C, ...: any): C
    local nargs = select("#", ...)
    if nargs == 1 and type((...)) == "table" then
        -- Copy from table argument
        local value = (...) as {string: any}
        for k, v in pairs(value) do
            (component as {string: any})[k] = v
        end
    end
    return component
end

-- Generic table-based component constructor
-- This is used when a table-based component is created but doesn't provide a custom constructor.
local function createTableComponentConstructor(): function(...: any): Component
    return function(...: any): Component return initializeComponentFromArgs({}, ...) end
end

-- Table storage implementation
local TABLE_STORAGE <const>: Storage = {
    storageType = "table",
    createColumn = function(_self: Storage, size: integer): {Component} return table_new(size, 0) as {Component} end,
    clear = function(_self: Storage, column: {Component}) table_clear(column) end,
    ensureCapacity = function(_self: Storage, column: {Component}, _needed: integer): {Component}
        -- Lua tables grow automatically, so just return the same column
        return column
    end,
    createComponent = createTableComponentConstructor as function(
        _self: Storage, _container: Component
    ): ComponentAllocator<Component>;
}

function storage.newTableStorage(): Storage
    return TABLE_STORAGE
end

function storage.newScalarStorage(kind: string, defaultValue: any): Storage
    if kind ~= "number" and kind ~= "boolean" and kind ~= "string" then
        error("newScalarStorage: kind must be one of 'number', 'boolean', or 'string'")
    end
    if type(defaultValue) ~= kind then
        error("newScalarStorage: defaultValue type must match kind '" .. kind .. "'")
    end
    return {
        storageType = "scalar",
        createColumn = function(_self: Storage, size: integer): {Component}
            return table_new(size, 0) as {Component}
        end,
        clear = function(_self: Storage, column: {Component}) table_clear(column) end,
        ensureCapacity = function(_self: Storage, column: {Component}, _needed: integer): {Component}
            return column
        end,
        createComponent = function(_self: Storage, _container: Component): ComponentAllocator<Component>
            return function(value?: any): Component
                if value == nil then
                    return defaultValue as Component
                end
                if type(value) ~= kind then
                    error("scalar component value type must match kind '" .. kind .. "'")
                end
                return value as Component
            end
        end,
        _scalarKind = kind,
        _scalarDefault = defaultValue,
    } as Storage
end

-- Tag storage: no per-row state. Presence is archetype-defined (the
-- archetype either has the column or it doesn't). Reads return the
-- container so `world:get(e, Tag)` yields the tag instance for live
-- rows. Writes are no-ops because there is nothing to store.
local function tagIndex(t: {Component}, _index: integer): Component
    return (t as table).__container as Component
end
local function tagNewIndex()
end
local TAG_MT <const>: metatable<{Component}> = {
    __index = tagIndex,
    __newindex = tagNewIndex,
}

function storage.newBitsetStorage(container: Component): Storage
    return {
        storageType = "tag",

        createColumn = function(_self: Storage, _size: integer): {Component}
            local data = {__container = container}
            return setmetatable(data as {Component}, TAG_MT)
        end,

        clear = function(_self: Storage, _column: {Component}) end,

        ensureCapacity = function(_self: Storage, column: {Component}, _needed: integer): {Component}
            return column
        end,

        createComponent = function(_self: Storage, _container: Component): ComponentAllocator<Component>
            return function(): Component return container end
        end,

        -- A tag holds no per-row state, so its snapshot payload is empty:
        -- presence in the archetype is the whole value. The pair still has
        -- to exist. Snapshot emits a column only for a component that has
        -- a `serialize`, and the table format restores presence from the
        -- per-entity payload, so a tag that serialized to nothing would
        -- come back missing. Without this pair the component falls through
        -- to the default codec in `internal/components.tl`, which walks the
        -- instance; a tag's instance is the container itself, so archetype
        -- signature bookkeeping reaches the save file.
        serialize = function(_self: Storage, _instance: Component): {string: any} return {} end,

        -- The payload is ignored, which is what lets a save written before
        -- tags carried a codec load unchanged: its recorded fields are read
        -- and discarded, and an absent or empty payload restores the same
        -- tag. Column writes are no-ops (`TAG_MT.__newindex`), so returning
        -- the container costs nothing on the column-major load path and
        -- carries presence on the row-major one.
        deserialize = function(_self: Storage, _data: {string: any}): Component return container end,
    } as Storage
end

function storage.newFFIStorage(def: {string: any}): Storage
    local ffi = require("tecs.internal.ffi" as string) as {string: any}
    return (ffi.newFFIStorage as function({string: any}): Storage)(def)
end

function storage.syncMetadataToFFI(s: Storage, container: Component)
    local storageAny = s as {string: any}
    if not storageAny.setMetadata then
        return
    end
    local setMetadata = storageAny.setMetadata as function(Storage, string, any)
    setMetadata(s, "relationshipType", container)
    -- Keep wildcard presence on instances only. The container itself remains
    -- the queryable wildcard component.
    setMetadata(s, "wildcardContainer", container)
    -- Sparse relationship values live outside archetype columns; this flag is
    -- the fast discriminator used by `WorldImpl:has` / `:get`.
    if (container as {string: any}).isSparse then
        setMetadata(s, "isSparseInstance", true)
    end
    local containerAny = container as {string: any}
    if containerAny.exclusiveRelationship ~= nil then
        setMetadata(s, "exclusiveRelationship", containerAny.exclusiveRelationship)
    end
    -- Relationship containers use tag storage for wildcard presence; concrete
    -- FFI instances must point back to the FFI storage for their data column.
    setMetadata(s, "storage", s)
    setMetadata(s, "storageType", s.storageType)
    setMetadata(s, "transient", containerAny.transient == true)

    -- Closed framework behavior metadata is attached to relationship
    -- containers after construction. Mirror only the typed metadata fields.
    for _, key in ipairs({
        "frameworkBehavior",
        "frameworkBehaviorBits",
    }) do
        if containerAny[key] ~= nil then
            setMetadata(s, key, containerAny[key])
        end
    end
end

return storage
