--- The command surface, and what each command does.
---
--- Eight commands, and between them a whole toolchain at one pinned set of
--- revisions. That is the point of the exercise rather than a convenience: a
--- Lua developer today assembles a formatter, a test runner and a build from
--- three unrelated projects and gets no type checker at all, and every one of
--- those moves independently. Here they are one file and one version.
---
--- ```
---  Command  What it does
---  ───────  ────────────────────────────────────────────────────────────────
---  new      Writes a working game out of the binary. Nothing is fetched.
---  check    Type-checks the project against the engine's installed types
---  format   Formats, or checks formatting, with the carried Cerulean
---  test     Compiles spec/ and runs it
---  build    Compiles src/, stages assets, writes build/
---  run      Builds, then becomes the game
---  clean    Removes build/
---  info     Versions, pins, project status, packaging targets
--- ```
---
--- Every one of them finds the project by searching upward for `tecs.lua`, so
--- all of them work from any directory inside it.

local tecs <const> = require("tecs")
local builder <const> = require("tecscli.builder")
local files <const> = require("tecscli.files")
local formatting <const> = require("tecscli.formatting")
local layout <const> = require("tecscli.layout")
local project <const> = require("tecscli.project")
local report <const> = require("tecscli.report")
local scaffold <const> = require("tecscli.scaffold")
local shell <const> = require("tecscli.shell")
local teal <const> = require("tecscli.teal")
local testing <const> = require("tecscli.testing")

local record run
end

local USAGE <const> = [[
tecs — a typed entity component system and the engine around it

usage: tecs <command> [arguments]

  new <directory>   Scaffold a project. --force overwrites.
  check [paths]     Type-check. Defaults to the project's source directory.
  format [paths]    Format in place. --check reports and writes nothing.
  test              Compile and run spec/
  build             Compile src/, stage assets, write build/
  run               Build, then launch the game
  clean             Remove build/
  info              Versions, pinned tool revisions, project, targets

  --version         Print the version and exit
  --help            This

A project is a directory holding tecs.lua. Every command searches upward for
it, so all of them work from anywhere inside a project.
]]

--- Writes a line to standard output.
local function say(line: string)
    io.write(line, "\n")
end

--- Writes a line to standard error.
local function complain(line: string)
    io.stderr:write(line, "\n")
end

--- Reports that there is no project here, and how to make one.
local function noProject(reason: string): integer
    complain(("tecs: %s"):format(reason))
    complain("Run `tecs new <directory>` to scaffold one.")
    return 1
end

--- Whether `flag` is among the arguments, removing it if so.
local function takeFlag(args: {string}, flag: string): boolean
    for index, argument in ipairs(args) do
        if argument == flag then
            table.remove(args, index)
            return true
        end
    end
    return false
end

--- `tecs new <directory>`
local function commandNew(paths: layout, args: {string}): integer
    local force = takeFlag(args, "--force")
    local directory = args[1]
    if directory == nil then
        complain("tecs new: name a directory to create")
        return 1
    end

    -- The project's name is the last segment of the path, which is what a
    -- developer typed and what they will call it.
    local name = directory:match("([^/\\]+)/?$") or directory
    local ok, reason = scaffold.write(paths.templates, directory, name, force)
    if not ok then
        complain(("tecs new: %s"):format(reason))
        return 1
    end

    say(("Created %s"):format(directory))
    say("")
    say(("  cd %s"):format(directory))
    say("  tecs run")
    return 0
end

--- `tecs check [paths]`
local function commandCheck(paths: layout, args: {string}): integer
    local found, reason = project.find()
    if found == nil then
        return noProject(reason)
    end

    local sources: {string} = {}
    if #args > 0 then
        sources = args
    else
        local sourceRoot = project.path(found, found.source)
        for _, relative in ipairs(
            files.walk(sourceRoot, function(path: string): boolean return files.hasSuffix(path, ".tl") end)
        ) do
            sources[#sources + 1] = found.source .. "/" .. relative
        end
    end

    if #sources == 0 then
        complain(("tecs check: no .tl sources under %s"):format(found.source))
        return 1
    end

    return teal.check(paths, found.root, project.path(found, found.source), sources)
end

--- `tecs format [--check] [paths]`
local function commandFormat(args: {string}): integer
    local check = takeFlag(args, "--check")
    local found, reason = project.find()
    if found == nil then
        return noProject(reason)
    end

    local worst, missing = formatting.apply(found.root, found.build, check)
    if #missing > 0 then
        complain(("tecs format: not installed: %s"):format(table.concat(missing, ", ")))
        complain("Those languages were left alone. Everything tecs carries itself was formatted.")
        if worst == 0 then
            worst = 1
        end
    end
    if worst ~= 0 and check then
        complain("tecs format: some files are not formatted. Run `tecs format`.")
    end
    return worst
end

--- `tecs build`
local function commandBuild(paths: layout): integer
    local found, reason = project.find()
    if found == nil then
        return noProject(reason)
    end

    local result, failure = builder.build(found, paths)
    if result == nil then
        complain(("tecs build: %s"):format(failure))
        return 1
    end
    say(("Built %s: %d sources, %d assets"):format(found.name, result.compiled, result.assets))
    return 0
end

--- `tecs run`
---
--- Becomes the game rather than starting it as a child. One process, one exit
--- status, and an interrupt that reaches the game instead of the tool.
local function commandRun(paths: layout): integer
    local found, reason = project.find()
    if found == nil then
        return noProject(reason)
    end

    local result, failure = builder.build(found, paths)
    if result == nil then
        complain(("tecs run: %s"):format(failure))
        return 1
    end

    -- The engine's own content root, passed explicitly. A game finds its
    -- shaders, materials and fonts there, and the running binary is the only
    -- thing that knows where it was installed.
    shell.setenv("TECS_LUA", paths.root)
    shell.setenv("TECS_ASSETS", paths.root)

    local trouble = shell.become({layout.self(), "--entry", result.entry})
    complain(("tecs run: %s"):format(trouble))
    return 1
end

--- `tecs info`
local function commandInfo(paths: layout): integer
    report.write(paths, say)
    return 0
end

--- `tecs test`
---
--- Specs run in this process, which already has the engine loaded, so a spec
--- can build a world and simulate physics with no window in sight.
local function commandTest(paths: layout): integer
    local found, reason = project.find()
    if found == nil then
        return noProject(reason)
    end

    local specRoot = project.path(found, found.spec)
    if not tecs.filesystem.isDirectory(specRoot) then
        complain(("tecs test: no %s directory"):format(found.spec))
        return 1
    end

    -- The game's own modules are compiled first, since a spec that tests them
    -- has to be able to require them.
    local built = builder.build(found, paths)
    if built == nil then
        complain("tecs test: the project does not build")
        return 1
    end

    local specs = files.walk(specRoot, function(path: string): boolean return files.hasSuffix(path, "_spec.tl") end)
    if #specs == 0 then
        complain(("tecs test: no *_spec.tl under %s"):format(found.spec))
        return 1
    end

    local qualified: {string} = {}
    for index, relative in ipairs(specs) do
        qualified[index] = found.spec .. "/" .. relative
    end
    local code = teal.generate(
        paths, found.root, project.path(found, found.source), found.spec, found.build .. "/spec", qualified
    )
    if code ~= 0 then
        return code
    end

    local buildRoot = project.path(found, found.build)
    package.path = table.concat(
        {
            buildRoot .. "/spec/?.lua",
            buildRoot .. "/lua/?.lua",
            buildRoot .. "/lua/?/init.lua",
            package.path,
        },
        ";"
    )

    testing.reset()
    for _, relative in ipairs(specs) do
        local module = (relative:sub(1, -4):gsub("/", "."))
        local ok, failure = pcall(require, module)
        if not ok then
            complain(("  FAIL %s: %s"):format(module, tostring(failure)))
            return 1
        end
    end

    local summary = testing.summary()
    say("")
    say(("%d passed, %d failed"):format(summary.passed, summary.failed))
    for _, failure in ipairs(summary.failures) do
        complain(("  %s\n    %s"):format(failure.name, failure.message))
    end
    return summary.failed == 0 and 0 or 1
end

--- `tecs clean`
local function commandClean(): integer
    local found, reason = project.find()
    if found == nil then
        return noProject(reason)
    end
    builder.clean(found)
    say(("Removed %s"):format(project.path(found, found.build)))
    return 0
end

--- Dispatches one invocation and exits with its status.
---
--- @param root The content root the bootstrap resolved.
function run.main(root: string)
    local paths <const> = layout.resolve(root)

    local args <const> = layout.arguments()
    local command = args[1]
    table.remove(args, 1)

    if command == nil or command == "help" or command == "--help" or command == "-h" then
        io.write(USAGE)
        os.exit(command == nil and 1 or 0)
    end
    if command == "--version" or command == "version" then
        say(tecs.version)
        os.exit(0)
    end

    -- Not a command: the Teal compiler, run in a child so its own `os.exit`
    -- lands on a process with nothing left to do.
    if command == "__teal" then
        teal.serve(args)
        os.exit(0)
    end

    local code: integer
    if command == "new" then
        code = commandNew(paths, args)
    elseif command == "check" then
        code = commandCheck(paths, args)
    elseif command == "format" then
        code = commandFormat(args)
    elseif command == "build" then
        code = commandBuild(paths)
    elseif command == "run" then
        code = commandRun(paths)
    elseif command == "test" then
        code = commandTest(paths)
    elseif command == "clean" then
        code = commandClean()
    elseif command == "info" then
        code = commandInfo(paths)
    else
        complain(("tecs: no such command: %s"):format(command))
        io.write(USAGE)
        code = 1
    end

    os.exit(code)
end

return run
