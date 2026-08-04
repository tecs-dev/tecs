-- The registry: what holds declared commands, dispatches them, and projects
-- them onto the debug server.
--
-- One declaration answers both callers. `execute` parses a typed command line
-- and `invoke` validates a decoded JSON object, and both reach the same action
-- through the same schema, so the two surfaces cannot disagree about what an
-- argument means.
--
-- Projection registers one tool per action rather than one per command: a
-- command with verbs projects `<name>_<verb>` for each, and projects `<name>`
-- as well only when it carries an action of its own. Each projected tool closes
-- over the action it calls, so there is no name index to keep in step with the
-- listing.

local type types = require("tecs.types")
local mcp <const> = require("tecs.io.mcp")
local answer <const> = require("tecs.debug.internal.answer")
local cmdargs <const> = require("tecs.debug.internal.cmdargs")
local type debugtypes = require("tecs.debug.internal.types")

local type Command = debugtypes.Command
local type Subcommand = debugtypes.Subcommand
local type Result = debugtypes.Result

local record registry
    --- Holds the commands one world has declared.
    record Registry
        --- Read-only. Reports the world every command in the registry reads.
        world: types.World

        --- Read-only. Reports the declared commands in registration order,
        --- which is the order help and the generated reference present them in.
        list: {Command}

        --- Read-only. Resolves a name or an alias to its command.
        byName: {string: Command}

        --- Read-only. Reports the declared names, without aliases, in
        --- registration order.
        names: {string}

        --- Read-only. Counts the tools the registry has projected.
        toolCount: integer

        add: function(self: Registry, command: Command)
        execute: function(self: Registry, text: string): Result
        invoke: function(self: Registry, name: string, arguments: {string: any}): Result, string
    end

    --- Groups commands in help and in the generated reference, in the order
    --- they are presented. A command that names none groups as `"Custom"`.
    SECTIONS: {string}

    new: function(world: types.World): Registry
end

registry.SECTIONS = {"Select", "Edit", "Render", "Engine", "Capture", "Custom", "Session"}

--- Verbs that only read. A verb outside this set is assumed to write, because
--- the protocol's own default is the pessimistic one and a wrong read-only hint
--- is the more expensive mistake.
local READ_VERBS <const>: {string: boolean} = {
    list = true,
    ls = true,
    info = true,
    status = true,
    get = true,
}

--- Commands whose action destroys something the caller cannot get back.
local DESTRUCTIVE_NAMES <const>: {string: boolean} = {
    despawn = true,
    remove = true,
    quit = true,
}

local RegistryMT <const>: metatable<registry.Registry> = {
    __index = registry.Registry,
}

local function isReadOnly(command: Command, sub: Subcommand): boolean
    if sub ~= nil then
        if sub.readOnly ~= nil then
            return sub.readOnly
        end
        return READ_VERBS[sub.name] == true
    end
    if command.readOnly ~= nil then
        return command.readOnly
    end
    return READ_VERBS[command.name] == true
end

local function isDestructive(command: Command, sub: Subcommand): boolean
    if sub ~= nil then
        if sub.destructive ~= nil then
            return sub.destructive
        end
        return DESTRUCTIVE_NAMES[command.name] == true or sub.name == "load"
    end
    if command.destructive ~= nil then
        return command.destructive
    end
    return DESTRUCTIVE_NAMES[command.name] == true
end

--- Names the tool one action projects to.
local function toolName(command: Command, sub: Subcommand): string
    if sub ~= nil then
        return command.name .. "_" .. sub.name
    end
    return command.name
end

--- Writes the description an agent reads. `agentHelp` is written for that
--- reader; `shortHelp` is written to fit one line, so it is the fallback rather
--- than the first choice.
local function toolDescription(command: Command, sub: Subcommand): string
    if sub ~= nil then
        if sub.agentHelp ~= nil then
            return sub.agentHelp
        end
        return command.name .. " " .. sub.name .. ": " .. sub.shortHelp .. "."
    end
    if command.agentHelp ~= nil then
        return command.agentHelp
    end
    return command.shortHelp .. "."
end

--- Turns a command's result into what the tool call answers with.
---
--- A failed command raises, which is how the server reports a tool error, so a
--- caller never has to read an `ok` field to find out whether anything happened.
local function payloadOf(result: Result): {string: any}
    if result == nil then
        return {}
    end
    if result.ok == false then
        error((result.code or "command_failed") .. ": " .. (result.message or "command failed"), 0)
    end

    local payload: {string: any} = {}
    if result.data ~= nil then
        for key, value in pairs(result.data) do
            payload[key] = value
        end
    end
    -- Guarded rather than assigned: writing nil here would delete a `message`
    -- the command's own data supplied, because that is what assigning nil to a
    -- Lua table key does.
    if result.message ~= nil then
        payload.message = result.message
    end
    return payload
end

--- Runs one action against an already-decoded argument object.
local function callAction(
    schema: cmdargs.Schema, run: function({string: any}): Result, arguments: {string: any}
): Result
    local values: {string: any} = {}
    if schema ~= nil then
        local parsed, reason = cmdargs.parseValues(schema, arguments or {})
        if parsed == nil then
            return {ok = false, code = "invalid_arguments", message = reason}
        end
        values = parsed
    elseif arguments ~= nil and next(arguments) ~= nil then
        return {ok = false, code = "invalid_arguments", message = "takes no arguments"}
    end
    return run(values)
end

--- Builds the tool one action projects to.
---
--- The handler closes over the action, so the listing and the dispatch are the
--- same decision made once.
local function projectTool(command: Command, sub: Subcommand): mcp.Tool
    local schema <const> = sub ~= nil and sub.schema or command.schema
    local run <const> = sub ~= nil and sub.run or command.run
    local outputSchema <const> = sub ~= nil and sub.outputSchema or command.outputSchema

    return {
        name = toolName(command, sub),
        description = toolDescription(command, sub),
        inputSchema = schema ~= nil and cmdargs.toolSchema(schema)
            or {
                ["type"] = "object",
                properties = {},
                additionalProperties = false,
            },
        outputSchema = outputSchema,
        readOnly = isReadOnly(command, sub),
        destructive = isDestructive(command, sub),
        handler = function(arguments: {string: any}): {string: any}
            return payloadOf(callAction(schema, run, arguments))
        end,
    }
end

local function validateName(what: string, name: string)
    if type(name) ~= "string" or name == "" then
        error("tecs.debug: a " .. what .. " needs a name", 3)
    end
    if name:find("%s") ~= nil then
        error("tecs.debug: " .. what .. " name '" .. name .. "' contains whitespace", 3)
    end
end

--- Registers one command and projects its actions as tools.
---
--- Raises on a bad declaration. A command is written once and read forever, so
--- a mistake in one is a programmer error and belongs at the call that made it
--- rather than at the tool call that later fails.
function registry.Registry:add(command: Command)
    validateName("command", command.name)
    if type(command.shortHelp) ~= "string" or command.shortHelp == "" then
        error("tecs.debug: command '" .. command.name .. "' needs a shortHelp", 3)
    end
    if command.run == nil and command.subcommands == nil then
        error("tecs.debug: command '" .. command.name .. "' needs run or subcommands", 3)
    end
    if self.byName[command.name] ~= nil then
        error("tecs.debug: a command named '" .. command.name .. "' is already registered", 3)
    end
    if command.schema ~= nil then
        cmdargs.validate(command.schema)
    end

    local seen <const>: {string: boolean} = {}
    for _, sub in ipairs(command.subcommands or {}) do
        validateName("subcommand", sub.name)
        if seen[sub.name] then
            error("tecs.debug: command '" .. command.name .. "' declares '" .. sub.name .. "' twice", 3)
        end
        seen[sub.name] = true
        if type(sub.shortHelp) ~= "string" or sub.shortHelp == "" then
            error("tecs.debug: '" .. command.name .. " " .. sub.name .. "' needs a shortHelp", 3)
        end
        if sub.run == nil then
            error("tecs.debug: '" .. command.name .. " " .. sub.name .. "' needs run", 3)
        end
        if sub.schema ~= nil then
            cmdargs.validate(sub.schema)
        end
    end

    for _, alias in ipairs(command.aliases or {}) do
        if self.byName[alias] ~= nil then
            error("tecs.debug: alias '" .. alias .. "' is already registered", 3)
        end
    end

    self.list[#self.list + 1] = command
    self.names[#self.names + 1] = command.name
    self.byName[command.name] = command
    for _, alias in ipairs(command.aliases or {}) do
        self.byName[alias] = command
    end

    if command.run ~= nil then
        mcp.register(projectTool(command, nil))
        self.toolCount = self.toolCount + 1
    end
    for _, sub in ipairs(command.subcommands or {}) do
        mcp.register(projectTool(command, sub))
        self.toolCount = self.toolCount + 1
    end
end

local function findSubcommand(command: Command, name: string): Subcommand
    if command.subcommands == nil or name == nil then
        return nil
    end
    for _, sub in ipairs(command.subcommands) do
        if sub.name == name then
            return sub
        end
        for _, alias in ipairs(sub.aliases or {}) do
            if alias == name then
                return sub
            end
        end
    end
    return nil
end

--- Runs a typed command line.
---
--- @param text The caller supplies one line, which may be empty.
--- @return What the command answered, or nil for an empty line.
function registry.Registry:execute(text: string): Result
    local parts, reason = cmdargs.tokenize(text)
    if parts == nil then
        return {ok = false, code = "parse_error", message = reason}
    end

    local name <const> = parts[1]
    if name == nil then
        return nil
    end
    local command <const> = self.byName[name]
    if command == nil then
        return {ok = false, code = "unknown_command", message = "no command named '" .. name .. "'"}
    end

    local run = command.run
    local schema = command.schema
    local first = 2
    local sub <const> = findSubcommand(command, parts[2])
    if sub ~= nil then
        run, schema, first = sub.run, sub.schema, 3
    end
    if run == nil then
        return {
            ok = false,
            code = "unknown_subcommand",
            message = command.name .. " expects a verb; see `help " .. command.name .. "`",
        }
    end

    local values: {string: any} = {}
    if schema ~= nil then
        local tokens: {string} = {}
        for index = first, #parts do
            tokens[#tokens + 1] = parts[index]
        end
        local parsed, argumentReason = cmdargs.parse(schema, tokens)
        if parsed == nil then
            return {ok = false, code = "invalid_arguments", message = command.name .. ": " .. argumentReason}
        end
        values = parsed
    end
    return run(values)
end

--- Runs one action by the name of the tool it projects to.
---
--- @param name The caller supplies a projected tool name.
--- @param arguments The caller supplies a decoded JSON object.
--- @return What the command answered, or nil and a reason when no action
---     carries that name.
function registry.Registry:invoke(name: string, arguments: {string: any}): Result, string
    for _, command in ipairs(self.list) do
        if command.run ~= nil and toolName(command, nil) == name then
            return callAction(command.schema, command.run, arguments)
        end
        for _, sub in ipairs(command.subcommands or {}) do
            if toolName(command, sub) == name then
                return callAction(sub.schema, sub.run, arguments)
            end
        end
    end
    return nil, "no command tool named '" .. name .. "'"
end

--- The signature help and the reference present, as `name <required> [optional]`.
local function signatureOf(command: Command, sub: Subcommand): string
    local parts: {string} = {command.name}
    if sub ~= nil then
        parts[#parts + 1] = sub.name
    end
    local schema <const> = sub ~= nil and sub.schema or command.schema
    if schema ~= nil then
        local arguments <const> = cmdargs.signature(schema)
        if arguments ~= "" then
            parts[#parts + 1] = arguments
        end
    end
    return table.concat(parts, " ")
end

--- Reports one action the way `describe` answers with it.
local function contractOf(command: Command, sub: Subcommand): {string: any}
    local tool <const> = projectTool(command, sub)
    return {
        tool = tool.name,
        signature = signatureOf(command, sub),
        shortHelp = sub ~= nil and sub.shortHelp or command.shortHelp,
        description = tool.description,
        inputSchema = tool.inputSchema,
        outputSchema = tool.outputSchema,
        readOnly = tool.readOnly,
        destructive = tool.destructive,
    }
end

local COMMAND_SCHEMA <const>: cmdargs.Schema = {
    args = {command = {required = true, help = "command name"}},
    positional = {"command"},
}

local OPTIONAL_COMMAND_SCHEMA <const>: cmdargs.Schema = {
    args = {command = {help = "command name; omitted lists every command"}},
    positional = {"command"},
}

--- Builds the three commands that answer for the registry itself.
---
--- They live here rather than in a command group because each of them reports
--- what the registry projects, and the projection is this module's.
local function discovery(self: registry.Registry): {Command}
    return {
        {
            name = "help",
            section = "Session",
            shortHelp = "list the commands, or explain one",
            agentHelp = "Lists every registered command with its one-line help, grouped by section, "
                .. "or explains one command: its signature, its arguments, and its verbs. "
                .. "Call describe instead for a machine-readable contract.",
            schema = OPTIONAL_COMMAND_SCHEMA,
            examples = {"help", "help snapshot"},
            outputSchema = {
                ["type"] = "object",
                properties = {
                    sections = {
                        ["type"] = "array",
                        description = "Sections holding at least one command, in presentation order.",
                        items = {
                            ["type"] = "object",
                            properties = {
                                name = {["type"] = "string"},
                                commands = {
                                    ["type"] = "array",
                                    items = {
                                        ["type"] = "object",
                                        properties = {
                                            name = {["type"] = "string"},
                                            signature = {["type"] = "string"},
                                            shortHelp = {["type"] = "string"},
                                        },
                                    },
                                },
                            },
                        },
                    },
                    command = {
                        ["type"] = "object",
                        description = "The named command, when one was named.",
                    },
                },
            },
            run = function(values: {string: any}): Result
                local wanted <const> = values.command as string
                if wanted ~= nil then
                    local command <const> = self.byName[wanted]
                    if command == nil then
                        return {ok = false, code = "unknown_command", message = "no command named '" .. wanted .. "'"}
                    end
                    local verbs: {any} = {}
                    for _, sub in ipairs(command.subcommands or {}) do
                        verbs[#verbs + 1] = {
                            name = sub.name,
                            signature = signatureOf(command, sub),
                            shortHelp = sub.shortHelp,
                        }
                    end
                    return {
                        message = signatureOf(command, nil),
                        data = {
                            command = {
                                name = command.name,
                                section = command.section or "Custom",
                                signature = signatureOf(command, nil),
                                shortHelp = command.shortHelp,
                                description = toolDescription(command, nil),
                                arguments = answer.list(command.schema ~= nil and cmdargs.argHelp(command.schema)
                                    or {}),
                                verbs = answer.list(verbs),
                                examples = answer.list(command.examples or {}),
                            },
                        },
                    }
                end

                local sections: {any} = {}
                for _, section in ipairs(registry.SECTIONS) do
                    local listed: {any} = {}
                    for _, command in ipairs(self.list) do
                        if (command.section or "Custom") == section then
                            listed[#listed + 1] = {
                                name = command.name,
                                signature = signatureOf(command, nil),
                                shortHelp = command.shortHelp,
                            }
                        end
                    end
                    if #listed > 0 then
                        sections[#sections + 1] = {name = section, commands = listed}
                    end
                end
                return {
                    message = tostring(#self.list) .. " commands",
                    data = {sections = answer.list(sections)},
                }
            end,
        },
        {
            name = "describe",
            section = "Session",
            shortHelp = "report one command's full contract",
            agentHelp = "Reports everything one command declares: the tool each of its actions projects to, "
                .. "the input schema, the output schema, and the safety hints. "
                .. "Call it before an unfamiliar tool, or to discover a command's verbs.",
            schema = COMMAND_SCHEMA,
            examples = {"describe snapshot", "describe archetypes"},
            outputSchema = {
                ["type"] = "object",
                properties = {
                    name = {["type"] = "string"},
                    section = {["type"] = "string"},
                    examples = {["type"] = "array", items = {["type"] = "string"}},
                    action = {
                        ["type"] = "object",
                        description = "The command's own action, when it carries one.",
                    },
                    verbs = {["type"] = "array", items = {["type"] = "object"}},
                },
                required = {"name", "section"},
            },
            run = function(values: {string: any}): Result
                local wanted <const> = values.command as string
                local command <const> = self.byName[wanted]
                if command == nil then
                    return {ok = false, code = "unknown_command", message = "no command named '" .. wanted .. "'"}
                end
                local verbs: {any} = {}
                for _, sub in ipairs(command.subcommands or {}) do
                    verbs[#verbs + 1] = contractOf(command, sub)
                end
                return {
                    message = command.shortHelp,
                    data = {
                        name = command.name,
                        section = command.section or "Custom",
                        examples = answer.list(command.examples or {}),
                        action = command.run ~= nil and contractOf(command, nil) or nil,
                        verbs = answer.list(verbs),
                    },
                }
            end,
        },
        {
            name = "capabilities",
            section = "Session",
            shortHelp = "report what this session's command surface holds",
            agentHelp = "Reports how many commands and tools this session registered and which sections "
                .. "they fall into. Call it once after connecting to learn which command families apply "
                .. "before listing tools.",
            examples = {"capabilities"},
            readOnly = true,
            outputSchema = {
                ["type"] = "object",
                properties = {
                    commands = {["type"] = "integer", description = "Registered commands."},
                    tools = {["type"] = "integer", description = "Tools those commands project to."},
                    sections = {
                        ["type"] = "array",
                        items = {
                            ["type"] = "object",
                            properties = {
                                name = {["type"] = "string"},
                                commands = {["type"] = "integer"},
                            },
                        },
                    },
                },
                required = {"commands", "tools", "sections"},
            },
            run = function(_: {string: any}): Result
                local sections: {any} = {}
                for _, section in ipairs(registry.SECTIONS) do
                    local count = 0
                    for _, command in ipairs(self.list) do
                        if (command.section or "Custom") == section then
                            count = count + 1
                        end
                    end
                    if count > 0 then
                        sections[#sections + 1] = {name = section, commands = count}
                    end
                end
                return {
                    message = tostring(#self.list) .. " commands, " .. tostring(self.toolCount) .. " tools",
                    data = {commands = #self.list, tools = self.toolCount, sections = answer.list(sections)},
                }
            end,
        },
    }
end

--- Builds an empty registry for one world, carrying only the commands that
--- answer for the registry itself.
---
--- @param world The caller supplies the world every command will read.
--- @return A registry with `help`, `describe` and `capabilities` registered.
function registry.new(world: types.World): registry.Registry
    local self <const> = setmetatable(
        {
            world = world,
            list = {},
            byName = {},
            names = {},
            toolCount = 0,
        } as registry.Registry,
        RegistryMT
    )

    for _, command in ipairs(discovery(self)) do
        self:add(command)
    end
    return self
end

return registry
