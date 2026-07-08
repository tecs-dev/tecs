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
            assert.is_true(exists(join(project, "src", "conf.tl")))
            assert.is_true(exists(join(project, "src", "main.tl")))
            assert.is_true(is_dir(join(project, "assets")))
            assert.is_true(is_dir(join(project, "types")))
            assert.is_true(exists(join(project, "types", "love2d.d.tl")))
            assert.is_true(exists(join(project, "types", "string", "buffer.d.tl")))
            assert.is_true(exists(join(project, "types", "table", "new.d.tl")))

            local main = read_file(join(project, "src", "main.tl"))
            assert.matches('require%("tecs"%)', main)
            assert.matches('require%("tecs2d"%)', main)
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

        it("removes all generated project state with wipe-clean", function()
            local root = make_temp("wipe")
            mkdir_p(join(root, "build"))
            mkdir_p(join(root, "src", "vendor"))
            mkdir_p(join(root, ".love12"))
            mkdir_p(join(root, "src"))
            write_file(join(root, "src", "main.tl"), "return true\n")

            with_cwd(root, function()
                assert.is_true(cli.run({"wipe-clean", "--quiet"}))
            end)

            assert.is_false(exists(join(root, "build")))
            assert.is_false(exists(join(root, "src", "vendor")))
            assert.is_false(exists(join(root, ".love12")))
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

        it("prints the version with --version", function()
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
