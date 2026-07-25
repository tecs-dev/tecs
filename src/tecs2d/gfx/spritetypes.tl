--- Public types shared by sprite components and events.

local tecs <const> = require("tecs")
local types <const> = require("tecs2d.gfx.types")
local sheet <const> = require("tecs2d.gfx.sheet")

local record spritetypes
    --- Options shared by all Sprite factories.
    interface SpriteOptions
        --- Animation speed multiplier. Defaults to 1.
        speed: number
        --- Center the sprite on its Transform. Defaults to true.
        centered: boolean
        --- Aseprite slice name to use as the pivot.
        pivotSlice: string
        --- Animation start time, used to stagger otherwise identical sprites.
        startTime: number
    end

    --- Options for `Sprite.fromTexture`.
    interface TextureSpriteOptions is SpriteOptions
        --- Source path used to reconstruct the sprite during snapshot load.
        path: string
    end

    --- An animated, automatically batched sprite component.
    interface Sprite is tecs.Component, types.Rect
        --- Identifier for the shared sprite template.
        spriteId: integer
        --- Animation start time used to offset playback.
        animStartTime: number
        --- Paused frame, or -1 while playing.
        pausedFrame: integer
        --- Number of active pause requests.
        pauseDepth: integer

        --- Mark sprite metadata as dirty, triggering GPU re-sync.
        --- Call this after changing Color, ClipBounds, or pivot values.
        markDirty: function(self)

        --- Set the animation tag.
        setTag: function(self, tag: string)

        --- Play a tag once, then invoke the callback when the last frame is reached.
        playOnce: function(self, tag: string, onComplete?: function(Sprite))

        --- Pause the animation at its current frame.
        pause: function(self, time?: number)

        --- Resume the animation from its paused frame.
        resume: function(self)

        --- Set the animation to the last frame and pause.
        pauseAtEnd: function(self)

        --- Set the animation to the first frame and pause.
        pauseAtStart: function(self)

        --- Jump to a frame within the current tag.
        gotoFrame: function(self, frame: integer)

        --- Get the current zero-based frame within the current tag.
        getFrame: function(self): integer

        --- Get the one-based frame across the complete SpriteSheet.
        getAbsoluteFrame: function(self): integer

        --- Get the current animation tag.
        getTag: function(self): string

        --- Get the normalized center point.
        getCenter: function(self): number, number

        --- Get the sprite dimensions.
        getDimensions: function(self): number, number

        --- Get the current pivot.
        getPivot: function(self): number, number

        --- Create a Sprite from a loaded SpriteSheet.
        fromSheet: function(
            spriteSheet: sheet.SpriteSheet,
            tag?: string,
            options?: SpriteOptions
        ): Sprite

        --- Create a Sprite from an Aseprite file.
        fromAseprite: function(path: string, tag?: string, options?: SpriteOptions): Sprite

        --- Create a single-frame Sprite from a texture.
        fromTexture: function(
            texture: love.graphics.Texture,
            options?: TextureSpriteOptions
        ): Sprite
    end

    --- Event emitted when a Sprite changes animation tags.
    interface ChangeTag is tecs.Event
        --- Entity whose Sprite changed.
        entity: integer
        --- Previous tag, or an empty string on initial assignment.
        oldTag: string
        --- Newly assigned tag.
        newTag: string
        --- Sprite component that changed.
        sprite: Sprite

        metamethod __call: function(
            self,
            entity: integer,
            oldTag: string,
            newTag: string,
            sprite: Sprite
        ): ChangeTag
    end
end

return spritetypes
