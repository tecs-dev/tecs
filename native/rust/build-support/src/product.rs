use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsString;
use std::fs;
use std::path::{Component, Path, PathBuf};
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
pub const CERULEAN_REVISION: &str = "d2420be67e79beaccfe45b064cb478227c03a5ea";
pub const TEALDOC_REVISION: &str = "fb00fe0628b8fc1ff29fcb7e4baa74911bc13788";
// Scintillua is not on LuaRocks and is pure Lua, so it is pinned and copied
// rather than depended on. The lexers give the documentation site every
// language that is not Teal; Teal keeps the compiler's own lexer.
pub const SCINTILLUA_REVISION: &str = "b9986ecad77b1ea73d75bf1e82e6e0fd3b4958b1";
pub const BUSTED_VERSION: &str = "2.2.0-1";
// Teal type definitions for the modules this tree requires from outside itself.
// They are declarations a checker reads and nothing links, so they ship nothing
// and no notice covers them, which is why they are versions rather than
// revisions like the projects the packaged build compiles.
//
// LuaJIT's are not optional: `ffi`, `bit`, `jit`, `string.buffer`, `table.new`
// and `table.clear` are what `src` reaches for, so without this rock
// `cargo xtask check` fails with `module not found: 'ffi'` in every file that
// touches the FFI. Busted's and Luassert's type the Teal specs under
// `spec/tecs`.
pub const LUAJIT_TYPES_VERSION: &str = "0.0.2-1";
pub const BUSTED_TYPES_VERSION: &str = "0.0.1-1";
pub const LUASSERT_TYPES_VERSION: &str = "0.0.1-1";
pub const SDL3_VERSION: &str = "3.4.12";
pub const SDL3_REVISION: &str = "f87239e71e42da91ca317a12eefb82cfbf3393eb";
pub const SDL3_MIXER_VERSION: &str = "3.2.4";
pub const SDL3_MIXER_REVISION: &str = "72a81869b45e249e8e67102db4e98dd2441f05a1";
pub const SDL3_TTF_VERSION: &str = "3.2.2";
pub const SDL3_TTF_REVISION: &str = "a1ce3670aec736ecbf0936c43f2f0cc53aa61e5b";
pub const FREETYPE_REVISION: &str = "9973564cfa63763a3e4ac67c09147899539b1e07";
pub const HARFBUZZ_REVISION: &str = "564bf9818a18709776856533829c0c04950773d6";
// LuaJIT has no releases, so the two constants below are one fact written
// twice: `LUAJIT_ROLLING` is `2.1.` and the Unix timestamp of the commit
// `LUAJIT_REVISION` names, which is what LuaJIT's own build stamps into
// `luajit -v` and into `luajit.pc`. Raising one means raising the other to the
// same commit, or a packaged build and the system version check disagree about
// what the tree pins. Homebrew tracks the tip of `v2.1` and states the
// revision behind each of its versions, so `brew cat luajit` is where the pair
// comes from.
pub const LUAJIT_REVISION: &str = "faaf663340347a78b22ed94c63c24fe090bd9784";
pub const LUAJIT_ROLLING: &str = "2.1.1785192264";
pub const SHADERC_VERSION: &str = "2026.3";
pub const SHADERC_REVISION: &str = "2c8cae778eec0283b44acbe7ed1a386865d78799";
pub const GLSLANG_REVISION: &str = "168d452a4f460d24b588fed08477a81c44ee27a1";
pub const SPIRV_TOOLS_REVISION: &str = "b707790a898e44038547df54580022fc1cf89c3d";
pub const SPIRV_HEADERS_REVISION: &str = "29981f65241605e08b0ede4cfeb999fe3b723c6a";
pub const SPIRV_CROSS_REVISION: &str = "2275d0efc4f2fa46851035d9d3c67c105bc8b99e";
pub const ZLIB_REVISION: &str = "da607da739fa6047df13e66a2af6b8bec7c2a498";

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

    fn prepare(&self) -> Result<()> {
        fs::create_dir_all(&self.out)?;
        for path in [
            &self.lua,
            &self.teal,
            &self.spec,
            &self.generated,
            &self.objects,
            &self.library,
            &self.binary,
            &self.notices,
        ] {
            if path.exists() {
                fs::remove_dir_all(path)?;
            }
            fs::create_dir_all(path)?;
        }
        for path in [&self.cargo, &self.dependencies] {
            fs::create_dir_all(path)?;
        }
        for path in [self.out.join("build-info.txt"), self.out.join("main.lua")] {
            if path.exists() {
                fs::remove_file(path)?;
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
struct Package {
    name: &'static str,
    includes: Vec<PathBuf>,
    compile_flags: Vec<OsString>,
    library_directories: Vec<PathBuf>,
    link_flags: Vec<OsString>,
}

struct CompileOptions<'a> {
    defines: &'a [&'a str],
    flags: &'a [OsString],
    warnings: bool,
}

pub fn build(root: &Path, preset: Preset) -> Result<PathBuf> {
    let paths = Paths::new(root, preset);
    preflight(root, preset)?;
    paths.prepare()?;
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
    let mut command = Command::new(executable);
    command
        .arg("--entry")
        .arg(root.join("main.tl"))
        .args(arguments)
        .current_dir(root);
    apply_development_environment(&mut command, &paths);
    run(&mut command, "Tecs demo")
}

pub fn test(root: &Path, preset: Preset) -> Result<()> {
    let mut rust = Command::new("cargo");
    rust.args(["test", "--locked", "--workspace", "--all-targets"])
        .current_dir(root);
    run(&mut rust, "Rust workspace tests")?;

    build(root, preset)?;
    let paths = Paths::new(root, preset);
    check_product_abi(root, preset, &paths)?;
    for arguments in [
        ["--pattern", "headless_spec"],
        ["--exclude-pattern", "headless_spec"],
    ] {
        let mut command = Command::new(root.join("vendor/bin/busted"));
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
    check_product_abi(root, preset, &paths)
}

fn check_product_abi(root: &Path, preset: Preset, paths: &Paths) -> Result<()> {
    let include_directories = if matches!(preset.dependencies, DependencyMode::System) {
        system_packages(preset)?
            .into_iter()
            .map(|(name, package)| (name, package.includes))
            .collect()
    } else {
        let include = paths.dependencies.join("prefix/include");
        BTreeMap::from([
            ("sdl3", vec![include.clone()]),
            ("sdl3mixer", vec![include.clone()]),
            ("sdl3ttf", vec![include.clone()]),
            ("shaderc", vec![include.clone()]),
            ("spvc", vec![include.join("spirv_cross")]),
            ("zlib", vec![include]),
        ])
    };
    let mut compiler_arguments = Vec::new();
    if std::env::consts::OS == "macos" {
        compiler_arguments.extend([
            OsString::from("-arch"),
            OsString::from(target_arch(preset)),
            OsString::from(format!(
                "-mmacosx-version-min={}",
                preset
                    .deployment_target
                    .context("macOS preset has no deployment target")?
            )),
        ]);
    }
    crate::abi::check_with_options(
        root,
        &paths.lua.join("tecs/ffi"),
        &crate::abi::Options {
            include_directories: &include_directories,
            compiler: if std::env::consts::OS == "windows" {
                "cl"
            } else {
                "cc"
            },
            compiler_arguments: &compiler_arguments,
            msvc: std::env::consts::OS == "windows",
        },
    )
    .map(|_| ())
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
    let runtime = if preset.rust_target.contains("windows") {
        prefix.join("bin")
    } else {
        prefix.join("lib")
    };
    copy_dynamic_libraries(&paths.library, &runtime)?;
    copy_runtime_dependencies(&paths.dependencies.join("prefix/lib"), &runtime)?;
    copy_runtime_dependencies(&paths.dependencies.join("prefix/bin"), &runtime)?;
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
        teal_compiler: &root.join("vendor/bin/tl"),
        teal_types: Some(&root.join("vendor/share/lua/5.1")),
    })?;

    let mut specs = Command::new(root.join("vendor/bin/busted"));
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
        "shapes" | "physics" | "sprites" | "text" | "particles" | "latency" | "http" | "io"
        | "tcp" => name,
        "alloc" | "allocation" => "allocation",
        _ => anyhow::bail!(
            "unknown benchmark {name:?}; expected shapes, physics, sprites, text, \
             particles, latency, http, io, tcp, or allocation"
        ),
    };
    if matches!(source, "io" | "tcp") && preset.sanitize {
        anyhow::bail!(
            "the io and tcp benchmarks run under system LuaJIT, not the instrumented native host; \
             sanitizer preset {preset} would not sanitize it"
        );
    }
    let executable = build(root, preset)?;
    let paths = Paths::new(root, preset);
    let entry = compile_teal_file(
        root,
        &paths,
        &root.join("bench").join(format!("{source}.tl")),
        &format!("bench/{source}.lua"),
    )?;
    let mut command = if matches!(source, "io" | "tcp") {
        let mut command = Command::new("luajit");
        command.arg(entry);
        command
    } else {
        let mut command = Command::new(executable);
        command.arg("--entry").arg(entry);
        command
    };
    command.args(arguments).current_dir(root);
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
        let lowered = name.to_ascii_lowercase();
        if (lowered.ends_with(".dylib")
            || lowered.ends_with(".so")
            || lowered.contains(".so.")
            || lowered.ends_with(".dll"))
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
    if std::env::consts::OS == "windows" {
        let path = std::env::var_os("PATH").unwrap_or_default();
        let mut directories = vec![paths.library.clone()];
        directories.extend(std::env::split_paths(&path));
        if let Ok(path) = std::env::join_paths(directories) {
            command.env("PATH", path);
        }
    }
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
    for path in [&source_root, &build_root, &prefix] {
        validate_owned_path(&paths.out, path, false)?;
    }
    fs::create_dir_all(&source_root)?;
    for path in [&build_root, &prefix] {
        if path.exists() {
            fs::remove_dir_all(path)?;
        }
    }
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
        &source_root,
        &mixer,
        &[
            "external/ogg",
            "external/opus",
            "external/opusfile",
            "external/wavpack",
        ],
    )?;
    let ttf = fetch_source(
        &source_root,
        "sdl3-ttf",
        "https://github.com/libsdl-org/SDL_ttf.git",
        SDL3_TTF_REVISION,
    )?;
    fetch_source_at(
        &source_root,
        &ttf.join("external/freetype"),
        "https://github.com/freetype/freetype.git",
        FREETYPE_REVISION,
    )?;
    fetch_source_at(
        &source_root,
        &ttf.join("external/harfbuzz"),
        "https://github.com/harfbuzz/harfbuzz.git",
        HARFBUZZ_REVISION,
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
        &source_root,
        &shaderc.join("third_party/glslang"),
        "https://github.com/KhronosGroup/glslang.git",
        GLSLANG_REVISION,
    )?;
    fetch_source_at(
        &source_root,
        &shaderc.join("third_party/spirv-tools"),
        "https://github.com/KhronosGroup/SPIRV-Tools.git",
        SPIRV_TOOLS_REVISION,
    )?;
    fetch_source_at(
        &source_root,
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
        &ttf,
        &build_root.join("sdl3-ttf"),
        &prefix,
        &[
            define_bool("BUILD_SHARED_LIBS", shared),
            "-DSDLTTF_VENDORED=ON".into(),
            "-DSDLTTF_HARFBUZZ=ON".into(),
            "-DSDLTTF_PLUTOSVG=OFF".into(),
            "-DSDLTTF_STRICT=ON".into(),
            "-DSDLTTF_SAMPLES=OFF".into(),
        ],
    )?;
    cmake_install(&build_root.join("sdl3-ttf"))?;

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
        pinned_package(
            "sdl3",
            vec![prefix.join("include")],
            vec![library.clone()],
            vec!["SDL3".into()],
        ),
    );
    packages.insert(
        "sdl3mixer",
        pinned_package(
            "sdl3mixer",
            vec![prefix.join("include")],
            vec![library.clone()],
            vec!["SDL3_mixer".into()],
        ),
    );
    packages.insert(
        "sdl3ttf",
        pinned_package(
            "sdl3ttf",
            vec![prefix.join("include")],
            vec![library.clone()],
            vec!["SDL3_ttf".into()],
        ),
    );
    packages.insert(
        "zlib",
        pinned_package(
            "zlib",
            vec![prefix.join("include")],
            vec![library.clone()],
            vec![if preset.rust_target.contains("windows") {
                "zlib".into()
            } else {
                "z".into()
            }],
        ),
    );
    packages.insert(
        "luajit",
        pinned_package(
            "luajit",
            vec![prefix.join("include/luajit-2.1")],
            vec![library.clone()],
            vec![if preset.rust_target.contains("windows") {
                "lua51".into()
            } else {
                "luajit-5.1".into()
            }],
        ),
    );
    packages.insert(
        "shaderc",
        pinned_package(
            "shaderc",
            vec![prefix.join("include")],
            vec![library.clone()],
            vec![if shared {
                "shaderc_shared".into()
            } else {
                "shaderc_combined".into()
            }],
        ),
    );
    packages.insert(
        "spvc",
        pinned_package(
            "spvc",
            vec![prefix.join("include/spirv_cross")],
            vec![library],
            Vec::new(),
        ),
    );
    let _ = root;
    Ok(packages)
}

fn pinned_package(
    name: &'static str,
    includes: Vec<PathBuf>,
    library_directories: Vec<PathBuf>,
    libraries: Vec<String>,
) -> Package {
    let mut compile_flags = Vec::new();
    for include in &includes {
        if std::env::consts::OS == "windows" {
            compile_flags.push(format!("/I{}", include.display()).into());
        } else {
            compile_flags.push("-I".into());
            compile_flags.push(include.as_os_str().to_owned());
        }
    }
    let mut link_flags = Vec::new();
    for directory in &library_directories {
        link_flags.push(
            if std::env::consts::OS == "windows" {
                format!("/libpath:{}", directory.display())
            } else {
                format!("-L{}", directory.display())
            }
            .into(),
        );
    }
    for library in &libraries {
        link_flags.push(
            if std::env::consts::OS == "windows" {
                format!("{library}.lib")
            } else {
                format!("-l{library}")
            }
            .into(),
        );
    }
    Package {
        name,
        includes,
        compile_flags,
        library_directories,
        link_flags,
    }
}

fn define_bool(name: &str, enabled: bool) -> OsString {
    format!("-D{name}={}", if enabled { "ON" } else { "OFF" }).into()
}

fn fetch_source(root: &Path, name: &str, repository: &str, revision: &str) -> Result<PathBuf> {
    let destination = root.join(name);
    fetch_source_at(root, &destination, repository, revision)?;
    Ok(destination)
}

fn fetch_source_at(
    source_cache: &Path,
    destination: &Path,
    repository: &str,
    revision: &str,
) -> Result<()> {
    if revision.len() != 40 || !revision.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        anyhow::bail!(
            "{repository} is pinned to {revision:?}, not an immutable 40-character commit"
        );
    }
    validate_owned_path(source_cache, destination, true)?;
    if destination.exists() && !destination.join(".git").exists() {
        fs::remove_dir_all(destination)?;
    }
    fs::create_dir_all(destination)?;
    if !destination.join(".git").exists() {
        command::run("git", ["init"], destination)?;
        command::run("git", ["remote", "add", "origin", repository], destination)?;
    } else {
        command::run(
            "git",
            ["remote", "set-url", "origin", repository],
            destination,
        )?;
    }

    if git_output(destination, &["rev-parse", "HEAD"])
        .ok()
        .as_deref()
        != Some(revision)
    {
        let mut fetch = Command::new("git");
        fetch
            .args(["fetch", "--depth", "1", "origin", revision])
            .current_dir(destination);
        run(&mut fetch, &format!("fetching {repository} at {revision}"))?;
        command::run(
            "git",
            ["checkout", "--force", "--detach", "FETCH_HEAD"],
            destination,
        )?;
    }
    command::run("git", ["reset", "--hard", revision], destination)?;
    command::run("git", ["clean", "-ffdx"], destination)?;

    let head = git_output(destination, &["rev-parse", "HEAD"])?;
    if head != revision {
        anyhow::bail!(
            "{} resolved {revision} to {head}; refusing a mutable or unexpected checkout",
            destination.display()
        );
    }
    let status = git_output(
        destination,
        &[
            "status",
            "--ignore-submodules=all",
            "--porcelain",
            "--untracked-files=all",
        ],
    )?;
    if !status.is_empty() {
        anyhow::bail!(
            "{} is dirty after restoring {revision}:\n{status}",
            destination.display()
        );
    }
    let residue = git_output(destination, &["clean", "-nffdx"])?;
    if !residue.is_empty() {
        anyhow::bail!(
            "{} retains ignored or untracked files after restoring {revision}:\n{residue}",
            destination.display()
        );
    }
    Ok(())
}

fn validate_owned_path(root: &Path, destination: &Path, reject_git_file: bool) -> Result<()> {
    let root_metadata = fs::symlink_metadata(root)
        .with_context(|| format!("reading dependency source cache {}", root.display()))?;
    if root_metadata.file_type().is_symlink() || !root_metadata.is_dir() {
        anyhow::bail!(
            "dependency source cache {} is not a real directory",
            root.display()
        );
    }
    let canonical_root = root
        .canonicalize()
        .with_context(|| format!("resolving dependency source cache {}", root.display()))?;
    let relative = destination.strip_prefix(root).with_context(|| {
        format!(
            "dependency source {} is outside its owned cache {}",
            destination.display(),
            root.display()
        )
    })?;
    if relative.as_os_str().is_empty() {
        anyhow::bail!(
            "dependency source {} cannot be the cache root itself",
            destination.display()
        );
    }

    let mut current = root.to_path_buf();
    for component in relative.components() {
        match component {
            Component::Normal(name) => current.push(name),
            Component::CurDir => continue,
            _ => {
                anyhow::bail!(
                    "dependency source {} escapes its owned cache {}",
                    destination.display(),
                    root.display()
                );
            }
        }
        match fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                anyhow::bail!(
                    "dependency source path {} is a symbolic link",
                    current.display()
                );
            }
            Ok(metadata) if !metadata.is_dir() => {
                anyhow::bail!(
                    "dependency source path {} is not a directory",
                    current.display()
                );
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }

    if destination.exists() {
        let canonical_destination = destination
            .canonicalize()
            .with_context(|| format!("resolving dependency source {}", destination.display()))?;
        if !canonical_destination.starts_with(&canonical_root) {
            anyhow::bail!(
                "dependency source {} resolves outside its owned cache {}",
                destination.display(),
                root.display()
            );
        }
    }
    if reject_git_file {
        match fs::symlink_metadata(destination.join(".git")) {
            Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
                anyhow::bail!(
                    "dependency source {} has a .git file or link; linked worktrees are not owned caches",
                    destination.display()
                );
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

fn update_submodules(source_cache: &Path, source: &Path, submodules: &[&str]) -> Result<()> {
    for submodule in submodules {
        let directory = source.join(submodule);
        validate_owned_path(source_cache, &directory, false)?;
        validate_submodule_git_directory(source, &directory)?;
    }
    let fingerprint = submodule_fingerprint(source, submodules)?;
    let git_directory = git_output(source, &["rev-parse", "--git-dir"])?;
    let git_directory = if Path::new(&git_directory).is_absolute() {
        PathBuf::from(git_directory)
    } else {
        source.join(git_directory)
    };
    let marker = git_directory.join("tecs-submodules");
    if fs::read_to_string(&marker).ok().as_deref() == Some(fingerprint.as_str())
        && submodules_are_ready(source, submodules)?
    {
        return Ok(());
    }
    let mut command = Command::new("git");
    command
        .args([
            "submodule",
            "update",
            "--init",
            "--force",
            "--depth",
            "1",
            "--",
        ])
        .args(submodules)
        .current_dir(source);
    run(&mut command, "fetching SDL_mixer decoder sources")?;
    for submodule in submodules {
        let directory = source.join(submodule);
        validate_owned_path(source_cache, &directory, false)?;
        validate_submodule_git_directory(source, &directory)?;
        let expected = git_output(source, &["rev-parse", &format!("HEAD:{submodule}")])?;
        command::run("git", ["reset", "--hard", &expected], &directory)?;
        command::run("git", ["clean", "-ffdx"], &directory)?;
    }
    if !submodules_are_ready(source, submodules)? {
        anyhow::bail!(
            "{} has incomplete or mismatched pinned submodules",
            source.display()
        );
    }
    fs::write(marker, fingerprint)?;
    Ok(())
}

fn validate_submodule_git_directory(source: &Path, submodule: &Path) -> Result<()> {
    let metadata = match fs::symlink_metadata(submodule.join(".git")) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    if metadata.file_type().is_symlink() {
        anyhow::bail!(
            "dependency submodule {} has a symbolic-link .git directory",
            submodule.display()
        );
    }
    if metadata.is_dir() {
        return Ok(());
    }
    if !metadata.is_file() {
        anyhow::bail!(
            "dependency submodule {} has an invalid .git entry",
            submodule.display()
        );
    }

    let contents = fs::read_to_string(submodule.join(".git"))
        .with_context(|| format!("reading submodule metadata in {}", submodule.display()))?;
    let git_directory = contents
        .trim()
        .strip_prefix("gitdir:")
        .map(str::trim)
        .context("submodule .git file has no gitdir target")?;
    let git_directory = Path::new(git_directory);
    let git_directory = if git_directory.is_absolute() {
        git_directory.to_path_buf()
    } else {
        submodule.join(git_directory)
    };
    let git_directory = git_directory.canonicalize().with_context(|| {
        format!(
            "resolving submodule Git directory {}",
            git_directory.display()
        )
    })?;
    let source_git = source
        .join(".git")
        .canonicalize()
        .with_context(|| format!("resolving dependency Git directory {}", source.display()))?;
    if !git_directory.starts_with(source_git.join("modules")) {
        anyhow::bail!(
            "dependency submodule {} points its .git file outside the owned checkout",
            submodule.display()
        );
    }
    Ok(())
}

fn submodule_fingerprint(source: &Path, submodules: &[&str]) -> Result<String> {
    let mut fingerprint = git_output(source, &["rev-parse", "HEAD"])?;
    for submodule in submodules {
        fingerprint.push('\n');
        fingerprint.push_str(submodule);
        fingerprint.push('=');
        fingerprint.push_str(&git_output(
            source,
            &["rev-parse", &format!("HEAD:{submodule}")],
        )?);
    }
    Ok(fingerprint)
}

fn submodules_are_ready(source: &Path, submodules: &[&str]) -> Result<bool> {
    for submodule in submodules {
        let directory = source.join(submodule);
        if !directory.join(".git").exists() {
            return Ok(false);
        }
        let expected = git_output(source, &["rev-parse", &format!("HEAD:{submodule}")])?;
        if git_output(&directory, &["rev-parse", "HEAD"])
            .ok()
            .as_deref()
            != Some(&expected)
        {
            return Ok(false);
        }
        if !git_output(
            &directory,
            &["status", "--porcelain", "--untracked-files=all"],
        )?
        .is_empty()
        {
            return Ok(false);
        }
        if !git_output(&directory, &["clean", "-nffdx"])?.is_empty() {
            return Ok(false);
        }
    }
    Ok(true)
}

fn git_output(directory: &Path, arguments: &[&str]) -> Result<String> {
    let output = Command::new("git")
        .args(arguments)
        .current_dir(directory)
        .output()
        .with_context(|| format!("starting git in {}", directory.display()))?;
    if !output.status.success() {
        anyhow::bail!(
            "git {} failed in {}:\n{}",
            arguments.join(" "),
            directory.display(),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(String::from_utf8(output.stdout)
        .context("git emitted non-UTF-8 output")?
        .trim()
        .to_owned())
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
        ("sdl3ttf", "sdl3-ttf"),
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

/// Holds the machine's dependencies to the revisions this tree pins, without
/// building anything.
///
/// This is the same gate a development build runs, exposed so that the command
/// which installs those dependencies can run it too. A preset that builds its
/// dependencies from pinned sources has nothing on the machine to check, so it
/// answers Ok.
pub fn check_system_dependencies(preset: Preset) -> Result<()> {
    if matches!(preset.dependencies, DependencyMode::System) {
        check_system_versions(preset)?;
    }
    Ok(())
}

fn check_system_versions(preset: Preset) -> Result<()> {
    let mut requirements = vec![
        ("SDL3", "sdl3", SDL3_VERSION, false),
        ("SDL3_mixer", "sdl3-mixer", SDL3_MIXER_VERSION, false),
        ("SDL3_ttf", "sdl3-ttf", SDL3_TTF_VERSION, false),
        ("LuaJIT", "luajit", LUAJIT_ROLLING, false),
    ];
    if matches!(preset.shaders, ShaderMode::Runtime) {
        requirements.push(("shaderc", "shaderc", SHADERC_VERSION, true));
    }
    let mut drift = Vec::new();
    for (name, package, revision, prefix) in requirements {
        let found = pkg_output(package, &["--modversion"])?;
        let found = found.trim();
        let expected = revision;
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
    let cflags = pkg_output(package, &["--cflags"])?;
    let flags = pkg_output(package, &["--libs"])?;
    package_from_flags(name, &cflags, &flags)
}

fn package_from_flags(name: &'static str, cflags: &str, flags: &str) -> Result<Package> {
    let compile_flags = parse_shell_flags(cflags, &format!("{name} compiler flags"))?;
    let link_flags = parse_shell_flags(flags, &format!("{name} linker flags"))?;
    Ok(Package {
        name,
        includes: flag_values(&compile_flags, "-I")
            .into_iter()
            .map(PathBuf::from)
            .collect(),
        compile_flags: compile_flags.into_iter().map(OsString::from).collect(),
        library_directories: flag_values(&link_flags, "-L")
            .into_iter()
            .map(PathBuf::from)
            .collect(),
        link_flags: link_flags.into_iter().map(OsString::from).collect(),
    })
}

fn parse_shell_flags(source: &str, description: &str) -> Result<Vec<String>> {
    shlex::split(source).with_context(|| format!("pkg-config emitted malformed {description}"))
}

fn flag_values(flags: &[String], prefix: &str) -> Vec<String> {
    let mut values = Vec::new();
    let mut index = 0;
    while index < flags.len() {
        if flags[index] == prefix {
            if let Some(value) = flags.get(index + 1) {
                values.push(value.clone());
                index += 2;
                continue;
            }
        } else if let Some(value) = flags[index].strip_prefix(prefix) {
            if !value.is_empty() {
                values.push(value.to_owned());
            }
        }
        index += 1;
    }
    values
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
        &root.join("src"),
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
/// Module pages under `docs/` carry only metadata and a title. The generator
/// renders module prose and every `### tecs.*` entry from Teal at build time,
/// so a page on disk holds none of the text or symbols the command looks up.
/// What it needs is the composed Markdown a site build writes beside each
/// page.
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
    let mut ttf = package(packages, "sdl3ttf")?.includes.clone();
    ttf.extend(sdl.clone());
    ttf.extend(native.clone());
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
            name: "sdl3ttf",
            header: "ttf.h",
            keeps: &["/SDL3_ttf/"],
            prefix: "TTF_",
            needed: &[],
            includes: ttf,
            registry_struct: "TecsSdl3TtfApi",
            registry_prefix: "TTF_",
            registry_headers: &["SDL3_ttf/SDL_ttf.h", "SDL3_ttf/SDL_textengine.h"],
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
    let includes = vec![root.join("native"), paths.generated.clone()];
    let compile_flags = package_compile_flags(packages);

    let cjson_objects = CJSON_SOURCES
        .iter()
        .map(|source| {
            compile_c(
                root,
                preset,
                paths,
                &root.join(source),
                &includes,
                CompileOptions {
                    defines: &["USE_INTERNAL_FPCONV", "MULTIPLE_THREADS"],
                    flags: &compile_flags,
                    warnings: false,
                },
            )
        })
        .collect::<Result<Vec<_>>>()?;
    let cjson_archive = paths.out.join("libtecs_cjson.a");
    archive(&cjson_archive, &cjson_objects)?;

    let mut registry_sources = vec![paths.generated.join("registry_install.c")];
    for name in [
        "sdl3",
        "sdl3mixer",
        "sdl3ttf",
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
        .map(|source| {
            compile_c(
                root,
                preset,
                paths,
                source,
                &includes,
                CompileOptions {
                    defines: &[],
                    flags: &compile_flags,
                    warnings: true,
                },
            )
        })
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
        CompileOptions {
            defines: &[],
            flags: &compile_flags,
            warnings: true,
        },
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
        CompileOptions {
            defines: &[],
            flags: &compile_flags,
            warnings: true,
        },
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

    let includes = vec![
        root.join("native"),
        root.join("cli"),
        paths.generated.clone(),
    ];
    let compile_flags = package_compile_flags(packages);

    let cjson_objects = CJSON_SOURCES
        .iter()
        .map(|source| {
            compile_c(
                root,
                preset,
                paths,
                &root.join(source),
                &includes,
                CompileOptions {
                    defines: &["USE_INTERNAL_FPCONV", "MULTIPLE_THREADS"],
                    flags: &compile_flags,
                    warnings: false,
                },
            )
        })
        .collect::<Result<Vec<_>>>()?;
    let cjson_archive = paths.out.join("libtecs_cjson.a");
    archive(&cjson_archive, &cjson_objects)?;

    let mut registry_sources = vec![paths.generated.join("registry_install.c")];
    for name in [
        "sdl3",
        "sdl3mixer",
        "sdl3ttf",
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
        .map(|source| {
            compile_c(
                root,
                preset,
                paths,
                source,
                &includes,
                CompileOptions {
                    defines: &[],
                    flags: &compile_flags,
                    warnings: true,
                },
            )
        })
        .collect::<Result<Vec<_>>>()?;
    let registry_archive = paths.out.join("libtecs_registry.a");
    archive(&registry_archive, &registry_objects)?;

    let main_object = compile_c(
        root,
        preset,
        paths,
        &paths.generated.join("sdl_main.c"),
        &includes,
        CompileOptions {
            defines: &["TECS_PAYLOAD=1"],
            flags: &compile_flags,
            warnings: true,
        },
    )?;
    let payload_object = compile_c(
        root,
        preset,
        paths,
        &payload_source,
        &includes,
        CompileOptions {
            defines: &[],
            flags: &compile_flags,
            warnings: true,
        },
    )?;
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
    options: CompileOptions<'_>,
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
    if options.warnings {
        if std::env::consts::OS == "windows" {
            command.arg("/W4");
            if std::env::var_os("TECS_WERROR").is_some() {
                command.arg("/WX");
            }
        } else {
            command.args(C_WARNINGS);
            if std::env::var_os("TECS_WERROR").is_some() {
                command.arg("-Werror");
            }
        }
    }
    for include in includes {
        if std::env::consts::OS == "windows" {
            command.arg(format!("/I{}", include.display()));
        } else {
            command.arg("-I").arg(include);
        }
    }
    for define in options.defines {
        command.arg(format!(
            "{}{define}",
            if std::env::consts::OS == "windows" {
                "/D"
            } else {
                "-D"
            }
        ));
    }
    command.args(options.flags);
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
        CompileOptions {
            defines: &[],
            flags: &package_compile_flags(packages),
            warnings: true,
        },
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
        package(packages, "sdl3ttf")?,
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
        flags.extend(package.link_flags.iter().cloned());
    }
    flags
}

fn package_compile_flags(packages: &BTreeMap<&'static str, Package>) -> Vec<OsString> {
    packages
        .values()
        .flat_map(|package| package.compile_flags.iter().cloned())
        .collect()
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
    use std::ffi::OsString;
    use std::fs;
    use std::os::unix::fs::symlink;
    use std::process::Command;

    use tempfile::tempdir;

    use super::{
        copy_dynamic_libraries, fetch_source_at, package_from_flags, package_link_flags, Paths,
        GLSLANG_REVISION, LUAJIT_REVISION, SDL3_MIXER_REVISION, SDL3_REVISION, SHADERC_REVISION,
        SPIRV_CROSS_REVISION, SPIRV_HEADERS_REVISION, SPIRV_TOOLS_REVISION, ZLIB_REVISION,
    };

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
    #[test]
    fn preparing_a_build_removes_outputs_but_preserves_caches() {
        let root = tempdir().unwrap();
        let preset = "macos-arm64-dev".parse().unwrap();
        let paths = Paths::new(root.path(), preset);
        for path in [
            &paths.lua,
            &paths.teal,
            &paths.spec,
            &paths.generated,
            &paths.objects,
            &paths.library,
            &paths.binary,
            &paths.notices,
            &paths.cargo,
            &paths.dependencies,
        ] {
            fs::create_dir_all(path).unwrap();
            fs::write(path.join("stale"), b"stale").unwrap();
        }
        fs::write(paths.out.join("build-info.txt"), b"stale").unwrap();
        fs::write(paths.out.join("main.lua"), b"stale").unwrap();

        paths.prepare().unwrap();

        for path in [
            &paths.lua,
            &paths.teal,
            &paths.spec,
            &paths.generated,
            &paths.objects,
            &paths.library,
            &paths.binary,
            &paths.notices,
        ] {
            assert!(path.is_dir());
            assert!(!path.join("stale").exists());
        }
        assert!(paths.cargo.join("stale").is_file());
        assert!(paths.dependencies.join("stale").is_file());
        assert!(!paths.out.join("build-info.txt").exists());
        assert!(!paths.out.join("main.lua").exists());
    }

    #[test]
    fn native_dependencies_are_pinned_to_commits() {
        for revision in [
            SDL3_REVISION,
            SDL3_MIXER_REVISION,
            LUAJIT_REVISION,
            SHADERC_REVISION,
            GLSLANG_REVISION,
            SPIRV_TOOLS_REVISION,
            SPIRV_HEADERS_REVISION,
            SPIRV_CROSS_REVISION,
            ZLIB_REVISION,
        ] {
            assert_eq!(revision.len(), 40);
            assert!(revision.bytes().all(|byte| byte.is_ascii_hexdigit()));
        }
    }

    #[test]
    fn source_fetch_restores_the_exact_clean_commit() {
        let origin = tempdir().unwrap();
        git(origin.path(), &["init"]);
        fs::write(origin.path().join("tracked"), b"original").unwrap();
        git(origin.path(), &["add", "tracked"]);
        let status = Command::new("git")
            .args(["commit", "-m", "Initial"])
            .env("GIT_AUTHOR_NAME", "Test")
            .env("GIT_AUTHOR_EMAIL", "test@example.com")
            .env("GIT_COMMITTER_NAME", "Test")
            .env("GIT_COMMITTER_EMAIL", "test@example.com")
            .current_dir(origin.path())
            .status()
            .unwrap();
        assert!(status.success());
        let revision = git_output_for_test(origin.path(), &["rev-parse", "HEAD"]);

        let source_cache = tempdir().unwrap();
        let checkout = source_cache.path().join("source");
        fetch_source_at(
            source_cache.path(),
            &checkout,
            origin.path().to_str().unwrap(),
            revision.trim(),
        )
        .unwrap();
        fs::write(checkout.join("tracked"), b"modified").unwrap();
        fs::write(checkout.join("untracked"), b"untracked").unwrap();

        fetch_source_at(
            source_cache.path(),
            &checkout,
            origin.path().to_str().unwrap(),
            revision.trim(),
        )
        .unwrap();

        assert_eq!(fs::read(checkout.join("tracked")).unwrap(), b"original");
        assert!(!checkout.join("untracked").exists());
        assert_eq!(
            git_output_for_test(&checkout, &["rev-parse", "HEAD"]).trim(),
            revision.trim()
        );
        assert!(git_output_for_test(
            &checkout,
            &["status", "--porcelain", "--untracked-files=all"]
        )
        .trim()
        .is_empty());
    }

    #[test]
    fn source_fetch_removes_ignored_files() {
        let origin = tempdir().unwrap();
        git(origin.path(), &["init"]);
        fs::write(origin.path().join(".gitignore"), b"ignored\n").unwrap();
        fs::write(origin.path().join("tracked"), b"original").unwrap();
        git(origin.path(), &["add", ".gitignore", "tracked"]);
        commit(origin.path());
        let revision = git_output_for_test(origin.path(), &["rev-parse", "HEAD"]);
        let source_cache = tempdir().unwrap();
        let checkout = source_cache.path().join("source");
        fetch_source_at(
            source_cache.path(),
            &checkout,
            origin.path().to_str().unwrap(),
            revision.trim(),
        )
        .unwrap();
        fs::write(checkout.join("ignored"), b"residue").unwrap();

        fetch_source_at(
            source_cache.path(),
            &checkout,
            origin.path().to_str().unwrap(),
            revision.trim(),
        )
        .unwrap();

        assert!(!checkout.join("ignored").exists());
        assert!(git_output_for_test(&checkout, &["clean", "-nffdx"])
            .trim()
            .is_empty());
    }

    #[test]
    fn source_fetch_rejects_symlink_destinations_without_touching_targets() {
        let source_cache = tempdir().unwrap();
        let outside = tempdir().unwrap();
        fs::write(outside.path().join("protected"), b"outside").unwrap();
        let destination = source_cache.path().join("source");
        symlink(outside.path(), &destination).unwrap();

        let error = fetch_source_at(
            source_cache.path(),
            &destination,
            "unused",
            "0123456789abcdef0123456789abcdef01234567",
        )
        .unwrap_err();

        assert!(error.to_string().contains("symbolic link"));
        assert_eq!(
            fs::read(outside.path().join("protected")).unwrap(),
            b"outside"
        );
    }

    #[test]
    fn source_fetch_rejects_linked_worktree_git_files() {
        let source_cache = tempdir().unwrap();
        let outside = tempdir().unwrap();
        fs::write(outside.path().join("protected"), b"outside").unwrap();
        let destination = source_cache.path().join("source");
        fs::create_dir(&destination).unwrap();
        fs::write(
            destination.join(".git"),
            format!("gitdir: {}\n", outside.path().join("git").display()),
        )
        .unwrap();
        fs::write(destination.join("protected"), b"inside").unwrap();

        let error = fetch_source_at(
            source_cache.path(),
            &destination,
            "unused",
            "0123456789abcdef0123456789abcdef01234567",
        )
        .unwrap_err();

        assert!(error.to_string().contains(".git file"));
        assert_eq!(fs::read(destination.join("protected")).unwrap(), b"inside");
        assert_eq!(
            fs::read(outside.path().join("protected")).unwrap(),
            b"outside"
        );
    }

    #[test]
    fn source_fetch_rejects_paths_outside_the_owned_cache() {
        let parent = tempdir().unwrap();
        let source_cache = parent.path().join("cache");
        fs::create_dir(&source_cache).unwrap();
        let outside = parent.path().join("outside");
        fs::create_dir(&outside).unwrap();
        fs::write(outside.join("protected"), b"outside").unwrap();
        let destination = source_cache.join("../outside");

        let error = fetch_source_at(
            &source_cache,
            &destination,
            "unused",
            "0123456789abcdef0123456789abcdef01234567",
        )
        .unwrap_err();

        assert!(error.to_string().contains("escapes its owned cache"));
        assert_eq!(fs::read(outside.join("protected")).unwrap(), b"outside");
    }

    #[test]
    fn source_fetch_rejects_mutable_references() {
        let source_cache = tempdir().unwrap();
        let checkout = source_cache.path().join("source");
        let error = fetch_source_at(source_cache.path(), &checkout, "unused", "v1.0").unwrap_err();
        assert!(error.to_string().contains("not an immutable"));
    }

    fn commit(directory: &std::path::Path) {
        let status = Command::new("git")
            .args(["commit", "-m", "Initial"])
            .env("GIT_AUTHOR_NAME", "Test")
            .env("GIT_AUTHOR_EMAIL", "test@example.com")
            .env("GIT_COMMITTER_NAME", "Test")
            .env("GIT_COMMITTER_EMAIL", "test@example.com")
            .current_dir(directory)
            .status()
            .unwrap();
        assert!(status.success());
    }

    fn git(directory: &std::path::Path, arguments: &[&str]) {
        assert!(Command::new("git")
            .args(arguments)
            .current_dir(directory)
            .status()
            .unwrap()
            .success());
    }

    fn git_output_for_test(directory: &std::path::Path, arguments: &[&str]) -> String {
        let output = Command::new("git")
            .args(arguments)
            .current_dir(directory)
            .output()
            .unwrap();
        assert!(output.status.success());
        String::from_utf8(output.stdout).unwrap()
    }

    #[test]
    fn pkg_config_preserves_quoted_paths_and_exact_flag_order() {
        let package = package_from_flags(
            "sample",
            "-I'/opt/sample include' -pthread -DSAMPLE=1",
            "-L'/opt/sample lib' -Wl,--start-group -lone -ltwo -Wl,--end-group -pthread",
        )
        .unwrap();

        assert_eq!(
            package.includes,
            [std::path::PathBuf::from("/opt/sample include")]
        );
        assert_eq!(
            package.compile_flags,
            [
                OsString::from("-I/opt/sample include"),
                OsString::from("-pthread"),
                OsString::from("-DSAMPLE=1"),
            ]
        );
        assert_eq!(
            package.library_directories,
            [std::path::PathBuf::from("/opt/sample lib")]
        );
        let expected = [
            OsString::from("-L/opt/sample lib"),
            OsString::from("-Wl,--start-group"),
            OsString::from("-lone"),
            OsString::from("-ltwo"),
            OsString::from("-Wl,--end-group"),
            OsString::from("-pthread"),
        ];
        assert_eq!(package.link_flags, expected);
        assert_eq!(package_link_flags(&[&package]), expected);
    }

    #[test]
    fn pkg_config_rejects_unclosed_shell_quotes() {
        let error = package_from_flags("sample", "-I'unclosed", "-lsample").unwrap_err();
        assert!(error
            .to_string()
            .contains("malformed sample compiler flags"));
    }
}
