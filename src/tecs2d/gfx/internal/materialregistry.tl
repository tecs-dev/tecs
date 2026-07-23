--- Material registry: singleton that maps material names to IDs and stores definitions.
--- Each material has a unique ID (1-255), fragment shader source, optional textures,
--- and lazily-compiled shader variants per shape type.

local Material <const> = require("tecs2d.gfx.internal.Material")
local devicestate <const> = require("tecs2d.gfx.internal.gpu.devicestate")

local record material_registry
    --- A registered material definition.
    record MaterialDef
        --- Unique ID (1-255)
        id: integer
        --- User-facing name
        name: string
        --- Path to the .glsl fragment file
        fragmentPath: string
        --- Raw GLSL source of the user's material() function
        fragmentSource: string
        --- Path to the .glsl vertex file (optional)
        vertexPath: string
        --- Raw GLSL source of the user's materialVertex() function (optional)
        vertexSource: string
        --- Map of uniform name to image path
        texturePaths: {string: string}
        --- Loaded textures (lazily populated when first used with love.graphics)
        textures: {string: love.graphics.Texture}
        --- If true, the material forces unlit rendering
        unlit: boolean
        --- Compiled shader variants per shape type (lazily populated)
        variants: {string: love.graphics.Shader}
    end

    --- Options for registering a material.
    record MaterialOpts
        --- Path to .glsl file or inline GLSL source for the material() function (optional).
        --- Strings ending in ".glsl" are loaded from file; otherwise treated as source.
        --- If omitted, defaults to standardMaterial(i). At least one of fragment or vertex
        --- must be provided.
        fragment: string
        --- Path to .glsl file or inline GLSL source for materialVertex() (optional).
        --- Same path-vs-inline detection as fragment.
        vertex: string
        --- Map of uniform name to texture path (up to 4 textures)
        textures: {string: string}
        --- If true, wraps fragment to force lit = 0.0
        unlit: boolean
    end

    --- Register a new material and return a Material component value ready for use.
    --- @param name Unique name for this material
    --- @param opts Material options (fragment path, textures, etc.)
    --- @return Material component value with the assigned materialId
    register: function(name: string, opts: MaterialOpts): Material

    --- Get a material definition by ID.
    getById: function(id: integer): MaterialDef

    --- Get a material definition by name.
    getByName: function(name: string): MaterialDef

    --- Get all registered material definitions.
    --- INTERNAL: returns the live table for efficiency. Do not mutate.
    --- Callers should only iterate with `pairs()`.
    getAll: function(): {integer: MaterialDef}

    --- Get or set a compiled shader variant for a material + shape type combination.
    getVariant: function(materialId: integer, shapeType: string): love.graphics.Shader
    setVariant: function(materialId: integer, shapeType: string, shader: love.graphics.Shader)

    --- Load textures for a material definition (call when love.graphics is available).
    loadTextures: function(def: MaterialDef)
end

local record RegistryState
    nextId: integer
    byId: {integer: material_registry.MaterialDef}
    byName: {string: material_registry.MaterialDef}
end

local deviceState <const> = devicestate.get()
local registry = deviceState.materialRegistry as RegistryState
if not registry then
    registry = {
        nextId = 1,
        byId = {},
        byName = {},
    }
    deviceState.materialRegistry = registry
end

-- Read a GLSL source file, trying io.open first then love.filesystem.
local function readGlslFile(path: string): string
    local f = io.open(path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        return content
    end
    -- Try love.filesystem if io.open fails
    local ok, content = pcall(function(): string
        return (love.filesystem.read as function(string): string)(path)
    end)
    if ok and content then
        return content
    end
    return nil
end

-- Returns true if the string looks like a file path (ends with .glsl).
local function isFilePath(s: string): boolean
    return s:sub(-5) == ".glsl"
end

-- Resolve a shader string: if it ends with .glsl, load from file; otherwise treat as inline source.
local function resolveShaderSource(s: string, label: string): string, string
    if isFilePath(s) then
        local source = readGlslFile(s)
        if not source then
            error("Cannot read material " .. label .. " file: " .. s)
        end
        return source, s
    end
    return s, nil
end

-- Default fragment source when none is provided (vertex-only materials).
local DEFAULT_FRAGMENT <const> = [[
MaterialOutput material(MaterialInput i) {
    return standardMaterial(i);
}
]]

function material_registry.register(name: string, opts: material_registry.MaterialOpts): Material
    assert(name, "Material name is required")
    assert(opts, "Material options are required")
    assert(opts.fragment or opts.vertex, "Material must have at least a fragment or vertex source")
    assert(not registry.byName[name], "Material '" .. name .. "' is already registered")
    assert(registry.nextId <= 255, "Maximum of 255 materials exceeded")

    local id = registry.nextId
    registry.nextId = registry.nextId + 1

    local fragmentSource: string
    local fragmentPath: string
    if opts.fragment then
        fragmentSource, fragmentPath = resolveShaderSource(opts.fragment, "fragment")
    else
        fragmentSource = DEFAULT_FRAGMENT
    end

    local vertexSource: string
    local vertexPath: string
    if opts.vertex then
        vertexSource, vertexPath = resolveShaderSource(opts.vertex, "vertex")
    end

    -- Copy texture paths so caller mutations don't affect the registry.
    local texturePaths: {string: string} = {}
    if opts.textures then
        for k, v in pairs(opts.textures) do
            texturePaths[k] = v
        end
    end

    local def: material_registry.MaterialDef = {
        id = id,
        name = name,
        fragmentPath = fragmentPath,
        fragmentSource = fragmentSource,
        vertexPath = vertexPath,
        vertexSource = vertexSource,
        texturePaths = texturePaths,
        textures = {},
        unlit = opts.unlit or false,
        variants = {},
    }

    registry.byId[id] = def
    registry.byName[name] = def

    return Material(id)
end

function material_registry.getById(id: integer): material_registry.MaterialDef
    return registry.byId[id]
end

function material_registry.getByName(name: string): material_registry.MaterialDef
    return registry.byName[name]
end

function material_registry.getAll(): {integer: material_registry.MaterialDef}
    return registry.byId
end

function material_registry.getVariant(materialId: integer, shapeType: string): love.graphics.Shader
    local def = registry.byId[materialId]
    if not def then return nil end
    return def.variants[shapeType]
end

function material_registry.setVariant(materialId: integer, shapeType: string, shader: love.graphics.Shader)
    local def = registry.byId[materialId]
    if not def then return end
    def.variants[shapeType] = shader
end

function material_registry.loadTextures(def: material_registry.MaterialDef)
    for uniformName, path in pairs(def.texturePaths) do
        if not def.textures[uniformName] then
            def.textures[uniformName] = love.graphics.newImage(path) as love.graphics.Texture
        end
    end
end

return material_registry
