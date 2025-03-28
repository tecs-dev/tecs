--[[
Cyan script to auto-generate rockspecs from file discovery
Scans src/ and build/ directories to create accurate file lists
]]

local modules <const> = {
    {
        name = "tecs",
        description = "Core ECS framework"
    },
    {
        name = "tecs2d",
        description = "Love2D integration"
    },
    {
        name = "tecs_assets",
        description = "Asset loading system"
    },
    {
        name = "tecs_render",
        description = "3D rendering pipeline"
    },
    {
        name = "tecs_controller",
        description = "Controller input handling"
    }
}

-- File discovery using shell commands
local function scan_directory(dir: string, pattern: string): {string}
    local files: {string} = {}
    local command = string.format("find %s -name '%s' 2>/dev/null", dir, pattern)

    local handle = io.popen(command)
    if not handle then
        return files
    end

    local lines: {string} = {}
    for line in handle:lines() do
        if line and line ~= "" then
            lines[#lines + 1] = line
        end
    end

    handle:close()

    -- Sort manually to avoid cyan build system sorting issues
    table.sort(lines)

    return lines
end

local function file_to_module_name(file_path: string): string
    -- Convert src/tecs/init.tl -> tecs
    -- Convert src/tecs/internal/world.tl -> tecs.internal.world
    local parts = {}
    for part in file_path:gmatch("[^/]+") do
        parts[#parts + 1] = part
    end

    -- Remove 'src' or 'build' prefix
    if parts[1] == "src" or parts[1] == "build" then
        table.remove(parts, 1)
    end

    -- Remove .tl/.lua extension
    local last = parts[#parts]
    if last then
        last = last:gsub("%.tl$", ""):gsub("%.lua$", "")
        parts[#parts] = last
    end

    -- Handle init files: tecs/init -> tecs
    if parts[#parts] == "init" then
        table.remove(parts, #parts)
    end

    return table.concat(parts, ".")
end

-- Directory existence check using shell command
local function directory_exists(path: string): boolean
    local handle = io.popen("test -d '" .. path .. "' && echo 'exists' || echo 'missing'")
    if not handle then
        return false
    end

    local result = handle:read("*a"):gsub("\n", "")
    handle:close()
    return result == "exists"
end

local record ModuleFiles
    lua: {string}
    teal: {string}
end

local function discover_files_for_module(module_name: string): ModuleFiles
    local lua_files: {string} = {}
    local teal_files: {string} = {}

    -- Scan for .tl files in src/
    local src_dir = "src/" .. module_name
    if directory_exists(src_dir) then
        local tl_files = scan_directory(src_dir, "*.tl")
        for _, file_path in ipairs(tl_files) do
            local module_path = file_to_module_name(file_path)
            teal_files[#teal_files + 1] = string.format('            ["%s"] = "%s"', module_path, file_path)
        end
    end

    -- Scan for .lua files in build/
    local build_dir = "build/" .. module_name
    if directory_exists(build_dir) then
        local lua_file_list = scan_directory(build_dir, "*.lua")
        for _, file_path in ipairs(lua_file_list) do
            local module_path = file_to_module_name(file_path)
            lua_files[#lua_files + 1] = string.format('            ["%s"] = "%s"', module_path, file_path)
        end
    end

    return {lua = lua_files, teal = teal_files} as ModuleFiles
end

local function read_template(template_path: string): string
    local file = io.open(template_path, "r")
    if not file then
        error("Could not read template: " .. template_path)
    end

    local content = file:read("*all")
    file:close()
    return content
end

local function write_rockspec(module_name: string, content: string)
    local output_path = "build/" .. module_name .. ".tl-dev-1.rockspec"
    local file = io.open(output_path, "w")
    if not file then
        error("Could not write rockspec: " .. output_path)
    end
    file:write(content)
    file:close()
    print("Generated " .. output_path)
end

local function generate_rockspec_for_module(module_name: string)
    local template_path = "rockspec-templates/" .. module_name .. ".tl-dev-1.rockspec.template"
    local template = read_template(template_path)

    local files = discover_files_for_module(module_name)

    -- Replace placeholders
    local lua_files_str = ""
    if #files.lua > 0 then
        lua_files_str = table.concat(files.lua, ",\n")
    end

    local teal_files_str = ""
    if #files.teal > 0 then
        teal_files_str = table.concat(files.teal, ",\n")
    end

    local result = template:gsub("        %-%- {{LUA_FILES}}", lua_files_str)
    result = result:gsub("            %-%- {{TEAL_FILES}}", teal_files_str)

    write_rockspec(module_name, result)
end

local function main()
    print("Generating rockspecs...")

    for _, module in ipairs(modules) do
        local template_path = "rockspec-templates/" .. module.name .. ".tl-dev-1.rockspec.template"
        local file = io.open(template_path, "r")
        if file then
            file:close()
            generate_rockspec_for_module(module.name)
        else
            print("Warning: Template not found for " .. module.name)
        end
    end

    print("Rockspec generation complete!")
end

main()