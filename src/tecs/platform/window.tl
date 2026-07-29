--[[
# Windows

`tecs.window` creates OS windows and reads the displays around them.
[`Application`](tealdoc:tecs.Application) creates the usual game window as
`app.window`. Tools and tests that call `newWindow` directly must call
`destroy` when they finish.

```teal
local window <const> = tecs.window.newWindow({
    title = "Starfarer",
    width = 1600,
    height = 900,
    hidden = true,
})

window:center()
window:show()
```

## Screen coordinates and pixels

Window layout and pointer input use screen coordinates. Render targets use
pixels. A high-density display may put several pixels behind one screen
coordinate.

```teal
local width <const>, height <const> = window:getSize()
local pixelWidth <const>, pixelHeight <const> = window:getPixelSize()
local density <const> = window:pixelDensity()

assert(pixelWidth == width * density)
assert(pixelHeight == height * density)
```

`displayScale` reports the desktop's preferred scale for text and interface
metrics. It does not convert between the two sizes.

## Compositor changes

Size, position and fullscreen setters may return before the compositor applies
the request. Most games consume the corresponding event later. Call `sync`
only before an immediate readback.

```teal
window:setSize(1280, 720)
if window:sync() then
    local width <const>, height <const> = window:getSize()
end
```

## Fullscreen modes

Fullscreen uses the desktop resolution when the caller selects no mode.
Exclusive fullscreen accepts only a mode that `fullscreenModes` or
`closestFullscreenMode` returns.

```teal
local mode <const> = tecs.window.Window.closestFullscreenMode(
    savedWidth,
    savedHeight,
    savedRefreshRate,
    true
)

if mode ~= nil then
    window:setFullscreenMode(mode)
    window:setFullscreen(true)
end
```

## Display placement

Desktop positions span every attached display and may contain negative
coordinates. Use usable bounds to keep windows clear of a taskbar, dock or
menu bar.

```teal
for _, displayId in ipairs(tecs.window.Window.displays()) do
    local x <const>, y <const>, width <const>, height <const> =
        tecs.window.Window.usableBounds(displayId)
end
```

Display and window events report changes. Getters report current state,
including state that existed before the first event. Use `Window:id` to match a
window event's `which` field.

## Pointer ownership

The window API owns mouse and keyboard confinement. `tecs.input` owns relative
mouse mode, warping, capture and cursor visibility. The GPU device owns
presentation pacing after it claims a window.
]]

-- Implementation details: the desktop window manager implements confinement,
-- while SDL carries the commands across the platform boundary.

local ffi <const> = require("ffi")
local bit <const> = require("bit")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K
local VIDEO <const> = K.SDL_INIT_VIDEO

local record window
    --- A `Window` owns one open OS window and reads the displays around it.
    ---
    --- Game code changes state through methods. Public fields expose framework
    --- state and remain read-only to callers.
    record Window
        --- Engine-owned. The framework stores the native window handle here for
        --- the GPU device to claim for presentation and sets it to nil when
        --- `destroy` runs. Ordinary game code ignores this field.
        handle: loader.CPtr
        --- Read-only. The framework stores the last title here when it creates
        --- the window or `setTitle` succeeds. Game code changes it through
        --- `setTitle`.
        title: string
        _destroyed: boolean

        --- `Orientation` describes a display's current or natural rotation.
        enum Orientation
            --- `"unknown"` reports that the platform cannot name the rotation.
            "unknown"
            --- `"landscape"` reports the natural landscape direction.
            "landscape"
            --- `"landscapeFlipped"` reports landscape rotated by half a turn.
            "landscapeFlipped"
            --- `"portrait"` reports the natural portrait direction.
            "portrait"
            --- `"portraitFlipped"` reports portrait rotated by half a turn.
            "portraitFlipped"
        end

        --- `Theme` describes the desktop's requested appearance.
        enum Theme
            --- `"unknown"` reports that the desktop has no theme preference.
            "unknown"
            --- `"light"` asks applications to use a light appearance.
            "light"
            --- `"dark"` asks applications to use a dark appearance.
            "dark"
        end

        --- `Flash` selects how long the desktop asks for attention.
        enum Flash
            --- `"cancel"` stops a flash already running.
            "cancel"
            --- `"brief"` asks once, whether or not anybody was looking.
            "brief"
            --- `"untilFocused"` keeps asking until the window gains focus.
            "untilFocused"
        end

        --- `Progress` selects what the taskbar or dock shows over the icon.
        enum Progress
            --- `"none"` hides progress and is the initial state.
            "none"
            --- `"indeterminate"` reports work whose extent is unknown.
            "indeterminate"
            --- `"normal"` reports work that is progressing normally.
            "normal"
            --- `"paused"` reports work that may resume.
            "paused"
            --- `"error"` reports work that stopped because it failed.
            "error"
        end

        --- `DisplayMode` describes one video mode returned by the platform.
        ---
        --- Callers treat every field as read-only and pass the record back to
        --- `setFullscreenMode`.
        record DisplayMode
            --- Read-only. The platform sets `display` when it builds the mode.
            display: integer
            --- Read-only. The platform sets `width` in screen coordinates when
            --- it builds the mode. Callers multiply it by `pixelDensity` to
            --- obtain pixels.
            width: integer
            --- Read-only. The platform sets `height` in screen coordinates
            --- when it builds the mode. Callers multiply it by `pixelDensity`
            --- to obtain pixels.
            height: integer
            --- Read-only. The platform sets `pixelDensity` when it builds the
            --- mode. A 1920 by 1080 mode at 2.0 draws 3840 by 2160 pixels.
            pixelDensity: number
            --- Read-only. The platform sets `refreshRate` in hertz when it
            --- builds the mode, or to zero when it cannot report a rate.
            refreshRate: number
            -- Implementation details: this native mode handle lets
            -- `setFullscreenMode` return a selected mode to the platform.
            _mode: loader.CPtr
        end

        --- Callers may set any
        --- [`Options`](tealdoc:tecs.window.Window.Options) field before passing
        --- the record to `newWindow`. The function reads the values and does
        --- not retain the record.
        record Options
            --- Caller-writable. The caller sets `title` to the desktop title
            --- before `newWindow` reads it. It defaults to `"tecs"`.
            title: string
            --- Caller-writable. The caller sets `width` in screen coordinates
            --- before `newWindow` reads it. It defaults to 1280.
            width: integer
            --- Caller-writable. The caller sets `height` in screen coordinates
            --- before `newWindow` reads it. It defaults to 720.
            height: integer
            --- Caller-writable. The caller sets `resizable` before `newWindow`
            --- reads it. It defaults to true, and only false disables edge
            --- resizing.
            resizable: boolean
            --- Caller-writable. The caller sets `highPixelDensity` before
            --- `newWindow` reads it. It defaults to true and lets the drawable
            --- follow the display density instead of stretching.
            highPixelDensity: boolean
            --- Caller-writable. The caller sets `fullscreen` before
            --- `newWindow` reads it to start on the display selected by the
            --- window manager. It defaults to false.
            fullscreen: boolean
            --- Caller-writable. The caller sets `borderless` before
            --- `newWindow` reads it to remove the title bar and frame. It
            --- defaults to false.
            borderless: boolean
            --- Caller-writable. The caller sets `hidden` before `newWindow`
            --- reads it to defer mapping until `show`. It defaults to false.
            hidden: boolean
            --- Caller-writable. The caller sets `alwaysOnTop` before
            --- `newWindow` reads it to keep the window above others. It
            --- defaults to false.
            alwaysOnTop: boolean
            --- Caller-writable. The caller sets `transparent` before
            --- `newWindow` reads it to request desktop alpha compositing. It
            --- defaults to false.
            transparent: boolean
            --- Caller-writable. The caller sets `x` with `y` before
            --- `newWindow` reads them. Without both fields, the window manager
            --- chooses the position.
            x: integer
            --- Caller-writable. The caller sets `y` with `x` before
            --- `newWindow` reads them.
            y: integer
            --- Caller-writable. The caller sets `minWidth` with `minHeight`
            --- before `newWindow` reads them.
            minWidth: integer
            --- Caller-writable. The caller sets `minHeight` with `minWidth`
            --- before `newWindow` reads them.
            minHeight: integer
            --- Caller-writable. The caller sets `maxWidth` with `maxHeight`
            --- before `newWindow` reads them.
            maxWidth: integer
            --- Caller-writable. The caller sets `maxHeight` with `maxWidth`
            --- before `newWindow` reads them.
            maxHeight: integer
            --- Caller-writable. The caller sets `icon` to an image path before
            --- `newWindow` reads it. `newWindow` decodes it synchronously.
            icon: string
        end

        --- Returns whether the platform can create and inspect windows.
        ---
        --- False in a headless process. Display and screen-saver functions
        --- answer harmless defaults there, while `newWindow` raises.
        ---
        --- @return Returns true when this process can create and inspect windows.
        available: function(): boolean

        --- Releases the window. Safe to call more than once.
        ---
        --- Every getter answers zero, false or nil after this call.
        destroy: function(self: Window)

        --- Returns the id carried in a window event's `which` field.
        ---
        --- @return Returns the platform window id, or zero after `destroy`.
        id: function(self: Window): integer

        --- Waits for the compositor to apply pending window changes.
        ---
        --- Size, position and fullscreen changes may land after their setters
        --- return. Call this only when code must read a changed value back
        --- immediately.
        ---
        --- @return Returns false when the platform times out or after `destroy`.
        sync: function(self: Window): boolean

        --- Reads the window size in screen coordinates.
        ---
        --- Pointer positions use these units. Render targets use
        --- `getPixelSize`.
        ---
        --- @return Returns the width, or zero after `destroy`.
        --- @return Returns the height, or zero after `destroy`.
        getSize: function(self: Window): integer, integer

        --- Reads the drawable size in pixels.
        ---
        --- @return Returns the pixel width, or zero after `destroy`.
        --- @return Returns the pixel height, or zero after `destroy`.
        getPixelSize: function(self: Window): integer, integer

        --- Resizes the window in screen coordinates.
        ---
        --- A fullscreen window ignores the request. A compositor may apply it
        --- after this returns; use `sync` before an immediate readback.
        ---
        --- @param width The caller supplies the new width in screen coordinates.
        --- @param height The caller supplies the new height in screen coordinates.
        --- @return Returns whether the platform accepted the request.
        setSize: function(self: Window, width: integer, height: integer): boolean

        --- Returns the ratio of drawable pixels to screen coordinates.
        ---
        --- @return Returns the ratio, 1 without high-density drawing, or zero after
        ---     `destroy`.
        pixelDensity: function(self: Window): number

        --- Returns the desktop's preferred scale for content.
        ---
        --- This is not the ratio between `getSize` and `getPixelSize`; use
        --- `pixelDensity` for that. A theme or UI can multiply its natural
        --- metrics by this value.
        ---
        --- @return Returns the scale, or zero after `destroy`.
        displayScale: function(self: Window): number

        --- Reads the top-left corner in desktop screen coordinates.
        ---
        --- @return Returns the horizontal position, or zero after `destroy`.
        --- @return Returns the vertical position, or zero after `destroy`.
        position: function(self: Window): integer, integer

        --- Moves the window in desktop screen coordinates.
        ---
        --- The coordinate space spans all displays and may contain negative
        --- positions.
        ---
        --- @param x The caller supplies the horizontal position.
        --- @param y The caller supplies the vertical position.
        --- @return Returns whether the platform accepted the request.
        setPosition: function(self: Window, x: integer, y: integer): boolean

        --- Centers the window on a display.
        ---
        --- @param displayId The caller omits this value to use the display the
        ---     window occupies.
        --- @return Returns whether the platform accepted the request.
        center: function(self: Window, displayId?: integer): boolean

        --- Reads the window decoration thickness in screen coordinates.
        ---
        --- @return Returns the top thickness, or zero without decoration.
        --- @return Returns the left thickness, or zero without decoration.
        --- @return Returns the bottom thickness, or zero without decoration.
        --- @return Returns the right thickness, or zero without decoration.
        borderSize: function(self: Window): integer, integer, integer, integer

        --- Reads the unobstructed region inside the window.
        ---
        --- A desktop normally returns the whole window. Phones and handhelds
        --- may exclude notches, rounded corners or gesture areas.
        ---
        --- @return Returns the horizontal offset in screen coordinates.
        --- @return Returns the vertical offset in screen coordinates.
        --- @return Returns the width in screen coordinates.
        --- @return Returns the height in screen coordinates.
        safeArea: function(self: Window): integer, integer, integer, integer

        --- Reads the minimum resize limit.
        ---
        --- @return Returns the minimum width, or zero when unset.
        --- @return Returns the minimum height, or zero when unset.
        minimumSize: function(self: Window): integer, integer

        --- Sets the minimum resize limit.
        ---
        --- @param width The caller supplies the minimum width, or zero to remove
        ---     that limit.
        --- @param height The caller supplies the minimum height, or zero to remove
        ---     that limit.
        --- @return Returns whether the platform accepted the limits.
        setMinimumSize: function(self: Window, width: integer, height: integer): boolean

        --- Reads the maximum resize limit.
        ---
        --- @return Returns the maximum width, or zero when unset.
        --- @return Returns the maximum height, or zero when unset.
        maximumSize: function(self: Window): integer, integer

        --- Sets the maximum resize limit.
        ---
        --- @param width The caller supplies the maximum width, or zero to remove
        ---     that limit.
        --- @param height The caller supplies the maximum height, or zero to remove
        ---     that limit.
        --- @return Returns whether the platform accepted the limits.
        setMaximumSize: function(self: Window, width: integer, height: integer): boolean

        --- Reads the allowed width-over-height range.
        ---
        --- @return Returns the minimum ratio, or zero when unset.
        --- @return Returns the maximum ratio, or zero when unset.
        aspectRatio: function(self: Window): number, number

        --- Constrains the width-over-height ratio.
        ---
        --- Equal values pin the window to one shape.
        ---
        --- @param minimum The caller supplies the minimum ratio, or zero to
        ---     remove that bound.
        --- @param maximum The caller supplies the maximum ratio, or zero to
        ---     remove that bound.
        --- @return Returns whether the platform accepted the bounds.
        setAspectRatio: function(self: Window, minimum: number, maximum: number): boolean

        --- Maps a hidden window onto the desktop.
        ---
        --- @return Returns whether the platform showed the window.
        show: function(self: Window): boolean

        --- Unmaps the window without destroying it.
        ---
        --- A claimed swapchain yields no texture while the desktop hides the
        --- window.
        ---
        --- @return Returns whether the platform hid the window.
        hide: function(self: Window): boolean

        --- Returns whether the desktop shows the window.
        ---
        --- Minimizing the window does not hide it.
        ---
        --- @return Returns false for a hidden or destroyed window.
        isVisible: function(self: Window): boolean

        --- Brings the window forward and requests input focus.
        ---
        --- Prefer `flash` when the user did not request a focus change.
        ---
        --- @return Returns whether the platform accepted the request.
        raise: function(self: Window): boolean

        --- Minimizes the window to the taskbar or dock.
        ---
        --- @return Returns whether the platform accepted the request.
        minimize: function(self: Window): boolean

        --- Returns whether the window occupies its minimized state.
        ---
        --- @return Returns false after `destroy`.
        isMinimized: function(self: Window): boolean

        --- Maximizes the window to the display's usable bounds.
        ---
        --- @return Returns whether the platform accepted the request.
        maximize: function(self: Window): boolean

        --- Returns whether the window fills the display's usable bounds.
        ---
        --- @return Returns false after `destroy`.
        isMaximized: function(self: Window): boolean

        --- Restores a minimized or maximized window.
        ---
        --- @return Returns whether the platform accepted the request.
        restore: function(self: Window): boolean

        --- Returns whether other windows cover this window completely.
        ---
        --- @return Returns false after `destroy`.
        isOccluded: function(self: Window): boolean

        --- Returns whether keyboard events currently target this window.
        ---
        --- @return Returns false after `destroy`.
        hasFocus: function(self: Window): boolean

        --- Returns whether the pointer is over the window.
        ---
        --- Relative mouse mode has no pointer position and reports false.
        ---
        --- @return Returns false after `destroy`.
        hasMouseFocus: function(self: Window): boolean

        --- Enters or leaves fullscreen.
        ---
        --- With no selected mode, fullscreen uses the desktop resolution.
        --- With a mode from `setFullscreenMode`, it changes the display mode.
        --- The swapchain follows the new size on the next acquired frame.
        ---
        --- @param fullscreen The caller passes true to enter fullscreen or false
        ---     to leave it.
        --- @return Returns whether the platform accepted the request.
        setFullscreen: function(self: Window, fullscreen: boolean): boolean

        --- Returns whether the window occupies a fullscreen display.
        ---
        --- @return Returns false after `destroy`.
        isFullscreen: function(self: Window): boolean

        --- Reads the selected exclusive fullscreen mode.
        ---
        --- @return Returns the mode, or nil for borderless fullscreen and after
        ---     `destroy`.
        fullscreenMode: function(self: Window): Window.DisplayMode

        --- Selects the video mode used by fullscreen.
        ---
        --- The mode must come from `fullscreenModes` or
        --- `closestFullscreenMode`; a hand-built record raises. Nil selects
        --- borderless fullscreen at the desktop resolution.
        ---
        --- @param mode The caller supplies a platform mode, or nil for
        ---     borderless fullscreen.
        --- @return Returns whether the platform accepted the mode.
        setFullscreenMode: function(self: Window, mode: Window.DisplayMode): boolean

        --- Sets the title and updates the public `title` field.
        ---
        --- @param title The caller supplies the new title. Nil raises.
        --- @return Returns whether the platform changed the title.
        setTitle: function(self: Window, title: string): boolean

        --- Sets the image the desktop shows for the window.
        ---
        --- The call decodes the file synchronously.
        ---
        --- @param path The caller supplies the image path. Nil raises.
        --- @return Returns false when the decoder cannot read the file or after
        ---     `destroy`.
        setIcon: function(self: Window, path: string): boolean

        --- Returns whether the user can resize the window by dragging an edge.
        ---
        --- @return Returns false after `destroy`.
        isResizable: function(self: Window): boolean

        --- Allows or forbids user resizing.
        ---
        --- @param resizable The caller chooses whether the user may resize the
        ---     window.
        --- @return Returns whether the platform accepted the change.
        setResizable: function(self: Window, resizable: boolean): boolean

        --- Returns whether the window has a title bar and frame.
        ---
        --- @return Returns false after `destroy`.
        isBordered: function(self: Window): boolean

        --- Adds or removes the title bar and frame.
        ---
        --- The client area keeps its size.
        ---
        --- @param bordered The caller chooses whether to show desktop decoration.
        --- @return Returns whether the platform accepted the change.
        setBordered: function(self: Window, bordered: boolean): boolean

        --- Returns whether the desktop keeps the window above others.
        ---
        --- @return Returns false after `destroy`.
        isAlwaysOnTop: function(self: Window): boolean

        --- Enables or disables always-on-top behavior.
        ---
        --- @param onTop The caller chooses whether to keep the window above
        ---     others.
        --- @return Returns whether the platform accepted the change.
        setAlwaysOnTop: function(self: Window, onTop: boolean): boolean

        --- Returns whether the window may take keyboard focus.
        ---
        --- @return Returns false after `destroy`.
        isFocusable: function(self: Window): boolean

        --- Allows or forbids keyboard focus.
        ---
        --- A non-focusable window suits an overlay.
        ---
        --- @param focusable The caller chooses whether the window may take focus.
        --- @return Returns whether the platform accepted the change.
        setFocusable: function(self: Window, focusable: boolean): boolean

        --- Reads the window opacity.
        ---
        --- @return Returns a value from 0 for invisible to 1 for solid, zero after
        ---     `destroy`, or 1 on a platform without compositing.
        opacity: function(self: Window): number

        --- Sets the window opacity.
        ---
        --- @param opacity The caller supplies a value from 0 for invisible to 1
        ---     for solid.
        --- @return Returns whether the desktop accepted the change.
        setOpacity: function(self: Window, opacity: number): boolean

        --- Asks for attention without taking focus.
        ---
        --- `"untilFocused"` keeps asking and `"cancel"` stops a request. An
        --- unknown operation raises.
        ---
        --- @param operation The caller chooses how long to ask for attention.
        --- @return Returns whether the desktop accepted the request.
        flash: function(self: Window, operation: Window.Flash): boolean

        --- Reads taskbar or dock progress.
        ---
        --- @return Returns the current state, or `"none"` after `destroy`.
        --- @return Returns progress from 0 to 1, or zero after `destroy`.
        progress: function(self: Window): Window.Progress, number

        --- Shows progress on the taskbar or dock.
        ---
        --- @param state The caller supplies `"none"`, `"indeterminate"`,
        ---     `"normal"`, `"paused"` or `"error"`. An unknown value raises.
        --- @param value The caller supplies progress from 0 to 1. The desktop
        ---     reads it for `"normal"`, `"paused"` and `"error"`; omit it to
        ---     keep the current value.
        --- @return Returns whether the desktop accepted the state and value.
        setProgress: function(self: Window, state: Window.Progress, value?: number): boolean

        --- Returns whether pointer confinement applies to the focused window.
        ---
        --- @return Returns false when the window lacks focus or after `destroy`.
        mouseGrab: function(self: Window): boolean

        --- Confines the pointer to the window or releases it.
        ---
        --- Unlike relative mouse mode, this leaves the pointer visible. An
        --- unfocused window records the request and resumes it on focus.
        ---
        --- @param grabbed The caller chooses whether to confine the pointer.
        --- @return Returns whether the platform accepted the request.
        setMouseGrab: function(self: Window, grabbed: boolean): boolean

        --- Returns whether the window intercepts desktop keyboard shortcuts.
        ---
        --- @return Returns false after `destroy`.
        keyboardGrab: function(self: Window): boolean

        --- Enables or disables interception of desktop keyboard shortcuts.
        ---
        --- Some desktops refuse this or require user permission.
        ---
        --- @param grabbed The caller chooses whether to intercept shortcuts
        ---     while focused.
        --- @return Returns whether the platform accepted the request.
        setKeyboardGrab: function(self: Window, grabbed: boolean): boolean

        --- Reads the pointer confinement region.
        ---
        --- @return Returns the horizontal offset in screen coordinates.
        --- @return Returns the vertical offset in screen coordinates.
        --- @return Returns the width in screen coordinates.
        --- @return Returns the height in screen coordinates. All four values
        ---     contain zero when unset.
        mouseRect: function(self: Window): integer, integer, integer, integer

        --- Confines the pointer to part of the window.
        ---
        --- This is independent of `setMouseGrab`. Call with no arguments to
        --- remove the region.
        ---
        --- @param x The caller supplies the horizontal offset, or nil to remove
        ---     the region.
        --- @param y The caller supplies the vertical offset with `x`.
        --- @param width The caller supplies the region width with `x`.
        --- @param height The caller supplies the region height with `x`.
        --- @return Returns whether the platform accepted the request.
        setMouseRect: function(self: Window, x?: integer, y?: integer, width?: integer, height?: integer): boolean

        --- Reads the display this window mostly occupies.
        ---
        --- @return Returns the display id, or zero after `destroy`.
        display: function(self: Window): integer

        --- Lists attached displays in platform order.
        ---
        --- @return Returns display ids, or an empty list without video.
        displays: function(): {integer}

        --- Reads the desktop's primary display.
        ---
        --- @return Returns the display id, or zero without video.
        primaryDisplay: function(): integer

        --- Reads the desktop name for a display.
        ---
        --- @param displayId The caller omits this value to use the primary
        ---     display.
        --- @return Returns the name, or an empty string without video.
        displayName: function(displayId?: integer): string

        --- Reads a display's desktop rectangle.
        ---
        --- @param displayId The caller omits this value to use the primary
        ---     display.
        --- @return Returns the horizontal position in desktop screen coordinates.
        --- @return Returns the vertical position in desktop screen coordinates.
        --- @return Returns the width in screen coordinates.
        --- @return Returns the height in screen coordinates.
        displayBounds: function(displayId?: integer): integer, integer, integer, integer

        --- Reads the display area not occupied by desktop chrome.
        ---
        --- @param displayId The caller omits this value to use the primary
        ---     display.
        --- @return Returns the horizontal position in desktop screen coordinates.
        --- @return Returns the vertical position in desktop screen coordinates.
        --- @return Returns the width in screen coordinates.
        --- @return Returns the height in screen coordinates.
        usableBounds: function(displayId?: integer): integer, integer, integer, integer

        --- Reads a display's preferred content scale.
        ---
        --- @param displayId The caller omits this value to use the primary
        ---     display.
        --- @return Returns the scale, or zero without video.
        contentScale: function(displayId?: integer): number

        --- Reads a display's current rotation.
        ---
        --- @param displayId The caller omits this value to use the primary
        ---     display.
        --- @return Returns the orientation, or `"unknown"` without video.
        orientation: function(displayId?: integer): Window.Orientation

        --- Reads the orientation a display was built for.
        ---
        --- @param displayId The caller omits this value to use the primary
        ---     display.
        --- @return Returns the natural orientation, or `"unknown"` without
        ---     video.
        naturalOrientation: function(displayId?: integer): Window.Orientation

        --- Reads the display mode the desktop started in.
        ---
        --- @param displayId The caller omits this value to use the primary
        ---     display.
        --- @return Returns the mode, or nil without video.
        desktopMode: function(displayId?: integer): Window.DisplayMode

        --- Reads the display mode in use now.
        ---
        --- @param displayId The caller omits this value to use the primary
        ---     display.
        --- @return Returns the mode, or nil without video.
        currentMode: function(displayId?: integer): Window.DisplayMode

        --- Lists the display's exclusive fullscreen modes, largest first.
        ---
        --- @param displayId The caller omits this value to use the primary
        ---     display.
        --- @return Returns modes accepted by `setFullscreenMode`, or an empty list
        ---     without video.
        fullscreenModes: function(displayId?: integer): {Window.DisplayMode}

        --- Finds the nearest fullscreen mode to a requested size.
        ---
        --- Use this when restoring a saved mode that the display may no longer
        --- offer exactly.
        ---
        --- @param width The caller supplies the requested width in screen
        ---     coordinates.
        --- @param height The caller supplies the requested height in screen
        ---     coordinates.
        --- @param refreshRate The caller supplies hertz, or zero or nil for the
        ---     highest available rate.
        --- @param highDensity The caller chooses whether the function may select
        ---     modes above density 1. It defaults to false.
        --- @param displayId The caller omits this value to use the primary
        ---     display.
        --- @return Returns the nearest platform mode, or nil when none fits.
        closestFullscreenMode: function(
            width: integer, height: integer, refreshRate?: number, highDensity?: boolean, displayId?: integer
        ): Window.DisplayMode

        --- Reads the desktop's light or dark preference.
        ---
        --- @return Returns `"light"`, `"dark"` or `"unknown"`.
        theme: function(): Window.Theme

        --- Returns whether the desktop may blank the display.
        ---
        --- Video startup disables the screen saver. Enable it for an unattended
        --- menu or cutscene.
        ---
        --- @return Returns false without video.
        screenSaverEnabled: function(): boolean

        --- Allows or forbids the desktop blanking the display.
        ---
        --- @param enabled The caller chooses whether the screen saver may run.
        --- @return Returns whether the platform accepted the change, or false without
        ---     video.
        setScreenSaverEnabled: function(enabled: boolean): boolean
    end

    --- Describes the caller-writable configuration that `newWindow` reads.
    type Options = Window.Options
    --- Describes one fullscreen mode a display offers.
    type DisplayMode = Window.DisplayMode
    --- Describes which way up a display is.
    type Orientation = Window.Orientation
    --- Describes the desktop's light or dark preference.
    type Theme = Window.Theme
    --- Selects how a window asks for attention.
    type Flash = Window.Flash
    --- Selects what a taskbar progress indicator shows.
    type Progress = Window.Progress

    --- Opens a window and raises when it cannot create a usable one.
    ---
    --- It validates sizes and the icon before returning. Omitted fields take
    --- the defaults that
    --- [`Options`](tealdoc:tecs.window.Window.Options) documents.
    ---
    --- @param options The caller supplies the initial window configuration.
    --- @return Returns the caller-owned window. The caller releases it through
    ---     `destroy`.
    newWindow: function(options: Window.Options): Window
end

local type Window = window.Window

local WindowMT <const>: metatable<Window> = {__index = Window}

-- Reuse out-parameters. Nothing here runs per frame, but there is no
-- reason to allocate for it either.
local widthOut <const> = loader.newArray("int[1]")
local heightOut <const> = loader.newArray("int[1]")
local thirdOut <const> = loader.newArray("int[1]")
local fourthOut <const> = loader.newArray("int[1]")
local minAspectOut <const> = loader.newArray("float[1]")
local maxAspectOut <const> = loader.newArray("float[1]")
local countOut <const> = loader.newArray("int[1]")
local rectOut <const> = loader.newStruct("SDL_Rect")
local rectIn <const> = rectOut as loader.CStruct

-- Built from the cdef rather than written out, so a value SDL renumbers is
-- renumbered here too instead of quietly mapping to the wrong name.
local ORIENTATIONS <const>: {integer: Window.Orientation} = {}
ORIENTATIONS[tonumber(C.SDL_ORIENTATION_UNKNOWN) as integer] = "unknown"
ORIENTATIONS[tonumber(C.SDL_ORIENTATION_LANDSCAPE) as integer] = "landscape"
ORIENTATIONS[tonumber(C.SDL_ORIENTATION_LANDSCAPE_FLIPPED) as integer] = "landscapeFlipped"
ORIENTATIONS[tonumber(C.SDL_ORIENTATION_PORTRAIT) as integer] = "portrait"
ORIENTATIONS[tonumber(C.SDL_ORIENTATION_PORTRAIT_FLIPPED) as integer] = "portraitFlipped"

local THEMES <const>: {integer: Window.Theme} = {}
THEMES[tonumber(C.SDL_SYSTEM_THEME_UNKNOWN) as integer] = "unknown"
THEMES[tonumber(C.SDL_SYSTEM_THEME_LIGHT) as integer] = "light"
THEMES[tonumber(C.SDL_SYSTEM_THEME_DARK) as integer] = "dark"

local FLASHES <const>: {Window.Flash: integer} = {
    cancel = tonumber(C.SDL_FLASH_CANCEL) as integer,
    brief = tonumber(C.SDL_FLASH_BRIEFLY) as integer,
    untilFocused = tonumber(C.SDL_FLASH_UNTIL_FOCUSED) as integer,
}

local PROGRESS_STATES <const>: {Window.Progress: integer} = {
    none = tonumber(C.SDL_PROGRESS_STATE_NONE) as integer,
    indeterminate = tonumber(C.SDL_PROGRESS_STATE_INDETERMINATE) as integer,
    normal = tonumber(C.SDL_PROGRESS_STATE_NORMAL) as integer,
    paused = tonumber(C.SDL_PROGRESS_STATE_PAUSED) as integer,
    error = tonumber(C.SDL_PROGRESS_STATE_ERROR) as integer,
}

local PROGRESS_NAMES <const>: {integer: Window.Progress} = {}
for name, value in pairs(PROGRESS_STATES) do
    PROGRESS_NAMES[value] = name
end

function Window.available(): boolean
    return tonumber(C.SDL_WasInit(VIDEO)) ~= 0
end

--- Whether a window flag is set, or false once the window is gone.
---
--- Read from SDL each time rather than remembered, so a flag the window
--- manager changed on its own reports honestly.
local function hasFlag(self: Window, flag: integer): boolean
    if self.handle == nil then
        return false
    end
    return bit.band(C.SDL_GetWindowFlags(self.handle) as integer, flag) ~= 0
end

--- Reads a pair of ints SDL wrote, or zeroes when the call failed.
---
--- SDL leaves an out-parameter untouched on failure, and these buffers are
--- reused, so returning them unchecked would report whatever the last
--- successful call happened to leave there.
local function pair(wrote: boolean): integer, integer
    if not wrote then
        return 0, 0
    end
    return widthOut[0] as integer, heightOut[0] as integer
end

--- Converts an `SDL_DisplayMode *` to a mode record, or nil for null.
local function toMode(pointer: loader.CValue): Window.DisplayMode
    if pointer == nil then
        return nil
    end
    return {
        display = tonumber(pointer.displayID) as integer,
        width = tonumber(pointer.w) as integer,
        height = tonumber(pointer.h) as integer,
        pixelDensity = tonumber(pointer.pixel_density) as number,
        refreshRate = tonumber(pointer.refresh_rate) as number,
        _mode = pointer as loader.CPtr,
    }
end

--- Resolves an optional display argument to the primary display.
---
--- Zero without video, which is the id SDL uses for "no display" and what
--- every display function here already answers empty for.
local function display(id?: integer): integer
    if id ~= nil then
        return id
    end
    return tonumber(C.SDL_GetPrimaryDisplay()) as integer
end

--- Decodes an image file and hands it to SDL as the window's icon.
---
--- Shared by `newWindow` and `setIcon` rather than one calling the other, because
--- an option applied at construction and a setter called later are the same
--- work and the function can write only one of them first.
local function applyIcon(handle: loader.CPtr, path: string): boolean
    -- Required here rather than at the top of the file so a process which only
    -- asks a window about itself does not load an image decoder.
    local content <const> = require("tecs.platform.content")
    local rust <const> = require("tecs.ffi.rust")
    local bytes <const> = content.read(path, "image")
    if bytes == nil then
        return false
    end
    local decoded = rust.C.tecsImageDecode(ffi.cast("const uint8_t *", bytes), #bytes)
    if decoded == nil then
        return false
    end
    local width <const> = tonumber(rust.C.tecsImageWidth(decoded)) as integer
    local height <const> = tonumber(rust.C.tecsImageHeight(decoded)) as integer
    local surface = C.SDL_CreateSurfaceFrom(
        width, height, C.SDL_PIXELFORMAT_ABGR8888, ffi.cast("void *", rust.C.tecsImagePixels(decoded)), width * 4
    )
    if surface == nil then
        rust.C.tecsImageDestroy(decoded)
        return false
    end
    local set = C.SDL_SetWindowIcon(handle, surface) as boolean
    C.SDL_DestroySurface(surface)
    rust.C.tecsImageDestroy(decoded)
    return set
end

-------------------------------------------------------------------------------
-- Creation and destruction
-------------------------------------------------------------------------------

function window.newWindow(options: Window.Options): Window
    local flags = 0
    if options.resizable ~= false then
        flags = flags + K.SDL_WINDOW_RESIZABLE
    end
    if options.highPixelDensity ~= false then
        flags = flags + K.SDL_WINDOW_HIGH_PIXEL_DENSITY
    end
    if options.fullscreen == true then
        flags = flags + K.SDL_WINDOW_FULLSCREEN
    end
    if options.borderless == true then
        flags = flags + K.SDL_WINDOW_BORDERLESS
    end
    if options.hidden == true then
        flags = flags + K.SDL_WINDOW_HIDDEN
    end
    if options.alwaysOnTop == true then
        flags = flags + K.SDL_WINDOW_ALWAYS_ON_TOP
    end
    if options.transparent == true then
        flags = flags + K.SDL_WINDOW_TRANSPARENT
    end

    local title = options.title or "tecs"
    local handle = C.SDL_CreateWindow(title, options.width or 1280, options.height or 720, flags)
    if handle == nil then
        sdl.fail("SDL_CreateWindow")
    end

    local self = setmetatable({} as Window, WindowMT)
    self.handle = handle
    self.title = title
    self._destroyed = false

    if options.minWidth ~= nil and options.minHeight ~= nil then
        C.SDL_SetWindowMinimumSize(handle, options.minWidth, options.minHeight)
    end
    if options.maxWidth ~= nil and options.maxHeight ~= nil then
        C.SDL_SetWindowMaximumSize(handle, options.maxWidth, options.maxHeight)
    end
    if options.x ~= nil and options.y ~= nil then
        C.SDL_SetWindowPosition(handle, options.x, options.y)
    end
    if options.icon ~= nil then
        applyIcon(handle, options.icon)
    end
    return self
end

function Window:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    C.SDL_DestroyWindow(self.handle)
    self.handle = nil
end

function Window:id(): integer
    if self.handle == nil then
        return 0
    end
    return tonumber(C.SDL_GetWindowID(self.handle)) as integer
end

function Window:sync(): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_SyncWindow(self.handle) as boolean
end

-------------------------------------------------------------------------------
-- Size and position
-------------------------------------------------------------------------------

function Window:getSize(): integer, integer
    if self.handle == nil then
        return 0, 0
    end
    return pair(C.SDL_GetWindowSize(self.handle, widthOut, heightOut) as boolean)
end

function Window:getPixelSize(): integer, integer
    if self.handle == nil then
        return 0, 0
    end
    return pair(C.SDL_GetWindowSizeInPixels(self.handle, widthOut, heightOut) as boolean)
end

function Window:setSize(width: integer, height: integer): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_SetWindowSize(self.handle, width, height) as boolean
end

function Window:pixelDensity(): number
    if self.handle == nil then
        return 0
    end
    return tonumber(C.SDL_GetWindowPixelDensity(self.handle)) as number
end

function Window:displayScale(): number
    if self.handle == nil then
        return 0
    end
    return tonumber(C.SDL_GetWindowDisplayScale(self.handle)) as number
end

function Window:position(): integer, integer
    if self.handle == nil then
        return 0, 0
    end
    return pair(C.SDL_GetWindowPosition(self.handle, widthOut, heightOut) as boolean)
end

function Window:setPosition(x: integer, y: integer): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_SetWindowPosition(self.handle, x, y) as boolean
end

function Window:center(displayId?: integer): boolean
    if self.handle == nil then
        return false
    end
    local centered = K.SDL_WINDOWPOS_CENTERED
    if displayId ~= nil then
        centered = bit.bor(K.SDL_WINDOWPOS_CENTERED_MASK, displayId)
    end
    return C.SDL_SetWindowPosition(self.handle, centered, centered) as boolean
end

function Window:borderSize(): integer, integer, integer, integer
    if self.handle == nil then
        return 0, 0, 0, 0
    end
    local wrote = C.SDL_GetWindowBordersSize(self.handle, widthOut, heightOut, thirdOut, fourthOut) as boolean
    if not wrote then
        return 0, 0, 0, 0
    end
    return widthOut[0] as integer, heightOut[0] as integer, thirdOut[0] as integer, fourthOut[0] as integer
end

function Window:safeArea(): integer, integer, integer, integer
    if self.handle == nil then
        return 0, 0, 0, 0
    end
    if not (C.SDL_GetWindowSafeArea(self.handle, rectOut) as boolean) then
        return 0, 0, 0, 0
    end
    return tonumber(rectOut.x) as integer,
        tonumber(rectOut.y) as integer,
        tonumber(rectOut.w) as integer,
        tonumber(rectOut.h) as integer
end

function Window:minimumSize(): integer, integer
    if self.handle == nil then
        return 0, 0
    end
    return pair(C.SDL_GetWindowMinimumSize(self.handle, widthOut, heightOut) as boolean)
end

function Window:setMinimumSize(width: integer, height: integer): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_SetWindowMinimumSize(self.handle, width, height) as boolean
end

function Window:maximumSize(): integer, integer
    if self.handle == nil then
        return 0, 0
    end
    return pair(C.SDL_GetWindowMaximumSize(self.handle, widthOut, heightOut) as boolean)
end

function Window:setMaximumSize(width: integer, height: integer): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_SetWindowMaximumSize(self.handle, width, height) as boolean
end

function Window:aspectRatio(): number, number
    if self.handle == nil then
        return 0, 0
    end
    local wrote = C.SDL_GetWindowAspectRatio(self.handle, minAspectOut, maxAspectOut) as boolean
    if not wrote then
        return 0, 0
    end
    return minAspectOut[0] as number, maxAspectOut[0] as number
end

function Window:setAspectRatio(minimum: number, maximum: number): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_SetWindowAspectRatio(self.handle, minimum, maximum) as boolean
end

-------------------------------------------------------------------------------
-- Visibility and window state
-------------------------------------------------------------------------------

function Window:show(): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_ShowWindow(self.handle) as boolean
end

function Window:hide(): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_HideWindow(self.handle) as boolean
end

function Window:isVisible(): boolean
    if self.handle == nil then
        return false
    end
    return not hasFlag(self, K.SDL_WINDOW_HIDDEN)
end

function Window:raise(): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_RaiseWindow(self.handle) as boolean
end

function Window:minimize(): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_MinimizeWindow(self.handle) as boolean
end

function Window:isMinimized(): boolean
    return hasFlag(self, K.SDL_WINDOW_MINIMIZED)
end

function Window:maximize(): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_MaximizeWindow(self.handle) as boolean
end

function Window:isMaximized(): boolean
    return hasFlag(self, K.SDL_WINDOW_MAXIMIZED)
end

function Window:restore(): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_RestoreWindow(self.handle) as boolean
end

function Window:isOccluded(): boolean
    return hasFlag(self, K.SDL_WINDOW_OCCLUDED)
end

function Window:hasFocus(): boolean
    return hasFlag(self, K.SDL_WINDOW_INPUT_FOCUS)
end

function Window:hasMouseFocus(): boolean
    return hasFlag(self, K.SDL_WINDOW_MOUSE_FOCUS)
end

-------------------------------------------------------------------------------
-- Fullscreen
-------------------------------------------------------------------------------

function Window:setFullscreen(fullscreen: boolean): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_SetWindowFullscreen(self.handle, fullscreen ~= false) as boolean
end

function Window:isFullscreen(): boolean
    return hasFlag(self, K.SDL_WINDOW_FULLSCREEN)
end

function Window:fullscreenMode(): Window.DisplayMode
    if self.handle == nil then
        return nil
    end
    return toMode(C.SDL_GetWindowFullscreenMode(self.handle))
end

function Window:setFullscreenMode(mode: Window.DisplayMode): boolean
    if self.handle == nil then
        return false
    end
    if mode == nil then
        return C.SDL_SetWindowFullscreenMode(self.handle, nil) as boolean
    end
    if mode._mode == nil then
        error(
            "tecs: Window:setFullscreenMode needs a mode from "
                .. "Window.fullscreenModes or Window.closestFullscreenMode",
            2
        )
    end
    return C.SDL_SetWindowFullscreenMode(self.handle, mode._mode) as boolean
end

-------------------------------------------------------------------------------
-- Decoration and appearance
-------------------------------------------------------------------------------

function Window:setTitle(title: string): boolean
    if title == nil then
        error("tecs: Window:setTitle needs a string", 2)
    end
    self.title = title
    if self.handle == nil then
        return false
    end
    return C.SDL_SetWindowTitle(self.handle, title) as boolean
end

function Window:setIcon(path: string): boolean
    if path == nil then
        error("tecs: Window:setIcon needs a path", 2)
    end
    if self.handle == nil then
        return false
    end
    return applyIcon(self.handle, path)
end

function Window:isResizable(): boolean
    return hasFlag(self, K.SDL_WINDOW_RESIZABLE)
end

function Window:setResizable(resizable: boolean): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_SetWindowResizable(self.handle, resizable ~= false) as boolean
end

function Window:isBordered(): boolean
    if self.handle == nil then
        return false
    end
    return not hasFlag(self, K.SDL_WINDOW_BORDERLESS)
end

function Window:setBordered(bordered: boolean): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_SetWindowBordered(self.handle, bordered ~= false) as boolean
end

function Window:isAlwaysOnTop(): boolean
    return hasFlag(self, K.SDL_WINDOW_ALWAYS_ON_TOP)
end

function Window:setAlwaysOnTop(onTop: boolean): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_SetWindowAlwaysOnTop(self.handle, onTop ~= false) as boolean
end

function Window:isFocusable(): boolean
    if self.handle == nil then
        return false
    end
    return not hasFlag(self, K.SDL_WINDOW_NOT_FOCUSABLE)
end

function Window:setFocusable(focusable: boolean): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_SetWindowFocusable(self.handle, focusable ~= false) as boolean
end

function Window:opacity(): number
    if self.handle == nil then
        return 0
    end
    local value = tonumber(C.SDL_GetWindowOpacity(self.handle)) as number
    if value < 0 then
        return 0
    end
    return value
end

function Window:setOpacity(opacity: number): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_SetWindowOpacity(self.handle, opacity) as boolean
end

-------------------------------------------------------------------------------
-- Attention
-------------------------------------------------------------------------------

function Window:flash(operation: Window.Flash): boolean
    local value = FLASHES[operation]
    if value == nil then
        error(("tecs: unknown flash operation '%s'"):format(tostring(operation)), 2)
    end
    if self.handle == nil then
        return false
    end
    return C.SDL_FlashWindow(self.handle, value) as boolean
end

function Window:progress(): Window.Progress, number
    if self.handle == nil then
        return "none", 0
    end
    local state = PROGRESS_NAMES[tonumber(C.SDL_GetWindowProgressState(self.handle)) as integer]
    if state == nil then
        return "none", 0
    end
    return state, tonumber(C.SDL_GetWindowProgressValue(self.handle)) as number
end

function Window:setProgress(state: Window.Progress, value?: number): boolean
    local resolved = PROGRESS_STATES[state]
    if resolved == nil then
        error(("tecs: unknown progress state '%s'"):format(tostring(state)), 2)
    end
    if self.handle == nil then
        return false
    end
    if not (C.SDL_SetWindowProgressState(self.handle, resolved) as boolean) then
        return false
    end
    if value == nil then
        return true
    end
    return C.SDL_SetWindowProgressValue(self.handle, value) as boolean
end

-------------------------------------------------------------------------------
-- Confinement
-------------------------------------------------------------------------------

function Window:mouseGrab(): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_GetWindowMouseGrab(self.handle) as boolean
end

function Window:setMouseGrab(grabbed: boolean): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_SetWindowMouseGrab(self.handle, grabbed ~= false) as boolean
end

function Window:keyboardGrab(): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_GetWindowKeyboardGrab(self.handle) as boolean
end

function Window:setKeyboardGrab(grabbed: boolean): boolean
    if self.handle == nil then
        return false
    end
    return C.SDL_SetWindowKeyboardGrab(self.handle, grabbed ~= false) as boolean
end

function Window:mouseRect(): integer, integer, integer, integer
    if self.handle == nil then
        return 0, 0, 0, 0
    end
    local rect = C.SDL_GetWindowMouseRect(self.handle)
    if rect == nil then
        return 0, 0, 0, 0
    end
    return tonumber(rect.x) as integer,
        tonumber(rect.y) as integer,
        tonumber(rect.w) as integer,
        tonumber(rect.h) as integer
end

function Window:setMouseRect(x?: integer, y?: integer, width?: integer, height?: integer): boolean
    if self.handle == nil then
        return false
    end
    if x == nil then
        return C.SDL_SetWindowMouseRect(self.handle, nil) as boolean
    end
    rectIn.x = x
    rectIn.y = y
    rectIn.w = width
    rectIn.h = height
    -- SDL copies the rect, so the shared scratch struct is free again as soon
    -- as this returns.
    return C.SDL_SetWindowMouseRect(self.handle, rectOut) as boolean
end

-------------------------------------------------------------------------------
-- Displays
-------------------------------------------------------------------------------

function Window:display(): integer
    if self.handle == nil then
        return 0
    end
    return tonumber(C.SDL_GetDisplayForWindow(self.handle)) as integer
end

function Window.displays(): {integer}
    local found: {integer} = {}
    if not Window.available() then
        return found
    end

    local list = C.SDL_GetDisplays(countOut)
    if list == nil then
        return found
    end
    local count = countOut[0] as integer
    for index = 0, count - 1 do
        found[index + 1] = tonumber((list as loader.CArray)[index]) as integer
    end
    C.SDL_free(list)
    return found
end

function Window.primaryDisplay(): integer
    if not Window.available() then
        return 0
    end
    return tonumber(C.SDL_GetPrimaryDisplay()) as integer
end

function Window.displayName(displayId?: integer): string
    if not Window.available() then
        return ""
    end
    return loader.toString(C.SDL_GetDisplayName(display(displayId)))
end

function Window.displayBounds(displayId?: integer): integer, integer, integer, integer
    if not Window.available() then
        return 0, 0, 0, 0
    end
    if not (C.SDL_GetDisplayBounds(display(displayId), rectOut) as boolean) then
        return 0, 0, 0, 0
    end
    return tonumber(rectOut.x) as integer,
        tonumber(rectOut.y) as integer,
        tonumber(rectOut.w) as integer,
        tonumber(rectOut.h) as integer
end

function Window.usableBounds(displayId?: integer): integer, integer, integer, integer
    if not Window.available() then
        return 0, 0, 0, 0
    end
    if not (C.SDL_GetDisplayUsableBounds(display(displayId), rectOut) as boolean) then
        return 0, 0, 0, 0
    end
    return tonumber(rectOut.x) as integer,
        tonumber(rectOut.y) as integer,
        tonumber(rectOut.w) as integer,
        tonumber(rectOut.h) as integer
end

function Window.contentScale(displayId?: integer): number
    if not Window.available() then
        return 0
    end
    return tonumber(C.SDL_GetDisplayContentScale(display(displayId))) as number
end

function Window.orientation(displayId?: integer): Window.Orientation
    if not Window.available() then
        return "unknown"
    end
    local value = tonumber(C.SDL_GetCurrentDisplayOrientation(display(displayId))) as integer
    return ORIENTATIONS[value] or "unknown"
end

function Window.naturalOrientation(displayId?: integer): Window.Orientation
    if not Window.available() then
        return "unknown"
    end
    local value = tonumber(C.SDL_GetNaturalDisplayOrientation(display(displayId))) as integer
    return ORIENTATIONS[value] or "unknown"
end

function Window.desktopMode(displayId?: integer): Window.DisplayMode
    if not Window.available() then
        return nil
    end
    return toMode(C.SDL_GetDesktopDisplayMode(display(displayId)))
end

function Window.currentMode(displayId?: integer): Window.DisplayMode
    if not Window.available() then
        return nil
    end
    return toMode(C.SDL_GetCurrentDisplayMode(display(displayId)))
end

function Window.fullscreenModes(displayId?: integer): {Window.DisplayMode}
    local found: {Window.DisplayMode} = {}
    if not Window.available() then
        return found
    end

    local list = C.SDL_GetFullscreenDisplayModes(display(displayId), countOut)
    if list == nil then
        return found
    end
    local count = countOut[0] as integer
    for index = 0, count - 1 do
        found[index + 1] = toMode((list as loader.CArray)[index] as loader.CValue)
    end
    -- One allocation holds the array of pointers; the modes it points at belong
    -- to SDL and outlive it, which is what lets a mode record keep one.
    C.SDL_free(list)
    return found
end

function Window.closestFullscreenMode(
    width: integer, height: integer, refreshRate?: number, highDensity?: boolean, displayId?: integer
): Window.DisplayMode
    if not Window.available() then
        return nil
    end
    -- Allocated per call rather than shared, because the record keeps it and
    -- SDL reads it again on every `setFullscreenMode`.
    local mode = loader.newStruct("SDL_DisplayMode")
    local found = C.SDL_GetClosestFullscreenDisplayMode(
        display(displayId), width, height, refreshRate or 0, highDensity == true, mode
    ) as boolean
    if not found then
        return nil
    end
    return toMode(mode)
end

-------------------------------------------------------------------------------
-- The desktop
-------------------------------------------------------------------------------

function Window.theme(): Window.Theme
    if not Window.available() then
        return "unknown"
    end
    return THEMES[tonumber(C.SDL_GetSystemTheme()) as integer] or "unknown"
end

function Window.screenSaverEnabled(): boolean
    if not Window.available() then
        return false
    end
    return C.SDL_ScreenSaverEnabled() as boolean
end

function Window.setScreenSaverEnabled(enabled: boolean): boolean
    if not Window.available() then
        return false
    end
    if enabled ~= false then
        return C.SDL_EnableScreenSaver() as boolean
    end
    return C.SDL_DisableScreenSaver() as boolean
end

return window
