#pragma language glsl4

// Mesh instance data from cull shader output
struct MeshInstance {
    vec4 posLayer;         // x, y, z, layerFloat
    vec4 color;            // r, g, b, a
    vec4 scaleRotFlags;    // scaleX, scaleY, rotation, flags
    vec4 pivot;            // pivotX, pivotY, _pad, _pad
    vec4 clipBounds;       // minX, minY, maxX, maxY
    uvec4 flags;           // flagBits, depthBits, _pad, _pad
};

// Flag constants (must match types.tl)
const uint FLAG_UNLIT = 0x1u;
const uint FLAG_SCREEN_SPACE = 0x10000u;
const uint FLAG_IGNORE_ZOOM = 0x20000u;
const uint FLAG_VIRTUAL_COORDS = 0x40000u;

layout(std430) readonly buffer MeshOutput {
    MeshInstance instances[];
};

uniform int BlendModePass;    // -1 = render all, 0+ = render only matching blend ID
uniform int MaterialPass;     // -1 = default pass (materialId=0 only), 0+ = specific material

varying vec4 vColor;
varying vec2 vTexCoord;
varying vec2 vWorldPos;
varying vec4 vClipBounds;
varying float vFlags;

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position) {
    int instanceID = love_InstanceID;
    MeshInstance inst = instances[instanceID];

    // Layer range filtering for multi-pass effects
    float layer = inst.posLayer.w;
    if (layer < LayerRange.x || layer > LayerRange.y) {
        return vec4(2.0, 2.0, 2.0, 1.0);
    }

    // Blend / material pass filtering. Cull packs blendId in bits 20-23
    // and materialId in bits 24-31 of `flags.x`.
    uint packedFlags = inst.flags.x;
    if (BlendModePass >= 0) {
        int blendId = int((packedFlags >> 20) & 0xFu);
        if (blendId != BlendModePass) {
            return vec4(2.0, 2.0, 2.0, 1.0);
        }
    }
    {
        int matId = int((packedFlags >> 24) & 0xFFu);
        if (MaterialPass < 0) {
            if (matId != 0) return vec4(2.0, 2.0, 2.0, 1.0);
        } else {
            if (matId != MaterialPass) return vec4(2.0, 2.0, 2.0, 1.0);
        }
    }

    // Extract transform data
    vec2 pos = inst.posLayer.xy;
    vec2 pivot = inst.pivot.xy;
    vec2 scale = inst.scaleRotFlags.xy;
    float rotation = inst.scaleRotFlags.z;

    // Check screen-space flags
    uint flagBits = inst.flags.x;
    bool isScreenSpace = (flagBits & FLAG_SCREEN_SPACE) != 0u;
    bool ignoresZoom = (flagBits & FLAG_IGNORE_ZOOM) != 0u;
    bool usesVirtualCoords = (flagBits & FLAG_VIRTUAL_COORDS) != 0u;

    // Transform vertex around pivot
    vec2 local = vertex_position.xy - pivot;
    vec2 scaled = local * scale;
    float c = cos(rotation);
    float s = sin(rotation);
    vec2 rotated = vec2(scaled.x * c - scaled.y * s, scaled.x * s + scaled.y * c);
    vec2 worldPos = pos + rotated;

    // -- VERTEX_MATERIAL --
    vec2 screenPos = worldToScreen(worldPos, isScreenSpace, ignoresZoom, usesVirtualCoords);

    // Read pre-computed depth from cull shader
    float depth = uintBitsToFloat(inst.flags.y);

    vec4 result = transform_projection * vec4(screenPos, 0.0, 1.0);
    result.z = depth * result.w;

    // Pass to fragment shader
    vColor = inst.color;
    vTexCoord = VertexTexCoord.xy;
    vWorldPos = worldPos;
    vClipBounds = inst.clipBounds;
    vFlags = float(flagBits);

    return result;
}
#endif

#ifdef PIXEL
uniform Image MainTex;

void effect() {
    if (outsideClipBounds(vWorldPos, vClipBounds)) discard;

    // Sample texture if available (use Texel which works with Image type)
    vec4 texColor = Texel(MainTex, vTexCoord);
    vec4 finalColor = texColor * vColor * VaryingColor;

    // Alpha test
    if (finalColor.a < 0.01) {
        discard;
    }

    // Check unlit flag
    uint flags = uint(vFlags);
    bool isUnlit = (flags & FLAG_UNLIT) != 0u;
    float litMarker = isUnlit ? 0.0 : 1.0;

    // G-buffer output
    love_Canvases[0] = finalColor;  // Albedo
    love_Canvases[1] = vec4(0.5, 0.5, 1.0, litMarker);  // Flat normal + unlit flag
    love_Canvases[2] = vec4(1.0, 0.5, 0.0, 1.0);  // ORM default (AO=1, roughness=0.5, metallic=0)
    love_Canvases[3] = vec4(0.0);  // No emission for meshes
}
#endif
