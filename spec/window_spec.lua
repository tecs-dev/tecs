-- The window surface, against a real window.
--
-- Nothing here is mocked. A window is a negotiation with the window manager
-- and a mock would only prove that the mock agrees with itself, so every
-- setter is driven and read back through SDL.
--
-- Which means the file has to put back what it changes. The window it works on
-- is its own, 64 by 64, and destroyed at the end; the screen saver is the one
-- setting that outlives the process, so it is saved and restored.
--
-- Three things are deliberately not exercised. Actual fullscreen animates for
-- most of a second on a desktop and would take over the display of whoever is
-- running the suite, so the fullscreen *mode* plumbing is driven on a windowed
-- window, which is where SDL records it. Minimizing and maximizing are
-- requests the window manager answers later, so the calls are made and the
-- resulting flags are not asserted on. Keyboard grab asks some desktops for a
-- permission prompt, so it is set and cleared without asserting the desktop
-- agreed.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local sdl = require("tecs.ffi.sdl3")
local loader = require("tecs.ffi.loader")
local events = require("tecs.platform.events")
local Application = require("tecs.Application")
local Window = require("tecs.platform.Window")

local C = sdl.C
local SIZE = 64
local ICON = "spec/fixtures/split.png"

--- Runs `fn` and returns the message it raised, or nil when it did not.
---
--- Used instead of `assert.has_error` wherever the point is *which* complaint
--- was raised: a method that does not exist raises too, and a test that only
--- asked whether something raised would pass against a module missing the
--- whole feature.
local function errorFrom(fn)
    local ok, message = pcall(fn)
    if ok then
        return nil
    end
    return tostring(message)
end

local ORIENTATIONS = {
    unknown = true,
    landscape = true,
    landscapeFlipped = true,
    portrait = true,
    portraitFlipped = true,
}

describe("platform.Window", function()
    local window

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = Window.newWindow({ title = "window", width = SIZE, height = SIZE })
    end)

    teardown(function()
        if window then
            window:destroy()
        end
        C.SDL_Quit()
    end)

    it("reports that there is a video subsystem to ask", function()
        assert.is_true(Window.available())
    end)

    it("names itself with the id events carry", function()
        -- `event.which` on every window event is this number, so without it
        -- there is no way to tell which window an event was about.
        local id = window:id()
        assert.is_number(id)
        assert.is_true(id > 0, "a live window has a non-zero id")
    end)

    it("waits for pending changes rather than guessing", function()
        assert.is_boolean(window:sync())
    end)

    ---------------------------------------------------------------- geometry

    it("resizes and reads the size back", function()
        assert.is_true(window:setSize(80, 96))
        window:sync()
        local width, height = window:getSize()
        assert.are.equal(80, width)
        assert.are.equal(96, height)
        assert.is_true(window:setSize(SIZE, SIZE))
        window:sync()
    end)

    it("separates screen coordinates from pixels without a converter", function()
        local width, height = window:getSize()
        local pixelWidth, pixelHeight = window:getPixelSize()
        local density = window:pixelDensity()

        assert.is_true(density > 0, "a live window has a pixel density")
        assert.are.equal(math.floor(width * density + 0.5), pixelWidth)
        assert.are.equal(math.floor(height * density + 0.5), pixelHeight)

        -- The desktop's scaling preference, which is a different question from
        -- the ratio above and is why there is no single "dpi scale".
        assert.is_true(window:displayScale() > 0)
    end)

    it("moves and reads the position back", function()
        assert.is_true(window:setPosition(120, 140))
        window:sync()
        local x, y = window:position()
        assert.are.equal(120, x)
        assert.are.equal(140, y)
    end)

    it("centers on a display", function()
        assert.is_true(window:center())
        assert.is_true(window:center(window:display()))
        window:sync()
    end)

    it("reports the decoration thickness", function()
        local top, left, bottom, right = window:borderSize()
        assert.is_number(top)
        assert.is_number(left)
        assert.is_number(bottom)
        assert.is_number(right)
        assert.is_true(top >= 0)
    end)

    it("reports the area nothing is drawn over", function()
        -- The whole window on a desktop. The point of asking is the platform
        -- where it is not, and the answer has the same shape on both.
        local width, height = window:getSize()
        local x, y, safeWidth, safeHeight = window:safeArea()
        assert.are.equal(0, x)
        assert.are.equal(0, y)
        assert.are.equal(width, safeWidth)
        assert.are.equal(height, safeHeight)
    end)

    it("constrains how small and how large it may be dragged", function()
        assert.is_true(window:setMinimumSize(32, 48))
        local minWidth, minHeight = window:minimumSize()
        assert.are.equal(32, minWidth)
        assert.are.equal(48, minHeight)

        assert.is_true(window:setMaximumSize(256, 320))
        local maxWidth, maxHeight = window:maximumSize()
        assert.are.equal(256, maxWidth)
        assert.are.equal(320, maxHeight)

        assert.is_true(window:setMinimumSize(0, 0))
        assert.is_true(window:setMaximumSize(0, 0))
    end)

    it("constrains the shape it may be dragged into", function()
        -- Its own window, and destroyed here. Asking AppKit to zoom a window
        -- that has ever carried a content aspect ratio traps inside AppKit, and
        -- clearing the ratio first does not undo it, so a window that has been
        -- given one cannot be handed on to the maximize test above.
        local shaped = Window.newWindow({ title = "shaped", width = SIZE, height = SIZE })
        assert.is_true(shaped:setAspectRatio(1.0, 2.0))
        local minimum, maximum = shaped:aspectRatio()
        assert.are.equal(1.0, minimum)
        assert.are.equal(2.0, maximum)

        assert.is_true(shaped:setAspectRatio(0, 0))
        assert.are.same({ 0, 0 }, { shaped:aspectRatio() })
        shaped:destroy()
    end)

    ------------------------------------------------------------------- state

    it("shows and hides without being destroyed", function()
        assert.is_true(window:isVisible())
        assert.is_true(window:hide())
        assert.is_false(window:isVisible())
        assert.is_true(window:show())
        assert.is_true(window:isVisible())
    end)

    it("answers focus without waiting for an event to fire", function()
        -- The whole reason these are here: a window that has had focus since it
        -- opened has fired neither focus event, so an event-only design cannot
        -- tell the first frame where it stands.
        assert.is_boolean(window:hasFocus())
        assert.is_boolean(window:hasMouseFocus())
        assert.is_boolean(window:isOccluded())
    end)

    it("asks the window manager to change its state", function()
        -- The requests are made and the flags are not read back: a compositor
        -- answers these later and the answer is what the minimized and
        -- maximized events report.
        assert.is_true(window:maximize())
        assert.is_boolean(window:isMaximized())
        assert.is_true(window:restore())
        assert.is_true(window:minimize())
        assert.is_boolean(window:isMinimized())
        assert.is_true(window:restore())
        assert.is_true(window:raise())
    end)

    it("stays windowed and says so", function()
        assert.is_true(window:setFullscreen(false))
        assert.is_false(window:isFullscreen())
    end)

    it("carries a fullscreen mode SDL handed out", function()
        local modes = Window.fullscreenModes()
        assert.is_true(#modes > 0, "a display offers at least one fullscreen mode")

        local chosen = modes[1]
        assert.is_true(window:setFullscreenMode(chosen))
        local read = window:fullscreenMode()
        assert.is_not_nil(read)
        assert.are.equal(chosen.width, read.width)
        assert.are.equal(chosen.height, read.height)

        assert.is_true(window:setFullscreenMode(nil))
        assert.is_nil(window:fullscreenMode())
    end)

    it("refuses a fullscreen mode nobody got from a display", function()
        -- SDL matches the mode against what the display actually offers, so a
        -- record filled in by hand names a resolution that may not exist.
        local message = errorFrom(function()
            window:setFullscreenMode({ width = 1234, height = 567 })
        end)
        assert.is_not_nil(message)
        assert.is_truthy(message:find("Window.fullscreenModes", 1, true))
    end)

    --------------------------------------------------------------- decoration

    it("sets the title and reports the copy back", function()
        assert.is_true(window:setTitle("renamed"))
        assert.are.equal("renamed", window.title)
        assert.is_true(window:setTitle("window"))
    end)

    it("decodes an icon file and hands it over", function()
        assert.is_true(window:setIcon(ICON))
    end)

    it("says nothing was decoded rather than raising", function()
        assert.is_false(window:setIcon("spec/fixtures/no-such-icon.png"))
    end)

    it("adds and removes the frame", function()
        assert.is_true(window:isBordered())
        assert.is_true(window:setBordered(false))
        assert.is_false(window:isBordered())
        assert.is_true(window:setBordered(true))
        assert.is_true(window:isBordered())
    end)

    it("allows and forbids the user resizing it", function()
        assert.is_true(window:isResizable())
        assert.is_true(window:setResizable(false))
        assert.is_false(window:isResizable())
        assert.is_true(window:setResizable(true))
    end)

    it("keeps itself above other windows on request", function()
        assert.is_false(window:isAlwaysOnTop())
        assert.is_true(window:setAlwaysOnTop(true))
        assert.is_true(window:isAlwaysOnTop())
        assert.is_true(window:setAlwaysOnTop(false))
    end)

    it("gives up being focusable on request", function()
        assert.is_true(window:isFocusable())
        assert.is_true(window:setFocusable(false))
        assert.is_false(window:isFocusable())
        assert.is_true(window:setFocusable(true))
    end)

    it("sets how opaque it is", function()
        assert.is_true(window:setOpacity(0.5))
        assert.are.equal(0.5, window:opacity())
        assert.is_true(window:setOpacity(1.0))
        assert.are.equal(1.0, window:opacity())
    end)

    ---------------------------------------------------------------- attention

    it("asks for attention without taking focus", function()
        assert.is_boolean(window:flash("brief"))
        assert.is_boolean(window:flash("cancel"))
    end)

    it("refuses a flash operation it does not have", function()
        local message = errorFrom(function()
            window:flash("blink")
        end)
        assert.is_not_nil(message)
        assert.is_truthy(message:find("unknown flash operation 'blink'", 1, true))
    end)

    it("shows how far along a long piece of work is", function()
        local state, value = window:progress()
        assert.are.equal("none", state)
        assert.are.equal(0, value)

        assert.is_boolean(window:setProgress("normal", 0.5))
        assert.is_boolean(window:setProgress("none"))
    end)

    it("refuses a progress state it does not have", function()
        local message = errorFrom(function()
            window:setProgress("halfway")
        end)
        assert.is_not_nil(message)
        assert.is_truthy(message:find("unknown progress state 'halfway'", 1, true))
    end)

    -------------------------------------------------------------- confinement

    it("confines the pointer to the window", function()
        -- Distinct from relative mouse mode, which is Input's: this leaves the
        -- pointer visible and stops it walking onto another monitor.
        assert.is_false(window:mouseGrab())
        assert.is_true(window:setMouseGrab(true))

        -- A grab exists only while the window has focus. SDL takes the request
        -- either way and reports it as not in force for a window that is not
        -- receiving the pointer, so which of the two answers is right depends
        -- on where focus is, and the suite runs windows in and out of it.
        assert.are.equal(window:hasFocus(), window:mouseGrab())

        assert.is_true(window:setMouseGrab(false))
        assert.is_false(window:mouseGrab())
    end)

    it("confines the pointer to part of the window", function()
        assert.are.same({ 0, 0, 0, 0 }, { window:mouseRect() })
        assert.is_true(window:setMouseRect(4, 8, 16, 32))
        local x, y, width, height = window:mouseRect()
        assert.are.equal(4, x)
        assert.are.equal(8, y)
        assert.are.equal(16, width)
        assert.are.equal(32, height)

        assert.is_true(window:setMouseRect())
        assert.are.same({ 0, 0, 0, 0 }, { window:mouseRect() })
    end)

    it("offers to intercept the desktop's own shortcuts", function()
        assert.is_false(window:keyboardGrab())
        window:setKeyboardGrab(true)
        window:setKeyboardGrab(false)
        assert.is_false(window:keyboardGrab())
    end)

    ---------------------------------------------------------------- displays

    it("enumerates the displays and names them", function()
        local displays = Window.displays()
        assert.is_true(#displays > 0, "an attached display is enumerated")

        local primary = Window.primaryDisplay()
        assert.is_true(primary > 0)

        local found = false
        for _, id in ipairs(displays) do
            if id == primary then
                found = true
            end
        end
        assert.is_true(found, "the primary display is one of the displays")
        assert.is_true(#Window.displayName(primary) > 0)
    end)

    it("reports the desktop dimensions and the part a taskbar leaves", function()
        local x, y, width, height = Window.displayBounds()
        assert.is_number(x)
        assert.is_number(y)
        assert.is_true(width > 0)
        assert.is_true(height > 0)

        local usableX, usableY, usableWidth, usableHeight = Window.usableBounds()
        assert.is_number(usableX)
        assert.is_number(usableY)
        assert.is_true(usableWidth > 0)
        assert.is_true(usableHeight <= height)
    end)

    it("reports a display's content scale", function()
        assert.is_true(Window.contentScale() > 0)
    end)

    it("reports how a display is turned and how it is built", function()
        assert.is_true(ORIENTATIONS[Window.orientation()] == true)
        assert.is_true(ORIENTATIONS[Window.naturalOrientation()] == true)
    end)

    it("reports the display a window is on", function()
        local displayId = window:display()
        assert.is_true(displayId > 0)
        assert.is_true(#Window.displayName(displayId) > 0)
    end)

    it("reports the desktop's mode and the mode in force", function()
        local desktop = Window.desktopMode()
        assert.is_not_nil(desktop)
        assert.is_true(desktop.width > 0)
        assert.is_true(desktop.height > 0)
        assert.is_true(desktop.pixelDensity > 0)
        assert.is_number(desktop.refreshRate)

        local current = Window.currentMode()
        assert.is_not_nil(current)
        assert.is_true(current.width > 0)
    end)

    it("finds the mode nearest a size a player saved", function()
        local mode = Window.closestFullscreenMode(640, 480)
        assert.is_not_nil(mode)
        assert.is_true(mode.width >= 640)
        assert.is_true(mode.height >= 480)
        -- Carries SDL's own mode, so it is a mode `setFullscreenMode` accepts.
        assert.is_true(window:setFullscreenMode(mode))
        assert.is_true(window:setFullscreenMode(nil))
    end)

    ---------------------------------------------------------------- desktop

    it("reports whether the desktop asked for light or dark", function()
        local theme = Window.theme()
        assert.is_true(theme == "unknown" or theme == "light" or theme == "dark")
    end)

    it("allows and forbids the display blanking", function()
        -- The one setting here that outlives the process, so it is put back.
        local saved = Window.screenSaverEnabled()
        assert.is_true(Window.setScreenSaverEnabled(true))
        assert.is_true(Window.screenSaverEnabled())
        assert.is_true(Window.setScreenSaverEnabled(false))
        assert.is_false(Window.screenSaverEnabled())
        Window.setScreenSaverEnabled(saved)
    end)
end)

describe("platform.Window created from options", function()
    local window

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = Window.newWindow({
            title = "options",
            width = SIZE,
            height = SIZE,
            borderless = true,
            hidden = true,
            alwaysOnTop = true,
            minWidth = 32,
            minHeight = 32,
            maxWidth = 512,
            maxHeight = 512,
            icon = ICON,
        })
    end)

    teardown(function()
        if window then
            window:destroy()
        end
        C.SDL_Quit()
    end)

    it("starts unmapped, so nothing half-arranged is ever seen", function()
        assert.is_false(window:isVisible())
    end)

    it("starts with the creation flags it was asked for", function()
        assert.is_false(window:isBordered())
        assert.is_true(window:isAlwaysOnTop())
    end)

    it("starts with the limits it was asked for", function()
        assert.are.same({ 32, 32 }, { window:minimumSize() })
        assert.are.same({ 512, 512 }, { window:maximumSize() })
    end)

    it("keeps the defaults a window has always had", function()
        -- Adding creation flags must not have moved what omitting them means.
        local plain = Window.newWindow({ title = "plain" })
        assert.is_true(plain:isResizable())
        assert.is_true(plain:isVisible())
        assert.is_false(plain:isFullscreen())
        assert.is_true(plain:isBordered())
        assert.are.equal("plain", plain.title)
        local width, height = plain:getSize()
        assert.are.equal(1280, width)
        assert.are.equal(720, height)
        plain:destroy()
    end)
end)

describe("platform.Window once it is destroyed", function()
    local window

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = Window.newWindow({ title = "gone", width = SIZE, height = SIZE })
        window:destroy()
    end)

    teardown(function()
        C.SDL_Quit()
    end)

    it("is safe to destroy again", function()
        window:destroy()
    end)

    it("answers zero rather than the size it used to be", function()
        -- SDL leaves an out-parameter untouched on failure and the buffers are
        -- reused, so a getter that did not check would report whatever the last
        -- window left there.
        assert.are.same({ 0, 0 }, { window:getSize() })
        assert.are.same({ 0, 0 }, { window:getPixelSize() })
        assert.are.same({ 0, 0 }, { window:position() })
        assert.are.same({ 0, 0 }, { window:minimumSize() })
        assert.are.same({ 0, 0 }, { window:maximumSize() })
        assert.are.same({ 0, 0 }, { window:aspectRatio() })
        assert.are.same({ 0, 0, 0, 0 }, { window:safeArea() })
        assert.are.same({ 0, 0, 0, 0 }, { window:borderSize() })
        assert.are.same({ 0, 0, 0, 0 }, { window:mouseRect() })
        assert.are.equal(0, window:id())
        assert.are.equal(0, window:display())
        assert.are.equal(0, window:pixelDensity())
        assert.are.equal(0, window:displayScale())
        assert.are.equal(0, window:opacity())
    end)

    it("answers false rather than claiming a state it no longer has", function()
        assert.is_false(window:isVisible())
        assert.is_false(window:isFullscreen())
        assert.is_false(window:isMinimized())
        assert.is_false(window:isMaximized())
        assert.is_false(window:isOccluded())
        assert.is_false(window:hasFocus())
        assert.is_false(window:hasMouseFocus())
        assert.is_false(window:isResizable())
        assert.is_false(window:isBordered())
        assert.is_false(window:isAlwaysOnTop())
        assert.is_false(window:isFocusable())
        assert.is_false(window:mouseGrab())
        assert.is_false(window:keyboardGrab())
        assert.is_nil(window:fullscreenMode())
        assert.are.same({ "none", 0 }, { window:progress() })
    end)

    it("reports a write as failed rather than pretending", function()
        assert.is_false(window:sync())
        assert.is_false(window:setSize(10, 10))
        assert.is_false(window:setPosition(10, 10))
        assert.is_false(window:center())
        assert.is_false(window:setMinimumSize(1, 1))
        assert.is_false(window:setMaximumSize(1, 1))
        assert.is_false(window:setAspectRatio(1, 1))
        assert.is_false(window:show())
        assert.is_false(window:hide())
        assert.is_false(window:raise())
        assert.is_false(window:minimize())
        assert.is_false(window:maximize())
        assert.is_false(window:restore())
        assert.is_false(window:setFullscreen(true))
        assert.is_false(window:setFullscreenMode(nil))
        assert.is_false(window:setTitle("nowhere"))
        assert.is_false(window:setIcon(ICON))
        assert.is_false(window:setResizable(true))
        assert.is_false(window:setBordered(true))
        assert.is_false(window:setAlwaysOnTop(true))
        assert.is_false(window:setFocusable(true))
        assert.is_false(window:setOpacity(1))
        assert.is_false(window:flash("cancel"))
        assert.is_false(window:setProgress("none"))
        assert.is_false(window:setMouseGrab(true))
        assert.is_false(window:setKeyboardGrab(true))
        assert.is_false(window:setMouseRect(1, 1, 1, 1))
    end)

    it("still reports the title it was last given", function()
        -- The one thing that survives, because it is a Lua string this module
        -- owns rather than something SDL is holding.
        assert.are.equal("nowhere", window.title)
    end)
end)

-- A change made here has to reach the game the same way a change the user made
-- does, or a game that reacts to the event stream would react to one and not
-- the other. SDL raises the same events for both, and this is what proves it:
-- the setter is called and SDL's own queue is read back through the engine's
-- conversion, so what is asserted on is the vocabulary a game sees.
describe("platform.Window changes the event stream reports", function()
    local window
    local holder

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = Window.newWindow({ title = "events", width = SIZE, height = SIZE })
        holder = loader.newArray("SDL_Event[1]")
        -- Whatever opening a window produced, so the first assertion is not
        -- reading the events that created it.
        while C.SDL_PollEvent(holder) ~= false do
        end
    end)

    teardown(function()
        if window then
            window:destroy()
        end
        C.SDL_Quit()
    end)

    -- Waits for one kind about this window. Bounded rather than open-ended:
    -- the window server answers a request when it chooses, so there is nothing
    -- deterministic to drive, and a spec that waited forever would hang the
    -- suite instead of failing it.
    local function await(kind)
        local id = window:id()
        for _ = 1, 200 do
            while C.SDL_PollEvent(holder) ~= false do
                local found
                events.drain(holder, 1, function(event)
                    if event.kind == kind and event.which == id then
                        found = events.copy(event)
                    end
                end)
                if found then
                    return found
                end
            end
            C.SDL_Delay(5)
        end
        return nil
    end

    it("reports a programmatic resize as a resize", function()
        assert.is_true(window:setSize(96, 112))
        local event = await("windowResized")
        assert.is_not_nil(event, "setSize raised no windowResized")
        assert.are.equal(96, event.data1)
        assert.are.equal(112, event.data2)

        local pixels = await("windowPixelSizeChanged")
        assert.is_not_nil(pixels, "setSize raised no windowPixelSizeChanged")
        assert.are.same({ pixels.data1, pixels.data2 }, { window:getPixelSize() })
    end)

    it("reports a programmatic move as a move", function()
        assert.is_true(window:setPosition(160, 180))
        local event = await("windowMoved")
        assert.is_not_nil(event, "setPosition raised no windowMoved")
        assert.are.equal(160, event.data1)
        assert.are.equal(180, event.data2)
    end)

    it("reports hiding and showing", function()
        assert.is_true(window:hide())
        assert.is_not_nil(await("windowHidden"), "hide raised no windowHidden")
        assert.is_true(window:show())
        assert.is_not_nil(await("windowShown"), "show raised no windowShown")
    end)
end)

-- Every window option belongs to the application config as well, because a
-- game does not build its own window: the application does, before the game's
-- load callback runs, and a setting that could only be applied afterwards
-- would be applied to a window somebody had already seen.
describe("Application's window configuration", function()
    local app

    setup(function()
        app = Application.newApplication({
            window = {
                title = "configured",
                width = SIZE,
                height = SIZE,
                hidden = true,
                borderless = true,
                alwaysOnTop = true,
                minWidth = 32,
                minHeight = 48,
                maxWidth = 256,
                maxHeight = 320,
                icon = ICON,
            },
        })
        assert(app:_init())
    end)

    teardown(function()
        app:_shutdown()
    end)

    it("opens the window the configuration asked for", function()
        assert.are.equal("configured", app.window.title)
        assert.are.same({ SIZE, SIZE }, { app.window:getSize() })
        assert.is_false(app.window:isVisible())
        assert.is_false(app.window:isBordered())
        assert.is_true(app.window:isAlwaysOnTop())
        assert.are.same({ 32, 48 }, { app.window:minimumSize() })
        assert.are.same({ 256, 320 }, { app.window:maximumSize() })
    end)
end)

-- Video is brought down the way the clipboard's headless block does it: a
-- matching number of quits is what down means, and the same number of inits
-- restores exactly what was there.
describe("platform.Window with no video", function()
    local held = 0

    setup(function()
        for _ = 1, 8 do
            if sdl.C.SDL_WasInit(sdl.K.SDL_INIT_VIDEO) == 0 then
                break
            end
            sdl.C.SDL_QuitSubSystem(sdl.K.SDL_INIT_VIDEO)
            held = held + 1
        end
    end)

    teardown(function()
        for _ = 1, held do
            assert(sdl.C.SDL_InitSubSystem(sdl.K.SDL_INIT_VIDEO))
        end
    end)

    it("reports that there is nothing to ask", function()
        -- The answer that separates "no displays" from "no video", which no
        -- other return value here can.
        assert.is_false(Window.available())
    end)

    it("answers empty instead of failing", function()
        -- A headless tool is a supported way to run, so asking is allowed and
        -- gets an answer. Nothing raises and nothing claims to have worked.
        assert.are.same({}, Window.displays())
        assert.are.equal(0, Window.primaryDisplay())
        assert.are.equal("", Window.displayName(1))
        assert.are.same({ 0, 0, 0, 0 }, { Window.displayBounds(1) })
        assert.are.same({ 0, 0, 0, 0 }, { Window.usableBounds(1) })
        assert.are.equal(0, Window.contentScale(1))
        assert.are.equal("unknown", Window.orientation(1))
        assert.are.equal("unknown", Window.naturalOrientation(1))
        assert.is_nil(Window.desktopMode(1))
        assert.is_nil(Window.currentMode(1))
        assert.are.same({}, Window.fullscreenModes(1))
        assert.is_nil(Window.closestFullscreenMode(640, 480))
        assert.are.equal("unknown", Window.theme())
        assert.is_false(Window.screenSaverEnabled())
    end)

    it("reports a write as failed rather than pretending", function()
        assert.is_false(Window.setScreenSaverEnabled(true))
    end)
end)
