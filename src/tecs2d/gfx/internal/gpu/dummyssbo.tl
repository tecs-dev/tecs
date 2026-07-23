--- Shared dummy SSBO singletons, keyed by std430 shadow ctype.
---
--- Used when an archetype lacks an optional component; the shader's
--- `ComponentMask` branches the read to a hardcoded default, but a
--- valid SSBO binding is still required. One 1-element buffer per
--- layout is shared across all dispatchers.

local std430 <const> = require("tecs2d.gfx.internal.gpu.std430")
local devicestate <const> = require("tecs2d.gfx.internal.gpu.devicestate")

local lg <const> = love.graphics

local record dummy_ssbo
    --- Return (creating on first use) the shared dummy buffer for a layout.
    dummyFor: function(layout: std430.Descriptor): love.graphics.Buffer
end

local dummyByFormat <const> = devicestate.get().dummySSBOs

function dummy_ssbo.dummyFor(layout: std430.Descriptor): love.graphics.Buffer
    local existing = dummyByFormat[layout.shadowCtype]
    if existing then return existing end
    local buf = lg.newBuffer(layout.format, 1, {usage = "static", shaderstorage = true})
    dummyByFormat[layout.shadowCtype] = buf
    return buf
end

return dummy_ssbo
