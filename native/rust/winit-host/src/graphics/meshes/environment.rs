//! The original six-face environment and analytic split-sum BRDF.
use super::*;

pub(super) fn upload(
    device: &Device,
    queue: &Queue,
    metadata: &Value,
    data: &[u8],
) -> Result<TextureView> {
    let images = array(metadata, "images")?;
    if images.len() != 6 {
        bail!("an environment needs six images");
    }
    let size = index(&images[0]["width"])? as u32;
    if size == 0 || size > device.limits().max_texture_dimension_2d {
        bail!("environment face size exceeds device limits");
    }
    let texture = device.create_texture(&TextureDescriptor {
        label: Some("mesh environment"),
        size: Extent3d {
            width: size,
            height: size,
            depth_or_array_layers: 6,
        },
        mip_level_count: size.ilog2() + 1,
        sample_count: 1,
        dimension: TextureDimension::D2,
        format: TextureFormat::Rgba8UnormSrgb,
        usage: TextureUsages::TEXTURE_BINDING
            | TextureUsages::RENDER_ATTACHMENT
            | TextureUsages::COPY_DST,
        view_formats: &[],
    });
    for (layer, image) in images.iter().enumerate() {
        let pixels = stream(data, &image["pixels"])?;
        if index(&image["width"])? != size as usize
            || index(&image["height"])? != size as usize
            || pixels.len() != size as usize * size as usize * 4
        {
            bail!("environment faces must be equally sized RGBA squares");
        }
        queue.write_texture(
            TexelCopyTextureInfo {
                texture: &texture,
                mip_level: 0,
                origin: Origin3d {
                    x: 0,
                    y: 0,
                    z: layer as u32,
                },
                aspect: TextureAspect::All,
            },
            pixels,
            TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(size * 4),
                rows_per_image: Some(size),
            },
            Extent3d {
                width: size,
                height: size,
                depth_or_array_layers: 1,
            },
        );
    }
    super::super::modeltextures::generate_mips(device, queue, &texture);
    Ok(texture.create_view(&TextureViewDescriptor {
        dimension: Some(TextureViewDimension::D2Array),
        ..Default::default()
    }))
}
pub(super) fn fallback(device: &Device, queue: &Queue) -> TextureView {
    let images: Vec<_> = (0..6)
        .map(|i| serde_json::json!({"width":1,"height":1,"pixels":[i*4,4]}))
        .collect();
    upload(
        device,
        queue,
        &serde_json::json!({"images":images}),
        &[0; 24],
    )
    .unwrap()
}

pub(super) struct Sky {
    layout: BindGroupLayout,
    pipeline: RenderPipeline,
}
impl Sky {
    pub fn new(device: &Device) -> Self {
        let layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("mesh sky"),
            entries: &[
                BindGroupLayoutEntry {
                    binding: 0,
                    visibility: ShaderStages::FRAGMENT,
                    ty: BindingType::Texture {
                        sample_type: TextureSampleType::Float { filterable: true },
                        view_dimension: TextureViewDimension::D2Array,
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
                    ty: BindingType::Buffer {
                        ty: BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
            ],
        });
        let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
            label: Some("mesh sky"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let source = format!(
            "{}\n{}",
            include_str!("../../../../../../assets/shaders/wgsl/meshenvironment.wgsl"),
            r#"
            struct Environment { inverse:mat4x4<f32>,camera:vec4<f32>,tuning:vec4<f32>,size:vec4<f32>, }
            @group(0) @binding(0) var environmentMap:texture_2d_array<f32>;
            @group(0) @binding(1) var environmentSampler:sampler;
            @group(0) @binding(2) var<uniform> environment:Environment;
            @vertex fn vertexMain(@builtin(vertex_index) i:u32)->@builtin(position) vec4<f32> {
                let uv=vec2<f32>(f32((i<<1u)&2u),f32(i&2u));return vec4<f32>(uv*2.0-1.0,0.0,1.0);
            }
            @fragment fn fragmentMain(@builtin(position) p:vec4<f32>)->@location(0) vec4<f32> {
                let uv=p.xy/environment.size.xy;
                let world=environment.inverse*vec4<f32>(uv.x*2.0-1.0,1.0-uv.y*2.0,1.0,1.0);
                let direction=normalize(world.xyz/world.w-environment.camera.xyz);
                return vec4<f32>(environmentSample(direction,0.0,environment.tuning.z)*environment.tuning.y,1.0);
            }
        "#
        );
        let shader = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("mesh sky"),
            source: ShaderSource::Wgsl(Cow::Owned(source)),
        });
        let pipeline = device.create_render_pipeline(&RenderPipelineDescriptor {
            label: Some("mesh sky"),
            layout: Some(&pipeline_layout),
            vertex: VertexState {
                module: &shader,
                entry_point: Some("vertexMain"),
                compilation_options: Default::default(),
                buffers: &[],
            },
            fragment: Some(FragmentState {
                module: &shader,
                entry_point: Some("fragmentMain"),
                compilation_options: Default::default(),
                targets: &[Some(ColorTargetState {
                    format: TextureFormat::Rgba16Float,
                    blend: None,
                    write_mask: ColorWrites::ALL,
                })],
            }),
            primitive: Default::default(),
            depth_stencil: None,
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        });
        Self { layout, pipeline }
    }
    pub fn render(&self, state: &View, color: &wgpu::Texture, encoder: &mut wgpu::CommandEncoder) {
        let view = color.create_view(&Default::default());
        let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
            label: Some("mesh sky"),
            color_attachments: &[Some(RenderPassColorAttachment {
                view: &view,
                depth_slice: None,
                resolve_target: None,
                ops: Operations {
                    load: LoadOp::Clear(Color::TRANSPARENT),
                    store: StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        pass.set_pipeline(&self.pipeline);
        pass.set_bind_group(0, &state.group, &[]);
        pass.draw(0..3, 0..1);
    }
}
pub(super) struct View {
    pub texture: TextureView,
    pub uniform: Buffer,
    pub visible: bool,
    group: BindGroup,
}
impl View {
    fn bind(renderer: &Renderer, texture: &TextureView, uniform: &Buffer) -> BindGroup {
        renderer.device.create_bind_group(&BindGroupDescriptor {
            label: Some("mesh environment"),
            layout: &renderer.sky.layout,
            entries: &[
                BindGroupEntry {
                    binding: 0,
                    resource: BindingResource::TextureView(texture),
                },
                BindGroupEntry {
                    binding: 1,
                    resource: BindingResource::Sampler(&renderer.sampler),
                },
                BindGroupEntry {
                    binding: 2,
                    resource: uniform.as_entire_binding(),
                },
            ],
        })
    }
    pub fn new(renderer: &Renderer) -> Self {
        let texture = renderer.environment_fallback.clone();
        let uniform = buffer(
            &renderer.device,
            &[0; 112],
            BufferUsages::UNIFORM | BufferUsages::COPY_DST,
        );
        let group = Self::bind(renderer, &texture, &uniform);
        Self {
            texture,
            uniform,
            visible: false,
            group,
        }
    }
    pub fn update(
        &mut self,
        renderer: &Renderer,
        camera: &[u8],
        settings: &Value,
        width: u32,
        height: u32,
    ) -> Result<bool> {
        let texture = match settings.get("environment") {
            None | Some(Value::Null) => &renderer.environment_fallback,
            Some(name) => renderer
                .environments
                .get(name.as_str().context("environment name must be a string")?)
                .context("environment is not resident; load its faces first")?,
        };
        let enabled = texture != &renderer.environment_fallback;
        let number =
            |key: &str, default: f32| settings.get(key).map(super::number).unwrap_or(Ok(default));
        let intensity = number("environmentIntensity", 1.)?;
        let sky = number("skyboxIntensity", 1.)?;
        let rotation = number("environmentRotation", 0.)?;
        if intensity < 0. || sky < 0. {
            bail!("environment intensity must be non-negative");
        }
        let words: Vec<f32> = camera
            .as_chunks::<4>()
            .0
            .iter()
            .map(|v| f32::from_ne_bytes(*v))
            .collect();
        let inverse = glam::Mat4::from_cols_array(words[..16].try_into()?).inverse();
        if !inverse.is_finite() {
            bail!("singular environment camera");
        }
        let mut params = inverse.to_cols_array().to_vec();
        params.extend_from_slice(&words[16..20]);
        params.extend_from_slice(&[
            if enabled { intensity } else { 0. },
            if enabled { sky } else { 0. },
            rotation,
            0.,
        ]);
        params.extend_from_slice(&[width as f32, height as f32, 0., 0.]);
        renderer
            .queue
            .write_buffer(&self.uniform, 0, bytemuck::cast_slice(&params));
        self.visible = enabled && sky > 0.;
        let changed = texture != &self.texture;
        if changed {
            self.texture = texture.clone();
            self.group = Self::bind(renderer, texture, &self.uniform);
        }
        Ok(changed)
    }
}
