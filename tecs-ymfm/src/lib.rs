//! Emulated Yamaha FM chips for tecs, as an extension behind the Decoder ABI.
//!
//! The chip is any of the 24 that [`ymfm_oxide`], a pure-Rust port of ymfm,
//! emulates: the OPL family with the OPL4, the OPLL family, the OPM and OPP,
//! the OPN family with its SSG and ADPCM, the OPZ, the OPQ and the YM2149.
//! A Playback opens one chip, by kind and input clock in its parameters, with
//! the memory images it reads (ADPCM and PCM ROMs) in its bytes. Register
//! writes arrive as Decoder events on the mixer's one clock, which tecs
//! schedules: the mixer reads a sequenced Decoder a frame at a time, so a
//! write lands within a sample of its time, and writes due on one frame
//! apply in the order they were sent.
//!
//! Each chip renders at its own rate, the one ymfm gives its clock, and the
//! mixer resamples it. Three chips render faster than any output needs, and
//! for those consecutive samples are averaged into one frame
//! ([`Kind::decimation`]). Every chip's outputs fold to one stereo pair
//! ([`Kind::outputs`]), and a chip with an SSG has its direct current removed.

use std::ffi::{c_char, c_void, CStr};

use tecs_audio_abi::{
    split_event, DecoderFormat, DecoderVTable, ABI_VERSION, EVENT_OP_MESSAGE, EVENT_OP_PORT,
    EVENT_OP_RESET, EVENT_OP_SHIFT, FORMAT_SEQUENCED,
};

use ymfm_oxide::misc::Ym2149;
use ymfm_oxide::opl::{
    Ds1001, Ym2413, Ym2423, Ym3526, Ym3812, Ymf262, Ymf278b, Ymf281, Ymf289b, Y8950,
};
use ymfm_oxide::opm::{Ym2151, Ym2164};
use ymfm_oxide::opn::{
    OpnFidelity, Ym2203, Ym2608, Ym2610, Ym2610b, Ym2612, Ym3438, Ymf276, Ymf288,
};
use ymfm_oxide::opq::{Ym3533, Ym3806};
use ymfm_oxide::opz::Ym2414;
use ymfm_oxide::{AccessClass, Interface, Output};

/// The input clock of an OPL2, the NTSC colour burst a sound card divides
/// down: 3.579545 MHz. The OPL3 takes four times it.
pub const OPL2_CLOCK: u32 = 3_579_545;

/// The input clock of an OPL3: 14.31818 MHz.
pub const OPL3_CLOCK: u32 = 4 * OPL2_CLOCK;

/// The rate an OPL2 or an OPL3 renders at on its usual clock, in hertz: the
/// input clock over 72 on the OPL2 and over 288 on the OPL3, 49 715.9 Hz,
/// which the emulator truncates to a whole rate.
pub const RATE: u32 = 49_715;

/// The fastest clock a chip's source runs at. A chip whose emulator renders
/// faster has consecutive samples averaged into one frame, as many as it takes
/// to come under this.
pub const MAX_RATE: u32 = 64_000;

/// The slowest input clock a chip is made with: below it the slowest chip's
/// rate falls under two thousand frames a second.
pub const MIN_CLOCK: u32 = 100_000;

/// The fastest input clock a chip is made with, three times the OPL4's.
pub const MAX_CLOCK: u32 = 100_000_000;

/// The largest memory image one class takes: sixteen megabytes, which covers
/// the 24-bit address space of every ADPCM and PCM engine ymfm has.
pub const MAX_IMAGE: usize = 16 * 1024 * 1024;

/// Selects which chip to emulate.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    /// The YM3526 (OPL): nine 2-operator channels, one sine wave, mono.
    Ym3526,
    /// The Y8950 (MSX-Audio): an OPL with an ADPCM-B channel reading
    /// external memory, mono.
    Y8950,
    /// The YM3812 (OPL2): nine 2-operator channels, four waveforms, mono.
    Ym3812,
    /// The YMF262 (OPL3): eighteen channels that pair into 4-operator
    /// voices, eight waveforms, and stereo from the pan bits of 0xC0 to 0xC8.
    Ymf262,
    /// The YMF289B (OPL3L): an OPL3 with two outputs.
    Ymf289b,
    /// The YMF278B (OPL4): an OPL3 and a 24-voice PCM wavetable reading
    /// external memory, the PCM registers in a third bank.
    Ymf278b,
    /// The YM2413 (OPLL): nine channels on fifteen built-in instruments and
    /// one the registers define, with ymfm's copyright-free stand-in for the
    /// instrument ROM.
    Ym2413,
    /// The YM2423 (OPLL-X), an OPLL with another instrument set.
    Ym2423,
    /// The YMF281 (OPLLP), an OPLL with another instrument set.
    Ymf281,
    /// The DS1001 (Konami VRC7): six OPLL channels and its own instruments.
    Ds1001,
    /// The YM2151 (OPM): eight 4-operator channels, stereo.
    Ym2151,
    /// The YM2164 (OPP), an OPM variant.
    Ym2164,
    /// The YM2203 (OPN): three 4-operator channels and a 3-channel SSG,
    /// mono.
    Ym2203,
    /// The YM2608 (OPNA): six FM channels, the SSG, six ADPCM-A rhythm
    /// channels on a ROM and an ADPCM-B channel, stereo.
    Ym2608,
    /// The YMF288 (OPN3L), an OPNA with its rhythm ROM built in.
    Ymf288,
    /// The YM2610 (OPNB): four FM channels, the SSG and ADPCM-A and ADPCM-B
    /// from external memory, stereo.
    Ym2610,
    /// The YM2610B (OPNB2): the YM2610 with all six FM channels.
    Ym2610b,
    /// The YM2612 (OPN2): six FM channels, one of them a DAC, stereo.
    Ym2612,
    /// The YM3438 (OPN2C), the CMOS YM2612.
    Ym3438,
    /// The YMF276 (OPN2L), the low-voltage YM3438.
    Ymf276,
    /// The YM2414 (OPZ): eight 4-operator channels, eight waveforms, stereo.
    Ym2414,
    /// The YM3806 (OPQ): eight 4-operator channels, stereo, written by
    /// register address directly rather than through an address port.
    Ym3806,
    /// The YM3533, an OPQ variant.
    Ym3533,
    /// The YM2149 (SSG), the AY-3-8910 family: three square-wave channels,
    /// noise and an envelope.
    Ym2149,
}

/// Where a chip's registers sit among its ports.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Layout {
    /// Banks of 256 registers, each written through an address port and then
    /// a data port, given as `(address, data)` offsets per bank.
    Banks(&'static [(u16, u16)]),
    /// One register file written by address directly: the offset is the
    /// register.
    Direct,
}

const ONE_BANK: &[(u16, u16)] = &[(0, 1)];
const TWO_BANKS: &[(u16, u16)] = &[(0, 1), (2, 3)];
const THREE_BANKS: &[(u16, u16)] = &[(0, 1), (2, 3), (4, 5)];
const SSG_BANK: &[(u16, u16)] = &[(0, 2)];

/// The last register the OPQ decodes.
const OPQ_LAST_REGISTER: u16 = 0x11f;

/// A class of external memory a chip reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MemoryClass {
    /// ADPCM-A sample ROM: the YM2608's rhythm ROM, the YM2610's sample ROM.
    AdpcmA,
    /// ADPCM-B sample ROM or RAM: the Y8950's, the YM2608's and the YM2610's.
    AdpcmB,
    /// PCM wavetable ROM and RAM: the OPL4's.
    Pcm,
}

impl MemoryClass {
    /// Every class, in the order of their wire numbers.
    pub const ALL: [MemoryClass; 3] = [MemoryClass::AdpcmA, MemoryClass::AdpcmB, MemoryClass::Pcm];

    /// Returns the class a wire number names: 0, 1 or 2.
    pub fn from_index(index: u32) -> Option<MemoryClass> {
        MemoryClass::ALL.get(index as usize).copied()
    }

    /// Returns the wire number the class crosses the C ABI as.
    pub const fn index(self) -> u8 {
        match self {
            MemoryClass::AdpcmA => 0,
            MemoryClass::AdpcmB => 1,
            MemoryClass::Pcm => 2,
        }
    }

    fn of(access: AccessClass) -> Option<MemoryClass> {
        match access {
            AccessClass::AdpcmA => Some(MemoryClass::AdpcmA),
            AccessClass::AdpcmB => Some(MemoryClass::AdpcmB),
            AccessClass::Pcm => Some(MemoryClass::Pcm),
            AccessClass::Io => None,
        }
    }
}

/// How one of a chip's outputs reaches the stereo pair.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Route {
    /// The output's index in the chip's order.
    pub output: usize,
    /// The share of it that goes left.
    pub left: f32,
    /// The share of it that goes right.
    pub right: f32,
}

const fn both(output: usize, gain: f32) -> Route {
    Route {
        output,
        left: gain,
        right: gain,
    }
}

const fn left(output: usize) -> Route {
    Route {
        output,
        left: 1.0,
        right: 0.0,
    }
}

const fn right(output: usize) -> Route {
    Route {
        output,
        left: 0.0,
        right: 1.0,
    }
}

/// The share each SSG channel takes of a mono mix of three: two ninths, which
/// puts three of them at two thirds of their sum, the factor ymfm itself
/// applies when it mixes the OPNA's SSG to one output.
pub const SSG_SHARE: f32 = 2.0 / 9.0;

const MONO: &[Route] = &[both(0, 1.0)];
const STEREO: &[Route] = &[left(0), right(1)];
const OPLL: &[Route] = &[both(0, 1.0), both(1, 1.0)];
const OPL4: &[Route] = &[left(4), right(5)];
const OPN: &[Route] = &[
    both(0, 1.0),
    both(1, SSG_SHARE),
    both(2, SSG_SHARE),
    both(3, SSG_SHARE),
];
const OPNA: &[Route] = &[left(0), right(1), both(2, 1.0)];
const SSG: &[Route] = &[both(0, SSG_SHARE), both(1, SSG_SHARE), both(2, SSG_SHARE)];

impl Kind {
    /// Every chip, in the order the module lists them.
    pub const ALL: [Kind; 24] = [
        Kind::Ym3526,
        Kind::Y8950,
        Kind::Ym3812,
        Kind::Ymf262,
        Kind::Ymf289b,
        Kind::Ymf278b,
        Kind::Ym2413,
        Kind::Ym2423,
        Kind::Ymf281,
        Kind::Ds1001,
        Kind::Ym2151,
        Kind::Ym2164,
        Kind::Ym2203,
        Kind::Ym2608,
        Kind::Ymf288,
        Kind::Ym2610,
        Kind::Ym2610b,
        Kind::Ym2612,
        Kind::Ym3438,
        Kind::Ymf276,
        Kind::Ym2414,
        Kind::Ym3806,
        Kind::Ym3533,
        Kind::Ym2149,
    ];

    /// Returns the chip a name selects: its part number in lower case, such
    /// as `"ym2612"`, or `"opl2"` and `"opl3"` for the YM3812 and the YMF262.
    pub fn from_name(name: &str) -> Option<Kind> {
        match name {
            "opl2" => return Some(Kind::Ym3812),
            "opl3" => return Some(Kind::Ymf262),
            _ => {}
        }
        Kind::ALL.into_iter().find(|kind| kind.name() == name)
    }

    /// Returns the chip's part number in lower case, which `from_name` reads.
    pub const fn name(self) -> &'static str {
        match self {
            Kind::Ym3526 => "ym3526",
            Kind::Y8950 => "y8950",
            Kind::Ym3812 => "ym3812",
            Kind::Ymf262 => "ymf262",
            Kind::Ymf289b => "ymf289b",
            Kind::Ymf278b => "ymf278b",
            Kind::Ym2413 => "ym2413",
            Kind::Ym2423 => "ym2423",
            Kind::Ymf281 => "ymf281",
            Kind::Ds1001 => "ds1001",
            Kind::Ym2151 => "ym2151",
            Kind::Ym2164 => "ym2164",
            Kind::Ym2203 => "ym2203",
            Kind::Ym2608 => "ym2608",
            Kind::Ymf288 => "ymf288",
            Kind::Ym2610 => "ym2610",
            Kind::Ym2610b => "ym2610b",
            Kind::Ym2612 => "ym2612",
            Kind::Ym3438 => "ym3438",
            Kind::Ymf276 => "ymf276",
            Kind::Ym2414 => "ym2414",
            Kind::Ym3806 => "ym3806",
            Kind::Ym3533 => "ym3533",
            Kind::Ym2149 => "ym2149",
        }
    }

    /// Returns the input clock the chip usually ran at, in hertz: the one in
    /// the machine it is best known from.
    pub const fn default_clock(self) -> u32 {
        match self {
            Kind::Ymf262 | Kind::Ymf289b => OPL3_CLOCK,
            Kind::Ymf278b => 33_868_800,
            Kind::Ym2203 => 3_993_600,
            Kind::Ym2608 => 7_987_200,
            Kind::Ymf288 => 15_974_400,
            Kind::Ym2610 | Kind::Ym2610b => 8_000_000,
            Kind::Ym2612 | Kind::Ym3438 | Kind::Ymf276 => 7_670_453,
            Kind::Ym2149 => 1_789_772,
            _ => OPL2_CLOCK,
        }
    }

    /// Returns the input clocks per sample the emulator renders at, so that
    /// its rate is the clock over this, truncated.
    ///
    /// The OPN chips with an SSG run at their lowest fidelity, which still
    /// keeps every FM sample and averages the SSG's: the highest renders the
    /// YM2203 at a megahertz for a difference nobody hears.
    pub const fn divider(self) -> u32 {
        match self {
            Kind::Ymf262 | Kind::Ymf289b => 288,
            Kind::Ymf278b => 768,
            Kind::Ym2151 | Kind::Ym2164 | Kind::Ym2414 | Kind::Ym3806 | Kind::Ym3533 => 64,
            Kind::Ym2203 => 24,
            Kind::Ym2608 => 48,
            Kind::Ymf288 | Kind::Ym2610 | Kind::Ym2610b => 144,
            Kind::Ym2612 | Kind::Ym3438 | Kind::Ymf276 => 144,
            Kind::Ym2149 => 64,
            _ => 72,
        }
    }

    /// Returns how many emulator samples make one frame of the chip's clock
    /// at `clock`: one, unless the emulator renders faster than [`MAX_RATE`].
    pub const fn decimation(self, clock: u32) -> u32 {
        let rate = clock / self.divider();
        if rate <= MAX_RATE {
            1
        } else {
            rate.div_ceil(MAX_RATE)
        }
    }

    /// Returns the rate of the chip's clock at `clock`, in frames a second:
    /// the emulator's rate over its decimation.
    pub const fn rate(self, clock: u32) -> u32 {
        clock / self.divider() / self.decimation(clock)
    }

    const fn layout(self) -> Layout {
        match self {
            Kind::Ymf262
            | Kind::Ymf289b
            | Kind::Ym2608
            | Kind::Ymf288
            | Kind::Ym2610
            | Kind::Ym2610b
            | Kind::Ym2612
            | Kind::Ym3438
            | Kind::Ymf276 => Layout::Banks(TWO_BANKS),
            Kind::Ymf278b => Layout::Banks(THREE_BANKS),
            Kind::Ym3806 | Kind::Ym3533 => Layout::Direct,
            Kind::Ym2149 => Layout::Banks(SSG_BANK),
            _ => Layout::Banks(ONE_BANK),
        }
    }

    /// Returns the highest register address the chip decodes, a bank of 256
    /// to each address port: 0xFF on a chip with one, 0x1FF on the OPL3 and
    /// the two-bank OPN chips, whose second bank is 0x100 up, and 0x2FF on the
    /// OPL4, whose PCM registers are the third. The OPQ, which has no address
    /// port, decodes to 0x11F.
    pub const fn last_register(self) -> u16 {
        match self.layout() {
            Layout::Banks(banks) => (banks.len() * 256 - 1) as u16,
            Layout::Direct => OPQ_LAST_REGISTER,
        }
    }

    /// Returns the highest port offset the chip has: 1 on a chip with one
    /// address and one data port, 3 with two of each and on the YM2149, whose
    /// data port is at 2, 5 on the OPL4, and the last register on the OPQ,
    /// whose offset is the register.
    pub const fn last_port(self) -> u16 {
        match self {
            Kind::Ym2149 => 3,
            _ => match self.layout() {
                Layout::Banks(banks) => (banks.len() * 2 - 1) as u16,
                Layout::Direct => OPQ_LAST_REGISTER,
            },
        }
    }

    /// Reports whether the chip reads memory of `class`.
    pub const fn reads(self, class: MemoryClass) -> bool {
        matches!(
            (self, class),
            (Kind::Y8950, MemoryClass::AdpcmB)
                | (
                    Kind::Ym2608 | Kind::Ym2610 | Kind::Ym2610b,
                    MemoryClass::AdpcmA | MemoryClass::AdpcmB
                )
                | (Kind::Ymf278b, MemoryClass::Pcm)
        )
    }

    /// Returns how each of the chip's outputs reaches the stereo pair.
    ///
    /// A mono chip plays its output on both sides. The OPL3 plays outputs A
    /// and B, which its pan bits select, and leaves C and D, which a stereo
    /// card did not wire. The OPL4 plays the mix of its FM and PCM A and B
    /// outputs, its third pair. The OPLL sums its melody and rhythm. The
    /// YM2203 adds its SSG channels to its FM, the YM2608 and the YM2610 add
    /// their mixed SSG to both sides, and the YM2149 mixes its three channels.
    pub const fn outputs(self) -> &'static [Route] {
        match self {
            Kind::Ymf262 | Kind::Ymf289b => STEREO,
            Kind::Ymf278b => OPL4,
            Kind::Ym2413 | Kind::Ym2423 | Kind::Ymf281 | Kind::Ds1001 => OPLL,
            Kind::Ym2151
            | Kind::Ym2164
            | Kind::Ym2612
            | Kind::Ym3438
            | Kind::Ymf276
            | Kind::Ym2414
            | Kind::Ym3806
            | Kind::Ym3533 => STEREO,
            Kind::Ym2203 => OPN,
            Kind::Ym2608 | Kind::Ymf288 | Kind::Ym2610 | Kind::Ym2610b => OPNA,
            Kind::Ym2149 => SSG,
            _ => MONO,
        }
    }

    /// Reports whether the chip plays the same on both sides.
    pub const fn mono(self) -> bool {
        matches!(
            self,
            Kind::Ym3526
                | Kind::Y8950
                | Kind::Ym3812
                | Kind::Ym2413
                | Kind::Ym2423
                | Kind::Ymf281
                | Kind::Ds1001
                | Kind::Ym2203
                | Kind::Ym2149
        )
    }

    /// Reports whether the chip has an SSG, whose output is offset from zero
    /// and is therefore filtered.
    pub const fn has_ssg(self) -> bool {
        matches!(
            self,
            Kind::Ym2203
                | Kind::Ym2608
                | Kind::Ymf288
                | Kind::Ym2610
                | Kind::Ym2610b
                | Kind::Ym2149
        )
    }
}

/// The memory images one chip reads, owned by its [`Fm`] target.
#[derive(Default)]
struct Images {
    adpcm_a: Box<[u8]>,
    adpcm_b: Box<[u8]>,
    pcm: Box<[u8]>,
}

impl Images {
    fn slot(&mut self, class: MemoryClass) -> &mut Box<[u8]> {
        match class {
            MemoryClass::AdpcmA => &mut self.adpcm_a,
            MemoryClass::AdpcmB => &mut self.adpcm_b,
            MemoryClass::Pcm => &mut self.pcm,
        }
    }
}

/// The chip's connection to its memory images: what ymfm calls its interface.
///
/// The images belong to the target, which replaces them between samples, and
/// the chip reads and writes them during one. A chip owns its interface and
/// not every chip lends it back, so the interface reaches the images through
/// a pointer to the allocation the target owns rather than holding them.
/// Timers, busy time and the IRQ line keep ymfm's defaults: nothing here asks
/// for them, because a chip played from a log or by a driver paced on the
/// clock never waits on them.
struct Memory(*mut Images);

// SAFETY: the pointer names an allocation the target owns and frees, and the
// target and the chip holding this move between threads together and are
// used from one thread at a time, through `&mut` on the target.
unsafe impl Send for Memory {}

impl Interface for Memory {
    fn external_read(&mut self, access: AccessClass, address: u32) -> u8 {
        let Some(class) = MemoryClass::of(access) else {
            return 0;
        };
        // SAFETY: see `Memory`. The chip calls this only while the target is
        // generating, and the target touches the images only between
        // samples, so no other reference to them is live.
        let images = unsafe { &mut *self.0 };
        images
            .slot(class)
            .get(address as usize)
            .copied()
            .unwrap_or(0)
    }

    fn external_write(&mut self, access: AccessClass, address: u32, data: u8) {
        let Some(class) = MemoryClass::of(access) else {
            return;
        };
        // SAFETY: as for `external_read`.
        let images = unsafe { &mut *self.0 };
        if let Some(byte) = images.slot(class).get_mut(address as usize) {
            *byte = data;
        }
    }
}

/// One emulated chip, written by port and read as all of its outputs.
///
/// Every chip is boxed, so the enum is a pointer wide and a reset replaces
/// one allocation rather than moving kilobytes of state through the stack.
enum Chip {
    Ym3526(Box<Ym3526<Memory>>),
    Y8950(Box<Y8950<Memory>>),
    Ym3812(Box<Ym3812<Memory>>),
    Ymf262(Box<Ymf262<Memory>>),
    Ymf289b(Box<Ymf289b<Memory>>),
    Ymf278b(Box<Ymf278b<Memory>>),
    Ym2413(Box<Ym2413<Memory>>),
    Ym2423(Box<Ym2423<Memory>>),
    Ymf281(Box<Ymf281<Memory>>),
    Ds1001(Box<Ds1001<Memory>>),
    Ym2151(Box<Ym2151<Memory>>),
    Ym2164(Box<Ym2164<Memory>>),
    Ym2203(Box<Ym2203<Memory>>),
    Ym2608(Box<Ym2608<Memory>>),
    Ymf288(Box<Ymf288<Memory>>),
    Ym2610(Box<Ym2610<Memory>>),
    Ym2610b(Box<Ym2610b<Memory>>),
    Ym2612(Box<Ym2612<Memory>>),
    Ym3438(Box<Ym3438<Memory>>),
    Ymf276(Box<Ymf276<Memory>>),
    Ym2414(Box<Ym2414<Memory>>),
    Ym3806(Box<Ym3806<Memory>>),
    Ym3533(Box<Ym3533<Memory>>),
    Ym2149(Box<Ym2149<Memory>>),
}

/// The most outputs any chip has: the OPL4's six.
const MAX_OUTPUTS: usize = 6;

/// Generates one sample of a chip with `N` outputs into the first `N` of
/// `out`.
fn one<const N: usize>(out: &mut [i32; MAX_OUTPUTS], generate: impl FnOnce(&mut [Output<N>])) {
    let mut sample = [Output::<N>::default()];
    generate(&mut sample);
    out[..N].copy_from_slice(&sample[0].data);
}

/// Dispatches one expression over every variant of [`Chip`], with the chip
/// bound to `$chip`.
macro_rules! each {
    ($value:expr, $chip:ident => $body:expr) => {
        match $value {
            Chip::Ym3526($chip) => $body,
            Chip::Y8950($chip) => $body,
            Chip::Ym3812($chip) => $body,
            Chip::Ymf262($chip) => $body,
            Chip::Ymf289b($chip) => $body,
            Chip::Ymf278b($chip) => $body,
            Chip::Ym2413($chip) => $body,
            Chip::Ym2423($chip) => $body,
            Chip::Ymf281($chip) => $body,
            Chip::Ds1001($chip) => $body,
            Chip::Ym2151($chip) => $body,
            Chip::Ym2164($chip) => $body,
            Chip::Ym2203($chip) => $body,
            Chip::Ym2608($chip) => $body,
            Chip::Ymf288($chip) => $body,
            Chip::Ym2610($chip) => $body,
            Chip::Ym2610b($chip) => $body,
            Chip::Ym2612($chip) => $body,
            Chip::Ym3438($chip) => $body,
            Chip::Ymf276($chip) => $body,
            Chip::Ym2414($chip) => $body,
            Chip::Ym3806($chip) => $body,
            Chip::Ym3533($chip) => $body,
            Chip::Ym2149($chip) => $body,
        }
    };
}

impl Chip {
    /// Creates a chip in its power-on state, reading memory through `images`.
    ///
    /// Boxing a chip allocates, and a reset builds a new one, so a reset on
    /// the audio thread allocates once: it is a rare event a game sends, not
    /// something every sample does.
    fn new(kind: Kind, images: *mut Images) -> Chip {
        let memory = Memory(images);
        let mut chip = match kind {
            Kind::Ym3526 => Chip::Ym3526(Box::new(Ym3526::new(memory))),
            Kind::Y8950 => Chip::Y8950(Box::new(Y8950::new(memory))),
            Kind::Ym3812 => Chip::Ym3812(Box::new(Ym3812::new(memory))),
            Kind::Ymf262 => Chip::Ymf262(Box::new(Ymf262::new(memory))),
            Kind::Ymf289b => Chip::Ymf289b(Box::new(Ymf289b::new(memory))),
            Kind::Ymf278b => Chip::Ymf278b(Box::new(Ymf278b::new(memory))),
            Kind::Ym2413 => Chip::Ym2413(Box::new(Ym2413::new(memory))),
            Kind::Ym2423 => Chip::Ym2423(Box::new(Ym2423::new(memory))),
            Kind::Ymf281 => Chip::Ymf281(Box::new(Ymf281::new(memory))),
            Kind::Ds1001 => Chip::Ds1001(Box::new(Ds1001::new(memory))),
            Kind::Ym2151 => Chip::Ym2151(Box::new(Ym2151::new(memory))),
            Kind::Ym2164 => Chip::Ym2164(Box::new(Ym2164::new(memory))),
            Kind::Ym2203 => Chip::Ym2203(Box::new(Ym2203::new(memory))),
            Kind::Ym2608 => Chip::Ym2608(Box::new(Ym2608::new(memory))),
            Kind::Ymf288 => Chip::Ymf288(Box::new(Ymf288::new(memory))),
            Kind::Ym2610 => Chip::Ym2610(Box::new(Ym2610::new(memory))),
            Kind::Ym2610b => Chip::Ym2610b(Box::new(Ym2610b::new(memory))),
            Kind::Ym2612 => Chip::Ym2612(Box::new(Ym2612::new(memory))),
            Kind::Ym3438 => Chip::Ym3438(Box::new(Ym3438::new(memory))),
            Kind::Ymf276 => Chip::Ymf276(Box::new(Ymf276::new(memory))),
            Kind::Ym2414 => Chip::Ym2414(Box::new(Ym2414::new(memory))),
            Kind::Ym3806 => Chip::Ym3806(Box::new(Ym3806::new(memory))),
            Kind::Ym3533 => Chip::Ym3533(Box::new(Ym3533::new(memory))),
            Kind::Ym2149 => Chip::Ym2149(Box::new(Ym2149::new(memory))),
        };
        chip.fidelity();
        chip
    }

    /// Puts the OPN chips with an SSG on the fidelity `Kind::divider` names.
    fn fidelity(&mut self) {
        match self {
            Chip::Ym2203(chip) => chip.set_fidelity(OpnFidelity::Min),
            Chip::Ym2608(chip) => chip.set_fidelity(OpnFidelity::Min),
            Chip::Ymf288(chip) => chip.set_fidelity(OpnFidelity::Min),
            Chip::Ym2610(chip) => chip.set_fidelity(OpnFidelity::Min),
            Chip::Ym2610b(chip) => chip.set_fidelity(OpnFidelity::Min),
            _ => {}
        }
    }

    /// Writes `data` to the port at `offset`, as the hardware's bus does.
    fn port(&mut self, offset: u16, data: u8) {
        let offset = u32::from(offset);
        each!(self, chip => chip.write(offset, data))
    }

    /// Writes `value` to `register` the way a driver does: the register's
    /// low byte to its bank's address port, then the value to the bank's
    /// data port, or straight to the register on a chip that has no address
    /// port.
    ///
    /// An OPL3 register from 0x100 up goes through the second bank's address
    /// port (offset 2, data at 3), and the chip itself masks it back to the
    /// first bank until the NEW bit in 0x105 is set, as the hardware does.
    fn register(&mut self, kind: Kind, register: u16, value: u8) {
        match kind.layout() {
            Layout::Direct => self.port(register, value),
            Layout::Banks(banks) => {
                let Some((address, data)) = banks.get(usize::from(register >> 8)) else {
                    return;
                };
                self.port(*address, register as u8);
                self.port(*data, value);
            }
        }
    }

    /// Generates the next sample of every output into `out`, in the chip's
    /// order.
    fn generate(&mut self, out: &mut [i32; MAX_OUTPUTS]) {
        match self {
            Chip::Ym3526(chip) => one::<1>(out, |s| chip.generate(s)),
            Chip::Y8950(chip) => one::<1>(out, |s| chip.generate(s)),
            Chip::Ym3812(chip) => one::<1>(out, |s| chip.generate(s)),
            Chip::Ymf262(chip) => one::<4>(out, |s| chip.generate(s)),
            Chip::Ymf289b(chip) => one::<2>(out, |s| chip.generate(s)),
            Chip::Ymf278b(chip) => one::<6>(out, |s| chip.generate(s)),
            Chip::Ym2413(chip) => one::<2>(out, |s| chip.generate(s)),
            Chip::Ym2423(chip) => one::<2>(out, |s| chip.generate(s)),
            Chip::Ymf281(chip) => one::<2>(out, |s| chip.generate(s)),
            Chip::Ds1001(chip) => one::<2>(out, |s| chip.generate(s)),
            Chip::Ym2151(chip) => one::<2>(out, |s| chip.generate(s)),
            Chip::Ym2164(chip) => one::<2>(out, |s| chip.generate(s)),
            Chip::Ym2203(chip) => one::<4>(out, |s| chip.generate(s)),
            Chip::Ym2608(chip) => one::<3>(out, |s| chip.generate(s)),
            Chip::Ymf288(chip) => one::<3>(out, |s| chip.generate(s)),
            Chip::Ym2610(chip) => one::<3>(out, |s| chip.generate(s)),
            Chip::Ym2610b(chip) => one::<3>(out, |s| chip.generate(s)),
            Chip::Ym2612(chip) => one::<2>(out, |s| chip.generate(s)),
            Chip::Ym3438(chip) => one::<2>(out, |s| chip.generate(s)),
            Chip::Ymf276(chip) => one::<2>(out, |s| chip.generate(s)),
            Chip::Ym2414(chip) => one::<2>(out, |s| chip.generate(s)),
            Chip::Ym3806(chip) => one::<2>(out, |s| chip.generate(s)),
            Chip::Ym3533(chip) => one::<2>(out, |s| chip.generate(s)),
            Chip::Ym2149(chip) => one::<3>(out, |s| chip.generate(s)),
        }
    }
}

/// A one-pole high-pass filter that removes direct current, at a few hertz.
#[derive(Clone, Copy, Default)]
struct DcBlocker {
    input: f32,
    output: f32,
}

impl DcBlocker {
    fn process(&mut self, sample: f32, pole: f32) -> f32 {
        let output = sample - self.input + pole * self.output;
        self.input = sample;
        self.output = output;
        output
    }
}

/// The corner the SSG filter cuts below, in hertz.
const DC_CORNER: f64 = 5.0;

/// Returns the pole of the SSG filter at a clock of `rate` frames a second.
fn dc_pole(rate: u32) -> f32 {
    (1.0 - 2.0 * std::f64::consts::PI * DC_CORNER / f64::from(rate)) as f32
}

/// The parameters a Playback opens with, as the bytes `params` points at.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Params {
    /// The chip, as its index in [`Kind::ALL`].
    pub kind: u32,
    /// Its input clock in hertz, zero for its usual one.
    pub clock: u32,
}

/// One chip being played.
struct Instance {
    kind: Kind,
    chip: Chip,
    /// A chip built ahead, so a reset on the audio thread swaps rather than
    /// allocates.
    spare: Option<Chip>,
    /// What a reset displaced, freed when the instance closes.
    retired: Vec<Chip>,
    images: *mut Images,
    decimation: u32,
    routes: &'static [Route],
    scale: f32,
    dc: Option<(DcBlocker, DcBlocker, f32)>,
}

impl Instance {
    fn frame(&mut self) -> (f32, f32) {
        let mut outputs = [0i32; MAX_OUTPUTS];
        let mut sums = [0f32; MAX_OUTPUTS];
        for _ in 0..self.decimation {
            self.chip.generate(&mut outputs);
            for (sum, output) in sums.iter_mut().zip(outputs.iter()) {
                *sum += *output as f32;
            }
        }
        let (mut l, mut r) = (0.0f32, 0.0f32);
        for route in self.routes {
            l += sums[route.output] * route.left;
            r += sums[route.output] * route.right;
        }
        l *= self.scale;
        r *= self.scale;
        if let Some((left, right, pole)) = &mut self.dc {
            l = left.process(l, *pole);
            r = right.process(r, *pole);
        }
        (l, r)
    }

    fn reset(&mut self) {
        let fresh = match self.spare.take() {
            Some(chip) => chip,
            // A second reset before the instance closes builds its chip
            // here; the first never does.
            None => Chip::new(self.kind, self.images),
        };
        let old = std::mem::replace(&mut self.chip, fresh);
        if self.retired.len() < self.retired.capacity() {
            self.retired.push(old);
        } else {
            std::mem::forget(old);
        }
        if let Some((left, right, _)) = &mut self.dc {
            *left = DcBlocker::default();
            *right = DcBlocker::default();
        }
    }
}

impl Drop for Instance {
    fn drop(&mut self) {
        // The chips hold copies of the images pointer; drop them first.
        self.retired.clear();
        self.spare = None;
        // SAFETY: from `Box::into_raw` in `build`, freed only here.
        drop(unsafe { Box::from_raw(self.images) });
    }
}

fn read_params(params: *const u8, params_len: usize) -> Option<(Kind, u32)> {
    if params.is_null() || params_len < std::mem::size_of::<Params>() {
        return None;
    }
    let params = unsafe { std::ptr::read_unaligned(params as *const Params) };
    let kind = *Kind::ALL.get(params.kind as usize)?;
    let clock = if params.clock == 0 {
        kind.default_clock()
    } else {
        params.clock
    };
    Some((kind, clock.clamp(MIN_CLOCK, MAX_CLOCK)))
}

/// Reads the images the bytes carry: each a class index and a length as
/// little-endian `u32`, then that many bytes.
fn read_images(kind: Kind, bytes: &[u8]) -> Option<Images> {
    let mut images = Images::default();
    let mut rest = bytes;
    while !rest.is_empty() {
        if rest.len() < 8 {
            return None;
        }
        let class = u32::from_le_bytes(rest[0..4].try_into().ok()?);
        let length = u32::from_le_bytes(rest[4..8].try_into().ok()?) as usize;
        if rest.len() < 8 + length || length > MAX_IMAGE {
            return None;
        }
        let class = MemoryClass::from_index(class)?;
        if kind.reads(class) {
            *images.slot(class) = rest[8..8 + length].to_vec().into_boxed_slice();
        }
        rest = &rest[8 + length..];
    }
    Some(images)
}

fn build(
    params: *const u8,
    params_len: usize,
    bytes: *const u8,
    bytes_len: usize,
) -> Option<Instance> {
    let (kind, clock) = read_params(params, params_len)?;
    let slice = if bytes.is_null() || bytes_len == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(bytes, bytes_len) }
    };
    let images = Box::into_raw(Box::new(read_images(kind, slice)?));
    let rate = kind.rate(clock);
    let decimation = kind.decimation(clock);
    let dc = kind
        .has_ssg()
        .then(|| (DcBlocker::default(), DcBlocker::default(), dc_pole(rate)));
    Some(Instance {
        kind,
        chip: Chip::new(kind, images),
        spare: Some(Chip::new(kind, images)),
        retired: Vec::with_capacity(1),
        images,
        decimation,
        routes: kind.outputs(),
        scale: 1.0 / (32768.0 * decimation as f32),
        dc,
    })
}

unsafe extern "C" fn describe(
    params: *const u8,
    params_len: usize,
    _bytes: *const u8,
    _bytes_len: usize,
    _output_rate: u32,
    out: *mut DecoderFormat,
) -> i32 {
    let Some((kind, clock)) = read_params(params, params_len) else {
        return 1;
    };
    if out.is_null() {
        return 2;
    }
    unsafe {
        *out = DecoderFormat {
            channels: 2,
            sample_rate: kind.rate(clock),
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
    bytes: *const u8,
    bytes_len: usize,
    _output_rate: u32,
) -> *mut c_void {
    match build(params, params_len, bytes, bytes_len) {
        None => std::ptr::null_mut(),
        Some(instance) => Box::into_raw(Box::new(instance)) as *mut c_void,
    }
}

unsafe extern "C" fn render(instance: *mut c_void, out: *mut f32, frames: u32) -> u32 {
    let state = unsafe { &mut *(instance as *mut Instance) };
    let target = unsafe { std::slice::from_raw_parts_mut(out, frames as usize * 2) };
    for frame in target.as_chunks_mut::<2>().0 {
        let (left, right) = state.frame();
        frame[0] = left;
        frame[1] = right;
    }
    frames
}

/// Packs a register write into an event: the register in bits 0 to 15, the
/// value in bits 16 to 23.
pub const fn register_event(register: u16, value: u8) -> u64 {
    register as u64 | (value as u64) << 16
}

/// Packs a port write: a write to the chip's bus at `offset`.
pub const fn port_event(offset: u16, value: u8) -> u64 {
    (EVENT_OP_PORT << EVENT_OP_SHIFT) | offset as u64 | (value as u64) << 16
}

unsafe extern "C" fn event(instance: *mut c_void, _frame: u32, data: u64) {
    let state = unsafe { &mut *(instance as *mut Instance) };
    let (op, payload) = split_event(data);
    let address = (payload & 0xFFFF) as u16;
    let value = ((payload >> 16) & 0xFF) as u8;
    match op {
        EVENT_OP_MESSAGE => {
            if address <= state.kind.last_register() {
                state.chip.register(state.kind, address, value);
            }
        }
        EVENT_OP_PORT => {
            if address <= state.kind.last_port() {
                state.chip.port(address, value);
            }
        }
        EVENT_OP_RESET => state.reset(),
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

/// Returns the FM Decoder's vtable.
#[no_mangle]
pub extern "C" fn tecs_ymfm_decoder() -> *const DecoderVTable {
    &VTABLE
}

/// Returns the index of the chip a part number or alias names, or `u32::MAX`
/// for none.
///
/// # Safety
///
/// `name` must be a NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn tecs_ymfm_kind(name: *const c_char) -> u32 {
    if name.is_null() {
        return u32::MAX;
    }
    let Ok(text) = (unsafe { CStr::from_ptr(name) }).to_str() else {
        return u32::MAX;
    };
    match Kind::from_name(text) {
        None => u32::MAX,
        Some(kind) => Kind::ALL
            .iter()
            .position(|each| *each == kind)
            .map_or(u32::MAX, |index| index as u32),
    }
}

/// Reports the rate a chip renders at for a clock, zero for its usual one.
#[no_mangle]
pub extern "C" fn tecs_ymfm_rate(kind: u32, clock: u32) -> u32 {
    match Kind::ALL.get(kind as usize) {
        None => 0,
        Some(kind) => {
            let clock = if clock == 0 {
                kind.default_clock()
            } else {
                clock
            };
            kind.rate(clock.clamp(MIN_CLOCK, MAX_CLOCK))
        }
    }
}

/// Reports a chip's usual input clock.
#[no_mangle]
pub extern "C" fn tecs_ymfm_default_clock(kind: u32) -> u32 {
    Kind::ALL
        .get(kind as usize)
        .map_or(0, |kind| kind.default_clock())
}

/// Reports the last register a chip has, and its last port offset, packed as
/// `register | port << 16`.
#[no_mangle]
pub extern "C" fn tecs_ymfm_limits(kind: u32) -> u32 {
    Kind::ALL.get(kind as usize).map_or(0, |kind| {
        u32::from(kind.last_register()) | u32::from(kind.last_port()) << 16
    })
}

/// Reports whether a chip reads a memory class.
#[no_mangle]
pub extern "C" fn tecs_ymfm_reads(kind: u32, class: u32) -> i32 {
    match (Kind::ALL.get(kind as usize), MemoryClass::from_index(class)) {
        (Some(kind), Some(class)) => i32::from(kind.reads(class)),
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(kind: Kind, clock: u32) -> Params {
        Params {
            kind: Kind::ALL.iter().position(|each| *each == kind).unwrap() as u32,
            clock,
        }
    }

    fn open_chip(kind: Kind, images: &[u8]) -> *mut c_void {
        let p = params(kind, 0);
        unsafe {
            open(
                &p as *const Params as *const u8,
                std::mem::size_of::<Params>(),
                images.as_ptr(),
                images.len(),
                48_000,
            )
        }
    }

    /// The writes that put a held sine on channel 0 of an OPL and key it on.
    const NOTE: [(u16, u8); 8] = [
        (0x20, 0x01),
        (0x23, 0x21),
        (0x40, 0x3f),
        (0x43, 0x00),
        (0x63, 0xf0),
        (0x83, 0x0f),
        (0xa0, 0x41),
        (0xb0, 0x32),
    ];

    #[test]
    fn sounds_an_opl2_note_written_through_events_and_resets_to_silence() {
        let chip = open_chip(Kind::Ym3812, &[]);
        assert!(!chip.is_null());
        for (register, value) in NOTE {
            unsafe { event(chip, 0, register_event(register, value)) };
        }
        let mut out = vec![0.0f32; 2 * 2000];
        unsafe { render(chip, out.as_mut_ptr(), 2000) };
        assert!(
            out.iter().any(|value| value.abs() > 1e-3),
            "the note sounds"
        );
        unsafe { event(chip, 0, EVENT_OP_RESET << EVENT_OP_SHIFT) };
        unsafe { render(chip, out.as_mut_ptr(), 2000) };
        assert!(
            out[2000..].iter().all(|value| value.abs() < 1e-3),
            "a reset silences it"
        );
        unsafe { close(chip) };
    }

    #[test]
    fn describes_each_chip_at_the_rate_its_clock_gives() {
        for kind in Kind::ALL {
            let p = params(kind, 0);
            let mut format = DecoderFormat::default();
            let status = unsafe {
                describe(
                    &p as *const Params as *const u8,
                    std::mem::size_of::<Params>(),
                    std::ptr::null(),
                    0,
                    48_000,
                    &mut format,
                )
            };
            assert_eq!(status, 0);
            assert_eq!(format.sample_rate, kind.rate(kind.default_clock()));
            assert!(format.sample_rate <= MAX_RATE);
            assert!(format.flags & FORMAT_SEQUENCED != 0);
        }
    }

    #[test]
    fn names_chips_by_part_number_and_refuses_bad_images() {
        let name = std::ffi::CString::new("ym3812").unwrap();
        assert_eq!(
            unsafe { tecs_ymfm_kind(name.as_ptr()) } as usize,
            Kind::ALL
                .iter()
                .position(|kind| *kind == Kind::Ym3812)
                .unwrap()
        );
        assert_eq!(
            tecs_ymfm_rate(unsafe { tecs_ymfm_kind(name.as_ptr()) }, 0),
            RATE
        );
        // A length past the bytes is refused rather than read past.
        let bad = [0u8, 0, 0, 0, 255, 0, 0, 0];
        assert!(open_chip(Kind::Ym2610, &bad).is_null());
    }
}
