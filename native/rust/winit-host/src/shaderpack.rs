//! The material dispatch a build compiles, and the file it ships in.
//!
//! Every material found under a material root is folded into one generated
//! fragment shader that dispatches on the id an instance carries. One dispatch
//! is what keeps the renderer's draw count a function of the batching rather
//! than of how many different shapes the scene holds.
//!
//! Assembling is text: each material's `material` function is renamed and a
//! `materialDispatch` is written over the renamed set. Nothing here parses
//! WGSL. That matters for what a release links: `assemble` reads a directory
//! and `read` reads a file, and a packaged build calls only the second, so no
//! part of the shader toolchain is on the path a game runs.
//!
//! The numbering rule is `tecs.gpu.materials`': `textured` holds id zero,
//! because an instance with no `Material` writes a zero, and every other name
//! follows alphabetically. The two sides derive it from the same file set and
//! the packet validator refuses an id past the count this pack answers to, so a
//! disagreement fails rather than drawing the wrong material.

use std::fs;
use std::path::Path;

use anyhow::{bail, Context, Result};

/// Identifies the file and its layout. The magic is checked so a wrong or
/// truncated file is reported as such rather than as a decode error from
/// somewhere inside the reader. It is a compatibility surface.
const MAGIC: &[u8; 6] = b"TECSSP";

/// The layout this build writes and the only one it reads.
const VERSION: u32 = 4;

/// Takes id zero. A compatibility surface shared with `tecs.gpu.materials`.
const DEFAULT_MATERIAL: &str = "textured";

/// The assembled material dispatch and the names it answers to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShaderPack {
    /// Material names in id order, so the index is the id.
    materials: Vec<String>,
    /// The generated WGSL, which the geometry and forward modules include.
    dispatch: String,
}

impl ShaderPack {
    pub fn materials(&self) -> &[String] {
        &self.materials
    }

    /// Returns how many ids the dispatch answers to, which bounds what a packet
    /// may name.
    pub fn material_count(&self) -> u32 {
        self.materials.len() as u32
    }

    pub fn dispatch(&self) -> &str {
        &self.dispatch
    }

    /// Reads every `*.wgsl` under one directory and folds them into a dispatch.
    ///
    /// This is the development path and the path the packaging step runs. It is
    /// never on the path a packaged game takes.
    pub fn assemble(directory: &Path) -> Result<Self> {
        let entries = fs::read_dir(directory)
            .with_context(|| format!("read the material directory {}", directory.display()))?;
        let mut sources: Vec<(String, String)> = Vec::new();
        for entry in entries {
            let entry = entry.context("read a material directory entry")?;
            let path = entry.path();
            if path.extension().and_then(|value| value.to_str()) != Some("wgsl") {
                continue;
            }
            let name = path
                .file_stem()
                .and_then(|value| value.to_str())
                .context("a material file has no usable name")?
                .to_owned();
            let source = fs::read_to_string(&path)
                .with_context(|| format!("read the material {}", path.display()))?;
            sources.push((name, source));
        }
        Self::from_sources(sources)
    }

    /// Folds a set of named material sources into a dispatch.
    pub fn from_sources(mut sources: Vec<(String, String)>) -> Result<Self> {
        sources.sort_by(|left, right| left.0.cmp(&right.0));
        sources.dedup_by(|left, right| left.0 == right.0);
        let Some(default) = sources
            .iter()
            .position(|(name, _)| name == DEFAULT_MATERIAL)
        else {
            bail!("the material set has no '{DEFAULT_MATERIAL}', which holds id zero");
        };
        let entry = sources.remove(default);
        sources.insert(0, entry);

        let mut dispatch = String::from("// Generated from the material roots. Do not edit.\n\n");
        for (id, (name, source)) in sources.iter().enumerate() {
            dispatch.push_str(&format!("// {name} (id {id})\n"));
            // Renamed rather than namespaced, because WGSL has no namespaces
            // and two materials both defining `material` would collide.
            dispatch.push_str(&rename(source, &mangle(name)));
            dispatch.push('\n');
        }
        dispatch
            .push_str("fn materialDispatch(id: u32, frag: MaterialInput) -> MaterialOutput {\n");
        for (id, (name, _)) in sources.iter().enumerate() {
            dispatch.push_str(&format!(
                "    if (id == {id}u) {{ return {}(frag); }}\n",
                mangle(name)
            ));
        }
        // An unknown id is a bug rather than a state to render, so it is loud:
        // magenta at full coverage is visible in any scene. Built from the
        // defaults for the same reason every material is, so the fields this
        // path has no opinion about are answers rather than whatever was there.
        dispatch.push_str("    var unknown = materialDefaults();\n");
        dispatch.push_str("    unknown.albedo = vec4<f32>(1.0, 0.0, 1.0, 1.0);\n");
        dispatch.push_str("    return unknown;\n");
        dispatch.push_str("}\n");

        Ok(Self {
            materials: sources.into_iter().map(|(name, _)| name).collect(),
            dispatch,
        })
    }

    /// Encodes the pack for a release to load.
    pub fn encode(&self) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(MAGIC);
        bytes.extend_from_slice(&VERSION.to_le_bytes());
        bytes.extend_from_slice(&(self.materials.len() as u32).to_le_bytes());
        for name in &self.materials {
            bytes.extend_from_slice(&(name.len() as u32).to_le_bytes());
            bytes.extend_from_slice(name.as_bytes());
        }
        bytes.extend_from_slice(&(self.dispatch.len() as u32).to_le_bytes());
        bytes.extend_from_slice(self.dispatch.as_bytes());
        bytes
    }

    /// Decodes a pack a build produced.
    ///
    /// The layout is explicitly little-endian, so a host may build a pack for
    /// another architecture.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let mut reader = Reader::new(bytes);
        if reader.bytes(MAGIC.len())? != MAGIC {
            bail!("the shader pack does not begin with its magic");
        }
        let version = reader.u32()?;
        if version != VERSION {
            bail!("shader pack version {version} is not {VERSION}");
        }
        let count = reader.u32()? as usize;
        let mut materials = Vec::with_capacity(count);
        for _ in 0..count {
            let length = reader.u32()? as usize;
            materials.push(
                std::str::from_utf8(reader.bytes(length)?)
                    .context("a shader pack material name is not UTF-8")?
                    .to_owned(),
            );
        }
        if materials.first().map(String::as_str) != Some(DEFAULT_MATERIAL) {
            bail!("the shader pack's id zero is not '{DEFAULT_MATERIAL}'");
        }
        let length = reader.u32()? as usize;
        let dispatch = std::str::from_utf8(reader.bytes(length)?)
            .context("the shader pack dispatch is not UTF-8")?
            .to_owned();
        reader.finish()?;

        Ok(Self {
            materials,
            dispatch,
        })
    }

    pub fn write(&self, path: &Path) -> Result<()> {
        fs::write(path, self.encode())
            .with_context(|| format!("write the shader pack {}", path.display()))
    }

    pub fn read(path: &Path) -> Result<Self> {
        let bytes =
            fs::read(path).with_context(|| format!("read the shader pack {}", path.display()))?;
        Self::decode(&bytes)
    }
}

/// Turns a material name into something that can be a WGSL identifier.
fn mangle(name: &str) -> String {
    let mut mangled = String::from("material_");
    for character in name.chars() {
        if character.is_ascii_alphanumeric() {
            mangled.push(character);
        } else {
            mangled.push('_');
        }
    }
    mangled
}

/// Renames a material's own `material` function without touching any other
/// identifier that happens to contain the word.
fn rename(source: &str, to: &str) -> String {
    let mut out = String::with_capacity(source.len() + to.len());
    let bytes = source.as_bytes();
    let mut at = 0;
    while let Some(found) = source[at..].find("material") {
        let start = at + found;
        let end = start + "material".len();
        let before_is_word = start > 0 && is_word(bytes[start - 1]);
        let after = source[end..].trim_start();
        let is_declaration =
            !before_is_word && after.starts_with('(') && source[..start].trim_end().ends_with("fn");
        out.push_str(&source[at..start]);
        if is_declaration {
            out.push_str(to);
        } else {
            out.push_str("material");
        }
        at = end;
    }
    out.push_str(&source[at..]);
    out
}

fn is_word(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_'
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, at: 0 }
    }

    fn u32(&mut self) -> Result<u32> {
        let slice = self
            .bytes
            .get(self.at..self.at + 4)
            .context("the shader pack ended in the middle of a word")?;
        self.at += 4;
        Ok(u32::from_le_bytes(slice.try_into().expect("four bytes")))
    }

    fn bytes(&mut self, count: usize) -> Result<&'a [u8]> {
        let slice = self
            .bytes
            .get(self.at..self.at + count)
            .context("the shader pack is shorter than it declares")?;
        self.at += count;
        Ok(slice)
    }

    fn finish(&self) -> Result<()> {
        if self.at != self.bytes.len() {
            bail!(
                "the shader pack is {} bytes and its records read {}",
                self.bytes.len(),
                self.at
            );
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sources() -> Vec<(String, String)> {
        vec![
            (
                "rounded".to_owned(),
                "fn material(frag: MaterialInput) -> MaterialOutput { return materialDefaults(); }\n"
                    .to_owned(),
            ),
            (
                "textured".to_owned(),
                "fn material(frag: MaterialInput) -> MaterialOutput { return materialDefaults(); }\n"
                    .to_owned(),
            ),
            (
                "game.ripple".to_owned(),
                "fn material(frag: MaterialInput) -> MaterialOutput { return materialDefaults(); }\n"
                    .to_owned(),
            ),
        ]
    }

    #[test]
    fn numbers_the_default_first_and_the_rest_alphabetically() {
        let pack = ShaderPack::from_sources(sources()).expect("assembled");
        assert_eq!(pack.materials(), ["textured", "game.ripple", "rounded"]);
        assert_eq!(pack.material_count(), 3);
    }

    #[test]
    fn dispatches_every_material_by_its_id() {
        let pack = ShaderPack::from_sources(sources()).expect("assembled");
        let dispatch = pack.dispatch();
        assert!(dispatch.contains("fn material_textured(frag: MaterialInput)"));
        assert!(dispatch.contains("fn material_game_ripple(frag: MaterialInput)"));
        assert!(dispatch.contains("if (id == 0u) { return material_textured(frag); }"));
        assert!(dispatch.contains("if (id == 1u) { return material_game_ripple(frag); }"));
        assert!(dispatch.contains("if (id == 2u) { return material_rounded(frag); }"));
        // An unknown id is loud rather than undefined.
        assert!(dispatch.contains("vec4<f32>(1.0, 0.0, 1.0, 1.0)"));
        assert!(
            !dispatch.contains("fn material(frag"),
            "no two bodies collide"
        );
    }

    #[test]
    fn renames_only_the_declaration() {
        let source = "fn material(frag: MaterialInput) -> MaterialOutput {\n\
                      // material notes\n\
                      var result = materialDefaults();\n\
                      let m: MaterialOutput = result;\n\
                      return result;\n}\n";
        let renamed = rename(source, "material_x");
        assert!(renamed.contains("fn material_x(frag"));
        assert!(renamed.contains("// material notes"), "{renamed}");
        assert!(renamed.contains("materialDefaults()"), "{renamed}");
        assert!(renamed.contains("MaterialOutput"), "{renamed}");
    }

    #[test]
    fn refuses_a_set_with_no_default() {
        let error =
            ShaderPack::from_sources(vec![("rounded".to_owned(), "fn material() {}".to_owned())])
                .unwrap_err()
                .to_string();
        assert!(error.contains("no 'textured'"), "{error}");
    }

    #[test]
    fn round_trips_through_its_file() {
        let pack = ShaderPack::from_sources(sources()).expect("assembled");
        let bytes = pack.encode();
        assert_eq!(ShaderPack::decode(&bytes).expect("decoded"), pack);
    }

    #[test]
    fn refuses_a_pack_it_would_misread() {
        let pack = ShaderPack::from_sources(sources()).expect("assembled");
        let mut bytes = pack.encode();
        bytes[0] = b'X';
        assert!(ShaderPack::decode(&bytes)
            .unwrap_err()
            .to_string()
            .contains("magic"));

        let mut versioned = pack.encode();
        versioned[6] = 3;
        assert!(ShaderPack::decode(&versioned)
            .unwrap_err()
            .to_string()
            .contains("version 3"));

        let mut truncated = pack.encode();
        truncated.truncate(truncated.len() - 8);
        assert!(ShaderPack::decode(&truncated).is_err());

        let mut trailing = pack.encode();
        trailing.push(0);
        assert!(ShaderPack::decode(&trailing)
            .unwrap_err()
            .to_string()
            .contains("records read"));
    }

    #[test]
    fn assembles_the_engine_material_set() {
        let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../assets/materials")
            .canonicalize()
            .expect("the engine material directory is in the tree");
        let pack = ShaderPack::assemble(&directory).expect("assembled");
        // The engine's own set, numbered by the rule `tecs.gpu.materials` uses.
        assert_eq!(
            pack.materials(),
            [
                "textured",
                "capsule",
                "circle",
                "ellipse",
                "emissive",
                "frame",
                "glyph",
                "glyphalpha",
                "line",
                "pie",
                "ring",
                "rounded",
                "star",
                "triangle",
            ]
        );
    }
}
