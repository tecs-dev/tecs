//! Tecs button and axis numbering, and the pure translation into it.
//!
//! The numbers here are this seam's own. SDL's enumerants left with SDL, and
//! nothing outside the process ever saw them: what a saved binding and a game
//! actually name is the string, and `src/tecs/input.nupp` maps a string to one
//! of these codes. Keeping the numbering here rather than deriving it from
//! `gilrs` is what lets the Nupp side stay ignorant of which backend produced
//! an event.
//!
//! Translation is a pure function over a [`Signal`] so it can be tested with no
//! gamepad, no `gilrs` context and no thread. The `gilrs` event enum is not
//! constructible in a test, because its `Code` payload has no public
//! constructor, so the caller reduces an event to a `Signal` first.

use gilrs::{Axis, Button};

/// Reports that a device appeared.
pub const KIND_ADDED: u32 = 1;

/// Reports that a device went away.
pub const KIND_REMOVED: u32 = 2;

/// Reports a button transition to held.
pub const KIND_BUTTON_DOWN: u32 = 3;

/// Reports a button transition to released.
pub const KIND_BUTTON_UP: u32 = 4;

/// Reports one axis's new value.
pub const KIND_AXIS: u32 = 5;

/// The positional button codes, in the order `src/tecs/input.nupp` names them.
pub mod button {
    pub const SOUTH: u32 = 1;
    pub const EAST: u32 = 2;
    pub const WEST: u32 = 3;
    pub const NORTH: u32 = 4;
    pub const BACK: u32 = 5;
    pub const GUIDE: u32 = 6;
    pub const START: u32 = 7;
    pub const LEFT_STICK: u32 = 8;
    pub const RIGHT_STICK: u32 = 9;
    pub const LEFT_SHOULDER: u32 = 10;
    pub const RIGHT_SHOULDER: u32 = 11;
    pub const DPAD_UP: u32 = 12;
    pub const DPAD_DOWN: u32 = 13;
    pub const DPAD_LEFT: u32 = 14;
    pub const DPAD_RIGHT: u32 = 15;

    /// The greatest code a button carries.
    pub const LAST: u32 = DPAD_RIGHT;
}

/// The axis codes, in the order `src/tecs/input.nupp` names them.
pub mod axis {
    pub const LEFT_X: u32 = 1;
    pub const LEFT_Y: u32 = 2;
    pub const RIGHT_X: u32 = 3;
    pub const RIGHT_Y: u32 = 4;
    pub const LEFT_TRIGGER: u32 = 5;
    pub const RIGHT_TRIGGER: u32 = 6;

    /// The greatest code an axis carries.
    pub const LAST: u32 = RIGHT_TRIGGER;
}

/// One observation crossing to Nupp.
///
/// The layout matches `cdef struct tecsGamepadEvent` in
/// `src/tecs/platform/gamepadnative.nupp`, and `tecs_gamepad_layout` reports
/// the size this build compiled so a drift is refused rather than misread.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GamepadEvent {
    /// One of the `KIND_` constants.
    pub kind: u32,
    /// The device the observation is about.
    pub device: u32,
    /// The button or axis code, and zero for a device event.
    pub code: u32,
    /// The axis value, and zero for every other kind.
    pub value: f32,
}

impl GamepadEvent {
    fn new(kind: u32, device: u32, code: u32, value: f32) -> Self {
        Self {
            kind,
            device,
            code,
            value,
        }
    }
}

/// What one `gilrs` event reduces to before translation.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Signal {
    /// The device connected.
    Connected,
    /// The device disconnected.
    Disconnected,
    /// A button changed between held and released.
    Button(Button, bool),
    /// A button reported an analog value, which is how a trigger arrives.
    ButtonValue(Button, f32),
    /// An axis reported a value.
    Axis(Axis, f32),
}

/// The hat position a device last reported, per device.
///
/// Some drivers report the directional pad as a two-valued axis rather than as
/// four buttons, and a game asking whether `"dpadLeft"` is held has no way to
/// read that. Remembering the last position is what lets an axis crossing the
/// threshold become the pair of button edges the rest of the engine already
/// understands.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct HatState {
    x: i8,
    y: i8,
}

/// The magnitude past which a hat axis counts as pressed.
const HAT_THRESHOLD: f32 = 0.5;

/// Returns the code a positional button carries, or zero when Tecs names none.
///
/// `gilrs` reports the shoulder bumpers as `LeftTrigger` and the analog
/// triggers as `LeftTrigger2`, which is the opposite of what the names suggest;
/// the analog pair leaves through [`trigger_axis`] instead. `C` and `Z` have no
/// Tecs name, because the positional vocabulary covers the pads a game ships
/// against and inventing two more names for a Sega layout would add a
/// compatibility surface with no reader.
pub fn button_code(button: Button) -> u32 {
    match button {
        Button::South => button::SOUTH,
        Button::East => button::EAST,
        Button::West => button::WEST,
        Button::North => button::NORTH,
        Button::Select => button::BACK,
        Button::Mode => button::GUIDE,
        Button::Start => button::START,
        Button::LeftThumb => button::LEFT_STICK,
        Button::RightThumb => button::RIGHT_STICK,
        Button::LeftTrigger => button::LEFT_SHOULDER,
        Button::RightTrigger => button::RIGHT_SHOULDER,
        Button::DPadUp => button::DPAD_UP,
        Button::DPadDown => button::DPAD_DOWN,
        Button::DPadLeft => button::DPAD_LEFT,
        Button::DPadRight => button::DPAD_RIGHT,
        Button::LeftTrigger2 | Button::RightTrigger2 | Button::C | Button::Z | Button::Unknown => 0,
    }
}

/// Returns the axis code an analog trigger reports through, or zero.
pub fn trigger_axis(button: Button) -> u32 {
    match button {
        Button::LeftTrigger2 => axis::LEFT_TRIGGER,
        Button::RightTrigger2 => axis::RIGHT_TRIGGER,
        _ => 0,
    }
}

/// Returns the code a stick or trigger axis carries, or zero.
///
/// The hat axes are absent deliberately: they become button edges in
/// [`translate`] rather than an axis a game would have to read a second way.
pub fn axis_code(value: Axis) -> u32 {
    match value {
        Axis::LeftStickX => axis::LEFT_X,
        Axis::LeftStickY => axis::LEFT_Y,
        Axis::RightStickX => axis::RIGHT_X,
        Axis::RightStickY => axis::RIGHT_Y,
        Axis::LeftZ => axis::LEFT_TRIGGER,
        Axis::RightZ => axis::RIGHT_TRIGGER,
        Axis::DPadX | Axis::DPadY | Axis::Unknown => 0,
    }
}

/// Reports whether an axis code points down the screen rather than up it.
///
/// `gilrs` reports a stick pushed away from the player as positive. Tecs has
/// always reported that as negative, because the engine's own vertical axis
/// grows downward and a game written against the Teal implementation reads
/// `axis("leftY") > 0` as "pull toward me". Flipping here keeps that true.
fn inverted(code: u32) -> bool {
    code == axis::LEFT_Y || code == axis::RIGHT_Y
}

/// Returns the hat position one threshold comparison settles on.
fn hat_step(value: f32) -> i8 {
    if value > HAT_THRESHOLD {
        1
    } else if value < -HAT_THRESHOLD {
        -1
    } else {
        0
    }
}

/// Appends the button edges a hat axis moving from `before` to `after` implies.
fn hat_edges(
    device: u32,
    before: i8,
    after: i8,
    negative: u32,
    positive: u32,
    out: &mut Vec<GamepadEvent>,
) {
    if before == after {
        return;
    }
    if before < 0 {
        out.push(GamepadEvent::new(KIND_BUTTON_UP, device, negative, 0.0));
    } else if before > 0 {
        out.push(GamepadEvent::new(KIND_BUTTON_UP, device, positive, 0.0));
    }
    if after < 0 {
        out.push(GamepadEvent::new(KIND_BUTTON_DOWN, device, negative, 0.0));
    } else if after > 0 {
        out.push(GamepadEvent::new(KIND_BUTTON_DOWN, device, positive, 0.0));
    }
}

/// Appends the observations one reduced `gilrs` event produces.
///
/// A signal Tecs names nothing for appends nothing, which is what keeps an
/// unmapped control off the queue rather than on it under a code no reader
/// resolves.
pub fn translate(device: u32, signal: Signal, hat: &mut HatState, out: &mut Vec<GamepadEvent>) {
    match signal {
        Signal::Connected => out.push(GamepadEvent::new(KIND_ADDED, device, 0, 0.0)),
        Signal::Disconnected => {
            *hat = HatState::default();
            out.push(GamepadEvent::new(KIND_REMOVED, device, 0, 0.0));
        }
        Signal::Button(button, down) => {
            let code = button_code(button);
            if code != 0 {
                let kind = if down {
                    KIND_BUTTON_DOWN
                } else {
                    KIND_BUTTON_UP
                };
                out.push(GamepadEvent::new(kind, device, code, 0.0));
                return;
            }
            // A trigger with no analog reading still has to reach the axis a
            // game reads it through, or a digital-only pad reports nothing.
            let trigger = trigger_axis(button);
            if trigger != 0 {
                let value = if down { 1.0 } else { 0.0 };
                out.push(GamepadEvent::new(KIND_AXIS, device, trigger, value));
            }
        }
        Signal::ButtonValue(button, value) => {
            let trigger = trigger_axis(button);
            if trigger != 0 {
                out.push(GamepadEvent::new(KIND_AXIS, device, trigger, value));
            }
        }
        Signal::Axis(input, value) => {
            if input == Axis::DPadX {
                let after = hat_step(value);
                hat_edges(
                    device,
                    hat.x,
                    after,
                    button::DPAD_LEFT,
                    button::DPAD_RIGHT,
                    out,
                );
                hat.x = after;
                return;
            }
            if input == Axis::DPadY {
                let after = hat_step(value);
                // Positive is away from the player, which is up on the pad.
                hat_edges(
                    device,
                    hat.y,
                    after,
                    button::DPAD_DOWN,
                    button::DPAD_UP,
                    out,
                );
                hat.y = after;
                return;
            }
            let code = axis_code(input);
            if code == 0 {
                return;
            }
            let signed = if inverted(code) { -value } else { value };
            out.push(GamepadEvent::new(KIND_AXIS, device, code, signed));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn drain(signals: &[Signal]) -> Vec<GamepadEvent> {
        let mut hat = HatState::default();
        let mut out = Vec::new();
        for signal in signals {
            translate(7, *signal, &mut hat, &mut out);
        }
        out
    }

    #[test]
    fn reports_connection_and_disconnection() {
        let events = drain(&[Signal::Connected, Signal::Disconnected]);
        assert_eq!(
            events,
            vec![
                GamepadEvent::new(KIND_ADDED, 7, 0, 0.0),
                GamepadEvent::new(KIND_REMOVED, 7, 0, 0.0),
            ]
        );
    }

    #[test]
    fn maps_positional_buttons_rather_than_hardware_labels() {
        let events = drain(&[
            Signal::Button(Button::South, true),
            Signal::Button(Button::South, false),
            Signal::Button(Button::Select, true),
            Signal::Button(Button::Mode, true),
            Signal::Button(Button::LeftTrigger, true),
        ]);
        assert_eq!(
            events,
            vec![
                GamepadEvent::new(KIND_BUTTON_DOWN, 7, button::SOUTH, 0.0),
                GamepadEvent::new(KIND_BUTTON_UP, 7, button::SOUTH, 0.0),
                GamepadEvent::new(KIND_BUTTON_DOWN, 7, button::BACK, 0.0),
                GamepadEvent::new(KIND_BUTTON_DOWN, 7, button::GUIDE, 0.0),
                GamepadEvent::new(KIND_BUTTON_DOWN, 7, button::LEFT_SHOULDER, 0.0),
            ]
        );
    }

    #[test]
    fn drops_a_control_tecs_names_nothing_for() {
        assert!(drain(&[
            Signal::Button(Button::C, true),
            Signal::Button(Button::Z, true),
            Signal::Axis(Axis::Unknown, 1.0),
        ])
        .is_empty());
    }

    #[test]
    fn reports_analog_triggers_as_axes() {
        let events = drain(&[
            Signal::ButtonValue(Button::LeftTrigger2, 0.25),
            Signal::Button(Button::RightTrigger2, true),
            Signal::Axis(Axis::RightZ, 0.75),
        ]);
        assert_eq!(
            events,
            vec![
                GamepadEvent::new(KIND_AXIS, 7, axis::LEFT_TRIGGER, 0.25),
                GamepadEvent::new(KIND_AXIS, 7, axis::RIGHT_TRIGGER, 1.0),
                GamepadEvent::new(KIND_AXIS, 7, axis::RIGHT_TRIGGER, 0.75),
            ]
        );
    }

    #[test]
    fn flips_the_vertical_sticks_and_leaves_the_horizontal_alone() {
        let events = drain(&[
            Signal::Axis(Axis::LeftStickY, 1.0),
            Signal::Axis(Axis::RightStickY, -0.5),
            Signal::Axis(Axis::LeftStickX, 1.0),
        ]);
        assert_eq!(
            events,
            vec![
                GamepadEvent::new(KIND_AXIS, 7, axis::LEFT_Y, -1.0),
                GamepadEvent::new(KIND_AXIS, 7, axis::RIGHT_Y, 0.5),
                GamepadEvent::new(KIND_AXIS, 7, axis::LEFT_X, 1.0),
            ]
        );
    }

    #[test]
    fn turns_a_hat_axis_into_directional_pad_edges() {
        let events = drain(&[
            Signal::Axis(Axis::DPadX, 1.0),
            Signal::Axis(Axis::DPadX, 0.0),
            Signal::Axis(Axis::DPadY, 1.0),
        ]);
        assert_eq!(
            events,
            vec![
                GamepadEvent::new(KIND_BUTTON_DOWN, 7, button::DPAD_RIGHT, 0.0),
                GamepadEvent::new(KIND_BUTTON_UP, 7, button::DPAD_RIGHT, 0.0),
                GamepadEvent::new(KIND_BUTTON_DOWN, 7, button::DPAD_UP, 0.0),
            ]
        );
    }

    #[test]
    fn releases_the_old_hat_direction_before_pressing_the_new_one() {
        let events = drain(&[
            Signal::Axis(Axis::DPadX, -1.0),
            Signal::Axis(Axis::DPadX, 1.0),
        ]);
        assert_eq!(
            events,
            vec![
                GamepadEvent::new(KIND_BUTTON_DOWN, 7, button::DPAD_LEFT, 0.0),
                GamepadEvent::new(KIND_BUTTON_UP, 7, button::DPAD_LEFT, 0.0),
                GamepadEvent::new(KIND_BUTTON_DOWN, 7, button::DPAD_RIGHT, 0.0),
            ]
        );
    }

    #[test]
    fn ignores_a_hat_axis_that_stays_inside_the_threshold() {
        assert!(drain(&[
            Signal::Axis(Axis::DPadX, 0.25),
            Signal::Axis(Axis::DPadY, -0.4)
        ])
        .is_empty());
    }
}
