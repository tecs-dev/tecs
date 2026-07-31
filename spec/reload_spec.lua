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
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local cjson = require("cjson")
local shaders = require("tecs.gpu.shaders")
local files = require("tecs.io.files")
local materials = require("tecs.gpu.materials")
local mcp = require("tecs.io.mcp")
local tools = require("tecs.io.mcp.tools")
local assets = require("tecs.assets")

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
        assert.is_truthy(source:find("SECOND", 1, true), "the dispatch still holds the source read at install")
        assert.is_falsy(source:find("FIRST", 1, true))
        assert.are.equal(before, materials.id("specreload"), "an edit must not move what an instance selects")
    end)

    it("refuses a material that was not there at install", function()
        local before = materials.id("specreload")
        local names = materials.names()

        write(dir .. "specreloadtwo.glsl", body("ADDED"))
        local reloaded, reason = materials.reload()

        assert.is_false(reloaded)
        assert.is_truthy(
            reason:find("specreloadtwo", 1, true),
            "the refusal must name what changed: " .. tostring(reason)
        )

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
        assert.is_truthy(
            shaders.source("specreload.frag"):find("FIRST", 1, true),
            "a resolved source is cached, which is what makes a reload a step"
        )

        shaders.invalidate()
        assert.is_truthy(shaders.source("specreload.frag"):find("SECOND", 1, true))
    end)
end)

describe("mcp reload_shaders", function()
    local rebuilt

    local function callTool()
        local response = cjson.decode(mcp.dispatch(cjson.encode({
            jsonrpc = "2.0",
            id = 1,
            method = "tools/call",
            params = { name = "reload_shaders", arguments = {} },
        })))
        local result = response.result
        local text = result.content and result.content[1] and result.content[1].text or ""
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
        assert.is_truthy(text:find("no shader rebuild is registered", 1, true), "unexpected refusal: " .. text)
    end)

    it("re-reads the sources and rebuilds once", function()
        tools.bindReload(function()
            rebuilt = rebuilt + 1
        end)

        local ok, result, text = callTool()
        assert.is_true(ok, text)
        assert.are.equal(1, rebuilt)

        local names = {}
        for _, name in ipairs(result.materials) do
            names[name] = true
        end
        assert.is_true(names[materials.defaultName])
    end)

    it("does not rebuild when the material set has changed", function()
        local dir = tempDir()
        materials.reset()
        materials.addRoot(dir)
        materials.install()
        write(dir .. "specreloadadded.glsl", body("ADDED"))
        tools.bindReload(function()
            rebuilt = rebuilt + 1
        end)

        local ok, _, text = callTool()
        os.remove(dir .. "specreloadadded.glsl")
        os.remove(dir)

        assert.is_false(ok)
        assert.is_truthy(text:find("specreloadadded", 1, true), "unexpected refusal: " .. text)
        assert.are.equal(0, rebuilt, "the pipelines were rebuilt from a set that renumbered")
    end)
end)

-- The image half of the same operation. Writing the pixels needs a device and
-- is asserted on in the renderer's own specs; what is here is the tool's own
-- share of it, which is deciding what may be reloaded at all and handing a
-- decoded file over exactly once.
describe("mcp reload_image", function()
    local FIXTURE = "spec/fixtures/split.png"
    local handed

    local function callTool(arguments)
        local response = cjson.decode(mcp.dispatch(cjson.encode({
            jsonrpc = "2.0",
            id = 1,
            method = "tools/call",
            params = { name = "reload_image", arguments = arguments },
        })))
        local result = response.result
        local text = result.content and result.content[1] and result.content[1].text or ""
        return result.isError ~= true, result.structuredContent, text
    end

    -- A renderer that records rather than uploads, so the region it answers
    -- with is the test's to choose and the reported layer can be told apart
    -- from a default.
    local function stub(region)
        return {
            replaceImage = function(_, handle)
                handed = { path = handle.path, width = handle.width, height = handle.height }
                handle:release()
                return nil, region
            end,
        }
    end

    before_each(function()
        handed = nil
        tools.bind(nil, nil)
        assets.install()
    end)

    after_each(function()
        assets.shutdown()
        tools.bind(nil, nil)
    end)

    it("refuses when nothing is bound to upload into", function()
        local ok, _, text = callTool({ path = FIXTURE })
        assert.is_false(ok)
        assert.is_truthy(text:find("no renderer is bound", 1, true), "unexpected refusal: " .. text)
        assert.is_nil(handed)
    end)

    it("refuses a path with no file behind it", function()
        tools.bind(stub({ layer = 0, width = 4, height = 4 }), nil)

        local ok, _, text = callTool({ path = "spec/fixtures/nothing.png" })
        assert.is_false(ok)
        assert.is_truthy(text:find("did not load", 1, true), "unexpected refusal: " .. text)
        assert.is_nil(handed, "a file that did not decode must not reach the array")
    end)

    it("refuses a call that names no path", function()
        tools.bind(stub({ layer = 0, width = 4, height = 4 }), nil)

        local ok, _, text = callTool({})
        assert.is_false(ok)
        assert.is_truthy(text:find("path is required", 1, true), "unexpected refusal: " .. text)
    end)

    it("hands the decoded file over and reports where it went", function()
        tools.bind(stub({ layer = 3, width = 4, height = 4 }), nil)

        local ok, result, text = callTool({ path = FIXTURE })
        assert.is_true(ok, text)
        assert.are.same({ path = FIXTURE, width = 4, height = 4 }, handed)
        assert.are.equal(3, result.layer, "the layer reported is the one the image already held")
        assert.are.equal(FIXTURE, result.path)
    end)
end)

-- The watcher's switch, which is the tool an agent reaches for rather than a
-- fifth reload: what it turns on is the four above happening without being
-- asked. The watcher's own behavior is asserted in `watch_spec`; what is here
-- is that the tool reports it, steps it, and stops it.
describe("mcp watch", function()
    local watcher = require("tecs.io.watcher")

    local function callTool(arguments)
        local response = cjson.decode(mcp.dispatch(cjson.encode({
            jsonrpc = "2.0",
            id = 1,
            method = "tools/call",
            params = { name = "watch", arguments = arguments },
        })))
        local result = response.result
        local text = result.content and result.content[1] and result.content[1].text or ""
        return result.isError ~= true, result.structuredContent, text
    end

    local dir, contentRoot

    -- The tool takes no root, so it watches the content root. Pointing that at
    -- a temp directory is what keeps this to its own files, and putting it back
    -- here rather than at the end of a case is what stops a failure leaking it
    -- into every later spec.
    before_each(function()
        dir = tempDir()
        contentRoot = files.assetRoot()
        files.setAssetRoot(dir)
        watcher.uninstall()
    end)

    after_each(function()
        files.setAssetRoot(contentRoot)
        watcher.uninstall()
        watcher.on("shader", nil)
        os.execute("rm -rf '" .. dir .. "'")
    end)

    it("reports that nothing is being watched", function()
        local ok, result, text = callTool({})
        assert.is_true(ok, text)
        assert.is_false(result.watching)
        assert.are.equal(0, result.files)
    end)

    it("starts, steps and stops the watcher", function()
        write(dir .. "watched.frag.glsl", "#version 450\n// FIRST\n")
        assert.is_string(files.read(dir .. "watched.frag.glsl"))

        local reloaded = 0
        watcher.on("shader", function()
            reloaded = reloaded + 1
        end)

        local ok, result, text = callTool({ enabled = true })
        assert.is_true(ok, text)
        assert.is_true(result.watching)
        assert.are.equal(1, result.files)
        assert.are.same({ dir .. "watched.frag.glsl" }, result.paths)

        write(dir .. "watched.frag.glsl", "#version 450\n// SECOND, longer\n")
        local _, pending = callTool({ poll = true })
        assert.are.equal(0, pending.reloaded, "a change was acted on before it settled")
        assert.are.same({ dir .. "watched.frag.glsl" }, pending.unsettled)

        local _, settled = callTool({ poll = true })
        assert.are.equal(1, settled.reloaded)
        assert.are.equal(1, settled.dispatched)
        assert.are.equal(1, reloaded)

        local _, stopped = callTool({ enabled = false })
        assert.is_false(stopped.watching)
        assert.are.equal(0, stopped.files)
    end)
end)

-- The whole operation, driven the way an agent drives it: a real application
-- with a device behind it and a tool call over the dispatcher. What this pins
-- that neither half above can is that the application hands its renderer to the
-- tool at all, so the refusal the first describe checks for is not what a
-- running game answers with.
describe("reload_shaders against a running application", function()
    local Application = require("tecs.Application")
    local watcher = require("tecs.io.watcher")

    it("rebuilds the pipelines of the application that is running", function()
        local app = Application.newApplication({
            window = { title = "reload", width = 64, height = 64 },
            -- Binding the tools is what registering a port turns on, and the
            -- reload is registered beside them.
            mcpPort = 7137,
        })
        assert.is_true(app:_init())
        app:_iterate(nil, 0, nil)

        local response = cjson.decode(mcp.dispatch(cjson.encode({
            jsonrpc = "2.0",
            id = 1,
            method = "tools/call",
            params = { name = "reload_shaders", arguments = {} },
        })))
        local result = response.result
        local text = result.content and result.content[1] and result.content[1].text or ""

        -- A frame after the swap, because a rebuild that left a pipeline
        -- released and not replaced is only visible in the next one.
        local drawn = app:_iterate(nil, 0, nil)
        app:_shutdown()
        tools.bind(nil, nil)
        tools.bindReload(nil)
        restore()

        assert.is_falsy(result.isError, "the reload was refused: " .. text)
        assert.is_true(drawn, "the frame after the rebuild did not run")
    end)

    -- A watcher asked for in the config has to be running by the first
    -- iteration and gone by the last, and the reloaders it routes to have to be
    -- registered without a port being opened: an edit picked up is worth having
    -- whether or not a debug server was wanted.
    it("runs the watcher an application was configured with", function()
        local app = Application.newApplication({
            window = { title = "watch", width = 64, height = 64 },
            watch = { intervalSeconds = 0 },
        })
        assert.is_true(app:_init())

        assert.is_true(watcher.isInstalled(), "the watcher the config asked for is not running")
        local kinds = {}
        for _, kind in ipairs(watcher.kinds()) do
            kinds[kind] = true
        end
        assert.is_true(kinds.shader, "no reloader owns a changed shader")
        assert.is_true(kinds.image, "no reloader owns a changed image")
        assert.is_true(kinds.sound, "no reloader owns a changed sound")

        -- The engine's own shaders are read through `assets`, so a run that has
        -- drawn a frame is already watching them.
        app:_iterate(nil, 0, nil)
        assert.is_true(#watcher.watching() > 0, "a run that has drawn is watching nothing")

        app:_shutdown()
        assert.is_false(watcher.isInstalled(), "the watcher outlived the application")
        tools.bind(nil, nil)
        tools.bindReload(nil)
        restore()
    end)
end)
