--- Sprite events
---
--- Events for sprite animation: ChangeTag (when animation tag changes).

local tecs <const> = require("tecs")
local spritetypes <const> = require("tecs2d.gfx.spritetypes")

local record sprite_events
    --- Event emitted when the animation tag of a sprite changes
    ChangeTag: spritetypes.ChangeTag

    --- Event emitted when a `playOnce` animation reaches its last frame
    AnimationComplete: spritetypes.AnimationComplete
end

local record AnimationCompleteImpl is spritetypes.AnimationComplete
    entity: integer
    tag: string

    metamethod __call: function(
        self, entity: integer, tag: string
    ): AnimationCompleteImpl
end

local record ChangeTagImpl is spritetypes.ChangeTag
    entity: integer
    oldTag: string
    newTag: string
    sprite: spritetypes.Sprite

    metamethod __call: function(
        self,
        entity: integer,
        oldTag: string,
        newTag: string,
        sprite: spritetypes.Sprite
    ): ChangeTagImpl
end

-------------------------------------------------------------------------------
-- Event registration
-------------------------------------------------------------------------------

ChangeTagImpl.init = function(
    e: ChangeTagImpl,
    entity: integer,
    oldTag: string,
    newTag: string,
    sprite: spritetypes.Sprite
)
    e.entity, e.oldTag, e.newTag, e.sprite = entity, oldTag or "", newTag or "", sprite
end
tecs.newEvent(ChangeTagImpl)
sprite_events.ChangeTag = ChangeTagImpl as spritetypes.ChangeTag

AnimationCompleteImpl.init = function(
    e: AnimationCompleteImpl,
    entity: integer,
    tag: string
)
    e.entity, e.tag = entity, tag or ""
end
tecs.newEvent(AnimationCompleteImpl)
sprite_events.AnimationComplete =
    AnimationCompleteImpl as spritetypes.AnimationComplete

return sprite_events
