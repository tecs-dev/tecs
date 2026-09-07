//! Shared model geometry and per-view retained indexed draws.
use super::*;
use serde_json::Value;
mod ao;
mod environment;
mod localshadows;
mod shadows;
mod transparent;

fn u32_at(bytes: &[u8], at: usize) -> Result<u32> {
    Ok(u32::from_ne_bytes(
        bytes
            .get(at..at + 4)
            .context("truncated mesh packet")?
            .try_into()?,
    ))
}
fn array<'a>(value: &'a Value, key: &str) -> Result<&'a Vec<Value>> {
    value[key]
        .as_array()
        .with_context(|| format!("model has no {key} array"))
}
fn number(value: &Value) -> Result<f32> {
    let number = value.as_f64().context("model number missing")? as f32;
    if !number.is_finite() {
        bail!("nonfinite model number");
    }
    Ok(number)
}
fn index(value: &Value) -> Result<usize> {
    Ok(usize::try_from(
        value.as_u64().context("model index missing")?,
    )?)
}
fn stream<'a>(data: &'a [u8], spec: &Value) -> Result<&'a [u8]> {
    let start = index(&spec[0])?;
    let length = index(&spec[1])?;
    data.get(start..start.checked_add(length).context("model stream overflow")?)
        .context("model stream is outside the packet")
}
fn buffer(device: &Device, bytes: &[u8], usage: BufferUsages) -> Buffer {
    device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("mesh data"),
        contents: if bytes.is_empty() { &[0; 4] } else { bytes },
        usage,
    })
}
type BatchKey = (u32, usize, u32, usize, bool, bool);
type BatchData = (Vec<u8>, Vec<u32>);

struct Geometry {
    vertices: Buffer,
    indices: Buffer,
    info: [u32; 8],
    max_joint: Option<u32>,
    source: Vec<u8>,
    index_data: Vec<u8>,
}
struct MaterialGpu {
    group: BindGroup,
    blend: bool,
    double_sided: bool,
    values: [f32; 16],
    maps: [TextureView; 5],
}
struct ModelGpu {
    meshes: Vec<Geometry>,
    materials: Vec<MaterialGpu>,
}
struct BatchGpu {
    model: u32,
    mesh: usize,
    material_model: u32,
    material: usize,
    instances: Buffer,
    data: Vec<u8>,
    entities: Vec<u32>,
    mirrored: bool,
    visible: Buffer,
    scan: Buffer,
    args: Buffer,
    info: Buffer,
    draw: BindGroup,
    cull: BindGroup,
    count: u32,
    blend: bool,
}
struct ViewGpu {
    revision: u32,
    camera: Vec<u8>,
    uniform: Buffer,
    palette: Buffer,
    palette_data: Vec<u8>,
    lighting: Buffer,
    settings: Vec<u8>,
    lights: Buffer,
    light_data: Vec<u8>,
    light_info: Buffer,
    light_tiles: Buffer,
    batches: Vec<BatchGpu>,
    color: wgpu::Texture,
    depth: wgpu::Texture,
    generation: u64,
    shadows: Option<shadows::Maps>,
    ao: Option<ao::State>,
    local_shadows: Option<localshadows::State>,
    settings_json: Value,
    environment: environment::View,
    transparent: Option<transparent::State>,
}

pub(super) struct Renderer {
    device: Device,
    queue: Queue,
    draw_layout: BindGroupLayout,
    cull_layout: BindGroupLayout,
    material_layout: BindGroupLayout,
    local_shadow_layout: BindGroupLayout,
    local_shadow_fallback: BindGroup,
    shadow_layout: BindGroupLayout,
    shadow_fallback: BindGroup,
    shader: wgpu::ShaderModule,
    pipelines: [RenderPipeline; 12],
    cull: [ComputePipeline; 4],
    light_bins: ComputePipeline,
    sampler: Sampler,
    fallbacks: [TextureView; 5],
    models: HashMap<u32, ModelGpu>,
    environments: HashMap<String, TextureView>,
    environment_fallback: TextureView,
    sky: environment::Sky,
    transparent: Option<transparent::Heap>,
    views: HashMap<u32, ViewGpu>,
    generation: u64,
}
impl Renderer {
    pub(super) fn new(device: &Device, queue: &Queue) -> Self {
        let storage = |binding, visibility, read_only| BindGroupLayoutEntry {
            binding,
            visibility,
            ty: BindingType::Buffer {
                ty: BufferBindingType::Storage { read_only },
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        };
        let uniform = |binding, visibility| BindGroupLayoutEntry {
            binding,
            visibility,
            ty: BindingType::Buffer {
                ty: BufferBindingType::Uniform,
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        };
        let draw_layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("mesh draw"),
            entries: &[
                storage(0, ShaderStages::VERTEX, true),
                storage(1, ShaderStages::VERTEX, true),
                storage(2, ShaderStages::VERTEX, true),
                storage(3, ShaderStages::VERTEX, true),
                uniform(6, ShaderStages::VERTEX),
                uniform(7, ShaderStages::VERTEX | ShaderStages::FRAGMENT),
                uniform(8, ShaderStages::FRAGMENT),
                storage(9, ShaderStages::FRAGMENT, true),
                storage(10, ShaderStages::FRAGMENT, true),
                uniform(11, ShaderStages::FRAGMENT),
                BindGroupLayoutEntry {
                    binding: 12,
                    visibility: ShaderStages::FRAGMENT,
                    ty: BindingType::Texture {
                        sample_type: TextureSampleType::Float { filterable: true },
                        view_dimension: TextureViewDimension::D2Array,
                        multisampled: false,
                    },
                    count: None,
                },
                BindGroupLayoutEntry {
                    binding: 13,
                    visibility: ShaderStages::FRAGMENT,
                    ty: BindingType::Sampler(SamplerBindingType::Filtering),
                    count: None,
                },
                uniform(14, ShaderStages::FRAGMENT),
            ],
        });
        let cull_layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("mesh cull"),
            entries: &[
                storage(1, ShaderStages::COMPUTE, true),
                storage(3, ShaderStages::COMPUTE, false),
                storage(4, ShaderStages::COMPUTE, false),
                storage(5, ShaderStages::COMPUTE, false),
                uniform(6, ShaderStages::COMPUTE),
                uniform(7, ShaderStages::COMPUTE),
            ],
        });
        let mut entries = vec![BindGroupLayoutEntry {
            binding: 0,
            visibility: ShaderStages::FRAGMENT,
            ty: BindingType::Sampler(SamplerBindingType::Filtering),
            count: None,
        }];
        for binding in 1..=5 {
            entries.push(BindGroupLayoutEntry {
                binding,
                visibility: ShaderStages::FRAGMENT,
                ty: BindingType::Texture {
                    sample_type: TextureSampleType::Float { filterable: true },
                    view_dimension: TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            });
        }
        entries.push(uniform(6, ShaderStages::FRAGMENT));
        let material_layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("mesh material"),
            entries: &entries,
        });
        let module = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("mesh"),
            source: ShaderSource::Wgsl(Cow::Owned(format!(
                "{}\n{}",
                include_str!("../../../../../assets/shaders/wgsl/meshenvironment.wgsl"),
                include_str!("../../../../../assets/shaders/wgsl/mesh.wgsl")
            ))),
        });
        let local_shadow_layout = localshadows::layout(device);
        let local_shadow_fallback = localshadows::fallback(device, &local_shadow_layout);
        let shadow_layout = shadows::layout(device);
        let shadow_fallback = shadows::fallback(device, &shadow_layout);
        let layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
            label: Some("mesh"),
            bind_group_layouts: &[
                Some(&draw_layout),
                Some(&material_layout),
                Some(&shadow_layout),
                Some(&local_shadow_layout),
            ],
            immediate_size: 0,
        });
        let pipelines = std::array::from_fn(|i| {
            device.create_render_pipeline(&RenderPipelineDescriptor {
                label: Some("mesh"),
                layout: Some(&layout),
                vertex: VertexState {
                    module: &module,
                    entry_point: Some("vertexMain"),
                    compilation_options: Default::default(),
                    buffers: &[],
                },
                fragment: Some(FragmentState {
                    module: &module,
                    entry_point: Some(if i % 6 >= 4 {
                        "fragmentGeometry"
                    } else {
                        "fragmentMain"
                    }),
                    compilation_options: Default::default(),
                    targets: &vec![
                        Some(ColorTargetState {
                            format: TextureFormat::Rgba16Float,
                            blend: (2..4)
                                .contains(&(i % 6))
                                .then_some(BlendState::PREMULTIPLIED_ALPHA_BLENDING),
                            write_mask: ColorWrites::ALL
                        });
                        if i % 6 >= 4 { 3 } else { 1 }
                    ],
                }),
                primitive: wgpu::PrimitiveState {
                    cull_mode: (i % 2 == 0).then_some(wgpu::Face::Back),
                    front_face: if i >= 6 {
                        wgpu::FrontFace::Cw
                    } else {
                        wgpu::FrontFace::Ccw
                    },
                    ..Default::default()
                },
                depth_stencil: Some(DepthStencilState {
                    format: DEPTH_FORMAT,
                    depth_write_enabled: Some(!(2..4).contains(&(i % 6))),
                    depth_compare: Some(wgpu::CompareFunction::LessEqual),
                    stencil: Default::default(),
                    bias: Default::default(),
                }),
                multisample: Default::default(),
                multiview_mask: None,
                cache: None,
            })
        });
        let cull_module = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("mesh cull"),
            source: ShaderSource::Wgsl(Cow::Borrowed(include_str!(
                "../../../../../assets/shaders/wgsl/meshcull.wgsl"
            ))),
        });
        let layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
            label: Some("mesh cull"),
            bind_group_layouts: &[Some(&cull_layout)],
            immediate_size: 0,
        });
        let cull = ["mark", "scanBlocks", "compact", "single"].map(|entry| {
            device.create_compute_pipeline(&ComputePipelineDescriptor {
                label: Some(entry),
                layout: Some(&layout),
                module: &cull_module,
                entry_point: Some(entry),
                compilation_options: Default::default(),
                cache: None,
            })
        });
        let sampler = device.create_sampler(&SamplerDescriptor {
            label: Some("model sampler"),
            address_mode_u: AddressMode::Repeat,
            address_mode_v: AddressMode::Repeat,
            mag_filter: FilterMode::Linear,
            mipmap_filter: MipmapFilterMode::Linear,
            min_filter: FilterMode::Linear,
            ..Default::default()
        });
        let light_shader = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("mesh light bins"),
            source: ShaderSource::Wgsl(Cow::Borrowed(include_str!(
                "../../../../../assets/shaders/wgsl/meshlightbin.wgsl"
            ))),
        });
        let light_bins = device.create_compute_pipeline(&ComputePipelineDescriptor {
            label: Some("mesh light bins"),
            layout: None,
            module: &light_shader,
            entry_point: Some("main"),
            compilation_options: Default::default(),
            cache: None,
        });
        let colors = [[255; 4], [128, 128, 255, 255], [255; 4], [255; 4], [255; 4]];
        let fallbacks = std::array::from_fn(|i| {
            Self::texture(device, queue, 1, 1, &colors[i], i == 0 || i == 4).unwrap()
        });
        Self {
            device: device.clone(),
            queue: queue.clone(),
            draw_layout,
            cull_layout,
            material_layout,
            shadow_layout,
            shadow_fallback,
            local_shadow_layout,
            local_shadow_fallback,
            shader: module,
            pipelines,
            cull,
            light_bins,
            sampler,
            fallbacks,
            models: HashMap::new(),
            environments: HashMap::new(),
            environment_fallback: environment::fallback(device, queue),
            sky: environment::Sky::new(device),
            transparent: None,
            views: HashMap::new(),
            generation: 0,
        }
    }
    fn texture(
        device: &Device,
        queue: &Queue,
        width: u32,
        height: u32,
        pixels: &[u8],
        srgb: bool,
    ) -> Result<TextureView> {
        if width == 0
            || height == 0
            || u64::from(width) * u64::from(height) * 4 != pixels.len() as u64
        {
            bail!("invalid model image");
        }
        let texture = device.create_texture(&TextureDescriptor {
            label: Some("model image"),
            size: Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: TextureDimension::D2,
            format: if srgb {
                TextureFormat::Rgba8UnormSrgb
            } else {
                TextureFormat::Rgba8Unorm
            },
            usage: TextureUsages::TEXTURE_BINDING | TextureUsages::COPY_DST,
            view_formats: &[],
        });
        queue.write_texture(
            texture.as_image_copy(),
            pixels,
            TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(width * 4),
                rows_per_image: Some(height),
            },
            texture.size(),
        );
        Ok(texture.create_view(&Default::default()))
    }
    pub(super) fn retain_views(&mut self, ids: &std::collections::HashSet<u32>) {
        self.views.retain(|id, _| ids.contains(id));
    }
    pub(super) fn upload(&mut self, id: u32, bytes: &[u8]) -> Result<()> {
        let length = u32_at(bytes, 0)? as usize;
        let metadata: Value = serde_json::from_slice(
            bytes
                .get(4..4 + length)
                .context("truncated model metadata")?,
        )?;
        if metadata["version"] != 1 {
            bail!("unsupported model version");
        }
        let data = bytes
            .get((4 + length).next_multiple_of(4)..)
            .context("truncated model streams")?;
        if let Some(name) = metadata.get("environment") {
            let name = name.as_str().context("environment name must be a string")?;
            if name.is_empty() {
                bail!("environment name cannot be empty");
            }
            let texture = environment::upload(&self.device, &self.queue, &metadata, data)?;
            self.environments.insert(name.to_owned(), texture);
            self.views.clear();
            return Ok(());
        }
        let mut meshes = Vec::new();
        for value in array(&metadata, "meshes")? {
            let source = stream(data, &value["vertices"])?;
            if source.len() % 48 != 0 || source.is_empty() {
                bail!("invalid mesh vertex stream");
            }
            let count = source.len() / 48;
            let mut vertices = source.to_vec();
            let mut info = [
                count as u32,
                0,
                0,
                0,
                index(&value["morphTargets"])? as u32,
                0,
                0,
                0,
            ];
            for (lane, name, stride) in [(1, "colors", 16), (2, "skin", 32), (3, "morph", 36)] {
                let stream = stream(data, &value[name])?;
                let expected = count * stride * if lane == 3 { info[4] as usize } else { 1 };
                if !stream.is_empty() && stream.len() != expected {
                    bail!("invalid {name} stream");
                }
                if !stream.is_empty() {
                    info[lane] = (vertices.len() / 4) as u32;
                    vertices.extend_from_slice(stream);
                }
            }
            for word in vertices.as_chunks::<4>().0 {
                if !f32::from_ne_bytes(*word).is_finite() {
                    bail!("nonfinite mesh vertex");
                }
            }
            let indices = stream(data, &value["indices"])?;
            if indices.len() % 12 != 0 || indices.is_empty() {
                bail!("invalid triangle indices");
            }
            for word in indices.as_chunks::<4>().0 {
                if u32::from_ne_bytes(*word) as usize >= count {
                    bail!("mesh index exceeds vertices");
                }
            }
            let mut max_joint = None;
            let skin = stream(data, &value["skin"])?;
            for vertex in skin.as_chunks::<32>().0 {
                for lane in 0..4 {
                    let joint = f32::from_ne_bytes(vertex[lane * 4..lane * 4 + 4].try_into()?);
                    if joint < 0. || joint.fract() != 0. {
                        bail!("invalid mesh joint");
                    }
                    max_joint = Some(max_joint.unwrap_or(0).max(joint as u32));
                }
            }
            info[5] = (indices.len() / 4) as u32;
            meshes.push(Geometry {
                vertices: buffer(&self.device, &vertices, BufferUsages::STORAGE),
                indices: buffer(&self.device, indices, BufferUsages::INDEX),
                info,
                max_joint,
                source: vertices,
                index_data: indices.to_vec(),
            });
        }
        let mut images = Vec::new();
        for value in array(&metadata, "images")? {
            let pixels = stream(data, &value["pixels"])?;
            let width = index(&value["width"])? as u32;
            let height = index(&value["height"])? as u32;
            images.push(super::modeltextures::upload(
                &self.device,
                &self.queue,
                super::modeltextures::Image {
                    width: value["storageWidth"].as_u64().unwrap_or(width as u64) as u32,
                    height: value["storageHeight"].as_u64().unwrap_or(height as u64) as u32,
                    levels: value["levels"].as_u64().unwrap_or(1) as u32,
                    compressed: value["format"].as_u64().unwrap_or(0) == 1,
                    mipmaps: metadata["mipmaps"].as_bool().unwrap_or(false),
                    pixels,
                },
            )?);
        }
        let mut materials = Vec::new();
        let defaults = serde_json::json!({"baseColor":[1,1,1,1],"emission":[0,0,0],"model":0,"metallic":0,"roughness":1,"normalScale":1,"occlusionStrength":1,"alphaMode":0,"alphaCutoff":0.5,"doubleSided":false,"images":[0,0,0,0,0]});
        for value in std::iter::once(&defaults).chain(array(&metadata, "materials")?) {
            let mut words = [0_f32; 16];
            for lane in 0..4 {
                words[lane] = number(&value["baseColor"][lane])?;
            }
            for lane in 0..3 {
                words[4 + lane] = number(&value["emission"][lane])?;
            }
            for (lane, key) in [
                (7, "model"),
                (8, "metallic"),
                (9, "roughness"),
                (10, "normalScale"),
                (11, "occlusionStrength"),
                (12, "alphaMode"),
                (13, "alphaCutoff"),
            ] {
                words[lane] = number(&value[key])?;
            }
            let double_sided = value["doubleSided"]
                .as_bool()
                .context("material double-sided flag missing")?;
            words[14] = u32::from(double_sided) as f32;
            let uniform = buffer(
                &self.device,
                bytemuck::cast_slice(&words),
                BufferUsages::UNIFORM,
            );
            let mut entries = vec![BindGroupEntry {
                binding: 0,
                resource: BindingResource::Sampler(&self.sampler),
            }];
            for lane in 0..5 {
                let image = index(&value["images"][lane])?;
                let view = if image == 0 {
                    &self.fallbacks[lane]
                } else {
                    &images
                        .get(image - 1)
                        .context("material image does not exist")?
                        [usize::from(lane == 0 || lane == 4)]
                };
                entries.push(BindGroupEntry {
                    binding: lane as u32 + 1,
                    resource: BindingResource::TextureView(view),
                });
            }
            entries.push(BindGroupEntry {
                binding: 6,
                resource: uniform.as_entire_binding(),
            });
            let group = self.device.create_bind_group(&BindGroupDescriptor {
                label: Some("model material"),
                layout: &self.material_layout,
                entries: &entries,
            });
            materials.push(MaterialGpu {
                group,
                blend: words[12] == 2.,
                double_sided,
                values: words,
                maps: std::array::from_fn(|lane| {
                    let image = index(&value["images"][lane]).unwrap();
                    if image == 0 {
                        self.fallbacks[lane].clone()
                    } else {
                        images[image - 1][usize::from(lane == 0 || lane == 4)].clone()
                    }
                }),
            });
        }
        self.models.insert(id, ModelGpu { meshes, materials });
        self.transparent = None;
        self.views.clear();
        Ok(())
    }
    fn target(&self, width: u32, height: u32, depth: bool) -> wgpu::Texture {
        self.device.create_texture(&TextureDescriptor {
            label: Some("mesh view target"),
            size: Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: TextureDimension::D2,
            format: if depth {
                DEPTH_FORMAT
            } else {
                TextureFormat::Rgba16Float
            },
            usage: TextureUsages::RENDER_ATTACHMENT
                | TextureUsages::TEXTURE_BINDING
                | if depth {
                    TextureUsages::empty()
                } else {
                    TextureUsages::COPY_DST
                },
            view_formats: &[],
        })
    }
    fn draw(&self, state: &ViewGpu, encoder: &mut wgpu::CommandEncoder, blend: bool) {
        let mut views = vec![state.color.create_view(&Default::default())];
        if !blend {
            if let Some(ao) = &state.ao {
                views.push(ao.ambient.create_view(&Default::default()));
                views.push(ao.normal.create_view(&Default::default()));
            }
        }
        let attachments: Vec<_> = views
            .iter()
            .enumerate()
            .map(|(index, view)| {
                Some(RenderPassColorAttachment {
                    view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: Operations {
                        load: if blend || (index == 0 && state.environment.visible) {
                            LoadOp::Load
                        } else {
                            LoadOp::Clear(Color::TRANSPARENT)
                        },
                        store: StoreOp::Store,
                    },
                })
            })
            .collect();
        let depth = state.depth.create_view(&Default::default());
        let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
            label: Some("mesh view"),
            color_attachments: &attachments,
            depth_stencil_attachment: Some(RenderPassDepthStencilAttachment {
                view: &depth,
                depth_ops: Some(Operations {
                    load: if blend {
                        LoadOp::Load
                    } else {
                        LoadOp::Clear(1.)
                    },
                    store: StoreOp::Store,
                }),
                stencil_ops: None,
            }),
            ..Default::default()
        });
        pass.set_bind_group(
            2,
            state
                .shadows
                .as_ref()
                .map(|s| &s.group)
                .unwrap_or(&self.shadow_fallback),
            &[],
        );
        pass.set_bind_group(
            3,
            state
                .local_shadows
                .as_ref()
                .map(|s| &s.group)
                .unwrap_or(&self.local_shadow_fallback),
            &[],
        );
        for batch in state.batches.iter().filter(|b| b.blend == blend) {
            let material = &self.models[&batch.material_model].materials[batch.material];
            let geometry = &self.models[&batch.model].meshes[batch.mesh];
            let pipeline = usize::from(material.double_sided)
                + usize::from(batch.mirrored) * 6
                + if blend {
                    2
                } else if state.ao.is_some() {
                    4
                } else {
                    0
                };
            pass.set_pipeline(&self.pipelines[pipeline]);
            pass.set_bind_group(0, &batch.draw, &[]);
            pass.set_bind_group(1, &material.group, &[]);
            pass.set_index_buffer(geometry.indices.slice(..), wgpu::IndexFormat::Uint32);
            pass.draw_indexed_indirect(&batch.args, 0);
        }
    }
    pub(super) fn render(
        &mut self,
        id: u32,
        bytes: &[u8],
        width: u32,
        height: u32,
    ) -> Result<(TextureView, u64)> {
        let version = u32_at(bytes, 4)?;
        if u32_at(bytes, 0)? != 0x544D5348 || !(1..=2).contains(&version) || bytes.len() < 96 {
            bail!("invalid mesh frame");
        }
        let revision = u32_at(bytes, 8)?;
        let retained = u32_at(bytes, 12)?;
        if retained > 1 {
            bail!("invalid mesh frame mode");
        }
        let camera = &bytes[16..96];
        let mut payload = 96;
        let settings = if version == 2 {
            let length = u32_at(bytes, payload)? as usize;
            payload += 4;
            let settings = bytes
                .get(
                    payload
                        ..payload
                            .checked_add(length)
                            .context("mesh settings overflow")?,
                )
                .context("truncated mesh settings")?;
            payload = (payload + length).next_multiple_of(4);
            settings
        } else {
            &[]
        };
        if payload > bytes.len() {
            bail!("truncated mesh settings padding");
        }
        let lights = if version == 2 {
            let length = u32_at(bytes, payload)? as usize;
            payload += 4;
            let lights = bytes
                .get(payload..payload.checked_add(length).context("mesh light overflow")?)
                .context("truncated mesh lights")?;
            if !length.is_multiple_of(64) {
                bail!("invalid mesh light stride");
            }
            payload += length;
            &lights[..lights.len().min(256 * 64)]
        } else {
            &[]
        };

        for value in camera.as_chunks::<4>().0 {
            if !f32::from_ne_bytes(*value).is_finite() {
                bail!("nonfinite mesh camera");
            }
        }
        let mut state = self.views.remove(&id).unwrap_or_else(|| {
            self.generation += 1;
            ViewGpu {
                revision: 0,
                camera: Vec::new(),
                uniform: buffer(
                    &self.device,
                    camera,
                    BufferUsages::UNIFORM | BufferUsages::COPY_DST,
                ),
                palette: buffer(
                    &self.device,
                    &[],
                    BufferUsages::STORAGE | BufferUsages::COPY_DST,
                ),
                palette_data: Vec::new(),
                lighting: buffer(
                    &self.device,
                    bytemuck::cast_slice(&super::meshlighting::parameters(&[]).unwrap()),
                    BufferUsages::UNIFORM | BufferUsages::COPY_DST,
                ),
                settings: Vec::new(),
                lights: buffer(
                    &self.device,
                    &[0; 256 * 64],
                    BufferUsages::STORAGE | BufferUsages::COPY_DST,
                ),
                light_data: Vec::new(),
                light_info: buffer(
                    &self.device,
                    &[0; 16],
                    BufferUsages::UNIFORM | BufferUsages::COPY_DST,
                ),
                light_tiles: buffer(
                    &self.device,
                    &vec![0; width.div_ceil(16) as usize * height.div_ceil(16) as usize * 32],
                    BufferUsages::STORAGE,
                ),
                batches: Vec::new(),
                color: self.target(width, height, false),
                depth: self.target(width, height, true),
                generation: self.generation,
                shadows: None,
                ao: None,
                local_shadows: None,
                settings_json: serde_json::json!({}),
                environment: environment::View::new(self),
                transparent: None,
            }
        });
        let outcome = (|| -> Result<()> {
            let settings_changed = state.settings != settings;
            if settings_changed {
                state.settings_json = if settings.is_empty() {
                    serde_json::json!({})
                } else {
                    serde_json::from_slice(settings)?
                };
                let parameters = super::meshlighting::parameters(settings)?;
                self.queue
                    .write_buffer(&state.lighting, 0, bytemuck::cast_slice(&parameters));
                state.settings.clear();
                state.settings.extend_from_slice(settings);
            }
            let lights_changed = state.light_data != lights;
            if lights_changed {
                for value in lights.as_chunks::<4>().0 {
                    if !f32::from_ne_bytes(*value).is_finite() {
                        bail!("nonfinite mesh light");
                    }
                }
                for row in lights.as_chunks::<64>().0 {
                    let f =
                        |i: usize| f32::from_ne_bytes(row[i * 4..i * 4 + 4].try_into().unwrap());
                    if f(3) <= 0. || (4..8).any(|i| f(i) < 0.) || !(0.0..=1.0).contains(&f(13)) {
                        bail!("invalid mesh light range");
                    }
                }
                if !lights.is_empty() {
                    self.queue.write_buffer(&state.lights, 0, lights);
                }
                state.light_data.clear();
                state.light_data.extend_from_slice(lights);
            }
            let camera_changed = state.camera != camera;
            if camera_changed {
                self.queue.write_buffer(&state.uniform, 0, camera);
                state.camera = camera.to_vec();
            }
            let resized = state.color.width() != width || state.color.height() != height;
            if resized {
                state.color = self.target(width, height, false);
                state.depth = self.target(width, height, true);
                state.light_tiles = buffer(
                    &self.device,
                    &vec![0; width.div_ceil(16) as usize * height.div_ceil(16) as usize * 32],
                    BufferUsages::STORAGE,
                );
                self.generation += 1;
                state.generation = self.generation;
            }
            let environment_changed = if camera_changed || settings_changed || resized {
                state
                    .environment
                    .update(self, camera, &state.settings_json, width, height)?
            } else {
                false
            };
            if resized || environment_changed {
                for batch in &mut state.batches {
                    let geometry = &self.models[&batch.model].meshes[batch.mesh];
                    let pairs = [
                        (0, &geometry.vertices),
                        (1, &batch.instances),
                        (2, &state.palette),
                        (3, &batch.visible),
                        (6, &batch.info),
                        (7, &state.uniform),
                        (8, &state.lighting),
                        (9, &state.lights),
                        (10, &state.light_tiles),
                        (11, &state.light_info),
                        (14, &state.environment.uniform),
                    ];
                    let mut entries: Vec<_> = pairs
                        .iter()
                        .map(|(binding, b)| BindGroupEntry {
                            binding: *binding,
                            resource: b.as_entire_binding(),
                        })
                        .collect();
                    entries.push(BindGroupEntry {
                        binding: 12,
                        resource: BindingResource::TextureView(&state.environment.texture),
                    });
                    entries.push(BindGroupEntry {
                        binding: 13,
                        resource: BindingResource::Sampler(&self.sampler),
                    });
                    batch.draw = self.device.create_bind_group(&BindGroupDescriptor {
                        label: Some("mesh view bindings"),
                        layout: &self.draw_layout,
                        entries: &entries,
                    });
                }
            }
            if retained == 1 {
                if state.revision != revision || bytes.len() != payload {
                    bail!("mesh retained frame refers to missing generation");
                }
            } else {
                let count = u32_at(bytes, payload)? as usize;
                let palette_count = u32_at(bytes, payload + 4)? as usize;
                let end = (payload + 8)
                    .checked_add(count.checked_mul(128).context("mesh count overflow")?)
                    .context("mesh frame overflow")?;
                let palette_bytes = bytes.get(end..).context("truncated mesh instances")?;
                if palette_bytes.len() != palette_count * 4 {
                    bail!("invalid mesh palette length");
                }
                for value in palette_bytes.as_chunks::<4>().0 {
                    if !f32::from_ne_bytes(*value).is_finite() {
                        bail!("nonfinite mesh palette");
                    }
                }
                let palette_grew = palette_bytes.len() as u64 > state.palette.size();
                if palette_grew {
                    state.palette = self.device.create_buffer(&BufferDescriptor {
                        label: Some("mesh palettes"),
                        size: (palette_bytes.len() as u64).next_power_of_two(),
                        usage: BufferUsages::STORAGE | BufferUsages::COPY_DST,
                        mapped_at_creation: false,
                    });
                }
                if state.palette_data != palette_bytes {
                    if !palette_bytes.is_empty() {
                        self.queue.write_buffer(&state.palette, 0, palette_bytes);
                    }
                    state.palette_data.clear();
                    state.palette_data.extend_from_slice(palette_bytes);
                }
                let mut groups: std::collections::BTreeMap<BatchKey, BatchData> =
                    std::collections::BTreeMap::new();
                for row in bytes[payload + 8..end].as_chunks::<128>().0 {
                    let model = u32_at(row, 4)?;
                    let mesh = u32_at(row, 8)? as usize;
                    if mesh == 0 {
                        bail!("mesh index must be one based");
                    }
                    let material_model = match u32_at(row, 12)? {
                        0 => model,
                        id => id,
                    };
                    let material = u32_at(row, 16)? as usize;
                    let geometry = self
                        .models
                        .get(&model)
                        .context("mesh model is not resident")?
                        .meshes
                        .get(mesh - 1)
                        .context("mesh geometry missing")?;
                    self.models
                        .get(&material_model)
                        .context("material model missing")?
                        .materials
                        .get(material)
                        .context("mesh material missing")?;
                    for value in row[32..112].as_chunks::<4>().0 {
                        if !f32::from_ne_bytes(*value).is_finite() {
                            bail!("nonfinite mesh transform");
                        }
                    }
                    let skin = u32_at(row, 112)? as usize;
                    let joints = u32_at(row, 116)? as usize;
                    let morph = u32_at(row, 120)? as usize;
                    let weights = u32_at(row, 124)? as usize;
                    if skin + joints * 16 > palette_count
                        || morph + weights > palette_count
                        || weights > geometry.info[4] as usize
                    {
                        bail!("mesh palette exceeds storage");
                    }
                    if let Some(maximum) = geometry.max_joint {
                        if joints == 0 || maximum as usize >= joints {
                            bail!("mesh joint exceeds palette");
                        }
                    }
                    let f = |at: usize| f32::from_ne_bytes(row[at..at + 4].try_into().unwrap());
                    let mirrored = f(64) * f(68) * f(72) < 0.;
                    let blend =
                        f(92) < 1. || self.models[&material_model].materials[material].blend;
                    let group = groups
                        .entry((model, mesh - 1, material_model, material, mirrored, blend))
                        .or_default();
                    group.0.extend_from_slice(&row[32..]);
                    group.1.push(u32_at(row, 0)?);
                }
                let mut resident: HashMap<_, _> = state
                    .batches
                    .drain(..)
                    .map(|b| {
                        (
                            (
                                b.model,
                                b.mesh,
                                b.material_model,
                                b.material,
                                b.mirrored,
                                b.blend,
                            ),
                            b,
                        )
                    })
                    .collect();
                for ((model, mesh, material_model, material, mirrored, blend), (data, entities)) in
                    groups
                {
                    if !palette_grew {
                        if let Some(mut batch) = resident.remove(&(
                            model,
                            mesh,
                            material_model,
                            material,
                            mirrored,
                            blend,
                        )) {
                            if batch.data.len() == data.len() {
                                if batch.data != data {
                                    self.queue.write_buffer(&batch.instances, 0, &data);
                                    batch.data = data;
                                }
                                batch.entities = entities;
                                state.batches.push(batch);
                                continue;
                            }
                        }
                    }
                    let geometry = &self.models[&model].meshes[mesh];
                    let count = (data.len() / 96) as u32;
                    let mut info = geometry.info;
                    info[6] = count;
                    info[7] = count.div_ceil(256);
                    let instances = buffer(
                        &self.device,
                        &data,
                        BufferUsages::STORAGE | BufferUsages::COPY_DST,
                    );
                    let make = |size, usage| {
                        self.device.create_buffer(&BufferDescriptor {
                            label: Some("mesh visibility"),
                            size,
                            usage,
                            mapped_at_creation: false,
                        })
                    };
                    let visible = make(u64::from(count) * 8, BufferUsages::STORAGE);
                    let scan = make(u64::from(count + info[7]) * 4, BufferUsages::STORAGE);
                    let args = make(20, BufferUsages::STORAGE | BufferUsages::INDIRECT);
                    let info_buffer = buffer(
                        &self.device,
                        bytemuck::cast_slice(&info),
                        BufferUsages::UNIFORM,
                    );
                    fn entries(pairs: Vec<(u32, &Buffer)>) -> Vec<BindGroupEntry<'_>> {
                        pairs
                            .into_iter()
                            .map(|(binding, buffer)| BindGroupEntry {
                                binding,
                                resource: buffer.as_entire_binding(),
                            })
                            .collect()
                    }
                    let draw = self.device.create_bind_group(&BindGroupDescriptor {
                        label: Some("mesh draw"),
                        layout: &self.draw_layout,
                        entries: &{
                            let mut values = entries(vec![
                                (0, &geometry.vertices),
                                (1, &instances),
                                (2, &state.palette),
                                (3, &visible),
                                (6, &info_buffer),
                                (7, &state.uniform),
                                (8, &state.lighting),
                                (9, &state.lights),
                                (10, &state.light_tiles),
                                (11, &state.light_info),
                                (14, &state.environment.uniform),
                            ]);
                            values.push(BindGroupEntry {
                                binding: 12,
                                resource: BindingResource::TextureView(&state.environment.texture),
                            });
                            values.push(BindGroupEntry {
                                binding: 13,
                                resource: BindingResource::Sampler(&self.sampler),
                            });
                            values
                        },
                    });
                    let cull = self.device.create_bind_group(&BindGroupDescriptor {
                        label: Some("mesh cull"),
                        layout: &self.cull_layout,
                        entries: &entries(vec![
                            (1, &instances),
                            (3, &visible),
                            (4, &scan),
                            (5, &args),
                            (6, &info_buffer),
                            (7, &state.uniform),
                        ]),
                    });
                    state.batches.push(BatchGpu {
                        model,
                        mesh,
                        material_model,
                        material,
                        instances,
                        data,
                        entities,
                        mirrored,
                        visible,
                        scan,
                        args,
                        info: info_buffer,
                        draw,
                        cull,
                        count,
                        blend,
                    });
                }
                state.revision = revision;
            }
            // A stationary view is already complete, including its lighting and AO.
            if retained == 1 && !camera_changed && !settings_changed && !lights_changed && !resized
            {
                return Ok(());
            }
            let mut encoder = self
                .device
                .create_command_encoder(&CommandEncoderDescriptor {
                    label: Some("mesh view"),
                });
            let options = shadows::Options::parse(settings, width, height)?;
            let shadows_changed = options.enabled
                && (settings_changed
                    || camera_changed
                    || resized
                    || retained == 0
                    || state.shadows.is_none());
            if options.enabled {
                let mut maps = match state.shadows.take() {
                    Some(maps) if maps.size() == options.size => maps,
                    _ => shadows::Maps::new(self, options.size, &self.shader)?,
                };
                if shadows_changed {
                    maps.update(
                        self,
                        &state,
                        &options,
                        camera,
                        &super::meshlighting::parameters(settings)?,
                        &mut encoder,
                    )?;
                }
                state.shadows = Some(maps);
            } else {
                state.shadows = None;
            }
            let local_enabled = state
                .settings_json
                .get("localShadows")
                .map(|v| v.as_bool().context("localShadows must be boolean"))
                .transpose()?
                .unwrap_or(false);
            let local_changed = local_enabled
                && (settings_changed
                    || lights_changed
                    || retained == 0
                    || state.local_shadows.is_none());
            if local_enabled {
                let size = state
                    .settings_json
                    .get("localShadowSize")
                    .map(index)
                    .unwrap_or(Ok(256))? as u32;
                let capacity = state
                    .settings_json
                    .get("localShadowCapacity")
                    .map(index)
                    .unwrap_or(Ok(4))? as u32;
                let mut maps = match state.local_shadows.take() {
                    Some(maps) if maps.size == size && maps.capacity == capacity => maps,
                    _ => localshadows::State::new(self, size, capacity)?,
                };
                if local_changed {
                    maps.update(self, &state, &state.settings_json, &mut encoder)?;
                }
                state.local_shadows = Some(maps);
            } else if state.local_shadows.take().is_some() && !state.light_data.is_empty() {
                self.queue.write_buffer(&state.lights, 0, &state.light_data);
            }
            if lights_changed || camera_changed || resized || retained == 0 {
                self.queue.write_buffer(
                    &state.light_info,
                    0,
                    bytemuck::cast_slice(&[
                        lights.len() as u32 / 64,
                        width,
                        height,
                        width.div_ceil(16),
                    ]),
                );
                let group = self.device.create_bind_group(&BindGroupDescriptor {
                    label: Some("mesh light bins"),
                    layout: &self.light_bins.get_bind_group_layout(0),
                    entries: &[
                        BindGroupEntry {
                            binding: 0,
                            resource: state.lights.as_entire_binding(),
                        },
                        BindGroupEntry {
                            binding: 1,
                            resource: state.light_tiles.as_entire_binding(),
                        },
                        BindGroupEntry {
                            binding: 2,
                            resource: state.light_info.as_entire_binding(),
                        },
                        BindGroupEntry {
                            binding: 3,
                            resource: state.uniform.as_entire_binding(),
                        },
                    ],
                });
                let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor {
                    label: Some("mesh light bins"),
                    timestamp_writes: None,
                });
                pass.set_pipeline(&self.light_bins);
                pass.set_bind_group(0, &group, &[]);
                pass.dispatch_workgroups(
                    (width.div_ceil(16) * height.div_ceil(16)).div_ceil(64),
                    1,
                    1,
                );
            }
            if retained == 0 || camera_changed || resized || shadows_changed || local_changed {
                for batch in &state.batches {
                    let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor {
                        label: Some("mesh cull"),
                        timestamp_writes: None,
                    });
                    pass.set_bind_group(0, &batch.cull, &[]);
                    if batch.count == 1 {
                        pass.set_pipeline(&self.cull[3]);
                        pass.dispatch_workgroups(1, 1, 1);
                    } else {
                        pass.set_pipeline(&self.cull[0]);
                        pass.dispatch_workgroups(batch.count.div_ceil(256), 1, 1);
                        pass.set_pipeline(&self.cull[1]);
                        pass.dispatch_workgroups(1, 1, 1);
                        pass.set_pipeline(&self.cull[2]);
                        pass.dispatch_workgroups(batch.count.div_ceil(256), 1, 1);
                    }
                }
            }
            let ssao = state
                .settings_json
                .get("ssao")
                .map(|v| v.as_bool().context("ssao must be boolean"))
                .transpose()?
                .unwrap_or(false);
            if ssao {
                let scale = state
                    .settings_json
                    .get("ssaoScale")
                    .map(number)
                    .unwrap_or(Ok(0.5))?;
                if resized || state.ao.as_ref().is_none_or(|a| a.scale != scale) {
                    state.ao = Some(ao::State::new(self, &state, scale)?);
                }
            } else {
                state.ao = None;
            }
            if state.environment.visible {
                self.sky
                    .render(&state.environment, &state.color, &mut encoder);
            }
            self.draw(&state, &mut encoder, false);
            if let Some(ao) = &mut state.ao {
                ao.render(
                    self,
                    &mut encoder,
                    &state.color,
                    camera,
                    &state.settings_json,
                )?;
            }
            if state.batches.iter().any(|b| b.blend) {
                let heap = match self.transparent.take() {
                    Some(heap) => heap,
                    None => transparent::Heap::new(self)?,
                };
                let previous = state.transparent.take();
                let alpha =
                    transparent::State::prepare(self, &heap, &state, previous, retained == 0)?;
                alpha.sort(&heap, &mut encoder);
                alpha.draw(self, &heap, &state, &mut encoder);
                state.transparent = Some(alpha);
                self.transparent = Some(heap);
            } else {
                state.transparent = None;
            }
            self.queue.submit([encoder.finish()]);
            Ok(())
        })();
        let result = (
            state.color.create_view(&Default::default()),
            state.generation,
        );
        self.views.insert(id, state);
        outcome?;
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn mesh_frame(retained: bool, x: f32) -> Vec<u8> {
        let mut bytes = Vec::new();
        for v in [0x544D5348_u32, 1, 1, u32::from(retained)] {
            bytes.extend_from_slice(&v.to_ne_bytes());
        }
        let f = 1.7320508_f32;
        let z = 100_f32 / (0.1 - 100.);
        let offset = 100_f32 * 0.1 / (0.1 - 100.);
        for v in [
            f * 360. / 640.,
            0.,
            0.,
            0.,
            0.,
            f,
            0.,
            0.,
            0.,
            0.,
            z,
            -1.,
            -x * f * 360. / 640.,
            0.,
            -4. * z + offset,
            4.,
            x,
            0.,
            4.,
            0.,
        ] {
            bytes.extend_from_slice(&v.to_ne_bytes());
        }
        if retained {
            return bytes;
        }
        for v in [1_u32, 17, 1, 1, 1, 1, 0, 0, 0, 0] {
            bytes.extend_from_slice(&v.to_ne_bytes());
        }
        for v in [
            0_f32, 0., 0., 0., 0., 0., 0., 1., 1., 1., 1., 0., 1., 1., 1., 1., 0., 0., 0., 2.,
        ] {
            bytes.extend_from_slice(&v.to_ne_bytes());
        }
        for v in [0_u32, 1, 16, 1] {
            bytes.extend_from_slice(&v.to_ne_bytes());
        }
        for v in [
            1_f32, 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0.5,
        ] {
            bytes.extend_from_slice(&v.to_ne_bytes());
        }
        bytes
    }
    fn envelope(mesh: &[u8]) -> Vec<u8> {
        let mut bytes = Vec::new();
        for v in [super::super::views::MAGIC, 2, 1, 640, 360, 1, 1] {
            bytes.extend_from_slice(&v.to_ne_bytes());
        }
        for v in [0_f32, 0., 1., 1.] {
            bytes.extend_from_slice(&v.to_ne_bytes());
        }
        let scene = crate::packet::tests::PacketBuilder::new()
            .graph(crate::graph::tests::deferred())
            .build();
        bytes.extend_from_slice(&(scene.len() as u32).to_ne_bytes());
        bytes.extend(scene);
        bytes.extend_from_slice(&(mesh.len() as u32).to_ne_bytes());
        bytes.extend(mesh);
        bytes
    }
    #[test]
    fn draws_skinned_morphed_geometry_and_reculls_a_retained_camera() {
        let probe = Instance::new(InstanceDescriptor::new_without_display_handle());
        if pollster::block_on(probe.request_adapter(&wgpu::RequestAdapterOptions::default()))
            .is_err()
        {
            return;
        }
        let mut graphics = Graphics::offscreen(640, 360).unwrap();
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../tests/assets/models/posed.gltf");
        let model = tecs_assets::model::load_packet(&path).unwrap();
        graphics.upload_model(1, &model).unwrap();
        graphics.request_capture();
        graphics.render(&envelope(&mesh_frame(false, 0.))).unwrap();
        let first = graphics.take_capture().unwrap();
        let at = (180 * 640 + 320) * 4;
        assert!(
            first.rgba[at] > 100,
            "3D geometry reaches the shared compositor: {:?}",
            &first.rgba[at..at + 4]
        );
        graphics.request_capture();
        graphics.render(&envelope(&mesh_frame(true, 0.))).unwrap();
        let retained = graphics.take_capture().unwrap();
        assert_eq!(first.rgba, retained.rgba);
        graphics.request_capture();
        graphics.render(&envelope(&mesh_frame(true, 100.))).unwrap();
        let moved = graphics.take_capture().unwrap();
        assert!(
            moved.rgba[at] < 100,
            "moving the camera culls retained geometry"
        );
    }
    fn configured_frame(settings: &str, lights: &[f32]) -> Vec<u8> {
        let frame = mesh_frame(false, 0.);
        let mut bytes = frame[..96].to_vec();
        bytes[4..8].copy_from_slice(&2_u32.to_ne_bytes());
        bytes.extend_from_slice(&(settings.len() as u32).to_ne_bytes());
        bytes.extend_from_slice(settings.as_bytes());
        bytes.resize(bytes.len().next_multiple_of(4), 0);
        bytes.extend_from_slice(&(lights.len() as u32 * 4).to_ne_bytes());
        bytes.extend_from_slice(bytemuck::cast_slice(lights));
        bytes.extend_from_slice(&frame[96..]);
        bytes
    }
    #[test]
    fn renders_many_geometry_batches_with_directional_shadows() {
        let probe = Instance::new(InstanceDescriptor::new_without_display_handle());
        if pollster::block_on(probe.request_adapter(&wgpu::RequestAdapterOptions::default()))
            .is_err()
        {
            return;
        }
        let mut graphics = Graphics::offscreen(640, 360).unwrap();
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../tests/assets/models/posed.gltf");
        let source = tecs_assets::model::load_packet(&path).unwrap();
        let length = u32_at(&source, 0).unwrap() as usize;
        let mut metadata: Value = serde_json::from_slice(&source[4..4 + length]).unwrap();
        const COUNT: usize = 768;
        let geometry = metadata["meshes"][0].clone();
        metadata["meshes"] = Value::Array(vec![geometry; COUNT]);
        let json = serde_json::to_vec(&metadata).unwrap();
        let mut model = (json.len() as u32).to_ne_bytes().to_vec();
        model.extend(json);
        model.resize(model.len().next_multiple_of(4), 0);
        model.extend_from_slice(&source[(4 + length).next_multiple_of(4)..]);
        graphics.upload_model(1, &model).unwrap();
        let source = configured_frame(r#"{"shadows":true,"shadowScale":0.25}"#, &[]);
        let offset = source.len() - (8 + 128 + 17 * 4);
        let mut frame = source[..offset].to_vec();
        frame.extend((COUNT as u32).to_ne_bytes());
        frame.extend(17_u32.to_ne_bytes());
        for index in 0..COUNT {
            let mut row = source[offset + 8..offset + 8 + 128].to_vec();
            row[..4].copy_from_slice(&(index as u32 + 1).to_ne_bytes());
            row[8..12].copy_from_slice(&(index as u32 + 1).to_ne_bytes());
            frame.extend(row);
        }
        frame.extend_from_slice(&source[source.len() - 17 * 4..]);
        graphics.request_capture();
        graphics.render(&envelope(&frame)).unwrap();
        let capture = graphics.take_capture().unwrap();
        assert!(capture.rgba[(180 * 640 + 320) * 4] > 50);
        assert_eq!(
            graphics.mesh_renderer.as_ref().unwrap().views[&1]
                .batches
                .len(),
            COUNT
        );
    }

    #[test]
    fn lights_fog_and_pose_updates_preserve_resident_buffers() {
        let probe = Instance::new(InstanceDescriptor::new_without_display_handle());
        if pollster::block_on(probe.request_adapter(&wgpu::RequestAdapterOptions::default()))
            .is_err()
        {
            return;
        }
        let mut graphics = Graphics::offscreen(640, 360).unwrap();
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../tests/assets/models/posed.gltf");
        graphics
            .upload_model(1, &tecs_assets::model::load_packet(&path).unwrap())
            .unwrap();
        let lights = [
            0., 0., 3., 20., 0., 1., 0., 80., 0., 0., -1., -1., 1., 0., 0., 0.,
        ];
        graphics.request_capture();
        let mut packet = configured_frame(r#"{"intensity":0,"ambient":0}"#, &lights);
        graphics.render(&envelope(&packet)).unwrap();
        let lit = graphics.take_capture().unwrap();
        let at = (180 * 640 + 320) * 4;
        assert!(
            lit.rgba[at + 1] > lit.rgba[at] + 30,
            "point light must reach the mesh: {:?}",
            &lit.rgba[at..at + 4]
        );
        let renderer = graphics.mesh_renderer.as_ref().unwrap();
        let state = &renderer.views[&1];
        let instances = state.batches[0].instances.clone();
        let palette = state.palette.clone();
        // Change only the morph pose. Neither the instance nor palette allocation should move.
        let end = packet.len();
        packet[end - 4..].copy_from_slice(&0.75_f32.to_ne_bytes());
        graphics.render(&envelope(&packet)).unwrap();
        let renderer = graphics.mesh_renderer.as_ref().unwrap();
        let state = &renderer.views[&1];
        assert_eq!(instances, state.batches[0].instances);
        assert_eq!(palette, state.palette);
        graphics.request_capture();
        graphics
            .render(&envelope(&configured_frame(
                r#"{"intensity":0,"ambient":0,"fog":true,"fogStart":0,"fogFinish":1,"fogR":1}"#,
                &[],
            )))
            .unwrap();
        let fog = graphics.take_capture().unwrap();
        assert!(fog.rgba[at] > 200 && fog.rgba[at + 1] < 10);
        graphics
            .render(&envelope(&configured_frame(
                r#"{"shadows":true,"shadowScale":0.25}"#,
                &[],
            )))
            .unwrap();
        assert!(graphics.mesh_renderer.as_ref().unwrap().views[&1]
            .shadows
            .is_some());
        graphics
            .render(&envelope(&configured_frame(r#"{"shadows":false}"#, &[])))
            .unwrap();
        assert!(graphics.mesh_renderer.as_ref().unwrap().views[&1]
            .shadows
            .is_none());
        graphics
            .render(&envelope(&configured_frame(
                r#"{"ssao":true,"ssaoScale":0.5}"#,
                &[],
            )))
            .unwrap();
        assert!(graphics.mesh_renderer.as_ref().unwrap().views[&1]
            .ao
            .is_some());
        let mut shadow_light = lights;
        shadow_light[14] = 1.;
        graphics
            .render(&envelope(&configured_frame(
                r#"{"localShadows":true,"localShadowSize":64}"#,
                &shadow_light,
            )))
            .unwrap();
        assert!(graphics.mesh_renderer.as_ref().unwrap().views[&1]
            .local_shadows
            .is_some());
        let colors = [
            [255, 0, 0, 255],
            [0, 255, 0, 255],
            [0, 0, 255, 255],
            [255, 255, 0, 255],
            [0, 255, 255, 255],
            [255, 0, 255, 255],
        ];
        let mut pixels = Vec::new();
        let mut images = Vec::new();
        for color in colors {
            images.push(serde_json::json!({"width":2,"height":2,"pixels":[pixels.len(),16]}));
            for _ in 0..4 {
                pixels.extend_from_slice(&color);
            }
        }
        let metadata = serde_json::to_vec(
            &serde_json::json!({"version":1,"environment":"test sky","images":images}),
        )
        .unwrap();
        let mut upload = (metadata.len() as u32).to_ne_bytes().to_vec();
        upload.extend(metadata);
        upload.resize(upload.len().next_multiple_of(4), 0);
        upload.extend(pixels);
        graphics.upload_model(2, &upload).unwrap();
        graphics.request_capture();
        graphics
            .render(&envelope(&configured_frame(
                r#"{"environment":"test sky","intensity":0,"ambient":0}"#,
                &[],
            )))
            .unwrap();
        let sky = graphics.take_capture().unwrap();
        let edge = (180 * 640 + 10) * 4;
        assert!(
            sky.rgba[edge] > sky.rgba[edge + 1] + 30
                && sky.rgba[edge + 2] > sky.rgba[edge + 1] + 30,
            "negative Z sky face: {:?}",
            &sky.rgba[edge..edge + 4]
        );
        assert!(
            sky.rgba[at] > 20 || sky.rgba[at + 1] > 20 || sky.rgba[at + 2] > 20,
            "the PBR mesh reflects the environment"
        );
        graphics.request_capture();
        graphics.render(&envelope(&configured_frame(r#"{"environment":"test sky","environmentRotation":3.141592653589793,"intensity":0,"ambient":0}"#,&[]))).unwrap();
        let rotated = graphics.take_capture().unwrap();
        assert!(
            rotated.rgba[edge + 1] > rotated.rgba[edge] + 30,
            "rotated sky selects positive Z"
        );
    }

    #[test]
    fn globally_sorts_interleaved_material_batches_and_resorts_a_retained_camera() {
        let probe = Instance::new(InstanceDescriptor::new_without_display_handle());
        if pollster::block_on(probe.request_adapter(&wgpu::RequestAdapterOptions::default()))
            .is_err()
        {
            return;
        }
        let mut graphics = Graphics::offscreen(640, 360).unwrap();
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../tests/assets/models/posed.gltf");
        let original = tecs_assets::model::load_packet(&path).unwrap();
        let length = u32_at(&original, 0).unwrap() as usize;
        let mut metadata: Value = serde_json::from_slice(&original[4..4 + length]).unwrap();
        metadata["materials"] = serde_json::json!([{"name":"unlit","model":1,"baseColor":[1,1,1,1],"emission":[0,0,0],"metallic":0,"roughness":1,"normalScale":1,"occlusionStrength":1,"alphaMode":0,"alphaCutoff":0.5,"doubleSided":true,"images":[0,0,0,0,0]}]);
        let metadata = serde_json::to_vec(&metadata).unwrap();
        let mut model = (metadata.len() as u32).to_ne_bytes().to_vec();
        model.extend(metadata);
        model.resize(model.len().next_multiple_of(4), 0);
        model.extend_from_slice(&original[(4 + length).next_multiple_of(4)..]);
        graphics.upload_model(1, &model).unwrap();
        graphics.upload_model(2, &model).unwrap();
        let original = mesh_frame(false, 0.);
        let mut packet = original[..104].to_vec();
        packet[96..100].copy_from_slice(&3_u32.to_ne_bytes());
        for (entity, model, z, color) in [
            (1_u32, 1_u32, 1_f32, [1_f32, 0., 0., 0.5]),
            (2, 1, -1., [0., 0., 1., 0.5]),
            (3, 2, 0., [0., 1., 0., 0.5]),
        ] {
            let mut row = original[104..232].to_vec();
            row[0..4].copy_from_slice(&entity.to_ne_bytes());
            row[4..8].copy_from_slice(&model.to_ne_bytes());
            row[12..16].copy_from_slice(&model.to_ne_bytes());
            row[16..20].copy_from_slice(&1_u32.to_ne_bytes());
            row[40..44].copy_from_slice(&z.to_ne_bytes());
            row[80..96].copy_from_slice(bytemuck::cast_slice(&color));
            packet.extend(row);
        }
        packet.extend_from_slice(&original[232..]);
        graphics.request_capture();
        graphics.render(&envelope(&packet)).unwrap();
        let first = graphics.take_capture().unwrap();
        let at = (180 * 640 + 320) * 4;
        let pixel = &first.rgba[at..at + 4];
        assert!(
            pixel[0] > pixel[1] && pixel[1] > pixel[2],
            "red then green then blue across material batches: {pixel:?}"
        );
        let mut retained = mesh_frame(true, 0.);
        let eye = glam::Vec3::new(0., 0., -4.);
        let matrix = glam::camera::rh::proj::directx::perspective(
            std::f32::consts::FRAC_PI_3,
            640. / 360.,
            0.1,
            100.,
        ) * glam::camera::rh::view::look_at_mat4(eye, glam::Vec3::ZERO, glam::Vec3::Y);
        retained[16..80].copy_from_slice(bytemuck::cast_slice(&matrix.to_cols_array()));
        retained[80..92].copy_from_slice(bytemuck::cast_slice(&eye.to_array()));
        graphics.request_capture();
        graphics.render(&envelope(&retained)).unwrap();
        let second = graphics.take_capture().unwrap();
        let pixel = &second.rgba[at..at + 4];
        assert!(
            pixel[2] > pixel[1] && pixel[1] > pixel[0],
            "the retained camera reverses global transparency order: {pixel:?}"
        );
    }
}
