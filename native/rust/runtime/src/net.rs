//! Provides nonblocking TCP, UDP, and asynchronous address resolution.
//!
//! `tecs.io` calls the opaque operations, sockets, and packets through the
//! generated Rust FFI table and exposes direct Teal operations backed by
//! private completion state.

use std::collections::{HashMap, VecDeque};
use std::ffi::c_int;
use std::io::{self, Read, Write};
use std::net::{
    IpAddr, SocketAddr, TcpListener as StdTcpListener, TcpStream, UdpSocket as StdUdpSocket,
};
use std::ptr;
use std::slice;
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::sync::OnceLock;
use std::thread;
use std::time::{Duration, Instant};

use mio::event::Event;
use mio::net::{
    TcpListener as MioTcpListener, TcpStream as MioTcpStream, UdpSocket as MioUdpSocket,
};
use mio::{Events, Interest, Poll, Token};
use tokio::runtime::{Builder, Runtime};
use tokio::task::AbortHandle;

use crate::set_error;

const READY_READABLE: u32 = 1;
const READY_WRITABLE: u32 = 2;
const READY_ERROR: u32 = 4;
const READY_CLOSED: u32 = 8;

pub struct TecsNetAddress {
    address: IpAddr,
    text: Box<[u8]>,
}

enum OperationValue {
    Address(TecsNetAddress),
    Stream(TecsNetStream),
}

pub struct TecsNetOperation {
    receiver: Receiver<Result<OperationValue, String>>,
    result: Option<Result<OperationValue, String>>,
    abort: AbortHandle,
}

static RUNTIME: OnceLock<Result<Runtime, String>> = OnceLock::new();

fn runtime() -> Result<&'static Runtime, &'static str> {
    match RUNTIME.get_or_init(|| {
        Builder::new_multi_thread()
            .worker_threads(1)
            .max_blocking_threads(8)
            .enable_all()
            .thread_name("tecs-net")
            .build()
            .map_err(|error| error.to_string())
    }) {
        Ok(runtime) => Ok(runtime),
        Err(error) => Err(error.as_str()),
    }
}

pub struct TecsNetStream {
    stream: MioTcpStream,
    pending: Vec<u8>,
    sent: usize,
    reactor: usize,
}

struct ReactorReady {
    token: u32,
    readiness: u32,
}

pub struct TecsNetReactor {
    poll: Poll,
    events: Events,
    streams: HashMap<u32, *mut TecsNetStream>,
    servers: HashMap<u32, *mut TecsNetServer>,
    datagrams: HashMap<u32, *mut TecsNetDatagram>,
    ready: VecDeque<ReactorReady>,
}

pub struct TecsNetServer {
    listener: MioTcpListener,
    accepted: Option<TecsNetStream>,
    reactor: usize,
}

pub struct TecsNetDatagram {
    socket: MioUdpSocket,
    reactor: usize,
}

pub struct TecsNetPacket {
    address: Option<TecsNetAddress>,
    port: u16,
    bytes: Box<[u8]>,
}

fn net_address(ip: IpAddr) -> TecsNetAddress {
    let text = ip.to_string().into_bytes().into_boxed_slice();
    TecsNetAddress { address: ip, text }
}

fn stream(socket: TcpStream) -> io::Result<TecsNetStream> {
    socket.set_nonblocking(true)?;
    socket.set_nodelay(true)?;
    Ok(TecsNetStream {
        stream: MioTcpStream::from_std(socket),
        pending: Vec::new(),
        sent: 0,
        reactor: 0,
    })
}

fn mio_stream(socket: MioTcpStream) -> io::Result<TecsNetStream> {
    socket.set_nodelay(true)?;
    Ok(TecsNetStream {
        stream: socket,
        pending: Vec::new(),
        sent: 0,
        reactor: 0,
    })
}

fn interest(bits: u32) -> Option<Interest> {
    match bits & (READY_READABLE | READY_WRITABLE) {
        READY_READABLE => Some(Interest::READABLE),
        READY_WRITABLE => Some(Interest::WRITABLE),
        3 => Some(Interest::READABLE.add(Interest::WRITABLE)),
        _ => None,
    }
}

fn readiness(event: &Event) -> u32 {
    let mut bits = 0;
    if event.is_readable() {
        bits |= READY_READABLE;
    }
    if event.is_writable() {
        bits |= READY_WRITABLE;
    }
    if event.is_error() {
        bits |= READY_ERROR;
    }
    if event.is_read_closed() || event.is_write_closed() {
        bits |= READY_CLOSED;
    }
    bits
}

unsafe fn unwatch(reactor: &mut TecsNetReactor, stream: &mut TecsNetStream) -> io::Result<()> {
    reactor.poll.registry().deregister(&mut stream.stream)?;
    reactor
        .streams
        .retain(|_, registered| !ptr::eq(*registered, stream));
    stream.reactor = 0;
    Ok(())
}

fn wait_until(timeout_ms: u32, mut ready: impl FnMut() -> io::Result<bool>) -> io::Result<bool> {
    let deadline = Instant::now() + Duration::from_millis(timeout_ms.into());
    loop {
        if ready()? {
            return Ok(true);
        }
        if timeout_ms == 0 || Instant::now() >= deadline {
            return Ok(false);
        }
        thread::sleep(Duration::from_millis(1));
    }
}

fn operation_status(operation: &mut TecsNetOperation, wait_ms: u32) -> c_int {
    if let Some(result) = &operation.result {
        return if result.is_ok() { 1 } else { -1 };
    }
    let received = if wait_ms == 0 {
        match operation.receiver.try_recv() {
            Ok(result) => Some(result),
            Err(TryRecvError::Empty) => None,
            Err(TryRecvError::Disconnected) => {
                Some(Err("network operation worker stopped".to_owned()))
            }
        }
    } else {
        match operation
            .receiver
            .recv_timeout(Duration::from_millis(wait_ms.into()))
        {
            Ok(result) => Some(result),
            Err(mpsc::RecvTimeoutError::Timeout) => None,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                Some(Err("network operation worker stopped".to_owned()))
            }
        }
    };
    let Some(result) = received else {
        return 0;
    };
    if let Err(error) = &result {
        set_error(error);
    }
    let status = if result.is_ok() { 1 } else { -1 };
    operation.result = Some(result);
    status
}

fn flush(stream: &mut TecsNetStream) -> io::Result<()> {
    while stream.sent < stream.pending.len() {
        match stream.stream.write(&stream.pending[stream.sent..]) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "connection closed while writing",
                ));
            }
            Ok(written) => stream.sent += written,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
            Err(error) => return Err(error),
        }
    }
    if stream.sent == stream.pending.len() {
        stream.pending.clear();
        stream.sent = 0;
    }
    Ok(())
}

unsafe fn bytes<'a>(data: *const u8, length: usize) -> Result<&'a [u8], &'static str> {
    if data.is_null() && length != 0 {
        return Err("byte pointer is null");
    }
    Ok(if length == 0 {
        &[]
    } else {
        // SAFETY: The caller promises a readable allocation of `length`.
        unsafe { slice::from_raw_parts(data, length) }
    })
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetResolve(host: *const u8, length: usize) -> *mut TecsNetOperation {
    let host = match unsafe { bytes(host, length) }
        .and_then(|bytes| std::str::from_utf8(bytes).map_err(|_| "hostname is not UTF-8"))
    {
        Ok(host) => host.to_owned(),
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
    let (sender, receiver) = mpsc::channel();
    let task = runtime.spawn(async move {
        let result = tokio::net::lookup_host((host.as_str(), 0))
            .await
            .map_err(|error| error.to_string())
            .and_then(|mut addresses| {
                addresses
                    .next()
                    .map(|value| OperationValue::Address(net_address(value.ip())))
                    .ok_or_else(|| "hostname resolved to no addresses".to_owned())
            });
        let _ = sender.send(result);
    });
    Box::into_raw(Box::new(TecsNetOperation {
        receiver,
        result: None,
        abort: task.abort_handle(),
    }))
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetConnect(
    address: *const TecsNetAddress,
    port: u16,
) -> *mut TecsNetOperation {
    if address.is_null() {
        set_error("address is null");
        return ptr::null_mut();
    }
    // SAFETY: The caller supplies a live address.
    let socket_address = SocketAddr::new(unsafe { (*address).address }, port);
    let runtime = match runtime() {
        Ok(runtime) => runtime,
        Err(error) => {
            set_error(error);
            return ptr::null_mut();
        }
    };
    let (sender, receiver) = mpsc::channel();
    let task = runtime.spawn(async move {
        let result = match tokio::net::TcpStream::connect(socket_address).await {
            Ok(socket) => socket
                .into_std()
                .and_then(stream)
                .map(OperationValue::Stream)
                .map_err(|error| error.to_string()),
            Err(error) => Err(error.to_string()),
        };
        let _ = sender.send(result);
    });
    Box::into_raw(Box::new(TecsNetOperation {
        receiver,
        result: None,
        abort: task.abort_handle(),
    }))
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetOperationStatus(
    operation: *mut TecsNetOperation,
    wait_ms: u32,
) -> c_int {
    if operation.is_null() {
        set_error("network operation is null");
        return -1;
    }
    // SAFETY: The caller supplies a live operation.
    operation_status(unsafe { &mut *operation }, wait_ms)
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetOperationTakeAddress(
    operation: *mut TecsNetOperation,
) -> *mut TecsNetAddress {
    if operation.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: The caller supplies a live operation.
    let operation = unsafe { &mut *operation };
    match operation.result.take() {
        Some(Ok(OperationValue::Address(address))) => Box::into_raw(Box::new(address)),
        result => {
            operation.result = result;
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetOperationTakeStream(
    operation: *mut TecsNetOperation,
) -> *mut TecsNetStream {
    if operation.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: The caller supplies a live operation.
    let operation = unsafe { &mut *operation };
    match operation.result.take() {
        Some(Ok(OperationValue::Stream(stream))) => Box::into_raw(Box::new(stream)),
        result => {
            operation.result = result;
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetOperationDestroy(operation: *mut TecsNetOperation) {
    if !operation.is_null() {
        // SAFETY: The caller transfers one owned operation.
        let operation = unsafe { Box::from_raw(operation) };
        operation.abort.abort();
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetAddressText(
    address: *const TecsNetAddress,
    length: *mut usize,
) -> *const u8 {
    if address.is_null() {
        if !length.is_null() {
            // SAFETY: The caller supplied an output pointer.
            unsafe { *length = 0 };
        }
        return ptr::null();
    }
    // SAFETY: The caller supplies a live address.
    let address = unsafe { &*address };
    if !length.is_null() {
        // SAFETY: The caller supplied an output pointer.
        unsafe { *length = address.text.len() };
    }
    address.text.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetAddressClone(
    address: *const TecsNetAddress,
) -> *mut TecsNetAddress {
    if address.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: The caller supplies a live address.
    Box::into_raw(Box::new(net_address(unsafe { (*address).address })))
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetAddressDestroy(address: *mut TecsNetAddress) {
    if !address.is_null() {
        // SAFETY: The caller transfers one owned address.
        drop(unsafe { Box::from_raw(address) });
    }
}

#[no_mangle]
pub extern "C" fn tecsNetReactorCreate() -> *mut TecsNetReactor {
    match Poll::new() {
        Ok(poll) => Box::into_raw(Box::new(TecsNetReactor {
            poll,
            events: Events::with_capacity(1024),
            streams: HashMap::new(),
            servers: HashMap::new(),
            datagrams: HashMap::new(),
            ready: VecDeque::new(),
        })),
        Err(error) => {
            set_error(error);
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetReactorWatch(
    reactor: *mut TecsNetReactor,
    stream: *mut TecsNetStream,
    token: u32,
    interest_bits: u32,
) -> c_int {
    if reactor.is_null() || stream.is_null() {
        set_error("network reactor or stream is null");
        return 0;
    }
    if token == 0 {
        set_error("network reactor token is zero");
        return 0;
    }
    let Some(interest) = interest(interest_bits) else {
        set_error("network reactor interest is empty");
        return 0;
    };
    // SAFETY: The caller supplies live reactor and stream values and does not
    // call the reactor concurrently.
    let reactor = unsafe { &mut *reactor };
    let stream = unsafe { &mut *stream };
    if stream.reactor != 0 {
        set_error("network stream already has a reactor watch");
        return 0;
    }
    if reactor.streams.contains_key(&token)
        || reactor.servers.contains_key(&token)
        || reactor.datagrams.contains_key(&token)
    {
        set_error("network reactor token is already watched");
        return 0;
    }
    if let Err(error) =
        reactor
            .poll
            .registry()
            .register(&mut stream.stream, Token(token as usize), interest)
    {
        set_error(error);
        return 0;
    }
    stream.reactor = ptr::from_mut(reactor) as usize;
    reactor.streams.insert(token, stream);
    1
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetReactorUnwatch(
    reactor: *mut TecsNetReactor,
    stream: *mut TecsNetStream,
    token: u32,
) -> c_int {
    if reactor.is_null() || stream.is_null() {
        set_error("network reactor or stream is null");
        return 0;
    }
    // SAFETY: The caller supplies live reactor and stream values and does not
    // call the reactor concurrently.
    let reactor = unsafe { &mut *reactor };
    let stream = unsafe { &mut *stream };
    let Some(registered) = reactor.streams.get(&token) else {
        set_error("network reactor token is not watched");
        return 0;
    };
    if !ptr::eq(*registered, stream) {
        set_error("network reactor token belongs to another stream");
        return 0;
    }
    if let Err(error) = unsafe { unwatch(reactor, stream) } {
        set_error(error);
        return 0;
    }
    1
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetReactorWatchServer(
    reactor: *mut TecsNetReactor,
    server: *mut TecsNetServer,
    token: u32,
    interest_bits: u32,
) -> c_int {
    if reactor.is_null() || server.is_null() {
        set_error("network reactor or server is null");
        return 0;
    }
    let Some(interest) = interest(interest_bits) else {
        set_error("network reactor interest is empty");
        return 0;
    };
    let reactor = unsafe { &mut *reactor };
    let server = unsafe { &mut *server };
    if token == 0
        || server.reactor != 0
        || reactor.streams.contains_key(&token)
        || reactor.servers.contains_key(&token)
        || reactor.datagrams.contains_key(&token)
    {
        set_error("network server watch is already active or has an invalid token");
        return 0;
    }
    if let Err(error) =
        reactor
            .poll
            .registry()
            .register(&mut server.listener, Token(token as usize), interest)
    {
        set_error(error);
        return 0;
    }
    server.reactor = ptr::from_mut(reactor) as usize;
    reactor.servers.insert(token, server);
    1
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetReactorUnwatchServer(
    reactor: *mut TecsNetReactor,
    server: *mut TecsNetServer,
    token: u32,
) -> c_int {
    if reactor.is_null() || server.is_null() {
        set_error("network reactor or server is null");
        return 0;
    }
    let reactor = unsafe { &mut *reactor };
    let server = unsafe { &mut *server };
    let Some(registered) = reactor.servers.get(&token) else {
        set_error("network reactor server token is not watched");
        return 0;
    };
    if !ptr::eq(*registered, server) {
        set_error("network reactor token belongs to another server");
        return 0;
    }
    if let Err(error) = reactor.poll.registry().deregister(&mut server.listener) {
        set_error(error);
        return 0;
    }
    reactor.servers.remove(&token);
    server.reactor = 0;
    1
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetReactorWatchDatagram(
    reactor: *mut TecsNetReactor,
    datagram: *mut TecsNetDatagram,
    token: u32,
    interest_bits: u32,
) -> c_int {
    if reactor.is_null() || datagram.is_null() {
        set_error("network reactor or datagram is null");
        return 0;
    }
    let Some(interest) = interest(interest_bits) else {
        set_error("network reactor interest is empty");
        return 0;
    };
    let reactor = unsafe { &mut *reactor };
    let datagram = unsafe { &mut *datagram };
    if token == 0
        || datagram.reactor != 0
        || reactor.streams.contains_key(&token)
        || reactor.servers.contains_key(&token)
        || reactor.datagrams.contains_key(&token)
    {
        set_error("network datagram watch is already active or has an invalid token");
        return 0;
    }
    if let Err(error) =
        reactor
            .poll
            .registry()
            .register(&mut datagram.socket, Token(token as usize), interest)
    {
        set_error(error);
        return 0;
    }
    datagram.reactor = ptr::from_mut(reactor) as usize;
    reactor.datagrams.insert(token, datagram);
    1
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetReactorUnwatchDatagram(
    reactor: *mut TecsNetReactor,
    datagram: *mut TecsNetDatagram,
    token: u32,
) -> c_int {
    if reactor.is_null() || datagram.is_null() {
        set_error("network reactor or datagram is null");
        return 0;
    }
    let reactor = unsafe { &mut *reactor };
    let datagram = unsafe { &mut *datagram };
    let Some(registered) = reactor.datagrams.get(&token) else {
        set_error("network reactor datagram token is not watched");
        return 0;
    };
    if !ptr::eq(*registered, datagram) {
        set_error("network reactor token belongs to another datagram");
        return 0;
    }
    if let Err(error) = reactor.poll.registry().deregister(&mut datagram.socket) {
        set_error(error);
        return 0;
    }
    reactor.datagrams.remove(&token);
    datagram.reactor = 0;
    1
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetReactorPoll(
    reactor: *mut TecsNetReactor,
    timeout_ms: u32,
) -> c_int {
    if reactor.is_null() {
        set_error("network reactor is null");
        return -1;
    }
    // SAFETY: The caller supplies a live reactor and does not call it
    // concurrently.
    let reactor = unsafe { &mut *reactor };
    if !reactor.ready.is_empty() {
        return c_int::try_from(reactor.ready.len()).unwrap_or(c_int::MAX);
    }

    let TecsNetReactor {
        poll,
        events,
        streams,
        servers,
        datagrams,
        ready,
    } = reactor;
    if let Err(error) = poll.poll(events, Some(Duration::from_millis(timeout_ms.into()))) {
        set_error(error);
        return -1;
    }

    for event in events.iter() {
        let Ok(token) = u32::try_from(event.token().0) else {
            continue;
        };
        let deregistered = if let Some(stream) = streams.remove(&token) {
            // SAFETY: A registration keeps its endpoint live until its
            // one-shot readiness is consumed or either owner destroys itself.
            let stream = unsafe { &mut *stream };
            let result = poll.registry().deregister(&mut stream.stream);
            stream.reactor = 0;
            result
        } else if let Some(server) = servers.remove(&token) {
            // SAFETY: The same lifetime rule applies to listening sockets.
            let server = unsafe { &mut *server };
            let result = poll.registry().deregister(&mut server.listener);
            server.reactor = 0;
            result
        } else if let Some(datagram) = datagrams.remove(&token) {
            // SAFETY: The same lifetime rule applies to datagram sockets.
            let datagram = unsafe { &mut *datagram };
            let result = poll.registry().deregister(&mut datagram.socket);
            datagram.reactor = 0;
            result
        } else {
            continue;
        };
        if let Err(error) = deregistered {
            set_error(error);
            return -1;
        }
        ready.push_back(ReactorReady {
            token,
            readiness: readiness(event),
        });
    }
    c_int::try_from(ready.len()).unwrap_or(c_int::MAX)
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetReactorNext(
    reactor: *mut TecsNetReactor,
    token: *mut u32,
    readiness: *mut u32,
) -> c_int {
    if reactor.is_null() || token.is_null() || readiness.is_null() {
        set_error("network reactor or output is null");
        return -1;
    }
    // SAFETY: The caller supplies a live reactor and writable outputs.
    let reactor = unsafe { &mut *reactor };
    let Some(event) = reactor.ready.pop_front() else {
        return 0;
    };
    unsafe {
        *token = event.token;
        *readiness = event.readiness;
    }
    1
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetReactorDestroy(reactor: *mut TecsNetReactor) {
    if reactor.is_null() {
        return;
    }
    // SAFETY: The caller transfers the one owned reactor.
    let mut reactor = unsafe { Box::from_raw(reactor) };
    let streams = std::mem::take(&mut reactor.streams);
    for (_, stream) in streams {
        // SAFETY: Registered streams coordinate destruction through their
        // reactor field and therefore remain live here.
        let stream = unsafe { &mut *stream };
        let _ = reactor.poll.registry().deregister(&mut stream.stream);
        stream.reactor = 0;
    }
    let servers = std::mem::take(&mut reactor.servers);
    for (_, server) in servers {
        // SAFETY: Registered servers coordinate destruction through their
        // reactor field and therefore remain live here.
        let server = unsafe { &mut *server };
        let _ = reactor.poll.registry().deregister(&mut server.listener);
        server.reactor = 0;
    }
    let datagrams = std::mem::take(&mut reactor.datagrams);
    for (_, datagram) in datagrams {
        // SAFETY: Registered datagrams coordinate destruction the same way.
        let datagram = unsafe { &mut *datagram };
        let _ = reactor.poll.registry().deregister(&mut datagram.socket);
        datagram.reactor = 0;
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetListen(
    address: *const TecsNetAddress,
    port: u16,
) -> *mut TecsNetServer {
    let ip = if address.is_null() {
        IpAddr::from([0, 0, 0, 0])
    } else {
        // SAFETY: The caller supplies a live address.
        unsafe { (*address).address }
    };
    match StdTcpListener::bind(SocketAddr::new(ip, port)).and_then(|listener| {
        listener.set_nonblocking(true)?;
        Ok(MioTcpListener::from_std(listener))
    }) {
        Ok(listener) => Box::into_raw(Box::new(TecsNetServer {
            listener,
            accepted: None,
            reactor: 0,
        })),
        Err(error) => {
            set_error(error);
            ptr::null_mut()
        }
    }
}

fn accept(server: &mut TecsNetServer) -> io::Result<bool> {
    if server.accepted.is_some() {
        return Ok(true);
    }
    match server.listener.accept() {
        Ok((socket, _)) => {
            server.accepted = Some(mio_stream(socket)?);
            Ok(true)
        }
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(false),
        Err(error) => Err(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetServerAccept(server: *mut TecsNetServer) -> *mut TecsNetStream {
    if server.is_null() {
        set_error("server is null");
        return ptr::null_mut();
    }
    // SAFETY: The caller supplies a live server.
    let server = unsafe { &mut *server };
    match accept(server) {
        Ok(true) => Box::into_raw(Box::new(server.accepted.take().expect("accepted stream"))),
        Ok(false) => ptr::null_mut(),
        Err(error) => {
            set_error(error);
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetServerWait(server: *mut TecsNetServer, timeout_ms: u32) -> c_int {
    if server.is_null() {
        set_error("server is null");
        return -1;
    }
    // SAFETY: The caller supplies a live server.
    match wait_until(timeout_ms, || accept(unsafe { &mut *server })) {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(error) => {
            set_error(error);
            -1
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetServerDestroy(server: *mut TecsNetServer) {
    if !server.is_null() {
        // SAFETY: A watched server and its reactor point at each other until
        // one of their destroy paths removes the registration.
        let server_ref = unsafe { &mut *server };
        if server_ref.reactor != 0 {
            let reactor = server_ref.reactor as *mut TecsNetReactor;
            let reactor = unsafe { &mut *reactor };
            let _ = reactor.poll.registry().deregister(&mut server_ref.listener);
            reactor
                .servers
                .retain(|_, registered| !ptr::eq(*registered, server_ref));
            server_ref.reactor = 0;
        }
        // SAFETY: The caller transfers one owned server.
        drop(unsafe { Box::from_raw(server) });
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetStreamPeer(stream: *const TecsNetStream) -> *mut TecsNetAddress {
    if stream.is_null() {
        set_error("stream is null");
        return ptr::null_mut();
    }
    // SAFETY: The caller supplies a live stream.
    match unsafe { (*stream).stream.peer_addr() } {
        Ok(value) => Box::into_raw(Box::new(net_address(value.ip()))),
        Err(error) => {
            set_error(error);
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetStreamRead(
    stream: *mut TecsNetStream,
    output: *mut u8,
    length: usize,
) -> i64 {
    if stream.is_null() || output.is_null() {
        set_error("stream or output buffer is null");
        return -1;
    }
    // SAFETY: The caller supplies a live stream and writable output.
    let stream = unsafe { &mut *stream };
    let output = unsafe { slice::from_raw_parts_mut(output, length) };
    match stream.stream.read(output) {
        Ok(0) => {
            set_error("connection closed");
            -1
        }
        Ok(read) => i64::try_from(read).unwrap_or(i64::MAX),
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => 0,
        Err(error) => {
            set_error(error);
            -1
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetStreamWrite(
    stream: *mut TecsNetStream,
    data: *const u8,
    length: usize,
) -> c_int {
    if stream.is_null() {
        set_error("stream is null");
        return 0;
    }
    let data = match unsafe { bytes(data, length) } {
        Ok(data) => data,
        Err(error) => {
            set_error(error);
            return 0;
        }
    };
    // SAFETY: The caller supplies a live stream.
    let stream = unsafe { &mut *stream };
    if let Err(error) = flush(stream) {
        set_error(error);
        return 0;
    }
    stream.pending.extend_from_slice(data);
    if let Err(error) = flush(stream) {
        set_error(error);
        return 0;
    }
    1
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetStreamPendingWrites(stream: *mut TecsNetStream) -> i64 {
    if stream.is_null() {
        set_error("stream is null");
        return -1;
    }
    // SAFETY: The caller supplies a live stream.
    let stream = unsafe { &mut *stream };
    if let Err(error) = flush(stream) {
        set_error(error);
        return -1;
    }
    i64::try_from(stream.pending.len() - stream.sent).unwrap_or(i64::MAX)
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetStreamDrain(stream: *mut TecsNetStream, timeout_ms: u32) -> c_int {
    if stream.is_null() {
        set_error("stream is null");
        return -1;
    }
    // SAFETY: The caller supplies a live stream.
    match wait_until(timeout_ms, || {
        let stream = unsafe { &mut *stream };
        flush(stream)?;
        Ok(stream.pending.is_empty())
    }) {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(error) => {
            set_error(error);
            -1
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetStreamWait(stream: *mut TecsNetStream, timeout_ms: u32) -> c_int {
    if stream.is_null() {
        set_error("stream is null");
        return -1;
    }
    let mut byte = [0_u8; 1];
    // SAFETY: The caller supplies a live stream.
    match wait_until(timeout_ms, || {
        match unsafe { (*stream).stream.peek(&mut byte) } {
            Ok(_) => Ok(true),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(false),
            Err(error) => Err(error),
        }
    }) {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(error) => {
            set_error(error);
            -1
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetStreamDestroy(stream: *mut TecsNetStream) {
    if !stream.is_null() {
        // SAFETY: A watched stream and its reactor point at each other until
        // one of their destroy paths removes the registration.
        let stream_ref = unsafe { &mut *stream };
        if stream_ref.reactor != 0 {
            let reactor = stream_ref.reactor as *mut TecsNetReactor;
            let _ = unsafe { unwatch(&mut *reactor, stream_ref) };
        }
        // SAFETY: The caller transfers one owned stream.
        drop(unsafe { Box::from_raw(stream) });
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetDatagramBind(
    address: *const TecsNetAddress,
    port: u16,
) -> *mut TecsNetDatagram {
    let ip = if address.is_null() {
        IpAddr::from([0, 0, 0, 0])
    } else {
        // SAFETY: The caller supplies a live address.
        unsafe { (*address).address }
    };
    match StdUdpSocket::bind(SocketAddr::new(ip, port)).and_then(|socket| {
        socket.set_nonblocking(true)?;
        Ok(MioUdpSocket::from_std(socket))
    }) {
        Ok(socket) => Box::into_raw(Box::new(TecsNetDatagram { socket, reactor: 0 })),
        Err(error) => {
            set_error(error);
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetDatagramSend(
    socket: *mut TecsNetDatagram,
    address: *const TecsNetAddress,
    port: u16,
    data: *const u8,
    length: usize,
) -> c_int {
    if socket.is_null() || address.is_null() {
        set_error("datagram socket or address is null");
        return -1;
    }
    let data = match unsafe { bytes(data, length) } {
        Ok(data) => data,
        Err(error) => {
            set_error(error);
            return -1;
        }
    };
    // SAFETY: The caller supplies live socket and address values.
    let destination = SocketAddr::new(unsafe { (*address).address }, port);
    match unsafe { (*socket).socket.send_to(data, destination) } {
        Ok(sent) if sent == data.len() => 1,
        Ok(sent) => {
            set_error(format!("sent {sent} of {} datagram bytes", data.len()));
            -1
        }
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => 0,
        Err(error) => {
            set_error(error);
            -1
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetDatagramSendWait(
    socket: *mut TecsNetDatagram,
    address: *const TecsNetAddress,
    port: u16,
    data: *const u8,
    length: usize,
    timeout_ms: u32,
) -> c_int {
    if socket.is_null() || address.is_null() {
        set_error("datagram socket or address is null");
        return -1;
    }
    let data = match unsafe { bytes(data, length) } {
        Ok(data) => data,
        Err(error) => {
            set_error(error);
            return -1;
        }
    };
    let destination = SocketAddr::new(unsafe { (*address).address }, port);
    match wait_until(timeout_ms, || {
        match unsafe { (*socket).socket.send_to(data, destination) } {
            Ok(sent) if sent == data.len() => Ok(true),
            Ok(sent) => Err(io::Error::other(format!(
                "sent {sent} of {} datagram bytes",
                data.len()
            ))),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(false),
            Err(error) => Err(error),
        }
    }) {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(error) => {
            set_error(error);
            -1
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetDatagramReceive(
    socket: *mut TecsNetDatagram,
) -> *mut TecsNetPacket {
    if socket.is_null() {
        set_error("datagram socket is null");
        return ptr::null_mut();
    }
    let mut bytes = vec![0_u8; 65_507];
    // SAFETY: The caller supplies a live socket.
    match unsafe { (*socket).socket.recv_from(&mut bytes) } {
        Ok((length, source)) => {
            bytes.truncate(length);
            Box::into_raw(Box::new(TecsNetPacket {
                address: Some(net_address(source.ip())),
                port: source.port(),
                bytes: bytes.into_boxed_slice(),
            }))
        }
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => ptr::null_mut(),
        Err(error) => {
            set_error(error);
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetDatagramWait(
    socket: *mut TecsNetDatagram,
    timeout_ms: u32,
) -> c_int {
    if socket.is_null() {
        set_error("datagram socket is null");
        return -1;
    }
    let mut byte = [0_u8; 1];
    // SAFETY: The caller supplies a live socket.
    match wait_until(timeout_ms, || {
        match unsafe { (*socket).socket.peek_from(&mut byte) } {
            Ok(_) => Ok(true),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(false),
            Err(error) => Err(error),
        }
    }) {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(error) => {
            set_error(error);
            -1
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetDatagramDestroy(socket: *mut TecsNetDatagram) {
    if !socket.is_null() {
        // SAFETY: A watched datagram and its reactor point at each other until
        // one of their destroy paths removes the registration.
        let socket_ref = unsafe { &mut *socket };
        if socket_ref.reactor != 0 {
            let reactor = socket_ref.reactor as *mut TecsNetReactor;
            let reactor = unsafe { &mut *reactor };
            let _ = reactor.poll.registry().deregister(&mut socket_ref.socket);
            reactor
                .datagrams
                .retain(|_, registered| !ptr::eq(*registered, socket_ref));
            socket_ref.reactor = 0;
        }
        // SAFETY: The caller transfers one owned socket.
        drop(unsafe { Box::from_raw(socket) });
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetPacketTakeAddress(
    packet: *mut TecsNetPacket,
) -> *mut TecsNetAddress {
    if packet.is_null() {
        return ptr::null_mut();
    }
    // SAFETY: The caller supplies a live packet.
    match unsafe { (*packet).address.take() } {
        Some(address) => Box::into_raw(Box::new(address)),
        None => ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetPacketPort(packet: *const TecsNetPacket) -> u16 {
    if packet.is_null() {
        return 0;
    }
    // SAFETY: The caller supplies a live packet.
    unsafe { (*packet).port }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetPacketBytes(
    packet: *const TecsNetPacket,
    length: *mut usize,
) -> *const u8 {
    if packet.is_null() {
        if !length.is_null() {
            // SAFETY: The caller supplied an output pointer.
            unsafe { *length = 0 };
        }
        return ptr::null();
    }
    // SAFETY: The caller supplies a live packet.
    let packet = unsafe { &*packet };
    if !length.is_null() {
        // SAFETY: The caller supplied an output pointer.
        unsafe { *length = packet.bytes.len() };
    }
    packet.bytes.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetPacketDestroy(packet: *mut TecsNetPacket) {
    if !packet.is_null() {
        // SAFETY: The caller transfers one owned packet.
        drop(unsafe { Box::from_raw(packet) });
    }
}
