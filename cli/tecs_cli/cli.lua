-- Cross-platform task runner for Tecs starter projects.
-- Usage: tecs [--version] [--quiet] <command>

local argparse = require("tecs_cli.vendor.argparse")
local ansicolors = require("tecs_cli.vendor.ansicolors")
local have_lfs, lfs = pcall(require, "lfs")

local VERSION = "0.7.0"
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

local function copy_love_dir(src, dst, depth)
    assert(love_api, "embedded copy requires LÖVE")
    depth = (depth or 0) + 1
    if depth > 32 then
        error("embedded directory nests too deep (malformed payload?): " .. src, 0)
    end
    mkdir(dst)
    for _, entry in ipairs(love_api.filesystem.getDirectoryItems(src)) do
        -- Guard against self-referential or path-shaped entries from
        -- malformed zip archives, which would otherwise recurse forever.
        local plain = entry ~= "" and entry ~= "." and entry ~= ".."
            and not entry:match("[/\\]")
        if plain then
            local source = src .. "/" .. entry
            local target = path_join(dst, entry)
            local info = love_api.filesystem.getInfo(source)
            if info and info.type == "directory" then
                copy_love_dir(source, target, depth)
            elseif info and info.type == "file" then
                local content, err = love_api.filesystem.read(source)
                if not content then
                    error("could not read embedded file " .. source .. ": " .. tostring(err), 0)
                end
                write_file(target, content)
            end
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

-- Per-user cache directory, matching the launchers' TECS_CACHE_DIR handling.
local function cache_root()
    local override = os.getenv("TECS_CACHE_DIR")
    if override and override ~= "" then return normalize(override) end
    if is_windows then
        local base = os.getenv("LOCALAPPDATA")
        if not base or base == "" then
            base = path_join(os.getenv("USERPROFILE") or ".", "AppData/Local")
        end
        return path_join(base, "tecs")
    end
    local xdg = os.getenv("XDG_CACHE_HOME")
    if xdg and xdg ~= "" then
        return path_join(xdg, "tecs")
    end
    return path_join(os.getenv("HOME") or ".", ".cache/tecs")
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
    remove(path_join(vendor, "rocks.lua"))
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

--------------------------------------------------------------------------------
-- Rock vendoring: a minimal luarocks.org client. Rocks are fetched over the
-- LÖVE runtime's HTTPS support, validated as pure Lua, and copied into
-- src/vendor/ so the game build stays self-contained. The LuaRocks client is
-- never involved.
--------------------------------------------------------------------------------

-- The manifest lives at the project root so it is committed (src/vendor/ is
-- generated and typically gitignored); check/build restore missing rocks
-- from it on fresh clones.
local ROCKS_MANIFEST = "tecs-rocks.lua"
local LEGACY_ROCKS_MANIFEST = "src/vendor/rocks.lua"
local LUAROCKS_SERVER = "https://luarocks.org"

local function fetch_url(url)
    local ok, https = pcall(require, "https")
    if not ok then
        error("network access unavailable; run tecs through its installed launcher", 0)
    end
    local code, body = https.request(url)
    if code ~= 200 or not body then
        error("download failed (HTTP " .. tostring(code) .. "): " .. url, 0)
    end
    return body
end

-- Run untrusted registry Lua (manifests, rockspecs) in an empty sandbox and
-- return the globals it assigned.
local function load_lua_table(content, chunkname)
    local chunk, err = loadstring(content, chunkname)
    if not chunk then
        error(chunkname .. " failed to parse: " .. tostring(err), 0)
    end
    local env = {}
    setfenv(chunk, env)
    local ok, result = pcall(chunk)
    if not ok then
        error(chunkname .. " failed to run: " .. tostring(result), 0)
    end
    return result, env
end

-- Scan the manifest's `repository` section line by line. The manifest is a
-- machine-generated Lua file, but it is megabytes of one table constructor,
-- which LuaJIT refuses to load (65536-constant limit) — and scanning also
-- avoids executing a large download as code.
local function parse_luarocks_manifest(content)
    local repository = {}
    local in_repository = false
    local rock, version
    for line in content:gmatch("[^\r\n]+") do
        if not in_repository then
            if line:match("^repository = {") then in_repository = true end
        elseif line:match("^}") then
            break
        else
            local name = line:match('^   %["([^"]+)"%] = {') or line:match("^   ([%w_]+) = {")
            if name then
                rock, version = {}, nil
                repository[name] = rock
            elseif rock then
                local v = line:match('^      %["([^"]+)"%] = {')
                if v then
                    version = {}
                    rock[v] = version
                elseif version then
                    local arch = line:match('arch = "([%w_%-]+)"')
                    if arch then
                        version[#version + 1] = {arch = arch}
                    end
                end
            end
        end
    end
    if not in_repository then
        error("unexpected luarocks.org manifest format", 0)
    end
    return repository
end

-- The luarocks.org manifest for Lua 5.1, cached for a day in the user cache.
local function luarocks_repository(force)
    local path = path_join(cache_root(), "luarocks/manifest-5.1")
    local content
    if not force and exists(path) and os.time() - file_mtime(path) < 86400 then
        local file = assert(io.open(path, "rb"))
        content = file:read("*a")
        file:close()
    else
        status("Fetching the luarocks.org manifest...")
        content = fetch_url(LUAROCKS_SERVER .. "/manifest-5.1")
        write_file(path, content)
    end
    return parse_luarocks_manifest(content)
end

-- Split "name@version" (version optional).
local function parse_rock_arg(value)
    local name, version = tostring(value):match("^([^@]+)@(.+)$")
    if not name then
        name, version = tostring(value), nil
    end
    return name:lower(), version
end

-- LuaRocks-style version order: dotted base compared piecewise (numeric
-- segments above alphabetical tags like scm/rc), then the rockspec revision.
local function parse_rock_version(v)
    local base, revision = v:match("^(.-)%-(%d+)$")
    if not base then
        base, revision = v, "0"
    end
    local parts = {}
    for piece in base:gmatch("[^%.]+") do parts[#parts + 1] = piece end
    return parts, tonumber(revision) or 0
end

local function rock_version_less(a, b)
    local ap, ar = parse_rock_version(a)
    local bp, br = parse_rock_version(b)
    for i = 1, math.max(#ap, #bp) do
        local x, y = ap[i], bp[i]
        if x ~= y then
            if x == nil then return true end
            if y == nil then return false end
            local nx, ny = tonumber(x), tonumber(y)
            if nx and ny then
                if nx ~= ny then return nx < ny end
            elseif nx then
                return false
            elseif ny then
                return true
            else
                return x < y
            end
        end
    end
    return ar < br
end

-- Pick the requested (or newest) version that has a downloadable source rock.
local function resolve_rock_version(repository, name, wanted)
    local entry = repository[name]
    if not entry then
        fail("rock not found on luarocks.org: " .. name)
    end
    local with_source = {}
    for version, archs in pairs(entry) do
        for _, arch in ipairs(archs) do
            if arch.arch == "src" then
                with_source[version] = true
            end
        end
    end
    if wanted then
        if not entry[wanted] then
            fail("rock " .. name .. " has no version " .. wanted)
        end
        if not with_source[wanted] then
            fail("rock " .. name .. " " .. wanted .. " has no source rock on luarocks.org; "
                .. "pick a version that publishes one")
        end
        return wanted
    end
    local best
    for version in pairs(with_source) do
        if not best or rock_version_less(best, version) then
            best = version
        end
    end
    if not best then
        fail("rock " .. name .. " publishes no source rocks on luarocks.org")
    end
    return best
end

-- Map a rockspec to vendored files, rejecting anything that is not pure Lua.
-- Returns {{source = path-in-rock, dest = path-under-share/lua/5.1}, ...}.
local function plan_rock_files(spec)
    local build = spec.build or {}
    local build_type = build.type or "builtin"
    if build_type ~= "builtin" and build_type ~= "none" then
        fail("rock " .. tostring(spec.package) .. " uses build type '" .. build_type
            .. "'; only pure-Lua rocks can be vendored (the game runtime has no C toolchain)")
    end
    local plan = {}
    for module_name, file in pairs(build.modules or {}) do
        if type(file) ~= "string" or not file:match("%.lua$") then
            fail("rock " .. tostring(spec.package)
                .. " contains native modules; only pure-Lua rocks can be vendored")
        end
        local rel = module_name:gsub("%.", "/")
        local dest = file:match("init%.lua$") and (rel .. "/init.lua") or (rel .. ".lua")
        plan[#plan + 1] = {source = file, dest = dest}
    end
    local install = build.install or {}
    for key, file in pairs(install.lua or {}) do
        if type(file) ~= "string" then
            fail("rock " .. tostring(spec.package) .. " has an unsupported install table")
        end
        local dest
        if type(key) == "number" then
            dest = basename(file)
        else
            local extension = file:match("(%.d%.tl)$") or file:match("(%.lua)$") or ""
            dest = key:gsub("%.", "/") .. extension
        end
        plan[#plan + 1] = {source = file, dest = dest}
    end
    if #plan == 0 then
        fail("rock " .. tostring(spec.package) .. " installs no Lua modules")
    end
    table.sort(plan, function(a, b) return a.dest < b.dest end)
    return plan
end

-- Vendored-rock bookkeeping, stored as a committed Lua table at the project
-- root (with a fallback read of the pre-0.3 location under src/vendor/).
local function read_rocks_manifest()
    local path = ROCKS_MANIFEST
    if not exists(path) then path = LEGACY_ROCKS_MANIFEST end
    if not exists(path) then return {} end
    local file = assert(io.open(normalize(path), "rb"))
    local content = file:read("*a")
    file:close()
    local manifest = load_lua_table(content, "@" .. path)
    return type(manifest) == "table" and manifest or {}
end

local function write_rocks_manifest(manifest)
    remove(LEGACY_ROCKS_MANIFEST)
    local names = {}
    for name in pairs(manifest) do names[#names + 1] = name end
    table.sort(names)
    local out = {
        "-- Rocks vendored by `tecs add`; managed by tecs add/remove/update.",
        "-- Commit this file: `tecs check` and `tecs build` restore the recorded",
        "-- rocks into src/vendor/ when they are missing.",
        "return {",
    }
    for _, name in ipairs(names) do
        local entry = manifest[name]
        out[#out + 1] = ("    [%q] = {"):format(name)
        out[#out + 1] = ("        version = %q,"):format(entry.version)
        out[#out + 1] = "        direct = " .. tostring(entry.direct == true) .. ","
        local deps = {}
        for _, dep in ipairs(entry.deps or {}) do deps[#deps + 1] = ("%q"):format(dep) end
        table.sort(deps)
        out[#out + 1] = "        deps = {" .. table.concat(deps, ", ") .. "},"
        out[#out + 1] = "        files = {"
        local files = {}
        for _, file in ipairs(entry.files or {}) do files[#files + 1] = file end
        table.sort(files)
        for _, file in ipairs(files) do
            out[#out + 1] = ("            %q,"):format(file)
        end
        out[#out + 1] = "        },"
        out[#out + 1] = "    },"
    end
    out[#out + 1] = "}"
    write_file(ROCKS_MANIFEST, table.concat(out, "\n") .. "\n")
end

local function remove_rock_files(entry)
    local stop = normalize("src/vendor")
    for _, file in ipairs(entry.files or {}) do
        local path = path_join("src/vendor", file)
        remove(path)
        -- Prune directories the file leaves empty, up to the vendor root.
        local dir = dirname(path)
        while dir ~= stop and dir ~= "." and is_empty_dir(dir) do
            remove(dir)
            dir = dirname(dir)
        end
    end
end

-- Drop manifest entries no direct rock needs, deleting their files.
local function rocks_gc(manifest)
    local needed = {}
    local function mark(name)
        if needed[name] then return end
        needed[name] = true
        local entry = manifest[name]
        for _, dep in ipairs(entry and entry.deps or {}) do mark(dep) end
    end
    for name, entry in pairs(manifest) do
        if entry.direct then mark(name) end
    end
    local removed = {}
    for name, entry in pairs(manifest) do
        if not needed[name] then
            remove_rock_files(entry)
            manifest[name] = nil
            removed[#removed + 1] = name
        end
    end
    table.sort(removed)
    return removed
end

-- Extract regular files from a ustar archive as {path = content}.
local function parse_tar(data)
    local files = {}
    local long_name
    local pos = 1
    while pos + 512 <= #data + 1 do
        local header = data:sub(pos, pos + 511)
        if header:match("^%z") then break end
        local name = header:sub(1, 100):gsub("%z.*", "")
        local size = tonumber(header:sub(125, 136):gsub("[%z ]", ""), 8) or 0
        local typeflag = header:sub(157, 157)
        local prefix = header:sub(346, 500):gsub("%z.*", "")
        if prefix ~= "" then name = prefix .. "/" .. name end
        local content = data:sub(pos + 512, pos + 511 + size)
        if typeflag == "L" then
            long_name = content:gsub("%z.*", "")
        else
            if long_name then
                name = long_name
                long_name = nil
            end
            if typeflag == "0" or typeflag == "\0" or typeflag == "" then
                files[name] = content
            end
        end
        pos = pos + 512 + math.ceil(size / 512) * 512
    end
    return files
end

-- Expand the source archive packed inside a mounted .src.rock into
-- {path = content}. Source rocks hold the rockspec plus the upstream release
-- artifact, typically a .tar.gz or .zip that is expanded here in memory.
local function expand_rock_source(mount)
    local fs = love_api.filesystem
    local files = {}
    local function add_tree(dir, prefix)
        for _, entry in ipairs(fs.getDirectoryItems(dir)) do
            local path = dir .. "/" .. entry
            local info = fs.getInfo(path)
            if info and info.type == "directory" then
                add_tree(path, prefix .. entry .. "/")
            elseif info and info.type == "file" then
                files[prefix .. entry] = fs.read(path)
            end
        end
    end
    for _, entry in ipairs(fs.getDirectoryItems(mount)) do
        local path = mount .. "/" .. entry
        local info = fs.getInfo(path)
        local lower = entry:lower()
        if info and info.type == "directory" then
            add_tree(path, entry .. "/")
        elseif info and info.type == "file" and not lower:match("%.rockspec$") then
            if lower:match("%.zip$") then
                local data = fs.newFileData((fs.read(path)), entry)
                if fs.mount(data, "tecs-rock-src") then
                    add_tree("tecs-rock-src", "")
                    pcall(fs.unmount, data)
                end
            elseif lower:match("%.tar%.gz$") or lower:match("%.tgz$") then
                local tar = love_api.data.decompress("string", "gzip", (fs.read(path)))
                for name, content in pairs(parse_tar(tar)) do files[name] = content end
            elseif lower:match("%.tar$") then
                for name, content in pairs(parse_tar((fs.read(path)))) do files[name] = content end
            else
                files[entry] = fs.read(path)
            end
        end
    end
    return files
end

-- Find a rockspec-relative path in the expanded source tree: at the root, in
-- the rockspec's source.dir, or (shallowest first) anywhere in the tree.
local function find_rock_source(files, spec, rel)
    if files[rel] then return files[rel] end
    local dir = spec.source and spec.source.dir
    if dir and files[dir .. "/" .. rel] then return files[dir .. "/" .. rel] end
    local suffix = "/" .. rel
    local best
    for path in pairs(files) do
        if path:sub(-#suffix) == suffix then
            local _, depth = path:gsub("/", "")
            if not best or depth < best.depth or (depth == best.depth and path < best.path) then
                best = {path = path, depth = depth}
            end
        end
    end
    return best and files[best.path] or nil
end

-- Mount a downloaded .src.rock (a zip) and call fn(mountpoint).
local function with_mounted_rock(archive, fn)
    if not (is_love_cli and love_api) then
        error("rock management requires LÖVE; run tecs through its installed launcher", 0)
    end
    local fs = love_api.filesystem
    if not fs.mountFullPath then
        error("this LÖVE runtime cannot mount rock archives; update the cached runtime", 0)
    end
    local mount = "tecs-rock-mount"
    if not fs.mountFullPath(archive, mount) then
        error("could not open rock archive " .. archive, 0)
    end
    local ok, err = pcall(fn, mount)
    pcall(fs.unmountFullPath, archive)
    if not ok then error(err, 0) end
end

-- Names LuaRocks dependency strings resolve to, minus the Lua VM itself.
local function dependency_names(spec)
    local names = {}
    for _, dep in ipairs(spec.dependencies or {}) do
        local name = tostring(dep):match("^%s*([%w_.-]+)")
        if name and name:lower() ~= "lua" then
            names[#names + 1] = name:lower()
        end
    end
    return names
end

-- Download, validate, and vendor one rock (plus dependencies and its
-- companion <name>-tl-type declarations when luarocks.org publishes them).
local function install_rock(repository, name, wanted, manifest, direct, seen)
    if seen[name] then return end
    seen[name] = true

    local version = resolve_rock_version(repository, name, wanted)
    local existing = manifest[name]
    if existing and existing.version == version then
        local complete = true
        for _, file in ipairs(existing.files or {}) do
            if not exists(path_join("src/vendor", file)) then
                complete = false
                break
            end
        end
        if complete then
            if direct then existing.direct = true end
            status(name .. " " .. version .. " is already vendored.")
            return
        end
    end
    if existing then
        remove_rock_files(existing)
    end

    local file_name = name .. "-" .. version .. ".src.rock"
    local archive = path_join(cache_root(), "luarocks/rocks", file_name)
    if not exists(archive) then
        status("Downloading " .. file_name .. "...")
        write_file(archive, fetch_url(LUAROCKS_SERVER .. "/" .. file_name))
    end

    local files = {}
    local deps
    with_mounted_rock(archive, function(mount)
        local fs = love_api.filesystem
        local spec_file
        for _, entry in ipairs(fs.getDirectoryItems(mount)) do
            if entry:match("%.rockspec$") then
                spec_file = mount .. "/" .. entry
                break
            end
        end
        if not spec_file then
            error("rock archive has no rockspec: " .. file_name, 0)
        end
        local _, spec = load_lua_table((fs.read(spec_file)), "@" .. name .. ".rockspec")
        local sources = expand_rock_source(mount)

        for _, item in ipairs(plan_rock_files(spec)) do
            local content = find_rock_source(sources, spec, item.source)
            if not content then
                error("rock " .. name .. " is missing packaged file " .. item.source, 0)
            end
            write_file(path_join(vendor_lua, item.dest), content)
            files[#files + 1] = "share/lua/5.1/" .. item.dest
        end

        local license_paths = {}
        for path in pairs(sources) do license_paths[#license_paths + 1] = path end
        table.sort(license_paths)
        local written = {}
        for _, path in ipairs(license_paths) do
            local _, depth = path:gsub("/", "")
            local base = path:match("[^/]+$")
            local is_license = base:upper():match("LICEN[CS]E") or base:upper():match("^COPYING")
            if depth <= 1 and is_license and not written[base] then
                written[base] = true
                write_file(path_join("src/vendor/licenses", name .. "-" .. base), sources[path])
                files[#files + 1] = "licenses/" .. name .. "-" .. base
            end
        end

        deps = dependency_names(spec)
    end)

    for _, dep in ipairs(deps) do
        install_rock(repository, dep, nil, manifest, false, seen)
    end
    local types_rock = name .. "-tl-type"
    if not name:match("%-tl%-type$") and repository[types_rock] then
        install_rock(repository, types_rock, nil, manifest, false, seen)
        deps[#deps + 1] = types_rock
    end

    manifest[name] = {
        version = version,
        direct = direct or (existing and existing.direct) or false,
        deps = deps,
        files = files,
    }
    status("Vendored " .. name .. " " .. version .. " (" .. #files .. " files).")
end

-- Reinstall manifest-recorded rocks whose files are missing (fresh clones:
-- src/vendor/ is generated and typically gitignored). Versions are pinned to
-- the manifest so a restore never upgrades anything.
local function restore_missing_rocks()
    local manifest = read_rocks_manifest()
    local missing = {}
    for name, entry in pairs(manifest) do
        for _, file in ipairs(entry.files or {}) do
            if not exists(path_join("src/vendor", file)) then
                missing[#missing + 1] = name
                break
            end
        end
    end
    if #missing == 0 then return end
    table.sort(missing)

    status("Restoring vendored rocks...")
    local repository = luarocks_repository(false)
    -- Pre-seed `seen` so dependency recursion cannot re-resolve (and upgrade)
    -- rocks the manifest already records; each rock is restored pinned.
    local seen = {}
    for name in pairs(manifest) do seen[name] = true end
    for _, name in ipairs(missing) do
        local entry = manifest[name]
        seen[name] = nil
        install_rock(repository, name, entry.version, manifest, entry.direct, seen)
        seen[name] = true
    end
    write_rocks_manifest(manifest)
end

local function ensure_project()
    if not exists("tlconfig.lua") then
        fail("not a Tecs project: tlconfig.lua not found in the current directory")
    end
end

--------------------------------------------------------------------------------
-- Distribution: package the built game as a .love file, a fused Windows
-- executable, and a macOS app bundle. Runtimes come from the launcher cache
-- when present, otherwise from the same pinned LÖVE nightly the launchers use.
--------------------------------------------------------------------------------

local DIST_RUNTIME_BASE = "https://nightly.link/love2d/love/workflows/main/main"

-- The distributable name, from the project directory.
local function dist_name()
    local name = basename(cwd()):gsub("[^%w%-_%. ]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = "game" end
    return name
end

-- Rebrand LÖVE's Info.plist for the game and drop its claim on .love files.
local function patch_plist(plist, name)
    plist = plist:gsub("(<key>CFBundleIdentifier</key>%s*<string>)[^<]*", "%1org.tecs2d." .. name, 1)
    plist = plist:gsub("(<key>CFBundleName</key>%s*<string>)[^<]*", "%1" .. name, 1)
    plist = plist:gsub("%s*<key>UTExportedTypeDeclarations</key>%s*<array>.-</array>", "", 1)
    return plist
end

local function read_binary(path)
    local file = assert(io.open(normalize(path), "rb"))
    local content = file:read("*a")
    file:close()
    return content
end

-- Zip entries (paths relative to base_dir) into zip_target, preserving
-- symlinks on POSIX. Uses Info-ZIP when available, else Windows' bsdtar.
local function create_zip(base_dir, zip_target, entries)
    remove(zip_target)
    local zip_abs = path_join(cwd(), zip_target)
    local quoted = {}
    for _, entry in ipairs(entries) do quoted[#quoted + 1] = q(entry) end
    local list = table.concat(quoted, " ")
    if is_windows then
        local bsdtar = path_join(os.getenv("WINDIR") or "C:\\Windows", "System32/tar.exe")
        run('cmd /C "cd /D ' .. q(path_join(cwd(), base_dir)) .. " && " .. q(bsdtar)
            .. " --format zip -cf " .. q(zip_abs) .. " " .. list .. '"')
    else
        run("cd " .. q(path_join(cwd(), base_dir)) .. " && zip -q -r -y " .. q(zip_abs) .. " " .. list)
    end
end

-- Copy every file under a mounted archive directory to dest.
local function copy_mount_tree(mount, dest)
    local fs = love_api.filesystem
    local function walk(dir, prefix)
        for _, entry in ipairs(fs.getDirectoryItems(dir)) do
            local source = dir .. "/" .. entry
            local info = fs.getInfo(source)
            if info and info.type == "directory" then
                walk(source, prefix .. entry .. "/")
            elseif info and info.type == "file" then
                write_file(path_join(dest, prefix .. entry), (fs.read(source)))
            end
        end
    end
    walk(mount, "")
end

-- Directory containing love.exe and its DLLs, reusing the host launcher's
-- cache on Windows and downloading the runtime zip elsewhere.
local function dist_windows_runtime()
    local launcher_cache = path_join(cache_root(), "love12-main")
    if exists(launcher_cache) then
        for _, file in ipairs(walk_files(launcher_cache, {})) do
            if basename(file) == "love.exe" then
                return dirname(file)
            end
        end
    end
    local dir = path_join(cache_root(), "dist/love-windows")
    for _, file in ipairs(walk_files(dir, {})) do
        if basename(file) == "love.exe" then
            return dirname(file)
        end
    end

    status("Downloading the Windows LÖVE runtime...")
    mkdir(dir)
    local outer = path_join(cache_root(), "dist/love-windows-outer.zip")
    write_file(outer, fetch_url(DIST_RUNTIME_BASE .. "/love-windows-x64.zip"))
    local inner = path_join(cache_root(), "dist/love-windows-inner.zip")
    with_mounted_rock(outer, function(mount)
        local fs = love_api.filesystem
        local inner_name
        for _, entry in ipairs(fs.getDirectoryItems(mount)) do
            if entry:match("%.zip$") then
                inner_name = entry
                break
            end
        end
        if not inner_name then
            error("unexpected Windows LÖVE runtime archive layout", 0)
        end
        write_file(inner, (fs.read(mount .. "/" .. inner_name)))
    end)
    with_mounted_rock(inner, function(mount)
        copy_mount_tree(mount, dir)
    end)
    remove(outer)
    remove(inner)

    for _, file in ipairs(walk_files(dir, {})) do
        if basename(file) == "love.exe" then
            return dirname(file)
        end
    end
    error("Windows LÖVE runtime did not contain love.exe", 0)
end

-- Path to love.app, reusing the host launcher's cache on macOS and
-- downloading the runtime zip elsewhere. POSIX hosts only (unzip preserves
-- the bundle's symlinks and permissions; archive mounting does not).
local function dist_macos_runtime()
    local cached = path_join(cache_root(), "love12-main/love.app")
    if exists(path_join(cached, "Contents/MacOS/love")) then
        return cached
    end
    local base_dir = path_join(cache_root(), "dist/love-macos")
    local app = path_join(base_dir, "love.app")
    if exists(path_join(app, "Contents/MacOS/love")) then
        return app
    end

    status("Downloading the macOS LÖVE runtime...")
    remove(base_dir)
    mkdir(base_dir)
    write_file(path_join(base_dir, "outer.zip"), fetch_url(DIST_RUNTIME_BASE .. "/love-macos.zip"))
    run("cd " .. q(base_dir) .. " && unzip -q outer.zip && unzip -q love-macos.zip"
        .. " && rm -f outer.zip love-macos.zip")
    if not exists(path_join(app, "Contents/MacOS/love")) then
        error("macOS LÖVE runtime did not contain love.app", 0)
    end
    return app
end

-- Build metadata module consumed by tecs2d.buildinfo. Games (and the MCP
-- and debugger plugins) use it to tell dev builds from distributed ones.
local BUILDINFO_PATH = "build/tecs_buildinfo.lua"

local function buildinfo_lua(dev)
    local love_version = ""
    if love_api and love_api.getVersion then
        local major, minor, revision = love_api.getVersion()
        love_version = table.concat({major, minor, revision}, ".")
    end
    local jitApi = rawget(_G, "jit")
    return table.concat({
        "-- Generated by `tecs build`; do not edit.",
        "return {",
        ("    dev = %s,"):format(tostring(dev == true)),
        ("    name = %q,"):format(dist_name()),
        ("    built = %q,"):format(os.date("!%Y-%m-%dT%H:%M:%SZ")),
        ("    cli = %q,"):format(VERSION),
        ("    love = %q,"):format(love_version),
        ("    luajit = %q,"):format((jitApi and jitApi.version) or _VERSION),
        "}",
    }, "\n") .. "\n"
end

-- Write the manifest when the build changed, it is missing, or a `tecs dist`
-- run left it marked as distributed.
local function refresh_buildinfo(changed)
    local stale = changed or not exists(BUILDINFO_PATH)
    if not stale then
        stale = read_binary(BUILDINFO_PATH):match("dev = false") ~= nil
    end
    if stale then
        write_file(BUILDINFO_PATH, buildinfo_lua(true))
    end
end

-- Zip build/ into dist/<name>.love.
local function dist_love(name)
    local love_file = path_join("dist", name .. ".love")
    -- Compiled specs and their scratch output are development artifacts.
    local excluded = {spec = true, test_deps = true}
    local entries = {}
    for entry in require_lfs().dir("build") do
        if entry ~= "." and entry ~= ".." and not entry:match("^%.") and not excluded[entry] then
            entries[#entries + 1] = entry
        end
    end
    table.sort(entries)
    create_zip("build", love_file, entries)
    status("Wrote " .. love_file)
    return love_file
end

-- Assemble dist/macos/<name>.app and dist/<name>-macos.zip.
local function dist_macos(name, love_file)
    local runtime = dist_macos_runtime()
    local out_dir = path_join("dist", "macos")
    local app = path_join(out_dir, name .. ".app")
    remove(app)
    mkdir(out_dir)
    run("cp -R " .. q(runtime) .. " " .. q(app))

    copy_file(love_file, path_join(app, "Contents/Resources", name .. ".love"))
    local plist_path = path_join(app, "Contents/Info.plist")
    write_file(plist_path, patch_plist(read_binary(plist_path), name))

    local bundle_zip = path_join("dist", name .. "-macos.zip")
    create_zip(out_dir, bundle_zip, {name .. ".app"})
    status("Wrote " .. app)
    status("Wrote " .. bundle_zip .. " (unsigned; sign and notarize before wide distribution)")
end

-- Assemble dist/windows/<name>/ (fused exe plus DLLs) and dist/<name>-windows.zip.
local function dist_windows(name, love_file)
    local runtime = dist_windows_runtime()
    local out_root = path_join("dist", "windows")
    local out = path_join(out_root, name)
    remove(out)
    mkdir(out)

    write_file(path_join(out, name .. ".exe"),
        read_binary(path_join(runtime, "love.exe")) .. read_binary(love_file))
    for _, file in ipairs(walk_files(runtime, {})) do
        local base = basename(file)
        if dirname(file) == normalize(runtime) then
            if base:lower():match("%.dll$") then
                copy_file(file, path_join(out, base))
            elseif base:lower():match("^license") then
                copy_file(file, path_join(out, "love-" .. base:lower()))
            end
        end
    end

    local bundle_zip = path_join("dist", name .. "-windows.zip")
    create_zip(out_root, bundle_zip, {name})
    status("Wrote " .. path_join(out, name .. ".exe"))
    status("Wrote " .. bundle_zip)
end

-- Task table: each entry implements one `tecs <target>` command.
local tasks = {}

-- Forward declaration; assigned after the command table below.
local parser

function tasks.check(args)
    ensure_vendor()
    restore_missing_rocks()
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
    restore_missing_rocks()
    local changed = compile_sources() > 0
    if copy_assets() then changed = true end
    if copy_vendor() then changed = true end
    refresh_buildinfo(changed)
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

    -- Agent guidance ships from the bundled doc so `tecs agent` and generated
    -- projects stay in sync; CLAUDE.md defers to AGENTS.md.
    for _, doc in ipairs(list_agent_docs()) do
        if doc.name == "tecs-project" then
            write_file(path_join(target, "AGENTS.md"), doc.content)
            write_file(path_join(target, "CLAUDE.md"), "@AGENTS.md\n")
        end
    end

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

function tasks.add(args)
    ensure_project()
    local name, wanted = parse_rock_arg(args.rock)
    local repository = luarocks_repository(false)
    if not repository[name] then
        -- The cached manifest may predate a new rock; refresh once before failing.
        repository = luarocks_repository(true)
    end
    local manifest = read_rocks_manifest()
    install_rock(repository, name, wanted, manifest, true, {})
    write_rocks_manifest(manifest)
    status("Vendored rocks are recorded in " .. ROCKS_MANIFEST .. ". Next: tecs check")
end

function tasks.remove(args)
    ensure_project()
    local name = parse_rock_arg(args.rock)
    local manifest = read_rocks_manifest()
    local entry = manifest[name]
    if not entry then
        fail("rock is not vendored: " .. name)
    end
    if not entry.direct then
        local dependents = {}
        for owner, other in pairs(manifest) do
            for _, dep in ipairs(other.deps or {}) do
                if dep == name then dependents[#dependents + 1] = owner end
            end
        end
        table.sort(dependents)
        fail(name .. " was vendored as a dependency of " .. table.concat(dependents, ", ")
            .. "; remove those rocks instead")
    end
    entry.direct = false
    local removed = rocks_gc(manifest)
    write_rocks_manifest(manifest)
    if #removed > 0 then
        status("Removed " .. table.concat(removed, ", ") .. ".")
    end
    if manifest[name] then
        status(name .. " is still required by another vendored rock and was kept.")
    end
end

function tasks.update(args)
    ensure_project()
    local manifest = read_rocks_manifest()
    local targets = {}
    if args.rock then
        local name = parse_rock_arg(args.rock)
        if not manifest[name] then
            fail("rock is not vendored: " .. name)
        end
        targets[#targets + 1] = name
    else
        for name, entry in pairs(manifest) do
            if entry.direct then targets[#targets + 1] = name end
        end
        table.sort(targets)
    end
    if #targets == 0 then
        status("No vendored rocks to update.")
        return
    end
    local repository = luarocks_repository(true)
    for _, name in ipairs(targets) do
        install_rock(repository, name, nil, manifest, manifest[name].direct, {})
    end
    rocks_gc(manifest)
    write_rocks_manifest(manifest)
end

-- Run project specs with the vendored busted runner. Files matching
-- *_lovespec.tl launch the built game under real LÖVE and drive it over the
-- tecs2d MCP server, so this is intentionally not headless.
function tasks.integ()
    ensure_project()
    if is_windows then
        fail("tecs integ requires macOS or Linux; the test harness drives POSIX processes")
    end
    if not exists("spec") then
        fail("no spec/ directory; create spec/<name>_spec.tl or spec/<name>_lovespec.tl first")
    end

    -- The specs exercise the built game, so build first.
    tasks.build()

    status("Compiling specs...")
    local spec_sources = list_files("spec", ".tl")
    local tl_args = {"-q", "--global-env-def", "busted", "gen",
        "--root", ".", "--output-dir", "build"}
    local found = false
    for _, source in ipairs(spec_sources) do
        if not source:match("%.d%.tl$") then
            tl_args[#tl_args + 1] = source
            found = true
        end
    end
    if not found then
        fail("no Teal specs found under spec/")
    end
    run_tl(tl_args)

    -- The CLI itself runs under dummy SDL drivers; launched games need real
    -- ones, and the fixture harness finds the runtime through LOVE.
    local ffi = require("ffi")
    ffi.cdef([[
        int setenv(const char *name, const char *value, int overwrite);
        int unsetenv(const char *name);
    ]])
    ffi.C.unsetenv("SDL_VIDEODRIVER")
    ffi.C.unsetenv("SDL_AUDIODRIVER")
    ffi.C.setenv("LOVE", love_bin(), 1)

    status("Running specs...")
    local previousPath = package.path
    local previousArg = rawget(_G, "arg")
    local previousExit = os.exit
    local exitSignal = {}
    package.path = table.concat({
        "build/?.lua",
        "build/?/init.lua",
        "build/vendor/share/lua/5.1/?.lua",
        "build/vendor/share/lua/5.1/?/init.lua",
    }, ";") .. ";" .. package.path
    rawset(_G, "arg", {"--output", "plainTerminal", "--pattern", "_%a*spec", "build/spec"})
    rawset(os, "exit", function(code)
        exitSignal.code = tonumber(code) or 0
        error(exitSignal, 0)
    end)

    local ok, err = pcall(function()
        require("busted.runner")({standalone = false})
    end)
    rawset(os, "exit", previousExit)
    rawset(_G, "arg", previousArg)
    package.path = previousPath
    if not ok and err ~= exitSignal then error(err, 0) end
    if (exitSignal.code or 0) ~= 0 then
        fail("specs failed")
    end
end

-- Package the built game for distribution.
function tasks.dist(args)
    ensure_project()
    if not is_love_cli then
        error("packaging requires LÖVE; run tecs through its installed launcher", 0)
    end
    if args.target == "macos" and is_windows then
        fail("the macOS bundle cannot be assembled on Windows; its symlinks need a POSIX host")
    end
    tasks.build()

    mkdir("dist")
    local name = dist_name()
    -- Package with distributed-build metadata, then restore the dev manifest
    -- so later runs and specs keep the MCP server and debugger enabled.
    write_file(BUILDINFO_PATH, buildinfo_lua(false))
    local ok, err = pcall(function()
        local love_file = dist_love(name)
        if args.target == "love" then return end

        if not args.target or args.target == "macos" then
            if is_windows then
                status("Skipping the macOS bundle: assemble it on macOS or Linux.")
            else
                dist_macos(name, love_file)
            end
        end
        if not args.target or args.target == "windows" then
            dist_windows(name, love_file)
        end
    end)
    write_file(BUILDINFO_PATH, buildinfo_lua(true))
    if not ok then error(err, 0) end
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
    local script = p["get_" .. args.shell .. "_complete"](p)
    if args.shell == "fish" then
        -- argparse's fish generator omits positional-argument choices (the
        -- zsh one includes them), so emit them from the parser definition.
        local extra = {}
        for _, command in ipairs(p._commands) do
            for _, argument in ipairs(command._arguments or {}) do
                if argument._choices then
                    extra[#extra + 1] = ("complete -c tecs -n '__fish_tecs_seen_command %s' -f -a '%s'")
                        :format(command._name, table.concat(argument._choices, " "))
                end
            end
        end
        if #extra > 0 then
            script = script .. table.concat(extra, "\n") .. "\n"
        end
    end
    io.write(script)
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
        name = "dist",
        summary = "Package the game for distribution",
        description = "Zip the built game into a .love file, assemble a macOS app bundle, and "
            .. "fuse a Windows executable, using the cached LÖVE runtimes.",
        action = tasks.dist,
        setup = function(subcommand)
            subcommand:argument("target", "Optional target: love, macos, or windows; omit for all.")
                :choices({"love", "macos", "windows"})
                :args("?")
        end,
    },
    {
        name = "integ",
        summary = "Run project specs against the built game",
        description = "Compile spec/ and run it with the bundled busted runner; *_lovespec.tl "
            .. "specs launch the built game under real LÖVE and drive it over MCP.",
        action = tasks.integ,
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
        name = "add",
        summary = "Vendor a rock from luarocks.org",
        description = "Download a pure-Lua rock, its dependencies, and matching Teal type "
            .. "declarations from luarocks.org into src/vendor/.",
        action = tasks.add,
        setup = function(subcommand)
            subcommand:argument("rock", "Rock name, optionally versioned: name@1.0-1.")
        end,
    },
    {
        name = "remove",
        summary = "Remove a vendored rock",
        description = "Remove a rock installed by `tecs add`, along with any dependencies "
            .. "no other vendored rock needs.",
        action = tasks.remove,
        setup = function(subcommand)
            subcommand:argument("rock", "Rock name to remove.")
        end,
    },
    {
        name = "update",
        summary = "Update vendored rocks",
        description = "Re-resolve one vendored rock (or all of them) to the newest version "
            .. "published on luarocks.org.",
        action = tasks.update,
        setup = function(subcommand)
            subcommand:argument("rock", "Rock to update; omit to update everything."):args("?")
        end,
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
        description = "Print a completion script for the given shell. bash: eval it from ~/.bashrc; "
            .. "zsh: write it to a file named _tecs on your fpath; "
            .. "fish: write it to ~/.config/fish/completions/tecs.fish.",
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
    dist_name = dist_name,
    patch_plist = patch_plist,
    buildinfo_lua = buildinfo_lua,
    parse_rock_arg = parse_rock_arg,
    parse_luarocks_manifest = parse_luarocks_manifest,
    rock_version_less = rock_version_less,
    plan_rock_files = plan_rock_files,
    read_rocks_manifest = read_rocks_manifest,
    write_rocks_manifest = write_rocks_manifest,
    rocks_gc = rocks_gc,
}

return M
