--- Resolves the debugger's leader modifier (held with a toggle key). The leader
--- is configurable; "ctrl" (the default), "alt", "shift", and "gui"/"cmd"/"super"
--- map to their left/right key pairs.

local input <const> = require("tecs2d.input")

local record leader
    isDown: function(view: input.View, name: string): boolean

    --- True when name is a recognized leader modifier.
    isValid: function(name: string): boolean
end

local PAIRS <const>: {string: {string}} = {
    ctrl = {"lctrl", "rctrl"},
    alt = {"lalt", "ralt"},
    shift = {"lshift", "rshift"},
    gui = {"lgui", "rgui"},
    cmd = {"lgui", "rgui"},
    super = {"lgui", "rgui"},
}

function leader.isValid(name: string): boolean
    return PAIRS[name] ~= nil
end

-- Read through the caller's input-stack view, so the debugger detects the leader
-- through its own layer while the game (a lower layer) does not.
function leader.isDown(view: input.View, name: string): boolean
    local keys = PAIRS[name] or PAIRS.ctrl
    return view.isKeyDown(keys[1]) or view.isKeyDown(keys[2])
end

return leader
