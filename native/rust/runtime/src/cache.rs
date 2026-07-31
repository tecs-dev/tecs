//! The operating system's disposable cache directory.

use std::env;
#[cfg(target_os = "android")]
use std::ffi::{c_char, CStr};
use std::path::{PathBuf, MAIN_SEPARATOR};
use std::ptr;
use std::slice;

use super::{set_error, TecsBytes};

#[cfg(target_os = "android")]
unsafe extern "C" {
    fn SDL_GetAndroidCachePath() -> *const c_char;
}

fn text(bytes: *const u8, length: usize, name: &str) -> Result<String, String> {
    if bytes.is_null() {
        return Err(format!("{name} is null"));
    }
    // SAFETY: The caller promises `length` readable bytes for this call.
    let bytes = unsafe { slice::from_raw_parts(bytes, length) };
    let value = std::str::from_utf8(bytes).map_err(|_| format!("{name} is not UTF-8"))?;
    if value.is_empty() {
        return Err(format!("{name} is empty"));
    }
    Ok(value.to_owned())
}

fn component(value: &str) -> String {
    let mut clean = String::with_capacity(value.len());
    for character in value.chars() {
        if character.is_control()
            || matches!(
                character,
                '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|'
            )
        {
            clean.push('_');
        } else {
            clean.push(character);
        }
    }
    let trimmed = clean.trim_matches([' ', '.']);
    if trimmed.is_empty() {
        "_".to_owned()
    } else {
        trimmed.to_owned()
    }
}

#[cfg(target_os = "android")]
fn cache_base() -> Result<PathBuf, String> {
    let path = unsafe { SDL_GetAndroidCachePath() };
    if path.is_null() {
        return Err("Android did not provide a cache directory".to_owned());
    }
    let path = unsafe { CStr::from_ptr(path) }
        .to_str()
        .map_err(|_| "Android cache directory is not UTF-8")?;
    Ok(PathBuf::from(path))
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn cache_base() -> Result<PathBuf, String> {
    let home = env::var_os("HOME").ok_or_else(|| "HOME is not available".to_owned())?;
    Ok(PathBuf::from(home).join("Library").join("Caches"))
}

#[cfg(target_os = "windows")]
fn cache_base() -> Result<PathBuf, String> {
    let local =
        env::var_os("LOCALAPPDATA").ok_or_else(|| "LOCALAPPDATA is not available".to_owned())?;
    Ok(PathBuf::from(local))
}

#[cfg(any(
    target_os = "linux",
    target_os = "freebsd",
    target_os = "openbsd",
    target_os = "netbsd",
    target_os = "dragonfly"
))]
fn cache_base() -> Result<PathBuf, String> {
    if let Some(given) = env::var_os("XDG_CACHE_HOME") {
        let path = PathBuf::from(given);
        if path.is_absolute() {
            return Ok(path);
        }
    }
    let home = env::var_os("HOME").ok_or_else(|| "HOME is not available".to_owned())?;
    Ok(PathBuf::from(home).join(".cache"))
}

#[cfg(not(any(
    target_os = "android",
    target_os = "macos",
    target_os = "ios",
    target_os = "windows",
    target_os = "linux",
    target_os = "freebsd",
    target_os = "openbsd",
    target_os = "netbsd",
    target_os = "dragonfly"
)))]
fn cache_base() -> Result<PathBuf, String> {
    Err("this platform has no system cache directory".to_owned())
}

fn resolve(organization: &str, application: &str) -> Result<TecsBytes, String> {
    let path = cache_base()?
        .join(component(organization))
        .join(component(application));
    std::fs::create_dir_all(&path)
        .map_err(|error| format!("cannot create cache directory {}: {error}", path.display()))?;
    let path = path
        .to_str()
        .ok_or_else(|| "cache directory is not valid UTF-8".to_owned())?;
    let mut bytes = path.as_bytes().to_vec();
    if !path.ends_with(MAIN_SEPARATOR) {
        bytes.extend_from_slice(MAIN_SEPARATOR.to_string().as_bytes());
    }
    Ok(TecsBytes {
        bytes: bytes.into_boxed_slice(),
    })
}

/// Returns an owned UTF-8 path to the application's system cache directory.
///
/// The path ends in the platform separator and exists before this returns.
/// Rust owns the returned byte allocation.
///
/// # Safety
///
/// Each non-null input must address its corresponding number of readable
/// bytes for this call.
#[no_mangle]
pub unsafe extern "C" fn tecsSystemCachePath(
    organization: *const u8,
    organization_length: usize,
    application: *const u8,
    application_length: usize,
) -> *mut TecsBytes {
    let result = text(organization, organization_length, "organization").and_then(|organization| {
        text(application, application_length, "application")
            .and_then(|application| resolve(&organization, &application))
    });
    match result {
        Ok(bytes) => Box::into_raw(Box::new(bytes)),
        Err(error) => {
            set_error(error);
            ptr::null_mut()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::component;

    #[test]
    fn identity_is_one_portable_path_component() {
        assert_eq!(component("Ex Nihilo"), "Ex Nihilo");
        assert_eq!(component("../studio/game:name"), "_studio_game_name");
        assert_eq!(component("..."), "_");
    }
}
