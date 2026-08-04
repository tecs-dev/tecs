--[=[
Debugger commands, and the tools they project to.

A command is declared once. Its argument schema types both a typed command line
and a JSON tool call, its action returns one structured result, and the debug
server advertises it with an input schema, an output schema and safety hints
that were all derived from that single declaration. Nothing about a command is
written twice, so the two surfaces cannot disagree.

## Getting the commands

`tecs.io.mcp` does not install them. An application with `mcpPort` set calls
`ensure` for its own world, so every session that has a debug server has the
whole command surface. A headless tool calls `ensure` itself.

## Adding one

```teal
local debugapi <const> = require("tecs.debug")

debugapi.ensure(world)
debugapi.register(world, {
    name = "wave",
    section = "Custom",
    shortHelp = "report the wave the game is on",
    agentHelp = "Reports the current wave number and how many enemies are left in it. "
        .. "Call it to check progress before spawning or despawning anything.",
    readOnly = true,
    outputSchema = {
        ["type"] = "object",
        properties = {
            wave = {["type"] = "integer"},
            remaining = {["type"] = "integer"},
        },
        required = {"wave", "remaining"},
    },
    run = function(_values: {string: any}): debugapi.Result
        return {
            message = "wave " .. tostring(state.wave),
            data = {wave = state.wave, remaining = state.remaining},
        }
    end,
})
```

That registers the tool `wave`. A command with `subcommands` registers one tool
per verb, named `<command>_<verb>`, and registers `<command>` as well when it
carries a `run` of its own.

## Results and failures

`Result.data` is the tool call's structured content, and `Result.message`
travels beside it under the key `message`. A result with `ok = false` raises its
`code` and `message` through the tool call, so an agent reads a failure the way
it reads any other tool error rather than by inspecting a field.

Declare `outputSchema` on anything a game ships. It is what lets an agent know
the shape of an answer before it makes the call, and it is what the reference
renders.

## Command names are a compatibility surface

A tool name is generated from a command name and a verb name, so renaming
either renames a tool that an agent already calls. Choose both once.

Requiring this module as `debug` shadows Lua's own `debug` library. A module
that needs both binds this one as `debugapi`.
]=]

local type types = require("tecs.types")
local storekeys <const> = require("tecs.internal.storekeys")
local registry <const> = require("tecs.debug.internal.registry")
local type debugtypes = require("tecs.debug.internal.types")
local type cmdargs = require("tecs.debug.internal.cmdargs")
local enginecmds <const> = require("tecs.debug.internal.cmd.engine")
local capturecmds <const> = require("tecs.debug.internal.cmd.capture")
local physicscmds <const> = require("tecs.debug.internal.cmd.physics")

local record debugapi
    --- Declares one command.
    type Command = debugtypes.Command

    --- Declares one verb under a command.
    type Subcommand = debugtypes.Subcommand

    --- Reports what one command did.
    type Result = debugtypes.Result

    --- Declares a command's arguments.
    type Schema = cmdargs.Schema

    --- Declares one argument.
    type ArgSpec = cmdargs.ArgSpec

    --- Holds the commands one world has declared.
    type Registry = registry.Registry

    --- Groups commands in help and in the generated reference, in the order
    --- they are presented. A command that names no section groups as
    --- `"Custom"`.
    SECTIONS: {string}

    ensure: function(world: types.World): Registry
    of: function(world: types.World): Registry
    register: function(world: types.World, command: Command)
end

debugapi.SECTIONS = registry.SECTIONS

-- The store key names a world's command registry. The string is a stable name
-- tools look the registry up by, independent of the Lua module path.
local registryKey <const> = storekeys.newKey("tecs.debug", nil as registry.Registry)

--- The command groups the engine registers, in the order they are presented.
local GROUPS <const>: {function(debugtypes.Env): {debugtypes.Command}} = {
    enginecmds.commands,
    capturecmds.commands,
    physicscmds.commands,
}

--- Returns the registry installed in `world`.
---
--- @param world The caller supplies a world with or without a registry.
--- @return The world's registry, or nil before `ensure` has run.
function debugapi.of(world: types.World): registry.Registry
    return world.resources[registryKey]
end

--- Builds the world's command registry, or returns the one it already has.
---
--- Registering the engine's own commands projects each of them onto the debug
--- server, so a session that calls this once has the whole surface. Calling it
--- again answers with the same registry and registers nothing further.
---
--- @param world The caller supplies the world the commands read and write.
--- @return The world's registry.
function debugapi.ensure(world: types.World): registry.Registry
    local existing <const> = world.resources[registryKey]
    if existing ~= nil then
        return existing
    end

    local built <const> = registry.new(world)
    local env <const>: debugtypes.Env = {world = world}
    for _, group in ipairs(GROUPS) do
        for _, command in ipairs(group(env)) do
            built:add(command)
        end
    end
    world.resources[registryKey] = built
    return built
end

--- Registers a game's own command and projects it onto the debug server.
---
--- Raises when the world has no registry, and raises on a malformed
--- declaration: a command is written once and called forever, so a mistake in
--- one belongs at the call that made it.
---
--- @param world The caller supplies a world `ensure` has already run on.
--- @param command The caller supplies a complete declaration.
function debugapi.register(world: types.World, command: debugtypes.Command)
    local built <const> = world.resources[registryKey]
    if built == nil then
        error("tecs.debug: this world has no command registry; call tecs.debug.ensure(world) first", 2)
    end
    built:add(command)
end

return debugapi
