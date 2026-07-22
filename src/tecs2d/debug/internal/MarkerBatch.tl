--- Batches debugger selection markers into one screen-space mesh draw.
--- Selection membership can be arbitrarily large; this renderer accepts a
--- bounded number of visible markers so debugger visualization never grows
--- the isolated tool world's entity count with the game-world selection.

local C <const> = require("ffi")
local lg <const> = love.graphics
local sqrt <const> = math.sqrt

local FLOATS_PER_VERT <const> = 8
local BYTES_PER_VERT <const> = 32
local SEGMENTS_PER_MARKER <const> = 8
local VERTS_PER_SEGMENT <const> = 6
local VERTS_PER_MARKER <const> = SEGMENTS_PER_MARKER * VERTS_PER_SEGMENT

local VERT_FORMAT <const>: any = {
    {name = "VertexPosition", format = "floatvec2", location = 0},
    {name = "VertexTexCoord", format = "floatvec2", location = 1},
    {name = "VertexColor", format = "floatvec4", location = 2},
}

local record MarkerBatch
    limit: integer
    count: integer
    vertCount: integer
    byteData: love.data.ByteData
    vertsRaw: C.CData
    verts: {integer: number}
    mesh: love.graphics.Mesh

    new: function(limit?: integer): MarkerBatch
    clear: function(self)
    add: function(self, x: number, y: number, radius: number): boolean
    draw: function(self)
end

local MT <const>: metatable<MarkerBatch> = {__index = MarkerBatch}

function MarkerBatch.new(limit?: integer): MarkerBatch
    return setmetatable({
        limit = math.max(1, limit or 2048),
        count = 0,
        vertCount = 0,
    } as MarkerBatch, MT)
end

local function ensureBuffer(self: MarkerBatch)
    if self.byteData then return end
    local capacity = self.limit * VERTS_PER_MARKER
    self.byteData = love.data.newByteData(capacity * BYTES_PER_VERT)
    self.vertsRaw = C.cast("float*", self.byteData:getFFIPointer()) as C.CData
    self.verts = self.vertsRaw as {integer: number}
    self.mesh = lg.newMesh(VERT_FORMAT as {{number | string}}, capacity,
        "triangles", "stream")
end

local function addVert(self: MarkerBatch, x: number, y: number)
    local base = self.vertCount * FLOATS_PER_VERT
    local verts = self.verts
    verts[base] = x
    verts[base + 1] = y
    verts[base + 4] = 1.0
    verts[base + 5] = 0.85
    verts[base + 6] = 0.2
    verts[base + 7] = 1.0
    self.vertCount = self.vertCount + 1
end

local function addLine(self: MarkerBatch, x1: number, y1: number,
        x2: number, y2: number, halfWidth: number)
    local dx, dy = x2 - x1, y2 - y1
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.0001 then return end
    local nx, ny = -dy / len * halfWidth, dx / len * halfWidth
    addVert(self, x1 + nx, y1 + ny)
    addVert(self, x1 - nx, y1 - ny)
    addVert(self, x2 + nx, y2 + ny)
    addVert(self, x2 + nx, y2 + ny)
    addVert(self, x1 - nx, y1 - ny)
    addVert(self, x2 - nx, y2 - ny)
end

function MarkerBatch:clear()
    self.count = 0
    self.vertCount = 0
end

function MarkerBatch:add(x: number, y: number, radius: number): boolean
    if self.count >= self.limit then return false end
    ensureBuffer(self)
    local r = radius
    local reach = radius + 6
    local hw = 1
    addLine(self, x - r, y - r, x + r, y - r, hw)
    addLine(self, x + r, y - r, x + r, y + r, hw)
    addLine(self, x + r, y + r, x - r, y + r, hw)
    addLine(self, x - r, y + r, x - r, y - r, hw)
    addLine(self, x, y - reach, x, y - r, hw)
    addLine(self, x, y + r, x, y + reach, hw)
    addLine(self, x - reach, y, x - r, y, hw)
    addLine(self, x + r, y, x + reach, y, hw)
    self.count = self.count + 1
    return true
end

function MarkerBatch:draw()
    if self.vertCount == 0 then return end
    local meshAny = self.mesh as {any: any}
    local setVertices = meshAny.setVertices as function(any, any, integer, integer)
    local setDrawRange = meshAny.setDrawRange as function(any, integer, integer)
    setVertices(self.mesh, self.byteData, 1, self.vertCount)
    setDrawRange(self.mesh, 1, self.vertCount)
    -- This draw lands on the game framebuffer immediately before the isolated
    -- tool-world canvas is composited. It therefore needs no ECS entity, and
    -- popup chrome still appears above the selection markers.
    lg.push("all")
    lg.origin()
    lg.setShader()
    lg.setBlendMode("alpha")
    lg.setColor(1, 1, 1, 1)
    lg.draw(self.mesh as love.graphics.Drawable)
    lg.pop()
end

return MarkerBatch
