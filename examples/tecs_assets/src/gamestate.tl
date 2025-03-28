local tecs <const> = require("tecs")

local record GameState is tecs.States<Value>
    enum Value
        "loading"
        "playing"
    end
end

return GameState