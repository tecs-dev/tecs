//! Nupp compiler and embedding SDK inputs used by native packaging.
use crate::command::run;
use anyhow::Result;
use std::path::{Path, PathBuf};
use std::process::Command;
pub const OUTPUT: &str = "out/nupp";
const HOST_FEATURES: &str = "base,native-files,native-net";

pub fn compiler(root: &Path) -> Result<PathBuf> {
    if let Some(root) = std::env::var_os("NUPP_COMPILER_ROOT") {
        return Ok(PathBuf::from(root).join("bin/nupp"));
    }
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
    let script = std::env::var_os("NUPP_COMPILER_ROOT")
        .map(|root| PathBuf::from(root).join("scripts/toolchain"))
        .or_else(|| search_upward(root, "nupp/scripts/toolchain"))?;
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

pub fn build(root: &Path, target: &str) -> Result<PathBuf> {
    run(compiler(root)?, ["build", "--target", target], root)?;
    Ok(root.join(OUTPUT))
}

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
