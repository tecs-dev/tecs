require("busted")

local luassert <const> = require("luassert")
local C <const> = require("ffi")

local record MockTransformState
    tx: number
    ty: number
    r: number
    sx: number
    sy: number
end

local record MockTransform
    _m: MockTransformState
    reset: function(MockTransform): MockTransform
    translate: function(MockTransform, number, number): MockTransform
    rotate: function(MockTransform, number): MockTransform
    scale: function(MockTransform, number, number): MockTransform
    transformPoint: function(MockTransform, number, number): number, number
    inverseTransformPoint: function(MockTransform, number, number): number, number
    getMatrix: function(MockTransform): number, number, number, number, number, number, number, number, number, number, number, number, number, number, number, number
    inverse: function(MockTransform): MockTransform
end

local MockTransformMT <const>: metatable<MockTransform> = { __index = MockTransform }

local function newTransformMock(): MockTransform
    local self = setmetatable({
        _m = { tx=0, ty=0, r=0, sx=1, sy=1 } as MockTransformState,
    } as MockTransform, MockTransformMT)
    return self
end

function MockTransform:reset(): MockTransform
    self._m.tx=0; self._m.ty=0; self._m.r=0; self._m.sx=1; self._m.sy=1; return self
end
function MockTransform:translate(dx: number, dy: number): MockTransform
    self._m.tx=self._m.tx+dx*self._m.sx; self._m.ty=self._m.ty+dy*self._m.sy; return self
end
function MockTransform:rotate(angle: number): MockTransform
    self._m.r=self._m.r+angle; return self
end
function MockTransform:scale(sx: number, sy: number): MockTransform
    self._m.sx=self._m.sx*sx; self._m.sy=self._m.sy*sy; return self
end
function MockTransform:transformPoint(x: number, y: number): number, number
    local m = self._m
    local cosR = math.cos(m.r)
    local sinR = math.sin(m.r)
    return x * m.sx * cosR - y * m.sy * sinR + m.tx,
           x * m.sx * sinR + y * m.sy * cosR + m.ty
end
function MockTransform:inverseTransformPoint(sx: number, sy: number): number, number
    local m = self._m
    local dx = sx - m.tx
    local dy = sy - m.ty
    local cosR = math.cos(-m.r)
    local sinR = math.sin(-m.r)
    return (dx * cosR - dy * sinR) / m.sx,
           (dx * sinR + dy * cosR) / m.sy
end
function MockTransform:getMatrix(): number, number, number, number, number, number, number, number, number, number, number, number, number, number, number, number
    local m = self._m
    local cosR = math.cos(m.r)
    local sinR = math.sin(m.r)
    return m.sx*cosR, -m.sy*sinR, 0, m.tx,
           m.sx*sinR, m.sy*cosR, 0, m.ty,
           0, 0, 1, 0,
           0, 0, 0, 1
end
function MockTransform:inverse(): MockTransform
    return newTransformMock()
end

-- Mock love modules for test environment (love2d not available in busted)
do
    if not rawget(_G as table, "love") then
        rawset(_G as table, "love", {})
    end
    local love_ref = rawget(_G as table, "love") as {string: {string: any}}
    love_ref["data"] = {
        newByteData = function(size: integer): any
            local buf = C.new("uint8_t[?]", size)
            return {
                getFFIPointer = function(): any return buf end,
            }
        end,
    }
    local noiseFn = function(x: number, y: number): number
        return 0.5 + 0.3 * math.sin((x or 0) + (y or 0))
    end
    local transformFactory: function(): any = newTransformMock as function(): any
    love_ref["math"] = {
        perlinNoise = noiseFn,
        newTransform = transformFactory,
    }
end

local Camera <const> = require("tecs2d.gfx.Camera")

local abs <const> = math.abs
local EPS <const> = 1e-3

local function assertNear(actual: number, expected: number, msg: string)
    luassert.is_true(abs(actual - expected) < EPS,
        (msg or "") .. " expected " .. tostring(expected) .. " got " .. tostring(actual))
end

describe("Camera", function()
    describe("constructor", function()
        it("should create with default values", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            luassert.is_equal(0, cam.x)
            luassert.is_equal(0, cam.y)
            luassert.is_equal(1.0, cam.zoom)
            luassert.is_equal(0.0, cam.rotation)
            luassert.is_true(cam.lerpingEnabled)
            luassert.is_equal(8.0, cam.lerpSpeed)
            luassert.is_false(cam.clampToBounds)
            luassert.is_not_nil(cam:getTransform())
        end)

        it("should set screen dimensions", function()
            local cam = Camera.new({screenWidth=1920, screenHeight=1080, virtualHeight=720})
            luassert.is_equal(1920, cam._screenWidth)
            luassert.is_equal(1080, cam._screenHeight)
            luassert.is_equal(720, cam._virtualHeight)
        end)
    end)

    describe("setPosition / getPosition", function()
        it("should set position immediately", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setPosition(100, 200)
            local x, y = cam:getPosition()
            luassert.is_equal(100, x)
            luassert.is_equal(200, y)
            -- Target should match
            luassert.is_equal(100, cam.targetX)
            luassert.is_equal(200, cam.targetY)
        end)
    end)

    describe("move", function()
        it("should move immediately when lerp disabled", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam.lerpingEnabled = false
            cam:move(50, 75)
            local x, y = cam:getPosition()
            luassert.is_equal(50, x)
            luassert.is_equal(75, y)
        end)

        it("should set target when lerp enabled", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam.lerpingEnabled = true
            cam:move(50, 75)
            -- Position should not change yet
            luassert.is_equal(0, cam.x)
            luassert.is_equal(0, cam.y)
            -- Target should be set
            luassert.is_equal(50, cam.targetX)
            luassert.is_equal(75, cam.targetY)
        end)

        it("should interpolate with update when lerp enabled", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam.lerpingEnabled = true
            cam.lerpSpeed = 10
            cam:move(100, 0)
            -- After one large dt, should have moved toward target
            cam:update(0.1)
            luassert.is_true(cam.x > 0)
            luassert.is_true(cam.x < 100)
        end)
    end)

    describe("nudge", function()
        it("should nudge by delta", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam.lerpingEnabled = false
            cam:setPosition(10, 20)
            cam:nudge(5, -3)
            local x, y = cam:getPosition()
            luassert.is_equal(15, x)
            luassert.is_equal(17, y)
        end)
    end)

    describe("setZoom / getZoom", function()
        it("should set and get zoom", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setZoom(2.5)
            luassert.is_equal(2.5, cam:getZoom())
        end)

        it("should clamp to minimum zoom", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setZoom(0)
            luassert.is_true(cam:getZoom() > 0)
        end)

        it("should clamp negative zoom", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setZoom(-1)
            luassert.is_true(cam:getZoom() > 0)
        end)
    end)

    describe("setRotation / getRotation", function()
        it("should set rotation immediately when lerp disabled", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam.lerpingEnabled = false
            cam:setRotation(1.5)
            luassert.is_equal(1.5, cam:getRotation())
        end)

        it("should set target rotation when lerp enabled", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam.lerpingEnabled = true
            cam:setRotation(1.5)
            luassert.is_equal(0.0, cam:getRotation())
            luassert.is_equal(1.5, cam.targetRotation)
        end)

        it("should use shortest-path lerp for rotation", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam.lerpingEnabled = true
            cam.lerpSpeed = 10
            cam.rotation = 0.1
            cam.targetRotation = -0.1
            cam:update(0.1)
            -- Should move toward -0.1 (shortest path)
            luassert.is_true(cam.rotation < 0.1)
        end)
    end)

    describe("toWorld / toScreen", function()
        it("should round-trip screen to world and back", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setPosition(100, 200)

            local wx, wy = cam:toWorld(400, 300)
            local sx, sy = cam:toScreen(wx, wy)
            assertNear(sx, 400, "screen x")
            assertNear(sy, 300, "screen y")
        end)

        it("should convert screen center to camera position", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setPosition(50, 75)

            local wx, wy = cam:toWorld(400, 300)
            assertNear(wx, 50, "world x at center")
            assertNear(wy, 75, "world y at center")
        end)
    end)

    describe("isVisible", function()
        it("should detect visible rectangles", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setPosition(0, 0)
            -- A rect near the center should be visible
            luassert.is_true(cam:isVisible(-10, -10, 20, 20))
        end)

        it("should detect invisible rectangles", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setPosition(0, 0)
            -- A rect far off-screen should not be visible
            luassert.is_false(cam:isVisible(10000, 10000, 10, 10))
        end)
    end)

    describe("updateBounds", function()
        it("should compute visible corners", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setPosition(0, 0)

            local x1, y1, x2, y2 = cam:getVisibleCorners()
            luassert.is_true(x1 < 0)
            luassert.is_true(y1 < 0)
            luassert.is_true(x2 > 0)
            luassert.is_true(y2 > 0)
        end)

        it("should compute visible dimensions", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setPosition(0, 0)

            local w, h = cam:getVisibleDimensions()
            luassert.is_true(w > 0)
            luassert.is_true(h > 0)
        end)

        it("should update when position changes", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setPosition(0, 0)
            local x1a = (cam:getVisibleCorners())

            cam:setPosition(100, 0)
            local x1b = (cam:getVisibleCorners())

            luassert.is_true(x1b > x1a)
        end)

        it("should update when zoom changes", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setPosition(0, 0)
            local w1, _ = cam:getVisibleDimensions()

            cam:setZoom(2.0)
            local w2, _ = cam:getVisibleDimensions()

            -- Higher zoom = smaller visible area
            luassert.is_true(w2 < w1)
        end)
    end)

    describe("setScreenSize", function()
        it("should update screen dimensions", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setScreenSize(1920, 1080, 720)
            luassert.is_equal(1920, cam._screenWidth)
            luassert.is_equal(1080, cam._screenHeight)
            luassert.is_equal(720, cam._virtualHeight)
        end)

        it("should recompute bounds after resize", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setPosition(0, 0)
            local w1, _ = cam:getVisibleDimensions()

            -- Double the width while keeping same height and virtualHeight
            -- This changes the aspect ratio, giving a wider visible area
            cam:setScreenSize(1600, 600, 600)
            local w2, _ = cam:getVisibleDimensions()

            -- Wider screen = wider visible area
            luassert.is_true(w2 > w1)
        end)
    end)

    describe("setLerpingEnabled", function()
        it("should snap to target when disabled", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam.lerpingEnabled = true
            cam:move(100, 200)
            -- Position should still be at 0,0
            luassert.is_equal(0, cam.x)

            cam:setLerpingEnabled(false)
            -- Should snap to target
            luassert.is_equal(100, cam.x)
            luassert.is_equal(200, cam.y)
        end)
    end)

    describe("setLerpSpeed", function()
        it("should clamp lerp speed", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setLerpSpeed(0)
            luassert.is_equal(1, cam.lerpSpeed)

            cam:setLerpSpeed(100)
            luassert.is_equal(20, cam.lerpSpeed)

            cam:setLerpSpeed(10)
            luassert.is_equal(10, cam.lerpSpeed)
        end)
    end)

    describe("setClamp / setWorldBounds", function()
        it("should clamp position to world bounds", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setClamp(true)
            cam:setWorldBounds(0, 0, 1000, 1000)

            -- Try to move outside bounds
            cam:setPosition(-500, -500)
            local x, y = cam:getPosition()
            luassert.is_true(x >= 0)
            luassert.is_true(y >= 0)
        end)
    end)

    describe("update", function()
        it("should do nothing when lerp disabled", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam.lerpingEnabled = false
            cam.x = 0
            cam.targetX = 100
            cam:update(1.0)
            luassert.is_equal(0, cam.x)
        end)

        it("should snap when close to target", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam.lerpingEnabled = true
            cam.x = 99.95
            cam.targetX = 100
            cam.y = 199.95
            cam.targetY = 200
            cam:update(0.016)
            luassert.is_equal(100, cam.x)
            luassert.is_equal(200, cam.y)
        end)
    end)

    describe("table-based constructor config", function()
        it("should apply position config", function()
            local cam = Camera.new({
                screenWidth = 800, screenHeight = 600, virtualHeight = 600,
                position = {50, 75},
            })
            luassert.is_equal(50, cam.x)
            luassert.is_equal(75, cam.y)
            luassert.is_equal(50, cam.targetX)
            luassert.is_equal(75, cam.targetY)
        end)

        it("should apply zoom config", function()
            local cam = Camera.new({
                screenWidth = 800, screenHeight = 600, virtualHeight = 600,
                zoom = 2.5,
            })
            luassert.is_equal(2.5, cam.zoom)
        end)

        it("should apply lerp config", function()
            local cam = Camera.new({
                screenWidth = 800, screenHeight = 600, virtualHeight = 600,
                lerpingEnabled = false,
                lerpSpeed = 12.0,
            })
            luassert.is_false(cam.lerpingEnabled)
            luassert.is_equal(12.0, cam.lerpSpeed)
        end)

        it("should apply name config", function()
            local cam = Camera.new({
                screenWidth = 800, screenHeight = 600, virtualHeight = 600,
                name = "minimap",
            })
            luassert.is_equal("minimap", cam:getName())
        end)
    end)

    describe("viewport", function()
        it("should default to fullscreen (0,0,0,0)", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            local x, y, w, h = cam:getViewport()
            luassert.is_equal(0, x)
            luassert.is_equal(0, y)
            luassert.is_equal(0, w)
            luassert.is_equal(0, h)
        end)

        it("should apply viewport from config", function()
            local cam = Camera.new({
                screenWidth = 800, screenHeight = 600, virtualHeight = 600,
                viewport = {100, 50, 400, 300},
            })
            local x, y, w, h = cam:getViewport()
            luassert.is_equal(100, x)
            luassert.is_equal(50, y)
            luassert.is_equal(400, w)
            luassert.is_equal(300, h)
            -- Screen size matches viewport for correct aspect ratio
            luassert.is_equal(400, cam._screenWidth)
            luassert.is_equal(300, cam._screenHeight)
        end)

        it("should update via setViewport", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setViewport(10, 20, 200, 150)
            local x, y, w, h = cam:getViewport()
            luassert.is_equal(10, x)
            luassert.is_equal(20, y)
            luassert.is_equal(200, w)
            luassert.is_equal(150, h)
            luassert.is_equal(200, cam._screenWidth)
            luassert.is_equal(150, cam._screenHeight)
        end)
    end)

    describe("layer mask", function()
        it("should default to all layers visible (0xFFFF)", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            luassert.is_equal(0xFFFF, cam:getLayerMask())
        end)

        it("should build mask from layers list", function()
            local cam = Camera.new({
                screenWidth = 800, screenHeight = 600, virtualHeight = 600,
                layers = {1, 3, 5},
            })
            luassert.is_true(cam:isLayerVisible(1))
            luassert.is_false(cam:isLayerVisible(2))
            luassert.is_true(cam:isLayerVisible(3))
            luassert.is_false(cam:isLayerVisible(4))
            luassert.is_true(cam:isLayerVisible(5))
        end)

        it("should build mask from layer range", function()
            local cam = Camera.new({
                screenWidth = 800, screenHeight = 600, virtualHeight = 600,
                layerRange = {2, 4},
            })
            luassert.is_false(cam:isLayerVisible(1))
            luassert.is_true(cam:isLayerVisible(2))
            luassert.is_true(cam:isLayerVisible(3))
            luassert.is_true(cam:isLayerVisible(4))
            luassert.is_false(cam:isLayerVisible(5))
        end)

        it("should apply layerMask directly", function()
            local cam = Camera.new({
                screenWidth = 800, screenHeight = 600, virtualHeight = 600,
                layerMask = 0x000F,  -- layers 1-4
            })
            luassert.is_true(cam:isLayerVisible(1))
            luassert.is_true(cam:isLayerVisible(4))
            luassert.is_false(cam:isLayerVisible(5))
        end)

        it("should toggle single layer", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            luassert.is_true(cam:isLayerVisible(3))
            cam:setLayer(3, false)
            luassert.is_false(cam:isLayerVisible(3))
            cam:setLayer(3, true)
            luassert.is_true(cam:isLayerVisible(3))
        end)

        it("should set layers from list", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setLayers({1, 5, 10})
            luassert.is_true(cam:isLayerVisible(1))
            luassert.is_false(cam:isLayerVisible(2))
            luassert.is_true(cam:isLayerVisible(5))
            luassert.is_true(cam:isLayerVisible(10))
            luassert.is_false(cam:isLayerVisible(11))
        end)

        it("should set layers from range", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setLayerRange(3, 7)
            luassert.is_false(cam:isLayerVisible(2))
            luassert.is_true(cam:isLayerVisible(3))
            luassert.is_true(cam:isLayerVisible(7))
            luassert.is_false(cam:isLayerVisible(8))
        end)

        it("should handle out-of-range layers", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            luassert.is_false(cam:isLayerVisible(0))
            luassert.is_false(cam:isLayerVisible(17))
            -- setLayer should not crash on out-of-range
            cam:setLayer(0, true)
            cam:setLayer(17, true)
        end)
    end)

    describe("disableDrawPhase", function()
        it("should default to false", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            luassert.is_false(cam:getDisableDrawPhase())
        end)

        it("should apply config", function()
            local cam = Camera.new({
                screenWidth = 800, screenHeight = 600, virtualHeight = 600,
                disableDrawPhase = true,
            })
            luassert.is_true(cam:getDisableDrawPhase())
        end)

        it("should toggle via setter", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setDisableDrawPhase(true)
            luassert.is_true(cam:getDisableDrawPhase())
            cam:setDisableDrawPhase(false)
            luassert.is_false(cam:getDisableDrawPhase())
        end)
    end)

    describe("active", function()
        it("should default to true", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            luassert.is_true(cam:isActive())
        end)

        it("should toggle via setter", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setActive(false)
            luassert.is_false(cam:isActive())
            cam:setActive(true)
            luassert.is_true(cam:isActive())
        end)
    end)

    describe("canvas", function()
        it("should set dimensions from canvas", function()
            local mockCanvas = {
                getWidth = function(): integer return 256 end,
                getHeight = function(): integer return 192 end,
            }
            local cam = Camera.new({
                screenWidth = 800, screenHeight = 600, virtualHeight = 600,
                canvas = mockCanvas as love.graphics.Canvas,
            })
            luassert.is_equal(256, cam._textureW)
            luassert.is_equal(192, cam._textureH)
            luassert.is_equal(256, cam._screenWidth)
            luassert.is_equal(192, cam._screenHeight)
            luassert.is_equal(mockCanvas, cam:getCanvas())
        end)

        it("should default to no canvas", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            luassert.is_equal(0, cam._textureW)
            luassert.is_equal(0, cam._textureH)
            luassert.is_nil(cam:getCanvas())
        end)
    end)

    describe("screenshake", function()
        it("should default to zero trauma", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            luassert.is_equal(0, cam:getTrauma())
            luassert.is_equal(0, cam._shakeOffsetX)
            luassert.is_equal(0, cam._shakeOffsetY)
            luassert.is_equal(0, cam._shakeAngle)
        end)

        it("should add trauma via shake()", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:shake(0.5)
            luassert.is_equal(0.5, cam:getTrauma())
        end)

        it("should stack trauma up to 1.0", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:shake(0.7)
            cam:shake(0.5)
            luassert.is_equal(1.0, cam:getTrauma())
        end)

        it("should decay trauma over time", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam.lerpingEnabled = false
            cam:shake(1.0)
            cam:update(0.5)
            -- Default decay is 1.5/sec, so after 0.5s: 1.0 - 1.5*0.5 = 0.25
            assertNear(cam:getTrauma(), 0.25, "trauma after decay")
        end)

        it("should not go below zero", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam.lerpingEnabled = false
            cam:shake(0.1)
            cam:update(1.0)
            luassert.is_equal(0, cam:getTrauma())
            luassert.is_equal(0, cam._shakeOffsetX)
            luassert.is_equal(0, cam._shakeOffsetY)
            luassert.is_equal(0, cam._shakeAngle)
        end)

        it("should produce non-zero offsets when trauma > 0", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam.lerpingEnabled = false
            cam:shake(1.0)
            cam:update(0.016)
            -- With trauma near 1.0, offsets should be non-zero (noise mock is non-constant)
            local hasOffset = cam._shakeOffsetX ~= 0 or cam._shakeOffsetY ~= 0 or cam._shakeAngle ~= 0
            luassert.is_true(hasOffset, "expected non-zero shake offsets")
        end)

        it("should apply shake offset to render position", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam.lerpingEnabled = false
            cam:setPosition(100, 200)
            cam:shake(1.0)
            cam:update(0.016)
            -- Render position should differ from logical position
            local logicalMatchesRender = cam._renderX == cam.x and cam._renderY == cam.y
            luassert.is_false(logicalMatchesRender, "render position should include shake offset")
            -- Logical position should remain unchanged
            luassert.is_equal(100, cam.x)
            luassert.is_equal(200, cam.y)
        end)

        it("should apply shake angle to render rotation", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam.lerpingEnabled = false
            cam:shake(1.0)
            cam:update(0.016)
            -- Render rotation should include shake angle
            luassert.is_true(cam._renderRotation ~= cam.rotation or cam._shakeAngle == 0)
        end)

        it("should configure shake intensity", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setShakeIntensity(20)
            luassert.is_equal(20, cam._shakeIntensity)
        end)

        it("should configure shake rotation", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setShakeRotation(0.1)
            luassert.is_equal(0.1, cam._shakeRotation)
        end)

        it("should configure trauma decay", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setTraumaDecay(3.0)
            luassert.is_equal(3.0, cam._traumaDecay)
        end)

        it("should pad visible bounds by shake intensity", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam:setShakeIntensity(0)
            cam:setPosition(0, 0)
            local x1a, y1a, x2a, y2a = cam:getVisibleCorners()

            cam:setShakeIntensity(16)
            cam:updateBounds()
            local x1b, y1b, x2b, y2b = cam:getVisibleCorners()

            -- With shake intensity, bounds should be larger
            luassert.is_true(x1b < x1a, "left edge should expand with shake padding")
            luassert.is_true(y1b < y1a, "top edge should expand with shake padding")
            luassert.is_true(x2b > x2a, "right edge should expand with shake padding")
            luassert.is_true(y2b > y2a, "bottom edge should expand with shake padding")
        end)

        it("should work with lerping enabled", function()
            local cam = Camera.new({screenWidth=800, screenHeight=600, virtualHeight=600})
            cam.lerpingEnabled = true
            cam:move(100, 200)
            cam:shake(0.8)
            cam:update(0.016)
            -- Should have both lerp movement and shake
            luassert.is_true(cam.x > 0, "position should lerp toward target")
            luassert.is_true(cam:getTrauma() > 0, "trauma should still be present")
            luassert.is_true(cam:getTrauma() < 0.8, "trauma should have decayed")
        end)
    end)
end)
