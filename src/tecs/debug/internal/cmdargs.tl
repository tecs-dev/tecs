--[=[
The argument grammar shared by every debugger command.

A command declares one schema, and that schema types both surfaces the debugger
exposes. `tokenize` and `parse` turn a typed command line into a name to value
map, while `toolSchema` projects the same declaration into a JSON Schema for an
MCP tool listing and `parseValues` checks the decoded argument object an agent
sends back. No command parses its own arguments, so the console and the agent
cannot disagree about what a command accepts.

A schema holds `args`, which maps each argument name to its `ArgSpec`, and
`positional`, which lists the argument names bound by position. A synthetic
argument holds one positional slot on behalf of several real arguments: each
source names the synthetic in `forward`, the synthetic names its sources back in
`synthetic`, and the slot binds whichever source accepts the token. `validate`
requires that pair of edges. Typed sources are tried before string sources, so a
number reaches a numeric source and a word falls through to a string one.

```teal
local cmdargs <const> = require("tecs.debug.internal.cmdargs")

local schema <const>: cmdargs.Schema = {
    args = {
        name = {help = "Names a mark.", forward = "target"},
        id = {help = "Identifies an entity by id.", default = 0, forward = "target"},
        target = {synthetic = {"name", "id"}, required = true, help = "Selects the entity to act on."},
    },
    positional = {"target"},
}

cmdargs.validate(schema)

local tokens <const> = assert(cmdargs.tokenize("boss"))
local values <const> = assert(cmdargs.parse(schema, tokens))
-- values.name is "boss" and values.target is "boss"; values.id stays nil.
```

`validate` raises, because a schema is written in this tree and a broken one is
a programmer error. `tokenize`, `parse` and `parseValues` all read input a user
or an agent supplied, so each returns `nil` and a reason instead.
]=]

local record cmdargs
    --- Declares one argument: how it is typed, how it is bound, and what values it accepts.
    record ArgSpec
        --- Caller-writable. Requires the argument to hold a value once parsing finishes.
        required: boolean
        --- Caller-writable. Supplies the value used when the argument is absent, and infers the
        --- value type when `kind` is omitted. A forwarding argument never receives its default,
        --- which only types it.
        default: any
        --- Caller-writable. Describes the argument in generated help and in the MCP tool schema.
        help: string
        --- Caller-writable. Names the synthetic argument this argument feeds its value into.
        forward: string
        --- Caller-writable. Lists the source argument names this synthetic argument accepts, and
        --- its presence marks the argument synthetic, so users neither name it nor see it.
        synthetic: {string}
        --- Caller-writable. States the value type explicitly, as `"number"`, `"boolean"`,
        --- `"string"`, `"list"`, `"table"` or `"rows"`. Omitting it infers the type from
        --- `default`, so set it for an optional typed argument that has no default, such as a
        --- number that leaves the current value unchanged when absent. A `"list"` is a
        --- comma-separated string on the command line and a JSON string array over MCP. A
        --- `"table"` is a brace-balanced Lua expression on the command line and a JSON object over
        --- MCP. A `"rows"` argument is that same expression on the command line and a JSON array
        --- of objects over MCP, so an action receives either a string or a table and handles both.
        kind: string
        --- Caller-writable. Restricts a string argument to these values, and projects to a JSON
        --- Schema `enum`.
        enum: {string}
        --- Caller-writable. Bounds a number argument from below, inclusively.
        min: number
        --- Caller-writable. Bounds a number argument from above, inclusively.
        max: number
        --- Caller-writable. Makes the slot consume every remaining token as free text, joined with
        --- single spaces, where a quoted span keeps its inner spacing. The argument must be the
        --- last positional slot and must be string-, table- or rows-typed.
        rest: boolean
    end

    --- Declares the complete argument grammar of one command.
    record Schema
        --- Caller-writable. Maps each argument name to the spec that types it.
        args: {string: ArgSpec}
        --- Caller-writable. Lists the argument names bound by position, in order. A slot may name
        --- a synthetic argument.
        positional: {string}
    end

    --- Checks that the schema is internally consistent and raises when it is not.
    ---
    --- Every forward edge must have its reciprocal synthetic edge, every synthetic source must
    --- name an argument that forwards back, every positional slot must name a declared argument,
    --- and a rest argument must be the last positional slot.
    --- @param schema The schema to check. A mistake in it raises, because a schema is written in
    ---     this tree rather than supplied by a user.
    validate: function(schema: Schema)

    --- Splits a command line into tokens.
    ---
    --- Single and double quotes group a value that contains spaces and are stripped from the
    --- token. A balanced `{...}` span stays one token verbatim, braces and inner spacing included,
    --- so a Lua table expression survives the split.
    --- @param text The raw command line, which may be empty.
    --- @return The tokens in order, or nil and the reason an unterminated quote or brace could not
    ---     be split.
    tokenize: function(text: string): {string}, string

    --- Parses command-line tokens into a name to value map, coercing each token to its declared
    --- type and applying defaults, forwarding and required checks.
    ---
    --- A token shaped `name=value` binds that argument, a bare token naming a boolean argument
    --- sets it true, and any other token fills the next positional slot. A positional token after
    --- a named one is an error, because it would read as a value the user meant to name.
    --- @param schema The schema to parse against, which `validate` accepts.
    --- @param tokens The tokens from `tokenize`, or any equivalent list.
    --- @return The values by argument name, or nil and the reason the tokens were malformed.
    parse: function(schema: Schema, tokens: {string}): {string: any}, string

    --- Checks an already-typed argument object, such as decoded MCP JSON, against the schema.
    ---
    --- Each named value is type-checked rather than coerced, and forwarding, synthetic
    --- resolution, defaults and required checks then run as they do for a command line. A missing
    --- required synthetic reports which of its sources to provide.
    --- @param schema The schema to check against, which `validate` accepts.
    --- @param given The argument object, keyed by argument name.
    --- @return The values by argument name, or nil and the reason the object did not satisfy the
    ---     schema.
    parseValues: function(schema: Schema, given: {string: any}): {string: any}, string

    --- Projects the schema to a JSON Schema object for an MCP tool listing.
    ---
    --- Synthetic arguments are hidden, and each of their sources carries a note naming the group
    --- to provide exactly one of.
    --- @param schema The schema to project.
    --- @return A fresh table shaped like an MCP `inputSchema`, which the caller owns.
    toolSchema: function(schema: Schema): {string: any}

    --- Renders the positional signature of the schema, such as `"<name|id> [seconds]"`.
    ---
    --- Positional slots come first in declaration order, then the key-only arguments sorted by
    --- name, each with a hint for the shape of its value. A required part is angle-bracketed and
    --- an optional one is square-bracketed.
    --- @param schema The schema to render.
    --- @return The signature as one line, which is empty when the schema declares nothing.
    signature: function(schema: Schema): string

    --- Renders one help line per user-facing argument, sorted by name.
    ---
    --- Each line holds the argument name, a tab, its help text, and either its default or the note
    --- that it is required. Synthetic arguments are omitted, since a user never names one.
    --- @param schema The schema to render.
    --- @return The lines in order, which the caller owns.
    argHelp: function(schema: Schema): {string}
end

local function argType(spec: cmdargs.ArgSpec): string
    if spec.kind then
        return spec.kind
    end
    local d = spec.default
    if type(d) == "number" then
        return "number"
    end
    if type(d) == "boolean" then
        return "boolean"
    end
    return "string"
end

local function isSynthetic(spec: cmdargs.ArgSpec): boolean
    return spec.synthetic ~= nil
end

local function parseBool(raw: string): boolean, boolean
    if raw == "1" or raw == "true" or raw == "on" or raw == "yes" then
        return true, true
    end
    if raw == "0" or raw == "false" or raw == "off" or raw == "no" then
        return false, true
    end
    return false, false
end

-- Value constraints shared by both parse paths: enum membership for strings
-- and inclusive bounds for numbers.
local function checkConstraints(name: string, spec: cmdargs.ArgSpec, value: any): string
    if spec.enum and type(value) == "string" then
        for _, allowed in ipairs(spec.enum) do
            if value == allowed then
                return nil
            end
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
        if not n then
            return nil, name .. " must be a number, got '" .. raw .. "'"
        end
        value = n
    elseif t == "boolean" then
        local b, ok = parseBool(raw)
        if not ok then
            return nil, name .. " must be true or false, got '" .. raw .. "'"
        end
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
    if cerr then
        return nil, cerr
    end
    return value
end

function cmdargs.validate(schema: cmdargs.Schema)
    local args = schema.args
    for name, spec in pairs(args) do
        if spec.rest then
            local at = argType(spec)
            if at ~= "string" and at ~= "table" and at ~= "rows" then
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
                if src == name then
                    found = true
                end
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
        if i > n then
            break
        end
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
                        if depth == 0 then
                            break
                        end
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
local function resolveSynthetic(
    args: {string: cmdargs.ArgSpec}, spec: cmdargs.ArgSpec, raw: string
): string, any, string
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
        if v ~= nil then
            return src, v
        end
    end
    if strings[1] then
        return strings[1], raw
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
            if err then
                return nil, err
            end
            local ferr = forwardValue(key, v)
            if ferr then
                return nil, ferr
            end
        elseif args[tok] and not isSynthetic(args[tok]) and argType(args[tok]) == "boolean" then
            sawNamed = true
            local ferr = forwardValue(tok, true)
            if ferr then
                return nil, ferr
            end
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
                        if rerr then
                            return nil, rerr
                        end
                        local ferr = forwardValue(rkey, rv)
                        if ferr then
                            return nil, ferr
                        end
                    elseif
                        args[rtok]
                        and not isSynthetic(args[rtok])
                        and not args[rtok].rest
                        and argType(args[rtok]) == "boolean"
                    then
                        local ferr = forwardValue(rtok, true)
                        if ferr then
                            return nil, ferr
                        end
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
                if not src then
                    return nil, err
                end
                values[src] = v
                values[slot] = v
            else
                local v, err = coerce(slot, spec, tok)
                if err then
                    return nil, err
                end
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
        if want == "list" or want == "table" or want == "rows" then
            -- JSON arrays/objects arrive as tables; strings stay accepted
            -- (the comma form for lists, a Lua expression for tables/rows).
            if got ~= "table" and got ~= "string" then
                return nil,
                    name
                        .. " must be a JSON "
                        .. ((want == "list") and "array" or (want == "rows") and "array of objects" or "object")
                        .. ", got "
                        .. got
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
        if cerr then
            return nil, cerr
        end
        local ferr = forwardValue(name, v)
        if ferr then
            return nil, ferr
        end
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

    -- One-of notes for synthetic groups, appended to each source description.
    local groupNote: {string: string} = {}
    for _, spec in pairs(schema.args) do
        if isSynthetic(spec) then
            local note = "Provide exactly one of: "
                .. table.concat(spec.synthetic, ", ")
                .. (spec.required and " (one is required)." or ".")
            for _, src in ipairs(spec.synthetic) do
                groupNote[src] = note
            end
        end
    end

    for name, spec in pairs(schema.args) do
        if not isSynthetic(spec) then
            local desc = spec.help or ""
            -- Forwarding args never receive their default (it only infers the
            -- type), so advertising one would be false.
            if spec.default ~= nil and not spec.forward then
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
            elseif t == "rows" then
                prop = {type = "array", items = {type = "object"}, description = desc}
            else
                prop = {type = t, description = desc}
            end
            if spec.enum then
                prop.enum = spec.enum
            end
            if spec.min then
                prop.minimum = spec.min
            end
            if spec.max then
                prop.maximum = spec.max
            end
            props[name] = prop
            if spec.required then
                required[#required + 1] = name
            end
        end
    end

    -- An argument-free schema leaves `properties` an empty table, which
    -- `tecs.data` encodes as the JSON object the MCP listing expects.
    local out: {string: any} = {
        type = "object",
        properties = props,
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
        if spec.rest then
            label = label .. "..."
        end
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
            if not kind and spec.default ~= nil then
                kind = type(spec.default)
            end
            if kind == "number" then
                hint = "N"
            elseif kind == "boolean" then
                hint = nil
            elseif kind == "list" then
                hint = "a,b"
            elseif kind == "table" then
                hint = "{}"
            elseif kind == "rows" then
                hint = "[{..}]"
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
        if spec.default ~= nil and not spec.forward then
            line = line .. " (default: " .. tostring(spec.default) .. ")"
        elseif spec.required then
            line = line .. " (required)"
        end
        lines[#lines + 1] = line
    end
    return lines
end

return cmdargs
