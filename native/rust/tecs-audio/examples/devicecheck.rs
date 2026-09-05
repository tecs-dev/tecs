//! Names the playback and recording devices attached now.
//!
//! A manual smoke check for a real machine, kept out of the test suite for the
//! same reason `opencheck` is: asking the host for its device list goes through
//! the platform machinery an open goes through, and on macOS that can block
//! without bound when the audio daemon is unreachable.

fn main() {
    for (label, recording) in [("playback", false), ("recording", true)] {
        eprintln!("listing {label} devices");
        match tecsaudio::enumerate::list(recording) {
            Err(reason) => eprintln!("  none: {reason}"),
            Ok(listing) => {
                for entry in listing.entries.iter() {
                    eprintln!(
                        "  id={} rate={} channels={} name={}",
                        entry.id,
                        entry.frequency,
                        entry.channels,
                        entry.name.to_string_lossy()
                    );
                }
            }
        }
    }
}
