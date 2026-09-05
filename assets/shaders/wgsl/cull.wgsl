// The view cull and the ordered compaction that feed the indirect draws.
//
// Three passes rather than one atomic append, because an atomic gives no
// ordering: the compacted list would come out differently every frame, so
// overlapping geometry swaps which one wins and the scene shimmers. A scan is
// deterministic, so the same scene draws the same way every frame. `mark`
// tests each instance and prefixes the survivors within its workgroup, `scan`
// turns the per-block totals into per-block bases, and `compact` writes each
// survivor at the offset those two agreed on.
//
// Three lanes, because what the G-buffer rasterizes, what the forward pass
// blends, and what casts a shadow are three lists over one set of instances. All
// three are scanned in the same dispatch over the one read the pass already pays
// for: a `vec3<u32>` add under the same barriers is the same scan run three
// times in parallel rather than three times in sequence, so the barrier count is
// what it was.
//
// The shadow lane is culled against a widened view rather than the camera's own.
// A wall just off the left edge throws a shadow that falls on screen, and the
// margin is what stops the cull dropping it.
//
// `args` is a fourth dispatch and not a fourth pass of the scan. It reads what
// the scan produced and turns it into one indirect draw per batch: a batch is a
// run of consecutive instances sharing an image, a sampler and a lane, so its
// survivors are a contiguous run of that lane's visible list and a batch needs
// only where that run starts and how long it is. It writes the shadow lane's
// arguments the same way, at `CAST_FANOUT` entries per surviving caster.
//
// `cast` is a fifth dispatch and runs after `compact`. It expands each surviving
// caster into its fixed run of entries, and that is where the light loop lives:
// `mark` stays a bounds-only pass over every instance in the world, which is
// what keeps it cheap, and this runs its loop only for the handful of instances
// that reached the lane.

const WORKGROUP: u32 = 256u;

// Where a lane's field sits inside the packed slot word, and what it holds: a
// nine-bit prefix and a keep bit. The prefix is an offset within a workgroup of
// 256, so nine bits is more than it can reach, and three lanes of ten bits fit
// the one word the mark pass already writes.
const LANE_BITS: u32 = 10u;
const LANE_FIELD: u32 = 0x3ffu;
const LANE_PREFIX: u32 = 0x1ffu;
const LANE_KEEP: u32 = 0x200u;
const LANE_COUNT: u32 = 3u;

// The lane numbering is a compatibility surface shared with the packet: a batch
// names its lane and this is what the name means. The shadow lane has no batch
// of its own; it is the third list over the same instances.
const LANE_OPAQUE: u32 = 0u;
const LANE_BLEND: u32 = 1u;
const LANE_CAST: u32 = 2u;

// Bit 0 of an instance's flags marks the blended lane, bit 1 an occluder, and
// bit 2 a drop-shadow caster.
const FLAG_BLENDED: u32 = 1u;
const FLAG_OCCLUDER: u32 = 2u;
const FLAG_CASTS: u32 = 6u;

// Entries the shadow lane emits per caster, and the packing of one. The same
// constants live in `cast.wgsl`, which draws the list this fills. Nine light
// bits rather than eight because two values above the light ceiling have to be
// sayable, and what is left is 23 bits of instance index.
const CAST_FANOUT: u32 = 4u;
const CAST_LIGHT_BITS: u32 = 9u;
const CAST_EMPTY: u32 = 0x1feu;
const CAST_NONE: u32 = 0x1ffu;

// Below this a light throws no copy at all, which is what stops a caster
// spending a run of its entries on lights at the very edge of their reach.
const CAST_MIN_WEIGHT: f32 = 0.05;

struct Light {
    position: vec4<f32>,
    color: vec4<f32>,
}

struct Instance {
    position: vec4<f32>,
    scale: vec4<f32>,
    uvRect: vec4<f32>,
    color: vec4<f32>,
    material: u32,
    flags: u32,
    reserved0: u32,
    reserved1: u32,
}

struct Batch {
    image: u32,
    sampler: u32,
    lane: u32,
    first: u32,
    count: u32,
}

struct Cull {
    // World-space rectangle the camera can see: min xy, max xy.
    view: vec4<f32>,
    // Instance count, workgroup count, one lane's visible-list capacity, and
    // the batch count.
    counts: vec4<u32>,
    // x how many lights the buffer holds, y how many casters the cast list has
    // room for, z the word the cast list begins at inside `visible`, w the word
    // the shadow lane's bases begin at inside `batchBase`.
    //
    // Three of the shadow lane's four buffers live inside the ones the drawing
    // lanes already bind, at an offset rather than in a binding of their own.
    // WebGPU guarantees eight storage buffers per stage and the cull would have
    // wanted eleven, and the alternative of asking the adapter for more would
    // trade a portable frame for four bindings.
    extra: vec4<u32>,
    // x the world units the shadow lane widens the view by.
    shadow: vec4<f32>,
}

@group(0) @binding(0) var<storage, read> instances: array<Instance>;
@group(0) @binding(1) var<storage, read> batches: array<Batch>;
@group(0) @binding(2) var<storage, read_write> slots: array<u32>;
@group(0) @binding(3) var<storage, read_write> blockCounts: array<u32>;
@group(0) @binding(4) var<storage, read_write> visible: array<u32>;
@group(0) @binding(5) var<storage, read_write> drawArgs: array<u32>;
@group(0) @binding(6) var<storage, read_write> batchBase: array<u32>;
@group(0) @binding(7) var<uniform> cull: Cull;
@group(0) @binding(8) var<storage, read> lights: array<Light>;

fn laneShift(lane: u32) -> u32 {
    return lane * LANE_BITS;
}

// The counts table holds one extra entry per lane, which the scan fills with
// that lane's total. `laneOffsetAt` reads it for the index one past the end,
// which is what a batch's length is measured against.
fn blockStride() -> u32 {
    return cull.counts.y + 1u;
}

// How many survivors of one lane precede an instance index, counting survivors
// only and defined for every index from zero to the instance count.
fn laneOffsetAt(lane: u32, at: u32) -> u32 {
    let stride = blockStride();
    if (at >= cull.counts.x) {
        return blockCounts[lane * stride + cull.counts.y];
    }
    let base = blockCounts[lane * stride + at / WORKGROUP];
    return base + ((slots[at] >> laneShift(lane)) & LANE_PREFIX);
}

var<workgroup> scratch: array<vec3<u32>, 256>;

@compute @workgroup_size(256)
fn markMain(
    @builtin(global_invocation_id) global: vec3<u32>,
    @builtin(local_invocation_id) local: vec3<u32>,
    @builtin(workgroup_id) group: vec3<u32>,
) {
    let i = global.x;
    let t = local.x;

    var keep = vec3<u32>(0u, 0u, 0u);
    if (i < cull.counts.x) {
        let instance = instances[i];
        // A rotated quad's axis-aligned bound, which is conservative: the cull
        // may keep something it would have dropped and may never drop
        // something it would have kept.
        let half = abs(instance.scale.xy) * 0.5;
        let c = abs(cos(instance.position.z));
        let s = abs(sin(instance.position.z));
        let extent = vec2<f32>(half.x * c + half.y * s, half.x * s + half.y * c);
        let center = instance.position.xy;
        // Tested in world space, so panning and zooming change what survives
        // rather than only what is drawn.
        let outside = center.x + extent.x < cull.view.x || center.x - extent.x > cull.view.z
            || center.y + extent.y < cull.view.y || center.y - extent.y > cull.view.w;
        if (!outside) {
            // A survivor goes to one drawing lane or the other and never to
            // both, so the two lists partition what the view kept rather than
            // overlapping.
            if ((instance.flags & FLAG_BLENDED) != 0u) {
                keep.y = 1u;
            } else {
                keep.x = 1u;
            }
        }
        // The shadow lane is separate from the two above rather than exclusive
        // of them: a caster is drawn and casts. Its view is widened by the
        // margin, so a caster just off the edge still throws a shadow onto it.
        if ((instance.flags & FLAG_CASTS) != 0u) {
            let margin = cull.shadow.x;
            let far = center.x + extent.x < cull.view.x - margin
                || center.x - extent.x > cull.view.z + margin
                || center.y + extent.y < cull.view.y - margin
                || center.y - extent.y > cull.view.w + margin;
            if (!far) {
                keep.z = 1u;
            }
        }
    }

    // Inclusive scan across the workgroup, once per lane. Each survivor learns
    // how many entries of its own lane precede it here, which is its offset
    // inside this block of that lane's list.
    scratch[t] = keep;
    workgroupBarrier();
    var stride = 1u;
    loop {
        if (stride >= WORKGROUP) {
            break;
        }
        var carried = vec3<u32>(0u, 0u, 0u);
        if (t >= stride) {
            carried = scratch[t - stride];
        }
        workgroupBarrier();
        scratch[t] = scratch[t] + carried;
        workgroupBarrier();
        stride = stride << 1u;
    }

    if (i < cull.counts.x) {
        // The exclusive prefix is written for every instance rather than for
        // survivors alone, because the batch arguments need the offset at an
        // index they did not choose and cannot know is a survivor.
        let exclusive = scratch[t] - keep;
        var word = (exclusive.x & LANE_PREFIX) | select(0u, LANE_KEEP, keep.x != 0u);
        word = word | (((exclusive.y & LANE_PREFIX) | select(0u, LANE_KEEP, keep.y != 0u)) << LANE_BITS);
        word = word
            | (((exclusive.z & LANE_PREFIX) | select(0u, LANE_KEEP, keep.z != 0u)) << (LANE_BITS * 2u));
        slots[i] = word;
    }
    if (t == WORKGROUP - 1u) {
        let total = scratch[t];
        let stridePerLane = blockStride();
        blockCounts[LANE_OPAQUE * stridePerLane + group.x] = total.x;
        blockCounts[LANE_BLEND * stridePerLane + group.x] = total.y;
        blockCounts[LANE_CAST * stridePerLane + group.x] = total.z;
    }
}

var<workgroup> partial: array<u32, 256>;

// Replaces one lane's per-block counts with their exclusive destination bases
// and answers the lane's total. One workgroup, so the scan is over blocks
// rather than over instances and stays a single dispatch however large the
// scene is: each thread folds a contiguous span serially, the folded totals are
// scanned, and the span is rewritten in place as running bases.
fn scanLane(lane: u32, blocks: u32, t: u32) -> u32 {
    let stride = blockStride();
    let span = (blocks + WORKGROUP - 1u) / WORKGROUP;
    let begin = min(t * span, blocks);
    let end = min(begin + span, blocks);

    var sum = 0u;
    for (var index = begin; index < end; index = index + 1u) {
        sum = sum + blockCounts[lane * stride + index];
    }

    partial[t] = sum;
    workgroupBarrier();
    var step = 1u;
    loop {
        if (step >= WORKGROUP) {
            break;
        }
        var carried = 0u;
        if (t >= step) {
            carried = partial[t - step];
        }
        workgroupBarrier();
        partial[t] = partial[t] + carried;
        workgroupBarrier();
        step = step << 1u;
    }

    var base = partial[t] - sum;
    for (var index = begin; index < end; index = index + 1u) {
        let count = blockCounts[lane * stride + index];
        blockCounts[lane * stride + index] = base;
        base = base + count;
    }
    let total = partial[WORKGROUP - 1u];
    workgroupBarrier();
    if (t == 0u) {
        blockCounts[lane * stride + blocks] = total;
    }
    workgroupBarrier();
    return total;
}

@compute @workgroup_size(256)
fn scanMain(@builtin(local_invocation_id) local: vec3<u32>) {
    let t = local.x;
    let blocks = cull.counts.y;
    for (var lane = 0u; lane < LANE_COUNT; lane = lane + 1u) {
        let unused = scanLane(lane, blocks, t);
    }
}

@compute @workgroup_size(256)
fn compactMain(@builtin(global_invocation_id) global: vec3<u32>, @builtin(workgroup_id) group: vec3<u32>) {
    let i = global.x;
    if (i >= cull.counts.x) {
        return;
    }
    let word = slots[i];
    let stride = blockStride();
    let capacity = cull.counts.z;
    for (var lane = 0u; lane < LANE_COUNT; lane = lane + 1u) {
        let field = (word >> laneShift(lane)) & LANE_FIELD;
        if ((field & LANE_KEEP) != 0u) {
            let at = blockCounts[lane * stride + group.x] + (field & LANE_PREFIX);
            // Past the end is dropped rather than wrapped. The batch arguments
            // hold their draws to the same ceiling, so what is dropped here is
            // what the draw already stopped short of, and both are the
            // survivors earliest in the buffer.
            if (at < capacity) {
                visible[lane * capacity + at] = i;
            }
        }
    }
}

@compute @workgroup_size(64)
fn argsMain(@builtin(global_invocation_id) global: vec3<u32>) {
    let b = global.x;
    if (b >= cull.counts.w) {
        return;
    }
    let batchValue = batches[b];
    let capacity = cull.counts.z;
    let start = min(laneOffsetAt(batchValue.lane, batchValue.first), capacity);
    let stop = min(laneOffsetAt(batchValue.lane, batchValue.first + batchValue.count), capacity);

    batchBase[b] = batchValue.lane * capacity + start;
    // Six vertices for the two triangles of a quad, then the surviving
    // instances, then the first vertex and the first instance, both zero: the
    // base the vertex shader adds comes from `batchBase` rather than from a
    // first-instance offset, which is not core to every backend.
    drawArgs[b * 4u + 0u] = 6u;
    drawArgs[b * 4u + 1u] = stop - start;
    drawArgs[b * 4u + 2u] = 0u;
    drawArgs[b * 4u + 3u] = 0u;

    // The shadow lane, measured the same way and multiplied out by the fan-out.
    // A batch's casters are a contiguous run of the cast lane for the same
    // reason its drawn instances are a contiguous run of its own lane, so the
    // three shadow draws bind this batch's image and draw only its entries.
    let casters = cull.extra.y;
    let castStart = min(laneOffsetAt(LANE_CAST, batchValue.first), casters);
    let castStop = min(laneOffsetAt(LANE_CAST, batchValue.first + batchValue.count), casters);
    batchBase[cull.extra.w + b] = castStart * CAST_FANOUT;
    let castAt = (cull.counts.w + b) * 4u;
    drawArgs[castAt + 0u] = 6u;
    drawArgs[castAt + 1u] = (castStop - castStart) * CAST_FANOUT;
    drawArgs[castAt + 2u] = 0u;
    drawArgs[castAt + 3u] = 0u;
}

fn castPack(instance: u32, light: u32) -> u32 {
    return (instance << CAST_LIGHT_BITS) | light;
}

// How much of a light reaches a point, which decides both which lights a caster
// keeps and how dark the copy each one throws is. `cast.wgsl` darkens by this
// same falloff, and the two have to agree: a shadow selected as the strongest
// and then drawn at another weight is a shadow that pops when an unrelated light
// moves.
fn castWeight(toLight: vec3<f32>, radius: f32, intensity: f32) -> f32 {
    let reach = max(radius, 1.0);
    let attenuation = clamp(1.0 - length(toLight) / reach, 0.0, 1.0);
    return intensity * attenuation * attenuation;
}

@compute @workgroup_size(256)
fn castMain(@builtin(global_invocation_id) global: vec3<u32>) {
    let k = global.x;
    let stride = blockStride();
    let total = blockCounts[LANE_CAST * stride + cull.counts.y];
    // A run is dropped whole rather than truncated. Half a run would leave a
    // caster's later entries holding whatever the last frame wrote there, and
    // the rank a draw derives from a position would name the wrong caster.
    if (k >= total || k >= cull.extra.y) {
        return;
    }
    let source = visible[LANE_CAST * cull.counts.z + k];
    let instance = instances[source];
    let at = cull.extra.z + k * CAST_FANOUT;

    if ((instance.flags & FLAG_OCCLUDER) != 0u) {
        // An occluder's silhouette goes into the mask once, at its own
        // transform. The rest of its run is filled rather than left, because a
        // stale entry from an earlier frame draws a shadow for an instance that
        // has gone.
        visible[at] = castPack(source, CAST_NONE);
        for (var j = 1u; j < CAST_FANOUT; j = j + 1u) {
            visible[at + j] = castPack(source, CAST_EMPTY);
        }
        return;
    }

    // Where the caster meets the ground, which is the bottom of its bound: a
    // shadow is thrown from a thing's feet and not from its middle.
    let foot = instance.position.xy + vec2<f32>(0.0, abs(instance.scale.y) * 0.5);

    // The four strongest, kept by a fixed comparison network rather than by
    // indexing an array, so there is no dynamic indexing inside a loop that is
    // already running. Ties keep the light earlier in the buffer, which is what
    // makes the result the same for the same scene rather than the same for the
    // same schedule. The width here is `CAST_FANOUT` written out; the two only
    // work while they agree.
    var w0 = 0.0;
    var w1 = 0.0;
    var w2 = 0.0;
    var w3 = 0.0;
    var s0 = CAST_EMPTY;
    var s1 = CAST_EMPTY;
    var s2 = CAST_EMPTY;
    var s3 = CAST_EMPTY;

    let lightCount = cull.extra.x;
    for (var l = 0u; l < lightCount; l = l + 1u) {
        let light = lights[l];
        let toLight = vec3<f32>(light.position.xy - foot, light.position.z);
        let w = castWeight(toLight, light.position.w, light.color.a);
        if (w < CAST_MIN_WEIGHT) {
            continue;
        }
        if (w > w0) {
            w3 = w2;
            s3 = s2;
            w2 = w1;
            s2 = s1;
            w1 = w0;
            s1 = s0;
            w0 = w;
            s0 = l;
        } else if (w > w1) {
            w3 = w2;
            s3 = s2;
            w2 = w1;
            s2 = s1;
            w1 = w;
            s1 = l;
        } else if (w > w2) {
            w3 = w2;
            s3 = s2;
            w2 = w;
            s2 = l;
        } else if (w > w3) {
            w3 = w;
            s3 = l;
        }
    }

    visible[at] = castPack(source, s0);
    visible[at + 1u] = castPack(source, s1);
    visible[at + 2u] = castPack(source, s2);
    visible[at + 3u] = castPack(source, s3);
}
