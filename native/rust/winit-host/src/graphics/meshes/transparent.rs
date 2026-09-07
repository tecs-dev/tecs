//! A globally sorted indirect lane with shared geometry and material bindings.
use super::*;
use std::num::{NonZeroU32, NonZeroU64};

pub(super) struct Heap {
    vertices: Buffer,
    indices: Buffer,
    geometries: Buffer,
    materials: BindGroup,
    geometry: HashMap<(u32, usize), (u32, u32)>,
    material: HashMap<(u32, usize), u32>,
    draw_layout: BindGroupLayout,
    sort_layout: BindGroupLayout,
    pipeline: RenderPipeline,
    sort: [ComputePipeline; 3],
}
impl Heap {
    pub fn new(renderer: &Renderer) -> Result<Self> {
        let device = &renderer.device;
        let required = wgpu::Features::TEXTURE_BINDING_ARRAY
            | wgpu::Features::SAMPLED_TEXTURE_AND_STORAGE_BUFFER_ARRAY_NON_UNIFORM_INDEXING
            | wgpu::Features::INDIRECT_FIRST_INSTANCE;
        if !device.features().contains(required) {
            bail!("globally sorted mesh transparency requires texture binding arrays and indirect first-instance support");
        }
        let mut vertices = Vec::new();
        let mut indices = Vec::new();
        let mut geometries = Vec::new();
        let mut words = Vec::new();
        let mut geometry = HashMap::new();
        let mut material = HashMap::new();
        let mut textures = Vec::<TextureView>::new();
        // TextureView hashes its stable resource identity; internal GPU state never changes that key.
        #[allow(clippy::mutable_key_type)]
        let mut texture_ids = HashMap::new();
        let mut ids: Vec<_> = renderer.models.keys().copied().collect();
        ids.sort_unstable();
        for id in ids {
            let model = &renderer.models[&id];
            for (index, mesh) in model.meshes.iter().enumerate() {
                let base = u32::try_from(vertices.len() / 4)?;
                let mut info = mesh.info;
                for offset in &mut info[1..=3] {
                    if *offset != 0 {
                        *offset = (*offset)
                            .checked_add(base)
                            .context("transparent geometry exceeds 32-bit addressing")?;
                    }
                }
                info[6] = u32::try_from(indices.len() / 4)?;
                geometry.insert((id, index), (u32::try_from(geometries.len())?, base));
                geometries.push(info);
                vertices.extend_from_slice(&mesh.source);
                indices.extend_from_slice(&mesh.index_data);
            }
            for (index, value) in model.materials.iter().enumerate() {
                material.insert((id, index), u32::try_from(words.len() / 96)?);
                words.extend_from_slice(bytemuck::cast_slice(&value.values));
                for map in &value.maps {
                    let next = u32::try_from(textures.len())?;
                    let entry = *texture_ids.entry(map.clone()).or_insert_with(|| {
                        textures.push(map.clone());
                        next
                    });
                    words.extend_from_slice(&entry.to_ne_bytes());
                }
                words.extend_from_slice(&[0; 12]);
            }
        }
        if textures.is_empty()
            || textures.len() > device.limits().max_binding_array_elements_per_shader_stage as usize
        {
            bail!("transparent material texture count exceeds device binding-array limits");
        }
        let material_layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("shared transparent materials"),
            entries: &[
                BindGroupLayoutEntry {
                    binding: 0,
                    visibility: ShaderStages::FRAGMENT,
                    ty: BindingType::Sampler(SamplerBindingType::Filtering),
                    count: None,
                },
                BindGroupLayoutEntry {
                    binding: 1,
                    visibility: ShaderStages::FRAGMENT,
                    ty: BindingType::Texture {
                        sample_type: TextureSampleType::Float { filterable: true },
                        view_dimension: TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: NonZeroU32::new(textures.len() as u32),
                },
                storage(6, ShaderStages::FRAGMENT, true),
            ],
        });
        let material_values = buffer(device, &words, BufferUsages::STORAGE);
        let references: Vec<_> = textures.iter().collect();
        let materials = device.create_bind_group(&BindGroupDescriptor {
            label: Some("shared transparent materials"),
            layout: &material_layout,
            entries: &[
                BindGroupEntry {
                    binding: 0,
                    resource: BindingResource::Sampler(&renderer.sampler),
                },
                BindGroupEntry {
                    binding: 1,
                    resource: BindingResource::TextureViewArray(&references),
                },
                BindGroupEntry {
                    binding: 6,
                    resource: material_values.as_entire_binding(),
                },
            ],
        });
        let mut entries = vec![
            storage(0, ShaderStages::VERTEX, true),
            storage(1, ShaderStages::VERTEX, true),
            storage(2, ShaderStages::VERTEX, true),
            storage(3, ShaderStages::VERTEX, true),
            uniform(6, ShaderStages::VERTEX, false),
            uniform(7, ShaderStages::VERTEX | ShaderStages::FRAGMENT, false),
            uniform(8, ShaderStages::FRAGMENT, false),
            storage(9, ShaderStages::FRAGMENT, true),
            storage(10, ShaderStages::FRAGMENT, true),
            uniform(11, ShaderStages::FRAGMENT, false),
            uniform(14, ShaderStages::FRAGMENT, false),
            storage(15, ShaderStages::VERTEX, true),
            storage(16, ShaderStages::VERTEX, true),
        ];
        entries.push(BindGroupLayoutEntry {
            binding: 12,
            visibility: ShaderStages::FRAGMENT,
            ty: BindingType::Texture {
                sample_type: TextureSampleType::Float { filterable: true },
                view_dimension: TextureViewDimension::D2Array,
                multisampled: false,
            },
            count: None,
        });
        entries.push(BindGroupLayoutEntry {
            binding: 13,
            visibility: ShaderStages::FRAGMENT,
            ty: BindingType::Sampler(SamplerBindingType::Filtering),
            count: None,
        });
        let draw_layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("global transparent draw"),
            entries: &entries,
        });
        let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
            label: Some("global transparent draw"),
            bind_group_layouts: &[
                Some(&draw_layout),
                Some(&material_layout),
                Some(&renderer.shadow_layout),
                Some(&renderer.local_shadow_layout),
            ],
            immediate_size: 0,
        });
        let shader = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("global transparent mesh"),
            source: ShaderSource::Wgsl(Cow::Owned(shader())),
        });
        let pipeline = device.create_render_pipeline(&RenderPipelineDescriptor {
            label: Some("global transparent mesh"),
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
                    blend: Some(BlendState::PREMULTIPLIED_ALPHA_BLENDING),
                    write_mask: ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState {
                cull_mode: None,
                ..Default::default()
            },
            depth_stencil: Some(DepthStencilState {
                format: DEPTH_FORMAT,
                depth_write_enabled: Some(false),
                depth_compare: Some(wgpu::CompareFunction::LessEqual),
                stencil: Default::default(),
                bias: Default::default(),
            }),
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        });
        let sort_layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("global mesh sort"),
            entries: &[
                storage(0, ShaderStages::COMPUTE, true),
                storage(1, ShaderStages::COMPUTE, true),
                storage(2, ShaderStages::COMPUTE, true),
                storage(3, ShaderStages::COMPUTE, false),
                storage(4, ShaderStages::COMPUTE, false),
                storage(5, ShaderStages::COMPUTE, false),
                uniform(6, ShaderStages::COMPUTE, true),
                storage(7, ShaderStages::COMPUTE, false),
                uniform(8, ShaderStages::COMPUTE, false),
            ],
        });
        let sort_pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
            label: Some("global mesh sort"),
            bind_group_layouts: &[Some(&sort_layout)],
            immediate_size: 0,
        });
        let module = device.create_shader_module(ShaderModuleDescriptor {
            label: Some("global mesh sort"),
            source: ShaderSource::Wgsl(Cow::Borrowed(include_str!(
                "../../../../../../assets/shaders/wgsl/meshalphasort.wgsl"
            ))),
        });
        let sort = std::array::from_fn(|i| {
            device.create_compute_pipeline(&ComputePipelineDescriptor {
                label: Some("global mesh sort"),
                layout: Some(&sort_pipeline_layout),
                module: &module,
                entry_point: Some(["mark", "sort", "emit"][i]),
                compilation_options: Default::default(),
                cache: None,
            })
        });
        Ok(Self {
            vertices: buffer(device, &vertices, BufferUsages::STORAGE),
            indices: buffer(device, &indices, BufferUsages::INDEX),
            geometries: buffer(
                device,
                bytemuck::cast_slice(&geometries),
                BufferUsages::STORAGE,
            ),
            materials,
            geometry,
            material,
            draw_layout,
            sort_layout,
            pipeline,
            sort,
        })
    }
}
fn storage(binding: u32, visibility: ShaderStages, read_only: bool) -> BindGroupLayoutEntry {
    BindGroupLayoutEntry {
        binding,
        visibility,
        ty: BindingType::Buffer {
            ty: BufferBindingType::Storage { read_only },
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    }
}
fn uniform(binding: u32, visibility: ShaderStages, dynamic: bool) -> BindGroupLayoutEntry {
    BindGroupLayoutEntry {
        binding,
        visibility,
        ty: BindingType::Buffer {
            ty: BufferBindingType::Uniform,
            has_dynamic_offset: dynamic,
            min_binding_size: None,
        },
        count: None,
    }
}
fn shader() -> String {
    let mut source = include_str!("../../../../../../assets/shaders/wgsl/mesh.wgsl").to_owned();
    source = source.replace(
        "alpha: vec4<f32>, }",
        "alpha: vec4<f32>, maps0:vec4<u32>, maps1:vec4<u32>, }",
    );
    for (binding, name) in [
        (1, "baseMap"),
        (2, "normalMap"),
        (3, "mrMap"),
        (4, "occlusionMap"),
        (5, "emissionMap"),
    ] {
        source = source.replace(
            &format!("@group(1) @binding({binding}) var {name}: texture_2d<f32>;"),
            "",
        );
    }
    source=source.replace("@group(1) @binding(6) var<uniform> material: Material;","@group(1) @binding(1) var materialMaps:binding_array<texture_2d<f32>>;\n@group(1) @binding(6) var<storage,read> materialValues:array<Material>;\n@group(0) @binding(15) var<storage,read> lookups:array<vec4<u32>>;\n@group(0) @binding(16) var<storage,read> geometries:array<MeshInfo>;");
    source=source.replace("@location(4) tint: vec4<f32>,","@location(4) tint: vec4<f32>, @location(5) @interpolate(flat) materialId:u32, @location(6) @interpolate(flat) winding:f32,");
    source=source.replace("let instance = instances[visible[mesh.counts.z + index]];","let row=visible[index];let lookup=lookups[row];let mesh=geometries[lookup.x];let instance=instances[row];");
    source = source.replace(
        "let at = vertex * 12u;",
        "let at = vertex * 12u + lookup.w;",
    );
    source=source.replace("output.tint = instance.tint;","output.tint = instance.tint;output.materialId=lookup.y;output.winding=sign(instance.scale.x*instance.scale.y*instance.scale.z);");
    source = source.replace(
        "if (!front && material.alpha.z",
        "if (!surfaceFront && material.alpha.z",
    );
    source=source.replace("fn shade(input: VertexOut, front: bool) -> Surface {","fn shade(input: VertexOut, front: bool) -> Surface {\n    let material=materialValues[input.materialId];let surfaceFront=select(!front,front,input.winding>=0.0);\n    if(!surfaceFront && material.alpha.z==0.0) {discard;}");
    for (name, index) in [
        ("baseMap", "maps0.x"),
        ("normalMap", "maps0.y"),
        ("mrMap", "maps0.z"),
        ("occlusionMap", "maps0.w"),
        ("emissionMap", "maps1.x"),
    ] {
        source = source.replace(
            &format!("textureSample({name},"),
            &format!("textureSample(materialMaps[material.{index}],"),
        );
    }
    if let Some(at) = source.find("@fragment fn shadowMain") {
        source.truncate(at);
    }
    format!(
        "enable wgpu_binding_array;\n{}\n{source}",
        include_str!("../../../../../../assets/shaders/wgsl/meshenvironment.wgsl")
    )
}

pub(super) struct State {
    capacity: u32,
    count: u32,
    single: bool,
    instances: Buffer,
    lookups: Buffer,
    visible: Buffer,
    commands: Buffer,
    counter: Buffer,
    params: Buffer,
    stages: Vec<u32>,
    sort: BindGroup,
    draw: BindGroup,
    data: Vec<u8>,
    lookup_data: Vec<[u32; 4]>,
    roots: Vec<Buffer>,
    environment: TextureView,
}
impl State {
    pub fn prepare(
        renderer: &Renderer,
        heap: &Heap,
        view: &ViewGpu,
        mut previous: Option<Self>,
        dirty: bool,
    ) -> Result<Self> {
        let count = view
            .batches
            .iter()
            .filter(|b| b.blend)
            .map(|b| b.count)
            .sum::<u32>();
        if count == 0 {
            bail!("empty transparent scene");
        }
        let roots = vec![
            view.palette.clone(),
            view.uniform.clone(),
            view.lighting.clone(),
            view.lights.clone(),
            view.light_tiles.clone(),
            view.light_info.clone(),
            view.environment.uniform.clone(),
        ];
        let mut data = Vec::new();
        let mut lookups = Vec::new();
        let mut geometry_ids = std::collections::HashSet::new();
        if dirty || previous.is_none() {
            data.reserve(count as usize * 96);
            lookups.reserve(count as usize);
            for batch in view.batches.iter().filter(|b| b.blend) {
                let &(geometry, base) = heap
                    .geometry
                    .get(&(batch.model, batch.mesh))
                    .context("missing transparent geometry")?;
                let &material = heap
                    .material
                    .get(&(batch.material_model, batch.material))
                    .context("missing transparent material")?;
                data.extend_from_slice(&batch.data);
                geometry_ids.insert(geometry);
                for &entity in &batch.entities {
                    lookups.push([geometry, material, entity, base]);
                }
            }
        }
        if previous.as_ref().is_some_and(|p| p.capacity < count) {
            previous = None;
        }
        let mut state = if let Some(state) = previous {
            state
        } else {
            let capacity = count.next_power_of_two();
            let device = &renderer.device;
            let make = |size, usage| {
                device.create_buffer(&BufferDescriptor {
                    label: Some("global transparent scene"),
                    size,
                    usage,
                    mapped_at_creation: false,
                })
            };
            let instances = make(
                capacity as u64 * 96,
                BufferUsages::STORAGE | BufferUsages::COPY_DST,
            );
            let lookups = make(
                capacity as u64 * 16,
                BufferUsages::STORAGE | BufferUsages::COPY_DST,
            );
            let keys = make(capacity as u64 * 16, BufferUsages::STORAGE);
            let visible = make(capacity as u64 * 4, BufferUsages::STORAGE);
            let commands = make(
                capacity as u64 * 20,
                BufferUsages::STORAGE | BufferUsages::INDIRECT,
            );
            let counter = make(4, BufferUsages::STORAGE | BufferUsages::COPY_DST);
            let alignment = device.limits().min_uniform_buffer_offset_alignment as usize;
            let mut words = vec![0_u8; alignment];
            let mut stages = Vec::new();
            let mut k = 2;
            while k <= capacity {
                let mut j = k / 2;
                while j > 0 {
                    stages.push(words.len() as u32);
                    let start = words.len();
                    words.resize(start + alignment, 0);
                    words[start..start + 16]
                        .copy_from_slice(bytemuck::cast_slice(&[count, capacity, k, j]));
                    j /= 2;
                }
                k *= 2;
            }
            let params = buffer(
                device,
                &words,
                BufferUsages::UNIFORM | BufferUsages::COPY_DST,
            );
            let pairs = [
                (0, &instances),
                (1, &lookups),
                (2, &heap.geometries),
                (3, &keys),
                (4, &commands),
                (5, &visible),
                (7, &counter),
                (8, &view.uniform),
            ];
            let mut entries: Vec<_> = pairs
                .iter()
                .map(|(binding, b)| BindGroupEntry {
                    binding: *binding,
                    resource: b.as_entire_binding(),
                })
                .collect();
            entries.push(BindGroupEntry {
                binding: 6,
                resource: BindingResource::Buffer(wgpu::BufferBinding {
                    buffer: &params,
                    offset: 0,
                    size: NonZeroU64::new(16),
                }),
            });
            let sort = device.create_bind_group(&BindGroupDescriptor {
                label: Some("global mesh sort"),
                layout: &heap.sort_layout,
                entries: &entries,
            });
            let draw = Self::bind(renderer, heap, view, &instances, &lookups, &visible);
            Self {
                capacity,
                count,
                single: false,
                instances,
                lookups,
                visible,
                commands,
                counter,
                params,
                stages,
                sort,
                draw,
                data: Vec::new(),
                lookup_data: Vec::new(),
                roots: roots.clone(),
                environment: view.environment.texture.clone(),
            }
        };
        if dirty || state.data.is_empty() {
            if state.data != data {
                renderer.queue.write_buffer(&state.instances, 0, &data);
                state.data = data;
            }
            if state.lookup_data != lookups {
                renderer
                    .queue
                    .write_buffer(&state.lookups, 0, bytemuck::cast_slice(&lookups));
                state.lookup_data = lookups;
            }
            state.single = geometry_ids.len() == 1;
            state.count = count;
            renderer.queue.write_buffer(
                &state.params,
                0,
                bytemuck::cast_slice(&[count, state.capacity, u32::from(state.single), 0]),
            );
        }
        if state.roots != roots || state.environment != view.environment.texture {
            state.draw = Self::bind(
                renderer,
                heap,
                view,
                &state.instances,
                &state.lookups,
                &state.visible,
            );
            state.roots = roots;
            state.environment = view.environment.texture.clone();
        }
        Ok(state)
    }
    fn bind(
        renderer: &Renderer,
        heap: &Heap,
        view: &ViewGpu,
        instances: &Buffer,
        lookups: &Buffer,
        visible: &Buffer,
    ) -> BindGroup {
        let dummy = buffer(&renderer.device, &[0; 32], BufferUsages::UNIFORM);
        let pairs = [
            (0, &heap.vertices),
            (1, instances),
            (2, &view.palette),
            (3, visible),
            (6, &dummy),
            (7, &view.uniform),
            (8, &view.lighting),
            (9, &view.lights),
            (10, &view.light_tiles),
            (11, &view.light_info),
            (14, &view.environment.uniform),
            (15, lookups),
            (16, &heap.geometries),
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
            resource: BindingResource::TextureView(&view.environment.texture),
        });
        entries.push(BindGroupEntry {
            binding: 13,
            resource: BindingResource::Sampler(&renderer.sampler),
        });
        renderer.device.create_bind_group(&BindGroupDescriptor {
            label: Some("global transparent draw"),
            layout: &heap.draw_layout,
            entries: &entries,
        })
    }
    pub fn sort(&self, heap: &Heap, encoder: &mut wgpu::CommandEncoder) {
        encoder.clear_buffer(&self.counter, 0, None);
        let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor {
            label: Some("global transparent sort"),
            timestamp_writes: None,
        });
        pass.set_bind_group(0, &self.sort, &[0]);
        pass.set_pipeline(&heap.sort[0]);
        pass.dispatch_workgroups(self.capacity.div_ceil(256), 1, 1);
        pass.set_pipeline(&heap.sort[1]);
        for &offset in &self.stages {
            pass.set_bind_group(0, &self.sort, &[offset]);
            pass.dispatch_workgroups(self.capacity.div_ceil(256), 1, 1);
        }
        pass.set_bind_group(0, &self.sort, &[0]);
        pass.set_pipeline(&heap.sort[2]);
        pass.dispatch_workgroups(self.count.div_ceil(256), 1, 1);
    }
    pub fn draw(
        &self,
        renderer: &Renderer,
        heap: &Heap,
        view: &ViewGpu,
        encoder: &mut wgpu::CommandEncoder,
    ) {
        let color = view.color.create_view(&Default::default());
        let depth = view.depth.create_view(&Default::default());
        let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
            label: Some("globally sorted transparent meshes"),
            color_attachments: &[Some(RenderPassColorAttachment {
                view: &color,
                depth_slice: None,
                resolve_target: None,
                ops: Operations {
                    load: LoadOp::Load,
                    store: StoreOp::Store,
                },
            })],
            depth_stencil_attachment: Some(RenderPassDepthStencilAttachment {
                view: &depth,
                depth_ops: Some(Operations {
                    load: LoadOp::Load,
                    store: StoreOp::Store,
                }),
                stencil_ops: None,
            }),
            ..Default::default()
        });
        pass.set_pipeline(&heap.pipeline);
        pass.set_bind_group(0, &self.draw, &[]);
        pass.set_bind_group(1, &heap.materials, &[]);
        pass.set_bind_group(
            2,
            view.shadows
                .as_ref()
                .map(|s| &s.group)
                .unwrap_or(&renderer.shadow_fallback),
            &[],
        );
        pass.set_bind_group(
            3,
            view.local_shadows
                .as_ref()
                .map(|s| &s.group)
                .unwrap_or(&renderer.local_shadow_fallback),
            &[],
        );
        pass.set_index_buffer(heap.indices.slice(..), wgpu::IndexFormat::Uint32);
        pass.multi_draw_indexed_indirect(
            &self.commands,
            0,
            if self.single { 1 } else { self.count },
        );
    }
}
