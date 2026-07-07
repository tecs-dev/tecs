--- Pure JSON parsing for Tiled map files.
---
--- Parses Tiled JSON export format (.tmj for maps, .tsj for tilesets).
--- Handles embedded and external tilesets, layer flattening, and property conversion.
--- This module has no dependencies on gfx or assets, making it safe to import anywhere.

local ffi <const> = require("ffi")
local types <const> = require("tecs2d.tiled.types")
local tileset_utils <const> = require("tecs2d.tiled.internal.tileset")
local json <const> = require("tecs.utils.json")

local type TilemapData = types.TilemapData
local type TilesetData = types.TilesetData
local type TileData = types.TileData
local type LayerData = types.LayerData
local type ObjectData = types.ObjectData
local type Point = types.Point
local type Frame = types.Frame

-- Method implementations for TilemapData (attached directly to each instance)
local function worldToTile(self: TilemapData, worldX: number, worldY: number): integer, integer
    local tileX = math.floor(worldX / self.tilewidth) + 1
    local tileY = math.floor(worldY / self.tileheight) + 1
    return tileX, tileY
end

local function tileToWorld(self: TilemapData, tileX: integer, tileY: integer): number, number
    local worldX: number = (tileX - 1) * self.tilewidth
    local worldY: number = (tileY - 1) * self.tileheight
    return worldX, worldY
end

local function getTile(self: TilemapData, layerIndex: integer, tileX: integer, tileY: integer): integer
    local layer = self.layers[layerIndex]
    if not layer or layer.type ~= "tilelayer" then
        return 0
    end
    if tileX < 1 or tileX > layer.width or tileY < 1 or tileY > layer.height then
        return 0
    end
    -- 0-based FFI index: (tileY-1) * width + (tileX-1)
    local idx = (tileY - 1) * layer.width + (tileX - 1)
    return layer.data[idx] or 0
end

local function getTileAt(self: TilemapData, layerIndex: integer, worldX: number, worldY: number): integer
    local tileX, tileY = worldToTile(self, worldX, worldY)
    return getTile(self, layerIndex, tileX, tileY)
end

-- Get TileData for a tile at given position (returns nil if no tile data)
local function getTileProperties(self: TilemapData, layerIndex: integer, tileX: integer, tileY: integer): TileData
    local gid = getTile(self, layerIndex, tileX, tileY)
    if gid == 0 then
        return nil
    end

    -- Strip flip flags
    local cleanGid = tileset_utils.getCleanGid(gid)

    -- Find tileset for this GID
    local tileset = tileset_utils.getTilesetForGid(self, cleanGid)
    if not tileset then
        return nil
    end

    -- Get local tile ID and look up tile data
    local localId = tileset_utils.getLocalTileId(tileset, cleanGid)
    return tileset.tiles[localId]
end

-- Get layer properties by index
local function getLayerProperties(self: TilemapData, layerIndex: integer): {string: any}
    local layer = self.layers[layerIndex]
    if not layer then
        return nil
    end
    return layer.properties
end

-- Get layer by name
local function getLayer(self: TilemapData, name: string): LayerData
    local layers <const> = self.layers
    for i = 1, #layers do
        if layers[i].name == name then
            return layers[i]
        end
    end
    return nil
end

-- Convert RGBA [0-1] back to hex color string
local function serializeColor(rgba: {number, number, number, number}): string
    if not rgba then
        return nil
    end
    local r = math.floor(rgba[1] * 255 + 0.5)
    local g = math.floor(rgba[2] * 255 + 0.5)
    local b = math.floor(rgba[3] * 255 + 0.5)
    local a = math.floor((rgba[4] or 1) * 255 + 0.5)
    if a == 255 then
        return string.format("#%02x%02x%02x", r, g, b)
    else
        return string.format("#%02x%02x%02x%02x", a, r, g, b)
    end
end

-- Convert properties table back to Tiled array format
local function serializeProperties(props: {string: any}): {{string: any}}
    if not props or not next(props) then
        return nil
    end
    local result: {{string: any}} = {}
    for name, value in pairs(props) do
        local propType: string
        local serializedValue: any = value
        local valueType = type(value)
        if valueType == "boolean" then
            propType = "bool"
        elseif valueType == "number" then
            propType = math.floor(value as number) == value and "int" or "float"
        elseif valueType == "string" then
            propType = "string"
        elseif valueType == "table" then
            local t = value as {any}
            if #t == 4 and type(t[1]) == "number" then
                propType = "color"
                serializedValue = serializeColor(t as {number, number, number, number})
            else
                propType = "string"
                serializedValue = json.serialize(value)
            end
        else
            propType = "string"
            serializedValue = tostring(value)
        end
        table.insert(result, {name = name, type = propType, value = serializedValue})
    end
    return result
end

-- Convert points array to Tiled format
local function serializePoints(points: {Point}): {{string: any}}
    if not points then
        return nil
    end
    local result: {{string: any}} = {}
    for i = 1, #points do
        local pt = points[i]
        table.insert(result, {x = pt.x, y = pt.y})
    end
    return result
end

-- Convert object to Tiled format
local function serializeObject(obj: ObjectData): {string: any}
    local result: {string: any} = {
        id = obj.id,
        name = obj.name,
        x = obj.x,
        y = obj.y,
        width = obj.width,
        height = obj.height,
        rotation = obj.rotation,
        visible = obj.visible
    }
    if obj.class and obj.class ~= "" then
        result["type"] = obj.class
    end
    if obj.gid and obj.gid > 0 then
        result.gid = obj.gid
    end
    if obj.shape == "point" then
        result.point = true
    elseif obj.shape == "ellipse" then
        result.ellipse = true
    elseif obj.shape == "polygon" then
        result.polygon = serializePoints(obj.polygon)
    elseif obj.shape == "polyline" then
        result.polyline = serializePoints(obj.polyline)
    end
    local props = serializeProperties(obj.properties)
    if props then
        result.properties = props
    end
    return result
end

-- Convert layer to Tiled format
local function serializeLayer(layer: LayerData): {string: any}
    local result: {string: any} = {
        id = layer.id,
        name = layer.name,
        type = layer.type,
        visible = layer.visible,
        opacity = layer.opacity,
        x = 0,
        y = 0
    }
    if layer.offsetx ~= 0 then
        result.offsetx = layer.offsetx
    end
    if layer.offsety ~= 0 then
        result.offsety = layer.offsety
    end
    if layer.parallaxx ~= 1 then
        result.parallaxx = layer.parallaxx
    end
    if layer.parallaxy ~= 1 then
        result.parallaxy = layer.parallaxy
    end
    if layer.tintcolor then
        result.tintcolor = serializeColor(layer.tintcolor)
    end
    local props = serializeProperties(layer.properties)
    if props then
        result.properties = props
    end
    if layer.type == "tilelayer" then
        result.width = layer.width
        result.height = layer.height
        -- layer.data is an FFI uint32_t buffer; the JSON serializer
        -- rejects cdata, so copy it into a plain array of GIDs.
        if layer.data then
            local count = layer.width * layer.height
            local src <const> = layer.data
            local gids: {integer} = {}
            for i = 1, count do
                gids[i] = src[i - 1]
            end
            result.data = gids
        end
    elseif layer.type == "objectgroup" then
        result.draworder = "topdown"
        local objects: {{string: any}} = {}
        if layer.objects then
            local layerObjects <const> = layer.objects
            for i = 1, #layerObjects do
                table.insert(objects, serializeObject(layerObjects[i]))
            end
        end
        result.objects = objects
    elseif layer.type == "imagelayer" then
        result.image = layer.imagePath
        if layer.imagewidth > 0 then
            result.imagewidth = layer.imagewidth
        end
        if layer.imageheight > 0 then
            result.imageheight = layer.imageheight
        end
        if layer.repeatx then
            result.repeatx = layer.repeatx
        end
        if layer.repeaty then
            result.repeaty = layer.repeaty
        end
    end
    return result
end

-- Convert tileset to Tiled format (embedded)
local function serializeTileset(ts: TilesetData): {string: any}
    local result: {string: any} = {
        firstgid = ts.firstgid,
        name = ts.name,
        tilewidth = ts.tilewidth,
        tileheight = ts.tileheight,
        tilecount = ts.tilecount,
        columns = ts.columns,
        image = ts.imagePath,
        imagewidth = ts.imagewidth,
        imageheight = ts.imageheight
    }
    if ts.spacing > 0 then
        result.spacing = ts.spacing
    end
    if ts.margin > 0 then
        result.margin = ts.margin
    end
    if ts.transparentcolor then
        result.transparentcolor = ts.transparentcolor
    end
    -- Serialize tile definitions
    if ts.tiles and next(ts.tiles) then
        local tiles: {{string: any}} = {}
        for localId, tile in pairs(ts.tiles) do
            local tileJson: {string: any} = {id = localId}
            if tile.class and tile.class ~= "" then
                tileJson["type"] = tile.class
            end
            if tile.animation then
                local frames: {{string: any}} = {}
                local animation <const> = tile.animation
                for fi = 1, #animation do
                    local frame = animation[fi]
                    table.insert(frames, {
                        tileid = frame.tileid,
                        duration = math.floor(frame.duration * 1000 + 0.5)
                    })
                end
                tileJson.animation = frames
            end
            local props = serializeProperties(tile.properties)
            if props then
                tileJson.properties = props
            end
            table.insert(tiles, tileJson)
        end
        result.tiles = tiles
    end
    return result
end

-- Serialize TilemapData to Tiled-compatible JSON
local function toJSON(self: TilemapData, pretty: boolean): string
    local map: {string: any} = {
        compressionlevel = -1,
        height = self.height,
        width = self.width,
        infinite = false,
        orientation = "orthogonal",
        renderorder = "right-down",
        tiledversion = "1.10.2",
        tileheight = self.tileheight,
        tilewidth = self.tilewidth,
        type = "map",
        version = "1.10"
    }
    -- Serialize layers
    local layers: {{string: any}} = {}
    local selfLayers <const> = self.layers
    for i = 1, #selfLayers do
        table.insert(layers, serializeLayer(selfLayers[i]))
    end
    map.layers = layers
    -- Serialize tilesets
    local tilesets: {{string: any}} = {}
    local selfTilesets <const> = self.tilesets
    for i = 1, #selfTilesets do
        local ts = selfTilesets[i]
        table.insert(tilesets, serializeTileset(ts))
    end
    map.tilesets = tilesets
    -- Serialize properties
    local props = serializeProperties(self.properties)
    if props then
        map.properties = props
    end
    if pretty then
        return json.serializePretty(map)
    else
        return json.serialize(map)
    end
end

local record parser
    --- Parse a Tiled map JSON into TilemapData.
    --- Does NOT load tileset images; that's handled by the asset loader.
    --- @param json The parsed JSON table
    --- @return Parsed TilemapData
    parseTiledMap: function(json: {string: any}): TilemapData

    --- Parse an external tileset JSON.
    --- @param json The parsed JSON table
    --- @param firstgid The first GID assigned to this tileset
    --- @return Parsed TilesetData (without image loaded)
    parseTileset: function(json: {string: any}, firstgid: integer): TilesetData

    --- Parse custom properties array.
    --- @param propsArray The properties array from Tiled JSON
    --- @return Table of property name to value
    parseProperties: function(propsArray: {{string: any}}): {string: any}

    --- Resolve a relative path from a base path.
    --- @param basePath The base file path
    --- @param relativePath The relative path to resolve
    --- @return Resolved absolute path
    resolveRelativePath: function(basePath: string, relativePath: string): string

    --- Attach read-only methods to a TilemapData instance.
    --- Called by parseTiledMap; also available for loader.tl to extend.
    --- @param map The TilemapData to attach methods to
    attachBaseMethods: function(map: TilemapData)

    --- Convert world coordinates to tile coordinates.
    worldToTile: function(map: TilemapData, worldX: number, worldY: number): integer, integer

    --- Convert tile coordinates to world coordinates.
    tileToWorld: function(map: TilemapData, tileX: integer, tileY: integer): number, number

    --- Get a tile GID at tile coordinates (0 for out-of-range or non-tile layers).
    getTile: function(map: TilemapData, layerIndex: integer, tileX: integer, tileY: integer): integer

    --- Get a tile GID at world coordinates.
    getTileAt: function(map: TilemapData, layerIndex: integer, worldX: number, worldY: number): integer

    -- Re-export types for convenience
    type TilemapData = types.TilemapData
    type TilesetData = types.TilesetData
    type LayerData = types.LayerData
end

-- Parse a hex color string to RGBA table (0-1 range)
local function parseHexColor(hex: string): {number, number, number, number}
    if not hex then
        return nil
    end

    -- Remove leading # if present
    if hex:sub(1, 1) == "#" then
        hex = hex:sub(2)
    end

    local r: number = 1
    local g: number = 1
    local b: number = 1
    local a: number = 1

    if #hex == 6 then
        -- RGB
        r = tonumber(hex:sub(1, 2), 16) / 255
        g = tonumber(hex:sub(3, 4), 16) / 255
        b = tonumber(hex:sub(5, 6), 16) / 255
    elseif #hex == 8 then
        -- ARGB (Tiled uses AARRGGBB)
        a = tonumber(hex:sub(1, 2), 16) / 255
        r = tonumber(hex:sub(3, 4), 16) / 255
        g = tonumber(hex:sub(5, 6), 16) / 255
        b = tonumber(hex:sub(7, 8), 16) / 255
    end

    return {r, g, b, a}
end

function parser.parseProperties(propsArray: {{string: any}}): {string: any}
    if not propsArray then
        return {}
    end

    local result: {string: any} = {}

    for i = 1, #propsArray do
        local prop = propsArray[i]
        local name = prop.name as string
        local propType = prop.type as string
        local value = prop.value

        -- Convert based on type
        if propType == "color" then
            result[name] = parseHexColor(value as string)
        elseif propType == "file" or propType == "string" then
            result[name] = value as string
        elseif propType == "int" or propType == "float" then
            result[name] = value as number
        elseif propType == "bool" then
            result[name] = value as boolean
        elseif propType == "object" then
            result[name] = value as integer  -- Object reference ID
        else
            -- Default: use value as-is
            result[name] = value
        end
    end

    return result
end

function parser.resolveRelativePath(basePath: string, relativePath: string): string
    -- Get directory of base path
    local dir = basePath:match("(.*/)")
    if not dir then
        dir = ""
    end

    -- Handle ../ in relative path
    while relativePath:sub(1, 3) == "../" do
        relativePath = relativePath:sub(4)
        dir = dir:match("(.*/)[^/]+/$") or ""
    end

    -- Handle ./ in relative path
    if relativePath:sub(1, 2) == "./" then
        relativePath = relativePath:sub(3)
    end

    return dir .. relativePath
end

-- Parse a point array (for polygons/polylines)
local function parsePoints(pointsArray: {{string: any}}): {Point}
    if not pointsArray then
        return nil
    end

    local result: {Point} = {}
    for i = 1, #pointsArray do
        local pt = pointsArray[i]
        table.insert(result, {
            x = pt.x as number,
            y = pt.y as number
        })
    end
    return result
end

-- Parse an object from Tiled JSON
local function parseObject(obj: {string: any}): ObjectData
    local shape = "rectangle"  -- Default shape

    if obj.point then
        shape = "point"
    elseif obj.ellipse then
        shape = "ellipse"
    elseif obj.polygon then
        shape = "polygon"
    elseif obj.polyline then
        shape = "polyline"
    end

    return {
        id = obj.id as integer,
        name = obj.name as string or "",
        class = obj["type"] as string or "",  -- "type" in Tiled JSON = class
        x = obj.x as number,
        y = obj.y as number,
        width = obj.width as number or 0,
        height = obj.height as number or 0,
        rotation = obj.rotation as number or 0,
        visible = obj.visible as boolean ~= false,  -- Default true
        gid = obj.gid as integer or 0,
        properties = parser.parseProperties(obj.properties as {{string: any}}),
        shape = shape,
        polygon = parsePoints(obj.polygon as {{string: any}}),
        polyline = parsePoints(obj.polyline as {{string: any}})
    }
end

-- Parse an objectgroup (collision shapes) from a tile definition
local function parseObjectGroup(objGroup: {string: any}): LayerData
    if not objGroup then
        return nil
    end
    local objects: {ObjectData} = {}
    local rawObjects = objGroup.objects as {{string: any}}
    if rawObjects then
        for i = 1, #rawObjects do
            table.insert(objects, parseObject(rawObjects[i]))
        end
    end
    return {
        id = objGroup.id as integer or 0,
        name = objGroup.name as string or "",
        type = "objectgroup",
        visible = true,
        opacity = 1,
        offsetx = 0,
        offsety = 0,
        parallaxx = 1,
        parallaxy = 1,
        objects = objects,
    } as LayerData
end

-- Parse animation frames
local function parseAnimation(framesArray: {{string: any}}): {Frame}
    if not framesArray then
        return nil
    end

    local result: {Frame} = {}
    for i = 1, #framesArray do
        local frame = framesArray[i]
        table.insert(result, {
            tileid = frame.tileid as integer,
            duration = (frame.duration as number) / 1000  -- Convert ms to seconds
        })
    end
    return result
end

-- Parse a single tile definition
local function parseTile(tileJson: {string: any}): TileData
    return {
        id = tileJson.id as integer,
        class = tileJson["type"] as string or "",
        properties = parser.parseProperties(tileJson.properties as {{string: any}}),
        animation = parseAnimation(tileJson.animation as {{string: any}}),
        objectgroup = parseObjectGroup(tileJson.objectgroup as {string: any}),
    }
end

function parser.parseTileset(data: {string: any}, firstgid: integer): TilesetData
    local ts: TilesetData = {
        firstgid = firstgid,
        name = data.name as string or "",
        tilewidth = data.tilewidth as integer,
        tileheight = data.tileheight as integer,
        tilecount = data.tilecount as integer,
        columns = data.columns as integer,
        spacing = data.spacing as integer or 0,
        margin = data.margin as integer or 0,
        imagePath = data.image as string,
        image = nil,  -- Loaded by asset manager
        imagewidth = data.imagewidth as integer,
        imageheight = data.imageheight as integer,
        transparentcolor = data.transparentcolor as string,
        tiles = {},
        _quads = {},
        _animatedTiles = {},
        _animationStates = {}
    }

    -- Parse individual tile definitions
    if data.tiles then
        local tilesJson = data.tiles as {{string: any}}
        for i = 1, #tilesJson do
            local tile = parseTile(tilesJson[i])
            ts.tiles[tile.id] = tile
        end
    end

    -- Build occluder heights lookup from tile properties
    ts._occluderHeights = {}
    for localId, tile in pairs(ts.tiles) do
        if tile.properties and tile.properties.occluderHeight then
            local height = tile.properties.occluderHeight as number
            if height > 0 then
                ts._occluderHeights[localId] = height
            end
        end
    end

    -- Initialize animation states for this tileset
    tileset_utils.initializeAnimationStates(ts)

    return ts
end

-- Parsing state passed through recursive layer parsing
local record ParseState
    nextGroupIndex: integer  -- Counter for render layer groups
    zOffsetCounter: integer  -- Counter for z offset within current group
    currentGroupIndex: integer  -- Current group's render layer index (nil = ungrouped)
end

-- Parse a layer recursively (handles groups)
-- state: parsing state for tracking group indices and z offsets
-- Returns nothing; modifies state in place
local function parseLayer(
    layerJson: {string: any},
    outputLayers: {LayerData},
    state: ParseState
)
    local layerType = layerJson["type"] as string

    if layerType == "group" then
        -- Entering a Tiled group: all layers inside share the same render layer
        -- Only TOP-LEVEL groups start a new group; nested groups stay in the parent's group
        local savedGroupIndex = state.currentGroupIndex

        if not state.currentGroupIndex then
            -- Top-level group: assign a new render layer group
            state.currentGroupIndex = state.nextGroupIndex
            state.nextGroupIndex = state.nextGroupIndex + 1
            state.zOffsetCounter = 0  -- Reset z offset for new group
        end
        -- Nested groups: keep parent's currentGroupIndex, continue z offset counter

        if layerJson.layers then
            local children <const> = layerJson.layers as {{string: any}}
            for i = 1, #children do
                parseLayer(children[i], outputLayers, state)
            end
        end

        -- Restore state when exiting top-level group
        if not savedGroupIndex then
            state.currentGroupIndex = nil
            state.zOffsetCounter = 0
        else
            -- Nested group: keep parent's state, z continues
        end
        return
    end

    -- Determine groupIndex and zOffset for this layer
    local layerGroupIndex: integer
    local layerZOffset: number

    if state.currentGroupIndex then
        -- Inside a group: share group's render layer, increment z offset
        layerGroupIndex = state.currentGroupIndex
        layerZOffset = state.zOffsetCounter * 100  -- 0, 100, 200, ...
        state.zOffsetCounter = state.zOffsetCounter + 1
    else
        -- Ungrouped top-level layer: gets its own render layer, z = 0
        layerGroupIndex = state.nextGroupIndex
        state.nextGroupIndex = state.nextGroupIndex + 1
        layerZOffset = 0
    end

    local layer: LayerData = {
        id = layerJson.id as integer,
        name = layerJson.name as string or "",
        type = layerType,
        visible = layerJson.visible as boolean ~= false,
        opacity = layerJson.opacity as number or 1,
        offsetx = layerJson.offsetx as number or 0,
        offsety = layerJson.offsety as number or 0,
        parallaxx = layerJson.parallaxx as number or 1,
        parallaxy = layerJson.parallaxy as number or 1,
        tintcolor = parseHexColor(layerJson.tintcolor as string),
        properties = parser.parseProperties(layerJson.properties as {{string: any}}),
        data = nil,
        width = 0,
        height = 0,
        objects = nil,
        imagePath = nil,
        imagewidth = 0,
        imageheight = 0,
        repeatx = false,
        repeaty = false,
        _image = nil,
        layers = nil,
        groupIndex = layerGroupIndex,
        zOffset = layerZOffset
    }

    if layerType == "tilelayer" then
        layer.width = layerJson.width as integer
        layer.height = layerJson.height as integer

        -- Parse tile data (supports compressed base64+zlib/gzip, CSV, or raw arrays)
        if layerJson.data then
            local encoding = layerJson.encoding as string
            -- Tiled's JSON export stores CSV-encoded layers as a plain
            -- JSON array (string CSV only exists in TMX), so route
            -- table-typed data to the raw-array path regardless of the
            -- declared encoding.
            if type(layerJson.data) == "table" and encoding ~= "base64" then
                encoding = nil
            end
            if encoding == "base64" then
                -- Compressed tile data: base64 decode -> decompress -> FFI
                local b64data = layerJson.data as string
                local loveData <const> = love.data as {string: function(string, string, any): love.Data}
                local decoded = loveData.decode("data", "base64", b64data)
                local compression = layerJson.compression as string

                local decompressed: love.Data
                if compression == "zlib" then
                    decompressed = loveData.decompress("data", "zlib", decoded)
                elseif compression == "gzip" then
                    decompressed = loveData.decompress("data", "gzip", decoded)
                elseif compression then
                    error("Unsupported tile compression: " .. compression)
                else
                    -- base64 without compression
                    decompressed = decoded
                end

                -- Anchor the decompressed data to prevent GC
                layer._rawTileData = decompressed

                -- Use FFI pointer directly (0-indexed) - no Lua table allocation
                layer.data = ffi.cast("uint32_t*", decompressed:getFFIPointer()) as {integer}
            elseif encoding == "csv" then
                -- CSV format: comma-separated integers as a string
                local csvData = layerJson.data as string
                local count = layer.width * layer.height
                local buf = ffi.new("uint32_t[?]", count) as {integer}
                local idx = 0
                for num in csvData:gmatch("%-?%d+") do
                    -- Bound the write: a malformed CSV with extra values
                    -- must not run past the FFI buffer.
                    if idx >= count then
                        error(string.format(
                            "tiled: layer '%s' CSV data has more than %d entries (expected width * height)",
                            layer.name, count))
                    end
                    buf[idx] = tonumber(num) as integer
                    idx = idx + 1
                end
                if idx ~= count then
                    error(string.format(
                        "tiled: layer '%s' CSV data has %d entries, expected %d (width * height)",
                        layer.name, idx, count))
                end
                layer.data = buf
            else
                -- Uncompressed raw array - convert to FFI. Size the buffer
                -- by width * height (what readers index by) and require the
                -- array to match, so a short array can't cause reads past
                -- the allocation.
                local rawData = layerJson.data as {integer}
                local count = layer.width * layer.height
                if #rawData ~= count then
                    error(string.format(
                        "tiled: layer '%s' data has %d entries, expected %d (width * height)",
                        layer.name, #rawData, count))
                end
                local buf = ffi.new("uint32_t[?]", count) as {integer}
                for i = 1, count do
                    buf[i - 1] = rawData[i]  -- 1-based Lua to 0-based FFI
                end
                layer.data = buf
            end
        else
            -- Chunked data (infinite maps) is rejected at the map level;
            -- anything else without data is malformed input.
            error("tiled: tile layer '" .. tostring(layer.name) .. "' has no data")
        end
    elseif layerType == "objectgroup" then
        layer.objects = {}
        if layerJson.objects then
            local objects <const> = layerJson.objects as {{string: any}}
            for i = 1, #objects do
                table.insert(layer.objects, parseObject(objects[i]))
            end
        end
    elseif layerType == "imagelayer" then
        layer.imagePath = layerJson.image as string
        layer.imagewidth = layerJson.imagewidth as integer or 0
        layer.imageheight = layerJson.imageheight as integer or 0
        layer.repeatx = layerJson.repeatx as boolean or false
        layer.repeaty = layerJson.repeaty as boolean or false
    end

    table.insert(outputLayers, layer)
end

-- Export the coordinate/tile lookups so callers holding a TilemapData
-- value (rather than a method receiver) share the same implementations.
parser.worldToTile = worldToTile
parser.tileToWorld = tileToWorld
parser.getTile = getTile
parser.getTileAt = getTileAt

-- Attach read-only methods to a TilemapData instance
function parser.attachBaseMethods(map: TilemapData)
    map.worldToTile = worldToTile
    map.tileToWorld = tileToWorld
    map.getTile = getTile
    map.getTileAt = getTileAt
    map.toJSON = toJSON
    map.getTileProperties = getTileProperties
    map.getLayerProperties = getLayerProperties
    map.getLayer = getLayer
end

function parser.parseTiledMap(data: {string: any}): TilemapData
    -- Infinite maps store tile data in per-layer chunk lists instead of
    -- dense arrays; nothing downstream handles that layout, so reject
    -- them with a clear message instead of nil-indexing at spawn.
    if data.infinite == true then
        error("tiled: infinite maps are not supported; disable 'Infinite' in Tiled's map properties and set a fixed size")
    end

    local map: TilemapData = {
        width = data.width as integer,
        height = data.height as integer,
        tilewidth = data.tilewidth as integer,
        tileheight = data.tileheight as integer,
        layers = {},
        tilesets = {},
        properties = parser.parseProperties(data.properties as {{string: any}}),
        _animatedTilesets = {},
        _gidToTileset = {},
        chunkSize = 32
    }

    -- Parse tilesets
    if data.tilesets then
        local tilesets <const> = data.tilesets as {{string: any}}
        for i = 1, #tilesets do
            local tsJson = tilesets[i]
            local firstgid = tsJson.firstgid as integer

            if tsJson.source then
                -- External tileset: store source path for later loading
                -- The asset loader will handle loading the external .tsj file
                local externalTs: TilesetData = {
                    firstgid = firstgid,
                    name = "",
                    tilewidth = 0,
                    tileheight = 0,
                    tilecount = 0,
                    columns = 0,
                    spacing = 0,
                    margin = 0,
                    imagePath = tsJson.source as string,  -- Store source path temporarily
                    image = nil,
                    imagewidth = 0,
                    imageheight = 0,
                    tiles = {},
                    _quads = {},
                    _animatedTiles = {},
                    _animationStates = {},
                    _occluderHeights = {}
                }
                table.insert(map.tilesets, externalTs)
            else
                -- Embedded tileset
                local ts = parser.parseTileset(tsJson, firstgid)
                table.insert(map.tilesets, ts)
            end
        end
    end

    -- Parse layers (flattening groups, assigning render layer groups and z offsets)
    -- Ungrouped top-level layers get unique groupIndex (own render layer)
    -- Layers inside a Tiled group share the same groupIndex with different zOffsets
    local parseState: ParseState = {
        nextGroupIndex = 1,
        zOffsetCounter = 0,
        currentGroupIndex = nil
    }
    if data.layers then
        local layers <const> = data.layers as {{string: any}}
        for i = 1, #layers do
            parseLayer(layers[i], map.layers, parseState)
        end
    end

    -- Build animated tilesets list
    local mapTilesets <const> = map.tilesets
    for i = 1, #mapTilesets do
        local ts = mapTilesets[i]
        if ts._animatedTiles and #ts._animatedTiles > 0 then
            table.insert(map._animatedTilesets, ts)
        end
    end

    -- Build GID cache
    tileset_utils.buildGidCache(map)

    -- Attach method-style API (read-only methods only)
    parser.attachBaseMethods(map)

    return map
end

return parser
