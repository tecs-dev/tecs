components {
  id: "bench"
  component: "/main/bench.script"
}
embedded_components {
  id: "factory"
  type: "factory"
  data: "prototype: \"/main/runner.go\"\n"
  "load_dynamically: false\n"
  ""
  position {
    x: 0.0
    y: 0.0
    z: 0.0
  }
  rotation {
    x: 0.0
    y: 0.0
    z: 0.0
    w: 1.0
  }
}
embedded_components {
  id: "camera"
  type: "camera"
  data: "aspect_ratio: 1.0\n"
  "fov: 0.7853982\n"
  "near_z: -1.0\n"
  "far_z: 1.0\n"
  "auto_aspect_ratio: 1\n"
  "orthographic_projection: 1\n"
  "orthographic_zoom: 1.0\n"
  ""
  position {
    x: 0.0
    y: 0.0
    z: 0.0
  }
  rotation {
    x: 0.0
    y: 0.0
    z: 0.0
    w: 1.0
  }
}
