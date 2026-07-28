---
description: "Operating-system utilities: URLs, preferred locales, power state, and simple native message boxes"
outline: deep
---

# tecs.system

`tecs.system` groups small process-wide services SDL presents consistently. They are not window state and do not
need an `Application`; a window is optional only when a message box should be parented to one.

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
the box modal to it. File and folder selection is asynchronous and belongs to [`tecs.dialogs`](/modules/dialogs).
