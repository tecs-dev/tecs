/* Rust-owned native services exposed through a C ABI.
 *
 * LuaJIT binds this header, so declarations stay within the C subset its FFI
 * parser accepts. Allocations are opaque and are always released by the Rust
 * function paired with the one that created them.
 */

#ifndef TECS_RUST_H
#define TECS_RUST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct TecsImage TecsImage;
typedef struct TecsBytes TecsBytes;

const char *tecsRustError(void);

TecsBytes *tecsCliHelp(void);
TecsBytes *tecsCliParse(size_t count, const char *const *arguments);

TecsImage *tecsImageDecode(const uint8_t *bytes, size_t length);
const uint8_t *tecsImagePixels(const TecsImage *image);
uint32_t tecsImageWidth(const TecsImage *image);
uint32_t tecsImageHeight(const TecsImage *image);
void tecsImageDestroy(TecsImage *image);

TecsBytes *tecsImageEncodePngRgbx(const uint8_t *pixels, size_t length, uint32_t width, uint32_t height, size_t pitch);
const uint8_t *tecsBytesData(const TecsBytes *bytes);
size_t tecsBytesLength(const TecsBytes *bytes);
void tecsBytesDestroy(TecsBytes *bytes);

/* Rapier 2D. Every arena handle stays paired with its owning opaque world. */

typedef struct TecsPhysicsWorld TecsPhysicsWorld;
typedef struct TecsPhysicsSnapshot TecsPhysicsSnapshot;

typedef struct TecsPhysicsHandle {
    uint32_t index;
    uint32_t generation;
} TecsPhysicsHandle;

typedef struct TecsPhysicsBodyDef {
    uint8_t kind;
    uint8_t fixed_rotation;
    uint8_t bullet;
    uint8_t sleep_enabled;
    float x;
    float y;
    float angle;
    float gravity_scale;
    float linear_damping;
    float angular_damping;
    uint64_t entity;
} TecsPhysicsBodyDef;

typedef struct TecsPhysicsColliderDef {
    uint8_t shape;
    uint8_t sensor;
    uint8_t _padding[2];
    float half_width;
    float half_height;
    float radius;
    float length;
    float offset_x;
    float offset_y;
    float density;
    float friction;
    float restitution;
    uint32_t category_bits;
    uint32_t mask_bits;
    int32_t group_index;
    uint64_t entity;
} TecsPhysicsColliderDef;

typedef struct TecsPhysicsMove {
    TecsPhysicsHandle body;
    float x;
    float y;
    float cosine;
    float sine;
} TecsPhysicsMove;

typedef struct TecsPhysicsPairEvent {
    uint64_t entity_a;
    uint64_t entity_b;
    float x;
    float y;
    float normal_x;
    float normal_y;
    float approach_speed;
    uint8_t started;
    uint8_t sensor;
    uint8_t hit;
    uint8_t _padding[5];
} TecsPhysicsPairEvent;

typedef struct TecsPhysicsRayHit {
    uint64_t entity;
    float x;
    float y;
    float normal_x;
    float normal_y;
    float fraction;
} TecsPhysicsRayHit;

TecsPhysicsWorld *tecsPhysicsWorldCreate(float gravity_x, float gravity_y, uint32_t substeps, uint32_t worker_count);
uint32_t tecsPhysicsDefaultWorkerCount(void);
void tecsPhysicsWorldDestroy(TecsPhysicsWorld *world);
bool tecsPhysicsWorldStep(TecsPhysicsWorld *world, float dt);

TecsPhysicsHandle tecsPhysicsBodyCreate(TecsPhysicsWorld *world, const TecsPhysicsBodyDef *definition);
TecsPhysicsHandle tecsPhysicsColliderCreate(TecsPhysicsWorld *world, TecsPhysicsHandle body,
                                            const TecsPhysicsColliderDef *definition);
bool tecsPhysicsBodyIsValid(const TecsPhysicsWorld *world, TecsPhysicsHandle body);
bool tecsPhysicsColliderIsValid(const TecsPhysicsWorld *world, TecsPhysicsHandle collider);
void tecsPhysicsBodyDestroy(TecsPhysicsWorld *world, TecsPhysicsHandle body);
void tecsPhysicsColliderDestroy(TecsPhysicsWorld *world, TecsPhysicsHandle collider);
void tecsPhysicsRemoveColliderByEntity(TecsPhysicsWorld *world, TecsPhysicsHandle body, uint64_t entity);
TecsPhysicsHandle tecsPhysicsColliderBody(const TecsPhysicsWorld *world, TecsPhysicsHandle collider);
size_t tecsPhysicsBodyCount(const TecsPhysicsWorld *world);
bool tecsPhysicsBodyByEntity(const TecsPhysicsWorld *world, uint64_t entity, TecsPhysicsHandle *body);
bool tecsPhysicsColliderByEntity(const TecsPhysicsWorld *world, uint64_t entity, TecsPhysicsHandle *collider);

const TecsPhysicsMove *tecsPhysicsMoves(const TecsPhysicsWorld *world, size_t *count);
bool tecsPhysicsBodyPosition(const TecsPhysicsWorld *world, TecsPhysicsHandle body, float *x, float *y, float *angle);
bool tecsPhysicsBodyVelocity(const TecsPhysicsWorld *world, TecsPhysicsHandle body, float *x, float *y, float *angular);
bool tecsPhysicsBodySetVelocity(TecsPhysicsWorld *world, TecsPhysicsHandle body, float x, float y);
bool tecsPhysicsBodySetAngularVelocity(TecsPhysicsWorld *world, TecsPhysicsHandle body, float omega);
bool tecsPhysicsBodyApplyImpulse(TecsPhysicsWorld *world, TecsPhysicsHandle body, float x, float y);
bool tecsPhysicsBodyApplyImpulseAt(TecsPhysicsWorld *world, TecsPhysicsHandle body, float x, float y, float point_x,
                                   float point_y);
bool tecsPhysicsBodyAddForce(TecsPhysicsWorld *world, TecsPhysicsHandle body, float x, float y);
bool tecsPhysicsBodyAddForceAt(TecsPhysicsWorld *world, TecsPhysicsHandle body, float x, float y, float point_x,
                               float point_y);
bool tecsPhysicsBodyAddTorque(TecsPhysicsWorld *world, TecsPhysicsHandle body, float torque);
bool tecsPhysicsBodySetTransform(TecsPhysicsWorld *world, TecsPhysicsHandle body, float x, float y, float angle);
bool tecsPhysicsBodySetAwake(TecsPhysicsWorld *world, TecsPhysicsHandle body, bool awake);
bool tecsPhysicsBodyIsAwake(const TecsPhysicsWorld *world, TecsPhysicsHandle body);
bool tecsPhysicsBodySetEnabled(TecsPhysicsWorld *world, TecsPhysicsHandle body, bool enabled);
bool tecsPhysicsBodySetType(TecsPhysicsWorld *world, TecsPhysicsHandle body, uint8_t kind);
bool tecsPhysicsBodySetProperties(TecsPhysicsWorld *world, TecsPhysicsHandle body, uint8_t kind, float gravity_scale,
                                  float linear_damping, float angular_damping, bool fixed_rotation, bool bullet);
void tecsPhysicsBodyApplyDefinition(TecsPhysicsWorld *world, TecsPhysicsHandle body,
                                    const TecsPhysicsBodyDef *definition);
float tecsPhysicsBodyAngularVelocity(const TecsPhysicsWorld *world, TecsPhysicsHandle body);

bool tecsPhysicsRaycast(const TecsPhysicsWorld *world, float x1, float y1, float x2, float y2, uint32_t category_bits,
                        uint32_t mask_bits, TecsPhysicsRayHit *hit);
const TecsPhysicsPairEvent *tecsPhysicsPairEvents(const TecsPhysicsWorld *world, size_t *count);

TecsPhysicsSnapshot *tecsPhysicsSnapshotCreate(const TecsPhysicsWorld *world);
bool tecsPhysicsSnapshotRestore(TecsPhysicsWorld *world, const uint8_t *bytes, size_t length);
const uint8_t *tecsPhysicsSnapshotData(const TecsPhysicsSnapshot *snapshot);
size_t tecsPhysicsSnapshotLength(const TecsPhysicsSnapshot *snapshot);
void tecsPhysicsSnapshotDestroy(TecsPhysicsSnapshot *snapshot);
uint32_t tecsPhysicsWorkerCount(const TecsPhysicsWorld *world);

#endif
