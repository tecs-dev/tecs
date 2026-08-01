# Tecs examples

Each file is a complete application. Run one from the repository root with:

```bash
cargo xtask example scene3d
```

`scene3d.tl` demonstrates the 3D scene contract that exists before mesh
rendering. It creates a mesh entity and projects its bounds through `Camera3D`
as a 2D debug wireframe. The wireframe is deliberately not a substitute for
`MeshDomain`: the example becomes a rendered mesh demo only after that domain
loads geometry and submits its own draw work.
