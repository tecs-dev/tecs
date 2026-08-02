// Samples three directional shadow cascades. The pass graph binds their maps
// at slots zero through two; material textures follow them in these variants.

layout(set = 2, binding = 0) uniform sampler2D meshShadowMap0;
layout(set = 2, binding = 1) uniform sampler2D meshShadowMap1;
layout(set = 2, binding = 2) uniform sampler2D meshShadowMap2;

layout(set = 3, binding = 0) uniform MeshShadow {
    mat4 viewProjection[3];
    // xyz holds each cascade's far camera distance and w its blend fraction.
    vec4 splits;
    // Dotting this row with a world position yields positive camera depth.
    vec4 cameraDepth;
    // xyz is the normalized direction light travels and w its intensity.
    vec4 direction;
    // rgb is light color and w is how strongly the map occludes it.
    vec4 colorStrength;
    // x depth bias, y PCF radius in texels, z whether a caster was rendered.
    vec4 tuning;
} meshShadow;

float meshShadowDepth(int cascade, vec2 uv) {
    if (cascade == 0) { return texture(meshShadowMap0, uv).r; }
    if (cascade == 1) { return texture(meshShadowMap1, uv).r; }
    return texture(meshShadowMap2, uv).r;
}

vec2 meshShadowTexel(int cascade) {
    if (cascade == 0) { return 1.0 / vec2(textureSize(meshShadowMap0, 0)); }
    if (cascade == 1) { return 1.0 / vec2(textureSize(meshShadowMap1, 0)); }
    return 1.0 / vec2(textureSize(meshShadowMap2, 0));
}

float meshShadowCascade(int cascade, vec3 world, vec3 normal) {
    vec4 projected = meshShadow.viewProjection[cascade] * vec4(world, 1.0);
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
    if (radius <= 0.0) {
        return receiver <= meshShadowDepth(cascade, uv) ? 1.0 : 0.0;
    }

    vec2 texel = meshShadowTexel(cascade);
    float visible = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float stored = meshShadowDepth(cascade, uv + vec2(x, y) * texel * radius);
            visible += receiver <= stored ? 1.0 : 0.0;
        }
    }
    return visible / 9.0;
}

float meshShadowVisibility(vec3 world, vec3 normal) {
    if (meshShadow.tuning.z < 0.5) { return 1.0; }
    float depth = dot(meshShadow.cameraDepth, vec4(world, 1.0));
    if (depth > meshShadow.splits.z) { return 1.0; }

    int cascade = depth <= meshShadow.splits.x ? 0
        : depth <= meshShadow.splits.y ? 1 : 2;
    float visible = meshShadowCascade(cascade, world, normal);
    if (cascade < 2 && meshShadow.splits.w > 0.0) {
        float previous = cascade == 0 ? 0.0 : meshShadow.splits[cascade - 1];
        float width = (meshShadow.splits[cascade] - previous) * meshShadow.splits.w;
        float blend = clamp((depth - (meshShadow.splits[cascade] - width)) / width, 0.0, 1.0);
        if (blend > 0.0) {
            visible = mix(visible, meshShadowCascade(cascade + 1, world, normal), blend);
        }
    }
    return mix(1.0, visible, meshShadow.colorStrength.w);
}
