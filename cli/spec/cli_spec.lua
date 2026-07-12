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

local function is_dir(path)
    return lfs.attributes(path, "mode") == "directory"
end

local function read_file(path)
    local f = assert(io.open(path, "rb"))
    local content = f:read("*a")
    f:close()
    return content
end

local function write_file(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

local function mkdir_p(path)
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

local function remove_tree(path)
    local mode = lfs.attributes(path, "mode")
    if not mode then return end
    if mode == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                remove_tree(join(path, entry))
            end
        end
        assert(lfs.rmdir(path))
    else
        assert(os.remove(path))
    end
end

local temp_counter = 0
local function temp_dir(name)
    temp_counter = temp_counter + 1
    local base = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    local root = join(base, "tecs-cli-spec-" .. name .. "-" .. tostring(os.time())
        .. "-" .. tostring(temp_counter))
    remove_tree(root)
    mkdir_p(root)
    return root
end

local function with_cwd(path, fn)
    local old = assert(lfs.currentdir())
    assert(lfs.chdir(path))
    local ok, err = pcall(fn)
    assert(lfs.chdir(old))
    if not ok then error(err, 0) end
end

describe("tecs CLI", function()
    local temps = {}

    after_each(function()
        for _, path in ipairs(temps) do
            remove_tree(path)
        end
        temps = {}
    end)

    local function make_temp(name)
        local path = temp_dir(name)
        temps[#temps + 1] = path
        return path
    end

    describe("commands", function()
        it("creates a new fixed-layout project from checked-in template source", function()
            local root = make_temp("new")
            local project = join(root, "sample-game")

            assert.is_true(cli.run({"--quiet", "new", project}))

            assert.is_true(exists(join(project, ".gitignore")))
            assert.is_true(exists(join(project, ".github", "workflows", "ci.yml")))
            assert.is_true(exists(join(project, ".mcp.json")))
            assert.is_true(exists(join(project, ".codex", "config.toml")))
            assert.is_true(exists(join(project, "README.md")))
            assert.is_true(exists(join(project, "tlconfig.lua")))
            assert.matches("Tecs project guide", read_file(join(project, "AGENTS.md")))
            assert.equals("@AGENTS.md\n", read_file(join(project, "CLAUDE.md")))
            assert.matches("tecs2d%.testing%.fixture",
                read_file(join(project, "spec", "game_lovespec.tl")))
            assert.matches("name: integration%-testing",
                read_file(join(project, ".claude", "skills", "integration-testing", "SKILL.md")))
            assert.is_false(exists(join(project, "game-dev-1.rockspec")))
            assert.is_true(exists(join(project, "src", "conf.tl")))
            assert.is_true(exists(join(project, "src", "main.tl")))
            assert.is_true(is_dir(join(project, "assets")))
            assert.is_false(exists(join(project, "types")))

            local main = read_file(join(project, "src", "main.tl"))
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
            local root = make_temp("empty")
            local project = join(root, "empty-project")
            mkdir_p(project)

            assert.is_true(cli.run({"--quiet", "new", project}))

            assert.is_true(exists(join(project, "src", "main.tl")))
            assert.is_true(exists(join(project, "tlconfig.lua")))
        end)

        it("removes build artifacts without touching source files", function()
            local root = make_temp("clean")
            mkdir_p(join(root, "build", "nested"))
            mkdir_p(join(root, "src"))
            write_file(join(root, "build", "nested", "artifact.lua"), "return true\n")
            write_file(join(root, "src", "main.tl"), "return true\n")

            with_cwd(root, function()
                assert.is_true(cli.run({"clean", "--quiet"}))
            end)

            assert.is_false(exists(join(root, "build")))
            assert.is_true(exists(join(root, "src", "main.tl")))
        end)

        it("rejects a non-empty target for new projects without modifying it", function()
            local root = make_temp("existing")
            local project = join(root, "already-here")
            mkdir_p(project)
            write_file(join(project, "keep.txt"), "do not overwrite\n")

            local ok, err = cli.run({"--quiet", "new", project})

            assert.is_false(ok)
            assert.matches("not empty", err)
            assert.equals("do not overwrite\n", read_file(join(project, "keep.txt")))
            assert.is_false(exists(join(project, "src", "main.tl")))
        end)

        it("reports unknown commands without running a task", function()
            local ok, err = cli.run({"nope"})

            assert.is_false(ok)
            assert.matches("unknown command", err)
        end)

        it("prints only the semantic version with --version", function()
            local printed = {}
            local real_print = print
            _G.print = function(...)
                printed[#printed + 1] = table.concat({...}, "\t")
            end
            local ok = cli.run({"--version"})
            _G.print = real_print

            assert.is_true(ok)
            assert.equals(1, #printed)
            assert.matches("^%d+%.%d+%.%d+$", printed[1])
        end)

        it("prints runtime versions and a next step with info", function()
            local printed = {}
            local real_print = print
            _G.print = function(...)
                printed[#printed + 1] = table.concat({...}, "\t")
            end
            local ok = cli.run({"info"})
            _G.print = real_print

            assert.is_true(ok)
            local output = table.concat(printed, "\n")
            assert.matches("Tecs CLI %d+%.%d+%.%d+", output)
            assert.matches("LuaJIT %d+%.%d+", output)
            assert.matches("Next: tecs new hello", output)
        end)

        it("includes current project information with info", function()
            local root = make_temp("version-project")
            mkdir_p(join(root, "src"))
            mkdir_p(join(root, "build"))
            write_file(join(root, "tlconfig.lua"), "return {}\n")
            write_file(join(root, "build", "main.lua"), "return true\n")

            local printed = {}
            local real_print = print
            _G.print = function(...)
                printed[#printed + 1] = table.concat({...}, "\t")
            end
            with_cwd(root, function()
                assert.is_true(cli.run({"info"}))
            end)
            _G.print = real_print

            local output = table.concat(printed, "\n")
            assert.matches("Project .-version%-project", output)
            assert.matches("Path: .-version%-project", output)
            assert.matches("Build: ready", output)
            assert.matches("Next: tecs run", output)
        end)

        it("suppresses status output with --quiet", function()
            local root = make_temp("quiet")
            mkdir_p(join(root, "build"))

            local captured = {}
            local real_stderr = io.stderr
            io.stderr = {
                write = function(_, ...)
                    captured[#captured + 1] = table.concat({...})
                end,
            }
            local run_ok, run_err = pcall(with_cwd, root, function()
                assert.is_true(cli.run({"clean", "--quiet"}))
            end)
            io.stderr = real_stderr
            assert(run_ok, run_err)

            assert.equals(0, #captured)
        end)
    end)

    describe("agent docs", function()
        local function capture_print(argv)
            local printed = {}
            local real_print = print
            _G.print = function(...)
                printed[#printed + 1] = table.concat({...}, "\t")
            end
            local ok, err = cli.run(argv)
            _G.print = real_print
            return ok, err, printed
        end

        it("lists bundled docs with descriptions", function()
            local ok, _, printed = capture_print({"agent", "list"})
            assert.is_true(ok)
            assert.matches("tecs%-project%s+Working guide", table.concat(printed, "\n"))
        end)

        it("materializes a doc into the data directory and prints its path", function()
            local root = make_temp("agent-path")
            cli._internal.set_data_dir(root)
            local run_ok, run_err = pcall(function()
                local ok, _, printed = capture_print({"agent", "path", "tecs-project"})
                assert.is_true(ok)
                assert.equals(1, #printed)
                assert.matches("agents", printed[1])
                assert.matches("Tecs project guide", read_file(printed[1]))
            end)
            cli._internal.set_data_dir(nil)
            assert(run_ok, run_err)
        end)

        it("overwrites a stale materialized doc", function()
            local root = make_temp("agent-refresh")
            cli._internal.set_data_dir(root)
            local run_ok, run_err = pcall(function()
                local _, _, printed = capture_print({"agent", "path", "tecs-project"})
                write_file(printed[1], "stale contents\n")
                local ok, _, reprinted = capture_print({"agent", "path", "tecs-project"})
                assert.is_true(ok)
                assert.equals(printed[1], reprinted[1])
                assert.matches("Tecs project guide", read_file(reprinted[1]))
            end)
            cli._internal.set_data_dir(nil)
            assert(run_ok, run_err)
        end)

        it("rejects unknown doc names without writing anything", function()
            local root = make_temp("agent-unknown")
            cli._internal.set_data_dir(root)
            local ok, err = cli.run({"agent", "path", "nope"})
            cli._internal.set_data_dir(nil)
            assert.is_true(not ok)
            assert.matches("unknown agent 'nope'", err)
            assert.is_true(not exists(join(root, "agents", "nope.md")))
        end)
    end)

    describe("completions", function()
        it("prints a completion function for bash", function()
            local captured = {}
            local real_write = io.write
            io.write = function(...)
                captured[#captured + 1] = table.concat({...})
                return true
            end
            local ok = cli.run({"completions", "bash"})
            io.write = real_write
            assert.is_true(ok)
            local script = table.concat(captured)
            assert.matches("_tecs%(%)", script)
            assert.matches("completions", script)
        end)

        it("adds positional choices to the fish script", function()
            local captured = {}
            local real_write = io.write
            io.write = function(...)
                captured[#captured + 1] = table.concat({...})
                return true
            end
            local ok = cli.run({"completions", "fish"})
            io.write = real_write
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
        local framework_dir = os.getenv("TECS_DIR")
        local has_framework = framework_dir and framework_dir ~= ""
            and exists(join(framework_dir, "src", "tecs", "utils", "json", "init.tl"))

        local function capture_print(argv)
            local printed = {}
            local real_print = print
            _G.print = function(...)
                printed[#printed + 1] = table.concat({...}, "\t")
            end
            local ok, err = cli.run(argv)
            _G.print = real_print
            return ok, err, printed
        end

        if has_framework then
            it("emits runtime info as sorted JSON", function()
                local ok, _, printed = capture_print({"info", "--json"})
                assert.is_true(ok)
                assert.equals(1, #printed)
                assert.matches('"version":"%d+%.%d+%.%d+"', printed[1])
                assert.matches('"love":null', printed[1])
                assert.matches('"project":null', printed[1])
            end)

            it("lists agent docs as JSON", function()
                local ok, _, printed = capture_print({"agent", "list", "--json"})
                assert.is_true(ok)
                assert.matches('"name":"tecs%-project"', printed[1])
                assert.matches('"description":"Working guide', printed[1])
            end)

            it("describes the current project in info --json", function()
                local root = make_temp("info-json")
                mkdir_p(join(root, "src"))
                write_file(join(root, "tlconfig.lua"), "return {}\n")

                local ok, _, printed
                with_cwd(root, function()
                    ok, _, printed = capture_print({"info", "--json"})
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
            local root = make_temp("integ-nolove")
            mkdir_p(join(root, "src"))
            mkdir_p(join(root, "spec"))
            write_file(join(root, "tlconfig.lua"), "return {}\n")

            local ok, err
            with_cwd(root, function()
                ok, err = cli.run({"integ"})
            end)
            assert.is_true(not ok)
            assert.matches("installed launcher", err)
        end)

        it("points check --json at the installed launcher outside LÖVE", function()
            local root = make_temp("check-json-nolove")
            mkdir_p(join(root, "src"))
            write_file(join(root, "tlconfig.lua"), "return {}\n")

            local ok, err
            with_cwd(root, function()
                ok, err = cli.run({"check", "--json"})
            end)
            assert.is_true(not ok)
            assert.matches("installed launcher", err)
        end)
    end)

    describe("rock vendoring", function()
        local internal = cli._internal

        it("parses rock arguments with optional versions", function()
            local name, version = internal.parse_rock_arg("Inspect")
            assert.equals("inspect", name)
            assert.equals(nil, version)
            name, version = internal.parse_rock_arg("inspect@3.1.1-0")
            assert.equals("inspect", name)
            assert.equals("3.1.1-0", version)
        end)

        it("orders rock versions like LuaRocks", function()
            assert.is_true(internal.rock_version_less("1.2-1", "1.10-1"))
            assert.is_true(internal.rock_version_less("1.0-1", "1.0-2"))
            assert.is_true(internal.rock_version_less("2.0-1", "3.1.1-0"))
            assert.is_true(internal.rock_version_less("3.1-1", "3.1.1-0"))
            assert.is_true(internal.rock_version_less("scm-1", "1.0-1"))
            assert.is_true(not internal.rock_version_less("1.0-1", "scm-1"))
        end)

        it("parses the repository section of a luarocks manifest", function()
            local repository = internal.parse_luarocks_manifest(table.concat({
                'commands = {}',
                'modules = {}',
                'repository = {',
                '   inspect = {',
                '      ["1.0-1"] = {',
                '         {',
                '            arch = "rockspec"',
                '         }, {',
                '            arch = "src"',
                '         }',
                '      }',
                '   },',
                '   ["inspect-tl-type"] = {',
                '      ["0.0.1-1"] = {',
                '         {',
                '            arch = "rockspec"',
                '         }',
                '      }',
                '   }',
                '}',
            }, "\n"))
            assert.equals("src", repository["inspect"]["1.0-1"][2].arch)
            assert.equals("rockspec", repository["inspect-tl-type"]["0.0.1-1"][1].arch)
            assert.equals(nil, repository["inspect-tl-type"]["0.0.1-1"][2])
        end)

        it("plans pure-Lua modules and type declaration installs", function()
            local plan = internal.plan_rock_files({
                package = "sample",
                build = {
                    type = "builtin",
                    modules = {
                        ["foo.bar"] = "src/foo/bar.lua",
                        foo = "src/foo/init.lua",
                    },
                    install = {lua = {"types/sample/sample.d.tl"}},
                },
            })
            local dests = {}
            for _, item in ipairs(plan) do dests[#dests + 1] = item.dest end
            assert.equals("foo/bar.lua foo/init.lua sample.d.tl", table.concat(dests, " "))
        end)

        it("rejects rocks that are not pure Lua", function()
            local ok, err = pcall(internal.plan_rock_files, {
                package = "native",
                build = {type = "builtin", modules = {core = "src/core.c"}},
            })
            assert.is_true(not ok)
            assert.matches("native modules", err.message)

            ok, err = pcall(internal.plan_rock_files, {
                package = "cmake-rock",
                build = {type = "cmake"},
            })
            assert.is_true(not ok)
            assert.matches("only pure%-Lua rocks", err.message)
        end)

        it("round-trips the vendored rock manifest at the project root", function()
            local root = make_temp("rocks-manifest")
            with_cwd(root, function()
                internal.write_rocks_manifest({
                    inspect = {
                        version = "3.1.1-0",
                        direct = true,
                        deps = {"inspect-tl-type"},
                        files = {"share/lua/5.1/inspect.lua"},
                    },
                })
                assert.is_true(exists(join(root, "tecs-rocks.lua")))
                local manifest = internal.read_rocks_manifest()
                assert.equals("3.1.1-0", manifest.inspect.version)
                assert.is_true(manifest.inspect.direct)
                assert.equals("inspect-tl-type", manifest.inspect.deps[1])
                assert.equals("share/lua/5.1/inspect.lua", manifest.inspect.files[1])
            end)
        end)

        it("reads the pre-0.3 manifest location and migrates it on write", function()
            local root = make_temp("rocks-legacy")
            with_cwd(root, function()
                mkdir_p(join(root, "src", "vendor"))
                write_file(join(root, "src", "vendor", "rocks.lua"),
                    'return {inspect = {version = "2.0-1", direct = true, deps = {}, files = {}}}\n')
                local manifest = internal.read_rocks_manifest()
                assert.equals("2.0-1", manifest.inspect.version)
                internal.write_rocks_manifest(manifest)
                assert.is_true(exists(join(root, "tecs-rocks.lua")))
                assert.is_true(not exists(join(root, "src", "vendor", "rocks.lua")))
            end)
        end)

        it("garbage-collects rocks nothing depends on, deleting their files", function()
            local root = make_temp("rocks-gc")
            with_cwd(root, function()
                mkdir_p(join(root, "src", "vendor", "share", "lua", "5.1"))
                write_file(join(root, "src", "vendor", "share", "lua", "5.1", "keep.lua"), "return 1\n")
                write_file(join(root, "src", "vendor", "share", "lua", "5.1", "drop.lua"), "return 2\n")
                local manifest = {
                    keeper = {version = "1.0-1", direct = true, deps = {"kept-dep"},
                        files = {"share/lua/5.1/keep.lua"}},
                    ["kept-dep"] = {version = "1.0-1", direct = false, deps = {}, files = {}},
                    orphan = {version = "1.0-1", direct = false, deps = {},
                        files = {"share/lua/5.1/drop.lua"}},
                }
                local removed = internal.rocks_gc(manifest)
                assert.equals("orphan", table.concat(removed, " "))
                assert.is_true(manifest.keeper ~= nil and manifest["kept-dep"] ~= nil)
                assert.equals(nil, manifest.orphan)
                assert.is_true(exists(join(root, "src", "vendor", "share", "lua", "5.1", "keep.lua")))
                assert.is_true(not exists(join(root, "src", "vendor", "share", "lua", "5.1", "drop.lua")))
            end)
        end)
    end)

    describe("path helpers", function()
        local internal = cli._internal
        local windows = {sep = "\\", is_windows = true, is_msys = false}
        local msys = {sep = "/", is_windows = false, is_msys = true}
        local posix = {sep = "/", is_windows = false, is_msys = false}

        after_each(function()
            internal.set_platform(internal.detect_platform())
        end)

        it("normalizes separators for the selected platform", function()
            internal.set_platform(windows)
            assert.equals("a\\b\\c", internal.normalize("a/b/c"))
            assert.equals("C:\\x\\y", internal.normalize("C:/x/y"))

            internal.set_platform(posix)
            assert.equals("a/b/c", internal.normalize("a\\b\\c"))
        end)

        it("converts drive letters to msys mount paths", function()
            internal.set_platform(msys)
            assert.equals("/d/work/game", internal.normalize("D:\\work\\game"))
            assert.equals("/c/tools", internal.normalize("C:/tools"))
        end)

        it("joins path segments with the platform separator", function()
            internal.set_platform(windows)
            assert.equals("C:\\x\\y\\z", internal.path_join("C:\\x", "y", "z"))
            assert.equals("a\\b", internal.path_join("a/", "/b"))

            internal.set_platform(posix)
            assert.equals("/a/b/c", internal.path_join("/a", "b/", "c"))
            assert.equals("a/b", internal.path_join("a//", "b"))
        end)

        it("preserves absolute runtime paths when running from build", function()
            internal.set_platform(posix)
            assert.equals("/Users/me/.cache/love", internal.path_from_build("/Users/me/.cache/love"))
            assert.equals("../tools/love", internal.path_from_build("tools/love"))

            internal.set_platform(windows)
            assert.equals("C:\\cache\\lovec.exe", internal.path_from_build("C:/cache/lovec.exe"))
            assert.equals("..\\tools\\love.exe", internal.path_from_build("tools/love.exe"))
        end)

        it("computes dirname and relative paths", function()
            internal.set_platform(posix)
            assert.equals("a/b", internal.dirname("a/b/c.txt"))
            assert.equals(".", internal.dirname("main.tl"))
            assert.equals("y/z.tl", internal.relative_to("/x/y/z.tl", "/x"))
            assert.equals("z.tl", internal.relative_to("/x/y/z.tl", "/x/y/"))
        end)

        it("matches copy exclusion patterns", function()
            assert.is_true(internal.should_exclude("art/sprite.ase", {"*.ase"}))
            assert.is_false(internal.should_exclude("art/sprite.png", {"*.ase"}))
            assert.is_true(internal.should_exclude("vendor", {"vendor"}))
            assert.is_true(internal.should_exclude("vendor/init.lua", {"vendor"}))
            assert.is_false(internal.should_exclude("vendored/init.lua", {"vendor"}))
            assert.is_false(internal.should_exclude("anything", nil))
        end)

        it("quotes shell arguments for each platform", function()
            internal.set_platform(windows)
            assert.equals('"a ""b"" c"', internal.q('a "b" c'))

            internal.set_platform(posix)
            assert.equals('"a \\"b\\" c"', internal.q('a "b" c'))
        end)
    end)

    describe("copy_dir", function()
        local internal = cli._internal

        it("mirrors a source tree, honoring exclusions and deleting stale files", function()
            local root = make_temp("copydir")
            local src = join(root, "from")
            local dst = join(root, "to")
            mkdir_p(join(src, "nested"))
            write_file(join(src, "keep.txt"), "keep")
            write_file(join(src, "nested", "deep.txt"), "deep")
            write_file(join(src, "sprite.ase"), "raw")
            mkdir_p(dst)
            write_file(join(dst, "stale.txt"), "old")

            internal.copy_dir(src, dst, {"*.ase"})

            assert.equals("keep", read_file(join(dst, "keep.txt")))
            assert.equals("deep", read_file(join(dst, "nested", "deep.txt")))
            assert.is_false(exists(join(dst, "sprite.ase")))
            assert.is_false(exists(join(dst, "stale.txt")))
        end)

        it("overwrites changed files when mirroring again", function()
            local root = make_temp("recopy")
            local src = join(root, "from")
            local dst = join(root, "to")
            mkdir_p(src)
            write_file(join(src, "file.txt"), "v1")

            internal.copy_dir(src, dst)
            write_file(join(src, "file.txt"), "v2")
            internal.copy_dir(src, dst)

            assert.equals("v2", read_file(join(dst, "file.txt")))
        end)
    end)

    describe("runtime vendor pruning", function()
        it("keeps runtime modules while removing development-only files", function()
            local root = make_temp("prune-vendor")
            local lua_root = join(root, "build", "vendor", "share", "lua", "5.1")
            mkdir_p(join(lua_root, "teal"))
            mkdir_p(join(lua_root, "tlcli"))
            mkdir_p(join(lua_root, "tecs"))
            mkdir_p(join(lua_root, "tecs2d"))
            mkdir_p(join(root, "build", "vendor", "lib", "luarocks"))
            mkdir_p(join(root, "build", "vendor", "lib", "lua", "5.1"))
            mkdir_p(join(root, "build", "vendor", "bin"))
            mkdir_p(join(root, "build", "tecs"))

            write_file(join(lua_root, "runtime.lua"), "return true\n")
            write_file(join(lua_root, "runtime.tl"), "return true\n")
            write_file(join(lua_root, "tl.lua"), "return true\n")
            write_file(join(lua_root, "teal", "init.lua"), "return true\n")
            write_file(join(lua_root, "tlcli", "main.lua"), "return true\n")
            write_file(join(lua_root, "tecs", "init.lua"), "return true\n")
            write_file(join(lua_root, "tecs2d", "init.lua"), "return true\n")
            write_file(join(root, "build", "vendor", "lib", "lua", "5.1", "runtime.so"), "native")
            write_file(join(root, "build", "vendor", "lib", "luarocks", "manifest"), "metadata")
            write_file(join(root, "build", "vendor", "bin", "tl"), "compiler")
            write_file(join(root, "build", "tecs", "init.lua"), "return true\n")
            write_file(join(root, "build", "tecs", "init.tl"), "return true\n")

            with_cwd(root, function()
                cli._internal.prune_runtime_vendor()
            end)

            assert.is_true(exists(join(lua_root, "runtime.lua")))
            assert.is_true(exists(join(root, "build", "vendor", "lib", "lua", "5.1", "runtime.so")))
            assert.is_true(exists(join(root, "build", "tecs", "init.lua")))
            assert.is_false(exists(join(lua_root, "runtime.tl")))
            assert.is_false(exists(join(lua_root, "tl.lua")))
            assert.is_false(exists(join(lua_root, "teal")))
            assert.is_false(exists(join(lua_root, "tlcli")))
            assert.is_false(exists(join(lua_root, "tecs")))
            assert.is_false(exists(join(lua_root, "tecs2d")))
            assert.is_false(exists(join(root, "build", "vendor", "lib", "luarocks")))
            assert.is_false(exists(join(root, "build", "vendor", "bin")))
            assert.is_false(exists(join(root, "build", "tecs", "init.tl")))
        end)
    end)

    describe("needs_update", function()
        local internal = cli._internal

        it("reports missing or stale outputs", function()
            local root = make_temp("mtime")
            local input = join(root, "input.tl")
            local output = join(root, "output.lua")
            write_file(input, "in")

            assert.is_true(internal.needs_update(output, input))

            write_file(output, "out")
            assert(lfs.touch(input, 1000000, 1000000))
            assert(lfs.touch(output, 2000000, 2000000))
            assert.is_false(internal.needs_update(output, input))

            assert(lfs.touch(input, 3000000, 3000000))
            assert.is_true(internal.needs_update(output, input))
        end)
    end)
end)
