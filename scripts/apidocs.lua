--[[
API-signature documentation renderer.

Extracts the public API surface of selected Teal modules using the Teal
compiler's *type* API (not text-parsing source) and renders a Markdown
reference page per module.

The heavy lifting is done by the Teal compiler:
  * `tl.check_file(file, env)` type-checks a module and hands back the
    module's `typedecl` as `result.type` and its AST as `result.ast`.
  * `types.show_type(t)` (from the internal `teal.types` module) renders any
    Type as Teal's own canonical string, e.g. `function(number, number): Rectangle`.
  * `require_file.require_module(env, name)` resolves a module path to its
    already-checked `typedecl`, which is how we follow a re-exported record
    (a `nominal` such as `rectangle.Rectangle`) back to its real definition.

This module is required by BOTH `scripts/gen_api_docs.lua` (which writes the
pages) and `spec/tecs2d/api/docgen_spec.tl` (which fails CI if a committed
page is stale), exactly like the debug docgen pattern.

All iteration is over ordered arrays (`field_order`, `meta_field_order`,
`MODULES`) so the rendered output is byte-for-byte deterministic.
]]

-- The Teal module search is driven by package.path (it probes .tl / .d.tl /
-- .lua variants of each template). Add the source tree so `require_module`
-- and `check_file` resolve project modules. Relative to the repo root, which
-- is the cwd for both `make docs-api` and `make test`.
do
   local need = "src/?.lua;src/?/init.lua;"
   if not package.path:find("src/%?%.lua", 1) then
      package.path = need .. package.path
   end
end

local tl = require("tl")
local types = require("teal.types")
local require_file = require("teal.check.require_file")
local show_type = types.show_type

local M = {}

--- The modules to document. A small table so it is trivial to extend.
--- Each entry:
---   title       page H1 + module label
---   module      require path (used to resolve re-exports back to defs)
---   file        source .tl to check (gives the module type + its AST)
---   out         committed Markdown path
---   description  frontmatter `description:` (required on every docs page)
---   prefix       call prefix for module-level functions/fields (e.g. "gfx.")
---   only         optional allow-list of export names to document
---   receiver     optional method receiver name for an expanded record
M.MODULES = {
   {
      title = "tecs2d.gfx",
      module = "tecs2d.gfx",
      file = "src/tecs2d/gfx/init.tl",
      out = "docs/tecs2d/api/gfx.md",
      prefix = "gfx.",
      description = "Signature reference for tecs2d.gfx: component constructors, cameras, materials, and rendering helpers.",
   },
   {
      title = "tecs.World",
      module = "tecs.types",
      file = "src/tecs/types.tl",
      out = "docs/tecs2d/api/world.md",
      only = { "World" },
      receiver = "world",
      description = "Signature reference for the tecs World API: spawning, querying, systems, events, resources, and snapshots.",
   },
   {
      title = "tecs2d.input",
      module = "tecs2d.input",
      file = "src/tecs2d/input.tl",
      out = "docs/tecs2d/api/input.md",
      prefix = "input.",
      description = "Signature reference for tecs2d.input: keyboard, mouse, and gamepad state plus the input query functions.",
   },
   {
      title = "tecs2d.events",
      module = "tecs2d.events",
      file = "src/tecs2d/events.tl",
      out = "docs/tecs2d/api/events.md",
      prefix = "events.",
      description = "Signature reference for tecs2d.events: the Tecs event wrappers for Love2D callbacks and their constructors.",
   },
}

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
-- inlined check, so we memoise per render).
local function module_type(env, cache, path)
   if cache[path] ~= nil then
      return cache[path] or nil
   end
   local mt = require_file.require_module(env, path)
   cache[path] = mt or false
   return mt
end

-- Resolve a field type to its underlying record / interface definition,
-- following typedecl re-exports and unresolved nominals. Returns the
-- structural def (record or interface) or nil for anything else.
--   aliasMap : local-var name -> require path (from the module's own AST)
--   moddef   : the module record, so same-module type refs resolve too
local function resolve_struct(field, aliasMap, moddef, env, cache)
   local t = field
   local guard = 0
   while t and guard < 32 do
      guard = guard + 1
      local tn = t.typename
      if tn == "record" or tn == "interface" then
         return t
      elseif tn == "typedecl" then
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
         return nil
      end
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
         -- Only `---` doc comments are documentation; skip plain `--` comments
         -- (e.g. section separators) that tl also attaches to the field.
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

local function render_doc(out, doc)
   if not doc then return end
   if #doc.prose > 0 then
      out[#out + 1] = table.concat(doc.prose, "\n")
      out[#out + 1] = ""
   end
   if #doc.params > 0 then
      out[#out + 1] = "**Parameters**"
      out[#out + 1] = ""
      for _, p in ipairs(doc.params) do
         local desc = p.desc ~= "" and (" — " .. p.desc) or ""
         out[#out + 1] = "- `" .. p.name .. "`" .. desc
      end
      out[#out + 1] = ""
   end
   if #doc.returns > 0 then
      out[#out + 1] = "**Returns** " .. table.concat(doc.returns, " ")
      out[#out + 1] = ""
   end
   if #doc.sees > 0 then
      for _, s in ipairs(doc.sees) do
         out[#out + 1] = "See: " .. s
      end
      out[#out + 1] = ""
   end
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

local function code_block(out, sig)
   out[#out + 1] = "```lua"
   out[#out + 1] = sig
   out[#out + 1] = "```"
   out[#out + 1] = ""
end

----------------------------------------------------------------------
-- Record expansion
----------------------------------------------------------------------

local function has_ctor(rec)
   return rec.meta_fields and rec.meta_fields["__call"] ~= nil
end

local function expand_record(out, name, rec, receiver)
   local ctor = has_ctor(rec)

   -- Show only members declared directly on this record, identified by their
   -- declaration file matching the record's own file. This drops the fields
   -- and methods inherited from framework interfaces (tecs.Component's
   -- serialize / componentId / new / init, etc.) while keeping the record's
   -- real public surface. When declaration positions are unavailable, fall
   -- back to showing every non-type member.
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

   if ctor then
      out[#out + 1] = "**Constructor**"
      out[#out + 1] = ""
      code_block(out, render_function(name, rec.meta_fields["__call"], true))
      local cdoc = rec.meta_field_comments and extract_doc(rec.meta_field_comments["__call"])
      render_doc(out, cdoc)
   end

   if #datafields > 0 then
      out[#out + 1] = "**Fields**"
      out[#out + 1] = ""
      for _, f in ipairs(datafields) do
         local line = "- `" .. f.name .. ": " .. show_type(f.ftype) .. "`"
         if f.doc and #f.doc.prose > 0 then
            line = line .. " — " .. table.concat(f.doc.prose, " ")
         end
         out[#out + 1] = line
      end
      out[#out + 1] = ""
   end

   if #methods > 0 then
      out[#out + 1] = "**Methods**"
      out[#out + 1] = ""
      for _, m in ipairs(methods) do
         out[#out + 1] = "#### `" .. receiver .. ":" .. m.name .. "`"
         out[#out + 1] = ""
         code_block(out, render_function(receiver .. ":" .. m.name, m.ftype, true))
         render_doc(out, m.doc)
      end
   end
end

----------------------------------------------------------------------
-- Page rendering
----------------------------------------------------------------------

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

function M.render(entry)
   local env = tl.new_env({ gen_target = "5.1", global_env_def = "love2d" })
   local result = assert(tl.check_file(entry.file, env),
      "check_file failed for " .. entry.file)
   assert(#result.syntax_errors == 0,
      "syntax errors while checking " .. entry.file)

   local moddef = unwrap(result.type)
   local aliasMap = build_alias_map(result.ast)
   local cache = {}
   local receiver = entry.receiver
   local prefix = entry.prefix or ""

   -- Which exports to document (preserve source order via field_order).
   local allow
   if entry.only then
      allow = {}
      for _, n in ipairs(entry.only) do allow[n] = true end
   end

   local out = {}
   out[#out + 1] = "---"
   out[#out + 1] = 'description: "' .. entry.description .. '"'
   out[#out + 1] = "outline: deep"
   out[#out + 1] = "---"
   out[#out + 1] = ""
   out[#out + 1] = "<!-- Generated by scripts/gen_api_docs.lua from the Teal type API. Do not edit by hand. -->"
   out[#out + 1] = ""
   local subject = entry.only and entry.title or entry.module
   out[#out + 1] = "# " .. entry.title
   out[#out + 1] = ""
   out[#out + 1] = "Public API signatures for `" .. subject
      .. "`, extracted from the Teal type definitions. Optional arguments are"
      .. " marked `?` and follow Teal's own signature syntax."
   out[#out + 1] = ""

   for _, name in ipairs(moddef.field_order or {}) do
      if not allow or allow[name] then
         local ft = moddef.fields[name]
         local doc = field_doc(moddef, name)
         local struct = resolve_struct(ft, aliasMap, moddef, env, cache)
         local expandable = struct
            and (struct.typename == "record" or struct.typename == "interface")
            and (ft.typename == "typedecl" or has_ctor(struct))

         local inner = unwrap(ft)
         local is_func = inner and inner.typename == "function"

         out[#out + 1] = "## `" .. name .. "`"
         out[#out + 1] = ""

         if expandable then
            render_doc(out, doc)
            expand_record(out, name, struct, receiver or name)
         elseif is_func then
            code_block(out, render_function(prefix .. name, ft, false))
            render_doc(out, doc)
         else
            code_block(out, prefix .. name .. ": " .. show_type(ft))
            render_doc(out, doc)
         end
      end
   end

   -- Collapse to a single trailing newline-free string; the caller appends
   -- exactly one "\n" (mirrors the debug docgen contract).
   local text = table.concat(out, "\n")
   text = text:gsub("\n\n\n+", "\n\n"):gsub("%s+$", "")
   return text
end

return M
