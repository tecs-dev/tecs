// Dissolve material: noise-based dissolve effect.
// params.x = dissolve threshold (0 = fully visible, 1 = fully dissolved)
// params.y = edge width (default 0.05)

MaterialOutput material(MaterialInput i) {
    MaterialOutput o = standardMaterial(i);

    float threshold = i.params.x;
    float edgeWidth = i.params.y > 0.0 ? i.params.y : 0.05;

    // Simple noise using localPos
    vec2 uv = i.localPos;
    float noise = fract(sin(dot(uv, vec2(12.9898, 78.233))) * 43758.5453);
    noise = noise * 0.5 + fract(sin(dot(uv * 2.0, vec2(39.346, 11.135))) * 65432.1234) * 0.3;
    noise += fract(sin(dot(uv * 4.0, vec2(73.156, 52.235))) * 12345.6789) * 0.2;

    // Discard pixels below threshold
    if (noise < threshold) {
        o.albedo = vec4(0.0);
        return o;
    }

    // Glowing edge near the dissolve boundary
    float edge = smoothstep(threshold, threshold + edgeWidth, noise);
    vec3 edgeColor = vec3(1.0, 0.4, 0.1);
    o.albedo = vec4(mix(edgeColor, i.color.rgb, edge), i.color.a);
    o.emission = vec4(edgeColor * (1.0 - edge) * 3.0, 1.0);

    return o;
}
