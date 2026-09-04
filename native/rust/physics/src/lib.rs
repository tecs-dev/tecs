//! Rapier 2D behind a batched, callback-free C ABI.
//!
//! One fixed step is one call. The managed caller fills command arrays it
//! owns, sizes the result arrays it owns, and hands both to
//! `tecsPhysicsStep`; the callee applies every command in a fixed order,
//! advances the world, and copies the results back. Nothing here retains a
//! caller pointer past the call that supplied it, and nothing here invokes a
//! caller function: a managed callback cannot be entered from a compiled
//! trace or from a thread the managed VM never created, so contacts, poses,
//! and assigned handles all leave through buffers instead.

pub mod abi;
pub mod sim;

use std::cell::RefCell;
use std::ffi::{c_char, CString};
use std::ptr;
use std::slice;

pub use abi::*;
pub use sim::{configure_workers, default_worker_count, Batch, Results, Simulation};

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default());
}

fn set_error(message: impl ToString) {
    let text = message.to_string().replace('\0', " ");
    LAST_ERROR.with(|slot| {
        *slot.borrow_mut() = CString::new(text).unwrap_or_default();
    });
}

/// Borrows this thread's most recent failure message.
///
/// The pointer stays valid until the next failing call on the same thread.
#[no_mangle]
pub extern "C" fn tecsPhysicsLastError() -> *const c_char {
    LAST_ERROR.with(|slot| slot.borrow().as_ptr())
}

/// Reports the solver width a world receives when it asks for none.
#[no_mangle]
pub extern "C" fn tecsPhysicsDefaultWorkerCount() -> u32 {
    default_worker_count()
}

/// Creates an isolated world with gravity in meters per second squared.
///
/// The returned pointer is owned by the caller and released exactly once by
/// `tecsPhysicsWorldDestroy`.
#[no_mangle]
pub extern "C" fn tecsPhysicsWorldCreate(
    gravity_x: f32,
    gravity_y: f32,
    substeps: u32,
    worker_count: u32,
) -> *mut Simulation {
    Box::into_raw(Box::new(Simulation::new(
        gravity_x,
        gravity_y,
        substeps,
        worker_count,
    )))
}

/// Releases a world and every Rapier container it owns.
///
/// # Safety
///
/// `world` must be null or a pointer this module returned and has not
/// already released.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsWorldDestroy(world: *mut Simulation) {
    if !world.is_null() {
        // SAFETY: ownership crosses this boundary exactly once.
        drop(unsafe { Box::from_raw(world) });
    }
}

/// Reports the substep count a world divides each step into.
///
/// # Safety
///
/// `world` must be null or point to a live world.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsSubstepCount(world: *const Simulation) -> u32 {
    unsafe { world.as_ref() }.map_or(0, Simulation::substeps)
}

/// Reports the solver width a world was configured with.
///
/// # Safety
///
/// `world` must be null or point to a live world.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsWorkerCount(world: *const Simulation) -> u32 {
    unsafe { world.as_ref() }.map_or(0, Simulation::worker_count)
}

/// Reports how many bodies a world holds.
///
/// # Safety
///
/// `world` must be null or point to a live world.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsBodyCount(world: *const Simulation) -> u64 {
    unsafe { world.as_ref() }.map_or(0, |world| world.body_count() as u64)
}

/// Reports how many impulse joints a world holds.
///
/// # Safety
///
/// `world` must be null or point to a live world.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsJointCount(world: *const Simulation) -> u64 {
    unsafe { world.as_ref() }.map_or(0, |world| world.joint_count() as u64)
}

/// Borrows one command array, treating a null pointer at count zero as empty.
///
/// # Safety
///
/// For a nonzero `count`, `data` must address that many readable elements.
unsafe fn command_slice<'a, T>(data: *const T, count: u64) -> Option<&'a [T]> {
    if count == 0 {
        return Some(&[]);
    }
    if data.is_null() {
        return None;
    }
    // SAFETY: the caller guarantees this readable range for the call.
    Some(unsafe { slice::from_raw_parts(data, count as usize) })
}

/// Copies `source` into caller memory and reports whether it fit.
///
/// A null target means the caller does not want that result, which is not a
/// shortfall: the count is still reported and nothing is truncated.
///
/// # Safety
///
/// For a nonzero `capacity`, `target` must address that many writable
/// elements.
unsafe fn copy_out<T: Copy>(source: &[T], target: *mut T, capacity: u64) -> bool {
    if target.is_null() {
        return true;
    }
    let fits = source.len() as u64 <= capacity;
    let count = source.len().min(capacity as usize);
    if count > 0 {
        // SAFETY: the caller guarantees this writable range for the call.
        unsafe { ptr::copy_nonoverlapping(source.as_ptr(), target, count) };
    }
    fits
}

/// Copies the last step's results into the batch's result buffers.
///
/// # Safety
///
/// Every result pointer in `batch` must address at least its capacity.
unsafe fn write_results(world: &Simulation, batch: &mut TecsPhysicsBatch) -> i32 {
    let results = world.results();
    batch.state_count = results.states.len() as u64;
    batch.moved_count = results.moved.len() as u64;
    batch.event_count = results.events.len() as u64;
    // SAFETY: forwarding the caller's guarantee about each result buffer.
    let fits = unsafe {
        let mut fits = copy_out(results.states, batch.states, batch.state_capacity);
        fits &= copy_out(results.moved, batch.moved, batch.moved_capacity);
        fits &= copy_out(results.events, batch.events, batch.event_capacity);
        fits &= copy_out(
            results.created_bodies,
            batch.created_bodies,
            batch.created_body_capacity,
        );
        fits &= copy_out(
            results.created_colliders,
            batch.created_colliders,
            batch.created_collider_capacity,
        );
        fits &= copy_out(
            results.created_joints,
            batch.created_joints,
            batch.created_joint_capacity,
        );
        fits &= copy_out(
            results.updated_colliders,
            batch.updated_colliders,
            batch.updated_collider_capacity,
        );
        fits
    };
    if fits {
        STATUS_OK
    } else {
        STATUS_TRUNCATED
    }
}

/// Applies one batch, advances the world, and writes back every result.
///
/// Commands are applied in a fixed order that does not depend on how the
/// caller discovered them: joint destruction, collider destruction, body
/// destruction, body creation, secondary collider creation, joint creation,
/// body redeclaration, collider replacement, then queued actions. The world
/// then steps by `batch.dt` seconds.
///
/// Returns `STATUS_OK`, or `STATUS_TRUNCATED` when the step ran but a result
/// buffer was smaller than its result. A truncated call leaves the required
/// counts in the batch, and `tecsPhysicsDrain` copies the same results into
/// larger buffers without stepping again.
///
/// # Safety
///
/// `world` must point to a live world and `batch` to a writable batch whose
/// command pointers address their counts and whose result pointers address
/// their capacities.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsStep(
    world: *mut Simulation,
    batch: *mut TecsPhysicsBatch,
) -> i32 {
    let (Some(world), Some(batch)) = (unsafe { world.as_mut() }, unsafe { batch.as_mut() }) else {
        set_error("physics step received a null world or batch");
        return STATUS_ERROR;
    };
    if !batch.dt.is_finite() || batch.dt < 0.0 {
        set_error("physics step interval must be a non-negative finite number");
        return STATUS_ERROR;
    }
    // SAFETY: forwarding the caller's guarantee about each command array.
    let commands = unsafe {
        (|| {
            Some(Batch {
                dt: batch.dt,
                create_bodies: command_slice(batch.create_bodies, batch.create_body_count)?,
                create_colliders: command_slice(
                    batch.create_colliders,
                    batch.create_collider_count,
                )?,
                create_joints: command_slice(batch.create_joints, batch.create_joint_count)?,
                update_bodies: command_slice(batch.update_bodies, batch.update_body_count)?,
                update_colliders: command_slice(
                    batch.update_colliders,
                    batch.update_collider_count,
                )?,
                actions: command_slice(batch.actions, batch.action_count)?,
                destroy_bodies: command_slice(batch.destroy_bodies, batch.destroy_body_count)?,
                destroy_colliders: command_slice(
                    batch.destroy_colliders,
                    batch.destroy_collider_count,
                )?,
                destroy_joints: command_slice(batch.destroy_joints, batch.destroy_joint_count)?,
            })
        })()
    };
    let Some(commands) = commands else {
        set_error("physics batch has a null command array with a nonzero count");
        return STATUS_ERROR;
    };
    if batch.created_body_capacity < batch.create_body_count
        || batch.created_collider_capacity < batch.create_collider_count
        || batch.created_joint_capacity < batch.create_joint_count
        || batch.updated_collider_capacity < batch.update_collider_count
    {
        set_error("physics batch result buffers are smaller than their command arrays");
        return STATUS_ERROR;
    }

    world.apply(&commands);
    world.step(commands.dt);
    world.refresh();
    world.drain_events();

    // SAFETY: forwarding the caller's guarantee about each result buffer.
    unsafe { write_results(world, batch) }
}

/// Copies the last step's results again, without applying or stepping.
///
/// # Safety
///
/// `world` must point to a live world and `batch` to a writable batch whose
/// result pointers address their capacities.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsDrain(
    world: *const Simulation,
    batch: *mut TecsPhysicsBatch,
) -> i32 {
    let (Some(world), Some(batch)) = (unsafe { world.as_ref() }, unsafe { batch.as_mut() }) else {
        set_error("physics drain received a null world or batch");
        return STATUS_ERROR;
    };
    // SAFETY: forwarding the caller's guarantee about each result buffer.
    unsafe { write_results(world, batch) }
}

/// Casts a finite segment and writes its nearest hit.
///
/// Returns 1 for a hit, 0 for a miss, and `STATUS_ERROR` for a null pointer.
///
/// # Safety
///
/// `world` must point to a live world and `output` to one writable hit.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsRaycast(
    world: *const Simulation,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    category_bits: u32,
    mask_bits: u32,
    output: *mut TecsPhysicsRayHit,
) -> i32 {
    let (Some(world), Some(output)) = (unsafe { world.as_ref() }, unsafe { output.as_mut() })
    else {
        set_error("physics raycast received a null world or output");
        return STATUS_ERROR;
    };
    match world.raycast(x1, y1, x2, y2, category_bits, mask_bits) {
        Some(hit) => {
            *output = hit;
            1
        }
        None => 0,
    }
}

/// Answers the body, collider, and joint handle owned by each entity.
///
/// A snapshot load resolves every restored entity in one call so the cost
/// stays linear in the world rather than quadratic.
///
/// # Safety
///
/// `world` must point to a live world, `entities` must address `count`
/// readable ids, and `bodies`, `colliders` and `joints` must each address
/// `count` writable handles.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsResolveEntities(
    world: *const Simulation,
    entities: *const u64,
    count: u64,
    bodies: *mut TecsPhysicsHandle,
    colliders: *mut TecsPhysicsHandle,
    joints: *mut TecsPhysicsHandle,
) -> i32 {
    let Some(world) = (unsafe { world.as_ref() }) else {
        set_error("physics entity resolution received a null world");
        return STATUS_ERROR;
    };
    if count == 0 {
        return STATUS_OK;
    }
    if entities.is_null() || bodies.is_null() || colliders.is_null() || joints.is_null() {
        set_error("physics entity resolution received a null array with a nonzero count");
        return STATUS_ERROR;
    }
    // SAFETY: the caller guarantees all four ranges for the call.
    unsafe {
        world.resolve_entities(
            slice::from_raw_parts(entities, count as usize),
            slice::from_raw_parts_mut(bodies, count as usize),
            slice::from_raw_parts_mut(colliders, count as usize),
            slice::from_raw_parts_mut(joints, count as usize),
        );
    }
    STATUS_OK
}

/// Serializes the world into its own buffer and reports the byte length.
///
/// Returns zero on failure, which `tecsPhysicsLastError` describes. The
/// bytes remain readable through `tecsPhysicsSnapshotRead` until the next
/// call to this function on the same world.
///
/// # Safety
///
/// `world` must point to a live world.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsSnapshotBegin(world: *mut Simulation) -> u64 {
    let Some(world) = (unsafe { world.as_mut() }) else {
        set_error("physics snapshot received a null world");
        return 0;
    };
    match world.save() {
        Ok(length) => length as u64,
        Err(error) => {
            set_error(error);
            0
        }
    }
}

/// Copies the bytes produced by the last `tecsPhysicsSnapshotBegin`.
///
/// Returns how many bytes were written, which is zero when `capacity` is
/// smaller than the snapshot.
///
/// # Safety
///
/// `world` must point to a live world and `output` must address `capacity`
/// writable bytes.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsSnapshotRead(
    world: *const Simulation,
    output: *mut u8,
    capacity: u64,
) -> u64 {
    let Some(world) = (unsafe { world.as_ref() }) else {
        set_error("physics snapshot read received a null world");
        return 0;
    };
    let bytes = world.saved();
    if bytes.is_empty() || bytes.len() as u64 > capacity || output.is_null() {
        return 0;
    }
    // SAFETY: the caller guarantees this writable range for the call.
    unsafe { ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len()) };
    bytes.len() as u64
}

/// Replaces every container with a previously saved snapshot.
///
/// # Safety
///
/// `world` must point to a live world and, for a nonzero `length`, `bytes`
/// must address that many readable bytes.
#[no_mangle]
pub unsafe extern "C" fn tecsPhysicsSnapshotRestore(
    world: *mut Simulation,
    bytes: *const u8,
    length: u64,
) -> i32 {
    let Some(world) = (unsafe { world.as_mut() }) else {
        set_error("physics restore received a null world");
        return STATUS_ERROR;
    };
    if bytes.is_null() || length == 0 {
        set_error("physics restore received no snapshot bytes");
        return STATUS_ERROR;
    }
    // SAFETY: the caller guarantees this readable range for the call.
    let bytes = unsafe { slice::from_raw_parts(bytes, length as usize) };
    match world.restore(bytes) {
        Ok(()) => STATUS_OK,
        Err(error) => {
            set_error(error);
            STATUS_ERROR
        }
    }
}
