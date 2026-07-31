//! Root of the Rust runtime and its shared image, byte-buffer, and error ABI.
//!
//! The crate collects the host services behind generated FFI tables. Teal
//! reaches the image codec through `tecs.assets`, `tecs.platform.window`, and
//! `tecs.gfx.screenshot`; the other services live in their modules below.

use std::cell::RefCell;
use std::ffi::{c_char, CString};
use std::ptr;
use std::slice;
use std::sync::Arc;

use image::codecs::png::PngEncoder;
use image::ImageEncoder;
use resvg::tiny_skia::{Pixmap, Transform};
use resvg::usvg::{fontdb, ImageHrefResolver, Options, Tree};

mod cache;
mod cli;
mod cli_docs;
mod cli_mcp;
mod dialogs;
mod host;
mod http;
mod logsink;
mod luamods;
mod mcodearena;
mod mcp;
mod net;
#[cfg(feature = "payload")]
mod payload;
mod physics;
mod regex;
mod registry;
mod sha256;
mod ui;
mod uuid;
mod window;
mod worker;

thread_local! {
    static LAST_ERROR: RefCell<CString> =
        RefCell::new(CString::new("no error").expect("static string has no NUL"));
}

/// An owned, tightly packed RGBA8 image.
///
/// This is opaque across the C ABI. Its pixel pointer remains valid until
/// `tecsImageDestroy` releases the image.
pub struct TecsImage {
    pixels: Box<[u8]>,
    width: u32,
    height: u32,
}

/// An owned byte buffer returned across the C ABI.
///
/// Like `TecsImage`, this is opaque so Rust remains responsible for releasing
/// the allocation it created.
pub struct TecsBytes {
    bytes: Box<[u8]>,
}

fn set_error(error: impl ToString) {
    let message = error.to_string().replace('\0', "\\0");
    LAST_ERROR.with(|slot| {
        *slot.borrow_mut() = CString::new(message).expect("interior NUL bytes were replaced");
    });
}

fn decode_raster(bytes: &[u8]) -> Result<TecsImage, image::ImageError> {
    let image = image::load_from_memory(bytes)?.into_rgba8();
    let (width, height) = image.dimensions();
    Ok(TecsImage {
        pixels: image.into_raw().into_boxed_slice(),
        width,
        height,
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
    })
}

fn decode(bytes: &[u8]) -> Result<TecsImage, String> {
    match decode_raster(bytes) {
        Ok(image) => Ok(image),
        Err(raster_error) => decode_svg(bytes).map_err(|svg_error| {
            format!("unsupported image: raster decoder: {raster_error}; SVG decoder: {svg_error}")
        }),
    }
}

fn encode_png_rgbx(
    pixels: &[u8],
    width: u32,
    height: u32,
    pitch: usize,
) -> Result<TecsBytes, String> {
    let row_bytes = (width as usize)
        .checked_mul(4)
        .ok_or_else(|| "image row is too large".to_owned())?;
    if pitch < row_bytes {
        return Err("image pitch is smaller than its pixel row".to_owned());
    }
    let required = pitch
        .checked_mul(height as usize)
        .ok_or_else(|| "image buffer is too large".to_owned())?;
    if pixels.len() < required {
        return Err("image buffer is shorter than its dimensions".to_owned());
    }

    let packed_len = row_bytes
        .checked_mul(height as usize)
        .ok_or_else(|| "image buffer is too large".to_owned())?;
    let mut packed = Vec::with_capacity(packed_len);
    for row in 0..height as usize {
        let start = row * pitch;
        let packed_start = packed.len();
        packed.extend_from_slice(&pixels[start..start + row_bytes]);
        for alpha in packed[packed_start + 3..].iter_mut().step_by(4) {
            *alpha = 255;
        }
    }

    let mut encoded = Vec::new();
    PngEncoder::new(&mut encoded)
        .write_image(&packed, width, height, image::ExtendedColorType::Rgba8)
        .map_err(|error| error.to_string())?;
    Ok(TecsBytes {
        bytes: encoded.into_boxed_slice(),
    })
}

/// Returns the last error raised on the calling thread.
///
/// The pointer remains valid until another Tecs Rust API call fails on this
/// thread. Callers must copy it when they need it longer.
#[no_mangle]
pub extern "C" fn tecsRustError() -> *const c_char {
    LAST_ERROR.with(|slot| slot.borrow().as_ptr())
}

/// Builds the help text for the Rust command schema.
///
/// The returned allocation belongs to Rust and must be released with
/// `tecsBytesDestroy`.
#[no_mangle]
pub extern "C" fn tecsCliHelp() -> *mut TecsBytes {
    Box::into_raw(Box::new(TecsBytes {
        bytes: cli::help().into_boxed_slice(),
    }))
}

/// Decodes PNG, JPEG, or static SVG bytes into tightly packed RGBA8 pixels.
///
/// Returns null on malformed input or allocation/size failure and records the
/// reason in `tecsRustError`.
///
/// # Safety
///
/// When `length` is nonzero, `bytes` must address at least that many readable
/// bytes for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn tecsImageDecode(bytes: *const u8, length: usize) -> *mut TecsImage {
    if bytes.is_null() && length != 0 {
        set_error("image input is null");
        return ptr::null_mut();
    }
    let input = if length == 0 {
        &[]
    } else {
        // SAFETY: The caller promises `length` readable bytes for this call.
        unsafe { slice::from_raw_parts(bytes, length) }
    };
    match decode(input) {
        Ok(image) => Box::into_raw(Box::new(image)),
        Err(error) => {
            set_error(error);
            ptr::null_mut()
        }
    }
}

/// Borrows an image's pixel allocation.
///
/// # Safety
///
/// `image` must be null or a live pointer returned by `tecsImageDecode`.
#[no_mangle]
pub unsafe extern "C" fn tecsImagePixels(image: *const TecsImage) -> *const u8 {
    if image.is_null() {
        return ptr::null();
    }
    // SAFETY: A non-null pointer must have come from `tecsImageDecode` and
    // remain owned by the caller.
    let image = unsafe { &*image };
    image.pixels.as_ptr()
}

/// Returns an image's width.
///
/// # Safety
///
/// `image` must be null or a live pointer returned by `tecsImageDecode`.
#[no_mangle]
pub unsafe extern "C" fn tecsImageWidth(image: *const TecsImage) -> u32 {
    if image.is_null() {
        return 0;
    }
    // SAFETY: See `tecsImagePixels`.
    let image = unsafe { &*image };
    image.width
}

/// Returns an image's height.
///
/// # Safety
///
/// `image` must be null or a live pointer returned by `tecsImageDecode`.
#[no_mangle]
pub unsafe extern "C" fn tecsImageHeight(image: *const TecsImage) -> u32 {
    if image.is_null() {
        return 0;
    }
    // SAFETY: See `tecsImagePixels`.
    let image = unsafe { &*image };
    image.height
}

/// Releases an image and its pixels.
///
/// # Safety
///
/// `image` must be null or an owned pointer returned by `tecsImageDecode`.
/// A non-null pointer may be destroyed exactly once.
#[no_mangle]
pub unsafe extern "C" fn tecsImageDestroy(image: *mut TecsImage) {
    if !image.is_null() {
        // SAFETY: Ownership crosses this boundary once and the caller must not
        // use or destroy the pointer again.
        drop(unsafe { Box::from_raw(image) });
    }
}

/// Encodes RGBX/RGBA bytes as a PNG, forcing every output alpha byte opaque.
///
/// # Safety
///
/// When `length` is nonzero, `pixels` must address at least that many readable
/// bytes for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn tecsImageEncodePngRgbx(
    pixels: *const u8,
    length: usize,
    width: u32,
    height: u32,
    pitch: usize,
) -> *mut TecsBytes {
    if pixels.is_null() && length != 0 {
        set_error("image input is null");
        return ptr::null_mut();
    }
    let input = if length == 0 {
        &[]
    } else {
        // SAFETY: The caller promises `length` readable bytes for this call.
        unsafe { slice::from_raw_parts(pixels, length) }
    };
    match encode_png_rgbx(input, width, height, pitch) {
        Ok(bytes) => Box::into_raw(Box::new(bytes)),
        Err(error) => {
            set_error(error);
            ptr::null_mut()
        }
    }
}

/// Borrows an encoded byte allocation.
///
/// # Safety
///
/// `bytes` must be null or a live pointer returned by a Tecs Rust API.
#[no_mangle]
pub unsafe extern "C" fn tecsBytesData(bytes: *const TecsBytes) -> *const u8 {
    if bytes.is_null() {
        return ptr::null();
    }
    // SAFETY: A non-null pointer must have come from a Tecs Rust API and
    // remain owned by the caller.
    let bytes = unsafe { &*bytes };
    bytes.bytes.as_ptr()
}

/// Returns the length of an encoded byte allocation.
///
/// # Safety
///
/// `bytes` must be null or a live pointer returned by a Tecs Rust API.
#[no_mangle]
pub unsafe extern "C" fn tecsBytesLength(bytes: *const TecsBytes) -> usize {
    if bytes.is_null() {
        return 0;
    }
    // SAFETY: See `tecsBytesData`.
    let bytes = unsafe { &*bytes };
    bytes.bytes.len()
}

/// Releases an encoded byte allocation.
///
/// # Safety
///
/// `bytes` must be null or an owned pointer returned by a Tecs Rust API. A
/// non-null pointer may be destroyed exactly once.
#[no_mangle]
pub unsafe extern "C" fn tecsBytesDestroy(bytes: *mut TecsBytes) {
    if !bytes.is_null() {
        // SAFETY: Ownership crosses this boundary once and the caller must not
        // use or destroy the pointer again.
        drop(unsafe { Box::from_raw(bytes) });
    }
}

#[cfg(test)]
mod tests {
    use image::codecs::jpeg::JpegEncoder;
    use image::{ExtendedColorType, ImageEncoder};

    use super::{decode, decode_svg, encode_png_rgbx};

    #[test]
    fn png_round_trip_is_rgba_and_opaque() {
        let input = [10, 20, 30, 0, 40, 50, 60, 128];
        let encoded = encode_png_rgbx(&input, 2, 1, 8).unwrap();
        let decoded = decode(&encoded.bytes).unwrap();
        assert_eq!(decoded.width, 2);
        assert_eq!(decoded.height, 1);
        assert_eq!(&*decoded.pixels, &[10, 20, 30, 255, 40, 50, 60, 255]);
    }

    #[test]
    fn encoder_honors_padded_pitch() {
        let input = [1, 2, 3, 4, 99, 99, 99, 99, 5, 6, 7, 8, 99, 99, 99, 99];
        let encoded = encode_png_rgbx(&input, 1, 2, 8).unwrap();
        let decoded = decode(&encoded.bytes).unwrap();
        assert_eq!(&*decoded.pixels, &[1, 2, 3, 255, 5, 6, 7, 255]);
    }

    #[test]
    fn jpeg_decodes_to_owned_rgba_pixels() {
        let mut encoded = Vec::new();
        JpegEncoder::new_with_quality(&mut encoded, 100)
            .write_image(&[240, 20, 10, 240, 20, 10], 2, 1, ExtendedColorType::Rgb8)
            .unwrap();

        let decoded = decode(&encoded).unwrap();
        assert_eq!((decoded.width, decoded.height), (2, 1));
        for pixel in decoded.pixels.chunks_exact(4) {
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
            decoded.pixels.chunks_exact(4).any(|pixel| pixel[3] != 0),
            "the bundled fallback font did not render SVG text"
        );
    }
}
