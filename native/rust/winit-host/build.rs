use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=NUPP_SDK");
    let sdk = env::var_os("NUPP_SDK")
        .map(PathBuf::from)
        .unwrap_or_else(stage_sdk);
    assert!(
        sdk.join("libnupp.a").is_file(),
        "Nupp SDK at {} has no libnupp.a",
        sdk.display()
    );
    println!("cargo:rustc-link-search=native={}", sdk.display());
    println!("cargo:rustc-link-lib=static=nupp");

    let target = env::var("TARGET").expect("Cargo sets TARGET");
    if !target.contains("windows") {
        println!("cargo:rustc-link-lib=m");
        println!("cargo:rustc-link-lib=pthread");
    }
    if !target.contains("windows") && !target.contains("apple") {
        println!("cargo:rustc-link-lib=dl");
    }
}

fn stage_sdk() -> PathBuf {
    let script = find_toolchain();
    let output = Command::new(&script)
        .arg("host-library")
        .arg("base")
        .output()
        .unwrap_or_else(|error| panic!("cannot run {}: {error}", script.display()));
    if !output.status.success() {
        panic!(
            "{} host-library base failed:\n{}",
            script.display(),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    let stdout = String::from_utf8(output.stdout).expect("toolchain output is UTF-8");
    let path = stdout
        .lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .expect("toolchain printed no SDK path");
    PathBuf::from(path.trim())
}

/// Locates the Nupp toolchain script beside the checkout.
///
/// The path is searched upward rather than counted, because a fixed
/// `../../../../` from the manifest directory only resolves in the primary
/// checkout. A git worktree sits deeper, so the fixed hop lands inside
/// `.claude/worktrees` and the build fails there with a missing script rather
/// than an obviously wrong path. Every ancestor is tried, so both layouts and
/// any future nesting resolve the same way. Set `NUPP_SDK` to bypass this.
fn find_toolchain() -> PathBuf {
    let manifest = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("Cargo sets it"));
    let mut directory = manifest.as_path();
    while let Some(parent) = directory.parent() {
        let candidate = parent.join("nupp/scripts/toolchain");
        if candidate.is_file() {
            return candidate;
        }
        directory = parent;
    }
    panic!(
        "no nupp/scripts/toolchain above {}; set NUPP_SDK to the staged SDK directory",
        manifest.display()
    );
}
