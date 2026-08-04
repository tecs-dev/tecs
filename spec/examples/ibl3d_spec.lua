local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local example = require("spec.support.example")

describe("ibl3d example", function()
    it("draws the environment-lit material scene", function()
        example.run("ibl3d", { frames = 2, compact = true }, function(session, render)
            local capture = session:capture()
            render.assertVisible(session, capture.measurement, "ibl3d must draw its environment and meshes")
            assert.is_true(session.app.renderer.meshes.environmentReady, "the example did not install its environment")
        end)
    end)
end)
