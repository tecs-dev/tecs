//! The cull and the ordered compaction, run on a real device.
//!
//! These tests exist for one property above all the others: the visible list is
//! a stable subsequence of packet order, so the same scene compacts to the same
//! order every run. That is the whole reason the compaction is a three-pass scan
//! rather than an atomic append, and it is not something the shape of the code
//! can demonstrate on its own.
//!
//! A machine with no adapter skips rather than fails. The Nupp suite and the
//! rest of the Rust tests cover everything that does not need a GPU, and a
//! headless build server without one should not be told the renderer is broken.

use std::borrow::Cow;

use wgpu::util::DeviceExt;
use wgpu::{
    BindGroupDescriptor, BindGroupEntry, BindGroupLayoutDescriptor, BindGroupLayoutEntry,
    BindingType, BufferBindingType, BufferDescriptor, BufferUsages, CommandEncoderDescriptor,
    ComputePassDescriptor, ComputePipelineDescriptor, Device, DeviceDescriptor, Instance,
    InstanceDescriptor, MapMode, PipelineCompilationOptions, PipelineLayoutDescriptor, PollType,
    Queue, ShaderModuleDescriptor, ShaderSource, ShaderStages,
};

use crate::packet::{
    CAST_FANOUT, INSTANCE_STRIDE, LANE_BLEND, LANE_CAST, LANE_COUNT, LANE_OPAQUE, LIGHT_STRIDE,
};

const CULL_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/cull.wgsl");
const WORKGROUP: u32 = 256;
const ARGS_WORKGROUP: u32 = 64;

/// The storage binding offset alignment, in words. The shadow lane's list and
/// its bases ride inside the two buffers the drawing lanes already bind, so both
/// offsets land on this.
const ALIGNMENT_WORDS: u32 = 64;

fn align_words(words: u32) -> u32 {
    words.div_ceil(ALIGNMENT_WORDS) * ALIGNMENT_WORDS
}

/// One light, as the packet lays it out.
#[derive(Clone, Copy, Debug)]
pub struct TestLight {
    pub x: f32,
    pub y: f32,
    pub height: f32,
    pub radius: f32,
    pub intensity: f32,
}

impl TestLight {
    fn bytes(&self) -> [u8; LIGHT_STRIDE] {
        let words = [
            self.x,
            self.y,
            self.height,
            self.radius,
            1.0,
            1.0,
            1.0,
            self.intensity,
        ];
        let mut bytes = [0_u8; LIGHT_STRIDE];
        for (index, value) in words.iter().enumerate() {
            bytes[index * 4..index * 4 + 4].copy_from_slice(&value.to_ne_bytes());
        }
        bytes
    }
}

/// One instance as the packet lays it out.
#[derive(Clone, Copy, Debug)]
pub struct TestInstance {
    pub x: f32,
    pub y: f32,
    pub rotation: f32,
    pub scale: f32,
    pub lane: u32,
    pub color: [f32; 4],
    pub material: u32,
    pub param: f32,
    /// Bit 1 marks an occluder and bit 2 a drop-shadow caster.
    pub cast: u32,
    pub cast_height: f32,
    pub clip: Option<[u32; 4]>,
}

impl TestInstance {
    pub fn opaque(x: f32, y: f32) -> Self {
        Self {
            x,
            y,
            rotation: 0.0,
            scale: 2.0,
            lane: LANE_OPAQUE,
            color: [1.0, 1.0, 1.0, 1.0],
            material: 0,
            param: 0.25,
            cast: 0,
            cast_height: 0.0,
            clip: None,
        }
    }

    /// The same quad, marked as a caster of the given flag.
    pub fn casting(x: f32, y: f32, flag: u32, height: f32) -> Self {
        Self {
            cast: flag,
            cast_height: height,
            ..Self::opaque(x, y)
        }
    }

    pub fn blended(x: f32, y: f32) -> Self {
        Self {
            lane: LANE_BLEND,
            ..Self::opaque(x, y)
        }
    }

    fn bytes(&self) -> [u8; INSTANCE_STRIDE] {
        let mut words = [0_u32; INSTANCE_STRIDE / 4];
        words[0] = self.x.to_bits();
        words[1] = self.y.to_bits();
        words[2] = self.rotation.to_bits();
        words[4] = self.scale.to_bits();
        words[5] = self.scale.to_bits();
        for (lane, channel) in self.color.iter().enumerate() {
            words[12 + lane] = channel.to_bits();
        }
        words[6] = self.param.to_bits();
        words[7] = self.cast_height.to_bits();
        words[16] = self.material;
        words[17] = self.lane | self.cast;
        if let Some([left, top, right, bottom]) = self.clip {
            words[17] |= 8;
            words[18] = left | (top << 16);
            words[19] = right | (bottom << 16);
        }
        let mut bytes = [0_u8; INSTANCE_STRIDE];
        for (index, word) in words.iter().enumerate() {
            bytes[index * 4..index * 4 + 4].copy_from_slice(&word.to_ne_bytes());
        }
        bytes
    }

    /// Whether the view rectangle keeps it, by the same test the shader makes.
    fn kept(&self, view: [f32; 4]) -> bool {
        let half = self.scale.abs() * 0.5;
        let c = self.rotation.cos().abs();
        let s = self.rotation.sin().abs();
        let extent = [half * c + half * s, half * s + half * c];
        !(self.x + extent[0] < view[0]
            || self.x - extent[0] > view[2]
            || self.y + extent[1] < view[1]
            || self.y - extent[1] > view[3])
    }
}

/// The buffers one cull leaves behind, for a caller that draws from them.
pub struct Culled {
    pub instances: wgpu::Buffer,
    /// The three lanes' visible lists, then the cast list at
    /// `cast_list_offset` words in.
    pub visible: wgpu::Buffer,
    /// The drawing lanes' indirect arguments, then the shadow lane's, one set
    /// per batch each.
    pub draw_args: wgpu::Buffer,
    /// The drawing lanes' bases, then the shadow lane's at `cast_base_offset`
    /// words in.
    pub batch_base: wgpu::Buffer,
    pub lights: wgpu::Buffer,
    pub cast_list_offset: u32,
    pub cast_base_offset: u32,
}

#[derive(Clone, Copy, Debug)]
pub struct TestBatch {
    pub lane: u32,
    pub first: u32,
    pub count: u32,
}

/// What the compaction must produce, worked out on the CPU.
#[derive(Debug, PartialEq, Eq)]
struct Expected {
    /// Instance indices per lane, in packet order.
    visible: Vec<Vec<u32>>,
    /// Where each batch's run starts in the whole visible buffer, and how long.
    batches: Vec<(u32, u32)>,
}

fn reference(
    instances: &[TestInstance],
    batches: &[TestBatch],
    view: [f32; 4],
    capacity: u32,
) -> Expected {
    let mut visible = vec![Vec::new(); LANE_COUNT as usize];
    for (index, instance) in instances.iter().enumerate() {
        if instance.kept(view) {
            visible[instance.lane as usize].push(index as u32);
            if instance.cast != 0 {
                visible[LANE_CAST as usize].push(index as u32);
            }
        }
    }

    // The offset of an index within its lane's survivors, which is what a
    // batch's start and end are measured by.
    let offset_at = |lane: u32, at: u32| -> u32 {
        instances
            .iter()
            .enumerate()
            .take(at as usize)
            .filter(|(_, instance)| {
                instance.kept(view)
                    && if lane == LANE_CAST {
                        instance.cast != 0
                    } else {
                        instance.lane == lane
                    }
            })
            .count() as u32
    };

    let batches = batches
        .iter()
        .map(|batch| {
            let start = offset_at(batch.lane, batch.first).min(capacity);
            let stop = offset_at(batch.lane, batch.first + batch.count).min(capacity);
            (batch.lane * capacity + start, stop - start)
        })
        .collect();

    for lane in visible.iter_mut() {
        lane.truncate(capacity as usize);
    }
    Expected { visible, batches }
}

pub struct Harness {
    pub device: Device,
    pub queue: Queue,
}

impl Harness {
    /// Opens a device with no surface, or answers none where there is no
    /// adapter to open one on.
    pub fn open() -> Option<Self> {
        let instance = Instance::new(InstanceDescriptor::new_without_display_handle());
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            force_fallback_adapter: false,
            compatible_surface: None,
            ..Default::default()
        }))
        .ok()?;
        let (device, queue) = pollster::block_on(adapter.request_device(&DeviceDescriptor {
            label: Some("tecs cull test"),
            ..Default::default()
        }))
        .ok()?;
        Some(Self { device, queue })
    }

    /// Runs mark, scan, compact and args once, and reads back what they wrote.
    fn run(
        &self,
        instances: &[TestInstance],
        batches: &[TestBatch],
        view: [f32; 4],
        capacity: u32,
    ) -> (Vec<u32>, Vec<u32>, Vec<u32>) {
        let culled = self.dispatch(instances, batches, view, capacity);
        (
            self.copy_back(&culled.visible),
            self.copy_back(&culled.draw_args),
            self.copy_back(&culled.batch_base),
        )
    }

    /// Copies one storage buffer out and reads it.
    fn copy_back(&self, buffer: &wgpu::Buffer) -> Vec<u32> {
        let out = staging(&self.device, buffer.size());
        let mut encoder = self
            .device
            .create_command_encoder(&CommandEncoderDescriptor { label: None });
        encoder.copy_buffer_to_buffer(buffer, 0, &out, 0, buffer.size());
        self.queue.submit([encoder.finish()]);
        self.read(&out)
    }

    /// Submits the four cull dispatches and hands back what they filled.
    pub fn dispatch(
        &self,
        instances: &[TestInstance],
        batches: &[TestBatch],
        view: [f32; 4],
        capacity: u32,
    ) -> Culled {
        self.dispatch_with(instances, batches, view, capacity, &[], 0.0)
    }

    /// Submits the five cull dispatches and hands back what they filled.
    pub fn dispatch_with(
        &self,
        instances: &[TestInstance],
        batches: &[TestBatch],
        view: [f32; 4],
        capacity: u32,
        lights: &[TestLight],
        margin: f32,
    ) -> Culled {
        let device = &self.device;
        let instance_count = instances.len() as u32;
        let blocks = instance_count.div_ceil(WORKGROUP).max(1);

        let mut instance_bytes = Vec::with_capacity(instances.len() * INSTANCE_STRIDE);
        for instance in instances {
            instance_bytes.extend_from_slice(&instance.bytes());
        }
        let mut batch_bytes = Vec::new();
        for batch in batches {
            for word in [0_u32, 0, batch.lane, batch.first, batch.count] {
                batch_bytes.extend_from_slice(&word.to_ne_bytes());
            }
        }
        let casters = instances.iter().filter(|held| held.cast != 0).count() as u32;
        let cast_capacity = casters.max(1);
        let cast_list_offset = align_words(capacity * LANE_COUNT);
        let cast_base_offset = align_words(batches.len().max(1) as u32);
        let uniform: [u32; 16] = [
            view[0].to_bits(),
            view[1].to_bits(),
            view[2].to_bits(),
            view[3].to_bits(),
            instance_count,
            blocks,
            capacity,
            batches.len() as u32,
            lights.len() as u32,
            cast_capacity,
            cast_list_offset,
            cast_base_offset,
            margin.to_bits(),
            0,
            0,
            0,
        ];
        let mut light_bytes = Vec::new();
        for light in lights {
            light_bytes.extend_from_slice(&light.bytes());
        }
        if light_bytes.is_empty() {
            light_bytes.extend_from_slice(&[0_u8; LIGHT_STRIDE]);
        }

        let instance_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("instances"),
            contents: &instance_bytes,
            usage: BufferUsages::STORAGE,
        });
        let batch_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("batches"),
            contents: &batch_bytes,
            usage: BufferUsages::STORAGE,
        });
        let uniform_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("cull"),
            contents: bytemuck::cast_slice(&uniform),
            usage: BufferUsages::UNIFORM,
        });
        let light_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("lights"),
            contents: &light_bytes,
            usage: BufferUsages::STORAGE | BufferUsages::COPY_SRC,
        });
        let slots = scratch(device, u64::from(instance_count) * 4);
        let block_counts = scratch(device, u64::from(blocks + 1) * u64::from(LANE_COUNT) * 4);
        let visible = scratch(
            device,
            (u64::from(cast_list_offset) + u64::from(cast_capacity) * u64::from(CAST_FANOUT)) * 4,
        );
        let draw_args = scratch(device, batches.len() as u64 * 32);
        let batch_base = scratch(
            device,
            (u64::from(cast_base_offset) + batches.len().max(1) as u64) * 4,
        );

        let layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("cull layout"),
            entries: &[
                entry(0, true),
                entry(1, true),
                entry(2, false),
                entry(3, false),
                entry(4, false),
                entry(5, false),
                entry(6, false),
                BindGroupLayoutEntry {
                    binding: 7,
                    visibility: ShaderStages::COMPUTE,
                    ty: BindingType::Buffer {
                        ty: BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                entry(8, true),
            ],
        });
        let group = device.create_bind_group(&BindGroupDescriptor {
            label: Some("cull group"),
            layout: &layout,
            entries: &[
                BindGroupEntry {
                    binding: 0,
                    resource: instance_buffer.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 1,
                    resource: batch_buffer.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 2,
                    resource: slots.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 3,
                    resource: block_counts.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 4,
                    resource: visible.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 5,
                    resource: draw_args.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 6,
                    resource: batch_base.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 7,
                    resource: uniform_buffer.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 8,
                    resource: light_buffer.as_entire_binding(),
                },
            ],
        });

        let module = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("cull"),
            source: ShaderSource::Wgsl(Cow::Borrowed(CULL_WGSL)),
        });
        let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
            label: Some("cull pipeline layout"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let pipelines = [
            "markMain",
            "scanMain",
            "compactMain",
            "argsMain",
            "castMain",
        ]
        .map(|name| {
            device.create_compute_pipeline(&ComputePipelineDescriptor {
                label: Some(name),
                layout: Some(&pipeline_layout),
                module: &module,
                entry_point: Some(name),
                compilation_options: PipelineCompilationOptions::default(),
                cache: None,
            })
        });

        let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor {
            label: Some("cull"),
        });
        {
            let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor {
                label: Some("cull"),
                timestamp_writes: None,
            });
            pass.set_bind_group(0, &group, &[]);
            pass.set_pipeline(&pipelines[0]);
            pass.dispatch_workgroups(blocks, 1, 1);
            pass.set_pipeline(&pipelines[1]);
            pass.dispatch_workgroups(1, 1, 1);
            pass.set_pipeline(&pipelines[2]);
            pass.dispatch_workgroups(blocks, 1, 1);
            pass.set_pipeline(&pipelines[3]);
            pass.dispatch_workgroups((batches.len() as u32).div_ceil(ARGS_WORKGROUP), 1, 1);
            pass.set_pipeline(&pipelines[4]);
            pass.dispatch_workgroups(blocks, 1, 1);
        }

        self.queue.submit([encoder.finish()]);

        Culled {
            instances: instance_buffer,
            visible,
            draw_args,
            batch_base,
            lights: light_buffer,
            cast_list_offset,
            cast_base_offset,
        }
    }

    /// Copies one storage buffer out and reads it, for a caller outside this
    /// module.
    pub fn read_back(&self, buffer: &wgpu::Buffer) -> Vec<u32> {
        self.copy_back(buffer)
    }

    fn read(&self, buffer: &wgpu::Buffer) -> Vec<u32> {
        buffer.slice(..).map_async(MapMode::Read, |_| {});
        self.device
            .poll(PollType::wait_indefinitely())
            .expect("the queue drains");
        let view = buffer
            .slice(..)
            .get_mapped_range()
            .expect("the buffer maps after the queue drains");
        let values = view
            .as_chunks::<4>()
            .0
            .iter()
            .map(|chunk| u32::from_ne_bytes(*chunk))
            .collect();
        drop(view);
        buffer.unmap();
        values
    }
}

/// A scratch buffer the shaders read and write, and a caller may copy out.
fn scratch(device: &Device, size: u64) -> wgpu::Buffer {
    device.create_buffer(&BufferDescriptor {
        label: None,
        size: size.max(4),
        // Indirect as well as storage, because the arguments the cull writes
        // are what a draw reads and both go through this one helper.
        usage: BufferUsages::STORAGE | BufferUsages::COPY_SRC | BufferUsages::INDIRECT,
        mapped_at_creation: false,
    })
}

fn staging(device: &Device, size: u64) -> wgpu::Buffer {
    device.create_buffer(&BufferDescriptor {
        label: None,
        size,
        usage: BufferUsages::COPY_DST | BufferUsages::MAP_READ,
        mapped_at_creation: false,
    })
}

fn entry(binding: u32, read_only: bool) -> BindGroupLayoutEntry {
    BindGroupLayoutEntry {
        binding,
        visibility: ShaderStages::COMPUTE,
        ty: BindingType::Buffer {
            ty: BufferBindingType::Storage { read_only },
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    }
}

/// Reads one lane's survivors out of the whole visible buffer.
fn lane(visible: &[u32], lane: u32, capacity: u32, count: usize) -> Vec<u32> {
    let base = (lane * capacity) as usize;
    visible[base..base + count].to_vec()
}

/// A scene of `count` quads, every fourth one blended and every seventh one
/// placed far outside the view.
fn scene(count: u32) -> (Vec<TestInstance>, Vec<TestBatch>) {
    let mut instances = Vec::new();
    for index in 0..count {
        let x = if index % 7 == 6 {
            100_000.0
        } else {
            index as f32
        };
        instances.push(if index % 4 == 3 {
            TestInstance::blended(x, 0.0)
        } else {
            TestInstance::opaque(x, 0.0)
        });
    }

    // Batches break wherever the lane changes, exactly as the extractor emits
    // them, so every batch belongs to one lane.
    let mut batches = Vec::new();
    let mut first = 0_u32;
    while first < count {
        let lane = instances[first as usize].lane;
        let mut length = 1;
        while first + length < count && instances[(first + length) as usize].lane == lane {
            length += 1;
        }
        batches.push(TestBatch {
            lane,
            first,
            count: length,
        });
        first += length;
    }
    (instances, batches)
}

#[test]
fn compacts_in_packet_order_and_repeats_itself() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the cull tests");
        return;
    };
    // Deliberately more than one workgroup, so the block scan is exercised
    // rather than the intra-block prefix alone.
    let (instances, batches) = scene(1000);
    let view = [-10.0, -10.0, 10_000.0, 10.0];
    let capacity = 1024;
    let expected = reference(&instances, &batches, view, capacity);

    let (visible, args, bases) = harness.run(&instances, &batches, view, capacity);
    assert_eq!(
        lane(
            &visible,
            LANE_OPAQUE,
            capacity,
            expected.visible[LANE_OPAQUE as usize].len()
        ),
        expected.visible[LANE_OPAQUE as usize],
        "the opaque lane is a stable subsequence of packet order"
    );
    assert_eq!(
        lane(
            &visible,
            LANE_BLEND,
            capacity,
            expected.visible[LANE_BLEND as usize].len()
        ),
        expected.visible[LANE_BLEND as usize],
        "the blended lane is a stable subsequence of packet order"
    );

    for (index, (base, count)) in expected.batches.iter().enumerate() {
        assert_eq!(
            bases[index], *base,
            "batch {index} starts where the scan said"
        );
        assert_eq!(args[index * 4], 6, "a quad is six vertices");
        assert_eq!(
            args[index * 4 + 1],
            *count,
            "batch {index} draws its survivors"
        );
        assert_eq!(args[index * 4 + 2], 0);
        assert_eq!(args[index * 4 + 3], 0);
    }

    // The property the whole three-pass scan exists for. An atomic append would
    // pass every assertion above and fail this one.
    for _ in 0..4 {
        let (again, more_args, more_bases) = harness.run(&instances, &batches, view, capacity);
        assert_eq!(again, visible, "the same scene compacts the same way");
        assert_eq!(more_args, args);
        assert_eq!(more_bases, bases);
    }
}

#[test]
fn drops_what_the_view_rejects() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the cull tests");
        return;
    };
    let instances = vec![
        TestInstance::opaque(0.0, 0.0),
        TestInstance::opaque(500.0, 0.0),
        TestInstance::opaque(4.0, 0.0),
    ];
    let batches = vec![TestBatch {
        lane: LANE_OPAQUE,
        first: 0,
        count: 3,
    }];
    let view = [-10.0, -10.0, 10.0, 10.0];
    let capacity = 8;

    let (visible, args, bases) = harness.run(&instances, &batches, view, capacity);
    assert_eq!(lane(&visible, LANE_OPAQUE, capacity, 2), vec![0, 2]);
    assert_eq!(args[1], 2, "the draw is held to what survived");
    assert_eq!(bases[0], 0);

    // A quad whose center is outside but whose corner reaches in is kept: the
    // bound is conservative, so the cull never drops something it should keep.
    let reaching = vec![TestInstance {
        x: 10.9,
        ..TestInstance::opaque(0.0, 0.0)
    }];
    let (visible, args, _) = harness.run(
        &reaching,
        &[TestBatch {
            lane: LANE_OPAQUE,
            first: 0,
            count: 1,
        }],
        view,
        capacity,
    );
    assert_eq!(args[1], 1);
    assert_eq!(lane(&visible, LANE_OPAQUE, capacity, 1), vec![0]);
}

#[test]
fn holds_every_draw_to_the_lists_capacity() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the cull tests");
        return;
    };
    let instances: Vec<TestInstance> = (0..64)
        .map(|index| TestInstance::opaque(index as f32, 0.0))
        .collect();
    let batches = vec![TestBatch {
        lane: LANE_OPAQUE,
        first: 0,
        count: 64,
    }];
    let view = [-10.0, -10.0, 10_000.0, 10.0];
    // Shorter than the scene, so the compaction drops what it cannot place and
    // the draw stops exactly where the list does.
    let capacity = 16;

    let (visible, args, bases) = harness.run(&instances, &batches, view, capacity);
    assert_eq!(args[1], 16, "the draw stops where the list does");
    assert_eq!(bases[0], 0);
    assert_eq!(
        lane(&visible, LANE_OPAQUE, capacity, 16),
        (0..16).collect::<Vec<u32>>(),
        "what survives the ceiling is the run earliest in the buffer"
    );
}

#[test]
fn starts_every_batch_where_its_lanes_survivors_do() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the cull tests");
        return;
    };
    // Two lanes interleaved across a workgroup boundary, which is where a batch
    // base has to come from the block scan rather than from one workgroup's own
    // prefix.
    let (instances, batches) = scene(700);
    let view = [-10.0, -10.0, 10_000.0, 10.0];
    let capacity = 1024;
    let expected = reference(&instances, &batches, view, capacity);
    let (_, args, bases) = harness.run(&instances, &batches, view, capacity);

    let mut opaque_covered = 0_u32;
    let mut blend_covered = 0_u32;
    for (index, batch) in batches.iter().enumerate() {
        let covered = if batch.lane == LANE_OPAQUE {
            &mut opaque_covered
        } else {
            &mut blend_covered
        };
        assert_eq!(
            bases[index],
            batch.lane * capacity + *covered,
            "batch {index} continues its lane rather than restarting it"
        );
        *covered += args[index * 4 + 1];
    }
    assert_eq!(
        opaque_covered as usize,
        expected.visible[LANE_OPAQUE as usize].len()
    );
    assert_eq!(
        blend_covered as usize,
        expected.visible[LANE_BLEND as usize].len()
    );
}
