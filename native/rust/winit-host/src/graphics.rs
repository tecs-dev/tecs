use std::borrow::Cow;
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use wgpu::util::DeviceExt;
use wgpu::{
    BindGroup, BindGroupDescriptor, BindGroupEntry, BindGroupLayoutDescriptor,
    BindGroupLayoutEntry, BindingType, BlendState, Buffer, BufferBindingType, BufferDescriptor,
    BufferUsages, Color, ColorTargetState, ColorWrites, CommandEncoderDescriptor,
    CurrentSurfaceTexture, Device, DeviceDescriptor, FragmentState, Instance, InstanceDescriptor,
    LoadOp, Operations, PipelineCompilationOptions, PipelineLayoutDescriptor, Queue,
    RenderPassColorAttachment, RenderPassDescriptor, RenderPipeline, RenderPipelineDescriptor,
    ShaderModuleDescriptor, ShaderSource, ShaderStages, StoreOp, Surface, SurfaceConfiguration,
    TextureViewDescriptor, VertexBufferLayout, VertexState, VertexStepMode,
};
use winit::event_loop::OwnedDisplayHandle;
use winit::window::Window;

const PACKET_MAGIC: u32 = 0x5445_4353;
const PACKET_VERSION: u32 = 1;
const PACKET_HEADER_SIZE: usize = 24;
const INSTANCE_STRIDE: usize = 36;

const SHADER: &str = r#"
struct Viewport {
    size: vec2<f32>,
    _padding: vec2<f32>,
}

@group(0) @binding(0)
var<uniform> viewport: Viewport;

struct InstanceInput {
    @location(0) position: vec2<f32>,
    @location(1) rotation: f32,
    @location(2) scale: vec2<f32>,
    @location(3) color: vec4<f32>,
}

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
}

@vertex
fn vertexMain(@builtin(vertex_index) vertexIndex: u32, instance: InstanceInput) -> VertexOutput {
    let corners = array<vec2<f32>, 6>(
        vec2(-0.5, -0.5), vec2(0.5, -0.5), vec2(-0.5, 0.5),
        vec2(-0.5, 0.5), vec2(0.5, -0.5), vec2(0.5, 0.5),
    );
    let local = corners[vertexIndex] * instance.scale;
    let sine = sin(instance.rotation);
    let cosine = cos(instance.rotation);
    let rotated = vec2(
        local.x * cosine - local.y * sine,
        local.x * sine + local.y * cosine,
    );
    let pixel = instance.position + rotated;
    let clip = vec2(
        pixel.x / viewport.size.x * 2.0 - 1.0,
        1.0 - pixel.y / viewport.size.y * 2.0,
    );

    var output: VertexOutput;
    output.position = vec4(clip, 0.0, 1.0);
    output.color = instance.color;
    return output;
}

@fragment
fn fragmentMain(input: VertexOutput) -> @location(0) vec4<f32> {
    return input.color;
}
"#;

struct RenderPacket<'a> {
    viewport: [f32; 2],
    instances: &'a [u8],
    instance_count: u32,
}

pub struct Graphics {
    surface: Surface<'static>,
    device: Device,
    queue: Queue,
    config: SurfaceConfiguration,
    pipeline: RenderPipeline,
    viewport_buffer: Buffer,
    viewport_bind_group: BindGroup,
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

        let viewport = [1.0_f32, 1.0, 0.0, 0.0];
        let viewport_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("tecs viewport"),
            contents: bytemuck::cast_slice(&viewport),
            usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
        });
        let viewport_layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("tecs viewport layout"),
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
        let viewport_bind_group = device.create_bind_group(&BindGroupDescriptor {
            label: Some("tecs viewport bind group"),
            layout: &viewport_layout,
            entries: &[BindGroupEntry {
                binding: 0,
                resource: viewport_buffer.as_entire_binding(),
            }],
        });
        let shader = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("tecs flat-color shader"),
            source: ShaderSource::Wgsl(Cow::Borrowed(SHADER)),
        });
        let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
            label: Some("tecs flat-color pipeline layout"),
            bind_group_layouts: &[Some(&viewport_layout)],
            immediate_size: 0,
        });
        let attributes = wgpu::vertex_attr_array![
            0 => Float32x2,
            1 => Float32,
            2 => Float32x2,
            3 => Float32x4,
        ];
        let pipeline = device.create_render_pipeline(&RenderPipelineDescriptor {
            label: Some("tecs flat-color pipeline"),
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
        let instance_capacity = INSTANCE_STRIDE;
        let instance_buffer = device.create_buffer(&BufferDescriptor {
            label: Some("tecs flat-color instances"),
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
            viewport_buffer,
            viewport_bind_group,
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

    pub fn render(&mut self, bytes: &[u8]) -> Result<()> {
        let packet = parse_packet(bytes)?;
        let viewport = [packet.viewport[0], packet.viewport[1], 0.0, 0.0];
        self.queue
            .write_buffer(&self.viewport_buffer, 0, bytemuck::cast_slice(&viewport));
        if packet.instances.len() > self.instance_capacity {
            self.instance_capacity = packet.instances.len().next_power_of_two();
            self.instance_buffer = self.device.create_buffer(&BufferDescriptor {
                label: Some("tecs flat-color instances"),
                size: self.instance_capacity as u64,
                usage: BufferUsages::VERTEX | BufferUsages::COPY_DST,
                mapped_at_creation: false,
            });
        }
        if !packet.instances.is_empty() {
            self.queue
                .write_buffer(&self.instance_buffer, 0, packet.instances);
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
                label: Some("tecs flat-color pass"),
                color_attachments: &color_attachments,
                ..Default::default()
            });
            pass.set_pipeline(&self.pipeline);
            pass.set_bind_group(0, &self.viewport_bind_group, &[]);
            pass.set_vertex_buffer(0, self.instance_buffer.slice(..));
            pass.draw(0..6, 0..packet.instance_count);
        }
        self.queue.submit([encoder.finish()]);
        self.queue.present(frame);
        if reconfigure {
            self.surface.configure(&self.device, &self.config);
        }

        Ok(())
    }
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
    let stride = read_u32(bytes, 8) as usize;
    if stride != INSTANCE_STRIDE {
        bail!("render packet instance stride {stride} is not {INSTANCE_STRIDE}");
    }
    let instance_count = read_u32(bytes, 12);
    let viewport = [read_f32(bytes, 16), read_f32(bytes, 20)];
    if !viewport[0].is_finite()
        || !viewport[1].is_finite()
        || viewport[0] <= 0.0
        || viewport[1] <= 0.0
    {
        bail!(
            "render packet has invalid viewport {}x{}",
            viewport[0],
            viewport[1]
        );
    }
    let instance_bytes = (instance_count as usize)
        .checked_mul(stride)
        .context("render packet instance byte count overflowed")?;
    let expected = PACKET_HEADER_SIZE
        .checked_add(instance_bytes)
        .context("render packet size overflowed")?;
    if bytes.len() != expected {
        bail!(
            "render packet is {} bytes; header declares {expected}",
            bytes.len()
        );
    }
    let instances = &bytes[PACKET_HEADER_SIZE..];
    for chunk in instances.chunks_exact(4) {
        let value = f32::from_ne_bytes(chunk.try_into().expect("four-byte chunk"));
        if !value.is_finite() {
            bail!("render packet contains a non-finite instance value");
        }
    }

    Ok(RenderPacket {
        viewport,
        instances,
        instance_count,
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

    fn packet(count: u32, values: &[f32]) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&PACKET_MAGIC.to_ne_bytes());
        bytes.extend_from_slice(&PACKET_VERSION.to_ne_bytes());
        bytes.extend_from_slice(&(INSTANCE_STRIDE as u32).to_ne_bytes());
        bytes.extend_from_slice(&count.to_ne_bytes());
        bytes.extend_from_slice(&640.0_f32.to_ne_bytes());
        bytes.extend_from_slice(&360.0_f32.to_ne_bytes());
        for value in values {
            bytes.extend_from_slice(&value.to_ne_bytes());
        }
        bytes
    }

    #[test]
    fn parses_a_complete_batch() {
        let values = [0.0_f32; INSTANCE_STRIDE / 4];
        let bytes = packet(1, &values);
        let parsed = parse_packet(&bytes).expect("valid packet");
        assert_eq!(parsed.viewport, [640.0, 360.0]);
        assert_eq!(parsed.instance_count, 1);
        assert_eq!(parsed.instances.len(), INSTANCE_STRIDE);
    }

    #[test]
    fn rejects_a_truncated_batch() {
        let bytes = packet(1, &[]);
        let error = parse_packet(&bytes).err().expect("truncated packet");
        assert!(error.to_string().contains("header declares 60"));
    }

    #[test]
    fn rejects_non_finite_gpu_values() {
        let mut values = [0.0_f32; INSTANCE_STRIDE / 4];
        values[2] = f32::NAN;
        let bytes = packet(1, &values);
        let error = parse_packet(&bytes).err().expect("invalid packet");
        assert!(error.to_string().contains("non-finite"));
    }
}
