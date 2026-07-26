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
local tecsInternal <const> = require("tecs.internal.types")
local fixedtracking <const> = require("tecs.internal.fixedtracking")
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
        flushFixed: function(
            self,
            component: tecs.Component,
            step: integer
        )
        flushCurrent: function(self, component: tecs.Component)

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
    local cap = (archetype as tecsInternal.ArchetypeInternal).capacity
    if cap < 1 then cap = 1 end
    return cap
end

function archetype_shadow_set.new(
    archetype: tecs.Archetype,
    specs: {tecs.Component: LayoutDescriptor}
): archetype_shadow_set.ShadowSet
    local entries: {archetype_shadow_set.Entry} = {}
    local columns = (archetype as tecsInternal.ArchetypeInternal).columns
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

local function prepareEntry(
    archetype: tecs.Archetype,
    e: archetype_shadow_set.Entry
): C.CData, integer, boolean
    local archInternal = archetype as tecsInternal.ArchetypeInternal
    local canonicalPtr = archInternal.columns[e.component] as C.CData
    local drifted = false
    if canonicalPtr ~= e.cachedCanonical
            or archInternal.capacity > e.buffer.capacity then
        local newCap = archInternal.capacity
        if newCap < 1 then newCap = 1 end
        if newCap > e.buffer.capacity then
            e.buffer:grow(newCap)
        end
        e.cachedCanonical = canonicalPtr
        drifted = true
    end
    return canonicalPtr, archInternal.entities[0], drifted
end

local function uploadEntry(
    e: archetype_shadow_set.Entry,
    canonicalPtr: C.CData,
    rowCount: integer,
    mutationVersion: integer,
    structureVersion: integer
)
    local holder =
        (FFIStorage.getColumnByteData as function(any): any)(canonicalPtr)
    if holder ~= nil and e.layout.identity then
        e.buffer:uploadByteData(
            holder as love.data.ByteData,
            rowCount,
            mutationVersion,
            structureVersion
        )
    else
        e.buffer:flushRange(
            canonicalPtr,
            rowCount,
            mutationVersion,
            structureVersion
        )
    end
end

function ShadowSet:flushFixed(component: tecs.Component, step: integer)
    local archetype = self.archetype
    local mutationVersion = fixedtracking.version(archetype, component)
    local structureVersion = fixedtracking.structureVersion(archetype)

    for i = 1, #self.entries do
        local e = self.entries[i]
        if e.component == component then
            local canonicalPtr, rowCount = prepareEntry(archetype, e)
            if rowCount <= 0 then return end
            local holder =
                (FFIStorage.getColumnByteData as function(any): any)(
                    canonicalPtr
                )
            if holder ~= nil and e.layout.identity then
                e.buffer:uploadFixedByteData(
                    holder as love.data.ByteData,
                    rowCount,
                    mutationVersion,
                    structureVersion,
                    step
                )
            else
                e.buffer:flushFixedRange(
                    canonicalPtr,
                    rowCount,
                    mutationVersion,
                    structureVersion,
                    step
                )
            end
            return
        end
    end
end

function ShadowSet:flushCurrent(component: tecs.Component)
    local archetype = self.archetype
    local mutationVersion = fixedtracking.version(archetype, component)
    local structureVersion = fixedtracking.structureVersion(archetype)

    for i = 1, #self.entries do
        local e = self.entries[i]
        if e.component == component then
            local canonicalPtr, rowCount, drifted =
                prepareEntry(archetype, e)
            if rowCount <= 0 then return end
            if not drifted and e.buffer.hasUploaded
                    and e.buffer.uploadedMutationVersion == mutationVersion
                    and e.buffer.uploadedStructureVersion
                        == structureVersion then
                return
            end
            uploadEntry(
                e,
                canonicalPtr,
                rowCount,
                mutationVersion,
                structureVersion
            )
            return
        end
    end
end

function ShadowSet:flush()
    local archetype = self.archetype
    local archInternal = archetype as tecsInternal.ArchetypeInternal
    local rowCount = archInternal.entities[0]

    if rowCount == 0 then return end

    for i = 1, #self.entries do
        local e = self.entries[i]
        local canonicalPtr, _, drifted = prepareEntry(archetype, e)
        local mutationVersion = fixedtracking.version(archetype, e.component)
        local structureVersion = fixedtracking.structureVersion(archetype)

        -- Per-component dirty gate: skip the upload entirely when the
        -- component's column hasn't changed this frame. Pointer drift
        -- forces an upload to repopulate the new GPU buffer.
        if drifted or archetype:isComponentDirty(e.component) then
            -- A fixed-step upload may already have consumed the same
            -- mutation version. Dirty bits live for the whole outer frame,
            -- so suppress that otherwise-redundant PreRender upload.
            if not drifted and mutationVersion >= 0
                    and e.buffer.hasUploaded
                    and e.buffer.uploadedMutationVersion == mutationVersion
                    and e.buffer.uploadedStructureVersion == structureVersion then
                goto continue
            end
            uploadEntry(
                e,
                canonicalPtr,
                rowCount,
                mutationVersion,
                structureVersion
            )
        end

        ::continue::
    end
end

return archetype_shadow_set
