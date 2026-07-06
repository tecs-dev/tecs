#pragma language glsl4

// Tecs uniforms (prefixed with tecs_ like Love2D's love_ convention)
// See: https://love2d.org/wiki/Shader_Variables for Love2D built-ins

// Depth value passed from CPU (computed via pipeline:computeDepth)
uniform float tecs_Depth;

// Lit flag: 1.0 = receives lighting, 0.0 = unlit (full bright)
uniform float tecs_Lit;

// Normal for lit surfaces (default 0,0,1 = flat facing camera)
uniform vec3 tecs_Normal;

// Main texture (automatically bound by Love2D for lg.draw/lg.print calls)
uniform Image MainTex;

// Optional normal map
uniform Image tecs_NormalMap;
uniform bool tecs_UseNormalMap;

#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vec4 result = transform_projection * vertex_position;
    // Inject depth in vertex shader (same approach as GPU shapes)
    result.z = tecs_Depth * result.w;
    return result;
}
#endif

#ifdef PIXEL
void effect() {
    vec4 texColor = Texel(MainTex, VaryingTexCoord.xy);
    vec4 finalColor = texColor * VaryingColor;

    // Alpha test for correct depth buffer behavior
    if (finalColor.a < 0.01) discard;

    // Determine normal
    vec3 normal = tecs_Normal;
    if (tecs_UseNormalMap) {
        // Sample normal map and convert from [0,1] to [-1,1]
        normal = Texel(tecs_NormalMap, VaryingTexCoord.xy).rgb * 2.0 - 1.0;
    }

    // Output to G-buffer
    // Canvas 0: Albedo
    love_Canvases[0] = finalColor;
    // Canvas 1: Normal (rgb) + lit flag (alpha: 1.0=lit, 0.0=unlit)
    love_Canvases[1] = vec4(normal * 0.5 + 0.5, tecs_Lit);
    // Canvas 2: ORM (R = AO, G = roughness, B = metallic)
    love_Canvases[2] = vec4(1.0, 0.5, 0.0, 1.0);
    // Canvas 3: Emission (added after lighting)
    love_Canvases[3] = vec4(0.0);
}
#endif
