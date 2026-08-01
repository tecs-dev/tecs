-- The 3D contract exists before MeshDomain does. These specs hold that seam
-- without opening a GPU device or letting the sprite extractor participate.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local components = require("tecs.components")
local Camera3D = require("tecs.gfx.Camera3D")
local MeshFramePacket = require("tecs.internal.render.MeshFramePacket")

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
            instanceRanges:mark(16, 32)
            boundsRanges:mark(8, 16)

            packet:begin(2)

            assert.are.equal(2, packet.slot)
            assert.are.equal(0, packet.instanceRanges.count)
            assert.are.equal(0, packet.boundsRanges.count)
            assert.is_true(rawequal(instanceRanges, packet.instanceRanges))
            assert.is_true(rawequal(boundsRanges, packet.boundsRanges))
        end)
    end)
end)
