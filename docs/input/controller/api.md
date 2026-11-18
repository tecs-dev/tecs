---
description: "Find the generated controller contracts for managers, logical controls, bindings and gamepad configuration"
---

# Controller API reference

The API documentation lives on declarations and is generated from the source.
See [](tecs.controller) for installation, standalone construction and world
resource lookup.

- [](tecs.controller.ControlManager) owns players, creates and removes
  controllers, and refreshes device assignments.
- [](tecs.controller.Controller) reads logical state, movement pairs and raw
  values, replaces bindings, changes gamepad policy and requests identification
  rumble.
- [](tecs.controller.Bindings) defines action lists and movement pairs.
- [](tecs.controller.GamepadConfig) configures a selected pad, automatic
  assignment and the axis deadzone.

The [controller guide](index.md), [binding formats](bindings.md) and
[gamepad workflow](gamepad.md) show these contracts together. The
[input guide](../index.md) explains capture and fixed-step timing.
