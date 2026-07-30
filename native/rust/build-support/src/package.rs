use std::collections::BTreeSet;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use anyhow::{Context, Result};
use regex::Regex;
use tempfile::tempdir;
use walkdir::WalkDir;

const MACOS_SYSTEM_PREFIXES: &[&str] = &["/usr/lib/", "/System/Library/"];
const LINUX_SYSTEM_LIBRARIES: &[&str] = &[
    "ld-linux-aarch64.so.1",
    "ld-linux-x86-64.so.2",
    "libc.so.6",
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
const COMPILER_NAMES: &[&str] = &["shaderc", "spirvcross", "spirv-cross", "dxcompiler"];
const LINKED_LIBRARIES: &[(&str, &str, &str)] = &[
    (r"tecs\w*", "MIT OR Apache-2.0", "the engine's own"),
    (
        r"spirvcrossc",
        "Apache-2.0 OR MIT",
        "the shared FFI library over SPIRV-Cross",
    ),
    (r"cjson", "MIT", "the vendored lua-cjson"),
    (
        r"SDL3(_mixer|_ttf)?",
        "Zlib",
        "SDL and its audio and font satellites",
    ),
    (
        r"(luajit|lua51)",
        "MIT",
        "the VM, including PUC-Rio Lua's notice",
    ),
    (
        r"shaderc(_shared)?",
        "Apache-2.0",
        "the development shader compiler",
    ),
    (r"z(lib)?", "Zlib", "the public deflate service"),
    (
        r"(ogg|opus|opusfile)",
        "BSD-3-Clause",
        "SDL_mixer's Opus decoder",
    ),
    (r"wavpack", "BSD-3-Clause", "SDL_mixer's WavPack decoder"),
    (
        r"freetype",
        "FTL OR GPL-2.0-only",
        "SDL_ttf's font rasterizer",
    ),
    (r"harfbuzz", "MIT", "SDL_ttf's text shaper"),
];
const REQUIRED_NOTICES: &[&str] = &[
    "share/tecs/THIRD_PARTY_NOTICES.md",
    "share/tecs/LICENSE-MIT",
    "share/tecs/LICENSE-APACHE",
];
const GLOBAL_USAGE: &str = r#"
local world = tecs.ecs.newWorld()
world:update(1 / 60)
tecs.log.get("game"):info("entities: %d", world:getStats().entities)

return tecs.newApplication({
    plugin = function(world: tecs.World, app: tecs.Application)
        print(world ~= nil and app.world ~= nil)
    end,
})
"#;

pub struct Options<'a> {
    pub prefix: &'a Path,
    pub allow_compiler: bool,
    pub teal_compiler: &'a Path,
    pub teal_types: Option<&'a Path>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Platform {
    Linux,
    Macos,
    Windows,
}

pub fn check(options: &Options<'_>) -> Result<()> {
    let prefix = options
        .prefix
        .canonicalize()
        .with_context(|| format!("no such install prefix: {}", options.prefix.display()))?;
    let info = prefix.join("share/tecs/build-info.txt");
    let build_info =
        fs::read_to_string(&info).with_context(|| format!("reading {}", info.display()))?;
    let development =
        build_info.contains("systemDeps=ON") || build_info.contains("systemDeps=true");
    let platform = platform_from_build_info(&build_info)?;
    let binaries = binaries(&prefix)?;
    if binaries.is_empty() {
        anyhow::bail!("no binaries found under {}", prefix.display());
    }
    let inspections = binaries
        .iter()
        .map(|binary| Ok((binary, references(binary, platform)?)))
        .collect::<Result<Vec<_>>>()?;
    let application_search_paths: Vec<_> = if platform == Platform::Macos {
        inspections
            .iter()
            .filter(|(binary, _)| {
                binary.parent() == Some(prefix.join("bin").as_path()) && !is_shared_library(binary)
            })
            .flat_map(|(binary, (rpaths, _))| {
                rpaths
                    .iter()
                    .filter_map(|rpath| resolved_search_path(&prefix, binary, rpath))
            })
            .collect()
    } else {
        Vec::new()
    };

    let mut license_problems = Vec::new();
    for notice in REQUIRED_NOTICES {
        if !prefix.join(notice).exists() {
            license_problems.push(format!(
                "no {notice}: a package that ships the code has to ship the notice"
            ));
        }
    }

    let mut problems = Vec::new();
    for (binary, (rpaths, libraries)) in &inspections {
        check_licenses(binary, libraries, platform, &mut license_problems)?;
        for rpath in rpaths {
            if !contained_search_path(&prefix, binary, rpath) {
                problems.push(format!(
                    "{}: search path leaves the package: {rpath}",
                    display_name(binary)
                ));
            }
        }
        for library in libraries {
            if library.starts_with('/') && !is_system_library(platform, library) {
                problems.push(format!(
                    "{}: links an absolute path: {library}",
                    display_name(binary)
                ));
            } else if !is_system_library(platform, library)
                && !dependency_is_reachable(
                    &prefix,
                    binary,
                    rpaths,
                    &application_search_paths,
                    library,
                    platform,
                )
            {
                problems.push(format!(
                    "{}: links {library}, but no packaged loader search path reaches it",
                    display_name(binary)
                ));
            }
        }
        if !options.allow_compiler {
            let name = binary
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or_default()
                .to_lowercase();
            for compiler in COMPILER_NAMES {
                if name.contains(compiler) {
                    problems.push(format!(
                        "{name}: a shader compiler must not ship in a release"
                    ));
                }
            }
        }
    }

    let packs = files_with_suffix(&prefix, "tsp")?;
    if packs.is_empty() {
        problems.push(
            "no shader pack (*.tsp): a release ships no compiler, so it must ship compiled shaders"
                .to_owned(),
        );
    }
    for pack in packs {
        let manifest = PathBuf::from(format!("{}.txt", pack.display()));
        if !manifest.exists() {
            problems.push(format!(
                "{}: no manifest beside it, so what it contains cannot be checked",
                pack.file_name()
                    .and_then(|value| value.to_str())
                    .unwrap_or("<shader pack>")
            ));
        } else {
            let source = fs::read_to_string(&manifest)?;
            if let Some(summary) = source.lines().nth(1) {
                println!("{}: {summary}", pack.strip_prefix(&prefix)?.display());
            }
        }
    }

    let mut type_problems = Vec::new();
    check_teal_types(
        &prefix,
        options.teal_compiler,
        options.teal_types,
        &mut type_problems,
    )?;
    println!(
        "checked {} binaries under {}",
        binaries.len(),
        prefix.display()
    );

    if !license_problems.is_empty() {
        let unique: BTreeSet<_> = license_problems.into_iter().collect();
        anyhow::bail!(
            "{} problems with the license position:\n{}",
            unique.len(),
            unique
                .into_iter()
                .map(|problem| format!("  {problem}"))
                .collect::<Vec<_>>()
                .join("\n")
        );
    }
    println!(
        "{} declared dependencies, and the notices to go with them",
        LINKED_LIBRARIES.len()
    );
    if !type_problems.is_empty() {
        anyhow::bail!(
            "{} problems with the packaged types:\n{}",
            type_problems.len(),
            type_problems
                .into_iter()
                .map(|problem| format!("  {problem}"))
                .collect::<Vec<_>>()
                .join("\n")
        );
    }
    if development {
        println!("\ndevelopment install: dependency containment was NOT checked.");
        println!("Build a packaged preset with `cargo xtask package --preset <name>`.");
        if !problems.is_empty() {
            println!(
                "\n{} references to the build machine, which a packaged preset would not have:",
                problems.len()
            );
            for problem in problems {
                println!("  {problem}");
            }
        }
        return Ok(());
    }
    if !problems.is_empty() {
        anyhow::bail!(
            "{} problems:\n{}",
            problems.len(),
            problems
                .into_iter()
                .map(|problem| format!("  {problem}"))
                .collect::<Vec<_>>()
                .join("\n")
        );
    }
    println!("package is self-contained");
    Ok(())
}

fn binaries(prefix: &Path) -> Result<Vec<PathBuf>> {
    let mut binaries: Vec<_> = WalkDir::new(prefix)
        .into_iter()
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|entry| entry.file_type().is_file() || entry.file_type().is_symlink())
        .filter(|entry| {
            let path = entry.path();
            is_shared_library(path)
                || path
                    .parent()
                    .and_then(Path::file_name)
                    .and_then(|value| value.to_str())
                    == Some("bin")
        })
        .map(|entry| entry.into_path())
        .collect();
    binaries.sort();
    Ok(binaries)
}

fn is_shared_library(path: &Path) -> bool {
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

fn files_with_suffix(prefix: &Path, extension: &str) -> Result<Vec<PathBuf>> {
    Ok(WalkDir::new(prefix)
        .into_iter()
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|entry| {
            entry.file_type().is_file()
                && entry.path().extension().and_then(|value| value.to_str()) == Some(extension)
        })
        .map(|entry| entry.into_path())
        .collect())
}

fn check_teal_types(
    prefix: &Path,
    teal_compiler: &Path,
    teal_types: Option<&Path>,
    problems: &mut Vec<String>,
) -> Result<()> {
    let teal = prefix.join("share/tecs/teal");
    if !teal.join("tecs/global.d.tl").exists() {
        problems.push(
            "no tecs/global.d.tl under share/tecs/teal: a game's `tl check` has no `tecs` global"
                .to_owned(),
        );
        return Ok(());
    }
    let Some(teal_types) = teal_types else {
        problems.push(
            "no Teal types directory was given, so the packaged declarations cannot be checked"
                .to_owned(),
        );
        return Ok(());
    };
    let teal_compiler = teal_compiler
        .canonicalize()
        .with_context(|| format!("no such Teal compiler: {}", teal_compiler.display()))?;
    let teal_types = teal_types
        .canonicalize()
        .with_context(|| format!("no such Teal types directory: {}", teal_types.display()))?;
    let directory = tempdir()?;
    let usage = directory.path().join("usage.tl");
    fs::write(&usage, GLOBAL_USAGE)?;
    let result = Command::new(&teal_compiler)
        .args(["--global-env-def", "tecs.global", "-I"])
        .arg(&teal_types)
        .arg("-I")
        .arg(&teal)
        .arg("check")
        .arg(&usage)
        .current_dir(directory.path())
        .output()
        .context("running packaged Teal type check")?;
    let stdout = String::from_utf8_lossy(&result.stdout);
    if !result.status.success() || !stdout.contains("0 errors detected") {
        problems
            .push("the packaged Teal types do not check a file using the `tecs` global:".into());
        let detail = format!("{}{}", stdout, String::from_utf8_lossy(&result.stderr));
        problems.extend(detail.lines().map(|line| format!("  {line}")));
    } else {
        println!(
            "{}: types a file using the `tecs` global",
            teal.strip_prefix(prefix)?.display()
        );
    }
    Ok(())
}

fn library_stem(reference: &str) -> Result<String> {
    let name = reference.rsplit('/').next().unwrap_or(reference);
    let shared = Regex::new(r"(?i)\.(dylib|so)(\.[\d.]+)?$|\.dll$")?;
    let versions = Regex::new(r"\.[\d.]+$")?;
    let suffix = Regex::new(r"-[\d.]+$")?;
    let name = shared.replace(name, "");
    let name = versions.replace(&name, "");
    let name = suffix.replace(&name, "");
    Ok(name.strip_prefix("lib").unwrap_or(&name).to_owned())
}

fn check_licenses(
    binary: &Path,
    libraries: &[String],
    platform: Platform,
    problems: &mut Vec<String>,
) -> Result<()> {
    let patterns: Vec<_> = LINKED_LIBRARIES
        .iter()
        .map(|(pattern, _, _)| Regex::new(&format!("^(?:{pattern})$")))
        .collect::<Result<_, _>>()?;
    for library in libraries {
        if is_system_library(platform, library) {
            continue;
        }
        let stem = library_stem(library)?;
        if !patterns.iter().any(|pattern| pattern.is_match(&stem)) {
            problems.push(format!(
                "{}: links {stem}, which is not a declared dependency. Add it with its license and reason, or remove it. Tecs brings in no LGPL.",
                binary.file_name().and_then(|value| value.to_str()).unwrap_or("<binary>")
            ));
        }
    }
    Ok(())
}

fn references(binary: &Path, platform: Platform) -> Result<(Vec<String>, Vec<String>)> {
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

fn platform_from_build_info(build_info: &str) -> Result<Platform> {
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

fn display_name(path: &Path) -> &str {
    path.file_name()
        .and_then(OsStr::to_str)
        .unwrap_or("<binary>")
}

fn is_system_library(platform: Platform, library: &str) -> bool {
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

fn contained_search_path(prefix: &Path, binary: &Path, rpath: &str) -> bool {
    resolved_search_path(prefix, binary, rpath).is_some()
}

fn resolved_search_path(prefix: &Path, binary: &Path, rpath: &str) -> Option<PathBuf> {
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

fn dependency_is_reachable(
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
        library_stem, platform_from_build_info, Platform,
    };

    #[test]
    fn normalizes_shared_library_names() {
        assert_eq!(
            library_stem("@rpath/libluajit-5.1.2.dylib").unwrap(),
            "luajit"
        );
        assert_eq!(library_stem("libSDL3.so.0").unwrap(), "SDL3");
        assert_eq!(library_stem("z.dll").unwrap(), "z");
        assert_eq!(library_stem("SDL3_MIXER.DLL").unwrap(), "SDL3_MIXER");
    }

    #[test]
    fn identifies_versioned_elf_libraries() {
        assert!(is_shared_library(Path::new("libSDL3.so.0")));
        assert!(is_shared_library(Path::new("libSDL3.so.0.2.4")));
        assert!(is_shared_library(Path::new("SDL3.dll")));
        assert!(!is_shared_library(Path::new("libSDL3.a")));
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
        fs::write(bin.join("SDL3.dll"), b"dll").unwrap();
        assert!(dependency_is_reachable(
            prefix.path(),
            &bin.join("tecs.exe"),
            &[],
            &[],
            "sdl3.DLL",
            Platform::Windows
        ));
        assert!(!dependency_is_reachable(
            prefix.path(),
            &bin.join("tecs.exe"),
            &[],
            &[],
            "SDL3_mixer.dll",
            Platform::Windows
        ));
    }

    #[test]
    fn applies_platform_system_library_allowlists() {
        assert!(is_system_library(Platform::Linux, "libc.so.6"));
        assert!(!is_system_library(Platform::Linux, "libSDL3.so.0"));
        assert!(is_system_library(Platform::Windows, "KERNEL32.DLL"));
        assert!(is_system_library(
            Platform::Windows,
            "api-ms-win-core-file-l1-2-0.dll"
        ));
        assert!(!is_system_library(Platform::Windows, "SDL3.dll"));
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
        fs::write(lib.join("libSDL3.so.0"), b"library").unwrap();
        fs::write(unrelated.join("liborphan.so"), b"library").unwrap();
        let binary = bin.join("tecs");
        let rpaths = vec!["$ORIGIN/../lib".to_owned()];

        assert!(dependency_is_reachable(
            prefix.path(),
            &binary,
            &rpaths,
            &[],
            "libSDL3.so.0",
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

    #[cfg(unix)]
    #[test]
    fn packaged_type_check_uses_the_explicit_compiler() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        use tempfile::tempdir;

        use super::check_teal_types;

        let directory = tempdir().unwrap();
        let prefix = directory.path().join("package");
        let teal = prefix.join("share/tecs/teal/tecs");
        let types = directory.path().join("types");
        fs::create_dir_all(&teal).unwrap();
        fs::create_dir_all(&types).unwrap();
        fs::write(teal.join("global.d.tl"), b"global tecs: {}\n").unwrap();
        let compiler = directory.path().join("tl");
        fs::write(&compiler, b"#!/bin/sh\nprintf '0 errors detected\\n'\n").unwrap();
        let mut permissions = fs::metadata(&compiler).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&compiler, permissions).unwrap();
        let mut problems = Vec::new();

        check_teal_types(&prefix, &compiler, Some(&types), &mut problems).unwrap();

        assert!(problems.is_empty());
    }

    #[test]
    fn packaged_type_check_requires_a_types_directory() {
        use std::fs;

        use tempfile::tempdir;

        use super::check_teal_types;

        let directory = tempdir().unwrap();
        let prefix = directory.path().join("package");
        let teal = prefix.join("share/tecs/teal/tecs");
        fs::create_dir_all(&teal).unwrap();
        fs::write(teal.join("global.d.tl"), b"global tecs: {}\n").unwrap();
        let mut problems = Vec::new();

        check_teal_types(
            &prefix,
            directory.path().join("missing-tl").as_path(),
            None,
            &mut problems,
        )
        .unwrap();

        assert_eq!(problems.len(), 1);
        assert!(problems[0].contains("no Teal types directory"));
    }
}
