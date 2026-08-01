--[=[
A sprite sheet divides one image into frames, tags, and slices.

Aseprite supplies the model: each frame carries its own duration, tags play
inclusive spans in a direction, and slices carry rectangles, nine-slice
centers, and pivots that may move between frames. `fromAseprite` reads its JSON
export into the same interface that `grid`, `rects`, and `build` produce.

Frames count from one in sheet order. Tag zero represents the whole sheet
playing forward.

Bind the finished sheet to a renderer sprite before drawing:

```teal
local hero <const> = tecs.gfx.animation.newSheetFromAseprite({
    name = "game.hero",
    json = asepriteExport,
})

hero:bind(app.renderer.sprites:sprite("sprites/hero.png"))
```

`sprite(frame)` creates a [`Sprite`](tealdoc:tecs.components.Sprite) for one frame.
`pivot(name, frame)` creates a
[`Pivot`](tealdoc:tecs.gfx.animation.Pivot) from a slice. Animation keeps that
pivot on the named slice as the slice moves.

A sheet name forms a snapshot compatibility surface. Every entity that plays
the sheet shares its registered frame, tag, slice, and timing data.
]=]
-- Implementation details:
-- Components carry the sheet's interned id rather than its table. The registry
-- resolves snapshot names and lets all entities share one sheet.
--
-- Sheets retain frame rectangles in source-image pixels until `bind` receives
-- the image's texture-array placement. Binding converts each frame and slice
-- into the UV coordinates that `Sprite` stores.

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local components <const> = require("tecs.components")
local log <const> = require("tecs.log")

local type Component = ecs.Component
local type World = types.World
local type Sprite = components.Sprite

local floor <const> = math.floor
local sort <const> = table.sort
local concat <const> = table.concat

-- "tecs.gfx" is the category the graphics modules already log under, and a
-- logger name is configuration a developer filters on rather than an
-- identifier, so this shares theirs instead of opening one for sheets.
local logger <const> = log.get("tecs.gfx")

--- Milliseconds a frame is held when nothing says otherwise, which is what
--- Aseprite writes for a frame nobody retimed.
local DEFAULT_DURATION <const> = 100.0

--- Bumped whenever a frame's region moves, which is registration and `bind`.
---
--- Anything holding a copy of those regions compares this against what it
--- copied from, which keeps the dependency running one way: a sheet knows
--- nothing about who read it.
local revision = 0

--- Selects how a tag walks its span.
---
--- `pingpong` plays forward and then back without repeating either end, so a
--- three-frame tag is 1, 2, 3, 2 and then round again.
local enum Direction
    --- Read-only. Plays the tag from its first frame to its last.
    "forward"
    --- Read-only. Plays the tag from its last frame to its first.
    "reverse"
    --- Read-only. Plays forward and then backward without repeating either
    --- endpoint.
    "pingpong"
end

--- Defines one frame's pixel rectangle and duration.
local record Rect
    --- Caller-writable. Sets the frame's left edge in image pixels.
    x: number
    --- Caller-writable. Sets the frame's top edge in image pixels.
    y: number
    --- Caller-writable. Sets the frame width in pixels.
    w: number
    --- Caller-writable. Sets the frame height in pixels.
    h: number
    --- Caller-writable. Sets the frame duration in milliseconds and defaults
    --- to `sheet.DEFAULT_DURATION`.
    duration: number
end

--- Defines an inclusive frame span and playback direction.
---
--- Aseprite calls this a frame tag, and a tag's name is what an animation asks
--- for.
local record Tag
    --- Caller-writable. Sets the first frame index in the inclusive span.
    from: integer
    --- Caller-writable. Sets the last frame index in the inclusive span.
    to: integer
    --- Caller-writable. Sets the playback direction and defaults to
    --- `"forward"`.
    direction: Direction
end

--- Defines where a slice sits from one frame onward and which points it
--- carries.
---
--- A slice holds a key until the next one, so a slice that never moves is one
--- key at frame one.
local record SliceKey
    --- Caller-writable. Sets the first frame on which this key takes effect,
    --- counting from one.
    frame: integer
    --- Caller-writable. Sets the slice rectangle's left edge in frame pixels.
    x: number
    --- Caller-writable. Sets the slice rectangle's top edge in frame pixels.
    y: number
    --- Caller-writable. Sets the slice rectangle's width in pixels.
    w: number
    --- Caller-writable. Sets the slice rectangle's height in pixels.
    h: number
    --- Caller-writable. Sets the nine-slice center's left edge in slice
    --- pixels. Nil means the slice has no center.
    centerX: number
    --- Caller-writable. Sets the nine-slice center's top edge in slice pixels.
    centerY: number
    --- Caller-writable. Sets the nine-slice center's width in pixels.
    centerW: number
    --- Caller-writable. Sets the nine-slice center's height in pixels.
    centerH: number
    --- Caller-writable. Sets the horizontal pivot in slice pixels. Nil means
    --- the slice has no pivot.
    pivotX: number
    --- Caller-writable. Sets the vertical pivot in slice pixels. Nil means the
    --- slice has no pivot.
    pivotY: number
end

--- Represents a named region that moves across frames.
---
--- Aseprite's slices carry hitboxes, attachment points and nine-patch borders.
--- The engine reads pivots out of them; everything else is the game's to use.
local record Slice
    --- Caller-writable. Sets the name used to find the slice.
    name: string
    --- Caller-writable. Stores free text carried by Aseprite.
    data: string
    --- Caller-writable. Sets at least one key in frame order.
    keys: {SliceKey}
end

--- Sets the point around which an entity's quad rotates and scales.
---
--- A quad with no Pivot turns about its center, so a character rotates about
--- its waist and a scale grows it in both directions at once. A quad with one
--- turns about the point the pivot names, and the entity's Transform2D position
--- is where that point lands: a character pivoted at its feet stands at its
--- position instead of hovering half a body above it.
---
--- The point is a fraction of the frame rather than a distance in pixels,
--- because that is what an artist places in Aseprite and what `pivotOf`
--- answers. A frame that changes size therefore carries its pivot with it.
---
--- `sheet` and `slice` identify the source of the fraction. Playback resolves a
--- moving slice on every frame change while the entity plays that sheet. Zero
--- for both fields marks a direct pivot that playback never rewrites.
local record Pivot is Component
    --- Caller-writable. Sets the pivot as a fraction across the frame from its
    --- left edge. One half selects the middle.
    x: number
    --- Caller-writable. Sets the pivot as a fraction down the frame from its
    --- top edge. One half selects the middle.
    y: number
    --- Caller-writable. Selects the sheet that owns the slice by registration
    --- index, or zero for a direct pivot.
    sheet: number
    --- Caller-writable. Selects the slice within that sheet by its
    --- `Sheet:sliceId` index, or zero
    --- for a pivot written directly.
    slice: number
    --- Engine-owned. Stores half the horizontal range that the point may travel
    --- over the current cycle, as a fraction of the frame.
    ---
    --- A direct pivot or single-key slice uses zero, keeping the quad's exact
    --- cull bound. A moving slice uses `x` and `y` for the travel midpoint and
    --- this field for its reach on either side.
    halfX: number
    --- Engine-owned. Stores the pivot's vertical travel for culling. Ordinary
    --- game code should ignore this field.
    halfY: number
end

--- Represents an image divided into frames.
local record Sheet
    --- Read-only. Reports the registered name that snapshots store.
    name: string
    --- Read-only. Reports the registration index carried by an
    --- [`Animation`](tealdoc:tecs.gfx.animation.Animation). Construction assigns
    --- an id once and never reuses it.
    id: integer
    --- Read-only. Reports the number of frames and the largest index `rect`, `uv` and `sprite`
    --- accept.
    count: integer
    --- Read-only. Reports the source image width in pixels. Frame rectangles use
    --- this width, so binding the sheet to an image of a different size places
    --- frames incorrectly.
    imageWidth: number
    --- Read-only. Reports the height in pixels of the image from which frames
    --- are cut.
    imageHeight: number

    --- Engine-owned. Stores frame rects in pixels. Ordinary game code should
    --- use `rect`.
    _rects: {number}
    --- Engine-owned. Stores each frame's duration in seconds. Ordinary game
    --- code should use `duration`. Construction converts authored milliseconds
    --- to seconds so playback never divides.
    _durations: {number}
    --- Engine-owned. Stores frame regions. Ordinary game code should use `uv`.
    --- Values remain fractions of
    --- the image until `bind`, of the texture-array layer after it.
    _uvs: {number}
    --- Engine-owned. Stores tag spans by tag id. Ordinary game code should use
    --- the tag methods. Index zero is the
    --- whole sheet forward, which is what an animation naming no tag plays.
    _from: {integer}
    --- Engine-owned. Stores tag endpoints. Ordinary game code should ignore
    --- this field.
    _to: {integer}
    --- Engine-owned. Stores tag directions. Ordinary game code should ignore
    --- this field.
    _direction: {Direction}
    --- Engine-owned. Stores tag names. Ordinary game code should ignore this
    --- field.
    _names: {string}
    --- Engine-owned. Stores tag ids. Ordinary game code should ignore this
    --- field.
    _ids: {string: integer}
    --- Engine-owned. Stores the frame index at each step of a tag's cycle.
    --- Ordinary game code should ignore this field. This is
    --- what collapses the three directions into one lookup: the direction
    --- decides the order once, when the sheet is built, and playback walks it.
    _order: {{integer}}
    --- Engine-owned. Stores elapsed seconds at each step of a tag's cycle.
    --- Ordinary game code should ignore this field. Tag ids index the values,
    --- including the complete cycle length.
    _timing: {{number}}
    --- Engine-owned. Stores total cycle durations. Ordinary game code should
    --- use `cycle`.
    _cycle: {number}
    --- Engine-owned. Stores slices by index. Ordinary game code should use
    --- `slice`.
    _slices: {Slice}
    --- Engine-owned. Stores slice ids by name. Ordinary game code should use
    --- `sliceId`.
    _sliceIds: {string: integer}

    --- Engine-owned. Stores the image index resolved by `bind`. Ordinary game
    --- code should ignore this field.
    _image: number
    --- Engine-owned. Stores the texture-array layer resolved by `bind`.
    --- Ordinary game code should ignore this field.
    _slot: number
    -- Implementation details:
    -- A packed cell may hold several images, so frame UVs apply both an origin
    -- and a scale.
    --- Engine-owned. Stores the horizontal origin within the texture-array
    --- cell. Ordinary game code should ignore this field.
    _originU: number
    --- Engine-owned. Stores the vertical origin within the texture-array cell.
    --- Ordinary game code should ignore this field.
    _originV: number
    --- Engine-owned. Stores the horizontal scale within the texture-array
    --- cell. Ordinary game code should ignore this field.
    _scaleU: number
    --- Engine-owned. Stores the vertical scale within the texture-array cell.
    --- Ordinary game code should ignore this field.
    _scaleV: number
    --- Returns a frame's pixel rectangle as x, y, width, and height.
    --- @param frame One to `count`. Anything else raises, since a frame index
    ---     out of range is a sheet and an animation disagreeing rather than
    ---     something to paper over.
    --- @return The rect's left, top, width and height, in the pixels of the
    ---     image the sheet was cut from.
    rect: function(self, frame: integer): number, number, number, number

    --- Returns how long a frame remains visible, in seconds.
    --- @param frame One to `count`. Anything else raises.
    --- @return Returns the authored frame duration in seconds.
    duration: function(self, frame: integer): number

    --- Returns a frame's region as u0, v0, u1, and v1.
    ---
    --- Fractions of the image before `bind` and of the texture-array layer
    --- after it, which is the region a
    --- [`Sprite`](tealdoc:tecs.components.Sprite) needs.
    --- @param frame One to `count`. Anything else raises.
    --- @return The region's left, top, right and bottom edges.
    uv: function(self, frame: integer): number, number, number, number

    --- Returns whether the sheet contains the given tag.
    --- @param name Any string, and nil answers false rather than raising, so
    ---     this is what to ask before `tag`.
    --- @return Whether `tag` would answer for that name.
    hasTag: function(self, name: string): boolean

    --- Returns the first frame, last frame, and direction of a named tag.
    ---
    --- Fails on a name the sheet does not carry, because the alternative is an
    --- animation silently playing the whole sheet on a typo.
    --- @param name A tag this sheet was built with.
    --- @return The tag's first frame index, its last, and its direction.
    tag: function(self, name: string): integer, integer, Direction

    --- Returns the index represented by a tag name, or zero when absent.
    ---
    --- Zero reads as the whole sheet rather than as nothing, so an animation
    --- that names no tag plays every frame in order.
    ---
    --- A name the sheet does not carry is reported at error level under the
    --- `tecs.gfx` logger and then treated as the whole sheet. Zero is a
    --- plausible wrong answer rather than a visible failure, so a misspelled
    --- tag would otherwise animate every frame with nothing said. The report
    --- names the sheet, the name asked for, and the tags the sheet does carry,
    --- once per sheet and name however often the name is asked. Ask `hasTag`
    --- instead when a name's absence is expected and ordinary.
    --- @param name A tag name, or nil or the empty string for the whole sheet.
    ---     The empty string is what a snapshot stores for tag zero, so neither
    ---     it nor nil is reported.
    --- @return Returns the index an
    ---     [`Animation`](tealdoc:tecs.gfx.animation.Animation) carries. The
    ---     index belongs to this sheet alone: ids follow tag names in sorted
    ---     order, so the same name in another sheet has another number.
    tagId: function(self, name: string): integer

    --- Returns the name represented by a tag index, or the empty string for
    --- the whole sheet.
    --- @param id An index from `tagId`. Nil, zero and anything the sheet does
    ---     not carry all answer the empty string.
    --- @return The tag's name, which is what a snapshot writes instead of the
    ---     index.
    tagName: function(self, id: integer): string

    --- Returns the duration of one tag cycle in seconds.
    --- @param id A tag index, or zero for the whole sheet.
    --- @return The sum of the durations of the frames the cycle visits, which
    ---     for a pingpong tag counts the frames it passes twice twice.
    cycle: function(self, id: integer): number

    --- Returns the frame shown by a tag at a point in its cycle.
    --- @param id A tag index, or zero for the whole sheet.
    --- @param time Seconds into the cycle. Outside it clamps rather than
    ---     wrapping, since wrapping is the caller's decision about looping.
    --- @return A frame index into the whole sheet, counting from one.
    frameAt: function(self, id: integer, time: number): integer

    --- Returns a slice by name, or nil when the sheet does not contain one.
    --- @param name A slice name.
    --- @return The slice, whose keys the caller must not mutate.
    slice: function(self, name: string): Slice

    --- Returns the index represented by a slice name, or zero when absent.
    --- @param name A slice name, or nil.
    --- @return The index, which is what a component carries in place of the
    ---     name for the reason a tag id is.
    sliceId: function(self, name: string): integer

    --- Returns the name represented by a slice index, or the empty string.
    ---
    --- @param id A slice index from `sliceId`. Zero or an absent index returns
    ---     the empty string.
    --- @return The slice name, or the empty string when the index is absent.
    sliceName: function(self, id: integer): string

    --- Returns the slice key active on a frame, or nil.
    ---
    --- A slice holds a key until the next one, so this answers the last key at
    --- or before the frame rather than only an exact match.
    --- @param id A slice index from `sliceId`. Zero answers nil.
    --- @param frame A frame index.
    sliceKeyAt: function(self, id: integer, frame: integer): SliceKey

    --- Returns a slice pivot as a fraction of its frame.
    ---
    --- Aseprite writes a pivot in the slice's own pixels, so this adds the
    --- slice's origin and divides by the frame, which is the number a quad
    --- wants: nothing downstream has to know the sheet's pixel sizes.
    ---
    --- A slice with a center but no pivot answers the center's middle, and a
    --- slice with neither answers the middle of its own rectangle. Zero, a
    --- slice the sheet does not carry, or a frame it has no key for all answer
    --- the middle of the frame, which is where a quad sits with no pivot at
    --- all.
    --- @param id A slice index from `sliceId`.
    --- @param frame A frame index.
    --- @return The pivot's x and y as fractions of the frame, from its top
    ---     left.
    pivotOf: function(self, id: integer, frame: integer): number, number

    --- Creates a Pivot from a named slice, ready to spawn.
    ---
    --- Bound to the slice as well as resolved from it, so playback moves the
    --- pivot as the frame changes rather than leaving it where the frame it
    --- was built from put it.
    ---
    --- Fails on a name the sheet does not carry, for the reason `tag` does:
    --- the alternative is a typo that silently pivots on the middle.
    --- @param name A slice this sheet carries.
    --- @param frame The frame to resolve it at, defaulting to the first. What
    ---     an entity shows before its first step, and what a sheet with no
    ---     Animation keeps.
    --- @return A component value, not an entity.
    pivot: function(self, name: string, frame?: integer): Pivot

    --- Resolves the sheet's frames against a registered image.
    ---
    --- `sprite` is what `renderer.sprites:sprite(name)` returns for a whole image: its
    --- `u1` and `v1` are the fractions of the texture-array layer that image
    --- occupies. The function scales the frame's image fraction by them
    --- before it names a region of the layer. Pass a sub-rect and the frames
    --- land inside that sub-rect, which is not what the sheet describes.
    ---
    --- Binding again rescales from the pixel rectangles instead of the previous
    --- result, so re-registering an image does not accumulate scaling error.
    --- Entities already carrying regions from an earlier bind keep them: a
    --- rebind does not update any existing [`Sprite`](tealdoc:tecs.components.Sprite).
    --- @param sprite A whole image, from `renderer.sprites:sprite`.
    --- @return Returns the sheet so callers can chain `bind`.
    bind: function(self, sprite: Sprite): Sheet

    --- Creates a Sprite showing one frame, ready to spawn.
    ---
    --- Defaults to the first frame. Meaningful after `bind`, since before it
    --- the sheet names no image and the quad has no layer to sample.
    --- @param frame One to `count`, defaulting to one. Anything else raises.
    --- @return Returns a fresh [`Sprite`](tealdoc:tecs.components.Sprite) that the
    ---     caller owns, not a view onto the sheet.
    sprite: function(self, frame?: integer): Sprite
end

local SheetMT <const>: metatable<Sheet> = {__index = Sheet}

--- Configures a sheet cut into a uniform grid.
local record GridOptions
    --- Caller-writable. Sets the required registration name.
    name: string
    --- Caller-writable. Sets the required image width in pixels.
    imageWidth: number
    --- Caller-writable. Sets the required image height in pixels.
    imageHeight: number
    --- Caller-writable. Sets the required frame width in pixels.
    frameWidth: number
    --- Caller-writable. Sets the required frame height in pixels.
    frameHeight: number
    --- Caller-writable. Sets the border between the image edge and first cell.
    --- Defaults to zero.
    margin: number
    --- Caller-writable. Sets the gap between neighboring cells and defaults to
    --- zero.
    spacing: number
    --- Caller-writable. Sets how many cells fit across. The constructor derives
    --- it from the image size when omitted.
    columns: integer
    --- Caller-writable. Sets how many cells fit down. The constructor derives
    --- it from the image size when omitted.
    rows: integer
    --- Caller-writable. Sets how many frames to take across rows. It defaults to every cell, which is
    --- wrong only for a sheet whose last row is short.
    count: integer
    --- Caller-writable. Sets how many milliseconds every cell remains visible.
    --- It defaults to `DEFAULT_DURATION`. A grid uses one duration for every
    --- frame; retime individual frames with `sheet.build`.
    duration: number
    --- Caller-writable. Defines optional named tags over the frames.
    tags: {string: Tag}
    --- Caller-writable. Defines optional named slices.
    slices: {Slice}
end

--- Configures a sheet cut into explicitly listed rectangles.
local record RectsOptions
    --- Caller-writable. Sets the required registration name.
    name: string
    --- Caller-writable. Sets the required image width in pixels.
    imageWidth: number
    --- Caller-writable. Sets the required image height in pixels.
    imageHeight: number
    --- Caller-writable. Sets the required frame rects in address order.
    frames: {Rect}
    --- Caller-writable. Defines optional named tags over the frames.
    tags: {string: Tag}
    --- Caller-writable. Defines optional named slices.
    slices: {Slice}
end

--- Configures a sheet read from an Aseprite JSON export.
local record AsepriteOptions
    --- Caller-writable. Sets the registration name. It defaults to the export's
    --- image name. An export without an image name requires this field.
    name: string
    --- Caller-writable. Supplies the export as JSON text or a decoded table.
    --- it. A table is what an asset pipeline that decoded once should pass.
    json: any
end

--- Builds a sheet one frame, tag, and slice at a time.
---
--- What every constructor here goes through, and what an importer for a format
--- nothing else reads writes into.
local record Builder
    --- Engine-owned. Stores the sheet under construction. Ordinary game code
    --- should use the builder methods.
    _sheet: Sheet
    --- Engine-owned. Stores tags under construction. Ordinary game code should
    --- use `tag`.
    _tags: {string: Tag}
    --- Engine-owned. Stores slices under construction. Ordinary game code
    --- should use `slice` or `sliceKeys`.
    _slices: {Slice}

    --- Appends a frame to the sheet under construction.
    --- @param x Left of the frame in the image, in pixels.
    --- @param y Top of the frame.
    --- @param w Width, which must be positive.
    --- @param h Height, which must be positive.
    --- @param duration Milliseconds it is held. Defaults to
    ---     `sheet.DEFAULT_DURATION`.
    --- @return The builder.
    frame: function(self, x: number, y: number, w: number, h: number, duration?: number): Builder

    --- Names an inclusive frame span and its playback direction.
    --- @param name What an animation asks for.
    --- @param from First frame, counting from one.
    --- @param to Last frame, inclusive.
    --- @param direction Defaults to "forward".
    --- @return The builder.
    tag: function(self, name: string, from: integer, to: integer, direction?: Direction): Builder

    --- Adds a fixed slice with a pivot.
    --- @param name What a sprite names to take its pivot from.
    --- @param x Left of the slice within a frame, in pixels.
    --- @param y Top of the slice.
    --- @param w Width.
    --- @param h Height.
    --- @param pivotX Pivot within the slice, in the slice's own pixels.
    ---     Omitted, the slice carries no pivot and its middle stands in.
    --- @param pivotY
    --- @return The builder.
    slice: function(
        self, name: string, x: number, y: number, w: number, h: number, pivotX?: number, pivotY?: number
    ): Builder

    --- Adds a slice from explicit keys for importers.
    --- @param name The slice's name.
    --- @param data Free text to carry alongside it, or nil for none.
    --- @param keys Keys in frame order, at least one.
    --- @return The builder.
    sliceKeys: function(self, name: string, data: string, keys: {SliceKey}): Builder

    --- Registers and returns the finished sheet.
    ---
    --- Raises on a sheet with no frames, and on a tag whose span falls outside
    --- them.
    finish: function(self): Sheet
end

local BuilderMT <const>: metatable<Builder> = {__index = Builder}

--- Provides sheet constructors, their process-wide registry, and the Pivot
--- into, and the [`Pivot`](tealdoc:tecs.gfx.animation.Pivot) component a slice
--- resolves to.
---
--- Registration is per process rather than per world, so a sheet built once is
--- reachable from every world by id or by name.
local record sheet
    --- Selects how a tag walks its span.
    type Direction = Direction
    --- One frame, as `rects` and the builder take it.
    type Rect = Rect
    --- A named span of frames, as the constructors take it.
    type Tag = Tag
    --- A named region that moves across the frames.
    type Slice = Slice
    --- Defines where a slice sits from one frame onward.
    type SliceKey = SliceKey
    --- Configures `grid`.
    type GridOptions = GridOptions
    --- Configures `rects`.
    type RectsOptions = RectsOptions
    --- Configures `fromAseprite`.
    type AsepriteOptions = AsepriteOptions
    --- Builds custom sheets one frame at a time.
    type Builder = Builder

    --- Read-only. Exposes an image divided into frames.
    Sheet: Sheet

    --- Read-only. Exposes the pivot component that controls where an entity's
    --- quad turns and scales.
    Pivot: Pivot

    --- Read-only. Reports how many milliseconds a frame remains visible when
    --- nothing overrides its duration.
    DEFAULT_DURATION: number

    --- Creates a sheet whose frames form a uniform grid.
    ---
    --- Margin surrounds the grid and spacing separates the cells, so a cell's
    --- left edge is `margin + column * (frameWidth + spacing)`. Both default to
    --- zero, which is an image cut with nothing between its cells.
    --- @param options Raises on a missing name, a non-positive image or frame
    ---     size, a grid that fits no cells, or a `count` past what the grid
    ---     holds. Frames come out in row-major order.
    --- @return The finished sheet, already registered under its name and
    ---     carrying an `id`.
    grid: function(options: GridOptions): Sheet

    --- Creates a sheet from explicitly listed frame rectangles.
    ---
    --- For an image no grid describes: frames of differing sizes, or an atlas
    --- whose cells a packing tool placed.
    --- @param options Raises on a missing name, a non-positive image size, an
    ---     empty frame list, or a frame with no positive size. Rects are not
    ---     checked against the image, so one that runs off the edge samples
    ---     whatever the layer holds there.
    --- @return The finished sheet, already registered under its name and
    ---     carrying an `id`.
    rects: function(options: RectsOptions): Sheet

    --- Creates a builder for a sheet that the other constructors cannot
    --- describe.
    ---
    --- The model is what the builder writes, so an atlas from any tool reaches
    --- the same sheet an Aseprite export does. Frames, tags and slices are
    --- added in any order. `build` registers the finished sheet.
    --- @param name Name to register the finished sheet under.
    --- @param imageWidth Size of the image the frames are cut from, in pixels.
    --- @param imageHeight
    --- @return A builder whose methods chain.
    build: function(name: string, imageWidth: number, imageHeight: number): Builder

    --- Creates a sheet from an Aseprite JSON export.
    ---
    --- One reader in front of the model rather than a second model: frames,
    --- their durations, frame tags with their directions, and slices with their
    --- keys all land in the sheet the builder writes.
    ---
    --- The reader accepts Aseprite's array layout and its object layout, sorting
    --- the latter by frame name. It ignores `spriteSourceSize`, so export with
    --- trimming off.
    --- @param options The export and the name to register it under.
    --- @return The finished sheet.
    fromAseprite: function(options: AsepriteOptions): Sheet

    --- Returns the sheet represented by a registration index, or nil.
    --- @param id An `id` from a sheet this process built. Construction assigns
    ---     ids in order, so each id is meaningful only within one run.
    --- @return The sheet, or nil for an id nothing was built under.
    byId: function(id: integer): Sheet

    --- Returns the sheet registered under a name, or nil.
    ---
    --- Building a second sheet under a name already taken replaces what this
    --- returns, so a reload points new entities at the new sheet. Entities
    --- already carrying the old id keep drawing the old one, which is what
    --- stops a reload from pulling a frame out from under them.
    --- @param name The name a sheet was built under.
    --- @return The sheet most recently registered under that name, or nil.
    byName: function(name: string): Sheet

    --- Folds a freshly built sheet into the one already registered under its
    --- name, keeping the old sheet's id.
    ---
    --- The reverse of what building under a taken name does, and it exists
    --- because a reload wants the reverse. Building again answers new entities
    --- with the new sheet and leaves every entity already playing on the old
    --- one, which is right for two sheets that happen to share a name and wrong
    --- for one file that was re-exported. This overwrites in place instead, so
    --- an [`Animation`](tealdoc:tecs.gfx.animation.Animation) holding the id
    --- continues and shows the new frames on its next step without changing the
    --- world.
    ---
    --- The refusals are the same ones a shader reload makes, for the same
    --- reason: a component holds an index into this sheet, so anything that
    --- this function refuses changes that renumber one. Tag ids follow the
    --- tag names in sorted order and slice ids follow the slices, so adding,
    --- removing or renaming either is a restart. Frames are free to change:
    --- an entity carries a tag and time, and each step resolves its frame from
    --- the cycle.
    ---
    --- Replacement preserves the existing bind and rescales frames against the
    --- old sheet's image region, so callers need not call `bind` again.
    ---
    --- The sheet handed in is spent. Its id resolves to the live sheet rather
    --- than to itself, because the two share their frame tables once the fold
    --- is done and only one of them may be bound.
    --- @param built A sheet from any constructor here, registered moments ago
    ---     under a name something else already holds.
    --- @return Returns the live sheet and nil, or nil and the refusal reason.
    replace: function(built: Sheet): Sheet, string

    --- Returns how many times any sheet's frames have changed.
    ---
    --- Bumped by registration and by `bind`, both of which move where a frame's
    --- region points. Anything holding a copy of those regions compares this
    --- against what it copied from rather than being told, which keeps the
    --- dependency running one way: a sheet knows nothing about who read it.
    --- @return A number that only ever increases.
    revision: function(): integer
end

sheet.Sheet = Sheet
sheet.DEFAULT_DURATION = DEFAULT_DURATION

-------------------------------------------------------------------------------
-- Frames
-------------------------------------------------------------------------------

function Sheet:rect(frame: integer): number, number, number, number
    if frame == nil or frame < 1 or frame > self.count then
        error(("tecs: sheet '%s' has no frame %s"):format(self.name, tostring(frame)), 2)
    end
    local base = (frame - 1) * 4
    local rects = self._rects
    return rects[base + 1], rects[base + 2], rects[base + 3], rects[base + 4]
end

function Sheet:duration(frame: integer): number
    if frame == nil or frame < 1 or frame > self.count then
        error(("tecs: sheet '%s' has no frame %s"):format(self.name, tostring(frame)), 2)
    end
    return self._durations[frame]
end

function Sheet:uv(frame: integer): number, number, number, number
    if frame == nil or frame < 1 or frame > self.count then
        error(("tecs: sheet '%s' has no frame %s"):format(self.name, tostring(frame)), 2)
    end
    local base = (frame - 1) * 4
    local uvs = self._uvs
    return uvs[base + 1], uvs[base + 2], uvs[base + 3], uvs[base + 4]
end

-------------------------------------------------------------------------------
-- Tags
-------------------------------------------------------------------------------

function Sheet:hasTag(name: string): boolean
    return name ~= nil and self._ids[name] ~= nil
end

function Sheet:tag(name: string): integer, integer, Direction
    local id = self._ids[name]
    if id == nil then
        error(("tecs: sheet '%s' has no tag '%s'"):format(self.name, tostring(name)), 2)
    end
    return self._from[id], self._to[id], self._direction[id]
end

--- Unknown tag names already reported, keyed by the sheet's id and then the
--- name.
---
--- A sheet's tag names are fixed once it is registered, because `replace`
--- refuses a build that would renumber them, so an entry here never goes stale
--- and a name reported once stays reported.
local reportedTags: {integer: {string: boolean}} = {}

--- Reports a tag name the sheet does not carry, once per sheet and name.
---
--- Zero reads as the whole sheet rather than as nothing, so a caller that
--- misspells a tag animates every frame instead of the span it named and no
--- other diagnostic fires. The report lists the tags the sheet does carry,
--- because a misspelling's answer is almost always one of them.
---
--- The memo is what makes reporting from the lookup itself safe: a caller that
--- asks every frame reports on its first frame and stays quiet afterwards.
local function reportUnknownTag(self: Sheet, name: string)
    local seen = reportedTags[self.id]
    if seen == nil then
        seen = {}
        reportedTags[self.id] = seen
    elseif seen[name] then
        return
    end
    seen[name] = true

    logger:error(
        "sheet '%s' has no tag '%s', so the whole sheet animates in place of "
            .. "the frames that name asked for; it carries %s",
        self.name,
        name,
        #self._names > 0 and concat(self._names, ", ") or "no tags"
    )
end

function Sheet:tagId(name: string): integer
    -- The empty string is what a snapshot writes for tag zero, so it names the
    -- whole sheet exactly as nil does and neither is a mistake to report.
    if name == nil or name == "" then
        return 0
    end
    local id <const> = self._ids[name]
    if id ~= nil then
        return id
    end
    reportUnknownTag(self, name)
    return 0
end

function Sheet:tagName(id: integer): string
    if id == nil or id < 1 then
        return ""
    end
    return self._names[id] or ""
end

function Sheet:cycle(id: integer): number
    return self._cycle[id or 0] or 0.0
end

function Sheet:frameAt(id: integer, time: number): integer
    local order = self._order[id or 0]
    if order == nil then
        return 1
    end

    -- A linear scan, because a tag is a handful of steps and the comparison is
    -- against a number already in cache. A binary search costs more branches
    -- than it saves at these lengths.
    local timing = self._timing[id or 0]
    local steps <const> = #order
    for step = 1, steps do
        if time <= timing[step] then
            return order[step]
        end
    end
    return order[steps]
end

-------------------------------------------------------------------------------
-- Slices
-------------------------------------------------------------------------------

sheet.Pivot = Pivot

ecs.newFFIComponent({
    name = "Pivot",
    container = Pivot,
    fields = {
        {"x", "float"},
        {"y", "float"},
        {"sheet", "int32_t"},
        {"slice", "int32_t"},
        {"halfX", "float"},
        {"halfY", "float"},
    },
    -- The middle of the frame, which is where a quad with no Pivot at all
    -- sits: adding the component without saying where moves nothing.
    defaults = {0.5, 0.5, 0, 0, 0.0, 0.0},
    -- A sheet id and a slice id are this process's answers, decided by the
    -- order sheets and their slices were built in. What crosses a save is the
    -- pair of names, resolved again on the way back in, and the fraction goes
    -- with them so a pivot written directly survives as well. The travel is
    -- deliberately dropped: it is the playback's answer rather than the
    -- entity's, and the first step after a load writes it from the registration
    -- this run made.
    serialize = function(instance: Pivot): {string: any}
        local source = sheet.byId(instance.sheet as integer)
        local name: string = nil
        local slice: string = nil
        if source ~= nil then
            name = source.name
            slice = source:sliceName(instance.slice as integer)
        end
        return {
            x = instance.x,
            y = instance.y,
            sheet = name,
            slice = slice,
        }
    end,
    deserialize = function(_world: World, data: {string: any}): Pivot
        local source = sheet.byName(data.sheet as string)
        local id, slice = 0, 0
        if source ~= nil then
            id = source.id
            slice = source:sliceId(data.slice as string)
        end
        return Pivot(data.x as number, data.y as number, id, slice)
    end,
})

function Sheet:slice(name: string): Slice
    if name == nil then
        return nil
    end
    local id = self._sliceIds[name]
    if id == nil then
        return nil
    end
    return self._slices[id]
end

function Sheet:sliceId(name: string): integer
    if name == nil then
        return 0
    end
    return self._sliceIds[name] or 0
end

function Sheet:sliceName(id: integer): string
    if id == nil or id < 1 then
        return ""
    end
    local entry = self._slices[id]
    if entry == nil then
        return ""
    end
    return entry.name
end

function Sheet:sliceKeyAt(id: integer, frame: integer): SliceKey
    if id == nil or id < 1 then
        return nil
    end
    local entry = self._slices[id]
    if entry == nil then
        return nil
    end

    local keys = entry.keys
    local found: SliceKey = nil
    for index = 1, #keys do
        local key = keys[index]
        if key.frame > frame then
            break
        end
        found = key
    end
    return found
end

function Sheet:pivotOf(id: integer, frame: integer): number, number
    local key = self:sliceKeyAt(id, frame)
    if key == nil then
        return 0.5, 0.5
    end

    local _, _, width, height = self:rect(frame)
    if width <= 0 or height <= 0 then
        return 0.5, 0.5
    end

    local x, y = key.pivotX, key.pivotY
    if x == nil then
        -- A nine-patch names a center rather than a pivot, and the middle of
        -- that center is the point the patch is anchored on. Failing both, the
        -- middle of the slice's own rectangle is the only point it names.
        if key.centerX ~= nil then
            x = key.centerX + key.centerW * 0.5
            y = key.centerY + key.centerH * 0.5
        else
            x = key.w * 0.5
            y = key.h * 0.5
        end
    end
    return (key.x + x) / width, (key.y + y) / height
end

function Sheet:pivot(name: string, frame?: integer): Pivot
    local id <const> = self:sliceId(name)
    if id < 1 then
        error(("tecs: sheet '%s' has no slice '%s'"):format(self.name, tostring(name)), 2)
    end
    local x, y = self:pivotOf(id, frame or 1)
    return Pivot(x, y, self.id, id)
end

-------------------------------------------------------------------------------
-- Binding to a registered image
-------------------------------------------------------------------------------

--- Recomputes every frame's region from its pixel rect and the current scale.
local function rescale(self: Sheet)
    local rects, uvs = self._rects, self._uvs
    local width, height = self.imageWidth, self.imageHeight
    local scaleU, scaleV = self._scaleU, self._scaleV
    local originU, originV = self._originU, self._originV
    for i = 1, self.count do
        local base = (i - 1) * 4
        local x, y = rects[base + 1], rects[base + 2]
        uvs[base + 1] = originU + x / width * scaleU
        uvs[base + 2] = originV + y / height * scaleV
        uvs[base + 3] = originU + (x + rects[base + 3]) / width * scaleU
        uvs[base + 4] = originV + (y + rects[base + 4]) / height * scaleV
    end
end

function Sheet:bind(sprite: Sprite): Sheet
    self._image = sprite.image
    self._slot = sprite.slot
    self._originU = sprite.u0
    self._originV = sprite.v0
    self._scaleU = sprite.u1 - sprite.u0
    self._scaleV = sprite.v1 - sprite.v0
    rescale(self)
    -- Every frame's region just moved, so anything that copied them is stale.
    revision = revision + 1
    return self
end

function Sheet:sprite(frame?: integer): Sprite
    local u0, v0, u1, v1 = self:uv(frame or 1)
    return components.Sprite(self._image, u0, v0, u1, v1, self._slot)
end

-------------------------------------------------------------------------------
-- Registration
-------------------------------------------------------------------------------

--- Sheets by registration index and by name.
---
--- An id is what an Animation carries, because a component is plain C memory
--- and a sheet is a table. A name is what a snapshot carries, for the reason
--- an image's name rather than its texture-array layer is: an index depends on
--- the order sheets were built in, and a save read by a run that builds them in
--- another order would point at the wrong picture.
local sheetsById: {Sheet} = {}
local sheetsByName: {string: Sheet} = {}

--- The sheet a name held immediately before the one it holds now.
---
--- Building under a taken name replaces what `byName` answers, which is the
--- documented behavior and the wrong one for a file that was exported twice.
--- `replace` is the reverse of it and has to know what was displaced, and only
--- registration is in a position to say.
local displaced: {string: Sheet} = {}

function sheet.revision(): integer
    return revision
end

function sheet.byId(id: integer): Sheet
    if id == nil or id < 1 then
        return nil
    end
    return sheetsById[id]
end

function sheet.byName(name: string): Sheet
    if name == nil then
        return nil
    end
    return sheetsByName[name]
end

--- Writes the order and timing of one tag.
---
--- The direction is spent here rather than at every step of playback: what
--- comes out is the frames in the order they are shown and the second each one
--- ends on, so a lookup is a scan of numbers and never a branch on direction.
local function planTag(self: Sheet, id: integer, from: integer, to: integer, direction: Direction)
    local durations <const> = self._durations
    local order: {integer} = {}
    local timing: {number} = {}
    local elapsed = 0.0
    local steps = 0

    local function step(frame: integer)
        steps = steps + 1
        elapsed = elapsed + durations[frame]
        order[steps] = frame
        timing[steps] = elapsed
    end

    if direction == "reverse" then
        for frame = to, from, -1 do
            step(frame)
        end
    else
        for frame = from, to do
            step(frame)
        end
        if direction == "pingpong" and to > from then
            -- Neither end is repeated, so a three-frame tag is 1, 2, 3, 2 and
            -- the cycle is five frames long rather than six.
            for frame = to - 1, from + 1, -1 do
                step(frame)
            end
        end
    end

    self._order[id] = order
    self._timing[id] = timing
    self._cycle[id] = elapsed
end

--- Assigns tags to a sheet under construction.
---
--- Ids follow the names in sorted order rather than the order `pairs` happens
--- to hand them over, so the same table produces the same ids on every run.
--- Index zero is the whole sheet forward and is always planned, since that is
--- what an animation naming no tag plays.
local function addTags(self: Sheet, tags: {string: Tag}, level: integer)
    self._from, self._to, self._names, self._ids = {}, {}, {}, {}
    self._direction, self._order, self._timing, self._cycle = {}, {}, {}, {}

    self._from[0], self._to[0] = 1, self.count
    self._direction[0] = "forward"
    planTag(self, 0, 1, self.count, "forward")
    if tags == nil then
        return
    end

    local names: {string} = {}
    for name in pairs(tags) do
        names[#names + 1] = name
    end
    sort(names)

    for i = 1, #names do
        local name = names[i]
        local span = tags[name]
        local from, to = span.from, span.to
        if from == nil or to == nil then
            error(("tecs: tag '%s' of sheet '%s' needs a from and a to"):format(name, self.name), level)
        end
        if from < 1 or to > self.count or from > to then
            error(
                ("tecs: tag '%s' of sheet '%s' spans %d to %d, outside " .. "its %d frames"):format(
                    name, self.name, from, to, self.count
                ),
                level
            )
        end
        local direction <const> = span.direction or "forward"
        if direction ~= "forward" and direction ~= "reverse" and direction ~= "pingpong" then
            error(
                ("tecs: tag '%s' of sheet '%s' has no direction '%s'"):format(name, self.name, tostring(direction)),
                level
            )
        end
        self._from[i] = from
        self._to[i] = to
        self._direction[i] = direction
        self._names[i] = name
        self._ids[name] = i
        planTag(self, i, from, to, direction)
    end
end

--- Assigns slices, in the order they were given.
local function addSlices(self: Sheet, slices: {Slice}, level: integer)
    self._slices, self._sliceIds = {}, {}
    if slices == nil then
        return
    end

    for index = 1, #slices do
        local entry = slices[index]
        if entry.name == nil or entry.name == "" then
            error(("tecs: slice %d of sheet '%s' has no name"):format(index, self.name), level)
        end
        local keys = entry.keys
        if keys == nil or #keys < 1 then
            error(("tecs: slice '%s' of sheet '%s' has no keys"):format(entry.name, self.name), level)
        end
        self._slices[index] = entry
        self._sliceIds[entry.name] = index
    end
end

--- Fields every sheet needs whatever cut its frames.
local function newSheet(name: string, imageWidth: number, imageHeight: number, level: integer): Sheet
    if name == nil or name == "" then
        error("tecs: a sheet needs a name", level)
    end
    if imageWidth == nil or imageHeight == nil or imageWidth <= 0 or imageHeight <= 0 then
        error(("tecs: sheet '%s' needs the pixel size of its image"):format(name), level)
    end
    local self = setmetatable({} as Sheet, SheetMT)
    self.name = name
    self.imageWidth = imageWidth
    self.imageHeight = imageHeight
    self.count = 0
    self._rects = {}
    self._durations = {}
    self._uvs = {}
    self._slices = {}
    self._sliceIds = {}
    -- Unbound, a frame's region is its plain fraction of the image, which is
    -- what a sheet can say without a renderer.
    self._image = 0
    self._slot = -1
    self._originU = 0.0
    self._originV = 0.0
    self._scaleU = 1.0
    self._scaleV = 1.0
    return self
end

--- Registers a finished sheet and hands back its id.
local function register(self: Sheet, tags: {string: Tag}, slices: {Slice}, level: integer): Sheet
    if self.count < 1 then
        error(("tecs: sheet '%s' has no frames"):format(self.name), level)
    end
    addTags(self, tags, level + 1)
    addSlices(self, slices, level + 1)
    rescale(self)
    sheetsById[#sheetsById + 1] = self
    self.id = #sheetsById
    displaced[self.name] = sheetsByName[self.name]
    sheetsByName[self.name] = self
    revision = revision + 1
    return self
end

--- Whether two name-to-index maps hand out the same indices.
---
--- A name that appeared or went away is looked for before one that merely
--- moved, because adding a tag renumbers every tag after it alphabetically and
--- the name a refusal should carry is the one that was edited rather than the
--- first one the edit pushed along.
--- @return Whether they agree, and the name that does not when they do not.
local function sameIndices(before: {string: integer}, after: {string: integer}): boolean, string
    for name in pairs(before) do
        if after[name] == nil then
            return false, name
        end
    end
    for name in pairs(after) do
        if before[name] == nil then
            return false, name
        end
    end
    for name, id in pairs(before) do
        if after[name] ~= id then
            return false, name
        end
    end
    return true
end

function sheet.replace(built: Sheet): Sheet, string
    if built == nil then
        error("tecs: there is no sheet to replace with", 2)
    end
    -- What the name held before this build took it, since building is what
    -- registers and `built` has already taken the name by the time it is
    -- handed over.
    local live = displaced[built.name]
    if live == nil or live == built then
        return nil, ("no sheet is registered as '%s', so there is nothing to " .. "replace"):format(built.name)
    end

    -- Checked before anything is written, so a refusal leaves the live sheet
    -- exactly as it was rather than part way through.
    local ok, moved = sameIndices(live._ids, built._ids)
    if not ok then
        sheetsByName[built.name] = live
        return nil,
            ("sheet '%s' would renumber its tags at '%s', and an " .. "Animation already holds a tag index"):format(
                built.name, moved
            )
    end
    ok, moved = sameIndices(live._sliceIds, built._sliceIds)
    if not ok then
        sheetsByName[built.name] = live
        return nil,
            ("sheet '%s' would renumber its slices at '%s', and a " .. "Pivot already holds a slice index"):format(
                built.name, moved
            )
    end

    live.count = built.count
    live.imageWidth = built.imageWidth
    live.imageHeight = built.imageHeight
    live._rects = built._rects
    live._durations = built._durations
    live._uvs = built._uvs
    live._from = built._from
    live._to = built._to
    live._direction = built._direction
    live._names = built._names
    live._ids = built._ids
    live._order = built._order
    live._timing = built._timing
    live._cycle = built._cycle
    live._slices = built._slices
    live._sliceIds = built._sliceIds

    -- The bind is the live sheet's and is kept: a re-export of the same image
    -- lands on the layer that image already holds, so the frames are rescaled
    -- against it rather than waiting for `bind` to be called a second time.
    rescale(live)

    -- Both the name and the id the build took now answer the live sheet. The id
    -- is not given back, because an id is handed out once and never reused;
    -- what it does is resolve to the sheet its frames ended up in, so anything
    -- that read `built.id` between the build and this call is pointed at the
    -- right one. It also takes the build out of the registry, which matters:
    -- the two share their frame tables now, and a `bind` on one would write
    -- through the other.
    sheetsByName[built.name] = live
    sheetsById[built.id] = live
    displaced[built.name] = nil
    return live
end

-------------------------------------------------------------------------------
-- Builder
-------------------------------------------------------------------------------

function sheet.build(name: string, imageWidth: number, imageHeight: number): Builder
    local self = setmetatable({} as Builder, BuilderMT)
    self._sheet = newSheet(name, imageWidth, imageHeight, 3)
    self._tags = {}
    self._slices = {}
    return self
end

function Builder:frame(x: number, y: number, w: number, h: number, duration?: number): Builder
    local target <const> = self._sheet
    if w == nil or h == nil or w <= 0 or h <= 0 then
        error(("tecs: frame %d of sheet '%s' has no positive size"):format(target.count + 1, target.name), 2)
    end
    local index <const> = target.count + 1
    local base <const> = (index - 1) * 4
    local rects <const> = target._rects
    rects[base + 1] = x or 0.0
    rects[base + 2] = y or 0.0
    rects[base + 3] = w
    rects[base + 4] = h
    -- Seconds from here on. The model is authored in milliseconds because
    -- Aseprite is; playback runs on a step measured in seconds and should not
    -- divide once per row to find that out.
    target._durations[index] = (duration or DEFAULT_DURATION) / 1000.0
    target.count = index
    return self
end

function Builder:tag(name: string, from: integer, to: integer, direction?: Direction): Builder
    if name == nil or name == "" then
        error("tecs: a tag needs a name", 2)
    end
    self._tags[name] = {from = from, to = to, direction = direction}
    return self
end

function Builder:slice(
    name: string, x: number, y: number, w: number, h: number, pivotX?: number, pivotY?: number
): Builder
    return self:sliceKeys(
        name,
        nil,
        {
            {
                frame = 1,
                x = x,
                y = y,
                w = w,
                h = h,
                pivotX = pivotX,
                pivotY = pivotY,
            },
        }
    )
end

function Builder:sliceKeys(name: string, data: string, keys: {SliceKey}): Builder
    self._slices[#self._slices + 1] = {
        name = name,
        data = data or "",
        keys = keys,
    }
    return self
end

function Builder:finish(): Sheet
    return register(self._sheet, self._tags, self._slices, 2)
end

-------------------------------------------------------------------------------
-- Constructors
-------------------------------------------------------------------------------

function sheet.grid(options: GridOptions): Sheet
    local self = newSheet(options.name, options.imageWidth, options.imageHeight, 2)

    local frameWidth <const> = options.frameWidth
    local frameHeight <const> = options.frameHeight
    if frameWidth == nil or frameHeight == nil or frameWidth <= 0 or frameHeight <= 0 then
        error(("tecs: sheet '%s' needs a positive frame size"):format(self.name), 2)
    end

    local margin <const> = options.margin or 0.0
    local spacing <const> = options.spacing or 0.0

    -- The last cell in a row has no spacing after it, so the spacing is added
    -- back once before dividing rather than subtracted from every cell.
    local columns <const> = options.columns or floor((self.imageWidth - 2 * margin + spacing) / (frameWidth + spacing))
    local rows <const> = options.rows or floor((self.imageHeight - 2 * margin + spacing) / (frameHeight + spacing))
    if columns < 1 or rows < 1 then
        error(
            ("tecs: sheet '%s' fits no %gx%g cells in %gx%g pixels"):format(
                self.name, frameWidth, frameHeight, self.imageWidth, self.imageHeight
            ),
            2
        )
    end

    local count <const> = options.count or columns * rows
    if count < 1 or count > columns * rows then
        error(("tecs: sheet '%s' asks for %d frames from a %dx%d grid"):format(self.name, count, columns, rows), 2)
    end

    local duration <const> = (options.duration or DEFAULT_DURATION) / 1000.0
    local rects = self._rects
    for i = 1, count do
        local column = (i - 1) % columns
        local row = floor((i - 1) / columns)
        local base = (i - 1) * 4
        rects[base + 1] = margin + column * (frameWidth + spacing)
        rects[base + 2] = margin + row * (frameHeight + spacing)
        rects[base + 3] = frameWidth
        rects[base + 4] = frameHeight
        self._durations[i] = duration
    end
    self.count = count

    return register(self, options.tags, options.slices, 2)
end

function sheet.rects(options: RectsOptions): Sheet
    local self = newSheet(options.name, options.imageWidth, options.imageHeight, 2)

    local frames <const> = options.frames
    if frames == nil or #frames < 1 then
        error(("tecs: sheet '%s' lists no frames"):format(self.name), 2)
    end

    local rects = self._rects
    for i = 1, #frames do
        local frame = frames[i]
        if frame.w == nil or frame.h == nil or frame.w <= 0 or frame.h <= 0 then
            error(("tecs: frame %d of sheet '%s' has no positive size"):format(i, self.name), 2)
        end
        local base = (i - 1) * 4
        rects[base + 1] = frame.x or 0.0
        rects[base + 2] = frame.y or 0.0
        rects[base + 3] = frame.w
        rects[base + 4] = frame.h
        self._durations[i] = (frame.duration or DEFAULT_DURATION) / 1000.0
    end
    self.count = #frames

    return register(self, options.tags, options.slices, 2)
end

-------------------------------------------------------------------------------
-- Aseprite JSON
-------------------------------------------------------------------------------

--- The export's frames as a list, whichever of the two layouts it used.
---
--- Aseprite writes an array when the export is told to, and otherwise an object
--- keyed by the frame's name. The names carry the frame number, so sorting them
--- is what puts the object's frames back in order.
local function asepriteFrames(export: {string: any}): {{string: any}}
    local raw = export.frames
    if raw == nil then
        error("tecs: the Aseprite export names no frames", 4)
    end

    local list = raw as {{string: any}}
    if #list > 0 then
        return list
    end

    local keyed = raw as {string: {string: any}}
    local names: {string} = {}
    for name in pairs(keyed) do
        names[#names + 1] = name
    end
    sort(names)

    local ordered: {{string: any}} = {}
    for index = 1, #names do
        ordered[index] = keyed[names[index]]
    end
    return ordered
end

function sheet.fromAseprite(options: AsepriteOptions): Sheet
    local source = options.json
    if source is string then
        source = (require("tecs.data") as {string: function(string): any}).decodeJSON(source)
    end
    local export = source as {string: any}
    if export == nil then
        error("tecs: an Aseprite sheet needs the export to read", 2)
    end

    local meta = (export.meta or {}) as {string: any}
    local size = (meta.size or {}) as {string: number}
    local name = options.name or (meta.image as string)
    if name == nil or name == "" then
        error("tecs: the Aseprite export names no image, so the sheet " .. "needs a name of its own", 2)
    end

    local builder <const> = sheet.build(name, size.w, size.h)

    local frames <const> = asepriteFrames(export)
    for index = 1, #frames do
        local entry = frames[index]
        local rect = (entry.frame or {}) as {string: number}
        if rect.w == nil or rect.h == nil then
            error(("tecs: frame %d of the Aseprite export has no rectangle"):format(index), 2)
        end
        builder:frame(rect.x or 0.0, rect.y or 0.0, rect.w, rect.h, entry.duration as number)
    end

    -- Aseprite counts frames from zero and this model counts from one, so the
    -- span moves by one at the boundary and nowhere else.
    local tags = (meta.frameTags or {}) as {{string: any}}
    for index = 1, #tags do
        local entry = tags[index]
        local from = entry.from as integer
        local to = entry.to as integer
        if from == nil or to == nil then
            error(("tecs: frame tag %d of the Aseprite export has no span"):format(index), 2)
        end
        builder:tag(entry.name as string, from + 1, to + 1, entry.direction as Direction)
    end

    local slices = (meta.slices or {}) as {{string: any}}
    for index = 1, #slices do
        local entry = slices[index]
        local raw = (entry.keys or {}) as {{string: any}}
        local keys: {SliceKey} = {}
        for at = 1, #raw do
            local key = raw[at]
            local bounds = (key.bounds or {}) as {string: number}
            local built: SliceKey = {
                frame = (key.frame as integer or 0) + 1,
                x = bounds.x or 0.0,
                y = bounds.y or 0.0,
                w = bounds.w or 0.0,
                h = bounds.h or 0.0,
            }
            local center = key.center as {string: number}
            if center ~= nil then
                built.centerX = center.x or 0.0
                built.centerY = center.y or 0.0
                built.centerW = center.w or 0.0
                built.centerH = center.h or 0.0
            end
            local pivot = key.pivot as {string: number}
            if pivot ~= nil then
                built.pivotX = pivot.x or 0.0
                built.pivotY = pivot.y or 0.0
            end
            keys[at] = built
        end
        builder:sliceKeys(entry.name as string, entry.data as string, keys)
    end

    return builder:finish()
end

return sheet
