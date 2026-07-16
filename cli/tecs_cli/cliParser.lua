-- Argument parser, command overview, and shell-facing help for the Tecs CLI.

local M = {}

function M.new(options)
    local argparse = assert(options.argparse)
    local color = assert(options.color)
    local commands = assert(options.commands)
    local version = assert(options.version)
    local parser = {}

    function parser.commandNames()
        local names = {}
        for _, command in ipairs(commands) do
            names[#names + 1] = command.name
        end
        return table.concat(names, ", ")
    end

    function parser.printHelp()
        io.write(color("bright cyan", "Tecs CLI ") .. color("black", version) .. "\n\n")
        io.write(color("bright", "Usage: ") .. color("green", "tecs")
            .. " [--version] [--quiet] " .. color("cyan", "<command>") .. "\n\n")
        io.write(color("bright", "Commands:") .. "\n")
        for _, command in ipairs(commands) do
            io.write("  " .. color("cyan", string.format("%-13s", command.name)) .. command.summary .. "\n")
        end
        io.write("\n")
        io.write(color("magenta", "MCP:") .. [[ there are two ways to connect agents. ]]
            .. color("cyan", "tecs mcp") .. [[ serves the project over
stdio: it can start and restart the game itself, exposes check/build/integ/
dist as tools, and the session survives game restarts and crashes. Every
running game also embeds its own MCP server over HTTP (port 19999 by
default); connect to that directly to attach to a game that is already
running, such as a distributed build with enableInDist.

]])
        io.write(color("magenta", "Dependencies:") .. [[ vendor pure-Lua rocks with LuaRocks into the
project tree, which already uses the LuaRocks layout:
    luarocks install --tree src/vendor --lua-version=5.1 <rock>
Teal declarations for popular rocks are published as <rock>-tl-type rocks.
src/vendor is regenerated and usually gitignored, so record your rocks
somewhere repeatable and reinstall after a fresh clone. Only pure-Lua rocks
work: the game runtime has no C toolchain.

]])
        io.write(color("magenta", "Hot reload:") .. [[ while the game is running, rerun ]]
            .. color("cyan", "tecs build") .. [[ from another terminal.
A successful build updates build/.tecs-reload-stamp; the running game will
snapshot, restart, and restore state automatically.
]])
    end

    function parser.create()
        local result = argparse("tecs", "Build, check, run, and manage fixed-layout Tecs starter projects.")
        result:help_max_width(88)
        result:flag("--version", "Show version and exit")
        result:flag("-q --quiet", "Suppress progress output")
        result:command_target("command")
        result:require_command(false)

        for _, command in ipairs(commands) do
            local subcommand = result:command(command.name, command.description or command.summary)
                :summary(command.summary)
                :action(function(args)
                    args.command = command.name
                end)
            if command.setup then command.setup(subcommand) end
        end

        result:command("help", "Show the Tecs CLI command overview.")
            :summary("Show command overview")
            :action(function(args)
                args.command = "help"
            end)
        return result
    end

    return parser
end

return M
