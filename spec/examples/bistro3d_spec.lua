local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local example = require("spec.support.example")

describe("bistro3d example", function()
    it("applies the stress-scene configuration to a compact glTF fixture", function()
        example.run("bistro3d", {
            frames = 2,
            compact = true,
            assets = { ["external/bistro/Bistro.tecs.gltf"] = "spec/fixtures/large-scene.gltf" },
            configure = function(config)
                -- Keep the same passes but size their fractional targets for
                -- this 96-pixel fixture rather than the stress-scene window.
                config.bloom.scale = 0.5
                config.meshes.shadows.scale = 1
            end,
            afterInit = function(session)
                local camera = session.app.renderer.meshes.camera
                camera.x, camera.y, camera.z = 0, 0, 3
                camera.rotationX, camera.rotationY, camera.rotationZ, camera.rotationW = 0, 0, 0, 1
            end,
        }, function(session, render)
            local capture = session:capture()
            local deferred = session.app.renderer.deferred
            render.assertVisible(session, capture.measurement, "Bistro configuration must draw the compact fixture")
            assert.is_true(deferred:castsMeshShadows(), "the Bistro configuration lost shadows")
            assert.is_true(deferred._meshFog, "the Bistro configuration lost mesh fog")
            assert.is_true(deferred._meshProbe, "the Bistro configuration lost its ambient probe")
            assert.is_true(deferred._bloom, "the Bistro configuration lost bloom")
        end)
    end)
end)
