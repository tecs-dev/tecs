--- The pass currently open on each command buffer.
---
--- SDL forbids beginning any render, compute or copy pass on a command buffer
--- while another is open, so there is at most one entry per buffer and in
--- practice at most one entry at all. What the table exists for is the case the
--- call site cannot cover: a pass body that throws skips the `finish` written
--- after it, and a command buffer with a pass still open can be neither
--- submitted nor canceled. Recovery has the command buffer and nothing else,
--- so this is how it reaches the pass.
---
--- Registration is by command buffer rather than by frame because a pass is
--- begun against a command buffer and nothing else is threaded through to the
--- places that begin one: a compute stage a game installs receives the frame,
--- but the pipeline's own passes are recorded from three modules that only ever
--- see the buffer. Keyed this way, every one of them is covered without being
--- asked to opt in.

local loader <const> = require("tecs.ffi.loader")

--- What a tracked pass has to be able to do. Both `RenderPass` and
--- `ComputePass` satisfy it, and neither is named here: this module is required
--- by both and can depend on neither.
local record Pass
    finish: function(self: Pass)
end

--- The open-pass registry, keyed by command buffer.
---
--- Process-wide state, not per device or per frame: one list serves every
--- command buffer, and it holds at most one entry per buffer. `RenderPass` and
--- `ComputePass` record and remove themselves, so nothing else calls `opened`
--- or `closed`; a caller recovering a frame calls `endOpen`.
local record passscope
    --- What a tracked pass has to be able to do.
    type Pass = Pass
end

-- Parallel arrays rather than a map: cdata pointers hash by identity rather
-- than by address, so a lookup has to compare. The list is one entry long
-- while a pass is open and empty otherwise, so the scan is not a scan.
local buffers: {loader.CValue} = {}
local passes: {Pass} = {}
local count = 0

--- Finds the entry for `commandBuffer`, or zero.
local function indexOf(commandBuffer: loader.CValue): integer
    for index = 1, count do
        if buffers[index] == commandBuffer then
            return index
        end
    end
    return 0
end

--- Records `pass` as the one open on `commandBuffer`.
---
--- Called by `begin`, so nothing outside this package has to know it happened.
--- An entry already there is replaced rather than refused: SDL has already
--- rejected the second begin by the time this runs, and losing the first pass
--- would be losing the one that can still be ended.
function passscope.opened(commandBuffer: loader.CValue, pass: Pass)
    local index = indexOf(commandBuffer)
    if index == 0 then
        count = count + 1
        index = count
    end
    buffers[index] = commandBuffer
    passes[index] = pass
end

--- Forgets the pass open on `commandBuffer`. Called by `finish`.
function passscope.closed(commandBuffer: loader.CValue)
    local index = indexOf(commandBuffer)
    if index == 0 then
        return
    end
    buffers[index] = buffers[count]
    passes[index] = passes[count]
    buffers[count] = nil
    passes[count] = nil
    count = count - 1
end

--- Ends whatever pass is open on `commandBuffer`.
---
--- The pass's own `finish` is what runs, so the entry is removed by the same
--- path that removes it on the ordinary route out.
--- @param commandBuffer The buffer to clear, which need not have a pass open:
---     one that does not is answered false rather than refused.
--- @return Whether there was one to end. False is the ordinary answer for a
---     frame that finished its passes itself.
function passscope.endOpen(commandBuffer: loader.CValue): boolean
    local index = indexOf(commandBuffer)
    if index == 0 then
        return false
    end
    passes[index]:finish()
    return true
end

--- How many command buffers have a pass open.
---
--- Zero everywhere except between a begin and its finish, which is what makes
--- it worth asserting on: a test that injected a throw into a pass body reads
--- this to find out whether the pass was ended rather than leaked.
function passscope.openCount(): integer
    return count
end

return passscope
