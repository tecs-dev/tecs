-- Noclip camera control without a window or physical input devices.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Camera3D = require("tecs.gfx.Camera3D")
local FlyCamera3D = require("tecs.gfx.FlyCamera3D")

local function close(actual, expected)
    assert.is_true(math.abs(actual - expected) < 0.00001, ("expected %.6f, got %.6f"):format(expected, actual))
end

local function fakeInput()
    local codes = {w = 1, s = 2, a = 3, d = 4, q = 5, e = 6, tab = 7}
    local state = {
        mouseDeltaX = 0,
        mouseDeltaY = 0,
        relative = false,
        click = false,
        pressed = {},
        down = {},
        shift = false,
    }
    function state:scancode(name)
        return assert(codes[name])
    end
    function state:relativeMouseMode()
        return self.relative
    end
    function state:setRelativeMouseMode(enabled)
        self.relative = enabled
        return true
    end
    function state:mousePressed(button)
        return button == "left" and self.click
    end
    function state:keyPressed(code)
        return self.pressed[code] == true
    end
    function state:keyDown(code)
        return self.down[code] == true
    end
    function state:modifierDown(name)
        return name == "shift" and self.shift
    end
    return state, codes
end

describe("gfx.FlyCamera3D", function()
    it("moves along the camera's initial forward direction", function()
        local source, keys = fakeInput()
        source.relative = true
        source.down[keys.w] = true
        local camera = Camera3D.newCamera3D({
            x = 6,
            rotationY = math.sin(math.pi * 0.25),
            rotationW = math.cos(math.pi * 0.25),
        })
        local controller = FlyCamera3D.new(source, camera, {moveSpeed = 2})

        controller:update(0.5)

        close(camera.x, 5)
        close(camera.y, 0)
        close(camera.z, 0)
    end)

    it("captures without consuming absolute motion and releases on Tab", function()
        local source, keys = fakeInput()
        source.click = true
        source.mouseDeltaX = 100
        local camera = Camera3D.newCamera3D()
        local controller = FlyCamera3D.new(source, camera, {lookSensitivity = 0.01})

        controller:update(1)
        assert.is_true(controller.captured)
        close(controller.yaw, 0)

        source.click = false
        controller:update(0)
        close(controller.yaw, -1)

        source.pressed[keys.tab] = true
        controller:update(0)
        assert.is_false(controller.captured)
        assert.is_false(source.relative)
    end)

    it("normalizes diagonal movement and applies sprint", function()
        local source, keys = fakeInput()
        source.relative = true
        source.down[keys.w] = true
        source.down[keys.d] = true
        source.shift = true
        local camera = Camera3D.newCamera3D()
        local controller = FlyCamera3D.new(source, camera, {moveSpeed = 2, sprintMultiplier = 3})

        controller:update(0.5)

        close(math.sqrt(camera.x * camera.x + camera.z * camera.z), 3)
        assert.has_error(function()
            controller:update(-0.01)
        end, "FlyCamera3D update dt must not be negative")
    end)
end)
