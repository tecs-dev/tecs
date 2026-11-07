//! The Decoder and Effect ABIs: how a separately built library plays a kind
//! of Sound, or processes a strip's signal, inside this mixer.
//!
//! Each is a versioned C vtable a library hands over as a pointer. Tecs owns
//! the queue, the scheduling and the timing, so an implementation only
//! renders, or processes, and applies what it is given on the frames it is
//! given: every one gets sample-accurate scheduling for free.
//!
//! Threads. `describe`, `open` and `close` run on a control thread, which is
//! any thread but the audio thread: allocate there. `render`, `event`,
//! `process`, `param` and `reset` run on the audio thread, under the rules
//! the mixer keeps itself: no allocation, no lock, no blocking. `seek` runs
//! on a control thread. A library must not assume which control thread.
//!
//! Compatibility. `abi_version` must equal the version this crate speaks, and
//! `struct_size` must be at least the size of the vtable this crate reads, so
//! the vtable can grow at its end without breaking a library built earlier.
//!
//! Every function pointer but `seek` is required.

use std::ffi::c_void;

use crate::effects::Effect;
use crate::source::Source;

pub use tecs_audio_abi::*;

/// The smallest vtable sizes this crate reads.
const DECODER_SIZE: usize = std::mem::size_of::<DecoderVTable>();
const EFFECT_SIZE: usize = std::mem::size_of::<EffectVTable>();

/// A Decoder a library registered, checked once.
#[derive(Clone, Copy)]
pub struct Decoder {
    vtable: &'static DecoderVTable,
}

// The vtable is immutable function pointers, which any thread may call
// within the thread rules above.
unsafe impl Send for Decoder {}
unsafe impl Sync for Decoder {}

impl Decoder {
    /// Checks a vtable a library handed over.
    ///
    /// # Safety
    ///
    /// `vtable` must be null or point at a `DecoderVTable` that outlives the
    /// process, as one in a loaded library's static data does.
    pub unsafe fn from_raw(vtable: *const DecoderVTable) -> Result<Decoder, String> {
        if vtable.is_null() {
            return Err("the decoder vtable is null".to_string());
        }
        let table = unsafe { &*vtable };
        if table.abi_version != ABI_VERSION {
            return Err(format!(
                "the decoder speaks ABI {}, and this mixer speaks {}",
                table.abi_version, ABI_VERSION
            ));
        }
        if (table.struct_size as usize) < DECODER_SIZE {
            return Err(format!(
                "the decoder vtable is {} bytes, smaller than the {} this mixer reads",
                table.struct_size, DECODER_SIZE
            ));
        }
        Ok(Decoder { vtable: table })
    }

    /// Asks the format a Sound renders as. Control thread.
    pub fn describe(
        &self,
        params: &[u8],
        bytes: &[u8],
        output_rate: u32,
    ) -> Result<DecoderFormat, String> {
        let mut format = DecoderFormat::default();
        let status = unsafe {
            (self.vtable.describe)(
                params.as_ptr(),
                params.len(),
                bytes.as_ptr(),
                bytes.len(),
                output_rate,
                &mut format,
            )
        };
        if status != 0 {
            return Err(format!(
                "the decoder cannot play this sound (status {status})"
            ));
        }
        if format.channels == 0 || format.channels > crate::source::MAX_CHANNELS as u32 {
            return Err(format!("the decoder reported {} channels", format.channels));
        }
        if format.sample_rate == 0 {
            return Err("the decoder reported a rate of zero".to_string());
        }
        Ok(format)
    }

    /// Builds a Playback's instance as a mixer source. Control thread.
    pub fn open(
        &self,
        params: &[u8],
        bytes: &[u8],
        output_rate: u32,
    ) -> Result<DecodedSource, String> {
        let format = self.describe(params, bytes, output_rate)?;
        let instance = unsafe {
            (self.vtable.open)(
                params.as_ptr(),
                params.len(),
                bytes.as_ptr(),
                bytes.len(),
                output_rate,
            )
        };
        if instance.is_null() {
            return Err("the decoder opened no instance".to_string());
        }
        Ok(DecodedSource {
            decoder: *self,
            instance,
            format,
            rendered: 0,
            ended: false,
        })
    }
}

/// One Playback rendered by a registered Decoder.
pub struct DecodedSource {
    decoder: Decoder,
    instance: *mut c_void,
    format: DecoderFormat,
    rendered: u64,
    ended: bool,
}

// The instance is owned by this value alone, and the thread rules above say
// which thread may call what.
unsafe impl Send for DecodedSource {}

impl Source for DecodedSource {
    fn channels(&self) -> u16 {
        self.format.channels as u16
    }

    fn sample_rate(&self) -> u32 {
        self.format.sample_rate
    }

    fn read(&mut self, out: &mut [f32]) -> usize {
        if self.ended {
            return 0;
        }
        let width = self.format.channels as usize;
        let frames = out.len() / width;
        if frames == 0 {
            return 0;
        }
        let wrote =
            unsafe { (self.decoder.vtable.render)(self.instance, out.as_mut_ptr(), frames as u32) }
                as usize;
        let wrote = wrote.min(frames);
        if wrote < frames {
            self.ended = true;
        }
        self.rendered += wrote as u64;
        wrote
    }

    fn seek(&mut self, seconds: f64) -> bool {
        let Some(seek) = self.decoder.vtable.seek else {
            return false;
        };
        if unsafe { seek(self.instance, seconds) } != 0 {
            return false;
        }
        self.ended = false;
        self.rendered = (seconds.max(0.0) * self.format.sample_rate as f64) as u64;
        true
    }

    fn position(&self) -> f64 {
        self.rendered as f64 / self.format.sample_rate as f64
    }

    fn exhausted(&self) -> bool {
        self.ended
    }

    fn event(&mut self, data: u64) {
        unsafe { (self.decoder.vtable.event)(self.instance, 0, data) };
    }

    fn sequenced(&self) -> bool {
        self.format.flags & FORMAT_SEQUENCED != 0
    }
}

impl Drop for DecodedSource {
    fn drop(&mut self) {
        // The mixer retires sources to a control thread before they drop.
        unsafe { (self.decoder.vtable.close)(self.instance) };
    }
}

/// An Effect a library registered, checked once.
#[derive(Clone, Copy)]
pub struct EffectKind {
    vtable: &'static EffectVTable,
}

unsafe impl Send for EffectKind {}
unsafe impl Sync for EffectKind {}

impl EffectKind {
    /// Checks a vtable a library handed over.
    ///
    /// # Safety
    ///
    /// As for [`Decoder::from_raw`].
    pub unsafe fn from_raw(vtable: *const EffectVTable) -> Result<EffectKind, String> {
        if vtable.is_null() {
            return Err("the effect vtable is null".to_string());
        }
        let table = unsafe { &*vtable };
        if table.abi_version != ABI_VERSION {
            return Err(format!(
                "the effect speaks ABI {}, and this mixer speaks {}",
                table.abi_version, ABI_VERSION
            ));
        }
        if (table.struct_size as usize) < EFFECT_SIZE {
            return Err(format!(
                "the effect vtable is {} bytes, smaller than the {} this mixer reads",
                table.struct_size, EFFECT_SIZE
            ));
        }
        Ok(EffectKind { vtable: table })
    }

    /// Builds an instance for a strip. Control thread.
    pub fn open(&self, params: &[u8], rate: u32, channels: u32) -> Result<Box<dyn Effect>, String> {
        let mut info = EffectInfo::default();
        let status = unsafe {
            (self.vtable.describe)(params.as_ptr(), params.len(), rate, channels, &mut info)
        };
        if status != 0 {
            return Err(format!(
                "the effect refused its parameters (status {status})"
            ));
        }
        let instance = unsafe { (self.vtable.open)(params.as_ptr(), params.len(), rate, channels) };
        if instance.is_null() {
            return Err("the effect opened no instance".to_string());
        }
        Ok(Box::new(AbiEffect {
            kind: *self,
            instance,
            info,
            channels: channels as usize,
        }))
    }
}

struct AbiEffect {
    kind: EffectKind,
    instance: *mut c_void,
    info: EffectInfo,
    channels: usize,
}

unsafe impl Send for AbiEffect {}

impl Effect for AbiEffect {
    fn process(&mut self, buffer: &mut [f32], frames: usize, channels: usize) {
        if channels != self.channels {
            return;
        }
        unsafe { (self.kind.vtable.process)(self.instance, buffer.as_mut_ptr(), frames as u32) };
    }

    fn param(&mut self, id: u32, value: f32) {
        unsafe { (self.kind.vtable.param)(self.instance, id, value, 0) };
    }

    fn reset(&mut self) {
        unsafe { (self.kind.vtable.reset)(self.instance) };
    }

    fn tail_frames(&self) -> u64 {
        self.info.tail
    }

    fn latency_frames(&self) -> u32 {
        self.info.latency
    }
}

impl Drop for AbiEffect {
    fn drop(&mut self) {
        unsafe { (self.kind.vtable.close)(self.instance) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A decoder rendering a constant level for a fixed number of frames,
    /// whose events set the level, to prove the vtable round trip.
    struct Constant {
        level: f32,
        left: u32,
    }

    unsafe extern "C" fn describe(
        _params: *const u8,
        _params_len: usize,
        _bytes: *const u8,
        _bytes_len: usize,
        output_rate: u32,
        out: *mut DecoderFormat,
    ) -> i32 {
        unsafe {
            *out = DecoderFormat {
                channels: 1,
                sample_rate: output_rate,
                length: -1.0,
                flags: FORMAT_SEQUENCED,
                reserved: 0,
            }
        };
        0
    }

    unsafe extern "C" fn open(
        _params: *const u8,
        _params_len: usize,
        _bytes: *const u8,
        _bytes_len: usize,
        _output_rate: u32,
    ) -> *mut c_void {
        Box::into_raw(Box::new(Constant {
            level: 0.5,
            left: 100,
        })) as *mut c_void
    }

    unsafe extern "C" fn render(instance: *mut c_void, out: *mut f32, frames: u32) -> u32 {
        let state = unsafe { &mut *(instance as *mut Constant) };
        let count = frames.min(state.left);
        for index in 0..count as usize {
            unsafe { *out.add(index) = state.level };
        }
        state.left -= count;
        count
    }

    unsafe extern "C" fn event(instance: *mut c_void, _frame: u32, data: u64) {
        let state = unsafe { &mut *(instance as *mut Constant) };
        state.level = data as f32 / 100.0;
    }

    unsafe extern "C" fn close(instance: *mut c_void) {
        drop(unsafe { Box::from_raw(instance as *mut Constant) });
    }

    static CONSTANT: DecoderVTable = DecoderVTable {
        abi_version: ABI_VERSION,
        struct_size: std::mem::size_of::<DecoderVTable>() as u32,
        describe,
        open,
        render,
        event,
        seek: None,
        close,
    };

    #[test]
    fn a_vtable_decoder_renders_takes_events_and_ends() {
        let decoder = unsafe { Decoder::from_raw(&CONSTANT) }.expect("a valid vtable");
        let mut source = decoder.open(&[], &[], 48_000).expect("an instance");
        assert!(source.sequenced());
        let mut out = [0.0f32; 10];
        assert_eq!(source.read(&mut out), 10);
        assert_eq!(out[0], 0.5);
        source.event(25);
        source.read(&mut out);
        assert_eq!(out[0], 0.25);
        let mut rest = [0.0f32; 200];
        assert_eq!(source.read(&mut rest), 80);
        assert!(source.exhausted());
    }

    #[test]
    fn a_vtable_from_another_version_is_refused() {
        static OLD: DecoderVTable = DecoderVTable {
            abi_version: 0,
            struct_size: std::mem::size_of::<DecoderVTable>() as u32,
            describe,
            open,
            render,
            event,
            seek: None,
            close,
        };
        assert!(unsafe { Decoder::from_raw(&OLD) }.is_err());
        assert!(unsafe { Decoder::from_raw(std::ptr::null()) }.is_err());
    }
}
