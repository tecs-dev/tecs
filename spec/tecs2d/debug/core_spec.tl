require("busted")

local luassert <const> = require("luassert")

_G.love = require("spec.love2d.love2d_mock")

local tecs <const> = require("tecs")
local context <const> = require("tecs2d.debug.context")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local recording <const> = require("tecs2d.debug.internal.recording")
local annotations <const> = require("tecs2d.debug.internal.annotations")
local freeze <const> = require("tecs2d.debug.internal.freeze")
local commands <const> = require("tecs2d.debug.commands")
local core <const> = require("tecs2d.debug.internal.core")

describe("tecs2d.debug.internal.core", function()
    it("returns the same registry on repeated ensure", function()
        local w = tecs.newWorld()
        local reg = core.ensure(w)
        luassert.is_not_nil(reg)
        luassert.equals(reg, core.ensure(w))
        luassert.equals(reg, core.ensure(w, {fps = 60}))
    end)

    it("publishes the context, recorder, annotations, freeze, and registry resources", function()
        local w = tecs.newWorld()
        local reg = core.ensure(w)
        luassert.equals(reg, w.resources[commands.KEY])
        luassert.equals(reg.env.ctx, w.resources[debugcontext.KEY])
        luassert.equals(reg.env.recorder, w.resources[recording.KEY])
        luassert.equals(reg.env.annotations, w.resources[annotations.KEY])
        luassert.equals(reg.env.freeze, w.resources[freeze.KEY])
    end)

    it("seeds default key bindings for the help command", function()
        local w = tecs.newWorld()
        local reg = core.ensure(w)
        luassert.equals("ctrl", reg.env.keys.leader)
        luassert.equals("/", reg.env.keys.debugToggle)
        luassert.equals(".", reg.env.keys.statsToggle)
    end)

    it("applies recording options through a later ensure", function()
        local w = tecs.newWorld()
        local reg = core.ensure(w)
        local rec = reg.env.recorder
        luassert.equals("ffmpeg", rec.ffmpegPath)
        luassert.equals(30, rec.defaultFps)

        local again = core.ensure(w, {
            ffmpegPath = "/opt/ffmpeg",
            outputDir = "clips",
            countdown = 1.5,
            fps = 60,
            scale = 2,
            frameFormat = "tga",
            ringSize = 16,
        })
        luassert.equals(reg, again)
        luassert.equals("/opt/ffmpeg", rec.ffmpegPath)
        luassert.equals("/opt/ffmpeg", reg.env.ctx.recording.ffmpegPath)
        luassert.equals("clips", rec.outputDir)
        luassert.equals(1.5, rec.defaultCountdown)
        luassert.equals(60, rec.defaultFps)
        luassert.equals(2, rec.defaultScale)
        luassert.equals("tga", rec.defaultFrameFormat)
        luassert.equals(16, rec.defaultRingSize)
    end)

    it("leaves recording options absent from a later ensure unchanged", function()
        local w = tecs.newWorld()
        local reg = core.ensure(w, {fps = 24, outputDir = "clips"})
        core.ensure(w, {scale = 3})
        local rec = reg.env.recorder
        luassert.equals(24, rec.defaultFps)
        luassert.equals("clips", rec.outputDir)
        luassert.equals(3, rec.defaultScale)
        luassert.equals("png", rec.defaultFrameFormat)
        luassert.equals("ffmpeg", rec.ffmpegPath)
    end)

    it("context.ensureCore delegates to core.ensure", function()
        luassert.equals(core.ensure, context.ensureCore)
        local w = tecs.newWorld()
        local reg = context.ensureCore(w)
        luassert.equals(reg, w.resources[commands.KEY])
        luassert.equals(reg, core.ensure(w))
    end)
end)
