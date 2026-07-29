//! Preserves nearby virtual address space for LuaJIT worker machine code.
//!
//! The host reserves the arena before application initialization and releases
//! it afterward; `tecs.workers` benefits when its later Lua states compile.

#[cfg(unix)]
mod platform {
    use std::ffi::c_void;
    use std::sync::{Mutex, OnceLock};

    const ARENA_BYTES: usize = 24 << 20;
    const ARENA_MIN: usize = 4 << 20;
    const MCODE_RANGE: usize = (1 << 26) - (1 << 21);
    const ATTEMPTS: usize = 64;
    const STEP: usize = 1 << 20;

    #[derive(Default)]
    struct Arena {
        address: usize,
        size: usize,
    }

    static ARENA: OnceLock<Mutex<Arena>> = OnceLock::new();

    unsafe extern "C" {
        fn luaL_newstate() -> *mut c_void;
    }

    fn interpreter_anchor() -> Option<usize> {
        let mut info = std::mem::MaybeUninit::<libc::Dl_info>::zeroed();
        let found = unsafe {
            libc::dladdr(
                luaL_newstate as *const () as *const c_void,
                info.as_mut_ptr(),
            )
        };
        if found == 0 {
            return None;
        }
        let base = unsafe { info.assume_init() }.dli_fbase as usize;
        (base != 0).then_some(base & !0xffff)
    }

    fn reserve_within(size: usize, low: usize, high: usize) -> Option<usize> {
        let mut hint = low;
        for _ in 0..ATTEMPTS {
            let address = unsafe {
                libc::mmap(
                    hint as *mut c_void,
                    size,
                    libc::PROT_NONE,
                    libc::MAP_PRIVATE | libc::MAP_ANON,
                    -1,
                    0,
                )
            };
            if address == libc::MAP_FAILED {
                return None;
            }
            let got = address as usize;
            if got >= low && got.checked_add(size).is_some_and(|end| end <= high) {
                return Some(got);
            }
            unsafe {
                libc::munmap(address, size);
            }
            hint = got.max(hint).saturating_add(STEP);
            if hint >= high {
                return None;
            }
        }
        None
    }

    pub fn reserve() -> bool {
        let arena = ARENA.get_or_init(|| Mutex::new(Arena::default()));
        let mut arena = arena
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if arena.address != 0 {
            return true;
        }
        let Some(target) = interpreter_anchor() else {
            return false;
        };
        let low = target.saturating_sub(MCODE_RANGE);
        let high = target.saturating_add(MCODE_RANGE);
        let mut size = ARENA_BYTES;
        while size >= ARENA_MIN {
            if let Some(address) = reserve_within(size, low, high) {
                arena.address = address;
                arena.size = size;
                return true;
            }
            size /= 2;
        }
        false
    }

    pub fn release() {
        let Some(arena) = ARENA.get() else {
            return;
        };
        let mut arena = arena
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if arena.address == 0 {
            return;
        }
        unsafe {
            libc::munmap(arena.address as *mut c_void, arena.size);
        }
        arena.address = 0;
        arena.size = 0;
    }
}

#[no_mangle]
pub extern "C" fn tecsMcodeArenaReserve() -> bool {
    #[cfg(unix)]
    {
        platform::reserve()
    }
    #[cfg(not(unix))]
    {
        false
    }
}

#[no_mangle]
pub extern "C" fn tecsMcodeArenaRelease() {
    #[cfg(unix)]
    platform::release();
}
