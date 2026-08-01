use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum DependencyMode {
    System,
    Packaged,
    Single,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ShaderMode {
    Runtime,
    Packaged,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Preset {
    pub name: &'static str,
    pub rust_target: &'static str,
    pub dependencies: DependencyMode,
    pub shaders: ShaderMode,
    pub sanitize: bool,
    pub deployment_target: Option<&'static str>,
    pub entry: &'static str,
}

impl Preset {
    pub const fn is_single(self) -> bool {
        matches!(self.dependencies, DependencyMode::Single)
    }
}

pub const PRESETS: &[Preset] = &[
    Preset {
        name: "macos-arm64-dev",
        rust_target: "aarch64-apple-darwin",
        dependencies: DependencyMode::System,
        shaders: ShaderMode::Runtime,
        sanitize: false,
        deployment_target: Some("15.0"),
        entry: "main.lua",
    },
    Preset {
        name: "macos-arm64-sanitize",
        rust_target: "aarch64-apple-darwin",
        dependencies: DependencyMode::System,
        shaders: ShaderMode::Runtime,
        sanitize: true,
        deployment_target: Some("15.0"),
        entry: "main.lua",
    },
    Preset {
        name: "macos-arm64",
        rust_target: "aarch64-apple-darwin",
        dependencies: DependencyMode::Packaged,
        shaders: ShaderMode::Packaged,
        sanitize: false,
        deployment_target: Some("11.0"),
        entry: "main.lua",
    },
    Preset {
        name: "macos-arm64-single",
        rust_target: "aarch64-apple-darwin",
        dependencies: DependencyMode::Single,
        shaders: ShaderMode::Runtime,
        sanitize: false,
        deployment_target: Some("11.0"),
        entry: "lua/tecscli/init.lua",
    },
    Preset {
        name: "macos-x64",
        rust_target: "x86_64-apple-darwin",
        dependencies: DependencyMode::Packaged,
        shaders: ShaderMode::Packaged,
        sanitize: false,
        deployment_target: Some("10.15"),
        entry: "main.lua",
    },
    Preset {
        name: "linux-x64-dev",
        rust_target: "x86_64-unknown-linux-gnu",
        dependencies: DependencyMode::System,
        shaders: ShaderMode::Runtime,
        sanitize: false,
        deployment_target: None,
        entry: "main.lua",
    },
    Preset {
        name: "linux-x64-sanitize",
        rust_target: "x86_64-unknown-linux-gnu",
        dependencies: DependencyMode::System,
        shaders: ShaderMode::Runtime,
        sanitize: true,
        deployment_target: None,
        entry: "main.lua",
    },
    Preset {
        name: "linux-x64",
        rust_target: "x86_64-unknown-linux-gnu",
        dependencies: DependencyMode::Packaged,
        shaders: ShaderMode::Packaged,
        sanitize: false,
        deployment_target: None,
        entry: "main.lua",
    },
    Preset {
        name: "windows-x64",
        rust_target: "x86_64-pc-windows-msvc",
        dependencies: DependencyMode::Packaged,
        shaders: ShaderMode::Packaged,
        sanitize: false,
        deployment_target: None,
        entry: "main.lua",
    },
];

impl FromStr for Preset {
    type Err = anyhow::Error;

    fn from_str(name: &str) -> Result<Self, Self::Err> {
        PRESETS
            .iter()
            .copied()
            .find(|preset| preset.name == name)
            .ok_or_else(|| anyhow::anyhow!("unknown preset {name:?}; run `cargo xtask presets`"))
    }
}

impl fmt::Display for Preset {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.name)
    }
}

pub fn host_default() -> anyhow::Result<Preset> {
    let name = match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => "macos-arm64-dev",
        ("linux", "x86_64") => "linux-x64-dev",
        (os, arch) => {
            anyhow::bail!("there is no development preset for {os}/{arch}; pass --preset")
        }
    };
    name.parse()
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;
    use std::fs;
    use std::path::Path;

    use super::{DependencyMode, Preset, PRESETS};

    #[test]
    fn names_are_unique() {
        for (index, preset) in PRESETS.iter().enumerate() {
            assert!(!PRESETS[..index]
                .iter()
                .any(|other| other.name == preset.name));
        }
    }

    #[test]
    fn single_file_is_exactly_one_preset() {
        let singles: Vec<_> = PRESETS
            .iter()
            .copied()
            .filter(|preset| preset.is_single())
            .collect();
        assert_eq!(singles.len(), 1);
        assert_eq!(singles[0].name, "macos-arm64-single");
        assert_eq!(singles[0].dependencies, DependencyMode::Single);
    }

    #[test]
    fn unknown_preset_is_actionable() {
        let error = "wat".parse::<Preset>().unwrap_err().to_string();
        assert!(error.contains("cargo xtask presets"));
    }

    #[test]
    fn cli_targets_match_packaged_presets() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let source = fs::read_to_string(root.join("cli/tecscli/targets.tl")).unwrap();
        let cli: BTreeSet<_> = source
            .lines()
            .filter_map(|line| {
                line.trim()
                    .strip_prefix("name = \"")
                    .and_then(|name| name.strip_suffix("\","))
            })
            .collect();
        let presets: BTreeSet<_> = PRESETS
            .iter()
            .filter(|preset| matches!(preset.dependencies, DependencyMode::Packaged))
            .map(|preset| preset.name)
            .collect();
        assert_eq!(cli, presets);
    }
}
