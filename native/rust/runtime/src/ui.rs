//! Retained Taffy trees keyed by ECS entity id.
//!
//! This is intentionally a layout service rather than a UI toolkit. Lua owns
//! component state, hierarchy, drawing and input; this module remembers only
//! the Taffy nodes needed to calculate derived boxes.

use std::collections::HashMap;
use std::slice;

use taffy::prelude::*;
use taffy::tree::NodeId;
use taffy::TaffyTree;

use crate::set_error;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TecsUiDimension {
    pub value: f32,
    pub unit: u8,
    pub _padding: [u8; 3],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TecsUiEdges {
    pub left: TecsUiDimension,
    pub right: TecsUiDimension,
    pub top: TecsUiDimension,
    pub bottom: TecsUiDimension,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TecsUiStyle {
    pub display: u8,
    pub position: u8,
    pub flex_direction: u8,
    pub flex_wrap: u8,
    pub justify_content: u8,
    pub align_items: u8,
    pub align_content: u8,
    pub _padding0: u8,
    pub flex_grow: f32,
    pub flex_shrink: f32,
    pub flex_basis: TecsUiDimension,
    pub width: TecsUiDimension,
    pub height: TecsUiDimension,
    pub min_width: TecsUiDimension,
    pub min_height: TecsUiDimension,
    pub max_width: TecsUiDimension,
    pub max_height: TecsUiDimension,
    pub margin: TecsUiEdges,
    pub padding: TecsUiEdges,
    pub border: TecsUiEdges,
    pub gap_width: TecsUiDimension,
    pub gap_height: TecsUiDimension,
    pub inset: TecsUiEdges,
}

#[repr(C)]
pub struct TecsUiLayout {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub changed: u8,
    pub _padding: [u8; 3],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TecsUiLayoutChange {
    pub entity: u64,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

pub struct TecsUiTree {
    tree: TaffyTree<()>,
    nodes: HashMap<u64, NodeId>,
    entities: HashMap<NodeId, u64>,
    layouts: HashMap<u64, (f32, f32, f32, f32)>,
    root_spaces: HashMap<u64, (f32, f32)>,
    changes: Vec<TecsUiLayoutChange>,
    #[cfg(test)]
    computed_roots: usize,
}

fn dimension(value: TecsUiDimension) -> Dimension {
    match value.unit {
        1 => Dimension::length(value.value),
        2 => Dimension::percent(value.value),
        _ => Dimension::auto(),
    }
}

fn length(value: TecsUiDimension) -> LengthPercentageAuto {
    match value.unit {
        1 => LengthPercentageAuto::length(value.value),
        2 => LengthPercentageAuto::percent(value.value),
        _ => LengthPercentageAuto::auto(),
    }
}

fn edges(value: TecsUiEdges) -> Rect<LengthPercentageAuto> {
    Rect {
        left: length(value.left),
        right: length(value.right),
        top: length(value.top),
        bottom: length(value.bottom),
    }
}

fn length_or_zero(value: TecsUiDimension) -> LengthPercentage {
    match value.unit {
        1 => LengthPercentage::length(value.value),
        2 => LengthPercentage::percent(value.value),
        _ => LengthPercentage::ZERO,
    }
}

fn style(value: &TecsUiStyle) -> Style {
    Style {
        display: match value.display {
            1 => Display::None,
            2 => Display::Grid,
            3 => Display::Block,
            _ => Display::Flex,
        },
        position: if value.position == 1 {
            Position::Absolute
        } else {
            Position::Relative
        },
        flex_direction: match value.flex_direction {
            1 => FlexDirection::RowReverse,
            2 => FlexDirection::Column,
            3 => FlexDirection::ColumnReverse,
            _ => FlexDirection::Row,
        },
        flex_wrap: if value.flex_wrap == 1 {
            FlexWrap::Wrap
        } else {
            FlexWrap::NoWrap
        },
        justify_content: match value.justify_content {
            1 => Some(JustifyContent::CENTER),
            2 => Some(JustifyContent::FLEX_END),
            3 => Some(JustifyContent::SPACE_BETWEEN),
            4 => Some(JustifyContent::SPACE_AROUND),
            5 => Some(JustifyContent::SPACE_EVENLY),
            _ => Some(JustifyContent::FLEX_START),
        },
        align_items: match value.align_items {
            1 => Some(AlignItems::CENTER),
            2 => Some(AlignItems::FLEX_END),
            3 => Some(AlignItems::BASELINE),
            _ => Some(AlignItems::STRETCH),
        },
        align_content: match value.align_content {
            1 => Some(AlignContent::CENTER),
            2 => Some(AlignContent::FLEX_END),
            3 => Some(AlignContent::SPACE_BETWEEN),
            4 => Some(AlignContent::SPACE_AROUND),
            5 => Some(AlignContent::SPACE_EVENLY),
            _ => Some(AlignContent::STRETCH),
        },
        flex_grow: value.flex_grow,
        flex_shrink: value.flex_shrink,
        flex_basis: dimension(value.flex_basis),
        size: Size {
            width: dimension(value.width),
            height: dimension(value.height),
        },
        min_size: Size {
            width: dimension(value.min_width),
            height: dimension(value.min_height),
        },
        max_size: Size {
            width: dimension(value.max_width),
            height: dimension(value.max_height),
        },
        margin: edges(value.margin),
        padding: Rect {
            left: length_or_zero(value.padding.left),
            right: length_or_zero(value.padding.right),
            top: length_or_zero(value.padding.top),
            bottom: length_or_zero(value.padding.bottom),
        },
        border: Rect {
            left: length_or_zero(value.border.left),
            right: length_or_zero(value.border.right),
            top: length_or_zero(value.border.top),
            bottom: length_or_zero(value.border.bottom),
        },
        gap: Size {
            width: length_or_zero(value.gap_width),
            height: length_or_zero(value.gap_height),
        },
        inset: edges(value.inset),
        ..Style::DEFAULT
    }
}

fn fail(message: impl ToString) -> bool {
    set_error(message);
    false
}

#[no_mangle]
pub extern "C" fn tecsUiTreeCreate() -> *mut TecsUiTree {
    Box::into_raw(Box::new(TecsUiTree {
        tree: TaffyTree::new(),
        nodes: HashMap::new(),
        entities: HashMap::new(),
        layouts: HashMap::new(),
        root_spaces: HashMap::new(),
        changes: Vec::new(),
        #[cfg(test)]
        computed_roots: 0,
    }))
}

#[no_mangle]
pub unsafe extern "C" fn tecsUiTreeDestroy(tree: *mut TecsUiTree) {
    if !tree.is_null() {
        drop(unsafe { Box::from_raw(tree) });
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsUiTreeInsert(
    tree: *mut TecsUiTree,
    entity: u64,
    value: *const TecsUiStyle,
) -> bool {
    let Some(tree) = (unsafe { tree.as_mut() }) else {
        return fail("UI tree is null");
    };
    let Some(value) = (unsafe { value.as_ref() }) else {
        return fail("UI style is null");
    };
    if tree.nodes.contains_key(&entity) {
        return true;
    }
    match tree.tree.new_leaf(style(value)) {
        Ok(node) => {
            tree.nodes.insert(entity, node);
            tree.entities.insert(node, entity);
            true
        }
        Err(error) => fail(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsUiTreeRemove(tree: *mut TecsUiTree, entity: u64) -> bool {
    let Some(tree) = (unsafe { tree.as_mut() }) else {
        return fail("UI tree is null");
    };
    let Some(node) = tree.nodes.remove(&entity) else {
        return true;
    };
    tree.entities.remove(&node);
    tree.layouts.remove(&entity);
    tree.root_spaces.remove(&entity);
    tree.tree.remove(node).map(|_| true).unwrap_or_else(fail)
}

#[no_mangle]
pub unsafe extern "C" fn tecsUiTreeSetStyle(
    tree: *mut TecsUiTree,
    entity: u64,
    value: *const TecsUiStyle,
) -> bool {
    let Some(tree) = (unsafe { tree.as_mut() }) else {
        return fail("UI tree is null");
    };
    let Some(value) = (unsafe { value.as_ref() }) else {
        return fail("UI style is null");
    };
    let Some(node) = tree.nodes.get(&entity).copied() else {
        return fail("UI entity has no Taffy node");
    };
    let next = style(value);
    if tree.tree.style(node).is_ok_and(|current| current == &next) {
        return true;
    }
    tree.tree
        .set_style(node, next)
        .map(|_| true)
        .unwrap_or_else(fail)
}

#[no_mangle]
pub unsafe extern "C" fn tecsUiTreeSetChildren(
    tree: *mut TecsUiTree,
    entity: u64,
    children: *const u64,
    count: usize,
) -> bool {
    let Some(tree) = (unsafe { tree.as_mut() }) else {
        return fail("UI tree is null");
    };
    let Some(node) = tree.nodes.get(&entity).copied() else {
        return fail("UI entity has no Taffy node");
    };
    let ids = if count == 0 {
        &[]
    } else if children.is_null() {
        return fail("UI children are null");
    } else {
        unsafe { slice::from_raw_parts(children, count) }
    };
    let mut mapped = Vec::with_capacity(ids.len());
    for child in ids {
        let Some(child) = tree.nodes.get(child).copied() else {
            return fail("UI child has no Taffy node");
        };
        mapped.push(child);
    }
    tree.tree
        .set_children(node, &mapped)
        .map(|_| true)
        .unwrap_or_else(fail)
}

#[no_mangle]
pub unsafe extern "C" fn tecsUiTreeInvalidateRoot(tree: *mut TecsUiTree, entity: u64) -> bool {
    let Some(tree) = (unsafe { tree.as_mut() }) else {
        return fail("UI tree is null");
    };
    tree.root_spaces.remove(&entity);
    true
}

#[no_mangle]
pub unsafe extern "C" fn tecsUiTreeBegin(tree: *mut TecsUiTree) -> bool {
    let Some(tree) = (unsafe { tree.as_mut() }) else {
        return fail("UI tree is null");
    };
    tree.changes.clear();
    #[cfg(test)]
    {
        tree.computed_roots = 0;
    }
    true
}

#[no_mangle]
pub unsafe extern "C" fn tecsUiTreeCompute(
    tree: *mut TecsUiTree,
    root: u64,
    width: f32,
    height: f32,
) -> bool {
    let Some(tree) = (unsafe { tree.as_mut() }) else {
        return fail("UI tree is null");
    };
    let Some(node) = tree.nodes.get(&root).copied() else {
        return fail("UI root has no Taffy node");
    };
    let next_space = (width, height);
    let space_changed = tree.root_spaces.get(&root).copied() != Some(next_space);
    let dirty = match tree.tree.dirty(node) {
        Ok(dirty) => dirty,
        Err(error) => return fail(error),
    };
    if !space_changed && !dirty {
        return true;
    }
    tree.root_spaces.insert(root, next_space);
    #[cfg(test)]
    {
        tree.computed_roots += 1;
    }
    let space = Size {
        width: AvailableSpace::Definite(width),
        height: AvailableSpace::Definite(height),
    };
    if let Err(error) = tree.tree.compute_layout(node, space) {
        return fail(error);
    }
    let mut pending = vec![node];
    while let Some(node) = pending.pop() {
        if let (Some(entity), Ok(layout)) = (tree.entities.get(&node), tree.tree.layout(node)) {
            let next = (
                layout.location.x,
                layout.location.y,
                layout.size.width,
                layout.size.height,
            );
            if tree.layouts.get(entity).copied() != Some(next) {
                tree.changes.push(TecsUiLayoutChange {
                    entity: *entity,
                    x: next.0,
                    y: next.1,
                    width: next.2,
                    height: next.3,
                });
                tree.layouts.insert(*entity, next);
            }
        }
        match tree.tree.children(node) {
            Ok(children) => pending.extend(children),
            Err(error) => return fail(error),
        }
    }
    true
}

#[no_mangle]
pub unsafe extern "C" fn tecsUiTreeChanges(
    tree: *const TecsUiTree,
    count: *mut usize,
) -> *const TecsUiLayoutChange {
    let Some(count) = (unsafe { count.as_mut() }) else {
        set_error("UI change count is null");
        return std::ptr::null();
    };
    let Some(tree) = (unsafe { tree.as_ref() }) else {
        set_error("UI tree is null");
        *count = 0;
        return std::ptr::null();
    };
    *count = tree.changes.len();
    if tree.changes.is_empty() {
        std::ptr::null()
    } else {
        tree.changes.as_ptr()
    }
}

#[no_mangle]
pub unsafe extern "C" fn tecsUiTreeLayout(
    tree: *const TecsUiTree,
    entity: u64,
    output: *mut TecsUiLayout,
) -> bool {
    let Some(tree) = (unsafe { tree.as_ref() }) else {
        return fail("UI tree is null");
    };
    let Some(output) = (unsafe { output.as_mut() }) else {
        return fail("UI layout output is null");
    };
    let Some(&(x, y, width, height)) = tree.layouts.get(&entity) else {
        return false;
    };
    let next = (x, y, width, height);
    let previous = (output.x, output.y, output.width, output.height);
    output.x = x;
    output.y = y;
    output.width = width;
    output.height = height;
    output.changed = u8::from(previous != next);
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn auto() -> TecsUiDimension {
        TecsUiDimension {
            value: 0.0,
            unit: 0,
            _padding: [0; 3],
        }
    }

    fn points(value: f32) -> TecsUiDimension {
        TecsUiDimension {
            value,
            unit: 1,
            _padding: [0; 3],
        }
    }

    fn style(width: TecsUiDimension, height: TecsUiDimension) -> TecsUiStyle {
        let auto = auto();
        let edges = TecsUiEdges {
            left: auto,
            right: auto,
            top: auto,
            bottom: auto,
        };
        TecsUiStyle {
            display: 0,
            position: 0,
            flex_direction: 0,
            flex_wrap: 0,
            justify_content: 0,
            align_items: 0,
            align_content: 0,
            _padding0: 0,
            flex_grow: 0.0,
            flex_shrink: 1.0,
            flex_basis: auto,
            width,
            height,
            min_width: auto,
            min_height: auto,
            max_width: auto,
            max_height: auto,
            margin: edges,
            padding: edges,
            border: edges,
            gap_width: auto,
            gap_height: auto,
            inset: edges,
        }
    }

    #[test]
    fn retains_nodes_and_returns_changed_boxes() {
        let root = style(auto(), auto());
        let child = style(points(20.0), points(10.0));
        let tree = tecsUiTreeCreate();
        assert!(!tree.is_null());
        assert!(unsafe { tecsUiTreeInsert(tree, 1, &root) });
        assert!(unsafe { tecsUiTreeInsert(tree, 2, &child) });
        assert!(unsafe { tecsUiTreeInsert(tree, 3, &root) });
        assert!(unsafe { tecsUiTreeInsert(tree, 4, &child) });
        let children = [2_u64];
        assert!(unsafe { tecsUiTreeSetChildren(tree, 1, children.as_ptr(), children.len()) });
        let other_children = [4_u64];
        assert!(unsafe {
            tecsUiTreeSetChildren(tree, 3, other_children.as_ptr(), other_children.len())
        });
        assert!(unsafe { tecsUiTreeBegin(tree) });
        assert!(unsafe { tecsUiTreeCompute(tree, 1, 100.0, 50.0) });
        assert!(unsafe { tecsUiTreeCompute(tree, 3, 100.0, 50.0) });
        assert_eq!(unsafe { (*tree).computed_roots }, 2);

        let mut count = 0;
        let changes = unsafe { tecsUiTreeChanges(tree, &mut count) };
        assert!(!changes.is_null());
        assert_eq!(count, 4);

        let mut output = TecsUiLayout {
            x: 0.0,
            y: 0.0,
            width: 0.0,
            height: 0.0,
            changed: 0,
            _padding: [0; 3],
        };
        assert!(unsafe { tecsUiTreeLayout(tree, 2, &mut output) });
        assert_eq!(
            (output.x, output.y, output.width, output.height),
            (0.0, 0.0, 20.0, 10.0)
        );
        assert_eq!(output.changed, 1);
        assert!(unsafe { tecsUiTreeLayout(tree, 2, &mut output) });
        assert_eq!(output.changed, 0);

        assert!(unsafe { tecsUiTreeBegin(tree) });
        assert!(unsafe { tecsUiTreeCompute(tree, 1, 100.0, 50.0) });
        assert!(unsafe { tecsUiTreeCompute(tree, 3, 100.0, 50.0) });
        assert_eq!(unsafe { (*tree).computed_roots }, 0);
        let changes = unsafe { tecsUiTreeChanges(tree, &mut count) };
        assert!(changes.is_null());
        assert_eq!(count, 0);

        assert!(unsafe { tecsUiTreeSetStyle(tree, 2, &child) });
        assert!(unsafe { tecsUiTreeBegin(tree) });
        assert!(unsafe { tecsUiTreeCompute(tree, 1, 100.0, 50.0) });
        assert!(unsafe { tecsUiTreeCompute(tree, 3, 100.0, 50.0) });
        assert_eq!(unsafe { (*tree).computed_roots }, 0);

        let wider = style(points(30.0), points(10.0));
        assert!(unsafe { tecsUiTreeSetStyle(tree, 2, &wider) });
        assert!(unsafe { tecsUiTreeBegin(tree) });
        assert!(unsafe { tecsUiTreeCompute(tree, 1, 100.0, 50.0) });
        assert!(unsafe { tecsUiTreeCompute(tree, 3, 100.0, 50.0) });
        assert_eq!(unsafe { (*tree).computed_roots }, 1);
        let changes = unsafe { tecsUiTreeChanges(tree, &mut count) };
        let changed = unsafe { slice::from_raw_parts(changes, count) };
        assert_eq!(count, 2);
        assert!(changed.iter().any(|change| change.entity == 2));
        assert!(changed
            .iter()
            .all(|change| change.entity == 1 || change.entity == 2));

        assert!(unsafe { tecsUiTreeBegin(tree) });
        assert!(unsafe { tecsUiTreeCompute(tree, 1, 100.0, 50.0) });
        assert!(unsafe { tecsUiTreeCompute(tree, 3, 120.0, 50.0) });
        assert_eq!(unsafe { (*tree).computed_roots }, 1);

        assert!(unsafe { tecsUiTreeInvalidateRoot(tree, 1) });
        assert!(unsafe { tecsUiTreeBegin(tree) });
        assert!(unsafe { tecsUiTreeCompute(tree, 1, 100.0, 50.0) });
        assert!(unsafe { tecsUiTreeCompute(tree, 3, 120.0, 50.0) });
        assert_eq!(unsafe { (*tree).computed_roots }, 1);
        unsafe { tecsUiTreeDestroy(tree) };
    }
}
