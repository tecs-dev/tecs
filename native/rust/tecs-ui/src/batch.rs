//! Dirty retained-tree synchronization. One owned input and one copied result.
use super::*;
use serde_json::{json, Value};
use std::collections::HashSet;

fn number(value: &Value, fallback: f32) -> Result<f32, String> {
    if value.is_null() {
        return Ok(fallback);
    }
    let n = value.as_f64().ok_or("UI dimension must be numeric")? as f32;
    if !n.is_finite() {
        return Err("UI dimension must be finite".into());
    }
    Ok(n)
}
fn dim(value: &Value) -> Result<TecsUiDimension, String> {
    let (value, unit) = if value.is_null() || value == "auto" {
        (0., 0)
    } else if let Some(text) = value.as_str() {
        let (text, scale, unit) = if let Some(n) = text.strip_suffix("px") {
            (n, 1., 1)
        } else if let Some(n) = text.strip_suffix('%') {
            (n, 0.01, 2)
        } else {
            return Err(format!("invalid UI dimension {text:?}"));
        };
        let value = text.parse::<f32>().map_err(|_| "invalid UI dimension")? * scale;
        if !value.is_finite() {
            return Err("UI dimension must be finite".into());
        }
        (value, unit)
    } else {
        (number(value, 0.)?, 1)
    };
    Ok(TecsUiDimension {
        value,
        unit,
        _padding: [0; 3],
    })
}
fn edge(value: &Value) -> Result<TecsUiEdges, String> {
    let get = |key| {
        if value.is_object() {
            &value[key]
        } else {
            value
        }
    };
    Ok(TecsUiEdges {
        left: dim(get("left"))?,
        right: dim(get("right"))?,
        top: dim(get("top"))?,
        bottom: dim(get("bottom"))?,
    })
}
fn choice(value: &Value, names: &[&str]) -> Result<u8, String> {
    if value.is_null() {
        return Ok(0);
    }
    names
        .iter()
        .position(|name| value == *name)
        .map(|n| n as u8)
        .ok_or_else(|| format!("invalid UI style value {value}"))
}
fn read_style(v: &Value) -> Result<TecsUiStyle, String> {
    Ok(TecsUiStyle {
        display: choice(&v["display"], &["flex", "none", "grid", "block"])?,
        position: choice(&v["position"], &["relative", "absolute"])?,
        flex_direction: choice(
            &v["flexDirection"],
            &["row", "rowReverse", "column", "columnReverse"],
        )?,
        flex_wrap: choice(&v["flexWrap"], &["nowrap", "wrap"])?,
        justify_content: choice(
            &v["justifyContent"],
            &[
                "start",
                "center",
                "end",
                "spaceBetween",
                "spaceAround",
                "spaceEvenly",
            ],
        )?,
        align_items: choice(
            &v["alignItems"],
            &["stretch", "center", "end", "baseline", "start"],
        )?,
        align_content: choice(
            &v["alignContent"],
            &[
                "stretch",
                "center",
                "end",
                "spaceBetween",
                "spaceAround",
                "spaceEvenly",
                "start",
            ],
        )?,
        _padding0: 0,
        flex_grow: number(&v["flexGrow"], 0.)?,
        flex_shrink: number(&v["flexShrink"], 1.)?,
        flex_basis: dim(&v["flexBasis"])?,
        width: dim(&v["width"])?,
        height: dim(&v["height"])?,
        min_width: dim(&v["minWidth"])?,
        min_height: dim(&v["minHeight"])?,
        max_width: dim(&v["maxWidth"])?,
        max_height: dim(&v["maxHeight"])?,
        margin: edge(v.get("margin").unwrap_or(&Value::from(0)))?,
        padding: edge(&v["padding"])?,
        border: edge(&v["border"])?,
        gap_width: dim(&v["gap"])?,
        gap_height: dim(v.get("rowGap").unwrap_or(&v["gap"]))?,
        inset: edge(&v["inset"])?,
    })
}
struct Node {
    id: u64,
    style: TecsUiStyle,
    measure: TecsUiMeasure,
    children: Vec<u64>,
    width: f32,
    height: f32,
    root: bool,
}
fn read_nodes(input: &[u8]) -> Result<Vec<Node>, String> {
    let data: Value = serde_json::from_slice(input).map_err(|e| e.to_string())?;
    let mut nodes = Vec::new();
    let mut ids = HashSet::new();
    for v in data.as_array().ok_or("UI batch must be an array")? {
        let id = v["id"]
            .as_u64()
            .filter(|id| *id > 0)
            .ok_or("invalid UI entity")?;
        if !ids.insert(id) {
            return Err("duplicate UI entity".into());
        }
        let children = v["children"]
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|v| v.as_u64().ok_or("invalid UI child".to_string()))
                    .collect::<Result<Vec<_>, _>>()
            })
            .transpose()?
            .unwrap_or_default();
        let m = &v["measure"];
        nodes.push(Node {
            id,
            style: read_style(&v["style"])?,
            children,
            measure: TecsUiMeasure {
                kind: m["kind"].as_u64().unwrap_or(0) as u8,
                _padding: [0; 3],
                width: number(&m["width"], 0.)?,
                height: number(&m["height"], 0.)?,
                min_width: number(&m["minWidth"], 0.)?,
                measured_width: number(&m["measuredWidth"], 0.)?,
                measured_height: number(&m["measuredHeight"], 0.)?,
            },
            width: number(&v["width"], 0.)?,
            height: number(&v["height"], 0.)?,
            root: v["root"] == true,
        });
    }
    let mut parents = HashMap::new();
    for n in &nodes {
        for child in &n.children {
            if !ids.contains(child) || parents.insert(*child, n.id).is_some() {
                return Err("UI child is missing or has multiple parents".into());
            }
        }
    }
    for id in &ids {
        let mut seen = HashSet::new();
        let mut cursor = *id;
        while let Some(parent) = parents.get(&cursor) {
            if !seen.insert(cursor) {
                return Err("UI hierarchy contains a cycle".into());
            }
            cursor = *parent;
        }
    }
    Ok(nodes)
}
fn sync(tree: &mut TecsUiTree, input: &[u8]) -> Result<String, String> {
    let nodes = read_nodes(input)?;
    let ids: HashSet<_> = nodes.iter().map(|n| n.id).collect();
    let removed: Vec<_> = tree
        .nodes
        .keys()
        .filter(|id| !ids.contains(id))
        .copied()
        .collect();
    let check = |ok| {
        if ok {
            Ok(())
        } else {
            Err(ERROR.with(|e| e.borrow().to_string_lossy().into_owned()))
        }
    };
    for id in removed {
        check(unsafe { tecsUiTreeRemove(tree, id) })?;
    }
    for n in &nodes {
        check(unsafe { tecsUiTreeInsert(tree, n.id, &n.style) })?;
        check(unsafe { tecsUiTreeSetStyle(tree, n.id, &n.style) })?;
        check(unsafe { tecsUiTreeSetMeasure(tree, n.id, &n.measure) })?;
    }
    for n in &nodes {
        let id = tree.nodes[&n.id];
        let mapped: Vec<_> = n.children.iter().map(|id| tree.nodes[id]).collect();
        if tree.tree.children(id).map_err(|e| e.to_string())? != mapped {
            check(unsafe {
                tecsUiTreeSetChildren(tree, n.id, n.children.as_ptr(), n.children.len())
            })?;
        }
    }
    check(unsafe { tecsUiTreeBegin(tree) })?;
    for n in &nodes {
        if n.root {
            check(unsafe { tecsUiTreeCompute(tree, n.id, n.width, n.height) })?;
        }
    }
    let changes:Vec<_>=tree.changes.iter().map(|c|json!({"id":c.entity,"x":c.x,"y":c.y,"width":c.width,"height":c.height,"contentWidth":c.content_width,"contentHeight":c.content_height})).collect();
    serde_json::to_string(&changes).map_err(|e| e.to_string())
}
/// Synchronizes the retained tree and returns an owned UTF-8 result, or null.
/// # Safety
/// The tree must be live and the input must name `length` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn tecsUiTreeSync(
    tree: *mut TecsUiTree,
    input: *const u8,
    length: u64,
) -> *mut c_char {
    if tree.is_null() || input.is_null() {
        set_error("null UI batch");
        return std::ptr::null_mut();
    }
    match sync(unsafe { &mut *tree }, unsafe {
        slice::from_raw_parts(input, length as usize)
    }) {
        Ok(text) => CString::new(text).unwrap().into_raw(),
        Err(e) => {
            set_error(e);
            std::ptr::null_mut()
        }
    }
}
/// Releases a result from `tecsUiTreeSync`.
/// # Safety
/// The pointer must be null or an unreleased result from this library.
#[no_mangle]
pub unsafe extern "C" fn tecsUiResultDestroy(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn retains_layout_and_rejects_cycles() {
        let tree = tecsUiTreeCreate();
        let source=br#"[{"id":1,"root":true,"width":300,"height":100,"style":{"width":"100%","height":"100%","gap":10},"children":[2,3]},{"id":2,"style":{"width":50,"height":20}},{"id":3,"style":{"flexGrow":1,"height":30}}]"#;
        let tree = unsafe { &mut *tree };
        let result: Value = serde_json::from_str(&sync(tree, source).unwrap()).unwrap();
        assert_eq!(result.as_array().unwrap().len(), 3);
        let child = &tree.layouts[&3];
        assert_eq!(child.x, 60.);
        assert_eq!(child.width, 240.);
        assert_eq!(sync(tree, source).unwrap(), "[]");
        assert!(sync(
            tree,
            br#"[{"id":1,"children":[2]},{"id":2,"children":[1]}]"#
        )
        .unwrap_err()
        .contains("cycle"));
        assert!(read_style(&json!({"width":"wat"})).is_err());
        unsafe { tecsUiTreeDestroy(tree) };
    }
}
