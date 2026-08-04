-- Shared mechanics for specs that inspect real GPU output. This deliberately
-- stops below pass construction: individual specs keep the renderer details
-- whose behavior they are proving.

local sdl = require("tecs.ffi.sdl3")
local newWindow = require("tecs.platform.window").newWindow
local Device = require("tecs.gpu.Device")
local Texture = require("tecs.gpu.Texture")

local C = sdl.C
local DEFAULT_FORMAT = 4 -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM

local render = {}

local function fail(message)
    error(message, 3)
end

function render.assertDriver(device)
    local actual = tostring(device.driver):lower()
    local expected = os.getenv("TECS_EXPECT_GPU_DRIVER")
    if expected ~= nil and expected ~= "" and actual ~= expected:lower() then
        fail(("expected SDL GPU driver %q, selected %q"):format(expected, actual))
    end
    return actual
end

function render.open(options)
    options = options or {}
    local width = options.width or 64
    local height = options.height or width
    if not C.SDL_Init(sdl.K.SDL_INIT_VIDEO) then
        fail("SDL video initialization failed: " .. sdl.error())
    end

    local context = {
        width = width,
        height = height,
        format = options.format or DEFAULT_FORMAT,
    }
    local ok, reason = pcall(function()
        context.window = newWindow({
            title = options.title or "render spec",
            width = width,
            height = height,
            highPixelDensity = false,
            resizable = false,
        })
        context.device = Device.create(context.window, {
            debug = options.debug ~= false,
            driver = options.driver,
        })
        context.driver = render.assertDriver(context.device)
        if options.target ~= false then
            context.target = Texture.create(context.device.handle, {
                width = width,
                height = height,
                format = context.format,
            })
        end
    end)
    if not ok then
        if context.target then
            context.target:destroy()
        end
        if context.device then
            context.device:destroy()
        end
        if context.window then
            context.window:destroy()
        end
        C.SDL_Quit()
        error(reason, 0)
    end
    return context
end

function render.close(context)
    if context == nil then
        return
    end
    if context.target then
        context.target:destroy()
        context.target = nil
    end
    if context.device then
        context.device:destroy()
        context.device = nil
    end
    if context.window then
        context.window:destroy()
        context.window = nil
    end
    C.SDL_Quit()
end

function render.frame(context, world, renderer, options)
    options = options or {}
    local target = options.target or context.target
    local width = options.width or target.width
    local height = options.height or target.height
    world:update(options.delta or 1 / 60)
    local commandBuffer = C.SDL_AcquireGPUCommandBuffer(context.device.handle)
    if commandBuffer == nil then
        fail("could not acquire a GPU command buffer on " .. context.driver)
    end
    renderer:render({
        width = width,
        height = height,
        commandBuffer = commandBuffer,
        swapchainTexture = target.handle,
    })
    if not C.SDL_SubmitGPUCommandBuffer(commandBuffer) then
        fail("could not submit a GPU command buffer on " .. context.driver)
    end
    return target:readback()
end

local function rectangle(texture, area)
    area = area or {}
    local x = area.x or 0
    local y = area.y or 0
    local width = area.width or texture.width
    local height = area.height or texture.height
    if x < 0 or y < 0 or width <= 0 or height <= 0 or x + width > texture.width or y + height > texture.height then
        fail(
            ("region (%d,%d %dx%d) is outside %dx%d target"):format(x, y, width, height, texture.width, texture.height)
        )
    end
    return x, y, width, height
end

function render.measure(texture, pixels, area)
    local x, y, width, height = rectangle(texture, area)
    local count = width * height
    local minimum = 255
    local maximum = 0
    local luma = 0
    local nonBlack = 0
    local red, green, blue = 0, 0, 0
    for row = y, y + height - 1 do
        for column = x, x + width - 1 do
            local pixel = texture:getPixel(pixels, column, row)
            red = red + pixel.r
            green = green + pixel.g
            blue = blue + pixel.b
            minimum = math.min(minimum, pixel.r, pixel.g, pixel.b)
            maximum = math.max(maximum, pixel.r, pixel.g, pixel.b)
            luma = luma + (pixel.r * 54 + pixel.g * 183 + pixel.b * 19) / 256
            if math.max(pixel.r, pixel.g, pixel.b) > 8 then
                nonBlack = nonBlack + 1
            end
        end
    end
    return {
        x = x,
        y = y,
        width = width,
        height = height,
        count = count,
        minChannel = minimum,
        maxChannel = maximum,
        channelRange = maximum - minimum,
        meanR = red / count,
        meanG = green / count,
        meanB = blue / count,
        meanLuma = luma / count,
        nonBlackRatio = nonBlack / count,
    }
end

function render.difference(texture, before, after, area, threshold)
    local x, y, width, height = rectangle(texture, area)
    local count = width * height
    local changed = 0
    local total = 0
    local maximum = 0
    threshold = threshold or 0
    for row = y, y + height - 1 do
        for column = x, x + width - 1 do
            local first = texture:getPixel(before, column, row)
            local second = texture:getPixel(after, column, row)
            local delta =
                math.max(math.abs(first.r - second.r), math.abs(first.g - second.g), math.abs(first.b - second.b))
            total = total + delta
            maximum = math.max(maximum, delta)
            if delta > threshold then
                changed = changed + 1
            end
        end
    end
    return {
        count = count,
        changed = changed,
        changedRatio = changed / count,
        meanDelta = total / count,
        maxDelta = maximum,
    }
end

function render.assertVisible(context, measurement, message)
    if measurement.nonBlackRatio < 0.01 or measurement.channelRange < 8 then
        fail(
            ("%s on %s: non-black %.3f%%, channel range %d, mean luma %.2f"):format(
                message or "expected visible output",
                context.driver,
                measurement.nonBlackRatio * 100,
                measurement.channelRange,
                measurement.meanLuma
            )
        )
    end
end

function render.assertChanged(context, difference, minimumRatio, message)
    minimumRatio = minimumRatio or 0.001
    if difference.changedRatio < minimumRatio then
        fail(
            ("%s on %s: %.3f%% of pixels changed, expected at least %.3f%%"):format(
                message or "expected rendered output to change",
                context.driver,
                difference.changedRatio * 100,
                minimumRatio * 100
            )
        )
    end
end

function render.assertStable(context, difference, maximumRatio, message)
    maximumRatio = maximumRatio or 0
    if difference.changedRatio > maximumRatio then
        fail(
            ("%s on %s: %.3f%% of pixels changed, expected at most %.3f%%"):format(
                message or "expected rendered output to remain stable",
                context.driver,
                difference.changedRatio * 100,
                maximumRatio * 100
            )
        )
    end
end

return render
