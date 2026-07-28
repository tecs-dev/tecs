---
description: "Standalone accelerometers, gyroscopes, and platform-specific sensors"
outline: deep
---

# tecs.sensors

`tecs.sensors` exposes sensors the platform reports independently. Sensors built into a gamepad remain methods
and events on [`Gamepad`](/modules/Gamepad), where their controller identity belongs.

## devices

```teal
function sensors.devices(): {sensors.Device}, string
```

Returns the sensors attached now, in platform order, plus an error only when the sensor subsystem could not
start. Each device has:

| Field          | Type      | Meaning                                                                         |
| -------------- | --------- | ------------------------------------------------------------------------------- |
| `id`           | `number`  | Instance id, valid while attached                                               |
| `name`         | `string`  | Platform display name                                                           |
| `kind`         | `string`  | `accelerometer`, `gyroscope`, a left/right variant, or `unknown`                |
| `platformType` | `integer` | Platform-specific type number, for hardware the portable vocabulary cannot name |

## open

```teal
function sensors.open(id: number): sensors.Sensor, string
```

Opens a device from `devices`, returning `(sensor, nil)` or `(nil, error)`. A `Sensor` copies the same metadata
onto `id`, `name`, `kind`, and `platformType`.

## read

```teal
function Sensor:read(count?: integer): {number}, string
```

Reads the newest values after updating SDL's sensor state. The default is three values, which is the natural
vector size for acceleration and angular velocity. A platform-specific sensor may request 1 through 16.

## destroy

```teal
function Sensor:destroy()
```

Closes the native sensor and is safe to call more than once. Reading afterwards returns an error.
