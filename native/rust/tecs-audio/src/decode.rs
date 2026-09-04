//! Symphonia-backed audio decoding for the Tecs audio runtime.
//!
//! This module turns a file on disk into interleaved f32 samples at the source
//! layout. It never downmixes and never resamples: the mixer above owns both.

use std::fs::File;
use std::path::Path;

use symphonia::core::audio::GenericAudioBufferRef;
use symphonia::core::codecs::audio::well_known::{
    CODEC_ID_AAC, CODEC_ID_ADPCM_G722, CODEC_ID_ADPCM_G726, CODEC_ID_ADPCM_G726LE,
    CODEC_ID_ADPCM_IMA_QT, CODEC_ID_ADPCM_IMA_WAV, CODEC_ID_ADPCM_MS, CODEC_ID_ALAC, CODEC_ID_FLAC,
    CODEC_ID_MP1, CODEC_ID_MP2, CODEC_ID_MP3, CODEC_ID_PCM_ALAW, CODEC_ID_PCM_F32BE,
    CODEC_ID_PCM_F32LE, CODEC_ID_PCM_F64BE, CODEC_ID_PCM_F64LE, CODEC_ID_PCM_MULAW,
    CODEC_ID_PCM_S16BE, CODEC_ID_PCM_S16LE, CODEC_ID_PCM_S24BE, CODEC_ID_PCM_S24LE,
    CODEC_ID_PCM_S32BE, CODEC_ID_PCM_S32LE, CODEC_ID_PCM_S8, CODEC_ID_PCM_U8, CODEC_ID_VORBIS,
};
use symphonia::core::codecs::audio::{
    AudioCodecId, AudioCodecParameters, AudioDecoder, AudioDecoderOptions,
};
use symphonia::core::codecs::CodecParameters;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo, TrackType};
use symphonia::core::io::{MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::units::{Duration, Time, TimeBase};

/// The audio codecs this module reports through `decoder_names`.
///
/// The registry offers lookup by codec ID and no iteration, so the report asks
/// after each well-known audio codec in turn and keeps the ones that answer.
const QUERIED_CODECS: &[AudioCodecId] = &[
    CODEC_ID_PCM_S8,
    CODEC_ID_PCM_U8,
    CODEC_ID_PCM_S16LE,
    CODEC_ID_PCM_S16BE,
    CODEC_ID_PCM_S24LE,
    CODEC_ID_PCM_S24BE,
    CODEC_ID_PCM_S32LE,
    CODEC_ID_PCM_S32BE,
    CODEC_ID_PCM_F32LE,
    CODEC_ID_PCM_F32BE,
    CODEC_ID_PCM_F64LE,
    CODEC_ID_PCM_F64BE,
    CODEC_ID_PCM_ALAW,
    CODEC_ID_PCM_MULAW,
    CODEC_ID_ADPCM_G722,
    CODEC_ID_ADPCM_G726,
    CODEC_ID_ADPCM_G726LE,
    CODEC_ID_ADPCM_MS,
    CODEC_ID_ADPCM_IMA_WAV,
    CODEC_ID_ADPCM_IMA_QT,
    CODEC_ID_FLAC,
    CODEC_ID_ALAC,
    CODEC_ID_VORBIS,
    CODEC_ID_MP1,
    CODEC_ID_MP2,
    CODEC_ID_MP3,
    CODEC_ID_AAC,
];

/// Interleaved f32 samples and the layout they were decoded at.
pub struct Decoded {
    /// Holds the decoded audio as interleaved f32 samples in the -1.0 to 1.0 range.
    pub samples: Vec<f32>,
    /// States the source sample rate in Hz.
    pub sample_rate: u32,
    /// States the source channel count, which the samples interleave by.
    pub channels: u16,
}

/// Fully decodes a file into interleaved f32 samples.
///
/// Returns the samples at the file's own sample rate and channel count. Returns
/// an error naming the path when the file cannot be opened, its container
/// cannot be identified, it carries no audio track, or no linked decoder
/// handles its codec.
pub fn decode_all(path: &str) -> Result<Decoded, String> {
    let mut streamer = Streamer::open(path)?;

    let mut samples = Vec::new();
    while streamer.read(&mut samples, usize::MAX)? {}

    Ok(Decoded {
        samples,
        sample_rate: streamer.sample_rate(),
        channels: streamer.channels(),
    })
}

/// Reports a file's duration in seconds when the container states one.
///
/// Returns `Ok(None)` for a file whose container carries no duration, which is
/// a normal answer rather than a failure. Returns an error naming the path when
/// the file cannot be opened or its container cannot be identified.
pub fn probe_duration(path: &str) -> Result<Option<f64>, String> {
    let reader = open_reader(path)?;
    let track = reader
        .default_track(TrackType::Audio)
        .ok_or_else(|| no_audio_track(path))?;

    Ok(
        track_duration_secs(track.time_base, track.duration).or_else(|| {
            track_duration_secs(reader.media_info().time_base, reader.media_info().duration)
        }),
    )
}

/// The decoder names this build linked, for reporting what a build got
/// rather than what it asked for.
///
/// Returns the short codec names, sorted and deduplicated. An empty vector means
/// this build linked no audio decoder at all.
pub fn decoder_names() -> Vec<String> {
    let registry = symphonia::default::get_codecs();

    let mut names: Vec<String> = QUERIED_CODECS
        .iter()
        .filter_map(|id| registry.get_audio_decoder(*id))
        .map(|registered| registered.codec.info.short_name.to_string())
        .collect();

    names.sort();
    names.dedup();
    names
}

/// An incremental reader for streaming playback.
///
/// The streamer holds the file open and decodes one packet at a time, so a
/// caller tops up a ring buffer without ever holding the whole file in memory.
pub struct Streamer {
    path: String,
    reader: Box<dyn FormatReader>,
    decoder: Box<dyn AudioDecoder>,
    track_id: u32,
    sample_rate: u32,
    channels: u16,
    duration: Option<f64>,
    pending: Vec<f32>,
    pending_pos: usize,
    exhausted: bool,
}

impl Streamer {
    /// Opens a file without decoding it.
    ///
    /// Reads only as far as identifying the container and building a decoder for
    /// its first audio track. Returns an error naming the path when the file
    /// cannot be opened, its container cannot be identified, it carries no audio
    /// track, or no linked decoder handles its codec.
    pub fn open(path: &str) -> Result<Streamer, String> {
        let reader = open_reader(path)?;

        let track = reader
            .default_track(TrackType::Audio)
            .ok_or_else(|| no_audio_track(path))?;
        let track_id = track.id;
        let duration = track_duration_secs(track.time_base, track.duration).or_else(|| {
            track_duration_secs(reader.media_info().time_base, reader.media_info().duration)
        });

        let params: AudioCodecParameters = match &track.codec_params {
            Some(CodecParameters::Audio(params)) => params.clone(),
            _ => {
                return Err(format!(
                    "tecs-audio: the audio track of \"{path}\" states no codec parameters"
                ))
            }
        };

        let registry = symphonia::default::get_codecs();
        let registered = registry.get_audio_decoder(params.codec).ok_or_else(|| {
            format!(
                "tecs-audio: this build links no decoder for the codec {} used by \"{path}\"",
                params.codec
            )
        })?;
        let decoder = (registered.factory)(&params, &AudioDecoderOptions::default())
            .map_err(|err| format!("tecs-audio: failed to open a decoder for \"{path}\": {err}"))?;

        let sample_rate = params.sample_rate.unwrap_or(0);
        let channels = params.channels.as_ref().map(|set| set.count()).unwrap_or(0);

        let mut streamer = Streamer {
            path: path.to_string(),
            reader,
            decoder,
            track_id,
            sample_rate,
            channels: u16::try_from(channels).unwrap_or(u16::MAX),
            duration,
            pending: Vec::new(),
            pending_pos: 0,
            exhausted: false,
        };

        // A container that states neither rate nor layout leaves both to the
        // first decoded buffer, so decode until one arrives and keep it.
        if streamer.sample_rate == 0 || streamer.channels == 0 {
            streamer.prime()?;
        }

        Ok(streamer)
    }

    /// Reports the source sample rate in Hz.
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Reports the source channel count, which the read samples interleave by.
    pub fn channels(&self) -> u16 {
        self.channels
    }

    /// Seconds, when the container states a duration.
    pub fn duration(&self) -> Option<f64> {
        self.duration
    }

    /// Appends at most `max` interleaved f32 samples to `out`. Returns false
    /// once the input is exhausted; a true with nothing appended means the
    /// reader made no progress this call and should be tried again.
    ///
    /// Returns an error naming the path only when the container itself fails.
    /// A packet the decoder rejects is dropped and reported as no progress, so a
    /// caller loops on true and stops on false.
    pub fn read(&mut self, out: &mut Vec<f32>, max: usize) -> Result<bool, String> {
        if max == 0 {
            return Ok(!self.is_finished());
        }

        if self.drain(out, max) > 0 {
            return Ok(true);
        }

        if self.exhausted {
            return Ok(false);
        }

        if !self.decode_next()? {
            return Ok(false);
        }

        self.drain(out, max);
        Ok(true)
    }

    /// Moves the read position to `seconds` from the start. Reports whether
    /// the input accepted it. Clears any buffered samples held inside.
    ///
    /// Reports false for a container that cannot seek and for a position the
    /// container rejects, leaving the read position where it already was. A
    /// negative `seconds` moves to the start. A seek after the end of the stream
    /// makes the streamer readable again.
    pub fn seek(&mut self, seconds: f64) -> bool {
        let time = match Time::try_from_secs_f64(seconds.max(0.0)) {
            Some(time) => time,
            None => return false,
        };

        let to = SeekTo::Time {
            time,
            track_id: Some(self.track_id),
        };
        if self.reader.seek(SeekMode::Accurate, to).is_err() {
            return false;
        }

        self.decoder.reset();
        self.pending.clear();
        self.pending_pos = 0;
        self.exhausted = false;
        true
    }

    /// Reports whether the streamer holds no buffered samples and has reached
    /// the end of the input.
    fn is_finished(&self) -> bool {
        self.exhausted && self.pending_pos >= self.pending.len()
    }

    /// Moves up to `max` buffered samples into `out` and returns how many moved.
    fn drain(&mut self, out: &mut Vec<f32>, max: usize) -> usize {
        let available = self.pending.len().saturating_sub(self.pending_pos);
        let count = available.min(max);
        if count == 0 {
            return 0;
        }

        out.extend_from_slice(&self.pending[self.pending_pos..self.pending_pos + count]);
        self.pending_pos += count;

        if self.pending_pos >= self.pending.len() {
            self.pending.clear();
            self.pending_pos = 0;
        }

        count
    }

    /// Decodes packets until the first one that carries audio, adopting its
    /// sample rate and channel count.
    fn prime(&mut self) -> Result<(), String> {
        while self.pending.is_empty() {
            if !self.decode_next()? {
                return Err(format!(
                    "tecs-audio: \"{}\" states no sample rate or channel layout and decoded no audio",
                    self.path
                ));
            }
        }
        Ok(())
    }

    /// Reads one packet and decodes it into the pending buffer.
    ///
    /// Returns `Ok(false)` at the end of the input. Returns `Ok(true)` with the
    /// pending buffer left empty for a packet belonging to another track or for
    /// a packet the decoder rejected.
    fn decode_next(&mut self) -> Result<bool, String> {
        let packet = match self.reader.next_packet() {
            Ok(Some(packet)) => packet,
            Ok(None) => {
                self.exhausted = true;
                return Ok(false);
            }
            Err(SymphoniaError::IoError(err))
                if err.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                self.exhausted = true;
                return Ok(false);
            }
            Err(SymphoniaError::ResetRequired) => {
                self.decoder.reset();
                return Ok(true);
            }
            Err(err) => {
                return Err(format!(
                    "tecs-audio: failed to read a packet from \"{}\": {err}",
                    self.path
                ))
            }
        };

        if packet.track_id != self.track_id {
            return Ok(true);
        }

        match self.decoder.decode(&packet) {
            Ok(buffer) => {
                adopt_spec(&buffer, &mut self.sample_rate, &mut self.channels);
                buffer.copy_to_vec_interleaved(&mut self.pending);
                self.pending_pos = 0;
            }
            // A malformed packet is discardable; decoding continues with the next.
            Err(SymphoniaError::DecodeError(_)) | Err(SymphoniaError::IoError(_)) => {}
            Err(SymphoniaError::ResetRequired) => self.decoder.reset(),
            Err(err) => {
                return Err(format!(
                    "tecs-audio: failed to decode a packet of \"{}\": {err}",
                    self.path
                ))
            }
        }

        Ok(true)
    }
}

/// Copies the decoded buffer's rate and channel count into the streamer's own.
fn adopt_spec(buffer: &GenericAudioBufferRef<'_>, sample_rate: &mut u32, channels: &mut u16) {
    let spec = buffer.spec();
    if spec.rate() > 0 {
        *sample_rate = spec.rate();
    }
    let count = spec.channels().count();
    if count > 0 {
        *channels = u16::try_from(count).unwrap_or(u16::MAX);
    }
}

/// Opens the file at `path` and identifies its container format.
///
/// Passes the file extension to the probe as a hint when the path carries a
/// usable one, and probes on content alone otherwise.
fn open_reader(path: &str) -> Result<Box<dyn FormatReader>, String> {
    let file =
        File::open(path).map_err(|err| format!("tecs-audio: failed to open \"{path}\": {err}"))?;

    let source = MediaSourceStream::new(Box::new(file), MediaSourceStreamOptions::default());

    let mut hint = Hint::new();
    if let Some(extension) = Path::new(path).extension().and_then(|ext| ext.to_str()) {
        if !extension.is_empty() {
            hint.with_extension(extension);
        }
    }

    symphonia::default::get_probe()
        .probe(
            &hint,
            source,
            FormatOptions::default(),
            MetadataOptions::default(),
        )
        .map_err(|err| format!("tecs-audio: failed to identify the format of \"{path}\": {err}"))
}

/// Converts a container-stated duration into seconds.
fn track_duration_secs(time_base: Option<TimeBase>, duration: Option<Duration>) -> Option<f64> {
    let time_base = time_base?;
    let duration = duration?;
    time_base
        .calc_duration(duration)
        .map(|time| time.as_secs_f64())
}

/// Builds the error reported for a file that carries no audio track.
fn no_audio_track(path: &str) -> String {
    format!("tecs-audio: \"{path}\" carries no audio track")
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    /// Counts test files so two in the same process never collide.
    static COUNTER: AtomicU64 = AtomicU64::new(0);

    /// A generated test file that removes itself when the test ends.
    struct TempWav {
        path: PathBuf,
    }

    impl TempWav {
        /// Writes a WAV file holding `samples` interleaved at the given layout.
        ///
        /// `float` selects 32-bit IEEE float samples; otherwise the file holds
        /// 16-bit signed PCM.
        fn write(samples: &[f32], sample_rate: u32, channels: u16, float: bool) -> TempWav {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
            let name = format!(
                "tecs-audio-decode-{}-{}-{}.wav",
                std::process::id(),
                nanos,
                unique
            );

            let path = std::env::temp_dir().join(name);
            fs::write(&path, encode_wav(samples, sample_rate, channels, float))
                .expect("the temp directory accepts a test file");

            TempWav { path }
        }

        /// Reports the file's path as a string.
        fn as_str(&self) -> &str {
            self.path.to_str().expect("the temp path is valid UTF-8")
        }
    }

    impl Drop for TempWav {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.path);
        }
    }

    /// Builds the bytes of a RIFF/WAVE file holding the given samples.
    fn encode_wav(samples: &[f32], sample_rate: u32, channels: u16, float: bool) -> Vec<u8> {
        let bits_per_sample: u16 = if float { 32 } else { 16 };
        let format_tag: u16 = if float { 3 } else { 1 };
        let block_align = channels * (bits_per_sample / 8);
        let byte_rate = sample_rate * u32::from(block_align);

        let mut data = Vec::with_capacity(samples.len() * usize::from(bits_per_sample / 8));
        for sample in samples {
            if float {
                data.extend_from_slice(&sample.to_le_bytes());
            } else {
                let scaled = (sample * 32767.0).round().clamp(-32768.0, 32767.0) as i16;
                data.extend_from_slice(&scaled.to_le_bytes());
            }
        }

        let mut out = Vec::with_capacity(44 + data.len());
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36u32 + data.len() as u32).to_le_bytes());
        out.extend_from_slice(b"WAVE");
        out.extend_from_slice(b"fmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&format_tag.to_le_bytes());
        out.extend_from_slice(&channels.to_le_bytes());
        out.extend_from_slice(&sample_rate.to_le_bytes());
        out.extend_from_slice(&byte_rate.to_le_bytes());
        out.extend_from_slice(&block_align.to_le_bytes());
        out.extend_from_slice(&bits_per_sample.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(&data);
        out
    }

    /// Returns the error of a failed call, panicking when the call succeeded.
    ///
    /// The public success types hold boxed trait objects and so cannot derive
    /// `Debug`, which `Result::expect_err` requires.
    fn expect_error<T>(result: Result<T, String>, what: &str) -> String {
        match result {
            Ok(_) => panic!("{what}"),
            Err(error) => error,
        }
    }

    /// Builds a stereo sine sweep of `frames` frames.
    fn stereo_tone(frames: usize) -> Vec<f32> {
        let mut samples = Vec::with_capacity(frames * 2);
        for frame in 0..frames {
            let phase = frame as f32 / 64.0;
            samples.push((phase).sin() * 0.5);
            samples.push((phase * 1.5).sin() * 0.25);
        }
        samples
    }

    #[test]
    fn decode_all_round_trips_16_bit_pcm() {
        let expected = stereo_tone(4800);
        let wav = TempWav::write(&expected, 48_000, 2, false);

        let decoded = decode_all(wav.as_str()).expect("the generated WAV decodes");

        assert_eq!(decoded.sample_rate, 48_000);
        assert_eq!(decoded.channels, 2);
        assert_eq!(decoded.samples.len(), expected.len());

        for (index, (actual, want)) in decoded.samples.iter().zip(expected.iter()).enumerate() {
            assert!(
                (actual - want).abs() < 1.0e-3,
                "sample {index} decoded as {actual}, expected about {want}"
            );
            assert!(
                (-1.0..=1.0).contains(actual),
                "sample {index} left the -1.0..1.0 range"
            );
        }
    }

    #[test]
    fn decode_all_round_trips_32_bit_float_pcm() {
        let expected = stereo_tone(2400);
        let wav = TempWav::write(&expected, 44_100, 2, true);

        let decoded = decode_all(wav.as_str()).expect("the generated float WAV decodes");

        assert_eq!(decoded.sample_rate, 44_100);
        assert_eq!(decoded.channels, 2);
        assert_eq!(decoded.samples.len(), expected.len());

        for (index, (actual, want)) in decoded.samples.iter().zip(expected.iter()).enumerate() {
            assert!(
                (actual - want).abs() < 1.0e-6,
                "sample {index} decoded as {actual}, expected about {want}"
            );
        }
    }

    #[test]
    fn decode_all_reports_a_mono_file_as_one_channel() {
        let expected: Vec<f32> = (0..1000).map(|n| (n as f32 / 32.0).sin() * 0.5).collect();
        let wav = TempWav::write(&expected, 22_050, 1, false);

        let decoded = decode_all(wav.as_str()).expect("the generated mono WAV decodes");

        assert_eq!(decoded.channels, 1);
        assert_eq!(decoded.sample_rate, 22_050);
        assert_eq!(decoded.samples.len(), expected.len());
    }

    #[test]
    fn probe_duration_matches_the_generated_length() {
        let expected = stereo_tone(48_000);
        let wav = TempWav::write(&expected, 48_000, 2, false);

        let duration = probe_duration(wav.as_str())
            .expect("the generated WAV probes")
            .expect("a WAV container states a duration");

        assert!(
            (duration - 1.0).abs() < 1.0e-3,
            "probed {duration} seconds, expected about 1.0"
        );
    }

    #[test]
    fn streamer_reads_the_same_total_as_decode_all() {
        let expected = stereo_tone(5000);
        let wav = TempWav::write(&expected, 48_000, 2, false);

        let decoded = decode_all(wav.as_str()).expect("the generated WAV decodes");

        let mut streamer = Streamer::open(wav.as_str()).expect("the generated WAV opens");
        assert_eq!(streamer.sample_rate(), 48_000);
        assert_eq!(streamer.channels(), 2);
        assert!(
            streamer.duration().is_some(),
            "a WAV container states a duration"
        );

        let mut streamed = Vec::new();
        let mut calls = 0;
        loop {
            calls += 1;
            assert!(calls < 1_000_000, "the streamer never reported exhaustion");
            if !streamer
                .read(&mut streamed, 512)
                .expect("streaming reads succeed")
            {
                break;
            }
            assert!(
                streamed.len() <= decoded.samples.len(),
                "the streamer overran the file"
            );
        }

        assert_eq!(streamed.len(), decoded.samples.len());
        assert_eq!(streamed, decoded.samples);

        // Exhaustion is stable: another read still reports false and appends nothing.
        let before = streamed.len();
        assert!(!streamer
            .read(&mut streamed, 512)
            .expect("a read past the end succeeds"));
        assert_eq!(streamed.len(), before);
    }

    #[test]
    fn streamer_read_never_appends_more_than_max() {
        let expected = stereo_tone(5000);
        let wav = TempWav::write(&expected, 48_000, 2, false);

        let mut streamer = Streamer::open(wav.as_str()).expect("the generated WAV opens");

        let mut streamed = Vec::new();
        loop {
            let before = streamed.len();
            let more = streamer
                .read(&mut streamed, 100)
                .expect("streaming reads succeed");
            assert!(
                streamed.len() - before <= 100,
                "one read appended more than max"
            );
            if !more {
                assert_eq!(streamed.len(), before, "the final read appended samples");
                break;
            }
        }
        assert_eq!(streamed.len(), expected.len());
    }

    #[test]
    fn streamer_seek_moves_to_the_midpoint() {
        let expected = stereo_tone(48_000);
        let wav = TempWav::write(&expected, 48_000, 2, false);

        let decoded = decode_all(wav.as_str()).expect("the generated WAV decodes");

        let mut streamer = Streamer::open(wav.as_str()).expect("the generated WAV opens");
        assert!(streamer.seek(0.5), "a WAV container accepts a seek");

        let mut second_half = Vec::new();
        while streamer
            .read(&mut second_half, 4096)
            .expect("streaming reads succeed")
        {}

        // An accurate seek lands at or before the requested position, so the
        // read may start up to one packet early. Allow a tenth of a second.
        let want = decoded.samples.len() / 2;
        let slack = (decoded.sample_rate as usize / 10) * usize::from(decoded.channels);
        assert!(
            second_half.len() >= want && second_half.len() <= want + slack,
            "reading from 0.5 s yielded {} samples, expected about {want}",
            second_half.len()
        );

        // The samples read after the seek line up with the second half.
        let offset = decoded.samples.len() - second_half.len();
        for (index, (actual, want)) in second_half
            .iter()
            .zip(decoded.samples[offset..].iter())
            .enumerate()
            .take(2048)
        {
            assert!(
                (actual - want).abs() < 1.0e-6,
                "sample {index} after the seek is {actual}, expected {want}"
            );
        }
    }

    #[test]
    fn streamer_seek_revives_an_exhausted_stream() {
        let expected = stereo_tone(2400);
        let wav = TempWav::write(&expected, 48_000, 2, false);

        let mut streamer = Streamer::open(wav.as_str()).expect("the generated WAV opens");

        let mut drained = Vec::new();
        while streamer
            .read(&mut drained, 4096)
            .expect("streaming reads succeed")
        {}
        assert_eq!(drained.len(), expected.len());

        assert!(streamer.seek(0.0), "a seek back to the start is accepted");

        let mut again = Vec::new();
        while streamer
            .read(&mut again, 4096)
            .expect("streaming reads succeed")
        {}
        assert_eq!(again.len(), expected.len());
    }

    #[test]
    fn a_missing_path_reports_an_error() {
        let missing = std::env::temp_dir().join("tecs-audio-decode-does-not-exist.wav");
        let missing = missing.to_str().expect("the temp path is valid UTF-8");

        let error = expect_error(decode_all(missing), "a missing file decoded");
        assert!(!error.is_empty());
        assert!(
            error.contains(missing),
            "the error does not name the path: {error}"
        );

        let error = expect_error(probe_duration(missing), "a missing file probed");
        assert!(!error.is_empty());
        assert!(
            error.contains(missing),
            "the error does not name the path: {error}"
        );

        let error = expect_error(Streamer::open(missing), "a missing file opened");
        assert!(!error.is_empty());
        assert!(
            error.contains(missing),
            "the error does not name the path: {error}"
        );
    }

    #[test]
    fn a_file_that_is_not_audio_reports_an_error() {
        let path =
            std::env::temp_dir().join(format!("tecs-audio-decode-junk-{}.wav", std::process::id()));
        fs::write(&path, b"this file is not audio at all").expect("the temp directory accepts it");

        let result = decode_all(path.to_str().expect("valid UTF-8"));
        let _ = fs::remove_file(&path);

        let error = expect_error(result, "a text file decoded as audio");
        assert!(!error.is_empty());
    }

    #[test]
    fn decoder_names_reports_the_linked_decoders() {
        let names = decoder_names();
        assert!(
            names.iter().any(|name| name == "pcm_s16le"),
            "this build links no 16-bit PCM decoder: {names:?}"
        );
        assert!(
            names.windows(2).all(|pair| pair[0] < pair[1]),
            "names are sorted and unique"
        );
    }
}
