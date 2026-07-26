











local bit = require("bit")

local shaders = { Entry = {}, Variant = {} }


























local registry = {}
local order = {}






function shaders.hash(text)
   local h = 0x811c9dc5
   for i = 1, #text do
      h = bit.bxor(h, text:byte(i))
      h = bit.bor(0, bit.lshift(h, 24) + bit.lshift(h, 8) +
      bit.lshift(h, 7) + bit.lshift(h, 4) + bit.lshift(h, 1) + h)
   end
   return bit.tohex(h)
end





function shaders.key(name, defines)
   if defines == nil then return name end
   local parts = {}
   for macro, value in pairs(defines) do
      parts[#parts + 1] = macro .. "=" .. value
   end
   if #parts == 0 then return name end
   table.sort(parts)
   return name .. "|" .. table.concat(parts, ",")
end





function shaders.register(entry)
   if entry.name == nil or entry.stage == nil or entry.source == nil then
      error("tecs2d: a shader entry needs a name, a stage, and a source", 2)
   end
   if registry[entry.name] == nil then
      order[#order + 1] = entry.name
   end
   registry[entry.name] = entry
end


function shaders.get(name)
   local entry = registry[name]
   if entry == nil then
      error(("tecs2d: no shader named '%s'"):format(tostring(name)), 2)
   end
   return entry
end


function shaders.source(name)
   return shaders.get(name).source
end


function shaders.list()
   local list = {}
   for i = 1, #order do
      list[i] = registry[order[i]]
   end
   return list
end





function shaders.buildList()
   local list = {}
   for _, entry in ipairs(shaders.list()) do
      local sets = { {} }
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








shaders.register({
   name = "instance.reset.comp",
   stage = "compute",
   source = [[
#version 450
layout(local_size_x = 1) in;
layout(set = 1, binding = 0) writeonly buffer DrawArgs { uint value[]; } args;
void main() {
    args.value[0] = 6u;   // vertices per quad
    args.value[1] = 0u;   // instances, accumulated by the cull
    args.value[2] = 0u;
    args.value[3] = 0u;
}
]],
})


shaders.register({
   name = "instance.cull.comp",
   stage = "compute",
   source = [[
#version 450
layout(local_size_x = 64) in;

struct Instance {
    vec4 xform;
    vec4 origin;
    vec4 color;
    vec4 uvRect;
};

layout(set = 0, binding = 0) readonly buffer Instances { Instance item[]; } instances;
layout(set = 1, binding = 0) buffer DrawArgs { uint value[]; } args;
layout(set = 1, binding = 1) writeonly buffer Visible { uint index[]; } visible;
layout(set = 2, binding = 0) uniform Cull { vec4 params; } cull;

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= uint(cull.params.z)) { return; }

    Instance self = instances.item[i];

    // The quad's half extent along each axis, from the columns of its basis.
    // A rotated quad reaches further than its scale alone, so both columns
    // contribute to both axes.
    float ex = 0.5 * (abs(self.xform.x) + abs(self.xform.z));
    float ey = 0.5 * (abs(self.xform.y) + abs(self.xform.w));

    vec2 origin = self.origin.xy;
    if (origin.x + ex < 0.0 || origin.x - ex > cull.params.x ||
        origin.y + ey < 0.0 || origin.y - ey > cull.params.y) {
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

const vec2 CORNERS[6] = vec2[6](
    vec2(-0.5, -0.5), vec2( 0.5, -0.5), vec2(-0.5,  0.5),
    vec2( 0.5, -0.5), vec2( 0.5,  0.5), vec2(-0.5,  0.5)
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
