use fastnoise_lite::{FastNoiseLite, FractalType, NoiseType};
use std::{ptr, slice};

pub struct TecsNoise {
    field: FastNoiseLite,
}

fn algorithm(value: u8) -> Option<NoiseType> {
    Some(match value {
        0 => NoiseType::Perlin,
        1 => NoiseType::OpenSimplex2,
        2 => NoiseType::OpenSimplex2S,
        3 => NoiseType::Cellular,
        4 => NoiseType::Value,
        5 => NoiseType::ValueCubic,
        _ => return None,
    })
}

fn fractal(value: u8) -> Option<FractalType> {
    Some(match value {
        0 => FractalType::None,
        1 => FractalType::FBm,
        2 => FractalType::Ridged,
        3 => FractalType::PingPong,
        _ => return None,
    })
}

#[no_mangle]
pub extern "C" fn tecsNoiseCreate(
    seed: i32,
    algorithm_value: u8,
    fractal_value: u8,
    frequency: f32,
    octaves: i32,
    lacunarity: f32,
    gain: f32,
    weighted_strength: f32,
    ping_pong_strength: f32,
) -> *mut TecsNoise {
    let Some(algorithm) = algorithm(algorithm_value) else {
        return ptr::null_mut();
    };
    let Some(fractal) = fractal(fractal_value) else {
        return ptr::null_mut();
    };
    if !frequency.is_finite()
        || !(1..=32).contains(&octaves)
        || !lacunarity.is_finite()
        || !gain.is_finite()
        || !(0.0..=1.0).contains(&weighted_strength)
        || !ping_pong_strength.is_finite()
    {
        return ptr::null_mut();
    }

    let mut field = FastNoiseLite::with_seed(seed);
    field.set_noise_type(Some(algorithm));
    field.set_fractal_type(Some(fractal));
    field.set_frequency(Some(frequency));
    field.set_fractal_octaves(Some(octaves));
    field.set_fractal_lacunarity(Some(lacunarity));
    field.set_fractal_gain(Some(gain));
    field.set_fractal_weighted_strength(Some(weighted_strength));
    field.set_fractal_ping_pong_strength(Some(ping_pong_strength));
    Box::into_raw(Box::new(TecsNoise { field }))
}

#[no_mangle]
pub unsafe extern "C" fn tecsNoiseDestroy(noise: *mut TecsNoise) {
    if !noise.is_null() {
        drop(Box::from_raw(noise));
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsNoiseSample2(noise: *const TecsNoise, x: f64, y: f64) -> f32 {
    noise
        .as_ref()
        .map_or(0.0, |noise| noise.field.get_noise_2d(x, y))
}

#[no_mangle]
pub unsafe extern "C" fn tecsNoiseSample3(noise: *const TecsNoise, x: f64, y: f64, z: f64) -> f32 {
    noise
        .as_ref()
        .map_or(0.0, |noise| noise.field.get_noise_3d(x, y, z))
}

#[no_mangle]
pub unsafe extern "C" fn tecsNoiseFill2(
    noise: *const TecsNoise,
    output: *mut f32,
    width: usize,
    height: usize,
    origin_x: f64,
    origin_y: f64,
    step_x: f64,
    step_y: f64,
) -> bool {
    let Some(noise) = noise.as_ref() else {
        return false;
    };
    let Some(length) = width.checked_mul(height) else {
        return false;
    };
    if length == 0 {
        return true;
    }
    if output.is_null() {
        return false;
    }

    let values = slice::from_raw_parts_mut(output, length);
    for row in 0..height {
        let y = origin_y + row as f64 * step_y;
        for column in 0..width {
            let x = origin_x + column as f64 * step_x;
            values[row * width + column] = noise.field.get_noise_2d(x, y);
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn samples_and_fills_the_same_field() {
        let noise = tecsNoiseCreate(42, 0, 1, 0.03, 4, 2.0, 0.5, 0.0, 2.0);
        assert!(!noise.is_null());

        let expected = unsafe { tecsNoiseSample2(noise, 3.0, 5.0) };
        let mut values = [0.0; 4];
        assert!(unsafe { tecsNoiseFill2(noise, values.as_mut_ptr(), 2, 2, 3.0, 5.0, 1.0, 1.0) });
        assert_eq!(expected, values[0]);
        assert!(values.iter().all(|value| (-1.0..=1.0).contains(value)));

        unsafe { tecsNoiseDestroy(noise) };
    }

    #[test]
    fn rejects_invalid_configuration_values() {
        assert!(tecsNoiseCreate(0, 6, 0, 1.0, 1, 2.0, 0.5, 0.0, 2.0).is_null());
        assert!(tecsNoiseCreate(0, 0, 4, 1.0, 1, 2.0, 0.5, 0.0, 2.0).is_null());
        assert!(tecsNoiseCreate(0, 0, 0, f32::NAN, 1, 2.0, 0.5, 0.0, 2.0).is_null());
        assert!(tecsNoiseCreate(0, 0, 0, 1.0, 0, 2.0, 0.5, 0.0, 2.0).is_null());
        assert!(tecsNoiseCreate(0, 0, 0, 1.0, 1, 2.0, 0.5, 1.1, 2.0).is_null());
    }

    #[test]
    fn reproduces_reference_values() {
        let noise = tecsNoiseCreate(777, 0, 0, 1.0, 3, 2.0, 0.5, 0.0, 2.0);
        let actual = unsafe {
            [
                tecsNoiseSample2(noise, 0.5, 0.5),
                tecsNoiseSample2(noise, 1.25, -3.75),
                tecsNoiseSample2(noise, 12.125, 7.875),
                tecsNoiseSample3(noise, 0.5, 0.5, 0.5),
            ]
        };
        let expected = [0.19981878, 0.39056084, 0.20810865, -0.24123035];
        assert!(actual
            .iter()
            .zip(expected)
            .all(|(actual, expected)| (actual - expected).abs() < 1e-6));
        unsafe { tecsNoiseDestroy(noise) };
    }
}
