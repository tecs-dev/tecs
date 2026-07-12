-- Cross-platform task runner for Tecs starter projects.
-- Usage: tecs [--version] [--quiet] <command>

local argparse = require("tecs_cli.vendor.argparse")
local ansicolors = require("tecs_cli.vendor.ansicolors")
local have_lfs, lfs = pcall(require, "lfs")

local VERSION = "0.1.0" -- keep in sync with the rockspec version
local is_love_cli = rawget(_G, "TECS_LOVE_CLI") == true
local love_api = rawget(_G, "love")

-- Platform traits detected from the OS path separator. Held in mutable locals
-- so specs can substitute another platform via M._internal.set_platform.
local sep, is_msys, is_windows, uses_cmd_shell

local function detect_platform()
    local host_sep = package.config:sub(1, 1)
    local msys = os.getenv("MSYSTEM") ~= nil
    local separator = msys and "/" or host_sep
    return {
        sep = separator,
        is_msys = msys,
        is_windows = separator == "\\" and not msys,
        uses_cmd_shell = host_sep == "\\",
    }
end

local function set_platform(platform)
    sep = platform.sep
    is_msys = platform.is_msys or false
    is_windows = platform.is_windows or false
    uses_cmd_shell = platform.uses_cmd_shell or false
end

set_platform(detect_platform())

-- Local Tecs/Tecs2D checkout used for installs and dev mode. Override with
-- TECS_DIR; otherwise use a sibling checkout, matching the CI layout.
local function default_tecs_dir()
    return sep == "\\" and "..\\tecs" or "../tecs"
end

local tecs_dir = os.getenv("TECS_DIR") or default_tecs_dir()

local vendor_lua = "src/vendor/share/lua/5.1"  -- installed LuaRocks module tree
local love12_dir = ".love12"                   -- downloaded Love2D 12 runtime
local nightly_base = "https://nightly.link/love2d/love/workflows/main/main"

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
        error("luafilesystem is required. Install tecs-cli with LuaRocks or install the `luafilesystem` rock.", 0)
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

-- Quote text for a single-quoted POSIX shell string.
local function shq(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function source_path()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        return source:sub(2)
    end
    return nil
end

-- Run a POSIX shell command explicitly when Lua is a Windows binary inside
-- MSYS2. MinGW LuaJIT's os.execute uses cmd.exe even though MSYS tools exist.
local function posix_cmd(cmd)
    if is_msys and uses_cmd_shell then
        return "bash -lc " .. shq('export PATH="$HOME/bin:$HOME/.luarocks/bin:/mingw64/bin:/usr/bin:$PATH"; ' .. cmd)
    end
    return cmd
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

local function command_ok(cmd)
    local a = os.execute(cmd)
    return a == true or a == 0
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

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function stamp_project_rockspec(target)
    local template_path = path_join(target, "project-dev-1.rockspec.in")
    local template = read_file(template_path)
    if not template then return end

    local title = basename(target)
    local rockspec = "game-dev-1.rockspec"
    template = template:gsub("@PACKAGE@", "game"):gsub("@TITLE@", title)
    write_file(path_join(target, rockspec), template)
    os.remove(normalize(template_path))
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

-- Run a command and return its non-empty output lines, normalized and sorted.
local function popen_lines(cmd)
    local p = assert(io.popen(cmd))
    local lines = {}
    for line in p:lines() do
        if line ~= "" then lines[#lines + 1] = normalize(line) end
    end
    p:close()
    table.sort(lines)
    return lines
end

-- Cache `uname -s`; used only for platform-specific Love2D runtime selection.
local uname_cache
local function uname_s()
    if not uname_cache then
        uname_cache = popen_lines("uname -s 2>/dev/null")[1] or ""
    end
    return uname_cache
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
        lua_module_path(tecs_dir) .. "/src/?.tl",
        lua_module_path(tecs_dir) .. "/src/?/init.tl",
        lua_module_path(tecs_dir) .. "/build/?.lua",
        lua_module_path(tecs_dir) .. "/build/?/init.lua",
        vendor_lua .. "/?.tl",
        vendor_lua .. "/?/init.tl",
        vendor_lua .. "/?.lua",
        vendor_lua .. "/?/init.lua",
        "",
    }
    return table.concat(paths, ";")
end

-- Prefix a command with the LUA_PATH the Teal compiler needs.
local function with_lua_path(cmd)
    local bin = path_join("src/vendor/bin")
    if is_msys and uses_cmd_shell then
        return posix_cmd("PATH=" .. q(bin) .. ':$PATH LUA_PATH=' .. q(lua_path()) .. " " .. cmd)
    end
    if uses_cmd_shell then
        return 'cmd /C "set PATH=' .. normalize(bin) .. ';%PATH%&& set LUA_PATH=' .. lua_path() .. '&& ' .. cmd .. '"'
    end
    return "PATH=" .. q(bin) .. ':$PATH LUA_PATH=' .. q(lua_path()) .. " " .. cmd
end

local function with_vendor_env(cmd)
    local root = assert(require_lfs().currentdir())
    local bin = path_join(root, "src/vendor/bin")
    local lua = path_join(root, "src/vendor/share/lua/5.1")
    local clib = path_join(root, "src/vendor/lib/lua/5.1")
    if uses_cmd_shell then
        return 'cmd /C "set PATH=' .. normalize(bin) .. ';%PATH%&& set LUA_PATH='
            .. lua_module_path(lua) .. '/?.lua;' .. lua_module_path(lua) .. '/?/init.lua;%LUA_PATH%&& set LUA_CPATH='
            .. lua_module_path(clib) .. '/?.dll;' .. lua_module_path(clib) .. '/?.so;%LUA_CPATH%&& ' .. cmd .. '"'
    end
    return posix_cmd("PATH=" .. q(bin) .. ':$PATH LUA_PATH='
        .. q(lua_module_path(lua) .. "/?.lua;" .. lua_module_path(lua) .. "/?/init.lua;;$LUA_PATH")
        .. " LUA_CPATH=" .. q(lua_module_path(clib) .. "/?.so;;$LUA_CPATH")
        .. " " .. cmd)
end

local function run_tl(args)
    if not is_love_cli then
        local quoted = {}
        for i = 1, #args do quoted[i] = q(args[i]) end
        run(with_lua_path("tl " .. table.concat(quoted, " ")))
        return
    end

    local previousPath = package.path
    local previousExit = os.exit
    local exitSignal = {}
    package.path = lua_path() .. ";" .. package.path
    rawset(os, "exit", function(code)
        exitSignal.code = tonumber(code) or 0
        error(exitSignal, 0)
    end)

    local ok, err = pcall(function()
        return require("tlcli.main")(args)
    end)
    rawset(os, "exit", previousExit)
    package.path = previousPath
    if not ok and err ~= exitSignal then error(err, 0) end
    if not ok and exitSignal.code ~= 0 then
        error("Teal failed with exit code " .. tostring(exitSignal.code), 0)
    end
end

-- Run a command from inside the local Tecs checkout with its luarocks bin
-- (where the `tl`/`luarocks` shims live) prepended to PATH.
local function tecs_cmd(cmd)
    local bin = path_join(tecs_dir, "vendor/bin")
    if is_windows then
        return 'cmd /C "cd /D ' .. q(tecs_dir) .. " && set PATH=" .. normalize(bin) .. ';%PATH%&& ' .. cmd .. '"'
    end
    return posix_cmd("cd " .. q(normalize(tecs_dir)) .. " && PATH=" .. q(bin) .. ':$PATH ' .. cmd)
end

local function ensure_msys_teal_wrapper()
    if not is_msys then return false end
    if not command_ok(posix_cmd('[ -f src/vendor/lib/luarocks/rocks-5.1/tl/*/bin/tl ]')) then
        return false
    end
    local bin = path_join("src/vendor/bin")
    mkdir(bin)
    write_file(path_join(bin, "tl"), [[#!/usr/bin/env bash
root="$(cygpath -m "$PWD")"
script="$(find "$root/src/vendor/lib/luarocks/rocks-5.1/tl" -path '*/bin/tl' | sort -r | head -n 1)"
export LUA_PATH="$root/src/vendor/share/lua/5.1/?.lua;$root/src/vendor/share/lua/5.1/?/init.lua;$LUA_PATH"
export LUA_CPATH="$root/src/vendor/lib/lua/5.1/?.dll;$root/src/vendor/lib/lua/5.1/?.so;$LUA_CPATH"
exec luajit "$script" "$@"
]])
    run(posix_cmd("chmod +x " .. q(path_join(bin, "tl"))))
    return true
end

local function teal_compiler_complete()
    return exists(path_join("src/vendor/bin/tl"))
        and exists(path_join(vendor_lua, "teal/init.lua"))
        and exists(path_join(vendor_lua, "tlcli/main.lua"))
end

local function ensure_teal_compiler()
    if teal_compiler_complete() then
        ensure_msys_teal_wrapper()
        return
    end

    local tree = q(path_join(cwd(), "src/vendor"))
    status("Installing Teal development release...")
    run(with_vendor_env("luarocks --dev --lua-version=5.1 install --tree=" .. tree .. " tl"))

    if not teal_compiler_complete() then
        fail("Teal installed without its teal/tlcli modules")
    end
    ensure_msys_teal_wrapper()
end

local function ensure_love_type_environment()
    if exists(path_join(vendor_lua, "love2d.d.tl")) then return end

    -- LuaRocks may build the transitive tecs dependency before it installs
    -- tecs2d's remaining dependencies. Preinstall the global environment so
    -- source-based dev rocks can type-check regardless of resolver order.
    local tree = q(path_join(cwd(), "src/vendor"))
    status("Installing LÖVE type environment...")
    run(with_vendor_env("luarocks --lua-version=5.1 install --tree=" .. tree
        .. " tecs-love2d-tl-type"))
end

local function ensure_mcp_runtime()
    if exists(path_join(vendor_lua, "socket.lua")) then return end

    local tree = q(path_join(cwd(), "src/vendor"))
    status("Installing LuaSocket runtime...")
    run(with_vendor_env("luarocks --lua-version=5.1 install --tree=" .. tree .. " luasocket"))
end

local function ensure_teal_type_dependencies()
    local haveFfi = exists(path_join(vendor_lua, "ffi.d.tl"))
    local haveSocket = exists(path_join(vendor_lua, "socket.d.tl"))
    if haveFfi and haveSocket then return end

    local tree = q(path_join(cwd(), "src/vendor"))
    status("Installing Teal dependency types...")
    if not haveFfi then
        run(with_vendor_env("luarocks --lua-version=5.1 install --tree=" .. tree
            .. " luajit-tl-type 0.0.2-1"))
    end
    if not haveSocket then
        run(with_vendor_env("luarocks --lua-version=5.1 install --tree=" .. tree
            .. " luasocket-tl-type 0.0.2-1"))
    end
end

-- Path to the downloaded Love2D executable for this platform.
local function love_bin()
    local supplied = os.getenv("TECS_LOVE_BIN")
    if supplied and supplied ~= "" then return normalize(supplied) end
    if is_windows then
        return path_join(love12_dir, "love.exe")
    elseif uname_s() == "Darwin" then
        return path_join(love12_dir, "love.app/Contents/MacOS/love")
    end
    return path_join(love12_dir, "love")
end

-- Use the local checkout directly when LuaRocks cannot reliably install into
-- the starter vendor tree, which can happen under MinGW/MSYS path translation.
local function sync_local_tecs()
    local tecs_src = path_join(tecs_dir, "src/tecs")
    local tecs2d_src = path_join(tecs_dir, "src/tecs2d")
    if not exists(tecs_src) or not exists(tecs2d_src) then return false end

    status("Syncing Tecs from local checkout...")
    copy_dir(tecs_src, path_join(vendor_lua, "tecs"))
    copy_dir(tecs2d_src, path_join(vendor_lua, "tecs2d"))
    return true
end

local function project_rockspec()
    local fs = require_lfs()
    for entry in fs.dir(".") do
        if entry:match("%-dev%-1%.rockspec$") then
            return entry
        end
    end
    return nil
end

local function install_project_rock()
    local rockspec = project_rockspec()
    if not rockspec then return end
    local tree = q(path_join(cwd(), "src/vendor"))
    run(with_vendor_env("luarocks --dev --lua-version=5.1 make --tree=" .. tree
        .. " " .. q(rockspec)))
    ensure_msys_teal_wrapper()
end

-- Install Tecs/Tecs2D into src/vendor via luarocks on first use.
local function ensure_vendor()
    if is_love_cli then
        if exists(path_join(vendor_lua, "tecs2d/init.tl"))
            and exists(path_join(vendor_lua, "love2d.d.tl"))
            and exists(path_join(vendor_lua, "ffi.d.tl"))
            and exists(path_join(vendor_lua, "socket.d.tl")) then return end

        status("Preparing embedded Tecs dependencies...")
        mkdir(vendor_lua)
        if exists(path_join(tecs_dir, "src/tecs/init.tl"))
            and exists(path_join(tecs_dir, "src/tecs2d/init.tl")) then
            copy_dir(path_join(tecs_dir, "src/tecs"), path_join(vendor_lua, "tecs"))
            copy_dir(path_join(tecs_dir, "src/tecs2d"), path_join(vendor_lua, "tecs2d"))
        else
            copy_love_dir("payload/framework/tecs", path_join(vendor_lua, "tecs"))
            copy_love_dir("payload/framework/tecs2d", path_join(vendor_lua, "tecs2d"))
        end
        copy_love_dir("payload/types", vendor_lua)
        return
    end

    ensure_teal_compiler()
    ensure_love_type_environment()
    ensure_mcp_runtime()
    ensure_teal_type_dependencies()
    if exists(path_join(vendor_lua, "tecs2d/init.tl"))
        and exists(path_join(vendor_lua, "love2d.d.tl"))
        and exists(path_join(vendor_lua, "ffi.d.tl"))
        and exists(path_join(vendor_lua, "socket.d.tl")) then return end
    if sync_local_tecs() then return end
    status("Installing project dependencies...")
    install_project_rock()
end

-- Download and unpack the Love2D 12 nightly for this platform into .love12.
local function download_love12()
    remove(love12_dir)
    mkdir(love12_dir)
    if is_windows then
        status("Downloading Love2D 12 for Windows...")
        local outer = path_join(love12_dir, "outer.zip")
        run("curl -sL -o " .. q(outer) .. " " .. q(nightly_base .. "/love-windows-x64.zip"))
        run('powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -Force '
            .. q(outer) .. " " .. q(love12_dir) .. '"')
        local inner = path_join(love12_dir, "love-windows-x64.zip")
        if exists(inner) then
            run('powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -Force '
                .. q(inner) .. " " .. q(love12_dir) .. '"')
        end
    else
        local outer = path_join(love12_dir, "outer.zip")
        if uname_s() == "Darwin" then
            status("Downloading Love2D 12 for macOS...")
            run("curl -sL -o " .. q(outer) .. " " .. q(nightly_base .. "/love-macos.zip"))
            run("cd " .. q(love12_dir)
                .. " && unzip -q outer.zip && unzip -q love-macos.zip && rm -f outer.zip love-macos.zip")
        else
            status("Downloading Love2D 12 for Linux...")
            run("curl -sL -o " .. q(outer) .. " " .. q(nightly_base .. "/love-linux-X64.AppImage.zip"))
            run("cd " .. q(love12_dir)
                .. " && unzip -q outer.zip && rm -f outer.zip && mv love-* love && chmod +x love")
        end
    end
    status("Love2D 12 installed to " .. love12_dir)
end

-- Download Love2D 12 only if it is not already present.
local function ensure_love12()
    if exists(love_bin()) then return end
    download_love12()
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

-- Stage the runtime Lua tree into build/: the vendored rocks plus the latest
-- tecs/tecs2d builds and their bundled internal assets. Stamp guards reruns.
-- Returns true when anything was staged.
local function copy_vendor()
    local required = path_join("build/tecs2d/init.lua")
    local stamp = path_join("build/.vendor-copy-stamp")
    local tecs_build = path_join(tecs_dir, "build/tecs")
    local tecs2d_build = path_join(tecs_dir, "build/tecs2d")
    local vendor_time = math.max(
        tree_mtime("src/vendor"),
        file_mtime(path_join(tecs_build, "init.lua")),
        file_mtime(path_join(tecs2d_build, "init.lua"))
    )
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

    if exists(path_join(tecs_build, "init.lua")) and exists(path_join(tecs2d_build, "init.lua")) then
        -- Local rock builds can contain package self-links that point outside the
        -- build tree, so skip those generated links.
        copy_dir(tecs_build, path_join("build/vendor/share/lua/5.1/tecs"), {"tecs"})
        copy_dir(tecs2d_build, path_join("build/vendor/share/lua/5.1/tecs2d"), {"tecs2d", "assets/internal/internal"})
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

function tasks.check()
    ensure_vendor()
    status("Typechecking...")
    local args = {"check"}
    for _, source in ipairs(list_teal_sources()) do args[#args + 1] = source end
    run_tl(args)
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
    ensure_love12()
    tasks.build()
    status("Launching game...")
    if is_windows then
        run('cmd /C "set SDL_VIDEODRIVER=&& set SDL_AUDIODRIVER=&& cd /D build && '
            .. q(path_join("..", love_bin())) .. ' ."')
    else
        run("cd build && env -u SDL_VIDEODRIVER -u SDL_AUDIODRIVER "
            .. q(path_join("..", love_bin())) .. " .")
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
    stamp_project_rockspec(target)
    mkdir(path_join(target, "assets"))

    status("Project created. Next: cd " .. target .. " && tecs check")
end

function tasks.love12()
    if os.getenv("TECS_LOVE_BIN") then
        status("Using cached LÖVE 12 runtime: " .. love_bin())
    else
        download_love12()
    end
end

function tasks.dev()
    local tecs_build = path_join(tecs_dir, "build/tecs")
    local tecs2d_build = path_join(tecs_dir, "build/tecs2d")
    if not exists(tecs_build) or not exists(tecs2d_build) then
        error("Tecs build output not found. Build Tecs first: " .. tecs_dir, 0)
    end
    install_project_rock()
    mkdir(path_join(vendor_lua))
    remove(path_join(vendor_lua, "tecs"))
    remove(path_join(vendor_lua, "tecs2d"))
    status("Preparing local Tecs development source...")
    copy_dir(path_join(tecs_dir, "src/tecs"), path_join(vendor_lua, "tecs"))
    copy_dir(path_join(tecs_dir, "src/tecs2d"), path_join(vendor_lua, "tecs2d"))
    status("Dev mode prepared. Re-run `tecs build` after changes.")
end

tasks["sync-tecs"] = function()
    status("Reinstalling Tecs and Tecs2D from " .. tecs_dir .. "...")
    if not exists(path_join(tecs_dir, "tecs-dev-1.rockspec")) then
        error("rockspec not found at " .. path_join(tecs_dir, "tecs-dev-1.rockspec"), 0)
    end
    remove(path_join(vendor_lua, "tecs"))
    remove(path_join(vendor_lua, "tecs2d"))
    install_project_rock()
    run(tecs_cmd("luarocks make --tree=" .. q(path_join(cwd(), "src/vendor"))
        .. " --lua-version=5.1 tecs-dev-1.rockspec"))
    run(tecs_cmd("luarocks make --tree=" .. q(path_join(cwd(), "src/vendor"))
        .. " --lua-version=5.1 tecs2d-dev-1.rockspec"))
    status("Sync complete.")
end

local M = {}

local commands = {
    {
        name = "new",
        summary = "Create a new Tecs project",
        description = "Create a new fixed-layout Tecs project from the bundled starter source.",
        action = tasks.new,
    },
    {
        name = "run",
        summary = "Build and run the game",
        description = "Download Love2D if needed, build the project, then launch the game from build/.",
        action = tasks.run,
    },
    {
        name = "build",
        summary = "Compile without running",
        description = "Install project dependencies if needed, compile Teal sources, copy assets, "
            .. "and refresh build output.",
        action = tasks.build,
    },
    {
        name = "check",
        summary = "Type-check all Teal source files",
        description = "Install project dependencies if needed and run the Teal type checker over src/.",
        action = tasks.check,
    },
    {
        name = "clean",
        summary = "Remove build artifacts",
        description = "Remove build/ while leaving vendored dependencies and the Love2D runtime in place.",
        action = tasks.clean,
    },
    {
        name = "love12",
        summary = "Re-download Love2D 12",
        description = "Download and unpack the Love2D 12 nightly runtime for this platform into .love12/.",
        action = tasks.love12,
    },
    {
        name = "dev",
        summary = "Prepare local Tecs source for development",
        description = "Copy local Tecs/Tecs2D sources from TECS_DIR or ../tecs into src/vendor/ "
            .. "for development iteration.",
        action = tasks.dev,
    },
    {
        name = "sync-tecs",
        summary = "Reinstall Tecs/Tecs2D from local rockspecs",
        description = "Reinstall Tecs and Tecs2D into src/vendor/ from the local Tecs checkout rockspecs.",
        action = tasks["sync-tecs"],
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
        io.write("  " .. color("cyan", string.format("%-11s", command.name)) .. command.summary .. "\n")
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

local function parser()
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
        if command.name == "new" then
            subcommand:argument("project", "Directory to create for the new project.")
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

        if target == "new" then
            task(args)
        else
            task()
        end
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
    dirname = dirname,
    relative_to = relative_to,
    should_exclude = should_exclude,
    needs_update = needs_update,
    copy_dir = copy_dir,
    prune_runtime_vendor = prune_runtime_vendor,
    teal_compiler_complete = teal_compiler_complete,
    q = q,
}

return M
