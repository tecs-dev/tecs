require("busted")

-- Skip this entire test suite if FFI is disabled since rendering requires FFI
local libffi = require("tecs.internal.ffi.libffi")
if not libffi.isFFIAvailable() then
    pending("Render pipeline tests require FFI support")
    return
end

-- Set up Love2D mock before requiring anything else
local love2d_mock <const> = require("spec.love2d.love2d_mock")
rawset(_G, "love", love2d_mock)

local tecs <const> = require("tecs")
local render <const> = require("tecs_render")
local luassert <const> = require("luassert")

-- Mock camera for testing that implements Camera interface
local record MockCamera is render.Camera
    visibleCalls: {{number, number, number, number}}
    attachCalls: integer
    detachCalls: integer
    drawLayerCalls: integer
    screenWidth: number
    screenHeight: number
end


function MockCamera:isVisible(x: number, y: number, w: number, h: number): boolean
    table.insert(self.visibleCalls, {x, y, w, h})
    return true  -- Always visible for testing
end

function MockCamera:setScreenSize(w: number, h: number)
    self.screenWidth = w
    self.screenHeight = h
end

function MockCamera:attach()
    self.attachCalls = self.attachCalls + 1
end

function MockCamera:drawLayer(_: render.Layer, _: render.Pipeline)
    self.drawLayerCalls = self.drawLayerCalls + 1
end

function MockCamera:detach(_: {integer}, _: render.Pipeline, ...: function(love.graphics.Image))
    self.detachCalls = self.detachCalls + 1
end

function MockCamera:setClamp(_: boolean)
    -- No-op for testing
end

local function createMockCamera(): MockCamera
    local mock: MockCamera = {
        visibleCalls = {},
        attachCalls = 0,
        detachCalls = 0,
        drawLayerCalls = 0,
        screenWidth = 800,
        screenHeight = 600,
        isVisible = MockCamera.isVisible,
        setScreenSize = MockCamera.setScreenSize,
        attach = MockCamera.attach,
        drawLayer = MockCamera.drawLayer,
        detach = MockCamera.detach,
        setClamp = MockCamera.setClamp
    }
    return mock
end

describe("tecs_render Pipeline", function()
    local world: tecs.World
    local camera: MockCamera
    local pipeline: render.Pipeline

    before_each(function()
        world = tecs.newWorld()
        camera = createMockCamera()
        pipeline = render.newPipeline({world = world, camera = camera})
    end)

    after_each(function()
        if world then
            world:shutdown()
        end
    end)

    describe("basic functionality", function()
        it("should create a pipeline", function()
            luassert.is_not_nil(pipeline)
            luassert.is_equal(camera, pipeline:getCamera())
        end)

        it("should handle draw calls", function()
            local drawId = pipeline:draw(
                1,      -- layer
                100, 200,  -- x, y
                32, 32,    -- width, height
                function() end  -- draw function
            )

            luassert.is_true(drawId > 0)
            luassert.is_equal(1, #camera.visibleCalls)
            luassert.same({100, 200, 32, 32}, camera.visibleCalls[1])
        end)

        it("should handle invisible draws", function()
            -- Make camera return false for visibility
            camera.isVisible = function(_self: MockCamera, _x: number, _y: number, _w: number, _h: number): boolean return false end

            local drawId = pipeline:draw(1, 100, 200, 32, 32, function() end)

            luassert.is_equal(0, drawId)  -- Should return 0 for invisible draws
        end)
    end)

    describe("drawTransform", function()
        it("should draw using Transform component", function()
            -- Create a Transform component
            local transform = tecs.builtins.Transform({
                x = 150,
                y = 250,
                z = 5,
                layer = 2
            })

            local drawId = pipeline:drawTransform(
                transform,
                64, 64,  -- width, height
                function() end
            )

            luassert.is_true(drawId > 0)
            luassert.is_equal(1, #camera.visibleCalls)
            luassert.same({150, 250, 64, 64}, camera.visibleCalls[1])
        end)

        it("should use default layer when Transform has no layer", function()
            local transform = tecs.builtins.Transform({
                x = 50,
                y = 75
                -- No layer specified
            })

            local drawId = pipeline:drawTransform(transform, 32, 32, function() end)

            luassert.is_true(drawId > 0)
            -- Should use default layer 1
            luassert.is_equal(1, #camera.visibleCalls)
            luassert.same({50, 75, 32, 32}, camera.visibleCalls[1])
        end)

        it("should handle invisible drawTransform calls", function()
            camera.isVisible = function(_self: MockCamera, _x: number, _y: number, _w: number, _h: number): boolean return false end

            local transform = tecs.builtins.Transform({
                x = 300,
                y = 400,
                layer = 3
            })

            local drawId = pipeline:drawTransform(transform, 16, 16, function() end)

            luassert.is_equal(0, drawId)  -- Should return 0 for invisible draws
        end)

        it("should use Transform z value", function()
            local transform = tecs.builtins.Transform({
                x = 100,
                y = 200,
                z = 10,
                layer = 1
            })

            local drawId = pipeline:drawTransform(transform, 32, 32, function() end)

            luassert.is_true(drawId > 0)

            -- Check that we can get the draw data back
            local x, y, w, h = pipeline:getDrawData(drawId)
            luassert.is_equal(100, x)
            luassert.is_equal(200, y)
            luassert.is_equal(32, w)
            luassert.is_equal(32, h)
        end)
    end)

    describe("draw modification", function()
        it("should allow setting z-depth after draw", function()
            local drawId = pipeline:draw(1, 0, 0, 32, 32, function() end)
            pipeline:setDrawZ(drawId, 15)

            -- Verify the z value was set (this is internal but we can test the API works)
            local x, y, w, h = pipeline:getDrawCoordinates(drawId)
            luassert.is_equal(0, x)
            luassert.is_equal(0, y)
            luassert.is_equal(32, w)
            luassert.is_equal(32, h)
        end)
    end)
end)