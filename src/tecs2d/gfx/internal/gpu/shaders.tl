--- GLSL shader utilities for GPU instanced rendering.
---
--- Provides loader functions and common include strings. Shape modules load
--- their own shape-specific shaders and call insertAfterPragma to inject
--- shared include strings (RENDER_COMMON, CULL_COMMON, TILE_COMMON) at the
--- top of the source. Shared shaders (lighting, shadow blur, cpu_world,
--- light_cull, bloom) are loaded eagerly at require time because they are
--- always needed by the pipeline.
---
--- Note: TILE_COMMON is loaded from the tilechunk subsystem and exported
--- here because both the tilechunk render shader and the tilechunk shadow
--- mask shader need it. This is a deliberate coupling, not an accident.

local record shaders
    --- Load a shader source file from disk
    loadShader: function(name: string, basePath?: string): string

    --- Load a render shader with layer filtering code inserted after pragma
    loadRenderShader: function(name: string, basePath?: string): string

    --- Load a cull shader with common code prepended
    loadCullShader: function(name: string, basePath?: string): string

    --- Insert content after the #pragma line of a shader
    insertAfterPragma: function(shader: string, content: string): string

    --- Common include strings (for special assembly)
    DEPTH_COMMON: string
    RENDER_COMMON: string
    CULL_COMMON: string
    TILE_COMMON: string

    --- Shared shader sources (not owned by any shape module)
    LIGHTING: string
    SHADOW_BLUR: string
    CPU_WORLD: string
    LIGHT_CULL: string
    BLOOM_DOWNSAMPLE: string
    BLOOM_UPSAMPLE: string
end

-- Default shader base path
local GPU_SHADERS <const> = "tecs2d/gfx/internal/gpu/shaders/"
local TILECHUNK_SHADERS <const> = "tecs2d/gfx/internal/tilechunk/"

-- Load shader source from file
function shaders.loadShader(name: string, basePath?: string): string
    local path = (basePath or GPU_SHADERS) .. name .. ".glsl"
    local contents, sizeOrErr = love.filesystem.read(path)
    if not contents then
        error("Failed to load shader '" .. path .. "': " .. tostring(sizeOrErr))
    end
    return contents
end

-- Load common include strings
shaders.DEPTH_COMMON = shaders.loadShader("depth_common")
shaders.CULL_COMMON = shaders.loadShader("cull_common") .. "\n" .. shaders.DEPTH_COMMON
shaders.RENDER_COMMON = shaders.loadShader("render_common")
shaders.TILE_COMMON = shaders.loadShader("tile_common", TILECHUNK_SHADERS)

-- Insert content immediately after the last #pragma directive at the top
-- of a shader. Scans line-by-line from the start, skipping past any
-- comments, blank lines, and #pragma lines, and injects at the first line
-- that isn't one of those. Falls back to prepending if no such boundary
-- is found. This lets shaders with leading comments or multiple #pragmas
-- still receive shared include code in a valid position.
function shaders.insertAfterPragma(shader: string, content: string): string
    local pos = 1
    local len = #shader
    local insertAt = 1
    while pos <= len do
        local nl = shader:find("\n", pos, true) or (len + 1)
        local line = shader:sub(pos, nl - 1)
        local trimmed = line:match("^%s*(.-)%s*$") or ""
        if trimmed == ""
                or trimmed:sub(1, 2) == "//"
                or trimmed:sub(1, 7) == "#pragma"
                or trimmed:sub(1, 8) == "#version"
                or trimmed:sub(1, 9) == "#extension" then
            -- Skip past this line; insertion point moves to the char after.
            insertAt = nl + 1
            pos = nl + 1
        else
            break
        end
    end
    return shader:sub(1, insertAt - 1) .. content .. shader:sub(insertAt)
end

-- Load a cull shader with common code prepended
function shaders.loadCullShader(name: string, basePath?: string): string
    return shaders.CULL_COMMON .. shaders.loadShader(name, basePath)
end

-- Load a render shader with layer filtering code inserted after pragma
function shaders.loadRenderShader(name: string, basePath?: string): string
    return shaders.insertAfterPragma(shaders.loadShader(name, basePath), shaders.RENDER_COMMON)
end

-- Load shared shader sources (not owned by any shape module)
shaders.LIGHTING = shaders.loadShader("lighting")
shaders.SHADOW_BLUR = shaders.loadShader("shadow_blur")
shaders.CPU_WORLD = shaders.loadShader("cpu_world")
shaders.LIGHT_CULL = shaders.loadShader("light_cull")
shaders.BLOOM_DOWNSAMPLE = shaders.loadShader("bloom_downsample")
shaders.BLOOM_UPSAMPLE = shaders.loadShader("bloom_upsample")

return shaders
