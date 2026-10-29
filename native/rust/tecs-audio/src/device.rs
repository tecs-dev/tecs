//! The `cpal` output stream.
//!
//! The data callback runs on a thread this process never created: CoreAudio
//! calls it on its own realtime thread, and ALSA and WASAPI call it on a thread
//! `cpal` spawned. Nothing reachable from inside it may enter the Lua virtual
//! machine, allocate, or open a file, which is why the callback does one thing:
//! hand the buffer it was given to the stream's [`Feed`], which locks the mixer
//! and fills it.
//!
//! This is the platform half of [`crate::output`]. It opens the default output
//! at the format the device has now, whatever the engine runs at, and turns
//! each stream error into what the supervisor does about it.

use std::any::Any;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SizedSample};

use crate::conform::Format;
use crate::output::{Alarm, Feed, Host, Tap};

/// The platform's default output, as the supervisor reaches it.
pub struct CpalHost {
    host: cpal::Host,
}

impl CpalHost {
    /// Takes the platform's default host.
    pub fn new() -> Result<CpalHost, String> {
        Ok(CpalHost {
            host: cpal::default_host(),
        })
    }

    /// Finds the default output and the configuration it runs at now.
    fn default_config(&self) -> Result<(cpal::Device, cpal::SupportedStreamConfig), String> {
        let device = self
            .host
            .default_output_device()
            .ok_or_else(|| "no default audio output device".to_string())?;
        let supported = device
            .default_output_config()
            .map_err(|error| format!("no default output configuration: {error}"))?;
        Ok((device, supported))
    }
}

impl Host for CpalHost {
    fn current(&mut self) -> Result<Format, String> {
        let (_, supported) = self.default_config()?;
        Ok(Format {
            sample_rate: supported.sample_rate(),
            channels: supported.channels(),
        })
    }

    /// Opens the default output at its own current configuration.
    ///
    /// The engine's rate is not asked for. Asking would have `cpal` set the
    /// hardware's nominal rate, which changes it for every other program on the
    /// device, and a headset in its microphone profile refuses anyway; the
    /// stream's conformer meets whatever the device runs at instead.
    fn open(&mut self, tap: Tap) -> Result<(Box<dyn Any>, Format), String> {
        let (device, supported) = self.default_config()?;
        let sample_format = supported.sample_format();
        let config: cpal::StreamConfig = supported.into();
        if config.channels == 0 || config.sample_rate == 0 {
            return Err(format!(
                "the default output reports {} Hz and {} channels",
                config.sample_rate, config.channels
            ));
        }
        let format = Format {
            sample_rate: config.sample_rate,
            channels: config.channels,
        };
        let feed = tap.feed(format);
        let alarm = tap.alarm();
        let stream = match sample_format {
            cpal::SampleFormat::F32 => build::<f32>(&device, &config, feed, alarm),
            cpal::SampleFormat::I16 => build::<i16>(&device, &config, feed, alarm),
            cpal::SampleFormat::U16 => build::<u16>(&device, &config, feed, alarm),
            cpal::SampleFormat::I32 => build::<i32>(&device, &config, feed, alarm),
            other => Err(format!("unsupported output sample format {other:?}")),
        }?;
        stream
            .play()
            .map_err(|error| format!("the output stream did not start: {error}"))?;
        Ok((Box::new(stream), format))
    }

    /// Polls on macOS, where a device can change format under a default-output
    /// stream without `cpal` reporting anything. Elsewhere asking can mean
    /// opening the device a second time, and the stream's own errors and the
    /// stall check are what the supervisor goes by.
    fn polls_format(&self) -> bool {
        cfg!(target_os = "macos")
    }
}

/// Reports whether a stream error leaves the output dead.
///
/// `cpal` reports more than failures through the error callback. A buffer
/// that missed its deadline (`Xrun`: CoreAudio's processor-overload
/// notification, which a slow first callback or a busy machine raises), a
/// default output followed to a new device (`DeviceChanged`) and a refused
/// realtime promotion (`RealtimeDenied`) all leave the stream playing. Taking
/// them as terminal silenced the whole mixer for good on one late buffer.
pub(crate) fn ends_the_stream(kind: cpal::ErrorKind) -> bool {
    !matches!(
        kind,
        cpal::ErrorKind::Xrun | cpal::ErrorKind::DeviceChanged | cpal::ErrorKind::RealtimeDenied
    )
}

/// What the supervisor does about one stream error.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Response {
    /// Nothing: the stream plays on.
    Ignore,
    /// Compare the device's format with the stream's now. A reroute leaves the
    /// stream playing, but the device it reached can run at another format.
    Recheck,
    /// Replace the stream.
    Reopen,
}

/// Classifies a stream error for the supervisor.
pub(crate) fn respond(kind: cpal::ErrorKind) -> Response {
    if ends_the_stream(kind) {
        Response::Reopen
    } else if matches!(kind, cpal::ErrorKind::DeviceChanged) {
        Response::Recheck
    } else {
        Response::Ignore
    }
}

/// Names what happened to the stream, for the reason the output reports.
fn describe(kind: cpal::ErrorKind) -> &'static str {
    match kind {
        cpal::ErrorKind::StreamInvalidated => "the output stream was invalidated",
        cpal::ErrorKind::DeviceNotAvailable => "the output device went away",
        cpal::ErrorKind::HostUnavailable => "the audio host went away",
        _ => "the output stream failed",
    }
}

/// Builds the output stream for one sample format.
fn build<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    mut feed: Feed,
    alarm: Alarm,
) -> Result<cpal::Stream, String>
where
    T: SizedSample + FromSample<f32>,
{
    device
        .build_output_stream(
            *config,
            move |output: &mut [T], _info: &cpal::OutputCallbackInfo| {
                feed.fill(output, T::from_sample);
            },
            move |error: cpal::Error| {
                // Classified before anything else, because an overrun arrives
                // on the realtime thread and must cost nothing. The kinds that
                // do act arrive on a `cpal` monitor thread, where formatting a
                // reason is affordable. Nothing here reopens a device.
                match respond(error.kind()) {
                    Response::Ignore => {}
                    Response::Recheck => alarm.recheck(),
                    Response::Reopen => {
                        alarm.lost(&format!("{}: {error}", describe(error.kind())));
                    }
                }
            },
            None,
        )
        .map_err(|error| format!("the output stream did not open: {error}"))
}

#[cfg(test)]
mod tests {
    use super::{ends_the_stream, respond, Response};
    use cpal::ErrorKind;

    #[test]
    fn a_reroute_asks_for_a_format_check_and_a_dead_stream_for_a_reopen() {
        assert_eq!(respond(ErrorKind::Xrun), Response::Ignore);
        assert_eq!(respond(ErrorKind::RealtimeDenied), Response::Ignore);
        assert_eq!(respond(ErrorKind::DeviceChanged), Response::Recheck);
        assert_eq!(respond(ErrorKind::StreamInvalidated), Response::Reopen);
        assert_eq!(respond(ErrorKind::DeviceNotAvailable), Response::Reopen);
        assert_eq!(respond(ErrorKind::BackendError), Response::Reopen);
    }

    #[test]
    fn a_late_buffer_or_a_reroute_does_not_end_the_stream() {
        assert!(!ends_the_stream(ErrorKind::Xrun));
        assert!(!ends_the_stream(ErrorKind::DeviceChanged));
        assert!(!ends_the_stream(ErrorKind::RealtimeDenied));
    }

    #[test]
    fn a_lost_device_or_an_invalidated_stream_does() {
        assert!(ends_the_stream(ErrorKind::DeviceNotAvailable));
        assert!(ends_the_stream(ErrorKind::HostUnavailable));
        assert!(ends_the_stream(ErrorKind::StreamInvalidated));
        assert!(ends_the_stream(ErrorKind::BackendError));
    }
}
