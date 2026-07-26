
local pool = require("tecs.utils.pool")
local buffer = require("string.buffer")

local load, setmetatable, table_concat, table_unpack = load, setmetatable, table.concat, table.unpack
local EMPTY = pool.EMPTY


local CODEGEN_BUF = buffer.new()
local ARRAY_POOL = pool.newTablePool({
   clearOn = "release",
   arrayHint = 8,
   hashHint = 0,
})







local ComponentCodegen = { CallSpec = {} }































local function createCallFn(spec)
   local tableAssigns = ARRAY_POOL:acquire()
   local allocArgs = ARRAY_POOL:acquire()
   local upDecls = ARRAY_POOL:acquire()
   local upArgs = ARRAY_POOL:acquire()

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
      tableAssigns[i] = fields[i] .. " = " .. param
      allocArgs[leadingArgCount + i] = param
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
   CODEGEN_BUF:put(")\n")
   if hasDefaults then
      for i = 1, #fields do
         if defaults[i] ~= nil then
            CODEGEN_BUF:putf("    if a%d == nil then a%d = d[%d] end\n", i, i, i)
         end
      end
   end
   CODEGEN_BUF:put("    ")

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
   local callFn = (chunk)(table_unpack(upArgs))

   ARRAY_POOL:release(tableAssigns)
   ARRAY_POOL:release(allocArgs)
   ARRAY_POOL:release(upDecls)
   ARRAY_POOL:release(upArgs)

   return callFn
end

local function createNewFn(
   container,
   fields,
   leadingFields,
   requiredFieldErrors)

   local leading
   local leadingCount
   if leadingFields then
      leading = leadingFields
      leadingCount = #leading
   else
      leading = EMPTY
      leadingCount = 0
   end
   local fieldCount = #fields
   return function(data)
      local args = {}
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
      return (container)(table_unpack(args, 1, leadingCount + fieldCount))
   end
end

ComponentCodegen.createCallFn = createCallFn
ComponentCodegen.createNewFn = createNewFn

return ComponentCodegen
