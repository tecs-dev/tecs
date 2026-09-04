use std::borrow::Cow;
use std::collections::HashMap;
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use wgpu::util::DeviceExt;
use wgpu::{
    AddressMode, BindGroup, BindGroupDescriptor, BindGroupEntry, BindGroupLayout,
    BindGroupLayoutDescriptor, BindGroupLayoutEntry, BindingResource, BindingType, BlendState,
    Buffer, BufferBindingType, BufferDescriptor, BufferUsages, Color, ColorTargetState,
    ColorWrites, CommandEncoderDescriptor, CurrentSurfaceTexture, Device, DeviceDescriptor,
    Extent3d, FilterMode, FragmentState, Instance, InstanceDescriptor, LoadOp, MipmapFilterMode,
    Operations, Origin3d, PipelineCompilationOptions, PipelineLayoutDescriptor, Queue,
    RenderPassColorAttachment, RenderPassDescriptor, RenderPipeline, RenderPipelineDescriptor,
    Sampler, SamplerBindingType, SamplerDescriptor, ShaderModuleDescriptor, ShaderSource,
    ShaderStages, StoreOp, Surface, SurfaceConfiguration, TexelCopyBufferLayout,
    TexelCopyTextureInfo, TextureAspect, TextureDescriptor, TextureDimension, TextureFormat,
    TextureSampleType, TextureUsages, TextureView, TextureViewDescriptor, TextureViewDimension,
    VertexBufferLayout, VertexState, VertexStepMode,
};
use winit::event_loop::OwnedDisplayHandle;
use winit::window::Window;

const PACKET_MAGIC: u32 = 0x5445_4353;
const PACKET_VERSION: u32 = 2;
const PACKET_HEADER_SIZE: usize = 56;
const BATCH_STRIDE: usize = 16;
const INSTANCE_STRIDE: usize = 56;

/// Every filter paired with every address mode, matching
/// `tecs.gfx.images.SAMPLER_COUNT` and its `address * 2 + filter` encoding.
const SAMPLER_COUNT: u32 = 6;

/// Four bytes per texel, which is the only layout an upload command declares.
const BYTES_PER_TEXEL: u32 = 4;

const SHADER: &str = r#"
struct Scene {
    viewport: vec2<f32>,
    camera: vec2<f32>,
    zoom: f32,
    rotation: f32,
}

@group(0) @binding(0)
var<uniform> scene: Scene;

@group(1) @binding(0)
var image: texture_2d<f32>;
@group(1) @binding(1)
var imageSampler: sampler;

struct InstanceInput {
    @location(0) position: vec2<f32>,
    @location(1) rotation: f32,
    @location(2) scale: vec2<f32>,
    @location(3) depth: f32,
    @location(4) uvRect: vec4<f32>,
    @location(5) tint: vec4<f32>,
}

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) tint: vec4<f32>,
    @location(1) uv: vec2<f32>,
}

@vertex
fn vertexMain(@builtin(vertex_index) vertexIndex: u32, instance: InstanceInput) -> VertexOutput {
    let corners = array<vec2<f32>, 6>(
        vec2(-0.5, -0.5), vec2(0.5, -0.5), vec2(-0.5, 0.5),
        vec2(-0.5, 0.5), vec2(0.5, -0.5), vec2(0.5, 0.5),
    );
    let corner = corners[vertexIndex];
    let local = corner * instance.scale;
    let sine = sin(instance.rotation);
    let cosine = cos(instance.rotation);
    let rotated = vec2(
        local.x * cosine - local.y * sine,
        local.x * sine + local.y * cosine,
    );
    let world = instance.position + rotated;

    // The world-to-clip matrix of `Camera2D.matrix`, applied without being
    // assembled. Y is negated once, here, because world y runs down; the
    // rotation is transposed so world offsets turn by minus the camera's
    // rotation and the negation above turns the scene back the other way.
    let sx = 2.0 * scene.zoom / scene.viewport.x;
    let sy = -2.0 * scene.zoom / scene.viewport.y;
    let c = cos(scene.rotation);
    let s = sin(scene.rotation);
    let m00 = sx * c;
    let m01 = sx * s;
    let m10 = -sy * s;
    let m11 = sy * c;
    let offset = world - scene.camera;
    let clip = vec2(
        m00 * offset.x + m01 * offset.y,
        m10 * offset.x + m11 * offset.y,
    );

    // The UV rectangle runs left to right and top to bottom, and the corner
    // at (-0.5, -0.5) is the top left one because world y runs down.
    let uvWeight = corner + vec2(0.5, 0.5);
    var output: VertexOutput;
    output.position = vec4(clip, instance.depth, 1.0);
    output.tint = instance.tint;
    output.uv = mix(instance.uvRect.xy, instance.uvRect.zw, uvWeight);
    return output;
}

@fragment
fn fragmentMain(input: VertexOutput) -> @location(0) vec4<f32> {
    return input.tint * textureSample(image, imageSampler, input.uv);
}
"#;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Batch {
    image: u32,
    sampler: u32,
    first: u32,
    count: u32,
}

#[derive(Debug)]
struct RenderPacket<'a> {
    /// Target width, target height, camera x, camera y, zoom, rotation, and two
    /// padding words, in the uniform's own order.
    scene: [f32; 8],
    batches: Vec<Batch>,
    instances: &'a [u8],
}

pub struct Graphics {
    surface: Surface<'static>,
    device: Device,
    queue: Queue,
    config: SurfaceConfiguration,
    pipeline: RenderPipeline,
    scene_buffer: Buffer,
    scene_bind_group: BindGroup,
    image_layout: BindGroupLayout,
    samplers: Vec<Sampler>,
    fallback: TextureView,
    images: HashMap<u32, TextureView>,
    bind_groups: HashMap<(u32, u32), BindGroup>,
    instance_buffer: Buffer,
    instance_capacity: usize,
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

        let scene = [1.0_f32, 1.0, 0.5, 0.5, 1.0, 0.0, 0.0, 0.0];
        let scene_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("tecs scene"),
            contents: bytemuck::cast_slice(&scene),
            usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
        });
        let scene_layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("tecs scene layout"),
            entries: &[BindGroupLayoutEntry {
                binding: 0,
                visibility: ShaderStages::VERTEX,
                ty: BindingType::Buffer {
                    ty: BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });
        let scene_bind_group = device.create_bind_group(&BindGroupDescriptor {
            label: Some("tecs scene bind group"),
            layout: &scene_layout,
            entries: &[BindGroupEntry {
                binding: 0,
                resource: scene_buffer.as_entire_binding(),
            }],
        });
        let image_layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
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
        let shader = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("tecs sprite shader"),
            source: ShaderSource::Wgsl(Cow::Borrowed(SHADER)),
        });
        let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
            label: Some("tecs sprite pipeline layout"),
            bind_group_layouts: &[Some(&scene_layout), Some(&image_layout)],
            immediate_size: 0,
        });
        let attributes = wgpu::vertex_attr_array![
            0 => Float32x2,
            1 => Float32,
            2 => Float32x2,
            3 => Float32,
            4 => Float32x4,
            5 => Float32x4,
        ];
        let pipeline = device.create_render_pipeline(&RenderPipelineDescriptor {
            label: Some("tecs sprite pipeline"),
            layout: Some(&pipeline_layout),
            vertex: VertexState {
                module: &shader,
                entry_point: Some("vertexMain"),
                compilation_options: PipelineCompilationOptions::default(),
                buffers: &[Some(VertexBufferLayout {
                    array_stride: INSTANCE_STRIDE as u64,
                    step_mode: VertexStepMode::Instance,
                    attributes: &attributes,
                })],
            },
            fragment: Some(FragmentState {
                module: &shader,
                entry_point: Some("fragmentMain"),
                compilation_options: PipelineCompilationOptions::default(),
                targets: &[Some(ColorTargetState {
                    format: config.format,
                    blend: Some(BlendState::ALPHA_BLENDING),
                    write_mask: ColorWrites::ALL,
                })],
            }),
            primitive: Default::default(),
            depth_stencil: None,
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        });
        let samplers = create_samplers(&device);
        // One opaque white texel, so an untextured instance and one whose image
        // never became resident both draw their tint unchanged.
        let fallback = create_image(&device, &queue, 0, 1, 1, &[255, 255, 255, 255])?;
        let instance_capacity = INSTANCE_STRIDE;
        let instance_buffer = device.create_buffer(&BufferDescriptor {
            label: Some("tecs sprite instances"),
            size: instance_capacity as u64,
            usage: BufferUsages::VERTEX | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        Ok(Self {
            surface,
            device,
            queue,
            config,
            pipeline,
            scene_buffer,
            scene_bind_group,
            image_layout,
            samplers,
            fallback,
            images: HashMap::new(),
            bind_groups: HashMap::new(),
            instance_buffer,
            instance_capacity,
        })
    }

    pub fn resize(&mut self, width: u32, height: u32) {
        if width == 0 || height == 0 {
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

    fn bind_group(&mut self, image: u32, sampler: u32) -> &BindGroup {
        let key = (image, sampler);
        if !self.bind_groups.contains_key(&key) {
            // An id the packet names but nothing uploaded falls back rather
            // than failing the frame, which is what makes a missing asset a
            // visible untextured quad instead of a dead window.
            let view = self.images.get(&image).map_or(&self.fallback, |view| view);
            let group = self.device.create_bind_group(&BindGroupDescriptor {
                label: Some("tecs image bind group"),
                layout: &self.image_layout,
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

    pub fn render(&mut self, bytes: &[u8]) -> Result<()> {
        let packet = parse_packet(bytes)?;
        self.queue
            .write_buffer(&self.scene_buffer, 0, bytemuck::cast_slice(&packet.scene));
        if packet.instances.len() > self.instance_capacity {
            self.instance_capacity = packet.instances.len().next_power_of_two();
            self.instance_buffer = self.device.create_buffer(&BufferDescriptor {
                label: Some("tecs sprite instances"),
                size: self.instance_capacity as u64,
                usage: BufferUsages::VERTEX | BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
        }
        if !packet.instances.is_empty() {
            self.queue
                .write_buffer(&self.instance_buffer, 0, packet.instances);
        }
        // Resolved before the pass borrows the encoder, because creating a bind
        // group on demand needs the device this method also lends out.
        for batch in &packet.batches {
            let _ = self.bind_group(batch.image, batch.sampler);
        }

        let (frame, reconfigure) = match self.surface.get_current_texture() {
            CurrentSurfaceTexture::Success(frame) => (frame, false),
            CurrentSurfaceTexture::Suboptimal(frame) => (frame, true),
            CurrentSurfaceTexture::Timeout | CurrentSurfaceTexture::Occluded => return Ok(()),
            CurrentSurfaceTexture::Outdated => {
                self.surface.configure(&self.device, &self.config);
                return Ok(());
            }
            CurrentSurfaceTexture::Lost => bail!("the wgpu presentation surface was lost"),
            CurrentSurfaceTexture::Validation => {
                bail!("wgpu rejected presentation surface acquisition")
            }
        };
        let view = frame.texture.create_view(&TextureViewDescriptor::default());
        let mut encoder = self
            .device
            .create_command_encoder(&CommandEncoderDescriptor {
                label: Some("tecs frame encoder"),
            });
        {
            let color_attachments = [Some(RenderPassColorAttachment {
                view: &view,
                depth_slice: None,
                resolve_target: None,
                ops: Operations {
                    load: LoadOp::Clear(Color {
                        r: 0.025,
                        g: 0.03,
                        b: 0.04,
                        a: 1.0,
                    }),
                    store: StoreOp::Store,
                },
            })];
            let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
                label: Some("tecs sprite pass"),
                color_attachments: &color_attachments,
                ..Default::default()
            });
            pass.set_pipeline(&self.pipeline);
            pass.set_bind_group(0, &self.scene_bind_group, &[]);
            pass.set_vertex_buffer(0, self.instance_buffer.slice(..));
            // In packet order, because the scene composites back to front with
            // no depth test and a reordered batch is a reordered picture.
            for batch in &packet.batches {
                let group = self
                    .bind_groups
                    .get(&(batch.image, batch.sampler))
                    .expect("resolved above");
                pass.set_bind_group(1, group, &[]);
                pass.draw(0..6, batch.first..batch.first + batch.count);
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

fn parse_packet(bytes: &[u8]) -> Result<RenderPacket<'_>> {
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
    let batch_stride = read_u32(bytes, 12) as usize;
    if batch_stride != BATCH_STRIDE {
        bail!("render packet batch stride {batch_stride} is not {BATCH_STRIDE}");
    }
    let batch_count = read_u32(bytes, 16);
    let instance_stride = read_u32(bytes, 20) as usize;
    if instance_stride != INSTANCE_STRIDE {
        bail!("render packet instance stride {instance_stride} is not {INSTANCE_STRIDE}");
    }
    let instance_count = read_u32(bytes, 24);
    let flags = read_u32(bytes, 28);
    if flags != 0 {
        bail!("render packet reserved flags {flags:#010x} are not zero");
    }

    let target = [read_f32(bytes, 32), read_f32(bytes, 36)];
    if !target[0].is_finite() || !target[1].is_finite() || target[0] <= 0.0 || target[1] <= 0.0 {
        bail!(
            "render packet has invalid render target {}x{}",
            target[0],
            target[1]
        );
    }
    let camera = [read_f32(bytes, 40), read_f32(bytes, 44)];
    let zoom = read_f32(bytes, 48);
    let rotation = read_f32(bytes, 52);
    if !camera[0].is_finite() || !camera[1].is_finite() || !rotation.is_finite() {
        bail!("render packet has a camera value that is not finite");
    }
    if !zoom.is_finite() || zoom <= 0.0 {
        bail!("render packet camera zoom {zoom} is not greater than zero");
    }

    let batch_bytes = (batch_count as usize)
        .checked_mul(batch_stride)
        .context("render packet batch byte count overflowed")?;
    let instance_bytes = (instance_count as usize)
        .checked_mul(instance_stride)
        .context("render packet instance byte count overflowed")?;
    let expected = PACKET_HEADER_SIZE
        .checked_add(batch_bytes)
        .and_then(|size| size.checked_add(instance_bytes))
        .context("render packet size overflowed")?;
    if bytes.len() != expected {
        bail!(
            "render packet is {} bytes; header declares {expected}",
            bytes.len()
        );
    }

    let mut batches = Vec::with_capacity(batch_count as usize);
    let mut covered = 0_u32;
    for index in 0..batch_count as usize {
        let base = PACKET_HEADER_SIZE + index * batch_stride;
        let batch = Batch {
            image: read_u32(bytes, base),
            sampler: read_u32(bytes, base + 4),
            first: read_u32(bytes, base + 8),
            count: read_u32(bytes, base + 12),
        };
        if batch.sampler >= SAMPLER_COUNT {
            bail!(
                "render packet batch {index} selects unknown sampler {}",
                batch.sampler
            );
        }
        if batch.count == 0 {
            bail!("render packet batch {index} draws no instances");
        }
        // The batches have to partition the instances in order, because the
        // draw order is the picture and a gap or an overlap is neither.
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

    let instances = &bytes[PACKET_HEADER_SIZE + batch_bytes..];
    for chunk in instances.chunks_exact(4) {
        let value = f32::from_ne_bytes(chunk.try_into().expect("four-byte chunk"));
        if !value.is_finite() {
            bail!("render packet contains a non-finite instance value");
        }
    }

    Ok(RenderPacket {
        scene: [
            target[0], target[1], camera[0], camera[1], zoom, rotation, 0.0, 0.0,
        ],
        batches,
        instances,
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
mod tests {
    use super::*;

    struct PacketBuilder {
        header: [u32; 8],
        target: [f32; 2],
        camera: [f32; 4],
        batches: Vec<[u32; 4]>,
        instances: Vec<f32>,
    }

    impl PacketBuilder {
        fn new() -> Self {
            Self {
                header: [
                    PACKET_MAGIC,
                    PACKET_VERSION,
                    PACKET_HEADER_SIZE as u32,
                    BATCH_STRIDE as u32,
                    0,
                    INSTANCE_STRIDE as u32,
                    0,
                    0,
                ],
                target: [640.0, 360.0],
                camera: [320.0, 180.0, 1.0, 0.0],
                batches: Vec::new(),
                instances: Vec::new(),
            }
        }

        fn batch(mut self, image: u32, sampler: u32, first: u32, count: u32) -> Self {
            self.batches.push([image, sampler, first, count]);
            self
        }

        fn instances(mut self, count: u32) -> Self {
            for index in 0..count {
                let mut values = [0.0_f32; INSTANCE_STRIDE / 4];
                values[0] = index as f32;
                self.instances.extend_from_slice(&values);
            }
            self
        }

        fn build(mut self) -> Vec<u8> {
            self.header[4] = self.batches.len() as u32;
            self.header[6] = (self.instances.len() * 4 / INSTANCE_STRIDE) as u32;
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
            for batch in &self.batches {
                for value in batch {
                    bytes.extend_from_slice(&value.to_ne_bytes());
                }
            }
            for value in &self.instances {
                bytes.extend_from_slice(&value.to_ne_bytes());
            }
            bytes
        }
    }

    fn valid() -> PacketBuilder {
        PacketBuilder::new()
            .instances(3)
            .batch(0, 0, 0, 2)
            .batch(7, 5, 2, 1)
    }

    #[test]
    fn parses_a_complete_scene() {
        let bytes = valid().build();
        let parsed = parse_packet(&bytes).expect("valid packet");
        assert_eq!(parsed.instances.len() / INSTANCE_STRIDE, 3);
        assert_eq!(
            parsed.scene,
            [640.0, 360.0, 320.0, 180.0, 1.0, 0.0, 0.0, 0.0]
        );
        assert_eq!(parsed.instances.len(), INSTANCE_STRIDE * 3);
        assert_eq!(
            parsed.batches,
            vec![
                Batch {
                    image: 0,
                    sampler: 0,
                    first: 0,
                    count: 2
                },
                Batch {
                    image: 7,
                    sampler: 5,
                    first: 2,
                    count: 1
                },
            ]
        );
    }

    #[test]
    fn parses_an_empty_scene() {
        let bytes = PacketBuilder::new().build();
        let parsed = parse_packet(&bytes).expect("valid empty packet");
        assert!(parsed.instances.is_empty());
        assert!(parsed.batches.is_empty());
        assert!(parsed.instances.is_empty());
    }

    #[test]
    fn rejects_an_old_version() {
        let mut builder = valid();
        builder.header[1] = 1;
        let error = parse_packet(&builder.build()).err().expect("rejected");
        assert!(error.to_string().contains("version 1 is not supported"));
    }

    #[test]
    fn rejects_a_foreign_header_size() {
        let mut builder = valid();
        builder.header[2] = 24;
        let error = parse_packet(&builder.build()).err().expect("rejected");
        assert!(error.to_string().contains("header size 24"));
    }

    #[test]
    fn rejects_reserved_flags() {
        let mut builder = valid();
        builder.header[7] = 1;
        let error = parse_packet(&builder.build()).err().expect("rejected");
        assert!(error.to_string().contains("reserved flags"));
    }

    #[test]
    fn rejects_a_truncated_batch_table() {
        let mut bytes = valid().build();
        bytes.truncate(bytes.len() - 4);
        let error = parse_packet(&bytes).err().expect("rejected");
        assert!(error.to_string().contains("header declares"));
    }

    #[test]
    fn rejects_batches_that_leave_a_gap() {
        let bytes = PacketBuilder::new()
            .instances(3)
            .batch(0, 0, 0, 1)
            .batch(1, 0, 2, 1)
            .build();
        let error = parse_packet(&bytes).err().expect("rejected");
        assert!(error.to_string().contains("starts at 2 rather than 1"));
    }

    #[test]
    fn rejects_batches_that_do_not_cover_every_instance() {
        let bytes = PacketBuilder::new().instances(3).batch(0, 0, 0, 2).build();
        let error = parse_packet(&bytes).err().expect("rejected");
        assert!(error.to_string().contains("cover 2 of 3 instances"));
    }

    #[test]
    fn rejects_an_empty_batch() {
        let bytes = PacketBuilder::new().instances(1).batch(0, 0, 0, 0).build();
        let error = parse_packet(&bytes).err().expect("rejected");
        assert!(error.to_string().contains("draws no instances"));
    }

    #[test]
    fn rejects_an_unknown_sampler() {
        let bytes = PacketBuilder::new()
            .instances(1)
            .batch(0, SAMPLER_COUNT, 0, 1)
            .build();
        let error = parse_packet(&bytes).err().expect("rejected");
        assert!(error.to_string().contains("unknown sampler"));
    }

    #[test]
    fn rejects_a_camera_that_cannot_project() {
        let mut builder = valid();
        builder.camera[2] = 0.0;
        let error = parse_packet(&builder.build()).err().expect("rejected");
        assert!(error
            .to_string()
            .contains("zoom 0 is not greater than zero"));

        let mut turned = valid();
        turned.camera[3] = f32::NAN;
        let error = parse_packet(&turned.build()).err().expect("rejected");
        assert!(error
            .to_string()
            .contains("camera value that is not finite"));
    }

    #[test]
    fn rejects_a_target_with_no_area() {
        let mut builder = valid();
        builder.target[1] = 0.0;
        let error = parse_packet(&builder.build()).err().expect("rejected");
        assert!(error.to_string().contains("invalid render target"));
    }

    #[test]
    fn rejects_non_finite_gpu_values() {
        let mut builder = valid();
        builder.instances[5] = f32::NAN;
        let error = parse_packet(&builder.build()).err().expect("rejected");
        assert!(error.to_string().contains("non-finite"));
    }
}
