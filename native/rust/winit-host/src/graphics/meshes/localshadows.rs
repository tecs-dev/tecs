//! Stable point and spot shadow slots, with six array layers for a point light.
use super::*;
use glam::Vec3;

pub(super) fn layout(device: &Device) -> BindGroupLayout {
    device.create_bind_group_layout(&BindGroupLayoutDescriptor {
        label: Some("local mesh shadows"),
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
                    ty: BufferBindingType::Storage { read_only: true },
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            },
            BindGroupLayoutEntry {
                binding: 3,
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
fn group(
    device: &Device,
    layout: &BindGroupLayout,
    texture: &wgpu::Texture,
    matrices: &Buffer,
    tuning: &Buffer,
) -> BindGroup {
    let view = texture.create_view(&TextureViewDescriptor {
        dimension: Some(TextureViewDimension::D2Array),
        ..Default::default()
    });
    let sampler = device.create_sampler(&SamplerDescriptor {
        compare: Some(wgpu::CompareFunction::LessEqual),
        mag_filter: FilterMode::Linear,
        min_filter: FilterMode::Linear,
        ..Default::default()
    });
    device.create_bind_group(&BindGroupDescriptor {
        label: Some("local shadow receiver"),
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
                resource: matrices.as_entire_binding(),
            },
            BindGroupEntry {
                binding: 3,
                resource: tuning.as_entire_binding(),
            },
        ],
    })
}
fn texture(device: &Device, size: u32, layers: u32) -> wgpu::Texture {
    device.create_texture(&TextureDescriptor {
        label: Some("local shadow atlas"),
        size: Extent3d {
            width: size,
            height: size,
            depth_or_array_layers: layers,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: TextureDimension::D2,
        format: DEPTH_FORMAT,
        usage: TextureUsages::RENDER_ATTACHMENT | TextureUsages::TEXTURE_BINDING,
        view_formats: &[],
    })
}
pub(super) fn fallback(device: &Device, layout: &BindGroupLayout) -> BindGroup {
    group(
        device,
        layout,
        &texture(device, 1, 1),
        &buffer(device, &[0; 64], BufferUsages::STORAGE),
        &buffer(device, &[0; 16], BufferUsages::UNIFORM),
    )
}
pub(super) struct State {
    pub size: u32,
    pub capacity: u32,
    pub group: BindGroup,
    texture: wgpu::Texture,
    matrices: Buffer,
    tuning: Buffer,
    cameras: Vec<Buffer>,
    pipelines: [RenderPipeline; 4],
    bindings: Vec<Vec<(BindGroup, BindGroup)>>,
    resident: Vec<(Buffer, Buffer, Buffer)>,
}
impl State {
    pub fn new(renderer: &Renderer, size: u32, capacity: u32) -> Result<Self> {
        let device = &renderer.device;
        if size == 0
            || size > device.limits().max_texture_dimension_2d
            || capacity == 0
            || capacity > device.limits().max_texture_array_layers / 6
        {
            bail!("local shadow size or capacity exceeds device limits");
        }
        let texture = texture(device, size, capacity * 6);
        let matrices = buffer(
            device,
            &vec![0; capacity as usize * 6 * 64],
            BufferUsages::STORAGE | BufferUsages::COPY_DST,
        );
        let tuning = buffer(
            device,
            &[0; 16],
            BufferUsages::UNIFORM | BufferUsages::COPY_DST,
        );
        let group = group(
            device,
            &renderer.local_shadow_layout,
            &texture,
            &matrices,
            &tuning,
        );
        let cameras = (0..capacity * 6)
            .map(|_| {
                buffer(
                    device,
                    &[0; 80],
                    BufferUsages::UNIFORM | BufferUsages::COPY_DST,
                )
            })
            .collect();
        Ok(Self {
            size,
            capacity,
            group,
            texture,
            matrices,
            tuning,
            cameras,
            pipelines: shadows::caster_pipelines(renderer, &renderer.shader),
            bindings: Vec::new(),
            resident: Vec::new(),
        })
    }
    pub fn update(
        &mut self,
        renderer: &Renderer,
        state: &ViewGpu,
        settings: &Value,
        encoder: &mut wgpu::CommandEncoder,
    ) -> Result<()> {
        let bias = settings
            .get("localShadowBias")
            .map(number)
            .unwrap_or(Ok(0.002))?;
        let softness = settings
            .get("localShadowSoftness")
            .map(number)
            .unwrap_or(Ok(1.))?;
        if bias < 0. || softness < 0. {
            bail!("local shadow bias and softness must be non-negative");
        }
        renderer.queue.write_buffer(
            &self.tuning,
            0,
            bytemuck::cast_slice(&[bias, softness, 0., 0.]),
        );
        let mut lights = state.light_data.clone();
        let mut matrices = Vec::new();
        let mut slots = 0;
        let directions = [Vec3::X, -Vec3::X, Vec3::Y, -Vec3::Y, Vec3::Z, -Vec3::Z];
        let mut faces = Vec::new();
        for row in lights.as_chunks_mut::<64>().0 {
            row[60..64].copy_from_slice(&0_f32.to_ne_bytes());
            let f = |i: usize| f32::from_ne_bytes(row[i * 4..i * 4 + 4].try_into().unwrap());
            if (f(14) as u32) & 1 == 0 || slots >= self.capacity {
                continue;
            }
            let position = Vec3::new(f(0), f(1), f(2));
            let radius = f(3);
            let kind = f(13);
            let direction = Vec3::new(f(8), f(9), f(10));
            let outer = f(11).acos();
            let base = matrices.len();
            for (face, &face_direction) in
                directions
                    .iter()
                    .enumerate()
                    .take(if kind == 0. { 6 } else { 1 })
            {
                let direction = if kind == 0. {
                    face_direction
                } else {
                    direction.normalize()
                };
                let up = if direction.y.abs() > 0.99 {
                    Vec3::Z
                } else {
                    Vec3::Y
                };
                let fov = if kind == 0. {
                    std::f32::consts::FRAC_PI_2
                } else {
                    outer * 2.
                };
                let matrix =
                    glam::camera::rh::proj::directx::perspective(fov, 1., radius * 0.001, radius)
                        * glam::camera::rh::view::look_at_mat4(position, position + direction, up);
                if !matrix.is_finite() {
                    bail!("invalid local shadow camera");
                }
                matrices.push(matrix.to_cols_array());
                faces.push(base + face);
            }
            row[60..64].copy_from_slice(&((base + 1) as f32).to_ne_bytes());
            slots += 1;
        }
        if !lights.is_empty() {
            renderer.queue.write_buffer(&state.lights, 0, &lights);
        }
        if !matrices.is_empty() {
            renderer
                .queue
                .write_buffer(&self.matrices, 0, bytemuck::cast_slice(&matrices));
        }
        for (i, matrix) in matrices.iter().enumerate() {
            let mut camera = [0.; 20];
            camera[..16].copy_from_slice(matrix);
            renderer
                .queue
                .write_buffer(&self.cameras[i], 0, bytemuck::cast_slice(&camera));
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
                self.bindings.push(
                    self.cameras
                        .iter()
                        .map(|camera| {
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
                                        resource: BindingResource::TextureView(
                                            &state.environment.texture,
                                        ),
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
                                        (7, camera),
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
                                        (7, camera),
                                    ],
                                ),
                            )
                        })
                        .collect(),
                );
            }
            self.resident = resident;
        }
        for face in faces {
            for (index, batch) in state.batches.iter().enumerate() {
                if batch.blend {
                    continue;
                }
                let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor {
                    label: Some("local shadow cull"),
                    timestamp_writes: None,
                });
                pass.set_bind_group(0, &self.bindings[index][face].1, &[]);
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
                base_array_layer: face as u32,
                array_layer_count: Some(1),
                ..Default::default()
            });
            let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
                label: Some("local shadow depth"),
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
                pass.set_bind_group(0, &self.bindings[index][face].0, &[]);
                pass.set_bind_group(1, &material.group, &[]);
                pass.set_index_buffer(geometry.indices.slice(..), wgpu::IndexFormat::Uint32);
                pass.draw_indexed_indirect(&batch.args, 0);
            }
            drop(pass);
            // A face is the bounded unit of a local-shadow submission, just
            // as a cascade is for directional shadows in a large scene.
            let next = renderer
                .device
                .create_command_encoder(&CommandEncoderDescriptor {
                    label: Some("mesh view after local shadow"),
                });
            renderer
                .queue
                .submit([std::mem::replace(encoder, next).finish()]);
        }
        Ok(())
    }
}
