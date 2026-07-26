--[[
Build script: compile <specDir>/**/*.tl to <outDir>/**/*.lua in a single Lua
process, using `tl` as a library.

Much faster than forking `tl gen` per file (~180ms startup overhead each).
Does it in well under a second by keeping the Teal compiler loaded.

Code is emitted even when a file does not type-check, which is the reason this
exists rather than a `tl gen` rule. The suites predate the type checker being
run over them and report errors that are in the test code, not in what it
tests; refusing to build them would take the whole suite away over that.
]]

local SPEC_DIR = ... or "spec"
local OUT_PREFIX = select(2, ...) or "build/test_deps"
local LUA_DIR = select(3, ...)

-- The build system passes where the Teal compiler lives rather than relying on
-- an inherited LUA_PATH, since a path list is a semicolon list and CMake reads
-- one of those as its own.
if LUA_DIR then
    package.path = LUA_DIR .. "/?.lua;" .. LUA_DIR .. "/?/init.lua;" .. package.path
end

local tl = require("tl")
local ok_lfs, lfs = pcall(require, "lfs")

local function path_join(a, b)
    if a == "" then return b end
    return a .. "/" .. b
end

local function find_spec_files_lfs(root, files)
    for name in lfs.dir(root) do
        if name ~= "." and name ~= ".." then
            local path = path_join(root, name)
            local mode = lfs.attributes(path, "mode")
            if mode == "directory" then
                find_spec_files_lfs(path, files)
            elseif mode == "file" and path:match("%.tl$") then
                files[#files + 1] = path
            end
        end
    end
end

local function find_spec_files()
    local files = {}
    if ok_lfs then
        find_spec_files_lfs(SPEC_DIR, files)
        table.sort(files)
        return files
    end

    local handle = io.popen("find " .. SPEC_DIR .. " -name '*.tl' 2>/dev/null")
    if not handle then return files end
    for line in handle:lines() do
        if line and line ~= "" then
            files[#files + 1] = line
        end
    end
    handle:close()
    table.sort(files)
    return files
end

local function read_file(path)
    local fh, err = io.open(path, "r")
    if not fh then error(err) end
    local content = fh:read("*a")
    fh:close()
    return content
end

local function write_file(path, content)
    local dir = path:match("(.+)/[^/]+$")
    if dir then
        if ok_lfs then
            -- Seeded from the root when the path is absolute, since the build
            -- system passes one and rebuilding it relatively would create the
            -- tree under the working directory instead.
            local current = dir:sub(1, 1) == "/" and "/" or ""
            for part in dir:gmatch("[^/]+") do
                current = current == "/" and ("/" .. part)
                    or path_join(current, part)
                if lfs.attributes(current, "mode") ~= "directory" then
                    assert(lfs.mkdir(current))
                end
            end
        else
            os.execute("mkdir -p '" .. dir .. "'")
        end
    end
    local fh, err = io.open(path, "w")
    if not fh then error(err) end
    fh:write(content)
    fh:close()
end

-- The input path is kept whole rather than made relative to SPEC_DIR, because
-- a spec requires its helpers by full module name (`spec.tecs.test_helpers`)
-- and dropping the leading directory would put them somewhere that name
-- cannot reach.
local function output_path_for(input)
    local relative = input
    if SPEC_DIR:sub(1, 1) == "/" then
        relative = "spec/" .. input:sub(#SPEC_DIR + 2)
    end
    return ((OUT_PREFIX .. "/" .. relative):gsub("%.tl$", ".lua"))
end

local function file_mtime(path)
    if ok_lfs then
        return lfs.attributes(path, "modification") or 0
    end

    local handle = io.popen("stat -f %m '" .. path .. "' 2>/dev/null || stat -c %Y '" .. path .. "' 2>/dev/null")
    if not handle then return 0 end
    local result = handle:read("*a")
    handle:close()
    return math.floor(tonumber((result or ""):match("%d+")) or 0)
end

local function needs_rebuild(src_path, out_path)
    local src_mtime = file_mtime(src_path)
    local out_mtime = file_mtime(out_path)
    return out_mtime == 0 or out_mtime < src_mtime
end

local function main()
    local files = find_spec_files()
    if #files == 0 then return end

    local to_compile = {}
    for _, src_path in ipairs(files) do
        if needs_rebuild(src_path, output_path_for(src_path)) then
            to_compile[#to_compile + 1] = src_path
        end
    end

    if #to_compile == 0 then return end

    print(string.format("Compiling %d spec files...", #to_compile))
    local t0 = os.clock()

    local errors = 0
    for _, src_path in ipairs(to_compile) do
        local env = assert(tl.new_env({
            defaults = {
                gen_target = "5.1",
                gen_compat = "off",
            },
        }))
        local source = read_file(src_path)
        local code = tl.gen(source, env, nil)
        if code then
            write_file(output_path_for(src_path), code)
        else
            errors = errors + 1
            print("ERROR compiling " .. src_path)
        end
    end

    print(string.format("Compiled %d spec files in %.2fs%s",
        #to_compile, os.clock() - t0,
        errors > 0 and (" (" .. errors .. " errors)") or ""))

    if errors > 0 then
        os.exit(1)
    end
end

main()
