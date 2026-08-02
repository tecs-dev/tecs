#ifndef TECS_MESH_LIGHT_INCLUDED
#define TECS_MESH_LIGHT_INCLUDED

struct MeshLight {
    vec4 positionRadius;
    vec4 colorIntensity;
    vec4 directionOuter;
    vec4 coneType;
};

float meshLightCone(MeshLight light, vec3 surfaceToLight) {
    if (light.coneType.y < 0.5) {
        return 1.0;
    }
    vec3 fromLight = -surfaceToLight;
    float cosine = dot(fromLight, normalize(light.directionOuter.xyz));
    return smoothstep(light.directionOuter.w, light.coneType.x, cosine);
}

#endif
