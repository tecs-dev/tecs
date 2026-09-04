//! The `cpal` output stream.
//!
//! The data callback runs on a thread this process never created: CoreAudio
//! calls it on its own realtime thread, and ALSA and WASAPI call it on a thread
//! `cpal` spawned. Nothing reachable from inside it may enter the Lua virtual
//! machine, allocate, or open a file, which is why the callback does one thing:
//! lock the mixer and ask it to fill the buffer it was handed.

use std::sync::{Arc, Mutex};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SizedSample};

use crate::mixer::Mixer;

/// An open output and the layout it runs at.
pub struct Output {
    /// Kept because dropping it closes the stream.
    _stream: cpal::Stream,
    /// The frames per second the device actually opened at, which is not
    /// always the rate that was asked for.
    pub sample_rate: u32,
    /// The channels the device actually opened with.
    pub channels: u16,
}

/// Opens the default output and starts it.
///
/// The requested layout is a preference. A device that will not take it opens
/// at its own default instead, and the caller reads back what it got rather
/// than being told the request failed.
///
/// @return the open output, or the reason no output opened
pub fn open(
    sample_rate: u32,
    channels: u16,
    max_voices: usize,
) -> Result<(Output, Arc<Mutex<Mixer>>), String> {
    let host = cpal::default_host();
    let device = host
        .default_output_device()
        .ok_or_else(|| "no default audio output device".to_string())?;
    let supported = device
        .default_output_config()
        .map_err(|error| format!("no default output configuration: {error}"))?;

    let format = supported.sample_format();
    let mut config: cpal::StreamConfig = supported.into();
    let wanted = cpal::StreamConfig {
        channels,
        sample_rate,
        buffer_size: cpal::BufferSize::Default,
    };
    if accepts(&device, &wanted, format) {
        config = wanted;
    }

    let mixer = Arc::new(Mutex::new(Mixer::new(
        config.sample_rate,
        config.channels,
        max_voices,
    )));
    let stream = match format {
        cpal::SampleFormat::F32 => build::<f32>(&device, &config, Arc::clone(&mixer)),
        cpal::SampleFormat::I16 => build::<i16>(&device, &config, Arc::clone(&mixer)),
        cpal::SampleFormat::U16 => build::<u16>(&device, &config, Arc::clone(&mixer)),
        cpal::SampleFormat::I32 => build::<i32>(&device, &config, Arc::clone(&mixer)),
        other => Err(format!("unsupported output sample format {other:?}")),
    }?;
    stream
        .play()
        .map_err(|error| format!("the output stream did not start: {error}"))?;

    Ok((
        Output {
            _stream: stream,
            sample_rate: config.sample_rate,
            channels: config.channels,
        },
        mixer,
    ))
}

/// Reports whether the device offers a configuration covering the request.
fn accepts(device: &cpal::Device, wanted: &cpal::StreamConfig, format: cpal::SampleFormat) -> bool {
    let ranges = match device.supported_output_configs() {
        Err(_) => return false,
        Ok(value) => value,
    };
    ranges.into_iter().any(|range| {
        range.channels() == wanted.channels
            && range.sample_format() == format
            && range.min_sample_rate() <= wanted.sample_rate
            && range.max_sample_rate() >= wanted.sample_rate
    })
}

/// Builds the output stream for one sample format.
fn build<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    mixer: Arc<Mutex<Mixer>>,
) -> Result<cpal::Stream, String>
where
    T: SizedSample + FromSample<f32>,
{
    let channels = config.channels as usize;
    let mut scratch: Vec<f32> = Vec::new();
    device
        .build_output_stream(
            *config,
            move |output: &mut [T], _info: &cpal::OutputCallbackInfo| {
                // The buffer arrives filled with silence, so leaving it alone
                // when the mixer is busy produces a gap rather than whatever
                // was there before.
                if channels == 0 {
                    return;
                }
                if scratch.len() < output.len() {
                    // Only on the first callbacks and after a buffer-size
                    // change, which is where an allocation here is affordable.
                    scratch.resize(output.len(), 0.0);
                }
                let frames = output.len() / channels;
                let span = &mut scratch[..frames * channels];
                match mixer.lock() {
                    Err(_) => return,
                    Ok(mut guard) => guard.render(span),
                }
                for (target, source) in output.iter_mut().zip(span.iter()) {
                    *target = T::from_sample(*source);
                }
            },
            move |error| {
                // There is nowhere to report this that the frame thread reads,
                // and a panic here would cross a C callback boundary.
                eprintln!("tecs-audio: output stream error: {error}");
            },
            None,
        )
        .map_err(|error| format!("the output stream did not open: {error}"))
}
