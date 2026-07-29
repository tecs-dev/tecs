//! Compiled regular expressions exposed to `tecs.regex`.
//!
//! Lua strings are byte strings, so the bridge uses `regex::bytes::Regex`.
//! Patterns remain UTF-8 Rust regex syntax while subjects may contain any
//! bytes, and every position crossing the ABI is a byte offset.

use std::ptr;
use std::slice;
use std::str;

use ::regex::bytes::Regex;

use super::set_error;

pub struct TecsRegex {
    regex: Regex,
    names: Vec<Option<Box<[u8]>>>,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TecsRegexSpan {
    start: usize,
    end: usize,
    matched: bool,
}

unsafe fn bytes<'a>(value: *const u8, length: usize) -> Option<&'a [u8]> {
    if value.is_null() {
        return (length == 0).then_some(&[]);
    }
    // SAFETY: Every public caller promises that a non-null pointer addresses
    // `length` readable bytes for the duration of the boundary call.
    Some(unsafe { slice::from_raw_parts(value, length) })
}

fn span(start: usize, end: usize) -> TecsRegexSpan {
    TecsRegexSpan {
        start,
        end,
        matched: true,
    }
}

fn unmatched() -> TecsRegexSpan {
    TecsRegexSpan {
        start: 0,
        end: 0,
        matched: false,
    }
}

/// Compiles one Rust regular expression.
///
/// Returns null and records the parser error in `tecsRustError` when the
/// pattern is not UTF-8 or is not valid Rust regex syntax.
///
/// # Safety
///
/// When `length` is nonzero, `pattern` must address at least that many
/// readable bytes for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn tecsRegexCompile(pattern: *const u8, length: usize) -> *mut TecsRegex {
    // SAFETY: Propagates this function's pointer validity contract.
    let Some(pattern) = (unsafe { bytes(pattern, length) }) else {
        set_error("regex pattern is null");
        return ptr::null_mut();
    };
    let pattern = match str::from_utf8(pattern) {
        Ok(pattern) => pattern,
        Err(_) => {
            set_error("regex pattern is not UTF-8");
            return ptr::null_mut();
        }
    };
    let regex = match Regex::new(pattern) {
        Ok(regex) => regex,
        Err(error) => {
            set_error(error);
            return ptr::null_mut();
        }
    };
    let names = regex
        .capture_names()
        .map(|name| name.map(|name| name.as_bytes().into()))
        .collect();
    Box::into_raw(Box::new(TecsRegex { regex, names }))
}

/// Returns the whole match plus the number of explicit capture groups.
///
/// # Safety
///
/// `regex` must be null or a live pointer returned by `tecsRegexCompile`.
#[no_mangle]
pub unsafe extern "C" fn tecsRegexCaptureCount(regex: *const TecsRegex) -> usize {
    if regex.is_null() {
        return 0;
    }
    // SAFETY: The caller promises that this is a live compiled regex.
    unsafe { &*regex }.regex.captures_len()
}

/// Borrows the name of one capture group.
///
/// An unnamed or out-of-range group answers null and writes zero to `length`.
/// The returned bytes stay valid until the compiled regex is destroyed.
///
/// # Safety
///
/// `regex` must be null or a live pointer returned by `tecsRegexCompile`.
/// `length`, when non-null, must be writable.
#[no_mangle]
pub unsafe extern "C" fn tecsRegexCaptureName(
    regex: *const TecsRegex,
    index: usize,
    length: *mut usize,
) -> *const u8 {
    if !length.is_null() {
        // SAFETY: The caller promises that a non-null out pointer is writable.
        unsafe { *length = 0 };
    }
    if regex.is_null() {
        return ptr::null();
    }
    // SAFETY: The caller promises that this is a live compiled regex.
    let regex = unsafe { &*regex };
    let Some(Some(name)) = regex.names.get(index) else {
        return ptr::null();
    };
    if !length.is_null() {
        // SAFETY: The caller promises that a non-null out pointer is writable.
        unsafe { *length = name.len() };
    }
    name.as_ptr()
}

/// Tests whether a subject contains a match.
///
/// # Safety
///
/// `regex` must be null or a live pointer returned by `tecsRegexCompile`.
/// When `length` is nonzero, `subject` must address at least that many
/// readable bytes for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn tecsRegexIsMatch(
    regex: *const TecsRegex,
    subject: *const u8,
    length: usize,
) -> bool {
    if regex.is_null() {
        return false;
    }
    // SAFETY: Propagates this function's pointer validity contract.
    let Some(subject) = (unsafe { bytes(subject, length) }) else {
        return false;
    };
    // SAFETY: The caller promises that this is a live compiled regex.
    unsafe { &*regex }.regex.is_match(subject)
}

/// Finds the first match at or after `start`.
///
/// # Safety
///
/// `regex` must be null or a live pointer returned by `tecsRegexCompile`.
/// The subject follows `tecsRegexIsMatch`'s contract. `span`, when non-null,
/// must be writable.
#[no_mangle]
pub unsafe extern "C" fn tecsRegexFind(
    regex: *const TecsRegex,
    subject: *const u8,
    length: usize,
    start: usize,
    output: *mut TecsRegexSpan,
) -> bool {
    if regex.is_null() || output.is_null() || start > length {
        return false;
    }
    // SAFETY: Propagates this function's pointer validity contract.
    let Some(subject) = (unsafe { bytes(subject, length) }) else {
        return false;
    };
    // SAFETY: The caller promises that this is a live compiled regex.
    let Some(found) = (unsafe { &*regex }).regex.find_at(subject, start) else {
        return false;
    };
    // SAFETY: The caller promises that a non-null out pointer is writable.
    unsafe { *output = span(found.start(), found.end()) };
    true
}

/// Finds a match and writes the whole match followed by every capture group.
///
/// Unmatched groups receive a span whose `matched` field is false. `count`
/// must be at least `tecsRegexCaptureCount(regex)` so a partial result is
/// never mistaken for a complete one.
///
/// # Safety
///
/// `regex` and the subject follow `tecsRegexFind`'s contract. `spans` must
/// address at least `count` writable spans.
#[no_mangle]
pub unsafe extern "C" fn tecsRegexCaptures(
    regex: *const TecsRegex,
    subject: *const u8,
    length: usize,
    start: usize,
    spans: *mut TecsRegexSpan,
    count: usize,
) -> bool {
    if regex.is_null() || spans.is_null() || start > length {
        return false;
    }
    // SAFETY: The caller promises that this is a live compiled regex.
    let regex = unsafe { &*regex };
    if count < regex.regex.captures_len() {
        return false;
    }
    // SAFETY: Propagates this function's pointer validity contract.
    let Some(subject) = (unsafe { bytes(subject, length) }) else {
        return false;
    };
    let Some(captures) = regex.regex.captures_at(subject, start) else {
        return false;
    };
    // SAFETY: The caller promises `count` writable spans.
    let spans = unsafe { slice::from_raw_parts_mut(spans, count) };
    for (index, output) in spans.iter_mut().enumerate().take(captures.len()) {
        *output = captures
            .get(index)
            .map(|found| span(found.start(), found.end()))
            .unwrap_or_else(unmatched);
    }
    true
}

/// Releases a compiled regular expression.
///
/// # Safety
///
/// `regex` must be null or an owned pointer returned by `tecsRegexCompile`.
/// A non-null pointer may be destroyed exactly once.
#[no_mangle]
pub unsafe extern "C" fn tecsRegexDestroy(regex: *mut TecsRegex) {
    if !regex.is_null() {
        // SAFETY: Ownership crosses this boundary once and the caller must not
        // use or destroy the pointer again.
        drop(unsafe { Box::from_raw(regex) });
    }
}
