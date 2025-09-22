require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")
local pipeline_key <const> = require("tecs2d.gfx.internal.pipeline_key")
local Anchor <const> = require("tecs2d.ui.internal.Anchor")
local bit <const> = require("bit")

local Transform <const> = tecs.builtins.Transform
local FPS <const> = 1 / 60

-- Mock camera with configurable visible corners
local record MockCamera
    visX1: number
    visY1: number
    visX2: number
    visY2: number
end

function MockCamera:getVisibleCorners(): number, number, number, number
    return self.visX1, self.visY1, self.visX2, self.visY2
end

-- Mock pipeline resource
local record MockPipeline
    screenWidth: integer
    screenHeight: integer
    virtualWidth: integer
    virtualHeight: integer
    screenSpaceMask: integer
    virtualCoordsMask: integer
    _camera: MockCamera
end

function MockPipeline:getCamera(): MockCamera
    return self._camera
end

local function newMockPipeline(opts: {string: any}): MockPipeline
    local screenW = (opts.screenWidth or 1280) as integer
    local screenH = (opts.screenHeight or 720) as integer
    local virtualW = (opts.virtualWidth or 480) as integer
    local virtualH = (opts.virtualHeight or 270) as integer
    local cam = opts.camera as MockCamera or {
        visX1 = 0, visY1 = 0, visX2 = 800, visY2 = 600
    } as MockCamera
    setmetatable(cam, { __index = MockCamera })
    local p: MockPipeline = {
        screenWidth = screenW,
        screenHeight = screenH,
        virtualWidth = virtualW,
        virtualHeight = virtualH,
        screenSpaceMask = 0,
        virtualCoordsMask = 0,
        _camera = cam
    }
    setmetatable(p, { __index = MockPipeline })
    return p
end

-- Configure layer bitmasks on mock pipeline (mirrors pipeline.tl logic)
local function configureLayer(p: MockPipeline, layer: integer, space: string)
    local bitIndex = layer - 1
    local layerBit = bit.lshift(1, bitIndex)
    local notBit = bit.bnot(layerBit)

    if space == "world" then
        p.screenSpaceMask = bit.band(p.screenSpaceMask, notBit)
        p.virtualCoordsMask = bit.band(p.virtualCoordsMask, notBit)
    elseif space == "virtual" then
        p.screenSpaceMask = bit.bor(p.screenSpaceMask, layerBit)
        p.virtualCoordsMask = bit.bor(p.virtualCoordsMask, layerBit)
    elseif space == "screen" then
        p.screenSpaceMask = bit.bor(p.screenSpaceMask, layerBit)
        p.virtualCoordsMask = bit.band(p.virtualCoordsMask, notBit)
    end
end

local function setupWorld(mockPipeline: MockPipeline): tecs.World
    local w = tecs.newWorld()
    -- Use rawset to bypass the typed Context __newindex
    rawset(w.resources as {string: any}, pipeline_key.PIPELINE, mockPipeline)
    Anchor.plugin(w)
    return w
end

local function tick(w: tecs.World)
    w:commit()
    w:update(FPS)
end

describe("Anchor", function()
    describe("screen-space", function()
        it("positions at top-left corner", function()
            local p = newMockPipeline({ screenWidth = 1280, screenHeight = 720 })
            configureLayer(p, 16, "screen")
            local w = setupWorld(p)

            local e = w:spawn(Transform(0, 0, 0, 16), Anchor(0, 0, 0, 0))
            tick(w)

            local t = w:get(e, Transform)
            luassert.are_equal(0, t.x)
            luassert.are_equal(0, t.y)
        end)

        it("positions at bottom-right corner", function()
            local p = newMockPipeline({ screenWidth = 1280, screenHeight = 720 })
            configureLayer(p, 16, "screen")
            local w = setupWorld(p)

            local e = w:spawn(Transform(0, 0, 0, 16), Anchor(1, 1, 0, 0))
            tick(w)

            local t = w:get(e, Transform)
            luassert.are_equal(1280, t.x)
            luassert.are_equal(720, t.y)
        end)

        it("positions at center", function()
            local p = newMockPipeline({ screenWidth = 1280, screenHeight = 720 })
            configureLayer(p, 16, "screen")
            local w = setupWorld(p)

            local e = w:spawn(Transform(0, 0, 0, 16), Anchor(0.5, 0.5, 0, 0))
            tick(w)

            local t = w:get(e, Transform)
            luassert.are_equal(640, t.x)
            luassert.are_equal(360, t.y)
        end)

        it("applies pixel offsets", function()
            local p = newMockPipeline({ screenWidth = 1280, screenHeight = 720 })
            configureLayer(p, 16, "screen")
            local w = setupWorld(p)

            local e = w:spawn(Transform(0, 0, 0, 16), Anchor(0, 1, 20, -200))
            tick(w)

            local t = w:get(e, Transform)
            luassert.are_equal(20, t.x)
            luassert.are_equal(520, t.y)
        end)
    end)

    describe("virtual-space", function()
        it("uses virtual dimensions", function()
            local p = newMockPipeline({
                screenWidth = 1280, screenHeight = 720,
                virtualWidth = 480, virtualHeight = 270
            })
            configureLayer(p, 8, "virtual")
            local w = setupWorld(p)

            local e = w:spawn(Transform(0, 0, 0, 8), Anchor(1, 1, 0, 0))
            tick(w)

            local t = w:get(e, Transform)
            luassert.are_equal(480, t.x)
            luassert.are_equal(270, t.y)
        end)

        it("centers correctly in virtual space", function()
            local p = newMockPipeline({
                screenWidth = 1920, screenHeight = 1080,
                virtualWidth = 320, virtualHeight = 180
            })
            configureLayer(p, 4, "virtual")
            local w = setupWorld(p)

            local e = w:spawn(Transform(0, 0, 0, 4), Anchor(0.5, 0.5, 10, -5))
            tick(w)

            local t = w:get(e, Transform)
            luassert.are_equal(170, t.x)
            luassert.are_equal(85, t.y)
        end)
    end)

    describe("world-space", function()
        it("uses camera visible bounds", function()
            local cam: MockCamera = { visX1 = 100, visY1 = 200, visX2 = 900, visY2 = 800 }
            setmetatable(cam, { __index = MockCamera })
            local p = newMockPipeline({ camera = cam as any })
            configureLayer(p, 2, "world")
            local w = setupWorld(p)

            local e = w:spawn(Transform(0, 0, 0, 2), Anchor(0, 0, 0, 0))
            tick(w)

            local t = w:get(e, Transform)
            luassert.are_equal(100, t.x)
            luassert.are_equal(200, t.y)
        end)

        it("anchors to bottom-right of camera view", function()
            local cam: MockCamera = { visX1 = 100, visY1 = 200, visX2 = 900, visY2 = 800 }
            setmetatable(cam, { __index = MockCamera })
            local p = newMockPipeline({ camera = cam as any })
            configureLayer(p, 2, "world")
            local w = setupWorld(p)

            local e = w:spawn(Transform(0, 0, 0, 2), Anchor(1, 1, -10, -10))
            tick(w)

            local t = w:get(e, Transform)
            luassert.are_equal(890, t.x)
            luassert.are_equal(790, t.y)
        end)

        it("re-resolves when camera moves", function()
            local cam: MockCamera = { visX1 = 0, visY1 = 0, visX2 = 800, visY2 = 600 }
            setmetatable(cam, { __index = MockCamera })
            local p = newMockPipeline({ camera = cam as any })
            configureLayer(p, 1, "world")
            local w = setupWorld(p)

            local e = w:spawn(Transform(0, 0, 0, 1), Anchor(0.5, 0.5, 0, 0))
            tick(w)

            local t = w:get(e, Transform)
            luassert.are_equal(400, t.x)
            luassert.are_equal(300, t.y)

            -- Move camera
            cam.visX1 = 500
            cam.visY1 = 300
            cam.visX2 = 1300
            cam.visY2 = 900
            tick(w)

            t = w:get(e, Transform)
            luassert.are_equal(900, t.x)
            luassert.are_equal(600, t.y)
        end)
    end)

    describe("standalone usage", function()
        it("works without LayoutBox", function()
            local p = newMockPipeline({ screenWidth = 800, screenHeight = 600 })
            configureLayer(p, 16, "screen")
            local w = setupWorld(p)

            local e = w:spawn(Transform(0, 0, 0, 16), Anchor(0.5, 0, 0, 10))
            tick(w)

            local t = w:get(e, Transform)
            luassert.are_equal(400, t.x)
            luassert.are_equal(10, t.y)
        end)

        it("preserves z and layer on transform", function()
            local p = newMockPipeline({ screenWidth = 800, screenHeight = 600 })
            configureLayer(p, 5, "screen")
            local w = setupWorld(p)

            local e = w:spawn(Transform(999, 999, 42, 5), Anchor(0, 0, 10, 20))
            tick(w)

            local t = w:get(e, Transform)
            luassert.are_equal(10, t.x)
            luassert.are_equal(20, t.y)
            luassert.are_equal(42, t.z)
            luassert.are_equal(5, t.layer)
        end)
    end)
end)
