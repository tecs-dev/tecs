//! Completed native frames, including CPU extraction, upload and GPU execution.
use anyhow::{bail, Context, Result};
use serde_json::json;
use std::path::PathBuf;

pub struct Run {
    path: PathBuf,
    samples: u32,
    warmup: u32,
    seen: u32,
    rows: Vec<[f64; 4]>,
    uploads: Vec<usize>,
    instances: Option<u32>,
    drawn: Option<u32>,
}

impl Run {
    pub fn new(path: PathBuf, samples: u32, warmup: u32) -> Result<Self> {
        if samples == 0 {
            bail!("benchmark samples must be positive");
        }
        Ok(Self {
            path,
            samples,
            warmup,
            seen: 0,
            rows: Vec::new(),
            uploads: Vec::new(),
            instances: None,
            drawn: None,
        })
    }

    pub fn finishing_next(&self) -> bool {
        self.seen >= self.warmup && self.rows.len() + 1 == self.samples as usize
    }

    pub fn record(&mut self, packet: &[u8], times: [f64; 3], drawn: Option<u32>) -> Result<bool> {
        let count = u32::from_ne_bytes(
            packet
                .get(36..40)
                .context("missing instance count")?
                .try_into()?,
        );
        if let Ok(expected) = std::env::var("BENCH_COUNT") {
            let expected = expected.parse::<u32>()?;
            if count != expected {
                bail!("requested {expected} shapes but the packet contains {count}");
            }
        }
        if let Some(previous) = self.instances {
            if count != previous {
                bail!("benchmark instance count changed from {previous} to {count}");
            }
        }
        self.instances = Some(count);
        if let Some(drawn) = drawn {
            if drawn != count {
                bail!("GPU drew {drawn} instances but the scene contains {count}");
            }
            self.drawn = Some(drawn);
        }
        self.seen += 1;
        if self.seen <= self.warmup {
            return Ok(false);
        }
        self.rows
            .push([times[0], times[1], times[2], times.iter().sum()]);
        let flags = u32::from_ne_bytes(packet[12..16].try_into()?);
        let uploaded = if flags & crate::packet::FRAME_RETAINED != 0 {
            0
        } else if flags & crate::packet::FRAME_DELTA != 0 {
            let graph = u32::from_ne_bytes(packet[20..24].try_into()?) as usize;
            let lights = u32::from_ne_bytes(packet[68..72].try_into()?) as usize;
            let tiles = u32::from_ne_bytes(packet[124..128].try_into()?) as usize;
            let start = 128 + graph + lights * 32 + tiles * (crate::packet::TILE_STRIDE + 4);
            let ranges = u32::from_ne_bytes(packet[start + 4..start + 8].try_into()?) as usize;
            packet.len() - start - 8 - ranges * 8
        } else {
            count as usize * crate::packet::INSTANCE_STRIDE
        };
        self.uploads.push(uploaded);
        if self.rows.len() != self.samples as usize {
            return Ok(false);
        }
        self.require_complete()?;
        let stages: Vec<_> = [
            "update",
            "extract",
            "render_and_gpu_wait",
            "completed_frame",
        ]
        .iter()
        .enumerate()
        .map(|(index, name)| {
            let mut values: Vec<_> = self.rows.iter().map(|row| row[index]).collect();
            values.sort_by(f64::total_cmp);
            let percentile = |fraction: f64| {
                values[((values.len() as f64 * fraction).ceil() as usize).saturating_sub(1)]
            };
            json!({
                "name": name,
                "p50_ms": percentile(0.5),
                "p95_ms": percentile(0.95),
                "p99_ms": percentile(0.99),
                "mean_ms": values.iter().sum::<f64>() / values.len() as f64,
                "max_ms": values[values.len()-1]
            })
        })
        .collect();
        let report = json!({
            "instances": count,
            "gpu_drawn_instances": self.drawn,
            "packet_bytes": packet.len(),
            "target_pixels": [
                f32::from_ne_bytes(packet[40..44].try_into()?),
                f32::from_ne_bytes(packet[44..48].try_into()?)
            ],
            "samples": self.samples,
            "warmup": self.warmup,
            "stages": stages,
            "samples_ms": self.rows,
            "instance_upload_bytes_per_frame": self.uploads,
            "shape": std::env::var("BENCH_SHAPE").unwrap_or_else(|_| "all".into()),
            "motion": std::env::var("BENCH_MOTION").unwrap_or_else(|_| "static".into()),
            "measurement": "serial completed offscreen GPU frames; render includes validation, uploads, command recording and GPU execution; excludes swapchain and desktop presentation"
        });
        if let Some(parent) = self.path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&self.path, serde_json::to_vec_pretty(&report)?)?;
        println!(
            "render benchmark: {count} instances; {}",
            self.path.display()
        );
        for stage in stages {
            println!(
                "{}: p50={} ms p95={} ms",
                stage["name"], stage["p50_ms"], stage["p95_ms"]
            );
        }
        Ok(true)
    }

    pub fn require_complete(&self) -> Result<()> {
        if self.rows.len() != self.samples as usize {
            bail!("render benchmark stopped before collecting all samples");
        }
        if self.drawn != self.instances || self.drawn.is_none() {
            bail!("render benchmark has no verified GPU draw count");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_empty_or_incomplete_measurements() {
        assert!(Run::new(PathBuf::new(), 0, 0).is_err());
        let run = Run::new(PathBuf::new(), 2, 0).unwrap();
        assert!(run.require_complete().is_err());
    }

    #[test]
    fn discards_warmup_and_refuses_a_changing_scene() {
        let mut run = Run::new(PathBuf::new(), 2, 1).unwrap();
        let mut packet = [0_u8; 48];
        packet[36..40].copy_from_slice(&12_u32.to_ne_bytes());
        assert!(!run.record(&packet, [1.0, 2.0, 3.0], None).unwrap());
        assert!(run.rows.is_empty());
        assert!(!run.record(&packet, [1.0, 2.0, 3.0], None).unwrap());
        assert_eq!(run.rows, [[1.0, 2.0, 3.0, 6.0]]);
        packet[36..40].copy_from_slice(&11_u32.to_ne_bytes());
        assert!(run.record(&packet, [1.0, 2.0, 3.0], None).is_err());
    }

    #[test]
    fn refuses_missing_or_incorrect_gpu_draw_counts() {
        let mut packet = [0_u8; 48];
        packet[36..40].copy_from_slice(&12_u32.to_ne_bytes());
        let mut missing = Run::new(PathBuf::new(), 1, 0).unwrap();
        assert!(missing.record(&packet, [1.0, 2.0, 3.0], None).is_err());
        let mut culled = Run::new(PathBuf::new(), 1, 0).unwrap();
        assert!(culled.record(&packet, [1.0, 2.0, 3.0], Some(11)).is_err());
    }
}
