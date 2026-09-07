//! Model images retain compressed mip chains; RGBA chains are generated on the GPU.
use super::*;

pub(super) struct Image<'a> {
    pub width: u32,
    pub height: u32,
    pub levels: u32,
    pub compressed: bool,
    pub mipmaps: bool,
    pub pixels: &'a [u8],
}

pub(super) fn upload(device: &Device, queue: &Queue, image: Image<'_>) -> Result<[TextureView; 2]> {
    let Image {
        width,
        height,
        levels,
        compressed,
        mipmaps,
        pixels,
    } = image;
    if width == 0
        || height == 0
        || width > device.limits().max_texture_dimension_2d
        || height > device.limits().max_texture_dimension_2d
    {
        bail!("model image dimensions exceed the device limit");
    }
    if compressed
        && !device
            .features()
            .contains(wgpu::Features::TEXTURE_COMPRESSION_BC)
    {
        bail!("this GPU does not support BC3 model textures");
    }
    let maximum = width.max(height).ilog2() + 1;
    if levels == 0
        || levels > maximum
        || (!compressed && levels != 1)
        || (compressed && (width % 4 != 0 || height % 4 != 0))
    {
        bail!("invalid model mip chain dimensions");
    }
    let count = if mipmaps && !compressed {
        maximum
    } else {
        levels
    };
    let format = if compressed {
        TextureFormat::Bc3RgbaUnorm
    } else {
        TextureFormat::Rgba8Unorm
    };
    let srgb = format.add_srgb_suffix();
    let texture = device.create_texture(&TextureDescriptor {
        label: Some("model image"),
        size: Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        },
        mip_level_count: count,
        sample_count: 1,
        dimension: TextureDimension::D2,
        format,
        usage: TextureUsages::TEXTURE_BINDING
            | TextureUsages::COPY_DST
            | if compressed {
                TextureUsages::empty()
            } else {
                TextureUsages::RENDER_ATTACHMENT
            },
        view_formats: &[srgb],
    });
    let mut offset = 0;
    for level in 0..levels {
        let w = (width >> level).max(1);
        let h = (height >> level).max(1);
        let pitch = if compressed {
            w.div_ceil(4) * 16
        } else {
            w * 4
        };
        let rows = if compressed { h.div_ceil(4) } else { h };
        let end = offset + pitch as usize * rows as usize;
        let data = pixels
            .get(offset..end)
            .context("truncated model image mip")?;
        queue.write_texture(
            TexelCopyTextureInfo {
                texture: &texture,
                mip_level: level,
                origin: Origin3d::ZERO,
                aspect: TextureAspect::All,
            },
            data,
            TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(pitch),
                rows_per_image: Some(rows),
            },
            Extent3d {
                width: if compressed { w.next_multiple_of(4) } else { w },
                height: if compressed { h.next_multiple_of(4) } else { h },
                depth_or_array_layers: 1,
            },
        );
        offset = end;
    }
    if offset != pixels.len() {
        bail!("model image has trailing mip bytes");
    }
    if count > levels {
        generate_mips(device, queue, &texture);
    }
    Ok([
        texture.create_view(&Default::default()),
        texture.create_view(&TextureViewDescriptor {
            format: Some(srgb),
            ..Default::default()
        }),
    ])
}

pub(super) fn generate_mips(device: &Device, queue: &Queue, texture: &wgpu::Texture) {
    if texture.mip_level_count() <= 1 {
        return;
    }
    let shader = device.create_shader_module(ShaderModuleDescriptor { label: Some("model mipmaps"), source: ShaderSource::Wgsl(Cow::Borrowed(r#"
        @group(0) @binding(0) var image: texture_2d<f32>;
        @group(0) @binding(1) var imageSampler: sampler;
        struct Vertex { @builtin(position) position: vec4<f32>, @location(0) uv: vec2<f32> }
        @vertex fn vertexMain(@builtin(vertex_index) i: u32) -> Vertex {
            let uv = vec2<f32>(f32((i << 1u) & 2u), f32(i & 2u));
            return Vertex(vec4<f32>(uv * vec2<f32>(2.0,-2.0) + vec2<f32>(-1.0,1.0),0.0,1.0),uv);
        }
        @fragment fn fragmentMain(v: Vertex) -> @location(0) vec4<f32> { return textureSample(image,imageSampler,v.uv); }
    "#)) });
    let pipeline = device.create_render_pipeline(&RenderPipelineDescriptor {
        label: Some("model mipmaps"),
        layout: None,
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
                format: texture.format(),
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
    let sampler = device.create_sampler(&SamplerDescriptor {
        min_filter: FilterMode::Linear,
        mag_filter: FilterMode::Linear,
        ..Default::default()
    });
    let mut encoder = device.create_command_encoder(&Default::default());
    for layer in 0..texture.depth_or_array_layers() {
        for level in 1..texture.mip_level_count() {
            let source = texture.create_view(&TextureViewDescriptor {
                dimension: Some(TextureViewDimension::D2),
                base_array_layer: layer,
                array_layer_count: Some(1),
                base_mip_level: level - 1,
                mip_level_count: Some(1),
                ..Default::default()
            });
            let destination = texture.create_view(&TextureViewDescriptor {
                dimension: Some(TextureViewDimension::D2),
                base_array_layer: layer,
                array_layer_count: Some(1),
                base_mip_level: level,
                mip_level_count: Some(1),
                ..Default::default()
            });
            let group = device.create_bind_group(&BindGroupDescriptor {
                label: Some("model mip"),
                layout: &pipeline.get_bind_group_layout(0),
                entries: &[
                    BindGroupEntry {
                        binding: 0,
                        resource: BindingResource::TextureView(&source),
                    },
                    BindGroupEntry {
                        binding: 1,
                        resource: BindingResource::Sampler(&sampler),
                    },
                ],
            });
            let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
                label: Some("model mip"),
                color_attachments: &[Some(RenderPassColorAttachment {
                    view: &destination,
                    depth_slice: None,
                    resolve_target: None,
                    ops: Operations {
                        load: LoadOp::Clear(Color::TRANSPARENT),
                        store: StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            pass.set_pipeline(&pipeline);
            pass.set_bind_group(0, &group, &[]);
            pass.draw(0..3, 0..1);
        }
    }
    queue.submit([encoder.finish()]);
}
