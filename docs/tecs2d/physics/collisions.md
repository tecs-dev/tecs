---
outline: deep
---

# Collision Events

Listen for collisions on specific entities using entity observers. Events are emitted to both entities involved in a
collision.

*See [World:setCallbacks](https://love2d.org/wiki/World:setCallbacks) for details on Box2D collision callbacks.*

## physics.BeginContact

Emitted when two shapes start touching.

```teal
local id = world:spawn(
    Transform(100, 100),
    physics.Collider({ shape = "circle", radius = 16 }),
    physics.RigidBody({ mass = 1 })
)

world:observe(id, physics.BeginContact, function(e: physics.BeginContact)
    print("Collided with entity", e.other)
    print("Collision normal:", e.normalX, e.normalY)
end)
```

| Field          | Type                                           | Description                   |
| -------------- | ---------------------------------------------- | ----------------------------- |
| `other`        | `integer`                                      | Entity ID of the other body   |
| `shape`        | [`Shape`](https://love2d.org/wiki/Shape)       | Our shape                     |
| `otherShape`   | [`Shape`](https://love2d.org/wiki/Shape)       | Their shape                   |
| `contact`      | [`Contact`](https://love2d.org/wiki/Contact)   | Box2D contact object          |
| `normalX`      | `number`                                       | Collision normal X            |
| `normalY`      | `number`                                       | Collision normal Y            |

## physics.EndContact

Emitted when two shapes stop touching.

```teal
world:observe(id, physics.EndContact, function(e: physics.EndContact)
    print("Stopped touching entity", e.other)
end)
```

| Field          | Type                                           | Description                   |
| -------------- | ---------------------------------------------- | ----------------------------- |
| `other`        | `integer`                                      | Entity ID of the other body   |
| `shape`        | [`Shape`](https://love2d.org/wiki/Shape)       | Our shape                     |
| `otherShape`   | [`Shape`](https://love2d.org/wiki/Shape)       | Their shape                   |
| `contact`      | [`Contact`](https://love2d.org/wiki/Contact)   | Box2D contact object          |
| `normalX`      | `number`                                       | Collision normal X            |
| `normalY`      | `number`                                       | Collision normal Y            |

## physics.PreSolve

Emitted before collision response is calculated. Use this to disable contacts conditionally.

```teal
world:observe(id, physics.PreSolve, function(e: physics.PreSolve)
    -- One-way platform: allow passing through from below
    local _, ny = e.contact:getNormal()
    if ny > 0 then
        e.contact:setEnabled(false)
    end
end)
```

| Field          | Type                                           | Description                   |
| -------------- | ---------------------------------------------- | ----------------------------- |
| `other`        | `integer`                                      | Entity ID of the other body   |
| `shape`        | [`Shape`](https://love2d.org/wiki/Shape)       | Our shape                     |
| `otherShape`   | [`Shape`](https://love2d.org/wiki/Shape)       | Their shape                   |
| `contact`      | [`Contact`](https://love2d.org/wiki/Contact)   | Box2D contact object          |

*See [Contact:setEnabled](https://love2d.org/wiki/Contact:setEnabled) for disabling contacts.*

## physics.PostSolve

Emitted after collision response with impulse data. Use this for damage calculations or sound effects based on impact
strength.

```teal
world:observe(id, physics.PostSolve, function(e: physics.PostSolve)
    if e.normalImpulse > 100 then
        print("Hard impact!", e.normalImpulse)
    end
end)
```

| Field              | Type                                           | Description                       |
| ------------------ | ---------------------------------------------- | --------------------------------- |
| `other`            | `integer`                                      | Entity ID of the other body       |
| `shape`            | [`Shape`](https://love2d.org/wiki/Shape)       | Our shape                         |
| `otherShape`       | [`Shape`](https://love2d.org/wiki/Shape)       | Their shape                       |
| `contact`          | [`Contact`](https://love2d.org/wiki/Contact)   | Box2D contact object              |
| `normalImpulse`    | `number`                                       | Impulse along collision normal    |
| `tangentImpulse`   | `number`                                       | Impulse along collision tangent   |

## Collision Filtering

### Category Bitmasks

Use `physics.categories()` to create bitmasks, and set `categories` and `mask` on Colliders to control which objects
collide:

```teal
local PLAYER = physics.categories(1)
local ENEMY = physics.categories(2)
local PROJECTILE = physics.categories(3)

-- Player collides with enemies but not own projectiles
world:spawn(
    Transform(100, 100),
    physics.Collider({
        shape = "circle",
        radius = 16,
        categories = PLAYER,
        mask = ENEMY
    }),
    physics.RigidBody({ mass = 1 })
)
```

*See [Shape:setFilterData](https://love2d.org/wiki/Shape:setFilterData) for more on collision filtering.*

### Layer-Based Filtering

The default contact filter rejects collisions between entities on different `Transform.layer` values. Two entities
will only collide if they share the same layer. This works alongside category/mask filtering.

To override this behavior, provide a custom `contactFilter` in the [plugin config](./index#plugin-configuration).
The filter receives both Box2D shapes and their associated `ShapeData`, and returns `true` to allow the collision
or `false` to reject it:

```teal
world:addPlugin(physics.new({
    world = physicsWorld,
    contactFilter = function(
        shapeA: love.physics.Shape,
        shapeB: love.physics.Shape,
        dataA: physics.ShapeData,
        dataB: physics.ShapeData
    ): boolean
        -- ShapeData fields:
        --   .entity     (integer)  entity ID
        --   .layer      (integer)  Transform layer
        --   .categories (integer)  collision category bits
        --   .mask       (integer)  collision mask bits
        --   .name       (string)   shape name

        -- Example: only collide if on the same layer
        return dataA.layer == dataB.layer
    end
}))
```
