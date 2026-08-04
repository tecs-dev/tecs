-- The Capture-section commands: what a session takes out of a running process
-- so that it can be read, compared or replayed later.
--
-- `snapshot` moves the whole world to a file and back, and `profile` samples
-- where the process spends its time. Both write under the writable root, so an
-- agent that shares a filesystem with the game opens the artifact directly
-- rather than carrying it through the protocol.

local profile <const> = require("tecs.utils.profile")
local type debugtypes = require("tecs.debug.internal.types")
local type cmdargs = require("tecs.debug.internal.cmdargs")

local type Command = debugtypes.Command
local type Result = debugtypes.Result

local record capture
    --- The Capture-section commands, in the order they are presented.
    ---
    --- @param env The caller supplies the world every command reads and writes.
    --- @return A fresh list the caller owns, each command closing over
    ---     `env.world` and none of them registered yet.
    commands: function(env: debugtypes.Env): {debugtypes.Command}
end

-- `tecs.utils.profile` allows one sample session per process rather than one
-- per world, so the handle on it is a module local rather than a closure over
-- the world. A second `profile.sample` raises, and `profile start` answers
-- `already_running` before it can.
local sampleSession: profile.SampleSession = nil

local SNAPSHOT_SAVE_SCHEMA <const>: cmdargs.Schema = {
    args = {
        name = {
            default = "snapshot.bin",
            help = "Names the file under the writable root that receives the snapshot.",
        },
    },
    positional = {"name"},
}

local SNAPSHOT_LOAD_SCHEMA <const>: cmdargs.Schema = {
    args = {
        path = {
            required = true,
            help = "Locates the binary snapshot to restore, as an absolute path such as the one "
                .. "`snapshot save` reports.",
        },
    },
    positional = {"path"},
}

local PROFILE_START_SCHEMA <const>: cmdargs.Schema = {
    args = {
        intervalMs = {
            kind = "number",
            min = 1,
            help = "Sets the sampler interval in milliseconds, defaulting to 10. Below 10 the timer "
                .. "starts taking real time from the main thread.",
        },
        zone = {
            help = "Keeps only the samples whose zone path starts with this prefix, such as "
                .. "`afterFixed/Render` or `afterFixed/Render:SpriteSync`.",
        },
    },
    positional = {"intervalMs"},
}

local PROFILE_STOP_SCHEMA <const>: cmdargs.Schema = {
    args = {
        name = {
            default = "profile.collapsed",
            help = "Names the file under the writable root that receives the collapsed-stack text.",
        },
    },
    positional = {"name"},
}

--- Counts the lines of collapsed-stack text one sample session produced.
---
--- The encoder writes no trailing newline and answers with the empty string
--- when nothing was sampled, so the count is one more than the newlines except
--- when there is no text at all.
local function countLines(text: string): integer
    if text == "" then
        return 0
    end
    local _, newlines <const> = text:gsub("\n", "")
    return newlines + 1
end

function capture.commands(env: debugtypes.Env): {Command}
    local w <const> = env.world

    return {
        {
            name = "snapshot",
            section = "Capture",
            shortHelp = "save and restore the whole world",
            agentHelp = "Writes the world to a binary file, and restores a world from one. Call save "
                .. "before an experiment and load to get back to where you were, or save at two moments "
                .. "and compare the files. Both verbs raise while a world update is suspended, because a "
                .. "half-committed update is not state a snapshot can carry.",
            examples = {"snapshot save", "snapshot save boss-fight.bin", "snapshot load /tmp/boss-fight.bin"},
            subcommands = {
                {
                    name = "save",
                    shortHelp = "write the world to a binary snapshot file",
                    agentHelp = "Writes every non-transient component of every entity to a binary file "
                        .. "under the writable root and answers with its absolute path, which is what "
                        .. "`snapshot load` takes back. It does not disturb the running game. Reusing a "
                        .. "name overwrites that file, so name each save you mean to keep.",
                    schema = SNAPSHOT_SAVE_SCHEMA,
                    examples = {"snapshot save", "snapshot save boss-fight.bin", "snapshot save name=wave3.bin"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            path = {
                                ["type"] = "string",
                                description = "The absolute path the snapshot was written to.",
                            },
                            format = {
                                ["type"] = "string",
                                description = "The representation on disk, which is always `binary`.",
                            },
                            bytes = {
                                ["type"] = "integer",
                                description = "The size of the written file, and absent when the platform "
                                    .. "declined to report it.",
                            },
                        },
                        required = {"path", "format"},
                    },
                    run = function(values: {string: any}): Result
                        -- Required here rather than at the top of the module.
                        -- Every session builds this command group, including a
                        -- headless one, while `tecs.io.files` resolves its
                        -- storage backend through the FFI at require time.
                        local files <const> = require("tecs.io.files")
                        local path <const> = files.writablePath(values.name as string)
                        w:saveSnapshot({format = "binary", path = path})

                        local data: {string: any} = {path = path, format = "binary"}
                        -- The writer reports no length, so the size comes from
                        -- the file itself and is left out when the platform
                        -- cannot answer for it rather than guessed at.
                        local info <const> = files.info(path)
                        if info ~= nil then
                            data.bytes = info.size
                        end
                        return {message = "snapshot written to " .. path, data = data}
                    end,
                },
                {
                    name = "load",
                    shortHelp = "replace the world with a saved snapshot",
                    agentHelp = "Despawns every entity in the world and restores the ones the file holds, "
                        .. "so the world it replaces is gone and anything holding an entity id from before "
                        .. "the load is stale. Answers with the snapshot's format version and the counts it "
                        .. "declared. Call snapshot save first if the current world is worth keeping.",
                    schema = SNAPSHOT_LOAD_SCHEMA,
                    examples = {"snapshot load /tmp/boss-fight.bin", "snapshot load path=/tmp/wave3.bin"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            path = {["type"] = "string", description = "Echoes the path that was read."},
                            bytes = {["type"] = "integer", description = "The size of the file that was read."},
                            version = {
                                ["type"] = "integer",
                                description = "The snapshot format version, which is not a game version.",
                            },
                            entities = {
                                ["type"] = "integer",
                                description = "The entities the snapshot declared, and absent when its "
                                    .. "writer did not count them.",
                            },
                            archetypes = {
                                ["type"] = "integer",
                                description = "The archetypes the snapshot declared, and absent when its "
                                    .. "writer did not count them.",
                            },
                        },
                        required = {"path", "bytes", "version"},
                    },
                    run = function(values: {string: any}): Result
                        -- Lazy for the reason `snapshot save` gives.
                        local files <const> = require("tecs.io.files")
                        local path <const> = values.path as string
                        local bytes <const> = files.read(path)
                        if bytes == nil then
                            return {
                                ok = false,
                                code = "read_failed",
                                message = "cannot read '" .. path .. "'",
                            }
                        end

                        local prelude <const> = w:loadSnapshot(bytes)
                        return {
                            message = "world replaced from " .. path,
                            data = {
                                path = path,
                                bytes = #bytes,
                                version = prelude.version,
                                entities = prelude.entityCount,
                                archetypes = prelude.archetypeCount,
                            },
                        }
                    end,
                },
            },
        },
        {
            name = "profile",
            section = "Capture",
            shortHelp = "sample where the running process spends its time",
            agentHelp = "Runs the LuaJIT sampling profiler over the running game and writes collapsed-stack "
                .. "text, which speedscope and flamegraph read directly. Per-system attribution comes from "
                .. "zone names shaped `<span>/<Phase>:<system>`, such as `afterFixed/Render:SpriteSync`, and "
                .. "`zone` filters on that prefix. Start it, let the game run, then stop it.",
            examples = {"profile start", "profile start 5 zone=afterFixed", "profile stop slow-frame.collapsed"},
            subcommands = {
                {
                    name = "start",
                    shortHelp = "begin sampling the running process",
                    agentHelp = "Starts the sampler and answers with the settings it is running under. One "
                        .. "session runs at a time per process, so a second call answers `already_running`. "
                        .. "The `zone` prefix is fixed at start and cannot be widened afterwards. Sampling "
                        .. "costs on every tick, so call profile stop once the question is answered.",
                    schema = PROFILE_START_SCHEMA,
                    examples = {"profile start", "profile start 5", "profile start intervalMs=5 zone=afterFixed"},
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            intervalMs = {
                                ["type"] = "integer",
                                description = "The sampler interval the session is running at.",
                            },
                            zone = {
                                ["type"] = "string",
                                description = "The zone prefix the session keeps, and absent when it keeps "
                                    .. "every zone.",
                            },
                        },
                        required = {"intervalMs"},
                    },
                    run = function(values: {string: any}): Result
                        if sampleSession ~= nil then
                            return {
                                ok = false,
                                code = "already_running",
                                message = "a sample session is already running; call `profile stop` first",
                            }
                        end

                        local options: profile.SampleOptions = {}
                        if values.intervalMs ~= nil then
                            options.intervalMs = math.floor(values.intervalMs as number) as integer
                        end
                        if values.zone ~= nil then
                            options.zone = values.zone as string
                        end
                        sampleSession = profile.sample(options)

                        local interval <const> = options.intervalMs or 10
                        return {
                            message = "sampling every " .. tostring(interval) .. " ms",
                            data = {intervalMs = interval, zone = options.zone},
                        }
                    end,
                },
                {
                    name = "stop",
                    shortHelp = "end sampling and write the collapsed stacks",
                    agentHelp = "Stops the session, writes its collapsed-stack text under the writable root "
                        .. "and answers with the path, the byte count and the line count, one line per "
                        .. "distinct stack. Open the file in speedscope or feed it to flamegraph. A session "
                        .. "that sampled nothing writes an empty file and reports zero lines.",
                    schema = PROFILE_STOP_SCHEMA,
                    examples = {
                        "profile stop", "profile stop slow-frame.collapsed", "profile stop name=wave3.collapsed"
                    },
                    outputSchema = {
                        ["type"] = "object",
                        properties = {
                            path = {
                                ["type"] = "string",
                                description = "The absolute path the collapsed-stack text was written to.",
                            },
                            bytes = {["type"] = "integer", description = "The size of the written text."},
                            lines = {
                                ["type"] = "integer",
                                description = "The distinct stacks the session recorded, one per line.",
                            },
                        },
                        required = {"path", "bytes", "lines"},
                    },
                    run = function(values: {string: any}): Result
                        if sampleSession == nil then
                            return {
                                ok = false,
                                code = "not_running",
                                message = "no sample session is running; call `profile start` first",
                            }
                        end

                        -- Lazy for the reason `snapshot save` gives.
                        local files <const> = require("tecs.io.files")
                        local path <const> = files.writablePath(values.name as string)
                        -- Released before the stop rather than after it. The
                        -- session ends whatever the write does, and a write that
                        -- raises would otherwise strand a handle that can never
                        -- be stopped again.
                        local session <const> = sampleSession
                        sampleSession = nil

                        local text <const> = session:stop(path)
                        return {
                            message = "profile written to " .. path,
                            data = {path = path, bytes = #text, lines = countLines(text)},
                        }
                    end,
                },
            },
        },
    }
end

return capture
