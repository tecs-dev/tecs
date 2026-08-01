# Tecs examples

Each file is a complete application. Run one from the repository root with:

```bash
cargo xtask example ui-demo
cargo xtask example scene3d
```

`ui-demo.tl` is the complete engine showcase. It exercises the sprite renderer,
lighting, text, UI, input, animation, audio, and debug tools together.

`scene3d.tl` demonstrates the 3D scene contract that exists before mesh
rendering. It creates a mesh entity and projects its bounds through `Camera3D`
as a 2D debug wireframe. The wireframe is deliberately not a substitute for
`MeshDomain`: the example becomes a rendered mesh demo only after that domain
loads geometry and submits its own draw work.
