-- Cross-platform task runner for Tecs starter projects.
-- Usage: tecs [--version] [--quiet] <command>

local argparse = require("tecs_cli.vendor.argparse")
local ansicolors = require("tecs_cli.vendor.ansicolors")
local have_lfs, lfs = pcall(require, "lfs")

local VERSION = "0.1.0"
local is_love_cli = rawget(_G, "TECS_LOVE_CLI") == true
local love_api = rawget(_G, "love")

-- Platform traits detected from the OS path separator. Held in mutable locals
-- so specs can substitute another platform via M._internal.set_platform.
local sep, is_msys, is_windows

local function detect_platform()
    local host_sep = package.config:sub(1, 1)
    local msys = os.getenv("MSYSTEM") ~= nil
    local separator = msys and "/" or host_sep
    return {
        sep = separator,
        is_msys = msys,
        is_windows = separator == "\\" and not msys,
    }
end

local function set_platform(platform)
    sep = platform.sep
    is_msys = platform.is_msys or false
    is_windows = platform.is_windows or false
end

set_platform(detect_platform())

-- TECS_DIR opts into copying framework sources from a local checkout.
local tecs_dir = os.getenv("TECS_DIR")
-- TECS_TEAL_DIR opts into loading the Teal compiler from a local
-- teal-language/tl checkout instead of the embedded copy.
local teal_dir = os.getenv("TECS_TEAL_DIR")
local vendor_lua = "src/vendor/share/lua/5.1"

-- Source-only asset extensions to exclude from build output and mtime checks.
local exclude_assets = {
    ["ase"] = true,
    ["aseprite"] = true,
}

-- The same extensions as glob patterns, for copy_dir exclusion lists.
local function exclude_asset_patterns()
    local patterns = {}
    for ext in pairs(exclude_assets) do
        patterns[#patterns + 1] = "*." .. ext
    end
    table.sort(patterns)
    return patterns
end

local color_enabled
local quiet = false

local function require_lfs()
    if not have_lfs then
        error("filesystem adapter unavailable; run tecs through its installed launcher", 0)
    end
    return lfs
end

local function env_flag(name)
    local value = os.getenv(name)
    return value ~= nil and value ~= "" and value ~= "0"
end

local function supports_color()
    if color_enabled ~= nil then return color_enabled end
    local term = os.getenv("TERM")
    if os.getenv("NO_COLOR") ~= nil then
        color_enabled = false
    elseif env_flag("FORCE_COLOR") or env_flag("CLICOLOR_FORCE") then
        color_enabled = true
    elseif term == "dumb" then
        color_enabled = false
    elseif is_windows then
        -- Plain cmd.exe consoles may not render ANSI codes, but ANSI-capable
        -- Windows environments (Windows Terminal, Git Bash) advertise
        -- themselves through these variables.
        color_enabled = os.getenv("WT_SESSION") ~= nil or term ~= nil
    else
        color_enabled = true
    end
    return color_enabled
end

local function color(spec, text)
    if not supports_color() then return text end
    return ansicolors("%{" .. spec .. "}" .. text .. "%{reset}")
end

-- Print a progress message to stderr (stdout is reserved for echoed commands).
local function status(message)
    if quiet then return end
    io.stderr:write(color("cyan", "==> ") .. message .. "\n")
end

local function fail(message)
    error({tecs_exit = true, message = message}, 0)
end


-- Quote a path so it survives as a single shell argument. cmd.exe expects
-- doubled quotes inside a quoted string; POSIX shells use backslash escapes.
local function q(path)
    path = tostring(path)
    if is_windows then
        return '"' .. path:gsub('"', '""') .. '"'
    end
    return '"' .. path:gsub('"', '\\"') .. '"'
end

local function source_path()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        return source:sub(2)
    end
    return nil
end

-- Convert path separators to the current platform's convention.
local function normalize(path)
    if is_windows then
        return (path:gsub("/", "\\"))
    end
    path = path:gsub("\\", "/")
    if is_msys then
        path = path:gsub("^(%a):", function(drive)
            return "/" .. drive:lower()
        end)
    end
    return path
end

-- Path spelling for Lua module search: forward slashes work for every tool we
-- invoke, including Windows Lua, so just flip backslashes.
local function lua_module_path(path)
    path = tostring(path):gsub("\\", "/")
    return path
end

-- Join path segments, collapsing extra separators while preserving an
-- absolute prefix (leading "/" on unix or a drive letter on Windows).
local function path_join(...)
    local parts = {...}
    local out = {}
    for i = 1, #parts do
        local part = tostring(parts[i])
        local unix_abs = i == 1 and part:match("^/")
        part = part:gsub("[/\\]+$", "")
        if not unix_abs then
            part = part:gsub("^[/\\]+", "")
        end
        if i == 1 and (part:match("^%a:[/\\]") or unix_abs) then
            part = parts[i]:gsub("[/\\]+$", "")
        end
        if part ~= "" then out[#out + 1] = part end
    end
    return normalize(table.concat(out, sep))
end

-- Resolve an executable path after the run command changes into build/.
local function path_from_build(path)
    path = normalize(path)
    if path:match("^%a:[/\\]") or path:match("^[/\\]") then return path end
    return path_join("..", path)
end

local HOT_RELOAD_STAMP = path_join("build", ".tecs-reload-stamp")

-- Directory portion of a path, or "." when there is no parent.
local function dirname(path)
    local dir = normalize(path):gsub("[/\\][^/\\]+$", "")
    if dir == path then return "." end
    if dir == "" then return "." end
    return dir
end

local function basename(path)
    return normalize(path):match("[^/\\]+$") or normalize(path)
end

-- True if a file or directory exists.
local function exists(path)
    return require_lfs().attributes(normalize(path)) ~= nil
end

-- Echo and run a shell command, raising on failure. Handles both the
-- LuaJIT/Lua 5.1 (numeric) and 5.2+ (boolean) os.execute return conventions.
local function run(cmd)
    if not quiet then
        io.stderr:write(color("black", cmd) .. "\n")
    end
    local a, _, c = os.execute(cmd)
    if a == true or a == 0 then return end
    local code = c or a or 1
    error("command failed with exit code " .. tostring(code), 0)
end

local function mkdir(path)
    path = normalize(path)
    if exists(path) then return end
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
            current = path_join(current, part)
        end
        if not exists(current) then
            local ok, err = require_lfs().mkdir(current)
            if not ok and not exists(current) then
                error("could not create directory " .. current .. ": " .. tostring(err), 0)
            end
        end
    end
end

local function write_file(path, content)
    mkdir(dirname(path))
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

local function is_dir(path)
    return require_lfs().attributes(normalize(path), "mode") == "directory"
end

local function is_empty_dir(path)
    if not is_dir(path) then return false end
    for entry in require_lfs().dir(normalize(path)) do
        if entry ~= "." and entry ~= ".." then
            return false
        end
    end
    return true
end

local function remove(path)
    path = normalize(path)
    if not exists(path) then return end
    local mode = require_lfs().attributes(path, "mode")
    if mode == "directory" then
        for entry in require_lfs().dir(path) do
            if entry ~= "." and entry ~= ".." then
                remove(path_join(path, entry))
            end
        end
        local ok, err = require_lfs().rmdir(path)
        if not ok then
            error("could not remove directory " .. path .. ": " .. tostring(err), 0)
        end
    else
        local ok, err = os.remove(path)
        if not ok then
            error("could not remove file " .. path .. ": " .. tostring(err), 0)
        end
    end
end

-- Escape a string for safe use as a literal inside a Lua pattern.
local function pattern_escape(s)
    return (s:gsub("([^%w])", "%%%1"))
end

local function should_exclude(rel, exclude)
    if not exclude then return false end
    for _, pattern in ipairs(exclude) do
        if rel == pattern or rel:match("^" .. pattern_escape(pattern) .. "[/\\]") then
            return true
        end
        local suffix = pattern:match("^%*%.(.+)$")
        if suffix and rel:match("%." .. pattern_escape(suffix) .. "$") then
            return true
        end
    end
    return false
end

local function copy_file(src, dst)
    mkdir(dirname(dst))
    local input = assert(io.open(src, "rb"))
    local content = input:read("*a")
    input:close()
    local output = assert(io.open(dst, "wb"))
    output:write(content)
    output:close()
end

local function walk_files(dir, out)
    dir = normalize(dir)
    out = out or {}
    local attr = require_lfs().attributes(dir)
    if not attr then return out end
    if attr.mode ~= "directory" then
        out[#out + 1] = dir
        return out
    end
    for entry in require_lfs().dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local path = path_join(dir, entry)
            local mode = require_lfs().attributes(path, "mode")
            if mode == "directory" then
                walk_files(path, out)
            elseif mode == "file" then
                out[#out + 1] = path
            end
        end
    end
    return out
end

local function relative_to(path, base)
    path = normalize(path)
    base = normalize(base):gsub("[/\\]+$", "")
    local prefix = pattern_escape(base) .. "[/\\]?"
    return path:gsub("^" .. prefix, "")
end

-- Mirror src into dst, deleting stale files in dst.
local function copy_dir(src, dst, exclude)
    src = normalize(src)
    dst = normalize(dst)
    mkdir(dst)
    local seen = {}
    for _, file in ipairs(walk_files(src, {})) do
        local rel = relative_to(file, src)
        if not should_exclude(rel, exclude) then
            local target = path_join(dst, rel)
            copy_file(file, target)
            seen[normalize(target)] = true
        end
    end
    for _, file in ipairs(walk_files(dst, {})) do
        local rel = relative_to(file, dst)
        if should_exclude(rel, exclude) or not seen[normalize(file)] then
            remove(file)
        end
    end
end

local function copy_love_dir(src, dst)
    assert(love_api, "embedded copy requires LÖVE")
    mkdir(dst)
    for _, entry in ipairs(love_api.filesystem.getDirectoryItems(src)) do
        local source = src .. "/" .. entry
        local target = path_join(dst, entry)
        local info = love_api.filesystem.getInfo(source)
        if info and info.type == "directory" then
            copy_love_dir(source, target)
        elseif info and info.type == "file" then
            local content, err = love_api.filesystem.read(source)
            if not content then
                error("could not read embedded file " .. source .. ": " .. tostring(err), 0)
            end
            write_file(target, content)
        end
    end
end

local function template_dir()
    local candidates = {}
    local module_path = source_path()
    if module_path then
        local module_dir = dirname(module_path)
        candidates[#candidates + 1] = path_join(module_dir, "templates/default")
        candidates[#candidates + 1] = path_join(module_dir, "../tecs_cli/templates/default")
    end
    if arg and arg[0] then
        local bin_dir = dirname(arg[0])
        candidates[#candidates + 1] = path_join(bin_dir, "../tecs_cli/templates/default")
        candidates[#candidates + 1] = path_join(bin_dir, "../templates/default")
    end
    for _, candidate in ipairs(candidates) do
        if is_dir(candidate) then
            return candidate
        end
    end
    error("could not find embedded default template", 0)
end

-- Per-user data directory where `tecs agent path` materializes bundled docs.
local data_dir_override
local function user_data_dir()
    if data_dir_override then return data_dir_override end
    if is_windows then
        local base = os.getenv("LOCALAPPDATA")
        if not base or base == "" then
            base = path_join(os.getenv("USERPROFILE") or ".", "AppData/Local")
        end
        return path_join(base, "tecs")
    end
    local xdg = os.getenv("XDG_DATA_HOME")
    if xdg and xdg ~= "" then
        return path_join(xdg, "tecs")
    end
    return path_join(os.getenv("HOME") or ".", ".local/share/tecs")
end

-- First non-heading paragraph line of a doc, used as its list description.
local function agent_doc_description(content)
    for line in content:gmatch("[^\r\n]+") do
        if not line:match("^#") and line:match("%S") then
            return (line:gsub("^%s+", ""):gsub("%s+$", ""))
        end
    end
    return ""
end

-- Bundled agent docs as {name, content}, sorted by name. Docs live in
-- tecs_cli/agents/ in the payload and the source tree.
local function list_agent_docs()
    local docs = {}
    if is_love_cli and love_api then
        for _, entry in ipairs(love_api.filesystem.getDirectoryItems("tecs_cli/agents")) do
            local name = entry:match("^(.+)%.md$")
            if name then
                local content, err = love_api.filesystem.read("tecs_cli/agents/" .. entry)
                if not content then
                    error("could not read embedded agent doc " .. entry .. ": " .. tostring(err), 0)
                end
                docs[#docs + 1] = {name = name, content = content}
            end
        end
    else
        local module_path = source_path()
        local dir = module_path and path_join(dirname(module_path), "agents")
        if dir and is_dir(dir) then
            for _, file in ipairs(walk_files(dir, {})) do
                local name = basename(file):match("^(.+)%.md$")
                if name then
                    local handle = assert(io.open(file, "rb"))
                    local content = handle:read("*a")
                    handle:close()
                    docs[#docs + 1] = {name = name, content = content}
                end
            end
        end
    end
    table.sort(docs, function(a, b) return a.name < b.name end)
    return docs
end

-- Modification time of a path (platform-specific units), or 0 if it is missing.
local function file_mtime(path)
    path = normalize(path)
    local mtime = require_lfs().attributes(path, "modification")
    return tonumber(mtime) or 0
end

-- True if output is missing or older than any input (incremental rebuild gate).
local function needs_update(output, ...)
    if not exists(output) then return true end
    local out_time = file_mtime(output)
    local inputs = {...}
    for i = 1, #inputs do
        if file_mtime(inputs[i]) > out_time then
            return true
        end
    end
    return false
end

-- Current working directory, normalized.
local function cwd()
    return normalize(require_lfs().currentdir() or ".")
end

-- All files under dir ending in suffix, as paths relative to the cwd.
local function list_files(dir, suffix)
    local files = {}
    for _, file in ipairs(walk_files(dir, {})) do
        if file:sub(-#suffix) == suffix then
            files[#files + 1] = relative_to(file, cwd())
        end
    end
    table.sort(files)
    return files
end

-- Every file under dir (follows symlinks), as paths relative to the cwd.
local function list_all_files(dir)
    local files = {}
    for _, file in ipairs(walk_files(dir, {})) do
        files[#files + 1] = relative_to(file, cwd())
    end
    table.sort(files)
    return files
end

-- Newest mtime anywhere under dir, ignoring source-only assets (e.g. .ase).
local function tree_mtime(dir)
    local latest = file_mtime(dir)
    for _, file in ipairs(list_all_files(dir)) do
        local ext = file:match("%.([^%.]+)$")
        if not exclude_assets[ext or ""] then
            latest = math.max(latest, file_mtime(file))
        end
    end
    return latest
end

-- Buildable Teal sources under src/, excluding vendored code and .d.tl decls.
local function list_teal_sources()
    local files = list_files("src", ".tl")
    local out = {}
    for _, file in ipairs(files) do
        local n = normalize(file)
        if not n:match("src[/\\]vendor[/\\]") and not n:match("%.d%.tl$") then
            out[#out + 1] = n
        end
    end
    return out
end

-- LUA_PATH entries letting `tl` resolve type defs and the vendored modules.
local function lua_path()
    local paths = {
        vendor_lua .. "/?.tl",
        vendor_lua .. "/?/init.tl",
        vendor_lua .. "/?.lua",
        vendor_lua .. "/?/init.lua",
        "",
    }
    if tecs_dir then
        table.insert(paths, 1, lua_module_path(tecs_dir) .. "/src/?.tl")
        table.insert(paths, 2, lua_module_path(tecs_dir) .. "/src/?/init.tl")
    end
    return table.concat(paths, ";")
end

-- When TECS_TEAL_DIR points at a teal-language/tl checkout, resolve the
-- compiler modules from that checkout ahead of the copy embedded in the
-- payload. The loader only claims teal/tlcli/compat53 module names and only
-- when the checkout provides the file, so everything else is untouched.
local teal_override_installed = false
local function install_teal_override()
    if not teal_dir or teal_override_installed then return end
    teal_override_installed = true
    local loaders = package.loaders or package.searchers
    table.insert(loaders, 1, function(name)
        if not (name:match("^teal$") or name:match("^teal%.")
            or name:match("^tlcli%.")
            or name:match("^compat53$") or name:match("^compat53%.")) then
            return nil
        end
        local base = lua_module_path(teal_dir)
        local rel = name:gsub("%.", "/")
        for _, candidate in ipairs({base .. "/" .. rel .. ".lua", base .. "/" .. rel .. "/init.lua"}) do
            local file = io.open(candidate, "rb")
            if file then
                local content = file:read("*a")
                file:close()
                local chunk, err = loadstring(content, "@" .. candidate)
                if not chunk then
                    error("TECS_TEAL_DIR module " .. candidate .. " failed to load: " .. tostring(err), 0)
                end
                return chunk
            end
        end
        return nil
    end)
end

-- Run fn with the embedded (or TECS_TEAL_DIR) Teal compiler importable and
-- os.exit trapped, restoring both afterwards. Returns the trapped exit code.
local function with_teal_env(fn)
    if not is_love_cli then
        error("embedded Teal compiler unavailable; run tecs through its installed launcher", 0)
    end

    install_teal_override()
    local previousPath = package.path
    local previousExit = os.exit
    local exitSignal = {}
    package.path = lua_path() .. ";" .. package.path
    rawset(os, "exit", function(code)
        exitSignal.code = tonumber(code) or 0
        error(exitSignal, 0)
    end)

    local ok, err = pcall(fn)
    rawset(os, "exit", previousExit)
    package.path = previousPath
    if not ok and err ~= exitSignal then error(err, 0) end
    return exitSignal.code or 0
end

local function run_tl(args)
    local code = with_teal_env(function()
        return require("tlcli.main")(args)
    end)
    if code ~= 0 then
        error("Teal failed with exit code " .. tostring(code), 0)
    end
end

-- Teal compiler API, importable from both the LÖVE payload and a source
-- checkout (specs); a TECS_TEAL_DIR checkout wins through the loader above.
local teal_api
local function load_teal_api()
    if teal_api then return teal_api end
    install_teal_override()
    if not is_love_cli then
        local module_path = source_path()
        local runtime = module_path and path_join(dirname(module_path), "runtime/teal")
        if runtime and is_dir(runtime) then
            local base = lua_module_path(runtime)
            package.path = base .. "/?.lua;" .. base .. "/?/init.lua;" .. package.path
        end
    end
    local ok, api = pcall(require, "teal.api.v2")
    if not ok then
        error("Teal compiler unavailable: " .. tostring(api), 0)
    end
    teal_api = api
    return teal_api
end

-- Read a framework module's Teal source from TECS_DIR or the embedded payload.
local function read_framework_source(name)
    local rel = name:gsub("%.", "/")
    for _, candidate in ipairs({rel .. ".tl", rel .. "/init.tl"}) do
        if tecs_dir then
            local file = io.open(path_join(tecs_dir, "src", candidate), "rb")
            if file then
                local content = file:read("*a")
                file:close()
                return content, path_join(tecs_dir, "src", candidate)
            end
        end
        if is_love_cli and love_api then
            local path = "payload/framework/" .. candidate
            local info = love_api.filesystem.getInfo(path)
            if info and info.type == "file" then
                return (love_api.filesystem.read(path)), path
            end
        end
    end
    return nil
end

-- Let require() resolve tecs.*/tecs2d.* by compiling framework Teal sources
-- in memory, so the CLI reuses framework modules (e.g. tecs.utils.json)
-- instead of shipping second implementations.
local framework_loader_installed = false
local function install_framework_loader()
    if framework_loader_installed then return end
    framework_loader_installed = true
    local loaders = package.loaders or package.searchers
    loaders[#loaders + 1] = function(name)
        if not (name == "tecs" or name:match("^tecs%.")
            or name == "tecs2d" or name:match("^tecs2d%.")) then
            return nil
        end
        local source, origin = read_framework_source(name)
        if not source then
            return "\n\tno framework source for '" .. name
                .. "' (set TECS_DIR or run tecs through its installed launcher)"
        end
        local lua_code = load_teal_api().gen(source)
        if not lua_code then
            error("framework module " .. name .. " failed to compile", 0)
        end
        local chunk, err = loadstring(lua_code, "@" .. lua_module_path(origin))
        if not chunk then
            error("framework module " .. name .. " failed to load: " .. tostring(err), 0)
        end
        return chunk
    end
end

-- The framework's JSON module backs all --json output.
local function json_module()
    install_framework_loader()
    local ok, json = pcall(require, "tecs.utils.json")
    if not ok then
        error("JSON output unavailable: " .. tostring(json), 0)
    end
    return json
end

-- Type-check sources through the Teal compiler API and return ok plus a flat
-- diagnostic list, instead of tlcli's human-readable report. Mirrors tlcli's
-- rules: syntax errors suppress a file's other diagnostics, disabled warnings
-- are dropped, and warnings promoted by warning_error fail the check.
local function collect_check_diagnostics(sources)
    local diagnostics = {}
    local check_ok = true

    local function add(err, severity, diag_kind)
        diagnostics[#diagnostics + 1] = {
            file = lua_module_path(err.filename or ""),
            line = tonumber(err.y) or 0,
            column = tonumber(err.x) or 0,
            severity = severity,
            kind = diag_kind,
            message = err.msg or "",
        }
        if err.tag then
            diagnostics[#diagnostics].tag = err.tag
        end
    end

    local code = with_teal_env(function()
        local configuration = require("tlcli.configuration")
        local driver = require("tlcli.driver")
        local tlconfig = configuration.get()
        configuration.merge_config_and_args(tlconfig, {include_dir = {}})
        local compiler = driver.setup_compiler(tlconfig)

        for _, source in ipairs(sources) do
            local _, _, err = driver.process_module(compiler, source)
            if err then
                check_ok = false
                add({filename = source, msg = err}, "error", "load")
            end
        end

        for name in compiler:loaded_files() do
            local _, errs = compiler:recall(name)
            if errs then
                if errs.syntax_errors and #errs.syntax_errors > 0 then
                    check_ok = false
                    for _, err in ipairs(errs.syntax_errors) do
                        add(err, "error", "syntax")
                    end
                else
                    for _, err in ipairs(errs.type_errors or {}) do
                        check_ok = false
                        add(err, "error", "type")
                    end
                    for _, warning in ipairs(errs.warnings or {}) do
                        if not tlconfig._disabled_warnings_set[warning.tag] then
                            if tlconfig._warning_errors_set[warning.tag] then
                                check_ok = false
                                add(warning, "error", "type")
                            else
                                add(warning, "warning", "warning")
                            end
                        end
                    end
                end
            end
        end
    end)
    if code ~= 0 then
        error("Teal failed with exit code " .. tostring(code), 0)
    end

    table.sort(diagnostics, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        if a.line ~= b.line then return a.line < b.line end
        if a.column ~= b.column then return a.column < b.column end
        return a.message < b.message
    end)
    return check_ok, diagnostics
end

local function love_bin()
    local supplied = os.getenv("TECS_LOVE_BIN")
    if supplied and supplied ~= "" then return normalize(supplied) end
    error("LÖVE runtime unavailable; run tecs through its installed launcher", 0)
end

local function embedded_dependencies_complete()
    return exists(path_join(vendor_lua, "tecs2d/init.tl"))
        and exists(path_join(vendor_lua, "love2d.d.tl"))
        and exists(path_join(vendor_lua, "ffi.d.tl"))
        and exists(path_join(vendor_lua, "socket.d.tl"))
        and exists(path_join(vendor_lua, "tecs2d/assets/fonts/tiny-font.fnt"))
        and exists(path_join(vendor_lua, "tecs2d/assets/fonts/tiny-font.png"))
end

local function copy_local_framework()
    if not tecs_dir then return false end
    local tecsSource = path_join(tecs_dir, "src/tecs")
    local tecs2dSource = path_join(tecs_dir, "src/tecs2d")
    local fonts = path_join(tecs_dir, "examples/shared/assets")
    if not exists(path_join(tecsSource, "init.tl"))
        or not exists(path_join(tecs2dSource, "init.tl"))
        or not exists(path_join(fonts, "tiny-font.fnt"))
        or not exists(path_join(fonts, "tiny-font.png")) then
        error("TECS_DIR is not a complete Tecs checkout: " .. tecs_dir, 0)
    end

    copy_dir(tecsSource, path_join(vendor_lua, "tecs"))
    copy_dir(tecs2dSource, path_join(vendor_lua, "tecs2d"))
    copy_file(path_join(fonts, "tiny-font.fnt"),
        path_join(vendor_lua, "tecs2d/assets/fonts/tiny-font.fnt"))
    copy_file(path_join(fonts, "tiny-font.png"),
        path_join(vendor_lua, "tecs2d/assets/fonts/tiny-font.png"))
    return true
end

local function ensure_vendor()
    if not is_love_cli then
        error("embedded dependencies unavailable; run tecs through its installed launcher", 0)
    end
    if not tecs_dir and embedded_dependencies_complete() then return end

    status(tecs_dir and "Preparing local Tecs dependencies..." or "Preparing embedded Tecs dependencies...")
    mkdir(vendor_lua)
    if not copy_local_framework() then
        copy_love_dir("payload/framework/tecs", path_join(vendor_lua, "tecs"))
        copy_love_dir("payload/framework/tecs2d", path_join(vendor_lua, "tecs2d"))
    end
    copy_love_dir("payload/types", vendor_lua)
end

-- Compile each changed Teal source to build/, mirroring the src/ layout.
local function compile_sources()
    local compiled = 0
    local pending = {}
    for _, src in ipairs(list_teal_sources()) do
        local rel = src:gsub("^src[/\\]", "")
        local lua_file = rel:gsub("%.tl$", ".lua")
        local out = path_join("build", lua_file)
        if needs_update(out, src, "tlconfig.lua") then
            if compiled == 0 then status("Compiling Teal...") end
            mkdir(dirname(out))
            if is_love_cli then
                pending[#pending + 1] = src
            else
                run_tl({"gen", src, "-o", out})
            end
            compiled = compiled + 1
        end
    end
    if #pending > 0 then
        local args = {"-q", "gen", "--root", "src", "--output-dir", "build"}
        for _, src in ipairs(pending) do args[#args + 1] = src end
        run_tl(args)
    end
    if compiled == 0 then status("Teal output is up to date.") end
    return compiled
end

-- Compile vendored Tecs/Tecs2D sources after staging them into build/. This
-- keeps the starter working with Teal releases that do not support `gen --root`.
local function compile_vendor_tecs_sources()
    local root = path_join("build/vendor/share/lua/5.1")
    local compiled = 0
    local pending = {}
    for _, src in ipairs(list_files(root, ".tl")) do
        local n = normalize(src)
        if (n:match("[/\\]tecs[/\\]") or n:match("[/\\]tecs2d[/\\]")) and not n:match("%.d%.tl$") then
            local out = n:gsub("%.tl$", ".lua")
            if needs_update(out, n, "tlconfig.lua") then
                if compiled == 0 then status("Compiling vendored Tecs...") end
                if is_love_cli then
                    pending[#pending + 1] = n
                else
                    run_tl({"gen", n, "-o", out})
                end
                compiled = compiled + 1
            end
        end
    end
    if #pending > 0 then
        local args = {"-q", "gen", "--root", root, "--output-dir", root}
        for _, src in ipairs(pending) do args[#args + 1] = src end
        run_tl(args)
        -- Teal's readers can remain pending finalization after an in-process
        -- compile. Windows will not delete those source files while their
        -- handles are open, so finalize them before pruning compiler inputs.
        collectgarbage("collect")
    end
end

-- Keep runtime modules and native libraries, but discard compiler inputs,
-- LuaRocks bookkeeping, and duplicate framework copies from the game bundle.
local function prune_runtime_vendor()
    local vendor = path_join("build", "vendor")
    local luaRoot = path_join(vendor, "share/lua/5.1")

    remove(path_join(vendor, "bin"))
    remove(path_join(vendor, "lib/luarocks"))
    remove(path_join(luaRoot, "teal"))
    remove(path_join(luaRoot, "tlcli"))
    remove(path_join(luaRoot, "tl.lua"))
    remove(path_join(luaRoot, "tecs"))
    remove(path_join(luaRoot, "tecs2d"))

    for _, source in ipairs(list_files("build", ".tl")) do
        remove(source)
    end
end

-- Copy assets/ into build/, skipping source-only files; stamp guards reruns.
-- Returns true when anything was copied.
local function copy_assets()
    if not exists("assets") then return false end
    local stamp = path_join("build/assets/.copy-stamp")
    if exists(stamp) and file_mtime(stamp) >= tree_mtime("assets") then
        status("Assets are up to date.")
        return false
    end
    status("Copying assets...")
    copy_dir("assets", "build/assets", exclude_asset_patterns())
    write_file(stamp, tostring(os.time()) .. "\n")
    return true
end

-- Stage the runtime Lua tree into build/ and compile framework sources.
-- Returns true when anything was staged.
local function copy_vendor()
    local required = path_join("build/tecs2d/init.lua")
    local stamp = path_join("build/.vendor-copy-stamp")
    local vendor_time = tree_mtime("src/vendor")
    if exists(required) and exists(stamp) and file_mtime(stamp) >= vendor_time then
        status("Runtime vendor tree is up to date.")
        return false
    end

    status("Preparing runtime vendor tree...")
    if exists("src/vendor") then
        copy_dir("src/vendor", "build/vendor")
    else
        mkdir("build/vendor")
    end

    compile_vendor_tecs_sources()

    local tecs = path_join("build/vendor/share/lua/5.1/tecs")
    local tecs2d = path_join("build/vendor/share/lua/5.1/tecs2d")
    if exists(tecs) then
        remove("build/tecs")
        copy_dir(tecs, "build/tecs")
    end
    if exists(tecs2d) then
        remove("build/tecs2d")
        copy_dir(tecs2d, "build/tecs2d")
    end
    local internal = path_join(tecs2d, "assets/internal")
    if exists(internal) then
        remove("build/internal")
        copy_dir(internal, "build/internal")
    end
    prune_runtime_vendor()
    write_file(stamp, tostring(os.time()) .. "\n")
    return true
end

-- Task table: each entry implements one `tecs <target>` command.
local tasks = {}

-- Forward declaration; assigned after the command table below.
local parser

function tasks.check(args)
    ensure_vendor()
    local sources = list_teal_sources()
    if args and args.json then
        local json = json_module()
        local check_ok, diagnostics = collect_check_diagnostics(sources)
        print(json.serialize({ok = check_ok, diagnostics = diagnostics}, true))
        if not check_ok then
            fail("typecheck reported errors")
        end
        return
    end
    status("Typechecking...")
    local tl_args = {"check"}
    for _, source in ipairs(sources) do tl_args[#tl_args + 1] = source end
    run_tl(tl_args)
end

function tasks.build()
    status("Building...")
    ensure_vendor()
    local changed = compile_sources() > 0
    if copy_assets() then changed = true end
    if copy_vendor() then changed = true end
    -- Only refresh the stamp when output changed, so a no-op rebuild does not
    -- trigger the running game's hot reload.
    if changed or not exists(HOT_RELOAD_STAMP) then
        write_file(HOT_RELOAD_STAMP, tostring(os.time()) .. "\n")
    end
end

function tasks.run()
    tasks.build()
    status("Launching game...")
    local executable = path_from_build(love_bin())
    if is_windows then
        run('cmd /C "set SDL_VIDEODRIVER=&& set SDL_AUDIODRIVER=&& cd /D build && '
            .. q(executable) .. ' ."')
    else
        run("cd build && env -u SDL_VIDEODRIVER -u SDL_AUDIODRIVER "
            .. q(executable) .. " .")
    end
end

function tasks.clean()
    status("Removing build artifacts...")
    remove("build")
end

function tasks.new(args)
    local target = args and args.project
    if not target or target == "" then
        fail("missing project path")
    end
    target = normalize(target)
    if exists(target) and not is_empty_dir(target) then
        fail("target already exists and is not empty: " .. target)
    end

    status("Creating project " .. target .. "...")
    mkdir(target)
    if is_love_cli then
        copy_love_dir("tecs_cli/templates/default", target)
    else
        copy_dir(template_dir(), target)
    end
    mkdir(path_join(target, "assets"))

    status("Project created. Next: cd " .. target .. " && tecs check")
end

function tasks.dev()
    if not tecs_dir then
        error("set TECS_DIR to a local Tecs checkout before running `tecs dev`", 0)
    end
    status("Preparing local Tecs development source...")
    ensure_vendor()
    status("Dev source copied. Re-run `tecs dev` after local framework changes.")
end

function tasks.agent(args)
    local docs = list_agent_docs()

    if args.agent_action == "list" then
        if args.json then
            local json = json_module()
            local listed = {}
            for _, doc in ipairs(docs) do
                listed[#listed + 1] = {
                    name = doc.name,
                    description = agent_doc_description(doc.content),
                }
            end
            print(json.serialize(listed, true))
            return
        end
        local width = 0
        for _, doc in ipairs(docs) do
            width = math.max(width, #doc.name)
        end
        for _, doc in ipairs(docs) do
            print(string.format("%-" .. width .. "s  %s", doc.name, agent_doc_description(doc.content)))
        end
        return
    end

    local name = args.name
    if not name or name == "" then
        fail("missing agent name; run `tecs agent list` to see what is available")
    end
    local names = {}
    for _, doc in ipairs(docs) do
        names[#names + 1] = doc.name
        if doc.name == name then
            local target = path_join(user_data_dir(), "agents", doc.name .. ".md")
            write_file(target, doc.content)
            print(target)
            return
        end
    end
    fail("unknown agent '" .. tostring(name) .. "'. Expected one of: " .. table.concat(names, ", "))
end

function tasks.completions(args)
    local p = parser()
    io.write(p["get_" .. args.shell .. "_complete"](p))
end

local M = {}

-- Runtime and project facts backing both info renderings.
local function gather_info()
    local love_version
    if love_api and love_api.getVersion then
        local major, minor, revision, codename = love_api.getVersion()
        love_version = table.concat({major, minor, revision}, ".")
        if codename and codename ~= "" then love_version = love_version .. " (" .. codename .. ")" end
    end

    local jitApi = rawget(_G, "jit")
    local project
    if exists("tlconfig.lua") and is_dir("src") then
        local root = cwd()
        project = {
            name = basename(root),
            path = root,
            built = exists("build/main.lua"),
        }
    end

    return {
        version = VERSION,
        love = love_version,
        lua = jitApi and jitApi.version or _VERSION,
        love_bin = os.getenv("TECS_LOVE_BIN"),
        tecs_dir = tecs_dir,
        teal_dir = teal_dir,
        project = project,
    }
end

local function print_info(args)
    local info = gather_info()

    if args and args.json then
        local json = json_module()
        print(json.serialize({
            version = info.version,
            love = info.love or json.NULL,
            lua = info.lua,
            love_bin = info.love_bin and lua_module_path(info.love_bin) or json.NULL,
            tecs_dir = info.tecs_dir and lua_module_path(info.tecs_dir) or json.NULL,
            teal_dir = info.teal_dir and lua_module_path(info.teal_dir) or json.NULL,
            project = info.project and {
                name = info.project.name,
                path = lua_module_path(info.project.path),
                built = info.project.built,
            } or json.NULL,
        }, true))
        return
    end

    print("Tecs CLI " .. info.version)
    if info.love then
        print("LÖVE " .. info.love)
    end
    print(info.lua)

    if info.project then
        print("")
        print("Project " .. info.project.name)
        print("  Path: " .. info.project.path)
        print("  Build: " .. (info.project.built and "ready" or "not built"))
        print("")
        print("Next: tecs run")
    else
        print("")
        print("Next: tecs new hello")
    end
end

tasks.info = print_info

local commands = {
    {
        name = "info",
        summary = "Show runtime and project information",
        description = "Show CLI, Love2D, and LuaJIT versions plus current project status and a next step.",
        action = print_info,
        setup = function(subcommand)
            subcommand:flag("--json", "Print runtime and project information as JSON on stdout.")
        end,
    },
    {
        name = "new",
        summary = "Create a new Tecs project",
        description = "Create a new fixed-layout Tecs project from the bundled starter source.",
        action = tasks.new,
        setup = function(subcommand)
            subcommand:argument("project", "Directory to create for the new project.")
        end,
    },
    {
        name = "run",
        summary = "Build and run the game",
        description = "Build the project, then launch the game from build/ with the cached LÖVE runtime.",
        action = tasks.run,
    },
    {
        name = "build",
        summary = "Compile without running",
        description = "Prepare embedded dependencies, compile Teal sources, copy assets, "
            .. "and refresh build output.",
        action = tasks.build,
    },
    {
        name = "check",
        summary = "Type-check all Teal source files",
        description = "Prepare embedded dependencies and run the Teal type checker over src/.",
        action = tasks.check,
        setup = function(subcommand)
            subcommand:flag("--json", "Print diagnostics as JSON on stdout.")
        end,
    },
    {
        name = "clean",
        summary = "Remove build artifacts",
        description = "Remove build/ while leaving prepared source dependencies in place.",
        action = tasks.clean,
    },
    {
        name = "dev",
        summary = "Prepare local Tecs source for development",
        description = "Copy local Tecs/Tecs2D sources from TECS_DIR into src/vendor/ for development iteration.",
        action = tasks.dev,
    },
    {
        name = "agent",
        summary = "List bundled agent docs or print one's path",
        description = "List the agent guides bundled with the CLI, or write one to the user data "
            .. "directory and print its absolute path for use in agent configuration.",
        action = tasks.agent,
        setup = function(subcommand)
            subcommand:argument("action", "Either `list` or `path`.")
                :target("agent_action")
                :choices({"list", "path"})
            subcommand:argument("name", "Agent doc name, required for `path`."):args("?")
            subcommand:flag("--json", "Print the listing as JSON on stdout.")
        end,
    },
    {
        name = "completions",
        summary = "Print a shell completion script",
        description = "Print a completion script for the given shell. Source it from your shell profile, "
            .. "e.g. `tecs completions zsh > ~/.config/tecs/completions.zsh`.",
        action = tasks.completions,
        setup = function(subcommand)
            subcommand:argument("shell", "Target shell."):choices({"bash", "zsh", "fish"})
        end,
    },
}

local function command_names()
    local names = {}
    for _, command in ipairs(commands) do
        names[#names + 1] = command.name
    end
    return table.concat(names, ", ")
end

local function print_help()
    io.write(color("bright cyan", "Tecs CLI ") .. color("black", VERSION) .. "\n\n")
    io.write(color("bright", "Usage: ") .. color("green", "tecs")
        .. " [--version] [--quiet] " .. color("cyan", "<command>") .. "\n\n")
    io.write(color("bright", "Commands:") .. "\n")
    for _, command in ipairs(commands) do
        io.write("  " .. color("cyan", string.format("%-13s", command.name)) .. command.summary .. "\n")
    end
    io.write("\n")
    io.write(color("magenta", "Tip:") .. [[ You can connect to your game using the built-in MCP server. Tell your
agent to launch the game and connect over MCP.

]])
    io.write(color("magenta", "Hot reload:") .. [[ while the game is running, rerun ]]
        .. color("cyan", "tecs build") .. [[ from another terminal.
A successful build updates build/.tecs-reload-stamp; the running game will
snapshot, restart, and restore state automatically.
]])
end

function parser()
    local p = argparse("tecs", "Build, check, run, and manage fixed-layout Tecs starter projects.")
    p:help_max_width(88)
    p:flag("--version", "Show version and exit")
    p:flag("-q --quiet", "Suppress progress output")
    p:command_target("command")
    p:require_command(false)

    for _, command in ipairs(commands) do
        local subcommand = p:command(command.name, command.description or command.summary)
            :summary(command.summary)
            :action(function(args)
                args.command = command.name
            end)
        if command.setup then
            command.setup(subcommand)
        end
    end

    p:command("help", "Show the Tecs CLI command overview.")
        :summary("Show command overview")
        :action(function(args)
            args.command = "help"
        end)
    return p
end

function M.run(argv)
    argv = argv or {}
    local ok, err = pcall(function()
        if #argv == 1 and (argv[1] == "-h" or argv[1] == "--help") then
            print_help()
            return
        end

        local ok, args = parser():pparse(argv)
        if not ok then
            fail(args)
        end
        quiet = args.quiet or false
        if args.version then
            print(VERSION)
            return
        end

        local target = args.command or "help"
        if target == "help" then
            print_help()
            return
        end

        local task = tasks[target]
        if not task then
            fail("unknown command '" .. tostring(target) .. "'. Expected one of: " .. command_names())
        end

        task(args)
    end)
    if not ok then
        if type(err) == "table" and err.tecs_exit then
            return false, err.message
        end
        return false, tostring(err)
    end
    return true
end

function M.main(argv)
    local ok, err = M.run(argv)
    if not ok then
        io.stderr:write(color("red bright", "error: ") .. tostring(err) .. "\n")
        os.exit(1)
    end
end

-- Test-only access to internal helpers; see spec/cli_spec.lua. set_platform
-- lets specs exercise other platforms' path handling on any host.
M._internal = {
    detect_platform = detect_platform,
    set_platform = set_platform,
    normalize = normalize,
    path_join = path_join,
    path_from_build = path_from_build,
    dirname = dirname,
    relative_to = relative_to,
    should_exclude = should_exclude,
    needs_update = needs_update,
    copy_dir = copy_dir,
    prune_runtime_vendor = prune_runtime_vendor,
    q = q,
    set_data_dir = function(path) data_dir_override = path end,
    list_agent_docs = list_agent_docs,
    agent_doc_description = agent_doc_description,
    json_module = json_module,
}

return M
