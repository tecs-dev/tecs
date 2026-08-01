#version 450

layout(location = 0) in vec3 vNormal;
layout(location = 1) flat in vec3 vColor;

layout(location = 0) out vec4 albedo;
layout(location = 1) out vec4 normal;
layout(location = 2) out vec4 orm;
layout(location = 3) out vec4 emission;

void main() {
    albedo = vec4(vColor, 1.0);
    normal = vec4(normalize(vNormal) * 0.5 + 0.5, 1.0);
    orm = vec4(1.0, 0.65, 0.0, 1.0);
    emission = vec4(0.0);
}
