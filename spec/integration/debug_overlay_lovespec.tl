require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/debugger"

describe("in-game debugger overlay", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        -- Frame counter in Update: stops advancing while frozen, resumes after.
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

    local function selectedList(): {number}
        return context().selected as {number}
    end

    local function selectedHas(eid: number): boolean
        local sel = selectedList()
        for i = 1, #sel do
            if sel[i] == eid then return true end
        end
        return false
    end

    -- Toggle: Ctrl+/ (ctrl held while / is pressed).
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

    -- Reset to closed and clear the selection before each test.
    before_each(function()
        if context().open as boolean then
            tap()
            waitOpen(false)
        end
        app.client:call("cmd_clear", {})
    end)

    local function openDebugger()
        tap()
        luassert.is_true(waitOpen(true) == true, "debugger did not open")
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

    -- Move the cursor into the game view and return the world point under it.
    local function moveCursor(sx: number, sy: number): number, number
        app.client:call("send_love_event", {event = "mousemoved", args = {sx, sy, 0, 0}})
        local wx, wy = 0.0, 0.0
        fixture.eventually(fixture.callTimeout, function(): boolean
            local m = context().mouse as {string: number}
            if math.abs(m.screenX - sx) < 1 then
                wx, wy = m.worldX, m.worldY
                return true
            end
            return nil
        end)
        return wx, wy
    end

    local function spawnAt(wx: number, wy: number): number
        return tonumber(fixture.runLua(app, string.format([[
            local tecs = require("tecs")
            local Transform = tecs.builtins.Transform
            local id = world:spawn(Transform(%f, %f, 0))
            world:commit()
            return id
        ]], wx, wy))[1])
    end

    it("starts closed", function()
        luassert.is_false(context().open as boolean, "should start closed")
    end)

    it("toggles and freezes with Ctrl+/", function()
        openDebugger()
        luassert.is_true(context().frozen as boolean, "should be frozen while open")

        local before = tonumber(fixture.runLua(app, "return _G.rec.frames")[1])
        fixture.eventually(0.3, function(): boolean return nil end)
        local after = tonumber(fixture.runLua(app, "return _G.rec.frames")[1])
        luassert.is_true(after == before, "Update ran while frozen")

        tap()
        luassert.is_true(waitOpen(false) == true, "debugger did not close")
    end)

    it("adds to the selection with a typed select command", function()
        local eid = spawnAt(80, 80)
        openDebugger()
        typeCommand("select " .. tostring(eid))
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            if selectedHas(eid) then return true end
            return nil
        end)
        luassert.is_true(ok == true,
            "select command did not select; selected=" .. tostring(#selectedList()))
    end)

    it("cycles command completions with Tab", function()
        openDebugger()
        app.client:call("send_love_event", {event = "textinput", args = {"de"}})
        fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().command as string) == "de" then return true end
            return nil
        end)
        app.client:call("send_love_event", {event = "keypressed", args = {"tab"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"tab"}})
        local completed = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().command as string) == "despawn" then return true end
            return nil
        end)
        luassert.is_true(completed == true,
            "Tab did not complete to despawn; command=" .. tostring(context().command))
        app.client:call("send_love_event", {event = "keypressed", args = {"return"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"return"}})
    end)

    it("shows the tab hint on open and clears it on tab", function()
        openDebugger()
        local shown = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().message as string) == "Hit [TAB] to see commands" then return true end
            return nil
        end)
        luassert.is_true(shown == true, "open hint not shown")
        app.client:call("send_love_event", {event = "keypressed", args = {"tab"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"tab"}})
        local cleared = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().message as string) == "" then return true end
            return nil
        end)
        luassert.is_true(cleared == true, "tab hint did not clear on tab")
    end)

    it("bare tab starts the cycle at the last used command", function()
        openDebugger()
        typeCommand("clear")
        -- Backward: the first shift+tab lands on the command just executed.
        app.client:call("send_love_event", {event = "keypressed", args = {"lshift"}})
        app.client:call("send_love_event", {event = "keypressed", args = {"tab"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"tab"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"lshift"}})
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().command as string) == "clear" then return true end
            return nil
        end)
        luassert.is_true(ok == true,
            "shift+tab did not start at the last used command; command=" .. tostring(context().command))
        -- Forward after a reset lands on the same starting point.
        app.client:call("send_love_event", {event = "keypressed", args = {"escape"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"escape"}})
        fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().command as string) == "" then return true end
            return nil
        end)
        app.client:call("send_love_event", {event = "keypressed", args = {"tab"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"tab"}})
        local fwd = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().command as string) == "clear" then return true end
            return nil
        end)
        luassert.is_true(fwd == true,
            "tab did not start at the last used command; command=" .. tostring(context().command))
    end)

    it("query selects entities by component", function()
        local a = spawnAt(30, 30)
        local b = spawnAt(31, 31)
        openDebugger()
        typeCommand("query +Transform")
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            if selectedHas(a) and selectedHas(b) then return true end
            return nil
        end)
        luassert.is_true(ok == true, "query +Transform did not select the spawned entities")
    end)


    it("light color sets the ambient light color", function()
        openDebugger()
        typeCommand("light color 0.30 0.40 0.50")
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            local s = fixture.runLua(app, [[
                local gfx = require("tecs2d.gfx")
                local p = world.resources[gfx.PIPELINE]
                local r, g, b = p:getAmbientLight()
                return string.format("%.2f,%.2f,%.2f", r, g, b)
            ]])[1]
            if s == "0.30,0.40,0.50" then return true end
            return nil
        end)
        luassert.is_true(ok == true, "light command did not set the ambient light")
    end)

    it("light toggle and light shadows flip the pipeline flags", function()
        local function flags(): string, string
            local vals = fixture.runLua(app, [[
                local gfx = require("tecs2d.gfx")
                local p = world.resources[gfx.PIPELINE]
                return tostring(p:isLightingEnabled()), tostring(p.shadowsEnabled)
            ]])
            return vals[1], vals[2]
        end
        local lit0 = flags()

        local toggled = app.client:call("cmd_light_toggle", {})
        luassert.equals(lit0 ~= "true", toggled.enabled as boolean)
        local litNow = flags()
        luassert.is_true(litNow ~= lit0, "light toggle did not flip lighting")
        app.client:call("cmd_light_toggle", {on = lit0 == "true"})

        app.client:call("cmd_light_shadows", {on = false})
        local _, sh = flags()
        luassert.equals("false", sh, "shadows off did not apply")
        app.client:call("cmd_light_shadows", {on = true})
        local _, sh2 = flags()
        luassert.equals("true", sh2, "shadows on did not apply")
    end)

    it("light bloom subcommand configures bloom", function()
        openDebugger()
        typeCommand("light bloom 2 1.5 0.1")
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            local s = fixture.runLua(app, [[
                local gfx = require("tecs2d.gfx")
                local b = world.resources[gfx.PIPELINE]:getBloom()
                return string.format("%s,%.2f,%.2f", tostring(b.enabled), b.intensity, b.radius)
            ]])[1]
            if s == "true,2.00,1.50" then return true end
            return nil
        end)
        luassert.is_true(ok == true, "bloom command did not configure bloom")
    end)

    it("toggles selection: click adds, clicking again removes", function()
        openDebugger()
        local wx, wy = moveCursor(200, 150)
        local eid = spawnAt(wx, wy)
        app.client:call("send_love_event", {event = "mousepressed", args = {200, 150, 1}})
        app.client:call("send_love_event", {event = "mousereleased", args = {200, 150, 1}})
        local added = fixture.eventually(fixture.callTimeout, function(): boolean
            if selectedHas(eid) then return true end
            return nil
        end)
        luassert.is_true(added == true, "click did not add to selection")

        app.client:call("send_love_event", {event = "mousepressed", args = {200, 150, 1}})
        app.client:call("send_love_event", {event = "mousereleased", args = {200, 150, 1}})
        local removed = fixture.eventually(fixture.callTimeout, function(): boolean
            if not selectedHas(eid) then return true end
            return nil
        end)
        luassert.is_true(removed == true, "second click did not remove from selection")
    end)

    it("drag selects entities inside the box", function()
        openDebugger()
        local wx, wy = moveCursor(160, 150)
        local eid = spawnAt(wx, wy)
        app.client:call("send_love_event", {event = "mousemoved", args = {120, 120, 0, 0}})
        app.client:call("send_love_event", {event = "mousepressed", args = {120, 120, 1}})
        app.client:call("send_love_event", {event = "mousemoved", args = {200, 190, 80, 70}})
        app.client:call("send_love_event", {event = "mousereleased", args = {200, 190, 1}})
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            if selectedHas(eid) then return true end
            return nil
        end)
        luassert.is_true(ok == true, "drag did not select the entity inside the box")
    end)

    local function entityX(eid: number): number
        return tonumber(fixture.runLua(app, string.format([[
            local tecs = require("tecs")
            local t = world:get(%d, tecs.builtins.Transform)
            return t and t.x or 0
        ]], eid))[1])
    end

    it("shift-drag moves the selected entities", function()
        openDebugger()
        local wx, wy = moveCursor(160, 150)
        local eid = spawnAt(wx, wy)
        app.client:call("cmd_select", {id = eid, replace = true})
        app.client:call("send_love_event", {event = "keypressed", args = {"lshift"}})
        app.client:call("send_love_event", {event = "mousepressed", args = {160, 150, 1}})
        app.client:call("send_love_event", {event = "mousemoved", args = {210, 150, 50, 0}})
        app.client:call("send_love_event", {event = "mousereleased", args = {210, 150, 1}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"lshift"}})
        local moved = fixture.eventually(fixture.callTimeout, function(): boolean
            if entityX(eid) > wx + 1 then return true end
            return nil
        end)
        luassert.is_true(moved == true, "shift-drag did not move the entity")
    end)

    it("right-click cancels a shift-drag and restores positions", function()
        openDebugger()
        local wx, wy = moveCursor(160, 150)
        local eid = spawnAt(wx, wy)
        app.client:call("cmd_select", {id = eid, replace = true})
        app.client:call("send_love_event", {event = "keypressed", args = {"lshift"}})
        app.client:call("send_love_event", {event = "mousepressed", args = {160, 150, 1}})
        app.client:call("send_love_event", {event = "mousemoved", args = {220, 150, 60, 0}})
        app.client:call("send_love_event", {event = "mousepressed", args = {220, 150, 2}})
        app.client:call("send_love_event", {event = "mousereleased", args = {220, 150, 1}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"lshift"}})
        local restored = fixture.eventually(fixture.callTimeout, function(): boolean
            if math.abs(entityX(eid) - wx) < 0.5 then return true end
            return nil
        end)
        luassert.is_true(restored == true, "right-click did not restore the entity position")
    end)

    it("despawn with no id despawns all selected and clears", function()
        local a = spawnAt(50, 50)
        local b = spawnAt(52, 52)
        app.client:call("cmd_select", {id = a, replace = true})
        openDebugger()
        typeCommand("select " .. tostring(b))
        fixture.eventually(fixture.callTimeout, function(): boolean
            if selectedHas(a) and selectedHas(b) then return true end
            return nil
        end)
        typeCommand("despawn")
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            local aAlive = fixture.runLua(app, string.format("return tostring(world:isAlive(%d))", a))[1]
            local bAlive = fixture.runLua(app, string.format("return tostring(world:isAlive(%d))", b))[1]
            if aAlive == "false" and bAlive == "false" and #selectedList() == 0 then return true end
            return nil
        end)
        luassert.is_true(ok == true, "despawn did not remove all selected and clear")
    end)

    it("middle-drag pans the camera", function()
        openDebugger()
        moveCursor(160, 120)
        local cam0 = context().camera as {string: number}
        app.client:call("send_love_event", {event = "mousepressed", args = {160, 120, 3}})
        app.client:call("send_love_event", {event = "mousemoved", args = {210, 120, 50, 0}})
        app.client:call("send_love_event", {event = "mousereleased", args = {210, 120, 3}})
        local moved = fixture.eventually(fixture.callTimeout, function(): boolean
            local cam = context().camera as {string: number}
            if math.abs(cam.x - cam0.x) > 1 then return true end
            return nil
        end)
        luassert.is_true(moved == true, "middle-drag did not move the camera")
    end)

    it("mouse wheel zooms the camera", function()
        openDebugger()
        moveCursor(160, 120)
        local z0 = (context().camera as {string: number}).zoom
        app.client:call("send_love_event", {event = "wheelmoved", args = {0, 3}})
        local zoomed = fixture.eventually(fixture.callTimeout, function(): boolean
            local z = (context().camera as {string: number}).zoom
            if z > z0 + 0.01 then return true end
            return nil
        end)
        luassert.is_true(zoomed == true, "wheel did not zoom the camera in")
    end)

    it("exit command closes the debugger and unfreezes", function()
        openDebugger()
        typeCommand("exit")
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            if not (context().open as boolean) and not (context().frozen as boolean) then return true end
            return nil
        end)
        luassert.is_true(ok == true, "exit did not close the debugger")
    end)

    it("step command ticks the game a fixed number of frames", function()
        openDebugger()
        local before = tonumber(fixture.runLua(app, "return _G.rec.frames")[1])
        -- Confirm the counter is genuinely frozen first.
        fixture.eventually(0.2, function(): boolean return nil end)
        local held = tonumber(fixture.runLua(app, "return _G.rec.frames")[1])
        luassert.is_true(held == before, "counter advanced while frozen")
        typeCommand("step 3")
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            local now = tonumber(fixture.runLua(app, "return _G.rec.frames")[1])
            if now == before + 3 then return true end
            return nil
        end)
        luassert.is_true(ok == true,
            "step 3 did not advance exactly 3 frames from " .. tostring(before))
    end)

    it("mark names entities and goto moves the camera to them", function()
        local a = spawnAt(300, 40)
        app.client:call("cmd_select", {id = a, replace = true})
        openDebugger()
        typeCommand("mark boss")
        local marked = fixture.eventually(fixture.callTimeout, function(): boolean
            local marks = context().marks as {string: string}
            if marks ~= nil and marks.boss ~= nil then return true end
            return nil
        end)
        luassert.is_true(marked == true, "mark did not appear in the debug context")
        typeCommand("goto boss")
        local moved = fixture.eventually(fixture.callTimeout, function(): boolean
            local cam = context().camera as {string: number}
            if math.abs(cam.x - 300) < 2 and math.abs(cam.y - 40) < 2 then return true end
            return nil
        end)
        luassert.is_true(moved == true, "goto did not move the camera to the marked entity")
        typeCommand("mark")
        local unmarked = fixture.eventually(fixture.callTimeout, function(): boolean
            local marks = context().marks as {string: string}
            if marks == nil or marks.boss == nil then return true end
            return nil
        end)
        luassert.is_true(unmarked == true, "mark with no name did not unmark")
    end)

    it("goto with an unknown name reports not found", function()
        openDebugger()
        typeCommand("goto nonexistent_mark_xyz")
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            local m = context().message as string
            if m ~= nil and m:find("no live entity for", 1, true) then return true end
            return nil
        end)
        luassert.is_true(ok == true,
            "goto unknown did not report not found; message=" .. tostring(context().message))
    end)

    it("the toggle character is typeable in a command", function()
        openDebugger()
        -- Each character arrives as its own textinput event; a lone "/" is the
        -- regression case (it used to be swallowed as the toggle key).
        app.client:call("send_love_event", {event = "textinput", args = {"a"}})
        fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().command as string) == "a" then return true end
            return nil
        end)
        app.client:call("send_love_event", {event = "textinput", args = {"/"}})
        app.client:call("send_love_event", {event = "textinput", args = {"b"}})
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().command as string) == "a/b" then return true end
            return nil
        end)
        luassert.is_true(ok == true,
            "could not type '/' into the command line; command=" .. tostring(context().command))
    end)

    it("select and despawn accept a mark name", function()
        local a = spawnAt(25, 25)
        local b = spawnAt(26, 26)
        app.client:call("cmd_select", {id = a, replace = true})
        openDebugger()
        typeCommand("select " .. tostring(b))
        typeCommand("mark crew")
        typeCommand("clear")
        typeCommand("select crew")
        local selok = fixture.eventually(fixture.callTimeout, function(): boolean
            if selectedHas(a) and selectedHas(b) then return true end
            return nil
        end)
        luassert.is_true(selok == true, "select <mark> did not select the marked entities")
        typeCommand("despawn crew")
        local dead = fixture.eventually(fixture.callTimeout, function(): boolean
            local aA = fixture.runLua(app, string.format("return tostring(world:isAlive(%d))", a))[1]
            local bA = fixture.runLua(app, string.format("return tostring(world:isAlive(%d))", b))[1]
            if aA == "false" and bA == "false" then return true end
            return nil
        end)
        luassert.is_true(dead == true, "despawn <mark> did not despawn the marked entities")
    end)

    it("note annotates selected entities and clears on empty", function()
        local a = spawnAt(55, 55)
        app.client:call("cmd_select", {id = a, replace = true})
        openDebugger()
        typeCommand("note needs review")
        local noted = fixture.eventually(fixture.callTimeout, function(): boolean
            local notes = context().notes as {string: string}
            if notes ~= nil and notes["needs review"] ~= nil then return true end
            return nil
        end)
        luassert.is_true(noted == true, "note did not appear in the debug context")
        typeCommand("note")
        local cleared = fixture.eventually(fixture.callTimeout, function(): boolean
            local notes = context().notes as {string: string}
            if notes == nil or notes["needs review"] == nil then return true end
            return nil
        end)
        luassert.is_true(cleared == true, "empty note did not clear the annotation")
    end)

    it("info with nothing selected reports nothing selected", function()
        openDebugger()
        typeCommand("info")
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            local m = context().message as string
            if m ~= nil and m:find("nothing selected", 1, true) then return true end
            return nil
        end)
        luassert.is_true(ok == true,
            "info empty did not report; message=" .. tostring(context().message))
    end)

    it("info of a selected entity succeeds", function()
        local eid = spawnAt(90, 90)
        app.client:call("cmd_select", {id = eid, replace = true})
        openDebugger()
        typeCommand("info")
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().message as string) == "" then return true end
            return nil
        end)
        luassert.is_true(ok == true,
            "info of a selected entity errored; message=" .. tostring(context().message))
    end)

    it("ctrl+c clears the command line", function()
        openDebugger()
        app.client:call("send_love_event", {event = "textinput", args = {"despawn"}})
        fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().command as string) == "despawn" then return true end
            return nil
        end)
        app.client:call("send_love_event", {event = "keypressed", args = {"lctrl"}})
        app.client:call("send_love_event", {event = "keypressed", args = {"c"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"c"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"lctrl"}})
        local cleared = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().command as string) == "" then return true end
            return nil
        end)
        luassert.is_true(cleared == true, "ctrl+c did not clear the command line")
    end)

    it("ctrl+c with an empty command leaves the debugger open", function()
        openDebugger()
        app.client:call("send_love_event", {event = "keypressed", args = {"lctrl"}})
        app.client:call("send_love_event", {event = "keypressed", args = {"c"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"c"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"lctrl"}})
        local stillOpen = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().open as boolean) and (context().command as string) == "" then return true end
            return nil
        end)
        luassert.is_true(stillOpen == true, "ctrl+c with empty command closed the debugger")
    end)

    it("escape clears the command line before exiting", function()
        openDebugger()
        app.client:call("send_love_event", {event = "textinput", args = {"despawn"}})
        fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().command as string) == "despawn" then return true end
            return nil
        end)
        app.client:call("send_love_event", {event = "keypressed", args = {"escape"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"escape"}})
        local cleared = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().open as boolean) and (context().command as string) == "" then return true end
            return nil
        end)
        luassert.is_true(cleared == true, "escape did not clear the command line first")
    end)

    it("escape exits the debugger when the command line is empty", function()
        openDebugger()
        app.client:call("send_love_event", {event = "keypressed", args = {"escape"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"escape"}})
        local closed = fixture.eventually(fixture.callTimeout, function(): boolean
            if not (context().open as boolean) then return true end
            return nil
        end)
        luassert.is_true(closed == true, "escape did not exit the debugger")
    end)

    it("up recalls the previous command from history", function()
        openDebugger()
        typeCommand("clear")
        app.client:call("send_love_event", {event = "keypressed", args = {"up"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"up"}})
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().command as string) == "clear" then return true end
            return nil
        end)
        luassert.is_true(ok == true,
            "up did not recall the previous command; command=" .. tostring(context().command))
    end)

    it("snapshot save reports a number and load restores state", function()
        openDebugger()
        local base = tonumber(fixture.runLua(app, "return world:getStats().entities")[1])
        typeCommand("snapshot save snaptest.snapshot")
        local num = 0
        fixture.eventually(fixture.callTimeout, function(): boolean
            local snaps = context().snapshots as {any}
            if snaps ~= nil and #snaps >= 1 then
                local last = snaps[#snaps] as {string: any}
                if last.number ~= nil and last.time ~= nil then
                    num = last.number as integer
                    return true
                end
            end
            return nil
        end)
        luassert.is_true(num >= 1, "snapshot save did not report a number and timestamp")
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local Transform = tecs.builtins.Transform
            for i = 1, 5 do world:spawn(Transform(i, i, 0)) end
            world:commit()
            return true
        ]])
        local grown = tonumber(fixture.runLua(app, "return world:getStats().entities")[1])
        luassert.is_true(grown == base + 5, "spawns did not grow the world")
        typeCommand("snapshot load " .. tostring(num))
        local restored = fixture.eventually(fixture.callTimeout, function(): boolean
            local n = tonumber(fixture.runLua(app, "return world:getStats().entities")[1])
            if n == base then return true end
            return nil
        end)
        luassert.is_true(restored == true, "snapshot load did not restore the entity count")
        local info = app.client:call("cmd_snapshot_info", {ref = tostring(num)})
        luassert.equals(num, tonumber(info.number), "snapshot info did not find the save by number")
        luassert.is_true(info.exists as boolean, "snapshot info says the file is missing")
        luassert.equals(base, tonumber(info.entities),
            "snapshot info entity count should match the world at save time")
        typeCommand("snapshot clear")
        local cleared = fixture.eventually(fixture.callTimeout, function(): boolean
            local snaps = context().snapshots as {any}
            if snaps ~= nil and #snaps == 0 then return true end
            return nil
        end)
        luassert.is_true(cleared == true, "snapshot clear did not wipe the history")
        local gone = fixture.runLua(app,
            "return love.filesystem.getInfo('snaptest.snapshot') and 'yes' or 'no'")[1]
        luassert.is_true(gone == "no", "snapshot clear did not delete the file")
    end)

    it("mark clear removes all marks and list reports empty", function()
        local a = spawnAt(15, 15)
        app.client:call("cmd_select", {id = a, replace = true})
        openDebugger()
        typeCommand("mark crew2")
        typeCommand("mark clear")
        local cleared = fixture.eventually(fixture.callTimeout, function(): boolean
            local marks = context().marks as {string: string}
            if marks == nil or marks.crew2 == nil then return true end
            return nil
        end)
        luassert.is_true(cleared == true, "mark clear did not remove marks")
        typeCommand("mark list")
        local empty = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().message as string) == "no marks yet" then return true end
            return nil
        end)
        luassert.is_true(empty == true, "mark list did not report empty after clear")
    end)

    it("profile with a duration reopens with a saved profile", function()
        openDebugger()
        typeCommand("profile 0.2")
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            local c = context()
            local profs = c.profiles as {any}
            if (c.open as boolean) and profs ~= nil and #profs > 0 then return true end
            return nil
        end)
        luassert.is_true(ok == true, "timed profile did not reopen with results")
        local info = app.client:call("cmd_profile_info", {})
        luassert.is_not_nil(info.summary, "profile info did not return a summary")
        typeCommand("profile clear")
        local pcleared = fixture.eventually(fixture.callTimeout, function(): boolean
            local profs = context().profiles as {any}
            if profs ~= nil and #profs == 0 then return true end
            return nil
        end)
        luassert.is_true(pcleared == true, "profile clear did not remove captures")
    end)

    it("screenshot captures the screen, lists, and clear deletes", function()
        openDebugger()
        typeCommand("screenshot shottest.png")
        local captured = fixture.eventually(fixture.callTimeout, function(): boolean
            local shots = context().screenshots as {any}
            if shots ~= nil and #shots >= 1 then
                local last = shots[#shots] as {string: any}
                if (last.path as string) == "shottest.png" and last.time ~= nil and last.size ~= nil then
                    return true
                end
            end
            return nil
        end)
        luassert.is_true(captured == true, "screenshot was not captured and recorded")

        -- Typed info renders the popup plus the thumbnail (loads the PNG in
        -- the overlay); message stays empty because the result is a popup.
        typeCommand("screenshot info")
        local infoShown = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().message as string) == "" then return true end
            return nil
        end)
        luassert.is_true(infoShown == true, "screenshot info errored: " .. tostring(context().message))
        local viaMcp = app.client:call("cmd_screenshot_info", {})
        luassert.equals("shottest.png", viaMcp.path as string)
        local copied = app.client:call("cmd_screenshot_path", {})
        luassert.matches("shottest%.png$", copied.path as string)
        -- Typing the next command dismisses the popup (and its thumbnail).
        typeCommand("screenshot clear")
        local cleared = fixture.eventually(fixture.callTimeout, function(): boolean
            local shots = context().screenshots as {any}
            if shots ~= nil and #shots == 0 then return true end
            return nil
        end)
        luassert.is_true(cleared == true, "screenshot clear did not wipe the history")
    end)

    it("screenshot delay and panel options defer the capture", function()
        openDebugger()
        typeCommand("screenshot delayshot.png delay=0.3 panel=true")
        local captured = fixture.eventually(fixture.callTimeout, function(): boolean
            local shots = context().screenshots as {any}
            if shots ~= nil and #shots >= 1 then
                local last = shots[#shots] as {string: any}
                if (last.path as string) == "delayshot.png" then return true end
            end
            return nil
        end)
        luassert.is_true(captured == true, "delayed screenshot never landed")
        typeCommand("screenshot clear")
    end)

    it("clear command clears the selection", function()
        local a = spawnAt(70, 70)
        app.client:call("cmd_select", {id = a, replace = true})
        openDebugger()
        typeCommand("clear")
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            if #selectedList() == 0 then return true end
            return nil
        end)
        luassert.is_true(ok == true, "clear did not clear the selection")
    end)

    it("delete key despawns the current selection", function()
        local a = spawnAt(60, 60)
        app.client:call("cmd_select", {id = a, replace = true})
        openDebugger()
        app.client:call("send_love_event", {event = "keypressed", args = {"delete"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"delete"}})
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            local alive = fixture.runLua(app, string.format("return tostring(world:isAlive(%d))", a))[1]
            if alive == "false" and #selectedList() == 0 then return true end
            return nil
        end)
        luassert.is_true(ok == true, "delete did not despawn the selection")
    end)

    it("help populates the popup without setting a message", function()
        openDebugger()
        typeCommand("help")
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().message as string) == "" then return true end
            return nil
        end)
        luassert.is_true(ok == true, "help left a message: " .. tostring(context().message))
    end)

    it("help <command> shows usage and reports unknown", function()
        openDebugger()
        typeCommand("help screenshot")
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().message as string) == "" then return true end
            return nil
        end)
        luassert.is_true(ok == true,
            "help <command> set a message: " .. tostring(context().message))
        typeCommand("help nope")
        local unknown = fixture.eventually(fixture.callTimeout, function(): boolean
            local m = context().message as string
            if m ~= nil and m:find("no such command", 1, true) then return true end
            return nil
        end)
        luassert.is_true(unknown == true, "help <unknown> did not report unknown")
    end)

    it("clears the result message when typing resumes", function()
        openDebugger()
        typeCommand("despawn")
        fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().message as string) ~= "" then return true end
            return nil
        end)
        app.client:call("send_love_event", {event = "textinput", args = {"d"}})
        local cleared = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().message as string) == "" then return true end
            return nil
        end)
        luassert.is_true(cleared == true, "message did not clear when typing resumed")
    end)

    it("agent drives the selection: add, replace, and clear", function()
        local a = spawnAt(40, 40)
        local b = spawnAt(42, 42)
        app.client:call("cmd_select", {id = a})
        app.client:call("cmd_select", {id = b})
        luassert.is_true(selectedHas(a) and selectedHas(b), "cmd_select did not accumulate")
        app.client:call("cmd_select", {id = a, replace = true})
        local sel = selectedList()
        luassert.is_true(#sel == 1 and sel[1] == a, "replace did not swap the selection")
        app.client:call("cmd_clear", {})
        luassert.is_true(#selectedList() == 0, "clearing selection did not empty the set")
    end)

    it("registry-derived cmd_* tools drive the debugger over MCP", function()
        local eid = spawnAt(45, 45)
        local sel = app.client:call("cmd_select", {id = eid})
        luassert.equals(1, tonumber(sel.selected), "cmd_select did not report a selection")
        luassert.is_true(selectedHas(eid), "cmd_select did not select the entity")

        local marked = app.client:call("cmd_mark", {name = "mcpmark"})
        luassert.equals("mcpmark", marked.name as string)
        local marks = context().marks as {string: string}
        luassert.is_true(marks ~= nil and marks.mcpmark ~= nil, "cmd_mark did not mark")

        app.client:call("cmd_note", {msg = "seen by agent"})
        local notes = context().notes as {string: string}
        luassert.is_true(notes ~= nil and notes["seen by agent"] ~= nil, "cmd_note did not note")

        local listed = app.client:call("cmd_mark_list", {})
        local groups = listed.marks as {string: {string: number}}
        luassert.is_true(groups ~= nil and groups.mcpmark ~= nil and groups.mcpmark.count == 1,
            "cmd_mark_list did not return structured groups")

        app.client:call("cmd_mark_clear", {})
        app.client:call("cmd_clear", {})
        luassert.equals(0, #selectedList(), "cmd_clear did not clear the selection")
    end)

    it("cmd_* tools validate arguments through the shared schemas", function()
        local envMissing = app.client:tryCall("cmd_select", {})
        luassert.is_true(envMissing ~= nil and (envMissing.ok as boolean) == false,
            "cmd_select with no target should fail validation")
        local envConflict = app.client:tryCall("cmd_select", {id = 1, name = "x"})
        luassert.is_true(envConflict ~= nil and (envConflict.ok as boolean) == false,
            "cmd_select with two targets should fail validation")
        local envType = app.client:tryCall("cmd_goto", {id = "five"})
        luassert.is_true(envType ~= nil and (envType.ok as boolean) == false,
            "cmd_goto with a string id should fail validation")
    end)

    it("an MCP freeze survives a debugger open/close cycle and shares step", function()
        app.client:call("cmd_freeze", {on = true})
        local f0 = tonumber(fixture.runLua(app, "return _G.rec.frames")[1])
        fixture.eventually(0.2, function(): boolean return nil end)
        local f1 = tonumber(fixture.runLua(app, "return _G.rec.frames")[1])
        luassert.is_true(f1 == f0, "game ran while MCP-frozen")

        -- Opening and closing the debugger must not clobber the MCP pause.
        tap()
        luassert.is_true(waitOpen(true) == true, "debugger did not open while frozen")
        tap()
        luassert.is_true(waitOpen(false) == true, "debugger did not close while frozen")
        local f2 = tonumber(fixture.runLua(app, "return _G.rec.frames")[1])
        fixture.eventually(0.3, function(): boolean return nil end)
        local f3 = tonumber(fixture.runLua(app, "return _G.rec.frames")[1])
        luassert.is_true(f3 == f2, "closing the debugger broke the MCP freeze")

        -- The cmd_step tool and the debugger share one freeze controller.
        app.client:call("cmd_step", {n = 2})
        local stepped = fixture.eventually(fixture.callTimeout, function(): boolean
            local now = tonumber(fixture.runLua(app, "return _G.rec.frames")[1])
            if now == f3 + 2 then return true end
            return nil
        end)
        luassert.is_true(stepped == true, "step did not advance exactly 2 frames while frozen")

        app.client:call("cmd_freeze", {on = false})
        local resumed = fixture.eventually(fixture.callTimeout, function(): boolean
            local now = tonumber(fixture.runLua(app, "return _G.rec.frames")[1])
            if now > f3 + 2 then return true end
            return nil
        end)
        luassert.is_true(resumed == true, "releasing the freeze did not restart gameplay")
    end)

    -- Toggle the stats HUD: Ctrl+. (ctrl held while . is pressed).
    local function tapStats()
        app.client:call("send_love_event", {event = "keypressed", args = {"lctrl"}})
        app.client:call("send_love_event", {event = "keypressed", args = {"."}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"."}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"lctrl"}})
    end

    local function waitStats(want: boolean): boolean
        return fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().statsShown as boolean) == want then return true end
            return nil
        end)
    end

    it("stats HUD toggles with Ctrl+. and is suppressed while the debugger is open", function()
        luassert.is_false(context().statsShown as boolean, "stats HUD should start hidden")
        tapStats()
        luassert.is_true(waitStats(true) == true, "Ctrl+. did not show the stats HUD")

        -- With the debugger command line open, the toggle must not fire.
        openDebugger()
        tapStats()
        fixture.eventually(0.3, function(): boolean return nil end)
        luassert.is_true(context().statsShown as boolean, "stats toggle fired while the debugger was open")
        tap()
        waitOpen(false)

        tapStats()
        luassert.is_true(waitStats(false) == true, "Ctrl+. did not hide the stats HUD")
    end)

    it("the toggle works while a game modal holds the input stack", function()
        fixture.runLua(app, "_G.tok = require('tecs2d.input').pushStack() return true")
        tap()
        luassert.is_true(waitOpen(true) == true,
            "Ctrl+/ did not open the debugger over a game input layer")
        tap()
        luassert.is_true(waitOpen(false) == true,
            "Ctrl+/ did not close the debugger over a game input layer")
        fixture.runLua(app, "require('tecs2d.input').popStack(_G.tok) return true")
    end)

    it("down walks the command history forward", function()
        openDebugger()
        typeCommand("clear")
        typeCommand("mark ls")
        app.client:call("send_love_event", {event = "keypressed", args = {"up"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"up"}})
        app.client:call("send_love_event", {event = "keypressed", args = {"up"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"up"}})
        local back = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().command as string) == "clear" then return true end
            return nil
        end)
        luassert.is_true(back == true, "up did not walk back to the first command")
        app.client:call("send_love_event", {event = "keypressed", args = {"down"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"down"}})
        local fwd = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().command as string) == "mark ls" then return true end
            return nil
        end)
        luassert.is_true(fwd == true,
            "down did not walk forward; command=" .. tostring(context().command))
    end)

    it("shift-drag moves every selected entity together", function()
        openDebugger()
        local wx, wy = moveCursor(160, 150)
        local a = spawnAt(wx, wy)
        local b = spawnAt(wx + 10, wy + 5)
        app.client:call("cmd_select", {id = a, replace = true})
        app.client:call("cmd_select", {id = b})
        local ax0 = entityX(a)
        local bx0 = entityX(b)
        app.client:call("send_love_event", {event = "keypressed", args = {"lshift"}})
        app.client:call("send_love_event", {event = "mousepressed", args = {160, 150, 1}})
        app.client:call("send_love_event", {event = "mousemoved", args = {210, 150, 50, 0}})
        app.client:call("send_love_event", {event = "mousereleased", args = {210, 150, 1}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"lshift"}})
        local moved = fixture.eventually(fixture.callTimeout, function(): boolean
            if entityX(a) > ax0 + 1 and entityX(b) > bx0 + 1 then return true end
            return nil
        end)
        luassert.is_true(moved == true, "shift-drag did not move both selected entities")
    end)

    it("screenshot of a drag area crops to the box", function()
        openDebugger()
        moveCursor(120, 120)
        app.client:call("send_love_event", {event = "mousepressed", args = {120, 120, 1}})
        app.client:call("send_love_event", {event = "mousemoved", args = {200, 180, 80, 60}})
        app.client:call("send_love_event", {event = "mousereleased", args = {200, 180, 1}})
        local area = fixture.eventually(fixture.callTimeout, function(): boolean
            if context().area ~= nil then return true end
            return nil
        end)
        luassert.is_true(area == true, "drag did not set an area")

        typeCommand("screenshot areashot.png")
        local captured = fixture.eventually(fixture.callTimeout, function(): boolean
            local shots = context().screenshots as {any}
            if shots ~= nil and #shots >= 1 then
                local last = shots[#shots] as {string: any}
                if (last.path as string) == "areashot.png" then return true end
            end
            return nil
        end)
        luassert.is_true(captured == true, "area screenshot was not recorded")

        -- Parse the PNG IHDR width and compare against the full framebuffer.
        local vals = fixture.runLua(app, [[
            local data = love.filesystem.read("areashot.png")
            if not data then return -1, -1 end
            local b1, b2, b3, b4 = data:byte(17, 20)
            local shotW = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
            local pw = love.graphics.getPixelDimensions()
            love.filesystem.remove("areashot.png")
            return shotW, pw
        ]])
        local shotW = tonumber(vals[1])
        local pixelW = tonumber(vals[2])
        luassert.is_true(shotW > 0, "area screenshot has no width")
        luassert.is_true(shotW < pixelW,
            string.format("area screenshot was not cropped (%d >= %d)", shotW, pixelW))
        typeCommand("screenshot clear")
    end)

    it("untimed profile runs until reopen, then publishes results", function()
        openDebugger()
        typeCommand("profile")
        local closed = fixture.eventually(fixture.callTimeout, function(): boolean
            if not (context().open as boolean) then return true end
            return nil
        end)
        luassert.is_true(closed == true, "profile did not close the panel to sample")
        fixture.eventually(0.3, function(): boolean return nil end)
        tap()
        local done = fixture.eventually(fixture.callTimeout, function(): boolean
            local c = context()
            local profs = c.profiles as {any}
            if (c.open as boolean) and profs ~= nil and #profs > 0 then return true end
            return nil
        end)
        luassert.is_true(done == true, "reopening did not finish the profile")
        typeCommand("profile clear")
    end)

    it("a game-registered custom command works typed and over MCP", function()
        fixture.runLua(app, [[
            local commands = require("tecs2d.debug.commands")
            commands.register(world, {
                name = "hello",
                shortHelp = "greet a target",
                schema = {
                    args = { who = {default = "world", help = "who to greet"} },
                    positional = {"who"},
                },
                run = function(v)
                    return {ok = true, message = "hello " .. tostring(v.who), data = {who = v.who}}
                end,
            })
            return true
        ]])

        local viaMcp = app.client:call("cmd_hello", {who = "agent"})
        luassert.equals("agent", viaMcp.who as string)
        luassert.equals("hello agent", viaMcp.message as string)

        openDebugger()
        typeCommand("hello bob")
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().message as string) == "hello bob" then return true end
            return nil
        end)
        luassert.is_true(ok == true,
            "typed custom command did not run; message=" .. tostring(context().message))
    end)

    it("draw annotations render on screen and clear over MCP", function()
        -- Earlier tests pan and zoom the camera; restore the identity mapping
        -- (camera at the window center, zoom 1) so world == screen.
        app.client:call("cmd_camera_move", {x = 160, y = 120, r = 0, z = 1})
        app.client:call("cmd_draw_line",
            {x = 20, y = 60, x2 = 120, y2 = 60, r = 1, g = 0, b = 0, a = 1, stroke = 8, tag = "spec"})
        local seen = fixture.eventually(fixture.callTimeout, function(): boolean
            local px = fixture.probePixels(app, {{70 / 320, 60 / 240}})[1]
            if px[1] > 0.5 and px[2] < 0.3 then return true end
            return nil
        end)
        luassert.is_true(seen == true, "annotation line did not render")

        local cleared = app.client:call("cmd_draw_clear", {tag = "spec"})
        luassert.equals(1, tonumber(cleared.cleared))
        local gone = fixture.eventually(fixture.callTimeout, function(): boolean
            local px = fixture.probePixels(app, {{70 / 320, 60 / 240}})[1]
            if px[1] < 0.5 then return true end
            return nil
        end)
        luassert.is_true(gone == true, "cleared annotation still renders")
    end)

    it("entity-pinned annotations die with their entity", function()
        local eid = spawnAt(100, 100)
        app.client:call("cmd_draw_circle", {entity = eid, radius = 12, tag = "pin"})
        local function pinned(): number
            return tonumber(fixture.runLua(app, [[
                local ann = require("tecs2d.debug.internal.annotations")
                local n = 0
                for _, a in ipairs(world.resources[ann.KEY].list) do
                    if a.tag == "pin" then n = n + 1 end
                end
                return n
            ]])[1])
        end
        luassert.equals(1, pinned())
        app.client:call("cmd_despawn", {id = eid})
        local swept = fixture.eventually(fixture.callTimeout, function(): boolean
            if pinned() == 0 then return true end
            return nil
        end)
        luassert.is_true(swept == true, "annotation did not die with its entity")
    end)

    it("ids toggles the id-label flag over MCP", function()
        app.client:call("cmd_ids", {on = true})
        luassert.is_true(context().showIds as boolean, "cmd_ids on did not set the flag")
        app.client:call("cmd_ids", {on = false})
        luassert.is_false(context().showIds as boolean, "cmd_ids off did not clear the flag")
    end)

    it("history records typed commands and is readable over MCP", function()
        openDebugger()
        typeCommand("clear")
        typeCommand("mark ls")
        local hist = app.client:call("cmd_history", {})
        local entries = hist.history as {string}
        luassert.is_true(#entries >= 2, "history did not record typed commands")
        luassert.equals("mark ls", entries[#entries])
    end)

    it("get_logs captures engine log lines with filters", function()
        fixture.runLua(app, [[
            require("tecs.utils.logging").getLogger("spec.logs"):info("hello-logs %d", 42)
            return true
        ]])
        local out = app.client:call("get_logs", {contains = "hello-logs"})
        local logs = out.logs as {any}
        luassert.is_true(#logs >= 1, "log line was not captured")
        local last = logs[#logs] as {string: any}
        luassert.equals("INFO", last.level as string)
        luassert.equals("spec.logs", last.logger as string)
        luassert.matches("hello%-logs 42", last.message as string)
    end)

    it("the operator-action feed flows through get_logs with a cursor", function()
        local base = app.client:call("get_logs", {limit = 1})
        local after = tonumber(base.latest)
        local eid = spawnAt(12, 12)
        app.client:call("cmd_select", {id = eid})
        app.client:call("cmd_mark", {name = "evmark"})

        local out = app.client:call("get_logs", {after = after, contains = "debug.events"})
        local sawSelection, sawMark = false, false
        for _, e in ipairs(out.logs as {any}) do
            local msg = (e as {string: any}).message as string
            if msg:find("selection", 1, true) then sawSelection = true end
            if msg:find("mark", 1, true) and msg:find("name=evmark", 1, true) then sawMark = true end
        end
        luassert.is_true(sawSelection, "selection event missing from the log feed")
        luassert.is_true(sawMark, "mark event missing from the log feed")

        local again = app.client:call("get_logs",
            {after = tonumber(out.latest), contains = "debug.events"})
        luassert.equals(0, #(again.logs as {any}), "cursor did not advance past seen lines")
        app.client:call("cmd_mark_clear", {})
    end)

    it("cmd_components_info reports FFI fields and defaults", function()
        local schema = app.client:call("cmd_components_info", {name = "Transform"})
        luassert.equals("ffi", schema.kind as string)
        local byName: {string: string} = {}
        for _, f in ipairs(schema.fields as {any}) do
            local field = f as {string: string}
            byName[field.name] = field.type
        end
        luassert.equals("float", byName.x)
        luassert.equals("int32_t", byName.layer)
        luassert.equals(1, tonumber((schema.defaults as {string: any}).scaleX))

        local unknown = app.client:tryCall("cmd_components_info", {name = "Nope"})
        luassert.is_true(unknown ~= nil and (unknown.ok as boolean) == false,
            "unknown component should error")
    end)

    it("cmd_systems stop/start control a system; cmd_systems_info reports it", function()
        local function frames(): number
            return tonumber(fixture.runLua(app, "return _G.rec.frames")[1])
        end
        local f0 = frames()
        local running = fixture.eventually(fixture.callTimeout, function(): boolean
            if frames() > f0 then return true end
            return nil
        end)
        luassert.is_true(running == true, "frame counter is not running")

        app.client:call("cmd_systems_stop", {name = "test.FrameCounter"})
        local f1 = frames()
        fixture.eventually(0.3, function(): boolean return nil end)
        luassert.equals(f1, frames(), "stopped system still ran")
        local info = app.client:call("cmd_systems_info", {name = "test.FrameCounter"})
        luassert.is_false(info.enabled as boolean)

        app.client:call("cmd_systems_start", {name = "test.FrameCounter"})
        local resumed = fixture.eventually(fixture.callTimeout, function(): boolean
            if frames() > f1 then return true end
            return nil
        end)
        luassert.is_true(resumed == true, "restarted system did not run")
    end)

    it("cmd_camera verbs move, retime, and toggle cameras", function()
        -- The context camera fields are sampled only while the panel is open;
        -- assert against the live pipeline camera instead.
        local function liveCamera(): number, number, number
            local vals = fixture.runLua(app, [[
                local gfx = require("tecs2d.gfx")
                local cam = world.resources[gfx.PIPELINE]:getCamera()
                local x, y = cam:getPosition()
                return x, y, cam:getZoom()
            ]])
            return tonumber(vals[1]), tonumber(vals[2]), tonumber(vals[3])
        end

        app.client:call("cmd_camera_move", {x = 200, y = 90, z = 2})
        local moved = fixture.eventually(fixture.callTimeout, function(): boolean
            local x, _, z = liveCamera()
            if math.abs(x - 200) < 1 and math.abs(z - 2) < 0.01 then return true end
            return nil
        end)
        luassert.is_true(moved == true, "cmd_camera_move did not move the camera")

        -- Partial move: only zoom changes, position keeps its current value.
        app.client:call("cmd_camera_move", {z = 1.5})
        local partial = fixture.eventually(fixture.callTimeout, function(): boolean
            local x, y, z = liveCamera()
            if math.abs(x - 200) < 1 and math.abs(y - 90) < 1 and math.abs(z - 1.5) < 0.01 then
                return true
            end
            return nil
        end)
        luassert.is_true(partial == true, "partial camera move clobbered the position")

        local ts = app.client:call("cmd_camera_timescale", {scale = 0.25})
        luassert.equals(0.25, tonumber(ts.scale))
        local live = fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            return world.resources[gfx.PIPELINE]:getTimeScale()
        ]])[1]
        luassert.equals("0.25", live, "timescale did not apply to the pipeline")
        app.client:call("cmd_camera_timescale", {scale = 1})

        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            world.resources[gfx.PIPELINE]:newCamera("speccam", {})
            return true
        ]])
        local off = app.client:call("cmd_camera_toggle", {name = "speccam"})
        luassert.is_false(off.active as boolean)
        local on = app.client:call("cmd_camera_toggle", {name = "speccam"})
        luassert.is_true(on.active as boolean)
        app.client:call("cmd_camera_toggle", {name = "speccam"})

        app.client:call("cmd_camera_move", {x = 160, y = 120, r = 0, z = 1})
    end)

    it("tab completes arguments, not just command names", function()
        openDebugger()
        app.client:call("send_love_event", {event = "textinput", args = {"query Transf"}})
        fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().command as string) == "query Transf" then return true end
            return nil
        end)
        app.client:call("send_love_event", {event = "keypressed", args = {"tab"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"tab"}})
        local completed = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().command as string) == "query Transform" then return true end
            return nil
        end)
        luassert.is_true(completed == true,
            "tab did not complete the component name; command=" .. tostring(context().command))
        app.client:call("send_love_event", {event = "keypressed", args = {"escape"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"escape"}})
    end)

    it("engine command groups answer over MCP in a live app", function()
        -- Archetypes and components.
        local archs = app.client:call("cmd_archetypes_list", {})
        luassert.is_true(tonumber(archs.count) >= 1, "no archetypes listed")
        local comp = app.client:call("cmd_components_info", {name = "Transform"})
        luassert.equals("ffi", comp.kind as string)

        -- States.
        fixture.runLua(app, "world:createState('LoveSpecState') return true")
        app.client:call("cmd_states_push", {name = "LoveSpecState"})
        local states = app.client:call("cmd_states_info", {})
        luassert.equals("LoveSpecState", states.top as string)
        app.client:call("cmd_states_pop", {})

        -- Layers: hiding layer 1 removes pixels, not just the flag.
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            _G.layerProbe = world:spawn(tecs.builtins.Transform(160, 120, 0, 1),
                gfx.Rectangle(80, 80), gfx.Color(1, 0, 0, 1))
            world:commit()
            return true
        ]])
        local CENTER = {{0.5, 0.5}}
        local function centerRed(): number
            return fixture.probePixels(app, CENTER)[1][1]
        end
        -- Ambient may have been dimmed by earlier tests; assert against a
        -- measured baseline rather than absolute brightness.
        local baseline = 0.0
        local shown = fixture.eventually(fixture.callTimeout, function(): boolean
            baseline = centerRed()
            if baseline > 0.1 then return true end
            return nil
        end)
        luassert.is_true(shown == true, "layer probe rectangle never rendered")
        local toggled = app.client:call("cmd_layers_toggle", {layer = "1"})
        luassert.is_false(toggled.visible as boolean)
        local hidden = fixture.eventually(fixture.callTimeout, function(): boolean
            if centerRed() < baseline * 0.25 then return true end
            return nil
        end)
        luassert.is_true(hidden == true, "layers toggle did not hide the layer's pixels")
        app.client:call("cmd_layers_toggle", {layer = "1"})
        local restored = fixture.eventually(fixture.callTimeout, function(): boolean
            if centerRed() > baseline * 0.75 then return true end
            return nil
        end)
        luassert.is_true(restored == true, "layers toggle did not restore the layer")
        -- `layers all` is the escape hatch: hide again, then reset everything.
        app.client:call("cmd_layers_toggle", {layer = "1"})
        app.client:call("cmd_layers_all", {})
        local allBack = fixture.eventually(fixture.callTimeout, function(): boolean
            if centerRed() > baseline * 0.75 then return true end
            return nil
        end)
        luassert.is_true(allBack == true, "layers all did not restore visibility")
        fixture.runLua(app, "world:despawn(_G.layerProbe) world:commit() return true")
        luassert.is_true((app.client:call("cmd_layers_list", {})).layers ~= nil)
        local layerInfo = app.client:call("cmd_layers_info", {layer = "1"})
        luassert.is_true(layerInfo.visible as boolean)
        luassert.is_not_nil(layerInfo.entities)

        -- Lighting state answers through the info verb.
        luassert.is_not_nil((app.client:call("cmd_light_info", {})).lighting)

        -- Grid and bounds overlays toggle and render without disturbing the app.
        local grid = app.client:call("cmd_grid", {size = 16, offsetX = 3, offsetY = -5})
        luassert.is_true(grid.enabled as boolean)
        luassert.equals(16, tonumber(grid.w))
        luassert.equals(3, tonumber(grid.offsetX))
        luassert.equals(-5, tonumber(grid.offsetY))
        local gridContext = (app.client:call("cmd_context", {})).grid as {string: any}
        luassert.equals(3, tonumber(gridContext.offsetX))
        luassert.equals(-5, tonumber(gridContext.offsetY))
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local image = love.graphics.newImage(love.image.newImageData(8, 8))
            _G.debugBoundsSprite = world:spawn(
                tecs.builtins.Transform(40, 40, 0),
                gfx.Sprite.fromTexture(image)
            )
            world:commit()
            return _G.debugBoundsSprite
        ]])
        app.client:call("cmd_bounds", {})
        luassert.is_true((app.client:call("cmd_context", {})).showBounds as boolean)
        -- Leave bounds enabled long enough for PostRender to inspect SpriteData.
        fixture.eventually(0.3, function(): boolean return nil end)
        luassert.is_true((app.client:call("cmd_context", {})).showBounds as boolean)
        -- Grid origin is (3, -5): tile x = floor((33-3)/16), y = floor((33+5)/16).
        -- No tilemaps in this fixture, so map info uses the grid fallback.
        local tileInfo = app.client:call("cmd_map_info", {x = 33, y = 33})
        luassert.equals(1, tonumber(tileInfo.x), "map info must honor the grid origin on x")
        luassert.equals(2, tonumber(tileInfo.y), "map info must honor the grid origin on y")
        app.client:call("cmd_draw_clear", {tag = "tile"})
        app.client:call("cmd_grid", {on = false})
        app.client:call("cmd_bounds", {on = false})

        -- Physics: empty Box2D world responds to status and probes.
        local phys = app.client:call("cmd_physics_info", {})
        luassert.equals(0, tonumber(phys.bodies))
        local ray = app.client:call("cmd_physics_raycast", {x1 = 0, y1 = 0, x2 = 100, y2 = 100})
        luassert.equals(0, #(ray.hits as {any}))
        app.client:call("cmd_draw_clear", {tag = "physics"})

        -- physics debug installs the drawer plugin on first use.
        app.client:call("cmd_physics_debug", {})
        local drawer = fixture.runLua(app, [[
            local systemcontrol = require("tecs2d.internal.systemcontrol")
            return tostring(systemcontrol.info(world, "tecs2d.gfx.physicsdebug") ~= nil)
        ]])[1]
        luassert.equals("true", drawer, "physics debug did not install the drawer system")
        app.client:call("cmd_physics_debug", {})

        -- Controllers, materials, sprites, assets, audio: status shapes.
        luassert.is_not_nil((app.client:call("cmd_controllers_list", {})).count)
        luassert.is_not_nil((app.client:call("cmd_materials_list", {})).count)
        luassert.is_not_nil((app.client:call("cmd_audio_info", {})).active)
        luassert.is_not_nil((app.client:call("cmd_assets_list", {})).count)

        -- Capabilities and describe answer over MCP.
        local caps = app.client:call("cmd_capabilities", {})
        luassert.is_true((caps.plugins as {string: any}).pipeline as boolean)
        luassert.is_true((caps.plugins as {string: any}).physics as boolean)
        luassert.is_not_nil((caps.mcp as {string: any}).port)
        local described = app.client:call("cmd_describe", {command = "rewind"})
        luassert.is_true(#(described.subcommands as {any}) >= 8)

        -- Agent session reflects the fixture's own MCP port.
        local agent = app.client:call("cmd_agent_info", {})
        luassert.equals(app.client.port, tonumber(agent.port), "agent session port mismatch")
        luassert.is_true(tonumber(agent.tools) > 40, "tool count looks wrong")
    end)

    it("rewind captures a ring, loads the past, and holds while frozen", function()
        local started = app.client:call("cmd_rewind_start", {interval = 0.15, cap = 8})
        luassert.equals(8, tonumber(started.cap))

        -- Let the ring accumulate pre-marker history.
        local preCount = 0
        local pre = fixture.eventually(fixture.callTimeout, function(): boolean
            local rw = (app.client:call("cmd_context", {})).rewind as {string: any}
            preCount = tonumber(rw.count) as integer
            if preCount >= 2 then return true end
            return nil
        end)
        luassert.is_true(pre == true, "ring never accumulated captures")

        -- Spawn a marker, then wait for captures that include it.
        local marker = spawnAt(300, 300)
        local post = fixture.eventually(fixture.callTimeout, function(): boolean
            local rw = (app.client:call("cmd_context", {})).rewind as {string: any}
            if tonumber(rw.count) >= preCount + 2 then return true end
            return nil
        end)
        luassert.is_true(post == true, "ring did not keep capturing after the spawn")

        -- Load the oldest entry: it predates the marker, so the marker dies.
        local count = tonumber(((app.client:call("cmd_context", {})).rewind as {string: any}).count)
        local loaded = app.client:call("cmd_rewind_load", {ref = tostring(count)})
        luassert.is_not_nil(loaded.age)
        local gone = fixture.eventually(fixture.callTimeout, function(): boolean
            local alive = fixture.runLua(app, string.format(
                "return tostring(world:isAlive(%d))", marker))[1]
            if alive == "false" then return true end
            return nil
        end)
        luassert.is_true(gone == true, "rewind load did not restore the pre-marker world")
        local rwAfter = (app.client:call("cmd_context", {})).rewind as {string: any}
        luassert.equals("paused", rwAfter.status as string)

        -- Keep the evidence as a normal snapshot, then resume.
        local kept = app.client:call("cmd_rewind_keep", {ref = "latest", name = "rewind-keep-test.snapshot"})
        luassert.is_not_nil(kept.number)
        app.client:call("cmd_rewind_resume", {})

        -- The freeze controller holds captures: open the debugger, wait past
        -- several intervals, and the count must not move.
        openDebugger()
        local frozenCount = tonumber(((app.client:call("cmd_context", {})).rewind as {string: any}).count)
        fixture.eventually(0.6, function(): boolean return nil end)
        local stillCount = tonumber(((app.client:call("cmd_context", {})).rewind as {string: any}).count)
        luassert.equals(frozenCount, stillCount, "ring captured while frozen")
        tap()
        waitOpen(false)

        app.client:call("cmd_rewind_clear", {})
        app.client:call("cmd_snapshot_clear", {})
        luassert.equals("idle",
            (((app.client:call("cmd_context", {})).rewind as {string: any}).status) as string)
    end)

    it("diff spots a spawned entity between snapshots over MCP", function()
        app.client:call("cmd_snapshot_save", {name = "diff-one.snapshot"})
        local marker = spawnAt(210, 210)
        app.client:call("cmd_snapshot_save", {name = "diff-two.snapshot"})

        local r = app.client:call("cmd_diff",
            {from = "diff-one.snapshot", to = "diff-two.snapshot"})
        luassert.is_true(tonumber((r.summary as {string: any}).entitiesAdded) >= 1,
            "diff missed the spawned entity")
        local found = false
        for _, ch in ipairs(r.changes as {any}) do
            local c = ch as {string: any}
            if tonumber(c.entity) == marker and (c.operation as string) == "add" then
                found = true
            end
        end
        luassert.is_true(found, "spawned entity missing from the change list")

        -- Pointer drill-down against the last diff, then against the artifact.
        local got = app.client:call("cmd_diff_get", {pointer = "/summary/entitiesAdded"})
        luassert.is_true(tonumber(got.value) >= 1)
        local fromFile = app.client:call("cmd_diff_get",
            {pointer = "/totalChanges", ref = "latest"})
        luassert.is_not_nil(fromFile.value)

        -- The live world diffs empty against the snapshot just taken of it.
        local same = app.client:call("cmd_diff", {from = "diff-two.snapshot"})
        luassert.equals(0, tonumber(same.totalChanges), "current should equal the fresh snapshot")

        app.client:call("cmd_diff_clear", {})
        app.client:call("cmd_snapshot_clear", {})
    end)

    it("leader+y yanks the last output to the clipboard", function()
        openDebugger()
        typeCommand("light info")
        local ran = fixture.eventually(fixture.callTimeout, function(): boolean
            if (context().message as string) == "" then return true end
            return nil
        end)
        luassert.is_true(ran == true, "light info errored: " .. tostring(context().message))
        app.client:call("send_love_event", {event = "keypressed", args = {"lctrl"}})
        app.client:call("send_love_event", {event = "keypressed", args = {"y"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"y"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"lctrl"}})
        local yanked = fixture.eventually(fixture.callTimeout, function(): boolean
            local m = context().message as string
            if m ~= nil and m:find("yanked", 1, true) then return true end
            return nil
        end)
        luassert.is_true(yanked == true, "yank never reported; message=" .. tostring(context().message))
        local clip = fixture.runLua(app, "return love.system.getClipboardText()")[1]
        luassert.matches("lighting", clip, "clipboard does not hold the light info output")
    end)

    it("right-click opens the context menu for entities and the world", function()
        -- A spot no earlier test spawned at: underMouse picks the nearest
        -- entity, so neighbors from other tests would steal the menu target.
        local eid = spawnAt(60, 200)
        openDebugger()
        local out = fixture.runLua(app, [[
            local pipelinekey = require("tecs2d.gfx.internal.pipelinekey")
            local cam = world.resources[pipelinekey.PIPELINE]:getCamera()
            local sx, sy = cam:toScreen(60, 200)
            return tostring(sx) .. "," .. tostring(sy)
        ]])[1]
        local sxs, sys = out:match("^(-?[%d%.]+),(-?[%d%.]+)$")
        local sx, sy = tonumber(sxs), tonumber(sys)
        moveCursor(sx, sy)
        app.client:call("send_love_event", {event = "mousepressed", args = {sx, sy, 2}})
        app.client:call("send_love_event", {event = "mousereleased", args = {sx, sy, 2}})
        local opened = fixture.eventually(fixture.callTimeout, function(): boolean
            local m = context().menu as {string: any}
            if m ~= nil and m.open == true and tonumber(m.target) == eid then return true end
            return nil
        end)
        luassert.is_true(opened == true, "entity context menu did not open")

        -- Keyboard: Info(1) -> Select(2) -> Select Only(3), Enter activates.
        for _ = 1, 2 do
            app.client:call("send_love_event", {event = "keypressed", args = {"down"}})
            app.client:call("send_love_event", {event = "keyreleased", args = {"down"}})
        end
        app.client:call("send_love_event", {event = "keypressed", args = {"return"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"return"}})
        local selected = fixture.eventually(fixture.callTimeout, function(): boolean
            local m = context().menu as {string: any}
            if m ~= nil and m.open == false and selectedHas(eid) and #selectedList() == 1 then
                return true
            end
            return nil
        end)
        luassert.is_true(selected == true, "Select Only did not run from the menu")

        -- Empty space: world menu opens, Escape closes without side effects.
        moveCursor(sx + 60, sy - 60)
        app.client:call("send_love_event", {event = "mousepressed", args = {sx + 60, sy - 60, 2}})
        app.client:call("send_love_event", {event = "mousereleased", args = {sx + 60, sy - 60, 2}})
        local worldMenu = fixture.eventually(fixture.callTimeout, function(): boolean
            local m = context().menu as {string: any}
            if m ~= nil and m.open == true and tonumber(m.target) == 0 then return true end
            return nil
        end)
        luassert.is_true(worldMenu == true, "world context menu did not open")
        app.client:call("send_love_event", {event = "keypressed", args = {"escape"}})
        app.client:call("send_love_event", {event = "keyreleased", args = {"escape"}})
        local closed = fixture.eventually(fixture.callTimeout, function(): boolean
            local m = context().menu as {string: any}
            if m ~= nil and m.open == false and (context().open as boolean) then return true end
            return nil
        end)
        luassert.is_true(closed == true, "escape must close the menu, not the debugger")
        fixture.runLua(app, string.format("world:despawn(%d) world:commit() return true", eid))
    end)

    it("typed set, spawn, and remove edit entities with Lua values", function()
        openDebugger()
        typeCommand("spawn Transform {x = 77, y = 33}")
        local id = 0
        local spawned = fixture.eventually(fixture.callTimeout, function(): boolean
            local sel = selectedList()
            if #sel >= 1 then
                id = sel[#sel] as integer
                return true
            end
            return nil
        end)
        luassert.is_true(spawned == true, "spawn did not select the new entity")
        local placed = fixture.eventually(fixture.callTimeout, function(): boolean
            if math.abs(entityX(id) - 77) < 0.01 then return true end
            return nil
        end)
        luassert.is_true(placed == true, "spawned Transform.x is wrong: " .. tostring(entityX(id)))

        typeCommand("set @selection Transform {x = 90}")
        local edited = fixture.eventually(fixture.callTimeout, function(): boolean
            if math.abs(entityX(id) - 90) < 0.01 then return true end
            return nil
        end)
        luassert.is_true(edited == true, "set @selection did not update Transform.x")

        typeCommand("remove " .. tostring(id) .. " Transform")
        local removed = fixture.eventually(fixture.callTimeout, function(): boolean
            local has = fixture.runLua(app, string.format([[
                local tecs = require("tecs")
                return tostring(world:get(%d, tecs.builtins.Transform) ~= nil)
            ]], id))[1]
            if has == "false" then return true end
            return nil
        end)
        luassert.is_true(removed == true, "remove did not strip the component")
    end)
end)
