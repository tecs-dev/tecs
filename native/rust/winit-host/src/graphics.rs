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

mod meshes;
mod meshlighting;
mod modeltextures;
mod particles;
mod views;

use std::borrow::Cow;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use wgpu::util::DeviceExt;

use anyhow::{bail, Context, Result};
use wgpu::{
    AddressMode, BindGroup, BindGroupDescriptor, BindGroupEntry, BindGroupLayout,
    BindGroupLayoutDescriptor, BindGroupLayoutEntry, BindingResource, BindingType, BlendComponent,
    BlendFactor, BlendOperation, BlendState, Buffer, BufferBindingType, BufferDescriptor,
    BufferUsages, Color, ColorTargetState, ColorWrites, CommandEncoderDescriptor,
    ComputePassDescriptor, ComputePipeline, ComputePipelineDescriptor, CurrentSurfaceTexture,
    DepthBiasState, DepthStencilState, Device, DeviceDescriptor, Extent3d, FilterMode,
    FragmentState, Instance, InstanceDescriptor, LoadOp, MipmapFilterMode, Operations, Origin3d,
    PipelineCompilationOptions, PipelineLayoutDescriptor, Queue, RenderPassColorAttachment,
    RenderPassDepthStencilAttachment, RenderPassDescriptor, RenderPipeline,
    RenderPipelineDescriptor, Sampler, SamplerBindingType, SamplerDescriptor, ShaderModule,
    ShaderModuleDescriptor, ShaderSource, ShaderStages, StencilState, StoreOp, Surface,
    SurfaceConfiguration, TexelCopyBufferLayout, TexelCopyTextureInfo, TextureAspect,
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
    parse_frame, Batch, RetainedScene, CAST_FANOUT, INSTANCE_STRIDE, LANE_BLEND, LANE_COUNT,
    LANE_OPAQUE, LIGHT_STRIDE, MAX_LIGHTS, SAMPLER_COUNT, SCENE_FLOATS,
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

/// Tiles the view is divided into on each axis, and the lights one holds. The
/// same two numbers live in `tecs.gfx.lighting`, `lightbin.wgsl` and
/// `lighting.wgsl`, and the four only work while they agree.
const LIGHT_TILES: u32 = 32;
const LIGHT_TILE_SLOTS: u32 = 64;
const LIGHT_TILE_COUNT: u32 = LIGHT_TILES * LIGHT_TILES;

/// The workgroup size the tile binning is written against.
const BIN_WORKGROUP: u32 = 64;

/// Which of the three shadow draws a cast pipeline is running. The numbering is
/// shared with `cast.wgsl`.
const CAST_MODE_MASK: u32 = 0;
const CAST_MODE_SHADOW: u32 = 1;
const CAST_MODE_STAMP: u32 = 2;

const MATERIAL_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/material.wgsl");
const FRAMETABLE_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/frametable.wgsl");
const TILECHUNK_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/tilechunk.wgsl");
const INSTANCE_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/instance.wgsl");
const CULL_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/cull.wgsl");
const RESOLVE_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/resolve.wgsl");
const LIGHTING_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/lighting.wgsl");
const COMPOSITE_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/composite.wgsl");
const PRESENT_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/present.wgsl");
const POSTPROCESS_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/postprocess.wgsl");
const LIGHTBIN_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/lightbin.wgsl");
const CAST_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/cast.wgsl");

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
    /// Covers the target once, and binds the light buffer and the tile lists
    /// beside the pass's declared inputs.
    Lighting,
    /// Draws every occluder's silhouette into the light mask, at the mask's own
    /// widened projection, resolving overlap with a maximum so the tallest
    /// occluder wins.
    Occluders,
    /// Draws the stretched copies into the drop-shadow target with a minimum so
    /// the darkest wins, then stamps each caster back over the shadow it threw
    /// across its own feet with a maximum.
    DropShadows,
    /// Begins the pass, applies its clears, and draws nothing. This is what a
    /// pass whose name this backend does not implement does, and it is also a
    /// useful pass in its own right: it clears a target.
    Empty,
}

/// What has to be true of a frame for a pass to run at all.
///
/// A gated pass is skipped entirely rather than begun and left empty, so a game
/// with no shadows and no bloom pays nothing at all for their being declared.
/// The graph still holds them, which is what keeps a game's own pass placed
/// beside one of them valid when the tuning changes.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Gate {
    Always,
    Shadows,
    Bloom,
}

impl Gate {
    pub fn open(self, shadows: bool, bloom: bool) -> bool {
        match self {
            Self::Always => true,
            Self::Shadows => shadows,
            Self::Bloom => bloom,
        }
    }
}

pub struct PassRuntime {
    parameters: Option<(Buffer, BindGroup)>,
    pub body: Body,
    pub gate: Gate,
    pub pipeline: Option<RenderPipeline>,
    /// The second pipeline of a two-draw pass, which is the drop shadow's stamp.
    pub second: Option<RenderPipeline>,
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
    cast_group: BindGroup,
    instance_capacity: u32,
    batch_capacity: u32,
    block_capacity: u32,
    cast_capacity: u32,
    batch_stride: u32,
    mode_stride: u32,
}

/// The bind group layouts every pipeline in this backend is built against.
///
/// Held together because a pipeline layout names several of them and a test
/// that builds pipelines needs the same set the frame does.
pub struct Layouts {
    pub scene: BindGroupLayout,
    pub mesh_composite: BindGroupLayout,
    pub image: BindGroupLayout,
    pub cull: BindGroupLayout,
    pub draw: BindGroupLayout,
    pub cast: BindGroupLayout,
    pub lighting: BindGroupLayout,
    pub bin: BindGroupLayout,
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
                BindGroupLayoutEntry {
                    binding: 2,
                    visibility: ShaderStages::FRAGMENT,
                    ty: BindingType::Texture {
                        sample_type: TextureSampleType::Float { filterable: true },
                        view_dimension: TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                BindGroupLayoutEntry {
                    binding: 3,
                    visibility: ShaderStages::FRAGMENT,
                    ty: BindingType::Texture {
                        sample_type: TextureSampleType::Float { filterable: true },
                        view_dimension: TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                BindGroupLayoutEntry {
                    binding: 4,
                    visibility: ShaderStages::FRAGMENT,
                    ty: BindingType::Texture {
                        sample_type: TextureSampleType::Float { filterable: true },
                        view_dimension: TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                BindGroupLayoutEntry {
                    binding: 6,
                    visibility: ShaderStages::VERTEX,
                    ty: BindingType::Buffer {
                        ty: BufferBindingType::Storage { read_only: true },
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                BindGroupLayoutEntry {
                    binding: 5,
                    visibility: ShaderStages::VERTEX,
                    ty: BindingType::Buffer {
                        ty: BufferBindingType::Storage { read_only: true },
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
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
                storage_entry(8, true),
                storage_entry(9, true),
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
        // The shadow draws read the same instance buffer the drawing lanes do,
        // plus the cast list, the light buffer, and two dynamic offsets: which
        // batch this draw is, and which of the three draws.
        let cast = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("tecs cast layout"),
            entries: &[
                vertex_storage_entry(0),
                vertex_storage_entry(1),
                vertex_storage_entry(2),
                dynamic_uniform_entry(3, ShaderStages::VERTEX),
                vertex_storage_entry(4),
                dynamic_uniform_entry(5, ShaderStages::VERTEX),
            ],
        });
        let lighting = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("tecs lighting layout"),
            entries: &[
                fragment_storage_entry(0),
                fragment_storage_entry(1),
                fragment_storage_entry(2),
            ],
        });
        let bin = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("tecs light bin layout"),
            entries: &[
                storage_entry(0, true),
                storage_entry(1, false),
                storage_entry(2, false),
                BindGroupLayoutEntry {
                    binding: 3,
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
        let mesh_composite = input_layout(device, &[Input::Target(0)]);
        Self {
            mesh_composite,
            scene,
            image,
            cull,
            draw,
            cast,
            lighting,
            bin,
        }
    }
}

/// A pending read of a submitted frame's GPU culling result.
pub struct DrawCountReadback {
    buffer: Buffer,
    ready: std::sync::mpsc::Receiver<Result<(), wgpu::BufferAsyncError>>,
}

pub struct Capture {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
    pub png: Vec<u8>,
}

pub struct Graphics {
    particle_pool: Option<u32>,
    particle_pools: HashMap<u32, particles::Pool>,
    mesh_renderer: Option<meshes::Renderer>,
    mesh_source: Option<(u64, BindGroup)>,
    mesh_fallback: BindGroup,
    views: HashMap<u32, views::ViewState>,
    view_revision: Option<u32>,
    rendering_view: bool,
    asset_revision: u64,
    view_compositor: Option<views::Compositor>,
    surface: Option<Surface<'static>>,
    offscreen: Option<wgpu::Texture>,
    capture_requested: bool,
    captured: Option<Result<Capture>>,
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
    linear_images: HashMap<u32, TextureView>,
    tile_chunks: Buffer,
    frame_table: Buffer,
    material_maps: HashMap<u32, [u32; 3]>,
    map_fallbacks: [TextureView; 3],
    bind_groups: HashMap<(u32, u32), BindGroup>,

    pass_sampler: Sampler,
    cull_pipelines: [ComputePipeline; 5],
    bin_pipeline: ComputePipeline,
    instance_module: ShaderModule,
    cast_module: ShaderModule,

    /// The light table, the tile lists, and the uniform the binning reads. All
    /// three are a fixed size, so they are made once and never replaced while a
    /// frame in flight is reading them.
    lights: Buffer,
    // Read and written only by the shaders. They are held because a bind group
    // borrows the buffers it was made from rather than owning them, so dropping
    // one here would leave the group pointing at nothing.
    #[allow(dead_code)]
    tile_counts: Buffer,
    #[allow(dead_code)]
    tile_lights: Buffer,
    bin_uniform: Buffer,
    bin_group: BindGroup,
    lighting_group: BindGroup,
    /// The three cast modes, written once, selected by a dynamic offset.
    cast_modes: Buffer,

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
    resident_scene: Option<RetainedScene>,
    /// What a device-lost callback reported, checked before every frame.
    lost: Arc<Mutex<Option<String>>>,
    /// What an uncaptured validation error reported.
    failed: Arc<Mutex<Option<String>>>,
}

fn benchmark_present_mode(supported: &[wgpu::PresentMode]) -> Result<wgpu::PresentMode> {
    [wgpu::PresentMode::Immediate, wgpu::PresentMode::Mailbox]
        .into_iter()
        .find(|mode| supported.contains(mode))
        .context(
            "this surface has no uncapped presentation mode; use the offscreen render benchmark",
        )
}

impl Graphics {
    pub fn new(window: Arc<Window>, display: OwnedDisplayHandle, benchmark: bool) -> Result<Self> {
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
            required_features: adapter.features() & (wgpu::Features::INDIRECT_FIRST_INSTANCE | wgpu::Features::TEXTURE_COMPRESSION_BC | wgpu::Features::TEXTURE_BINDING_ARRAY | wgpu::Features::SAMPLED_TEXTURE_AND_STORAGE_BUFFER_ARRAY_NON_UNIFORM_INDEXING),
            label: Some("tecs device"),
            required_limits: wgpu::Limits {
                max_storage_buffer_binding_size: adapter.limits().max_storage_buffer_binding_size,
                max_buffer_size: adapter.limits().max_buffer_size,
                max_binding_array_elements_per_shader_stage: adapter.limits().max_binding_array_elements_per_shader_stage,
                max_storage_buffers_per_shader_stage: 9,
                ..Default::default()
            },
            ..Default::default()
        }))
        .context("create the wgpu device")?;
        let mut config = surface
            .get_default_config(&adapter, size.width.max(1), size.height.max(1))
            .context("choose a supported wgpu surface configuration")?;
        if surface
            .get_capabilities(&adapter)
            .usages
            .contains(TextureUsages::COPY_SRC)
        {
            config.usage |= TextureUsages::COPY_SRC;
        }
        if benchmark {
            config.present_mode =
                benchmark_present_mode(&surface.get_capabilities(&adapter).present_modes)?;
        }
        surface.configure(&device, &config);

        eprintln!(
            "tecs GPU: {} ({:?}), storage binding limit {} bytes",
            adapter.get_info().name,
            adapter.get_info().backend,
            device.limits().max_storage_buffer_binding_size
        );
        if benchmark {
            eprintln!(
                "tecs benchmark presentation: {:?} (uncapped)",
                config.present_mode
            );
        }
        let pack = load_pack()?;
        Self::assemble(Some(surface), device, queue, config, pack)
    }

    /// Uses the production frame graph on a fixed GPU target without a desktop surface.
    pub fn offscreen(width: u32, height: u32) -> Result<Self> {
        let instance = Instance::new(InstanceDescriptor::new_without_display_handle());
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            ..Default::default()
        }))?;
        let (device, queue) = pollster::block_on(adapter.request_device(&DeviceDescriptor {
            required_features: adapter.features() & (wgpu::Features::INDIRECT_FIRST_INSTANCE | wgpu::Features::TEXTURE_COMPRESSION_BC | wgpu::Features::TEXTURE_BINDING_ARRAY | wgpu::Features::SAMPLED_TEXTURE_AND_STORAGE_BUFFER_ARRAY_NON_UNIFORM_INDEXING),
            label: Some("tecs benchmark device"),
            required_limits: wgpu::Limits {
                max_storage_buffer_binding_size: adapter.limits().max_storage_buffer_binding_size,
                max_buffer_size: adapter.limits().max_buffer_size,
                max_binding_array_elements_per_shader_stage: adapter.limits().max_binding_array_elements_per_shader_stage,
                max_storage_buffers_per_shader_stage: 9,
                ..Default::default()
            },
            ..Default::default()
        }))?;
        eprintln!(
            "tecs GPU: {} ({:?}), storage binding limit {} bytes",
            adapter.get_info().name,
            adapter.get_info().backend,
            device.limits().max_storage_buffer_binding_size
        );
        let config = SurfaceConfiguration {
            usage: TextureUsages::RENDER_ATTACHMENT | TextureUsages::COPY_SRC,
            format: TextureFormat::Bgra8UnormSrgb,
            width,
            height,
            // No surface is created, so presentation settings are never used.
            present_mode: wgpu::PresentMode::Immediate,
            desired_maximum_frame_latency: 2,
            alpha_mode: wgpu::CompositeAlphaMode::Opaque,
            view_formats: vec![],
            color_space: Default::default(),
        };
        Self::assemble(None, device, queue, config, load_pack()?)
    }

    /// Builds everything that does not depend on the graph.
    ///
    /// Split out so a test can hand in a headless device and the same code
    /// answers.
    fn assemble(
        surface: Option<Surface<'static>>,
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

        let mut scene = [0.0_f32; SCENE_FLOATS];
        scene[0] = 1.0;
        scene[1] = 1.0;
        scene[2] = 0.5;
        scene[3] = 0.5;
        scene[4] = 1.0;
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
        let cull_pipelines = [
            "markMain",
            "scanMain",
            "compactMain",
            "argsMain",
            "castMain",
        ]
        .map(|entry| {
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
        let cast_module = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("tecs cast"),
            source: ShaderSource::Wgsl(Cow::Owned(cast_source(&pack))),
        });

        // Fixed sizes, so these are made once and never replaced while a frame
        // in flight is reading them. A grid that grew with the window would have
        // to be reallocated under a frame that had already been submitted.
        let lights = device.create_buffer(&BufferDescriptor {
            label: Some("tecs lights"),
            size: u64::from(MAX_LIGHTS) * LIGHT_STRIDE as u64,
            usage: BufferUsages::STORAGE | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let tile_counts = device.create_buffer(&BufferDescriptor {
            label: Some("tecs light tile counts"),
            size: u64::from(LIGHT_TILE_COUNT) * 4,
            usage: BufferUsages::STORAGE | BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        let tile_lights = device.create_buffer(&BufferDescriptor {
            label: Some("tecs light tile lists"),
            size: u64::from(LIGHT_TILE_COUNT) * u64::from(LIGHT_TILE_SLOTS) * 4,
            usage: BufferUsages::STORAGE | BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        let bin_uniform = device.create_buffer(&BufferDescriptor {
            label: Some("tecs light bin uniform"),
            size: 32,
            usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let bin_module = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("tecs light bin"),
            source: ShaderSource::Wgsl(Cow::Borrowed(LIGHTBIN_WGSL)),
        });
        let bin_pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
            label: Some("tecs light bin pipeline layout"),
            bind_group_layouts: &[Some(&layouts.bin)],
            immediate_size: 0,
        });
        let bin_pipeline = device.create_compute_pipeline(&ComputePipelineDescriptor {
            label: Some("tecs light bin"),
            layout: Some(&bin_pipeline_layout),
            module: &bin_module,
            entry_point: Some("binMain"),
            compilation_options: PipelineCompilationOptions::default(),
            cache: None,
        });
        let bin_group = device.create_bind_group(&BindGroupDescriptor {
            label: Some("tecs light bin bind group"),
            layout: &layouts.bin,
            entries: &[
                BindGroupEntry {
                    binding: 0,
                    resource: lights.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 1,
                    resource: tile_counts.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 2,
                    resource: tile_lights.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 3,
                    resource: bin_uniform.as_entire_binding(),
                },
            ],
        });
        let lighting_group = device.create_bind_group(&BindGroupDescriptor {
            label: Some("tecs lighting bind group"),
            layout: &layouts.lighting,
            entries: &[
                BindGroupEntry {
                    binding: 0,
                    resource: lights.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 1,
                    resource: tile_counts.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 2,
                    resource: tile_lights.as_entire_binding(),
                },
            ],
        });

        // Three values, written once, one per shadow draw. A dynamic offset
        // selects which, so the three draws share one pipeline layout and one
        // bind group.
        let mode_stride = device.limits().min_uniform_buffer_offset_alignment.max(4);
        let cast_modes = device.create_buffer(&BufferDescriptor {
            label: Some("tecs cast modes"),
            size: u64::from(mode_stride) * 3,
            usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let mut modes = vec![0_u8; (mode_stride * 3) as usize];
        for mode in [CAST_MODE_MASK, CAST_MODE_SHADOW, CAST_MODE_STAMP] {
            let at = (mode * mode_stride) as usize;
            modes[at..at + 4].copy_from_slice(&mode.to_ne_bytes());
        }
        queue.write_buffer(&cast_modes, 0, &modes);

        let frame_table = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("sprite frame table"),
            contents: &[0; 4],
            usage: BufferUsages::STORAGE | BufferUsages::COPY_DST,
        });
        let tile_chunks = device.create_buffer(&BufferDescriptor {
            label: Some("tecs tile grids"),
            size: super::packet::TILE_STRIDE as u64,
            usage: BufferUsages::STORAGE | BufferUsages::COPY_DST,
            mapped_at_creation: false,
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
        let mut map_fallbacks = [
            create_image(&device, &queue, 0, 1, 1, &[128, 128, 255, 255])?,
            create_image(&device, &queue, 0, 1, 1, &[0, 0, 0, 255])?,
            create_image(&device, &queue, 0, 1, 1, &[255, 128, 0, 255])?,
        ];
        map_fallbacks[0] = linear_view(&map_fallbacks[0]);
        map_fallbacks[2] = linear_view(&map_fallbacks[2]);
        let fallback = create_image(&device, &queue, 0, 1, 1, &[255, 255, 255, 255])?;

        let offscreen = surface.is_none().then(|| {
            device.create_texture(&TextureDescriptor {
                label: Some("tecs benchmark output"),
                size: Extent3d {
                    width: config.width,
                    height: config.height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: TextureDimension::D2,
                format: config.format,
                usage: TextureUsages::RENDER_ATTACHMENT | TextureUsages::COPY_SRC,
                view_formats: &[],
            })
        });
        let mesh_black = device.create_texture(&TextureDescriptor {
            label: Some("empty mesh view"),
            size: Extent3d {
                width: 1,
                height: 1,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: TextureDimension::D2,
            format: TextureFormat::Rgba16Float,
            usage: TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        let mesh_view = mesh_black.create_view(&Default::default());
        let mesh_fallback = device.create_bind_group(&BindGroupDescriptor {
            label: Some("empty mesh view"),
            layout: &layouts.mesh_composite,
            entries: &[
                BindGroupEntry {
                    binding: 0,
                    resource: BindingResource::Sampler(&pass_sampler),
                },
                BindGroupEntry {
                    binding: 1,
                    resource: BindingResource::TextureView(&mesh_view),
                },
            ],
        });
        Ok(Self {
            mesh_renderer: None,
            mesh_source: None,
            mesh_fallback,
            views: HashMap::new(),
            view_revision: None,
            rendering_view: false,
            asset_revision: 0,
            view_compositor: None,
            surface,
            offscreen,
            capture_requested: false,
            captured: None,
            tile_chunks,
            frame_table,
            particle_pool: None,
            particle_pools: HashMap::new(),
            material_maps: HashMap::new(),
            map_fallbacks,
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
            linear_images: HashMap::new(),
            bind_groups: HashMap::new(),
            pass_sampler,
            cull_pipelines,
            bin_pipeline,
            instance_module,
            cast_module,
            lights,
            tile_counts,
            tile_lights,
            bin_uniform,
            bin_group,
            lighting_group,
            cast_modes,
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
            resident_scene: None,
            lost,
            failed,
        })
    }

    pub fn upload_model(&mut self, id: u32, bytes: &[u8]) -> Result<()> {
        let renderer = self
            .mesh_renderer
            .get_or_insert_with(|| meshes::Renderer::new(&self.device, &self.queue));
        renderer.upload(id, bytes)?;
        self.view_revision = Some(0);
        Ok(())
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
        if let Some(surface) = &self.surface {
            surface.configure(&self.device, &self.config);
        }
    }

    /// Makes one image resident, replacing whatever already lived under its id.
    pub fn upload_image(&mut self, id: u32, width: u32, height: u32, pixels: &[u8]) -> Result<()> {
        self.asset_revision += 1;
        if id == 0 {
            bail!("image id 0 is the backend's own fallback and cannot be replaced");
        }
        let view = create_image(&self.device, &self.queue, id, width, height, pixels)?;
        self.linear_images.insert(id, linear_view(&view));
        self.images.insert(id, view);
        // A replacement invalidates every bind group holding the old view.
        self.bind_groups.retain(|(image, _), _| {
            *image != id
                && !self
                    .material_maps
                    .get(image)
                    .is_some_and(|maps| maps.contains(&id))
        });
        Ok(())
    }

    /// Drops one image and everything bound to it.
    pub fn release_image(&mut self, id: u32) -> Result<()> {
        self.asset_revision += 1;
        if id == 0 {
            bail!("image id 0 is the backend's own fallback and cannot be released");
        }
        self.bind_groups.retain(|(image, _), _| {
            *image != id
                && !self
                    .material_maps
                    .get(image)
                    .is_some_and(|maps| maps.contains(&id))
        });
        self.linear_images.remove(&id);
        if self.images.remove(&id).is_none() {
            bail!("image {id} is not resident");
        }
        Ok(())
    }

    pub fn set_material_maps(&mut self, image: u32, maps: [u32; 3]) -> Result<()> {
        self.asset_revision += 1;
        let parent = self
            .images
            .get(&image)
            .context("material albedo is not resident")?;
        for id in maps.into_iter().filter(|id| *id != 0) {
            let map = self
                .images
                .get(&id)
                .context("material map is not resident")?;
            if map.texture().size() != parent.texture().size() {
                bail!("material map dimensions differ from albedo");
            }
        }
        self.material_maps.insert(image, maps);
        self.bind_groups.retain(|(id, _), _| *id != image);
        Ok(())
    }

    fn image_bind_group(&mut self, image: u32, sampler: u32) -> &BindGroup {
        let key = (image, sampler);
        if !self.bind_groups.contains_key(&key) {
            // An id the packet names but nothing uploaded falls back rather
            // than failing the frame, which is what makes a missing asset a
            // visible untextured quad instead of a dead window.
            let view = self.images.get(&image).unwrap_or(&self.fallback);
            let maps = self.material_maps.get(&image).copied().unwrap_or([0; 3]);
            let views: Vec<_> = maps
                .iter()
                .enumerate()
                .map(|(i, id)| {
                    (if i == 1 {
                        &self.images
                    } else {
                        &self.linear_images
                    })
                    .get(id)
                    .unwrap_or(&self.map_fallbacks[i])
                })
                .collect();
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
                    BindGroupEntry {
                        binding: 2,
                        resource: BindingResource::TextureView(views[0]),
                    },
                    BindGroupEntry {
                        binding: 3,
                        resource: BindingResource::TextureView(views[1]),
                    },
                    BindGroupEntry {
                        binding: 4,
                        resource: BindingResource::TextureView(views[2]),
                    },
                    BindGroupEntry {
                        binding: 6,
                        resource: self.frame_table.as_entire_binding(),
                    },
                    BindGroupEntry {
                        binding: 5,
                        resource: self.tile_chunks.as_entire_binding(),
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
    fn ensure_scratch(&mut self, instance_count: u32, batch_count: u32, caster_count: u32) {
        let instance_capacity = capacity(instance_count.max(1));
        let batch_capacity = capacity(batch_count.max(1));
        let blocks = instance_count.div_ceil(WORKGROUP).max(1);
        let block_capacity = capacity(blocks + 1);
        let cast_capacity = capacity(caster_count.max(1));
        if let Some(scratch) = self.scratch.as_ref() {
            if scratch.instance_capacity >= instance_capacity
                && scratch.batch_capacity >= batch_capacity
                && scratch.block_capacity >= block_capacity
                && scratch.cast_capacity >= cast_capacity
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
        let cast_capacity =
            cast_capacity.max(self.scratch.as_ref().map_or(0, |held| held.cast_capacity));

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
        // The shadow lane's list rides at the end of the visible buffer and its
        // bases at the end of the batch bases, rather than in two bindings of
        // their own: WebGPU guarantees eight storage buffers per stage and the
        // cull would otherwise want eleven. Each offset is rounded up to the
        // storage binding alignment, because the shadow draws bind the same
        // buffer from there.
        let cast_words = cast_list_offset(instance_capacity);
        let visible = device.create_buffer(&BufferDescriptor {
            label: Some("tecs visible lists"),
            size: (u64::from(cast_words) + u64::from(cast_capacity) * u64::from(CAST_FANOUT)) * 4,
            usage: BufferUsages::STORAGE | BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        // Twice over, because the shadow lane's arguments follow the drawing
        // lanes' in the same buffer. An indirect draw takes a byte offset, so
        // that half needs no alignment of its own.
        let draw_args = device.create_buffer(&BufferDescriptor {
            label: Some("tecs draw arguments"),
            size: u64::from(batch_capacity) * 2 * DRAW_ARGS_WORDS * 4,
            usage: BufferUsages::STORAGE | BufferUsages::INDIRECT | BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        let cast_base_words = cast_base_offset(batch_capacity);
        let batch_base = device.create_buffer(&BufferDescriptor {
            label: Some("tecs batch bases"),
            size: (u64::from(cast_base_words) + u64::from(batch_capacity)) * 4,
            usage: BufferUsages::STORAGE | BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        let cull_uniform = device.create_buffer(&BufferDescriptor {
            label: Some("tecs cull uniform"),
            size: 64,
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
                BindGroupEntry {
                    binding: 8,
                    resource: self.lights.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 9,
                    resource: self.frame_table.as_entire_binding(),
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

        let cast_group = device.create_bind_group(&BindGroupDescriptor {
            label: Some("tecs cast bind group"),
            layout: &self.layouts.cast,
            entries: &[
                BindGroupEntry {
                    binding: 0,
                    resource: instances.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                        buffer: &visible,
                        offset: u64::from(cast_words) * 4,
                        size: None,
                    }),
                },
                BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                        buffer: &batch_base,
                        offset: u64::from(cast_base_words) * 4,
                        size: None,
                    }),
                },
                BindGroupEntry {
                    binding: 3,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                        buffer: &batch_index,
                        offset: 0,
                        size: std::num::NonZeroU64::new(4),
                    }),
                },
                BindGroupEntry {
                    binding: 4,
                    resource: self.lights.as_entire_binding(),
                },
                BindGroupEntry {
                    binding: 5,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                        buffer: &self.cast_modes,
                        offset: 0,
                        size: std::num::NonZeroU64::new(4),
                    }),
                },
            ],
        });

        let mode_stride = self
            .device
            .limits()
            .min_uniform_buffer_offset_alignment
            .max(4);
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
            cast_group,
            instance_capacity,
            batch_capacity,
            block_capacity,
            cast_capacity,
            batch_stride,
            mode_stride,
        });
    }

    /// Enqueues a small copy without waiting for the GPU on the event thread.
    pub fn request_drawn_instances(&self) -> Result<DrawCountReadback> {
        let scratch = self.scratch.as_ref().context("no rendered frame")?;
        let size = self.batches.len() as u64 * 16;
        anyhow::ensure!(size > 0, "no draw batches to read");
        let readback = self.device.create_buffer(&BufferDescriptor {
            label: Some("tecs benchmark draw counts"),
            size,
            usage: BufferUsages::MAP_READ | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let mut encoder = self
            .device
            .create_command_encoder(&CommandEncoderDescriptor::default());
        encoder.copy_buffer_to_buffer(&scratch.draw_args, 0, &readback, 0, size);
        self.queue.submit([encoder.finish()]);
        let (send, receive) = std::sync::mpsc::channel();
        readback
            .slice(..)
            .map_async(wgpu::MapMode::Read, move |result| {
                let _ = send.send(result);
            });
        Ok(DrawCountReadback {
            buffer: readback,
            ready: receive,
        })
    }

    /// Returns the completed count, or None while the copy is in flight.
    pub fn poll_drawn_instances(&self, readback: &DrawCountReadback) -> Result<Option<u32>> {
        self.device.poll(wgpu::PollType::Poll)?;
        match readback.ready.try_recv() {
            Ok(result) => result?,
            Err(std::sync::mpsc::TryRecvError::Empty) => return Ok(None),
            Err(error) => return Err(error.into()),
        }
        let bytes = readback.buffer.slice(..).get_mapped_range()?;
        let (args, _) = bytes[..].as_chunks::<16>();
        let count = args
            .iter()
            .map(|args| u32::from_ne_bytes(args[4..8].try_into().expect("draw args")))
            .sum();
        drop(bytes);
        readback.buffer.unmap();
        Ok(Some(count))
    }

    /// Requests readback of the next rendered presentation image.
    pub fn request_capture(&mut self) {
        self.capture_requested = true;
        self.captured = None;
    }

    pub fn take_capture(&mut self) -> Result<Capture> {
        self.capture_requested = false;
        self.captured
            .take()
            .context("the requested frame was not rendered")?
    }

    /// Reads the last completed offscreen frame without advancing simulation.
    pub fn capture_offscreen(&self) -> Result<Capture> {
        let texture = self
            .offscreen
            .as_ref()
            .context("capture needs an offscreen renderer")?;
        let pitch = (self.config.width * 4).div_ceil(256) * 256;
        let buffer = self.device.create_buffer(&BufferDescriptor {
            label: Some("tecs offscreen screenshot"),
            size: u64::from(pitch) * u64::from(self.config.height),
            usage: BufferUsages::COPY_DST | BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let mut encoder = self.device.create_command_encoder(&Default::default());
        encoder.copy_texture_to_buffer(
            texture.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &buffer,
                layout: TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(pitch),
                    rows_per_image: Some(self.config.height),
                },
            },
            texture.size(),
        );
        self.queue.submit([encoder.finish()]);
        self.read_capture(&buffer, pitch)
    }

    fn read_capture(&self, buffer: &Buffer, pitch: u32) -> Result<Capture> {
        use image::ImageEncoder;
        let (send, receive) = std::sync::mpsc::channel();
        buffer
            .slice(..)
            .map_async(wgpu::MapMode::Read, move |result| {
                let _ = send.send(result);
            });
        self.device.poll(wgpu::PollType::wait_indefinitely())?;
        receive.recv()??;
        let mapped = buffer.slice(..).get_mapped_range()?;
        let mut rgba = Vec::with_capacity((self.config.width * self.config.height * 4) as usize);
        for row in mapped.chunks_exact(pitch as usize) {
            rgba.extend_from_slice(&row[..self.config.width as usize * 4]);
        }
        drop(mapped);
        buffer.unmap();
        let bgra = matches!(
            self.config.format,
            TextureFormat::Bgra8Unorm | TextureFormat::Bgra8UnormSrgb
        );
        for pixel in rgba.as_chunks_mut::<4>().0 {
            if bgra {
                pixel.swap(0, 2);
            }
            pixel[3] = 255;
        }
        let mut png = Vec::new();
        image::codecs::png::PngEncoder::new(&mut png).write_image(
            &rgba,
            self.config.width,
            self.config.height,
            image::ExtendedColorType::Rgba8,
        )?;
        Ok(Capture {
            width: self.config.width,
            height: self.config.height,
            rgba,
            png,
        })
    }

    /// Reads the GPU's indirect instance counts once after a benchmark run.
    pub fn drawn_instances(&self) -> Result<u32> {
        if self.batches.is_empty() {
            return Ok(0);
        }
        let readback = self.request_drawn_instances()?;
        self.device.poll(wgpu::PollType::wait_indefinitely())?;
        self.poll_drawn_instances(&readback)?
            .context("GPU draw count did not complete")
    }

    /// Waits for completed GPU work; benchmark samples include submission and execution.
    pub fn finish_frame(&self) -> Result<()> {
        self.device.poll(wgpu::PollType::wait_indefinitely())?;
        if let Some(reason) = self.failed.lock().expect("mutex").take() {
            bail!("wgpu reported an error while drawing: {reason}");
        }
        Ok(())
    }

    /// The generation a new frame may reference; zero requests a complete upload.
    pub fn scene_revision(&self) -> u32 {
        if let Some(revision) = self.view_revision {
            return revision;
        }
        self.resident_scene
            .as_ref()
            .map_or(0, |scene| scene.revision)
    }

    /// Returns true when a frame was submitted, false when the surface skipped it.
    pub fn render(&mut self, bytes: &[u8]) -> Result<bool> {
        if bytes.starts_with(&views::MAGIC.to_ne_bytes()) {
            return self.render_views(bytes);
        }
        self.view_revision = None;
        if let Some(reason) = self.lost.lock().expect("mutex").take() {
            // Everything held belonged to a device that no longer exists, so it
            // is dropped rather than submitted to. A frame after this one
            // rebuilds from the packet, which carries the graph declaration
            // every time for exactly this reason.
            self.targets.clear();
            self.scratch = None;
            self.resident_scene = None;
            self.images.clear();
            self.bind_groups.clear();
            self.graph_revision = None;
            bail!("the wgpu device was lost: {reason}");
        }

        let mut batches = std::mem::take(&mut self.batches);
        let outcome = self.render_inner(bytes, &mut batches);
        self.batches = batches;
        let submitted = outcome?;

        if let Some(reason) = self.failed.lock().expect("mutex").take() {
            bail!("wgpu reported an error while drawing: {reason}");
        }
        Ok(submitted)
    }

    fn render_inner(&mut self, bytes: &[u8], batches: &mut Vec<Batch>) -> Result<bool> {
        let packet = parse_frame(
            bytes,
            batches,
            self.pack.material_count(),
            self.resident_scene.as_ref(),
        )?;
        if !packet.frame_table.is_empty() {
            if packet.frame_table.len() as u64
                > self.device.limits().max_storage_buffer_binding_size
            {
                bail!("animation table exceeds adapter capacity");
            }
            if packet.frame_table.len() as u64 > self.frame_table.size() {
                self.frame_table = self.device.create_buffer(&BufferDescriptor {
                    label: Some("sprite frame table"),
                    size: (packet.frame_table.len() as u64).next_power_of_two(),
                    usage: BufferUsages::STORAGE | BufferUsages::COPY_DST,
                    mapped_at_creation: false,
                });
                self.bind_groups.clear();
                if let Some(scratch) = &mut self.scratch {
                    scratch.cull_group = rebind_cull(
                        &self.device,
                        &self.layouts.cull,
                        scratch,
                        &self.lights,
                        &self.frame_table,
                    );
                }
            }
            self.queue
                .write_buffer(&self.frame_table, 0, packet.frame_table);
        }
        let header = packet.header;
        validate_instance_capacity(packet.instance_count, &self.device.limits())?;

        if self.graph_revision != Some(header.graph_revision)
            || self.pipeline_format != Some(self.config.format)
        {
            let graph = parse_graph(packet.graph)?;
            let rebuild = self.pipeline_format != Some(self.config.format)
                || self
                    .graph
                    .as_ref()
                    .is_none_or(|held| !held.same_pipelines(&graph));
            if rebuild {
                self.graph_generation += 1;
                self.bound_generation = 0;
                self.passes = build_passes(
                    &self.device,
                    &self.layouts,
                    &self.instance_module,
                    &self.cast_module,
                    &graph,
                    self.config.format,
                )?;
            } else {
                for (runtime, spec) in self.passes.iter().zip(graph.passes()) {
                    if let Some((buffer, _)) = &runtime.parameters {
                        self.queue
                            .write_buffer(buffer, 0, bytemuck::cast_slice(&spec.parameters));
                    }
                }
            }
            self.graph = Some(graph);
            self.graph_revision = Some(header.graph_revision);
            self.pipeline_format = Some(self.config.format);
        }
        let graph = self
            .graph
            .take()
            .expect("a graph is built before the first frame is drawn");
        let outcome = self.draw(&graph, &packet, batches);
        self.graph = Some(graph);
        if outcome.is_ok() {
            if packet.delta {
                let scene = self.resident_scene.as_mut().expect("validated delta");
                for update in &packet.updates {
                    let first = update.offset as usize / INSTANCE_STRIDE;
                    scene.flags[first..first + update.flags.len()].copy_from_slice(&update.flags);
                }
                scene.revision = packet.scene_revision;
                scene.casters = packet.caster_count;
            } else if !packet.retained {
                self.resident_scene = Some(RetainedScene {
                    tile_count: packet.tile_count,
                    revision: packet.scene_revision,
                    instances: packet.instance_count,
                    casters: packet.caster_count,
                    batches: batches.clone(),
                    flags: packet
                        .updates
                        .first()
                        .map_or_else(Vec::new, |update| update.flags.clone()),
                });
            }
        }
        outcome
    }

    /// Draws one shadow mode over every batch's run of the cast list.
    ///
    /// A batch's casters are a contiguous run of the shadow lane for the same
    /// reason its drawn instances are a contiguous run of its own lane, so each
    /// batch binds its own image and draws only its entries, and a caster's
    /// silhouette is cut by the artwork it draws with.
    fn cast_draw(
        &self,
        pass: &mut wgpu::RenderPass<'_>,
        pipeline: &RenderPipeline,
        scratch: &Scratch,
        batches: &[Batch],
        mode: u32,
    ) {
        pass.set_pipeline(pipeline);
        pass.set_bind_group(0, &self.scene_bind_group, &[]);
        for (slot, batch) in batches.iter().enumerate() {
            let image = self
                .bind_groups
                .get(&(batch.image, batch.sampler))
                .expect("resolved before the encoder");
            pass.set_bind_group(1, image, &[]);
            pass.set_bind_group(
                2,
                &scratch.cast_group,
                &[
                    slot as u32 * scratch.batch_stride,
                    mode * scratch.mode_stride,
                ],
            );
            // The shadow lane's arguments follow the drawing lanes' in the
            // same buffer, one set per batch each.
            pass.draw_indirect(
                &scratch.draw_args,
                (batches.len() as u64 + slot as u64) * DRAW_ARGS_WORDS * 4,
            );
        }
    }

    fn draw(
        &mut self,
        graph: &Graph,
        packet: &crate::packet::Packet<'_>,
        batches: &[Batch],
    ) -> Result<bool> {
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

        let header = packet.header;
        let shadows = header.shadows();
        let bloom = header.bloom_enabled();
        let view = header.world_view();
        self.queue.write_buffer(
            &self.scene_buffer,
            0,
            bytemuck::cast_slice(&header.scene(packet.light_count)),
        );
        if !packet.light_bytes.is_empty() {
            self.queue.write_buffer(&self.lights, 0, packet.light_bytes);
        }
        // The same rectangle the resolve maps its fragments into, because a grid
        // the two passes disagree about puts a light in a tile nothing looks in.
        let bin: [u32; 8] = [
            view[0].to_bits(),
            view[1].to_bits(),
            view[2].to_bits(),
            view[3].to_bits(),
            packet.light_count,
            0,
            0,
            0,
        ];
        self.queue
            .write_buffer(&self.bin_uniform, 0, bytemuck::cast_slice(&bin));

        let tile_size = u64::from(packet.tile_count.max(1).next_power_of_two())
            * super::packet::TILE_STRIDE as u64;
        if tile_size > self.device.limits().max_storage_buffer_binding_size {
            bail!("tile grids exceed adapter capacity");
        }
        if tile_size > self.tile_chunks.size() {
            if packet.delta || packet.retained {
                bail!("partial frame cannot grow tile storage");
            }
            self.tile_chunks = self.device.create_buffer(&BufferDescriptor {
                label: Some("tecs tile grids"),
                size: tile_size,
                usage: BufferUsages::STORAGE | BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
            self.bind_groups.clear();
        }
        for (slot, data) in &packet.tile_updates {
            self.queue.write_buffer(
                &self.tile_chunks,
                u64::from(*slot) * super::packet::TILE_STRIDE as u64,
                data,
            );
        }
        let mut particle_id = None;
        if !packet.particles.is_empty() {
            let data = particles::parse(packet.particles)?;
            if !self.rendering_view {
                self.particle_pools.retain(|id, _| *id == data.id);
            }
            if data.emitters.is_empty() {
                self.particle_pools.remove(&data.id);
            } else {
                particle_id = Some(data.id);
                if !self.particle_pools.contains_key(&data.id) {
                    let size = u64::from(data.capacity) * INSTANCE_STRIDE as u64;
                    if size > self.device.limits().max_storage_buffer_binding_size
                        || size > self.device.limits().max_buffer_size
                    {
                        bail!("particle pool exceeds adapter storage limit");
                    }
                    let held = self.scratch.take();
                    self.ensure_scratch(data.capacity, data.maximum, 0);
                    let scratch = self.scratch.take().expect("particle scratch");
                    self.scratch = held;
                    let pool = particles::Pool::new(&self.device, &data, scratch)?;
                    self.particle_pools.insert(data.id, pool);
                }
                let pool = self.particle_pools.get_mut(&data.id).unwrap();
                pool.update(&self.queue, &data)?;
                pool.bind_frame_table(
                    &self.device,
                    &self.layouts.cull,
                    &self.lights,
                    &self.frame_table,
                );
                pool.prepare_cull(&self.queue, &header);
                let images: Vec<_> = pool
                    .batches
                    .iter()
                    .map(|batch| (batch.image, batch.sampler))
                    .collect();
                for (image, sampler) in images {
                    self.image_bind_group(image, sampler);
                }
            }
        } else if !self.rendering_view {
            self.particle_pools.clear();
        }
        self.particle_pool = particle_id;
        self.ensure_scratch(
            packet.instance_count,
            batches.len() as u32,
            packet.caster_count,
        );
        let scratch = self.scratch.as_ref().expect("just ensured");
        for update in &packet.updates {
            self.queue
                .write_buffer(&scratch.instances, update.offset, update.bytes);
        }
        if !packet.retained && !packet.delta && !packet.batch_bytes.is_empty() {
            self.queue
                .write_buffer(&scratch.batches, 0, packet.batch_bytes);
        }
        let blocks = packet.instance_count.div_ceil(WORKGROUP);
        // argsMain resets shadow draw counts to zero when the lane is off;
        // stale cast-list entries are therefore unreachable without expansion.
        let cast_capacity = if shadows { scratch.cast_capacity } else { 0 };
        let uniform: [u32; 16] = [
            view[0].to_bits(),
            view[1].to_bits(),
            view[2].to_bits(),
            view[3].to_bits(),
            packet.instance_count,
            blocks,
            scratch.instance_capacity,
            batches.len() as u32,
            packet.light_count,
            cast_capacity,
            cast_list_offset(scratch.instance_capacity),
            cast_base_offset(scratch.batch_capacity),
            header.shadow_margin.to_bits(),
            0,
            0,
            0,
        ];
        self.queue
            .write_buffer(&scratch.cull_uniform, 0, bytemuck::cast_slice(&uniform));

        // Resolved before the encoder borrows self, because creating an image
        // bind group on demand needs the device this method also lends out.
        for batch in batches {
            let _ = self.image_bind_group(batch.image, batch.sampler);
        }

        let (frame, reconfigure) = if let Some(surface) = &self.surface {
            match surface.get_current_texture() {
                CurrentSurfaceTexture::Success(frame) => (Some(frame), false),
                CurrentSurfaceTexture::Suboptimal(frame) => (Some(frame), true),
                CurrentSurfaceTexture::Timeout | CurrentSurfaceTexture::Occluded => {
                    return Ok(false)
                }
                CurrentSurfaceTexture::Outdated | CurrentSurfaceTexture::Lost => {
                    // Both mean the surface no longer matches the window. Rebuilt
                    // here and drawn next frame, which is one dropped frame rather
                    // than a dead window.
                    if let Some(surface) = &self.surface {
                        surface.configure(&self.device, &self.config);
                    }
                    return Ok(false);
                }
                CurrentSurfaceTexture::Validation => {
                    bail!("wgpu rejected presentation surface acquisition")
                }
            }
        } else {
            (None, false)
        };
        let swapchain = match &frame {
            Some(frame) => frame.texture.create_view(&TextureViewDescriptor::default()),
            None => self
                .offscreen
                .as_ref()
                .expect("offscreen output")
                .create_view(&TextureViewDescriptor::default()),
        };
        let mut encoder = self
            .device
            .create_command_encoder(&CommandEncoderDescriptor {
                label: Some("tecs frame encoder"),
            });

        if let Some(id) = particle_id {
            self.particle_pools
                .get_mut(&id)
                .unwrap()
                .dispatch(&mut encoder, &self.cull_pipelines);
        }
        let scratch = self.scratch.as_ref().expect("ensured above");
        {
            // Dispatched every frame, including one with no lights at all. It is
            // the only thing that writes the tile counts, so skipping it would
            // leave the previous frame's lists standing and light a scene by
            // lights that are gone.
            let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor {
                label: Some("tecs light bin"),
                timestamp_writes: None,
            });
            pass.set_bind_group(0, &self.bin_group, &[]);
            pass.set_pipeline(&self.bin_pipeline);
            pass.dispatch_workgroups(LIGHT_TILE_COUNT.div_ceil(BIN_WORKGROUP), 1, 1);
        }
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
            // and turns it into one indirect draw per batch, for the drawing
            // lanes and the shadow lane both.
            pass.set_pipeline(&self.cull_pipelines[3]);
            pass.dispatch_workgroups((batches.len() as u32).div_ceil(ARGS_WORKGROUP), 1, 1);
            // Like the original SpriteBackend, expand the shadow lane only
            // when this frame actually draws casters. argsMain still resets
            // its indirect counts when the previous frame had shadows.
            if shadows && packet.caster_count > 0 {
                pass.set_pipeline(&self.cull_pipelines[4]);
                pass.dispatch_workgroups(blocks, 1, 1);
            }
        }

        for (index, spec) in graph.passes().iter().enumerate() {
            // A pass whose lane the frame turned off is skipped entirely rather
            // than begun and left empty, so a game with no shadows and no bloom
            // pays nothing at all for their being declared.
            if !self.passes[index].gate.open(shadows, bloom) {
                continue;
            }
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
                        load: if self.rendering_view {
                            LoadOp::Clear(Color::TRANSPARENT)
                        } else {
                            load_op(spec.clear, None)
                        },
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
                Body::Fullscreen | Body::Lighting => {
                    let pipeline = runtime
                        .pipeline
                        .as_ref()
                        .expect("a fullscreen pass has one");
                    pass.set_pipeline(pipeline);
                    pass.set_bind_group(0, &self.scene_bind_group, &[]);
                    if let Some(inputs) = runtime.inputs.as_ref() {
                        pass.set_bind_group(1, inputs, &[]);
                    }
                    if matches!(runtime.body, Body::Lighting) {
                        pass.set_bind_group(2, &self.lighting_group, &[]);
                    }
                    if (spec.name == "composite" || spec.name == "bloomExtract")
                        && spec.shader.is_none()
                    {
                        pass.set_bind_group(
                            2,
                            self.mesh_source
                                .as_ref()
                                .map_or(&self.mesh_fallback, |(_, group)| group),
                            &[],
                        );
                    }
                    if let Some((_, group)) = &runtime.parameters {
                        pass.set_bind_group(2, group, &[]);
                    }
                    pass.draw(0..3, 0..1);
                }
                Body::Occluders => {
                    if packet.instance_count == 0 {
                        continue;
                    }
                    let pipeline = runtime.pipeline.as_ref().expect("the mask draw has one");
                    self.cast_draw(&mut pass, pipeline, scratch, batches, CAST_MODE_MASK);
                }
                Body::DropShadows => {
                    if packet.instance_count == 0 {
                        continue;
                    }
                    let stretched = runtime.pipeline.as_ref().expect("the shadow draw has one");
                    self.cast_draw(&mut pass, stretched, scratch, batches, CAST_MODE_SHADOW);
                    // The stamp goes second and takes the maximum, which is what
                    // puts a caster back at full brightness over the shadow it
                    // threw across its own feet.
                    let stamp = runtime.second.as_ref().expect("the stamp draw has one");
                    self.cast_draw(&mut pass, stamp, scratch, batches, CAST_MODE_STAMP);
                }
                Body::Instanced { lane } => {
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
                    if let Some(id) = particle_id {
                        let pool = &self.particle_pools[&id];
                        for (slot, batch) in pool.batches.iter().enumerate() {
                            if batch.lane != lane {
                                continue;
                            }
                            pass.set_bind_group(
                                1,
                                self.bind_groups
                                    .get(&(batch.image, batch.sampler))
                                    .expect("particle image"),
                                &[],
                            );
                            pass.set_bind_group(
                                2,
                                &pool.scratch.draw_group,
                                &[slot as u32 * pool.scratch.batch_stride],
                            );
                            pass.draw_indirect(
                                &pool.scratch.draw_args,
                                slot as u64 * DRAW_ARGS_WORDS * 4,
                            );
                        }
                    }
                }
            }
        }

        let capture_buffer = if self.capture_requested {
            self.capture_requested = false;
            let texture = frame
                .as_ref()
                .map(|frame| &frame.texture)
                .or(self.offscreen.as_ref())
                .expect("frame output");
            if !texture.usage().contains(TextureUsages::COPY_SRC) {
                self.captured = Some(Err(anyhow::anyhow!(
                    "this surface does not support screenshot readback"
                )));
                None
            } else {
                let pitch = (self.config.width * 4).div_ceil(256) * 256;
                let buffer = self.device.create_buffer(&BufferDescriptor {
                    label: Some("tecs screenshot"),
                    size: u64::from(pitch) * u64::from(self.config.height),
                    usage: BufferUsages::COPY_DST | BufferUsages::MAP_READ,
                    mapped_at_creation: false,
                });
                encoder.copy_texture_to_buffer(
                    TexelCopyTextureInfo {
                        texture,
                        mip_level: 0,
                        origin: Origin3d::ZERO,
                        aspect: TextureAspect::All,
                    },
                    wgpu::TexelCopyBufferInfo {
                        buffer: &buffer,
                        layout: TexelCopyBufferLayout {
                            offset: 0,
                            bytes_per_row: Some(pitch),
                            rows_per_image: Some(self.config.height),
                        },
                    },
                    texture.size(),
                );
                Some((buffer, pitch))
            }
        } else {
            None
        };
        self.queue.submit([encoder.finish()]);
        if let Some((buffer, pitch)) = capture_buffer {
            self.captured = Some(self.read_capture(&buffer, pitch));
        }
        if let Some(frame) = frame {
            self.queue.present(frame);
        }
        if reconfigure {
            if let Some(surface) = &self.surface {
                surface.configure(&self.device, &self.config);
            }
        }
        Ok(true)
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
    cast_module: &ShaderModule,
    graph: &Graph,
    surface_format: TextureFormat,
) -> Result<Vec<PassRuntime>> {
    let mut passes = Vec::with_capacity(graph.passes().len());
    for pass in graph.passes() {
        let body = if pass.shader.is_some() {
            Body::Fullscreen
        } else {
            body_for(&pass.name)
        };
        let gate = if pass.shader.is_some() {
            Gate::Always
        } else {
            gate_for(&pass.name)
        };
        let color_formats: Vec<TextureFormat> = if pass.outputs.is_empty() {
            vec![surface_format]
        } else {
            pass.outputs
                .iter()
                .map(|index| texture_format(graph.targets()[*index].format))
                .collect()
        };
        let depth = depth_state(pass.depth);

        let mut parameters = None;
        let mut second: Option<RenderPipeline> = None;
        let (pipeline, input_layout) = match body {
            Body::Empty => (None, None),
            Body::Occluders | Body::DropShadows => {
                let layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
                    label: Some("tecs cast pipeline layout"),
                    bind_group_layouts: &[
                        Some(&layouts.scene),
                        Some(&layouts.image),
                        Some(&layouts.cast),
                    ],
                    immediate_size: 0,
                });
                // The blend is what resolves overlap between casters: a maximum
                // for the mask, so the tallest occluder wins, and a minimum for
                // the stretched copies, so the darkest does. Neither is order
                // dependent, which is what lets the shadow draws ignore the
                // sorting the drawing lanes need.
                let first_blend = if matches!(body, Body::Occluders) {
                    channel_blend(BlendOperation::Max)
                } else {
                    channel_blend(BlendOperation::Min)
                };
                let pipeline = cast_pipeline(
                    device,
                    cast_module,
                    &layout,
                    &pass.name,
                    &color_formats,
                    first_blend,
                );
                if matches!(body, Body::DropShadows) {
                    second = Some(cast_pipeline(
                        device,
                        cast_module,
                        &layout,
                        "dropShadowStamp",
                        &color_formats,
                        channel_blend(BlendOperation::Max),
                    ));
                }
                (Some(pipeline), None)
            }
            Body::Instanced { lane } => {
                let entry = if lane == LANE_OPAQUE {
                    "geometryMain"
                } else {
                    "forwardMain"
                };
                let blend = if lane == LANE_OPAQUE {
                    None
                } else {
                    Some(BlendState::PREMULTIPLIED_ALPHA_BLENDING)
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
            Body::Fullscreen | Body::Lighting => {
                let mesh_composite = (pass.name == "composite" || pass.name == "bloomExtract")
                    && pass.shader.is_none();
                let composite_source = if mesh_composite {
                    let source = if pass.name == "composite" {
                        COMPOSITE_WGSL.replace("return vec4<f32>(lit.rgb * lit.a + bloom, lit.a);", "let background = textureSample(meshColor, meshSampler, input.uv); let alpha = lit.a + background.a * (1.0 - lit.a); return vec4<f32>(lit.rgb * lit.a + bloom + background.rgb * (1.0 - lit.a), alpha);")
                    } else {
                        POSTPROCESS_WGSL.replace("let color = textureSample(input0, passSampler, input.uv).rgb;", "let foreground = textureSample(input0, passSampler, input.uv); let background = textureSample(meshColor, meshSampler, input.uv); let color = foreground.rgb * foreground.a + background.rgb * (1.0 - foreground.a);")
                    };
                    Some(format!("@group(2) @binding(0) var meshSampler: sampler;\n@group(2) @binding(1) var meshColor: texture_2d<f32>;\n{source}"))
                } else {
                    None
                };
                let custom = pass.shader.as_ref().map(|source| format!("struct Parameters {{ values: array<vec4<f32>, 4>, }}\n@group(2) @binding(0) var<uniform> params: Parameters;\n{source}\n@fragment fn customMain(input: FullscreenOutput) -> @location(0) vec4<f32> {{ return postprocess(input.uv); }}"));
                let entry = if let Some(source) = composite_source.as_deref() {
                    (
                        if pass.name == "composite" {
                            "compositeMain"
                        } else {
                            "bloomExtractMain"
                        },
                        source,
                        None,
                    )
                } else if let Some(source) = custom.as_deref() {
                    (
                        "customMain",
                        source,
                        pass.outputs
                            .is_empty()
                            .then_some(BlendState::PREMULTIPLIED_ALPHA_BLENDING),
                    )
                } else {
                    fullscreen_entry(&pass.name)
                        .with_context(|| format!("pass '{}' has no fullscreen body", pass.name))?
                };
                let module = device.create_shader_module(ShaderModuleDescriptor {
                    label: Some(pass.name.as_str()),
                    source: ShaderSource::Wgsl(Cow::Owned(fullscreen_source_typed(
                        entry.1,
                        &pass.inputs,
                    ))),
                });
                let input_layout = input_layout(device, &pass.inputs);
                let parameter_layout =
                    device.create_bind_group_layout(&BindGroupLayoutDescriptor {
                        label: Some("post-process parameters"),
                        entries: &[BindGroupLayoutEntry {
                            binding: 0,
                            visibility: ShaderStages::FRAGMENT,
                            ty: BindingType::Buffer {
                                ty: BufferBindingType::Uniform,
                                has_dynamic_offset: false,
                                min_binding_size: None,
                            },
                            count: None,
                        }],
                    });
                let mut groups = vec![Some(&layouts.scene), Some(&input_layout)];
                if mesh_composite {
                    groups.push(Some(&layouts.mesh_composite));
                }
                if custom.is_some() {
                    let buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                        label: Some("post-process parameters"),
                        contents: bytemuck::cast_slice(&pass.parameters),
                        usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
                    });
                    let group = device.create_bind_group(&BindGroupDescriptor {
                        label: Some("post-process parameters"),
                        layout: &parameter_layout,
                        entries: &[BindGroupEntry {
                            binding: 0,
                            resource: buffer.as_entire_binding(),
                        }],
                    });
                    parameters = Some((buffer, group));
                    groups.push(Some(&parameter_layout));
                }
                if matches!(body, Body::Lighting) {
                    groups.push(Some(&layouts.lighting));
                }
                let layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
                    label: Some("tecs fullscreen pipeline layout"),
                    bind_group_layouts: &groups,
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
            parameters,
            body,
            gate,
            pipeline,
            second,
            inputs: None,
            input_layout,
        });
    }
    Ok(passes)
}

/// Builds one of the three shadow draws.
fn cast_pipeline(
    device: &Device,
    module: &ShaderModule,
    layout: &wgpu::PipelineLayout,
    label: &str,
    formats: &[TextureFormat],
    blend: BlendState,
) -> RenderPipeline {
    let targets: Vec<Option<ColorTargetState>> = formats
        .iter()
        .map(|format| {
            Some(ColorTargetState {
                format: *format,
                blend: Some(blend),
                write_mask: ColorWrites::ALL,
            })
        })
        .collect();
    device.create_render_pipeline(&RenderPipelineDescriptor {
        label: Some(label),
        layout: Some(layout),
        vertex: VertexState {
            module,
            entry_point: Some("castVertexMain"),
            compilation_options: PipelineCompilationOptions::default(),
            buffers: &[],
        },
        fragment: Some(FragmentState {
            module,
            entry_point: Some("castFragmentMain"),
            compilation_options: PipelineCompilationOptions::default(),
            targets: &targets,
        }),
        primitive: Default::default(),
        // Nothing in the shadow lane tests depth. An occluder blocks light in
        // the world rather than standing in front of something.
        depth_stencil: None,
        multisample: Default::default(),
        multiview_mask: None,
        cache: None,
    })
}

/// A blend that folds a fragment into what is already there by one operation on
/// every channel, which is what makes the shadow draws order independent.
fn channel_blend(operation: BlendOperation) -> BlendState {
    let component = BlendComponent {
        src_factor: BlendFactor::One,
        dst_factor: BlendFactor::One,
        operation,
    };
    BlendState {
        color: component,
        alpha: component,
    }
}

/// Builds the layout a fullscreen pass with `count` declared inputs binds.
fn input_layout(device: &Device, inputs: &[Input]) -> BindGroupLayout {
    let mut entries = vec![BindGroupLayoutEntry {
        binding: 0,
        visibility: ShaderStages::FRAGMENT,
        ty: BindingType::Sampler(SamplerBindingType::NonFiltering),
        count: None,
    }];
    for (index, input) in inputs.iter().enumerate() {
        entries.push(BindGroupLayoutEntry {
            binding: index as u32 + 1,
            visibility: ShaderStages::FRAGMENT,
            ty: BindingType::Texture {
                sample_type: if *input == Input::Depth {
                    TextureSampleType::Depth
                } else {
                    TextureSampleType::Float { filterable: false }
                },
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
    format!(
        "{MATERIAL_WGSL}\n{}\n{INSTANCE_WGSL}\n{TILECHUNK_WGSL}\n{FRAMETABLE_WGSL}",
        pack.dispatch()
    )
}

/// The module the three shadow draws go through.
///
/// The same material contract and the same assembled dispatch as the drawing
/// lanes, because a caster's silhouette is the coverage its own material
/// decided: a circle, a rounded box or a glyph casts for nothing, and a caster
/// needs no alpha threshold of its own.
pub fn cast_source(pack: &ShaderPack) -> String {
    format!(
        "{MATERIAL_WGSL}\n{}\n{CAST_WGSL}\n{TILECHUNK_WGSL}\n{FRAMETABLE_WGSL}",
        pack.dispatch()
    )
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
        "lighting" => Body::Lighting,
        "occluders" => Body::Occluders,
        "dropShadowAO" => Body::DropShadows,
        "occluderBlurH" | "occluderBlurV" | "bloomExtract" | "bloomBlurX" | "bloomBlurY"
        | "composite" | "present" => Body::Fullscreen,
        _ => Body::Empty,
    }
}

/// Returns what a frame has to have turned on for a pass of a given name to run.
///
/// Only the passes the engine declares are gated. A pass a game adds runs every
/// frame, because nothing here knows what would make it unnecessary.
fn gate_for(name: &str) -> Gate {
    match name {
        "occluders" | "occluderBlurH" | "occluderBlurV" | "dropShadowAO" => Gate::Shadows,
        "bloomExtract" | "bloomBlurX" | "bloomBlurY" => Gate::Bloom,
        _ => Gate::Always,
    }
}

/// The entry point, source and blend of each fullscreen pass this backend
/// implements.
fn fullscreen_entry(name: &str) -> Option<(&'static str, &'static str, Option<BlendState>)> {
    match name {
        "lighting" => Some(("lightingMain", LIGHTING_WGSL, None)),
        "occluderBlurH" => Some(("occluderBlurXMain", POSTPROCESS_WGSL, None)),
        "occluderBlurV" => Some(("occluderBlurYMain", POSTPROCESS_WGSL, None)),
        "bloomExtract" => Some(("bloomExtractMain", POSTPROCESS_WGSL, None)),
        "bloomBlurX" => Some(("bloomBlurXMain", POSTPROCESS_WGSL, None)),
        "bloomBlurY" => Some(("bloomBlurYMain", POSTPROCESS_WGSL, None)),
        "composite" => Some(("compositeMain", COMPOSITE_WGSL, None)),
        // The scene is blended over the clear this pass declares, so a pixel
        // nothing drew shows the window's background.
        "present" => Some((
            "presentMain",
            PRESENT_WGSL,
            Some(BlendState::PREMULTIPLIED_ALPHA_BLENDING),
        )),
        _ => None,
    }
}

/// Builds a fullscreen pass's module with exactly the input bindings its
/// pipeline layout provides.
fn fullscreen_source_typed(fragment: &str, inputs: &[Input]) -> String {
    let mut source = fullscreen_source(fragment, inputs.len());
    for (index, input) in inputs.iter().enumerate() {
        if *input == Input::Depth {
            source = source.replace(
                &format!("var input{index}: texture_2d<f32>"),
                &format!("var input{index}: texture_depth_2d"),
            );
        }
    }
    source
}

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

fn fragment_storage_entry(binding: u32) -> BindGroupLayoutEntry {
    BindGroupLayoutEntry {
        binding,
        visibility: ShaderStages::FRAGMENT,
        ty: BindingType::Buffer {
            ty: BufferBindingType::Storage { read_only: true },
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    }
}

fn dynamic_uniform_entry(binding: u32, visibility: ShaderStages) -> BindGroupLayoutEntry {
    BindGroupLayoutEntry {
        binding,
        visibility,
        ty: BindingType::Buffer {
            ty: BufferBindingType::Uniform,
            has_dynamic_offset: true,
            min_binding_size: std::num::NonZeroU64::new(4),
        },
        count: None,
    }
}

/// Rejects a scene whose rounded instance buffer exceeds the device's limits.
fn validate_instance_capacity(count: u32, limits: &wgpu::Limits) -> Result<()> {
    let required = u64::from(capacity(count.max(1))) * INSTANCE_STRIDE as u64;
    let limit = limits
        .max_storage_buffer_binding_size
        .min(limits.max_buffer_size);
    if required > limit {
        bail!("{count} instances need a {required} byte GPU buffer; this adapter allows {limit} bytes");
    }
    Ok(())
}

/// Rounds a count up to the next power of two, so a scene that oscillates in
/// size does not reallocate every frame.
fn capacity(count: u32) -> u32 {
    count.next_power_of_two()
}

/// The storage binding offset alignment WebGPU guarantees, in words.
///
/// The shadow lane's list and its bases are bound as offsets into buffers the
/// drawing lanes already hold, and a bound offset has to land on this.
const BINDING_ALIGNMENT_WORDS: u32 = 64;

fn align_words(words: u32) -> u32 {
    words.div_ceil(BINDING_ALIGNMENT_WORDS) * BINDING_ALIGNMENT_WORDS
}

/// The word the cast list begins at inside the visible buffer.
fn cast_list_offset(instance_capacity: u32) -> u32 {
    align_words(instance_capacity * LANE_COUNT)
}

/// The word the shadow lane's bases begin at inside the batch bases.
fn cast_base_offset(batch_capacity: u32) -> u32 {
    align_words(batch_capacity)
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
        view_formats: &[TextureFormat::Rgba8Unorm],
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

fn linear_view(view: &TextureView) -> TextureView {
    view.texture().create_view(&TextureViewDescriptor {
        format: Some(TextureFormat::Rgba8Unorm),
        ..Default::default()
    })
}

fn rebind_cull(
    device: &Device,
    layout: &BindGroupLayout,
    scratch: &Scratch,
    lights: &Buffer,
    frames: &Buffer,
) -> BindGroup {
    let buffers = [
        &scratch.instances,
        &scratch.batches,
        &scratch.slots,
        &scratch.block_counts,
        &scratch.visible,
        &scratch.draw_args,
        &scratch.batch_base,
        &scratch.cull_uniform,
        lights,
        frames,
    ];
    let entries: Vec<_> = buffers
        .into_iter()
        .enumerate()
        .map(|(binding, buffer)| BindGroupEntry {
            binding: binding as u32,
            resource: buffer.as_entire_binding(),
        })
        .collect();
    device.create_bind_group(&BindGroupDescriptor {
        label: Some("sprite cull"),
        layout,
        entries: &entries,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_gpu_instances_across_camera_frames_and_partial_uploads() {
        use crate::packet::tests::{delta, retained, PacketBuilder};
        let probe = Instance::new(InstanceDescriptor::new_without_display_handle());
        if pollster::block_on(probe.request_adapter(&wgpu::RequestAdapterOptions::default()))
            .is_err()
        {
            return;
        }
        let mut graphics = Graphics::offscreen(640, 360).expect("offscreen renderer");
        let mut fixture = PacketBuilder::new()
            .graph(crate::graph::tests::deferred())
            .instances(3, LANE_OPAQUE)
            .batch(0, 0, LANE_OPAQUE, 0, 3);
        fixture.counts[3] = 1;
        let full = fixture.build();
        assert!(graphics.render(&full).unwrap());
        graphics.finish_frame().unwrap();
        assert_eq!(graphics.drawn_instances().unwrap(), 3);
        let mut moved = retained(&full, 1);
        moved[48..52].copy_from_slice(&1000_f32.to_ne_bytes());
        graphics.render(&moved).unwrap();
        graphics.finish_frame().unwrap();
        assert_eq!(graphics.drawn_instances().unwrap(), 0);
        let mut instance = full[full.len() - INSTANCE_STRIDE..].to_vec();
        instance[0..4].copy_from_slice(&1000_f32.to_ne_bytes());
        let patch = delta(&full, 2, 1, 0, &instance);
        graphics.render(&patch).unwrap();
        graphics.finish_frame().unwrap();
        assert_eq!(graphics.drawn_instances().unwrap(), 2);
        graphics.render(&retained(&full, 2)).unwrap();
        graphics.finish_frame().unwrap();
        assert_eq!(graphics.drawn_instances().unwrap(), 2);
        assert_eq!(graphics.scene_revision(), 2);
    }

    #[test]
    fn sprite_frames_advance_on_gpu_without_instance_uploads() {
        use crate::packet::tests::{retained, PacketBuilder};
        let probe = Instance::new(InstanceDescriptor::new_without_display_handle());
        if pollster::block_on(probe.request_adapter(&wgpu::RequestAdapterOptions::default()))
            .is_err()
        {
            return;
        }
        let mut graphics = Graphics::offscreen(640, 360).unwrap();
        graphics
            .upload_image(1, 2, 1, &[255, 0, 0, 255, 0, 255, 0, 255])
            .unwrap();
        let mut fixture = PacketBuilder::new()
            .graph(crate::graph::tests::deferred())
            .instances(1, 0)
            .batch(1, 0, 0, 0, 1);
        for (i, v) in [
            320_f32, 180., 0., 0.5, 64., 64., 0., 0., -1., 0., 1., 1., 1., 1., 1., 1.,
        ]
        .into_iter()
        .enumerate()
        {
            fixture.instances[0][i] = v.to_bits();
        }
        fixture.counts[3] = 1;
        let full = fixture.build();
        // Two authored milliseconds, distinct UVs, shared by any number of rows.
        let table = [
            1_f32, 7., 5., 2., 2., 0., 1., 0., 0., 0.5, 1., 1., 0., 0., 0., 0.5, 0., 1., 1., 1.,
            0., 0., 0.,
        ];
        let packet = |original: &[u8], clock: f32, data: &[f32]| {
            let mut bytes = original[..128].to_vec();
            bytes[4..8].copy_from_slice(&8_u32.to_ne_bytes());
            bytes[8..12].copy_from_slice(&136_u32.to_ne_bytes());
            bytes.extend(clock.to_ne_bytes());
            bytes.extend(((data.len() * 4) as u32).to_ne_bytes());
            bytes.extend_from_slice(bytemuck::cast_slice(data));
            bytes.extend_from_slice(&original[128..]);
            bytes
        };
        graphics.request_capture();
        graphics.render(&packet(&full, 0., &table)).unwrap();
        let first = graphics.take_capture().unwrap();
        let at = (180 * 640 + 320) * 4;
        assert!(
            first.rgba[at] > 200 && first.rgba[at + 1] < 10,
            "first sprite frame is red"
        );
        let instances = graphics.scratch.as_ref().unwrap().instances.clone();
        let resident = retained(&full, 1);
        graphics.request_capture();
        graphics.render(&packet(&resident, 1., &[])).unwrap();
        let second = graphics.take_capture().unwrap();
        assert!(
            second.rgba[at + 1] > 200 && second.rgba[at] < 10,
            "retained sprite resolves green from new clock"
        );
        assert_eq!(instances, graphics.scratch.as_ref().unwrap().instances);
        // The anchor lies outside the camera, but the second frame's pivot
        // brings its quad back into view. Culling must cover every frame.
        let mut shifted = table;
        shifted[12] = 1.5;
        shifted[14] = 1.5;
        shifted[20] = 1.5;
        shifted[22] = 1.5;
        let mut outside = full.clone();
        let instance_offset = outside.len() - INSTANCE_STRIDE;
        outside[instance_offset..instance_offset + 4].copy_from_slice(&700_f32.to_ne_bytes());
        graphics.request_capture();
        graphics.render(&packet(&outside, 1., &shifted)).unwrap();
        let pivoted = graphics.take_capture().unwrap();
        let edge = (180 * 640 + 604) * 4;
        assert!(
            pivoted.rgba[edge + 1] > 200,
            "moving pivot survives GPU culling at the camera edge"
        );
        graphics.render(&packet(&full, 0., &table)).unwrap();
        graphics.request_capture();
        graphics.render(&packet(&resident, 2., &[])).unwrap();
        assert_eq!(
            first.rgba,
            graphics.take_capture().unwrap().rgba,
            "GPU wraps exactly at the authored cycle boundary"
        );
    }

    #[test]
    fn compact_tiles_match_quads_and_capture_exact_png_pixels() {
        use crate::packet::tests::PacketBuilder;
        let probe = Instance::new(InstanceDescriptor::new_without_display_handle());
        if pollster::block_on(probe.request_adapter(&wgpu::RequestAdapterOptions::default()))
            .is_err()
        {
            return;
        }
        let mut graphics = Graphics::offscreen(640, 360).unwrap();
        let mut pixels = vec![0_u8; 64 * 32 * 4];
        for y in 0..32 {
            for x in 0..64 {
                let i = (y * 64 + x) * 4;
                pixels[i..i + 4].copy_from_slice(&[
                    (x * 4) as u8,
                    (y * 8) as u8,
                    if x % 3 == 0 { 255 } else { 0 },
                    255,
                ]);
            }
        }
        graphics.upload_image(1, 64, 32, &pixels).unwrap();
        let fixture = |n| {
            PacketBuilder::new()
                .graph(crate::graph::tests::deferred())
                .instances(n, 0)
                .batch(1, 0, 0, 0, n)
        };
        let mut chunk = fixture(1);
        let mut tile = vec![0_u8; crate::packet::TILE_STRIDE];
        for (i, value) in [16_f32, 8., 3., 1., 2., 40., 20., 3., -2., 64., 32., 0.]
            .into_iter()
            .enumerate()
        {
            tile[i * 4..i * 4 + 4].copy_from_slice(&value.to_ne_bytes());
        }
        let mut quads = fixture(8);
        let c = 0.3_f32.cos();
        let s = 0.3_f32.sin();
        let base = &mut chunk.instances[0];
        for (i, v) in [
            10_f32, 20., 0.3, 0.5, 2., 3., 0.25, 0., 0., 3000., 0., 0., 1., 1., 1., 1.,
        ]
        .into_iter()
        .enumerate()
        {
            base[i] = v.to_bits();
        }
        base[17] = 16;
        for flags in 0..8_u32 {
            let h = flags & 1 != 0;
            let v = flags & 2 != 0;
            let d = flags & 4 != 0;
            let encoded: u32 = 2
                | if h { 0x80000000 } else { 0 }
                | if v { 0x40000000 } else { 0 }
                | if d { 0x20000000 } else { 0 };
            let offset = 48 + flags as usize * 4;
            tile[offset..offset + 4].copy_from_slice(&encoded.to_ne_bytes());
            let x = flags as f32 * 40. + 11.;
            let y = 14.;
            let mut sx = 32_f32;
            let mut sy = 24_f32;
            let mut angle = 0.3;
            if d {
                angle += std::f32::consts::FRAC_PI_2;
                sy *= if h { 1. } else { -1. };
                sx *= if v { -1. } else { 1. };
            } else {
                sx *= if h { -1. } else { 1. };
                sy *= if v { -1. } else { 1. };
            }
            let quad = &mut quads.instances[flags as usize];
            for (i, value) in [
                10. + x * 2. * c - y * 3. * s,
                20. + x * 2. * s + y * 3. * c,
                angle,
                0.5,
                sx,
                sy,
                0.25,
                0.,
                19. / 64.,
                2. / 32.,
                35. / 64.,
                10. / 32.,
                1.,
                1.,
                1.,
                1.,
            ]
            .into_iter()
            .enumerate()
            {
                quad[i] = value.to_bits();
            }
        }
        chunk.tiles.push((0, tile));
        graphics.request_capture();
        graphics.render(&chunk.build()).unwrap();
        let compact = graphics.take_capture().unwrap();
        assert_eq!(graphics.drawn_instances().unwrap(), 1);
        graphics.request_capture();
        graphics.render(&quads.build()).unwrap();
        let expanded = graphics.take_capture().unwrap();
        assert_eq!(
            compact.rgba, expanded.rgba,
            "GPU chunk placement differs from individual quads"
        );
        let decoded = image::load_from_memory(&compact.png).unwrap().into_rgba8();
        assert_eq!(decoded.as_raw(), &compact.rgba);
        assert_eq!(decoded.dimensions(), (640, 360));
        assert!(compact
            .rgba
            .as_chunks::<4>()
            .0
            .iter()
            .all(|pixel| pixel[3] == 255));
        assert!(compact
            .rgba
            .as_chunks::<4>()
            .0
            .iter()
            .any(|pixel| pixel[0] != 0 || pixel[1] != 0));
    }

    #[test]
    fn material_maps_survive_replacement_and_release() {
        use crate::packet::tests::PacketBuilder;
        let probe = Instance::new(InstanceDescriptor::new_without_display_handle());
        if pollster::block_on(probe.request_adapter(&wgpu::RequestAdapterOptions::default()))
            .is_err()
        {
            return;
        }
        let mut graphics = Graphics::offscreen(641, 361).unwrap();
        graphics.upload_image(1, 1, 1, &[0, 0, 0, 255]).unwrap();
        graphics.upload_image(2, 1, 1, &[255, 0, 0, 255]).unwrap();
        graphics.set_material_maps(1, [0, 2, 0]).unwrap();
        let mut fixture = PacketBuilder::new()
            .graph(crate::graph::tests::deferred())
            .instances(1, 0)
            .batch(1, 0, 0, 0, 1);
        for (i, value) in [
            320_f32, 180., 0., 0.5, 100., 100., 0.25, 0., 0., 0., 1., 1., 1., 1., 1., 1.,
        ]
        .into_iter()
        .enumerate()
        {
            fixture.instances[0][i] = value.to_bits();
        }
        fixture.target = [641., 361.];
        let packet = fixture.build();
        let center = |graphics: &mut Graphics| {
            graphics.request_capture();
            graphics.render(&packet).unwrap();
            let image = graphics.take_capture().unwrap();
            image.rgba[(180 * 641 + 320) * 4..(180 * 641 + 320) * 4 + 4].to_vec()
        };
        let red = center(&mut graphics);
        assert!(red[0] > 200 && red[1] < 5);
        graphics.upload_image(2, 1, 1, &[0, 255, 0, 255]).unwrap();
        let green = center(&mut graphics);
        assert!(green[1] > 200 && green[0] < 5);
        graphics.release_image(2).unwrap();
        let dark = center(&mut graphics);
        assert_eq!(dark, [0, 0, 0, 255]);
        graphics.upload_image(3, 2, 1, &[255; 8]).unwrap();
        assert!(graphics.set_material_maps(1, [3, 0, 0]).is_err());
    }

    #[test]
    fn custom_postprocess_draws_and_updates_parameters_without_rebuilding() {
        use crate::packet::tests::PacketBuilder;
        let probe = Instance::new(InstanceDescriptor::new_without_display_handle());
        if pollster::block_on(probe.request_adapter(&wgpu::RequestAdapterOptions::default()))
            .is_err()
        {
            return;
        }
        let mut graphics = Graphics::offscreen(640, 360).unwrap();
        let source = "fn postprocess(uv: vec2<f32>) -> vec4<f32> { return params.values[0]; }";
        let mut generation = 0;
        for (revision, color) in [(1, [1., 0., 0., 1.]), (2, [0., 1., 0., 1.])] {
            let mut parameters = [0.; 16];
            parameters[..4].copy_from_slice(&color);
            let mut fixture = PacketBuilder::new().graph(crate::graph::tests::custom(
                crate::graph::tests::deferred(),
                11,
                source,
                parameters,
            ));
            fixture.header[4] = revision;
            graphics.request_capture();
            graphics.render(&fixture.build()).unwrap();
            let capture = graphics.take_capture().unwrap();
            assert_eq!(
                &capture.rgba[..4],
                if revision == 1 {
                    &[255, 0, 0, 255]
                } else {
                    &[0, 255, 0, 255]
                }
            );
            if revision == 1 {
                generation = graphics.graph_generation;
            } else {
                assert_eq!(generation, graphics.graph_generation);
            }
        }
    }

    #[test]
    fn benchmarks_never_fall_back_to_fifo() {
        use wgpu::PresentMode::{Fifo, Immediate, Mailbox};
        assert_eq!(
            benchmark_present_mode(&[Fifo, Mailbox, Immediate]).unwrap(),
            Immediate
        );
        assert_eq!(benchmark_present_mode(&[Fifo, Mailbox]).unwrap(), Mailbox);
        assert!(benchmark_present_mode(&[Fifo]).is_err());
    }

    #[test]
    fn full_entity_capacity_requires_explicit_gpu_limits() {
        let defaults = wgpu::Limits::default();
        assert!(validate_instance_capacity(4_194_303, &defaults).is_err());
        let supported = wgpu::Limits {
            max_storage_buffer_binding_size: 335_544_320,
            max_buffer_size: 335_544_320,
            ..defaults
        };
        assert!(validate_instance_capacity(4_194_303, &supported).is_ok());
        let too_small = wgpu::Limits {
            max_buffer_size: 335_544_319,
            ..supported
        };
        assert!(validate_instance_capacity(4_194_303, &too_small).is_err());
    }

    #[test]
    fn rounds_capacities_up_to_a_power_of_two() {
        assert_eq!(capacity(1), 1);
        assert_eq!(capacity(3), 4);
        assert_eq!(capacity(256), 256);
        assert_eq!(capacity(257), 512);
    }

    #[test]
    fn puts_the_shadow_lane_where_a_bind_group_can_reach_it() {
        // Every offset lands on the storage binding alignment WebGPU
        // guarantees, because the shadow draws bind the same buffers from there.
        for capacity in [1_u32, 3, 64, 100, 1024] {
            assert_eq!(cast_list_offset(capacity) % BINDING_ALIGNMENT_WORDS, 0);
            assert_eq!(cast_base_offset(capacity) % BINDING_ALIGNMENT_WORDS, 0);
            assert!(cast_list_offset(capacity) >= capacity * LANE_COUNT);
            assert!(cast_base_offset(capacity) >= capacity);
        }
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
        assert!(matches!(body_for("lighting"), Body::Lighting));
        assert!(matches!(body_for("occluders"), Body::Occluders));
        assert!(matches!(body_for("dropShadowAO"), Body::DropShadows));
        assert!(matches!(body_for("occluderBlurH"), Body::Fullscreen));
        assert!(matches!(body_for("bloomExtract"), Body::Fullscreen));
        assert!(matches!(body_for("composite"), Body::Fullscreen));
        assert!(matches!(body_for("present"), Body::Fullscreen));
        // A pass this backend has no body for still runs: it begins with its
        // attachments and its clears and draws nothing.
        assert!(matches!(body_for("game.overlay"), Body::Empty));
    }

    #[test]
    fn runs_a_gated_pass_only_where_its_lane_is_on() {
        assert_eq!(gate_for("occluders"), Gate::Shadows);
        assert_eq!(gate_for("occluderBlurV"), Gate::Shadows);
        assert_eq!(gate_for("dropShadowAO"), Gate::Shadows);
        assert_eq!(gate_for("bloomBlurY"), Gate::Bloom);
        assert_eq!(gate_for("lighting"), Gate::Always);
        // A pass a game adds runs every frame, because nothing here knows what
        // would make it unnecessary.
        assert_eq!(gate_for("game.overlay"), Gate::Always);

        assert!(Gate::Always.open(false, false));
        assert!(!Gate::Shadows.open(false, true));
        assert!(Gate::Shadows.open(true, false));
        assert!(!Gate::Bloom.open(true, false));
        assert!(Gate::Bloom.open(false, true));
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
