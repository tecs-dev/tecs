//! The original directional light, distance fog and ambient-cube equations.
use super::*;
use serde_json::Value;

pub(super) fn parameters(bytes: &[u8]) -> Result<[f32; 40]> {
    let settings: Value = if bytes.is_empty() {
        serde_json::json!({})
    } else {
        serde_json::from_slice(bytes)?
    };
    let number = |key: &str, default: f32| -> Result<f32> {
        let value = match settings.get(key) {
            Some(v) => v.as_f64().context("lighting parameter must be numeric")? as f32,
            None => default,
        };
        if !value.is_finite() {
            bail!("lighting {key} must be finite");
        }
        Ok(value)
    };
    let mut values = [0.; 40];
    for (lane, key, default) in [
        (0, "directionX", -0.5),
        (1, "directionY", -1.),
        (2, "directionZ", -0.5),
        (3, "intensity", 1.),
        (4, "r", 1.),
        (5, "g", 1.),
        (6, "b", 1.),
        (7, "ambient", 0.15),
        (8, "fogR", 0.),
        (9, "fogG", 0.),
        (10, "fogB", 0.),
        (12, "fogStart", 20.),
        (13, "fogFinish", 100.),
        (14, "probeIntensity", 1.),
    ] {
        values[lane] = number(key, default)?;
    }
    values[11] = match settings.get("fog") {
        None => 0.,
        Some(v) => u32::from(v.as_bool().context("fog must be boolean")?) as f32,
    };
    if values[..3].iter().all(|v| *v == 0.)
        || values[3..11].iter().any(|v| *v < 0.)
        || values[8..11].iter().any(|v| *v > 1.)
        || values[12] < 0.
        || values[13] <= values[12]
        || values[14] < 0.
    {
        bail!("invalid mesh lighting range or zero direction");
    }
    // Nupp's empty tables encode as objects. An empty probe disables it.
    if let Some(probe) = settings.get("probe") {
        if let Some(faces) = probe.as_array() {
            if !faces.is_empty() && faces.len() != 18 {
                bail!("ambient cube needs six RGB faces");
            }
            for (i, v) in faces.iter().enumerate() {
                let value = v.as_f64().context("ambient cube value must be numeric")? as f32;
                if !value.is_finite() || value < 0. {
                    bail!("ambient cube irradiance must be finite and non-negative");
                }
                values[16 + i / 3 * 4 + i % 3] = value;
            }
        } else if !probe.as_object().is_some_and(|o| o.is_empty()) {
            bail!("invalid ambient cube");
        }
    }
    Ok(values)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_invalid_lighting_without_uploading_it() {
        for value in [
            r#"{"directionX":0,"directionY":0,"directionZ":0}"#,
            r#"{"fogStart":10,"fogFinish":5}"#,
            r#"{"intensity":-1}"#,
            r#"{"probe":[1,2,3]}"#,
        ] {
            assert!(parameters(value.as_bytes()).is_err());
        }
        assert!(parameters(br#"{"probe":{}}"#).is_ok());
    }
}
