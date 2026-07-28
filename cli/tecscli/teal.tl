--- Running the Teal compiler this binary carries.
---
--- **The compiler is a pinned commit compiled into the binary, not a rock
--- resolved on a user's machine.** `cmake/Revisions.cmake` names it beside SDL
--- and Box2D, because it is a dependency in the same sense: a project checked
--- by one revision and formatted by another is a project whose CI disagrees
--- with its editor, and the failure is silent in the direction that matters.
---
--- It runs in a child process rather than in this one, and that is deliberate.
--- `tlcli.main` ends with `os.exit`, which is right for a program whose whole
--- job is one check and wrong for `tecs build`, which type-checks and then has
--- work left to do. Intercepting `os.exit` would work until the day the
--- compiler reached it through the compatibility shim it already loads. A child
--- also gets the project root as its working directory for free, which is what
--- `tlconfig.lua` is resolved against.
---
--- The child is this same executable, reached through a hidden `__teal`
--- command. There is no `tl` on a user's machine to run instead.

local layout <const> = require("tecscli.layout")
local shell <const> = require("tecscli.shell")

local record teal
end

--- Include paths every invocation needs, in the order `tl` searches them.
---
--- Last wins, so the project's own sources come last: a game that names a
--- module the engine also has means its own. The declarations directory
--- carries LuaJIT's `ffi`, `jit`, `bit` and `buffer`, which the engine's
--- sources reference and which no compiler knows about on its own.
local function includes(paths: layout, projectSource?: string): {string}
    local argv <const>: {string} = {
        "-I",
        paths.tools,
        "-I",
        paths.teal,
    }
    if projectSource ~= nil and projectSource ~= "" then
        argv[#argv + 1] = "-I"
        argv[#argv + 1] = projectSource
    end
    return argv
end

--- Runs `tl` with `args`, in `cwd`, and answers its exit code.
local function invoke(args: {string}, cwd: string): integer
    local argv <const> = layout.reinvoke()
    argv[#argv + 1] = "__teal"
    for _, argument in ipairs(args) do
        argv[#argv + 1] = argument
    end
    return shell.run(argv, cwd)
end

--- Type-checks `sources`, which are paths relative to `cwd`.
---
--- `--global-env-def tecs.global` is what puts the `tecs` global in scope
--- without a project having to require anything, and it resolves out of the
--- installed Teal tree rather than out of this repository.
function teal.check(paths: layout, cwd: string, projectSource: string, sources: {string}): integer
    local args <const>: {string} = {"--global-env-def", "tecs.global"}
    for _, argument in ipairs(includes(paths, projectSource)) do
        args[#args + 1] = argument
    end
    args[#args + 1] = "check"
    for _, source in ipairs(sources) do
        args[#args + 1] = source
    end
    return invoke(args, cwd)
end

--- Compiles `sources` into `output`, keeping their layout under `root`.
function teal.generate(
    paths: layout, cwd: string, projectSource: string, root: string, output: string, sources: {string}
): integer
    local args <const>: {string} = {"--global-env-def", "tecs.global"}
    for _, argument in ipairs(includes(paths, projectSource)) do
        args[#args + 1] = argument
    end
    -- Quiet, because `tecs build` reports what it built and a second listing
    -- of every file the compiler wrote is the same answer told twice.
    args[#args + 1] = "-q"
    args[#args + 1] = "gen"
    args[#args + 1] = "--gen-target=5.1"
    args[#args + 1] = "--root"
    args[#args + 1] = root
    args[#args + 1] = "--output-dir"
    args[#args + 1] = output
    for _, source in ipairs(sources) do
        args[#args + 1] = source
    end
    return invoke(args, cwd)
end

--- What a `__teal` child does: hands its arguments to the compiler and exits.
---
--- The module name is built rather than written, so the type checker does not
--- follow this require into the compiler's own compiled Lua. That tree is
--- generated code with no `.tl` beside it, and checking it reports errors in
--- somebody else's build output as though they were errors here.
function teal.serve(args: {string})
    -- One table rather than a spread vector. `tlcli.main` is declared over
    -- varargs and immediately hands them to `argparse:parse`, which takes a
    -- list, so its own `tl` script calls it with `({...})`. Spreading here
    -- reaches `ipairs` with a string and fails inside the parser.
    local main <const> = require("tlcli." .. "main") as function({string})
    main(args)
    -- Reached only when the compiler declined to exit for itself.
    os.exit(0)
end

return teal
