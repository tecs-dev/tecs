//! Every pipeline the deferred graph implies, built on a real device.
//!
//! This is what proves the compiled material dispatch is a shader: the engine's
//! whole material set is assembled, folded into the instanced module, and put
//! through pipeline creation with the bind group layouts the frame uses. A
//! material that does not compile, a binding a layout does not provide, and an
//! attachment count a fragment does not write all fail here rather than on the
//! first frame of a game.
//!
//! A machine with no adapter skips rather than fails.

use std::borrow::Cow;
use std::path::Path;

use wgpu::{
    DeviceDescriptor, ErrorFilter, Instance, InstanceDescriptor, ShaderModuleDescriptor,
    ShaderSource, TextureFormat,
};

use crate::graph::{parse_graph, tests::GraphBuilder};
use crate::graphics::{build_passes, instance_source, Body, Layouts};
use crate::shaderpack::ShaderPack;

fn engine_pack() -> ShaderPack {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../assets/materials")
        .canonicalize()
        .expect("the engine material directory is in the tree");
    ShaderPack::assemble(&directory).expect("the engine material set assembles")
}

fn open() -> Option<(wgpu::Device, wgpu::Queue)> {
    let instance = Instance::new(InstanceDescriptor::new_without_display_handle());
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        force_fallback_adapter: false,
        compatible_surface: None,
        ..Default::default()
    }))
    .ok()?;
    pollster::block_on(adapter.request_device(&DeviceDescriptor {
        label: Some("tecs pipeline test"),
        ..Default::default()
    }))
    .ok()
}

#[test]
fn builds_every_deferred_pipeline_from_the_engine_material_set() {
    let Some((device, _queue)) = open() else {
        eprintln!("no wgpu adapter; skipping the pipeline tests");
        return;
    };
    let pack = engine_pack();
    assert_eq!(pack.material_count(), 13);

    let scope = device.push_error_scope(ErrorFilter::Validation);
    let layouts = Layouts::new(&device);
    let module = device.create_shader_module(ShaderModuleDescriptor {
        label: Some("tecs instance"),
        source: ShaderSource::Wgsl(Cow::Owned(instance_source(&pack))),
    });
    let graph = parse_graph(&crate::graph::tests::deferred()).expect("the deferred graph decodes");
    let passes = build_passes(
        &device,
        &layouts,
        &module,
        &graph,
        TextureFormat::Bgra8UnormSrgb,
    )
    .expect("every deferred pass builds");

    assert_eq!(passes.len(), 5);
    // geometry and forward draw the scene; lighting, composite and present each
    // cover their target once.
    assert!(matches!(passes[0].body, Body::Instanced { .. }));
    assert!(matches!(passes[3].body, Body::Instanced { .. }));
    for pass in &passes {
        assert!(
            pass.pipeline.is_some(),
            "every deferred pass has a pipeline"
        );
    }
    assert!(
        passes[1].input_layout.is_some(),
        "a resolve binds its inputs"
    );
    assert!(passes[0].input_layout.is_none(), "geometry reads no target");

    let error = pollster::block_on(scope.pop());
    assert!(error.is_none(), "{error:?}");
}

#[test]
fn gives_a_pass_it_has_no_body_for_its_attachments_and_nothing_else() {
    let Some((device, _queue)) = open() else {
        eprintln!("no wgpu adapter; skipping the pipeline tests");
        return;
    };
    // A game's own pass, declared at a named seam. The backend has no body for
    // it, so it begins with its clear and draws nothing rather than refusing the
    // graph.
    let bytes = GraphBuilder::new()
        .target("albedo", 0, 1.0, Some(0.0))
        .target("normal", 0, 1.0, Some(0.5))
        .target("orm", 0, 1.0, Some(1.0))
        .target("emission", 0, 1.0, Some(0.0))
        .target("lit", 1, 1.0, Some(0.0))
        .target("scene", 0, 1.0, None)
        .target("game.overlay", 0, 0.5, Some(0.0))
        .pass(
            "geometry",
            &[],
            &["albedo", "normal", "orm", "emission"],
            1,
            0,
        )
        .pass(
            "lighting",
            &["albedo", "normal", "orm", "emission"],
            &["lit"],
            0,
            0,
        )
        .pass("composite", &["lit"], &["scene"], 0, 0)
        .pass("game.overlay", &["scene"], &["game.overlay"], 0, 0)
        .pass("present", &["scene"], &[], 0, 2)
        .build();
    let graph = parse_graph(&bytes).expect("the graph decodes");

    let scope = device.push_error_scope(ErrorFilter::Validation);
    let layouts = Layouts::new(&device);
    let module = device.create_shader_module(ShaderModuleDescriptor {
        label: Some("tecs instance"),
        source: ShaderSource::Wgsl(Cow::Owned(instance_source(&engine_pack()))),
    });
    let passes = build_passes(
        &device,
        &layouts,
        &module,
        &graph,
        TextureFormat::Bgra8UnormSrgb,
    )
    .expect("a graph with an unimplemented pass still builds");

    assert_eq!(passes.len(), 5);
    assert!(matches!(passes[3].body, Body::Empty));
    assert!(passes[3].pipeline.is_none());

    let error = pollster::block_on(scope.pop());
    assert!(error.is_none(), "{error:?}");
}

#[test]
fn rebuilds_pipelines_for_a_different_swapchain_format() {
    let Some((device, _queue)) = open() else {
        eprintln!("no wgpu adapter; skipping the pipeline tests");
        return;
    };
    // The present pass bakes the swapchain's format, so a surface that comes
    // back configured differently after a resize or a display change needs the
    // pipelines made again. Both formats have to build for that to be possible.
    let graph = parse_graph(&crate::graph::tests::deferred()).expect("the deferred graph decodes");
    let layouts = Layouts::new(&device);
    let module = device.create_shader_module(ShaderModuleDescriptor {
        label: Some("tecs instance"),
        source: ShaderSource::Wgsl(Cow::Owned(instance_source(&engine_pack()))),
    });
    for format in [TextureFormat::Bgra8UnormSrgb, TextureFormat::Rgba8UnormSrgb] {
        let scope = device.push_error_scope(ErrorFilter::Validation);
        let passes = build_passes(&device, &layouts, &module, &graph, format)
            .expect("the deferred graph builds against either swapchain format");
        assert_eq!(passes.len(), 5);
        let error = pollster::block_on(scope.pop());
        assert!(error.is_none(), "{format:?}: {error:?}");
    }
}
