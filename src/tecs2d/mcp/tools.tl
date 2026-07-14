local json <const> = require("tecs.utils.json")

--- Kernel MCP tool definitions: the transport-level tools the server always
--- exposes. Everything else is projected from the debugger command registry
--- as cmd_* tools (see tecs2d.debug.commands); cmd_capabilities is the
--- discovery entry point for that surface.
local record tools
    record Schema
        type: string
        properties: {string: Schema}
        items: Schema
        required: {string}
        additionalProperties: boolean
        description: string
    end

    --- MCP safety hints, declared explicitly because the protocol's
    --- defaults are pessimistic. A closed record so a typo'd hint key
    --- fails typecheck.
    record Annotations
        readOnlyHint: boolean
        destructiveHint: boolean
        idempotentHint: boolean
        openWorldHint: boolean
    end

    record Tool
        name: string
        description: string
        inputSchema: Schema
        annotations: Annotations
    end

    list: {Tool}

    --- Serialize tools list to JSON string (for bridge)
    toJSON: function(): string
end

-- json.EMPTY_OBJECT keeps empty schema tables serializing as {} rather than [].
local EMPTY_SCHEMA: tools.Schema = {
    type = "object",
    properties = json.EMPTY_OBJECT as {string: tools.Schema},
    additionalProperties = false
}

local JSON_TEXT_RESPONSE <const> = " Returns compact JSON text envelope."

tools.list = {
    {
        name = "ping",
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Check if the game is running. Call cmd_capabilities next to discover what the " ..
            "session's cmd_* command tools support." .. JSON_TEXT_RESPONSE,
        inputSchema = EMPTY_SCHEMA
    },
    {
        name = "screenshot",
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Capture a screenshot of the game window and return it inline as MCP image content, " ..
            "in one call. With filesystem access to the game host, cmd_screenshot is usually better: it " ..
            "writes a persistent session artifact instead of a base64 payload (the capture lands at end " ..
            "of frame; poll cmd_screenshot_info before reading the file).",
        inputSchema = {
            type = "object",
            properties = {
                x = {type = "number", description = "Optional X coordinate for region capture"},
                y = {type = "number", description = "Optional Y coordinate for region capture"},
                width = {type = "number", description = "Optional width for region capture"},
                height = {type = "number", description = "Optional height for region capture"}
            },
            additionalProperties = false
        }
    },
    {
        name = "sample_pixels",
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Sample framebuffer pixel colors at one or more points without transferring a " ..
            "full screenshot. Returns RGBA floats in 0..1 per point plus the framebuffer size." ..
            JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                points = {
                    type = "array",
                    description = "Points to sample, each an object with x and y. " ..
                        "Pixel coordinates by default; out-of-range points are clamped.",
                    items = {
                        type = "object",
                        properties = {
                            x = {type = "number", description = "X coordinate"},
                            y = {type = "number", description = "Y coordinate"}
                        },
                        required = {"x", "y"},
                        additionalProperties = false
                    }
                },
                normalized = {
                    type = "boolean",
                    description = "When true, x and y are 0..1 fractions of the framebuffer size " ..
                        "instead of pixel coordinates (resolution-independent)."
                }
            },
            required = {"points"},
            additionalProperties = false
        }
    },
    {
        name = "send_love_event",
        annotations = {readOnlyHint = false, destructiveHint = false, idempotentHint = false, openWorldHint = false},
        description = "Send a Love2D event to the game." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                event = {
                    type = "string",
                    description = "Event name: keypressed, keyreleased, mousepressed, " ..
                        "mousereleased, mousemoved, wheelmoved, resize, focus"
                },
                args = {
                    type = "array",
                    description = "Event arguments. Mixed types allowed; each item is " ..
                        "passed through to love.event.push() with its original type so events " ..
                        "like resize/mousepressed/wheelmoved receive numbers, focus receives booleans, etc.",
                    -- No `type` on items means "any JSON type" per JSON Schema.
                    items = json.EMPTY_OBJECT as tools.Schema
                }
            },
            required = {"event"},
            additionalProperties = false
        }
    },
    {
        name = "run_lua",
        annotations = {readOnlyHint = false, destructiveHint = true, idempotentHint = false, openWorldHint = false},
        description = "Run Lua code in the game. " ..
            "Code is wrapped in function(world) ... end automatically. " ..
            "The result is an envelope {returned: <count>, values: [...]}: values holds your " ..
            "return values in order, so `return snake.length` reads back as values[0]. " ..
            "Return values are serialized as JSON by default -- return a table (e.g. " ..
            "{count = ..., score = ...}) for a structured, cheap read; pass lua=true for the raw " ..
            "Lua tostring form instead. " ..
            "The code is sandboxed: love2d APIs and the ECS world are available, but the " ..
            "filesystem (io, os.execute) and module loading (require, load, dofile) are not. " ..
            "Use 'world' directly to access the ECS world. Prefer the structured cmd_* " ..
            "command tools (cmd_fetch, cmd_set, cmd_spawn, ...) when one covers the operation." ..
            JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                code = {type = "string", description = "Lua code to execute with 'world' in scope"},
                lua = {type = "boolean",
                    description = "Return values as Lua tostring strings instead of JSON (default false)"}
            },
            required = {"code"},
            additionalProperties = false
        }
    },
    {
        name = "get_logs",
        annotations = {readOnlyHint = true, destructiveHint = false, idempotentHint = true, openWorldHint = false},
        description = "Read recent engine log lines captured from tecs logging (ring of 500), including the " ..
            "tecs2d.debug.events operator-action feed. Each line carries a monotonic seq; poll incrementally " ..
            "with after=<last seen seq> (result.latest). Filter by minimum level or substring; newest last. " ..
            "Pass clear=true to empty the buffer." .. JSON_TEXT_RESPONSE,
        inputSchema = {
            type = "object",
            properties = {
                level = {type = "string", description = "Minimum severity: DEBUG, INFO, WARN, or ERROR"},
                contains = {type = "string", description = "Only lines whose message or logger contains this text"},
                after = {type = "number", description = "Only lines with seq greater than this (cursor; default 0)"},
                limit = {type = "number", description = "Max lines to return, newest last (default 50)"},
                clear = {type = "boolean", description = "Clear the captured buffer instead of reading"}
            },
            additionalProperties = false
        }
    }
}

function tools.toJSON(): string
    return json.serialize(tools.list)
end

return tools
