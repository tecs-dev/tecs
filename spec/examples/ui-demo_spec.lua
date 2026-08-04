local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local example = require("spec.support.example")

describe("ui-demo example", function()
    it("draws a changing interface through the application lifecycle", function()
        example.run("ui-demo", { frames = 2 }, function(session, render)
            local first = session:capture()
            render.assertVisible(session, first.measurement, "ui-demo must draw its interface")
            session:advance(12)
            local second = session:capture()
            render.assertChanged(
                session,
                render.difference(first.texture, first.pixels, second.pixels, nil, 2),
                0.0005,
                "ui-demo animation must reach the composited target"
            )
        end)
    end)
end)
