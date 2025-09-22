// Ice/frost material: cool blue tint with PBR reflections.
// params.x = frost intensity (0-1, default 0.5)

MaterialOutput material(MaterialInput i) {
    MaterialOutput o = standardMaterial(i);

    float frost = i.params.x > 0.0 ? i.params.x : 0.5;

    // Blue-tinted albedo
    vec3 iceColor = mix(i.color.rgb, vec3(0.6, 0.8, 1.0), frost * 0.6);
    o.albedo = vec4(iceColor, i.color.a);

    // Smooth, slightly metallic surface (low roughness for sharp reflections)
    o.orm = vec4(1.0, mix(0.5, 0.1, frost), mix(0.0, 0.3, frost), 1.0);

    // Subtle surface normal variation (frozen cracks)
    vec2 uv = i.localPos * 10.0;
    float nx = sin(uv.x * 3.0 + uv.y * 5.0) * 0.15 * frost;
    float ny = cos(uv.y * 4.0 + uv.x * 2.0) * 0.15 * frost;
    o.normal = vec3(0.5 + nx, 0.5 + ny, 1.0);

    return o;
}
