// Lava material: animated distortion with emission glow.
// params.x = speed multiplier (default 1.0)
// params.y = emission intensity (default 2.0)

MaterialOutput material(MaterialInput i) {
    MaterialOutput o = standardMaterial(i);

    float speed = i.params.x > 0.0 ? i.params.x : 1.0;
    float emissionIntensity = i.params.y > 0.0 ? i.params.y : 2.0;
    float t = i.time * speed;

    // Animated UV distortion
    vec2 uv = i.localPos;
    uv.x += sin(uv.y * 8.0 + t * 2.0) * 0.05;
    uv.y += cos(uv.x * 6.0 + t * 1.5) * 0.04;

    // Lava color gradient (dark red to bright orange/yellow)
    float heat = sin(uv.x * 10.0 + t) * 0.5 + 0.5;
    heat *= sin(uv.y * 8.0 - t * 0.7) * 0.5 + 0.5;
    heat = smoothstep(0.2, 0.8, heat);

    vec3 coolColor = vec3(0.3, 0.05, 0.0);
    vec3 hotColor = vec3(1.0, 0.6, 0.1);
    vec3 lavaColor = mix(coolColor, hotColor, heat);

    o.albedo = vec4(lavaColor * i.color.rgb, i.color.a);
    o.emission = vec4(lavaColor * heat * emissionIntensity, 1.0);
    o.normal = vec3(0.5 + sin(uv.x * 20.0) * 0.1, 0.5 + cos(uv.y * 20.0) * 0.1, 1.0);

    return o;
}
