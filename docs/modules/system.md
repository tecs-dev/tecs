---
description: "Operating-system utilities: URLs, locales, power, message boxes, and asynchronous file and folder dialogs"
outline: deep
---

# tecs.system

`tecs.system` groups small process-wide services SDL presents consistently. They are not window state. A window
is optional when a message box or file picker should be parented to one, and an `Application` is only needed to
pump asynchronous dialog results automatically.

## openURL

```teal
function system.openURL(url: string): boolean, string
```

Asks the operating system to open `url` with its preferred handler. Returns `(true, nil)` when the request was
accepted and `(false, error)` otherwise. An empty URL is refused without invoking the platform.

## preferredLocales

```teal
function system.preferredLocales(): {system.Locale}
```

Returns the user's preferred locales in priority order. Each has `language`, an ISO 639 code, and `country`, an
ISO 3166 code or `""` when the platform names only a language. The list and strings are owned Lua values.

## power

```teal
function system.power(): system.Power
```

Returns `state`, `seconds`, and `percent`. State is `"unknown"`, `"onBattery"`, `"noBattery"`, `"charging"`,
`"charged"` or `"error"`. Either number is `-1` when the platform cannot supply it.

## messageBox

```teal
function system.messageBox(
    kind: string, title: string, message: string, window?: Window
): boolean, string
```

Shows a simple blocking native message box. `kind` is `"info"`, `"warning"` or `"error"`. Pass a window to make
the box modal to it.

## File and folder dialogs

```teal
function system.openFile(
    options?: system.DialogOptions
): Future<system.DialogResult>

function system.saveFile(
    options?: system.DialogOptions
): Future<system.DialogResult>

function system.openFolder(
    options?: system.DialogOptions
): Future<system.DialogResult>
```

These open native platform pickers and return [`Future`](/modules/Future) values. `saveFile` returns at most one
path. `openFile` and `openFolder` return one unless `multiple` is true.

```teal
local choice <const> = tecs.system.openFile({
    window = app.window,
    filters = {
        { name = "Images", pattern = "png;jpg;jpeg" },
    },
    defaultLocation = tecs.paths.content(),
    multiple = true,
})
```

`DialogOptions` has these fields:

| Field             | Type                    | Meaning                                                  |
| ----------------- | ----------------------- | -------------------------------------------------------- |
| `window`          | `Window`                | Optional parent window                                   |
| `filters`         | `{system.DialogFilter}` | Display names and semicolon-separated extension patterns |
| `defaultLocation` | `string`                | Initial directory or file                                |
| `multiple`        | `boolean`               | Allows several selections on open-file and open-folder   |

Every filter needs a non-empty `name` and `pattern`; invalid filters raise before a dialog opens.

A ready future carries `paths`, `filter`, and `cancelled`. `filter` is one-based, or zero when no filter applies.
Closing the picker without choosing is a successful result with `cancelled = true` and an empty path list;
failure means the platform could not complete the dialog.

SDL retains a callback for these pickers and may invoke it from a thread LuaJIT did not create.
`native/dialogs.c` therefore copies its answer behind a mutex, and `Application` settles the future on the main
thread.

## updateDialogs

```teal
function system.updateDialogs(): integer
```

Settles completed file and folder dialogs and returns how many completed. `Application` calls this each frame. A
tool that uses dialogs without an application can call it itself or use `future:wait()`, whose source polls the
native state.
