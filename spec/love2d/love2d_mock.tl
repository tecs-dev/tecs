-- Mock Love2D module for testing
local record love2d_mock
    record TimerModule
        getTime: function(): number
        getFPS: function(): number
        step: function(): number
        sleep: function(duration: number)
        currentTime: number  -- Mock time for testing
    end
    record JoystickModule
        enum GamepadButton
            "a"
            "b"
            "x"
            "y"
            "back"
            "guide"
            "start"
            "leftstick"
            "rightstick"
            "leftshoulder"
            "rightshoulder"
            "dpup"
            "dpdown"
            "dpleft"
            "dpright"
        end

        enum GamepadAxis
            "leftx"
            "lefty"
            "rightx"
            "righty"
            "triggerleft"
            "triggerright"
        end

        enum JoystickHat
            "c"  -- centered
            "u"  -- up
            "d"  -- down
            "l"  -- left
            "r"  -- right
            "lu" -- left-up
            "ld" -- left-down
            "ru" -- right-up
            "rd" -- right-down
        end

        record Joystick
            getGUID: function(self: Joystick): string
            getName: function(self: Joystick): string
            getID: function(self: Joystick): number, number
            isGamepad: function(self: Joystick): boolean
            isVibrationSupported: function(self: Joystick): boolean
            setVibration: function(self: Joystick, left: number, right: number, duration: number): boolean

            -- Internal mock state
            _guid: string
            _name: string
            _id: number
            _instanceId: number
            _isGamepad: boolean
            _buttons: {integer: boolean}
            _axes: {string: number}
            _hats: {integer: JoystickHat}
        end

        getJoysticks: function(): {Joystick}
    end

    joystick: JoystickModule
    timer: TimerModule
    audio: {string: function}

    -- Mock joystick registry for testing
    _mockJoysticks: {JoystickModule.Joystick}

    -- Create a mock joystick for testing
    createMockJoystick: function(guid: string, name?: string, isGamepad?: boolean): JoystickModule.Joystick

    -- Clear all mock joysticks
    clearMockJoysticks: function()

    -- Add a mock joystick to the registry
    addMockJoystick: function(joystick: JoystickModule.Joystick)

    -- Remove a mock joystick from the registry
    removeMockJoystick: function(joystick: JoystickModule.Joystick)

    -- Event module for Love2D event handling
    record EventModule
        poll: function(): string, any, any, any, any, any
        pump: function()
        quit: function(reason?: string)
        push: function(name: string, ...: any)
    end
    event: EventModule

    -- Filesystem module for tecs_assets
    record FilesystemModule
        read: function(path: string): string
        getInfo: function(path: string): any
        write: function(path: string, contents: string): boolean, string
        remove: function(path: string): boolean, string
        newFileData: function(contents: string, name: string): love.filesystem.FileData
    end
    filesystem: FilesystemModule

    -- Thread module for tecs_assets
    record ThreadModule
        record Channel
            push: function(self, value: any): number
            pop: function(self): any
            getCount: function(self): integer
            _queue: {any}
        end
        getChannel: function(name: string): Channel
        newThread: function(code: string): Thread

        record Thread
            start: function(self, ...: any)
            isRunning: function(self): boolean
            getError: function(self): string
        end
    end
    thread: ThreadModule

    -- System module for tecs_assets
    record SystemModule
        getProcessorCount: function(): integer
    end
    system: SystemModule

    -- Data module for ByteData. Minimal stub to support shadow_buffer
    -- integration tests; only the bits the shadow pipeline reads.
    record DataModule
        newByteData: function(size: integer): love.data.ByteData
    end
    data: DataModule

    -- Graphics module for Love2D graphics functions
    record GraphicsModule
        getStats: function(): table
        newShader: function(vertex?: string, fragment: string): love.graphics.Shader
        origin: function()
        clear: function(...: any)
        present: function()
        isActive: function(): boolean
        getBackgroundColor: function(): number, number, number, number
        setDefaultFilter: function(min: string, mag: string)
        setLineStyle: function(style: string)
        setLineJoin: function(join: string)
        getWidth: function(): number
        getHeight: function(): number
        newCanvas: function(width: number, height: number): love.graphics.Canvas
        newQuad: function(x: number, y: number, width: number, height: number, sw: number, sh: number): love.graphics.Quad
        getShader: function(): love.graphics.Shader
        setShader: function(shader?: love.graphics.Shader)
        setCanvas: function(canvas?: love.graphics.Canvas)
        getCanvas: function(): love.graphics.Canvas
        draw: function(drawable: love.graphics.Drawable, ...: any)
        setColor: function(...: any)
        setBlendMode: function(mode: string, alphamode?: string)
        getScissor: function(): number, number, number, number
        setScissor: function(...: any)
        translate: function(dx: number, dy: number)
        push: function(stack?: string)
        pop: function()
        newImage: function(imageData: love.image.ImageData): love.graphics.Image
        newFont: function(...: any): love.graphics.Font
        newParticleSystem: function(image: any, bufferSize?: number): love.graphics.ParticleSystem
        print: function(...: any)

        --- Minimal Buffer stub for shadow_buffer integration tests. The
        --- real LÖVE 12 returns an SSBO handle; the stub records the
        --- shape of the call and exposes `_writes` so tests can assert
        --- what was uploaded. Other GPU tests stay pending because
        --- `newComputeShader` isn't stubbed.
        newBuffer: function(format: any, count: integer, options: any): love.graphics.Buffer
    end
    graphics: GraphicsModule

    -- Love2D event handlers
    handlers: {string: function}

    -- Timer module functions
    quit: function(): boolean

    -- Version info (Love2D 12)
    getVersion: function(): integer, integer, integer, string
end

local love: love2d_mock = {
    joystick = {},
    timer = {} as love2d_mock.TimerModule,
    _mockJoysticks = {}
}

-- Mock Love2D 12 version for GPU tests
function love.getVersion(): integer, integer, integer, string
    return 12, 0, 0, "Mock Love2D 12"
end

local JoystickMT: metatable<love2d_mock.JoystickModule.Joystick> = {
    __index = {
        getGUID = function(self: love2d_mock.JoystickModule.Joystick): string
            return self._guid
        end,
        getName = function(self: love2d_mock.JoystickModule.Joystick): string
            return self._name
        end,
        getID = function(self: love2d_mock.JoystickModule.Joystick): number, number
            return self._id, self._instanceId
        end,
        isGamepad = function(self: love2d_mock.JoystickModule.Joystick): boolean
            return self._isGamepad
        end,
        isVibrationSupported = function(self: love2d_mock.JoystickModule.Joystick): boolean
            return self._isGamepad -- Assume gamepads support vibration
        end,
        setVibration = function(self: love2d_mock.JoystickModule.Joystick, _left: number, _right: number, _duration: number): boolean
            -- Mock vibration, just return success
            return self._isGamepad
        end
    }
}

function love.joystick.getJoysticks(): {love2d_mock.JoystickModule.Joystick}
    return love._mockJoysticks
end

local nextId = 1
local nextInstanceId = 1

function love.createMockJoystick(guid: string, name?: string, isGamepad?: boolean): love2d_mock.JoystickModule.Joystick
    local joystick = {
        _guid = guid,
        _name = name or "Mock Controller",
        _id = nextId,
        _instanceId = nextInstanceId,
        _isGamepad = isGamepad ~= false, -- Default to true
        _buttons = {},
        _axes = {},
        _hats = {}
    } as love2d_mock.JoystickModule.Joystick

    setmetatable(joystick, JoystickMT)

    nextId = nextId + 1
    nextInstanceId = nextInstanceId + 1

    return joystick
end

function love.clearMockJoysticks()
    love._mockJoysticks = {}
end

function love.addMockJoystick(joystick: love2d_mock.JoystickModule.Joystick)
    table.insert(love._mockJoysticks, joystick)
end

function love.removeMockJoystick(joystick: love2d_mock.JoystickModule.Joystick)
    for i = #love._mockJoysticks, 1, -1 do
        if love._mockJoysticks[i] == joystick then
            table.remove(love._mockJoysticks, i)
            break
        end
    end
end

-- Initialize timer module
love.timer.currentTime = 0
love.timer.getTime = function(): number
    return love.timer.currentTime
end
love.timer.getFPS = function(): number
    return 60  -- Mock 60 FPS
end
love.timer.step = function(): number
    love.timer.currentTime = love.timer.currentTime + (1/60)
    return 1/60  -- Return delta time
end
love.timer.sleep = function(_duration: number) end

love.audio = {
    setPosition = function(_x: number, _y: number, _z: number) end,
    setOrientation = function(...: any) end,
    setEffect = function(_name: string, _settings: any): boolean return true end,
}

-- Initialize event module for tecs2d
love.event = {
    poll = function(): string, any, any, any, any, any
        -- Return nil to indicate no events
        return nil
    end,
    pump = function()
        -- Do nothing for tests
    end,
    quit = function(_reason?: string) end,
    push = function(_name: string, ...: any) end,
}

-- Initialize handlers for tecs2d
love.handlers = {}

-- Initialize quit function
love.quit = function(): boolean
    return true  -- Allow quit for tests
end

-- Initialize filesystem module for tecs_assets
love.filesystem = {
    read = function(path: string): string
        -- Return mock worker code for tecs_assets
        if path:match("worker") then
            return "-- mock worker"
        end
        return nil
    end,
    getInfo = function(_path: string): any
        return nil
    end,
    write = function(_path: string, _contents: string): boolean, string
        return true, nil
    end,
    remove = function(_path: string): boolean, string
        return true, nil
    end,
    newFileData = function(contents: string, name: string): any
        return {
            getString = function(): string return contents end,
            getFilename = function(): string return name end
        }
    end
}

-- Initialize thread module for tecs_assets
local mockChannels: {string: love2d_mock.ThreadModule.Channel} = {}

love.thread = {
    getChannel = function(name: string): love2d_mock.ThreadModule.Channel
        if not mockChannels[name] then
            local channel: love2d_mock.ThreadModule.Channel = {
                _queue = {},
                push = function(self: love2d_mock.ThreadModule.Channel, value: any): number
                    table.insert(self._queue, value)
                    return #self._queue
                end,
                pop = function(self: love2d_mock.ThreadModule.Channel): any
                    if #self._queue > 0 then
                        return table.remove(self._queue, 1)
                    end
                    return nil
                end,
                getCount = function(self: love2d_mock.ThreadModule.Channel): integer
                    return #self._queue
                end
            }
            mockChannels[name] = channel
        end
        return mockChannels[name]
    end,
    newThread = function(_code: string): love2d_mock.ThreadModule.Thread
        return {
            start = function(_self: love2d_mock.ThreadModule.Thread, ...: any) end,
            isRunning = function(_self: love2d_mock.ThreadModule.Thread): boolean return false end,
            getError = function(_self: love2d_mock.ThreadModule.Thread): string return nil end
        }
    end
}

-- Initialize system module for tecs_assets
love.system = {
    getProcessorCount = function(): integer return 4 end
}

-- Initialize graphics module
love.graphics = {
    getStats = function(): table
        return {
            texturememory = 1024,
            images = 0,
            canvases = 0,
            fonts = 0,
            drawcalls = 0,
            drawcallsbatched = 0
        }
    end,
    newShader = function(_vertex?: string, _fragment?: string): any
        -- Create a mock shader with methods compatible with love.graphics.Shader
        local shader = {
            send = function(_self, _name: string, ...: any) end,
            getWarnings = function(_self): string return "" end,
            hasUniform = function(_self, _name: string): boolean return true end
        }
        return shader
    end,
    origin = function() end,
    clear = function(...: any) end,
    present = function() end,
    isActive = function(): boolean return true end,
    getBackgroundColor = function(): number, number, number, number
        return 0, 0, 0, 1
    end,
    setDefaultFilter = function(_min: string, _mag: string) end,
    setLineStyle = function(_style: string) end,
    setLineJoin = function(_join: string) end,
    getWidth = function(): number return 1920 end,
    getHeight = function(): number return 1080 end,
    newCanvas = function(_width: number, _height: number): any
        -- Create a mock canvas with methods compatible with love.graphics.Canvas
        local canvas = {
            setFilter = function(_self, _min: string, _mag: string) end,
            getDimensions = function(_self): number, number return _width, _height end,
            newImageData = function(_self): any
                -- Mock image data
                return {}
            end
        }
        return canvas
    end,
    newQuad = function(_x: number, _y: number, _width: number, _height: number, _sw: number, _sh: number): any
        -- Create a mock quad with methods compatible with love.graphics.Quad
        local quad = {
            setViewport = function(_self, x: number, y: number, w: number, h: number) end,
            getViewport = function(_self): number, number, number, number
                return _x, _y, _width, _height
            end
        }
        return quad
    end,
    getShader = function(): any return nil end,
    setShader = function(_shader?: any) end,
    setCanvas = function(_canvas?: any) end,
    getCanvas = function(): any return nil end,
    draw = function(_drawable: any, ...: any) end,
    setColor = function(...: any) end,
    setBlendMode = function(_mode: string, _alphamode?: string) end,
    getScissor = function(): number, number, number, number
        return 0, 0, 0, 0
    end,
    setScissor = function(...: any) end,
    translate = function(_dx: number, _dy: number) end,
    push = function(_stack?: string) end,
    pop = function() end,
    newImage = function(...: any): any
        -- Create a mock image with methods compatible with love.graphics.Image
        local image = {
            getDimensions = function(_self): number, number
                return 256, 256  -- Default size
            end,
            getWidth = function(_self): number
                return 256
            end,
            getHeight = function(_self): number
                return 256
            end
        }
        return image
    end,
    newFont = function(...: any): any
        -- Create a mock font
        local font = {
            getWidth = function(_self, _text: string): number return 100 end,
            getHeight = function(_self): number return 16 end,
            getLineHeight = function(_self): number return 1.0 end
        }
        return font
    end,
    newParticleSystem = function(_image: any, _bufferSize?: number): any
        -- Create a mock particle system with all configurable methods
        local ps = {
            -- Core emission
            setEmissionRate = function(_self, _rate: number) end,
            setEmissionArea = function(_self, _distribution: string, _dx: number, _dy: number, _angle: number, _directionRelativeToCenter?: boolean) end,
            setParticleLifetime = function(_self, _min: number, _max?: number) end,

            -- Movement
            setDirection = function(_self, _direction: number) end,
            setSpread = function(_self, _spread: number) end,
            setSpeed = function(_self, _min: number, _max?: number) end,
            setLinearAcceleration = function(_self, _xmin: number, _ymin: number, _xmax?: number, _ymax?: number) end,
            setRadialAcceleration = function(_self, _min: number, _max?: number) end,
            setTangentialAcceleration = function(_self, _min: number, _max?: number) end,
            setLinearDamping = function(_self, _min: number, _max?: number) end,

            -- Appearance
            setSizes = function(_self, ...: number) end,
            setSizeVariation = function(_self, _variation: number) end,
            setColors = function(_self, ...: number) end,
            setRotation = function(_self, _min: number, _max?: number) end,
            setSpin = function(_self, _min: number, _max?: number) end,
            setSpinVariation = function(_self, _variation: number) end,
            setRelativeRotation = function(_self, _enable: boolean) end,

            -- Texture
            setOffset = function(_self, _x: number, _y: number) end,
            setInsertMode = function(_self, _mode: string) end,
            setPosition = function(_self, _x: number, _y: number) end,

            -- Lifecycle
            update = function(_self, _dt: number) end,
            emit = function(_self, _numparticles: number) end,
            start = function(_self) end,
            stop = function(_self) end,
            pause = function(_self) end,
            reset = function(_self) end,
            getCount = function(_self): number return 0 end
        }
        return ps
    end,
    print = function(...: any) end,
    newBuffer = function(_format: any, count: integer, _options: any): any
        return {
            _count = count,
            _writes = {} as {{string:any}},
            setArrayData = function(self: any, data: any, srcStart: integer, destStart: integer, n: integer)
                local writes = self._writes as {{string:any}}
                writes[#writes + 1] = {
                    data = data, dest = destStart, src = srcStart, count = n,
                }
            end,
        }
    end,
}

local cffi <const> = require("ffi")

love.data = {
    newByteData = function(size: integer): any
        local cdata = cffi.new("uint8_t[?]", size)
        return {
            _cdata = cdata,
            _size = size,
            getFFIPointer = function(self: any): any
                return (self as {string:any})._cdata
            end,
            getSize = function(self: any): integer
                return (self as {string:any})._size as integer
            end,
            release = function(_self: any) end,
        }
    end,
}

return love
