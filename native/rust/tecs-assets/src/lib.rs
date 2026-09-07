//! File-format decoding for the Tecs asset boundary.
mod maps;
pub mod model;
mod modelimage;
use std::{
    cell::RefCell,
    ffi::{c_char, CString},
    path::Path,
    slice,
};
thread_local! { static ERROR: RefCell<CString> = RefCell::new(CString::new("").unwrap()); }
fn set_error(message: impl ToString) {
    ERROR.with(|e| *e.borrow_mut() = CString::new(message.to_string().replace('\0', " ")).unwrap());
}
fn fail(message: impl ToString) -> *mut AssetResult {
    set_error(message);
    std::ptr::null_mut()
}
pub struct AssetResult {
    data: Vec<u8>,
    width: u32,
    height: u32,
}
/// Returns the last failure on this thread.
#[no_mangle]
pub extern "C" fn tecsAssetError() -> *const c_char {
    ERROR.with(|e| e.borrow().as_ptr())
}
/// Reads a TMX map (kind 0) or decodes an image to RGBA8 (kind 1).
/// # Safety
/// `path` must name `length` readable UTF-8 bytes.
#[no_mangle]
pub unsafe extern "C" fn tecsAssetLoad(
    path: *const u8,
    length: u64,
    kind: u32,
    transparent: u32,
) -> *mut AssetResult {
    if path.is_null() {
        return fail("null asset path");
    }
    let path = match std::str::from_utf8(unsafe { slice::from_raw_parts(path, length as usize) }) {
        Ok(p) => Path::new(p),
        Err(e) => return fail(e),
    };
    let result = match kind {
        0 => maps::load(path).map(|data| AssetResult {
            data,
            width: 0,
            height: 0,
        }),
        1 => std::fs::read(path)
            .map_err(|e| e.to_string())
            .and_then(|bytes| modelimage::decode(&bytes))
            .and_then(|image| {
                if image.format != 0 {
                    return Err("this image consumer requires RGBA8, not compressed BC3".to_owned());
                }
                let mut data = image.pixels.into_vec();
                if transparent & 0x1000000 != 0 {
                    for pixel in data.as_chunks_mut::<4>().0 {
                        if u32::from(pixel[0]) == (transparent >> 16) & 255
                            && u32::from(pixel[1]) == (transparent >> 8) & 255
                            && u32::from(pixel[2]) == transparent & 255
                        {
                            pixel[3] = 0;
                        }
                    }
                }
                Ok(AssetResult {
                    width: image.width,
                    height: image.height,
                    data,
                })
            }),
        2 => model::load_packet(path).map(|data| AssetResult {
            data,
            width: 0,
            height: 0,
        }),
        _ => Err("unknown asset kind".into()),
    };
    match result {
        Ok(value) => Box::into_raw(Box::new(value)),
        Err(e) => fail(e),
    }
}
/// Returns bytes retained by a live result.
/// # Safety
/// `result` must point to a live result.
#[no_mangle]
pub unsafe extern "C" fn tecsAssetData(result: *const AssetResult) -> *const u8 {
    unsafe { (*result).data.as_ptr() }
}
/// Returns the byte count of a live result.
/// # Safety
/// `result` must point to a live result.
#[no_mangle]
pub unsafe extern "C" fn tecsAssetLength(result: *const AssetResult) -> u64 {
    unsafe { (*result).data.len() as u64 }
}
/// Returns the image width, or zero for map data.
/// # Safety
/// `result` must point to a live result.
#[no_mangle]
pub unsafe extern "C" fn tecsAssetWidth(result: *const AssetResult) -> u32 {
    unsafe { (*result).width }
}
/// Returns the image height, or zero for map data.
/// # Safety
/// `result` must point to a live result.
#[no_mangle]
pub unsafe extern "C" fn tecsAssetHeight(result: *const AssetResult) -> u32 {
    unsafe { (*result).height }
}
/// Releases an owned asset result.
/// # Safety
/// `result` must be null or a live result returned by this library, released once.
#[no_mangle]
pub unsafe extern "C" fn tecsAssetDestroy(result: *mut AssetResult) {
    if !result.is_null() {
        drop(unsafe { Box::from_raw(result) });
    }
}
