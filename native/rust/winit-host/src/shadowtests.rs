//! The shadow lane, from the cast list the cull fills to the two targets the
//! three draws write, on a real device.
//!
//! What this exists to prove is the part that has no shape a reader can check:
//! that an occluder's run names itself and nothing else, that a drop-shadow
//! caster keeps its lights by weight rather than by buffer order, that the
//! occluder mask carries the caster's height where the caster actually is, and
//! that a stretched copy lands on the far side of its caster from the light that
//! threw it.
//!
//! A machine with no adapter skips rather than fails.

use std::borrow::Cow;
use std::path::Path;

use wgpu::{
    AddressMode, BindGroupDescriptor, BindGroupEntry, BindingResource, BufferDescriptor,
    BufferUsages, CommandEncoderDescriptor, Extent3d, FilterMode, LoadOp, MipmapFilterMode,
    Operations, Origin3d, RenderPassColorAttachment, RenderPassDescriptor, SamplerDescriptor,
    ShaderModuleDescriptor, ShaderSource, StoreOp, TexelCopyBufferInfo, TexelCopyBufferLayout,
    TexelCopyTextureInfo, TextureAspect, TextureDescriptor, TextureDimension, TextureFormat,
    TextureUsages, TextureViewDescriptor,
};

use crate::culltests::{Harness, TestBatch, TestInstance, TestLight};
use crate::graph::{
    parse_graph,
    tests::{deferred, pass_at},
};
use crate::graphics::{build_passes, cast_source, instance_source, Layouts};
use crate::packet::{Header, CAST_FANOUT, FRAME_SHADOWS, LANE_OPAQUE, SCENE_FLOATS};
use crate::shaderpack::ShaderPack;

/// Wide enough that one row of RGBA8 is exactly the copy alignment.
const SIZE: u32 = 64;

/// The three constants `cast.wgsl` and `cull.wgsl` share.
const CAST_LIGHT_BITS: u32 = 9;
const CAST_LIGHT_MASK: u32 = 0x1ff;
const CAST_EMPTY: u32 = 0x1fe;
const CAST_NONE: u32 = 0x1ff;

const FLAG_OCCLUDER: u32 = 2;
const FLAG_DROP_SHADOW: u32 = 4;

const CAST_MODE_MASK: u32 = 0;
const CAST_MODE_SHADOW: u32 = 1;
const CAST_MODE_STAMP: u32 = 2;

fn engine_pack() -> ShaderPack {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../assets/materials")
        .canonicalize()
        .expect("the engine material directory is in the tree");
    ShaderPack::assemble(&directory).expect("the engine material set assembles")
}

/// The header a shadow test draws through: one world unit to one pixel, camera
/// on the middle of the target, and no margin, so a mask texel is a target pixel
/// and a test can name a column.
fn header() -> Header {
    Header {
        graph_revision: 1,
        flags: FRAME_SHADOWS,
        target: [SIZE as f32, SIZE as f32],
        camera: [SIZE as f32 * 0.5, SIZE as f32 * 0.5],
        zoom: 1.0,
        rotation: 0.0,
        ambient: [0.0, 0.0, 0.0],
        shadow_steps: 32.0,
        shadow_height: 64.0,
        shadow_margin: 0.0,
        drop_opacity: 1.0,
        drop_length: 512.0,
        bloom: [0.8, 0.1, 0.7],
    }
}

fn entry_instance(entry: u32) -> u32 {
    entry >> CAST_LIGHT_BITS
}

fn entry_light(entry: u32) -> u32 {
    entry & CAST_LIGHT_MASK
}

/// Runs the cull over one scene and reads the cast list back.
fn cast_list(
    harness: &Harness,
    instances: &[TestInstance],
    lights: &[TestLight],
) -> (Vec<u32>, Vec<u32>) {
    let batches = vec![TestBatch {
        lane: LANE_OPAQUE,
        first: 0,
        count: instances.len() as u32,
    }];
    let view = [0.0, 0.0, SIZE as f32, SIZE as f32];
    let culled = harness.dispatch_with(instances, &batches, view, 16, lights, 0.0);
    let visible = harness.read_back(&culled.visible);
    let bases = harness.read_back(&culled.batch_base);
    let casters = instances.iter().filter(|held| held.cast != 0).count();
    let start = culled.cast_list_offset as usize;
    (
        visible[start..start + casters * CAST_FANOUT as usize].to_vec(),
        bases[culled.cast_base_offset as usize..].to_vec(),
    )
}

#[test]
fn names_an_occluder_and_nothing_else_in_its_run() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the shadow tests");
        return;
    };
    let instances = vec![
        TestInstance::casting(20.0, 32.0, FLAG_OCCLUDER, 1.0),
        TestInstance::opaque(30.0, 32.0),
    ];
    let lights = vec![TestLight {
        x: 10.0,
        y: 32.0,
        height: 16.0,
        radius: 64.0,
        intensity: 1.0,
    }];
    let (list, _) = cast_list(&harness, &instances, &lights);

    // An occluder's entries say so by naming no light, which is what tells the
    // two drop-shadow draws to leave it alone: it darkens nothing, it blocks.
    assert_eq!(list.len(), CAST_FANOUT as usize);
    assert_eq!(entry_instance(list[0]), 0);
    assert_eq!(entry_light(list[0]), CAST_NONE);
    // The rest of the run is filled rather than left, because a stale entry from
    // an earlier frame would draw a shadow for an instance that has gone.
    for entry in &list[1..] {
        assert_eq!(entry_light(*entry), CAST_EMPTY);
        assert_eq!(entry_instance(*entry), 0);
    }
}

#[test]
fn keeps_a_casters_lights_by_weight_rather_than_buffer_order() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the shadow tests");
        return;
    };
    let instances = vec![TestInstance::casting(32.0, 32.0, FLAG_DROP_SHADOW, 1.0)];
    // Five lights, weakest first in the buffer. Only four fit a run, so the
    // faintest has to be the one dropped: a cap that bound by buffer order would
    // drop whichever happened to sit last, which can be the brightest, and would
    // make a shadow pop when an unrelated light is spawned.
    let lights = vec![
        TestLight {
            x: 32.0,
            y: 32.0,
            height: 8.0,
            radius: 40.0,
            intensity: 0.2,
        },
        TestLight {
            x: 32.0,
            y: 32.0,
            height: 8.0,
            radius: 40.0,
            intensity: 0.9,
        },
        TestLight {
            x: 32.0,
            y: 32.0,
            height: 8.0,
            radius: 40.0,
            intensity: 0.4,
        },
        TestLight {
            x: 32.0,
            y: 32.0,
            height: 8.0,
            radius: 40.0,
            intensity: 1.0,
        },
        TestLight {
            x: 32.0,
            y: 32.0,
            height: 8.0,
            radius: 40.0,
            intensity: 0.6,
        },
    ];
    let (list, _) = cast_list(&harness, &instances, &lights);

    let named: Vec<u32> = list.iter().map(|entry| entry_light(*entry)).collect();
    assert_eq!(named, vec![3, 1, 4, 2], "strongest first, faintest dropped");
    for entry in &list {
        assert_eq!(entry_instance(*entry), 0);
    }
}

#[test]
fn fills_a_short_run_and_measures_a_batch_against_the_fan_out() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the shadow tests");
        return;
    };
    let instances = vec![
        TestInstance::casting(20.0, 32.0, FLAG_DROP_SHADOW, 1.0),
        TestInstance::opaque(24.0, 32.0),
        TestInstance::casting(40.0, 32.0, FLAG_OCCLUDER, 0.5),
    ];
    // One light, and a second too far away to be worth a copy: below the minimum
    // weight a caster spends no entry on it.
    let lights = vec![
        TestLight {
            x: 8.0,
            y: 32.0,
            height: 16.0,
            radius: 64.0,
            intensity: 1.0,
        },
        TestLight {
            x: 4000.0,
            y: 32.0,
            height: 16.0,
            radius: 64.0,
            intensity: 1.0,
        },
    ];
    let (list, bases) = cast_list(&harness, &instances, &lights);

    assert_eq!(list.len(), 2 * CAST_FANOUT as usize);
    assert_eq!(entry_light(list[0]), 0, "the near light throws the copy");
    for entry in &list[1..CAST_FANOUT as usize] {
        assert_eq!(entry_light(*entry), CAST_EMPTY);
    }
    // The occluder is the second caster, so its run begins at the fan-out.
    assert_eq!(entry_light(list[CAST_FANOUT as usize]), CAST_NONE);
    assert_eq!(entry_instance(list[CAST_FANOUT as usize]), 2);
    // One batch, holding both casters, so its base is zero and it draws every
    // entry: the fan-out is what turns a caster count into an entry count.
    assert_eq!(bases[0], 0);
}

/// Renders one shadow mode over one instance and returns the target's rows.
fn cast_render(
    harness: &Harness,
    instances: &[TestInstance],
    lights: &[TestLight],
    mode: u32,
    format: TextureFormat,
    clear: wgpu::Color,
) -> Vec<u8> {
    let device = &harness.device;
    let scope = device.push_error_scope(wgpu::ErrorFilter::Validation);
    let batches = vec![TestBatch {
        lane: LANE_OPAQUE,
        first: 0,
        count: instances.len() as u32,
    }];
    let view = [0.0, 0.0, SIZE as f32, SIZE as f32];
    let culled = harness.dispatch_with(instances, &batches, view, 16, lights, 0.0);

    let layouts = Layouts::new(device);
    let pack = engine_pack();
    let module = device.create_shader_module(ShaderModuleDescriptor {
        label: Some("tecs instance"),
        source: ShaderSource::Wgsl(Cow::Owned(instance_source(&pack))),
    });
    let casts = device.create_shader_module(ShaderModuleDescriptor {
        label: Some("tecs cast"),
        source: ShaderSource::Wgsl(Cow::Owned(cast_source(&pack))),
    });
    let graph = parse_graph(&deferred()).expect("the deferred graph decodes");
    let passes = build_passes(
        device,
        &layouts,
        &module,
        &casts,
        &graph,
        TextureFormat::Bgra8UnormSrgb,
    )
    .expect("the deferred graph builds");
    // The mask draw and the two drop-shadow draws differ only in their blend, and
    // the format they write comes from the target the graph declares.
    let pipeline = match mode {
        CAST_MODE_MASK => passes[pass_at("occluders")]
            .pipeline
            .as_ref()
            .expect("the mask draw has a pipeline"),
        CAST_MODE_SHADOW => passes[pass_at("dropShadowAO")]
            .pipeline
            .as_ref()
            .expect("the shadow draw has a pipeline"),
        _ => passes[pass_at("dropShadowAO")]
            .second
            .as_ref()
            .expect("the stamp draw has a pipeline"),
    };

    let read = header().scene(lights.len() as u32);
    let scene_buffer = device.create_buffer(&BufferDescriptor {
        label: Some("scene"),
        size: (SCENE_FLOATS * 4) as u64,
        usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    harness
        .queue
        .write_buffer(&scene_buffer, 0, bytemuck::cast_slice(&read));
    let scene_group = device.create_bind_group(&BindGroupDescriptor {
        label: Some("scene"),
        layout: &layouts.scene,
        entries: &[BindGroupEntry {
            binding: 0,
            resource: scene_buffer.as_entire_binding(),
        }],
    });

    // One opaque white texel, so a caster with no image casts the silhouette its
    // material decided rather than nothing.
    let fallback = device.create_texture(&TextureDescriptor {
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
            texture: &fallback,
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
        label: Some("image"),
        address_mode_u: AddressMode::ClampToEdge,
        address_mode_v: AddressMode::ClampToEdge,
        address_mode_w: AddressMode::ClampToEdge,
        mag_filter: FilterMode::Nearest,
        min_filter: FilterMode::Nearest,
        mipmap_filter: MipmapFilterMode::Nearest,
        ..Default::default()
    });
    let image_group = device.create_bind_group(&BindGroupDescriptor {
        label: Some("image"),
        layout: &layouts.image,
        entries: &[
            BindGroupEntry {
                binding: 0,
                resource: BindingResource::TextureView(
                    &fallback.create_view(&TextureViewDescriptor::default()),
                ),
            },
            BindGroupEntry {
                binding: 1,
                resource: BindingResource::Sampler(&sampler),
            },
        ],
    });

    let stride = device.limits().min_uniform_buffer_offset_alignment.max(4);
    let indices = device.create_buffer(&BufferDescriptor {
        label: Some("batch index"),
        size: u64::from(stride),
        usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    harness
        .queue
        .write_buffer(&indices, 0, &0_u32.to_ne_bytes());
    let modes = device.create_buffer(&BufferDescriptor {
        label: Some("cast modes"),
        size: u64::from(stride) * 3,
        usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let mut mode_bytes = vec![0_u8; (stride * 3) as usize];
    for value in [CAST_MODE_MASK, CAST_MODE_SHADOW, CAST_MODE_STAMP] {
        let at = (value * stride) as usize;
        mode_bytes[at..at + 4].copy_from_slice(&value.to_ne_bytes());
    }
    harness.queue.write_buffer(&modes, 0, &mode_bytes);

    let cast_group = device.create_bind_group(&BindGroupDescriptor {
        label: Some("cast"),
        layout: &layouts.cast,
        entries: &[
            BindGroupEntry {
                binding: 0,
                resource: culled.instances.as_entire_binding(),
            },
            BindGroupEntry {
                binding: 1,
                resource: BindingResource::Buffer(wgpu::BufferBinding {
                    buffer: &culled.visible,
                    offset: u64::from(culled.cast_list_offset) * 4,
                    size: None,
                }),
            },
            BindGroupEntry {
                binding: 2,
                resource: BindingResource::Buffer(wgpu::BufferBinding {
                    buffer: &culled.batch_base,
                    offset: u64::from(culled.cast_base_offset) * 4,
                    size: None,
                }),
            },
            BindGroupEntry {
                binding: 3,
                resource: BindingResource::Buffer(wgpu::BufferBinding {
                    buffer: &indices,
                    offset: 0,
                    size: std::num::NonZeroU64::new(4),
                }),
            },
            BindGroupEntry {
                binding: 4,
                resource: culled.lights.as_entire_binding(),
            },
            BindGroupEntry {
                binding: 5,
                resource: BindingResource::Buffer(wgpu::BufferBinding {
                    buffer: &modes,
                    offset: 0,
                    size: std::num::NonZeroU64::new(4),
                }),
            },
        ],
    });

    let bytes_per_texel = if format == TextureFormat::R8Unorm {
        1
    } else {
        4
    };
    let target = device.create_texture(&TextureDescriptor {
        label: Some("cast target"),
        size: Extent3d {
            width: SIZE,
            height: SIZE,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: TextureDimension::D2,
        format,
        usage: TextureUsages::RENDER_ATTACHMENT | TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let target_view = target.create_view(&TextureViewDescriptor::default());
    // One row of R8 is 64 bytes, so the readback rounds up to the copy alignment
    // and the rows are unpacked below.
    let row = (SIZE * bytes_per_texel).max(256);
    let readback = device.create_buffer(&BufferDescriptor {
        label: Some("readback"),
        size: u64::from(row) * u64::from(SIZE),
        usage: BufferUsages::COPY_DST | BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });

    let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor { label: None });
    {
        let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
            label: Some("cast"),
            color_attachments: &[Some(RenderPassColorAttachment {
                view: &target_view,
                depth_slice: None,
                resolve_target: None,
                ops: Operations {
                    load: LoadOp::Clear(clear),
                    store: StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        pass.set_pipeline(pipeline);
        pass.set_bind_group(0, &scene_group, &[]);
        pass.set_bind_group(1, &image_group, &[]);
        pass.set_bind_group(2, &cast_group, &[0, mode * stride]);
        // The shadow lane's arguments follow the drawing lanes' in the same
        // buffer, one set per batch each.
        pass.draw_indirect(&culled.draw_args, 16);
    }
    encoder.copy_texture_to_buffer(
        TexelCopyTextureInfo {
            texture: &target,
            mip_level: 0,
            origin: Origin3d::ZERO,
            aspect: TextureAspect::All,
        },
        TexelCopyBufferInfo {
            buffer: &readback,
            layout: TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(row),
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

    readback.slice(..).map_async(wgpu::MapMode::Read, |_| {});
    device
        .poll(wgpu::PollType::wait_indefinitely())
        .expect("the queue drains");
    let view = readback
        .slice(..)
        .get_mapped_range()
        .expect("the buffer maps after the queue drains");
    let mut rows = Vec::with_capacity((SIZE * SIZE * bytes_per_texel) as usize);
    for line in 0..SIZE as usize {
        let at = line * row as usize;
        rows.extend_from_slice(&view[at..at + (SIZE * bytes_per_texel) as usize]);
    }
    drop(view);
    readback.unmap();

    let error = pollster::block_on(scope.pop());
    assert!(error.is_none(), "{error:?}");
    rows
}

fn texel(rows: &[u8], x: u32, y: u32, channels: u32) -> &[u8] {
    let at = ((y * SIZE + x) * channels) as usize;
    &rows[at..at + channels as usize]
}

#[test]
fn writes_a_casters_height_where_the_caster_stands() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the shadow tests");
        return;
    };
    // A ten by ten occluder at the middle of the target. The mask has no margin
    // here, so a mask texel is a target pixel and the silhouette lands on the
    // pixels the caster covers.
    let mut caster = TestInstance::casting(32.0, 32.0, FLAG_OCCLUDER, 1.0);
    caster.scale = 10.0;
    let rows = cast_render(
        &harness,
        &[caster],
        &[],
        CAST_MODE_MASK,
        TextureFormat::Rgba8UnormSrgb,
        wgpu::Color::TRANSPARENT,
    );

    // Green marks a pixel an occluder really covers, which is what lets the
    // raymarch tell a silhouette from the halo the blur spreads around one.
    let inside = texel(&rows, 32, 32, 4);
    assert!(inside[1] > 200, "the marker is set: {inside:?}");
    assert!(inside[0] > 200, "a full-height caster: {inside:?}");
    let outside = texel(&rows, 8, 8, 4);
    assert_eq!(outside[1], 0, "nothing outside the silhouette");

    // Half the height, in the same place, and the marker is the same: the marker
    // is membership and the red is how tall.
    let mut short = TestInstance::casting(32.0, 32.0, FLAG_OCCLUDER, 0.25);
    short.scale = 10.0;
    let shallow = cast_render(
        &harness,
        &[short],
        &[],
        CAST_MODE_MASK,
        TextureFormat::Rgba8UnormSrgb,
        wgpu::Color::TRANSPARENT,
    );
    let lowered = texel(&shallow, 32, 32, 4);
    assert!(lowered[1] > 200, "still covered: {lowered:?}");
    assert!(lowered[0] < inside[0], "{lowered:?} against {inside:?}");
}

#[test]
fn throws_a_stretched_copy_away_from_the_light() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the shadow tests");
        return;
    };
    // A caster at the middle and a light to its left, so the copy falls to the
    // right. The light stands well above the caster, which bounds the reach.
    let mut caster = TestInstance::casting(32.0, 32.0, FLAG_DROP_SHADOW, 0.5);
    caster.scale = 8.0;
    // The light stands twice the caster's own height, which by similar triangles
    // throws the copy to the caster's height again beyond its feet: a light
    // barely clearing a tall caster would throw it to the horizon, which is what
    // the length bound is for.
    let lights = vec![TestLight {
        x: 8.0,
        y: 36.0,
        height: 8.0,
        radius: 96.0,
        intensity: 1.0,
    }];
    let rows = cast_render(
        &harness,
        &[caster],
        &lights,
        CAST_MODE_SHADOW,
        TextureFormat::R8Unorm,
        wgpu::Color::WHITE,
    );

    // Darkened on the far side of the caster's feet from the light, and left
    // alone on the light's own side.
    let away = texel(&rows, 44, 36, 1)[0];
    let toward = texel(&rows, 20, 36, 1)[0];
    assert!(away < 128, "the copy lands away from the light: {away}");
    assert!(
        toward > 200,
        "nothing between the caster and its light: {toward}"
    );

    // Moving the light to the other side moves the copy with it. A shadow is
    // thrown by where the light is rather than by where the caster faces.
    let mirrored = vec![TestLight {
        x: 56.0,
        y: 36.0,
        height: 8.0,
        radius: 96.0,
        intensity: 1.0,
    }];
    let flipped = cast_render(
        &harness,
        &[caster],
        &mirrored,
        CAST_MODE_SHADOW,
        TextureFormat::R8Unorm,
        wgpu::Color::WHITE,
    );
    assert!(texel(&flipped, 20, 36, 1)[0] < 128, "the copy follows");
    assert!(
        texel(&flipped, 44, 36, 1)[0] > 200,
        "and leaves the far side"
    );
}

#[test]
fn stamps_a_caster_back_over_the_shadow_it_threw() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the shadow tests");
        return;
    };
    // The stamp writes one wherever the caster itself covers, which is what puts
    // it back at full brightness over the shadow that fell across its own feet.
    let mut caster = TestInstance::casting(32.0, 32.0, FLAG_DROP_SHADOW, 0.5);
    caster.scale = 8.0;
    let lights = vec![TestLight {
        x: 8.0,
        y: 32.0,
        height: 32.0,
        radius: 96.0,
        intensity: 1.0,
    }];
    let rows = cast_render(
        &harness,
        &[caster],
        &lights,
        CAST_MODE_STAMP,
        TextureFormat::R8Unorm,
        wgpu::Color::BLACK,
    );
    assert!(texel(&rows, 32, 32, 1)[0] > 200, "the caster is restored");
    assert_eq!(texel(&rows, 8, 8, 1)[0], 0, "and nothing else is");

    // An occluder is not stamped: it darkens nothing, so there is nothing of its
    // own to put back.
    let mut blocker = TestInstance::casting(32.0, 32.0, FLAG_OCCLUDER, 1.0);
    blocker.scale = 8.0;
    let untouched = cast_render(
        &harness,
        &[blocker],
        &lights,
        CAST_MODE_STAMP,
        TextureFormat::R8Unorm,
        wgpu::Color::BLACK,
    );
    assert_eq!(texel(&untouched, 32, 32, 1)[0], 0);
}

#[test]
fn draws_the_same_shadow_twice() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the shadow tests");
        return;
    };
    // Several casters and several lights, which is where an ordering that was
    // not deterministic would show: the blend resolves overlap by a minimum, and
    // the list the draws walk is the ordered compaction's.
    let instances: Vec<TestInstance> = (0..8)
        .map(|index| {
            let mut held = TestInstance::casting(
                8.0 + index as f32 * 6.0,
                20.0 + (index % 3) as f32 * 12.0,
                if index % 3 == 0 {
                    FLAG_OCCLUDER
                } else {
                    FLAG_DROP_SHADOW
                },
                0.3 + index as f32 * 0.08,
            );
            held.scale = 6.0;
            held
        })
        .collect();
    let lights: Vec<TestLight> = (0..4)
        .map(|index| TestLight {
            x: 6.0 + index as f32 * 15.0,
            y: 12.0 + index as f32 * 9.0,
            height: 20.0 + index as f32 * 4.0,
            radius: 80.0,
            intensity: 0.8,
        })
        .collect();

    let first = cast_render(
        &harness,
        &instances,
        &lights,
        CAST_MODE_SHADOW,
        TextureFormat::R8Unorm,
        wgpu::Color::WHITE,
    );
    let second = cast_render(
        &harness,
        &instances,
        &lights,
        CAST_MODE_SHADOW,
        TextureFormat::R8Unorm,
        wgpu::Color::WHITE,
    );
    assert_eq!(first, second, "the same scene casts the same shadows");
    assert!(
        first.iter().any(|value| *value < 255),
        "something was actually shadowed"
    );
}
