-- What a Material means, and that it means the same after a save.
--
-- A material's dispatch id is a position: the default takes zero and every
-- other `materials/*.glsl` name is numbered by sorted order after it. A file
-- appearing ahead of one alphabetically therefore moves its number, so an id
-- written into a snapshot names whichever material the loading build happens
-- to have put in that place, and the scene comes back rendering through a
-- shader nobody asked for with nothing said about it.
--
-- The first two tests are that demonstration. Each adds a material sorting
-- earlier between the save and the load, asserts the id provably moved, and
-- then asserts the entity still draws as what it was saved as. A file
-- carrying the number instead answers the material that took its place, by
-- name, with the load reporting nothing wrong.
--
-- The second is the case that cannot be guessed at. A snapshot naming a
-- material this build does not have is refused, because both of the quiet
-- answers -- fall back to the default, or drop the component -- are the same
-- failure the name is written to prevent.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local components = require("tecs.components")
local materials = require("tecs.gpu.materials")
local shaders = require("tecs.gpu.shaders")

local Material = components.Material

--- A material body, enough of one for the dispatch to compile around.
local function body(marker)
    return table.concat({
        "MaterialOutput material(MaterialInput frag) {",
        "    // " .. marker,
        "    MaterialOutput out;",
        "    out.albedo = frag.tint;",
        "    out.coverage = 1.0;",
        "    return out;",
        "}",
    }, "\n")
end

local function tempDir()
    local path = os.tmpname()
    os.remove(path)
    os.execute("mkdir -p '" .. path .. "'")
    return path .. "/"
end

local function write(path, text)
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
end

--- True when `wanted` appears anywhere inside a nest of tables.
local function holds(value, wanted)
    if value == wanted then return true end
    if type(value) ~= "table" then return false end
    for _, item in pairs(value) do
        if holds(item, wanted) then return true end
    end
    return false
end

describe("material identity across a snapshot", function()
    local dir

    before_each(function()
        dir = tempDir()
        materials.reset()
        materials.addRoot(dir)
    end)

    after_each(function()
        os.remove(dir .. "specmata.glsl")
        os.remove(dir .. "specmatb.glsl")
        os.remove(dir)
        shaders.invalidate()
        materials.reset()
        materials.install()
    end)

    --- Re-reads `dir` from nothing, which is what a rebuild with a different
    --- set of material files looks like from inside the process.
    local function rebuild()
        materials.reset()
        materials.addRoot(dir)
        materials.install()
    end

    it("survives a material added ahead of it alphabetically", function()
        write(dir .. "specmatb.glsl", body("B"))
        materials.install()

        local saved = materials.id("specmatb")
        local world = tecs.newWorld()
        local entity = world:spawn(Material(saved, 0.75))

        local snapshot = world:saveSnapshot({ format = "table" }).snapshot
        assert.is_true(
            holds(snapshot.archetypes, "specmatb"),
            "a snapshot has to carry the name; a number in a file names a position"
        )

        -- The rebuild that breaks a stored number. `specmata` sorts first, so
        -- every material after it moves up one.
        write(dir .. "specmata.glsl", body("A"))
        rebuild()

        local moved = materials.id("specmatb")
        assert.are_not.equal(saved, moved, "the ids have to move or this proves nothing")
        assert.are.equal(
            "specmatb",
            materials.names()[moved + 1],
            "the material that took the saved id is a different one"
        )

        local restored = tecs.newWorld()
        restored:loadSnapshot(snapshot)

        local material = restored:get(entity, Material)
        assert.are.equal(
            "specmatb",
            materials.names()[material.id + 1],
            "the entity draws as whatever the saved number now selects"
        )
        assert.are.equal(moved, material.id)
        assert.are.equal(0.75, material.param)
    end)

    it("survives the same rebuild through the binary format", function()
        write(dir .. "specmatb.glsl", body("B"))
        materials.install()

        local world = tecs.newWorld()
        local entity = world:spawn(Material(materials.id("specmatb"), 0.5))
        local buffer = world:saveSnapshot().buffer

        write(dir .. "specmata.glsl", body("A"))
        rebuild()

        local restored = tecs.newWorld()
        restored:loadSnapshot(buffer)

        local material = restored:get(entity, Material)
        assert.are.equal("specmatb", materials.names()[material.id + 1])
        assert.are.equal(0.5, material.param)
    end)

    it("refuses a snapshot naming a material this build does not have", function()
        write(dir .. "specmatb.glsl", body("B"))
        materials.install()

        local world = tecs.newWorld()
        world:spawn(Material(materials.id("specmatb"), 0.25))
        local snapshot = world:saveSnapshot({ format = "table" }).snapshot

        os.remove(dir .. "specmatb.glsl")
        rebuild()

        local restored = tecs.newWorld()
        local ok, err = pcall(function() restored:loadSnapshot(snapshot) end)

        assert.is_false(ok, "a material the build has lost cannot be guessed at")
        assert.is_truthy(
            tostring(err):find("specmatb", 1, true),
            "the refusal has to name the missing material: " .. tostring(err)
        )
        assert.is_truthy(
            tostring(err):find("loadSnapshot:", 1, true),
            "and read like the load's other refusals: " .. tostring(err)
        )
    end)

    it("keeps the default material for an entity that named none", function()
        write(dir .. "specmatb.glsl", body("B"))
        materials.install()

        local world = tecs.newWorld()
        local entity = world:spawn(Material())
        local snapshot = world:saveSnapshot({ format = "table" }).snapshot

        write(dir .. "specmata.glsl", body("A"))
        rebuild()

        local restored = tecs.newWorld()
        restored:loadSnapshot(snapshot)

        local material = restored:get(entity, Material)
        assert.are.equal(0, material.id, "id zero is what no material means, in any build")
        assert.are.equal(materials.defaultName, materials.name(material.id))
    end)
end)

describe("materials.name", function()
    it("answers the material an id dispatches to", function()
        materials.install()
        local names = materials.names()
        for id = 0, #names - 1 do
            assert.are.equal(names[id + 1], materials.name(id))
        end
        assert.are.equal(materials.defaultName, materials.name(0))
    end)

    it("answers nil for an id nothing has", function()
        materials.install()
        assert.is_nil(materials.name(#materials.names()))
        assert.is_nil(materials.name(-1))
    end)
end)

describe("materials.find", function()
    it("answers the id without raising on a name nothing has", function()
        materials.install()
        assert.are.equal(0, materials.find(materials.defaultName))
        assert.is_nil(materials.find("specmatnothing"))
    end)
end)
