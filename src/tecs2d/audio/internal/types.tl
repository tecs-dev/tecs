local tecs <const> = require("tecs")
local tecs_assets <const> = require("tecs2d.assets")

local type Component = tecs.Component

--- Type definitions for the tecs2d.audio module.
local record types

    --- Handle type alias for audio sources.
    type Handle = tecs_assets.Handle<love.audio.Source>

    --- Options for playing a sound via the direct API.
    record PlayOptions
        --- Sound group name (defaults to "sfx").
        group: string

        --- Volume multiplier 0-1 (defaults to 1.0).
        volume: number

        --- Pitch multiplier (defaults to 1.0).
        pitch: number

        --- Random pitch variance +/- this value (defaults to 0).
        pitchVariance: number

        --- Sound key for voice limiting and cooldowns.
        key: string

        --- Fade in duration in seconds (0 = instant).
        fadeIn: number

        --- Whether to loop the sound.
        loop: boolean
    end

    --- Information about an active audio source for cleanup tracking.
    record SourceInfo
        --- The sound group this source belongs to.
        group: string

        --- The sound key for voice limiting (may be nil).
        key: string

        --- Target volume (for fading).
        targetVolume: number

        --- Base volume before group/master multipliers.
        baseVolume: number

        --- Fade duration in seconds (0 = no fade).
        fadeDuration: number

        --- Elapsed fade time.
        fadeElapsed: number

        --- Starting volume for fade.
        fadeStartVolume: number

        --- Whether to stop after fade completes.
        stopAfterFade: boolean

        --- Whether currently paused.
        paused: boolean

        --- Back-reference for component sources only. Lets stopAll() and
        --- similar manager-wide operations flip playing=false and clear
        --- _source on the owning component, so the next sync doesn't
        --- re-play a source the caller just stopped.
        audioSrc: AudioSource
    end

    --- Configuration for a sound group.
    record SoundGroup
        --- Volume multiplier 0-1.
        volume: number

        --- Whether the group is muted.
        muted: boolean

        --- Whether the group is paused.
        paused: boolean
    end

    --- The audio manager interface.
    interface AudioManager
        --- Set the volume for a sound group.
        --- @param name The group name.
        --- @param volume Volume 0-1.
        setGroupVolume: function(self, name: string, volume: number)

        --- Get the volume for a sound group.
        --- @param name The group name.
        --- @return The group volume 0-1.
        getGroupVolume: function(self, name: string): number

        --- Mute or unmute a sound group.
        --- @param name The group name.
        --- @param muted Whether to mute the group.
        muteGroup: function(self, name: string, muted: boolean)

        --- Check if a sound group is muted.
        --- @param name The group name.
        --- @return True if muted.
        isGroupMuted: function(self, name: string): boolean

        --- Set the maximum concurrent voices for a sound key.
        --- @param key The sound key.
        --- @param maxVoices Maximum concurrent plays (0 = unlimited).
        setVoiceLimit: function(self, key: string, maxVoices: integer)

        --- Set cooldown between plays for a sound key.
        --- @param key The sound key.
        --- @param seconds Minimum seconds between plays.
        setCooldown: function(self, key: string, seconds: number)

        --- Check if a sound key is on cooldown.
        --- @param key The sound key.
        --- @return True if on cooldown.
        isOnCooldown: function(self, key: string): boolean

        --- Play a non-positional (2D) sound.
        --- @param handle The audio asset handle.
        --- @param options Optional play options.
        --- @return The playing source, or nil if blocked by cooldown/voice limit.
        play: function(self, handle: tecs_assets.Handle<love.audio.Source>, options?: PlayOptions): love.audio.Source

        --- Play a positional (3D) sound.
        --- @param handle The audio asset handle.
        --- @param x X position.
        --- @param y Y position.
        --- @param z Z position.
        --- @param options Optional play options.
        --- @return The playing source, or nil if blocked by cooldown/voice limit.
        playAt: function(
            self, handle: tecs_assets.Handle<love.audio.Source>, x: number, y: number, z: number,
            options?: PlayOptions
        ): love.audio.Source

        --- Stop all sounds in a group.
        --- @param name The group name.
        --- @param fadeDuration Optional fade out duration in seconds.
        stopGroup: function(self, name: string, fadeDuration?: number)

        --- Stop all sounds.
        --- @param fadeDuration Optional fade out duration in seconds.
        stopAll: function(self, fadeDuration?: number)

        --- Pause all sounds in a group.
        --- @param name The group name.
        --- @param fadeDuration Optional fade out duration in seconds.
        pauseGroup: function(self, name: string, fadeDuration?: number)

        --- Resume all sounds in a group.
        --- @param name The group name.
        --- @param fadeDuration Optional fade in duration in seconds.
        resumeGroup: function(self, name: string, fadeDuration?: number)

        --- Check if a group is paused.
        --- @param name The group name.
        --- @return True if paused.
        isGroupPaused: function(self, name: string): boolean

        --- Stop a specific source.
        --- @param source The source to stop.
        --- @param fadeDuration Optional fade out duration in seconds.
        stop: function(self, source: love.audio.Source, fadeDuration?: number)

        --- Pause a specific source.
        --- @param source The source to pause.
        --- @param fadeDuration Optional fade out duration in seconds.
        pause: function(self, source: love.audio.Source, fadeDuration?: number)

        --- Resume a specific source.
        --- @param source The source to resume.
        --- @param fadeDuration Optional fade in duration in seconds.
        resume: function(self, source: love.audio.Source, fadeDuration?: number)

        --- Set an effect on a group. Applies to all current and future sources in the group.
        --- @param groupName The group name.
        --- @param effectName The effect type name (e.g., "reverb", "chorus", "distortion").
        --- @param settings Effect settings table (e.g., { decaytime = 2.0, density = 0.8 }).
        setGroupEffect: function(self, groupName: string, effectName: string, settings: {string:any})

        --- Remove an effect from a group.
        --- @param groupName The group name.
        --- @param effectName The effect slot name.
        removeGroupEffect: function(self, groupName: string, effectName: string)

        --- Update the audio manager (called each frame).
        --- Processes fades, cooldowns, and cleans up finished sources.
        --- @param dt Delta time in seconds.
        update: function(self, dt: number)

        --- Register an AudioSource component's source for group operations.
        --- @param source The LÖVE audio source.
        --- @param group The sound group name.
        --- @param baseVolume The base volume for the source.
        --- @param audioSrc The owning AudioSource component (used by stopAll()
        ---                 and group operations to mutate playing=false).
        registerComponentSource: function(self, source: love.audio.Source, group: string, baseVolume: number, audioSrc?: AudioSource)

        --- Refresh a registered component source's mutable state (volume,
        --- group, looping, attenuation). Called each frame by the audio
        --- plugin so gameplay mutations on AudioSource take effect.
        --- @param source The LÖVE audio source.
        --- @param audioSrc The component with current field values.
        refreshComponentSource: function(self, source: love.audio.Source, audioSrc: AudioSource)

        --- Unregister an AudioSource component's source.
        --- @param source The LÖVE audio source.
        unregisterComponentSource: function(self, source: love.audio.Source)

        --- Check if a component source should play (not paused by group).
        --- @param source The LÖVE audio source.
        --- @return True if the source should play.
        shouldComponentSourcePlay: function(self, source: love.audio.Source): boolean

        --- Check if a component source is currently fading.
        --- @param source The LÖVE audio source.
        --- @return True if the source is fading.
        isComponentSourceFading: function(self, source: love.audio.Source): boolean

        --- Set the listener position (called by the listener system).
        --- @param x X position.
        --- @param y Y position.
        --- @param z Z position.
        setListenerPosition: function(self, x: number, y: number, z: number)

        --- Capture durable mixer state (per-group volume/mute/pause and
        --- listener position) as a plain table for snapshotting. Voice
        --- limits, cooldowns, and effects are treated as startup config,
        --- not gameplay state, so they are not included.
        --- @return A `string.buffer`-encodable mixer-state table.
        serializeMixer: function(self): {string:any}

        --- Restore mixer state produced by `serializeMixer`. Re-applies the
        --- restored group volumes and mute flags to any sources already
        --- registered on this manager.
        --- @param data The mixer-state table.
        restoreMixer: function(self, data: {string:any})
    end

    --- Configuration for the AudioSource component.
    record AudioSourceConfig
        --- Handle to the audio asset.
        handle: tecs_assets.Handle<love.audio.Source>

        --- Sound group name (defaults to "sfx").
        group: string

        --- Volume 0-1 (defaults to 1.0).
        volume: number

        --- Pitch multiplier (defaults to 1.0).
        pitch: number

        --- Random pitch variance +/- (defaults to 0).
        pitchVariance: number

        --- Whether to loop (defaults to false).
        looping: boolean

        --- Whether to play immediately (defaults to true).
        playing: boolean

        --- If true, position is relative to the listener instead of world space (defaults to false).
        relative: boolean

        --- Reference distance for attenuation (defaults to 100).
        refDistance: number

        --- Max distance for attenuation (defaults to 1000).
        maxDistance: number
    end

    --- Component for continuous/looping sounds attached to entities.
    record AudioSource is Component
        --- Handle to the audio asset.
        handle: tecs_assets.Handle<love.audio.Source>

        --- Sound group name. Changing it re-routes group/master volume;
        --- group effects applied at registration do not migrate.
        group: string

        --- Volume 0-1.
        volume: number

        --- Pitch multiplier.
        pitch: number

        --- Random pitch variance +/-.
        pitchVariance: number

        --- Whether the sound loops.
        looping: boolean

        --- Whether currently playing.
        playing: boolean

        --- If true, ignore Transform (for UI/ambient).
        relative: boolean

        --- Reference distance for attenuation.
        refDistance: number

        --- Max distance for attenuation.
        maxDistance: number

        --- Internal: the cloned source instance.
        _source: love.audio.Source

        --- Internal: last group registered with the manager, used to detect
        --- group changes and re-register.
        _appliedGroup: string

        --- Internal: last relative state applied to the source, used to detect
        --- changes that require re-initialization.
        _appliedRelative: boolean

        --- Internal: pitch variance offset rolled at (re)trigger time and
        --- held for the whole playback.
        _pitchOffset: number

        --- Internal: whether the source was playing on the previous update;
        --- distinguishes a finished one-shot from a not-yet-started source.
        _wasPlaying: boolean

        --- Create a new AudioSource component.
        metamethod __call: function(self, config: AudioSourceConfig): AudioSource
    end

    --- Tag component marking an entity as the audio listener.
    record AudioListener is Component
        metamethod __call: function(self): AudioListener
    end

end

return types
