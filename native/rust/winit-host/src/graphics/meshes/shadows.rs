//! Three texel-snapped cascades, ported from the original MeshBackend.
use super::*;
use glam::{Mat4, Vec3, Vec4};

pub(super) struct Options {
    pub enabled: bool,
    pub size: u32,
    pub distance: f32,
    pub lambda: f32,
    pub blend: f32,
    pub padding: f32,
    pub bias: f32,
    pub softness: f32,
    pub strength: f32,
}
impl Options {
    pub fn parse(bytes: &[u8], width: u32, height: u32) -> Result<Self> {
        let root: Value = if bytes.is_empty() {
            serde_json::json!({})
        } else {
            serde_json::from_slice(bytes)?
        };
        let enabled = root
            .get("shadows")
            .map(|v| v.as_bool().context("shadows must be boolean"))
            .transpose()?
            .unwrap_or(false);
        let f = |key: &str, default: f32| -> Result<f32> {
            root.get(key).map(number).unwrap_or(Ok(default))
        };
        let scale = f("shadowScale", 1.)?;
        let result = Self {
            enabled,
            size: (width.max(height) as f32 * scale).round().max(1.) as u32,
            distance: f("shadowDistance", 100.)?,
            lambda: f("shadowSplitLambda", 0.7)?,
            blend: f("shadowSplitBlend", 0.1)?,
            padding: f("shadowDepthPadding", 20.)?,
            bias: f("shadowBias", 0.0015)?,
            softness: f("shadowSoftness", 1.)?,
            strength: f("shadowStrength", 1.)?,
        };
        if scale <= 0.
            || !(0.0..=1.0).contains(&result.lambda)
            || !(0.0..=0.5).contains(&result.blend)
            || result.padding < 0.
            || result.bias < 0.
            || result.softness < 0.
            || !(0.0..=1.0).contains(&result.strength)
        {
            bail!("invalid directional shadow settings");
        }
        Ok(result)
    }
}

pub(super) fn layout(device: &Device) -> BindGroupLayout {
    device.create_bind_group_layout(&BindGroupLayoutDescriptor {
        label: Some("mesh shadows"),
        entries: &[
            BindGroupLayoutEntry {
                binding: 0,
                visibility: ShaderStages::FRAGMENT,
                ty: BindingType::Texture {
                    sample_type: TextureSampleType::Depth,
                    view_dimension: TextureViewDimension::D2Array,
                    multisampled: false,
                },
                count: None,
            },
            BindGroupLayoutEntry {
                binding: 1,
                visibility: ShaderStages::FRAGMENT,
                ty: BindingType::Sampler(SamplerBindingType::Comparison),
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
    })
}

pub(super) struct Maps {
    texture: wgpu::Texture,
    pub group: BindGroup,
    uniform: Buffer,
    camera: [Buffer; 3],
    pipelines: [RenderPipeline; 4],
    resident: Vec<(Buffer, Buffer, Buffer)>,
    bindings: Vec<[(BindGroup, BindGroup); 3]>,
}
impl Maps {
    pub fn new(renderer: &Renderer, size: u32, shader: &wgpu::ShaderModule) -> Result<Self> {
        if size > renderer.device.limits().max_texture_dimension_2d {
            bail!("shadow size exceeds device limit");
        }
        let device = &renderer.device;
        let texture = device.create_texture(&TextureDescriptor {
            label: Some("directional shadow cascades"),
            size: Extent3d {
                width: size,
                height: size,
                depth_or_array_layers: 3,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: TextureDimension::D2,
            format: DEPTH_FORMAT,
            usage: TextureUsages::RENDER_ATTACHMENT | TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        let view = texture.create_view(&TextureViewDescriptor {
            dimension: Some(TextureViewDimension::D2Array),
            ..Default::default()
        });
        let sampler = device.create_sampler(&SamplerDescriptor {
            label: Some("mesh shadow PCF"),
            compare: Some(wgpu::CompareFunction::LessEqual),
            mag_filter: FilterMode::Linear,
            min_filter: FilterMode::Linear,
            ..Default::default()
        });
        let uniform = buffer(
            device,
            &[0; 240],
            BufferUsages::UNIFORM | BufferUsages::COPY_DST,
        );
        let group = device.create_bind_group(&BindGroupDescriptor {
            label: Some("mesh shadow receiver"),
            layout: &renderer.shadow_layout,
            entries: &[
                BindGroupEntry {
                    binding: 0,
                    resource: BindingResource::TextureView(&view),
                },
                BindGroupEntry {
                    binding: 1,
                    resource: BindingResource::Sampler(&sampler),
                },
                BindGroupEntry {
                    binding: 2,
                    resource: uniform.as_entire_binding(),
                },
            ],
        });
        let pipelines = caster_pipelines(renderer, shader);
        Ok(Self {
            texture,
            group,
            uniform,
            camera: std::array::from_fn(|_| {
                buffer(
                    device,
                    &[0; 80],
                    BufferUsages::UNIFORM | BufferUsages::COPY_DST,
                )
            }),
            pipelines,
            resident: Vec::new(),
            bindings: Vec::new(),
        })
    }
    pub fn size(&self) -> u32 {
        self.texture.width()
    }
    pub fn update(
        &mut self,
        renderer: &Renderer,
        state: &ViewGpu,
        options: &Options,
        camera: &[u8],
        lighting: &[f32; 40],
        encoder: &mut wgpu::CommandEncoder,
    ) -> Result<()> {
        let matrices = cascades(camera, options, Vec3::from_slice(&lighting[..3]))?;
        renderer
            .queue
            .write_buffer(&self.uniform, 0, bytemuck::cast_slice(&matrices));
        for cascade in 0..3 {
            let mut view = [0_f32; 20];
            view[..16].copy_from_slice(&matrices[cascade * 16..cascade * 16 + 16]);
            renderer
                .queue
                .write_buffer(&self.camera[cascade], 0, bytemuck::cast_slice(&view));
        }
        let resident: Vec<_> = state
            .batches
            .iter()
            .map(|b| {
                (
                    b.instances.clone(),
                    state.palette.clone(),
                    b.visible.clone(),
                )
            })
            .collect();
        if self.resident != resident {
            self.bindings.clear();
            for batch in &state.batches {
                let geometry = &renderer.models[&batch.model].meshes[batch.mesh];
                self.bindings.push(std::array::from_fn(|i| {
                    let group = |layout: &BindGroupLayout, pairs: &[(u32, &Buffer)]| {
                        let mut entries: Vec<_> = pairs
                            .iter()
                            .map(|(binding, b)| BindGroupEntry {
                                binding: *binding,
                                resource: b.as_entire_binding(),
                            })
                            .collect();
                        if pairs.iter().any(|(binding, _)| *binding == 0) {
                            entries.push(BindGroupEntry {
                                binding: 12,
                                resource: BindingResource::TextureView(&state.environment.texture),
                            });
                            entries.push(BindGroupEntry {
                                binding: 13,
                                resource: BindingResource::Sampler(&renderer.sampler),
                            });
                            entries.push(BindGroupEntry {
                                binding: 14,
                                resource: state.environment.uniform.as_entire_binding(),
                            });
                        }
                        renderer.device.create_bind_group(&BindGroupDescriptor {
                            label: Some("shadow caster"),
                            layout,
                            entries: &entries,
                        })
                    };
                    (
                        group(
                            &renderer.draw_layout,
                            &[
                                (0, &geometry.vertices),
                                (1, &batch.instances),
                                (2, &state.palette),
                                (3, &batch.visible),
                                (6, &batch.info),
                                (7, &self.camera[i]),
                                (8, &state.lighting),
                                (9, &state.lights),
                                (10, &state.light_tiles),
                                (11, &state.light_info),
                            ],
                        ),
                        group(
                            &renderer.cull_layout,
                            &[
                                (1, &batch.instances),
                                (3, &batch.visible),
                                (4, &batch.scan),
                                (5, &batch.args),
                                (6, &batch.info),
                                (7, &self.camera[i]),
                            ],
                        ),
                    )
                }));
            }
            self.resident = resident;
        }
        for cascade in 0..3 {
            for (index, batch) in state.batches.iter().enumerate() {
                if batch.blend {
                    continue;
                }
                let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor {
                    label: Some("mesh shadow cull"),
                    timestamp_writes: None,
                });
                pass.set_bind_group(0, &self.bindings[index][cascade].1, &[]);
                if batch.count == 1 {
                    pass.set_pipeline(&renderer.cull[3]);
                    pass.dispatch_workgroups(1, 1, 1);
                } else {
                    pass.set_pipeline(&renderer.cull[0]);
                    pass.dispatch_workgroups(batch.count.div_ceil(256), 1, 1);
                    pass.set_pipeline(&renderer.cull[1]);
                    pass.dispatch_workgroups(1, 1, 1);
                    pass.set_pipeline(&renderer.cull[2]);
                    pass.dispatch_workgroups(batch.count.div_ceil(256), 1, 1);
                }
            }
            let view = self.texture.create_view(&TextureViewDescriptor {
                dimension: Some(TextureViewDimension::D2),
                base_array_layer: cascade as u32,
                array_layer_count: Some(1),
                ..Default::default()
            });
            let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
                label: Some("mesh directional shadow"),
                color_attachments: &[],
                depth_stencil_attachment: Some(RenderPassDepthStencilAttachment {
                    view: &view,
                    depth_ops: Some(Operations {
                        load: LoadOp::Clear(1.),
                        store: StoreOp::Store,
                    }),
                    stencil_ops: None,
                }),
                ..Default::default()
            });
            for (index, batch) in state.batches.iter().enumerate() {
                if batch.blend {
                    continue;
                }
                let material = &renderer.models[&batch.material_model].materials[batch.material];
                let geometry = &renderer.models[&batch.model].meshes[batch.mesh];
                pass.set_pipeline(
                    &self.pipelines
                        [usize::from(material.double_sided) + usize::from(batch.mirrored) * 2],
                );
                pass.set_bind_group(0, &self.bindings[index][cascade].0, &[]);
                pass.set_bind_group(1, &material.group, &[]);
                pass.set_index_buffer(geometry.indices.slice(..), wgpu::IndexFormat::Uint32);
                pass.draw_indexed_indirect(&batch.args, 0);
            }
            drop(pass);
            // Bound each shadow submission to one cascade. Large imported
            // scenes otherwise retain thousands of draw resources across all
            // cascades in one Metal command buffer.
            let next = renderer
                .device
                .create_command_encoder(&CommandEncoderDescriptor {
                    label: Some("mesh view after shadow cascade"),
                });
            renderer
                .queue
                .submit([std::mem::replace(encoder, next).finish()]);
        }
        Ok(())
    }
}

fn cascades(camera: &[u8], options: &Options, direction: Vec3) -> Result<[f32; 60]> {
    let words: Vec<f32> = camera
        .as_chunks::<4>()
        .0
        .iter()
        .map(|w| f32::from_ne_bytes(*w))
        .collect();
    let vp = Mat4::from_cols_array(words[..16].try_into()?);
    let inverse = vp.inverse();
    if !inverse.is_finite() {
        bail!("singular shadow camera");
    }
    let eye = Vec3::from_slice(&words[16..19]);
    let unproject = |x, y, z| {
        let p = inverse * Vec4::new(x, y, z, 1.);
        p.truncate() / p.w
    };
    let near = unproject(0., 0., 0.).distance(eye);
    let far = unproject(0., 0., 1.).distance(eye);
    if options.distance <= near {
        bail!("shadow distance must exceed camera near plane");
    }
    let covered = far.min(options.distance);
    let d = direction.normalize();
    let up = if d.y.abs() > 0.99 { Vec3::X } else { Vec3::Y };
    let right = up.cross(d).normalize();
    let vertical = d.cross(right);
    let xy = [(-1., -1.), (1., -1.), (1., 1.), (-1., 1.)];
    let frustum: Vec<_> = xy
        .iter()
        .map(|(x, y)| (unproject(*x, *y, 0.), unproject(*x, *y, 1.)))
        .collect();
    let mut output = [0.; 60];
    let mut split_near = near;
    for cascade in 0..3 {
        let fraction = (cascade + 1) as f32 / 3.;
        let logarithmic = near * (covered / near).powf(fraction);
        let linear = near + (covered - near) * fraction;
        let split_far = linear + (logarithmic - linear) * options.lambda;
        let corners: Vec<_> = frustum
            .iter()
            .flat_map(|(a, b)| {
                [
                    a + (b - a) * ((split_near - near) / (far - near)),
                    a + (b - a) * ((split_far - near) / (far - near)),
                ]
            })
            .collect();
        let center = corners.iter().copied().sum::<Vec3>() / 8.;
        let radius = (corners
            .iter()
            .map(|v| v.distance(center))
            .fold(0_f32, f32::max)
            * 16.)
            .ceil()
            .max(1.)
            / 16.;
        let minimum = corners
            .iter()
            .map(|v| v.dot(d))
            .fold(f32::INFINITY, f32::min);
        let maximum = corners
            .iter()
            .map(|v| v.dot(d))
            .fold(f32::NEG_INFINITY, f32::max);
        let texel = radius * 2. / options.size as f32;
        let center_right = (center.dot(right) / texel + 0.5).floor() * texel;
        let center_up = (center.dot(vertical) / texel + 0.5).floor() * texel;
        let span = (maximum - minimum + options.padding * 2.).max(1. / 65535.);
        let step = span / 65535.;
        let center_depth = (((minimum + maximum) * 0.5) / step + 0.5).floor() * step;
        let matrix = Mat4::from_cols(
            right.extend(-center_right) / radius,
            vertical.extend(-center_up) / radius,
            d.extend(-(center_depth - span * 0.5)) / span,
            Vec4::W,
        )
        .transpose();
        output[cascade * 16..cascade * 16 + 16].copy_from_slice(&matrix.to_cols_array());
        output[48 + cascade] = split_far;
        split_near = split_far;
    }
    output[51] = options.blend;
    output[52..56].copy_from_slice(&vp.transpose().w_axis.to_array());
    output[56..60].copy_from_slice(&[options.bias, options.softness, options.strength, 1.]);
    Ok(output)
}

pub(super) fn fallback(device: &Device, layout: &BindGroupLayout) -> BindGroup {
    let texture = device.create_texture(&TextureDescriptor {
        label: Some("disabled mesh shadows"),
        size: Extent3d {
            width: 1,
            height: 1,
            depth_or_array_layers: 3,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: TextureDimension::D2,
        format: DEPTH_FORMAT,
        usage: TextureUsages::TEXTURE_BINDING,
        view_formats: &[],
    });
    let view = texture.create_view(&TextureViewDescriptor {
        dimension: Some(TextureViewDimension::D2Array),
        ..Default::default()
    });
    let sampler = device.create_sampler(&SamplerDescriptor {
        compare: Some(wgpu::CompareFunction::LessEqual),
        ..Default::default()
    });
    let uniform = buffer(device, &[0; 240], BufferUsages::UNIFORM);
    device.create_bind_group(&BindGroupDescriptor {
        label: Some("disabled mesh shadows"),
        layout,
        entries: &[
            BindGroupEntry {
                binding: 0,
                resource: BindingResource::TextureView(&view),
            },
            BindGroupEntry {
                binding: 1,
                resource: BindingResource::Sampler(&sampler),
            },
            BindGroupEntry {
                binding: 2,
                resource: uniform.as_entire_binding(),
            },
        ],
    })
}

pub(super) fn caster_pipelines(
    renderer: &Renderer,
    shader: &wgpu::ShaderModule,
) -> [RenderPipeline; 4] {
    let device = &renderer.device;
    let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
        label: Some("mesh shadow caster"),
        bind_group_layouts: &[Some(&renderer.draw_layout), Some(&renderer.material_layout)],
        immediate_size: 0,
    });

    std::array::from_fn(|side| {
        device.create_render_pipeline(&RenderPipelineDescriptor {
            label: Some("mesh shadow caster"),
            layout: Some(&pipeline_layout),
            vertex: VertexState {
                module: shader,
                entry_point: Some("vertexMain"),
                compilation_options: Default::default(),
                buffers: &[],
            },
            fragment: Some(FragmentState {
                module: shader,
                entry_point: Some("shadowMain"),
                compilation_options: Default::default(),
                targets: &[],
            }),
            primitive: wgpu::PrimitiveState {
                cull_mode: (side % 2 == 0).then_some(wgpu::Face::Back),
                front_face: if side >= 2 {
                    wgpu::FrontFace::Cw
                } else {
                    wgpu::FrontFace::Ccw
                },
                ..Default::default()
            },
            depth_stencil: Some(DepthStencilState {
                format: DEPTH_FORMAT,
                depth_write_enabled: Some(true),
                depth_compare: Some(wgpu::CompareFunction::LessEqual),
                stencil: Default::default(),
                bias: Default::default(),
            }),
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        })
    })
}
