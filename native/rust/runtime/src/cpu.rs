//! Bounded CPU jobs that must not contend with file-open progress.

use std::ffi::{c_char, CString};
use std::ptr;
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

use crate::{decode, set_error, TecsBytes, TecsImage};

const CPU_WORKERS: usize = 2;
const CPU_QUEUE_CAPACITY: usize = 64;
const MAX_CPU_REQUESTS: usize = 64;
const MAX_CPU_BYTES: usize = 256 * 1024 * 1024;

const STATUS_PENDING: i32 = 0;
const STATUS_READY: i32 = 1;
const STATUS_FAILED: i32 = 2;

struct State {
    status: i32,
    input: Option<Box<TecsBytes>>,
    image: Option<TecsImage>,
    error: Option<CString>,
    _abandoned: bool,
}

pub struct TecsImageDecodeRequest {
    state: Mutex<State>,
    changed: Condvar,
    bytes: usize,
}

struct Counts {
    requests: usize,
    bytes: usize,
}

struct CpuPool {
    sender: SyncSender<usize>,
    counts: Arc<Mutex<Counts>>,
}

static CPU: OnceLock<CpuPool> = OnceLock::new();

fn message(value: impl ToString) -> CString {
    CString::new(value.to_string().replace('\0', "\\0")).expect("interior NUL bytes were replaced")
}

fn pool() -> &'static CpuPool {
    CPU.get_or_init(|| {
        let (sender, receiver) = mpsc::sync_channel(CPU_QUEUE_CAPACITY);
        let jobs: Arc<Mutex<Receiver<usize>>> = Arc::new(Mutex::new(receiver));
        let counts = Arc::new(Mutex::new(Counts {
            requests: 0,
            bytes: 0,
        }));
        for index in 0..CPU_WORKERS {
            let jobs = jobs.clone();
            let counts = counts.clone();
            thread::Builder::new()
                .name(format!("tecs.cpu.{index}"))
                .spawn(move || loop {
                    let request = jobs
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .recv();
                    let Ok(pointer) = request else {
                        break;
                    };
                    let request = unsafe { &*(pointer as *const TecsImageDecodeRequest) };
                    let input = request
                        .state
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .input
                        .take()
                        .expect("a queued CPU job owns its input");
                    let decoded = decode(&input.bytes);
                    drop(input);
                    let request_bytes = request.bytes;
                    {
                        let mut counts = counts
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner);
                        counts.requests = counts.requests.saturating_sub(1);
                        counts.bytes = counts.bytes.saturating_sub(request_bytes);
                    }
                    let abandoned;
                    {
                        let mut state = request
                            .state
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner);
                        match decoded {
                            Ok(image) => {
                                state.image = Some(image);
                                state.status = STATUS_READY;
                            }
                            Err(error) => {
                                state.error = Some(message(error));
                                state.status = STATUS_FAILED;
                            }
                        }
                        abandoned = state._abandoned;
                        // Publish completion only after every shared counter
                        // and request field is finished. Destroy may free the
                        // request as soon as this lock is released.
                        request.changed.notify_all();
                    }
                    if abandoned {
                        unsafe { drop(Box::from_raw(pointer as *mut TecsImageDecodeRequest)) };
                    }
                })
                .expect("the bounded CPU worker must start");
        }
        CpuPool { sender, counts }
    })
}

#[no_mangle]
pub unsafe extern "C" fn tecsImageDecodeStart(
    bytes: *mut TecsBytes,
) -> *mut TecsImageDecodeRequest {
    if bytes.is_null() {
        set_error("image decode bytes are null");
        return ptr::null_mut();
    }
    let bytes = unsafe { Box::from_raw(bytes) };
    let length = bytes.bytes.len();
    let request = Box::new(TecsImageDecodeRequest {
        state: Mutex::new(State {
            status: STATUS_PENDING,
            input: Some(bytes),
            image: None,
            error: None,
            _abandoned: false,
        }),
        changed: Condvar::new(),
        bytes: length,
    });
    let pointer = Box::into_raw(request);
    let pool = pool();
    {
        let mut counts = pool
            .counts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if counts.requests >= MAX_CPU_REQUESTS
            || counts.bytes.saturating_add(length) > MAX_CPU_BYTES
        {
            drop(counts);
            unsafe { drop(Box::from_raw(pointer)) };
            set_error("CPU decode queue capacity exceeded");
            return ptr::null_mut();
        }
        counts.requests += 1;
        counts.bytes += length;
    }
    match pool.sender.try_send(pointer as usize) {
        Ok(()) => pointer,
        Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {
            let mut counts = pool
                .counts
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            counts.requests = counts.requests.saturating_sub(1);
            counts.bytes = counts.bytes.saturating_sub(length);
            drop(counts);
            unsafe { drop(Box::from_raw(pointer)) };
            set_error("CPU decode queue is unavailable");
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsImageDecodeStatus(request: *const TecsImageDecodeRequest) -> i32 {
    let Some(request) = (unsafe { request.as_ref() }) else {
        return STATUS_FAILED;
    };
    request
        .state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .status
}

#[no_mangle]
pub unsafe extern "C" fn tecsImageDecodeWait(
    request: *mut TecsImageDecodeRequest,
    wait_ms: u32,
) -> u32 {
    let Some(request) = (unsafe { request.as_ref() }) else {
        return 0;
    };
    let state = request
        .state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if state.status != STATUS_PENDING {
        return 1;
    }
    let waited = request
        .changed
        .wait_timeout(state, Duration::from_millis(wait_ms as u64))
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    u32::from(waited.0.status != STATUS_PENDING)
}

#[no_mangle]
pub unsafe extern "C" fn tecsImageDecodeError(
    request: *const TecsImageDecodeRequest,
) -> *const c_char {
    let Some(request) = (unsafe { request.as_ref() }) else {
        return c"image decode request is null".as_ptr();
    };
    request
        .state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .error
        .as_ref()
        .map_or(c"image decode failed".as_ptr(), |error| error.as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn tecsImageDecodeTake(
    request: *mut TecsImageDecodeRequest,
) -> *mut TecsImage {
    let Some(request_ref) = (unsafe { request.as_ref() }) else {
        set_error("image decode request is null");
        return ptr::null_mut();
    };
    let image = request_ref
        .state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .image
        .take();
    let Some(image) = image else {
        set_error("image decode is not ready");
        return ptr::null_mut();
    };
    unsafe { drop(Box::from_raw(request)) };
    Box::into_raw(Box::new(image))
}

#[no_mangle]
pub unsafe extern "C" fn tecsImageDecodeRequestDestroy(request: *mut TecsImageDecodeRequest) {
    let Some(request_ref) = (unsafe { request.as_ref() }) else {
        return;
    };
    let mut state = request_ref
        .state
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if state.status == STATUS_PENDING {
        state._abandoned = true;
        return;
    }
    drop(state);
    unsafe { drop(Box::from_raw(request)) };
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    static TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn decodes_on_the_cpu_lane_and_transfers_image_ownership() {
        let _guard = TEST_LOCK.lock().unwrap();
        let bytes = Box::into_raw(Box::new(TecsBytes {
            bytes: br#"<svg xmlns="http://www.w3.org/2000/svg" width="2" height="3"/>"#
                .to_vec()
                .into_boxed_slice(),
        }));
        let request = unsafe { tecsImageDecodeStart(bytes) };
        assert!(!request.is_null());
        assert_eq!(unsafe { tecsImageDecodeWait(request, 5000) }, 1);
        assert_eq!(unsafe { tecsImageDecodeStatus(request) }, STATUS_READY);
        let image = unsafe { tecsImageDecodeTake(request) };
        assert!(!image.is_null());
        assert_eq!(unsafe { (*image).width }, 2);
        assert_eq!(unsafe { (*image).height }, 3);
        unsafe { drop(Box::from_raw(image)) };
    }

    #[test]
    fn keeps_decode_failures_on_the_request() {
        let _guard = TEST_LOCK.lock().unwrap();
        let bytes = Box::into_raw(Box::new(TecsBytes {
            bytes: b"not an image".to_vec().into_boxed_slice(),
        }));
        let request = unsafe { tecsImageDecodeStart(bytes) };
        assert!(!request.is_null());
        assert_eq!(unsafe { tecsImageDecodeWait(request, 5000) }, 1);
        assert_eq!(unsafe { tecsImageDecodeStatus(request) }, STATUS_FAILED);
        assert!(
            !unsafe { std::ffi::CStr::from_ptr(tecsImageDecodeError(request)) }
                .to_bytes()
                .is_empty()
        );
        unsafe { tecsImageDecodeRequestDestroy(request) };
    }

    #[test]
    fn immediately_abandons_thousands_of_decode_requests() {
        let _guard = TEST_LOCK.lock().unwrap();
        const SVG: &[u8] = br#"<svg xmlns="http://www.w3.org/2000/svg" width="2" height="3"/>"#;
        for index in 0..2_000 {
            loop {
                let bytes = Box::into_raw(Box::new(TecsBytes {
                    bytes: SVG.to_vec().into_boxed_slice(),
                }));
                let request = unsafe { tecsImageDecodeStart(bytes) };
                if request.is_null() {
                    thread::yield_now();
                    continue;
                }
                if index % 2 == 0 {
                    thread::yield_now();
                }
                unsafe { tecsImageDecodeRequestDestroy(request) };
                break;
            }
        }

        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let counts = pool()
                .counts
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if counts.requests == 0 {
                assert_eq!(counts.bytes, 0);
                break;
            }
            assert!(
                Instant::now() < deadline,
                "abandoned CPU jobs did not drain"
            );
            drop(counts);
            thread::yield_now();
        }
    }
}
