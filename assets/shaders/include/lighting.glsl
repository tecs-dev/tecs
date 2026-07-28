// The grid lights are binned into, shared by the pass that fills it and the
// pass that reads it.
//
// A fragment consults the lights whose tile it is in rather than every light
// in the scene, which is what makes many lights affordable: a light's cost
// becomes proportional to what it covers instead of to how many pixels exist.
//
// World space, not screen space and not normalized device coordinates. The
// grid covers the rectangle the camera can see, measured in world units, so a
// light's position and its radius are both already in the space the tiles are
// measured in and the zoom enters once, as the half extent of that rectangle.
// Binning in device coordinates would mean projecting a radius, which is not
// a length under a projection and has to be recovered per light.
//
// The grid is a fixed count rather than a fixed tile size in pixels, so its
// two buffers are allocated once and never resized. A buffer that grew with
// the window would have to be replaced while a frame in flight was still
// reading the old one, and the granularity a resolution-independent grid gives
// up is granularity binning barely uses: what a fragment needs is a short list,
// not the shortest one.

// Tiles the view is divided into on each axis. `lightlayout.TILES` in
// src/tecs/gpu/lightlayout.tl is the same number, and the pair only works
// while they agree.
const int LIGHT_TILES = 32;

// Lights one tile holds. `lightlayout.TILE_SLOTS` is the same number. A tile
// reached by more than this keeps the ones earliest in the light buffer and
// drops the rest, which is a deterministic choice rather than whichever
// arrived first.
const int LIGHT_TILE_SLOTS = 64;

// Which tile a world position falls in.
//
// `bounds` is the world rectangle the grid covers, as minimum xy then maximum
// xy. Clamped rather than tested, because a fragment at the very edge of the
// view can land a rounding error outside the rectangle its own camera
// produced, and the nearest tile is the right answer there.
int lightTileOf(vec2 world, vec4 bounds) {
    vec2 span = max(bounds.zw - bounds.xy, vec2(1e-6));
    vec2 across = (world - bounds.xy) / span;
    ivec2 cell = clamp(ivec2(floor(across * float(LIGHT_TILES))),
                       ivec2(0), ivec2(LIGHT_TILES - 1));
    return cell.y * LIGHT_TILES + cell.x;
}
