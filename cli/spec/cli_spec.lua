package.path = "./?.lua;./?/init.lua;" .. package.path

local lfs = require("lfs")
local cli = require("tecs_cli.cli")

local sep = package.config:sub(1, 1)
local is_windows = sep == "\\"

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
    local root = join(os.getenv("TMPDIR") or "/tmp", "tecs-cli-spec-" .. tostring(os.time()) .. "-" .. tostring(temp_counter))
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

    it("creates a new fixed-layout project from checked-in template source", function()
        local root = make_temp("new")
        local project = join(root, "sample-game")

        assert.is_true(cli.run({"new", project}))

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

        assert.is_true(cli.run({"new", project}))

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
            assert.is_true(cli.run({"clean"}))
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
            assert.is_true(cli.run({"wipe-clean"}))
        end)

        assert.is_false(exists(join(root, "build")))
        assert.is_false(exists(join(root, "src", "vendor")))
        assert.is_false(exists(join(root, ".love12")))
        assert.is_true(exists(join(root, "src", "main.tl")))
    end)

    it("forwards test arguments to a project-local busted executable", function()
        if is_windows then pending("project-local executable forwarding is covered on POSIX") end

        local root = make_temp("test")
        local bin = join(root, "src", "vendor", "bin")
        mkdir_p(bin)
        local output = join(root, "args.txt")
        local busted = join(bin, "busted")
        write_file(busted, "#!/bin/sh\nfor arg in \"$@\"; do printf '%s\\n' \"$arg\" >> args.txt; done\n")
        local chmod_ok = os.execute("chmod +x " .. string.format("%q", busted))
        assert.is_true(chmod_ok == true or chmod_ok == 0)

        with_cwd(root, function()
            assert.is_true(cli.run({"test", "--pattern", "player spec", "--verbose"}))
        end)

        local args = read_file(output)
        assert.matches("%-%-pattern\n", args)
        assert.matches("player spec\n", args)
        assert.matches("%-%-verbose\n", args)
    end)

    it("rejects a non-empty target for new projects without modifying it", function()
        local root = make_temp("existing")
        local project = join(root, "already-here")
        mkdir_p(project)
        write_file(join(project, "keep.txt"), "do not overwrite\n")

        local ok, err = cli.run({"new", project})

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
end)
