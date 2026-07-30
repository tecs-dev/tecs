//! Provides nonblocking TCP, UDP, and asynchronous address resolution.
//!
//! `tecs.io` calls the opaque operations, sockets, and packets through the
//! generated Rust FFI table and exposes them as Teal objects and futures.

use std::ffi::c_int;
use std::io::{self, Read, Write};
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream, ToSocketAddrs, UdpSocket};
use std::ptr;
use std::slice;
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread;
use std::time::{Duration, Instant};

use crate::set_error;

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
}

pub struct TecsNetStream {
    stream: TcpStream,
    pending: Vec<u8>,
    sent: usize,
}

pub struct TecsNetServer {
    listener: TcpListener,
    accepted: Option<TecsNetStream>,
}

pub struct TecsNetDatagram {
    socket: UdpSocket,
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
        stream: socket,
        pending: Vec::new(),
        sent: 0,
    })
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
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let result = (host.as_str(), 0)
            .to_socket_addrs()
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
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let result = TcpStream::connect(socket_address)
            .and_then(stream)
            .map(OperationValue::Stream)
            .map_err(|error| error.to_string());
        let _ = sender.send(result);
    });
    Box::into_raw(Box::new(TecsNetOperation {
        receiver,
        result: None,
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
        drop(unsafe { Box::from_raw(operation) });
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
    match TcpListener::bind(SocketAddr::new(ip, port)).and_then(|listener| {
        listener.set_nonblocking(true)?;
        Ok(listener)
    }) {
        Ok(listener) => Box::into_raw(Box::new(TecsNetServer {
            listener,
            accepted: None,
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
            server.accepted = Some(stream(socket)?);
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
    match UdpSocket::bind(SocketAddr::new(ip, port)).and_then(|socket| {
        socket.set_nonblocking(true)?;
        Ok(socket)
    }) {
        Ok(socket) => Box::into_raw(Box::new(TecsNetDatagram { socket })),
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
        return 0;
    }
    let data = match unsafe { bytes(data, length) } {
        Ok(data) => data,
        Err(error) => {
            set_error(error);
            return 0;
        }
    };
    // SAFETY: The caller supplies live socket and address values.
    let destination = SocketAddr::new(unsafe { (*address).address }, port);
    match unsafe { (*socket).socket.send_to(data, destination) } {
        Ok(sent) if sent == data.len() => 1,
        Ok(sent) => {
            set_error(format!("sent {sent} of {} datagram bytes", data.len()));
            0
        }
        Err(error) => {
            set_error(error);
            0
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
