--- Schema-driven debugger command completion.
---
--- Completion is intentionally independent of overlay input state: it reads
--- only the registry's command declarations and live candidate resolver.

local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

local record completion
    record Source
        names: {string}
        byName: {string: cmdtypes.Command}
        candidatesFor: function(self: Source, source: string): {string}
    end

    complete: function(source: Source, text: string): string, {string}
end

local function findSubcommand(cmd: cmdtypes.Command,
        name: string): cmdtypes.Subcommand
    if not cmd.subcommands or not name then return nil end
    for _, sub in ipairs(cmd.subcommands) do
        if sub.name == name then return sub end
    end
    return nil
end

local function completionKind(spec: cmdargs.ArgSpec): string
    if spec.kind then return spec.kind end
    if type(spec.default) == "boolean" then return "boolean" end
    if type(spec.default) == "number" then return "number" end
    return "string"
end

local function markArg(schema: cmdargs.Schema,
        used: {string: boolean}, name: string)
    if not name then return end
    used[name] = true
    local spec = schema.args[name]
    if not spec then return end
    if spec.forward then
        used[spec.forward] = true
        local target = schema.args[spec.forward]
        for _, member in ipairs((target and target.synthetic) or {}) do
            used[member] = true
        end
    end
    for _, member in ipairs(spec.synthetic or {}) do used[member] = true end
end

local function argumentPosition(schema: cmdargs.Schema,
        tokens: {string}): integer, {string: boolean}
    local used: {string: boolean} = {}
    local position = 1
    for _, token in ipairs(tokens) do
        local name = token:match("^([%a_][%w_]*)=")
        if name and schema.args[name] then
            markArg(schema, used, name)
        else
            local positional = schema.positional or {}
            local slot = positional[position]
            if slot then
                markArg(schema, used, slot)
                local spec = schema.args[slot]
                if not spec.rest then position = position + 1 end
            end
        end
    end
    return position, used
end

local function quoted(value: string): string
    if not value:find("[%s\"\\]") then return value end
    return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

function completion.complete(source: completion.Source,
        text: string): string, {string}
    local out: {string} = {}
    local head, prefix = text:match("^(.*%s)(%S*)$")
    if not head then
        prefix = text
        if prefix == "" then
            for _, section in ipairs(cmdtypes.SECTIONS) do
                local start = #out
                for i = 1, #source.names do
                    local cmd = source.byName[source.names[i]]
                    if cmd and (cmd.section or "Custom") == section then
                        out[#out + 1] = source.names[i]
                    end
                end
                if #out > start then
                    table.insert(out, start + 1,
                        cmdtypes.SECTION_MARK .. section)
                end
            end
            return "", out
        end
        for i = 1, #source.names do
            if source.names[i]:sub(1, #prefix) == prefix then
                out[#out + 1] = source.names[i]
            end
        end
        return "", out
    end

    local tokens = cmdargs.tokenize(head)
    if not tokens or #tokens == 0 then return head, out end
    local cmd = source.byName[tokens[1]]
    if not cmd then return head, out end

    local routedSub: cmdtypes.Subcommand = nil
    if cmd.subcommands and tokens[2] then
        routedSub = findSubcommand(cmd, tokens[2])
    end

    if cmd.subcommands and not routedSub then
        for _, sub in ipairs(cmd.subcommands) do
            if sub.name:sub(1, #prefix) == prefix then
                out[#out + 1] = sub.name
            end
        end
        if not cmd.run then return head, out end
    end

    local schema = routedSub and routedSub.schema or cmd.schema
    if not schema then return head, out end
    local firstArg = routedSub and 3 or 2
    local previous: {string} = {}
    for i = firstArg, #tokens do previous[#previous + 1] = tokens[i] end
    local position, used = argumentPosition(schema, previous)

    local named, valuePrefix = prefix:match("^([%a_][%w_]*)=(.*)$")
    local spec: cmdargs.ArgSpec = nil
    local activeSlot: string = nil
    local outputPrefix = ""
    if named and schema.args[named] and not schema.args[named].synthetic then
        spec = schema.args[named]
        outputPrefix = named .. "="
    else
        local positional = schema.positional or {}
        local slot = positional[position]
        if slot and (not named or schema.args[slot].rest) then
            activeSlot = slot
            spec = schema.args[slot]
        end
        valuePrefix = prefix
    end

    local seen: {string: boolean} = {}
    local function add(value: string, rawPrefix: string, prefixOut: string)
        local negative = rawPrefix:sub(1, 1) == "-"
        local openedQuote = rawPrefix:sub(1, 1) == '"'
        local matchPrefix = rawPrefix
        if negative or openedQuote then matchPrefix = rawPrefix:sub(2) end
        if value:sub(1, #matchPrefix) ~= matchPrefix then return end
        local rendered = quoted(value)
        if negative then rendered = "-" .. rendered end
        local candidate = prefixOut .. rendered
        if not seen[candidate] then
            seen[candidate] = true
            out[#out + 1] = candidate
        end
    end

    local function addSpecValues(valueSpec: cmdargs.ArgSpec)
        local values: {string} = {}
        for _, value in ipairs(valueSpec.enum or {}) do
            values[#values + 1] = value
        end
        if completionKind(valueSpec) == "boolean" then
            values[#values + 1] = "on"
            values[#values + 1] = "off"
        end
        if valueSpec.completion then
            for candidateSource in valueSpec.completion:gmatch("[^,]+") do
                local live = source:candidatesFor(candidateSource)
                for i = 1, #live do values[#values + 1] = live[i] end
            end
        end
        for _, member in ipairs(valueSpec.synthetic or {}) do
            local memberSpec = schema.args[member]
            if memberSpec then
                for _, value in ipairs(memberSpec.enum or {}) do
                    values[#values + 1] = value
                end
                if completionKind(memberSpec) == "boolean" then
                    values[#values + 1] = "on"
                    values[#values + 1] = "off"
                end
                if memberSpec.completion then
                    for candidateSource in
                            memberSpec.completion:gmatch("[^,]+") do
                        local live = source:candidatesFor(candidateSource)
                        for i = 1, #live do values[#values + 1] = live[i] end
                    end
                end
            end
        end
        for i = 1, #values do
            add(values[i], valuePrefix or "", outputPrefix)
        end
    end
    if spec then addSpecValues(spec) end

    if not named then
        local keys: {string} = {}
        for name, argSpec in pairs(schema.args) do
            if not argSpec.synthetic and not used[name] and name ~= activeSlot then
                keys[#keys + 1] = name .. "="
            end
        end
        table.sort(keys)
        for i = 1, #keys do
            if keys[i]:sub(1, #prefix) == prefix and not seen[keys[i]] then
                seen[keys[i]] = true
                out[#out + 1] = keys[i]
            end
        end
    end
    return head, out
end

return completion
