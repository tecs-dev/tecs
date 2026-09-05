//! The Nupp half of the build: modules, game components, benchmarks, and the
//! `winit` host that loads a component.
//!
//! The Nupp compiler owns compilation. This module owns finding it, finding the
//! embedding SDK the Rust host links against, and putting the two together, so
//! a contributor reaches one command rather than three tools and two
//! environment variables.
//!
//! The `winit` host is selectable here and is not the default. The Teal
//! implementation is still the shipping path, and the migration plan defers the
//! switch until the whole platform matrix passes.

use std::collections::BTreeSet;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result};

use crate::command::run;

/// Where `nupp build` writes, as `nupp.lua` configures it.
pub const OUTPUT: &str = "out/nupp";

/// The manifest target built when none is named.
pub const DEFAULT_TARGET: &str = "headless";

/// Where the Nupp benchmark programs live.
// Benchmarks live under the `tecs` namespace because several reach
// `tecs.internal` modules, which the checker restricts to importers whose
// first namespace segment matches.
pub const BENCHMARKS: &str = "bench/nupp/tecs";

/// Where the rendered Nupp documentation site is written.
pub const DOCUMENTATION: &str = "out/nupp-docs";

/// The manifest target that renders the documentation.
const DOCUMENTATION_TARGET: &str = "docs";

/// The Nupp host features a Tecs component needs at load time.
///
/// The runtime refuses to load a component whose declared features the
/// embedding library lacks, so this must cover everything the tree reaches for:
/// `tecs.internal.nativelibrary` opens files and `tecs.mcp` listens on a
/// socket. `native/rust/winit-host/build.rs` stages the same set for an
/// ordinary `cargo build`. Keep the two lists together.
const HOST_FEATURES: &str = "base,native-files,native-net";

/// The component and entry a `winit` host run uses when the caller names none.
///
/// `tecs.host` is the reusable blank host: it opens a window and runs an empty
/// world, which is what a smoke run needs.
pub const DEFAULT_COMPONENT: &str = "host";
const DEFAULT_ENTRY: &str = "tecs.host.create";

/// Locates the Nupp compiler.
///
/// `NUPP` wins, then a compiler checkout beside this one, then a `nupp` on
/// `PATH`. The sibling beats the installed release because the compiler and
/// this tree move together during the migration, and the tree is developed
/// against a compiler newer than the published one.
///
/// The sibling is searched upward rather than counted, for the reason
/// `native/rust/winit-host/build.rs` gives: a git worktree sits deeper than the
/// primary checkout, so a fixed number of hops resolves in one layout and not
/// the other.
pub fn compiler(root: &Path) -> Result<PathBuf> {
    if let Some(configured) = std::env::var_os("NUPP") {
        let path = PathBuf::from(configured);
        if !path.is_file() {
            anyhow::bail!("NUPP names {}, which is not a file", path.display());
        }
        return Ok(path);
    }
    if let Some(sibling) = search_upward(root, "nupp/bin/nupp") {
        return Ok(sibling);
    }
    // Left last so a checkout being worked on wins over an installed release,
    // which is the common case while the compiler and this tree move together.
    if which("nupp") {
        return Ok(PathBuf::from("nupp"));
    }
    anyhow::bail!(
        "no Nupp compiler found; install one, put it on PATH, set NUPP to it, \
         or check the compiler out beside {}",
        root.display()
    )
}

/// Locates the Nupp embedding SDK the Rust host links `libnupp.a` from.
///
/// Returns `None` rather than failing when nothing can stage one. The caller
/// decides whether that is fatal: building a Nupp module needs no SDK, and only
/// the host does.
pub fn sdk(root: &Path) -> Option<PathBuf> {
    if let Some(configured) = std::env::var_os("NUPP_SDK") {
        return Some(PathBuf::from(configured));
    }
    let script = search_upward(root, "nupp/scripts/toolchain")?;
    let mut command = Command::new(&script);
    // The Nupp toolchain builds its embedding library with its own Cargo, and
    // that project's minimum compiler is newer than this tree's
    // `rust-toolchain.toml` pin. Inheriting the pin makes the nested build fail
    // on a version it never asked for. `native/rust/winit-host/build.rs` clears
    // the same variables for the same reason.
    for variable in ["RUSTUP_TOOLCHAIN", "RUSTC", "RUSTC_WRAPPER", "CARGO"] {
        command.env_remove(variable);
    }
    let output = command
        .args(["host-library", HOST_FEATURES])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?;
    let line = text.lines().rev().find(|line| !line.trim().is_empty())?;
    let path = PathBuf::from(line.trim());
    path.join("libnupp.a").is_file().then_some(path)
}

/// Runs the Nupp compiler with the repository as its working directory.
fn nupp<I, S>(root: &Path, arguments: I) -> Result<()>
where
    I: IntoIterator<Item = S>,
    S: AsRef<std::ffi::OsStr>,
{
    run(compiler(root)?, arguments, root)
}

/// Type-checks every Nupp source under the manifest's include roots.
pub fn check(root: &Path) -> Result<()> {
    nupp(root, ["check", "--strict"])
}

/// Formats every Nupp source in place, or reports the unformatted ones.
pub fn format(root: &Path, verify: bool) -> Result<()> {
    nupp(root, ["fmt", if verify { "--check" } else { "--write" }])
}

/// Builds and runs the Nupp test suites.
pub fn test(root: &Path) -> Result<()> {
    nupp(root, ["test"])
}

/// Builds one configured manifest target.
pub fn build(root: &Path, target: &str) -> Result<PathBuf> {
    nupp(root, ["build", "--target", target])?;
    Ok(root.join(OUTPUT))
}

/// Lists the manifest's configured targets and tasks.
pub fn targets(root: &Path) -> Result<()> {
    nupp(root, ["tasks"])
}

/// Renders the Nupp documentation site.
///
/// The Nupp compiler reads the docblocks it already checks, so the reference
/// has no second copy of a signature to drift from. Tealdoc cannot do this
/// half: it resolves a module only through `src/<name>.tl`, so it can neither
/// read a Nupp declaration nor project one onto a page. The two sites collapse
/// into one when the Teal implementation is deleted.
pub fn documentation(root: &Path, output: Option<&Path>) -> Result<PathBuf> {
    let destination = output.map_or_else(|| root.join(DOCUMENTATION), Path::to_path_buf);
    nupp(
        root,
        [
            std::ffi::OsStr::new("build"),
            std::ffi::OsStr::new("--target"),
            std::ffi::OsStr::new(DOCUMENTATION_TARGET),
            std::ffi::OsStr::new("--out-dir"),
            destination.as_os_str(),
        ],
    )?;
    Ok(destination)
}

/// Renders the Nupp documentation into a scratch directory and gates it.
///
/// The render is the gate for the reference: a docblock the generator cannot
/// read fails here. `scripts/check-docs-descriptions.sh` is the gate for the
/// pages, and it is the same script `cargo xtask docs-check` runs, over the
/// same `docs/` tree, so a Nupp page is held to what a Teal page is held to.
pub fn documentation_check(root: &Path) -> Result<()> {
    crate::docs::check_descriptions(root)?;
    let scratch = tempfile::Builder::new()
        .prefix("tecs-nupp-docs.")
        .tempdir()?;
    documentation(root, Some(&scratch.path().join("site")))?;
    println!("OK: the Nupp reference renders and every page carries a description");
    Ok(())
}

/// Runs one Nupp benchmark program.
///
/// Benchmarks are compiled at `-O2` rather than the ad-hoc default of `-O0`,
/// because a measurement taken at a different optimization level than the one
/// that ships answers a question nobody asked.
pub fn benchmark(root: &Path, name: &str, arguments: &[OsString]) -> Result<()> {
    let source = benchmark_source(root, name)?;
    let mut command = Command::new(compiler(root)?);
    command
        .arg("run")
        .arg("-O2")
        .arg(&source)
        .args(arguments)
        .current_dir(root);
    let status = command
        .status()
        .with_context(|| format!("failed to start the {name} benchmark"))?;
    if !status.success() {
        anyhow::bail!("the {name} benchmark exited with {status}");
    }
    Ok(())
}

/// Resolves a benchmark name to its program, and lists the alternatives when
/// the name is unknown.
fn benchmark_source(root: &Path, name: &str) -> Result<PathBuf> {
    let directory = root.join(BENCHMARKS);
    let source = directory.join(format!("{name}.nupp"));
    if source.is_file() {
        return Ok(source);
    }
    let mut available = BTreeSet::new();
    for entry in std::fs::read_dir(&directory)
        .with_context(|| format!("read {}", directory.display()))?
        .flatten()
    {
        let path = entry.path();
        if path
            .extension()
            .is_some_and(|extension| extension == "nupp")
        {
            if let Some(stem) = path.file_stem().and_then(|stem| stem.to_str()) {
                available.insert(stem.to_owned());
            }
        }
    }
    let listed = available.into_iter().collect::<Vec<_>>().join(", ");
    // `bitset` and `latency` are the two Teal benchmark names with no Nupp
    // program, and both are named by the migration plan's performance gates, so
    // a reader who types one deserves the answer rather than a name list.
    let note = match name {
        "bitset" => {
            "\nThe Nupp ECS has no bitset. `signature` measures the archetype \
             signature and query matching that occupy its place."
        }
        "latency" => {
            "\nEvent-to-photon latency is not ported: nothing in Nupp pushes an \
             event into the host queue, and no stage is marked inside a host turn."
        }
        _ => "",
    };
    anyhow::bail!("unknown Nupp benchmark {name:?}; expected {listed}{note}")
}

/// Builds a component target and runs it through the Rust `winit` host.
///
/// The host is a development executable, not the default one. It is built with
/// Cargo in the debug profile, since what it is for right now is seeing a
/// change work.
pub fn host(root: &Path, target: &str, entry: Option<&str>, arguments: &[OsString]) -> Result<()> {
    build(root, target)?;
    let component = root.join(OUTPUT).join(format!("{target}.nuppc"));
    if !component.is_file() {
        anyhow::bail!(
            "target {target:?} produced no component at {}; \
             only a `kind = \"component\"` target in nupp.lua can be run by the host",
            component.display()
        );
    }
    let entry = entry
        .map(str::to_owned)
        .unwrap_or_else(|| default_entry(target));
    let mut command = Command::new("cargo");
    command
        .args(["run", "-p", "tecs-winit-host", "--"])
        .arg("--component")
        .arg(&component)
        .arg("--entry")
        .arg(&entry)
        .args(arguments)
        .current_dir(root);
    apply_sdk(&mut command, root);
    let status = command
        .status()
        .context("failed to start the Tecs winit host through Cargo")?;
    if !status.success() {
        anyhow::bail!("the {target} host run exited with {status}");
    }
    Ok(())
}

/// Names the session constructor a component target exports.
///
/// The blank host exports `tecs.host.create`; every game component exports
/// `<name>.create`, which is the convention `examples/nupp` follows and the
/// Rust `--entry` option selects.
fn default_entry(target: &str) -> String {
    if target == DEFAULT_COMPONENT {
        DEFAULT_ENTRY.to_owned()
    } else {
        format!("{target}.create")
    }
}

/// Puts the Nupp SDK on a Cargo child's environment.
///
/// `NUPP_SDK` is what `native/rust/winit-host/build.rs` links against, and
/// setting it here skips the staging call that build script would otherwise
/// make. Nothing is added to the loader path: that build script records the SDK
/// as a run path, so a host binary finds the embedding library on its own.
pub fn apply_sdk(command: &mut Command, root: &Path) {
    if let Some(sdk) = sdk(root) {
        command.env("NUPP_SDK", sdk);
    }
}

/// Checks, formats, tests, and builds the Rust host against a Nupp component.
///
/// This is the Nupp counterpart of `cargo xtask test`, and it is separate
/// because the two implementations are still parallel: neither suite proves
/// anything about the other.
pub fn verify(root: &Path) -> Result<()> {
    check(root)?;
    format(root, true)?;
    test(root)?;
    for target in [DEFAULT_TARGET, DEFAULT_COMPONENT] {
        build(root, target)?;
    }
    if sdk(root).is_none() {
        println!(
            "skipping the Rust host: no Nupp embedding SDK. Set NUPP_SDK, or \
             check the Nupp compiler out beside this tree so its toolchain can \
             stage one."
        );
        return Ok(());
    }
    for arguments in [
        vec!["fmt", "-p", "tecs-winit-host", "--", "--check"],
        vec![
            "clippy",
            "-p",
            "tecs-winit-host",
            "--all-targets",
            "--",
            "-D",
            "warnings",
        ],
        vec!["test", "-p", "tecs-winit-host"],
    ] {
        let mut command = Command::new("cargo");
        command.args(&arguments).current_dir(root);
        apply_sdk(&mut command, root);
        let status = command
            .status()
            .context("failed to start Cargo for the Tecs winit host")?;
        if !status.success() {
            anyhow::bail!("cargo {} exited with {status}", arguments[0]);
        }
    }
    Ok(())
}

/// Searches this checkout and every ancestor for a relative path.
fn search_upward(root: &Path, relative: &str) -> Option<PathBuf> {
    let mut directory = Some(root);
    while let Some(current) = directory {
        let candidate = current.join(relative);
        if candidate.is_file() {
            return Some(candidate);
        }
        directory = current.parent();
    }
    None
}

/// Reports whether a program resolves on `PATH`.
fn which(program: &str) -> bool {
    let Some(paths) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&paths).any(|directory| directory.join(program).is_file())
}
