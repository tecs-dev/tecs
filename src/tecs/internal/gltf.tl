-- Static glTF 2.0 and GLB decoding for the asset worker. Everything returned
-- is made only of strings, numbers, booleans, and tables so it can cross a
-- worker channel. GPU objects and public asset records are built on receipt.

local ffi <const> = require("ffi")
local data <const> = require("tecs.data")
local files <const> = require("tecs.io.files")
local loader <const> = require("tecs.ffi.loader")

local record gltf
    decodeFile: function(path: string): {string: any}
end

local COMPONENT_BYTES <const>: {integer: integer} = {
    [5120] = 1,
    [5121] = 1,
    [5122] = 2,
    [5123] = 2,
    [5125] = 4,
    [5126] = 4,
}
local TYPE_COUNT <const>: {string: integer} = {SCALAR = 1, VEC2 = 2, VEC3 = 3, VEC4 = 4, MAT4 = 16}

local function uint32(bytes: string, at: integer): integer
    local a, b, c, d = bytes:byte(at, at + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function base64(text: string): string
    local alphabet <const> = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local values: {integer: integer} = {}
    for index = 1, #alphabet do
        values[alphabet:byte(index)] = index - 1
    end
    local parts: {string} = {}
    local group: {integer} = {}
    for index = 1, #text do
        local byte <const> = text:byte(index)
        if byte ~= 61 then
            local value = values[byte]
            if value ~= nil then
                group[#group + 1] = value
                if #group == 4 then
                    parts[#parts + 1] = string.char(
                        group[1] * 4 + math.floor(group[2] / 16),
                        (group[2] % 16) * 16 + math.floor(group[3] / 4),
                        (group[3] % 4) * 64 + group[4]
                    )
                    group = {}
                end
            end
        end
    end
    if #group == 2 then
        parts[#parts + 1] = string.char(group[1] * 4 + math.floor(group[2] / 16))
    elseif #group == 3 then
        parts[#parts + 1] = string.char(
            group[1] * 4 + math.floor(group[2] / 16), (group[2] % 16) * 16 + math.floor(group[3] / 4)
        )
    end
    return table.concat(parts)
end

local function directory(path: string): string
    return path:match("^(.*[/\\])") or ""
end

local function uriBytes(uri: string, base: string): string
    local encoded = uri:match("^data:[^,]*;base64,(.*)$")
    if encoded ~= nil then
        return base64(encoded)
    end
    if uri:match("^data:") then
        error("tecs: glTF supports only base64 data URIs", 0)
    end
    local bytes = files.read(base .. uri)
    if bytes == nil then
        error(("tecs: cannot read glTF resource %s"):format(base .. uri), 0)
    end
    return bytes
end

local function container(bytes: string, path: string): {string: any}, string
    if #bytes >= 12 and uint32(bytes, 1) == 0x46546c67 then
        if uint32(bytes, 5) ~= 2 then
            error(("tecs: %s is not glTF 2.0"):format(path), 0)
        end
        local jsonText: string = nil
        local binary: string = nil
        local at = 13
        while at + 7 <= #bytes do
            local length <const> = uint32(bytes, at)
            local kind <const> = uint32(bytes, at + 4)
            local body <const> = bytes:sub(at + 8, at + 7 + length)
            if kind == 0x4e4f534a then
                jsonText = body:gsub("[%z ]+$", "")
            elseif kind == 0x004e4942 then
                binary = body
            end
            at = at + 8 + length
        end
        if jsonText == nil then
            error(("tecs: %s has no GLB JSON chunk"):format(path), 0)
        end
        return data.decodeJSON(jsonText) as {string: any}, binary
    end
    return data.decodeJSON(bytes) as {string: any}, nil
end

local function component(pointer: loader.BytePointer, offset: integer, kind: integer, normalized: boolean): number
    local at <const> = pointer + offset
    if kind == 5126 then
        return (ffi.cast("const float *", at) as loader.CArray)[0] as number
    elseif kind == 5125 then
        return tonumber((ffi.cast("const uint32_t *", at) as loader.CArray)[0])
    elseif kind == 5123 then
        local value <const> = tonumber((ffi.cast("const uint16_t *", at) as loader.CArray)[0])
        return normalized and value / 65535.0 or value
    elseif kind == 5122 then
        local value <const> = tonumber((ffi.cast("const int16_t *", at) as loader.CArray)[0])
        return normalized and math.max(value / 32767.0, -1.0) or value
    elseif kind == 5121 then
        local value <const> = tonumber((ffi.cast("const uint8_t *", at) as loader.CArray)[0])
        return normalized and value / 255.0 or value
    end
    local value <const> = tonumber((ffi.cast("const int8_t *", at) as loader.CArray)[0])
    return normalized and math.max(value / 127.0, -1.0) or value
end

local record Access
    pointer: loader.BytePointer
    offset: integer
    stride: integer
    componentBytes: integer
    componentType: integer
    components: integer
    count: integer
    normalized: boolean
end

local function accessor(document: {string: any}, buffers: {string}, index: integer): Access
    local sources = document.accessors as {{string: any}}
    local source = sources ~= nil and sources[index + 1] or nil
    if source == nil or source.bufferView == nil then
        error("tecs: sparse or missing-buffer glTF accessors are not supported", 0)
    end
    if source.sparse ~= nil then
        error("tecs: sparse glTF accessors are not supported", 0)
    end
    local views = document.bufferViews as {{string: any}}
    local view = views ~= nil and views[(source.bufferView as integer) + 1] or nil
    if view == nil then
        error("tecs: glTF accessor names a missing buffer view", 0)
    end
    local bytes <const> = buffers[(view.buffer as integer) + 1]
    local kind <const> = source.componentType as integer
    local width = COMPONENT_BYTES[kind]
    local components = TYPE_COUNT[source.type as string]
    if bytes == nil or width == nil or components == nil then
        error("tecs: glTF accessor has an unsupported type", 0)
    end
    local viewOffset <const> = view.byteOffset as integer or 0
    local viewLength <const> = view.byteLength as integer
    local sourceOffset <const> = source.byteOffset as integer or 0
    local stride <const> = view.byteStride as integer or width * components
    local count <const> = source.count as integer
    local packed <const> = width * components
    if viewLength == nil or viewOffset < 0 or viewLength < 0 or viewOffset + viewLength > #bytes then
        error("tecs: glTF buffer view is outside its buffer", 0)
    end
    if sourceOffset < 0 or count == nil or count < 0 or stride < packed or stride % width ~= 0 then
        error("tecs: glTF accessor has an invalid range or stride", 0)
    end
    local endOffset <const> = sourceOffset + (count > 0 and (count - 1) * stride + packed or 0)
    if endOffset > viewLength or (viewOffset + sourceOffset) % width ~= 0 then
        error("tecs: glTF accessor is outside or misaligned in its buffer view", 0)
    end
    return {
        pointer = loader.bytePointer(ffi.cast("const uint8_t *", bytes) as loader.CValue),
        offset = viewOffset + sourceOffset,
        stride = stride,
        componentBytes = width,
        componentType = kind,
        components = components,
        count = count,
        normalized = source.normalized == true,
    }
end

local function sameRows(access: Access, components: integer, count: integer, name: string)
    if access.components ~= components or access.count ~= count then
        error(("tecs: %s has the wrong shape or vertex count"):format(name), 0)
    end
end

local function add3(values: loader.CArray, row: integer, x: number, y: number, z: number)
    local at <const> = row * 3
    values[at] = (values[at] as number) + x
    values[at + 1] = (values[at + 1] as number) + y
    values[at + 2] = (values[at + 2] as number) + z
end

local function value(access: Access, row: integer, lane: integer): number
    return component(
        access.pointer,
        access.offset + row * access.stride + lane * access.componentBytes,
        access.componentType,
        access.normalized
    )
end

local function finite(item: number): boolean
    return item ~= nil and item == item and item ~= math.huge and item ~= -math.huge
end

local function decodeAnimations(
    document: {string: any}, buffers: {string}, nodes: {{string: any}}, path: string
): {{string: any}}
    local animations: {{string: any}} = {}
    for animationIndex, source in ipairs(document.animations as {{string: any}} or {}) do
        local samplers <const> = source.samplers as {{string: any}} or {}
        local channels <const> = source.channels as {{string: any}} or {}
        if #channels == 0 then
            error(("tecs: %s animation %d has no channels"):format(path, animationIndex - 1), 0)
        end
        local decoded: {{string: any}} = {}
        local duration = 0.0
        local targets: {string: boolean} = {}
        for channelIndex, channel in ipairs(channels) do
            local samplerIndex <const> = channel.sampler as integer
            local sampler = samplerIndex ~= nil and samplers[samplerIndex + 1] or nil
            if sampler == nil or sampler.input == nil or sampler.output == nil then
                error(
                    ("tecs: %s animation %d channel %d names a missing sampler"):format(
                        path, animationIndex - 1, channelIndex - 1
                    ),
                    0
                )
            end
            local target <const> = channel.target as {string: any}
            local nodeIndex <const> = target ~= nil and target.node as integer or nil
            local targetPath <const> = target ~= nil and target.path as string or nil
            local pathCode: integer
            local components: integer
            if targetPath == "translation" then
                pathCode, components = 0, 3
            elseif targetPath == "rotation" then
                pathCode, components = 1, 4
            elseif targetPath == "scale" then
                pathCode, components = 2, 3
            elseif targetPath == "weights" then
                pathCode = 3
                local targetNode <const> = nodeIndex ~= nil and nodes[nodeIndex + 1] or nil
                local mesh = targetNode ~= nil and targetNode.mesh as integer or nil
                local sourceMesh = mesh ~= nil and (document.meshes as {{string: any}} or {})[mesh + 1] or nil
                if sourceMesh == nil then
                    error(("tecs: %s morph-weight animation targets a node without a mesh"):format(path), 0)
                end
                for _, primitive in ipairs(sourceMesh.primitives as {{string: any}} or {}) do
                    local targetCount <const> = #(primitive.targets as {{string: integer}} or {})
                    if components == nil then
                        components = targetCount
                    elseif components ~= targetCount then
                        error(("tecs: %s morph-weight animation targets inconsistent primitives"):format(path), 0)
                    end
                end
                if components == nil or components == 0 then
                    error(("tecs: %s morph-weight animation targets a mesh without morph targets"):format(path), 0)
                end
            else
                error(
                    ("tecs: %s animation %d channel %d has an unsupported target"):format(
                        path, animationIndex - 1, channelIndex - 1
                    ),
                    0
                )
            end
            local node = nodeIndex ~= nil and nodes[nodeIndex + 1] or nil
            if node == nil then
                error(
                    ("tecs: %s animation %d channel %d names a missing node"):format(
                        path, animationIndex - 1, channelIndex - 1
                    ),
                    0
                )
            end
            if node.matrix ~= nil and pathCode ~= 3 then
                error(("tecs: %s animates node %d, which uses a fixed matrix"):format(path, nodeIndex), 0)
            end
            local targetKey <const> = tostring(nodeIndex) .. ":" .. tostring(pathCode)
            if targets[targetKey] then
                error(
                    ("tecs: %s animation %d targets one node path more than once"):format(path, animationIndex - 1), 0
                )
            end
            targets[targetKey] = true

            local interpolationName <const> = sampler.interpolation as string or "LINEAR"
            local interpolation: integer
            if interpolationName == "LINEAR" then
                interpolation = 0
            elseif interpolationName == "STEP" then
                interpolation = 1
            elseif interpolationName == "CUBICSPLINE" then
                interpolation = 2
            else
                error(
                    ("tecs: %s animation %d uses interpolation %s"):format(
                        path, animationIndex - 1, tostring(interpolationName)
                    ),
                    0
                )
            end
            local input <const> = accessor(document, buffers, sampler.input as integer)
            local output <const> = accessor(document, buffers, sampler.output as integer)
            if input.components ~= 1 or input.componentType ~= 5126 or input.normalized or input.count == 0 then
                error(
                    ("tecs: %s animation %d key times are not non-empty float scalars"):format(
                        path, animationIndex - 1
                    ),
                    0
                )
            end
            local outputRows <const> = input.count * (interpolation == 2 and 3 or 1)
            local outputShape <const> = pathCode == 3
                and output.components == 1
                and output.count == outputRows * components or output.components == components
                and output.count == outputRows
            if not outputShape or output.componentType ~= 5126 or output.normalized then
                error(
                    ("tecs: %s animation %d channel %d has the wrong output shape"):format(
                        path, animationIndex - 1, channelIndex - 1
                    ),
                    0
                )
            end
            local times: {number} = {}
            local values: {number} = {}
            local previous = -math.huge
            for row = 0, input.count - 1 do
                local time <const> = value(input, row, 0)
                if not finite(time) or time < 0 or time <= previous then
                    error(
                        ("tecs: %s animation %d key times are not finite and increasing"):format(
                            path, animationIndex - 1
                        ),
                        0
                    )
                end
                times[row + 1] = time
                previous = time
                duration = math.max(duration, time)
            end
            for row = 0, output.count - 1 do
                for lane = 0, output.components - 1 do
                    local item <const> = value(output, row, lane)
                    if not finite(item) then
                        error(("tecs: %s animation %d contains a non-finite value"):format(path, animationIndex - 1), 0)
                    end
                    values[#values + 1] = item
                end
            end
            decoded[#decoded + 1] = {
                node = nodeIndex + 1,
                path = pathCode,
                interpolation = interpolation,
                width = components,
                times = times,
                values = values,
            }
        end
        animations[#animations + 1] = {
            name = source.name as string or ("animation-%d"):format(animationIndex - 1),
            duration = duration,
            channels = decoded,
        }
    end
    return animations
end

local function normalize3(x: number, y: number, z: number): number, number, number
    local length <const> = math.sqrt(x * x + y * y + z * z)
    if length <= 1e-20 then
        return 0, 0, 1
    end
    return x / length, y / length, z / length
end

local function decodePrimitive(
    document: {string: any}, buffers: {string}, primitive: {string: any}, name: string, defaultWeights: {number}
): {string: any}
    if primitive.mode ~= nil and primitive.mode ~= 4 then
        error(("tecs: %s is not a triangle primitive"):format(name), 0)
    end
    local attributes = primitive.attributes as {string: integer}
    if attributes == nil or attributes.POSITION == nil then
        error(("tecs: %s has no POSITION attribute"):format(name), 0)
    end
    if attributes.COLOR_0 ~= nil then
        error(("tecs: %s uses unsupported vertex attributes"):format(name), 0)
    end
    if (attributes.JOINTS_0 == nil) ~= (attributes.WEIGHTS_0 == nil) then
        error(("tecs: %s must supply JOINTS_0 and WEIGHTS_0 together"):format(name), 0)
    end
    local positions <const> = accessor(document, buffers, attributes.POSITION)
    if positions.components ~= 3 then
        error(("tecs: %s POSITION is not VEC3"):format(name), 0)
    end
    local normals: Access = nil
    local tangents: Access = nil
    local uvs: Access = nil
    local joints: Access = nil
    local weights: Access = nil
    local morphTargets: {{string: Access}} = {}
    if attributes.NORMAL ~= nil then
        normals = accessor(document, buffers, attributes.NORMAL)
        sameRows(normals, 3, positions.count, name .. " NORMAL")
    end
    if attributes.TANGENT ~= nil then
        tangents = accessor(document, buffers, attributes.TANGENT)
        sameRows(tangents, 4, positions.count, name .. " TANGENT")
    end
    if attributes.TEXCOORD_0 ~= nil then
        uvs = accessor(document, buffers, attributes.TEXCOORD_0)
        sameRows(uvs, 2, positions.count, name .. " TEXCOORD_0")
    end
    if attributes.JOINTS_0 ~= nil then
        joints = accessor(document, buffers, attributes.JOINTS_0)
        weights = accessor(document, buffers, attributes.WEIGHTS_0)
        sameRows(joints, 4, positions.count, name .. " JOINTS_0")
        sameRows(weights, 4, positions.count, name .. " WEIGHTS_0")
        if joints.normalized or (joints.componentType ~= 5121 and joints.componentType ~= 5123) then
            error(("tecs: %s JOINTS_0 does not use an unsigned integer type"):format(name), 0)
        end
        if
            weights.componentType ~= 5126
            and not (weights.normalized and (weights.componentType == 5121 or weights.componentType == 5123))
        then
            error(("tecs: %s WEIGHTS_0 does not use float or normalized unsigned values"):format(name), 0)
        end
    end
    for targetIndex, target in ipairs(primitive.targets as {{string: integer}} or {}) do
        for semantic in pairs(target) do
            if semantic ~= "POSITION" and semantic ~= "NORMAL" and semantic ~= "TANGENT" then
                error(
                    ("tecs: %s morph target %d uses unsupported %s deltas"):format(name, targetIndex - 1, semantic), 0
                )
            end
        end
        local decoded: {string: Access} = {}
        for _, semantic in ipairs({"POSITION", "NORMAL", "TANGENT"}) do
            local index <const> = target[semantic]
            if index ~= nil then
                local source <const> = accessor(document, buffers, index)
                sameRows(source, 3, positions.count, name .. " morph " .. semantic)
                if source.componentType ~= 5126 or source.normalized then
                    error(("tecs: %s morph target %d %s is not float VEC3"):format(name, targetIndex - 1, semantic), 0)
                end
                decoded[semantic] = source
            end
        end
        if decoded.POSITION == nil and decoded.NORMAL == nil and decoded.TANGENT == nil then
            error(("tecs: %s morph target %d is empty"):format(name, targetIndex - 1), 0)
        end
        morphTargets[targetIndex] = decoded
    end
    if #defaultWeights ~= 0 and #defaultWeights ~= #morphTargets then
        error(("tecs: %s mesh weights do not match its morph targets"):format(name), 0)
    end
    if primitive.material ~= nil then
        local material = (document.materials as {{string: any}} or {})[(primitive.material as integer) + 1]
        if material == nil then
            error(("tecs: %s names a missing material"):format(name), 0)
        end
        local pbr <const> = material.pbrMetallicRoughness as {string: any} or {}
        local textured <const> = pbr.baseColorTexture ~= nil
            or pbr.metallicRoughnessTexture ~= nil
            or material.normalTexture ~= nil
            or material.occlusionTexture ~= nil
            or material.emissiveTexture ~= nil
        if textured and uvs == nil then
            error(("tecs: %s uses a texture without TEXCOORD_0"):format(name), 0)
        end
    end

    local indices: loader.CArray
    local indexCount: integer
    if primitive.indices == nil then
        indexCount = positions.count
        indices = ffi.new("uint32_t[?]", indexCount) as loader.CArray
        for index = 0, indexCount - 1 do
            indices[index] = index
        end
    else
        local source <const> = accessor(document, buffers, primitive.indices as integer)
        if source.components ~= 1 then
            error(("tecs: %s indices are not scalar"):format(name), 0)
        end
        if
            source.normalized
            or (source.componentType ~= 5121 and source.componentType ~= 5123 and source.componentType ~= 5125)
        then
            error(("tecs: %s indices do not use an unsigned integer type"):format(name), 0)
        end
        indexCount = source.count
        indices = ffi.new("uint32_t[?]", indexCount) as loader.CArray
        for index = 0, indexCount - 1 do
            local vertex <const> = value(source, index, 0)
            if vertex < 0 or vertex >= positions.count or vertex ~= math.floor(vertex) then
                error(("tecs: %s index %d is outside its vertex range"):format(name, index), 0)
            end
            indices[index] = vertex
        end
    end
    if indexCount == 0 or indexCount % 3 ~= 0 then
        error(("tecs: %s has a non-triangle index count"):format(name), 0)
    end

    local vertices <const> = ffi.new("float[?]", positions.count * 12) as loader.CArray
    local skinVertices: loader.CArray = nil
    local morphVertices: loader.CArray = nil
    local maxJoint = -1
    if joints ~= nil then
        skinVertices = ffi.new("float[?]", positions.count * 8) as loader.CArray
        for row = 0, positions.count - 1 do
            local at <const> = row * 8
            local total = 0.0
            for lane = 0, 3 do
                local joint <const> = value(joints, row, lane)
                local weight <const> = value(weights, row, lane)
                if joint < 0 or joint ~= math.floor(joint) or weight < 0 then
                    error(("tecs: %s has invalid joint data at vertex %d"):format(name, row), 0)
                end
                skinVertices[at + lane] = joint
                skinVertices[at + 4 + lane] = weight
                maxJoint = math.floor(math.max(maxJoint, joint))
                total = total + weight
            end
            if total <= 1e-20 then
                error(("tecs: %s has zero joint weight at vertex %d"):format(name, row), 0)
            end
            for lane = 0, 3 do
                skinVertices[at + 4 + lane] = (skinVertices[at + 4 + lane] as number) / total
            end
        end
    end
    local morphRadius = 0.0
    if #morphTargets > 0 then
        morphVertices = ffi.new("float[?]", positions.count * #morphTargets * 9) as loader.CArray
        for row = 0, positions.count - 1 do
            local displacement = 0.0
            for targetIndex, target in ipairs(morphTargets) do
                local destination <const> = ((targetIndex - 1) * positions.count + row) * 9
                for lane = 0, 2 do
                    morphVertices[destination + lane] = target.POSITION ~= nil and value(target.POSITION, row, lane)
                        or 0
                    morphVertices[destination + 3 + lane] = target.NORMAL ~= nil and value(target.NORMAL, row, lane)
                        or 0
                    morphVertices[destination + 6 + lane] = target.TANGENT ~= nil and value(target.TANGENT, row, lane)
                        or 0
                end
                local dx, dy, dz <const> = morphVertices[destination] as number,
                    morphVertices[destination + 1] as number,
                    morphVertices[destination + 2] as number
                displacement = displacement + math.sqrt(dx * dx + dy * dy + dz * dz)
            end
            morphRadius = math.max(morphRadius, displacement)
        end
    end
    local generatedNormals: loader.CArray = nil
    if normals == nil then
        generatedNormals = ffi.new("float[?]", positions.count * 3) as loader.CArray
        for triangle = 0, indexCount - 1, 3 do
            local a <const> = tonumber(indices[triangle]) as integer
            local b <const> = tonumber(indices[triangle + 1]) as integer
            local c <const> = tonumber(indices[triangle + 2]) as integer
            local ax, ay, az <const> = value(positions, a, 0), value(positions, a, 1), value(positions, a, 2)
            local bx, by, bz <const> = value(positions, b, 0), value(positions, b, 1), value(positions, b, 2)
            local cx, cy, cz <const> = value(positions, c, 0), value(positions, c, 1), value(positions, c, 2)
            local abx, aby, abz <const> = bx - ax, by - ay, bz - az
            local acx, acy, acz <const> = cx - ax, cy - ay, cz - az
            local nx, ny, nz <const> = aby * acz - abz * acy, abz * acx - abx * acz, abx * acy - aby * acx
            add3(generatedNormals, a, nx, ny, nz)
            add3(generatedNormals, b, nx, ny, nz)
            add3(generatedNormals, c, nx, ny, nz)
        end
    end

    local minX, minY, minZ = math.huge, math.huge, math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    for row = 0, positions.count - 1 do
        local at <const> = row * 12
        local x, y, z <const> = value(positions, row, 0), value(positions, row, 1), value(positions, row, 2)
        vertices[at], vertices[at + 1], vertices[at + 2] = x, y, z
        minX, minY, minZ = math.min(minX, x), math.min(minY, y), math.min(minZ, z)
        maxX, maxY, maxZ = math.max(maxX, x), math.max(maxY, y), math.max(maxZ, z)
        local nx: number = 0.0
        local ny: number = 0.0
        local nz: number = 0.0
        if normals ~= nil then
            nx, ny, nz = normalize3(value(normals, row, 0), value(normals, row, 1), value(normals, row, 2))
        else
            nx, ny, nz = normalize3(
                generatedNormals[row * 3] as number,
                generatedNormals[row * 3 + 1] as number,
                generatedNormals[row * 3 + 2] as number
            )
        end
        vertices[at + 3], vertices[at + 4], vertices[at + 5] = nx, ny, nz
        vertices[at + 10] = uvs ~= nil and value(uvs, row, 0) or 0
        vertices[at + 11] = uvs ~= nil and value(uvs, row, 1) or 0
    end

    local generatedTangents: loader.CArray = nil
    local generatedBitangents: loader.CArray = nil
    if tangents == nil and uvs ~= nil then
        generatedTangents = ffi.new("float[?]", positions.count * 3) as loader.CArray
        generatedBitangents = ffi.new("float[?]", positions.count * 3) as loader.CArray
        for triangle = 0, indexCount - 1, 3 do
            local a <const> = tonumber(indices[triangle]) as integer
            local b <const> = tonumber(indices[triangle + 1]) as integer
            local c <const> = tonumber(indices[triangle + 2]) as integer
            local aa, ba, ca <const> = a * 12, b * 12, c * 12
            local x1 <const> = (vertices[ba] as number) - (vertices[aa] as number)
            local y1 <const> = (vertices[ba + 1] as number) - (vertices[aa + 1] as number)
            local z1 <const> = (vertices[ba + 2] as number) - (vertices[aa + 2] as number)
            local x2 <const> = (vertices[ca] as number) - (vertices[aa] as number)
            local y2 <const> = (vertices[ca + 1] as number) - (vertices[aa + 1] as number)
            local z2 <const> = (vertices[ca + 2] as number) - (vertices[aa + 2] as number)
            local du1 <const> = (vertices[ba + 10] as number) - (vertices[aa + 10] as number)
            local dv1 <const> = (vertices[ba + 11] as number) - (vertices[aa + 11] as number)
            local du2 <const> = (vertices[ca + 10] as number) - (vertices[aa + 10] as number)
            local dv2 <const> = (vertices[ca + 11] as number) - (vertices[aa + 11] as number)
            local determinant <const> = du1 * dv2 - dv1 * du2
            if math.abs(determinant) > 1e-20 then
                local inverse <const> = 1.0 / determinant
                local tx, ty, tz <const> = (x1 * dv2 - x2 * dv1) * inverse,
                    (y1 * dv2 - y2 * dv1) * inverse,
                    (z1 * dv2 - z2 * dv1) * inverse
                local bx, by, bz <const> = (x2 * du1 - x1 * du2) * inverse,
                    (y2 * du1 - y1 * du2) * inverse,
                    (z2 * du1 - z1 * du2) * inverse
                add3(generatedTangents, a, tx, ty, tz)
                add3(generatedTangents, b, tx, ty, tz)
                add3(generatedTangents, c, tx, ty, tz)
                add3(generatedBitangents, a, bx, by, bz)
                add3(generatedBitangents, b, bx, by, bz)
                add3(generatedBitangents, c, bx, by, bz)
            end
        end
    end
    for row = 0, positions.count - 1 do
        local at <const> = row * 12
        if tangents ~= nil then
            vertices[at + 6], vertices[at + 7] = value(tangents, row, 0), value(tangents, row, 1)
            vertices[at + 8], vertices[at + 9] = value(tangents, row, 2), value(tangents, row, 3)
        else
            local nx, ny, nz <const> = vertices[at + 3] as number,
                vertices[at + 4] as number,
                vertices[at + 5] as number
            local tx, ty, tz = nz, 0.0, -nx
            local handedness = 1.0
            if generatedTangents ~= nil then
                tx, ty, tz = generatedTangents[row * 3] as number,
                    generatedTangents[row * 3 + 1] as number,
                    generatedTangents[row * 3 + 2] as number
                local projection <const> = nx * tx + ny * ty + nz * tz
                tx, ty, tz = tx - nx * projection, ty - ny * projection, tz - nz * projection
            end
            if math.abs(tx) + math.abs(ty) + math.abs(tz) < 1e-20 then
                tx, ty, tz = math.abs(nx) < 0.9 and 0 or 1,
                    math.abs(nx) < 0.9 and nz or 0,
                    math.abs(nx) < 0.9 and -ny or 0
            end
            tx, ty, tz = normalize3(tx, ty, tz)
            if generatedBitangents ~= nil then
                local bx <const> = generatedBitangents[row * 3] as number
                local by <const> = generatedBitangents[row * 3 + 1] as number
                local bz <const> = generatedBitangents[row * 3 + 2] as number
                handedness = (ny * tz - nz * ty) * bx + (nz * tx - nx * tz) * by + (nx * ty - ny * tx) * bz < 0 and -1
                    or 1
            end
            vertices[at + 6], vertices[at + 7], vertices[at + 8], vertices[at + 9] = tx, ty, tz, handedness
        end
    end
    local centerX, centerY, centerZ <const> = (minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5
    local radiusSquared = 0.0
    for row = 0, positions.count - 1 do
        local at <const> = row * 12
        local dx <const> = (vertices[at] as number) - centerX
        local dy <const> = (vertices[at + 1] as number) - centerY
        local dz <const> = (vertices[at + 2] as number) - centerZ
        radiusSquared = math.max(radiusSquared, dx * dx + dy * dy + dz * dz)
    end
    return {
        name = name,
        vertices = ffi.string(vertices as string, positions.count * 48),
        indices = ffi.string(indices as string, indexCount * 4),
        skinVertices = skinVertices ~= nil and ffi.string(skinVertices as string, positions.count * 32) or nil,
        morphVertices = morphVertices ~= nil
            and ffi.string(morphVertices as string, positions.count * #morphTargets * 36) or nil,
        morphTargetCount = #morphTargets,
        morphWeights = defaultWeights,
        vertexCount = positions.count,
        indexCount = indexCount,
        centerX = centerX,
        centerY = centerY,
        centerZ = centerZ,
        radius = math.sqrt(radiusSquared) + morphRadius,
        material = primitive.material ~= nil and (primitive.material as integer) + 1 or 0,
        maxJoint = maxJoint,
    }
end

local function identity(): {number}
    return {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
end

local function localMatrix(node: {string: any}): {number}
    if node.matrix ~= nil then
        return node.matrix as {number}
    end
    local t <const> = node.translation as {number} or {0, 0, 0}
    local r <const> = node.rotation as {number} or {0, 0, 0, 1}
    local s <const> = node.scale as {number} or {1, 1, 1}
    local x, y, z, w <const> = r[1], r[2], r[3], r[4]
    local xx, yy, zz <const> = x * x, y * y, z * z
    local xy, xz, yz <const> = x * y, x * z, y * z
    local wx, wy, wz <const> = w * x, w * y, w * z
    return {
        (1 - 2 * (yy + zz)) * s[1],
        (2 * (xy + wz)) * s[1],
        (2 * (xz - wy)) * s[1],
        0,
        (2 * (xy - wz)) * s[2],
        (1 - 2 * (xx + zz)) * s[2],
        (2 * (yz + wx)) * s[2],
        0,
        (2 * (xz + wy)) * s[3],
        (2 * (yz - wx)) * s[3],
        (1 - 2 * (xx + yy)) * s[3],
        0,
        t[1],
        t[2],
        t[3],
        1,
    }
end

local function multiply(a: {number}, b: {number}): {number}
    local result: {number} = {}
    for column = 0, 3 do
        for row = 0, 3 do
            local sum = 0.0
            for lane = 0, 3 do
                sum = sum + a[lane * 4 + row + 1] * b[column * 4 + lane + 1]
            end
            result[column * 4 + row + 1] = sum
        end
    end
    return result
end

local function inverseAffine(m: {number}): {number}
    local a00, a01, a02 <const> = m[1], m[5], m[9]
    local a10, a11, a12 <const> = m[2], m[6], m[10]
    local a20, a21, a22 <const> = m[3], m[7], m[11]
    local determinant <const> = a00 * (a11 * a22 - a12 * a21) - a01 * (a10 * a22 - a12 * a20) + a02 * (
        a10 * a21 - a11 * a20
    )
    if math.abs(determinant) <= 1e-20 then
        error("tecs: a glTF skin uses a non-invertible mesh transform", 0)
    end
    local d <const> = 1.0 / determinant
    local i00, i01, i02 <const> = (a11 * a22 - a12 * a21) * d, (a02 * a21 - a01 * a22) * d, (a01 * a12 - a02 * a11) * d
    local i10, i11, i12 <const> = (a12 * a20 - a10 * a22) * d, (a00 * a22 - a02 * a20) * d, (a02 * a10 - a00 * a12) * d
    local i20, i21, i22 <const> = (a10 * a21 - a11 * a20) * d, (a01 * a20 - a00 * a21) * d, (a00 * a11 - a01 * a10) * d
    local tx, ty, tz <const> = m[13], m[14], m[15]
    return {
        i00,
        i10,
        i20,
        0,
        i01,
        i11,
        i21,
        0,
        i02,
        i12,
        i22,
        0,
        -(i00 * tx + i01 * ty + i02 * tz),
        -(i10 * tx + i11 * ty + i12 * tz),
        -(i20 * tx + i21 * ty + i22 * tz),
        1,
    }
end

local function decompose(m: {number}): {string: number}
    local sx = math.sqrt(m[1] * m[1] + m[2] * m[2] + m[3] * m[3])
    local sy <const> = math.sqrt(m[5] * m[5] + m[6] * m[6] + m[7] * m[7])
    local sz <const> = math.sqrt(m[9] * m[9] + m[10] * m[10] + m[11] * m[11])
    if sx <= 1e-20 or sy <= 1e-20 or sz <= 1e-20 then
        error("tecs: a glTF node transform has a zero scale axis", 0)
    end
    local determinant <const> = m[1] * (m[6] * m[11] - m[7] * m[10]) - m[5] * (m[2] * m[11] - m[3] * m[10]) + m[9] * (
        m[2] * m[7] - m[3] * m[6]
    )
    if determinant < 0 then
        sx = -sx
    end
    local r00, r01, r02 <const> = m[1] / sx, m[5] / sy, m[9] / sz
    local r10, r11, r12 <const> = m[2] / sx, m[6] / sy, m[10] / sz
    local r20, r21, r22 <const> = m[3] / sx, m[7] / sy, m[11] / sz
    if
        math.abs(r00 * r01 + r10 * r11 + r20 * r21) > 1e-4
        or math.abs(r00 * r02 + r10 * r12 + r20 * r22) > 1e-4
        or math.abs(r01 * r02 + r11 * r12 + r21 * r22) > 1e-4
    then
        error("tecs: a glTF node hierarchy produces shear that Transform3D cannot represent", 0)
    end
    local qx: number = 0.0
    local qy: number = 0.0
    local qz: number = 0.0
    local qw: number = 1.0
    local trace <const> = r00 + r11 + r22
    if trace > 0 then
        local scale <const> = math.sqrt(trace + 1.0) * 2
        qw, qx, qy, qz = 0.25 * scale, (r21 - r12) / scale, (r02 - r20) / scale, (r10 - r01) / scale
    elseif r00 > r11 and r00 > r22 then
        local scale <const> = math.sqrt(1.0 + r00 - r11 - r22) * 2
        qw, qx, qy, qz = (r21 - r12) / scale, 0.25 * scale, (r01 + r10) / scale, (r02 + r20) / scale
    elseif r11 > r22 then
        local scale <const> = math.sqrt(1.0 + r11 - r00 - r22) * 2
        qw, qx, qy, qz = (r02 - r20) / scale, (r01 + r10) / scale, 0.25 * scale, (r12 + r21) / scale
    else
        local scale <const> = math.sqrt(1.0 + r22 - r00 - r11) * 2
        qw, qx, qy, qz = (r10 - r01) / scale, (r02 + r20) / scale, (r12 + r21) / scale, 0.25 * scale
    end
    return {
        x = m[13],
        y = m[14],
        z = m[15],
        rotationX = qx,
        rotationY = qy,
        rotationZ = qz,
        rotationW = qw,
        scaleX = sx,
        scaleY = sy,
        scaleZ = sz,
    }
end

function gltf.decodeFile(path: string): {string: any}
    local bytes = files.read(path)
    if bytes == nil then
        error(("tecs: cannot read %s"):format(path), 0)
    end
    local document, binary = container(bytes, path)
    if (document.asset as {string: any}).version ~= "2.0" then
        error(("tecs: %s is not glTF 2.0"):format(path), 0)
    end
    for _, extension in ipairs(document.extensionsRequired as {string} or {}) do
        if extension ~= "KHR_materials_unlit" then
            error(("tecs: %s requires unsupported extension %s"):format(path, extension), 0)
        end
    end
    local base <const> = directory(path)
    local buffers: {string} = {}
    for index, source in ipairs(document.buffers as {{string: any}} or {}) do
        if source.uri ~= nil then
            buffers[index] = uriBytes(source.uri as string, base)
        elseif index == 1 and binary ~= nil then
            buffers[index] = binary
        else
            error(("tecs: %s buffer %d has no data"):format(path, index - 1), 0)
        end
        if source.byteLength == nil or (source.byteLength as integer) > #buffers[index] then
            error(("tecs: %s buffer %d is shorter than declared"):format(path, index - 1), 0)
        end
    end

    local images: {{string: any}} = {}
    for index, source in ipairs(document.images as {{string: any}} or {}) do
        local encoded: string
        if source.uri ~= nil then
            encoded = uriBytes(source.uri as string, base)
        elseif source.bufferView ~= nil then
            local view <const> = (document.bufferViews as {{string: any}} or {})[(source.bufferView as integer) + 1]
            if view == nil then
                error(("tecs: %s image %d names a missing buffer view"):format(path, index - 1), 0)
            end
            local start <const> = (view.byteOffset as integer or 0) + 1
            local buffer <const> = buffers[(view.buffer as integer) + 1]
            local length <const> = view.byteLength as integer
            if buffer == nil or length == nil or start < 1 or start + length - 1 > #buffer then
                error(("tecs: %s image %d is outside its buffer"):format(path, index - 1), 0)
            end
            encoded = buffer:sub(start, start + length - 1)
        else
            error(("tecs: %s image %d has no data"):format(path, index - 1), 0)
        end
        local label <const> = source.name as string
        images[index] = {
            name = path .. "#image-" .. (index - 1) .. (label ~= nil and (":" .. label) or ""),
            bytes = encoded,
        }
    end

    for index, texture in ipairs(document.textures as {{string: any}} or {}) do
        if texture.source == nil or images[(texture.source as integer) + 1] == nil then
            error(("tecs: %s texture %d names a missing image"):format(path, index - 1), 0)
        end
        if texture.sampler ~= nil then
            local sampler <const> = (document.samplers as {{string: any}} or {})[(texture.sampler as integer) + 1]
            if
                sampler == nil
                or (sampler.wrapS ~= nil and sampler.wrapS ~= 10497)
                or (sampler.wrapT ~= nil and sampler.wrapT ~= 10497)
                or (sampler.magFilter ~= nil and sampler.magFilter ~= 9729)
                or (sampler.minFilter ~= nil and sampler.minFilter ~= 9729)
            then
                error(("tecs: %s texture %d needs an unsupported sampler"):format(path, index - 1), 0)
            end
        end
    end

    local function textureImage(info: {string: any}): integer
        if info == nil then
            return 0
        end
        if info.texCoord ~= nil and info.texCoord ~= 0 or info.extensions ~= nil then
            error("tecs: glTF mesh materials support only untransformed TEXCOORD_0", 0)
        end
        local texture = (document.textures as {{string: any}} or {})[(info.index as integer) + 1]
        if texture == nil then
            error("tecs: glTF material names a missing texture", 0)
        end
        return (texture.source as integer) + 1
    end

    local materials: {{string: any}} = {}
    for index, source in ipairs(document.materials as {{string: any}} or {}) do
        if
            source.alphaMode ~= nil
            and source.alphaMode ~= "OPAQUE"
            and source.alphaMode ~= "MASK"
            and source.alphaMode ~= "BLEND"
        then
            error(
                ("tecs: %s material %d has invalid alpha mode %s"):format(path, index - 1, tostring(source.alphaMode)),
                0
            )
        end
        if source.doubleSided == true then
            error(("tecs: %s material %d needs unsupported double-sided rendering"):format(path, index - 1), 0)
        end
        if source.extensions ~= nil then
            for extension in pairs(source.extensions as {string: any}) do
                if extension ~= "KHR_materials_unlit" then
                    error(("tecs: %s material %d uses unsupported extension %s"):format(path, index - 1, extension), 0)
                end
            end
        end
        local pbr <const> = source.pbrMetallicRoughness as {string: any} or {}
        local baseFactor <const> = pbr.baseColorFactor as {number} or {1, 1, 1, 1}
        local emissive <const> = source.emissiveFactor as {number} or {0, 0, 0}
        materials[index] = {
            name = path
                .. "#material-"
                .. (index - 1)
                .. (source.name ~= nil and (":" .. (source.name as string)) or ""),
            model = source.extensions ~= nil and (source.extensions as {string: any}).KHR_materials_unlit ~= nil and 1
                or 0,
            alphaMode = source.alphaMode == "BLEND" and 2 or source.alphaMode == "MASK" and 1 or 0,
            baseColorImage = textureImage(pbr.baseColorTexture as {string: any}),
            normalImage = textureImage(source.normalTexture as {string: any}),
            metallicRoughnessImage = textureImage(pbr.metallicRoughnessTexture as {string: any}),
            occlusionImage = textureImage(source.occlusionTexture as {string: any}),
            emissiveImage = textureImage(source.emissiveTexture as {string: any}),
            alphaCutoff = source.alphaMode == "MASK" and (source.alphaCutoff as number or 0.5) or 0.0,
            baseR = baseFactor[1],
            baseG = baseFactor[2],
            baseB = baseFactor[3],
            baseA = baseFactor[4],
            emissiveR = emissive[1],
            emissiveG = emissive[2],
            emissiveB = emissive[3],
            metallic = pbr.metallicFactor as number or 1.0,
            roughness = pbr.roughnessFactor as number or 1.0,
            normalScale = source.normalTexture ~= nil
                and ((source.normalTexture as {string: any}).scale as number or 1.0) or 1.0,
            occlusionStrength = source.occlusionTexture ~= nil
                and ((source.occlusionTexture as {string: any}).strength as number or 1.0) or 1.0,
        }
    end

    local meshes: {{string: any}} = {}
    local byMesh: {integer: {integer}} = {}
    local weightsByMesh: {integer: {number}} = {}
    for meshIndex, source in ipairs(document.meshes as {{string: any}} or {}) do
        local primitiveIndices: {integer} = {}
        local defaultWeights: {number} = {}
        for index, weight in ipairs(source.weights as {number} or {}) do
            if not finite(weight) then
                error(("tecs: %s mesh %d has a non-finite morph weight"):format(path, meshIndex - 1), 0)
            end
            defaultWeights[index] = weight
        end
        for primitiveIndex, primitive in ipairs(source.primitives as {{string: any}}) do
            local name <const> = path .. "#mesh-" .. (meshIndex - 1) .. "-primitive-" .. (primitiveIndex - 1)
            meshes[#meshes + 1] = decodePrimitive(document, buffers, primitive, name, defaultWeights)
            primitiveIndices[#primitiveIndices + 1] = #meshes
        end
        byMesh[meshIndex] = primitiveIndices
        weightsByMesh[meshIndex] = defaultWeights
    end

    local draws: {{string: any}} = {}
    local skins: {{string: any}} = {}
    local nodes <const> = document.nodes as {{string: any}} or {}
    local parents: {integer: integer} = {}
    for parent, node in ipairs(nodes) do
        for _, child in ipairs(node.children as {integer} or {}) do
            if nodes[child + 1] == nil then
                error(("tecs: %s node names a missing child"):format(path), 0)
            end
            if parents[child] ~= nil then
                error(("tecs: %s node %d has more than one parent"):format(path, child), 0)
            end
            parents[child] = parent - 1
        end
    end

    local modelNodes: {{string: any}} = {}
    local function vector(source: any, count: integer, defaults: {number}, label: string): {number}
        local values <const> = source as {number} or defaults
        if #values ~= count then
            error(("tecs: %s node %s has the wrong shape"):format(path, label), 0)
        end
        local copy: {number} = {}
        for index = 1, count do
            local item <const> = values[index]
            if not finite(item) then
                error(("tecs: %s node %s contains a non-finite value"):format(path, label), 0)
            end
            copy[index] = item
        end
        return copy
    end
    for index, node in ipairs(nodes) do
        if node.matrix ~= nil and (node.translation ~= nil or node.rotation ~= nil or node.scale ~= nil) then
            error(("tecs: %s node %d combines matrix and TRS transforms"):format(path, index - 1), 0)
        end
        local translation <const> = vector(node.translation, 3, {0, 0, 0}, ("%d translation"):format(index - 1))
        local rotation <const> = vector(node.rotation, 4, {0, 0, 0, 1}, ("%d rotation"):format(index - 1))
        local scale <const> = vector(node.scale, 3, {1, 1, 1}, ("%d scale"):format(index - 1))
        local length <const> = math.sqrt(
            rotation[1] * rotation[1] + rotation[2] * rotation[2] + rotation[3] * rotation[3] + rotation[4] * rotation[4]
        )
        if length <= 1e-20 then
            error(("tecs: %s node %d has a zero rotation quaternion"):format(path, index - 1), 0)
        end
        local matrix: {number} = nil
        if node.matrix ~= nil then
            matrix = vector(node.matrix, 16, {}, ("%d matrix"):format(index - 1))
        end
        local parent <const> = parents[index - 1]
        modelNodes[index] = {
            parent = parent ~= nil and parent + 1 or 0,
            x = translation[1],
            y = translation[2],
            z = translation[3],
            rotationX = rotation[1] / length,
            rotationY = rotation[2] / length,
            rotationZ = rotation[3] / length,
            rotationW = rotation[4] / length,
            scaleX = scale[1],
            scaleY = scale[2],
            scaleZ = scale[3],
            matrix = matrix,
        }
    end
    local animations <const> = decodeAnimations(document, buffers, nodes, path)

    local worlds: {integer: {number}} = {}
    local resolving: {integer: boolean} = {}
    local function worldOf(index: integer): {number}
        local existing = worlds[index]
        if existing ~= nil then
            return existing
        end
        local node = nodes[index + 1]
        if node == nil then
            error(("tecs: %s skin names a missing joint node"):format(path), 0)
        end
        if resolving[index] then
            error(("tecs: %s has a cycle in its node hierarchy"):format(path), 0)
        end
        resolving[index] = true
        local parent = parents[index]
        existing = multiply(parent ~= nil and worldOf(parent) or identity(), localMatrix(node))
        resolving[index] = nil
        worlds[index] = existing
        return existing
    end
    for index = 0, #nodes - 1 do
        worldOf(index)
    end

    local skinByNode: {integer: integer} = {}
    local skinSources <const> = document.skins as {{string: any}} or {}
    local function skinFor(nodeIndex: integer, skinIndex: integer, meshWorld: {number}): integer
        local existing = skinByNode[nodeIndex]
        if existing ~= nil then
            return existing
        end
        local source = skinSources[skinIndex + 1]
        if source == nil then
            error(("tecs: %s node names a missing skin"):format(path), 0)
        end
        local joints <const> = source.joints as {integer} or {}
        if #joints == 0 then
            error(("tecs: %s skin %d has no joints"):format(path, skinIndex), 0)
        end
        local inverseBinds: Access = nil
        if source.inverseBindMatrices ~= nil then
            inverseBinds = accessor(document, buffers, source.inverseBindMatrices as integer)
            sameRows(inverseBinds, 16, #joints, ("skin %d inverse bind matrices"):format(skinIndex))
            if inverseBinds.componentType ~= 5126 or inverseBinds.normalized then
                error(("tecs: %s skin %d inverse bind matrices are not float MAT4 values"):format(path, skinIndex), 0)
            end
        end
        local inverseMesh <const> = inverseAffine(meshWorld)
        local matrices: {number} = {}
        local inverseBindMatrices: {number} = {}
        local modelJoints: {integer} = {}
        for jointIndex, jointNode in ipairs(joints) do
            local inverseBind = identity()
            if inverseBinds ~= nil then
                for lane = 0, 15 do
                    inverseBind[lane + 1] = value(inverseBinds, jointIndex - 1, lane)
                end
            end
            modelJoints[jointIndex] = jointNode + 1
            for lane = 1, 16 do
                inverseBindMatrices[#inverseBindMatrices + 1] = inverseBind[lane]
            end
            local matrix <const> = multiply(multiply(inverseMesh, worldOf(jointNode)), inverseBind)
            for lane = 1, 16 do
                matrices[#matrices + 1] = matrix[lane]
            end
        end
        skins[#skins + 1] = {
            name = path .. "#skin-" .. skinIndex .. "-node-" .. nodeIndex,
            matrices = matrices,
            node = nodeIndex + 1,
            joints = modelJoints,
            inverseBindMatrices = inverseBindMatrices,
        }
        skinByNode[nodeIndex] = #skins
        return #skins
    end

    local visiting: {integer: boolean} = {}
    local function visit(index: integer)
        local node <const> = nodes[index + 1]
        if node == nil then
            error(("tecs: %s scene names a missing node"):format(path), 0)
        end
        if visiting[index] then
            error(("tecs: %s has a cycle in its node hierarchy"):format(path), 0)
        end
        visiting[index] = true
        local world <const> = worldOf(index)
        if node.mesh ~= nil then
            local meshIndex <const> = (node.mesh as integer) + 1
            local nodeMeshes <const> = byMesh[meshIndex]
            if nodeMeshes == nil then
                error(("tecs: %s node names a missing mesh"):format(path), 0)
            end
            local skin = 0
            if node.skin ~= nil then
                skin = skinFor(index, node.skin as integer, world)
            end
            for _, mesh in ipairs(nodeMeshes) do
                local geometry <const> = meshes[mesh]
                if (geometry.skinVertices ~= nil) ~= (skin ~= 0) then
                    error(("tecs: %s node and mesh disagree about skinning"):format(path), 0)
                end
                if skin ~= 0 then
                    local jointCount <const> = #(skins[skin].matrices as {number}) / 16
                    if (geometry.maxJoint as integer) >= jointCount then
                        error(("tecs: %s mesh joint index exceeds skin %d"):format(path, node.skin as integer), 0)
                    end
                end
                local transform <const> = decompose(world) as {string: any}
                transform.mesh = mesh
                transform.material = geometry.material as number
                transform.skin = skin
                transform.node = index + 1
                local sourceWeights <const> = node.weights as {number} or weightsByMesh[meshIndex]
                local targetCount <const> = geometry.morphTargetCount as integer
                if #sourceWeights ~= 0 and #sourceWeights ~= targetCount then
                    error(("tecs: %s node %d weights do not match its morph targets"):format(path, index), 0)
                end
                local weights: {number} = {}
                for target = 1, targetCount do
                    local weight <const> = #sourceWeights == 0 and 0.0 or sourceWeights[target]
                    if not finite(weight) then
                        error(("tecs: %s node %d has a non-finite morph weight"):format(path, index), 0)
                    end
                    weights[target] = weight
                end
                transform.weights = weights
                draws[#draws + 1] = transform
            end
        end
        for _, child in ipairs(node.children as {integer} or {}) do
            visit(child)
        end
        visiting[index] = nil
    end
    local sceneIndex <const> = document.scene as integer or 0
    local scene <const> = (document.scenes as {{string: any}} or {})[sceneIndex + 1]
    if scene ~= nil then
        for _, node in ipairs(scene.nodes as {integer} or {}) do
            visit(node)
        end
    else
        local children: {integer: boolean} = {}
        for _, node in ipairs(nodes) do
            for _, child in ipairs(node.children as {integer} or {}) do
                children[child] = true
            end
        end
        for index = 0, #nodes - 1 do
            if not children[index] then
                visit(index)
            end
        end
    end
    return {
        path = path,
        meshes = meshes,
        images = images,
        materials = materials,
        skins = skins,
        nodes = modelNodes,
        animations = animations,
        draws = draws,
    }
end

return gltf
