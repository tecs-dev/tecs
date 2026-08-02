--[=[
A free-fly controller turns mouse and keyboard input into a 3D camera pose.

The controller is deliberately a camera tool rather than a character
controller. It has no gravity or collision, so render showcases and editor
views can move through large scenes without creating physics geometry. Click
the left mouse button to enter relative mouse mode, press Tab to release it,
and call `update` from a frame-phase system:

```teal
local controller <const> = tecs.gfx.FlyCamera3D.new(
    app.input,
    app.renderer.meshes.camera,
    {moveSpeed = 5, sprintMultiplier = 4}
)

world:addSystem({
    name = "game.FlyCamera",
    phase = tecs.ecs.phases.Update,
    run = function(dt: number)
        controller:update(dt)
    end,
})
```

WASD moves along the view, Q and E move down and up in world space, and Shift
multiplies the speed. The constructor caches physical scancodes, and `update`
allocates nothing.
]=]

local type input = require("tecs.input")
local type Camera3D = require("tecs.gfx.Camera3D")

local sqrt <const>, asin <const>, atan2 <const> = math.sqrt, math.asin, math.atan2
local sin <const>, cos <const> = math.sin, math.cos
local PI <const>, TAU <const> = math.pi, math.pi * 2.0

--- Defines optional free-fly camera behavior.
local record FlyCamera3DOptions
    --- Caller-writable. Sets ordinary movement speed in world units per second
    --- and defaults to 5.
    moveSpeed: number
    --- Caller-writable. Multiplies movement speed while Shift is held and
    --- defaults to 4.
    sprintMultiplier: number
    --- Caller-writable. Sets radians of rotation per mouse-motion unit and
    --- defaults to 0.0025.
    lookSensitivity: number
    --- Caller-writable. Limits absolute pitch in radians and defaults to 89
    --- degrees.
    maxPitch: number
end

--- Controls one perspective camera with relative mouse and keyboard input.
local record FlyCamera3D
    --- Names the options accepted by `new`.
    type Options = FlyCamera3DOptions

    --- Read-only. Refers to the camera whose pose `update` changes.
    camera: Camera3D
    --- Caller-writable. Sets ordinary movement speed in world units per second.
    moveSpeed: number
    --- Caller-writable. Multiplies movement speed while Shift is held.
    sprintMultiplier: number
    --- Caller-writable. Sets radians of rotation per mouse-motion unit.
    lookSensitivity: number
    --- Caller-writable. Limits absolute pitch in radians below pi divided by two.
    maxPitch: number
    --- Read-only. Reports the current left-right heading in radians.
    yaw: number
    --- Read-only. Reports the current up-down angle in radians.
    pitch: number
    --- Read-only. Reports whether this controller currently owns relative
    --- mouse input.
    captured: boolean

    --- Engine-owned. Retains the input state that `update` reads. Ordinary
    --- game code should ignore this field.
    _input: input.Input
    --- Engine-owned. Caches the physical forward key. Ordinary game code
    --- should ignore this field.
    _forward: integer
    --- Engine-owned. Caches the physical backward key. Ordinary game code
    --- should ignore this field.
    _backward: integer
    --- Engine-owned. Caches the physical left key. Ordinary game code should
    --- ignore this field.
    _left: integer
    --- Engine-owned. Caches the physical right key. Ordinary game code should
    --- ignore this field.
    _right: integer
    --- Engine-owned. Caches the physical down key. Ordinary game code should
    --- ignore this field.
    _down: integer
    --- Engine-owned. Caches the physical up key. Ordinary game code should
    --- ignore this field.
    _up: integer
    --- Engine-owned. Caches the key that releases relative mouse mode.
    --- Ordinary game code should ignore this field.
    _release: integer

    --- Creates a free-fly controller for one camera.
    --- @param source The application [`Input`](tealdoc:tecs.input.Input) remains owned by the application and must
    ---     outlive the controller.
    --- @param camera The perspective [`Camera3D`](tealdoc:tecs.gfx.Camera3D) remains owned by the caller and receives
    ---     pose changes in place.
    --- @param options The caller omits this value to use the documented movement defaults.
    --- @return A controller initialized from the camera's current forward direction.
    new: function(source: input.Input, camera: Camera3D, options?: FlyCamera3DOptions): FlyCamera3D

    --- Requests or releases relative mouse mode.
    --- @param captured The caller passes true to hide and capture the pointer or false to release it.
    --- @return Returns whether the platform reached the requested state.
    setCaptured: function(self, captured: boolean): boolean

    --- Applies this frame's input to the camera.
    ---
    --- A left click captures the pointer and returns without consuming the
    --- absolute motion that produced that click. Tab releases it. While
    --- captured, WASD moves along the view, Q and E move vertically, Shift
    --- sprints, and relative mouse motion changes yaw and pitch.
    --- @param dt The caller supplies a non-negative frame duration in seconds.
    update: function(self, dt: number)
end

local FlyCamera3DMT <const>: metatable<FlyCamera3D> = {__index = FlyCamera3D}

local function checkedOptions(options: FlyCamera3DOptions): number, number, number, number
    local moveSpeed <const> = options.moveSpeed or 5.0
    local sprintMultiplier <const> = options.sprintMultiplier or 4.0
    local lookSensitivity <const> = options.lookSensitivity or 0.0025
    local maxPitch <const> = options.maxPitch or math.rad(89.0)
    if moveSpeed <= 0.0 then
        error("FlyCamera3D moveSpeed must be greater than zero", 3)
    end
    if sprintMultiplier < 1.0 then
        error("FlyCamera3D sprintMultiplier must be at least one", 3)
    end
    if lookSensitivity <= 0.0 then
        error("FlyCamera3D lookSensitivity must be greater than zero", 3)
    end
    if maxPitch <= 0.0 or maxPitch >= PI * 0.5 then
        error("FlyCamera3D maxPitch must be greater than zero and less than pi divided by two", 3)
    end
    return moveSpeed, sprintMultiplier, lookSensitivity, maxPitch
end

function FlyCamera3D.new(source: input.Input, camera: Camera3D, options?: FlyCamera3DOptions): FlyCamera3D
    if source == nil then
        error("FlyCamera3D input is required", 2)
    end
    if camera == nil then
        error("FlyCamera3D camera is required", 2)
    end
    options = options or {}
    local moveSpeed, sprintMultiplier, lookSensitivity, maxPitch = checkedOptions(options)

    local qx, qy, qz, qw = camera.rotationX, camera.rotationY, camera.rotationZ, camera.rotationW
    local magnitude <const> = sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
    if magnitude == 0.0 then
        error("FlyCamera3D camera rotation quaternion must not be zero", 2)
    end
    local inverseMagnitude <const> = 1.0 / magnitude
    qx, qy, qz, qw = qx * inverseMagnitude, qy * inverseMagnitude, qz * inverseMagnitude, qw * inverseMagnitude

    local forwardX <const> = -2.0 * (qx * qz + qy * qw)
    local rawForwardY <const> = 2.0 * (qx * qw - qy * qz)
    local forwardY <const> = math.max(-1.0, math.min(1.0, rawForwardY))
    local forwardZ <const> = -(1.0 - 2.0 * (qx * qx + qy * qy))

    local self = setmetatable({} as FlyCamera3D, FlyCamera3DMT)
    self.camera = camera
    self.moveSpeed = moveSpeed
    self.sprintMultiplier = sprintMultiplier
    self.lookSensitivity = lookSensitivity
    self.maxPitch = maxPitch
    self.yaw = atan2(-forwardX, -forwardZ)
    self.pitch = asin(forwardY)
    self.captured = source:relativeMouseMode()
    self._input = source
    self._forward = source:scancode("w")
    self._backward = source:scancode("s")
    self._left = source:scancode("a")
    self._right = source:scancode("d")
    self._down = source:scancode("q")
    self._up = source:scancode("e")
    self._release = source:scancode("tab")
    return self
end

function FlyCamera3D:setCaptured(captured: boolean): boolean
    local accepted <const> = self._input:setRelativeMouseMode(captured)
    self.captured = self._input:relativeMouseMode()
    return accepted and self.captured == captured
end

local function writeOrientation(self: FlyCamera3D)
    local halfYaw <const>, halfPitch <const> = self.yaw * 0.5, self.pitch * 0.5
    local sinYaw <const>, cosYaw <const> = sin(halfYaw), cos(halfYaw)
    local sinPitch <const>, cosPitch <const> = sin(halfPitch), cos(halfPitch)
    self.camera.rotationX = cosYaw * sinPitch
    self.camera.rotationY = sinYaw * cosPitch
    self.camera.rotationZ = -sinYaw * sinPitch
    self.camera.rotationW = cosYaw * cosPitch
end

function FlyCamera3D:update(dt: number)
    if dt < 0.0 then
        error("FlyCamera3D update dt must not be negative", 2)
    end

    local source <const> = self._input
    if not self.captured and source:mousePressed("left") then
        self:setCaptured(true)
        return
    end
    if self.captured and source:keyPressed(self._release) then
        self:setCaptured(false)
        return
    end

    self.captured = source:relativeMouseMode()
    if not self.captured then
        return
    end

    self.yaw = (self.yaw - source.mouseDeltaX * self.lookSensitivity + PI) % TAU - PI
    self.pitch = math.max(
        -self.maxPitch, math.min(self.maxPitch, self.pitch - source.mouseDeltaY * self.lookSensitivity)
    )
    writeOrientation(self)

    local forward <const> = (source:keyDown(self._forward) and 1 or 0)
        - (source:keyDown(self._backward) and 1 or 0)
    local side <const> = (source:keyDown(self._right) and 1 or 0) - (source:keyDown(self._left) and 1 or 0)
    local vertical <const> = (source:keyDown(self._up) and 1 or 0) - (source:keyDown(self._down) and 1 or 0)
    if forward == 0 and side == 0 and vertical == 0 then
        return
    end

    local cosPitch <const> = cos(self.pitch)
    local forwardX <const>, forwardY <const>, forwardZ <const> = -sin(self.yaw) * cosPitch,
        sin(self.pitch),
        -cos(self.yaw) * cosPitch
    local rightX <const>, rightZ <const> = cos(self.yaw), -sin(self.yaw)
    local moveX <const> = forwardX * forward + rightX * side
    local moveY <const> = forwardY * forward + vertical
    local moveZ <const> = forwardZ * forward + rightZ * side
    local length <const> = sqrt(moveX * moveX + moveY * moveY + moveZ * moveZ)
    if length == 0.0 then
        return
    end
    local speed <const> = self.moveSpeed * (source:modifierDown("shift") and self.sprintMultiplier or 1.0)
    local scale <const> = speed * dt / length
    self.camera.x = self.camera.x + moveX * scale
    self.camera.y = self.camera.y + moveY * scale
    self.camera.z = self.camera.z + moveZ * scale
end

return FlyCamera3D
