//! What a shipped binary links against, and whether the package it sits in
//! reaches those libraries on its own.
//!
//! [`crate::package`] owns what a release contains; this module owns the
//! platform half of proving it is relocatable. The three inspectors are
//! `otool`, `readelf` and `dumpbin`, and each one answers the same pair: the
//! loader search paths a binary declares, and the libraries it needs.

use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use anyhow::{Context, Result};
use regex::Regex;
use walkdir::WalkDir;

const MACOS_SYSTEM_PREFIXES: &[&str] = &["/usr/lib/", "/System/Library/"];
const LINUX_SYSTEM_LIBRARIES: &[&str] = &[
    "ld-linux-aarch64.so.1",
    "ld-linux-x86-64.so.2",
    "libc.so.6",
    // Platform services supplied by the Linux distribution, like the window
    // and audio frameworks on macOS. Their runtime requirements are in README.
    "libasound.so.2",
    "libudev.so.1",
    "libdl.so.2",
    "libgcc_s.so.1",
    "libm.so.6",
    "libpthread.so.0",
    "librt.so.1",
    "libstdc++.so.6",
    "linux-vdso.so.1",
];
const WINDOWS_SYSTEM_LIBRARIES: &[&str] = &[
    "advapi32.dll",
    "avrt.dll",
    "bcrypt.dll",
    "cfgmgr32.dll",
    "combase.dll",
    "crypt32.dll",
    "d3d11.dll",
    "d3d12.dll",
    "dwmapi.dll",
    "dxgi.dll",
    "gdi32.dll",
    "hid.dll",
    "imm32.dll",
    "iphlpapi.dll",
    "kernel32.dll",
    "mf.dll",
    "mfplat.dll",
    "mfreadwrite.dll",
    "mfuuid.dll",
    "mmdevapi.dll",
    "ntdll.dll",
    "ole32.dll",
    "oleaut32.dll",
    "powrprof.dll",
    "secur32.dll",
    "setupapi.dll",
    "shell32.dll",
    "shlwapi.dll",
    "ucrtbase.dll",
    "user32.dll",
    "userenv.dll",
    "uuid.dll",
    "version.dll",
    "winmm.dll",
    "ws2_32.dll",
];
pub(crate) const COMPILER_LIBRARY_NAMES: &[&str] =
    &["shaderc", "spirvcross", "spirv-cross", "dxcompiler"];
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Platform {
    Linux,
    Macos,
    Windows,
}

pub(crate) fn binaries(prefix: &Path) -> Result<Vec<PathBuf>> {
    let mut binaries: Vec<_> = WalkDir::new(prefix)
        .into_iter()
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|entry| entry.file_type().is_file() || entry.file_type().is_symlink())
        .filter(|entry| {
            let path = entry.path();
            let in_bin = path
                .parent()
                .and_then(Path::file_name)
                .and_then(|value| value.to_str())
                == Some("bin");
            // bin/ also carries shader data and its text manifest. Inspect
            // extensionless Unix executables and Windows .exe files, while
            // still passing a malformed executable to the inspector to fail.
            let executable = path
                .extension()
                .is_none_or(|extension| extension.eq_ignore_ascii_case("exe"));
            is_shared_library(path) || (in_bin && executable)
        })
        .map(|entry| entry.into_path())
        .collect();
    binaries.sort();
    Ok(binaries)
}

pub(crate) fn is_shared_library(path: &Path) -> bool {
    let name = path
        .file_name()
        .and_then(OsStr::to_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    name.ends_with(".dylib")
        || name.contains(".dylib.")
        || name.ends_with(".so")
        || name.contains(".so.")
        || name.ends_with(".dll")
}

pub(crate) fn references(binary: &Path, platform: Platform) -> Result<(Vec<String>, Vec<String>)> {
    match platform {
        Platform::Macos => macho_references(binary),
        Platform::Windows => pe_references(binary),
        Platform::Linux => elf_references(binary),
    }
}

fn macho_references(binary: &Path) -> Result<(Vec<String>, Vec<String>)> {
    let mut load_command = Command::new("otool");
    load_command.arg("-l").arg(binary);
    let load = checked_output(&mut load_command, "otool -l")?;
    let text = String::from_utf8(load.stdout)?;
    let rpath = Regex::new(r"(?s)cmd LC_RPATH.*?path ([^\s]+)")?;
    let rpaths = rpath
        .captures_iter(&text)
        .map(|found| found[1].to_owned())
        .collect();
    let mut linked_command = Command::new("otool");
    linked_command.arg("-L").arg(binary);
    let linked = checked_output(&mut linked_command, "otool -L")?;
    let libraries = String::from_utf8(linked.stdout)?
        .lines()
        .skip(1)
        .filter_map(|line| line.split_whitespace().next().map(str::to_owned))
        .collect();
    Ok((rpaths, libraries))
}

fn elf_references(binary: &Path) -> Result<(Vec<String>, Vec<String>)> {
    let mut command = Command::new("readelf");
    command.arg("-d").arg(binary);
    let output = checked_output(&mut command, "readelf -d")?;
    let text = String::from_utf8(output.stdout)?;
    let rpath = Regex::new(r"\(R(?:UN)?PATH\).*\[([^\]]+)\]")?;
    let rpaths = rpath
        .captures_iter(&text)
        .flat_map(|found| found[1].split(':').map(str::to_owned).collect::<Vec<_>>())
        .collect();
    let needed = Regex::new(r"\(NEEDED\).*\[([^\]]+)\]")?;
    let libraries = needed
        .captures_iter(&text)
        .map(|found| found[1].to_owned())
        .collect();
    Ok((rpaths, libraries))
}

fn pe_references(binary: &Path) -> Result<(Vec<String>, Vec<String>)> {
    let mut command = Command::new("dumpbin");
    command.arg("/dependents").arg(binary);
    let output = checked_output(&mut command, "dumpbin /dependents")?;
    let dll = Regex::new(r"(?i)^\s+([A-Za-z0-9_.+-]+\.dll)\s*$")?;
    let libraries = String::from_utf8(output.stdout)?
        .lines()
        .filter_map(|line| dll.captures(line).map(|found| found[1].to_owned()))
        .collect();
    Ok((Vec::new(), libraries))
}

fn checked_output(command: &mut Command, description: &str) -> Result<Output> {
    let output = command
        .output()
        .with_context(|| format!("running {description}"))?;
    if output.status.success() {
        Ok(output)
    } else {
        anyhow::bail!(
            "{description} exited with {}:\n{}{}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
    }
}

pub(crate) fn platform_from_build_info(build_info: &str) -> Result<Platform> {
    let system = build_info
        .lines()
        .find_map(|line| line.strip_prefix("system="))
        .context("build-info.txt has no system entry")?;
    match system {
        "Linux" => Ok(Platform::Linux),
        "macOS" => Ok(Platform::Macos),
        "Windows" => Ok(Platform::Windows),
        _ => anyhow::bail!("unsupported packaged system {system:?}"),
    }
}

pub(crate) fn display_name(path: &Path) -> &str {
    path.file_name()
        .and_then(OsStr::to_str)
        .unwrap_or("<binary>")
}

pub(crate) fn is_system_library(platform: Platform, library: &str) -> bool {
    match platform {
        Platform::Macos => MACOS_SYSTEM_PREFIXES
            .iter()
            .any(|prefix| library.starts_with(prefix)),
        Platform::Linux => LINUX_SYSTEM_LIBRARIES.contains(&library),
        Platform::Windows => {
            let library = library.to_ascii_lowercase();
            WINDOWS_SYSTEM_LIBRARIES.contains(&library.as_str())
                || library.starts_with("api-ms-win-")
                || library.starts_with("ext-ms-win-")
        }
    }
}

pub(crate) fn contained_search_path(prefix: &Path, binary: &Path, rpath: &str) -> bool {
    resolved_search_path(prefix, binary, rpath).is_some()
}

pub(crate) fn resolved_search_path(prefix: &Path, binary: &Path, rpath: &str) -> Option<PathBuf> {
    let (base, relative) = if let Some(relative) = rpath.strip_prefix("$ORIGIN") {
        (binary.parent().unwrap_or(prefix).to_path_buf(), relative)
    } else if let Some(relative) = rpath.strip_prefix("@loader_path") {
        (binary.parent().unwrap_or(prefix).to_path_buf(), relative)
    } else {
        let relative = rpath.strip_prefix("@executable_path")?;
        (prefix.join("bin"), relative)
    };
    lexical_path_within(prefix, &base, relative)
}

pub(crate) fn dependency_is_reachable(
    prefix: &Path,
    binary: &Path,
    rpaths: &[String],
    application_search_paths: &[PathBuf],
    library: &str,
    platform: Platform,
) -> bool {
    if let Some(name) = library.strip_prefix("@rpath/") {
        return rpaths
            .iter()
            .filter_map(|rpath| resolved_search_path(prefix, binary, rpath))
            .chain(application_search_paths.iter().cloned())
            .any(|directory| directory_contains(&directory, name, false));
    }
    if let Some(relative) = library.strip_prefix("@loader_path") {
        return lexical_path_within(prefix, binary.parent().unwrap_or(prefix), relative)
            .is_some_and(|path| path.exists());
    }
    if let Some(relative) = library.strip_prefix("@executable_path") {
        return lexical_path_within(prefix, &prefix.join("bin"), relative)
            .is_some_and(|path| path.exists());
    }
    if library.contains('/') {
        return false;
    }
    match platform {
        Platform::Macos | Platform::Linux => rpaths
            .iter()
            .filter_map(|rpath| resolved_search_path(prefix, binary, rpath))
            .chain(
                (platform == Platform::Macos)
                    .then_some(application_search_paths.iter().cloned())
                    .into_iter()
                    .flatten(),
            )
            .any(|directory| directory_contains(&directory, library, false)),
        Platform::Windows => directory_contains(&prefix.join("bin"), library, true),
    }
}

fn directory_contains(directory: &Path, name: &str, case_insensitive: bool) -> bool {
    if !case_insensitive {
        return directory.join(name).exists();
    }
    let expected = name.to_ascii_lowercase();
    fs::read_dir(directory).is_ok_and(|entries| {
        entries.filter_map(Result::ok).any(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .eq_ignore_ascii_case(&expected)
        })
    })
}

fn lexical_path_within(prefix: &Path, base: &Path, relative: &str) -> Option<PathBuf> {
    let mut path = base.to_path_buf();
    for component in Path::new(relative.trim_start_matches('/')).components() {
        use std::path::Component;
        match component {
            Component::CurDir => {}
            Component::Normal(part) => path.push(part),
            Component::ParentDir => {
                path.pop();
            }
            Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    path.starts_with(prefix).then_some(path)
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;

    use tempfile::tempdir;

    use super::{
        dependency_is_reachable, is_shared_library, is_system_library, lexical_path_within,
        platform_from_build_info, Platform,
    };

    #[test]
    fn binary_discovery_excludes_shader_data_and_manifests() {
        let prefix = tempdir().unwrap();
        for name in [
            "bin/tecs-host",
            "bin/tecs-host.exe",
            "bin/shaders.tecspack",
            "bin/shaders.tecspack.txt",
            "lib/libnupp.so",
            "lib/libservice.so.1",
        ] {
            let path = prefix.path().join(name);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, "content").unwrap();
        }
        let found: Vec<_> = super::binaries(prefix.path())
            .unwrap()
            .into_iter()
            .map(|path| path.strip_prefix(prefix.path()).unwrap().to_path_buf())
            .collect();
        assert_eq!(
            found,
            [
                Path::new("bin/tecs-host"),
                Path::new("bin/tecs-host.exe"),
                Path::new("lib/libnupp.so"),
                Path::new("lib/libservice.so.1"),
            ]
        );
    }

    #[test]
    fn identifies_versioned_elf_libraries() {
        assert!(is_shared_library(Path::new("libtecsphysics.so.0")));
        assert!(is_shared_library(Path::new("libtecsphysics.so.0.2.4")));
        assert!(is_shared_library(Path::new("tecsphysics.dll")));
        assert!(!is_shared_library(Path::new("libtecsphysics.a")));
    }

    #[test]
    fn reads_the_package_target_from_build_info() {
        assert_eq!(
            platform_from_build_info("systemDeps=false\nsystem=Windows\narch=x86_64\n").unwrap(),
            Platform::Windows
        );
    }

    #[test]
    fn resolves_windows_dlls_from_bin_without_case() {
        let prefix = tempdir().unwrap();
        let bin = prefix.path().join("bin");
        fs::create_dir_all(&bin).unwrap();
        fs::write(bin.join("tecsphysics.dll"), b"dll").unwrap();
        assert!(dependency_is_reachable(
            prefix.path(),
            &bin.join("tecs.exe"),
            &[],
            &[],
            "tecsphysics.DLL",
            Platform::Windows
        ));
        assert!(!dependency_is_reachable(
            prefix.path(),
            &bin.join("tecs.exe"),
            &[],
            &[],
            "tecsaudio.dll",
            Platform::Windows
        ));
    }

    #[test]
    fn applies_platform_system_library_allowlists() {
        assert!(is_system_library(Platform::Linux, "libc.so.6"));
        assert!(is_system_library(Platform::Linux, "libasound.so.2"));
        assert!(is_system_library(Platform::Linux, "libudev.so.1"));
        assert!(!is_system_library(Platform::Linux, "libshaderc_shared.so"));
        assert!(!is_system_library(Platform::Linux, "libtecsphysics.so.0"));
        assert!(is_system_library(Platform::Windows, "KERNEL32.DLL"));
        assert!(is_system_library(
            Platform::Windows,
            "api-ms-win-core-file-l1-2-0.dll"
        ));
        assert!(!is_system_library(Platform::Windows, "tecsphysics.dll"));
    }

    #[test]
    fn rejects_search_paths_that_escape_the_package() {
        let prefix = Path::new("/package");
        assert!(lexical_path_within(prefix, Path::new("/package/bin"), "../lib").is_some());
        assert!(lexical_path_within(prefix, Path::new("/package/bin"), "../../outside").is_none());
    }

    #[test]
    fn dependencies_must_be_in_a_modeled_search_directory() {
        let prefix = tempdir().unwrap();
        let bin = prefix.path().join("bin");
        let lib = prefix.path().join("lib");
        let unrelated = prefix.path().join("share/tecs");
        fs::create_dir_all(&bin).unwrap();
        fs::create_dir_all(&lib).unwrap();
        fs::create_dir_all(&unrelated).unwrap();
        fs::write(lib.join("libtecsphysics.so.0"), b"library").unwrap();
        fs::write(unrelated.join("liborphan.so"), b"library").unwrap();
        let binary = bin.join("tecs");
        let rpaths = vec!["$ORIGIN/../lib".to_owned()];

        assert!(dependency_is_reachable(
            prefix.path(),
            &binary,
            &rpaths,
            &[],
            "libtecsphysics.so.0",
            Platform::Linux
        ));
        assert!(!dependency_is_reachable(
            prefix.path(),
            &binary,
            &rpaths,
            &[],
            "liborphan.so",
            Platform::Linux
        ));
    }

    #[test]
    fn rpath_dependencies_resolve_through_declared_search_paths() {
        let prefix = tempdir().unwrap();
        let bin = prefix.path().join("bin");
        let lib = prefix.path().join("lib");
        fs::create_dir_all(&bin).unwrap();
        fs::create_dir_all(&lib).unwrap();
        fs::write(lib.join("libworker.dylib"), b"library").unwrap();
        let binary = bin.join("tecs");
        let rpaths = vec!["@executable_path/../lib".to_owned()];

        assert!(dependency_is_reachable(
            prefix.path(),
            &binary,
            &rpaths,
            &[],
            "@rpath/libworker.dylib",
            Platform::Macos
        ));
        assert!(!dependency_is_reachable(
            prefix.path(),
            &binary,
            &rpaths,
            &[],
            "@rpath/libmissing.dylib",
            Platform::Macos
        ));
        assert!(dependency_is_reachable(
            prefix.path(),
            &lib.join("libconsumer.dylib"),
            &[],
            std::slice::from_ref(&lib),
            "@rpath/libworker.dylib",
            Platform::Macos
        ));
    }
}
