--- The process-global program registry.
---
--- Programs are keyed by name, and every name can have several versions
--- alive at once: redefining a name compiles a new one, and a playback keeps
--- the version it started with so a hot reload continues rather than resuming
--- into changed instructions.
---
--- A version is held by the playbacks running it and dropped when the last
--- one finishes, is cancelled, or is discarded by a snapshot load. The newest
--- version of a name is never dropped: that is the one `play` resolves.
---
--- Global rather than per world, because a program is code: two worlds
--- playing the same name are running the same instructions.

local seqprogram <const> = require("tecs2d.sequence.internal.program")
local seqtypes <const> = require("tecs2d.sequence.internal.types")

local type ProgramImpl = seqtypes.ProgramImpl

local record registry
    --- The newest version of a name, or nil.
    newest: function(name: string): ProgramImpl

    --- One specific version of a name, or nil once it has been dropped.
    version: function(name: string, version: integer): ProgramImpl

    --- Every defined name, sorted.
    names: function(): {string}

    --- The version number a fresh compile of `name` should carry.
    nextVersion: function(name: string): integer

    --- Record a freshly compiled version as the newest of its name.
    publish: function(prog: ProgramImpl)

    --- Rebuild a version from snapshot data, reusing the live one when this
    --- process still has it. Never displaces a newer definition.
    restore: function(data: {string: any}): ProgramImpl

    --- Claim a version on behalf of one playback.
    retain: function(prog: ProgramImpl)

    --- Give up one playback's claim, dropping the version at zero.
    release: function(prog: ProgramImpl)
end

local byName: {string: ProgramImpl} = {}
local versions: {string: {integer: ProgramImpl}} = {}
local refs: {ProgramImpl: integer} = {}

function registry.newest(name: string): ProgramImpl
    return byName[name]
end

function registry.version(name: string, version: integer): ProgramImpl
    local known = versions[name]
    return known and known[version]
end

function registry.names(): {string}
    local out: {string} = {}
    for name in pairs(byName) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function registry.nextVersion(name: string): integer
    local previous = byName[name]
    return previous and previous.version + 1 or 1
end

function registry.publish(prog: ProgramImpl)
    byName[prog.name] = prog
    local known = versions[prog.name]
    if not known then
        known = {}
        versions[prog.name] = known
    end
    known[prog.version] = prog
end

function registry.restore(data: {string: any}): ProgramImpl
    local name <const> = data.name as string
    local version <const> = data.version as integer
    local known = versions[name]
    if known and known[version] then
        return known[version]
    end

    local prog: ProgramImpl = {
        name = name,
        version = version,
        code = data.code as {integer},
        consts = data.consts as {any},
        loopSlots = data.loopSlots as integer,
        loopCounts = (data.loopCounts as {integer: integer}) or {},
        bindingArgs = {},
    }
    seqprogram.indexBindingArgs(prog)
    if not known then
        known = {}
        versions[name] = known
    end
    known[version] = prog

    -- A restored version never displaces a newer definition.
    local newest = byName[name]
    if not newest or newest.version < version then
        byName[name] = prog
    end
    return prog
end

function registry.retain(prog: ProgramImpl)
    refs[prog] = (refs[prog] or 0) + 1
end

function registry.release(prog: ProgramImpl)
    if not prog then return end
    local remaining = (refs[prog] or 1) - 1
    if remaining > 0 then
        refs[prog] = remaining
        return
    end
    refs[prog] = nil
    if byName[prog.name] == prog then return end
    local known = versions[prog.name]
    if not known then return end
    known[prog.version] = nil
    if next(known) == nil then versions[prog.name] = nil end
end

return registry
