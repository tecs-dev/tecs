use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use walkdir::WalkDir;

const FILES: &[&str] = &["tl.lua", "argparse.lua"];
const PACKAGES: &[&str] = &["teal", "tlcli", "cerulean"];
const DECLARATIONS: &[&str] = &[
    "bit.d.tl",
    "buffer.d.tl",
    "cjson.d.tl",
    "ffi.d.tl",
    "jit.d.tl",
    "string/buffer.d.tl",
    "table/clear.d.tl",
    "table/new.d.tl",
];
const LICENSES: &[(&str, &str)] = &[
    ("teal/LICENSE", "teal-LICENSE"),
    ("cerulean/LICENSE", "cerulean-LICENSE"),
    ("cerulean/MIT-teal.txt", "cerulean-MIT-teal.txt"),
];

pub fn tools(vendor: &Path, licenses: &Path, output: &Path) -> Result<usize> {
    if !vendor.is_dir() {
        anyhow::bail!(
            "tecs: {} is not there. Run `cargo xtask dev-tools`.",
            vendor.display()
        );
    }
    let mut staged = 0;
    for name in FILES.iter().chain(DECLARATIONS) {
        let source = vendor.join(name);
        require_file(&source)?;
        copy(&source, &output.join(name))?;
        staged += 1;
    }
    for package in PACKAGES {
        let root = vendor.join(package);
        if !root.is_dir() {
            anyhow::bail!(
                "tecs: {} is missing from the vendor tree. Run `cargo xtask dev-tools`.",
                root.display()
            );
        }
        let mut sources: Vec<PathBuf> = WalkDir::new(&root)
            .into_iter()
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .filter(|entry| {
                entry.file_type().is_file()
                    && entry.path().extension().and_then(|value| value.to_str()) == Some("lua")
            })
            .map(|entry| entry.into_path())
            .collect();
        sources.sort();
        for source in sources {
            let relative = source.strip_prefix(&root)?;
            copy(&source, &output.join(package).join(relative))?;
            staged += 1;
        }
    }
    for (relative, name) in LICENSES {
        let source = licenses.join(relative);
        if source.is_file() {
            copy(&source, &output.join("licenses").join(name))?;
            staged += 1;
        }
    }
    println!("staged {staged} files into {}", output.display());
    Ok(staged)
}

fn require_file(path: &Path) -> Result<()> {
    if path.is_file() {
        Ok(())
    } else {
        anyhow::bail!(
            "tecs: {} is missing from the vendor tree. Run `cargo xtask dev-tools`.",
            path.display()
        )
    }
}

fn copy(source: &Path, target: &Path) -> Result<()> {
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(source, target)
        .with_context(|| format!("copying {} to {}", source.display(), target.display()))?;
    Ok(())
}
