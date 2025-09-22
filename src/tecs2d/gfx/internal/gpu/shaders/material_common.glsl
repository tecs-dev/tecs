// Shared material system structs and default/standard material functions.
// Included by material variant shaders (compiled by material_compiler).

struct MaterialInput {
    vec4 color;       // entity color (post-texture-sample for sprites)
    vec2 uv;          // texture coords (sprites) or normalized local coords
    vec2 worldPos;    // world position
    vec2 localPos;    // position within shape, normalized 0..1 (0,0=top-left, 1,1=bottom-right)
    float sdfDist;    // signed distance from edge (negative inside, 0 at edge)
    float time;       // global game time
    vec4 params;      // per-entity params (p0, p1, p2, p3)
};

struct MaterialOutput {
    vec4 albedo;      // -> love_Canvases[0]
    vec3 normal;      // -> love_Canvases[1].rgb (encoded 0..1)
    float lit;        // -> love_Canvases[1].a
    vec4 orm;         // -> love_Canvases[2] (R=AO, G=roughness, B=metallic)
    vec4 emission;    // -> love_Canvases[3]
};

// defaultMaterial: returns flat defaults (no textures sampled).
// Use standardMaterial() instead to preserve normal/emission/ORM maps.
MaterialOutput defaultMaterial(MaterialInput i) {
    MaterialOutput o;
    o.albedo = i.color;
    o.normal = vec3(0.5, 0.5, 1.0);  // flat up
    o.lit = 1.0;
    o.orm = vec4(1.0, 0.5, 0.0, 1.0);
    o.emission = vec4(0.0);
    return o;
}

// _std is populated by the call site with the shape's standard G-buffer values
// (sampled texture maps for sprites, computed normals for shapes, etc.)
// before the user's material() function is called.
MaterialOutput _std;

// standardMaterial: returns the same output the shape would produce without
// a custom material. For sprites this includes sampled normal/emission/ORM
// maps; for shapes this includes computed hemisphere or flat normals.
// Use this as a starting point and override only the channels you need:
//
//   MaterialOutput material(MaterialInput i) {
//       MaterialOutput o = standardMaterial(i);
//       o.emission = vec4(1.0, 0.0, 0.0, 1.0) * i.params.x;
//       return o;
//   }
MaterialOutput standardMaterial(MaterialInput i) {
    return _std;
}
