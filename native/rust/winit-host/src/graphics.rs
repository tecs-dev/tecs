//! The wgpu backend: the device, the graph's targets, and the frame.
//!
//! A frame is a compute pass that culls and compacts the scene into one visible
//! list per lane, then the declared render passes in declaration order. A pass
//! this backend has a body for draws; one it does not is still begun with its
//! attachments and its clears, so a game may declare a pass that only clears a
//! target and the graph runs it.
//!
//! Nothing here decides what the graph is. `src/tecs/gpu/passes.nupp` declares
//! it, the packet carries the declaration, and `graph.rs` decodes it. The names
//! in `body_for` are the passes this backend implements, and each of them is a
//! compatibility surface.

use std::borrow::Cow;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use anyhow::{bail, Context, Result};
use wgpu::{
    AddressMode, BindGroup, BindGroupDescriptor, BindGroupEntry, BindGroupLayout,
    BindGroupLayoutDescriptor, BindGroupLayoutEntry, BindingResource, BindingType, BlendState,
    Buffer, BufferBindingType, BufferDescriptor, BufferUsages, Color, ColorTargetState,
    ColorWrites, CommandEncoderDescriptor, ComputePassDescriptor, ComputePipeline,
    ComputePipelineDescriptor, CurrentSurfaceTexture, DepthBiasState, DepthStencilState, Device,
    DeviceDescriptor, Extent3d, FilterMode, FragmentState, Instance, InstanceDescriptor, LoadOp,
    MipmapFilterMode, Operations, Origin3d, PipelineCompilationOptions, PipelineLayoutDescriptor,
    Queue, RenderPassColorAttachment, RenderPassDepthStencilAttachment, RenderPassDescriptor,
    RenderPipeline, RenderPipelineDescriptor, Sampler, SamplerBindingType, SamplerDescriptor,
    ShaderModule, ShaderModuleDescriptor, ShaderSource, ShaderStages, StencilState, StoreOp,
    Surface, SurfaceConfiguration, TexelCopyBufferLayout, TexelCopyTextureInfo, TextureAspect,
    TextureDescriptor, TextureDimension, TextureFormat, TextureSampleType, TextureUsages,
    TextureView, TextureViewDescriptor, TextureViewDimension, VertexState,
};
use winit::event_loop::OwnedDisplayHandle;
use winit::window::Window;

use crate::graph::{
    parse_graph, ClearMode, DepthMode, Graph, Input, TargetAllocator, TargetFormat, TargetStore,
    MAX_OUTPUTS,
};
use crate::packet::{
    parse_packet, Batch, INSTANCE_STRIDE, LANE_BLEND, LANE_COUNT, LANE_OPAQUE, SAMPLER_COUNT,
};
use crate::shaderpack::ShaderPack;

/// Four bytes per texel, which is the only layout an upload command declares.
const BYTES_PER_TEXEL: u32 = 4;

/// The workgroup size every cull dispatch is written against. Changing it
/// changes the shader's shared-memory scan, so the two are one number.
const WORKGROUP: u32 = 256;

/// The workgroup size of the pass that turns the scan into indirect arguments.
const ARGS_WORKGROUP: u32 = 64;

/// One indirect draw is four words: vertices, instances, first vertex, first
/// instance.
const DRAW_ARGS_WORDS: u64 = 4;

/// The depth attachment every depth pass shares.
const DEPTH_FORMAT: TextureFormat = TextureFormat::Depth32Float;

const MATERIAL_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/material.wgsl");
const INSTANCE_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/instance.wgsl");
const CULL_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/cull.wgsl");
const RESOLVE_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/resolve.wgsl");
const LIGHTING_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/lighting.wgsl");
const COMPOSITE_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/composite.wgsl");
const PRESENT_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/present.wgsl");

/// What this backend does when it reaches a pass of a given name.
///
/// Every name here is a compatibility surface: a game names one to place a pass
/// of its own beside it, and reordering the graph reorders these bodies with
/// it.
pub enum Body {
    /// Draws one lane of the scene through the indirect arguments the cull
    /// produced.
    Instanced { lane: u32 },
    /// Covers the target once, reading the pass's declared inputs.
    Fullscreen,
    /// Begins the pass, applies its clears, and draws nothing. This is what a
    /// pass whose name this backend does not implement does, and it is also a
    /// useful pass in its own right: it clears a target.
    Empty,
}

pub struct PassRuntime {
    pub body: Body,
    pub pipeline: Option<RenderPipeline>,
    /// Rebuilt whenever the targets are reallocated, because a bind group holds
    /// the views it was made from.
    inputs: Option<BindGroup>,
    pub input_layout: Option<BindGroupLayout>,
}

/// One target's texture, held through the view every pass reaches it by. The
/// view keeps the texture alive, so the texture itself is not retained.
struct TargetTexture {
    view: TextureView,
}

struct Allocator<'a> {
    device: &'a Device,
}

impl TargetAllocator for Allocator<'_> {
    type Target = TargetTexture;

    fn create(
        &mut self,
        name: &str,
        format: TargetFormat,
        width: u32,
        height: u32,
    ) -> Self::Target {
        let format = texture_format(format);
        let texture = self.device.create_texture(&TextureDescriptor {
            label: Some(name),
            size: Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: TextureDimension::D2,
            format,
            usage: TextureUsages::RENDER_ATTACHMENT | TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        TargetTexture {
            view: texture.create_view(&TextureViewDescriptor::default()),
        }
    }

    fn create_depth(&mut self, width: u32, height: u32) -> Self::Target {
        let texture = self.device.create_texture(&TextureDescriptor {
            label: Some("tecs depth"),
            size: Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: TextureDimension::D2,
            format: DEPTH_FORMAT,
            usage: TextureUsages::RENDER_ATTACHMENT | TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        TargetTexture {
            view: texture.create_view(&TextureViewDescriptor::default()),
        }
    }
}

/// The buffers the cull and the draws share, and the two bind groups over them.
///
/// Rebuilt as one unit, because a bind group holds the buffers it was made
/// from: growing any of them invalidates both groups, and rebuilding them
/// separately would only add a way for the two to disagree.
struct Scratch {
    instances: Buffer,
    batches: Buffer,
    // Read and written only by the shaders. They are held because a bind group
    // borrows the buffers it was made from rather than owning them, so dropping
    // one here would leave the group pointing at nothing.
    #[allow(dead_code)]
    slots: Buffer,
    #[allow(dead_code)]
    block_counts: Buffer,
    #[allow(dead_code)]
    visible: Buffer,
    draw_args: Buffer,
    #[allow(dead_code)]
    batch_base: Buffer,
    cull_uniform: Buffer,
    #[allow(dead_code)]
    batch_index: Buffer,
    cull_group: BindGroup,
    draw_group: BindGroup,
    instance_capacity: u32,
    batch_capacity: u32,
    block_capacity: u32,
    batch_stride: u32,
}

/// The bind group layouts every pipeline in this backend is built against.
///
/// Held together because a pipeline layout names several of them and a test
/// that builds pipelines needs the same set the frame does.
pub struct Layouts {
    pub scene: BindGroupLayout,
    pub image: BindGroupLayout,
    pub cull: BindGroupLayout,
    pub draw: BindGroupLayout,
}

impl Layouts {
    pub fn new(device: &Device) -> Self {
        let scene = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("tecs scene layout"),
            entries: &[BindGroupLayoutEntry {
                binding: 0,
                visibility: ShaderStages::VERTEX | ShaderStages::FRAGMENT,
                ty: BindingType::Buffer {
                    ty: BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });
        let image = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("tecs image layout"),
            entries: &[
                BindGroupLayoutEntry {
                    binding: 0,
                    visibility: ShaderStages::FRAGMENT,
                    ty: BindingType::Texture {
                        sample_type: TextureSampleType::Float { filterable: true },
                        view_dimension: TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                BindGroupLayoutEntry {
                    binding: 1,
                    visibility: ShaderStages::FRAGMENT,
                    ty: BindingType::Sampler(SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });
        let cull = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("tecs cull layout"),
            entries: &[
                storage_entry(0, true),
                storage_entry(1, true),
                storage_entry(2, false),
                storage_entry(3, false),
                storage_entry(4, false),
                storage_entry(5, false),
                storage_entry(6, false),
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
            ],
        });
        let draw = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("tecs draw layout"),
            entries: &[
                vertex_storage_entry(0),
                vertex_storage_entry(1),
                vertex_storage_entry(2),
                BindGroupLayoutEntry {
                    binding: 3,
                    visibility: ShaderStages::VERTEX,
                    ty: BindingType::Buffer {
                        ty: BufferBindingType::Uniform,
                        has_dynamic_offset: true,
                        min_binding_size: std::num::NonZeroU64::new(4),
                    },
                    count: None,
                },
            ],
        });
        Self {
            scene,
            image,
            cull,
            draw,
        }
    }
}

pub struct Graphics {
    surface: Surface<'static>,
    device: Device,
    queue: Queue,
    config: SurfaceConfiguration,
    pack: ShaderPack,

    scene_buffer: Buffer,
    scene_bind_group: BindGroup,

    layouts: Layouts,
    samplers: Vec<Sampler>,
    fallback: TextureView,
    images: HashMap<u32, TextureView>,
    bind_groups: HashMap<(u32, u32), BindGroup>,

    pass_sampler: Sampler,
    cull_pipelines: [ComputePipeline; 4],
    instance_module: ShaderModule,

    graph: Option<Graph>,
    graph_generation: u64,
    graph_revision: Option<u32>,
    pipeline_format: Option<TextureFormat>,
    passes: Vec<PassRuntime>,
    targets: TargetStore<TargetTexture>,
    /// Bumped whenever the targets are reallocated, so an input bind group
    /// knows the views it holds are stale.
    binding_generation: u64,
    bound_generation: u64,

    scratch: Option<Scratch>,
    batches: Vec<Batch>,
    /// What a device-lost callback reported, checked before every frame.
    lost: Arc<Mutex<Option<String>>>,
    /// What an uncaptured validation error reported.
    failed: Arc<Mutex<Option<String>>>,
}

impl Graphics {
    pub fn new(window: Arc<Window>, display: OwnedDisplayHandle) -> Result<Self> {
        let size = window.inner_size();
        let instance = Instance::new(InstanceDescriptor {
            display: Some(Box::new(display)),
            ..InstanceDescriptor::new_without_display_handle()
        });
        let surface = instance
            .create_surface(window)
            .context("create the wgpu presentation surface")?;
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            force_fallback_adapter: false,
            compatible_surface: Some(&surface),
            ..Default::default()
        }))
        .context("select a wgpu adapter for the window")?;
        let (device, queue) = pollster::block_on(adapter.request_device(&DeviceDescriptor {
            label: Some("tecs device"),
            ..Default::default()
        }))
        .context("create the wgpu device")?;
        let config = surface
            .get_default_config(&adapter, size.width.max(1), size.height.max(1))
            .context("choose a supported wgpu surface configuration")?;
        surface.configure(&device, &config);

        let pack = load_pack()?;
        Self::assemble(surface, device, queue, config, pack)
    }

    /// Builds everything that does not depend on the graph.
    ///
    /// Split out so a test can hand in a headless device and the same code
    /// answers.
    fn assemble(
        surface: Surface<'static>,
        device: Device,
        queue: Queue,
        config: SurfaceConfiguration,
        pack: ShaderPack,
    ) -> Result<Self> {
        let lost: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
        let failed: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
        {
            // Both callbacks stay inside Rust and only write to a mutex the
            // frame reads. Nothing managed is entered from a driver thread.
            let lost = Arc::clone(&lost);
            device.set_device_lost_callback(move |reason, message| {
                *lost
                    .lock()
                    .expect("the device-lost mutex is never poisoned") =
                    Some(format!("{reason:?}: {message}"));
            });
            let failed = Arc::clone(&failed);
            device.on_uncaptured_error(Arc::new(move |error: wgpu::Error| {
                let mut held = failed
                    .lock()
                    .expect("the device-error mutex is never poisoned");
                if held.is_none() {
                    *held = Some(error.to_string());
                }
            }));
        }

        let scene = [1.0_f32, 1.0, 0.5, 0.5, 1.0, 0.0, 0.0, 0.0];
        let scene_buffer = device.create_buffer(&BufferDescriptor {
            label: Some("tecs scene"),
            size: std::mem::size_of_val(&scene) as u64,
            usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        queue.write_buffer(&scene_buffer, 0, bytemuck::cast_slice(&scene));
        let layouts = Layouts::new(&device);
        let scene_bind_group = device.create_bind_group(&BindGroupDescriptor {
            label: Some("tecs scene bind group"),
            layout: &layouts.scene,
            entries: &[BindGroupEntry {
                binding: 0,
                resource: scene_buffer.as_entire_binding(),
            }],
        });

        let cull_module = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("tecs cull"),
            source: ShaderSource::Wgsl(Cow::Borrowed(CULL_WGSL)),
        });
        let cull_pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
            label: Some("tecs cull pipeline layout"),
            bind_group_layouts: &[Some(&layouts.cull)],
            immediate_size: 0,
        });
        let cull_pipelines = ["markMain", "scanMain", "compactMain", "argsMain"].map(|entry| {
            device.create_compute_pipeline(&ComputePipelineDescriptor {
                label: Some(entry),
                layout: Some(&cull_pipeline_layout),
                module: &cull_module,
                entry_point: Some(entry),
                compilation_options: PipelineCompilationOptions::default(),
                cache: None,
            })
        });

        let instance_module = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("tecs instance"),
            source: ShaderSource::Wgsl(Cow::Owned(instance_source(&pack))),
        });

        let samplers = create_samplers(&device);
        // Nearest and clamped, because a graph target is read at the resolution
        // it was written.
        let pass_sampler = device.create_sampler(&SamplerDescriptor {
            label: Some("tecs pass sampler"),
            address_mode_u: AddressMode::ClampToEdge,
            address_mode_v: AddressMode::ClampToEdge,
            address_mode_w: AddressMode::ClampToEdge,
            mag_filter: FilterMode::Nearest,
            min_filter: FilterMode::Nearest,
            mipmap_filter: MipmapFilterMode::Nearest,
            ..Default::default()
        });
        // One opaque white texel, so an untextured instance and one whose image
        // never became resident both draw their tint unchanged.
        let fallback = create_image(&device, &queue, 0, 1, 1, &[255, 255, 255, 255])?;

        Ok(Self {
            surface,
            device,
            queue,
            config,
            pack,
            scene_buffer,
            scene_bind_group,
            layouts,
            samplers,
            fallback,
            images: HashMap::new(),
            bind_groups: HashMap::new(),
            pass_sampler,
            cull_pipelines,
            instance_module,
            graph: None,
            graph_generation: 0,
            graph_revision: None,
            pipeline_format: None,
            passes: Vec::new(),
            targets: TargetStore::default(),
            binding_generation: 1,
            bound_generation: 0,
            scratch: None,
            batches: Vec::new(),
            lost,
            failed,
        })
    }

    pub fn resize(&mut self, width: u32, height: u32) {
        if width == 0 || height == 0 {
            return;
        }
        if self.config.width == width && self.config.height == height {
            return;
        }
        self.config.width = width;
        self.config.height = height;
        self.surface.configure(&self.device, &self.config);
    }

    /// Makes one image resident, replacing whatever already lived under its id.
    pub fn upload_image(&mut self, id: u32, width: u32, height: u32, pixels: &[u8]) -> Result<()> {
        if id == 0 {
            bail!("image id 0 is the backend's own fallback and cannot be replaced");
        }
        let view = create_image(&self.device, &self.queue, id, width, height, pixels)?;
        self.images.insert(id, view);
        // A replacement invalidates every bind group holding the old view.
        self.bind_groups.retain(|(image, _), _| *image != id);
        Ok(())
    }

    /// Drops one image and everything bound to it.
    pub fn release_image(&mut self, id: u32) -> Result<()> {
        if id == 0 {
            bail!("image id 0 is the backend's own fallback and cannot be released");
        }
        self.bind_groups.retain(|(image, _), _| *image != id);
        if self.images.remove(&id).is_none() {
            bail!("image {id} is not resident");
        }
        Ok(())
    }

    fn image_bind_group(&mut self, image: u32, sampler: u32) -> &BindGroup {
        let key = (image, sampler);
        if !self.bind_groups.contains_key(&key) {
            // An id the packet names but nothing uploaded falls back rather
            // than failing the frame, which is what makes a missing asset a
            // visible untextured quad instead of a dead window.
            let view = self.images.get(&image).unwrap_or(&self.fallback);
            let group = self.device.create_bind_group(&BindGroupDescriptor {
                label: Some("tecs image bind group"),
                layout: &self.layouts.image,
                entries: &[
                    BindGroupEntry {
                        binding: 0,
                        resource: BindingResource::TextureView(view),
                    },
                    BindGroupEntry {
                        binding: 1,
                        resource: BindingResource::Sampler(&self.samplers[sampler as usize]),
                    },
                ],
            });
            self.bind_groups.insert(key, group);
        }
        self.bind_groups.get(&key).expect("just inserted")
    }

    /// Rebinds every fullscreen pass's inputs to the targets as they now are.
    fn rebind_inputs(&mut self, graph: &Graph) {
        for (index, pass) in graph.passes().iter().enumerate() {
            let runtime = &self.passes[index];
            let Some(layout) = runtime.input_layout.as_ref() else {
                continue;
            };
            let mut entries = vec![BindGroupEntry {
                binding: 0,
                resource: BindingResource::Sampler(&self.pass_sampler),
            }];
            for (slot, input) in pass.inputs.iter().enumerate() {
                let view = match input {
                    Input::Target(target) => &self.targets.target(*target).view,
                    Input::Depth => {
                        &self
                            .targets
                            .depth()
                            .expect("a graph that reads depth allocates it")
                            .view
                    }
                };
                entries.push(BindGroupEntry {
                    binding: slot as u32 + 1,
                    resource: BindingResource::TextureView(view),
                });
            }
            let group = self.device.create_bind_group(&BindGroupDescriptor {
                label: Some(pass.name.as_str()),
                layout,
                entries: &entries,
            });
            self.passes[index].inputs = Some(group);
        }
    }

    /// Grows the shared buffers to a scene and rebuilds the two bind groups.
    ///
    /// Capacities only ever grow and round to a power of two, so a scene that
    /// oscillates in size does not reallocate every frame.
    fn ensure_scratch(&mut self, instance_count: u32, batch_count: u32) {
        let instance_capacity = capacity(instance_count.max(1));
        let batch_capacity = capacity(batch_count.max(1));
        let blocks = instance_count.div_ceil(WORKGROUP).max(1);
        let block_capacity = capacity(blocks + 1);
        if let Some(scratch) = self.scratch.as_ref() {
            if scratch.instance_capacity >= instance_capacity
                && scratch.batch_capacity >= batch_capacity
                && scratch.block_capacity >= block_capacity
            {
                return;
            }
        }

        let instance_capacity = instance_capacity.max(
            self.scratch
                .as_ref()
                .map_or(0, |held| held.instance_capacity),
        );
        let batch_capacity =
            batch_capacity.max(self.scratch.as_ref().map_or(0, |held| held.batch_capacity));
        let block_capacity =
            block_capacity.max(self.scratch.as_ref().map_or(0, |held| held.block_capacity));

        let device = &self.device;
        let instances = device.create_buffer(&BufferDescriptor {
            label: Some("tecs instances"),
            size: u64::from(instance_capacity) * INSTANCE_STRIDE as u64,
            usage: BufferUsages::STORAGE | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let batches = device.create_buffer(&BufferDescriptor {
            label: Some("tecs batches"),
            size: u64::from(batch_capacity) * crate::packet::BATCH_STRIDE as u64,
            usage: BufferUsages::STORAGE | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let slots = device.create_buffer(&BufferDescriptor {
            label: Some("tecs cull slots"),
            size: u64::from(instance_capacity) * 4,
            usage: BufferUsages::STORAGE,
            mapped_at_creation: false,
        });
        let block_counts = device.create_buffer(&BufferDescriptor {
            label: Some("tecs cull block counts"),
            size: u64::from(block_capacity) * u64::from(LANE_COUNT) * 4,
            usage: BufferUsages::STORAGE,
            mapped_at_creation: false,
        });
        let visible = device.create_buffer(&BufferDescriptor {
            label: Some("tecs visible lists"),
            size: u64::from(instance_capacity) * u64::from(LANE_COUNT) * 4,
            usage: BufferUsages::STORAGE | BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        let draw_args = device.create_buffer(&BufferDescriptor {
            label: Some("tecs draw arguments"),
            size: u64::from(batch_capacity) * DRAW_ARGS_WORDS * 4,
            usage: BufferUsages::STORAGE | BufferUsages::INDIRECT | BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        let batch_base = device.create_buffer(&BufferDescriptor {
            label: Some("tecs batch bases"),
            size: u64::from(batch_capacity) * 4,
            usage: BufferUsages::STORAGE | BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        let cull_uniform = device.create_buffer(&BufferDescriptor {
            label: Some("tecs cull uniform"),
            size: 32,
            usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // The per-batch index a draw selects with a dynamic offset. Its
        // contents are the index itself, so it is written once here and never
        // again: what changes per frame is the base the args pass computed, and
        // that lives in a storage buffer this indexes into.
        let batch_stride = device.limits().min_uniform_buffer_offset_alignment.max(4);
        let batch_index = device.create_buffer(&BufferDescriptor {
            label: Some("tecs batch index"),
            size: u64::from(batch_capacity) * u64::from(batch_stride),
            usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let mut indices = vec![0_u8; (batch_capacity * batch_stride) as usize];
        for index in 0..batch_capacity {
            let at = (index * batch_stride) as usize;
            indices[at..at + 4].copy_from_slice(&index.to_ne_bytes());
        }
        self.queue.write_buffer(&batch_index, 0, &indices);

        let cull_group = device.create_bind_group(&BindGroupDescriptor {
            label: Some("tecs cull bind group"),
            layout: &self.layouts.cull,
            entries: &[
                BindGroupEntry {
                    binding: 0,
                    resource: instances.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 1,
                    resource: batches.as_entire_binding(),
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
                    resource: cull_uniform.as_entire_binding(),
                },
            ],
        });
        let draw_group = device.create_bind_group(&BindGroupDescriptor {
            label: Some("tecs draw bind group"),
            layout: &self.layouts.draw,
            entries: &[
                BindGroupEntry {
                    binding: 0,
                    resource: instances.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 1,
                    resource: visible.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 2,
                    resource: batch_base.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 3,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                        buffer: &batch_index,
                        offset: 0,
                        size: std::num::NonZeroU64::new(4),
                    }),
                },
            ],
        });

        self.scratch = Some(Scratch {
            instances,
            batches,
            slots,
            block_counts,
            visible,
            draw_args,
            batch_base,
            cull_uniform,
            batch_index,
            cull_group,
            draw_group,
            instance_capacity,
            batch_capacity,
            block_capacity,
            batch_stride,
        });
    }

    /// Draws one frame from one packet.
    pub fn render(&mut self, bytes: &[u8]) -> Result<()> {
        if let Some(reason) = self.lost.lock().expect("mutex").take() {
            // Everything held belonged to a device that no longer exists, so it
            // is dropped rather than submitted to. A frame after this one
            // rebuilds from the packet, which carries the graph declaration
            // every time for exactly this reason.
            self.targets.clear();
            self.scratch = None;
            self.images.clear();
            self.bind_groups.clear();
            self.graph_revision = None;
            bail!("the wgpu device was lost: {reason}");
        }

        let mut batches = std::mem::take(&mut self.batches);
        let outcome = self.render_inner(bytes, &mut batches);
        self.batches = batches;
        outcome?;

        if let Some(reason) = self.failed.lock().expect("mutex").take() {
            bail!("wgpu reported an error while drawing: {reason}");
        }
        Ok(())
    }

    fn render_inner(&mut self, bytes: &[u8], batches: &mut Vec<Batch>) -> Result<()> {
        let packet = parse_packet(bytes, batches, self.pack.material_count())?;
        let header = packet.header;

        if self.graph_revision != Some(header.graph_revision)
            || self.pipeline_format != Some(self.config.format)
        {
            let graph = parse_graph(packet.graph)?;
            self.graph_generation += 1;
            self.passes = build_passes(
                &self.device,
                &self.layouts,
                &self.instance_module,
                &graph,
                self.config.format,
            )?;
            self.graph = Some(graph);
            self.graph_revision = Some(header.graph_revision);
            self.pipeline_format = Some(self.config.format);
            // The pipelines changed, so the bind groups over the targets have
            // to be made again against the layouts the new ones declare.
            self.bound_generation = 0;
        }
        let graph = self
            .graph
            .take()
            .expect("a graph is built before the first frame is drawn");
        let outcome = self.draw(&graph, &packet, batches);
        self.graph = Some(graph);
        outcome
    }

    fn draw(
        &mut self,
        graph: &Graph,
        packet: &crate::packet::Packet<'_>,
        batches: &[Batch],
    ) -> Result<()> {
        let width = self.config.width.max(1);
        let height = self.config.height.max(1);
        let (held_width, held_height) = self.targets.size();
        {
            let mut allocator = Allocator {
                device: &self.device,
            };
            self.targets
                .ensure(graph, self.graph_generation, width, height, &mut allocator);
        }
        if held_width != width || held_height != height {
            self.binding_generation += 1;
        }
        if self.bound_generation != self.binding_generation {
            self.rebind_inputs(graph);
            self.bound_generation = self.binding_generation;
        }

        self.queue.write_buffer(
            &self.scene_buffer,
            0,
            bytemuck::cast_slice(&packet.header.scene),
        );
        self.ensure_scratch(packet.instance_count, batches.len() as u32);
        let scratch = self.scratch.as_ref().expect("just ensured");
        if !packet.instances.is_empty() {
            self.queue
                .write_buffer(&scratch.instances, 0, packet.instances);
        }
        if !packet.batch_bytes.is_empty() {
            self.queue
                .write_buffer(&scratch.batches, 0, packet.batch_bytes);
        }
        let blocks = packet.instance_count.div_ceil(WORKGROUP);
        let view = packet.header.world_view();
        let uniform: [u32; 8] = [
            view[0].to_bits(),
            view[1].to_bits(),
            view[2].to_bits(),
            view[3].to_bits(),
            packet.instance_count,
            blocks,
            scratch.instance_capacity,
            batches.len() as u32,
        ];
        self.queue
            .write_buffer(&scratch.cull_uniform, 0, bytemuck::cast_slice(&uniform));

        // Resolved before the encoder borrows self, because creating an image
        // bind group on demand needs the device this method also lends out.
        for batch in batches {
            let _ = self.image_bind_group(batch.image, batch.sampler);
        }

        let (frame, reconfigure) = match self.surface.get_current_texture() {
            CurrentSurfaceTexture::Success(frame) => (frame, false),
            CurrentSurfaceTexture::Suboptimal(frame) => (frame, true),
            CurrentSurfaceTexture::Timeout | CurrentSurfaceTexture::Occluded => return Ok(()),
            CurrentSurfaceTexture::Outdated | CurrentSurfaceTexture::Lost => {
                // Both mean the surface no longer matches the window. Rebuilt
                // here and drawn next frame, which is one dropped frame rather
                // than a dead window.
                self.surface.configure(&self.device, &self.config);
                return Ok(());
            }
            CurrentSurfaceTexture::Validation => {
                bail!("wgpu rejected presentation surface acquisition")
            }
        };
        let swapchain = frame.texture.create_view(&TextureViewDescriptor::default());
        let mut encoder = self
            .device
            .create_command_encoder(&CommandEncoderDescriptor {
                label: Some("tecs frame encoder"),
            });

        let scratch = self.scratch.as_ref().expect("ensured above");
        if packet.instance_count > 0 && !batches.is_empty() {
            let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor {
                label: Some("tecs cull"),
                timestamp_writes: None,
            });
            pass.set_bind_group(0, &scratch.cull_group, &[]);
            // Mark, scan, compact: an ordered three-pass scan rather than an
            // atomic append, because an atomic gives no ordering and the
            // compacted list would come out differently every frame.
            pass.set_pipeline(&self.cull_pipelines[0]);
            pass.dispatch_workgroups(blocks, 1, 1);
            pass.set_pipeline(&self.cull_pipelines[1]);
            pass.dispatch_workgroups(1, 1, 1);
            pass.set_pipeline(&self.cull_pipelines[2]);
            pass.dispatch_workgroups(blocks, 1, 1);
            // Not a fourth pass of the scan: this reads what the scan produced
            // and turns it into one indirect draw per batch.
            pass.set_pipeline(&self.cull_pipelines[3]);
            pass.dispatch_workgroups((batches.len() as u32).div_ceil(ARGS_WORKGROUP), 1, 1);
        }

        for (index, spec) in graph.passes().iter().enumerate() {
            // On the stack rather than in a vector, because a frame walks
            // every pass and a per-pass allocation is a per-frame allocation.
            // An attachment borrows a target view, so the array cannot be kept
            // on the pass between frames either.
            let mut storage: [Option<RenderPassColorAttachment>; MAX_OUTPUTS] =
                [const { None }; MAX_OUTPUTS];
            let count = spec.outputs.len().max(1);
            if spec.outputs.is_empty() {
                storage[0] = Some(RenderPassColorAttachment {
                    view: &swapchain,
                    depth_slice: None,
                    resolve_target: None,
                    ops: Operations {
                        load: load_op(spec.clear, None),
                        store: StoreOp::Store,
                    },
                });
            } else {
                for (slot, output) in spec.outputs.iter().enumerate() {
                    storage[slot] = Some(RenderPassColorAttachment {
                        view: &self.targets.target(*output).view,
                        depth_slice: None,
                        resolve_target: None,
                        ops: Operations {
                            load: load_op(spec.clear, graph.targets()[*output].clear),
                            store: StoreOp::Store,
                        },
                    });
                }
            }
            let attachments = &storage[..count];
            let depth_attachment =
                (spec.depth != DepthMode::None).then(|| RenderPassDepthStencilAttachment {
                    view: &self
                        .targets
                        .depth()
                        .expect("a graph that uses depth allocates it")
                        .view,
                    depth_ops: Some(Operations {
                        load: match spec.depth_clear {
                            Some(value) => LoadOp::Clear(value),
                            None => LoadOp::Load,
                        },
                        store: if spec.depth == DepthMode::TestWrite {
                            StoreOp::Store
                        } else {
                            StoreOp::Discard
                        },
                    }),
                    stencil_ops: None,
                });

            let runtime = &self.passes[index];
            let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
                label: Some(spec.name.as_str()),
                color_attachments: attachments,
                depth_stencil_attachment: depth_attachment,
                ..Default::default()
            });
            match runtime.body {
                Body::Empty => {}
                Body::Fullscreen => {
                    let pipeline = runtime
                        .pipeline
                        .as_ref()
                        .expect("a fullscreen pass has one");
                    pass.set_pipeline(pipeline);
                    pass.set_bind_group(0, &self.scene_bind_group, &[]);
                    if let Some(inputs) = runtime.inputs.as_ref() {
                        pass.set_bind_group(1, inputs, &[]);
                    }
                    pass.draw(0..3, 0..1);
                }
                Body::Instanced { lane } => {
                    if packet.instance_count == 0 {
                        continue;
                    }
                    let pipeline = runtime
                        .pipeline
                        .as_ref()
                        .expect("an instanced pass has one");
                    pass.set_pipeline(pipeline);
                    pass.set_bind_group(0, &self.scene_bind_group, &[]);
                    // In packet order, because the scene composites back to
                    // front and a reordered batch is a reordered picture.
                    for (slot, batch) in batches.iter().enumerate() {
                        if batch.lane != lane {
                            continue;
                        }
                        let image = self
                            .bind_groups
                            .get(&(batch.image, batch.sampler))
                            .expect("resolved above");
                        pass.set_bind_group(1, image, &[]);
                        pass.set_bind_group(
                            2,
                            &scratch.draw_group,
                            &[slot as u32 * scratch.batch_stride],
                        );
                        pass.draw_indirect(&scratch.draw_args, slot as u64 * DRAW_ARGS_WORDS * 4);
                    }
                }
            }
        }

        self.queue.submit([encoder.finish()]);
        self.queue.present(frame);
        if reconfigure {
            self.surface.configure(&self.device, &self.config);
        }
        Ok(())
    }
}

/// Rebuilds every pipeline the graph implies.
///
/// Called when the declaration changes and when the swapchain format does,
/// since a pipeline bakes the formats of the attachments it writes.
pub fn build_passes(
    device: &Device,
    layouts: &Layouts,
    instance_module: &ShaderModule,
    graph: &Graph,
    surface_format: TextureFormat,
) -> Result<Vec<PassRuntime>> {
    let mut passes = Vec::with_capacity(graph.passes().len());
    for pass in graph.passes() {
        let body = body_for(&pass.name);
        let color_formats: Vec<TextureFormat> = if pass.outputs.is_empty() {
            vec![surface_format]
        } else {
            pass.outputs
                .iter()
                .map(|index| texture_format(graph.targets()[*index].format))
                .collect()
        };
        let depth = depth_state(pass.depth);

        let (pipeline, input_layout) = match body {
            Body::Empty => (None, None),
            Body::Instanced { lane } => {
                let entry = if lane == LANE_OPAQUE {
                    "geometryMain"
                } else {
                    "forwardMain"
                };
                let blend = if lane == LANE_OPAQUE {
                    None
                } else {
                    Some(BlendState::ALPHA_BLENDING)
                };
                let layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
                    label: Some("tecs instanced pipeline layout"),
                    bind_group_layouts: &[
                        Some(&layouts.scene),
                        Some(&layouts.image),
                        Some(&layouts.draw),
                    ],
                    immediate_size: 0,
                });
                let targets: Vec<Option<ColorTargetState>> = color_formats
                    .iter()
                    .map(|format| {
                        Some(ColorTargetState {
                            format: *format,
                            blend,
                            write_mask: ColorWrites::ALL,
                        })
                    })
                    .collect();
                let pipeline = device.create_render_pipeline(&RenderPipelineDescriptor {
                    label: Some(pass.name.as_str()),
                    layout: Some(&layout),
                    vertex: VertexState {
                        module: instance_module,
                        entry_point: Some("vertexMain"),
                        compilation_options: PipelineCompilationOptions::default(),
                        buffers: &[],
                    },
                    fragment: Some(FragmentState {
                        module: instance_module,
                        entry_point: Some(entry),
                        compilation_options: PipelineCompilationOptions::default(),
                        targets: &targets,
                    }),
                    primitive: Default::default(),
                    depth_stencil: depth.clone(),
                    multisample: Default::default(),
                    multiview_mask: None,
                    cache: None,
                });
                (Some(pipeline), None)
            }
            Body::Fullscreen => {
                let entry = fullscreen_entry(&pass.name)
                    .with_context(|| format!("pass '{}' has no fullscreen body", pass.name))?;
                let module = device.create_shader_module(ShaderModuleDescriptor {
                    label: Some(pass.name.as_str()),
                    source: ShaderSource::Wgsl(Cow::Owned(fullscreen_source(
                        entry.1,
                        pass.inputs.len(),
                    ))),
                });
                let input_layout = input_layout(device, pass.inputs.len());
                let layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
                    label: Some("tecs fullscreen pipeline layout"),
                    bind_group_layouts: &[Some(&layouts.scene), Some(&input_layout)],
                    immediate_size: 0,
                });
                let targets: Vec<Option<ColorTargetState>> = color_formats
                    .iter()
                    .map(|format| {
                        Some(ColorTargetState {
                            format: *format,
                            blend: entry.2,
                            write_mask: ColorWrites::ALL,
                        })
                    })
                    .collect();
                let pipeline = device.create_render_pipeline(&RenderPipelineDescriptor {
                    label: Some(pass.name.as_str()),
                    layout: Some(&layout),
                    vertex: VertexState {
                        module: &module,
                        entry_point: Some("fullscreenMain"),
                        compilation_options: PipelineCompilationOptions::default(),
                        buffers: &[],
                    },
                    fragment: Some(FragmentState {
                        module: &module,
                        entry_point: Some(entry.0),
                        compilation_options: PipelineCompilationOptions::default(),
                        targets: &targets,
                    }),
                    primitive: Default::default(),
                    depth_stencil: depth.clone(),
                    multisample: Default::default(),
                    multiview_mask: None,
                    cache: None,
                });
                (Some(pipeline), Some(input_layout))
            }
        };

        passes.push(PassRuntime {
            body,
            pipeline,
            inputs: None,
            input_layout,
        });
    }
    Ok(passes)
}

/// Builds the layout a fullscreen pass with `count` declared inputs binds.
fn input_layout(device: &Device, count: usize) -> BindGroupLayout {
    let mut entries = vec![BindGroupLayoutEntry {
        binding: 0,
        visibility: ShaderStages::FRAGMENT,
        ty: BindingType::Sampler(SamplerBindingType::NonFiltering),
        count: None,
    }];
    for index in 0..count {
        entries.push(BindGroupLayoutEntry {
            binding: index as u32 + 1,
            visibility: ShaderStages::FRAGMENT,
            ty: BindingType::Texture {
                sample_type: TextureSampleType::Float { filterable: false },
                view_dimension: TextureViewDimension::D2,
                multisampled: false,
            },
            count: None,
        });
    }
    device.create_bind_group_layout(&BindGroupLayoutDescriptor {
        label: Some("tecs pass input layout"),
        entries: &entries,
    })
}

/// The one module every instanced pass draws through: the material contract,
/// the dispatch the pack assembled, and the vertex and fragment halves that
/// call into it.
pub fn instance_source(pack: &ShaderPack) -> String {
    format!("{MATERIAL_WGSL}\n{}\n{INSTANCE_WGSL}", pack.dispatch())
}

/// Returns what this backend does for a pass of a given name.
///
/// Every name here is a compatibility surface. A name this backend does not
/// implement is a pass that begins, clears and draws nothing, which is a useful
/// pass rather than an error: a game declares one to clear a target it fills
/// some other way.
fn body_for(name: &str) -> Body {
    match name {
        "geometry" => Body::Instanced { lane: LANE_OPAQUE },
        "forward" => Body::Instanced { lane: LANE_BLEND },
        "lighting" | "composite" | "present" => Body::Fullscreen,
        _ => Body::Empty,
    }
}

/// The entry point, source and blend of each fullscreen pass this backend
/// implements.
fn fullscreen_entry(name: &str) -> Option<(&'static str, &'static str, Option<BlendState>)> {
    match name {
        "lighting" => Some(("lightingMain", LIGHTING_WGSL, None)),
        "composite" => Some(("compositeMain", COMPOSITE_WGSL, None)),
        // The scene is blended over the clear this pass declares, so a pixel
        // nothing drew shows the window's background.
        "present" => Some((
            "presentMain",
            PRESENT_WGSL,
            Some(BlendState::ALPHA_BLENDING),
        )),
        _ => None,
    }
}

/// Builds a fullscreen pass's module with exactly the input bindings its
/// pipeline layout provides.
fn fullscreen_source(fragment: &str, inputs: usize) -> String {
    let mut source = String::from(RESOLVE_WGSL);
    source.push('\n');
    for index in 0..inputs {
        source.push_str(&format!(
            "@group(1) @binding({}) var input{index}: texture_2d<f32>;\n",
            index + 1
        ));
    }
    source.push('\n');
    source.push_str(fragment);
    source
}

fn load_op(mode: ClearMode, target: Option<[f64; 4]>) -> LoadOp<Color> {
    let color = match mode {
        ClearMode::Load => None,
        ClearMode::Override(value) => Some(value),
        ClearMode::Target => target,
    };
    match color {
        Some(value) => LoadOp::Clear(Color {
            r: value[0],
            g: value[1],
            b: value[2],
            a: value[3],
        }),
        None => LoadOp::Load,
    }
}

fn depth_state(mode: DepthMode) -> Option<DepthStencilState> {
    match mode {
        DepthMode::None => None,
        // Less-or-equal rather than less, so equal depths still resolve to
        // whatever drew last: draw order is deterministic and means something
        // here, so depth decides between instances that differ and leaves the
        // rest alone.
        DepthMode::TestWrite => Some(DepthStencilState {
            format: DEPTH_FORMAT,
            depth_write_enabled: Some(true),
            depth_compare: Some(wgpu::CompareFunction::LessEqual),
            stencil: StencilState::default(),
            bias: DepthBiasState::default(),
        }),
        DepthMode::Test => Some(DepthStencilState {
            format: DEPTH_FORMAT,
            depth_write_enabled: Some(false),
            depth_compare: Some(wgpu::CompareFunction::LessEqual),
            stencil: StencilState::default(),
            bias: DepthBiasState::default(),
        }),
    }
}

fn texture_format(format: TargetFormat) -> TextureFormat {
    match format {
        // sRGB, so the whole chain from an image texture to the swapchain works
        // in the same space the wave-one path did.
        TargetFormat::Rgba8 => TextureFormat::Rgba8UnormSrgb,
        TargetFormat::Rgba16Float => TextureFormat::Rgba16Float,
        TargetFormat::R8 => TextureFormat::R8Unorm,
        TargetFormat::R16Float => TextureFormat::R16Float,
    }
}

fn storage_entry(binding: u32, read_only: bool) -> BindGroupLayoutEntry {
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

fn vertex_storage_entry(binding: u32) -> BindGroupLayoutEntry {
    BindGroupLayoutEntry {
        binding,
        visibility: ShaderStages::VERTEX,
        ty: BindingType::Buffer {
            ty: BufferBindingType::Storage { read_only: true },
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    }
}

/// Rounds a count up to the next power of two, so a scene that oscillates in
/// size does not reallocate every frame.
fn capacity(count: u32) -> u32 {
    count.next_power_of_two()
}

/// Finds the shader pack, or assembles one from the material directory.
///
/// A packaged build ships the pack beside its executable and takes the first
/// branch, which links nothing that reads a material file. The directory branch
/// is the development one.
fn load_pack() -> Result<ShaderPack> {
    if let Some(path) = std::env::var_os("TECS_SHADER_PACK") {
        return ShaderPack::read(std::path::Path::new(&path));
    }
    let executable = std::env::current_exe().context("find the Tecs host executable")?;
    let mut directory = executable.parent();
    while let Some(candidate) = directory {
        let packed = candidate.join("shaders.tecspack");
        if packed.is_file() {
            return ShaderPack::read(&packed);
        }
        let materials = candidate.join("assets/materials");
        if materials.is_dir() {
            return ShaderPack::assemble(&materials);
        }
        directory = candidate.parent();
    }
    bail!("no shaders.tecspack and no assets/materials above the executable")
}

fn create_samplers(device: &Device) -> Vec<Sampler> {
    let mut samplers = Vec::with_capacity(SAMPLER_COUNT as usize);
    // `address * 2 + filter`, the encoding `tecs.gfx.images.samplerIndex`
    // writes, so an index selects a sampler without a lookup table.
    for address in [
        AddressMode::ClampToEdge,
        AddressMode::Repeat,
        AddressMode::MirrorRepeat,
    ] {
        for filter in [FilterMode::Nearest, FilterMode::Linear] {
            samplers.push(device.create_sampler(&SamplerDescriptor {
                label: Some("tecs sampler"),
                address_mode_u: address,
                address_mode_v: address,
                address_mode_w: address,
                mag_filter: filter,
                min_filter: filter,
                mipmap_filter: MipmapFilterMode::Nearest,
                ..Default::default()
            }));
        }
    }
    samplers
}

fn create_image(
    device: &Device,
    queue: &Queue,
    id: u32,
    width: u32,
    height: u32,
    pixels: &[u8],
) -> Result<TextureView> {
    if width == 0 || height == 0 {
        bail!("image {id} is {width}x{height}; both dimensions must be positive");
    }
    let expected = (width as usize)
        .checked_mul(height as usize)
        .and_then(|texels| texels.checked_mul(BYTES_PER_TEXEL as usize))
        .context("image texel byte count overflowed")?;
    if pixels.len() != expected {
        bail!(
            "image {id} is {width}x{height} and needs {expected} RGBA8 bytes; it carries {}",
            pixels.len()
        );
    }
    let size = Extent3d {
        width,
        height,
        depth_or_array_layers: 1,
    };
    let texture = device.create_texture(&TextureDescriptor {
        label: Some("tecs image"),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: TextureDimension::D2,
        format: TextureFormat::Rgba8UnormSrgb,
        usage: TextureUsages::TEXTURE_BINDING | TextureUsages::COPY_DST,
        view_formats: &[],
    });
    queue.write_texture(
        TexelCopyTextureInfo {
            texture: &texture,
            mip_level: 0,
            origin: Origin3d::ZERO,
            aspect: TextureAspect::All,
        },
        pixels,
        TexelCopyBufferLayout {
            offset: 0,
            bytes_per_row: Some(width * BYTES_PER_TEXEL),
            rows_per_image: Some(height),
        },
        size,
    );
    // The view keeps the texture alive, so the texture itself is not retained.
    Ok(texture.create_view(&TextureViewDescriptor::default()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rounds_capacities_up_to_a_power_of_two() {
        assert_eq!(capacity(1), 1);
        assert_eq!(capacity(3), 4);
        assert_eq!(capacity(256), 256);
        assert_eq!(capacity(257), 512);
    }

    #[test]
    fn maps_every_pass_name_this_backend_implements() {
        assert!(matches!(
            body_for("geometry"),
            Body::Instanced { lane: LANE_OPAQUE }
        ));
        assert!(matches!(
            body_for("forward"),
            Body::Instanced { lane: LANE_BLEND }
        ));
        assert!(matches!(body_for("lighting"), Body::Fullscreen));
        assert!(matches!(body_for("composite"), Body::Fullscreen));
        assert!(matches!(body_for("present"), Body::Fullscreen));
        // A pass this backend has no body for still runs: it begins with its
        // attachments and its clears and draws nothing.
        assert!(matches!(body_for("game.overlay"), Body::Empty));
    }

    #[test]
    fn takes_a_clear_from_the_pass_before_the_target() {
        let target = Some([1.0, 0.0, 0.0, 1.0]);
        assert!(matches!(load_op(ClearMode::Load, target), LoadOp::Load));
        assert!(matches!(load_op(ClearMode::Target, None), LoadOp::Load));
        let LoadOp::Clear(color) = load_op(ClearMode::Target, target) else {
            panic!("a target's own clear is used");
        };
        assert_eq!(color.r, 1.0);
        let LoadOp::Clear(color) = load_op(ClearMode::Override([0.0, 0.5, 0.0, 1.0]), target)
        else {
            panic!("a pass's clear wins over its target's");
        };
        assert_eq!(color.g, 0.5);
    }

    #[test]
    fn declares_exactly_the_inputs_a_pass_binds() {
        let source = fullscreen_source("@fragment fn x() {}", 4);
        assert!(source.contains("@group(1) @binding(1) var input0: texture_2d<f32>;"));
        assert!(source.contains("@group(1) @binding(4) var input3: texture_2d<f32>;"));
        assert!(!source.contains("input4"));
        assert!(
            source.contains("fn fullscreenMain"),
            "the vertex half is shared"
        );

        let none = fullscreen_source("@fragment fn x() {}", 0);
        assert!(!none.contains("input0"));
    }

    #[test]
    fn writes_depth_only_where_a_pass_says_so() {
        assert!(depth_state(DepthMode::None).is_none());
        let write = depth_state(DepthMode::TestWrite).expect("attached");
        assert_eq!(write.depth_write_enabled, Some(true));
        assert_eq!(write.depth_compare, Some(wgpu::CompareFunction::LessEqual));
        let test = depth_state(DepthMode::Test).expect("attached");
        assert_eq!(test.depth_write_enabled, Some(false));
    }
}
