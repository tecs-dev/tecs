---
description: "Physics components Collider, RigidBody, and StaticBody with shapes, mass, forces, and filtering"
outline: deep
---

# Physics Components

The physics module provides three components for adding physics to entities: `Collider`, `RigidBody`, and
`StaticBody`. All require a `Transform` component.

## physics.Collider

Defines the collision shape for an entity. By itself (without RigidBody or StaticBody), creates a kinematic body that
is moved by Transform, not by physics.

```teal
local Transform = tecs.builtins.Transform

-- Circle collider
world:spawn(
    Transform(100, 100),
    physics.Collider.new({ shape = "circle", radius = 16 })
)

-- Rectangle collider
world:spawn(
    Transform(200, 100),
    physics.Collider.new({ shape = "rectangle", width = 32, height = 48 })
)
```

### Configuration

| Property        | Type        | Default      | Description                                                  |
| --------------- | ----------- | ------------ | ------------------------------------------------------------ |
| `shape`         | `string`    | `"circle"`   | Shape type: `"circle"` or `"rectangle"`                      |
| `radius`        | `number`    | `16`         | Radius for circle shapes                                     |
| `width`         | `number`    | `32`         | Width for rectangle shapes                                   |
| `height`        | `number`    | `32`         | Height for rectangle shapes                                  |
| `sensor`        | `boolean`   | `false`      | If true, detects collisions but doesn't respond physically   |
| `restitution`   | `number`    | `0`          | Bounciness (0 = no bounce, 1 = full bounce)                  |
| `friction`      | `number`    | `0.3`        | Surface friction                                             |
| `categories`    | `integer`   | `0xFFFF`     | Collision category bitmask (16-bit)                          |
| `mask`          | `integer`   | `0xFFFF`     | Collision mask bitmask (16-bit)                              |
| `groupIndex`    | `integer`   | `0`          | Collision group (-32768 to 32767, see below)                 |

*See [Shape:setFilterData](https://love2d.org/wiki/Shape:setFilterData) for details on collision filtering.*

#### Restitution and friction precedence

* For **static bodies**, the Collider's `restitution` and `friction` values are used.
* For **dynamic bodies** (entities with RigidBody), the RigidBody's `restitution` and `friction` values take
  precedence and the Collider's values are ignored.

### Runtime Access

After spawning, the Collider component exposes the Box2D body and shapes:

| Field         | Type                                              | Description                                      |
| ------------- | ------------------------------------------------- | ------------------------------------------------ |
| `body`        | [`Body`](https://love2d.org/wiki/Body)            | The Box2D body                                   |
| `shapeList`   | `{`[`Shape`](https://love2d.org/wiki/Shape)`}`    | List of shapes (for multi-shape colliders)       |

```teal
local c = world:get(entityId, physics.Collider)
c.body:applyForce(100, 0)
c.body:applyLinearImpulse(0, -200)
c.body:setLinearVelocity(100, 0)
```

*See [Body:applyForce](https://love2d.org/wiki/Body:applyForce) and
[Body:applyLinearImpulse](https://love2d.org/wiki/Body:applyLinearImpulse) for details.*

## physics.RigidBody

Makes an entity a dynamic physics body that responds to forces and collisions.

```teal
world:spawn(
    Transform(100, 100),
    physics.Collider.new({ shape = "circle", radius = 16 }),
    physics.RigidBody.new({ mass = 1, restitution = 0.8 })
)
```

### Configuration

| Property          | Type        | Default   | Description                                                          |
| ----------------- | ----------- | --------- | -------------------------------------------------------------------- |
| `bodyType`        | `BodyType`  | `"dynamic"` | Love body type (`"dynamic"`, `"kinematic"`, or `"static"`)          |
| `mass`            | `number`    | *nil*     | Explicit body mass in kg (see below)                                 |
| `density`         | `number`    | `1`       | Shape density in kg/px², used by Box2D to compute mass from area     |
| `restitution`     | `number`    | `0`       | Bounciness, 0-1 (overrides Collider's value)                         |
| `friction`        | `number`    | `0.3`     | Surface friction, 0+ (overrides Collider's value)                    |
| `drag`            | `number`    | `0`       | Linear damping, 0+ (higher = more resistance)                        |
| `angularDrag`     | `number`    | `0`       | Angular damping, 0+ (higher = more rotational resistance)            |
| `vx`              | `number`    | `0`       | Initial X velocity in px/s                                           |
| `vy`              | `number`    | `0`       | Initial Y velocity in px/s                                           |
| `bullet`          | `boolean`   | `false`   | Enable continuous collision detection for fast objects               |
| `fixedRotation`   | `boolean`   | `false`   | Prevent rotation (default from plugin config)                        |

The `fixedRotation` default comes from the plugin's `defaultFixedRotation` config option. If neither is set, it
defaults to `false` (matching Box2D's default).

### Mass vs Density

By default, Box2D computes mass automatically from shape area and `density`. This is usually what you want:
larger shapes are heavier.

Set `mass` to override this with an explicit value. When `mass` is set, the body's total mass is forced to that
value after shape creation, preserving the center of mass and inertia computed from density.

*See [Body](https://love2d.org/wiki/Body) for more about Box2D bodies.*

## physics.StaticBody

Marks an entity as a static physics body. Static bodies don't move but can be collided with. Takes no arguments.

```teal
-- Ground platform
world:spawn(
    Transform(400, 550),
    physics.Collider.new({ shape = "rectangle", width = 800, height = 20 }),
    physics.StaticBody()
)
```

## Multi-Shape Colliders

Create colliders with multiple shapes for complex hitboxes:

```teal
world:spawn(
    Transform(100, 100),
    physics.Collider.new({
        shapes = {
            { type = "circle", radius = 16, offsetX = 0, offsetY = -20 },  -- Head
            { type = "rectangle", width = 24, height = 40 },               -- Body
        }
    }),
    physics.RigidBody.new({ mass = 1 })
)
```

All shapes share a single Box2D body. Individual shapes are accessible at runtime via `Collider.shapeList`.

### Shape Config Fields

| Property    | Type        | Default      | Description                                   |
| ----------- | ----------- | ------------ | --------------------------------------------- |
| `type`      | `string`    | —            | `"circle"` or `"rectangle"` (required)        |
| `radius`    | `number`    | `16`         | Radius for circle shapes                      |
| `width`     | `number`    | `32`         | Width for rectangle shapes                    |
| `height`    | `number`    | `32`         | Height for rectangle shapes                   |
| `offsetX`   | `number`    | `0`          | X offset from body center                     |
| `offsetY`   | `number`    | `0`          | Y offset from body center                     |
| `sensor`    | `boolean`   | `false`      | Per-shape sensor flag                         |
| `name`      | `string`    | `nil`        | Optional name, accessible via shape user data |

## Applying Forces

Access the Box2D body through the Collider component. Force application should typically run in FixedUpdate:

```teal
world:addSystem({
    phase = tecs.phases.FixedUpdate,
    run = function()
        local c = world:get(playerId, physics.Collider)
        if c and c.body then
            c.body:applyForce(100, 0)
            c.body:applyLinearImpulse(0, -200)
            c.body:setLinearVelocity(100, 0)
        end
    end
})
```
