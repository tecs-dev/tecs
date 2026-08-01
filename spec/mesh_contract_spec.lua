-- The mesh contract stays independent of the sprite lane. These specs hold
-- that seam without opening a GPU device or letting the sprite extractor
-- participate.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local assets = require("tecs.assets")
local loader = require("tecs.ffi.loader")
local components = require("tecs.components")
local Camera3D = require("tecs.gfx.Camera3D")
local MeshExtractor = require("tecs.internal.render.MeshExtractor")
local MeshFramePacket = require("tecs.internal.render.MeshFramePacket")
local frustum = require("tecs.internal.render.frustum")

local function triangle(name)
    return assets.newMesh({
        name = name,
        vertices = {
            0,
            0,
            0,
            0,
            0,
            1,
            1,
            0,
            0,
            1,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            1,
            1,
            0,
            0,
            1,
            1,
            0,
            0,
            1,
            0,
            0,
            0,
            1,
            1,
            0,
            0,
            1,
            0,
            1,
        },
        indices = { 0, 1, 2 },
    })
end

local function near(actual, expected, message)
    assert.is_true(
        math.abs(actual - expected) < 0.00001,
        (message or "values differ") .. (": expected %.8f, got %.8f"):format(expected, actual)
    )
end

local function clipPoint(matrix, x, y, z)
    return matrix[0] * x + matrix[4] * y + matrix[8] * z + matrix[12],
        matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13],
        matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14],
        matrix[3] * x + matrix[7] * y + matrix[11] * z + matrix[15]
end

describe("the 3D scene contract", function()
    describe("Transform3D", function()
        it("defaults to the identity transform", function()
            local transform = tecs.Transform3D()
            assert.are.equal(0, transform.x)
            assert.are.equal(0, transform.y)
            assert.are.equal(0, transform.z)
            assert.are.equal(0, transform.rotationX)
            assert.are.equal(0, transform.rotationY)
            assert.are.equal(0, transform.rotationZ)
            assert.are.equal(1, transform.rotationW)
            assert.are.equal(1, transform.scaleX)
            assert.are.equal(1, transform.scaleY)
            assert.are.equal(1, transform.scaleZ)
        end)

        it("constructs partial transforms by field name", function()
            local transform = tecs.Transform3D.new({ x = 4, rotationY = 0.5, rotationW = 0.5, scaleZ = 3 })
            assert.are.equal(4, transform.x)
            assert.are.equal(0.5, transform.rotationY)
            assert.are.equal(0.5, transform.rotationW)
            assert.are.equal(1, transform.scaleX)
            assert.are.equal(3, transform.scaleZ)
        end)

        it("is the one component at the root and on the ECS", function()
            assert.is_true(rawequal(tecs.Transform3D, tecs.ecs.Transform3D))
            assert.are.equal("Transform3D", tecs.Transform3D.componentName)
        end)
    end)

    describe("mesh components", function()
        it("interns one normalized identity for each asset name", function()
            local first = components.meshId("models//props/./crate.glb")
            local second = components.meshId("models/props/crate.glb")
            assert.are.equal(first, second)
            assert.are.equal("models/props/crate.glb", components.meshName(first))
            assert.is_nil(components.meshName(2147483647))
        end)

        it("rejects an empty mesh name", function()
            assert.has_error(function()
                components.meshId("")
            end, "tecs: a mesh name cannot be empty")
        end)

        it("keeps residency out of snapshots", function()
            local world = tecs.ecs.newWorld()
            local asset = components.meshId("models/ship.glb")
            local mesh = components.Mesh(asset, 17)
            local encoded = components.Mesh.serialize(mesh)
            assert.same({ mesh = "models/ship.glb" }, encoded)

            local restored = components.Mesh.deserialize(world, encoded)
            assert.are.equal(asset, restored.asset)
            assert.are.equal(-1, restored.slot)
        end)

        it("keeps mesh material identity separate from 2D materials", function()
            local world = tecs.ecs.newWorld()
            local asset = components.meshMaterialId("models//props/./crate.glb#paint")
            assert.are.equal("models/props/crate.glb#paint", components.meshMaterialName(asset))

            local encoded = components.MeshMaterial.serialize(components.MeshMaterial(asset, 9))
            assert.same({ meshMaterial = "models/props/crate.glb#paint" }, encoded)
            local restored = components.MeshMaterial.deserialize(world, encoded)
            assert.are.equal(asset, restored.asset)
            assert.are.equal(-1, restored.slot)
        end)

        it("uses a unit local sphere and rejects a negative radius", function()
            local bounds = components.Bounds3D()
            assert.are.equal(0, bounds.centerX)
            assert.are.equal(0, bounds.centerY)
            assert.are.equal(0, bounds.centerZ)
            assert.are.equal(1, bounds.radius)
            assert.has_error(function()
                components.Bounds3D(0, 0, 0, -1)
            end, "Bounds3D radius must be greater than or equal to 0, got: -1")
        end)

        it("keeps the 2D and 3D admission tags distinct", function()
            assert.are_not.equal(components.Renderable2D, components.Renderable3D)
            assert.are.equal("Renderable3D", components.Renderable3D.componentName)
        end)
    end)

    describe("mesh assets", function()
        it("builds the fixed vertex layout with 32-bit indices and bounds", function()
            local mesh = triangle("procedural://triangle")
            assert.are.equal("procedural://triangle", mesh.name)
            assert.are.equal(3, mesh.vertexCount)
            assert.are.equal(3, mesh.indexCount)
            assert.are.equal(2, mesh.indices[2])
            near(mesh.centerX, 0.5)
            near(mesh.centerY, 0.5)
            near(mesh.centerZ, 0)
            near(mesh.radius, math.sqrt(0.5))

            mesh:release()
            assert.is_nil(mesh.vertices)
            assert.is_nil(mesh.indices)
            mesh:release()
        end)

        it("rejects malformed procedural geometry at the call site", function()
            assert.has_error(function()
                assets.newMesh({ name = "bad://stride", vertices = { 0, 1, 2 }, indices = { 0, 0, 0 } })
            end, "tecs: mesh 'bad://stride' needs a non-empty multiple of 12 vertex floats")
            assert.has_error(function()
                local mesh = triangle("bad://index")
                mesh:release()
                assets.newMesh({
                    name = "bad://index",
                    vertices = {
                        0,
                        0,
                        0,
                        0,
                        0,
                        1,
                        1,
                        0,
                        0,
                        1,
                        0,
                        0,
                    },
                    indices = { 0, 0, 1 },
                })
            end, "tecs: mesh 'bad://index' index 3 is outside 0..0")
        end)

        it("keeps optional skin attributes outside the rigid vertex stream", function()
            local source = triangle("procedural://skin-source")
            local vertices = {}
            for index = 0, source.vertexCount * 12 - 1 do
                vertices[index + 1] = source.vertices[index]
            end
            source:release()
            local mesh = assets.newMesh({
                name = "procedural://skinned-triangle",
                vertices = vertices,
                indices = { 0, 1, 2 },
                joints = { 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0 },
                weights = { 1, 0, 0, 0, 0.25, 0.75, 0, 0, 1, 0, 0, 0 },
            })
            assert.is_not_nil(mesh.skinVertices)
            near(mesh.skinVertices[8 + 4], 0.25)
            near(mesh.skinVertices[8 + 5], 0.75)
            mesh:release()
            assert.is_nil(mesh.skinVertices)

            assert.has_error(function()
                assets.newMesh({
                    name = "bad://skin-pair",
                    vertices = vertices,
                    indices = { 0, 1, 2 },
                    joints = { 0 },
                })
            end, "tecs: mesh 'bad://skin-pair' joints and weights must be supplied together")
        end)
    end)

    describe("MeshExtractor", function()
        local function extractorScene(capacity, transparency, skinning)
            local world = tecs.ecs.newWorld()
            local packet = MeshFramePacket.create(skinning)
            local extractor = MeshExtractor.create({
                capacity = capacity,
                transparency = transparency,
                skinning = skinning,
            })
            local instances = loader.newArray("float[?]", capacity * 16)
            local bounds = loader.newArray("float[?]", capacity * 4)
            local commands = loader.newArray("SDL_GPUIndexedIndirectDrawCommand[?]", capacity)
            local skins = skinning and loader.newArray("float[?]", capacity) or nil
            extractor:setStaging(0, instances, bounds, commands, skins)
            extractor:install(world, packet, nil)
            return world, extractor, packet, instances, bounds, commands, skins
        end

        it("resolves residency once and writes mesh-owned staging", function()
            local world, extractor, packet, instances, bounds, commands = extractorScene(2)
            local asset = components.meshId("procedural://triangle")
            extractor:registerMesh(asset, 7, 11, 13, 15)
            local entity = world:spawn(
                tecs.Transform3D.new({ x = 4, y = 5, z = 6, scaleX = 2 }),
                components.Mesh(asset),
                components.Bounds3D(1, 0, 0, 0.5),
                components.MeshMaterial(3, 0),
                components.Tint(0.2, 0.4, 0.6, 1),
                components.Renderable3D()
            )

            extractor:extract(packet)

            assert.are.equal(1, packet.count)
            assert.are.equal(0, packet.dropped)
            assert.are.equal(1, packet.rewritten)
            assert.are.equal(7, instances[10])
            assert.are.equal(0, instances[11])
            near(instances[12], 0)
            near(instances[13], 0.2)
            near(instances[14], 0.4)
            near(instances[15], 0.6)
            near(bounds[0], 6)
            near(bounds[1], 5)
            near(bounds[2], 6)
            near(bounds[3], 1)
            assert.are.equal(15, commands[0].num_indices)
            assert.are.equal(1, commands[0].num_instances)
            assert.are.equal(13, commands[0].first_index)
            assert.are.equal(11, commands[0].vertex_offset)
            assert.are.equal(0, commands[0].first_instance)
            assert.are.equal(7, world:get(entity, components.Mesh).slot)
        end)

        it("writes optional palette offsets without changing rigid instances", function()
            local world, extractor, packet, _, _, _, skins = extractorScene(2, false, true)
            local meshAsset = components.meshId("procedural://skinned")
            local skinAsset = components.meshSkinId("procedural://skeleton")
            extractor:registerMesh(meshAsset, 0, 0, 0, 3)
            extractor:registerSkin(skinAsset, 12)
            world:spawn(
                tecs.Transform3D(),
                components.Mesh(meshAsset, 0),
                components.Bounds3D(),
                components.MeshMaterial(),
                components.MeshSkin(skinAsset),
                components.Tint(),
                components.Renderable3D()
            )
            world:spawn(
                tecs.Transform3D(),
                components.Mesh(meshAsset, 0),
                components.Bounds3D(),
                components.MeshMaterial(),
                components.Tint(),
                components.Renderable3D()
            )

            extractor:extract(packet)
            assert.are.equal(12, skins[0])
            assert.are.equal(-1, skins[1])
            assert.are.equal(8, packet.skinRanges.bytes)
        end)

        it("drops over capacity without leaving the world deferred", function()
            local world, extractor, packet = extractorScene(1)
            local asset = components.meshId("procedural://triangle")
            extractor:registerMesh(asset, 0, 0, 0, 3)
            for _ = 1, 3 do
                world:spawn(
                    tecs.Transform3D(),
                    components.Mesh(asset, 0),
                    components.Bounds3D(),
                    components.MeshMaterial(),
                    components.Tint(),
                    components.Renderable3D()
                )
            end

            extractor:extract(packet)
            assert.are.equal(1, packet.count)
            assert.are.equal(2, packet.dropped)

            local marker = tecs.ecs.newTagComponent({ name = "MeshExtractorAfterCapacity" })
            world:spawn(marker)
            local found = 0
            for _, length in world:newQuery({ include = { marker } }):iter() do
                found = found + length
            end
            assert.are.equal(1, found)
        end)

        it("classifies resident blended materials without inspecting textures", function()
            local world, extractor, packet, instances = extractorScene(2, true)
            local meshAsset = components.meshId("procedural://glass")
            local materialAsset = components.meshMaterialId("procedural://glass-material")
            extractor:registerMesh(meshAsset, 0, 0, 0, 3)
            extractor:registerMaterial(materialAsset, 1, 2)
            world:spawn(
                tecs.Transform3D(),
                components.Mesh(meshAsset, 0),
                components.Bounds3D(),
                components.MeshMaterial(materialAsset, 1),
                components.Tint(),
                components.Renderable3D()
            )

            extractor:extract(packet)
            assert.are.equal(1, packet.blendCount)
            assert.are.equal(2, instances[12])
        end)

        it("raises for unregistered geometry after exhausting the query", function()
            local world, extractor, packet = extractorScene(1)
            local asset = components.meshId("procedural://missing")
            world:spawn(
                tecs.Transform3D(),
                components.Mesh(asset),
                components.Bounds3D(),
                components.MeshMaterial(),
                components.Tint(),
                components.Renderable3D()
            )
            assert.has_error(function()
                extractor:extract(packet)
            end, "tecs: no mesh is registered as 'procedural://missing'")
        end)
    end)

    describe("Camera3D", function()
        it("maps the near and far planes to zero and one", function()
            local camera = Camera3D.newCamera3D({ verticalFov = math.pi / 2, near = 1, far = 11 })
            local matrix = camera:matrix(100, 100)

            local _, _, nearZ, nearW = clipPoint(matrix, 0, 0, -1)
            local _, _, farZ, farW = clipPoint(matrix, 0, 0, -11)
            near(nearZ / nearW, 0, "near depth")
            near(farZ / farW, 1, "far depth")
        end)

        it("uses vertical field of view and viewport aspect", function()
            local camera = Camera3D.newCamera3D({ verticalFov = math.pi / 2, near = 1, far = 10 })
            local matrix = camera:matrix(200, 100)

            local rightX, _, _, rightW = clipPoint(matrix, 2, 0, -1)
            local _, topY, _, topW = clipPoint(matrix, 0, 1, -1)
            near(rightX / rightW, 1, "right edge")
            near(topY / topW, 1, "top edge")
        end)

        it("inverts camera position and orientation", function()
            local half = math.sqrt(0.5)
            local camera = Camera3D.newCamera3D({
                x = 3,
                y = 4,
                z = 5,
                rotationY = half,
                rotationW = half,
                verticalFov = math.pi / 2,
                near = 1,
                far = 10,
            })
            local matrix = camera:matrix(100, 100)

            -- Positive 90 degrees around Y turns local -Z toward world -X.
            local x, y, _, w = clipPoint(matrix, 2, 4, 5)
            near(x / w, 0, "rotated view x")
            near(y / w, 0, "rotated view y")
            near(w, 1, "rotated near distance")
        end)

        it("rejects invalid projection and zero orientation values", function()
            assert.has_error(function()
                Camera3D.newCamera3D({ near = 0 })
            end, "Camera3D near must be greater than 0")
            assert.has_error(function()
                Camera3D.newCamera3D({ near = 2, far = 1 })
            end, "Camera3D far must be greater than near")

            local camera = Camera3D.newCamera3D()
            camera.rotationW = 0
            assert.has_error(function()
                camera:matrix(100, 100)
            end, "Camera3D rotation quaternion must not be zero")
        end)

        it("extracts six planes that keep and reject bounding spheres", function()
            local camera = Camera3D.newCamera3D({ verticalFov = math.pi / 2, near = 1, far = 10 })
            local planes = loader.newArray("float[24]")
            frustum.write(camera:matrix(100, 100), planes)

            local function visible(x, y, z, radius)
                for plane = 0, 5 do
                    local at = plane * 4
                    if planes[at] * x + planes[at + 1] * y + planes[at + 2] * z + planes[at + 3] < -radius then
                        return false
                    end
                end
                return true
            end

            assert.is_true(visible(0, 0, -2, 0.1))
            assert.is_true(visible(2, 0, -2, 0.1), "a sphere touching the right plane survives")
            assert.is_false(visible(3, 0, -2, 0.1))
            assert.is_false(visible(0, 0, -0.5, 0.1))
            assert.is_false(visible(0, 0, -11, 0.1))
        end)
    end)

    describe("MeshFramePacket", function()
        it("copies camera state instead of retaining the camera", function()
            local camera = Camera3D.newCamera3D({ x = 4, y = 5, z = 6, near = 0.5, far = 200 })
            local packet = MeshFramePacket.create()
            packet:setCamera(camera, 320, 180)
            local first = packet.viewProjection[0]

            camera.x = 40
            camera.verticalFov = math.pi / 4
            camera:matrix(320, 180)

            assert.are.equal(4, packet.cameraX)
            assert.are.equal(5, packet.cameraY)
            assert.are.equal(6, packet.cameraZ)
            assert.are.equal(0.5, packet.near)
            assert.are.equal(200, packet.far)
            assert.are.equal(first, packet.viewProjection[0])
        end)

        it("reuses and clears its dirty-range storage", function()
            local packet = MeshFramePacket.create()
            local instanceRanges = packet.instanceRanges
            local boundsRanges = packet.boundsRanges
            local commandRanges = packet.commandRanges
            instanceRanges:mark(16, 32)
            boundsRanges:mark(8, 16)
            commandRanges:mark(0, 20)

            packet:begin(2)

            assert.are.equal(2, packet.slot)
            assert.are.equal(0, packet.instanceRanges.count)
            assert.are.equal(0, packet.boundsRanges.count)
            assert.are.equal(0, packet.commandRanges.count)
            assert.is_true(rawequal(instanceRanges, packet.instanceRanges))
            assert.is_true(rawequal(boundsRanges, packet.boundsRanges))
            assert.is_true(rawequal(commandRanges, packet.commandRanges))
        end)
    end)
end)
