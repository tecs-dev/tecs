
local schema = {}









local function isValidCIdent(name)
   return name:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

function schema.validateFields(fields, reservedFields)
   local seen = {}
   local reserved = reservedFields or {}

   for i = 1, #fields do
      local field = fields[i]
      local fieldName, fieldType = field[1], field[2]

      if not fieldName or fieldName == "" then
         error("Field #" .. i .. ": field name cannot be empty")
      end

      if reserved[fieldName] then
         error("Field #" .. i .. ": '" .. fieldName .. "' is reserved and must not be specified manually")
      end

      if not isValidCIdent(fieldName) then
         error("Field #" .. i .. ": invalid C identifier: " .. fieldName)
      end

      if seen[fieldName] then
         error("Field #" .. i .. ": duplicate field name: " .. fieldName)
      end
      seen[fieldName] = true

      if not fieldType or fieldType == "" then
         error("Field #" .. i .. ": field type cannot be empty for field: " .. fieldName)
      end
   end
end

return schema
