//! Rapier-backed 2D physics behind a callback-free C ABI.
//!
//! LuaJIT owns no Rust allocation and receives no callbacks. A world is an
//! opaque allocation, bodies and colliders are generational arena handles,
//! and events are drained from contiguous buffers after each fixed step.

use std::collections::BTreeMap;
use std::ptr;
use std::slice;
use std::sync::mpsc::{self, Receiver};
use std::sync::OnceLock;

use rapier2d::prelude::*;
use serde::{Deserialize, Serialize};

use super::set_error;

static PHYSICS_WORKERS: OnceLock<u32> = OnceLock::new();

fn configure_workers(requested: u32) -> u32 {
    *PHYSICS_WORKERS.get_or_init(|| {
        let requested = requested.clamp(1, 64);
        if rayon::ThreadPoolBuilder::new()
            .num_threads(requested as usize)
            .thread_name(|index| format!("tecs-physics-{index}"))
            .build_global()
            .is_ok()
        {
            requested
        } else {
            rayon::current_num_threads().clamp(1, 64) as u32
        }
    })
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct TecsPhysicsHandle {
    pub index: u32,
    pub generation: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TecsPhysicsBodyDef {
    pub kind: u8,
    pub fixed_rotation: u8,
    pub bullet: u8,
    pub sleep_enabled: u8,
    pub x: f32,
    pub y: f32,
    pub angle: f32,
    pub gravity_scale: f32,
    pub linear_damping: f32,
    pub angular_damping: f32,
    pub entity: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TecsPhysicsColliderDef {
    pub shape: u8,
    pub sensor: u8,
    pub _padding: [u8; 2],
    pub half_width: f32,
    pub half_height: f32,
    pub radius: f32,
    pub length: f32,
    pub offset_x: f32,
    pub offset_y: f32,
    pub density: f32,
    pub friction: f32,
    pub restitution: f32,
    pub category_bits: u32,
    pub mask_bits: u32,
    pub group_index: i32,
    pub entity: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct TecsPhysicsMove {
    pub body: TecsPhysicsHandle,
    pub x: f32,
    pub y: f32,
    pub cosine: f32,
    pub sine: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct TecsPhysicsPairEvent {
    pub entity_a: u64,
    pub entity_b: u64,
    pub x: f32,
    pub y: f32,
    pub normal_x: f32,
    pub normal_y: f32,
    pub approach_speed: f32,
    pub started: u8,
    pub sensor: u8,
    pub hit: u8,
    pub _padding: [u8; 5],
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct TecsPhysicsRayHit {
    pub entity: u64,
    pub x: f32,
    pub y: f32,
    pub normal_x: f32,
    pub normal_y: f32,
    pub fraction: f32,
}

pub struct TecsPhysicsSnapshot {
    bytes: Box<[u8]>,
}

#[derive(Serialize, Deserialize)]
struct PhysicsSnapshot {
    gravity: Vector,
    integration_parameters: IntegrationParameters,
    islands: IslandManager,
    broad_phase: BroadPhaseBvh,
    narrow_phase: NarrowPhase,
    bodies: RigidBodySet,
    colliders: ColliderSet,
    impulse_joints: ImpulseJointSet,
    multibody_joints: MultibodyJointSet,
    ccd_solver: CCDSolver,
    substeps: u32,
    worker_count: u32,
}

pub struct TecsPhysicsWorld {
    world: PhysicsWorld,
    substeps: u32,
    worker_count: u32,
    collision_receiver: Receiver<CollisionEvent>,
    force_receiver: Receiver<ContactForceEvent>,
    event_handler: ChannelEventCollector,
    moves: Vec<TecsPhysicsMove>,
    events: Vec<TecsPhysicsPairEvent>,
}

fn body_handle(handle: TecsPhysicsHandle) -> RigidBodyHandle {
    RigidBodyHandle::from_raw_parts(handle.index, handle.generation)
}

fn collider_handle(handle: TecsPhysicsHandle) -> ColliderHandle {
    ColliderHandle::from_raw_parts(handle.index, handle.generation)
}

fn public_body_handle(handle: RigidBodyHandle) -> TecsPhysicsHandle {
    let (index, generation) = handle.into_raw_parts();
    TecsPhysicsHandle { index, generation }
}

fn public_collider_handle(handle: ColliderHandle) -> TecsPhysicsHandle {
    let (index, generation) = handle.into_raw_parts();
    TecsPhysicsHandle { index, generation }
}

fn body_type(kind: u8) -> RigidBodyType {
    match kind {
        1 => RigidBodyType::KinematicVelocityBased,
        2 => RigidBodyType::Dynamic,
        _ => RigidBodyType::Fixed,
    }
}

fn collision_groups(category_bits: u32, mask_bits: u32) -> InteractionGroups {
    InteractionGroups::new(
        Group::from_bits_truncate(category_bits),
        Group::from_bits_truncate(mask_bits),
        InteractionTestMode::And,
    )
}

fn make_channels() -> (
    Receiver<CollisionEvent>,
    Receiver<ContactForceEvent>,
    ChannelEventCollector,
) {
    let (collision_sender, collision_receiver) = mpsc::channel();
    let (force_sender, force_receiver) = mpsc::channel();
    (
        collision_receiver,
        force_receiver,
        ChannelEventCollector::new(collision_sender, force_sender),
    )
}

fn new_world(gravity_x: f32, gravity_y: f32, substeps: u32, worker_count: u32) -> TecsPhysicsWorld {
    let worker_count = configure_workers(worker_count);
    let mut world = PhysicsWorld {
        gravity: Vector::new(gravity_x, gravity_y),
        ..PhysicsWorld::default()
    };
    // A zero threshold makes every solved contact available as a hit event.
    world.integration_parameters.max_ccd_substeps = 1;
    let (collision_receiver, force_receiver, event_handler) = make_channels();
    TecsPhysicsWorld {
        world,
        substeps: substeps.max(1),
        worker_count,
        collision_receiver,
        force_receiver,
        event_handler,
        moves: Vec::new(),
        events: Vec::new(),
    }
}

fn entity_of_collider(world: &PhysicsWorld, handle: ColliderHandle) -> u64 {
    world
        .colliders
        .get(handle)
        .map(|collider| collider.user_data as u64)
        .unwrap_or(0)
}

fn collision_entities(
    world: &PhysicsWorld,
    first: ColliderHandle,
    second: ColliderHandle,
    sensor: bool,
) -> (u64, u64) {
    let first_entity = entity_of_collider(world, first);
    let second_entity = entity_of_collider(world, second);
    if !sensor {
        return (first_entity, second_entity);
    }
    let first_sensor = world.colliders.get(first).is_some_and(Collider::is_sensor);
    if first_sensor {
        (first_entity, second_entity)
    } else {
        (second_entity, first_entity)
    }
}

fn drain_events(world: &mut TecsPhysicsWorld) {
    world.events.clear();
    while let Ok(event) = world.collision_receiver.try_recv() {
        let sensor = event.sensor();
        let (entity_a, entity_b) =
            collision_entities(&world.world, event.collider1(), event.collider2(), sensor);
        world.events.push(TecsPhysicsPairEvent {
            entity_a,
            entity_b,
            started: u8::from(event.started()),
            sensor: u8::from(sensor),
            ..TecsPhysicsPairEvent::default()
        });
    }
    while let Ok(event) = world.force_receiver.try_recv() {
        let entity_a = entity_of_collider(&world.world, event.collider1);
        let entity_b = entity_of_collider(&world.world, event.collider2);
        let Some(pair) = world
            .world
            .narrow_phase
            .contact_pair(event.collider1, event.collider2)
        else {
            continue;
        };
        let Some(manifold) = pair
            .manifolds
            .iter()
            .find(|manifold| !manifold.data.solver_contacts.is_empty())
        else {
            continue;
        };
        let point = manifold.data.solver_contacts[0].point;
        let normal = event.max_force_direction;
        let velocity = |collider: ColliderHandle| {
            world
                .world
                .colliders
                .get(collider)
                .and_then(Collider::parent)
                .and_then(|body| world.world.bodies.get(body))
                .map(|body| body.velocity_at_point(point))
                .unwrap_or(Vector::ZERO)
        };
        let relative_velocity = velocity(event.collider2) - velocity(event.collider1);
        world.events.push(TecsPhysicsPairEvent {
            entity_a,
            entity_b,
            x: point.x,
            y: point.y,
            normal_x: normal.x,
            normal_y: normal.y,
            approach_speed: relative_velocity.dot(normal).abs(),
            hit: 1,
            ..TecsPhysicsPairEvent::default()
        });
    }
}

fn snapshot(world: &TecsPhysicsWorld) -> PhysicsSnapshot {
    PhysicsSnapshot {
        gravity: world.world.gravity,
        integration_parameters: world.world.integration_parameters,
        islands: world.world.islands.clone(),
        broad_phase: world.world.broad_phase.clone(),
        narrow_phase: world.world.narrow_phase.clone(),
        bodies: world.world.bodies.clone(),
        colliders: world.world.colliders.clone(),
        impulse_joints: world.world.impulse_joints.clone(),
        multibody_joints: world.world.multibody_joints.clone(),
        ccd_solver: world.world.ccd_solver.clone(),
        substeps: world.substeps,
        worker_count: world.worker_count,
    }
}

fn from_snapshot(snapshot: PhysicsSnapshot) -> TecsPhysicsWorld {
    let mut result = new_world(
        snapshot.gravity.x,
        snapshot.gravity.y,
        snapshot.substeps,
        snapshot.worker_count,
    );
    result.world = PhysicsWorld {
        gravity: snapshot.gravity,
        integration_parameters: snapshot.integration_parameters,
        physics_pipeline: PhysicsPipeline::new(),
        islands: snapshot.islands,
        broad_phase: snapshot.broad_phase,
        narrow_phase: snapshot.narrow_phase,
        bodies: snapshot.bodies,
        colliders: snapshot.colliders,
        impulse_joints: snapshot.impulse_joints,
        multibody_joints: snapshot.multibody_joints,
        ccd_solver: snapshot.ccd_solver,
    };
    result
}

/// Creates an isolated Rapier world.
#[no_mangle]
pub extern "C" fn tecsPhysicsWorldCreate(
    gravity_x: f32,
    gravity_y: f32,
    substeps: u32,
    worker_count: u32,
) -> *mut TecsPhysicsWorld {
    Box::into_raw(Box::new(new_world(
        gravity_x,
        gravity_y,
        substeps,
        worker_count,
    )))
}

/// Returns the process worker default, capped for short solver stages.
#[no_mangle]
pub extern "C" fn tecsPhysicsDefaultWorkerCount() -> u32 {
    std::thread::available_parallelism()
        .map(|count| count.get())
        .unwrap_or(1)
        .clamp(1, 8) as u32
}

/// Releases a world and all of its Rapier state.
///
/// # Safety
///
/// `world` must be null or an owned pointer returned by this module.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsWorldDestroy(world: *mut TecsPhysicsWorld) {
    if !world.is_null() {
        // SAFETY: Ownership crosses this boundary exactly once.
        drop(unsafe { Box::from_raw(world) });
    }
}

/// Advances a world with fixed substeps and records moved bodies and events.
///
/// # Safety
///
/// `world` must point to a live physics world.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsWorldStep(world: *mut TecsPhysicsWorld, dt: f32) -> bool {
    let Some(world) = (unsafe { world.as_mut() }) else {
        set_error("physics world is null");
        return false;
    };

    let before: BTreeMap<u32, (f32, f32, f32)> = world
        .world
        .bodies
        .iter()
        .map(|(handle, body)| {
            let (index, _) = handle.into_raw_parts();
            (
                index,
                (
                    body.translation().x,
                    body.translation().y,
                    body.rotation().angle(),
                ),
            )
        })
        .collect();

    let substep_dt = dt / world.substeps as f32;
    world.world.integration_parameters.dt = substep_dt;
    for _ in 0..world.substeps {
        world.world.step_with_events(&(), &world.event_handler);
    }

    world.moves.clear();
    for (handle, body) in world.world.bodies.iter() {
        let (index, _) = handle.into_raw_parts();
        let position = body.translation();
        let angle = body.rotation().angle();
        let changed = before.get(&index).is_none_or(|old| {
            old.0.to_bits() != position.x.to_bits()
                || old.1.to_bits() != position.y.to_bits()
                || old.2.to_bits() != angle.to_bits()
        });
        if changed {
            world.moves.push(TecsPhysicsMove {
                body: public_body_handle(handle),
                x: position.x,
                y: position.y,
                cosine: angle.cos(),
                sine: angle.sin(),
            });
        }
    }
    world.moves.sort_unstable_by_key(|entry| entry.body.index);
    drain_events(world);
    true
}

/// Creates a body without a collider.
///
/// # Safety
///
/// Both pointers must be live for this call.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsBodyCreate(
    world: *mut TecsPhysicsWorld,
    definition: *const TecsPhysicsBodyDef,
) -> TecsPhysicsHandle {
    let (Some(world), Some(definition)) =
        (unsafe { world.as_mut() }, unsafe { definition.as_ref() })
    else {
        set_error("physics body creation received a null pointer");
        return TecsPhysicsHandle::default();
    };
    let mut builder = RigidBodyBuilder::new(body_type(definition.kind))
        .translation(Vector::new(definition.x, definition.y))
        .rotation(definition.angle)
        .ccd_enabled(definition.bullet != 0)
        .can_sleep(definition.sleep_enabled != 0)
        .gravity_scale(definition.gravity_scale)
        .linear_damping(definition.linear_damping)
        .angular_damping(definition.angular_damping)
        .user_data(definition.entity as u128);
    if definition.fixed_rotation != 0 {
        builder = builder.lock_rotations();
    }
    let body = builder.build();
    public_body_handle(world.world.insert_body(body))
}

/// Creates a collider attached to `body`.
///
/// # Safety
///
/// All pointers must be live for this call.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsColliderCreate(
    world: *mut TecsPhysicsWorld,
    body: TecsPhysicsHandle,
    definition: *const TecsPhysicsColliderDef,
) -> TecsPhysicsHandle {
    let (Some(world), Some(definition)) =
        (unsafe { world.as_mut() }, unsafe { definition.as_ref() })
    else {
        set_error("physics collider creation received a null pointer");
        return TecsPhysicsHandle::default();
    };
    let parent = body_handle(body);
    if !world.world.bodies.contains(parent) {
        set_error("physics body handle is stale");
        return TecsPhysicsHandle::default();
    }

    let builder = match definition.shape {
        1 => ColliderBuilder::ball(definition.radius),
        2 => ColliderBuilder::capsule_y(definition.length * 0.5, definition.radius),
        _ => ColliderBuilder::cuboid(definition.half_width, definition.half_height),
    }
    .translation(Vector::new(definition.offset_x, definition.offset_y))
    .density(definition.density)
    .friction(definition.friction)
    .restitution(definition.restitution)
    .sensor(definition.sensor != 0)
    .collision_groups(collision_groups(
        definition.category_bits,
        definition.mask_bits,
    ))
    .active_events(ActiveEvents::COLLISION_EVENTS | ActiveEvents::CONTACT_FORCE_EVENTS)
    .contact_force_event_threshold(0.0)
    .user_data(definition.entity as u128);

    public_collider_handle(world.world.insert_collider(builder, Some(parent)))
}

/// Returns whether a body handle belongs to this live world.
///
/// # Safety
///
/// `world` must be null or point to a live world.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsBodyIsValid(
    world: *const TecsPhysicsWorld,
    body: TecsPhysicsHandle,
) -> bool {
    unsafe { world.as_ref() }.is_some_and(|world| world.world.bodies.contains(body_handle(body)))
}

/// Returns whether a collider handle belongs to this live world.
///
/// # Safety
///
/// `world` must be null or point to a live world.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsColliderIsValid(
    world: *const TecsPhysicsWorld,
    collider: TecsPhysicsHandle,
) -> bool {
    unsafe { world.as_ref() }
        .is_some_and(|world| world.world.colliders.contains(collider_handle(collider)))
}

/// Removes a body and every attached collider.
///
/// # Safety
///
/// `world` must point to a live world.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsBodyDestroy(
    world: *mut TecsPhysicsWorld,
    body: TecsPhysicsHandle,
) {
    if let Some(world) = unsafe { world.as_mut() } {
        world.world.remove_body(body_handle(body));
    }
}

/// Removes a collider.
///
/// # Safety
///
/// `world` must point to a live world.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsColliderDestroy(
    world: *mut TecsPhysicsWorld,
    collider: TecsPhysicsHandle,
) {
    if let Some(world) = unsafe { world.as_mut() } {
        world.world.remove_collider(collider_handle(collider));
    }
}

/// Finds and removes the collider whose user data names `entity`.
///
/// # Safety
///
/// `world` must point to a live world.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsRemoveColliderByEntity(
    world: *mut TecsPhysicsWorld,
    body: TecsPhysicsHandle,
    entity: u64,
) {
    let Some(world) = (unsafe { world.as_mut() }) else {
        return;
    };
    let body = body_handle(body);
    let Some(body_ref) = world.world.bodies.get(body) else {
        return;
    };
    let found = body_ref
        .colliders()
        .iter()
        .copied()
        .find(|handle| entity_of_collider(&world.world, *handle) == entity);
    if let Some(handle) = found {
        world.world.remove_collider(handle);
    }
}

/// Returns the body owning a collider.
///
/// # Safety
///
/// `world` and `output` must be live.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsColliderBody(
    world: *const TecsPhysicsWorld,
    collider: TecsPhysicsHandle,
) -> TecsPhysicsHandle {
    let Some(world) = (unsafe { world.as_ref() }) else {
        return TecsPhysicsHandle::default();
    };
    let Some(parent) = world
        .world
        .colliders
        .get(collider_handle(collider))
        .and_then(Collider::parent)
    else {
        return TecsPhysicsHandle::default();
    };
    public_body_handle(parent)
}

/// Returns how many bodies this world owns.
///
/// # Safety
///
/// `world` must be null or point to a live world.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsBodyCount(world: *const TecsPhysicsWorld) -> usize {
    unsafe { world.as_ref() }
        .map(|world| world.world.bodies.len())
        .unwrap_or(0)
}

/// Finds a body by the entity stored in its user data.
///
/// # Safety
///
/// `world` and `output` must be live.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsBodyByEntity(
    world: *const TecsPhysicsWorld,
    entity: u64,
    output: *mut TecsPhysicsHandle,
) -> bool {
    let (Some(world), Some(output)) = (unsafe { world.as_ref() }, unsafe { output.as_mut() })
    else {
        return false;
    };
    let Some((handle, _)) = world
        .world
        .bodies
        .iter()
        .find(|(_, body)| body.user_data as u64 == entity)
    else {
        return false;
    };
    *output = public_body_handle(handle);
    true
}

/// Finds a collider by the entity stored in its user data.
///
/// # Safety
///
/// `world` and `output` must be live.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsColliderByEntity(
    world: *const TecsPhysicsWorld,
    entity: u64,
    output: *mut TecsPhysicsHandle,
) -> bool {
    let (Some(world), Some(output)) = (unsafe { world.as_ref() }, unsafe { output.as_mut() })
    else {
        return false;
    };
    let Some((handle, _)) = world
        .world
        .colliders
        .iter()
        .find(|(_, collider)| collider.user_data as u64 == entity)
    else {
        return false;
    };
    *output = public_collider_handle(handle);
    true
}

/// Borrows the last step's moved-body buffer.
///
/// # Safety
///
/// `world` must be live and `count` may be null.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsMoves(
    world: *const TecsPhysicsWorld,
    count: *mut usize,
) -> *const TecsPhysicsMove {
    let Some(world) = (unsafe { world.as_ref() }) else {
        return ptr::null();
    };
    if let Some(count) = unsafe { count.as_mut() } {
        *count = world.moves.len();
    }
    world.moves.as_ptr()
}

/// Reads a body's position and angle.
///
/// # Safety
///
/// `world` must be live and output pointers may be null independently.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsBodyPosition(
    world: *const TecsPhysicsWorld,
    body: TecsPhysicsHandle,
    x: *mut f32,
    y: *mut f32,
    angle: *mut f32,
) -> bool {
    let Some(world) = (unsafe { world.as_ref() }) else {
        return false;
    };
    let Some(body) = world.world.bodies.get(body_handle(body)) else {
        return false;
    };
    let position = body.translation();
    if let Some(x) = unsafe { x.as_mut() } {
        *x = position.x;
    }
    if let Some(y) = unsafe { y.as_mut() } {
        *y = position.y;
    }
    if let Some(angle) = unsafe { angle.as_mut() } {
        *angle = body.rotation().angle();
    }
    true
}

/// Reads a body's linear velocity.
///
/// # Safety
///
/// `world` must be live and the output pointers may be null independently.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsBodyVelocity(
    world: *const TecsPhysicsWorld,
    body: TecsPhysicsHandle,
    x: *mut f32,
    y: *mut f32,
    angular: *mut f32,
) -> bool {
    let Some(world) = (unsafe { world.as_ref() }) else {
        return false;
    };
    let Some(body) = world.world.bodies.get(body_handle(body)) else {
        return false;
    };
    if let Some(x) = unsafe { x.as_mut() } {
        *x = body.linvel().x;
    }
    if let Some(y) = unsafe { y.as_mut() } {
        *y = body.linvel().y;
    }
    if let Some(angular) = unsafe { angular.as_mut() } {
        *angular = body.angvel();
    }
    true
}

macro_rules! body_mutation {
    ($name:ident, ($($argument:ident: $type:ty),*), $body:ident, $action:block) => {
        #[no_mangle]
        pub unsafe extern "C" fn $name(
            world: *mut TecsPhysicsWorld,
            handle: TecsPhysicsHandle,
            $($argument: $type),*
        ) -> bool {
            let Some(world) = (unsafe { world.as_mut() }) else {
                return false;
            };
            let Some($body) = world.world.bodies.get_mut(body_handle(handle)) else {
                return false;
            };
            $action
            true
        }
    };
}

body_mutation!(tecsPhysicsBodySetVelocity, (x: f32, y: f32), body, {
    body.set_linvel(Vector::new(x, y), true);
});
body_mutation!(tecsPhysicsBodySetAngularVelocity, (omega: f32), body, {
    body.set_angvel(omega, true);
});
body_mutation!(tecsPhysicsBodyApplyImpulse, (x: f32, y: f32), body, {
    body.apply_impulse(Vector::new(x, y), true);
});
body_mutation!(
    tecsPhysicsBodyApplyImpulseAt,
    (x: f32, y: f32, point_x: f32, point_y: f32),
    body,
    {
        body.apply_impulse_at_point(Vector::new(x, y), Vector::new(point_x, point_y), true);
    }
);
body_mutation!(tecsPhysicsBodyAddForce, (x: f32, y: f32), body, {
    body.add_force(Vector::new(x, y), true);
});
body_mutation!(
    tecsPhysicsBodyAddForceAt,
    (x: f32, y: f32, point_x: f32, point_y: f32),
    body,
    {
        body.add_force_at_point(Vector::new(x, y), Vector::new(point_x, point_y), true);
    }
);
body_mutation!(tecsPhysicsBodyAddTorque, (torque: f32), body, {
    body.add_torque(torque, true);
});
body_mutation!(tecsPhysicsBodySetAwake, (awake: bool), body, {
    if awake {
        body.wake_up(true);
    } else {
        body.sleep();
    }
});
body_mutation!(tecsPhysicsBodySetEnabled, (enabled: bool), body, {
    body.set_enabled(enabled);
});
body_mutation!(tecsPhysicsBodySetType, (kind: u8), body, {
    body.set_body_type(body_type(kind), true);
});
body_mutation!(
    tecsPhysicsBodySetProperties,
    (
        kind: u8,
        gravity_scale: f32,
        linear_damping: f32,
        angular_damping: f32,
        fixed_rotation: bool,
        bullet: bool
    ),
    body,
    {
        body.set_body_type(body_type(kind), true);
        body.set_gravity_scale(gravity_scale, true);
        body.set_linear_damping(linear_damping);
        body.set_angular_damping(angular_damping);
        body.lock_rotations(fixed_rotation, true);
        body.enable_ccd(bullet);
    }
);

/// Applies every mutable property from a body declaration.
///
/// Position and user data are deliberately left alone: declaration edits
/// must not teleport a body or change its owning entity.
///
/// # Safety
///
/// `world` and `definition` must be live.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsBodyApplyDefinition(
    world: *mut TecsPhysicsWorld,
    handle: TecsPhysicsHandle,
    definition: *const TecsPhysicsBodyDef,
) {
    let (Some(world), Some(definition)) =
        (unsafe { world.as_mut() }, unsafe { definition.as_ref() })
    else {
        return;
    };
    let Some(body) = world.world.bodies.get_mut(body_handle(handle)) else {
        return;
    };
    body.set_body_type(body_type(definition.kind), true);
    body.set_gravity_scale(definition.gravity_scale, true);
    body.set_linear_damping(definition.linear_damping);
    body.set_angular_damping(definition.angular_damping);
    body.lock_rotations(definition.fixed_rotation != 0, true);
    body.enable_ccd(definition.bullet != 0);
    let activation = body.activation_mut();
    if definition.sleep_enabled != 0 {
        activation.normalized_linear_threshold =
            RigidBodyActivation::default_normalized_linear_threshold();
        activation.angular_threshold = RigidBodyActivation::default_angular_threshold();
    } else {
        activation.normalized_linear_threshold = -1.0;
        activation.angular_threshold = -1.0;
        activation.sleeping = false;
    }
}
body_mutation!(
    tecsPhysicsBodySetTransform,
    (x: f32, y: f32, angle: f32),
    body,
    {
        body.set_position(Pose::new(Vector::new(x, y), angle), true);
    }
);

/// Reads a body's angular velocity.
///
/// # Safety
///
/// `world` must be live.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsBodyAngularVelocity(
    world: *const TecsPhysicsWorld,
    body: TecsPhysicsHandle,
) -> f32 {
    unsafe { world.as_ref() }
        .and_then(|world| world.world.bodies.get(body_handle(body)))
        .map(RigidBody::angvel)
        .unwrap_or(0.0)
}

/// Returns whether a body is awake.
///
/// # Safety
///
/// `world` must be live.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsBodyIsAwake(
    world: *const TecsPhysicsWorld,
    body: TecsPhysicsHandle,
) -> bool {
    unsafe { world.as_ref() }
        .and_then(|world| world.world.bodies.get(body_handle(body)))
        .is_some_and(|body| !body.is_sleeping())
}

/// Casts a finite segment and returns its nearest hit.
///
/// # Safety
///
/// `world` and `output` must be live.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsRaycast(
    world: *const TecsPhysicsWorld,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    category_bits: u32,
    mask_bits: u32,
    output: *mut TecsPhysicsRayHit,
) -> bool {
    let (Some(world), Some(output)) = (unsafe { world.as_ref() }, unsafe { output.as_mut() })
    else {
        return false;
    };
    let direction = Vector::new(x2 - x1, y2 - y1);
    let ray = Ray::new(Vector::new(x1, y1), direction);
    let filter = QueryFilter::default().groups(collision_groups(category_bits, mask_bits));
    let Some((handle, intersection)) = world.world.cast_ray_and_get_normal(&ray, 1.0, true, filter)
    else {
        return false;
    };
    let point = ray.point_at(intersection.time_of_impact);
    *output = TecsPhysicsRayHit {
        entity: entity_of_collider(&world.world, handle),
        x: point.x,
        y: point.y,
        normal_x: intersection.normal.x,
        normal_y: intersection.normal.y,
        fraction: intersection.time_of_impact,
    };
    true
}

/// Borrows the last step's event buffer.
///
/// # Safety
///
/// `world` must be live and `count` may be null.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsPairEvents(
    world: *const TecsPhysicsWorld,
    count: *mut usize,
) -> *const TecsPhysicsPairEvent {
    let Some(world) = (unsafe { world.as_ref() }) else {
        return ptr::null();
    };
    if let Some(count) = unsafe { count.as_mut() } {
        *count = world.events.len();
    }
    world.events.as_ptr()
}

/// Serializes every deterministic Rapier state container.
///
/// # Safety
///
/// `world` must be live.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsSnapshotCreate(
    world: *const TecsPhysicsWorld,
) -> *mut TecsPhysicsSnapshot {
    let Some(world) = (unsafe { world.as_ref() }) else {
        set_error("physics world is null");
        return ptr::null_mut();
    };
    match bincode::serialize(&snapshot(world)) {
        Ok(bytes) => Box::into_raw(Box::new(TecsPhysicsSnapshot {
            bytes: bytes.into_boxed_slice(),
        })),
        Err(error) => {
            set_error(error);
            ptr::null_mut()
        }
    }
}

/// Restores a complete Rapier snapshot, preserving arena handles.
///
/// # Safety
///
/// `world` must be an owned live world. For nonzero `length`, `bytes` must
/// address at least that many readable bytes.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsSnapshotRestore(
    world: *mut TecsPhysicsWorld,
    bytes: *const u8,
    length: usize,
) -> bool {
    let Some(world) = (unsafe { world.as_mut() }) else {
        set_error("physics world is null");
        return false;
    };
    if bytes.is_null() && length != 0 {
        set_error("physics snapshot bytes are null");
        return false;
    }
    let bytes = if length == 0 {
        &[]
    } else {
        // SAFETY: The caller guarantees this readable range for the call.
        unsafe { slice::from_raw_parts(bytes, length) }
    };
    match bincode::deserialize(bytes) {
        Ok(snapshot) => {
            *world = from_snapshot(snapshot);
            true
        }
        Err(error) => {
            set_error(error);
            false
        }
    }
}

/// Borrows snapshot bytes.
///
/// # Safety
///
/// `snapshot` must be null or a live snapshot pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsSnapshotData(
    snapshot: *const TecsPhysicsSnapshot,
) -> *const u8 {
    unsafe { snapshot.as_ref() }
        .map(|snapshot| snapshot.bytes.as_ptr())
        .unwrap_or(ptr::null())
}

/// Returns a snapshot byte length.
///
/// # Safety
///
/// `snapshot` must be null or a live snapshot pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsSnapshotLength(snapshot: *const TecsPhysicsSnapshot) -> usize {
    unsafe { snapshot.as_ref() }
        .map(|snapshot| snapshot.bytes.len())
        .unwrap_or(0)
}

/// Releases snapshot bytes.
///
/// # Safety
///
/// `snapshot` must be null or an owned live snapshot pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsSnapshotDestroy(snapshot: *mut TecsPhysicsSnapshot) {
    if !snapshot.is_null() {
        // SAFETY: Ownership crosses this boundary exactly once.
        drop(unsafe { Box::from_raw(snapshot) });
    }
}

/// Returns the worker-count contract recorded for this world.
///
/// Rapier's `parallel` feature executes through Rayon's process-wide pool;
/// the value is retained in snapshots so world configuration round-trips.
///
/// # Safety
///
/// `world` must be null or point to a live world.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsWorkerCount(world: *const TecsPhysicsWorld) -> u32 {
    unsafe { world.as_ref() }
        .map(|world| world.worker_count)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_restores_handles_and_motion() {
        let mut world = new_world(0.0, 9.8, 2, 1);
        let definition = TecsPhysicsBodyDef {
            kind: 2,
            fixed_rotation: 0,
            bullet: 0,
            sleep_enabled: 1,
            x: 1.0,
            y: 2.0,
            angle: 0.0,
            gravity_scale: 1.0,
            linear_damping: 0.0,
            angular_damping: 0.0,
            entity: 7,
        };
        let body = world
            .world
            .insert_body(RigidBodyBuilder::dynamic().translation(Vector::new(1.0, 2.0)));
        let handle = public_body_handle(body);
        world.world.bodies[body].set_linvel(Vector::new(3.0, 4.0), true);

        let encoded = bincode::serialize(&snapshot(&world)).unwrap();
        let restored = from_snapshot(bincode::deserialize(&encoded).unwrap());
        let body = restored.world.bodies.get(body_handle(handle)).unwrap();
        assert_eq!(body.translation(), Vector::new(1.0, 2.0));
        assert_eq!(body.linvel(), Vector::new(3.0, 4.0));
        assert_eq!(definition.entity, 7);
    }

    #[test]
    fn generational_handles_reject_removed_bodies() {
        let mut world = new_world(0.0, 0.0, 1, 1);
        let body = world.world.insert_body(RigidBodyBuilder::dynamic());
        let handle = public_body_handle(body);
        world.world.remove_body(body);
        assert!(!world.world.bodies.contains(body_handle(handle)));
    }
}
