--- An image divided into frames, with tags and slices over them.
---
--- The model is Aseprite's, because that is what the art is authored in: a
--- sheet is a list of frames each holding for its own duration, a set of named
--- tags that play an inclusive span of them in a direction, and a set of named
--- slices carrying rectangles, nine-slice centres and pivots that move from
--- frame to frame. Reading an Aseprite JSON sidecar is one function in front of
--- that model rather than the model itself, so another reader for the binary
--- format populates the same sheet without reshaping anything.
---
--- A sheet is data, not a component. A hundred entities drawing the same
--- character share one sheet and point at it, so what an entity carries is the
--- sheet's id rather than a copy of its frame table.
---
--- One component does live here. A `Pivot` is resolved from a slice, and a
--- slice index is this sheet's answer alone, so writing the name a snapshot
--- carries instead needs the registry at the bottom of this file. Putting the
--- component in `tecs.components` would point that module at this one, which
--- already points the other way.
---
--- Frames are addressed by index, counting from one, in the order the sheet
--- lays them out: for a grid that is left to right and then top to bottom. A
--- tag is an inclusive span of those indices, and that is what an animation
--- plays. Tag zero is the whole sheet, forward.
---
--- Two coordinate spaces meet here and only one of them is a sheet's business.
--- A frame is written in pixels, because that is how an artist cuts an image
--- up. What a `Sprite` carries is a region of a texture-array layer, which is
--- the fraction of the image the frame covers scaled by the fraction of the
--- layer the image itself covers. The second fraction is the renderer's
--- answer, so a sheet holds pixels until `bind` hands it one.

local ecs <const> = require("tecs.ecs")
local components <const> = require("tecs.components")

local type Component = ecs.Component
local type World = ecs.World
local type Sprite = components.Sprite

local floor <const> = math.floor
local sort <const> = table.sort

--- Milliseconds a frame is held when nothing says otherwise, which is what
--- Aseprite writes for a frame nobody retimed.
local DEFAULT_DURATION <const> = 100.0

--- Bumped whenever a frame's region moves, which is registration and `bind`.
---
--- Anything holding a copy of those regions compares this against what it
--- copied from, which keeps the dependency running one way: a sheet knows
--- nothing about who read it.
local revision = 0

--- How a tag walks its span.
---
--- `pingpong` plays forward and then back without repeating either end, so a
--- three-frame tag is 1, 2, 3, 2 and then round again.
local enum Direction
    "forward"
    "reverse"
    "pingpong"
end

--- One frame's pixel rect and how long it is held.
local record Rect
    x: number
    y: number
    w: number
    h: number
    --- Milliseconds. Defaults to `sheet.DEFAULT_DURATION`.
    duration: number
end

--- An inclusive span of frame indices, played in a direction.
---
--- Aseprite calls this a frame tag, and a tag's name is what an animation asks
--- for.
local record Tag
    from: integer
    to: integer
    --- Defaults to "forward".
    direction: Direction
end

--- Where a slice sits from one frame on, and the points it carries.
---
--- A slice holds a key until the next one, so a slice that never moves is one
--- key at frame one.
local record SliceKey
    --- Frame this key takes effect from, counting from one.
    frame: integer
    --- The slice's rectangle, in the pixels of the frame it sits on.
    x: number
    y: number
    w: number
    h: number
    --- Nine-slice centre, in the slice's own pixels. Nil for a slice with no
    --- centre, which is every slice that is not a nine-patch.
    centerX: number
    centerY: number
    centerW: number
    centerH: number
    --- Pivot, in the slice's own pixels. Nil for a slice with no pivot.
    pivotX: number
    pivotY: number
end

--- A named region that moves across the frames.
---
--- Aseprite's slices carry hitboxes, attachment points and nine-patch borders.
--- The engine reads pivots out of them; everything else is the game's to use.
local record Slice
    name: string
    --- Free text Aseprite carries alongside a slice.
    data: string
    --- Keys in frame order, at least one.
    keys: {SliceKey}
end

--- Where an entity's quad turns and scales about.
---
--- A quad with no Pivot turns about its centre, so a character rotates about
--- its waist and a scale grows it in both directions at once. A quad with one
--- turns about the point the pivot names, and the entity's Transform position
--- is where that point lands: a character pivoted at its feet stands at its
--- position instead of hovering half a body above it.
---
--- The point is a fraction of the frame rather than a distance in pixels,
--- because that is what an artist places in Aseprite and what `pivotOf`
--- answers. A frame that changes size therefore carries its pivot with it.
---
--- `sheet` and `slice` are what the fraction was resolved from. A slice moves
--- from frame to frame, so playback resolves it again on every frame change,
--- and it only does so while the slice belongs to the sheet the entity is
--- playing: a frame index means nothing in another sheet's frames. Both zero
--- is a pivot written directly, which nothing rewrites.
local record Pivot is Component
    --- Fraction across the frame, from its left edge. Half is the middle.
    x: number
    --- Fraction down the frame, from its top edge. Half is the middle.
    y: number
    --- Registration index of the sheet the slice belongs to, or zero.
    sheet: number
    --- Index of the slice within that sheet, from `Sheet:sliceId`, or zero
    --- for a pivot written directly.
    slice: number
    --- How far the point above can move over the cycle being played, as half
    --- the range in each axis and a fraction of the frame.
    ---
    --- Zero for a pivot written directly and for a slice with a single key,
    --- which is nearly every one of them, and the cull bound is then exactly
    --- the quad's own. Playback on the GPU resolves the frame after the bound is
    --- written, so a slice that genuinely moves has to have its travel covered:
    --- `x` and `y` are then the middle of where it goes and this is how far
    --- either side of that the quad can be drawn.
    halfX: number
    halfY: number
end

--- An image divided into frames.
local record Sheet
    --- Name the sheet is registered under, and what a snapshot writes.
    name: string
    --- Registration index, which is what an Animation carries. Assigned when
    --- the sheet is built and never reused, so a second sheet built under a
    --- taken name gets a fresh id rather than the old one.
    id: integer
    --- Number of frames, and so the largest index `rect`, `uv` and `sprite`
    --- accept.
    count: integer
    --- Size of the image the frames are cut from, in pixels. What frame rects
    --- are measured against, so a sheet cut for one image and bound to another
    --- of a different size places its frames wrongly with no complaint.
    imageWidth: number
    imageHeight: number

    --- Frame rects in pixels, four numbers per frame: x, y, w, h.
    _rects: {number}
    --- Seconds each frame is held, converted from the milliseconds the model
    --- is authored in so playback never divides.
    _durations: {number}
    --- Frame regions, four numbers per frame: u0, v0, u1, v1. Fractions of
    --- the image until `bind`, of the texture-array layer after it.
    _uvs: {number}
    --- Tag spans, directions and names, indexed by tag id. Index zero is the
    --- whole sheet forward, which is what an animation naming no tag plays.
    _from: {integer}
    _to: {integer}
    _direction: {Direction}
    _names: {string}
    _ids: {string: integer}
    --- Frame index at each step of a tag's cycle, indexed by tag id. This is
    --- what collapses the three directions into one lookup: the direction
    --- decides the order once, when the sheet is built, and playback walks it.
    _order: {{integer}}
    --- Seconds elapsed at the end of each step of a tag's cycle, indexed by
    --- tag id, and the cycle's whole length.
    _timing: {{number}}
    _cycle: {number}
    --- Slices by index and by name.
    _slices: {Slice}
    _sliceIds: {string: integer}

    --- What `bind` resolved: the image index and texture-array layer a frame's
    --- Sprite carries, and the fractions of that layer the image occupies.
    _image: number
    _slot: number
    --- Where the image sits within its texture-array cell, and how much of
    --- the cell it covers. A packed cell holds several images, so a frame's
    --- fraction of the image is scaled and then moved rather than only scaled.
    _originU: number
    _originV: number
    _scaleU: number
    _scaleV: number

    --- A frame's pixel rect, as x, y, w and h.
    --- @param frame One to `count`. Anything else raises, since a frame index
    ---     out of range is a sheet and an animation disagreeing rather than
    ---     something to paper over.
    --- @return The rect's left, top, width and height, in the pixels of the
    ---     image the sheet was cut from.
    rect: function(self, frame: integer): number, number, number, number

    --- How long a frame is held, in seconds.
    --- @param frame One to `count`. Anything else raises.
    --- @return Seconds, which is the milliseconds the frame was authored with
    ---     divided by a thousand.
    duration: function(self, frame: integer): number

    --- A frame's region, as u0, v0, u1 and v1.
    ---
    --- Fractions of the image before `bind` and of the texture-array layer
    --- after it, which is the pair of numbers a `Sprite` wants.
    --- @param frame One to `count`. Anything else raises.
    --- @return The region's left, top, right and bottom edges.
    uv: function(self, frame: integer): number, number, number, number

    --- True when the sheet names the given tag.
    --- @param name Any string, and nil answers false rather than raising, so
    ---     this is what to ask before `tag`.
    --- @return Whether `tag` would answer for that name.
    hasTag: function(self, name: string): boolean

    --- The first frame, last frame and direction of a named tag.
    ---
    --- Fails on a name the sheet does not carry, because the alternative is an
    --- animation silently playing the whole sheet on a typo.
    --- @param name A tag this sheet was built with.
    --- @return The tag's first frame index, its last, and its direction.
    tag: function(self, name: string): integer, integer, Direction

    --- Index a tag name stands for, or zero when the sheet does not name it.
    ---
    --- Zero reads as the whole sheet rather than as nothing, so an animation
    --- that names no tag plays every frame in order.
    --- @param name A tag name, or nil for the whole sheet.
    --- @return The index an `Animation` carries, which is this sheet's answer
    ---     alone: ids follow the tag names in sorted order, so the same name
    ---     in another sheet is another number.
    tagId: function(self, name: string): integer

    --- Name a tag index stands for, or the empty string for the whole sheet.
    --- @param id An index from `tagId`. Nil, zero and anything the sheet does
    ---     not carry all answer the empty string.
    --- @return The tag's name, which is what a snapshot writes instead of the
    ---     index.
    tagName: function(self, id: integer): string

    --- Seconds one pass through a tag's cycle takes.
    --- @param id A tag index, or zero for the whole sheet.
    --- @return The sum of the durations of the frames the cycle visits, which
    ---     for a pingpong tag counts the frames it passes twice twice.
    cycle: function(self, id: integer): number

    --- The frame a tag is showing at a point in its cycle.
    --- @param id A tag index, or zero for the whole sheet.
    --- @param time Seconds into the cycle. Outside it clamps rather than
    ---     wrapping, since wrapping is the caller's decision about looping.
    --- @return A frame index into the whole sheet, counting from one.
    frameAt: function(self, id: integer, time: number): integer

    --- A slice by name, or nil when the sheet does not carry one.
    --- @param name A slice name.
    --- @return The slice, whose keys the caller must not mutate.
    slice: function(self, name: string): Slice

    --- Index a slice name stands for, or zero when the sheet does not name it.
    --- @param name A slice name, or nil.
    --- @return The index, which is what a component carries in place of the
    ---     name for the reason a tag id is.
    sliceId: function(self, name: string): integer

    --- Name a slice index stands for, or the empty string.
    sliceName: function(self, id: integer): string

    --- The key of a slice that is in force on a frame, or nil.
    ---
    --- A slice holds a key until the next one, so this answers the last key at
    --- or before the frame rather than only an exact match.
    --- @param id A slice index from `sliceId`. Zero answers nil.
    --- @param frame A frame index.
    sliceKeyAt: function(self, id: integer, frame: integer): SliceKey

    --- Where a slice's pivot sits on a frame, as a fraction of that frame.
    ---
    --- Aseprite writes a pivot in the slice's own pixels, so this adds the
    --- slice's origin and divides by the frame, which is the number a quad
    --- wants: nothing downstream has to know the sheet's pixel sizes.
    ---
    --- A slice with a centre but no pivot answers the centre's middle, and a
    --- slice with neither answers the middle of its own rectangle. Zero, a
    --- slice the sheet does not carry, or a frame it has no key for all answer
    --- the middle of the frame, which is where a quad sits with no pivot at
    --- all.
    --- @param id A slice index from `sliceId`.
    --- @param frame A frame index.
    --- @return The pivot's x and y as fractions of the frame, from its top
    ---     left.
    pivotOf: function(self, id: integer, frame: integer): number, number

    --- A Pivot resolved from a named slice, ready to spawn.
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
    --- `sprite` is what `Renderer:sprite(name)` returns for a whole image: its
    --- `u1` and `v1` are the fractions of the texture-array layer that image
    --- occupies, and a frame's fraction of the image has to be scaled by them
    --- before it names a region of the layer. Pass a sub-rect and the frames
    --- land inside that sub-rect, which is not what the sheet describes.
    ---
    --- Binding again rescales from the pixel rects rather than from the last
    --- result, so a sheet survives its image being registered a second time.
    --- Entities already carrying regions from an earlier bind keep them: a
    --- rebind moves nothing that has already been written into a `Sprite`.
    --- @param sprite A whole image, from `Renderer:sprite`.
    --- @return The sheet, so a bind can be chained onto the construction.
    bind: function(self, sprite: Sprite): Sheet

    --- A Sprite showing one frame, ready to spawn.
    ---
    --- Defaults to the first frame. Meaningful after `bind`, since before it
    --- the sheet names no image and the quad has no layer to sample.
    --- @param frame One to `count`, defaulting to one. Anything else raises.
    --- @return A fresh `Sprite`, which is a value the caller owns rather than a
    ---     view onto the sheet.
    sprite: function(self, frame?: integer): Sprite
end

local SheetMT <const>: metatable<Sheet> = { __index = Sheet }

--- Options for a sheet cut into a uniform grid.
local record GridOptions
    --- Name to register the sheet under (required).
    name: string
    --- Size of the image the grid is cut from, in pixels (required).
    imageWidth: number
    imageHeight: number
    --- Size of one cell, in pixels (required).
    frameWidth: number
    frameHeight: number
    --- Border between the image's edge and the first cell. Defaults to zero.
    margin: number
    --- Gap between neighbouring cells. Defaults to zero.
    spacing: number
    --- Cells across and down. Derived from the image size when omitted.
    columns: integer
    rows: integer
    --- Frames to take, counting across rows. Defaults to every cell, which is
    --- wrong only for a sheet whose last row is short.
    count: integer
    --- Milliseconds every cell is held. Defaults to `DEFAULT_DURATION`. A grid
    --- is one duration for every frame by construction; retime individual
    --- frames with `sheet.build`.
    duration: number
    --- Named tags over the frames. Optional.
    tags: {string: Tag}
    --- Named slices. Optional.
    slices: {Slice}
end

--- Options for a sheet cut into explicitly listed rects.
local record RectsOptions
    --- Name to register the sheet under (required).
    name: string
    --- Size of the image the rects are cut from, in pixels (required).
    imageWidth: number
    imageHeight: number
    --- Frame rects in pixels, in the order they are addressed (required).
    frames: {Rect}
    --- Named tags over the frames. Optional.
    tags: {string: Tag}
    --- Named slices. Optional.
    slices: {Slice}
end

--- Options for a sheet read from an Aseprite JSON export.
local record AsepriteOptions
    --- Name to register the sheet under. Defaults to the export's own image
    --- name, and is required when the export does not carry one.
    name: string
    --- The export, either as the JSON text or as a table already decoded from
    --- it. A table is what an asset pipeline that decoded once should pass.
    json: any
end

--- Builds a sheet a frame, a tag and a slice at a time.
---
--- What every constructor here goes through, and what an importer for a format
--- nothing else reads writes into.
local record Builder
    _sheet: Sheet
    _tags: {string: Tag}
    _slices: {Slice}

    --- Appends a frame.
    --- @param x Left of the frame in the image, in pixels.
    --- @param y Top of the frame.
    --- @param w Width, which must be positive.
    --- @param h Height, which must be positive.
    --- @param duration Milliseconds it is held. Defaults to
    ---     `sheet.DEFAULT_DURATION`.
    --- @return The builder.
    frame: function(self, x: number, y: number, w: number, h: number,
                    duration?: number): Builder

    --- Names an inclusive span of frames and how it walks them.
    --- @param name What an animation asks for.
    --- @param from First frame, counting from one.
    --- @param to Last frame, inclusive.
    --- @param direction Defaults to "forward".
    --- @return The builder.
    tag: function(self, name: string, from: integer, to: integer,
                  direction?: Direction): Builder

    --- Adds a slice that never moves, with a pivot.
    --- @param name What a sprite names to take its pivot from.
    --- @param x Left of the slice within a frame, in pixels.
    --- @param y Top of the slice.
    --- @param w Width.
    --- @param h Height.
    --- @param pivotX Pivot within the slice, in the slice's own pixels.
    ---     Omitted, the slice carries no pivot and its middle stands in.
    --- @param pivotY
    --- @return The builder.
    slice: function(self, name: string, x: number, y: number, w: number,
                    h: number, pivotX?: number, pivotY?: number): Builder

    --- Adds a slice with its keys written out, which is what an importer uses.
    --- @param name The slice's name.
    --- @param data Free text to carry alongside it, or nil for none.
    --- @param keys Keys in frame order, at least one.
    --- @return The builder.
    sliceKeys: function(self, name: string, data: string,
                        keys: {SliceKey}): Builder

    --- Registers the sheet and hands it back.
    ---
    --- Raises on a sheet with no frames, and on a tag whose span falls outside
    --- them.
    finish: function(self): Sheet
end

local BuilderMT <const>: metatable<Builder> = { __index = Builder }

local record sheet
    type Direction = Direction
    type Rect = Rect
    type Tag = Tag
    type Slice = Slice
    type SliceKey = SliceKey
    type GridOptions = GridOptions
    type RectsOptions = RectsOptions
    type AsepriteOptions = AsepriteOptions
    type Builder = Builder

    --- An image divided into frames.
    Sheet: Sheet

    --- Where an entity's quad turns and scales about.
    Pivot: Pivot

    --- Milliseconds a frame is held when nothing says otherwise.
    DEFAULT_DURATION: number

    --- A sheet whose frames are the cells of a uniform grid.
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

    --- A sheet whose frames are listed one rect at a time.
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

    --- A builder, for a sheet no constructor above describes.
    ---
    --- The model is what the builder writes, so an atlas from any tool reaches
    --- the same sheet an Aseprite export does. Frames, tags and slices are
    --- added in any order and the sheet is registered by `build`.
    --- @param name Name to register the finished sheet under.
    --- @param imageWidth Size of the image the frames are cut from, in pixels.
    --- @param imageHeight
    --- @return A builder whose methods chain.
    build: function(name: string, imageWidth: number, imageHeight: number): Builder

    --- A sheet read from an Aseprite JSON export.
    ---
    --- One reader in front of the model rather than a second model: frames,
    --- their durations, frame tags with their directions, and slices with their
    --- keys all land in the sheet the builder writes.
    ---
    --- Both of Aseprite's frame layouts are read, the array and the object
    --- keyed by frame name, the second in sorted name order. Trimmed exports
    --- are not read: `spriteSourceSize` is ignored, so export with trimming
    --- off or the frames land in the wrong place.
    --- @param options The export and the name to register it under.
    --- @return The finished sheet.
    fromAseprite: function(options: AsepriteOptions): Sheet

    --- The sheet a registration index stands for, or nil.
    --- @param id An `id` from a sheet this process built. Ids are handed out in
    ---     construction order, so one is only meaningful within a run.
    --- @return The sheet, or nil for an id nothing was built under.
    byId: function(id: integer): Sheet

    --- The sheet registered under a name, or nil.
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
    --- an `Animation` holding the id goes on playing and shows the new frames
    --- on its next step, with nothing in the world touched.
    ---
    --- The refusals are the same ones a shader reload makes, for the same
    --- reason: a component holds an index into this sheet, so anything that
    --- renumbers one is refused rather than half applied. Tag ids follow the
    --- tag names in sorted order and slice ids follow the slices, so adding,
    --- removing or renaming either is a restart. Frames are free to change:
    --- what an entity carries is a tag and a time, and the frame is resolved
    --- from the cycle on every step.
    ---
    --- The bind is carried over. A sheet re-exported over the same image is
    --- already bound to the right layer, so its frames are rescaled against
    --- the region the old sheet held rather than needing `bind` called again.
    ---
    --- The sheet handed in is spent. Its id resolves to the live sheet rather
    --- than to itself, because the two share their frame tables once the fold
    --- is done and only one of them may be bound.
    --- @param built A sheet from any constructor here, registered moments ago
    ---     under a name something else already holds.
    --- @return The live sheet, and nil, or nil and the reason it was refused.
    replace: function(built: Sheet): Sheet, string

    --- How many times any sheet's frames have changed.
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
        error(("tecs: sheet '%s' has no frame %s")
            :format(self.name, tostring(frame)), 2)
    end
    local base = (frame - 1) * 4
    local rects = self._rects
    return rects[base + 1], rects[base + 2], rects[base + 3], rects[base + 4]
end

function Sheet:duration(frame: integer): number
    if frame == nil or frame < 1 or frame > self.count then
        error(("tecs: sheet '%s' has no frame %s")
            :format(self.name, tostring(frame)), 2)
    end
    return self._durations[frame]
end

function Sheet:uv(frame: integer): number, number, number, number
    if frame == nil or frame < 1 or frame > self.count then
        error(("tecs: sheet '%s' has no frame %s")
            :format(self.name, tostring(frame)), 2)
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
        error(("tecs: sheet '%s' has no tag '%s'")
            :format(self.name, tostring(name)), 2)
    end
    return self._from[id], self._to[id], self._direction[id]
end

function Sheet:tagId(name: string): integer
    if name == nil then return 0 end
    return self._ids[name] or 0
end

function Sheet:tagName(id: integer): string
    if id == nil or id < 1 then return "" end
    return self._names[id] or ""
end

function Sheet:cycle(id: integer): number
    return self._cycle[id or 0] or 0.0
end

function Sheet:frameAt(id: integer, time: number): integer
    local order = self._order[id or 0]
    if order == nil then return 1 end

    -- A linear scan, because a tag is a handful of steps and the comparison is
    -- against a number already in cache. A binary search costs more branches
    -- than it saves at these lengths.
    local timing = self._timing[id or 0]
    local steps <const> = #order
    for step = 1, steps do
        if time <= timing[step] then return order[step] end
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
        { "x", "float" }, { "y", "float" },
        { "sheet", "int32_t" }, { "slice", "int32_t" },
        { "halfX", "float" }, { "halfY", "float" },
    },
    -- The middle of the frame, which is where a quad with no Pivot at all
    -- sits: adding the component without saying where moves nothing.
    defaults = { 0.5, 0.5, 0, 0, 0.0, 0.0 },
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
            x = instance.x, y = instance.y, sheet = name, slice = slice,
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
    if name == nil then return nil end
    local id = self._sliceIds[name]
    if id == nil then return nil end
    return self._slices[id]
end

function Sheet:sliceId(name: string): integer
    if name == nil then return 0 end
    return self._sliceIds[name] or 0
end

function Sheet:sliceName(id: integer): string
    if id == nil or id < 1 then return "" end
    local entry = self._slices[id]
    if entry == nil then return "" end
    return entry.name
end

function Sheet:sliceKeyAt(id: integer, frame: integer): SliceKey
    if id == nil or id < 1 then return nil end
    local entry = self._slices[id]
    if entry == nil then return nil end

    local keys = entry.keys
    local found: SliceKey = nil
    for index = 1, #keys do
        local key = keys[index]
        if key.frame > frame then break end
        found = key
    end
    return found
end

function Sheet:pivotOf(id: integer, frame: integer): number, number
    local key = self:sliceKeyAt(id, frame)
    if key == nil then return 0.5, 0.5 end

    local _, _, width, height = self:rect(frame)
    if width <= 0 or height <= 0 then return 0.5, 0.5 end

    local x, y = key.pivotX, key.pivotY
    if x == nil then
        -- A nine-patch names a centre rather than a pivot, and the middle of
        -- that centre is the point the patch is anchored on. Failing both, the
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
        error(("tecs: sheet '%s' has no slice '%s'")
            :format(self.name, tostring(name)), 2)
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
--- documented behaviour and the wrong one for a file that was exported twice.
--- `replace` is the reverse of it and has to know what was displaced, and only
--- registration is in a position to say.
local displaced: {string: Sheet} = {}

function sheet.revision(): integer
    return revision
end

function sheet.byId(id: integer): Sheet
    if id == nil or id < 1 then return nil end
    return sheetsById[id]
end

function sheet.byName(name: string): Sheet
    if name == nil then return nil end
    return sheetsByName[name]
end

--- Writes the order and timing of one tag.
---
--- The direction is spent here rather than at every step of playback: what
--- comes out is the frames in the order they are shown and the second each one
--- ends on, so a lookup is a scan of numbers and never a branch on direction.
local function planTag(self: Sheet, id: integer, from: integer, to: integer,
                       direction: Direction)
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
        for frame = to, from, -1 do step(frame) end
    else
        for frame = from, to do step(frame) end
        if direction == "pingpong" and to > from then
            -- Neither end is repeated, so a three-frame tag is 1, 2, 3, 2 and
            -- the cycle is five frames long rather than six.
            for frame = to - 1, from + 1, -1 do step(frame) end
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
    if tags == nil then return end

    local names: {string} = {}
    for name in pairs(tags) do names[#names + 1] = name end
    sort(names)

    for i = 1, #names do
        local name = names[i]
        local span = tags[name]
        local from, to = span.from, span.to
        if from == nil or to == nil then
            error(("tecs: tag '%s' of sheet '%s' needs a from and a to")
                :format(name, self.name), level)
        end
        if from < 1 or to > self.count or from > to then
            error(("tecs: tag '%s' of sheet '%s' spans %d to %d, outside "
                .. "its %d frames")
                :format(name, self.name, from, to, self.count), level)
        end
        local direction <const> = span.direction or "forward"
        if direction ~= "forward" and direction ~= "reverse"
            and direction ~= "pingpong" then
            error(("tecs: tag '%s' of sheet '%s' has no direction '%s'")
                :format(name, self.name, tostring(direction)), level)
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
    if slices == nil then return end

    for index = 1, #slices do
        local entry = slices[index]
        if entry.name == nil or entry.name == "" then
            error(("tecs: slice %d of sheet '%s' has no name")
                :format(index, self.name), level)
        end
        local keys = entry.keys
        if keys == nil or #keys < 1 then
            error(("tecs: slice '%s' of sheet '%s' has no keys")
                :format(entry.name, self.name), level)
        end
        self._slices[index] = entry
        self._sliceIds[entry.name] = index
    end
end

--- Fields every sheet needs whatever cut its frames.
local function newSheet(name: string, imageWidth: number,
                        imageHeight: number, level: integer): Sheet
    if name == nil or name == "" then
        error("tecs: a sheet needs a name", level)
    end
    if imageWidth == nil or imageHeight == nil
        or imageWidth <= 0 or imageHeight <= 0 then
        error(("tecs: sheet '%s' needs the pixel size of its image")
            :format(name), level)
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
local function register(self: Sheet, tags: {string: Tag}, slices: {Slice},
                        level: integer): Sheet
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
local function sameIndices(before: {string: integer},
                           after: {string: integer}): boolean, string
    for name in pairs(before) do
        if after[name] == nil then return false, name end
    end
    for name in pairs(after) do
        if before[name] == nil then return false, name end
    end
    for name, id in pairs(before) do
        if after[name] ~= id then return false, name end
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
        return nil, ("no sheet is registered as '%s', so there is nothing to "
            .. "replace"):format(built.name)
    end

    -- Checked before anything is written, so a refusal leaves the live sheet
    -- exactly as it was rather than part way through.
    local ok, moved = sameIndices(live._ids, built._ids)
    if not ok then
        sheetsByName[built.name] = live
        return nil, ("sheet '%s' would renumber its tags at '%s', and an "
            .. "Animation already holds a tag index"):format(built.name, moved)
    end
    ok, moved = sameIndices(live._sliceIds, built._sliceIds)
    if not ok then
        sheetsByName[built.name] = live
        return nil, ("sheet '%s' would renumber its slices at '%s', and a "
            .. "Pivot already holds a slice index"):format(built.name, moved)
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

function sheet.build(name: string, imageWidth: number,
                     imageHeight: number): Builder
    local self = setmetatable({} as Builder, BuilderMT)
    self._sheet = newSheet(name, imageWidth, imageHeight, 3)
    self._tags = {}
    self._slices = {}
    return self
end

function Builder:frame(x: number, y: number, w: number, h: number,
                       duration?: number): Builder
    local target <const> = self._sheet
    if w == nil or h == nil or w <= 0 or h <= 0 then
        error(("tecs: frame %d of sheet '%s' has no positive size")
            :format(target.count + 1, target.name), 2)
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

function Builder:tag(name: string, from: integer, to: integer,
                     direction?: Direction): Builder
    if name == nil or name == "" then
        error("tecs: a tag needs a name", 2)
    end
    self._tags[name] = { from = from, to = to, direction = direction }
    return self
end

function Builder:slice(name: string, x: number, y: number, w: number,
                       h: number, pivotX?: number, pivotY?: number): Builder
    return self:sliceKeys(name, nil, { {
        frame = 1, x = x, y = y, w = w, h = h,
        pivotX = pivotX, pivotY = pivotY,
    } })
end

function Builder:sliceKeys(name: string, data: string,
                           keys: {SliceKey}): Builder
    self._slices[#self._slices + 1] = {
        name = name, data = data or "", keys = keys,
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
    local self = newSheet(options.name, options.imageWidth,
        options.imageHeight, 2)

    local frameWidth <const> = options.frameWidth
    local frameHeight <const> = options.frameHeight
    if frameWidth == nil or frameHeight == nil
        or frameWidth <= 0 or frameHeight <= 0 then
        error(("tecs: sheet '%s' needs a positive frame size")
            :format(self.name), 2)
    end

    local margin <const> = options.margin or 0.0
    local spacing <const> = options.spacing or 0.0

    -- The last cell in a row has no spacing after it, so the spacing is added
    -- back once before dividing rather than subtracted from every cell.
    local columns <const> = options.columns
        or floor((self.imageWidth - 2 * margin + spacing)
            / (frameWidth + spacing))
    local rows <const> = options.rows
        or floor((self.imageHeight - 2 * margin + spacing)
            / (frameHeight + spacing))
    if columns < 1 or rows < 1 then
        error(("tecs: sheet '%s' fits no %gx%g cells in %gx%g pixels")
            :format(self.name, frameWidth, frameHeight,
                self.imageWidth, self.imageHeight), 2)
    end

    local count <const> = options.count or columns * rows
    if count < 1 or count > columns * rows then
        error(("tecs: sheet '%s' asks for %d frames from a %dx%d grid")
            :format(self.name, count, columns, rows), 2)
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
    local self = newSheet(options.name, options.imageWidth,
        options.imageHeight, 2)

    local frames <const> = options.frames
    if frames == nil or #frames < 1 then
        error(("tecs: sheet '%s' lists no frames"):format(self.name), 2)
    end

    local rects = self._rects
    for i = 1, #frames do
        local frame = frames[i]
        if frame.w == nil or frame.h == nil or frame.w <= 0 or frame.h <= 0 then
            error(("tecs: frame %d of sheet '%s' has no positive size")
                :format(i, self.name), 2)
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
    if #list > 0 then return list end

    local keyed = raw as {string: {string: any}}
    local names: {string} = {}
    for name in pairs(keyed) do names[#names + 1] = name end
    sort(names)

    local ordered: {{string: any}} = {}
    for index = 1, #names do ordered[index] = keyed[names[index]] end
    return ordered
end

function sheet.fromAseprite(options: AsepriteOptions): Sheet
    local source = options.json
    if source is string then
        source = (require("tecs.json") as
            {string: function(string): any}).decode(source)
    end
    local export = source as {string: any}
    if export == nil then
        error("tecs: an Aseprite sheet needs the export to read", 2)
    end

    local meta = (export.meta or {}) as {string: any}
    local size = (meta.size or {}) as {string: number}
    local name = options.name or (meta.image as string)
    if name == nil or name == "" then
        error("tecs: the Aseprite export names no image, so the sheet "
            .. "needs a name of its own", 2)
    end

    local builder <const> = sheet.build(name, size.w, size.h)

    local frames <const> = asepriteFrames(export)
    for index = 1, #frames do
        local entry = frames[index]
        local rect = (entry.frame or {}) as {string: number}
        if rect.w == nil or rect.h == nil then
            error(("tecs: frame %d of the Aseprite export has no rectangle")
                :format(index), 2)
        end
        builder:frame(rect.x or 0.0, rect.y or 0.0, rect.w, rect.h,
            entry.duration as number)
    end

    -- Aseprite counts frames from zero and this model counts from one, so the
    -- span moves by one at the boundary and nowhere else.
    local tags = (meta.frameTags or {}) as {{string: any}}
    for index = 1, #tags do
        local entry = tags[index]
        local from = entry.from as integer
        local to = entry.to as integer
        if from == nil or to == nil then
            error(("tecs: frame tag %d of the Aseprite export has no span")
                :format(index), 2)
        end
        builder:tag(entry.name as string, from + 1, to + 1,
            entry.direction as Direction)
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
            local centre = key.center as {string: number}
            if centre ~= nil then
                built.centerX = centre.x or 0.0
                built.centerY = centre.y or 0.0
                built.centerW = centre.w or 0.0
                built.centerH = centre.h or 0.0
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
