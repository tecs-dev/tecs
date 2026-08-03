// Quaternion rotation and palette lookup shared by mesh geometry and shadow
// vertices. The including shader declares `jointMatrices` when skinning is on.
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
#endif
