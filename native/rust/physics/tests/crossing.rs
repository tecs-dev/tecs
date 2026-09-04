//! Behavior tests driven through the exported C ABI rather than the Rust
//! types behind it, so what the managed binding calls is what runs here.

use std::ptr;

use tecs_physics::*;

/// One owned set of command and result buffers, shaped like the managed
/// caller's.
struct Buffers {
    create_bodies: Vec<TecsPhysicsBodyCreate>,
    create_colliders: Vec<TecsPhysicsColliderCreate>,
    create_joints: Vec<TecsPhysicsJointCreate>,
    update_bodies: Vec<TecsPhysicsBodyUpdate>,
    update_colliders: Vec<TecsPhysicsColliderUpdate>,
    actions: Vec<TecsPhysicsBodyAction>,
    destroy_bodies: Vec<TecsPhysicsHandle>,
    destroy_colliders: Vec<TecsPhysicsHandle>,
    destroy_joints: Vec<TecsPhysicsHandle>,

    created_bodies: Vec<TecsPhysicsCreatedBody>,
    created_colliders: Vec<TecsPhysicsHandle>,
    created_joints: Vec<TecsPhysicsHandle>,
    updated_colliders: Vec<TecsPhysicsHandle>,
    states: Vec<TecsPhysicsBodyState>,
    moved: Vec<u32>,
    events: Vec<TecsPhysicsPairEvent>,
}

impl Buffers {
    fn new() -> Self {
        Self {
            create_bodies: Vec::new(),
            create_colliders: Vec::new(),
            create_joints: Vec::new(),
            update_bodies: Vec::new(),
            update_colliders: Vec::new(),
            actions: Vec::new(),
            destroy_bodies: Vec::new(),
            destroy_colliders: Vec::new(),
            destroy_joints: Vec::new(),
            created_bodies: Vec::new(),
            created_colliders: Vec::new(),
            created_joints: Vec::new(),
            updated_colliders: Vec::new(),
            states: vec![TecsPhysicsBodyState::default(); 64],
            moved: vec![0; 64],
            events: vec![TecsPhysicsPairEvent::default(); 64],
        }
    }

    fn clear_commands(&mut self) {
        self.create_bodies.clear();
        self.create_colliders.clear();
        self.create_joints.clear();
        self.update_bodies.clear();
        self.update_colliders.clear();
        self.actions.clear();
        self.destroy_bodies.clear();
        self.destroy_colliders.clear();
        self.destroy_joints.clear();
    }

    fn batch(&mut self, dt: f32) -> TecsPhysicsBatch {
        self.created_bodies
            .resize(self.create_bodies.len(), TecsPhysicsCreatedBody::default());
        self.created_colliders
            .resize(self.create_colliders.len(), TecsPhysicsHandle::default());
        self.created_joints
            .resize(self.create_joints.len(), TecsPhysicsHandle::default());
        self.updated_colliders
            .resize(self.update_colliders.len(), TecsPhysicsHandle::default());
        TecsPhysicsBatch {
            dt,
            reserved: 0,
            create_bodies: self.create_bodies.as_ptr(),
            create_body_count: self.create_bodies.len() as u64,
            create_colliders: self.create_colliders.as_ptr(),
            create_collider_count: self.create_colliders.len() as u64,
            create_joints: self.create_joints.as_ptr(),
            create_joint_count: self.create_joints.len() as u64,
            update_bodies: self.update_bodies.as_ptr(),
            update_body_count: self.update_bodies.len() as u64,
            update_colliders: self.update_colliders.as_ptr(),
            update_collider_count: self.update_colliders.len() as u64,
            actions: self.actions.as_ptr(),
            action_count: self.actions.len() as u64,
            destroy_bodies: self.destroy_bodies.as_ptr(),
            destroy_body_count: self.destroy_bodies.len() as u64,
            destroy_colliders: self.destroy_colliders.as_ptr(),
            destroy_collider_count: self.destroy_colliders.len() as u64,
            destroy_joints: self.destroy_joints.as_ptr(),
            destroy_joint_count: self.destroy_joints.len() as u64,
            created_bodies: self.created_bodies.as_mut_ptr(),
            created_body_capacity: self.created_bodies.len() as u64,
            created_colliders: self.created_colliders.as_mut_ptr(),
            created_collider_capacity: self.created_colliders.len() as u64,
            created_joints: self.created_joints.as_mut_ptr(),
            created_joint_capacity: self.created_joints.len() as u64,
            updated_colliders: self.updated_colliders.as_mut_ptr(),
            updated_collider_capacity: self.updated_colliders.len() as u64,
            states: self.states.as_mut_ptr(),
            state_capacity: self.states.len() as u64,
            moved: self.moved.as_mut_ptr(),
            moved_capacity: self.moved.len() as u64,
            events: self.events.as_mut_ptr(),
            event_capacity: self.events.len() as u64,
            state_count: 0,
            moved_count: 0,
            event_count: 0,
        }
    }

    fn step(&mut self, world: *mut Simulation, dt: f32) -> TecsPhysicsBatch {
        let mut batch = self.batch(dt);
        let status = unsafe { tecsPhysicsStep(world, &mut batch) };
        assert_eq!(status, STATUS_OK, "step reported {status}");
        self.clear_commands();
        batch
    }
}

fn collider(entity: u64, half_width: f32, half_height: f32) -> TecsPhysicsColliderDef {
    TecsPhysicsColliderDef {
        entity,
        shape: SHAPE_BOX,
        flags: 0,
        half_width,
        half_height,
        radius: 0.0,
        length: 0.0,
        offset_x: 0.0,
        offset_y: 0.0,
        density: 1.0,
        friction: 0.6,
        restitution: 0.0,
        category_bits: 1,
        mask_bits: u32::MAX,
    }
}

fn body(entity: u64, kind: u32, x: f32, y: f32) -> TecsPhysicsBodyCreate {
    TecsPhysicsBodyCreate {
        entity,
        collider: collider(entity, 0.5, 0.5),
        kind,
        flags: BODY_SLEEP_ENABLED,
        gravity_scale: 1.0,
        linear_damping: 0.0,
        angular_damping: 0.0,
        x,
        y,
        angle: 0.0,
        vx: 0.0,
        vy: 0.0,
        omega: 0.0,
    }
}

fn state(
    batch: &TecsPhysicsBatch,
    buffers: &Buffers,
    handle: TecsPhysicsHandle,
) -> TecsPhysicsBodyState {
    assert!(
        (handle.index as u64) < batch.state_count,
        "handle is past the state buffer"
    );
    buffers.states[handle.index as usize]
}

struct World(*mut Simulation);

impl World {
    fn new(gravity_y: f32) -> Self {
        Self(tecsPhysicsWorldCreate(0.0, gravity_y, 4, 1))
    }
}

impl Drop for World {
    fn drop(&mut self) {
        unsafe { tecsPhysicsWorldDestroy(self.0) };
    }
}

#[test]
fn creates_a_body_with_its_primary_collider_and_reports_the_handles() {
    let world = World::new(0.0);
    let mut buffers = Buffers::new();
    buffers.create_bodies.push(body(7, BODY_DYNAMIC, 1.0, 2.0));

    let batch = buffers.step(world.0, 1.0 / 60.0);

    assert_eq!(batch.state_count, 1);
    let created = buffers.created_bodies[0];
    assert_eq!(unsafe { tecsPhysicsBodyCount(world.0) }, 1);
    let observed = state(&batch, &buffers, created.body);
    assert_eq!(observed.flags & STATE_LIVE, STATE_LIVE);
    assert_eq!(observed.generation, created.body.generation);
    assert!((observed.x - 1.0).abs() < 1e-5);
    assert!(!created.collider.is_null());
}

#[test]
fn applies_commands_in_a_fixed_order_regardless_of_arrival() {
    let world = World::new(0.0);
    let mut buffers = Buffers::new();
    buffers.create_bodies.push(body(1, BODY_DYNAMIC, 0.0, 0.0));
    buffers.step(world.0, 0.0);
    let existing = buffers.created_bodies[0].body;

    // Destruction precedes creation inside one batch, so the freed slot is
    // available to the body created by the same call.
    buffers.destroy_bodies.push(existing);
    buffers.create_bodies.push(body(2, BODY_DYNAMIC, 5.0, 0.0));
    let batch = buffers.step(world.0, 0.0);

    assert_eq!(unsafe { tecsPhysicsBodyCount(world.0) }, 1);
    let replacement = buffers.created_bodies[0].body;
    assert_eq!(replacement.index, existing.index);
    assert_ne!(replacement.generation, existing.generation);
    let observed = state(&batch, &buffers, replacement);
    assert!((observed.x - 5.0).abs() < 1e-5);
}

#[test]
fn attaches_a_secondary_collider_to_a_body_created_by_the_same_batch() {
    let world = World::new(0.0);
    let mut buffers = Buffers::new();
    buffers.create_bodies.push(body(1, BODY_DYNAMIC, 0.0, 0.0));
    buffers.create_colliders.push(TecsPhysicsColliderCreate {
        def: collider(2, 0.25, 0.25),
        body: TecsPhysicsHandle::default(),
        body_create_index: 0,
        reserved: 0,
    });

    buffers.step(world.0, 0.0);

    assert!(!buffers.created_colliders[0].is_null());
}

#[test]
fn replaces_a_collider_by_entity_and_reports_the_new_handle() {
    let world = World::new(0.0);
    let mut buffers = Buffers::new();
    buffers.create_bodies.push(body(9, BODY_DYNAMIC, 0.0, 0.0));
    buffers.step(world.0, 0.0);
    let created = buffers.created_bodies[0];

    let mut replacement = collider(9, 2.0, 2.0);
    replacement.friction = 0.1;
    buffers.update_colliders.push(TecsPhysicsColliderUpdate {
        def: replacement,
        collider: TecsPhysicsHandle::default(),
        body: created.body,
        mode: COLLIDER_BY_ENTITY,
        reserved: 0,
    });
    buffers.step(world.0, 0.0);

    let handle = buffers.updated_colliders[0];
    assert!(!handle.is_null());
    assert_ne!(handle, created.collider);
}

#[test]
fn falls_under_gravity_and_lands_on_a_static_body() {
    let world = World::new(9.81);
    let mut buffers = Buffers::new();
    let mut ground = body(1, BODY_STATIC, 0.0, 0.0);
    ground.collider = collider(1, 10.0, 0.5);
    buffers.create_bodies.push(ground);
    buffers.create_bodies.push(body(2, BODY_DYNAMIC, 0.0, -5.0));
    buffers.step(world.0, 0.0);
    let falling = buffers.created_bodies[1].body;

    let mut last = TecsPhysicsBodyState::default();
    for _ in 0..240 {
        let batch = buffers.step(world.0, 1.0 / 60.0);
        last = state(&batch, &buffers, falling);
    }

    assert!(
        last.y > -1.5,
        "expected the body to rest on the ground, got y = {}",
        last.y
    );
    assert!(last.y < 0.0);
}

#[test]
fn reports_contact_and_sensor_transitions_through_the_event_buffer() {
    let world = World::new(0.0);
    let mut buffers = Buffers::new();
    let mut sensor = body(1, BODY_STATIC, 0.0, 0.0);
    sensor.collider = collider(1, 1.0, 1.0);
    sensor.collider.flags = COLLIDER_SENSOR;
    buffers.create_bodies.push(sensor);
    let mut visitor = body(2, BODY_KINEMATIC, -5.0, 0.0);
    visitor.vx = 2.0;
    buffers.create_bodies.push(visitor);
    buffers.step(world.0, 0.0);

    let mut began = false;
    for _ in 0..240 {
        let batch = buffers.step(world.0, 1.0 / 60.0);
        for index in 0..batch.event_count as usize {
            let event = buffers.events[index];
            if event.sensor == 1 && event.started == 1 {
                assert_eq!(event.entity_a, 1, "the sensor is reported first");
                assert_eq!(event.entity_b, 2);
                began = true;
            }
        }
        if began {
            break;
        }
    }

    assert!(began, "the visitor never entered the sensor");
}

#[test]
fn a_revolute_joint_holds_two_bodies_at_one_anchor() {
    let world = World::new(9.81);
    let mut buffers = Buffers::new();
    buffers.create_bodies.push(body(1, BODY_STATIC, 0.0, 0.0));
    buffers.create_bodies.push(body(2, BODY_DYNAMIC, 2.0, 0.0));
    buffers.create_joints.push(TecsPhysicsJointCreate {
        entity: 3,
        body_a: TecsPhysicsHandle::default(),
        body_b: TecsPhysicsHandle::default(),
        body_a_create_index: 0,
        body_b_create_index: 1,
        kind: JOINT_REVOLUTE,
        flags: 0,
        anchor_ax: 0.0,
        anchor_ay: 0.0,
        anchor_bx: -2.0,
        anchor_by: 0.0,
        axis_x: 0.0,
        axis_y: 0.0,
        limit_min: 0.0,
        limit_max: 0.0,
        motor_target_velocity: 0.0,
        motor_max_force: 0.0,
    });
    buffers.step(world.0, 0.0);
    let joint = buffers.created_joints[0];
    let swinging = buffers.created_bodies[1].body;
    assert!(!joint.is_null());
    assert_eq!(unsafe { tecsPhysicsJointCount(world.0) }, 1);

    let mut last = TecsPhysicsBodyState::default();
    for _ in 0..120 {
        let batch = buffers.step(world.0, 1.0 / 60.0);
        last = state(&batch, &buffers, swinging);
    }

    let radius = (last.x * last.x + last.y * last.y).sqrt();
    assert!((radius - 2.0).abs() < 0.2, "the arm stretched to {radius}");
    assert!(last.y > 0.05, "the arm never swung, y = {}", last.y);

    buffers.destroy_joints.push(joint);
    buffers.step(world.0, 1.0 / 60.0);
    assert_eq!(unsafe { tecsPhysicsJointCount(world.0) }, 0);
}

#[test]
fn queued_actions_apply_before_the_step_that_follows_them() {
    let world = World::new(0.0);
    let mut buffers = Buffers::new();
    buffers.create_bodies.push(body(1, BODY_DYNAMIC, 0.0, 0.0));
    buffers.step(world.0, 0.0);
    let handle = buffers.created_bodies[0].body;

    buffers.actions.push(TecsPhysicsBodyAction {
        body: handle,
        action: ACTION_SET_VELOCITY,
        reserved: 0,
        a: 3.0,
        b: 0.0,
        c: 0.0,
        d: 0.0,
    });
    let batch = buffers.step(world.0, 1.0);

    let observed = state(&batch, &buffers, handle);
    assert!((observed.vx - 3.0).abs() < 1e-5);
    assert!(
        (observed.x - 3.0).abs() < 0.01,
        "the body moved to {}",
        observed.x
    );
    assert_eq!(observed.flags & STATE_MOVED, STATE_MOVED);
    assert_eq!(batch.moved_count, 1);
    assert_eq!(buffers.moved[0], handle.index);
}

#[test]
fn a_resting_body_reports_no_move() {
    let world = World::new(0.0);
    let mut buffers = Buffers::new();
    buffers.create_bodies.push(body(1, BODY_STATIC, 0.0, 0.0));
    buffers.step(world.0, 0.0);

    let batch = buffers.step(world.0, 1.0 / 60.0);

    assert_eq!(batch.moved_count, 0);
}

#[test]
fn a_ray_finds_the_nearest_collider() {
    let world = World::new(0.0);
    let mut buffers = Buffers::new();
    let mut near = body(1, BODY_STATIC, 2.0, 0.0);
    near.collider = collider(1, 0.5, 5.0);
    let mut far = body(2, BODY_STATIC, 6.0, 0.0);
    far.collider = collider(2, 0.5, 5.0);
    buffers.create_bodies.push(near);
    buffers.create_bodies.push(far);
    buffers.step(world.0, 0.0);

    let mut hit = TecsPhysicsRayHit::default();
    let found =
        unsafe { tecsPhysicsRaycast(world.0, -2.0, 0.0, 10.0, 0.0, u32::MAX, u32::MAX, &mut hit) };

    assert_eq!(found, 1);
    assert_eq!(hit.entity, 1);
    assert!((hit.x - 1.5).abs() < 1e-3, "the ray stopped at {}", hit.x);
    assert!(hit.fraction > 0.0 && hit.fraction < 1.0);
}

#[test]
fn a_filtered_ray_skips_a_shape_neither_mask_admits() {
    let world = World::new(0.0);
    let mut buffers = Buffers::new();
    let mut blocker = body(1, BODY_STATIC, 2.0, 0.0);
    blocker.collider = collider(1, 0.5, 5.0);
    blocker.collider.category_bits = 2;
    blocker.collider.mask_bits = 2;
    buffers.create_bodies.push(blocker);
    buffers.step(world.0, 0.0);

    let mut hit = TecsPhysicsRayHit::default();
    let found = unsafe { tecsPhysicsRaycast(world.0, -2.0, 0.0, 10.0, 0.0, 1, 1, &mut hit) };

    assert_eq!(found, 0);
}

#[test]
fn resolves_every_requested_entity_in_one_call() {
    let world = World::new(0.0);
    let mut buffers = Buffers::new();
    buffers.create_bodies.push(body(11, BODY_DYNAMIC, 0.0, 0.0));
    buffers.create_bodies.push(body(22, BODY_DYNAMIC, 1.0, 0.0));
    buffers.step(world.0, 0.0);
    let expected = buffers.created_bodies.clone();

    let entities = [22u64, 11, 33];
    let mut bodies = vec![TecsPhysicsHandle::default(); 3];
    let mut colliders = vec![TecsPhysicsHandle::default(); 3];
    let status = unsafe {
        tecsPhysicsResolveEntities(
            world.0,
            entities.as_ptr(),
            entities.len() as u64,
            bodies.as_mut_ptr(),
            colliders.as_mut_ptr(),
        )
    };

    assert_eq!(status, STATUS_OK);
    assert_eq!(bodies[0], expected[1].body);
    assert_eq!(bodies[1], expected[0].body);
    assert!(bodies[2].is_null());
    assert_eq!(colliders[0], expected[1].collider);
}

#[test]
fn a_short_result_buffer_truncates_and_drains_without_stepping_again() {
    let world = World::new(0.0);
    let mut buffers = Buffers::new();
    for entity in 1..=4u64 {
        let mut created = body(entity, BODY_DYNAMIC, entity as f32, 0.0);
        created.vx = 1.0;
        buffers.create_bodies.push(created);
    }
    buffers.step(world.0, 0.0);

    buffers.states.truncate(2);
    let mut batch = buffers.batch(1.0 / 60.0);
    let status = unsafe { tecsPhysicsStep(world.0, &mut batch) };
    assert_eq!(status, STATUS_TRUNCATED);
    assert_eq!(batch.state_count, 4);

    buffers.states = vec![TecsPhysicsBodyState::default(); batch.state_count as usize];
    let mut wider = buffers.batch(0.0);
    let status = unsafe { tecsPhysicsDrain(world.0, &mut wider) };

    assert_eq!(status, STATUS_OK);
    assert_eq!(wider.state_count, 4);
    assert_eq!(unsafe { tecsPhysicsBodyCount(world.0) }, 4);
    assert!(buffers
        .states
        .iter()
        .all(|slot| slot.flags & STATE_LIVE != 0));
}

#[test]
fn a_null_command_array_with_a_nonzero_count_is_refused() {
    let world = World::new(0.0);
    let mut buffers = Buffers::new();
    let mut batch = buffers.batch(0.0);
    batch.create_bodies = ptr::null();
    batch.create_body_count = 1;

    let status = unsafe { tecsPhysicsStep(world.0, &mut batch) };

    assert_eq!(status, STATUS_ERROR);
    assert_eq!(unsafe { tecsPhysicsBodyCount(world.0) }, 0);
}

/// Runs one scenario and returns its final poses, keyed by arena index.
fn scenario(seed: f32) -> Vec<(f32, f32, f32)> {
    let world = World::new(9.81);
    let mut buffers = Buffers::new();
    let mut ground = body(1, BODY_STATIC, 0.0, 0.0);
    ground.collider = collider(1, 20.0, 0.5);
    buffers.create_bodies.push(ground);
    for index in 0..12u64 {
        let mut falling = body(
            index + 2,
            BODY_DYNAMIC,
            (index as f32) * 0.9 - 5.0 + seed,
            -3.0 - (index as f32) * 1.3,
        );
        falling.collider.restitution = 0.3;
        buffers.create_bodies.push(falling);
    }
    buffers.step(world.0, 0.0);
    let handles: Vec<TecsPhysicsHandle> = buffers
        .created_bodies
        .iter()
        .map(|created| created.body)
        .collect();

    for frame in 0..300 {
        if frame == 60 {
            buffers.actions.push(TecsPhysicsBodyAction {
                body: handles[3],
                action: ACTION_IMPULSE,
                reserved: 0,
                a: 4.0,
                b: -2.0,
                c: 0.0,
                d: 0.0,
            });
        }
        buffers.step(world.0, 1.0 / 60.0);
    }

    handles
        .iter()
        .map(|handle| {
            let slot = buffers.states[handle.index as usize];
            (slot.x, slot.y, slot.cosine)
        })
        .collect()
}

#[test]
fn the_same_scenario_produces_bit_identical_results() {
    let first = scenario(0.0);
    let second = scenario(0.0);

    assert_eq!(first.len(), 13);
    for (index, (left, right)) in first.iter().zip(second.iter()).enumerate() {
        assert_eq!(
            left.0.to_bits(),
            right.0.to_bits(),
            "body {index} x diverged"
        );
        assert_eq!(
            left.1.to_bits(),
            right.1.to_bits(),
            "body {index} y diverged"
        );
        assert_eq!(
            left.2.to_bits(),
            right.2.to_bits(),
            "body {index} angle diverged"
        );
    }
    assert_ne!(
        first,
        scenario(0.5),
        "a changed scenario must change its result"
    );
}

#[test]
fn a_snapshot_round_trip_preserves_handles_poses_and_velocities() {
    let world = World::new(9.81);
    let mut buffers = Buffers::new();
    buffers.create_bodies.push(body(1, BODY_STATIC, 0.0, 0.0));
    buffers.create_bodies.push(body(2, BODY_DYNAMIC, 0.0, -4.0));
    buffers.step(world.0, 0.0);
    let handles: Vec<TecsPhysicsHandle> = buffers
        .created_bodies
        .iter()
        .map(|created| created.body)
        .collect();
    for _ in 0..30 {
        buffers.step(world.0, 1.0 / 60.0);
    }
    let saved = buffers.states[handles[1].index as usize];

    let length = unsafe { tecsPhysicsSnapshotBegin(world.0) };
    assert!(length > 0);
    let mut bytes = vec![0u8; length as usize];
    let written =
        unsafe { tecsPhysicsSnapshotRead(world.0, bytes.as_mut_ptr(), bytes.len() as u64) };
    assert_eq!(written, length);

    let restored = World::new(0.0);
    let status =
        unsafe { tecsPhysicsSnapshotRestore(restored.0, bytes.as_ptr(), bytes.len() as u64) };
    assert_eq!(status, STATUS_OK);
    assert_eq!(unsafe { tecsPhysicsBodyCount(restored.0) }, 2);

    let mut after = Buffers::new();
    let batch = after.step(restored.0, 0.0);
    assert_eq!(batch.state_count, 2);
    let observed = after.states[handles[1].index as usize];
    assert_eq!(observed.generation, handles[1].generation);
    assert_eq!(observed.x.to_bits(), saved.x.to_bits());
    assert_eq!(observed.y.to_bits(), saved.y.to_bits());
    assert_eq!(observed.vy.to_bits(), saved.vy.to_bits());
}

#[test]
fn a_restored_world_continues_the_same_trajectory() {
    let source = World::new(9.81);
    let mut buffers = Buffers::new();
    buffers.create_bodies.push(body(1, BODY_DYNAMIC, 0.0, 0.0));
    buffers.step(source.0, 0.0);
    let handle = buffers.created_bodies[0].body;
    for _ in 0..20 {
        buffers.step(source.0, 1.0 / 60.0);
    }

    let length = unsafe { tecsPhysicsSnapshotBegin(source.0) };
    let mut bytes = vec![0u8; length as usize];
    unsafe { tecsPhysicsSnapshotRead(source.0, bytes.as_mut_ptr(), bytes.len() as u64) };
    let restored = World::new(0.0);
    unsafe { tecsPhysicsSnapshotRestore(restored.0, bytes.as_ptr(), bytes.len() as u64) };

    let mut continued = Buffers::new();
    let mut expected = TecsPhysicsBodyState::default();
    for _ in 0..20 {
        let batch = buffers.step(source.0, 1.0 / 60.0);
        expected = state(&batch, &buffers, handle);
    }
    let mut observed = TecsPhysicsBodyState::default();
    for _ in 0..20 {
        let batch = continued.step(restored.0, 1.0 / 60.0);
        observed = state(&batch, &continued, handle);
    }

    assert_eq!(observed.y.to_bits(), expected.y.to_bits());
    assert_eq!(observed.vy.to_bits(), expected.vy.to_bits());
}

#[test]
fn a_disabled_body_stops_moving_and_resumes_when_enabled() {
    let world = World::new(9.81);
    let mut buffers = Buffers::new();
    buffers.create_bodies.push(body(1, BODY_DYNAMIC, 0.0, 0.0));
    buffers.step(world.0, 0.0);
    let handle = buffers.created_bodies[0].body;

    buffers.actions.push(TecsPhysicsBodyAction {
        body: handle,
        action: ACTION_SET_ENABLED,
        reserved: 0,
        a: 0.0,
        b: 0.0,
        c: 0.0,
        d: 0.0,
    });
    let disabled = buffers.step(world.0, 1.0 / 60.0);
    let held = state(&disabled, &buffers, handle);
    assert_eq!(held.flags & STATE_ENABLED, 0);
    for _ in 0..30 {
        buffers.step(world.0, 1.0 / 60.0);
    }
    let still = buffers.states[handle.index as usize];
    assert_eq!(still.y.to_bits(), held.y.to_bits());

    buffers.actions.push(TecsPhysicsBodyAction {
        body: handle,
        action: ACTION_SET_ENABLED,
        reserved: 0,
        a: 1.0,
        b: 0.0,
        c: 0.0,
        d: 0.0,
    });
    for _ in 0..30 {
        buffers.step(world.0, 1.0 / 60.0);
    }

    let moving = buffers.states[handle.index as usize];
    assert_eq!(moving.flags & STATE_ENABLED, STATE_ENABLED);
    assert!(moving.y > held.y, "the body did not resume falling");
}

#[test]
fn a_redeclaration_changes_a_body_without_moving_it() {
    let world = World::new(9.81);
    let mut buffers = Buffers::new();
    buffers.create_bodies.push(body(1, BODY_DYNAMIC, 3.0, -1.0));
    buffers.step(world.0, 0.0);
    let handle = buffers.created_bodies[0].body;

    buffers.update_bodies.push(TecsPhysicsBodyUpdate {
        body: handle,
        kind: BODY_STATIC,
        flags: BODY_FIXED_ROTATION,
        gravity_scale: 1.0,
        linear_damping: 0.0,
        angular_damping: 0.0,
    });
    let batch = buffers.step(world.0, 1.0 / 60.0);
    let observed = state(&batch, &buffers, handle);

    assert!((observed.x - 3.0).abs() < 1e-5);
    assert!(
        (observed.y + 1.0).abs() < 1e-5,
        "a redeclaration moved the body"
    );
    for _ in 0..30 {
        buffers.step(world.0, 1.0 / 60.0);
    }
    assert_eq!(
        buffers.states[handle.index as usize].y.to_bits(),
        observed.y.to_bits()
    );
}

#[test]
fn destroying_a_body_frees_its_state_slot_and_its_colliders() {
    let world = World::new(0.0);
    let mut buffers = Buffers::new();
    buffers.create_bodies.push(body(1, BODY_DYNAMIC, 0.0, 0.0));
    buffers.create_bodies.push(body(2, BODY_DYNAMIC, 1.0, 0.0));
    buffers.step(world.0, 0.0);
    let doomed = buffers.created_bodies[0].body;

    buffers.destroy_bodies.push(doomed);
    let batch = buffers.step(world.0, 0.0);

    assert_eq!(unsafe { tecsPhysicsBodyCount(world.0) }, 1);
    assert!((doomed.index as u64) < batch.state_count);
    assert_eq!(buffers.states[doomed.index as usize].flags & STATE_LIVE, 0);
}

#[test]
fn a_stale_handle_in_any_command_is_ignored() {
    let world = World::new(0.0);
    let mut buffers = Buffers::new();
    buffers.create_bodies.push(body(1, BODY_DYNAMIC, 0.0, 0.0));
    buffers.step(world.0, 0.0);
    let handle = buffers.created_bodies[0].body;
    buffers.destroy_bodies.push(handle);
    buffers.step(world.0, 0.0);

    buffers.destroy_bodies.push(handle);
    buffers.actions.push(TecsPhysicsBodyAction {
        body: handle,
        action: ACTION_IMPULSE,
        reserved: 0,
        a: 1.0,
        b: 0.0,
        c: 0.0,
        d: 0.0,
    });
    buffers.update_bodies.push(TecsPhysicsBodyUpdate {
        body: handle,
        kind: BODY_STATIC,
        flags: 0,
        gravity_scale: 1.0,
        linear_damping: 0.0,
        angular_damping: 0.0,
    });
    let mut batch = buffers.batch(1.0 / 60.0);
    let status = unsafe { tecsPhysicsStep(world.0, &mut batch) };

    assert_eq!(status, STATUS_OK);
    assert_eq!(unsafe { tecsPhysicsBodyCount(world.0) }, 0);
}
