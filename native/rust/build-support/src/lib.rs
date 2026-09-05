pub mod binaries;
pub mod command;
pub mod docs;
pub mod formatting;
pub mod nupp;
pub mod package;

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

/// Finds the repository root from a path inside the checkout.
pub fn repository_root(start: &Path) -> Result<PathBuf> {
    for path in start.ancestors() {
        if path.join("Cargo.toml").is_file() && path.join("rust-toolchain.toml").is_file() {
            return Ok(path.to_path_buf());
        }
    }
    anyhow::bail!(
        "could not find the Tecs repository root from {}",
        start.display()
    )
}

/// Returns a path below the repository and describes a missing input clearly.
pub fn required(root: &Path, relative: impl AsRef<Path>) -> Result<PathBuf> {
    let path = root.join(relative);
    if path.exists() {
        Ok(path)
    } else {
        Err(anyhow::anyhow!(
            "required path {} does not exist",
            path.display()
        ))
        .with_context(|| format!("repository root is {}", root.display()))
    }
}
