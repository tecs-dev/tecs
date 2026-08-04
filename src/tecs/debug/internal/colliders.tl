-- The collider overlay: one outline per physics collider, drawn through the
-- instanced sprite path rather than through entities or a pass of its own.
--
-- An outline is a closed polyline, and every one of its segments is an ordinary
-- textured quad: the segment's length is the quad's width, the outline's
-- thickness is its height, and the texture is the white texel the backend keeps
-- on array layer zero. So the overlay is an `InstanceProducer` and nothing else,
-- and culling, layers, depth and materials apply to it without the renderer
-- knowing it is not a scene.
--
-- Scale is what the design is for. A world holding a hundred thousand static
-- colliders and a hundred moving ones has to cost a hundred quad rewrites a
-- frame, so each archetype owns a contiguous span of the run and a span whose
-- columns are clean is left exactly as it was written. What survives that gate
-- is the rest of the design: the reserved count only grows, because changing it
-- relayouts every instance in the scene; a slot inside the reservation that
-- nothing draws carries the hidden sentinel; and the ranges handed back are
-- coalesced, because the extractor shares one small range budget with the whole
-- frame.

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local loader <const> = require("tecs.ffi.loader")
local components <const> = require("tecs.components")
local layers <const> = require("tecs.gfx.layers")
local instancelayout <const> = require("tecs.gpu.instancelayout")
local storekeys <const> = require("tecs.internal.storekeys")

local type Renderer = require("tecs.Renderer")
-- Type only, and it has to stay that way. Requiring `tecs.physics` registers its
-- components and events as a side effect of loading the module, and a session
-- that never simulates anything still reaches this file to answer a command.
-- `install` takes the require once a caller has asked for an overlay, by which
-- point the components exist or are about to.
local type physicsapi = require("tecs.physics")

local type World = types.World
local type Query = types.Query
local type Archetype = types.Archetype
local type Relationship = types.components.Relationship
local type Collider = physicsapi.Collider
local type Previous = components.PreviousTransform2D

local Transform2D <const> = ecs.Transform2D
local PreviousTransform2D <const> = components.PreviousTransform2D

local cos <const> = math.cos
local sin <const> = math.sin
local atan2 <const> = math.atan2
local sqrt <const> = math.sqrt
local abs <const> = math.abs
local floor <const> = math.floor
local PI <const> = math.pi
local TWO_PI <const> = PI * 2.0

local INSTANCE_FLOATS <const> = instancelayout.FLOATS
local INSTANCE_BYTES <const> = instancelayout.BYTES
local BOUND_FLOATS <const> = instancelayout.BOUND_FLOATS
local BOUND_BYTES <const> = instancelayout.BOUND_BYTES
local HIDDEN <const> = instancelayout.HIDDEN
local HIDDEN_DEPTH <const> = instancelayout.HIDDEN_DEPTH
--- Both positive, and they have to be. The two signs of a bound's half extents
--- are a role encoding, so a negative y extent would claim the shadow-caster
--- lane and rasterize the outlines into the occluder mask.
local OPAQUE_X <const>, OPAQUE_Y <const> = instancelayout.signsOf("opaque")

--- `Collider.shape` discriminants, which the component stores as a number. Box
--- is zero and is what anything else is drawn as, so it needs no name here.
local SHAPE_CIRCLE <const> = 1
local SHAPE_CAPSULE <const> = 2

--- Layer the overlay draws on when the caller names none. Sixteen is the HUD by
--- convention, so the overlay sits directly under it.
local DEFAULT_LAYER <const> = 15
--- Outline thickness in screen pixels, which is thin enough to read a shape's
--- edge against the sprite it belongs to.
local DEFAULT_THICKNESS <const> = 1.5
--- Points a circle is tessellated with, and half of that per capsule cap.
local DEFAULT_SEGMENTS <const> = 16
--- Tint of a solid collider, and of a sensor, which reads differently on
--- purpose: a sensor reports overlaps and stops nothing.
local DEFAULT_COLOR <const>: {number} = {0.25, 1.0, 0.45, 1.0}
local DEFAULT_SENSOR_COLOR <const>: {number} = {1.0, 0.75, 0.2, 1.0}

--- Quads one overlay reserves at the very most.
---
--- A debug overlay may not spend the whole sprite buffer on itself, and it may
--- not grow without bound in a world nobody expected to visualize. Shapes past
--- this are reported as dropped rather than drawn.
local MAX_INSTANCES <const> = 32768
--- Slots the arrays start at, and the floor every growth doubles from.
local MINIMUM_SLOTS <const> = 256
--- Distinct dirty ranges kept before they collapse into one covering span.
--- `dirtyranges.MAX` is 64 for the whole frame, and this run is one of several
--- things spending it.
local MAX_RANGES <const> = 16
--- How far the camera's zoom moves before the outlines are rebuilt at a new
--- world-space thickness. Nothing marks zoom dirty, so it is compared here, and
--- a band rather than an equality keeps a camera easing towards a target from
--- rewriting every quad for a change no pixel shows.
local ZOOM_EPSILON <const> = 1.0e-4

--- Unit-circle points per tessellation, as x, y pairs from angle zero, built
--- once per segment count and shared by every overlay in the process.
---
--- A capsule reads the same table: its cap step is `PI / caps`, which is the
--- circle's own step once the segment count is even, so the caps are the
--- circle's points and no second table is needed.
local UNIT_CIRCLES <const>: {integer: {number}} = {}

local function unitCircle(segments: integer): {number}
    local existing <const> = UNIT_CIRCLES[segments]
    if existing ~= nil then
        return existing
    end

    local points <const>: {number} = {}
    local step <const> = TWO_PI / segments
    for index = 0, segments - 1 do
        local angle <const> = index * step
        points[index * 2 + 1] = cos(angle)
        points[index * 2 + 2] = sin(angle)
    end
    UNIT_CIRCLES[segments] = points
    return points
end

--- The overlay a world holds, and the shape a command talks to.
local record colliders
    --- Configures one overlay. Every field is optional and takes the default
    --- named on it.
    record Options
        --- Caller-writable. Draws the outlines on this layer, from 1 to
        --- `tecs.gfx.layers.MAX`. Defaults to 15, one under the layer a HUD
        --- conventionally takes. Installing configures the layer as an unlit
        --- z-sorted one, so the layer belongs to the overlay from then on.
        layer: integer

        --- Caller-writable. Draws each outline this many screen pixels thick,
        --- which stays constant as the camera zooms. Defaults to 1.5. Zero or
        --- less raises.
        thickness: number

        --- Caller-writable. Tessellates a circle into this many segments, and
        --- each capsule cap into half that. Defaults to 16. An odd count is
        --- raised to the next even one so the caps share the circle's points,
        --- and fewer than four raises.
        segments: integer

        --- Caller-writable. Tints a solid collider, as red, green, blue and
        --- alpha from zero to one. Defaults to a green. A list of any other
        --- length raises.
        color: {number}

        --- Caller-writable. Tints a sensor, under the same rule as `color`, so
        --- a shape that reports overlaps and stops nothing reads differently
        --- from one that stops things. Defaults to an amber.
        sensorColor: {number}
    end

    --- Reports what the last build produced, which is what a command answers
    --- with.
    record Stats
        --- Read-only. Counts the colliders the last build tessellated.
        shapes: integer
        --- Read-only. Counts the quads those colliders occupy, which is the
        --- length of the run the renderer draws.
        instances: integer
        --- Read-only. Reports the reservation the renderer lays out, which is
        --- the high-water mark of `instances`: it grows and holds, and falls
        --- only when the renderer releases the overlay's buffers.
        reserved: integer
        --- Read-only. Counts the colliders the last build left undrawn because
        --- the overlay had already reserved every quad it may hold.
        dropped: integer
        --- Read-only. Reports the graphics layer the outlines draw on, which is
        --- what the overlay was installed with rather than what a later caller
        --- asked for: installing twice answers with the first one.
        layer: integer
    end

    --- One world's overlay, which draws nothing until it is enabled.
    record Overlay
        --- Turns the outlines on or off.
        ---
        --- Enabling allocates the overlay's buffers and queries on the first
        --- call and rebuilds every outline on the next update. Disabling hides
        --- every quad and keeps the reservation, because handing the
        --- reservation back would move every later instance in the scene and a
        --- debug toggle should not cost the frame that much.
        --- @param self The overlay to switch.
        --- @param on True draws the outlines, false hides them. Switching to
        ---     the state it is already in does nothing.
        setEnabled: function(self: Overlay, on: boolean)

        --- Reports whether the outlines are being drawn.
        --- @param self The overlay to ask.
        --- @return True between a `setEnabled(true)` and the next
        ---     `setEnabled(false)`.
        isEnabled: function(self: Overlay): boolean

        --- Reports what the last build produced.
        --- @param self The overlay to ask.
        --- @return A fresh record the caller owns. Every count is zero on an
        ---     overlay that has never been enabled.
        stats: function(self: Overlay): Stats
    end

    --- Installs the overlay in `world`, or answers with the one it already has.
    ---
    --- Idempotent per world: a second call answers with the first call's
    --- overlay, ignores its options, and adds no second system. Installing
    --- configures the layer, registers the producer and adds the system that
    --- builds the outlines; it allocates no instance buffers and creates no
    --- queries until something enables the overlay.
    --- @param world The world whose colliders are drawn. It needs a physics
    ---     simulation for the overlay to find anything, and installing into one
    ---     without a simulation is not an error.
    --- @param renderer The renderer drawing `world`. Nil raises, because an
    ---     overlay with nothing to draw through is a mistake at the call rather
    ---     than a state to report.
    --- @param options The configuration, or nil for the defaults. A malformed
    ---     option raises.
    --- @return The world's overlay, disabled unless it already existed.
    install: function(world: World, renderer: Renderer, options?: Options): Overlay

    --- Answers with a world's overlay.
    --- @param world The world to ask.
    --- @return The overlay, or nil where nothing has installed one.
    of: function(world: World): Overlay
end

--- One archetype's contiguous span of the run.
---
--- The span is what makes a clean archetype free: its quads stay resident
--- between builds, so a build that finds nothing dirty writes nothing and marks
--- nothing.
local record Span
    --- The archetype the span draws. A span whose archetype changed is
    --- rewritten whatever the dirty bits say.
    archetype: Archetype
    --- Whether the poses come from an owning body rather than from the
    --- archetype's own transforms.
    secondary: boolean
    --- Instance index the span starts at, counted from zero.
    offset: integer
    --- Quads the span holds.
    instances: integer
    --- Rows the archetype held when the span was measured.
    rows: integer
    --- Whether any row was between two different poses when the span was last
    --- written.
    ---
    --- What decides whether a moving interpolation fraction has anything to say
    --- to this span. A row whose previous and current transforms are equal
    --- draws the same outline at every fraction, and a world of resting bodies
    --- is exactly that, so a span of them is skipped rather than rewritten once
    --- a frame for a pose that cannot move. It can only become true through a
    --- transform write, which marks the column and rewrites the span, so a body
    --- that starts moving is never missed.
    moving: boolean
end

--- The overlay's state, which is also the producer the renderer draws it
--- through.
---
--- One object for both because the two are the same thing seen from either
--- side: what the build writes is exactly what the producer hands over, and a
--- second object would only be a second place for the two to disagree.
local record Outlines
    setEnabled: function(self: Outlines, on: boolean)
    isEnabled: function(self: Outlines): boolean
    stats: function(self: Outlines): colliders.Stats

    count: function(self: Outlines): integer
    takeDirty: function(self: Outlines): {integer}
    blended: function(self: Outlines): integer
    casting: function(self: Outlines): integer
    write: function(
        self: Outlines, floats: loader.CArray, bounds: loader.CArray, base: integer, first: integer, last: integer
    )
    destroy: function(self: Outlines)

    --- Whether the outlines are drawn, and whether the next build rewrites all
    --- of them.
    _enabled: boolean
    _rebuild: boolean
    --- Set once the renderer has released the producer, after which the build
    --- does nothing at all.
    _released: boolean

    _world: World
    _renderer: Renderer
    --- The collider component, the relationship naming a secondary collider's
    --- owner, and the two queries, all resolved when the overlay is first
    --- enabled rather than when it is installed.
    _collider: Collider
    _colliderOf: Relationship
    _primary: Query
    _secondary: Query

    --- Instance floats, sixteen per slot, and cull bounds, four per slot, with
    --- byte views of both so a copy can be offset into them exactly.
    _instances: loader.CArray
    _bounds: loader.CArray
    _instanceBytes: loader.BytePointer
    _boundBytes: loader.BytePointer
    --- Slots the arrays hold.
    _capacity: integer
    --- Slots the run reserves, which only ever grows: changing it relayouts
    --- every instance in the scene.
    _reserved: integer
    --- Slots the last build drew into. Everything from here to `_reserved`
    --- carries the hidden sentinel.
    _used: integer

    --- The spans, in walk order, and how many of them the last build reached.
    _spans: {Span}
    _spanCount: integer
    --- Where the walk in progress has reached, so the two queries share one
    --- cursor without passing four counters between them.
    _walkIndex: integer
    _walkOffset: integer

    --- Sub-ranges written since the last sync, as flat one-based inclusive
    --- pairs, how many entries are in use, and whether the last sync took them.
    --- They are dropped at the first mark after that rather than on the way
    --- out, so the table handed over stays valid while the renderer reads it.
    _dirty: {integer}
    _dirtyCount: integer
    _taken: boolean

    --- What the outlines were last built against: the camera zoom, the
    --- interpolation fraction, and the world-space thickness the zoom implies.
    _zoom: number
    _alpha: number
    _width: number

    --- The configuration, flattened out of `Options`. The layer is kept beside
    --- the depth derived from it, because `stats` reports the layer the overlay
    --- actually took and a caller that installed second never learns its own
    --- request was declined any other way.
    _layer: integer
    _thickness: number
    _segments: integer
    _caps: integer
    _unit: {number}
    _depth: number
    _r: number
    _g: number
    _b: number
    _a: number
    _sensorR: number
    _sensorG: number
    _sensorB: number
    _sensorA: number

    --- What the last build produced.
    _shapes: integer
    _dropped: integer
end

local OutlinesMT <const>: metatable<Outlines> = {__index = Outlines}

--- World-space points of the outline being built, as x, y pairs. Module scope
--- and reused by every collider of every overlay, so a build allocates nothing.
local POINTS <const>: {number} = {}

--- The store key names a world's overlay. `"tecs.debug.colliders"` is an
--- externally typed compatibility surface: a tool looks the overlay up by this
--- string rather than by the Lua module path, so it stays as it is written here
--- whatever happens to the module around it.
local overlayKey <const> = storekeys.newKey("tecs.debug.colliders", nil as Outlines)

-------------------------------------------------------------------------------
-- The buffers and the dirty ranges
-------------------------------------------------------------------------------

--- Writes the hidden sentinel into slots `first` through `last`, counted from
--- zero, so a slot inside the reservation that nothing draws is dropped by the
--- cull before the draw sees it.
local function hideSlots(self: Outlines, first: integer, last: integer)
    local floats <const> = self._instances
    local bounds <const> = self._bounds
    for slot = first, last do
        local at <const> = slot * INSTANCE_FLOATS
        for lane = 0, INSTANCE_FLOATS - 1 do
            floats[at + lane] = 0.0
        end
        floats[at + 3] = HIDDEN_DEPTH
        local bound <const> = slot * BOUND_FLOATS
        bounds[bound] = HIDDEN
        bounds[bound + 1] = HIDDEN
        -- Positive zeros, under the sign rule every bound this producer writes
        -- obeys.
        bounds[bound + 2] = 0.0
        bounds[bound + 3] = 0.0
    end
end

--- Grows the arrays to hold at least `slots`, preserving what is in them.
local function reserveCapacity(self: Outlines, slots: integer)
    if slots <= self._capacity then
        return
    end

    local capacity = self._capacity
    if capacity < MINIMUM_SLOTS then
        capacity = MINIMUM_SLOTS
    end
    while capacity < slots do
        capacity = capacity * 2
    end

    local instances <const> = loader.newArray("float[?]", capacity * INSTANCE_FLOATS)
    local bounds <const> = loader.newArray("float[?]", capacity * BOUND_FLOATS)
    if self._capacity > 0 then
        loader.copyBytes(instances, self._instances as loader.CValue, self._capacity * INSTANCE_BYTES)
        loader.copyBytes(bounds, self._bounds as loader.CValue, self._capacity * BOUND_BYTES)
    end

    local grown <const> = self._capacity
    self._instances = instances
    self._bounds = bounds
    self._instanceBytes = loader.bytePointer(instances as loader.CValue)
    self._boundBytes = loader.bytePointer(bounds as loader.CValue)
    self._capacity = capacity
    -- A fresh array is zero-filled, which is a real quad of no size at the
    -- world origin rather than nothing. The sentinel is what makes it nothing.
    hideSlots(self, grown, capacity - 1)
end

--- Drops the ranges the last sync consumed.
local function settle(self: Outlines)
    if not self._taken then
        return
    end
    local ranges <const> = self._dirty
    for index = self._dirtyCount * 2, 1, -1 do
        ranges[index] = nil
    end
    self._dirtyCount = 0
    self._taken = false
end

--- Records that instances `first` through `last` of the run were written, as
--- one-based inclusive positions within the run.
---
--- Marks arrive in ascending order, because the build walks the spans in the
--- order they are laid out, so testing the last entry alone merges everything
--- that can merge. Past `MAX_RANGES` the list collapses to one covering span,
--- which rewrites the gaps between the spans and keeps the frame's range budget
--- for the rest of the scene.
local function mark(self: Outlines, first: integer, last: integer)
    settle(self)
    local ranges <const> = self._dirty
    local count <const> = self._dirtyCount

    if count > 0 then
        local previous <const> = ranges[count * 2]
        if first <= previous + 1 then
            if last > previous then
                ranges[count * 2] = last
            end
            return
        end
    end

    if count == MAX_RANGES then
        ranges[2] = last
        for index = count * 2, 3, -1 do
            ranges[index] = nil
        end
        self._dirtyCount = 1
        return
    end

    ranges[count * 2 + 1] = first
    ranges[count * 2 + 2] = last
    self._dirtyCount = count + 1
end

-------------------------------------------------------------------------------
-- The geometry
-------------------------------------------------------------------------------

--- Quads one collider is tessellated into.
local function instancesFor(self: Outlines, shape: number): integer
    if shape == SHAPE_CIRCLE then
        return self._segments
    end
    if shape == SHAPE_CAPSULE then
        return self._segments + 2
    end
    return 4
end

--- Quads a whole archetype is tessellated into.
local function measure(self: Outlines, column: {Collider}, length: integer): integer
    local total = 0
    for row = 1, length do
        total = total + instancesFor(self, column[row].shape)
    end
    return total
end

--- Writes one segment as a quad, into slot `slot` counted from zero.
---
--- The quad is longer than the segment by one thickness, which fills the notch
--- every corner of a closed outline would otherwise show.
local function writeSegment(
    self: Outlines,
    slot: integer,
    ax: number,
    ay: number,
    bx: number,
    by: number,
    r: number,
    g: number,
    b: number,
    a: number
)
    local dx <const> = bx - ax
    local dy <const> = by - ay
    local angle <const> = atan2(dy, dx)
    local width <const> = self._width
    local scaleX <const> = sqrt(dx * dx + dy * dy) + width
    local centerX <const> = (ax + bx) * 0.5
    local centerY <const> = (ay + by) * 0.5

    local floats <const> = self._instances
    local at <const> = slot * INSTANCE_FLOATS
    floats[at] = angle
    floats[at + 1] = scaleX
    floats[at + 2] = width
    floats[at + 3] = self._depth

    floats[at + 4] = centerX
    floats[at + 5] = centerY
    -- Array layer zero with an all-zero rect, which is the single opaque white
    -- texel the backend always uploads, and material zero.
    floats[at + 6] = 0.0
    floats[at + 7] = 0.0

    floats[at + 8] = r
    floats[at + 9] = g
    floats[at + 10] = b
    floats[at + 11] = a

    floats[at + 12] = 0.0
    floats[at + 13] = 0.0
    floats[at + 14] = 0.0
    floats[at + 15] = 0.0

    local ex <const>, ey <const> = instancelayout.extentOf(angle, scaleX, width)
    local bounds <const> = self._bounds
    local bound <const> = slot * BOUND_FLOATS
    bounds[bound] = centerX
    bounds[bound + 1] = centerY
    bounds[bound + 2] = ex * OPAQUE_X
    bounds[bound + 3] = ey * OPAQUE_Y
end

--- Fills `POINTS` with a box's four corners in world units.
local function buildBox(collider: Collider, cx: number, cy: number, cosR: number, sinR: number): integer
    local hw <const> = collider.halfWidth
    local hh <const> = collider.halfHeight
    local rx <const> = cosR * hw
    local ry <const> = sinR * hw
    local ux <const> = sinR * hh
    local uy <const> = cosR * hh

    POINTS[1] = cx - rx + ux
    POINTS[2] = cy - ry - uy
    POINTS[3] = cx + rx + ux
    POINTS[4] = cy + ry - uy
    POINTS[5] = cx + rx - ux
    POINTS[6] = cy + ry + uy
    POINTS[7] = cx - rx - ux
    POINTS[8] = cy - ry + uy
    return 4
end

--- Fills `POINTS` with a circle's points in world units.
---
--- The body's rotation is not applied, because a circle is the one shape it
--- cannot move: turning the tessellation would cost two multiplies a point to
--- produce the same outline.
local function buildCircle(self: Outlines, collider: Collider, cx: number, cy: number): integer
    local unit <const> = self._unit
    local radius <const> = collider.radius
    local segments <const> = self._segments
    for index = 0, segments - 1 do
        local at <const> = index * 2
        POINTS[at + 1] = cx + unit[at + 1] * radius
        POINTS[at + 2] = cy + unit[at + 2] * radius
    end
    return segments
end

--- Fills `POINTS` with a capsule's points in world units.
---
--- The capsule is vertical in its body frame, so `length` separates the cap
--- centers along y and the two straight sides join the caps at their widest.
local function buildCapsule(
    self: Outlines, collider: Collider, cx: number, cy: number, cosR: number, sinR: number
): integer
    local unit <const> = self._unit
    local radius <const> = collider.radius
    local half <const> = collider.length * 0.5
    local segments <const> = self._segments
    local caps <const> = self._caps
    local count = 0

    for index = 0, caps do
        local at <const> = index * 2
        local lx <const> = unit[at + 1] * radius
        local ly <const> = half + unit[at + 2] * radius
        count = count + 1
        POINTS[count * 2 - 1] = cx + cosR * lx - sinR * ly
        POINTS[count * 2] = cy + sinR * lx + cosR * ly
    end

    for index = caps, segments do
        -- The last point of the arc is the first point of the circle again,
        -- which is where the outline closes.
        local wrapped <const> = index == segments and 0 or index
        local at <const> = wrapped * 2
        local lx <const> = unit[at + 1] * radius
        local ly <const> = unit[at + 2] * radius - half
        count = count + 1
        POINTS[count * 2 - 1] = cx + cosR * lx - sinR * ly
        POINTS[count * 2] = cy + sinR * lx + cosR * ly
    end

    return count
end

--- Writes one collider's outline from slot `slot`, and answers with the slot
--- after it.
local function writeCollider(
    self: Outlines, collider: Collider, x: number, y: number, rotation: number, slot: integer
): integer
    local cosR <const> = cos(rotation)
    local sinR <const> = sin(rotation)
    -- The offset is in the body frame and turns with the body, so the shape's
    -- center is the body's position plus the rotated offset, and the shape's
    -- own points are then placed about that.
    local offsetX <const> = collider.offsetX
    local offsetY <const> = collider.offsetY
    local cx <const> = x + cosR * offsetX - sinR * offsetY
    local cy <const> = y + sinR * offsetX + cosR * offsetY

    local shape <const> = collider.shape
    local count: integer
    if shape == SHAPE_CIRCLE then
        count = buildCircle(self, collider, cx, cy)
    elseif shape == SHAPE_CAPSULE then
        count = buildCapsule(self, collider, cx, cy, cosR, sinR)
    else
        count = buildBox(collider, cx, cy, cosR, sinR)
    end

    local r, g, b, a = self._r, self._g, self._b, self._a
    if collider.isSensor ~= 0 then
        r, g, b, a = self._sensorR, self._sensorG, self._sensorB, self._sensorA
    end

    for index = 1, count do
        -- The outline is closed, so the last segment runs back to the first
        -- point.
        local following <const> = index == count and 1 or index + 1
        writeSegment(
            self,
            slot,
            POINTS[index * 2 - 1],
            POINTS[index * 2],
            POINTS[following * 2 - 1],
            POINTS[following * 2],
            r,
            g,
            b,
            a
        )
        slot = slot + 1
    end
    return slot
end

--- The angle to draw a body at, interpolated the short way round.
---
--- A body crossing pi would otherwise be interpolated the long way and spin
--- backwards through nearly a full turn on that frame.
local function blendAngle(before: number, after: number, alpha: number): number
    local turn = after - before
    if turn > PI then
        turn = turn - TWO_PI
    elseif turn < -PI then
        turn = turn + TWO_PI
    end
    return before + turn * alpha
end

-------------------------------------------------------------------------------
-- The build
-------------------------------------------------------------------------------

--- Writes every outline of an archetype whose entities carry their own
--- transforms.
--- @return Whether any row lies between two different poses, which is what
---     decides whether a later interpolation fraction changes this span.
local function writePrimary(
    self: Outlines, archetype: Archetype, length: integer, offset: integer, previous: {Previous}
): boolean
    local column <const> = archetype:get(self._collider)
    local transforms <const> = archetype:get(Transform2D)
    local alpha <const> = self._alpha
    local slot = offset
    local moving = false
    for row = 1, length do
        local transform <const> = transforms[row]
        local x = transform.x
        local y = transform.y
        local rotation = transform.rotation
        if previous ~= nil then
            local before <const> = previous[row]
            if before.x ~= x or before.y ~= y or before.rotation ~= rotation then
                moving = true
                x = before.x + (x - before.x) * alpha
                y = before.y + (y - before.y) * alpha
                rotation = blendAngle(before.rotation, rotation, alpha)
            end
        end
        slot = writeCollider(self, column[row], x, y, rotation, slot)
    end
    return moving
end

--- Writes every outline of an archetype whose entities are secondary colliders.
---
--- A secondary collider holds no transform of its own, so its pose comes from
--- the body it names through `ColliderOf`. The relationship is sparse, which is
--- why the owner is resolved per entity rather than read off the archetype.
local function writeSecondary(
    self: Outlines, archetype: Archetype, length: integer, offset: integer, entities: {integer}
)
    local column <const> = archetype:get(self._collider)
    local world <const> = self._world
    local relationship <const> = self._colliderOf
    local alpha <const> = self._alpha
    local slot = offset
    for row = 1, length do
        local collider <const> = column[row]
        local link <const> = world:getFirstRelationship(entities[row], relationship)
        local transform <const> = link ~= nil and world:get(link.target, Transform2D) or nil
        if transform == nil then
            -- The span was measured from the shapes, so a collider whose owner
            -- cannot be resolved still consumes its slots. Hiding them is what
            -- keeps every later span where the layout says it is.
            local count <const> = instancesFor(self, collider.shape)
            hideSlots(self, slot, slot + count - 1)
            slot = slot + count
        else
            local x = transform.x
            local y = transform.y
            local rotation = transform.rotation
            local before <const> = world:get(link.target, PreviousTransform2D)
            if before ~= nil then
                x = before.x + (x - before.x) * alpha
                y = before.y + (y - before.y) * alpha
                rotation = blendAngle(before.rotation, rotation, alpha)
            end
            slot = writeCollider(self, collider, x, y, rotation, slot)
        end
    end
end

local function spanAt(self: Outlines, index: integer): Span
    local spans <const> = self._spans
    local span = spans[index]
    if span == nil then
        span = {secondary = false, offset = 0, instances = 0, rows = 0, moving = false}
        spans[index] = span
    end
    return span
end

--- Lays out and rewrites one query's archetypes, continuing the cursor the
--- other query left.
---
--- The whole point of the overlay is in the gate below: an archetype whose
--- transforms and colliders are both clean, whose span has not moved, and whose
--- bodies are not between two poses is left exactly as it was written, however
--- many colliders it holds.
local function walk(self: Outlines, query: Query, secondary: boolean, alphaMoved: boolean, rebuildAll: boolean)
    local collider <const> = self._collider
    for archetype, length, entities in query:iter() do
        self._walkIndex = self._walkIndex + 1
        local span <const> = spanAt(self, self._walkIndex)
        local offset <const> = self._walkOffset

        -- A structural change marks every column of the archetype, so a clean
        -- collider column on an unchanged row count is the same shapes it was
        -- measured from and the measurement is skipped with it.
        local colliderDirty <const> = archetype:isComponentDirty(collider)
        local instances: integer
        if not colliderDirty and span.archetype == archetype and span.rows == length then
            instances = span.instances
        else
            instances = measure(self, archetype:get(collider), length)
        end

        local dropped = 0
        if offset + instances > MAX_INSTANCES then
            dropped = length
            instances = 0
        end

        -- Interpolated the way the extractor interpolates a sprite, so an
        -- outline lands on the sprite it belongs to rather than up to one fixed
        -- step behind it. That also makes the pose move on a frame no column
        -- was written, which is the one case the dirty bits cannot see.
        local previous: {Previous} = nil
        if not secondary then
            previous = archetype:get(PreviousTransform2D)
        end

        local moved <const> = span.archetype ~= archetype
            or span.secondary ~= secondary
            or span.offset ~= offset
            or span.instances ~= instances
            or span.rows ~= length
        -- A secondary collider's pose lives in an archetype this span cannot
        -- see, so a clean column here says nothing about the body it follows.
        local rewrite <const> = instances > 0
            and (
                rebuildAll
                or moved
                or secondary
                or colliderDirty
                or archetype:isComponentDirty(Transform2D)
                or (previous ~= nil and alphaMoved and span.moving)
            )

        if rewrite then
            reserveCapacity(self, offset + instances)
            if secondary then
                writeSecondary(self, archetype, length, offset, entities)
                -- The secondary path rewrites every frame, so nothing here has
                -- a fraction to be sensitive to.
                span.moving = false
            else
                span.moving = writePrimary(self, archetype, length, offset, previous)
            end
            mark(self, offset + 1, offset + instances)
        end

        span.archetype = archetype
        span.secondary = secondary
        span.offset = offset
        span.instances = instances
        span.rows = length

        self._walkOffset = offset + instances
        self._dropped = self._dropped + dropped
        if instances > 0 then
            self._shapes = self._shapes + length
        end
    end
end

--- Brings the run up to date with the world, once per update.
local function build(self: Outlines)
    if self._released or not self._enabled then
        return
    end

    local rebuildAll = self._rebuild
    self._rebuild = false

    -- Thickness is constant in screen pixels, so it is a world-space length
    -- that moves with the camera. Nothing marks zoom dirty, so it is compared
    -- here, and every quad is rebuilt when it moves.
    local zoom = self._renderer.sprites.camera.zoom
    if zoom <= 0.0 then
        zoom = 1.0
    end
    if abs(zoom - self._zoom) > ZOOM_EPSILON * (zoom > 1.0 and zoom or 1.0) then
        self._zoom = zoom
        self._width = self._thickness / zoom
        rebuildAll = true
    end

    local _, _, alpha = self._world:getFixedTiming()
    local alphaMoved <const> = alpha ~= self._alpha
    self._alpha = alpha

    self._walkIndex = 0
    self._walkOffset = 0
    self._shapes = 0
    self._dropped = 0
    walk(self, self._primary, false, alphaMoved, rebuildAll)
    walk(self, self._secondary, true, alphaMoved, rebuildAll)

    local total <const> = self._walkOffset
    if total < self._used then
        hideSlots(self, total, self._used - 1)
        mark(self, total + 1, self._used)
    end
    self._used = total

    local spans <const> = self._spans
    for index = self._walkIndex + 1, self._spanCount do
        local span <const> = spans[index]
        span.archetype = nil
        span.instances = 0
        span.rows = 0
    end
    self._spanCount = self._walkIndex

    if total > self._reserved then
        self._reserved = total
    end
end

-------------------------------------------------------------------------------
-- The producer
-------------------------------------------------------------------------------

--- Slots the run reserves, which is the high-water mark rather than the slots
--- in use: changing it relayouts every instance in the scene, so it only grows,
--- and a reserved slot nothing draws carries the hidden sentinel.
function Outlines:count(): integer
    return self._reserved
end

function Outlines:takeDirty(): {integer}
    settle(self)
    self._taken = true
    return self._dirty
end

--- The outlines are opaque, and deliberately: the forward lane sorts and blends
--- what it draws, and an overlay wants to be culled and cheap instead.
function Outlines:blended(): integer
    return 0
end

--- The outlines write no caster lane signs into their bounds.
function Outlines:casting(): integer
    return 0
end

function Outlines:write(floats: loader.CArray, bounds: loader.CArray, base: integer, first: integer, last: integer)
    local count <const> = last - first + 1
    if count <= 0 then
        return
    end

    loader.copyTo(
        loader.bytePointer(floats as loader.CValue) + (base + first - 1) * INSTANCE_BYTES,
        (self._instanceBytes + (first - 1) * INSTANCE_BYTES) as loader.CValue,
        count * INSTANCE_BYTES
    )
    loader.copyTo(
        loader.bytePointer(bounds as loader.CValue) + (base + first - 1) * BOUND_BYTES,
        (self._boundBytes + (first - 1) * BOUND_BYTES) as loader.CValue,
        count * BOUND_BYTES
    )
end

--- Releases the buffers, after which the overlay draws nothing and cannot be
--- enabled again.
---
--- The reservation goes back with them, so a producer asked for its count after
--- this answers zero rather than naming slots whose bytes are gone.
function Outlines:destroy()
    self._released = true
    self._enabled = false
    self._instances = nil
    self._bounds = nil
    self._instanceBytes = nil
    self._boundBytes = nil
    self._capacity = 0
    self._reserved = 0
    self._used = 0
end

-------------------------------------------------------------------------------
-- The overlay
-------------------------------------------------------------------------------

--- Allocates the buffers and creates the queries, on the first enable rather
--- than at install: an overlay nobody turns on costs a system that returns.
local function allocate(self: Outlines)
    if self._primary ~= nil then
        return
    end

    -- Safe here, and only here: an overlay is enabled by a caller that has
    -- asked to see colliders, so the components this registers are the ones it
    -- asked about.
    local physics <const> = require("tecs.physics")
    local collider <const> = physics.Collider
    local colliderOf <const> = physics.ColliderOf as Relationship
    self._collider = collider
    self._colliderOf = colliderOf

    -- Excluding `ColliderOf` from the first query is what stops a secondary
    -- collider that also carries a transform being drawn twice, once at each of
    -- two poses.
    self._primary = self._world:newQuery({
        name = "tecs.debug.Colliders",
        include = {Transform2D, collider},
        exclude = {colliderOf},
    })
    self._secondary = self._world:newQuery({
        name = "tecs.debug.SecondaryColliders",
        include = {collider, colliderOf},
    })

    reserveCapacity(self, MINIMUM_SLOTS)
end

function Outlines:setEnabled(on: boolean)
    if self._released or on == self._enabled then
        return
    end

    if on then
        allocate(self)
        self._enabled = true
        self._rebuild = true
        return
    end

    self._enabled = false
    if self._used > 0 then
        hideSlots(self, 0, self._used - 1)
        mark(self, 1, self._used)
        self._used = 0
    end
    self._shapes = 0
    self._dropped = 0
end

function Outlines:isEnabled(): boolean
    return self._enabled
end

function Outlines:stats(): colliders.Stats
    return {
        shapes = self._shapes,
        instances = self._used,
        reserved = self._reserved,
        dropped = self._dropped,
        layer = self._layer,
    }
end

--- Reads a color option, which is four numbers from zero to one.
local function colorOf(value: {number}, name: string, fallback: {number}): number, number, number, number
    if value == nil then
        return fallback[1], fallback[2], fallback[3], fallback[4]
    end
    if #value ~= 4 then
        error(("tecs.debug: %s takes four numbers, red, green, blue and alpha, not %d"):format(name, #value), 3)
    end
    return value[1], value[2], value[3], value[4]
end

function colliders.of(world: World): colliders.Overlay
    return world.resources[overlayKey] as colliders.Overlay
end

function colliders.install(world: World, renderer: Renderer, options?: colliders.Options): colliders.Overlay
    if world == nil then
        error("tecs.debug: the collider overlay needs a world", 2)
    end
    if renderer == nil then
        error("tecs.debug: the collider overlay needs a renderer to draw through", 2)
    end

    local existing <const> = world.resources[overlayKey]
    if existing ~= nil then
        return existing as colliders.Overlay
    end

    local config <const> = options or {}
    local layer <const> = config.layer or DEFAULT_LAYER
    if layer < 1 or layer > layers.MAX then
        error(("tecs.debug: the collider overlay's layer is 1 to %d, not %d"):format(layers.MAX, layer), 2)
    end
    local thickness <const> = config.thickness or DEFAULT_THICKNESS
    if thickness <= 0.0 then
        error("tecs.debug: the collider overlay's thickness is a positive number of screen pixels", 2)
    end
    local requested <const> = config.segments or DEFAULT_SEGMENTS
    if requested < 4 then
        error(("tecs.debug: the collider overlay tessellates into 4 segments or more, not %d"):format(requested), 2)
    end
    -- Even, so a capsule's caps are the circle's own points.
    local segments <const> = requested % 2 == 0 and requested or requested + 1

    local self <const> = setmetatable({} as Outlines, OutlinesMT)
    self._enabled = false
    self._rebuild = false
    self._released = false
    self._world = world
    self._renderer = renderer
    self._capacity = 0
    self._reserved = 0
    self._used = 0
    self._spans = {}
    self._spanCount = 0
    self._walkIndex = 0
    self._walkOffset = 0
    self._dirty = {}
    self._dirtyCount = 0
    self._taken = false
    self._zoom = 1.0
    self._alpha = 0.0
    self._width = thickness
    self._thickness = thickness
    self._segments = segments
    self._caps = floor(segments / 2)
    self._unit = unitCircle(segments)
    self._shapes = 0
    self._dropped = 0
    self._r, self._g, self._b, self._a = colorOf(config.color, "color", DEFAULT_COLOR)
    self._sensorR, self._sensorG, self._sensorB, self._sensorA = colorOf(
        config.sensorColor, "sensorColor", DEFAULT_SENSOR_COLOR
    )

    -- Sorted by z and unlit, and nothing else: screen space, virtual
    -- coordinates, parallax and ignored zoom each stop the view culling the
    -- layer, and an overlay over a hundred thousand colliders wants the cull
    -- more than any of them.
    layers.configure(layer, {sort = "z", unlit = true})
    -- One depth for every quad, at the front of the layer's band. The outlines
    -- do not sort against each other, so there is nothing for a per-quad depth
    -- to decide.
    self._layer = layer
    self._depth = layers.depthOf(layer, layers.maxZ, 0.0, 0.0)

    renderer.sprites:addProducer(self as Renderer.SpriteInstanceProducer)

    -- Physics writes transforms in `FixedPostUpdate`, so `PostUpdate` reads this
    -- frame's poses, and after `RelativeTransform2D` a parented body's world
    -- transform is the composed one. The system name is an externally typed
    -- compatibility surface, because the debug server reports it and an agent
    -- selects on it.
    world:addSystem({
        name = "tecs.ColliderOverlay",
        phase = ecs.phases.PostUpdate,
        after = {"RelativeTransform2D"},
        run = function() build(self) end,
    })

    world.resources[overlayKey] = self
    return self as colliders.Overlay
end

return colliders
