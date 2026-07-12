--- Love2D integration suite: host recording driven through the debugger
--- command registry (typed commands and the cmd_record_* MCP tools).
--- Recording assembles with ffmpeg, so the whole suite is skipped when
--- ffmpeg is not on the host PATH.
---
--- Run via `make test-love FILE_MATCH='debug_recording'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/debugger"

local function hostHasFfmpeg(): boolean
    local ok = os.execute("command -v ffmpeg >/dev/null 2>&1") as any
    return ok == true or ok == 0
end

describe("debugger host recording", function()
    if not hostHasFfmpeg() then
        it("requires ffmpeg on PATH", function()
            pending("ffmpeg not found on PATH; skipping recording suite")
        end)
        return
    end

    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            _G.rec = { frames = 0 }
            world:addSystem({
                name = "test.FrameCounter",
                phase = tecs.phases.Update,
                run = function() _G.rec.frames = _G.rec.frames + 1 end,
            })
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    local function context(): {string: any}
        return app.client:call("cmd_context", {}) as {string: any}
    end

    local function recordingStatus(): string
        return (context().recording as {string: any}).status as string
    end

    local function tap()
        app.client:call("send_love_event", {event = "keypressed", args = {"lctrl"}})
        app.client:call("send_love_event", {event = "keypressed", args = {"/"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"/"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"lctrl"}})
    end

    local function waitOpen(want: boolean): boolean
        return fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().open as boolean) == want then return true end
            return nil
        end)
    end

    local function typeCommand(text: string)
        app.client:call("send_love_event", {event = "textinput", args = {text}})
        fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().command as string) == text then return true end
            return nil
        end)
        app.client:call("send_love_event", {event = "keypressed", args = {"return"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"return"}})
    end

    local function waitStatus(want: string, seconds: number): boolean
        return fixture.eventually(seconds, function(): boolean
            if recordingStatus() == want then return true end
            return nil
        end)
    end

    local function removeRecordingFiles(name: string)
        fixture.runLua(app, string.format([[
            love.filesystem.remove("recordings/%s.mp4")
            love.filesystem.remove("recordings/%s.mp4.ffmpeg.log")
            return true
        ]], name, name))
    end

    before_each(function()
        if context().open as boolean then
            tap()
            waitOpen(false)
        end
    end)

    it("arms a countdown over MCP and cancel disarms it", function()
        local out = app.client:call("cmd_record_start",
            {seconds = 5, name = "lovespec-arm", countdown = 30})
        local state = out.recording as {string: any}
        luassert.equals("countdown", state.status as string)
        luassert.equals("countdown", recordingStatus())

        app.client:call("cmd_record_cancel", {})
        luassert.equals("idle", recordingStatus())
    end)

    it("records, assembles a video, and cleans up its scratch files", function()
        app.client:call("cmd_record_start",
            {seconds = 0, countdown = 0, name = "lovespec-e2e", fps = 10, scale = 0.5})
        luassert.is_true(waitStatus("recording", fixture.callTimeout) == true,
            "recording did not start")
        -- Let it capture a few frames.
        fixture.eventually(0.7, function(): boolean return nil end)
        app.client:call("cmd_record_stop", {})

        luassert.is_true(waitStatus("completed", 15) == true,
            "recording did not complete; status=" .. recordingStatus())
        local listed = app.client:call("cmd_record_list", {})
        local recs = listed.recordings as {any}
        luassert.is_true(recs ~= nil and #recs >= 1, "completed recording missing from list")

        local info = app.client:call("cmd_record_info", {})
        luassert.is_true(tonumber(info.duration) > 0, "record info lacks a duration")
        luassert.equals("manual", info.stopReason as string)

        local vals = fixture.runLua(app, [[
            local video = love.filesystem.getInfo("recordings/lovespec-e2e.mp4")
            local pid = love.filesystem.getInfo("recordings/lovespec-e2e.mp4.ffmpeg.pid")
            local frames = love.filesystem.getInfo("recordings/lovespec-e2e.frames")
            return video and video.size or 0, pid and "yes" or "no", frames and "yes" or "no"
        ]])
        luassert.is_true(tonumber(vals[1]) > 0, "video file is missing or empty")
        luassert.equals("no", vals[2], "pid file was not cleaned up")
        luassert.equals("no", vals[3], "frames scratch dir was not cleaned up")
        removeRecordingFiles("lovespec-e2e")
    end)

    it("record start debug keeps the panel open and the game running", function()
        tap()
        luassert.is_true(waitOpen(true) == true, "debugger did not open")
        typeCommand("record start debug countdown=0 name=lovespec-dbg fps=10")
        luassert.is_true(waitStatus("recording", fixture.callTimeout) == true,
            "debug recording did not start")
        luassert.is_true(context().open as boolean, "debug recording closed the panel")

        -- The game must be live behind the open panel.
        local f1 = tonumber(fixture.runLua(app, "return _G.rec.frames")[1])
        local live = fixture.eventually(fixture.callTimeout, function(): boolean
            local now = tonumber(fixture.runLua(app, "return _G.rec.frames")[1])
            if now > f1 then return true end
            return nil
        end)
        luassert.is_true(live == true, "game froze during a debug recording")

        typeCommand("record stop")
        luassert.is_true(waitStatus("completed", 15) == true,
            "debug recording did not complete; status=" .. recordingStatus())

        -- With the recording over, the still-open panel re-freezes the game.
        local refroze = fixture.eventually(fixture.callTimeout, function(): boolean
            if context().frozen as boolean then return true end
            return nil
        end)
        luassert.is_true(refroze == true, "panel did not re-freeze after the debug recording")
        tap()
        waitOpen(false)
        removeRecordingFiles("lovespec-dbg")
    end)
end)
