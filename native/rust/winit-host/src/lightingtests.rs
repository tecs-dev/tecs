//! The deferred lighting resolve and the bloom threshold, run on a real device.
//!
//! These exist for the properties nothing about the shape of the code can show:
//! that a light's contribution falls off with distance and vanishes at its
//! radius, that authored occlusion reaches the ambient term and not a light,
//! that the drop-shadow mask darkens everything including the ambient, that the
//! occluder mask's march darkens a light and leaves the ambient alone, and that
//! the same inputs resolve to the same bytes twice.
//!
//! Every G-buffer input is an sRGB target, so a value uploaded as raw bytes has
//! to be encoded the way a render into one would have encoded it. `srgb_byte`
//! does that, and it is why the expectations below are written against linear
//! values rather than against the bytes.
//!
//! A machine with no adapter skips rather than fails.

use std::borrow::Cow;
use std::path::Path;

use wgpu::{
    AddressMode, BindGroupDescriptor, BindGroupEntry, BindingResource, BufferDescriptor,
    BufferUsages, CommandEncoderDescriptor, ComputePassDescriptor, ComputePipelineDescriptor,
    Device, ErrorFilter, Extent3d, FilterMode, LoadOp, MipmapFilterMode, Operations, Origin3d,
    PipelineCompilationOptions, PipelineLayoutDescriptor, RenderPassColorAttachment,
    RenderPassDescriptor, SamplerDescriptor, ShaderModuleDescriptor, ShaderSource, StoreOp,
    TexelCopyBufferInfo, TexelCopyBufferLayout, TexelCopyTextureInfo, TextureAspect,
    TextureDescriptor, TextureDimension, TextureFormat, TextureUsages, TextureView,
    TextureViewDescriptor,
};

use crate::culltests::Harness;
use crate::graph::{
    parse_graph,
    tests::{deferred, pass_at},
};
use crate::graphics::{build_passes, cast_source, instance_source, Layouts};
use crate::packet::{Header, FRAME_BLOOM, FRAME_SHADOWS, LIGHT_STRIDE, SCENE_FLOATS};
use crate::shaderpack::ShaderPack;

const LIGHTBIN_WGSL: &str = include_str!("../../../../assets/shaders/wgsl/lightbin.wgsl");

/// Wide enough that one row of RGBA16F is a whole multiple of the copy
/// alignment, so the readback needs no padding arithmetic.
const SIZE: u32 = 64;

const LIGHT_TILES: u32 = 32;
const LIGHT_TILE_SLOTS: u32 = 64;
const LIGHT_TILE_COUNT: u32 = LIGHT_TILES * LIGHT_TILES;

/// One light, in the order the packet's light table writes it.
#[derive(Clone, Copy, Debug)]
struct Light {
    x: f32,
    y: f32,
    height: f32,
    radius: f32,
    color: [f32; 3],
    intensity: f32,
}

impl Light {
    fn white(x: f32, y: f32, height: f32, radius: f32, intensity: f32) -> Self {
        Self {
            x,
            y,
            height,
            radius,
            color: [1.0, 1.0, 1.0],
            intensity,
        }
    }

    fn words(&self) -> [f32; 8] {
        [
            self.x,
            self.y,
            self.height,
            self.radius,
            self.color[0],
            self.color[1],
            self.color[2],
            self.intensity,
        ]
    }
}

/// What one resolve is run over.
struct Scene {
    ambient: [f32; 3],
    shadows: bool,
    bloom: bool,
    lights: Vec<Light>,
    /// Linear rgba the whole albedo target is filled with.
    albedo: [f32; 4],
    /// The `lit` flag every normal texel carries.
    lit: f32,
    /// Linear rgba the whole emission target is filled with.
    emission: [f32; 4],
    /// Linear ambient occlusion in the ORM red channel.
    occlusion: f32,
    /// How much of all lighting reaches every pixel, before any drop shadow.
    drop_shadow: f32,
    /// Height and marker for one band of the occluder mask, as a half-open
    /// range of columns in mask texels.
    occluder: Option<(u32, u32, f32)>,
}

impl Default for Scene {
    fn default() -> Self {
        Self {
            ambient: [0.0, 0.0, 0.0],
            shadows: false,
            bloom: false,
            lights: Vec::new(),
            albedo: [1.0, 1.0, 1.0, 1.0],
            lit: 1.0,
            emission: [0.0, 0.0, 0.0, 0.0],
            occlusion: 1.0,
            drop_shadow: 1.0,
            occluder: None,
        }
    }
}

fn engine_pack() -> ShaderPack {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../assets/materials")
        .canonicalize()
        .expect("the engine material directory is in the tree");
    ShaderPack::assemble(&directory).expect("the engine material set assembles")
}

/// Encodes a linear value the way a render into an sRGB target would have.
///
/// A texture written with `write_texture` takes the bytes as they are, so a test
/// that uploads a G-buffer has to apply the transfer the geometry pass would
/// have applied on its behalf.
fn srgb_byte(linear: f32) -> u8 {
    let encoded = if linear <= 0.003_130_8 {
        linear * 12.92
    } else {
        1.055 * linear.powf(1.0 / 2.4) - 0.055
    };
    (encoded.clamp(0.0, 1.0) * 255.0).round() as u8
}

/// The nearest half-float to a value, for a test that uploads a wide target.
///
/// Round to nearest is not needed: every value a bloom test writes is exactly
/// representable, and truncating one that is not would still test the threshold.
fn f32_to_half(value: f32) -> u16 {
    let bits = value.to_bits();
    let sign = ((bits >> 16) & 0x8000) as u16;
    let exponent = ((bits >> 23) & 0xff) as i32 - 127;
    let fraction = bits & 0x7f_ffff;
    if exponent < -14 {
        return sign;
    }
    if exponent > 15 {
        return sign | 0x7bff;
    }
    sign | (((exponent + 15) as u16) << 10) | ((fraction >> 13) as u16)
}

fn half_to_f32(bits: u16) -> f32 {
    let sign = if bits & 0x8000 != 0 { -1.0 } else { 1.0 };
    let exponent = i32::from((bits >> 10) & 0x1f);
    let fraction = f32::from(bits & 0x3ff);
    let magnitude = if exponent == 0 {
        fraction * 2.0_f32.powi(-24)
    } else if exponent == 31 {
        f32::INFINITY
    } else {
        (1.0 + fraction / 1024.0) * 2.0_f32.powi(exponent - 15)
    };
    sign * magnitude
}

/// A header describing the test's view, which is one world unit to one pixel
/// with the camera on the middle of the target.
fn header(scene: &Scene) -> Header {
    let mut flags = 0;
    if scene.shadows {
        flags |= FRAME_SHADOWS;
    }
    if scene.bloom {
        flags |= FRAME_BLOOM;
    }
    Header {
        graph_revision: 1,
        flags,
        target: [SIZE as f32, SIZE as f32],
        camera: [SIZE as f32 * 0.5, SIZE as f32 * 0.5],
        zoom: 1.0,
        rotation: 0.0,
        ambient: scene.ambient,
        shadow_steps: 32.0,
        shadow_height: 64.0,
        // No margin, so the occluder mask covers exactly the view and a mask
        // texel is a target pixel. That is what lets a test place an occluder by
        // column.
        shadow_margin: 0.0,
        drop_opacity: 0.4,
        drop_length: 512.0,
        bloom: [0.8, 0.1, 0.7],
    }
}

/// Fills one texture with a repeating texel.
fn filled(
    harness: &Harness,
    label: &str,
    format: TextureFormat,
    texel: &[u8],
) -> (wgpu::Texture, TextureView) {
    let mut pixels = Vec::with_capacity((SIZE * SIZE) as usize * texel.len());
    for _ in 0..SIZE * SIZE {
        pixels.extend_from_slice(texel);
    }
    written(harness, label, format, &pixels, texel.len() as u32)
}

fn written(
    harness: &Harness,
    label: &str,
    format: TextureFormat,
    pixels: &[u8],
    bytes_per_texel: u32,
) -> (wgpu::Texture, TextureView) {
    let size = Extent3d {
        width: SIZE,
        height: SIZE,
        depth_or_array_layers: 1,
    };
    let texture = harness.device.create_texture(&TextureDescriptor {
        label: Some(label),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: TextureDimension::D2,
        format,
        usage: TextureUsages::TEXTURE_BINDING | TextureUsages::COPY_DST,
        view_formats: &[],
    });
    harness.queue.write_texture(
        TexelCopyTextureInfo {
            texture: &texture,
            mip_level: 0,
            origin: Origin3d::ZERO,
            aspect: TextureAspect::All,
        },
        pixels,
        TexelCopyBufferLayout {
            offset: 0,
            bytes_per_row: Some(SIZE * bytes_per_texel),
            rows_per_image: Some(SIZE),
        },
        size,
    );
    let view = texture.create_view(&TextureViewDescriptor::default());
    (texture, view)
}

/// Runs the light binning, the lighting resolve, and a readback of `lit`.
///
/// Returns one linear rgba per pixel, row major.
fn resolve(harness: &Harness, scene: &Scene) -> Vec<[f32; 4]> {
    let device = &harness.device;
    let scope = device.push_error_scope(ErrorFilter::Validation);
    let header = header(scene);
    let read = header.scene(scene.lights.len() as u32);
    assert_eq!(read.len(), SCENE_FLOATS);

    // The G-buffer, uploaded rather than drawn, so a resolve can be run over
    // exactly the surface a test means.
    let albedo = filled(
        harness,
        "albedo",
        TextureFormat::Rgba8UnormSrgb,
        &[
            srgb_byte(scene.albedo[0]),
            srgb_byte(scene.albedo[1]),
            srgb_byte(scene.albedo[2]),
            (scene.albedo[3] * 255.0).round() as u8,
        ],
    );
    // Facing the viewer, which is what a flat 2D surface writes.
    let normal = filled(
        harness,
        "normal",
        TextureFormat::Rgba8UnormSrgb,
        &[
            srgb_byte(0.5),
            srgb_byte(0.5),
            srgb_byte(1.0),
            (scene.lit * 255.0).round() as u8,
        ],
    );
    let orm = filled(
        harness,
        "orm",
        TextureFormat::Rgba8UnormSrgb,
        &[srgb_byte(scene.occlusion), srgb_byte(0.5), 0, 255],
    );
    let emission = filled(
        harness,
        "emission",
        TextureFormat::Rgba8UnormSrgb,
        &[
            srgb_byte(scene.emission[0]),
            srgb_byte(scene.emission[1]),
            srgb_byte(scene.emission[2]),
            (scene.emission[3] * 255.0).round() as u8,
        ],
    );

    let mut mask = Vec::with_capacity((SIZE * SIZE) as usize * 4);
    for _ in 0..SIZE {
        for column in 0..SIZE {
            match scene.occluder {
                Some((first, last, height)) if column >= first && column < last => {
                    mask.extend_from_slice(&[srgb_byte(height), 255, 0, 255]);
                }
                _ => mask.extend_from_slice(&[0, 0, 0, 255]),
            }
        }
    }
    let occluders = written(
        harness,
        "occluders",
        TextureFormat::Rgba8UnormSrgb,
        &mask,
        4,
    );
    // One channel and not sRGB, so the byte is the value.
    let drop_shadow = filled(
        harness,
        "dropShadowAO",
        TextureFormat::R8Unorm,
        &[(scene.drop_shadow * 255.0).round() as u8],
    );

    let target = device.create_texture(&TextureDescriptor {
        label: Some("lit"),
        size: Extent3d {
            width: SIZE,
            height: SIZE,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: TextureDimension::D2,
        format: TextureFormat::Rgba16Float,
        usage: TextureUsages::RENDER_ATTACHMENT | TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let target_view = target.create_view(&TextureViewDescriptor::default());

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
    let lighting = &passes[pass_at("lighting")];

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

    let mut light_bytes = vec![0_u8; LIGHT_STRIDE.max(scene.lights.len() * LIGHT_STRIDE)];
    for (index, light) in scene.lights.iter().enumerate() {
        for (lane, value) in light.words().iter().enumerate() {
            let at = index * LIGHT_STRIDE + lane * 4;
            light_bytes[at..at + 4].copy_from_slice(&value.to_ne_bytes());
        }
    }
    let lights = device.create_buffer(&BufferDescriptor {
        label: Some("lights"),
        size: light_bytes.len() as u64,
        usage: BufferUsages::STORAGE | BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    harness.queue.write_buffer(&lights, 0, &light_bytes);
    let tile_counts = device.create_buffer(&BufferDescriptor {
        label: Some("tile counts"),
        size: u64::from(LIGHT_TILE_COUNT) * 4,
        usage: BufferUsages::STORAGE | BufferUsages::COPY_SRC,
        mapped_at_creation: false,
    });
    let tile_lights = device.create_buffer(&BufferDescriptor {
        label: Some("tile lights"),
        size: u64::from(LIGHT_TILE_COUNT) * u64::from(LIGHT_TILE_SLOTS) * 4,
        usage: BufferUsages::STORAGE | BufferUsages::COPY_SRC,
        mapped_at_creation: false,
    });
    let view = header.world_view();
    let bin_words: [u32; 8] = [
        view[0].to_bits(),
        view[1].to_bits(),
        view[2].to_bits(),
        view[3].to_bits(),
        scene.lights.len() as u32,
        0,
        0,
        0,
    ];
    let bin_uniform = device.create_buffer(&BufferDescriptor {
        label: Some("bin"),
        size: 32,
        usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    harness
        .queue
        .write_buffer(&bin_uniform, 0, bytemuck::cast_slice(&bin_words));
    let bin_group = device.create_bind_group(&BindGroupDescriptor {
        label: Some("bin"),
        layout: &layouts.bin,
        entries: &[
            BindGroupEntry {
                binding: 0,
                resource: lights.as_entire_binding(),
            },
            BindGroupEntry {
                binding: 1,
                resource: tile_counts.as_entire_binding(),
            },
            BindGroupEntry {
                binding: 2,
                resource: tile_lights.as_entire_binding(),
            },
            BindGroupEntry {
                binding: 3,
                resource: bin_uniform.as_entire_binding(),
            },
        ],
    });
    let bin_module = device.create_shader_module(ShaderModuleDescriptor {
        label: Some("lightbin"),
        source: ShaderSource::Wgsl(Cow::Borrowed(LIGHTBIN_WGSL)),
    });
    let bin_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
        label: Some("lightbin"),
        bind_group_layouts: &[Some(&layouts.bin)],
        immediate_size: 0,
    });
    let bin_pipeline = device.create_compute_pipeline(&ComputePipelineDescriptor {
        label: Some("lightbin"),
        layout: Some(&bin_layout),
        module: &bin_module,
        entry_point: Some("binMain"),
        compilation_options: PipelineCompilationOptions::default(),
        cache: None,
    });

    let sampler = device.create_sampler(&SamplerDescriptor {
        label: Some("pass sampler"),
        address_mode_u: AddressMode::ClampToEdge,
        address_mode_v: AddressMode::ClampToEdge,
        address_mode_w: AddressMode::ClampToEdge,
        mag_filter: FilterMode::Nearest,
        min_filter: FilterMode::Nearest,
        mipmap_filter: MipmapFilterMode::Nearest,
        ..Default::default()
    });
    let inputs = device.create_bind_group(&BindGroupDescriptor {
        label: Some("lighting inputs"),
        layout: lighting
            .input_layout
            .as_ref()
            .expect("a resolve binds its inputs"),
        entries: &[
            BindGroupEntry {
                binding: 0,
                resource: BindingResource::Sampler(&sampler),
            },
            BindGroupEntry {
                binding: 1,
                resource: BindingResource::TextureView(&albedo.1),
            },
            BindGroupEntry {
                binding: 2,
                resource: BindingResource::TextureView(&normal.1),
            },
            BindGroupEntry {
                binding: 3,
                resource: BindingResource::TextureView(&orm.1),
            },
            BindGroupEntry {
                binding: 4,
                resource: BindingResource::TextureView(&emission.1),
            },
            BindGroupEntry {
                binding: 5,
                resource: BindingResource::TextureView(&occluders.1),
            },
            BindGroupEntry {
                binding: 6,
                resource: BindingResource::TextureView(&drop_shadow.1),
            },
        ],
    });
    let light_group = device.create_bind_group(&BindGroupDescriptor {
        label: Some("lighting lights"),
        layout: &layouts.lighting,
        entries: &[
            BindGroupEntry {
                binding: 0,
                resource: lights.as_entire_binding(),
            },
            BindGroupEntry {
                binding: 1,
                resource: tile_counts.as_entire_binding(),
            },
            BindGroupEntry {
                binding: 2,
                resource: tile_lights.as_entire_binding(),
            },
        ],
    });

    let readback = device.create_buffer(&BufferDescriptor {
        label: Some("readback"),
        size: u64::from(SIZE) * u64::from(SIZE) * 8,
        usage: BufferUsages::COPY_DST | BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor { label: None });
    {
        let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor {
            label: Some("lightbin"),
            timestamp_writes: None,
        });
        pass.set_bind_group(0, &bin_group, &[]);
        pass.set_pipeline(&bin_pipeline);
        pass.dispatch_workgroups(LIGHT_TILE_COUNT.div_ceil(64), 1, 1);
    }
    {
        let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
            label: Some("lighting"),
            color_attachments: &[Some(RenderPassColorAttachment {
                view: &target_view,
                depth_slice: None,
                resolve_target: None,
                ops: Operations {
                    load: LoadOp::Clear(wgpu::Color::BLACK),
                    store: StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        pass.set_pipeline(lighting.pipeline.as_ref().expect("lighting has a pipeline"));
        pass.set_bind_group(0, &scene_group, &[]);
        pass.set_bind_group(1, &inputs, &[]);
        pass.set_bind_group(2, &light_group, &[]);
        pass.draw(0..3, 0..1);
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
                bytes_per_row: Some(SIZE * 8),
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

    let words = read_halves(device, &readback);
    let error = pollster::block_on(scope.pop());
    assert!(error.is_none(), "{error:?}");
    words.as_chunks::<4>().0.to_vec()
}

fn read_halves(device: &Device, buffer: &wgpu::Buffer) -> Vec<f32> {
    buffer.slice(..).map_async(wgpu::MapMode::Read, |_| {});
    device
        .poll(wgpu::PollType::wait_indefinitely())
        .expect("the queue drains");
    let view = buffer
        .slice(..)
        .get_mapped_range()
        .expect("the buffer maps after the queue drains");
    let values = view
        .as_chunks::<2>()
        .0
        .iter()
        .map(|chunk| half_to_f32(u16::from_ne_bytes(*chunk)))
        .collect();
    drop(view);
    buffer.unmap();
    values
}

fn at(pixels: &[[f32; 4]], x: u32, y: u32) -> [f32; 4] {
    pixels[(y * SIZE + x) as usize]
}

fn close(left: f32, right: f32, tolerance: f32) -> bool {
    (left - right).abs() <= tolerance
}

/// Runs the bloom threshold or one axis of its blur over a target filled with
/// one value per column, and reads what it wrote.
fn bloom(harness: &Harness, pass: &str, columns: &[f32], tuning: [f32; 3]) -> Vec<[f32; 4]> {
    let device = &harness.device;
    let scope = device.push_error_scope(ErrorFilter::Validation);
    let mut header = header(&Scene {
        bloom: true,
        ..Scene::default()
    });
    header.bloom = tuning;
    let read = header.scene(0);

    let mut pixels = Vec::with_capacity((SIZE * SIZE) as usize * 8);
    for _ in 0..SIZE {
        for column in 0..SIZE as usize {
            let value = columns[column % columns.len()];
            for lane in [value, value, value, 1.0] {
                pixels.extend_from_slice(&f32_to_half(lane).to_ne_bytes());
            }
        }
    }
    let source = written(harness, "lit", TextureFormat::Rgba16Float, &pixels, 8);

    let target = device.create_texture(&TextureDescriptor {
        label: Some("bloomA"),
        size: Extent3d {
            width: SIZE,
            height: SIZE,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: TextureDimension::D2,
        format: TextureFormat::Rgba16Float,
        usage: TextureUsages::RENDER_ATTACHMENT | TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let target_view = target.create_view(&TextureViewDescriptor::default());

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
    let runtime = &passes[pass_at(pass)];

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
    let sampler = device.create_sampler(&SamplerDescriptor {
        label: Some("pass sampler"),
        address_mode_u: AddressMode::ClampToEdge,
        address_mode_v: AddressMode::ClampToEdge,
        address_mode_w: AddressMode::ClampToEdge,
        mag_filter: FilterMode::Nearest,
        min_filter: FilterMode::Nearest,
        mipmap_filter: MipmapFilterMode::Nearest,
        ..Default::default()
    });
    let inputs = device.create_bind_group(&BindGroupDescriptor {
        label: Some("bloom input"),
        layout: runtime
            .input_layout
            .as_ref()
            .expect("a bloom pass binds its input"),
        entries: &[
            BindGroupEntry {
                binding: 0,
                resource: BindingResource::Sampler(&sampler),
            },
            BindGroupEntry {
                binding: 1,
                resource: BindingResource::TextureView(&source.1),
            },
        ],
    });

    let readback = device.create_buffer(&BufferDescriptor {
        label: Some("readback"),
        size: u64::from(SIZE) * u64::from(SIZE) * 8,
        usage: BufferUsages::COPY_DST | BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let mut encoder = device.create_command_encoder(&CommandEncoderDescriptor { label: None });
    {
        let mut pass = encoder.begin_render_pass(&RenderPassDescriptor {
            label: Some("bloom"),
            color_attachments: &[Some(RenderPassColorAttachment {
                view: &target_view,
                depth_slice: None,
                resolve_target: None,
                ops: Operations {
                    load: LoadOp::Clear(wgpu::Color::BLACK),
                    store: StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        pass.set_pipeline(runtime.pipeline.as_ref().expect("a bloom pass has one"));
        pass.set_bind_group(0, &scene_group, &[]);
        pass.set_bind_group(1, &inputs, &[]);
        pass.draw(0..3, 0..1);
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
                bytes_per_row: Some(SIZE * 8),
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

    let words = read_halves(device, &readback);
    let error = pollster::block_on(scope.pop());
    assert!(error.is_none(), "{error:?}");
    words.as_chunks::<4>().0.to_vec()
}

#[test]
fn extracts_only_what_passes_the_bloom_threshold() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the lighting tests");
        return;
    };
    // Four columns: well under the threshold, just under it, on it, and over.
    // The knee is narrow, so the first two extract nothing a viewer could see.
    let columns = [0.25_f32, 0.75, 1.0, 2.0];
    let extracted = bloom(&harness, "bloomExtract", &columns, [1.0, 0.05, 1.0]);

    let dark = at(&extracted, 0, 8)[0];
    let under = at(&extracted, 1, 8)[0];
    let on = at(&extracted, 2, 8)[0];
    let over = at(&extracted, 3, 8)[0];
    assert!(dark < 0.01, "well under the threshold: {dark}");
    assert!(under < 0.05, "just under it: {under}");
    assert!(on < over, "{on} against {over}");
    // A pixel at twice the threshold keeps the whole of what it has over it.
    assert!(close(over, 1.0, 0.02), "{over}");

    // The knee is what keeps a surface crossing the threshold from popping: a
    // pixel just under it extracts a little rather than nothing at all.
    let softened = bloom(&harness, "bloomExtract", &columns, [1.0, 0.5, 1.0]);
    assert!(at(&softened, 1, 8)[0] > under, "the knee reaches below");

    // The intensity scales what comes out and nothing else.
    let halved = bloom(&harness, "bloomExtract", &columns, [1.0, 0.05, 0.5]);
    assert!(close(at(&halved, 3, 8)[0], over * 0.5, 0.02));
}

#[test]
fn spreads_the_bloom_blur_along_one_axis_at_a_time() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the lighting tests");
        return;
    };
    // One bright column in sixteen, away from either edge, so the horizontal blur
    // has somewhere to spread it and no tap clamps back onto the bright column.
    // The vertical blur has nothing to spread at all, because every row holds the
    // same values.
    let mut columns = [0.0_f32; 16];
    columns[8] = 1.0;
    let across = bloom(&harness, "bloomBlurX", &columns, [0.0, 0.1, 1.0]);
    let down = bloom(&harness, "bloomBlurY", &columns, [0.0, 0.1, 1.0]);

    // The center tap keeps the largest share and the neighbours take less the
    // further out they are, which is the Gaussian the two blurs share.
    let center = at(&across, 8, 8)[0];
    let one = at(&across, 9, 8)[0];
    let two = at(&across, 10, 8)[0];
    assert!(
        center > one && one > two && two > 0.0,
        "{center} {one} {two}"
    );
    assert!(close(center, 0.227, 0.01), "the center weight: {center}");

    // Every row holds the same values, so blurring down changes nothing: the two
    // passes are one shader over one axis each, and running the wrong one would
    // show here.
    assert!(close(at(&down, 8, 8)[0], 1.0, 0.01));
    assert!(close(at(&down, 9, 8)[0], 0.0, 0.01));
}

#[test]
fn falls_a_light_off_to_nothing_at_its_radius() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the lighting tests");
        return;
    };
    // One light directly over the middle of the target, reaching half of it.
    let scene = Scene {
        lights: vec![Light::white(32.0, 32.0, 16.0, 24.0, 1.0)],
        ..Scene::default()
    };
    let pixels = resolve(&harness, &scene);

    // Under the light the whole distance is its height, so the falloff is the
    // square of one less sixteen over twenty-four.
    let under = at(&pixels, 32, 32)[0];
    let expected = (1.0_f32 - 16.0 / 24.0).powi(2);
    assert!(close(under, expected, 0.01), "{under} against {expected}");

    // Falling off with distance, and exactly nothing past the radius: the reach
    // is bounded rather than merely small, which is what makes a light's cost
    // proportional to what it covers.
    let near = at(&pixels, 40, 32)[0];
    let far = at(&pixels, 48, 32)[0];
    assert!(under > near && near > far, "{under} {near} {far}");
    assert_eq!(at(&pixels, 60, 32)[0], 0.0, "past the radius");
    assert_eq!(at(&pixels, 0, 0)[0], 0.0, "a corner outside every light");
}

#[test]
fn adds_every_light_that_reaches_a_pixel() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the lighting tests");
        return;
    };
    let near = Light::white(24.0, 32.0, 8.0, 40.0, 1.0);
    let far = Light::white(40.0, 30.0, 12.0, 44.0, 0.7);
    let one = Scene {
        lights: vec![near],
        ..Scene::default()
    };
    let other = Scene {
        lights: vec![far],
        ..Scene::default()
    };
    let two = Scene {
        lights: vec![near, far],
        ..Scene::default()
    };
    let left = at(&resolve(&harness, &one), 32, 32)[0];
    let right = at(&resolve(&harness, &other), 32, 32)[0];
    let paired = at(&resolve(&harness, &two), 32, 32)[0];

    // Accumulation is a sum, so a pixel both lights reach takes exactly what the
    // two read separately add up to.
    assert!(left > 0.0 && right > 0.0, "{left} {right}");
    assert!(paired > left && paired > right, "{paired}");
    assert!(
        close(paired, left + right, 0.01),
        "{paired} against {left} plus {right}"
    );
}

#[test]
fn reaches_authored_occlusion_to_the_ambient_and_not_to_a_light() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the lighting tests");
        return;
    };
    let open = Scene {
        ambient: [0.5, 0.5, 0.5],
        lights: vec![Light::white(32.0, 32.0, 8.0, 64.0, 1.0)],
        ..Scene::default()
    };
    let occluded = Scene {
        occlusion: 0.25,
        ..Scene {
            ambient: [0.5, 0.5, 0.5],
            lights: vec![Light::white(32.0, 32.0, 8.0, 64.0, 1.0)],
            ..Scene::default()
        }
    };
    let bright = at(&resolve(&harness, &open), 32, 32)[0];
    let dim = at(&resolve(&harness, &occluded), 32, 32)[0];

    // A point light is a directionally known contribution and is not hidden by a
    // baked ambient term, so occlusion takes a quarter of the ambient half and
    // leaves the light where it was.
    let light = bright - 0.5;
    assert!(close(dim, 0.5 * 0.25 + light, 0.02), "{dim} from {bright}");
}

#[test]
fn darkens_the_ambient_with_the_drop_shadow_mask() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the lighting tests");
        return;
    };
    let lit = Scene {
        ambient: [0.6, 0.6, 0.6],
        shadows: true,
        drop_shadow: 1.0,
        ..Scene::default()
    };
    let shaded = Scene {
        ambient: [0.6, 0.6, 0.6],
        shadows: true,
        drop_shadow: 0.5,
        ..Scene::default()
    };
    let full = at(&resolve(&harness, &lit), 32, 32)[0];
    let half = at(&resolve(&harness, &shaded), 32, 32)[0];

    // This is the whole of what makes the drop shadow a different thing from the
    // occluder mask rather than a weaker one: the mask has no path to the
    // ambient term at all, and in a scene lit only by ambient it is nothing.
    assert!(close(full, 0.6, 0.01), "{full}");
    assert!(close(half, 0.3, 0.01), "{half}");

    // With the lane off the mask is not read, so the same target leaves the
    // resolve alone.
    let ignored = Scene {
        ambient: [0.6, 0.6, 0.6],
        shadows: false,
        drop_shadow: 0.5,
        ..Scene::default()
    };
    let untouched = at(&resolve(&harness, &ignored), 32, 32)[0];
    assert!(close(untouched, 0.6, 0.01), "{untouched}");
}

#[test]
fn marches_the_occluder_mask_between_a_pixel_and_its_light() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the lighting tests");
        return;
    };
    // A light on the left, a wall of full-height occluder down the middle, and
    // the pixels to its right in shadow. The light stands well below the wall's
    // world height, so the ray never clears it.
    let build = |occluder: Option<(u32, u32, f32)>| Scene {
        shadows: true,
        lights: vec![Light::white(4.0, 32.0, 24.0, 96.0, 1.0)],
        occluder,
        ..Scene::default()
    };
    let open = resolve(&harness, &build(None));
    // Twelve texels wide, because the march's step count follows the light's own
    // attenuation: a pixel at the fringe of a light's reach takes its floor of
    // four steps, and a band narrower than one of those strides is a band some
    // of those pixels step straight over. The real graph blurs the mask before
    // the march reads it, which widens every silhouette for exactly this reason;
    // this test uploads the mask directly and so has to be wide enough itself.
    let walled = resolve(&harness, &build(Some((26, 38, 1.0))));

    // Behind the wall, and darker for it.
    let behind_open = at(&open, 50, 32)[0];
    let behind_walled = at(&walled, 50, 32)[0];
    assert!(behind_open > 0.05, "the light reaches there at all");
    assert!(
        behind_walled < behind_open * 0.5,
        "{behind_walled} against {behind_open}"
    );

    // In front of the wall, on the light's own side, and untouched. A wall does
    // not shadow what stands between it and the light.
    let front_open = at(&open, 16, 32)[0];
    let front_walled = at(&walled, 16, 32)[0];
    assert!(
        close(front_open, front_walled, 0.02),
        "{front_walled} against {front_open}"
    );

    // A short occluder lets the ray over it, so the same wall at a tenth of the
    // height casts less than at full height.
    let short = resolve(&harness, &build(Some((26, 38, 0.05))));
    let behind_short = at(&short, 50, 32)[0];
    assert!(
        behind_short > behind_walled,
        "{behind_short} against {behind_walled}"
    );
}

#[test]
fn passes_an_unlit_surface_and_its_emission_through() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the lighting tests");
        return;
    };
    // A material that asked not to be lit passes through at its own color, plus
    // whatever it emits. Emission is the surface's own and is not lighting
    // reaching it, so no light and no shadow scales it.
    let unlit = Scene {
        lit: 0.0,
        albedo: [0.25, 0.25, 0.25, 1.0],
        emission: [1.0, 0.0, 0.0, 0.5],
        ambient: [1.0, 1.0, 1.0],
        lights: vec![Light::white(32.0, 32.0, 8.0, 64.0, 4.0)],
        ..Scene::default()
    };
    let pixel = at(&resolve(&harness, &unlit), 32, 32);
    assert!(close(pixel[0], 0.25 + 0.5, 0.02), "{pixel:?}");
    assert!(close(pixel[1], 0.25, 0.02), "{pixel:?}");

    // A lit surface in the dark still glows, and the drop shadow that darkens
    // the ground it stands on does not dim it.
    let glowing = Scene {
        emission: [0.0, 1.0, 0.0, 0.5],
        shadows: true,
        drop_shadow: 0.0,
        ..Scene::default()
    };
    let glow = at(&resolve(&harness, &glowing), 32, 32);
    assert!(close(glow[1], 0.5, 0.02), "{glow:?}");
    assert!(close(glow[0], 0.0, 0.02), "{glow:?}");
}

#[test]
fn resolves_the_same_scene_to_the_same_bytes_twice() {
    let Some(harness) = Harness::open() else {
        eprintln!("no wgpu adapter; skipping the lighting tests");
        return;
    };
    // Sixteen lights over one tile grid, a wall, and both shadow mechanisms on.
    // The binning gathers rather than scatters precisely so that this holds: a
    // tile's list comes out in light-buffer order every time, and accumulating
    // in a different order would sum to a different last bit.
    let build = || Scene {
        shadows: true,
        ambient: [0.1, 0.12, 0.15],
        drop_shadow: 0.75,
        occluder: Some((28, 36, 0.8)),
        lights: (0..16)
            .map(|index| {
                Light::white(
                    4.0 + index as f32 * 3.5,
                    8.0 + (index % 5) as f32 * 11.0,
                    6.0 + index as f32,
                    30.0 + index as f32 * 2.0,
                    0.6,
                )
            })
            .collect(),
        ..Scene::default()
    };
    let first = resolve(&harness, &build());
    let second = resolve(&harness, &build());
    assert_eq!(first, second, "the same scene resolves the same way");
    assert!(
        first.iter().any(|texel| texel[0] > 0.0),
        "the scene is not simply black"
    );
}
