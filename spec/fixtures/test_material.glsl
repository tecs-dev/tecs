MaterialOutput material(MaterialInput i) {
    MaterialOutput o = standardMaterial(i);
    o.albedo = vec4(1.0, 0.0, 0.0, 1.0);
    return o;
}
