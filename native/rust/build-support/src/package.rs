//! Packaging: presets, installs, and the gate on the difference between them.
//!
//! What a release has to carry is not what a checkout has lying around. A
//! checkout reaches an SDK staged in a Nupp build cache, a Cargo target
//! directory, and a material directory it assembles a shader dispatch from
//! every time it starts. None of those exist on the machine a release runs on,
//! so a package carries the four libraries, the compiled component, and the
//! prebuilt shader pack, and it carries no path back to the machine that
//! built it.
//!
//! Two preset kinds hold that line. A development preset links against the
//! staged SDK where it sits and ships no shader pack, which is convenient and not shippable. A release
//! preset links a loader-relative run path and ships the pack, and only a
//! release install passes [`check`]. That gate is the whole point of having
//! two: without it a release is whatever happened to work on one desk.
//!
//! Packaging is native only. The Nupp toolchain stages a host embedding
//! library for the machine it runs on, so there is nothing to cross-link
//! against, and a Windows package is built on Windows.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::str::FromStr;

use anyhow::{Context, Result};

use crate::binaries::{
    binaries, contained_search_path, dependency_is_reachable, display_name, is_shared_library,
    is_system_library, platform_from_build_info, references, Platform, COMPILER_LIBRARY_NAMES,
};
use crate::nupp;

/// Where an installed release is written.
pub const OUTPUT: &str = "out/package";

/// The name the host executable is installed under.
///
/// The crate is `tecs-winit-host` because `winit` is what it drives. A release
/// carries the shorter name, since which windowing library sits inside it is
/// not something a player or a packager has to know.
pub const EXECUTABLE: &str = "tecs-host";

/// The component a release runs as its showcase.
pub const SHOWCASE: &str = "lighting";

/// The component [`test`] runs to prove the packaged native services resolve.
pub const SMOKE: &str = "nativesmoke";

/// The line `nativesmoke` prints when all three service libraries loaded.
///
/// The exit status cannot carry this. `run_headless` in the Rust host never
/// calls `tecs.host.crashed`, so a plugin that raises during install leaves
/// the process exiting zero with nothing on standard output, which is exactly
/// what a missing service library looks like. Matching the line is what makes
/// the smoke run a test rather than a hope.
const SMOKE_SENTINEL: &str = "nativesmoke: every native service resolved";

/// The shader pack a release reads, beside the executable.
///
/// The name is the one `load_pack` in the Rust host searches for, and the host
/// walks up from its own directory, so `bin/` is where the walk finds it on its
/// first step. It is a compatibility surface shared with that search.
const SHADER_PACK: &str = "shaders.tecspack";

/// What a shader pack begins with, and the layout this build reads.
///
/// Both are a compatibility surface shared with
/// `native/rust/winit-host/src/shaderpack.rs`. They are repeated rather than
/// imported because that module lives in the host binary's own crate, which
/// build support does not and should not depend on.
const SHADER_PACK_MAGIC: &[u8] = b"TECSSP";
const SHADER_PACK_VERSION: u32 = 4;

/// The magic, the version, and the material count, which is the least a pack
/// can be and still say what it holds.
const SHADER_PACK_HEADER: usize = SHADER_PACK_MAGIC.len() + 8;

/// Where the material directory a pack is assembled from lives.
const MATERIALS: &str = "assets/materials";

/// The Nupp module whose builtin material list a pack has to agree with.
const MATERIAL_SOURCE: &str = "src/tecs/gpu/materials.nupp";

/// The Rust service crates a package installs, and the library stem each one
/// produces.
///
/// The stems are the compatibility surface `tecs.internal.nativelibrary.open`
/// is called with, so they are spelled here to match those calls rather than to
/// match the crate names, which differ from them on purpose.
const SERVICES: &[(&str, &str)] = &[
    ("tecs-audio", "tecsaudio"),
    ("tecs-gamepad", "tecsgamepad"),
    ("tecs-physics", "tecs_physics"),
];

/// The Cargo package that produces the host executable.
const HOST_PACKAGE: &str = "tecs-winit-host";

/// The environment variable `native/rust/winit-host/build.rs` reads to record a
/// loader-relative run path instead of the staged SDK's absolute one.
const PACKAGED_RUN_PATH: &str = "TECS_PACKAGED_RUN_PATH";

/// The licenses a release ships whatever else it carries.
const REQUIRED_NOTICES: &[&str] = &[
    "share/tecs/THIRD_PARTY_NOTICES.md",
    "share/tecs/LICENSE-MIT",
    "share/tecs/LICENSE-APACHE",
    "share/tecs/cargo-dependencies.txt",
    "share/tecs/cargo-licenses.txt",
    "share/tecs/license-sources.json",
];

/// The license the tree's own crates carry, which their manifests do not spell
/// because the two license files at the repository root do.
const OWN_LICENSE: &str = "MIT OR Apache-2.0";

/// One supported packaging configuration.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Preset {
    /// The name `--preset` selects.
    pub name: &'static str,
    /// The Rust target triple the host and services are built for.
    pub rust_target: &'static str,
    /// Whether the install is relocatable and therefore shippable.
    pub release: bool,
    /// The macOS deployment target exported for the build, where one applies.
    pub deployment_target: Option<&'static str>,
}

impl Preset {
    /// Returns the platform whose binary format an install is inspected with.
    fn platform(self) -> Platform {
        if self.rust_target.contains("windows") {
            Platform::Windows
        } else if self.rust_target.contains("apple") {
            Platform::Macos
        } else {
            Platform::Linux
        }
    }

    /// Returns the `system=` value written into `build-info.txt`.
    ///
    /// The three spellings are the ones `platform_from_build_info` reads, and
    /// they are shared with the Teal path's own build info.
    fn system(self) -> &'static str {
        match self.platform() {
            Platform::Macos => "macOS",
            Platform::Windows => "Windows",
            Platform::Linux => "Linux",
        }
    }

    /// Returns the loader-relative run path a release records, or `None` where
    /// the platform needs none.
    ///
    /// Windows resolves an import beside the executable, so a Windows package
    /// puts every library in `bin/` and records nothing.
    fn run_path(self) -> Option<&'static str> {
        match self.platform() {
            Platform::Macos => Some("@executable_path/../lib"),
            Platform::Linux => Some("$ORIGIN/../lib"),
            Platform::Windows => None,
        }
    }

    /// Returns the directory a loadable library is installed into, relative to
    /// the prefix.
    fn library_directory(self) -> &'static str {
        if self.platform() == Platform::Windows {
            "bin"
        } else {
            "lib"
        }
    }
}

/// The platform matrix a Nupp release covers.
///
/// Each platform carries a development preset and a release preset, and the
/// pair exists so the difference between them is a thing a command can check
/// rather than a thing a reader has to trust.
pub const PRESETS: &[Preset] = &[
    Preset {
        name: "macos-arm64-dev",
        rust_target: "aarch64-apple-darwin",
        release: false,
        deployment_target: Some("15.0"),
    },
    Preset {
        name: "macos-arm64",
        rust_target: "aarch64-apple-darwin",
        release: true,
        deployment_target: Some("11.0"),
    },
    Preset {
        name: "linux-x64-dev",
        rust_target: "x86_64-unknown-linux-gnu",
        release: false,
        deployment_target: None,
    },
    Preset {
        name: "linux-x64",
        rust_target: "x86_64-unknown-linux-gnu",
        release: true,
        deployment_target: None,
    },
    Preset {
        name: "windows-x64-dev",
        rust_target: "x86_64-pc-windows-msvc",
        release: false,
        deployment_target: None,
    },
    Preset {
        name: "windows-x64",
        rust_target: "x86_64-pc-windows-msvc",
        release: true,
        deployment_target: None,
    },
];

impl FromStr for Preset {
    type Err = anyhow::Error;

    fn from_str(name: &str) -> Result<Self, Self::Err> {
        PRESETS
            .iter()
            .copied()
            .find(|preset| preset.name == name)
            .ok_or_else(|| anyhow::anyhow!("unknown preset {name:?}; run `nupp task presets`"))
    }
}

impl fmt::Display for Preset {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.name)
    }
}

/// Returns the release preset for the machine this runs on.
///
/// Packaging defaults to a release rather than to the development preset,
/// because a development install exists to be examined and a release is what
/// anybody actually asks for.
pub fn host_default() -> Result<Preset> {
    let name = match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => "macos-arm64",
        ("linux", "x86_64") => "linux-x64",
        ("windows", "x86_64") => "windows-x64",
        (os, arch) => anyhow::bail!("there is no Nupp preset for {os}/{arch}; pass --preset"),
    };
    name.parse()
}

/// Prints the platform matrix and what each preset produces.
pub fn list() {
    for preset in PRESETS {
        println!(
            "{:<20} {:<26} {}",
            preset.name,
            preset.rust_target,
            if preset.release {
                "release, relocatable, ships a shader pack"
            } else {
                "development, links the staged SDK where it sits"
            }
        );
    }
}

/// Builds and installs a relocatable release tree.
///
/// The components named are built and installed under
/// `share/tecs/components`; naming none installs the showcase and the native
/// smoke component, which is what `test` then runs.
///
/// The prefix is removed before anything is written, so an install is always a
/// clean one and a file a previous run left cannot be mistaken for a file this
/// build produced.
///
/// @param root the repository root
/// @param preset the configuration to build
/// @param components the Nupp component targets to install
/// @return the installed prefix
pub fn install(root: &Path, preset: Preset, components: &[String]) -> Result<PathBuf> {
    require_native_target(preset)?;
    let sdk = nupp::sdk(root).context(
        "packaging needs a Nupp embedding SDK, which is what the host links its runtime from. \
         Set NUPP_SDK, or check the Nupp compiler out beside this tree so its toolchain can \
         stage one.",
    )?;
    let selected: Vec<String> = if components.is_empty() {
        vec![SHOWCASE.to_owned(), SMOKE.to_owned()]
    } else {
        components.to_vec()
    };

    let mut built = Vec::new();
    for component in &selected {
        nupp::build(root, component)?;
        let path = root.join(nupp::OUTPUT).join(format!("{component}.nuppc"));
        if !path.is_file() {
            anyhow::bail!(
                "target {component:?} produced no component at {}; only a \
                 `kind = \"component\"` target in nupp.lua can be packaged",
                path.display()
            );
        }
        built.push(path);
    }

    build_native(root, preset, &sdk)?;

    let prefix = root.join(OUTPUT);
    if prefix.exists() {
        fs::remove_dir_all(&prefix)?;
    }
    let libraries = prefix.join(preset.library_directory());
    for directory in [
        prefix.join("bin"),
        libraries.clone(),
        prefix.join("share/tecs/components"),
    ] {
        fs::create_dir_all(&directory)?;
    }

    let artifacts = root
        .join("target")
        .join(preset.rust_target)
        .join(if preset.release { "release" } else { "debug" });
    let executable = prefix.join("bin").join(executable_name(preset));
    copy_file(&artifacts.join(host_artifact(preset)), &executable)?;
    let runtime = runtime_library(preset, &sdk);
    copy_file(&sdk.join(&runtime), &libraries.join(&runtime))?;
    for (_, stem) in SERVICES {
        let file = service_library(preset, stem);
        copy_file(&artifacts.join(&file), &libraries.join(&file))?;
    }
    for component in &built {
        let name = component
            .file_name()
            .context("a built component has no file name")?;
        copy_file(component, &prefix.join("share/tecs/components").join(name))?;
    }
    for notice in ["THIRD_PARTY_NOTICES.md", "LICENSE-MIT", "LICENSE-APACHE"] {
        copy_file(&root.join(notice), &prefix.join("share/tecs").join(notice))?;
    }
    copy_runtime_notices(&sdk, &prefix)?;

    if preset.platform() == Platform::Macos {
        relocate_install_names(&libraries)?;
    }
    if preset.release {
        pack_shaders(root, &prefix, &executable)?;
    }
    write_inventory(root, preset, &prefix)?;
    write_build_info(root, preset, &prefix, &selected)?;
    Ok(prefix)
}

/// Verifies that an installed Nupp release is complete and relocatable.
///
/// A development install is reported rather than refused, because it is not
/// pretending to be shippable. Everything a release claims is checked: what it
/// carries, that no search path or link leaves the prefix, that no shader
/// compiler came along, and that every Cargo package it ships has a recorded
/// license.
///
/// @param prefix the installed prefix to inspect
/// @return nothing, and raises with every problem found rather than the first
pub fn check(prefix: &Path) -> Result<()> {
    let prefix = prefix
        .canonicalize()
        .with_context(|| format!("no such install prefix: {}", prefix.display()))?;
    let info = prefix.join("share/tecs/build-info.txt");
    let build_info =
        fs::read_to_string(&info).with_context(|| format!("reading {}", info.display()))?;
    let platform = platform_from_build_info(&build_info)?;
    let development = build_info.contains("development=true");

    let mut problems = Vec::new();
    check_contents(&prefix, platform, development, &mut problems)?;
    check_license_position(&prefix, &mut problems)?;
    check_manifest_paths(&prefix, &mut problems)?;
    check_binaries(&prefix, platform, &mut problems)?;

    println!("checked {}", prefix.display());
    if development {
        println!("\ndevelopment install: it is not relocatable and was not held to that.");
        println!("Build a release with `nupp task package --preset <name>`.");
        if !problems.is_empty() {
            println!(
                "\n{} references to the build machine, which a release would not have:",
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

/// Installs a clean release, checks it, and runs it from a relocated copy.
///
/// The relocation is the part a check cannot do. An install is only
/// relocatable if it still runs after it moves, and it moves here into a
/// temporary directory with an unrelated working directory and every Tecs
/// environment variable removed, so nothing the build machine exports can be
/// standing in for something the package should have carried.
///
/// @param root the repository root
/// @param preset the configuration to build and run
/// @return nothing, and raises when the installed release does not run
pub fn test(root: &Path, preset: Preset) -> Result<()> {
    let prefix = install(root, preset, &[])?;
    check(&prefix)?;
    if !preset.release {
        println!("development preset: nothing to run from a relocated copy");
        return Ok(());
    }

    let scratch = tempfile::Builder::new().prefix("tecs-package.").tempdir()?;
    let moved = scratch.path().join("tecs");
    copy_tree(&prefix, &moved)?;

    let executable = moved.join("bin").join(executable_name(preset));
    let smoke = moved
        .join("share/tecs/components")
        .join(format!("{SMOKE}.nuppc"));
    let output = installed_run(
        &executable,
        &[
            "--component".as_ref(),
            smoke.as_os_str(),
            "--entry".as_ref(),
            format!("{SMOKE}.create").as_ref(),
            "--headless".as_ref(),
            "--frames".as_ref(),
            "1".as_ref(),
        ],
        scratch.path(),
    )?;
    if !output.contains(SMOKE_SENTINEL) {
        anyhow::bail!(
            "the relocated install did not resolve its native services. \
             Expected {SMOKE_SENTINEL:?} on standard output, and got:\n{output}"
        );
    }
    println!("{}", output.trim_end());

    let showcase = moved
        .join("share/tecs/components")
        .join(format!("{SHOWCASE}.nuppc"));
    if showcase.is_file() {
        installed_run(
            &executable,
            &[
                "--component".as_ref(),
                showcase.as_os_str(),
                "--entry".as_ref(),
                format!("{SHOWCASE}.create").as_ref(),
                "--headless".as_ref(),
                "--frames".as_ref(),
                "2".as_ref(),
            ],
            scratch.path(),
        )?;
        println!("the relocated install ran {SHOWCASE} headless");
    }
    println!("installed release runs from {}", moved.display());
    Ok(())
}

/// Refuses a preset that names a target this machine cannot link.
fn require_native_target(preset: Preset) -> Result<()> {
    let native = host_default()?;
    if native.rust_target != preset.rust_target {
        anyhow::bail!(
            "cannot package {} on this machine: the Nupp toolchain stages an embedding library \
             for the host it runs on, so there is nothing to link {} against. Build that \
             preset's package on that platform.",
            preset.name,
            preset.rust_target
        );
    }
    Ok(())
}

/// Builds the host executable and the three service libraries.
fn build_native(root: &Path, preset: Preset, sdk: &Path) -> Result<()> {
    let mut command = Command::new("cargo");
    command.args(["build", "--locked", "--target", preset.rust_target]);
    if preset.release {
        command.arg("--release");
    }
    command.args(["--package", HOST_PACKAGE]);
    for (package, _) in SERVICES {
        command.args(["--package", package]);
    }
    command.env("NUPP_SDK", sdk).current_dir(root);
    // A release records the run path its own layout puts the runtime library
    // at. A development build records nothing, so `build.rs` falls back to the
    // staged SDK's absolute path, which is what makes the difference between
    // the two presets something `check` can see.
    if preset.release {
        if let Some(run_path) = preset.run_path() {
            command.env(PACKAGED_RUN_PATH, run_path);
        }
    }
    if let Some(deployment) = preset.deployment_target {
        command.env("MACOSX_DEPLOYMENT_TARGET", deployment);
    }
    let status = command
        .status()
        .context("failed to start Cargo for the Tecs host and its native services")?;
    if !status.success() {
        anyhow::bail!("cargo build for {} exited with {status}", preset.name);
    }
    Ok(())
}

/// Rewrites an absolute Mach-O install name to a loader-relative one.
///
/// Cargo gives a `cdylib` the absolute path it wrote it to as its install name,
/// so a copied library still says where it was built. Nothing in Tecs links
/// against these three by name, since `tecs.internal.nativelibrary` loads them
/// into the process namespace at run time, but a shipped file that names a
/// Cargo target directory is a build-machine path in a release, and `check`
/// refuses one.
///
/// The alternative was a per-crate `-install_name` link argument, and it loses:
/// Cargo applies `RUSTFLAGS` to a whole invocation, so three different install
/// names mean three builds that each invalidate the previous one's cache.
///
/// Editing a Mach-O file invalidates its signature and an arm64 macOS refuses
/// to load an unsigned one, so each edited file is signed again. This runs on
/// macOS alone, since ELF and PE carry no equivalent of an install name.
fn relocate_install_names(directory: &Path) -> Result<()> {
    for entry in fs::read_dir(directory)
        .with_context(|| format!("reading {}", directory.display()))?
        .flatten()
    {
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("dylib") {
            continue;
        }
        let name = path
            .file_name()
            .and_then(|value| value.to_str())
            .context("a packaged library has no usable file name")?
            .to_owned();
        let output = Command::new("otool")
            .arg("-D")
            .arg(&path)
            .output()
            .with_context(|| format!("reading the install name of {}", path.display()))?;
        // `otool -D` prints the file it read as a heading before the install
        // name, and that heading is an absolute path. Skipping it is what keeps
        // a library that already names `@rpath` from being rewritten and signed
        // again for nothing.
        let current = String::from_utf8_lossy(&output.stdout);
        let absolute = current
            .lines()
            .map(str::trim)
            .filter(|line| !line.ends_with(':') && !line.is_empty())
            .any(|line| line.starts_with('/'));
        if !absolute {
            continue;
        }
        let relative = format!("@rpath/{name}");
        let steps: [(&str, Vec<&str>); 2] = [
            ("install_name_tool", vec!["-id", relative.as_str()]),
            ("codesign", vec!["--force", "--sign", "-"]),
        ];
        for (program, arguments) in steps {
            let status = Command::new(program)
                .args(&arguments)
                .arg(&path)
                .status()
                .with_context(|| format!("running {program} on {}", path.display()))?;
            if !status.success() {
                anyhow::bail!("{program} on {} exited with {status}", path.display());
            }
        }
    }
    Ok(())
}

/// Assembles the shader pack with the packaged host and records what is in it.
///
/// The pack is written by the installed executable rather than by a build-tree
/// one, so the first thing this proves is that the relinked binary starts and
/// finds its runtime library through the run path the package recorded. The
/// material list it prints becomes the manifest beside the pack, and it is
/// checked against the builtin list the Nupp side numbers from, because the two
/// have to agree for an id in a packet to select the material a game asked for.
fn pack_shaders(root: &Path, prefix: &Path, executable: &Path) -> Result<()> {
    let materials = root.join(MATERIALS);
    let pack = prefix.join("bin").join(SHADER_PACK);
    let output = Command::new(executable)
        .arg("--pack-shaders")
        .arg(&materials)
        .arg(&pack)
        .current_dir(root)
        .output()
        .with_context(|| format!("running {}", executable.display()))?;
    if !output.status.success() {
        anyhow::bail!(
            "assembling the shader pack exited with {}:\n{}{}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    let summary =
        String::from_utf8(output.stdout).context("the shader pack summary is not UTF-8")?;
    let summary = summary.trim();
    // The source is named relative to the repository, not as the absolute path
    // this build read. The manifest ships, and a shipped file that names the
    // desk it was assembled on is the thing `check` refuses everywhere else.
    fs::write(
        prefix.join("bin").join(format!("{SHADER_PACK}.txt")),
        format!("{MATERIALS}\n{summary}\n"),
    )?;
    check_material_parity(root, summary)?;
    println!("{summary}");
    Ok(())
}

/// Holds the packed material set to the builtin set the engine numbers from.
///
/// `tecs.gpu.materials` bakes its builtin names in and assigns ids from them,
/// and the pack assigns ids from a directory. A packet names a material by id,
/// so a name in one list and not the other draws the wrong shape rather than
/// failing, which is the sort of defect a release must not be able to ship.
fn check_material_parity(root: &Path, summary: &str) -> Result<()> {
    let packed: BTreeSet<_> = summary
        .split_once(": ")
        .map_or(summary, |(_, names)| names)
        .split(", ")
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .collect();
    let source = root.join(MATERIAL_SOURCE);
    let text = fs::read_to_string(&source).with_context(|| {
        format!(
            "reading the builtin material list from {}",
            source.display()
        )
    })?;
    let builtins = builtin_materials(&text).with_context(|| {
        format!(
            "reading the BUILTINS list from {}; the packaging check needs it to hold the pack to \
             what the engine can name",
            source.display()
        )
    })?;
    if packed == builtins {
        return Ok(());
    }
    let only_packed: Vec<_> = packed.difference(&builtins).copied().collect();
    let only_builtin: Vec<_> = builtins.difference(&packed).copied().collect();
    anyhow::bail!(
        "the shader pack and {} disagree about which materials exist, so an id in a frame packet \
         would not select the material a game asked for.\n  only in the pack: {}\n  only in the \
         engine: {}",
        MATERIAL_SOURCE,
        format_list(&only_packed),
        format_list(&only_builtin)
    );
}

/// Reads the quoted names out of the `BUILTINS` table in a Nupp source.
///
/// The opening brace is found after the `=`, not after the name. The
/// declaration carries its type first, and that type is a table type spelled
/// with braces of its own, so the first brace after `BUILTINS` opens `{string}`
/// and holds no name at all.
fn builtin_materials(source: &str) -> Option<BTreeSet<&str>> {
    let start = source.find("BUILTINS")?;
    let assignment = source[start..].find('=')? + start;
    let open = source[assignment..].find('{')? + assignment;
    let close = source[open..].find('}')? + open;
    let mut names = BTreeSet::new();
    let mut rest = &source[open..close];
    while let Some(quote) = rest.find('"') {
        rest = &rest[quote + 1..];
        let end = rest.find('"')?;
        names.insert(&rest[..end]);
        rest = &rest[end + 1..];
    }
    (!names.is_empty()).then_some(names)
}

/// Formats a name list for a failure message, or says the list is empty.
fn format_list(names: &[&str]) -> String {
    if names.is_empty() {
        "none".to_owned()
    } else {
        names.join(", ")
    }
}

/// Writes the Cargo package inventory and the license recorded for each entry.
///
/// The two files are separate because they answer separate questions. The
/// inventory says what code is in the package, resolved for this target and
/// these features rather than read off a manifest. The license file says what
/// each of those packages is licensed under, and `check` refuses an install
/// where an entry has no answer.
/// Copies the Nupp distribution's own third-party notices beside ours.
///
/// The package ships `libnupp`, and that library carries LuaJIT, LPeg and
/// lunajson inside it. Each is permissive and each asks for its copyright
/// notice to travel with a distribution, so a package holding the code and not
/// the notice is exactly the compliance failure `THIRD_PARTY_NOTICES.md` says
/// this engine could commit on its own.
///
/// The notices sit beside the staged SDK in the Nupp checkout rather than in
/// the SDK directory itself, so this walks up to find them and reports rather
/// than guessing when it cannot.
fn copy_runtime_notices(sdk: &Path, prefix: &Path) -> Result<()> {
    let mut directory = sdk;
    let source = loop {
        let candidate = directory.join("host/notices");
        if candidate.is_dir() {
            break candidate;
        }
        directory = directory.parent().context(
            "no host/notices above the staged Nupp SDK; the runtime ships without its notices",
        )?;
    };
    let target = prefix.join("share/tecs/notices");
    std::fs::create_dir_all(&target).with_context(|| format!("create {}", target.display()))?;
    for entry in std::fs::read_dir(&source)
        .with_context(|| format!("read {}", source.display()))?
        .flatten()
    {
        let path = entry.path();
        if path.is_file() {
            let name = path.file_name().context("a notice has no file name")?;
            copy_file(&path, &target.join(name))?;
        }
    }
    Ok(())
}

fn write_inventory(root: &Path, preset: Preset, prefix: &Path) -> Result<()> {
    let mut tree = Command::new("cargo");
    tree.args([
        "tree",
        // CI enables color globally, but this output is a shipped inventory.
        // Colored subtree notes otherwise survive inventory_entry's trimming.
        "--color",
        "never",
        "--locked",
        "--target",
        preset.rust_target,
        "--edges",
        "normal,build",
        "--prefix",
        "none",
        "--format",
        "{p}",
    ]);
    tree.args(["--package", HOST_PACKAGE]);
    for (package, _) in SERVICES {
        tree.args(["--package", package]);
    }
    let output = tree
        .current_dir(root)
        .output()
        .context("running the Cargo dependency inventory")?;
    if !output.status.success() {
        anyhow::bail!(
            "the Cargo dependency inventory exited with {}:\n{}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let listing = String::from_utf8(output.stdout).context("the inventory is not UTF-8")?;
    let packages: BTreeSet<_> = listing
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(inventory_entry)
        .collect();
    if packages.is_empty() {
        anyhow::bail!("the Cargo dependency inventory is empty");
    }
    fs::write(
        prefix.join("share/tecs/cargo-dependencies.txt"),
        format!(
            "{}\n",
            packages.iter().cloned().collect::<Vec<_>>().join("\n")
        ),
    )?;

    let licenses = package_licenses(root)?;
    let mut recorded = String::new();
    let mut missing = Vec::new();
    for entry in &packages {
        let mut fields = entry.split_whitespace();
        let name = fields.next().unwrap_or_default();
        let version = fields.next().unwrap_or_default();
        match licenses.get(&(name.to_owned(), version.trim_start_matches('v').to_owned())) {
            Some(license) => recorded.push_str(&format!("{name} {version} {license}\n")),
            None => missing.push(entry.clone()),
        }
    }
    if !missing.is_empty() {
        anyhow::bail!(
            "{} packages carry no license this build could record, and a package that ships the \
             code has to ship the notice: {}",
            missing.len(),
            missing.join(", ")
        );
    }
    fs::write(prefix.join("share/tecs/cargo-licenses.txt"), recorded)?;
    crate::licensesources::write(root, prefix, &packages)?;
    Ok(())
}

/// Reduces one `cargo tree` line to the name and version a package ships.
///
/// The formatter appends notes in parentheses to some entries, and it appends
/// more than one: `(*)` where a subtree repeats, `(proc-macro)` for a
/// build-time macro, and the package's own directory for a path dependency. A
/// repeated proc-macro carries two, which is why this loops rather than
/// stripping once. The path note is the reason it exists at all: it carries the
/// build machine's absolute path, and a shipped inventory that names the desk
/// it was built on is exactly what the rest of this module refuses.
fn inventory_entry(line: &str) -> String {
    let mut entry = line.trim_end();
    while entry.ends_with(')') {
        let Some(note) = entry.rfind(" (") else { break };
        entry = entry[..note].trim_end();
    }
    entry.to_owned()
}

/// Reads every workspace package's license expression from Cargo metadata.
///
/// The tree's own crates spell no `license` in their manifests, because the two
/// license files at the repository root carry it, so they are answered here
/// rather than left looking like a gap.
fn package_licenses(root: &Path) -> Result<BTreeMap<(String, String), String>> {
    let output = Command::new("cargo")
        .args(["metadata", "--locked", "--format-version", "1"])
        .current_dir(root)
        .output()
        .context("running cargo metadata for package licenses")?;
    if !output.status.success() {
        anyhow::bail!(
            "cargo metadata exited with {}:\n{}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let metadata: serde_json::Value =
        serde_json::from_slice(&output.stdout).context("cargo metadata is not JSON")?;
    let packages = metadata["packages"]
        .as_array()
        .context("cargo metadata carries no package array")?;
    let mut licenses = BTreeMap::new();
    for package in packages {
        let (Some(name), Some(version)) = (package["name"].as_str(), package["version"].as_str())
        else {
            continue;
        };
        let license = package["license"]
            .as_str()
            .map(str::to_owned)
            .or_else(|| {
                package["license_file"]
                    .as_str()
                    .map(|file| format!("see {file}"))
            })
            .unwrap_or_else(|| OWN_LICENSE.to_owned());
        licenses.insert((name.to_owned(), version.to_owned()), license);
    }
    Ok(licenses)
}

/// Writes what this install is, in the shape the checks read back.
fn write_build_info(
    root: &Path,
    preset: Preset,
    prefix: &Path,
    components: &[String],
) -> Result<()> {
    let compiler = nupp::compiler(root)?;
    let version = Command::new(&compiler)
        .arg("--version")
        .current_dir(root)
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|text| text.trim().to_owned())
        .unwrap_or_else(|| "unknown".to_owned());
    fs::write(
        prefix.join("share/tecs/build-info.txt"),
        format!(
            "implementation=nupp\npreset={}\nsystem={}\ntarget={}\ndevelopment={}\ncompiler={}\n\
             executable=bin/{}\ncomponents={}\n",
            preset.name,
            preset.system(),
            preset.rust_target,
            !preset.release,
            version,
            executable_name(preset),
            components.join(",")
        ),
    )?;
    Ok(())
}

/// Reports what an install is missing.
fn check_contents(
    prefix: &Path,
    platform: Platform,
    development: bool,
    problems: &mut Vec<String>,
) -> Result<()> {
    let executable = prefix.join("bin").join(if platform == Platform::Windows {
        format!("{EXECUTABLE}.exe")
    } else {
        EXECUTABLE.to_owned()
    });
    if !executable.is_file() {
        problems.push(format!(
            "no {}: a package with no host runs nothing",
            executable
                .strip_prefix(prefix)
                .unwrap_or(&executable)
                .display()
        ));
    }
    if !development {
        for relative in [SHADER_PACK.to_owned(), format!("{SHADER_PACK}.txt")] {
            if !prefix.join("bin").join(&relative).is_file() {
                problems.push(format!(
                    "no bin/{relative}: a release links no shader compiler, so it must carry \
                     compiled shaders"
                ));
            }
        }
        if let Some(problem) = shader_pack_problem(&prefix.join("bin").join(SHADER_PACK)) {
            problems.push(problem);
        }
    }
    let components = prefix.join("share/tecs/components");
    let found = fs::read_dir(&components)
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .filter(|entry| {
                    entry.path().extension().and_then(|value| value.to_str()) == Some("nuppc")
                })
                .count()
        })
        .unwrap_or_default();
    if found == 0 {
        problems.push(
            "no *.nuppc under share/tecs/components: a package ships no Nupp compiler, so a \
             compiled component is the only Nupp it can run"
                .to_owned(),
        );
    }
    let directory = if platform == Platform::Windows {
        "bin"
    } else {
        "lib"
    };
    let mut expected: Vec<String> = SERVICES
        .iter()
        .map(|(_, stem)| library_file(platform, stem))
        .collect();
    expected.push(library_file(platform, "nupp"));
    for file in expected {
        if !prefix.join(directory).join(&file).is_file() {
            problems.push(format!(
                "no {directory}/{file}: the loader searches beside the executable and finds \
                 nothing else"
            ));
        }
    }
    Ok(())
}

/// Reports a shader pack the host would refuse to read, or `None`.
///
/// A release loads this file and links nothing that could build another one, so
/// a pack that is truncated, empty or written by a build that moved on is a
/// release that starts and then cannot draw. The header is cheap enough to read
/// here and it is the same header the host checks: six magic bytes, a
/// little-endian version, and a little-endian material count.
///
/// `TECSSP` and version 4 are a compatibility surface shared with
/// `native/rust/winit-host/src/shaderpack.rs`, which is the code that reads
/// them for real.
fn shader_pack_problem(pack: &Path) -> Option<String> {
    let bytes = fs::read(pack).ok()?;
    let name = display_name(pack);
    if bytes.len() < SHADER_PACK_HEADER {
        return Some(format!(
            "{name}: {} bytes is shorter than the header a shader pack begins with",
            bytes.len()
        ));
    }
    if &bytes[..SHADER_PACK_MAGIC.len()] != SHADER_PACK_MAGIC {
        return Some(format!(
            "{name}: does not begin with its magic, so it is not a shader pack"
        ));
    }
    let word =
        |at: usize| u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]]);
    let version = word(SHADER_PACK_MAGIC.len());
    if version != SHADER_PACK_VERSION {
        return Some(format!(
            "{name}: is version {version}, and this build reads {SHADER_PACK_VERSION}"
        ));
    }
    if word(SHADER_PACK_MAGIC.len() + 4) == 0 {
        return Some(format!("{name}: carries no materials at all"));
    }
    None
}

/// Reports a shipped manifest that names the machine the release was built on.
///
/// The binaries are held to this by their run paths and their links, and the
/// text files beside them were not held to anything until a shader-pack
/// manifest shipped naming a checkout in a home directory. None of these four
/// files has a reason to carry an absolute path, so none of them may.
fn check_manifest_paths(prefix: &Path, problems: &mut Vec<String>) -> Result<()> {
    let manifests = [
        "share/tecs/build-info.txt",
        "share/tecs/cargo-dependencies.txt",
        "share/tecs/cargo-licenses.txt",
        &format!("bin/{SHADER_PACK}.txt"),
    ];
    for relative in manifests {
        let path = prefix.join(relative);
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        for token in text.split_whitespace() {
            if is_absolute_path(token) {
                problems.push(format!("{relative}: names a build-machine path: {token}"));
            }
        }
    }
    Ok(())
}

/// Reports whether a token reads as an absolute path on any supported platform.
///
/// A lone `/` is not one. Some crates still spell a dual license the old way,
/// as `Apache-2.0 / MIT`, and the separator arrives here as a token of its own.
fn is_absolute_path(token: &str) -> bool {
    if token.starts_with('/') {
        return token.trim_matches('/').chars().next().is_some();
    }
    let bytes = token.as_bytes();
    bytes.len() > 2
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && (bytes[2] == b'\\' || bytes[2] == b'/')
}

/// Reports a release that ships code without the notice that goes with it.
fn check_license_position(prefix: &Path, problems: &mut Vec<String>) -> Result<()> {
    for notice in REQUIRED_NOTICES {
        if !prefix.join(notice).exists() {
            problems.push(format!(
                "no {notice}: a package that ships the code has to ship the notice"
            ));
        }
    }
    crate::licensesources::check(prefix, problems)?;
    let inventory = prefix.join("share/tecs/cargo-dependencies.txt");
    let recorded = prefix.join("share/tecs/cargo-licenses.txt");
    if !inventory.is_file() || !recorded.is_file() {
        return Ok(());
    }
    let licenses: BTreeSet<_> = fs::read_to_string(&recorded)?
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let name = fields.next()?;
            let version = fields.next()?;
            fields.next().is_some().then(|| format!("{name} {version}"))
        })
        .collect();
    for entry in fs::read_to_string(&inventory)?.lines() {
        let entry = entry.trim();
        if entry.is_empty() {
            continue;
        }
        if !licenses.contains(entry) {
            problems.push(format!(
                "Cargo package {entry} ships with no recorded license in cargo-licenses.txt"
            ));
        }
    }
    Ok(())
}

/// Reports a binary that reaches outside the prefix for anything.
fn check_binaries(prefix: &Path, platform: Platform, problems: &mut Vec<String>) -> Result<()> {
    let found = binaries(prefix)?;
    if found.is_empty() {
        anyhow::bail!("no binaries found under {}", prefix.display());
    }
    let inspections = found
        .iter()
        .map(|binary| {
            Ok((
                binary,
                references(binary, platform)
                    .with_context(|| format!("inspect {}", binary.display()))?,
            ))
        })
        .collect::<Result<Vec<_>>>()?;
    let application_search_paths: Vec<_> = if platform == Platform::Macos {
        inspections
            .iter()
            .filter(|(binary, _)| {
                binary.parent() == Some(prefix.join("bin").as_path()) && !is_shared_library(binary)
            })
            .flat_map(|(binary, (rpaths, _))| {
                rpaths.iter().filter_map(|rpath| {
                    crate::binaries::resolved_search_path(prefix, binary, rpath)
                })
            })
            .collect()
    } else {
        Vec::new()
    };
    for (binary, (rpaths, libraries)) in &inspections {
        for rpath in rpaths {
            if !contained_search_path(prefix, binary, rpath) {
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
                    prefix,
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
        let name = display_name(binary).to_ascii_lowercase();
        for compiler in COMPILER_LIBRARY_NAMES {
            if name.contains(compiler) {
                problems.push(format!(
                    "{name}: a shader compiler must not ship in a release"
                ));
            }
        }
    }
    println!("checked {} binaries", found.len());
    Ok(())
}

/// Runs an installed executable with nothing this tree exports still set.
///
/// Every variable the engine reads as an override is removed rather than left
/// to chance, because a package that only runs because a shell exported
/// `TECS_SHADER_PACK` is not a package that runs.
fn installed_run(
    executable: &Path,
    arguments: &[&std::ffi::OsStr],
    directory: &Path,
) -> Result<String> {
    let mut command = Command::new(executable);
    command.args(arguments).current_dir(directory);
    for variable in [
        "TECS_SHADER_PACK",
        "TECS_AUDIO_LIBRARY",
        "TECS_GAMEPAD_LIBRARY",
        "TECS_PHYSICS_LIBRARY",
        "DYLD_LIBRARY_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "LD_LIBRARY_PATH",
        "NUPP_SDK",
    ] {
        command.env_remove(variable);
    }
    let output = command
        .output()
        .with_context(|| format!("running {}", executable.display()))?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    if !output.status.success() {
        anyhow::bail!(
            "{} exited with {}:\n{text}",
            executable.display(),
            output.status
        );
    }
    Ok(text)
}

/// Returns the file name the host executable is installed under.
fn executable_name(preset: Preset) -> String {
    if preset.platform() == Platform::Windows {
        format!("{EXECUTABLE}.exe")
    } else {
        EXECUTABLE.to_owned()
    }
}

/// Returns the file name Cargo writes the host executable as.
fn host_artifact(preset: Preset) -> String {
    if preset.platform() == Platform::Windows {
        format!("{HOST_PACKAGE}.exe")
    } else {
        HOST_PACKAGE.to_owned()
    }
}

/// Returns a platform's file name for a loadable library.
fn library_file(platform: Platform, stem: &str) -> String {
    match platform {
        Platform::Windows => format!("{stem}.dll"),
        Platform::Macos => format!("lib{stem}.dylib"),
        Platform::Linux => format!("lib{stem}.so"),
    }
}

/// Returns the file name of the Nupp runtime library the host links against.
///
/// The staged SDK names it in `link.json`, and that is read rather than guessed
/// because the guess is only ever checked on the platform the guesser is
/// standing on. The platform default answers when the SDK carries no manifest.
fn runtime_library(preset: Preset, sdk: &Path) -> String {
    let named = fs::read_to_string(sdk.join("link.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .and_then(|manifest| manifest["dynamic"].as_str().map(str::to_owned));
    named.unwrap_or_else(|| library_file(preset.platform(), "nupp"))
}

/// Returns the file name Cargo writes one service library as.
fn service_library(preset: Preset, stem: &str) -> String {
    library_file(preset.platform(), stem)
}

/// Copies one file and says which one when it is not there.
fn copy_file(source: &Path, destination: &Path) -> Result<()> {
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(source, destination)
        .with_context(|| format!("copying {} to {}", source.display(), destination.display()))?;
    Ok(())
}

/// Copies a directory tree, preserving the executable bit.
fn copy_tree(source: &Path, destination: &Path) -> Result<()> {
    fs::create_dir_all(destination)?;
    for entry in walkdir::WalkDir::new(source) {
        let entry = entry?;
        let relative = entry.path().strip_prefix(source)?;
        if relative.as_os_str().is_empty() {
            continue;
        }
        let target = destination.join(relative);
        if entry.file_type().is_dir() {
            fs::create_dir_all(&target)?;
        } else {
            copy_file(entry.path(), &target)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let mode = entry.metadata()?.permissions().mode();
                fs::set_permissions(&target, fs::Permissions::from_mode(mode))?;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{builtin_materials, Preset, EXECUTABLE, PRESETS, SERVICES};
    use crate::binaries::Platform;
    use std::collections::BTreeSet;
    use std::fs;
    use std::path::Path;

    fn root() -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
    }

    #[test]
    fn names_are_unique() {
        let names: BTreeSet<_> = PRESETS.iter().map(|preset| preset.name).collect();
        assert_eq!(names.len(), PRESETS.len());
    }

    #[test]
    fn every_platform_has_both_kinds() {
        for target in [
            "aarch64-apple-darwin",
            "x86_64-unknown-linux-gnu",
            "x86_64-pc-windows-msvc",
        ] {
            let kinds: BTreeSet<_> = PRESETS
                .iter()
                .filter(|preset| preset.rust_target == target)
                .map(|preset| preset.release)
                .collect();
            assert_eq!(kinds.len(), 2, "{target} is missing a preset kind");
        }
    }

    #[test]
    fn windows_puts_every_library_beside_the_executable() {
        let windows: Preset = "windows-x64".parse().unwrap();
        assert_eq!(windows.platform(), Platform::Windows);
        assert_eq!(windows.library_directory(), "bin");
        assert!(windows.run_path().is_none());
        assert_eq!(super::executable_name(windows), format!("{EXECUTABLE}.exe"));
    }

    #[test]
    fn unix_run_paths_stay_relative() {
        for name in ["macos-arm64", "linux-x64"] {
            let preset: Preset = name.parse().unwrap();
            let run_path = preset.run_path().unwrap();
            assert!(
                run_path.starts_with('@') || run_path.starts_with('$'),
                "{name} records an absolute run path: {run_path}"
            );
            assert_eq!(preset.library_directory(), "lib");
        }
    }

    #[test]
    fn unknown_preset_is_actionable() {
        let error = "wat".parse::<Preset>().unwrap_err().to_string();
        assert!(error.contains("nupp task presets"));
    }

    /// Writes a complete macOS release layout, minus whatever is named.
    ///
    /// The files hold no real content. `check_contents` asks what a package
    /// carries, and building a real one to answer that takes a linker, a Nupp
    /// compiler and several minutes.
    fn staged_prefix(scratch: &Path, omit: &[&str]) -> std::path::PathBuf {
        let prefix = scratch.join("prefix");
        let mut pack = b"TECSSP".to_vec();
        pack.extend_from_slice(&4u32.to_le_bytes());
        pack.extend_from_slice(&14u32.to_le_bytes());
        let mut files: Vec<(String, Vec<u8>)> = vec![
            ("bin/tecs-host".to_owned(), b"host".to_vec()),
            ("bin/shaders.tecspack".to_owned(), pack),
            ("bin/shaders.tecspack.txt".to_owned(), b"14".to_vec()),
            (
                "share/tecs/components/lighting.nuppc".to_owned(),
                b"component".to_vec(),
            ),
            ("lib/libnupp.dylib".to_owned(), b"runtime".to_vec()),
        ];
        for (_, stem) in SERVICES {
            files.push((format!("lib/lib{stem}.dylib"), b"service".to_vec()));
        }
        for (relative, content) in files {
            if omit.contains(&relative.as_str()) {
                continue;
            }
            let path = prefix.join(&relative);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, content).unwrap();
        }
        prefix
    }

    fn contents_problems(omit: &[&str]) -> Vec<String> {
        let scratch = tempfile::tempdir().unwrap();
        let prefix = staged_prefix(scratch.path(), omit);
        let mut problems = Vec::new();
        super::check_contents(&prefix, Platform::Macos, false, &mut problems).unwrap();
        problems
    }

    #[test]
    fn a_complete_release_layout_reports_nothing() {
        assert_eq!(contents_problems(&[]), Vec::<String>::new());
    }

    #[test]
    fn every_shipped_file_is_required_by_name() {
        for (relative, expected) in [
            ("bin/tecs-host", "runs nothing"),
            ("bin/shaders.tecspack", "compiled shaders"),
            ("bin/shaders.tecspack.txt", "compiled shaders"),
            ("share/tecs/components/lighting.nuppc", "compiled component"),
            ("lib/libnupp.dylib", "beside the executable"),
            ("lib/libtecsaudio.dylib", "beside the executable"),
            ("lib/libtecsgamepad.dylib", "beside the executable"),
            ("lib/libtecs_physics.dylib", "beside the executable"),
        ] {
            let problems = contents_problems(&[relative]);
            assert!(
                problems.iter().any(|problem| problem.contains(expected)),
                "removing {relative} was not reported: {problems:?}"
            );
        }
    }

    #[test]
    fn a_development_install_still_needs_its_libraries() {
        let scratch = tempfile::tempdir().unwrap();
        let prefix = staged_prefix(scratch.path(), &["bin/shaders.tecspack"]);
        let mut problems = Vec::new();
        super::check_contents(&prefix, Platform::Macos, true, &mut problems).unwrap();
        assert_eq!(
            problems,
            Vec::<String>::new(),
            "a development install ships no shader pack and is not asked for one"
        );
    }

    #[test]
    fn a_shipped_manifest_may_not_name_the_build_machine() {
        let scratch = tempfile::tempdir().unwrap();
        let prefix = scratch.path().join("prefix");
        fs::create_dir_all(prefix.join("share/tecs")).unwrap();
        fs::create_dir_all(prefix.join("bin")).unwrap();
        fs::write(
            prefix.join("share/tecs/cargo-licenses.txt"),
            "anyhow v1.0.104 MIT OR Apache-2.0\nold-style v1.0.0 MIT/Apache-2.0\n",
        )
        .unwrap();
        fs::write(
            prefix.join("bin/shaders.tecspack.txt"),
            "assets/materials\n14 materials: textured\n",
        )
        .unwrap();
        let mut problems = Vec::new();
        super::check_manifest_paths(&prefix, &mut problems).unwrap();
        assert_eq!(problems, Vec::<String>::new());

        fs::write(
            prefix.join("bin/shaders.tecspack.txt"),
            "/Users/somebody/tecs/assets/materials\n14 materials: textured\n",
        )
        .unwrap();
        let mut problems = Vec::new();
        super::check_manifest_paths(&prefix, &mut problems).unwrap();
        assert_eq!(problems.len(), 1, "{problems:?}");
        assert!(problems[0].contains("build-machine path"));
    }

    #[test]
    fn a_windows_path_is_absolute_too() {
        assert!(super::is_absolute_path("/home/somebody/tecs"));
        assert!(super::is_absolute_path(r"C:\Users\somebody\tecs"));
        assert!(super::is_absolute_path("C:/Users/somebody/tecs"));
        assert!(!super::is_absolute_path("assets/materials"));
        assert!(!super::is_absolute_path("MIT/Apache-2.0"));
        // `fnv` still spells its dual license `Apache-2.0 / MIT`, so the
        // separator reaches this as a token by itself.
        assert!(!super::is_absolute_path("/"));
    }

    #[test]
    fn every_service_stem_is_opened_by_some_module() {
        let mut opened = BTreeSet::new();
        for entry in walkdir::WalkDir::new(root().join("src/tecs")) {
            let entry = entry.unwrap();
            if entry.path().extension().and_then(|value| value.to_str()) != Some("nupp") {
                continue;
            }
            let text = fs::read_to_string(entry.path()).unwrap();
            for (_, stem) in SERVICES {
                if text.contains(&format!("nativelibrary.open(\"{stem}\"")) {
                    opened.insert(*stem);
                }
            }
        }
        let expected: BTreeSet<_> = SERVICES.iter().map(|(_, stem)| *stem).collect();
        assert_eq!(
            opened, expected,
            "a packaged service library is named by no module, or a module names one the package \
             does not install"
        );
    }

    #[test]
    fn cargo_inventory_records_a_license_for_every_shipped_dependency() {
        let scratch = tempfile::tempdir().unwrap();
        let prefix = scratch.path();
        for notice in super::REQUIRED_NOTICES {
            let path = prefix.join(notice);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, "notice").unwrap();
        }
        super::write_inventory(&root(), super::host_default().unwrap(), prefix).unwrap();
        let inventory =
            fs::read_to_string(prefix.join("share/tecs/cargo-dependencies.txt")).unwrap();
        assert!(!inventory.is_empty());
        assert!(
            !inventory.contains('\u{1b}'),
            "Cargo color escapes entered the inventory"
        );
        let mut problems = Vec::new();
        super::check_license_position(prefix, &mut problems).unwrap();
        super::check_manifest_paths(prefix, &mut problems).unwrap();
        assert!(problems.is_empty(), "{problems:?}");
    }

    #[test]
    fn inventory_entries_carry_no_build_machine_path() {
        assert_eq!(super::inventory_entry("anyhow v1.0.104"), "anyhow v1.0.104");
        assert_eq!(
            super::inventory_entry("serde_derive v1.0.229 (proc-macro)"),
            "serde_derive v1.0.229"
        );
        assert_eq!(
            super::inventory_entry("document-features v0.2.12 (proc-macro) (*)"),
            "document-features v0.2.12"
        );
        assert_eq!(
            super::inventory_entry(
                "tecs-audio v0.1.0 (/home/somebody/tecs/native/rust/tecs-audio)"
            ),
            "tecs-audio v0.1.0"
        );
    }

    #[test]
    fn a_shader_pack_header_is_read_the_way_the_host_reads_it() {
        let scratch = tempfile::tempdir().unwrap();
        let pack = scratch.path().join("shaders.tecspack");

        fs::write(&pack, b"TECSSP").unwrap();
        assert!(super::shader_pack_problem(&pack)
            .unwrap()
            .contains("shorter than the header"));

        let mut bytes = b"NOTPCK".to_vec();
        bytes.extend_from_slice(&4u32.to_le_bytes());
        bytes.extend_from_slice(&14u32.to_le_bytes());
        fs::write(&pack, &bytes).unwrap();
        assert!(super::shader_pack_problem(&pack).unwrap().contains("magic"));

        let mut bytes = b"TECSSP".to_vec();
        bytes.extend_from_slice(&3u32.to_le_bytes());
        bytes.extend_from_slice(&14u32.to_le_bytes());
        fs::write(&pack, &bytes).unwrap();
        assert!(super::shader_pack_problem(&pack)
            .unwrap()
            .contains("version 3"));

        let mut bytes = b"TECSSP".to_vec();
        bytes.extend_from_slice(&4u32.to_le_bytes());
        bytes.extend_from_slice(&0u32.to_le_bytes());
        fs::write(&pack, &bytes).unwrap();
        assert!(super::shader_pack_problem(&pack)
            .unwrap()
            .contains("no materials"));

        let mut bytes = b"TECSSP".to_vec();
        bytes.extend_from_slice(&4u32.to_le_bytes());
        bytes.extend_from_slice(&14u32.to_le_bytes());
        fs::write(&pack, &bytes).unwrap();
        assert!(super::shader_pack_problem(&pack).is_none());
    }

    #[test]
    fn builtin_materials_are_read_from_the_source() {
        let text = fs::read_to_string(root().join(super::MATERIAL_SOURCE)).unwrap();
        let names = builtin_materials(&text).expect("BUILTINS is readable");
        assert!(names.contains("textured"));
        assert!(names.contains("glyphalpha"));
        assert!(names.len() >= 14, "found only {} materials", names.len());
    }

    #[test]
    fn material_parity_accepts_the_shipped_set() {
        let text = fs::read_to_string(root().join(super::MATERIAL_SOURCE)).unwrap();
        let names = builtin_materials(&text).unwrap();
        let summary = format!(
            "{} materials: {}",
            names.len(),
            names.iter().copied().collect::<Vec<_>>().join(", ")
        );
        super::check_material_parity(&root(), &summary).unwrap();
    }

    #[test]
    fn material_parity_rejects_a_missing_material() {
        let error = super::check_material_parity(&root(), "1 materials: textured").unwrap_err();
        assert!(error.to_string().contains("only in the engine"));
    }
}
