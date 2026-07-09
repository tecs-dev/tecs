--- A collection of `shadowbuffer` instances attached to one archetype,
--- each backing one of the archetype's component columns. Encapsulates:
---
--- - Pointer-drift detection at flush time. If the archetype's column
---   storage was reallocated by `Archetype:reserveCapacity`, the cached
---   canonical pointer differs from `archetype.columns[component]`. The
---   shadow buffer is grown to match `archetype.capacity`, the new pointer
---   becomes the cache, and an unconditional `flushRange` re-uploads
---   the live rows into the freshly-allocated GPU buffer.
--- - Per-component dirty gating: each entry consults
---   `archetype:isComponentDirty(component)` and uploads only when
---   that component's column actually changed since the last frame.
--- - One generic `flush()` entry point for shape-specific render state
---   to call.
---
--- The shadow set is component-agnostic. Per-shape state objects compose
--- a shadow set for the components they care about plus any shape-specific
--- render columns (e.g., circle material params).

local C <const> = require("ffi")
local tecs <const> = require("tecs")
local shadowbuffer <const> = require("tecs2d.gfx.internal.gpu.shadowbuffer")
local std430 <const> = require("tecs2d.gfx.internal.gpu.std430")
local FFIStorage <const> = require("tecs.internal.ffi.FFIStorage") as {string:any}

local type LayoutDescriptor = std430.Descriptor
local type ShadowBuffer = shadowbuffer.ShadowBuffer

local record archetype_shadow_set
    record Entry
        component: tecs.Component
        layout: LayoutDescriptor
        buffer: ShadowBuffer
        cachedCanonical: C.CData
    end

    record ShadowSet
        archetype: tecs.Archetype
        entries: {Entry}

        --- Iterate (component, ShadowBuffer) for every entry. Useful
        --- for the per-shape cull dispatch which binds each as an SSBO.
        forEach: function(self, fn: function(tecs.Component, ShadowBuffer))

        --- Run pointer-drift detection per entry; for each entry,
        --- upload via `flushRange` whenever the entry's component is
        --- marked dirty on the archetype (or pointer drift forced a
        --- buffer rebuild). Idempotent when no mutation occurred --
        --- world's end-of-update clear leaves every component bit at
        --- 0 until the next frame's writes.
        flush: function(self)

        --- Get the ShadowBuffer for a specific component, or nil if
        --- not in this set.
        get: function(self, component: tecs.Component): ShadowBuffer
    end

    --- Build a shadow set for an archetype.
    ---
    --- @param archetype The archetype to shadow.
    --- @param specs Map from component → layout descriptor. Components
    --- not present on the archetype are skipped silently (so callers
    --- can pass a "wishlist" without checking presence first).
    new: function(
        archetype: tecs.Archetype,
        specs: {tecs.Component: LayoutDescriptor}
    ): ShadowSet
end

local ShadowSet <const> = archetype_shadow_set.ShadowSet
local SHADOW_SET_MT <const>: metatable<ShadowSet> = {__index = ShadowSet}

-- Compute initial shadow capacity from the archetype's current column
-- storage. The FFI column has `INITIAL_CAPACITY` rows (see FFIStorage.tl)
-- even when archetype.capacity == 0; sizing the shadow buffer to match
-- the archetype's logical capacity (often 0 at archetype creation) would
-- produce a tiny shadow. Use `max(1, archetype.capacity)` as the floor;
-- the next reserveCapacity will trigger pointer drift detection and
-- grow the shadow buffer to whatever the underlying column reports.
local function initialCapacity(archetype: tecs.Archetype): integer
    local cap = (archetype as {string:any}).capacity as integer
    if cap < 1 then cap = 1 end
    return cap
end

function archetype_shadow_set.new(
    archetype: tecs.Archetype,
    specs: {tecs.Component: LayoutDescriptor}
): archetype_shadow_set.ShadowSet
    local entries: {archetype_shadow_set.Entry} = {}
    local archAny = archetype as {string:any}
    local columns = archAny.columns as {tecs.Component: any}
    local cap = initialCapacity(archetype)

    for comp, layout in pairs(specs) do
        local canonical = columns[comp]
        if canonical ~= nil then
            local buf = shadowbuffer.new(
                cap,
                layout.elementSize,
                layout.shadowCtype,
                layout.format,
                layout.translate
            )
            entries[#entries + 1] = {
                component = comp,
                layout = layout,
                buffer = buf,
                cachedCanonical = canonical as C.CData,
            }
        end
    end

    local self: archetype_shadow_set.ShadowSet = {
        archetype = archetype,
        entries = entries,
    }
    return setmetatable(self, SHADOW_SET_MT)
end

function ShadowSet:forEach(fn: function(tecs.Component, ShadowBuffer))
    for i = 1, #self.entries do
        local e = self.entries[i]
        fn(e.component, e.buffer)
    end
end

function ShadowSet:get(component: tecs.Component): ShadowBuffer
    for i = 1, #self.entries do
        local e = self.entries[i]
        if e.component == component then return e.buffer end
    end
    return nil
end

function ShadowSet:flush()
    local archetype = self.archetype
    local archAny = archetype as {string:any}
    local columns = archAny.columns as {tecs.Component: any}
    local archCap = archAny.capacity as integer
    local rowCount = (archAny.entities as {integer})[0] as integer

    if rowCount == 0 then return end

    for i = 1, #self.entries do
        local e = self.entries[i]
        local canonical = columns[e.component]

        -- Pointer drift detection: if the archetype's column was
        -- reallocated (reserveCapacity creates a new cdata array), the
        -- shadow buffer must grow to match. The freshly-allocated GPU
        -- buffer has uninitialized contents, so an unconditional
        -- flushRange follows regardless of the component-dirty bit.
        local drifted = false
        if canonical ~= e.cachedCanonical or archCap > e.buffer.capacity then
            local newCap = archCap
            if newCap < 1 then newCap = 1 end
            if newCap > e.buffer.capacity then
                e.buffer:grow(newCap)
            end
            e.cachedCanonical = canonical as C.CData
            drifted = true
        end

        -- Per-component dirty gate: skip the upload entirely when the
        -- component's column hasn't changed this frame. Pointer drift
        -- forces an upload to repopulate the new GPU buffer.
        if drifted or archetype:isComponentDirty(e.component) then
            local holder = (FFIStorage.getColumnByteData as function(any): any)(canonical)
            if holder ~= nil and e.layout.identity then
                -- Direct upload: the column's backing ByteData is already in
                -- std430 layout (identity), so skip the staging translate and
                -- push it straight to the SSBO.
                e.buffer.gpuBuffer:setArrayData(holder as love.data.ByteData, 2, 1, rowCount)
            else
                e.buffer:flushRange(canonical as C.CData, rowCount)
            end
        end
    end
end

return archetype_shadow_set
