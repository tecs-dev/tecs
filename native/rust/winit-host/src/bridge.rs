use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::ffi::CStr;
use std::path::Path;
use std::rc::Rc;
use std::time::Instant;

use crate::sdk::{HostHandler, HostRuntime, HostValue, ManagedHandle, ManagedValue};
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
    "tecs.host.nextWindowCommand",
    "tecs.host.windowCommandFailed",
    "tecs.host.renderPacket",
    "tecs.host.nextCapture",
    "tecs.host.captureResult",
    "tecs.host.nextModelUpload",
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

/// One image residency request a frame asked the host to apply.
#[derive(Clone, Debug, PartialEq)]
pub enum ImageCommand {
    /// Makes `pixels`, eight-bit RGBA rows top to bottom, resident under `image`.
    Upload {
        image: u32,
        width: u32,
        height: u32,
        sampler: u32,
        format: String,
        pixels: Vec<u8>,
    },
    /// Drops `image` and everything bound to it.
    Release { image: u32 },
    /// Associates normal, emission and ORM images with `image`; zero is none.
    MaterialMaps { image: u32, maps: [u32; 3] },
}

/// An image command waiting for the host loop, and the request its frame is
/// parked on until the host answers it.
#[derive(Clone, Debug, PartialEq)]
pub struct PendingImage {
    pub request: u64,
    pub command: ImageCommand,
}

/// A queued image request, or why its arguments did not describe a command.
type ImageRequest = (u64, Result<ImageCommand, String>);

/// The kinds a frame calls to apply image residency, which are a
/// compatibility surface with `tecs.host`.
const IMAGE_KINDS: [&CStr; 3] = [
    c"tecs.image.upload",
    c"tecs.image.release",
    c"tecs.image.material-maps",
];

/// Queues each image call for the host loop, which answers it after applying
/// it to the GPU. The handler runs inside the frame that made the call, where
/// the renderer is out of reach.
struct ImageRequests {
    queue: Rc<RefCell<VecDeque<ImageRequest>>>,
}

impl HostHandler for ImageRequests {
    fn request(&mut self, request: u64, kind: &str, arguments: &[HostValue<'_>]) {
        let command = image_command(kind, arguments).map_err(|error| format!("{error:#}"));
        self.queue.borrow_mut().push_back((request, command));
    }

    fn cancel(&mut self, request: u64) {
        self.queue
            .borrow_mut()
            .retain(|(queued, _)| *queued != request);
    }
}

fn image_command(kind: &str, arguments: &[HostValue<'_>]) -> Result<ImageCommand> {
    let integer = |index: usize| match arguments.get(index) {
        Some(HostValue::Number(value)) => exact_u32(*value, kind),
        _ => bail!("{kind} argument {} is not a number", index + 1),
    };
    let bytes = |index: usize| match arguments.get(index) {
        Some(HostValue::Bytes(value)) => Ok(*value),
        _ => bail!("{kind} argument {} is not bytes", index + 1),
    };
    Ok(match kind {
        "tecs.image.upload" => ImageCommand::Upload {
            image: integer(0)?,
            width: integer(1)?,
            height: integer(2)?,
            sampler: integer(3)?,
            format: String::from_utf8_lossy(bytes(4)?).into_owned(),
            pixels: bytes(5)?.to_vec(),
        },
        "tecs.image.release" => ImageCommand::Release { image: integer(0)? },
        "tecs.image.material-maps" => ImageCommand::MaterialMaps {
            image: integer(0)?,
            maps: [integer(1)?, integer(2)?, integer(3)?],
        },
        _ => bail!("no image command is called {kind}"),
    })
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
    next_window_command: ManagedHandle,
    window_command_failed: ManagedHandle,
    render_packet: ManagedHandle,
    next_capture: ManagedHandle,
    capture_result: ManagedHandle,
    next_model_upload: ManagedHandle,
}

pub struct Bridge {
    runtime: HostRuntime,
    session: ManagedHandle,
    exports: Exports,
    images: Rc<RefCell<VecDeque<ImageRequest>>>,
    stats: Option<BridgeStats>,
}

#[derive(Default)]
struct ExportStats {
    calls: u64,
    bytes_in: u64,
    bytes_out: u64,
    nanos: u128,
}

/// Every crossing of the managed boundary, recorded when `TECS_BRIDGE_STATS`
/// names a file to write them to: per export, per frame, and the sizes of the
/// render packets and model uploads that cross.
struct BridgeStats {
    output: std::path::PathBuf,
    names: HashMap<usize, &'static str>,
    exports: HashMap<&'static str, ExportStats>,
    frame_calls: Vec<u32>,
    frame_nanos: Vec<u128>,
    frame_wall: Vec<u128>,
    last_frame: Option<Instant>,
    current_calls: u32,
    current_nanos: u128,
    packets: Vec<usize>,
    uploads: Vec<usize>,
}

fn value_bytes(values: &[ManagedValue]) -> u64 {
    values
        .iter()
        .map(|value| match value {
            ManagedValue::Bytes(bytes) => bytes.len() as u64,
            _ => 0,
        })
        .sum()
}

impl BridgeStats {
    fn record(
        &mut self,
        export: ManagedHandle,
        arguments: &[ManagedValue],
        results: &[ManagedValue],
        nanos: u128,
    ) {
        let name = self
            .names
            .get(&export.address())
            .copied()
            .unwrap_or("entry");
        let entry = self.exports.entry(name).or_default();
        entry.calls += 1;
        entry.bytes_in += value_bytes(arguments);
        let out = value_bytes(results);
        entry.bytes_out += out;
        entry.nanos += nanos;
        self.current_calls += 1;
        self.current_nanos += nanos;
        match name {
            "tecs.host.renderPacket" => self.packets.push(out as usize),
            "tecs.host.nextModelUpload" if out > 0 => self.uploads.push(out as usize),
            "tecs.host.iterate" => {
                let now = Instant::now();
                if let Some(last) = self.last_frame.replace(now) {
                    self.frame_wall.push(now.duration_since(last).as_nanos());
                }
                self.frame_calls.push(self.current_calls);
                self.frame_nanos.push(self.current_nanos);
                self.current_calls = 0;
                self.current_nanos = 0;
            }
            _ => {}
        }
    }

    fn record_crossing(&mut self, name: &'static str, nanos: u128) {
        let entry = self.exports.entry(name).or_default();
        entry.calls += 1;
        entry.nanos += nanos;
        self.current_calls += 1;
        self.current_nanos += nanos;
    }

    fn write(&self) {
        let exports: serde_json::Map<String, serde_json::Value> = self
            .exports
            .iter()
            .map(|(name, stats)| {
                (
                    (*name).to_owned(),
                    serde_json::json!({
                        "calls": stats.calls,
                        "bytesIn": stats.bytes_in,
                        "bytesOut": stats.bytes_out,
                        "ms": stats.nanos as f64 / 1e6,
                    }),
                )
            })
            .collect();
        let report = serde_json::json!({
            "frames": self.frame_calls.len(),
            "exports": exports,
            "callsPerFrame": self.frame_calls,
            "boundaryMsPerFrame": self.frame_nanos.iter().map(|nanos| *nanos as f64 / 1e6).collect::<Vec<_>>(),
            "frameMs": self.frame_wall.iter().map(|nanos| *nanos as f64 / 1e6).collect::<Vec<_>>(),
            "packetBytes": self.packets,
            "uploadBytes": self.uploads,
        });
        let _ = std::fs::write(
            &self.output,
            serde_json::to_vec_pretty(&report).unwrap_or_default(),
        );
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        if let Some(stats) = &self.stats {
            stats.write();
        }
    }
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
        let images = Rc::new(RefCell::new(VecDeque::new()));
        runtime
            .register_host(
                &IMAGE_KINDS,
                Box::new(ImageRequests {
                    queue: Rc::clone(&images),
                }),
            )
            .context("register the image residency handler")?;
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
        let stats = std::env::var_os("TECS_BRIDGE_STATS").map(|output| BridgeStats {
            output: output.into(),
            names: EXPORT_NAMES
                .iter()
                .zip(&handles)
                .map(|(name, handle)| (handle.address(), *name))
                .collect(),
            exports: HashMap::new(),
            frame_calls: Vec::new(),
            frame_nanos: Vec::new(),
            frame_wall: Vec::new(),
            last_frame: None,
            current_calls: 0,
            current_nanos: 0,
            packets: Vec::new(),
            uploads: Vec::new(),
        });

        Ok(Self {
            runtime,
            session,
            exports,
            images,
            stats,
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

    pub fn render_packet(&mut self, resident_revision: u32) -> Result<Vec<u8>> {
        let values = self.call(
            self.exports.render_packet,
            &[ManagedValue::Number(f64::from(resident_revision))],
        )?;
        one_bytes(values, "tecs.host.renderPacket")
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
        self.push(
            c"tecs.input.close",
            &[ManagedValue::Number(timestamp), unsigned(sequence)],
        )
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
        self.push(
            c"tecs.input.resize",
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
        )
    }

    pub fn push_focus(&mut self, focused: bool, timestamp: f64, sequence: u64) -> Result<()> {
        self.push(
            c"tecs.input.focus",
            &[
                ManagedValue::Boolean(focused),
                ManagedValue::Number(timestamp),
                unsigned(sequence),
            ],
        )
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
        self.push(
            c"tecs.input.key",
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
        )
    }

    pub fn push_pointer_move(
        &mut self,
        x: f64,
        y: f64,
        dx: f64,
        dy: f64,
        timestamp: f64,
        sequence: u64,
    ) -> Result<()> {
        self.push(
            c"tecs.input.pointer-move",
            &[
                ManagedValue::Number(x),
                ManagedValue::Number(y),
                ManagedValue::Number(dx),
                ManagedValue::Number(dy),
                ManagedValue::Number(timestamp),
                unsigned(sequence),
            ],
        )
    }

    pub fn push_pointer_button(
        &mut self,
        down: bool,
        button: u16,
        x: f64,
        y: f64,
        timestamp: f64,
        sequence: u64,
    ) -> Result<()> {
        self.push(
            c"tecs.input.pointer-button",
            &[
                ManagedValue::Boolean(down),
                number(button),
                ManagedValue::Number(x),
                ManagedValue::Number(y),
                ManagedValue::Number(timestamp),
                unsigned(sequence),
            ],
        )
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
        self.push(
            c"tecs.input.wheel",
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
        )
    }

    pub fn push_text(&mut self, value: &str, timestamp: f64, sequence: u64) -> Result<()> {
        self.push(
            c"tecs.input.text",
            &[
                text(value),
                ManagedValue::Number(timestamp),
                unsigned(sequence),
            ],
        )
    }

    /// Queues one finger's transition or movement on a touch surface.
    ///
    /// The device and finger identities cross as text because both are 64-bit
    /// platform values, and a Lua number would round two fingers into one.
    pub fn push_touch(&mut self, touch: &TouchEvent<'_>) -> Result<()> {
        self.push(
            c"tecs.input.touch",
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
        )
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

    pub fn next_model_upload(&mut self) -> Result<Option<(u32, Vec<u8>)>> {
        let values = self.call(self.exports.next_model_upload, &[])?;
        let id = required_number(&values, 0, "model id")? as u32;
        if id == 0 {
            return Ok(None);
        }
        let data = match values.get(1) {
            Some(ManagedValue::Bytes(bytes)) => bytes.clone(),
            _ => bail!("model upload has no geometry bytes"),
        };
        Ok(Some((id, data)))
    }

    pub fn next_capture(&mut self) -> Result<Option<u64>> {
        let values = self.call(self.exports.next_capture, &[])?;
        let id = exact_u64(
            required_number(&values, 0, "capture request")?,
            "capture id",
        )?;
        Ok((id != 0).then_some(id))
    }

    pub fn capture_result(
        &mut self,
        id: u64,
        capture: &Result<crate::graphics::Capture>,
    ) -> Result<()> {
        let (width, height, rgba, png, reason) = match capture {
            Ok(frame) => (
                frame.width,
                frame.height,
                frame.rgba.clone(),
                frame.png.clone(),
                None,
            ),
            Err(error) => (0, 0, Vec::new(), Vec::new(), Some(format!("{error:#}"))),
        };
        self.call(
            self.exports.capture_result,
            &[
                unsigned(id),
                number(width),
                number(height),
                ManagedValue::Bytes(rgba),
                ManagedValue::Bytes(png),
                optional_text_value(reason.as_deref()),
            ],
        )?;
        Ok(())
    }

    /// Takes the next image command a parked frame is waiting on.
    ///
    /// A request whose arguments describe no command is failed here, which
    /// raises in the frame that made it.
    pub fn next_image_command(&mut self) -> Result<Option<PendingImage>> {
        loop {
            let Some((request, command)) = self.images.borrow_mut().pop_front() else {
                return Ok(None);
            };
            match command {
                Ok(command) => return Ok(Some(PendingImage { request, command })),
                Err(reason) => self
                    .runtime
                    .fail(request, &reason)
                    .context("fail a malformed image command")?,
            }
        }
    }

    /// Answers an image command with the backend's outcome; the parked frame
    /// completes it in `tecs.gfx.images` when it next polls.
    ///
    /// A rejected image is answered rather than failing the frame, so a game
    /// observes a failed asset and the window keeps drawing.
    pub fn report_image_result(&mut self, request: u64, reason: Option<&str>) -> Result<()> {
        let started = Instant::now();
        self.runtime
            .answer(
                request,
                &[
                    ManagedValue::Boolean(reason.is_none()),
                    optional_text_value(reason),
                ],
            )
            .context("answer an image command")?;
        if let Some(stats) = &mut self.stats {
            stats.record_crossing("tecs.image.answer", started.elapsed().as_nanos());
        }
        Ok(())
    }

    /// Answers an image command without applying it, which leaves the image
    /// pending, for a host with no renderer.
    pub fn skip_image_command(&mut self, request: u64) -> Result<()> {
        self.runtime
            .answer(request, &[])
            .context("answer an image command")
    }

    pub fn report_window_failure(&mut self, serial: u64, reason: &str) -> Result<()> {
        let export = self.exports.window_command_failed;
        self.call(export, &[unsigned(serial), text(reason)])?;
        Ok(())
    }

    /// Queues one input observation on the host channel. The session routes
    /// each `tecs.input.*` kind to the platform event the application reads,
    /// delivered at the start of the next frame.
    fn push(&mut self, kind: &'static CStr, values: &[ManagedValue]) -> Result<()> {
        let started = Instant::now();
        self.runtime
            .push(kind, values)
            .with_context(|| format!("push {}", kind.to_string_lossy()))?;
        if let Some(stats) = &mut self.stats {
            stats.record_crossing(
                kind.to_str().unwrap_or("push"),
                started.elapsed().as_nanos(),
            );
        }
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
        let started = Instant::now();
        let results = self.runtime.call(export, &passed)?;
        if let Some(stats) = &mut self.stats {
            stats.record(export, arguments, &results, started.elapsed().as_nanos());
        }
        Ok(results)
    }
}

impl Exports {
    fn from_handles(handles: &[ManagedHandle]) -> Result<Self> {
        let [_create, init, iterate, shutdown, crashed, set_suspended, attach_window, apply_window_state, detach_window, next_window_command, window_command_failed, render_packet, next_capture, capture_result, next_model_upload] =
            handles
        else {
            bail!("internal export table length mismatch");
        };
        Ok(Self {
            init: *init,
            iterate: *iterate,
            shutdown: *shutdown,
            crashed: *crashed,
            set_suspended: *set_suspended,
            attach_window: *attach_window,
            apply_window_state: *apply_window_state,
            detach_window: *detach_window,
            next_window_command: *next_window_command,
            window_command_failed: *window_command_failed,
            render_packet: *render_packet,
            next_capture: *next_capture,
            capture_result: *capture_result,
            next_model_upload: *next_model_upload,
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

fn one_bytes(mut values: Vec<ManagedValue>, operation: &str) -> Result<Vec<u8>> {
    if values.len() != 1 {
        bail!("{operation} returned an unexpected value shape");
    }
    match values.pop() {
        Some(ManagedValue::Bytes(bytes)) => Ok(bytes),
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
