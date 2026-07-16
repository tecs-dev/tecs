--[[
Structured API extraction over the Teal compiler's type API.

Backs `tecs api` (CLI command and MCP bridge tool): extract() pulls one
module's public symbols as plain Lua tables and build_index() aggregates a
set of modules into the queryable index cli.lua resolves lookups against.
Bundled into the .love payload by scripts/build_love.sh and loaded by
cli.lua's loadApidocs(); it has no other consumers.

The heavy lifting is done by the Teal compiler (the CLI's vendored teal.*
tree; loadTealApi() must have put it on the search path first):
  * `tl.check_file(file, env)` type-checks a module and hands back the
    module's `typedecl` as `result.type` and its AST as `result.ast`.
  * `types.show_type(t)` renders any Type as Teal's own canonical string,
    e.g. `function(number, number): Rectangle`.
  * `require_file.require_module(env, name)` resolves a module path to its
    already-checked `typedecl`, which is how we follow a re-exported record
    (a `nominal` such as `rectangle.Rectangle`) back to its real definition.

All iteration is over ordered arrays (`field_order`, `meta_field_order`) and
build_index() sorts its output, so a generated index is deterministic.
]]

-- The classic `tl` module is the compiler entry point in a Tecs checkout
-- (its vendor tree re-exports teal.api.v2 and registers every teal.*
-- submodule via package.preload). The CLI vendors the teal.* tree directly
-- without that top-level shim, so fall back to teal.api.v2, which exposes
-- the same new_env / check_file surface.
local ok_tl, tl = pcall(require, "tl")
if not ok_tl then
    tl = require("teal.api.v2")
end
local types = require("teal.types")
local require_file = require("teal.check.require_file")
local show_type = types.show_type

local M = {}

----------------------------------------------------------------------
-- Type navigation helpers
----------------------------------------------------------------------

-- Unwrap a typedecl / generic wrapper to reach the underlying structural
-- type (record / interface / function / ...).
local function unwrap(t)
    local guard = 0
    while t and guard < 32 do
        guard = guard + 1
        if t.typename == "typedecl" then
            t = t.def
        elseif t.typename == "generic" then
            t = t.t
        else
            return t
        end
    end
    return t
end

-- The module type cache keyed by require path (require_module already caches
-- inside env, but modules loaded by full path aren't retained across the
-- inlined check, so we memoise per extraction).
local function module_type(env, cache, path)
    if cache[path] ~= nil then
        return cache[path] or nil
    end
    local mt = require_file.require_module(env, path)
    cache[path] = mt or false
    return mt
end

-- Resolve a field type to its terminal structural type -- record, interface,
-- function, map, whatever the alias chain ends at -- following typedecl
-- re-exports and unresolved nominals. `type System = types.System =
-- function(dt, world)` resolves through to the function type instead of
-- dead-ending at the alias.
--   aliasMap : local-var name -> require path (from the module's own AST)
--   moddef   : the module record, so same-module type refs resolve too
local function resolve_type(field, aliasMap, moddef, env, cache)
    local t = field
    local guard = 0
    while t and guard < 32 do
        guard = guard + 1
        local tn = t.typename
        if tn == "typedecl" then
            t = t.def
        elseif tn == "generic" then
            t = t.t
        elseif tn == "nominal" then
            if t.found then
                t = t.found
            else
                local names = t.names
                if not names or #names == 0 then return nil end
                local cur
                local start = 2
                if aliasMap[names[1]] then
                    cur = module_type(env, cache, aliasMap[names[1]])
                elseif moddef and moddef.fields and moddef.fields[names[1]] then
                    cur = moddef.fields[names[1]]
                else
                    return nil
                end
                if not cur then return nil end
                for i = start, #names do
                    cur = unwrap(cur)
                    if not (cur and cur.fields) then return nil end
                    cur = cur.fields[names[i]]
                    if not cur then return nil end
                end
                t = cur
            end
        else
            return t
        end
    end
    return nil
end

-- resolve_type narrowed to record/interface terminals (the expandable kinds).
local function resolve_struct(field, aliasMap, moddef, env, cache)
    local t = resolve_type(field, aliasMap, moddef, env, cache)
    if t and (t.typename == "record" or t.typename == "interface") then
        return t
    end
    return nil
end

----------------------------------------------------------------------
-- Doc-comment extraction
----------------------------------------------------------------------

-- field_comments[name] is a list of comment groups; each group is a list of
-- { x, y, text } line records whose text still carries the leading `---`.
local function extract_doc(comments)
    if not comments then return nil end
    local prose, params, returns, sees = {}, {}, {}, {}
    for _, group in ipairs(comments) do
        for _, entry in ipairs(group) do
            -- Only `---` doc comments are documentation; skip plain `--`
            -- comments (e.g. section separators) that tl also attaches.
            if not (entry.text or ""):match("^%-%-%-") then goto continue end
            local txt = (entry.text or ""):gsub("^%-%-%-%s?", "")
            txt = txt:gsub("%s+$", "")
            local pn, pd = txt:match("^@param%s+(%S+)%s*(.*)$")
            local rd = txt:match("^@returns?%s*(.*)$")
            local sd = txt:match("^@see%s*(.*)$")
            if pn then
                params[#params + 1] = { name = pn, desc = pd }
            elseif rd ~= nil and txt:match("^@returns?") then
                returns[#returns + 1] = rd
            elseif sd ~= nil and txt:match("^@see") then
                sees[#sees + 1] = sd
            else
                prose[#prose + 1] = txt
            end
            ::continue::
        end
    end
    -- Trim trailing blank prose lines.
    while #prose > 0 and prose[#prose] == "" do prose[#prose] = nil end
    if #prose == 0 and #params == 0 and #returns == 0 and #sees == 0 then
        return nil
    end
    return { prose = prose, params = params, returns = returns, sees = sees }
end

local function field_doc(rec, name)
    if not rec.field_comments then return nil end
    return extract_doc(rec.field_comments[name])
end

----------------------------------------------------------------------
-- Signature rendering
----------------------------------------------------------------------

-- Render a function type's signature envelope, using show_type for each
-- element type. `method` drops the leading self argument.
--   name    : callable name (already includes any prefix/receiver)
local function render_function(name, ftype, method)
    local typeargs
    local fn = ftype
    if fn.typename == "generic" then
        typeargs = fn.typeargs
        fn = fn.t
    end
    if fn.typename ~= "function" then
        -- Not actually a function; fall back to the canonical rendering.
        return name .. ": " .. show_type(ftype)
    end

    local gen = ""
    if typeargs and #typeargs > 0 then
        local ts = {}
        for _, ta in ipairs(typeargs) do ts[#ts + 1] = show_type(ta) end
        gen = "<" .. table.concat(ts, ", ") .. ">"
    end

    local args = fn.args and fn.args.tuple or {}
    local start = 1
    if method and #args >= 1 then start = 2 end

    local parts = {}
    local n = #args
    for i = start, n do
        local a = args[i]
        if fn.args.is_va and i == n then
            parts[#parts + 1] = "...: " .. show_type(a)
        else
            local opt = fn.min_arity and i > fn.min_arity
            parts[#parts + 1] = (opt and "? " or "") .. show_type(a)
        end
    end

    local rets = fn.rets and fn.rets.tuple or {}
    local ret = ""
    if #rets > 0 then
        local rp = {}
        for _, r in ipairs(rets) do rp[#rp + 1] = show_type(r) end
        local body = table.concat(rp, ", ")
        if fn.rets.is_va then body = body .. "..." end
        ret = (#rets > 1) and (": (" .. body .. ")") or (": " .. body)
    end

    return name .. gen .. "(" .. table.concat(parts, ", ") .. ")" .. ret
end

----------------------------------------------------------------------
-- Record members
----------------------------------------------------------------------

local function has_ctor(rec)
    return rec.meta_fields and rec.meta_fields["__call"] ~= nil
end

-- Split a record's own public members into method and data-field lists,
-- preserving source order.
--
-- Show only members declared directly on this record, identified by their
-- declaration file matching the record's own file. This drops the fields and
-- methods inherited from framework interfaces (tecs.Component's serialize /
-- componentId / new / init, etc.) while keeping the record's real public
-- surface. When declaration positions are unavailable, fall back to showing
-- every non-type member.
local function record_members(rec)
    local function is_own(ft)
        if rec.f and ft.f then return ft.f == rec.f end
        return true
    end

    local methods, datafields = {}, {}
    for _, fn in ipairs(rec.field_order or {}) do
        local ft = rec.fields[fn]
        if ft.typename ~= "typedecl" and is_own(ft) then
            local doc = field_doc(rec, fn)
            local inner = unwrap(ft)
            if inner and inner.typename == "function" then
                methods[#methods + 1] = { name = fn, ftype = ft, doc = doc }
            else
                datafields[#datafields + 1] = { name = fn, ftype = ft, doc = doc }
            end
        end
    end
    return methods, datafields
end

-- Extract a function type's parameters and return types as structured data
-- (mirrors render_function's envelope logic but returns tables, not a string).
local function fn_params_returns(ftype, method)
    local fn = ftype
    if fn.typename == "generic" then fn = fn.t end
    if fn.typename ~= "function" then return {}, {} end

    local args = fn.args and fn.args.tuple or {}
    local start = 1
    if method and #args >= 1 then start = 2 end

    local params = {}
    local n = #args
    for i = start, n do
        local a = args[i]
        if fn.args.is_va and i == n then
            params[#params + 1] = { type = show_type(a), optional = false, vararg = true }
        else
            local opt = fn.min_arity and i > fn.min_arity
            params[#params + 1] = { type = show_type(a), optional = opt and true or false }
        end
    end

    local rets = {}
    for _, r in ipairs(fn.rets and fn.rets.tuple or {}) do
        rets[#rets + 1] = show_type(r)
    end
    return params, rets
end

-- Local `require` aliases in a module's AST: local-var name -> require path.
-- Lets resolve_struct follow `local rectangle = require("...")` nominals.
local function build_alias_map(ast)
    local map = {}
    local function require_path(exp)
        if type(exp) ~= "table" then return nil end
        if exp.kind == "op" and exp.e1 and exp.e1.kind == "variable"
            and exp.e1.tk == "require" and exp.e2 then
            local first = exp.e2[1]
            if first and first.kind == "string" and first.tk then
                return (first.tk:gsub('^["\']', ""):gsub('["\']$', ""))
            end
        end
        return nil
    end
    for _, stmt in ipairs(ast) do
        if stmt.kind == "local_declaration" and stmt.vars and stmt.exps then
            for i, v in ipairs(stmt.vars) do
                local p = require_path(stmt.exps[i])
                if p and v.tk then map[v.tk] = p end
            end
        end
    end
    return map
end

----------------------------------------------------------------------
-- Structured extraction
--
-- extract() and build_index() return a module set's public surface as plain
-- Lua tables, so the `api` command and its MCP tool can look up a single
-- symbol without reparsing anything.
----------------------------------------------------------------------

-- prose string (or nil) and see-list (or nil) from an extracted doc.
local function doc_parts(doc)
    if not doc then return nil, nil end
    local prose = #doc.prose > 0 and table.concat(doc.prose, "\n") or nil
    local sees = #doc.sees > 0 and doc.sees or nil
    return prose, sees
end

-- Inline prose (single line) for a field or method doc.
local function inline_prose(doc)
    if doc and #doc.prose > 0 then return table.concat(doc.prose, " ") end
    return nil
end

-- Build the structured record for an expandable record/interface symbol.
local function record_symbol(name, struct, receiver)
    local methods, datafields = record_members(struct)

    local fieldsOut = {}
    for _, f in ipairs(datafields) do
        fieldsOut[#fieldsOut + 1] = {
            name = f.name,
            type = show_type(f.ftype),
            doc = inline_prose(f.doc),
        }
    end

    local methodsOut = {}
    for _, m in ipairs(methods) do
        local mprose, msees = doc_parts(m.doc)
        local mp, mr = fn_params_returns(m.ftype, true)
        methodsOut[#methodsOut + 1] = {
            name = m.name,
            signature = render_function(receiver .. ":" .. m.name, m.ftype, true),
            params = mp,
            returns = mr,
            doc = mprose,
            see = msees,
        }
    end

    local ctor
    if has_ctor(struct) then
        local cp, cr = fn_params_returns(struct.meta_fields["__call"], true)
        ctor = {
            params = cp,
            returns = cr,
            signature = render_function(name, struct.meta_fields["__call"], true),
        }
    end

    return {
        kind = has_ctor(struct) and "component" or "record",
        signature = "record " .. name,
        fields = fieldsOut,
        methods = methodsOut,
        constructor = ctor,
    }
end

-- Top-level type declarations in source order: {name, typ} for each
-- `local record/type/interface` (and the global variants). Used to extract
-- symbols from a module whose *return* value is a plain table -- Teal infers a
-- `map` type with no field_order, and that is the common project idiom (declare
-- the record, then assign it onto the returned table). The framework modules
-- instead return an explicit namespace record, so they never reach this path.
local function top_level_type_decls(ast)
    local decls = {}
    for _, stmt in ipairs(ast or {}) do
        if (stmt.kind == "local_type" or stmt.kind == "global_type")
            and stmt.var and stmt.var.tk
            and stmt.value and stmt.value.newtype then
            decls[#decls + 1] = { name = stmt.var.tk, typ = stmt.value.newtype }
        end
    end
    return decls
end

-- A module whose return value IS a single record (a component or plain data
-- record) rather than a namespace table of exports. Detected so a project file
-- that `return`s one component surfaces as one symbol, not as one symbol per
-- field.
local function is_leaf_record(rec)
    if not rec or rec.typename ~= "record" then return false end
    if has_ctor(rec) then return true end
    local hasTypedecl, hasData = false, false
    for _, fn in ipairs(rec.field_order or {}) do
        if rec.fields[fn].typename == "typedecl" then
            hasTypedecl = true
        else
            hasData = true
        end
    end
    return hasData and not hasTypedecl
end

-- Method receivers for the structured index. A record's methods render as
-- `<receiver>:<method>`; the receiver defaults to the type's own name, with
-- these idiomatic overrides.
M.RECEIVER_OVERRIDES = { World = "world" }

local function receiver_for(name)
    return M.RECEIVER_OVERRIDES[name] or name
end

-- Extract one module's public symbols as structured records. `entry` is a
-- module spec {module, file, prefix?, title?}. The full public surface is
-- documented, and each record's method receiver derives from its own name
-- (via RECEIVER_OVERRIDES), so `world:getMut` reads right while every other
-- type uses its own name. Errors from the Teal checker propagate to the
-- caller (build_index isolates them per module).
function M.extract(entry)
    local env = tl.new_env({ gen_target = "5.1", global_env_def = "love2d" })
    local result = assert(tl.check_file(entry.file, env),
        "check_file failed for " .. entry.file)
    assert(#result.syntax_errors == 0,
        "syntax errors while checking " .. entry.file)

    local moddef = unwrap(result.type)
    local aliasMap = build_alias_map(result.ast)
    local cache = {}
    local prefix = entry.prefix or ""
    local source = entry.file

    local symbols = {}
    local function push(sym)
        sym.module = entry.module
        sym.source = source
        symbols[#symbols + 1] = sym
    end

    -- Leaf-record module: the whole file is one symbol.
    if moddef and is_leaf_record(moddef) then
        local name = moddef.declname or entry.symbol
            or (entry.module:match("[^.]+$") or entry.module)
        local rcv = receiver_for(name)
        local doc = field_doc(moddef, name)
        local prose, sees = doc_parts(doc)
        local sym = record_symbol(name, moddef, rcv)
        sym.symbol = name
        sym.receiver = rcv
        sym.doc = prose
        sym.see = sees
        push(sym)
        return { title = entry.title, module = entry.module, symbols = symbols }
    end

    for _, name in ipairs(moddef and moddef.field_order or {}) do
        do
            local ft = moddef.fields[name]
            local doc = field_doc(moddef, name)
            local prose, sees = doc_parts(doc)
            local struct = resolve_struct(ft, aliasMap, moddef, env, cache)
            local expandable = struct
                and (struct.typename == "record" or struct.typename == "interface")
                and (ft.typename == "typedecl" or has_ctor(struct))

            local inner = unwrap(ft)
            local is_func = inner and inner.typename == "function"

            if expandable then
                local rcv = receiver_for(name)
                local sym = record_symbol(name, struct, rcv)
                sym.symbol = name
                sym.receiver = rcv
                sym.doc = prose
                sym.see = sees
                push(sym)
            elseif is_func then
                local params, rets = fn_params_returns(ft, false)
                push({
                    symbol = name,
                    kind = "function",
                    signature = render_function(prefix .. name, ft, false),
                    params = params,
                    returns = rets,
                    fields = {},
                    methods = {},
                    doc = prose,
                    see = sees,
                })
            else
                -- Aliases used to dead-end here ("type alias to types.System"),
                -- pushing readers to grep vendored source. Resolve the chain
                -- and show the terminal type inline, keeping the alias as a
                -- breadcrumb.
                local shown = show_type(ft)
                local sig = prefix .. name .. ": " .. shown
                local resolved = resolve_type(ft, aliasMap, moddef, env, cache)
                if resolved then
                    local shownResolved = show_type(resolved)
                    if shownResolved ~= shown then
                        sig = prefix .. name .. ": " .. shownResolved
                            .. "   (" .. shown .. ")"
                    end
                end
                push({
                    symbol = name,
                    kind = "type",
                    signature = sig,
                    params = {},
                    returns = {},
                    fields = {},
                    methods = {},
                    doc = prose,
                    see = sees,
                })
            end
        end
    end

    -- Fallback for a plain-table module (Teal inferred `map`, no field_order):
    -- surface the records/types declared at the top level. This is what makes
    -- the project overlay work on real code, where components are typically
    -- `local record X ... end; M.X = X; return M`.
    if #symbols == 0 and not (moddef and moddef.field_order) then
        for _, decl in ipairs(top_level_type_decls(result.ast)) do
            local name = decl.name
            local def = unwrap(decl.typ)
            if def and (def.typename == "record" or def.typename == "interface") then
                local rcv = receiver_for(name)
                local sym = record_symbol(name, def, rcv)
                sym.symbol = name
                sym.receiver = rcv
                push(sym)
            elseif def then
                push({
                    symbol = name,
                    kind = "type",
                    signature = "type " .. name .. " = " .. show_type(def),
                    params = {},
                    returns = {},
                    fields = {},
                    methods = {},
                })
            end
        end
    end

    return { title = entry.title, module = entry.module, symbols = symbols }
end

-- Build a structured index over a set of module specs (opts.modules).
-- Returns { symbols = { <symbol record>, ... },
--           modules = { [module name] = { symbol names, sorted } } }.
-- Deterministic: symbols sorted by (module, symbol). With opts.tolerant a
-- module that fails to check is skipped (and recorded in the returned
-- `errors`) instead of aborting the whole build.
function M.build_index(opts)
    opts = opts or {}
    local specs = assert(opts.modules, "build_index requires opts.modules")

    local symbols = {}
    local modules = {}
    local errors = {}

    for _, entry in ipairs(specs) do
        local ok, data = pcall(M.extract, entry)
        if ok and data then
            local names = modules[data.module] or {}
            for _, sym in ipairs(data.symbols) do
                symbols[#symbols + 1] = sym
                names[#names + 1] = sym.symbol
            end
            modules[data.module] = names
        elseif not opts.tolerant then
            error(data, 0)
        else
            errors[#errors + 1] = { module = entry.module, error = tostring(data) }
        end
    end

    table.sort(symbols, function(a, b)
        if a.module ~= b.module then return a.module < b.module end
        return a.symbol < b.symbol
    end)
    for _, names in pairs(modules) do
        table.sort(names)
    end

    return { symbols = symbols, modules = modules, errors = errors }
end

return M
