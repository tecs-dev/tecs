//! Ordered viewports, retaining each view's GPU scene between submissions.
use super::*;
pub(super) const MAGIC: u32 = 0x54565753;

pub(super) struct ViewState {
    particle_pool: Option<u32>,
    mesh_source: Option<(u64, BindGroup)>,
    offscreen: Option<wgpu::Texture>,
    scratch: Option<Scratch>,
    batches: Vec<Batch>,
    resident_scene: Option<RetainedScene>,
    tile_chunks: Buffer,
    frame_table: Buffer,
    bind_groups: HashMap<(u32, u32), BindGroup>,
    graph: Option<Graph>,
    graph_generation: u64,
    graph_revision: Option<u32>,
    pipeline_format: Option<TextureFormat>,
    passes: Vec<PassRuntime>,
    targets: TargetStore<TargetTexture>,
    binding_generation: u64,
    bound_generation: u64,
    asset_revision: u64,
}

impl ViewState {
    fn new(device: &Device) -> Self {
        Self {
            particle_pool: None,
            mesh_source: None,
            offscreen: None,
            scratch: None,
            batches: Vec::new(),
            resident_scene: None,
            frame_table: device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("view frame table"),
                contents: &[0; 4],
                usage: BufferUsages::STORAGE | BufferUsages::COPY_DST,
            }),
            tile_chunks: device.create_buffer(&BufferDescriptor {
                label: Some("view tile chunks"),
                size: 1072,
                usage: BufferUsages::STORAGE | BufferUsages::COPY_DST,
                mapped_at_creation: false,
            }),
            bind_groups: HashMap::new(),
            graph: None,
            graph_generation: 0,
            graph_revision: None,
            pipeline_format: None,
            passes: Vec::new(),
            targets: TargetStore::default(),
            binding_generation: 1,
            bound_generation: 0,
            asset_revision: 0,
        }
    }
    fn swap(&mut self, graphics: &mut Graphics) {
        macro_rules! swap { ($($field:ident),*) => { $(std::mem::swap(&mut self.$field, &mut graphics.$field);)* }; }
        swap!(
            particle_pool,
            mesh_source,
            offscreen,
            scratch,
            batches,
            resident_scene,
            tile_chunks,
            frame_table,
            bind_groups,
            graph,
            graph_generation,
            graph_revision,
            pipeline_format,
            passes,
            targets,
            binding_generation,
            bound_generation
        );
    }
}

struct View<'a> {
    id: u32,
    rect: [f32; 4],
    packet: &'a [u8],
    meshes: &'a [u8],
}
struct Frame<'a> {
    revision: u32,
    width: u32,
    height: u32,
    views: Vec<View<'a>>,
}
fn parse(bytes: &[u8]) -> Result<Frame<'_>> {
    let mut at = 0;
    fn word(bytes: &[u8], at: &mut usize) -> Result<u32> {
        let value = u32::from_ne_bytes(
            bytes
                .get(*at..*at + 4)
                .context("truncated views")?
                .try_into()?,
        );
        *at += 4;
        Ok(value)
    }
    let magic = word(bytes, &mut at)?;
    let version = word(bytes, &mut at)?;
    if magic != MAGIC || (version != 1 && version != 2) {
        bail!("unknown view packet");
    }
    let revision = word(bytes, &mut at)?;
    let width = word(bytes, &mut at)?;
    let height = word(bytes, &mut at)?;
    let count = word(bytes, &mut at)? as usize;
    if width == 0 || height == 0 || count > bytes.len() / 24 {
        bail!("invalid view dimensions or count");
    }
    let mut views = Vec::with_capacity(count);
    let mut ids = std::collections::HashSet::new();
    for _ in 0..count {
        let id = word(bytes, &mut at)?;
        if !ids.insert(id) {
            bail!("duplicate view id");
        }
        let mut rect = [0.; 4];
        for value in &mut rect {
            *value = f32::from_bits(word(bytes, &mut at)?);
        }
        if rect.iter().any(|v| !v.is_finite())
            || rect[0] < 0.
            || rect[1] < 0.
            || rect[2] <= 0.
            || rect[3] <= 0.
            || rect[0] + rect[2] > 1.000001
            || rect[1] + rect[3] > 1.000001
        {
            bail!("view rectangle is outside the frame");
        }
        let size = word(bytes, &mut at)? as usize;
        let packet = bytes.get(at..at + size).context("truncated view scene")?;
        at += size;
        if packet.len() < 128 {
            bail!("view scene is shorter than its header");
        }
        let expected = [
            (rect[2] * width as f32).round().max(1.),
            (rect[3] * height as f32).round().max(1.),
        ];
        for (index, expected) in expected.into_iter().enumerate() {
            let actual = f32::from_ne_bytes(packet[40 + index * 4..44 + index * 4].try_into()?);
            if expected != actual {
                bail!("view scene dimensions do not match its viewport");
            }
        }
        let meshes = if version == 2 {
            let size = word(bytes, &mut at)? as usize;
            let data = bytes.get(at..at + size).context("truncated mesh view")?;
            at += size;
            data
        } else {
            &[]
        };
        views.push(View {
            id,
            rect,
            packet,
            meshes,
        });
    }
    if at != bytes.len() {
        bail!("trailing view bytes");
    }
    Ok(Frame {
        revision,
        width,
        height,
        views,
    })
}

pub(super) struct Compositor {
    format: TextureFormat,
    pipeline: RenderPipeline,
    layout: BindGroupLayout,
}
impl Compositor {
    fn new(g: &Graphics) -> Self {
        let layout = input_layout(&g.device, &[Input::Target(0)]);
        let module = g.device.create_shader_module(ShaderModuleDescriptor {
            label: Some("view composite"),
            source: ShaderSource::Wgsl(Cow::Owned(fullscreen_source(PRESENT_WGSL, 1))),
        });
        let pipeline_layout = g.device.create_pipeline_layout(&PipelineLayoutDescriptor {
            label: Some("view composite"),
            bind_group_layouts: &[Some(&g.layouts.scene), Some(&layout)],
            immediate_size: 0,
        });
        let pipeline = g.device.create_render_pipeline(&RenderPipelineDescriptor {
            label: Some("view composite"),
            layout: Some(&pipeline_layout),
            vertex: VertexState {
                module: &module,
                entry_point: Some("fullscreenMain"),
                compilation_options: Default::default(),
                buffers: &[],
            },
            fragment: Some(FragmentState {
                module: &module,
                entry_point: Some("presentMain"),
                compilation_options: Default::default(),
                targets: &[Some(ColorTargetState {
                    format: g.config.format,
                    blend: Some(BlendState::PREMULTIPLIED_ALPHA_BLENDING),
                    write_mask: ColorWrites::ALL,
                })],
            }),
            primitive: Default::default(),
            depth_stencil: None,
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        });
        Self {
            format: g.config.format,
            pipeline,
            layout,
        }
    }
}

impl Graphics {
    pub(super) fn render_views(&mut self, bytes: &[u8]) -> Result<bool> {
        let frame = parse(bytes)?;
        if frame.width != self.config.width || frame.height != self.config.height {
            bail!("view frame size differs from the output");
        }
        if let Some(reason) = self.lost.lock().expect("mutex").take() {
            self.views.clear();
            self.view_revision = None;
            bail!("the wgpu device was lost: {reason}");
        }
        let capture = std::mem::take(&mut self.capture_requested);
        let surface = self.surface.take();
        let original_size = (self.config.width, self.config.height);
        self.rendering_view = true;
        let outcome = (|| -> Result<()> {
            for view in &frame.views {
                let mut state = self
                    .views
                    .remove(&view.id)
                    .unwrap_or_else(|| ViewState::new(&self.device));
                if state.asset_revision != self.asset_revision {
                    state.bind_groups.clear();
                    state.asset_revision = self.asset_revision;
                }
                state.swap(self);
                let width = (view.rect[2] * frame.width as f32).round().max(1.) as u32;
                let height = (view.rect[3] * frame.height as f32).round().max(1.) as u32;
                self.config.width = width;
                self.config.height = height;
                if self.offscreen.as_ref().is_none_or(|t| {
                    t.width() != width || t.height() != height || t.format() != self.config.format
                }) {
                    self.offscreen = Some(self.device.create_texture(&TextureDescriptor {
                        label: Some("view output"),
                        size: Extent3d {
                            width,
                            height,
                            depth_or_array_layers: 1,
                        },
                        mip_level_count: 1,
                        sample_count: 1,
                        dimension: TextureDimension::D2,
                        format: self.config.format,
                        usage: TextureUsages::RENDER_ATTACHMENT
                            | TextureUsages::TEXTURE_BINDING
                            | TextureUsages::COPY_SRC,
                        view_formats: &[],
                    }));
                }
                let result = (|| -> Result<bool> {
                    if view.meshes.is_empty() {
                        self.mesh_source = None;
                    } else {
                        let renderer = self.mesh_renderer.get_or_insert_with(|| {
                            meshes::Renderer::new(&self.device, &self.queue)
                        });
                        let (texture, generation) =
                            renderer.render(view.id, view.meshes, width, height)?;
                        if self
                            .mesh_source
                            .as_ref()
                            .is_none_or(|(held, _)| *held != generation)
                        {
                            let group = self.device.create_bind_group(&BindGroupDescriptor {
                                label: Some("mesh composite"),
                                layout: &self.layouts.mesh_composite,
                                entries: &[
                                    BindGroupEntry {
                                        binding: 0,
                                        resource: BindingResource::Sampler(&self.pass_sampler),
                                    },
                                    BindGroupEntry {
                                        binding: 1,
                                        resource: BindingResource::TextureView(&texture),
                                    },
                                ],
                            });
                            self.mesh_source = Some((generation, group));
                        }
                    }
                    self.render(view.packet)
                })();
                state.swap(self);
                self.views.insert(view.id, state);
                result?;
            }
            Ok(())
        })();
        self.config.width = original_size.0;
        self.config.height = original_size.1;
        self.surface = surface;
        self.rendering_view = false;
        self.capture_requested = capture;
        if let Err(error) = outcome {
            self.view_revision = None;
            return Err(error);
        }
        if let Some(renderer) = &mut self.mesh_renderer {
            renderer.retain_views(
                &frame
                    .views
                    .iter()
                    .filter(|v| !v.meshes.is_empty())
                    .map(|v| v.id)
                    .collect(),
            );
        }
        let particle_ids: std::collections::HashSet<_> = frame
            .views
            .iter()
            .filter_map(|view| self.views[&view.id].particle_pool)
            .collect();
        self.particle_pools
            .retain(|id, _| particle_ids.contains(id));
        self.views
            .retain(|id, _| frame.views.iter().any(|v| v.id == *id));
        if self
            .view_compositor
            .as_ref()
            .is_none_or(|c| c.format != self.config.format)
        {
            self.view_compositor = Some(Compositor::new(self));
        }
        let output = if let Some(surface) = &self.surface {
            match surface.get_current_texture() {
                CurrentSurfaceTexture::Success(value)
                | CurrentSurfaceTexture::Suboptimal(value) => Some(value),
                CurrentSurfaceTexture::Timeout | CurrentSurfaceTexture::Occluded => {
                    return Ok(false)
                }
                CurrentSurfaceTexture::Outdated | CurrentSurfaceTexture::Lost => {
                    surface.configure(&self.device, &self.config);
                    return Ok(false);
                }
                CurrentSurfaceTexture::Validation => bail!("wgpu rejected view presentation"),
            }
        } else {
            None
        };
        let texture = output
            .as_ref()
            .map(|f| &f.texture)
            .or(self.offscreen.as_ref())
            .context("view presentation has no output")?;
        let output_view = texture.create_view(&TextureViewDescriptor::default());
        let compositor = self.view_compositor.as_ref().unwrap();
        let groups: Vec<_> = frame
            .views
            .iter()
            .map(|v| {
                let view = self.views[&v.id]
                    .offscreen
                    .as_ref()
                    .unwrap()
                    .create_view(&TextureViewDescriptor::default());
                self.device.create_bind_group(&BindGroupDescriptor {
                    label: Some("view composite"),
                    layout: &compositor.layout,
                    entries: &[
                        BindGroupEntry {
                            binding: 0,
                            resource: BindingResource::Sampler(&self.pass_sampler),
                        },
                        BindGroupEntry {
                            binding: 1,
                            resource: BindingResource::TextureView(&view),
                        },
                    ],
                })
            })
            .collect();
        let mut encoder = self
            .device
            .create_command_encoder(&CommandEncoderDescriptor {
                label: Some("compose views"),
            });
        {
            let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
                label: Some("compose views"),
                color_attachments: &[Some(RenderPassColorAttachment {
                    view: &output_view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: Operations {
                        load: LoadOp::Clear(Color {
                            r: 0.025,
                            g: 0.03,
                            b: 0.04,
                            a: 1.,
                        }),
                        store: StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_pipeline(&compositor.pipeline);
            pass.set_bind_group(0, &self.scene_bind_group, &[]);
            for (view, group) in frame.views.iter().zip(&groups) {
                let x = view.rect[0] * frame.width as f32;
                let y = view.rect[1] * frame.height as f32;
                let width = (view.rect[2] * frame.width as f32).min(frame.width as f32 - x);
                let height = (view.rect[3] * frame.height as f32).min(frame.height as f32 - y);
                pass.set_viewport(x, y, width, height, 0., 1.);
                pass.set_bind_group(1, group, &[]);
                pass.draw(0..3, 0..1);
            }
        }
        let readback = if capture {
            self.capture_requested = false;
            if texture.usage().contains(TextureUsages::COPY_SRC) {
                let pitch = (frame.width * 4).div_ceil(256) * 256;
                let buffer = self.device.create_buffer(&BufferDescriptor {
                    label: Some("view screenshot"),
                    size: u64::from(pitch) * u64::from(frame.height),
                    usage: BufferUsages::COPY_DST | BufferUsages::MAP_READ,
                    mapped_at_creation: false,
                });
                encoder.copy_texture_to_buffer(
                    texture.as_image_copy(),
                    wgpu::TexelCopyBufferInfo {
                        buffer: &buffer,
                        layout: TexelCopyBufferLayout {
                            offset: 0,
                            bytes_per_row: Some(pitch),
                            rows_per_image: Some(frame.height),
                        },
                    },
                    texture.size(),
                );
                Some((buffer, pitch))
            } else {
                self.captured = Some(Err(anyhow::anyhow!(
                    "surface does not support screenshot readback"
                )));
                None
            }
        } else {
            None
        };
        self.queue.submit([encoder.finish()]);
        if let Some((buffer, pitch)) = readback {
            self.captured = Some(self.read_capture(&buffer, pitch));
        }
        if let Some(output) = output {
            self.queue.present(output);
        }
        self.view_revision = Some(frame.revision);
        if let Some(reason) = self.failed.lock().expect("mutex").take() {
            self.view_revision = None;
            bail!("wgpu reported a view rendering error: {reason}");
        }
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn envelope(revision: u32, views: &[(u32, [f32; 4], Vec<u8>)]) -> Vec<u8> {
        let mut bytes = Vec::new();
        for word in [MAGIC, 1, revision, 640, 360, views.len() as u32] {
            bytes.extend_from_slice(&word.to_ne_bytes());
        }
        for (id, rect, packet) in views {
            bytes.extend_from_slice(&id.to_ne_bytes());
            for value in rect {
                bytes.extend_from_slice(&value.to_ne_bytes());
            }
            bytes.extend_from_slice(&(packet.len() as u32).to_ne_bytes());
            bytes.extend_from_slice(packet);
        }
        bytes
    }
    fn scene(color: [f32; 4]) -> Vec<u8> {
        let mut parameters = [0.; 16];
        parameters[..4].copy_from_slice(&color);
        let graph = crate::graph::tests::custom(
            crate::graph::tests::deferred(),
            11,
            "fn postprocess(uv: vec2<f32>) -> vec4<f32> { return params.values[0]; }",
            parameters,
        );
        let mut fixture = crate::packet::tests::PacketBuilder::new()
            .graph(graph)
            .instances(1, 0)
            .batch(0, 0, 0, 0, 1);
        fixture.target = [320., 360.];
        fixture.counts[3] = 1;
        fixture.build()
    }
    #[test]
    fn rejects_duplicate_views_and_invalid_rectangles() {
        let first = (1, [0., 0., 0.5, 1.], scene([1.; 4]));
        assert!(parse(&envelope(1, &[first.clone(), first.clone()])).is_err());
        let mut outside = first;
        outside.1[0] = 1.;
        assert!(parse(&envelope(1, &[outside])).is_err());
    }
    #[test]
    fn composes_ordered_viewports_and_retains_their_gpu_scenes() {
        let probe = Instance::new(InstanceDescriptor::new_without_display_handle());
        if pollster::block_on(probe.request_adapter(&wgpu::RequestAdapterOptions::default()))
            .is_err()
        {
            return;
        }
        let mut graphics = Graphics::offscreen(640, 360).unwrap();
        let red = scene([1., 0., 0., 1.]);
        let green = scene([0., 1., 0., 1.]);
        let views = [
            (1, [0., 0., 0.5, 1.], red.clone()),
            (2, [0.5, 0., 0.5, 1.], green.clone()),
        ];
        graphics.request_capture();
        graphics.render(&envelope(1, &views)).unwrap();
        let capture = graphics.take_capture().unwrap();
        assert_eq!(
            &capture.rgba[(180 * 640 + 160) * 4..(180 * 640 + 160) * 4 + 4],
            &[255, 0, 0, 255]
        );
        assert_eq!(
            &capture.rgba[(180 * 640 + 480) * 4..(180 * 640 + 480) * 4 + 4],
            &[0, 255, 0, 255]
        );
        assert_eq!(graphics.scene_revision(), 1);
        let retained = [
            (
                1,
                [0.5, 0., 0.5, 1.],
                crate::packet::tests::retained(&red, 1),
            ),
            (
                2,
                [0., 0., 0.5, 1.],
                crate::packet::tests::retained(&green, 1),
            ),
        ];
        graphics.request_capture();
        graphics.render(&envelope(2, &retained)).unwrap();
        let capture = graphics.take_capture().unwrap();
        assert_eq!(
            &capture.rgba[(180 * 640 + 160) * 4..(180 * 640 + 160) * 4 + 4],
            &[0, 255, 0, 255]
        );
        assert_eq!(
            graphics.views[&1].resident_scene.as_ref().unwrap().revision,
            1
        );
        assert_eq!(
            graphics.views[&2].resident_scene.as_ref().unwrap().revision,
            1
        );
        graphics.render(&envelope(3, &[])).unwrap();
        assert!(graphics.views.is_empty());
    }
}
