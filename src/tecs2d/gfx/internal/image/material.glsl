#pragma language glsl4

#define DEFAULT_ORM vec4(1.0, 0.5, 0.0, 1.0)

uniform float tecs_Depth;
uniform float tecs_Lit;
uniform vec2 tecs_ImageAnchor;
uniform vec2 tecs_ImageScale;
uniform vec2 tecs_ImageSize;
uniform float tecs_ImageRotation;
uniform vec2 tecs_ImageOrigin;
uniform vec4 tecs_ClipBounds;
uniform vec4 tecs_WorldToScreenLinear;
uniform Image MainTex;

varying vec2 vWorldPos;

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vec2 localPos =
        VertexTexCoord.xy * tecs_ImageSize - tecs_ImageOrigin;
    vec2 scaled = localPos * tecs_ImageScale;
    float c = cos(tecs_ImageRotation);
    float s = sin(tecs_ImageRotation);
    vec2 worldPos = tecs_ImageAnchor + vec2(
        scaled.x * c - scaled.y * s,
        scaled.x * s + scaled.y * c
    );

    vec2 baseWorldPos = worldPos;
    // -- VERTEX_MATERIAL --

    // Love has already applied the direct draw transform to vertex_position.
    // Apply only the material's world-space displacement, converted through
    // the active camera transform captured by the binder.
    vec2 worldDelta = worldPos - baseWorldPos;
    vertex_position.xy += vec2(
        tecs_WorldToScreenLinear.x * worldDelta.x
            + tecs_WorldToScreenLinear.y * worldDelta.y,
        tecs_WorldToScreenLinear.z * worldDelta.x
            + tecs_WorldToScreenLinear.w * worldDelta.y
    );

    vec4 result = transform_projection * vertex_position;
    result.z = tecs_Depth * result.w;
    vWorldPos = worldPos;
    return result;
}
#endif

#ifdef PIXEL
void effect() {
    if (vWorldPos.x < tecs_ClipBounds.x
            || vWorldPos.x > tecs_ClipBounds.z
            || vWorldPos.y < tecs_ClipBounds.y
            || vWorldPos.y > tecs_ClipBounds.w) {
        discard;
    }

    vec4 finalColor = Texel(MainTex, VaryingTexCoord.xy) * VaryingColor;
    if (finalColor.a < 0.01) {
        discard;
    }

    // -- MATERIAL_BEGIN --
    love_Canvases[0] = finalColor;
    love_Canvases[1] = vec4(0.5, 0.5, 1.0, tecs_Lit);
    love_Canvases[2] = DEFAULT_ORM;
    love_Canvases[3] = vec4(0.0);
    // -- MATERIAL_END --
}
#endif
