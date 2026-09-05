//! One GPU-driven draw, end to end, on a real device.
//!
//! The cull compacts, the args pass writes an indirect draw, the vertex shader
//! reads the instance the compaction chose, and the material dispatch decides
//! the color. Everything but the surface is here, so what this proves is that
//! the whole chain from a packet's instance to a G-buffer texel works rather
//! than that each link compiles.
//!
//! A machine with no adapter skips rather than fails.

use std::borrow::Cow;
use std::path::Path;

use wgpu::{
    BindGroupDescriptor, BindGroupEntry, BindingResource, BufferDescriptor, BufferUsages,
    CommandEncoderDescriptor, ErrorFilter, Extent3d, LoadOp, MapMode, Operations, Origin3d,
    PollType, RenderPassColorAttachment, RenderPassDepthStencilAttachment, RenderPassDescriptor,
    SamplerDescriptor, ShaderModuleDescriptor, ShaderSource, StoreOp, TexelCopyBufferInfo,
    TexelCopyBufferLayout, TexelCopyTextureInfo, TextureAspect, TextureDescriptor,
    TextureDimension, TextureFormat, TextureUsages, TextureViewDescriptor,
};

use crate::culltests::{Harness, TestBatch, TestInstance};
use crate::graph::{parse_graph, tests::deferred};
use crate::graphics::{build_passes, instance_source, Layouts};
use crate::packet::LANE_OPAQUE;
use crate::shaderpack::ShaderPack;

/// Wide enough that one row of RGBA8 is exactly the copy alignment, so the
/// readback needs no padding arithmetic.
const SIZE: u32 = 64;

fn engine_pack() -> ShaderPack {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../assets/materials")
        .canonicalize()
        .expect("the engine material directory is in the tree");
    ShaderPack::assemble(&directory).expect("the engine material set assembles")
}

/// Runs the cull and the geometry pass over one scene and returns the albedo
/// attachment as RGBA8 rows.
fn render(harness: &Harness, instances: &[TestInstance]) -> Vec<u8> {
    let device = &harness.device;
    let scope = device.push_error_scope(ErrorFilter::Validation);
    let batches = vec![TestBatch {
        lane: LANE_OPAQUE,
        first: 0,
        count: instances.len() as u32,
    }];
    let view = [-2.0, -2.0, 2.0, 2.0];
    let culled = harness.dispatch(instances, &batches, view, 8);

    let layouts = Layouts::new(device);
    let module = device.create_shader_module(ShaderModuleDescriptor {
        label: Some("tecs instance"),
        source: ShaderSource::Wgsl(Cow::Owned(instance_source(&engine_pack()))),
    });
    let graph = parse_graph(&deferred()).expect("the deferred graph decodes");
    let passes = build_passes(
        device,
        &layouts,
        &module,
        &graph,
        TextureFormat::Bgra8UnormSrgb,
    )
    .expect("the deferred graph builds");
    let geometry = passes[0]
        .pipeline
        .as_ref()
        .expect("geometry has a pipeline");

    // The G-buffer, at the formats the graph declares.
    let attachments: Vec<_> = ["albedo", "normal", "orm", "emission"]
        .iter()
        .map(|name| {
            device.create_texture(&TextureDescriptor {
                label: Some(name),
                size: Extent3d {
                    width: SIZE,
                    height: SIZE,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: TextureDimension::D2,
                format: TextureFormat::Rgba8UnormSrgb,
                usage: TextureUsages::RENDER_ATTACHMENT | TextureUsages::COPY_SRC,
                view_formats: &[],
            })
        })
        .collect();
    let depth = device.create_texture(&TextureDescriptor {
        label: Some("depth"),
        size: Extent3d {
            width: SIZE,
            height: SIZE,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: TextureDimension::D2,
        format: TextureFormat::Depth32Float,
        usage: TextureUsages::RENDER_ATTACHMENT,
        view_formats: &[],
    });

    // The view the packet's header describes, in the layout the scene uniform
    // takes: the target size, the camera, its zoom and its rotation.
    let scene = [SIZE as f32, SIZE as f32, 0.0, 0.0, 16.0, 0.0, 0.0, 0.0];
    let scene_buffer = device.create_buffer(&BufferDescriptor {
        label: Some("scene"),
        size: 32,
        usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    harness
        .queue
        .write_buffer(&scene_buffer, 0, bytemuck::cast_slice(&scene));
    let scene_group = device.create_bind_group(&BindGroupDescriptor {
        label: Some("scene"),
        layout: &layouts.scene,
        entries: &[BindGroupEntry {
            binding: 0,
            resource: scene_buffer.as_entire_binding(),
        }],
    });

    // The backend's own white fallback, which is what an instance with no image
    // samples and what makes an untextured quad draw its tint unchanged.
    let white = device.create_texture(&TextureDescriptor {
        label: Some("white"),
        size: Extent3d {
            width: 1,
            height: 1,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: TextureDimension::D2,
        format: TextureFormat::Rgba8UnormSrgb,
        usage: TextureUsages::TEXTURE_BINDING | TextureUsages::COPY_DST,
        view_formats: &[],
    });
    harness.queue.write_texture(
        TexelCopyTextureInfo {
            texture: &white,
            mip_level: 0,
            origin: Origin3d::ZERO,
            aspect: TextureAspect::All,
        },
        &[255_u8, 255, 255, 255],
        TexelCopyBufferLayout {
            offset: 0,
            bytes_per_row: Some(4),
            rows_per_image: Some(1),
        },
        Extent3d {
            width: 1,
            height: 1,
            depth_or_array_layers: 1,
        },
    );
    let sampler = device.create_sampler(&SamplerDescriptor {
        label: Some("nearest"),
        ..Default::default()
    });
    let image_group = device.create_bind_group(&BindGroupDescriptor {
        label: Some("image"),
        layout: &layouts.image,
        entries: &[
            BindGroupEntry {
                binding: 0,
                resource: BindingResource::TextureView(
                    &white.create_view(&TextureViewDescriptor::default()),
                ),
            },
            BindGroupEntry {
                binding: 1,
                resource: BindingResource::Sampler(&sampler),
            },
        ],
    });

    // One batch, so the dynamic offset the draw selects is zero and the buffer
    // holds one index.
    let batch_index = device.create_buffer(&BufferDescriptor {
        label: Some("batch index"),
        size: 256,
        usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    harness
        .queue
        .write_buffer(&batch_index, 0, &0_u32.to_ne_bytes());
    let draw_group = device.create_bind_group(&BindGroupDescriptor {
        label: Some("draw"),
        layout: &layouts.draw,
        entries: &[
            BindGroupEntry {
                binding: 0,
                resource: culled.instances.as_entire_binding(),
            },
            BindGroupEntry {
                binding: 1,
                resource: culled.visible.as_entire_binding(),
            },
            BindGroupEntry {
                binding: 2,
                resource: culled.batch_base.as_entire_binding(),
            },
            BindGroupEntry {
                binding: 3,
                resource: BindingResource::Buffer(wgpu::BufferBinding {
                    buffer: &batch_index,
                    offset: 0,
                    size: std::num::NonZeroU64::new(4),
                }),
            },
        ],
    });

    let views: Vec<_> = attachments
        .iter()
        .map(|texture| texture.create_view(&TextureViewDescriptor::default()))
        .collect();
    let depth_view = depth.create_view(&TextureViewDescriptor::default());
    let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor {
        label: Some("geometry"),
    });
    {
        let color: Vec<Option<RenderPassColorAttachment>> = views
            .iter()
            .map(|view| {
                Some(RenderPassColorAttachment {
                    view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: Operations {
                        load: LoadOp::Clear(wgpu::Color::TRANSPARENT),
                        store: StoreOp::Store,
                    },
                })
            })
            .collect();
        let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
            label: Some("geometry"),
            color_attachments: &color,
            depth_stencil_attachment: Some(RenderPassDepthStencilAttachment {
                view: &depth_view,
                depth_ops: Some(Operations {
                    load: LoadOp::Clear(1.0),
                    store: StoreOp::Store,
                }),
                stencil_ops: None,
            }),
            ..Default::default()
        });
        pass.set_pipeline(geometry);
        pass.set_bind_group(0, &scene_group, &[]);
        pass.set_bind_group(1, &image_group, &[]);
        pass.set_bind_group(2, &draw_group, &[0]);
        pass.draw_indirect(&culled.draw_args, 0);
    }

    let readback = device.create_buffer(&BufferDescriptor {
        label: Some("albedo readback"),
        size: u64::from(SIZE) * u64::from(SIZE) * 4,
        usage: BufferUsages::COPY_DST | BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    encoder.copy_texture_to_buffer(
        TexelCopyTextureInfo {
            texture: &attachments[0],
            mip_level: 0,
            origin: Origin3d::ZERO,
            aspect: TextureAspect::All,
        },
        TexelCopyBufferInfo {
            buffer: &readback,
            layout: TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(SIZE * 4),
                rows_per_image: Some(SIZE),
            },
        },
        Extent3d {
            width: SIZE,
            height: SIZE,
            depth_or_array_layers: 1,
        },
    );
    harness.queue.submit([encoder.finish()]);

    readback.slice(..).map_async(MapMode::Read, |_| {});
    device
        .poll(PollType::wait_indefinitely())
        .expect("the queue drains");
    let pixels = readback
        .slice(..)
        .get_mapped_range()
        .expect("the buffer maps")
        .to_vec();

    let error = pollster::block_on(scope.pop());
    assert!(error.is_none(), "{error:?}");

    pixels
}

/// The texel at the middle of the target, where every quad here covers.
fn center(pixels: &[u8]) -> [u8; 4] {
    let at = ((SIZE / 2) * SIZE + SIZE / 2) as usize * 4;
    pixels[at..at + 4].try_into().expect("four channels")
}

/// A texel just inside the quad's corner, which a circle inscribed in the quad
/// does not reach.
fn corner(pixels: &[u8]) -> [u8; 4] {
    // The quad spans the middle half of the target, so this is one texel inside
    // its top left corner and well outside a circle inscribed in it.
    let x = SIZE / 4 + 1;
    let y = SIZE / 4 + 1;
    let at = (y * SIZE + x) as usize * 4;
    pixels[at..at + 4].try_into().expect("four channels")
}

#[test]
fn draws_the_instance_the_compaction_chose() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the draw tests");
        return;
    };
    // Two quads: one over the middle of the target and one far outside the
    // view. The cull drops the second, so the draw is one instance long and
    // what lands in the middle is the first one's tint.
    let pixels = render(
        &harness,
        &[
            TestInstance::opaque(0.0, 0.0),
            TestInstance::opaque(100_000.0, 0.0),
        ],
    );
    assert_eq!(
        center(&pixels),
        [255, 255, 255, 255],
        "the surviving instance covers the middle of the target"
    );
    // A texel outside the quad keeps the attachment's clear, which is what
    // proves the draw is bounded by the geometry rather than covering the
    // target the way a fullscreen pass would.
    assert_eq!(&pixels[0..4], [0, 0, 0, 0], "the clear survives outside it");
}

#[test]
fn dispatches_to_the_material_the_instance_names() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the draw tests");
        return;
    };
    let pack = engine_pack();
    let circle = pack
        .materials()
        .iter()
        .position(|name| name == "circle")
        .expect("the engine set has a circle") as u32;

    // The default material covers the whole quad, so its corner is drawn.
    let textured = render(&harness, &[TestInstance::opaque(0.0, 0.0)]);
    assert_eq!(center(&textured), [255, 255, 255, 255]);
    assert_eq!(
        corner(&textured),
        [255, 255, 255, 255],
        "`textured` covers the quad's corner"
    );

    // `circle` returns a coverage its corner fails, so the same geometry with a
    // different material id keeps the clear there. Nothing but the id differs
    // between the two draws, so the dispatch is what decided it.
    let inscribed = render(
        &harness,
        &[TestInstance {
            material: circle,
            ..TestInstance::opaque(0.0, 0.0)
        }],
    );
    assert_eq!(center(&inscribed), [255, 255, 255, 255]);
    assert_eq!(
        corner(&inscribed),
        [0, 0, 0, 0],
        "`circle` discards the quad's corner"
    );
}
