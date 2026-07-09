--- Generic per-archetype state for the renderer-owned shadow-column
--- path. Replaces per-shape `archetype_state.tl` files that were
--- byte-for-byte identical except for the state record name.
---
--- One instance per archetype that contains the shape's required
--- components. Owns:
---
--- - An `archetypeshadowset` covering whatever components were passed
---   in via `specs`. Components not present on the archetype are
---   skipped silently; the cull shader reads them via `ComponentMask`.
--- - An archetype observer for the destruction signal. Dirty signalling
---   flows through the per-archetype per-component bitset, so no row
---   callbacks are defined; leaving them nil keeps the archetype's
---   per-row observer loops off entirely.
---
--- The state object IS the `ArchetypeEntityObserver` for its
--- archetype. Lifecycle is driven by `archetype_registry`.

local tecs <const> = require("tecs")
local archetypeshadowset <const> = require("tecs2d.gfx.internal.gpu.archetypeshadowset")
local std430 <const> = require("tecs2d.gfx.internal.gpu.std430")

local record shadow_state
    record ArchetypeState
        archetype: tecs.Archetype
        shadows: archetypeshadowset.ShadowSet
        --- Set when the archetype is destroyed; the registry treats
        --- this as the cleanup signal and removes the state from its
        --- map.
        destroyed: boolean

        --- The only ArchetypeEntityObserver method this state defines;
        --- row callbacks stay nil so the archetype's per-row observer
        --- loops never run for shadow states.
        onArchetypeDestroyed: function(self, archetype: tecs.Archetype)

        --- Called by the per-shape uploader. Drives the shadow set's
        --- pointer-drift detection + per-component dirty gate + bulk
        --- flushRange uploads.
        flush: function(self)
    end

    --- Build a state for one archetype.
    ---
    --- @param archetype The archetype to shadow.
    --- @param specs Map from component handle to std430 layout.
    --- Components not present on the archetype are skipped by the
    --- shadow set, so `specs` is a wishlist.
    new: function(
        archetype: tecs.Archetype,
        specs: {tecs.Component: std430.Descriptor}
    ): ArchetypeState
end

local ArchetypeState <const> = shadow_state.ArchetypeState
local STATE_MT <const>: metatable<ArchetypeState> = {__index = ArchetypeState}

function shadow_state.new(
    archetype: tecs.Archetype,
    specs: {tecs.Component: std430.Descriptor}
): shadow_state.ArchetypeState
    local self: shadow_state.ArchetypeState = {
        archetype = archetype,
        shadows = archetypeshadowset.new(archetype, specs),
        destroyed = false,
    }
    return setmetatable(self, STATE_MT)
end

function ArchetypeState:onArchetypeDestroyed(_archetype: tecs.Archetype)
    self.destroyed = true
    -- The shadow set's love.graphics.Buffer instances are GC-managed.
    -- Nothing else to release explicitly here.
end

function ArchetypeState:flush()
    if self.destroyed then return end
    self.shadows:flush()
end

return shadow_state
