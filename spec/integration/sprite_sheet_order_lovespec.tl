--- Love2D integration suite: a saved sprite names its sheet, not its slot.
---
--- A sprite's GPU texture-array layer is assigned in registration order, and
--- SpriteData carries that layer as a plain number. If a snapshot were
--- restored by trusting that number, a process that registered its sheets in
--- a different order would draw every restored sprite with someone else's
--- texture.
---
--- This saves in one process and loads in a second that registers the same
--- two sheets in the opposite order, so the layer a sprite needs is not the
--- layer it had. What comes back has to be re-resolved from the sheet the
--- save named.
---
--- Run via `make test-love FILE_MATCH='sprite_sheet_order'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/sprites"
local SAVE_PATH <const> = "sprite-sheet-order.save"

-- Two file-backed sheets, so both survive a save: Sprite refuses to serialize
-- a sheet built from an in-memory image, which has no durable path.
local SHEET_A <const> = "assets/tree-cone.png"
local SHEET_B <const> = "assets/checkered_green.png"

-- SpriteData is internal: it is the GPU-side mirror the sync writes, and the
-- texture-array layer this spec is about lives on it and nowhere public.
local SPRITE_DATA <const> = [[
    local components = require("tecs.internal.components")
    local SpriteData = components.registeredComponents["SpriteData"]
]]

--- Register the two sheets in the given order and return the sprite's slice.
local function registerAndSpawn(app: fixture.App, first: string, second: string): string
    return fixture.runLua(app, [[
        local gfx = require("tecs.gfx")
        _G.tecsOrderFirst = gfx.SpriteSheet.fromTextureFile("]] .. first .. [[")
        _G.tecsOrderSecond = gfx.SpriteSheet.fromTextureFile("]] .. second .. [[")
        return true
    ]])[1]
end

--- The packed texture-array slice a sprite is drawing from, once synced.
local function sliceOf(app: fixture.App, global: string): number
    local values = fixture.runLua(app, SPRITE_DATA .. [[
        local data = world:get(_G.]] .. global .. [[, SpriteData)
        return data ~= nil and data.textureSlice or -1
    ]])
    return tonumber(values[1]) or -1
end

--- Wait until the sprite sync has given the entity a real slice.
local function awaitSynced(app: fixture.App, global: string): boolean
    return fixture.eventually(fixture.callTimeout, function(): boolean
        local values = fixture.runLua(app, SPRITE_DATA .. [[
            local data = world:get(_G.]] .. global .. [[, SpriteData)
            return data ~= nil and data.width > 0
        ]])
        if values[1] == "true" then return true end
        return nil
    end) == true
end

describe("sprite sheets: a save names the sheet, not the slot", function()
    local first: fixture.App
    local second: fixture.App
    local savedSlice = -1
    local savedEntity = ""

    teardown(function()
        if second then
            fixture.runLua(second,
                "love.filesystem.remove('" .. SAVE_PATH .. "') return true")
            fixture.stop(second)
        end
        if first then fixture.stop(first) end
    end)

    it("saves a sprite drawn from the second-registered sheet", function()
        first = fixture.start(APP_DIR)
        fixture.runLua(first,
            "love.filesystem.remove('" .. SAVE_PATH .. "') return true")
        registerAndSpawn(first, SHEET_A, SHEET_B)

        fixture.runLua(first, [[
            local tecs = require("tecs")
            local gfx = require("tecs.gfx")
            _G.tecsOrderSprite = world:spawn(
                tecs.builtins.Transform(40, 40, 0, 1),
                gfx.Sprite.fromSheet(_G.tecsOrderSecond, ""))
            world:commit()
            return true
        ]])
        luassert.is_true(awaitSynced(first, "tecsOrderSprite"),
            "the sprite never synced a slice")

        savedSlice = sliceOf(first, "tecsOrderSprite")
        luassert.is_true(savedSlice >= 0, "no slice was assigned")
        -- A snapshot restores entity ids, so this names the same sprite in
        -- the next process.
        savedEntity = fixture.runLua(first, "return _G.tecsOrderSprite")[1]

        local wrote = fixture.runLua(first, [[
            local snapshot = world:saveSnapshot()
            return love.filesystem.write("]] .. SAVE_PATH .. [[",
                tostring(snapshot.buffer))
        ]])
        luassert.equals("true", wrote[1], "the snapshot was not written")
    end)

    it("re-resolves the slice in a process that registered them the other way", function()
        fixture.stop(first)
        first = nil

        second = fixture.start(APP_DIR)
        -- The opposite order, so the sheet the save names now lands on a
        -- different texture-array layer than it had.
        registerAndSpawn(second, SHEET_B, SHEET_A)

        fixture.runLua(second, [[
            local payload = love.filesystem.read("]] .. SAVE_PATH .. [[")
            if not payload then return "missing save" end
            world:loadSnapshot(payload)
            return true
        ]])

        local found = fixture.runLua(second, [[
            local gfx = require("tecs.gfx")
            _G.tecsOrderSprite = ]] .. savedEntity .. [[
            return world:get(_G.tecsOrderSprite, gfx.Sprite) ~= nil
        ]])
        luassert.equals("true", found[1], "the sprite did not survive the load")
        luassert.is_true(awaitSynced(second, "tecsOrderSprite"),
            "the restored sprite never resynced")

        -- A sprite spawned now from the same sheet is the ground truth for
        -- what layer that sheet occupies in this process.
        fixture.runLua(second, [[
            local tecs = require("tecs")
            local gfx = require("tecs.gfx")
            _G.tecsOrderFresh = world:spawn(
                tecs.builtins.Transform(80, 40, 0, 1),
                gfx.Sprite.fromSheet(_G.tecsOrderFirst, ""))
            world:commit()
            return true
        ]])
        luassert.is_true(awaitSynced(second, "tecsOrderFresh"),
            "the fresh sprite never synced")

        local restored <const> = sliceOf(second, "tecsOrderSprite")
        local fresh <const> = sliceOf(second, "tecsOrderFresh")

        -- Same sheet, so same texture-array layer: the restored sprite
        -- resolved the file the save named to the sheet this process already
        -- loaded, at the layer this process gave it.
        luassert.equals(fresh, restored, string.format(
            "restored sprite is on a different layer than a fresh one from "
            .. "the same file (saved=%s restored=%s fresh=%s)",
            tostring(savedSlice), tostring(restored), tostring(fresh)))
    end)
end)
