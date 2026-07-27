--- An OS window, and the displays it can sit on.
---
--- The handle is owned by the platform layer and released by `destroy`, not
--- by a finalizer. Tying GPU-adjacent lifetimes to Lua's collector makes
--- hot reload either leak or double-free, depending on collection order.
---
--- ## Two coordinate systems, and no converter between them
---
--- `getSize` is screen coordinates, which is what a mouse, a pen or a touch
--- position arrives in. `getPixelSize` is the drawable, which is what a render
--- target is sized to. On a high-density display they differ by
--- `pixelDensity`, and on every display the desktop's own scaling factor is
--- `displayScale`, which is a hint about how large text should be drawn rather
--- than a ratio between the two.
---
--- Those three answers are what the platform actually knows. There is no
--- `toPixels` or `fromPixels` here, because a converter would have to pick one
--- of the two systems as the real one and silently reinterpret the other; the
--- pair of getters says which is which at every call site instead.
---
--- ## Polled state beside events that report the same thing
---
--- `events` carries `windowMoved`, `windowResized`, `windowFocusGained`,
--- `windowFocusLost`, `windowMinimized`, `windowMaximized`, `windowRestored`,
--- `windowShown`, `windowHidden`, `windowOccluded`, `windowEnterFullscreen`,
--- `windowLeaveFullscreen`, `windowDisplayScaleChanged` and
--- `windowSafeAreaChanged`. Every one of those facts is also readable here,
--- which looks like a second way to learn the same thing and is not.
---
--- An event reports a *change*. Nothing reports the state a window started in:
--- a window created hidden fires no `windowHidden`, a window that has never
--- had focus fires no `windowFocusLost`, and a game that only listens has to
--- assume an initial value and hope the platform agrees. The getters here are
--- how the first frame learns where it stands, and how any later frame
--- resynchronises without keeping a mirror of the event stream.
---
--- They agree with the events by construction: each one asks SDL rather than
--- caching, so the flags a getter reads are the flags the event was derived
--- from. `id` is the bridge between the two, since it is the value an event's
--- `which` field carries.
---
--- ## What is not here
---
--- Pointer behaviour is `Input`'s: relative mouse mode, warping, capture and
--- cursor visibility all act through the window but are input modes, and
--- `Input` already holds the handle for them. What is here instead is
--- *confinement*, which is a property of the window's bargain with the window
--- manager rather than of the pointer: `setMouseGrab`, `setKeyboardGrab` and
--- `setMouseRect`.
---
--- Vsync is not here. SDL has `SDL_SetWindowSurfaceVSync`, and it paces the
--- window *surface*, which is the software-blit path and cannot coexist with a
--- window a GPU device has claimed. Presentation pacing for a claimed window is
--- `Device:setPresentMode`, and offering a second spelling of it on the window
--- would be a call that either does nothing or tears the swapchain down.
---
--- Nor is the surface family itself (`SDL_GetWindowSurface`,
--- `SDL_UpdateWindowSurface`, `SDL_SetWindowShape`), the graphics-API interop
--- (`SDL_GL_*`, `SDL_EGL_*`), the raw property bag
--- (`SDL_GetWindowProperties`, `SDL_GetWindowPixelFormat`,
--- `SDL_GetWindowICCProfile`), the multi-window relationships
--- (`SDL_CreatePopupWindow`, `SDL_SetWindowParent`, `SDL_SetWindowModal`), or
--- the entry points that hand back a raw `SDL_Window *` this module does not
--- own (`SDL_GetWindows`, `SDL_GetWindowFromID`, `SDL_GetGrabbedWindow`).
--- `SDL_SetWindowHitTest` is left out for the reason `clipboard` records for
--- the offer side of the clipboard: it retains a callback SDL enters from its
--- own event pump, and this engine keeps callbacks native.
---
--- ## Changing a window a device has claimed
---
--- Safe: size, position, minimum and maximum size, aspect ratio, fullscreen,
--- borders, opacity, visibility and minimisation. The pass graph sizes its
--- targets from the swapchain texture it acquires each frame rather than from
--- anything asked of the window, so a size change is picked up on the next
--- frame with no reconfiguration; a hidden or minimised window acquires no
--- texture and the frame is skipped whole.
---
--- Asynchronous: on some window systems a size, position or fullscreen change
--- is a request the compositor answers later, so reading the value straight
--- back reports the old one. `sync` waits for the pending changes to land,
--- and is the only reason to call it.
---
--- ## With no video
---
--- The display and screen-saver functions belong to SDL's video subsystem and
--- fail with "Video subsystem has not been initialized" without it, so they
--- answer here without calling SDL at all: empty lists, zero sizes, "unknown"
--- orientations and themes. A destroyed window answers the same way, because
--- SDL leaves an out-parameter untouched on failure and a getter that returned
--- it would report the size the window had before it was destroyed.
---
--- `create` is the exception and raises, since a window that could not be
--- created is not a question with a sensible answer.

local bit <const> = require("bit")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K
local VIDEO <const> = K.SDL_INIT_VIDEO

local record Window
    --- The `SDL_Window`. Nil once `destroy` has run, and what a device claims
    --- for presentation.
    handle: loader.CPtr
    --- The title last set, kept so reading it back does not cross the FFI.
    title: string
    _destroyed: boolean

    --- How a display is rotated relative to its natural orientation.
    enum Orientation
        "unknown"
        "landscape"
        "landscapeFlipped"
        "portrait"
        "portraitFlipped"
    end

    --- What the desktop asks applications to look like.
    enum Theme
        "unknown"
        "light"
        "dark"
    end

    --- How hard to ask for attention.
    enum Flash
        --- Stops a flash already running.
        "cancel"
        --- One flash, whether or not anybody was looking.
        "brief"
        --- Keeps flashing until the window is focused.
        "untilFocused"
    end

    --- What the taskbar or dock shows over this application's icon.
    enum Progress
        --- Nothing shown, which is where a window starts.
        "none"
        --- Work is happening and its extent is not known.
        "indeterminate"
        "normal"
        "paused"
        --- Work stopped because it failed.
        "error"
    end

    --- One video mode a display can be put into.
    record DisplayMode
        --- Display this mode belongs to.
        display: integer
        --- Size in screen coordinates. Multiply by `pixelDensity` for pixels.
        width: integer
        height: integer
        --- Screen coordinates to pixels, so a 1920 by 1080 mode at 2.0 draws
        --- 3840 by 2160.
        pixelDensity: number
        --- Refreshes per second, or 0 where the platform will not say.
        refreshRate: number
        --- SDL's own mode, which `setFullscreenMode` passes back to it. A mode
        --- assembled by hand rather than taken from `fullscreenModes` or
        --- `closestFullscreenMode` does not carry one and is rejected.
        _mode: loader.CPtr
    end

    --- What `create` takes. Every field is optional.
    record Options
        --- Defaults to "tecs".
        title: string
        --- Size in screen coordinates, not pixels: on a high-density display
        --- the drawable is larger. Defaults to 1280 by 720.
        width: integer
        height: integer
        --- Defaults to true, so omitting it gives a resizable window. Only an
        --- explicit false turns it off.
        resizable: boolean
        --- Whether the drawable follows the display's density instead of being
        --- stretched to it. Defaults to true, on the same terms, which is what
        --- makes `getPixelSize` differ from `getSize`.
        highPixelDensity: boolean
        --- Starts fullscreen on whichever display the window manager picks.
        --- Defaults to false.
        fullscreen: boolean
        --- Drops the title bar and the frame. Defaults to false.
        borderless: boolean
        --- Creates the window without mapping it, so nothing is shown until
        --- `show` is called. Defaults to false, and is what a game that wants
        --- to place and size the window before it is first seen sets.
        hidden: boolean
        --- Keeps the window above others. Defaults to false.
        alwaysOnTop: boolean
        --- Asks for a window whose buffer has an alpha channel the desktop
        --- composites against. Defaults to false, and is refused outright on a
        --- platform that cannot do it.
        transparent: boolean
        --- Position in screen coordinates. Both are needed for either to
        --- apply; left unset, the window manager places the window.
        x: integer
        y: integer
        --- Size limits, applied after creation. Each pair is needed together.
        minWidth: integer
        minHeight: integer
        maxWidth: integer
        maxHeight: integer
        --- Image file the window is shown as. Decoded once, here, rather than
        --- going through the asset system, which decodes on a worker and
        --- answers with a GPU texture.
        icon: string
    end
end

local WindowMT <const>: metatable<Window> = { __index = Window }

-- Reused out-parameters. Nothing here is asked per frame, but there is no
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

--- Whether there is a video subsystem to ask at all.
---
--- False in a process that never brought it up, where every display and
--- screen-saver function here answers empty rather than failing. `create`
--- raises there instead, so this is what a caller checks before deciding
--- whether to open a window.
function Window.available(): boolean
    return tonumber(C.SDL_WasInit(VIDEO)) ~= 0
end

--- Whether a window flag is set, or false once the window is gone.
---
--- Read from SDL each time rather than remembered, so a flag the window
--- manager changed on its own reports honestly.
local function hasFlag(self: Window, flag: integer): boolean
    if self.handle == nil then return false end
    return bit.band(C.SDL_GetWindowFlags(self.handle) as integer, flag) ~= 0
end

--- Reads a pair of ints SDL wrote, or zeroes when the call failed.
---
--- SDL leaves an out-parameter untouched on failure, and these buffers are
--- reused, so returning them unchecked would report whatever the last
--- successful call happened to leave there.
local function pair(wrote: boolean): integer, integer
    if not wrote then return 0, 0 end
    return widthOut[0] as integer, heightOut[0] as integer
end

--- Converts an `SDL_DisplayMode *` to a mode record, or nil for null.
local function toMode(pointer: loader.CValue): Window.DisplayMode
    if pointer == nil then return nil end
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
    if id ~= nil then return id end
    return tonumber(C.SDL_GetPrimaryDisplay()) as integer
end

--- Decodes an image file and hands it to SDL as the window's icon.
---
--- Shared by `create` and `setIcon` rather than one calling the other, because
--- an option applied at construction and a setter called later are the same
--- work and only one of them can be written first.
local function applyIcon(handle: loader.CPtr, path: string): boolean
    -- Required here rather than at the top of the file so that a process which
    -- only asks a window about itself does not load an image decoder.
    local sdl3image <const> = require("tecs.ffi.sdl3image")
    local surface = sdl3image.C.IMG_Load(path)
    if surface == nil then return false end
    local set = C.SDL_SetWindowIcon(handle, surface) as boolean
    C.SDL_DestroySurface(surface)
    return set
end

-------------------------------------------------------------------------------
-- Creation and destruction
-------------------------------------------------------------------------------

--- Creates a window. Requires `SDL_Init(SDL_INIT_VIDEO)` to have run.
---
--- Flags that SDL only accepts at creation are taken from `options` and set
--- here; everything else in `options` is applied straight afterwards, and has
--- a setter of its own, so nothing is reachable at creation that is not
--- reachable later.
function Window.create(options: Window.Options): Window
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
    local handle = C.SDL_CreateWindow(title,
        options.width or 1280, options.height or 720, flags)
    if handle == nil then sdl.fail("SDL_CreateWindow") end

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

--- Releases the window. Safe to call more than once.
---
--- Every getter answers zero, false or nil afterwards rather than reading
--- through a null handle.
function Window:destroy()
    if self._destroyed then return end
    self._destroyed = true
    C.SDL_DestroyWindow(self.handle)
    self.handle = nil
end

--- The id events name this window by, which is what an event's `which` field
--- carries. Zero once the window is gone.
function Window:id(): integer
    if self.handle == nil then return 0 end
    return tonumber(C.SDL_GetWindowID(self.handle)) as integer
end

--- Waits for pending window changes to be applied.
---
--- Size, position and fullscreen are requests rather than commands on a
--- compositing window system, and SDL reports the old value until the
--- compositor answers. This blocks until it has, so a caller that must read
--- back what it just set has somewhere to wait. Everywhere else the change is
--- already applied and this returns immediately.
---
--- Returns false when the changes did not land in SDL's timeout, and false
--- with no window.
function Window:sync(): boolean
    if self.handle == nil then return false end
    return C.SDL_SyncWindow(self.handle) as boolean
end

-------------------------------------------------------------------------------
-- Size and position
-------------------------------------------------------------------------------

--- Returns the window's size in screen coordinates.
---
--- The units mouse, touch and pen positions arrive in, so this is what a
--- layout positioned against the pointer uses. `getPixelSize` is what a render
--- target is sized to.
function Window:getSize(): integer, integer
    if self.handle == nil then return 0, 0 end
    return pair(C.SDL_GetWindowSize(self.handle, widthOut, heightOut) as boolean)
end

--- Returns the drawable size in pixels, which differs from `getSize` on
--- high-density displays.
function Window:getPixelSize(): integer, integer
    if self.handle == nil then return 0, 0 end
    return pair(C.SDL_GetWindowSizeInPixels(self.handle, widthOut, heightOut) as boolean)
end

--- Resizes the window, in screen coordinates.
---
--- Safe while a device holds the window: the swapchain is recreated by SDL and
--- the renderer sizes its targets to the texture it acquires next frame. A
--- fullscreen window ignores this, and a window whose size the compositor has
--- to agree to reports the old size until `sync` returns.
function Window:setSize(width: integer, height: integer): boolean
    if self.handle == nil then return false end
    return C.SDL_SetWindowSize(self.handle, width, height) as boolean
end

--- Ratio of pixels to screen coordinates: 2.0 on a display where the drawable
--- is twice the window. 1.0 without `highPixelDensity`, and 0 with no window.
function Window:pixelDensity(): number
    if self.handle == nil then return 0 end
    return tonumber(C.SDL_GetWindowPixelDensity(self.handle)) as number
end

--- How much larger than its natural size the desktop asks content to be drawn.
---
--- Not a ratio between `getSize` and `getPixelSize`, which is `pixelDensity`.
--- This is the user's scaling preference, so it is what a font size or a UI
--- metric is multiplied by, and it changes without the window resizing.
--- `events.windowDisplayScaleChanged` reports that it has.
function Window:displayScale(): number
    if self.handle == nil then return 0 end
    return tonumber(C.SDL_GetWindowDisplayScale(self.handle)) as number
end

--- Position of the window's top-left corner in screen coordinates.
function Window:position(): integer, integer
    if self.handle == nil then return 0, 0 end
    return pair(C.SDL_GetWindowPosition(self.handle, widthOut, heightOut) as boolean)
end

--- Moves the window, in screen coordinates.
---
--- The coordinate space spans every display, so a negative or very large
--- position is how a window is put on a second monitor.
function Window:setPosition(x: integer, y: integer): boolean
    if self.handle == nil then return false end
    return C.SDL_SetWindowPosition(self.handle, x, y) as boolean
end

--- Centres the window on `display`, or on the display it is already on.
function Window:center(displayId?: integer): boolean
    if self.handle == nil then return false end
    local centered = K.SDL_WINDOWPOS_CENTERED
    if displayId ~= nil then
        centered = bit.bor(K.SDL_WINDOWPOS_CENTERED_MASK, displayId)
    end
    return C.SDL_SetWindowPosition(self.handle, centered, centered) as boolean
end

--- Thickness of the window manager's decoration, in screen coordinates:
--- top, left, bottom and right.
---
--- All zero on a platform that does not decorate windows and on a borderless
--- one, which is the honest answer rather than a failure.
function Window:borderSize(): integer, integer, integer, integer
    if self.handle == nil then return 0, 0, 0, 0 end
    local wrote = C.SDL_GetWindowBordersSize(self.handle,
        widthOut, heightOut, thirdOut, fourthOut) as boolean
    if not wrote then return 0, 0, 0, 0 end
    return widthOut[0] as integer, heightOut[0] as integer,
        thirdOut[0] as integer, fourthOut[0] as integer
end

--- The part of the window nothing is drawn over, as x, y, width and height in
--- screen coordinates.
---
--- The whole window on a desktop. Smaller where a notch, a rounded corner or a
--- system gesture area overlaps it, which is what a phone or a handheld needs
--- to keep a health bar out from under. `events.windowSafeAreaChanged` reports
--- that it moved.
function Window:safeArea(): integer, integer, integer, integer
    if self.handle == nil then return 0, 0, 0, 0 end
    if not (C.SDL_GetWindowSafeArea(self.handle, rectOut) as boolean) then
        return 0, 0, 0, 0
    end
    return tonumber(rectOut.x) as integer, tonumber(rectOut.y) as integer,
        tonumber(rectOut.w) as integer, tonumber(rectOut.h) as integer
end

--- Smallest size the window may be resized to, in screen coordinates.
function Window:minimumSize(): integer, integer
    if self.handle == nil then return 0, 0 end
    return pair(C.SDL_GetWindowMinimumSize(self.handle, widthOut, heightOut) as boolean)
end

--- Sets the smallest size the window may be resized to. Zero for either
--- dimension removes the limit on it.
function Window:setMinimumSize(width: integer, height: integer): boolean
    if self.handle == nil then return false end
    return C.SDL_SetWindowMinimumSize(self.handle, width, height) as boolean
end

--- Largest size the window may be resized to, in screen coordinates. Zero for
--- a dimension that has no limit.
function Window:maximumSize(): integer, integer
    if self.handle == nil then return 0, 0 end
    return pair(C.SDL_GetWindowMaximumSize(self.handle, widthOut, heightOut) as boolean)
end

--- Sets the largest size the window may be resized to. Zero for either
--- dimension removes the limit on it.
function Window:setMaximumSize(width: integer, height: integer): boolean
    if self.handle == nil then return false end
    return C.SDL_SetWindowMaximumSize(self.handle, width, height) as boolean
end

--- Narrowest and widest width-over-height the window may be resized to. Zero
--- for a bound that is not set.
function Window:aspectRatio(): number, number
    if self.handle == nil then return 0, 0 end
    local wrote = C.SDL_GetWindowAspectRatio(self.handle,
        minAspectOut, maxAspectOut) as boolean
    if not wrote then return 0, 0 end
    return minAspectOut[0] as number, maxAspectOut[0] as number
end

--- Constrains resizing to a range of width-over-height ratios.
---
--- The same value for both pins the window to one shape, which is what a game
--- that will not letterbox wants. Zero for either removes that bound.
function Window:setAspectRatio(minimum: number, maximum: number): boolean
    if self.handle == nil then return false end
    return C.SDL_SetWindowAspectRatio(self.handle, minimum, maximum) as boolean
end

-------------------------------------------------------------------------------
-- Visibility and window state
-------------------------------------------------------------------------------

--- Maps the window onto the desktop. What a window created `hidden` needs
--- before anything it draws is seen.
function Window:show(): boolean
    if self.handle == nil then return false end
    return C.SDL_ShowWindow(self.handle) as boolean
end

--- Unmaps the window without destroying it.
---
--- Safe while a device holds it: no swapchain texture is acquired while the
--- window is hidden and the frame is skipped whole rather than drawn nowhere.
function Window:hide(): boolean
    if self.handle == nil then return false end
    return C.SDL_HideWindow(self.handle) as boolean
end

--- Whether the window is mapped. False for a window created `hidden` and one
--- that `hide` was called on, and true for a minimised window, which is mapped
--- and not visible.
function Window:isVisible(): boolean
    if self.handle == nil then return false end
    return not hasFlag(self, K.SDL_WINDOW_HIDDEN)
end

--- Brings the window to the front and gives it input focus.
---
--- Distinct from `flash`: this takes focus, which a desktop may refuse or may
--- allow to interrupt whatever the user was doing. Ask for attention instead
--- unless the user just did something that expects a window to come forward.
function Window:raise(): boolean
    if self.handle == nil then return false end
    return C.SDL_RaiseWindow(self.handle) as boolean
end

--- Minimises the window to the taskbar or dock.
function Window:minimize(): boolean
    if self.handle == nil then return false end
    return C.SDL_MinimizeWindow(self.handle) as boolean
end

--- Whether the window is minimised. `events.windowMinimized` reports that it
--- became so; this is how the first frame after startup finds out.
function Window:isMinimized(): boolean
    return hasFlag(self, K.SDL_WINDOW_MINIMIZED)
end

--- Maximises the window to fill the display's usable bounds.
function Window:maximize(): boolean
    if self.handle == nil then return false end
    return C.SDL_MaximizeWindow(self.handle) as boolean
end

--- Whether the window is maximised.
function Window:isMaximized(): boolean
    return hasFlag(self, K.SDL_WINDOW_MAXIMIZED)
end

--- Returns a minimised or maximised window to its previous size and position.
function Window:restore(): boolean
    if self.handle == nil then return false end
    return C.SDL_RestoreWindow(self.handle) as boolean
end

--- Whether something is covering the window entirely.
---
--- A frame drawn now is not seen, which is worth knowing before an expensive
--- one is built. Independent of minimisation: an occluded window is mapped and
--- not minimised, and both stop the swapchain handing out a texture.
function Window:isOccluded(): boolean
    return hasFlag(self, K.SDL_WINDOW_OCCLUDED)
end

--- Whether the window has keyboard focus, which is where key events are going.
---
--- `events.windowFocusGained` and `windowFocusLost` report the transitions.
--- This is the value they start from, which no event supplies: a window that
--- has had focus since it opened has fired neither.
function Window:hasFocus(): boolean
    return hasFlag(self, K.SDL_WINDOW_INPUT_FOCUS)
end

--- Whether the pointer is over the window.
---
--- Beside `events.windowMouseEnter` and `windowMouseLeave` on the same terms
--- as `hasFocus`. False while relative mouse mode is on, since there is no
--- pointer position for the window to contain.
function Window:hasMouseFocus(): boolean
    return hasFlag(self, K.SDL_WINDOW_MOUSE_FOCUS)
end

-------------------------------------------------------------------------------
-- Fullscreen
-------------------------------------------------------------------------------

--- Enters or leaves fullscreen.
---
--- Which fullscreen depends on `setFullscreenMode`: with no mode set this is
--- borderless fullscreen at the desktop's own resolution, which is what a
--- window that shares a display with other applications wants. With a mode set
--- it changes the display's video mode to it.
---
--- Safe while a device holds the window. The swapchain follows the new size
--- and the renderer picks it up from the texture it acquires next frame.
--- `events.windowEnterFullscreen` and `windowLeaveFullscreen` report that the
--- change actually landed, which on a compositing window system is later than
--- this returns; `sync` is the other way to wait for it.
function Window:setFullscreen(fullscreen: boolean): boolean
    if self.handle == nil then return false end
    return C.SDL_SetWindowFullscreen(self.handle, fullscreen ~= false) as boolean
end

--- Whether the window is fullscreen.
function Window:isFullscreen(): boolean
    return hasFlag(self, K.SDL_WINDOW_FULLSCREEN)
end

--- The video mode fullscreen will use, or nil for borderless fullscreen at
--- whatever the desktop is already running.
function Window:fullscreenMode(): Window.DisplayMode
    if self.handle == nil then return nil end
    return toMode(C.SDL_GetWindowFullscreenMode(self.handle))
end

--- Chooses the video mode fullscreen uses, or nil for borderless fullscreen at
--- the desktop's resolution.
---
--- The mode has to have come from `fullscreenModes` or
--- `closestFullscreenMode`, because SDL matches it against the modes the
--- display actually has and a record assembled by hand names one that may not
--- exist. Takes effect the next time the window is made fullscreen, and
--- immediately if it already is.
function Window:setFullscreenMode(mode: Window.DisplayMode): boolean
    if self.handle == nil then return false end
    if mode == nil then
        return C.SDL_SetWindowFullscreenMode(self.handle, nil) as boolean
    end
    if mode._mode == nil then
        error("tecs: Window:setFullscreenMode needs a mode from " ..
            "Window.fullscreenModes or Window.closestFullscreenMode", 2)
    end
    return C.SDL_SetWindowFullscreenMode(self.handle, mode._mode) as boolean
end

-------------------------------------------------------------------------------
-- Decoration and appearance
-------------------------------------------------------------------------------

--- Sets the window's title, and the copy `title` reports.
function Window:setTitle(title: string): boolean
    if title == nil then
        error("tecs: Window:setTitle needs a string", 2)
    end
    self.title = title
    if self.handle == nil then return false end
    return C.SDL_SetWindowTitle(self.handle, title) as boolean
end

--- Sets the image the desktop shows the window as.
---
--- Decoded synchronously from `path`, because an icon is wanted before the
--- first frame and the asset system decodes on a worker and answers with a GPU
--- texture, which is not what SDL takes. SDL copies the pixels, so nothing is
--- retained here. False when the file could not be decoded.
function Window:setIcon(path: string): boolean
    if path == nil then
        error("tecs: Window:setIcon needs a path", 2)
    end
    if self.handle == nil then return false end
    return applyIcon(self.handle, path)
end

--- Whether the window can be resized by dragging its edge. Says nothing about
--- `setSize`, which works either way.
function Window:isResizable(): boolean
    return hasFlag(self, K.SDL_WINDOW_RESIZABLE)
end

--- Allows or forbids the user resizing the window.
function Window:setResizable(resizable: boolean): boolean
    if self.handle == nil then return false end
    return C.SDL_SetWindowResizable(self.handle, resizable ~= false) as boolean
end

--- Whether the window has a title bar and a frame.
function Window:isBordered(): boolean
    if self.handle == nil then return false end
    return not hasFlag(self, K.SDL_WINDOW_BORDERLESS)
end

--- Adds or removes the title bar and the frame. The client area keeps its
--- size, so the window as a whole changes size by the border thickness.
function Window:setBordered(bordered: boolean): boolean
    if self.handle == nil then return false end
    return C.SDL_SetWindowBordered(self.handle, bordered ~= false) as boolean
end

--- Whether the window is kept above others.
function Window:isAlwaysOnTop(): boolean
    return hasFlag(self, K.SDL_WINDOW_ALWAYS_ON_TOP)
end

--- Keeps the window above others, or stops doing so.
function Window:setAlwaysOnTop(onTop: boolean): boolean
    if self.handle == nil then return false end
    return C.SDL_SetWindowAlwaysOnTop(self.handle, onTop ~= false) as boolean
end

--- Whether the window can take keyboard focus. True for an ordinary window.
function Window:isFocusable(): boolean
    if self.handle == nil then return false end
    return not hasFlag(self, K.SDL_WINDOW_NOT_FOCUSABLE)
end

--- Allows or forbids the window taking keyboard focus. A window that cannot
--- take focus is what an overlay uses to stay out of the way.
function Window:setFocusable(focusable: boolean): boolean
    if self.handle == nil then return false end
    return C.SDL_SetWindowFocusable(self.handle, focusable ~= false) as boolean
end

--- How opaque the window is, 0 for invisible and 1 for solid. Zero with no
--- window, and 1 on a platform that composites nothing.
function Window:opacity(): number
    if self.handle == nil then return 0 end
    local value = tonumber(C.SDL_GetWindowOpacity(self.handle)) as number
    if value < 0 then return 0 end
    return value
end

--- Sets how opaque the window is, 0 to 1. Whether the desktop honours it is
--- the desktop's business; false says it did not.
function Window:setOpacity(opacity: number): boolean
    if self.handle == nil then return false end
    return C.SDL_SetWindowOpacity(self.handle, opacity) as boolean
end

-------------------------------------------------------------------------------
-- Attention
-------------------------------------------------------------------------------

--- Asks for the user's attention without taking focus.
---
--- The polite form of `raise`: the taskbar entry or the dock icon is marked
--- and the user decides when to look. `"untilFocused"` keeps asking, which
--- suits a turn-based game waiting on a player who alt-tabbed away, and
--- `"cancel"` stops it.
function Window:flash(operation: Window.Flash): boolean
    local value = FLASHES[operation]
    if value == nil then
        error(("tecs: unknown flash operation '%s'"):format(tostring(operation)), 2)
    end
    if self.handle == nil then return false end
    return C.SDL_FlashWindow(self.handle, value) as boolean
end

--- What the taskbar or dock is showing over the application's icon, and how
--- far along it is. "none" and 0 with no window.
function Window:progress(): Window.Progress, number
    if self.handle == nil then return "none", 0 end
    local state = PROGRESS_NAMES[tonumber(C.SDL_GetWindowProgressState(self.handle)) as integer]
    if state == nil then return "none", 0 end
    return state, tonumber(C.SDL_GetWindowProgressValue(self.handle)) as number
end

--- Shows how far along a long piece of work is, on the taskbar or the dock.
---
--- What a shader pack build or an asset load has to report to, since neither
--- can draw a progress bar in a window that is not rendering yet. `value` runs
--- 0 to 1 and only means anything for "normal", "paused" and "error".
function Window:setProgress(state: Window.Progress, value?: number): boolean
    local resolved = PROGRESS_STATES[state]
    if resolved == nil then
        error(("tecs: unknown progress state '%s'"):format(tostring(state)), 2)
    end
    if self.handle == nil then return false end
    if not (C.SDL_SetWindowProgressState(self.handle, resolved) as boolean) then
        return false
    end
    if value == nil then return true end
    return C.SDL_SetWindowProgressValue(self.handle, value) as boolean
end

-------------------------------------------------------------------------------
-- Confinement
-------------------------------------------------------------------------------

--- Whether the pointer is confined to the window right now.
---
--- False for an unfocused window even where `setMouseGrab` was called and
--- succeeded, since a window that is not receiving the pointer is not holding
--- it either. Becomes true again when focus returns.
function Window:mouseGrab(): boolean
    if self.handle == nil then return false end
    return C.SDL_GetWindowMouseGrab(self.handle) as boolean
end

--- Confines the pointer to the window, or releases it.
---
--- Not the same as `Input:setRelativeMouseMode`, which hides the pointer and
--- delivers deltas: this leaves the pointer visible and stops it walking onto
--- another monitor. A game that wants both sets both.
---
--- Taking the request is not the same as the grab being in force, which is
--- what `mouseGrab` answers: an unfocused window records the request and holds
--- nothing until focus comes back.
function Window:setMouseGrab(grabbed: boolean): boolean
    if self.handle == nil then return false end
    return C.SDL_SetWindowMouseGrab(self.handle, grabbed ~= false) as boolean
end

--- Whether the desktop's own keyboard shortcuts are being intercepted.
function Window:keyboardGrab(): boolean
    if self.handle == nil then return false end
    return C.SDL_GetWindowKeyboardGrab(self.handle) as boolean
end

--- Intercepts the desktop's keyboard shortcuts while the window has focus, so
--- that alt-tab and the like reach the game instead.
---
--- Costly to get wrong, since it is how a window stops the user leaving it.
--- Some desktops refuse it outright and some require a permission the user
--- grants once.
function Window:setKeyboardGrab(grabbed: boolean): boolean
    if self.handle == nil then return false end
    return C.SDL_SetWindowKeyboardGrab(self.handle, grabbed ~= false) as boolean
end

--- The region within the window the pointer is confined to, as x, y, width and
--- height in screen coordinates. All zero when there is none.
function Window:mouseRect(): integer, integer, integer, integer
    if self.handle == nil then return 0, 0, 0, 0 end
    local rect = C.SDL_GetWindowMouseRect(self.handle)
    if rect == nil then return 0, 0, 0, 0 end
    return tonumber(rect.x) as integer, tonumber(rect.y) as integer,
        tonumber(rect.w) as integer, tonumber(rect.h) as integer
end

--- Confines the pointer to part of the window, in screen coordinates.
---
--- Independent of `setMouseGrab`, which confines it to the window as a whole;
--- this applies while the window has focus whether or not the window is
--- grabbed. Called with nothing, the region is removed.
function Window:setMouseRect(x?: integer, y?: integer,
                             width?: integer, height?: integer): boolean
    if self.handle == nil then return false end
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

--- The display this window is mostly on. Zero with no window.
function Window:display(): integer
    if self.handle == nil then return 0 end
    return tonumber(C.SDL_GetDisplayForWindow(self.handle)) as integer
end

--- Every display currently attached, in the order SDL reports them.
---
--- Empty with no video. `events.displayAdded` and `displayRemoved` report that
--- this list changed, so a game with a display menu rebuilds it there rather
--- than polling.
function Window.displays(): {integer}
    local found: {integer} = {}
    if not Window.available() then return found end

    local list = C.SDL_GetDisplays(countOut)
    if list == nil then return found end
    local count = countOut[0] as integer
    for index = 0, count - 1 do
        found[index + 1] = tonumber((list as loader.CArray)[index]) as integer
    end
    C.SDL_free(list)
    return found
end

--- The display the desktop treats as primary, or zero with no video.
function Window.primaryDisplay(): integer
    if not Window.available() then return 0 end
    return tonumber(C.SDL_GetPrimaryDisplay()) as integer
end

--- A display's name as the desktop shows it, for a menu that lets the player
--- choose one. Empty with no video.
function Window.displayName(displayId?: integer): string
    if not Window.available() then return "" end
    return loader.toString(C.SDL_GetDisplayName(display(displayId)))
end

--- A display's position and size in the desktop's coordinate space, as x, y,
--- width and height in screen coordinates.
---
--- The width and height are the desktop dimensions, and the x and y are what
--- makes the coordinates `setPosition` takes span every monitor.
function Window.displayBounds(displayId?: integer): integer, integer, integer, integer
    if not Window.available() then return 0, 0, 0, 0 end
    if not (C.SDL_GetDisplayBounds(display(displayId), rectOut) as boolean) then
        return 0, 0, 0, 0
    end
    return tonumber(rectOut.x) as integer, tonumber(rectOut.y) as integer,
        tonumber(rectOut.w) as integer, tonumber(rectOut.h) as integer
end

--- The part of a display not covered by a taskbar, dock or menu bar, in the
--- same coordinates as `displayBounds`.
---
--- Where a window should be placed and how large it should be to be usable,
--- which `displayBounds` does not answer. `events.displayUsableBoundsChanged`
--- reports that it moved.
function Window.usableBounds(displayId?: integer): integer, integer, integer, integer
    if not Window.available() then return 0, 0, 0, 0 end
    if not (C.SDL_GetDisplayUsableBounds(display(displayId), rectOut) as boolean) then
        return 0, 0, 0, 0
    end
    return tonumber(rectOut.x) as integer, tonumber(rectOut.y) as integer,
        tonumber(rectOut.w) as integer, tonumber(rectOut.h) as integer
end

--- A display's content scale, the same quantity `Window:displayScale` reports
--- for whichever display a window is on. Zero with no video.
---
--- Named for what SDL calls it rather than matching the method, because a
--- record holds one `displayScale` and the two would be the same field.
function Window.contentScale(displayId?: integer): number
    if not Window.available() then return 0 end
    return tonumber(C.SDL_GetDisplayContentScale(display(displayId))) as number
end

--- How a display is rotated right now. `events.displayOrientation` reports
--- that it turned.
function Window.orientation(displayId?: integer): Window.Orientation
    if not Window.available() then return "unknown" end
    local value = tonumber(C.SDL_GetCurrentDisplayOrientation(display(displayId))) as integer
    return ORIENTATIONS[value] or "unknown"
end

--- How a display is built to be held, which does not change.
---
--- What tells a landscape reading apart from a device that is landscape to
--- begin with, and so what a game deciding whether to letterbox or rotate its
--- own content asks alongside `orientation`.
function Window.naturalOrientation(displayId?: integer): Window.Orientation
    if not Window.available() then return "unknown" end
    local value = tonumber(C.SDL_GetNaturalDisplayOrientation(display(displayId))) as integer
    return ORIENTATIONS[value] or "unknown"
end

--- The mode a display was in when the desktop started, which is what leaving
--- fullscreen returns it to. Nil with no video.
function Window.desktopMode(displayId?: integer): Window.DisplayMode
    if not Window.available() then return nil end
    return toMode(C.SDL_GetDesktopDisplayMode(display(displayId)))
end

--- The mode a display is in right now, which differs from `desktopMode` while
--- something holds it fullscreen at another resolution.
function Window.currentMode(displayId?: integer): Window.DisplayMode
    if not Window.available() then return nil end
    return toMode(C.SDL_GetCurrentDisplayMode(display(displayId)))
end

--- Every fullscreen mode a display offers, largest first.
---
--- What a resolution menu is built from, and what `setFullscreenMode` takes.
--- Empty with no video, and on a platform whose only fullscreen is the
--- desktop's own resolution.
function Window.fullscreenModes(displayId?: integer): {Window.DisplayMode}
    local found: {Window.DisplayMode} = {}
    if not Window.available() then return found end

    local list = C.SDL_GetFullscreenDisplayModes(display(displayId), countOut)
    if list == nil then return found end
    local count = countOut[0] as integer
    for index = 0, count - 1 do
        found[index + 1] = toMode((list as loader.CArray)[index] as loader.CValue)
    end
    -- One allocation holds the array of pointers; the modes it points at belong
    -- to SDL and outlive it, which is what lets a mode record keep one.
    C.SDL_free(list)
    return found
end

--- The mode nearest to a requested size and refresh rate.
---
--- What a game restoring a saved resolution asks for, since the display may no
--- longer offer exactly what was saved. Nil when the display offers nothing
--- that fits, and with no video.
--- @param refreshRate Hertz, or 0 or nil for the highest the size allows.
--- @param highDensity Whether modes whose pixel density is above 1 may be
---     chosen. Defaults to false.
function Window.closestFullscreenMode(width: integer, height: integer,
                                      refreshRate?: number,
                                      highDensity?: boolean,
                                      displayId?: integer): Window.DisplayMode
    if not Window.available() then return nil end
    -- Allocated per call rather than shared, because the record keeps it and
    -- SDL reads it again on every `setFullscreenMode`.
    local mode = loader.newStruct("SDL_DisplayMode")
    local found = C.SDL_GetClosestFullscreenDisplayMode(display(displayId),
        width, height, refreshRate or 0, highDensity == true, mode) as boolean
    if not found then return nil end
    return toMode(mode)
end

-------------------------------------------------------------------------------
-- The desktop
-------------------------------------------------------------------------------

--- Whether the desktop is asking applications to draw themselves light or
--- dark. "unknown" where the platform has no such preference, and with no
--- video.
function Window.theme(): Window.Theme
    if not Window.available() then return "unknown" end
    return THEMES[tonumber(C.SDL_GetSystemTheme()) as integer] or "unknown"
end

--- Whether the desktop is allowed to blank the display while this application
--- runs.
---
--- False for most of a game's life, since SDL disables the screen saver as
--- soon as video comes up: a player holding a gamepad is not idle, and the
--- keyboard and mouse are what the desktop watches. Turn it back on for a menu
--- or a cutscene nobody is playing through.
function Window.screenSaverEnabled(): boolean
    if not Window.available() then return false end
    return C.SDL_ScreenSaverEnabled() as boolean
end

--- Allows or forbids the desktop blanking the display.
---
--- Applies to the whole application rather than to one window, which is why it
--- is here and not a method. False with no video.
function Window.setScreenSaverEnabled(enabled: boolean): boolean
    if not Window.available() then return false end
    if enabled ~= false then
        return C.SDL_EnableScreenSaver() as boolean
    end
    return C.SDL_DisableScreenSaver() as boolean
end

return Window
