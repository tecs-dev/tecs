//! Runs asynchronous HTTP transfers through Reqwest and a bounded event queue.
//!
//! `tecs.io.http` calls this through the generated `http` FFI table; its Teal
//! client drains chunks and completions on the SDL thread.

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{c_char, CString};
use std::path::PathBuf;
use std::ptr;
use std::slice;
use std::str;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::Duration;

use bytes::Bytes;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use reqwest::{Body, Client, Method, Proxy, Url};
use tokio::runtime::{Builder, Runtime};
use tokio::sync::{mpsc, Semaphore};
use tokio::task::AbortHandle;
use tokio_stream::wrappers::ReceiverStream;
use tokio_util::io::ReaderStream;

const EVENT_QUEUE_CAPACITY: usize = 64;
const UPLOAD_QUEUE_CAPACITY: usize = 2;
const UPLOAD_CHUNK_BYTES: usize = 512 * 1024;
const RESPONSE_CHUNK_BYTES: usize = 64 * 1024;
const MAX_HEADER_BYTES: usize = 256 * 1024;

const EVENT_HEADERS: u32 = 1;
const EVENT_CHUNK: u32 = 2;
const EVENT_COMPLETE: u32 = 3;
const EVENT_FAILED: u32 = 4;
const BODY_NONE: u32 = 0;
const BODY_INLINE: u32 = 1;
const BODY_UPLOAD: u32 = 2;
const BODY_FILE: u32 = 3;
const UPLOAD_CLOSED: i32 = -1;
const UPLOAD_BACKPRESSURE: i32 = 0;
const UPLOAD_ACCEPTED: i32 = 1;

type UploadItem = Result<Bytes, std::io::Error>;
type UploadSender = mpsc::Sender<UploadItem>;

thread_local! {
    static LAST_HTTP_ERROR: RefCell<CString> =
        RefCell::new(CString::new("no error").expect("static string has no NUL"));
}

static RUNTIME: OnceLock<Result<Runtime, String>> = OnceLock::new();
static TLS_PROVIDER: OnceLock<()> = OnceLock::new();

fn install_tls_provider() {
    TLS_PROVIDER.get_or_init(|| {
        // `rustls-no-provider` keeps Reqwest from choosing a crypto backend
        // behind the build's back. This crate chooses ring explicitly; an
        // error only means another linked Rust component installed a provider
        // first, in which case Rustls is already ready.
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TecsHttpSlice {
    data: *const u8,
    length: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TecsHttpHeader {
    name: TecsHttpSlice,
    value: TecsHttpSlice,
}

#[repr(C)]
pub struct TecsHttpClientOptions {
    connect_timeout_ms: u64,
    max_redirects: u32,
    max_connections: u32,
    max_connections_per_host: u32,
    compressed: i32,
    proxy_mode: i32,
    proxy: TecsHttpSlice,
    no_proxy_set: i32,
    no_proxy: TecsHttpSlice,
    proxy_credentials: TecsHttpSlice,
}

#[repr(C)]
pub struct TecsHttpRequest {
    id: u64,
    url: TecsHttpSlice,
    method: TecsHttpSlice,
    headers: *const TecsHttpHeader,
    header_count: usize,
    body: TecsHttpSlice,
    body_kind: u32,
    body_length: i64,
    timeout_ms: u64,
    stall_timeout_ms: u64,
    max_bytes: u64,
    insecure: i32,
}

enum Event {
    Headers {
        id: u64,
        status: u16,
        headers: Box<[u8]>,
        url: Box<[u8]>,
    },
    Chunk {
        id: u64,
        data: Bytes,
    },
    Complete {
        id: u64,
    },
    Failed {
        id: u64,
        error: Box<[u8]>,
    },
}

pub struct TecsHttpEvent {
    event: Event,
}

struct Activity {
    generation: Mutex<u64>,
    changed: Condvar,
}

impl Activity {
    fn notify(&self) {
        let mut generation = self.generation.lock().unwrap_or_else(|e| e.into_inner());
        *generation = generation.wrapping_add(1);
        self.changed.notify_one();
    }
}

struct Shared {
    sender: mpsc::Sender<Event>,
    activity: Activity,
    closed: AtomicBool,
    total: Arc<Semaphore>,
    per_host_limit: usize,
    per_host: Mutex<HashMap<String, Arc<Semaphore>>>,
    uploads: Mutex<HashMap<u64, UploadSender>>,
}

impl Shared {
    async fn send(&self, event: Event) -> bool {
        if self.closed.load(Ordering::Acquire) {
            return false;
        }
        if self.sender.send(event).await.is_err() {
            return false;
        }
        self.activity.notify();
        true
    }

    fn host_semaphore(&self, host: &str) -> Arc<Semaphore> {
        let mut semaphores = self.per_host.lock().unwrap_or_else(|e| e.into_inner());
        semaphores
            .entry(host.to_owned())
            .or_insert_with(|| Arc::new(Semaphore::new(self.per_host_limit)))
            .clone()
    }
}

pub struct TecsHttpClient {
    secure: Client,
    insecure: Client,
    shared: Arc<Shared>,
    receiver: Mutex<mpsc::Receiver<Event>>,
    handles: Mutex<HashMap<u64, AbortHandle>>,
}

struct OwnedRequest {
    id: u64,
    url: Url,
    method: Method,
    headers: HeaderMap,
    body: Option<OwnedBody>,
    timeout: Duration,
    stall_timeout: Option<Duration>,
    max_bytes: u64,
    insecure: bool,
}

enum OwnedBody {
    Ready(Body),
    File(PathBuf),
}

struct UploadGuard {
    shared: Arc<Shared>,
    id: u64,
}

impl Drop for UploadGuard {
    fn drop(&mut self) {
        self.shared
            .uploads
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .remove(&self.id);
    }
}

fn set_error(error: impl ToString) {
    let message = error.to_string().replace('\0', "\\0");
    LAST_HTTP_ERROR.with(|slot| {
        *slot.borrow_mut() = CString::new(message).expect("interior NUL bytes were replaced");
    });
}

fn runtime() -> Result<&'static Runtime, &'static str> {
    match RUNTIME.get_or_init(|| {
        Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("tecs-http")
            .build()
            .map_err(|error| error.to_string())
    }) {
        Ok(runtime) => Ok(runtime),
        Err(error) => Err(error.as_str()),
    }
}

unsafe fn bytes<'a>(value: TecsHttpSlice) -> Result<&'a [u8], &'static str> {
    if value.data.is_null() {
        if value.length == 0 {
            return Ok(&[]);
        }
        return Err("a non-empty byte slice has a null pointer");
    }
    // SAFETY: Every public caller promises that non-empty slices remain
    // readable for the duration of the synchronous boundary call.
    Ok(unsafe { slice::from_raw_parts(value.data, value.length) })
}

unsafe fn text(value: TecsHttpSlice, what: &str) -> Result<String, String> {
    // SAFETY: Propagates the boundary's slice validity contract.
    let value = unsafe { bytes(value) }.map_err(str::to_owned)?;
    str::from_utf8(value)
        .map(str::to_owned)
        .map_err(|_| format!("{what} is not UTF-8"))
}

fn header_bytes(headers: &HeaderMap) -> Result<Box<[u8]>, String> {
    let mut encoded = Vec::new();
    for (name, value) in headers {
        let value = value.as_bytes();
        let required = name
            .as_str()
            .len()
            .checked_add(value.len())
            .and_then(|length| length.checked_add(4))
            .and_then(|length| encoded.len().checked_add(length))
            .ok_or_else(|| "response headers are too large".to_owned())?;
        if required > MAX_HEADER_BYTES {
            return Err("response headers exceeded 262144 bytes".to_owned());
        }
        encoded.extend_from_slice(name.as_str().as_bytes());
        encoded.extend_from_slice(b": ");
        encoded.extend_from_slice(value);
        encoded.extend_from_slice(b"\r\n");
    }
    Ok(encoded.into_boxed_slice())
}

fn proxy_with_options(
    mut proxy: Proxy,
    credentials: &str,
    no_proxy: Option<reqwest::NoProxy>,
) -> Proxy {
    if !credentials.is_empty() {
        let (user, password) = credentials.split_once(':').unwrap_or((credentials, ""));
        proxy = proxy.basic_auth(user, password);
    }
    proxy.no_proxy(no_proxy)
}

fn environment_proxy(lower: &str, upper: &str) -> Option<String> {
    std::env::var(lower)
        .or_else(|_| std::env::var(upper))
        .ok()
        .filter(|value| !value.is_empty())
}

fn client_builder(options: &TecsHttpClientOptions, insecure: bool) -> Result<Client, String> {
    let mut builder = Client::builder()
        .connect_timeout(Duration::from_millis(options.connect_timeout_ms))
        .pool_max_idle_per_host(options.max_connections_per_host as usize)
        .danger_accept_invalid_certs(insecure);
    builder = if options.max_redirects == 0 {
        builder.redirect(reqwest::redirect::Policy::none())
    } else {
        builder.redirect(reqwest::redirect::Policy::limited(
            options.max_redirects as usize,
        ))
    };

    if options.compressed == 0 {
        builder = builder.no_deflate().no_gzip();
    }

    // SAFETY: The options and their slices are borrowed only for this call.
    let proxy = unsafe { text(options.proxy, "proxy") }?;
    // SAFETY: See above.
    let no_proxy = unsafe { text(options.no_proxy, "noProxy") }?;
    // SAFETY: See above.
    let credentials = unsafe { text(options.proxy_credentials, "proxy credentials") }?;
    let no_proxy = if options.no_proxy_set != 0 {
        reqwest::NoProxy::from_string(&no_proxy)
    } else {
        reqwest::NoProxy::from_env()
    };

    if options.proxy_mode == 1 {
        builder = builder.no_proxy();
    } else if options.proxy_mode == 2 {
        let configured = Proxy::all(&proxy).map_err(|error| error.to_string())?;
        let configured = proxy_with_options(configured, &credentials, no_proxy);
        builder = builder.proxy(configured);
    } else if options.proxy_mode == 0 {
        let http = environment_proxy("http_proxy", "HTTP_PROXY");
        let https = environment_proxy("https_proxy", "HTTPS_PROXY");
        let all = environment_proxy("all_proxy", "ALL_PROXY");
        let has_environment_proxy = http.is_some() || https.is_some() || all.is_some();
        if let Some(proxy) = http {
            let configured = Proxy::http(&proxy).map_err(|error| error.to_string())?;
            builder = builder.proxy(proxy_with_options(
                configured,
                &credentials,
                no_proxy.clone(),
            ));
        }
        if let Some(proxy) = https {
            let configured = Proxy::https(&proxy).map_err(|error| error.to_string())?;
            builder = builder.proxy(proxy_with_options(
                configured,
                &credentials,
                no_proxy.clone(),
            ));
        }
        if let Some(proxy) = all {
            let configured = Proxy::all(&proxy).map_err(|error| error.to_string())?;
            builder = builder.proxy(proxy_with_options(
                configured,
                &credentials,
                no_proxy.clone(),
            ));
        }
        if !has_environment_proxy {
            builder = builder.no_proxy();
        }
    } else if options.proxy_mode != 0 {
        return Err("proxy mode is not valid".to_owned());
    }

    builder.build().map_err(|error| error.to_string())
}

unsafe fn own_request(
    request: &TecsHttpRequest,
    shared: &Arc<Shared>,
) -> Result<OwnedRequest, String> {
    // SAFETY: The request's slices are borrowed only while they are copied.
    let url = unsafe { text(request.url, "request URL") }?;
    let url = Url::parse(&url).map_err(|error| error.to_string())?;
    // SAFETY: See above.
    let method = unsafe { text(request.method, "request method") }?;
    let method = Method::from_bytes(method.as_bytes()).map_err(|error| error.to_string())?;

    let raw_headers = if request.headers.is_null() {
        if request.header_count == 0 {
            &[][..]
        } else {
            return Err("non-empty request headers have a null pointer".to_owned());
        }
    } else {
        // SAFETY: The caller promises this array is readable for this call.
        unsafe { slice::from_raw_parts(request.headers, request.header_count) }
    };
    let mut headers = HeaderMap::with_capacity(raw_headers.len());
    for raw in raw_headers {
        // SAFETY: Each nested slice has the same synchronous lifetime.
        let name = unsafe { bytes(raw.name) }.map_err(str::to_owned)?;
        // SAFETY: See above.
        let value = unsafe { bytes(raw.value) }.map_err(str::to_owned)?;
        let name = HeaderName::from_bytes(name).map_err(|error| error.to_string())?;
        let value = HeaderValue::from_bytes(value).map_err(|error| error.to_string())?;
        headers.insert(name, value);
    }

    let body = match request.body_kind {
        BODY_NONE => None,
        BODY_INLINE => {
            // SAFETY: The bytes are copied before this call returns.
            let copied =
                Bytes::copy_from_slice(unsafe { bytes(request.body) }.map_err(str::to_owned)?);
            Some(OwnedBody::Ready(Body::from(copied)))
        }
        BODY_UPLOAD => {
            if request.body_length < -1 {
                return Err("request body length must be -1 or non-negative".to_owned());
            }
            if request.body_length >= 0 && !headers.contains_key(reqwest::header::CONTENT_LENGTH) {
                let length = HeaderValue::from_str(&request.body_length.to_string())
                    .map_err(|error| error.to_string())?;
                headers.insert(reqwest::header::CONTENT_LENGTH, length);
            }
            let (sender, receiver) = mpsc::channel::<UploadItem>(UPLOAD_QUEUE_CAPACITY);
            let replaced = shared
                .uploads
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .insert(request.id, sender);
            if replaced.is_some() {
                return Err("request id already has an upload body".to_owned());
            }
            Some(OwnedBody::Ready(Body::wrap_stream(ReceiverStream::new(
                receiver,
            ))))
        }
        BODY_FILE => {
            if request.body_length < 0 {
                return Err("file request body length must be non-negative".to_owned());
            }
            if !headers.contains_key(reqwest::header::CONTENT_LENGTH) {
                let length = HeaderValue::from_str(&request.body_length.to_string())
                    .map_err(|error| error.to_string())?;
                headers.insert(reqwest::header::CONTENT_LENGTH, length);
            }
            // SAFETY: The path is copied before this boundary returns.
            let path = unsafe { text(request.body, "request body file path") }?;
            if path.is_empty() {
                return Err("request body file path is empty".to_owned());
            }
            Some(OwnedBody::File(PathBuf::from(path)))
        }
        _ => return Err("request body kind is not valid".to_owned()),
    };

    Ok(OwnedRequest {
        id: request.id,
        url,
        method,
        headers,
        body,
        timeout: Duration::from_millis(request.timeout_ms),
        stall_timeout: (request.stall_timeout_ms != 0)
            .then(|| Duration::from_millis(request.stall_timeout_ms)),
        max_bytes: request.max_bytes,
        insecure: request.insecure != 0,
    })
}

async fn fail(shared: &Shared, id: u64, url: &Url, reason: impl ToString) {
    let message = format!("tecs: {url}: {}", reason.to_string());
    let _ = shared
        .send(Event::Failed {
            id,
            error: message.into_bytes().into_boxed_slice(),
        })
        .await;
}

async fn perform(client: Client, shared: Arc<Shared>, request: OwnedRequest) {
    let id = request.id;
    let _upload_guard = UploadGuard {
        shared: shared.clone(),
        id,
    };
    let url = request.url.clone();
    let host = request.url.host_str().unwrap_or("").to_owned();
    let total_permit = match shared.total.clone().acquire_owned().await {
        Ok(permit) => permit,
        Err(error) => {
            fail(&shared, id, &url, error).await;
            return;
        }
    };
    let host_permit = match shared.host_semaphore(&host).acquire_owned().await {
        Ok(permit) => permit,
        Err(error) => {
            fail(&shared, id, &url, error).await;
            return;
        }
    };

    let mut builder = client
        .request(request.method, request.url)
        .headers(request.headers)
        .timeout(request.timeout);
    if let Some(body) = request.body {
        match body {
            OwnedBody::Ready(body) => builder = builder.body(body),
            OwnedBody::File(path) => {
                let file = match tokio::fs::File::open(&path).await {
                    Ok(file) => file,
                    Err(error) => {
                        fail(
                            &shared,
                            id,
                            &url,
                            format!("cannot open request body {}: {error}", path.display()),
                        )
                        .await;
                        return;
                    }
                };
                builder = builder.body(Body::wrap_stream(ReaderStream::with_capacity(
                    file,
                    UPLOAD_CHUNK_BYTES,
                )));
            }
        }
    }

    let response = match builder.send().await {
        Ok(response) => response,
        Err(error) => {
            fail(&shared, id, &url, error).await;
            return;
        }
    };
    let status = response.status().as_u16();
    let effective_url = response
        .url()
        .as_str()
        .as_bytes()
        .to_vec()
        .into_boxed_slice();
    let headers = match header_bytes(response.headers()) {
        Ok(headers) => headers,
        Err(error) => {
            fail(&shared, id, &url, error).await;
            return;
        }
    };

    if request.max_bytes != 0
        && response
            .content_length()
            .is_some_and(|length| length > request.max_bytes)
    {
        fail(
            &shared,
            id,
            &url,
            format!("response body exceeded {} bytes", request.max_bytes),
        )
        .await;
        return;
    }

    if !shared
        .send(Event::Headers {
            id,
            status,
            headers,
            url: effective_url,
        })
        .await
    {
        return;
    }

    let mut response = response;
    let mut received = 0_u64;
    loop {
        let next = if let Some(stall_timeout) = request.stall_timeout {
            match tokio::time::timeout(stall_timeout, response.chunk()).await {
                Ok(result) => result,
                Err(_) => {
                    fail(
                        &shared,
                        id,
                        &url,
                        format!(
                            "response made no progress for {} milliseconds",
                            stall_timeout.as_millis()
                        ),
                    )
                    .await;
                    return;
                }
            }
        } else {
            response.chunk().await
        };
        let chunk = match next {
            Ok(Some(chunk)) => chunk,
            Ok(None) => break,
            Err(error) => {
                fail(&shared, id, &url, error).await;
                return;
            }
        };
        received = match received.checked_add(chunk.len() as u64) {
            Some(received) => received,
            None => {
                fail(&shared, id, &url, "response body is too large").await;
                return;
            }
        };
        if request.max_bytes != 0 && received > request.max_bytes {
            fail(
                &shared,
                id,
                &url,
                format!("response body exceeded {} bytes", request.max_bytes),
            )
            .await;
            return;
        }
        for start in (0..chunk.len()).step_by(RESPONSE_CHUNK_BYTES) {
            let end = (start + RESPONSE_CHUNK_BYTES).min(chunk.len());
            if !shared
                .send(Event::Chunk {
                    id,
                    data: chunk.slice(start..end),
                })
                .await
            {
                return;
            }
        }
    }

    let _ = shared.send(Event::Complete { id }).await;

    drop(host_permit);
    drop(total_permit);
}

fn event_data(bytes: &[u8], length: *mut usize) -> *const u8 {
    if !length.is_null() {
        // SAFETY: The caller supplied writable storage for one size value.
        unsafe {
            *length = bytes.len();
        }
    }
    bytes.as_ptr()
}

/// Returns the last synchronous HTTP boundary error.
#[no_mangle]
pub extern "C" fn tecsHttpError() -> *const c_char {
    LAST_HTTP_ERROR.with(|slot| slot.borrow().as_ptr())
}

/// Creates a reqwest connection pool and its bounded completion queue.
///
/// # Safety
///
/// `options` must be null or point to a readable options value whose nested
/// slices remain readable for this call.
#[no_mangle]
pub unsafe extern "C" fn tecsHttpClientCreate(
    options: *const TecsHttpClientOptions,
) -> *mut TecsHttpClient {
    if options.is_null() {
        set_error("HTTP client options are null");
        return ptr::null_mut();
    }
    if let Err(error) = runtime() {
        set_error(error);
        return ptr::null_mut();
    }
    install_tls_provider();
    // SAFETY: Null was rejected and the caller promises a readable value.
    let options = unsafe { &*options };
    if options.max_connections == 0 || options.max_connections_per_host == 0 {
        set_error("HTTP connection limits must be greater than zero");
        return ptr::null_mut();
    }
    if options.max_connections as usize > Semaphore::MAX_PERMITS
        || options.max_connections_per_host as usize > Semaphore::MAX_PERMITS
    {
        set_error("HTTP connection limits are too large");
        return ptr::null_mut();
    }
    let secure = match client_builder(options, false) {
        Ok(client) => client,
        Err(error) => {
            set_error(error);
            return ptr::null_mut();
        }
    };
    let insecure = match client_builder(options, true) {
        Ok(client) => client,
        Err(error) => {
            set_error(error);
            return ptr::null_mut();
        }
    };
    let (sender, receiver) = mpsc::channel(EVENT_QUEUE_CAPACITY);
    let shared = Arc::new(Shared {
        sender,
        activity: Activity {
            generation: Mutex::new(0),
            changed: Condvar::new(),
        },
        closed: AtomicBool::new(false),
        total: Arc::new(Semaphore::new(options.max_connections as usize)),
        per_host_limit: options.max_connections_per_host as usize,
        per_host: Mutex::new(HashMap::new()),
        uploads: Mutex::new(HashMap::new()),
    });
    Box::into_raw(Box::new(TecsHttpClient {
        secure,
        insecure,
        shared,
        receiver: Mutex::new(receiver),
        handles: Mutex::new(HashMap::new()),
    }))
}

/// Releases a client and aborts all its requests.
///
/// # Safety
///
/// `client` must be null or an owned pointer returned by
/// `tecsHttpClientCreate`, destroyed exactly once.
#[no_mangle]
pub unsafe extern "C" fn tecsHttpClientDestroy(client: *mut TecsHttpClient) {
    if client.is_null() {
        return;
    }
    // SAFETY: Ownership crosses this boundary once.
    let client = unsafe { Box::from_raw(client) };
    client.shared.closed.store(true, Ordering::Release);
    let mut handles = client.handles.lock().unwrap_or_else(|e| e.into_inner());
    client
        .shared
        .uploads
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();
    for (_, handle) in handles.drain() {
        handle.abort();
    }
}

/// Copies and schedules one request.
///
/// # Safety
///
/// Both pointers must identify live values for this call, and every slice in
/// `request` must satisfy `TecsHttpSlice`'s readable-memory contract.
#[no_mangle]
pub unsafe extern "C" fn tecsHttpClientSend(
    client: *mut TecsHttpClient,
    request: *const TecsHttpRequest,
) -> i32 {
    if client.is_null() || request.is_null() {
        set_error("HTTP send needs a client and request");
        return 0;
    }
    // SAFETY: Null was rejected and the caller promises live pointers.
    let client = unsafe { &*client };
    if client.shared.closed.load(Ordering::Acquire) {
        set_error("HTTP client is closed");
        return 0;
    }
    // SAFETY: The request is copied synchronously.
    let request = match unsafe { own_request(&*request, &client.shared) } {
        Ok(request) => request,
        Err(error) => {
            set_error(error);
            return 0;
        }
    };
    let id = request.id;
    let http = if request.insecure {
        client.insecure.clone()
    } else {
        client.secure.clone()
    };
    let shared = client.shared.clone();
    let handle = match runtime() {
        Ok(runtime) => runtime.spawn(perform(http, shared, request)),
        Err(error) => {
            set_error(error);
            return 0;
        }
    };
    client
        .handles
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(id, handle.abort_handle());
    1
}

/// Aborts one request.
///
/// # Safety
///
/// `client` must be null or a live client pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsHttpClientCancel(client: *mut TecsHttpClient, id: u64) {
    if client.is_null() {
        return;
    }
    // SAFETY: A non-null pointer must be a live client.
    let client = unsafe { &*client };
    client
        .shared
        .uploads
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .remove(&id);
    if let Some(handle) = client
        .handles
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&id)
    {
        handle.abort();
    }
}

/// Offers one request-body chunk to the bounded upload channel.
///
/// # Safety
///
/// `client` must be null or a live client pointer. A non-empty `data` range
/// must remain readable for this call. Rust copies accepted bytes before
/// returning.
#[no_mangle]
pub unsafe extern "C" fn tecsHttpClientUpload(
    client: *mut TecsHttpClient,
    id: u64,
    data: *const u8,
    length: usize,
    finished: i32,
) -> i32 {
    if client.is_null() {
        set_error("HTTP upload needs a client");
        return UPLOAD_CLOSED;
    }
    if finished != 0 && length != 0 {
        set_error("HTTP upload finish needs an empty byte slice");
        return UPLOAD_CLOSED;
    }
    if length > UPLOAD_CHUNK_BYTES {
        set_error("HTTP upload chunks cannot exceed 524288 bytes");
        return UPLOAD_CLOSED;
    }
    // SAFETY: Null was rejected and the caller promises a live client.
    let client = unsafe { &*client };
    let mut uploads = client
        .shared
        .uploads
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    if finished != 0 {
        return if uploads.remove(&id).is_some() {
            UPLOAD_ACCEPTED
        } else {
            UPLOAD_CLOSED
        };
    }
    let Some(sender) = uploads.get(&id) else {
        return UPLOAD_CLOSED;
    };
    let permit = match sender.try_reserve() {
        Ok(permit) => permit,
        Err(mpsc::error::TrySendError::Full(_)) => return UPLOAD_BACKPRESSURE,
        Err(mpsc::error::TrySendError::Closed(_)) => return UPLOAD_CLOSED,
    };
    let source = TecsHttpSlice { data, length };
    // SAFETY: The boundary contract keeps this slice readable for the call.
    let source = match unsafe { bytes(source) } {
        Ok(source) => source,
        Err(error) => {
            set_error(error);
            return UPLOAD_CLOSED;
        }
    };
    permit.send(Ok(Bytes::copy_from_slice(source)));
    client.shared.activity.notify();
    UPLOAD_ACCEPTED
}

fn try_next(client: &TecsHttpClient) -> Option<Event> {
    let mut receiver = client.receiver.lock().unwrap_or_else(|e| e.into_inner());
    loop {
        let event = receiver.try_recv().ok()?;
        let id = match &event {
            Event::Headers { id, .. }
            | Event::Chunk { id, .. }
            | Event::Complete { id, .. }
            | Event::Failed { id, .. } => *id,
        };
        let canceled = !client
            .handles
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains_key(&id);
        if canceled {
            continue;
        }
        if matches!(event, Event::Complete { .. } | Event::Failed { .. }) {
            client
                .handles
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&id);
        }
        return Some(event);
    }
}

/// Drains one event, waiting for at most `wait_ms`.
///
/// # Safety
///
/// `client` must be null or a live client pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsHttpClientNext(
    client: *mut TecsHttpClient,
    wait_ms: u32,
) -> *mut TecsHttpEvent {
    if client.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: A non-null pointer must be a live client.
    let client = unsafe { &*client };
    if let Some(event) = try_next(client) {
        return Box::into_raw(Box::new(TecsHttpEvent { event }));
    }
    if wait_ms == 0 {
        return ptr::null_mut();
    }

    let generation = client
        .shared
        .activity
        .generation
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let before = *generation;
    if let Some(event) = try_next(client) {
        return Box::into_raw(Box::new(TecsHttpEvent { event }));
    }
    let _guard = client
        .shared
        .activity
        .changed
        .wait_timeout_while(
            generation,
            Duration::from_millis(wait_ms as u64),
            |current| *current == before && !client.shared.closed.load(Ordering::Acquire),
        )
        .unwrap_or_else(|e| e.into_inner());
    match try_next(client) {
        Some(event) => Box::into_raw(Box::new(TecsHttpEvent { event })),
        None => ptr::null_mut(),
    }
}

/// Returns an event's kind.
///
/// # Safety
///
/// `event` must be null or a live event pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsHttpEventKind(event: *const TecsHttpEvent) -> u32 {
    if event.is_null() {
        return 0;
    }
    // SAFETY: Null was rejected.
    match &unsafe { &*event }.event {
        Event::Headers { .. } => EVENT_HEADERS,
        Event::Chunk { .. } => EVENT_CHUNK,
        Event::Complete { .. } => EVENT_COMPLETE,
        Event::Failed { .. } => EVENT_FAILED,
    }
}

/// Returns an event's request id.
///
/// # Safety
///
/// `event` must be null or a live event pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsHttpEventId(event: *const TecsHttpEvent) -> u64 {
    if event.is_null() {
        return 0;
    }
    // SAFETY: Null was rejected.
    match &unsafe { &*event }.event {
        Event::Headers { id, .. }
        | Event::Chunk { id, .. }
        | Event::Complete { id, .. }
        | Event::Failed { id, .. } => *id,
    }
}

/// Returns a completion's HTTP status.
///
/// # Safety
///
/// `event` must be null or a live event pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsHttpEventStatus(event: *const TecsHttpEvent) -> u16 {
    if event.is_null() {
        return 0;
    }
    // SAFETY: Null was rejected.
    match &unsafe { &*event }.event {
        Event::Headers { status, .. } => *status,
        _ => 0,
    }
}

/// Borrows a chunk's bytes.
///
/// # Safety
///
/// `event` must be null or a live event pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsHttpEventData(
    event: *const TecsHttpEvent,
    length: *mut usize,
) -> *const u8 {
    if event.is_null() {
        return event_data(&[], length);
    }
    // SAFETY: Null was rejected.
    match &unsafe { &*event }.event {
        Event::Chunk { data, .. } => event_data(data, length),
        _ => event_data(&[], length),
    }
}

/// Borrows a completion's encoded final headers.
///
/// # Safety
///
/// `event` must be null or a live event pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsHttpEventHeaders(
    event: *const TecsHttpEvent,
    length: *mut usize,
) -> *const u8 {
    if event.is_null() {
        return event_data(&[], length);
    }
    // SAFETY: Null was rejected.
    match &unsafe { &*event }.event {
        Event::Headers { headers, .. } => event_data(headers, length),
        _ => event_data(&[], length),
    }
}

/// Borrows a completion's effective URL.
///
/// # Safety
///
/// `event` must be null or a live event pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsHttpEventUrl(
    event: *const TecsHttpEvent,
    length: *mut usize,
) -> *const u8 {
    if event.is_null() {
        return event_data(&[], length);
    }
    // SAFETY: Null was rejected.
    match &unsafe { &*event }.event {
        Event::Headers { url, .. } => event_data(url, length),
        _ => event_data(&[], length),
    }
}

/// Borrows a failure's reason.
///
/// # Safety
///
/// `event` must be null or a live event pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsHttpEventError(
    event: *const TecsHttpEvent,
    length: *mut usize,
) -> *const u8 {
    if event.is_null() {
        return event_data(&[], length);
    }
    // SAFETY: Null was rejected.
    match &unsafe { &*event }.event {
        Event::Failed { error, .. } => event_data(error, length),
        _ => event_data(&[], length),
    }
}

/// Releases an event.
///
/// # Safety
///
/// `event` must be null or an owned event pointer, destroyed exactly once.
#[no_mangle]
pub unsafe extern "C" fn tecsHttpEventDestroy(event: *mut TecsHttpEvent) {
    if !event.is_null() {
        // SAFETY: Ownership crosses this boundary once.
        drop(unsafe { Box::from_raw(event) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;

    #[test]
    fn rejects_headers_over_the_limit() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "x-large",
            HeaderValue::from_bytes(&vec![b'x'; MAX_HEADER_BYTES]).unwrap(),
        );
        assert!(header_bytes(&headers)
            .unwrap_err()
            .contains("response headers exceeded"));
    }

    #[test]
    fn encodes_headers_for_lua_without_a_callback() {
        let mut headers = HeaderMap::new();
        headers.insert("content-type", HeaderValue::from_static("text/plain"));
        let encoded = header_bytes(&headers).unwrap();
        assert_eq!(&*encoded, b"content-type: text/plain\r\n");
    }

    #[test]
    fn upload_queue_stays_bounded_before_copying() {
        // The production constructor installs this before it builds either
        // client. This test constructs the client directly to isolate queue
        // backpressure, so it must establish the same process invariant.
        install_tls_provider();
        let (event_sender, event_receiver) = mpsc::channel(EVENT_QUEUE_CAPACITY);
        let shared = Arc::new(Shared {
            sender: event_sender,
            activity: Activity {
                generation: Mutex::new(0),
                changed: Condvar::new(),
            },
            closed: AtomicBool::new(false),
            total: Arc::new(Semaphore::new(1)),
            per_host_limit: 1,
            per_host: Mutex::new(HashMap::new()),
            uploads: Mutex::new(HashMap::new()),
        });
        let (upload_sender, _upload_receiver) = mpsc::channel(UPLOAD_QUEUE_CAPACITY);
        shared.uploads.lock().unwrap().insert(7, upload_sender);

        let client = Box::into_raw(Box::new(TecsHttpClient {
            secure: Client::new(),
            insecure: Client::new(),
            shared,
            receiver: Mutex::new(event_receiver),
            handles: Mutex::new(HashMap::new()),
        }));
        let chunk = vec![b'x'; UPLOAD_CHUNK_BYTES];
        for _ in 0..UPLOAD_QUEUE_CAPACITY {
            // SAFETY: The client and source remain live for the synchronous copy.
            assert_eq!(
                unsafe { tecsHttpClientUpload(client, 7, chunk.as_ptr(), chunk.len(), 0) },
                UPLOAD_ACCEPTED
            );
        }
        // Two 512 KiB pieces are one MiB. The next offer encounters
        // backpressure before constructing a Bytes allocation.
        assert_eq!(UPLOAD_QUEUE_CAPACITY * UPLOAD_CHUNK_BYTES, 1024 * 1024);
        // SAFETY: The client and source still remain live.
        assert_eq!(
            unsafe { tecsHttpClientUpload(client, 7, chunk.as_ptr(), chunk.len(), 0) },
            UPLOAD_BACKPRESSURE
        );
        // SAFETY: Ownership is returned exactly once.
        unsafe { tecsHttpClientDestroy(client) };
    }

    #[test]
    fn owns_native_file_request_paths_without_an_upload_queue() {
        let (event_sender, _event_receiver) = mpsc::channel(EVENT_QUEUE_CAPACITY);
        let shared = Arc::new(Shared {
            sender: event_sender,
            activity: Activity {
                generation: Mutex::new(0),
                changed: Condvar::new(),
            },
            closed: AtomicBool::new(false),
            total: Arc::new(Semaphore::new(1)),
            per_host_limit: 1,
            per_host: Mutex::new(HashMap::new()),
            uploads: Mutex::new(HashMap::new()),
        });
        let url = b"http://127.0.0.1/upload";
        let method = b"POST";
        let path = b"/tmp/request-body.bin";
        let request = TecsHttpRequest {
            id: 9,
            url: TecsHttpSlice {
                data: url.as_ptr(),
                length: url.len(),
            },
            method: TecsHttpSlice {
                data: method.as_ptr(),
                length: method.len(),
            },
            headers: ptr::null(),
            header_count: 0,
            body: TecsHttpSlice {
                data: path.as_ptr(),
                length: path.len(),
            },
            body_kind: BODY_FILE,
            body_length: 17,
            timeout_ms: 1_000,
            stall_timeout_ms: 0,
            max_bytes: 0,
            insecure: 0,
        };

        // SAFETY: Every request slice remains live for this synchronous copy.
        let owned = unsafe { own_request(&request, &shared) }.unwrap();
        match owned.body {
            Some(OwnedBody::File(owned_path)) => {
                assert_eq!(owned_path, PathBuf::from("/tmp/request-body.bin"));
            }
            _ => panic!("file request did not retain its path"),
        }
        assert_eq!(owned.headers[reqwest::header::CONTENT_LENGTH], "17");
        assert!(shared.uploads.lock().unwrap().is_empty());
    }

    #[test]
    fn queues_chunks_and_completion_for_the_calling_thread() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut request = [0_u8; 4096];
            let read = socket.read(&mut request).unwrap();
            assert!(request[..read]
                .windows(4)
                .any(|window| window == b"\r\n\r\n"));
            socket
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\
                      Content-Length: 5\r\nConnection: close\r\n\r\nhello",
                )
                .unwrap();
        });

        let empty = TecsHttpSlice {
            data: ptr::null(),
            length: 0,
        };
        let options = TecsHttpClientOptions {
            connect_timeout_ms: 5_000,
            max_redirects: 5,
            max_connections: 4,
            max_connections_per_host: 2,
            compressed: 1,
            proxy_mode: 1,
            proxy: empty,
            no_proxy_set: 0,
            no_proxy: empty,
            proxy_credentials: empty,
        };
        // SAFETY: `options` and its empty slices remain live for the call.
        let client = unsafe { tecsHttpClientCreate(&options) };
        assert!(!client.is_null());

        let url = format!("http://{address}/spec");
        let method = b"GET";
        let request = TecsHttpRequest {
            id: 42,
            url: TecsHttpSlice {
                data: url.as_ptr(),
                length: url.len(),
            },
            method: TecsHttpSlice {
                data: method.as_ptr(),
                length: method.len(),
            },
            headers: ptr::null(),
            header_count: 0,
            body: empty,
            body_kind: BODY_NONE,
            body_length: -1,
            timeout_ms: 5_000,
            stall_timeout_ms: 0,
            max_bytes: 0,
            insecure: 0,
        };
        // SAFETY: The client and request remain live for the synchronous copy.
        assert_eq!(unsafe { tecsHttpClientSend(client, &request) }, 1);

        let mut body = Vec::new();
        let mut headers_event = None;
        let mut complete = false;
        for _ in 0..10 {
            // SAFETY: The client remains live until the end of the test.
            let event = unsafe { tecsHttpClientNext(client, 1_000) };
            if event.is_null() {
                continue;
            }
            // SAFETY: This event is live until it is destroyed below.
            match &unsafe { &*event }.event {
                Event::Headers {
                    id,
                    status,
                    headers,
                    url,
                } => {
                    headers_event = Some((*id, *status, headers.to_vec(), url.to_vec()));
                }
                Event::Chunk { id, data } => {
                    assert_eq!(*id, 42);
                    body.extend_from_slice(data);
                }
                Event::Complete { id } => {
                    assert_eq!(*id, 42);
                    complete = true;
                }
                Event::Failed { error, .. } => {
                    panic!("request failed: {}", String::from_utf8_lossy(error));
                }
            }
            // SAFETY: Ownership is returned exactly once.
            unsafe { tecsHttpEventDestroy(event) };
            if complete {
                break;
            }
        }

        // SAFETY: Ownership is returned exactly once, after all events used.
        unsafe { tecsHttpClientDestroy(client) };
        server.join().unwrap();

        assert_eq!(body, b"hello");
        assert!(complete);
        let (id, status, headers, effective_url) = headers_event.expect("headers event");
        assert_eq!(id, 42);
        assert_eq!(status, 200);
        assert!(headers
            .windows(b"content-type: text/plain".len())
            .any(|window| window == b"content-type: text/plain"));
        assert_eq!(effective_url, url.as_bytes());
    }
}
