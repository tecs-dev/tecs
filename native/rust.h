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
typedef struct TecsAsyncFileRequest TecsAsyncFileRequest;
typedef struct TecsImageDecodeRequest TecsImageDecodeRequest;
typedef struct TecsTemporaryPath TecsTemporaryPath;
typedef struct TecsWindowHitRegions TecsWindowHitRegions;
typedef struct TecsMcpServer TecsMcpServer;
typedef struct TecsMcpRequest TecsMcpRequest;
typedef struct TecsNetAddress TecsNetAddress;
typedef struct TecsNetOperation TecsNetOperation;
typedef struct TecsNetReactor TecsNetReactor;
typedef struct TecsNetStream TecsNetStream;
typedef struct TecsNetServer TecsNetServer;
typedef struct TecsNetDatagram TecsNetDatagram;
typedef struct TecsNetPacket TecsNetPacket;
typedef struct TecsNoise TecsNoise;
typedef struct TecsRegex TecsRegex;
typedef struct TecsUiTree TecsUiTree;
typedef struct TecsUri TecsUri;
typedef struct TecsShader TecsShader;
typedef struct TecsModel TecsModel;

typedef struct TecsShaderDefine {
    const uint8_t *name;
    size_t name_length;
    const uint8_t *value;
    size_t value_length;
} TecsShaderDefine;

typedef struct TecsShaderInfo {
    const uint8_t *code;
    size_t code_length;
    const char *entrypoint;
    uint32_t samplers;
    uint32_t read_only_storage_textures;
    uint32_t read_only_storage_buffers;
    uint32_t read_write_storage_textures;
    uint32_t read_write_storage_buffers;
    uint32_t uniform_buffers;
    uint32_t thread_count_x;
    uint32_t thread_count_y;
    uint32_t thread_count_z;
} TecsShaderInfo;

/* Immutable glTF import. Every pointer in the flat view remains valid until
 * the opaque model owner is destroyed. Large geometry and image payloads are
 * borrowed directly rather than serialized through a Lua worker channel. */
typedef struct TecsModelMesh {
    const uint8_t *name;
    size_t name_length;
    const float *vertices;
    size_t vertex_count;
    const float *color_vertices;
    const uint32_t *indices;
    size_t index_count;
    const float *skin_vertices;
    const float *morph_vertices;
    size_t morph_target_count;
    const float *morph_weights;
    size_t morph_weight_count;
    float center_x;
    float center_y;
    float center_z;
    float radius;
} TecsModelMesh;

typedef struct TecsModelImage {
    const uint8_t *name;
    size_t name_length;
    const uint8_t *bytes;
    size_t byte_count;
} TecsModelImage;

typedef struct TecsModelMaterial {
    const uint8_t *name;
    size_t name_length;
    uint32_t model;
    uint32_t alpha_mode;
    uint32_t base_color_image;
    uint32_t normal_image;
    uint32_t metallic_roughness_image;
    uint32_t occlusion_image;
    uint32_t emissive_image;
    float alpha_cutoff;
    float base_r;
    float base_g;
    float base_b;
    float base_a;
    float emissive_r;
    float emissive_g;
    float emissive_b;
    float metallic;
    float roughness;
    float normal_scale;
    float occlusion_strength;
    uint8_t double_sided;
    uint8_t _padding[3];
} TecsModelMaterial;

typedef struct TecsModelDraw {
    uint32_t mesh;
    uint32_t material;
    uint32_t skin;
    uint32_t node;
    const float *weights;
    size_t weight_count;
    float x;
    float y;
    float z;
    float rotation_x;
    float rotation_y;
    float rotation_z;
    float rotation_w;
    float scale_x;
    float scale_y;
    float scale_z;
} TecsModelDraw;

typedef struct TecsModelSkin {
    const uint8_t *name;
    size_t name_length;
    const float *matrices;
    size_t matrix_count;
    uint32_t node;
    const uint32_t *joints;
    size_t joint_count;
    const float *inverse_bind_matrices;
    size_t inverse_bind_matrix_count;
} TecsModelSkin;

typedef struct TecsModelNode {
    uint32_t parent;
    float x;
    float y;
    float z;
    float rotation_x;
    float rotation_y;
    float rotation_z;
    float rotation_w;
    float scale_x;
    float scale_y;
    float scale_z;
    uint8_t has_matrix;
    uint8_t _padding[3];
    float matrix[16];
} TecsModelNode;

typedef struct TecsModelAnimation {
    const uint8_t *name;
    size_t name_length;
    float duration;
    size_t first_channel;
    size_t channel_count;
} TecsModelAnimation;

typedef struct TecsModelAnimationChannel {
    uint32_t node;
    uint32_t path;
    uint32_t interpolation;
    uint32_t width;
    const float *times;
    size_t time_count;
    const float *values;
    size_t value_count;
} TecsModelAnimationChannel;

typedef struct TecsModelInfo {
    const uint8_t *path;
    size_t path_length;
    uint8_t mipmaps;
    uint8_t _padding[7];
    const TecsModelMesh *meshes;
    size_t mesh_count;
    const TecsModelImage *images;
    size_t image_count;
    const TecsModelMaterial *materials;
    size_t material_count;
    const TecsModelDraw *draws;
    size_t draw_count;
    const TecsModelSkin *skins;
    size_t skin_count;
    const TecsModelNode *nodes;
    size_t node_count;
    const TecsModelAnimation *animations;
    size_t animation_count;
    const TecsModelAnimationChannel *channels;
    size_t channel_count;
} TecsModelInfo;

/* Taffy-backed retained UI layout. An entity id is the tree key, so Lua keeps
 * ownership of the ECS hierarchy and Rust owns only the derived layout cache.
 * A dimension value uses its accompanying unit: 0 auto, 1 points, 2 percent.
 */
typedef struct TecsUiDimension {
    float value;
    uint8_t unit;
    uint8_t _padding[3];
} TecsUiDimension;

typedef struct TecsUiEdges {
    TecsUiDimension left;
    TecsUiDimension right;
    TecsUiDimension top;
    TecsUiDimension bottom;
} TecsUiEdges;

typedef struct TecsUiStyle {
    uint8_t display;
    uint8_t position;
    uint8_t flex_direction;
    uint8_t flex_wrap;
    uint8_t justify_content;
    uint8_t align_items;
    uint8_t align_content;
    uint8_t _padding0;
    float flex_grow;
    float flex_shrink;
    TecsUiDimension flex_basis;
    TecsUiDimension width;
    TecsUiDimension height;
    TecsUiDimension min_width;
    TecsUiDimension min_height;
    TecsUiDimension max_width;
    TecsUiDimension max_height;
    TecsUiEdges margin;
    TecsUiEdges padding;
    TecsUiEdges border;
    TecsUiDimension gap_width;
    TecsUiDimension gap_height;
    TecsUiEdges inset;
} TecsUiStyle;

typedef struct TecsUiLayout {
    float x;
    float y;
    float width;
    float height;
    uint8_t changed;
    uint8_t _padding[3];
} TecsUiLayout;

typedef struct TecsUiLayoutChange {
    uint64_t entity;
    float x;
    float y;
    float width;
    float height;
    float content_width;
    float content_height;
} TecsUiLayoutChange;

typedef struct TecsUiMeasure {
    uint8_t kind;
    uint8_t _padding[3];
    float width;
    float height;
    float min_width;
    float measured_width;
    float measured_height;
} TecsUiMeasure;

typedef struct TecsRegexSpan {
    size_t start;
    size_t end;
    bool matched;
} TecsRegexSpan;

/* Cargo-owned GLSL compilation. Stage is 0 vertex, 1 fragment, or 2 compute.
 * Target is 0 SPIR-V or 1 Metal Shading Language. */
bool tecsShaderCompilerAvailable(void);
TecsShader *tecsShaderCompile(const uint8_t *source, size_t source_length, const uint8_t *name, size_t name_length,
                              uint32_t stage, uint32_t target, const TecsShaderDefine *defines, size_t define_count);
bool tecsShaderGetInfo(const TecsShader *shader, TecsShaderInfo *info);
void tecsShaderDestroy(TecsShader *shader);

TecsModel *tecsModelLoad(const uint8_t *path, size_t path_length);
bool tecsModelGetInfo(const TecsModel *model, TecsModelInfo *info);
void tecsModelDestroy(TecsModel *model);

typedef struct TecsStringView {
    const uint8_t *data;
    size_t length;
} TecsStringView;

typedef struct TecsWindowHitRegion {
    int32_t x;
    int32_t y;
    int32_t width;
    int32_t height;
    int32_t result;
} TecsWindowHitRegion;

typedef struct SDL_Window SDL_Window;

const char *tecsRustError(void);
int tecsHostEventBatchAcknowledge(void *host, uint64_t token);

/* Immutable procedural noise fields. Algorithm and fractal values are private
 * discriminants selected by the tecs.math.noise binding. */
TecsNoise *tecsNoiseCreate(int32_t seed, uint8_t algorithm, uint8_t fractal, float frequency, int32_t octaves,
                           float lacunarity, float gain, float weighted_strength, float ping_pong_strength);
void tecsNoiseDestroy(TecsNoise *noise);
float tecsNoiseSample2(const TecsNoise *noise, double x, double y);
float tecsNoiseSample3(const TecsNoise *noise, double x, double y, double z);
bool tecsNoiseFill2(const TecsNoise *noise, float *output, size_t width, size_t height, double origin_x,
                    double origin_y, double step_x, double step_y);

/* Immutable absolute URIs. Every borrowed component remains valid until the
 * parsed value is destroyed. Modifier functions return a new parsed value. */
TecsUri *tecsUriParse(const uint8_t *text, size_t length);
const uint8_t *tecsUriText(const TecsUri *uri, size_t *length);
const uint8_t *tecsUriScheme(const TecsUri *uri, size_t *length);
const uint8_t *tecsUriAuthority(const TecsUri *uri, size_t *length);
const uint8_t *tecsUriUsername(const TecsUri *uri, size_t *length);
const uint8_t *tecsUriPassword(const TecsUri *uri, size_t *length);
const uint8_t *tecsUriHost(const TecsUri *uri, size_t *length);
int tecsUriPort(const TecsUri *uri, uint16_t *port);
const uint8_t *tecsUriPath(const TecsUri *uri, size_t *length);
const uint8_t *tecsUriQuery(const TecsUri *uri, size_t *length);
const uint8_t *tecsUriFragment(const TecsUri *uri, size_t *length);
TecsUri *tecsUriWithText(const TecsUri *uri, uint32_t kind, const uint8_t *value, size_t value_length, int present);
TecsUri *tecsUriWithPort(const TecsUri *uri, int32_t port);
TecsUri *tecsUriConcatPath(const TecsUri *uri, const uint8_t *suffix, size_t suffix_length);
TecsUri *tecsUriResolve(const TecsUri *uri, const uint8_t *reference, size_t reference_length);
TecsUri *tecsUriWithEndpoint(const TecsUri *uri, const TecsUri *endpoint);
void tecsUriDestroy(TecsUri *uri);

TecsUiTree *tecsUiTreeCreate(void);
void tecsUiTreeDestroy(TecsUiTree *tree);
bool tecsUiTreeInsert(TecsUiTree *tree, uint64_t entity, const TecsUiStyle *style);
bool tecsUiTreeRemove(TecsUiTree *tree, uint64_t entity);
bool tecsUiTreeSetStyle(TecsUiTree *tree, uint64_t entity, const TecsUiStyle *style);
bool tecsUiTreeSetMeasure(TecsUiTree *tree, uint64_t entity, const TecsUiMeasure *measure);
bool tecsUiTreeSetChildren(TecsUiTree *tree, uint64_t entity, const uint64_t *children, size_t count);
bool tecsUiTreeInvalidateRoot(TecsUiTree *tree, uint64_t entity);
bool tecsUiTreeBegin(TecsUiTree *tree);
bool tecsUiTreeCompute(TecsUiTree *tree, uint64_t root, float width, float height);
bool tecsUiTreeLayout(const TecsUiTree *tree, uint64_t entity, TecsUiLayout *layout);
const TecsUiLayoutChange *tecsUiTreeChanges(const TecsUiTree *tree, size_t *count);

/* RFC 9562 UUIDs. Each output holds 36 lowercase characters and a NUL. */
bool tecsUuid4(char output[37]);
bool tecsUuid7(char output[37]);

/* SHA-256 as 64 lowercase hexadecimal characters and a NUL. */
bool tecsSha256(const uint8_t *bytes, size_t length, char output[65]);

TecsBytes *tecsCliHelp(void);
TecsBytes *tecsCliParse(size_t count, const char *const *arguments);
TecsBytes *tecsCliDocs(const char *directory, const char *query);
int tecsCliMcp(void);

TecsBytes *tecsSystemCachePath(const uint8_t *organization, size_t organization_length, const uint8_t *application,
                               size_t application_length);
int tecsPathIsSymlink(const uint8_t *path, size_t path_length);
bool tecsPathValidate(const uint8_t *path, size_t path_length);
TecsBytes *tecsPathJoin(const TecsStringView *parts, size_t count);
TecsBytes *tecsPathNormalize(const uint8_t *path, size_t path_length);
TecsBytes *tecsPathAbsolute(const uint8_t *path, size_t path_length);
TecsBytes *tecsPathCanonicalize(const uint8_t *path, size_t path_length);
TecsBytes *tecsPathRelative(const uint8_t *path, size_t path_length, const uint8_t *base, size_t base_length);
TecsBytes *tecsPathParent(const uint8_t *path, size_t path_length);
TecsBytes *tecsPathFileName(const uint8_t *path, size_t path_length);
TecsBytes *tecsPathStem(const uint8_t *path, size_t path_length);
TecsBytes *tecsPathExtension(const uint8_t *path, size_t path_length);
TecsBytes *tecsPathWithFileName(const uint8_t *path, size_t path_length, const uint8_t *name, size_t name_length);
TecsBytes *tecsPathWithExtension(const uint8_t *path, size_t path_length, const uint8_t *extension,
                                 size_t extension_length);
bool tecsPathIsAbsolute(const uint8_t *path, size_t path_length);
TecsBytes *tecsPathReadLink(const uint8_t *path, size_t path_length);
bool tecsPathCreateSymlink(const uint8_t *target, size_t target_length, const uint8_t *link, size_t link_length,
                           bool directory);
int tecsPathIsReadOnly(const uint8_t *path, size_t path_length);
bool tecsPathSetReadOnly(const uint8_t *path, size_t path_length, bool read_only);
bool tecsFileWriteAtomic(const uint8_t *path, size_t path_length, const uint8_t *bytes, size_t length);
TecsTemporaryPath *tecsTemporaryFileCreate(const uint8_t *directory, size_t directory_length, const uint8_t *prefix,
                                           size_t prefix_length, const uint8_t *suffix, size_t suffix_length);
TecsTemporaryPath *tecsTemporaryDirectoryCreate(const uint8_t *directory, size_t directory_length,
                                                const uint8_t *prefix, size_t prefix_length, const uint8_t *suffix,
                                                size_t suffix_length);
TecsBytes *tecsTemporaryPathGet(const TecsTemporaryPath *temporary);
bool tecsTemporaryPathPersist(TecsTemporaryPath *temporary, const uint8_t *destination, size_t destination_length);
bool tecsTemporaryPathClose(TecsTemporaryPath *temporary);
void tecsTemporaryPathDestroy(TecsTemporaryPath *temporary);

bool tecsSignalsInstall(void);
uint32_t tecsSignalsPoll(void);
void tecsSignalsUninstall(void);

TecsImage *tecsImageDecode(const uint8_t *bytes, size_t length);
const uint8_t *tecsImagePixels(const TecsImage *image);
uint32_t tecsImageWidth(const TecsImage *image);
uint32_t tecsImageHeight(const TecsImage *image);
void tecsImageDestroy(TecsImage *image);

TecsBytes *tecsImageEncodePngRgbx(const uint8_t *pixels, size_t length, uint32_t width, uint32_t height, size_t pitch);
const uint8_t *tecsBytesData(const TecsBytes *bytes);
size_t tecsBytesLength(const TecsBytes *bytes);
void tecsBytesDestroy(TecsBytes *bytes);

/* Finite regular-file transfers. Opening and metadata run on a bounded
 * blocking lane; bytes move through one process SDL_AsyncIO queue. A write
 * borrows `bytes` until its request settles or shutdown completes. */
TecsAsyncFileRequest *tecsAsyncFileRead(const uint8_t *path, size_t pathLength);
TecsAsyncFileRequest *tecsAsyncFileWrite(const uint8_t *path, size_t pathLength, const uint8_t *bytes, size_t length,
                                         int flush);
uint32_t tecsAsyncFilePoll(void);
uint32_t tecsAsyncFileWait(uint32_t waitMs);
int tecsAsyncFileStatus(const TecsAsyncFileRequest *request);
const uint8_t *tecsAsyncFileData(const TecsAsyncFileRequest *request);
size_t tecsAsyncFileLength(const TecsAsyncFileRequest *request);
const char *tecsAsyncFileError(const TecsAsyncFileRequest *request);
TecsBytes *tecsAsyncFileTakeBytes(TecsAsyncFileRequest *request);
void tecsAsyncFileDestroy(TecsAsyncFileRequest *request);
void tecsAsyncFileShutdown(void);

/* CPU image decoding uses a bounded pool separate from file-open workers. The
 * start call consumes bytes whether or not the job can be accepted. */
TecsImageDecodeRequest *tecsImageDecodeStart(TecsBytes *bytes);
int tecsImageDecodeStatus(const TecsImageDecodeRequest *request);
uint32_t tecsImageDecodeWait(TecsImageDecodeRequest *request, uint32_t waitMs);
const char *tecsImageDecodeError(const TecsImageDecodeRequest *request);
TecsImage *tecsImageDecodeTake(TecsImageDecodeRequest *request);
void tecsImageDecodeRequestDestroy(TecsImageDecodeRequest *request);

/* Declarative window hit testing. SDL retains this callback, so Rust owns it
 * and the copied region list instead of allowing SDL to enter Lua. */
TecsWindowHitRegions *tecsWindowHitRegionsCreate(SDL_Window *window, const TecsWindowHitRegion *regions, size_t count);
bool tecsWindowHitRegionsUpdate(TecsWindowHitRegions *state, const TecsWindowHitRegion *regions, size_t count);
bool tecsWindowHitRegionsClear(SDL_Window *window, TecsWindowHitRegions *state);
void tecsWindowHitRegionsDestroy(TecsWindowHitRegions *state);

/* Streamable HTTP MCP. Rust owns HTTP and the protocol; Lua drains only tool
 * calls from the SDL thread and submits their completed results. */
TecsMcpServer *tecsMcpServerCreate(uint16_t port, const uint8_t *tools, size_t tools_length);
bool tecsMcpServerSetTools(TecsMcpServer *server, const uint8_t *tools, size_t tools_length);
TecsMcpRequest *tecsMcpServerNext(TecsMcpServer *server);
const uint8_t *tecsMcpRequestName(const TecsMcpRequest *request, size_t *length);
const uint8_t *tecsMcpRequestArguments(const TecsMcpRequest *request, size_t *length);
void tecsMcpRequestRespond(TecsMcpRequest *request, const uint8_t *result, size_t result_length, bool is_error,
                           bool crashed);
void tecsMcpRequestDestroy(TecsMcpRequest *request);
void tecsMcpServerDestroy(TecsMcpServer *server);

/* Nonblocking TCP and UDP. DNS resolution and client connection complete on
 * Rust-owned workers; Lua polls their opaque operations from the SDL thread. */

TecsNetOperation *tecsNetResolve(const uint8_t *host, size_t length);
TecsNetOperation *tecsNetConnect(const TecsNetAddress *address, uint16_t port);
int tecsNetOperationStatus(TecsNetOperation *operation, uint32_t waitMs);
TecsNetAddress *tecsNetOperationTakeAddress(TecsNetOperation *operation);
TecsNetStream *tecsNetOperationTakeStream(TecsNetOperation *operation);
void tecsNetOperationDestroy(TecsNetOperation *operation);

const uint8_t *tecsNetAddressText(const TecsNetAddress *address, size_t *length);
TecsNetAddress *tecsNetAddressClone(const TecsNetAddress *address);
void tecsNetAddressDestroy(TecsNetAddress *address);

/* A reactor watch is one-shot. Poll removes a ready endpoint before queueing
 * its token, so the caller drains the operation and explicitly watches again
 * only after it reaches would-block. Interest uses bit 1 for readable and bit
 * 2 for writable. Readiness adds bit 4 for an error and bit 8 for closure. */
TecsNetReactor *tecsNetReactorCreate(void);
int tecsNetReactorWatch(TecsNetReactor *reactor, TecsNetStream *stream, uint32_t token, uint32_t interest);
int tecsNetReactorUnwatch(TecsNetReactor *reactor, TecsNetStream *stream, uint32_t token);
int tecsNetReactorWatchServer(TecsNetReactor *reactor, TecsNetServer *server, uint32_t token, uint32_t interest);
int tecsNetReactorUnwatchServer(TecsNetReactor *reactor, TecsNetServer *server, uint32_t token);
int tecsNetReactorWatchDatagram(TecsNetReactor *reactor, TecsNetDatagram *socket, uint32_t token, uint32_t interest);
int tecsNetReactorUnwatchDatagram(TecsNetReactor *reactor, TecsNetDatagram *socket, uint32_t token);
int tecsNetReactorPoll(TecsNetReactor *reactor, uint32_t timeoutMs);
int tecsNetReactorNext(TecsNetReactor *reactor, uint32_t *token, uint32_t *readiness);
void tecsNetReactorDestroy(TecsNetReactor *reactor);

TecsNetServer *tecsNetListen(const TecsNetAddress *address, uint16_t port);
TecsNetStream *tecsNetServerAccept(TecsNetServer *server);
int tecsNetServerWait(TecsNetServer *server, uint32_t timeoutMs);
void tecsNetServerDestroy(TecsNetServer *server);

TecsNetAddress *tecsNetStreamPeer(const TecsNetStream *stream);
int64_t tecsNetStreamRead(TecsNetStream *stream, uint8_t *bytes, size_t length);
int tecsNetStreamWrite(TecsNetStream *stream, const uint8_t *bytes, size_t length);
int64_t tecsNetStreamPendingWrites(TecsNetStream *stream);
int tecsNetStreamDrain(TecsNetStream *stream, uint32_t timeoutMs);
int tecsNetStreamWait(TecsNetStream *stream, uint32_t timeoutMs);
void tecsNetStreamDestroy(TecsNetStream *stream);

TecsNetDatagram *tecsNetDatagramBind(const TecsNetAddress *address, uint16_t port);
int tecsNetDatagramSend(TecsNetDatagram *socket, const TecsNetAddress *address, uint16_t port, const uint8_t *bytes,
                        size_t length);
int tecsNetDatagramSendWait(TecsNetDatagram *socket, const TecsNetAddress *address, uint16_t port, const uint8_t *bytes,
                            size_t length, uint32_t timeoutMs);
TecsNetPacket *tecsNetDatagramReceive(TecsNetDatagram *socket);
int tecsNetDatagramWait(TecsNetDatagram *socket, uint32_t timeoutMs);
void tecsNetDatagramDestroy(TecsNetDatagram *socket);
TecsNetAddress *tecsNetPacketTakeAddress(TecsNetPacket *packet);
uint16_t tecsNetPacketPort(const TecsNetPacket *packet);
const uint8_t *tecsNetPacketBytes(const TecsNetPacket *packet, size_t *length);
void tecsNetPacketDestroy(TecsNetPacket *packet);

/* Compiled byte-string regular expressions. Patterns are UTF-8 Rust regex
 * syntax; subjects are arbitrary Lua strings, and every span is a zero-based,
 * end-exclusive byte range. */

TecsRegex *tecsRegexCompile(const uint8_t *pattern, size_t length);
size_t tecsRegexCaptureCount(const TecsRegex *regex);
const uint8_t *tecsRegexCaptureName(const TecsRegex *regex, size_t index, size_t *length);
bool tecsRegexIsMatch(const TecsRegex *regex, const uint8_t *subject, size_t length);
bool tecsRegexFind(const TecsRegex *regex, const uint8_t *subject, size_t length, size_t start, TecsRegexSpan *span);
bool tecsRegexCaptures(const TecsRegex *regex, const uint8_t *subject, size_t length, size_t start,
                       TecsRegexSpan *spans, size_t count);
TecsBytes *tecsRegexReplace(const TecsRegex *regex, const uint8_t *subject, size_t length, const uint8_t *replacement,
                            size_t replacement_length, size_t limit);
void tecsRegexDestroy(TecsRegex *regex);

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
    uint8_t started;
    uint8_t sensor;
    uint8_t _padding[6];
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
