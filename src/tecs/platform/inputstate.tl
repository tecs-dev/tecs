--[=[
The parts of input state that no single device owns.

A gamepad has its own buttons and its own axes, so the three-tier button
state cannot live inside `Input` where a per-device object could not reach
it. It lives here, and so does the layer gate, which every device shares:
one gate object answers for the keyboard, the mouse and every pad, so a
layer pushed once is answered the same way by all of them.
]=]

local record Layer
    --- What the layer is for, in diagnostics. Not an identity: two layers may
    --- share a name, and a query is answered from the object rather than from
    --- what it is called.
    name: string
    --- Whether this layer hides input from the layers beneath it.
    blocking: boolean
    --- Position in the stack. Compared against the topmost blocking layer to
    --- decide whether this layer may read.
    ---
    --- Fixed when the layer is pushed. Nothing renumbers, because the base
    --- layer is never removed and only the top one ever is, so an index cannot
    --- go stale while its layer is still on the stack.
    index: integer
end

--- Live, frame and latched state for one set of buttons.
---
--- Live state answers "is it held". The frame sets answer "did it change this
--- frame". The latched sets answer the same question for a fixed step, which
--- is not the same question: a button pressed and released between two steps
--- is invisible to the frame sets, and losing it produces input loss that
--- varies with frame timing and so cannot be reproduced on demand.
--- Every set is keyed by the platform's own code for the button, and holds
--- true or nothing: a code absent from a set is a button that set has nothing
--- to say about, which is why membership rather than value is what is read.
local record Buttons
    --- Held right now. Survives the frame boundary, and is emptied only by a
    --- release or by `releaseAll`.
    down: {integer: boolean}
    --- Went down since the last `beginFrame`, and cleared by the next one.
    pressed: {integer: boolean}
    --- Came up since the last `beginFrame`, and cleared by the next one.
    released: {integer: boolean}
    --- Went down since the last fixed step, accumulated across every frame
    --- between two steps and cleared by `exitFixed`. A button pressed and
    --- released inside one step interval appears in this and in
    --- `latchedReleased` together.
    latchedPressed: {integer: boolean}
    --- Came up since the last fixed step, on the same terms.
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
    --- A position in the layer stack, handed back by `Gate:push` and passed to
    --- every query that wants to be answered relative to it.
    Layer: Layer
    --- One set of buttons in three tiers. `Input` holds one for the keyboard
    --- and one for the mouse; every `Gamepad` holds its own.
    Buttons: Buttons
    --- The layer stack. One instance is shared by every device, so a layer
    --- pushed once is answered the same way by all of them.
    Gate: Gate
end

local ButtonsMT <const>: metatable<Buttons> = {__index = Buttons}
local GateMT <const>: metatable<Gate> = {__index = Gate}

local function clear(set: {integer: boolean})
    for code in pairs(set) do
        set[code] = nil
    end
end

-------------------------------------------------------------------------------
-- Buttons
-------------------------------------------------------------------------------

--- Creates an empty set, with nothing held and no edges recorded.
function Buttons.create(): Buttons
    return setmetatable(
        {
            down = {},
            pressed = {},
            released = {},
            latchedPressed = {},
            latchedReleased = {},
        } as Buttons,
        ButtonsMT
    )
end

--- Records a press in all three tiers.
---
--- A platform repeat is not a press and must be filtered before this: holding
--- a key would otherwise read as pressing it once per repeat interval.
--- @param code The platform's own code for the button.
function Buttons:press(code: integer)
    self.down[code] = true
    self.pressed[code] = true
    self.latchedPressed[code] = true
end

--- Records a release in all three tiers.
---
--- Recorded whether or not the button was held, since the platform is the
--- authority on that and a release for something this never saw pressed means
--- the press was missed rather than that the release is spurious.
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

--- Drops every edge in both tiers, leaving held state alone.
---
--- What a capture boundary needs. An edge belongs to whoever could read input
--- when it happened, and a layer that gains or loses capture partway through a
--- frame would otherwise be answered from the other side of the boundary: a
--- key typed into a menu fires in gameplay the instant the menu pops. Held
--- state is not an edge and survives, so a key still physically down is still
--- down on both sides.
function Buttons:clearEdges()
    clear(self.pressed)
    clear(self.released)
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
---
--- The live set is returned rather than a copy, so a caller tests membership
--- in it and does not retain it past the frame.
--- @param fixed Whether a fixed step is running, which selects the latched
---     sets over the frame sets.
--- @param released Whether the caller wants releases rather than presses.
function Buttons:edges(fixed: boolean, released: boolean): {integer: boolean}
    if fixed then
        return released and self.latchedReleased or self.latchedPressed
    end
    return released and self.released or self.pressed
end

-------------------------------------------------------------------------------
-- Gate
-------------------------------------------------------------------------------

--- Creates a stack holding only the base layer.
---
--- The base layer blocks, which is what makes it the thing everything beneath
--- would be hidden from if there were anything beneath it.
function Gate.create(): Gate
    return setmetatable(
        {
            layers = {{name = "base", blocking = true, index = 1}},
            fixed = false,
        } as Gate,
        GateMT
    )
end

--- The lowest layer index still allowed to read.
local function readableFrom(self: Gate): integer
    for index = #self.layers, 1, -1 do
        if self.layers[index].blocking then
            return index
        end
    end
    return 1
end

--- Pushes a layer and returns it, plus whether capture moved.
---
--- A blocking layer hides input from everything beneath. Pass
--- `blocking = false` for an overlay that observes without consuming.
---
--- Capture moves when the lowest readable index does, which is to say when the
--- layer blocks. An overlay that consumes nothing is not a boundary: the
--- layers beneath keep reading the same stream they were reading a moment ago,
--- and taking their pending edges away to hand the overlay a clean slate would
--- be the same defect pointing the other way.
function Gate:push(name: string, blocking?: boolean): Layer, boolean
    local before = readableFrom(self)
    local layer: Layer = {
        name = name,
        blocking = blocking ~= false,
        index = #self.layers + 1,
    }
    self.layers[layer.index] = layer
    return layer, readableFrom(self) ~= before
end

--- Removes the topmost layer and returns it, plus whether capture moved.
---
--- The base layer is never removed, so popping an empty stack returns nil
--- rather than raising: an unbalanced pop leaves the stack in the state
--- everything already reads correctly, and reports no boundary because none
--- was crossed.
function Gate:pop(): Layer, boolean
    local count = #self.layers
    if count <= 1 then
        return nil, false
    end
    local before = readableFrom(self)
    local layer = self.layers[count]
    self.layers[count] = nil
    return layer, readableFrom(self) ~= before
end

--- The layer currently on top.
function Gate:top(): Layer
    return self.layers[#self.layers]
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
