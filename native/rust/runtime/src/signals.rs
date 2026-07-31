//! Converts operating-system termination signals into polled process state.
//!
//! Signal handlers only touch atomics. `tecs.platform.os` drains those flags
//! from the Lua thread through this ABI, so no handler or console callback can
//! enter LuaJIT.

#[cfg(unix)]
mod platform {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};

    use signal_hook::consts::signal::{SIGHUP, SIGINT, SIGQUIT, SIGTERM};
    use signal_hook::flag;
    use signal_hook::low_level::unregister;
    use signal_hook::SigId;

    const INTERRUPT: u32 = 1 << 0;
    const TERMINATE: u32 = 1 << 1;
    const HANGUP: u32 = 1 << 2;
    const QUIT: u32 = 1 << 3;

    struct Flag {
        bit: u32,
        pending: Arc<AtomicBool>,
    }

    struct State {
        disabled: Arc<AtomicBool>,
        flags: Vec<Flag>,
    }

    static STATE: Mutex<Option<State>> = Mutex::new(None);

    pub fn install() -> Result<(), String> {
        let mut state = STATE.lock().unwrap_or_else(|error| error.into_inner());
        if let Some(state) = state.as_ref() {
            state.disabled.store(false, Ordering::Release);
            return Ok(());
        }

        let disabled = Arc::new(AtomicBool::new(false));
        let mut flags = Vec::with_capacity(4);
        let mut registrations: Vec<SigId> = Vec::with_capacity(8);
        for (signal, bit) in [
            (SIGINT, INTERRUPT),
            (SIGTERM, TERMINATE),
            (SIGHUP, HANGUP),
            (SIGQUIT, QUIT),
        ] {
            let pending = Arc::new(AtomicBool::new(false));
            match flag::register_conditional_default(signal, Arc::clone(&disabled)) {
                Ok(registration) => registrations.push(registration),
                Err(error) => {
                    for registration in registrations {
                        unregister(registration);
                    }
                    return Err(error.to_string());
                }
            }
            match flag::register(signal, Arc::clone(&pending)) {
                Ok(registration) => {
                    registrations.push(registration);
                    flags.push(Flag { bit, pending });
                }
                Err(error) => {
                    for registration in registrations {
                        unregister(registration);
                    }
                    return Err(error.to_string());
                }
            }
        }
        *state = Some(State { disabled, flags });
        Ok(())
    }

    pub fn poll() -> u32 {
        let state = STATE.lock().unwrap_or_else(|error| error.into_inner());
        let Some(state) = state.as_ref() else {
            return 0;
        };
        state.flags.iter().fold(0, |pending, flag| {
            if flag.pending.swap(false, Ordering::AcqRel) {
                pending | flag.bit
            } else {
                pending
            }
        })
    }

    pub fn uninstall() {
        let state = STATE.lock().unwrap_or_else(|error| error.into_inner());
        if let Some(state) = state.as_ref() {
            for flag in &state.flags {
                flag.pending.store(false, Ordering::Release);
            }
            state.disabled.store(true, Ordering::Release);
        }
    }
}

#[cfg(windows)]
mod platform {
    use std::ffi::c_int;
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

    const CTRL_C_EVENT: u32 = 0;
    const CTRL_BREAK_EVENT: u32 = 1;
    const CTRL_CLOSE_EVENT: u32 = 2;
    const CTRL_LOGOFF_EVENT: u32 = 5;
    const CTRL_SHUTDOWN_EVENT: u32 = 6;

    const INTERRUPT: u32 = 1 << 0;
    const TERMINATE: u32 = 1 << 1;

    static INSTALLED: AtomicBool = AtomicBool::new(false);
    static PENDING: AtomicU32 = AtomicU32::new(0);

    type Handler = Option<unsafe extern "system" fn(u32) -> c_int>;

    #[link(name = "Kernel32")]
    unsafe extern "system" {
        fn SetConsoleCtrlHandler(handler: Handler, add: c_int) -> c_int;
    }

    unsafe extern "system" fn console_handler(kind: u32) -> c_int {
        let bit = match kind {
            CTRL_C_EVENT | CTRL_BREAK_EVENT => INTERRUPT,
            CTRL_CLOSE_EVENT | CTRL_LOGOFF_EVENT | CTRL_SHUTDOWN_EVENT => TERMINATE,
            _ => return 0,
        };
        PENDING.fetch_or(bit, Ordering::Release);
        1
    }

    pub fn install() -> Result<(), String> {
        if INSTALLED.load(Ordering::Acquire) {
            return Ok(());
        }
        if unsafe { SetConsoleCtrlHandler(Some(console_handler), 1) } == 0 {
            return Err("cannot install the console signal handler".to_owned());
        }
        INSTALLED.store(true, Ordering::Release);
        Ok(())
    }

    pub fn poll() -> u32 {
        PENDING.swap(0, Ordering::AcqRel)
    }

    pub fn uninstall() {
        if INSTALLED.swap(false, Ordering::AcqRel) {
            unsafe {
                SetConsoleCtrlHandler(Some(console_handler), 0);
            }
        }
        PENDING.store(0, Ordering::Release);
    }
}

#[cfg(not(any(unix, windows)))]
mod platform {
    pub fn install() -> Result<(), String> {
        Err("process signals are not supported on this platform".to_owned())
    }

    pub fn poll() -> u32 {
        0
    }

    pub fn uninstall() {}
}

#[no_mangle]
pub extern "C" fn tecsSignalsInstall() -> bool {
    match platform::install() {
        Ok(()) => true,
        Err(error) => {
            super::set_error(error);
            false
        }
    }
}

#[no_mangle]
pub extern "C" fn tecsSignalsPoll() -> u32 {
    platform::poll()
}

#[no_mangle]
pub extern "C" fn tecsSignalsUninstall() {
    platform::uninstall();
}
