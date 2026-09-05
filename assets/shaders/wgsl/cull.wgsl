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
// Two lanes, because what the G-buffer rasterizes and what the forward pass
// blends are two lists over one set of instances. Both are scanned in the same
// dispatch over the one read the pass already pays for: a `vec2<u32>` add under
// the same barriers is the same scan run twice in parallel rather than twice in
// sequence, so the barrier count is what it was.
//
// `args` is a fourth dispatch and not a fourth pass of the scan. It reads what
// the scan produced and turns it into one indirect draw per batch: a batch is a
// run of consecutive instances sharing an image, a sampler and a lane, so its
// survivors are a contiguous run of that lane's visible list and a batch needs
// only where that run starts and how long it is.

const WORKGROUP: u32 = 256u;

// Where a lane's field sits inside the packed slot word, and what it holds: a
// fifteen-bit prefix and a keep bit. The prefix is an offset within a workgroup
// of 256, so fifteen bits is far more than it can reach, and two lanes fit the
// one word the mark pass already writes.
const LANE_BITS: u32 = 16u;
const LANE_FIELD: u32 = 0xffffu;
const LANE_PREFIX: u32 = 0x7fffu;
const LANE_KEEP: u32 = 0x8000u;
const LANE_COUNT: u32 = 2u;

// The lane numbering is a compatibility surface shared with the packet: a batch
// names its lane and this is what the name means.
const LANE_OPAQUE: u32 = 0u;
const LANE_BLEND: u32 = 1u;

// Bit 0 of an instance's flags marks the blended lane.
const FLAG_BLENDED: u32 = 1u;

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
}

@group(0) @binding(0) var<storage, read> instances: array<Instance>;
@group(0) @binding(1) var<storage, read> batches: array<Batch>;
@group(0) @binding(2) var<storage, read_write> slots: array<u32>;
@group(0) @binding(3) var<storage, read_write> blockCounts: array<u32>;
@group(0) @binding(4) var<storage, read_write> visible: array<u32>;
@group(0) @binding(5) var<storage, read_write> drawArgs: array<u32>;
@group(0) @binding(6) var<storage, read_write> batchBase: array<u32>;
@group(0) @binding(7) var<uniform> cull: Cull;

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

var<workgroup> scratch: array<vec2<u32>, 256>;

@compute @workgroup_size(256)
fn markMain(
    @builtin(global_invocation_id) global: vec3<u32>,
    @builtin(local_invocation_id) local: vec3<u32>,
    @builtin(workgroup_id) group: vec3<u32>,
) {
    let i = global.x;
    let t = local.x;

    var keep = vec2<u32>(0u, 0u);
    var blended = false;
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
            // A survivor goes to one lane or the other and never to both, so
            // the two lists partition what the view kept rather than
            // overlapping.
            blended = (instance.flags & FLAG_BLENDED) != 0u;
            if (blended) {
                keep.y = 1u;
            } else {
                keep.x = 1u;
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
        var carried = vec2<u32>(0u, 0u);
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
        slots[i] = word;
    }
    if (t == WORKGROUP - 1u) {
        let total = scratch[t];
        let stridePerLane = blockStride();
        blockCounts[LANE_OPAQUE * stridePerLane + group.x] = total.x;
        blockCounts[LANE_BLEND * stridePerLane + group.x] = total.y;
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
}
