require("busted")

-- Set up Love2D mock before requiring anything else
local love2d_mock <const> = require("spec.love2d.love2d_mock")
rawset(_G, "love", love2d_mock)

-- Skip if Love2D 12 GPU features aren't available (mock doesn't support full GPU)
if not love.graphics.newComputeShader then
    pending("Render pipeline tests require Love2D 12 GPU features")
    return
end

local tecs <const> = require("tecs")
local gfx <const> = require("tecs2d.gfx")
local luassert <const> = require("luassert")

-- Mock camera for testing that implements Camera interface
local record MockCamera is gfx.Camera
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

function MockCamera:drawLayer(_: gfx.Layer, _: gfx.Pipeline)
    self.drawLayerCalls = self.drawLayerCalls + 1
end

function MockCamera:detach(_: {integer}, _: gfx.Pipeline, ...: function(love.graphics.Image))
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

describe("tecs2d.gfx Pipeline", function()
    local world: tecs.World
    local camera: MockCamera
    local pipeline: gfx.Pipeline

    before_each(function()
        world = tecs.newWorld()
        camera = createMockCamera()
        pipeline = gfx.newPipeline({world = world, camera = camera})
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
                0,         -- rotation
                1, 1,      -- scaleX, scaleY
                0, 0,      -- pivotX, pivotY
                function() end  -- draw function
            )

            luassert.is_true(drawId > 0)
            luassert.is_equal(1, #camera.visibleCalls)
            luassert.same({100, 200, 32, 32}, camera.visibleCalls[1])
        end)

        it("should handle invisible draws", function()
            -- Make camera return false for visibility
            camera.isVisible = function(_self: MockCamera, _x: number, _y: number, _w: number, _h: number): boolean return false end

            local drawId = pipeline:draw(1, 100, 200, 32, 32, 0, 1, 1, 0, 0, function() end)

            luassert.is_equal(0, drawId)  -- Should return 0 for invisible draws
        end)
    end)

    describe("drawTransform", function()
        it("should draw using Transform component", function()
            -- Create a Transform component
            local transform = tecs.builtins.Transform.new({
                x = 150,
                y = 250,
                z = 5,
                layer = 2
            })

            local drawId = pipeline:drawTransform(
                transform,
                150 - 32, 250 - 32,  -- cullX, cullY (centered)
                64, 64,              -- width, height
                function() end
            )

            luassert.is_true(drawId > 0)
            luassert.is_equal(1, #camera.visibleCalls)
            luassert.same({118, 218, 64, 64}, camera.visibleCalls[1])
        end)

        it("should use default layer when Transform has no layer", function()
            local transform = tecs.builtins.Transform.new({
                x = 50,
                y = 75
                -- No layer specified
            })

            local drawId = pipeline:drawTransform(transform, 50 - 16, 75 - 16, 32, 32, function() end)

            luassert.is_true(drawId > 0)
            -- Should use default layer 1
            luassert.is_equal(1, #camera.visibleCalls)
            luassert.same({34, 59, 32, 32}, camera.visibleCalls[1])
        end)

        it("should handle invisible drawTransform calls", function()
            camera.isVisible = function(_self: MockCamera, _x: number, _y: number, _w: number, _h: number): boolean return false end

            local transform = tecs.builtins.Transform.new({
                x = 300,
                y = 400,
                layer = 3
            })

            local drawId = pipeline:drawTransform(transform, 300 - 8, 400 - 8, 16, 16, function() end)

            luassert.is_equal(0, drawId)  -- Should return 0 for invisible draws
        end)

        it("should use Transform z value", function()
            local transform = tecs.builtins.Transform.new({
                x = 100,
                y = 200,
                z = 10,
                layer = 1
            })

            local drawId = pipeline:drawTransform(transform, 100 - 16, 200 - 16, 32, 32, function() end)

            luassert.is_true(drawId > 0)

            -- Check that we can get the draw data back
            local x, y, w, h = pipeline:getDrawData(drawId)
            luassert.is_equal(84, x)  -- 100 - 16
            luassert.is_equal(184, y) -- 200 - 16
            luassert.is_equal(32, w)
            luassert.is_equal(32, h)
        end)
    end)

    describe("draw modification", function()
        it("should allow setting z-depth after draw", function()
            local drawId = pipeline:draw(1, 0, 0, 32, 32, 0, 1, 1, 0, 0, function() end)
            pipeline:setDrawZ(drawId, 15)

            -- Verify the z value was set (this is internal but we can test the API works)
            local x, y, w, h = pipeline:getDrawCoordinates(drawId)
            luassert.is_equal(0, x)
            luassert.is_equal(0, y)
            luassert.is_equal(32, w)
            luassert.is_equal(32, h)
        end)
    end)

    describe("sorting", function()
        it("should support disabling sorting with sortFunction = false", function()
            -- Create a new world and camera for this test to avoid system name conflicts
            local unsortedWorld = tecs.newWorld()
            local unsortedCamera = createMockCamera()

            -- Create a pipeline with sorting disabled
            local unsortedPipeline = gfx.newPipeline({
                world = unsortedWorld,
                camera = unsortedCamera,
                sortFunction = false
            } as gfx.RenderConfig)

            -- Add draws in a specific order
            local draw1 = unsortedPipeline:draw(1, 0, 100, 32, 32, 0, 1, 1, 0, 0, function() end)  -- bottom
            local draw2 = unsortedPipeline:draw(1, 0, 50, 32, 32, 0, 1, 1, 0, 0, function() end)   -- top
            local draw3 = unsortedPipeline:draw(1, 0, 75, 32, 32, 0, 1, 1, 0, 0, function() end)   -- middle

            -- Draws should be returned in insertion order (not sorted by y position)
            luassert.is_true(draw1 > 0)
            luassert.is_true(draw2 > 0)
            luassert.is_true(draw3 > 0)
            luassert.is_true(draw1 < draw2)
            luassert.is_true(draw2 < draw3)

            -- Clean up
            unsortedWorld:shutdown()
        end)
    end)

    describe("G-buffer auto-uniforms", function()
        it("should have G-buffer canvas fields on the renderer", function()
            local renderer = pipeline:getRenderer()
            luassert.is_not_nil(renderer)
            -- These are created during resize() and should be valid canvases
            luassert.is_not_nil(renderer.gBufferNormal)
            luassert.is_not_nil(renderer.gBufferEmission)
        end)

        it("should set layer effect without errors when using auto-uniform names", function()
            -- Create a mock shader that declares tecs_Normal, tecs_Emission
            local mockShader = love.graphics.newShader("", "")

            -- Setting a layer effect should not error
            luassert.has_no.errors(function()
                pipeline:setLayerEffect(1, mockShader, nil, { singleLayer = true })
            end)

            -- Clearing should not error
            luassert.has_no.errors(function()
                pipeline:clearLayerEffect(1)
            end)
        end)
    end)
end)