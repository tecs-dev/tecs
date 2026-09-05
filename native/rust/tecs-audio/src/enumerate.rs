//! Naming the playback and recording devices attached now.
//!
//! Enumeration is a snapshot rather than a subscription, and it is cold: a game
//! lists devices to fill a settings menu, not once a frame. So this allocates
//! freely and holds each name as a `CString` the binding borrows, rather than
//! copying names into a fixed-width struct that would truncate the long ones
//! some interfaces produce.
//!
//! Nothing here is reachable from a test. Asking a host for its device list goes
//! through the same platform machinery an open does, and on macOS that is the
//! CoreAudio HAL proxy, which blocks without bound when the audio daemon is
//! unreachable. `examples/devicecheck.rs` is the manual check.

use std::ffi::CString;

use cpal::traits::{DeviceTrait, HostTrait};

/// One device, as Tecs reports it.
pub struct DeviceEntry {
    /// The position in this listing, from one up. Zero is never assigned: it
    /// means "the platform default" wherever a device is selected.
    pub id: u32,
    /// The platform's display name, which is the only durable way to name a
    /// device across runs.
    pub name: CString,
    /// The device's preferred frames per second, and zero when it will not say.
    pub frequency: u32,
    /// The device's preferred channels per frame, and zero when it will not
    /// say.
    pub channels: u16,
}

/// A finished listing, owned by the caller until it is freed.
pub struct DeviceList {
    /// The devices in the order the host produced them, which is the order the
    /// ids number.
    pub entries: Vec<DeviceEntry>,
}

/// Names every device of one direction attached now.
///
/// A device whose preferred configuration cannot be read is still listed, with
/// zero for the frequency and channels it would not report. A device that has
/// no readable name at all is skipped, because an unnamed entry cannot be
/// selected again on a later run.
///
/// @return the listing, or the reason the host gave for producing none
pub fn list(recording: bool) -> Result<DeviceList, String> {
    let host = cpal::default_host();
    let devices: Vec<cpal::Device> = if recording {
        host.input_devices()
            .map_err(|error| format!("no recording devices: {error}"))?
            .collect()
    } else {
        host.output_devices()
            .map_err(|error| format!("no playback devices: {error}"))?
            .collect()
    };

    let mut entries: Vec<DeviceEntry> = Vec::with_capacity(devices.len());
    for device in devices.iter() {
        let name = match display_name(device) {
            None => continue,
            Some(value) => value,
        };
        let config = if recording {
            device.default_input_config().ok()
        } else {
            device.default_output_config().ok()
        };
        let (frequency, channels) = match config {
            None => (0, 0),
            Some(value) => (value.sample_rate(), value.channels()),
        };
        entries.push(DeviceEntry {
            id: entries.len() as u32 + 1,
            name,
            frequency,
            channels,
        });
    }

    Ok(DeviceList { entries })
}

/// Returns the recording device an id or a name selects.
///
/// A name wins over an id, because a name survives a run and an id is only
/// meaningful for the listing that produced it. Neither given takes the
/// platform's current default.
///
/// @return the device, or the reason nothing matched
pub fn find_input(id: u32, name: Option<&str>) -> Result<cpal::Device, String> {
    let host = cpal::default_host();
    if let Some(wanted) = name.filter(|value| !value.is_empty()) {
        let devices = host
            .input_devices()
            .map_err(|error| format!("no recording devices: {error}"))?;
        for device in devices {
            if display_name(&device).is_some_and(|found| found.to_bytes() == wanted.as_bytes()) {
                return Ok(device);
            }
        }

        return Err(format!("no recording device named '{wanted}'"));
    }
    if id > 0 {
        let devices = host
            .input_devices()
            .map_err(|error| format!("no recording devices: {error}"))?;
        // The id is a position in the listing rather than anything the platform
        // issued, so it is resolved against a listing taken now. A device that
        // has come or gone since then moves, which is why a game that keeps a
        // choice keeps the name.
        let mut position: u32 = 0;
        for device in devices {
            if display_name(&device).is_none() {
                continue;
            }
            position += 1;
            if position == id {
                return Ok(device);
            }
        }

        return Err(format!("no recording device with id {id}"));
    }

    host.default_input_device()
        .ok_or_else(|| "no default recording device".to_string())
}

/// Returns a device's display name, or nothing when it has none this can use.
fn display_name(device: &cpal::Device) -> Option<CString> {
    let text = match device.description() {
        Ok(value) => value.name().to_string(),
        Err(_) => return None,
    };
    if text.is_empty() {
        return None;
    }

    CString::new(text).ok()
}
