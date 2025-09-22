-- LÖVE2D system info dump for bug reports
-- Run with: make system-info

local output = {}

local function emit(line)
    table.insert(output, line or "")
end

local function section(name)
    emit("")
    emit("## " .. name)
end

local function kv(key, value)
    emit(string.format("- **%s**: %s", key, tostring(value)))
end


function love.load()
    emit("# LÖVE System Info")
    emit("")
    emit("```")

    -- Version
    local major, minor, revision, codename = love.getVersion()
    emit(string.format("LÖVE %d.%d.%d (%s)", major, minor, revision, codename))
    emit(string.format("OS: %s", love.system.getOS()))
    emit(string.format("Processors: %d cores", love.system.getProcessorCount()))
    emit("```")

    -- Graphics
    section("Graphics")
    local rendererName, version, vendor, device = love.graphics.getRendererInfo()
    kv("Renderer", rendererName)
    kv("Version", version)
    kv("Device", device)
    if vendor and vendor ~= "" then kv("Vendor", vendor) end

    section("Graphics Limits")
    emit("```")
    local limits = love.graphics.getSystemLimits()
    local limitOrder = {"texturesize", "texturelayers", "volumetexturesize", "cubetexturesize",
                        "multicanvas", "texturemsaa", "anisotropy", "pointsize",
                        "texelbuffersize", "shaderstoragebuffersize",
                        "threadgroupsx", "threadgroupsy", "threadgroupsz"}
    local byteFields = {texelbuffersize = true, shaderstoragebuffersize = true}
    for _, k in ipairs(limitOrder) do
        if limits[k] then
            local v = limits[k]
            if byteFields[k] and v > 1024*1024 then
                emit(string.format("%-25s %s", k, string.format("%.0f MB", v / (1024*1024))))
            else
                emit(string.format("%-25s %s", k, tostring(v)))
            end
        end
    end
    emit("```")

    section("Graphics Features")
    emit("```")
    local features = love.graphics.getSupported()
    local featureList = {}
    for k in pairs(features) do table.insert(featureList, k) end
    table.sort(featureList)
    for _, k in ipairs(featureList) do
        emit(string.format("%-25s %s", k, features[k] and "yes" or "no"))
    end
    emit("```")

    section("Texture Types")
    local types = love.graphics.getTextureTypes()
    local supported = {}
    for k, v in pairs(types) do
        if v then table.insert(supported, k) end
    end
    table.sort(supported)
    emit(table.concat(supported, ", "))

    section("Texture Formats")
    local ok, formats = pcall(love.graphics.getTextureFormats, {
        canvas = true, sample = true, computewrite = true
    })
    if ok and formats then
        local sorted = {}
        for k in pairs(formats) do table.insert(sorted, k) end
        table.sort(sorted)
        local uncompressed, compressed, depth = {}, {}, {}
        for _, f in ipairs(sorted) do
            if f:match("^depth") or f:match("^stencil") then
                table.insert(depth, f)
            elseif f:match("^[A-Z]") then
                table.insert(compressed, f)
            else
                table.insert(uncompressed, f)
            end
        end
        emit("**Uncompressed**: " .. table.concat(uncompressed, ", "))
        emit("")
        emit("**Depth/Stencil**: " .. table.concat(depth, ", "))
        emit("")
        emit("**Compressed**: " .. #compressed .. " formats supported")
    end

    -- Displays
    section("Displays")
    local displayCount = love.window.getDisplayCount()
    for i = 1, displayCount do
        local name = love.window.getDisplayName(i)
        local dw, dh = love.window.getDesktopDimensions(i)
        emit(string.format("- **Display %d**: %s (%dx%d)", i, name, dw, dh))
    end

    -- Window
    section("Window")
    local w, h, flags = love.window.getMode()
    kv("Size", w .. "x" .. h)
    kv("VSync", flags.vsync)
    kv("MSAA", flags.msaa)
    kv("High DPI", flags.highdpi)
    kv("DPI Scale", love.graphics.getDPIScale())

    -- Audio
    section("Audio")
    local devices = love.audio.getPlaybackDevices and love.audio.getPlaybackDevices() or {}
    kv("Playback devices", #devices)
    for _, dev in ipairs(devices) do
        emit(string.format("  - %s", dev))
    end
    local recDevices = love.audio.getRecordingDevices and love.audio.getRecordingDevices() or {}
    kv("Recording devices", #recDevices)

    -- Joysticks
    section("Joysticks")
    local joysticks = love.joystick.getJoysticks()
    if #joysticks == 0 then
        emit("None connected")
    else
        for _, js in ipairs(joysticks) do
            emit(string.format("- **%s** (GUID: %s)", js:getName(), js:getGUID()))
            emit(string.format("  - Gamepad: %s, Vibration: %s", tostring(js:isGamepad()), tostring(js:isVibrationSupported())))
        end
    end

    -- Filesystem
    section("Filesystem")
    kv("Save directory", love.filesystem.getSaveDirectory())
    kv("Source", love.filesystem.getSource())
    kv("Working directory", love.filesystem.getWorkingDirectory())

    -- Print all
    local text = table.concat(output, "\n")
    print(text)

    -- Copy to clipboard
    love.system.setClipboardText(text)
    print("\n---\n(Copied to clipboard)")
end

function love.draw()
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("System info dumped to console and clipboard.\nPress ESC to exit.", 10, 10)
end

function love.keypressed(key)
    if key == "escape" then
        love.event.quit()
    end
end
