--- Collision geometry extraction from Tiled tilemaps.
---
--- Converts per-tile collision shapes into optimized Box2D chain shapes
--- for efficient static collision. Uses polygon tracing to merge adjacent
--- tiles into minimal chain shapes.

local types <const> = require("tecs2d.tiled.types")
local tileset_utils <const> = require("tecs2d.tiled.internal.tileset")
local getCleanGid <const> = tileset_utils.getCleanGid

local type TilemapData = types.TilemapData
local type TileData = types.TileData
local type TilesetData = types.TilesetData
local type ObjectData = types.ObjectData

local lp <const> = love.physics

-- Type aliases for Box2D objects (to work with 'any' physics world)
local type PhysicsWorld = love.physics.World
local type PhysicsBody = love.physics.Body

--- Configuration for collision generation.
local record CollisionConfig
    --- Whether collision is enabled (default: false)
    enabled: boolean
    --- Merge adjacent shapes into chain shapes (default: true)
    mergeShapes: boolean
    --- Optional filter function to include/exclude tiles
    filter: function(tile: TileData, gid: integer, tileX: integer, tileY: integer): boolean
end

--- An edge in 2D space with direction.
local record Edge
    x1: number
    y1: number
    x2: number
    y2: number
end

-- Chunk size for per-chunk collision (matches render chunk size)
local CHUNK_SIZE <const> = 16

local record collision
    --- Collision configuration type.
    type Config = CollisionConfig

    --- Chunk size for collision (matches render chunk size)
    CHUNK_SIZE: integer

    --- Create collision bodies from tilemap data.
    --- @param tilemapData The parsed tilemap data
    --- @param physicsWorld The Box2D physics world
    --- @param config Collision configuration
    --- @return Array of created physics bodies
    createColliders: function(
        tilemapData: TilemapData, physicsWorld: PhysicsWorld, config: CollisionConfig
    ): {PhysicsBody}

    --- Create collision body for a single chunk.
    --- @param tilemapData The parsed tilemap data
    --- @param physicsWorld The Box2D physics world
    --- @param config Collision configuration
    --- @param layerIndex Layer index (1-based)
    --- @param chunkX Chunk X coordinate (0-based)
    --- @param chunkY Chunk Y coordinate (0-based)
    --- @return Physics body for this chunk (nil if no collision tiles)
    createChunkCollider: function(
        tilemapData: TilemapData,
        physicsWorld: PhysicsWorld,
        config: CollisionConfig,
        layerIndex: integer,
        chunkX: integer,
        chunkY: integer
    ): PhysicsBody

    --- Destroy a single collision body.
    --- @param body Physics body to destroy
    destroyCollider: function(body: PhysicsBody)

    --- Destroy collision bodies and clean up.
    --- @param bodies Array of physics bodies to destroy
    destroyColliders: function(bodies: {PhysicsBody})

    --- Check if a tile GID has collision shapes.
    --- @param tilemapData The parsed tilemap data
    --- @param gid The tile GID to check
    --- @return true if tile has collision shapes
    tileHasCollision: function(tilemapData: TilemapData, gid: integer): boolean
end

collision.CHUNK_SIZE = CHUNK_SIZE

-- Epsilon for floating point comparisons
local EPSILON <const> = 0.001

-- Check if two numbers are approximately equal
local function approxEqual(a: number, b: number): boolean
    return math.abs(a - b) < EPSILON
end

-- Create a key for edge lookup (normalized so direction doesn't matter for duplicate detection)
local function edgeKey(x1: number, y1: number, x2: number, y2: number): string
    -- Normalize so smaller point comes first
    if x1 < x2 or (approxEqual(x1, x2) and y1 < y2) then
        return string.format("%.2f,%.2f-%.2f,%.2f", x1, y1, x2, y2)
    else
        return string.format("%.2f,%.2f-%.2f,%.2f", x2, y2, x1, y1)
    end
end

-- Create a directional edge key (for tracing, direction matters)
local function directedEdgeKey(x1: number, y1: number, x2: number, y2: number): string
    return string.format("%.2f,%.2f-%.2f,%.2f", x1, y1, x2, y2)
end

-- Tiled rotates objects (clockwise, in degrees) around the object's own (x, y)
-- pivot. Rotate a single point that's expressed relative to that pivot, then
-- translate it into world space.
local function rotateAround(px: number, py: number, anchorX: number, anchorY: number,
                            sinR: number, cosR: number, worldX: number, worldY: number): number, number
    local rx = px * cosR - py * sinR
    local ry = px * sinR + py * cosR
    return worldX + anchorX + rx, worldY + anchorY + ry
end

-- Extract edges from a collision object, honoring the object's rotation
-- (degrees, clockwise around (obj.x, obj.y)). Without this, rotated collision
-- shapes authored in Tiled flatten to axis-aligned versions.
local function extractObjectEdges(obj: ObjectData, worldX: number, worldY: number): {Edge}
    local rotation = obj.rotation or 0
    local sinR = 0.0
    local cosR = 1.0
    if rotation ~= 0 then
        local rad = rotation * math.pi / 180
        sinR = math.sin(rad)
        cosR = math.cos(rad)
    end

    if obj.shape == "rectangle" then
        -- Rectangle vertices are at offsets (0,0), (w,0), (w,h), (0,h) relative
        -- to (obj.x, obj.y). Rotate each then build clockwise edges.
        local w, h = obj.width, obj.height
        local x1, y1 = rotateAround(0, 0, obj.x, obj.y, sinR, cosR, worldX, worldY)
        local x2, y2 = rotateAround(w, 0, obj.x, obj.y, sinR, cosR, worldX, worldY)
        local x3, y3 = rotateAround(w, h, obj.x, obj.y, sinR, cosR, worldX, worldY)
        local x4, y4 = rotateAround(0, h, obj.x, obj.y, sinR, cosR, worldX, worldY)
        return {
            { x1 = x1, y1 = y1, x2 = x2, y2 = y2 },  -- Top
            { x1 = x2, y1 = y2, x2 = x3, y2 = y3 },  -- Right
            { x1 = x3, y1 = y3, x2 = x4, y2 = y4 },  -- Bottom
            { x1 = x4, y1 = y4, x2 = x1, y2 = y1 },  -- Left
        }
    elseif obj.shape == "polygon" and obj.polygon then
        local edges: {Edge} = {}
        local n = #obj.polygon
        for i = 1, n do
            local p1 = obj.polygon[i]
            local p2 = obj.polygon[i % n + 1]
            local x1, y1 = rotateAround(p1.x, p1.y, obj.x, obj.y, sinR, cosR, worldX, worldY)
            local x2, y2 = rotateAround(p2.x, p2.y, obj.x, obj.y, sinR, cosR, worldX, worldY)
            table.insert(edges, {x1 = x1, y1 = y1, x2 = x2, y2 = y2})
        end
        return edges
    end
    -- Ellipses and other shapes are not supported for merging
    return {}
end

-- Collect all edges from tiles with collision data
local function collectEdges(
    tilemapData: TilemapData,
    config: CollisionConfig
): {Edge}, {ObjectData}
    local edges: {Edge} = {}
    local isolatedObjects: {ObjectData} = {}  -- Objects that can't be merged (ellipses, etc.)

    -- Iterate through all tile layers
    for _, layer in ipairs(tilemapData.layers) do
        if layer.type == "tilelayer" and layer.data then
            for tileY = 1, layer.height do
                for tileX = 1, layer.width do
                    -- 0-based FFI index
                    local idx = (tileY - 1) * layer.width + (tileX - 1)
                    local gid = layer.data[idx]

                    if gid and gid > 0 then
                        -- Strip flip flags before tileset/tile lookup. Without this,
                        -- the high-bit flip flags inflate the GID and the local-tile
                        -- lookup misses entirely, silently dropping collision.
                        local cleanGid = getCleanGid(gid)
                        -- Find tileset and tile data
                        local tileset: TilesetData = nil
                        for i = #tilemapData.tilesets, 1, -1 do
                            if cleanGid >= tilemapData.tilesets[i].firstgid then
                                tileset = tilemapData.tilesets[i]
                                break
                            end
                        end

                        if tileset then
                            local localId = cleanGid - tileset.firstgid
                            local tileData = tileset.tiles[localId]

                            if tileData and tileData.objectgroup and tileData.objectgroup.objects then
                                -- Check filter
                                if not config.filter or config.filter(tileData, cleanGid, tileX, tileY) then
                                    -- Calculate world position of tile
                                    local worldX = (tileX - 1) * tilemapData.tilewidth + layer.offsetx
                                    local worldY = (tileY - 1) * tilemapData.tileheight + layer.offsety

                                    -- Extract edges from all collision objects
                                    for _, obj in ipairs(tileData.objectgroup.objects) do
                                        if obj.shape == "rectangle" or obj.shape == "polygon" then
                                            local objEdges = extractObjectEdges(obj, worldX, worldY)
                                            for _, edge in ipairs(objEdges) do
                                                table.insert(edges, edge)
                                            end
                                        else
                                            -- Store non-mergeable objects for later
                                            local worldObj: ObjectData = {
                                                id = obj.id,
                                                name = obj.name,
                                                class = obj.class,
                                                x = worldX + obj.x,
                                                y = worldY + obj.y,
                                                width = obj.width,
                                                height = obj.height,
                                                rotation = obj.rotation,
                                                visible = obj.visible,
                                                gid = obj.gid,
                                                properties = obj.properties,
                                                shape = obj.shape,
                                            }
                                            table.insert(isolatedObjects, worldObj)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return edges, isolatedObjects
end

-- Collect edges from a specific chunk region of a single layer
local function collectChunkEdges(
    tilemapData: TilemapData,
    config: CollisionConfig,
    layerIndex: integer,
    chunkX: integer,
    chunkY: integer
): {Edge}, {ObjectData}
    local edges: {Edge} = {}
    local isolatedObjects: {ObjectData} = {}

    local layer = tilemapData.layers[layerIndex]
    if not layer or layer.type ~= "tilelayer" or not layer.data then
        return edges, isolatedObjects
    end

    -- Calculate tile range for this chunk
    local startCol = chunkX * CHUNK_SIZE + 1
    local startRow = chunkY * CHUNK_SIZE + 1
    local endCol = math.min(startCol + CHUNK_SIZE - 1, layer.width)
    local endRow = math.min(startRow + CHUNK_SIZE - 1, layer.height)

    for tileY = startRow, endRow do
        for tileX = startCol, endCol do
            -- 0-based FFI index
            local idx = (tileY - 1) * layer.width + (tileX - 1)
            local gid = layer.data[idx]

            if gid and gid > 0 then
                -- Strip flip flags before tileset/tile lookup (see collectEdges).
                local cleanGid = getCleanGid(gid)
                -- Find tileset and tile data
                local tileset: TilesetData = nil
                for i = #tilemapData.tilesets, 1, -1 do
                    if cleanGid >= tilemapData.tilesets[i].firstgid then
                        tileset = tilemapData.tilesets[i]
                        break
                    end
                end

                if tileset then
                    local localId = cleanGid - tileset.firstgid
                    local tileData = tileset.tiles[localId]

                    if tileData and tileData.objectgroup and tileData.objectgroup.objects then
                        -- Check filter
                        if not config.filter or config.filter(tileData, cleanGid, tileX, tileY) then
                            -- Calculate world position of tile
                            local worldX = (tileX - 1) * tilemapData.tilewidth + layer.offsetx
                            local worldY = (tileY - 1) * tilemapData.tileheight + layer.offsety

                            -- Extract edges from all collision objects
                            for _, obj in ipairs(tileData.objectgroup.objects) do
                                if obj.shape == "rectangle" or obj.shape == "polygon" then
                                    local objEdges = extractObjectEdges(obj, worldX, worldY)
                                    for _, edge in ipairs(objEdges) do
                                        table.insert(edges, edge)
                                    end
                                else
                                    -- Store non-mergeable objects for later
                                    local worldObj: ObjectData = {
                                        id = obj.id,
                                        name = obj.name,
                                        class = obj.class,
                                        x = worldX + obj.x,
                                        y = worldY + obj.y,
                                        width = obj.width,
                                        height = obj.height,
                                        rotation = obj.rotation,
                                        visible = obj.visible,
                                        gid = obj.gid,
                                        properties = obj.properties,
                                        shape = obj.shape,
                                    }
                                    table.insert(isolatedObjects, worldObj)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return edges, isolatedObjects
end

-- Remove internal edges (edges that appear twice with opposite directions)
local function removeInternalEdges(edges: {Edge}): {Edge}
    local edgeCounts: {string: integer} = {}
    local edgeData: {string: Edge} = {}

    -- Count edges (using undirected key)
    for _, edge in ipairs(edges) do
        local key = edgeKey(edge.x1, edge.y1, edge.x2, edge.y2)
        edgeCounts[key] = (edgeCounts[key] or 0) + 1
        edgeData[key] = edge
    end

    -- Keep only edges that appear exactly once (external edges)
    local result: {Edge} = {}
    for _, edge in ipairs(edges) do
        local key = edgeKey(edge.x1, edge.y1, edge.x2, edge.y2)
        if edgeCounts[key] == 1 then
            table.insert(result, edge)
        end
    end

    return result
end

-- Build adjacency map for edge tracing
local function buildAdjacencyMap(edges: {Edge}): {string: {Edge}}
    local adjacency: {string: {Edge}} = {}

    for _, edge in ipairs(edges) do
        local startKey = string.format("%.2f,%.2f", edge.x1, edge.y1)
        if not adjacency[startKey] then
            adjacency[startKey] = {}
        end
        table.insert(adjacency[startKey], edge)
    end

    return adjacency
end

-- Trace closed polygons from edges
local function tracePolygons(edges: {Edge}): {{number}}
    if #edges == 0 then
        return {}
    end

    local adjacency = buildAdjacencyMap(edges)
    local used: {string: boolean} = {}
    local polygons: {{number}} = {}

    for _, startEdge in ipairs(edges) do
        local startKey = directedEdgeKey(startEdge.x1, startEdge.y1, startEdge.x2, startEdge.y2)

        if not used[startKey] then
            local vertices: {number} = {}
            local currentEdge = startEdge
            local iterations = 0
            local maxIterations = #edges + 1

            repeat
                local key = directedEdgeKey(currentEdge.x1, currentEdge.y1, currentEdge.x2, currentEdge.y2)
                if used[key] then
                    break
                end
                used[key] = true

                -- Add start point of edge
                table.insert(vertices, currentEdge.x1)
                table.insert(vertices, currentEdge.y1)

                -- Find next edge starting from current edge's end point
                local endKey = string.format("%.2f,%.2f", currentEdge.x2, currentEdge.y2)
                local nextEdges = adjacency[endKey]
                local nextEdge: Edge = nil

                if nextEdges then
                    for _, candidate in ipairs(nextEdges) do
                        local candKey = directedEdgeKey(candidate.x1, candidate.y1, candidate.x2, candidate.y2)
                        if not used[candKey] then
                            nextEdge = candidate
                            break
                        end
                    end
                end

                if nextEdge then
                    currentEdge = nextEdge
                else
                    break
                end

                iterations = iterations + 1
            until iterations > maxIterations or (
                approxEqual(currentEdge.x1, startEdge.x1) and
                approxEqual(currentEdge.y1, startEdge.y1)
            )

            -- Only keep closed polygons with at least 3 vertices (6 numbers)
            if #vertices >= 6 then
                table.insert(polygons, vertices)
            end
        end
    end

    return polygons
end

-- Create chain shape from vertices (Love2D 12 API)
local function createChainShape(body: PhysicsBody, vertices: {number})
    if #vertices < 6 then
        return
    end

    -- Love2D 12: pass body as first parameter (cast to bypass outdated type defs)
    local newChainShape = lp.newChainShape as function(PhysicsBody, boolean, {number}): love.physics.Shape
    newChainShape(body, true, vertices)
end

function collision.createColliders(
    tilemapData: TilemapData,
    physicsWorld: PhysicsWorld,
    config: CollisionConfig
): {PhysicsBody}
    if not config.enabled then
        return {}
    end

    local bodies: {PhysicsBody} = {}

    -- Collect all edges from tiles
    local edges, isolatedObjects = collectEdges(tilemapData, config)

    if #edges == 0 and #isolatedObjects == 0 then
        return bodies
    end

    -- Create main static body for collision geometry
    local body = lp.newBody(physicsWorld, 0, 0, "static")
    table.insert(bodies, body)

    if config.mergeShapes ~= false and #edges > 0 then
        -- Remove internal edges (shared between adjacent tiles)
        local externalEdges = removeInternalEdges(edges)

        -- Trace closed polygons
        local polygons = tracePolygons(externalEdges)

        -- Create chain shapes for each polygon
        for _, vertices in ipairs(polygons) do
            createChainShape(body, vertices)
        end
    else
        -- No merging: create individual fixtures for each edge set
        -- This would require tracking which edges belong to which tile
        -- For simplicity, we'll still remove internal edges but not merge collinear
        local externalEdges = removeInternalEdges(edges)
        local polygons = tracePolygons(externalEdges)
        for _, vertices in ipairs(polygons) do
            createChainShape(body, vertices)
        end
    end

    -- Handle isolated objects (ellipses, etc.) - Love2D 12 API
    local newCircleShape = lp.newCircleShape as function(PhysicsBody, number, number, number): love.physics.Shape
    for _, obj in ipairs(isolatedObjects) do
        if obj.shape == "ellipse" then
            -- Approximate ellipse as circle using average radius
            local radius = (obj.width + obj.height) / 4
            local cx = obj.x + obj.width / 2
            local cy = obj.y + obj.height / 2
            newCircleShape(body, cx, cy, radius)
        end
    end

    return bodies
end

function collision.destroyColliders(bodies: {PhysicsBody})
    for _, body in ipairs(bodies) do
        if body and not body:isDestroyed() then
            body:destroy()
        end
    end
end

function collision.destroyCollider(body: PhysicsBody)
    if body and not body:isDestroyed() then
        body:destroy()
    end
end

function collision.createChunkCollider(
    tilemapData: TilemapData,
    physicsWorld: PhysicsWorld,
    config: CollisionConfig,
    layerIndex: integer,
    chunkX: integer,
    chunkY: integer
): PhysicsBody
    if not config.enabled then
        return nil
    end

    -- Collect edges from this chunk only
    local edges, isolatedObjects = collectChunkEdges(tilemapData, config, layerIndex, chunkX, chunkY)

    if #edges == 0 and #isolatedObjects == 0 then
        return nil
    end

    -- Create static body for this chunk's collision geometry
    local body = lp.newBody(physicsWorld, 0, 0, "static")

    if config.mergeShapes ~= false and #edges > 0 then
        -- Remove internal edges (shared between adjacent tiles within chunk)
        local externalEdges = removeInternalEdges(edges)

        -- Trace closed polygons
        local polygons = tracePolygons(externalEdges)

        -- Create chain shapes for each polygon
        for _, vertices in ipairs(polygons) do
            createChainShape(body, vertices)
        end
    else
        -- No merging: still remove internal edges but create separate shapes
        local externalEdges = removeInternalEdges(edges)
        local polygons = tracePolygons(externalEdges)
        for _, vertices in ipairs(polygons) do
            createChainShape(body, vertices)
        end
    end

    -- Handle isolated objects (ellipses, etc.) - Love2D 12 API
    local newCircleShape = lp.newCircleShape as function(PhysicsBody, number, number, number): love.physics.Shape
    for _, obj in ipairs(isolatedObjects) do
        if obj.shape == "ellipse" then
            local radius = (obj.width + obj.height) / 4
            local cx = obj.x + obj.width / 2
            local cy = obj.y + obj.height / 2
            newCircleShape(body, cx, cy, radius)
        end
    end

    -- Check if body has any shapes; if not, destroy and return nil
    -- Note: getShapes is the Love2D 12 replacement for deprecated getFixtures
    local getShapes = (body as {string: any}).getShapes as function(any): {any}
    local shapes = getShapes(body)
    if #shapes == 0 then
        body:destroy()
        return nil
    end

    return body
end

function collision.tileHasCollision(tilemapData: TilemapData, gid: integer): boolean
    if not gid or gid <= 0 then
        return false
    end

    -- Strip flip flags so flipped tiles correctly resolve to their base tile.
    local cleanGid = getCleanGid(gid)

    -- Find tileset for this GID
    local tileset: TilesetData = nil
    for i = #tilemapData.tilesets, 1, -1 do
        if cleanGid >= tilemapData.tilesets[i].firstgid then
            tileset = tilemapData.tilesets[i]
            break
        end
    end

    if not tileset then
        return false
    end

    local localId = cleanGid - tileset.firstgid
    local tileData = tileset.tiles[localId]

    return tileData ~= nil
        and tileData.objectgroup ~= nil
        and tileData.objectgroup.objects ~= nil
        and #tileData.objectgroup.objects > 0
end

return collision
