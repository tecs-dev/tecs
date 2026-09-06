//! Version-specific source provenance for the MPL crates a package carries.
//!
//! Only verified, unmodified crates.io sources may use an upstream URL alone.
//! A patch must first gain a packaged-source contract; it cannot silently inherit
//! the upstream archive's provenance.
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::Read;
use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

const REGISTRY: &str = "registry+https://github.com/rust-lang/crates.io-index";
const MANIFEST: &str = "share/tecs/license-sources.json";

pub fn write(root: &Path, prefix: &Path, shipped: &BTreeSet<String>) -> Result<()> {
    let output = Command::new("cargo")
        .args(["metadata", "--locked", "--format-version", "1"])
        .current_dir(root)
        .output()?;
    anyhow::ensure!(
        output.status.success(),
        "cannot resolve source provenance: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let metadata: Value = serde_json::from_slice(&output.stdout)?;
    let lock: toml::Value = toml::from_str(&fs::read_to_string(root.join("Cargo.lock"))?)?;
    let locked = lock["package"]
        .as_array()
        .context("lockfile has no packages")?;
    let mut sources = BTreeMap::new();
    for package in metadata["packages"]
        .as_array()
        .context("metadata has no packages")?
    {
        let name = package["name"].as_str().context("package has no name")?;
        let version = package["version"]
            .as_str()
            .context("package has no version")?;
        let license = package["license"].as_str().unwrap_or_default();
        if !shipped.contains(&format!("{name} v{version}")) || !license.contains("MPL-2.0") {
            continue;
        }
        anyhow::ensure!(package["source"].as_str() == Some(REGISTRY),
            "{name} {version}: patched, vendored or non-crates.io MPL sources need packaged source and modification records");
        let entry = locked
            .iter()
            .find(|entry| {
                entry["name"].as_str() == Some(name)
                    && entry["version"].as_str() == Some(version)
                    && entry.get("source").and_then(toml::Value::as_str) == Some(REGISTRY)
            })
            .context("covered crate is absent from the locked registry graph")?;
        let checksum = entry
            .get("checksum")
            .and_then(toml::Value::as_str)
            .context("covered crate has no locked source checksum")?;
        let manifest = Path::new(
            package["manifest_path"]
                .as_str()
                .context("package has no manifest")?,
        );
        let source = manifest.parent().context("manifest has no parent")?;
        let registry = source.parent().context("source has no registry")?;
        let registry_root = registry
            .parent()
            .and_then(Path::parent)
            .context("source is not in a Cargo registry")?;
        let archive = registry_root
            .join("cache")
            .join(registry.file_name().context("registry has no name")?)
            .join(format!("{name}-{version}.crate"));
        let bytes = fs::read(&archive)
            .with_context(|| format!("cannot verify the source archive for {name} {version}"))?;
        anyhow::ensure!(
            format!("{:x}", Sha256::digest(&bytes)) == checksum,
            "{name} {version}: source archive differs from Cargo.lock"
        );
        verify_source(source, &bytes).with_context(|| {
            format!("{name} {version}: modified MPL source needs a packaged-source record")
        })?;
        sources.insert(
            format!("{name} {version}"),
            json!({
                "name": name, "version": version, "license": license,
                "source": format!("https://crates.io/api/v1/crates/{name}/{version}/download"),
                "sha256": checksum, "modifications": [], "verifiedUnmodified": true
            }),
        );
    }
    fs::write(
        prefix.join(MANIFEST),
        serde_json::to_string_pretty(&json!({
            "version": 1, "packages": sources.into_values().collect::<Vec<_>>()
        }))? + "\n",
    )?;
    Ok(())
}

fn verify_source(source: &Path, bytes: &[u8]) -> Result<()> {
    let mut archive = tar::Archive::new(flate2::read::GzDecoder::new(bytes));
    let mut expected = BTreeSet::new();
    for entry in archive.entries()? {
        let mut entry = entry?;
        if entry.header().entry_type().is_dir() {
            continue;
        }
        anyhow::ensure!(
            entry.header().entry_type().is_file(),
            "source archive contains a non-file"
        );
        let path = entry.path()?.into_owned();
        let relative: std::path::PathBuf = path.components().skip(1).collect();
        anyhow::ensure!(
            !relative.as_os_str().is_empty()
                && relative
                    .components()
                    .all(|part| matches!(part, std::path::Component::Normal(_))),
            "invalid archive path"
        );
        let mut original = Vec::new();
        entry.read_to_end(&mut original)?;
        let actual = source.join(&relative);
        anyhow::ensure!(
            !fs::symlink_metadata(&actual)?.file_type().is_symlink(),
            "source is a symlink: {}",
            relative.display()
        );
        anyhow::ensure!(
            fs::read(&actual)? == original,
            "source differs: {}",
            relative.display()
        );
        expected.insert(relative);
    }
    anyhow::ensure!(!expected.is_empty(), "empty source archive");
    for entry in walkdir::WalkDir::new(source) {
        let entry = entry?;
        if entry.file_type().is_dir() {
            continue;
        }
        let relative = entry.path().strip_prefix(source)?;
        // Cargo writes this extraction receipt itself; it is not crate source.
        if relative == Path::new(".cargo-ok") {
            continue;
        }
        anyhow::ensure!(
            expected.contains(relative),
            "extra source file: {}",
            relative.display()
        );
    }
    Ok(())
}

pub fn check(prefix: &Path, problems: &mut Vec<String>) -> Result<()> {
    let path = prefix.join(MANIFEST);
    let Ok(text) = fs::read_to_string(&path) else {
        return Ok(());
    };
    let source: Value = match serde_json::from_str(&text) {
        Ok(value) => value,
        Err(error) => {
            problems.push(format!("invalid license-sources.json: {error}"));
            return Ok(());
        }
    };
    let Some(packages) = source["packages"]
        .as_array()
        .filter(|_| source["version"] == 1)
    else {
        problems.push("invalid license-sources.json version or packages".into());
        return Ok(());
    };
    let licenses = fs::read_to_string(prefix.join("share/tecs/cargo-licenses.txt"))?;
    let expected: BTreeSet<_> = licenses
        .lines()
        .filter(|line| line.contains("MPL-2.0"))
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            Some((
                fields.next()?.to_owned(),
                fields.next()?.trim_start_matches('v').to_owned(),
            ))
        })
        .collect();
    let mut seen = BTreeSet::new();
    for package in packages {
        let name = package["name"].as_str().unwrap_or_default();
        let version = package["version"].as_str().unwrap_or_default();
        let key = (name.to_owned(), version.to_owned());
        let checksum = package["sha256"].as_str().unwrap_or_default();
        let valid = expected.contains(&key)
            && seen.insert(key)
            && package["source"]
                == format!("https://crates.io/api/v1/crates/{name}/{version}/download")
            && package["license"]
                .as_str()
                .is_some_and(|value| value.contains("MPL-2.0"))
            && checksum.len() == 64
            && checksum.bytes().all(|byte| byte.is_ascii_hexdigit())
            && package["verifiedUnmodified"] == true
            && package["modifications"]
                .as_array()
                .is_some_and(Vec::is_empty);
        if !valid {
            problems.push(format!(
                "invalid or duplicate MPL source record for {name} {version}"
            ));
        }
    }
    for (name, version) in expected.difference(&seen) {
        problems.push(format!(
            "no version-specific MPL source record for {name} {version}"
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn source_verification_refuses_edits_and_extra_files() {
        let scratch = tempfile::tempdir().unwrap();
        fs::write(scratch.path().join("lib.rs"), "original").unwrap();
        let gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        let mut archive = tar::Builder::new(gzip);
        let mut header = tar::Header::new_gnu();
        header.set_size(8);
        header.set_mode(0o644);
        header.set_cksum();
        archive
            .append_data(&mut header, "crate-1.0.0/lib.rs", b"original".as_slice())
            .unwrap();
        let bytes = archive.into_inner().unwrap().finish().unwrap();
        verify_source(scratch.path(), &bytes).unwrap();
        fs::write(scratch.path().join("extra.rs"), "extra").unwrap();
        assert!(verify_source(scratch.path(), &bytes)
            .unwrap_err()
            .to_string()
            .contains("extra"));
        fs::remove_file(scratch.path().join("extra.rs")).unwrap();
        fs::write(scratch.path().join("lib.rs"), "modified").unwrap();
        assert!(verify_source(scratch.path(), &bytes)
            .unwrap_err()
            .to_string()
            .contains("differs"));
    }
    #[test]
    fn installed_source_versions_must_match_the_inventory() {
        let scratch = tempfile::tempdir().unwrap();
        let directory = scratch.path().join("share/tecs");
        fs::create_dir_all(&directory).unwrap();
        fs::write(
            directory.join("cargo-licenses.txt"),
            "symphonia v0.6.1 MPL-2.0\n",
        )
        .unwrap();
        fs::write(
            directory.join("license-sources.json"),
            r#"{"version":1,"packages":[{"name":"symphonia","version":"0.5.5"}]}"#,
        )
        .unwrap();
        let mut problems = Vec::new();
        check(scratch.path(), &mut problems).unwrap();
        assert_eq!(problems.len(), 2);
        assert!(problems.iter().any(|value| value.contains("0.6.1")));
    }
}
