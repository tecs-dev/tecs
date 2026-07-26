



local json = {}








































local parser = require("tecs.utils.json.internal.parser")
local serializer = require("tecs.utils.json.internal.serializer")


json.NULL = setmetatable({}, {
   __tostring = function()
      return "json.NULL"
   end,
   __newindex = function()
      error("Cannot modify json.NULL sentinel")
   end,
})


json.EMPTY_ARRAY = setmetatable({}, {
   __tostring = function()
      return "json.EMPTY_ARRAY"
   end,
   __newindex = function()
      error("Cannot modify json.EMPTY_ARRAY sentinel")
   end,
})


json.EMPTY_OBJECT = setmetatable({}, {
   __tostring = function()
      return "json.EMPTY_OBJECT"
   end,
   __newindex = function()
      error("Cannot modify json.EMPTY_OBJECT sentinel")
   end,
})

parser.setNullSentinel(json.NULL)
serializer.setNullSentinel(json.NULL)
serializer.setEmptyObjectSentinel(json.EMPTY_OBJECT)





local OBJECT_MARKER = {}
parser.setObjectMarker(OBJECT_MARKER)
serializer.setObjectMarker(OBJECT_MARKER)

json.parse = parser.parse
json.parseCData = parser.parseCData
json.serialize = serializer.serialize
json.serializePretty = serializer.serializePretty

return json
