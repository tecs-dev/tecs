//! Filesystem operations SDL's path API cannot answer.

use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::slice;
use std::sync::atomic::{AtomicU64, Ordering};

#[cfg(unix)]
use std::ffi::OsStr;
#[cfg(any(target_os = "macos", target_os = "ios"))]
use std::os::fd::AsRawFd;
#[cfg(unix)]
use std::os::unix::ffi::OsStrExt;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

#[cfg(windows)]
use std::iter;
#[cfg(windows)]
use std::os::windows::ffi::OsStrExt;

use super::{set_error, TecsBytes};

static TEMPORARY_ID: AtomicU64 = AtomicU64::new(0);

#[cfg(unix)]
fn path_from_bytes(bytes: &[u8]) -> Result<PathBuf, String> {
    Ok(PathBuf::from(OsStr::from_bytes(bytes)))
}

#[cfg(unix)]
fn path_bytes(path: &Path) -> Result<Box<[u8]>, String> {
    Ok(path.as_os_str().as_bytes().to_vec().into_boxed_slice())
}

#[cfg(not(unix))]
fn path_bytes(path: &Path) -> Result<Box<[u8]>, String> {
    path.to_str()
        .map(|value| value.as_bytes().to_vec().into_boxed_slice())
        .ok_or_else(|| "filesystem path is not valid UTF-8".to_owned())
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

enum TemporaryKind {
    File,
    Directory,
}

/// An exclusively created temporary path which removes itself until persisted.
pub struct TecsTemporaryPath {
    path: PathBuf,
    kind: TemporaryKind,
    active: bool,
}

impl TecsTemporaryPath {
    fn close(&mut self) -> io::Result<()> {
        if !self.active {
            return Ok(());
        }
        match self.kind {
            TemporaryKind::File => std::fs::remove_file(&self.path)?,
            TemporaryKind::Directory => std::fs::remove_dir_all(&self.path)?,
        }
        self.active = false;
        Ok(())
    }
}

impl Drop for TecsTemporaryPath {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

fn create_owned_temporary(
    directory: &Path,
    prefix: &str,
    suffix: &str,
    kind: TemporaryKind,
) -> io::Result<TecsTemporaryPath> {
    for _ in 0..128 {
        let id = TEMPORARY_ID.fetch_add(1, Ordering::Relaxed);
        let path = directory.join(format!("{prefix}{}-{id}{suffix}", std::process::id()));
        let result = match kind {
            TemporaryKind::File => OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
                .map(|_| ()),
            TemporaryKind::Directory => std::fs::create_dir(&path),
        };
        match result {
            Ok(()) => {
                return Ok(TecsTemporaryPath {
                    path,
                    kind,
                    active: true,
                });
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "cannot reserve a unique temporary path",
    ))
}

unsafe fn input_bytes<'a>(
    pointer: *const u8,
    length: usize,
    name: &str,
) -> Result<&'a [u8], String> {
    if pointer.is_null() && length != 0 {
        return Err(format!("{name} is null"));
    }
    Ok(if length == 0 {
        &[]
    } else {
        // SAFETY: The caller promises `length` readable bytes.
        unsafe { slice::from_raw_parts(pointer, length) }
    })
}

unsafe fn create_temporary_ffi(
    directory: *const u8,
    directory_length: usize,
    prefix: *const u8,
    prefix_length: usize,
    suffix: *const u8,
    suffix_length: usize,
    kind: TemporaryKind,
) -> *mut TecsTemporaryPath {
    let result = (|| {
        let directory = unsafe { input_bytes(directory, directory_length, "temporary directory") }?;
        let prefix = unsafe { input_bytes(prefix, prefix_length, "temporary prefix") }?;
        let suffix = unsafe { input_bytes(suffix, suffix_length, "temporary suffix") }?;
        let directory = if directory.is_empty() {
            std::env::temp_dir()
        } else {
            path_from_bytes(directory)?
        };
        let prefix = std::str::from_utf8(prefix)
            .map_err(|_| "temporary prefix is not valid UTF-8".to_owned())?;
        let suffix = std::str::from_utf8(suffix)
            .map_err(|_| "temporary suffix is not valid UTF-8".to_owned())?;
        create_owned_temporary(&directory, prefix, suffix, kind).map_err(|error| error.to_string())
    })();
    match result {
        Ok(temporary) => Box::into_raw(Box::new(temporary)),
        Err(error) => {
            set_error(error);
            std::ptr::null_mut()
        }
    }
}

struct TemporaryFile {
    file: Option<File>,
    path: PathBuf,
    committed: bool,
}

impl Drop for TemporaryFile {
    fn drop(&mut self) {
        self.file.take();
        if !self.committed {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

fn parent_of(path: &Path) -> &Path {
    path.parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."))
}

fn create_temporary(path: &Path) -> io::Result<TemporaryFile> {
    let parent = parent_of(path);
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("file");

    for _ in 0..128 {
        let id = TEMPORARY_ID.fetch_add(1, Ordering::Relaxed);
        let temporary = parent.join(format!(".{name}.tecs-{}-{id}.tmp", std::process::id()));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
        {
            Ok(file) => {
                return Ok(TemporaryFile {
                    file: Some(file),
                    path: temporary,
                    committed: false,
                });
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }

    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "cannot reserve a unique neighboring temporary file",
    ))
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn sync_file(file: &File) -> io::Result<()> {
    // fsync may stop at the drive's volatile cache on Apple platforms.
    // F_FULLFSYNC asks the device to commit that cache as well. Filesystems
    // that do not implement it still receive Rust's ordinary fsync contract.
    let result = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_FULLFSYNC) };
    if result == 0 {
        return Ok(());
    }
    file.sync_all()
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn sync_file(file: &File) -> io::Result<()> {
    file.sync_all()
}

#[cfg(unix)]
fn replace(temporary: &Path, destination: &Path) -> io::Result<()> {
    std::fs::rename(temporary, destination)
}

#[cfg(windows)]
fn replace(temporary: &Path, destination: &Path) -> io::Result<()> {
    const MOVEFILE_REPLACE_EXISTING: u32 = 0x0000_0001;
    const MOVEFILE_WRITE_THROUGH: u32 = 0x0000_0008;

    #[link(name = "kernel32")]
    extern "system" {
        fn MoveFileExW(existing: *const u16, destination: *const u16, flags: u32) -> i32;
    }

    let existing: Vec<u16> = temporary
        .as_os_str()
        .encode_wide()
        .chain(iter::once(0))
        .collect();
    let destination: Vec<u16> = destination
        .as_os_str()
        .encode_wide()
        .chain(iter::once(0))
        .collect();
    let moved = unsafe {
        MoveFileExW(
            existing.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(unix)]
fn sync_parent(path: &Path) -> io::Result<()> {
    File::open(parent_of(path))?.sync_all()
}

#[cfg(windows)]
fn sync_parent(_path: &Path) -> io::Result<()> {
    // MoveFileExW above requests write-through for the replacement. Windows
    // has no directory fsync operation corresponding to the Unix call.
    Ok(())
}

fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut temporary = create_temporary(path)?;
    let file = temporary
        .file
        .as_mut()
        .expect("a newly created temporary file owns its handle");
    file.write_all(bytes)?;
    sync_file(file)?;

    // Windows cannot replace an open file. Closing before the move also means
    // every write error has surfaced before the destination can change.
    temporary.file.take();
    replace(&temporary.path, path)?;
    temporary.committed = true;

    // A failure here means the atomic replacement is visible, but its
    // survival across a crash could not be confirmed. Rolling back would be a
    // second non-durable replacement and would destroy the atomic guarantee.
    sync_parent(path)
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

/// Returns the target spelling stored in a symbolic link.
#[no_mangle]
pub unsafe extern "C" fn tecsPathReadLink(path: *const u8, path_length: usize) -> *mut TecsBytes {
    let result = (|| {
        let bytes = unsafe { input_bytes(path, path_length, "filesystem path") }?;
        let target =
            std::fs::read_link(path_from_bytes(bytes)?).map_err(|error| error.to_string())?;
        Ok::<TecsBytes, String>(TecsBytes {
            bytes: path_bytes(&target)?,
        })
    })();
    match result {
        Ok(bytes) => Box::into_raw(Box::new(bytes)),
        Err(error) => {
            set_error(error);
            std::ptr::null_mut()
        }
    }
}

/// Creates a symbolic link without resolving the target spelling.
#[no_mangle]
pub unsafe extern "C" fn tecsPathCreateSymlink(
    target: *const u8,
    target_length: usize,
    link: *const u8,
    link_length: usize,
    directory: bool,
) -> bool {
    let result = (|| {
        let target =
            path_from_bytes(unsafe { input_bytes(target, target_length, "link target") }?)?;
        let link = path_from_bytes(unsafe { input_bytes(link, link_length, "link path") }?)?;
        #[cfg(unix)]
        {
            let _ = directory;
            std::os::unix::fs::symlink(target, link).map_err(|error| error.to_string())
        }
        #[cfg(windows)]
        {
            if directory {
                std::os::windows::fs::symlink_dir(target, link).map_err(|error| error.to_string())
            } else {
                std::os::windows::fs::symlink_file(target, link).map_err(|error| error.to_string())
            }
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = (target, link, directory);
            Err("symbolic links are not supported on this platform".to_owned())
        }
    })();
    match result {
        Ok(()) => true,
        Err(error) => {
            set_error(error);
            false
        }
    }
}

/// Returns whether a path's portable read-only flag is set.
#[no_mangle]
pub unsafe extern "C" fn tecsPathIsReadOnly(path: *const u8, path_length: usize) -> i32 {
    let result = (|| {
        let path = path_from_bytes(unsafe { input_bytes(path, path_length, "filesystem path") }?)?;
        std::fs::metadata(path)
            .map(|metadata| metadata.permissions().readonly())
            .map_err(|error| error.to_string())
    })();
    match result {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(error) => {
            set_error(error);
            -1
        }
    }
}

/// Changes only the portable read-only state of a path.
#[no_mangle]
pub unsafe extern "C" fn tecsPathSetReadOnly(
    path: *const u8,
    path_length: usize,
    read_only: bool,
) -> bool {
    let result = (|| {
        let path = path_from_bytes(unsafe { input_bytes(path, path_length, "filesystem path") }?)?;
        let mut permissions = std::fs::metadata(&path)
            .map_err(|error| error.to_string())?
            .permissions();
        #[cfg(unix)]
        {
            let mode = permissions.mode();
            permissions.set_mode(if read_only {
                mode & !0o222
            } else {
                mode | 0o200
            });
        }
        #[cfg(not(unix))]
        permissions.set_readonly(read_only);
        std::fs::set_permissions(path, permissions).map_err(|error| error.to_string())
    })();
    match result {
        Ok(()) => true,
        Err(error) => {
            set_error(error);
            false
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsTemporaryFileCreate(
    directory: *const u8,
    directory_length: usize,
    prefix: *const u8,
    prefix_length: usize,
    suffix: *const u8,
    suffix_length: usize,
) -> *mut TecsTemporaryPath {
    unsafe {
        create_temporary_ffi(
            directory,
            directory_length,
            prefix,
            prefix_length,
            suffix,
            suffix_length,
            TemporaryKind::File,
        )
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsTemporaryDirectoryCreate(
    directory: *const u8,
    directory_length: usize,
    prefix: *const u8,
    prefix_length: usize,
    suffix: *const u8,
    suffix_length: usize,
) -> *mut TecsTemporaryPath {
    unsafe {
        create_temporary_ffi(
            directory,
            directory_length,
            prefix,
            prefix_length,
            suffix,
            suffix_length,
            TemporaryKind::Directory,
        )
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsTemporaryPathGet(
    temporary: *const TecsTemporaryPath,
) -> *mut TecsBytes {
    let Some(temporary) = (unsafe { temporary.as_ref() }) else {
        set_error("temporary path is null");
        return std::ptr::null_mut();
    };
    match path_bytes(&temporary.path) {
        Ok(bytes) => Box::into_raw(Box::new(TecsBytes { bytes })),
        Err(error) => {
            set_error(error);
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsTemporaryPathPersist(
    temporary: *mut TecsTemporaryPath,
    destination: *const u8,
    destination_length: usize,
) -> bool {
    let result = (|| {
        let temporary =
            unsafe { temporary.as_mut() }.ok_or_else(|| "temporary path is null".to_owned())?;
        if !temporary.active {
            return Err("temporary path is closed".to_owned());
        }
        let destination = path_from_bytes(unsafe {
            input_bytes(destination, destination_length, "temporary destination")
        }?)?;
        match std::fs::symlink_metadata(&destination) {
            Ok(_) => return Err("temporary destination already exists".to_owned()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.to_string()),
        }
        std::fs::rename(&temporary.path, destination).map_err(|error| error.to_string())?;
        temporary.active = false;
        Ok(())
    })();
    match result {
        Ok(()) => true,
        Err(error) => {
            set_error(error);
            false
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsTemporaryPathClose(temporary: *mut TecsTemporaryPath) -> bool {
    let result = unsafe { temporary.as_mut() }
        .ok_or_else(|| "temporary path is null".to_owned())
        .and_then(|temporary| temporary.close().map_err(|error| error.to_string()));
    match result {
        Ok(()) => true,
        Err(error) => {
            set_error(error);
            false
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsTemporaryPathDestroy(temporary: *mut TecsTemporaryPath) {
    if !temporary.is_null() {
        drop(unsafe { Box::from_raw(temporary) });
    }
}

/// Durably writes bytes through a neighboring file and atomically replaces a path.
///
/// Returns false after recording an operating-system failure in
/// `tecsRustError`. A failure before replacement leaves an existing destination
/// untouched and removes the temporary file. A failure synchronizing the
/// parent after replacement leaves the complete new destination visible but
/// reports that crash durability could not be confirmed.
///
/// # Safety
///
/// Nonempty path and byte slices must each address their declared number of
/// readable bytes for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn tecsFileWriteAtomic(
    path: *const u8,
    path_length: usize,
    bytes: *const u8,
    length: usize,
) -> bool {
    if path.is_null() && path_length != 0 {
        set_error("filesystem path is null");
        return false;
    }
    if bytes.is_null() && length != 0 {
        set_error("file bytes are null");
        return false;
    }
    let path_bytes = if path_length == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(path, path_length) }
    };
    let bytes = if length == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(bytes, length) }
    };

    match path_from_bytes(path_bytes)
        .and_then(|path| write_atomic(&path, bytes).map_err(|error| error.to_string()))
    {
        Ok(()) => true,
        Err(error) => {
            set_error(error);
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::write_atomic;

    static TEST_ID: AtomicU64 = AtomicU64::new(0);

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let id = TEST_ID.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "tecs-atomic-write-test-{}-{id}",
                std::process::id()
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn creates_and_replaces_a_complete_file() {
        let directory = TestDirectory::new();
        let path = directory.0.join("save.bin");
        write_atomic(&path, b"first").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"first");

        write_atomic(&path, b"a longer replacement\0with bytes").unwrap();
        assert_eq!(
            fs::read(&path).unwrap(),
            b"a longer replacement\0with bytes"
        );
    }

    #[test]
    fn removes_the_temporary_file_when_replacement_fails() {
        let directory = TestDirectory::new();
        let destination = directory.0.join("occupied");
        fs::create_dir(&destination).unwrap();
        fs::write(destination.join("entry"), b"kept").unwrap();

        assert!(write_atomic(&destination, b"replacement").is_err());
        assert_eq!(fs::read(destination.join("entry")).unwrap(), b"kept");
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 1);
    }

    #[test]
    fn does_not_create_a_destination_when_its_parent_is_absent() {
        let directory = TestDirectory::new();
        let path = directory.0.join("absent/save.bin");
        assert!(write_atomic(&path, b"bytes").is_err());
        assert!(!path.exists());
        assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 0);
    }
}
