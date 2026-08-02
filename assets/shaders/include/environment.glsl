// Samples six conventional cube faces stored in a 2D array. Keeping the
// upload as an array avoids relying on a backend-specific cube texture path,
// while the direction-to-face choice stays identical in every mesh lane.
vec3 environmentCoordinate(vec3 direction) {
    vec3 axis = abs(direction);
    vec2 face;
    float layer;
    if (axis.x >= axis.y && axis.x >= axis.z) {
        float inverse = 1.0 / max(axis.x, 1e-6);
        if (direction.x >= 0.0) {
            face = vec2(-direction.z, -direction.y) * inverse;
            layer = 0.0;
        } else {
            face = vec2(direction.z, -direction.y) * inverse;
            layer = 1.0;
        }
    } else if (axis.y >= axis.z) {
        float inverse = 1.0 / max(axis.y, 1e-6);
        if (direction.y >= 0.0) {
            face = vec2(direction.x, direction.z) * inverse;
            layer = 2.0;
        } else {
            face = vec2(direction.x, -direction.z) * inverse;
            layer = 3.0;
        }
    } else {
        float inverse = 1.0 / max(axis.z, 1e-6);
        if (direction.z >= 0.0) {
            face = vec2(direction.x, -direction.y) * inverse;
            layer = 4.0;
        } else {
            face = vec2(-direction.x, -direction.y) * inverse;
            layer = 5.0;
        }
    }
    return vec3(face * 0.5 + 0.5, layer);
}

vec3 environmentRotate(vec3 direction, vec2 turn) {
    return vec3(
        turn.x * direction.x + turn.y * direction.z,
        direction.y,
        -turn.y * direction.x + turn.x * direction.z);
}

vec3 environmentSample(vec3 direction, float lod, vec2 turn) {
    return textureLod(meshEnvironment,
        environmentCoordinate(environmentRotate(normalize(direction), turn)), lod).rgb;
}

// Lazarov's analytic fit to the split-sum environment BRDF. The fit removes a
// second texture and binding while retaining the roughness and Fresnel response
// PBR materials need. Authored GGX-prefiltered faces can replace the generated
// mip approximation later without changing this material-side contract.
vec2 environmentBRDF(float roughness, float normalView) {
    const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
    const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
    vec4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * normalView)) * r.x + r.y;
    return vec2(-1.04, 1.04) * a004 + r.zw;
}

vec3 environmentSpecular(
    vec3 albedo,
    vec3 normal,
    vec3 viewDirection,
    float roughness,
    float metallic,
    float occlusion,
    float intensity,
    vec2 turn
) {
    if (intensity <= 0.0) { return vec3(0.0); }
    float clampedRoughness = clamp(roughness, 0.04, 1.0);
    float levels = float(textureQueryLevels(meshEnvironment));
    vec3 reflected = reflect(-viewDirection, normal);
    vec3 radiance = environmentSample(reflected, clampedRoughness * max(levels - 1.0, 0.0), turn);
    vec3 f0 = mix(vec3(0.04), albedo, clamp(metallic, 0.0, 1.0));
    vec2 brdf = environmentBRDF(clampedRoughness, max(dot(normal, viewDirection), 0.0));
    return radiance * (f0 * brdf.x + brdf.y) * occlusion * intensity;
}
