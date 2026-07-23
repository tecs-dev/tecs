--- Shared harness for the debugger command specs: installs the love2d mock,
--- registers the spec-only components, and builds a registry on a fresh
--- world. Required by commands_spec and the per-group specs under cmd/,
--- which mirror the src/tecs2d/debug/internal/cmd/ layout.

_G.love = require("spec.love2d.love2d_mock")

local tecs <const> = require("tecs")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local suspension <const> = require("tecs2d.internal.suspension")
local commands <const> = require("tecs2d.debug.commands")

local record cmdharness
    --- Spec-only components, named to avoid cross-spec collisions.
    SpecPos: tecs.Component
    SpecTag: tecs.Component

    --- A registry on a fresh world with the debug context installed.
    makeRegistry: function(): commands.Registry, tecs.World, debugcontext.Context
end

cmdharness.SpecPos = tecs.newComponent({
    name = "DbgCmdPos",
    container = {},
    fields = {"x", "y"},
    defaults = {0, 0},
})
cmdharness.SpecTag = tecs.newTagComponent({name = "DbgCmdTag"})

function cmdharness.makeRegistry(): commands.Registry, tecs.World, debugcontext.Context
    local w = tecs.newWorld()
    local ctx = debugcontext.new()
    w.resources[debugcontext.KEY] = ctx
    local reg = commands.build({
        world = w,
        ctx = ctx,
        recorder = nil,
        suspension = suspension.ensure(w),
        keys = {leader = "ctrl", debugToggle = "/", statsToggle = "."},
    })
    w.resources[commands.KEY] = reg
    return reg, w, ctx
end

return cmdharness
