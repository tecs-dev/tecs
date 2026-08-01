local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")

describe("render views", function()
    it("exposes a snapshot-safe entity component", function()
        local camera2D = tecs.gfx.newCamera2D({ x = 12, y = 18, zoom = 2 })
        local camera3D = tecs.gfx.newCamera3D({ x = 3, y = 4, z = 5, near = 0.25, far = 90 })
        local view = tecs.gfx.View.new({
            camera2D = camera2D,
            camera3D = camera3D,
            x = 0.5,
            width = 0.5,
            order = 7,
        })

        assert.are.equal("View", tecs.gfx.View.componentName)
        local encoded = tecs.gfx.View.serialize(view)
        local restored = tecs.gfx.View.deserialize(tecs.ecs.newWorld(), encoded)
        assert.are.equal(12, restored.camera2D.x)
        assert.are.equal(5, restored.camera3D.z)
        assert.are.equal(0.5, restored.x)
        assert.are.equal(7, restored.order)
        assert.is_true(restored.enabled)
    end)

    it("rejects empty cameras and viewports outside the frame", function()
        assert.has_error(function()
            tecs.gfx.View.new({})
        end, "tecs: View requires camera2D, camera3D, or both")
        assert.has_error(function()
            tecs.gfx.View.new({ camera2D = tecs.gfx.newCamera2D(), x = 0.75, width = 0.5 })
        end, "tecs: View viewport must be positive and contained within the frame")
    end)
end)
