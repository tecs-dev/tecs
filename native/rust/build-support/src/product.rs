use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result};
use regex::Regex;
use walkdir::WalkDir;

use crate::cdef::{self, Options as CdefOptions};
use crate::command;
use crate::payload::{self, Root as PayloadRoot};
use crate::presets::{DependencyMode, Preset, ShaderMode};
use crate::registry::{self, Options as RegistryOptions};
use crate::{staging, tooling};

pub const TEAL_REVISION: &str = "1326d829790b92e23defe69fcf40460103b60d1d";
pub const CERULEAN_REVISION: &str = "a09b6d734a55d58489e16498bd83387d39c4cafe";
pub const TEALDOC_REVISION: &str = "83548b9ab5262c581c228e3762181a4b07be061f";
pub const SDL3_REVISION: &str = "release-3.4.12";
pub const SDL3_MIXER_REVISION: &str = "release-3.2.4";
pub const LUAJIT_REVISION: &str = "871db2c84ecefd70a850e03a6c340214a81739f0";
pub const LUAJIT_ROLLING: &str = "2.1.1753364724";
pub const SHADERC_REVISION: &str = "v2026.3";
pub const GLSLANG_REVISION: &str = "168d452a4f460d24b588fed08477a81c44ee27a1";
pub const SPIRV_TOOLS_REVISION: &str = "b707790a898e44038547df54580022fc1cf89c3d";
pub const SPIRV_HEADERS_REVISION: &str = "29981f65241605e08b0ede4cfeb999fe3b723c6a";
pub const SPIRV_CROSS_REVISION: &str = "vulkan-sdk-1.4.313.0";
pub const ZLIB_REVISION: &str = "v1.3.2";

const C_WARNINGS: &[&str] = &[
    "-Wall",
    "-Wextra",
    "-Wvla",
    "-Wconversion",
    "-Wshadow",
    "-Wpointer-arith",
    "-Wstrict-prototypes",
    "-Wmissing-prototypes",
    "-Wold-style-definition",
    "-Wredundant-decls",
    "-Wwrite-strings",
    "-Wdouble-promotion",
    "-Wformat=2",
    "-Wundef",
    "-Wcast-align",
    "-Wnull-dereference",
];

const CJSON_SOURCES: &[&str] = &[
    "vendor/cjson/lua_cjson.c",
    "vendor/cjson/strbuf.c",
    "vendor/cjson/g_fmt.c",
    "vendor/cjson/dtoa.c",
];

#[derive(Debug)]
struct Paths {
    out: PathBuf,
    lua: PathBuf,
    teal: PathBuf,
    spec: PathBuf,
    generated: PathBuf,
    objects: PathBuf,
    library: PathBuf,
    binary: PathBuf,
    cargo: PathBuf,
    notices: PathBuf,
    dependencies: PathBuf,
}

impl Paths {
    fn new(root: &Path, preset: Preset) -> Self {
        let out = root.join("out").join(preset.name);
        Self {
            lua: out.join("lua"),
            teal: out.join("teal"),
            spec: out.join("spec"),
            generated: out.join("generated"),
            objects: out.join("objects"),
            library: out.join("lib"),
            binary: out.join("bin"),
            cargo: out.join("cargo"),
            notices: out.join("notices"),
            dependencies: out.join("dependencies"),
            out,
        }
    }

    fn create(&self) -> Result<()> {
        for path in [
            &self.lua,
            &self.teal,
            &self.spec,
            &self.generated,
            &self.objects,
            &self.library,
            &self.binary,
            &self.cargo,
            &self.notices,
            &self.dependencies,
        ] {
            fs::create_dir_all(path)?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
struct Package {
    name: &'static str,
    includes: Vec<PathBuf>,
    library_directories: Vec<PathBuf>,
    libraries: Vec<String>,
}

pub fn build(root: &Path, preset: Preset) -> Result<PathBuf> {
    let paths = Paths::new(root, preset);
    paths.create()?;
    preflight(root, preset)?;
    match preset.dependencies {
        DependencyMode::System => build_system(root, preset, &paths),
        DependencyMode::Packaged | DependencyMode::Single => build_pinned(root, preset, &paths),
    }
}

pub fn check(root: &Path) -> Result<()> {
    let mut sources = teal_sources(&root.join("src"))?;
    sources.extend(teal_sources(&root.join("bench"))?);
    sources.extend(cli_sources(&root.join("cli"))?);
    sources.push(root.join("main.tl"));
    let mut command = Command::new(root.join("vendor/bin/tl"));
    command
        .arg("check")
        .arg("-I")
        .arg(root.join("vendor/share/lua/5.1"))
        .arg("-I")
        .arg(root.join("vendor/tl"))
        .arg("-I")
        .arg(root.join("cli"))
        .args(sources)
        .current_dir(root);
    run(&mut command, "Teal type checking")
}

pub fn run_demo(root: &Path, preset: Preset, arguments: &[OsString]) -> Result<()> {
    let executable = build(root, preset)?;
    let paths = Paths::new(root, preset);
    let entry = compile_teal_file(root, &paths, &root.join("main.tl"), "main.lua")?;
    let mut command = Command::new(executable);
    command
        .arg("--entry")
        .arg(entry)
        .args(arguments)
        .current_dir(root);
    apply_development_environment(&mut command, &paths);
    run(&mut command, "Tecs demo")
}

pub fn test(root: &Path, preset: Preset) -> Result<()> {
    build(root, preset)?;
    let paths = Paths::new(root, preset);
    for arguments in [
        ["--pattern", "headless_spec"],
        ["--exclude-pattern", "headless_spec"],
    ] {
        let mut command = Command::new("busted");
        command.args(arguments).current_dir(root);
        apply_development_environment(&mut command, &paths);
        run(&mut command, "Busted spec suite")?;
    }
    Ok(())
}

pub fn shaders(root: &Path, preset: Preset) -> Result<()> {
    build(root, preset)?;
    let paths = Paths::new(root, preset);
    let mut command = Command::new("luajit");
    command
        .arg(root.join("scripts/buildshaders.lua"))
        .current_dir(root);
    apply_development_environment(&mut command, &paths);
    run(&mut command, "shader pack build")
}

pub fn abi_check(root: &Path, preset: Preset) -> Result<()> {
    build(root, preset)?;
    let paths = Paths::new(root, preset);
    crate::abi::check(root, &paths.lua.join("tecs/ffi")).map(|_| ())
}

pub fn install_package(root: &Path, preset: Preset) -> Result<PathBuf> {
    if !matches!(preset.dependencies, DependencyMode::Packaged) {
        anyhow::bail!(
            "{} is not a packaged preset; choose one listed as packaged by `cargo xtask presets`",
            preset.name
        );
    }
    build(root, preset)?;
    let paths = Paths::new(root, preset);
    compile_teal_file(root, &paths, &root.join("main.tl"), "lua/main.lua")?;
    let shader_host = crate::presets::host_default()?;
    shaders(root, shader_host)?;
    let host_paths = Paths::new(root, shader_host);
    fs::copy(
        host_paths.lua.join("shaders.tsp"),
        paths.lua.join("shaders.tsp"),
    )?;
    fs::copy(
        host_paths.lua.join("shaders.tsp.txt"),
        paths.lua.join("shaders.tsp.txt"),
    )?;
    let prefix = root.join("out/package");
    if prefix.exists() {
        fs::remove_dir_all(&prefix)?;
    }
    fs::create_dir_all(prefix.join("bin"))?;
    fs::create_dir_all(prefix.join("lib"))?;
    fs::create_dir_all(prefix.join("share/tecs"))?;
    fs::copy(
        paths.binary.join(executable_name()),
        prefix.join("bin").join(executable_name()),
    )?;
    copy_dynamic_libraries(&paths.library, &prefix.join("lib"))?;
    copy_runtime_dependencies(&paths.dependencies.join("prefix/lib"), &prefix.join("lib"))?;
    copy_tree(&paths.lua, &prefix.join("share/tecs/lua"), false)?;
    copy_tree(&paths.teal, &prefix.join("share/tecs/teal"), false)?;
    copy_tree(&paths.notices, &prefix.join("share/tecs"), false)?;
    fs::copy(
        paths.out.join("build-info.txt"),
        prefix.join("share/tecs/build-info.txt"),
    )?;
    Ok(prefix)
}

pub fn single(root: &Path) -> Result<PathBuf> {
    let preset: Preset = "macos-arm64-single".parse()?;
    let executable = build(root, preset)?;
    let destination = root.join("out/single/bin/tecs");
    fs::create_dir_all(
        destination
            .parent()
            .context("single-file destination has no parent")?,
    )?;
    fs::copy(executable, &destination)?;
    Ok(destination)
}

pub fn test_package(root: &Path, preset: Preset) -> Result<()> {
    let prefix = install_package(root, preset)?;
    let paths = Paths::new(root, preset);
    crate::package::check(&crate::package::Options {
        prefix: &prefix,
        allow_compiler: false,
        teal_types: Some(&root.join("vendor/share/lua/5.1")),
    })?;

    let mut specs = Command::new("busted");
    specs
        .args(["--pattern", "headless_spec"])
        .current_dir(root)
        .env("TECS_LUA", prefix.join("share/tecs/lua"))
        .env("TECS_LIB", prefix.join("lib"))
        .env("TECS_ASSETS", prefix.join("share/tecs/lua"))
        .env("TECS_SPEC", &paths.spec);
    run(&mut specs, "packaged headless spec suite")?;
    Ok(())
}

pub fn benchmark(root: &Path, preset: Preset, name: &str, arguments: &[OsString]) -> Result<()> {
    let source = match name {
        "shapes" | "physics" | "sprites" | "text" | "particles" | "latency" => name,
        "alloc" | "allocation" => "allocation",
        _ => anyhow::bail!(
            "unknown host benchmark {name:?}; expected shapes, physics, sprites, text, \
             particles, latency, or allocation"
        ),
    };
    let executable = build(root, preset)?;
    let paths = Paths::new(root, preset);
    let entry = compile_teal_file(
        root,
        &paths,
        &root.join("bench").join(format!("{source}.tl")),
        &format!("bench/{source}.lua"),
    )?;
    let mut command = Command::new(executable);
    command
        .arg("--entry")
        .arg(entry)
        .args(arguments)
        .current_dir(root);
    apply_development_environment(&mut command, &paths);
    run(&mut command, &format!("{source} benchmark"))
}

fn copy_dynamic_libraries(source: &Path, destination: &Path) -> Result<()> {
    copy_dynamic_libraries_if(source, destination, |_| true)
}

fn copy_runtime_dependencies(source: &Path, destination: &Path) -> Result<()> {
    copy_dynamic_libraries_if(source, destination, |name| {
        let lowered = name.to_ascii_lowercase();
        ["sdl3", "sdl3_mixer", "luajit", "lua51", "libz", "zlib"]
            .iter()
            .any(|library| lowered.contains(library))
    })
}

fn copy_dynamic_libraries_if(
    source: &Path,
    destination: &Path,
    wanted: impl Fn(&str) -> bool,
) -> Result<()> {
    if !source.is_dir() {
        return Ok(());
    }
    for entry in WalkDir::new(source).max_depth(1) {
        let entry = entry?;
        if !entry.file_type().is_file() && !entry.file_type().is_symlink() {
            continue;
        }
        let name = entry.file_name().to_string_lossy();
        if (name.ends_with(".dylib")
            || name.ends_with(".so")
            || name.contains(".so.")
            || name.ends_with(".dll"))
            && wanted(&name)
        {
            let target = destination.join(entry.file_name());
            if entry.file_type().is_symlink() {
                copy_library_symlink(entry.path(), &target)?;
            } else {
                fs::copy(entry.path(), target)?;
            }
        }
    }
    Ok(())
}

#[cfg(unix)]
fn copy_library_symlink(source: &Path, destination: &Path) -> Result<()> {
    std::os::unix::fs::symlink(fs::read_link(source)?, destination)?;
    Ok(())
}

#[cfg(not(unix))]
fn copy_library_symlink(source: &Path, destination: &Path) -> Result<()> {
    fs::copy(source, destination)?;
    Ok(())
}

fn compile_teal_file(
    root: &Path,
    paths: &Paths,
    source: &Path,
    relative_output: &str,
) -> Result<PathBuf> {
    let output = paths.out.join(relative_output);
    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut command = Command::new(root.join("vendor/bin/tl"));
    command
        .arg("gen")
        .arg("-I")
        .arg(root.join("vendor/share/lua/5.1"))
        .arg("-I")
        .arg(root.join("vendor/tl"))
        .arg("-I")
        .arg(root.join("cli"))
        .arg(source)
        .arg("-o")
        .arg(&output)
        .current_dir(root);
    run(
        &mut command,
        &format!("Teal compilation of {}", source.display()),
    )?;
    Ok(output)
}

fn apply_development_environment(command: &mut Command, paths: &Paths) {
    command
        .env("TECS_LUA", &paths.lua)
        .env("TECS_LIB", &paths.library)
        .env("TECS_ASSETS", &paths.lua)
        .env("TECS_SPEC", &paths.spec);
}

fn preflight(root: &Path, preset: Preset) -> Result<()> {
    command::run("cargo", ["fmt", "--all", "--", "--check"], root)?;
    let mut clippy = Command::new("cargo");
    clippy
        .args([
            "clippy",
            "--workspace",
            "--all-targets",
            "--locked",
            "--target",
        ])
        .arg(preset.rust_target)
        .arg("--release")
        .current_dir(root);
    if preset.is_single() {
        clippy.arg("--features").arg("tecs-native/payload");
    }
    clippy.args(["--", "-D", "warnings"]);
    apply_platform_environment(&mut clippy, preset);
    run(&mut clippy, "Cargo Clippy")
}

fn build_system(root: &Path, preset: Preset, paths: &Paths) -> Result<PathBuf> {
    let packages = system_packages(preset)?;
    stage_content(root, paths, &packages)?;
    generate_bindings(root, preset, paths, &packages)?;
    let rust_archive = build_rust(root, preset, paths)?;
    compile_and_link(root, preset, paths, &packages, &rust_archive)?;
    write_build_info(preset, paths)?;
    Ok(paths.binary.join(executable_name()))
}

fn build_pinned(root: &Path, preset: Preset, paths: &Paths) -> Result<PathBuf> {
    ensure_native_host(preset)?;
    let packages = pinned_packages(root, preset, paths)?;
    stage_content(root, paths, &packages)?;
    generate_bindings(root, preset, paths, &packages)?;
    let rust_archive = build_rust(root, preset, paths)?;
    if preset.is_single() {
        compile_and_link_single(root, preset, paths, &packages, &rust_archive)?;
    } else {
        compile_and_link(root, preset, paths, &packages, &rust_archive)?;
    }
    write_build_info(preset, paths)?;
    Ok(paths.binary.join(executable_name()))
}

fn ensure_native_host(preset: Preset) -> Result<()> {
    let host_matches = match std::env::consts::OS {
        "macos" => preset.rust_target.contains("apple-darwin"),
        "linux" => preset.rust_target.contains("unknown-linux-gnu"),
        "windows" => preset.rust_target.contains("pc-windows-msvc"),
        _ => false,
    };
    if host_matches
        || preset.rust_target.contains("apple-ios")
        || preset.rust_target.contains("android")
    {
        Ok(())
    } else {
        anyhow::bail!(
            "{} must be built on its target operating system; use the release matrix for cross-OS builds",
            preset.name
        )
    }
}

fn pinned_packages(
    root: &Path,
    preset: Preset,
    paths: &Paths,
) -> Result<BTreeMap<&'static str, Package>> {
    let source_root = paths.dependencies.join("src");
    let build_root = paths.dependencies.join("build");
    let prefix = paths.dependencies.join("prefix");
    fs::create_dir_all(&source_root)?;
    fs::create_dir_all(&build_root)?;
    fs::create_dir_all(&prefix)?;

    let sdl = fetch_source(
        &source_root,
        "sdl3",
        "https://github.com/libsdl-org/SDL.git",
        SDL3_REVISION,
    )?;
    let mixer = fetch_source(
        &source_root,
        "sdl3-mixer",
        "https://github.com/libsdl-org/SDL_mixer.git",
        SDL3_MIXER_REVISION,
    )?;
    update_submodules(
        &mixer,
        &[
            "external/ogg",
            "external/opus",
            "external/opusfile",
            "external/wavpack",
        ],
    )?;
    let zlib = fetch_source(
        &source_root,
        "zlib",
        "https://github.com/madler/zlib.git",
        ZLIB_REVISION,
    )?;
    let spirv_cross = fetch_source(
        &source_root,
        "spirv-cross",
        "https://github.com/KhronosGroup/SPIRV-Cross.git",
        SPIRV_CROSS_REVISION,
    )?;
    let shaderc = fetch_source(
        &source_root,
        "shaderc",
        "https://github.com/google/shaderc.git",
        SHADERC_REVISION,
    )?;
    fetch_source_at(
        &shaderc.join("third_party/glslang"),
        "https://github.com/KhronosGroup/glslang.git",
        GLSLANG_REVISION,
    )?;
    fetch_source_at(
        &shaderc.join("third_party/spirv-tools"),
        "https://github.com/KhronosGroup/SPIRV-Tools.git",
        SPIRV_TOOLS_REVISION,
    )?;
    fetch_source_at(
        &shaderc.join("third_party/spirv-tools/external/spirv-headers"),
        "https://github.com/KhronosGroup/SPIRV-Headers.git",
        SPIRV_HEADERS_REVISION,
    )?;
    let luajit = fetch_source(
        &source_root,
        "luajit",
        "https://github.com/LuaJIT/LuaJIT.git",
        LUAJIT_REVISION,
    )?;

    let shared = !preset.is_single();
    configure_cmake(
        preset,
        &sdl,
        &build_root.join("sdl3"),
        &prefix,
        &[
            define_bool("SDL_SHARED", shared),
            define_bool("SDL_STATIC", !shared),
            "-DSDL_TEST_LIBRARY=OFF".into(),
            "-DSDL_TESTS=OFF".into(),
            "-DSDL_EXAMPLES=OFF".into(),
        ],
    )?;
    cmake_install(&build_root.join("sdl3"))?;

    configure_cmake(
        preset,
        &zlib,
        &build_root.join("zlib"),
        &prefix,
        &[
            define_bool("ZLIB_BUILD_SHARED", shared),
            "-DZLIB_BUILD_STATIC=ON".into(),
            "-DZLIB_BUILD_TESTING=OFF".into(),
        ],
    )?;
    cmake_install(&build_root.join("zlib"))?;

    configure_cmake(
        preset,
        &mixer,
        &build_root.join("sdl3-mixer"),
        &prefix,
        &[
            define_bool("BUILD_SHARED_LIBS", shared),
            define_bool("SDLMIXER_BUILD_SHARED_LIBS", shared),
            "-DSDLMIXER_VENDORED=ON".into(),
            "-DSDLMIXER_STRICT=ON".into(),
            "-DSDLMIXER_DEPS_SHARED=OFF".into(),
            "-DSDLMIXER_TESTS=OFF".into(),
            "-DSDLMIXER_EXAMPLES=OFF".into(),
            "-DSDLMIXER_GME=OFF".into(),
            "-DSDLMIXER_MOD=OFF".into(),
            "-DSDLMIXER_MIDI=OFF".into(),
            "-DSDLMIXER_MP3_MPG123=OFF".into(),
            "-DSDLMIXER_MP3_DRMP3=ON".into(),
            "-DSDLMIXER_FLAC_LIBFLAC=OFF".into(),
            "-DSDLMIXER_FLAC_DRFLAC=ON".into(),
            "-DSDLMIXER_VORBIS_VORBISFILE=OFF".into(),
            "-DSDLMIXER_VORBIS_TREMOR=OFF".into(),
            "-DSDLMIXER_VORBIS_STB=ON".into(),
            "-DSDLMIXER_OPUS=ON".into(),
            "-DSDLMIXER_WAVPACK=ON".into(),
        ],
    )?;
    cmake_install(&build_root.join("sdl3-mixer"))?;

    configure_cmake(
        preset,
        &spirv_cross,
        &build_root.join("spirv-cross"),
        &prefix,
        &[
            "-DSPIRV_CROSS_CLI=OFF".into(),
            "-DSPIRV_CROSS_ENABLE_TESTS=OFF".into(),
            "-DSPIRV_CROSS_SKIP_INSTALL=OFF".into(),
            "-DSPIRV_CROSS_SHARED=OFF".into(),
        ],
    )?;
    cmake_install(&build_root.join("spirv-cross"))?;

    configure_cmake(
        preset,
        &shaderc,
        &build_root.join("shaderc"),
        &prefix,
        &[
            "-DSHADERC_SKIP_TESTS=ON".into(),
            "-DSHADERC_SKIP_EXAMPLES=ON".into(),
            "-DSHADERC_SKIP_EXECUTABLES=ON".into(),
            "-DSHADERC_SKIP_COPYRIGHT_CHECK=ON".into(),
            "-DSHADERC_ENABLE_WERROR_COMPILE=OFF".into(),
            "-DSHADERC_SKIP_INSTALL=OFF".into(),
            "-DSPIRV_SKIP_TESTS=ON".into(),
            "-DSPIRV_SKIP_EXECUTABLES=ON".into(),
            "-DENABLE_GLSLANG_BINARIES=OFF".into(),
            "-DGLSLANG_TESTS=OFF".into(),
            "-DBUILD_SHARED_LIBS=OFF".into(),
        ],
    )?;
    cmake_build(
        &build_root.join("shaderc"),
        Some(if shared {
            "shaderc_shared"
        } else {
            "shaderc_combined"
        }),
    )?;
    install_shaderc(&shaderc, &build_root.join("shaderc"), &prefix, shared)?;
    build_luajit(preset, &luajit, &prefix)?;

    let library = prefix.join("lib");
    let mut packages = BTreeMap::new();
    packages.insert(
        "sdl3",
        Package {
            name: "sdl3",
            includes: vec![prefix.join("include")],
            library_directories: vec![library.clone()],
            libraries: vec!["SDL3".into()],
        },
    );
    packages.insert(
        "sdl3mixer",
        Package {
            name: "sdl3mixer",
            includes: vec![prefix.join("include")],
            library_directories: vec![library.clone()],
            libraries: vec!["SDL3_mixer".into()],
        },
    );
    packages.insert(
        "zlib",
        Package {
            name: "zlib",
            includes: vec![prefix.join("include")],
            library_directories: vec![library.clone()],
            libraries: vec![if preset.rust_target.contains("windows") {
                "zlib".into()
            } else {
                "z".into()
            }],
        },
    );
    packages.insert(
        "luajit",
        Package {
            name: "luajit",
            includes: vec![prefix.join("include/luajit-2.1")],
            library_directories: vec![library.clone()],
            libraries: vec![if preset.rust_target.contains("windows") {
                "lua51".into()
            } else {
                "luajit-5.1".into()
            }],
        },
    );
    packages.insert(
        "shaderc",
        Package {
            name: "shaderc",
            includes: vec![prefix.join("include")],
            library_directories: vec![library.clone()],
            libraries: vec![if shared {
                "shaderc_shared".into()
            } else {
                "shaderc_combined".into()
            }],
        },
    );
    packages.insert(
        "spvc",
        Package {
            name: "spvc",
            includes: vec![prefix.join("include/spirv_cross")],
            library_directories: vec![library],
            libraries: Vec::new(),
        },
    );
    let _ = root;
    Ok(packages)
}

fn define_bool(name: &str, enabled: bool) -> OsString {
    format!("-D{name}={}", if enabled { "ON" } else { "OFF" }).into()
}

fn fetch_source(root: &Path, name: &str, repository: &str, revision: &str) -> Result<PathBuf> {
    let destination = root.join(name);
    fetch_source_at(&destination, repository, revision)?;
    Ok(destination)
}

fn fetch_source_at(destination: &Path, repository: &str, revision: &str) -> Result<()> {
    let marker = destination.join(".tecs-revision");
    if fs::read_to_string(&marker).ok().as_deref() == Some(revision) {
        return Ok(());
    }
    fs::create_dir_all(destination)?;
    if !destination.join(".git").is_dir() {
        command::run("git", ["init"], destination)?;
        command::run("git", ["remote", "add", "origin", repository], destination)?;
    }
    let mut fetch = Command::new("git");
    fetch
        .args(["fetch", "--depth", "1", "origin", revision])
        .current_dir(destination);
    run(&mut fetch, &format!("fetching {repository} at {revision}"))?;
    command::run("git", ["checkout", "--detach", "FETCH_HEAD"], destination)?;
    fs::write(marker, revision)?;
    Ok(())
}

fn update_submodules(source: &Path, submodules: &[&str]) -> Result<()> {
    let marker = source.join(".tecs-submodules");
    if fs::read_to_string(&marker).ok().as_deref() == Some("ready") {
        return Ok(());
    }
    let mut command = Command::new("git");
    command
        .args(["submodule", "update", "--init", "--depth", "1", "--"])
        .args(submodules)
        .current_dir(source);
    run(&mut command, "fetching SDL_mixer decoder sources")?;
    fs::write(marker, "ready")?;
    Ok(())
}

fn configure_cmake(
    preset: Preset,
    source: &Path,
    build: &Path,
    prefix: &Path,
    definitions: &[OsString],
) -> Result<()> {
    fs::create_dir_all(build)?;
    let mut command = Command::new("cmake");
    command
        .arg("-S")
        .arg(source)
        .arg("-B")
        .arg(build)
        .arg("-DCMAKE_BUILD_TYPE=Release")
        .arg("-DCMAKE_POSITION_INDEPENDENT_CODE=ON")
        .arg(format!("-DCMAKE_INSTALL_PREFIX={}", prefix.display()))
        .arg(format!("-DCMAKE_PREFIX_PATH={}", prefix.display()))
        .args(definitions);
    apply_native_cmake_target(&mut command, preset)?;
    run(
        &mut command,
        &format!("configuring native dependency {}", source.display()),
    )
}

fn apply_native_cmake_target(command: &mut Command, preset: Preset) -> Result<()> {
    if preset.rust_target.contains("apple-darwin") {
        command
            .arg(format!("-DCMAKE_OSX_ARCHITECTURES={}", target_arch(preset)))
            .arg(format!(
                "-DCMAKE_OSX_DEPLOYMENT_TARGET={}",
                preset
                    .deployment_target
                    .context("macOS preset has no deployment target")?
            ))
            .arg("-DCMAKE_INSTALL_NAME_DIR=@rpath");
    } else if preset.rust_target.contains("apple-ios") {
        command
            .arg("-DCMAKE_SYSTEM_NAME=iOS")
            .arg("-DCMAKE_OSX_ARCHITECTURES=arm64")
            .arg(format!(
                "-DCMAKE_OSX_DEPLOYMENT_TARGET={}",
                preset
                    .deployment_target
                    .context("iOS preset has no deployment target")?
            ));
    } else if preset.rust_target.contains("android") {
        let ndk = std::env::var_os("ANDROID_NDK_HOME")
            .or_else(|| std::env::var_os("ANDROID_NDK_ROOT"))
            .context("set ANDROID_NDK_HOME to build an Android preset")?;
        let abi = if preset.rust_target.starts_with("aarch64") {
            "arm64-v8a"
        } else {
            "x86_64"
        };
        command
            .arg(format!(
                "-DCMAKE_TOOLCHAIN_FILE={}",
                PathBuf::from(ndk)
                    .join("build/cmake/android.toolchain.cmake")
                    .display()
            ))
            .arg(format!("-DANDROID_ABI={abi}"))
            .arg(format!(
                "-DANDROID_PLATFORM=android-{}",
                preset
                    .deployment_target
                    .context("Android preset has no API level")?
            ));
    }
    Ok(())
}

fn cmake_build(build: &Path, target: Option<&str>) -> Result<()> {
    let mut command = Command::new("cmake");
    command
        .arg("--build")
        .arg(build)
        .args(["--config", "Release", "--parallel", "8"]);
    if let Some(target) = target {
        command.arg("--target").arg(target);
    }
    run(&mut command, &format!("building {}", build.display()))
}

fn cmake_install(build: &Path) -> Result<()> {
    cmake_build(build, Some("install"))
}

fn install_shaderc(source: &Path, build: &Path, prefix: &Path, shared: bool) -> Result<()> {
    let include = prefix.join("include/shaderc");
    fs::create_dir_all(&include)?;
    copy_tree(&source.join("libshaderc/include/shaderc"), &include, false)?;
    let library = prefix.join("lib");
    fs::create_dir_all(&library)?;
    let mut copied = 0;
    for entry in WalkDir::new(build).into_iter().filter_map(Result::ok) {
        if !entry.file_type().is_file() && !entry.file_type().is_symlink() {
            continue;
        }
        let name = entry.file_name().to_string_lossy();
        let wanted = if shared {
            (name.starts_with("libshaderc_shared")
                && (name.ends_with(".dylib") || name.contains(".so")))
                || (name.starts_with("shaderc_shared")
                    && (name.ends_with(".dll") || name.ends_with(".lib")))
        } else {
            name == "libshaderc_combined.a" || name == "shaderc_combined.lib"
        };
        if wanted {
            fs::copy(entry.path(), library.join(entry.file_name()))?;
            copied += 1;
        }
    }
    if copied == 0 {
        anyhow::bail!(
            "shaderc build did not produce {}",
            if shared {
                "a shared library"
            } else {
                "the combined archive"
            }
        );
    }
    Ok(())
}

fn build_luajit(preset: Preset, source: &Path, prefix: &Path) -> Result<()> {
    if preset.rust_target.contains("windows") {
        let mut build = Command::new("cmd");
        build
            .args(["/C", "msvcbuild.bat"])
            .current_dir(source.join("src"));
        run(&mut build, "building pinned LuaJIT")?;
        let library = prefix.join("lib");
        let include = prefix.join("include/luajit-2.1");
        fs::create_dir_all(&library)?;
        fs::create_dir_all(&include)?;
        for name in ["lua51.dll", "lua51.lib"] {
            fs::copy(source.join("src").join(name), library.join(name))?;
        }
        for name in [
            "lua.h",
            "lualib.h",
            "lauxlib.h",
            "luaconf.h",
            "lua.hpp",
            "luajit.h",
        ] {
            fs::copy(source.join("src").join(name), include.join(name))?;
        }
        copy_tree(
            &source.join("src/jit"),
            &prefix.join("share/luajit-2.1/jit"),
            true,
        )?;
        return Ok(());
    }
    if preset.rust_target.contains("apple-ios") || preset.rust_target.contains("android") {
        anyhow::bail!(
            "{} needs the LuaJIT mobile cross-build adapter, which is not available on this host",
            preset.name
        );
    }
    let mut flags = vec![format!("PREFIX={}", prefix.display())];
    if preset.rust_target.contains("apple-darwin") {
        flags.push("TARGET_DYLIBPATH=@rpath/libluajit-5.1.dylib".into());
        flags.push(format!("CFLAGS=-arch {}", target_arch(preset)));
        flags.push(format!("LDFLAGS=-arch {}", target_arch(preset)));
    } else {
        flags.push("TARGET_SONAME=libluajit-5.1.so".into());
    }
    let mut build = Command::new("make");
    build.args(&flags).current_dir(source);
    apply_platform_environment(&mut build, preset);
    run(&mut build, "building pinned LuaJIT")?;
    let mut install = Command::new("make");
    install.arg("install").args(&flags).current_dir(source);
    apply_platform_environment(&mut install, preset);
    run(&mut install, "installing pinned LuaJIT")
}

fn system_packages(preset: Preset) -> Result<BTreeMap<&'static str, Package>> {
    check_system_versions(preset)?;
    let mut packages = BTreeMap::new();
    for (key, package) in [
        ("sdl3", "sdl3"),
        ("sdl3mixer", "sdl3-mixer"),
        ("luajit", "luajit"),
        ("zlib", "zlib"),
    ] {
        packages.insert(key, pkg_config(key, package)?);
    }
    if matches!(preset.shaders, ShaderMode::Runtime) {
        packages.insert("shaderc", pkg_config("shaderc", "shaderc")?);
        packages.insert("spvc", pkg_config("spvc", "spirv-cross-c")?);
    }
    Ok(packages)
}

fn check_system_versions(preset: Preset) -> Result<()> {
    let mut requirements = vec![
        ("SDL3", "sdl3", SDL3_REVISION, false),
        ("SDL3_mixer", "sdl3-mixer", SDL3_MIXER_REVISION, false),
        ("LuaJIT", "luajit", LUAJIT_ROLLING, false),
    ];
    if matches!(preset.shaders, ShaderMode::Runtime) {
        requirements.push(("shaderc", "shaderc", SHADERC_REVISION, true));
    }
    let mut drift = Vec::new();
    for (name, package, revision, prefix) in requirements {
        let found = pkg_output(package, &["--modversion"])?;
        let found = found.trim();
        let expected = revision
            .strip_prefix("release-")
            .or_else(|| revision.strip_prefix('v'))
            .unwrap_or(revision);
        let matches = if prefix {
            found.starts_with(expected)
        } else {
            found == expected
        };
        if !matches {
            drift.push(format!(
                "  {name}: system has {found}, this tree pins {revision}"
            ));
        }
    }
    if drift.is_empty() {
        return Ok(());
    }
    let allowed = std::env::var("TECS_ALLOW_VERSION_DRIFT")
        .is_ok_and(|value| !value.is_empty() && value != "0" && value.to_lowercase() != "off");
    if allowed {
        eprintln!(
            "warning: proceeding with system dependency version drift:\n{}",
            drift.join("\n")
        );
        Ok(())
    } else {
        anyhow::bail!(
            "system dependencies disagree with the pinned revisions:\n{}\n\
             Install the pinned versions, raise the revisions deliberately, or set \
             TECS_ALLOW_VERSION_DRIFT=1 while working on that update.",
            drift.join("\n")
        )
    }
}

fn pkg_config(name: &'static str, package: &'static str) -> Result<Package> {
    let cflags = pkg_output(package, &["--cflags-only-I"])?;
    let includes = cflags
        .split_whitespace()
        .filter_map(|flag| flag.strip_prefix("-I"))
        .map(PathBuf::from)
        .collect();
    let flags = pkg_output(package, &["--libs"])?;
    let library_directories = flags
        .split_whitespace()
        .filter_map(|flag| flag.strip_prefix("-L"))
        .map(PathBuf::from)
        .collect();
    let libraries = flags
        .split_whitespace()
        .filter_map(|flag| flag.strip_prefix("-l"))
        .map(str::to_owned)
        .collect();
    Ok(Package {
        name,
        includes,
        library_directories,
        libraries,
    })
}

fn pkg_output(package: &str, arguments: &[&str]) -> Result<String> {
    let output = Command::new("pkg-config")
        .args(arguments)
        .arg(package)
        .output()
        .with_context(|| format!("starting pkg-config for {package}"))?;
    if !output.status.success() {
        anyhow::bail!(
            "pkg-config could not resolve {package}:\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    String::from_utf8(output.stdout).context("pkg-config emitted non-UTF-8 output")
}

fn stage_content(
    root: &Path,
    paths: &Paths,
    packages: &BTreeMap<&'static str, Package>,
) -> Result<()> {
    let sources = teal_sources(&root.join("src"))?;
    let cli_sources = cli_sources(&root.join("cli"))?;
    let tl = root.join("vendor/bin/tl");
    if !tl.is_file() {
        anyhow::bail!(
            "{} is missing; run `cargo xtask dev-tools` inside this worktree",
            tl.display()
        );
    }

    let mut engine = Command::new(&tl);
    engine
        .args(["-q", "gen", "-I"])
        .arg(root.join("vendor/share/lua/5.1"))
        .arg("-I")
        .arg(root.join("vendor/tl"))
        .arg("--root")
        .arg(root.join("src"))
        .arg("--output-dir")
        .arg(&paths.lua)
        .args(&sources)
        .current_dir(root);
    run(&mut engine, "Teal engine compilation")?;

    let mut cli = Command::new(&tl);
    cli.args(["-q", "gen", "-I"])
        .arg(root.join("vendor/share/lua/5.1"))
        .arg("-I")
        .arg(root.join("vendor/tl"))
        .arg("-I")
        .arg(root.join("src"))
        .arg("-I")
        .arg(root.join("cli"))
        .arg("--root")
        .arg(root.join("cli"))
        .arg("--output-dir")
        .arg(&paths.lua)
        .args(&cli_sources)
        .current_dir(root);
    run(&mut cli, "Teal CLI compilation")?;

    copy_tree(&root.join("assets"), &paths.lua, false)?;
    stage_offline_docs(root, &paths.lua.join("tecsdocs"))?;
    copy_tree(
        &root.join("cli/tecscli/templates"),
        &paths.lua.join("tecscli/templates"),
        true,
    )?;
    staging::tools(
        &root.join("vendor/share/lua/5.1"),
        &root.join("vendor/licenses"),
        &paths.lua.join("tecstools"),
    )?;
    tooling::generate(
        TEAL_REVISION,
        CERULEAN_REVISION,
        &paths.lua.join("tecscli/toolchain.lua"),
    )?;
    stage_jit(package(packages, "luajit")?, &paths.lua)?;

    copy_tree(&root.join("src"), &paths.teal, true)?;
    copy_tree(&root.join("cli/tecscli"), &paths.teal.join("tecscli"), true)?;
    let templates = paths.teal.join("tecscli/templates");
    if templates.exists() {
        fs::remove_dir_all(templates)?;
    }
    for notice in ["THIRD_PARTY_NOTICES.md", "LICENSE-MIT", "LICENSE-APACHE"] {
        fs::copy(root.join(notice), paths.notices.join(notice))?;
    }
    compile_specs(root, paths)?;
    Ok(())
}

fn teal_sources(directory: &Path) -> Result<Vec<PathBuf>> {
    source_files(directory, |path| {
        path.extension().and_then(|value| value.to_str()) == Some("tl")
            && !path.to_string_lossy().ends_with(".d.tl")
    })
}

fn cli_sources(directory: &Path) -> Result<Vec<PathBuf>> {
    source_files(directory, |path| {
        path.extension().and_then(|value| value.to_str()) == Some("tl")
            && !path.to_string_lossy().ends_with(".d.tl")
            && !path
                .components()
                .any(|part| part.as_os_str() == "templates")
    })
}

fn source_files(directory: &Path, predicate: impl Fn(&Path) -> bool) -> Result<Vec<PathBuf>> {
    let mut files: Vec<_> = WalkDir::new(directory)
        .into_iter()
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|entry| entry.file_type().is_file() && predicate(entry.path()))
        .map(|entry| entry.into_path())
        .collect();
    files.sort();
    Ok(files)
}

fn copy_tree(source: &Path, destination: &Path, clean: bool) -> Result<()> {
    if clean && destination.exists() {
        fs::remove_dir_all(destination)?;
    }
    fs::create_dir_all(destination)?;
    for entry in WalkDir::new(source) {
        let entry = entry?;
        let relative = entry.path().strip_prefix(source)?;
        let target = destination.join(relative);
        if entry.file_type().is_dir() {
            fs::create_dir_all(target)?;
        } else if entry.file_type().is_file() {
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

/// Stages the documentation `tecs docs` reads offline.
///
/// The pages under `docs/` carry prose and no reference: the generator renders
/// every `### tecs.*` entry at build time, so a page on disk holds none of the
/// 1,000-odd symbols the command looks up. What it needs is the composed
/// Markdown a site build writes beside each page, which is prose and reference
/// together.
///
/// A site build takes about thirteen seconds, which is not a price every
/// `build` and `test` should pay, so it runs only when a page or a source file
/// is newer than the last one. The fingerprint is a modification time rather
/// than a hash because the inputs are thousands of files and the question is
/// only whether anything moved.
fn stage_offline_docs(root: &Path, destination: &Path) -> Result<()> {
    let composed = root.join(crate::docs::OUTPUT);
    if docs_are_stale(root, &composed)? {
        crate::docs::build(root, &composed)?;
    }
    stage_markdown(&composed, destination)
}

/// Whether a page or a Teal source is newer than the composed Markdown.
fn docs_are_stale(root: &Path, composed: &Path) -> Result<bool> {
    let built = match fs::metadata(composed.join("index.md")) {
        Ok(metadata) => metadata.modified()?,
        Err(_) => return Ok(true),
    };
    for directory in [root.join("docs"), root.join("src")] {
        for path in source_files(&directory, |path| {
            let extension = path.extension().and_then(|value| value.to_str());
            let is_input = extension == Some("md") || extension == Some("tl");
            is_input
                && !path
                    .components()
                    .any(|part| part.as_os_str() == "node_modules")
        })? {
            if fs::metadata(&path)?.modified()? > built {
                return Ok(true);
            }
        }
    }
    Ok(false)
}

fn stage_markdown(source: &Path, destination: &Path) -> Result<()> {
    if destination.exists() {
        fs::remove_dir_all(destination)?;
    }
    for path in source_files(source, |path| {
        path.extension().and_then(|value| value.to_str()) == Some("md")
            && !path
                .components()
                .any(|part| part.as_os_str() == "node_modules")
    })? {
        let relative = path.strip_prefix(source)?;
        let target = destination.join(relative);
        fs::create_dir_all(
            target
                .parent()
                .context("offline documentation page has no parent")?,
        )?;
        fs::copy(path, target)?;
    }
    Ok(())
}

fn stage_jit(luajit: &Package, lua: &Path) -> Result<()> {
    let library = luajit
        .library_directories
        .first()
        .context("LuaJIT has no library directory")?;
    let prefix = library
        .parent()
        .context("LuaJIT library directory has no parent")?;
    let source = prefix.join("share/luajit-2.1/jit");
    if !source.join("vmdef.lua").is_file() {
        anyhow::bail!(
            "LuaJIT's jit/*.lua were not found below {}",
            source.display()
        );
    }
    copy_tree(&source, &lua.join("jit"), true)?;
    Ok(())
}

fn compile_specs(root: &Path, paths: &Paths) -> Result<()> {
    let mut command = Command::new("luajit");
    command
        .arg(root.join("scripts/compile_specs.lua"))
        .arg(root.join("spec"))
        .arg(&paths.spec)
        .arg(root.join("vendor/share/lua/5.1"))
        .current_dir(root);
    run(&mut command, "Teal spec compilation")
}

struct Binding<'a> {
    name: &'static str,
    header: &'static str,
    keeps: &'static [&'static str],
    prefix: &'static str,
    needed: &'static [&'static str],
    includes: Vec<PathBuf>,
    registry_struct: &'static str,
    registry_prefix: &'static str,
    registry_headers: &'static [&'static str],
    enabled: bool,
    _packages: &'a BTreeMap<&'static str, Package>,
}

fn generate_bindings(
    root: &Path,
    preset: Preset,
    paths: &Paths,
    packages: &BTreeMap<&'static str, Package>,
) -> Result<()> {
    let ffi = paths.lua.join("tecs/ffi");
    fs::create_dir_all(&ffi)?;
    let native = vec![root.join("native")];
    let sdl = package(packages, "sdl3")?.includes.clone();
    let mut mixer = package(packages, "sdl3mixer")?.includes.clone();
    mixer.extend(sdl.clone());
    let zlib = package(packages, "zlib")?.includes.clone();
    let shaderc = packages
        .get("shaderc")
        .map(|package| package.includes.clone())
        .unwrap_or_default();
    let spvc = packages
        .get("spvc")
        .map(|package| package.includes.clone())
        .unwrap_or_default();
    let runtime_shaders = matches!(preset.shaders, ShaderMode::Runtime);
    let bindings = vec![
        Binding {
            name: "sdl3",
            header: "SDL3/SDL.h",
            keeps: &["/SDL3/"],
            prefix: "SDL_",
            needed: &[],
            includes: sdl,
            registry_struct: "TecsSdl3Api",
            registry_prefix: "SDL_",
            registry_headers: &["SDL3/SDL.h"],
            enabled: true,
            _packages: packages,
        },
        Binding {
            name: "sdl3mixer",
            header: "SDL3_mixer/SDL_mixer.h",
            keeps: &["/SDL3_mixer/"],
            prefix: "MIX_",
            needed: &[],
            includes: mixer,
            registry_struct: "TecsSdl3MixerApi",
            registry_prefix: "MIX_",
            registry_headers: &["SDL3_mixer/SDL_mixer.h"],
            enabled: true,
            _packages: packages,
        },
        Binding {
            name: "shaderc",
            header: "shaderc/shaderc.h",
            keeps: &["/shaderc/"],
            prefix: "shaderc_",
            needed: &[],
            includes: shaderc,
            registry_struct: "TecsShadercApi",
            registry_prefix: "shaderc_",
            registry_headers: &["shaderc/shaderc.h"],
            enabled: runtime_shaders,
            _packages: packages,
        },
        Binding {
            name: "spvc",
            header: "spirv_cross_c.h",
            keeps: &["/spirv_cross_c.h", "/spirv.h"],
            prefix: "SPVC_",
            needed: &[],
            includes: spvc,
            registry_struct: "TecsSpvcApi",
            registry_prefix: "spvc_",
            registry_headers: &["spirv_cross_c.h"],
            enabled: runtime_shaders,
            _packages: packages,
        },
        Binding {
            name: "zlib",
            header: "zlib.h",
            keeps: &["/zlib.h", "/zconf.h"],
            prefix: "Z",
            needed: &["off_t"],
            includes: zlib,
            registry_struct: "TecsZlibApi",
            registry_prefix: "",
            registry_headers: &["zlib.h"],
            enabled: true,
            _packages: packages,
        },
        Binding {
            name: "worker",
            header: "worker.h",
            keeps: &["/native/"],
            prefix: "TECS_",
            needed: &[],
            includes: native.clone(),
            registry_struct: "TecsWorkerApi",
            registry_prefix: "tecs",
            registry_headers: &["worker.h"],
            enabled: true,
            _packages: packages,
        },
        Binding {
            name: "logsink",
            header: "logsink.h",
            keeps: &["/native/"],
            prefix: "TECS_",
            needed: &[],
            includes: native.clone(),
            registry_struct: "TecsLogsinkApi",
            registry_prefix: "tecs",
            registry_headers: &["logsink.h"],
            enabled: true,
            _packages: packages,
        },
        Binding {
            name: "dialogs",
            header: "dialogs.h",
            keeps: &["/native/"],
            prefix: "TECS_",
            needed: &[],
            includes: native.clone(),
            registry_struct: "TecsDialogsApi",
            registry_prefix: "tecs",
            registry_headers: &["dialogs.h"],
            enabled: true,
            _packages: packages,
        },
        Binding {
            name: "http",
            header: "http.h",
            keeps: &["/native/"],
            prefix: "TECS_",
            needed: &[],
            includes: native.clone(),
            registry_struct: "TecsHttpApi",
            registry_prefix: "tecs",
            registry_headers: &["http.h"],
            enabled: true,
            _packages: packages,
        },
        Binding {
            name: "rust",
            header: "rust.h",
            keeps: &["/native/"],
            prefix: "TECS_",
            needed: &[],
            includes: native,
            registry_struct: "TecsRustApi",
            registry_prefix: "tecs",
            registry_headers: &["rust.h"],
            enabled: true,
            _packages: packages,
        },
    ];
    let mut registry = Vec::new();
    for binding in &bindings {
        let headers = vec![binding.header.to_owned()];
        let keeps = binding
            .keeps
            .iter()
            .map(|value| (*value).to_owned())
            .collect::<Vec<_>>();
        let needed = binding
            .needed
            .iter()
            .map(|value| (*value).to_owned())
            .collect::<Vec<_>>();
        let prefixes = vec![binding.prefix.to_owned()];
        let cdef_output = ffi.join(format!("{}cdef.lua", binding.name));
        let constants_output = ffi.join(format!("{}const.lua", binding.name));
        cdef::generate(&CdefOptions {
            compiler: "cc",
            headers: &headers,
            include_directories: &binding.includes,
            defines: &["NDEBUG".to_owned()],
            keeps: &keeps,
            needed: &needed,
            define_prefixes: &prefixes,
            constants_output: Some(&constants_output),
            output: &cdef_output,
        })?;
        if binding.enabled {
            let registry_headers = binding
                .registry_headers
                .iter()
                .map(|value| (*value).to_owned())
                .collect::<Vec<_>>();
            registry::generate(&RegistryOptions {
                cdef: &cdef_output,
                name: binding.name,
                struct_name: binding.registry_struct,
                prefix: binding.registry_prefix,
                headers: &registry_headers,
                source_output: &paths.generated.join(format!("{}api.c", binding.name)),
                cdef_output: &ffi.join(format!("{}apicdef.lua", binding.name)),
            })?;
            registry.push((binding.name, binding.registry_struct));
        }
    }
    generate_registry_root(paths, &registry)?;
    Ok(())
}

fn package<'a>(packages: &'a BTreeMap<&'static str, Package>, name: &str) -> Result<&'a Package> {
    packages
        .get(name)
        .with_context(|| format!("dependency {name} was not resolved"))
}

fn generate_registry_root(paths: &Paths, registry: &[(&str, &str)]) -> Result<()> {
    let mut lua = String::from("-- Generated by `cargo xtask`. Do not edit.\nreturn {\n");
    for (name, structure) in registry {
        lua.push_str(&format!("    {name} = \"{structure}\",\n"));
    }
    lua.push_str("}\n");
    fs::write(paths.lua.join("tecs/ffi/registrystructs.lua"), lua)?;

    let entries = registry
        .iter()
        .map(|(name, structure)| format!("TECS_API({name}, {structure})"))
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";
    fs::write(
        paths.generated.join("registry_entries.h"),
        format!("/* Generated by `cargo xtask`. Do not edit. */\n{entries}"),
    )?;
    fs::write(
        paths.generated.join("registry_install.c"),
        r#"/* Generated by `cargo xtask`. Do not edit. */
#include <stddef.h>
#include "registry.h"
#define TECS_API(name, struct_) extern const void *tecs_##name##_api(void);
#include "registry_entries.h"
#undef TECS_API
extern void tecsRegistryInstallTables(struct lua_State *, size_t, const char *const *, const void *const *);
void tecsRegistryInstall(struct lua_State *L)
{
    const char *names[] = {
#define TECS_API(name, struct_) #name,
#include "registry_entries.h"
#undef TECS_API
    };
    const void *tables[] = {
#define TECS_API(name, struct_) tecs_##name##_api(),
#include "registry_entries.h"
#undef TECS_API
    };
    tecsRegistryInstallTables(L, sizeof(names) / sizeof(names[0]), names, tables);
}
"#,
    )?;
    fs::write(
        paths.generated.join("sdl_main.c"),
        r#"/* Generated by `cargo xtask`. Do not edit. */
#define SDL_MAIN_USE_CALLBACKS 1
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
"#,
    )?;
    fs::write(
        paths.generated.join("worker_anchor.c"),
        "/* Generated by `cargo xtask`. Do not edit. */\nvoid tecsWorkerLibraryAnchor(void);\nvoid tecsWorkerLibraryAnchor(void) {}\n",
    )?;
    fs::write(
        paths.generated.join("spvc_anchor.c"),
        "/* Generated by `cargo xtask`. Do not edit. */\nvoid tecsSpirvCrossLibraryAnchor(void);\nvoid tecsSpirvCrossLibraryAnchor(void) {}\n",
    )?;
    Ok(())
}

fn build_rust(root: &Path, preset: Preset, paths: &Paths) -> Result<PathBuf> {
    let mut command = Command::new("cargo");
    command
        .args([
            "build",
            "--locked",
            "--package",
            "tecs-native",
            "--target",
            preset.rust_target,
            "--release",
        ])
        .env("CARGO_TARGET_DIR", &paths.cargo)
        .env("TECS_CONTENT", "../share/tecs/lua/")
        .env("TECS_ENTRY", preset.entry)
        .current_dir(root);
    if preset.is_single() {
        command.args(["--features", "payload"]);
    }
    apply_platform_environment(&mut command, preset);
    run(&mut command, "Rust native service build")?;
    let name = if preset.rust_target.contains("windows") {
        "tecs_native.lib"
    } else {
        "libtecs_native.a"
    };
    let archive = paths
        .cargo
        .join(preset.rust_target)
        .join("release")
        .join(name);
    if !archive.is_file() {
        anyhow::bail!("Cargo did not produce {}", archive.display());
    }
    Ok(archive)
}

fn compile_and_link(
    root: &Path,
    preset: Preset,
    paths: &Paths,
    packages: &BTreeMap<&'static str, Package>,
    rust_archive: &Path,
) -> Result<()> {
    let mut includes = vec![root.join("native"), paths.generated.clone()];
    for package in packages.values() {
        includes.extend(package.includes.clone());
    }
    includes.sort();
    includes.dedup();

    let cjson_objects = CJSON_SOURCES
        .iter()
        .map(|source| {
            compile_c(
                root,
                preset,
                paths,
                &root.join(source),
                &includes,
                &["USE_INTERNAL_FPCONV", "MULTIPLE_THREADS"],
                false,
            )
        })
        .collect::<Result<Vec<_>>>()?;
    let cjson_archive = paths.out.join("libtecs_cjson.a");
    archive(&cjson_archive, &cjson_objects)?;

    let mut registry_sources = vec![paths.generated.join("registry_install.c")];
    for name in [
        "sdl3",
        "sdl3mixer",
        "zlib",
        "worker",
        "logsink",
        "dialogs",
        "http",
        "rust",
    ] {
        registry_sources.push(paths.generated.join(format!("{name}api.c")));
    }
    if matches!(preset.shaders, ShaderMode::Runtime) {
        registry_sources.push(paths.generated.join("shadercapi.c"));
        registry_sources.push(paths.generated.join("spvcapi.c"));
    }
    let registry_objects = registry_sources
        .iter()
        .map(|source| compile_c(root, preset, paths, source, &includes, &[], true))
        .collect::<Result<Vec<_>>>()?;
    let registry_archive = paths.out.join("libtecs_registry.a");
    archive(&registry_archive, &registry_objects)?;

    let cjson_module = paths.library.join("cjson.so");
    link_shared(
        preset,
        &cjson_module,
        &cjson_objects,
        &package_link_flags(&[package(packages, "luajit")?]),
        None,
    )?;

    let spirv_cross = if matches!(preset.shaders, ShaderMode::Runtime) {
        Some(link_spirv_cross(root, preset, paths, packages, &includes)?)
    } else {
        None
    };

    let worker_object = compile_c(
        root,
        preset,
        paths,
        &paths.generated.join("worker_anchor.c"),
        &includes,
        &[],
        true,
    )?;
    let worker = paths.library.join(shared_name("tecsworker"));
    let mut worker_flags = vec![
        registry_archive.as_os_str().to_owned(),
        cjson_archive.as_os_str().to_owned(),
    ];
    worker_flags.extend(force_load(rust_archive));
    worker_flags.extend(native_dependency_flags(packages, spirv_cross.as_deref())?);
    worker_flags.extend(rust_platform_flags());
    link_shared(
        preset,
        &worker,
        &[worker_object],
        &worker_flags,
        Some("tecsworker"),
    )?;

    let main_object = compile_c(
        root,
        preset,
        paths,
        &paths.generated.join("sdl_main.c"),
        &includes,
        &[],
        true,
    )?;
    let executable = paths.binary.join(executable_name());
    let worker_link = if std::env::consts::OS == "windows" {
        paths.library.join("tecsworker.lib")
    } else {
        worker.clone()
    };
    let mut final_flags = vec![
        registry_archive.as_os_str().to_owned(),
        worker_link.into_os_string(),
        cjson_archive.as_os_str().to_owned(),
    ];
    final_flags.extend(native_dependency_flags(packages, spirv_cross.as_deref())?);
    final_flags.push(rust_archive.as_os_str().to_owned());
    final_flags.extend(rust_platform_flags());
    link_executable(preset, paths, &executable, &[main_object], &final_flags)?;
    Ok(())
}

fn compile_and_link_single(
    root: &Path,
    preset: Preset,
    paths: &Paths,
    packages: &BTreeMap<&'static str, Package>,
    rust_archive: &Path,
) -> Result<()> {
    if std::env::consts::OS == "windows" {
        anyhow::bail!("the single-file linker is not yet supported on Windows");
    }
    let payload_source = paths.generated.join("payload_data.c");
    payload::generate(
        &[
            PayloadRoot {
                prefix: "lua".into(),
                directory: paths.lua.clone(),
            },
            PayloadRoot {
                prefix: "teal".into(),
                directory: paths.teal.clone(),
            },
            PayloadRoot {
                prefix: "notices".into(),
                directory: paths.notices.clone(),
            },
        ],
        &payload_source,
    )?;

    let mut includes = vec![
        root.join("native"),
        root.join("cli"),
        paths.generated.clone(),
    ];
    for package in packages.values() {
        includes.extend(package.includes.clone());
    }
    includes.sort();
    includes.dedup();

    let cjson_objects = CJSON_SOURCES
        .iter()
        .map(|source| {
            compile_c(
                root,
                preset,
                paths,
                &root.join(source),
                &includes,
                &["USE_INTERNAL_FPCONV", "MULTIPLE_THREADS"],
                false,
            )
        })
        .collect::<Result<Vec<_>>>()?;
    let cjson_archive = paths.out.join("libtecs_cjson.a");
    archive(&cjson_archive, &cjson_objects)?;

    let mut registry_sources = vec![paths.generated.join("registry_install.c")];
    for name in [
        "sdl3",
        "sdl3mixer",
        "zlib",
        "worker",
        "logsink",
        "dialogs",
        "http",
        "rust",
        "shaderc",
        "spvc",
    ] {
        registry_sources.push(paths.generated.join(format!("{name}api.c")));
    }
    let registry_objects = registry_sources
        .iter()
        .map(|source| compile_c(root, preset, paths, source, &includes, &[], true))
        .collect::<Result<Vec<_>>>()?;
    let registry_archive = paths.out.join("libtecs_registry.a");
    archive(&registry_archive, &registry_objects)?;

    let main_object = compile_c(
        root,
        preset,
        paths,
        &paths.generated.join("sdl_main.c"),
        &includes,
        &["TECS_PAYLOAD=1"],
        true,
    )?;
    let payload_object = compile_c(root, preset, paths, &payload_source, &includes, &[], true)?;
    let mut flags = vec![
        registry_archive.into_os_string(),
        cjson_archive.into_os_string(),
    ];
    flags.extend(force_load(rust_archive));
    flags.extend(pinned_static_archives(paths)?);
    flags.extend(rust_platform_flags());
    if std::env::consts::OS == "macos" {
        flags.extend(sdl_macos_static_flags());
        flags.push("-lc++".into());
        flags.push("-Wl,-no_compact_unwind".into());
    } else {
        flags.push("-lstdc++".into());
    }
    let executable = paths.binary.join(executable_name());
    link_executable(
        preset,
        paths,
        &executable,
        &[main_object, payload_object],
        &flags,
    )
}

fn pinned_static_archives(paths: &Paths) -> Result<Vec<OsString>> {
    let library = paths.dependencies.join("prefix/lib");
    let mut archives: Vec<_> = WalkDir::new(&library)
        .into_iter()
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|entry| {
            entry.file_type().is_file()
                && matches!(
                    entry.path().extension().and_then(|value| value.to_str()),
                    Some("a" | "lib")
                )
        })
        .map(|entry| entry.into_path())
        .collect();
    archives.sort();
    if archives.is_empty() {
        anyhow::bail!(
            "no pinned static archives were installed in {}",
            library.display()
        );
    }
    Ok(archives
        .iter()
        .flat_map(|archive| force_load(archive))
        .collect())
}

fn compile_c(
    root: &Path,
    preset: Preset,
    paths: &Paths,
    source: &Path,
    includes: &[PathBuf],
    defines: &[&str],
    warnings: bool,
) -> Result<PathBuf> {
    let relative = source
        .strip_prefix(root)
        .unwrap_or(source)
        .to_string_lossy()
        .replace(['/', '\\', '.'], "_");
    let object = paths.objects.join(format!("{relative}.o"));
    let mut command = if std::env::consts::OS == "windows" {
        let mut command = Command::new("cl");
        command
            .args(["/nologo", "/std:c11", "/O2", "/Zi", "/DNDEBUG", "/c"])
            .arg(source)
            .arg(format!("/Fo{}", object.display()));
        command
    } else {
        let mut command = Command::new("cc");
        command
            .args(["-std=gnu99", "-O2", "-g", "-DNDEBUG", "-fPIC", "-c"])
            .arg(source)
            .arg("-o")
            .arg(&object);
        command
    };
    if std::env::consts::OS == "macos" {
        command.args(["-arch", target_arch(preset)]).arg(format!(
            "-mmacosx-version-min={}",
            preset
                .deployment_target
                .context("macOS preset has no deployment target")?
        ));
    }
    if preset.sanitize {
        command.args(["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]);
    }
    if warnings {
        if std::env::consts::OS == "windows" {
            command.arg("/W4");
        } else {
            command.args(C_WARNINGS);
        }
    }
    for include in includes {
        if std::env::consts::OS == "windows" {
            command.arg(format!("/I{}", include.display()));
        } else {
            command.arg("-I").arg(include);
        }
    }
    for define in defines {
        command.arg(format!(
            "{}{define}",
            if std::env::consts::OS == "windows" {
                "/D"
            } else {
                "-D"
            }
        ));
    }
    run(
        &mut command,
        &format!("C compilation of {}", source.display()),
    )?;
    Ok(object)
}

fn archive(output: &Path, objects: &[PathBuf]) -> Result<()> {
    if output.exists() {
        fs::remove_file(output)?;
    }
    if std::env::consts::OS == "windows" {
        let mut command = Command::new("lib");
        command
            .args(["/nologo"])
            .arg(format!("/OUT:{}", output.display()))
            .args(objects);
        run(&mut command, "static archive creation")
    } else {
        let mut command = Command::new("ar");
        command.args(["qc"]).arg(output).args(objects);
        run(&mut command, "static archive creation")?;
        let mut ranlib = Command::new("ranlib");
        ranlib.arg(output);
        run(&mut ranlib, "static archive index")
    }
}

fn windows_exports(output: &Path) -> Result<Vec<OsString>> {
    let generated = output
        .parent()
        .and_then(Path::parent)
        .context("shared library output has no build root")?
        .join("generated");
    let address = Regex::new(r"=\s*&([A-Za-z_][A-Za-z0-9_]*)")?;
    let mut symbols = BTreeSet::new();
    for name in ["worker", "logsink", "dialogs", "http", "rust"] {
        let source = fs::read_to_string(generated.join(format!("{name}api.c")))?;
        symbols.extend(
            address
                .captures_iter(&source)
                .map(|capture| capture[1].to_owned()),
        );
    }
    Ok(symbols
        .into_iter()
        .map(|symbol| format!("/export:{symbol}").into())
        .collect())
}

fn link_shared(
    preset: Preset,
    output: &Path,
    objects: &[PathBuf],
    flags: &[OsString],
    install_name: Option<&str>,
) -> Result<()> {
    let mut command = if std::env::consts::OS == "windows" {
        let mut command = Command::new("link");
        command
            .args(["/nologo", "/dll"])
            .arg(format!("/out:{}", output.display()));
        command
    } else {
        Command::new("cc")
    };
    if std::env::consts::OS == "windows" {
        if output.file_name().and_then(|value| value.to_str()) == Some("cjson.so") {
            command.arg("/export:luaopen_cjson");
        } else if install_name == Some("tecsworker") {
            command.args(windows_exports(output)?);
        }
        command.arg(format!(
            "/implib:{}",
            output.with_extension("lib").display()
        ));
    } else if std::env::consts::OS == "macos" {
        if output.extension().and_then(|value| value.to_str()) == Some("so") {
            command.arg("-bundle");
        } else {
            command.arg("-dynamiclib");
        }
        command.args(["-arch", target_arch(preset)]).arg(format!(
            "-mmacosx-version-min={}",
            preset
                .deployment_target
                .context("macOS preset has no deployment target")?
        ));
        if let Some(name) = install_name {
            command
                .arg("-install_name")
                .arg(format!("@rpath/{}", shared_name(name)));
        }
        command.arg("-Wl,-rpath,@loader_path");
    } else {
        command.arg("-shared");
        if let Some(name) = install_name {
            command.arg(format!("-Wl,-soname,{}", shared_name(name)));
        }
        command.arg("-Wl,-rpath,$ORIGIN");
    }
    if preset.sanitize {
        command.args(["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]);
    }
    if std::env::consts::OS == "windows" {
        command.args(objects).args(flags);
    } else {
        command.arg("-o").arg(output).args(objects).args(flags);
    }
    run(&mut command, &format!("linking {}", output.display()))
}

fn link_executable(
    preset: Preset,
    paths: &Paths,
    output: &Path,
    objects: &[PathBuf],
    flags: &[OsString],
) -> Result<()> {
    let mut command = if std::env::consts::OS == "windows" {
        let mut command = Command::new("link");
        command
            .args(["/nologo"])
            .arg(format!("/out:{}", output.display()));
        command
    } else {
        let mut command = Command::new("cc");
        command.args(["-O2", "-g"]);
        command
    };
    if std::env::consts::OS == "macos" {
        command.args(["-arch", target_arch(preset)]).arg(format!(
            "-mmacosx-version-min={}",
            preset
                .deployment_target
                .context("macOS preset has no deployment target")?
        ));
        if matches!(preset.dependencies, DependencyMode::System) {
            command.arg(format!("-Wl,-rpath,{}", paths.library.display()));
        }
        command.arg("-Wl,-rpath,@executable_path/../lib");
    } else if std::env::consts::OS != "windows" {
        if matches!(preset.dependencies, DependencyMode::System) {
            command.arg(format!("-Wl,-rpath,{}", paths.library.display()));
        }
        command.arg("-Wl,-rpath,$ORIGIN/../lib");
    }
    if preset.sanitize {
        command.args(["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]);
    }
    if std::env::consts::OS == "windows" {
        command.args(objects).args(flags);
    } else {
        command.arg("-o").arg(output).args(objects).args(flags);
    }
    run(&mut command, &format!("linking {}", output.display()))
}

fn link_spirv_cross(
    root: &Path,
    preset: Preset,
    paths: &Paths,
    packages: &BTreeMap<&'static str, Package>,
    includes: &[PathBuf],
) -> Result<PathBuf> {
    let anchor = compile_c(
        root,
        preset,
        paths,
        &paths.generated.join("spvc_anchor.c"),
        includes,
        &[],
        true,
    )?;
    let package = package(packages, "spvc")?;
    let directory = package
        .library_directories
        .first()
        .context("SPIRV-Cross has no library directory")?;
    let mut archives = Vec::new();
    for name in [
        "spirv-cross-c",
        "spirv-cross-cpp",
        "spirv-cross-msl",
        "spirv-cross-glsl",
        "spirv-cross-hlsl",
        "spirv-cross-reflect",
        "spirv-cross-util",
        "spirv-cross-core",
    ] {
        let path = directory.join(format!("lib{name}.a"));
        if !path.is_file() {
            anyhow::bail!("SPIRV-Cross archive {} was not found", path.display());
        }
        archives.push(path);
    }
    let output = paths.library.join(shared_name("spirvcrossc"));
    let mut command = Command::new("c++");
    if std::env::consts::OS == "macos" {
        command
            .args(["-dynamiclib", "-Wl,-all_load", "-arch", target_arch(preset)])
            .arg(format!(
                "-mmacosx-version-min={}",
                preset
                    .deployment_target
                    .context("macOS preset has no deployment target")?
            ))
            .arg("-install_name")
            .arg(format!("@rpath/{}", shared_name("spirvcrossc")));
    } else {
        command.args(["-shared", "-Wl,--whole-archive"]);
    }
    command.arg("-o").arg(&output).arg(anchor).args(&archives);
    if std::env::consts::OS != "macos" {
        command.arg("-Wl,--no-whole-archive");
    }
    run(&mut command, "linking SPIRV-Cross FFI library")?;
    Ok(output)
}

fn native_dependency_flags(
    packages: &BTreeMap<&'static str, Package>,
    spirv_cross: Option<&Path>,
) -> Result<Vec<OsString>> {
    let mut flags = package_link_flags(&[
        package(packages, "sdl3mixer")?,
        package(packages, "sdl3")?,
        package(packages, "zlib")?,
    ]);
    if let Some(spirv_cross) = spirv_cross {
        flags.extend(package_link_flags(&[package(packages, "shaderc")?]));
        flags.push(spirv_cross.as_os_str().to_owned());
    }
    flags.extend(package_link_flags(&[package(packages, "luajit")?]));
    Ok(flags)
}

fn package_link_flags(packages: &[&Package]) -> Vec<OsString> {
    let mut flags = Vec::new();
    for package in packages {
        let _ = package.name;
        for directory in &package.library_directories {
            flags.push(OsString::from(if std::env::consts::OS == "windows" {
                format!("/libpath:{}", directory.display())
            } else {
                format!("-L{}", directory.display())
            }));
        }
        for library in &package.libraries {
            flags.push(OsString::from(if std::env::consts::OS == "windows" {
                format!("{library}.lib")
            } else {
                format!("-l{library}")
            }));
        }
    }
    flags
}

fn force_load(archive: &Path) -> Vec<OsString> {
    if std::env::consts::OS == "macos" {
        vec![
            "-Xlinker".into(),
            "-force_load".into(),
            "-Xlinker".into(),
            archive.as_os_str().to_owned(),
        ]
    } else if std::env::consts::OS == "windows" {
        vec![format!("/wholearchive:{}", archive.display()).into()]
    } else {
        vec![
            "-Wl,--whole-archive".into(),
            archive.as_os_str().to_owned(),
            "-Wl,--no-whole-archive".into(),
        ]
    }
}

fn rust_platform_flags() -> Vec<OsString> {
    if std::env::consts::OS == "macos" {
        [
            "-framework",
            "Security",
            "-framework",
            "SystemConfiguration",
            "-framework",
            "CoreFoundation",
            "-liconv",
        ]
        .into_iter()
        .map(OsString::from)
        .collect()
    } else if std::env::consts::OS == "windows" {
        [
            "advapi32.lib",
            "bcrypt.lib",
            "crypt32.lib",
            "iphlpapi.lib",
            "kernel32.lib",
            "ntdll.lib",
            "ole32.lib",
            "secur32.lib",
            "userenv.lib",
            "ws2_32.lib",
        ]
        .into_iter()
        .map(OsString::from)
        .collect()
    } else {
        ["-ldl", "-lpthread", "-lm", "-lc"]
            .into_iter()
            .map(OsString::from)
            .collect()
    }
}

fn sdl_macos_static_flags() -> Vec<OsString> {
    [
        "-lpthread",
        "-lm",
        "-framework",
        "CoreMedia",
        "-framework",
        "CoreVideo",
        "-framework",
        "Cocoa",
        "-Xlinker",
        "-weak_framework",
        "-Xlinker",
        "UniformTypeIdentifiers",
        "-framework",
        "IOKit",
        "-framework",
        "ForceFeedback",
        "-framework",
        "Carbon",
        "-framework",
        "CoreAudio",
        "-framework",
        "AudioToolbox",
        "-framework",
        "AVFoundation",
        "-framework",
        "Foundation",
        "-framework",
        "GameController",
        "-framework",
        "Metal",
        "-framework",
        "QuartzCore",
        "-Xlinker",
        "-weak_framework",
        "-Xlinker",
        "CoreHaptics",
    ]
    .into_iter()
    .map(OsString::from)
    .collect()
}

fn target_arch(preset: Preset) -> &'static str {
    if preset.rust_target.starts_with("aarch64") {
        "arm64"
    } else {
        "x86_64"
    }
}

fn shared_name(stem: &str) -> String {
    match std::env::consts::OS {
        "macos" => format!("lib{stem}.dylib"),
        "windows" => format!("{stem}.dll"),
        _ => format!("lib{stem}.so"),
    }
}

fn executable_name() -> &'static str {
    if std::env::consts::OS == "windows" {
        "tecs.exe"
    } else {
        "tecs"
    }
}

fn write_build_info(preset: Preset, paths: &Paths) -> Result<()> {
    fs::write(
        paths.out.join("build-info.txt"),
        format!(
            "systemDeps={}\nsystem={}\narch={}\n",
            matches!(preset.dependencies, DependencyMode::System),
            target_system(preset),
            target_arch(preset)
        ),
    )?;
    Ok(())
}

fn target_system(preset: Preset) -> &'static str {
    if preset.rust_target.contains("apple-darwin") {
        "macOS"
    } else if preset.rust_target.contains("apple-ios") {
        "iOS"
    } else if preset.rust_target.contains("android") {
        "Android"
    } else if preset.rust_target.contains("windows") {
        "Windows"
    } else {
        "Linux"
    }
}

fn apply_platform_environment(command: &mut Command, preset: Preset) {
    if preset.rust_target.contains("apple-darwin") {
        if let Some(deployment) = preset.deployment_target {
            command.env("MACOSX_DEPLOYMENT_TARGET", deployment);
        }
    }
}

fn run(command: &mut Command, description: &str) -> Result<()> {
    let status = command
        .status()
        .with_context(|| format!("failed to start {description}"))?;
    if status.success() {
        Ok(())
    } else {
        anyhow::bail!("{description} exited with {status}")
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::fs;
    use std::os::unix::fs::symlink;

    use tempfile::tempdir;

    use super::copy_dynamic_libraries;

    #[test]
    fn packaged_library_aliases_remain_symlinks() {
        let source = tempdir().unwrap();
        let destination = tempdir().unwrap();
        fs::write(source.path().join("libSDL3.0.dylib"), b"library").unwrap();
        symlink("libSDL3.0.dylib", source.path().join("libSDL3.dylib")).unwrap();

        copy_dynamic_libraries(source.path(), destination.path()).unwrap();

        let alias = destination.path().join("libSDL3.dylib");
        assert!(fs::symlink_metadata(&alias)
            .unwrap()
            .file_type()
            .is_symlink());
        assert_eq!(
            fs::read_link(alias).unwrap(),
            std::path::PathBuf::from("libSDL3.0.dylib")
        );
    }
}
