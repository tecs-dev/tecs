-- The record types a command is declared with, in a leaf module.
--
-- The registry re-exports these names on the public record, and every command
-- group depends on this module rather than on the registry. Teal refuses a
-- require cycle even through a type-only require, so the types a group and the
-- registry both name have to sit below both.

local type types = require("tecs.types")
local type cmdargs = require("tecs.debug.internal.cmdargs")
-- Type only, and it has to stay that way. Requiring the renderer for real would
-- reach the FFI as this module loads, and a headless session declares commands
-- without a graphics stack behind them.
local type Renderer = require("tecs.Renderer")

local record debugtypes
    --- Reports what one command did.
    record Result
        --- Caller-writable. Reports whether the command did what it was asked.
        --- Omitted counts as success. False raises the command's message
        --- through the tool call rather than answering with it.
        ok: boolean

        --- Caller-writable. Names the failure in a word an agent can match on,
        --- such as `no_match` or `invalid_ref`. Required when `ok` is false and
        --- ignored otherwise.
        code: string

        --- Caller-writable. Summarizes the outcome for a person in one line.
        --- A successful command carries it beside its data under the key
        --- `message`.
        message: string

        --- Caller-writable. Carries the structured answer, which is what the
        --- tool call returns and what `outputSchema` describes. Omitted answers
        --- with the message alone.
        data: {string: any}
    end

    --- Declares one verb under a command, as `snapshot save` declares `save`.
    record Subcommand
        --- Caller-writable. Names the verb. The projected tool is
        --- `<command>_<name>`, so this string is part of an externally typed
        --- surface once it ships. Required.
        name: string

        --- Caller-writable. Names other spellings that dispatch to this verb on
        --- a typed command line. Aliases are never projected as tools.
        aliases: {string}

        --- Caller-writable. Says what the verb does in one line, lowercase and
        --- without a trailing period. Required.
        shortHelp: string

        --- Caller-writable. Says what an agent needs: when to call this, what
        --- it changes, what it answers with, and what to call next. The
        --- projected tool description falls back to `shortHelp`, which is
        --- written to fit one line rather than to brief an agent.
        agentHelp: string

        --- Caller-writable. Declares the arguments. Omitted means the verb
        --- takes none.
        schema: cmdargs.Schema

        --- Caller-writable. Shows complete command lines that work, for the
        --- generated reference and the usage output.
        examples: {string}

        --- Caller-writable. Describes `Result.data` as a JSON Schema. The
        --- projection advertises it as the tool's `outputSchema`, so an agent
        --- knows the shape of the answer before making the call.
        outputSchema: {string: any}

        --- Caller-writable. Declares that the verb only reads. Omitted derives
        --- the answer from the verb: `list`, `info`, `status` and `get` read.
        readOnly: boolean

        --- Caller-writable. Declares that the verb destroys something a caller
        --- cannot get back. Omitted derives the answer from the verb.
        destructive: boolean

        --- Caller-writable. Runs the verb. Required.
        run: function(values: {string: any}): Result
    end

    --- Declares one command.
    record Command
        --- Caller-writable. Names the command, and names the tool it projects
        --- to. Whitespace is refused. Required.
        name: string

        --- Caller-writable. Names other spellings that dispatch to this command
        --- on a typed command line. Aliases are never projected as tools.
        aliases: {string}

        --- Caller-writable. Says what the command does in one line, lowercase
        --- and without a trailing period. Required.
        shortHelp: string

        --- Caller-writable. Says what an agent needs. See
        --- [`Subcommand.agentHelp`](tealdoc:tecs.debug.Subcommand.agentHelp).
        agentHelp: string

        --- Caller-writable. Declares the arguments of the command's own action.
        schema: cmdargs.Schema

        --- Caller-writable. Declares the verbs under this command. A command
        --- with verbs may still carry `run`, which answers when the first word
        --- matches no verb.
        subcommands: {Subcommand}

        --- Caller-writable. Shows complete command lines that work.
        examples: {string}

        --- Caller-writable. Describes `Result.data` as a JSON Schema.
        outputSchema: {string: any}

        --- Caller-writable. Declares that the command only reads.
        readOnly: boolean

        --- Caller-writable. Declares that the command destroys something.
        --- Omitted derives the answer from the name.
        destructive: boolean

        --- Caller-writable. Groups the command in help and in the generated
        --- reference, as one of
        --- [`tecs.debug.SECTIONS`](tealdoc:tecs.debug.SECTIONS). Omitted groups
        --- as `"Custom"`, which is where a game's own commands belong.
        section: string

        --- Caller-writable. Runs the command's own action. Required unless the
        --- command declares `subcommands`, in which case a command with no
        --- action projects no bare tool.
        run: function(values: {string: any}): Result
    end

    --- Carries what a command group receives when it is built.
    record Env
        --- Read-only. Reports the world the commands read and write.
        world: types.World

        --- Read-only. Answers with the renderer drawing this world, or nil
        --- where nothing bound one.
        ---
        --- A function rather than a field because a renderer is bound after the
        --- commands are built: an application opens its window and creates its
        --- device well after the world exists, and a headless session never
        --- binds one at all.
        renderer: function(): Renderer
    end
end

return debugtypes
