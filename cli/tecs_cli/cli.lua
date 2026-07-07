-- Cross-platform task runner for Tecs starter projects.
-- Usage: tecs [help|check|build|run|clean|love12|dev|sync-tecs]

local argparse = require("argparse")
local have_ansicolors, ansicolors = pcall(require, "ansicolors")
local have_lfs, lfs = pcall(require, "lfs")

local VERSION = "0.1.0"

-- Detect the platform from the OS path separator.
local host_sep = package.config:sub(1, 1)
local sep = host_sep
local is_msys = os.getenv("MSYSTEM") ~= nil
if is_msys then sep = "/" end
local is_windows = sep == "\\" and not is_msys
local uses_cmd_shell = host_sep == "\\"

-- Local Tecs/Tecs2D checkout used for installs and dev mode. Override with
-- TECS_DIR; otherwise use a sibling checkout, matching the CI layout.
local function default_tecs_dir()
    return sep == "\\" and "..\\tecs" or "../tecs"
end

local tecs_dir = os.getenv("TECS_DIR") or default_tecs_dir()

local vendor_lua = "src/vendor/share/lua/5.1"  -- installed LuaRocks module tree
local love12_dir = ".love12"                   -- downloaded Love2D 12 runtime
local nightly_base = "https://nightly.link/love2d/love/workflows/main/main"
local pinned_tl_ref = "4b97e8d4c743795cb148c898fb19e14b6f3b8f2d"

-- Source-only asset extensions to exclude from build output and mtime checks.
local exclude_assets = {
    ["ase"] = true,
    ["aseprite"] = true,
}

local color_enabled

local function require_lfs()
    if not have_lfs then
        error("luafilesystem is required. Install tecs-cli with LuaRocks or install the `luafilesystem` rock.", 0)
    end
    return lfs
end

local function supports_color()
    if color_enabled ~= nil then return color_enabled end
    local no_color = os.getenv("NO_COLOR")
    local term = os.getenv("TERM")
    color_enabled = no_color == nil and not is_windows and term ~= "dumb"
    return color_enabled
end

local function color(spec, text)
    if not supports_color() then return text end
    if have_ansicolors then
        return ansicolors("%{" .. spec .. "}" .. text .. "%{reset}")
    end
    local codes = {
        blue = "34",
        cyan = "36",
        green = "32",
        magenta = "35",
        red = "31",
        yellow = "33",
        bright = "1",
        black = "90",
    }
    local out = {}
    for token in spec:gmatch("%S+") do
        out[#out + 1] = codes[token]
    end
    if #out == 0 then return text end
    return "\27[" .. table.concat(out, ";") .. "m" .. text .. "\27[0m"
end

-- Print a progress message to stderr (stdout is reserved for echoed commands).
local function status(message)
    io.stderr:write(color("cyan", "==> ") .. message .. "\n")
end

local function fail(message)
    error({tecs_exit = true, message = message}, 0)
end

-- Quote a path so it survives as a single shell argument.
local function q(path)
    return '"' .. tostring(path):gsub('"', '\\"') .. '"'
end

-- Quote text for a single-quoted POSIX shell string.
local function shq(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function shell_arg(value)
    value = tostring(value)
    if is_windows then
        return q(value)
    end
    return shq(value)
end

local function basename(path)
    path = tostring(path):gsub("[/\\]+$", "")
    return path:match("([^/\\]+)$") or path
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

-- Path spelling for Lua module search. Under MSYS2 our shell tools need
-- `/d/...`, but the `tl` shim ultimately runs Windows Lua and needs `D:/...`.
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

-- True if a file or directory exists.
local function exists(path)
    return require_lfs().attributes(normalize(path)) ~= nil
end

local function path_exists(path)
    path = normalize(path)
    local ok = os.rename(path, path)
    if ok then return true end
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

-- Echo and run a shell command, raising on failure. Handles both the
-- Lua 5.1 (numeric) and 5.2+ (boolean) os.execute return conventions.
local function run(cmd)
    io.stderr:write(color("black", cmd) .. "\n")
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
        "types/?.d.tl",
        "types/string/?.d.tl",
        "types/table/?.d.tl",
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

-- Run a command from inside the local Tecs checkout with its luarocks bin
-- (where the `tl`/`luarocks` shims live) prepended to PATH.
local function tecs_cmd(cmd)
    local bin = path_join(tecs_dir, "vendor/bin")
    if is_windows then
        return 'cmd /C "cd /D ' .. q(tecs_dir) .. " && set PATH=" .. normalize(bin) .. ';%PATH%&& ' .. cmd .. '"'
    end
    return posix_cmd("cd " .. q(normalize(tecs_dir)) .. " && PATH=" .. q(bin) .. ':$PATH ' .. cmd)
end

local function tecs_tl_ref()
    local env_ref = os.getenv("TL_REF")
    if env_ref and env_ref ~= "" then return env_ref end
    local makefile = read_file(path_join(tecs_dir, "Makefile")) or ""
    return makefile:match("\nTL_REF%s*%?=%s*([%w]+)") or makefile:match("^TL_REF%s*%?=%s*([%w]+)") or pinned_tl_ref
end

local function ensure_msys_teal_wrapper()
    if not is_msys then return false end
    if not command_ok(posix_cmd('[ -f src/vendor/lib/luarocks/rocks-5.1/tl/dev-1/bin/tl ]')) then
        return false
    end
    local bin = path_join("src/vendor/bin")
    mkdir(bin)
    write_file(path_join(bin, "tl"), [[#!/usr/bin/env bash
root="$(cygpath -m "$PWD")"
script="$root/src/vendor/lib/luarocks/rocks-5.1/tl/dev-1/bin/tl"
export LUA_PATH="$root/src/vendor/share/lua/5.1/?.lua;$root/src/vendor/share/lua/5.1/?/init.lua;$LUA_PATH"
export LUA_CPATH="$root/src/vendor/lib/lua/5.1/?.dll;$root/src/vendor/lib/lua/5.1/?.so;$LUA_CPATH"
exec luajit "$script" "$@"
]])
    run(posix_cmd("chmod +x " .. q(path_join(bin, "tl"))))
    return true
end

local function ensure_teal_compiler()
    if exists(path_join("src/vendor/bin/tl")) and not is_msys and command_ok(posix_cmd(q(path_join("src/vendor/bin/tl")) .. " --version >/dev/null 2>&1")) then
        return
    end
    if ensure_msys_teal_wrapper() then return end
    local ref = tecs_tl_ref()
    if not ref then
        error("Could not find TL_REF in " .. path_join(tecs_dir, "Makefile"), 0)
    end
    status("Installing Teal compiler at " .. ref .. "...")
    local tmp = path_join(".tecs-tmp", "tl")
    remove(tmp)
    run(posix_cmd("git clone --branch main " .. q("https://github.com/teal-language/tl.git") .. " " .. q(tmp)))
    run(posix_cmd("cd " .. q(tmp) .. " && git checkout --detach " .. q(ref)))
    run(posix_cmd("cd " .. q(tmp) .. " && luarocks make --tree=" .. q(path_join(cwd(), "src/vendor")) .. " --lua-version=5.1 tl-dev-1.rockspec"))
    remove(path_join(".tecs-tmp"))
end

-- Path to the downloaded Love2D executable for this platform.
local function love_bin()
    if is_windows then
        return path_join(love12_dir, "love.exe")
    elseif uname_s() == "Darwin" then
        return path_join(love12_dir, "love.app/Contents/MacOS/love")
    end
    return path_join(love12_dir, "love")
end

-- Copy Teal type definitions from the Tecs checkout on first use.
local function ensure_types()
    if exists("types/love2d.d.tl") then return end
    local bundled = path_join(template_dir(), "types")
    if exists(path_join(bundled, "love2d.d.tl")) then
        status("Copying bundled type definitions...")
        mkdir("types")
        copy_dir(bundled, "types")
        return
    end
    local source = path_join(tecs_dir, "types")
    if not exists(source) then
        error(
            "Type definitions not found. Expected " .. source .. "\n" ..
            "Set TECS_DIR to a current Tecs checkout, run `git pull` there, or restore this starter's types/ directory.",
            0
        )
    end
    status("Copying type definitions...")
    copy_dir(source, "types", {"luassert", "busted.d.tl"})
end

-- Use the local checkout directly when LuaRocks cannot reliably install into
-- the starter vendor tree, which can happen under MinGW/MSYS path translation.
local function sync_local_tecs()
    local tecs_src = path_join(tecs_dir, "src/tecs")
    local tecs2d_src = path_join(tecs_dir, "src/tecs2d")
    if not exists(tecs_src) or not exists(tecs2d_src) then return end

    status("Syncing Tecs from local checkout...")
    copy_dir(tecs_src, path_join(vendor_lua, "tecs"))
    copy_dir(tecs2d_src, path_join(vendor_lua, "tecs2d"))
end

local function install_tecs_rocks()
    local tree = q(path_join(cwd(), "src/vendor"))
    if exists(path_join(tecs_dir, "tecs-dev-1.rockspec")) and exists(path_join(tecs_dir, "tecs2d-dev-1.rockspec")) then
        run(tecs_cmd("luarocks make --tree=" .. tree .. " --lua-version=5.1 tecs-dev-1.rockspec"))
        run(tecs_cmd("luarocks make --tree=" .. tree .. " --lua-version=5.1 tecs2d-dev-1.rockspec"))
        return
    end
    run(posix_cmd("luarocks install --tree=" .. tree .. " --lua-version=5.1 tecs"))
    run(posix_cmd("luarocks install --tree=" .. tree .. " --lua-version=5.1 tecs2d"))
end

-- Install Tecs/Tecs2D into src/vendor via luarocks on first use.
local function ensure_vendor()
    ensure_teal_compiler()
    if exists(path_join(vendor_lua, "tecs2d/init.tl")) then return end
    sync_local_tecs()
    if exists(path_join(vendor_lua, "tecs2d/init.tl")) then return end
    status("Installing Tecs and Tecs2D dependencies...")
    install_tecs_rocks()
    if not exists(path_join(vendor_lua, "tecs2d/init.tl")) then
        sync_local_tecs()
    end
end

-- Download and unpack the Love2D 12 nightly for this platform into .love12.
local function download_love12()
    remove(love12_dir)
    mkdir(love12_dir)
    if is_windows then
        status("Downloading Love2D 12 for Windows...")
        local outer = path_join(love12_dir, "outer.zip")
        run("curl -sL -o " .. q(outer) .. " " .. q(nightly_base .. "/love-windows-x64.zip"))
        run('powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -Force ' .. q(outer) .. " " .. q(love12_dir) .. '"')
        local inner = path_join(love12_dir, "love-windows-x64.zip")
        if exists(inner) then
            run('powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -Force ' .. q(inner) .. " " .. q(love12_dir) .. '"')
        end
    else
        local outer = path_join(love12_dir, "outer.zip")
        if uname_s() == "Darwin" then
            status("Downloading Love2D 12 for macOS...")
            run("curl -sL -o " .. q(outer) .. " " .. q(nightly_base .. "/love-macos.zip"))
            run("cd " .. q(love12_dir) .. " && unzip -q outer.zip && unzip -q love-macos.zip && rm -f outer.zip love-macos.zip")
        else
            status("Downloading Love2D 12 for Linux...")
            run("curl -sL -o " .. q(outer) .. " " .. q(nightly_base .. "/love-linux-X64.AppImage.zip"))
            run("cd " .. q(love12_dir) .. " && unzip -q outer.zip && rm -f outer.zip && mv love-* love && chmod +x love")
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
    for _, src in ipairs(list_teal_sources()) do
        local rel = src:gsub("^src[/\\]", "")
        local lua_file = rel:gsub("%.tl$", ".lua")
        local out = path_join("build", lua_file)
        if needs_update(out, src, "tlconfig.lua") then
            if compiled == 0 then status("Compiling Teal...") end
            mkdir(dirname(out))
            run(with_lua_path("tl gen " .. q(src) .. " -o " .. q(out)))
            compiled = compiled + 1
        end
    end
    if compiled == 0 then status("Teal output is up to date.") end
end

-- Compile vendored Tecs/Tecs2D sources after staging them into build/. This
-- keeps the starter working with Teal releases that do not support `gen --root`.
local function compile_vendor_tecs_sources()
    local root = path_join("build/vendor/share/lua/5.1")
    local compiled = 0
    for _, src in ipairs(list_files(root, ".tl")) do
        local n = normalize(src)
        if (n:match("[/\\]tecs[/\\]") or n:match("[/\\]tecs2d[/\\]")) and not n:match("%.d%.tl$") then
            local out = n:gsub("%.tl$", ".lua")
            if needs_update(out, n, "tlconfig.lua") then
                if compiled == 0 then status("Compiling vendored Tecs...") end
                run(with_lua_path("tl gen " .. q(n) .. " -o " .. q(out)))
                compiled = compiled + 1
            end
        end
    end
end

-- Copy assets/ into build/, skipping source-only files; stamp guards reruns.
local function copy_assets()
    if not exists("assets") then return end
    local stamp = path_join("build/assets/.copy-stamp")
    if exists(stamp) and file_mtime(stamp) >= tree_mtime("assets") then
        status("Assets are up to date.")
        return
    end
    status("Copying assets...")
    copy_dir("assets", "build/assets", {"*.ase", "*.aseprite"})
    write_file(stamp, tostring(os.time()) .. "\n")
end

-- Stage the runtime Lua tree into build/: the vendored rocks plus the latest
-- tecs/tecs2d builds and their bundled internal assets. Stamp guards reruns.
local function copy_vendor()
    local required = path_join("build/vendor/share/lua/5.1/tecs2d/init.lua")
    local stamp = path_join("build/vendor/.copy-stamp")
    local tecs_build = path_join(tecs_dir, "build/tecs")
    local tecs2d_build = path_join(tecs_dir, "build/tecs2d")
    local vendor_time = math.max(
        tree_mtime("src/vendor"),
        file_mtime(path_join(tecs_build, "init.lua")),
        file_mtime(path_join(tecs2d_build, "init.lua"))
    )
    if exists(required) and exists(stamp) and file_mtime(stamp) >= vendor_time then
        status("Runtime vendor tree is up to date.")
        return
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
    write_file(stamp, tostring(os.time()) .. "\n")
end

-- Task table: each entry implements one `tecs <target>` command.
local tasks = {}

function tasks.check()
    ensure_types()
    ensure_vendor()
    status("Typechecking...")
    local sources = table.concat(list_teal_sources(), " ")
    run(with_lua_path("tl check " .. sources))
end

function tasks.build()
    status("Building...")
    ensure_types()
    ensure_vendor()
    compile_sources()
    copy_assets()
    copy_vendor()
    write_file(HOT_RELOAD_STAMP, tostring(os.time()) .. "\n")
end

function tasks.run()
    ensure_love12()
    tasks.build()
    status("Launching game...")
    if is_windows then
        run('cmd /C "cd /D build && ' .. q(path_join("..", love_bin())) .. ' ."')
    else
        run("cd build && " .. q(path_join("..", love_bin())) .. " .")
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
    copy_dir(template_dir(), target)
    mkdir(path_join(target, "assets"))
    mkdir(path_join(target, "types"))

    status("Project created. Next: cd " .. target .. " && tecs check")
end

local function local_busted()
    local bin = path_join("src/vendor/bin")
    local candidates = is_windows and {
        path_join(bin, "busted.bat"),
        path_join(bin, "busted.cmd"),
        path_join(bin, "busted.exe"),
        path_join(bin, "busted"),
    } or {
        path_join(bin, "busted"),
    }
    for _, candidate in ipairs(candidates) do
        if path_exists(candidate) then
            return q(candidate)
        end
    end
    return "busted"
end

function tasks.test(args)
    status("Running tests...")
    local cmd = local_busted()
    args = args or {}
    for _, arg in ipairs(args) do
        cmd = cmd .. " " .. shell_arg(arg)
    end
    run(cmd)
end

tasks["wipe-clean"] = function()
    status("Removing build artifacts, vendored dependencies, and Love2D...")
    remove("build")
    remove("src/vendor")
    remove(love12_dir)
end

function tasks.love12()
    download_love12()
end

function tasks.dev()
    local tecs_build = path_join(tecs_dir, "build/tecs")
    local tecs2d_build = path_join(tecs_dir, "build/tecs2d")
    if not exists(tecs_build) or not exists(tecs2d_build) then
        error("Tecs build output not found. Build Tecs first: " .. tecs_dir, 0)
    end
    mkdir(path_join(vendor_lua))
    remove(path_join(vendor_lua, "tecs"))
    remove(path_join(vendor_lua, "tecs2d"))
    status("Preparing local Tecs development source...")
    copy_dir(path_join(tecs_dir, "src/tecs"), path_join(vendor_lua, "tecs"))
    copy_dir(path_join(tecs_dir, "src/tecs2d"), path_join(vendor_lua, "tecs2d"))
    ensure_types()
    status("Dev mode prepared. Re-run `tecs build` after changes.")
end

tasks["sync-tecs"] = function()
    status("Reinstalling Tecs and Tecs2D from " .. tecs_dir .. "...")
    if not exists(path_join(tecs_dir, "tecs-dev-1.rockspec")) then
        error("rockspec not found at " .. path_join(tecs_dir, "tecs-dev-1.rockspec"), 0)
    end
    remove(path_join(vendor_lua, "tecs"))
    remove(path_join(vendor_lua, "tecs2d"))
    ensure_types()
    run(tecs_cmd("luarocks make --tree=" .. q(path_join(cwd(), "src/vendor")) .. " --lua-version=5.1 tecs-dev-1.rockspec"))
    run(tecs_cmd("luarocks make --tree=" .. q(path_join(cwd(), "src/vendor")) .. " --lua-version=5.1 tecs2d-dev-1.rockspec"))
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
        description = "Install project dependencies if needed, compile Teal sources, copy assets, and refresh build output.",
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
        name = "test",
        summary = "Run Busted tests",
        description = "Run the project's Busted test suite from the project root.",
        action = tasks.test,
    },
    {
        name = "wipe-clean",
        summary = "Remove build artifacts, vendored dependencies, and Love2D",
        description = "Remove build/, src/vendor/, and the downloaded .love12 runtime.",
        action = tasks["wipe-clean"],
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
        description = "Copy local Tecs/Tecs2D sources from TECS_DIR or ../tecs into src/vendor/ for development iteration.",
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
    io.write(color("bright", "Usage: ") .. color("green", "tecs") .. " [--version] " .. color("cyan", "<command>") .. "\n\n")
    io.write(color("bright", "Commands:") .. "\n")
    for _, command in ipairs(commands) do
        io.write("  " .. color("cyan", string.format("%-11s", command.name)) .. command.summary .. "\n")
    end
    io.write("\n")
    io.write(color("magenta", "Tip:") .. [[ You can connect to your game using the built-in MCP server. Tell your
agent to launch the game and connect over MCP.

]])
    io.write(color("magenta", "Hot reload:") .. [[ while the game is running, rerun ]] .. color("cyan", "tecs build") .. [[ from another terminal.
A successful build updates build/.tecs-reload-stamp; the running game will
snapshot, restart, and restore state automatically.
]])
end

function tasks.help()
    print_help()
end

local function parser()
    local p = argparse("tecs", "Build, check, run, and manage fixed-layout Tecs starter projects.")
    p:help_max_width(88)
    p:flag("--version", "Show version and exit")
    p:command_target("command")
    p:require_command(false)

    for _, command in ipairs(commands) do
        local subcommand = p:command(command.name, command.description or command.summary)
            :summary(command.summary)
            :action(function(args)
                args.command = command.name
            end)
        if command.name == "test" then
            subcommand:handle_options(false)
            subcommand:argument("busted_args", "Arguments passed through to busted.")
                :args("*")
        elseif command.name == "new" then
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

        if target == "test" then
            task(args.busted_args)
        elseif target == "new" then
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

return M
