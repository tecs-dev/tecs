vec2 materialVertex(vec2 worldPos, float time, vec4 params) {
    return worldPos + vec2(sin(time) * params.x, 0.0);
}
