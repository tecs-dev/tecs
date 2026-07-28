--- `tecs format`, over the table `scripts/format.py` owns.
---
--- **There is one description of what gets formatted and by what, and this is
--- not it.** `scripts/format.py` is, and the build asks that script to print
--- its own tables and bakes the answer in as `tecscli.toolchain`. So the
--- repository's `make format`, the CMake target of the same name and this
--- command all read the same suffix map, the same exclusions and the same
--- argument lists. A second list here is the failure this arrangement exists to
--- prevent: an editor formatting on save and a CI job checking formatting would
--- one day disagree about one file, and the diff would belong to nobody.
---
--- **The Teal formatter is inside the binary and is pinned by commit.** That is
--- the part worth stating twice. A formatter resolved at run time is one that
--- can change under a user without anything saying so, and one did: a floating
--- Cerulean rewrote three `= macroexp(...)` declarations without their bodies,
--- and `tl check` still passed, because what a rewrite like that removes is the
--- implementation and what it leaves is the declaration. `tecs format` runs the
--- exact commit `cmake/Revisions.cmake` names, and `tecs info` prints it.
---
--- Everything else formats through a program on `PATH`, because a C++, Rust or
--- Node formatter cannot be carried inside a Lua payload. A missing one is
--- reported by name, which is what `format.py` does with the same table.

local shell <const> = require("tecscli.shell")
local files <const> = require("tecscli.files")
local lfsshim <const> = require("tecscli.lfsshim")
local toolchain <const> = require("tecscli.toolchain")

local record formatting
    --- What one language's files are formatted with.
    record Tool
        tool: string
        apply: {string}
        check: {string}
        module: string
    end
end

--- The language a path formats as, or nil when nothing formats it.
local function languageOf(relative: string): string
    local name = relative:match("([^/]+)$") or relative
    local named = (toolchain.format.names as {string: string})[name]
    if named ~= nil then
        return named
    end
    local suffix = name:match("(%.[^.]+)$")
    if suffix == nil then
        return nil
    end
    return (toolchain.format.suffixes as {string: string})[suffix]
end

--- Whether a file's opening lines say a tool wrote it.
---
--- The same test `format.py` makes, for the same reason: the build writes some
--- generated files into a source tree, and a marker in the file survives a
--- rename where a path list does not.
local function isGenerated(path: string): boolean
    local handle = io.open(path, "r")
    if handle == nil then
        return false
    end
    local lines = toolchain.format.generatedScanLines as integer
    for _ = 1, lines do
        local line = handle:read("*l")
        if line == nil then
            break
        end
        local lowered = line:lower()
        for _, marker in ipairs(toolchain.format.generatedMarkers as {string}) do
            if lowered:find(marker, 1, true) ~= nil then
                handle:close()
                return true
            end
        end
    end
    handle:close()
    return false
end

--- Whether a relative path sits under a tree nothing formats.
local function isExcluded(relative: string, buildDirectory: string): boolean
    if relative:sub(1, #buildDirectory + 1) == buildDirectory .. "/" then
        return true
    end
    for _, prefix in ipairs(toolchain.format.excluded as {string}) do
        if relative:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

--- Every formattable file under `root`, grouped by language.
---
--- Discovered by walking rather than by asking git, which is where this
--- deliberately differs from `format.py`. That script runs inside a checkout
--- and takes the ignore rules already written in `.gitignore`; a project
--- `tecs new` scaffolded may not be a repository at all yet, and a formatter
--- that does nothing until `git init` has been run is a formatter that looks
--- broken. The build directory and the four version-control trees are skipped
--- explicitly instead.
function formatting.collect(root: string, buildDirectory: string): {string: {string}}
    local grouped: {string: {string}} = {}
    for _, relative in ipairs(files.walk(root)) do
        if not isExcluded(relative, buildDirectory) then
            local language = languageOf(relative)
            if language ~= nil and not isGenerated(root .. "/" .. relative) then
                local bucket = grouped[language]
                if bucket == nil then
                    bucket = {}
                    grouped[language] = bucket
                end
                bucket[#bucket + 1] = relative
            end
        end
    end
    return grouped
end

--- Runs the formatter this binary carries, in this process.
---
--- The flags come from the same table as everything else: whatever
--- `format.py` passes after the program name is what is passed here, so
--- `--check` reaches Cerulean because that script says it should.
local function runCarried(tool: formatting.Tool, check: boolean, paths: {string}): integer
    lfsshim.install()
    local cli = require(tool.module) as {string: any}

    local argv: {string} = {}
    local declared = check and tool.check or tool.apply
    for index = 2, #declared do
        argv[#argv + 1] = declared[index]
    end
    for _, path in ipairs(paths) do
        argv[#argv + 1] = path
    end

    local newStdio <const> = (cli.Stdio as {string: any}).new as function(
        function(string), function(string), function(): string
    ): any
    local stdio <const> = newStdio(function(text: string) io.stdout:write(text) end, function(text: string)
        io.stderr:write(text)
    end,
    function(): string return io.stdin:read("*a") end)
    return (cli.run as function({string}, any): integer)(argv, stdio)
end

--- Formats, or checks, every file under `root`.
---
--- @return The worst exit code seen, and the languages whose tool is missing.
function formatting.apply(root: string, buildDirectory: string, check: boolean): integer, {string}
    local grouped = formatting.collect(root, buildDirectory)

    local languages: {string} = {}
    for language in pairs(grouped) do
        languages[#languages + 1] = language
    end
    table.sort(languages)

    local worst = 0
    local missing: {string} = {}
    for _, language in ipairs(languages) do
        local tool = (toolchain.format.tools as {string: formatting.Tool})[language]
        if tool.module ~= nil then
            local code = runCarried(tool, check, grouped[language])
            if code > worst then
                worst = code
            end
        elseif not shell.onPath(tool.tool) then
            missing[#missing + 1] = tool.tool
        else
            local argv: {string} = {}
            for _, part in ipairs(check and tool.check or tool.apply) do
                argv[#argv + 1] = part
            end
            for _, path in ipairs(grouped[language]) do
                argv[#argv + 1] = path
            end
            local code = shell.run(argv, root)
            if code > worst then
                worst = code
            end
        end
    end

    table.sort(missing)
    return worst, missing
end

return formatting
