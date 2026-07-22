local tecs <const> = require("tecs")
local manager <const> = require("tecs2d.audio.internal.manager")
local types <const> = require("tecs2d.audio.internal.types")

local Transform <const> = tecs.builtins.Transform

local DEFAULT_REF_DISTANCE <const> = 100
local DEFAULT_MAX_DISTANCE <const> = 1000

--- A unified audio system for Tecs providing spatial audio, sound groups
--- with volume control, voice limiting, and cooldowns.
---
--- `tecs2d.run` installs the audio plugin automatically. Access the audio
--- manager via world resources:
---
--- ```lua
--- local audio = require("tecs2d.audio")
--- local audioManager = world.resources[audio]
--- audioManager:play(soundHandle, { group = "sfx" })
--- audioManager:playAt(soundHandle, x, y, z, { group = "sfx" })
--- ```
local record audio is tecs.Key<types.AudioManager>
    type AudioManager = types.AudioManager
    type PlayOptions = types.PlayOptions
    type SoundGroup = types.SoundGroup
    type AudioSourceConfig = types.AudioSourceConfig

    --- Component for continuous/looping sounds attached to entities.
    AudioSource: types.AudioSource

    --- Tag component marking an entity as the audio listener.
    AudioListener: types.AudioListener

    --- Creates a new AudioManager instance.
    --- @return A new AudioManager.
    new: function(): types.AudioManager

    --- Creates a plugin that adds audio systems to the world.
    --- @return A plugin function to add to the world.
    plugin: function(): tecs.Plugin

    --- Handle type alias for convenience.
    type Handle<T> = types.Handle<T>
end

-------------------------------------------------------------------------------
--- Component Definitions
-------------------------------------------------------------------------------

audio.AudioListener = tecs.newTagComponent({
    name = "AudioListener"
}) as types.AudioListener

audio.AudioSource = tecs.newComponent({
    name = "AudioSource",
    container = types.AudioSource,
    new = function(data: {string: any}): types.AudioSource
        local config = data as types.AudioSourceConfig
        assert(config.handle, "AudioSource requires a handle")
        return {
            handle = config.handle,
            group = config.group or "sfx",
            volume = config.volume or 1.0,
            pitch = config.pitch or 1.0,
            pitchVariance = config.pitchVariance or 0,
            looping = config.looping or false,
            playing = config.playing ~= false,  -- default true
            relative = config.relative or false,
            refDistance = config.refDistance or DEFAULT_REF_DISTANCE,
            maxDistance = config.maxDistance or DEFAULT_MAX_DISTANCE,
            _source = nil,
            _appliedGroup = nil,
            _appliedRelative = nil,
        }
    end,
    serialize = function(src: types.AudioSource): {string: any}
        local handle = src.handle
        if not handle then return nil end
        local assets_module <const> = require("tecs2d.assets")
        local descriptor = assets_module.describe(handle)
        if not descriptor or descriptor.action ~= "loadAudio" then return nil end
        local args = descriptor.args
        return {
            path          = descriptor.inputPath,
            sourceType    = args and args[1] or "static",
            streamType    = args and args[2] or nil,
            group         = src.group,
            volume        = src.volume,
            pitch         = src.pitch,
            pitchVariance = src.pitchVariance,
            looping       = src.looping,
            playing       = src.playing,
            relative      = src.relative,
            refDistance    = src.refDistance,
            maxDistance    = src.maxDistance,
        }
    end,
    deserialize = function(_world: tecs.World, data: {string: any}): types.AudioSource
        if not data then return nil end
        local assets_module <const> = require("tecs2d.assets")
        local handle = assets_module.loadAudio(
            data.path as string,
            (data.sourceType as love.audio.SourceType) or "static",
            data.streamType as string
        ) as types.Handle<love.audio.Source>
        return types.AudioSource.new({
            handle        = handle,
            group         = data.group as string,
            volume        = data.volume as number,
            pitch         = data.pitch as number,
            pitchVariance = data.pitchVariance as number,
            looping       = data.looping as boolean,
            playing       = data.playing as boolean,
            relative      = data.relative as boolean,
            refDistance    = data.refDistance as number,
            maxDistance    = data.maxDistance as number,
        } as types.AudioSourceConfig)
    end,
})

-------------------------------------------------------------------------------
--- Constructor
-------------------------------------------------------------------------------

function audio.new(): types.AudioManager
    return manager.new()
end

-------------------------------------------------------------------------------
--- Plugin
-------------------------------------------------------------------------------

function audio.plugin(): tecs.Plugin
    return function(world: tecs.World)
        local audioManager = manager.new()
        world.resources[audio] = audioManager

        -- The audio manager is a world resource, so its mixer state (group
        -- volumes, mutes, pauses, listener position) lives outside the ECS
        -- and is not captured by the core snapshot. Persist it explicitly.
        -- Component sources themselves round-trip via AudioSource; they get
        -- recreated by the lifecycle observers below, and restoreMixer
        -- re-applies the restored group levels to them.
        world:addSnapshotHandler({
            name = "tecs2d.audio.mixer",
            save = function(_world: tecs.World): any
                return audioManager:serializeMixer()
            end,
            load = function(_world: tecs.World, value: any)
                audioManager:restoreMixer(value as {string:any})
            end,
        })

        -- Set up listener orientation for 2D games with screen coordinates (+X right, +Y down).
        -- Forward faces +Z (into the screen), up is +Y. This ensures +X maps to right speaker.
        love.audio.setOrientation(0, 0, 1, 0, 1, 0)

        -- Create queries
        local listenerQuery = world:query({
            name = "audio.Listener",
            include = {audio.AudioListener, Transform}
        })

        -----------------------------------------------------------------------
        --- Helper: Teardown a component source (stop, unregister, clear).
        -----------------------------------------------------------------------
        local function teardownSource(audioSrc: types.AudioSource)
            local src = audioSrc._source
            if src then
                src:stop()
                audioManager:unregisterComponentSource(src)
                audioSrc._source = nil
                audioSrc._appliedGroup = nil
                audioSrc._appliedRelative = nil
            end
        end

        -- Cleanup query: fires onEntitiesRemoved whenever an AudioSource is
        -- removed (or its entity despawns). Match only {AudioSource} so the callback
        -- doesn't fire when Transform is added/removed on an entity that
        -- still holds its AudioSource.
        world:query({
            name = "audio.Cleanup",
            include = {audio.AudioSource},
            onEntitiesRemoved = function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
                local sources = archetype:getMut(audio.AudioSource) as {types.AudioSource}
                for row = firstRow, lastRow do
                    local audioSrc = sources[row]
                    if audioSrc then
                        teardownSource(audioSrc)
                    end
                end
            end
        })

        local sourceQuery = world:query({
            name = "audio.Sources",
            include = {audio.AudioSource, Transform}
        })

        local relativeSourceQuery = world:query({
            name = "audio.RelativeSources",
            include = {audio.AudioSource},
            exclude = {Transform}
        })

        -----------------------------------------------------------------------
        --- Helper: Initialize a source from an AudioSource component
        -----------------------------------------------------------------------
        local function initializeSource(audioSrc: types.AudioSource, isRelative: boolean)
            if not audioSrc.handle or not audioSrc.handle.isComplete then return end
            -- A completed handle may hold an error; dereferencing .value would raise.
            if audioSrc.handle.err then return end
            local src = audioSrc.handle.value:clone()
            src:setRelative(isRelative)
            src:setLooping(audioSrc.looping)
            if isRelative then
                src:setPosition(0, 0, 0)
            else
                src:setAttenuationDistances(audioSrc.refDistance, audioSrc.maxDistance)
            end
            audioSrc._source = src
            audioSrc._appliedGroup = audioSrc.group
            audioSrc._appliedRelative = isRelative
            audioManager:registerComponentSource(src, audioSrc.group, audioSrc.volume, audioSrc)
        end

        -----------------------------------------------------------------------
        --- Helper: If the component's group or relative flag changed since
        --- last init, tear down and re-initialize. Other mutable fields
        --- (volume, looping, attenuation) flow through refreshComponentSource
        --- each frame and don't require a re-init.
        -----------------------------------------------------------------------
        local function reinitIfStructuralChange(audioSrc: types.AudioSource, isRelative: boolean)
            if not audioSrc._source then return end
            if audioSrc._appliedGroup ~= audioSrc.group
                or audioSrc._appliedRelative ~= isRelative then
                teardownSource(audioSrc)
                if audioSrc.handle.isComplete then
                    initializeSource(audioSrc, isRelative)
                end
            end
        end

        -----------------------------------------------------------------------
        --- Helper: Apply pitch with optional variance. The variance offset
        --- is rolled once per (re)trigger in updatePlayState and held for
        --- the whole playback.
        -----------------------------------------------------------------------
        local function applyPitch(audioSrc: types.AudioSource)
            audioSrc._source:setPitch(audioSrc.pitch + (audioSrc._pitchOffset or 0))
        end

        -----------------------------------------------------------------------
        --- Helper: Update play state based on component and manager state
        -----------------------------------------------------------------------
        local function updatePlayState(audioSrc: types.AudioSource)
            local src = audioSrc._source
            local canPlay = audioManager:shouldComponentSourcePlay(src)
            local isFading = audioManager:isComponentSourceFading(src)
            if audioSrc.playing and canPlay and not src:isPlaying() then
                if audioSrc._wasPlaying and not audioSrc.looping then
                    -- A one-shot that reached its natural end: clear the
                    -- declarative flag instead of retriggering forever.
                    audioSrc.playing = false
                    audioSrc._wasPlaying = false
                else
                    if audioSrc.pitchVariance > 0 then
                        audioSrc._pitchOffset = (math.random() * 2 - 1) * audioSrc.pitchVariance
                    end
                    src:play()
                    audioSrc._wasPlaying = true
                end
            elseif not isFading and (not audioSrc.playing or not canPlay) and src:isPlaying() then
                src:stop()
                audioSrc._wasPlaying = false
            end
        end

        -----------------------------------------------------------------------
        --- System: Update Listener
        -----------------------------------------------------------------------
        world:addSystem({
            name = "audio.UpdateListener",
            phase = tecs.phases.PostUpdate,
            run = function(_dt: number)
                -- Only the first listener is used; returning mid-iteration would
                -- leave the world in deferred scope, so finish the loop instead.
                local found = false
                local x, y, z = 0.0, 0.0, 0.0
                for archetype, len in listenerQuery:iter() do
                    if not found and len > 0 then
                        local t = archetype:get(Transform)[1]
                        x, y, z = t.x, t.y, t.z
                        found = true
                    end
                end
                if found then
                    audioManager:setListenerPosition(x, y, z)
                end
            end
        })

        -----------------------------------------------------------------------
        --- System: Update AudioSources (positional)
        -----------------------------------------------------------------------
        -----------------------------------------------------------------------
        --- Helper: Per-frame sync for a relative (non-positional) source:
        --- init when the handle completes, re-init on structural change, then
        --- refresh mutable fields and play state.
        -----------------------------------------------------------------------
        local function updateRelativeSource(audioSrc: types.AudioSource)
            if audioSrc.handle.isComplete and not audioSrc._source then
                initializeSource(audioSrc, true)
            end

            reinitIfStructuralChange(audioSrc, true)

            if audioSrc._source then
                audioManager:refreshComponentSource(audioSrc._source, audioSrc)
                applyPitch(audioSrc)
                updatePlayState(audioSrc)
            end
        end

        -----------------------------------------------------------------------
        --- System: Update AudioSources with a Transform. Relative rows take
        --- the non-positional path in the same iteration, so the query is
        --- only walked once per frame.
        -----------------------------------------------------------------------
        world:addSystem({
            name = "audio.UpdateSources",
            phase = tecs.phases.PostUpdate,
            run = function(_dt: number)
                for archetype, len in sourceQuery:iter() do
                    local sources = archetype:getMut(audio.AudioSource)
                    local transforms = archetype:get(Transform)

                    for i = 1, len do
                        local audioSrc = sources[i]

                        if audioSrc.relative then
                            updateRelativeSource(audioSrc)
                            goto continue
                        end

                        -- Initialize source if handle is ready
                        if audioSrc.handle.isComplete and not audioSrc._source then
                            initializeSource(audioSrc, false)
                        end

                        -- Re-initialize if a structural field (group, relative)
                        -- changed since the last init.
                        reinitIfStructuralChange(audioSrc, false)

                        if audioSrc._source then
                            local transform = transforms[i]
                            audioSrc._source:setPosition(transform.x, transform.y, transform.z)
                            audioManager:refreshComponentSource(audioSrc._source, audioSrc)
                            applyPitch(audioSrc)
                            updatePlayState(audioSrc)
                        end

                        ::continue::
                    end
                end
            end
        })

        -----------------------------------------------------------------------
        --- System: Update AudioSources without a Transform (always relative)
        -----------------------------------------------------------------------
        world:addSystem({
            name = "audio.UpdateRelativeSources",
            phase = tecs.phases.PostUpdate,
            run = function(_dt: number)
                for archetype, len in relativeSourceQuery:iter() do
                    local sources = archetype:getMut(audio.AudioSource)

                    for i = 1, len do
                        updateRelativeSource(sources[i])
                    end
                end
            end
        })

        -----------------------------------------------------------------------
        --- System: Cleanup
        -----------------------------------------------------------------------
        world:addSystem({
            name = "audio.Cleanup",
            phase = tecs.phases.Last,
            run = function(dt: number)
                audioManager:update(dt)
            end
        })

        -----------------------------------------------------------------------
        --- System: Shutdown
        -----------------------------------------------------------------------
        world:addSystem({
            name = "audio.Shutdown",
            phase = tecs.phases.Shutdown,
            run = function(_dt: number)
                audioManager:stopAll()
            end
        })
    end
end

return audio
