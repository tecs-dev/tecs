// Cross-engine 2D sprite throughput benchmark, Bevy implementation.
// See ../SPEC.md for the scene contract.

use bevy::prelude::*;
use bevy::window::{PresentMode, WindowResolution};

// ---------- Scene constants (must match SPEC.md) ----------
const SCREEN_W: f32 = 1280.0;
const SCREEN_H: f32 = 720.0;
const SPACING: f32 = 40.0;
const AMP: f32 = 16.0;
const OMEGA: f32 = 2.0;
const FIT: f32 = 0.9;
const FRAMES_IN_SHEET: usize = 8;
const CULL_OFFSET: f32 = 1.0e7; // parks the culled half off-screen

#[derive(Component)]
struct Base {
    x: f32,
    y: f32,
    phase: f32,
    anim_off: f32,
}

#[derive(Resource)]
struct Cfg {
    count: usize,
    warmup: f64,
    measure: f64,
    moving: bool,
}

#[derive(Resource, Default)]
struct BenchState {
    measure_start: Option<f64>,
    samples: Vec<f64>,
    sum: f64,
    frames: u64,
}

fn env_num(name: &str, default: f64) -> f64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn main() {
    let count: usize = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(100_000);
    let cfg = Cfg {
        count,
        warmup: env_num("BENCH_WARMUP", 2.0),
        measure: env_num("BENCH_MEASURE", 5.0),
        moving: env_num("BENCH_MOVE", 1.0) != 0.0,
    };

    App::new()
        .add_plugins(
            DefaultPlugins
                .set(WindowPlugin {
                    primary_window: Some(Window {
                        title: "Bevy Sprite Throughput Benchmark".into(),
                        resolution: WindowResolution::new(SCREEN_W, SCREEN_H),
                        present_mode: PresentMode::Immediate, // vsync off
                        resizable: false,
                        ..default()
                    }),
                    ..default()
                })
                .set(ImagePlugin::default_nearest()),
        )
        .insert_resource(cfg)
        .init_resource::<BenchState>()
        .add_systems(Startup, setup)
        .add_systems(Update, (move_sprites, animate_sprites, measure))
        .run();
}

fn setup(
    mut commands: Commands,
    cfg: Res<Cfg>,
    asset_server: Res<AssetServer>,
    mut layouts: ResMut<Assets<TextureAtlasLayout>>,
) {
    let image = asset_server.load("running.png");
    // 3x3 grid of 32x35 cells; frames 0..=7 are valid (cell 8 unused).
    let layout = layouts.add(TextureAtlasLayout::from_grid(
        UVec2::new(32, 35),
        3,
        3,
        None,
        None,
    ));

    // Split: first `vis` sprites form a viewport-filling grid (drawn), the
    // rest sit far off-screen at +CULL_OFFSET (frustum-culled by Bevy's
    // visibility system). One run exercises both the draw and the cull path.
    let vis = cfg.count / 2;
    let cul = cfg.count - vis;
    let grid_v = (vis.max(1) as f64).sqrt().ceil() as usize;
    let grid_c = (cul.max(1) as f64).sqrt().ceil() as usize;
    let gw_v = (grid_v.saturating_sub(1)) as f32 * SPACING;
    let gw_c = (grid_c.saturating_sub(1)) as f32 * SPACING;

    // Camera centered on the visible grid, zoomed so it fills 90% of the
    // window height. OrthographicProjection.scale is world-units per pixel.
    let scale = if gw_v > 0.0 { gw_v / (SCREEN_H * FIT) } else { 1.0 };
    commands.spawn((
        Camera2d,
        OrthographicProjection {
            scale,
            ..OrthographicProjection::default_2d()
        },
    ));

    let base = move |i: usize| -> (f32, f32) {
        if i < vis {
            let row = (i / grid_v) as f32;
            let col = (i % grid_v) as f32;
            (-(gw_v / 2.0) + col * SPACING, -(gw_v / 2.0) + row * SPACING)
        } else {
            let j = i - vis;
            let row = (j / grid_c) as f32;
            let col = (j % grid_c) as f32;
            (CULL_OFFSET - gw_c / 2.0 + col * SPACING, -(gw_c / 2.0) + row * SPACING)
        }
    };

    let sprites = (0..cfg.count).map(move |i| {
        let (bx, by) = base(i);
        (
            Sprite::from_atlas_image(
                image.clone(),
                TextureAtlas { layout: layout.clone(), index: 0 },
            ),
            Transform::from_xyz(bx, by, 0.0),
            Base {
                x: bx,
                y: by,
                phase: i as f32 * 0.001,
                anim_off: i as f32 * 0.137,
            },
        )
    });
    commands.spawn_batch(sprites);
}

fn move_sprites(
    time: Res<Time<Real>>,
    cfg: Res<Cfg>,
    mut q: Query<(&mut Transform, &Base)>,
) {
    if !cfg.moving {
        return;
    }
    let t = time.elapsed_secs();
    let wt = OMEGA * t;
    for (mut tr, base) in q.iter_mut() {
        tr.translation.x = base.x + (wt + base.phase).sin() * AMP;
        tr.translation.y = base.y + (wt + base.phase).cos() * AMP;
    }
}

fn animate_sprites(time: Res<Time<Real>>, mut q: Query<(&mut Sprite, &Base)>) {
    let t = time.elapsed_secs();
    for (mut sprite, base) in q.iter_mut() {
        if let Some(atlas) = sprite.texture_atlas.as_mut() {
            atlas.index = ((t * 10.0 + base.anim_off).floor() as i64)
                .rem_euclid(FRAMES_IN_SHEET as i64) as usize;
        }
    }
}

fn measure(
    time: Res<Time<Real>>,
    cfg: Res<Cfg>,
    mut state: ResMut<BenchState>,
    mut exit: EventWriter<AppExit>,
) {
    let elapsed = time.elapsed_secs_f64();
    let dt = time.delta_secs_f64();
    if elapsed < cfg.warmup {
        return;
    }
    let measure_start = match state.measure_start {
        Some(s) => s,
        None => {
            state.measure_start = Some(elapsed);
            return;
        }
    };
    state.samples.push(dt);
    state.sum += dt;
    state.frames += 1;

    if elapsed - measure_start >= cfg.measure {
        let frames = state.frames.max(1);
        let mean_ms = (state.sum / frames as f64) * 1000.0;
        state.samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let n = state.samples.len().max(1);
        let p99_idx = ((0.99 * n as f64).ceil() as usize).clamp(1, n) - 1;
        let p99_ms = state.samples[p99_idx] * 1000.0;
        let fps = if mean_ms > 0.0 { 1000.0 / mean_ms } else { 0.0 };
        let low1 = if p99_ms > 0.0 { 1000.0 / p99_ms } else { 0.0 };
        println!(
            "RESULT,bevy,{},{},{:.4},{:.2},{:.2}",
            cfg.count, frames, mean_ms, fps, low1
        );
        exit.send(AppExit::Success);
    }
}
