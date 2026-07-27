-- Re-reading shaders and materials while the process keeps running.
--
-- Two halves, and only the first is here. Re-reading the sources is a file
-- operation with rules attached, and the rules are the part worth testing: a
-- material file appearing renumbers every material after it alphabetically,
-- and a build that links no compiler cannot replace a shader at all. Swapping
-- the pipeline objects afterwards is the device's half and is registered from
-- outside, so what is checked here is that it is called exactly when the rules
-- allow it and never when they do not.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. package.path

local cjson = require("cjson")
local shaders = require("tecs.gpu.shaders")
local materials = require("tecs.gpu.materials")
local mcp = require("tecs.mcp")
local tools = require("tecs.mcp.tools")

--- A material body naming itself, so the dispatch can be read back for it.
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

--- The generated material dispatch, read through a shader that includes it.
local function dispatch()
    shaders.override("spec.dispatch.frag", '#include "materials.glsl"\n')
    local source = shaders.source("spec.dispatch.frag")
    shaders.override("spec.dispatch.frag", nil)
    return source
end

local function restore()
    shaders.override("spec.dispatch.frag", nil)
    shaders.invalidate()
    materials.reset()
    materials.install()
end

describe("material reload", function()
    local dir

    before_each(function()
        dir = tempDir()
        write(dir .. "specreload.glsl", body("FIRST"))
        materials.reset()
        materials.addRoot(dir)
        materials.install()
    end)

    after_each(function()
        os.remove(dir .. "specreload.glsl")
        os.remove(dir .. "specreloadtwo.glsl")
        os.remove(dir)
        restore()
    end)

    it("picks up an edited body without moving any id", function()
        local before = materials.id("specreload")
        assert.is_truthy(dispatch():find("FIRST", 1, true))

        write(dir .. "specreload.glsl", body("SECOND"))
        assert.is_true(materials.reload())

        local source = dispatch()
        assert.is_truthy(source:find("SECOND", 1, true),
            "the dispatch still holds the source read at install")
        assert.is_falsy(source:find("FIRST", 1, true))
        assert.are.equal(before, materials.id("specreload"),
            "an edit must not move what an instance selects")
    end)

    it("refuses a material that was not there at install", function()
        local before = materials.id("specreload")
        local names = materials.names()

        write(dir .. "specreloadtwo.glsl", body("ADDED"))
        local reloaded, reason = materials.reload()

        assert.is_false(reloaded)
        assert.is_truthy(reason:find("specreloadtwo", 1, true),
            "the refusal must name what changed: " .. tostring(reason))

        -- Refused means nothing moved, not that the new file was half taken.
        assert.are.equal(before, materials.id("specreload"))
        assert.are.same(names, materials.names())
        assert.is_falsy(dispatch():find("ADDED", 1, true))
    end)

    it("keeps a material supplied from memory across a re-read", function()
        materials.define("specdefined", body("DEFINED"))
        materials.install()
        local before = materials.id("specdefined")

        assert.is_true(materials.reload())
        assert.are.equal(before, materials.id("specdefined"))
        assert.is_truthy(dispatch():find("DEFINED", 1, true))
    end)
end)

describe("shader source invalidation", function()
    local dir

    setup(function()
        dir = tempDir()
        write(dir .. "specreload.frag.glsl", "#version 450\n// FIRST\n")
        shaders.addRoot(dir)
    end)

    teardown(function()
        os.remove(dir .. "specreload.frag.glsl")
        os.remove(dir)
        shaders.invalidate()
    end)

    it("re-reads a source only once the cache is dropped", function()
        assert.is_truthy(shaders.source("specreload.frag"):find("FIRST", 1, true))

        write(dir .. "specreload.frag.glsl", "#version 450\n// SECOND\n")
        assert.is_truthy(shaders.source("specreload.frag"):find("FIRST", 1, true),
            "a resolved source is cached, which is what makes a reload a step")

        shaders.invalidate()
        assert.is_truthy(shaders.source("specreload.frag"):find("SECOND", 1, true))
    end)
end)

describe("mcp reload_shaders", function()
    local rebuilt

    local function callTool()
        local response = cjson.decode(mcp.dispatch(cjson.encode({
            jsonrpc = "2.0", id = 1, method = "tools/call",
            params = { name = "reload_shaders", arguments = {} },
        })))
        local result = response.result
        local text = result.content and result.content[1]
            and result.content[1].text or ""
        return result.isError ~= true, result.structuredContent, text
    end

    before_each(function()
        rebuilt = 0
        materials.reset()
        materials.install()
    end)

    after_each(function()
        tools.bindReload(nil)
        restore()
    end)

    it("refuses when nothing can rebuild the pipelines", function()
        local ok, _, text = callTool()
        assert.is_false(ok)
        assert.is_truthy(text:find("no shader rebuild is registered", 1, true),
            "unexpected refusal: " .. text)
    end)

    it("re-reads the sources and rebuilds once", function()
        tools.bindReload(function() rebuilt = rebuilt + 1 end)

        local ok, result, text = callTool()
        assert.is_true(ok, text)
        assert.are.equal(1, rebuilt)

        local names = {}
        for _, name in ipairs(result.materials) do names[name] = true end
        assert.is_true(names[materials.defaultName])
    end)

    it("does not rebuild when the material set has changed", function()
        local dir = tempDir()
        materials.reset()
        materials.addRoot(dir)
        materials.install()
        write(dir .. "specreloadadded.glsl", body("ADDED"))
        tools.bindReload(function() rebuilt = rebuilt + 1 end)

        local ok, _, text = callTool()
        os.remove(dir .. "specreloadadded.glsl")
        os.remove(dir)

        assert.is_false(ok)
        assert.is_truthy(text:find("specreloadadded", 1, true),
            "unexpected refusal: " .. text)
        assert.are.equal(0, rebuilt,
            "the pipelines were rebuilt from a set that renumbered")
    end)
end)
