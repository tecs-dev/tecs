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
pub const PACKET_VERSION: u32 = 3;
pub const PACKET_HEADER_SIZE: usize = 64;
pub const BATCH_STRIDE: usize = 20;
pub const INSTANCE_STRIDE: usize = 80;

/// Every filter paired with every address mode, matching
/// `tecs.gfx.images.SAMPLER_COUNT` and its `address * 2 + filter` encoding.
pub const SAMPLER_COUNT: u32 = 6;

/// The G-buffer lane and the blended lane. The numbering is a compatibility
/// surface shared with `tecs.internal.framepacket` and the cull shader.
pub const LANE_COUNT: u32 = 2;
pub const LANE_OPAQUE: u32 = 0;
pub const LANE_BLEND: u32 = 1;

/// Bit 0 of an instance's flags marks the blended lane.
const FLAG_BLENDED: u32 = 1;

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

/// What the header says about the frame, in the order the scene uniform wants
/// its first six words.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Header {
    /// Rebuild the graph when this differs from the one it was built from.
    pub graph_revision: u32,
    /// Target width, target height, camera x, camera y, zoom, rotation, and two
    /// padding words.
    pub scene: [f32; 8],
}

impl Header {
    /// Returns the world-space rectangle the camera can see, as min xy and max
    /// xy, which is what the cull tests an instance's bound against.
    ///
    /// The view is a rotated rectangle and this is its axis-aligned bound, so
    /// the cull may keep something it could have dropped and never drops
    /// something it should have kept.
    pub fn world_view(&self) -> [f32; 4] {
        let width = self.scene[0];
        let height = self.scene[1];
        let camera = [self.scene[2], self.scene[3]];
        let zoom = self.scene[4];
        let rotation = self.scene[5];
        let half = [width * 0.5 / zoom, height * 0.5 / zoom];
        let c = rotation.cos().abs();
        let s = rotation.sin().abs();
        let extent = [half[0] * c + half[1] * s, half[0] * s + half[1] * c];
        [
            camera[0] - extent[0],
            camera[1] - extent[1],
            camera[0] + extent[0],
            camera[1] + extent[1],
        ]
    }
}

/// One parsed packet, borrowing the caller's bytes.
#[derive(Debug)]
pub struct Packet<'a> {
    pub header: Header,
    /// The encoded graph declaration, parsed only when the revision changes.
    pub graph: &'a [u8],
    pub instances: &'a [u8],
    pub instance_count: u32,
    /// The batch table, as bytes, for the buffer the cull binds.
    pub batch_bytes: &'a [u8],
}

/// Parses one packet and fills `batches` with its table.
///
/// `batches` is the caller's, cleared and refilled, so a steady scene parses
/// without allocating.
///
/// `material_count` is how many materials the loaded dispatch answers to. An
/// instance naming an id past it is refused rather than drawn through whatever
/// the dispatch happens to have at that number.
pub fn parse_packet<'a>(
    bytes: &'a [u8],
    batches: &mut Vec<Batch>,
    material_count: u32,
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
    if flags != 0 {
        bail!("render packet reserved flags {flags:#010x} are not zero");
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

    let batch_table_bytes = (batch_count as usize)
        .checked_mul(batch_stride)
        .context("render packet batch byte count overflowed")?;
    let instance_bytes = (instance_count as usize)
        .checked_mul(instance_stride)
        .context("render packet instance byte count overflowed")?;
    let expected = PACKET_HEADER_SIZE
        .checked_add(graph_bytes)
        .and_then(|size| size.checked_add(batch_table_bytes))
        .and_then(|size| size.checked_add(instance_bytes))
        .context("render packet size overflowed")?;
    if bytes.len() != expected {
        bail!(
            "render packet is {} bytes; header declares {expected}",
            bytes.len()
        );
    }

    let graph = &bytes[PACKET_HEADER_SIZE..PACKET_HEADER_SIZE + graph_bytes];
    let table_start = PACKET_HEADER_SIZE + graph_bytes;
    let instance_start = table_start + batch_table_bytes;
    let batch_bytes = &bytes[table_start..instance_start];
    let instances = &bytes[instance_start..];

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
        if batch.lane >= LANE_COUNT {
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

    for (index, batch) in batches.iter().enumerate() {
        for slot in batch.first..batch.first + batch.count {
            let base = slot as usize * instance_stride;
            let material = read_u32(instances, base + INSTANCE_MATERIAL_OFFSET);
            if material >= material_count {
                bail!(
                    "render packet instance {slot} selects material {material}, and the loaded \
                     dispatch carries {material_count}"
                );
            }
            let instance_flags = read_u32(instances, base + INSTANCE_FLAGS_OFFSET);
            if instance_flags & !FLAG_BLENDED != 0 {
                bail!("render packet instance {slot} sets reserved flag bits");
            }
            let blended = u32::from(instance_flags & FLAG_BLENDED != 0);
            // The cull routes an instance by its own flag and the draw finds it
            // through its batch, so the two have to agree or a survivor lands in
            // a list nothing draws.
            if blended != batch.lane {
                bail!(
                    "render packet instance {slot} is in lane {blended} and batch {index} is in \
                     lane {}",
                    batch.lane
                );
            }
        }
    }

    // Only the leading sixteen floats of an instance reach arithmetic; the four
    // trailing words are the material, the flags and two reserved zeroes, and
    // reading those as floats would reject an ordinary id as a denormal.
    for index in 0..instance_count as usize {
        let base = index * instance_stride;
        for lane in 0..16 {
            let value = read_f32(instances, base + lane * 4);
            if !value.is_finite() {
                bail!("render packet instance {index} holds a value that is not finite");
            }
        }
        for word in 18..20 {
            if read_u32(instances, base + word * 4) != 0 {
                bail!("render packet instance {index} sets a reserved word");
            }
        }
    }

    Ok(Packet {
        header: Header {
            graph_revision,
            scene: [
                target[0], target[1], camera[0], camera[1], zoom, rotation, 0.0, 0.0,
            ],
        },
        graph,
        instances,
        instance_count,
        batch_bytes,
    })
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
        pub graph: Vec<u8>,
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
                graph: Vec::new(),
                batches: Vec::new(),
                instances: Vec::new(),
            }
        }

        pub fn graph(mut self, bytes: Vec<u8>) -> Self {
            self.graph = bytes;
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

        pub fn build(mut self) -> Vec<u8> {
            self.header[5] = self.graph.len() as u32;
            self.header[7] = self.batches.len() as u32;
            self.header[9] = self.instances.len() as u32;
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
            bytes.extend_from_slice(&self.graph);
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

    #[test]
    fn parses_a_complete_scene() {
        let bytes = valid().build();
        let (packet, batches) = parse(&bytes).expect("valid packet");
        assert_eq!(packet.instance_count, 3);
        assert_eq!(packet.instances.len(), INSTANCE_STRIDE * 3);
        assert_eq!(packet.graph.len(), 0);
        assert_eq!(packet.header.graph_revision, 1);
        assert_eq!(
            packet.header.scene,
            [640.0, 360.0, 320.0, 180.0, 1.0, 0.0, 0.0, 0.0]
        );
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
        assert!(packet.instances.is_empty());
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
    fn rejects_reserved_flags() {
        let mut builder = valid();
        builder.header[3] = 1;
        assert!(rejection(&builder.build()).contains("reserved flags"));
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
            .batch(0, 0, LANE_COUNT, 0, 1)
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
        flagged.instances[0][INSTANCE_FLAGS_OFFSET / 4] = 2;
        assert!(rejection(&flagged.build()).contains("reserved flag bits"));
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

    #[test]
    fn bounds_an_unrotated_view_by_the_camera() {
        let header = Header {
            graph_revision: 0,
            scene: [640.0, 360.0, 100.0, 50.0, 2.0, 0.0, 0.0, 0.0],
        };
        assert_eq!(header.world_view(), [-60.0, -40.0, 260.0, 140.0]);
    }

    #[test]
    fn widens_a_rotated_view_to_its_axis_aligned_bound() {
        let header = Header {
            graph_revision: 0,
            scene: [
                200.0,
                100.0,
                0.0,
                0.0,
                1.0,
                std::f32::consts::FRAC_PI_2,
                0.0,
                0.0,
            ],
        };
        let view = header.world_view();
        // A quarter turn swaps the two half extents, and the cull may only ever
        // keep more than the exact view would.
        assert!((view[0] + 50.0).abs() < 1e-3, "{view:?}");
        assert!((view[3] - 100.0).abs() < 1e-3, "{view:?}");
    }
}
