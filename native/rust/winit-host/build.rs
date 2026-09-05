use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=NUPP_SDK");
    println!("cargo:rerun-if-env-changed={PACKAGED_RUN_PATH}");
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
    // The static library carries a reference to the embedding library beside
    // it, so a binary that links cleanly still aborts at startup unless the
    // loader can find that. Recording a run path is what makes the binary
    // start at all.
    //
    // Which run path depends on who is building. A checkout gets the staged
    // SDK's absolute path, which is what makes `cargo run` and `cargo test`
    // work in a tree that exports nothing. A package gets the relative path
    // its own layout puts the library at, and gets it *instead*, because an
    // absolute path into a build cache is exactly what
    // `cargo xtask nupp check-package` refuses: a release that carries one
    // runs on the machine that built it and nowhere else.
    //
    // Relinking a packaged binary afterwards would need `install_name_tool` on
    // macOS and `patchelf` on Linux, and neither is a dependency this tree
    // otherwise has, so the choice is made here where the linker is already
    // being told what to do.
    if !target_os().contains("windows") {
        let packaged = env::var_os(PACKAGED_RUN_PATH);
        match packaged.as_ref().and_then(|value| value.to_str()) {
            Some(relative) if !relative.is_empty() => {
                println!("cargo:rustc-link-arg=-Wl,-rpath,{relative}");
            }
            _ => println!("cargo:rustc-link-arg=-Wl,-rpath,{}", sdk.display()),
        }
    }

    let target = target_os();
    if !target.contains("windows") {
        println!("cargo:rustc-link-lib=m");
        println!("cargo:rustc-link-lib=pthread");
    }
    if !target.contains("windows") && !target.contains("apple") {
        println!("cargo:rustc-link-lib=dl");
    }
}

/// The target triple Cargo is building for.
fn target_os() -> String {
    env::var("TARGET").expect("Cargo sets TARGET")
}

/// The Nupp host features a Tecs component needs at load time.
///
/// A component declares the host features its payload reaches for, and the
/// runtime refuses to load one whose features the embedding library was not
/// built with. `base` alone was enough while `tecs.host` reached for neither,
/// and it stopped being enough the moment the tree gained a module that opens a
/// file or a socket: `tecs.internal.nativelibrary` searches the filesystem for
/// a native service, and `tecs.mcp` listens. The failure is a refusal to load
/// the component, not a link error, so it appears at run time in a host that
/// built cleanly.
///
/// `native/rust/build-support/src/nupp.rs` stages the same set for
/// `cargo xtask nupp run`. Keep the two lists together.
// Every Tecs component needs both beyond `base`. `native-files` is what
// `tecs.gpu.materials` reaches for, globbing a material root so the ids it
// assigns and the ids the prebuilt dispatch answers to come from one rule over
// one set of files, and `native-net` arrives with the I/O module extraction
// builds its packet through. A host staged without them refuses to load the
// component rather than failing later.
const HOST_FEATURES: &str = "base,native-files,native-net";

/// Names the run path a packaged link records instead of the staged SDK's
/// absolute one.
///
/// `native/rust/build-support/src/nupppackage.rs` sets it to the loader-relative
/// form each platform spells differently, `@executable_path/../lib` on macOS and
/// `$ORIGIN/../lib` on Linux. It is deliberately not a boolean: the packager
/// owns the layout, so the packager names the path.
const PACKAGED_RUN_PATH: &str = "TECS_PACKAGED_RUN_PATH";

/// Cargo's environment for a build script, which a nested unrelated build must
/// not inherit.
///
/// The Nupp toolchain script runs its own Cargo build of the embedding library,
/// and that project has its own minimum compiler. Leaving these set makes the
/// nested build run under this tree's `rust-toolchain.toml` pin, which is older
/// than Nupp's minimum, so the SDK fails to stage with a version error about
/// packages that are not in this workspace at all. The nested build resolves
/// its own toolchain when these are gone.
const INHERITED_CARGO_VARIABLES: [&str; 5] = [
    "RUSTUP_TOOLCHAIN",
    "RUSTC",
    "RUSTC_WRAPPER",
    "CARGO",
    "CARGO_ENCODED_RUSTFLAGS",
];

fn stage_sdk() -> PathBuf {
    let script = find_toolchain();
    let mut command = Command::new(&script);
    for variable in INHERITED_CARGO_VARIABLES {
        command.env_remove(variable);
    }
    let output = command
        .arg("host-library")
        .arg(HOST_FEATURES)
        .output()
        .unwrap_or_else(|error| panic!("cannot run {}: {error}", script.display()));
    if !output.status.success() {
        panic!(
            "{} host-library {HOST_FEATURES} failed:\n{}",
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
