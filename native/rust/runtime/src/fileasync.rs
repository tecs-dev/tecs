//! Bounded regular-file transfers over SDL AsyncIO.
//!
//! SDL makes transfers asynchronous but deliberately leaves open and size
//! lookup synchronous. Two process-lifetime blocking workers cover only that
//! gap. The owner thread starts and drains one SDL queue; native workers never
//! call Lua.

use std::cell::RefCell;
use std::collections::HashSet;
use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::slice;
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use sdl3_sys::asyncio::{
    SDL_AsyncIO, SDL_AsyncIOOutcome, SDL_AsyncIOQueue, SDL_AsyncIOResult, SDL_AsyncIOTaskType,
    SDL_CloseAsyncIO, SDL_CreateAsyncIOQueue, SDL_DestroyAsyncIOQueue, SDL_GetAsyncIOResult,
    SDL_GetAsyncIOSize, SDL_ReadAsyncIO, SDL_WaitAsyncIOResult, SDL_WriteAsyncIO,
};
use sdl3_sys::error::SDL_GetError;

use crate::{set_error, TecsBytes};

const OPEN_WORKERS: usize = 2;
const OPEN_QUEUE_CAPACITY: usize = 64;
const MAX_REQUESTS: usize = 128;
const MAX_BYTES: usize = 256 * 1024 * 1024;
const MAX_REQUEST_BYTES: usize = 256 * 1024 * 1024;

const STATUS_PENDING: i32 = 0;
const STATUS_READY: i32 = 1;
const STATUS_FAILED: i32 = 2;
const STATUS_CANCELED: i32 = 3;

#[derive(Clone, Copy)]
enum Kind {
    Read,
    Write,
}

enum OpenJob {
    Open {
        request: usize,
        path: CString,
        kind: Kind,
    },
}

struct OpenResult {
    request: usize,
    file: usize,
    size: i64,
    error: Option<CString>,
}

struct BlockingLane {
    sender: SyncSender<OpenJob>,
    receiver: Mutex<Receiver<OpenResult>>,
}

static BLOCKING_LANE: OnceLock<BlockingLane> = OnceLock::new();

pub struct TecsAsyncFileRequest {
    kind: Kind,
    status: i32,
    outcomes: u8,
    failure: Option<CString>,
    canceled: bool,
    abandoned: bool,
    data: *mut u8,
    length: usize,
    capacity: usize,
    owned: Option<Box<[u8]>>,
    accounted: usize,
    flush: bool,
}

struct AsyncRuntime {
    queue: *mut SDL_AsyncIOQueue,
    active: HashSet<usize>,
    requests: usize,
    bytes: usize,
    opening: usize,
}

impl AsyncRuntime {
    fn new() -> Self {
        Self {
            queue: ptr::null_mut(),
            active: HashSet::new(),
            requests: 0,
            bytes: 0,
            opening: 0,
        }
    }

    fn queue(&mut self) -> Result<*mut SDL_AsyncIOQueue, CString> {
        if self.queue.is_null() {
            self.queue = unsafe { SDL_CreateAsyncIOQueue() };
            if self.queue.is_null() {
                return Err(sdl_error("cannot create the SDL AsyncIO queue"));
            }
        }
        Ok(self.queue)
    }
}

thread_local! {
    static ASYNC: RefCell<AsyncRuntime> = RefCell::new(AsyncRuntime::new());
}

fn cstring(message: impl ToString) -> CString {
    CString::new(message.to_string().replace('\0', "\\0"))
        .expect("interior NUL bytes were replaced")
}

fn sdl_error(context: &str) -> CString {
    let pointer = SDL_GetError();
    let detail = if pointer.is_null() {
        "unknown SDL error".to_owned()
    } else {
        // SAFETY: SDL owns a NUL-terminated thread-local error string.
        unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned()
    };
    cstring(format!("{context}: {detail}"))
}

fn lane() -> &'static BlockingLane {
    BLOCKING_LANE.get_or_init(|| {
        let (job_sender, job_receiver) = mpsc::sync_channel(OPEN_QUEUE_CAPACITY);
        let (result_sender, result_receiver) = mpsc::channel();
        let jobs = std::sync::Arc::new(Mutex::new(job_receiver));
        for index in 0..OPEN_WORKERS {
            let jobs = jobs.clone();
            let results = result_sender.clone();
            thread::Builder::new()
                .name(format!("tecs.file-open.{index}"))
                .spawn(move || loop {
                    let job = jobs
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .recv();
                    let Ok(OpenJob::Open {
                        request,
                        path,
                        kind,
                    }) = job
                    else {
                        break;
                    };
                    let mode = match kind {
                        Kind::Read => c"r",
                        Kind::Write => c"w",
                    };
                    let file = unsafe {
                        sdl3_sys::asyncio::SDL_AsyncIOFromFile(path.as_ptr(), mode.as_ptr())
                    };
                    let (size, error) = if file.is_null() {
                        (-1, Some(sdl_error("cannot open file")))
                    } else if matches!(kind, Kind::Read) {
                        let size = unsafe { SDL_GetAsyncIOSize(file) };
                        if size < 0 {
                            (size, Some(sdl_error("cannot determine file size")))
                        } else {
                            (size, None)
                        }
                    } else {
                        (0, None)
                    };
                    if results
                        .send(OpenResult {
                            request,
                            file: file as usize,
                            size,
                            error,
                        })
                        .is_err()
                    {
                        break;
                    }
                })
                .expect("the bounded file-open worker must start");
        }
        BlockingLane {
            sender: job_sender,
            receiver: Mutex::new(result_receiver),
        }
    })
}

unsafe fn path(path: *const u8, length: usize) -> Result<CString, CString> {
    if path.is_null() && length != 0 {
        return Err(cstring("file path is null"));
    }
    let bytes = if length == 0 {
        &[]
    } else {
        // SAFETY: The boundary promises `length` readable bytes.
        unsafe { slice::from_raw_parts(path, length) }
    };
    CString::new(bytes).map_err(|_| cstring("file path contains a NUL byte"))
}

fn finish(runtime: &mut AsyncRuntime, pointer: usize) {
    let request = unsafe { &mut *(pointer as *mut TecsAsyncFileRequest) };
    if request.outcomes != 0 || request.status != STATUS_PENDING {
        return;
    }
    request.status = if request.failure.is_some() {
        STATUS_FAILED
    } else if request.canceled {
        STATUS_CANCELED
    } else {
        STATUS_READY
    };
    runtime.active.remove(&pointer);
    runtime.requests = runtime.requests.saturating_sub(1);
    runtime.bytes = runtime.bytes.saturating_sub(request.accounted);
    request.accounted = 0;
}

fn queue_close(
    runtime: &mut AsyncRuntime,
    request: &mut TecsAsyncFileRequest,
    file: *mut SDL_AsyncIO,
    flush: bool,
) {
    let pointer = request as *mut TecsAsyncFileRequest;
    let queue = match runtime.queue() {
        Ok(queue) => queue,
        Err(error) => {
            if request.failure.is_none() {
                request.failure = Some(error);
            }
            return;
        }
    };
    if unsafe { SDL_CloseAsyncIO(file, flush, queue, pointer.cast()) } {
        request.outcomes = request.outcomes.saturating_add(1);
    } else if request.failure.is_none() {
        request.failure = Some(sdl_error("cannot queue file close"));
    }
}

fn handle_open(runtime: &mut AsyncRuntime, opened: OpenResult) {
    if !runtime.active.contains(&opened.request) {
        return;
    }
    runtime.opening = runtime.opening.saturating_sub(1);
    let request = unsafe { &mut *(opened.request as *mut TecsAsyncFileRequest) };
    let file = opened.file as *mut SDL_AsyncIO;
    if let Some(error) = opened.error {
        request.failure = Some(error);
        if !file.is_null() {
            queue_close(runtime, request, file, request.flush);
        }
        finish(runtime, opened.request);
        return;
    }

    let queue = match runtime.queue() {
        Ok(queue) => queue,
        Err(error) => {
            request.failure = Some(error);
            // There is no synchronous SDL close. Queue creation failure is a
            // process-level fault; retaining this rare handle is safer than
            // inventing a close call SDL does not provide.
            finish(runtime, opened.request);
            return;
        }
    };
    debug_assert_eq!(queue, runtime.queue);

    match request.kind {
        Kind::Read => {
            let Ok(length) = usize::try_from(opened.size) else {
                request.failure = Some(cstring("file size does not fit this platform"));
                queue_close(runtime, request, file, false);
                finish(runtime, opened.request);
                return;
            };
            if length > MAX_REQUEST_BYTES || runtime.bytes.saturating_add(length) > MAX_BYTES {
                request.failure = Some(cstring("asynchronous file byte limit exceeded"));
                queue_close(runtime, request, file, false);
                finish(runtime, opened.request);
                return;
            }
            runtime.bytes += length;
            request.accounted = length;
            request.capacity = length;
            let mut bytes = vec![0_u8; length].into_boxed_slice();
            request.data = bytes.as_mut_ptr();
            request.owned = Some(bytes);
            if length == 0 {
                request.length = 0;
            } else if unsafe {
                SDL_ReadAsyncIO(
                    file,
                    request.data.cast(),
                    0,
                    length as u64,
                    queue,
                    (request as *mut TecsAsyncFileRequest).cast(),
                )
            } {
                request.outcomes = request.outcomes.saturating_add(1);
            } else {
                request.failure = Some(sdl_error("cannot queue file read"));
            }
            queue_close(runtime, request, file, request.flush);
        }
        Kind::Write => {
            let length = request.length;
            if length > 0 {
                if unsafe {
                    SDL_WriteAsyncIO(
                        file,
                        request.data.cast(),
                        0,
                        length as u64,
                        queue,
                        (request as *mut TecsAsyncFileRequest).cast(),
                    )
                } {
                    request.outcomes = request.outcomes.saturating_add(1);
                } else {
                    request.failure = Some(sdl_error("cannot queue file write"));
                }
            }
            queue_close(runtime, request, file, request.flush);
        }
    }
    finish(runtime, opened.request);
}

fn handle_outcome(runtime: &mut AsyncRuntime, outcome: &SDL_AsyncIOOutcome) {
    let pointer = outcome.userdata as usize;
    if pointer == 0 || !runtime.active.contains(&pointer) {
        return;
    }
    let request = unsafe { &mut *(pointer as *mut TecsAsyncFileRequest) };
    if outcome.result == SDL_AsyncIOResult::FAILURE && request.failure.is_none() {
        request.failure = Some(sdl_error("asynchronous file transfer failed"));
    } else if outcome.result == SDL_AsyncIOResult::CANCELED {
        request.canceled = true;
    } else if outcome.r#type == SDL_AsyncIOTaskType::READ {
        let transferred = usize::try_from(outcome.bytes_transferred).unwrap_or(usize::MAX);
        if transferred > request.capacity {
            request.failure = Some(cstring("SDL reported a file read past its destination"));
        } else {
            request.length = transferred;
        }
    } else if outcome.r#type == SDL_AsyncIOTaskType::WRITE
        && outcome.bytes_transferred != outcome.bytes_requested
        && request.failure.is_none()
    {
        request.failure = Some(cstring("asynchronous file write was incomplete"));
    }
    request.outcomes = request.outcomes.saturating_sub(1);
    finish(runtime, pointer);
}

fn drain_open(runtime: &mut AsyncRuntime) -> u32 {
    let receiver = lane()
        .receiver
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let mut count = 0;
    while let Ok(opened) = receiver.try_recv() {
        handle_open(runtime, opened);
        count += 1;
    }
    count
}

fn poll(runtime: &mut AsyncRuntime) -> u32 {
    let mut count = drain_open(runtime);
    if runtime.queue.is_null() {
        return count;
    }
    let mut outcome = SDL_AsyncIOOutcome::default();
    while unsafe { SDL_GetAsyncIOResult(runtime.queue, &mut outcome) } {
        handle_outcome(runtime, &outcome);
        count += 1;
        outcome = SDL_AsyncIOOutcome::default();
    }
    count
}

unsafe fn start(
    path_pointer: *const u8,
    path_length: usize,
    kind: Kind,
    bytes: &[u8],
) -> *mut TecsAsyncFileRequest {
    let path = match unsafe { path(path_pointer, path_length) } {
        Ok(path) => path,
        Err(error) => {
            set_error(error.to_string_lossy());
            return ptr::null_mut();
        }
    };
    if matches!(kind, Kind::Write) && bytes.len() > MAX_REQUEST_BYTES {
        set_error("asynchronous file request exceeds 268435456 bytes");
        return ptr::null_mut();
    }
    // Write storage is borrowed until SDL reports both the transfer and close
    // outcomes. The Lua adapter retains an immutable string or private
    // ByteView for exactly that lifetime. Reads allocate native-owned output.
    let data = if matches!(kind, Kind::Write) {
        bytes.as_ptr().cast_mut()
    } else {
        ptr::null_mut()
    };
    let mut request = Box::new(TecsAsyncFileRequest {
        kind,
        status: STATUS_PENDING,
        outcomes: 0,
        failure: None,
        canceled: false,
        abandoned: false,
        data,
        length: bytes.len(),
        capacity: bytes.len(),
        owned: None,
        accounted: if matches!(kind, Kind::Write) {
            bytes.len()
        } else {
            0
        },
        flush: false,
    });
    let pointer = (&mut *request) as *mut TecsAsyncFileRequest;
    let accepted = ASYNC.with(|slot| {
        let mut runtime = slot.borrow_mut();
        if runtime.requests >= MAX_REQUESTS
            || runtime.bytes.saturating_add(request.accounted) > MAX_BYTES
        {
            return Err("asynchronous file queue capacity exceeded");
        }
        match lane().sender.try_send(OpenJob::Open {
            request: pointer as usize,
            path,
            kind,
        }) {
            Ok(()) => {
                runtime.requests += 1;
                runtime.bytes += request.accounted;
                runtime.opening += 1;
                runtime.active.insert(pointer as usize);
                Ok(())
            }
            Err(TrySendError::Full(_)) => Err("file-open lane is full"),
            Err(TrySendError::Disconnected(_)) => Err("file-open lane is unavailable"),
        }
    });
    if let Err(error) = accepted {
        set_error(error);
        return ptr::null_mut();
    }
    Box::into_raw(request)
}

#[no_mangle]
pub unsafe extern "C" fn tecsAsyncFileRead(
    path: *const u8,
    path_length: usize,
) -> *mut TecsAsyncFileRequest {
    unsafe { start(path, path_length, Kind::Read, &[]) }
}

#[no_mangle]
pub unsafe extern "C" fn tecsAsyncFileWrite(
    path: *const u8,
    path_length: usize,
    bytes: *const u8,
    length: usize,
    flush: i32,
) -> *mut TecsAsyncFileRequest {
    if bytes.is_null() && length != 0 {
        set_error("file write bytes are null");
        return ptr::null_mut();
    }
    let bytes = if length == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(bytes, length) }
    };
    let request = unsafe { start(path, path_length, Kind::Write, bytes) };
    if let Some(request) = unsafe { request.as_mut() } {
        request.flush = flush != 0;
    }
    request
}

#[no_mangle]
pub extern "C" fn tecsAsyncFilePoll() -> u32 {
    ASYNC.with(|slot| poll(&mut slot.borrow_mut()))
}

#[no_mangle]
pub extern "C" fn tecsAsyncFileWait(wait_ms: u32) -> u32 {
    let deadline = Instant::now() + Duration::from_millis(wait_ms as u64);
    let mut total = 0;
    loop {
        total += tecsAsyncFilePoll();
        if total != 0 || Instant::now() >= deadline {
            return total;
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        let slice = remaining.min(Duration::from_millis(5));
        let waited = ASYNC.with(|slot| {
            let mut runtime = slot.borrow_mut();
            if runtime.queue.is_null() {
                false
            } else {
                let mut outcome = SDL_AsyncIOOutcome::default();
                if unsafe {
                    SDL_WaitAsyncIOResult(runtime.queue, &mut outcome, slice.as_millis() as i32)
                } {
                    handle_outcome(&mut runtime, &outcome);
                    true
                } else {
                    false
                }
            }
        });
        if waited {
            total += 1;
        } else if slice.is_zero() {
            return total;
        } else {
            thread::sleep(slice.min(Duration::from_millis(1)));
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsAsyncFileStatus(request: *const TecsAsyncFileRequest) -> i32 {
    unsafe { request.as_ref() }.map_or(STATUS_FAILED, |request| request.status)
}

#[no_mangle]
pub unsafe extern "C" fn tecsAsyncFileData(request: *const TecsAsyncFileRequest) -> *const u8 {
    unsafe { request.as_ref() }.map_or(ptr::null(), |request| request.data.cast_const())
}

#[no_mangle]
pub unsafe extern "C" fn tecsAsyncFileLength(request: *const TecsAsyncFileRequest) -> usize {
    unsafe { request.as_ref() }.map_or(0, |request| request.length)
}

#[no_mangle]
pub unsafe extern "C" fn tecsAsyncFileError(request: *const TecsAsyncFileRequest) -> *const c_char {
    unsafe { request.as_ref() }
        .and_then(|request| request.failure.as_ref())
        .map_or(c"asynchronous file request failed".as_ptr(), |error| {
            error.as_ptr()
        })
}

#[no_mangle]
pub unsafe extern "C" fn tecsAsyncFileTakeBytes(
    request: *mut TecsAsyncFileRequest,
) -> *mut TecsBytes {
    let Some(request_ref) = (unsafe { request.as_mut() }) else {
        set_error("asynchronous file request is null");
        return ptr::null_mut();
    };
    if request_ref.status != STATUS_READY || !matches!(request_ref.kind, Kind::Read) {
        set_error("asynchronous file read is not ready");
        return ptr::null_mut();
    }
    let bytes = request_ref.owned.take().unwrap_or_else(|| Box::new([]));
    request_ref.data = ptr::null_mut();
    request_ref.length = 0;
    unsafe { destroy_now(request) };
    Box::into_raw(Box::new(TecsBytes { bytes }))
}

unsafe fn destroy_now(request: *mut TecsAsyncFileRequest) {
    if !request.is_null() {
        drop(unsafe { Box::from_raw(request) });
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsAsyncFileDestroy(request: *mut TecsAsyncFileRequest) {
    let Some(request_ref) = (unsafe { request.as_mut() }) else {
        return;
    };
    if request_ref.status == STATUS_PENDING {
        request_ref.abandoned = true;
    } else {
        unsafe { destroy_now(request) };
    }
}

#[no_mangle]
pub extern "C" fn tecsAsyncFileShutdown() {
    loop {
        let opening = ASYNC.with(|slot| slot.borrow().opening);
        if opening == 0 {
            break;
        }
        tecsAsyncFileWait(5);
    }
    ASYNC.with(|slot| {
        let mut runtime = slot.borrow_mut();
        if !runtime.queue.is_null() {
            unsafe { SDL_DestroyAsyncIOQueue(runtime.queue) };
            runtime.queue = ptr::null_mut();
        }
        let active: Vec<usize> = runtime.active.drain().collect();
        for pointer in active {
            let request = unsafe { &mut *(pointer as *mut TecsAsyncFileRequest) };
            request.status = STATUS_CANCELED;
            request.canceled = true;
            request.outcomes = 0;
        }
        runtime.requests = 0;
        runtime.bytes = 0;
        runtime.opening = 0;
    });
}
