require("busted")

local luassert <const> = require("luassert")
local inputidentity <const> = require("tecs2d.debug.internal.inputidentity")

-- Characterization: these strings and pairings are what the input tape and
-- the replay recorder each computed for themselves before they shared one
-- table. Both read held state by identity, so the two sides agreeing is the
-- whole point of the module.
describe("tecs2d.debug.internal.inputidentity", function()
    describe("presses", function()
        it("names a key by its key argument", function()
            luassert.equals("key:space", inputidentity.press("keypressed", {"space", "space", false}))
        end)

        it("names a mouse button by its button argument", function()
            luassert.equals("mouse:2", inputidentity.press("mousepressed", {10, 20, 2, false, 1}))
        end)

        it("names a touch by its id argument", function()
            luassert.equals("touch:t1", inputidentity.press("touchpressed", {"t1", 10, 20}))
        end)

        it("returns nil for an event that holds nothing down", function()
            luassert.is_nil(inputidentity.press("mousemoved", {10, 20}))
            luassert.is_nil(inputidentity.press("keyreleased", {"space"}))
            luassert.is_nil(inputidentity.press("wheelmoved", {0, 1}))
        end)
    end)

    describe("releases", function()
        it("names the press it ends", function()
            luassert.equals("key:space", inputidentity.release("keyreleased", {"space", "space"}))
            luassert.equals("mouse:2", inputidentity.release("mousereleased", {10, 20, 2}))
            luassert.equals("touch:t1", inputidentity.release("touchreleased", {"t1", 10, 20}))
        end)

        it("returns nil for an event that releases nothing", function()
            luassert.is_nil(inputidentity.release("keypressed", {"space"}))
            luassert.is_nil(inputidentity.release("mousemoved", {10, 20}))
        end)
    end)

    describe("pairing", function()
        it("gives the release that ends each press", function()
            luassert.equals("keyreleased", inputidentity.pairedRelease("keypressed"))
            luassert.equals("mousereleased", inputidentity.pairedRelease("mousepressed"))
            luassert.equals("touchreleased", inputidentity.pairedRelease("touchpressed"))
        end)

        it("has no release for a non-press", function()
            luassert.is_nil(inputidentity.pairedRelease("mousemoved"))
            luassert.is_nil(inputidentity.pairedRelease("keyreleased"))
        end)

        it("round-trips: a press and its release share one identity", function()
            local cases: {{string, {any}, {any}}} = {
                {"keypressed", {"a", "a", false}, {"a", "a"}},
                {"mousepressed", {1, 2, 3, false, 1}, {1, 2, 3}},
                {"touchpressed", {"id", 1, 2}, {"id", 1, 2}},
            }
            for i = 1, #cases do
                local press, pressArgs, releaseArgs = cases[i][1], cases[i][2], cases[i][3]
                local release = inputidentity.pairedRelease(press)
                luassert.equals(
                    inputidentity.press(press, pressArgs),
                    inputidentity.release(release, releaseArgs),
                    press .. " and " .. release .. " must agree on one identity")
            end
        end)
    end)
end)
