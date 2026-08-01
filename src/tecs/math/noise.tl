--[=[
Native procedural scalar fields in two and three dimensions.

```teal
local terrain <const> = tecs.math.noise.new({
    algorithm = "perlin",
    fractal = "fbm",
    seed = 1234,
    frequency = 0.01,
    octaves = 4,
})

local height <const> = terrain:sample2(worldX, worldY)
```

A field is immutable after construction. The seed, algorithm, and options
therefore determine every sample, and sampling carries no snapshot state.
`fill2` crosses into native code once for a complete row-major grid and reuses
native scratch storage when the same field fills another grid.

FastNoise Lite supplies the algorithms. Its output is stable within the
version Tecs pins, but upgrading that dependency may change a generated field.
Persist the seed and options rather than generated values only when accepting
that versioned behavior.
]=]

local ffi <const> = require("ffi")
local binding <const> = require("tecs.ffi.rust")
local loader <const> = require("tecs.ffi.loader")

local C <const> = binding.C
local abs <const> = math.abs
local floor <const> = math.floor
local huge <const> = math.huge

local DEFAULT_SEED <const> = 0x5EED1234
local MAX_FLOAT <const> = 3.4028234663852886e38
local MAX_GRID_EXTENT <const> = 2147483647
local MAX_OCTAVES <const> = 32

local record noise
    --- Selects the native scalar-field algorithm.
    enum Algorithm
        --- `"perlin"` selects classic gradient noise.
        "perlin"
        --- `"simplex"` selects OpenSimplex2 noise.
        "simplex"
        --- `"simplexSmooth"` selects the smoother OpenSimplex2S variant.
        "simplexSmooth"
        --- `"cellular"` selects a nearest-feature cellular field.
        "cellular"
        --- `"value"` selects linearly interpolated value noise.
        "value"
        --- `"valueCubic"` selects cubically interpolated value noise.
        "valueCubic"
    end

    --- Selects how the field combines frequency octaves.
    enum Fractal
        --- `"none"` samples one octave.
        "none"
        --- `"fbm"` adds successively finer and quieter octaves.
        "fbm"
        --- `"ridged"` folds each octave into sharp ridges before combining it.
        "ridged"
        --- `"pingPong"` folds each octave repeatedly into terraces before combining it.
        "pingPong"
    end

    --- Configures one immutable native noise field.
    record Options
        --- Caller-writable. Selects the field algorithm. Defaults to `"perlin"`.
        algorithm: Algorithm
        --- Caller-writable. Selects octave composition. Defaults to `"none"`.
        fractal: Fractal
        --- Caller-writable. Selects the repeatable field. Defaults to `0x5EED1234`.
        seed: integer
        --- Caller-writable. Scales every coordinate before sampling. Defaults to `0.01`.
        frequency: number
        --- Caller-writable. Sets the octave count for a fractal field. Defaults to three.
        octaves: integer
        --- Caller-writable. Multiplies frequency between octaves. Defaults to two.
        lacunarity: number
        --- Caller-writable. Multiplies amplitude between octaves. Defaults to `0.5`.
        gain: number
        --- Caller-writable. Lets one octave's value influence the next octave's
        --- amplitude. Defaults to zero and accepts values in `[0, 1]`.
        weightedStrength: number
        --- Caller-writable. Sets the fold strength for `"pingPong"`. Defaults to two.
        pingPongStrength: number
    end

    --- Represents an immutable native procedural field.
    record Noise
        --- Engine-owned. Stores the native FastNoise Lite field. Ordinary game
        --- code should ignore this field.
        _handle: loader.CPtr
        --- Engine-owned. Stores reusable native output for `fill2`. Ordinary
        --- game code should ignore this field.
        _scratch: loader.CArray
        --- Engine-owned. Reports the number of floats `_scratch` can hold.
        --- Ordinary game code should ignore this field.
        _scratchCapacity: integer

        --- Samples the field at a two-dimensional coordinate.
        ---
        --- @param x A finite horizontal coordinate, scaled by the field's frequency.
        --- @param y A finite vertical coordinate, scaled by the field's frequency.
        --- @return A value in `[-1, 1]`.
        sample2: function(self: Noise, x: number, y: number): number

        --- Samples the field at a three-dimensional coordinate.
        ---
        --- @param x A finite horizontal coordinate, scaled by the field's frequency.
        --- @param y A finite vertical coordinate, scaled by the field's frequency.
        --- @param z A finite depth coordinate, scaled by the field's frequency.
        --- @return A value in `[-1, 1]`.
        sample3: function(self: Noise, x: number, y: number, z: number): number

        --- Fills a list with a row-major two-dimensional grid.
        ---
        --- Rows advance by `stepY`; columns advance by `stepX`. The method
        --- replaces indices `1..width*height`, removes any old trailing
        --- entries, and retains the table and native scratch allocation for
        --- reuse.
        ---
        --- @param values The caller-owned list the method fills and returns.
        --- @param width The number of columns, as an integer in `[0, 2147483647]`.
        --- @param height The number of rows, as an integer in `[0, 2147483647]`.
        --- @param originX The first column's coordinate. Defaults to zero.
        --- @param originY The first row's coordinate. Defaults to zero.
        --- @param stepX The coordinate distance between columns. Defaults to one.
        --- @param stepY The coordinate distance between rows. Defaults to one.
        --- @return `values` itself after replacing its contents.
        fill2: function(
            self: Noise,
            values: {number},
            width: integer,
            height: integer,
            originX?: number,
            originY?: number,
            stepX?: number,
            stepY?: number
        ): {number}
    end

    --- Creates an immutable native procedural field.
    ---
    --- Invalid enum names, non-finite numeric options, a seed outside the
    --- signed 32-bit range, an octave count outside `1..32`, or a weighted
    --- strength outside `[0, 1]` raise at the call site.
    ---
    --- @param options The field configuration. Nil takes every documented default.
    --- @return A field whose native allocation the Lua collector releases.
    new: function(options?: Options): Noise
end

local NoiseMT <const>: metatable<noise.Noise> = {__index = noise.Noise}

local algorithms <const>: {string: integer} = {
    perlin = 0,
    simplex = 1,
    simplexSmooth = 2,
    cellular = 3,
    value = 4,
    valueCubic = 5,
}

local fractals <const>: {string: integer} = {
    none = 0,
    fbm = 1,
    ridged = 2,
    pingPong = 3,
}

local function finiteFloat(value: number): boolean
    return type(value) == "number" and value == value and value ~= huge and value ~= -huge and abs(value) <= MAX_FLOAT
end

local function checkCoordinate(value: number, name: string, level: integer)
    if type(value) ~= "number" or value ~= value or value == huge or value == -huge then
        error("noise: " .. name .. " must be finite", level)
    end
end

local function checkExtent(value: integer, name: string)
    if type(value) ~= "number" or value ~= floor(value) or value < 0 or value > MAX_GRID_EXTENT then
        error("noise: " .. name .. " must be an integer from zero through 2147483647", 3)
    end
end

function noise.Noise:sample2(x: number, y: number): number
    checkCoordinate(x, "x", 2)
    checkCoordinate(y, "y", 2)
    return tonumber(C.tecsNoiseSample2(self._handle, x, y))
end

function noise.Noise:sample3(x: number, y: number, z: number): number
    checkCoordinate(x, "x", 2)
    checkCoordinate(y, "y", 2)
    checkCoordinate(z, "z", 2)
    return tonumber(C.tecsNoiseSample3(self._handle, x, y, z))
end

function noise.Noise:fill2(
    values: {number},
    width: integer,
    height: integer,
    originX?: number,
    originY?: number,
    stepX?: number,
    stepY?: number
): {number}
    if type(values) ~= "table" then
        error("noise: fill2 needs an output table", 2)
    end
    checkExtent(width, "width")
    checkExtent(height, "height")
    originX = originX or 0.0
    originY = originY or 0.0
    stepX = stepX or 1.0
    stepY = stepY or 1.0
    checkCoordinate(originX, "originX", 2)
    checkCoordinate(originY, "originY", 2)
    checkCoordinate(stepX, "stepX", 2)
    checkCoordinate(stepY, "stepY", 2)

    if height > 0 and width > floor(MAX_GRID_EXTENT / height) then
        error("noise: the grid dimensions are too large", 2)
    end
    local count <const> = width * height
    if count > self._scratchCapacity then
        local capacity = self._scratchCapacity
        while capacity < count do
            capacity = capacity * 2
        end
        self._scratch = loader.newArray("float[?]", capacity)
        self._scratchCapacity = capacity
    end
    if not C.tecsNoiseFill2(self._handle, self._scratch, width, height, originX, originY, stepX, stepY) as boolean then
        error("noise: the grid dimensions are too large", 2)
    end

    local scratch <const> = self._scratch as {integer: number}
    for index = 1, count do
        values[index] = tonumber(scratch[index - 1])
    end
    for index = #values, count + 1, -1 do
        (values as {any})[index] = nil
    end
    return values
end

function noise.new(options?: noise.Options): noise.Noise
    options = options or {} as noise.Options
    local algorithmName <const> = options.algorithm or "perlin"
    local algorithm <const> = algorithms[algorithmName]
    if algorithm == nil then
        error("noise: unknown algorithm " .. tostring(algorithmName), 2)
    end
    local fractalName <const> = options.fractal or "none"
    local fractal <const> = fractals[fractalName]
    if fractal == nil then
        error("noise: unknown fractal " .. tostring(fractalName), 2)
    end

    local seed = options.seed
    if seed == nil then
        seed = DEFAULT_SEED
    end
    if type(seed) ~= "number" or seed ~= floor(seed) or seed < -2147483648 or seed > 2147483647 then
        error("noise: seed must be a signed 32-bit integer", 2)
    end
    local frequency = options.frequency
    if frequency == nil then
        frequency = 0.01
    end
    local octaves = options.octaves
    if octaves == nil then
        octaves = 3
    end
    local lacunarity = options.lacunarity
    if lacunarity == nil then
        lacunarity = 2.0
    end
    local gain = options.gain
    if gain == nil then
        gain = 0.5
    end
    local weightedStrength = options.weightedStrength
    if weightedStrength == nil then
        weightedStrength = 0.0
    end
    local pingPongStrength = options.pingPongStrength
    if pingPongStrength == nil then
        pingPongStrength = 2.0
    end
    if not finiteFloat(frequency) then
        error("noise: frequency must be a finite 32-bit float", 2)
    end
    if type(octaves) ~= "number" or octaves ~= floor(octaves) or octaves < 1 or octaves > MAX_OCTAVES then
        error("noise: octaves must be an integer from 1 through 32", 2)
    end
    if not finiteFloat(lacunarity) then
        error("noise: lacunarity must be a finite 32-bit float", 2)
    end
    if not finiteFloat(gain) then
        error("noise: gain must be a finite 32-bit float", 2)
    end
    if not finiteFloat(weightedStrength) or weightedStrength < 0.0 or weightedStrength > 1.0 then
        error("noise: weightedStrength must be from zero through one", 2)
    end
    if not finiteFloat(pingPongStrength) then
        error("noise: pingPongStrength must be a finite 32-bit float", 2)
    end

    local handle = C.tecsNoiseCreate(
        seed, algorithm, fractal, frequency, octaves, lacunarity, gain, weightedStrength, pingPongStrength
    )
    if handle == nil then
        error("noise: native construction rejected a validated configuration", 2)
    end
    handle = ffi.gc(handle as ffi.CData, C.tecsNoiseDestroy as function(ffi.CData)) as loader.CPtr

    local field = setmetatable({} as noise.Noise, NoiseMT)
    field._handle = handle
    field._scratch = loader.newArray("float[1]")
    field._scratchCapacity = 1
    return field
end

return noise
