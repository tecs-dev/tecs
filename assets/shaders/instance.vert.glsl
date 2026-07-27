#version 450

struct Instance {
    vec4 xform;   // rotation, scaleX, scaleY, depth
    vec4 origin;  // xy world position, z clip region and array layer, w material
    vec4 color;
    vec4 uvRect;  // u0 v0 u1 v1
};

layout(set = 0, binding = 0) readonly buffer Instances { Instance item[]; } instances;
layout(set = 0, binding = 1) readonly buffer Visible { uint index[]; } visible;
layout(set = 1, binding = 0) uniform View { mat4 viewProjection; } view;

// Bands the depth range divides into, and the same number as `layers.MAX` in
// src/tecs/gfx/layers.tl. The two are one number and only work while they
// agree.
const int LAYER_BANDS = 16;

// Texture-array layers `origin.z` addresses, and the stride the clip region
// index sits above them at. `LAYER_SLOTS` in src/tecs/gpu/instancelayout.tl is
// the same number and the pair only works while they agree. Every value the
// packing produces is a whole number well inside the range a float represents
// integers exactly over, so both halves come back out exactly.
const float LAYER_SLOTS = 64.0;

// The space a layer positions its contents in, held in an entry's first
// component.
const float LAYER_CAMERA = 0.0;
const float LAYER_SCREEN = 1.0;
const float LAYER_VIRTUAL = 2.0;

// What each layer does to the geometry on it.
//
// The camera's parameters rather than a matrix per mode, because parallax
// multiplies the camera's position: a matrix would have to exist per layer and
// be rebuilt every frame the camera moved. Passed this way the table is
// configuration, packed when it changes, and the four cases compose from it in
// a handful of instructions.
layout(set = 1, binding = 1) uniform Layers {
    // xy camera position in world units, z reciprocal zoom, w unused.
    vec4 camera;
    // Position to clip: xy for screen pixels, zw for virtual coordinates.
    vec4 fixedScale;
    // Per layer: mode, parallax offset factor, ignore-zoom flag, lit flag.
    vec4 entry[LAYER_BANDS];
} layers;

layout(location = 0) out vec4 vColor;
layout(location = 1) out vec3 vUV;
// Local quad coordinate, -0.5 to 0.5, for a distance field to be evaluated
// over. Free: it is the corner the vertex already used.
layout(location = 2) out vec2 vLocal;
// Material and its parameter, flat because they are per instance.
layout(location = 3) flat out int vMaterial;
layout(location = 4) flat out float vParam;
// Whether the layer wants its contents lit, flat for the same reason.
layout(location = 5) flat out float vLit;
// Which clip region the fragments belong to, zero for none. Flat, so the test
// downstream is uniform across the primitive rather than a per-fragment
// decision that could go either way.
layout(location = 6) flat out int vClip;

// Four distinct corners, visited through an index buffer. A non-indexed quad
// runs the vertex shader six times for the four positions it actually has.
//
// The corners are symmetric and stay that way. A pivot moves where the quad
// hangs off the point it is drawn at, and `Extractor.tl` folds it into
// `origin.xy` before the instance is written, because origin - basis * pivot
// places every corner exactly where corner - pivot would: the same geometry
// for no extra bytes in the instance. Two things here decide the sign it uses:
// these corners, and the `corner + 0.5` below that maps them onto UV. Change
// either and the pivot's Y follows.
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

    // Depth is the transform's fourth float, in zero to one with zero nearest.
    float depth = self.xform.w;

    // Which layer this is on, recovered from that depth rather than carried in
    // the instance. `depthOf` in src/tecs/gfx/layers.tl writes
    // (LAYER_BANDS - layer) / LAYER_BANDS plus an offset within the band that
    // is strictly less than one band wide, so multiplying by LAYER_BANDS leaves
    // LAYER_BANDS - layer as the integer part and nothing within a band can
    // reach the next one. That
    // holds only while a band is that wide and a within-band offset cannot
    // spill: change the band layout and this still compiles and starts
    // answering wrongly, which is why the reasoning is here rather than
    // assumed. Depth is clamped into 0.001..0.999, so the index is always in
    // range.
    int layer = LAYER_BANDS - int(floor(depth * float(LAYER_BANDS)));
    vec4 entry = layers.entry[layer - 1];

    vec4 clip;
    if (entry.x == LAYER_CAMERA) {
        // Parallax shifts the world position instead of building a second
        // matrix. The projection is affine, so moving a point by
        // (1 - parallax) * camera before it scales how far the camera carried
        // it and changes nothing else, for two multiply-adds. The shift is
        // exactly zero at parallax one, which is every layer until something
        // says otherwise.
        vec2 placed = world + entry.y * layers.camera.xy;
        // The camera owns the world-to-clip transform, including the Y flip, so
        // this does no coordinate arithmetic of its own.
        clip = view.viewProjection * vec4(placed, 0.0, 1.0);
        // That matrix carries the zoom, so a layer that ignores zoom divides it
        // back out. The mix is exact at both ends, so a layer that takes the
        // zoom multiplies by one.
        clip.xy *= mix(1.0, layers.camera.z, entry.z);
    } else {
        // Screen pixels and virtual coordinates are one projection with two
        // divisors: both measure from the top left with Y running down, so both
        // reach clip through the same negated scale and the same corner offset,
        // and only the size of the space they are measured in differs.
        vec2 scale = entry.x == LAYER_SCREEN
            ? layers.fixedScale.xy : layers.fixedScale.zw;
        clip = vec4(world * scale + vec2(-1.0, 1.0), 0.0, 1.0);
    }

    gl_Position = clip;

    // Depth goes straight into clip space rather than through the projection:
    // it is already the value the depth test should compare. Scaling by W is
    // what survives the perspective divide, and is a multiply by one under the
    // orthographic projection this has today.
    gl_Position.z = depth * gl_Position.w;

    vColor = self.color;
    vLit = entry.w;

    // The array layer and the clip region share origin.z: the region is the
    // number of whole strides in it and the layer is what is left over.
    float packedSlot = self.origin.z;
    float arrayLayer = mod(packedSlot, LAYER_SLOTS);
    vClip = int(floor(packedSlot / LAYER_SLOTS));

    // Corners run -0.5..0.5, so shifting by a half is the fraction across the
    // frame. Both axes map the same way and neither is flipped: world Y runs
    // down the screen the way texture rows run down the image, and the one
    // negation between them is the camera's, applied to clip space after this.
    // A flip here would compose with that one instead of cancelling it.
    vUV = vec3(mix(self.uvRect.xy, self.uvRect.zw, corner + 0.5), arrayLayer);

    vLocal = corner;
    // Material and parameter share origin.w, which is otherwise spare: the
    // integer part selects, the fraction carries the parameter.
    float packed = self.origin.w;
    vMaterial = int(floor(packed));
    vParam = fract(packed);
}
