-- `tecs new` produces a project that type-checks.
--
-- This runs the real binary against a real temporary directory, because the
-- property is about what lands on disk rather than about any function.
--
-- **The check here deliberately does not pass `--global-env-def`.** That is the
-- whole point of the spec. `tecs check` passes it as an argument, so the CLI's
-- own path was green while a scaffolded project had 31 type errors in it: every
-- use of the `tecs` global was an unknown variable to anything that was not
-- tecs. An editor, a language server and a bare `tl` read `tlconfig.lua` and
-- nothing else, so that is what is exercised. A check that is green only when
-- one particular program runs it is worse than one that is red, because the
-- red one gets fixed.
--
-- The fix is one key in the scaffolded `tlconfig.lua`, which
-- `src/tecs/global.d.tl` documents for exactly this case.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local files = require("tecs.io.files")
local process = require("tecs.io.Process")

-- Absolute, because every child below is given a working directory of its own
-- and a relative path would then resolve against the scaffolded project rather
-- than against this repository. What that looks like is a child that never
-- starts and a result with no output in it, which reads as a program that ran
-- and printed nothing.
if root:sub(1, 1) ~= "/" then
    root = (files.currentDirectory():gsub("/$", "")) .. "/" .. root
end

--- The directory holding `bin/tecs`, found by walking up from the content root.
---
--- Two layouts and one rule: a build tree has the Lua at `out/<preset>/lua` and
--- an installed one at `<prefix>/share/tecs/lua`, so the binary is one level up
--- in the first and three in the second.
local function findHost()
    local directory = (root:gsub("/$", ""))
    for _ = 1, 6 do
        local handle = io.open(directory .. "/bin/tecs", "r")
        if handle ~= nil then
            handle:close()
            return directory
        end
        local parent = directory:match("^(.*)/[^/]+$")
        if parent == nil or parent == "" or parent == directory then
            break
        end
        directory = parent
    end
    return nil
end

local out = findHost()

--- The engine's Teal type information, which is the content root's sibling in
--- both trees.
local teal = (root:gsub("/$", "")):match("^(.*)/[^/]+$") .. "/teal"

--- Runs the CLI and answers its result.
---
--- Reached through `--entry`, because a build tree and a package both bake in
--- the demo as the default chunk; only the one-file preset bakes in the CLI.
--- The environment is passed rather than inherited, so the child reads the same
--- tree this process was pointed at however the suite was launched.
local function tecs(args, cwd)
    local argv = { out .. "/bin/tecs", "--entry", root .. "/tecscli/init.lua" }
    for _, argument in ipairs(args) do
        argv[#argv + 1] = argument
    end

    local child, startReason = process.new({
        args = argv,
        cwd = cwd,
        env = {
            TECS_LUA = root,
            TECS_LIB = os.getenv("TECS_LIB") or (out .. "/lib"),
            TECS_ASSETS = os.getenv("TECS_ASSETS") or root,
        },
        timeoutMs = 120000,
    })
    assert.is_not_nil(child, startReason)

    -- Both streams, because a compiler splits itself between them: the
    -- diagnostics that matter here land on one and the summary on the other,
    -- and a spec that read only one would report an empty string as a failure.
    local result, communicateReason = child:communicate()
    assert.is_not_nil(result, communicateReason)
    child:close()
    result.output = result.output .. result.errorOutput
    return result
end

--- A temporary directory that does not exist yet.
local function scratch()
    local path = os.tmpname()
    os.remove(path)
    return path
end

local function write(path, body)
    local handle = assert(io.open(path, "w"))
    handle:write(body)
    handle:close()
end

local function read(path)
    local handle = assert(io.open(path, "r"))
    local body = handle:read("*a")
    handle:close()
    return body
end

describe("a scaffolded project", function()
    local directory, project, created

    setup(function()
        directory = scratch()
        project = directory .. "/hello"
        created = tecs({ "new", project })
    end)

    teardown(function()
        if directory ~= nil then
            os.execute("rm -rf '" .. directory .. "'")
        end
    end)

    it("is written out", function()
        assert.is_not_nil(out, "no bin/tecs above " .. root)
        assert.is_not_nil(created, "tecs new never ran")
        assert.are.equal(0, created.exit.exitCode, created.output)

        local manifest = io.open(project .. "/tecs.lua", "r")
        assert.is_not_nil(manifest, "no tecs.lua: " .. created.output)
        manifest:close()
    end)

    -- No `--global-env-def` appears on the command line, so the project's own
    -- tlconfig.lua must supply it.
    it("type-checks the way an editor checks it, with no argument from tecs", function()
        local checked = tecs({ "__teal", "-I", teal, "-I", project .. "/src", "check", "src/main.tl" }, project)
        assert.is_not_nil(checked, "the compiler never ran")
        assert.is_truthy(
            checked.output:find("0 errors detected", 1, true),
            "a fresh project does not type-check on its own:\n" .. checked.output
        )
    end)

    it("type-checks through tecs check", function()
        local checked = tecs({ "check" }, project)
        assert.are.equal(0, checked.exit.exitCode, checked.output)
    end)

    -- Nothing of ours in a user's output. A warning from the engine's own
    -- sources reads as a warning about the game, and the person who sees it
    -- cannot act on it.
    --
    -- Silence rather than an absence of the word, because everything a clean
    -- check could say is something a user cannot act on either: the compiler's
    -- own sign-off offers `tl run` and `tl gen`, and there is no `tl` on their
    -- machine.
    it("says nothing when it is happy", function()
        local checked = tecs({ "check" }, project)
        assert.are.equal("", checked.output, "a clean type-check is not silent:\n" .. checked.output)
    end)

    -- The scaffold draws text, and text needs a font nobody installs. It comes
    -- out of the content root, which is also what a single-file build's
    -- payload is packed from, so a template that draws a string works on a
    -- machine with no assets of its own only while these are in there.
    it("carries the font the template draws with", function()
        for _, name in ipairs({
            "fonts/JetBrainsMono-ExtraBold.ttf",
        }) do
            local handle = io.open(root .. "/" .. name, "r")
            assert.is_not_nil(handle, "the content root carries no " .. name)
            handle:close()
        end
    end)

    it("compiles source and stages development assets", function()
        write(project .. "/assets/example.txt", "asset")
        local built = tecs({ "build" }, project)
        assert.are.equal(0, built.exit.exitCode, built.output)

        local asset = io.open(project .. "/build/assets/example.txt", "r")
        assert.is_not_nil(asset, "no staged asset: " .. built.output)
        asset:close()

        local entry = io.open(project .. "/build/main.lua", "r")
        assert.is_not_nil(entry, "no build/main.lua: " .. built.output)
        entry:close()
    end)

    it("runs a project-root Teal entry instead of the manifest entry", function()
        write(
            project .. "/alternate.tl",
            [[
local marker <const> = assert(io.open("teal-entry.txt", "w"))
marker:write("teal override")
marker:close()

return tecs.newApplication({
    window = {title = "alternate", width = 64, height = 64},
    debugMaxFrames = 1,
})
]]
        )

        local ran = tecs({ "run", "alternate.tl" }, project)
        assert.is_not_nil(ran, "tecs run never returned")
        assert.are.equal("teal override", read(project .. "/teal-entry.txt"), ran.output)
    end)

    it("runs Lua with only the arguments after the separator", function()
        assert(files.createDirectory(project .. "/tools"))
        write(
            project .. "/tools/alternate.lua",
            [[
local marker = assert(io.open("lua-entry.txt", "w"))
marker:write(type(require("main")), "\n", tostring(#arg))
for index = 1, #arg do
    marker:write("\n", arg[index])
end
marker:close()

return tecs.newApplication({
    window = {title = "alternate", width = 64, height = 64},
    debugMaxFrames = 1,
})
]]
        )

        local ran =
            tecs({ "run", "tools/alternate.lua", "--", "first", "--entry", "still-an-argument", "last value" }, project)
        assert.is_not_nil(ran, "tecs run never returned")
        assert.are.equal(
            "table\n4\nfirst\n--entry\nstill-an-argument\nlast value",
            read(project .. "/lua-entry.txt"),
            ran.output
        )
    end)

    it("passes its own specs", function()
        local tested = tecs({ "test" }, project)
        assert.are.equal(0, tested.exit.exitCode, tested.output)
        assert.is_truthy(tested.output:find("2 passed, 0 failed", 1, true), tested.output)
    end)
end)
