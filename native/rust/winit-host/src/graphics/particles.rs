//! GPU particle pools. Emitter packets cross the ABI; particle state never does.
//! The original emit/spawn/simulate shaders feed the ordinary sprite cull and
//! indirect draw path. Multiple views share one simulation and recull its output.
use super::*;
use crate::packet::Header;

const EFFECT_FLOATS: usize = 69;
const EMITTER_FLOATS: usize = 24;
const STATE_BYTES: u64 = 32;
const MAX_PARTICLES: u32 = 4_000_000;

pub(super) struct Packet<'a> {
    pub id: u32,
    serial: u32,
    pub capacity: u32,
    pub maximum: u32,
    dt: f32,
    alpha: f32,
    effects: &'a [u8],
    pub emitters: Vec<(u32, u32, &'a [u8])>,
}
fn word(bytes: &[u8], at: usize) -> u32 {
    u32::from_ne_bytes(bytes[at..at + 4].try_into().unwrap())
}
fn float(bytes: &[u8], at: usize) -> f32 {
    f32::from_bits(word(bytes, at * 4))
}
fn integer(value: f32, limit: u32) -> Result<u32> {
    if !value.is_finite() || value < 0. || value.fract() != 0. || value > limit as f32 {
        bail!("invalid particle integer");
    }
    Ok(value as u32)
}
pub(super) fn parse(bytes: &[u8]) -> Result<Packet<'_>> {
    if bytes.len() < 40 || word(bytes, 0) != 0x54505443 || word(bytes, 4) != 2 {
        bail!("invalid particle packet");
    }
    let id = word(bytes, 8);
    let serial = word(bytes, 12);
    let capacity = word(bytes, 16);
    let maximum = word(bytes, 20);
    let dt = float(bytes, 6);
    let alpha = float(bytes, 7);
    let length = word(bytes, 32) as usize;
    let count = word(bytes, 36) as usize;
    if id == 0
        || capacity == 0
        || capacity > MAX_PARTICLES
        || maximum == 0
        || maximum > 65536
        || count > maximum as usize
        || !dt.is_finite()
        || dt <= 0.
        || !alpha.is_finite()
        || !(0. ..=1.).contains(&alpha)
        || !length.is_multiple_of(4)
        || length > 65536 * 4
        || bytes.len() != 40 + length + count * 104
    {
        bail!("invalid particle packet limits");
    }
    let effects = &bytes[40..40 + length];
    for at in 0..effects.len() / 4 {
        if !float(effects, at).is_finite() {
            bail!("nonfinite particle effect");
        }
    }
    let mut emitters = Vec::with_capacity(count);
    let mut seen = std::collections::HashSet::new();
    let mut ranges = Vec::new();
    for record in bytes[40 + length..].as_chunks::<104>().0 {
        let index = word(record, 0);
        let token = word(record, 4);
        let data = &record[8..];
        if token == 0 || index >= maximum || !seen.insert(index) {
            bail!("invalid or duplicate particle emitter");
        }
        for at in 0..EMITTER_FLOATS {
            if !float(data, at).is_finite() {
                bail!("nonfinite particle emitter");
            }
        }
        let effect = integer(float(data, 0), 65536)? as usize * EFFECT_FLOATS;
        if (effect + EFFECT_FLOATS) * 4 > effects.len() {
            bail!("particle emitter selects invalid effect");
        }
        let base = integer(float(data, 1), capacity)?;
        let slots = integer(float(data, 2), capacity)?;
        if slots == 0 || base + slots > capacity || float(data, 22) < 0. || float(data, 22) > 8. {
            bail!("invalid particle slot range or step count");
        }
        if float(data, 13) < 0. || float(data, 14) < 0. || float(data, 15) < 0. {
            bail!("invalid particle scale");
        }
        for (offset, width) in [(43, 32), (44, 128)] {
            let value = float(effects, effect + offset);
            if value >= 0. {
                let at = integer(value, 65536)? as usize;
                if at + width > effects.len() / 4 {
                    bail!("invalid particle curve range");
                }
            }
        }
        if float(effects, effect + 24) <= 0.
            || float(effects, effect + 25) < float(effects, effect + 24)
            || float(effects, effect + 38) < 0.
        {
            bail!("invalid particle lifetime or drag");
        }
        integer(float(effects, effect + 53), u32::MAX)?;
        ranges.push((base, base + slots));
        emitters.push((index, token, data));
    }
    ranges.sort_unstable();
    if ranges.windows(2).any(|pair| pair[0].1 > pair[1].0) {
        bail!("particle emitter ranges overlap");
    }
    emitters.sort_by_key(|(index, _, _)| *index);
    Ok(Packet {
        id,
        serial,
        capacity,
        maximum,
        dt,
        alpha,
        effects,
        emitters,
    })
}

pub(super) struct Pool {
    pub scratch: Scratch,
    pub batches: Vec<Batch>,
    capacity: u32,
    maximum: u32,
    serial: Option<u32>,
    effects: Buffer,
    emitters: Buffer,
    owners: Buffer,
    runtime: Buffer,
    states: Buffer,
    params: Buffer,
    pipelines: Vec<ComputePipeline>,
    group: BindGroup,
    source_effects: Vec<u8>,
    source_emitters: Vec<u8>,
    layout: Vec<(u32, u32, u32, u32, u32)>,
    frame_table: Option<Buffer>,
    last_cull: Vec<u32>,
    cull_dirty: bool,
    clear: Vec<(u64, u64)>,
    simulate: bool,
    highest: u32,
}
impl Pool {
    pub fn new(device: &Device, packet: &Packet<'_>, scratch: Scratch) -> Result<Self> {
        let size = u64::from(packet.capacity) * INSTANCE_STRIDE as u64;
        if size > device.limits().max_storage_buffer_binding_size
            || size > device.limits().max_buffer_size
        {
            bail!("particle pool exceeds adapter storage limit");
        }
        let buffer = |name, size, usage| {
            device.create_buffer(&BufferDescriptor {
                label: Some(name),
                size,
                usage,
                mapped_at_creation: false,
            })
        };
        let effects = buffer(
            "particle effects",
            65536 * 4,
            BufferUsages::STORAGE | BufferUsages::COPY_DST,
        );
        let emitters = buffer(
            "particle emitters",
            u64::from(packet.maximum) * 96,
            BufferUsages::STORAGE | BufferUsages::COPY_DST,
        );
        let owners = buffer(
            "particle owners",
            u64::from(packet.capacity) * 4,
            BufferUsages::STORAGE | BufferUsages::COPY_DST,
        );
        let runtime = buffer(
            "particle runtime",
            u64::from(packet.maximum) * 32,
            BufferUsages::STORAGE | BufferUsages::COPY_DST,
        );
        let states = buffer(
            "particle states",
            u64::from(packet.capacity) * STATE_BYTES,
            BufferUsages::STORAGE | BufferUsages::COPY_DST | BufferUsages::COPY_SRC,
        );
        let params = buffer(
            "particle timing",
            32,
            BufferUsages::UNIFORM | BufferUsages::COPY_DST,
        );
        let entries: Vec<_> = (0..7)
            .map(|binding| BindGroupLayoutEntry {
                binding,
                visibility: ShaderStages::COMPUTE,
                ty: BindingType::Buffer {
                    ty: if binding == 6 {
                        BufferBindingType::Uniform
                    } else {
                        BufferBindingType::Storage {
                            read_only: binding < 3,
                        }
                    },
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            })
            .collect();
        let layout = device.create_bind_group_layout(&BindGroupLayoutDescriptor {
            label: Some("particles"),
            entries: &entries,
        });
        let pipeline_layout = device.create_pipeline_layout(&PipelineLayoutDescriptor {
            label: Some("particles"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let pipelines = [
            include_str!("../../../../../assets/shaders/particle.emit.comp.glsl"),
            include_str!("../../../../../assets/shaders/particle.spawn.comp.glsl"),
            include_str!("../../../../../assets/shaders/particle.simulate.comp.glsl"),
        ]
        .into_iter()
        .map(|source| {
            let module = device.create_shader_module(ShaderModuleDescriptor {
                label: Some("particle compute"),
                source: ShaderSource::Glsl {
                    shader: Cow::Owned(format!(
                        "#version 450\n{}\n{}",
                        include_str!("../../../../../assets/shaders/particle.glsl"),
                        source.trim_start_matches("#version 450")
                    )),
                    stage: wgpu::naga::ShaderStage::Compute,
                    defines: Default::default(),
                },
            });
            device.create_compute_pipeline(&ComputePipelineDescriptor {
                label: Some("particle compute"),
                layout: Some(&pipeline_layout),
                module: &module,
                entry_point: Some("main"),
                compilation_options: Default::default(),
                cache: None,
            })
        })
        .collect();
        let buffers = [
            &effects,
            &emitters,
            &owners,
            &runtime,
            &states,
            &scratch.instances,
            &params,
        ];
        let entries: Vec<_> = buffers
            .into_iter()
            .enumerate()
            .map(|(binding, buffer)| BindGroupEntry {
                binding: binding as u32,
                resource: buffer.as_entire_binding(),
            })
            .collect();
        let group = device.create_bind_group(&BindGroupDescriptor {
            label: Some("particles"),
            layout: &layout,
            entries: &entries,
        });
        Ok(Self {
            scratch,
            batches: Vec::new(),
            capacity: packet.capacity,
            maximum: packet.maximum,
            serial: None,
            effects,
            emitters,
            owners,
            runtime,
            states,
            params,
            pipelines,
            group,
            source_effects: Vec::new(),
            source_emitters: Vec::new(),
            layout: Vec::new(),
            frame_table: None,
            last_cull: Vec::new(),
            cull_dirty: true,
            clear: Vec::new(),
            simulate: false,
            highest: 0,
        })
    }
    pub fn update(&mut self, queue: &Queue, packet: &Packet<'_>) -> Result<()> {
        if self.capacity != packet.capacity || self.maximum != packet.maximum {
            bail!("particle pool limits changed while live");
        }
        if self.serial == Some(packet.serial) {
            return Ok(());
        }
        self.serial = Some(packet.serial);
        let mut layout = Vec::with_capacity(packet.emitters.len());
        for (index, token, data) in &packet.emitters {
            layout.push((
                *index,
                float(data, 1) as u32,
                float(data, 2) as u32,
                float(data, 0) as u32,
                *token,
            ));
        }
        let changed = self.layout != layout;
        let effects_changed = self.source_effects != packet.effects;
        if effects_changed {
            queue.write_buffer(&self.effects, 0, packet.effects);
            self.source_effects = packet.effects.to_vec();
            self.simulate = true;
        }
        if changed {
            let mut owners = vec![0_u32; self.capacity as usize];
            for &(index, base, count, effect, token) in &layout {
                owners[base as usize..(base + count) as usize].fill(index + 1);
                if !self.layout.contains(&(index, base, count, effect, token)) {
                    queue.write_buffer(&self.runtime, u64::from(index) * 32, &[0; 32]);
                    self.clear.push((
                        u64::from(base) * STATE_BYTES,
                        u64::from(count) * STATE_BYTES,
                    ));
                }
            }
            queue.write_buffer(&self.owners, 0, bytemuck::cast_slice(&owners));
            self.layout = layout;
            self.simulate = true;
        }
        if changed || effects_changed {
            self.batches = self
                .layout
                .iter()
                .map(|&(_, first, count, effect, _)| {
                    let base = effect as usize * EFFECT_FLOATS;
                    Batch {
                        image: float(packet.effects, base + 53) as u32,
                        sampler: 0,
                        lane: if float(packet.effects, base + 64) > 0. {
                            LANE_BLEND
                        } else {
                            LANE_OPAQUE
                        },
                        first,
                        count,
                    }
                })
                .collect();
            // Pool-slot order makes every batch contiguous in the ordered cull.
            self.batches.sort_by_key(|batch| batch.first);
            let words: Vec<_> = self
                .batches
                .iter()
                .flat_map(|batch| {
                    [
                        batch.image,
                        batch.sampler,
                        batch.lane,
                        batch.first,
                        batch.count,
                    ]
                })
                .collect();
            if !words.is_empty() {
                queue.write_buffer(&self.scratch.batches, 0, bytemuck::cast_slice(&words));
            }
        }
        self.highest = packet.emitters.last().map_or(0, |(index, _, _)| index + 1);
        let mut emitters = vec![0_u8; self.highest as usize * 96];
        for (index, _, data) in &packet.emitters {
            emitters[*index as usize * 96..(*index as usize + 1) * 96].copy_from_slice(data);
        }
        if self.source_emitters != emitters {
            if !emitters.is_empty() {
                queue.write_buffer(&self.emitters, 0, &emitters);
            }
            self.source_emitters = emitters;
            self.simulate = true;
        }
        // A running field extrapolates between fixed ticks. A held field's
        // emitter record disables extrapolation in the simulation shader.
        let timing = [
            0_f32,
            8.,
            packet.dt,
            packet.alpha,
            0.,
            self.capacity as f32,
            self.highest as f32,
            0.,
        ];
        self.simulate |= packet
            .emitters
            .iter()
            .any(|(_, _, data)| float(data, 22) > 0. || float(data, 23) > 0.);
        if self.simulate {
            queue.write_buffer(&self.params, 0, bytemuck::cast_slice(&timing));
        }
        Ok(())
    }
    pub fn bind_frame_table(
        &mut self,
        device: &Device,
        layout: &BindGroupLayout,
        lights: &Buffer,
        frames: &Buffer,
    ) {
        if self.frame_table.as_ref() != Some(frames) {
            self.scratch.cull_group = rebind_cull(device, layout, &self.scratch, lights, frames);
            self.frame_table = Some(frames.clone());
            self.cull_dirty = true;
        }
    }
    pub fn prepare_cull(&mut self, queue: &Queue, header: &Header) {
        let view = header.world_view();
        let scratch = &self.scratch;
        let uniform = [
            view[0].to_bits(),
            view[1].to_bits(),
            view[2].to_bits(),
            view[3].to_bits(),
            self.capacity,
            self.capacity.div_ceil(WORKGROUP),
            scratch.instance_capacity,
            self.batches.len() as u32,
            0,
            0,
            cast_list_offset(scratch.instance_capacity),
            cast_base_offset(scratch.batch_capacity),
            0,
            0,
            0,
            0,
        ];
        if self.last_cull != uniform {
            queue.write_buffer(&scratch.cull_uniform, 0, bytemuck::cast_slice(&uniform));
            self.last_cull = uniform.to_vec();
            self.cull_dirty = true;
        }
    }
    pub fn dispatch(&mut self, encoder: &mut wgpu::CommandEncoder, cull: &[ComputePipeline]) {
        for (offset, size) in self.clear.drain(..) {
            encoder.clear_buffer(&self.states, offset, Some(size));
        }
        if self.simulate {
            self.cull_dirty = true;
            let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor {
                label: Some("particle simulation"),
                timestamp_writes: None,
            });
            pass.set_bind_group(0, &self.group, &[]);
            for (index, pipeline) in self.pipelines.iter().enumerate() {
                pass.set_pipeline(pipeline);
                pass.dispatch_workgroups(
                    if index == 0 {
                        self.highest.div_ceil(64).max(1)
                    } else {
                        self.capacity.div_ceil(64)
                    },
                    1,
                    1,
                );
            }
            self.simulate = false;
        }
        if self.batches.is_empty() || !self.cull_dirty {
            return;
        }
        self.cull_dirty = false;
        let mut pass = encoder.begin_compute_pass(&ComputePassDescriptor {
            label: Some("particle ordered cull"),
            timestamp_writes: None,
        });
        pass.set_bind_group(0, &self.scratch.cull_group, &[]);
        for (index, pipeline) in cull[..4].iter().enumerate() {
            pass.set_pipeline(pipeline);
            pass.dispatch_workgroups(
                match index {
                    1 => 1,
                    3 => (self.batches.len() as u32).div_ceil(ARGS_WORKGROUP),
                    _ => self.capacity.div_ceil(WORKGROUP),
                },
                1,
                1,
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn frame(
        serial: u32,
        clock: f32,
        steps: f32,
        playing: f32,
        clear: f32,
        generation: f32,
    ) -> Vec<u8> {
        let mut effect = vec![0_f32; 69];
        for (at, value) in [
            (0, 60.),
            (14, 1.),
            (24, 1.),
            (25, 1.),
            (26, 60.),
            (27, 60.),
            (28, 8.),
            (29, 8.),
            (43, -1.),
            (44, -1.),
            (45, 1.),
            (48, 1.),
            (55, 0.5),
            (59, 0.5),
            (60, 0.5),
            (62, 1.),
        ] {
            effect[at] = value;
        }
        effect[67] = 65535.;
        effect[68] = 65535.;
        let emitter = [
            0_f32,
            0.,
            4.,
            playing,
            1.,
            generation,
            0.,
            clear,
            320.,
            180.,
            320.,
            180.,
            0.,
            1.,
            1.,
            1.,
            1.,
            1.,
            1.,
            1.,
            0.,
            clock,
            steps,
            steps.signum(),
        ];
        let mut data = Vec::new();
        for value in [
            0x54505443,
            2,
            1,
            serial,
            4,
            2,
            (1_f32 / 60.).to_bits(),
            0,
            276,
            1,
        ] {
            data.extend(value.to_ne_bytes());
        }
        data.extend_from_slice(bytemuck::cast_slice(&effect));
        data.extend(0_u32.to_ne_bytes());
        data.extend(1_u32.to_ne_bytes());
        data.extend_from_slice(bytemuck::cast_slice(&emitter));
        let old = crate::packet::tests::PacketBuilder::new()
            .graph(crate::graph::tests::deferred())
            .build();
        let mut packet = old[..128].to_vec();
        packet[4..8].copy_from_slice(&9_u32.to_ne_bytes());
        packet[8..12].copy_from_slice(&140_u32.to_ne_bytes());
        packet.extend(0_f32.to_ne_bytes());
        packet.extend(0_u32.to_ne_bytes());
        packet.extend((data.len() as u32).to_ne_bytes());
        packet.extend(data);
        packet.extend_from_slice(&old[128..]);
        packet
    }
    fn state(graphics: &Graphics) -> Vec<u8> {
        let source = &graphics.particle_pools[&1].states;
        let staging = graphics.device.create_buffer(&BufferDescriptor {
            label: Some("particle test readback"),
            size: 128,
            usage: BufferUsages::MAP_READ | BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let mut encoder = graphics
            .device
            .create_command_encoder(&CommandEncoderDescriptor::default());
        encoder.copy_buffer_to_buffer(source, 0, &staging, 0, 128);
        graphics.queue.submit([encoder.finish()]);
        let (tx, rx) = std::sync::mpsc::channel();
        staging
            .slice(..)
            .map_async(wgpu::MapMode::Read, move |result| {
                tx.send(result).unwrap();
            });
        graphics
            .device
            .poll(wgpu::PollType::wait_indefinitely())
            .unwrap();
        rx.recv().unwrap().unwrap();
        let bytes = staging.slice(..).get_mapped_range().unwrap().to_vec();
        staging.unmap();
        bytes
    }
    #[test]
    fn additive_particles_survive_transparent_scene_composition() {
        let probe = Instance::new(InstanceDescriptor::new_without_display_handle());
        if pollster::block_on(probe.request_adapter(&wgpu::RequestAdapterOptions::default()))
            .is_err()
        {
            return;
        }
        let mut graphics = Graphics::offscreen(640, 360).unwrap();
        let mut packet = frame(1, 1., 1., 1., -1., 1.);
        packet[140 + 40 + 64 * 4..140 + 40 + 65 * 4].copy_from_slice(&2_f32.to_ne_bytes());
        graphics.request_capture();
        graphics.render(&packet).unwrap();
        let image = graphics.take_capture().unwrap();
        let at = (180 * 640 + 320) * 4;
        assert!(
            image.rgba[at] > 200,
            "additive light must survive a zero-alpha scene and presentation"
        );
        assert!(image.rgba[at + 1] < 80);
    }
    #[test]
    fn restored_schedule_does_not_replay_old_bursts() {
        let probe = Instance::new(InstanceDescriptor::new_without_display_handle());
        if pollster::block_on(probe.request_adapter(&wgpu::RequestAdapterOptions::default()))
            .is_err()
        {
            return;
        }
        let mut graphics = Graphics::offscreen(640, 360).unwrap();
        let mut packet = frame(1, 31., 1., 1., -1., 1.);
        let effect = 140 + 40;
        for (index, value) in [(0, 0_f32), (5, 1.), (16, 0.), (17, 4.)] {
            packet[effect + index * 4..effect + index * 4 + 4]
                .copy_from_slice(&value.to_ne_bytes());
        }
        graphics.render(&packet).unwrap();
        assert!(
            state(&graphics).iter().all(|byte| *byte == 0),
            "an elapsed burst must not refill a restored field"
        );
        // Reusing precisely the same pool range must still clear the old GPU
        // runtime. The allocation token distinguishes a newly admitted emitter.
        let mut fresh = frame(2, 1., 1., 1., -1., 1.);
        let token = 140 + 40 + 276 + 4;
        fresh[token..token + 4].copy_from_slice(&2_u32.to_ne_bytes());
        graphics.render(&fresh).unwrap();
        assert_eq!(float(&state(&graphics), 4), 1.);
    }

    #[test]
    fn gpu_particles_emit_integrate_pause_clear_and_restart() {
        let probe = Instance::new(InstanceDescriptor::new_without_display_handle());
        if pollster::block_on(probe.request_adapter(&wgpu::RequestAdapterOptions::default()))
            .is_err()
        {
            return;
        }
        let mut graphics = Graphics::offscreen(640, 360).unwrap();
        graphics.request_capture();
        graphics.render(&frame(1, 1., 1., 1., -1., 1.)).unwrap();
        let first = graphics.take_capture().unwrap();
        let at = (180 * 640 + 320) * 4;
        assert!(
            first.rgba[at] > 200,
            "GPU emitter draws through sprite geometry pass"
        );
        let born = state(&graphics);
        assert_eq!(float(&born, 0), 320.);
        assert_eq!(float(&born, 4), 1.);
        assert_eq!(float(&born, 5), 1.);
        graphics.render(&frame(2, 2., 1., 1., -1., 1.)).unwrap();
        let moved = state(&graphics);
        assert_eq!(
            float(&moved, 0),
            321.,
            "fixed step advances the live GPU state"
        );
        assert_eq!(float(&moved, 8), 320., "new particle starts at the emitter");
        graphics.render(&frame(3, 2., 0., 0., -1., 1.)).unwrap();
        assert_eq!(
            moved,
            state(&graphics),
            "paused field performs no integration"
        );
        graphics.request_capture();
        graphics.render(&frame(4, 2., 0., 0., 2.5, 1.)).unwrap();
        let cleared = graphics.take_capture().unwrap();
        assert!(
            cleared.rgba[at] < 10,
            "clear hides live particles immediately"
        );
        let mut restart = frame(5, 3., 1., 1., 2.5, 2.); // schedule and random cursor restart
        graphics.request_capture();
        graphics.render(&restart).unwrap();
        assert_eq!(
            first.rgba,
            graphics.take_capture().unwrap().rgba,
            "restarted field repeats its initial image"
        );
        restart[136..140].copy_from_slice(&1_u32.to_ne_bytes());
        assert!(
            graphics.render(&restart).is_err(),
            "malformed particle packets are rejected"
        );
    }
}
