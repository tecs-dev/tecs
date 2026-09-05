//! The render pass and render target graph.
//!
//! Nupp declares the graph and the packet carries the declaration; this module
//! decodes it, holds it to the same rules the declaration is held to, and owns
//! the targets it names. Execution follows declaration order rather than a
//! topological sort: the order of a deferred pipeline is a design decision, and
//! a graph that quietly reorders itself is harder to reason about than one that
//! refuses to run.
//!
//! Target allocation is separated from texture creation, so the sizing and the
//! reuse rule are testable without a device. `TargetStore` decides what to
//! allocate and a `TargetAllocator` makes it.

use std::collections::HashMap;

use anyhow::{bail, Context, Result};

/// Reserved as an input name for the shared depth attachment. This string is a
/// compatibility surface shared with `tecs.gpu.passes.DEPTH`.
pub const DEPTH_NAME: &str = "depth";

/// How many color attachments one pass may write. WebGPU guarantees eight, and
/// the frame builds a pass's attachments on the stack against this bound.
pub const MAX_OUTPUTS: usize = 8;

/// The formats a target may be declared in. The wire codes are a compatibility
/// surface shared with `tecs.gpu.passes`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TargetFormat {
    Rgba8,
    Rgba16Float,
    R8,
    R16Float,
}

impl TargetFormat {
    fn from_code(code: u32) -> Result<Self> {
        Ok(match code {
            0 => Self::Rgba8,
            1 => Self::Rgba16Float,
            2 => Self::R8,
            3 => Self::R16Float,
            other => bail!("render graph target format {other} is not one this backend knows"),
        })
    }
}

/// How a pass uses the shared depth attachment.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DepthMode {
    None,
    TestWrite,
    Test,
}

impl DepthMode {
    fn from_code(code: u32) -> Result<Self> {
        Ok(match code {
            0 => Self::None,
            1 => Self::TestWrite,
            2 => Self::Test,
            other => bail!("render graph depth mode {other} is not one this backend knows"),
        })
    }
}

/// What a pass does to the targets it writes when it begins.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ClearMode {
    /// Takes each output target's own declared clear.
    Target,
    /// Loads every output, whatever the targets declare.
    Load,
    /// Clears every output to one color.
    Override([f64; 4]),
}

/// A target the backend allocates, sizes with the frame, and owns.
#[derive(Clone, Debug, PartialEq)]
pub struct Target {
    pub name: String,
    pub format: TargetFormat,
    pub scale: f32,
    pub clear: Option<[f64; 4]>,
}

/// One input of a pass, resolved to what it reads.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Input {
    Target(usize),
    Depth,
}

/// One pass, with its names resolved to target indices.
#[derive(Clone, Debug, PartialEq)]
pub struct Pass {
    pub name: String,
    pub inputs: Vec<Input>,
    /// Empty renders to the swapchain.
    pub outputs: Vec<usize>,
    pub depth: DepthMode,
    pub depth_clear: Option<f32>,
    pub clear: ClearMode,
}

/// A decoded, validated graph.
#[derive(Clone, Debug, PartialEq)]
pub struct Graph {
    targets: Vec<Target>,
    passes: Vec<Pass>,
    needs_depth: bool,
}

impl Graph {
    pub fn targets(&self) -> &[Target] {
        &self.targets
    }

    pub fn passes(&self) -> &[Pass] {
        &self.passes
    }

    pub fn needs_depth(&self) -> bool {
        self.needs_depth
    }

    /// Returns the size a target is allocated at for one frame size.
    ///
    /// A scaled target rounds down and never reaches zero, because a texture
    /// with no area is not a texture a pass can be begun against.
    pub fn target_size(&self, index: usize, width: u32, height: u32) -> (u32, u32) {
        let scale = self.targets[index].scale;
        (
            ((width as f32 * scale).floor() as u32).max(1),
            ((height as f32 * scale).floor() as u32).max(1),
        )
    }
}

/// Decodes the graph section of a frame packet.
///
/// The section is untrusted input at an ABI boundary, so every rule the
/// declaration holds itself to is checked again here. A packet that describes a
/// graph that cannot run is refused, and the refusal names the pass.
pub fn parse_graph(bytes: &[u8]) -> Result<Graph> {
    let mut reader = Reader::new(bytes);
    let name_count = reader.u32()? as usize;
    let name_bytes = reader.u32()? as usize;
    let blob = reader.bytes(name_bytes)?;

    let mut names = Vec::with_capacity(name_count);
    let mut at = 0_usize;
    for _ in 0..name_count {
        let stop = blob[at..]
            .iter()
            .position(|byte| *byte == 0)
            .context("render graph name table is not terminated")?;
        names.push(
            std::str::from_utf8(&blob[at..at + stop])
                .context("render graph name is not UTF-8")?
                .to_owned(),
        );
        at += stop + 1;
    }

    let target_count = reader.u32()? as usize;
    let mut targets: Vec<Target> = Vec::with_capacity(target_count);
    let mut target_index: HashMap<String, usize> = HashMap::with_capacity(target_count);
    for index in 0..target_count {
        let name = names
            .get(reader.u32()? as usize)
            .context("render graph target names an index the table has not")?
            .clone();
        let format = TargetFormat::from_code(reader.u32()?)?;
        let scale = reader.f32()?;
        let has_clear = reader.u32()?;
        let clear = [
            reader.f32()? as f64,
            reader.f32()? as f64,
            reader.f32()? as f64,
            reader.f32()? as f64,
        ];
        if name == DEPTH_NAME {
            bail!("render graph target name '{DEPTH_NAME}' is reserved for the depth attachment");
        }
        if !scale.is_finite() || scale <= 0.0 || scale > 1.0 {
            bail!("render graph target '{name}' has scale {scale}, which is not above zero and at most one");
        }
        if has_clear > 1 {
            bail!("render graph target '{name}' has an unknown clear marker {has_clear}");
        }
        if target_index.insert(name.clone(), index).is_some() {
            bail!("render graph declares target '{name}' twice");
        }
        targets.push(Target {
            name,
            format,
            scale,
            clear: (has_clear == 1).then_some(clear),
        });
    }

    let pass_count = reader.u32()? as usize;
    let mut passes: Vec<Pass> = Vec::with_capacity(pass_count);
    let mut pass_names: HashMap<String, ()> = HashMap::with_capacity(pass_count);
    let mut produced = vec![false; targets.len()];
    let mut produced_depth = false;
    let mut needs_depth = false;
    for _ in 0..pass_count {
        let name = names
            .get(reader.u32()? as usize)
            .context("render graph pass names an index the table has not")?
            .clone();
        let depth = DepthMode::from_code(reader.u32()?)?;
        let has_depth_clear = reader.u32()?;
        let depth_clear = reader.f32()?;
        let clear_code = reader.u32()?;
        let clear_color = [
            reader.f32()? as f64,
            reader.f32()? as f64,
            reader.f32()? as f64,
            reader.f32()? as f64,
        ];
        let input_count = reader.u32()? as usize;
        let output_count = reader.u32()? as usize;

        if pass_names.insert(name.clone(), ()).is_some() {
            bail!("render graph declares pass '{name}' twice");
        }
        let clear = match clear_code {
            0 => ClearMode::Target,
            1 => ClearMode::Load,
            2 => ClearMode::Override(clear_color),
            other => bail!("render graph pass '{name}' has an unknown clear mode {other}"),
        };

        let mut inputs = Vec::with_capacity(input_count);
        for _ in 0..input_count {
            let referenced = names
                .get(reader.u32()? as usize)
                .context("render graph input names an index the table has not")?;
            if referenced == DEPTH_NAME {
                if !produced_depth {
                    bail!("render graph pass '{name}' reads depth before any pass writes it");
                }
                inputs.push(Input::Depth);
                continue;
            }
            let index = *target_index.get(referenced).with_context(|| {
                format!("render graph pass '{name}' reads undeclared target '{referenced}'")
            })?;
            if !produced[index] {
                bail!("render graph pass '{name}' reads '{referenced}' before any pass writes it");
            }
            inputs.push(Input::Target(index));
        }

        let mut outputs = Vec::with_capacity(output_count);
        for _ in 0..output_count {
            let referenced = names
                .get(reader.u32()? as usize)
                .context("render graph output names an index the table has not")?;
            let index = *target_index.get(referenced).with_context(|| {
                format!("render graph pass '{name}' writes undeclared target '{referenced}'")
            })?;
            // One depth attachment at frame size serves every depth pass, so a
            // pass drawing into a scaled target cannot share it.
            if depth != DepthMode::None && targets[index].scale != 1.0 {
                bail!(
                    "render graph pass '{name}' uses depth but writes '{referenced}' below frame \
                     scale, and the depth attachment is frame sized"
                );
            }
            outputs.push(index);
        }
        if outputs.len() > MAX_OUTPUTS {
            bail!(
                "render graph pass '{name}' writes {} targets, and a pass may write {MAX_OUTPUTS}",
                outputs.len()
            );
        }

        if depth != DepthMode::None {
            needs_depth = true;
        }
        if depth == DepthMode::TestWrite {
            produced_depth = true;
        }
        for index in &outputs {
            produced[*index] = true;
        }

        passes.push(Pass {
            name,
            inputs,
            outputs,
            depth,
            depth_clear: (has_depth_clear == 1).then_some(depth_clear),
            clear,
        });
    }
    reader.finish()?;

    Ok(Graph {
        targets,
        passes,
        needs_depth,
    })
}

/// Makes the texture behind one target.
pub trait TargetAllocator {
    type Target;

    fn create(&mut self, name: &str, format: TargetFormat, width: u32, height: u32)
        -> Self::Target;

    /// Makes the shared depth attachment, which is always at frame size.
    fn create_depth(&mut self, width: u32, height: u32) -> Self::Target;
}

/// The textures a graph's targets are backed by.
///
/// Reallocation is what this exists to avoid: a target is remade only when the
/// frame size changes or the graph itself is replaced, so a steady window keeps
/// every texture it has for as long as it runs.
pub struct TargetStore<T> {
    targets: Vec<T>,
    depth: Option<T>,
    width: u32,
    height: u32,
    generation: u64,
}

impl<T> Default for TargetStore<T> {
    fn default() -> Self {
        Self {
            targets: Vec::new(),
            depth: None,
            width: 0,
            height: 0,
            generation: 0,
        }
    }
}

impl<T> TargetStore<T> {
    /// Allocates whatever the graph needs at this frame size, and nothing that
    /// is already the right size.
    ///
    /// `generation` identifies the graph. A different one reallocates
    /// everything, because a replaced graph may have renamed, reformatted or
    /// rescaled any target while keeping the count.
    pub fn ensure<A: TargetAllocator<Target = T>>(
        &mut self,
        graph: &Graph,
        generation: u64,
        width: u32,
        height: u32,
        allocator: &mut A,
    ) {
        if self.width == width && self.height == height && self.generation == generation {
            return;
        }
        // Dropped before the replacements are built rather than after, so a
        // frame that grows does not hold two full sets of attachments at once.
        self.targets.clear();
        self.depth = None;
        self.width = width;
        self.height = height;
        self.generation = generation;

        for index in 0..graph.targets().len() {
            let (target_width, target_height) = graph.target_size(index, width, height);
            let target = &graph.targets()[index];
            self.targets.push(allocator.create(
                &target.name,
                target.format,
                target_width,
                target_height,
            ));
        }
        if graph.needs_depth() {
            self.depth = Some(allocator.create_depth(width, height));
        }
    }

    pub fn target(&self, index: usize) -> &T {
        &self.targets[index]
    }

    pub fn depth(&self) -> Option<&T> {
        self.depth.as_ref()
    }

    pub fn size(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    /// Forgets every texture, so the next `ensure` allocates again.
    ///
    /// A lost device is what calls this: the textures belonged to a device that
    /// no longer exists, and nothing may hand one to the replacement.
    pub fn clear(&mut self) {
        self.targets.clear();
        self.depth = None;
        self.width = 0;
        self.height = 0;
    }
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
            .context("render graph section ended in the middle of a word")?;
        self.at += 4;
        Ok(u32::from_ne_bytes(slice.try_into().expect("four bytes")))
    }

    fn f32(&mut self) -> Result<f32> {
        Ok(f32::from_bits(self.u32()?))
    }

    fn bytes(&mut self, count: usize) -> Result<&'a [u8]> {
        let slice = self
            .bytes
            .get(self.at..self.at + count)
            .context("render graph section is shorter than it declares")?;
        self.at += count;
        Ok(slice)
    }

    fn finish(&self) -> Result<()> {
        if self.at != self.bytes.len() {
            bail!(
                "render graph section is {} bytes and its records read {}",
                self.bytes.len(),
                self.at
            );
        }
        Ok(())
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;

    /// Builds the same section `tecs.gpu.passes.section` writes.
    pub struct GraphBuilder {
        names: Vec<String>,
        targets: Vec<Vec<u32>>,
        passes: Vec<Vec<u32>>,
    }

    impl GraphBuilder {
        pub fn new() -> Self {
            Self {
                names: Vec::new(),
                targets: Vec::new(),
                passes: Vec::new(),
            }
        }

        fn intern(&mut self, name: &str) -> u32 {
            if let Some(index) = self.names.iter().position(|held| held == name) {
                return index as u32;
            }
            self.names.push(name.to_owned());
            self.names.len() as u32 - 1
        }

        pub fn target(mut self, name: &str, format: u32, scale: f32, clear: Option<f32>) -> Self {
            let index = self.intern(name);
            let value = clear.unwrap_or(0.0);
            self.targets.push(vec![
                index,
                format,
                scale.to_bits(),
                u32::from(clear.is_some()),
                value.to_bits(),
                value.to_bits(),
                value.to_bits(),
                value.to_bits(),
            ]);
            self
        }

        pub fn pass(
            mut self,
            name: &str,
            inputs: &[&str],
            outputs: &[&str],
            depth: u32,
            clear_mode: u32,
        ) -> Self {
            let index = self.intern(name);
            let inputs: Vec<u32> = inputs.iter().map(|value| self.intern(value)).collect();
            let outputs: Vec<u32> = outputs.iter().map(|value| self.intern(value)).collect();
            let mut record = vec![
                index,
                depth,
                u32::from(depth == 1),
                1.0_f32.to_bits(),
                clear_mode,
                0,
                0,
                0,
                0,
                inputs.len() as u32,
                outputs.len() as u32,
            ];
            record.extend_from_slice(&inputs);
            record.extend_from_slice(&outputs);
            self.passes.push(record);
            self
        }

        pub fn build(self) -> Vec<u8> {
            let mut blob = Vec::new();
            for name in &self.names {
                blob.extend_from_slice(name.as_bytes());
                blob.push(0);
            }
            while blob.len() % 4 != 0 {
                blob.push(0);
            }

            let mut bytes = Vec::new();
            bytes.extend_from_slice(&(self.names.len() as u32).to_ne_bytes());
            bytes.extend_from_slice(&(blob.len() as u32).to_ne_bytes());
            bytes.extend_from_slice(&blob);
            bytes.extend_from_slice(&(self.targets.len() as u32).to_ne_bytes());
            for record in &self.targets {
                for value in record {
                    bytes.extend_from_slice(&value.to_ne_bytes());
                }
            }
            bytes.extend_from_slice(&(self.passes.len() as u32).to_ne_bytes());
            for record in &self.passes {
                for value in record {
                    bytes.extend_from_slice(&value.to_ne_bytes());
                }
            }
            bytes
        }
    }

    /// The deferred graph as `tecs.gpu.passes` declares it.
    pub fn deferred() -> Vec<u8> {
        GraphBuilder::new()
            .target("albedo", 0, 1.0, Some(0.0))
            .target("normal", 0, 1.0, Some(0.5))
            .target("orm", 0, 1.0, Some(1.0))
            .target("emission", 0, 1.0, Some(0.0))
            .target("lit", 1, 1.0, Some(0.0))
            .target("scene", 0, 1.0, None)
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
            .pass("forward", &[], &["scene"], 2, 1)
            .pass("present", &["scene"], &[], 0, 2)
            .build()
    }

    #[derive(Default)]
    struct CountingAllocator {
        created: Vec<(String, u32, u32)>,
        depths: u32,
    }

    impl TargetAllocator for CountingAllocator {
        type Target = String;

        fn create(
            &mut self,
            name: &str,
            _format: TargetFormat,
            width: u32,
            height: u32,
        ) -> Self::Target {
            self.created.push((name.to_owned(), width, height));
            format!("{name}@{width}x{height}")
        }

        fn create_depth(&mut self, width: u32, height: u32) -> Self::Target {
            self.depths += 1;
            format!("depth@{width}x{height}")
        }
    }

    #[test]
    fn decodes_the_deferred_graph_in_declaration_order() {
        let graph = parse_graph(&deferred()).expect("valid graph");
        let names: Vec<&str> = graph
            .targets()
            .iter()
            .map(|target| target.name.as_str())
            .collect();
        assert_eq!(
            names,
            ["albedo", "normal", "orm", "emission", "lit", "scene"]
        );
        let passes: Vec<&str> = graph
            .passes()
            .iter()
            .map(|pass| pass.name.as_str())
            .collect();
        assert_eq!(
            passes,
            ["geometry", "lighting", "composite", "forward", "present"]
        );
        assert_eq!(graph.targets()[4].format, TargetFormat::Rgba16Float);
        assert_eq!(graph.targets()[5].clear, None);
        assert_eq!(graph.passes()[0].depth, DepthMode::TestWrite);
        assert_eq!(graph.passes()[0].depth_clear, Some(1.0));
        assert_eq!(graph.passes()[3].depth, DepthMode::Test);
        assert_eq!(graph.passes()[3].clear, ClearMode::Load);
        assert!(matches!(graph.passes()[4].clear, ClearMode::Override(_)));
        assert!(
            graph.passes()[4].outputs.is_empty(),
            "present writes the swapchain"
        );
        assert_eq!(
            graph.passes()[1].inputs,
            [
                Input::Target(0),
                Input::Target(1),
                Input::Target(2),
                Input::Target(3)
            ]
        );
        assert!(graph.needs_depth());
    }

    #[test]
    fn resolves_the_shared_depth_attachment_by_name() {
        let bytes = GraphBuilder::new()
            .target("albedo", 0, 1.0, Some(0.0))
            .target("ao", 2, 0.5, Some(1.0))
            .pass("geometry", &[], &["albedo"], 1, 0)
            .pass("ao", &["albedo", "depth"], &["ao"], 0, 0)
            .build();
        let graph = parse_graph(&bytes).expect("valid graph");
        assert_eq!(graph.passes()[1].inputs, [Input::Target(0), Input::Depth]);
    }

    #[test]
    fn refuses_a_graph_that_cannot_run() {
        let reading_ahead = GraphBuilder::new()
            .target("albedo", 0, 1.0, None)
            .pass("early", &["albedo"], &[], 0, 0)
            .build();
        let message = parse_graph(&reading_ahead).unwrap_err().to_string();
        assert!(message.contains("before any pass writes it"), "{message}");

        let unknown_input = GraphBuilder::new()
            .pass("early", &["nothing"], &[], 0, 0)
            .build();
        let message = parse_graph(&unknown_input).unwrap_err().to_string();
        assert!(message.contains("reads undeclared target"), "{message}");

        let unknown_output = GraphBuilder::new()
            .pass("early", &[], &["nothing"], 0, 0)
            .build();
        let message = parse_graph(&unknown_output).unwrap_err().to_string();
        assert!(message.contains("writes undeclared target"), "{message}");

        let early_depth = GraphBuilder::new()
            .pass("early", &["depth"], &[], 0, 0)
            .build();
        let message = parse_graph(&early_depth).unwrap_err().to_string();
        assert!(message.contains("reads depth before"), "{message}");

        let duplicate = GraphBuilder::new()
            .target("albedo", 0, 1.0, None)
            .pass("one", &[], &["albedo"], 0, 0)
            .pass("one", &[], &["albedo"], 0, 0)
            .build();
        let message = parse_graph(&duplicate).unwrap_err().to_string();
        assert!(message.contains("declares pass 'one' twice"), "{message}");

        let scaled_depth = GraphBuilder::new()
            .target("half", 0, 0.5, None)
            .pass("small", &[], &["half"], 1, 0)
            .build();
        let message = parse_graph(&scaled_depth).unwrap_err().to_string();
        assert!(
            message.contains("depth attachment is frame sized"),
            "{message}"
        );

        let reserved = GraphBuilder::new().target("depth", 0, 1.0, None).build();
        let message = parse_graph(&reserved).unwrap_err().to_string();
        assert!(
            message.contains("reserved for the depth attachment"),
            "{message}"
        );

        let bad_format = GraphBuilder::new().target("albedo", 9, 1.0, None).build();
        let message = parse_graph(&bad_format).unwrap_err().to_string();
        assert!(message.contains("target format 9"), "{message}");

        let bad_scale = GraphBuilder::new().target("albedo", 0, 0.0, None).build();
        let message = parse_graph(&bad_scale).unwrap_err().to_string();
        assert!(message.contains("not above zero"), "{message}");
    }

    #[test]
    fn refuses_a_section_with_trailing_bytes() {
        let mut bytes = deferred();
        bytes.push(0);
        let message = parse_graph(&bytes).unwrap_err().to_string();
        assert!(message.contains("records read"), "{message}");

        let mut truncated = deferred();
        truncated.truncate(truncated.len() - 4);
        assert!(parse_graph(&truncated).is_err());
    }

    #[test]
    fn scales_a_target_down_and_never_to_nothing() {
        let bytes = GraphBuilder::new()
            .target("full", 0, 1.0, None)
            .target("half", 0, 0.5, None)
            .target("tiny", 0, 0.01, None)
            .build();
        let graph = parse_graph(&bytes).expect("valid graph");
        assert_eq!(graph.target_size(0, 1920, 1080), (1920, 1080));
        assert_eq!(graph.target_size(1, 1921, 1081), (960, 540));
        assert_eq!(graph.target_size(2, 32, 32), (1, 1));
    }

    #[test]
    fn allocates_once_and_reuses_until_the_size_changes() {
        let graph = parse_graph(&deferred()).expect("valid graph");
        let mut allocator = CountingAllocator::default();
        let mut store = TargetStore::default();

        store.ensure(&graph, 1, 800, 600, &mut allocator);
        assert_eq!(allocator.created.len(), 6);
        assert_eq!(allocator.depths, 1);
        assert_eq!(store.target(0), "albedo@800x600");
        assert_eq!(store.depth().map(String::as_str), Some("depth@800x600"));

        store.ensure(&graph, 1, 800, 600, &mut allocator);
        assert_eq!(
            allocator.created.len(),
            6,
            "a steady frame allocates nothing"
        );

        store.ensure(&graph, 1, 1024, 768, &mut allocator);
        assert_eq!(allocator.created.len(), 12);
        assert_eq!(store.size(), (1024, 768));

        // A replaced graph may have renamed, reformatted or rescaled any target
        // while keeping the count, so a new generation reallocates.
        store.ensure(&graph, 2, 1024, 768, &mut allocator);
        assert_eq!(allocator.created.len(), 18);

        store.clear();
        store.ensure(&graph, 2, 1024, 768, &mut allocator);
        assert_eq!(
            allocator.created.len(),
            24,
            "a lost device drops every texture"
        );
    }

    #[test]
    fn allocates_no_depth_for_a_graph_that_never_tests_it() {
        let bytes = GraphBuilder::new()
            .target("scene", 0, 1.0, None)
            .pass("draw", &[], &["scene"], 0, 0)
            .pass("present", &["scene"], &[], 0, 0)
            .build();
        let graph = parse_graph(&bytes).expect("valid graph");
        assert!(!graph.needs_depth());

        let mut allocator = CountingAllocator::default();
        let mut store = TargetStore::default();
        store.ensure(&graph, 1, 640, 360, &mut allocator);
        assert_eq!(allocator.depths, 0);
        assert!(store.depth().is_none());
    }
}
