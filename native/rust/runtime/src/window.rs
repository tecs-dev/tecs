//! Rust-owned SDL window callbacks.
//!
//! SDL can invoke a hit-test callback while it is processing native window
//! messages. Keeping the callback and its copied region list here prevents a
//! retained C function pointer from entering LuaJIT.

use std::ffi::{c_int, c_void};
use std::ptr;
use std::slice;
use std::sync::RwLock;

#[repr(C)]
pub struct SdlWindow {
    _private: [u8; 0],
}

#[repr(C)]
struct SdlPoint {
    x: c_int,
    y: c_int,
}

type SdlHitTest = unsafe extern "C" fn(*mut SdlWindow, *const SdlPoint, *mut c_void) -> c_int;

unsafe extern "C" {
    fn SDL_SetWindowHitTest(
        window: *mut SdlWindow,
        callback: Option<SdlHitTest>,
        callback_data: *mut c_void,
    ) -> bool;
}

const HITTEST_NORMAL: c_int = 0;
const HITTEST_FIRST_SPECIAL: c_int = 1;
const HITTEST_LAST_SPECIAL: c_int = 9;

#[derive(Clone, Copy)]
#[repr(C)]
pub struct TecsWindowHitRegion {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    result: i32,
}

pub struct TecsWindowHitRegions {
    regions: RwLock<Vec<TecsWindowHitRegion>>,
}

fn valid(region: &TecsWindowHitRegion) -> bool {
    region.x >= 0
        && region.y >= 0
        && region.width > 0
        && region.height > 0
        && (HITTEST_FIRST_SPECIAL..=HITTEST_LAST_SPECIAL).contains(&region.result)
}

fn copy_regions(
    regions: *const TecsWindowHitRegion,
    count: usize,
) -> Option<Vec<TecsWindowHitRegion>> {
    if count == 0 || regions.is_null() {
        return None;
    }
    // SAFETY: The caller promises `count` readable records for this call.
    let regions = unsafe { slice::from_raw_parts(regions, count) };
    if !regions.iter().all(valid) {
        return None;
    }
    Some(regions.to_vec())
}

fn result_at(regions: &[TecsWindowHitRegion], x: i32, y: i32) -> c_int {
    for region in regions {
        let right = i64::from(region.x) + i64::from(region.width);
        let bottom = i64::from(region.y) + i64::from(region.height);
        if x >= region.x && y >= region.y && i64::from(x) < right && i64::from(y) < bottom {
            return region.result;
        }
    }
    HITTEST_NORMAL
}

unsafe extern "C" fn hit_test(
    _window: *mut SdlWindow,
    point: *const SdlPoint,
    callback_data: *mut c_void,
) -> c_int {
    let Some(point) = (unsafe { point.as_ref() }) else {
        return HITTEST_NORMAL;
    };
    let Some(state) = (unsafe { callback_data.cast::<TecsWindowHitRegions>().as_ref() }) else {
        return HITTEST_NORMAL;
    };
    let regions = state
        .regions
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    result_at(&regions, point.x, point.y)
}

/// Copies regions and registers a Rust callback on a window.
///
/// Returns null when the arguments are invalid or SDL does not support window
/// hit testing. The returned state belongs to the caller.
///
/// # Safety
///
/// `window` must be a live SDL window. `regions` must address `count` readable
/// records for this call.
#[no_mangle]
pub unsafe extern "C" fn tecsWindowHitRegionsCreate(
    window: *mut SdlWindow,
    regions: *const TecsWindowHitRegion,
    count: usize,
) -> *mut TecsWindowHitRegions {
    if window.is_null() {
        return ptr::null_mut();
    }
    let Some(regions) = copy_regions(regions, count) else {
        return ptr::null_mut();
    };
    let state = Box::new(TecsWindowHitRegions {
        regions: RwLock::new(regions),
    });
    let state = Box::into_raw(state);
    if unsafe { SDL_SetWindowHitTest(window, Some(hit_test), state.cast::<c_void>()) } {
        state
    } else {
        // SAFETY: SDL rejected the callback, so it retained neither pointer.
        drop(unsafe { Box::from_raw(state) });
        ptr::null_mut()
    }
}

/// Replaces the copied regions behind an installed callback.
///
/// # Safety
///
/// `state` must be a live pointer returned by
/// `tecsWindowHitRegionsCreate`. `regions` must address `count` readable
/// records for this call.
#[no_mangle]
pub unsafe extern "C" fn tecsWindowHitRegionsUpdate(
    state: *mut TecsWindowHitRegions,
    regions: *const TecsWindowHitRegion,
    count: usize,
) -> bool {
    let Some(state) = (unsafe { state.as_ref() }) else {
        return false;
    };
    let Some(regions) = copy_regions(regions, count) else {
        return false;
    };
    *state
        .regions
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = regions;
    true
}

/// Unregisters a live window's callback and releases its copied regions.
///
/// On failure SDL may still retain the callback data, so this leaves the state
/// allocated and ownership with the caller.
///
/// # Safety
///
/// `window` and `state` must still be the pair passed to
/// `tecsWindowHitRegionsCreate`. A successful call consumes `state`.
#[no_mangle]
pub unsafe extern "C" fn tecsWindowHitRegionsClear(
    window: *mut SdlWindow,
    state: *mut TecsWindowHitRegions,
) -> bool {
    if window.is_null() || state.is_null() {
        return false;
    }
    if !unsafe { SDL_SetWindowHitTest(window, None, ptr::null_mut()) } {
        return false;
    }
    // SAFETY: SDL no longer retains this callback data.
    drop(unsafe { Box::from_raw(state) });
    true
}

/// Releases callback data after its SDL window has been destroyed.
///
/// # Safety
///
/// `state` must be null or a live pointer returned by
/// `tecsWindowHitRegionsCreate`, and SDL must no longer retain it.
#[no_mangle]
pub unsafe extern "C" fn tecsWindowHitRegionsDestroy(state: *mut TecsWindowHitRegions) {
    if !state.is_null() {
        // SAFETY: The destroyed window cannot call the callback again.
        drop(unsafe { Box::from_raw(state) });
    }
}

#[cfg(test)]
mod tests {
    use super::{result_at, TecsWindowHitRegion, HITTEST_NORMAL};

    #[test]
    fn first_matching_region_wins_and_edges_are_half_open() {
        let regions = [
            TecsWindowHitRegion {
                x: 0,
                y: 0,
                width: 10,
                height: 10,
                result: 2,
            },
            TecsWindowHitRegion {
                x: 5,
                y: 5,
                width: 10,
                height: 10,
                result: 1,
            },
        ];

        assert_eq!(result_at(&regions, 0, 0), 2);
        assert_eq!(result_at(&regions, 5, 5), 2);
        assert_eq!(result_at(&regions, 10, 5), 1);
        assert_eq!(result_at(&regions, 15, 5), HITTEST_NORMAL);
        assert_eq!(result_at(&regions, -1, 0), HITTEST_NORMAL);
    }
}
