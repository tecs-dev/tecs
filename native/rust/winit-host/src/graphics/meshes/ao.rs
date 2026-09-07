//! Mesh-only ambient occlusion, allocated only for a view which enables it.
use super::*;

pub(super) struct State {
    pub scale: f32,
    pub normal: wgpu::Texture,
    pub ambient: wgpu::Texture,
    targets: [wgpu::Texture; 4],
    pipelines: [RenderPipeline; 4],
    groups: [BindGroup; 4],
    uniform: Buffer,
    parameters: Vec<f32>,
}
impl State {
    pub fn new(renderer: &Renderer, state: &ViewGpu, scale: f32) -> Result<Self> {
        let device = &renderer.device;
        let width = state.color.width();
        let height = state.color.height();
        if !scale.is_finite() || scale <= 0. || scale > 1. {
            bail!("SSAO scale must be positive and no greater than one");
        }
        let make = |w, h, format, copy| {
            device.create_texture(&TextureDescriptor {
                label: Some("mesh ambient occlusion"),
                size: Extent3d {
                    width: w,
                    height: h,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: TextureDimension::D2,
                format,
                usage: TextureUsages::RENDER_ATTACHMENT
                    | TextureUsages::TEXTURE_BINDING
                    | if copy {
                        TextureUsages::COPY_SRC
                    } else {
                        TextureUsages::empty()
                    },
                view_formats: &[],
            })
        };
        let normal = make(width, height, TextureFormat::Rgba16Float, false);
        let ambient = make(width, height, TextureFormat::Rgba16Float, false);
        let w = (width as f32 * scale).round().max(1.) as u32;
        let h = (height as f32 * scale).round().max(1.) as u32;
        let targets = std::array::from_fn(|i| {
            if i == 3 {
                make(width, height, TextureFormat::Rgba16Float, true)
            } else {
                make(w, h, TextureFormat::R16Float, false)
            }
        });
        let uniform = buffer(
            device,
            &[0; 160],
            BufferUsages::UNIFORM | BufferUsages::COPY_DST,
        );
        let mut entries = Vec::new();
        for binding in [0, 1, 2, 5, 6] {
            entries.push(BindGroupLayoutEntry {
                binding,
                visibility: ShaderStages::FRAGMENT,
                ty: BindingType::Texture {
                    sample_type: if binding == 1 {
                        TextureSampleType::Depth
                    } else {
                        TextureSampleType::Float { filterable: true }
                    },
                    view_dimension: TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            });
        }
        entries.push(BindGroupLayoutEntry {
            binding: 3,
            visibility: ShaderStages::FRAGMENT,
            ty: BindingType::Sampler(SamplerBindingType::Filtering),
            count: None,
        });
        entries.push(BindGroupLayoutEntry {
            binding: 4,
            visibility: ShaderStages::FRAGMENT,
            ty: BindingType::Buffer {
                ty: BufferBindingType::Uniform,
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        });
        let layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("mesh SSAO"),
            entries: &entries,
        });
        let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
            label: Some("mesh SSAO"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let shader = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("mesh SSAO"),
            source: ShaderSource::Wgsl(Cow::Borrowed(include_str!(
                "../../../../../../assets/shaders/wgsl/meshssao.wgsl"
            ))),
        });
        let pipelines = std::array::from_fn(|i| {
            device.create_render_pipeline(&RenderPipelineDescriptor {
                label: Some("mesh SSAO"),
                layout: Some(&pipeline_layout),
                vertex: VertexState {
                    module: &shader,
                    entry_point: Some("vertexMain"),
                    compilation_options: Default::default(),
                    buffers: &[],
                },
                fragment: Some(FragmentState {
                    module: &shader,
                    entry_point: Some(["estimate", "horizontal", "vertical", "apply"][i]),
                    compilation_options: Default::default(),
                    targets: &[Some(ColorTargetState {
                        format: targets[i].format(),
                        blend: None,
                        write_mask: ColorWrites::ALL,
                    })],
                }),
                primitive: Default::default(),
                depth_stencil: None,
                multisample: Default::default(),
                multiview_mask: None,
                cache: None,
            })
        });
        let sampler = device.create_sampler(&SamplerDescriptor {
            mag_filter: FilterMode::Linear,
            min_filter: FilterMode::Linear,
            ..Default::default()
        });
        let groups = std::array::from_fn(|i| {
            let normal = normal.create_view(&Default::default());
            let depth = state.depth.create_view(&Default::default());
            let source = targets[if i == 0 { 1 } else { i - 1 }].create_view(&Default::default());
            let scene = state.color.create_view(&Default::default());
            let ambient = ambient.create_view(&Default::default());
            device.create_bind_group(&BindGroupDescriptor {
                label: Some("mesh SSAO inputs"),
                layout: &layout,
                entries: &[
                    BindGroupEntry {
                        binding: 0,
                        resource: BindingResource::TextureView(&normal),
                    },
                    BindGroupEntry {
                        binding: 1,
                        resource: BindingResource::TextureView(&depth),
                    },
                    BindGroupEntry {
                        binding: 2,
                        resource: BindingResource::TextureView(&source),
                    },
                    BindGroupEntry {
                        binding: 3,
                        resource: BindingResource::Sampler(&sampler),
                    },
                    BindGroupEntry {
                        binding: 4,
                        resource: uniform.as_entire_binding(),
                    },
                    BindGroupEntry {
                        binding: 5,
                        resource: BindingResource::TextureView(&scene),
                    },
                    BindGroupEntry {
                        binding: 6,
                        resource: BindingResource::TextureView(&ambient),
                    },
                ],
            })
        });
        Ok(Self {
            scale,
            normal,
            ambient,
            targets,
            pipelines,
            groups,
            uniform,
            parameters: Vec::new(),
        })
    }
    pub fn render(
        &mut self,
        renderer: &Renderer,
        encoder: &mut wgpu::CommandEncoder,
        color: &wgpu::Texture,
        camera: &[u8],
        settings: &Value,
    ) -> Result<()> {
        let number =
            |key: &str, default: f32| settings.get(key).map(super::number).unwrap_or(Ok(default));
        let radius = number("ssaoRadius", 0.5)?;
        let bias = number("ssaoBias", 0.025)?;
        let intensity = number("ssaoIntensity", 1.)?;
        let power = number("ssaoPower", 1.5)?;
        if radius <= 0. || bias < 0. || intensity < 0. || power <= 0. {
            bail!("invalid SSAO tuning");
        }
        let values: Vec<f32> = camera
            .as_chunks::<4>()
            .0
            .iter()
            .map(|v| f32::from_ne_bytes(*v))
            .collect();
        let inverse = glam::Mat4::from_cols_array(values[..16].try_into()?).inverse();
        if !inverse.is_finite() {
            bail!("singular SSAO camera");
        }
        let mut parameters = values[..16].to_vec();
        parameters.extend_from_slice(&inverse.to_cols_array());
        parameters.extend_from_slice(&[radius, bias, intensity, power]);
        parameters.extend_from_slice(&values[16..20]);
        if parameters != self.parameters {
            renderer
                .queue
                .write_buffer(&self.uniform, 0, bytemuck::cast_slice(&parameters));
            self.parameters = parameters;
        }
        for i in 0..4 {
            let view = self.targets[i].create_view(&Default::default());
            let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
                label: Some("mesh SSAO"),
                color_attachments: &[Some(RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: Operations {
                        load: LoadOp::Clear(Color::WHITE),
                        store: StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            pass.set_pipeline(&self.pipelines[i]);
            pass.set_bind_group(0, &self.groups[i], &[]);
            pass.draw(0..3, 0..1);
        }
        encoder.copy_texture_to_texture(
            self.targets[3].as_image_copy(),
            color.as_image_copy(),
            color.size(),
        );
        Ok(())
    }
}
