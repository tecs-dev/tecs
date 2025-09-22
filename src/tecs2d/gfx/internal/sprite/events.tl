--- Sprite events
---
--- Events for sprite animation: ChangeTag (when animation tag changes).

local tecs <const> = require("tecs")

local record sprite_events
    --- Event emitted when the animation tag of a sprite changes
    record ChangeTag is tecs.Event
        entity: integer
        oldTag: string
        newTag: string
        sprite: any  -- Sprite (use any to avoid circular dep)

        metamethod __call: function(self, entity: integer, oldTag: string, newTag: string, sprite: any): ChangeTag
    end

end

-------------------------------------------------------------------------------
-- Event registration
-------------------------------------------------------------------------------

sprite_events.ChangeTag.init = function(
    e: sprite_events.ChangeTag, entity: integer, oldTag: string, newTag: string, sprite: any
)
    e.entity, e.oldTag, e.newTag, e.sprite = entity, oldTag or "", newTag or "", sprite
end
tecs.newEvent(sprite_events.ChangeTag)

return sprite_events
