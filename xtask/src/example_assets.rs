use std::collections::BTreeSet;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::Command;

use anyhow::{bail, Context, Result};
use image::imageops::FilterType;
use image::{DynamicImage, RgbaImage};
use serde_json::Value;

const SPONZA_REVISION: &str = "2bac6f8c57bf471df0d2a1e8a8ec023c7801dddf";
const SPONZA_MODEL_ROOT: &str = "Models/Sponza";
const SPONZA_TEXTURE_SIZE: u32 = 1024;
const COMPRESSED_MAGIC: &[u8; 8] = b"TECSBC3\0";
const COMPRESSED_VERSION: u32 = 1;

pub fn fetch(root: &Path, name: &str) -> Result<()> {
    match name {
        "sponza" => fetch_sponza(root),
        _ => bail!("unknown example asset {name:?}; expected `sponza`"),
    }
}

pub fn require_for_example(root: &Path, name: &str) -> Result<()> {
    if name == "sponza3d"
        && !root
            .join("assets/external/sponza/Sponza.tecs.gltf")
            .is_file()
    {
        bail!(
            "the sponza3d example needs its ignored scene cache; run `cargo xtask fetch sponza` first"
        );
    }
    Ok(())
}

fn fetch_sponza(root: &Path) -> Result<()> {
    let destination = root.join("assets/external/sponza");
    fs::create_dir_all(&destination)
        .with_context(|| format!("creating {}", destination.display()))?;

    let base = format!(
        "https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/{SPONZA_REVISION}/{SPONZA_MODEL_ROOT}"
    );
    download(&format!("{base}/README.md"), &destination.join("NOTICE.md"))?;
    let model = destination.join("Sponza.gltf");
    download(&format!("{base}/glTF/Sponza.gltf"), &model)?;

    let mut document: Value = serde_json::from_slice(
        &fs::read(&model).with_context(|| format!("reading {}", model.display()))?,
    )
    .with_context(|| format!("parsing {}", model.display()))?;
    let mut files = BTreeSet::new();
    collect_uris(&document, "buffers", &mut files)?;
    collect_uris(&document, "images", &mut files)?;
    for relative in files {
        let relative = safe_relative(&relative)?;
        let source = format!("{base}/glTF/{}", relative.to_string_lossy());
        download(&source, &destination.join(relative))?;
    }

    let (compressed_bytes, source_bytes) = preprocess_textures(&destination, &mut document)?;
    let derived = destination.join("Sponza.tecs.gltf");
    fs::write(&derived, serde_json::to_vec_pretty(&document)?)
        .with_context(|| format!("writing {}", derived.display()))?;
    let chunks = primitive_count(&document);

    fs::write(
        destination.join("SOURCE"),
        format!(
            "KhronosGroup/glTF-Sample-Assets\nrevision={SPONZA_REVISION}\npath={SPONZA_MODEL_ROOT}/glTF\nderived=Sponza.tecs.gltf\ntexture_format=BC3\ntexture_size={SPONZA_TEXTURE_SIZE}\ncull_chunks={chunks}\n"
        ),
    )?;
    println!(
        "fetched and imported Sponza into {} ({chunks} culling chunks, {:.1} MiB source textures, {:.1} MiB BC3 mip chains)",
        destination.display(),
        source_bytes as f64 / 1_048_576.0,
        compressed_bytes as f64 / 1_048_576.0
    );
    Ok(())
}

fn primitive_count(document: &Value) -> usize {
    document
        .get("meshes")
        .and_then(Value::as_array)
        .map(|meshes| {
            meshes
                .iter()
                .filter_map(|mesh| mesh.get("primitives").and_then(Value::as_array))
                .map(Vec::len)
                .sum()
        })
        .unwrap_or(0)
}

fn preprocess_textures(destination: &Path, document: &mut Value) -> Result<(u64, u64)> {
    let Some(images) = document.get_mut("images").and_then(Value::as_array_mut) else {
        return Ok((0, 0));
    };
    let compressed_root = destination.join("compressed");
    fs::create_dir_all(&compressed_root)
        .with_context(|| format!("creating {}", compressed_root.display()))?;
    let mut compressed_bytes = 0;
    let mut source_bytes = 0;
    for (index, image) in images.iter_mut().enumerate() {
        let uri = image
            .get("uri")
            .and_then(Value::as_str)
            .with_context(|| format!("Sponza image {index} has no external URI"))?;
        let source = destination.join(safe_relative(uri)?);
        let bytes = fs::read(&source).with_context(|| format!("reading {}", source.display()))?;
        source_bytes += bytes.len() as u64;
        let relative = format!("compressed/image-{index:03}.tbc");
        let target = destination.join(&relative);
        let cached = fs::read(&target).ok();
        if cached
            .as_deref()
            .is_some_and(|bytes| valid_cached_texture(bytes, SPONZA_TEXTURE_SIZE))
        {
            compressed_bytes += cached.as_ref().map(Vec::len).unwrap_or(0) as u64;
        } else {
            let decoded = image::load_from_memory(&bytes)
                .with_context(|| format!("decoding {}", source.display()))?;
            let encoded = encode_bc3_texture(&decoded, SPONZA_TEXTURE_SIZE, SPONZA_TEXTURE_SIZE)?;
            compressed_bytes += encoded.len() as u64;
            fs::write(&target, encoded).with_context(|| format!("writing {}", target.display()))?;
        }
        image["uri"] = Value::String(relative);
        image["mimeType"] = Value::String("application/x-tecs-bc3".to_owned());
    }
    Ok((compressed_bytes, source_bytes))
}

fn valid_cached_texture(bytes: &[u8], storage_size: u32) -> bool {
    if bytes.len() < 36 || &bytes[..8] != COMPRESSED_MAGIC {
        return false;
    }
    let value = |offset: usize| u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap());
    value(8) == COMPRESSED_VERSION
        && value(20) == storage_size
        && value(24) == storage_size
        && value(32) as usize == bytes.len() - 36
}

fn encode_bc3_texture(
    image: &DynamicImage,
    storage_width: u32,
    storage_height: u32,
) -> Result<Vec<u8>> {
    let source = image.to_rgba8();
    let width = source.width();
    let height = source.height();
    if width == 0 || height == 0 || width > storage_width || height > storage_height {
        bail!(
            "cannot fit decoded texture {width}x{height} in {storage_width}x{storage_height} mesh cell"
        );
    }
    let mut level = RgbaImage::from_fn(storage_width, storage_height, |x, y| {
        *source.get_pixel(x.min(width - 1), y.min(height - 1))
    });
    let levels = storage_width.max(storage_height).ilog2() + 1;
    let mut payload = Vec::new();
    for level_index in 0..levels {
        encode_bc3_level(&level, &mut payload);
        if level_index + 1 < levels {
            level = image::imageops::resize(
                &level,
                (level.width() / 2).max(1),
                (level.height() / 2).max(1),
                FilterType::Triangle,
            );
        }
    }
    let mut output = Vec::with_capacity(36 + payload.len());
    output.extend_from_slice(COMPRESSED_MAGIC);
    for value in [
        COMPRESSED_VERSION,
        width,
        height,
        storage_width,
        storage_height,
        levels,
        payload.len() as u32,
    ] {
        output.extend_from_slice(&value.to_le_bytes());
    }
    output.extend_from_slice(&payload);
    Ok(output)
}

fn encode_bc3_level(image: &RgbaImage, output: &mut Vec<u8>) {
    for block_y in (0..image.height()).step_by(4) {
        for block_x in (0..image.width()).step_by(4) {
            let mut pixels = [[0_u8; 4]; 16];
            for y in 0..4 {
                for x in 0..4 {
                    pixels[y * 4 + x] = image
                        .get_pixel(
                            (block_x + x as u32).min(image.width() - 1),
                            (block_y + y as u32).min(image.height() - 1),
                        )
                        .0;
                }
            }
            encode_bc3_block(&pixels, output);
        }
    }
}

fn encode_bc3_block(pixels: &[[u8; 4]; 16], output: &mut Vec<u8>) {
    let alpha_max = pixels.iter().map(|pixel| pixel[3]).max().unwrap_or(255);
    let alpha_min = pixels.iter().map(|pixel| pixel[3]).min().unwrap_or(255);
    output.push(alpha_max);
    output.push(alpha_min);
    let alpha_palette = alpha_palette(alpha_max, alpha_min);
    let mut alpha_bits = 0_u64;
    for (index, pixel) in pixels.iter().enumerate() {
        let selected = nearest_alpha(pixel[3], &alpha_palette);
        alpha_bits |= (selected as u64) << (index * 3);
    }
    output.extend_from_slice(&alpha_bits.to_le_bytes()[..6]);

    let mut low = [255_u8; 3];
    let mut high = [0_u8; 3];
    for pixel in pixels {
        for channel in 0..3 {
            low[channel] = low[channel].min(pixel[channel]);
            high[channel] = high[channel].max(pixel[channel]);
        }
    }
    let mut color0 = rgb565(high);
    let mut color1 = rgb565(low);
    if color0 <= color1 {
        if color1 > 0 {
            color0 = color1;
            color1 -= 1;
        } else {
            color0 = 1;
        }
    }
    output.extend_from_slice(&color0.to_le_bytes());
    output.extend_from_slice(&color1.to_le_bytes());
    let colors = color_palette(color0, color1);
    let mut color_bits = 0_u32;
    for (index, pixel) in pixels.iter().enumerate() {
        let selected = nearest_color(pixel, &colors);
        color_bits |= (selected as u32) << (index * 2);
    }
    output.extend_from_slice(&color_bits.to_le_bytes());
}

fn alpha_palette(high: u8, low: u8) -> [u8; 8] {
    let mut palette = [0; 8];
    palette[0] = high;
    palette[1] = low;
    if high > low {
        for index in 1..=6 {
            palette[index + 1] =
                (((7 - index) as u16 * high as u16 + index as u16 * low as u16) / 7) as u8;
        }
    } else {
        for index in 1..=4 {
            palette[index + 1] =
                (((5 - index) as u16 * high as u16 + index as u16 * low as u16) / 5) as u8;
        }
        palette[6] = 0;
        palette[7] = 255;
    }
    palette
}

fn nearest_alpha(alpha: u8, palette: &[u8; 8]) -> usize {
    palette
        .iter()
        .enumerate()
        .min_by_key(|(_, candidate)| alpha.abs_diff(**candidate))
        .map(|(index, _)| index)
        .unwrap_or(0)
}

fn rgb565(color: [u8; 3]) -> u16 {
    ((color[0] as u16 >> 3) << 11) | ((color[1] as u16 >> 2) << 5) | (color[2] as u16 >> 3)
}

fn expand565(color: u16) -> [u8; 3] {
    let r = ((color >> 11) & 31) as u8;
    let g = ((color >> 5) & 63) as u8;
    let b = (color & 31) as u8;
    [
        (r << 3) | (r >> 2),
        (g << 2) | (g >> 4),
        (b << 3) | (b >> 2),
    ]
}

fn color_palette(color0: u16, color1: u16) -> [[u8; 3]; 4] {
    let high = expand565(color0);
    let low = expand565(color1);
    [
        high,
        low,
        [
            ((2 * high[0] as u16 + low[0] as u16) / 3) as u8,
            ((2 * high[1] as u16 + low[1] as u16) / 3) as u8,
            ((2 * high[2] as u16 + low[2] as u16) / 3) as u8,
        ],
        [
            ((high[0] as u16 + 2 * low[0] as u16) / 3) as u8,
            ((high[1] as u16 + 2 * low[1] as u16) / 3) as u8,
            ((high[2] as u16 + 2 * low[2] as u16) / 3) as u8,
        ],
    ]
}

fn nearest_color(pixel: &[u8; 4], palette: &[[u8; 3]; 4]) -> usize {
    palette
        .iter()
        .enumerate()
        .min_by_key(|(_, candidate)| {
            let dr = pixel[0] as i32 - candidate[0] as i32;
            let dg = pixel[1] as i32 - candidate[1] as i32;
            let db = pixel[2] as i32 - candidate[2] as i32;
            dr * dr + dg * dg + db * db
        })
        .map(|(index, _)| index)
        .unwrap_or(0)
}

fn collect_uris(document: &Value, key: &str, output: &mut BTreeSet<String>) -> Result<()> {
    let Some(entries) = document.get(key).and_then(Value::as_array) else {
        return Ok(());
    };
    for entry in entries {
        let Some(uri) = entry.get("uri").and_then(Value::as_str) else {
            continue;
        };
        if uri.starts_with("data:") {
            continue;
        }
        output.insert(uri.to_owned());
    }
    Ok(())
}

fn safe_relative(value: &str) -> Result<PathBuf> {
    let path = Path::new(value);
    if path.as_os_str().is_empty()
        || path.is_absolute()
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        bail!("Sponza contains unsafe relative URI {value:?}");
    }
    Ok(path.to_owned())
}

fn download(url: &str, destination: &Path) -> Result<()> {
    if destination.is_file() {
        return Ok(());
    }
    let parent = destination
        .parent()
        .with_context(|| format!("{} has no parent", destination.display()))?;
    fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    let temporary = destination.with_extension(format!(
        "{}.part",
        destination
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("download")
    ));
    let status = Command::new("curl")
        .args(["-fsSL", "--show-error", "--retry", "3", "--output"])
        .arg(&temporary)
        .arg(url)
        .status()
        .with_context(|| format!("starting curl for {url}"))?;
    if !status.success() {
        let _ = fs::remove_file(&temporary);
        bail!("curl failed while fetching {url}");
    }
    fs::rename(&temporary, destination).with_context(|| {
        format!(
            "moving downloaded asset {} to {}",
            temporary.display(),
            destination.display()
        )
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{encode_bc3_texture, require_for_example, safe_relative, valid_cached_texture};
    use image::{DynamicImage, Rgba, RgbaImage};
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn accepts_model_relative_paths() {
        assert_eq!(
            safe_relative("textures/cloth.png").unwrap().to_str(),
            Some("textures/cloth.png")
        );
    }

    #[test]
    fn rejects_paths_outside_the_cache() {
        assert!(safe_relative("../outside.bin").is_err());
        assert!(safe_relative("/outside.bin").is_err());
    }

    #[test]
    fn writes_complete_bc3_mip_chains() {
        let image = DynamicImage::ImageRgba8(RgbaImage::from_pixel(2, 1, Rgba([17, 34, 51, 68])));
        let bytes = encode_bc3_texture(&image, 4, 4).unwrap();
        assert_eq!(&bytes[..8], b"TECSBC3\0");
        assert_eq!(u32::from_le_bytes(bytes[12..16].try_into().unwrap()), 2);
        assert_eq!(u32::from_le_bytes(bytes[28..32].try_into().unwrap()), 3);
        assert_eq!(u32::from_le_bytes(bytes[32..36].try_into().unwrap()), 48);
        assert_eq!(bytes.len(), 84);
        assert!(valid_cached_texture(&bytes, 4));
        let mut truncated = bytes;
        truncated.pop();
        assert!(!valid_cached_texture(&truncated, 4));
    }

    #[test]
    fn requires_the_sponza_cache_before_opening_its_window() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "tecs-sponza-example-{}-{unique}",
            std::process::id()
        ));
        assert!(require_for_example(&root, "sponza3d").is_err());
        assert!(require_for_example(&root, "scene3d").is_ok());

        let scene = root.join("assets/external/sponza/Sponza.tecs.gltf");
        fs::create_dir_all(scene.parent().unwrap()).unwrap();
        fs::write(&scene, b"{}").unwrap();
        assert!(require_for_example(&root, "sponza3d").is_ok());
        fs::remove_dir_all(&root).unwrap();
    }
}
