#version 450
// Estimates opaque-mesh ambient occlusion from the existing world normals and
// depth. Twelve deterministic hemisphere samples at half resolution cost the
// same depth bandwidth as three full-resolution samples, and require no noise
// texture or retained kernel buffer.

layout(location = 0) in vec2 vUV;
layout(location = 0) out vec4 outColor;
layout(set = 2, binding = 0) uniform sampler2D normalTexture;
layout(set = 2, binding = 1) uniform sampler2D depthTexture;
layout(set = 3, binding = 0) uniform SSAO {
    mat4 viewProjection;
    mat4 inverseViewProjection;
    // x world radius, y world bias, z intensity, w contrast power.
    vec4 tuning;
    vec4 camera;
} ssao;

const int SAMPLE_COUNT = 12;
const float PI2 = 6.283185307179586;
const float GOLDEN_ANGLE = 2.399963229728653;

float hash12(vec2 value) {
    vec3 p = fract(vec3(value.xyx) * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

vec3 worldOf(vec2 uv, float depth) {
    vec4 clip = vec4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    vec4 world = ssao.inverseViewProjection * clip;
    return world.xyz / max(abs(world.w), 1e-6) * sign(world.w);
}

void main() {
    vec4 encoded = texture(normalTexture, vUV);
    // Mesh normal markers occupy the interior ranges. Sprites use the exact
    // endpoints, and empty target pixels clear to zero.
    if (encoded.a <= 0.1 || encoded.a >= 0.9) {
        outColor = vec4(1.0);
        return;
    }

    float depth = texture(depthTexture, vUV).r;
    if (depth >= 1.0) {
        outColor = vec4(1.0);
        return;
    }

    vec3 position = worldOf(vUV, depth);
    vec3 normal = normalize(encoded.xyz * 2.0 - 1.0);
    // Lock the rotation to the surface instead of the target pixel. Walking
    // the camera then changes what becomes visible without rotating a fixed
    // surface's sample pattern underneath it.
    float seed = hash12(position.xy * 17.0
                      + vec2(position.z * 11.0, position.z * 23.0));
    vec3 random = normalize(vec3(
        cos(seed * PI2),
        sin(seed * PI2),
        fract(seed * 17.0) * 2.0 - 1.0));
    vec3 tangent = random - normal * dot(random, normal);
    if (dot(tangent, tangent) < 1e-5) {
        tangent = abs(normal.z) < 0.9 ? cross(normal, vec3(0.0, 0.0, 1.0))
                                     : cross(normal, vec3(0.0, 1.0, 0.0));
    }
    tangent = normalize(tangent);
    vec3 bitangent = cross(normal, tangent);

    float radius = ssao.tuning.x;
    float centerDistance = length(position - ssao.camera.xyz);
    float occluded = 0.0;
    float valid = 0.0;
    for (int index = 0; index < SAMPLE_COUNT; index++) {
        float progress = (float(index) + 0.5) / float(SAMPLE_COUNT);
        float angle = float(index) * GOLDEN_ANGLE + seed * PI2;
        float elevation = mix(0.15, 0.95, fract(progress * 7.61803398875));
        float radial = sqrt(max(1.0 - elevation * elevation, 0.0));
        vec3 hemisphere = tangent * (cos(angle) * radial)
                        + bitangent * (sin(angle) * radial)
                        + normal * elevation;
        float reach = mix(0.15, 1.0, progress * progress);
        vec3 expected = position + hemisphere * radius * reach;
        vec4 projected = ssao.viewProjection * vec4(expected, 1.0);
        if (projected.w <= 0.0) { continue; }
        vec2 sampleUV = projected.xy / projected.w * 0.5 + 0.5;
        sampleUV.y = 1.0 - sampleUV.y;
        if (any(lessThan(sampleUV, vec2(0.0))) || any(greaterThan(sampleUV, vec2(1.0)))) {
            continue;
        }

        float sampleDepth = texture(depthTexture, sampleUV).r;
        if (sampleDepth >= 1.0) { continue; }
        vec3 actual = worldOf(sampleUV, sampleDepth);
        float separation = length(actual - position);
        float range = 1.0 - smoothstep(radius * 0.5, radius, separation);
        float actualDistance = length(actual - ssao.camera.xyz);
        float expectedDistance = length(expected - ssao.camera.xyz);
        occluded += actualDistance + ssao.tuning.y < expectedDistance ? range : 0.0;
        valid += 1.0;
    }

    float visibility = 1.0 - (valid > 0.0 ? occluded / valid : 0.0) * ssao.tuning.z;
    visibility = pow(clamp(visibility, 0.0, 1.0), ssao.tuning.w);
    outColor = vec4(visibility, visibility, visibility, 1.0);
}
