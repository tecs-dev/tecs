local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local example = require("spec.support.example")

describe("sponza3d example", function()
    it("applies the large-scene configuration to a compact glTF fixture", function()
        example.run("sponza3d", {
            frames = 2,
            compact = true,
            assets = { ["external/sponza/Sponza.tecs.gltf"] = "spec/fixtures/large-scene.gltf" },
            afterInit = function(session)
                local camera = session.app.renderer.meshes.camera
                camera.x, camera.y, camera.z = 0, 0, 3
                camera.rotationX, camera.rotationY, camera.rotationZ, camera.rotationW = 0, 0, 0, 1
            end,
        }, function(session, render)
            local capture = session:capture()
            local deferred = session.app.renderer.deferred
            render.assertVisible(session, capture.measurement, "Sponza configuration must draw the compact fixture")
            assert.is_true(deferred:castsMeshShadows(), "the Sponza configuration lost shadows")
            assert.is_true(deferred._meshFog, "the Sponza configuration lost mesh fog")
            assert.is_true(deferred._bloom, "the Sponza configuration lost bloom")
        end)
    end)
end)
