# Vendor Directory

This directory would normally contain the Tecs modules installed via LuaRocks:

```
src/vendor/
├── share/lua/5.1/
│   ├── tecs/
│   ├── tecs2d/
│   ├── tecs_render/
│   └── ... (other modules)
└── lib/lua/5.1/
    └── (compiled libraries if any)
```

Install modules with:

```bash
luarocks install --tree=src/vendor tecs.tl
luarocks install --tree=src/vendor tecs2d.tl
luarocks install --tree=src/vendor tecs_render.tl
```

This directory is not committed to the Tecs source repository since this repo IS the source of the vendor packages.
But in your game projects, you should commit the vendor directory for reproducible builds.