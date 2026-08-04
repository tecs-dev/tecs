local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local example = require("spec.support.example")

describe("shadows3d example", function()
    it("draws its directional and local-light scene", function()
        example.run("shadows3d", { frames = 2, compact = true }, function(session, render)
            local capture = session:capture()
            render.assertVisible(session, capture.measurement, "shadows3d must draw lit geometry")
            assert.is_true(session.app.renderer.deferred:castsMeshShadows(), "the example did not enable mesh shadows")
        end)
    end)
end)
