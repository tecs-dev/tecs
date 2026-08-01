use std::ptr;
use std::slice;
use std::str;

use url::Url;

use super::set_error;

pub struct TecsUri {
    url: Url,
}

unsafe fn input<'a>(data: *const u8, length: usize, what: &str) -> Result<&'a str, String> {
    if data.is_null() && length != 0 {
        return Err(format!("{what} is null"));
    }
    let bytes = if length == 0 {
        &[]
    } else {
        // SAFETY: The caller promises `length` readable bytes for this call.
        unsafe { slice::from_raw_parts(data, length) }
    };
    str::from_utf8(bytes).map_err(|_| format!("{what} is not UTF-8"))
}

fn fail(error: impl ToString) -> *mut TecsUri {
    set_error(error);
    ptr::null_mut()
}

fn output(url: Url) -> *mut TecsUri {
    Box::into_raw(Box::new(TecsUri { url }))
}

fn part(value: Option<&str>, length: *mut usize) -> *const u8 {
    match value {
        Some(value) => {
            if !length.is_null() {
                // SAFETY: The caller supplied writable output storage.
                unsafe { *length = value.len() };
            }
            value.as_ptr()
        }
        None => {
            if !length.is_null() {
                // SAFETY: The caller supplied writable output storage.
                unsafe { *length = 0 };
            }
            ptr::null()
        }
    }
}

fn authority(url: &Url) -> Option<&str> {
    let text = url.as_str();
    let after_scheme = url.scheme().len().checked_add(1)?;
    let rest = text.get(after_scheme..)?;
    if !rest.starts_with("//") {
        return None;
    }
    let start = after_scheme + 2;
    let tail = text.get(start..)?;
    let length = tail.find(['/', '?', '#']).unwrap_or(tail.len());
    text.get(start..start + length)
}

unsafe fn parse(data: *const u8, length: usize) -> Result<Url, String> {
    // SAFETY: This function preserves the public boundary's input contract.
    let text = unsafe { input(data, length, "URI") }?;
    Url::parse(text).map_err(|error| error.to_string())
}

unsafe fn clone_url(uri: *const TecsUri) -> Result<Url, String> {
    if uri.is_null() {
        return Err("URI is null".to_owned());
    }
    // SAFETY: Null was rejected and the caller promises a live URI.
    Ok(unsafe { &*uri }.url.clone())
}

/// Parses one absolute URI and retains its normalized components.
///
/// # Safety
///
/// `data` must be null with zero length or readable for `length` bytes.
#[no_mangle]
pub unsafe extern "C" fn tecsUriParse(data: *const u8, length: usize) -> *mut TecsUri {
    match unsafe { parse(data, length) } {
        Ok(url) => output(url),
        Err(error) => fail(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsUriText(uri: *const TecsUri, length: *mut usize) -> *const u8 {
    if uri.is_null() {
        return part(None, length);
    }
    part(Some(unsafe { &*uri }.url.as_str()), length)
}

#[no_mangle]
pub unsafe extern "C" fn tecsUriScheme(uri: *const TecsUri, length: *mut usize) -> *const u8 {
    if uri.is_null() {
        return part(None, length);
    }
    part(Some(unsafe { &*uri }.url.scheme()), length)
}

#[no_mangle]
pub unsafe extern "C" fn tecsUriAuthority(uri: *const TecsUri, length: *mut usize) -> *const u8 {
    if uri.is_null() {
        return part(None, length);
    }
    part(authority(&unsafe { &*uri }.url), length)
}

#[no_mangle]
pub unsafe extern "C" fn tecsUriUsername(uri: *const TecsUri, length: *mut usize) -> *const u8 {
    if uri.is_null() {
        return part(None, length);
    }
    part(Some(unsafe { &*uri }.url.username()), length)
}

#[no_mangle]
pub unsafe extern "C" fn tecsUriPassword(uri: *const TecsUri, length: *mut usize) -> *const u8 {
    if uri.is_null() {
        return part(None, length);
    }
    part(unsafe { &*uri }.url.password(), length)
}

#[no_mangle]
pub unsafe extern "C" fn tecsUriHost(uri: *const TecsUri, length: *mut usize) -> *const u8 {
    if uri.is_null() {
        return part(None, length);
    }
    part(unsafe { &*uri }.url.host_str(), length)
}

#[no_mangle]
pub unsafe extern "C" fn tecsUriPort(uri: *const TecsUri, port: *mut u16) -> i32 {
    if uri.is_null() {
        return 0;
    }
    let Some(value) = (unsafe { &*uri }).url.port() else {
        return 0;
    };
    if !port.is_null() {
        // SAFETY: The caller supplied writable output storage.
        unsafe { *port = value };
    }
    1
}

#[no_mangle]
pub unsafe extern "C" fn tecsUriPath(uri: *const TecsUri, length: *mut usize) -> *const u8 {
    if uri.is_null() {
        return part(None, length);
    }
    part(Some(unsafe { &*uri }.url.path()), length)
}

#[no_mangle]
pub unsafe extern "C" fn tecsUriQuery(uri: *const TecsUri, length: *mut usize) -> *const u8 {
    if uri.is_null() {
        return part(None, length);
    }
    part(unsafe { &*uri }.url.query(), length)
}

#[no_mangle]
pub unsafe extern "C" fn tecsUriFragment(uri: *const TecsUri, length: *mut usize) -> *const u8 {
    if uri.is_null() {
        return part(None, length);
    }
    part(unsafe { &*uri }.url.fragment(), length)
}

/// Copies a URI while replacing one text component.
///
/// Kinds are scheme, user information, host, path, query, and fragment in
/// that order. `present` clears optional components when zero.
#[no_mangle]
pub unsafe extern "C" fn tecsUriWithText(
    uri: *const TecsUri,
    kind: u32,
    value: *const u8,
    value_length: usize,
    present: i32,
) -> *mut TecsUri {
    let mut url = match unsafe { clone_url(uri) } {
        Ok(url) => url,
        Err(error) => return fail(error),
    };
    let value = match unsafe { input(value, value_length, "URI component") } {
        Ok(value) => value,
        Err(error) => return fail(error),
    };
    let result = match kind {
        0 => url
            .set_scheme(value)
            .map_err(|_| "URI scheme is invalid".to_owned()),
        1 => {
            let (username, password) = if present == 0 {
                ("", None)
            } else if let Some((username, password)) = value.split_once(':') {
                (username, Some(password))
            } else {
                (value, None)
            };
            url.set_username(username)
                .map_err(|_| "URI user information is invalid".to_owned())
                .and_then(|_| {
                    url.set_password(password)
                        .map_err(|_| "URI user information is invalid".to_owned())
                })
        }
        2 => url
            .set_host((present != 0).then_some(value))
            .map_err(|error| error.to_string()),
        3 => {
            url.set_path(value);
            Ok(())
        }
        4 => {
            url.set_query((present != 0).then_some(value));
            Ok(())
        }
        5 => {
            url.set_fragment((present != 0).then_some(value));
            Ok(())
        }
        _ => Err("URI component kind is invalid".to_owned()),
    };
    match result {
        Ok(()) => output(url),
        Err(error) => fail(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsUriWithPort(uri: *const TecsUri, port: i32) -> *mut TecsUri {
    let mut url = match unsafe { clone_url(uri) } {
        Ok(url) => url,
        Err(error) => return fail(error),
    };
    let port = if port < 0 { None } else { Some(port as u16) };
    match url.set_port(port) {
        Ok(()) => output(url),
        Err(()) => fail("URI port is not valid for this scheme"),
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsUriConcatPath(
    uri: *const TecsUri,
    suffix: *const u8,
    suffix_length: usize,
) -> *mut TecsUri {
    let mut url = match unsafe { clone_url(uri) } {
        Ok(url) => url,
        Err(error) => return fail(error),
    };
    let suffix = match unsafe { input(suffix, suffix_length, "URI path") } {
        Ok(suffix) => suffix,
        Err(error) => return fail(error),
    };
    let mut joined = url.path().to_owned();
    if joined.ends_with('/') && suffix.starts_with('/') {
        joined.push_str(&suffix[1..]);
    } else if !joined.ends_with('/') && !suffix.starts_with('/') {
        joined.push('/');
        joined.push_str(suffix);
    } else {
        joined.push_str(suffix);
    }
    url.set_path(&joined);
    output(url)
}

#[no_mangle]
pub unsafe extern "C" fn tecsUriResolve(
    uri: *const TecsUri,
    reference: *const u8,
    reference_length: usize,
) -> *mut TecsUri {
    let url = match unsafe { clone_url(uri) } {
        Ok(url) => url,
        Err(error) => return fail(error),
    };
    let reference = match unsafe { input(reference, reference_length, "URI reference") } {
        Ok(reference) => reference,
        Err(error) => return fail(error),
    };
    match url.join(reference) {
        Ok(resolved) => output(resolved),
        Err(error) => fail(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsUriWithEndpoint(
    uri: *const TecsUri,
    endpoint_uri: *const TecsUri,
) -> *mut TecsUri {
    let current = match unsafe { clone_url(uri) } {
        Ok(url) => url,
        Err(error) => return fail(error),
    };
    let mut endpoint = match unsafe { clone_url(endpoint_uri) } {
        Ok(url) => url,
        Err(error) => return fail(error),
    };
    let mut joined = endpoint.path().to_owned();
    let suffix = current.path();
    if joined.ends_with('/') && suffix.starts_with('/') {
        joined.push_str(&suffix[1..]);
    } else if !joined.ends_with('/') && !suffix.starts_with('/') {
        joined.push('/');
        joined.push_str(suffix);
    } else {
        joined.push_str(suffix);
    }
    endpoint.set_path(&joined);
    endpoint.set_query(current.query());
    endpoint.set_fragment(current.fragment());
    output(endpoint)
}

#[no_mangle]
pub unsafe extern "C" fn tecsUriDestroy(uri: *mut TecsUri) {
    if !uri.is_null() {
        // SAFETY: The caller transfers one owned URI.
        drop(unsafe { Box::from_raw(uri) });
    }
}
