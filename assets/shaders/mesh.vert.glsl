#version 450
#pragma tecs variants MESH_SKINNING=1

layout(set = 0, binding = 0) readonly buffer Vertices {
    float value[];
} vertices;

layout(set = 0, binding = 1) readonly buffer Instances {
    float value[];
} instances;

#ifdef MESH_SKINNING
layout(set = 0, binding = 2) readonly buffer SkinVertices { float value[]; } skinVertices;
layout(set = 0, binding = 3) readonly buffer InstanceSkins { float value[]; } instanceSkins;
layout(set = 0, binding = 4) readonly buffer JointMatrices { float value[]; } jointMatrices;
#endif

layout(set = 1, binding = 0) uniform View {
    mat4 viewProjection;
} view;

layout(location = 0) out vec3 vNormal;
layout(location = 1) flat out vec3 vColor;
layout(location = 2) out vec2 vUV;
layout(location = 3) out vec4 vTangent;
layout(location = 4) flat out int vMaterial;
layout(location = 5) out vec3 vWorld;

vec3 rotateBy(vec4 rotation, vec3 value) {
    vec3 twice = 2.0 * cross(rotation.xyz, value);
    return value + rotation.w * twice + cross(rotation.xyz, twice);
}

#ifdef MESH_SKINNING
mat4 jointMatrix(int joint) {
    int at = joint * 16;
    return mat4(
        jointMatrices.value[at], jointMatrices.value[at + 1],
        jointMatrices.value[at + 2], jointMatrices.value[at + 3],
        jointMatrices.value[at + 4], jointMatrices.value[at + 5],
        jointMatrices.value[at + 6], jointMatrices.value[at + 7],
        jointMatrices.value[at + 8], jointMatrices.value[at + 9],
        jointMatrices.value[at + 10], jointMatrices.value[at + 11],
        jointMatrices.value[at + 12], jointMatrices.value[at + 13],
        jointMatrices.value[at + 14], jointMatrices.value[at + 15]);
}

void applySkin(inout vec3 position, inout vec3 normal, inout vec4 tangent) {
    int skin = int(instanceSkins.value[gl_InstanceIndex]);
    if (skin < 0) {
        return;
    }
    int at = gl_VertexIndex * 8;
    ivec4 joints = ivec4(
        skinVertices.value[at], skinVertices.value[at + 1],
        skinVertices.value[at + 2], skinVertices.value[at + 3]);
    vec4 weights = vec4(
        skinVertices.value[at + 4], skinVertices.value[at + 5],
        skinVertices.value[at + 6], skinVertices.value[at + 7]);
    mat4 matrix = jointMatrix(skin + joints.x) * weights.x
        + jointMatrix(skin + joints.y) * weights.y
        + jointMatrix(skin + joints.z) * weights.z
        + jointMatrix(skin + joints.w) * weights.w;
    position = (matrix * vec4(position, 1.0)).xyz;
    normal = mat3(matrix) * normal;
    tangent.xyz = mat3(matrix) * tangent.xyz;
}
#endif

void main() {
    int vertexBase = gl_VertexIndex * 12;
    vec3 localPosition = vec3(
        vertices.value[vertexBase],
        vertices.value[vertexBase + 1],
        vertices.value[vertexBase + 2]);
    vec3 localNormal = vec3(
        vertices.value[vertexBase + 3],
        vertices.value[vertexBase + 4],
        vertices.value[vertexBase + 5]);
    vec4 localTangent = vec4(
        vertices.value[vertexBase + 6],
        vertices.value[vertexBase + 7],
        vertices.value[vertexBase + 8],
        vertices.value[vertexBase + 9]);
#ifdef MESH_SKINNING
    applySkin(localPosition, localNormal, localTangent);
#endif

    int instanceBase = gl_InstanceIndex * 16;
    vec3 position = vec3(
        instances.value[instanceBase],
        instances.value[instanceBase + 1],
        instances.value[instanceBase + 2]);
    vec4 rotation = normalize(vec4(
        instances.value[instanceBase + 3],
        instances.value[instanceBase + 4],
        instances.value[instanceBase + 5],
        instances.value[instanceBase + 6]));
    vec3 scale = vec3(
        instances.value[instanceBase + 7],
        instances.value[instanceBase + 8],
        instances.value[instanceBase + 9]);

    vec3 world = position + rotateBy(rotation, localPosition * scale);
    vWorld = world;
    gl_Position = view.viewProjection * vec4(world, 1.0);

    vec3 inverseScale = vec3(
        scale.x == 0.0 ? 0.0 : 1.0 / scale.x,
        scale.y == 0.0 ? 0.0 : 1.0 / scale.y,
        scale.z == 0.0 ? 0.0 : 1.0 / scale.z);
    vNormal = normalize(rotateBy(rotation, localNormal * inverseScale));
    vec3 tangent = rotateBy(rotation, localTangent.xyz * scale);
    tangent = normalize(tangent - vNormal * dot(vNormal, tangent));
    float reflection = scale.x * scale.y * scale.z < 0.0 ? -1.0 : 1.0;
    vTangent = vec4(tangent, localTangent.w * reflection);
    vUV = vec2(vertices.value[vertexBase + 10], vertices.value[vertexBase + 11]);
    vMaterial = int(instances.value[instanceBase + 11]);
    vColor = vec3(
        instances.value[instanceBase + 13],
        instances.value[instanceBase + 14],
        instances.value[instanceBase + 15]);
}
