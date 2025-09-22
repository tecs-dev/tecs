MaterialOutput material(MaterialInput i) {
    MaterialOutput o = standardMaterial(i);
    float r = sin(i.time * 2.0) * 0.5 + 0.5;
    float g = sin(i.time * 2.0 + 2.094) * 0.5 + 0.5;
    float b = sin(i.time * 2.0 + 4.189) * 0.5 + 0.5;
    o.albedo = vec4(r, g, b, 1.0) * i.color;
    return o;
}
