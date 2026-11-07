//! General MIDI for tecs, as an extension: a SoundFont synthesizer
//! (`rustysynth`) behind the Decoder ABI.
//!
//! A game loads a SoundFont through `tecs_gm_load_font`, which returns an id
//! this library keeps the font under, and plays a synthesizer by opening a
//! Playback through the Decoder `tecs_gm_decoder` returns, with the font id
//! in its parameters. MIDI arrives as Decoder events on the mixer's one
//! clock, which tecs schedules: this library only renders and applies them.
//!
//! `rustysynth` applies MIDI between blocks of eight frames, its finest, so
//! an event lands within seven frames of its time.
//!
//! A SoundFont that does not parse is refused with a reason rather than
//! aborting the process: the parser runs under `catch_unwind`, and nothing
//! here unwinds across the C ABI.

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::io::Cursor;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex, OnceLock};

use rustysynth::{SoundFont, Synthesizer, SynthesizerSettings};
use tecs_audio_abi::{
    split_event, DecoderFormat, DecoderVTable, ABI_VERSION, EVENT_OP_MESSAGE, EVENT_OP_NOTES_OFF,
    EVENT_OP_RESET, FORMAT_SEQUENCED,
};

/// Frames between the points MIDI applies at.
pub const BLOCK_FRAMES: usize = 8;

/// The parameters a Playback opens with, as the bytes `params` points at.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Params {
    /// The id `tecs_gm_load_font` returned.
    pub font: u64,
    /// Notes sounding at once, 8 to 256.
    pub polyphony: u32,
    /// Non-zero runs the reverb and chorus.
    pub effects: u32,
}

/// Every loaded font, by id.
fn fonts() -> &'static Mutex<HashMap<u64, Arc<SoundFont>>> {
    static FONTS: OnceLock<Mutex<HashMap<u64, Arc<SoundFont>>>> = OnceLock::new();
    FONTS.get_or_init(|| Mutex::new(HashMap::new()))
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

/// Parses SoundFont 2 bytes, refusing what is not one with a reason, and a
/// parser panic as a reason too.
pub fn parse_font(name: &str, bytes: &[u8]) -> Result<Arc<SoundFont>, String> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"sfbk" {
        return Err(format!("'{name}' is not a SoundFont 2 file"));
    }
    let parsed = catch_unwind(AssertUnwindSafe(|| SoundFont::new(&mut Cursor::new(bytes))));
    match parsed {
        Err(_) => Err(format!(
            "'{name}' is malformed: the SoundFont parser gave up on it"
        )),
        Ok(Err(error)) => Err(format!("'{name}' is not a readable SoundFont: {error}")),
        Ok(Ok(font)) => Ok(Arc::new(font)),
    }
}

/// Keeps a parsed font and returns its id.
pub fn keep_font(font: Arc<SoundFont>) -> u64 {
    let id = next_id();
    if let Ok(mut held) = fonts().lock() {
        held.insert(id, font);
    }
    id
}

/// Loads a SoundFont file and returns its id, or zero with a reason
/// `tecs_gm_last_error` reads.
///
/// # Safety
///
/// `path` must be a NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn tecs_gm_load_font(path: *const c_char) -> u64 {
    if path.is_null() {
        return fail("no path".to_string());
    }
    let Ok(path) = (unsafe { CStr::from_ptr(path) }).to_str() else {
        return fail("the path is not UTF-8".to_string());
    };
    match std::fs::read(path) {
        Err(error) => fail(format!("cannot open '{path}': {error}")),
        Ok(bytes) => match parse_font(path, &bytes) {
            Err(reason) => fail(reason),
            Ok(font) => keep_font(font),
        },
    }
}

/// Loads a SoundFont from bytes in memory and returns its id, or zero.
///
/// # Safety
///
/// `bytes` must hold `length` bytes.
#[no_mangle]
pub unsafe extern "C" fn tecs_gm_load_font_bytes(bytes: *const u8, length: u64) -> u64 {
    if bytes.is_null() {
        return fail("no bytes".to_string());
    }
    let slice = unsafe { std::slice::from_raw_parts(bytes, length as usize) };
    match parse_font("SoundFont bytes", slice) {
        Err(reason) => fail(reason),
        Ok(font) => keep_font(font),
    }
}

/// Lets go of a font. A synthesizer still playing it keeps it alive.
#[no_mangle]
pub extern "C" fn tecs_gm_release_font(font: u64) {
    if let Ok(mut held) = fonts().lock() {
        held.remove(&font);
    }
}

/// Returns the reason the last load failed, valid until the next failure.
#[no_mangle]
pub extern "C" fn tecs_gm_last_error() -> *const c_char {
    match last_error().lock() {
        Err(_) => std::ptr::null(),
        Ok(slot) => slot.as_ptr(),
    }
}

/// Returns the General MIDI Decoder's vtable.
#[no_mangle]
pub extern "C" fn tecs_gm_decoder() -> *const DecoderVTable {
    &VTABLE
}

/// One synthesizer, rendering into a block it hands out a frame at a time.
struct Instance {
    synthesizer: Synthesizer,
    left: [f32; BLOCK_FRAMES],
    right: [f32; BLOCK_FRAMES],
    cursor: usize,
}

fn read_params(params: *const u8, params_len: usize) -> Option<Params> {
    if params.is_null() || params_len < std::mem::size_of::<Params>() {
        return None;
    }
    Some(unsafe { std::ptr::read_unaligned(params as *const Params) })
}

fn build(params: *const u8, params_len: usize, output_rate: u32) -> Option<Instance> {
    let params = read_params(params, params_len)?;
    let font = fonts().lock().ok()?.get(&params.font).cloned()?;
    let mut settings = SynthesizerSettings::new(i32::try_from(output_rate).ok()?);
    settings.block_size = BLOCK_FRAMES;
    settings.maximum_polyphony = (params.polyphony as usize).clamp(8, 256);
    settings.enable_reverb_and_chorus = params.effects != 0;
    let synthesizer = catch_unwind(AssertUnwindSafe(|| Synthesizer::new(&font, &settings)))
        .ok()?
        .ok()?;
    Some(Instance {
        synthesizer,
        left: [0.0; BLOCK_FRAMES],
        right: [0.0; BLOCK_FRAMES],
        cursor: BLOCK_FRAMES,
    })
}

unsafe extern "C" fn describe(
    params: *const u8,
    params_len: usize,
    _bytes: *const u8,
    _bytes_len: usize,
    output_rate: u32,
    out: *mut DecoderFormat,
) -> i32 {
    let Some(params) = read_params(params, params_len) else {
        return 1;
    };
    let known = fonts()
        .lock()
        .map(|held| held.contains_key(&params.font))
        .unwrap_or(false);
    if !known || out.is_null() {
        return 2;
    }
    unsafe {
        *out = DecoderFormat {
            channels: 2,
            sample_rate: output_rate,
            length: -1.0,
            flags: FORMAT_SEQUENCED,
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
    output_rate: u32,
) -> *mut c_void {
    match build(params, params_len, output_rate) {
        None => std::ptr::null_mut(),
        Some(instance) => Box::into_raw(Box::new(instance)) as *mut c_void,
    }
}

unsafe extern "C" fn render(instance: *mut c_void, out: *mut f32, frames: u32) -> u32 {
    let state = unsafe { &mut *(instance as *mut Instance) };
    let target = unsafe { std::slice::from_raw_parts_mut(out, frames as usize * 2) };
    for frame in target.as_chunks_mut::<2>().0 {
        if state.cursor == BLOCK_FRAMES {
            state.synthesizer.render(&mut state.left, &mut state.right);
            state.cursor = 0;
        }
        frame[0] = state.left[state.cursor];
        frame[1] = state.right[state.cursor];
        state.cursor += 1;
    }
    frames
}

unsafe extern "C" fn event(instance: *mut c_void, _frame: u32, data: u64) {
    let state = unsafe { &mut *(instance as *mut Instance) };
    let (op, payload) = split_event(data);
    match op {
        EVENT_OP_MESSAGE => {
            let status = (payload & 0xFF) as i32;
            // System messages carry no channel, and a synthesizer has no use
            // for any of them.
            if status < 0xF0 {
                state.synthesizer.process_midi_message(
                    status & 0x0F,
                    status & 0xF0,
                    ((payload >> 8) & 0x7F) as i32,
                    ((payload >> 16) & 0x7F) as i32,
                );
            }
        }
        EVENT_OP_NOTES_OFF => {
            let immediate = payload & 1 != 0;
            let channel = (payload >> 8) & 0xFF;
            if channel == 0xFF {
                state.synthesizer.note_off_all(immediate);
            } else {
                state
                    .synthesizer
                    .note_off_all_channel(channel as i32, immediate);
            }
        }
        EVENT_OP_RESET => state.synthesizer.reset(),
        _ => {}
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
    seek: None,
    close,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_bytes_that_are_not_a_soundfont_without_aborting() {
        assert!(parse_font("junk", b"not a soundfont").is_err());
        // A RIFF sfbk header over garbage reaches the parser, which must
        // answer with a reason rather than take the process down.
        let mut bytes = b"RIFF\x10\x00\x00\x00sfbk".to_vec();
        bytes.extend_from_slice(&[0xFF; 64]);
        assert!(parse_font("garbage", &bytes).is_err());
    }

    #[test]
    fn describes_nothing_for_an_unknown_font() {
        let params = Params {
            font: 999_999,
            polyphony: 64,
            effects: 0,
        };
        let mut format = DecoderFormat::default();
        let status = unsafe {
            describe(
                &params as *const Params as *const u8,
                std::mem::size_of::<Params>(),
                std::ptr::null(),
                0,
                48_000,
                &mut format,
            )
        };
        assert_ne!(status, 0);
    }

    /// Renders a note through the vtable when `TECS_TEST_SOUNDFONT` names a
    /// SoundFont, which CI does not have.
    #[test]
    fn renders_a_note_through_the_vtable() {
        let Ok(path) = std::env::var("TECS_TEST_SOUNDFONT") else {
            return;
        };
        let bytes = std::fs::read(&path).expect("the font reads");
        let font = keep_font(parse_font(&path, &bytes).expect("a SoundFont"));
        let params = Params {
            font,
            polyphony: 32,
            effects: 0,
        };
        let pointer = &params as *const Params as *const u8;
        let size = std::mem::size_of::<Params>();
        let instance = unsafe { open(pointer, size, std::ptr::null(), 0, 48_000) };
        assert!(!instance.is_null());
        unsafe { event(instance, 0, tecs_audio_abi::midi_event(0x90, 60, 100)) };
        let mut out = vec![0.0f32; 2 * 4800];
        unsafe { render(instance, out.as_mut_ptr(), 4800) };
        assert!(out.iter().any(|value| value.abs() > 1e-3));
        unsafe { close(instance) };
    }
}
