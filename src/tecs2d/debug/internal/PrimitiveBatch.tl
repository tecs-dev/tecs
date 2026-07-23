--- One screen-space triangle mesh for ephemeral debugger geometry.
---
--- Selection markers, drag boxes, bounds, grids, and similar
--- one-frame diagnostics have no retained identity. They are rebuilt into
--- this stream buffer and submitted in one draw instead of consuming ECS
--- entities.

local C <const> = require("ffi")
local lg <const> = love.graphics
local cos <const> = math.cos
local sin <const> = math.sin
local sqrt <const> = math.sqrt
local pi <const> = math.pi

local FLOATS_PER_VERT <const> = 8
local BYTES_PER_VERT <const> = 32
local CIRCLE_SEGMENTS <const> = 32
local SEGMENTS_PER_MARKER <const> = 8
local VERTS_PER_SEGMENT <const> = 6
local VERTS_PER_MARKER <const> = SEGMENTS_PER_MARKER * VERTS_PER_SEGMENT

local VERT_FORMAT <const>: any = {
    {name = "VertexPosition", format = "floatvec2", location = 0},
    {name = "VertexTexCoord", format = "floatvec2", location = 1},
    {name = "VertexColor", format = "floatvec4", location = 2},
}

local record PrimitiveBatch
    maxVertices: integer
    markerLimit: integer
    -- Selection-marker count remains public for debugger diagnostics.
    count: integer
    vertCount: integer
    byteData: love.data.ByteData
    vertsRaw: C.CData
    verts: {integer: number}
    mesh: love.graphics.Mesh

    new: function(maxVertices?: integer, markerLimit?: integer): PrimitiveBatch
    clear: function(self)
    line: function(self, x1: number, y1: number, x2: number, y2: number,
        width: number, r: number, g: number, b: number, a: number): boolean
    rectangle: function(self, mode: string, x: number, y: number,
        width: number, height: number, lineWidth: number,
        r: number, g: number, b: number, a: number): boolean
    circle: function(self, mode: string, x: number, y: number,
        radius: number, lineWidth: number,
        r: number, g: number, b: number, a: number): boolean
    selection: function(self, x: number, y: number, radius: number): boolean
    draw: function(self)
end

local MT <const>: metatable<PrimitiveBatch> = {__index = PrimitiveBatch}

function PrimitiveBatch.new(maxVertices?: integer,
        markerLimit?: integer): PrimitiveBatch
    return setmetatable({
        maxVertices = math.max(256, maxVertices or 131072),
        markerLimit = math.max(1, markerLimit or 2048),
        count = 0,
        vertCount = 0,
    } as PrimitiveBatch, MT)
end

local function ensureBuffer(self: PrimitiveBatch)
    if self.byteData then return end
    self.byteData = love.data.newByteData(self.maxVertices * BYTES_PER_VERT)
    self.vertsRaw = C.cast("float*", self.byteData:getFFIPointer()) as C.CData
    self.verts = self.vertsRaw as {integer: number}
    self.mesh = lg.newMesh(VERT_FORMAT as {{number | string}},
        self.maxVertices, "triangles", "stream")
end

local function hasRoom(self: PrimitiveBatch, count: integer): boolean
    if self.vertCount + count > self.maxVertices then return false end
    ensureBuffer(self)
    return true
end

local function addVert(self: PrimitiveBatch, x: number, y: number,
        r: number, g: number, b: number, a: number)
    local base = self.vertCount * FLOATS_PER_VERT
    local verts = self.verts
    verts[base] = x
    verts[base + 1] = y
    verts[base + 4] = r
    verts[base + 5] = g
    verts[base + 6] = b
    verts[base + 7] = a
    self.vertCount = self.vertCount + 1
end

local function appendLine(self: PrimitiveBatch, x1: number, y1: number,
        x2: number, y2: number, width: number,
        r: number, g: number, b: number, a: number)
    local dx, dy = x2 - x1, y2 - y1
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.0001 then return end
    local halfWidth = width * 0.5
    local nx, ny = -dy / len * halfWidth, dx / len * halfWidth
    addVert(self, x1 + nx, y1 + ny, r, g, b, a)
    addVert(self, x1 - nx, y1 - ny, r, g, b, a)
    addVert(self, x2 + nx, y2 + ny, r, g, b, a)
    addVert(self, x2 + nx, y2 + ny, r, g, b, a)
    addVert(self, x1 - nx, y1 - ny, r, g, b, a)
    addVert(self, x2 - nx, y2 - ny, r, g, b, a)
end

function PrimitiveBatch:clear()
    self.count = 0
    self.vertCount = 0
end

function PrimitiveBatch:line(x1: number, y1: number, x2: number, y2: number,
        width: number, r: number, g: number, b: number, a: number): boolean
    if not hasRoom(self, VERTS_PER_SEGMENT) then return false end
    appendLine(self, x1, y1, x2, y2, width, r, g, b, a)
    return true
end

function PrimitiveBatch:rectangle(mode: string, x: number, y: number,
        width: number, height: number, lineWidth: number,
        r: number, g: number, b: number, a: number): boolean
    if mode == "fill" then
        if not hasRoom(self, 6) then return false end
        addVert(self, x, y, r, g, b, a)
        addVert(self, x + width, y, r, g, b, a)
        addVert(self, x + width, y + height, r, g, b, a)
        addVert(self, x, y, r, g, b, a)
        addVert(self, x + width, y + height, r, g, b, a)
        addVert(self, x, y + height, r, g, b, a)
        return true
    end
    if not hasRoom(self, VERTS_PER_SEGMENT * 4) then return false end
    appendLine(self, x, y, x + width, y, lineWidth, r, g, b, a)
    appendLine(self, x + width, y, x + width, y + height,
        lineWidth, r, g, b, a)
    appendLine(self, x + width, y + height, x, y + height,
        lineWidth, r, g, b, a)
    appendLine(self, x, y + height, x, y, lineWidth, r, g, b, a)
    return true
end

function PrimitiveBatch:circle(mode: string, x: number, y: number,
        radius: number, lineWidth: number,
        r: number, g: number, b: number, a: number): boolean
    local needed = mode == "fill" and CIRCLE_SEGMENTS * 3
        or CIRCLE_SEGMENTS * VERTS_PER_SEGMENT
    if not hasRoom(self, needed) then return false end
    for i = 0, CIRCLE_SEGMENTS - 1 do
        local a1 = i / CIRCLE_SEGMENTS * pi * 2
        local a2 = (i + 1) / CIRCLE_SEGMENTS * pi * 2
        local x1, y1 = x + cos(a1) * radius, y + sin(a1) * radius
        local x2, y2 = x + cos(a2) * radius, y + sin(a2) * radius
        if mode == "fill" then
            addVert(self, x, y, r, g, b, a)
            addVert(self, x1, y1, r, g, b, a)
            addVert(self, x2, y2, r, g, b, a)
        else
            appendLine(self, x1, y1, x2, y2,
                lineWidth, r, g, b, a)
        end
    end
    return true
end

function PrimitiveBatch:selection(x: number, y: number,
        radius: number): boolean
    if self.count >= self.markerLimit
            or not hasRoom(self, VERTS_PER_MARKER) then return false end
    local reach = radius + 6
    local r, g, b, a = 1.0, 0.85, 0.2, 1.0
    appendLine(self, x - radius, y - radius, x + radius, y - radius,
        2, r, g, b, a)
    appendLine(self, x + radius, y - radius, x + radius, y + radius,
        2, r, g, b, a)
    appendLine(self, x + radius, y + radius, x - radius, y + radius,
        2, r, g, b, a)
    appendLine(self, x - radius, y + radius, x - radius, y - radius,
        2, r, g, b, a)
    appendLine(self, x, y - reach, x, y - radius, 2, r, g, b, a)
    appendLine(self, x, y + radius, x, y + reach, 2, r, g, b, a)
    appendLine(self, x - reach, y, x - radius, y, 2, r, g, b, a)
    appendLine(self, x + radius, y, x + reach, y, 2, r, g, b, a)
    self.count = self.count + 1
    return true
end

function PrimitiveBatch:draw()
    if self.vertCount == 0 then return end
    local meshAny = self.mesh as {any: any}
    local setVertices = meshAny.setVertices as function(any, any, integer, integer)
    local setDrawRange = meshAny.setDrawRange as function(any, integer, integer)
    setVertices(self.mesh, self.byteData, 1, self.vertCount)
    setDrawRange(self.mesh, 1, self.vertCount)
    lg.push("all")
    lg.origin()
    lg.setCanvas()
    lg.setShader()
    lg.setBlendMode("alpha")
    lg.setColor(1, 1, 1, 1)
    lg.draw(self.mesh as love.graphics.Drawable)
    lg.pop()
end

return PrimitiveBatch
