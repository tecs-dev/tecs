---
description: "Creating an OS window and reading its size, state, confinement and displays, in screen coordinates and pixels"
outline: deep
---

# tecs.window.Window

`tecs.window.Window` is an OS window, and the displays it can sit on. It creates one, reads and changes its size,
position, decoration, fullscreen state and opacity, confines the pointer to it, asks for the user's attention
through it, and enumerates the displays around it.

The handle is owned by the platform layer and released by `destroy`, not by a finalizer. Tying GPU-adjacent
lifetimes to Lua's collector makes hot reload either leak or double-free, depending on collection order.

[`Application`](/modules/application) creates the window for you from the `Window.Options` its config carries,
and holds it. A game that only wants a window of a certain size sets the options and never calls `Window.create`.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")` and every module is a field on it, so this module is `tecs.window.Window`.
`tecs` is also set as a global, which makes the require line optional, and engine modules are resolved lazily on
first field access.

## Two coordinate systems, and no converter between them

`getSize` is screen coordinates, which is what a mouse, a pen or a touch position arrives in. `getPixelSize` is
the drawable, which is what a render target is sized to. On a high-density display they differ by `pixelDensity`,
and on every display the desktop's own scaling factor is `displayScale`, which is a hint about how large text
should be drawn rather than a ratio between the two.

Those three answers are what the platform actually knows. There is no `toPixels` or `fromPixels` here, because a
converter would have to pick one of the two systems as the real one and silently reinterpret the other; the pair
of getters says which is which at every call site instead.

## Polled state beside events that report the same thing

[`events`](/modules/events#windows) carries `windowMoved`, `windowResized`, `windowFocusGained`,
`windowFocusLost`, `windowMinimized`, `windowMaximized`, `windowRestored`, `windowShown`, `windowHidden`,
`windowOccluded`, `windowEnterFullscreen`, `windowLeaveFullscreen`, `windowDisplayScaleChanged` and
`windowSafeAreaChanged`. Every one of those facts is also readable here, which looks like a second way to learn
the same thing and is not.

An event reports a _change_. Nothing reports the state a window started in: a window created hidden fires no
`windowHidden`, a window that has never had focus fires no `windowFocusLost`, and a game that only listens has to
assume an initial value and hope the platform agrees. The getters here are how the first frame learns where it
stands, and how any later frame resynchronises without keeping a mirror of the event stream.

They agree with the events by construction: each one asks SDL rather than caching, so the flags a getter reads
are the flags the event was derived from. `id` is the bridge between the two, since it is the value an event's
`which` field carries.

## With no video

The display and screen-saver functions belong to SDL's video subsystem and answer here without calling SDL at
all when it is not up: empty lists, zero sizes, `"unknown"` orientations and themes. A destroyed window answers
the same way, because SDL leaves an out-parameter untouched on failure and a getter that returned it would report
the size the window had before it was destroyed.

`create` is the exception and raises, since a window that could not be created is not a question with a sensible
answer.

### available

Whether there is a video subsystem to ask at all.

```teal
function Window.available(): boolean
```

What a caller checks before deciding whether to open a window.

## Creating a window

### create

Creates a window.

```teal
function Window.create(options: Window.Options): Window
```

Requires SDL's video subsystem to have been initialised, and raises when the window could not be created.

Flags that SDL only accepts at creation are taken from `options` and set there; everything else in `options` is
applied straight afterwards and has a setter of its own, so nothing is reachable at creation that is not
reachable later.

**`Options` fields, every one optional:**

| Field                   | Type      | Default   | Description                                                                                                                                                          |
| ----------------------- | --------- | --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `title`                 | `string`  | `"tecs"`  | The window's title.                                                                                                                                                  |
| `width`, `height`       | `integer` | 1280, 720 | Size in screen coordinates, not pixels: on a high-density display the drawable is larger.                                                                            |
| `resizable`             | `boolean` | `true`    | Only an explicit false turns it off.                                                                                                                                 |
| `highPixelDensity`      | `boolean` | `true`    | Whether the drawable follows the display's density instead of being stretched to it, on the same terms. This is what makes `getPixelSize` differ from `getSize`.     |
| `fullscreen`            | `boolean` | `false`   | Starts fullscreen on whichever display the window manager picks.                                                                                                     |
| `borderless`            | `boolean` | `false`   | Drops the title bar and the frame.                                                                                                                                   |
| `hidden`                | `boolean` | `false`   | Creates the window without mapping it, so nothing is shown until `show` is called. What a game that wants to place and size the window before it is first seen sets. |
| `alwaysOnTop`           | `boolean` | `false`   | Keeps the window above others.                                                                                                                                       |
| `transparent`           | `boolean` | `false`   | Asks for a window whose buffer has an alpha channel the desktop composites against. Refused outright on a platform that cannot do it.                                |
| `x`, `y`                | `integer` | unset     | Position in screen coordinates. Both are needed for either to apply; left unset, the window manager places the window.                                               |
| `minWidth`, `minHeight` | `integer` | unset     | Smallest size, applied after creation. Needed together.                                                                                                              |
| `maxWidth`, `maxHeight` | `integer` | unset     | Largest size, applied after creation. Needed together.                                                                                                               |
| `icon`                  | `string`  | unset     | Image file the window is shown as. Decoded once, here, rather than going through the asset system, which decodes on a worker and answers with a GPU texture.         |

**Example:**

```teal
local window <const> = tecs.window.Window.create({
    title = "Starfarer",
    width = 1600, height = 900,
    minWidth = 640, minHeight = 360,
    hidden = true,
})
window:center()
window:show()
```

### Fields

| Field    | Type          | Description                                                                                   |
| -------- | ------------- | --------------------------------------------------------------------------------------------- |
| `handle` | `loader.CPtr` | The underlying window. Nil once `destroy` has run, and what a device claims for presentation. |
| `title`  | `string`      | The title last set, kept so reading it back does not cross the FFI.                           |

### destroy

Releases the window.

```teal
function Window:destroy()
```

Safe to call more than once. Every getter answers zero, false or nil afterwards rather than reading through a
null handle.

### id

The id events name this window by.

```teal
function Window:id(): integer
```

**Returns:** the id an event's `which` field carries, or zero once the window is gone.

### sync

Waits for pending window changes to be applied.

```teal
function Window:sync(): boolean
```

Size, position and fullscreen are requests rather than commands on a compositing window system, and SDL reports
the old value until the compositor answers. This blocks until it has, so a caller that must read back what it
just set has somewhere to wait. Everywhere else the change is already applied and this returns immediately.

**Returns:** false when the changes did not land in SDL's timeout, and false with no window.

## Changing a window a device has claimed

Safe: size, position, minimum and maximum size, aspect ratio, fullscreen, borders, opacity, visibility and
minimisation. The pass graph sizes its targets from the swapchain texture it acquires each frame rather than from
anything asked of the window, so a size change is picked up on the next frame with no reconfiguration; a hidden
or minimised window acquires no texture and the frame is skipped whole.

Asynchronous: on some window systems a size, position or fullscreen change is a request the compositor answers
later, so reading the value straight back reports the old one. `sync` waits for the pending changes to land, and
is the only reason to call it.

## Size and position

```teal
function Window:getSize(): integer, integer
function Window:getPixelSize(): integer, integer
function Window:setSize(width: integer, height: integer): boolean
function Window:pixelDensity(): number
function Window:displayScale(): number
function Window:position(): integer, integer
function Window:setPosition(x: integer, y: integer): boolean
function Window:center(displayId?: integer): boolean
function Window:borderSize(): integer, integer, integer, integer
function Window:safeArea(): integer, integer, integer, integer
```

| Method         | What it answers                                                                                                                                                                                                                                                      |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `getSize`      | Size in screen coordinates, the units mouse, touch and pen positions arrive in.                                                                                                                                                                                      |
| `getPixelSize` | The drawable size in pixels, which differs from `getSize` on high-density displays.                                                                                                                                                                                  |
| `setSize`      | Resizes, in screen coordinates. A fullscreen window ignores it, and a window whose size the compositor has to agree to reports the old size until `sync` returns.                                                                                                    |
| `pixelDensity` | Ratio of pixels to screen coordinates: 2.0 where the drawable is twice the window. 1.0 without `highPixelDensity`, and 0 with no window.                                                                                                                             |
| `displayScale` | How much larger than its natural size the desktop asks content to be drawn. Not a ratio between the two sizes; it is the user's scaling preference, so it is what a font size or a UI metric is multiplied by, and it changes without the window resizing.           |
| `position`     | Position of the top-left corner in screen coordinates.                                                                                                                                                                                                               |
| `setPosition`  | Moves the window. The coordinate space spans every display, so a negative or very large position is how a window is put on a second monitor.                                                                                                                         |
| `center`       | Centres the window on `displayId`, or on the display it is already on.                                                                                                                                                                                               |
| `borderSize`   | Thickness of the window manager's decoration, as top, left, bottom and right in screen coordinates. All zero on a platform that does not decorate windows and on a borderless one, which is the honest answer rather than a failure.                                 |
| `safeArea`     | The part of the window nothing is drawn over, as x, y, width and height. The whole window on a desktop; smaller where a notch, a rounded corner or a system gesture area overlaps it, which is what a phone or a handheld needs to keep a health bar out from under. |

`events.windowDisplayScaleChanged` reports that `displayScale` changed, and `events.windowSafeAreaChanged` that
the safe area moved.

## Size limits

```teal
function Window:minimumSize(): integer, integer
function Window:setMinimumSize(width: integer, height: integer): boolean
function Window:maximumSize(): integer, integer
function Window:setMaximumSize(width: integer, height: integer): boolean
function Window:aspectRatio(): number, number
function Window:setAspectRatio(minimum: number, maximum: number): boolean
```

Zero for either dimension removes that limit, and a maximum reads back as zero for a dimension that has none.
`aspectRatio` answers the narrowest and widest width-over-height the window may be resized to, zero for a bound
that is not set; passing the same value for both pins the window to one shape, which is what a game that will
not letterbox wants.

## Visibility and window state

```teal
function Window:show(): boolean
function Window:hide(): boolean
function Window:isVisible(): boolean
function Window:raise(): boolean
function Window:minimize(): boolean
function Window:isMinimized(): boolean
function Window:maximize(): boolean
function Window:isMaximized(): boolean
function Window:restore(): boolean
function Window:isOccluded(): boolean
function Window:hasFocus(): boolean
function Window:hasMouseFocus(): boolean
```

| Method          | What it does or answers                                                                                                                                                             |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `show`          | Maps the window onto the desktop. What a window created `hidden` needs before anything it draws is seen.                                                                            |
| `hide`          | Unmaps the window without destroying it. Safe while a device holds it: no swapchain texture is acquired and the frame is skipped whole rather than drawn nowhere.                   |
| `isVisible`     | Whether the window is mapped. False for a window created `hidden` and one `hide` was called on, and true for a minimised window, which is mapped and not visible.                   |
| `raise`         | Brings the window to the front and gives it input focus. Distinct from `flash`: this takes focus, which a desktop may refuse or may allow to interrupt whatever the user was doing. |
| `minimize`      | Minimises to the taskbar or dock.                                                                                                                                                   |
| `isMinimized`   | Whether it is minimised. `events.windowMinimized` reports that it became so; this is how the first frame after startup finds out.                                                   |
| `maximize`      | Maximises to fill the display's usable bounds.                                                                                                                                      |
| `isMaximized`   | Whether it is maximised.                                                                                                                                                            |
| `restore`       | Returns a minimised or maximised window to its previous size and position.                                                                                                          |
| `isOccluded`    | Whether something is covering the window entirely, so a frame drawn now is not seen. Independent of minimisation, and both stop the swapchain handing out a texture.                |
| `hasFocus`      | Whether the window has keyboard focus, which is where key events are going.                                                                                                         |
| `hasMouseFocus` | Whether the pointer is over the window. False while relative mouse mode is on, since there is no pointer position for the window to contain.                                        |

## Fullscreen

```teal
function Window:setFullscreen(fullscreen: boolean): boolean
function Window:isFullscreen(): boolean
function Window:fullscreenMode(): Window.DisplayMode
function Window:setFullscreenMode(mode: Window.DisplayMode): boolean
```

Which fullscreen depends on `setFullscreenMode`: with no mode set, `setFullscreen(true)` is borderless
fullscreen at the desktop's own resolution, which is what a window that shares a display with other applications
wants. With a mode set it changes the display's video mode to it.

Safe while a device holds the window. The swapchain follows the new size and the renderer picks it up from the
texture it acquires next frame. `events.windowEnterFullscreen` and `windowLeaveFullscreen` report that the change
actually landed, which on a compositing window system is later than `setFullscreen` returns; `sync` is the other
way to wait for it.

::: warning A mode has to come from the platform
`setFullscreenMode` needs a mode from [`Window.fullscreenModes`](#displays) or `Window.closestFullscreenMode`,
because SDL matches it against the modes the display actually has and a record assembled by hand names one that
may not exist. A mode without the platform's own handle raises. Passing nil selects borderless fullscreen at the
desktop's resolution. It takes effect the next time the window is made fullscreen, and immediately if it already
is.
:::

**`DisplayMode` fields:**

| Field          | Type      | Description                                                                     |
| -------------- | --------- | ------------------------------------------------------------------------------- |
| `display`      | `integer` | Display this mode belongs to.                                                   |
| `width`        | `integer` | Size in screen coordinates. Multiply by `pixelDensity` for pixels.              |
| `height`       | `integer` | Same.                                                                           |
| `pixelDensity` | `number`  | Screen coordinates to pixels, so a 1920 by 1080 mode at 2.0 draws 3840 by 2160. |
| `refreshRate`  | `number`  | Refreshes per second, or 0 where the platform will not say.                     |

## Decoration and appearance

```teal
function Window:setTitle(title: string): boolean
function Window:setIcon(path: string): boolean
function Window:isResizable(): boolean
function Window:setResizable(resizable: boolean): boolean
function Window:isBordered(): boolean
function Window:setBordered(bordered: boolean): boolean
function Window:isAlwaysOnTop(): boolean
function Window:setAlwaysOnTop(onTop: boolean): boolean
function Window:isFocusable(): boolean
function Window:setFocusable(focusable: boolean): boolean
function Window:opacity(): number
function Window:setOpacity(opacity: number): boolean
```

`setTitle` also updates the `title` field, and raises on a nil argument. `setIcon` decodes `path` synchronously,
because an icon is wanted before the first frame and the asset system decodes on a worker and answers with a GPU
texture, which is not what SDL takes; SDL copies the pixels, so nothing is retained, and the result is false when
the file could not be decoded.

`isResizable` is whether the user can drag an edge and says nothing about `setSize`, which works either way.
`setBordered` keeps the client area's size, so the window as a whole changes size by the border thickness. A
window that cannot take focus is what an overlay uses to stay out of the way. `opacity` runs 0 for invisible to
1 for solid, answers 0 with no window and 1 on a platform that composites nothing, and whether the desktop
honours `setOpacity` is the desktop's business; false says it did not.

## Attention

### flash

Asks for the user's attention without taking focus.

```teal
function Window:flash(operation: Window.Flash): boolean
```

The polite form of `raise`: the taskbar entry or the dock icon is marked and the user decides when to look. An
unknown operation raises.

**`Flash` values:**

| Value            | Meaning                                                                                                        |
| ---------------- | -------------------------------------------------------------------------------------------------------------- |
| `"cancel"`       | Stops a flash already running.                                                                                 |
| `"brief"`        | One flash, whether or not anybody was looking.                                                                 |
| `"untilFocused"` | Keeps flashing until the window is focused, which suits a turn-based game waiting on a player who tabbed away. |

### progress

What the taskbar or dock is showing over the application's icon, and how far along it is.

```teal
function Window:progress(): Window.Progress, number
function Window:setProgress(state: Window.Progress, value?: number): boolean
```

**Parameters:**

- `state`: one of `"none"`, `"indeterminate"`, `"normal"`, `"paused"` or `"error"`. An unknown state raises.
- `value`: 0 to 1, and only meaningful for `"normal"`, `"paused"` and `"error"`. Omitted leaves the value alone.

`"none"` is where a window starts and what `progress` answers with no window, beside a value of 0.
`"indeterminate"` says work is happening and its extent is not known, and `"error"` that work stopped because it
failed. This is what a shader pack build or an asset load has to report to, since neither can draw a progress bar
in a window that is not rendering yet.

## Confinement

Pointer behaviour is [`Input`](/modules/input)'s: relative mouse mode, warping, capture and cursor visibility all
act through the window but are input modes. What is here instead is confinement, which is a property of the
window's bargain with the window manager rather than of the pointer.

```teal
function Window:mouseGrab(): boolean
function Window:setMouseGrab(grabbed: boolean): boolean
function Window:keyboardGrab(): boolean
function Window:setKeyboardGrab(grabbed: boolean): boolean
function Window:mouseRect(): integer, integer, integer, integer
function Window:setMouseRect(x?: integer, y?: integer,
                             width?: integer, height?: integer): boolean
```

`setMouseGrab` confines the pointer to the window and leaves it visible, which is not the same as relative mouse
mode; a game that wants both sets both. Taking the request is not the same as the grab being in force, which is
what `mouseGrab` answers: an unfocused window records the request and holds nothing until focus comes back.

`setKeyboardGrab` intercepts the desktop's own keyboard shortcuts while the window has focus, so that alt-tab and
the like reach the game instead. It is costly to get wrong, since it is how a window stops the user leaving it,
and some desktops refuse it outright while some require a permission the user grants once.

`setMouseRect` confines the pointer to part of the window, in screen coordinates, and is independent of
`setMouseGrab`: it applies while the window has focus whether or not the window is grabbed. Called with no
arguments, the region is removed. `mouseRect` answers x, y, width and height, all zero when there is none.

## Displays

Display functions are on the module rather than on a window, and every one takes an optional display id that
defaults to the primary display.

```teal
function Window:display(): integer
function Window.displays(): {integer}
function Window.primaryDisplay(): integer
function Window.displayName(displayId?: integer): string
function Window.displayBounds(displayId?: integer): integer, integer, integer, integer
function Window.usableBounds(displayId?: integer): integer, integer, integer, integer
function Window.contentScale(displayId?: integer): number
function Window.orientation(displayId?: integer): Window.Orientation
function Window.naturalOrientation(displayId?: integer): Window.Orientation
function Window.desktopMode(displayId?: integer): Window.DisplayMode
function Window.currentMode(displayId?: integer): Window.DisplayMode
function Window.fullscreenModes(displayId?: integer): {Window.DisplayMode}
```

| Function             | What it answers                                                                                                                                                                                                                                                       |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Window:display`     | The display this window is mostly on. Zero with no window.                                                                                                                                                                                                            |
| `displays`           | Every display currently attached, in the order SDL reports them. `events.displayAdded` and `displayRemoved` report that this list changed, so a game with a display menu rebuilds it there rather than polling.                                                       |
| `primaryDisplay`     | The display the desktop treats as primary.                                                                                                                                                                                                                            |
| `displayName`        | A display's name as the desktop shows it, for a menu that lets the player choose one.                                                                                                                                                                                 |
| `displayBounds`      | A display's position and size in the desktop's coordinate space, as x, y, width and height. The x and y are what makes the coordinates `setPosition` takes span every monitor.                                                                                        |
| `usableBounds`       | The part of a display not covered by a taskbar, dock or menu bar, in the same coordinates. Where a window should be placed and how large it should be to be usable, which `displayBounds` does not answer. `events.displayUsableBoundsChanged` reports that it moved. |
| `contentScale`       | A display's content scale, the same quantity `Window:displayScale` reports for whichever display a window is on. Named for what SDL calls it rather than matching the method, because a record holds one `displayScale` and the two would be the same field.          |
| `orientation`        | How a display is rotated right now. `events.displayOrientation` reports that it turned.                                                                                                                                                                               |
| `naturalOrientation` | How a display is built to be held, which does not change. What tells a landscape reading apart from a device that is landscape to begin with.                                                                                                                         |
| `desktopMode`        | The mode a display was in when the desktop started, which is what leaving fullscreen returns it to.                                                                                                                                                                   |
| `currentMode`        | The mode a display is in right now, which differs from `desktopMode` while something holds it fullscreen at another resolution.                                                                                                                                       |
| `fullscreenModes`    | Every fullscreen mode a display offers, largest first. What a resolution menu is built from, and what `setFullscreenMode` takes. Empty on a platform whose only fullscreen is the desktop's own resolution.                                                           |

**`Orientation` values:** `"unknown"`, `"landscape"`, `"landscapeFlipped"`, `"portrait"`, `"portraitFlipped"`.

### closestFullscreenMode

The mode nearest to a requested size and refresh rate.

```teal
function Window.closestFullscreenMode(width: integer, height: integer,
                                      refreshRate?: number,
                                      highDensity?: boolean,
                                      displayId?: integer): Window.DisplayMode
```

**Parameters:**

- `refreshRate`: hertz, or 0 or nil for the highest the size allows.
- `highDensity`: whether modes whose pixel density is above 1 may be chosen. Defaults to false.

**Returns:** the mode, or nil when the display offers nothing that fits, and with no video.

What a game restoring a saved resolution asks for, since the display may no longer offer exactly what was saved.

**Example:**

```teal
local mode <const> = tecs.window.Window.closestFullscreenMode(saved.width, saved.height, saved.refreshRate)
if mode ~= nil then
    window:setFullscreenMode(mode)
    window:setFullscreen(true)
end
```

## The desktop

```teal
function Window.theme(): Window.Theme
function Window.screenSaverEnabled(): boolean
function Window.setScreenSaverEnabled(enabled: boolean): boolean
```

`theme` is whether the desktop is asking applications to draw themselves light or dark: `"light"`, `"dark"`, or
`"unknown"` where the platform has no such preference and with no video. `events.themeChanged` reports that it
changed.

The screen saver is off for most of a game's life, since SDL disables it as soon as video comes up: a player
holding a gamepad is not idle, and the keyboard and mouse are what the desktop watches. Turn it back on for a
menu or a cutscene nobody is playing through. It applies to the whole application rather than to one window,
which is why it is not a method.

## What is not here

Presentation pacing is not a window setting. SDL's window vsync paces the window _surface_, which is the
software-blit path and cannot coexist with a window a GPU device has claimed, so pacing a claimed window is the
device's business and a second spelling of it here would be a call that either does nothing or tears the
swapchain down.

Nor is the surface family itself, the graphics-API interop, the raw property bag, the multi-window relationships,
or the entry points that hand back a raw window pointer this module does not own. A hit test is left out for the
reason [`clipboard`](/modules/clipboard#arbitrary-mime-types) records for the offer side of the clipboard: it
retains a callback SDL enters from its own event pump, and this engine keeps callbacks native.

## Design record

- [The window](https://github.com/tecs-dev/tecs/blob/main/README.md#the-window)
- [Events](https://github.com/tecs-dev/tecs/blob/main/README.md#events)
- [Porting to a platform SDL does not cover](https://github.com/tecs-dev/tecs/blob/main/README.md#porting-to-a-platform-sdl-does-not-cover)
