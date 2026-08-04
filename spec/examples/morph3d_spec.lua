local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local example = require("spec.support.example")

describe("morph3d example", function()
    it("changes the rendered silhouette through morph targets", function()
        example.run("morph3d", { frames = 2, compact = true }, function(session, render)
            local first = session:capture()
            render.assertVisible(session, first.measurement, "morph3d must draw its colored model")
            session:advance(20)
            local second = session:capture()
            render.assertChanged(
                session,
                render.difference(first.texture, first.pixels, second.pixels, nil, 2),
                0.0005,
                "morph playback must change rendered pixels"
            )
        end)
    end)
end)
