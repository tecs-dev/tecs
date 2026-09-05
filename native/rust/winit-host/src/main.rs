mod bridge;
#[cfg(test)]
mod culltests;
#[cfg(test)]
mod drawtests;
mod graph;
mod graphics;
mod packet;
#[cfg(test)]
mod pipelinetests;
mod sdk;
mod shaderpack;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use anyhow::{anyhow, Context, Result};
use bridge::{Bridge, FrameState, ImageCommand, SessionOptions, WindowCommand, WindowState};
use graphics::Graphics;
use winit::application::ApplicationHandler;
use winit::dpi::{LogicalPosition, LogicalSize, PhysicalPosition, PhysicalSize};
use winit::event::{ElementState, Ime, MouseButton, MouseScrollDelta, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop};
use winit::keyboard::{Key, ModifiersState, PhysicalKey};
use winit::window::{CursorGrabMode, Fullscreen, Window, WindowAttributes, WindowId};

const SHIFT_MODIFIER: u8 = 1;
const CONTROL_MODIFIER: u8 = 2;
const ALT_MODIFIER: u8 = 4;
const SUPER_MODIFIER: u8 = 8;

struct Config {
    component: PathBuf,
    entry: String,
    title: String,
    width: u32,
    height: u32,
    debug: bool,
    headless: bool,
    max_frames: Option<u32>,
}

struct App {
    bridge: Bridge,
    config: Config,
    window: Option<Arc<Window>>,
    graphics: Option<Graphics>,
    window_id: Option<WindowId>,
    state: Option<WindowState>,
    start: Instant,
    last_frame: Instant,
    cursor: (f64, f64),
    modifiers: ModifiersState,
    sequence: u64,
    shutdown: bool,
    frame_parked: bool,
}

impl App {
    fn new(config: Config) -> Result<Self> {
        let executable = std::env::current_exe().context("find the Tecs host executable")?;
        let mut bridge = Bridge::load(&SessionOptions {
            executable: &executable,
            component: &config.component,
            entry: &config.entry,
            title: &config.title,
            width: config.width,
            height: config.height,
            debug: config.debug,
            max_frames: config.max_frames,
        })?;
        bridge.init().context("initialize the Tecs application")?;
        let now = Instant::now();
        Ok(Self {
            bridge,
            config,
            window: None,
            graphics: None,
            window_id: None,
            state: None,
            start: now,
            last_frame: now,
            cursor: (0.0, 0.0),
            modifiers: ModifiersState::empty(),
            sequence: 0,
            shutdown: false,
            frame_parked: false,
        })
    }

    fn timestamp(&self) -> f64 {
        self.start.elapsed().as_secs_f64()
    }

    fn next_sequence(&mut self) -> u64 {
        self.sequence += 1;
        self.sequence
    }

    fn create_window(&mut self, event_loop: &ActiveEventLoop) -> Result<()> {
        if self.window.is_some() {
            self.bridge.set_suspended(false)?;
            return Ok(());
        }
        let attributes = WindowAttributes::default()
            .with_title(self.config.title.clone())
            .with_inner_size(LogicalSize::new(self.config.width, self.config.height))
            .with_resizable(true);
        let window = Arc::new(
            event_loop
                .create_window(attributes)
                .context("create the winit window")?,
        );
        let physical = window.inner_size();
        let scale = window.scale_factor();
        let logical = physical.to_logical::<u32>(scale);
        let position = window
            .outer_position()
            .unwrap_or(PhysicalPosition::new(0, 0));
        let logical_position = position.to_logical::<i32>(scale);
        let state = WindowState {
            id: 1,
            title: self.config.title.clone(),
            width: logical.width,
            height: logical.height,
            pixel_width: physical.width,
            pixel_height: physical.height,
            scale_factor: scale,
            x: logical_position.x,
            y: logical_position.y,
            focused: window.has_focus(),
            visible: true,
            minimized: window.is_minimized().unwrap_or(false),
            maximized: window.is_maximized(),
            fullscreen: window.fullscreen().is_some(),
            occluded: false,
            resizable: window.is_resizable(),
            cursor_visible: true,
            cursor_grab: "none".to_owned(),
        };
        let graphics = Graphics::new(Arc::clone(&window), event_loop.owned_display_handle())?;
        self.bridge.attach_window(&state)?;
        self.window_id = Some(window.id());
        self.window = Some(window);
        self.graphics = Some(graphics);
        self.state = Some(state);
        Ok(())
    }

    fn push_resize(&mut self, scale_changed: bool, physical: PhysicalSize<u32>) -> Result<()> {
        let scale = self
            .window
            .as_ref()
            .map(|window| window.scale_factor())
            .unwrap_or(1.0);
        let logical = physical.to_logical::<u32>(scale);
        if let Some(state) = self.state.as_mut() {
            state.width = logical.width;
            state.height = logical.height;
            state.pixel_width = physical.width;
            state.pixel_height = physical.height;
            state.scale_factor = scale;
        }
        if let Some(graphics) = self.graphics.as_mut() {
            graphics.resize(physical.width, physical.height);
        }
        let timestamp = self.timestamp();
        let sequence = self.next_sequence();
        self.bridge.push_resize(
            scale_changed,
            logical.width,
            logical.height,
            physical.width,
            physical.height,
            scale,
            timestamp,
            sequence,
        )
    }

    fn apply_commands(&mut self) -> Result<()> {
        while let Some(command) = self.bridge.next_window_command()? {
            if let Err(error) = self.apply_command(&command) {
                self.bridge
                    .report_window_failure(command.serial, &error.to_string())?;
            }
        }
        if let Some(state) = self.state.as_ref() {
            self.bridge.apply_window_state(state)?;
        }
        Ok(())
    }

    /// Drains every queued residency request and reports each outcome.
    ///
    /// A rejected image is reported back rather than failing the frame, so a
    /// game observes a failed asset and the window keeps drawing.
    fn apply_image_commands(&mut self) -> Result<()> {
        while let Some(command) = self.bridge.next_image_command()? {
            let outcome = match self.graphics.as_mut() {
                None => Err(anyhow!("the renderer is not attached")),
                Some(graphics) => apply_image_command(graphics, &command),
            };
            let reason = outcome.err().map(|error| format!("{error:#}"));
            self.bridge
                .report_image_result(command.image, command.serial, reason.as_deref())?;
        }
        Ok(())
    }

    fn apply_command(&mut self, command: &WindowCommand) -> Result<()> {
        let window = self
            .window
            .as_ref()
            .ok_or_else(|| anyhow!("the OS window is not attached"))?;
        let state = self
            .state
            .as_mut()
            .ok_or_else(|| anyhow!("the observed window state is missing"))?;
        match command.kind.as_str() {
            "setTitle" => {
                let title = command
                    .text
                    .as_deref()
                    .context("setTitle omitted its title")?;
                window.set_title(title);
                state.title = title.to_owned();
            }
            "setSize" => {
                let width = command.x.context("setSize omitted its width")?;
                let height = command.y.context("setSize omitted its height")?;
                let _ = window.request_inner_size(LogicalSize::new(width, height));
            }
            "setPosition" => {
                let x = command.x.context("setPosition omitted x")?;
                let y = command.y.context("setPosition omitted y")?;
                window.set_outer_position(LogicalPosition::new(x, y));
                state.x = x as i32;
                state.y = y as i32;
            }
            "setVisible" => {
                let visible = command.flag.context("setVisible omitted its flag")?;
                window.set_visible(visible);
                state.visible = visible;
            }
            "setResizable" => {
                let resizable = command.flag.context("setResizable omitted its flag")?;
                window.set_resizable(resizable);
                state.resizable = resizable;
            }
            "setFullscreen" => {
                let fullscreen = command.flag.context("setFullscreen omitted its flag")?;
                window.set_fullscreen(fullscreen.then_some(Fullscreen::Borderless(None)));
                state.fullscreen = fullscreen;
            }
            "setCursorVisible" => {
                let visible = command.flag.context("setCursorVisible omitted its flag")?;
                window.set_cursor_visible(visible);
                state.cursor_visible = visible;
            }
            "setCursorGrab" => {
                let mode = command
                    .text
                    .as_deref()
                    .context("setCursorGrab omitted its mode")?;
                let winit_mode = match mode {
                    "none" => CursorGrabMode::None,
                    "confined" => CursorGrabMode::Confined,
                    "locked" => CursorGrabMode::Locked,
                    _ => return Err(anyhow!("unknown cursor grab mode {mode}")),
                };
                window.set_cursor_grab(winit_mode)?;
                state.cursor_grab = mode.to_owned();
            }
            "requestRedraw" => window.request_redraw(),
            kind => return Err(anyhow!("unknown window command {kind}")),
        }
        Ok(())
    }

    fn tick(&mut self, event_loop: &ActiveEventLoop) -> Result<()> {
        let now = Instant::now();
        let dt = if self.frame_parked {
            0.0
        } else {
            let elapsed = now.duration_since(self.last_frame).as_secs_f64();
            self.last_frame = now;
            elapsed
        };
        match self.bridge.iterate(dt)? {
            FrameState::Parked => {
                self.frame_parked = true;
                return Ok(());
            }
            FrameState::Continue => self.frame_parked = false,
            FrameState::Stopped => {
                self.frame_parked = false;
                event_loop.exit();
                return Ok(());
            }
        }
        self.apply_commands()?;
        self.apply_image_commands()?;
        if let Some(graphics) = self.graphics.as_mut() {
            let packet = self.bridge.render_packet()?;
            graphics.render(&packet)?;
        }
        if let Some(failure) = self.bridge.crashed()? {
            return Err(anyhow!("Nupp application crashed: {failure}"));
        }
        Ok(())
    }

    fn fail(&mut self, event_loop: &ActiveEventLoop, error: anyhow::Error) {
        eprintln!("tecs-winit-host: {error:#}");
        event_loop.exit();
    }

    fn shutdown(&mut self) {
        if self.shutdown {
            return;
        }
        self.shutdown = true;
        self.graphics = None;
        if self.window.take().is_some() {
            if let Err(error) = self.bridge.detach_window() {
                eprintln!("tecs-winit-host: detach window: {error:#}");
            }
        }
        if let Err(error) = self.bridge.shutdown() {
            eprintln!("tecs-winit-host: shutdown: {error:#}");
        }
    }
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if let Err(error) = self.create_window(event_loop) {
            self.fail(event_loop, error);
        }
    }

    fn suspended(&mut self, event_loop: &ActiveEventLoop) {
        if let Err(error) = self.bridge.set_suspended(true) {
            self.fail(event_loop, error);
        }
    }

    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        window_id: WindowId,
        event: WindowEvent,
    ) {
        if Some(window_id) != self.window_id {
            return;
        }
        let result = match event {
            WindowEvent::CloseRequested => {
                let timestamp = self.timestamp();
                let sequence = self.next_sequence();
                self.bridge.push_close(timestamp, sequence)
            }
            WindowEvent::Destroyed => self.bridge.detach_window(),
            WindowEvent::Resized(size) => self.push_resize(false, size),
            WindowEvent::ScaleFactorChanged { scale_factor, .. } => {
                if let Some(state) = self.state.as_mut() {
                    state.scale_factor = scale_factor;
                }
                let size = self
                    .window
                    .as_ref()
                    .map(|window| window.inner_size())
                    .unwrap_or_default();
                self.push_resize(true, size)
            }
            WindowEvent::Focused(focused) => {
                if let Some(state) = self.state.as_mut() {
                    state.focused = focused;
                }
                let timestamp = self.timestamp();
                let sequence = self.next_sequence();
                self.bridge.push_focus(focused, timestamp, sequence)
            }
            WindowEvent::ModifiersChanged(modifiers) => {
                self.modifiers = modifiers.state();
                Ok(())
            }
            WindowEvent::KeyboardInput { event, .. } => {
                let down = event.state == ElementState::Pressed;
                let physical = physical_key_name(event.physical_key);
                let logical = logical_key_name(&event.logical_key);
                let key_text = event.text.as_ref().map(ToString::to_string);
                let modifiers = modifier_mask(self.modifiers);
                let timestamp = self.timestamp();
                let sequence = self.next_sequence();
                self.bridge.push_key(
                    down,
                    &physical,
                    logical.as_deref(),
                    key_text.as_deref(),
                    modifiers,
                    event.repeat,
                    timestamp,
                    sequence,
                )
            }
            WindowEvent::CursorMoved { position, .. } => {
                let scale = self.state.as_ref().map_or(1.0, |state| state.scale_factor);
                let logical = position.to_logical::<f64>(scale);
                let delta = (logical.x - self.cursor.0, logical.y - self.cursor.1);
                self.cursor = (logical.x, logical.y);
                let timestamp = self.timestamp();
                let sequence = self.next_sequence();
                self.bridge
                    .push_pointer_move(logical.x, logical.y, delta.0, delta.1, timestamp, sequence)
            }
            WindowEvent::MouseInput { state, button, .. } => {
                let down = state == ElementState::Pressed;
                let timestamp = self.timestamp();
                let sequence = self.next_sequence();
                self.bridge.push_pointer_button(
                    down,
                    mouse_button(button),
                    self.cursor.0,
                    self.cursor.1,
                    timestamp,
                    sequence,
                )
            }
            WindowEvent::MouseWheel { delta, .. } => {
                let scale = self.state.as_ref().map_or(1.0, |state| state.scale_factor);
                let (wheel_x, wheel_y, ticks_x, ticks_y) = match delta {
                    MouseScrollDelta::LineDelta(x, y) => (
                        f64::from(x),
                        f64::from(y),
                        x.round() as i64,
                        y.round() as i64,
                    ),
                    MouseScrollDelta::PixelDelta(position) => {
                        let logical = position.to_logical::<f64>(scale);
                        (logical.x, logical.y, 0, 0)
                    }
                };
                let timestamp = self.timestamp();
                let sequence = self.next_sequence();
                self.bridge.push_wheel(
                    wheel_x,
                    wheel_y,
                    ticks_x,
                    ticks_y,
                    self.cursor.0,
                    self.cursor.1,
                    timestamp,
                    sequence,
                )
            }
            WindowEvent::Ime(Ime::Commit(text)) => {
                let timestamp = self.timestamp();
                let sequence = self.next_sequence();
                self.bridge.push_text(&text, timestamp, sequence)
            }
            WindowEvent::Moved(position) => {
                if let Some(state) = self.state.as_mut() {
                    let logical = position.to_logical::<i32>(state.scale_factor);
                    state.x = logical.x;
                    state.y = logical.y;
                }
                Ok(())
            }
            WindowEvent::Occluded(occluded) => {
                if let Some(state) = self.state.as_mut() {
                    state.occluded = occluded;
                }
                Ok(())
            }
            _ => Ok(()),
        };
        if let Err(error) = result {
            self.fail(event_loop, error);
        }
    }

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        if let Err(error) = self.tick(event_loop) {
            self.fail(event_loop, error);
        }
    }

    fn exiting(&mut self, _event_loop: &ActiveEventLoop) {
        self.shutdown();
    }
}

impl Drop for App {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn apply_image_command(graphics: &mut Graphics, command: &ImageCommand) -> Result<()> {
    match command.kind.as_str() {
        "uploadImage" => {
            if command.format != "rgba8" {
                return Err(anyhow!("unknown image format {}", command.format));
            }
            graphics.upload_image(
                command.image,
                command.width,
                command.height,
                &command.pixels,
            )
        }
        "releaseImage" => graphics.release_image(command.image),
        kind => Err(anyhow!("unknown image command {kind}")),
    }
}

fn physical_key_name(key: PhysicalKey) -> String {
    match key {
        PhysicalKey::Code(code) => format!("{code:?}"),
        PhysicalKey::Unidentified(value) => format!("Unidentified({value:?})"),
    }
}

fn logical_key_name(key: &Key) -> Option<String> {
    match key {
        Key::Character(value) => Some(value.to_string()),
        Key::Named(value) => Some(format!("{value:?}")),
        Key::Dead(value) => value.map(|character| character.to_string()),
        Key::Unidentified(_) => None,
    }
}

fn modifier_mask(state: ModifiersState) -> u8 {
    let mut mask = 0;
    if state.shift_key() {
        mask |= SHIFT_MODIFIER;
    }
    if state.control_key() {
        mask |= CONTROL_MODIFIER;
    }
    if state.alt_key() {
        mask |= ALT_MODIFIER;
    }
    if state.super_key() {
        mask |= SUPER_MODIFIER;
    }
    mask
}

fn mouse_button(button: MouseButton) -> u16 {
    match button {
        MouseButton::Left => 1,
        MouseButton::Middle => 2,
        MouseButton::Right => 3,
        MouseButton::Back => 4,
        MouseButton::Forward => 5,
        MouseButton::Other(value) => value.saturating_add(6),
    }
}

fn parse_config() -> Result<Config> {
    let mut component = PathBuf::from("out/nupp/host.nuppc");
    let mut entry = "tecs.host.create".to_owned();
    let mut title = "tecs".to_owned();
    let mut width = 1280;
    let mut height = 720;
    let mut debug = false;
    let mut headless = false;
    let mut max_frames = None;
    let mut arguments = std::env::args_os().skip(1);
    while let Some(argument) = arguments.next() {
        match argument.to_string_lossy().as_ref() {
            "--component" => {
                component = arguments
                    .next()
                    .context("--component requires a path")?
                    .into();
            }
            "--entry" => {
                entry = arguments
                    .next()
                    .context("--entry requires an exported function name")?
                    .to_string_lossy()
                    .into_owned();
                if entry.is_empty() {
                    return Err(anyhow!("--entry must not be empty"));
                }
            }
            "--title" => {
                title = arguments
                    .next()
                    .context("--title requires text")?
                    .to_string_lossy()
                    .into_owned();
            }
            "--width" => {
                width = arguments
                    .next()
                    .context("--width requires a number")?
                    .to_string_lossy()
                    .parse()
                    .context("--width must be a positive integer")?;
            }
            "--height" => {
                height = arguments
                    .next()
                    .context("--height requires a number")?
                    .to_string_lossy()
                    .parse()
                    .context("--height must be a positive integer")?;
            }
            "--debug" => debug = true,
            "--headless" => headless = true,
            "--frames" => {
                let frames = arguments
                    .next()
                    .context("--frames requires a number")?
                    .to_string_lossy()
                    .parse::<u32>()
                    .context("--frames must be a positive integer")?;
                if frames == 0 {
                    return Err(anyhow!("--frames must be a positive integer"));
                }
                max_frames = Some(frames);
            }
            unknown => return Err(anyhow!("unknown argument {unknown}")),
        }
    }
    if width == 0 || height == 0 {
        return Err(anyhow!("window dimensions must be positive"));
    }
    Ok(Config {
        component,
        entry,
        title,
        width,
        height,
        debug,
        headless,
        max_frames,
    })
}

fn run() -> Result<()> {
    // The shader pack is built rather than run, so it is answered before the
    // window configuration is even parsed. A release consumes the file this
    // writes and never reads a material directory of its own.
    let mut arguments = std::env::args_os().skip(1);
    if arguments
        .next()
        .is_some_and(|value| value == *"--pack-shaders")
    {
        return pack_shaders(arguments.collect());
    }
    let config = parse_config()?;
    if config.headless {
        return run_headless(config);
    }
    let event_loop = EventLoop::new().context("create the winit event loop")?;
    event_loop.set_control_flow(ControlFlow::Poll);
    let mut app = App::new(config)?;
    event_loop
        .run_app(&mut app)
        .context("run the winit event loop")
}

/// Assembles the material dispatch into a shader pack a release loads.
///
/// `--pack-shaders <materials directory> <output file>`. This is the packaging
/// step, and it is the only path in this binary that reads a material file.
fn pack_shaders(arguments: Vec<std::ffi::OsString>) -> Result<()> {
    let [materials, output] = arguments.as_slice() else {
        return Err(anyhow!(
            "--pack-shaders takes a material directory and an output file"
        ));
    };
    let pack = shaderpack::ShaderPack::assemble(std::path::Path::new(materials))?;
    pack.write(std::path::Path::new(output))?;
    println!(
        "{} materials: {}",
        pack.materials().len(),
        pack.materials().join(", ")
    );
    Ok(())
}

fn run_headless(config: Config) -> Result<()> {
    let executable = std::env::current_exe().context("find the Tecs host executable")?;
    let mut bridge = Bridge::load(&SessionOptions {
        executable: &executable,
        component: &config.component,
        entry: &config.entry,
        title: &config.title,
        width: config.width,
        height: config.height,
        debug: config.debug,
        max_frames: Some(config.max_frames.unwrap_or(1)),
    })?;
    bridge.init().context("initialize the Tecs application")?;
    while !matches!(bridge.iterate(0.0)?, FrameState::Stopped) {}
    bridge.shutdown()
}

fn main() {
    if let Err(error) = run() {
        eprintln!("tecs-winit-host: {error:#}");
        std::process::exit(1);
    }
}
