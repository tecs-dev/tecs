//! Whole-model glTF import behind one owner-safe C ABI.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::{fs, ptr, slice, str};

use glam::{Mat4, Quat, Vec3};
use gltf::animation::util::ReadOutputs;
use gltf::animation::Interpolation;
use gltf::mesh::Mode;
use gltf::scene::Transform;
use gltf::texture::{MagFilter, MinFilter, WrappingMode};

use crate::set_error;

const MAX_CHUNK_INDICES: usize = 65_536 * 3;
type Decomposed = ([f32; 3], [f32; 4], [f32; 3]);

#[repr(C)]
pub struct TecsModelMesh {
    pub name: *const u8,
    pub name_length: usize,
    pub vertices: *const f32,
    pub vertex_count: usize,
    pub color_vertices: *const f32,
    pub indices: *const u32,
    pub index_count: usize,
    pub skin_vertices: *const f32,
    pub morph_vertices: *const f32,
    pub morph_target_count: usize,
    pub morph_weights: *const f32,
    pub morph_weight_count: usize,
    pub center_x: f32,
    pub center_y: f32,
    pub center_z: f32,
    pub radius: f32,
}

#[repr(C)]
pub struct TecsModelImage {
    pub name: *const u8,
    pub name_length: usize,
    pub bytes: *const u8,
    pub byte_count: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TecsModelMaterial {
    pub name: *const u8,
    pub name_length: usize,
    pub model: u32,
    pub alpha_mode: u32,
    pub base_color_image: u32,
    pub normal_image: u32,
    pub metallic_roughness_image: u32,
    pub occlusion_image: u32,
    pub emissive_image: u32,
    pub alpha_cutoff: f32,
    pub base_r: f32,
    pub base_g: f32,
    pub base_b: f32,
    pub base_a: f32,
    pub emissive_r: f32,
    pub emissive_g: f32,
    pub emissive_b: f32,
    pub metallic: f32,
    pub roughness: f32,
    pub normal_scale: f32,
    pub occlusion_strength: f32,
    pub double_sided: u8,
    pub _padding: [u8; 3],
}

#[repr(C)]
pub struct TecsModelDraw {
    pub mesh: u32,
    pub material: u32,
    pub skin: u32,
    pub node: u32,
    pub weights: *const f32,
    pub weight_count: usize,
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub rotation_x: f32,
    pub rotation_y: f32,
    pub rotation_z: f32,
    pub rotation_w: f32,
    pub scale_x: f32,
    pub scale_y: f32,
    pub scale_z: f32,
}

#[repr(C)]
pub struct TecsModelSkin {
    pub name: *const u8,
    pub name_length: usize,
    pub matrices: *const f32,
    pub matrix_count: usize,
    pub node: u32,
    pub joints: *const u32,
    pub joint_count: usize,
    pub inverse_bind_matrices: *const f32,
    pub inverse_bind_matrix_count: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TecsModelNode {
    pub parent: u32,
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub rotation_x: f32,
    pub rotation_y: f32,
    pub rotation_z: f32,
    pub rotation_w: f32,
    pub scale_x: f32,
    pub scale_y: f32,
    pub scale_z: f32,
    pub has_matrix: u8,
    pub _padding: [u8; 3],
    pub matrix: [f32; 16],
}

#[repr(C)]
pub struct TecsModelAnimation {
    pub name: *const u8,
    pub name_length: usize,
    pub duration: f32,
    pub first_channel: usize,
    pub channel_count: usize,
}

#[repr(C)]
pub struct TecsModelAnimationChannel {
    pub node: u32,
    pub path: u32,
    pub interpolation: u32,
    pub width: u32,
    pub times: *const f32,
    pub time_count: usize,
    pub values: *const f32,
    pub value_count: usize,
}

#[repr(C)]
pub struct TecsModelInfo {
    pub path: *const u8,
    pub path_length: usize,
    pub mipmaps: u8,
    pub _padding: [u8; 7],
    pub meshes: *const TecsModelMesh,
    pub mesh_count: usize,
    pub images: *const TecsModelImage,
    pub image_count: usize,
    pub materials: *const TecsModelMaterial,
    pub material_count: usize,
    pub draws: *const TecsModelDraw,
    pub draw_count: usize,
    pub skins: *const TecsModelSkin,
    pub skin_count: usize,
    pub nodes: *const TecsModelNode,
    pub node_count: usize,
    pub animations: *const TecsModelAnimation,
    pub animation_count: usize,
    pub channels: *const TecsModelAnimationChannel,
    pub channel_count: usize,
}

struct MeshData {
    name: String,
    vertices: Vec<f32>,
    colors: Vec<f32>,
    indices: Vec<u32>,
    skin: Vec<f32>,
    morph: Vec<f32>,
    morph_weights: Vec<f32>,
    morph_target_count: usize,
    center: Vec3,
    radius: f32,
    material: u32,
    max_joint: i32,
}

struct ImageData {
    name: String,
    bytes: Vec<u8>,
}

struct MaterialData {
    name: String,
    view: TecsModelMaterial,
}

struct DrawData {
    weights: Vec<f32>,
    view: TecsModelDraw,
}

struct SkinData {
    name: String,
    matrices: Vec<f32>,
    joints: Vec<u32>,
    inverse_binds: Vec<f32>,
    node: u32,
}

struct ChannelData {
    times: Vec<f32>,
    values: Vec<f32>,
    node: u32,
    path: u32,
    interpolation: u32,
    width: u32,
}

struct AnimationData {
    name: String,
    duration: f32,
    first_channel: usize,
    channel_count: usize,
}

pub struct TecsModel {
    path: String,
    mipmaps: bool,
    mesh_data: Vec<MeshData>,
    image_data: Vec<ImageData>,
    material_data: Vec<MaterialData>,
    draw_data: Vec<DrawData>,
    skin_data: Vec<SkinData>,
    animation_data: Vec<AnimationData>,
    channel_data: Vec<ChannelData>,
    mesh_views: Vec<TecsModelMesh>,
    image_views: Vec<TecsModelImage>,
    material_views: Vec<TecsModelMaterial>,
    draw_views: Vec<TecsModelDraw>,
    skin_views: Vec<TecsModelSkin>,
    nodes: Vec<TecsModelNode>,
    animation_views: Vec<TecsModelAnimation>,
    channel_views: Vec<TecsModelAnimationChannel>,
}

fn maybe_ptr<T>(values: &[T]) -> *const T {
    if values.is_empty() {
        ptr::null()
    } else {
        values.as_ptr()
    }
}

fn finite(values: impl IntoIterator<Item = f32>, label: &str) -> Result<(), String> {
    if values.into_iter().all(f32::is_finite) {
        Ok(())
    } else {
        Err(format!("{label} contains a non-finite value"))
    }
}

fn normalized(value: Vec3, label: &str) -> Result<Vec3, String> {
    let length = value.length();
    if !length.is_finite() || length <= 1.0e-20 {
        Err(format!("{label} has zero length"))
    } else {
        Ok(value / length)
    }
}

fn generate_normals(positions: &[Vec3], indices: &[u32], name: &str) -> Result<Vec<Vec3>, String> {
    let mut normals = vec![Vec3::ZERO; positions.len()];
    for triangle in indices.chunks_exact(3) {
        let a = triangle[0] as usize;
        let b = triangle[1] as usize;
        let c = triangle[2] as usize;
        let normal = (positions[b] - positions[a]).cross(positions[c] - positions[a]);
        normals[a] += normal;
        normals[b] += normal;
        normals[c] += normal;
    }
    normals
        .into_iter()
        .map(|normal| normalized(normal, &format!("{name} generated normal")))
        .collect()
}

struct TangentGeometry<'a> {
    positions: &'a [Vec3],
    normals: &'a [Vec3],
    uvs: &'a [[f32; 2]],
    indices: &'a [u32],
    corners: Vec<Option<[f32; 4]>>,
}

impl TangentGeometry<'_> {
    fn source(&self, face: usize, vertex: usize) -> usize {
        self.indices[face * 3 + vertex] as usize
    }
}

impl bevy_mikktspace::Geometry for TangentGeometry<'_> {
    fn num_faces(&self) -> usize {
        self.indices.len() / 3
    }

    fn num_vertices_of_face(&self, _face: usize) -> usize {
        3
    }

    fn position(&self, face: usize, vertex: usize) -> [f32; 3] {
        self.positions[self.source(face, vertex)].to_array()
    }

    fn normal(&self, face: usize, vertex: usize) -> [f32; 3] {
        self.normals[self.source(face, vertex)].to_array()
    }

    fn tex_coord(&self, face: usize, vertex: usize) -> [f32; 2] {
        self.uvs[self.source(face, vertex)]
    }

    fn set_tangent(
        &mut self,
        tangent: Option<bevy_mikktspace::TangentSpace>,
        face: usize,
        vertex: usize,
    ) {
        self.corners[face * 3 + vertex] = tangent.map(|value| value.tangent_encoded());
    }
}

fn orthogonal_tangent(normal: Vec3) -> [f32; 4] {
    let tangent = if normal.x.abs() < 0.9 {
        Vec3::new(0.0, normal.z, -normal.y).normalize()
    } else {
        Vec3::new(-normal.y, normal.x, 0.0).normalize()
    };
    [tangent.x, tangent.y, tangent.z, 1.0]
}

fn generate_tangent_corners(
    positions: &[Vec3],
    normals: &[Vec3],
    uvs: &[[f32; 2]],
    indices: &[u32],
) -> Result<Vec<[f32; 4]>, String> {
    let mut geometry = TangentGeometry {
        positions,
        normals,
        uvs,
        indices,
        corners: vec![None; indices.len()],
    };
    bevy_mikktspace::generate_tangents(&mut geometry)
        .map_err(|error| format!("MikkTSpace tangent generation failed: {error}"))?;
    Ok(geometry
        .corners
        .into_iter()
        .enumerate()
        .map(|(corner, tangent)| {
            tangent.unwrap_or_else(|| orthogonal_tangent(normals[indices[corner] as usize]))
        })
        .collect())
}

struct TangentRemap {
    source_vertices: Vec<usize>,
    tangents: Vec<[f32; 4]>,
    indices: Vec<u32>,
}

fn remap_tangent_corners(indices: &[u32], corners: &[[f32; 4]]) -> TangentRemap {
    let mut remap = HashMap::new();
    let mut source_vertices = Vec::new();
    let mut tangents = Vec::new();
    let mut remapped_indices = Vec::with_capacity(indices.len());
    for (&source, tangent) in indices.iter().zip(corners) {
        let key = (
            source,
            tangent.map(|value| if value == 0.0 { 0 } else { value.to_bits() }),
        );
        let next = source_vertices.len() as u32;
        let index = *remap.entry(key).or_insert_with(|| {
            source_vertices.push(source as usize);
            tangents.push(*tangent);
            next
        });
        remapped_indices.push(index);
    }
    TangentRemap {
        source_vertices,
        tangents,
        indices: remapped_indices,
    }
}

fn decode_primitive(
    primitive: &gltf::Primitive<'_>,
    buffers: &[gltf::buffer::Data],
    name: String,
    default_weights: &[f32],
) -> Result<MeshData, String> {
    if primitive.mode() != Mode::Triangles {
        return Err(format!("{name} is not a triangle primitive"));
    }
    let reader = primitive.reader(|buffer| Some(buffers[buffer.index()].0.as_slice()));
    let positions: Vec<Vec3> = reader
        .read_positions()
        .ok_or_else(|| format!("{name} has no POSITION attribute"))?
        .map(Vec3::from_array)
        .collect();
    if positions.is_empty() {
        return Err(format!("{name} has no vertices"));
    }
    finite(
        positions.iter().flat_map(|value| value.to_array()),
        &format!("{name} POSITION"),
    )?;
    let indices: Vec<u32> = reader
        .read_indices()
        .map(|values| values.into_u32().collect())
        .unwrap_or_else(|| (0..positions.len() as u32).collect());
    if indices.is_empty() || !indices.len().is_multiple_of(3) {
        return Err(format!("{name} has a non-triangle index count"));
    }
    if let Some((offset, value)) = indices
        .iter()
        .enumerate()
        .find(|(_, value)| **value as usize >= positions.len())
    {
        return Err(format!(
            "{name} index {offset} ({value}) is outside its vertex range"
        ));
    }

    let normals = match reader.read_normals() {
        Some(values) => {
            let values: Vec<Vec3> = values.map(Vec3::from_array).collect();
            if values.len() != positions.len() {
                return Err(format!("{name} NORMAL count does not match POSITION"));
            }
            values
                .into_iter()
                .map(|value| normalized(value, &format!("{name} NORMAL")))
                .collect::<Result<Vec<_>, _>>()?
        }
        None => generate_normals(&positions, &indices, &name)?,
    };
    let uvs: Vec<[f32; 2]> = reader
        .read_tex_coords(0)
        .map(|values| values.into_f32().collect())
        .unwrap_or_else(|| vec![[0.0, 0.0]; positions.len()]);
    if uvs.len() != positions.len() {
        return Err(format!("{name} TEXCOORD_0 count does not match POSITION"));
    }
    finite(
        uvs.iter().flat_map(|value| *value),
        &format!("{name} TEXCOORD_0"),
    )?;
    let source_vertex_count = positions.len();
    let has_uvs = primitive.get(&gltf::Semantic::TexCoords(0)).is_some();
    let authored_tangents = reader
        .read_tangents()
        .map(Iterator::collect::<Vec<[f32; 4]>>);
    if authored_tangents
        .as_ref()
        .is_some_and(|values| values.len() != source_vertex_count)
    {
        return Err(format!("{name} TANGENT count does not match POSITION"));
    }
    let (positions, normals, uvs, tangents, indices, source_vertices) =
        if let Some(tangents) = authored_tangents {
            (
                positions,
                normals,
                uvs,
                tangents,
                indices,
                (0..source_vertex_count).collect::<Vec<_>>(),
            )
        } else if has_uvs {
            let corners = generate_tangent_corners(&positions, &normals, &uvs, &indices)
                .map_err(|error| format!("{name} {error}"))?;
            let remapped = remap_tangent_corners(&indices, &corners);
            (
                remapped
                    .source_vertices
                    .iter()
                    .map(|&source| positions[source])
                    .collect(),
                remapped
                    .source_vertices
                    .iter()
                    .map(|&source| normals[source])
                    .collect(),
                remapped
                    .source_vertices
                    .iter()
                    .map(|&source| uvs[source])
                    .collect(),
                remapped.tangents,
                remapped.indices,
                remapped.source_vertices,
            )
        } else {
            let tangents = normals
                .iter()
                .map(|normal| orthogonal_tangent(*normal))
                .collect();
            (
                positions,
                normals,
                uvs,
                tangents,
                indices,
                (0..source_vertex_count).collect::<Vec<_>>(),
            )
        };
    finite(
        tangents.iter().flat_map(|value| *value),
        &format!("{name} TANGENT"),
    )?;

    let source_colors: Vec<[f32; 4]> = match reader.read_colors(0) {
        Some(values) => values.into_rgba_f32().collect(),
        None => Vec::new(),
    };
    if !source_colors.is_empty() && source_colors.len() != source_vertex_count {
        return Err(format!("{name} COLOR_0 count does not match POSITION"));
    }
    let colors: Vec<f32> = if source_colors.is_empty() {
        Vec::new()
    } else {
        source_vertices
            .iter()
            .flat_map(|&source| source_colors[source])
            .collect()
    };
    finite(colors.iter().copied(), &format!("{name} COLOR_0"))?;

    let joints = reader
        .read_joints(0)
        .map(|values| values.into_u16().collect::<Vec<_>>());
    let weights = reader
        .read_weights(0)
        .map(|values| values.into_f32().collect::<Vec<_>>());
    if joints.is_some() != weights.is_some() {
        return Err(format!(
            "{name} must supply JOINTS_0 and WEIGHTS_0 together"
        ));
    }
    let mut skin = Vec::new();
    let mut max_joint = -1;
    if let (Some(joints), Some(weights)) = (joints, weights) {
        if joints.len() != source_vertex_count || weights.len() != source_vertex_count {
            return Err(format!(
                "{name} skin attribute count does not match POSITION"
            ));
        }
        let mut source_skin = Vec::with_capacity(source_vertex_count);
        for (vertex, (joints, weights)) in joints.into_iter().zip(weights).enumerate() {
            let total: f32 = weights.iter().sum();
            if !total.is_finite() || total <= 1.0e-20 || weights.iter().any(|weight| *weight < 0.0)
            {
                return Err(format!(
                    "{name} has invalid joint weights at vertex {vertex}"
                ));
            }
            let joints = joints.map(|joint| {
                max_joint = max_joint.max(i32::from(joint));
                f32::from(joint)
            });
            let weights = weights.map(|weight| weight / total);
            source_skin.push([
                joints[0], joints[1], joints[2], joints[3], weights[0], weights[1], weights[2],
                weights[3],
            ]);
        }
        skin.reserve(positions.len() * 8);
        for &source in &source_vertices {
            skin.extend(source_skin[source]);
        }
    }

    let morph_targets: Vec<_> = reader.read_morph_targets().collect();
    if !default_weights.is_empty() && default_weights.len() != morph_targets.len() {
        return Err(format!(
            "{name} mesh weights do not match its morph targets"
        ));
    }
    let mut morph = Vec::with_capacity(positions.len() * morph_targets.len() * 9);
    let mut morph_radius = 0.0f32;
    let mut decoded_targets = Vec::new();
    for (target, (position_values, normal_values, tangent_values)) in
        morph_targets.into_iter().enumerate()
    {
        let positions_delta = position_values.map(Iterator::collect::<Vec<_>>);
        let normals_delta = normal_values.map(Iterator::collect::<Vec<_>>);
        let tangents_delta = tangent_values.map(Iterator::collect::<Vec<_>>);
        if positions_delta.is_none() && normals_delta.is_none() && tangents_delta.is_none() {
            return Err(format!("{name} morph target {target} is empty"));
        }
        for (label, length) in [
            ("POSITION", positions_delta.as_ref().map(Vec::len)),
            ("NORMAL", normals_delta.as_ref().map(Vec::len)),
            ("TANGENT", tangents_delta.as_ref().map(Vec::len)),
        ] {
            if let Some(length) = length {
                if length != source_vertex_count {
                    return Err(format!(
                        "{name} morph {label} count does not match POSITION"
                    ));
                }
            }
        }
        decoded_targets.push((positions_delta, normals_delta, tangents_delta));
    }
    for target in &decoded_targets {
        for &source in &source_vertices {
            let position = target.0.as_ref().map_or([0.0; 3], |values| values[source]);
            let normal = target.1.as_ref().map_or([0.0; 3], |values| values[source]);
            let tangent = target.2.as_ref().map_or([0.0; 3], |values| values[source]);
            morph.extend(position);
            morph.extend(normal);
            morph.extend(tangent);
        }
    }
    for &source in &source_vertices {
        let displacement: f32 = decoded_targets
            .iter()
            .map(|target| {
                target
                    .0
                    .as_ref()
                    .map_or(Vec3::ZERO, |values| Vec3::from_array(values[source]))
                    .length()
            })
            .sum();
        morph_radius = morph_radius.max(displacement);
    }
    finite(morph.iter().copied(), &format!("{name} morph target"))?;

    let mut vertices = Vec::with_capacity(positions.len() * 12);
    for index in 0..positions.len() {
        vertices.extend(positions[index].to_array());
        vertices.extend(normals[index].to_array());
        vertices.extend(tangents[index]);
        vertices.extend(uvs[index]);
    }
    let mut minimum = positions[0];
    let mut maximum = positions[0];
    for position in &positions[1..] {
        minimum = minimum.min(*position);
        maximum = maximum.max(*position);
    }
    let center = (minimum + maximum) * 0.5;
    let radius = positions
        .iter()
        .map(|position| position.distance_squared(center))
        .fold(0.0f32, f32::max)
        .sqrt()
        + morph_radius;
    Ok(MeshData {
        name,
        vertices,
        colors,
        indices,
        skin,
        morph,
        morph_weights: default_weights.to_vec(),
        morph_target_count: decoded_targets.len(),
        center,
        radius,
        material: primitive
            .material()
            .index()
            .map_or(0, |index| index as u32 + 1),
        max_joint,
    })
}

fn split_mesh(source: MeshData) -> Vec<MeshData> {
    split_mesh_at(source, MAX_CHUNK_INDICES)
}

fn split_mesh_at(source: MeshData, maximum_indices: usize) -> Vec<MeshData> {
    if source.indices.len() <= maximum_indices {
        return vec![source];
    }
    let mut chunks = Vec::new();
    for (chunk_index, source_indices) in source.indices.chunks(maximum_indices).enumerate() {
        let mut remap = HashMap::new();
        let mut source_vertices = Vec::new();
        let mut indices = Vec::with_capacity(source_indices.len());
        for &source_index in source_indices {
            let next = source_vertices.len() as u32;
            let mapped = *remap.entry(source_index).or_insert_with(|| {
                source_vertices.push(source_index as usize);
                next
            });
            indices.push(mapped);
        }
        let mut vertices = Vec::with_capacity(source_vertices.len() * 12);
        let mut colors = Vec::with_capacity(source_vertices.len() * 4);
        let mut skin = Vec::with_capacity(source_vertices.len() * 8);
        for &vertex in &source_vertices {
            vertices.extend_from_slice(&source.vertices[vertex * 12..vertex * 12 + 12]);
            if !source.colors.is_empty() {
                colors.extend_from_slice(&source.colors[vertex * 4..vertex * 4 + 4]);
            }
            if !source.skin.is_empty() {
                skin.extend_from_slice(&source.skin[vertex * 8..vertex * 8 + 8]);
            }
        }
        let mut morph = Vec::with_capacity(source_vertices.len() * source.morph_target_count * 9);
        for target in 0..source.morph_target_count {
            for &vertex in &source_vertices {
                let at = (target * (source.vertices.len() / 12) + vertex) * 9;
                morph.extend_from_slice(&source.morph[at..at + 9]);
            }
        }
        let positions: Vec<Vec3> = vertices
            .chunks_exact(12)
            .map(|row| Vec3::new(row[0], row[1], row[2]))
            .collect();
        let mut minimum = positions[0];
        let mut maximum = positions[0];
        for position in &positions[1..] {
            minimum = minimum.min(*position);
            maximum = maximum.max(*position);
        }
        let center = (minimum + maximum) * 0.5;
        let mut morph_radius = 0.0f32;
        for vertex in 0..positions.len() {
            let mut displacement = 0.0;
            for target in 0..source.morph_target_count {
                let at = (target * positions.len() + vertex) * 9;
                displacement += Vec3::new(morph[at], morph[at + 1], morph[at + 2]).length();
            }
            morph_radius = morph_radius.max(displacement);
        }
        let radius = positions
            .iter()
            .map(|position| position.distance_squared(center))
            .fold(0.0f32, f32::max)
            .sqrt()
            + morph_radius;
        chunks.push(MeshData {
            name: format!("{}#chunk-{chunk_index}", source.name),
            vertices,
            colors,
            indices,
            skin,
            morph,
            morph_weights: source.morph_weights.clone(),
            morph_target_count: source.morph_target_count,
            center,
            radius,
            material: source.material,
            max_joint: source.max_joint,
        });
    }
    chunks
}

fn remap_float_stream<const WIDTH: usize>(
    values: &[f32],
    vertex_count: usize,
    remap: &[u32],
) -> Vec<f32>
where
    [f32; WIDTH]: Default + bytemuck::Pod,
{
    let rows: &[[f32; WIDTH]] = bytemuck::cast_slice(values);
    let remapped: Vec<[f32; WIDTH]> = meshopt::remap_vertex_buffer(rows, vertex_count, remap);
    bytemuck::cast_vec(remapped)
}

fn remap_mesh_vertices(mesh: &mut MeshData, vertex_count: usize, remap: &[u32]) {
    mesh.vertices = remap_float_stream::<12>(&mesh.vertices, vertex_count, remap);
    if !mesh.colors.is_empty() {
        mesh.colors = remap_float_stream::<4>(&mesh.colors, vertex_count, remap);
    }
    if !mesh.skin.is_empty() {
        mesh.skin = remap_float_stream::<8>(&mesh.skin, vertex_count, remap);
    }
    if !mesh.morph.is_empty() {
        let source = std::mem::take(&mut mesh.morph);
        let target_width = remap.len() * 9;
        mesh.morph = Vec::with_capacity(vertex_count * mesh.morph_target_count * 9);
        for target in source.chunks_exact(target_width) {
            mesh.morph
                .extend(remap_float_stream::<9>(target, vertex_count, remap));
        }
    }
}

fn optimize_mesh(mesh: &mut MeshData, preserve_triangle_order: bool) {
    let vertex_count = mesh.vertices.len() / 12;
    if !preserve_triangle_order {
        mesh.indices = meshopt::optimize_vertex_cache(&mesh.indices, vertex_count);
    }
    let remap = meshopt::optimize_vertex_fetch_remap(&mesh.indices, vertex_count);
    debug_assert_eq!(remap.len(), vertex_count);
    mesh.indices = meshopt::remap_index_buffer(Some(&mesh.indices), vertex_count, &remap);
    remap_mesh_vertices(mesh, remap.len(), &remap);
}

fn node_local(node: &gltf::Node<'_>) -> Mat4 {
    match node.transform() {
        Transform::Matrix { matrix } => Mat4::from_cols_array_2d(&matrix),
        Transform::Decomposed {
            translation,
            rotation,
            scale,
        } => Mat4::from_scale_rotation_translation(
            Vec3::from_array(scale),
            Quat::from_array(rotation).normalize(),
            Vec3::from_array(translation),
        ),
    }
}

fn decompose(matrix: Mat4, label: &str) -> Result<Decomposed, String> {
    if !matrix.is_finite() {
        return Err(format!("{label} contains a non-finite transform"));
    }
    let (scale, rotation, translation) = matrix.to_scale_rotation_translation();
    if scale.abs().min_element() <= 1.0e-20 || !rotation.is_finite() {
        return Err(format!("{label} is not a finite invertible TRS transform"));
    }
    let rebuilt = Mat4::from_scale_rotation_translation(scale, rotation, translation);
    let error = matrix
        .to_cols_array()
        .into_iter()
        .zip(rebuilt.to_cols_array())
        .map(|(a, b)| (a - b).abs())
        .fold(0.0, f32::max);
    if error > 1.0e-4 {
        return Err(format!("{label} produces shear"));
    }
    Ok((
        translation.to_array(),
        rotation.normalize().to_array(),
        scale.to_array(),
    ))
}

fn texture_image(info: Option<gltf::texture::Info<'_>>, label: &str) -> Result<u32, String> {
    let Some(info) = info else { return Ok(0) };
    if info.tex_coord() != 0 {
        return Err(format!("{label} supports only TEXCOORD_0"));
    }
    if info.texture_transform().is_some() {
        return Err(format!("{label} does not support KHR_texture_transform"));
    }
    Ok(info.texture().source().index() as u32 + 1)
}

fn read_uri(base: &Path, uri: &str) -> Result<Vec<u8>, String> {
    if uri.starts_with("data:") {
        let data = data_url::DataUrl::process(uri).map_err(|error| error.to_string())?;
        return data
            .decode_to_vec()
            .map(|value| value.0)
            .map_err(|error| error.to_string());
    }
    if uri.contains(':') {
        return Err(format!("unsupported glTF URI scheme in '{uri}'"));
    }
    let decoded = urlencoding::decode(uri).map_err(|error| error.to_string())?;
    fs::read(base.join(decoded.as_ref())).map_err(|error| error.to_string())
}

fn build_views(model: &mut TecsModel) {
    model.mesh_views = model
        .mesh_data
        .iter()
        .map(|mesh| TecsModelMesh {
            name: mesh.name.as_ptr(),
            name_length: mesh.name.len(),
            vertices: maybe_ptr(&mesh.vertices),
            vertex_count: mesh.vertices.len() / 12,
            color_vertices: maybe_ptr(&mesh.colors),
            indices: maybe_ptr(&mesh.indices),
            index_count: mesh.indices.len(),
            skin_vertices: maybe_ptr(&mesh.skin),
            morph_vertices: maybe_ptr(&mesh.morph),
            morph_target_count: mesh.morph_target_count,
            morph_weights: maybe_ptr(&mesh.morph_weights),
            morph_weight_count: mesh.morph_weights.len(),
            center_x: mesh.center.x,
            center_y: mesh.center.y,
            center_z: mesh.center.z,
            radius: mesh.radius,
        })
        .collect();
    model.image_views = model
        .image_data
        .iter()
        .map(|image| TecsModelImage {
            name: image.name.as_ptr(),
            name_length: image.name.len(),
            bytes: maybe_ptr(&image.bytes),
            byte_count: image.bytes.len(),
        })
        .collect();
    model.material_views = model
        .material_data
        .iter_mut()
        .map(|material| {
            material.view.name = material.name.as_ptr();
            material.view.name_length = material.name.len();
            material.view
        })
        .collect();
    model.draw_views = model
        .draw_data
        .iter_mut()
        .map(|draw| {
            draw.view.weights = maybe_ptr(&draw.weights);
            draw.view.weight_count = draw.weights.len();
            TecsModelDraw { ..draw.view }
        })
        .collect();
    model.skin_views = model
        .skin_data
        .iter()
        .map(|skin| TecsModelSkin {
            name: skin.name.as_ptr(),
            name_length: skin.name.len(),
            matrices: maybe_ptr(&skin.matrices),
            matrix_count: skin.matrices.len(),
            node: skin.node,
            joints: maybe_ptr(&skin.joints),
            joint_count: skin.joints.len(),
            inverse_bind_matrices: maybe_ptr(&skin.inverse_binds),
            inverse_bind_matrix_count: skin.inverse_binds.len(),
        })
        .collect();
    model.animation_views = model
        .animation_data
        .iter()
        .map(|animation| TecsModelAnimation {
            name: animation.name.as_ptr(),
            name_length: animation.name.len(),
            duration: animation.duration,
            first_channel: animation.first_channel,
            channel_count: animation.channel_count,
        })
        .collect();
    model.channel_views = model
        .channel_data
        .iter()
        .map(|channel| TecsModelAnimationChannel {
            node: channel.node,
            path: channel.path,
            interpolation: channel.interpolation,
            width: channel.width,
            times: maybe_ptr(&channel.times),
            time_count: channel.times.len(),
            values: maybe_ptr(&channel.values),
            value_count: channel.values.len(),
        })
        .collect();
}

fn import_with_geometry_optimization(
    path: &Path,
    optimize_geometry: bool,
) -> Result<TecsModel, String> {
    let path_text = path.to_string_lossy().into_owned();
    let gltf =
        gltf::Gltf::open(path).map_err(|error| format!("cannot decode {path_text}: {error}"))?;
    for extension in gltf.document.extensions_required() {
        if extension != "KHR_materials_unlit" {
            return Err(format!(
                "{path_text} requires unsupported extension {extension}"
            ));
        }
    }
    let base = path.parent().unwrap_or_else(|| Path::new("."));
    let buffers = gltf::import_buffers(&gltf.document, Some(base), gltf.blob)
        .map_err(|error| format!("cannot load {path_text} buffers: {error}"))?;

    let mut mipmaps = None;
    for texture in gltf.document.textures() {
        let sampler = texture.sampler();
        if sampler.wrap_s() != WrappingMode::Repeat || sampler.wrap_t() != WrappingMode::Repeat {
            return Err(format!(
                "{path_text} texture {} needs an unsupported sampler",
                texture.index()
            ));
        }
        if let Some(filter) = sampler.mag_filter() {
            if filter != MagFilter::Linear {
                return Err(format!(
                    "{path_text} texture {} needs an unsupported sampler",
                    texture.index()
                ));
            }
        }
        if let Some(filter) = sampler.min_filter() {
            let requested = match filter {
                MinFilter::Linear => false,
                MinFilter::LinearMipmapLinear => true,
                _ => {
                    return Err(format!(
                        "{path_text} texture {} needs an unsupported sampler",
                        texture.index()
                    ))
                }
            };
            if mipmaps.is_some_and(|existing| existing != requested) {
                return Err(format!(
                    "{path_text} mixes mipmapped and non-mipmapped texture samplers"
                ));
            }
            mipmaps = Some(requested);
        }
    }

    let mut image_data = Vec::new();
    for image in gltf.document.images() {
        let bytes = match image.source() {
            gltf::image::Source::View { view, .. } => {
                let data = &buffers[view.buffer().index()].0;
                data.get(view.offset()..view.offset() + view.length())
                    .ok_or_else(|| {
                        format!("{path_text} image {} is outside its buffer", image.index())
                    })?
                    .to_vec()
            }
            gltf::image::Source::Uri { uri, .. } => read_uri(base, uri).map_err(|error| {
                format!("cannot load {path_text} image {}: {error}", image.index())
            })?,
        };
        image_data.push(ImageData {
            name: format!("{path_text}#image-{}", image.index()),
            bytes,
        });
    }

    let mut material_data = Vec::new();
    for material in gltf.document.materials() {
        let index = material.index().unwrap_or(material_data.len());
        let label = format!("{path_text} material {index}");
        let pbr = material.pbr_metallic_roughness();
        let base = pbr.base_color_factor();
        let emissive = material.emissive_factor();
        let normal = material.normal_texture();
        let occlusion = material.occlusion_texture();
        if normal.as_ref().is_some_and(|value| value.tex_coord() != 0)
            || occlusion
                .as_ref()
                .is_some_and(|value| value.tex_coord() != 0)
        {
            return Err(format!("{label} supports only TEXCOORD_0"));
        }
        if normal
            .as_ref()
            .and_then(|value| value.extension_value("KHR_texture_transform"))
            .is_some()
            || occlusion
                .as_ref()
                .and_then(|value| value.extension_value("KHR_texture_transform"))
                .is_some()
        {
            return Err(format!("{label} does not support KHR_texture_transform"));
        }
        material_data.push(MaterialData {
            name: format!(
                "{path_text}#material-{index}{}",
                material
                    .name()
                    .map_or(String::new(), |name| format!(":{name}"))
            ),
            view: TecsModelMaterial {
                name: ptr::null(),
                name_length: 0,
                model: u32::from(material.unlit()),
                alpha_mode: match material.alpha_mode() {
                    gltf::material::AlphaMode::Opaque => 0,
                    gltf::material::AlphaMode::Mask => 1,
                    gltf::material::AlphaMode::Blend => 2,
                },
                base_color_image: texture_image(pbr.base_color_texture(), &label)?,
                normal_image: normal
                    .as_ref()
                    .map_or(0, |value| value.texture().source().index() as u32 + 1),
                metallic_roughness_image: texture_image(pbr.metallic_roughness_texture(), &label)?,
                occlusion_image: occlusion
                    .as_ref()
                    .map_or(0, |value| value.texture().source().index() as u32 + 1),
                emissive_image: texture_image(material.emissive_texture(), &label)?,
                alpha_cutoff: material.alpha_cutoff().unwrap_or(0.0),
                base_r: base[0],
                base_g: base[1],
                base_b: base[2],
                base_a: base[3],
                emissive_r: emissive[0],
                emissive_g: emissive[1],
                emissive_b: emissive[2],
                metallic: pbr.metallic_factor(),
                roughness: pbr.roughness_factor(),
                normal_scale: normal.map_or(1.0, |value| value.scale()),
                occlusion_strength: occlusion.map_or(1.0, |value| value.strength()),
                double_sided: u8::from(material.double_sided()),
                _padding: [0; 3],
            },
        });
    }

    let mut mesh_data = Vec::new();
    let mut by_mesh = vec![Vec::new(); gltf.document.meshes().len()];
    let mut weights_by_mesh = vec![Vec::new(); by_mesh.len()];
    for mesh in gltf.document.meshes() {
        let weights = mesh.weights().unwrap_or(&[]).to_vec();
        finite(
            weights.iter().copied(),
            &format!("{path_text} mesh {} weights", mesh.index()),
        )?;
        weights_by_mesh[mesh.index()] = weights.clone();
        for primitive in mesh.primitives() {
            let name = format!(
                "{path_text}#mesh-{}-primitive-{}",
                mesh.index(),
                primitive.index()
            );
            let preserve_triangle_order =
                primitive.material().alpha_mode() == gltf::material::AlphaMode::Blend;
            for mut chunk in split_mesh(decode_primitive(&primitive, &buffers, name, &weights)?) {
                if optimize_geometry {
                    optimize_mesh(&mut chunk, preserve_triangle_order);
                }
                mesh_data.push(chunk);
                by_mesh[mesh.index()].push(mesh_data.len() as u32);
            }
        }
    }

    let node_count = gltf.document.nodes().len();
    let mut parents = vec![None; node_count];
    for node in gltf.document.nodes() {
        for child in node.children() {
            if parents[child.index()].replace(node.index()).is_some() {
                return Err(format!(
                    "{path_text} node {} has more than one parent",
                    child.index()
                ));
            }
        }
    }
    let mut nodes = Vec::with_capacity(node_count);
    let mut locals = Vec::with_capacity(node_count);
    for node in gltf.document.nodes() {
        let transform = node.transform();
        let (translation, rotation, scale) = transform.clone().decomposed();
        let rotation = Quat::from_array(rotation).normalize();
        if !rotation.is_finite() {
            return Err(format!(
                "{path_text} node {} has an invalid rotation",
                node.index()
            ));
        }
        let (has_matrix, matrix) = match transform {
            Transform::Matrix { matrix } => (1, Mat4::from_cols_array_2d(&matrix).to_cols_array()),
            Transform::Decomposed { .. } => (0, [0.0; 16]),
        };
        nodes.push(TecsModelNode {
            parent: parents[node.index()].map_or(0, |parent| parent as u32 + 1),
            x: translation[0],
            y: translation[1],
            z: translation[2],
            rotation_x: rotation.x,
            rotation_y: rotation.y,
            rotation_z: rotation.z,
            rotation_w: rotation.w,
            scale_x: scale[0],
            scale_y: scale[1],
            scale_z: scale[2],
            has_matrix,
            _padding: [0; 3],
            matrix,
        });
        locals.push(node_local(&node));
    }
    let mut worlds = vec![None; node_count];
    fn world_of(
        index: usize,
        parents: &[Option<usize>],
        locals: &[Mat4],
        worlds: &mut [Option<Mat4>],
        active: &mut [bool],
    ) -> Result<Mat4, String> {
        if let Some(world) = worlds[index] {
            return Ok(world);
        }
        if active[index] {
            return Err("glTF node hierarchy contains a cycle".to_owned());
        }
        active[index] = true;
        let parent_world = match parents[index] {
            Some(parent) => world_of(parent, parents, locals, worlds, active)?,
            None => Mat4::IDENTITY,
        };
        let world = parent_world * locals[index];
        active[index] = false;
        worlds[index] = Some(world);
        Ok(world)
    }
    let mut active = vec![false; node_count];
    for index in 0..node_count {
        world_of(index, &parents, &locals, &mut worlds, &mut active)
            .map_err(|error| format!("{path_text}: {error}"))?;
    }
    let worlds: Vec<Mat4> = worlds.into_iter().map(Option::unwrap).collect();

    let mut channel_data = Vec::new();
    let mut animation_data = Vec::new();
    for animation in gltf.document.animations() {
        let first_channel = channel_data.len();
        let mut duration = 0.0f32;
        for channel in animation.channels() {
            let reader = channel.reader(|buffer| Some(buffers[buffer.index()].0.as_slice()));
            let times: Vec<f32> = reader
                .read_inputs()
                .ok_or_else(|| format!("{path_text} animation {} has no input", animation.index()))?
                .collect();
            if times.is_empty()
                || times
                    .windows(2)
                    .any(|pair| !pair[0].is_finite() || pair[1] <= pair[0])
            {
                return Err(format!(
                    "{path_text} animation {} has invalid key times",
                    animation.index()
                ));
            }
            duration = duration.max(*times.last().unwrap());
            let (path, width, values) = match reader.read_outputs().ok_or_else(|| {
                format!("{path_text} animation {} has no output", animation.index())
            })? {
                ReadOutputs::Translations(values) => (0, 3, values.flatten().collect::<Vec<_>>()),
                ReadOutputs::Rotations(values) => {
                    (1, 4, values.into_f32().flatten().collect::<Vec<_>>())
                }
                ReadOutputs::Scales(values) => (2, 3, values.flatten().collect::<Vec<_>>()),
                ReadOutputs::MorphTargetWeights(values) => {
                    let node = channel.target().node();
                    let width = node
                        .mesh()
                        .map(|mesh| {
                            mesh.primitives()
                                .next()
                                .map(|primitive| primitive.morph_targets().len())
                                .unwrap_or(0)
                        })
                        .unwrap_or(0);
                    if width == 0 {
                        return Err(format!("{path_text} animation {} targets weights on a node without morph targets", animation.index()));
                    }
                    (3, width as u32, values.into_f32().collect::<Vec<_>>())
                }
            };
            finite(
                values.iter().copied(),
                &format!("{path_text} animation {} output", animation.index()),
            )?;
            let rows = times.len()
                * if channel.sampler().interpolation() == Interpolation::CubicSpline {
                    3
                } else {
                    1
                };
            if values.len() != rows * width as usize {
                return Err(format!(
                    "{path_text} animation {} output size does not match its keys",
                    animation.index()
                ));
            }
            channel_data.push(ChannelData {
                times,
                values,
                node: channel.target().node().index() as u32 + 1,
                path,
                interpolation: match channel.sampler().interpolation() {
                    Interpolation::Linear => 0,
                    Interpolation::Step => 1,
                    Interpolation::CubicSpline => 2,
                },
                width,
            });
        }
        if channel_data.len() == first_channel {
            return Err(format!(
                "{path_text} animation {} has no channels",
                animation.index()
            ));
        }
        animation_data.push(AnimationData {
            name: animation
                .name()
                .map_or_else(|| format!("animation-{}", animation.index()), str::to_owned),
            duration,
            first_channel,
            channel_count: channel_data.len() - first_channel,
        });
    }

    let mut skin_data = Vec::new();
    let mut skin_by_node = HashMap::new();
    let mut draw_data = Vec::new();
    struct SceneBuilder<'a> {
        path: &'a str,
        buffers: &'a [gltf::buffer::Data],
        worlds: &'a [Mat4],
        by_mesh: &'a [Vec<u32>],
        weights_by_mesh: &'a [Vec<f32>],
        meshes: &'a [MeshData],
        skins: &'a mut Vec<SkinData>,
        skin_by_node: &'a mut HashMap<usize, u32>,
        draws: &'a mut Vec<DrawData>,
        visiting: &'a mut [bool],
    }
    impl SceneBuilder<'_> {
        fn visit(&mut self, node: gltf::Node<'_>) -> Result<(), String> {
            if self.visiting[node.index()] {
                return Err(format!("{} has a cycle in its scene hierarchy", self.path));
            }
            self.visiting[node.index()] = true;
            if let Some(mesh) = node.mesh() {
                let skin = if let Some(source) = node.skin() {
                    if let Some(&existing) = self.skin_by_node.get(&node.index()) {
                        existing
                    } else {
                        let joints: Vec<_> = source.joints().map(|joint| joint.index()).collect();
                        if joints.is_empty() {
                            return Err(format!(
                                "{} skin {} has no joints",
                                self.path,
                                source.index()
                            ));
                        }
                        let inverse_binds: Vec<Mat4> = source
                            .reader(|buffer| Some(self.buffers[buffer.index()].0.as_slice()))
                            .read_inverse_bind_matrices()
                            .map(|values| {
                                values
                                    .map(|value| Mat4::from_cols_array_2d(&value))
                                    .collect()
                            })
                            .unwrap_or_else(|| vec![Mat4::IDENTITY; joints.len()]);
                        if inverse_binds.len() != joints.len() {
                            return Err(format!(
                                "{} skin {} inverse bind count differs from its joints",
                                self.path,
                                source.index()
                            ));
                        }
                        let inverse_mesh = self.worlds[node.index()].inverse();
                        if !inverse_mesh.is_finite() {
                            return Err(format!(
                                "{} node {} has a non-invertible skin transform",
                                self.path,
                                node.index()
                            ));
                        }
                        let mut matrices = Vec::with_capacity(joints.len() * 16);
                        let mut inverse_bind_values = Vec::with_capacity(joints.len() * 16);
                        for (&joint, inverse_bind) in joints.iter().zip(&inverse_binds) {
                            matrices.extend(
                                (inverse_mesh * self.worlds[joint] * *inverse_bind).to_cols_array(),
                            );
                            inverse_bind_values.extend(inverse_bind.to_cols_array());
                        }
                        self.skins.push(SkinData {
                            name: format!(
                                "{}#skin-{}-node-{}",
                                self.path,
                                source.index(),
                                node.index()
                            ),
                            matrices,
                            joints: joints.iter().map(|index| *index as u32 + 1).collect(),
                            inverse_binds: inverse_bind_values,
                            node: node.index() as u32 + 1,
                        });
                        let created = self.skins.len() as u32;
                        self.skin_by_node.insert(node.index(), created);
                        created
                    }
                } else {
                    0
                };
                let source_weights = node
                    .weights()
                    .unwrap_or(&self.weights_by_mesh[mesh.index()]);
                for &mesh_index in &self.by_mesh[mesh.index()] {
                    let geometry = &self.meshes[mesh_index as usize - 1];
                    if geometry.skin.is_empty() != (skin == 0) {
                        return Err(format!(
                            "{} node and mesh disagree about skinning",
                            self.path
                        ));
                    }
                    if skin != 0
                        && geometry.max_joint >= (self.skins[skin as usize - 1].joints.len() as i32)
                    {
                        return Err(format!(
                            "{} mesh joint index exceeds skin {}",
                            self.path,
                            skin - 1
                        ));
                    }
                    let weights = if source_weights.is_empty() {
                        vec![0.0; geometry.morph_target_count]
                    } else {
                        source_weights.to_vec()
                    };
                    if weights.len() != geometry.morph_target_count {
                        return Err(format!(
                            "{} node {} weights do not match its morph targets",
                            self.path,
                            node.index()
                        ));
                    }
                    finite(
                        weights.iter().copied(),
                        &format!("{} node {} weights", self.path, node.index()),
                    )?;
                    let (translation, rotation, scale) = decompose(
                        self.worlds[node.index()],
                        &format!("{} node {}", self.path, node.index()),
                    )?;
                    self.draws.push(DrawData {
                        weights,
                        view: TecsModelDraw {
                            mesh: mesh_index,
                            material: geometry.material,
                            skin,
                            node: node.index() as u32 + 1,
                            weights: ptr::null(),
                            weight_count: 0,
                            x: translation[0],
                            y: translation[1],
                            z: translation[2],
                            rotation_x: rotation[0],
                            rotation_y: rotation[1],
                            rotation_z: rotation[2],
                            rotation_w: rotation[3],
                            scale_x: scale[0],
                            scale_y: scale[1],
                            scale_z: scale[2],
                        },
                    });
                }
            }
            for child in node.children() {
                self.visit(child)?;
            }
            self.visiting[node.index()] = false;
            Ok(())
        }
    }
    let mut visiting = vec![false; node_count];
    let mut builder = SceneBuilder {
        path: &path_text,
        buffers: &buffers,
        worlds: &worlds,
        by_mesh: &by_mesh,
        weights_by_mesh: &weights_by_mesh,
        meshes: &mesh_data,
        skins: &mut skin_data,
        skin_by_node: &mut skin_by_node,
        draws: &mut draw_data,
        visiting: &mut visiting,
    };
    if let Some(scene) = gltf
        .document
        .default_scene()
        .or_else(|| gltf.document.scenes().next())
    {
        for node in scene.nodes() {
            builder.visit(node)?;
        }
    } else {
        for node in gltf
            .document
            .nodes()
            .filter(|node| parents[node.index()].is_none())
        {
            builder.visit(node)?;
        }
    }

    let mut model = TecsModel {
        path: path_text,
        mipmaps: mipmaps.unwrap_or(false),
        mesh_data,
        image_data,
        material_data,
        draw_data,
        skin_data,
        animation_data,
        channel_data,
        mesh_views: Vec::new(),
        image_views: Vec::new(),
        material_views: Vec::new(),
        draw_views: Vec::new(),
        skin_views: Vec::new(),
        nodes,
        animation_views: Vec::new(),
        channel_views: Vec::new(),
    };
    build_views(&mut model);
    Ok(model)
}

fn import(path: &Path) -> Result<TecsModel, String> {
    import_with_geometry_optimization(path, true)
}

#[no_mangle]
pub unsafe extern "C" fn tecsModelLoad(path: *const u8, path_length: usize) -> *mut TecsModel {
    if path.is_null() && path_length != 0 {
        set_error("model path is null");
        return ptr::null_mut();
    }
    let bytes = if path_length == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(path, path_length) }
    };
    let path = match str::from_utf8(bytes) {
        Ok(path) if !path.is_empty() => PathBuf::from(path),
        Ok(_) => {
            set_error("model path is empty");
            return ptr::null_mut();
        }
        Err(error) => {
            set_error(error);
            return ptr::null_mut();
        }
    };
    match import(&path) {
        Ok(model) => Box::into_raw(Box::new(model)),
        Err(error) => {
            set_error(error);
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsModelGetInfo(
    model: *const TecsModel,
    info: *mut TecsModelInfo,
) -> bool {
    if model.is_null() || info.is_null() {
        set_error("model and info are required");
        return false;
    }
    let model = unsafe { &*model };
    unsafe {
        *info = TecsModelInfo {
            path: model.path.as_ptr(),
            path_length: model.path.len(),
            mipmaps: u8::from(model.mipmaps),
            _padding: [0; 7],
            meshes: maybe_ptr(&model.mesh_views),
            mesh_count: model.mesh_views.len(),
            images: maybe_ptr(&model.image_views),
            image_count: model.image_views.len(),
            materials: maybe_ptr(&model.material_views),
            material_count: model.material_views.len(),
            draws: maybe_ptr(&model.draw_views),
            draw_count: model.draw_views.len(),
            skins: maybe_ptr(&model.skin_views),
            skin_count: model.skin_views.len(),
            nodes: maybe_ptr(&model.nodes),
            node_count: model.nodes.len(),
            animations: maybe_ptr(&model.animation_views),
            animation_count: model.animation_views.len(),
            channels: maybe_ptr(&model.channel_views),
            channel_count: model.channel_views.len(),
        }
    };
    true
}

#[no_mangle]
pub unsafe extern "C" fn tecsModelDestroy(model: *mut TecsModel) {
    if !model.is_null() {
        drop(unsafe { Box::from_raw(model) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::size_of;
    use std::time::Instant;

    struct ModelMetrics {
        vertices: usize,
        indices: usize,
        geometry_bytes: usize,
        vertices_transformed: u64,
        bytes_fetched: u64,
    }

    fn model_metrics(model: &TecsModel) -> ModelMetrics {
        let mut result = ModelMetrics {
            vertices: 0,
            indices: 0,
            geometry_bytes: 0,
            vertices_transformed: 0,
            bytes_fetched: 0,
        };
        for mesh in &model.mesh_data {
            let vertex_count = mesh.vertices.len() / 12;
            let cache = meshopt::analyze_vertex_cache(&mesh.indices, vertex_count, 16, 32, 256);
            let mut fetched = u64::from(
                meshopt::analyze_vertex_fetch(&mesh.indices, vertex_count, 12 * size_of::<f32>())
                    .bytes_fetched,
            );
            if !mesh.colors.is_empty() {
                fetched += u64::from(
                    meshopt::analyze_vertex_fetch(
                        &mesh.indices,
                        vertex_count,
                        4 * size_of::<f32>(),
                    )
                    .bytes_fetched,
                );
            }
            if !mesh.skin.is_empty() {
                fetched += u64::from(
                    meshopt::analyze_vertex_fetch(
                        &mesh.indices,
                        vertex_count,
                        8 * size_of::<f32>(),
                    )
                    .bytes_fetched,
                );
            }
            for _ in 0..mesh.morph_target_count {
                fetched += u64::from(
                    meshopt::analyze_vertex_fetch(
                        &mesh.indices,
                        vertex_count,
                        9 * size_of::<f32>(),
                    )
                    .bytes_fetched,
                );
            }
            result.vertices += vertex_count;
            result.indices += mesh.indices.len();
            result.geometry_bytes += mesh.vertices.len() * size_of::<f32>()
                + mesh.colors.len() * size_of::<f32>()
                + mesh.skin.len() * size_of::<f32>()
                + mesh.morph.len() * size_of::<f32>()
                + mesh.indices.len() * size_of::<u32>();
            result.vertices_transformed += u64::from(cache.vertices_transformed);
            result.bytes_fetched += fetched;
        }
        result
    }

    fn vertex(x: f32, y: f32) -> [f32; 12] {
        [x, y, 0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
    }

    fn vertex_identity(mesh: &MeshData, vertex: usize) -> Vec<u32> {
        let mut identity: Vec<u32> = mesh.vertices[vertex * 12..vertex * 12 + 12]
            .iter()
            .map(|value| value.to_bits())
            .collect();
        if !mesh.colors.is_empty() {
            identity.extend(
                mesh.colors[vertex * 4..vertex * 4 + 4]
                    .iter()
                    .map(|value| value.to_bits()),
            );
        }
        if !mesh.skin.is_empty() {
            identity.extend(
                mesh.skin[vertex * 8..vertex * 8 + 8]
                    .iter()
                    .map(|value| value.to_bits()),
            );
        }
        let vertex_count = mesh.vertices.len() / 12;
        for target in 0..mesh.morph_target_count {
            let at = (target * vertex_count + vertex) * 9;
            identity.extend(mesh.morph[at..at + 9].iter().map(|value| value.to_bits()));
        }
        identity
    }

    fn expanded_corners(mesh: &MeshData) -> Vec<Vec<u32>> {
        mesh.indices
            .iter()
            .map(|index| vertex_identity(mesh, *index as usize))
            .collect()
    }

    fn sorted_triangles(mesh: &MeshData) -> Vec<Vec<u32>> {
        let mut triangles: Vec<Vec<u32>> = expanded_corners(mesh)
            .chunks_exact(3)
            .map(|triangle| triangle.iter().flatten().copied().collect())
            .collect();
        triangles.sort_unstable();
        triangles
    }

    fn mesh_with_all_streams() -> MeshData {
        let mut vertices = Vec::new();
        for value in [
            vertex(0.0, 0.0),
            vertex(1.0, 0.0),
            vertex(1.0, 1.0),
            vertex(0.0, 0.0),
            vertex(1.0, 1.0),
            vertex(0.0, 1.0),
        ] {
            vertices.extend(value);
        }
        let source = [0usize, 1, 2, 0, 2, 3];
        let mut colors = Vec::new();
        let mut skin = Vec::new();
        let mut morph = Vec::new();
        for &value in &source {
            colors.extend([value as f32, 0.25, 0.5, 1.0]);
            skin.extend([value as f32, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0]);
            morph.extend([value as f32 * 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]);
        }
        MeshData {
            name: "fixture://all-streams".to_owned(),
            vertices,
            colors,
            indices: vec![3, 4, 5, 0, 1, 2],
            skin,
            morph,
            morph_weights: vec![0.0],
            morph_target_count: 1,
            center: Vec3::splat(0.5),
            radius: 1.0,
            material: 1,
            max_joint: 3,
        }
    }

    #[test]
    fn remaps_every_vertex_stream_during_fetch_optimization() {
        let mut mesh = mesh_with_all_streams();
        let expected = expanded_corners(&mesh);

        optimize_mesh(&mut mesh, true);

        assert_eq!(mesh.vertices.len() / 12, 6);
        assert_eq!(mesh.colors.len(), 6 * 4);
        assert_eq!(mesh.skin.len(), 6 * 8);
        assert_eq!(mesh.morph.len(), 6 * 9);
        assert_eq!(expanded_corners(&mesh), expected);
    }

    #[test]
    fn improves_cache_and_fetch_metrics_without_changing_topology() {
        let side = 17usize;
        let mut vertices = Vec::new();
        for y in 0..side {
            for x in 0..side {
                vertices.extend(vertex(x as f32, y as f32));
            }
        }
        let mut ordered = Vec::new();
        for y in 0..side - 1 {
            for x in 0..side - 1 {
                let at = (y * side + x) as u32;
                ordered.push([at, at + 1, at + side as u32]);
                ordered.push([at + 1, at + side as u32 + 1, at + side as u32]);
            }
        }
        let mut indices = Vec::with_capacity(ordered.len() * 3);
        let mut front = 0;
        let mut back = ordered.len();
        while front < back {
            indices.extend(ordered[front]);
            front += 1;
            if front < back {
                back -= 1;
                indices.extend(ordered[back]);
            }
        }
        let mut mesh = MeshData {
            name: "fixture://cache-grid".to_owned(),
            vertices,
            colors: Vec::new(),
            indices,
            skin: Vec::new(),
            morph: Vec::new(),
            morph_weights: Vec::new(),
            morph_target_count: 0,
            center: Vec3::splat(8.0),
            radius: 12.0,
            material: 1,
            max_joint: -1,
        };
        let expected = sorted_triangles(&mesh);
        let before_cache = meshopt::analyze_vertex_cache(&mesh.indices, side * side, 16, 32, 256);
        let before_fetch =
            meshopt::analyze_vertex_fetch(&mesh.indices, side * side, 12 * size_of::<f32>());

        optimize_mesh(&mut mesh, false);

        let vertex_count = mesh.vertices.len() / 12;
        let after_cache = meshopt::analyze_vertex_cache(&mesh.indices, vertex_count, 16, 32, 256);
        let after_fetch =
            meshopt::analyze_vertex_fetch(&mesh.indices, vertex_count, 12 * size_of::<f32>());
        assert_eq!(sorted_triangles(&mesh), expected);
        assert!(after_cache.vertices_transformed < before_cache.vertices_transformed);
        assert!(after_cache.acmr < before_cache.acmr);
        assert!(after_fetch.bytes_fetched <= before_fetch.bytes_fetched);
    }

    #[test]
    fn preserves_blended_triangle_order_while_optimizing_fetch() {
        let mut mesh = mesh_with_all_streams();
        let expected = expanded_corners(&mesh);

        optimize_mesh(&mut mesh, true);

        assert_eq!(expanded_corners(&mesh), expected);
    }

    #[test]
    #[ignore = "set TECS_MODEL_BENCH to report a cached large-scene import"]
    fn reports_large_scene_geometry_optimization() {
        let path = std::env::var_os("TECS_MODEL_BENCH")
            .map(PathBuf::from)
            .expect("TECS_MODEL_BENCH must name a glTF or GLB model");
        let started = Instant::now();
        let baseline = import_with_geometry_optimization(&path, false).unwrap();
        let baseline_time = started.elapsed();
        let baseline_metrics = model_metrics(&baseline);
        drop(baseline);

        let started = Instant::now();
        let optimized = import_with_geometry_optimization(&path, true).unwrap();
        let optimized_time = started.elapsed();
        let optimized_metrics = model_metrics(&optimized);

        println!(
            "model={} baseline_ms={} optimized_ms={} baseline_vertices={} optimized_vertices={} indices={} baseline_bytes={} optimized_bytes={} baseline_transforms={} optimized_transforms={} baseline_fetch_bytes={} optimized_fetch_bytes={}",
            path.display(),
            baseline_time.as_millis(),
            optimized_time.as_millis(),
            baseline_metrics.vertices,
            optimized_metrics.vertices,
            optimized_metrics.indices,
            baseline_metrics.geometry_bytes,
            optimized_metrics.geometry_bytes,
            baseline_metrics.vertices_transformed,
            optimized_metrics.vertices_transformed,
            baseline_metrics.bytes_fetched,
            optimized_metrics.bytes_fetched,
        );
        assert_eq!(optimized_metrics.indices, baseline_metrics.indices);
        assert!(optimized_metrics.vertices <= baseline_metrics.vertices);
        assert!(optimized_metrics.geometry_bytes <= baseline_metrics.geometry_bytes);
        assert!(optimized_metrics.vertices_transformed <= baseline_metrics.vertices_transformed);
        assert!(optimized_metrics.bytes_fetched <= baseline_metrics.bytes_fetched);
    }

    #[test]
    fn generates_standard_tangents_for_an_indexed_quad() {
        let positions = [
            Vec3::new(0.0, 0.0, 0.0),
            Vec3::new(1.0, 0.0, 0.0),
            Vec3::new(1.0, 1.0, 0.0),
            Vec3::new(0.0, 1.0, 0.0),
        ];
        let normals = [Vec3::Z; 4];
        let uvs = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]];
        let indices = [0, 1, 2, 0, 2, 3];

        let corners = generate_tangent_corners(&positions, &normals, &uvs, &indices).unwrap();

        assert_eq!(corners.len(), indices.len());
        for tangent in corners {
            assert!((tangent[0] - 1.0).abs() < 1.0e-6);
            assert!(tangent[1].abs() < 1.0e-6);
            assert!(tangent[2].abs() < 1.0e-6);
            assert!((tangent[3].abs() - 1.0).abs() < 1.0e-6);
        }
    }

    #[test]
    fn splits_vertices_at_tangent_discontinuities() {
        let indices = [0, 1, 2, 0, 2, 3];
        let corners = [
            [1.0, 0.0, 0.0, 1.0],
            [1.0, 0.0, 0.0, 1.0],
            [1.0, 0.0, 0.0, 1.0],
            [-1.0, 0.0, 0.0, -1.0],
            [-1.0, 0.0, 0.0, -1.0],
            [-1.0, 0.0, 0.0, -1.0],
        ];

        let remapped = remap_tangent_corners(&indices, &corners);

        assert_eq!(remapped.source_vertices, vec![0, 1, 2, 0, 2, 3]);
        assert_eq!(remapped.indices, vec![0, 1, 2, 3, 4, 5]);
        assert_eq!(remapped.tangents, corners);
    }

    #[test]
    fn splits_oversized_primitives_into_independent_culling_chunks() {
        let mut vertices = Vec::new();
        for value in [
            vertex(0.0, 0.0),
            vertex(1.0, 0.0),
            vertex(0.0, 0.5),
            vertex(10.0, 0.0),
            vertex(11.0, 0.0),
            vertex(10.0, 1.0),
        ] {
            vertices.extend(value);
        }
        let chunks = split_mesh_at(
            MeshData {
                name: "fixture://two-triangles".to_owned(),
                vertices,
                colors: Vec::new(),
                indices: vec![0, 1, 2, 3, 4, 5],
                skin: Vec::new(),
                morph: Vec::new(),
                morph_weights: Vec::new(),
                morph_target_count: 0,
                center: Vec3::ZERO,
                radius: 0.0,
                material: 2,
                max_joint: -1,
            },
            3,
        );

        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[0].vertices.len() / 12, 3);
        assert_eq!(chunks[1].vertices.len() / 12, 3);
        assert_eq!(chunks[0].indices.len(), 3);
        assert_eq!(chunks[1].indices.len(), 3);
        assert_eq!(chunks[0].name, "fixture://two-triangles#chunk-0");
        assert_eq!(chunks[1].name, "fixture://two-triangles#chunk-1");
        assert!((chunks[0].center.x - 0.5).abs() < f32::EPSILON);
        assert!((chunks[1].center.x - 10.5).abs() < f32::EPSILON);
        assert_eq!(chunks[1].material, 2);
    }
}
