--[[
# Standalone sensors

Standalone accelerometers, gyroscopes and platform-specific sensors do not
belong to a gamepad. Enumerate a snapshot, open the selected instance id, poll
it, and close it explicitly.

```teal
for _, device in ipairs(tecs.input.sensors()) do
    local sensor <const>, reason <const> = tecs.input.openSensor(device.id)
    if sensor ~= nil then
        local values <const>, readError <const> = sensor:read()
        if values ~= nil then
            print(sensor.name, values[1], values[2], values[3])
        else
            print(readError)
        end
        sensor:destroy()
    else
        print(reason)
    end
end
```

`Sensor:read` returns three values by default and accepts one to sixteen for a
platform-specific sensor. Acceleration uses meters per second squared and
rotation uses radians per second.
]]

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K

--- `Device` describes a standalone sensor returned by enumeration.
---
--- The platform sets every field. Callers treat the snapshot as read-only.
local record Device
    --- Read-only. The platform sets `id` to an instance id that remains valid
    --- while the device stays attached.
    id: number
    --- Read-only. The platform sets `name` to the device display name.
    name: string
    --- Read-only. The platform sets `kind` to `"accelerometer"`,
    --- `"gyroscope"`, a left or right variant, or `"unknown"`.
    kind: string
    --- Read-only. The platform sets `platformType` to its private type number,
    --- or zero when none exists. Ordinary game code ignores this field.
    platformType: integer
end

--- A `Sensor` owns one opened standalone sensor and reads it by polling.
---
--- The platform sets every public field at open. Callers treat those fields as
--- read-only and close the object with `destroy`.
local record Sensor
    --- Read-only. The platform sets `id` from the opened device.
    id: number
    --- Read-only. The platform sets `name` from the opened device.
    name: string
    --- Read-only. The platform sets `kind` from the same vocabulary as
    --- `Device.kind`.
    kind: string
    --- Read-only. The platform sets `platformType` to its private type number,
    --- or zero when none exists. Ordinary game code ignores this field.
    platformType: integer
    _handle: loader.CPtr
    _destroyed: boolean

    --- Reads the newest values.
    ---
    --- Three values is the natural size for accelerometers and gyroscopes. A
    --- platform-specific sensor can request up to sixteen.
    ---
    --- @param count The caller requests one to sixteen values or omits the
    ---     count for three. Invalid counts return an error instead of raising.
    --- @return Returns a fresh caller-owned list. Acceleration uses meters per
    ---     second squared and rotation uses radians per second. The method
    ---     returns nil after failure or destruction.
    --- @return Returns the reason when the first return is nil.
    read: function(self: Sensor, count?: integer): {number}, string

    --- Closes the sensor. Safe to call more than once.
    destroy: function(self: Sensor)
end

local record sensors
    --- Describes one enumerated sensor before open.
    type Device = Device

    --- Describes one opened sensor.
    type Sensor = Sensor

    --- Returns the standalone sensors attached now.
    ---
    --- @return Returns a fresh caller-owned list in platform order. It returns
    ---     an empty list when no sensors exist or initialization fails.
    --- @return Returns SDL's reason when initialization or enumeration fails.
    sensors: function(): {Device}, string

    --- Opens an attached standalone sensor.
    ---
    --- @param id The caller supplies an instance id from `sensors`. An id stops
    ---     naming the device after unplug.
    --- @return Returns the opened sensor, or nil on failure. The caller owns
    ---     the sensor and closes it with `destroy`.
    --- @return Returns the reason when the first return is nil.
    openSensor: function(id: number): Sensor, string
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
    return setmetatable(
        {
            id = tonumber(C.SDL_GetSensorID(handle)) as number,
            name = loader.toString(C.SDL_GetSensorName(handle)),
            kind = SENSOR_TYPES[kind] or "unknown",
            platformType = tonumber(C.SDL_GetSensorNonPortableType(handle)) as integer,
            _handle = handle,
            _destroyed = false,
        } as Sensor,
        SensorMT
    ), nil
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
