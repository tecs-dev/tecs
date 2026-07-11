--- Generic argument grammar for debugger commands. Each command declares a
--- schema; this module tokenizes, parses (positional or name=value, quoted),
--- validates, and generates help text, so no command parses its own arguments.
--- The same schema also projects to the MCP surface: toolSchema() emits a JSON
--- Schema for the tool listing and parseValues() validates a JSON argument
--- object, so one declaration drives both the command line and the agent.
---
--- Schema:
---   args: name -> {required, default, help, forward, synthetic, kind, rest}
---     default   : also declares the value type (number / boolean / string).
---     forward   : name of a synthetic arg this arg feeds its value into.
---     synthetic : source arg names; presence marks this arg synthetic (hidden).
---                 A synthetic's value comes from a positional slot or a forward.
---     rest      : the arg captures the remainder of the line as free text; it
---                 must be the last positional slot and string-typed.
---   positional: ordered arg names bound by position (may be synthetic).
---
--- Forwarding must be reciprocal: if a.forward == s then s must be synthetic and
--- list a in s.synthetic, and vice versa. validate() asserts this.

local json <const> = require("tecs.utils.json")

local record cmdargs
    record ArgSpec
        required: boolean
        default: any
        help: string
        forward: string
        synthetic: {string}
        -- Explicit value type ("number" / "boolean" / "string" / "list" /
        -- "table"). When omitted it is inferred from `default`. Set it for an
        -- optional typed arg that has no default, e.g. a number that defaults
        -- to nil (leave unchanged). A "list" is a comma-separated string on
        -- the command line and a JSON string array over MCP; a "table" is a
        -- brace-balanced Lua expression on the command line and a JSON object
        -- over MCP (actions receive a string or a table and handle both).
        kind: string
        -- Allowed values for a string arg; projected as a JSON Schema enum.
        enum: {string}
        -- Inclusive bounds for a number arg.
        min: number
        max: number
        -- Free-text tail: the slot consumes every remaining token, joined with
        -- single spaces (quoted spans keep their inner spacing).
        rest: boolean
    end

    record Schema
        args: {string: ArgSpec}
        positional: {string}
    end

    --- Assert the schema is internally consistent. Raises on a mistake, since a
    --- bad schema is a programming error, not user input.
    validate: function(schema: Schema)

    --- Split a command line into tokens, honoring single/double quotes so a value
    --- may contain spaces or other characters. Returns tokens, or nil + error.
    tokenize: function(text: string): {string}, string

    --- Parse argument tokens into a name -> value map (defaults applied). Returns
    --- values, or nil + an error message for malformed input.
    parse: function(schema: Schema, tokens: {string}): {string: any}, string

    --- Validate an already-typed argument object (e.g. decoded MCP JSON) against
    --- the schema: type-checks each named value, applies forwarding, synthetic
    --- resolution, defaults, and required checks. Returns values, or nil + error.
    parseValues: function(schema: Schema, given: {string: any}): {string: any}, string

    --- Project the schema to a JSON Schema object for an MCP tool listing.
    --- Synthetic args are hidden; their sources carry a "provide exactly one
    --- of ..." note. Returns a plain table shaped like an MCP inputSchema.
    toolSchema: function(schema: Schema): {string: any}

    --- The positional signature, e.g. "<name|id> [seconds]".
    signature: function(schema: Schema): string

    --- Tab-aligned per-argument help lines (name, help, default).
    argHelp: function(schema: Schema): {string}
end

local function argType(spec: cmdargs.ArgSpec): string
    if spec.kind then return spec.kind end
    local d = spec.default
    if type(d) == "number" then return "number" end
    if type(d) == "boolean" then return "boolean" end
    return "string"
end

local function isSynthetic(spec: cmdargs.ArgSpec): boolean
    return spec.synthetic ~= nil
end

local function parseBool(raw: string): boolean, boolean
    if raw == "1" or raw == "true" or raw == "on" or raw == "yes" then return true, true end
    if raw == "0" or raw == "false" or raw == "off" or raw == "no" then return false, true end
    return false, false
end

-- Value constraints shared by both parse paths: enum membership for strings
-- and inclusive bounds for numbers.
local function checkConstraints(name: string, spec: cmdargs.ArgSpec, value: any): string
    if spec.enum and type(value) == "string" then
        for _, allowed in ipairs(spec.enum) do
            if value == allowed then return nil end
        end
        return name .. " must be one of " .. table.concat(spec.enum, ", ")
    end
    if type(value) == "number" then
        if spec.min and (value as number) < spec.min then
            return name .. " must be at least " .. tostring(spec.min)
        end
        if spec.max and (value as number) > spec.max then
            return name .. " must be at most " .. tostring(spec.max)
        end
    end
    return nil
end

-- Convert a raw token to the arg's value type, or return nil + error.
local function coerce(name: string, spec: cmdargs.ArgSpec, raw: string): any, string
    local t = argType(spec)
    local value: any = raw
    if t == "number" then
        local n = tonumber(raw)
        if not n then return nil, name .. " must be a number, got '" .. raw .. "'" end
        value = n
    elseif t == "boolean" then
        local b, ok = parseBool(raw)
        if not ok then return nil, name .. " must be true or false, got '" .. raw .. "'" end
        value = b
    elseif t == "list" then
        local items: {string} = {}
        for item in raw:gmatch("[^,]+") do
            items[#items + 1] = item
        end
        value = items
    end
    -- A "table" stays the raw brace expression; the action parses it.
    local cerr = checkConstraints(name, spec, value)
    if cerr then return nil, cerr end
    return value
end

function cmdargs.validate(schema: cmdargs.Schema)
    local args = schema.args
    for name, spec in pairs(args) do
        if spec.rest then
            if argType(spec) ~= "string" and argType(spec) ~= "table" then
                error("cmdargs: rest arg '" .. name .. "' must be string-typed")
            end
            if isSynthetic(spec) or spec.forward then
                error("cmdargs: rest arg '" .. name .. "' cannot be synthetic or forward")
            end
            if schema.positional[#schema.positional] ~= name then
                error("cmdargs: rest arg '" .. name .. "' must be the last positional slot")
            end
        end
        if spec.forward then
            local target = args[spec.forward]
            if not target then
                error("cmdargs: '" .. name .. "' forwards to unknown arg '" .. spec.forward .. "'")
            end
            if not isSynthetic(target) then
                error("cmdargs: '" .. name .. "' forwards to non-synthetic arg '" .. spec.forward .. "'")
            end
            local found = false
            for _, src in ipairs(target.synthetic) do
                if src == name then found = true end
            end
            if not found then
                error("cmdargs: '" .. spec.forward .. "'.synthetic is missing the reciprocal edge for '" .. name .. "'")
            end
        end
        if spec.synthetic then
            for _, src in ipairs(spec.synthetic) do
                local srcSpec = args[src]
                if not srcSpec then
                    error("cmdargs: synthetic '" .. name .. "' names unknown source '" .. src .. "'")
                end
                if srcSpec.forward ~= name then
                    error("cmdargs: source '" .. src .. "' does not forward back to synthetic '" .. name .. "'")
                end
            end
        end
    end
    for _, slot in ipairs(schema.positional) do
        if not args[slot] then
            error("cmdargs: positional slot '" .. slot .. "' is not a declared arg")
        end
    end
end

function cmdargs.tokenize(text: string): {string}, string
    local tokens: {string} = {}
    local i = 1
    local n = #text
    while i <= n do
        while i <= n and text:sub(i, i):match("%s") do
            i = i + 1
        end
        if i > n then break end
        local buf: {string} = {}
        while i <= n and not text:sub(i, i):match("%s") do
            local c = text:sub(i, i)
            if c == '"' or c == "'" then
                local close = text:find(c, i + 1, true)
                if not close then
                    return nil, "unterminated " .. c .. " quote"
                end
                buf[#buf + 1] = text:sub(i + 1, close - 1)
                i = close + 1
            elseif c == "{" then
                -- A balanced {...} span is one token, kept verbatim (braces
                -- included, inner spaces preserved) so Lua table expressions
                -- pass through, e.g. `set 5 Transform {x = 10, y = 20}`.
                -- Quotes inside the span may contain unbalanced braces.
                local depth = 0
                local j = i
                while j <= n do
                    local cc = text:sub(j, j)
                    if cc == '"' or cc == "'" then
                        local close = text:find(cc, j + 1, true)
                        if not close then
                            return nil, "unterminated " .. cc .. " quote"
                        end
                        j = close
                    elseif cc == "{" then
                        depth = depth + 1
                    elseif cc == "}" then
                        depth = depth - 1
                        if depth == 0 then break end
                    end
                    j = j + 1
                end
                if depth ~= 0 or j > n then
                    return nil, "unterminated { expression"
                end
                buf[#buf + 1] = text:sub(i, j)
                i = j + 1
            else
                buf[#buf + 1] = c
                i = i + 1
            end
        end
        tokens[#tokens + 1] = table.concat(buf)
    end
    return tokens, nil
end

-- Bind a positional value to a synthetic slot by resolving which source it fits:
-- typed sources (number/boolean) are tried before string sources, so "5" binds
-- to a numeric id and "foo" falls through to a string name.
local function resolveSynthetic(args: {string: cmdargs.ArgSpec}, spec: cmdargs.ArgSpec, raw: string): string, any, string
    local typed: {string} = {}
    local strings: {string} = {}
    for _, src in ipairs(spec.synthetic) do
        if argType(args[src]) == "string" then
            strings[#strings + 1] = src
        else
            typed[#typed + 1] = src
        end
    end
    for _, src in ipairs(typed) do
        local v = coerce(src, args[src], raw)
        if v ~= nil then return src, v end
    end
    for _, src in ipairs(strings) do
        return src, raw
    end
    return nil, nil, "invalid value '" .. raw .. "'"
end

function cmdargs.parse(schema: cmdargs.Schema, tokens: {string}): {string: any}, string
    local args = schema.args
    local values: {string: any} = {}
    local sawNamed = false
    local posIndex = 1

    local function forwardValue(name: string, value: any): string
        local spec = args[name]
        values[name] = value
        if spec.forward then
            if values[spec.forward] ~= nil then
                return "conflicting arguments for '" .. spec.forward .. "'"
            end
            values[spec.forward] = value
        end
        return nil
    end

    local i = 1
    local n = #tokens
    while i <= n do
        local tok = tokens[i]
        local key, val = tok:match("^(%w+)=(.*)$")
        if key then
            sawNamed = true
            local spec = args[key]
            if not spec or isSynthetic(spec) then
                return nil, "unknown argument '" .. key .. "'"
            end
            local v, err = coerce(key, spec, val)
            if err then return nil, err end
            local ferr = forwardValue(key, v)
            if ferr then return nil, ferr end
        elseif args[tok] and not isSynthetic(args[tok]) and argType(args[tok]) == "boolean" then
            sawNamed = true
            local ferr = forwardValue(tok, true)
            if ferr then return nil, ferr end
        elseif sawNamed then
            return nil, "positional argument '" .. tok .. "' after a named argument"
        else
            local slot = schema.positional[posIndex]
            if not slot then
                return nil, "unexpected argument '" .. tok .. "'"
            end
            posIndex = posIndex + 1
            local spec = args[slot]
            if spec.rest then
                -- Free-text tail: remaining tokens joined with single spaces.
                -- Tokens naming a declared arg (key=value, or a bare boolean
                -- flag) still parse as named so flags can follow the text;
                -- undeclared words stay part of it.
                local buf: {string} = {}
                while i <= n do
                    local rtok = tokens[i]
                    local rkey, rval = rtok:match("^(%w+)=(.*)$")
                    local rspec = rkey and args[rkey]
                    if rspec and not isSynthetic(rspec) and not rspec.rest then
                        local rv, rerr = coerce(rkey, rspec, rval)
                        if rerr then return nil, rerr end
                        local ferr = forwardValue(rkey, rv)
                        if ferr then return nil, ferr end
                    elseif args[rtok] and not isSynthetic(args[rtok]) and not args[rtok].rest
                        and argType(args[rtok]) == "boolean" then
                        local ferr = forwardValue(rtok, true)
                        if ferr then return nil, ferr end
                    else
                        buf[#buf + 1] = rtok
                    end
                    i = i + 1
                end
                values[slot] = table.concat(buf, " ")
                i = n
            elseif isSynthetic(spec) then
                if values[slot] ~= nil then
                    return nil, "conflicting arguments for '" .. slot .. "'"
                end
                local src, v, err = resolveSynthetic(args, spec, tok)
                if not src then return nil, err end
                values[src] = v
                values[slot] = v
            else
                local v, err = coerce(slot, spec, tok)
                if err then return nil, err end
                values[slot] = v
            end
        end
        i = i + 1
    end

    for name, spec in pairs(args) do
        if values[name] == nil and spec.default ~= nil and not spec.forward and not isSynthetic(spec) then
            values[name] = spec.default
        end
    end
    for name, spec in pairs(args) do
        if spec.required and values[name] == nil then
            return nil, "missing required argument '" .. name .. "'"
        end
    end
    return values
end

function cmdargs.parseValues(schema: cmdargs.Schema, given: {string: any}): {string: any}, string
    local args = schema.args
    local values: {string: any} = {}

    local function forwardValue(name: string, value: any): string
        local spec = args[name]
        values[name] = value
        if spec.forward then
            if values[spec.forward] ~= nil then
                return "conflicting arguments for '" .. spec.forward .. "'"
            end
            values[spec.forward] = value
        end
        return nil
    end

    for name, v in pairs(given) do
        local spec = args[name]
        if not spec or isSynthetic(spec) then
            return nil, "unknown argument '" .. name .. "'"
        end
        local want = argType(spec)
        local got = type(v)
        if want == "list" or want == "table" then
            -- JSON arrays/objects arrive as tables; strings stay accepted
            -- (the comma form for lists, a Lua expression for tables).
            if got ~= "table" and got ~= "string" then
                return nil, name .. " must be a JSON " ..
                    ((want == "list") and "array" or "object") .. ", got " .. got
            end
            if want == "list" then
                if got == "string" then
                    local items: {string} = {}
                    for item in (v as string):gmatch("[^,]+") do
                        items[#items + 1] = item
                    end
                    v = items
                else
                    for _, item in ipairs(v as {any}) do
                        if type(item) ~= "string" then
                            return nil, name .. " must be an array of strings"
                        end
                    end
                end
            end
        elseif got ~= want then
            return nil, name .. " must be a " .. want .. ", got " .. got
        end
        local cerr = checkConstraints(name, spec, v)
        if cerr then return nil, cerr end
        local ferr = forwardValue(name, v)
        if ferr then return nil, ferr end
    end

    for name, spec in pairs(args) do
        if values[name] == nil and spec.default ~= nil and not spec.forward and not isSynthetic(spec) then
            values[name] = spec.default
        end
    end
    for name, spec in pairs(args) do
        if spec.required and values[name] == nil then
            if isSynthetic(spec) then
                return nil, "provide exactly one of " .. table.concat(spec.synthetic, ", ")
            end
            return nil, "missing required argument '" .. name .. "'"
        end
    end
    return values
end

function cmdargs.toolSchema(schema: cmdargs.Schema): {string: any}
    local props: {string: any} = {}
    local required: {string} = {}
    local hasProps = false

    -- One-of notes for synthetic groups, appended to each source description.
    local groupNote: {string: string} = {}
    for _, spec in pairs(schema.args) do
        if isSynthetic(spec) then
            local note = "Provide exactly one of: " .. table.concat(spec.synthetic, ", ") ..
                (spec.required and " (one is required)." or ".")
            for _, src in ipairs(spec.synthetic) do
                groupNote[src] = note
            end
        end
    end

    for name, spec in pairs(schema.args) do
        if not isSynthetic(spec) then
            local desc = spec.help or ""
            if spec.default ~= nil then
                desc = desc .. " (default: " .. tostring(spec.default) .. ")"
            end
            if groupNote[name] then
                desc = (desc ~= "") and (desc .. ". " .. groupNote[name]) or groupNote[name]
            end
            local prop: {string: any}
            local t = argType(spec)
            if t == "list" then
                prop = {type = "array", items = {type = "string"}, description = desc}
            elseif t == "table" then
                prop = {type = "object", description = desc}
            else
                prop = {type = t, description = desc}
            end
            if spec.enum then prop.enum = spec.enum end
            if spec.min then prop.minimum = spec.min end
            if spec.max then prop.maximum = spec.max end
            props[name] = prop
            hasProps = true
            if spec.required then required[#required + 1] = name end
        end
    end

    local out: {string: any} = {
        type = "object",
        properties = hasProps and props or json.EMPTY_OBJECT,
        additionalProperties = false,
    }
    if #required > 0 then
        table.sort(required)
        out.required = required
    end
    return out
end

function cmdargs.signature(schema: cmdargs.Schema): string
    local parts: {string} = {}
    local inPositional: {string: boolean} = {}
    for _, slot in ipairs(schema.positional or {}) do
        inPositional[slot] = true
        local spec = schema.args[slot]
        local label: string
        if isSynthetic(spec) then
            label = table.concat(spec.synthetic, "|")
        else
            label = slot
        end
        if spec.rest then label = label .. "..." end
        if spec.required then
            parts[#parts + 1] = "<" .. label .. ">"
        else
            parts[#parts + 1] = "[" .. label .. "]"
        end
    end
    -- key=value-only arguments follow the positional slots, sorted, with a
    -- hint for the value shape. Members of a synthetic slot are already
    -- shown by that slot; booleans read as bare flags.
    local named: {string} = {}
    for name, spec in pairs(schema.args) do
        if not inPositional[name] and not isSynthetic(spec) and not spec.forward then
            named[#named + 1] = name
        end
    end
    table.sort(named)
    for _, name in ipairs(named) do
        local spec = schema.args[name]
        local hint: string
        if spec.enum then
            hint = table.concat(spec.enum, "|")
        else
            local kind = spec.kind
            if not kind and spec.default ~= nil then kind = type(spec.default) end
            if kind == "number" then
                hint = "N"
            elseif kind == "boolean" then
                hint = nil
            elseif kind == "list" then
                hint = "a,b"
            elseif kind == "table" then
                hint = "{}"
            else
                hint = "..."
            end
        end
        local label = hint and (name .. "=" .. hint) or name
        if spec.required then
            parts[#parts + 1] = "<" .. label .. ">"
        else
            parts[#parts + 1] = "[" .. label .. "]"
        end
    end
    return table.concat(parts, " ")
end

function cmdargs.argHelp(schema: cmdargs.Schema): {string}
    -- Show every user-facing (non-synthetic) argument, name-aligned with tabs.
    local names: {string} = {}
    for name, spec in pairs(schema.args) do
        if not isSynthetic(spec) then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    local lines: {string} = {}
    for _, name in ipairs(names) do
        local spec = schema.args[name]
        local line = "  " .. name .. "\t" .. (spec.help or "")
        if spec.default ~= nil then
            line = line .. " (default: " .. tostring(spec.default) .. ")"
        elseif spec.required then
            line = line .. " (required)"
        end
        lines[#lines + 1] = line
    end
    return lines
end

return cmdargs
