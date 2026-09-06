//! The build: Nupp modules, game components, benchmarks, and the `winit` host
//! that loads a component.
//!
//! The Nupp compiler owns compilation. This module owns finding it, finding the
//! embedding SDK the Rust host links against, and putting the two together, so
//! a contributor reaches one command rather than three tools and two
//! environment variables.

use std::collections::BTreeSet;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

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
pub const DOCUMENTATION: &str = "out/docs";

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
    // process-specific compiler overrides must not leak into that build.
    // Keep this tree's Rust pin aligned with the SDK's pinned compiler, since
    // libnupp.a carries Rust's standard library. `native/rust/winit-host/build.rs`
    // clears the same variables for the same reason.
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

/// Builds all native services and requires every discovered Nupp test to pass.
///
/// The raw report is retained at `out/validation/nupp-tests.json`. Direct
/// `nupp test` remains useful for focused development with optional bindings;
/// this integration gate refuses skips and missing suite discovery.
pub fn test(root: &Path) -> Result<()> {
    let libraries = native_libraries(root, false)?;
    let expected = std::fs::read_dir(root.join("tests"))?
        .map(|entry| entry.map(|entry| entry.file_name().to_string_lossy().into_owned()))
        .collect::<std::io::Result<Vec<_>>>()?
        .into_iter()
        .filter_map(|name| name.strip_suffix(".nupp").map(str::to_owned))
        .filter(|name| name.ends_with("test"))
        .collect::<BTreeSet<_>>();
    let output = Command::new(compiler(root)?)
        .args(["test", "--json"])
        .envs(libraries)
        .current_dir(root)
        .stderr(Stdio::inherit())
        .output()
        .context("running the mandatory Nupp integration tests")?;
    let directory = root.join("out/validation");
    std::fs::create_dir_all(&directory)?;
    let report = directory.join("nupp-tests.json");
    std::fs::write(&report, &output.stdout)?;
    let result = validate_test_report(&output.stdout, &expected);
    if !output.status.success() {
        anyhow::bail!(
            "Nupp tests exited with {}; report: {}",
            output.status,
            report.display()
        );
    }
    result.with_context(|| format!("mandatory test gate; report: {}", report.display()))?;
    Ok(())
}

/// Uses Cargo's artifact paths so an alternate target directory cannot make
/// the tests accidentally load a library left over in the checkout.
fn native_libraries(root: &Path, release: bool) -> Result<Vec<(&'static str, PathBuf)>> {
    let mut build = Command::new("cargo");
    build
        .args([
            "build",
            "--locked",
            "-p",
            "tecs-audio",
            "-p",
            "tecs-gamepad",
            "-p",
            "tecs-physics",
            "--message-format=json-render-diagnostics",
        ])
        .current_dir(root)
        .stderr(Stdio::inherit());
    if release {
        build.arg("--release");
    }
    let output = build
        .output()
        .context("building native integration libraries")?;
    if !output.status.success() {
        anyhow::bail!("native service build exited with {}", output.status);
    }
    let artifacts = String::from_utf8(output.stdout)?
        .lines()
        .map(serde_json::from_str::<serde_json::Value>)
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let mut libraries = Vec::new();
    for (name, variable) in [
        ("tecsaudio", "TECS_AUDIO_LIBRARY"),
        ("tecsgamepad", "TECS_GAMEPAD_LIBRARY"),
        ("tecs_physics", "TECS_PHYSICS_LIBRARY"),
    ] {
        let path = artifacts
            .iter()
            .filter(|value| {
                value["reason"] == "compiler-artifact" && value["target"]["name"] == name
            })
            .filter_map(|value| value["filenames"].as_array())
            .flatten()
            .filter_map(serde_json::Value::as_str)
            .map(PathBuf::from)
            .find(|path| {
                path.extension()
                    .is_some_and(|ext| ext == std::env::consts::DLL_EXTENSION)
            })
            .with_context(|| format!("Cargo produced no native library for {name}"))?;
        libraries.push((variable, path));
    }
    Ok(libraries)
}

fn validate_test_report(bytes: &[u8], expected: &BTreeSet<String>) -> Result<()> {
    let report: serde_json::Value =
        serde_json::from_slice(bytes).context("test report is not JSON")?;
    let tests = report["tests"]
        .as_array()
        .context("test report has no cases")?;
    let mut discovered = BTreeSet::new();
    let mut cases = BTreeSet::new();
    for case in tests {
        let suite = case["suite"].as_str().context("test case has no suite")?;
        let name = case["name"].as_str().context("test case has no name")?;
        discovered.insert(suite.to_owned());
        anyhow::ensure!(
            cases.insert((suite, name)),
            "duplicate test case {suite}.{name}"
        );
        anyhow::ensure!(case["status"] == "passed", "test did not pass: {case}");
    }
    anyhow::ensure!(
        !expected.is_empty() && !tests.is_empty(),
        "no tests were discovered"
    );
    anyhow::ensure!(
        &discovered == expected,
        "suite discovery mismatch: missing {:?}; unexpected {:?}",
        expected.difference(&discovered).collect::<Vec<_>>(),
        discovered.difference(expected).collect::<Vec<_>>()
    );
    anyhow::ensure!(
        report["ok"] == true
            && report["total"].as_u64() == Some(tests.len() as u64)
            && report["passed"].as_u64() == Some(tests.len() as u64)
            && report["failed"] == 0
            && report["skipped"] == 0,
        "test summary does not report every discovered case as passed"
    );
    println!(
        "{} tests passed in {} suites; zero skipped",
        tests.len(),
        discovered.len()
    );
    Ok(())
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

/// Renders the documentation site.
///
/// The Nupp compiler reads the docblocks it already checks, so the reference
/// has no second copy of a signature to drift from.
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

/// Runs one benchmark program.
///
/// Benchmarks are compiled at `-O2` rather than the ad-hoc default of `-O0`,
/// because a measurement taken at a different optimization level than the one
/// that ships answers a question nobody asked.
pub fn benchmark(root: &Path, name: &str, arguments: &[OsString]) -> Result<()> {
    if name == "acceptance" {
        anyhow::ensure!(
            arguments.is_empty(),
            "acceptance takes no benchmark overrides"
        );
        return benchmark_acceptance(root);
    }
    let source = benchmark_source(root, name)?;
    let libraries = if name == "physics" {
        native_libraries(root, true)?
    } else {
        Vec::new()
    };
    for (variable, path) in &libraries {
        eprintln!("benchmark release library: {variable}={}", path.display());
    }
    let mut command = Command::new(compiler(root)?);
    command
        .arg("run")
        .arg("-O2")
        .arg(&source)
        .envs(libraries)
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

/// Runs fixed CPU workloads three times, outside the ordinary CI gate. Each
/// run must meet every p95 budget; no pooling can hide a bad repetition.
pub fn benchmark_acceptance(root: &Path) -> Result<()> {
    let libraries = native_libraries(root, true)?;
    let compiler = compiler(root)?;
    let directory = root.join("out/validation/performance");
    std::fs::create_dir_all(&directory)?;
    let workloads = [
        (
            "shapes-4000",
            "shapes",
            "BENCH_SHAPES",
            "2000",
            "120",
            vec![("update", 1.0), ("extract", 3.0), ("frame", 4.0)],
        ),
        (
            "physics-1000",
            "physics",
            "BENCH_BODIES",
            "1000",
            "600",
            vec![
                ("commands+ecs", 2.0),
                ("native batch", 3.0),
                ("sync", 0.5),
                ("update", 5.0),
            ],
        ),
        (
            "physics-4000-stress",
            "physics",
            "BENCH_BODIES",
            "4000",
            "600",
            vec![
                ("commands+ecs", 8.0),
                ("native batch", 20.0),
                ("sync", 1.0),
                ("update", 25.0),
            ],
        ),
    ];
    let mut results = Vec::new();
    let mut failures = Vec::new();
    for (label, name, variable, count, warmup, budgets) in workloads {
        for repetition in 1..=3 {
            let mut command = Command::new(&compiler);
            // A developer's shell must not silently change the accepted fixture.
            for (key, _) in std::env::vars_os() {
                if key.to_string_lossy().starts_with("BENCH_") {
                    command.env_remove(key);
                }
            }
            command
                .args(["run", "-O2"])
                .arg(benchmark_source(root, name)?)
                .envs(libraries.iter().map(|(key, value)| (*key, value)))
                .env(variable, count)
                .env("BENCH_JSON", "1")
                .env("BENCH_WARMUP", warmup)
                .env("BENCH_FRAMES", "900")
                .env("BENCH_AREA_W", "1280")
                .env("BENCH_AREA_H", "720")
                .env("BENCH_MODE", "frame")
                .env("BENCH_WORKERS", "0")
                .current_dir(root);
            let output = command.output().context("running performance acceptance")?;
            let stem = format!("{label}-{repetition}");
            std::fs::write(directory.join(format!("{stem}.stdout")), &output.stdout)?;
            std::fs::write(directory.join(format!("{stem}.stderr")), &output.stderr)?;
            anyhow::ensure!(
                output.status.success(),
                "{stem} failed; see {}",
                directory.display()
            );
            let stdout = String::from_utf8(output.stdout)?;
            let report: serde_json::Value = serde_json::from_str(
                stdout
                    .lines()
                    .find_map(|line| line.strip_prefix("TECS_BENCH_JSON "))
                    .context("benchmark did not emit its structured report")?,
            )?;
            if name == "physics" {
                anyhow::ensure!(
                    report["metadata"]["bodies"].as_u64() == Some(count.parse()?),
                    "{stem} did not spawn every body"
                );
                anyhow::ensure!(
                    report["metadata"]["effectiveWorkers"] == 1,
                    "{stem} must use one actual solver worker"
                );
                anyhow::ensure!(
                    report["metadata"]["substeps"] == 4,
                    "{stem} must use four substeps"
                );
            } else {
                anyhow::ensure!(
                    report["metadata"]["instances"] == 4000,
                    "{stem} must extract every instance"
                );
            }
            let violations = check_performance_budgets(&report, &budgets)?;
            println!(
                "{stem}: {}",
                if violations.is_empty() {
                    "PASS"
                } else {
                    "FAIL"
                }
            );
            for violation in &violations {
                eprintln!("  {violation}");
                failures.push(format!("{stem}: {violation}"));
            }
            results.push(
                serde_json::json!({"workload": label, "repetition": repetition,
                "p95BudgetsMs": budgets, "violations": violations, "report": report}),
            );
        }
    }
    let revision = Command::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(root)
        .output()?;
    let dirty = Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(root)
        .output()?;
    let version = Command::new(&compiler)
        .arg("--version")
        .current_dir(root)
        .output()?;
    let report = serde_json::json!({"schemaVersion": 1, "os": std::env::consts::OS,
        "architecture": std::env::consts::ARCH, "revision": String::from_utf8_lossy(&revision.stdout).trim(),
        "dirty": !dirty.stdout.is_empty(), "compiler": compiler,
        "compilerVersion": String::from_utf8_lossy(&version.stdout).trim(),
        "nativeLibraries": libraries, "nativeProfile": "release", "optimization": "O2",
        "frames": 900, "requestedWorkers": 0, "effectiveWorkers": 1, "results": results, "passed": failures.is_empty()});
    std::fs::write(
        directory.join("acceptance.json"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    anyhow::ensure!(
        failures.is_empty(),
        "performance budgets exceeded; see {}",
        directory.display()
    );
    Ok(())
}

fn check_performance_budgets(
    report: &serde_json::Value,
    budgets: &[(&str, f64)],
) -> Result<Vec<String>> {
    let stages = report["stages"]
        .as_array()
        .context("missing performance stages")?;
    let mut violations = Vec::new();
    for (name, limit) in budgets {
        let matching = stages
            .iter()
            .filter(|stage| stage["name"] == *name)
            .collect::<Vec<_>>();
        anyhow::ensure!(matching.len() == 1, "expected exactly one {name} stage");
        let stage = matching[0];
        anyhow::ensure!(
            stage["samples"].as_u64() == Some(900),
            "{name} must contain 900 samples"
        );
        let p95 = stage["p95"].as_f64().context("missing numeric p95")?;
        anyhow::ensure!(p95.is_finite() && p95 >= 0.0, "invalid {name} p95");
        if p95 > *limit {
            violations.push(format!("{name} p95 {p95:.3} ms exceeds {limit:.3} ms"));
        }
    }
    Ok(violations)
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
    // `bitset` and `latency` are named by the migration plan's performance
    // gates and have no program here, so a reader who types one deserves the
    // answer rather than a name list.
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
    anyhow::bail!("unknown benchmark {name:?}; expected {listed}{note}")
}

/// Builds a component target and runs it through the Rust `winit` host.
///
/// It is built with Cargo in the debug profile, since what a run is for is
/// seeing a change work.
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

/// Runs strict checking, formatting, mandatory integration tests, documentation,
/// workspace Rust checks, and five headless component smokes.
///
/// An embedding SDK is required. Performance measurements and relocated
/// release-package validation are separate commands with separate budgets.
pub fn verify(root: &Path) -> Result<()> {
    let sdk = sdk(root).filter(|path| path.join("libnupp.a").is_file()).context(
        "verify requires a Nupp embedding SDK; set NUPP_SDK or stage one from a sibling Nupp checkout"
    )?;
    check(root)?;
    crate::formatting::apply(root, &[], true)?;
    test(root)?;
    crate::docs::check(root)?;
    build(root, DEFAULT_TARGET)?;
    for arguments in [
        vec!["fmt", "--all", "--", "--check"],
        vec![
            "clippy",
            "--locked",
            "--workspace",
            "--all-targets",
            "--",
            "-D",
            "warnings",
        ],
        vec!["test", "--locked", "--workspace", "--all-targets"],
    ] {
        let status = Command::new("cargo")
            .args(&arguments)
            .env("NUPP_SDK", &sdk)
            .current_dir(root)
            .status()
            .context("running workspace Rust validation")?;
        if !status.success() {
            anyhow::bail!("cargo {} exited with {status}", arguments[0]);
        }
    }
    let libraries = native_libraries(root, false)?;
    for target in [
        DEFAULT_COMPONENT,
        "flatcolor",
        "sprites",
        "lighting",
        "nativesmoke",
    ] {
        build(root, target)?;
        let status = Command::new("cargo")
            .args([
                "run",
                "--locked",
                "-p",
                "tecs-winit-host",
                "--",
                "--component",
            ])
            .arg(root.join(OUTPUT).join(format!("{target}.nuppc")))
            .args([
                "--entry",
                &default_entry(target),
                "--headless",
                "--frames",
                "5",
            ])
            .env("NUPP_SDK", &sdk)
            .envs(libraries.iter().map(|(name, path)| (*name, path)))
            .current_dir(root)
            .status()
            .with_context(|| format!("running the {target} component smoke"))?;
        anyhow::ensure!(
            status.success(),
            "the {target} component smoke exited with {status}"
        );
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn performance_gate_requires_complete_samples_and_checks_the_tail() {
        let good = json!({"stages": [{"name": "extract", "samples": 900, "p95": 3.0}]});
        assert!(check_performance_budgets(&good, &[("extract", 3.0)])
            .unwrap()
            .is_empty());
        assert_eq!(
            check_performance_budgets(&good, &[("extract", 2.9)])
                .unwrap()
                .len(),
            1
        );
        assert!(check_performance_budgets(&good, &[("update", 3.0)]).is_err());
        let short = json!({"stages": [{"name": "extract", "samples": 899, "p95": 1.0}]});
        assert!(check_performance_budgets(&short, &[("extract", 3.0)]).is_err());
        let duplicate = json!({"stages": [good["stages"][0], good["stages"][0]]});
        assert!(check_performance_budgets(&duplicate, &[("extract", 3.0)]).is_err());
    }

    fn report() -> serde_json::Value {
        json!({"ok": true, "total": 1, "passed": 1, "failed": 0, "skipped": 0,
            "tests": [{"suite": "audionativetest", "name": "opensOffline", "status": "passed"}]})
    }

    fn validate(report: serde_json::Value, suites: &[&str]) -> Result<()> {
        validate_test_report(
            &serde_json::to_vec(&report)?,
            &suites.iter().map(|suite| (*suite).to_owned()).collect(),
        )
    }

    #[test]
    fn requires_discovery_and_consistent_pass_counts() {
        assert!(validate(report(), &["audionativetest"]).is_ok());
        assert!(validate(report(), &["audionativetest", "gamepadnativetest"]).is_err());
        let mut wrong_total = report();
        wrong_total["total"] = json!(2);
        assert!(validate(wrong_total, &["audionativetest"]).is_err());
        let mut empty = report();
        empty["tests"] = json!([]);
        assert!(validate(empty, &[]).is_err());
    }

    #[test]
    fn refuses_skips_even_when_the_runner_reports_success() {
        let mut skipped = report();
        skipped["tests"][0]["status"] = json!("skipped");
        skipped["tests"][0]["skip"] = json!({"reason": "native opener refused"});
        skipped["passed"] = json!(0);
        skipped["skipped"] = json!(1);
        assert!(validate(skipped, &["audionativetest"]).is_err());
    }

    #[test]
    fn refuses_duplicate_cases_and_invalid_reports() {
        let mut duplicate = report();
        duplicate["tests"] = json!([duplicate["tests"][0], duplicate["tests"][0]]);
        duplicate["passed"] = json!(2);
        duplicate["total"] = json!(2);
        assert!(validate(duplicate, &["audionativetest"]).is_err());
        assert!(validate_test_report(b"not JSON", &BTreeSet::new()).is_err());
    }
}
