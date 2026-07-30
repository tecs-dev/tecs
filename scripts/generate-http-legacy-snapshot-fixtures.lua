-- Regenerates the binary HTTP snapshots captured before DataStream was
-- replaced. Run this only from the repository revision named by the fixture
-- README: the point is to preserve that revision's wire representation.

local luaRoot = assert(os.getenv("TECS_LUA"), "TECS_LUA must name the built Lua tree")
package.path = luaRoot .. "/?.lua;" .. luaRoot .. "/?/init.lua;" .. package.path

local ffi = require("ffi")
local StringBuffer = require("string.buffer")
local tecs = require("tecs")
local files = tecs.io.files
local http = tecs.io.http

local output = "spec/fixtures/http-legacy-snapshots/"

-- LuaJIT's native table encoder follows randomized hash iteration. Snapshot
-- decoding does not care about map order, but fixtures do: the same source
-- should produce the same committed bytes in every process. Encode the small
-- plain-data maps in these fixtures with sorted keys while retaining the
-- binary-v2 framing and scalar encoding used by the engine.
local function putU32(buffer, value)
    assert(value >= 0 and value < 0xe0, "fixture table is too large for one-byte U encoding")
    buffer:put(string.char(value))
end

local function sortedKeys(value)
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        local leftType = type(left)
        local rightType = type(right)
        if leftType == rightType then
            return tostring(left) < tostring(right)
        end
        return leftType < rightType
    end)
    return keys
end

local function encodeCanonical(buffer, value)
    if type(value) ~= "table" then
        buffer:encode(value)
        return
    end

    local keys = sortedKeys(value)
    if #keys == 0 then
        buffer:put(string.char(0x08))
        return
    end

    buffer:put(string.char(0x09))
    putU32(buffer, #keys)
    for _, key in ipairs(keys) do
        encodeCanonical(buffer, key)
        encodeCanonical(buffer, value[key])
    end
end

local function binarySnapshot(component)
    local componentType = assert(component.componentType)
    local world = tecs.ecs.newWorld()
    local entity = world:spawn(component)
    world:commit()

    -- Pipeline state is unrelated to HTTP compatibility and is itself a map.
    -- Clearing it makes this one-component fixture carry only the bytes under
    -- test. This is a valid state for the current snapshot writer.
    world.pipeline.fixedAccumulator = nil
    world.pipeline.phaseStates = nil

    local snapshot = assert(world:saveSnapshot({format = "table"}).snapshot)
    assert(#snapshot.componentTable == 1)
    assert(#snapshot.archetypes == 1)
    assert(#snapshot.archetypes[1].columnIndices == 1)
    assert(#snapshot.archetypes[1].entities == 1)
    assert(snapshot.componentTable[1].name == componentType.componentName)

    local row = snapshot.archetypes[1].entities[1]
    assert(row[1] == entity)

    local buffer = StringBuffer.new()
    buffer:encode(snapshot.version)
    buffer:encode(snapshot.nextEntityId)
    buffer:encode(1) -- entity count
    buffer:encode(1) -- archetype count
    buffer:encode(1) -- component count
    buffer:encode(snapshot.componentTable[1].name)
    buffer:encode(componentType.fingerprint or "")
    buffer:encode(1) -- column count
    buffer:encode(1) -- archetype entity count
    buffer:encode(1) -- component-table index
    buffer:encode(0) -- dense column-major mode

    local ids = ffi.new("double[1]", entity)
    buffer:putcdata(ids, ffi.sizeof(ids))
    encodeCanonical(buffer, row[2])
    buffer:encode(false) -- no keyed snapshot data follows
    return buffer:tostring(), entity
end

local function writeSnapshot(name, component, validate)
    local bytes, entity = binarySnapshot(component)
    local path = output .. name
    local ok, reason = files.write(path, bytes)
    assert(ok, reason)

    local restored = tecs.ecs.newWorld()
    restored:loadSnapshot(bytes)
    validate(restored, entity)
    print(("wrote %s (%d bytes)"):format(path, #bytes))
end

writeSnapshot(
    "request-string.bin",
    http.plugin.Request({
        url = "https://example.test/upload/string",
        method = "POST",
        body = "legacy request body",
    }),
    function(world, entity)
        local request = assert(world:get(entity, http.plugin.Request))
        assert(request.url == "https://example.test/upload/string")
        assert(request.method == "POST")
        assert(request.body == "legacy request body")
    end
)

writeSnapshot(
    "request-file-datastream.bin",
    http.plugin.Request({
        url = "https://example.test/upload/file",
        method = "PUT",
        body = http.newFileStream("spec/fixtures/test_material.glsl", "text/plain"),
    }),
    function(world, entity)
        local request = assert(world:get(entity, http.plugin.Request))
        assert(type(request.body) == "table")
        assert(getmetatable(request.body) == nil)
        assert(request.body.kind == "file")
        assert(request.body.path == "spec/fixtures/test_material.glsl")
        assert(request.body.contentType == "text/plain")
    end
)

writeSnapshot(
    "response-string-datastream.bin",
    http.plugin.Response({
        status = 201,
        headers = {["content-type"] = "text/plain"},
        body = http.newStringStream("legacy response body", "text/plain"),
        url = "https://example.test/response",
    }),
    function(world, entity)
        local response = assert(world:get(entity, http.plugin.Response))
        assert(response.status == 201)
        assert(response.url == "https://example.test/response")
        assert(type(response.body) == "table")
        assert(getmetatable(response.body) == nil)
        assert(response.body.kind == "string")
        assert(response.body._text == "legacy response body")
        assert(response.body.contentType == "text/plain")
    end
)
