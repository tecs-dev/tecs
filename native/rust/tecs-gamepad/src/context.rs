//! The `gilrs` context, the queue Nupp drains, and the rumble effects.
//!
//! Everything `gilrs` does happens behind this type, on whichever thread calls
//! [`Context::poll`]. On macOS `gilrs` runs an `IOHIDManager` on a `CFRunLoop`
//! of its own and posts through a channel; on Linux it reads `evdev`
//! descriptors and on Windows it polls XInput. None of those paths take a
//! function pointer from us, and none of them can reach Nupp: an observation
//! becomes an event in [`Context::queue`] and leaves only when the frame thread
//! asks for it.

use std::collections::HashMap;
use std::ffi::CString;

use gilrs::ff::{BaseEffect, BaseEffectType, Effect, EffectBuilder, Repeat, Replay, Ticks};
use gilrs::{Axis, Button, EventType, Gilrs, GilrsBuilder, PowerInfo};

use crate::codes::{self, GamepadEvent, HatState, Signal};

/// Reports that the power source could not be determined.
pub const POWER_UNKNOWN: u32 = 0;

/// Reports a device with no battery, which is a wired one.
pub const POWER_NO_BATTERY: u32 = 1;

/// Reports a device running on its battery.
pub const POWER_ON_BATTERY: u32 = 2;

/// Reports a device whose battery is filling.
pub const POWER_CHARGING: u32 = 3;

/// Reports a device whose battery is full.
pub const POWER_CHARGED: u32 = 4;

/// What one device reports about itself.
///
/// The layout matches `cdef struct tecsGamepadInfo` in
/// `src/tecs/platform/gamepadnative.nupp`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct GamepadInfo {
    /// Nonzero while the device is attached.
    pub connected: i32,
    /// One bit per present button code, at `1 << (code - 1)`.
    pub buttons: u32,
    /// One bit per present axis code, at `1 << (code - 1)`.
    pub axes: u32,
    /// Nonzero when the device accepts rumble.
    pub force_feedback: i32,
    /// One of the `POWER_` constants.
    pub power_state: u32,
    /// The battery percentage, and -1 when the device will not say.
    pub power_percent: i32,
}

/// Selects which string `Context::string` returns.
pub const STRING_NAME: u32 = 0;

/// Selects the stable identity a saved binding matches on.
pub const STRING_GUID: u32 = 1;

/// Selects the name the operating system reports for the device.
pub const STRING_OS_NAME: u32 = 2;

/// The greatest number of events one poll leaves queued.
///
/// A queue that grew without bound would turn a frame the game never drained
/// into memory the process never gets back. Dropping the oldest is right rather
/// than dropping the newest: the newest carries the current state, and a button
/// edge older than eight thousand events is not one a game is still waiting for.
const QUEUE_LIMIT: usize = 8192;

/// Everything one process needs to read gamepads.
pub struct Context {
    gilrs: Option<Gilrs>,
    queue: Vec<GamepadEvent>,
    read: usize,
    hats: HashMap<u32, HatState>,
    identities: HashMap<u32, gilrs::GamepadId>,
    effects: HashMap<u32, Effect>,
    scratch: Option<CString>,
    failure: Option<CString>,
}

/// Reduces one `gilrs` event to what translation needs.
fn signal(event: &EventType) -> Option<Signal> {
    match *event {
        EventType::Connected => Some(Signal::Connected),
        EventType::Disconnected => Some(Signal::Disconnected),
        EventType::ButtonPressed(button, _) => Some(Signal::Button(button, true)),
        EventType::ButtonReleased(button, _) => Some(Signal::Button(button, false)),
        EventType::ButtonChanged(button, value, _) => Some(Signal::ButtonValue(button, value)),
        EventType::AxisChanged(axis, value, _) => Some(Signal::Axis(axis, value)),
        // A repeat is not a press, a dropped event was already filtered out,
        // and a finished effect is something this crate started rather than
        // something the player did.
        _ => None,
    }
}

/// Returns the magnitude a zero-to-one strength maps onto.
fn magnitude(strength: f32) -> u16 {
    let clamped = strength.clamp(0.0, 1.0);
    (clamped * f32::from(u16::MAX)).round() as u16
}

impl Context {
    /// Opens the platform's gamepad source.
    ///
    /// A machine with no gamepad support still answers with a context.
    /// [`Context::available`] reports false on one, every call still answers,
    /// and no device ever appears.
    pub fn open() -> Self {
        let gilrs = GilrsBuilder::new().set_update_state(true).build();
        let (gilrs, failure) = match gilrs {
            Ok(opened) => (Some(opened), None),
            // `NotImplemented` hands the context back, but a context on a
            // platform with no backend reports nothing, so it is dropped here
            // and the reason is kept for the binding to read.
            Err(gilrs::Error::NotImplemented(_)) => {
                (None, Some("gilrs has no backend on this platform"))
            }
            Err(_) => (None, Some("gilrs could not open the gamepad source")),
        };
        let mut context = Self {
            gilrs,
            queue: Vec::new(),
            read: 0,
            hats: HashMap::new(),
            identities: HashMap::new(),
            effects: HashMap::new(),
            scratch: None,
            failure: None,
        };
        if let Some(reason) = failure {
            context.fail(reason);
        }
        // A device attached before the process started produces no connection
        // event, so the first poll would find nothing. Announcing what is
        // already there makes an attach and a cold start read the same.
        let attached: Vec<u32> = context.attached();
        for device in attached {
            context
                .queue
                .push(GamepadEvent::new_device(codes::KIND_ADDED, device));
        }
        context
    }

    /// Opens a context with no backend at all.
    ///
    /// This is what a headless build gets and what a test that must not touch
    /// a device asks for.
    pub fn open_detached() -> Self {
        Self {
            gilrs: None,
            queue: Vec::new(),
            read: 0,
            hats: HashMap::new(),
            identities: HashMap::new(),
            effects: HashMap::new(),
            scratch: None,
            failure: None,
        }
    }

    /// Reports whether a real gamepad source opened.
    pub fn available(&self) -> bool {
        self.gilrs.is_some()
    }

    /// Records a failure for the next `tecs_gamepad_last_error`.
    fn fail(&mut self, reason: &str) {
        self.failure = CString::new(reason).ok();
    }

    /// Returns the last recorded failure.
    pub fn failure(&self) -> Option<&CString> {
        self.failure.as_ref()
    }

    /// Returns the identifiers of every attached device.
    pub fn attached(&mut self) -> Vec<u32> {
        let Some(gilrs) = self.gilrs.as_ref() else {
            return Vec::new();
        };
        let mut found = Vec::new();
        let mut seen = Vec::new();
        for (id, _) in gilrs.gamepads() {
            let device = usize::from(id) as u32;
            found.push(device);
            seen.push((device, id));
        }
        for (device, id) in seen {
            self.identities.insert(device, id);
        }
        found
    }

    /// Reads everything the platform has produced since the previous poll.
    ///
    /// Returns how many observations are waiting to be drained.
    pub fn poll(&mut self) -> usize {
        self.compact();
        let Some(gilrs) = self.gilrs.as_mut() else {
            return 0;
        };
        gilrs.inc();
        while let Some(event) = gilrs.next_event() {
            let device = usize::from(event.id) as u32;
            self.identities.insert(device, event.id);
            let Some(reduced) = signal(&event.event) else {
                continue;
            };
            let hat = self.hats.entry(device).or_default();
            codes::translate(device, reduced, hat, &mut self.queue);
        }
        if self.queue.len() > QUEUE_LIMIT {
            let excess = self.queue.len() - QUEUE_LIMIT;
            self.queue.drain(0..excess);
        }
        self.queue.len()
    }

    /// Drops the events already drained, so the queue does not grow forever.
    fn compact(&mut self) {
        if self.read == 0 {
            return;
        }
        self.queue.drain(0..self.read);
        self.read = 0;
    }

    /// Copies at most `out.len()` waiting observations and returns the count.
    pub fn drain(&mut self, out: &mut [GamepadEvent]) -> usize {
        let mut written = 0;
        while written < out.len() && self.read < self.queue.len() {
            out[written] = self.queue[self.read];
            self.read += 1;
            written += 1;
        }
        written
    }

    /// Reports what one device says about itself.
    pub fn info(&self, device: u32) -> GamepadInfo {
        let Some(gilrs) = self.gilrs.as_ref() else {
            return GamepadInfo::default();
        };
        let Some(id) = self.identities.get(&device) else {
            return GamepadInfo::default();
        };
        let pad = gilrs.gamepad(*id);
        let mut buttons = 0u32;
        for button in EVERY_BUTTON {
            let code = codes::button_code(button);
            if code != 0 && pad.button_code(button).is_some() {
                buttons |= 1 << (code - 1);
            }
        }
        let mut axes = 0u32;
        for axis in EVERY_AXIS {
            let code = codes::axis_code(axis);
            if code != 0 && pad.axis_code(axis).is_some() {
                axes |= 1 << (code - 1);
            }
        }
        // A trigger reaches a game as an axis, so a pad reporting it as a
        // button still has to declare the axis or `hasAxis` denies what
        // `axis` then answers.
        for button in [Button::LeftTrigger2, Button::RightTrigger2] {
            let code = codes::trigger_axis(button);
            if code != 0 && pad.button_code(button).is_some() {
                axes |= 1 << (code - 1);
            }
        }
        let (state, percent) = match pad.power_info() {
            PowerInfo::Unknown => (POWER_UNKNOWN, -1),
            PowerInfo::Wired => (POWER_NO_BATTERY, -1),
            PowerInfo::Discharging(level) => (POWER_ON_BATTERY, i32::from(level)),
            PowerInfo::Charging(level) => (POWER_CHARGING, i32::from(level)),
            PowerInfo::Charged => (POWER_CHARGED, 100),
        };
        GamepadInfo {
            connected: i32::from(pad.is_connected()),
            buttons,
            axes,
            force_feedback: i32::from(pad.is_ff_supported()),
            power_state: state,
            power_percent: percent,
        }
    }

    /// Returns one of a device's strings, valid until the next such call.
    pub fn string(&mut self, device: u32, which: u32) -> Option<&CString> {
        let gilrs = self.gilrs.as_ref()?;
        let id = *self.identities.get(&device)?;
        let pad = gilrs.gamepad(id);
        let value = match which {
            STRING_NAME => pad.name().to_owned(),
            STRING_OS_NAME => pad.os_name().to_owned(),
            STRING_GUID => uuid_text(pad.uuid()),
            _ => return None,
        };
        self.scratch = CString::new(value).ok();
        self.scratch.as_ref()
    }

    /// Plays one rumble effect, replacing whatever the device was playing.
    ///
    /// Returns false when the platform has no force feedback, which is what a
    /// macOS build always answers: `gilrs` implements force feedback on `evdev`
    /// and XInput and not on `IOKit`.
    pub fn rumble(&mut self, device: u32, low: f32, high: f32, seconds: f32) -> bool {
        // Dropping the previous effect stops it, which is what makes a second
        // rumble replace the first rather than sum with it.
        self.effects.remove(&device);
        if seconds <= 0.0 || !seconds.is_finite() {
            return true;
        }
        let Some(gilrs) = self.gilrs.as_mut() else {
            return false;
        };
        let Some(id) = self.identities.get(&device).copied() else {
            return false;
        };
        if !gilrs.gamepad(id).is_ff_supported() {
            return false;
        }
        let milliseconds = (seconds * 1000.0).min(f32::from(u16::MAX)) as u32;
        let play_for = Ticks::from_ms(milliseconds);
        let scheduling = Replay {
            after: Ticks::from_ms(0),
            play_for,
            with_delay: Ticks::from_ms(0),
        };
        let built = EffectBuilder::new()
            .add_effect(BaseEffect {
                kind: BaseEffectType::Weak {
                    magnitude: magnitude(low),
                },
                scheduling,
                envelope: Default::default(),
            })
            .add_effect(BaseEffect {
                kind: BaseEffectType::Strong {
                    magnitude: magnitude(high),
                },
                scheduling,
                envelope: Default::default(),
            })
            .repeat(Repeat::For(play_for))
            .gamepads(&[id])
            .finish(gilrs);
        let effect = match built {
            Ok(effect) => effect,
            Err(error) => {
                self.fail(&format!("gilrs refused the rumble effect: {error}"));
                return false;
            }
        };
        if let Err(error) = effect.play() {
            self.fail(&format!("gilrs could not play the rumble effect: {error}"));
            return false;
        }
        self.effects.insert(device, effect);
        true
    }
}

/// Every button a device can report, for the capability mask.
const EVERY_BUTTON: [Button; 15] = [
    Button::South,
    Button::East,
    Button::West,
    Button::North,
    Button::Select,
    Button::Mode,
    Button::Start,
    Button::LeftThumb,
    Button::RightThumb,
    Button::LeftTrigger,
    Button::RightTrigger,
    Button::DPadUp,
    Button::DPadDown,
    Button::DPadLeft,
    Button::DPadRight,
];

/// Every axis a device can report, for the capability mask.
const EVERY_AXIS: [Axis; 6] = [
    Axis::LeftStickX,
    Axis::LeftStickY,
    Axis::RightStickX,
    Axis::RightStickY,
    Axis::LeftZ,
    Axis::RightZ,
];

/// Formats a device identity the way a saved binding stores it.
///
/// Lowercase hexadecimal with no separators, because the value is matched
/// rather than read, and a separator is one more thing two writers can disagree
/// about.
fn uuid_text(bytes: [u8; 16]) -> String {
    let mut text = String::with_capacity(32);
    for byte in bytes {
        text.push_str(&format!("{byte:02x}"));
    }
    text
}

impl GamepadEvent {
    /// Returns a device event, which carries no code and no value.
    pub fn new_device(kind: u32, device: u32) -> Self {
        Self {
            kind,
            device,
            code: 0,
            value: 0.0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_detached_context_reports_nothing() {
        let mut context = Context::open_detached();
        assert!(!context.available());
        assert_eq!(context.poll(), 0);
        let mut out = [GamepadEvent::new_device(0, 0); 4];
        assert_eq!(context.drain(&mut out), 0);
        assert!(context.attached().is_empty());
        assert_eq!(context.info(0), GamepadInfo::default());
        assert!(context.string(0, STRING_NAME).is_none());
        assert!(!context.rumble(0, 1.0, 1.0, 0.5));
    }

    #[test]
    fn drains_in_order_and_across_calls() {
        let mut context = Context::open_detached();
        for index in 0..5u32 {
            context
                .queue
                .push(GamepadEvent::new_device(codes::KIND_ADDED, index));
        }
        let mut out = [GamepadEvent::new_device(0, 0); 2];
        assert_eq!(context.drain(&mut out), 2);
        assert_eq!(out[0].device, 0);
        assert_eq!(out[1].device, 1);
        assert_eq!(context.drain(&mut out), 2);
        assert_eq!(out[0].device, 2);
        assert_eq!(context.drain(&mut out), 1);
        assert_eq!(out[0].device, 4);
        assert_eq!(context.drain(&mut out), 0);
    }

    #[test]
    fn a_poll_drops_what_was_already_drained() {
        let mut context = Context::open_detached();
        context
            .queue
            .push(GamepadEvent::new_device(codes::KIND_ADDED, 1));
        let mut out = [GamepadEvent::new_device(0, 0); 1];
        assert_eq!(context.drain(&mut out), 1);
        assert_eq!(context.poll(), 0);
        assert!(context.queue.is_empty());
    }

    #[test]
    fn rumble_with_no_duration_only_stops_what_was_playing() {
        let mut context = Context::open_detached();
        assert!(context.rumble(0, 1.0, 1.0, 0.0));
    }

    #[test]
    fn scales_strength_across_the_whole_magnitude_range() {
        assert_eq!(magnitude(0.0), 0);
        assert_eq!(magnitude(1.0), u16::MAX);
        assert_eq!(magnitude(-3.0), 0);
        assert_eq!(magnitude(7.0), u16::MAX);
    }

    #[test]
    fn formats_a_device_identity_as_plain_hexadecimal() {
        let mut bytes = [0u8; 16];
        bytes[0] = 0x03;
        bytes[15] = 0xfe;
        assert_eq!(uuid_text(bytes), "030000000000000000000000000000fe");
    }
}
