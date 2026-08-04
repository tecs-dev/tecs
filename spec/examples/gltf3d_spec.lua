local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local example = require("spec.support.example")

describe("gltf3d example", function()
    it("loads and draws repository-owned glTF geometry", function()
        example.run("gltf3d", { frames = 2, compact = true }, function(session, render)
            local capture = session:capture()
            render.assertVisible(session, capture.measurement, "gltf3d must draw its loaded model")
            assert.is_true(session.app.renderer.meshes.meshCount > 0, "no glTF mesh reached the renderer")
        end)
    end)
end)
