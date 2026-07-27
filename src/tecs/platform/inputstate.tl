--- The parts of input state that no single device owns.
---
--- A gamepad has its own buttons and its own axes, so the three-tier button
--- state cannot live inside `Input` where a per-device object could not reach
--- it. It lives here, and so does the layer gate, which every device shares:
--- one gate object answers for the keyboard, the mouse and every pad, so a
--- layer pushed once is answered the same way by all of them.

local record Layer
    name: string
    --- Whether this layer hides input from the layers beneath it.
    blocking: boolean
    --- Position in the stack. Compared against the topmost blocking layer to
    --- decide whether this layer may read.
    index: integer
end

--- Live, frame and latched state for one set of buttons.
---
--- Live state answers "is it held". The frame sets answer "did it change this
--- frame". The latched sets answer the same question for a fixed step, which
--- is not the same question: a button pressed and released between two steps
--- is invisible to the frame sets, and losing it produces input loss that
--- varies with frame timing and so cannot be reproduced on demand.
local record Buttons
    down: {integer: boolean}
    pressed: {integer: boolean}
    released: {integer: boolean}
    latchedPressed: {integer: boolean}
    latchedReleased: {integer: boolean}
end

--- The layer stack, plus which tier queries read right now.
local record Gate
    --- The stack, with the base layer always at index 1.
    layers: {Layer}
    --- True between `enterFixedPhase` and `exitFixedPhase`, when queries read
    --- the latched sets instead of the frame sets.
    fixed: boolean
end

local record inputstate
    Layer: Layer
    Buttons: Buttons
    Gate: Gate
end

local ButtonsMT <const>: metatable<Buttons> = { __index = Buttons }
local GateMT <const>: metatable<Gate> = { __index = Gate }

local function clear(set: {integer: boolean})
    for code in pairs(set) do set[code] = nil end
end

-------------------------------------------------------------------------------
-- Buttons
-------------------------------------------------------------------------------

function Buttons.create(): Buttons
    return setmetatable({
        down = {}, pressed = {}, released = {},
        latchedPressed = {}, latchedReleased = {},
    } as Buttons, ButtonsMT)
end

function Buttons:press(code: integer)
    self.down[code] = true
    self.pressed[code] = true
    self.latchedPressed[code] = true
end

function Buttons:release(code: integer)
    self.down[code] = nil
    self.released[code] = true
    self.latchedReleased[code] = true
end

--- Drops the frame edges. Held state survives, because holding is not an edge.
function Buttons:beginFrame()
    clear(self.pressed)
    clear(self.released)
end

--- Drops the latched edges a fixed step has now consumed.
function Buttons:exitFixed()
    clear(self.latchedPressed)
    clear(self.latchedReleased)
end

--- Releases everything held, reporting each as an edge.
---
--- What focus loss and device removal need: a button whose release the
--- platform will never deliver would otherwise read as held forever.
function Buttons:releaseAll()
    for code in pairs(self.down) do
        self.released[code] = true
        self.latchedReleased[code] = true
    end
    clear(self.down)
end

--- The edge set a query should read, given the phase and which edge it wants.
function Buttons:edges(fixed: boolean, released: boolean): {integer: boolean}
    if fixed then
        return released and self.latchedReleased or self.latchedPressed
    end
    return released and self.released or self.pressed
end

-------------------------------------------------------------------------------
-- Gate
-------------------------------------------------------------------------------

function Gate.create(): Gate
    return setmetatable({
        layers = { { name = "base", blocking = true, index = 1 } },
        fixed = false,
    } as Gate, GateMT)
end

--- Pushes a layer and returns it.
---
--- A blocking layer hides input from everything beneath. Pass
--- `blocking = false` for an overlay that observes without consuming.
function Gate:push(name: string, blocking?: boolean): Layer
    local layer: Layer = {
        name = name,
        blocking = blocking ~= false,
        index = #self.layers + 1,
    }
    self.layers[layer.index] = layer
    return layer
end

--- Removes the topmost layer and returns it. The base layer is never removed.
function Gate:pop(): Layer
    local count = #self.layers
    if count <= 1 then return nil end
    local layer = self.layers[count]
    self.layers[count] = nil
    return layer
end

--- The layer currently on top.
function Gate:top(): Layer
    return self.layers[#self.layers]
end

--- The lowest layer index still allowed to read.
local function readableFrom(self: Gate): integer
    for index = #self.layers, 1, -1 do
        if self.layers[index].blocking then return index end
    end
    return 1
end

--- Whether `layer` may read input. Omitting a layer means the base layer,
--- which is the safe default: it goes quiet when anything is pushed over it.
function Gate:canRead(layer?: Layer): boolean
    local index = layer ~= nil and layer.index or 1
    return index >= readableFrom(self)
end

inputstate.Buttons = Buttons
inputstate.Gate = Gate

return inputstate
