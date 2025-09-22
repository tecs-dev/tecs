--- Material variant compiler.
--- Takes a shape type's base render shader source, injects the user's material() function,
--- and compiles a variant shader. Variants are compiled lazily and cached.

local registry <const> = require("tecs2d.gfx.internal.material_registry")
local StringBuffer <const> = require("string.buffer")

local lg <const> = love.graphics

-- Shape types that support materials. Derived from CALL_SITE keys below
-- so there is a single source of truth; add a new shape once by adding
-- its CALL_SITE entry.

local record material_compiler
    --- Compile or retrieve a cached variant shader for a material + shape type.
    --- Returns nil if the material or shape type is invalid.
    compile: function(materialId: integer, shapeType: string): love.graphics.Shader

    --- Precompile all registered materials for all shape types.
    --- Call during a loading screen to avoid first-frame compilation hitches.
    precompileAll: function()

    --- Get the base render shader source for a shape type.
    getBaseSource: function(shapeType: string): string

    --- Register the base render shader source for a shape type.
    --- Called by each shape module after loading its render shader source.
    registerBaseSource: function(shapeType: string, source: string)
end

-- Load material_common.glsl content (cached)
local materialCommonSource: string
local function getMaterialCommon(): string
    if not materialCommonSource then
        local contents = love.filesystem.read(
            "tecs2d/gfx/internal/gpu/shaders/material_common.glsl")
        if not contents then
            error("Failed to load material_common.glsl")
        end
        materialCommonSource = contents
    end
    return materialCommonSource
end

-- Dynamic map of shape type to shader source (populated by each shape module via registerBaseSource)
local baseSourceMap: {string: string} = {}

function material_compiler.registerBaseSource(shapeType: string, source: string)
    baseSourceMap[shapeType] = source
end

function material_compiler.getBaseSource(shapeType: string): string
    return baseSourceMap[shapeType]
end

-- Per-shape-type GLSL that populates MaterialInput fields and the _std
-- MaterialOutput (used by standardMaterial()). The _std output captures the
-- shape's standard G-buffer values so custom materials can build on them.
local CALL_SITE <const>: {string: string} = {
    rectangle = [[
    mi.color = vec4(vColor.rgb, vColor.a * alpha);
    mi.uv = (vLocalPos / vHalfSize) * 0.5 + 0.5;
    mi.worldPos = vWorldPos;
    mi.localPos = (vLocalPos / vHalfSize) * 0.5 + 0.5;
    mi.sdfDist = dist;
    _std.albedo = mi.color;
    _std.normal = vec3(0.5, 0.5, 1.0);
    _std.lit = litMarker;
    _std.orm = vec4(1.0, 0.5, 0.0, 1.0);
    _std.emission = vec4(0.0);
]],
    circle = [[
    mi.color = vec4(vColor.rgb, vColor.a * alpha);
    mi.uv = (vLocalPos + 1.0) * 0.5;
    mi.worldPos = vWorldPos;
    mi.localPos = (vLocalPos + 1.0) * 0.5;
    mi.sdfDist = dist - 1.0;
    _std.albedo = mi.color;
    _std.normal = normal * 0.5 + 0.5;
    _std.lit = litMarker;
    _std.orm = vec4(1.0, 0.5, 0.0, 1.0);
    _std.emission = vec4(0.0);
]],
    ellipse = [[
    mi.color = vec4(vColor.rgb, vColor.a * alpha);
    mi.uv = (vLocalPos + 1.0) * 0.5;
    mi.worldPos = vWorldPos;
    mi.localPos = (vLocalPos + 1.0) * 0.5;
    mi.sdfDist = dist - 1.0;
    _std.albedo = mi.color;
    _std.normal = normal * 0.5 + 0.5;
    _std.lit = litMarker;
    _std.orm = vec4(1.0, 0.5, 0.0, 1.0);
    _std.emission = vec4(0.0);
]],
    arc = [[
    mi.color = vec4(vColor.rgb, vColor.a * alpha);
    mi.uv = (vLocalPos + 1.0) * 0.5;
    mi.worldPos = vWorldPos;
    mi.localPos = (vLocalPos + 1.0) * 0.5;
    mi.sdfDist = dist - 1.0;
    _std.albedo = mi.color;
    _std.normal = normal * 0.5 + 0.5;
    _std.lit = litMarker;
    _std.orm = vec4(1.0, 0.5, 0.0, 1.0);
    _std.emission = vec4(0.0);
]],
    line = [[
    mi.color = vec4(vColor.rgb, vColor.a * alpha);
    vec2 pa_m = vWorldPos - vP1;
    vec2 ba_m = vP2 - vP1;
    float len2_m = dot(ba_m, ba_m);
    float t_m = clamp(dot(pa_m, ba_m) / len2_m, 0.0, 1.0);
    mi.uv = vec2(t_m, 0.5 + dist / vLineWidth);
    mi.worldPos = vWorldPos;
    mi.localPos = mi.uv;
    mi.sdfDist = dist - halfWidth;
    _std.albedo = mi.color;
    _std.normal = vec3(0.5, 0.5, 1.0);
    _std.lit = litMarker;
    _std.orm = vec4(1.0, 0.5, 0.0, 1.0);
    _std.emission = vec4(0.0);
]],
    sprite = [[
    mi.color = finalColor;
    mi.uv = vTexCoord;
    mi.worldPos = vWorldPos;
    mi.localPos = vTexCoord;
    mi.sdfDist = 0.0;
    _std.albedo = finalColor;
    _std.normal = normal;
    _std.lit = litMarker;
    _std.orm = orm;
    _std.emission = emission;
]],
    text = [[
    mi.color = finalColor;
    mi.uv = vTexCoord.xy;
    mi.worldPos = vWorldPos;
    mi.localPos = vTexCoord.xy;
    mi.sdfDist = sdfDist;
    _std.albedo = finalColor;
    _std.normal = vec3(0.5, 0.5, 1.0);
    _std.lit = litMarker;
    _std.orm = vec4(1.0, 0.5, 0.0, 1.0);
    _std.emission = vec4(0.0);
]],
}

-- Derived list of supported shape types, computed from CALL_SITE keys.
local ALL_SHAPE_TYPES <const>: {string} = {}
do
    for shape in pairs(CALL_SITE) do
        ALL_SHAPE_TYPES[#ALL_SHAPE_TYPES + 1] = shape
    end
end

local CALL_SITE_TAIL <const> = [[
    mi.time = GlobalTime;
    mi.params = vMaterialParams;

    MaterialOutput mo = material(mi);
    love_Canvases[0] = mo.albedo;
    love_Canvases[1] = vec4(mo.normal, mo.lit);
    love_Canvases[2] = mo.orm;
    love_Canvases[3] = mo.emission;
    love_Canvases[4] = vec4(floor(gl_FragCoord.z * 255.0) / 255.0, fract(gl_FragCoord.z * 255.0), 0.0, 1.0); // Depth (16-bit RG)
]]

-- Unlit material wrapper: injects user fragment source into a forced-unlit material() function
local UNLIT_WRAPPER <const> = [[
MaterialOutput material(MaterialInput i) {
    MaterialOutput o = standardMaterial(i);
    %s
    o.lit = 0.0;
    return o;
}
]]

-- SSBO declarations injected before #ifdef VERTEX
local SSBO_DECL <const> = [[

// Material params SSBO (per-entity material parameters)
layout(std430) readonly buffer MaterialParamsBuffer {
    vec4 materialParams[];
};
uniform float GlobalTime;
varying vec4 vMaterialParams;

]]

-- Reusable buffer for building variant source
local buf <const> = StringBuffer.new(8192)

-- Emit the material call site GLSL for a given shape type
local function putCallSite(b: StringBuffer, shapeType: string)
    local site = CALL_SITE[shapeType]
    if not site then
        error("material_compiler: no CALL_SITE for shape type '" .. shapeType .. "'")
    end
    b:put("    MaterialInput mi;\n", site, CALL_SITE_TAIL)
end

-- Default no-op materialVertex for materials without a vertex function.
local DEFAULT_VERTEX_FUNC <const> = [[
vec2 materialVertex(vec2 worldPos, float time, vec4 params) {
    return worldPos;
}
]]

-- Build the material variant source in a single forward pass through baseSource.
-- Finds all injection points first, then assembles with StringBuffer.
local function buildVariantSource(baseSource: string, def: registry.MaterialDef, shapeType: string): string
    local materialCommon = getMaterialCommon()

    local beginMarker <const> = "// -- MATERIAL_BEGIN --"
    local endMarker <const> = "// -- MATERIAL_END --"
    local vtxMarker <const> = "// -- VERTEX_MATERIAL --"

    -- Find all injection points in the original base source
    local vertexPos = baseSource:find("#ifdef VERTEX", 1, true)
    local vtxMatPos = baseSource:find(vtxMarker, 1, true)
    local returnPos = baseSource:find("return result;", 1, true)
    local pixelPos = baseSource:find("#ifdef PIXEL", 1, true)
    local beginPos = baseSource:find(beginMarker, 1, true)
    local endPos = baseSource:find(endMarker, 1, true)

    -- Validate all required markers. If any are missing, the base shader
    -- has drifted from the expected shape and injection would silently
    -- produce garbage source. Fail loudly.
    if not beginPos or not endPos then
        error("Render shader for '" .. shapeType
            .. "' is missing MATERIAL_BEGIN/MATERIAL_END markers")
    end
    if not vertexPos then
        error("Render shader for '" .. shapeType .. "' is missing '#ifdef VERTEX'")
    end
    if not pixelPos then
        error("Render shader for '" .. shapeType .. "' is missing '#ifdef PIXEL'")
    end
    if not returnPos then
        error("Render shader for '" .. shapeType .. "' is missing 'return result;' in vertex section")
    end

    local endLinePos = baseSource:find("\n", endPos, true)
    if not endLinePos then
        endLinePos = #baseSource
    end

    local hasVertexMaterial = def.vertexSource ~= nil

    -- Precompute the material params index expression once (text uses
    -- vg.headerIndex, everything else uses instanceID). Avoids drift.
    local paramsIndexExpr = shapeType == "text" and "vg.headerIndex" or "instanceID"

    -- Build the result in a single forward pass
    buf:reset()

    -- [start .. #ifdef VERTEX)
    buf:put(baseSource:sub(1, vertexPos - 1))

    -- Inject SSBO declarations before #ifdef VERTEX
    buf:put(SSBO_DECL)

    -- Inject materialVertex() function declaration (before #ifdef VERTEX body)
    if hasVertexMaterial then
        buf:put("\n// Vertex material function\n", def.vertexSource, "\n")
    else
        buf:put("\n", DEFAULT_VERTEX_FUNC)
    end

    if vtxMatPos then
        -- [#ifdef VERTEX .. VERTEX_MATERIAL marker)
        buf:put(baseSource:sub(vertexPos, vtxMatPos - 1))

        -- Inject materialVertex call at the marker
        buf:put(vtxMarker, "\n")
        buf:put("    {\n")
        buf:put("        vec4 _mvp = materialParams[", paramsIndexExpr, "];\n")
        buf:put("        worldPos = materialVertex(worldPos, GlobalTime, _mvp);\n")
        buf:put("    }\n")

        -- Find end of marker line
        local vtxMarkerEnd = baseSource:find("\n", vtxMatPos, true)
        if not vtxMarkerEnd then vtxMarkerEnd = vtxMatPos + #vtxMarker end

        -- [after VERTEX_MATERIAL line .. return result;)
        buf:put(baseSource:sub(vtxMarkerEnd + 1, returnPos - 1))
    else
        -- No VERTEX_MATERIAL marker: [#ifdef VERTEX .. return result;)
        buf:put(baseSource:sub(vertexPos, returnPos - 1))
    end

    -- Inject params read before "return result;"
    buf:put("    vMaterialParams = materialParams[", paramsIndexExpr, "];\n    ")

    -- [return result; .. #ifdef PIXEL)
    buf:put(baseSource:sub(returnPos, pixelPos - 1))

    -- Inject material structs and user's material() function
    buf:put("\n// Material system definitions\n", materialCommon, "\n")
    local fragmentSource = def.fragmentSource
    if not def.unlit then
        buf:put(fragmentSource, "\n")
    else
        buf:putf(UNLIT_WRAPPER, fragmentSource)
    end

    buf:put("\n")

    -- [#ifdef PIXEL .. MATERIAL_BEGIN)
    buf:put(baseSource:sub(pixelPos, beginPos - 1))

    -- Replacement: marker + call site + end marker
    buf:put(beginMarker, "\n")
    putCallSite(buf, shapeType)
    buf:put("    ", endMarker, "\n")

    -- [after MATERIAL_END line .. end]
    buf:put(baseSource:sub(endLinePos + 1))

    return buf:get()
end

function material_compiler.compile(materialId: integer, shapeType: string): love.graphics.Shader
    -- Check cache first
    local cached = registry.getVariant(materialId, shapeType)
    if cached then
        return cached
    end

    local def = registry.getById(materialId)
    if not def then
        return nil
    end

    local baseSource = material_compiler.getBaseSource(shapeType)
    if not baseSource then
        return nil
    end

    -- Load textures if not already loaded
    registry.loadTextures(def)

    -- Build variant source
    local variantSource = buildVariantSource(baseSource, def, shapeType)

    -- Compile the shader
    local ok, shaderOrErr = pcall(function(): love.graphics.Shader
        return lg.newShader(variantSource)
    end)
    if not ok then
        error("Failed to compile material variant '" .. def.name
            .. "' for shape '" .. shapeType .. "': " .. tostring(shaderOrErr))
    end

    local shader = shaderOrErr as love.graphics.Shader

    -- Cache the compiled variant
    registry.setVariant(materialId, shapeType, shader)

    return shader
end

function material_compiler.precompileAll()
    local allDefs = registry.getAll()
    for _, def in pairs(allDefs) do
        for _, shapeType in ipairs(ALL_SHAPE_TYPES) do
            material_compiler.compile(def.id, shapeType)
        end
    end
end

return material_compiler
