//! Parsing and validation of the versioned frame packet.
//!
//! The packet is the one thing that crosses from Nupp per frame, and nothing
//! else in this crate reads its bytes. It is untrusted input at an ABI
//! boundary, so every count, stride, offset and enumerated value is checked
//! here rather than trusted into a GPU buffer: a packet that does not describe
//! itself is refused, and the refusal names what did not add up.
//!
//! `src/tecs/internal/framepacket.nupp` documents the layout and is the only
//! writer of it.

use anyhow::{bail, Context, Result};

pub const PACKET_MAGIC: u32 = 0x5445_4353;
pub const PACKET_VERSION: u32 = 6;
pub const PACKET_HEADER_SIZE: usize = 128;
pub const BATCH_STRIDE: usize = 20;
pub const INSTANCE_STRIDE: usize = 80;
pub const LIGHT_STRIDE: usize = 32;

/// Lights one frame resolves, matching `tecs.gfx.lighting.MAX_LIGHTS`. A packet
/// naming more is refused rather than silently truncated, because the extractor
/// applies the ceiling and one that did not is a sender this backend does not
/// understand.
pub const MAX_LIGHTS: u32 = 256;

/// Every filter paired with every address mode, matching
/// `tecs.gfx.images.SAMPLER_COUNT` and its `address * 2 + filter` encoding.
pub const SAMPLER_COUNT: u32 = 6;

/// The G-buffer lane, the blended lane, and the shadow lane. The numbering is a
/// compatibility surface shared with `tecs.internal.framepacket` and the cull
/// shader. Only the first two are named by a batch; the third is a third list
/// over the same instances and no batch selects it.
pub const LANE_COUNT: u32 = 3;
pub const LANE_OPAQUE: u32 = 0;
pub const LANE_BLEND: u32 = 1;
// Named for the shader and the tests it is shared with; the frame itself never
// selects the shadow lane by number, because no batch belongs to it.
#[allow(dead_code)]
pub const LANE_CAST: u32 = 2;

/// How many lanes a batch may name, which is the two drawing lanes.
pub const DRAW_LANE_COUNT: u32 = 2;

/// Cast-list entries one caster occupies, matching
/// `tecs.gfx.lighting.CAST_FANOUT` and the two shadow shaders.
pub const CAST_FANOUT: u32 = 4;

/// Bit 0 of an instance's flags marks the blended lane, bit 1 an occluder, and
/// bit 2 a drop-shadow caster.
const FLAG_BLENDED: u32 = 1;
const FLAG_OCCLUDER: u32 = 2;
const FLAG_DROP_SHADOW: u32 = 4;
const FLAG_CASTS: u32 = FLAG_OCCLUDER | FLAG_DROP_SHADOW;
const FLAG_CLIPPED: u32 = 8;
const FLAG_ALL: u32 = FLAG_BLENDED | FLAG_OCCLUDER | FLAG_DROP_SHADOW | FLAG_CLIPPED;

/// Bit 0 of the header's flags runs the shadow lane, bit 1 the bloom chain.
pub const FRAME_SHADOWS: u32 = 1;
pub const FRAME_BLOOM: u32 = 2;
pub const FRAME_RETAINED: u32 = 4;
pub const FRAME_DELTA: u32 = 8;
const FRAME_ALL: u32 = FRAME_SHADOWS | FRAME_BLOOM | FRAME_RETAINED | FRAME_DELTA;

/// Byte offset of an instance's flags word.
const INSTANCE_FLAGS_OFFSET: usize = 68;

/// Byte offset of an instance's material id.
const INSTANCE_MATERIAL_OFFSET: usize = 64;

/// One run of consecutive instances sharing an image, a sampler and a lane.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Batch {
    pub image: u32,
    pub sampler: u32,
    pub lane: u32,
    pub first: u32,
    pub count: u32,
}

/// The number of floats in the scene uniform every pass binds.
pub const SCENE_FLOATS: usize = 32;

/// What the header says about the frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Header {
    /// Rebuild the graph when this differs from the one it was built from.
    pub graph_revision: u32,
    /// Bit 0 runs the shadow lane, bit 1 the bloom chain.
    pub flags: u32,
    /// Render target width and height in pixels.
    pub target: [f32; 2],
    /// View center in world units.
    pub camera: [f32; 2],
    pub zoom: f32,
    pub rotation: f32,
    /// The light every surface receives before any light entity is counted.
    pub ambient: [f32; 3],
    /// March samples at full attenuation.
    pub shadow_steps: f32,
    /// World height a caster at height one stands.
    pub shadow_height: f32,
    /// World units outside the view a caster is still kept, which is also how
    /// far the occluder mask's projection is widened.
    pub shadow_margin: f32,
    /// Drop-shadow darkness at full weight, and the longest one may be.
    pub drop_opacity: f32,
    pub drop_length: f32,
    /// Bloom threshold, knee and intensity.
    pub bloom: [f32; 3],
}

impl Header {
    pub fn shadows(&self) -> bool {
        self.flags & FRAME_SHADOWS != 0
    }

    pub fn bloom_enabled(&self) -> bool {
        self.flags & FRAME_BLOOM != 0
    }

    /// Returns the world-space rectangle the camera can see, as min xy and max
    /// xy, which is what the cull tests an instance's bound against.
    ///
    /// The view is a rotated rectangle and this is its axis-aligned bound, so
    /// the cull may keep something it could have dropped and never drops
    /// something it should have kept.
    pub fn world_view(&self) -> [f32; 4] {
        let half = [
            self.target[0] * 0.5 / self.zoom,
            self.target[1] * 0.5 / self.zoom,
        ];
        let c = self.rotation.cos().abs();
        let s = self.rotation.sin().abs();
        let extent = [half[0] * c + half[1] * s, half[0] * s + half[1] * c];
        [
            self.camera[0] - extent[0],
            self.camera[1] - extent[1],
            self.camera[0] + extent[0],
            self.camera[1] + extent[1],
        ]
    }

    /// Returns the world-to-mask-UV transform, as a 2x2 in row order then the
    /// offset that goes with it.
    ///
    /// The mask covers the camera's own view rectangle widened by the shadow
    /// margin on all four sides, measured in the camera's rotated frame rather
    /// than an axis-aligned one: a turned camera would otherwise spend the mask
    /// on corners it cannot see. The projection stays orthographic, so it
    /// inverts to exactly these six numbers and the march pays two multiply-adds
    /// per sample instead of a matrix by a vector.
    ///
    /// The two axes take different scales when the view is not square, which is
    /// harmless: a march maps both of its endpoints through this one transform,
    /// so what it compares are heights and never distances.
    pub fn mask_transform(&self) -> ([f32; 4], [f32; 2]) {
        let half_x = self.target[0] * 0.5 / self.zoom + self.shadow_margin;
        let half_y = self.target[1] * 0.5 / self.zoom + self.shadow_margin;
        let c = self.rotation.cos();
        let s = self.rotation.sin();
        let row0 = [c / (2.0 * half_x), s / (2.0 * half_x)];
        let row1 = [-s / (2.0 * half_y), c / (2.0 * half_y)];
        let offset = [
            0.5 - (row0[0] * self.camera[0] + row0[1] * self.camera[1]),
            0.5 - (row1[0] * self.camera[0] + row1[1] * self.camera[1]),
        ];
        ([row0[0], row0[1], row1[0], row1[1]], offset)
    }

    /// Builds the scene uniform every pass binds at group zero.
    ///
    /// `light_count` rides here rather than in the packet's own words because
    /// the extractor's ceiling has already been applied by the time this is
    /// built.
    pub fn scene(&self, light_count: u32) -> [f32; SCENE_FLOATS] {
        let view = self.world_view();
        let (transform, offset) = self.mask_transform();
        let shadows = if self.shadows() { 1.0 } else { 0.0 };
        [
            self.target[0],
            self.target[1],
            self.camera[0],
            self.camera[1],
            self.zoom,
            self.rotation,
            0.0,
            0.0,
            self.ambient[0],
            self.ambient[1],
            self.ambient[2],
            shadows,
            view[0],
            view[1],
            view[2],
            view[3],
            transform[0],
            transform[1],
            transform[2],
            transform[3],
            offset[0],
            offset[1],
            self.shadow_steps,
            self.shadow_height,
            self.drop_opacity,
            self.drop_length,
            self.shadow_margin,
            light_count as f32,
            self.bloom[0],
            self.bloom[1],
            self.bloom[2],
            if self.bloom_enabled() { 1.0 } else { 0.0 },
        ]
    }
}

/// One parsed packet, borrowing the caller's bytes.
#[derive(Debug)]
pub struct Packet<'a> {
    pub header: Header,
    pub scene_revision: u32,
    pub retained: bool,
    pub delta: bool,
    pub updates: Vec<InstanceUpdate<'a>>,
    /// The encoded graph declaration, parsed only when the revision changes.
    pub graph: &'a [u8],
    /// The light table, as bytes, for the buffer the binning and the resolve
    /// both read.
    pub light_bytes: &'a [u8],
    pub light_count: u32,
    /// Instances carrying a cast flag, which is what sizes the cast list.
    pub caster_count: u32,
    pub instance_count: u32,
    /// The batch table, as bytes, for the buffer the cull binds.
    pub batch_bytes: &'a [u8],
}

/// Bytes to copy into the persistent instance buffer, with validated flags.
#[derive(Debug)]
pub struct InstanceUpdate<'a> {
    pub offset: u64,
    pub bytes: &'a [u8],
    pub flags: Vec<u8>,
}

/// Identity and layout of instance bytes already validated and uploaded.
#[derive(Clone, Debug)]
pub struct RetainedScene {
    pub revision: u32,
    pub instances: u32,
    pub casters: u32,
    pub batches: Vec<Batch>,
    pub flags: Vec<u8>,
}

/// Parses one packet and fills `batches` with its table.
///
/// `batches` is the caller's, cleared and refilled for a full snapshot.
///
/// `material_count` is how many materials the loaded dispatch answers to. An
/// instance naming an id past it is refused rather than drawn through whatever
/// the dispatch happens to have at that number.
#[cfg(test)]
pub fn parse_packet<'a>(
    bytes: &'a [u8],
    batches: &mut Vec<Batch>,
    material_count: u32,
) -> Result<Packet<'a>> {
    parse_frame(bytes, batches, material_count, None)
}

/// Validates full scenes or dirty ranges against the receiver's resident layout.
/// Retained frames preserve the batch table and never walk instance data.
pub fn parse_frame<'a>(
    bytes: &'a [u8],
    batches: &mut Vec<Batch>,
    material_count: u32,
    resident: Option<&RetainedScene>,
) -> Result<Packet<'a>> {
    if bytes.len() < PACKET_HEADER_SIZE {
        bail!(
            "render packet is {} bytes; header needs {PACKET_HEADER_SIZE}",
            bytes.len()
        );
    }
    let magic = read_u32(bytes, 0);
    if magic != PACKET_MAGIC {
        bail!("render packet has unknown magic {magic:#010x}");
    }
    let version = read_u32(bytes, 4);
    if version != PACKET_VERSION {
        bail!("render packet version {version} is not supported");
    }
    let header_size = read_u32(bytes, 8) as usize;
    if header_size != PACKET_HEADER_SIZE {
        bail!("render packet header size {header_size} is not {PACKET_HEADER_SIZE}");
    }
    let flags = read_u32(bytes, 12);
    if flags & !FRAME_ALL != 0 {
        bail!("render packet frame flags {flags:#010x} set bits this backend does not know");
    }
    let graph_revision = read_u32(bytes, 16);
    let graph_bytes = read_u32(bytes, 20) as usize;
    let batch_stride = read_u32(bytes, 24) as usize;
    if batch_stride != BATCH_STRIDE {
        bail!("render packet batch stride {batch_stride} is not {BATCH_STRIDE}");
    }
    let batch_count = read_u32(bytes, 28);
    let instance_stride = read_u32(bytes, 32) as usize;
    if instance_stride != INSTANCE_STRIDE {
        bail!("render packet instance stride {instance_stride} is not {INSTANCE_STRIDE}");
    }
    let instance_count = read_u32(bytes, 36);

    let target = [read_f32(bytes, 40), read_f32(bytes, 44)];
    if !target[0].is_finite() || !target[1].is_finite() || target[0] <= 0.0 || target[1] <= 0.0 {
        bail!(
            "render packet has invalid render target {}x{}",
            target[0],
            target[1]
        );
    }
    let camera = [read_f32(bytes, 48), read_f32(bytes, 52)];
    let zoom = read_f32(bytes, 56);
    let rotation = read_f32(bytes, 60);
    if !camera[0].is_finite() || !camera[1].is_finite() || !rotation.is_finite() {
        bail!("render packet has a camera value that is not finite");
    }
    if !zoom.is_finite() || zoom <= 0.0 {
        bail!("render packet camera zoom {zoom} is not greater than zero");
    }

    let light_stride = read_u32(bytes, 64) as usize;
    if light_stride != LIGHT_STRIDE {
        bail!("render packet light stride {light_stride} is not {LIGHT_STRIDE}");
    }
    let light_count = read_u32(bytes, 68);
    if light_count > MAX_LIGHTS {
        bail!("render packet carries {light_count} lights, and one frame resolves {MAX_LIGHTS}");
    }
    let caster_count = read_u32(bytes, 72);
    let scene_revision = read_u32(bytes, 76);
    let retained = flags & FRAME_RETAINED != 0;
    let delta = flags & FRAME_DELTA != 0;
    let partial = retained || delta;
    if retained && delta {
        bail!("render packet cannot retain and patch instances together");
    }
    if retained
        && (scene_revision == 0 || resident.is_none_or(|scene| scene.revision != scene_revision))
    {
        bail!("render packet references an instance generation that is not resident");
    }
    let ambient = [
        read_f32(bytes, 80),
        read_f32(bytes, 84),
        read_f32(bytes, 88),
    ];
    let shadow_steps = read_f32(bytes, 92);
    let shadow_height = read_f32(bytes, 96);
    let shadow_margin = read_f32(bytes, 100);
    let drop_opacity = read_f32(bytes, 104);
    let drop_length = read_f32(bytes, 108);
    let bloom = [
        read_f32(bytes, 112),
        read_f32(bytes, 116),
        read_f32(bytes, 120),
    ];
    if read_u32(bytes, 124) != 0 {
        bail!("render packet sets a reserved header word");
    }
    for value in ambient {
        if !value.is_finite() || value < 0.0 {
            bail!("render packet ambient channel {value} is not finite and at or above zero");
        }
    }
    // The shadow and bloom words are written whether or not their flag is set,
    // so they are held to their ranges only where the frame reads them.
    if flags & FRAME_SHADOWS != 0 {
        if !(4.0..=4096.0).contains(&shadow_steps) {
            bail!(
                "render packet asks for {shadow_steps} shadow march steps, and four is the floor"
            );
        }
        if !shadow_height.is_finite() || shadow_height <= 0.0 {
            bail!("render packet shadow height {shadow_height} is not above zero");
        }
        if !shadow_margin.is_finite() || shadow_margin < 0.0 {
            bail!("render packet shadow margin {shadow_margin} is negative");
        }
        if !(0.0..=1.0).contains(&drop_opacity) {
            bail!("render packet drop shadow opacity {drop_opacity} is outside zero to one");
        }
        if !drop_length.is_finite() || drop_length < 0.0 {
            bail!("render packet drop shadow length {drop_length} is negative");
        }
    }
    if flags & FRAME_BLOOM != 0 {
        for value in bloom {
            if !value.is_finite() || value < 0.0 {
                bail!("render packet bloom value {value} is not finite and at or above zero");
            }
        }
    }

    let light_table_bytes = (light_count as usize)
        .checked_mul(light_stride)
        .context("render packet light byte count overflowed")?;
    let batch_table_bytes = if partial {
        0
    } else {
        (batch_count as usize)
            .checked_mul(batch_stride)
            .context("render packet batch byte count overflowed")?
    };
    let instance_bytes = (instance_count as usize)
        .checked_mul(instance_stride)
        .context("render packet instance byte count overflowed")?;
    let prefix = PACKET_HEADER_SIZE
        .checked_add(graph_bytes)
        .and_then(|size| size.checked_add(light_table_bytes))
        .and_then(|size| size.checked_add(batch_table_bytes))
        .context("render packet size overflowed")?;
    let expected = prefix
        .checked_add(if partial { 0 } else { instance_bytes })
        .context("render packet size overflowed")?;
    if bytes.len() < expected || (!delta && bytes.len() != expected) {
        bail!(
            "render packet is {} bytes; header declares {expected}",
            bytes.len()
        );
    }
    let graph = &bytes[PACKET_HEADER_SIZE..PACKET_HEADER_SIZE + graph_bytes];
    let light_start = PACKET_HEADER_SIZE + graph_bytes;
    let table_start = light_start + light_table_bytes;
    let instance_start = table_start + batch_table_bytes;
    let light_bytes = &bytes[light_start..table_start];
    let batch_bytes = &bytes[table_start..instance_start];
    let instances = &bytes[instance_start..];

    for index in 0..light_count as usize {
        let base = index * light_stride;
        for lane in 0..8 {
            let value = read_f32(light_bytes, base + lane * 4);
            if !value.is_finite() {
                bail!("render packet light {index} holds a value that is not finite");
            }
        }
        let radius = read_f32(light_bytes, base + 12);
        if radius <= 0.0 {
            bail!("render packet light {index} has radius {radius}, which is not above zero");
        }
    }

    if partial {
        let scene = resident.context("render packet patches a scene that is not resident")?;
        // The caller retains this table alongside the resident generation.
        // Partial packets cannot supply or change its contents.
        if scene.instances != instance_count
            || scene.casters != caster_count
            || scene.flags.len() != instance_count as usize
            || scene.batches.len() != batch_count as usize
            || batches.len() != scene.batches.len()
        {
            bail!("render packet changes the layout of retained instances");
        }
    } else {
        batches.clear();
        batches.reserve(batch_count as usize);
        let mut covered = 0_u32;
        for index in 0..batch_count as usize {
            let base = table_start + index * batch_stride;
            let batch = Batch {
                image: read_u32(bytes, base),
                sampler: read_u32(bytes, base + 4),
                lane: read_u32(bytes, base + 8),
                first: read_u32(bytes, base + 12),
                count: read_u32(bytes, base + 16),
            };
            if batch.sampler >= SAMPLER_COUNT {
                bail!(
                    "render packet batch {index} selects unknown sampler {}",
                    batch.sampler
                );
            }
            if batch.lane >= DRAW_LANE_COUNT {
                bail!(
                    "render packet batch {index} selects unknown lane {}",
                    batch.lane
                );
            }
            if batch.count == 0 {
                bail!("render packet batch {index} draws no instances");
            }
            // The batches have to partition the instances in order, because the
            // draw order is the picture and a gap or an overlap is neither, and
            // because a batch's survivors are only a contiguous run of its lane's
            // visible list while that holds.
            if batch.first != covered {
                bail!(
                    "render packet batch {index} starts at {} rather than {covered}",
                    batch.first
                );
            }
            covered = covered
                .checked_add(batch.count)
                .context("render packet batch coverage overflowed")?;
            if covered > instance_count {
                bail!("render packet batches cover more than {instance_count} instances");
            }
            batches.push(batch);
        }
        if covered != instance_count {
            bail!("render packet batches cover {covered} of {instance_count} instances");
        }
    }

    let mut updates = Vec::new();
    let mut casters = if partial {
        resident.expect("checked resident").casters
    } else {
        0
    };
    if delta {
        if instances.len() < 8 {
            bail!("render packet omits its delta header");
        }
        let base = read_u32(instances, 0);
        let scene = resident.expect("checked resident");
        if base == 0 || base != scene.revision || scene_revision <= base {
            bail!("render packet delta does not follow its resident generation");
        }
        let ranges = read_u32(instances, 4) as usize;
        if ranges == 0 || ranges > 64 {
            bail!("render packet delta range count is outside one to 64");
        }
        let mut cursor = 8 + ranges * 8;
        if cursor > instances.len() {
            bail!("render packet truncates its delta ranges");
        }
        let mut previous_end = 0;
        for index in 0..ranges {
            let offset = read_u32(instances, 8 + index * 8) as usize;
            let length = read_u32(instances, 12 + index * 8) as usize;
            let end = offset
                .checked_add(length)
                .context("delta range overflowed")?;
            if length == 0
                || offset % INSTANCE_STRIDE != 0
                || length % INSTANCE_STRIDE != 0
                || offset < previous_end
                || end > instance_bytes
            {
                bail!("render packet has an invalid or overlapping delta range");
            }
            previous_end = end;
            let data_end = cursor
                .checked_add(length)
                .context("delta payload overflowed")?;
            let data = instances
                .get(cursor..data_end)
                .context("render packet truncates a delta payload")?;
            cursor = data_end;
            let first = offset / INSTANCE_STRIDE;
            let flags = validate_instances(data, first as u32, batches, material_count)?;
            for (at, flag) in flags.iter().enumerate() {
                casters -= u32::from(scene.flags[first + at] & FLAG_CASTS as u8 != 0);
                casters += u32::from(flag & FLAG_CASTS as u8 != 0);
            }
            updates.push(InstanceUpdate {
                offset: offset as u64,
                bytes: data,
                flags,
            });
        }
        if cursor != instances.len() {
            bail!("render packet has trailing delta bytes");
        }
    } else if !retained {
        let flags = validate_instances(instances, 0, batches, material_count)?;
        casters = flags
            .iter()
            .filter(|flag| **flag & FLAG_CASTS as u8 != 0)
            .count() as u32;
        if !instances.is_empty() {
            updates.push(InstanceUpdate {
                offset: 0,
                bytes: instances,
                flags,
            });
        }
    }
    if casters != caster_count {
        bail!("render packet declares {caster_count} casters and its instances hold {casters}");
    }

    Ok(Packet {
        scene_revision,
        retained,
        delta,
        updates,
        header: Header {
            graph_revision,
            flags,
            target,
            camera,
            zoom,
            rotation,
            ambient,
            shadow_steps,
            shadow_height,
            shadow_margin,
            drop_opacity,
            drop_length,
            bloom,
        },
        graph,
        light_bytes,
        light_count,
        caster_count,
        instance_count,
        batch_bytes,
    })
}

fn validate_instances(
    bytes: &[u8],
    first: u32,
    batches: &[Batch],
    material_count: u32,
) -> Result<Vec<u8>> {
    let mut flags = Vec::with_capacity(bytes.len() / INSTANCE_STRIDE);
    let mut batch = batches.partition_point(|batch| batch.first + batch.count <= first);
    for (at, instance) in bytes.chunks_exact(INSTANCE_STRIDE).enumerate() {
        let slot = first + at as u32;
        while batch < batches.len() && slot >= batches[batch].first + batches[batch].count {
            batch += 1;
        }
        let lane = batches
            .get(batch)
            .context("instance lies outside the batch table")?
            .lane;
        let material = read_u32(instance, INSTANCE_MATERIAL_OFFSET);
        if material >= material_count {
            bail!("render packet instance {slot} selects material {material}, and the loaded dispatch carries {material_count}");
        }
        let flag = read_u32(instance, INSTANCE_FLAGS_OFFSET);
        if flag & !FLAG_ALL != 0 {
            bail!("render packet instance {slot} sets reserved flag bits");
        }
        if flag & FLAG_CASTS == FLAG_CASTS {
            bail!("render packet instance {slot} is both an occluder and a drop-shadow caster, and an entity carrying both is an occluder");
        }
        if flag & FLAG_BLENDED != 0 && flag & FLAG_CASTS != 0 {
            bail!("render packet instance {slot} is blended and casts, and a blended entity casts nothing");
        }
        if u32::from(flag & FLAG_BLENDED != 0) != lane {
            let blended = u32::from(flag & FLAG_BLENDED != 0);
            bail!("render packet instance {slot} is in lane {blended} and batch {batch} is in lane {lane}");
        }
        for channel in 0..16 {
            if !read_f32(instance, channel * 4).is_finite() {
                bail!("render packet instance {slot} holds a value that is not finite");
            }
        }
        let min = read_u32(instance, 72);
        let max = read_u32(instance, 76);
        if flag & FLAG_CLIPPED != 0 {
            if min & 65535 > max & 65535 || min >> 16 > max >> 16 {
                bail!("render packet instance {slot} has inverted clip bounds");
            }
        } else if min != 0 || max != 0 {
            bail!("render packet instance {slot} sets a reserved word");
        }
        flags.push(flag as u8);
    }
    Ok(flags)
}

fn read_u32(bytes: &[u8], offset: usize) -> u32 {
    u32::from_ne_bytes(
        bytes[offset..offset + 4]
            .try_into()
            .expect("checked header"),
    )
}

fn read_f32(bytes: &[u8], offset: usize) -> f32 {
    f32::from_ne_bytes(
        bytes[offset..offset + 4]
            .try_into()
            .expect("checked header"),
    )
}

#[cfg(test)]
pub mod tests {
    use super::*;

    /// Builds packets a test can bend one field of at a time.
    pub struct PacketBuilder {
        pub header: [u32; 10],
        pub target: [f32; 2],
        pub camera: [f32; 4],
        /// The light stride, count, caster count and reserved word.
        pub counts: [u32; 4],
        /// Overrides the light count the header declares, for a test that wants
        /// one the table does not back.
        pub declared_lights: Option<u32>,
        /// Ambient rgb, the five shadow words, the three bloom words, and the
        /// trailing reserved word read as a float.
        pub tuning: [f32; 12],
        pub graph: Vec<u8>,
        pub lights: Vec<[f32; LIGHT_STRIDE / 4]>,
        pub batches: Vec<[u32; 5]>,
        pub instances: Vec<[u32; INSTANCE_STRIDE / 4]>,
    }

    impl PacketBuilder {
        pub fn new() -> Self {
            Self {
                header: [
                    PACKET_MAGIC,
                    PACKET_VERSION,
                    PACKET_HEADER_SIZE as u32,
                    0,
                    1,
                    0,
                    BATCH_STRIDE as u32,
                    0,
                    INSTANCE_STRIDE as u32,
                    0,
                ],
                target: [640.0, 360.0],
                camera: [320.0, 180.0, 1.0, 0.0],
                counts: [LIGHT_STRIDE as u32, 0, 0, 0],
                declared_lights: None,
                tuning: [
                    1.0, 1.0, 1.0, 24.0, 64.0, 200.0, 0.4, 512.0, 0.8, 0.1, 0.7, 0.0,
                ],
                graph: Vec::new(),
                lights: Vec::new(),
                batches: Vec::new(),
                instances: Vec::new(),
            }
        }

        pub fn graph(mut self, bytes: Vec<u8>) -> Self {
            self.graph = bytes;
            self
        }

        pub fn flags(mut self, value: u32) -> Self {
            self.header[3] = value;
            self
        }

        pub fn light(mut self, x: f32, y: f32, height: f32, radius: f32, intensity: f32) -> Self {
            self.lights
                .push([x, y, height, radius, 1.0, 1.0, 1.0, intensity]);
            self
        }

        pub fn batch(
            mut self,
            image: u32,
            sampler: u32,
            lane: u32,
            first: u32,
            count: u32,
        ) -> Self {
            self.batches.push([image, sampler, lane, first, count]);
            self
        }

        /// Appends `count` instances, each carrying its own index as its x and
        /// the lane given as its flags.
        pub fn instances(mut self, count: u32, lane: u32) -> Self {
            for index in 0..count {
                let mut words = [0_u32; INSTANCE_STRIDE / 4];
                words[0] = (index as f32).to_bits();
                words[INSTANCE_FLAGS_OFFSET / 4] = lane;
                self.instances.push(words);
            }
            self
        }

        /// Marks one already-appended instance as a caster of the given flag at
        /// the given height, and counts it in the header.
        pub fn caster(mut self, at: usize, flag: u32, height: f32) -> Self {
            self.instances[at][INSTANCE_FLAGS_OFFSET / 4] |= flag;
            self.instances[at][7] = height.to_bits();
            self.counts[2] += 1;
            self
        }

        pub fn build(mut self) -> Vec<u8> {
            self.header[5] = self.graph.len() as u32;
            self.header[7] = self.batches.len() as u32;
            self.header[9] = self.instances.len() as u32;
            self.counts[1] = self.declared_lights.unwrap_or(self.lights.len() as u32);
            let mut bytes = Vec::new();
            for value in self.header {
                bytes.extend_from_slice(&value.to_ne_bytes());
            }
            for value in self.target {
                bytes.extend_from_slice(&value.to_ne_bytes());
            }
            for value in self.camera {
                bytes.extend_from_slice(&value.to_ne_bytes());
            }
            for value in self.counts {
                bytes.extend_from_slice(&value.to_ne_bytes());
            }
            for value in self.tuning {
                bytes.extend_from_slice(&value.to_ne_bytes());
            }
            bytes.extend_from_slice(&self.graph);
            for light in &self.lights {
                for value in light {
                    bytes.extend_from_slice(&value.to_ne_bytes());
                }
            }
            for batch in &self.batches {
                for value in batch {
                    bytes.extend_from_slice(&value.to_ne_bytes());
                }
            }
            for instance in &self.instances {
                for value in instance {
                    bytes.extend_from_slice(&value.to_ne_bytes());
                }
            }
            bytes
        }
    }

    fn valid() -> PacketBuilder {
        PacketBuilder::new()
            .instances(3, LANE_OPAQUE)
            .batch(0, 0, LANE_OPAQUE, 0, 2)
            .batch(7, 5, LANE_OPAQUE, 2, 1)
    }

    fn parse(bytes: &[u8]) -> Result<(Packet<'_>, Vec<Batch>)> {
        let mut batches = Vec::new();
        let packet = parse_packet(bytes, &mut batches, 16)?;
        Ok((packet, batches))
    }

    fn rejection(bytes: &[u8]) -> String {
        let mut batches = Vec::new();
        parse_packet(bytes, &mut batches, 16)
            .expect_err("rejected")
            .to_string()
    }

    pub fn retained(full: &[u8], revision: u32) -> Vec<u8> {
        let prefix = PACKET_HEADER_SIZE
            + read_u32(full, 20) as usize
            + read_u32(full, 68) as usize * LIGHT_STRIDE;
        let mut bytes = full[..prefix].to_vec();
        let flags = read_u32(full, 12) | FRAME_RETAINED;
        bytes[12..16].copy_from_slice(&flags.to_ne_bytes());
        bytes[76..80].copy_from_slice(&revision.to_ne_bytes());
        bytes
    }

    pub fn delta(full: &[u8], revision: u32, base: u32, offset: u32, data: &[u8]) -> Vec<u8> {
        let mut bytes = retained(full, revision);
        let flags = (read_u32(&bytes, 12) & !FRAME_RETAINED) | FRAME_DELTA;
        bytes[12..16].copy_from_slice(&flags.to_ne_bytes());
        for word in [base, 1, offset, data.len() as u32] {
            bytes.extend_from_slice(&word.to_ne_bytes());
        }
        bytes.extend_from_slice(data);
        bytes
    }

    fn resident_fixture() -> (Vec<u8>, Vec<Batch>, RetainedScene) {
        let mut fixture =
            PacketBuilder::new()
                .instances(3, LANE_OPAQUE)
                .batch(0, 0, LANE_OPAQUE, 0, 3);
        fixture.counts[3] = 1;
        let bytes = fixture.build();
        let mut batches = Vec::new();
        let packet = parse_packet(&bytes, &mut batches, 16).unwrap();
        let resident = RetainedScene {
            revision: 1,
            instances: 3,
            casters: 0,
            batches: batches.clone(),
            flags: packet.updates[0].flags.clone(),
        };
        (bytes, batches, resident)
    }

    #[test]
    fn retains_validated_instances_without_a_payload() {
        let (full, mut batches, scene) = resident_fixture();
        let bytes = retained(&full, 1);
        let packet = parse_frame(&bytes, &mut batches, 16, Some(&scene)).unwrap();
        assert_eq!(packet.instance_count, 3);
        assert!(packet.updates.is_empty());
        assert!(packet.batch_bytes.is_empty());
        assert!(parse_frame(&bytes, &mut batches, 16, None).is_err());
        assert!(parse_frame(&retained(&full, 2), &mut batches, 16, Some(&scene)).is_err());
        let mut smuggled = bytes;
        smuggled.extend_from_slice(&[0; INSTANCE_STRIDE]);
        assert!(parse_frame(&smuggled, &mut batches, 16, Some(&scene)).is_err());
    }

    #[test]
    fn validates_only_a_delta_against_its_resident_generation() {
        let (full, mut batches, scene) = resident_fixture();
        let mut data = full[full.len() - INSTANCE_STRIDE..].to_vec();
        data[0..4].copy_from_slice(&42_f32.to_ne_bytes());
        let bytes = delta(&full, 2, 1, INSTANCE_STRIDE as u32, &data);
        let packet = parse_frame(&bytes, &mut batches, 16, Some(&scene)).unwrap();
        assert!(packet.delta);
        assert_eq!(packet.updates.len(), 1);
        assert_eq!(packet.updates[0].offset, INSTANCE_STRIDE as u64);
        assert_eq!(packet.updates[0].bytes, data);
        for (offset, value) in [(128, 9_u32), (132, 65), (136, 1), (140, 0), (72, 1)] {
            let mut invalid = bytes.clone();
            invalid[offset..offset + 4].copy_from_slice(&value.to_ne_bytes());
            assert!(
                parse_frame(&invalid, &mut batches, 16, Some(&scene)).is_err(),
                "offset {offset}"
            );
        }
        let mut invalid = bytes.clone();
        invalid[144..148].copy_from_slice(&f32::NAN.to_ne_bytes());
        assert!(parse_frame(&invalid, &mut batches, 16, Some(&scene)).is_err());
        let mut invalid = bytes;
        invalid[144 + INSTANCE_MATERIAL_OFFSET..148 + INSTANCE_MATERIAL_OFFSET]
            .copy_from_slice(&999_u32.to_ne_bytes());
        assert!(parse_frame(&invalid, &mut batches, 16, Some(&scene)).is_err());
    }

    #[test]
    fn parses_a_complete_scene() {
        let bytes = valid().build();
        let (packet, batches) = parse(&bytes).expect("valid packet");
        assert_eq!(packet.instance_count, 3);
        assert_eq!(packet.updates[0].bytes.len(), INSTANCE_STRIDE * 3);
        assert_eq!(packet.graph.len(), 0);
        assert_eq!(packet.header.graph_revision, 1);
        assert_eq!(packet.header.target, [640.0, 360.0]);
        assert_eq!(packet.header.camera, [320.0, 180.0]);
        assert_eq!(packet.header.zoom, 1.0);
        assert_eq!(packet.light_count, 0);
        assert_eq!(packet.caster_count, 0);
        assert_eq!(
            batches,
            vec![
                Batch {
                    image: 0,
                    sampler: 0,
                    lane: LANE_OPAQUE,
                    first: 0,
                    count: 2
                },
                Batch {
                    image: 7,
                    sampler: 5,
                    lane: LANE_OPAQUE,
                    first: 2,
                    count: 1
                },
            ]
        );
    }

    #[test]
    fn parses_an_empty_scene() {
        let bytes = PacketBuilder::new().build();
        let (packet, batches) = parse(&bytes).expect("valid empty packet");
        assert!(packet.updates.is_empty());
        assert!(batches.is_empty());
    }

    #[test]
    fn carries_the_graph_section_through_untouched() {
        let bytes = valid().graph(vec![1, 2, 3, 4, 5, 6, 7, 8]).build();
        let (packet, _) = parse(&bytes).expect("valid packet");
        assert_eq!(packet.graph, &[1, 2, 3, 4, 5, 6, 7, 8]);
    }

    #[test]
    fn reuses_the_callers_batch_vector() {
        let bytes = valid().build();
        let mut batches = Vec::with_capacity(64);
        let pointer = batches.as_ptr();
        parse_packet(&bytes, &mut batches, 16).expect("valid packet");
        parse_packet(&bytes, &mut batches, 16).expect("valid packet");
        assert_eq!(batches.len(), 2);
        assert_eq!(
            batches.as_ptr(),
            pointer,
            "a steady scene reallocates nothing"
        );
    }

    #[test]
    fn rejects_an_old_version() {
        let mut builder = valid();
        builder.header[1] = 2;
        assert!(rejection(&builder.build()).contains("version 2 is not supported"));
    }

    #[test]
    fn rejects_a_foreign_header_size() {
        let mut builder = valid();
        builder.header[2] = 24;
        assert!(rejection(&builder.build()).contains("header size 24"));
    }

    #[test]
    fn rejects_frame_flags_it_does_not_know() {
        let mut builder = valid();
        builder.header[3] = 0x10;
        assert!(rejection(&builder.build()).contains("set bits this backend does not know"));
    }

    #[test]
    fn carries_the_light_table_and_its_ceiling() {
        let bytes = valid()
            .light(10.0, 20.0, 30.0, 40.0, 2.0)
            .light(50.0, 60.0, 70.0, 80.0, 3.0)
            .build();
        let (packet, _) = parse(&bytes).expect("valid packet");
        assert_eq!(packet.light_count, 2);
        assert_eq!(packet.light_bytes.len(), LIGHT_STRIDE * 2);
        assert_eq!(read_f32(packet.light_bytes, 0), 10.0);
        assert_eq!(read_f32(packet.light_bytes, LIGHT_STRIDE + 12), 80.0);

        let mut past = valid();
        past.declared_lights = Some(MAX_LIGHTS + 1);
        assert!(rejection(&past.build()).contains("one frame resolves"));
    }

    #[test]
    fn rejects_a_light_that_cannot_light() {
        let mut dark = valid().light(0.0, 0.0, 1.0, 0.0, 1.0);
        assert!(rejection(&dark.build()).contains("is not above zero"));
        dark = valid().light(0.0, 0.0, 1.0, 8.0, 1.0);
        dark.lights[0][2] = f32::NAN;
        assert!(rejection(&dark.build()).contains("not finite"));
    }

    #[test]
    fn counts_the_casters_its_instances_hold() {
        let bytes = valid()
            .caster(0, FLAG_OCCLUDER, 0.5)
            .caster(1, FLAG_DROP_SHADOW, 0.25)
            .build();
        let (packet, _) = parse(&bytes).expect("valid packet");
        assert_eq!(packet.caster_count, 2);

        let mut miscounted = valid().caster(0, FLAG_OCCLUDER, 1.0);
        miscounted.counts[2] = 3;
        assert!(rejection(&miscounted.build()).contains("declares 3 casters"));
    }

    #[test]
    fn rejects_a_caster_that_cannot_be_one() {
        let both = valid().caster(0, FLAG_OCCLUDER | FLAG_DROP_SHADOW, 1.0);
        let message = rejection(&both.build());
        assert!(
            message.contains("carrying both is an occluder"),
            "{message}"
        );

        let blended = PacketBuilder::new()
            .instances(1, LANE_BLEND)
            .batch(0, 0, LANE_BLEND, 0, 1)
            .caster(0, FLAG_OCCLUDER, 1.0);
        let message = rejection(&blended.build());
        assert!(
            message.contains("blended entity casts nothing"),
            "{message}"
        );
    }

    #[test]
    fn holds_the_shadow_tuning_only_where_the_frame_reads_it() {
        // The words ride in every packet, so a frame with the lane off carries
        // whatever the extractor last wrote and nothing checks it.
        let mut off = valid();
        off.tuning[3] = 0.0;
        assert!(parse(&off.build()).is_ok());

        let mut on = valid().flags(FRAME_SHADOWS);
        on.tuning[3] = 0.0;
        assert!(rejection(&on.build()).contains("four is the floor"));

        let mut dark = valid().flags(FRAME_SHADOWS);
        dark.tuning[6] = 2.0;
        assert!(rejection(&dark.build()).contains("outside zero to one"));

        let mut glow = valid().flags(FRAME_BLOOM);
        glow.tuning[8] = -1.0;
        assert!(rejection(&glow.build()).contains("at or above zero"));
    }

    #[test]
    fn widens_the_occluder_mask_by_the_shadow_margin() {
        let bytes = valid().flags(FRAME_SHADOWS).build();
        let (packet, _) = parse(&bytes).expect("valid packet");
        let (transform, offset) = packet.header.mask_transform();
        // The camera sits at the middle of its own view, which is the middle of
        // the mask however wide the margin makes it.
        let center = [
            transform[0] * 320.0 + transform[1] * 180.0 + offset[0],
            transform[2] * 320.0 + transform[3] * 180.0 + offset[1],
        ];
        assert!((center[0] - 0.5).abs() < 1e-5, "{center:?}");
        assert!((center[1] - 0.5).abs() < 1e-5, "{center:?}");

        // The view's own left edge lands inside the mask rather than on it,
        // because the margin widened the projection past it.
        let view = packet.header.world_view();
        let left = transform[0] * view[0] + transform[1] * 180.0 + offset[0];
        assert!(left > 0.0 && left < 0.5, "{left}");

        // A caster the margin's whole width outside the view still lands inside
        // the mask, which is the point of widening it.
        let outside = transform[0] * (view[0] - 199.0) + transform[1] * 180.0 + offset[0];
        assert!(outside > 0.0, "{outside}");
    }

    #[test]
    fn builds_the_scene_uniform_the_passes_bind() {
        let bytes = valid().flags(FRAME_SHADOWS | FRAME_BLOOM).build();
        let (packet, _) = parse(&bytes).expect("valid packet");
        let scene = packet.header.scene(3);
        assert_eq!(scene.len(), SCENE_FLOATS);
        assert_eq!(&scene[0..6], &[640.0, 360.0, 320.0, 180.0, 1.0, 0.0]);
        // The ambient alpha and the bloom alpha are the two flags, which is what
        // lets one lighting pipeline and one composite pipeline serve a frame
        // with the lane on and a frame with it off.
        assert_eq!(scene[11], 1.0);
        assert_eq!(scene[31], 1.0);
        assert_eq!(&scene[12..16], &packet.header.world_view());
        assert_eq!(scene[22], 24.0, "the march step ceiling");
        assert_eq!(
            scene[23], 64.0,
            "the world height of a full-height occluder"
        );
        assert_eq!(scene[27], 3.0, "the light count the caller applied");

        let dark = valid().build();
        let (packet, _) = parse(&dark).expect("valid packet");
        let scene = packet.header.scene(0);
        assert_eq!(scene[11], 0.0);
        assert_eq!(scene[31], 0.0);
    }

    #[test]
    fn rejects_a_truncated_batch_table() {
        let mut bytes = valid().build();
        bytes.truncate(bytes.len() - 4);
        assert!(rejection(&bytes).contains("header declares"));
    }

    #[test]
    fn rejects_batches_that_leave_a_gap() {
        let bytes = PacketBuilder::new()
            .instances(3, LANE_OPAQUE)
            .batch(0, 0, LANE_OPAQUE, 0, 1)
            .batch(1, 0, LANE_OPAQUE, 2, 1)
            .build();
        assert!(rejection(&bytes).contains("starts at 2 rather than 1"));
    }

    #[test]
    fn rejects_batches_that_do_not_cover_every_instance() {
        let bytes = PacketBuilder::new()
            .instances(3, LANE_OPAQUE)
            .batch(0, 0, LANE_OPAQUE, 0, 2)
            .build();
        assert!(rejection(&bytes).contains("cover 2 of 3 instances"));
    }

    #[test]
    fn rejects_an_empty_batch() {
        let bytes = PacketBuilder::new()
            .instances(1, LANE_OPAQUE)
            .batch(0, 0, LANE_OPAQUE, 0, 0)
            .build();
        assert!(rejection(&bytes).contains("draws no instances"));
    }

    #[test]
    fn rejects_an_unknown_sampler_or_lane() {
        let bytes = PacketBuilder::new()
            .instances(1, LANE_OPAQUE)
            .batch(0, SAMPLER_COUNT, LANE_OPAQUE, 0, 1)
            .build();
        assert!(rejection(&bytes).contains("unknown sampler"));

        let bytes = PacketBuilder::new()
            .instances(1, LANE_OPAQUE)
            .batch(0, 0, DRAW_LANE_COUNT, 0, 1)
            .build();
        assert!(rejection(&bytes).contains("unknown lane"));
    }

    #[test]
    fn rejects_an_instance_whose_lane_is_not_its_batch() {
        let bytes = PacketBuilder::new()
            .instances(1, LANE_BLEND)
            .batch(0, 0, LANE_OPAQUE, 0, 1)
            .build();
        let message = rejection(&bytes);
        assert!(
            message.contains("is in lane 1 and batch 0 is in lane 0"),
            "{message}"
        );
    }

    #[test]
    fn rejects_a_material_the_dispatch_does_not_carry() {
        let mut builder =
            PacketBuilder::new()
                .instances(1, LANE_OPAQUE)
                .batch(0, 0, LANE_OPAQUE, 0, 1);
        builder.instances[0][INSTANCE_MATERIAL_OFFSET / 4] = 16;
        let message = rejection(&builder.build());
        assert!(message.contains("selects material 16"), "{message}");
    }

    #[test]
    fn rejects_reserved_instance_words() {
        let mut builder = valid();
        builder.instances[0][19] = 1;
        assert!(rejection(&builder.build()).contains("reserved word"));

        let mut flagged = valid();
        flagged.instances[0][INSTANCE_FLAGS_OFFSET / 4] = 16;
        assert!(rejection(&flagged.build()).contains("reserved flag bits"));
    }

    #[test]
    fn validates_clipping_bounds() {
        let mut builder = valid();
        builder.instances[0][17] |= FLAG_CLIPPED;
        builder.instances[0][18] = 10 | (20 << 16);
        builder.instances[0][19] = 30 | (40 << 16);
        assert!(parse(&builder.build()).is_ok());
        let mut builder = valid();
        builder.instances[0][17] |= FLAG_CLIPPED;
        builder.instances[0][19] = 30 | (40 << 16);
        builder.instances[0][18] = 31 | (20 << 16);
        assert!(rejection(&builder.build()).contains("inverted clip bounds"));
    }

    #[test]
    fn rejects_a_camera_that_cannot_project() {
        let mut builder = valid();
        builder.camera[2] = 0.0;
        assert!(rejection(&builder.build()).contains("zoom 0 is not greater than zero"));

        let mut turned = valid();
        turned.camera[3] = f32::NAN;
        assert!(rejection(&turned.build()).contains("camera value that is not finite"));
    }

    #[test]
    fn rejects_a_target_with_no_area() {
        let mut builder = valid();
        builder.target[1] = 0.0;
        assert!(rejection(&builder.build()).contains("invalid render target"));
    }

    #[test]
    fn rejects_non_finite_gpu_values() {
        let mut builder = valid();
        builder.instances[0][5] = f32::NAN.to_bits();
        assert!(rejection(&builder.build()).contains("not finite"));
    }

    fn header(target: [f32; 2], camera: [f32; 2], zoom: f32, rotation: f32) -> Header {
        Header {
            graph_revision: 0,
            flags: 0,
            target,
            camera,
            zoom,
            rotation,
            ambient: [1.0, 1.0, 1.0],
            shadow_steps: 24.0,
            shadow_height: 64.0,
            shadow_margin: 200.0,
            drop_opacity: 0.4,
            drop_length: 512.0,
            bloom: [0.8, 0.1, 0.7],
        }
    }

    #[test]
    fn bounds_an_unrotated_view_by_the_camera() {
        let read = header([640.0, 360.0], [100.0, 50.0], 2.0, 0.0);
        assert_eq!(read.world_view(), [-60.0, -40.0, 260.0, 140.0]);
    }

    #[test]
    fn widens_a_rotated_view_to_its_axis_aligned_bound() {
        let read = header([200.0, 100.0], [0.0, 0.0], 1.0, std::f32::consts::FRAC_PI_2);
        let view = read.world_view();
        // A quarter turn swaps the two half extents, and the cull may only ever
        // keep more than the exact view would.
        assert!((view[0] + 50.0).abs() < 1e-3, "{view:?}");
        assert!((view[3] - 100.0).abs() < 1e-3, "{view:?}");
    }

    #[test]
    fn turns_the_occluder_mask_with_the_camera() {
        // A quarter turn puts the world's +x along the mask's -v, which is what
        // keeps a turned camera's mask on what it can see rather than on the
        // corners of an axis-aligned box around it.
        let read = header([200.0, 100.0], [0.0, 0.0], 1.0, std::f32::consts::FRAC_PI_2);
        let (transform, offset) = read.mask_transform();
        let along = [
            transform[0] * 10.0 + offset[0],
            transform[2] * 10.0 + offset[1],
        ];
        assert!((along[0] - 0.5).abs() < 1e-5, "{along:?}");
        assert!(along[1] < 0.5, "{along:?}");
    }
}
