use std::ptr;
use std::slice;
use std::str;

use camino::{absolute_utf8, Utf8Component, Utf8Path, Utf8PathBuf};
use path_clean::PathClean;
use pathdiff::diff_utf8_paths;

use super::{set_error, TecsBytes};

#[repr(C)]
pub struct TecsStringView {
    data: *const u8,
    length: usize,
}

unsafe fn input<'a>(data: *const u8, length: usize) -> Result<&'a Utf8Path, String> {
    if data.is_null() && length != 0 {
        return Err("path input is null".to_owned());
    }
    let bytes = if length == 0 {
        &[]
    } else {
        // SAFETY: The caller promises `length` readable bytes for this call.
        unsafe { slice::from_raw_parts(data, length) }
    };
    let text = str::from_utf8(bytes).map_err(|_| "path is not valid UTF-8".to_owned())?;
    if text.as_bytes().contains(&0) {
        return Err("path contains a NUL byte".to_owned());
    }
    Ok(Utf8Path::new(text))
}

fn output(path: impl Into<Utf8PathBuf>) -> *mut TecsBytes {
    Box::into_raw(Box::new(TecsBytes {
        bytes: path.into().into_string().into_bytes().into_boxed_slice(),
    }))
}

fn fail(error: impl ToString) -> *mut TecsBytes {
    set_error(error);
    ptr::null_mut()
}

fn converted(path: std::path::PathBuf) -> Result<Utf8PathBuf, String> {
    Utf8PathBuf::from_path_buf(path).map_err(|_| "path result is not valid UTF-8".to_owned())
}

#[no_mangle]
pub unsafe extern "C" fn tecsPathValidate(data: *const u8, length: usize) -> bool {
    match unsafe { input(data, length) } {
        Ok(_) => true,
        Err(error) => {
            set_error(error);
            false
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsPathJoin(
    parts: *const TecsStringView,
    count: usize,
) -> *mut TecsBytes {
    if parts.is_null() && count != 0 {
        return fail("path parts are null");
    }
    let parts = if count == 0 {
        &[]
    } else {
        // SAFETY: The caller promises `count` initialized views for this call.
        unsafe { slice::from_raw_parts(parts, count) }
    };
    let mut joined = Utf8PathBuf::new();
    for part in parts {
        let part = match unsafe { input(part.data, part.length) } {
            Ok(part) => part,
            Err(error) => return fail(error),
        };
        joined.push(part);
    }
    output(joined)
}

#[no_mangle]
pub unsafe extern "C" fn tecsPathNormalize(data: *const u8, length: usize) -> *mut TecsBytes {
    let path = match unsafe { input(data, length) } {
        Ok(path) => path,
        Err(error) => return fail(error),
    };
    match converted(path.as_std_path().clean()) {
        Ok(cleaned) => output(cleaned),
        Err(error) => fail(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsPathAbsolute(data: *const u8, length: usize) -> *mut TecsBytes {
    let path = match unsafe { input(data, length) } {
        Ok(path) => path,
        Err(error) => return fail(error),
    };
    match absolute_utf8(path) {
        Ok(absolute) => output(absolute),
        Err(error) => fail(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsPathCanonicalize(data: *const u8, length: usize) -> *mut TecsBytes {
    let path = match unsafe { input(data, length) } {
        Ok(path) => path,
        Err(error) => return fail(error),
    };
    match path.canonicalize_utf8() {
        Ok(canonical) => output(canonical),
        Err(error) => fail(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsPathRelative(
    data: *const u8,
    length: usize,
    base: *const u8,
    base_length: usize,
) -> *mut TecsBytes {
    let path = match unsafe { input(data, length) } {
        Ok(path) => path,
        Err(error) => return fail(error),
    };
    let base = match unsafe { input(base, base_length) } {
        Ok(base) => base,
        Err(error) => return fail(error),
    };
    match diff_utf8_paths(path, base) {
        Some(relative) => output(relative),
        None => fail("paths do not share a relative coordinate system"),
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsPathParent(data: *const u8, length: usize) -> *mut TecsBytes {
    let path = match unsafe { input(data, length) } {
        Ok(path) => path,
        Err(error) => return fail(error),
    };
    path.parent().map_or_else(ptr::null_mut, output)
}

#[no_mangle]
pub unsafe extern "C" fn tecsPathFileName(data: *const u8, length: usize) -> *mut TecsBytes {
    let path = match unsafe { input(data, length) } {
        Ok(path) => path,
        Err(error) => return fail(error),
    };
    path.file_name()
        .map_or_else(ptr::null_mut, |name| output(Utf8PathBuf::from(name)))
}

#[no_mangle]
pub unsafe extern "C" fn tecsPathStem(data: *const u8, length: usize) -> *mut TecsBytes {
    let path = match unsafe { input(data, length) } {
        Ok(path) => path,
        Err(error) => return fail(error),
    };
    path.file_stem()
        .map_or_else(ptr::null_mut, |stem| output(Utf8PathBuf::from(stem)))
}

#[no_mangle]
pub unsafe extern "C" fn tecsPathExtension(data: *const u8, length: usize) -> *mut TecsBytes {
    let path = match unsafe { input(data, length) } {
        Ok(path) => path,
        Err(error) => return fail(error),
    };
    path.extension().map_or_else(ptr::null_mut, |extension| {
        output(Utf8PathBuf::from(extension))
    })
}

fn normal_component(value: &Utf8Path) -> bool {
    let mut components = value.components();
    matches!(components.next(), Some(Utf8Component::Normal(_))) && components.next().is_none()
}

#[no_mangle]
pub unsafe extern "C" fn tecsPathWithFileName(
    data: *const u8,
    length: usize,
    name: *const u8,
    name_length: usize,
) -> *mut TecsBytes {
    let path = match unsafe { input(data, length) } {
        Ok(path) => path,
        Err(error) => return fail(error),
    };
    let name = match unsafe { input(name, name_length) } {
        Ok(name) if normal_component(name) => name,
        Ok(_) => return fail("file name must be one non-empty path component"),
        Err(error) => return fail(error),
    };
    output(path.with_file_name(name))
}

#[no_mangle]
pub unsafe extern "C" fn tecsPathWithExtension(
    data: *const u8,
    length: usize,
    extension: *const u8,
    extension_length: usize,
) -> *mut TecsBytes {
    let path = match unsafe { input(data, length) } {
        Ok(path) => path,
        Err(error) => return fail(error),
    };
    let extension = match unsafe { input(extension, extension_length) } {
        Ok(extension) => extension,
        Err(error) => return fail(error),
    };
    if !extension.as_str().is_empty() && !normal_component(extension) {
        return fail("extension must be empty or one path component");
    }
    output(path.with_extension(extension.as_str()))
}

#[no_mangle]
pub unsafe extern "C" fn tecsPathIsAbsolute(data: *const u8, length: usize) -> bool {
    match unsafe { input(data, length) } {
        Ok(path) => path.is_absolute(),
        Err(error) => {
            set_error(error);
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use camino::Utf8Path;
    use path_clean::PathClean;
    use pathdiff::diff_utf8_paths;

    #[test]
    fn dependencies_supply_lexical_and_relative_operations() {
        let cleaned = Utf8Path::new("alpha/./beta/../file.txt")
            .as_std_path()
            .clean();
        assert_eq!(cleaned, std::path::Path::new("alpha/file.txt"));
        assert_eq!(
            diff_utf8_paths(Utf8Path::new("/alpha/file.txt"), Utf8Path::new("/alpha")),
            Some("file.txt".into())
        );
    }
}
