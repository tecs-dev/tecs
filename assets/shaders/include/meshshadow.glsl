// Samples the mesh domain's one directional shadow map. The graph binds the
// map at slot zero; material textures move to slot one in this shader variant.

layout(set = 2, binding = 0) uniform sampler2D meshShadowMap;

layout(set = 3, binding = 0) uniform MeshShadow {
    mat4 viewProjection;
    // xyz is the normalized direction light travels and w its intensity.
    vec4 direction;
    // rgb is light color and w is how strongly the map occludes it.
    vec4 colorStrength;
    // x depth bias, y PCF radius in texels, z whether a caster was rendered.
    vec4 tuning;
} meshShadow;

float meshShadowVisibility(vec3 world, vec3 normal) {
    if (meshShadow.tuning.z < 0.5) { return 1.0; }
    vec4 projected = meshShadow.viewProjection * vec4(world, 1.0);
    vec3 shadow = projected.xyz / projected.w;
    vec2 uv = shadow.xy * 0.5 + 0.5;
    if (shadow.z < 0.0 || shadow.z > 1.0
            || any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
        return 1.0;
    }

    vec3 toLight = -meshShadow.direction.xyz;
    float slope = 1.0 - max(dot(normalize(normal), toLight), 0.0);
    float receiver = shadow.z - meshShadow.tuning.x * (1.0 + slope);
    float radius = meshShadow.tuning.y;
    vec2 texel = 1.0 / vec2(textureSize(meshShadowMap, 0));
    float visible = 0.0;
    if (radius <= 0.0) {
        visible = receiver <= texture(meshShadowMap, uv).r ? 1.0 : 0.0;
    } else {
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float stored = texture(meshShadowMap, uv + vec2(x, y) * texel * radius).r;
                visible += receiver <= stored ? 1.0 : 0.0;
            }
        }
        visible /= 9.0;
    }
    return mix(1.0, visible, meshShadow.colorStrength.w);
}
