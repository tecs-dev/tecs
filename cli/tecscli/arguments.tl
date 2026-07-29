--- Command-line parsing through the Rust Clap schema.
---
--- Clap owns the grammar, validation, help and diagnostics. Lua keeps the
--- command implementations: Rust answers either one normalized command to run
--- or one complete message and exit status to return.
---
--- The boundary is a NUL-separated byte buffer rather than a Rust struct.
--- Neither language has to agree on enum layout, padding or ownership, and the
--- existing `TecsBytes` destructor keeps the allocation on the side that made
--- it. Command arguments cannot contain NUL at the operating-system boundary,
--- so every other byte in a path survives the round trip.

local ffi <const> = require("ffi")
local loader <const> = require("tecs.ffi.loader")

loader.declare("rust")

local C <const> = loader.library("tecs_native", "tecs-native", "TECS_RUST_PATH", "rust")
local parseNative <const> = C.tecsCliParse as function(integer, any): loader.CValue
local docsNative <const> = C.tecsCliDocs as function(string, any): loader.CValue
local bytesData <const> = C.tecsBytesData as function(loader.CValue): loader.CValue
local bytesLength <const> = C.tecsBytesLength as function(loader.CValue): any
local bytesDestroy <const> = C.tecsBytesDestroy as function(loader.CValue)
local rustError <const> = C.tecsRustError as function(): loader.CValue
local runMcp <const> = C.tecsCliMcp as function(): integer

local record arguments
    record Invocation
        --- `run` for a normalized command and `exit` for Clap output.
        kind: string
        --- The command name when `kind` is `run`.
        command: string
        --- Normalized operands and flags for the command implementation.
        values: {string}
        --- Process status when `kind` is `exit`.
        code: integer
        --- Complete text to write before exiting.
        output: string
        --- Whether `output` belongs on standard error.
        stderr: boolean
    end
end

--- Copies Lua strings into a C argv for the duration of one Rust call.
local function nativeArguments(raw: {string}): any, {any}
    local count <const> = #raw
    if count == 0 then
        return nil, {}
    end

    local argv = ffi.new("const char *[?]", count) as {integer: any}
    local held: {any} = {}
    for index = 1, count do
        held[index] = ffi.new("char[?]", #raw[index] + 1)
        ffi.copy(held[index] as string, raw[index])
        argv[index - 1] = held[index]
    end
    return argv, held
end

--- Splits the wire result, which always includes its final separator.
local function fieldsOf(encoded: string): {string}
    local fields: {string} = {}
    local at = 1
    while at <= #encoded do
        local stop = encoded:find("\0", at, true)
        if stop == nil then
            error("tecs: Rust returned a malformed command result")
        end
        fields[#fields + 1] = encoded:sub(at, stop - 1)
        at = stop + 1
    end
    return fields
end

--- Decodes one result from the Rust CLI boundary.
local function invocationOf(result: loader.CValue): arguments.Invocation
    if result == nil then
        error(("tecs: cannot run command: %s"):format(loader.toString(rustError())))
    end

    local length <const> = tonumber(bytesLength(result)) as integer
    local encoded <const> = loader.toBytes(bytesData(result), length)
    bytesDestroy(result)

    local fields <const> = fieldsOf(encoded)
    if fields[1] == "run" and fields[2] ~= nil then
        local values: {string} = {}
        for index = 3, #fields do
            values[#values + 1] = fields[index]
        end
        return {
            kind = "run",
            command = fields[2],
            values = values,
            code = 0,
            output = "",
            stderr = false,
        }
    end
    if fields[1] == "exit" and fields[2] ~= nil and fields[3] ~= nil and fields[4] ~= nil then
        return {
            kind = "exit",
            command = "",
            values = {},
            code = math.floor(tonumber(fields[2]) or 1),
            output = fields[4],
            stderr = fields[3] == "stderr",
        }
    end
    error("tecs: Rust returned an unknown command result")
end

--- Parses the arguments after the executable and host-only `--entry` pair.
function arguments.parse(raw: {string}): arguments.Invocation
    local argv, held = nativeArguments(raw)
    local result = parseNative(#raw, argv)
    -- Keep the backing strings live across the FFI call.
    local _ <const> = held
    return invocationOf(result)
end

--- Searches the reference staged with the CLI.
---
--- Rust reads and renders Markdown because it already owns the command
--- grammar and can unit-test matching without booting an SDL host.
function arguments.docs(root: string, query?: string): arguments.Invocation
    return invocationOf(docsNative(root .. "/tecsdocs", query))
end

--- Runs the blocking stdio-to-game MCP bridge.
---
--- Standard output belongs exclusively to the protocol until this returns.
--- Diagnostics go to standard error inside Rust, so an agent never mistakes a
--- discovery message for JSON-RPC.
function arguments.runMcp(): integer
    return runMcp()
end

return arguments
