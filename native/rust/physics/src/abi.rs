//! The plain-old-data layouts of the batched physics crossing.
//!
//! Every type here is `#[repr(C)]` and holds nothing but fixed-width scalars
//! and other `#[repr(C)]` types, so the managed caller can declare the same
//! layouts and index them directly. Field names are Rust's; the ABI is
//! positional, and `layout` in the test module below pins every size and
//! offset so a reordering here fails a test rather than a running game.
//!
//! The managed side owns every buffer. A batch carries read-only command
//! arrays it filled and writable result arrays it sized, and the callee
//! borrows both for exactly the duration of one call.

/// A generational Rapier arena handle.
///
/// Arena index zero at generation zero is a real handle, so absence is
/// spelled `NULL` rather than a zeroed value.
#[repr(C)]
#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
pub struct TecsPhysicsHandle {
    pub index: u32,
    pub generation: u32,
}

impl TecsPhysicsHandle {
    /// The handle a failed creation, update, or lookup reports.
    pub const NULL: Self = Self {
        index: NULL_INDEX,
        generation: u32::MAX,
    };

    /// Reports whether this handle names nothing.
    pub fn is_null(self) -> bool {
        self.index == NULL_INDEX
    }
}

/// The arena index no live body, collider, or joint ever occupies.
pub const NULL_INDEX: u32 = u32::MAX;

/// The geometry, material, and filtering of one collider.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TecsPhysicsColliderDef {
    pub entity: u64,
    pub shape: u32,
    pub flags: u32,
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
}

/// One body creation, with the primary collider it always carries.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TecsPhysicsBodyCreate {
    pub entity: u64,
    pub collider: TecsPhysicsColliderDef,
    pub kind: u32,
    pub flags: u32,
    pub gravity_scale: f32,
    pub linear_damping: f32,
    pub angular_damping: f32,
    pub x: f32,
    pub y: f32,
    pub angle: f32,
    pub vx: f32,
    pub vy: f32,
    pub omega: f32,
}

/// One redeclaration of a live body's simulation properties.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TecsPhysicsBodyUpdate {
    pub body: TecsPhysicsHandle,
    pub kind: u32,
    pub flags: u32,
    pub gravity_scale: f32,
    pub linear_damping: f32,
    pub angular_damping: f32,
}

/// One secondary collider creation on an existing or same-batch body.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TecsPhysicsColliderCreate {
    pub def: TecsPhysicsColliderDef,
    pub body: TecsPhysicsHandle,
    pub body_create_index: i32,
    pub reserved: u32,
}

/// One in-place collider replacement, addressed by handle or by entity.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TecsPhysicsColliderUpdate {
    pub def: TecsPhysicsColliderDef,
    pub collider: TecsPhysicsHandle,
    pub body: TecsPhysicsHandle,
    pub mode: u32,
    pub reserved: u32,
}

/// One joint creation between two existing or same-batch bodies.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TecsPhysicsJointCreate {
    pub entity: u64,
    pub body_a: TecsPhysicsHandle,
    pub body_b: TecsPhysicsHandle,
    pub body_a_create_index: i32,
    pub body_b_create_index: i32,
    pub kind: u32,
    pub flags: u32,
    pub anchor_ax: f32,
    pub anchor_ay: f32,
    pub anchor_bx: f32,
    pub anchor_by: f32,
    pub axis_x: f32,
    pub axis_y: f32,
    pub limit_min: f32,
    pub limit_max: f32,
    pub motor_target_velocity: f32,
    pub motor_max_force: f32,
}

/// One queued mutation of a live body, applied before the step that follows.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct TecsPhysicsBodyAction {
    pub body: TecsPhysicsHandle,
    pub action: u32,
    pub reserved: u32,
    pub a: f32,
    pub b: f32,
    pub c: f32,
    pub d: f32,
}

/// One body's post-step state, indexed by its arena index.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug, PartialEq)]
pub struct TecsPhysicsBodyState {
    pub generation: u32,
    pub flags: u32,
    pub x: f32,
    pub y: f32,
    pub cosine: f32,
    pub sine: f32,
    pub vx: f32,
    pub vy: f32,
    pub omega: f32,
    pub reserved: u32,
}

/// The body and primary collider assigned to one creation command.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct TecsPhysicsCreatedBody {
    pub body: TecsPhysicsHandle,
    pub collider: TecsPhysicsHandle,
}

/// One contact or sensor transition observed during the last step.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct TecsPhysicsPairEvent {
    pub entity_a: u64,
    pub entity_b: u64,
    pub started: u32,
    pub sensor: u32,
}

/// The nearest collider a segment met.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct TecsPhysicsRayHit {
    pub entity: u64,
    pub x: f32,
    pub y: f32,
    pub normal_x: f32,
    pub normal_y: f32,
    pub fraction: f32,
    pub reserved: u32,
}

/// One fixed step's complete crossing: commands in, results out.
///
/// Command pointers are read-only for the callee. Result pointers address
/// caller memory the callee fills. A null pointer is legal wherever the
/// matching count or capacity is zero.
#[repr(C)]
#[derive(Debug)]
pub struct TecsPhysicsBatch {
    pub dt: f32,
    pub reserved: u32,

    pub create_bodies: *const TecsPhysicsBodyCreate,
    pub create_body_count: u64,
    pub create_colliders: *const TecsPhysicsColliderCreate,
    pub create_collider_count: u64,
    pub create_joints: *const TecsPhysicsJointCreate,
    pub create_joint_count: u64,
    pub update_bodies: *const TecsPhysicsBodyUpdate,
    pub update_body_count: u64,
    pub update_colliders: *const TecsPhysicsColliderUpdate,
    pub update_collider_count: u64,
    pub actions: *const TecsPhysicsBodyAction,
    pub action_count: u64,
    pub destroy_bodies: *const TecsPhysicsHandle,
    pub destroy_body_count: u64,
    pub destroy_colliders: *const TecsPhysicsHandle,
    pub destroy_collider_count: u64,
    pub destroy_joints: *const TecsPhysicsHandle,
    pub destroy_joint_count: u64,

    pub created_bodies: *mut TecsPhysicsCreatedBody,
    pub created_body_capacity: u64,
    pub created_colliders: *mut TecsPhysicsHandle,
    pub created_collider_capacity: u64,
    pub created_joints: *mut TecsPhysicsHandle,
    pub created_joint_capacity: u64,
    pub updated_colliders: *mut TecsPhysicsHandle,
    pub updated_collider_capacity: u64,
    pub states: *mut TecsPhysicsBodyState,
    pub state_capacity: u64,
    pub moved: *mut u32,
    pub moved_capacity: u64,
    pub events: *mut TecsPhysicsPairEvent,
    pub event_capacity: u64,

    pub state_count: u64,
    pub moved_count: u64,
    pub event_count: u64,
}

/// The call applied its commands, stepped, and wrote every result.
pub const STATUS_OK: i32 = 0;
/// The call applied its commands and stepped, but a result buffer was short.
///
/// The batch's count fields report what the results actually need. Growing
/// those buffers and calling `tecsPhysicsDrain` copies them without stepping
/// again.
pub const STATUS_TRUNCATED: i32 = 1;
/// The call did nothing. `tecsPhysicsLastError` describes why.
pub const STATUS_ERROR: i32 = 2;

/// A body Rapier does not move.
pub const BODY_STATIC: u32 = 0;
/// A body the game moves through velocity, which pushes dynamic bodies.
pub const BODY_KINEMATIC: u32 = 1;
/// A body the solver moves.
pub const BODY_DYNAMIC: u32 = 2;

/// The body's angle is locked.
pub const BODY_FIXED_ROTATION: u32 = 1;
/// The body sweeps its motion for continuous collision.
pub const BODY_BULLET: u32 = 2;
/// The body may fall asleep when it comes to rest.
pub const BODY_SLEEP_ENABLED: u32 = 4;

/// An axis-aligned box in the body frame.
pub const SHAPE_BOX: u32 = 0;
/// A circle.
pub const SHAPE_CIRCLE: u32 = 1;
/// A vertical capsule.
pub const SHAPE_CAPSULE: u32 = 2;

/// The collider reports overlap without a collision response.
pub const COLLIDER_SENSOR: u32 = 1;

/// The collider update addresses its target by collider handle.
pub const COLLIDER_BY_HANDLE: u32 = 0;
/// The collider update addresses the collider under `body` owning `entity`.
pub const COLLIDER_BY_ENTITY: u32 = 1;

/// Both bodies keep one relative pose.
pub const JOINT_FIXED: u32 = 0;
/// Both bodies share one anchor point and rotate freely about it.
pub const JOINT_REVOLUTE: u32 = 1;
/// Both bodies slide along one axis and share their angle.
pub const JOINT_PRISMATIC: u32 = 2;

/// The joint's limits are enforced.
pub const JOINT_LIMITS: u32 = 1;
/// The joint's motor drives its free degree of freedom.
pub const JOINT_MOTOR: u32 = 2;
/// The joined bodies still collide with one another.
pub const JOINT_CONTACTS: u32 = 4;

/// The state slot addresses a live body.
pub const STATE_LIVE: u32 = 1;
/// The solver is still integrating the body.
pub const STATE_AWAKE: u32 = 2;
/// The body's pose differs from the one reported after the previous step.
pub const STATE_MOVED: u32 = 4;
/// The body participates in the simulation.
pub const STATE_ENABLED: u32 = 8;

/// Adds a center-of-mass impulse, in `a` and `b`.
pub const ACTION_IMPULSE: u32 = 0;
/// Adds an impulse `a`, `b` at the world point `c`, `d`.
pub const ACTION_IMPULSE_AT: u32 = 1;
/// Adds a center-of-mass force, in `a` and `b`.
pub const ACTION_FORCE: u32 = 2;
/// Adds a force `a`, `b` at the world point `c`, `d`.
pub const ACTION_FORCE_AT: u32 = 3;
/// Adds torque `a`.
pub const ACTION_TORQUE: u32 = 4;
/// Replaces linear velocity with `a`, `b`.
pub const ACTION_SET_VELOCITY: u32 = 5;
/// Replaces angular velocity with `a`.
pub const ACTION_SET_ANGULAR_VELOCITY: u32 = 6;
/// Wakes the body when `a` is nonzero and sleeps it otherwise.
pub const ACTION_SET_AWAKE: u32 = 7;
/// Enables the body when `a` is nonzero and disables it otherwise.
pub const ACTION_SET_ENABLED: u32 = 8;
/// Replaces the body type with `a`, one of the body kind constants.
pub const ACTION_SET_BODY_TYPE: u32 = 9;
/// Teleports the body to `a`, `b` with angle `c`, leaving velocity alone.
pub const ACTION_SET_TRANSFORM: u32 = 10;

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{align_of, offset_of, size_of};

    /// The managed binding repeats these numbers and asserts them at load.
    #[test]
    fn layout_is_pinned() {
        assert_eq!(size_of::<TecsPhysicsHandle>(), 8);
        assert_eq!(align_of::<TecsPhysicsHandle>(), 4);

        assert_eq!(size_of::<TecsPhysicsColliderDef>(), 64);
        assert_eq!(align_of::<TecsPhysicsColliderDef>(), 8);
        assert_eq!(offset_of!(TecsPhysicsColliderDef, entity), 0);
        assert_eq!(offset_of!(TecsPhysicsColliderDef, shape), 8);
        assert_eq!(offset_of!(TecsPhysicsColliderDef, half_width), 16);
        assert_eq!(offset_of!(TecsPhysicsColliderDef, category_bits), 52);
        assert_eq!(offset_of!(TecsPhysicsColliderDef, mask_bits), 56);

        assert_eq!(size_of::<TecsPhysicsBodyCreate>(), 120);
        assert_eq!(offset_of!(TecsPhysicsBodyCreate, collider), 8);
        assert_eq!(offset_of!(TecsPhysicsBodyCreate, kind), 72);
        assert_eq!(offset_of!(TecsPhysicsBodyCreate, omega), 112);

        assert_eq!(size_of::<TecsPhysicsBodyUpdate>(), 28);
        assert_eq!(size_of::<TecsPhysicsColliderCreate>(), 80);
        assert_eq!(size_of::<TecsPhysicsColliderUpdate>(), 88);
        assert_eq!(size_of::<TecsPhysicsJointCreate>(), 80);
        assert_eq!(size_of::<TecsPhysicsBodyAction>(), 32);
        assert_eq!(size_of::<TecsPhysicsBodyState>(), 40);
        assert_eq!(size_of::<TecsPhysicsCreatedBody>(), 16);
        assert_eq!(size_of::<TecsPhysicsPairEvent>(), 24);
        assert_eq!(size_of::<TecsPhysicsRayHit>(), 32);
        assert_eq!(size_of::<TecsPhysicsBatch>(), 288);
        assert_eq!(offset_of!(TecsPhysicsBatch, create_bodies), 8);
        assert_eq!(offset_of!(TecsPhysicsBatch, destroy_joints), 136);
        assert_eq!(offset_of!(TecsPhysicsBatch, created_bodies), 152);
        assert_eq!(offset_of!(TecsPhysicsBatch, states), 216);
        assert_eq!(offset_of!(TecsPhysicsBatch, state_count), 264);
        assert_eq!(offset_of!(TecsPhysicsBatch, event_count), 280);
    }
}
