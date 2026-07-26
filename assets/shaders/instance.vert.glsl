#version 450

struct Instance {
    vec4 xform;   // rotation, scaleX, scaleY, spare
    vec4 origin;  // xy world position, z array layer, w material
    vec4 color;
    vec4 uvRect;  // u0 v0 u1 v1
};

layout(set = 0, binding = 0) readonly buffer Instances { Instance item[]; } instances;
layout(set = 0, binding = 1) readonly buffer Visible { uint index[]; } visible;
layout(set = 1, binding = 0) uniform View { vec4 viewport; } view;

layout(location = 0) out vec4 vColor;
layout(location = 1) out vec3 vUV;
// Local quad coordinate, -0.5 to 0.5, for a distance field to be evaluated
// over. Free: it is the corner the vertex already used.
layout(location = 2) out vec2 vLocal;
// Material and its parameter, flat because they are per instance.
layout(location = 3) flat out int vMaterial;
layout(location = 4) flat out float vParam;

// Four distinct corners, visited through an index buffer. A non-indexed quad
// runs the vertex shader six times for the four positions it actually has.
const vec2 CORNERS[4] = vec2[4](
    vec2(-0.5, -0.5), vec2( 0.5, -0.5),
    vec2(-0.5,  0.5), vec2( 0.5,  0.5)
);

void main() {
    // The cull compacted the survivors, so this walks the visible list rather
    // than the instance array.
    uint slot = visible.index[gl_InstanceIndex];
    Instance self = instances.item[slot];

    // The basis is built here rather than on the CPU. Sine and cosine are one
    // hardware instruction on a GPU and a libm call on the host, and the host
    // would pay them once per entity per frame while this pays them across
    // however many cores are free.
    float angle = self.xform.x;
    float sx = self.xform.y;
    float sy = self.xform.z;
    float c = cos(angle);
    float s = sin(angle);
    // Column major, which is what the constructor takes: the first pair is
    // the first column, not the first row. Transposing these gives a matrix
    // that scales along world axes after rotating, so a turned rectangle keeps
    // an upright footprint and only its sampling spins.
    mat2 basis = mat2(c * sx, s * sx, -s * sy, c * sy);
    vec2 corner = CORNERS[gl_VertexIndex];
    vec2 world = self.origin.xy + basis * corner;

    // World units are pixels with the origin at the top left, which is also
    // what the lighting pass works in, so light positions need no conversion.
    vec2 ndc = vec2(world.x / view.viewport.x * 2.0 - 1.0,
                    1.0 - world.y / view.viewport.y * 2.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
    vColor = self.color;

    // Corners run -0.5..0.5, and V is flipped because texture rows run down
    // from the top while the quad's local Y runs up.
    vUV = vec3(mix(self.uvRect.xy, self.uvRect.zw,
                   vec2(corner.x + 0.5, 0.5 - corner.y)),
               self.origin.z);

    vLocal = corner;
    // Material and parameter share origin.w, which is otherwise spare: the
    // integer part selects, the fraction carries the parameter.
    float packed = self.origin.w;
    vMaterial = int(floor(packed));
    vParam = fract(packed);
}
