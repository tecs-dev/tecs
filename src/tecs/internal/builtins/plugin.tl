local builtins <const> = require("tecs.internal.builtins")
local phases <const> = require("tecs.internal.phases")
local types <const> = require("tecs.types")

local TTL <const> = builtins.TTL

return function(w: types.World)
    -- Don't enable debug by default.
    w:setState(builtins.Debug, "off")

    -- Handle despawning entities with TTLs.
    local ttlQuery = w:query({include = {TTL}})
    w:addSystem({
        name = "ttl",
        phase = phases.FixedUpdate,
        run = function(dt: number)
            for archetype, len, entities in ttlQuery() do
                local ttls = archetype[TTL]
                for row = 1, len do
                    local ttl = ttls[row]
                    ttl.remaining = ttl.remaining - dt
                    if ttl.remaining <= 0 then
                        w:despawn(entities[row])
                    end
                end
            end
        end
    })
end
