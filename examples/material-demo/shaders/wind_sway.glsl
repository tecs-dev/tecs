// Wind sway vertex material: sinusoidal world-position offset.
// params.x = sway amplitude in pixels (default 6.0)
// params.y = sway speed multiplier (default 1.0)
vec2 materialVertex(vec2 worldPos, float time, vec4 params) {
    float amplitude = params.x > 0.0 ? params.x : 6.0;
    float speed = params.y > 0.0 ? params.y : 1.0;
    float sway = sin(time * speed * 2.0 + worldPos.x * 0.04) * amplitude;
    return worldPos + vec2(sway, 0.0);
}
