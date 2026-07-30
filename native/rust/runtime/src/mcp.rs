//! Official RMCP Streamable HTTP server with an SDL-thread tool bridge.
//!
//! Tokio owns the listener, HTTP framing, MCP lifecycle, sessions, and
//! JSON-RPC. A bounded channel is the only route into LuaJIT: the SDL thread
//! drains calls and completes their one-shot response. Rust never calls Lua.
//! `tecs.io.mcp` reaches the server through its Teal `transport` module and the
//! generated Rust FFI table.

use std::ptr;
use std::slice;
use std::sync::{Arc, Mutex, OnceLock, RwLock};

use axum::Router;
use rmcp::model::{
    CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock, ErrorCode, ErrorData,
    Implementation, JsonObject, ListToolsResult, MetaObject, PaginatedRequestParams,
    ServerCapabilities, ServerInfo, Tool, ToolAnnotations,
};
use rmcp::service::RequestContext;
use rmcp::transport::streamable_http_server::{
    session::local::LocalSessionManager, StreamableHttpServerConfig, StreamableHttpService,
};
use rmcp::{RoleServer, ServerHandler};
use serde::Deserialize;
use serde_json::Value;
use tokio::runtime::{Builder, Runtime};
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;

use crate::set_error;

const CALL_QUEUE_CAPACITY: usize = 64;
const MAX_REQUEST_BODY_BYTES: usize = 4 * 1024 * 1024;

static RUNTIME: OnceLock<Result<Runtime, String>> = OnceLock::new();

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LuaTool {
    name: String,
    #[serde(default)]
    description: String,
    #[serde(default = "empty_schema")]
    input_schema: JsonObject,
    #[serde(default)]
    annotations: LuaAnnotations,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LuaAnnotations {
    #[serde(default)]
    read_only_hint: bool,
    #[serde(default)]
    destructive_hint: bool,
    #[serde(default)]
    when_crashed_hint: bool,
}

fn empty_schema() -> JsonObject {
    let mut schema = JsonObject::new();
    schema.insert("type".to_owned(), Value::String("object".to_owned()));
    schema
}

fn runtime() -> Result<&'static Runtime, &'static str> {
    match RUNTIME.get_or_init(|| {
        Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("tecs-mcp")
            .build()
            .map_err(|error| error.to_string())
    }) {
        Ok(runtime) => Ok(runtime),
        Err(error) => Err(error.as_str()),
    }
}

fn decode_tools(bytes: &[u8]) -> Result<Vec<Tool>, String> {
    let tools: Vec<LuaTool> =
        serde_json::from_slice(bytes).map_err(|error| format!("invalid MCP tool list: {error}"))?;
    Ok(tools
        .into_iter()
        .map(|source| {
            let mut meta = MetaObject::new();
            meta.insert(
                "whenCrashedHint".to_owned(),
                Value::Bool(source.annotations.when_crashed_hint),
            );
            Tool::new(source.name, source.description, source.input_schema)
                .with_annotations(
                    ToolAnnotations::new()
                        .read_only(source.annotations.read_only_hint)
                        .destructive(source.annotations.destructive_hint),
                )
                .with_meta(meta)
        })
        .collect())
}

struct PendingCall {
    name: Box<[u8]>,
    arguments: Box<[u8]>,
    response: oneshot::Sender<LuaResponse>,
}

enum LuaResponse {
    Success(Value),
    Error { message: String, crashed: bool },
}

struct Shared {
    tools: RwLock<Vec<Tool>>,
    calls: mpsc::Sender<PendingCall>,
}

#[derive(Clone)]
struct EngineServer {
    shared: Arc<Shared>,
}

impl ServerHandler for EngineServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("tecs", "0.1.0"))
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        let tools = self
            .shared
            .tools
            .read()
            .unwrap_or_else(|error| error.into_inner())
            .clone();
        Ok(ListToolsResult::with_all_items(tools))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        let known = self
            .shared
            .tools
            .read()
            .unwrap_or_else(|error| error.into_inner())
            .iter()
            .any(|tool| tool.name == request.name);
        if !known {
            return Err(ErrorData::new(
                ErrorCode::METHOD_NOT_FOUND,
                format!("no tool named '{}'", request.name),
                None,
            ));
        }

        let arguments = Value::Object(request.arguments.unwrap_or_default());
        let arguments = serde_json::to_vec(&arguments).map_err(|error| {
            ErrorData::internal_error(format!("cannot encode tool arguments: {error}"), None)
        })?;
        let (response, receive) = oneshot::channel();
        self.shared
            .calls
            .send(PendingCall {
                name: request.name.as_bytes().into(),
                arguments: arguments.into_boxed_slice(),
                response,
            })
            .await
            .map_err(|_| {
                ErrorData::internal_error("the game stopped accepting tool calls", None)
            })?;

        let result = receive.await.map_err(|_| {
            ErrorData::internal_error("the game stopped before answering the tool call", None)
        })?;
        Ok(match result {
            LuaResponse::Success(value) => CallToolResult::structured(value).into(),
            LuaResponse::Error { message, crashed } => {
                let mut result = CallToolResult::error(vec![ContentBlock::text(message)]);
                if crashed {
                    let mut meta = MetaObject::new();
                    meta.insert("crashed".to_owned(), Value::Bool(true));
                    result = result.with_meta(Some(meta));
                }
                result.into()
            }
        })
    }
}

/// A Rust-owned MCP server. Only the completed call receiver is touched by Lua.
pub struct TecsMcpServer {
    shared: Arc<Shared>,
    calls: Mutex<mpsc::Receiver<PendingCall>>,
    cancellation: CancellationToken,
}

/// One engine-facing tool invocation transferred to the SDL thread.
pub struct TecsMcpRequest {
    name: Box<[u8]>,
    arguments: Box<[u8]>,
    response: Option<oneshot::Sender<LuaResponse>>,
}

unsafe fn input<'a>(data: *const u8, length: usize) -> Result<&'a [u8], &'static str> {
    if data.is_null() {
        return if length == 0 {
            Ok(&[])
        } else {
            Err("a non-empty MCP input has a null pointer")
        };
    }
    // SAFETY: The caller keeps the bytes readable for this synchronous call.
    Ok(unsafe { slice::from_raw_parts(data, length) })
}

/// Starts a loopback-only Streamable HTTP MCP server.
///
/// # Safety
///
/// `tools` must be null for an empty input or readable for `tools_length`
/// bytes for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn tecsMcpServerCreate(
    port: u16,
    tools: *const u8,
    tools_length: usize,
) -> *mut TecsMcpServer {
    // SAFETY: Propagates this function's input validity contract.
    let tools = match unsafe { input(tools, tools_length) }
        .and_then(|bytes| decode_tools(bytes).map_err(|_| "the MCP tool list is not valid JSON"))
    {
        Ok(tools) => tools,
        Err(error) => {
            set_error(error);
            return ptr::null_mut();
        }
    };
    let runtime = match runtime() {
        Ok(runtime) => runtime,
        Err(error) => {
            set_error(error);
            return ptr::null_mut();
        }
    };

    let listener = match runtime.block_on(tokio::net::TcpListener::bind(("127.0.0.1", port))) {
        Ok(listener) => listener,
        Err(error) => {
            set_error(format!("cannot listen on port {port}: {error}"));
            return ptr::null_mut();
        }
    };
    let (send, receive) = mpsc::channel(CALL_QUEUE_CAPACITY);
    let shared = Arc::new(Shared {
        tools: RwLock::new(tools),
        calls: send,
    });
    let cancellation = CancellationToken::new();
    let config = StreamableHttpServerConfig::default()
        .with_json_response(true)
        .with_cancellation_token(cancellation.clone())
        .with_allowed_origins([
            format!("http://localhost:{port}"),
            format!("http://127.0.0.1:{port}"),
        ])
        .with_max_request_body_bytes(MAX_REQUEST_BODY_BYTES);
    let factory_shared = shared.clone();
    let service: StreamableHttpService<EngineServer, LocalSessionManager> =
        StreamableHttpService::new(
            move || {
                Ok(EngineServer {
                    shared: factory_shared.clone(),
                })
            },
            Default::default(),
            config,
        );
    let router = Router::new().nest_service("/mcp", service);
    let stop = cancellation.clone();
    runtime.spawn(async move {
        let _ = axum::serve(listener, router)
            .with_graceful_shutdown(stop.cancelled_owned())
            .await;
    });

    Box::into_raw(Box::new(TecsMcpServer {
        shared,
        calls: Mutex::new(receive),
        cancellation,
    }))
}

/// Replaces the dynamically registered tool list.
///
/// # Safety
///
/// `server` must be a live server pointer. `tools` follows the validity
/// contract of `tecsMcpServerCreate`.
#[no_mangle]
pub unsafe extern "C" fn tecsMcpServerSetTools(
    server: *mut TecsMcpServer,
    tools: *const u8,
    tools_length: usize,
) -> bool {
    if server.is_null() {
        set_error("MCP server is null");
        return false;
    }
    // SAFETY: Propagates this function's input validity contract.
    let bytes = match unsafe { input(tools, tools_length) } {
        Ok(bytes) => bytes,
        Err(error) => {
            set_error(error);
            return false;
        }
    };
    let tools = match decode_tools(bytes) {
        Ok(tools) => tools,
        Err(error) => {
            set_error(error);
            return false;
        }
    };
    // SAFETY: The non-null pointer is live by contract.
    let server = unsafe { &*server };
    *server
        .shared
        .tools
        .write()
        .unwrap_or_else(|error| error.into_inner()) = tools;
    true
}

/// Takes the next tool call without waiting.
///
/// # Safety
///
/// `server` must be null or a live server pointer.
#[no_mangle]
pub unsafe extern "C" fn tecsMcpServerNext(server: *mut TecsMcpServer) -> *mut TecsMcpRequest {
    if server.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: The non-null pointer is live by contract.
    let server = unsafe { &*server };
    let mut calls = server
        .calls
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    match calls.try_recv() {
        Ok(call) => Box::into_raw(Box::new(TecsMcpRequest {
            name: call.name,
            arguments: call.arguments,
            response: Some(call.response),
        })),
        Err(_) => ptr::null_mut(),
    }
}

unsafe fn request_bytes(
    request: *const TecsMcpRequest,
    length: *mut usize,
    select: impl FnOnce(&TecsMcpRequest) -> &[u8],
) -> *const u8 {
    if request.is_null() {
        if !length.is_null() {
            // SAFETY: A non-null out pointer is writable by the ABI contract.
            unsafe { *length = 0 };
        }
        return ptr::null();
    }
    // SAFETY: The non-null request pointer is live by contract.
    let bytes = select(unsafe { &*request });
    if !length.is_null() {
        // SAFETY: A non-null out pointer is writable by the ABI contract.
        unsafe { *length = bytes.len() };
    }
    bytes.as_ptr()
}

/// Borrows the request's tool name.
#[no_mangle]
pub unsafe extern "C" fn tecsMcpRequestName(
    request: *const TecsMcpRequest,
    length: *mut usize,
) -> *const u8 {
    // SAFETY: Propagates the boundary pointer contracts.
    unsafe { request_bytes(request, length, |request| &request.name) }
}

/// Borrows the request's JSON argument object.
#[no_mangle]
pub unsafe extern "C" fn tecsMcpRequestArguments(
    request: *const TecsMcpRequest,
    length: *mut usize,
) -> *const u8 {
    // SAFETY: Propagates the boundary pointer contracts.
    unsafe { request_bytes(request, length, |request| &request.arguments) }
}

/// Completes and releases a request.
///
/// # Safety
///
/// `request` must be an owned request pointer and may be consumed once.
/// `result` follows the input validity contract of `tecsMcpServerCreate`.
#[no_mangle]
pub unsafe extern "C" fn tecsMcpRequestRespond(
    request: *mut TecsMcpRequest,
    result: *const u8,
    result_length: usize,
    is_error: bool,
    crashed: bool,
) {
    if request.is_null() {
        return;
    }
    // SAFETY: Ownership crosses this boundary exactly once.
    let mut request = unsafe { Box::from_raw(request) };
    let Some(response) = request.response.take() else {
        return;
    };
    // SAFETY: Propagates this function's input validity contract.
    let bytes = unsafe { input(result, result_length) };
    let answer = if is_error {
        LuaResponse::Error {
            message: bytes
                .map(|bytes| String::from_utf8_lossy(bytes).into_owned())
                .unwrap_or_else(str::to_owned),
            crashed,
        }
    } else {
        match bytes
            .map_err(str::to_owned)
            .and_then(|bytes| serde_json::from_slice(bytes).map_err(|error| error.to_string()))
        {
            Ok(value) => LuaResponse::Success(value),
            Err(error) => LuaResponse::Error {
                message: format!("tecs: invalid tool result: {error}"),
                crashed: false,
            },
        }
    };
    let _ = response.send(answer);
}

/// Abandons and releases a request.
///
/// # Safety
///
/// `request` follows `tecsMcpRequestRespond`'s ownership contract.
#[no_mangle]
pub unsafe extern "C" fn tecsMcpRequestDestroy(request: *mut TecsMcpRequest) {
    if !request.is_null() {
        // SAFETY: Ownership crosses this boundary exactly once.
        drop(unsafe { Box::from_raw(request) });
    }
}

/// Stops and releases a server.
///
/// # Safety
///
/// `server` must be null or an owned live pointer and may be consumed once.
#[no_mangle]
pub unsafe extern "C" fn tecsMcpServerDestroy(server: *mut TecsMcpServer) {
    if !server.is_null() {
        // SAFETY: Ownership crosses this boundary exactly once.
        let server = unsafe { Box::from_raw(server) };
        server.cancellation.cancel();
    }
}
