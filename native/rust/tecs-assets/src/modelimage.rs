//! Upload-ready images, preserving the original SVG and BC3 KTX2 contracts.
use resvg::tiny_skia::{Pixmap, Transform};
use resvg::usvg::{fontdb, ImageHrefResolver, Options, Tree};
use std::sync::Arc;
pub struct TecsImage {
    pub pixels: Box<[u8]>,
    pub width: u32,
    pub height: u32,
    pub storage_width: u32,
    pub storage_height: u32,
    pub levels: u32,
    pub format: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TecsImageInfo {
    pub pixels: *const u8,
    pub byte_count: usize,
    pub width: u32,
    pub height: u32,
    pub storage_width: u32,
    pub storage_height: u32,
    pub levels: u32,
    pub format: u32,
}

const IMAGE_RGBA8: u32 = 0;
const IMAGE_BC3: u32 = 1;
const ORIGINAL_SIZE_KEY: &str = "TECSoriginalSize";

impl TecsImage {
    pub fn info(&self) -> TecsImageInfo {
        TecsImageInfo {
            pixels: self.pixels.as_ptr(),
            byte_count: self.pixels.len(),
            width: self.width,
            height: self.height,
            storage_width: self.storage_width,
            storage_height: self.storage_height,
            levels: self.levels,
            format: self.format,
        }
    }
}

fn decode_raster(bytes: &[u8]) -> Result<TecsImage, image::ImageError> {
    let image = image::load_from_memory(bytes)?.into_rgba8();
    let (width, height) = image.dimensions();
    Ok(TecsImage {
        pixels: image.into_raw().into_boxed_slice(),
        width,
        height,
        storage_width: width,
        storage_height: height,
        levels: 1,
        format: IMAGE_RGBA8,
    })
}

fn decode_svg(bytes: &[u8]) -> Result<TecsImage, String> {
    // SVG output must not change with the fonts installed on the machine
    // running the game. Tecs already ships this face for its own text, so it
    // is the complete SVG font database rather than one fallback among system
    // fonts.
    let mut fonts = fontdb::Database::new();
    fonts.load_font_data(
        include_bytes!("../../../../assets/fonts/JetBrainsMono-ExtraBold.ttf").to_vec(),
    );
    // External image references bypass the storage seam, make a load depend on
    // the worker's current directory, and leave file watching unaware of the
    // dependency. The custom resolver therefore permits inline SVG data only.
    let options = Options {
        font_family: "JetBrains Mono".to_owned(),
        style_sheet: Some("text { font-family: 'JetBrains Mono' !important; }".to_owned()),
        fontdb: Arc::new(fonts),
        image_href_resolver: ImageHrefResolver {
            resolve_data: ImageHrefResolver::default_data_resolver(),
            resolve_string: Box::new(|_, _| None),
        },
        ..Options::default()
    };
    let tree = Tree::from_data(bytes, &options).map_err(|error| error.to_string())?;
    let size = tree.size().to_int_size();
    let mut pixmap = Pixmap::new(size.width(), size.height())
        .ok_or_else(|| "SVG dimensions are too large".to_owned())?;
    resvg::render(&tree, Transform::identity(), &mut pixmap.as_mut());

    // tiny-skia renders premultiplied RGBA. Tecs' image ABI is straight RGBA,
    // and its forward shader premultiplies at composition time, so passing
    // these bytes through would darken every translucent edge twice.
    let mut pixels = Vec::with_capacity(pixmap.data().len());
    for pixel in pixmap.pixels() {
        let straight = pixel.demultiply();
        pixels.extend_from_slice(&[
            straight.red(),
            straight.green(),
            straight.blue(),
            straight.alpha(),
        ]);
    }

    Ok(TecsImage {
        pixels: pixels.into_boxed_slice(),
        width: size.width(),
        height: size.height(),
        storage_width: size.width(),
        storage_height: size.height(),
        levels: 1,
        format: IMAGE_RGBA8,
    })
}

fn decode_ktx2(bytes: &[u8]) -> Result<TecsImage, String> {
    let reader =
        ktx2::Reader::new(bytes).map_err(|error| format!("invalid KTX2 texture: {error}"))?;
    let header = reader.header();
    if header.format != Some(ktx2::Format::BC3_UNORM_BLOCK) {
        return Err("KTX2 texture is not linear BC3".to_owned());
    }
    if header.pixel_depth != 0 || header.layer_count != 0 || header.face_count != 1 {
        return Err("KTX2 texture must contain one two-dimensional image".to_owned());
    }
    if header.supercompression_scheme.is_some() {
        return Err("KTX2 supercompression is not supported".to_owned());
    }
    if reader.transfer_function() != Some(ktx2::TransferFunction::Linear) {
        return Err("KTX2 BC3 texture must use a linear transfer function".to_owned());
    }
    if reader.is_alpha_premultiplied() != Some(false) {
        return Err("KTX2 BC3 texture must use straight alpha".to_owned());
    }
    let storage_width = header.pixel_width;
    let storage_height = header.pixel_height;
    if storage_width == 0 || storage_height == 0 {
        return Err("KTX2 texture dimensions must be greater than zero".to_owned());
    }
    let expected_levels = storage_width.max(storage_height).ilog2() + 1;
    if header.level_count != expected_levels {
        return Err(format!(
            "KTX2 BC3 texture has {} mip levels, expected {expected_levels}",
            header.level_count
        ));
    }
    let mut width = storage_width;
    let mut height = storage_height;
    if let Some((_, value)) = reader
        .key_value_data()
        .find(|(key, _)| *key == ORIGINAL_SIZE_KEY)
    {
        if value.len() != 8 {
            return Err("KTX2 original-size metadata must contain two integers".to_owned());
        }
        width = u32::from_le_bytes(value[0..4].try_into().unwrap());
        height = u32::from_le_bytes(value[4..8].try_into().unwrap());
    }
    if width == 0 || height == 0 || width > storage_width || height > storage_height {
        return Err("KTX2 original dimensions are outside its storage image".to_owned());
    }

    let mut pixels = Vec::new();
    for (index, level) in reader.levels().enumerate() {
        let level_width = (storage_width >> index).max(1);
        let level_height = (storage_height >> index).max(1);
        let expected = (level_width.div_ceil(4) as usize)
            .checked_mul(level_height.div_ceil(4) as usize)
            .and_then(|blocks| blocks.checked_mul(16))
            .ok_or_else(|| "KTX2 BC3 mip chain is too large".to_owned())?;
        if level.data.len() != expected || level.uncompressed_byte_length != expected as u64 {
            return Err(format!(
                "KTX2 BC3 mip {index} has {} bytes, expected {expected}",
                level.data.len()
            ));
        }
        pixels.extend_from_slice(level.data);
    }
    Ok(TecsImage {
        pixels: pixels.into_boxed_slice(),
        width,
        height,
        storage_width,
        storage_height,
        levels: header.level_count,
        format: IMAGE_BC3,
    })
}

pub fn decode(bytes: &[u8]) -> Result<TecsImage, String> {
    if bytes.starts_with(&ktx2::MAGIC) {
        return decode_ktx2(bytes);
    }
    match decode_raster(bytes) {
        Ok(image) => Ok(image),
        Err(raster_error) => decode_svg(bytes).map_err(|svg_error| {
            format!("unsupported image: raster decoder: {raster_error}; SVG decoder: {svg_error}")
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::codecs::jpeg::JpegEncoder;
    use image::{ExtendedColorType, ImageEncoder};
    #[test]
    fn jpeg_decodes_to_owned_rgba_pixels() {
        let mut encoded = Vec::new();
        JpegEncoder::new_with_quality(&mut encoded, 100)
            .write_image(&[240, 20, 10, 240, 20, 10], 2, 1, ExtendedColorType::Rgb8)
            .unwrap();

        let decoded = decode(&encoded).unwrap();
        assert_eq!((decoded.width, decoded.height), (2, 1));
        for pixel in decoded.pixels.as_chunks::<4>().0 {
            assert!(pixel[0] > 200);
            assert!(pixel[1] < 60);
            assert!(pixel[2] < 50);
            assert_eq!(pixel[3], 255);
        }
    }

    #[test]
    fn svg_decodes_at_its_intrinsic_size_to_straight_rgba() {
        let decoded = decode_svg(
            br##"<svg xmlns="http://www.w3.org/2000/svg" width="2" height="1">
                <rect width="1" height="1" fill="#ff0000" fill-opacity="0.5"/>
                <rect x="1" width="1" height="1" fill="#00ff00"/>
            </svg>"##,
        )
        .unwrap();

        assert_eq!((decoded.width, decoded.height), (2, 1));
        assert_eq!(decoded.pixels[0], 255);
        assert_eq!(decoded.pixels[1], 0);
        assert_eq!(decoded.pixels[2], 0);
        assert!((127..=128).contains(&decoded.pixels[3]));
        assert_eq!(&decoded.pixels[4..], &[0, 255, 0, 255]);
    }

    #[test]
    fn svg_text_uses_the_bundled_font() {
        let decoded = decode_svg(
            br##"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16">
                <text x="0" y="13" font-family="not-installed" font-size="14">T</text>
            </svg>"##,
        )
        .unwrap();

        assert!(
            decoded
                .pixels
                .as_chunks::<4>()
                .0
                .iter()
                .any(|pixel| pixel[3] != 0),
            "the bundled fallback font did not render SVG text"
        );
    }
    #[test]
    fn bc3_preserves_logical_dimensions_and_all_compressed_mips() {
        let bytes = include_bytes!("../../../../tests/assets/textures/solid-red.ktx2");
        let value = decode(bytes).unwrap();
        assert_eq!((value.width, value.height), (3, 2));
        assert_eq!((value.storage_width, value.storage_height), (4, 4));
        assert_eq!(
            (value.format, value.levels, value.pixels.len()),
            (IMAGE_BC3, 3, 48)
        );
        assert!(decode(&bytes[..bytes.len() - 1]).is_err());
        let mut wrong_format = bytes.to_vec();
        wrong_format[12..16].copy_from_slice(&0_u32.to_le_bytes());
        assert!(decode(&wrong_format).is_err());
    }
}
