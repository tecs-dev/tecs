--- Where the parts of an installed tecs are, and what this binary is.
---
--- Four questions every command asks and none should answer for itself: where
--- the engine's compiled Lua is, where its Teal type information is, where the
--- pinned tools are, and what to execute to run a game.
---
--- The answers differ between a build tree and an installed one, and the
--- difference is one level of nesting:
---
--- ```
---  Part               Build tree                Installed
---  ─────────────────  ────────────────────────  ────────────────────────
---  Compiled Lua       out/<preset>/lua          <prefix>/share/tecs/lua
---  Teal types         out/<preset>/teal         <prefix>/share/tecs/teal
---  Pinned tools       out/<preset>/lua/tecstools  ...lua/tecstools
---  Executable         out/<preset>/bin/tecs     <prefix>/bin/tecs
--- ```
---
--- So the Teal tree is the content root's sibling in both, which is why it is
--- reached that way rather than by asking which tree this is.

local tecs <const> = require("tecs")

local record layout
    --- Content root: the engine's compiled Lua and the assets beside it.
    root: string
    --- The engine's `.tl` sources, which are its type information.
    teal: string
    --- The pinned Teal compiler and Cerulean formatter.
    tools: string
    --- Templates `tecs new` writes out.
    templates: string
end

--- Everything but the last path segment, without a trailing separator.
local function parent(path: string): string
    local found = path:match("^(.*)[/\\][^/\\]+$")
    return found or "."
end

--- The last path segment.
local function basename(path: string): string
    return (path:match("([^/\\]+)$")) or path
end

--- Fills in every path from the content root.
function layout.resolve(root: string): layout
    return {
        root = root,
        teal = parent(root) .. "/teal",
        tools = root .. "/tecstools",
        templates = root .. "/tecscli/templates",
    }
end

--- The `tecs` binary that is running, as an absolute path.
---
--- `paths.base` is the executable's own directory, which SDL answers from the
--- process rather than from `argv[0]`, so it survives being reached through a
--- symbolic link or a `PATH` lookup. Only the file name comes from `argv[0]`,
--- which is what makes a renamed copy still find itself.
function layout.self(): string
    local argv = (_G as {string: {integer: string}})["arg"]
    local invoked = argv ~= nil and argv[0] or "tecs"
    local base = tecs.paths.base()
    if base == nil or base == "" then
        return invoked
    end
    return base .. basename(invoked)
end

--- How to invoke this binary again so it comes back as the CLI.
---
--- A release bakes the CLI in as its entry chunk, so the binary's own name is
--- enough. A build tree bakes in the demo instead and reaches the CLI through
--- `--entry`, which is the seam that already existed. Both are answered by
--- repeating whatever this process was started with, rather than by asking
--- which kind of tree this is.
function layout.reinvoke(): {string}
    local argv = (_G as {string: {integer: string}})["arg"]
    local command <const>: {string} = {layout.self()}
    local index = 1
    while argv[index] ~= nil do
        if argv[index] == "--entry" and argv[index + 1] ~= nil then
            command[#command + 1] = "--entry"
            command[#command + 1] = argv[index + 1]
            break
        end
        index = index + 1
    end
    return command
end

--- The arguments this process was given, with a leading `--entry` pair gone.
---
--- The host consumes `--entry` and hands the whole vector through, so a CLI
--- reached that way sees two arguments it did not ask for. Stripping them here
--- is what makes a build tree's `tecs --entry <chunk> check` and a release's
--- `tecs check` the same command.
function layout.arguments(): {string}
    local argv = (_G as {string: {integer: string}})["arg"]
    local args: {string} = {}
    local index = 1
    while argv[index] ~= nil do
        if argv[index] == "--entry" and argv[index + 1] ~= nil and #args == 0 then
            index = index + 2
        else
            args[#args + 1] = argv[index]
            index = index + 1
        end
    end
    return args
end

return layout
