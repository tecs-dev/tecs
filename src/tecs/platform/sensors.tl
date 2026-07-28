--- Standalone accelerometers, gyroscopes and platform-specific sensors.
---
--- Gamepad sensors stay on `Gamepad`, because their device identity and event
--- routing live there. This module is for sensors SDL exposes independently.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K

local record Device
    --- Instance id, valid while the device is attached.
    id: number
    name: string
    --- `"accelerometer"`, `"gyroscope"`, their left/right variants, or
    --- `"unknown"`.
    kind: string
    --- Platform-specific type number. Zero when there is none.
    platformType: integer
end

--- An opened sensor, read by polling rather than through events.
local record Sensor
    --- Instance id, as `Device.id` reported it.
    id: number
    name: string
    --- The same set of names `Device.kind` uses.
    kind: string
    --- Platform-specific type number. Zero when there is none.
    platformType: integer
    _handle: loader.CPtr
    _destroyed: boolean

    --- Reads the newest values.
    ---
    --- Three values is the natural size for accelerometers and gyroscopes. A
    --- platform-specific sensor can request up to sixteen.
    ---
    --- @param count How many values to take, defaulting to three. An integer
    ---     from 1 to 16; anything else is reported rather than raised. Asking
    ---     for fewer than the sensor produces takes the first few rather than
    ---     failing.
    --- @return The values, a fresh list the caller owns and indexed from one.
    ---     Units are the sensor's own: SDL reports acceleration in meters per
    ---     second squared and rotation in radians per second. Nil on failure,
    ---     which includes reading a destroyed sensor.
    --- @return The reason, when the first return is nil.
    read: function(self: Sensor, count?: integer): {number}, string

    --- Closes the sensor. Safe to call more than once.
    destroy: function(self: Sensor)
end

--- Standalone sensors: listing what is attached, and opening one.
local record sensors
    --- One sensor the platform reports, before it is opened.
    type Device = Device

    --- An opened sensor.
    type Sensor = Sensor
end

local SensorMT <const>: metatable<Sensor> = {__index = Sensor}
local countOut <const> = loader.newArray("int[1]")
local valuesOut <const> = loader.newArray("float[16]")

local SENSOR_TYPES <const>: {integer: string} = {
    [tonumber(C.SDL_SENSOR_UNKNOWN) as integer] = "unknown",
    [tonumber(C.SDL_SENSOR_ACCEL) as integer] = "accelerometer",
    [tonumber(C.SDL_SENSOR_GYRO) as integer] = "gyroscope",
    [tonumber(C.SDL_SENSOR_ACCEL_L) as integer] = "leftAccelerometer",
    [tonumber(C.SDL_SENSOR_GYRO_L) as integer] = "leftGyroscope",
    [tonumber(C.SDL_SENSOR_ACCEL_R) as integer] = "rightAccelerometer",
    [tonumber(C.SDL_SENSOR_GYRO_R) as integer] = "rightGyroscope",
}

local function ensureSubsystem(): boolean, string
    if tonumber(C.SDL_WasInit(K.SDL_INIT_SENSOR)) ~= 0 then
        return true, nil
    end
    if not C.SDL_InitSubSystem(K.SDL_INIT_SENSOR) then
        return false, sdl.error()
    end
    return true, nil
end

--- Sensors attached now, in platform order.
---
--- A snapshot, not a subscription: a sensor unplugged after this leaves an id
--- that `openSensor` refuses.
---
--- @return The devices, listed afresh each call and the caller's to keep.
---     Empty rather than nil when the sensor subsystem cannot start, so a
---     caller that only iterates needs no nil check. Most desktop machines
---     genuinely have none, which is an empty list and not a failure.
--- @return SDL's reason, when something went wrong.
function sensors.sensors(): {Device}, string
    local ok, err = ensureSubsystem()
    if not ok then
        return {}, err
    end

    local out: {Device} = {}
    local ids = C.SDL_GetSensors(countOut)
    if ids == nil then
        return out, sdl.error()
    end
    local list = ids as loader.CArray
    for index = 0, (countOut[0] as integer) - 1 do
        local id = tonumber(list[index]) as number
        local kind = tonumber(C.SDL_GetSensorTypeForID(id)) as integer
        out[#out + 1] = {
            id = id,
            name = loader.toString(C.SDL_GetSensorNameForID(id)),
            kind = SENSOR_TYPES[kind] or "unknown",
            platformType = tonumber(C.SDL_GetSensorNonPortableTypeForID(id)) as integer,
        }
    end
    C.SDL_free(ids)
    return out, nil
end

--- Opens an attached sensor by instance id.
---
--- @param id An instance id from `sensors`. Ids name a device while it stays
---     attached rather than a slot, so one kept across an unplug does not come
---     back to the same sensor.
--- @return The open sensor, whose `name` and `kind` are read from the device
---     itself rather than copied from the listing. Nil on failure, with the
---     reason beside it, and nothing is left open in that case. Closing is the
---     caller's, through `destroy`.
--- @return The reason, when the first return is nil.
function sensors.openSensor(id: number): Sensor, string
    local ok, err = ensureSubsystem()
    if not ok then
        return nil, err
    end
    local handle = C.SDL_OpenSensor(id)
    if handle == nil then
        return nil, sdl.error()
    end
    local kind = tonumber(C.SDL_GetSensorType(handle)) as integer
    return setmetatable({
        id = tonumber(C.SDL_GetSensorID(handle)) as number,
        name = loader.toString(C.SDL_GetSensorName(handle)),
        kind = SENSOR_TYPES[kind] or "unknown",
        platformType = tonumber(C.SDL_GetSensorNonPortableType(handle)) as integer,
        _handle = handle,
        _destroyed = false,
    } as Sensor, SensorMT), nil
end

function Sensor:read(count?: integer): {number}, string
    if self._destroyed then
        return nil, "sensor is destroyed"
    end
    local total = count or 3
    if total < 1 or total > 16 or total ~= math.floor(total) then
        return nil, "sensor value count must be an integer from 1 to 16"
    end
    C.SDL_UpdateSensors()
    if not C.SDL_GetSensorData(self._handle, valuesOut, total) then
        return nil, sdl.error()
    end
    local out: {number} = {}
    for index = 0, total - 1 do
        out[index + 1] = tonumber(valuesOut[index])
    end
    return out, nil
end

function Sensor:destroy()
    if self._destroyed then
        return
    end
    C.SDL_CloseSensor(self._handle)
    self._handle = nil
    self._destroyed = true
end

return sensors
