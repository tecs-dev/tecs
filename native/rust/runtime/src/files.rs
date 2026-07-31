//! Filesystem operations SDL's path API cannot answer.

use std::path::{Path, PathBuf};
use std::slice;

#[cfg(unix)]
use std::ffi::OsStr;
#[cfg(unix)]
use std::os::unix::ffi::OsStrExt;

use super::set_error;

#[cfg(unix)]
fn path_from_bytes(bytes: &[u8]) -> Result<PathBuf, String> {
    Ok(PathBuf::from(OsStr::from_bytes(bytes)))
}

#[cfg(not(unix))]
fn path_from_bytes(bytes: &[u8]) -> Result<PathBuf, String> {
    let path =
        std::str::from_utf8(bytes).map_err(|_| "filesystem path is not valid UTF-8".to_owned())?;
    Ok(PathBuf::from(path))
}

fn is_symlink(path: &Path) -> Result<bool, String> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) => Ok(metadata.file_type().is_symlink()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error.to_string()),
    }
}

/// Returns whether a path itself is a symbolic link.
///
/// Returns 1 for a link, 0 for any other object or an absent path, and -1
/// after recording an operating-system failure in `tecsRustError`.
///
/// # Safety
///
/// When `path_length` is nonzero, `path` must address at least that many
/// readable bytes for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn tecsPathIsSymlink(path: *const u8, path_length: usize) -> i32 {
    if path.is_null() && path_length != 0 {
        set_error("filesystem path is null");
        return -1;
    }
    let bytes = if path_length == 0 {
        &[]
    } else {
        // SAFETY: The caller promises `path_length` readable bytes.
        unsafe { slice::from_raw_parts(path, path_length) }
    };
    match path_from_bytes(bytes).and_then(|path| is_symlink(&path)) {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(error) => {
            set_error(error);
            -1
        }
    }
}
