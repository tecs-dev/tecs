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

[`Application`](/modules/Application) creates the window for you from the `Window.Options` its config carries,
and holds it. A game that only wants a window of a certain size sets the options and never calls
`tecs.window.newWindow`.

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
stands, and how any later frame resynchronizes without keeping a mirror of the event stream.

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

### newWindow

Creates a window.

```teal
function tecs.window.newWindow(options: Window.Options): Window
```

Requires SDL's video subsystem to have been initialized, and raises when the window could not be created.

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
local window <const> = tecs.window.newWindow({
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
minimization. The pass graph sizes its targets from the swapchain texture it acquires each frame rather than from
anything asked of the window, so a size change is picked up on the next frame with no reconfiguration; a hidden
or minimized window acquires no texture and the frame is skipped whole.

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
| `center`       | Centers the window on `displayId`, or on the display it is already on.                                                                                                                                                                                               |
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
| `isVisible`     | Whether the window is mapped. False for a window created `hidden` and one `hide` was called on, and true for a minimized window, which is mapped and not visible.                   |
| `raise`         | Brings the window to the front and gives it input focus. Distinct from `flash`: this takes focus, which a desktop may refuse or may allow to interrupt whatever the user was doing. |
| `minimize`      | Minimizes to the taskbar or dock.                                                                                                                                                   |
| `isMinimized`   | Whether it is minimized. `events.windowMinimized` reports that it became so; this is how the first frame after startup finds out.                                                   |
| `maximize`      | Maximizes to fill the display's usable bounds.                                                                                                                                      |
| `isMaximized`   | Whether it is maximized.                                                                                                                                                            |
| `restore`       | Returns a minimized or maximized window to its previous size and position.                                                                                                          |
| `isOccluded`    | Whether something is covering the window entirely, so a frame drawn now is not seen. Independent of minimization, and both stop the swapchain handing out a texture.                |
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

Pointer behavior is [`Input`](/modules/input)'s: relative mouse mode, warping, capture and cursor visibility all
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

Nor is a message box, which is a blocking modal dialog whose one real use is reporting a failure before there is
a window or after there is not.

Nor is the surface family itself, the graphics-API interop, the raw property bag, the multi-window relationships,
or the entry points that hand back a raw window pointer this module does not own. A hit test is left out for the
reason [`clipboard`](/modules/system#arbitrary-mime-types) records for the offer side of the clipboard: it
retains a callback SDL enters from its own event pump, and this engine keeps callbacks native.
<!-- @generated by docs/scripts/reference.py from src/tecs/platform/Window.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/platform/Window.tl`.

<a id="tecs.window.Window.DisplayMode"></a>

### tecs.window.Window.DisplayMode

<pre><code v-pre>record <a href="#tecs.window.Window.DisplayMode">tecs.window.Window.DisplayMode</a>
</code></pre>

One video mode a display can be put into.

<a id="tecs.window.Window.DisplayMode.display"></a>

### tecs.window.Window.DisplayMode.display

<pre><code v-pre><a href="#tecs.window.Window.DisplayMode.display">tecs.window.Window.DisplayMode.display</a>: integer
</code></pre>

Display this mode belongs to.

<a id="tecs.window.Window.DisplayMode.width"></a>

### tecs.window.Window.DisplayMode.width

<pre><code v-pre><a href="#tecs.window.Window.DisplayMode.width">tecs.window.Window.DisplayMode.width</a>: integer
</code></pre>

Size in screen coordinates. Multiply by `pixelDensity` for pixels.

<a id="tecs.window.Window.DisplayMode.height"></a>

### tecs.window.Window.DisplayMode.height

<pre><code v-pre><a href="#tecs.window.Window.DisplayMode.height">tecs.window.Window.DisplayMode.height</a>: integer
</code></pre>

<a id="tecs.window.Window.DisplayMode.pixelDensity"></a>

### tecs.window.Window.DisplayMode.pixelDensity

<pre><code v-pre><a href="#tecs.window.Window.DisplayMode.pixelDensity">tecs.window.Window.DisplayMode.pixelDensity</a>: number
</code></pre>

Screen coordinates to pixels, so a 1920 by 1080 mode at 2.0 draws
3840 by 2160.

<a id="tecs.window.Window.DisplayMode.refreshRate"></a>

### tecs.window.Window.DisplayMode.refreshRate

<pre><code v-pre><a href="#tecs.window.Window.DisplayMode.refreshRate">tecs.window.Window.DisplayMode.refreshRate</a>: number
</code></pre>

Refreshes per second, or 0 where the platform will not say.

<a id="tecs.window.Window.Flash"></a>

### tecs.window.Window.Flash

<pre><code v-pre>enum <a href="#tecs.window.Window.Flash">tecs.window.Window.Flash</a>
</code></pre>

How hard to ask for attention.

<a id="tecs.window.Window.Flash.&quot;brief&quot;"></a>

### tecs.window.Window.Flash.&quot;brief&quot;

One flash, whether or not anybody was looking.

<a id="tecs.window.Window.Flash.&quot;cancel&quot;"></a>

### tecs.window.Window.Flash.&quot;cancel&quot;

Stops a flash already running.

<a id="tecs.window.Window.Flash.&quot;untilFocused&quot;"></a>

### tecs.window.Window.Flash.&quot;untilFocused&quot;

Keeps flashing until the window is focused.

<a id="tecs.window.Window.Options"></a>

### tecs.window.Window.Options

<pre><code v-pre>record <a href="#tecs.window.Window.Options">tecs.window.Window.Options</a>
</code></pre>

What `newWindow` takes. Every field is optional.

<a id="tecs.window.Window.Options.title"></a>

### tecs.window.Window.Options.title

<pre><code v-pre><a href="#tecs.window.Window.Options.title">tecs.window.Window.Options.title</a>: string
</code></pre>

Defaults to "tecs".

<a id="tecs.window.Window.Options.width"></a>

### tecs.window.Window.Options.width

<pre><code v-pre><a href="#tecs.window.Window.Options.width">tecs.window.Window.Options.width</a>: integer
</code></pre>

Size in screen coordinates, not pixels: on a high-density display
the drawable is larger. Defaults to 1280 by 720.

<a id="tecs.window.Window.Options.height"></a>

### tecs.window.Window.Options.height

<pre><code v-pre><a href="#tecs.window.Window.Options.height">tecs.window.Window.Options.height</a>: integer
</code></pre>

<a id="tecs.window.Window.Options.resizable"></a>

### tecs.window.Window.Options.resizable

<pre><code v-pre><a href="#tecs.window.Window.Options.resizable">tecs.window.Window.Options.resizable</a>: boolean
</code></pre>

Defaults to true, so omitting it gives a resizable window. Only an
explicit false turns it off.

<a id="tecs.window.Window.Options.highPixelDensity"></a>

### tecs.window.Window.Options.highPixelDensity

<pre><code v-pre><a href="#tecs.window.Window.Options.highPixelDensity">tecs.window.Window.Options.highPixelDensity</a>: boolean
</code></pre>

Whether the drawable follows the display's density instead of being
stretched to it. Defaults to true, on the same terms, which is what
makes `getPixelSize` differ from `getSize`.

<a id="tecs.window.Window.Options.fullscreen"></a>

### tecs.window.Window.Options.fullscreen

<pre><code v-pre><a href="#tecs.window.Window.Options.fullscreen">tecs.window.Window.Options.fullscreen</a>: boolean
</code></pre>

Starts fullscreen on whichever display the window manager picks.
Defaults to false.

<a id="tecs.window.Window.Options.borderless"></a>

### tecs.window.Window.Options.borderless

<pre><code v-pre><a href="#tecs.window.Window.Options.borderless">tecs.window.Window.Options.borderless</a>: boolean
</code></pre>

Drops the title bar and the frame. Defaults to false.

<a id="tecs.window.Window.Options.hidden"></a>

### tecs.window.Window.Options.hidden

<pre><code v-pre><a href="#tecs.window.Window.Options.hidden">tecs.window.Window.Options.hidden</a>: boolean
</code></pre>

Creates the window without mapping it, so nothing is shown until
`show` is called. Defaults to false, and is what a game that wants
to place and size the window before it is first seen sets.

<a id="tecs.window.Window.Options.alwaysOnTop"></a>

### tecs.window.Window.Options.alwaysOnTop

<pre><code v-pre><a href="#tecs.window.Window.Options.alwaysOnTop">tecs.window.Window.Options.alwaysOnTop</a>: boolean
</code></pre>

Keeps the window above others. Defaults to false.

<a id="tecs.window.Window.Options.transparent"></a>

### tecs.window.Window.Options.transparent

<pre><code v-pre><a href="#tecs.window.Window.Options.transparent">tecs.window.Window.Options.transparent</a>: boolean
</code></pre>

Asks for a window whose buffer has an alpha channel the desktop
composites against. Defaults to false, and is refused outright on a
platform that cannot do it.

<a id="tecs.window.Window.Options.x"></a>

### tecs.window.Window.Options.x

<pre><code v-pre><a href="#tecs.window.Window.Options.x">tecs.window.Window.Options.x</a>: integer
</code></pre>

Position in screen coordinates. Both are needed for either to
apply; left unset, the window manager places the window.

<a id="tecs.window.Window.Options.y"></a>

### tecs.window.Window.Options.y

<pre><code v-pre><a href="#tecs.window.Window.Options.y">tecs.window.Window.Options.y</a>: integer
</code></pre>

<a id="tecs.window.Window.Options.minWidth"></a>

### tecs.window.Window.Options.minWidth

<pre><code v-pre><a href="#tecs.window.Window.Options.minWidth">tecs.window.Window.Options.minWidth</a>: integer
</code></pre>

Size limits, applied after creation. Each pair is needed together.

<a id="tecs.window.Window.Options.minHeight"></a>

### tecs.window.Window.Options.minHeight

<pre><code v-pre><a href="#tecs.window.Window.Options.minHeight">tecs.window.Window.Options.minHeight</a>: integer
</code></pre>

<a id="tecs.window.Window.Options.maxWidth"></a>

### tecs.window.Window.Options.maxWidth

<pre><code v-pre><a href="#tecs.window.Window.Options.maxWidth">tecs.window.Window.Options.maxWidth</a>: integer
</code></pre>

<a id="tecs.window.Window.Options.maxHeight"></a>

### tecs.window.Window.Options.maxHeight

<pre><code v-pre><a href="#tecs.window.Window.Options.maxHeight">tecs.window.Window.Options.maxHeight</a>: integer
</code></pre>

<a id="tecs.window.Window.Options.icon"></a>

### tecs.window.Window.Options.icon

<pre><code v-pre><a href="#tecs.window.Window.Options.icon">tecs.window.Window.Options.icon</a>: string
</code></pre>

Image file the window is shown as. Decoded once, here, rather than
going through the asset system, which decodes on a worker and
answers with a GPU texture.

<a id="tecs.window.Window.Orientation"></a>

### tecs.window.Window.Orientation

<pre><code v-pre>enum <a href="#tecs.window.Window.Orientation">tecs.window.Window.Orientation</a>
</code></pre>

How a display is rotated relative to its natural orientation.

<a id="tecs.window.Window.Orientation.&quot;landscape&quot;"></a>

### tecs.window.Window.Orientation.&quot;landscape&quot;

<a id="tecs.window.Window.Orientation.&quot;landscapeFlipped&quot;"></a>

### tecs.window.Window.Orientation.&quot;landscapeFlipped&quot;

<a id="tecs.window.Window.Orientation.&quot;portrait&quot;"></a>

### tecs.window.Window.Orientation.&quot;portrait&quot;

<a id="tecs.window.Window.Orientation.&quot;portraitFlipped&quot;"></a>

### tecs.window.Window.Orientation.&quot;portraitFlipped&quot;

<a id="tecs.window.Window.Orientation.&quot;unknown&quot;"></a>

### tecs.window.Window.Orientation.&quot;unknown&quot;

<a id="tecs.window.Window.Progress"></a>

### tecs.window.Window.Progress

<pre><code v-pre>enum <a href="#tecs.window.Window.Progress">tecs.window.Window.Progress</a>
</code></pre>

What the taskbar or dock shows over this application's icon.

<a id="tecs.window.Window.Progress.&quot;error&quot;"></a>

### tecs.window.Window.Progress.&quot;error&quot;

Work stopped because it failed.

<a id="tecs.window.Window.Progress.&quot;indeterminate&quot;"></a>

### tecs.window.Window.Progress.&quot;indeterminate&quot;

Work is happening and its extent is not known.

<a id="tecs.window.Window.Progress.&quot;none&quot;"></a>

### tecs.window.Window.Progress.&quot;none&quot;

Nothing shown, which is where a window starts.

<a id="tecs.window.Window.Progress.&quot;normal&quot;"></a>

### tecs.window.Window.Progress.&quot;normal&quot;

<a id="tecs.window.Window.Progress.&quot;paused&quot;"></a>

### tecs.window.Window.Progress.&quot;paused&quot;

<a id="tecs.window.Window.Theme"></a>

### tecs.window.Window.Theme

<pre><code v-pre>enum <a href="#tecs.window.Window.Theme">tecs.window.Window.Theme</a>
</code></pre>

What the desktop asks applications to look like.

<a id="tecs.window.Window.Theme.&quot;dark&quot;"></a>

### tecs.window.Window.Theme.&quot;dark&quot;

<a id="tecs.window.Window.Theme.&quot;light&quot;"></a>

### tecs.window.Window.Theme.&quot;light&quot;

<a id="tecs.window.Window.Theme.&quot;unknown&quot;"></a>

### tecs.window.Window.Theme.&quot;unknown&quot;

<a id="tecs.window.Window.aspectRatio"></a>

### tecs.window.Window.aspectRatio

<pre><code v-pre>function <a href="#tecs.window.Window.aspectRatio">tecs.window.Window.aspectRatio</a>(self: Window): number, number
</code></pre>

Narrowest and widest width-over-height the window may be resized to. Zero
for a bound that is not set.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>number</code> |             |
| <code v-pre>number</code> |             |

<a id="tecs.window.Window.available"></a>

### tecs.window.Window.available

<pre><code v-pre>function <a href="#tecs.window.Window.available">tecs.window.Window.available</a>(): boolean
</code></pre>

Whether there is a video subsystem to ask at all.

False in a process that never brought it up, where every display and
screen-saver function here answers empty rather than failing. `newWindow`
raises there instead, so this is what a caller checks before deciding
whether to open a window.

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.borderSize"></a>

### tecs.window.Window.borderSize

<pre><code v-pre>function <a href="#tecs.window.Window.borderSize">tecs.window.Window.borderSize</a>(self: Window): integer, integer, integer, integer
</code></pre>

Thickness of the window manager's decoration, in screen coordinates:
top, left, bottom and right.

All zero on a platform that does not decorate windows and on a borderless
one, which is the honest answer rather than a failure.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |

<a id="tecs.window.Window.center"></a>

### tecs.window.Window.center

<pre><code v-pre>function <a href="#tecs.window.Window.center">tecs.window.Window.center</a>(self: Window, displayId: integer): boolean
</code></pre>

Centers the window on `display`, or on the display it is already on.

#### Parameters

| Type                       | Name                         | Description |
| -------------------------- | ---------------------------- | ----------- |
| <code v-pre>Window</code>  | <code v-pre>self</code>      |             |
| <code v-pre>integer</code> | <code v-pre>displayId</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.closestFullscreenMode"></a>

### tecs.window.Window.closestFullscreenMode

<pre><code v-pre>function <a href="#tecs.window.Window.closestFullscreenMode">tecs.window.Window.closestFullscreenMode</a>(width: integer, height: integer, refreshRate: number, highDensity: boolean, displayId: integer): Window.DisplayMode
</code></pre>

The mode nearest to a requested size and refresh rate.

What a game restoring a saved resolution asks for, since the display may no
longer offer exactly what was saved. Nil when the display offers nothing
that fits, and with no video.

#### Parameters

| Type                       | Name                           | Description                                                                    |
| -------------------------- | ------------------------------ | ------------------------------------------------------------------------------ |
| <code v-pre>integer</code> | <code v-pre>width</code>       |                                                                                |
| <code v-pre>integer</code> | <code v-pre>height</code>      |                                                                                |
| <code v-pre>number</code>  | <code v-pre>refreshRate</code> | Hertz, or 0 or nil for the highest the size allows.                            |
| <code v-pre>boolean</code> | <code v-pre>highDensity</code> | Whether modes whose pixel density is above 1 may be chosen. Defaults to false. |
| <code v-pre>integer</code> | <code v-pre>displayId</code>   |                                                                                |

#### Returns

| Type                                  | Description |
| ------------------------------------- | ----------- |
| <code v-pre>Window.DisplayMode</code> |             |

<a id="tecs.window.Window.contentScale"></a>

### tecs.window.Window.contentScale

<pre><code v-pre>function <a href="#tecs.window.Window.contentScale">tecs.window.Window.contentScale</a>(displayId: integer): number
</code></pre>

A display's content scale, the same quantity `Window:displayScale` reports
for whichever display a window is on. Zero with no video.

Named for what SDL calls it rather than matching the method, because a
record holds one `displayScale` and the two would be the same field.

#### Parameters

| Type                       | Name                         | Description |
| -------------------------- | ---------------------------- | ----------- |
| <code v-pre>integer</code> | <code v-pre>displayId</code> |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>number</code> |             |

<a id="tecs.window.Window.currentMode"></a>

### tecs.window.Window.currentMode

<pre><code v-pre>function <a href="#tecs.window.Window.currentMode">tecs.window.Window.currentMode</a>(displayId: integer): Window.DisplayMode
</code></pre>

The mode a display is in right now, which differs from `desktopMode` while
something holds it fullscreen at another resolution.

#### Parameters

| Type                       | Name                         | Description |
| -------------------------- | ---------------------------- | ----------- |
| <code v-pre>integer</code> | <code v-pre>displayId</code> |             |

#### Returns

| Type                                  | Description |
| ------------------------------------- | ----------- |
| <code v-pre>Window.DisplayMode</code> |             |

<a id="tecs.window.Window.desktopMode"></a>

### tecs.window.Window.desktopMode

<pre><code v-pre>function <a href="#tecs.window.Window.desktopMode">tecs.window.Window.desktopMode</a>(displayId: integer): Window.DisplayMode
</code></pre>

The mode a display was in when the desktop started, which is what leaving
fullscreen returns it to. Nil with no video.

#### Parameters

| Type                       | Name                         | Description |
| -------------------------- | ---------------------------- | ----------- |
| <code v-pre>integer</code> | <code v-pre>displayId</code> |             |

#### Returns

| Type                                  | Description |
| ------------------------------------- | ----------- |
| <code v-pre>Window.DisplayMode</code> |             |

<a id="tecs.window.Window.destroy"></a>

### tecs.window.Window.destroy

<pre><code v-pre>function <a href="#tecs.window.Window.destroy">tecs.window.Window.destroy</a>(self: Window)
</code></pre>

Releases the window. Safe to call more than once.

Every getter answers zero, false or nil afterwards rather than reading
through a null handle.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

<a id="tecs.window.Window.display"></a>

### tecs.window.Window.display

<pre><code v-pre>function <a href="#tecs.window.Window.display">tecs.window.Window.display</a>(self: Window): integer
</code></pre>

The display this window is mostly on. Zero with no window.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>integer</code> |             |

<a id="tecs.window.Window.displayBounds"></a>

### tecs.window.Window.displayBounds

<pre><code v-pre>function <a href="#tecs.window.Window.displayBounds">tecs.window.Window.displayBounds</a>(displayId: integer): integer, integer, integer, integer
</code></pre>

A display's position and size in the desktop's coordinate space, as x, y,
width and height in screen coordinates.

The width and height are the desktop dimensions, and the x and y are what
makes the coordinates `setPosition` takes span every monitor.

#### Parameters

| Type                       | Name                         | Description |
| -------------------------- | ---------------------------- | ----------- |
| <code v-pre>integer</code> | <code v-pre>displayId</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |

<a id="tecs.window.Window.displayName"></a>

### tecs.window.Window.displayName

<pre><code v-pre>function <a href="#tecs.window.Window.displayName">tecs.window.Window.displayName</a>(displayId: integer): string
</code></pre>

A display's name as the desktop shows it, for a menu that lets the player
choose one. Empty with no video.

#### Parameters

| Type                       | Name                         | Description |
| -------------------------- | ---------------------------- | ----------- |
| <code v-pre>integer</code> | <code v-pre>displayId</code> |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>string</code> |             |

<a id="tecs.window.Window.displayScale"></a>

### tecs.window.Window.displayScale

<pre><code v-pre>function <a href="#tecs.window.Window.displayScale">tecs.window.Window.displayScale</a>(self: Window): number
</code></pre>

How much larger than its natural size the desktop asks content to be drawn.

Not a ratio between `getSize` and `getPixelSize`, which is `pixelDensity`.
This is the user's scaling preference, so it is what a font size or a UI
metric is multiplied by, and it changes without the window resizing.
`events.windowDisplayScaleChanged` reports that it has.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>number</code> |             |

<a id="tecs.window.Window.displays"></a>

### tecs.window.Window.displays

<pre><code v-pre>function <a href="#tecs.window.Window.displays">tecs.window.Window.displays</a>(): {integer}
</code></pre>

Every display currently attached, in the order SDL reports them.

Empty with no video. `events.displayAdded` and `displayRemoved` report that
this list changed, so a game with a display menu rebuilds it there rather
than polling.

#### Returns

| Type                         | Description |
| ---------------------------- | ----------- |
| <code v-pre>{integer}</code> |             |

<a id="tecs.window.Window.flash"></a>

### tecs.window.Window.flash

<pre><code v-pre>function <a href="#tecs.window.Window.flash">tecs.window.Window.flash</a>(self: Window, operation: Window.Flash): boolean
</code></pre>

Asks for the user's attention without taking focus.

The polite form of `raise`: the taskbar entry or the dock icon is marked
and the user decides when to look. `"untilFocused"` keeps asking, which
suits a turn-based game waiting on a player who alt-tabbed away, and
`"cancel"` stops it.

#### Parameters

| Type                            | Name                         | Description |
| ------------------------------- | ---------------------------- | ----------- |
| <code v-pre>Window</code>       | <code v-pre>self</code>      |             |
| <code v-pre>Window.Flash</code> | <code v-pre>operation</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.fullscreenMode"></a>

### tecs.window.Window.fullscreenMode

<pre><code v-pre>function <a href="#tecs.window.Window.fullscreenMode">tecs.window.Window.fullscreenMode</a>(self: Window): Window.DisplayMode
</code></pre>

The video mode fullscreen will use, or nil for borderless fullscreen at
whatever the desktop is already running.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                                  | Description |
| ------------------------------------- | ----------- |
| <code v-pre>Window.DisplayMode</code> |             |

<a id="tecs.window.Window.fullscreenModes"></a>

### tecs.window.Window.fullscreenModes

<pre><code v-pre>function <a href="#tecs.window.Window.fullscreenModes">tecs.window.Window.fullscreenModes</a>(displayId: integer): {Window.DisplayMode}
</code></pre>

Every fullscreen mode a display offers, largest first.

What a resolution menu is built from, and what `setFullscreenMode` takes.
Empty with no video, and on a platform whose only fullscreen is the
desktop's own resolution.

#### Parameters

| Type                       | Name                         | Description |
| -------------------------- | ---------------------------- | ----------- |
| <code v-pre>integer</code> | <code v-pre>displayId</code> |             |

#### Returns

| Type                                    | Description |
| --------------------------------------- | ----------- |
| <code v-pre>{Window.DisplayMode}</code> |             |

<a id="tecs.window.Window.getPixelSize"></a>

### tecs.window.Window.getPixelSize

<pre><code v-pre>function <a href="#tecs.window.Window.getPixelSize">tecs.window.Window.getPixelSize</a>(self: Window): integer, integer
</code></pre>

Returns the drawable size in pixels, which differs from `getSize` on
high-density displays.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |

<a id="tecs.window.Window.getSize"></a>

### tecs.window.Window.getSize

<pre><code v-pre>function <a href="#tecs.window.Window.getSize">tecs.window.Window.getSize</a>(self: Window): integer, integer
</code></pre>

Returns the window's size in screen coordinates.

The units mouse, touch and pen positions arrive in, so this is what a
layout positioned against the pointer uses. `getPixelSize` is what a render
target is sized to.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |

<a id="tecs.window.Window.handle"></a>

### tecs.window.Window.handle

<pre><code v-pre><a href="#tecs.window.Window.handle">tecs.window.Window.handle</a>: loader.CPtr
</code></pre>

The `SDL_Window`. Nil once `destroy` has run, and what a device claims
for presentation.

<a id="tecs.window.Window.hasFocus"></a>

### tecs.window.Window.hasFocus

<pre><code v-pre>function <a href="#tecs.window.Window.hasFocus">tecs.window.Window.hasFocus</a>(self: Window): boolean
</code></pre>

Whether the window has keyboard focus, which is where key events are going.

`events.windowFocusGained` and `windowFocusLost` report the transitions.
This is the value they start from, which no event supplies: a window that
has had focus since it opened has fired neither.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.hasMouseFocus"></a>

### tecs.window.Window.hasMouseFocus

<pre><code v-pre>function <a href="#tecs.window.Window.hasMouseFocus">tecs.window.Window.hasMouseFocus</a>(self: Window): boolean
</code></pre>

Whether the pointer is over the window.

Beside `events.windowMouseEnter` and `windowMouseLeave` on the same terms
as `hasFocus`. False while relative mouse mode is on, since there is no
pointer position for the window to contain.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.hide"></a>

### tecs.window.Window.hide

<pre><code v-pre>function <a href="#tecs.window.Window.hide">tecs.window.Window.hide</a>(self: Window): boolean
</code></pre>

Unmaps the window without destroying it.

Safe while a device holds it: no swapchain texture is acquired while the
window is hidden and the frame is skipped whole rather than drawn nowhere.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.id"></a>

### tecs.window.Window.id

<pre><code v-pre>function <a href="#tecs.window.Window.id">tecs.window.Window.id</a>(self: Window): integer
</code></pre>

The id events name this window by, which is what an event's `which` field
carries. Zero once the window is gone.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>integer</code> |             |

<a id="tecs.window.Window.isAlwaysOnTop"></a>

### tecs.window.Window.isAlwaysOnTop

<pre><code v-pre>function <a href="#tecs.window.Window.isAlwaysOnTop">tecs.window.Window.isAlwaysOnTop</a>(self: Window): boolean
</code></pre>

Whether the window is kept above others.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.isBordered"></a>

### tecs.window.Window.isBordered

<pre><code v-pre>function <a href="#tecs.window.Window.isBordered">tecs.window.Window.isBordered</a>(self: Window): boolean
</code></pre>

Whether the window has a title bar and a frame.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.isFocusable"></a>

### tecs.window.Window.isFocusable

<pre><code v-pre>function <a href="#tecs.window.Window.isFocusable">tecs.window.Window.isFocusable</a>(self: Window): boolean
</code></pre>

Whether the window can take keyboard focus. True for an ordinary window.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.isFullscreen"></a>

### tecs.window.Window.isFullscreen

<pre><code v-pre>function <a href="#tecs.window.Window.isFullscreen">tecs.window.Window.isFullscreen</a>(self: Window): boolean
</code></pre>

Whether the window is fullscreen.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.isMaximized"></a>

### tecs.window.Window.isMaximized

<pre><code v-pre>function <a href="#tecs.window.Window.isMaximized">tecs.window.Window.isMaximized</a>(self: Window): boolean
</code></pre>

Whether the window is maximized.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.isMinimized"></a>

### tecs.window.Window.isMinimized

<pre><code v-pre>function <a href="#tecs.window.Window.isMinimized">tecs.window.Window.isMinimized</a>(self: Window): boolean
</code></pre>

Whether the window is minimized. `events.windowMinimized` reports that it
became so; this is how the first frame after startup finds out.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.isOccluded"></a>

### tecs.window.Window.isOccluded

<pre><code v-pre>function <a href="#tecs.window.Window.isOccluded">tecs.window.Window.isOccluded</a>(self: Window): boolean
</code></pre>

Whether something is covering the window entirely.

A frame drawn now is not seen, which is worth knowing before an expensive
one is built. Independent of minimization: an occluded window is mapped and
not minimized, and both stop the swapchain handing out a texture.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.isResizable"></a>

### tecs.window.Window.isResizable

<pre><code v-pre>function <a href="#tecs.window.Window.isResizable">tecs.window.Window.isResizable</a>(self: Window): boolean
</code></pre>

Whether the window can be resized by dragging its edge. Says nothing about
`setSize`, which works either way.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.isVisible"></a>

### tecs.window.Window.isVisible

<pre><code v-pre>function <a href="#tecs.window.Window.isVisible">tecs.window.Window.isVisible</a>(self: Window): boolean
</code></pre>

Whether the window is mapped. False for a window created `hidden` and one
that `hide` was called on, and true for a minimized window, which is mapped
and not visible.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.keyboardGrab"></a>

### tecs.window.Window.keyboardGrab

<pre><code v-pre>function <a href="#tecs.window.Window.keyboardGrab">tecs.window.Window.keyboardGrab</a>(self: Window): boolean
</code></pre>

Whether the desktop's own keyboard shortcuts are being intercepted.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.maximize"></a>

### tecs.window.Window.maximize

<pre><code v-pre>function <a href="#tecs.window.Window.maximize">tecs.window.Window.maximize</a>(self: Window): boolean
</code></pre>

Maximizes the window to fill the display's usable bounds.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.maximumSize"></a>

### tecs.window.Window.maximumSize

<pre><code v-pre>function <a href="#tecs.window.Window.maximumSize">tecs.window.Window.maximumSize</a>(self: Window): integer, integer
</code></pre>

Largest size the window may be resized to, in screen coordinates. Zero for
a dimension that has no limit.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |

<a id="tecs.window.Window.minimize"></a>

### tecs.window.Window.minimize

<pre><code v-pre>function <a href="#tecs.window.Window.minimize">tecs.window.Window.minimize</a>(self: Window): boolean
</code></pre>

Minimizes the window to the taskbar or dock.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.minimumSize"></a>

### tecs.window.Window.minimumSize

<pre><code v-pre>function <a href="#tecs.window.Window.minimumSize">tecs.window.Window.minimumSize</a>(self: Window): integer, integer
</code></pre>

Smallest size the window may be resized to, in screen coordinates.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |

<a id="tecs.window.Window.mouseGrab"></a>

### tecs.window.Window.mouseGrab

<pre><code v-pre>function <a href="#tecs.window.Window.mouseGrab">tecs.window.Window.mouseGrab</a>(self: Window): boolean
</code></pre>

Whether the pointer is confined to the window right now.

False for an unfocused window even where `setMouseGrab` was called and
succeeded, since a window that is not receiving the pointer is not holding
it either. Becomes true again when focus returns.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.mouseRect"></a>

### tecs.window.Window.mouseRect

<pre><code v-pre>function <a href="#tecs.window.Window.mouseRect">tecs.window.Window.mouseRect</a>(self: Window): integer, integer, integer, integer
</code></pre>

The region within the window the pointer is confined to, as x, y, width and
height in screen coordinates. All zero when there is none.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |

<a id="tecs.window.Window.naturalOrientation"></a>

### tecs.window.Window.naturalOrientation

<pre><code v-pre>function <a href="#tecs.window.Window.naturalOrientation">tecs.window.Window.naturalOrientation</a>(displayId: integer): Window.Orientation
</code></pre>

How a display is built to be held, which does not change.

What tells a landscape reading apart from a device that is landscape to
begin with, and so what a game deciding whether to letterbox or rotate its
own content asks alongside `orientation`.

#### Parameters

| Type                       | Name                         | Description |
| -------------------------- | ---------------------------- | ----------- |
| <code v-pre>integer</code> | <code v-pre>displayId</code> |             |

#### Returns

| Type                                  | Description |
| ------------------------------------- | ----------- |
| <code v-pre>Window.Orientation</code> |             |

<a id="tecs.window.Window.newWindow"></a>

### tecs.window.Window.newWindow

<pre><code v-pre>function <a href="#tecs.window.Window.newWindow">tecs.window.Window.newWindow</a>(options: Window.Options): Window
</code></pre>

Creates a window. Requires `SDL_Init(SDL_INIT_VIDEO)` to have run.

Flags that SDL only accepts at creation are taken from `options` and set
here; everything else in `options` is applied straight afterwards, and has
a setter of its own, so nothing is reachable at creation that is not
reachable later.

#### Parameters

| Type                              | Name                       | Description |
| --------------------------------- | -------------------------- | ----------- |
| <code v-pre>Window.Options</code> | <code v-pre>options</code> |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>Window</code> |             |

<a id="tecs.window.Window.opacity"></a>

### tecs.window.Window.opacity

<pre><code v-pre>function <a href="#tecs.window.Window.opacity">tecs.window.Window.opacity</a>(self: Window): number
</code></pre>

How opaque the window is, 0 for invisible and 1 for solid. Zero with no
window, and 1 on a platform that composites nothing.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>number</code> |             |

<a id="tecs.window.Window.orientation"></a>

### tecs.window.Window.orientation

<pre><code v-pre>function <a href="#tecs.window.Window.orientation">tecs.window.Window.orientation</a>(displayId: integer): Window.Orientation
</code></pre>

How a display is rotated right now. `events.displayOrientation` reports
that it turned.

#### Parameters

| Type                       | Name                         | Description |
| -------------------------- | ---------------------------- | ----------- |
| <code v-pre>integer</code> | <code v-pre>displayId</code> |             |

#### Returns

| Type                                  | Description |
| ------------------------------------- | ----------- |
| <code v-pre>Window.Orientation</code> |             |

<a id="tecs.window.Window.pixelDensity"></a>

### tecs.window.Window.pixelDensity

<pre><code v-pre>function <a href="#tecs.window.Window.pixelDensity">tecs.window.Window.pixelDensity</a>(self: Window): number
</code></pre>

Ratio of pixels to screen coordinates: 2.0 on a display where the drawable
is twice the window. 1.0 without `highPixelDensity`, and 0 with no window.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>number</code> |             |

<a id="tecs.window.Window.position"></a>

### tecs.window.Window.position

<pre><code v-pre>function <a href="#tecs.window.Window.position">tecs.window.Window.position</a>(self: Window): integer, integer
</code></pre>

Position of the window's top-left corner in screen coordinates.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |

<a id="tecs.window.Window.primaryDisplay"></a>

### tecs.window.Window.primaryDisplay

<pre><code v-pre>function <a href="#tecs.window.Window.primaryDisplay">tecs.window.Window.primaryDisplay</a>(): integer
</code></pre>

The display the desktop treats as primary, or zero with no video.

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>integer</code> |             |

<a id="tecs.window.Window.progress"></a>

### tecs.window.Window.progress

<pre><code v-pre>function <a href="#tecs.window.Window.progress">tecs.window.Window.progress</a>(self: Window): Window.Progress, number
</code></pre>

What the taskbar or dock is showing over the application's icon, and how
far along it is. "none" and 0 with no window.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                               | Description |
| ---------------------------------- | ----------- |
| <code v-pre>Window.Progress</code> |             |
| <code v-pre>number</code>          |             |

<a id="tecs.window.Window.raise"></a>

### tecs.window.Window.raise

<pre><code v-pre>function <a href="#tecs.window.Window.raise">tecs.window.Window.raise</a>(self: Window): boolean
</code></pre>

Brings the window to the front and gives it input focus.

Distinct from `flash`: this takes focus, which a desktop may refuse or may
allow to interrupt whatever the user was doing. Ask for attention instead
unless the user just did something that expects a window to come forward.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.restore"></a>

### tecs.window.Window.restore

<pre><code v-pre>function <a href="#tecs.window.Window.restore">tecs.window.Window.restore</a>(self: Window): boolean
</code></pre>

Returns a minimized or maximized window to its previous size and position.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.safeArea"></a>

### tecs.window.Window.safeArea

<pre><code v-pre>function <a href="#tecs.window.Window.safeArea">tecs.window.Window.safeArea</a>(self: Window): integer, integer, integer, integer
</code></pre>

The part of the window nothing is drawn over, as x, y, width and height in
screen coordinates.

The whole window on a desktop. Smaller where a notch, a rounded corner or a
system gesture area overlaps it, which is what a phone or a handheld needs
to keep a health bar out from under. `events.windowSafeAreaChanged` reports
that it moved.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |

<a id="tecs.window.Window.screenSaverEnabled"></a>

### tecs.window.Window.screenSaverEnabled

<pre><code v-pre>function <a href="#tecs.window.Window.screenSaverEnabled">tecs.window.Window.screenSaverEnabled</a>(): boolean
</code></pre>

Whether the desktop is allowed to blank the display while this application
runs.

False for most of a game's life, since SDL disables the screen saver as
soon as video comes up: a player holding a gamepad is not idle, and the
keyboard and mouse are what the desktop watches. Turn it back on for a menu
or a cutscene nobody is playing through.

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setAlwaysOnTop"></a>

### tecs.window.Window.setAlwaysOnTop

<pre><code v-pre>function <a href="#tecs.window.Window.setAlwaysOnTop">tecs.window.Window.setAlwaysOnTop</a>(self: Window, onTop: boolean): boolean
</code></pre>

Keeps the window above others, or stops doing so.

#### Parameters

| Type                       | Name                     | Description |
| -------------------------- | ------------------------ | ----------- |
| <code v-pre>Window</code>  | <code v-pre>self</code>  |             |
| <code v-pre>boolean</code> | <code v-pre>onTop</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setAspectRatio"></a>

### tecs.window.Window.setAspectRatio

<pre><code v-pre>function <a href="#tecs.window.Window.setAspectRatio">tecs.window.Window.setAspectRatio</a>(self: Window, minimum: number, maximum: number): boolean
</code></pre>

Constrains resizing to a range of width-over-height ratios.

The same value for both pins the window to one shape, which is what a game
that will not letterbox wants. Zero for either removes that bound.

#### Parameters

| Type                      | Name                       | Description |
| ------------------------- | -------------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code>    |             |
| <code v-pre>number</code> | <code v-pre>minimum</code> |             |
| <code v-pre>number</code> | <code v-pre>maximum</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setBordered"></a>

### tecs.window.Window.setBordered

<pre><code v-pre>function <a href="#tecs.window.Window.setBordered">tecs.window.Window.setBordered</a>(self: Window, bordered: boolean): boolean
</code></pre>

Adds or removes the title bar and the frame. The client area keeps its
size, so the window as a whole changes size by the border thickness.

#### Parameters

| Type                       | Name                        | Description |
| -------------------------- | --------------------------- | ----------- |
| <code v-pre>Window</code>  | <code v-pre>self</code>     |             |
| <code v-pre>boolean</code> | <code v-pre>bordered</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setFocusable"></a>

### tecs.window.Window.setFocusable

<pre><code v-pre>function <a href="#tecs.window.Window.setFocusable">tecs.window.Window.setFocusable</a>(self: Window, focusable: boolean): boolean
</code></pre>

Allows or forbids the window taking keyboard focus. A window that cannot
take focus is what an overlay uses to stay out of the way.

#### Parameters

| Type                       | Name                         | Description |
| -------------------------- | ---------------------------- | ----------- |
| <code v-pre>Window</code>  | <code v-pre>self</code>      |             |
| <code v-pre>boolean</code> | <code v-pre>focusable</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setFullscreen"></a>

### tecs.window.Window.setFullscreen

<pre><code v-pre>function <a href="#tecs.window.Window.setFullscreen">tecs.window.Window.setFullscreen</a>(self: Window, fullscreen: boolean): boolean
</code></pre>

Enters or leaves fullscreen.

Which fullscreen depends on `setFullscreenMode`: with no mode set this is
borderless fullscreen at the desktop's own resolution, which is what a
window that shares a display with other applications wants. With a mode set
it changes the display's video mode to it.

Safe while a device holds the window. The swapchain follows the new size
and the renderer picks it up from the texture it acquires next frame.
`events.windowEnterFullscreen` and `windowLeaveFullscreen` report that the
change actually landed, which on a compositing window system is later than
this returns; `sync` is the other way to wait for it.

#### Parameters

| Type                       | Name                          | Description |
| -------------------------- | ----------------------------- | ----------- |
| <code v-pre>Window</code>  | <code v-pre>self</code>       |             |
| <code v-pre>boolean</code> | <code v-pre>fullscreen</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setFullscreenMode"></a>

### tecs.window.Window.setFullscreenMode

<pre><code v-pre>function <a href="#tecs.window.Window.setFullscreenMode">tecs.window.Window.setFullscreenMode</a>(self: Window, mode: Window.DisplayMode): boolean
</code></pre>

Chooses the video mode fullscreen uses, or nil for borderless fullscreen at
the desktop's resolution.

The mode has to have come from `fullscreenModes` or
`closestFullscreenMode`, because SDL matches it against the modes the
display actually has and a record assembled by hand names one that may not
exist. Takes effect the next time the window is made fullscreen, and
immediately if it already is.

#### Parameters

| Type                                  | Name                    | Description |
| ------------------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code>             | <code v-pre>self</code> |             |
| <code v-pre>Window.DisplayMode</code> | <code v-pre>mode</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setIcon"></a>

### tecs.window.Window.setIcon

<pre><code v-pre>function <a href="#tecs.window.Window.setIcon">tecs.window.Window.setIcon</a>(self: Window, path: string): boolean
</code></pre>

Sets the image the desktop shows the window as.

Decoded synchronously from `path`, because an icon is wanted before the
first frame and the asset system decodes on a worker and answers with a GPU
texture, which is not what SDL takes. SDL copies the pixels, so nothing is
retained here. False when the file could not be decoded.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |
| <code v-pre>string</code> | <code v-pre>path</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setKeyboardGrab"></a>

### tecs.window.Window.setKeyboardGrab

<pre><code v-pre>function <a href="#tecs.window.Window.setKeyboardGrab">tecs.window.Window.setKeyboardGrab</a>(self: Window, grabbed: boolean): boolean
</code></pre>

Intercepts the desktop's keyboard shortcuts while the window has focus, so
that alt-tab and the like reach the game instead.

Costly to get wrong, since it is how a window stops the user leaving it.
Some desktops refuse it outright and some require a permission the user
grants once.

#### Parameters

| Type                       | Name                       | Description |
| -------------------------- | -------------------------- | ----------- |
| <code v-pre>Window</code>  | <code v-pre>self</code>    |             |
| <code v-pre>boolean</code> | <code v-pre>grabbed</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setMaximumSize"></a>

### tecs.window.Window.setMaximumSize

<pre><code v-pre>function <a href="#tecs.window.Window.setMaximumSize">tecs.window.Window.setMaximumSize</a>(self: Window, width: integer, height: integer): boolean
</code></pre>

Sets the largest size the window may be resized to. Zero for either
dimension removes the limit on it.

#### Parameters

| Type                       | Name                      | Description |
| -------------------------- | ------------------------- | ----------- |
| <code v-pre>Window</code>  | <code v-pre>self</code>   |             |
| <code v-pre>integer</code> | <code v-pre>width</code>  |             |
| <code v-pre>integer</code> | <code v-pre>height</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setMinimumSize"></a>

### tecs.window.Window.setMinimumSize

<pre><code v-pre>function <a href="#tecs.window.Window.setMinimumSize">tecs.window.Window.setMinimumSize</a>(self: Window, width: integer, height: integer): boolean
</code></pre>

Sets the smallest size the window may be resized to. Zero for either
dimension removes the limit on it.

#### Parameters

| Type                       | Name                      | Description |
| -------------------------- | ------------------------- | ----------- |
| <code v-pre>Window</code>  | <code v-pre>self</code>   |             |
| <code v-pre>integer</code> | <code v-pre>width</code>  |             |
| <code v-pre>integer</code> | <code v-pre>height</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setMouseGrab"></a>

### tecs.window.Window.setMouseGrab

<pre><code v-pre>function <a href="#tecs.window.Window.setMouseGrab">tecs.window.Window.setMouseGrab</a>(self: Window, grabbed: boolean): boolean
</code></pre>

Confines the pointer to the window, or releases it.

Not the same as `Input:setRelativeMouseMode`, which hides the pointer and
delivers deltas: this leaves the pointer visible and stops it walking onto
another monitor. A game that wants both sets both.

Taking the request is not the same as the grab being in force, which is
what `mouseGrab` answers: an unfocused window records the request and holds
nothing until focus comes back.

#### Parameters

| Type                       | Name                       | Description |
| -------------------------- | -------------------------- | ----------- |
| <code v-pre>Window</code>  | <code v-pre>self</code>    |             |
| <code v-pre>boolean</code> | <code v-pre>grabbed</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setMouseRect"></a>

### tecs.window.Window.setMouseRect

<pre><code v-pre>function <a href="#tecs.window.Window.setMouseRect">tecs.window.Window.setMouseRect</a>(self: Window, x: integer, y: integer, width: integer, height: integer): boolean
</code></pre>

Confines the pointer to part of the window, in screen coordinates.

Independent of `setMouseGrab`, which confines it to the window as a whole;
this applies while the window has focus whether or not the window is
grabbed. Called with nothing, the region is removed.

#### Parameters

| Type                       | Name                      | Description |
| -------------------------- | ------------------------- | ----------- |
| <code v-pre>Window</code>  | <code v-pre>self</code>   |             |
| <code v-pre>integer</code> | <code v-pre>x</code>      |             |
| <code v-pre>integer</code> | <code v-pre>y</code>      |             |
| <code v-pre>integer</code> | <code v-pre>width</code>  |             |
| <code v-pre>integer</code> | <code v-pre>height</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setOpacity"></a>

### tecs.window.Window.setOpacity

<pre><code v-pre>function <a href="#tecs.window.Window.setOpacity">tecs.window.Window.setOpacity</a>(self: Window, opacity: number): boolean
</code></pre>

Sets how opaque the window is, 0 to 1. Whether the desktop honours it is
the desktop's business; false says it did not.

#### Parameters

| Type                      | Name                       | Description |
| ------------------------- | -------------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code>    |             |
| <code v-pre>number</code> | <code v-pre>opacity</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setPosition"></a>

### tecs.window.Window.setPosition

<pre><code v-pre>function <a href="#tecs.window.Window.setPosition">tecs.window.Window.setPosition</a>(self: Window, x: integer, y: integer): boolean
</code></pre>

Moves the window, in screen coordinates.

The coordinate space spans every display, so a negative or very large
position is how a window is put on a second monitor.

#### Parameters

| Type                       | Name                    | Description |
| -------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code>  | <code v-pre>self</code> |             |
| <code v-pre>integer</code> | <code v-pre>x</code>    |             |
| <code v-pre>integer</code> | <code v-pre>y</code>    |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setProgress"></a>

### tecs.window.Window.setProgress

<pre><code v-pre>function <a href="#tecs.window.Window.setProgress">tecs.window.Window.setProgress</a>(self: Window, state: Window.Progress, value: number): boolean
</code></pre>

Shows how far along a long piece of work is, on the taskbar or the dock.

What a shader pack build or an asset load has to report to, since neither
can draw a progress bar in a window that is not rendering yet. `value` runs
0 to 1 and only means anything for "normal", "paused" and "error".

#### Parameters

| Type                               | Name                     | Description |
| ---------------------------------- | ------------------------ | ----------- |
| <code v-pre>Window</code>          | <code v-pre>self</code>  |             |
| <code v-pre>Window.Progress</code> | <code v-pre>state</code> |             |
| <code v-pre>number</code>          | <code v-pre>value</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setResizable"></a>

### tecs.window.Window.setResizable

<pre><code v-pre>function <a href="#tecs.window.Window.setResizable">tecs.window.Window.setResizable</a>(self: Window, resizable: boolean): boolean
</code></pre>

Allows or forbids the user resizing the window.

#### Parameters

| Type                       | Name                         | Description |
| -------------------------- | ---------------------------- | ----------- |
| <code v-pre>Window</code>  | <code v-pre>self</code>      |             |
| <code v-pre>boolean</code> | <code v-pre>resizable</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setScreenSaverEnabled"></a>

### tecs.window.Window.setScreenSaverEnabled

<pre><code v-pre>function <a href="#tecs.window.Window.setScreenSaverEnabled">tecs.window.Window.setScreenSaverEnabled</a>(enabled: boolean): boolean
</code></pre>

Allows or forbids the desktop blanking the display.

Applies to the whole application rather than to one window, which is why it
is here and not a method. False with no video.

#### Parameters

| Type                       | Name                       | Description |
| -------------------------- | -------------------------- | ----------- |
| <code v-pre>boolean</code> | <code v-pre>enabled</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setSize"></a>

### tecs.window.Window.setSize

<pre><code v-pre>function <a href="#tecs.window.Window.setSize">tecs.window.Window.setSize</a>(self: Window, width: integer, height: integer): boolean
</code></pre>

Resizes the window, in screen coordinates.

Safe while a device holds the window: the swapchain is recreated by SDL and
the renderer sizes its targets to the texture it acquires next frame. A
fullscreen window ignores this, and a window whose size the compositor has
to agree to reports the old size until `sync` returns.

#### Parameters

| Type                       | Name                      | Description |
| -------------------------- | ------------------------- | ----------- |
| <code v-pre>Window</code>  | <code v-pre>self</code>   |             |
| <code v-pre>integer</code> | <code v-pre>width</code>  |             |
| <code v-pre>integer</code> | <code v-pre>height</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.setTitle"></a>

### tecs.window.Window.setTitle

<pre><code v-pre>function <a href="#tecs.window.Window.setTitle">tecs.window.Window.setTitle</a>(self: Window, title: string): boolean
</code></pre>

Sets the window's title, and the copy `title` reports.

#### Parameters

| Type                      | Name                     | Description |
| ------------------------- | ------------------------ | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code>  |             |
| <code v-pre>string</code> | <code v-pre>title</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.show"></a>

### tecs.window.Window.show

<pre><code v-pre>function <a href="#tecs.window.Window.show">tecs.window.Window.show</a>(self: Window): boolean
</code></pre>

Maps the window onto the desktop. What a window created `hidden` needs
before anything it draws is seen.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.sync"></a>

### tecs.window.Window.sync

<pre><code v-pre>function <a href="#tecs.window.Window.sync">tecs.window.Window.sync</a>(self: Window): boolean
</code></pre>

Waits for pending window changes to be applied.

Size, position and fullscreen are requests rather than commands on a
compositing window system, and SDL reports the old value until the
compositor answers. This blocks until it has, so a caller that must read
back what it just set has somewhere to wait. Everywhere else the change is
already applied and this returns immediately.

Returns false when the changes did not land in SDL's timeout, and false
with no window.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Window</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.window.Window.theme"></a>

### tecs.window.Window.theme

<pre><code v-pre>function <a href="#tecs.window.Window.theme">tecs.window.Window.theme</a>(): Window.Theme
</code></pre>

Whether the desktop is asking applications to draw themselves light or
dark. "unknown" where the platform has no such preference, and with no
video.

#### Returns

| Type                            | Description |
| ------------------------------- | ----------- |
| <code v-pre>Window.Theme</code> |             |

<a id="tecs.window.Window.title"></a>

### tecs.window.Window.title

<pre><code v-pre><a href="#tecs.window.Window.title">tecs.window.Window.title</a>: string
</code></pre>

The title last set, kept so reading it back does not cross the FFI.

<a id="tecs.window.Window.usableBounds"></a>

### tecs.window.Window.usableBounds

<pre><code v-pre>function <a href="#tecs.window.Window.usableBounds">tecs.window.Window.usableBounds</a>(displayId: integer): integer, integer, integer, integer
</code></pre>

The part of a display not covered by a taskbar, dock or menu bar, in the
same coordinates as `displayBounds`.

Where a window should be placed and how large it should be to be usable,
which `displayBounds` does not answer. `events.displayUsableBoundsChanged`
reports that it moved.

#### Parameters

| Type                       | Name                         | Description |
| -------------------------- | ---------------------------- | ----------- |
| <code v-pre>integer</code> | <code v-pre>displayId</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |
| <code v-pre>integer</code> |             |
