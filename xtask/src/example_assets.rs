#[cfg(feature = "bistro-import")]
use std::collections::BTreeMap;
use std::collections::BTreeSet;
use std::fs;
#[cfg(feature = "bistro-import")]
use std::io::{Cursor, Read};
use std::path::{Component, Path, PathBuf};
use std::process::Command;

use anyhow::{bail, Context, Result};
use image::imageops::FilterType;
use image::{DynamicImage, RgbaImage};
use serde_json::Value;
#[cfg(feature = "bistro-import")]
use sha2::{Digest, Sha256};

const SPONZA_REVISION: &str = "2bac6f8c57bf471df0d2a1e8a8ec023c7801dddf";
const SPONZA_MODEL_ROOT: &str = "Models/Sponza";
const SPONZA_TEXTURE_SIZE: u32 = 1024;
#[cfg(feature = "bistro-import")]
const BISTRO_REVISION: &str = "96b9ea240f779c99f475d928e6037e60e7c4692b";
#[cfg(feature = "bistro-import")]
const BISTRO_SHA256: &str = "31f0227490c570926dd16e6650a8584a530a3bcdf651ab524f56b3f00e8cc140";
#[cfg(feature = "bistro-import")]
const BISTRO_BYTES: u64 = 986_315_600;
#[cfg(feature = "bistro-import")]
const BISTRO_TEXTURE_SIZE: u32 = 512;
const COMPRESSED_MAGIC: &[u8; 8] = b"TECSBC3\0";
const COMPRESSED_VERSION: u32 = 1;

pub fn fetch(root: &Path, name: &str) -> Result<()> {
    match name {
        "sponza" => fetch_sponza(root),
        "bistro" => fetch_bistro(root),
        _ => bail!("unknown example asset {name:?}; expected `sponza` or `bistro`"),
    }
}

pub fn require_for_example(root: &Path, name: &str) -> Result<()> {
    if name == "sponza3d"
        && !root
            .join("assets/external/sponza/Sponza.tecs.gltf")
            .is_file()
    {
        bail!(
            "the sponza3d example needs its ignored scene cache; run `cargo xtask fetch sponza` first"
        );
    }
    if name == "bistro3d"
        && !root
            .join("assets/external/bistro/Bistro.tecs.gltf")
            .is_file()
    {
        bail!(
            "the bistro3d example needs its ignored scene cache; run `cargo xtask fetch bistro` first"
        );
    }
    Ok(())
}

#[cfg(not(feature = "bistro-import"))]
fn fetch_bistro(root: &Path) -> Result<()> {
    let status = Command::new("cargo")
        .args([
            "run",
            "--release",
            "-p",
            "tecs-xtask",
            "--features",
            "bistro-import",
            "--",
            "fetch",
            "bistro",
        ])
        .current_dir(root)
        .status()
        .context("starting the opt-in Bistro importer")?;
    if !status.success() {
        bail!("the Bistro importer exited with {status}");
    }
    Ok(())
}

#[cfg(feature = "bistro-import")]
fn fetch_bistro(root: &Path) -> Result<()> {
    let destination = root.join("assets/external/bistro");
    fs::create_dir_all(&destination)
        .with_context(|| format!("creating {}", destination.display()))?;
    let derived = destination.join("Bistro.tecs.gltf");
    let geometry = destination.join("Bistro.bin");
    if derived.is_file() && geometry.is_file() {
        let mut document: Value = serde_json::from_slice(
            &fs::read(&derived).with_context(|| format!("reading {}", derived.display()))?,
        )?;
        let promoted = promote_secondary_texcoords(&mut document);
        let mut geometry_bytes =
            fs::read(&geometry).with_context(|| format!("reading {}", geometry.display()))?;
        let synthesized = synthesize_missing_texcoords(&mut document, &mut geometry_bytes)?;
        if promoted > 0 || synthesized > 0 {
            fs::write(&derived, serde_json::to_vec_pretty(&document)?)
                .with_context(|| format!("updating {}", derived.display()))?;
            fs::write(&geometry, geometry_bytes)
                .with_context(|| format!("updating {}", geometry.display()))?;
            println!(
                "updated {promoted} Bistro secondary UV streams and synthesized {synthesized} missing UV streams"
            );
        }
        println!("using imported Bistro cache at {}", destination.display());
        return Ok(());
    }

    let raw = format!(
        "https://raw.githubusercontent.com/yamayuski/babylon-lumberyard-bistro/{BISTRO_REVISION}/Bistro_v5_2"
    );
    download(
        &format!("{raw}/LICENSE.txt"),
        &destination.join("LICENSE.txt"),
    )?;
    download(
        &format!("{raw}/README.txt"),
        &destination.join("NOTICE.txt"),
    )?;
    let source = destination.join("BistroExterior.source.glb");
    download_verified(
        &format!(
            "https://media.githubusercontent.com/media/yamayuski/babylon-lumberyard-bistro/{BISTRO_REVISION}/Bistro_v5_2/BistroExterior.glb"
        ),
        &source,
        BISTRO_BYTES,
        BISTRO_SHA256,
    )?;

    println!("decoding 1,591 Draco culling chunks; this can take several minutes");
    let source_data = fs::read(&source).with_context(|| format!("reading {}", source.display()))?;
    let (json, binary) = parse_glb(&source_data)?;
    let mut document: Value = serde_json::from_slice(json).context("parsing Bistro GLB JSON")?;
    let (mut geometry_bytes, geometry_buffer) = decompress_bistro_geometry(&mut document, binary)?;
    promote_secondary_texcoords(&mut document);
    let (compressed_bytes, source_texture_bytes) =
        preprocess_embedded_textures(&destination, &mut document, binary, BISTRO_TEXTURE_SIZE)?;
    compact_geometry(&mut document, geometry_buffer, &mut geometry_bytes, binary)?;
    drop(source_data);
    fs::write(&geometry, &geometry_bytes)
        .with_context(|| format!("writing {}", geometry.display()))?;
    fs::write(&derived, serde_json::to_vec_pretty(&document)?)
        .with_context(|| format!("writing {}", derived.display()))?;
    let chunks = primitive_count(&document);
    let vertices = accessor_total(&document, "POSITION");
    let indices = index_total(&document);
    fs::write(
        destination.join("SOURCE"),
        format!(
            "yamayuski/babylon-lumberyard-bistro\nrevision={BISTRO_REVISION}\npath=Bistro_v5_2/BistroExterior.glb\nsha256={BISTRO_SHA256}\nderived=Bistro.tecs.gltf\ntexture_format=BC3\ntexture_size={BISTRO_TEXTURE_SIZE}\ncull_chunks={chunks}\nvertices={vertices}\nindices={indices}\n"
        ),
    )?;
    fs::remove_file(&source).with_context(|| format!("removing temporary {}", source.display()))?;
    println!(
        "fetched and imported Bistro into {} ({chunks} culling chunks, {vertices} vertices, {indices} indices, {:.1} MiB geometry, {:.1} MiB source textures, {:.1} MiB BC3 mip chains)",
        destination.display(),
        geometry_bytes.len() as f64 / 1_048_576.0,
        source_texture_bytes as f64 / 1_048_576.0,
        compressed_bytes as f64 / 1_048_576.0,
    );
    Ok(())
}

fn fetch_sponza(root: &Path) -> Result<()> {
    let destination = root.join("assets/external/sponza");
    fs::create_dir_all(&destination)
        .with_context(|| format!("creating {}", destination.display()))?;

    let base = format!(
        "https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/{SPONZA_REVISION}/{SPONZA_MODEL_ROOT}"
    );
    download(&format!("{base}/README.md"), &destination.join("NOTICE.md"))?;
    let model = destination.join("Sponza.gltf");
    download(&format!("{base}/glTF/Sponza.gltf"), &model)?;

    let mut document: Value = serde_json::from_slice(
        &fs::read(&model).with_context(|| format!("reading {}", model.display()))?,
    )
    .with_context(|| format!("parsing {}", model.display()))?;
    let mut files = BTreeSet::new();
    collect_uris(&document, "buffers", &mut files)?;
    collect_uris(&document, "images", &mut files)?;
    for relative in files {
        let relative = safe_relative(&relative)?;
        let source = format!("{base}/glTF/{}", relative.to_string_lossy());
        download(&source, &destination.join(relative))?;
    }

    let (compressed_bytes, source_bytes) = preprocess_textures(&destination, &mut document)?;
    let derived = destination.join("Sponza.tecs.gltf");
    fs::write(&derived, serde_json::to_vec_pretty(&document)?)
        .with_context(|| format!("writing {}", derived.display()))?;
    let chunks = primitive_count(&document);

    fs::write(
        destination.join("SOURCE"),
        format!(
            "KhronosGroup/glTF-Sample-Assets\nrevision={SPONZA_REVISION}\npath={SPONZA_MODEL_ROOT}/glTF\nderived=Sponza.tecs.gltf\ntexture_format=BC3\ntexture_size={SPONZA_TEXTURE_SIZE}\ncull_chunks={chunks}\n"
        ),
    )?;
    println!(
        "fetched and imported Sponza into {} ({chunks} culling chunks, {:.1} MiB source textures, {:.1} MiB BC3 mip chains)",
        destination.display(),
        source_bytes as f64 / 1_048_576.0,
        compressed_bytes as f64 / 1_048_576.0
    );
    Ok(())
}

fn primitive_count(document: &Value) -> usize {
    document
        .get("meshes")
        .and_then(Value::as_array)
        .map(|meshes| {
            meshes
                .iter()
                .filter_map(|mesh| mesh.get("primitives").and_then(Value::as_array))
                .map(Vec::len)
                .sum()
        })
        .unwrap_or(0)
}

#[cfg(feature = "bistro-import")]
fn accessor_total(document: &Value, semantic: &str) -> u64 {
    let accessors = document
        .get("accessors")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    document
        .get("meshes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|mesh| mesh.get("primitives").and_then(Value::as_array))
        .flatten()
        .filter_map(|primitive| {
            primitive
                .get("attributes")
                .and_then(|attributes| attributes.get(semantic))
                .and_then(Value::as_u64)
                .and_then(|index| accessors.get(index as usize))
                .and_then(|accessor| accessor.get("count"))
                .and_then(Value::as_u64)
        })
        .sum()
}

#[cfg(feature = "bistro-import")]
fn index_total(document: &Value) -> u64 {
    let accessors = document
        .get("accessors")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    document
        .get("meshes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|mesh| mesh.get("primitives").and_then(Value::as_array))
        .flatten()
        .filter_map(|primitive| {
            primitive
                .get("indices")
                .and_then(Value::as_u64)
                .and_then(|index| accessors.get(index as usize))
                .and_then(|accessor| accessor.get("count"))
                .and_then(Value::as_u64)
        })
        .sum()
}

#[cfg(feature = "bistro-import")]
fn parse_glb(bytes: &[u8]) -> Result<(&[u8], &[u8])> {
    if bytes.len() < 20 || &bytes[..4] != b"glTF" {
        bail!("Bistro source is not a GLB container");
    }
    let u32_at =
        |offset: usize| u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap()) as usize;
    if u32_at(4) != 2 || u32_at(8) != bytes.len() {
        bail!("Bistro source has an invalid GLB header");
    }
    let json_length = u32_at(12);
    if &bytes[16..20] != b"JSON" || 20 + json_length + 8 > bytes.len() {
        bail!("Bistro source has an invalid GLB JSON chunk");
    }
    let binary_header = 20 + json_length;
    let binary_length = u32_at(binary_header);
    if &bytes[binary_header + 4..binary_header + 8] != b"BIN\0"
        || binary_header + 8 + binary_length > bytes.len()
    {
        bail!("Bistro source has an invalid GLB binary chunk");
    }
    Ok((
        &bytes[20..20 + json_length],
        &bytes[binary_header + 8..binary_header + 8 + binary_length],
    ))
}

#[cfg(feature = "bistro-import")]
struct DracoJob {
    mesh: usize,
    primitive: usize,
    view: usize,
    indices: usize,
    attributes: Vec<(u64, String, usize)>,
}

#[cfg(feature = "bistro-import")]
fn decompress_bistro_geometry(document: &mut Value, binary: &[u8]) -> Result<(Vec<u8>, usize)> {
    let views = document
        .get("bufferViews")
        .and_then(Value::as_array)
        .context("Bistro has no buffer views")?
        .clone();
    let mut jobs = Vec::new();
    for (mesh_index, mesh) in document
        .get("meshes")
        .and_then(Value::as_array)
        .context("Bistro has no meshes")?
        .iter()
        .enumerate()
    {
        for (primitive_index, primitive) in mesh
            .get("primitives")
            .and_then(Value::as_array)
            .context("Bistro mesh has no primitives")?
            .iter()
            .enumerate()
        {
            let Some(draco) = primitive.pointer("/extensions/KHR_draco_mesh_compression") else {
                continue;
            };
            let view = draco
                .get("bufferView")
                .and_then(Value::as_u64)
                .context("Bistro Draco primitive has no buffer view")?
                as usize;
            let mut attributes = Vec::new();
            for (semantic, unique_id) in draco
                .get("attributes")
                .and_then(Value::as_object)
                .context("Bistro Draco primitive has no attributes")?
            {
                let accessor = primitive
                    .get("attributes")
                    .and_then(|values| values.get(semantic))
                    .and_then(Value::as_u64)
                    .with_context(|| format!("Bistro Draco attribute {semantic} has no accessor"))?
                    as usize;
                attributes.push((
                    unique_id
                        .as_u64()
                        .with_context(|| format!("Bistro Draco attribute {semantic} has no ID"))?,
                    semantic.clone(),
                    accessor,
                ));
            }
            attributes.sort_by_key(|attribute| attribute.0);
            jobs.push(DracoJob {
                mesh: mesh_index,
                primitive: primitive_index,
                view,
                indices: primitive
                    .get("indices")
                    .and_then(Value::as_u64)
                    .context("Bistro Draco primitive has no index accessor")?
                    as usize,
                attributes,
            });
        }
    }
    let geometry_buffer = document
        .get("buffers")
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or(0);
    let mut geometry = Vec::new();
    for (job_index, job) in jobs.iter().enumerate() {
        let view = views
            .get(job.view)
            .with_context(|| format!("Bistro Draco view {} is missing", job.view))?;
        let offset = view.get("byteOffset").and_then(Value::as_u64).unwrap_or(0) as usize;
        let length = view
            .get("byteLength")
            .and_then(Value::as_u64)
            .context("Bistro Draco view has no byte length")? as usize;
        let compressed = binary.get(offset..offset + length).with_context(|| {
            format!("Bistro Draco view {} is outside the binary chunk", job.view)
        })?;
        let decoded = draco_decoder::decode_mesh_with_config_sync(compressed)
            .with_context(|| format!("decoding Bistro Draco primitive {job_index}"))?;
        let decoded_attributes = decoded.config.attributes();
        if decoded_attributes.len() != job.attributes.len() {
            bail!(
                "Bistro Draco primitive {job_index} decoded {} attributes but declares {}",
                decoded_attributes.len(),
                job.attributes.len()
            );
        }

        let index_length = decoded.config.index_length() as usize;
        let index_offset = append_aligned(&mut geometry, &decoded.data[..index_length]);
        let index_view = append_view(document, geometry_buffer, index_offset, index_length, 34963)?;
        update_accessor(
            document,
            job.indices,
            index_view,
            decoded.config.index_count() as u64,
            if index_length / decoded.config.index_count() as usize == 2 {
                5123
            } else {
                5125
            },
            "SCALAR",
        )?;

        for ((_, semantic, accessor), attribute) in
            job.attributes.iter().zip(decoded_attributes.iter())
        {
            let start = attribute.offset() as usize;
            let length = attribute.lenght() as usize;
            let bytes = decoded.data.get(start..start + length).with_context(|| {
                format!("decoded Bistro Draco attribute {semantic} is outside its buffer")
            })?;
            let offset = append_aligned(&mut geometry, bytes);
            let view = append_view(document, geometry_buffer, offset, length, 34962)?;
            update_accessor(
                document,
                *accessor,
                view,
                decoded.config.vertex_count() as u64,
                draco_component_type(attribute.data_type()),
                accessor_shape(attribute.dim())?,
            )?;
        }
        if !job
            .attributes
            .iter()
            .any(|(_, semantic, _)| semantic == "TEXCOORD_0" || semantic == "TEXCOORD_1")
        {
            let zeros = vec![0_u8; decoded.config.vertex_count() as usize * 8];
            let offset = append_aligned(&mut geometry, &zeros);
            let view = append_view(document, geometry_buffer, offset, zeros.len(), 34962)?;
            let accessor = document
                .get_mut("accessors")
                .and_then(Value::as_array_mut)
                .context("Bistro accessors disappeared")?;
            let index = accessor.len();
            accessor.push(serde_json::json!({
                "bufferView": view,
                "componentType": 5126,
                "count": decoded.config.vertex_count(),
                "type": "VEC2"
            }));
            document["meshes"][job.mesh]["primitives"][job.primitive]["attributes"]["TEXCOORD_0"] =
                Value::from(index as u64);
        }
        let primitive = document
            .get_mut("meshes")
            .and_then(Value::as_array_mut)
            .and_then(|meshes| meshes.get_mut(job.mesh))
            .and_then(|mesh| mesh.get_mut("primitives"))
            .and_then(Value::as_array_mut)
            .and_then(|primitives| primitives.get_mut(job.primitive))
            .context("Bistro primitive disappeared during decompression")?;
        if let Some(extensions) = primitive
            .get_mut("extensions")
            .and_then(Value::as_object_mut)
        {
            extensions.remove("KHR_draco_mesh_compression");
        }
        if job_index % 200 == 199 {
            println!("decoded {} / {} Bistro chunks", job_index + 1, jobs.len());
        }
    }
    document
        .get_mut("buffers")
        .and_then(Value::as_array_mut)
        .context("Bistro buffers disappeared")?
        .push(serde_json::json!({
            "byteLength": geometry.len(),
            "uri": "Bistro.bin"
        }));
    Ok((geometry, geometry_buffer))
}

#[cfg(feature = "bistro-import")]
fn append_aligned(output: &mut Vec<u8>, bytes: &[u8]) -> usize {
    while !output.len().is_multiple_of(4) {
        output.push(0);
    }
    let offset = output.len();
    output.extend_from_slice(bytes);
    offset
}

#[cfg(feature = "bistro-import")]
fn promote_secondary_texcoords(document: &mut Value) -> usize {
    let Some(meshes) = document.get_mut("meshes").and_then(Value::as_array_mut) else {
        return 0;
    };
    let mut promoted = 0;
    for attributes in meshes
        .iter_mut()
        .filter_map(|mesh| mesh.get_mut("primitives").and_then(Value::as_array_mut))
        .flatten()
        .filter_map(|primitive| {
            primitive
                .get_mut("attributes")
                .and_then(Value::as_object_mut)
        })
    {
        if !attributes.contains_key("TEXCOORD_0") {
            if let Some(accessor) = attributes.remove("TEXCOORD_1") {
                attributes.insert("TEXCOORD_0".to_owned(), accessor);
                promoted += 1;
            }
        }
    }
    promoted
}

#[cfg(feature = "bistro-import")]
fn synthesize_missing_texcoords(document: &mut Value, geometry: &mut Vec<u8>) -> Result<usize> {
    let accessors = document
        .get("accessors")
        .and_then(Value::as_array)
        .context("Bistro cache has no accessors")?;
    let mut jobs = Vec::new();
    for (mesh_index, mesh) in document
        .get("meshes")
        .and_then(Value::as_array)
        .context("Bistro cache has no meshes")?
        .iter()
        .enumerate()
    {
        for (primitive_index, primitive) in mesh
            .get("primitives")
            .and_then(Value::as_array)
            .context("Bistro cache mesh has no primitives")?
            .iter()
            .enumerate()
        {
            let attributes = primitive
                .get("attributes")
                .and_then(Value::as_object)
                .context("Bistro cache primitive has no attributes")?;
            if attributes.contains_key("TEXCOORD_0") || attributes.contains_key("TEXCOORD_1") {
                continue;
            }
            let position = attributes
                .get("POSITION")
                .and_then(Value::as_u64)
                .context("Bistro cache primitive has no position accessor")?
                as usize;
            let count = accessors
                .get(position)
                .and_then(|accessor| accessor.get("count"))
                .and_then(Value::as_u64)
                .context("Bistro cache position accessor has no count")?;
            jobs.push((mesh_index, primitive_index, count));
        }
    }
    for (mesh, primitive, count) in &jobs {
        let zeros = vec![0_u8; *count as usize * 8];
        let offset = append_aligned(geometry, &zeros);
        let views = document
            .get_mut("bufferViews")
            .and_then(Value::as_array_mut)
            .context("Bistro cache has no buffer views")?;
        let view = views.len();
        views.push(serde_json::json!({
            "buffer": 0,
            "byteOffset": offset,
            "byteLength": zeros.len(),
            "target": 34962
        }));
        let accessors = document
            .get_mut("accessors")
            .and_then(Value::as_array_mut)
            .context("Bistro cache accessors disappeared")?;
        let accessor = accessors.len();
        accessors.push(serde_json::json!({
            "bufferView": view,
            "componentType": 5126,
            "count": count,
            "type": "VEC2"
        }));
        document["meshes"][*mesh]["primitives"][*primitive]["attributes"]["TEXCOORD_0"] =
            Value::from(accessor as u64);
    }
    document["buffers"][0]["byteLength"] = Value::from(geometry.len() as u64);
    Ok(jobs.len())
}

#[cfg(feature = "bistro-import")]
fn append_view(
    document: &mut Value,
    buffer: usize,
    offset: usize,
    length: usize,
    target: u64,
) -> Result<usize> {
    let views = document
        .get_mut("bufferViews")
        .and_then(Value::as_array_mut)
        .context("Bistro buffer views disappeared")?;
    let index = views.len();
    views.push(serde_json::json!({
        "buffer": buffer,
        "byteOffset": offset,
        "byteLength": length,
        "target": target
    }));
    Ok(index)
}

#[cfg(feature = "bistro-import")]
fn update_accessor(
    document: &mut Value,
    accessor: usize,
    view: usize,
    count: u64,
    component_type: u64,
    shape: &str,
) -> Result<()> {
    let accessor = document
        .get_mut("accessors")
        .and_then(Value::as_array_mut)
        .and_then(|accessors| accessors.get_mut(accessor))
        .context("Bistro accessor disappeared")?;
    accessor["bufferView"] = Value::from(view as u64);
    accessor.as_object_mut().unwrap().remove("byteOffset");
    accessor["count"] = Value::from(count);
    accessor["componentType"] = Value::from(component_type);
    accessor["type"] = Value::String(shape.to_owned());
    Ok(())
}

#[cfg(feature = "bistro-import")]
fn draco_component_type(data_type: draco_decoder::AttributeDataType) -> u64 {
    use draco_decoder::AttributeDataType;
    match data_type {
        AttributeDataType::Int8 => 5120,
        AttributeDataType::UInt8 => 5121,
        AttributeDataType::Int16 => 5122,
        AttributeDataType::UInt16 => 5123,
        AttributeDataType::Int32 => 5124,
        AttributeDataType::UInt32 => 5125,
        AttributeDataType::Float32 => 5126,
    }
}

#[cfg(feature = "bistro-import")]
fn accessor_shape(dimensions: u32) -> Result<&'static str> {
    match dimensions {
        1 => Ok("SCALAR"),
        2 => Ok("VEC2"),
        3 => Ok("VEC3"),
        4 => Ok("VEC4"),
        _ => bail!("Bistro Draco attribute has {dimensions} components"),
    }
}

#[cfg(feature = "bistro-import")]
fn preprocess_embedded_textures(
    destination: &Path,
    document: &mut Value,
    source_buffer: &[u8],
    storage_size: u32,
) -> Result<(u64, u64)> {
    let normal_images = normal_image_indices(document);
    let views = document
        .get("bufferViews")
        .and_then(Value::as_array)
        .context("Bistro has no buffer views")?
        .clone();
    let images = document
        .get_mut("images")
        .and_then(Value::as_array_mut)
        .context("Bistro has no images")?;
    let compressed_root = destination.join("compressed");
    fs::create_dir_all(&compressed_root)
        .with_context(|| format!("creating {}", compressed_root.display()))?;
    let mut compressed_bytes = 0_u64;
    let mut source_bytes = 0_u64;
    for (index, image) in images.iter_mut().enumerate() {
        let view_index = image
            .get("bufferView")
            .and_then(Value::as_u64)
            .with_context(|| format!("Bistro image {index} has no embedded buffer view"))?
            as usize;
        let view = views.get(view_index).with_context(|| {
            format!("Bistro image {index} names missing buffer view {view_index}")
        })?;
        let buffer_index = view.get("buffer").and_then(Value::as_u64).unwrap_or(0) as usize;
        if buffer_index != 0 {
            bail!("Bistro image {index} is not in the GLB binary buffer");
        }
        let offset = view.get("byteOffset").and_then(Value::as_u64).unwrap_or(0) as usize;
        let length = view
            .get("byteLength")
            .and_then(Value::as_u64)
            .context("Bistro image buffer view has no byte length")? as usize;
        let bytes = source_buffer
            .get(offset..offset + length)
            .with_context(|| format!("Bistro image {index} is outside buffer {buffer_index}"))?;
        source_bytes += bytes.len() as u64;
        let relative = format!("compressed/image-{index:03}.tbc");
        let target = destination.join(&relative);
        let cached = fs::read(&target).ok();
        if cached
            .as_deref()
            .is_some_and(|bytes| valid_cached_texture(bytes, storage_size))
        {
            compressed_bytes += cached.as_ref().map(Vec::len).unwrap_or(0) as u64;
        } else {
            let mut decoded = decode_bistro_image(bytes)
                .with_context(|| format!("decoding Bistro image {index}"))?;
            if normal_images.contains(&index) {
                reconstruct_normal_blue(&mut decoded);
            }
            let encoded = encode_bc3_texture(
                &DynamicImage::ImageRgba8(decoded),
                storage_size,
                storage_size,
            )?;
            compressed_bytes += encoded.len() as u64;
            fs::write(&target, encoded).with_context(|| format!("writing {}", target.display()))?;
        }
        let object = image
            .as_object_mut()
            .with_context(|| format!("Bistro image {index} is not an object"))?;
        object.remove("bufferView");
        object.insert("uri".to_owned(), Value::String(relative));
        object.insert(
            "mimeType".to_owned(),
            Value::String("application/x-tecs-bc3".to_owned()),
        );
    }
    Ok((compressed_bytes, source_bytes))
}

#[cfg(feature = "bistro-import")]
fn normal_image_indices(document: &Value) -> BTreeSet<usize> {
    let textures = document
        .get("textures")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    document
        .get("materials")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|material| {
            material
                .get("normalTexture")
                .and_then(|texture| texture.get("index"))
                .and_then(Value::as_u64)
                .and_then(|index| textures.get(index as usize))
                .and_then(|texture| texture.get("source"))
                .and_then(Value::as_u64)
                .map(|index| index as usize)
        })
        .collect()
}

#[cfg(feature = "bistro-import")]
fn decode_bistro_image(bytes: &[u8]) -> Result<RgbaImage> {
    if bytes.starts_with(b"DDS ") {
        let dds = image_dds::ddsfile::Dds::read(&mut Cursor::new(bytes))
            .context("parsing DDS texture")?;
        return image_dds::image_from_dds(&dds, 0).context("decoding DDS texture");
    }
    Ok(image::load_from_memory(bytes)
        .context("decoding raster texture")?
        .to_rgba8())
}

#[cfg(feature = "bistro-import")]
fn reconstruct_normal_blue(image: &mut RgbaImage) {
    for pixel in image.pixels_mut() {
        let x = pixel[0] as f32 / 127.5 - 1.0;
        let y = pixel[1] as f32 / 127.5 - 1.0;
        let z = (1.0 - x * x - y * y).max(0.0).sqrt();
        pixel[2] = ((z * 0.5 + 0.5) * 255.0).round() as u8;
    }
}

#[cfg(feature = "bistro-import")]
fn compact_geometry(
    document: &mut Value,
    geometry_buffer: usize,
    geometry: &mut Vec<u8>,
    source_buffer: &[u8],
) -> Result<()> {
    let mut referenced = BTreeSet::new();
    collect_accessor_references(document, &mut referenced);
    let old_accessors = document
        .get("accessors")
        .and_then(Value::as_array)
        .context("Bistro has no accessors")?;
    let accessor_map: BTreeMap<usize, usize> = referenced
        .iter()
        .enumerate()
        .map(|(new, old)| (*old, new))
        .collect();
    let mut accessors: Vec<Value> = referenced
        .iter()
        .map(|old| {
            old_accessors
                .get(*old)
                .cloned()
                .with_context(|| format!("Bistro accessor {old} is missing"))
        })
        .collect::<Result<_>>()?;
    remap_accessor_references(document, &accessor_map)?;

    let mut referenced_views = BTreeSet::new();
    for accessor in &accessors {
        let view = accessor
            .get("bufferView")
            .and_then(Value::as_u64)
            .context("decompressed Bistro accessor has no buffer view")?
            as usize;
        referenced_views.insert(view);
    }
    let old_views = document
        .get("bufferViews")
        .and_then(Value::as_array)
        .context("Bistro has no buffer views")?;
    let view_map: BTreeMap<usize, usize> = referenced_views
        .iter()
        .enumerate()
        .map(|(new, old)| (*old, new))
        .collect();
    let mut views: Vec<Value> = referenced_views
        .iter()
        .map(|old| {
            old_views
                .get(*old)
                .cloned()
                .with_context(|| format!("Bistro buffer view {old} is missing"))
        })
        .collect::<Result<_>>()?;
    for accessor in &mut accessors {
        let old = accessor["bufferView"].as_u64().unwrap() as usize;
        accessor["bufferView"] = Value::from(view_map[&old] as u64);
    }

    for view in &mut views {
        let old_buffer = view.get("buffer").and_then(Value::as_u64).unwrap_or(0) as usize;
        if old_buffer == 0 {
            let offset = view.get("byteOffset").and_then(Value::as_u64).unwrap_or(0) as usize;
            let length =
                view.get("byteLength")
                    .and_then(Value::as_u64)
                    .context("Bistro retained view has no byte length")? as usize;
            let bytes = source_buffer
                .get(offset..offset + length)
                .context("Bistro retained view is outside the source buffer")?;
            view["byteOffset"] = Value::from(append_aligned(geometry, bytes) as u64);
        } else if old_buffer != geometry_buffer {
            bail!("Bistro retained a non-geometry buffer {old_buffer}");
        }
        view["buffer"] = Value::from(0_u64);
    }
    document["accessors"] = Value::Array(accessors);
    document["bufferViews"] = Value::Array(views);
    document["buffers"] = Value::Array(vec![serde_json::json!({
        "byteLength": geometry.len(),
        "uri": "Bistro.bin"
    })]);
    remove_extension(document, "KHR_draco_mesh_compression");
    Ok(())
}

#[cfg(feature = "bistro-import")]
fn collect_accessor_references(document: &Value, output: &mut BTreeSet<usize>) {
    if let Some(meshes) = document.get("meshes").and_then(Value::as_array) {
        for primitive in meshes
            .iter()
            .filter_map(|mesh| mesh.get("primitives").and_then(Value::as_array))
            .flatten()
        {
            collect_index(primitive.get("indices"), output);
            if let Some(attributes) = primitive.get("attributes").and_then(Value::as_object) {
                for value in attributes.values() {
                    collect_index(Some(value), output);
                }
            }
            if let Some(targets) = primitive.get("targets").and_then(Value::as_array) {
                for target in targets.iter().filter_map(Value::as_object) {
                    for value in target.values() {
                        collect_index(Some(value), output);
                    }
                }
            }
        }
    }
    if let Some(skins) = document.get("skins").and_then(Value::as_array) {
        for skin in skins {
            collect_index(skin.get("inverseBindMatrices"), output);
        }
    }
    if let Some(animations) = document.get("animations").and_then(Value::as_array) {
        for sampler in animations
            .iter()
            .filter_map(|animation| animation.get("samplers").and_then(Value::as_array))
            .flatten()
        {
            collect_index(sampler.get("input"), output);
            collect_index(sampler.get("output"), output);
        }
    }
}

#[cfg(feature = "bistro-import")]
fn collect_index(value: Option<&Value>, output: &mut BTreeSet<usize>) {
    if let Some(index) = value.and_then(Value::as_u64) {
        output.insert(index as usize);
    }
}

#[cfg(feature = "bistro-import")]
fn remap_accessor_references(document: &mut Value, map: &BTreeMap<usize, usize>) -> Result<()> {
    if let Some(meshes) = document.get_mut("meshes").and_then(Value::as_array_mut) {
        for primitive in meshes
            .iter_mut()
            .filter_map(|mesh| mesh.get_mut("primitives").and_then(Value::as_array_mut))
            .flatten()
        {
            remap_index(primitive.get_mut("indices"), map)?;
            if let Some(attributes) = primitive
                .get_mut("attributes")
                .and_then(Value::as_object_mut)
            {
                for value in attributes.values_mut() {
                    remap_index(Some(value), map)?;
                }
            }
            if let Some(targets) = primitive.get_mut("targets").and_then(Value::as_array_mut) {
                for target in targets.iter_mut().filter_map(Value::as_object_mut) {
                    for value in target.values_mut() {
                        remap_index(Some(value), map)?;
                    }
                }
            }
        }
    }
    if let Some(skins) = document.get_mut("skins").and_then(Value::as_array_mut) {
        for skin in skins {
            remap_index(skin.get_mut("inverseBindMatrices"), map)?;
        }
    }
    if let Some(animations) = document.get_mut("animations").and_then(Value::as_array_mut) {
        for sampler in animations
            .iter_mut()
            .filter_map(|animation| animation.get_mut("samplers").and_then(Value::as_array_mut))
            .flatten()
        {
            remap_index(sampler.get_mut("input"), map)?;
            remap_index(sampler.get_mut("output"), map)?;
        }
    }
    Ok(())
}

#[cfg(feature = "bistro-import")]
fn remap_index(value: Option<&mut Value>, map: &BTreeMap<usize, usize>) -> Result<()> {
    let Some(value) = value else { return Ok(()) };
    let old = value
        .as_u64()
        .context("Bistro accessor reference is not an integer")? as usize;
    let new = map
        .get(&old)
        .with_context(|| format!("Bistro accessor {old} was not retained"))?;
    *value = Value::from(*new as u64);
    Ok(())
}

#[cfg(feature = "bistro-import")]
fn remove_extension(document: &mut Value, name: &str) {
    for key in ["extensionsUsed", "extensionsRequired"] {
        let Some(values) = document.get_mut(key).and_then(Value::as_array_mut) else {
            continue;
        };
        values.retain(|value| value.as_str() != Some(name));
        if values.is_empty() {
            document.as_object_mut().unwrap().remove(key);
        }
    }
}

fn preprocess_textures(destination: &Path, document: &mut Value) -> Result<(u64, u64)> {
    let Some(images) = document.get_mut("images").and_then(Value::as_array_mut) else {
        return Ok((0, 0));
    };
    let compressed_root = destination.join("compressed");
    fs::create_dir_all(&compressed_root)
        .with_context(|| format!("creating {}", compressed_root.display()))?;
    let mut compressed_bytes = 0;
    let mut source_bytes = 0;
    for (index, image) in images.iter_mut().enumerate() {
        let uri = image
            .get("uri")
            .and_then(Value::as_str)
            .with_context(|| format!("Sponza image {index} has no external URI"))?;
        let source = destination.join(safe_relative(uri)?);
        let bytes = fs::read(&source).with_context(|| format!("reading {}", source.display()))?;
        source_bytes += bytes.len() as u64;
        let relative = format!("compressed/image-{index:03}.tbc");
        let target = destination.join(&relative);
        let cached = fs::read(&target).ok();
        if cached
            .as_deref()
            .is_some_and(|bytes| valid_cached_texture(bytes, SPONZA_TEXTURE_SIZE))
        {
            compressed_bytes += cached.as_ref().map(Vec::len).unwrap_or(0) as u64;
        } else {
            let decoded = image::load_from_memory(&bytes)
                .with_context(|| format!("decoding {}", source.display()))?;
            let encoded = encode_bc3_texture(&decoded, SPONZA_TEXTURE_SIZE, SPONZA_TEXTURE_SIZE)?;
            compressed_bytes += encoded.len() as u64;
            fs::write(&target, encoded).with_context(|| format!("writing {}", target.display()))?;
        }
        image["uri"] = Value::String(relative);
        image["mimeType"] = Value::String("application/x-tecs-bc3".to_owned());
    }
    Ok((compressed_bytes, source_bytes))
}

fn valid_cached_texture(bytes: &[u8], storage_size: u32) -> bool {
    if bytes.len() < 36 || &bytes[..8] != COMPRESSED_MAGIC {
        return false;
    }
    let value = |offset: usize| u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap());
    value(8) == COMPRESSED_VERSION
        && value(20) == storage_size
        && value(24) == storage_size
        && value(32) as usize == bytes.len() - 36
}

fn encode_bc3_texture(
    image: &DynamicImage,
    storage_width: u32,
    storage_height: u32,
) -> Result<Vec<u8>> {
    let source = image.to_rgba8();
    if source.width() == 0 || source.height() == 0 {
        bail!("cannot encode an empty texture");
    }
    let scale = (storage_width as f64 / source.width() as f64)
        .min(storage_height as f64 / source.height() as f64)
        .min(1.0);
    let width = ((source.width() as f64 * scale).round() as u32).max(1);
    let height = ((source.height() as f64 * scale).round() as u32).max(1);
    let source = if width != source.width() || height != source.height() {
        image::imageops::resize(&source, width, height, FilterType::Triangle)
    } else {
        source
    };
    let mut level = RgbaImage::from_fn(storage_width, storage_height, |x, y| {
        *source.get_pixel(x.min(width - 1), y.min(height - 1))
    });
    let levels = storage_width.max(storage_height).ilog2() + 1;
    let mut payload = Vec::new();
    for level_index in 0..levels {
        encode_bc3_level(&level, &mut payload);
        if level_index + 1 < levels {
            level = image::imageops::resize(
                &level,
                (level.width() / 2).max(1),
                (level.height() / 2).max(1),
                FilterType::Triangle,
            );
        }
    }
    let mut output = Vec::with_capacity(36 + payload.len());
    output.extend_from_slice(COMPRESSED_MAGIC);
    for value in [
        COMPRESSED_VERSION,
        width,
        height,
        storage_width,
        storage_height,
        levels,
        payload.len() as u32,
    ] {
        output.extend_from_slice(&value.to_le_bytes());
    }
    output.extend_from_slice(&payload);
    Ok(output)
}

fn encode_bc3_level(image: &RgbaImage, output: &mut Vec<u8>) {
    for block_y in (0..image.height()).step_by(4) {
        for block_x in (0..image.width()).step_by(4) {
            let mut pixels = [[0_u8; 4]; 16];
            for y in 0..4 {
                for x in 0..4 {
                    pixels[y * 4 + x] = image
                        .get_pixel(
                            (block_x + x as u32).min(image.width() - 1),
                            (block_y + y as u32).min(image.height() - 1),
                        )
                        .0;
                }
            }
            encode_bc3_block(&pixels, output);
        }
    }
}

fn encode_bc3_block(pixels: &[[u8; 4]; 16], output: &mut Vec<u8>) {
    let alpha_max = pixels.iter().map(|pixel| pixel[3]).max().unwrap_or(255);
    let alpha_min = pixels.iter().map(|pixel| pixel[3]).min().unwrap_or(255);
    output.push(alpha_max);
    output.push(alpha_min);
    let alpha_palette = alpha_palette(alpha_max, alpha_min);
    let mut alpha_bits = 0_u64;
    for (index, pixel) in pixels.iter().enumerate() {
        let selected = nearest_alpha(pixel[3], &alpha_palette);
        alpha_bits |= (selected as u64) << (index * 3);
    }
    output.extend_from_slice(&alpha_bits.to_le_bytes()[..6]);

    let mut low = [255_u8; 3];
    let mut high = [0_u8; 3];
    for pixel in pixels {
        for channel in 0..3 {
            low[channel] = low[channel].min(pixel[channel]);
            high[channel] = high[channel].max(pixel[channel]);
        }
    }
    let mut color0 = rgb565(high);
    let mut color1 = rgb565(low);
    if color0 <= color1 {
        if color1 > 0 {
            color0 = color1;
            color1 -= 1;
        } else {
            color0 = 1;
        }
    }
    output.extend_from_slice(&color0.to_le_bytes());
    output.extend_from_slice(&color1.to_le_bytes());
    let colors = color_palette(color0, color1);
    let mut color_bits = 0_u32;
    for (index, pixel) in pixels.iter().enumerate() {
        let selected = nearest_color(pixel, &colors);
        color_bits |= (selected as u32) << (index * 2);
    }
    output.extend_from_slice(&color_bits.to_le_bytes());
}

fn alpha_palette(high: u8, low: u8) -> [u8; 8] {
    let mut palette = [0; 8];
    palette[0] = high;
    palette[1] = low;
    if high > low {
        for index in 1..=6 {
            palette[index + 1] =
                (((7 - index) as u16 * high as u16 + index as u16 * low as u16) / 7) as u8;
        }
    } else {
        for index in 1..=4 {
            palette[index + 1] =
                (((5 - index) as u16 * high as u16 + index as u16 * low as u16) / 5) as u8;
        }
        palette[6] = 0;
        palette[7] = 255;
    }
    palette
}

fn nearest_alpha(alpha: u8, palette: &[u8; 8]) -> usize {
    palette
        .iter()
        .enumerate()
        .min_by_key(|(_, candidate)| alpha.abs_diff(**candidate))
        .map(|(index, _)| index)
        .unwrap_or(0)
}

fn rgb565(color: [u8; 3]) -> u16 {
    ((color[0] as u16 >> 3) << 11) | ((color[1] as u16 >> 2) << 5) | (color[2] as u16 >> 3)
}

fn expand565(color: u16) -> [u8; 3] {
    let r = ((color >> 11) & 31) as u8;
    let g = ((color >> 5) & 63) as u8;
    let b = (color & 31) as u8;
    [
        (r << 3) | (r >> 2),
        (g << 2) | (g >> 4),
        (b << 3) | (b >> 2),
    ]
}

fn color_palette(color0: u16, color1: u16) -> [[u8; 3]; 4] {
    let high = expand565(color0);
    let low = expand565(color1);
    [
        high,
        low,
        [
            ((2 * high[0] as u16 + low[0] as u16) / 3) as u8,
            ((2 * high[1] as u16 + low[1] as u16) / 3) as u8,
            ((2 * high[2] as u16 + low[2] as u16) / 3) as u8,
        ],
        [
            ((high[0] as u16 + 2 * low[0] as u16) / 3) as u8,
            ((high[1] as u16 + 2 * low[1] as u16) / 3) as u8,
            ((high[2] as u16 + 2 * low[2] as u16) / 3) as u8,
        ],
    ]
}

fn nearest_color(pixel: &[u8; 4], palette: &[[u8; 3]; 4]) -> usize {
    palette
        .iter()
        .enumerate()
        .min_by_key(|(_, candidate)| {
            let dr = pixel[0] as i32 - candidate[0] as i32;
            let dg = pixel[1] as i32 - candidate[1] as i32;
            let db = pixel[2] as i32 - candidate[2] as i32;
            dr * dr + dg * dg + db * db
        })
        .map(|(index, _)| index)
        .unwrap_or(0)
}

fn collect_uris(document: &Value, key: &str, output: &mut BTreeSet<String>) -> Result<()> {
    let Some(entries) = document.get(key).and_then(Value::as_array) else {
        return Ok(());
    };
    for entry in entries {
        let Some(uri) = entry.get("uri").and_then(Value::as_str) else {
            continue;
        };
        if uri.starts_with("data:") {
            continue;
        }
        output.insert(uri.to_owned());
    }
    Ok(())
}

fn safe_relative(value: &str) -> Result<PathBuf> {
    let path = Path::new(value);
    if path.as_os_str().is_empty()
        || path.is_absolute()
        || path
            .components()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        bail!("Sponza contains unsafe relative URI {value:?}");
    }
    Ok(path.to_owned())
}

fn download(url: &str, destination: &Path) -> Result<()> {
    if destination.is_file() {
        return Ok(());
    }
    let parent = destination
        .parent()
        .with_context(|| format!("{} has no parent", destination.display()))?;
    fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    let temporary = destination.with_extension(format!(
        "{}.part",
        destination
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("download")
    ));
    let status = Command::new("curl")
        .args(["-fsSL", "--show-error", "--retry", "3", "--output"])
        .arg(&temporary)
        .arg(url)
        .status()
        .with_context(|| format!("starting curl for {url}"))?;
    if !status.success() {
        let _ = fs::remove_file(&temporary);
        bail!("curl failed while fetching {url}");
    }
    fs::rename(&temporary, destination).with_context(|| {
        format!(
            "moving downloaded asset {} to {}",
            temporary.display(),
            destination.display()
        )
    })?;
    Ok(())
}

#[cfg(feature = "bistro-import")]
fn download_verified(
    url: &str,
    destination: &Path,
    expected_bytes: u64,
    expected_sha256: &str,
) -> Result<()> {
    if destination.is_file() && verify_file(destination, expected_bytes, expected_sha256)? {
        return Ok(());
    }
    if destination.exists() {
        fs::remove_file(destination)
            .with_context(|| format!("removing invalid {}", destination.display()))?;
    }
    download(url, destination)?;
    if !verify_file(destination, expected_bytes, expected_sha256)? {
        fs::remove_file(destination)
            .with_context(|| format!("removing invalid {}", destination.display()))?;
        bail!(
            "downloaded asset {} does not match its pinned size and SHA-256",
            destination.display()
        );
    }
    Ok(())
}

#[cfg(feature = "bistro-import")]
fn verify_file(path: &Path, expected_bytes: u64, expected_sha256: &str) -> Result<bool> {
    if fs::metadata(path)?.len() != expected_bytes {
        return Ok(false);
    }
    let mut file = fs::File::open(path).with_context(|| format!("opening {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut chunk = vec![0_u8; 1024 * 1024];
    loop {
        let count = file
            .read(&mut chunk)
            .with_context(|| format!("reading {}", path.display()))?;
        if count == 0 {
            break;
        }
        hasher.update(&chunk[..count]);
    }
    let digest = format!("{:x}", hasher.finalize());
    Ok(digest == expected_sha256)
}

#[cfg(test)]
mod tests {
    use super::{encode_bc3_texture, require_for_example, safe_relative, valid_cached_texture};
    use image::{DynamicImage, Rgba, RgbaImage};
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn accepts_model_relative_paths() {
        assert_eq!(
            safe_relative("textures/cloth.png").unwrap().to_str(),
            Some("textures/cloth.png")
        );
    }

    #[test]
    fn rejects_paths_outside_the_cache() {
        assert!(safe_relative("../outside.bin").is_err());
        assert!(safe_relative("/outside.bin").is_err());
    }

    #[test]
    fn writes_complete_bc3_mip_chains() {
        let image = DynamicImage::ImageRgba8(RgbaImage::from_pixel(2, 1, Rgba([17, 34, 51, 68])));
        let bytes = encode_bc3_texture(&image, 4, 4).unwrap();
        assert_eq!(&bytes[..8], b"TECSBC3\0");
        assert_eq!(u32::from_le_bytes(bytes[12..16].try_into().unwrap()), 2);
        assert_eq!(u32::from_le_bytes(bytes[28..32].try_into().unwrap()), 3);
        assert_eq!(u32::from_le_bytes(bytes[32..36].try_into().unwrap()), 48);
        assert_eq!(bytes.len(), 84);
        assert!(valid_cached_texture(&bytes, 4));
        let mut truncated = bytes;
        truncated.pop();
        assert!(!valid_cached_texture(&truncated, 4));
    }

    #[test]
    fn downsamples_large_textures_without_changing_the_storage_contract() {
        let image = DynamicImage::ImageRgba8(RgbaImage::from_pixel(1024, 256, Rgba([1, 2, 3, 4])));
        let bytes = encode_bc3_texture(&image, 512, 512).unwrap();
        assert_eq!(u32::from_le_bytes(bytes[12..16].try_into().unwrap()), 512);
        assert_eq!(u32::from_le_bytes(bytes[16..20].try_into().unwrap()), 128);
        assert_eq!(u32::from_le_bytes(bytes[20..24].try_into().unwrap()), 512);
        assert_eq!(u32::from_le_bytes(bytes[24..28].try_into().unwrap()), 512);
        assert!(valid_cached_texture(&bytes, 512));
    }

    #[test]
    fn requires_large_scene_caches_before_opening_their_windows() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "tecs-sponza-example-{}-{unique}",
            std::process::id()
        ));
        assert!(require_for_example(&root, "sponza3d").is_err());
        assert!(require_for_example(&root, "bistro3d").is_err());
        assert!(require_for_example(&root, "scene3d").is_ok());

        let scene = root.join("assets/external/sponza/Sponza.tecs.gltf");
        fs::create_dir_all(scene.parent().unwrap()).unwrap();
        fs::write(&scene, b"{}").unwrap();
        assert!(require_for_example(&root, "sponza3d").is_ok());

        let bistro = root.join("assets/external/bistro/Bistro.tecs.gltf");
        fs::create_dir_all(bistro.parent().unwrap()).unwrap();
        fs::write(&bistro, b"{}").unwrap();
        assert!(require_for_example(&root, "bistro3d").is_ok());
        fs::remove_dir_all(&root).unwrap();
    }

    #[cfg(feature = "bistro-import")]
    #[test]
    fn parses_a_glb_with_json_and_binary_chunks() {
        let json = br#"{}  "#;
        let binary = [1_u8, 2, 3, 4];
        let total = 12 + 8 + json.len() + 8 + binary.len();
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"glTF");
        bytes.extend_from_slice(&2_u32.to_le_bytes());
        bytes.extend_from_slice(&(total as u32).to_le_bytes());
        bytes.extend_from_slice(&(json.len() as u32).to_le_bytes());
        bytes.extend_from_slice(b"JSON");
        bytes.extend_from_slice(json);
        bytes.extend_from_slice(&(binary.len() as u32).to_le_bytes());
        bytes.extend_from_slice(b"BIN\0");
        bytes.extend_from_slice(&binary);

        let (parsed_json, parsed_binary) = super::parse_glb(&bytes).unwrap();
        assert_eq!(parsed_json, json);
        assert_eq!(parsed_binary, binary);
    }

    #[cfg(feature = "bistro-import")]
    #[test]
    fn promotes_a_secondary_uv_stream_when_it_is_the_only_one() {
        let mut document = serde_json::json!({
            "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "TEXCOORD_1": 1}}]}]
        });
        assert_eq!(super::promote_secondary_texcoords(&mut document), 1);
        let attributes = &document["meshes"][0]["primitives"][0]["attributes"];
        assert_eq!(attributes["TEXCOORD_0"], 1);
        assert!(attributes.get("TEXCOORD_1").is_none());
    }
}
