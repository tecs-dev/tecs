// The shadow lane's list, shared by the pass that fills it and the three draws
// that read it.
//
// One entry is one `uint`: the instance it came from and the light its copy is
// thrown by. Nothing else has to travel, because everything a stretched copy
// needs is already in the source instance and the light is already a slot in a
// buffer. That is four bytes per shadow rather than a record per shadow, and it
// is what makes the list the same element type as the visible list.
//
// Every caster occupies exactly `CAST_FANOUT` contiguous entries, whether or not
// it has that many lights near it, so an entry's rank within its caster is its
// position in the list modulo the fan-out and costs no bits. That is also what
// makes the two passes that want one entry per caster able to find it: rank zero
// exists for every caster, including one no light reaches.

// Entries the shadow lane emits per caster.
//
// One per light the caster's drop shadow is thrown by: four lights is more than
// any one character stands in, and the fourth is already fainter than a viewer
// picks out. It is uniform across casters, including the occluders that throw
// no copy at all, which is what makes an entry's rank its position modulo this
// and saves carrying one. `instancelayout.CAST_FANOUT` is the same number and
// the comparison network in `instance.cast.comp.glsl` is that many wide.
const uint CAST_FANOUT = 4u;

// Bits an entry gives the light, and the instance index above them. Nine rather
// than eight because two values above the light ceiling have to be sayable, and
// what is left is 23 bits: 8,388,607 instances, against a four million scale
// bar.
const uint CAST_LIGHT_BITS = 9u;
const uint CAST_LIGHT_MASK = 0x1FFu;

// An entry that draws nothing. A caster with fewer lights than the fan-out
// fills the rest of its run with these, which cost four bytes and four vertex
// invocations that return an off-screen position and rasterise nothing.
const uint CAST_EMPTY = 0x1FEu;

// An entry that names the caster rather than a light: an occluder's silhouette,
// and the copy of a drop-shadow caster that stamps it back out of its own
// shadow. Both draw the source instance's own transform.
const uint CAST_NONE = 0x1FFu;

uint castPack(uint instance, uint light) {
    return (instance << CAST_LIGHT_BITS) | light;
}

uint castInstance(uint entry) { return entry >> CAST_LIGHT_BITS; }

uint castLight(uint entry) { return entry & CAST_LIGHT_MASK; }

// Below this a light throws no copy at all. The faintest shadow a viewer can
// pick out is well above it, and the reject is what stops a caster spending a
// run of its entries on lights at the very edge of their reach.
const float CAST_MIN_WEIGHT = 0.05;

// How much of a light reaches a point, which decides both which lights a caster
// keeps and how dark the copy each one throws is.
//
// The same falloff the resolve applies, including the light's height as the
// third axis, so a shadow fades out exactly where the light that cast it does.
// Written here rather than twice because the pass that selects by this and the
// pass that darkens by it have to agree: a shadow selected as the strongest and
// then drawn at another weight is a shadow that pops when an unrelated light
// moves.
// @param toLight From the point to the light, with the light's height as z.
float castWeight(vec3 toLight, float radius, float intensity) {
    float reach = max(radius, 1.0);
    float attenuation = clamp(1.0 - length(toLight) / reach, 0.0, 1.0);
    return intensity * attenuation * attenuation;
}
