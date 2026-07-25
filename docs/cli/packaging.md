---
description: "Packaging built games with tecs dist into love files, macOS bundles, and Windows executables"
outline: deep
---

# Packaging

`tecs dist` packages the built game for players:

```sh
tecs dist            # .love file, macOS app bundle, and Windows executable
tecs dist windows    # or one target: love, macos, windows
```

Everything lands in `dist/`:

| Artifact | Contents |
| -------- | -------- |
| `<name>.love` | `build/` zipped; runs on an installed Love 12 |
| `<name>-macos.zip` | A self-contained app bundle: the Love runtime with the game embedded and a rebranded `Info.plist`. Unzip, double-click, play |
| `<name>-windows.zip` | A folder with `<name>.exe` (Love fused with the game), Love's DLLs, and its license |

The Love runtime comes from the launcher cache when present and is
downloaded once otherwise. Windows packages build on any host, because
fusing is byte concatenation. The macOS bundle needs macOS or Linux, since
the app's framework symlinks require a POSIX filesystem.

The macOS bundle ships unsigned. Sign and notarize it with an Apple
Developer ID before wide distribution; unsigned apps trigger Gatekeeper's
unidentified-developer prompt.

## Dev and distributed builds

Every `tecs build` writes a `build/tecs_buildinfo.lua` manifest: project
name, build timestamp, tool versions, and a `dev` flag. `tecs dist` packages
the manifest with `dev = false` and restores the dev manifest afterward, so
local runs and specs keep their tooling.

The [MCP server](/tecs2d/mcp/) and the debugger read the manifest through
`tecs2d.buildinfo` and disable themselves in distributed builds. A game can
keep them deliberately:

```teal
world:addPlugin(mcp.new({enableInDist = true}))
world:addPlugin(require("tecs2d.debug").new({enableInDist = true}))
```

The [tecs-space-example](https://github.com/tecs-dev/tecs-space-example)
repository does exactly that to make its shipped demo inspectable, and its
release workflow shows the full automation: every tag runs `tecs integ`,
packages with `tecs dist`, and attaches the artifacts to the GitHub release.
