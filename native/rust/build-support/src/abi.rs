use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result};
use regex::Regex;
use serde::Deserialize;
use tempfile::tempdir;

struct Library {
    name: &'static str,
    headers: &'static [&'static str],
    package: &'static str,
    requires: &'static [&'static str],
}

const LIBRARIES: &[Library] = &[
    Library {
        name: "sdl3",
        headers: &["SDL3/SDL.h"],
        package: "sdl3",
        requires: &[],
    },
    Library {
        name: "sdl3mixer",
        headers: &["SDL3_mixer/SDL_mixer.h"],
        package: "sdl3-mixer",
        requires: &["sdl3"],
    },
    Library {
        name: "shaderc",
        headers: &["shaderc/shaderc.h"],
        package: "shaderc",
        requires: &[],
    },
    Library {
        name: "zlib",
        headers: &["zlib.h"],
        package: "zlib",
        requires: &[],
    },
];

#[derive(Clone, Debug)]
struct Record {
    name: String,
    fields: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
struct Layout {
    #[serde(default)]
    name: String,
    size: usize,
    align: usize,
    fields: BTreeMap<String, usize>,
}

pub fn check(root: &Path, generated: &Path) -> Result<usize> {
    let mut total = 0;
    let mut mismatches = Vec::new();
    for library in LIBRARIES {
        let cdef = read_cdef(generated, library.name)?;
        let records = parse_records(&cdef)?;
        if records.is_empty() {
            println!("{}: no records found", library.name);
            continue;
        }
        let includes = include_directories(library.package);
        let from_c = c_report(library.headers, &includes, &records)?;
        let from_lua = lua_report(root, generated, library.name, &records, library.requires)?;
        let mut checked = 0;
        for record in &records {
            let (Some(c), Some(lua)) = (from_c.get(&record.name), from_lua.get(&record.name))
            else {
                continue;
            };
            checked += 1;
            if c.size != lua.size {
                mismatches.push(format!(
                    "{}.{}: sizeof C={} lua={}",
                    library.name, record.name, c.size, lua.size
                ));
            }
            if c.align != lua.align {
                mismatches.push(format!(
                    "{}.{}: alignof C={} lua={}",
                    library.name, record.name, c.align, lua.align
                ));
            }
            for field in &record.fields {
                if let (Some(c), Some(lua)) = (c.fields.get(field), lua.fields.get(field)) {
                    if c != lua {
                        mismatches.push(format!(
                            "{}.{}.{}: offset C={} lua={}",
                            library.name, record.name, field, c, lua
                        ));
                    }
                }
            }
        }
        total += checked;
        println!("{}: {checked} records verified", library.name);
    }
    if !mismatches.is_empty() {
        let shown = mismatches
            .iter()
            .take(50)
            .map(|value| format!("  {value}"))
            .collect::<Vec<_>>()
            .join("\n");
        anyhow::bail!("{} ABI MISMATCHES:\n{shown}", mismatches.len());
    }
    println!("\nABI OK: {total} records match the C compiler");
    Ok(total)
}

fn include_directories(package: &str) -> Vec<PathBuf> {
    let output = Command::new("pkg-config")
        .args(["--cflags-only-I", package])
        .output();
    if let Ok(output) = output {
        if output.status.success() {
            let found: Vec<_> = String::from_utf8_lossy(&output.stdout)
                .split_whitespace()
                .filter_map(|flag| flag.strip_prefix("-I"))
                .map(PathBuf::from)
                .collect();
            if !found.is_empty() {
                return found;
            }
        }
    }
    [
        "/opt/homebrew/include",
        "/usr/local/include",
        "/usr/include",
    ]
    .into_iter()
    .map(PathBuf::from)
    .filter(|path| path.is_dir())
    .collect()
}

fn read_cdef(generated: &Path, name: &str) -> Result<String> {
    let path = generated.join(format!("{name}cdef.lua"));
    let text = fs::read_to_string(&path)
        .with_context(|| format!("missing {}; run `cargo xtask build` first", path.display()))?;
    let opening = "[==========[";
    let closing = "]==========]";
    let start = text.find(opening).context("cdef has no opening marker")? + opening.len();
    let end = text.rfind(closing).context("cdef has no closing marker")?;
    Ok(text[start..end].to_owned())
}

fn parse_records(cdef: &str) -> Result<Vec<Record>> {
    let start = Regex::new(r"\b(typedef\s+)?(struct|union)\s+(\w+)?\s*\{")?;
    let end = Regex::new(r"^\s*(\w+)\s*;")?;
    let field = Regex::new(r"(\w+)\s*(?:\[[^\]]*\])*\s*;\s*$")?;
    let mut records = Vec::new();
    let mut position = 0;
    while let Some(found) = start.captures(&cdef[position..]) {
        let complete = found.get(0).expect("whole regex match");
        let absolute_start = position + complete.start();
        let opening = cdef[absolute_start..]
            .find('{')
            .map(|offset| absolute_start + offset)
            .context("record has no opening brace")?;
        let mut depth = 0_i32;
        let mut closing = None;
        for (offset, character) in cdef[opening..].char_indices() {
            match character {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if depth == 0 {
                        closing = Some(opening + offset);
                        break;
                    }
                }
                _ => {}
            }
        }
        let Some(closing) = closing else {
            break;
        };
        let tail = &cdef[closing + 1..];
        let ending = end.captures(tail);
        position = closing + 1;
        let name = if found.get(1).is_some() {
            let Some(ending) = ending else {
                continue;
            };
            position += ending.get(0).expect("whole regex match").end();
            ending[1].to_owned()
        } else {
            let Some(tag) = found.get(3) else {
                continue;
            };
            format!("{} {}", &found[2], tag.as_str())
        };
        let body = &cdef[opening + 1..closing];
        let mut fields = Vec::new();
        let mut member_depth = 0_i32;
        let mut declaration = String::new();
        for character in body.chars() {
            match character {
                '{' => member_depth += 1,
                '}' => member_depth -= 1,
                ';' if member_depth == 0 => {
                    declaration.push(';');
                    let stripped = declaration.trim();
                    if ![':', '{', '}']
                        .iter()
                        .any(|character| stripped.contains(*character))
                    {
                        if let Some(found) = field.captures(stripped) {
                            fields.push(found[1].to_owned());
                        }
                    }
                    declaration.clear();
                    continue;
                }
                _ => {}
            }
            declaration.push(character);
        }
        records.push(Record { name, fields });
    }
    Ok(records)
}

fn c_report(
    headers: &[&str],
    include_directories: &[PathBuf],
    records: &[Record],
) -> Result<HashMap<String, Layout>> {
    let includes = headers
        .iter()
        .map(|header| format!("#include <{header}>"))
        .collect::<Vec<_>>()
        .join("\n");
    let mut lines = Vec::new();
    for record in records {
        lines.push(format!(
            "    printf(\"{{\\\"name\\\":\\\"{}\\\",\\\"size\\\":%zu,\\\"align\\\":%zu,\\\"fields\\\":{{\", sizeof({}), _Alignof({}));",
            record.name, record.name, record.name
        ));
        for (index, field) in record.fields.iter().enumerate() {
            let comma = if index == 0 { "" } else { "," };
            lines.push(format!(
                "    printf(\"{comma}\\\"{field}\\\":%zu\", offsetof({}, {field}));",
                record.name
            ));
        }
        lines.push("    printf(\"}}\\n\");".to_owned());
    }
    let program = format!(
        "{includes}\n#include <stdio.h>\n#include <stddef.h>\nint main(void) {{\n{}\n    return 0;\n}}\n",
        lines.join("\n")
    );
    let directory = tempdir()?;
    let source = directory.path().join("abi.c");
    let executable = directory.path().join("abi");
    fs::write(&source, program)?;
    let mut compiler = Command::new("cc");
    compiler
        .args(["-std=c11", "-w", "-o"])
        .arg(&executable)
        .arg(&source);
    for include in include_directories {
        compiler.arg("-I").arg(include);
    }
    let build = compiler.output().context("starting ABI probe compiler")?;
    if !build.status.success() {
        anyhow::bail!(
            "ABI probe failed to compile:\n{}",
            String::from_utf8_lossy(&build.stderr)
                .chars()
                .take(3000)
                .collect::<String>()
        );
    }
    let run = Command::new(executable)
        .output()
        .context("running ABI probe")?;
    parse_json_report(&run.stdout)
}

fn lua_report(
    root: &Path,
    generated: &Path,
    name: &str,
    records: &[Record],
    requires: &[&str],
) -> Result<HashMap<String, Layout>> {
    let directory = tempdir()?;
    let listing = directory.path().join("records.txt");
    let list = records
        .iter()
        .map(|record| {
            std::iter::once(record.name.as_str())
                .chain(record.fields.iter().map(String::as_str))
                .collect::<Vec<_>>()
                .join("\t")
        })
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";
    fs::write(&listing, list)?;
    let declares = requires
        .iter()
        .map(|dependency| format!(r#"ffi.cdef(require("tecs.ffi.{dependency}cdef"))"#))
        .collect::<Vec<_>>()
        .join("\n");
    let lua_root = generated
        .parent()
        .and_then(Path::parent)
        .context("generated cdefs are not below a Lua root")?;
    let script = format!(
        r#"local ffi = require("ffi")
local listing = ...
package.path = "{lua}/?.lua;{lua}/?/init.lua;" .. package.path
{declares}
ffi.cdef(require("tecs.ffi.{name}cdef"))
local out = {{}}
for line in io.lines(listing) do
    local record = line:match("^([^\t]+)")
    local fields = {{}}
    for field in line:gmatch("\t([^\t]+)") do fields[#fields + 1] = field end
    local ok, size = pcall(ffi.sizeof, record)
    if ok and size then
        local parts = {{ record, tostring(size), tostring(ffi.alignof(record)) }}
        for _, field in ipairs(fields) do
            local fieldOk, offset = pcall(ffi.offsetof, record, field)
            if fieldOk and offset then parts[#parts + 1] = field .. "=" .. tostring(offset) end
        end
        out[#out + 1] = table.concat(parts, "\t")
    end
end
print(table.concat(out, "\n"))
"#,
        lua = lua_root.display()
    );
    let script_path = directory.path().join("probe.lua");
    fs::write(&script_path, script)?;
    let run = Command::new("luajit")
        .arg(script_path)
        .arg(listing)
        .current_dir(root)
        .output()
        .context("running LuaJIT ABI probe")?;
    if !run.status.success() {
        anyhow::bail!(
            "LuaJIT ABI probe failed:\n{}",
            String::from_utf8_lossy(&run.stderr)
                .chars()
                .take(3000)
                .collect::<String>()
        );
    }
    parse_lua_report(&run.stdout)
}

fn parse_json_report(output: &[u8]) -> Result<HashMap<String, Layout>> {
    let mut report = HashMap::new();
    for line in String::from_utf8(output.to_vec())?.lines() {
        if line.trim().is_empty() {
            continue;
        }
        let layout: Layout = serde_json::from_str(line)?;
        report.insert(layout.name.clone(), layout);
    }
    Ok(report)
}

fn parse_lua_report(output: &[u8]) -> Result<HashMap<String, Layout>> {
    let mut report = HashMap::new();
    for line in String::from_utf8(output.to_vec())?.lines() {
        let parts: Vec<_> = line.split('\t').collect();
        if parts.len() < 3 {
            continue;
        }
        let mut fields = BTreeMap::new();
        for item in &parts[3..] {
            if let Some((field, offset)) = item.split_once('=') {
                fields.insert(field.to_owned(), offset.parse()?);
            }
        }
        report.insert(
            parts[0].to_owned(),
            Layout {
                name: parts[0].to_owned(),
                size: parts[1].parse()?,
                align: parts[2].parse()?,
                fields,
            },
        );
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::parse_records;

    #[test]
    fn parses_typedef_and_tagged_records() {
        let records = parse_records(
            "typedef struct { int x; char bytes[4]; } Point;\nunion Value { int i; float f; };",
        )
        .unwrap();
        assert_eq!(records.len(), 2);
        assert_eq!(records[0].name, "Point");
        assert_eq!(records[0].fields, ["x", "bytes"]);
        assert_eq!(records[1].name, "union Value");
    }

    #[test]
    fn ignores_bit_fields_and_nested_members() {
        let records = parse_records(
            "typedef struct { int visible; unsigned flags: 2; union { int hidden; }; } Item;",
        )
        .unwrap();
        assert_eq!(records[0].fields, ["visible"]);
    }
}
