//! An emulated Yamaha FM chip that plays as one voice of the mixer.
//!
//! The chip is any of the 24 that [`ymfm_oxide`], a pure-Rust port of ymfm,
//! emulates: the OPL family with the OPL4, the OPLL family, the OPM and OPP,
//! the OPN family with its SSG and ADPCM, the OPZ, the OPQ and the YM2149. What
//! drives it is the scheduler the General MIDI synthesizer uses: the same
//! bounded ring, the same schedule sorted by frame and then by sending, the
//! same source the mixer reads. What differs is the grid. A register write
//! takes effect on the very sample it is due at, so the target's block is one
//! frame and an event lands on the first clock frame at or after its time,
//! never later. Writes due on one frame all apply before it is generated, so a
//! key-off and a key-on there are no change at all: a note is struck again by
//! spacing them a frame apart.
//!
//! Each chip runs at its own rate, the one ymfm gives its input clock, and the
//! voice that reads it resamples to the output, as it would a clip recorded at
//! that rate. Three chips render faster than any output needs, the YM2203 and
//! the YM2608 at three times their FM rate so the SSG can be averaged down and
//! the YMF288 at twice it, and for those the source averages consecutive
//! samples into one frame ([`Kind::decimation`]), so the clock a game
//! schedules against never runs past 64 kHz. Every chip's outputs are folded
//! into one stereo pair ([`Kind::outputs`]), and a chip with an SSG has its
//! direct current removed, because the SSG's square waves swing between zero
//! and a positive level rather than around zero, which the hardware's output
//! capacitor took care of.
//!
//! ```
//! use tecsaudio::fm::{self, Kind};
//! use tecsaudio::source::Source;
//!
//! let (mut port, mut source) = fm::open(Kind::Ym3812, Kind::Ym3812.default_clock());
//! // Key channel 0 on a quarter of a second in, on the chip's own clock.
//! assert!(port.write(0xb0, 0x32, 0.25));
//! let mut out = [0.0f32; 2];
//! source.read(&mut out);
//! ```

use std::sync::mpsc::{sync_channel, Receiver, SyncSender};

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

use crate::synth::{
    self, Event, Port, SynthSource, Target, KIND_MEMORY, KIND_MESSAGE, KIND_PORT, KIND_RESET,
};

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

/// The memory images that can be on their way to the audio thread at once,
/// and the displaced ones on their way back.
pub const MEMORY_QUEUE: usize = 8;

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

    /// Reports the rate the emulator gives `clock`, which `Kind::divider`
    /// has to agree with.
    #[cfg(test)]
    fn sample_rate(&self, clock: u32) -> u32 {
        each!(self, chip => chip.sample_rate(clock))
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

/// Writes the queue holds between the game thread and the callback, which is
/// also the largest batch `writes` can ever accept.
pub const QUEUE_WRITES: usize = synth::QUEUE_EVENTS;

/// One register write, or one port write, as a batch crosses the C ABI.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RegisterWrite {
    /// The register, up to the chip's last, or the port offset, up to its
    /// last port.
    pub register: u16,
    /// The value, from 0 to 255. Sixteen bits wide so the struct has no
    /// padding for two languages to disagree about.
    pub value: u16,
}

/// The chip as a scheduler target.
///
/// A register write carries the register's low byte in `status`, its high
/// byte in `data1` and the value in `data2`; a port write carries the offset
/// the same way. A memory event carries the class in `data1`, and its image
/// is the next one waiting on the memory channel.
pub struct Fm {
    kind: Kind,
    chip: Chip,
    /// The images the chip reads, owned here through a raw pointer so the
    /// chip's interface can point at them: from `Box::into_raw`, freed in
    /// `Drop`.
    images: *mut Images,
    images_in: Receiver<Box<[u8]>>,
    images_out: SyncSender<Box<[u8]>>,
    decimation: u32,
    /// The routes of `kind.outputs()`.
    routes: &'static [Route],
    /// The scale from the emulator's integers to the mixer's floats, with the
    /// average over the decimated samples folded in.
    scale: f32,
    /// The SSG filter for each side and its pole, on a chip with an SSG.
    dc: Option<(DcBlocker, DcBlocker, f32)>,
}

// SAFETY: `images` is owned by this target alone, and the chip's interface
// that also points at it moves with the target. See `Memory`.
unsafe impl Send for Fm {}

impl Drop for Fm {
    fn drop(&mut self) {
        // SAFETY: the pointer came from `Box::into_raw` in `open` and is
        // freed only here. The chip still holds a copy, but its interface has
        // no destructor and the chip is not used again.
        drop(unsafe { Box::from_raw(self.images) });
    }
}

impl Fm {
    /// Replaces the image of `class` and hands back the one it displaced.
    fn swap(&mut self, class: MemoryClass, image: Box<[u8]>) -> Box<[u8]> {
        // SAFETY: the chip is not generating, since this target is borrowed
        // mutably here, so this is the one live reference to the images.
        let images = unsafe { &mut *self.images };
        std::mem::replace(images.slot(class), image)
    }

    /// Generates the next frame: as many samples as the decimation names,
    /// averaged, folded to stereo and, for an SSG, filtered.
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
}

impl Target for Fm {
    const BLOCK_FRAMES: usize = 1;

    fn apply(&mut self, event: &Event) {
        let address = u16::from(event.status) | (u16::from(event.data1) << 8);
        match event.kind {
            KIND_MESSAGE => self.chip.register(self.kind, address, event.data2),
            KIND_PORT => self.chip.port(address, event.data2),
            KIND_RESET => {
                // A reset keeps the memory images, as the hardware's reset
                // line leaves its RAM alone.
                self.chip = Chip::new(self.kind, self.images);
                if let Some((left, right, _)) = &mut self.dc {
                    *left = DcBlocker::default();
                    *right = DcBlocker::default();
                }
            }
            KIND_MEMORY => {
                let Some(class) = MemoryClass::from_index(u32::from(event.data1)) else {
                    return;
                };
                let Ok(image) = self.images_in.try_recv() else {
                    return;
                };
                let displaced = self.swap(class, image);
                // Freed on the game thread, which collects it at its next
                // memory load; dropped here only if that queue is full, which
                // takes a game loading images faster than the chip renders.
                let _ = self.images_out.try_send(displaced);
            }
            _ => {}
        }
    }

    fn render(&mut self, left: &mut [f32], right: &mut [f32]) {
        for (l, r) in left.iter_mut().zip(right.iter_mut()) {
            (*l, *r) = self.frame();
        }
    }
}

/// The game side of one chip: where register writes are sent and the clock
/// read.
pub struct FmPort {
    port: Port,
    kind: Kind,
    clock: u32,
    images_out: SyncSender<Box<[u8]>>,
    images_back: Receiver<Box<[u8]>>,
}

impl FmPort {
    /// Converts a time on the chip clock to the first frame at or after it.
    ///
    /// A time within a millionth of a frame of a whole frame is that frame,
    /// so a time computed as `now() + k / rate` lands on frame `k` rather
    /// than one past it for a rounding error. Zero, a negative time and a
    /// time that is not a number all mean the next frame.
    fn frame_at(&self, seconds: f64) -> u64 {
        if seconds.is_nan() || seconds <= 0.0 {
            return 0;
        }
        let exact = seconds * f64::from(self.port.sample_rate());
        let nearest = exact.round();
        if (exact - nearest).abs() < 1e-6 {
            nearest as u64
        } else {
            exact.ceil() as u64
        }
    }

    fn event(kind: u8, address: u16, value: u8, frame: u64) -> Event {
        Event {
            frame,
            kind,
            status: address as u8,
            data1: (address >> 8) as u8,
            data2: value,
        }
    }

    /// Reports which chip the port drives.
    pub fn kind(&self) -> Kind {
        self.kind
    }

    /// Reports the input clock the chip was made with, in hertz.
    pub fn clock(&self) -> u32 {
        self.clock
    }

    /// Reports the rate of the chip's clock, in frames a second.
    pub fn rate(&self) -> u32 {
        self.port.sample_rate()
    }

    /// Queues one register write for `at` seconds on the chip clock, and
    /// reports whether it was queued: false when the queue is full or the
    /// register is past the chip's last.
    pub fn write(&mut self, register: u16, value: u8, at: f64) -> bool {
        if register > self.kind.last_register() {
            return false;
        }
        let frame = self.frame_at(at);
        self.port
            .push(FmPort::event(KIND_MESSAGE, register, value, frame))
    }

    /// Queues one write of `data` to the port at `offset`, for `at` seconds
    /// on the chip clock, and reports whether it was queued: false when the
    /// queue is full or the offset is past the chip's last port.
    pub fn write_port(&mut self, offset: u16, data: u8, at: f64) -> bool {
        if offset > self.kind.last_port() {
            return false;
        }
        let frame = self.frame_at(at);
        self.port
            .push(FmPort::event(KIND_PORT, offset, data, frame))
    }

    /// Queues every write in `writes` for `at`, in order, all or none, and
    /// reports which: none when the queue cannot take them all, or when any
    /// address is past the chip's last or any value past 255. The addresses
    /// are registers, or port offsets when `ports` is set.
    pub fn writes(&mut self, writes: &[RegisterWrite], at: f64, ports: bool) -> bool {
        let (last, kind) = if ports {
            (self.kind.last_port(), KIND_PORT)
        } else {
            (self.kind.last_register(), KIND_MESSAGE)
        };
        if writes
            .iter()
            .any(|write| write.register > last || write.value > 0xff)
        {
            return false;
        }
        let frame = self.frame_at(at);
        self.port.push_all(writes.len(), |index| {
            FmPort::event(
                kind,
                writes[index].register,
                writes[index].value as u8,
                frame,
            )
        })
    }

    /// Replaces the memory image of `class` with a copy of `image`, from the
    /// chip's next frame, and reports whether it was queued: false when the
    /// chip reads no memory of that class, the image is past [`MAX_IMAGE`],
    /// [`MEMORY_QUEUE`] images are already on their way, or the write queue
    /// is full.
    ///
    /// An image replaces the whole class rather than a range of it, and lands
    /// before any write due on the same frame. A reset keeps it.
    pub fn set_memory(&mut self, class: MemoryClass, image: &[u8]) -> bool {
        self.collect();
        if !self.kind.reads(class) || image.len() > MAX_IMAGE {
            return false;
        }
        // An image sent without its event would be taken by the next one, so
        // the queue is checked first. This port is the ring's only producer
        // and the callback only ever makes room, so room seen here is still
        // there for the push below.
        if !self.port.has_room() {
            self.port.refuse();
            return false;
        }
        if self
            .images_out
            .try_send(image.to_vec().into_boxed_slice())
            .is_err()
        {
            return false;
        }
        self.port.push(FmPort::event(
            KIND_MEMORY,
            u16::from(class.index()) << 8,
            0,
            0,
        ))
    }

    /// Frees the images the chip has displaced, on this thread.
    fn collect(&mut self) {
        while self.images_back.try_recv().is_ok() {}
    }

    /// Queues a return to the chip's power-on state for `at` seconds on the
    /// chip clock, where zero or a time already passed means the next frame.
    ///
    /// Writes sent before the reset and due before `at` still apply; those
    /// due at or after it are discarded, so nothing sent earlier plays over
    /// the silence the reset makes. Writes sent after it apply as usual. The
    /// memory images stay.
    pub fn reset(&mut self, at: f64) -> bool {
        let frame = self.frame_at(at);
        self.port.push(Event {
            frame,
            kind: KIND_RESET,
            status: 0,
            data1: 0,
            data2: 0,
        })
    }

    /// Reports the chip clock in seconds: the frames it has rendered over
    /// its rate.
    pub fn now(&self) -> f64 {
        self.port.now()
    }

    /// Reports the frames the chip has rendered.
    pub fn frames(&self) -> u64 {
        self.port.frames()
    }

    /// Reports how many sends the queue refused: a refused batch counts once.
    pub fn dropped(&self) -> u64 {
        self.port.dropped()
    }
}

/// Builds the two halves of one chip at `clock` hertz: the port the game
/// writes through and the source the mixer reads.
///
/// A clock outside [`MIN_CLOCK`] to [`MAX_CLOCK`] is clamped into it.
pub fn open(kind: Kind, clock: u32) -> (FmPort, SynthSource<Fm>) {
    let clock = clock.clamp(MIN_CLOCK, MAX_CLOCK);
    let rate = kind.rate(clock);
    let decimation = kind.decimation(clock);
    let images = Box::into_raw(Box::<Images>::default());
    let (images_out, images_in) = sync_channel(MEMORY_QUEUE);
    let (images_return, images_back) = sync_channel(MEMORY_QUEUE);
    let dc = kind
        .has_ssg()
        .then(|| (DcBlocker::default(), DcBlocker::default(), dc_pole(rate)));
    let (port, source) = synth::assemble(
        Fm {
            kind,
            chip: Chip::new(kind, images),
            images,
            images_in,
            images_out: images_return,
            decimation,
            routes: kind.outputs(),
            scale: 1.0 / (32768.0 * decimation as f32),
            dc,
        },
        rate,
    );
    (
        FmPort {
            port,
            kind,
            clock,
            images_out,
            images_back,
        },
        source,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::Source;

    /// The writes that put a held sine on channel 0 of an OPL and key it on.
    /// Its envelope jumps straight to full and holds, so the note sounds the
    /// same wherever the chip's envelope counter happens to stand.
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

    fn opl2() -> (FmPort, SynthSource<Fm>) {
        open(Kind::Ym3812, OPL2_CLOCK)
    }

    fn opl3() -> (FmPort, SynthSource<Fm>) {
        open(Kind::Ymf262, OPL3_CLOCK)
    }

    /// Reads `frames` from a source in pieces of `piece`, as a voice does,
    /// and returns both channels.
    fn pull_both(source: &mut impl Source, frames: usize, piece: usize) -> Vec<(f32, f32)> {
        let mut out = Vec::with_capacity(frames);
        let mut staging = vec![0.0f32; piece * 2];
        while out.len() < frames {
            let wanted = (frames - out.len()).min(piece);
            let got = source.read(&mut staging[..wanted * 2]);
            out.extend(
                staging[..got * 2]
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .map(|frame| (frame[0], frame[1])),
            );
        }
        out
    }

    /// Reads `frames` from a source in pieces of `piece` and returns the left
    /// channel.
    fn pull(source: &mut impl Source, frames: usize, piece: usize) -> Vec<f32> {
        pull_both(source, frames, piece)
            .into_iter()
            .map(|(left, _)| left)
            .collect()
    }

    /// Renders `frames` straight from a chip, applying each write before the
    /// sample it names, which is what ymfm's renders mean by a write's time.
    fn direct(kind: Kind, writes: &[(u64, u16, u8)], frames: usize) -> Vec<f32> {
        let mut images = Images::default();
        let mut chip = Chip::new(kind, &mut images);
        let mut next = 0;
        let mut outputs = [0i32; MAX_OUTPUTS];
        (0..frames as u64)
            .map(|frame| {
                while next < writes.len() && writes[next].0 <= frame {
                    chip.register(kind, writes[next].1, writes[next].2);
                    next += 1;
                }
                chip.generate(&mut outputs);
                outputs[0] as f32 / 32768.0
            })
            .collect()
    }

    fn timed(frame: u64) -> Vec<(u64, u16, u8)> {
        NOTE.iter()
            .map(|(register, value)| (frame, *register, *value))
            .collect()
    }

    #[test]
    fn lands_a_write_on_the_first_sample_at_or_after_its_time() {
        let rate = f64::from(RATE);
        for (at, frame) in [
            (1000.0 / rate, 1000),
            (1000.4 / rate, 1001),
            (1000.9 / rate, 1001),
        ] {
            let (mut port, mut source) = opl2();
            for (register, value) in NOTE {
                assert!(port.write(register, value, at));
            }
            // A piece size that does not divide anything, so the reads fall
            // across the write's sample at an arbitrary offset.
            let out = pull(&mut source, 3000, 37);
            assert_eq!(out, direct(Kind::Ym3812, &timed(frame), 3000), "at {at}");
            assert!(out[..frame as usize].iter().all(|sample| *sample == 0.0));
            assert!(out[frame as usize + 4..]
                .iter()
                .any(|sample| *sample != 0.0));
        }
    }

    #[test]
    fn lands_a_time_computed_from_the_clock_on_its_sample() {
        let (mut port, mut source) = opl2();
        pull(&mut source, 777, 64);
        // `now` and a step of whole samples, each as floating point carries it.
        let at = port.now() + 123.0 / f64::from(RATE);
        for (register, value) in NOTE {
            assert!(port.write(register, value, at));
        }
        let out = pull(&mut source, 2000, 64);
        let reference = direct(Kind::Ym3812, &timed(123), 2000);
        assert_eq!(out, reference);
    }

    #[test]
    fn applies_writes_due_on_one_sample_in_sending_order() {
        let (mut port, mut source) = opl2();
        for (register, value) in NOTE {
            assert!(port.write(register, value, 0.0));
        }
        // Two frequencies for the same sample: the second one sent wins.
        let at = 500.0 / f64::from(RATE);
        assert!(port.write(0xa0, 0x10, at));
        assert!(port.write(0xa0, 0x80, at));
        let out = pull(&mut source, 1500, 256);
        let mut writes = timed(0);
        writes.push((500, 0xa0, 0x10));
        writes.push((500, 0xa0, 0x80));
        assert_eq!(out, direct(Kind::Ym3812, &writes, 1500));
        writes.truncate(NOTE.len() + 1);
        assert_ne!(out, direct(Kind::Ym3812, &writes, 1500));
    }

    #[test]
    fn orders_writes_by_time_rather_than_by_sending() {
        let (mut port, mut source) = opl2();
        let rate = f64::from(RATE);
        for (register, value) in NOTE {
            assert!(port.write(register, value, 0.0));
        }
        assert!(port.write(0xb0, 0x12, 900.0 / rate));
        assert!(port.write(0xa0, 0x99, 300.0 / rate));
        let out = pull(&mut source, 1500, 100);
        let mut writes = timed(0);
        writes.push((300, 0xa0, 0x99));
        writes.push((900, 0xb0, 0x12));
        assert_eq!(out, direct(Kind::Ym3812, &writes, 1500));
    }

    #[test]
    fn applies_a_past_or_untimed_write_on_the_next_sample() {
        let (mut port, mut source) = opl2();
        pull(&mut source, 640, 64);
        assert!(port.write(NOTE[0].0, NOTE[0].1, 0.0));
        assert!(port.write(NOTE[1].0, NOTE[1].1, -3.0));
        for (register, value) in &NOTE[2..] {
            assert!(port.write(*register, *value, 1.0 / f64::from(RATE)));
        }
        let out = pull(&mut source, 1000, 64);
        let reference = direct(Kind::Ym3812, &timed(0), 1000);
        assert_eq!(out, reference);
    }

    #[test]
    fn plays_the_opl2_on_both_sides_and_the_opl3_from_its_pan_bits() {
        let (mut port, mut source) = opl2();
        for (register, value) in NOTE {
            assert!(port.write(register, value, 0.0));
        }
        let out = pull_both(&mut source, 600, 64);
        assert!(out.iter().all(|(left, right)| left == right));
        assert!(out.iter().any(|(left, _)| *left != 0.0));

        let (mut port, mut source) = opl3();
        assert!(port.write(0x105, 0x01, 0.0));
        for (register, value) in NOTE {
            assert!(port.write(register, value, 0.0));
        }
        // Channel 0 to the left only.
        assert!(port.write(0xc0, 0x10, 0.0));
        let out = pull_both(&mut source, 600, 64);
        assert!(out.iter().any(|(left, _)| *left != 0.0));
        assert!(out.iter().all(|(_, right)| *right == 0.0));
    }

    #[test]
    fn refuses_a_register_past_the_chip_and_queues_nothing() {
        let (mut opl2, _source) = opl2();
        assert!(!opl2.write(0x100, 0x01, 0.0));
        assert!(opl2.write(0xff, 0x01, 0.0));
        assert!(!opl2.write_port(2, 0x01, 0.0));
        assert!(opl2.write_port(1, 0x01, 0.0));
        let (mut opl3, _source) = opl3();
        assert!(opl3.write(0x1ff, 0x01, 0.0));
        assert!(!opl3.write(0x200, 0x01, 0.0));
        let bad = [
            RegisterWrite {
                register: 0x20,
                value: 1,
            },
            RegisterWrite {
                register: 0x40,
                value: 0x100,
            },
        ];
        assert!(!opl3.writes(&bad, 0.0, false));
        let ports = [RegisterWrite {
            register: 4,
            value: 1,
        }];
        assert!(!opl3.writes(&ports, 0.0, true));
        assert_eq!(
            opl2.dropped() + opl3.dropped(),
            0,
            "a refused value is not a drop"
        );
    }

    #[test]
    fn bounds_the_queue_and_takes_a_batch_whole_or_not_at_all() {
        let (mut port, mut source) = opl2();
        let later = 1.0;
        let batch: Vec<RegisterWrite> = (0..100)
            .map(|index| RegisterWrite {
                register: 0xa0,
                value: index,
            })
            .collect();
        for _ in 0..QUEUE_WRITES - 50 {
            assert!(port.write(0x20, 0x01, later));
        }
        // Fifty slots are left: the batch of a hundred does not fit and none
        // of it is queued, so all fifty singles still are.
        assert!(!port.writes(&batch, later, false));
        for _ in 0..50 {
            assert!(port.write(0x20, 0x01, later));
        }
        assert!(!port.write(0x20, 0x01, later));
        assert_eq!(port.dropped(), 2);

        // One sample moves the ring into the schedule, which has the room.
        pull(&mut source, 1, 1);
        assert!(port.writes(&batch, later, false));
        let too_many = vec![
            RegisterWrite {
                register: 0x20,
                value: 1,
            };
            QUEUE_WRITES + 1
        ];
        let (mut fresh, _source) = opl2();
        assert!(
            !fresh.writes(&too_many, 0.0, false),
            "a batch past the queue never fits"
        );
        assert!(fresh.writes(&too_many[..QUEUE_WRITES], 0.0, false));
    }

    #[test]
    fn resets_to_power_on_and_discards_what_was_pending() {
        let (mut port, mut source) = opl3();
        for (register, value) in NOTE {
            assert!(port.write(register, value, 0.0));
        }
        pull(&mut source, 1000, 128);
        // A note scheduled for later, then a reset sent after it.
        assert!(port.write(0xb1, 0x32, 2000.0 / f64::from(RATE)));
        assert!(port.reset(0.0));
        let after = pull(&mut source, 3000, 128);
        assert!(
            after.iter().all(|sample| *sample == 0.0),
            "the chip is silent and the note gone"
        );

        // What follows a reset plays on a chip just as a new one would.
        for (register, value) in NOTE {
            assert!(port.write(register, value, 0.0));
        }
        let replay = pull(&mut source, 2000, 128);
        assert_eq!(replay, direct(Kind::Ymf262, &timed(0), 2000));
    }

    #[test]
    fn resets_at_its_time_keeping_what_falls_before_it() {
        let rate = f64::from(RATE);
        let (mut port, mut source) = opl2();
        for (register, value) in NOTE {
            assert!(port.write(register, value, 0.0));
        }
        // A frequency change before the reset, one after it, then the reset
        // between them, and a write sent after the reset for later still.
        assert!(port.write(0xa0, 0x80, 400.0 / rate));
        assert!(port.write(0xa0, 0x20, 900.0 / rate));
        assert!(port.reset(600.0 / rate));
        for (register, value) in NOTE {
            assert!(port.write(register, value, 800.0 / rate));
        }
        let out = pull(&mut source, 1200, 50);
        let mut writes = timed(0);
        writes.push((400, 0xa0, 0x80));
        let before = direct(Kind::Ym3812, &writes, 600);
        assert_eq!(&out[..600], &before[..]);
        assert!(
            out[600..800].iter().all(|sample| *sample == 0.0),
            "the reset silences the chip at its sample"
        );
        // The note sent after the reset plays, and the frequency change at 900
        // sent before it does not.
        let after = direct(Kind::Ym3812, &timed(0), 400);
        assert_eq!(&out[800..], &after[..]);
    }

    #[test]
    fn renders_at_the_rate_the_emulator_gives_each_chip_clock() {
        assert_eq!(Kind::Ym3812.rate(OPL2_CLOCK), RATE);
        assert_eq!(Kind::Ymf262.rate(OPL3_CLOCK), RATE);
        for kind in Kind::ALL {
            for clock in [kind.default_clock(), 4_000_000, MIN_CLOCK] {
                let mut images = Images::default();
                let chip = Chip::new(kind, &mut images);
                assert_eq!(
                    clock / kind.divider(),
                    chip.sample_rate(clock),
                    "{} at {clock}",
                    kind.name()
                );
                assert!(kind.rate(clock) <= MAX_RATE, "{}", kind.name());
            }
            let (port, source) = open(kind, kind.default_clock());
            assert_eq!(port.rate(), kind.rate(kind.default_clock()));
            assert_eq!(source.sample_rate(), port.rate());
            assert_eq!(port.clock(), kind.default_clock());
        }
        // The three that render past the ceiling at their own clocks, and
        // what their frames come to.
        assert_eq!(Kind::Ym2203.decimation(3_993_600), 3);
        assert_eq!(Kind::Ym2203.rate(3_993_600), 55_466);
        assert_eq!(Kind::Ym2608.decimation(7_987_200), 3);
        assert_eq!(Kind::Ymf288.decimation(15_974_400), 2);
        assert_eq!(Kind::Ym2612.decimation(7_670_453), 1);
        assert_eq!(Kind::Ym2612.rate(7_670_453), 53_267);
        // A clock past either bound is clamped to it.
        let (port, _source) = open(Kind::Ym3812, 1);
        assert_eq!(port.clock(), MIN_CLOCK);
    }

    #[test]
    fn names_every_chip_once_and_reads_the_opl_aliases() {
        for kind in Kind::ALL {
            assert_eq!(Kind::from_name(kind.name()), Some(kind));
        }
        assert_eq!(Kind::from_name("opl2"), Some(Kind::Ym3812));
        assert_eq!(Kind::from_name("opl3"), Some(Kind::Ymf262));
        assert_eq!(Kind::from_name("sn76489"), None);
        assert_eq!(Kind::from_name("YM2612"), None);
    }

    #[test]
    fn writes_the_second_bank_of_an_opl3_through_its_own_port() {
        let (mut port, mut source) = opl3();
        assert!(port.write(0x105, 0x01, 0.0));
        // The note on channel 9, the first of the second bank, centred.
        for (register, value) in NOTE {
            assert!(port.write(0x100 | register, value, 0.0));
        }
        assert!(port.write(0x1c0, 0x31, 0.0));
        let out = pull(&mut source, 600, 64);
        assert!(out.iter().any(|sample| *sample != 0.0));
        // Without the NEW bit the chip masks the bank away, so the same
        // writes land on channel 0 of the first bank.
        let (mut port, mut source) = opl3();
        for (register, value) in NOTE {
            assert!(port.write(0x100 | register, value, 0.0));
        }
        let out = pull(&mut source, 600, 64);
        assert!(out.iter().any(|sample| *sample != 0.0));
        assert_eq!(out, direct(Kind::Ymf262, &timed(0), 600));
    }

    #[test]
    fn writes_a_register_and_its_two_port_writes_alike() {
        let (mut by_register, mut first) = opl3();
        let (mut by_port, mut second) = opl3();
        for (register, value) in NOTE {
            assert!(by_register.write(register | 0x100, value, 0.0));
            let batch = [
                RegisterWrite {
                    register: 2,
                    value: register & 0xff,
                },
                RegisterWrite {
                    register: 3,
                    value: u16::from(value),
                },
            ];
            assert!(by_port.writes(&batch, 0.0, true));
        }
        assert!(by_port.write_port(0, 0x20, 0.0));
        assert!(by_register.write(0x20, 0x00, 0.0));
        assert_eq!(pull(&mut first, 800, 64), pull(&mut second, 800, 64));
    }

    #[test]
    fn takes_a_key_off_and_on_due_on_one_sample_as_no_change() {
        let rate = f64::from(RATE);
        let (mut port, mut source) = opl2();
        for (register, value) in NOTE {
            assert!(port.write(register, value, 0.0));
        }
        // Released and keyed again on sample 500: both apply before it, so
        // the note holds as if neither had been sent.
        assert!(port.write(0xb0, 0x12, 500.0 / rate));
        assert!(port.write(0xb0, 0x32, 500.0 / rate));
        let out = pull(&mut source, 1500, 64);
        assert_eq!(out, direct(Kind::Ym3812, &timed(0), 1500));
    }

    #[test]
    fn runs_the_clock_in_chip_samples() {
        let (port, mut source) = opl2();
        assert_eq!(port.now(), 0.0);
        pull(&mut source, RATE as usize / 2, 512);
        assert_eq!(port.frames(), u64::from(RATE / 2));
        assert!((port.now() - f64::from(RATE / 2) / f64::from(RATE)).abs() < 1e-12);
        assert_eq!(source.sample_rate(), RATE);
        assert_eq!(source.channels(), 2);
        assert!(!source.exhausted());
    }

    /// The OPM's held sine on channel 0: algorithm 7, operator 4 alone at
    /// full level, keyed on. The OPZ shares the layout of these registers.
    const OPM_TONE: [(u16, u8); 10] = [
        (0x20, 0xc7),
        (0x60, 0x7f),
        (0x68, 0x7f),
        (0x70, 0x7f),
        (0x78, 0x00),
        (0x58, 0x01),
        (0x98, 0x1f),
        (0xf8, 0x0f),
        (0x28, 0x4a),
        (0x08, 0x40),
    ];

    /// The writes that sound a held tone on each chip through its register
    /// convenience.
    fn tone(kind: Kind) -> Vec<(u16, u8)> {
        match kind {
            Kind::Ym3526 | Kind::Y8950 | Kind::Ym3812 | Kind::Ymf262 | Kind::Ymf289b => {
                NOTE.to_vec()
            }
            Kind::Ymf278b => {
                let mut writes = vec![(0x105, 0x03)];
                writes.extend(NOTE);
                writes.push((0xc0, 0x30));
                writes
            }
            // The first instrument on channel 0 at full volume, keyed on.
            Kind::Ym2413 | Kind::Ym2423 | Kind::Ymf281 | Kind::Ds1001 => {
                vec![(0x30, 0x10), (0x10, 0xab), (0x20, 0x1c)]
            }
            Kind::Ym2151 | Kind::Ym2164 | Kind::Ym2414 => OPM_TONE.to_vec(),
            // Channel 0, or 1 on the YM2610, which has no channel 0: algorithm
            // 7, every operator at full level with the fastest attack, both
            // sides, keyed on.
            Kind::Ym2203
            | Kind::Ym2608
            | Kind::Ymf288
            | Kind::Ym2610
            | Kind::Ym2610b
            | Kind::Ym2612
            | Kind::Ym3438
            | Kind::Ymf276 => {
                let channel: u16 = if matches!(kind, Kind::Ym2610 | Kind::Ym2610b) {
                    1
                } else {
                    0
                };
                let mut writes = vec![(0x29, 0x80), (0xb0 + channel, 0x07), (0xb4 + channel, 0xc0)];
                for operator in [0x00, 0x04, 0x08, 0x0c] {
                    writes.push((0x30 + operator + channel, 0x01));
                    writes.push((0x40 + operator + channel, 0x00));
                    writes.push((0x50 + operator + channel, 0x1f));
                    writes.push((0x80 + operator + channel, 0x0f));
                }
                writes.push((0xa4 + channel, 0x22));
                writes.push((0xa0 + channel, 0x69));
                writes.push((0x28, 0xf0 | channel as u8));
                writes
            }
            // Algorithm 7 on channel 0, every operator at full level and the
            // fastest attack, keyed on.
            Kind::Ym3806 | Kind::Ym3533 => {
                let mut writes = vec![(0x10, 0xc7)];
                for operator in [0x00, 0x08, 0x10, 0x18] {
                    writes.push((0x40 + operator, 0x01));
                    writes.push((0x60 + operator, 0x00));
                    writes.push((0x80 + operator, 0x1f));
                    writes.push((0xe0 + operator, 0x0f));
                }
                writes.push((0x20, 0x4a));
                writes.push((0x28, 0x4a));
                writes.push((0x30, 0x4a));
                writes.push((0x38, 0x4a));
                writes.push((0x05, 0x78));
                writes
            }
            // Channel A on a tone at full volume.
            Kind::Ym2149 => vec![(0x00, 0xfe), (0x01, 0x00), (0x07, 0x3e), (0x08, 0x0f)],
        }
    }

    #[test]
    fn sounds_every_chip_and_folds_its_outputs_to_stereo() {
        for kind in Kind::ALL {
            let (mut port, mut source) = open(kind, kind.default_clock());
            for (register, value) in tone(kind) {
                assert!(port.write(register, value, 0.0), "{}", kind.name());
            }
            let out = pull_both(&mut source, 4000, 256);
            assert!(
                out.iter()
                    .all(|(left, right)| left.is_finite() && right.is_finite()),
                "{}",
                kind.name()
            );
            assert!(
                out.iter()
                    .any(|(left, right)| *left != 0.0 || *right != 0.0),
                "{} makes a sound",
                kind.name()
            );
            if kind.mono() {
                assert!(
                    out.iter().all(|(left, right)| left == right),
                    "{} is mono",
                    kind.name()
                );
            }
        }
    }

    #[test]
    fn removes_the_offset_of_a_held_ssg_level() {
        let kind = Kind::Ym2149;
        let (mut port, mut source) = open(kind, kind.default_clock());
        // Tone and noise off: the channel holds its level, which the filter
        // takes back to zero.
        for (register, value) in [(0x07, 0x3f), (0x08, 0x0f)] {
            assert!(port.write(register, value, 0.0));
        }
        let frames = kind.rate(kind.default_clock()) as usize;
        let out = pull(&mut source, frames, 512);
        assert!(out[1..100].iter().any(|sample| *sample > 0.0));
        assert!(out[out.len() - 100..]
            .iter()
            .all(|sample| sample.abs() < 1e-3));
    }

    #[test]
    fn averages_a_chip_that_renders_past_the_ceiling() {
        let kind = Kind::Ym2203;
        let clock = kind.default_clock();
        let (mut port, mut source) = open(kind, clock);
        let writes = tone(kind);
        for (register, value) in &writes {
            assert!(port.write(*register, *value, 0.0));
        }
        let out = pull(&mut source, 1000, 100);
        // The same writes straight into a chip, three samples a frame.
        let mut images = Images::default();
        let mut chip = Chip::new(kind, &mut images);
        for (register, value) in &writes {
            chip.register(kind, *register, *value);
        }
        let mut outputs = [0i32; MAX_OUTPUTS];
        let mut filter = DcBlocker::default();
        let pole = dc_pole(kind.rate(clock));
        for (index, sample) in out.iter().enumerate() {
            let mut sum = 0.0f32;
            for _ in 0..3 {
                chip.generate(&mut outputs);
                sum += outputs[0] as f32;
                for output in &outputs[1..4] {
                    sum += *output as f32 * SSG_SHARE;
                }
            }
            let expected = filter.process(sum * (1.0 / (32768.0 * 3.0)), pole);
            assert_eq!(*sample, expected, "frame {index}");
        }
        assert!(out.iter().any(|sample| *sample != 0.0));
    }

    #[test]
    fn takes_memory_only_of_a_class_the_chip_reads() {
        let (mut ym2612, _source) = open(Kind::Ym2612, Kind::Ym2612.default_clock());
        assert!(!ym2612.set_memory(MemoryClass::AdpcmA, &[1, 2, 3]));
        let (mut ym2610, _source) = open(Kind::Ym2610, Kind::Ym2610.default_clock());
        assert!(ym2610.set_memory(MemoryClass::AdpcmA, &[1, 2, 3]));
        assert!(ym2610.set_memory(MemoryClass::AdpcmB, &[1, 2, 3]));
        assert!(!ym2610.set_memory(MemoryClass::Pcm, &[1, 2, 3]));
        assert!(!ym2610.set_memory(MemoryClass::AdpcmA, &vec![0; MAX_IMAGE + 1]));
        let (mut opl4, _source) = open(Kind::Ymf278b, Kind::Ymf278b.default_clock());
        assert!(opl4.set_memory(MemoryClass::Pcm, &[0; 16]));
        let (mut y8950, _source) = open(Kind::Y8950, Kind::Y8950.default_clock());
        assert!(y8950.set_memory(MemoryClass::AdpcmB, &[0; 16]));
        assert!(!y8950.set_memory(MemoryClass::AdpcmA, &[0; 16]));
        // The memory queue is bounded and refuses rather than growing.
        let (mut full, _source) = open(Kind::Ym2608, Kind::Ym2608.default_clock());
        for _ in 0..MEMORY_QUEUE {
            assert!(full.set_memory(MemoryClass::AdpcmB, &[0; 4]));
        }
        assert!(!full.set_memory(MemoryClass::AdpcmB, &[0; 4]));
    }

    /// Plays channel 0 of a YM2610's ADPCM-A from `image`, and returns what
    /// the chip rendered.
    fn adpcm_a(image: Option<&[u8]>, reset: bool) -> Vec<f32> {
        let kind = Kind::Ym2610;
        let (mut port, mut source) = open(kind, kind.default_clock());
        if let Some(image) = image {
            assert!(port.set_memory(MemoryClass::AdpcmA, image));
        }
        if reset {
            assert!(port.reset(0.0));
        }
        // Start 0 and end 0x0f in 256-byte units, both sides at full level,
        // the total level at full, then key on.
        for (register, value) in [
            (0x110, 0x00),
            (0x118, 0x00),
            (0x120, 0x0f),
            (0x128, 0x00),
            (0x108, 0xdf),
            (0x101, 0x3f),
            (0x100, 0x01),
        ] {
            assert!(port.write(register, value, 0.0));
        }
        pull(&mut source, 2000, 128)
    }

    #[test]
    fn reads_samples_from_a_memory_image_and_keeps_it_across_a_reset() {
        let image: Vec<u8> = (0..4096u32).map(|index| (index * 37 % 251) as u8).collect();
        let silent = adpcm_a(None, false);
        let played = adpcm_a(Some(&image), false);
        assert_ne!(played, silent, "the image is what the channel plays");
        assert!(played.iter().any(|sample| *sample != 0.0));
        assert_eq!(
            adpcm_a(Some(&image), true),
            played,
            "a reset keeps the image"
        );
    }

    #[test]
    fn hands_a_displaced_image_back_to_the_game_thread() {
        let (mut port, mut source) = open(Kind::Ym2610, Kind::Ym2610.default_clock());
        for _ in 0..3 {
            assert!(port.set_memory(MemoryClass::AdpcmB, &[0; 64]));
        }
        pull(&mut source, 4, 4);
        // Each load displaced the one before it, the first the empty image,
        // so three came back.
        let mut returned = 0;
        while port.images_back.try_recv().is_ok() {
            returned += 1;
        }
        assert_eq!(returned, 3);
    }
}
