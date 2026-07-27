--- An image divided into frames, with named ranges over them.
---
--- A sheet is data, not a component. A hundred entities drawing the same
--- character share one sheet and point at it, so what an entity carries is the
--- sheet's id rather than a copy of its frame table.
---
--- Frames are addressed by index, counting from one, in the order the sheet
--- lays them out: for a grid that is left to right and then top to bottom. A
--- named range is an inclusive span of those indices, and that is what an
--- animation plays.
---
--- Two coordinate spaces meet here and only one of them is a sheet's business.
--- A frame is written in pixels, because that is how an artist cuts an image
--- up. What a `Sprite` carries is a region of a texture-array layer, which is
--- the fraction of the image the frame covers scaled by the fraction of the
--- layer the image itself covers. The second fraction is the renderer's
--- answer, so a sheet holds pixels until `bind` hands it one.

local components <const> = require("tecs.components")

local type Sprite = components.Sprite

local floor <const> = math.floor
local sort <const> = table.sort

--- Frames per second an animation runs at when nothing says otherwise.
local DEFAULT_FPS <const> = 12.0

--- An inclusive span of frame indices.
local record Range
    from: integer
    to: integer
end

--- One frame's pixel rect.
local record Rect
    x: number
    y: number
    w: number
    h: number
end

--- An image divided into frames.
local record Sheet
    --- Name the sheet is registered under, and what a snapshot writes.
    name: string
    --- Registration index, which is what an Animation carries.
    id: integer
    --- Number of frames.
    count: integer
    --- Size of the image the frames are cut from, in pixels.
    imageWidth: number
    imageHeight: number

    --- Frame rects in pixels, four numbers per frame: x, y, w, h.
    _rects: {number}
    --- Frame regions, four numbers per frame: u0, v0, u1, v1. Fractions of
    --- the image until `bind`, of the texture-array layer after it.
    _uvs: {number}
    --- Range spans and names, indexed by range id.
    _from: {integer}
    _to: {integer}
    _names: {string}
    _ids: {string: integer}
    --- What `bind` resolved: the image index and texture-array layer a frame's
    --- Sprite carries, and the fractions of that layer the image occupies.
    _image: number
    _slot: number
    _scaleU: number
    _scaleV: number
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
    --- Named spans over the frames. Optional.
    ranges: {string: Range}
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
    --- Named spans over the frames. Optional.
    ranges: {string: Range}
end

local record sheet
    type Range = Range
    type Rect = Rect
    type GridOptions = GridOptions
    type RectsOptions = RectsOptions

    --- An image divided into frames.
    Sheet: Sheet

    --- Frames per second an animation runs at when nothing says otherwise.
    DEFAULT_FPS: number

    --- A sheet whose frames are the cells of a uniform grid.
    grid: function(options: GridOptions): Sheet

    --- A sheet whose frames are listed one rect at a time.
    rects: function(options: RectsOptions): Sheet

    --- The sheet a registration index stands for, or nil.
    byId: function(id: integer): Sheet

    --- The sheet registered under a name, or nil.
    byName: function(name: string): Sheet
end

sheet.Sheet = Sheet
sheet.DEFAULT_FPS = DEFAULT_FPS

-------------------------------------------------------------------------------
-- Frames
-------------------------------------------------------------------------------

--- A frame's pixel rect, as x, y, w and h.
function Sheet:rect(frame: integer): number, number, number, number
    if frame == nil or frame < 1 or frame > self.count then
        error(("tecs: sheet '%s' has no frame %s")
            :format(self.name, tostring(frame)), 2)
    end
    local base = (frame - 1) * 4
    local rects = self._rects
    return rects[base + 1], rects[base + 2], rects[base + 3], rects[base + 4]
end

--- A frame's region, as u0, v0, u1 and v1.
---
--- Fractions of the image before `bind` and of the texture-array layer after
--- it, which is the pair of numbers a `Sprite` wants.
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
-- Ranges
-------------------------------------------------------------------------------

--- True when the sheet names the given range.
function Sheet:hasRange(name: string): boolean
    return name ~= nil and self._ids[name] ~= nil
end

--- The first and last frame of a named range.
---
--- Fails on a name the sheet does not carry, because the alternative is an
--- animation silently playing the whole sheet on a typo.
function Sheet:range(name: string): integer, integer
    local id = self._ids[name]
    if id == nil then
        error(("tecs: sheet '%s' has no range '%s'")
            :format(self.name, tostring(name)), 2)
    end
    return self._from[id], self._to[id]
end

--- Index a range name stands for, or zero when the sheet does not name it.
---
--- Zero reads as the whole sheet rather than as nothing, so an animation that
--- names no range plays every frame in order.
function Sheet:rangeId(name: string): integer
    if name == nil then return 0 end
    return self._ids[name] or 0
end

--- Name a range index stands for, or the empty string for the whole sheet.
function Sheet:rangeName(id: integer): string
    if id == nil or id < 1 then return "" end
    return self._names[id] or ""
end

-------------------------------------------------------------------------------
-- Binding to a registered image
-------------------------------------------------------------------------------

--- Recomputes every frame's region from its pixel rect and the current scale.
local function rescale(self: Sheet)
    local rects, uvs = self._rects, self._uvs
    local width, height = self.imageWidth, self.imageHeight
    local scaleU, scaleV = self._scaleU, self._scaleV
    for i = 1, self.count do
        local base = (i - 1) * 4
        local x, y = rects[base + 1], rects[base + 2]
        uvs[base + 1] = x / width * scaleU
        uvs[base + 2] = y / height * scaleV
        uvs[base + 3] = (x + rects[base + 3]) / width * scaleU
        uvs[base + 4] = (y + rects[base + 4]) / height * scaleV
    end
end

--- Resolves the sheet's frames against a registered image.
---
--- `sprite` is what `Renderer:sprite(name)` returns for a whole image: its
--- `u1` and `v1` are the fractions of the texture-array layer that image
--- occupies, and a frame's fraction of the image has to be scaled by them
--- before it names a region of the layer. Pass a sub-rect and the frames land
--- inside that sub-rect, which is not what the sheet describes.
---
--- Binding again rescales from the pixel rects rather than from the last
--- result, so a sheet survives its image being registered a second time.
function Sheet:bind(sprite: Sprite): Sheet
    self._image = sprite.image
    self._slot = sprite.slot
    self._scaleU = sprite.u1
    self._scaleV = sprite.v1
    rescale(self)
    return self
end

--- A Sprite showing one frame, ready to spawn.
---
--- Defaults to the first frame. Meaningful after `bind`, since before it the
--- sheet names no image and the quad has no layer to sample.
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

function sheet.byId(id: integer): Sheet
    if id == nil or id < 1 then return nil end
    return sheetsById[id]
end

--- Building a second sheet under a name already taken replaces what this
--- returns, so a reload points new entities at the new sheet. Entities already
--- carrying the old id keep drawing the old one, which is what stops a reload
--- from pulling a frame out from under them.
function sheet.byName(name: string): Sheet
    if name == nil then return nil end
    return sheetsByName[name]
end

--- Assigns ranges to a sheet under construction.
---
--- Ids follow the names in sorted order rather than the order `pairs` happens
--- to hand them over, so the same table produces the same ids on every run.
local function addRanges(self: Sheet, ranges: {string: Range})
    self._from, self._to, self._names, self._ids = {}, {}, {}, {}
    if ranges == nil then return end

    local names: {string} = {}
    for name in pairs(ranges) do names[#names + 1] = name end
    sort(names)

    for i = 1, #names do
        local name = names[i]
        local span = ranges[name]
        local from, to = span.from, span.to
        if from == nil or to == nil then
            error(("tecs: range '%s' of sheet '%s' needs a from and a to")
                :format(name, self.name), 3)
        end
        if from < 1 or to > self.count or from > to then
            error(("tecs: range '%s' of sheet '%s' spans %d to %d, outside "
                .. "its %d frames")
                :format(name, self.name, from, to, self.count), 3)
        end
        self._from[i] = from
        self._to[i] = to
        self._names[i] = name
        self._ids[name] = i
    end
end

--- Fields every sheet needs whatever cut its frames.
local function newSheet(name: string, imageWidth: number,
                        imageHeight: number): Sheet
    if name == nil or name == "" then
        error("tecs: a sheet needs a name", 3)
    end
    if imageWidth == nil or imageHeight == nil
        or imageWidth <= 0 or imageHeight <= 0 then
        error(("tecs: sheet '%s' needs the pixel size of its image")
            :format(name), 3)
    end
    local self = setmetatable({} as Sheet, SheetMT)
    self.name = name
    self.imageWidth = imageWidth
    self.imageHeight = imageHeight
    self.count = 0
    self._rects = {}
    self._uvs = {}
    -- Unbound, a frame's region is its plain fraction of the image, which is
    -- what a sheet can say without a renderer.
    self._image = 0
    self._slot = -1
    self._scaleU = 1.0
    self._scaleV = 1.0
    return self
end

--- Registers a finished sheet and hands back its id.
local function register(self: Sheet, ranges: {string: Range}): Sheet
    addRanges(self, ranges)
    rescale(self)
    sheetsById[#sheetsById + 1] = self
    self.id = #sheetsById
    sheetsByName[self.name] = self
    return self
end

-------------------------------------------------------------------------------
-- Constructors
-------------------------------------------------------------------------------

--- A sheet whose frames are the cells of a uniform grid.
---
--- Margin surrounds the grid and spacing separates the cells, so a cell's left
--- edge is `margin + column * (frameWidth + spacing)`. Both default to zero,
--- which is an image cut with nothing between its cells.
function sheet.grid(options: GridOptions): Sheet
    local self = newSheet(options.name, options.imageWidth, options.imageHeight)

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

    local rects = self._rects
    for i = 1, count do
        local column = (i - 1) % columns
        local row = floor((i - 1) / columns)
        local base = (i - 1) * 4
        rects[base + 1] = margin + column * (frameWidth + spacing)
        rects[base + 2] = margin + row * (frameHeight + spacing)
        rects[base + 3] = frameWidth
        rects[base + 4] = frameHeight
    end
    self.count = count

    return register(self, options.ranges)
end

--- A sheet whose frames are listed one rect at a time.
---
--- For an image no grid describes: frames of differing sizes, or an atlas
--- whose cells a packing tool placed.
function sheet.rects(options: RectsOptions): Sheet
    local self = newSheet(options.name, options.imageWidth, options.imageHeight)

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
    end
    self.count = #frames

    return register(self, options.ranges)
end

return sheet
