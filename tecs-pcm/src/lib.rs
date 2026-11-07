//! Encoded audio files for tecs, as an extension: symphonia's decoders behind
//! the Decoder ABI.
//!
//! A game that plays recorded sound brings this; one that does not, a chiptune
//! game on `tecs-ymfm` alone for instance, carries no codec at all.
//!
//! A clip is loaded once, process-wide, under an id this library hands out:
//! resident, decoded whole into memory and shared by every Playback of it, or
//! streamed, decoded a block at a time on one feeder thread as it plays. A
//! Playback opens through the Decoder `tecs_pcm_decoder` returns, with the
//! clip's id as its parameters, so starting a voice copies nothing.
//!
//! A streamed Playback whose feeder falls behind plays silence for what is
//! missing rather than ending: the voice goes on when the blocks arrive.

pub mod decode;
pub mod source;
pub mod stream;

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::{Arc, Mutex, OnceLock, RwLock};

use source::{ResidentSource, Source};
use stream::Feeder;
use tecs_audio_abi::{DecoderFormat, DecoderVTable, ABI_VERSION};

/// Measures a clip's duration against the streaming threshold.
pub const MODE_AUTO: u32 = 0;
/// Decodes a clip whole into memory.
pub const MODE_RESIDENT: u32 = 1;
/// Streams a clip from its file as it plays.
pub const MODE_STREAM: u32 = 2;

/// What a load reports about a clip.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct ClipInfo {
    /// Seconds, or a negative number when the file does not say.
    pub duration: f64,
    pub channels: u32,
    pub sample_rate: u32,
    /// One when the clip is held decoded, zero when it streams.
    pub resident: u32,
    pub reserved: u32,
}

/// The parameters a Playback opens with: the clip's id.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Params {
    pub clip: u64,
}

enum Clip {
    Resident {
        samples: Arc<[f32]>,
        channels: u16,
        sample_rate: u32,
    },
    Streamed {
        path: String,
        channels: u16,
        sample_rate: u32,
        duration: Option<f64>,
    },
}

fn clips() -> &'static RwLock<HashMap<u64, Clip>> {
    static CLIPS: OnceLock<RwLock<HashMap<u64, Clip>>> = OnceLock::new();
    CLIPS.get_or_init(|| RwLock::new(HashMap::new()))
}

fn feeder() -> &'static Feeder {
    static FEEDER: OnceLock<Feeder> = OnceLock::new();
    FEEDER.get_or_init(Feeder::start)
}

fn next_id() -> u64 {
    static NEXT: Mutex<u64> = Mutex::new(0);
    let mut next = NEXT.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    *next += 1;
    *next
}

fn last_error() -> &'static Mutex<CString> {
    static LAST: OnceLock<Mutex<CString>> = OnceLock::new();
    LAST.get_or_init(|| Mutex::new(CString::default()))
}

fn fail(reason: String) -> u64 {
    if let Ok(mut slot) = last_error().lock() {
        *slot = CString::new(reason).unwrap_or_default();
    }
    0
}

fn keep(clip: Clip, info: *mut ClipInfo) -> u64 {
    let report = match &clip {
        Clip::Resident {
            samples,
            channels,
            sample_rate,
        } => ClipInfo {
            duration: samples.len() as f64
                / (*channels).max(1) as f64
                / (*sample_rate).max(1) as f64,
            channels: u32::from(*channels),
            sample_rate: *sample_rate,
            resident: 1,
            reserved: 0,
        },
        Clip::Streamed {
            channels,
            sample_rate,
            duration,
            ..
        } => ClipInfo {
            duration: duration.unwrap_or(-1.0),
            channels: u32::from(*channels),
            sample_rate: *sample_rate,
            resident: 0,
            reserved: 0,
        },
    };
    if !info.is_null() {
        unsafe { *info = report };
    }
    let id = next_id();
    if let Ok(mut held) = clips().write() {
        held.insert(id, clip);
    }
    id
}

fn resident(label: &str, decoded: decode::Decoded) -> Result<Clip, String> {
    if decoded.channels == 0 || usize::from(decoded.channels) > source::MAX_CHANNELS {
        return Err(format!(
            "'{label}' has {} channels, and the mixer carries at most {}",
            decoded.channels,
            source::MAX_CHANNELS
        ));
    }
    Ok(Clip::Resident {
        samples: decoded.samples.into(),
        channels: decoded.channels,
        sample_rate: decoded.sample_rate,
    })
}

/// Loads a clip from a file, resident, streamed, or as its duration against
/// `stream_seconds` decides, and returns its id.
pub fn load(path: &str, mode: u32, stream_seconds: f32) -> Result<(u64, ClipInfo), String> {
    let duration = match mode {
        MODE_RESIDENT => None,
        _ => decode::probe_duration(path)?,
    };
    let stream = match mode {
        MODE_RESIDENT => false,
        MODE_STREAM => true,
        _ => duration.is_some_and(|seconds| seconds > stream_seconds as f64),
    };
    let clip = if stream {
        let streamer = decode::Streamer::open(path)?;
        let (channels, sample_rate) = (streamer.channels(), streamer.sample_rate());
        Clip::Streamed {
            path: path.to_string(),
            channels,
            sample_rate,
            duration,
        }
    } else {
        resident(path, decode::decode_all(path)?)?
    };
    let mut info = ClipInfo::default();
    let id = keep(clip, &mut info);
    Ok((id, info))
}

/// Loads a clip from the bytes of an encoded file, resident.
pub fn load_bytes(name: &str, bytes: &[u8]) -> Result<(u64, ClipInfo), String> {
    let clip = resident(name, decode::decode_bytes(name, bytes)?)?;
    let mut info = ClipInfo::default();
    let id = keep(clip, &mut info);
    Ok((id, info))
}

/// Loads a clip from a file and returns its id, or zero with a reason
/// `tecs_pcm_last_error` reads.
///
/// # Safety
///
/// `path` must be a NUL-terminated UTF-8 string and `info` null or writable.
#[no_mangle]
pub unsafe extern "C" fn tecs_pcm_load(
    path: *const c_char,
    mode: u32,
    stream_seconds: f32,
    info: *mut ClipInfo,
) -> u64 {
    if path.is_null() {
        return fail("no path".to_string());
    }
    let Ok(text) = (unsafe { CStr::from_ptr(path) }).to_str() else {
        return fail("the path is not UTF-8".to_string());
    };
    match load(text, mode, stream_seconds) {
        Err(reason) => fail(reason),
        Ok((id, found)) => {
            if !info.is_null() {
                unsafe { *info = found };
            }
            id
        }
    }
}

/// Loads a clip from the bytes of an encoded file, resident, and returns its
/// id, or zero with a reason.
///
/// # Safety
///
/// `name` must be a NUL-terminated UTF-8 string, `bytes` hold `length`
/// bytes, and `info` be null or writable.
#[no_mangle]
pub unsafe extern "C" fn tecs_pcm_load_bytes(
    name: *const c_char,
    bytes: *const u8,
    length: u64,
    info: *mut ClipInfo,
) -> u64 {
    if name.is_null() || bytes.is_null() {
        return fail("no name or no bytes".to_string());
    }
    let Ok(label) = (unsafe { CStr::from_ptr(name) }).to_str() else {
        return fail("the name is not UTF-8".to_string());
    };
    let slice = unsafe { std::slice::from_raw_parts(bytes, length as usize) };
    match load_bytes(label, slice) {
        Err(reason) => fail(reason),
        Ok((id, found)) => {
            if !info.is_null() {
                unsafe { *info = found };
            }
            id
        }
    }
}

/// Lets go of a clip. Playbacks already reading it keep its samples.
#[no_mangle]
pub extern "C" fn tecs_pcm_release(clip: u64) {
    if let Ok(mut held) = clips().write() {
        held.remove(&clip);
    }
}

/// Returns the reason the last load failed, valid until the next failure.
#[no_mangle]
pub extern "C" fn tecs_pcm_last_error() -> *const c_char {
    match last_error().lock() {
        Err(_) => std::ptr::null(),
        Ok(slot) => slot.as_ptr(),
    }
}

/// Returns the codecs this build links, joined by commas, valid for the
/// life of the process.
#[no_mangle]
pub extern "C" fn tecs_pcm_codecs() -> *const c_char {
    static NAMES: OnceLock<CString> = OnceLock::new();
    NAMES
        .get_or_init(|| CString::new(decode::decoder_names().join(",")).unwrap_or_default())
        .as_ptr()
}

/// Returns the PCM Decoder's vtable.
#[no_mangle]
pub extern "C" fn tecs_pcm_decoder() -> *const DecoderVTable {
    &VTABLE
}

/// One Playback: a resident clip's shared samples, or a stream.
struct Instance {
    source: Box<dyn Source>,
    channels: usize,
}

fn params_of(params: *const u8, params_len: usize) -> Option<u64> {
    if params.is_null() || params_len < std::mem::size_of::<Params>() {
        return None;
    }
    Some(unsafe { std::ptr::read_unaligned(params as *const Params) }.clip)
}

unsafe extern "C" fn describe(
    params: *const u8,
    params_len: usize,
    _bytes: *const u8,
    _bytes_len: usize,
    _output_rate: u32,
    out: *mut DecoderFormat,
) -> i32 {
    let Some(id) = params_of(params, params_len) else {
        return 1;
    };
    let Ok(held) = clips().read() else {
        return 2;
    };
    let Some(clip) = held.get(&id) else {
        return 3;
    };
    let (channels, sample_rate, length) = match clip {
        Clip::Resident {
            samples,
            channels,
            sample_rate,
        } => (
            *channels,
            *sample_rate,
            samples.len() as f64 / (*channels).max(1) as f64 / (*sample_rate).max(1) as f64,
        ),
        Clip::Streamed {
            channels,
            sample_rate,
            duration,
            ..
        } => (*channels, *sample_rate, duration.unwrap_or(-1.0)),
    };
    unsafe {
        *out = DecoderFormat {
            channels: u32::from(channels),
            sample_rate,
            length,
            flags: 0,
            reserved: 0,
        }
    };
    0
}

unsafe extern "C" fn open(
    params: *const u8,
    params_len: usize,
    _bytes: *const u8,
    _bytes_len: usize,
    _output_rate: u32,
) -> *mut c_void {
    let Some(id) = params_of(params, params_len) else {
        return std::ptr::null_mut();
    };
    let (source, channels): (Box<dyn Source>, u16) = {
        let Ok(held) = clips().read() else {
            return std::ptr::null_mut();
        };
        match held.get(&id) {
            None => return std::ptr::null_mut(),
            Some(Clip::Resident {
                samples,
                channels,
                sample_rate,
            }) => (
                Box::new(ResidentSource::new(
                    Arc::clone(samples),
                    *channels,
                    *sample_rate,
                )),
                *channels,
            ),
            Some(Clip::Streamed { path, channels, .. }) => {
                let path = path.clone();
                let channels = *channels;
                drop(held);
                match decode::Streamer::open(&path) {
                    Err(reason) => {
                        fail(reason);
                        return std::ptr::null_mut();
                    }
                    Ok(streamer) => (Box::new(feeder().attach(streamer, 0.0)), channels),
                }
            }
        }
    };
    Box::into_raw(Box::new(Instance {
        source,
        channels: usize::from(channels).max(1),
    })) as *mut c_void
}

unsafe extern "C" fn render(instance: *mut c_void, out: *mut f32, frames: u32) -> u32 {
    let state = unsafe { &mut *(instance as *mut Instance) };
    let width = state.channels;
    let target = unsafe { std::slice::from_raw_parts_mut(out, frames as usize * width) };
    let mut done = 0;
    while done < frames as usize {
        let wrote = state.source.read(&mut target[done * width..]);
        if wrote == 0 {
            if state.source.exhausted() {
                // The end: fewer frames than asked tells the mixer so.
                return done as u32;
            }
            // A stream whose feeder is behind: silence for what is missing,
            // and the voice goes on.
            target[done * width..].fill(0.0);
            return frames;
        }
        done += wrote;
    }
    frames
}

unsafe extern "C" fn event(_instance: *mut c_void, _frame: u32, _data: u64) {}

unsafe extern "C" fn seek(instance: *mut c_void, seconds: f64) -> i32 {
    let state = unsafe { &mut *(instance as *mut Instance) };
    if state.source.seek(seconds.max(0.0)) {
        0
    } else {
        1
    }
}

unsafe extern "C" fn close(instance: *mut c_void) {
    drop(unsafe { Box::from_raw(instance as *mut Instance) });
}

static VTABLE: DecoderVTable = DecoderVTable {
    abi_version: ABI_VERSION,
    struct_size: std::mem::size_of::<DecoderVTable>() as u32,
    describe,
    open,
    render,
    event,
    seek: Some(seek),
    close,
};
