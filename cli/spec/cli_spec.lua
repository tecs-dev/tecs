package.path = "./?.lua;./?/init.lua;" .. package.path

local lfs = require("lfs")
local cli = require("tecs_cli.cli")

local sep = package.config:sub(1, 1)

local function join(...)
    local parts = {...}
    return table.concat(parts, sep)
end

local function exists(path)
    return lfs.attributes(path) ~= nil
end

local function isDir(path)
    return lfs.attributes(path, "mode") == "directory"
end

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local content = f:read("*a")
    f:close()
    return content
end

local function writeFile(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

local function mkdirP(path)
    local current = ""
    if path:match("^%a:[/\\]") then
        current = path:sub(1, 2)
        path = path:sub(4)
    elseif path:match("^[/\\]") then
        current = sep
        path = path:gsub("^[/\\]+", "")
    end
    for part in path:gmatch("[^/\\]+") do
        if current == "" then
            current = part
        elseif current == sep then
            current = sep .. part
        else
            current = join(current, part)
        end
        if not exists(current) then
            assert(lfs.mkdir(current))
        end
    end
end

local function removeTree(path)
    local mode = lfs.attributes(path, "mode")
    if not mode then return end
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                removeTree(join(path, entry))
            end
        end
        assert(lfs.rmdir(path))
    else
        assert(os.remove(path))
    end
end

local tempCounter = 0
local function tempDir(name)
    tempCounter = tempCounter + 1
    local base = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    local root = join(base, "tecs-cli-spec-" .. name .. "-" .. tostring(os.time())
        .. "-" .. tostring(tempCounter))
    removeTree(root)
    mkdirP(root)
    return root
end

local function withCwd(path, fn)
    local old = assert(lfs.currentdir())
    assert(lfs.chdir(path))
    local ok, err = pcall(fn)
    assert(lfs.chdir(old))
    if not ok then error(err, 0) end
end

-- A persistent user-data dir shared by the source-mode `api` specs, so the
-- runtime framework index is type-checked once and then served from its cache
-- across the rest of the suite (and never writes to the real user home).
local apiCacheDir
local function sharedApiDataDir()
    if not apiCacheDir then apiCacheDir = tempDir("api-fw-cache") end
    return apiCacheDir
end

describe("tecs CLI", function()
    local temps = {}

    after_each(function()
        for _, path in ipairs(temps) do
            removeTree(path)
        end
        temps = {}
    end)

    local function makeTemp(name)
        local path = tempDir(name)
        temps[#temps + 1] = path
        return path
    end

    describe("commands", function()
        it("refuses to nest a project inside an existing one", function()
            -- A nested project detaches from the outer project's MCP bridge:
            -- an agent that runs `tecs new` inside a generated project ends
            -- up driving the outer template instead of its own game.
            local root = makeTemp("new-nested")
            local outer = join(root, "outer")
            assert.is_true(cli.run({"--quiet", "new", outer}))
            withCwd(outer, function()
                local ok, err = cli.run({"new", "inner"})
                assert.is_true(not ok)
                assert.matches("already a Tecs project", err)
                assert.is_false(exists(join(outer, "inner")))
                -- Deliberate nesting stays possible.
                local ok2, err2 = cli.run({"--quiet", "new", "inner", "--force"})
                if not ok2 then error("forced nest failed: " .. tostring(err2)) end
                assert.is_true(exists(join(outer, "inner", "tlconfig.lua")))
            end)
        end)

        it("creates a new fixed-layout project from checked-in template source", function()
            local root = makeTemp("new")
            local project = join(root, "sample-game")

            assert.is_true(cli.run({"--quiet", "new", project}))

            assert.is_true(exists(join(project, ".gitignore")))
            assert.is_true(exists(join(project, ".github", "workflows", "ci.yml")))
            assert.is_true(exists(join(project, ".mcp.json")))
            assert.is_true(exists(join(project, ".codex", "config.toml")))
            assert.is_true(exists(join(project, "README.md")))
            assert.is_true(exists(join(project, "tlconfig.lua")))
            local agents = readFile(join(project, "AGENTS.md"))
            assert.matches("Tecs project guide", agents)
            assert.matches("tecs docs", agents)
            -- Procedural guidance ships as pushed Claude Code skills; the human
            -- README points at both the skills and `tecs docs`.
            assert.matches("name: tecs%-cli",
                readFile(join(project, ".claude", "skills", "tecs-cli", "SKILL.md")))
            assert.matches("name: integration%-testing",
                readFile(join(project, ".claude", "skills", "integration-testing", "SKILL.md")))
            assert.matches("name: tecs%-conventions",
                readFile(join(project, ".claude", "skills", "tecs-conventions", "SKILL.md")))
            assert.matches("tecs docs", readFile(join(project, "README.md")))
            assert.equals("@AGENTS.md\n", readFile(join(project, "CLAUDE.md")))
            assert.matches("tecs2d%.testing%.fixture",
                readFile(join(project, "spec", "game_lovespec.tl")))
            assert.is_false(exists(join(project, "game-dev-1.rockspec")))
            -- conf.tl is stamped with the project name so every game gets
            -- its own LÖVE save dir (no cross-project artifact bleed).
            local conf = readFile(join(project, "src", "conf.tl"))
            assert.matches('t%.window%.title = "sample%-game"', conf)
            assert.matches('t%.identity = "tecs%-sample%-game"', conf)
            assert.is_true(exists(join(project, "src", "main.tl")))
            assert.is_true(isDir(join(project, "assets")))
            assert.is_false(exists(join(project, "types")))

            local main = readFile(join(project, "src", "main.tl"))
            assert.matches('require%("tecs"%)', main)
            assert.matches('require%("tecs2d"%)', main)
            assert.matches('require%("tecs2d%.gfx"%)', main)
            assert.matches('require%("tecs2d%.mcp"%)', main)
            assert.matches('require%("tecs2d%.debug"%)', main)
            assert.matches('world:addPlugin%(mcp%.new%(%)%)', main)
            assert.matches('world:addPlugin%(debugPlugin%.new%(%)%)', main)
            assert.matches('name = "SpawnHello"', main)
            assert.matches('phase = tecs%.phases%.Startup', main)
            assert.matches('gfx%.Text%(FONT, "HELLO TECS2D!", 4%)', main)
            assert.matches('name = "background"', main)
            assert.matches('name = "content"', main)
            assert.equals(nil, main:match('love%.graphics'))
            assert.equals(nil, main:match('DrawHello'))
            assert.matches("tecs2d%.run", main)
        end)

        it("can create a project inside an existing empty directory", function()
            local root = makeTemp("empty")
            local project = join(root, "empty-project")
            mkdirP(project)

            assert.is_true(cli.run({"--quiet", "new", project}))

            assert.is_true(exists(join(project, "src", "main.tl")))
            assert.is_true(exists(join(project, "tlconfig.lua")))
        end)

        it("removes build artifacts without touching source files", function()
            local root = makeTemp("clean")
            mkdirP(join(root, "build", "nested"))
            mkdirP(join(root, "src"))
            writeFile(join(root, "build", "nested", "artifact.lua"), "return true\n")
            writeFile(join(root, "src", "main.tl"), "return true\n")

            withCwd(root, function()
                assert.is_true(cli.run({"clean", "--quiet"}))
            end)

            assert.is_false(exists(join(root, "build")))
            assert.is_true(exists(join(root, "src", "main.tl")))
        end)

        it("rejects a non-empty target for new projects without modifying it", function()
            local root = makeTemp("existing")
            local project = join(root, "already-here")
            mkdirP(project)
            writeFile(join(project, "keep.txt"), "do not overwrite\n")

            local ok, err = cli.run({"--quiet", "new", project})

            assert.is_false(ok)
            assert.matches("not empty", err)
            assert.equals("do not overwrite\n", readFile(join(project, "keep.txt")))
            assert.is_false(exists(join(project, "src", "main.tl")))
        end)

        it("reports unknown commands without running a task", function()
            local ok, err = cli.run({"nope"})

            assert.is_false(ok)
            assert.matches("unknown command", err)
        end)

        it("prints only the semantic version with --version", function()
            local printed = {}
            local realPrint = print
            _G.print = function(...)
                printed[#printed + 1] = table.concat({...}, "\t")
            end
            local ok = cli.run({"--version"})
            _G.print = realPrint

            assert.is_true(ok)
            assert.equals(1, #printed)
            -- Semver with an optional prerelease tag: release builds print
            -- "0.10.8", working-tree builds "0.10.8-dev".
            local v = printed[1]
            assert.is_true((v:match("^%d+%.%d+%.%d+$")
                or v:match("^%d+%.%d+%.%d+%-%w+$")) ~= nil)
        end)

        it("prints runtime versions and a next step with info", function()
            local printed = {}
            local realPrint = print
            _G.print = function(...)
                printed[#printed + 1] = table.concat({...}, "\t")
            end
            local ok = cli.run({"info"})
            _G.print = realPrint

            assert.is_true(ok)
            local output = table.concat(printed, "\n")
            assert.matches("Tecs CLI %d+%.%d+%.%d+", output)
            assert.matches("LuaJIT %d+%.%d+", output)
            assert.matches("Next: tecs new hello", output)
        end)

        it("includes current project information with info", function()
            local root = makeTemp("version-project")
            mkdirP(join(root, "src"))
            mkdirP(join(root, "build"))
            writeFile(join(root, "tlconfig.lua"), "return {}\n")
            writeFile(join(root, "build", "main.lua"), "return true\n")

            local printed = {}
            local realPrint = print
            _G.print = function(...)
                printed[#printed + 1] = table.concat({...}, "\t")
            end
            withCwd(root, function()
                assert.is_true(cli.run({"info"}))
            end)
            _G.print = realPrint

            local output = table.concat(printed, "\n")
            assert.matches("Project .-version%-project", output)
            assert.matches("Path: .-version%-project", output)
            assert.matches("Build: ready", output)
            assert.matches("Next: tecs run", output)
        end)

        it("suppresses status output with --quiet", function()
            local root = makeTemp("quiet")
            mkdirP(join(root, "build"))

            local captured = {}
            local realStderr = io.stderr
            io.stderr = {
                write = function(_, ...)
                    captured[#captured + 1] = table.concat({...})
                end,
            }
            local runOk, runErr = pcall(withCwd, root, function()
                assert.is_true(cli.run({"clean", "--quiet"}))
            end)
            io.stderr = realStderr
            assert(runOk, runErr)

            assert.equals(0, #captured)
        end)
    end)

    describe("agent docs", function()
        local function capturePrint(argv)
            local printed = {}
            local realPrint = print
            _G.print = function(...)
                printed[#printed + 1] = table.concat({...}, "\t")
            end
            local ok, err = cli.run(argv)
            _G.print = realPrint
            return ok, err, printed
        end

        it("lists bundled docs with descriptions", function()
            local ok, _, printed = capturePrint({"agent", "list"})
            assert.is_true(ok)
            assert.matches("tecs%-project%s+Working guide", table.concat(printed, "\n"))
        end)

        it("materializes a doc into the data directory and prints its path", function()
            local root = makeTemp("agent-path")
            cli._internal.setDataDir(root)
            local runOk, runErr = pcall(function()
                local ok, _, printed = capturePrint({"agent", "path", "tecs-project"})
                assert.is_true(ok)
                assert.equals(1, #printed)
                assert.matches("agents", printed[1])
                assert.matches("Tecs project guide", readFile(printed[1]))
            end)
            cli._internal.setDataDir(nil)
            assert(runOk, runErr)
        end)

        it("overwrites a stale materialized doc", function()
            local root = makeTemp("agent-refresh")
            cli._internal.setDataDir(root)
            local runOk, runErr = pcall(function()
                local _, _, printed = capturePrint({"agent", "path", "tecs-project"})
                writeFile(printed[1], "stale contents\n")
                local ok, _, reprinted = capturePrint({"agent", "path", "tecs-project"})
                assert.is_true(ok)
                assert.equals(printed[1], reprinted[1])
                assert.matches("Tecs project guide", readFile(reprinted[1]))
            end)
            cli._internal.setDataDir(nil)
            assert(runOk, runErr)
        end)

        it("rejects unknown doc names without writing anything", function()
            local root = makeTemp("agent-unknown")
            cli._internal.setDataDir(root)
            local ok, err = cli.run({"agent", "path", "nope"})
            cli._internal.setDataDir(nil)
            assert.is_true(not ok)
            assert.matches("unknown agent 'nope'", err)
            assert.is_true(not exists(join(root, "agents", "nope.md")))
        end)
    end)

    describe("check remediation", function()
        it("hints the events-as-value mistake with a docs pointer", function()
            local root = makeTemp("remediation")
            local file = join(root, "m.tl")
            writeFile(file, "local tecs2d = require(\"tecs2d\")\n"
                .. "world:observe(0, tecs2d.MousePressed, handler)\n")
            local diags = {{
                file = file, line = 2, column = 18, kind = "type",
                message = "cannot use a type definition as a concrete value",
            }}
            cli._internal.attachRemediation(diags)
            assert.matches('require%("tecs2d%.events"%)', diags[1].hint)
            assert.matches("events%.MousePressed", diags[1].hint)
            assert.equals("tecs2d/events", diags[1].docs)
        end)

        it("hints the generic-annotation-plus-const syntax error", function()
            -- `local KEY: tecs.Key<T> <const> = ...` doesn't parse and Teal
            -- reports only a bare "syntax error", pointing agents at the
            -- wrong construct (an agent edited the line below it, twice).
            local root = makeTemp("remediation-const")
            local file = join(root, "m.tl")
            writeFile(file, "local tecs = require(\"tecs\")\n"
                .. "local STATE_KEY: tecs.Key<GameState> <const> = tecs.newKey(\"game.state\")\n")
            local diags = {{
                file = file, line = 2, column = 39, kind = "syntax",
                message = "syntax error",
            }}
            cli._internal.attachRemediation(diags)
            assert.matches("cannot parse `<const>` after a generic", diags[1].hint)
            assert.matches("as tecs%.Key<T>", diags[1].hint)
        end)

        it("leaves unrelated syntax errors bare", function()
            local root = makeTemp("remediation-syntax-neg")
            local file = join(root, "m.tl")
            writeFile(file, "local x = {\n")
            local diags = {{
                file = file, line = 1, column = 11, kind = "syntax",
                message = "syntax error",
            }}
            cli._internal.attachRemediation(diags)
            assert.is_true(diags[1].hint == nil)
        end)

        it("does not hint an unrelated type-as-value error", function()
            local root = makeTemp("remediation-neg")
            local file = join(root, "m.tl")
            writeFile(file, "local x = SomeOtherType\n")
            local diags = {{
                file = file, line = 1, column = 11, kind = "type",
                message = "cannot use a type definition as a concrete value",
            }}
            cli._internal.attachRemediation(diags)
            assert.is_true(diags[1].hint == nil)
            assert.is_true(diags[1].docs == nil)
        end)

        it("points unknown-field errors at the exact tecs api lookup", function()
            local diags = {
                {file = "x.tl", line = 1, column = 1, kind = "type",
                 message = "invalid key 'linewidth' in record 'r' of type Rectangle"},
                {file = "x.tl", line = 2, column = 1, kind = "type",
                 message = "invalid key 'getMutt' in 'world' of interface type tecs.World"},
                {file = "x.tl", line = 3, column = 1, kind = "type",
                 message = "cannot index key 'currrent' in variable 'h' of type Health"},
                -- Structural and primitive types never resolve to an API symbol.
                {file = "x.tl", line = 4, column = 1, kind = "type",
                 message = "invalid key 'foo' in record 'm' of type {string:number}"},
                {file = "x.tl", line = 5, column = 1, kind = "type",
                 message = "cannot index key 'bar' in variable 's' of type string"},
            }
            cli._internal.attachRemediation(diags)
            assert.matches("`tecs api Rectangle`", diags[1].hint)
            assert.matches("`tecs api World`", diags[2].hint)
            assert.matches("`tecs api Health`", diags[3].hint)
            assert.is_true(diags[4].hint == nil)
            assert.is_true(diags[5].hint == nil)
        end)

        it("points arity and argument-type errors at the offending call", function()
            local root = makeTemp("remediation-call")
            local file = join(root, "m.tl")
            writeFile(file, table.concat({
                "local r = gfx.Rectangle(10)",
                "world:spawn(\"nope\")",
                "world.getMut(1, Health)",
                "local h = Health(1)",
                "local ok = helper(1, 2, 3)",
                "print(r, h, ok)",
            }, "\n") .. "\n")
            local arity = "wrong number of arguments (given 1, expects 2)"
            local argt = "argument 1: got string \"nope\", expected number"
            local diags = {
                {file = file, line = 1, column = 11, kind = "type", message = arity},
                {file = file, line = 2, column = 13, kind = "type", message = argt},
                {file = file, line = 3, column = 14, kind = "type", message = argt},
                {file = file, line = 4, column = 11, kind = "type", message = arity},
                -- A local helper is not an API symbol: no hint.
                {file = file, line = 5, column = 12, kind = "type", message = arity},
            }
            cli._internal.attachRemediation(diags)
            assert.matches("`tecs api gfx%.Rectangle`", diags[1].hint)
            assert.matches("`tecs api world:spawn`", diags[2].hint)
            assert.matches("`tecs api world:getMut`", diags[3].hint)
            assert.matches("`tecs api Health`", diags[4].hint)
            assert.is_true(diags[5].hint == nil)
        end)
    end)

    describe("docs command", function()
        local function capturePrint(argv)
            local printed = {}
            local realPrint = print
            _G.print = function(...)
                printed[#printed + 1] = table.concat({...}, "\t")
            end
            local ok, err = cli.run(argv)
            _G.print = realPrint
            return ok, err, printed
        end

        local function captureWrite(argv)
            local chunks = {}
            local realWrite = io.write
            io.write = function(...)
                chunks[#chunks + 1] = table.concat({...})
                return true
            end
            local ok, err = cli.run(argv)
            io.write = realWrite
            return ok, err, table.concat(chunks)
        end

        it("prints the page index tree", function()
            local ok, _, out = captureWrite({"docs"})
            assert.is_true(ok)
            assert.matches("Table of Contents", out)
            assert.matches("%[World%]%(/tecs/world%.md%)", out)
        end)

        it("prints the page index as JSON", function()
            local ok, _, printed = capturePrint({"docs", "--json"})
            assert.is_true(ok)
            local out = table.concat(printed, "\n")
            assert.matches('"id":"tecs/world"', out)
            assert.matches('"title":"World"', out)
            assert.matches('"description":', out)
        end)

        it("prints one page by its index path", function()
            local ok, _, out = captureWrite({"docs", "tecs/world"})
            assert.is_true(ok)
            assert.matches("# World", out)
        end)

        it("accepts the full /path.md form too", function()
            local ok, _, out = captureWrite({"docs", "/tecs/world.md"})
            assert.is_true(ok)
            assert.matches("# World", out)
        end)

        it("prints every page with --full", function()
            local ok, _, out = captureWrite({"docs", "--full"})
            assert.is_true(ok)
            assert.matches("url: /tecs/world%.md", out)
            assert.matches("url: /tecs2d/rendering/shapes%.md", out)
        end)

        it("rejects an unknown page", function()
            local ok, err = cli.run({"docs", "nope/does-not-exist"})
            assert.is_true(not ok)
            assert.matches("unknown page 'nope/does%-not%-exist'", err)
        end)

        it("searches page contents with a pattern", function()
            local ok, _, out = captureWrite({"docs", "--search", "latch"})
            assert.is_true(ok)
            assert.matches("tecs2d/input", out)
            -- Matching lines print under the page id, trimmed.
            assert.matches("[Ll]atch", out)
        end)

        it("fails a search with no matches", function()
            local ok, err = cli.run({"docs", "--search", "zzzznothing"})
            assert.is_true(not ok)
            assert.matches("no docs match", err)
        end)

        it("suggests near-miss pages on an unknown page", function()
            -- A plausible-but-wrong id must redirect in one call, not dead-end.
            local ok, err = cli.run({"docs", "tecs2d/shapes"})
            assert.is_true(not ok)
            assert.matches("did you mean:", err)
            assert.matches("tecs2d/rendering/shapes", err)
        end)

        it("rejects --json combined with a page", function()
            local ok, err = cli.run({"docs", "tecs/world", "--json"})
            assert.is_true(not ok)
            assert.matches("only valid for the page index", err)
        end)

        it("rejects a page combined with --full", function()
            local ok, err = cli.run({"docs", "tecs/world", "--full"})
            assert.is_true(not ok)
            assert.matches("either a page or %-%-full", err)
        end)

        it("leaves `agent list` unchanged", function()
            local _, _, printed = capturePrint({"agent", "list"})
            local out = table.concat(printed, "\n")
            assert.matches("tecs%-project", out)
        end)

        it("exposes docs in the completion script", function()
            local captured = {}
            local realWrite = io.write
            io.write = function(...)
                captured[#captured + 1] = table.concat({...})
                return true
            end
            local ok = cli.run({"completions", "bash"})
            io.write = realWrite
            assert.is_true(ok)
            assert.matches("docs", table.concat(captured))
        end)
    end)

    describe("completions", function()
        it("prints a completion function for bash", function()
            local captured = {}
            local realWrite = io.write
            io.write = function(...)
                captured[#captured + 1] = table.concat({...})
                return true
            end
            local ok = cli.run({"completions", "bash"})
            io.write = realWrite
            assert.is_true(ok)
            local script = table.concat(captured)
            assert.matches("_tecs%(%)", script)
            assert.matches("completions", script)
        end)

        it("adds positional choices to the fish script", function()
            local captured = {}
            local realWrite = io.write
            io.write = function(...)
                captured[#captured + 1] = table.concat({...})
                return true
            end
            local ok = cli.run({"completions", "fish"})
            io.write = realWrite
            assert.is_true(ok)
            local script = table.concat(captured)
            assert.matches("__fish_tecs_seen_command completions' %-f %-a 'bash zsh fish'", script)
            assert.matches("__fish_tecs_seen_command agent' %-f %-a 'list path'", script)
        end)

        it("rejects unsupported shells", function()
            local ok, err = cli.run({"completions", "tcsh"})
            assert.is_true(not ok)
            assert.matches("argument 'shell' must be one of 'bash', 'zsh', 'fish'", err)
        end)
    end)

    describe("json output", function()
        local frameworkDir = os.getenv("TECS_DIR")
        local hasFramework = frameworkDir and frameworkDir ~= ""
            and exists(join(frameworkDir, "src", "tecs", "utils", "json", "init.tl"))

        local function capturePrint(argv)
            local printed = {}
            local realPrint = print
            _G.print = function(...)
                printed[#printed + 1] = table.concat({...}, "\t")
            end
            local ok, err = cli.run(argv)
            _G.print = realPrint
            return ok, err, printed
        end

        if hasFramework then
            it("emits runtime info as sorted JSON", function()
                local ok, _, printed = capturePrint({"info", "--json"})
                assert.is_true(ok)
                assert.equals(1, #printed)
                assert.matches('"version":"%d+%.%d+%.%d+', printed[1])
                assert.matches('"love":null', printed[1])
                assert.matches('"project":null', printed[1])
            end)

            it("lists agent docs as JSON", function()
                local ok, _, printed = capturePrint({"agent", "list", "--json"})
                assert.is_true(ok)
                assert.matches('"name":"tecs%-project"', printed[1])
                assert.matches('"description":"Working guide', printed[1])
            end)

            it("describes the current project in info --json", function()
                local root = makeTemp("info-json")
                mkdirP(join(root, "src"))
                writeFile(join(root, "tlconfig.lua"), "return {}\n")

                local ok, _, printed
                withCwd(root, function()
                    ok, _, printed = capturePrint({"info", "--json"})
                end)
                assert.is_true(ok)
                assert.matches('"name":"tecs%-cli%-spec%-info%-json', printed[1])
                assert.matches('"built":false', printed[1])
            end)
        else
            it("skips JSON specs without a Tecs checkout (set TECS_DIR)", function()
                assert.is_true(true)
            end)
        end

        it("points integ at the installed launcher outside LÖVE", function()
            local root = makeTemp("integ-nolove")
            mkdirP(join(root, "src"))
            mkdirP(join(root, "spec"))
            writeFile(join(root, "tlconfig.lua"), "return {}\n")

            local ok, err
            withCwd(root, function()
                ok, err = cli.run({"integ"})
            end)
            assert.is_true(not ok)
            assert.matches("installed launcher", err)
        end)

        it("points check --json at the installed launcher outside LÖVE", function()
            local root = makeTemp("check-json-nolove")
            mkdirP(join(root, "src"))
            writeFile(join(root, "tlconfig.lua"), "return {}\n")

            local ok, err
            withCwd(root, function()
                ok, err = cli.run({"check", "--json"})
            end)
            assert.is_true(not ok)
            assert.matches("installed launcher", err)
        end)
    end)

    describe("api", function()
        local frameworkDir = os.getenv("TECS_DIR")
        -- The framework tier is generated at runtime from the framework sources
        -- by the CLI's own apidocs extractor -- no committed/bundled index.
        local hasFramework = frameworkDir and frameworkDir ~= ""
            and exists(join(frameworkDir, "src", "tecs", "init.tl"))

        local function capturePrint(argv)
            cli._internal.setDataDir(sharedApiDataDir())
            local printed = {}
            local realPrint = print
            _G.print = function(...)
                printed[#printed + 1] = table.concat({...}, "\t")
            end
            local ok, err = cli.run(argv)
            _G.print = realPrint
            cli._internal.setDataDir(nil)
            return ok, err, table.concat(printed, "\n")
        end

        local function captureWrite(argv)
            cli._internal.setDataDir(sharedApiDataDir())
            local chunks = {}
            local realWrite = io.write
            io.write = function(...)
                chunks[#chunks + 1] = table.concat({...})
                return true
            end
            local ok, err = cli.run(argv)
            io.write = realWrite
            cli._internal.setDataDir(nil)
            return ok, err, table.concat(chunks)
        end

        if hasFramework then
            it("lists framework modules (full public surface) with no arguments", function()
                local ok, _, out = captureWrite({"api"})
                assert.is_true(ok)
                assert.matches("Framework modules:", out)
                assert.matches("tecs2d%.gfx", out)
                assert.matches("tecs%.types", out)
                -- The bare `tecs` module appears as its own indented line.
                assert.matches("  tecs\n", out .. "\n")
            end)

            it("resolves builtins by bare name and module path", function()
                -- Transform is the first component every agent looks up.
                local ok, _, out = captureWrite({"api", "Transform"})
                assert.is_true(ok)
                assert.matches("^%-%- tecs%.builtins%.Transform\n", out)
                assert.matches("layer: integer", out)

                local ok2, _, out2 = captureWrite({"api", "tecs.builtins.Transform"})
                assert.is_true(ok2)
                assert.matches("record Transform", out2)
            end)

            it("resolves type aliases to their terminal type", function()
                -- `type System = types.System = function(dt, world)` used to
                -- dead-end at "type alias to types.System", pushing agents to
                -- grep vendored source. The terminal type must show inline.
                local ok, _, out = captureWrite({"api", "tecs.System"})
                assert.is_true(ok)
                assert.matches("function%(number, World%)", out)
                assert.matches("type alias to types%.System", out)
            end)

            it("expands type-namespace records like tecs.phases", function()
                -- phases is re-exported as a value field, and its members are
                -- nested tag records. Both used to be invisible: `tecs api
                -- tecs.phases` printed a one-line header with no phase names.
                local ok, _, out = captureWrite({"api", "tecs.phases"})
                assert.is_true(ok)
                assert.matches("record phases", out)
                assert.matches("type Update: Phase", out)
                assert.matches("type FixedUpdate: Phase", out)
                assert.matches("type Startup: Phase", out)
            end)

            it("answers nested-member addresses like tecs.phases.Startup", function()
                local ok, _, out = captureWrite({"api", "tecs.phases.Startup"})
                assert.is_true(ok)
                assert.matches("type Startup: Phase", out)
                assert.matches("nested in: tecs api tecs%.phases", out)

                -- Bare parent name works too, and canonicalizes to the
                -- defining module.
                local ok2, _, out2 = captureWrite({"api", "World.Config"})
                assert.is_true(ok2)
                assert.matches("tecs%.types%.World%.Config", out2)
            end)

            it("rejects unknown --fields keys loudly", function()
                -- Silently dropping a bad key reads as "the symbol has none of
                -- those" (an agent grepped empty output and concluded World
                -- had no methods).
                local ok, err = cli.run({"api", "tecs.World", "--fields", "name,signature"})
                assert.is_true(not ok)
                assert.matches("unknown %-%-fields key 'name'", err)
                assert.matches("constructor", err)
            end)

            it("renders parameter names in signatures", function()
                -- Three anonymous numbers invite positional guesses (an agent
                -- read Rectangle's lineWidth as a corner radius); names are
                -- read back from the declaration site.
                local ok, _, out = captureWrite(
                    {"api", "gfx.Rectangle", "--fields", "constructor"})
                assert.is_true(ok)
                assert.matches("width: number", out)
                assert.matches("lineWidth%?: number", out)

                local ok2, _, out2 = captureWrite({"api", "World:getMut"})
                assert.is_true(ok2)
                assert.matches("entity: integer", out2)
            end)

            it("renders a component's constructor before its fields", function()
                local ok, _, out = captureWrite({"api", "tecs2d.gfx.Text"})
                assert.is_true(ok)
                local ctorAt = out:find("metamethod __call", 1, true)
                local fieldAt = out:find("slabOffset", 1, true)
                assert.is_true(ctorAt ~= nil and fieldAt ~= nil and ctorAt < fieldAt,
                    "constructor must render above the field list")
            end)

            it("lists tecs.types with more than just World", function()
                local ok, _, out = captureWrite({"api", "tecs.types"})
                assert.is_true(ok)
                assert.matches("World", out)
                assert.matches("Query", out)
                assert.matches("Pipeline", out)
            end)

            it("lists a module's symbols", function()
                local ok, _, out = captureWrite({"api", "gfx"})
                assert.is_true(ok)
                assert.matches("Rectangle", out)
                assert.matches("newPipeline", out)
            end)

            it("renders a framework type as a Teal record block", function()
                local ok, _, out = captureWrite({"api", "gfx.Rectangle"})
                assert.is_true(ok)
                assert.matches("^%-%- tecs2d%.gfx%.Rectangle\n", out)
                assert.matches("record Rectangle", out)
                assert.matches("width: number", out)
                assert.matches("metamethod __call", out)
            end)

            it("prints one method signature", function()
                local ok, _, out = captureWrite({"api", "world:getMut"})
                assert.is_true(ok)
                assert.matches("^%-%- tecs%.types%.World:getMut\n", out)
                assert.matches("world:getMut", out)
                assert.matches("integer", out)
            end)

            it("emits structured records with --json", function()
                local ok, _, out = capturePrint({"api", "gfx.Rectangle", "--json"})
                assert.is_true(ok)
                assert.matches('"kind":"component"', out)
                assert.matches('"symbol":"Rectangle"', out)
            end)

            it("projects only requested keys with --fields", function()
                local ok, _, out = capturePrint({"api", "gfx.Rectangle", "--fields", "signature", "--json"})
                assert.is_true(ok)
                assert.matches('"signature":', out)
                assert.equals(nil, out:match('"methods":'))
                assert.equals(nil, out:match('"fields":%['))
            end)

            it("projects the RENDERED output with --fields signature", function()
                local ok, _, out = captureWrite({"api", "gfx.Rectangle", "--fields", "signature"})
                assert.is_true(ok)
                assert.matches("record Rectangle", out)
                -- Only the signature line, not the whole record block.
                assert.equals(nil, out:match("width: number"))
                assert.equals(nil, out:match("metamethod __call"))
            end)

            it("projects the RENDERED output with --fields methods", function()
                local ok, _, out = captureWrite({"api", "gfx.Pipeline", "--fields", "methods"})
                assert.is_true(ok)
                -- Receiver form: colon-call methods must be visually distinct
                -- from plain function fields.
                assert.matches("Pipeline:render%(", out)
                -- No record wrapper and no data fields when only methods are asked for.
                assert.equals(nil, out:match("\nrecord Pipeline"))
                assert.equals(nil, out:match("drawCamX"))
            end)

            it("suggests module-qualified near matches on an unknown symbol and exits non-zero", function()
                local ok, _, out = captureWrite({"api", "gfx.Recktangle"})
                assert.is_false(ok)
                assert.matches("did you mean", out)
                -- Suggestions are fully addressable, usable verbatim as the next query.
                assert.matches("tecs2d%.gfx%.Rectangle", out)
            end)

            it("batches multiple lookups, never short-circuiting on a miss", function()
                local ok, _, out = captureWrite({"api", "gfx.Rectangle", "gfx.Nope"})
                assert.is_false(ok)
                -- The hit still renders...
                assert.matches("record Rectangle", out)
                -- ...and the miss reports its suggestions.
                assert.matches("gfx%.Nope", out)
                assert.matches("did you mean", out)
            end)

            it("looks up a dynamic project component from the overlay", function()
                local root = makeTemp("api-overlay")
                local project = join(root, "game")
                assert.is_true(cli.run({"--quiet", "new", project}))

                mkdirP(join(project, "src", "components"))
                writeFile(join(project, "src", "components", "health.tl"), table.concat({
                    "local tecs <const> = require(\"tecs\")",
                    "",
                    "local record Health is tecs.Component",
                    "   --- Current hit points remaining.",
                    "   current: number",
                    "   --- Maximum hit points.",
                    "   max: number",
                    "",
                    "   metamethod __call: function(self, current: number, max: number): Health",
                    "end",
                    "",
                    "return Health",
                    "",
                }, "\n"))

                local ok, out
                withCwd(project, function()
                    local res, _, text = captureWrite({"api", "Health"})
                    ok, out = res, text
                end)
                assert.is_true(ok)
                assert.matches("record Health", out)
                assert.matches("current: number", out)
                assert.matches("max: number", out)
            end)

            it("does not report a same-type re-export as an alternate match", function()
                -- TouchPressed is indexed under both tecs2d (re-export) and
                -- tecs2d.events; the same underlying record is not a collision,
                -- and the defining module is reported as the canonical address.
                local ok, _, out = captureWrite({"api", "TouchPressed"})
                assert.is_true(ok)
                assert.matches("^%-%- tecs2d%.events%.TouchPressed\n", out)
                assert.matches("record TouchPressed", out)
                assert.equals(nil, out:match("also matches"))
            end)

            it("prefers a project symbol over a framework symbol with the same bare name", function()
                local root = makeTemp("api-shadow")
                local project = join(root, "game")
                assert.is_true(cli.run({"--quiet", "new", project}))

                mkdirP(join(project, "src", "components"))
                writeFile(join(project, "src", "components", "rectangle.tl"), table.concat({
                    "local tecs <const> = require(\"tecs\")",
                    "",
                    "local record Rectangle is tecs.Component",
                    "   w: number",
                    "   h: number",
                    "",
                    "   metamethod __call: function(self, w: number, h: number): Rectangle",
                    "end",
                    "",
                    "return Rectangle",
                    "",
                }, "\n"))

                local ok, out
                withCwd(project, function()
                    local res, _, text = captureWrite({"api", "Rectangle"})
                    ok, out = res, text
                end)
                assert.is_true(ok)
                -- The project's own component wins the bare name...
                assert.matches("w: number", out)
                assert.equals(nil, out:match("lineWidth"))
                -- ...and the shadowed framework match is reported.
                assert.matches("also matches: tecs2d%.gfx%.Rectangle", out)
            end)

            it("keeps reporting a degraded overlay on cache hits", function()
                local root = makeTemp("api-degraded")
                local project = join(root, "game")
                assert.is_true(cli.run({"--quiet", "new", project}))

                mkdirP(join(project, "src", "components"))
                writeFile(join(project, "src", "components", "broken.tl"),
                    "local record Broken\n   x: number\nthis is not teal ((\n")

                withCwd(project, function()
                    -- The second lookup is served from build/api-index.json; the
                    -- degraded note must survive the cache hit.
                    for _ = 1, 2 do
                        local ok, _, out = captureWrite({"api", "gfx.Rectangle"})
                        assert.is_true(ok)
                        assert.matches("note: some project modules could not be analyzed", out)
                        assert.matches("record Rectangle", out)
                    end
                end)
            end)

            it("returns a dynamic project component's fields as JSON", function()
                local root = makeTemp("api-overlay-json")
                local project = join(root, "game")
                assert.is_true(cli.run({"--quiet", "new", project}))

                mkdirP(join(project, "src", "components"))
                writeFile(join(project, "src", "components", "velocity.tl"), table.concat({
                    "local tecs <const> = require(\"tecs\")",
                    "",
                    "local record Velocity is tecs.Component",
                    "   dx: number",
                    "   dy: number",
                    "",
                    "   metamethod __call: function(self, dx: number, dy: number): Velocity",
                    "end",
                    "",
                    "return Velocity",
                    "",
                }, "\n"))

                local ok, out
                withCwd(project, function()
                    local res, _, text = capturePrint({"api", "Velocity", "--json"})
                    ok, out = res, text
                end)
                assert.is_true(ok)
                assert.matches('"symbol":"Velocity"', out)
                assert.matches('"dx"', out)
                assert.matches('"dy"', out)
            end)
        else
            it("skips api specs without a Tecs checkout (set TECS_DIR)", function()
                assert.is_true(true)
            end)
        end
    end)

    describe("call command", function()
        it("requires the packaged runtime in source mode", function()
            local ok, err = cli.run({"call", "ping"})
            assert.is_false(ok)
            assert.matches("launcher", tostring(err))
        end)
    end)

    -- Packaged-mode coverage: source-mode specs cannot catch bugs that only
    -- appear inside the .love (e.g. the extractor's plain-table fallback, which
    -- source mode masked because it ran the same code but the earlier fixtures
    -- used a typed `local record` module). This builds the real payload and
    -- drives the packaged CLI. Gated on a LÖVE binary and Node being available.
    describe("packaged .love", function()
        local frameworkDir = os.getenv("TECS_DIR")

        local function shellOk(cmd)
            local a, _, c = os.execute(cmd)
            return a == true or a == 0 or c == 0
        end

        local function findLove()
            local candidate = os.getenv("TECS_LOVE_BIN") or os.getenv("LOVE")
            if candidate and candidate ~= "" and exists(candidate) then return candidate end
            if frameworkDir and frameworkDir ~= "" then
                local p = join(frameworkDir, "bin", "love2d", "love.app", "Contents", "MacOS", "love")
                if exists(p) then return p end
            end
            return nil
        end

        local loveBin = findLove()
        local canPackage = frameworkDir and frameworkDir ~= "" and loveBin
            and exists(join(frameworkDir, "src", "tecs", "init.tl"))
            and shellOk("command -v node >/dev/null 2>&1")

        if canPackage then
            local function sq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
            local app = join(assert(lfs.currentdir()), "dist", "tecs-cli.love")

            -- Build the real payload once, then reuse it across the block.
            local built = false
            local function ensureBuilt()
                if built then return end
                assert.is_true(shellOk("TECS_DIR=" .. sq(frameworkDir)
                    .. " ./scripts/build_love.sh >/dev/null 2>&1"),
                    "scripts/build_love.sh failed")
                assert.is_true(exists(app), "packaged .love not produced")
                built = true
            end

            -- Run the packaged CLI for `project`, with a controlled user-data dir
            -- (XDG_DATA_HOME) so the framework-index cache is inspectable and the
            -- real user home is never touched. Captures stdout.
            local function runPackaged(project, dataDir, argv)
                local parts = {
                    "SDL_VIDEODRIVER=dummy", "SDL_AUDIODRIVER=dummy",
                    "XDG_DATA_HOME=" .. sq(dataDir),
                    "TECS_LOVE_BIN=" .. sq(loveBin), sq(loveBin), sq(app),
                    "--tecs-project", sq(project),
                }
                for _, a in ipairs(argv) do parts[#parts + 1] = sq(a) end
                local pipe = assert(io.popen(table.concat(parts, " ") .. " 2>/dev/null"))
                local out = pipe:read("*a") or ""
                pipe:close()
                return out
            end

            local function frameworkCacheFile(dataDir)
                local dir = join(dataDir, "tecs")
                if not isDir(dir) then return nil end
                for entry in lfs.dir(dir) do
                    if entry:match("^api%-framework%-index%-.+%.json$") then
                        return join(dir, entry)
                    end
                end
                return nil
            end

            it("generates the framework tier at runtime (no bundled index) and caches it", function()
                ensureBuilt()

                -- The payload ships the extractor, NOT a prebuilt index.
                local pipe = assert(io.popen("unzip -l " .. sq(app) .. " 2>/dev/null"))
                local listing = pipe:read("*a") or ""
                pipe:close()
                assert.equals(nil, listing:match("api%-index%.json"))
                assert.matches("apidocs%.lua", listing)
                assert.matches("cliApi%.lua", listing)
                assert.matches("cliDocs%.lua", listing)
                assert.matches("cliFileSystem%.lua", listing)
                assert.matches("cliParser%.lua", listing)

                local dataDir = makeTemp("pkg-udata")
                local proj = makeTemp("pkg-fw") -- no project: framework tier only

                -- Runtime generation answers a framework lookup with no build/game.
                local rect = runPackaged(proj, dataDir, {"api", "gfx.Rectangle"})
                assert.matches("record Rectangle", rect)

                -- Outside a project the framework is staged under the user data
                -- dir -- never as src/vendor in the cwd.
                assert.is_false(isDir(join(proj, "src")))

                -- Full public surface: tecs.types is more than just World.
                local types = runPackaged(proj, dataDir, {"api", "tecs.types"})
                assert.matches("World", types)
                assert.matches("Query", types)

                -- The user-level cache was written, keyed by version.
                local cacheFile = frameworkCacheFile(dataDir)
                assert.is_true(cacheFile ~= nil, "framework index cache not created")

                -- Second call is served FROM the cache: inject a sentinel module
                -- and confirm it comes back (a fresh regenerate would drop it).
                local json = cli._internal.jsonModule()
                local parsed = json.parse(readFile(cacheFile))
                parsed.modules["sentinel.module"] = {"SentinelSym"}
                writeFile(cacheFile, json.serialize(parsed))
                local relisted = runPackaged(proj, dataDir, {"api"})
                assert.matches("sentinel%.module", relisted)
            end)

            it("tecs new stages the vendor so first use never prepares", function()
                ensureBuilt()
                local dataDir = makeTemp("pkg-new-udata")
                local parent = makeTemp("pkg-new")
                runPackaged(parent, dataDir, {"new", "staged"})
                -- The scaffolded project is complete: the exact files
                -- embeddedDependenciesComplete() checks are already there,
                -- so the first check/api inside it stages nothing.
                local v = join(parent, "staged", "src", "vendor", "share", "lua", "5.1")
                assert.is_true(exists(join(v, "tecs2d", "init.tl")), "framework not staged")
                assert.is_true(exists(join(v, "love2d.d.tl")), "types not staged")
                assert.is_true(exists(join(v, "tecs2d", "assets", "fonts", "tiny-font.png")),
                    "assets not staged")
                assert.is_true(exists(join(v, "tecs2d", "assets", "fonts", "jetbrainsmono-extrabold-msdf.png")),
                    "debug font not staged")
                assert.is_true(exists(join(v, "tecs2d", "assets", "fonts", "jetbrainsmono-extrabold-msdf.json")),
                    "debug font metrics not staged")
                assert.is_true(exists(join(v, "tecs2d", "assets", "fonts", "JetBrainsMono-OFL.txt")),
                    "debug font license not staged")
                assert.is_true(exists(join(v, "tecs2d", "assets", "fonts", "JetBrainsMono-NOTICE.md")),
                    "debug font notice not staged")
            end)

            it("projects rendered output with --fields through the packaged CLI", function()
                ensureBuilt()
                local dataDir = makeTemp("pkg-fields-udata")
                local proj = makeTemp("pkg-fields")
                local out = runPackaged(proj, dataDir, {"api", "gfx.Rectangle", "--fields", "signature"})
                assert.matches("record Rectangle", out)
                assert.equals(nil, out:match("width: number"))
            end)

            it("resolves a plain-table-idiom project component through the packaged CLI", function()
                ensureBuilt()
                local dataDir = makeTemp("pkg-plain-udata")
                local root = makeTemp("pkg-plain")
                local project = join(root, "game")
                runPackaged(root, dataDir, {"--quiet", "new", "game"})
                assert.is_true(exists(join(project, "tlconfig.lua")), "tecs new (packaged) failed")

                -- The common project idiom: a record assigned onto a plain table
                -- (Teal infers the module type as `map`, no field_order).
                mkdirP(join(project, "src", "components"))
                writeFile(join(project, "src", "components", "health.tl"), table.concat({
                    "local tecs <const> = require(\"tecs\")",
                    "",
                    "local M = {}",
                    "",
                    "local record Health is tecs.Component",
                    "   --- Current hit points remaining.",
                    "   current: number",
                    "   --- Maximum hit points.",
                    "   max: number",
                    "",
                    "   metamethod __call: function(self, current: number, max: number): Health",
                    "end",
                    "",
                    "M.Health = Health",
                    "",
                    "return M",
                    "",
                }, "\n"))

                local out = runPackaged(project, dataDir, {"api", "Health"})
                assert.matches("record Health", out)
                assert.matches("current: number", out)
                assert.matches("max: number", out)
            end)

            it("tecs call fails helpfully when no game is running", function()
                ensureBuilt()
                local dataDir = makeTemp("pkg-call-udata")
                local proj = makeTemp("pkg-call")
                -- runPackaged drops stderr; this needs it (fail() writes there).
                local parts = {
                    "SDL_VIDEODRIVER=dummy", "SDL_AUDIODRIVER=dummy",
                    "XDG_DATA_HOME=" .. sq(dataDir),
                    "TECS_LOVE_BIN=" .. sq(loveBin), sq(loveBin), sq(app),
                    "--tecs-project", sq(proj),
                    -- Port 1 is never listening: connection refused, no timeout.
                    "call", "ping", "--port", "1", "--timeout", "2",
                }
                local pipe = assert(io.popen(table.concat(parts, " ") .. " 2>&1"))
                local out = pipe:read("*a") or ""
                pipe:close()
                assert.matches("No game answering", out)
                assert.matches("tecs run", out)
            end)

            -- Guards the remediation matchers against drift in the Teal
            -- compiler's exact error strings: this exercises the real payload
            -- compiler end to end, not synthetic messages.
            it("attaches tecs api hints to real check --json diagnostics", function()
                ensureBuilt()
                local dataDir = makeTemp("pkg-hints-udata")
                local root = makeTemp("pkg-hints")
                local project = join(root, "game")
                runPackaged(root, dataDir, {"--quiet", "new", "game"})
                assert.is_true(exists(join(project, "tlconfig.lua")), "tecs new (packaged) failed")

                writeFile(join(project, "src", "broken.tl"), table.concat({
                    "local gfx <const> = require(\"tecs2d.gfx\")",
                    "",
                    "local function setup()",
                    "   local r = gfx.Rectangle(10)",
                    "   print(r.linewidth)",
                    "end",
                    "",
                    "return { setup = setup }",
                    "",
                }, "\n"))

                local out = runPackaged(project, dataDir, {"check", "--json"})
                local parsed = cli._internal.jsonModule().parse(out)
                assert.is_false(parsed.ok)
                local hints = {}
                for _, d in ipairs(parsed.diagnostics) do
                    if d.hint then hints[#hints + 1] = d.hint end
                end
                local joined = table.concat(hints, "\n")
                -- The arity error points at the call target...
                assert.matches("`tecs api gfx%.Rectangle`", joined)
                -- ...and the unknown field at its record type.
                assert.matches("`tecs api Rectangle`", joined)
                assert.matches("'linewidth' does not exist on Rectangle", joined)
            end)
        else
            it("skips packaged specs without LÖVE, Node, and a Tecs checkout", function()
                assert.is_true(true)
            end)
        end
    end)

    describe("mcp bridge", function()
        local frameworkDir = os.getenv("TECS_DIR")
        local hasFramework = frameworkDir and frameworkDir ~= ""
            and exists(join(frameworkDir, "src", "tecs", "utils", "json", "init.tl"))

        local function newServer()
            local bridge = require("tecs_cli.mcp_bridge")
            return bridge.new({
                version = "9.9.9",
                projectName = "spec-game",
                json = cli._internal.jsonModule(),
                kernelTools = {
                    {name = "screenshot", description = "d", inputSchema = {type = "object"}},
                },
                build = function() end,
                setEnv = function() end,
                unsetEnv = function() end,
                readBuildinfo = function() return nil end,
                log = function() end,
            })
        end

        if hasFramework then
            it("answers initialize with the server identity", function()
                local out = newServer():handleLine(
                    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}')
                assert.equals(1, #out)
                assert.matches('"name":"tecs"', out[1])
                assert.matches('"version":"9%.9%.9"', out[1])
                assert.matches('"listChanged":true', out[1])
            end)

            it("round-trips parsed empty tool schemas as {} in tools/list", function()
                -- Regression: kernel tools come from a PARSED JSON manifest; an
                -- empty properties object must not degrade to [] (strict MCP
                -- clients reject the whole tools list -- "tools fetch failed").
                local bridge = require("tecs_cli.mcp_bridge")
                local json = cli._internal.jsonModule()
                local parsedTools = json.parse('[{"name":"ping","description":"d",'
                    .. '"inputSchema":{"type":"object","properties":{},'
                    .. '"additionalProperties":false}}]')
                local server = bridge.new({
                    version = "9.9.9", projectName = "spec-game", json = json,
                    kernelTools = parsedTools,
                    build = function() end,
                    setEnv = function() end, unsetEnv = function() end,
                    readBuildinfo = function() return nil end,
                    log = function() end,
                })
                local out = server:handleLine('{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
                assert.matches('"properties":{}', out[1], 1, true)
                assert.equals(nil, out[1]:find('"properties":[]', 1, true))
            end)

            it("lists lifecycle tools alongside the game's kernel tools", function()
                local out = newServer():handleLine('{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
                assert.matches('"start_game"', out[1])
                assert.matches('"game_logs"', out[1])
                assert.matches('"screenshot"', out[1])
                -- The toolchain is CLI-only by design: no check/build/api/docs
                -- mirrors bloating the bridge manifest.
                assert.equals(nil, out[1]:find('"name":"check"', 1, true))
                assert.equals(nil, out[1]:find('"name":"api"', 1, true))
                assert.equals(nil, out[1]:find('"name":"integ"', 1, true))
            end)

            it("front-loads the bundled tool manifest when the cache is empty", function()
                local bridge = require("tecs_cli.mcp_bridge")
                local server = bridge.new({
                    version = "9.9.9",
                    projectName = "spec-game",
                    json = cli._internal.jsonModule(),
                    kernelTools = {
                        {name = "screenshot", description = "d", inputSchema = {type = "object"}},
                    },
                    -- No user-level cache yet (fresh machine): the manifest is
                    -- the front-load source, so the full set is advertised at
                    -- initialize before any start_game.
                    readDefaultTools = function() return nil end,
                    readBundledTools = function()
                        return {{name = "cmd_from_manifest", description = "d",
                            inputSchema = {type = "object"}}}
                    end,
                    build = function() end,
                    setEnv = function() end,
                    unsetEnv = function() end,
                    readBuildinfo = function() return nil end,
                    log = function() end,
                })
                local out = server:handleLine('{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
                assert.matches('"cmd_from_manifest"', out[1])
                assert.matches('"start_game"', out[1])
            end)

            it("runs lifecycle tools and wraps structured results", function()
                local out = newServer():handleLine(
                    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"game_status","arguments":{}}}')
                assert.matches('\\"running\\":false', out[1])
                assert.equals(nil, out[1]:match("isError"))
            end)

            it("errors on game tools when no game is running", function()
                local out = newServer():handleLine(
                    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}')
                assert.matches("start_game", out[1])
                assert.matches('"isError":true', out[1])
            end)

            it("rejects unknown methods and malformed lines", function()
                local server = newServer()
                local out = server:handleLine('{"jsonrpc":"2.0","id":5,"method":"resources/list"}')
                assert.matches("%-32601", out[1])
                out = server:handleLine("this is not json")
                assert.matches("%-32700", out[1])
            end)

            it("ignores notifications", function()
                local out = newServer():handleLine(
                    '{"jsonrpc":"2.0","method":"notifications/initialized"}')
                assert.equals(0, #out)
            end)
        else
            it("skips bridge specs without a Tecs checkout (set TECS_DIR)", function()
                assert.is_true(true)
            end)
        end
    end)

    describe("dist", function()
        local internal = cli._internal

        it("derives a sanitized name from the project directory", function()
            local root = makeTemp("Cool Game!!")
            withCwd(root, function()
                local name = internal.distName()
                assert.matches("Cool Game", name)
                assert.equals(nil, name:match("!"))
            end)
        end)

        it("generates build metadata with the dev flag", function()
            local root = makeTemp("buildinfo")
            withCwd(root, function()
                local dev = internal.buildinfoLua(true)
                assert.matches("dev = true", dev)
                assert.matches('cli = "%d+%.%d+%.%d+', dev)
                assert.matches('built = "%d%d%d%d%-%d%d%-%d%dT', dev)
                assert.matches("tecs%-cli%-spec%-buildinfo", dev)
                assert.matches("dev = false", internal.buildinfoLua(false))
                local chunk = assert(loadstring(dev))
                local info = chunk()
                assert.is_true(info.dev)
            end)
        end)

        it("patches the LÖVE Info.plist for the game", function()
            local plist = table.concat({
                "<dict>",
                "    <key>CFBundleIdentifier</key>",
                "    <string>org.love2d.love</string>",
                "    <key>CFBundleName</key>",
                "    <string>LÖVE</string>",
                "    <key>UTExportedTypeDeclarations</key>",
                "    <array>",
                "        <dict>",
                "            <key>UTTypeTagSpecification</key>",
                "            <dict>",
                "                <key>public.filename-extension</key>",
                "                <array>",
                "                    <string>love</string>",
                "                </array>",
                "            </dict>",
                "        </dict>",
                "    </array>",
                "</dict>",
            }, "\n")
            local patched = internal.patchPlist(plist, "mygame")
            assert.matches("org%.tecs2d%.mygame", patched)
            assert.matches("<string>mygame</string>", patched)
            assert.equals(nil, patched:match("UTExportedTypeDeclarations"))
            assert.equals(nil, patched:match("org%.love2d%.love"))
            assert.equals(nil, patched:match("UTTypeTagSpecification"))
            assert.equals("<dict>\n    <key>CFBundleIdentifier</key>\n"
                .. "    <string>org.tecs2d.mygame</string>\n"
                .. "    <key>CFBundleName</key>\n"
                .. "    <string>mygame</string>\n</dict>", patched)
        end)
    end)

    describe("path helpers", function()
        local internal = cli._internal
        local windows = {sep = "\\", isWindows = true, isMsys = false}
        local msys = {sep = "/", isWindows = false, isMsys = true}
        local posix = {sep = "/", isWindows = false, isMsys = false}

        after_each(function()
            internal.setPlatform(internal.detectPlatform())
        end)

        it("normalizes separators for the selected platform", function()
            internal.setPlatform(windows)
            assert.equals("a\\b\\c", internal.normalize("a/b/c"))
            assert.equals("C:\\x\\y", internal.normalize("C:/x/y"))

            internal.setPlatform(posix)
            assert.equals("a/b/c", internal.normalize("a\\b\\c"))
        end)

        it("converts drive letters to msys mount paths", function()
            internal.setPlatform(msys)
            assert.equals("/d/work/game", internal.normalize("D:\\work\\game"))
            assert.equals("/c/tools", internal.normalize("C:/tools"))
        end)

        it("joins path segments with the platform separator", function()
            internal.setPlatform(windows)
            assert.equals("C:\\x\\y\\z", internal.pathJoin("C:\\x", "y", "z"))
            assert.equals("a\\b", internal.pathJoin("a/", "/b"))

            internal.setPlatform(posix)
            assert.equals("/a/b/c", internal.pathJoin("/a", "b/", "c"))
            assert.equals("a/b", internal.pathJoin("a//", "b"))
        end)

        it("preserves absolute runtime paths when running from build", function()
            internal.setPlatform(posix)
            assert.equals("/Users/me/.cache/love", internal.pathFromBuild("/Users/me/.cache/love"))
            assert.equals("../tools/love", internal.pathFromBuild("tools/love"))

            internal.setPlatform(windows)
            assert.equals("C:\\cache\\lovec.exe", internal.pathFromBuild("C:/cache/lovec.exe"))
            assert.equals("..\\tools\\love.exe", internal.pathFromBuild("tools/love.exe"))
        end)

        it("computes dirname and relative paths", function()
            internal.setPlatform(posix)
            assert.equals("a/b", internal.dirname("a/b/c.txt"))
            assert.equals(".", internal.dirname("main.tl"))
            assert.equals("y/z.tl", internal.relativeTo("/x/y/z.tl", "/x"))
            assert.equals("z.tl", internal.relativeTo("/x/y/z.tl", "/x/y/"))
        end)

        it("matches copy exclusion patterns", function()
            assert.is_true(internal.shouldExclude("art/sprite.ase", {"*.ase"}))
            assert.is_false(internal.shouldExclude("art/sprite.png", {"*.ase"}))
            assert.is_true(internal.shouldExclude("vendor", {"vendor"}))
            assert.is_true(internal.shouldExclude("vendor/init.lua", {"vendor"}))
            assert.is_false(internal.shouldExclude("vendored/init.lua", {"vendor"}))
            assert.is_false(internal.shouldExclude("anything", nil))
        end)

        it("quotes shell arguments for each platform", function()
            internal.setPlatform(windows)
            assert.equals('"a ""b"" c"', internal.q('a "b" c'))

            internal.setPlatform(posix)
            assert.equals('"a \\"b\\" c"', internal.q('a "b" c'))
        end)
    end)

    describe("copyDir", function()
        local internal = cli._internal

        it("mirrors a source tree, honoring exclusions and deleting stale files", function()
            local root = makeTemp("copydir")
            local src = join(root, "from")
            local dst = join(root, "to")
            mkdirP(join(src, "nested"))
            writeFile(join(src, "keep.txt"), "keep")
            writeFile(join(src, "nested", "deep.txt"), "deep")
            writeFile(join(src, "sprite.ase"), "raw")
            mkdirP(dst)
            writeFile(join(dst, "stale.txt"), "old")

            internal.copyDir(src, dst, {"*.ase"})

            assert.equals("keep", readFile(join(dst, "keep.txt")))
            assert.equals("deep", readFile(join(dst, "nested", "deep.txt")))
            assert.is_false(exists(join(dst, "sprite.ase")))
            assert.is_false(exists(join(dst, "stale.txt")))
        end)

        it("overwrites changed files when mirroring again", function()
            local root = makeTemp("recopy")
            local src = join(root, "from")
            local dst = join(root, "to")
            mkdirP(src)
            writeFile(join(src, "file.txt"), "v1")

            internal.copyDir(src, dst)
            writeFile(join(src, "file.txt"), "v2")
            internal.copyDir(src, dst)

            assert.equals("v2", readFile(join(dst, "file.txt")))
        end)
    end)

    describe("runtime vendor pruning", function()
        it("checks generated files through the native filesystem", function()
            local root = makeTemp("native-file-check")
            writeFile(join(root, "generated.lua"), "return true\n")

            assert.is_true(cli._internal.isFile(join(root, "generated.lua")))
            assert.is_false(cli._internal.isFile(join(root, "missing.lua")))
            assert.is_false(cli._internal.isFile(root))
        end)

        it("stages the process worker entrypoint for game builds", function()
            local root = makeTemp("worker-runtime")
            local tecs2d = join(root, "build", "vendor", "share", "lua", "5.1", "tecs2d")
            mkdirP(join(tecs2d, "workers", "internal"))
            mkdirP(join(root, "build", "internal"))
            writeFile(join(tecs2d, "workers", "internal", "worker.lua"), "return true\n")
            writeFile(join(root, "build", "internal", "stale.lua"), "return false\n")

            withCwd(root, function()
                assert.is_true(cli._internal.stageWorkerRuntime(
                    join("build", "vendor", "share", "lua", "5.1", "tecs2d")))
            end)

            assert.equals("return true\n", readFile(join(root, "build", "internal", "worker.lua")))
            assert.is_false(exists(join(root, "build", "internal", "stale.lua")))
        end)

        it("keeps runtime modules while removing development-only files", function()
            local root = makeTemp("prune-vendor")
            local luaRoot = join(root, "build", "vendor", "share", "lua", "5.1")
            mkdirP(join(luaRoot, "teal"))
            mkdirP(join(luaRoot, "tlcli"))
            mkdirP(join(luaRoot, "tecs"))
            mkdirP(join(luaRoot, "tecs2d"))
            mkdirP(join(root, "build", "vendor", "lib", "luarocks"))
            mkdirP(join(root, "build", "vendor", "lib", "lua", "5.1"))
            mkdirP(join(root, "build", "vendor", "bin"))
            mkdirP(join(root, "build", "tecs"))

            writeFile(join(luaRoot, "runtime.lua"), "return true\n")
            writeFile(join(luaRoot, "runtime.tl"), "return true\n")
            writeFile(join(luaRoot, "tl.lua"), "return true\n")
            writeFile(join(luaRoot, "teal", "init.lua"), "return true\n")
            writeFile(join(luaRoot, "tlcli", "main.lua"), "return true\n")
            writeFile(join(luaRoot, "tecs", "init.lua"), "return true\n")
            writeFile(join(luaRoot, "tecs2d", "init.lua"), "return true\n")
            writeFile(join(root, "build", "vendor", "lib", "lua", "5.1", "runtime.so"), "native")
            writeFile(join(root, "build", "vendor", "lib", "luarocks", "manifest"), "metadata")
            writeFile(join(root, "build", "vendor", "bin", "tl"), "compiler")
            writeFile(join(root, "build", "tecs", "init.lua"), "return true\n")
            writeFile(join(root, "build", "tecs", "init.tl"), "return true\n")

            withCwd(root, function()
                cli._internal.pruneRuntimeVendor()
            end)

            assert.is_true(exists(join(luaRoot, "runtime.lua")))
            assert.is_true(exists(join(root, "build", "vendor", "lib", "lua", "5.1", "runtime.so")))
            assert.is_true(exists(join(root, "build", "tecs", "init.lua")))
            assert.is_false(exists(join(luaRoot, "runtime.tl")))
            assert.is_false(exists(join(luaRoot, "tl.lua")))
            assert.is_false(exists(join(luaRoot, "teal")))
            assert.is_false(exists(join(luaRoot, "tlcli")))
            assert.is_false(exists(join(luaRoot, "tecs")))
            assert.is_false(exists(join(luaRoot, "tecs2d")))
            assert.is_false(exists(join(root, "build", "vendor", "lib", "luarocks")))
            assert.is_false(exists(join(root, "build", "vendor", "bin")))
            assert.is_false(exists(join(root, "build", "tecs", "init.tl")))
        end)
    end)

    describe("needsUpdate", function()
        local internal = cli._internal

        it("reports missing or stale outputs", function()
            local root = makeTemp("mtime")
            local input = join(root, "input.tl")
            local output = join(root, "output.lua")
            writeFile(input, "in")

            assert.is_true(internal.needsUpdate(output, input))

            writeFile(output, "out")
            assert(lfs.touch(input, 1000000, 1000000))
            assert(lfs.touch(output, 2000000, 2000000))
            assert.is_false(internal.needsUpdate(output, input))

            assert(lfs.touch(input, 3000000, 3000000))
            assert.is_true(internal.needsUpdate(output, input))
        end)
    end)
end)
