//! One Rapier world and the batch application that drives it.
//!
//! Nothing in this module calls back into the managed runtime. Commands
//! arrive as slices the caller filled and results leave through slices the
//! caller sized, so a compiled managed trace is never re-entered and no
//! foreign thread ever enters the managed VM.

use std::collections::HashMap;
use std::sync::mpsc::{self, Receiver};
use std::sync::OnceLock;

use rapier2d::prelude::*;
use serde::{Deserialize, Serialize};

use crate::abi::*;

static PHYSICS_WORKERS: OnceLock<u32> = OnceLock::new();

/// Installs the process-wide solver pool once and reports its final size.
///
/// Rapier reaches Rayon's global pool, so the first world decides the width
/// for the process and later worlds observe that decision rather than
/// changing it.
pub fn configure_workers(requested: u32) -> u32 {
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

/// The default solver width when a world does not name one.
pub fn default_worker_count() -> u32 {
    std::thread::available_parallelism()
        .map(|count| count.get())
        .unwrap_or(1)
        .clamp(1, 8) as u32
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

/// One isolated simulation and the results of its last step.
pub struct Simulation {
    world: PhysicsWorld,
    substeps: u32,
    worker_count: u32,
    collisions: Receiver<CollisionEvent>,
    handler: ChannelEventCollector,
    states: Vec<TecsPhysicsBodyState>,
    moved: Vec<u32>,
    events: Vec<TecsPhysicsPairEvent>,
    created_bodies: Vec<TecsPhysicsCreatedBody>,
    created_colliders: Vec<TecsPhysicsHandle>,
    created_joints: Vec<TecsPhysicsHandle>,
    updated_colliders: Vec<TecsPhysicsHandle>,
    snapshot: Vec<u8>,
}

fn channels() -> (Receiver<CollisionEvent>, ChannelEventCollector) {
    let (collisions, collision_receiver) = mpsc::channel();
    let (forces, _force_receiver) = mpsc::channel();
    (
        collision_receiver,
        ChannelEventCollector::new(collisions, forces),
    )
}

fn body_type(kind: u32) -> RigidBodyType {
    match kind {
        BODY_KINEMATIC => RigidBodyType::KinematicVelocityBased,
        BODY_DYNAMIC => RigidBodyType::Dynamic,
        _ => RigidBodyType::Fixed,
    }
}

fn groups(category_bits: u32, mask_bits: u32) -> InteractionGroups {
    InteractionGroups::new(
        Group::from_bits_truncate(category_bits),
        Group::from_bits_truncate(mask_bits),
        InteractionTestMode::And,
    )
}

fn body_handle(handle: TecsPhysicsHandle) -> RigidBodyHandle {
    RigidBodyHandle::from_raw_parts(handle.index, handle.generation)
}

fn collider_handle(handle: TecsPhysicsHandle) -> ColliderHandle {
    ColliderHandle::from_raw_parts(handle.index, handle.generation)
}

fn joint_handle(handle: TecsPhysicsHandle) -> ImpulseJointHandle {
    ImpulseJointHandle::from_raw_parts(handle.index, handle.generation)
}

fn public_body(handle: RigidBodyHandle) -> TecsPhysicsHandle {
    let (index, generation) = handle.into_raw_parts();
    TecsPhysicsHandle { index, generation }
}

fn public_collider(handle: ColliderHandle) -> TecsPhysicsHandle {
    let (index, generation) = handle.into_raw_parts();
    TecsPhysicsHandle { index, generation }
}

fn public_joint(handle: ImpulseJointHandle) -> TecsPhysicsHandle {
    let (index, generation) = handle.into_raw_parts();
    TecsPhysicsHandle { index, generation }
}

fn collider_builder(def: &TecsPhysicsColliderDef) -> ColliderBuilder {
    let shape = match def.shape {
        SHAPE_SEGMENT => ColliderBuilder::segment(
            Vector::new(-def.half_width, -def.half_height),
            Vector::new(def.half_width, def.half_height),
        ),
        SHAPE_CIRCLE => ColliderBuilder::ball(def.radius),
        SHAPE_CAPSULE => ColliderBuilder::capsule_y(def.length * 0.5, def.radius),
        _ => ColliderBuilder::cuboid(def.half_width, def.half_height),
    };
    let mut builder = shape
        .translation(Vector::new(def.offset_x, def.offset_y))
        .density(def.density)
        .friction(def.friction)
        .restitution(def.restitution)
        .sensor(def.flags & COLLIDER_SENSOR != 0)
        .collision_groups(groups(def.category_bits, def.mask_bits))
        .active_events(ActiveEvents::COLLISION_EVENTS)
        .user_data(def.entity as u128);
    if def.flags & COLLIDER_SENSOR != 0 {
        // A trigger zone is usually a shape on a fixed body and its visitor is
        // often kinematic, a pairing Rapier's default collision types exclude.
        // A sensor that reports nothing in that arrangement is the more
        // surprising answer, so a sensor observes every body pairing.
        builder = builder.active_collision_types(ActiveCollisionTypes::all());
    }

    builder
}

fn apply_declaration(
    body: &mut RigidBody,
    kind: u32,
    flags: u32,
    gravity_scale: f32,
    linear_damping: f32,
    angular_damping: f32,
) {
    body.set_body_type(body_type(kind), true);
    body.set_gravity_scale(gravity_scale, true);
    body.set_linear_damping(linear_damping);
    body.set_angular_damping(angular_damping);
    body.lock_rotations(flags & BODY_FIXED_ROTATION != 0, true);
    body.enable_ccd(flags & BODY_BULLET != 0);
    let activation = body.activation_mut();
    if flags & BODY_SLEEP_ENABLED != 0 {
        activation.normalized_linear_threshold =
            RigidBodyActivation::default_normalized_linear_threshold();
        activation.angular_threshold = RigidBodyActivation::default_angular_threshold();
    } else {
        activation.normalized_linear_threshold = -1.0;
        activation.angular_threshold = -1.0;
        activation.sleeping = false;
    }
}

impl Simulation {
    /// Creates an empty world with a fixed substep count and solver width.
    pub fn new(gravity_x: f32, gravity_y: f32, substeps: u32, worker_count: u32) -> Self {
        let worker_count = configure_workers(worker_count);
        let mut world = PhysicsWorld {
            gravity: Vector::new(gravity_x, gravity_y),
            ..PhysicsWorld::default()
        };
        world.integration_parameters.max_ccd_substeps = 1;
        let (collisions, handler) = channels();
        Self {
            world,
            substeps: substeps.max(1),
            worker_count,
            collisions,
            handler,
            states: Vec::new(),
            moved: Vec::new(),
            events: Vec::new(),
            created_bodies: Vec::new(),
            created_colliders: Vec::new(),
            created_joints: Vec::new(),
            updated_colliders: Vec::new(),
            snapshot: Vec::new(),
        }
    }

    /// Reports the substep count each `step` divides its interval into.
    pub fn substeps(&self) -> u32 {
        self.substeps
    }

    /// Reports the solver width this world was configured with.
    pub fn worker_count(&self) -> u32 {
        self.worker_count
    }

    /// Reports how many bodies the world holds.
    pub fn body_count(&self) -> usize {
        self.world.bodies.len()
    }

    /// Reports how many impulse joints the world holds.
    pub fn joint_count(&self) -> usize {
        self.world.impulse_joints.len()
    }

    fn entity_of(&self, collider: ColliderHandle) -> u64 {
        self.world
            .colliders
            .get(collider)
            .map(|value| value.user_data as u64)
            .unwrap_or(0)
    }

    fn resolve_body(
        &self,
        handle: TecsPhysicsHandle,
        create_index: i32,
    ) -> Option<RigidBodyHandle> {
        if create_index >= 0 {
            return self
                .created_bodies
                .get(create_index as usize)
                .filter(|created| !created.body.is_null())
                .map(|created| body_handle(created.body));
        }
        Some(body_handle(handle))
    }

    fn create_body(&mut self, command: &TecsPhysicsBodyCreate) -> TecsPhysicsCreatedBody {
        let mut builder = RigidBodyBuilder::new(body_type(command.kind))
            .translation(Vector::new(command.x, command.y))
            .rotation(command.angle)
            .linvel(Vector::new(command.vx, command.vy))
            .angvel(command.omega)
            .ccd_enabled(command.flags & BODY_BULLET != 0)
            .can_sleep(command.flags & BODY_SLEEP_ENABLED != 0)
            .gravity_scale(command.gravity_scale)
            .linear_damping(command.linear_damping)
            .angular_damping(command.angular_damping)
            .user_data(command.entity as u128);
        if command.flags & BODY_FIXED_ROTATION != 0 {
            builder = builder.lock_rotations();
        }
        let body = self.world.insert_body(builder.build());
        let collider = self
            .world
            .insert_collider(collider_builder(&command.collider), Some(body));
        TecsPhysicsCreatedBody {
            body: public_body(body),
            collider: public_collider(collider),
        }
    }

    fn create_joint(&mut self, command: &TecsPhysicsJointCreate) -> TecsPhysicsHandle {
        let (Some(first), Some(second)) = (
            self.resolve_body(command.body_a, command.body_a_create_index),
            self.resolve_body(command.body_b, command.body_b_create_index),
        ) else {
            return TecsPhysicsHandle::NULL;
        };
        if !self.world.bodies.contains(first) || !self.world.bodies.contains(second) {
            return TecsPhysicsHandle::NULL;
        }
        let anchor_a = Vector::new(command.anchor_ax, command.anchor_ay);
        let anchor_b = Vector::new(command.anchor_bx, command.anchor_by);
        let limits = command.flags & JOINT_LIMITS != 0;
        let motor = command.flags & JOINT_MOTOR != 0;
        let joint: GenericJoint = match command.kind {
            JOINT_REVOLUTE => {
                let mut builder = RevoluteJointBuilder::new()
                    .local_anchor1(anchor_a)
                    .local_anchor2(anchor_b)
                    .contacts_enabled(command.flags & JOINT_CONTACTS != 0);
                if limits {
                    builder = builder.limits([command.limit_min, command.limit_max]);
                }
                if motor {
                    builder = builder
                        .motor_velocity(command.motor_target_velocity, 0.0)
                        .motor_max_force(command.motor_max_force);
                }
                builder.into()
            }
            JOINT_PRISMATIC => {
                let axis = Vector::new(command.axis_x, command.axis_y).normalize();
                let mut builder = PrismaticJointBuilder::new(axis)
                    .local_anchor1(anchor_a)
                    .local_anchor2(anchor_b)
                    .contacts_enabled(command.flags & JOINT_CONTACTS != 0);
                if limits {
                    builder = builder.limits([command.limit_min, command.limit_max]);
                }
                if motor {
                    builder = builder
                        .motor_velocity(command.motor_target_velocity, 0.0)
                        .motor_max_force(command.motor_max_force);
                }
                builder.into()
            }
            _ => FixedJointBuilder::new()
                .local_anchor1(anchor_a)
                .local_anchor2(anchor_b)
                .contacts_enabled(command.flags & JOINT_CONTACTS != 0)
                .into(),
        };
        // The joint carries its entity the way a body and a collider do, so a
        // snapshot load resolves all three from the restored state alone.
        let mut joint = joint;
        joint.user_data = command.entity as u128;
        public_joint(self.world.impulse_joints.insert(first, second, joint, true))
    }

    fn update_collider(&mut self, command: &TecsPhysicsColliderUpdate) -> TecsPhysicsHandle {
        let existing = if command.mode == COLLIDER_BY_ENTITY {
            let parent = body_handle(command.body);
            let Some(body) = self.world.bodies.get(parent) else {
                return TecsPhysicsHandle::NULL;
            };
            body.colliders()
                .iter()
                .copied()
                .find(|handle| self.entity_of(*handle) == command.def.entity)
        } else {
            let handle = collider_handle(command.collider);
            self.world.colliders.contains(handle).then_some(handle)
        };
        let Some(existing) = existing else {
            return TecsPhysicsHandle::NULL;
        };
        let Some(parent) = self
            .world
            .colliders
            .get(existing)
            .and_then(Collider::parent)
        else {
            return TecsPhysicsHandle::NULL;
        };
        self.world.remove_collider(existing);
        public_collider(
            self.world
                .insert_collider(collider_builder(&command.def), Some(parent)),
        )
    }

    fn apply_action(&mut self, command: &TecsPhysicsBodyAction) {
        let Some(body) = self.world.bodies.get_mut(body_handle(command.body)) else {
            return;
        };
        match command.action {
            ACTION_IMPULSE => body.apply_impulse(Vector::new(command.a, command.b), true),
            ACTION_IMPULSE_AT => body.apply_impulse_at_point(
                Vector::new(command.a, command.b),
                Vector::new(command.c, command.d),
                true,
            ),
            ACTION_FORCE => body.add_force(Vector::new(command.a, command.b), true),
            ACTION_FORCE_AT => body.add_force_at_point(
                Vector::new(command.a, command.b),
                Vector::new(command.c, command.d),
                true,
            ),
            ACTION_TORQUE => body.add_torque(command.a, true),
            ACTION_SET_VELOCITY => body.set_linvel(Vector::new(command.a, command.b), true),
            ACTION_SET_ANGULAR_VELOCITY => body.set_angvel(command.a, true),
            ACTION_SET_AWAKE => {
                if command.a != 0.0 {
                    body.wake_up(true);
                } else {
                    body.sleep();
                }
            }
            ACTION_SET_ENABLED => body.set_enabled(command.a != 0.0),
            ACTION_SET_BODY_TYPE => body.set_body_type(body_type(command.a as u32), true),
            ACTION_SET_TRANSFORM => body.set_position(
                Pose::new(Vector::new(command.a, command.b), command.c),
                true,
            ),
            _ => {}
        }
    }

    /// Applies one batch of commands in the documented fixed order.
    ///
    /// Destruction precedes creation so a slot freed by this batch may be
    /// reused within it, and the order never depends on iteration order in
    /// the caller.
    pub fn apply(&mut self, batch: &Batch<'_>) {
        self.created_bodies.clear();
        self.created_colliders.clear();
        self.created_joints.clear();
        self.updated_colliders.clear();

        for handle in batch.destroy_joints {
            self.world
                .impulse_joints
                .remove(joint_handle(*handle), true);
        }
        for handle in batch.destroy_colliders {
            self.world.remove_collider(collider_handle(*handle));
        }
        for handle in batch.destroy_bodies {
            self.world.remove_body(body_handle(*handle));
        }
        for command in batch.create_bodies {
            let created = self.create_body(command);
            self.created_bodies.push(created);
        }
        for command in batch.create_colliders {
            let handle = match self.resolve_body(command.body, command.body_create_index) {
                Some(parent) if self.world.bodies.contains(parent) => public_collider(
                    self.world
                        .insert_collider(collider_builder(&command.def), Some(parent)),
                ),
                _ => TecsPhysicsHandle::NULL,
            };
            self.created_colliders.push(handle);
        }
        for command in batch.create_joints {
            let handle = self.create_joint(command);
            self.created_joints.push(handle);
        }
        for command in batch.update_bodies {
            if let Some(body) = self.world.bodies.get_mut(body_handle(command.body)) {
                apply_declaration(
                    body,
                    command.kind,
                    command.flags,
                    command.gravity_scale,
                    command.linear_damping,
                    command.angular_damping,
                );
            }
        }
        for command in batch.update_colliders {
            let handle = self.update_collider(command);
            self.updated_colliders.push(handle);
        }
        for command in batch.actions {
            self.apply_action(command);
        }
    }

    /// Advances the world by `dt` seconds, divided into its substeps.
    pub fn step(&mut self, dt: f32) {
        self.world.integration_parameters.dt = dt / self.substeps as f32;
        for _ in 0..self.substeps {
            self.world.step_with_events(&(), &self.handler);
        }
    }

    /// Rebuilds the arena-indexed state mirror and the moved-index list.
    pub fn refresh(&mut self) {
        let mut highest: u32 = 0;
        for (handle, _) in self.world.bodies.iter() {
            let (index, _) = handle.into_raw_parts();
            highest = highest.max(index + 1);
        }
        let previous = std::mem::take(&mut self.states);
        self.states = vec![TecsPhysicsBodyState::default(); highest as usize];
        self.moved.clear();
        for (handle, body) in self.world.bodies.iter() {
            let (index, generation) = handle.into_raw_parts();
            let position = body.translation();
            let angle = body.rotation().angle();
            let before = previous.get(index as usize);
            let moved = match before {
                Some(before)
                    if before.flags & STATE_LIVE != 0 && before.generation == generation =>
                {
                    before.x.to_bits() != position.x.to_bits()
                        || before.y.to_bits() != position.y.to_bits()
                        || before.cosine.to_bits() != angle.cos().to_bits()
                        || before.sine.to_bits() != angle.sin().to_bits()
                }
                _ => true,
            };
            let mut flags = STATE_LIVE;
            if !body.is_sleeping() {
                flags |= STATE_AWAKE;
            }
            if body.is_enabled() {
                flags |= STATE_ENABLED;
            }
            if moved {
                flags |= STATE_MOVED;
                self.moved.push(index);
            }
            self.states[index as usize] = TecsPhysicsBodyState {
                generation,
                flags,
                x: position.x,
                y: position.y,
                cosine: angle.cos(),
                sine: angle.sin(),
                vx: body.linvel().x,
                vy: body.linvel().y,
                omega: body.angvel(),
                reserved: 0,
            };
        }
        self.moved.sort_unstable();
    }

    /// Moves the narrow phase's queued transitions into the event buffer.
    pub fn drain_events(&mut self) {
        self.events.clear();
        while let Ok(event) = self.collisions.try_recv() {
            let sensor = event.sensor();
            let first = event.collider1();
            let second = event.collider2();
            let first_entity = self.entity_of(first);
            let second_entity = self.entity_of(second);
            // A sensor transition names the sensor first, whichever side of
            // the pair Rapier reported it on. A contact keeps Rapier's order.
            let swap = sensor
                && !self
                    .world
                    .colliders
                    .get(first)
                    .is_some_and(Collider::is_sensor);
            let (entity_a, entity_b) = if swap {
                (second_entity, first_entity)
            } else {
                (first_entity, second_entity)
            };
            self.events.push(TecsPhysicsPairEvent {
                entity_a,
                entity_b,
                started: u32::from(event.started()),
                sensor: u32::from(sensor),
            });
        }
    }

    /// Reports the last step's results.
    pub fn results(&self) -> Results<'_> {
        Results {
            states: &self.states,
            moved: &self.moved,
            events: &self.events,
            created_bodies: &self.created_bodies,
            created_colliders: &self.created_colliders,
            created_joints: &self.created_joints,
            updated_colliders: &self.updated_colliders,
        }
    }

    /// Casts a finite segment and returns its nearest hit.
    pub fn raycast(
        &self,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        category_bits: u32,
        mask_bits: u32,
    ) -> Option<TecsPhysicsRayHit> {
        let ray = Ray::new(Vector::new(x1, y1), Vector::new(x2 - x1, y2 - y1));
        let filter = QueryFilter::default().groups(groups(category_bits, mask_bits));
        let (handle, intersection) = self
            .world
            .cast_ray_and_get_normal(&ray, 1.0, true, filter)?;
        let point = ray.point_at(intersection.time_of_impact);
        Some(TecsPhysicsRayHit {
            entity: self.entity_of(handle),
            x: point.x,
            y: point.y,
            normal_x: intersection.normal.x,
            normal_y: intersection.normal.y,
            fraction: intersection.time_of_impact,
            reserved: 0,
        })
    }

    /// Answers one body, collider, and joint handle for each entity asked
    /// about.
    ///
    /// A snapshot load asks for every restored entity at once, so this walks
    /// each arena once instead of once per entity.
    pub fn resolve_entities(
        &self,
        entities: &[u64],
        bodies: &mut [TecsPhysicsHandle],
        colliders: &mut [TecsPhysicsHandle],
        joints: &mut [TecsPhysicsHandle],
    ) {
        let mut body_index: HashMap<u64, TecsPhysicsHandle> = HashMap::new();
        for (handle, body) in self.world.bodies.iter() {
            body_index
                .entry(body.user_data as u64)
                .or_insert_with(|| public_body(handle));
        }
        let mut collider_index: HashMap<u64, TecsPhysicsHandle> = HashMap::new();
        for (handle, collider) in self.world.colliders.iter() {
            collider_index
                .entry(collider.user_data as u64)
                .or_insert_with(|| public_collider(handle));
        }
        let mut joint_index: HashMap<u64, TecsPhysicsHandle> = HashMap::new();
        for (handle, joint) in self.world.impulse_joints.iter() {
            joint_index
                .entry(joint.data.user_data as u64)
                .or_insert_with(|| public_joint(handle));
        }
        for (slot, entity) in entities.iter().enumerate() {
            bodies[slot] = body_index
                .get(entity)
                .copied()
                .unwrap_or(TecsPhysicsHandle::NULL);
            colliders[slot] = collider_index
                .get(entity)
                .copied()
                .unwrap_or(TecsPhysicsHandle::NULL);
            joints[slot] = joint_index
                .get(entity)
                .copied()
                .unwrap_or(TecsPhysicsHandle::NULL);
        }
    }

    /// Serializes every deterministic container into the world's own buffer.
    pub fn save(&mut self) -> Result<usize, String> {
        let snapshot = PhysicsSnapshot {
            gravity: self.world.gravity,
            integration_parameters: self.world.integration_parameters,
            islands: self.world.islands.clone(),
            broad_phase: self.world.broad_phase.clone(),
            narrow_phase: self.world.narrow_phase.clone(),
            bodies: self.world.bodies.clone(),
            colliders: self.world.colliders.clone(),
            impulse_joints: self.world.impulse_joints.clone(),
            multibody_joints: self.world.multibody_joints.clone(),
            ccd_solver: self.world.ccd_solver.clone(),
            substeps: self.substeps,
            worker_count: self.worker_count,
        };
        match bincode::serialize(&snapshot) {
            Ok(bytes) => {
                self.snapshot = bytes;
                Ok(self.snapshot.len())
            }
            Err(error) => Err(error.to_string()),
        }
    }

    /// Borrows the bytes produced by the last successful `save`.
    pub fn saved(&self) -> &[u8] {
        &self.snapshot
    }

    /// Replaces every container with a previously saved snapshot.
    ///
    /// Arena indices and generations survive, so handles a save recorded keep
    /// addressing the same bodies after the load.
    pub fn restore(&mut self, bytes: &[u8]) -> Result<(), String> {
        let snapshot: PhysicsSnapshot =
            bincode::deserialize(bytes).map_err(|error| error.to_string())?;
        let (collisions, handler) = channels();
        self.collisions = collisions;
        self.handler = handler;
        self.substeps = snapshot.substeps.max(1);
        self.worker_count = snapshot.worker_count;
        self.world = PhysicsWorld {
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
        self.states.clear();
        self.moved.clear();
        self.events.clear();
        self.refresh();
        Ok(())
    }
}

/// One batch's command slices, already checked against their counts.
pub struct Batch<'a> {
    pub dt: f32,
    pub create_bodies: &'a [TecsPhysicsBodyCreate],
    pub create_colliders: &'a [TecsPhysicsColliderCreate],
    pub create_joints: &'a [TecsPhysicsJointCreate],
    pub update_bodies: &'a [TecsPhysicsBodyUpdate],
    pub update_colliders: &'a [TecsPhysicsColliderUpdate],
    pub actions: &'a [TecsPhysicsBodyAction],
    pub destroy_bodies: &'a [TecsPhysicsHandle],
    pub destroy_colliders: &'a [TecsPhysicsHandle],
    pub destroy_joints: &'a [TecsPhysicsHandle],
}

/// The last step's results, borrowed from the world that produced them.
pub struct Results<'a> {
    pub states: &'a [TecsPhysicsBodyState],
    pub moved: &'a [u32],
    pub events: &'a [TecsPhysicsPairEvent],
    pub created_bodies: &'a [TecsPhysicsCreatedBody],
    pub created_colliders: &'a [TecsPhysicsHandle],
    pub created_joints: &'a [TecsPhysicsHandle],
    pub updated_colliders: &'a [TecsPhysicsHandle],
}
