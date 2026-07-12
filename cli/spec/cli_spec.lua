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
            assert.is_true(exists(join(project, "README.md")))
            assert.is_true(exists(join(project, "tlconfig.lua")))
            assert.is_true(exists(join(project, "game-dev-1.rockspec")))
            assert.is_false(exists(join(project, "project-dev-1.rockspec.in")))
            local rockspec = read_file(join(project, "game-dev-1.rockspec"))
            assert.matches('"tecs2d == dev%-1"', rockspec)
            assert.equals(nil, rockspec:match('"tl == dev%-1"'))
            assert.equals(nil, rockspec:match('"tecs == dev%-1"'))
            assert.equals(nil, rockspec:match('"luajit%-tl%-type'))
            assert.equals(nil, rockspec:match('"luasocket%-tl%-type'))
            assert.equals(nil, rockspec:match('"tecs%-love2d%-tl%-type'))
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

    describe("path helpers", function()
        local internal = cli._internal
        local windows = {sep = "\\", is_windows = true, is_msys = false, uses_cmd_shell = true}
        local msys = {sep = "/", is_windows = false, is_msys = true, uses_cmd_shell = true}
        local posix = {sep = "/", is_windows = false, is_msys = false, uses_cmd_shell = false}

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
            assert.equals("../.love12/love", internal.path_from_build(".love12/love"))

            internal.set_platform(windows)
            assert.equals("C:\\cache\\lovec.exe", internal.path_from_build("C:/cache/lovec.exe"))
            assert.equals("..\\.love12\\love.exe", internal.path_from_build(".love12/love.exe"))
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

    describe("Teal installation validation", function()
        it("requires the launcher and both namespaced module trees", function()
            local root = make_temp("teal-complete")
            mkdir_p(join(root, "src", "vendor", "bin"))
            mkdir_p(join(root, "src", "vendor", "share", "lua", "5.1", "teal"))
            mkdir_p(join(root, "src", "vendor", "share", "lua", "5.1", "tlcli"))

            with_cwd(root, function()
                assert.is_false(cli._internal.teal_compiler_complete())
                write_file(join("src", "vendor", "bin", "tl"), "launcher")
                write_file(join("src", "vendor", "share", "lua", "5.1", "teal", "init.lua"), "return {}")
                assert.is_false(cli._internal.teal_compiler_complete())
                write_file(join("src", "vendor", "share", "lua", "5.1", "tlcli", "main.lua"), "return {}")
                assert.is_true(cli._internal.teal_compiler_complete())
            end)
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
