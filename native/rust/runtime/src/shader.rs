//! Optional Cargo-owned shader compilation behind the stable C ABI.

use std::ffi::{c_char, CString};
use std::ptr;
#[cfg(feature = "shader-compiler")]
use std::slice;

use crate::set_error;

#[repr(C)]
pub struct TecsShaderDefine {
    name: *const u8,
    name_length: usize,
    value: *const u8,
    value_length: usize,
}

#[repr(C)]
pub struct TecsShaderInfo {
    code: *const u8,
    code_length: usize,
    entrypoint: *const c_char,
    samplers: u32,
    read_only_storage_textures: u32,
    read_only_storage_buffers: u32,
    read_write_storage_textures: u32,
    read_write_storage_buffers: u32,
    uniform_buffers: u32,
    thread_count_x: u32,
    thread_count_y: u32,
    thread_count_z: u32,
}

#[derive(Clone, Copy, Default)]
struct ResourceCounts {
    samplers: u32,
    read_only_storage_textures: u32,
    read_only_storage_buffers: u32,
    read_write_storage_textures: u32,
    read_write_storage_buffers: u32,
    uniform_buffers: u32,
}

pub struct TecsShader {
    code: Box<[u8]>,
    entrypoint: CString,
    counts: ResourceCounts,
    thread_count: [u32; 3],
}

#[cfg(feature = "shader-compiler")]
mod compiler {
    use std::collections::BTreeMap;
    use std::sync::OnceLock;

    use spirv_cross2::compile::msl::{BindTarget, CompilerOptions, ResourceBinding};
    use spirv_cross2::reflect::{DecorationValue, ExecutionModeArguments, ResourceType};
    use spirv_cross2::spirv::{Decoration, ExecutionMode, ExecutionModel};
    use spirv_cross2::targets::Msl;
    use spirv_cross2::{Compiler, Module};

    use super::{ResourceCounts, TecsShader};

    static SHADER_COMPILER: OnceLock<Result<shaderc::Compiler, String>> = OnceLock::new();

    #[derive(Clone, Copy)]
    struct Binding {
        set: u32,
        binding: u32,
    }

    struct Reflected {
        sampled: Vec<Binding>,
        read_only_textures: Vec<Binding>,
        read_write_textures: Vec<Binding>,
        read_only_buffers: Vec<Binding>,
        read_write_buffers: Vec<Binding>,
        uniforms: Vec<Binding>,
        counts: ResourceCounts,
    }

    struct Layout {
        resources: u32,
        read_write: Option<u32>,
        uniforms: u32,
    }

    fn layout(stage: u32) -> Result<Layout, String> {
        match stage {
            0 => Ok(Layout {
                resources: 0,
                read_write: None,
                uniforms: 1,
            }),
            1 => Ok(Layout {
                resources: 2,
                read_write: None,
                uniforms: 3,
            }),
            2 => Ok(Layout {
                resources: 0,
                read_write: Some(1),
                uniforms: 2,
            }),
            _ => Err(format!("unknown shader stage {stage}")),
        }
    }

    fn execution_model(stage: u32) -> Result<ExecutionModel, String> {
        match stage {
            0 => Ok(ExecutionModel::Vertex),
            1 => Ok(ExecutionModel::Fragment),
            2 => Ok(ExecutionModel::GLCompute),
            _ => Err(format!("unknown shader stage {stage}")),
        }
    }

    fn collect(
        compiler: &Compiler<Msl>,
        resources: &spirv_cross2::reflect::ShaderResources,
        resource_type: ResourceType,
    ) -> Result<Vec<Binding>, String> {
        let mut found = Vec::new();
        let entries = resources
            .resources_for_type(resource_type)
            .map_err(|error| error.to_string())?;
        for resource in entries {
            let set = match compiler
                .decoration(resource.id, Decoration::DescriptorSet)
                .map_err(|error| error.to_string())?
            {
                Some(DecorationValue::Literal(value)) => value,
                _ => {
                    return Err(format!(
                        "resource '{}' has no descriptor set",
                        resource.name
                    ))
                }
            };
            let binding = match compiler
                .decoration(resource.id, Decoration::Binding)
                .map_err(|error| error.to_string())?
            {
                Some(DecorationValue::Literal(value)) => value,
                _ => return Err(format!("resource '{}' has no binding", resource.name)),
            };
            found.push(Binding { set, binding });
        }
        found.sort_by_key(|entry| (entry.set, entry.binding));
        Ok(found)
    }

    fn in_set(bindings: &[Binding], set: Option<u32>) -> Vec<Binding> {
        let Some(set) = set else {
            return Vec::new();
        };
        bindings
            .iter()
            .copied()
            .filter(|entry| entry.set == set)
            .collect()
    }

    fn reject_other_sets(
        bindings: &[Binding],
        resource: &str,
        allowed_a: u32,
        allowed_b: Option<u32>,
    ) -> Result<(), String> {
        if let Some(entry) = bindings
            .iter()
            .find(|entry| entry.set != allowed_a && Some(entry.set) != allowed_b)
        {
            return Err(format!(
                "{resource} at set {}, binding {} is outside SDL's stage layout",
                entry.set, entry.binding
            ));
        }
        Ok(())
    }

    fn reflect(compiler: &Compiler<Msl>, stage: u32) -> Result<Reflected, String> {
        let layout = layout(stage)?;
        let resources = compiler
            .shader_resources()
            .map_err(|error| error.to_string())?;
        let sampled = collect(compiler, &resources, ResourceType::SampledImage)?;
        let textures = collect(compiler, &resources, ResourceType::StorageImage)?;
        let buffers = collect(compiler, &resources, ResourceType::StorageBuffer)?;
        let uniforms = collect(compiler, &resources, ResourceType::UniformBuffer)?;
        reject_other_sets(&sampled, "sampled texture", layout.resources, None)?;
        reject_other_sets(
            &textures,
            "storage texture",
            layout.resources,
            layout.read_write,
        )?;
        reject_other_sets(
            &buffers,
            "storage buffer",
            layout.resources,
            layout.read_write,
        )?;
        reject_other_sets(&uniforms, "uniform buffer", layout.uniforms, None)?;

        let read_only_textures = in_set(&textures, Some(layout.resources));
        let read_write_textures = in_set(&textures, layout.read_write);
        let read_only_buffers = in_set(&buffers, Some(layout.resources));
        let read_write_buffers = in_set(&buffers, layout.read_write);
        let counts = ResourceCounts {
            samplers: sampled.len() as u32,
            read_only_storage_textures: read_only_textures.len() as u32,
            read_only_storage_buffers: read_only_buffers.len() as u32,
            read_write_storage_textures: read_write_textures.len() as u32,
            read_write_storage_buffers: read_write_buffers.len() as u32,
            uniform_buffers: uniforms.len() as u32,
        };
        Ok(Reflected {
            sampled,
            read_only_textures,
            read_write_textures,
            read_only_buffers,
            read_write_buffers,
            uniforms,
            counts,
        })
    }

    fn bind(
        compiler: &mut Compiler<Msl>,
        stage: ExecutionModel,
        binding: Binding,
        buffer: u32,
        texture: u32,
        sampler: u32,
    ) -> Result<(), String> {
        compiler
            .add_resource_binding(
                stage,
                ResourceBinding::from_qualified(binding.set, binding.binding),
                &BindTarget {
                    buffer,
                    texture,
                    sampler,
                    count: None,
                },
            )
            .map_err(|error| error.to_string())
    }

    fn remap(
        compiler: &mut Compiler<Msl>,
        stage: ExecutionModel,
        reflected: &Reflected,
    ) -> Result<(), String> {
        for (buffer_slot, binding) in reflected
            .uniforms
            .iter()
            .chain(&reflected.read_only_buffers)
            .chain(&reflected.read_write_buffers)
            .enumerate()
        {
            bind(compiler, stage, *binding, buffer_slot as u32, 0, 0)?;
        }

        for (texture_slot, binding) in reflected
            .sampled
            .iter()
            .chain(&reflected.read_only_textures)
            .chain(&reflected.read_write_textures)
            .enumerate()
        {
            let texture_slot = texture_slot as u32;
            let sampler_slot = if texture_slot < reflected.sampled.len() as u32 {
                texture_slot
            } else {
                0
            };
            bind(compiler, stage, *binding, 0, texture_slot, sampler_slot)?;
        }
        Ok(())
    }

    pub fn compile(
        source: &str,
        name: &str,
        stage: u32,
        target: u32,
        defines: BTreeMap<String, String>,
    ) -> Result<TecsShader, String> {
        let compiler = SHADER_COMPILER
            .get_or_init(|| {
                shaderc::Compiler::new()
                    .map_err(|error| format!("cannot create shader compiler: {error}"))
            })
            .as_ref()
            .map_err(Clone::clone)?;
        let mut options = shaderc::CompileOptions::new()
            .map_err(|error| format!("cannot create shader compiler options: {error}"))?;
        options.set_target_env(
            shaderc::TargetEnv::Vulkan,
            shaderc::EnvVersion::Vulkan1_0 as u32,
        );
        options.set_optimization_level(shaderc::OptimizationLevel::Performance);
        for (key, value) in defines {
            options.add_macro_definition(&key, Some(&value));
        }
        let kind = match stage {
            0 => shaderc::ShaderKind::Vertex,
            1 => shaderc::ShaderKind::Fragment,
            2 => shaderc::ShaderKind::Compute,
            _ => return Err(format!("unknown shader stage {stage}")),
        };
        let artifact = compiler
            .compile_into_spirv(source, kind, name, "main", Some(&options))
            .map_err(|error| error.to_string())?;
        let words = artifact.as_binary();
        let mut cross = Compiler::<Msl>::new(Module::from_words(words))
            .map_err(|error| format!("{name}: SPIR-V reflection failed: {error}"))?;
        let reflected = reflect(&cross, stage)?;
        let thread_count = if stage == 2 {
            match cross
                .execution_mode_arguments(ExecutionMode::LocalSize)
                .map_err(|error| error.to_string())?
            {
                Some(ExecutionModeArguments::LocalSize { x, y, z }) => [x, y, z],
                _ => [1, 1, 1],
            }
        } else {
            [1, 1, 1]
        };

        let (code, entrypoint) = match target {
            0 => (artifact.as_binary_u8().to_vec(), "main".to_owned()),
            1 => {
                let model = execution_model(stage)?;
                remap(&mut cross, model, &reflected)?;
                let compiled = cross
                    .compile(&CompilerOptions::default())
                    .map_err(|error| format!("{name}: MSL generation failed: {error}"))?;
                let entrypoint = compiled
                    .cleansed_entry_point_name("main", model)
                    .map_err(|error| error.to_string())?
                    .map_or_else(|| "main".to_owned(), |value| value.to_string());
                let mut bytes = compiled.as_ref().as_bytes().to_vec();
                bytes.push(0);
                (bytes, entrypoint)
            }
            _ => return Err(format!("unknown shader target {target}")),
        };

        Ok(TecsShader {
            code: code.into_boxed_slice(),
            entrypoint: std::ffi::CString::new(entrypoint)
                .map_err(|_| "generated shader entry point contains a NUL byte".to_owned())?,
            counts: reflected.counts,
            thread_count,
        })
    }
}

#[no_mangle]
pub extern "C" fn tecsShaderCompilerAvailable() -> bool {
    cfg!(feature = "shader-compiler")
}

#[cfg(feature = "shader-compiler")]
unsafe fn bytes<'a>(data: *const u8, length: usize, what: &str) -> Result<&'a [u8], String> {
    if data.is_null() && length != 0 {
        return Err(format!("{what} is null"));
    }
    Ok(if length == 0 {
        &[]
    } else {
        // SAFETY: The caller promises `length` readable bytes for this call.
        unsafe { slice::from_raw_parts(data, length) }
    })
}

#[no_mangle]
pub unsafe extern "C" fn tecsShaderCompile(
    source: *const u8,
    source_length: usize,
    name: *const u8,
    name_length: usize,
    stage: u32,
    target: u32,
    defines: *const TecsShaderDefine,
    define_count: usize,
) -> *mut TecsShader {
    #[cfg(not(feature = "shader-compiler"))]
    {
        let _ = (
            source,
            source_length,
            name,
            name_length,
            stage,
            target,
            defines,
            define_count,
        );
        set_error("this build contains no shader compiler");
        ptr::null_mut()
    }

    #[cfg(feature = "shader-compiler")]
    {
        let result = (|| {
            let source =
                std::str::from_utf8(unsafe { bytes(source, source_length, "shader source")? })
                    .map_err(|error| format!("shader source is not UTF-8: {error}"))?;
            let name = std::str::from_utf8(unsafe { bytes(name, name_length, "shader name")? })
                .map_err(|error| format!("shader name is not UTF-8: {error}"))?;
            if defines.is_null() && define_count != 0 {
                return Err("shader defines are null".to_owned());
            }
            let definitions = if define_count == 0 {
                &[]
            } else {
                // SAFETY: The caller promises `define_count` readable definitions.
                unsafe { slice::from_raw_parts(defines, define_count) }
            };
            let mut map = std::collections::BTreeMap::new();
            for definition in definitions {
                let key = std::str::from_utf8(unsafe {
                    bytes(
                        definition.name,
                        definition.name_length,
                        "shader define name",
                    )?
                })
                .map_err(|error| format!("shader define name is not UTF-8: {error}"))?;
                let value = std::str::from_utf8(unsafe {
                    bytes(
                        definition.value,
                        definition.value_length,
                        "shader define value",
                    )?
                })
                .map_err(|error| format!("shader define value is not UTF-8: {error}"))?;
                map.insert(key.to_owned(), value.to_owned());
            }
            compiler::compile(source, name, stage, target, map)
        })();
        match result {
            Ok(shader) => Box::into_raw(Box::new(shader)),
            Err(error) => {
                set_error(error);
                ptr::null_mut()
            }
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsShaderGetInfo(
    shader: *const TecsShader,
    info: *mut TecsShaderInfo,
) -> bool {
    if shader.is_null() || info.is_null() {
        set_error("shader or output info is null");
        return false;
    }
    // SAFETY: Both pointers were checked and the caller promises they are valid.
    let shader = unsafe { &*shader };
    unsafe {
        *info = TecsShaderInfo {
            code: shader.code.as_ptr(),
            code_length: shader.code.len(),
            entrypoint: shader.entrypoint.as_ptr(),
            samplers: shader.counts.samplers,
            read_only_storage_textures: shader.counts.read_only_storage_textures,
            read_only_storage_buffers: shader.counts.read_only_storage_buffers,
            read_write_storage_textures: shader.counts.read_write_storage_textures,
            read_write_storage_buffers: shader.counts.read_write_storage_buffers,
            uniform_buffers: shader.counts.uniform_buffers,
            thread_count_x: shader.thread_count[0],
            thread_count_y: shader.thread_count[1],
            thread_count_z: shader.thread_count[2],
        };
    }
    true
}

#[no_mangle]
pub unsafe extern "C" fn tecsShaderDestroy(shader: *mut TecsShader) {
    if !shader.is_null() {
        // SAFETY: The pointer came from `tecsShaderCompile` and is released once.
        drop(unsafe { Box::from_raw(shader) });
    }
}
