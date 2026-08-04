local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local example = require("spec.support.example")

describe("scene3d example", function()
    it("composites both 3D views and the animated scene", function()
        example.run("scene3d", { frames = 2, compact = true }, function(session, render)
            local first = session:capture()
            local width = first.texture.width
            local height = first.texture.height
            render.assertVisible(
                session,
                render.measure(first.texture, first.pixels, { x = 0, y = 0, width = width / 2, height = height }),
                "scene3d left camera must draw"
            )
            render.assertVisible(
                session,
                render.measure(
                    first.texture,
                    first.pixels,
                    { x = width / 2, y = 0, width = width / 2, height = height }
                ),
                "scene3d right camera must draw"
            )
            assert.are.equal(3, #session.app.renderer._views, "the example must retain two 3D views and its HUD")
        end)
    end)
end)
