use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result};
use regex::Regex;
use tempfile::tempdir;
use walkdir::WalkDir;

const SYSTEM_PREFIXES: &[&str] = &[
    "/usr/lib/",
    "/System/Library/",
    "@rpath/",
    "@executable_path/",
    "@loader_path/",
    "/lib/",
    "/lib64/",
];
const COMPILER_NAMES: &[&str] = &["shaderc", "spirvcross", "spirv-cross", "dxcompiler"];
const LINKED_LIBRARIES: &[(&str, &str, &str)] = &[
    (r"tecs\w*", "MIT OR Apache-2.0", "the engine's own"),
    (
        r"spirvcrossc",
        "Apache-2.0 OR MIT",
        "the shared FFI library over SPIRV-Cross",
    ),
    (r"cjson", "MIT", "the vendored lua-cjson"),
    (r"SDL3(_mixer)?", "Zlib", "SDL and its audio satellite"),
    (r"luajit", "MIT", "the VM, including PUC-Rio Lua's notice"),
    (
        r"shaderc(_shared)?",
        "Apache-2.0",
        "the development shader compiler",
    ),
    (r"z", "Zlib", "the public deflate service"),
    (
        r"(ogg|opus|opusfile)",
        "BSD-3-Clause",
        "SDL_mixer's Opus decoder",
    ),
    (r"wavpack", "BSD-3-Clause", "SDL_mixer's WavPack decoder"),
];
const REQUIRED_NOTICES: &[&str] = &[
    "share/tecs/THIRD_PARTY_NOTICES.md",
    "share/tecs/LICENSE-MIT",
    "share/tecs/LICENSE-APACHE",
];
const GLOBAL_USAGE: &str = r#"
local world = tecs.ecs.newWorld()
world:update(1 / 60)
tecs.log.get("game"):info("entities: %d", world:getStats().entities)

return tecs.newApplication({
    plugin = function(world: tecs.World, app: tecs.Application)
        print(world ~= nil and app.world ~= nil)
    end,
})
"#;

pub struct Options<'a> {
    pub prefix: &'a Path,
    pub allow_compiler: bool,
    pub teal_types: Option<&'a Path>,
}

pub fn check(options: &Options<'_>) -> Result<()> {
    let prefix = options
        .prefix
        .canonicalize()
        .with_context(|| format!("no such install prefix: {}", options.prefix.display()))?;
    let info = prefix.join("share/tecs/build-info.txt");
    let development = fs::read_to_string(info)
        .is_ok_and(|text| text.contains("systemDeps=ON") || text.contains("systemDeps=true"));
    let binaries = binaries(&prefix)?;
    if binaries.is_empty() {
        anyhow::bail!("no binaries found under {}", prefix.display());
    }
    let packaged_names: BTreeSet<_> = WalkDir::new(&prefix)
        .into_iter()
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|entry| entry.file_type().is_file() || entry.file_type().is_symlink())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();

    let mut license_problems = Vec::new();
    for notice in REQUIRED_NOTICES {
        if !prefix.join(notice).exists() {
            license_problems.push(format!(
                "no {notice}: a package that ships the code has to ship the notice"
            ));
        }
    }

    let mut problems = Vec::new();
    for binary in &binaries {
        let (rpaths, libraries) = references(binary)?;
        check_licenses(binary, &libraries, &mut license_problems)?;
        for rpath in rpaths {
            if !["@executable_path", "@loader_path", "$ORIGIN"]
                .iter()
                .any(|prefix| rpath.starts_with(prefix))
            {
                problems.push(format!(
                    "{}: search path leaves the package: {rpath}",
                    binary
                        .file_name()
                        .and_then(|value| value.to_str())
                        .unwrap_or("<binary>")
                ));
            }
        }
        for library in libraries {
            if let Some(name) = library.strip_prefix("@rpath/") {
                if !packaged_names.contains(name) {
                    problems.push(format!(
                        "{}: links {library}, but {name} is not in the package",
                        binary
                            .file_name()
                            .and_then(|value| value.to_str())
                            .unwrap_or("<binary>")
                    ));
                }
            }
            if library.starts_with('/')
                && !SYSTEM_PREFIXES
                    .iter()
                    .any(|prefix| library.starts_with(prefix))
            {
                problems.push(format!(
                    "{}: links an absolute path: {library}",
                    binary
                        .file_name()
                        .and_then(|value| value.to_str())
                        .unwrap_or("<binary>")
                ));
            }
        }
        if !options.allow_compiler {
            let name = binary
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or_default()
                .to_lowercase();
            for compiler in COMPILER_NAMES {
                if name.contains(compiler) {
                    problems.push(format!(
                        "{name}: a shader compiler must not ship in a release"
                    ));
                }
            }
        }
    }

    let packs = files_with_suffix(&prefix, "tsp")?;
    if packs.is_empty() {
        problems.push(
            "no shader pack (*.tsp): a release ships no compiler, so it must ship compiled shaders"
                .to_owned(),
        );
    }
    for pack in packs {
        let manifest = PathBuf::from(format!("{}.txt", pack.display()));
        if !manifest.exists() {
            problems.push(format!(
                "{}: no manifest beside it, so what it contains cannot be checked",
                pack.file_name()
                    .and_then(|value| value.to_str())
                    .unwrap_or("<shader pack>")
            ));
        } else {
            let source = fs::read_to_string(&manifest)?;
            if let Some(summary) = source.lines().nth(1) {
                println!("{}: {summary}", pack.strip_prefix(&prefix)?.display());
            }
        }
    }

    let mut type_problems = Vec::new();
    check_teal_types(&prefix, options.teal_types, &mut type_problems)?;
    println!(
        "checked {} binaries under {}",
        binaries.len(),
        prefix.display()
    );

    if !license_problems.is_empty() {
        let unique: BTreeSet<_> = license_problems.into_iter().collect();
        anyhow::bail!(
            "{} problems with the license position:\n{}",
            unique.len(),
            unique
                .into_iter()
                .map(|problem| format!("  {problem}"))
                .collect::<Vec<_>>()
                .join("\n")
        );
    }
    println!(
        "{} declared dependencies, and the notices to go with them",
        LINKED_LIBRARIES.len()
    );
    if !type_problems.is_empty() {
        anyhow::bail!(
            "{} problems with the packaged types:\n{}",
            type_problems.len(),
            type_problems
                .into_iter()
                .map(|problem| format!("  {problem}"))
                .collect::<Vec<_>>()
                .join("\n")
        );
    }
    if development {
        println!("\ndevelopment install: dependency containment was NOT checked.");
        println!("Build a packaged preset with `cargo xtask package --preset <name>`.");
        if !problems.is_empty() {
            println!(
                "\n{} references to the build machine, which a packaged preset would not have:",
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

fn binaries(prefix: &Path) -> Result<Vec<PathBuf>> {
    let mut binaries: Vec<_> = WalkDir::new(prefix)
        .into_iter()
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|entry| entry.file_type().is_file())
        .filter(|entry| {
            let path = entry.path();
            matches!(
                path.extension().and_then(|value| value.to_str()),
                Some("dylib" | "so" | "dll")
            ) || path
                .parent()
                .and_then(Path::file_name)
                .and_then(|value| value.to_str())
                == Some("bin")
        })
        .map(|entry| entry.into_path())
        .collect();
    binaries.sort();
    Ok(binaries)
}

fn files_with_suffix(prefix: &Path, extension: &str) -> Result<Vec<PathBuf>> {
    Ok(WalkDir::new(prefix)
        .into_iter()
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|entry| {
            entry.file_type().is_file()
                && entry.path().extension().and_then(|value| value.to_str()) == Some(extension)
        })
        .map(|entry| entry.into_path())
        .collect())
}

fn check_teal_types(
    prefix: &Path,
    teal_types: Option<&Path>,
    problems: &mut Vec<String>,
) -> Result<()> {
    let teal = prefix.join("share/tecs/teal");
    if !teal.join("tecs/global.d.tl").exists() {
        problems.push(
            "no tecs/global.d.tl under share/tecs/teal: a game's `tl check` has no `tecs` global"
                .to_owned(),
        );
        return Ok(());
    }
    if Command::new("tl").arg("--version").output().is_err() {
        println!("tl is not installed, so the packaged types were not checked");
        return Ok(());
    }
    let Some(teal_types) = teal_types else {
        println!("no --teal-types given, so the packaged types were not checked");
        return Ok(());
    };
    let teal_types = teal_types
        .canonicalize()
        .with_context(|| format!("no such Teal types directory: {}", teal_types.display()))?;
    let directory = tempdir()?;
    let usage = directory.path().join("usage.tl");
    fs::write(&usage, GLOBAL_USAGE)?;
    let result = Command::new("tl")
        .args(["--global-env-def", "tecs.global", "-I"])
        .arg(&teal_types)
        .arg("-I")
        .arg(&teal)
        .arg("check")
        .arg(&usage)
        .current_dir(directory.path())
        .output()
        .context("running packaged Teal type check")?;
    let stdout = String::from_utf8_lossy(&result.stdout);
    if !stdout.contains("0 errors detected") {
        problems
            .push("the packaged Teal types do not check a file using the `tecs` global:".into());
        let detail = format!("{}{}", stdout, String::from_utf8_lossy(&result.stderr));
        problems.extend(detail.lines().map(|line| format!("  {line}")));
    } else {
        println!(
            "{}: types a file using the `tecs` global",
            teal.strip_prefix(prefix)?.display()
        );
    }
    Ok(())
}

fn library_stem(reference: &str) -> Result<String> {
    let name = reference.rsplit('/').next().unwrap_or(reference);
    let shared = Regex::new(r"\.(dylib|so)(\.[\d.]+)?$")?;
    let versions = Regex::new(r"\.[\d.]+$")?;
    let suffix = Regex::new(r"-[\d.]+$")?;
    let name = shared.replace(name, "");
    let name = versions.replace(&name, "");
    let name = suffix.replace(&name, "");
    Ok(name.strip_prefix("lib").unwrap_or(&name).to_owned())
}

fn check_licenses(binary: &Path, libraries: &[String], problems: &mut Vec<String>) -> Result<()> {
    let patterns: Vec<_> = LINKED_LIBRARIES
        .iter()
        .map(|(pattern, _, _)| Regex::new(&format!("^(?:{pattern})$")))
        .collect::<Result<_, _>>()?;
    for library in libraries {
        if ["/usr/lib/", "/System/", "/lib/", "/lib64/"]
            .iter()
            .any(|prefix| library.starts_with(prefix))
        {
            continue;
        }
        let stem = library_stem(library)?;
        if !patterns.iter().any(|pattern| pattern.is_match(&stem)) {
            problems.push(format!(
                "{}: links {stem}, which is not a declared dependency. Add it with its license and reason, or remove it. Tecs brings in no LGPL.",
                binary.file_name().and_then(|value| value.to_str()).unwrap_or("<binary>")
            ));
        }
    }
    Ok(())
}

fn references(binary: &Path) -> Result<(Vec<String>, Vec<String>)> {
    match std::env::consts::OS {
        "macos" => macho_references(binary),
        "windows" => pe_references(binary),
        _ => elf_references(binary),
    }
}

fn macho_references(binary: &Path) -> Result<(Vec<String>, Vec<String>)> {
    let load = Command::new("otool").arg("-l").arg(binary).output()?;
    let text = String::from_utf8(load.stdout)?;
    let rpath = Regex::new(r"(?s)cmd LC_RPATH.*?path ([^\s]+)")?;
    let rpaths = rpath
        .captures_iter(&text)
        .map(|found| found[1].to_owned())
        .collect();
    let linked = Command::new("otool").arg("-L").arg(binary).output()?;
    let libraries = String::from_utf8(linked.stdout)?
        .lines()
        .skip(1)
        .filter_map(|line| line.split_whitespace().next().map(str::to_owned))
        .collect();
    Ok((rpaths, libraries))
}

fn elf_references(binary: &Path) -> Result<(Vec<String>, Vec<String>)> {
    let output = Command::new("readelf").arg("-d").arg(binary).output()?;
    let text = String::from_utf8(output.stdout)?;
    let rpath = Regex::new(r"\(R(?:UN)?PATH\).*\[([^\]]+)\]")?;
    let rpaths = rpath
        .captures_iter(&text)
        .flat_map(|found| found[1].split(':').map(str::to_owned).collect::<Vec<_>>())
        .collect();
    let needed = Regex::new(r"\(NEEDED\).*\[([^\]]+)\]")?;
    let libraries = needed
        .captures_iter(&text)
        .map(|found| found[1].to_owned())
        .collect();
    Ok((rpaths, libraries))
}

fn pe_references(binary: &Path) -> Result<(Vec<String>, Vec<String>)> {
    let output = Command::new("dumpbin")
        .arg("/dependents")
        .arg(binary)
        .output()
        .context("running dumpbin /dependents")?;
    let dll = Regex::new(r"(?i)^\s+([A-Za-z0-9_.+-]+\.dll)\s*$")?;
    let libraries = String::from_utf8(output.stdout)?
        .lines()
        .filter_map(|line| dll.captures(line).map(|found| found[1].to_owned()))
        .collect();
    Ok((Vec::new(), libraries))
}

#[cfg(test)]
mod tests {
    use super::library_stem;

    #[test]
    fn normalizes_shared_library_names() {
        assert_eq!(
            library_stem("@rpath/libluajit-5.1.2.dylib").unwrap(),
            "luajit"
        );
        assert_eq!(library_stem("libSDL3.so.0").unwrap(), "SDL3");
        assert_eq!(library_stem("z.dll").unwrap(), "z.dll");
    }
}
