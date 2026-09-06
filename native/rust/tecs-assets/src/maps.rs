//! Projects rs-tiled's parsed data into owned game-facing values.
use serde_json::{json, Value};
use std::path::Path;
use tiled::{LayerType, ObjectData, ObjectShape, PropertyValue, TileLayer};
fn property(v: &PropertyValue) -> Value {
    match v {
        PropertyValue::BoolValue(v) => json!(v),
        PropertyValue::FloatValue(v) => json!(v),
        PropertyValue::IntValue(v) => json!(v),
        PropertyValue::StringValue(v) | PropertyValue::FileValue(v) => json!(v),
        PropertyValue::ObjectValue(v) => json!(v),
        PropertyValue::ColorValue(v) => json!([v.red, v.green, v.blue, v.alpha]),
        PropertyValue::ListValue(v) => Value::Array(v.iter().map(property).collect()),
        PropertyValue::ClassValue {
            property_type,
            properties: p,
        } => json!({"class":property_type,"properties":properties(p)}),
    }
}
fn properties(p: &tiled::Properties) -> Value {
    Value::Object(p.iter().map(|(k, v)| (k.clone(), property(v))).collect())
}
fn object(v: &ObjectData) -> Value {
    let (shape, width, height, points, text) = match &v.shape {
        ObjectShape::Rect { width, height } => {
            ("rectangle", *width, *height, vec![], String::new())
        }
        ObjectShape::Ellipse { width, height } => {
            ("ellipse", *width, *height, vec![], String::new())
        }
        ObjectShape::Capsule { width, height } => {
            ("capsule", *width, *height, vec![], String::new())
        }
        ObjectShape::Polygon { points } => ("polygon", 0., 0., points.clone(), String::new()),
        ObjectShape::Polyline { points } => ("polyline", 0., 0., points.clone(), String::new()),
        ObjectShape::Point(..) => ("point", 0., 0., vec![], String::new()),
        ObjectShape::Text {
            width,
            height,
            text,
            ..
        } => ("text", *width, *height, vec![], text.clone()),
    };
    json!({"id":v.id(),"name":v.name,"class":v.user_type,"x":v.x,"y":v.y,"width":width,"height":height,"rotation":v.rotation,"visible":v.visible,"opacity":v.opacity,"shape":shape,"points":points,"text":text,"properties":properties(&v.properties)})
}
fn image(v: Option<&tiled::Image>) -> Value {
    match v {
        None => Value::Null,
        Some(v) => {
            json!({"path":v.source,"width":v.width,"height":v.height,"transparent":v.transparent_colour.map(|c|[c.red,c.green,c.blue])})
        }
    }
}
fn cell(x: i32, y: i32, t: tiled::LayerTile<'_>) -> Value {
    json!({"x":x,"y":y,"tileset":t.tileset_index()+1,"id":t.id(),"flipH":t.flip_h,"flipV":t.flip_v,"flipD":t.flip_d})
}
fn layer(v: tiled::Layer<'_>) -> Result<Value, String> {
    if v.blend_mode != "normal" {
        return Err(format!(
            "Tecs does not support Tiled blend mode {:?} in layer {:?}",
            v.blend_mode, v.name
        ));
    }
    let mut out = json!({"id":v.id(),"name":v.name,"visible":v.visible,"x":v.offset_x,"y":v.offset_y,"parallaxX":v.parallax_x,"parallaxY":v.parallax_y,"opacity":v.opacity,"tint":v.tint_color.map(|c|[c.red,c.green,c.blue,c.alpha]).unwrap_or([255;4]),"properties":properties(&v.properties),"cells":[],"objects":[],"layers":[],"width":0,"height":0,"repeatX":false,"repeatY":false});
    match v.layer_type() {
        LayerType::Tiles(tiles) => {
            out["kind"] = json!("tiles");
            let mut cells = Vec::new();
            match tiles {
                TileLayer::Finite(f) => {
                    out["width"] = json!(f.width());
                    out["height"] = json!(f.height());
                    for y in 0..f.height() as i32 {
                        for x in 0..f.width() as i32 {
                            if let Some(t) = f.get_tile(x, y) {
                                cells.push(cell(x, y, t));
                            }
                        }
                    }
                }
                TileLayer::Infinite(f) => {
                    for ((cx, cy), chunk) in f.chunks() {
                        for y in 0..tiled::ChunkData::HEIGHT as i32 {
                            for x in 0..tiled::ChunkData::WIDTH as i32 {
                                if let Some(t) = chunk.get_tile(x, y) {
                                    cells.push(cell(
                                        cx * tiled::ChunkData::WIDTH as i32 + x,
                                        cy * tiled::ChunkData::HEIGHT as i32 + y,
                                        t,
                                    ));
                                }
                            }
                        }
                    }
                }
            };
            cells.sort_by_key(|c| (c["y"].as_i64(), c["x"].as_i64()));
            out["cells"] = json!(cells);
        }
        LayerType::Objects(objects) => {
            out["kind"] = json!("objects");
            let values:Vec<_>=objects.objects().map(|o|{let mut value=object(&o);if let Some(tile)=o.get_tile(){value["tile"]=json!({"source":tile.get_tileset().source,"name":tile.get_tileset().name,"id":tile.id(),"flipH":tile.flip_h,"flipV":tile.flip_v,"flipD":tile.flip_d});}value}).collect();
            out["objects"] = json!(values);
        }
        LayerType::Image(v) => {
            out["kind"] = json!("image");
            out["image"] = image(v.image.as_ref());
            out["repeatX"] = json!(v.repeat_x);
            out["repeatY"] = json!(v.repeat_y);
        }
        LayerType::Group(v) => {
            out["kind"] = json!("group");
            out["layers"] = Value::Array(v.layers().map(layer).collect::<Result<_, _>>()?);
        }
    }
    Ok(out)
}
fn flatten(mut value: Value, parent: Option<&Value>, out: &mut Vec<Value>) {
    if let Some(parent) = parent {
        for key in ["x", "y"] {
            value[key] = json!(value[key].as_f64().unwrap() + parent[key].as_f64().unwrap());
        }
        for key in ["parallaxX", "parallaxY", "opacity"] {
            value[key] = json!(value[key].as_f64().unwrap() * parent[key].as_f64().unwrap());
        }
        value["visible"] = json!(value["visible"] == true && parent["visible"] == true);
        for i in 0..4 {
            value["tint"][i] = json!(
                value["tint"][i].as_f64().unwrap() * parent["tint"][i].as_f64().unwrap() / 255.
            );
        }
    }
    if value["kind"] == "group" {
        let children = value["layers"].take();
        for child in children.as_array().unwrap() {
            flatten(child.clone(), Some(&value), out);
        }
    } else {
        value.as_object_mut().unwrap().remove("layers");
        out.push(value);
    }
}
pub fn load(path: &Path) -> Result<Vec<u8>, String> {
    let map = tiled::Loader::new()
        .load_tmx_map(path)
        .map_err(|e| e.to_string())?;
    if map.orientation != tiled::Orientation::Orthogonal {
        return Err("Tecs currently renders orthogonal Tiled maps".into());
    }
    let mut sets = Vec::new();
    for ts in map.tilesets() {
        let mut tiles = Vec::new();
        for (id, t) in ts.tiles() {
            let collisions: Vec<_> = t
                .collision
                .as_ref()
                .map(|c| c.object_data().iter().map(object).collect())
                .unwrap_or_default();
            let frames: Vec<_> = t
                .animation
                .as_ref()
                .map(|a| {
                    a.iter()
                        .map(|f| json!({"id":f.tile_id,"duration":f.duration as f64/1000.}))
                        .collect()
                })
                .unwrap_or_default();
            tiles.push(json!({"id":id,"class":t.user_type,"properties":properties(&t.properties),"image":image(t.image.as_ref()),"collision":collisions,"animation":frames,"rect":t.image_rect.map(|r|[r.x,r.y,r.width,r.height])}));
        }
        tiles.sort_by_key(|t| t["id"].as_u64());
        sets.push(json!({"name":ts.name,"source":ts.source,"tileWidth":ts.tile_width,"tileHeight":ts.tile_height,"columns":ts.columns,"count":ts.tilecount,"spacing":ts.spacing,"margin":ts.margin,"alignment":format!("{:?}",ts.object_alignment),"x":ts.offset_x,"y":ts.offset_y,"image":image(ts.image.as_ref()),"tiles":tiles,"properties":properties(&ts.properties)}));
    }
    let mut layers = Vec::new();
    for source in map.layers() {
        flatten(layer(source)?, None, &mut layers);
    }
    serde_json::to_vec(&json!({"source":path,"parallaxX":map.parallax_origin_x,"parallaxY":map.parallax_origin_y,"width":map.width,"height":map.height,"tileWidth":map.tile_width,"tileHeight":map.tile_height,"infinite":map.infinite(),"properties":properties(&map.properties),"tilesets":sets,"layers":layers})).map_err(|e|e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(name: &str) -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../tests/fixtures/tiled/maps")
            .join(name)
    }
    #[test]
    fn resolves_external_tilesets_and_group_properties() {
        let value: Value = serde_json::from_slice(&load(&fixture("level.tmx")).unwrap()).unwrap();
        assert_eq!(value["layers"][0]["x"], 8.0);
        assert_eq!(value["layers"][0]["opacity"], 0.5);
        assert_eq!(
            value["tilesets"][0]["tiles"][0]["animation"][0]["duration"],
            0.1
        );
        assert!(Path::new(value["tilesets"][0]["image"]["path"].as_str().unwrap()).is_file());
        assert!(load(&fixture("missing.tmx")).is_err());
    }
    #[test]
    fn decodes_compressed_infinite_chunks_and_flip_bits() {
        let value: Value =
            serde_json::from_slice(&load(&fixture("infinite.tmx")).unwrap()).unwrap();
        let cells = value["layers"][0]["cells"].as_array().unwrap();
        assert_eq!(cells.len(), 2);
        assert_eq!(cells[0]["x"], -2);
        assert_eq!(cells[0]["y"], -1);
        assert_eq!(cells[1]["x"], -1);
        assert_eq!(cells[1]["y"], 0);
        assert_eq!(cells[1]["id"], 1);
        assert_eq!(cells[1]["flipH"], true);
    }
    #[test]
    fn preserves_tile_objects_and_image_repetition() {
        let value: Value = serde_json::from_slice(&load(&fixture("objects.tmx")).unwrap()).unwrap();
        assert_eq!(value["layers"][0]["objects"][0]["tile"]["id"], 1);
        assert_eq!(value["layers"][1]["repeatX"], true);
    }
}
