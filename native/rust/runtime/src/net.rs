//! Provides nonblocking TCP, UDP, and asynchronous address resolution.
//!
//! `tecs.io` calls the opaque operations, sockets, and packets through the
//! generated Rust FFI table and exposes direct Teal operations backed by
//! private completion state.

use std::collections::{HashMap, VecDeque};
use std::ffi::c_int;
use std::fmt::{self, Write as FormatWrite};
use std::io::{self, Read, Write};
use std::net::{
    IpAddr, SocketAddr, TcpListener as StdTcpListener, TcpStream, UdpSocket as StdUdpSocket,
};
use std::ptr;
use std::slice;
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

#[cfg(unix)]
use std::os::fd::{AsRawFd, RawFd};
#[cfg(windows)]
use std::os::windows::io::{AsRawSocket, RawSocket};

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
const STREAM_WRITE_CAPACITY: usize = 1024 * 1024;
const DATAGRAM_CAPACITY: usize = 65_507;

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
    /// Holds one maximum-size datagram so packet reception allocates only the
    /// exact payload it hands to its caller.
    scratch: Vec<u8>,
    /// Records the sender of the most recent received datagram so a caller
    /// that skipped the packet form can still address a reply.
    source: Option<SocketAddr>,
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

/// Names the readiness a blocking wait asks the kernel for.
#[derive(Clone, Copy)]
enum WaitFor {
    Readable,
    Writable,
}

#[cfg(unix)]
type Descriptor = RawFd;
#[cfg(windows)]
type Descriptor = RawSocket;

#[cfg(unix)]
fn descriptor(source: &impl AsRawFd) -> Descriptor {
    source.as_raw_fd()
}

#[cfg(windows)]
fn descriptor(source: &impl AsRawSocket) -> Descriptor {
    source.as_raw_socket()
}

/// Declares the one Winsock entry point Windows readiness waits need.
///
/// `windows-sys` is not a dependency of this crate, and the socket poll is
/// three declarations, so it is written here rather than pulled in.
#[cfg(windows)]
mod winsock {
    /// Mirrors `WSAPOLLFD`.
    #[repr(C)]
    pub struct PollDescriptor {
        pub socket: usize,
        pub events: i16,
        pub revents: i16,
    }

    /// Mirrors `POLLRDNORM`.
    pub const POLL_READABLE: i16 = 0x0100;
    /// Mirrors `POLLWRNORM`.
    pub const POLL_WRITABLE: i16 = 0x0010;

    #[link(name = "ws2_32")]
    extern "system" {
        pub fn WSAPoll(descriptors: *mut PollDescriptor, count: u32, timeout: i32) -> i32;
    }
}

/// Sleeps in the kernel until the descriptor is ready or `timeout_ms` elapses.
///
/// A wakeup is advisory: the caller retries its operation and waits again, so
/// a spurious readiness report costs one syscall rather than a wrong result.
#[cfg(unix)]
fn wait_descriptor(target: Descriptor, wait_for: WaitFor, timeout_ms: i32) -> io::Result<()> {
    let mut entry = libc::pollfd {
        fd: target,
        events: match wait_for {
            WaitFor::Readable => libc::POLLIN,
            WaitFor::Writable => libc::POLLOUT,
        },
        revents: 0,
    };
    // SAFETY: `poll` reads and writes the one entry this call owns.
    let status = unsafe { libc::poll(&mut entry, 1, timeout_ms) };
    if status < 0 {
        let failure = io::Error::last_os_error();
        if failure.kind() != io::ErrorKind::Interrupted {
            return Err(failure);
        }
    }
    Ok(())
}

#[cfg(windows)]
fn wait_descriptor(target: Descriptor, wait_for: WaitFor, timeout_ms: i32) -> io::Result<()> {
    let mut entry = winsock::PollDescriptor {
        socket: target as usize,
        events: match wait_for {
            WaitFor::Readable => winsock::POLL_READABLE,
            WaitFor::Writable => winsock::POLL_WRITABLE,
        },
        revents: 0,
    };
    // SAFETY: `WSAPoll` reads and writes the one entry this call owns.
    let status = unsafe { winsock::WSAPoll(&mut entry, 1, timeout_ms) };
    if status < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Retries `ready` around kernel readiness waits until it succeeds or the
/// timeout expires.
///
/// A zero timeout polls once. The caller's operation stays the authority on
/// readiness, so this only decides when to attempt it again, and an idle wait
/// costs no CPU.
fn wait_until(
    target: Descriptor,
    wait_for: WaitFor,
    timeout_ms: u32,
    mut ready: impl FnMut() -> io::Result<bool>,
) -> io::Result<bool> {
    let deadline = Instant::now() + Duration::from_millis(timeout_ms.into());
    loop {
        if ready()? {
            return Ok(true);
        }
        if timeout_ms == 0 {
            return Ok(false);
        }
        let now = Instant::now();
        if now >= deadline {
            return Ok(false);
        }
        let remaining = deadline.saturating_duration_since(now).as_millis();
        let slice = i32::try_from(remaining).unwrap_or(i32::MAX).max(1);
        wait_descriptor(target, wait_for, slice)?;
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
    } else if stream.sent > 0 {
        let remaining = stream.pending.len() - stream.sent;
        stream.pending.copy_within(stream.sent.., 0);
        stream.pending.truncate(remaining);
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
    let target = descriptor(&unsafe { &*server }.listener);
    match wait_until(target, WaitFor::Readable, timeout_ms, || {
        accept(unsafe { &mut *server })
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
) -> i64 {
    if stream.is_null() {
        set_error("stream is null");
        return -1;
    }
    let data = match unsafe { bytes(data, length) } {
        Ok(data) => data,
        Err(error) => {
            set_error(error);
            return -1;
        }
    };
    // SAFETY: The caller supplies a live stream.
    let stream = unsafe { &mut *stream };
    if let Err(error) = flush(stream) {
        set_error(error);
        return -1;
    }
    let accepted = data
        .len()
        .min(STREAM_WRITE_CAPACITY.saturating_sub(stream.pending.len()));
    if accepted == 0 {
        return 0;
    }
    stream.pending.extend_from_slice(&data[..accepted]);
    if let Err(error) = flush(stream) {
        set_error(error);
        return -1;
    }
    i64::try_from(accepted).unwrap_or(i64::MAX)
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
    let target = descriptor(&unsafe { &*stream }.stream);
    match wait_until(target, WaitFor::Writable, timeout_ms, || {
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
    let target = descriptor(&unsafe { &*stream }.stream);
    match wait_until(target, WaitFor::Readable, timeout_ms, || {
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
        Ok(socket) => Box::into_raw(Box::new(TecsNetDatagram {
            socket,
            reactor: 0,
            scratch: Vec::new(),
            source: None,
        })),
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
    // SAFETY: The caller supplies a live socket.
    let target = descriptor(&unsafe { &*socket }.socket);
    match wait_until(target, WaitFor::Writable, timeout_ms, || {
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
    packet: *mut *mut TecsNetPacket,
) -> c_int {
    if socket.is_null() || packet.is_null() {
        set_error("datagram socket or output is null");
        return -1;
    }
    // SAFETY: The caller supplies writable storage for one packet pointer.
    unsafe {
        *packet = ptr::null_mut();
    }
    // SAFETY: The caller supplies a live socket.
    let socket = unsafe { &mut *socket };
    if socket.scratch.len() < DATAGRAM_CAPACITY {
        socket.scratch.resize(DATAGRAM_CAPACITY, 0);
    }
    match socket.socket.recv_from(&mut socket.scratch) {
        Ok((length, source)) => {
            socket.source = Some(source);
            let bytes = Box::<[u8]>::from(&socket.scratch[..length]);
            // SAFETY: The output was validated above and receives ownership.
            unsafe {
                *packet = Box::into_raw(Box::new(TecsNetPacket {
                    address: Some(net_address(source.ip())),
                    port: source.port(),
                    bytes,
                }));
            }
            1
        }
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => 0,
        Err(error) => {
            set_error(error);
            -1
        }
    }
}

/// Writes formatted text into caller memory without allocating.
struct TextSink<'a> {
    target: &'a mut [u8],
    written: usize,
}

impl FormatWrite for TextSink<'_> {
    fn write_str(&mut self, value: &str) -> fmt::Result {
        let bytes = value.as_bytes();
        let finish = self.written + bytes.len();
        if finish > self.target.len() {
            return Err(fmt::Error);
        }
        self.target[self.written..finish].copy_from_slice(bytes);
        self.written = finish;
        Ok(())
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetDatagramReceiveInto(
    socket: *mut TecsNetDatagram,
    output: *mut u8,
    capacity: usize,
    length: *mut usize,
    source: *mut u8,
    source_capacity: usize,
    source_length: *mut usize,
    port: *mut u16,
) -> c_int {
    if socket.is_null() || length.is_null() || source_length.is_null() || port.is_null() {
        set_error("datagram socket or output is null");
        return -1;
    }
    if (output.is_null() && capacity != 0) || (source.is_null() && source_capacity != 0) {
        set_error("datagram output buffer is null");
        return -1;
    }
    // SAFETY: The caller supplies writable storage for each output.
    unsafe {
        *length = 0;
        *source_length = 0;
        *port = 0;
    }
    let mut nothing = [0_u8; 0];
    // SAFETY: The caller promises a writable allocation of `capacity`.
    let payload = if capacity == 0 {
        &mut nothing[..]
    } else {
        unsafe { slice::from_raw_parts_mut(output, capacity) }
    };
    // SAFETY: The caller supplies a live socket.
    let socket = unsafe { &mut *socket };
    let (received, from) = match socket.socket.recv_from(payload) {
        Ok(value) => value,
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => return 0,
        Err(error) => {
            set_error(error);
            return -1;
        }
    };
    socket.source = Some(from);

    let mut unwritten = [0_u8; 0];
    // SAFETY: The caller promises a writable allocation of `source_capacity`.
    let text = if source_capacity == 0 {
        &mut unwritten[..]
    } else {
        unsafe { slice::from_raw_parts_mut(source, source_capacity) }
    };
    let mut sink = TextSink {
        target: text,
        written: 0,
    };
    if write!(sink, "{}", from.ip()).is_err() {
        set_error("datagram source address does not fit its buffer");
        return -1;
    }
    let written = sink.written;
    // SAFETY: Each output pointer was validated above.
    unsafe {
        *length = received;
        *source_length = written;
        *port = from.port();
    }
    1
}

#[no_mangle]
pub unsafe extern "C" fn tecsNetDatagramSource(
    socket: *mut TecsNetDatagram,
) -> *mut TecsNetAddress {
    if socket.is_null() {
        set_error("datagram socket is null");
        return ptr::null_mut();
    }
    // SAFETY: The caller supplies a live socket.
    match unsafe { &*socket }.source {
        Some(source) => Box::into_raw(Box::new(net_address(source.ip()))),
        None => {
            set_error("datagram socket has received no packet");
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
    let target = descriptor(&unsafe { &*socket }.socket);
    match wait_until(target, WaitFor::Readable, timeout_ms, || {
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;
    use std::thread;

    fn loopback() -> *mut TecsNetAddress {
        Box::into_raw(Box::new(net_address(IpAddr::V4(Ipv4Addr::LOCALHOST))))
    }

    fn listener_port(server: *mut TecsNetServer) -> u16 {
        // SAFETY: The test owns the server for the whole call.
        unsafe { &*server }
            .listener
            .local_addr()
            .expect("listener address")
            .port()
    }

    fn datagram_port(socket: *mut TecsNetDatagram) -> u16 {
        // SAFETY: The test owns the socket for the whole call.
        unsafe { &*socket }
            .socket
            .local_addr()
            .expect("datagram address")
            .port()
    }

    #[test]
    fn a_blocking_wait_returns_after_its_timeout() {
        let address = loopback();
        let server = unsafe { tecsNetListen(address, 0) };
        assert!(!server.is_null());

        let started = Instant::now();
        let status = unsafe { tecsNetServerWait(server, 120) };
        let elapsed = started.elapsed();
        assert_eq!(0, status);
        assert!(elapsed >= Duration::from_millis(110), "waited {elapsed:?}");
        assert!(elapsed < Duration::from_millis(2000), "waited {elapsed:?}");

        unsafe { tecsNetServerDestroy(server) };
        unsafe { tecsNetAddressDestroy(address) };
    }

    #[test]
    fn a_zero_timeout_polls_without_waiting() {
        let address = loopback();
        let server = unsafe { tecsNetListen(address, 0) };
        assert!(!server.is_null());

        let started = Instant::now();
        assert_eq!(0, unsafe { tecsNetServerWait(server, 0) });
        assert!(started.elapsed() < Duration::from_millis(50));

        unsafe { tecsNetServerDestroy(server) };
        unsafe { tecsNetAddressDestroy(address) };
    }

    #[test]
    fn a_blocking_wait_wakes_when_its_client_arrives() {
        let address = loopback();
        let server = unsafe { tecsNetListen(address, 0) };
        assert!(!server.is_null());
        let port = listener_port(server);

        let client = thread::spawn(move || {
            thread::sleep(Duration::from_millis(60));
            TcpStream::connect((Ipv4Addr::LOCALHOST, port)).expect("client connects")
        });
        let started = Instant::now();
        let status = unsafe { tecsNetServerWait(server, 5000) };
        let elapsed = started.elapsed();
        assert_eq!(1, status);
        assert!(elapsed < Duration::from_millis(2000), "waited {elapsed:?}");

        let accepted = unsafe { tecsNetServerAccept(server) };
        assert!(!accepted.is_null());
        drop(client.join().expect("client thread"));

        unsafe { tecsNetStreamDestroy(accepted) };
        unsafe { tecsNetServerDestroy(server) };
        unsafe { tecsNetAddressDestroy(address) };
    }

    #[test]
    fn a_stream_drain_finishes_its_queued_bytes() {
        let address = loopback();
        let server = unsafe { tecsNetListen(address, 0) };
        let port = listener_port(server);
        let peer = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).expect("client connects");
        assert_eq!(1, unsafe { tecsNetServerWait(server, 2000) });
        let accepted = unsafe { tecsNetServerAccept(server) };
        assert!(!accepted.is_null());

        let payload = b"drain me";
        let written = unsafe { tecsNetStreamWrite(accepted, payload.as_ptr(), payload.len()) };
        assert_eq!(payload.len() as i64, written);
        assert_eq!(1, unsafe { tecsNetStreamDrain(accepted, 2000) });
        assert_eq!(0, unsafe { tecsNetStreamPendingWrites(accepted) });

        drop(peer);
        unsafe { tecsNetStreamDestroy(accepted) };
        unsafe { tecsNetServerDestroy(server) };
        unsafe { tecsNetAddressDestroy(address) };
    }

    #[test]
    fn a_datagram_receives_into_caller_memory() {
        let address = loopback();
        let receiver = unsafe { tecsNetDatagramBind(address, 0) };
        let sender = unsafe { tecsNetDatagramBind(address, 0) };
        assert!(!receiver.is_null() && !sender.is_null());
        let port = datagram_port(receiver);
        let payload = b"datagram bytes";

        let mut bytes = [0_u8; 64];
        let mut length = 0_usize;
        let mut text = [0_u8; 64];
        let mut text_length = 0_usize;
        let mut source_port = 0_u16;

        // Nothing has arrived, so the call reports would-block without
        // touching its outputs.
        assert_eq!(0, unsafe {
            tecsNetDatagramReceiveInto(
                receiver,
                bytes.as_mut_ptr(),
                bytes.len(),
                &mut length,
                text.as_mut_ptr(),
                text.len(),
                &mut text_length,
                &mut source_port,
            )
        });
        assert_eq!(0, length);

        assert_eq!(1, unsafe {
            tecsNetDatagramSend(sender, address, port, payload.as_ptr(), payload.len())
        });
        assert_eq!(1, unsafe { tecsNetDatagramWait(receiver, 2000) });
        assert_eq!(1, unsafe {
            tecsNetDatagramReceiveInto(
                receiver,
                bytes.as_mut_ptr(),
                bytes.len(),
                &mut length,
                text.as_mut_ptr(),
                text.len(),
                &mut text_length,
                &mut source_port,
            )
        });
        assert_eq!(payload.len(), length);
        assert_eq!(&payload[..], &bytes[..length]);
        assert_eq!(
            "127.0.0.1",
            std::str::from_utf8(&text[..text_length]).expect("address text")
        );
        assert_eq!(datagram_port(sender), source_port);

        let source = unsafe { tecsNetDatagramSource(receiver) };
        assert!(!source.is_null());
        unsafe { tecsNetAddressDestroy(source) };

        unsafe { tecsNetDatagramDestroy(sender) };
        unsafe { tecsNetDatagramDestroy(receiver) };
        unsafe { tecsNetAddressDestroy(address) };
    }

    #[test]
    fn a_datagram_packet_owns_exactly_its_payload() {
        let address = loopback();
        let receiver = unsafe { tecsNetDatagramBind(address, 0) };
        let sender = unsafe { tecsNetDatagramBind(address, 0) };
        let port = datagram_port(receiver);
        let payload = b"packet";
        assert_eq!(1, unsafe {
            tecsNetDatagramSend(sender, address, port, payload.as_ptr(), payload.len())
        });
        assert_eq!(1, unsafe { tecsNetDatagramWait(receiver, 2000) });

        let mut packet: *mut TecsNetPacket = ptr::null_mut();
        assert_eq!(1, unsafe { tecsNetDatagramReceive(receiver, &mut packet) });
        assert!(!packet.is_null());
        // SAFETY: The receive above produced one live packet.
        let held = unsafe { &*packet };
        assert_eq!(payload.len(), held.bytes.len());
        assert_eq!(&payload[..], &held.bytes[..]);
        // SAFETY: The socket is live and keeps its reception buffer.
        assert_eq!(DATAGRAM_CAPACITY, unsafe { &*receiver }.scratch.len());

        unsafe { tecsNetPacketDestroy(packet) };
        unsafe { tecsNetDatagramDestroy(sender) };
        unsafe { tecsNetDatagramDestroy(receiver) };
        unsafe { tecsNetAddressDestroy(address) };
    }

    #[test]
    fn a_source_address_needs_a_received_datagram() {
        let address = loopback();
        let socket = unsafe { tecsNetDatagramBind(address, 0) };
        assert!(unsafe { tecsNetDatagramSource(socket) }.is_null());

        unsafe { tecsNetDatagramDestroy(socket) };
        unsafe { tecsNetAddressDestroy(address) };
    }
}
