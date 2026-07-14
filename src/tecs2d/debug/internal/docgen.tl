--- Render the debugger command registry as a Markdown reference page, and
--- the MCP tools page from the kernel tool definitions plus the registry.
---
--- `scripts/gen_debug_docs.lua` (via `make docs-debug`) writes the results to
--- docs/tecs2d/debug-reference.md and docs/tecs2d/mcp/tools.md, and a spec
--- asserts the committed pages match a fresh render, so the docs can never
--- drift from the code.

local commands <const> = require("tecs2d.debug.commands")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")
local tools <const> = require("tecs2d.mcp.tools")

local record docgen
    markdown: function(reg: commands.Registry): string

    --- A compact index of every projected cmd_* tool (name, one-line
    --- description, link into the reference page).
    toolIndex: function(reg: commands.Registry): string

    --- The full MCP tools page: intro and envelope conventions, a kernel
    --- tools section generated from tecs2d.mcp.tools, and the cmd_* tool
    --- index generated from the registry.
    toolsPage: function(reg: commands.Registry): string
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
        "description: \"Generated reference for every built-in debugger command and cmd_* MCP tool with arguments, result schemas, and examples\"",
        "outline: [2, 3]",
        "---",
        "",
        "<!-- Generated by `make docs-debug` from the debugger command registry. Do not edit by hand. -->",
        "",
        "# Debugger Commands",
        "",
        "Every command below is typeable in the [in-game debugger](./debug) (see",
        "[command syntax](./debug#command-syntax)); those marked with a tool name are also callable",
        "over [MCP](./mcp/tools) as `cmd_*` tools, with the same arguments as JSON parameters and the",
        "result data wrapped as `{ok = true, result = {...data, message}}`.",
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
            out[#out + 1] = "| Command | Description |"
            out[#out + 1] = "| --- | --- |"
            for _, c in ipairs(bucket) do
                out[#out + 1] = "| [`" .. c.name .. "`](#cmd-" .. c.name .. ") | " ..
                    escapeCell(sentence(c.shortHelp)) .. " |"
            end
            out[#out + 1] = ""
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

local function kernelBadges(a: tools.Annotations): string
    local b: {string} = {}
    if a.readOnlyHint then b[#b + 1] = "read-only" end
    if a.destructiveHint then b[#b + 1] = "destructive" end
    if a.idempotentHint then b[#b + 1] = "idempotent" end
    return table.concat(b, ", ")
end

local function kernelTypeLabel(schema: tools.Schema): string
    local t = schema.type
    if not t then return "any" end
    if t == "array" then
        local items = schema.items
        if items and items.type then return items.type .. "[]" end
        return "array"
    end
    return t
end

-- Property names in a stable order: required arguments first, then
-- alphabetical within each group.
local function sortedProperties(props: {string: tools.Schema}, required: {string: boolean}): {string}
    local names: {string} = {}
    if props then
        for name in pairs(props) do names[#names + 1] = name end
    end
    table.sort(names, function(a: string, b: string): boolean
        local ra, rb = required[a] or false, required[b] or false
        if ra ~= rb then return ra end
        return a < b
    end)
    return names
end

local function requiredSet(list: {string}): {string: boolean}
    local set: {string: boolean} = {}
    for _, name in ipairs(list or {}) do set[name] = true end
    return set
end

local function kernelArgRow(out: {string}, name: string, schema: tools.Schema, required: boolean)
    out[#out + 1] = "| `" .. name .. "` | " .. escapeCell(kernelTypeLabel(schema)) ..
        " | " .. (required and "yes" or "no") ..
        " | " .. escapeCell(schema.description or "") .. " |"
end

local function renderKernelArgs(out: {string}, schema: tools.Schema)
    local required = requiredSet(schema.required)
    local names = sortedProperties(schema.properties, required)
    if #names == 0 then
        out[#out + 1] = "No arguments."
        out[#out + 1] = ""
        return
    end
    out[#out + 1] = "| Argument | Type | Required | Description |"
    out[#out + 1] = "| --- | --- | --- | --- |"
    for _, name in ipairs(names) do
        local prop = schema.properties[name]
        kernelArgRow(out, name, prop, required[name])
        -- One level into array item objects, so callers see the item shape
        -- (e.g. points[].x) without reading the raw JSON Schema.
        local items = prop.items
        if items and items.properties then
            local itemRequired = requiredSet(items.required)
            for _, sub in ipairs(sortedProperties(items.properties, itemRequired)) do
                kernelArgRow(out, name .. "[]." .. sub, items.properties[sub], itemRequired[sub])
            end
        end
    end
    out[#out + 1] = ""
end

local function renderKernelTool(out: {string}, tool: tools.Tool)
    out[#out + 1] = "### `" .. tool.name .. "` {#" .. tool.name .. "}"
    out[#out + 1] = ""
    out[#out + 1] = escapeProse(tool.description)
    out[#out + 1] = ""
    local b = kernelBadges(tool.annotations)
    out[#out + 1] = "Annotations: " .. (b ~= "" and b or "none") .. "."
    out[#out + 1] = ""
    renderKernelArgs(out, tool.inputSchema)
end

function docgen.toolsPage(reg: commands.Registry): string
    local out: {string} = {
        "---",
        "description: \"Generated MCP tool reference: kernel tools (ping, screenshot, run_lua, get_logs) and the full cmd_* command tool index with response envelope\"",
        "outline: [2, 3]",
        "---",
        "",
        "<!-- Generated by `make docs-debug` from the kernel tool definitions and the debugger command registry. Do not edit by hand. -->",
        "",
        "# MCP Tools",
        "",
        "The MCP server exposes two tool layers to agents connected to a running game:",
        "",
        "- **Kernel tools** are transport-level and always available: liveness, screenshots, pixel",
        "  sampling, Love2D events, arbitrary Lua, and log capture.",
        "- **Command tools** (`cmd_*`) project the debugger command registry, one tool per command or",
        "  subcommand verb, including commands the game registers itself. Call `cmd_capabilities` after",
        "  connecting to discover what the session supports, and `cmd_describe` for one command's full",
        "  contract.",
        "",
        "The server listens on `http://localhost:19999/mcp` by default; an MCP client connects with",
        '`{"type": "http", "url": "http://localhost:19999/mcp"}`. See the [MCP server guide](./) for',
        "setup and the investigation workflow.",
        "",
        "This page is generated: run `make docs-debug` after changing a kernel tool or a debugger",
        "command.",
        "",
        "## Response envelope",
        "",
        "Except for `screenshot`, tool calls return an MCP `result` with one text content item plus the",
        "same envelope as `structuredContent`, so typed clients consume the object directly while",
        "text-only clients parse the JSON. Every tool declares MCP safety annotations (readOnlyHint,",
        "destructiveHint, idempotentHint, openWorldHint): kernel tools declare them explicitly, and",
        "command tools derive them from the command (reads derive read-only and idempotent, world loads",
        "and despawns derive destructive, and commands can override per key). Successful tool payloads",
        "use:",
        "",
        "```json",
        '{"ok":true,"result":{}}',
        "```",
        "",
        "Command tools carry the command's structured data plus its human-readable `message` inside",
        "`result`:",
        "",
        "```json",
        '{"ok":true,"result":{"selected":3,"added":[42],"message":"selected 1"}}',
        "```",
        "",
        "Tool-level failures still return a JSON-RPC `result`, not a JSON-RPC `error`. The MCP tool",
        "result has `isError: true`, and its text content contains the structured error envelope:",
        "",
        "```json",
        '{"ok":false,"error":{"code":"unknown_component","message":"Unknown component","details":{"component":"Health"}}}',
        "```",
        "",
        "JSON-RPC protocol and dispatch errors, such as unknown tool names, invalid `tools/call`",
        "params, unknown methods, or malformed requests, use standard JSON-RPC `error` responses",
        "instead of MCP tool results.",
        "",
        "MCP clients discover the live tool set by calling `tools/list`. The response composes the",
        "kernel tools with every command currently registered in the game, including game-defined",
        "commands, so it is the exact source of truth for the session.",
        "",
        "## Kernel tools",
        "",
        "Kernel tools are defined by the MCP server itself and available in every session.",
        "",
    }
    for _, tool in ipairs(tools.list) do
        renderKernelTool(out, tool)
    end
    out[#out + 1] = "## Command tools"
    out[#out + 1] = ""
    out[#out + 1] = "Every debugger command that allows MCP projection appears as one `cmd_*` tool per command and"
    out[#out + 1] = "subcommand verb. The tool's JSON input schema is generated from the command's argument schema,"
    out[#out + 1] = "so `tools/list` always matches what the operator can type and validation is identical on both"
    out[#out + 1] = "surfaces. These are the same commands typeable in the [in-game debugger](../debug); they share"
    out[#out + 1] = "the operator's selection, marks, notes, and capture artifacts. Games extend the surface with"
    out[#out + 1] = "`require(\"tecs2d.debug.commands\").register`; registered commands appear as `cmd_<name>` tools"
    out[#out + 1] = "exactly like the builtins."
    out[#out + 1] = ""
    out[#out + 1] = "This index links each tool to its full contract (arguments, result data schema, examples,"
    out[#out + 1] = "safety annotations) in the [Command Reference](../debug-reference); `cmd_describe` returns the"
    out[#out + 1] = "same contract as structured data at runtime."
    out[#out + 1] = ""
    out[#out + 1] = docgen.toolIndex(reg)
    return table.concat(out, "\n")
end

return docgen
