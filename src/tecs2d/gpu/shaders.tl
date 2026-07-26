--- The engine's GLSL, and the registry it is reached through.
---
--- Every shader the engine can ask for at run time is named here. That is what
--- makes a build packageable: the packaging step enumerates this registry, so
--- it needs no device, no window, and no world, and a shader that is not
--- listed cannot appear on a target that ships no compiler.
---
--- Keeping the sources here rather than beside the code that binds them costs
--- nothing in correctness, because the resource counts SDL_GPU is told are
--- reflected out of this text rather than declared at the binding site. The
--- binding code cannot disagree with a shader it does not describe.

local bit <const> = require("bit")

local record shaders
    --- One named shader source.
    record Entry
        --- Stable name, `<subsystem>.<what>.<stage>`. This is the key a
        --- packaged artifact is found under, so renaming one invalidates any
        --- pack built before the rename.
        name: string
        --- "vertex", "fragment", or "compute".
        stage: string
        source: string
        --- Define sets that must be baked in addition to the empty one. A
        --- variant the engine assembles at run time but does not declare here
        --- is absent from every pack, which is a failure on a target that
        --- cannot compile.
        variants: {{string: string}}
    end

    --- A source and one define set, with the key the pair is stored under.
    record Variant
        key: string
        name: string
        stage: string
        source: string
        defines: {string: string}
    end
end

local registry <const>: {string: shaders.Entry} = {}
local order <const>: {string} = {}

--- FNV-1a over the bytes, as eight hex digits.
---
--- Identifies a source, so a pack built from different text is detected rather
--- than trusted. The multiply is decomposed into shifts because the prime
--- times a 32-bit value exceeds what a double holds exactly.
function shaders.hash(text: string): string
    local h = 0x811c9dc5
    for i = 1, #text do
        h = bit.bxor(h, text:byte(i))
        h = bit.bor(0, bit.lshift(h, 24) + bit.lshift(h, 8)
            + bit.lshift(h, 7) + bit.lshift(h, 4) + bit.lshift(h, 1) + h)
    end
    return bit.tohex(h)
end

--- The key a name and define set are stored under.
---
--- Defines are sorted so the key does not depend on table order, which in Lua
--- is not the order they were written in.
function shaders.key(name: string, defines?: {string: string}): string
    if defines == nil then return name end
    local parts: {string} = {}
    for macro, value in pairs(defines) do
        parts[#parts + 1] = macro .. "=" .. value
    end
    if #parts == 0 then return name end
    table.sort(parts)
    return name .. "|" .. table.concat(parts, ",")
end

--- Registers a source under `entry.name`.
---
--- Re-registering a name replaces it, which is what a test wants when it
--- overrides an engine shader to probe a pass in isolation.
function shaders.register(entry: shaders.Entry)
    if entry.name == nil or entry.stage == nil or entry.source == nil then
        error("tecs2d: a shader entry needs a name, a stage, and a source", 2)
    end
    if registry[entry.name] == nil then
        order[#order + 1] = entry.name
    end
    registry[entry.name] = entry
end

--- Returns the entry registered under `name`.
function shaders.get(name: string): shaders.Entry
    local entry = registry[name]
    if entry == nil then
        error(("tecs2d: no shader named '%s'"):format(tostring(name)), 2)
    end
    return entry
end

--- Returns the GLSL registered under `name`.
function shaders.source(name: string): string
    return shaders.get(name).source
end

--- Every registered entry, in registration order.
function shaders.list(): {shaders.Entry}
    local list: {shaders.Entry} = {}
    for i = 1, #order do
        list[i] = registry[order[i]]
    end
    return list
end

--- Every variant of every registered entry that a pack must contain.
---
--- The empty define set always counts as a variant, since that is what the
--- engine asks for unless it is assembling a material.
function shaders.buildList(): {shaders.Variant}
    local list: {shaders.Variant} = {}
    for _, entry in ipairs(shaders.list()) do
        local sets: {{string: string}} = { {} }
        for _, defines in ipairs(entry.variants or {}) do
            sets[#sets + 1] = defines
        end
        for _, defines in ipairs(sets) do
            list[#list + 1] = {
                key = shaders.key(entry.name, defines),
                name = entry.name,
                stage = entry.stage,
                source = entry.source,
                defines = defines,
            }
        end
    end
    return list
end

-------------------------------------------------------------------------------
-- Instanced geometry
-------------------------------------------------------------------------------

--- Zeroes the visible counter before the cull accumulates into it. A separate
--- pass rather than a branch inside the cull, because invocations within one
--- dispatch have no ordering against each other.
shaders.register({
    name = "instance.reset.comp",
    stage = "compute",
    source = [[
#version 450
layout(local_size_x = 1) in;
layout(set = 1, binding = 0) writeonly buffer DrawArgs { uint value[]; } args;
void main() {
    // SDL_GPUIndexedIndirectDrawCommand: indices, instances, first index,
    // vertex offset, first instance.
    args.value[0] = 6u;   // indices per quad, over four distinct corners
    args.value[1] = 0u;   // instances, accumulated by the cull
    args.value[2] = 0u;
    args.value[3] = 0u;
    args.value[4] = 0u;
}
]],
})

--- Rejects instances outside the view and compacts the rest.
shaders.register({
    name = "instance.cull.comp",
    stage = "compute",
    source = [[
#version 450
layout(local_size_x = 64) in;

// Bounds only, never the instance. This pass runs over every entity every
// frame whether or not it draws, so it is the one place where reading 64 bytes
// to use 24 of them is the dominant cost. Sixteen bytes with the extents
// already resolved is a quarter of the traffic.
layout(set = 0, binding = 0) readonly buffer Bounds {
    vec4 item[];   // xy centre, zw half extent
} bounds;

layout(set = 1, binding = 0) buffer DrawArgs { uint value[]; } args;
layout(set = 1, binding = 1) writeonly buffer Visible { uint index[]; } visible;
layout(set = 2, binding = 0) uniform Cull { vec4 params; } cull;

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(cull.params.z)) { return; }

    vec4 box = bounds.item[i];
    if (box.x + box.z < 0.0 || box.x - box.z > cull.params.x ||
        box.y + box.w < 0.0 || box.y - box.w > cull.params.y) {
        return;
    }

    visible.index[atomicAdd(args.value[1], 1u)] = i;
}
]],
})

shaders.register({
    name = "instance.vert",
    stage = "vertex",
    source = [[
#version 450

struct Instance {
    vec4 xform;   // 2x2 basis of rotation and scale
    vec4 origin;  // xy world position, z array layer, w spare
    vec4 color;
    vec4 uvRect;  // u0 v0 u1 v1
};

layout(set = 0, binding = 0) readonly buffer Instances { Instance item[]; } instances;
layout(set = 0, binding = 1) readonly buffer Visible { uint index[]; } visible;
layout(set = 1, binding = 0) uniform View { vec4 viewport; } view;

layout(location = 0) out vec4 vColor;
layout(location = 1) out vec3 vUV;

// Four distinct corners, visited through an index buffer. A non-indexed quad
// runs the vertex shader six times for the four positions it actually has.
const vec2 CORNERS[4] = vec2[4](
    vec2(-0.5, -0.5), vec2( 0.5, -0.5),
    vec2(-0.5,  0.5), vec2( 0.5,  0.5)
);

void main() {
    // The cull compacted the survivors, so this walks the visible list rather
    // than the instance array.
    uint slot = visible.index[gl_InstanceIndex];
    Instance self = instances.item[slot];
    mat2 basis = mat2(self.xform.x, self.xform.y, self.xform.z, self.xform.w);
    vec2 corner = CORNERS[gl_VertexIndex];
    vec2 world = self.origin.xy + basis * corner;

    // World units are pixels with the origin at the top left, which is also
    // what the lighting pass works in, so light positions need no conversion.
    vec2 ndc = vec2(world.x / view.viewport.x * 2.0 - 1.0,
                    1.0 - world.y / view.viewport.y * 2.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
    vColor = self.color;

    // Corners run -0.5..0.5, and V is flipped because texture rows run down
    // from the top while the quad's local Y runs up.
    vUV = vec3(mix(self.uvRect.xy, self.uvRect.zw,
                   vec2(corner.x + 0.5, 0.5 - corner.y)),
               self.origin.z);
}
]],
})

shaders.register({
    name = "instance.frag",
    stage = "fragment",
    source = [[
#version 450
layout(location = 0) in vec4 vColor;
layout(location = 1) in vec3 vUV;
layout(location = 0) out vec4 albedo;
layout(location = 1) out vec4 normal;

layout(set = 2, binding = 0) uniform sampler2DArray images;

void main() {
    // Untextured geometry samples layer zero, so both paths land here.
    albedo = texture(images, vUV) * vColor;
    normal = vec4(0.5, 0.5, 1.0, 1.0);
}
]],
})

-------------------------------------------------------------------------------
-- Deferred passes
-------------------------------------------------------------------------------

--- Emits a fullscreen triangle and the UV to sample a full-target texture.
---
--- The V coordinate is flipped against the NDC Y: NDC +Y is up while texture
--- V runs down from the top-left, so a pass that samples its input without
--- this correction produces a vertically mirrored image, which reads as a
--- content bug rather than a coordinate one.
shaders.register({
    name = "deferred.fullscreen.vert",
    stage = "vertex",
    source = [[
#version 450
layout(location = 0) out vec2 vUV;
void main() {
    vec2 corner = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
    vUV = vec2(corner.x, 1.0 - corner.y);
}
]],
})

shaders.register({
    name = "deferred.lighting.frag",
    stage = "fragment",
    source = [[
#version 450

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2D gAlbedo;
layout(set = 2, binding = 1) uniform sampler2D gNormal;

struct Light {
    vec4 position;   // xy in target pixels, z height, w radius
    vec4 color;      // rgb colour, a intensity
};

layout(set = 2, binding = 2) readonly buffer Lights {
    Light item[];
} lights;

layout(set = 3, binding = 0) uniform Scene {
    vec4 ambient;      // rgb ambient colour, a unused
    vec4 viewport;     // xy target size, z light count, w unused
} scene;

void main() {
    vec4 albedo = texture(gAlbedo, vUV);

    // Normals are stored biased into unsigned range, as the G-buffer format
    // has no signed representation.
    vec3 normal = normalize(texture(gNormal, vUV).xyz * 2.0 - 1.0);

    vec2 fragment = vUV * scene.viewport.xy;
    vec3 accumulated = scene.ambient.rgb;

    int count = int(scene.viewport.z);
    for (int i = 0; i < count; i++) {
        Light light = lights.item[i];
        vec3 toLight = vec3(light.position.xy - fragment, light.position.z);
        float distance = length(toLight);
        float radius = max(light.position.w, 1.0);

        // Smooth falloff to zero at the radius so a light has bounded reach
        // and the lighting cost stays proportional to what it touches.
        float attenuation = clamp(1.0 - distance / radius, 0.0, 1.0);
        attenuation *= attenuation;

        float lambert = max(dot(normal, normalize(toLight)), 0.0);
        accumulated += light.color.rgb * light.color.a * attenuation * lambert;
    }

    outColor = vec4(albedo.rgb * accumulated, albedo.a);
}
]],
})

shaders.register({
    name = "deferred.composite.frag",
    stage = "fragment",
    source = [[
#version 450
layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;
layout(set = 2, binding = 0) uniform sampler2D litTexture;
void main() { outColor = texture(litTexture, vUV); }
]],
})

return shaders
