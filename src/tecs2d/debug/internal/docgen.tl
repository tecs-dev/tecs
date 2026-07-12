--- Render the debugger command registry as a Markdown reference page.
---
--- `scripts/gen_debug_docs.lua` (via `make docs-debug`) writes the result to
--- docs/tecs2d/debug-reference.md, and a spec asserts the committed page
--- matches a fresh render, so the reference can never drift from the code.

local commands <const> = require("tecs2d.debug.commands")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

local record docgen
    markdown: function(reg: commands.Registry): string

    --- A compact index of every projected cmd_* tool (name, one-line
    --- description, link into the reference page) for splicing into the
    --- MCP tools doc between GENERATED markers.
    toolIndex: function(reg: commands.Registry): string
end

local SECTION_ORDER <const>: {string} = cmdtypes.SECTIONS

local SECTION_INTRO <const>: {string: string} = {
    Select = "Find, select, mark, and annotate entities.",
    Edit = "Mutate the live world: components, spawning, world-space drawing.",
    Render = "Inspect and toggle the render pipeline.",
    Engine = "Engine introspection: systems, archetypes, components, states, physics, controllers, assets, audio.",
    Capture = "Artifacts and time travel: screenshots, profiles, snapshots, recordings, rewind, diff.",
    Session = "The debugger session itself.",
    Custom = "Commands registered by the game via `require(\"tecs2d.debug.commands\").register`.",
}

local function splitTicks(s: string): {string}
    local segs: {string} = {}
    local start = 1
    while true do
        local pos = s:find("`", start, true)
        if not pos then
            segs[#segs + 1] = s:sub(start)
            return segs
        end
        segs[#segs + 1] = s:sub(start, pos - 1)
        start = pos + 1
    end
end

-- A raw angle bracket outside a code span opens an HTML tag under VitePress;
-- inside backticks markdown already renders it literally.
local function escapeProse(s: string): string
    local segs = splitTicks(s)
    for i = 1, #segs, 2 do
        segs[i] = segs[i]:gsub("<", "&lt;")
    end
    return table.concat(segs, "`")
end

-- Table cells additionally need every pipe escaped, code span or not, or the
-- pipe splits the row.
local function escapeCell(s: string): string
    local out = escapeProse(s)
    out = out:gsub("|", "\\|")
    return out
end

local function sentence(s: string): string
    local out = s:gsub("^%l", string.upper)
    if not out:match("%.$") then out = out .. "." end
    return escapeProse(out)
end

-- JSON with sorted object keys and stable layout: the page is committed and
-- drift-checked, so rendering must be deterministic across runs.
local function stableJson(v: any, indent: string): string
    local t = type(v)
    if t == "string" then
        local s = (v as string):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
        return '"' .. s .. '"'
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        local tbl = v as {any: any}
        local total = 0
        for _ in pairs(tbl) do total = total + 1 end
        if total == 0 then return "{}" end
        local inner = indent .. "  "
        if #(v as {any}) == total then
            local items: {string} = {}
            for _, item in ipairs(v as {any}) do
                items[#items + 1] = inner .. stableJson(item, inner)
            end
            return "[\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "]"
        end
        local keys: {string} = {}
        for k in pairs(tbl) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local fields: {string} = {}
        for _, k in ipairs(keys) do
            fields[#fields + 1] = inner .. '"' .. k .. '": ' .. stableJson(tbl[k], inner)
        end
        return "{\n" .. table.concat(fields, ",\n") .. "\n" .. indent .. "}"
    end
    return "null"
end

local function typeLabel(spec: cmdargs.ArgSpec): string
    if spec.enum then
        return table.concat(spec.enum, " | ")
    end
    local t = spec.kind
    if not t and spec.default ~= nil then t = type(spec.default) end
    t = t or "string"
    if spec.min and spec.max then
        t = t .. " (" .. tostring(spec.min) .. ".." .. tostring(spec.max) .. ")"
    elseif spec.min then
        t = t .. " (min " .. tostring(spec.min) .. ")"
    elseif spec.max then
        t = t .. " (max " .. tostring(spec.max) .. ")"
    end
    return t
end

-- User-facing arguments in reading order: positional slots first (a synthetic
-- slot expands to its member args, which are what MCP callers pass), then the
-- key=value-only args sorted by name.
local function argOrder(schema: cmdargs.Schema): {string}
    local seen: {string: boolean} = {}
    local order: {string} = {}
    local function push(name: string)
        if not seen[name] then
            seen[name] = true
            order[#order + 1] = name
        end
    end
    for _, slot in ipairs(schema.positional or {}) do
        local spec = schema.args[slot]
        if spec.synthetic then
            for _, member in ipairs(spec.synthetic) do push(member) end
        else
            push(slot)
        end
    end
    local named: {string} = {}
    for name, spec in pairs(schema.args) do
        if not seen[name] and not spec.synthetic then named[#named + 1] = name end
    end
    table.sort(named)
    for _, name in ipairs(named) do push(name) end
    return order
end

local function badges(a: cmdtypes.ToolAnnotations): string
    if not a then return "" end
    local b: {string} = {}
    if a.readOnlyHint then b[#b + 1] = "read-only" end
    if a.destructiveHint then b[#b + 1] = "destructive" end
    if a.idempotentHint then b[#b + 1] = "idempotent" end
    return table.concat(b, ", ")
end

local function renderArgs(out: {string}, schema: cmdargs.Schema)
    local order = argOrder(schema)
    if #order == 0 then return end
    out[#out + 1] = "| Argument | Type | Description |"
    out[#out + 1] = "| --- | --- | --- |"
    for _, name in ipairs(order) do
        local spec = schema.args[name]
        local desc = spec.help or ""
        if spec.default ~= nil then
            desc = desc .. " (default: " .. tostring(spec.default) .. ")"
        elseif spec.required then
            desc = desc .. " (required)"
        end
        out[#out + 1] = "| `" .. name .. "` | " .. escapeCell(typeLabel(spec)) ..
            " | " .. escapeCell(desc) .. " |"
    end
    out[#out + 1] = ""
end

local function toolLine(out: {string}, tool: cmdtypes.McpTool, overlay: boolean)
    if tool then
        local line = "MCP tool: `" .. tool.name .. "`"
        local b = badges(tool.annotations)
        if b ~= "" then line = line .. " (" .. b .. ")" end
        if overlay == false then line = line .. ". MCP only; not typeable in the overlay." end
        out[#out + 1] = line
    else
        out[#out + 1] = "Overlay only; not projected over MCP."
    end
    out[#out + 1] = ""
end

local function renderExamples(out: {string}, examples: {string})
    if not examples or #examples == 0 then return end
    out[#out + 1] = "```"
    for _, ex in ipairs(examples) do out[#out + 1] = ex end
    out[#out + 1] = "```"
    out[#out + 1] = ""
end

-- metadata.screenshots entries with docs = true render as images. `file` is
-- a path usable from the reference page (e.g. ./assets/debug/select.png).
local function renderScreenshots(out: {string}, metadata: {string: any})
    if not metadata then return end
    local shots = metadata.screenshots
    if type(shots) ~= "table" then return end
    for _, entry in ipairs(shots as {any}) do
        local shot = entry as {string: any}
        if shot.docs == true and type(shot.file) == "string" then
            local alt = type(shot.alt) == "string" and (shot.alt as string) or ""
            out[#out + 1] = "![" .. escapeProse(alt) .. "](" .. (shot.file as string) .. ")"
            out[#out + 1] = ""
        end
    end
end

-- The declared Result.data schema, collapsed by default. Over MCP the same
-- object arrives wrapped as {ok = true, result = {...data, message}}.
local function renderOutputSchema(out: {string}, outputSchema: {string: any})
    if not outputSchema then return end
    out[#out + 1] = "::: details Result data schema"
    out[#out + 1] = "```json"
    out[#out + 1] = stableJson(outputSchema, "")
    out[#out + 1] = "```"
    out[#out + 1] = ":::"
    out[#out + 1] = ""
end

local function renderCommand(out: {string}, c: cmdtypes.Command, toolFor: {string: cmdtypes.McpTool})
    out[#out + 1] = "### `" .. commands.commandSignature(c) .. "` {#cmd-" .. c.name .. "}"
    out[#out + 1] = ""
    if c.aliases and #c.aliases > 0 then
        out[#out + 1] = "Aliases: `" .. table.concat(c.aliases, "`, `") .. "`"
        out[#out + 1] = ""
    end
    out[#out + 1] = sentence(c.shortHelp)
    out[#out + 1] = ""
    if c.mcpHelp then
        out[#out + 1] = escapeProse(c.mcpHelp)
        out[#out + 1] = ""
    end
    renderScreenshots(out, c.metadata)
    if c.run then
        toolLine(out, toolFor["cmd_" .. c.name], c.overlay)
    end
    if c.schema then renderArgs(out, c.schema) end
    renderOutputSchema(out, c.outputSchema)
    renderExamples(out, c.examples)
    for _, sub in ipairs(c.subcommands or {}) do
        out[#out + 1] = "#### `" .. commands.subSignature(c, sub) .. "` {#cmd-" ..
            c.name .. "-" .. sub.name .. "}"
        out[#out + 1] = ""
        out[#out + 1] = sentence(sub.shortHelp)
        out[#out + 1] = ""
        if sub.mcpHelp then
            out[#out + 1] = escapeProse(sub.mcpHelp)
            out[#out + 1] = ""
        end
        renderScreenshots(out, sub.metadata)
        toolLine(out, toolFor["cmd_" .. c.name .. "_" .. sub.name], c.overlay)
        if sub.schema then renderArgs(out, sub.schema) end
        renderOutputSchema(out, sub.outputSchema)
        renderExamples(out, sub.examples)
    end
end

function docgen.markdown(reg: commands.Registry): string
    local toolFor: {string: cmdtypes.McpTool} = {}
    for _, tool in ipairs(reg:mcpTools()) do toolFor[tool.name] = tool end

    local bySection: {string: {cmdtypes.Command}} = {}
    for _, c in ipairs(reg.list) do
        local section = c.section or "Custom"
        local bucket = bySection[section]
        if not bucket then
            bucket = {}
            bySection[section] = bucket
        end
        bucket[#bucket + 1] = c
    end

    local out: {string} = {
        "---",
        "outline: [2, 3]",
        "---",
        "",
        "<!-- Generated by `make docs-debug` from the debugger command registry. Do not edit by hand. -->",
        "",
        "# Debugger Commands",
        "",
        "Every command below is typeable in the [in-game debugger](./debug). Commands marked with an",
        "MCP tool name are also projected over [MCP](./mcp/tools) as `cmd_*` tools that share the",
        "operator's selection, marks, and notes; the safety hints in parentheses are the tool's",
        "declared MCP annotations. Arguments are positional or `key=value` in the overlay and JSON",
        "parameters over MCP. Result data schemas describe the command's structured payload; over MCP",
        "it arrives wrapped as `{ok = true, result = {...data, message}}` and is also declared as the",
        "tool's `outputSchema`.",
        "",
        "This page is generated: run `make docs-debug` after changing a command.",
        "",
    }
    for _, section in ipairs(SECTION_ORDER) do
        local bucket = bySection[section]
        if bucket then
            out[#out + 1] = "## " .. section
            out[#out + 1] = ""
            if SECTION_INTRO[section] then
                out[#out + 1] = SECTION_INTRO[section]
                out[#out + 1] = ""
            end
            for _, c in ipairs(bucket) do renderCommand(out, c, toolFor) end
        end
    end
    return table.concat(out, "\n")
end

function docgen.toolIndex(reg: commands.Registry): string
    local out: {string} = {
        "| Tool | Description |",
        "| --- | --- |",
    }
    for _, c in ipairs(reg.list) do
        if c.mcp ~= false and c.run then
            out[#out + 1] = "| [`cmd_" .. c.name .. "`](../debug-reference#cmd-" .. c.name ..
                ") | " .. escapeCell(sentence(c.shortHelp)) .. " |"
        end
        for _, sub in ipairs(c.subcommands or {}) do
            if sub.mcp ~= false then
                out[#out + 1] = "| [`cmd_" .. c.name .. "_" .. sub.name ..
                    "`](../debug-reference#cmd-" .. c.name .. "-" .. sub.name .. ") | " ..
                    escapeCell(sentence(sub.shortHelp)) .. " |"
            end
        end
    end
    return table.concat(out, "\n")
end

return docgen
