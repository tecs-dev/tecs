local tecs_assets <const> = require("tecs2d.assets")
local types <const> = require("tecs2d.audio.internal.types")

local la_setPosition <const> = love.audio.setPosition

local type PlayOptions = types.PlayOptions
local type SoundGroup = types.SoundGroup
local type SourceInfo = types.SourceInfo

--- Effect settings type.
local type EffectSettings = boolean | {string:any}

--- Group effects tracking.
local record GroupEffects
    effects: {string: EffectSettings}
end

--- Internal implementation of the AudioManager.
local record AudioManagerImpl is types.AudioManager
    _groups: {string: SoundGroup}
    _groupEffects: {string: GroupEffects}
    _voiceLimits: {string: integer}
    _voiceCounts: {string: integer}
    _cooldowns: {string: number}
    _cooldownDurations: {string: number}
    _activeSources: {love.audio.Source: SourceInfo}
    _componentSources: {love.audio.Source: SourceInfo}  -- AudioSource component sources
    _listenerX: number
    _listenerY: number
    _listenerZ: number
end

local AudioManagerImpl_mt: metatable<AudioManagerImpl> = {
    __index = AudioManagerImpl
}

--- Default sound groups with their initial volumes.
local DEFAULT_GROUPS <const>: {string: number} = {
    master = 1.0,
    music = 0.8,
    sfx = 1.0,
    ui = 1.0
}

-------------------------------------------------------------------------------
--- Constructor
-------------------------------------------------------------------------------

--- Creates a new AudioManager.
--- @return A new AudioManager instance.
function AudioManagerImpl.new(): AudioManagerImpl
    local groups: {string: SoundGroup} = {}
    for name, volume in pairs(DEFAULT_GROUPS) do
        groups[name] = {
            volume = volume,
            muted = false,
            paused = false
        }
    end

    local self: AudioManagerImpl = setmetatable({
        _groups = groups,
        _groupEffects = {},
        _voiceLimits = {},
        _voiceCounts = {},
        _cooldowns = {},
        _cooldownDurations = {},
        _activeSources = {},
        _componentSources = {},
        _listenerX = 0,
        _listenerY = 0,
        _listenerZ = 0
    }, AudioManagerImpl_mt)

    return self
end

-------------------------------------------------------------------------------
--- Group Management
-------------------------------------------------------------------------------

local function ensureGroup(self: AudioManagerImpl, name: string): SoundGroup
    local group = self._groups[name]
    if not group then
        group = { volume = 1.0, muted = false, paused = false }
        self._groups[name] = group
    end
    return group
end

local function computeEffectiveVolume(self: AudioManagerImpl, groupName: string, volume: number): number
    local masterGroup = self._groups["master"]
    if masterGroup and masterGroup.muted then
        return 0
    end
    local group = self._groups[groupName]
    if not group then
        return volume
    end
    if group.muted then
        return 0
    end
    -- A muted master silences every group.
    local masterVolume = 1.0
    if masterGroup then
        masterVolume = masterGroup.muted and 0 or masterGroup.volume
    end
    return volume * group.volume * masterVolume
end

local function applyEffectiveVolume(self: AudioManagerImpl, source: love.audio.Source, info: SourceInfo)
    local effectiveVol = computeEffectiveVolume(self, info.group, info.baseVolume or 1.0)
    if info.fadeDuration > 0 then
        if effectiveVol == 0 then
            -- Mute-style change: silence immediately and pin both fade
            -- endpoints to 0 so update() can't lerp the volume back up;
            -- fade completion bookkeeping (paused / stopAfterFade) still
            -- fires when the timer elapses.
            info.fadeStartVolume = 0
            info.targetVolume = 0
            source:setVolume(0)
        elseif info.targetVolume > 0 then
            -- Retarget in-progress fade-ins to the new level. Fade-outs
            -- (target 0, from stop/pause fades) keep heading to 0 so
            -- their completion semantics hold.
            info.targetVolume = effectiveVol
        end
    else
        source:setVolume(effectiveVol)
    end
end

local function applyVolumeToSources(self: AudioManagerImpl, groupName: string)
    -- When a "master" setting changes, every group's effective volume
    -- shifts, so we walk all sources. Otherwise only the named group.
    local isMaster <const> = (groupName == "master")
    for source, info in pairs(self._activeSources) do
        if isMaster or info.group == groupName then
            applyEffectiveVolume(self, source, info)
        end
    end
    for source, info in pairs(self._componentSources) do
        if isMaster or info.group == groupName then
            applyEffectiveVolume(self, source, info)
        end
    end
end

function AudioManagerImpl:setGroupVolume(name: string, volume: number)
    local group = ensureGroup(self, name)
    group.volume = math.max(0, math.min(1, volume))
    -- Apply the new effective volume to live active and component sources so
    -- setGroupVolume works as a live-mixer control.
    applyVolumeToSources(self, name)
end

function AudioManagerImpl:getGroupVolume(name: string): number
    local group = self._groups[name]
    if not group then
        return 1.0
    end
    return group.volume
end

function AudioManagerImpl:muteGroup(name: string, muted: boolean)
    local group = ensureGroup(self, name)
    group.muted = muted

    -- Route through the shared volume application: it fans a "master"
    -- mute out to every group, covers component sources, and silences
    -- sources mid-fade instead of letting the fade lerp them back up.
    applyVolumeToSources(self, name)
end

function AudioManagerImpl:isGroupMuted(name: string): boolean
    local group = self._groups[name]
    if not group then
        return false
    end
    return group.muted
end

-------------------------------------------------------------------------------
--- Voice Limiting
-------------------------------------------------------------------------------

function AudioManagerImpl:setVoiceLimit(key: string, maxVoices: integer)
    self._voiceLimits[key] = maxVoices
end

local function canPlayVoice(self: AudioManagerImpl, key: string): boolean
    if not key then
        return true
    end
    local limit = self._voiceLimits[key]
    if not limit or limit <= 0 then
        return true
    end
    local count = self._voiceCounts[key] or 0
    return count < limit
end

local function incrementVoiceCount(self: AudioManagerImpl, key: string)
    if key then
        self._voiceCounts[key] = (self._voiceCounts[key] or 0) + 1
    end
end

local function decrementVoiceCount(self: AudioManagerImpl, key: string)
    if key then
        local count = self._voiceCounts[key]
        if count and count > 0 then
            self._voiceCounts[key] = count - 1
        end
    end
end

-------------------------------------------------------------------------------
--- Cooldowns
-------------------------------------------------------------------------------

function AudioManagerImpl:setCooldown(key: string, seconds: number)
    self._cooldownDurations[key] = seconds
end

function AudioManagerImpl:isOnCooldown(key: string): boolean
    if not key then
        return false
    end
    local remaining = self._cooldowns[key]
    return remaining ~= nil and remaining > 0
end

local function startCooldown(self: AudioManagerImpl, key: string)
    if key then
        local duration = self._cooldownDurations[key]
        if duration and duration > 0 then
            self._cooldowns[key] = duration
        end
    end
end

-------------------------------------------------------------------------------
--- Pitch Variance
-------------------------------------------------------------------------------

local function applyPitchVariance(pitch: number, variance: number): number
    if variance <= 0 then
        return pitch
    end
    local offset = (math.random() * 2 - 1) * variance
    return pitch + offset
end

-------------------------------------------------------------------------------
--- Play API
-------------------------------------------------------------------------------

local function applyGroupEffects(self: AudioManagerImpl, source: love.audio.Source, groupName: string)
    local ge = self._groupEffects[groupName]
    if ge and ge.effects then
        for effectName, _ in pairs(ge.effects) do
            local globalEffectName = groupName .. "_" .. effectName
            local setEffect = source.setEffect as function(love.audio.Source, string, boolean): boolean
            setEffect(source, globalEffectName, true)
        end
    end
end

local function playInternal(
    self: AudioManagerImpl,
    handle: tecs_assets.Handle<love.audio.Source>,
    options: PlayOptions,
    isPositional: boolean,
    x: number,
    y: number,
    z: number
): love.audio.Source
    if not handle.isComplete then
        return nil
    end

    local groupName = options.group or "sfx"
    local volume = options.volume or 1.0
    local pitch = options.pitch or 1.0
    local pitchVariance = options.pitchVariance or 0
    local key = options.key
    local fadeIn = options.fadeIn or 0
    local loop = options.loop or false

    -- Check cooldown
    if self:isOnCooldown(key) then
        return nil
    end

    -- Check voice limit
    if not canPlayVoice(self, key) then
        return nil
    end

    -- Clone and configure source
    local source = handle.value:clone()
    source:setRelative(not isPositional)
    source:setPosition(x, y, z)
    source:setPitch(applyPitchVariance(pitch, pitchVariance))
    source:setLooping(loop)

    -- Apply group effects
    applyGroupEffects(self, source, groupName)

    local targetVolume = computeEffectiveVolume(self, groupName, volume)
    if fadeIn > 0 then
        source:setVolume(0)
    else
        source:setVolume(targetVolume)
    end

    -- A paused group holds new sounds too: register them paused so
    -- resumeGroup starts them, instead of playing through the pause.
    local group = ensureGroup(self, groupName)
    local startPaused = group.paused
    if not startPaused then
        source:play()
    end

    -- Track source
    self._activeSources[source] = {
        group = groupName,
        key = key,
        baseVolume = volume,
        targetVolume = targetVolume,
        fadeDuration = fadeIn,
        fadeElapsed = 0,
        fadeStartVolume = 0,
        stopAfterFade = false,
        paused = startPaused
    }
    incrementVoiceCount(self, key)
    startCooldown(self, key)

    return source
end

function AudioManagerImpl:play(handle: tecs_assets.Handle<love.audio.Source>, options?: PlayOptions): love.audio.Source
    return playInternal(self, handle, options or {}, false, 0, 0, 0)
end

function AudioManagerImpl:playAt(
    handle: tecs_assets.Handle<love.audio.Source>, x: number, y: number, z: number, options?: PlayOptions
): love.audio.Source
    return playInternal(self, handle, options or {}, true, x, y, z)
end

-------------------------------------------------------------------------------
--- Control
-------------------------------------------------------------------------------

local function startFadeOut(info: SourceInfo, source: love.audio.Source, duration: number, stopAfter: boolean)
    info.fadeStartVolume = source:getVolume()
    info.targetVolume = 0
    info.fadeDuration = duration
    info.fadeElapsed = 0
    info.stopAfterFade = stopAfter
end

local function startFadeIn(info: SourceInfo, source: love.audio.Source, duration: number, self: AudioManagerImpl)
    info.fadeStartVolume = source:getVolume()
    info.targetVolume = computeEffectiveVolume(self, info.group, info.baseVolume)
    info.fadeDuration = duration
    info.fadeElapsed = 0
    info.stopAfterFade = false
end

function AudioManagerImpl:stopGroup(name: string, fadeDuration?: number)
    fadeDuration = fadeDuration or 0
    for source, info in pairs(self._activeSources) do
        if info.group == name then
            if fadeDuration > 0 then
                startFadeOut(info, source, fadeDuration, true)
            else
                source:stop()
                decrementVoiceCount(self, info.key)
                self._activeSources[source] = nil
            end
        end
    end
end

function AudioManagerImpl:stopAll(fadeDuration?: number)
    fadeDuration = fadeDuration or 0
    for source, info in pairs(self._activeSources) do
        if fadeDuration > 0 then
            startFadeOut(info, source, fadeDuration, true)
        else
            source:stop()
            decrementVoiceCount(self, info.key)
            self._activeSources[source] = nil
        end
    end

    -- Also stop component sources. We use the back-ref to flip
    -- audioSrc.playing = false and clear _source so the next audio sync
    -- doesn't see audioSrc.playing == true and immediately restart the
    -- sound (which would make stopAll() a no-op for components).
    -- Instant-stop path only; fading a component source would be quickly
    -- overridden by the per-frame sync anyway.
    for source, info in pairs(self._componentSources) do
        source:stop()
        if info.audioSrc then
            info.audioSrc.playing = false
            info.audioSrc._source = nil
            info.audioSrc._appliedGroup = nil
            info.audioSrc._appliedRelative = nil
        end
        self._componentSources[source] = nil
    end
end

function AudioManagerImpl:pauseGroup(name: string, fadeDuration?: number)
    fadeDuration = fadeDuration or 0
    local group = ensureGroup(self, name)
    group.paused = true

    for source, info in pairs(self._activeSources) do
        if info.group == name and not info.paused then
            if fadeDuration > 0 then
                startFadeOut(info, source, fadeDuration, false)
                info.paused = true
            else
                source:pause()
                info.paused = true
            end
        end
    end

    -- Also pause component sources. Only mark/pause sources that are
    -- currently playing; non-looping component sources that already
    -- finished would otherwise get resumeGroup'd back to life on the
    -- next resume.
    for source, info in pairs(self._componentSources) do
        if info.group == name and not info.paused and source:isPlaying() then
            if fadeDuration > 0 then
                startFadeOut(info, source, fadeDuration, false)
                info.paused = true
            else
                source:pause()
                info.paused = true
            end
        end
    end
end

function AudioManagerImpl:resumeGroup(name: string, fadeDuration?: number)
    fadeDuration = fadeDuration or 0
    local group = ensureGroup(self, name)
    group.paused = false

    for source, info in pairs(self._activeSources) do
        if info.group == name and info.paused then
            source:play()
            info.paused = false
            if fadeDuration > 0 then
                startFadeIn(info, source, fadeDuration, self)
            else
                local targetVol = computeEffectiveVolume(self, info.group, info.baseVolume)
                source:setVolume(targetVol)
            end
        end
    end

    -- Also resume component sources
    for source, info in pairs(self._componentSources) do
        if info.group == name and info.paused then
            source:play()
            info.paused = false
            if fadeDuration > 0 then
                startFadeIn(info, source, fadeDuration, self)
            else
                local targetVol = computeEffectiveVolume(self, info.group, info.baseVolume)
                source:setVolume(targetVol)
            end
        end
    end
end

function AudioManagerImpl:isGroupPaused(name: string): boolean
    local group = self._groups[name]
    return group ~= nil and group.paused
end

function AudioManagerImpl:stop(source: love.audio.Source, fadeDuration?: number)
    local info = self._activeSources[source]
    if not info then return end

    fadeDuration = fadeDuration or 0
    if fadeDuration > 0 then
        startFadeOut(info, source, fadeDuration, true)
    else
        source:stop()
        decrementVoiceCount(self, info.key)
        self._activeSources[source] = nil
    end
end

function AudioManagerImpl:pause(source: love.audio.Source, fadeDuration?: number)
    local info = self._activeSources[source]
    if not info or info.paused then return end

    fadeDuration = fadeDuration or 0
    if fadeDuration > 0 then
        startFadeOut(info, source, fadeDuration, false)
        info.paused = true
    else
        source:pause()
        info.paused = true
    end
end

function AudioManagerImpl:resume(source: love.audio.Source, fadeDuration?: number)
    local info = self._activeSources[source]
    if not info or not info.paused then return end

    fadeDuration = fadeDuration or 0
    source:play()
    info.paused = false

    if fadeDuration > 0 then
        startFadeIn(info, source, fadeDuration, self)
    else
        local targetVol = computeEffectiveVolume(self, info.group, info.baseVolume)
        source:setVolume(targetVol)
    end
end

-------------------------------------------------------------------------------
--- Effects
-------------------------------------------------------------------------------

function AudioManagerImpl:setGroupEffect(groupName: string, effectName: string, settings: {string:any})
    local ge = self._groupEffects[groupName]
    if not ge then
        ge = { effects = {} }
        self._groupEffects[groupName] = ge
    end
    ge.effects[effectName] = settings

    -- Define the effect globally in LÖVE's audio system
    -- The effect name is scoped to the group to avoid conflicts
    local globalEffectName = groupName .. "_" .. effectName
    local effectSettings = { type = effectName } as {string:any}
    for k, v in pairs(settings) do
        effectSettings[k] = v
    end
    local setGlobalEffect = love.audio.setEffect as function(string, {string:any}): boolean
    local success = setGlobalEffect(globalEffectName, effectSettings)
    if not success then
        return
    end

    -- Enable effect on all current sources in this group
    for source, info in pairs(self._activeSources) do
        if info.group == groupName then
            local setEffect = source.setEffect as function(love.audio.Source, string, boolean): boolean
            setEffect(source, globalEffectName, true)
        end
    end

    -- Also apply to component sources
    for source, info in pairs(self._componentSources) do
        if info.group == groupName then
            local setEffect = source.setEffect as function(love.audio.Source, string, boolean): boolean
            setEffect(source, globalEffectName, true)
        end
    end
end

function AudioManagerImpl:removeGroupEffect(groupName: string, effectName: string)
    local ge = self._groupEffects[groupName]
    if ge and ge.effects then
        ge.effects[effectName] = nil
    end

    local globalEffectName = groupName .. "_" .. effectName

    -- Remove from all current sources in this group
    for source, info in pairs(self._activeSources) do
        if info.group == groupName then
            local setEffect = source.setEffect as function(love.audio.Source, string, boolean): boolean
            setEffect(source, globalEffectName, false)
        end
    end

    -- Also remove from component sources
    for source, info in pairs(self._componentSources) do
        if info.group == groupName then
            local setEffect = source.setEffect as function(love.audio.Source, string, boolean): boolean
            setEffect(source, globalEffectName, false)
        end
    end

    -- Free the global effect slot. Effect names are scoped per group, so
    -- no other group can be using this one; without this, repeated
    -- set/remove cycles with distinct names exhaust LÖVE's limited
    -- effect slots.
    local clearGlobalEffect = love.audio.setEffect as function(string, boolean): boolean
    clearGlobalEffect(globalEffectName, false)
end

-------------------------------------------------------------------------------
--- Update
-------------------------------------------------------------------------------

local function lerp(a: number, b: number, t: number): number
    return a + (b - a) * t
end

function AudioManagerImpl:update(dt: number)
    -- Decrement cooldowns
    for key, remaining in pairs(self._cooldowns) do
        remaining = remaining - dt
        if remaining <= 0 then
            self._cooldowns[key] = nil
        else
            self._cooldowns[key] = remaining
        end
    end

    -- Process fades and cleanup finished sources
    for source, info in pairs(self._activeSources) do
        -- Handle fading
        if info.fadeDuration > 0 then
            info.fadeElapsed = info.fadeElapsed + dt
            local t = math.min(1, info.fadeElapsed / info.fadeDuration)
            local currentVol = lerp(info.fadeStartVolume, info.targetVolume, t)
            source:setVolume(currentVol)

            if t >= 1 then
                info.fadeDuration = 0
                if info.stopAfterFade then
                    source:stop()
                    decrementVoiceCount(self, info.key)
                    self._activeSources[source] = nil
                elseif info.paused and info.targetVolume == 0 then
                    source:pause()
                end
            end
        elseif not info.paused and not source:isPlaying() then
            -- Cleanup finished sources (not paused, not fading)
            decrementVoiceCount(self, info.key)
            self._activeSources[source] = nil
        end
    end

    -- Process fades for component sources (no cleanup - managed by components)
    for source, info in pairs(self._componentSources) do
        if info.fadeDuration > 0 then
            info.fadeElapsed = info.fadeElapsed + dt
            local t = math.min(1, info.fadeElapsed / info.fadeDuration)
            local currentVol = lerp(info.fadeStartVolume, info.targetVolume, t)
            source:setVolume(currentVol)

            if t >= 1 then
                info.fadeDuration = 0
                if info.paused and info.targetVolume == 0 then
                    source:pause()
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
--- Component Source Registration (for AudioSource components)
-------------------------------------------------------------------------------

function AudioManagerImpl:registerComponentSource(source: love.audio.Source, group: string, baseVolume: number, audioSrc?: types.AudioSource)
    local effectiveVolume = computeEffectiveVolume(self, group, baseVolume)
    self._componentSources[source] = {
        group = group,
        key = nil,
        baseVolume = baseVolume,
        targetVolume = effectiveVolume,
        fadeDuration = 0,
        fadeElapsed = 0,
        fadeStartVolume = 0,
        stopAfterFade = false,
        paused = false,
        audioSrc = audioSrc
    }

    -- Apply effective volume to source
    source:setVolume(effectiveVolume)

    -- Apply group effects (effects are already defined globally)
    local ge = self._groupEffects[group]
    if ge and ge.effects then
        for effectName, _ in pairs(ge.effects) do
            local globalEffectName = group .. "_" .. effectName
            local setEffect = source.setEffect as function(love.audio.Source, string, boolean): boolean
            setEffect(source, globalEffectName, true)
        end
    end
end

function AudioManagerImpl:unregisterComponentSource(source: love.audio.Source)
    self._componentSources[source] = nil
end

function AudioManagerImpl:refreshComponentSource(source: love.audio.Source, audioSrc: types.AudioSource)
    local info = self._componentSources[source]
    if not info then return end

    -- Re-apply mutable fields so gameplay mutations on the component take
    -- effect. Group change updates tracking (effects won't migrate; that's
    -- documented as an immutable-after-init field). Volume always flows
    -- through computeEffectiveVolume so group/master volume stay honored.
    if info.group ~= audioSrc.group then
        info.group = audioSrc.group
    end
    info.baseVolume = audioSrc.volume

    if info.fadeDuration == 0 and not info.paused then
        local effectiveVol = computeEffectiveVolume(self, info.group, info.baseVolume)
        source:setVolume(effectiveVol)
    end

    source:setLooping(audioSrc.looping)
    if not audioSrc.relative then
        source:setAttenuationDistances(audioSrc.refDistance, audioSrc.maxDistance)
    end
end

function AudioManagerImpl:shouldComponentSourcePlay(source: love.audio.Source): boolean
    local info = self._componentSources[source]
    if not info then return true end
    -- Don't interfere if managed by a fade or already paused
    if info.fadeDuration > 0 or info.paused then return false end
    local group = self._groups[info.group]
    return not (group and group.paused)
end

function AudioManagerImpl:isComponentSourceFading(source: love.audio.Source): boolean
    local info = self._componentSources[source]
    return info ~= nil and info.fadeDuration > 0
end

-------------------------------------------------------------------------------
--- Listener
-------------------------------------------------------------------------------

function AudioManagerImpl:setListenerPosition(x: number, y: number, z: number)
    self._listenerX = x
    self._listenerY = y
    self._listenerZ = z
    la_setPosition(x, y, z)
end

-------------------------------------------------------------------------------
--- Snapshot
-------------------------------------------------------------------------------

function AudioManagerImpl:serializeMixer(): {string:any}
    local groups: {string: {string:any}} = {}
    for name, g in pairs(self._groups) do
        groups[name] = {
            volume = g.volume,
            muted = g.muted,
            paused = g.paused,
        }
    end
    return {
        groups = groups,
        listenerX = self._listenerX,
        listenerY = self._listenerY,
        listenerZ = self._listenerZ,
    }
end

function AudioManagerImpl:restoreMixer(data: {string:any})
    if not data then return end

    local groups = data.groups as {string: {string:any}}
    if groups then
        for name, g in pairs(groups) do
            -- Raw-set `paused` so we don't fade/pause live sources; restored
            -- component sources check the flag when the play systems run.
            local group = ensureGroup(self, name)
            group.paused = g.paused == true
            -- setGroupVolume/muteGroup re-apply the restored levels to any
            -- sources the load-time lifecycle observers already registered
            -- (they were registered against the pre-restore group volumes).
            self:setGroupVolume(name, (g.volume as number) or group.volume)
            self:muteGroup(name, g.muted == true)
        end
    end

    local lx = data.listenerX as number
    local ly = data.listenerY as number
    local lz = data.listenerZ as number
    if lx ~= nil and ly ~= nil and lz ~= nil then
        self:setListenerPosition(lx, ly, lz)
    end
end

-------------------------------------------------------------------------------
--- Module
-------------------------------------------------------------------------------

local record manager
    new: function(): AudioManagerImpl
end

manager.new = AudioManagerImpl.new

return manager
