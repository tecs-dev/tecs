use std::path::Path;

use crate::sdk::{HostRuntime, ManagedHandle, ManagedValue};
use anyhow::{anyhow, bail, Context, Result};

const EXPORT_NAMES: &[&str] = &[
    "tecs.host.create",
    "tecs.host.init",
    "tecs.host.iterate",
    "tecs.host.shutdown",
    "tecs.host.crashed",
    "tecs.host.setSuspended",
    "tecs.host.attachWindow",
    "tecs.host.applyWindowState",
    "tecs.host.detachWindow",
    "tecs.host.pushClose",
    "tecs.host.pushResize",
    "tecs.host.pushFocus",
    "tecs.host.pushKey",
    "tecs.host.pushPointerMove",
    "tecs.host.pushPointerButton",
    "tecs.host.pushWheel",
    "tecs.host.pushText",
    "tecs.host.pushTouch",
    "tecs.host.nextWindowCommand",
    "tecs.host.windowCommandFailed",
    "tecs.host.renderPacket",
    "tecs.host.nextImageCommand",
    "tecs.host.imageCommandResult",
];

#[derive(Clone, Debug, PartialEq)]
pub struct WindowState {
    pub id: u64,
    pub title: String,
    pub width: u32,
    pub height: u32,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub scale_factor: f64,
    pub x: i32,
    pub y: i32,
    pub focused: bool,
    pub visible: bool,
    pub minimized: bool,
    pub maximized: bool,
    pub fullscreen: bool,
    pub occluded: bool,
    pub resizable: bool,
    pub cursor_visible: bool,
    pub cursor_grab: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct WindowCommand {
    pub kind: String,
    pub serial: u64,
    pub text: Option<String>,
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub flag: Option<bool>,
}

/// One drained image residency request. `pixels` is empty for a release.
#[derive(Clone, Debug, PartialEq)]
pub struct ImageCommand {
    pub kind: String,
    pub serial: u64,
    pub image: u32,
    pub width: u32,
    pub height: u32,
    pub sampler: u32,
    pub format: String,
    pub pixels: Vec<u8>,
}

/// One finger crossing into Nupp.
///
/// The fields travel together because they are one observation, and twelve
/// positional arguments at a call site is where a transposed coordinate pair
/// hides.
pub struct TouchEvent<'a> {
    /// One of `fingerDown`, `fingerMotion`, `fingerUp` or `fingerCanceled`.
    pub phase: &'a str,
    /// The touch surface's opaque identity.
    pub device: &'a str,
    /// The finger's opaque identity on that surface.
    pub finger: &'a str,
    /// The position in logical window coordinates.
    pub x: f64,
    /// The position in logical window coordinates.
    pub y: f64,
    /// The position across the surface, from zero to one.
    pub normal_x: f64,
    /// The position down the surface, from zero to one.
    pub normal_y: f64,
    /// The reported pressure from zero to one, and zero where the surface does
    /// not measure it.
    pub pressure: f64,
    /// The movement since this finger's previous event.
    pub dx: f64,
    /// The movement since this finger's previous event.
    pub dy: f64,
    /// The host time this observation carries.
    pub timestamp: f64,
    /// The host's ordering number for this batch.
    pub sequence: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FrameState {
    Parked,
    Continue,
    Stopped,
}

struct Exports {
    init: ManagedHandle,
    iterate: ManagedHandle,
    shutdown: ManagedHandle,
    crashed: ManagedHandle,
    set_suspended: ManagedHandle,
    attach_window: ManagedHandle,
    apply_window_state: ManagedHandle,
    detach_window: ManagedHandle,
    push_close: ManagedHandle,
    push_resize: ManagedHandle,
    push_focus: ManagedHandle,
    push_key: ManagedHandle,
    push_pointer_move: ManagedHandle,
    push_pointer_button: ManagedHandle,
    push_wheel: ManagedHandle,
    push_text: ManagedHandle,
    push_touch: ManagedHandle,
    next_window_command: ManagedHandle,
    window_command_failed: ManagedHandle,
    render_packet: ManagedHandle,
    next_image_command: ManagedHandle,
    image_command_result: ManagedHandle,
}

pub struct Bridge {
    runtime: HostRuntime,
    session: ManagedHandle,
    exports: Exports,
}

/// Everything a managed session needs to exist.
///
/// The fields travel together because they are one decision the caller has
/// already made, and passing them as one borrowed descriptor keeps each call
/// site reading as the configuration it came from rather than as an ordered
/// list of eight values whose order nothing checks.
pub struct SessionOptions<'a> {
    /// The running host executable, which the Nupp runtime resolves against.
    pub executable: &'a Path,
    /// The compiled Nupp component to load.
    pub component: &'a Path,
    /// The exported session constructor the game selected.
    pub entry: &'a str,
    /// The desktop window title.
    pub title: &'a str,
    /// The initial logical width.
    pub width: u32,
    /// The initial logical height.
    pub height: u32,
    /// Whether a guarded application failure may be cleared.
    pub debug: bool,
    /// An optional positive frame limit for a bounded run.
    pub max_frames: Option<u32>,
}

impl Bridge {
    pub fn load(options: &SessionOptions<'_>) -> Result<Self> {
        let SessionOptions {
            executable,
            component: component_path,
            entry: entry_export,
            title,
            width,
            height,
            debug,
            max_frames,
        } = *options;
        let mut runtime = HostRuntime::new(executable).context("create the Nupp runtime")?;
        let bytes = std::fs::read(component_path)
            .with_context(|| format!("read Nupp component {}", component_path.display()))?;
        let component = runtime
            .load_component(&bytes, &component_path.display().to_string())
            .context("load the Tecs Nupp component")?;
        let handles = EXPORT_NAMES
            .iter()
            .map(|name| {
                runtime
                    .find_export(component, name)
                    .with_context(|| format!("find Nupp export {name}"))
            })
            .collect::<Result<Vec<_>>>()?;
        let create = if entry_export == EXPORT_NAMES[0] {
            handles[0]
        } else {
            runtime
                .find_export(component, entry_export)
                .with_context(|| format!("find Nupp game entry export {entry_export}"))?
        };
        runtime
            .start_component(component, &[])
            .context("start the Tecs Nupp component")?;

        let exports = Exports::from_handles(&handles)?;
        let values = runtime
            .call(
                create,
                &[
                    text(title),
                    number(width),
                    number(height),
                    ManagedValue::Boolean(debug),
                    max_frames.map_or(ManagedValue::Nil, number),
                ],
            )
            .with_context(|| {
                format!("create the Tecs application session through {entry_export}")
            })?;
        let session = one_handle(&values, entry_export)?;

        Ok(Self {
            runtime,
            session,
            exports,
        })
    }

    pub fn init(&mut self) -> Result<bool> {
        let values = self.call(self.exports.init, &[])?;
        one_boolean(&values, "tecs.host.init")
    }

    pub fn iterate(&mut self, dt: f64) -> Result<FrameState> {
        let values = self.call(self.exports.iterate, &[ManagedValue::Number(dt)])?;
        match one_text(&values, "tecs.host.iterate")?.as_str() {
            "parked" => Ok(FrameState::Parked),
            "continue" => Ok(FrameState::Continue),
            "stopped" => Ok(FrameState::Stopped),
            state => bail!("tecs.host.iterate returned unknown frame state {state:?}"),
        }
    }

    pub fn shutdown(&mut self) -> Result<()> {
        let export = self.exports.shutdown;
        let _ = self.call(export, &[])?;
        self.runtime
            .shutdown()
            .context("shut down the Nupp runtime")
    }

    pub fn crashed(&mut self) -> Result<Option<String>> {
        let values = self.call(self.exports.crashed, &[])?;
        optional_text(&values, 0, "tecs.host.crashed")
    }

    pub fn render_packet(&mut self) -> Result<Vec<u8>> {
        let values = self.call(self.exports.render_packet, &[])?;
        one_bytes(&values, "tecs.host.renderPacket")
    }

    pub fn set_suspended(&mut self, suspended: bool) -> Result<()> {
        let export = self.exports.set_suspended;
        self.call(export, &[ManagedValue::Boolean(suspended)])?;
        Ok(())
    }

    pub fn attach_window(&mut self, state: &WindowState) -> Result<()> {
        let arguments = state_values(state);
        let export = self.exports.attach_window;
        self.call(export, &arguments)?;
        Ok(())
    }

    pub fn apply_window_state(&mut self, state: &WindowState) -> Result<()> {
        let arguments = state_values(state);
        let export = self.exports.apply_window_state;
        self.call(export, &arguments)?;
        Ok(())
    }

    pub fn detach_window(&mut self) -> Result<()> {
        let export = self.exports.detach_window;
        self.call(export, &[])?;
        Ok(())
    }

    pub fn push_close(&mut self, timestamp: f64, sequence: u64) -> Result<()> {
        let export = self.exports.push_close;
        self.call(
            export,
            &[ManagedValue::Number(timestamp), unsigned(sequence)],
        )?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn push_resize(
        &mut self,
        scale_changed: bool,
        width: u32,
        height: u32,
        pixel_width: u32,
        pixel_height: u32,
        scale_factor: f64,
        timestamp: f64,
        sequence: u64,
    ) -> Result<()> {
        let export = self.exports.push_resize;
        self.call(
            export,
            &[
                ManagedValue::Boolean(scale_changed),
                number(width),
                number(height),
                number(pixel_width),
                number(pixel_height),
                ManagedValue::Number(scale_factor),
                ManagedValue::Number(timestamp),
                unsigned(sequence),
            ],
        )?;
        Ok(())
    }

    pub fn push_focus(&mut self, focused: bool, timestamp: f64, sequence: u64) -> Result<()> {
        let export = self.exports.push_focus;
        self.call(
            export,
            &[
                ManagedValue::Boolean(focused),
                ManagedValue::Number(timestamp),
                unsigned(sequence),
            ],
        )?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn push_key(
        &mut self,
        down: bool,
        physical_key: &str,
        logical_key: Option<&str>,
        key_text: Option<&str>,
        modifiers: u8,
        repeated: bool,
        timestamp: f64,
        sequence: u64,
    ) -> Result<()> {
        let export = self.exports.push_key;
        self.call(
            export,
            &[
                ManagedValue::Boolean(down),
                text(physical_key),
                optional_text_value(logical_key),
                optional_text_value(key_text),
                number(modifiers),
                ManagedValue::Boolean(repeated),
                ManagedValue::Number(timestamp),
                unsigned(sequence),
            ],
        )?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn push_pointer_move(
        &mut self,
        x: f64,
        y: f64,
        dx: f64,
        dy: f64,
        timestamp: f64,
        sequence: u64,
    ) -> Result<()> {
        let export = self.exports.push_pointer_move;
        self.call(
            export,
            &[
                ManagedValue::Number(x),
                ManagedValue::Number(y),
                ManagedValue::Number(dx),
                ManagedValue::Number(dy),
                ManagedValue::Number(timestamp),
                unsigned(sequence),
            ],
        )?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn push_pointer_button(
        &mut self,
        down: bool,
        button: u16,
        x: f64,
        y: f64,
        timestamp: f64,
        sequence: u64,
    ) -> Result<()> {
        let export = self.exports.push_pointer_button;
        self.call(
            export,
            &[
                ManagedValue::Boolean(down),
                number(button),
                ManagedValue::Number(x),
                ManagedValue::Number(y),
                ManagedValue::Number(timestamp),
                unsigned(sequence),
            ],
        )?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn push_wheel(
        &mut self,
        wheel_x: f64,
        wheel_y: f64,
        ticks_x: i64,
        ticks_y: i64,
        x: f64,
        y: f64,
        timestamp: f64,
        sequence: u64,
    ) -> Result<()> {
        let export = self.exports.push_wheel;
        self.call(
            export,
            &[
                ManagedValue::Number(wheel_x),
                ManagedValue::Number(wheel_y),
                signed(ticks_x),
                signed(ticks_y),
                ManagedValue::Number(x),
                ManagedValue::Number(y),
                ManagedValue::Number(timestamp),
                unsigned(sequence),
            ],
        )?;
        Ok(())
    }

    pub fn push_text(&mut self, value: &str, timestamp: f64, sequence: u64) -> Result<()> {
        let export = self.exports.push_text;
        self.call(
            export,
            &[
                text(value),
                ManagedValue::Number(timestamp),
                unsigned(sequence),
            ],
        )?;
        Ok(())
    }

    /// Queues one finger's transition or movement on a touch surface.
    ///
    /// The device and finger identities cross as text because both are 64-bit
    /// platform values, and a Lua number would round two fingers into one.
    pub fn push_touch(&mut self, touch: &TouchEvent<'_>) -> Result<()> {
        let export = self.exports.push_touch;
        self.call(
            export,
            &[
                text(touch.phase),
                text(touch.device),
                text(touch.finger),
                ManagedValue::Number(touch.x),
                ManagedValue::Number(touch.y),
                ManagedValue::Number(touch.normal_x),
                ManagedValue::Number(touch.normal_y),
                ManagedValue::Number(touch.pressure),
                ManagedValue::Number(touch.dx),
                ManagedValue::Number(touch.dy),
                ManagedValue::Number(touch.timestamp),
                unsigned(touch.sequence),
            ],
        )?;
        Ok(())
    }

    pub fn next_window_command(&mut self) -> Result<Option<WindowCommand>> {
        let values = self.call(self.exports.next_window_command, &[])?;
        let Some(kind) = optional_text(&values, 0, "tecs.host.nextWindowCommand kind")? else {
            return Ok(None);
        };
        let serial = required_number(&values, 1, "tecs.host.nextWindowCommand serial")?;
        Ok(Some(WindowCommand {
            kind,
            serial: exact_u64(serial, "window command serial")?,
            text: optional_text(&values, 2, "tecs.host.nextWindowCommand text")?,
            x: optional_number(&values, 3, "tecs.host.nextWindowCommand x")?,
            y: optional_number(&values, 4, "tecs.host.nextWindowCommand y")?,
            flag: optional_boolean(&values, 5, "tecs.host.nextWindowCommand flag")?,
        }))
    }

    pub fn next_image_command(&mut self) -> Result<Option<ImageCommand>> {
        let values = self.call(self.exports.next_image_command, &[])?;
        let Some(kind) = optional_text(&values, 0, "tecs.host.nextImageCommand kind")? else {
            return Ok(None);
        };
        let serial = required_number(&values, 1, "tecs.host.nextImageCommand serial")?;
        let image = required_number(&values, 2, "tecs.host.nextImageCommand image")?;
        let release = kind == "releaseImage";
        Ok(Some(ImageCommand {
            kind,
            serial: exact_u64(serial, "image command serial")?,
            image: exact_u32(image, "image command id")?,
            width: optional_u32(&values, 3, "tecs.host.nextImageCommand width")?,
            height: optional_u32(&values, 4, "tecs.host.nextImageCommand height")?,
            sampler: optional_u32(&values, 5, "tecs.host.nextImageCommand sampler")?,
            format: optional_text(&values, 6, "tecs.host.nextImageCommand format")?
                .unwrap_or_default(),
            pixels: if release {
                Vec::new()
            } else {
                optional_bytes(&values, 7, "tecs.host.nextImageCommand pixels")?
            },
        }))
    }

    pub fn report_image_result(
        &mut self,
        image: u32,
        serial: u64,
        reason: Option<&str>,
    ) -> Result<()> {
        let export = self.exports.image_command_result;
        self.call(
            export,
            &[
                number(image),
                unsigned(serial),
                ManagedValue::Boolean(reason.is_none()),
                optional_text_value(reason),
            ],
        )?;
        Ok(())
    }

    pub fn report_window_failure(&mut self, serial: u64, reason: &str) -> Result<()> {
        let export = self.exports.window_command_failed;
        self.call(export, &[unsigned(serial), text(reason)])?;
        Ok(())
    }

    fn call(
        &mut self,
        export: ManagedHandle,
        arguments: &[ManagedValue],
    ) -> Result<Vec<ManagedValue>> {
        let mut passed = Vec::with_capacity(arguments.len() + 1);
        passed.push(ManagedValue::Handle(self.session));
        passed.extend_from_slice(arguments);
        self.runtime.call(export, &passed)
    }
}

impl Exports {
    fn from_handles(handles: &[ManagedHandle]) -> Result<Self> {
        if handles.len() != EXPORT_NAMES.len() {
            bail!("internal export table length mismatch");
        }
        Ok(Self {
            init: handles[1],
            iterate: handles[2],
            shutdown: handles[3],
            crashed: handles[4],
            set_suspended: handles[5],
            attach_window: handles[6],
            apply_window_state: handles[7],
            detach_window: handles[8],
            push_close: handles[9],
            push_resize: handles[10],
            push_focus: handles[11],
            push_key: handles[12],
            push_pointer_move: handles[13],
            push_pointer_button: handles[14],
            push_wheel: handles[15],
            push_text: handles[16],
            push_touch: handles[17],
            next_window_command: handles[18],
            window_command_failed: handles[19],
            render_packet: handles[20],
            next_image_command: handles[21],
            image_command_result: handles[22],
        })
    }
}

fn state_values(state: &WindowState) -> Vec<ManagedValue> {
    vec![
        unsigned(state.id),
        text(&state.title),
        number(state.width),
        number(state.height),
        number(state.pixel_width),
        number(state.pixel_height),
        ManagedValue::Number(state.scale_factor),
        number(state.x),
        number(state.y),
        ManagedValue::Boolean(state.focused),
        ManagedValue::Boolean(state.visible),
        ManagedValue::Boolean(state.minimized),
        ManagedValue::Boolean(state.maximized),
        ManagedValue::Boolean(state.fullscreen),
        ManagedValue::Boolean(state.occluded),
        ManagedValue::Boolean(state.resizable),
        ManagedValue::Boolean(state.cursor_visible),
        text(&state.cursor_grab),
    ]
}

fn text(value: &str) -> ManagedValue {
    ManagedValue::Bytes(value.as_bytes().to_vec())
}

fn optional_text_value(value: Option<&str>) -> ManagedValue {
    value.map_or(ManagedValue::Nil, text)
}

fn number(value: impl Into<f64>) -> ManagedValue {
    ManagedValue::Number(value.into())
}

fn unsigned(value: u64) -> ManagedValue {
    debug_assert!(value <= (1_u64 << 53));
    ManagedValue::Number(value as f64)
}

fn signed(value: i64) -> ManagedValue {
    debug_assert!(value.unsigned_abs() <= (1_u64 << 53));
    ManagedValue::Number(value as f64)
}

fn one_handle(values: &[ManagedValue], operation: &str) -> Result<ManagedHandle> {
    match values {
        [ManagedValue::Handle(value)] => Ok(*value),
        _ => bail!("{operation} returned an unexpected value shape"),
    }
}

fn one_boolean(values: &[ManagedValue], operation: &str) -> Result<bool> {
    match values {
        [ManagedValue::Boolean(value)] => Ok(*value),
        _ => bail!("{operation} returned an unexpected value shape"),
    }
}

fn one_text(values: &[ManagedValue], operation: &str) -> Result<String> {
    if values.len() != 1 {
        bail!(
            "{operation} returned {} values instead of one",
            values.len()
        );
    }
    match &values[0] {
        ManagedValue::Bytes(bytes) => String::from_utf8(bytes.clone())
            .with_context(|| format!("{operation} returned non-UTF-8 text")),
        other => bail!("{operation} returned {other:?} instead of text"),
    }
}

fn one_bytes(values: &[ManagedValue], operation: &str) -> Result<Vec<u8>> {
    match values {
        [ManagedValue::Bytes(bytes)] => Ok(bytes.clone()),
        _ => bail!("{operation} returned an unexpected value shape"),
    }
}

fn value<'a>(
    values: &'a [ManagedValue],
    index: usize,
    operation: &str,
) -> Result<&'a ManagedValue> {
    values
        .get(index)
        .ok_or_else(|| anyhow!("{operation} omitted result {}", index + 1))
}

fn optional_text(values: &[ManagedValue], index: usize, operation: &str) -> Result<Option<String>> {
    match value(values, index, operation)? {
        ManagedValue::Nil => Ok(None),
        ManagedValue::Bytes(bytes) => String::from_utf8(bytes.clone())
            .map(Some)
            .with_context(|| format!("{operation} returned non-UTF-8 text")),
        _ => bail!("{operation} returned non-text result {}", index + 1),
    }
}

fn required_number(values: &[ManagedValue], index: usize, operation: &str) -> Result<f64> {
    match value(values, index, operation)? {
        ManagedValue::Number(value) => Ok(*value),
        _ => bail!("{operation} returned non-number result {}", index + 1),
    }
}

fn optional_number(values: &[ManagedValue], index: usize, operation: &str) -> Result<Option<f64>> {
    match value(values, index, operation)? {
        ManagedValue::Nil => Ok(None),
        ManagedValue::Number(value) => Ok(Some(*value)),
        _ => bail!("{operation} returned non-number result {}", index + 1),
    }
}

fn optional_boolean(
    values: &[ManagedValue],
    index: usize,
    operation: &str,
) -> Result<Option<bool>> {
    match value(values, index, operation)? {
        ManagedValue::Nil => Ok(None),
        ManagedValue::Boolean(value) => Ok(Some(*value)),
        _ => bail!("{operation} returned non-boolean result {}", index + 1),
    }
}

fn optional_u32(values: &[ManagedValue], index: usize, operation: &str) -> Result<u32> {
    match optional_number(values, index, operation)? {
        None => Ok(0),
        Some(value) => exact_u32(value, operation),
    }
}

fn optional_bytes(values: &[ManagedValue], index: usize, operation: &str) -> Result<Vec<u8>> {
    match value(values, index, operation)? {
        ManagedValue::Nil => Ok(Vec::new()),
        ManagedValue::Bytes(bytes) => Ok(bytes.clone()),
        _ => bail!("{operation} returned a non-byte result {}", index + 1),
    }
}

fn exact_u32(value: f64, field: &str) -> Result<u32> {
    if value < 0.0 || value > f64::from(u32::MAX) || value.fract() != 0.0 {
        bail!("{field} is not a 32-bit unsigned integer: {value}");
    }
    Ok(value as u32)
}

fn exact_u64(value: f64, field: &str) -> Result<u64> {
    if value < 0.0 || value > u64::MAX as f64 || value.fract() != 0.0 {
        bail!("{field} is not a non-negative exact integer: {value}");
    }
    Ok(value as u64)
}
