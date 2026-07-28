---
description: "Asynchronous native open-file, save-file, and folder selection"
outline: deep
---

# tecs.dialogs

`tecs.dialogs` opens native platform pickers and returns [`Future`](/modules/Future) values. The callback SDL
retains is implemented in C: it may arrive on a thread LuaJIT did not create, so it copies the answer behind a
mutex and `Application` settles the future from the main thread.

## Opening dialogs

```teal
function dialogs.openFile(options?: dialogs.Options): Future<dialogs.Result>
function dialogs.saveFile(options?: dialogs.Options): Future<dialogs.Result>
function dialogs.openFolder(options?: dialogs.Options): Future<dialogs.Result>
```

`saveFile` returns at most one path. `openFile` and `openFolder` return one unless `multiple` is true.

```teal
local choice <const> = tecs.dialogs.openFile({
    window = app.window,
    filters = {
        { name = "Images", pattern = "png;jpg;jpeg" },
    },
    defaultLocation = tecs.paths.content(),
    multiple = true,
})
```

## Options

| Field             | Type               | Meaning                                                  |
| ----------------- | ------------------ | -------------------------------------------------------- |
| `window`          | `Window`           | Optional parent window                                   |
| `filters`         | `{dialogs.Filter}` | Display names and semicolon-separated extension patterns |
| `defaultLocation` | `string`           | Initial directory or file                                |
| `multiple`        | `boolean`          | Allows several selections on open-file and open-folder   |

Every filter needs a non-empty `name` and `pattern`; invalid filters raise before a dialog opens.

## Result

A ready future carries `paths`, `filter`, and `cancelled`. `filter` is one-based, or zero when no filter applies.
Closing the picker without choosing is a successful result with `cancelled = true` and an empty path list;
failure means the platform could not complete the dialog.

`Application` calls `dialogs.update()` each frame. A tool that uses dialogs without an application can call that
function itself or `future:wait()`, whose source polls the native state.
