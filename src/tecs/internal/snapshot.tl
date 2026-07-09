--- World snapshotting.
---
--- Two API layers:
---
--- * Streaming (allocation-lean): `saveSnapshot(world, writer)` walks the
---   world archetype-by-archetype and drives the internal writer. The writer
---   sees:
---
---       writer:writePrelude(version, nextEntityId, counts, componentTable)
---       writer:startArchetype(columnCount, entityCount, columnIndices, mode)
---       writer:writeIds(ids, count)                 -- column-major
---       writer:writeColumnRaw(...) / writeColumnValue(...)
---       writer:writeEntity(id, components, count, cols)   -- row-major
---       writer:endArchetype()
---       -- ...more archetypes...
---       writer:writeData(key, value)
---       writer:writeDataEnd()
---       writer:writeEnd()
---
---   `loadSnapshot(world, reader)` reads the prelude, despawns every existing
---   entity, then pulls archetypes via `reader:nextArchetype()` and issues a
---   single `batchSpawnAt` per archetype (falling back to per-entity spawns
---   when the archetype contains a sparse relationship).
---
--- * Table helpers: `saveSnapshotTable` returns a plain Lua snapshot table
---   (JSON-compatible); `loadSnapshotTable` consumes one.
---
--- SaveOptions can filter by query and Transform layer. Writers are still
--- allowed to drop additional entities or archetypes, but built-in filtering
--- happens before writer calls.
---
--- The table format is:
---
---     {
---         version = 1,
---         nextEntityId = integer,
---         componentTable = {{name = "Position"}, {name = "Health"}},
---         archetypes = {
---             {
---                 columnIndices = {1, 2},
---                 entities = {
---                     {1, {...Position...}, {...Health...}},
---                     {2, {...Position...}, {...Health...}},
---                 },
---             },
---             ...
---         },
---         data = {{key = string, value = any}},
---     }
---
--- Entities are stored as positional arrays: `[id, comp1_data, comp2_data, ...]`
--- where each slot aligns with the archetype header's `columnIndices`.
--- Dropping the per-entity component keys cuts JSON size substantially and
--- eliminates per-component hash lookups on the load path (we resolve
--- `columnIndices` through `componentTable` once per archetype).

local types <const> = require("tecs.types")
local internal <const> = require("tecs.internal.types")
local components <const> = require("tecs.internal.components")
local builtins <const> = require("tecs.internal.builtins")
local FFIStorage <const> = require("tecs.internal.ffi.FFIStorage")
local IdAllocator <const> = require("tecs.internal.IdAllocator")
local bit <const> = require("bit")
local StringBuffer <const> = require("string.buffer")

-- string.buffer methods live on one shared metatable; bind them once so
-- per-value writer/reader paths skip a method fetch per call.
local BUF_PROBE <const> = StringBuffer.new()
local BUF_ENCODE <const> = (BUF_PROBE as {string: function}).encode as function(any, any)
local BUF_DECODE <const> = (BUF_PROBE as {string: function}).decode as function(any): any

-- FFI helpers wrap LuaJIT's `ffi` module as untyped (`any`) operations,
-- since LuaJIT's pointer arithmetic and CType juggling don't fit Teal's
-- strict type system. Each helper returns `any` so downstream operations
-- (indexing, +, etc.) work without per-call casts.
local record FFIShim
    new: function(ct: any, n: integer): any
    cast: function(ct: string, src: any): any
    copy: function(dst: any, src: any, n: integer)
    typeof: function(ct: string): any
end
local _ffi <const> = require("ffi") as FFIShim
local function ffiNew(ct: any, n: integer): any return _ffi.new(ct, n) end
local function ffiCopy(dst: any, src: any, n: integer) _ffi.copy(dst, src, n) end
local function ffiTypeof(ct: string): any return _ffi.typeof(ct) end
-- Instantiate a ctype with no count (one struct instance, not an array).
-- LuaJIT idiom: `ctype(...)` calls the constructor for that ctype.
local ffiNewOne <const>: function(any): any =
    (load("return function(ct) return ct() end") as function(): any)() as function(any): any
-- Cast `src` to `char*` and offset by `byteOffset` bytes. Hides FFI pointer
-- arithmetic from Teal's type checker (which doesn't model CData + integer).
-- Compiled once at module load via `load()` so the hot path is just a
-- function call into LuaJIT-friendly code.
local ffiOffsetCharPtr <const>: function(any, integer): any =
    (load("local cast = ...; return function(src, n) return cast('char*', src) + n end") as function(any): any)(_ffi.cast) as function(any, integer): any

-- Double-level offset: returns `src + slots` as a `double*`. Used when
-- downstream code needs to keep reading the pointer as doubles (e.g. the
-- table writer, which does `ptr[k]` expecting one double per step).
-- Entity IDs live in double[] arrays because the 53-bit packed id would
-- overflow int32.
local ffiOffsetDoublePtr <const>: function(any, integer): any =
    (load("local cast = ...; return function(src, n) return cast('double*', src) + n end") as function(any): any)(_ffi.cast) as function(any, integer): any

local type World = types.World
local type Component = types.components.Component
local type ComponentInternal = internal.ComponentInternal
local type Archetype = internal.ArchetypeInternal
local type SnapshotPrelude = types.World.SnapshotPrelude
local type SnapshotTable = types.World.Snapshot
local type SnapshotOptions = types.World.SnapshotOptions
local type SnapshotOutput = types.World.SnapshotOutput
local table_move <const> = table.move

local SNAPSHOT_VERSION <const> = 2

-- Row-major presence masks use exact double arithmetic (LuaJIT's bit
-- library is 32-bit); powers of two up to 2^51 keep every mask integral.
local ROW_MASK_MAX_COLUMNS <const> = 52
local POW2 <const>: {number} = {}
do
    local p = 1
    for i = 1, ROW_MASK_MAX_COLUMNS do
        POW2[i] = p
        p = p * 2
    end
end
local STATE_STACK_DATA_KEY <const> = "__tecs.stateStack"
local PIPELINE_DATA_KEY <const> = "__tecs.pipeline"

local record snapshot
    record Prelude
        version: integer
        nextEntityId: integer
        --- Optional metadata. Writers that know these cheaply set them;
        --- streaming writers with no archetype count up front can omit.
        entityCount: integer
        archetypeCount: integer
        --- Component table: ordered list of (name, fingerprint) pairs that
        --- archetype frames reference by 1-based index. Built by saveSnapshot's
        --- pre-pass, consumed by readers to resolve components once.
        componentTable: {ComponentTableEntry}
    end

    record ComponentTableEntry
        name: string
        --- Canonical field-layout fingerprint for FFI components. The
        --- binary format embeds it to detect schema drift and route to
        --- per-entity migration when saved and current layouts differ.
        --- The table/JSON format omits it entirely -- loads there go
        --- through per-component `deserialize`, which is field-name-keyed
        --- and migrates naturally.
        fingerprint: string | nil
    end

    interface Writer
        --- Emit the prelude. `componentTable` is the full set of components
        --- referenced by the snapshot's archetypes; archetype frames refer
        --- to entries by 1-based index.
        writePrelude: function(self: Writer,
            version: integer,
            nextEntityId: integer,
            entityCount: integer,
            archetypeCount: integer,
            componentTable: {ComponentTableEntry})

        --- Open a new archetype frame. `columnIndices` references the
        --- prelude's componentTable. `mode` is 0 for column-major (dense
        --- archetype, FFI columns get bulk memcpy) or 1 for row-major
        --- (sparse-bearing archetype, fall back to per-entity emit).
        startArchetype: function(self: Writer,
            columnCount: integer,
            entityCount: integer,
            columnIndices: {integer},
            mode: integer)

        --- Column-major mode only: bulk-write the entity ID array.
        --- `idsArray` is opaque (FFI double[] for binary writers, Lua
        --- array for table writers); writers consume `count` elements.
        writeIds: function(self: Writer, idsArray: any, count: integer)

        --- Column-major mode only: bulk-write a whole FFI column.
        --- `colIdx` is the 1-based position within the archetype frame
        --- (matches `columnIndices`). Optional method -- present only on
        --- writers that can handle raw bytes (BufferWriter). saveSnapshot
        --- calls this for FFI dense columns when the writer supports it.
        writeColumnRaw: function(self: Writer, colIdx: integer, srcPtr: any, byteCount: integer)

        --- Column-major mode only: write one component value, called
        --- `entityCount` times per non-FFI column. `colIdx` is the
        --- archetype-local column position; lets table writers demux
        --- per-column buffers without inferring from call order.
        writeColumnValue: function(self: Writer, colIdx: integer, value: Component, comp: Component)

        --- Row-major mode only (sparse archetypes). `comps[1..count]`
        --- aligns with the archetype header's columns; missing sparse
        --- values are represented as nil entries so binary writers can
        --- emit a self-describing presence bitmap. `cols[1..count]` are
        --- the column components; serializers resolve through them
        --- (values can be raw scalars with no componentType), mirroring
        --- how readers resolve deserializers from the component table.
        writeEntity: function(self: Writer, id: integer, comps: {Component}, count: integer,
            cols: {Component})

        endArchetype: function(self: Writer)

        --- Append a (key, value) pair to the snapshot's data section.
        --- Key is a string, value is anything string.buffer-encodable.
        --- Called by `saveSnapshot` for each `opts.customData` entry,
        --- then once per `OnSnapshotSave` listener's `addData` call.
        writeData: function(self: Writer, key: string, value: any)

        --- Close the data section. Called once after all `writeData` calls.
        writeDataEnd: function(self: Writer)

        --- Called after the data section is closed, before `saveSnapshot`
        --- returns. Writers can flush or emit trailing content here.
        writeEnd: function(self: Writer)
    end

    interface Reader
        --- Read the prelude. The returned Prelude includes `componentTable`,
        --- which the reader has already resolved internally (each entry's
        --- component looked up by name + schema match decision computed once).
        readPrelude: function(self: Reader): Prelude

        --- Advance to the next archetype. Returns:
        --- (componentTypes, columnIndices, entityCount, mode)
        --- - componentTypes: resolved Component array in column order
        --- - columnIndices: 1-based indices into prelude.componentTable
        --- - mode: 0=column-major, 1=row-major (sparse-bearing)
        --- Returns nil for componentTypes when no more archetypes.
        nextArchetype: function(self: Reader): {Component}, {integer}, integer, integer

        --- Column-major mode only: bulk-read entity IDs into a destination
        --- array. `dest` may be FFI double[] or a Lua array. Reader fills
        --- `dest[0..count-1]` (FFI) or `dest[1..count]` (Lua) per its convention.
        readIds: function(self: Reader, count: integer): any

        --- Column-major mode only: bulk-read raw bytes from the buffer
        --- directly into `destBase + byteOffset`. Used for FFI fast-path
        --- column copy. Caller guarantees `byteCount` matches the writer's.
        --- Splitting destBase from offset lets the reader own pointer
        --- arithmetic (which Teal's type system doesn't model).
        readColumnRawInto: function(self: Reader, destBase: any, byteOffset: integer, byteCount: integer)

        --- True when the column at `colIdx` in the current archetype can
        --- be bulk-memcpy'd safely (schema matches between save and load).
        --- False when the reader must route through `readColumnValue` to
        --- migrate per-entity.
        schemaMatchesForColumn: function(self: Reader, colIdx: integer): boolean

        --- Column-major mode only: read one column value, decoding per
        --- entity. Handles non-FFI components (via `deserialize`), custom
        --- codecs, and schema migration when the saved FFI layout differs
        --- from the current registration.
        readColumnValue: function(self: Reader, colIdx: integer, world: World): Component

        --- Row-major mode only (sparse archetypes). Returns one entity row
        --- as `(id, comp1, comp2, ...)` matching the legacy shape. `nil` id
        --- signals end of archetype.
        readEntity: function(self: Reader): integer, Component...

        --- Read the next (key, value) pair from the snapshot's data section.
        --- Returns (nil, nil) when the section ends. `loadSnapshot` calls
        --- this in a loop after archetypes are loaded, dispatching each
        --- pair to `StartSnapshotLoad:onData` callbacks.
        nextData: function(self: Reader): string, any

        --- Called by `loadSnapshot` after the final archetype is consumed.
        --- Paired with `Writer.writeEnd`: readers that skipped over trailing
        --- custom content in `nextArchetype` can surface or seek past it here.
        readEnd: function(self: Reader)
    end

    record ArchetypeEntry
        --- 1-based indices into `Snapshot.componentTable`. Order matches the
        --- positions inside each entity row.
        columnIndices: {integer}
        -- Each entity is `{id, data_1, data_2, ..., data_N}` aligned to
        -- `columnIndices`. `data_i` is whatever the component referenced
        -- by `columnIndices[i]`'s `serialize` returned.
        entities: {{any}}
    end

    record DataEntry
        key: string
        value: any
    end

    record Snapshot
        version: integer
        nextEntityId: integer
        --- Component table is the source of truth for archetype column
        --- references. ArchetypeEntry.columnIndices points into this list.
        --- Names + fingerprint are kept here once instead of being repeated
        --- per archetype.
        componentTable: {ComponentTableEntry}
        archetypes: {ArchetypeEntry}
        --- Ordered (key, value) pairs appended to the snapshot after all
        --- archetypes. Populated by `opts.customData` and any `addData`
        --- calls from `OnSnapshotSave` listeners.
        data: {DataEntry}
    end

    --- Options passed to `saveSnapshot`. All fields are optional.
    record SaveOptions
        --- `"binary"` (default) or `"table"`.
        format: types.World.SnapshotFormat
        --- Reuse this `string.buffer` instead of allocating a fresh one.
        --- The buffer is `:reset()` first, so prior contents are discarded.
        --- Useful for callers that save in a loop and want to amortize
        --- the underlying allocation.
        buffer: StringBuffer
        --- Optional file path for binary output.
        path: string
        --- QueryDescriptor whose include/includeAny/exclude set selects the
        --- archetypes that should be saved. Built into a temp query internally.
        --- Composes freely with `layers`; no Transform requirement.
        filterQuery: types.Query.Descriptor
        --- Allow-list of `Transform.layer` values (must fit in 0..31).
        --- Entities carrying a `Transform` whose `layer` is NOT in this
        --- set are skipped. Entities without a `Transform` pass through
        --- unaffected -- `layers` is a filter on Transform-bearing
        --- entities, not a hard gate.
        layers: {integer}
        --- Ad-hoc keyed metadata to attach to this snapshot. Each `(key,
        --- value)` pair gets emitted into the snapshot's data section,
        --- read back via `StartSnapshotLoad:onData(key, cb)` on load.
        --- Keys must be strings; values must be string.buffer-encodable.
        --- Map iteration order is undefined; if your encoding needs
        --- determinism, use the `OnSnapshotSave` event instead.
        customData: {string: any}
    end

    --- Save the world. Returns the LuaJIT `string.buffer` holding the
    --- snapshot bytes. Pass `opts.buffer` to reuse an existing buffer
    --- (it gets `:reset()` first); otherwise a fresh buffer is allocated.
    --- See the Love2D export patterns in the snapshot docs.
    saveSnapshot: function(world: World, opts: SnapshotOptions): SnapshotOutput

    --- Load a snapshot from a Lua string OR a `string.buffer`. Strings
    --- are copied once into an internal buffer; buffers are consumed in
    --- place. Returns the snapshot prelude (version, counts).
    ---
    --- Custom metadata flows through events on entity 0:
    ---   - `StartSnapshotLoad` -- listeners register per-key callbacks
    ---     via `ev:onData(key, function(value) ... end)`
    ---   - `FinishSnapshotLoad(prelude)` -- fires once after every data
    ---     callback has run
    loadSnapshot: function(world: World, source: any): SnapshotPrelude

    --- Build an in-memory `Snapshot` table -- JSON-friendly, useful for
    --- programmatic inspection / migration. Slower than the buffer path.
    --- Accepts the same options as `saveSnapshot`.
    saveSnapshotTable: function(world: World, opts: SnapshotOptions): SnapshotTable

    --- Load from a `Snapshot` table previously produced by
    --- `saveSnapshotTable` (or parsed from JSON). Same event emission
    --- semantics as `loadSnapshot`.
    loadSnapshotTable: function(world: World, snap: SnapshotTable): SnapshotPrelude
end

-------------------------------------------------------------------------------
-- Schema migration (load-side slow path)
-------------------------------------------------------------------------------
--
-- When an FFI component's `fingerprint` differs between save-time and load-time
-- (field added / removed / reordered, or ctype changed), the bulk-memcpy path
-- is unsafe: it would copy bytes laid out under the saved schema into a
-- struct shaped by the current schema, silently corrupting data.
--
-- The slow path cdef's a struct matching the SAVED layout, reads each entity's
-- bytes into that struct, then constructs a current-schema instance by copying
-- same-named fields across. New fields get their zero default; removed fields
-- are dropped. Type changes ride LuaJIT's implicit numeric conversion (int →
-- float, etc.); incompatible conversions (array size change, different
-- aggregate shapes) still error inside LuaJIT, which is the right outcome.

local record MigSchemaInfo
    structType: any              -- ffi.typeof('struct __tecs_mig_N')
    fields: {{string, string}}   -- saved schema fields as [{name, ctype}]
    size: integer                -- savedSize in bytes
end

local migStructCounter = 0
local migSchemaCache: {string: MigSchemaInfo} = {}

-- Parse a fingerprint of the form `name1:type1,name2:type2,...|sizeBytes`
-- into its component field list and total struct size.
local function parseSchema(fingerprint: string): {{string, string}}, integer
    local fieldsPart, sizePart = fingerprint:match("^(.-)|(%d+)$")
    if not fieldsPart then
        error("snapshot: invalid fingerprint format: " .. fingerprint)
    end
    local size = tonumber(sizePart) as integer
    local fields: {{string, string}} = {}
    for part in fieldsPart:gmatch("[^,]+") do
        local name, ctype = part:match("^([^:]+):(.+)$")
        if not name or not ctype then
            error("snapshot: invalid schema field: '" .. part .. "' in " .. fingerprint)
        end
        fields[#fields + 1] = {name, ctype}
    end
    return fields, size
end

-- Resolve a saved fingerprint to a dynamically-cdef'd struct type.
-- Cached globally by fingerprint so repeat migrations reuse the same ctype.
-- The struct definition itself is generated by `FFIStorage.defineStruct`,
-- so the migration layout uses the exact same field->cdef logic as real
-- component registrations (array syntax, type aliases, etc.).
local function getOrBuildMigSchema(fingerprint: string): MigSchemaInfo
    local cached = migSchemaCache[fingerprint]
    if cached then return cached end

    local fields, size = parseSchema(fingerprint)
    migStructCounter = migStructCounter + 1
    local structName = "__tecs_mig_" .. migStructCounter
    local structType, _ = FFIStorage.defineStruct(structName, fields)

    local info: MigSchemaInfo = {
        structType = structType,
        fields = fields,
        size = size,
    }
    migSchemaCache[fingerprint] = info
    return info
end

-- Build a per-entity migrator that reads `savedSize` bytes from the buffer
-- into a scratch struct shaped by the saved schema, then constructs a
-- current-schema instance by copying same-named fields. Returns a
-- `function(buf) -> instance` closure.
local function buildMigrator(comp: Component, savedFingerprint: string): function(any): any
    local savedInfo = getOrBuildMigSchema(savedFingerprint)
    local savedFields = savedInfo.fields
    local nSaved = #savedFields
    local savedSize = savedInfo.size

    local currentFingerprint = (comp as {string: any}).fingerprint as string or ""
    local currentInfo = getOrBuildMigSchema(currentFingerprint)
    local currentNames: {string: boolean} = {}
    for i = 1, #currentInfo.fields do
        currentNames[currentInfo.fields[i][1]] = true
    end

    -- One persistent scratch instance; safe to reuse since each entity
    -- fully overwrites it before fields get projected into the instance.
    local scratch = ffiNewOne(savedInfo.structType)
    local scratchFields = scratch as {string: any}
    local constructor = comp as function(): any

    return function(buf: any): any
        local ref <const> = (buf as {string: function}).ref as function(any): any
        local skip <const> = (buf as {string: function}).skip as function(any, integer)
        ffiCopy(scratch, ref(buf), savedSize)
        skip(buf, savedSize)

        local instance = constructor()
        local instanceFields = instance as {string: any}
        for i = 1, nSaved do
            local name = savedFields[i][1]
            if currentNames[name] then
                instanceFields[name] = scratchFields[name]
            end
        end
        return instance
    end
end

-------------------------------------------------------------------------------
-- Streaming save
-------------------------------------------------------------------------------

-- Per-archetype cache of (cols, hasSparse) -- emit-eligible components in
-- archetype.componentList order, plus a flag if any are sparse-container
-- (which routes the archetype through the row-major emit). Component sets
-- are immutable per archetype, so this cache never needs invalidation.
local record ArchetypeColumnsCache
    cols: {Component}
    hasSparse: boolean
end
-- Weak keys: destroyed archetypes (compact, discarded worlds) must not be
-- pinned for the process lifetime by this module-global cache.
local archetypeColumnsCache: {Archetype: ArchetypeColumnsCache} =
    setmetatable({}, {__mode = "k"})

local function archetypeColumns(arch: Archetype): {Component}, boolean
    local cached = archetypeColumnsCache[arch]
    if cached then return cached.cols, cached.hasSparse end

    local cols: {Component} = {}
    local hasSparse = false
    for i = 1, arch.columnsCount do
        local comp = arch.componentList[i]
        local emit = false
        if (comp as ComponentInternal).transient then
            emit = false
        elseif (comp as ComponentInternal).isSparse and (comp as ComponentInternal).isContainer then
            emit = comp.serialize ~= nil
            if emit then hasSparse = true end
        elseif not (comp as ComponentInternal).isContainer then
            emit = comp.serialize ~= nil
        end
        if emit then
            cols[#cols + 1] = comp
        end
    end
    archetypeColumnsCache[arch] = {cols = cols, hasSparse = hasSparse}
    return cols, hasSparse
end

local function captureStateStack(world: World): {string}
    local stack = (world as {string: any})._stateStack as {string}
    if stack == nil or #stack == 0 then return nil end
    local out: {string} = {}
    for i = 1, #stack do
        out[i] = stack[i]
    end
    return out
end

local function restoreStateStack(world: World, saved: {string})
    if saved == nil then return end
    local worldAny = world as {string: any}
    local states = worldAny._stateComponents as {string: Component}
    local stack: {string} = {}
    for i = 1, #saved do
        local name = saved[i]
        if states[name] == nil then
            error("loadSnapshot: saved state '" .. tostring(name) ..
                "' is not registered in this world; call world:createState('" ..
                tostring(name) .. "') before loading")
        end
        stack[#stack + 1] = name
    end
    worldAny._stateStack = stack
    local top = stack[#stack]
    worldAny.autoStateComponent = top and states[top] or nil
end

local function capturePipelineState(world: World): {string:any}
    local pipeline = (world as {string:any}).pipeline as {string:any}
    if not pipeline then return nil end
    if pipeline.fixedAccumulator == nil and pipeline.phaseStates == nil then return nil end

    local out: {string:any} = {}
    if pipeline.fixedAccumulator ~= nil then
        out.fixedAccumulator = pipeline.fixedAccumulator
    end

    local phaseStates = pipeline.phaseStates as {boolean}
    if phaseStates then
        local states: {boolean} = {}
        for i = 1, #phaseStates do
            states[i] = phaseStates[i] == true
        end
        out.phaseStates = states
    end
    return out
end

local function restorePipelineState(world: World, saved: {string:any})
    if saved == nil then return end
    local pipeline = (world as {string:any}).pipeline as {string:any}
    if not pipeline then return end

    if saved.fixedAccumulator ~= nil and pipeline.fixedAccumulator ~= nil then
        pipeline.fixedAccumulator = saved.fixedAccumulator
    end

    local savedPhaseStates = saved.phaseStates as {boolean}
    local phaseStates = pipeline.phaseStates as {boolean}
    if savedPhaseStates and phaseStates then
        for i = 1, #savedPhaseStates do
            if phaseStates[i] ~= nil then
                phaseStates[i] = savedPhaseStates[i] == true
            end
        end
        pipeline.dirty = true
    end
end

local function cloneComponentList(list: {Component}): {Component}
    if not list then return nil end
    local out: {Component} = {}
    for i = 1, #list do out[i] = list[i] end
    return out
end

local function cloneQueryDescriptor(d: types.Query.Descriptor): types.Query.Descriptor
    if not d then return nil end
    local out: types.Query.Descriptor = {}
    for k, v in pairs(d as {string:any}) do
        (out as {string:any})[k] = v
    end
    out.include = cloneComponentList(d.include)
    out.includeAny = cloneComponentList(d.includeAny)
    out.exclude = cloneComponentList(d.exclude)
    return out
end

-- Build an integer bitmask of allowed `Transform.layer` values from the
-- user-provided list. Layers >= 32 error out since we use bit.band on a
-- uint32. In practice games stay well under that.
local function buildLayerMask(layers: {integer}): integer
    local mask = 0
    for i = 1, #layers do
        local l = layers[i]
        if l < 0 or l > 31 then
            error("saveSnapshot: layer " .. tostring(l) .. " out of range 0..31 for bitmask matching")
        end
        mask = bit.bor(mask, bit.lshift(1, l))
    end
    return mask
end

-- Resolve the effective query + per-entity layer filter from SaveOptions.
-- Returns (query, layerMask) where either can be nil. Layer filtering is
-- applied per-archetype inside the main loop: archetypes that don't have
-- Transform pass through unconditionally; archetypes that do get their
-- entities filtered by layer.
local function resolveSaveFilters(world: World, opts: SnapshotOptions, filterQuery: types.Query.Descriptor): types.Query, integer
    local layerMask: integer = nil
    if opts.layers then
        layerMask = buildLayerMask(opts.layers)
    end

    local query: types.Query
    if filterQuery then
        local d: types.Query.Descriptor = cloneQueryDescriptor(filterQuery)
        d.temp = true
        query = world:query(d)
    end
    return query, layerMask
end

-- Does this archetype carry a Transform column? Layer filtering only
-- applies to archetypes where the answer is yes.
local function archetypeHasTransform(arch: Archetype): boolean
    return arch.columns[builtins.Transform as types.components.Component] ~= nil
end

-- Count entities that will actually be emitted per archetype + total, given
-- the resolved filters. We need the per-archetype count to send an accurate
-- `startArchetype(count)` so the reader loops the right number of times.
local function countFilteredArchetype(arch: Archetype, layerMask: integer, hasTransform: boolean): integer
    local full = arch.entities[0]
    if full == 0 then return 0 end
    if layerMask == nil or not hasTransform then return full end
    local transforms = arch.columns[builtins.Transform as types.components.Component] as {{string: integer}}
    local n = 0
    for row = 1, full do
        local layer = transforms[row].layer
        if bit.band(layerMask, bit.lshift(1, layer)) ~= 0 then
            n = n + 1
        end
    end
    return n
end

-- Layer-filter helper. Returns a contiguous double cdata array of entity ids
-- that pass the layer mask, plus the count. Reused per-archetype if needed.
local doubleArrayType <const>: any = ffiTypeof("double[?]")
local function buildFilteredIds(arch: Archetype, layerMask: integer, count: integer): any
    local ids = ffiNew(doubleArrayType, count) as {integer: integer}
    local transforms = arch.columns[builtins.Transform as types.components.Component] as {{string: integer}}
    local entities = arch.entities as {integer}
    local idx = 0
    for row = 1, arch.entities[0] do
        if bit.band(layerMask, bit.lshift(1, transforms[row].layer)) ~= 0 then
            ids[idx] = entities[row]
            idx = idx + 1
        end
    end
    return ids
end

-- Forward declarations for the internal Writer constructors. Defined
-- below; referenced here by `saveSnapshot` / `saveSnapshotTable`.
local newBufferWriterImpl: function(any): snapshot.Writer
local newTableWriterImpl: function(): snapshot.Writer, function(): SnapshotTable

-- Shared orchestration for both `saveSnapshot` (binary buffer destination)
-- and `saveSnapshotTable` (in-memory Lua table). The writer abstraction is
-- internal -- users only see the public `saveSnapshot` / `saveSnapshotTable`
-- functions.
local function saveSnapshotImpl(world: World, writer: snapshot.Writer, opts: SnapshotOptions)
    -- Fire `OnSnapshotSave` first so plugins can declare which derived
    -- entities to exclude (`ev:exclude(comp)`) and queue keyed metadata
    -- (`ev:addData(k, v)`). Excludes are merged into the filter BEFORE
    -- the archetype walk; addData calls are queued and flushed after
    -- archetypes are written so they land in the data section.
    local pendingDataPairs: {{string, any}} = {}
    local excludedComponents: {Component} = {}
    local stateStack = captureStateStack(world)
    local pipelineState = capturePipelineState(world)
    do
        local saveEvent = builtins.OnSnapshotSave()
        local evAny = saveEvent as {string: any}
        evAny.addData = function(_self: any, k: string, v: any)
            pendingDataPairs[#pendingDataPairs + 1] = {k, v}
        end
        evAny.exclude = function(_self: any, comp: Component)
            excludedComponents[#excludedComponents + 1] = comp
        end
        world:emit(0, saveEvent as types.events.Event)
    end

    -- Merge any plugin-declared excludes into a cloned filter descriptor;
    -- the caller-owned opts table stays untouched so a reused opts table
    -- does not accumulate excludes across saves.
    local filterQuery = opts.filterQuery
    if #excludedComponents > 0 then
        local d: types.Query.Descriptor = cloneQueryDescriptor(filterQuery) or {}
        local exclude = d.exclude
        if not exclude then
            exclude = {}
            d.exclude = exclude
        end
        for i = 1, #excludedComponents do
            exclude[#exclude + 1] = excludedComponents[i]
        end
        filterQuery = d
    end

    local query, layerMask = resolveSaveFilters(world, opts, filterQuery)

    -- Pre-pass: walk all matched archetypes once. Three jobs in one loop:
    --   1. Count total entities + archetypes for the prelude metadata.
    --   2. Collect the unique components used into componentTable so
    --      archetype frames can reference them by integer index.
    --   3. Cache per-archetype eligible columns + sparse mode flag so the
    --      emit loop below doesn't re-walk arch.componentList.
    local componentTable: {snapshot.ComponentTableEntry} = {}
    local componentIndex: {Component: integer} = {}

    local record EmitEntry
        arch: Archetype
        cols: {Component}
        columnIndices: {integer}
        count: integer
        hasSparse: boolean
        -- True when the archetype carries a Transform AND `layers` was
        -- set. Archetypes without Transform always pass through in full,
        -- even when `layers` is present.
        applyLayerFilter: boolean
    end
    local emitList: {EmitEntry} = {}
    local totalEntityCount = 0

    local function addComponent(comp: Component): integer
        local idx = componentIndex[comp]
        if idx then return idx end
        idx = #componentTable + 1
        componentIndex[comp] = idx
        -- Dense relationship instance columns save as
        -- "<container>-><target>": FFI instances share one metatype
        -- componentName across targets, and per-target instances may not
        -- exist yet in the loading process, so the loader reconstructs
        -- them from the container. Table-backed instances already carry
        -- this name shape.
        local name = comp.componentName
        local wildcard = (comp as ComponentInternal).wildcardContainer
        if wildcard and comp.target ~= nil then
            name = wildcard.componentName .. "->" .. tostring(comp.target)
        end
        componentTable[idx] = {
            name = name,
            fingerprint = (comp as {string: any}).fingerprint as string or "",
        }
        return idx
    end

    local function processArchetype(arch: Archetype)
        local hasTransform = archetypeHasTransform(arch)
        local count = countFilteredArchetype(arch, layerMask, hasTransform)
        if count == 0 then return end

        -- Archetypes with zero serializable columns (empty entities, or
        -- all components transient) still emit an id-only frame: entity
        -- identity survives the snapshot even when no data does, per the
        -- transient contract in docs/tecs/save-games.md.
        local cols, hasSparse = archetypeColumns(arch)

        local columnIndices: {integer} = {}
        for i = 1, #cols do
            columnIndices[i] = addComponent(cols[i])
        end

        emitList[#emitList + 1] = {
            arch = arch,
            cols = cols,
            columnIndices = columnIndices,
            count = count,
            hasSparse = hasSparse,
            applyLayerFilter = layerMask ~= nil and hasTransform,
        }
        totalEntityCount = totalEntityCount + count
    end

    if query then
        for arch, _len in query:iter() do processArchetype(arch as Archetype) end
    else
        world:forEachArchetype(processArchetype as function(types.Archetype))
    end

    writer:writePrelude(
        SNAPSHOT_VERSION,
        -- Arena-based allocation: emit `nextFreshSlot` as the nextEntityId
        -- so snapshot round-trips preserve the slot space.
        ((world as {string: any}).allocator as {string: integer}).nextFreshSlot as integer,
        totalEntityCount,
        #emitList,
        componentTable)

    local stores = (world as {string: any}).relationshipStores as {any: any}
    local vals: {Component} = {}
    local writerAny = writer as {string: any}
    local hasBulkColumnRaw = writerAny.writeColumnRaw ~= nil

    for _, entry in ipairs(emitList) do
        local arch = entry.arch
        local cols = entry.cols
        local count = entry.count
        local hasSparse = entry.hasSparse
        local applyLayerFilter = entry.applyLayerFilter
        local mode = hasSparse and 1 or 0

        writer:startArchetype(#cols, count, entry.columnIndices, mode)

        if mode == 0 then
            -- COLUMN-MAJOR FAST PATH (dense archetype, no sparse containers).
            -- Bulk-write the entity IDs, then bulk-write each FFI column
            -- (or per-entity-encode each non-FFI column).
            local idsArray: any
            if applyLayerFilter then
                idsArray = buildFilteredIds(arch, layerMask, count)
            else
                -- arch.entities is a double[N+1] where [0] is the length and
                -- [1..N] are ids. Pass `entities + 1` straight to the writer:
                -- BufferWriter memcpys the bytes, TableWriter reads via
                -- cdata indexing. Zero allocations on the unfiltered path.
                -- Offset the FFI pointer by one double slot so we skip
                -- the leading length field. BufferWriter memcpys bytes;
                -- TableWriter reads via `ptr[k]`, so we keep double step.
                idsArray = ffiOffsetDoublePtr(arch.entities, 1)
            end
            writer:writeIds(idsArray, count)

            for c = 1, #cols do
                local comp = cols[c]
                local structSize = (comp as {string: any}).structSize as integer
                -- Bulk-eligible: FFI struct-backed AND uses the auto-installed
                -- raw serializer. Components that supply a custom `serialize`
                -- (e.g. `Text`, which holds non-portable glyph slab pointers)
                -- skip the auto-install of `serializeRaw`, so they fall back
                -- to the per-entity path even though `structSize` is set.
                local bulkEligible = hasBulkColumnRaw and structSize and (comp as ComponentInternal).serializeRaw
                    and not (comp as ComponentInternal).isContainer
                local column = arch.columns[comp]
                if bulkEligible and not applyLayerFilter then
                    -- FFI bulk: one putcdata of structSize * count bytes.
                    -- Skip slot 0 (FFI columns reserve it as padding so
                    -- 1-based entity rows align with array indices).
                    writer:writeColumnRaw(c, ffiOffsetCharPtr(column, structSize), structSize * count)
                elseif bulkEligible then
                    -- FFI but layer-filtered: emit per-entity raw via the
                    -- per-component serializeRaw path. Still no allocation.
                    local typedColumn = column as {Component}
                    local transforms = arch.columns[builtins.Transform as types.components.Component] as {{string: integer}}
                    for row = 1, arch.entities[0] do
                        if bit.band(layerMask, bit.lshift(1, transforms[row].layer)) ~= 0 then
                            writer:writeColumnValue(c, typedColumn[row], comp)
                        end
                    end
                else
                    -- Per-entity encoded value (non-FFI, or table writer).
                    local typedColumn = column as {Component}
                    if applyLayerFilter then
                        local transforms = arch.columns[builtins.Transform as types.components.Component] as {{string: integer}}
                        for row = 1, arch.entities[0] do
                            if bit.band(layerMask, bit.lshift(1, transforms[row].layer)) ~= 0 then
                                writer:writeColumnValue(c, typedColumn[row], comp)
                            end
                        end
                    else
                        for row = 1, arch.entities[0] do
                            writer:writeColumnValue(c, typedColumn[row], comp)
                        end
                    end
                end
            end
        else
            -- ROW-MAJOR FALLBACK (sparse-bearing archetype). Per-entity
            -- emit with per-row sparse holes preserved so the writer can
            -- encode which archetype columns are present for each entity.
            local entities = arch.entities as {integer}
            local transforms: {{string: integer}}
            if applyLayerFilter then
                transforms = arch.columns[builtins.Transform as types.components.Component] as {{string: integer}}
            end

            for row = 1, arch.entities[0] do
                if applyLayerFilter then
                    if bit.band(layerMask, bit.lshift(1, transforms[row].layer)) == 0 then
                        goto continue
                    end
                end

                local entityId = entities[row]
                for i = 1, #cols do
                    local comp = cols[i]
                    if (comp as ComponentInternal).isSparse and (comp as ComponentInternal).isContainer then
                        local store = stores[comp] as {string: function(any, integer): any}
                        if store and comp.serialize then
                            local value = store.get(store, entityId)
                            -- Non-exclusive sparse stores hold a target map
                            -- per source; the snapshot row format carries one
                            -- value per (entity, container), so these cannot
                            -- round-trip. Fail at save time instead of
                            -- corrupting the load.
                            if value ~= nil
                                    and not (comp as types.components.Relationship).exclusiveRelationship then
                                error("snapshot: non-exclusive sparse relationship '"
                                    .. comp.componentName
                                    .. "' cannot be serialized; mark it transient")
                            end
                            vals[i] = value as Component
                        else
                            vals[i] = nil
                        end
                    elseif not (comp as ComponentInternal).isContainer then
                        local col = arch.columns[comp] as {Component}
                        vals[i] = col[row]
                    else
                        vals[i] = nil
                    end
                end
                writer:writeEntity(entityId, vals, #cols, cols)
                ::continue::
            end
        end

        writer:endArchetype()
    end

    -- Data section: reserved framework data is written first, then
    -- opts.customData (map of string→any), then any (key, value) pairs
    -- queued by `OnSnapshotSave`
    -- listeners earlier in this function are flushed. Each writeData
    -- call writes one pair; writeDataEnd closes with a sentinel.
    if stateStack ~= nil then
        writer:writeData(STATE_STACK_DATA_KEY, stateStack)
    end
    if pipelineState ~= nil then
        writer:writeData(PIPELINE_DATA_KEY, pipelineState)
    end
    if opts.customData then
        for k, v in pairs(opts.customData) do
            writer:writeData(k, v)
        end
    end
    for i = 1, #pendingDataPairs do
        writer:writeData(pendingDataPairs[i][1], pendingDataPairs[i][2])
    end
    writer:writeDataEnd()

    writer:writeEnd()
end

local function writeBufferToPath(path: string, buf: any)
    local f, err = io.open(path, "wb")
    if not f then
        error("saveSnapshot: failed to open '" .. path .. "': " .. tostring(err))
    end
    local bufToString = (buf as {string: any}).tostring as function(any): string
    local ok, writeErr = f:write(bufToString(buf))
    f:close()
    if not ok then
        error("saveSnapshot: failed to write '" .. path .. "': " .. tostring(writeErr))
    end
end

local function saveBinary(world: World, opts: SnapshotOptions): SnapshotOutput
    local buf = opts.buffer
    if buf then
        local bufAny = buf as {string: function}
        bufAny.reset(buf)
    else
        buf = StringBuffer.new()
    end
    saveSnapshotImpl(world, newBufferWriterImpl(buf), opts)
    if opts.path ~= nil then
        writeBufferToPath(opts.path, buf)
    end
    return {
        format = "binary",
        buffer = buf,
        snapshot = nil,
    } as SnapshotOutput
end

local function saveTable(world: World, opts: SnapshotOptions): SnapshotOutput
    if opts.buffer ~= nil then
        error("saveSnapshot: opts.buffer is only valid for binary output")
    end
    if opts.path ~= nil then
        error("saveSnapshot: opts.path is only valid for binary output")
    end
    local writer, get = newTableWriterImpl()
    saveSnapshotImpl(world, writer, opts)
    return {
        format = "table",
        buffer = nil,
        snapshot = get(),
    } as SnapshotOutput
end

function snapshot.saveSnapshot(world: World, opts: SnapshotOptions): SnapshotOutput
    opts = opts or {} as SnapshotOptions
    if opts.format == "table" then
        return saveTable(world, opts)
    end
    return saveBinary(world, opts)
end

-------------------------------------------------------------------------------
-- Streaming load
-------------------------------------------------------------------------------

local function clearWorld(world: World)
    -- Load-replace wipes in place: a snapshot load replaces the world
    -- rather than despawning gameplay entities, so no per-entity
    -- OnDespawn fan-out fires. clearEntities also resets the allocator,
    -- bumping every touched generation so pre-load handles cannot alias
    -- restored ids, and empties the free stack for batchSpawnAt.
    world:clearEntities()
end

-- Column-major fast path. For each FFI dense column, do ONE bulk memcpy
-- from the buffer into the archetype column (no per-entity allocations).
-- Non-FFI columns fall through to per-entity decode.
local function loadColumnMajor(
    world: internal.WorldImpl,
    reader: snapshot.Reader,
    componentTypes: {Component},
    entityCount: integer
)
    if entityCount == 0 then return end

    -- Bulk-read ids into an FFI double[] and hand the pointer straight
    -- to `batchSpawnAtRaw` -- no per-entity copy to a Lua table. Only the
    -- binary reader reaches this path (TableReader always reports row
    -- mode), so `ids` is guaranteed to be cdata.
    local ids = reader:readIds(entityCount)

    world:batchSpawnAtRaw(ids, entityCount, componentTypes,
        function(arch: Archetype, rowStart: integer, _rowEnd: integer, count: integer)
            for col = 1, #componentTypes do
                local comp = assert(
                    componentTypes[col],
                    "loadSnapshot: unknown component in saved archetype"
                ) as ComponentInternal
                local structSize = (comp as {string: any}).structSize as integer
                local archColumn = arch.columns[comp] as any

                -- Match save-side bulk eligibility: FFI struct + raw codec + not a container
                -- + saved schema matches current. Schema drift forces the per-entity
                -- migration path; the reader's migrator handles byte-level remapping into
                -- the current layout.
                local bulkEligible = structSize
                    and comp.deserializeRaw
                    and not comp.isContainer
                    and reader.readColumnRawInto
                    and reader:schemaMatchesForColumn(col)
                if bulkEligible then
                    -- FAST PATH: bulk memcpy buffer → archetype column.
                    reader:readColumnRawInto(archColumn, rowStart * structSize, structSize * count)
                else
                    -- SLOW PATH: per-entity decode (custom serialize, containers, non-FFI,
                    -- schema-mismatched FFI, or readers without bulk capability). Reader
                    -- internally routes through the migrator when appropriate.
                    for k = 0, count - 1 do
                        local val = reader:readColumnValue(col, world) as any
                        -- A nil value means the component's serialize returned nil at save time
                        -- (transient state, synthetic paths, etc.) and the framework skipped its
                        -- deserialize. For FFI columns we MUST NOT assign nil -- LuaJIT raises a
                        -- conversion error that corrupts the unwinder. Leave the slot at its
                        -- zero-initialized default; downstream systems already check for sentinel
                        -- values like ``spriteId == 0` or `gpuSlot == -1`.
                        if val ~= nil then
                            if comp.storageType == "scalar" and type(val) == "table" then
                                val = (val as {string:any}).value
                            end
                            (archColumn as {any})[rowStart + k] = val
                        end
                    end
                end
            end
    end)
end

-- Row-major fallback for sparse-bearing archetypes. Per-entity spawnAt
-- so setSparse fires correctly. readEntity consumes buffer bytes
-- eagerly, so the whole archetype stages under one scope and drains
-- once instead of paying a full transaction per entity.
local function loadRowMajor(world: World, reader: snapshot.Reader)
    local function applyOne(id: integer, ...: Component): boolean
        if id == nil then return false end
        world:spawnAt(id, ...)
        return true
    end
    world:defer()
    while applyOne(reader:readEntity()) do end
    world:commit()
end

-- Forward decls for internal Reader constructors.
local newBufferReaderImpl: function(any): snapshot.Reader
local newTableReaderImpl: function(SnapshotTable): snapshot.Reader
local attachWorld: function(snapshot.Reader, World)

-- Shared orchestration for both `loadSnapshot` (binary) and
-- `loadSnapshotTable` (in-memory). The reader abstraction is internal.
-- Returns the prelude so the public wrappers can hand it back to callers.
local function loadSnapshotImpl(world: World, reader: snapshot.Reader): SnapshotPrelude
    local worldImpl <const> = world as internal.WorldImpl
    local prelude = reader:readPrelude()
    assert(prelude, "reader:readPrelude returned nil")
    assert(prelude.version == SNAPSHOT_VERSION,
        "unsupported snapshot version: " .. tostring(prelude.version))

    clearWorld(world)

    -- Restore recreates entities with exactly their saved components. Suppress
    -- the active state's auto-tag during the load so restored entities are not
    -- ALSO tagged with the current top state; otherwise persistent (base-state)
    -- entities like the player/HUD would inherit e.g. gameState and be despawned
    -- on the next state transition. restoreStateStack below re-establishes the
    -- correct autoStateComponent from the saved state stack.
    local savedAutoState = worldImpl.autoStateComponent
    worldImpl.autoStateComponent = nil

    while true do
        local componentTypes, _columnIndices, entityCount, mode = reader:nextArchetype()
        if not componentTypes then break end

        if mode == 0 then
            loadColumnMajor(worldImpl, reader, componentTypes, entityCount)
        else
            loadRowMajor(world, reader)
        end
        -- batchSpawnAt's callback (which actually consumes the column
        -- data from the buffer) runs at commit time, so we MUST commit
        -- after each archetype. Otherwise the next nextArchetype call
        -- decodes still-unread column bytes as bogus header values.
        world:commit()
    end

    worldImpl.autoStateComponent = savedAutoState
    -- Bump the fresh-slot watermark past the highest restored slot so new
    -- spawns don't collide with loaded ids. batchSpawnAt already advances
    -- nextFreshSlot on a per-entity basis; this is a belt-and-braces cap
    -- for the snapshot-wide maximum recorded in the prelude.
    local allocator = worldImpl.allocator
    if prelude.nextEntityId > allocator.nextFreshSlot then
        allocator.nextFreshSlot = prelude.nextEntityId
    end
    -- Rebuild the free stack: slots that were dead at save time sit below
    -- the watermark but in no archetype. Without this sweep they are
    -- stranded and fresh spawns exhaust the id space early.
    IdAllocator.rebuildFreeStack(allocator)

    do
        local rebuildKeyIndex = (world as {string:any})._rebuildKeyIndex as function(any)
        if rebuildKeyIndex then
            rebuildKeyIndex(world)
        end
    end

    -- Data section: emit `StartSnapshotLoad` first so listeners can
    -- register per-key callbacks via `ev:onData(key, cb)`. Then read each
    -- (key, value) pair and dispatch to the registered handlers. Finally
    -- fire `FinishSnapshotLoad` once the data section is exhausted.
    local handlers: {string: {function(any)}} = {}
    local startEvent = builtins.StartSnapshotLoad()
    local startEventAny = startEvent as {string: any}
    startEventAny.onData = function(_self: any, key: string, cb: function(any))
        local arr = handlers[key]
        if not arr then
            arr = {}
            handlers[key] = arr
        end
        arr[#arr + 1] = cb
    end
    world:emit(0, startEvent as types.events.Event)

    while true do
        local key, value = reader:nextData()
        if key == nil then break end
        if key == STATE_STACK_DATA_KEY then
            restoreStateStack(world, value as {string})
            goto continue_data
        end
        if key == PIPELINE_DATA_KEY then
            restorePipelineState(world, value as {string:any})
            goto continue_data
        end
        local arr = handlers[key]
        if arr then
            for i = 1, #arr do
                arr[i](value)
            end
        end
        ::continue_data::
    end
    reader:readEnd()

    local finishEvent = builtins.FinishSnapshotLoad()
    local finishEventAny = finishEvent as {string: any}
    finishEventAny.prelude = prelude
    world:emit(0, finishEvent as types.events.Event)
    return prelude as SnapshotPrelude
end

function snapshot.loadSnapshot(world: World, source: any): SnapshotPrelude
    assert(source, "loadSnapshot requires a source (snapshot table, string, or string.buffer)")

    if type(source) == "table" then
        local srcAny = source as {string: any}
        if srcAny.format == "table" and srcAny.snapshot ~= nil then
            source = srcAny.snapshot
        elseif srcAny.format == "binary" and srcAny.buffer ~= nil then
            source = srcAny.buffer
        end
    end

    if type(source) == "table" then
        return snapshot.loadSnapshotTable(world, source as SnapshotTable)
    end

    -- Accept a Lua string for ergonomic Love2D-style usage:
    --   world:loadSnapshot(love.filesystem.read("save.bin"))
    -- The string is copied once into a fresh internal buffer.
    local buf: any
    if type(source) == "string" then
        buf = StringBuffer.new()
        local bufFns = buf as {string: function}
        bufFns.put(buf, source as any)
    else
        buf = source
    end

    local reader = newBufferReaderImpl(buf)
    attachWorld(reader, world)
    return loadSnapshotImpl(world, reader)
end

-------------------------------------------------------------------------------
-- Shared helpers for entry build / expand
-------------------------------------------------------------------------------

-- Build a positional entry `{id, data_1, data_2, ..., data_N}` where each
-- `data_i` comes from the i-th component's `serialize` callback. Callers
-- guarantee the component order matches the archetype header's
-- `columnIndices`, so the reader can deserialize by position.
local function buildEntry(id: integer, comps: {Component}, count: integer, cols: {Component}): {any}
    local entry: {any} = {}
    entry[1] = id
    for i = 1, count do
        local inst = comps[i]
        if inst == nil then
            entry[i + 1] = nil
        else
            -- Serialize through the column component: scalar columns
            -- hold raw values with no componentType of their own.
            local ct = cols[i]
            if ct and ct.serialize then
                local serialize = ct.serialize as function(any): any
                entry[i + 1] = serialize(inst)
            else
                entry[i + 1] = nil
            end
        end
    end
    return entry
end

local function buildByName(): {string: Component}
    local byName: {string: Component} = {}
    for _, comp in pairs(components.componentsById as {integer: Component}) do
        byName[comp.componentName] = comp
    end
    return byName
end

-- Resolve a saved "<container>-><target>" instance-column name by
-- constructing the per-target relationship instance from its registered
-- container. Covers instances that were never constructed in this
-- process (fresh load) and FFI instances, which are not registered.
local function resolveInstanceByName(byName: {string: Component}, name: string): Component
    local base, targetStr = name:match("^(.-)%->([%d%.]+)$")
    if not base then return nil end
    local container = byName[base]
    if not container then return nil end
    local target = tonumber(targetStr)
    if not target then return nil end
    return (container as function(number): Component)(target)
end

-- Deserialize a positional entry `{id, data_1, ..., data_N}` back into
-- (id, component_1, ..., component_N) using a pre-resolved componentTypes
-- array. Returns gaps as `nil` so positions remain aligned for the caller.
local function expandEntry(entry: {any}, componentTypes: {Component}, comps: {Component}, world: World): integer, integer
    local rawId = entry[1]
    local id: integer
    local ty = type(rawId)
    if ty == "number" then
        id = rawId as integer
    elseif ty == "string" then
        id = tonumber(rawId as string) as integer
    end
    if not id then return nil, 0 end

    local width = #componentTypes
    for i = 1, width do
        local ct = componentTypes[i]
        local data = entry[i + 1]
        if ct and data ~= nil and ct.deserialize then
            comps[i] = ct.deserialize(world, data as {string: any})
        else
            comps[i] = nil
        end
    end
    return id, width
end

-- Weak map from built-in reader -> function that stamps the World reference
-- onto it. Used by `loadSnapshotTable` so deserialize() gets a world.
local worldAttachers: {snapshot.Reader: function(snapshot.Reader, World)} = setmetatable(
    {} as {snapshot.Reader: function(snapshot.Reader, World)},
    {__mode = "k"} as metatable<{snapshot.Reader: function(snapshot.Reader, World)}>
)

attachWorld = function(reader: snapshot.Reader, world: World)
    local fn = worldAttachers[reader]
    if fn then fn(reader, world) end
end

-------------------------------------------------------------------------------
-- Built-in table writer / reader
-------------------------------------------------------------------------------

-- TableWriter: builds an in-memory `Snapshot` table. JSON-friendly format
-- mirrors the binary layout but stores per-entity rows (since JSON has no
-- compact column representation). Sparse and column-major archetypes both
-- produce the same row-shaped `entities[i] = {id, c1Data, c2Data, ...}`.
local record TableWriterImpl is snapshot.Writer
    _snap: SnapshotTable
    _currentArch: snapshot.ArchetypeEntry
    _columnBuffers: {{any}}           -- one array per column, filled by writeColumnValue
    _columnCounts: {integer}          -- per-column write cursor; keeps nil serializations aligned
end

local TABLE_WRITER_MT <const>: metatable<TableWriterImpl> = {__index = TableWriterImpl}

function TableWriterImpl:writePrelude(
    version: integer,
    nextEntityId: integer,
    _entityCount: integer,
    _archetypeCount: integer,
    componentTable: {snapshot.ComponentTableEntry})
    -- The table/JSON format doesn't use the FFI fingerprint: loads always
    -- go through per-component `deserialize` (keyed by field name), so
    -- schema drift is handled intrinsically. Strip fingerprints from the
    -- emitted componentTable to keep JSON output clean and portable.
    local strippedTable: {types.World.SnapshotComponentTableEntry} = {}
    for i = 1, #componentTable do
        strippedTable[i] = {name = componentTable[i].name}
    end
    self._snap = {
        version = version,
        nextEntityId = nextEntityId,
        componentTable = strippedTable,
        archetypes = {},
        data = {},
    }
end

function TableWriterImpl:startArchetype(
    _columnCount: integer,
    _entityCount: integer,
    columnIndices: {integer},
    _mode: integer)
    local entry: snapshot.ArchetypeEntry = {
        columnIndices = columnIndices,
        entities = {},
    }
    self._currentArch = entry
    self._columnBuffers = {}
    self._columnCounts = {}
    for i = 1, #columnIndices do
        self._columnBuffers[i] = {}
        self._columnCounts[i] = 0
    end
    local archs = self._snap.archetypes as {snapshot.ArchetypeEntry}
    archs[#archs + 1] = entry
end

function TableWriterImpl:writeIds(idsArray: any, count: integer)
    -- TableWriter stores ids inline in entity rows (built at endArchetype).
    -- Stash them on a side buffer for now.
    local ids: {integer} = {}
    -- idsArray could be FFI double* or a Lua array. Detect via type.
    if type(idsArray) == "cdata" then
        for k = 0, count - 1 do
            ids[k + 1] = (idsArray as {integer: integer})[k]
        end
    else
        local arr = idsArray as {integer}
        table_move(arr, 1, count, 1, ids)
    end
    (self._currentArch as {string: any})._pendingIds = ids
end

-- Note: TableWriter intentionally does NOT implement writeColumnRaw.
-- saveSnapshot's capability check (`writer.writeColumnRaw ~= nil`) sees
-- the missing method and routes FFI columns through writeColumnValue
-- (per-entity comp.serialize) instead.

function TableWriterImpl:writeColumnValue(colIdx: integer, value: Component, comp: Component)
    -- saveSnapshot calls this once per (column, entity). Write at an
    -- explicit per-column index so a serialize hook returning nil leaves
    -- an aligned hole instead of shifting every later entity's value.
    local k = self._columnCounts[colIdx] + 1
    self._columnCounts[colIdx] = k
    if comp.serialize then
        self._columnBuffers[colIdx][k] = comp.serialize(value)
    end
end

function TableWriterImpl:writeEntity(id: integer, comps: {Component}, count: integer, cols: {Component})
    -- Row-major path (sparse archetypes). One entity at a time, variable count.
    local entry = buildEntry(id, comps, count, cols)
    local entities = self._currentArch.entities as {{any}}
    entities[#entities + 1] = entry
end

function TableWriterImpl:endArchetype()
    -- Transpose column buffers into entity rows for column-major archetypes.
    -- Row-major archetypes already populated `entities` directly via writeEntity.
    local arch = self._currentArch as {string: any}
    local pendingIds = arch._pendingIds as {integer}
    if pendingIds then
        local entities = self._currentArch.entities as {{any}}
        local nCols = #self._columnBuffers
        for k = 1, #pendingIds do
            local row: {any} = {pendingIds[k]}
            for c = 1, nCols do
                row[c + 1] = self._columnBuffers[c][k]
            end
            entities[#entities + 1] = row
        end
    end
    -- Strip the scratch field; it's an internal side-buffer for the
    -- column-major → row-major transpose and must not leak into the
    -- final snapshot (otherwise it shows up in JSON exports and gets
    -- round-tripped back on load).
    arch._pendingIds = nil
    self._currentArch = nil
    self._columnBuffers = nil
end

function TableWriterImpl:writeData(key: string, value: any)
    local data = self._snap.data as {snapshot.DataEntry}
    data[#data + 1] = {key = key, value = value}
end

function TableWriterImpl:writeDataEnd() end

function TableWriterImpl:writeEnd() end

function newTableWriterImpl(): snapshot.Writer, function(): SnapshotTable
    local impl: TableWriterImpl = setmetatable({} as TableWriterImpl, TABLE_WRITER_MT)
    local function get(): SnapshotTable return impl._snap as SnapshotTable end
    return impl as snapshot.Writer, get
end

-- TableReader: walks an in-memory `Snapshot`. Always reports mode=1 (row
-- shape) regardless of how the writer ingested the data -- the table format
-- normalises everything to per-entity rows in `entities[i] = {id, c1, c2, ...}`.
local record TableReaderImpl is snapshot.Reader
    _snap: SnapshotTable
    _archCursor: integer
    _entityCursor: integer
    _dataCursor: integer
    _byName: {string: Component}
    _world: World
    _currentTypes: {Component}     -- resolved once per archetype
    _compsScratch: {Component}     -- reused across readEntity calls
end

local TABLE_READER_MT <const>: metatable<TableReaderImpl> = {__index = TableReaderImpl}

function TableReaderImpl:readPrelude(): snapshot.Prelude
    local snap = self._snap
    local archs = snap.archetypes as {snapshot.ArchetypeEntry}
    local total = 0
    for i = 1, #archs do
        total = total + #(archs[i].entities as {any})
    end
    return {
        version = snap.version,
        nextEntityId = snap.nextEntityId,
        entityCount = total,
        archetypeCount = #archs,
        componentTable = snap.componentTable as {snapshot.ComponentTableEntry},
    }
end

function TableReaderImpl:nextArchetype(): {Component}, {integer}, integer, integer
    local archs = self._snap.archetypes as {snapshot.ArchetypeEntry}
    local idx = self._archCursor + 1
    if idx > #archs then return nil, nil, 0, 0 end
    self._archCursor = idx
    self._entityCursor = 0
    local entry = archs[idx]
    local ents = entry.entities as {any}

    -- Resolve component types via the snapshot's componentTable.
    if not self._byName then self._byName = buildByName() end
    local componentTable = self._snap.componentTable
    local columnIndices = entry.columnIndices
    local compTypes: {Component} = {}
    for i = 1, #columnIndices do
        local nameEntry = componentTable[columnIndices[i]]
        local comp = self._byName[nameEntry.name]
        if not comp then
            comp = resolveInstanceByName(self._byName, nameEntry.name)
        end
        compTypes[i] = comp
    end
    self._currentTypes = compTypes
    -- Always row-shape (mode=1); table storage doesn't keep mode info.
    return compTypes, columnIndices, #ents, 1
end

function TableReaderImpl:readIds(_count: integer): any
    error("TableReader: readIds not used (table reader always reports row mode)")
end

function TableReaderImpl:readColumnRawInto(_destBase: any, _byteOffset: integer, _byteCount: integer)
    error("TableReader: readColumnRawInto not used (table reader always reports row mode)")
end

function TableReaderImpl:readColumnValue(_colIdx: integer, _world: World): Component
    error("TableReader: readColumnValue not used (table reader always reports row mode)")
end

function TableReaderImpl:schemaMatchesForColumn(_colIdx: integer): boolean
    -- Table format round-trips through per-component serialize/deserialize,
    -- which already handles field drift; the column-major / bulk path that
    -- this predicate guards doesn't apply here.
    return true
end

function TableReaderImpl:readEntity(): integer, Component...
    local archs = self._snap.archetypes as {snapshot.ArchetypeEntry}
    local archIdx = self._archCursor
    if archIdx == 0 or archIdx > #archs then return nil end
    local entities = archs[archIdx].entities as {{any}}
    local idx = self._entityCursor + 1
    if idx > #entities then return nil end
    self._entityCursor = idx
    local entry = entities[idx]

    local comps = self._compsScratch
    if not comps then
        comps = {}
        self._compsScratch = comps
    end
    local id, width = expandEntry(entry, self._currentTypes, comps, self._world)
    if not id then return nil end
    local packed = 0
    for i = 1, width do
        local comp = comps[i]
        if comp ~= nil then
            packed = packed + 1
            comps[packed] = comp
        end
    end
    for i = packed + 1, width do
        comps[i] = nil
    end
    return id, (table.unpack as function({Component}, integer, integer): Component...)(comps, 1, packed)
end

function TableReaderImpl:nextData(): string, any
    local data = self._snap.data as {snapshot.DataEntry}
    if not data then return nil, nil end
    local idx = (self._dataCursor or 0) + 1
    if idx > #data then return nil, nil end
    self._dataCursor = idx
    local entry = data[idx]
    return entry.key, entry.value
end

function TableReaderImpl:readEnd() end

function newTableReaderImpl(snap: SnapshotTable): snapshot.Reader
    assert(snap, "newTableReader requires a snapshot")
    local impl: TableReaderImpl = setmetatable({
        _snap = snap,
        _archCursor = 0,
        _entityCursor = 0,
    } as TableReaderImpl, TABLE_READER_MT)
    worldAttachers[impl as snapshot.Reader] = function(r: snapshot.Reader, w: World)
        (r as TableReaderImpl)._world = w
    end
    return impl as snapshot.Reader
end

-------------------------------------------------------------------------------
-- Built-in LuaJIT string.buffer writer / reader
-------------------------------------------------------------------------------

-- Buffer-format framing (column-major fast path with bulk FFI memcpy):
--
--   prelude:
--     encode(version)
--     encode(nextEntityId)
--     encode(entityCount)
--     encode(archetypeCount)
--     encode(componentCount)
--     per i: encode(name); encode(fingerprint)
--     encode(customCount)
--     per j: encode(custom[j])
--
--   per archetype:
--     encode(columnCount)
--     encode(entityCount)
--     per c: encode(columnIndex)         -- 1-based into prelude.componentTable
--     encode(mode)                        -- 0 = column-major, 1 = row-major (sparse)
--
--     mode == 0 (column-major):
--       putcdata(idsArray, count * 8)    -- bulk write entity IDs as double
--       per column c:
--         (FFI dense column) putcdata(column, structSize * count)
--         OR (non-FFI / per-entity) per k: encode(comp.serialize(column[k]))
--
--     mode == 1 (row-major, sparse):
--       per entity:
--         encode(id)
--         per component j: serializeRaw(value, buf) | encode(serialize(value)) | encode(nil placeholder)

local record BufferWriterImpl is snapshot.Writer
    _buf: any
end

local BUFFER_WRITER_MT <const>: metatable<BufferWriterImpl> = {__index = BufferWriterImpl}

function BufferWriterImpl:writePrelude(
    version: integer,
    nextEntityId: integer,
    entityCount: integer,
    archetypeCount: integer,
    componentTable: {snapshot.ComponentTableEntry})
    local buf = self._buf
    local encode <const> = (buf as {string: function}).encode as function(any, any)
    encode(buf, version as any)
    encode(buf, nextEntityId as any)
    encode(buf, entityCount as any)
    encode(buf, archetypeCount as any)
    local componentCount = #(componentTable as {any})
    encode(buf, componentCount as any)
    for i = 1, componentCount do
        local entry = componentTable[i]
        encode(buf, entry.name as any)
        encode(buf, entry.fingerprint as any)
    end
end

function BufferWriterImpl:startArchetype(
    columnCount: integer,
    entityCount: integer,
    columnIndices: {integer},
    mode: integer)
    local buf = self._buf
    local encode <const> = (buf as {string: function}).encode as function(any, any)
    encode(buf, columnCount as any)
    encode(buf, entityCount as any)
    for i = 1, columnCount do
        encode(buf, columnIndices[i] as any)
    end
    encode(buf, mode as any)
end

function BufferWriterImpl:writeIds(idsArray: any, count: integer)
    -- Bulk-write the entity ID array as raw double bytes. idsArray is
    -- expected to be an FFI double* (or compatible) and contiguous.
    local put <const> = (self._buf as {string: function}).putcdata as function(any, any, integer)
    put(self._buf, idsArray, count * 8)
end

function BufferWriterImpl:writeColumnRaw(_colIdx: integer, srcPtr: any, byteCount: integer)
    -- Bulk-memcpy a whole FFI column directly into the buffer. Zero
    -- per-entity work, no allocations.
    local put <const> = (self._buf as {string: function}).putcdata as function(any, any, integer)
    put(self._buf, srcPtr, byteCount)
end

function BufferWriterImpl:writeColumnValue(_colIdx: integer, value: Component, comp: Component)
    -- Per-entity encode (non-FFI components, or layer-filtered FFI).
    local buf = self._buf
    local compI = comp as ComponentInternal
    if compI.serializeRaw then
        compI.serializeRaw(value, buf)
    elseif comp.serialize then
        BUF_ENCODE(buf, comp.serialize(value) as any)
    else
        BUF_ENCODE(buf, nil as any)
    end
end

function BufferWriterImpl:writeEntity(id: integer, comps: {Component}, count: integer, cols: {Component})
    -- Row-major fallback (sparse archetypes). Emit a per-row presence
    -- bitmask (bit i-1 = column i present), then only the present values
    -- in archetype-column order. One number instead of a boolean table:
    -- no per-entity allocation on either side.
    if count > ROW_MASK_MAX_COLUMNS then
        error("snapshot: row-major archetype exceeds " .. ROW_MASK_MAX_COLUMNS .. " columns")
    end
    local buf = self._buf
    local encode <const> = BUF_ENCODE
    encode(buf, id as any)
    local mask: number = 0
    for i = 1, count do
        if comps[i] ~= nil then
            mask = mask + POW2[i]
        end
    end
    encode(buf, mask as any)
    for i = 1, count do
        local inst = comps[i]
        if inst ~= nil then
            -- Serialize through the column component (readers resolve
            -- deserializers from the component table the same way);
            -- scalar columns hold raw values with no componentType.
            local ct = cols[i] as ComponentInternal
            if ct.serializeRaw then
                ct.serializeRaw(inst, buf)
            elseif ct.serialize then
                encode(buf, ct.serialize(inst as ComponentInternal) as any)
            else
                encode(buf, nil as any)
            end
        end
    end
end

function BufferWriterImpl:endArchetype() end

function BufferWriterImpl:writeData(key: string, value: any)
    -- Sentinel-prefixed pair: `true` marks "another entry follows",
    -- `false` (written by writeDataEnd) closes the section.
    local buf = self._buf
    local encode <const> = (buf as {string: function}).encode as function(any, any)
    encode(buf, true as any)
    encode(buf, key as any)
    encode(buf, value)
end

function BufferWriterImpl:writeDataEnd()
    local buf = self._buf
    local encode <const> = (buf as {string: function}).encode as function(any, any)
    encode(buf, false as any)
end

function BufferWriterImpl:writeEnd() end

function newBufferWriterImpl(buf: any): snapshot.Writer
    assert(buf, "newBufferWriter requires a LuaJIT string.buffer")
    local impl: BufferWriterImpl = setmetatable({
        _buf = buf,
    } as BufferWriterImpl, BUFFER_WRITER_MT)
    return impl as snapshot.Writer
end

-- Resolved entry per component-table position. Built once when readPrelude
-- decodes the table; lookups are then O(1) per archetype frame.
local record ResolvedComponent
    comp: Component       -- nil if unknown to the loading world
    schemaMatch: boolean  -- whether saved fingerprint matches current
    savedFingerprint: string
    -- Per-entity decoder closure used whenever the bulk memcpy path is
    -- unsafe (schema drift). Nil for matching schemas + non-FFI paths.
    migrate: function(any): any
end

local record BufferReaderImpl is snapshot.Reader
    _buf: any
    _byName: {string: Component}
    _world: World
    _resolvedTable: {ResolvedComponent}  -- index → resolved entry
    _currentTypes: {Component}           -- archetype-local component types in column order
    _currentIndices: {integer}           -- archetype-local column indices (for slow-path lookup)
    _currentMode: integer
    _archRemaining: integer              -- entities left to read in row-major mode
    _archetypesRemaining: integer        -- archetype frames still to consume in the buffer
    _compsScratch: {Component}
end

local BUFFER_READER_MT <const>: metatable<BufferReaderImpl> = {__index = BufferReaderImpl}

local function bufEmpty(buf: any): boolean
    return (#(buf as {any})) == 0
end

function BufferReaderImpl:readPrelude(): snapshot.Prelude
    local buf = self._buf
    local decode <const> = (buf as {string: function}).decode as function(any): any
    local version = decode(buf) as integer
    local nextEntityId = decode(buf) as integer
    local entityCount = decode(buf) as integer
    local archetypeCount = decode(buf) as integer

    -- Decode component table and resolve each entry against the loading
    -- world's registered components. The fingerprint check decides per
    -- column whether load can use the bulk fast path or must drop to
    -- per-entity translation.
    local componentCount = decode(buf) as integer
    if not self._byName then self._byName = buildByName() end
    local componentTable: {snapshot.ComponentTableEntry} = {}
    local resolved: {ResolvedComponent} = {}
    for i = 1, componentCount do
        local name = decode(buf) as string
        local fingerprint = decode(buf) as string
        componentTable[i] = {name = name, fingerprint = fingerprint}
        local comp = self._byName[name]
        if not comp then
            comp = resolveInstanceByName(self._byName, name)
        end
        -- Binary frames have no per-column skip markers, so an unknown
        -- component makes the rest of the stream unreadable. Fail here,
        -- before the loader clears the world.
        if not comp then
            error("loadSnapshot: snapshot references component '" .. name ..
                "' which is not registered in this world; register it before loading", 0)
        end
        local currentSchema = (comp as {string: any}).fingerprint as string or ""
        local match = (fingerprint == currentSchema)
        local migrate: function(any): any = nil
        if not match and fingerprint ~= "" then
            if (comp as ComponentInternal).deserializeRaw then
                -- Default-hook FFI component: the saved column holds raw
                -- struct bytes in the old layout. Build a per-entity
                -- migrator so the load path projects them field by field.
                migrate = buildMigrator(comp, fingerprint)
            elseif currentSchema == "" then
                error("loadSnapshot: component '" .. name ..
                    "' was saved as an FFI struct but is now registered without one; cannot migrate", 0)
            end
            -- Custom-hook components save structured payloads; their own
            -- deserialize receives the old payload directly, which is the
            -- manual-migration path.
        end
        resolved[i] = {
            comp = comp,
            schemaMatch = match,
            savedFingerprint = fingerprint,
            migrate = migrate,
        }
    end
    self._resolvedTable = resolved
    self._archetypesRemaining = archetypeCount

    return {
        version = version,
        nextEntityId = nextEntityId,
        entityCount = entityCount,
        archetypeCount = archetypeCount,
        componentTable = componentTable,
    }
end

function BufferReaderImpl:nextArchetype(): {Component}, {integer}, integer, integer
    if self._archetypesRemaining <= 0 then return nil, nil, 0, 0 end
    self._archetypesRemaining = self._archetypesRemaining - 1
    if bufEmpty(self._buf) then return nil, nil, 0, 0 end
    local buf = self._buf
    local decode <const> = (buf as {string: function}).decode as function(any): any
    local columnCount = decode(buf) as integer
    if columnCount == nil then return nil, nil, 0, 0 end
    local entityCount = decode(buf) as integer
    local indices: {integer} = {}
    local compTypes: {Component} = {}
    for i = 1, columnCount do
        local idx = decode(buf) as integer
        indices[i] = idx
        compTypes[i] = self._resolvedTable[idx].comp
    end
    local mode = decode(buf) as integer
    self._currentTypes = compTypes
    self._currentIndices = indices
    self._currentMode = mode
    self._archRemaining = entityCount
    return compTypes, indices, entityCount, mode
end

function BufferReaderImpl:readIds(count: integer): any
    -- Bulk-read double * count from buffer into a fresh FFI array.
    local buf = self._buf
    local ref <const> = (buf as {string: function}).ref as function(any): any
    local skip <const> = (buf as {string: function}).skip as function(any, integer)
    local bytes = count * 8
    local ids = ffiNew(doubleArrayType, count)
    ffiCopy(ids, ref(buf), bytes)
    skip(buf, bytes)
    return ids
end

function BufferReaderImpl:readColumnRawInto(destBase: any, byteOffset: integer, byteCount: integer)
    -- Bulk-memcpy raw bytes from buffer directly into `destBase + byteOffset`.
    -- This is the FFI fast path: zero allocations, single memcpy per column.
    local buf = self._buf
    local ref <const> = (buf as {string: function}).ref as function(any): any
    local skip <const> = (buf as {string: function}).skip as function(any, integer)
    ffiCopy(ffiOffsetCharPtr(destBase, byteOffset), ref(buf), byteCount)
    skip(buf, byteCount)
end

function BufferReaderImpl:schemaMatchesForColumn(colIdx: integer): boolean
    local compIdx = self._currentIndices[colIdx]
    return self._resolvedTable[compIdx].schemaMatch
end

-- Per-entity decode helper shared by column-major and row-major paths.
-- Routes through the migrator when the saved schema doesn't match the
-- current registration; otherwise falls back to the component's raw or
-- structured codec.
function BufferReaderImpl:_decodeOne(colIdx: integer, world: World): Component
    local buf = self._buf
    local compIdx = self._currentIndices[colIdx]
    local resolved = self._resolvedTable[compIdx]
    local ct = resolved.comp
    if resolved.migrate then
        return resolved.migrate(buf) as Component
    end
    local ctI = ct as ComponentInternal
    if ct and ctI.deserializeRaw then
        return ctI.deserializeRaw(buf)
    elseif ct and ct.deserialize then
        local payload = BUF_DECODE(buf) as {string: any}
        -- Serialize was allowed to return nil for components that can't
        -- round-trip (synthetic paths, transient runtime state). The
        -- encoded stream carries nil in that slot; skip deserialize
        -- rather than passing nil through and risking crashes inside
        -- user code that assumes data is a table.
        if payload == nil then return nil end
        return ct.deserialize(world, payload)
    else
        BUF_DECODE(buf)
        return nil
    end
end

function BufferReaderImpl:readColumnValue(colIdx: integer, world: World): Component
    return self:_decodeOne(colIdx, world)
end

function BufferReaderImpl:readEntity(): integer, Component...
    if self._archRemaining <= 0 then return nil end
    self._archRemaining = self._archRemaining - 1
    local buf = self._buf
    local decode <const> = BUF_DECODE
    local id = decode(buf) as integer
    local mask = decode(buf) as number
    local compTypes = self._currentTypes
    local width = #compTypes
    local comps = self._compsScratch
    if not comps then comps = {}; self._compsScratch = comps end
    for i = 1, width do
        local p = POW2[i]
        if mask % (p + p) >= p then
            comps[i] = self:_decodeOne(i, self._world)
        else
            comps[i] = nil
        end
    end
    local packed = 0
    for i = 1, width do
        local comp = comps[i]
        if comp ~= nil then
            packed = packed + 1
            comps[packed] = comp
        end
    end
    for i = packed + 1, width do
        comps[i] = nil
    end
    return id, (table.unpack as function({Component}, integer, integer): Component...)(comps, 1, packed)
end

function BufferReaderImpl:nextData(): string, any
    local buf = self._buf
    local decode <const> = (buf as {string: function}).decode as function(any): any
    local more = decode(buf) as boolean
    if not more then return nil, nil end
    local key = decode(buf) as string
    local value = decode(buf)
    return key, value
end

function BufferReaderImpl:readEnd() end

function newBufferReaderImpl(buf: any): snapshot.Reader
    assert(buf, "newBufferReader requires a LuaJIT string.buffer")
    local impl: BufferReaderImpl = setmetatable({
        _buf = buf,
        _archRemaining = 0,
        _archetypesRemaining = 0,
    } as BufferReaderImpl, BUFFER_READER_MT)
    worldAttachers[impl as snapshot.Reader] = function(r: snapshot.Reader, w: World)
        (r as BufferReaderImpl)._world = w
    end
    return impl as snapshot.Reader
end

-------------------------------------------------------------------------------
-- Public table-format API
-------------------------------------------------------------------------------

function snapshot.saveSnapshotTable(world: World, opts: SnapshotOptions): SnapshotTable
    local writer, get = newTableWriterImpl()
    saveSnapshotImpl(world, writer, opts or {} as SnapshotOptions)
    return get()
end

function snapshot.loadSnapshotTable(world: World, snap: SnapshotTable): SnapshotPrelude
    local reader = newTableReaderImpl(snap)
    attachWorld(reader, world)
    return loadSnapshotImpl(world, reader)
end

return snapshot
