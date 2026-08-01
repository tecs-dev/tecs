--[=[
A view draws one or both rendering domains into a rectangle of the frame.

Views are entities. Spawn a `View` component to replace the renderer's
synthesized full-frame view, then assign a 2D camera, a 3D camera, or both:

```teal
world:spawn(tecs.gfx.View.new({
    camera3D = tecs.gfx.newCamera3D({x = 0, y = 3, z = 8}),
    x = 0,
    y = 0,
    width = 0.5,
    height = 1,
    order = 0,
}))
```

Viewport coordinates are fractions of the frame. Views draw in ascending
`order`; equal orders use entity id. A view with both cameras composes meshes
then sprites through the normal shared renderer order. A view with only a 2D
camera is the direct way to place a full-frame UI above an earlier 3D view.

The renderer must be created with `maxViews` large enough for the explicit
views. Omitting `maxViews` preserves the original single-view resources and
pass sequence.
]=]

local type types = require("tecs.types")
local ecs <const> = require("tecs.ecs")
local Camera2D <const> = require("tecs.gfx.Camera2D")
local Camera3D <const> = require("tecs.gfx.Camera3D")

--- Describes one ordered viewport and the domain cameras drawn through it.
local record View is types.components.Component
    --- Caller-writable. Selects the 2D camera, or nil to omit sprites.
    camera2D: Camera2D
    --- Caller-writable. Selects the 3D camera, or nil to omit meshes.
    camera3D: Camera3D
    --- Caller-writable. Sets the left edge as a frame fraction and defaults to zero.
    x: number
    --- Caller-writable. Sets the top edge as a frame fraction and defaults to zero.
    y: number
    --- Caller-writable. Sets the width as a frame fraction and defaults to one.
    width: number
    --- Caller-writable. Sets the height as a frame fraction and defaults to one.
    height: number
    --- Caller-writable. Sets composition order and defaults to zero.
    order: integer
    --- Caller-writable. Enables the view and defaults to true.
    enabled: boolean
end

local function camera2DData(camera: Camera2D): {string: any}
    if camera == nil then
        return nil
    end
    return {x = camera.x, y = camera.y, zoom = camera.zoom, rotation = camera.rotation}
end

local function camera3DData(camera: Camera3D): {string: any}
    if camera == nil then
        return nil
    end
    return {
        x = camera.x,
        y = camera.y,
        z = camera.z,
        rotationX = camera.rotationX,
        rotationY = camera.rotationY,
        rotationZ = camera.rotationZ,
        rotationW = camera.rotationW,
        verticalFov = camera.verticalFov,
        near = camera.near,
        far = camera.far,
    }
end

ecs.newComponent({
    -- Compatibility surface: snapshots persist component names independently
    -- of the Lua namespace that exposes them.
    name = "View",
    container = View,
    fields = {"camera2D", "camera3D", "x", "y", "width", "height", "order", "enabled"},
    init = function(view: View)
        view.x = view.x or 0.0
        view.y = view.y or 0.0
        view.width = view.width or 1.0
        view.height = view.height or 1.0
        view.order = view.order or 0
        if view.enabled == nil then
            view.enabled = true
        end
        if view.x < 0.0 or view.y < 0.0 or view.width <= 0.0 or view.height <= 0.0 or view.x + view.width > 1.0
            or view.y + view.height > 1.0
        then
            error("tecs: View viewport must be positive and contained within the frame", 3)
        end
        if view.camera2D == nil and view.camera3D == nil then
            error("tecs: View requires camera2D, camera3D, or both", 3)
        end
    end,
    serialize = function(view: View): {string: any}
        return {
            camera2D = camera2DData(view.camera2D),
            camera3D = camera3DData(view.camera3D),
            x = view.x,
            y = view.y,
            width = view.width,
            height = view.height,
            order = view.order,
            enabled = view.enabled,
        }
    end,
    deserialize = function(_world: types.World, data: {string: any}): View
        return View.new({
            camera2D = data.camera2D ~= nil and Camera2D.newCamera2D(data.camera2D as Camera2D.Options) or nil,
            camera3D = data.camera3D ~= nil and Camera3D.newCamera3D(data.camera3D as Camera3D.Options) or nil,
            x = data.x as number,
            y = data.y as number,
            width = data.width as number,
            height = data.height as number,
            order = data.order as integer,
            enabled = data.enabled as boolean,
        })
    end,
})

return View
