local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local example = require("spec.support.example")

describe("animated3d example", function()
    it("draws and advances its skinned and morphed models", function()
        example.run("animated3d", { frames = 2, compact = true }, function(session, render)
            local first = session:capture()
            render.assertVisible(session, first.measurement, "animated3d must draw its models")
            session:advance(20)
            local second = session:capture()
            render.assertChanged(
                session,
                render.difference(first.texture, first.pixels, second.pixels, nil, 2),
                0.0005,
                "animated glTF state must change rendered pixels"
            )
        end)
    end)
end)
