--- Optional physics debug rendering for tecs2d.gfx.
--- Builds a triangle mesh from physics shapes and caches it. Static bodies
--- are only processed once (or when the body count changes); dynamic bodies
--- are updated every frame. Draws the entire mesh in a single draw call.
--- Toggle on/off by emitting PhysicsDebugToggle to world address 0.
---
--- Example:
--- ```lua
--- local gfx = require("tecs2d.gfx")
--- local physics = require("tecs2d.physics")
---
--- -- Initialize physics first
--- world:addPlugin(physics.new({ world = lp.newWorld(0, 300) }))
---
--- -- Then render pipeline
--- local pipeline = gfx.newPipeline({ world = world })
---
--- -- Then physics debug (optional)
--- world:addPlugin(gfx.physicsDebug.new())
---
--- -- Toggle with event
--- world:emit(0, gfx.PhysicsDebugToggle)
--- ```

local C <const> = require("ffi")
local tecs <const> = require("tecs")
local pipelinekey <const> = require("tecs2d.gfx.internal.pipelinekey")
local physics <const> = require("tecs2d.physics")
local retire <const> = require("tecs2d.gfx.internal.gpu.retire")

local lg <const> = love.graphics
local mathCos <const> = math.cos
local mathSin <const> = math.sin
local math_sqrt <const> = math.sqrt

local DEBUG_LAYER <const> = 15
local CIRCLE_SEGMENTS <const> = 16
local TWO_PI <const> = math.pi * 2
local FLOATS_PER_VERT <const> = 8  -- x, y, u, v, r, g, b, a
local BYTES_PER_VERT <const> = 32
local INITIAL_CAPACITY <const> = 65536

-- Vertex format: 2 floats pos + 2 floats uv + 4 floats color = 32 bytes
local VERT_FORMAT <const>: any = {
    { name = "VertexPosition", format = "floatvec2", location = 0 },
    { name = "VertexTexCoord", format = "floatvec2", location = 1 },
    { name = "VertexColor", format = "floatvec4", location = 2 },
}

-- Pre-compute circle unit vectors
local circleUX: {number} = {}
local circleUY: {number} = {}
for s = 0, CIRCLE_SEGMENTS do
    local a = s / CIRCLE_SEGMENTS * TWO_PI
    circleUX[s] = mathCos(a)
    circleUY[s] = mathSin(a)
end

local record physicsDebug
    record Options
        --- Whether debug drawing starts enabled. Defaults to false.
        enabled: boolean
        --- Red channel. Defaults to 1.
        r: number
        --- Green channel. Defaults to 0.
        g: number
        --- Blue channel. Defaults to 0.
        b: number
        --- Alpha channel. Defaults to 0.8.
        a: number
    end

    --- Event to toggle physics debug shapes on/off. Emit to world address 0.
    record PhysicsDebugToggle is tecs.Event
        metamethod __call: function(self): PhysicsDebugToggle
    end

    new: function(options?: Options): tecs.Plugin
end

-- Register toggle event
local PhysicsDebugToggle <const> = physicsDebug.PhysicsDebugToggle
tecs.newFFIEvent(PhysicsDebugToggle, {}, "PhysicsDebugToggle")

function physicsDebug.new(options?: physicsDebug.Options): tecs.Plugin
    local cr = options and options.r or 1.0
    local cg = options and options.g or 0.0
    local cb = options and options.b or 0.0
    local ca = options and options.a or 0.8
    local startsEnabled = options and options.enabled or false

    return function(world: tecs.World)
        local physicsState = world.resources[physics]
        if not physicsState then
            error("physicsDebug requires physics plugin to be initialized first")
        end

        local pipelineInstance = world.resources[pipelinekey.PIPELINE]
        if not pipelineInstance then
            error("physicsDebug requires tecs2d.gfx pipeline to be initialized first")
        end

        local physicsWorld = physicsState.world
        local enabled = startsEnabled

        -- Mesh buffer state, allocated lazily on the first enabled frame
        -- so installing the plugin costs no VRAM or RAM until the debug
        -- overlay is actually toggled on.
        local capacity = 0
        local byteData: love.data.ByteData = nil
        local vertsRaw: C.CData = nil
        local verts: {integer: number} = nil
        local mesh: love.graphics.Mesh = nil
        local vertCount = 0

        local function ensureBuffers()
            if byteData then return end
            capacity = INITIAL_CAPACITY
            byteData = love.data.newByteData(capacity * BYTES_PER_VERT)
            vertsRaw = C.cast("float*", byteData:getFFIPointer()) as C.CData
            verts = vertsRaw as {integer: number}
            mesh = lg.newMesh(VERT_FORMAT as {{number | string}}, capacity, "triangles", "stream")
        end

        -- Cache state: static geometry is built once and reused.
        -- Per-body shape count keyed by body identity catches chunk
        -- destroy/recreate cycles even when total shape count happens
        -- to be unchanged (e.g. tiled.CollisionRebuild swaps a body
        -- with a same-shape-count replacement).
        local staticVertCount = 0       -- verts used by static bodies (start of buffer)
        local cachedStaticShapeCounts: {love.physics.Body: integer} = {}
        local cachedStaticBodyCount = -1 -- -1 = not built
        local cachedLineHW: number = -1  -- lineHW when cache was built; -1 = not built

        local function grow(needed: integer)
            local newCap = capacity
            while vertCount + needed > newCap do
                newCap = newCap * 2
            end
            local newByteData = love.data.newByteData(newCap * BYTES_PER_VERT)
            local newVertsRaw = C.cast("float*", newByteData:getFFIPointer()) as C.CData
            C.copy(newVertsRaw, vertsRaw, vertCount * BYTES_PER_VERT)
            -- The previous frame's draw may still reference the old mesh
            -- and its vertex data; release both through the deferred
            -- retire list instead of mid-frame.
            retire.push(byteData)
            retire.push(mesh)
            byteData = newByteData
            vertsRaw = newVertsRaw
            verts = newVertsRaw as {integer: number}
            capacity = newCap
            mesh = lg.newMesh(VERT_FORMAT as {{number | string}}, newCap, "triangles", "stream")
        end

        local function addVert(x: number, y: number)
            local base = vertCount * FLOATS_PER_VERT
            verts[base] = x
            verts[base + 1] = y
            verts[base + 4] = cr
            verts[base + 5] = cg
            verts[base + 6] = cb
            verts[base + 7] = ca
            vertCount = vertCount + 1
        end

        local function addLineQuad(x1: number, y1: number, x2: number, y2: number, hw: number)
            local dx = x2 - x1
            local dy = y2 - y1
            local len = math_sqrt(dx * dx + dy * dy)
            if len < 0.0001 then return end
            local nx = -dy / len * hw
            local ny = dx / len * hw
            if vertCount + 6 > capacity then grow(6) end
            addVert(x1 + nx, y1 + ny)
            addVert(x1 - nx, y1 - ny)
            addVert(x2 + nx, y2 + ny)
            addVert(x2 + nx, y2 + ny)
            addVert(x1 - nx, y1 - ny)
            addVert(x2 - nx, y2 - ny)
        end

        -- Write all shapes on a single body into the mesh buffer
        local function writeBody(body: love.physics.Body, lineHW: number)
            local bx, by = body:getPosition()
            local angle = body:getAngle()
            local cosA, sinA = mathCos(angle), mathSin(angle)
            local bodyAny = body as {any: any}
            local getShapes = bodyAny.getShapes as function(any): {any}
            local shapes = getShapes(body)
            if not shapes then return end

            for si = 1, #shapes do
                local shape = shapes[si]
                local shapeObj = shape as love.physics.Shape
                local shapeType = shapeObj:getType()

                if shapeType == "circle" then
                    local circleShape = shapeObj as love.physics.CircleShape
                    local radius = circleShape:getRadius()
                    local ox, oy = circleShape:getPoint()
                    local cx = bx + ox * cosA - oy * sinA
                    local cy = by + ox * sinA + oy * cosA
                    for s = 0, CIRCLE_SEGMENTS - 1 do
                        addLineQuad(
                            cx + circleUX[s] * radius, cy + circleUY[s] * radius,
                            cx + circleUX[s + 1] * radius, cy + circleUY[s + 1] * radius,
                            lineHW
                        )
                    end

                elseif shapeType == "polygon" then
                    local polygonShape = shapeObj as love.physics.PolygonShape
                    local points = {polygonShape:getPoints()}
                    local wp: {number} = {}
                    for i = 1, #points, 2 do
                        local px, py = points[i] as number, points[i + 1] as number
                        wp[#wp + 1] = bx + px * cosA - py * sinA
                        wp[#wp + 1] = by + px * sinA + py * cosA
                    end
                    local numPoints = #wp
                    for i = 1, numPoints, 2 do
                        local ni = i + 2
                        if ni > numPoints then ni = 1 end
                        addLineQuad(wp[i], wp[i + 1], wp[ni], wp[ni + 1], lineHW)
                    end

                elseif shapeType == "chain" then
                    local shapeAny = shape as {any: any}
                    local getPoint = shapeAny.getPoint as function(any, integer): (number, number)
                    local getVertexCount = shapeAny.getVertexCount as function(any): integer
                    local count = getVertexCount(shape)
                    local wp: {number} = {}
                    for idx = 1, count do
                        local px, py = getPoint(shape, idx)
                        wp[#wp + 1] = bx + px * cosA - py * sinA
                        wp[#wp + 1] = by + px * sinA + py * cosA
                    end
                    for i = 1, #wp - 2, 2 do
                        addLineQuad(wp[i], wp[i + 1], wp[i + 2], wp[i + 3], lineHW)
                    end
                end
            end
        end

        local function getBodyShapeCount(body: love.physics.Body): integer
            local bodyAny = body as {any: any}
            local getShapes = bodyAny.getShapes as function(any): {any}
            local shapes = getShapes(body)
            return shapes and #shapes or 0
        end

        -- Returns true if any static body was added, removed, or had
        -- its shape count change since the last rebuild.
        local function staticCacheDirty(bodies: {love.physics.Body}): boolean
            if cachedStaticBodyCount < 0 then return true end
            local seen = 0
            for bi = 1, #bodies do
                local body = bodies[bi]
                if body:getType() == "static" then
                    seen = seen + 1
                    local cached = cachedStaticShapeCounts[body]
                    if cached == nil then return true end
                    if cached ~= getBodyShapeCount(body) then return true end
                end
            end
            return seen ~= cachedStaticBodyCount
        end

        -- Build the static portion of the mesh from all static bodies
        local function rebuildStaticCache(bodies: {love.physics.Body}, lineHW: number)
            vertCount = 0
            for k in pairs(cachedStaticShapeCounts) do
                cachedStaticShapeCounts[k] = nil
            end
            local staticCount = 0
            for bi = 1, #bodies do
                local body = bodies[bi]
                if body:getType() == "static" then
                    writeBody(body, lineHW)
                    cachedStaticShapeCounts[body] = getBodyShapeCount(body)
                    staticCount = staticCount + 1
                end
            end
            staticVertCount = vertCount
            cachedStaticBodyCount = staticCount
            cachedLineHW = lineHW
        end

        local function invalidateCache()
            for k in pairs(cachedStaticShapeCounts) do
                cachedStaticShapeCounts[k] = nil
            end
            cachedStaticBodyCount = -1
            cachedLineHW = -1
        end

        world:observe(0, PhysicsDebugToggle, function()
            enabled = not enabled
            if enabled then
                invalidateCache()
            end
        end)

        world:addSystem({
            name = "tecs2d.gfx.physicsdebug",
            phase = tecs.phases.Draw,
            run = function(_dt: number)
                if not enabled then return end
                ensureBuffers()

                local camZoom = pipelineInstance:getCamera():getZoom()
                local lineHW = 0.75 / camZoom

                local bodies = physicsWorld:getBodies()
                local currentBodyCount = #bodies

                -- Rebuild static cache when any static body is added,
                -- removed, or has its shape count change (catches
                -- tiled.CollisionRebuild swapping a chunk collider
                -- with a same-count replacement), or when line
                -- thickness changes by >5% (zoom).
                local needsRebuild = staticCacheDirty(bodies)
                if not needsRebuild and cachedLineHW > 0 then
                    local ratio = lineHW / cachedLineHW
                    if ratio < 0.95 or ratio > 1.05 then
                        needsRebuild = true
                    end
                end
                if needsRebuild then
                    rebuildStaticCache(bodies, lineHW)
                end

                -- Append dynamic bodies after the static portion
                vertCount = staticVertCount
                for bi = 1, currentBodyCount do
                    local body = bodies[bi]
                    if body:getType() ~= "static" then
                        writeBody(body, lineHW)
                    end
                end

                if vertCount > 0 then
                    local meshTbl = mesh as {any: any}
                    local setVertices = meshTbl.setVertices as function(any, any, integer, integer)
                    local setDrawRange = meshTbl.setDrawRange as function(any, integer, integer)
                    -- Upload only the live vertex range, not the full
                    -- buffer capacity.
                    setVertices(mesh, byteData, 1, vertCount)
                    setDrawRange(mesh, 1, vertCount)
                    pipelineInstance:worldShader():at(DEBUG_LAYER, 0, 0):unlit():attach()
                    lg.setColor(1, 1, 1, 1)
                    lg.draw(mesh as love.graphics.Drawable)
                    pipelineInstance:detachWorldShader()
                end
            end
        })
    end
end

return physicsDebug
