-- Shaping helpers every command answers through.
--
-- A leaf module: the registry and each command group require it, and it
-- requires neither of them.

local data <const> = require("tecs.data")

local record answer
    list: function<T>({T}): {T}
end

--- Answers with the rows, or with the sentinel an empty list has to serialize
--- as.
---
--- An empty Lua table encodes as a JSON object, so a command answering with no
--- rows would contradict the `array` its own output schema declares, and a
--- client reading the field strictly would reject it.
---
--- @param rows The caller supplies the rows it built, which may be none.
--- @return The same table when it holds anything, and otherwise the empty-array
---     sentinel, which the caller must not then write into.
function answer.list<T>(rows: {T}): {T}
    if #rows > 0 then
        return rows
    end
    return data.empty_array as {T}
end

return answer
