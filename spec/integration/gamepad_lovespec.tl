--- Love2D integration suite: gamepad input via an SDL3 virtual device.
--- LÖVE 12 bundles SDL3 (ABI-stable since 3.2), whose virtual joystick
--- API creates a device indistinguishable from real hardware at every
--- layer above SDL. A LuaJIT FFI shim attaches a virtual gamepad from
--- inside the fixture app and puppets its buttons and axes, covering
--- hotplug events, gamepad button/axis event flow into the input module,
--- controller bindings, deadzones, and detach.
---
--- Run via `make test-love FILE_MATCH='gamepad'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("spec.integration.harness.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

-- FFI shim installed into the app. SDL_AttachVirtualJoystick copies the
-- descriptor (and strdups the name), so no cdata needs to outlive the
-- call. type 1 = SDL_JOYSTICK_TYPE_GAMEPAD: SDL maps the device's
-- buttons/axes 1:1 onto SDL_GamepadButton/SDL_GamepadAxis indices and
-- provides the gamepad mapping automatically.
local SHIM <const> = [[
    local ffi = require("ffi")
    ffi.cdef([=[
        typedef struct SDL_VirtualJoystickDesc {
            uint32_t version;
            uint16_t type;
            uint16_t padding;
            uint16_t vendor_id;
            uint16_t product_id;
            uint16_t naxes;
            uint16_t nbuttons;
            uint16_t nballs;
            uint16_t nhats;
            uint16_t ntouchpads;
            uint16_t nsensors;
            uint16_t padding2[2];
            uint32_t button_mask;
            uint32_t axis_mask;
            const char *name;
            const void *touchpads;
            const void *sensors;
            void *userdata;
            void *Update;
            void *SetPlayerIndex;
            void *Rumble;
            void *RumbleTriggers;
            void *SetLED;
            void *SendEffect;
            void *SetSensorsEnabled;
            void *Cleanup;
        } SDL_VirtualJoystickDesc;
        typedef struct SDL_Joystick SDL_Joystick;
        int SDL_GetVersion(void);
        const char* SDL_GetError(void);
        uint32_t SDL_AttachVirtualJoystick(const SDL_VirtualJoystickDesc *desc);
        bool SDL_DetachVirtualJoystick(uint32_t instance_id);
        SDL_Joystick* SDL_GetJoystickFromID(uint32_t instance_id);
        bool SDL_SetJoystickVirtualButton(SDL_Joystick *joystick, int button, bool down);
        bool SDL_SetJoystickVirtualAxis(SDL_Joystick *joystick, int axis, int16_t value);
    ]=])
    local sdl = ffi.C

    local pad = {}
    function pad.attach()
        local desc = ffi.new("SDL_VirtualJoystickDesc")
        desc.version = ffi.sizeof("SDL_VirtualJoystickDesc")
        desc.type = 1
        desc.naxes = 6
        desc.nbuttons = 15
        desc.name = "Tecs Virtual Pad"
        local id = sdl.SDL_AttachVirtualJoystick(desc)
        if id == 0 then
            error("SDL_AttachVirtualJoystick failed: " .. ffi.string(sdl.SDL_GetError()))
        end
        pad.id = id
        return id
    end
    function pad.handle()
        local h = sdl.SDL_GetJoystickFromID(pad.id)
        if h == nil then error("virtual joystick not opened yet") end
        return h
    end
    function pad.button(index, down)
        if not sdl.SDL_SetJoystickVirtualButton(pad.handle(), index, down) then
            error("SDL_SetJoystickVirtualButton failed: " .. ffi.string(sdl.SDL_GetError()))
        end
    end
    function pad.axis(index, value)
        if not sdl.SDL_SetJoystickVirtualAxis(pad.handle(), index, value) then
            error("SDL_SetJoystickVirtualAxis failed: " .. ffi.string(sdl.SDL_GetError()))
        end
    end
    function pad.detach()
        sdl.SDL_DetachVirtualJoystick(pad.id)
    end
    _G.tecsPad = pad
    return sdl.SDL_GetVersion()
]]

-- SDL_GamepadButton / SDL_GamepadAxis indices used below
local BUTTON_A <const> = 0
local AXIS_LEFTX <const> = 0

local function rec(app: fixture.App, field: string): number
    local values = fixture.runLua(app, "return _G.tecsPadRec." .. field)
    return tonumber(values[1])
end

local function waitRec(app: fixture.App, field: string, check: function(number): boolean, label: string)
    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        if check(rec(app, field)) then return true end
        return nil
    end)
    luassert.is_true(ok == true, string.format(
        "%s: %s = %s", label, field, tostring(rec(app, field))))
end

describe("gamepad: virtual SDL3 device end to end", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        local versionValues = fixture.runLua(app, SHIM)
        local sdlVersion = tonumber(versionValues[1])
        luassert.is_number(sdlVersion, "SDL shim failed to load")
        luassert.is_true(sdlVersion >= 3002000, "SDL older than 3.2: " .. tostring(sdlVersion))

        -- Recorder + controller with gamepad bindings + hotplug counters.
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local tecs2d = require("tecs2d")
            local controller = require("tecs2d.controller")
            local manager = world.resources[controller]
            _G.tecsGamepadCtrl = manager:addController({
                controls = {
                    jump = {"button:a"},
                    moveRight = {"axis:leftx+"},
                    move = {"axis:leftx"},
                },
            }, {auto = true, deadzone = 0.25})

            _G.tecsPadRec = {
                added = 0, removed = 0,
                jumpPressed = 0, jumpReleased = 0, jumpDownFrames = 0,
                moveRaw = 0, moveRightRaw = 0,
            }
            local r = _G.tecsPadRec
            world:observe(0, tecs2d.JoystickAdded, function()
                r.added = r.added + 1
            end)
            world:observe(0, tecs2d.JoystickRemoved, function()
                r.removed = r.removed + 1
            end)
            world:addSystem({
                name = "test.PadRecorder",
                phase = tecs.phases.Update,
                run = function()
                    local ctrl = _G.tecsGamepadCtrl
                    if ctrl:isPressed("jump") then r.jumpPressed = r.jumpPressed + 1 end
                    if ctrl:isReleased("jump") then r.jumpReleased = r.jumpReleased + 1 end
                    if ctrl:isDown("jump") then r.jumpDownFrames = r.jumpDownFrames + 1 end
                    r.moveRaw = ctrl:getRaw("move")
                    r.moveRightRaw = ctrl:getRaw("moveRight")
                end,
            })
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("attaching the virtual pad fires JoystickAdded and auto-assigns", function()
        fixture.runLua(app, "_G.tecsPad.attach() return true")
        waitRec(app, "added", function(n: number): boolean return n == 1 end,
            "JoystickAdded should fire once")

        local values = fixture.runLua(app, [[
            local ctrl = _G.tecsGamepadCtrl
            local js = ctrl.joystick
            return tostring(js ~= nil), js and tostring(js:isGamepad()) or "nil"
        ]])
        luassert.equals("true", values[1], "controller never auto-assigned the virtual pad")
        luassert.equals("true", values[2], "virtual pad should register as a gamepad")
    end)

    it("a gamepad button press drives the bound action edge", function()
        fixture.runLua(app, string.format("_G.tecsPad.button(%d, true) return true", BUTTON_A))
        waitRec(app, "jumpPressed", function(n: number): boolean return n == 1 end,
            "jump press edge from button:a")

        local d1 = rec(app, "jumpDownFrames")
        local held = fixture.eventually(fixture.callTimeout, function(): boolean
            if rec(app, "jumpDownFrames") > d1 then return true end
            return nil
        end)
        luassert.is_true(held == true, "jump should stay down while the button is held")

        fixture.runLua(app, string.format("_G.tecsPad.button(%d, false) return true", BUTTON_A))
        waitRec(app, "jumpReleased", function(n: number): boolean return n == 1 end,
            "jump release edge")
        luassert.equals(1, rec(app, "jumpPressed"), "jump edge fired more than once")
    end)

    it("axis values pass through with the deadzone applied", function()
        -- Full deflection: raw ~ 1.0 on both the raw and directional bindings.
        fixture.runLua(app, string.format("_G.tecsPad.axis(%d, 32767) return true", AXIS_LEFTX))
        waitRec(app, "moveRaw", function(n: number): boolean return n > 0.95 end,
            "full deflection should read ~1")
        waitRec(app, "moveRightRaw", function(n: number): boolean return n > 0.95 end,
            "directional binding should read ~1")

        -- Below the 0.25 deadzone: exactly 0.
        fixture.runLua(app, string.format("_G.tecsPad.axis(%d, 3277) return true", AXIS_LEFTX))
        waitRec(app, "moveRaw", function(n: number): boolean return n == 0 end,
            "sub-deadzone deflection should read exactly 0")

        -- Negative full deflection: raw -1, directional positive stays 0.
        fixture.runLua(app, string.format("_G.tecsPad.axis(%d, -32768) return true", AXIS_LEFTX))
        waitRec(app, "moveRaw", function(n: number): boolean return n < -0.95 end,
            "negative deflection should read ~-1")
        luassert.equals(0, rec(app, "moveRightRaw"),
            "positive directional binding should ignore negative deflection")

        fixture.runLua(app, string.format("_G.tecsPad.axis(%d, 0) return true", AXIS_LEFTX))
    end)

    it("detaching fires JoystickRemoved and unassigns the controller", function()
        fixture.runLua(app, "_G.tecsPad.detach() return true")
        waitRec(app, "removed", function(n: number): boolean return n == 1 end,
            "JoystickRemoved should fire once")

        local values = fixture.runLua(app, [[
            return tostring(_G.tecsGamepadCtrl.joystick == nil)
        ]])
        luassert.equals("true", values[1], "controller kept a detached joystick")
    end)
end)
