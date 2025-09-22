--[[
Build script: compile spec/**/*.tl to build/test_deps/spec/**/*.lua
in a single Lua process, using `tl` as a library.

Much faster than forking `tl gen` per file (~180ms startup overhead each).
Does it in well under a second by keeping the Teal compiler loaded.
]]

local tl = require("tl")

local SPEC_DIR = "spec"
local OUT_PREFIX = "build/test_deps"

local function find_spec_files()
    local files = {}
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
        os.execute("mkdir -p '" .. dir .. "'")
    end
    local fh, err = io.open(path, "w")
    if not fh then error(err) end
    fh:write(content)
    fh:close()
end

local function output_path_for(input)
    return ((OUT_PREFIX .. "/" .. input):gsub("%.tl$", ".lua"))
end

local function file_mtime(path)
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
