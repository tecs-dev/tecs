--[[ Internal module to generate component constructors. --]]
local pool <const> = require("tecs.utils.pool")
local buffer <const> = require("string.buffer")

local load, setmetatable, table_concat, table_unpack <const> = load, setmetatable, table.concat, table.unpack
local EMPTY = pool.EMPTY

-- Reusable string buffer and tables for codegen.
local CODEGEN_BUF <const>: buffer = buffer.new()
local ARRAY_POOL <const> = pool.newTablePool({
    clearOn = "release",
    arrayHint = 8,
    hashHint = 0,
})

--- Shared constructor/new codegen for components and relationships.
---
--- `createCallFn` generates the hot `__call` path for all component
--- backends. The generated function owns positional defaulting and then
--- either stamps a table literal or forwards the normalized args into an
--- allocator. Callers keep `.new(data)` logic separate for now.
local record ComponentCodegen
    enum CallBackend
        "tableLiteral"
        "allocatorCall"
    end

    record CallSpec
        backend: CallBackend
        fields: {string}
        defaults: {any}
        leadingArgCount: integer
        includeSelfParam: boolean
        instanceMt: metatable<any> | nil
        allocator: function(...: any): any | nil
    end

    --- Generate a fused `__call` function for a component/relationship
    --- backend. Positional defaults are applied inline in the emitted code.
    createCallFn: function(spec: CallSpec): function(any, ...: any): any

    --- Build a `.new(data)` adapter that unpacks named fields into
    --- positional args and forwards through the container's `__call`.
    --- `leadingFields` are prepended before `fields` (for example
    --- `{"target"}` for relationships).
    createNewFn: function(
        container: any,
        fields: {string},
        leadingFields?: {string},
        requiredFieldErrors?: {string:string}
    ): function(data: {string: any}): any
end

local function createCallFn(spec: ComponentCodegen.CallSpec): function(any, ...: any): any
    local tableAssigns = ARRAY_POOL:acquire() as {string}
    local allocArgs = ARRAY_POOL:acquire() as {string}
    local upDecls = ARRAY_POOL:acquire() as {string}
    local upArgs = ARRAY_POOL:acquire() as {any}

    local fields = spec.fields
    local defaults = spec.defaults
    local leadingArgCount = spec.leadingArgCount or 0
    local backend = spec.backend
    local includeSelfParam = spec.includeSelfParam

    for i = 1, leadingArgCount do
        allocArgs[i] = "l" .. i
    end

    local hasDefaults = defaults ~= nil
    for i = 1, #fields do
        local param = "a" .. i
        local field = fields[i]
        local valueExpr: string
        if hasDefaults and defaults[i] ~= nil then
            valueExpr = param .. " == nil and d[" .. i .. "] or " .. param
        else
            valueExpr = param
        end
        tableAssigns[i] = field .. " = " .. valueExpr
        allocArgs[leadingArgCount + i] = valueExpr
    end

    if hasDefaults then
        upDecls[#upDecls + 1] = "d"
        upArgs[#upArgs + 1] = defaults
    end

    if backend == "tableLiteral" then
        if spec.instanceMt then
            upDecls[#upDecls + 1] = "mt"
            upArgs[#upArgs + 1] = spec.instanceMt
            upDecls[#upDecls + 1] = "setmetatable"
            upArgs[#upArgs + 1] = setmetatable
        end
    else
        upDecls[#upDecls + 1] = "alloc"
        upArgs[#upArgs + 1] = spec.allocator
    end

    CODEGEN_BUF:reset()
    if #upDecls > 0 then
        CODEGEN_BUF:putf("local %s = ...\n", table_concat(upDecls, ", "))
    end
    CODEGEN_BUF:put("return function(")
    local needComma = false
    if includeSelfParam then
        CODEGEN_BUF:put("_c")
        needComma = true
    end
    for i = 1, leadingArgCount do
        if needComma then CODEGEN_BUF:put(", ") end
        CODEGEN_BUF:putf("l%d", i)
        needComma = true
    end
    for i = 1, #fields do
        if needComma then CODEGEN_BUF:put(", ") end
        CODEGEN_BUF:putf("a%d", i)
        needComma = true
    end
    CODEGEN_BUF:put(")\n    ")

    if backend == "tableLiteral" then
        if spec.instanceMt then
            CODEGEN_BUF:putf("return setmetatable({%s}, mt)\nend", table_concat(tableAssigns, ", "))
        else
            CODEGEN_BUF:putf("return {%s}\nend", table_concat(tableAssigns, ", "))
        end
    else
        CODEGEN_BUF:putf("return alloc(%s)\nend", table_concat(allocArgs, ", "))
    end

    local src = CODEGEN_BUF:get()
    local chunk, err = load(src, "=component_ctor", "t")
    if not chunk then error("codegen failed: " .. tostring(err)) end
    local callFn = (chunk as function(...: any): function(any, ...: any): any)(table_unpack(upArgs))

    ARRAY_POOL:release(tableAssigns)
    ARRAY_POOL:release(allocArgs)
    ARRAY_POOL:release(upDecls)
    ARRAY_POOL:release(upArgs)

    return callFn
end

local function createNewFn(
    container: any,
    fields: {string},
    leadingFields?: {string},
    requiredFieldErrors?: {string:string}
): function(data: {string: any}): any
    local leading: {string}
    local leadingCount: integer
    if leadingFields then
        leading = leadingFields
        leadingCount = #leading
    else
        leading = EMPTY as {string}
        leadingCount = 0
    end
    local fieldCount = #fields
    return function(data: {string: any}): any
        local args: {any} = {}
        for i = 1, leadingCount do
            local field = leading[i]
            local value = data[field]
            local err = requiredFieldErrors and requiredFieldErrors[field]
            if err and value == nil then
                error(err)
            end
            args[i] = value
        end
        for i = 1, fieldCount do
            args[leadingCount + i] = data[fields[i]]
        end
        return (container as function(...: any): any)(table_unpack(args, 1, leadingCount + fieldCount))
    end
end

ComponentCodegen.createCallFn = createCallFn
ComponentCodegen.createNewFn = createNewFn

return ComponentCodegen
