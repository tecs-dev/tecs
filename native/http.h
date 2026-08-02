/* Asynchronous HTTP over the Rust runtime.
 *
 * Rust owns reqwest, Tokio, every socket, and the threads that drive them.
 * Lua submits copied request data and drains a bounded event queue from the
 * SDL thread. No Rust worker ever calls Lua, which is the LuaJIT callback rule
 * this boundary exists to enforce.
 *
 * The cdef the FFI uses is generated from this header, so keep it in the C
 * subset LuaJIT parses.
 */

#ifndef TECS_HTTP_H
#define TECS_HTTP_H

#include <stddef.h>
#include <stdint.h>

typedef struct TecsHttpClient TecsHttpClient;
typedef struct TecsHttpEvent TecsHttpEvent;

typedef struct TecsHttpSlice {
    const uint8_t *data;
    size_t length;
} TecsHttpSlice;

typedef struct TecsHttpHeader {
    TecsHttpSlice name;
    TecsHttpSlice value;
} TecsHttpHeader;

typedef struct TecsHttpClientOptions {
    uint64_t connectTimeoutMs;
    uint32_t maxRedirects;
    uint32_t maxConnections;
    uint32_t maxConnectionsPerHost;
    int compressed;
    /* 0 follows the environment, 1 forces a direct connection, and 2 uses
     * proxy. This keeps an unset proxy distinct from an explicitly empty one. */
    int proxyMode;
    TecsHttpSlice proxy;
    int noProxySet;
    TecsHttpSlice noProxy;
    TecsHttpSlice proxyCredentials;
} TecsHttpClientOptions;

typedef struct TecsHttpRequest {
    uint64_t id;
    TecsHttpSlice url;
    TecsHttpSlice method;
    const TecsHttpHeader *headers;
    size_t headerCount;
    TecsHttpSlice body;
    uint32_t bodyKind;
    /* A non-negative upload length, or -1 when the source cannot know it. */
    int64_t bodyLength;
    uint64_t timeoutMs;
    uint64_t stallTimeoutMs;
    uint64_t maxBytes;
    int insecure;
} TecsHttpRequest;

enum TecsHttpBodyKind { TECS_HTTP_BODY_NONE = 0, TECS_HTTP_BODY_INLINE = 1, TECS_HTTP_BODY_UPLOAD = 2 };

enum TecsHttpEventKind {
    TECS_HTTP_EVENT_HEADERS = 1,
    TECS_HTTP_EVENT_CHUNK = 2,
    TECS_HTTP_EVENT_COMPLETE = 3,
    TECS_HTTP_EVENT_FAILED = 4
};

enum TecsHttpUploadResult {
    TECS_HTTP_UPLOAD_CLOSED = -1,
    TECS_HTTP_UPLOAD_BACKPRESSURE = 0,
    TECS_HTTP_UPLOAD_ACCEPTED = 1
};

/* Builds a connection pool and starts the process-wide Tokio runtime on first
 * use. Returns NULL on invalid options or when the runtime cannot start;
 * tecsHttpError() then describes why. */
TecsHttpClient *tecsHttpClientCreate(const TecsHttpClientOptions *options);

/* Stops every request owned by the client and releases its event queue. */
void tecsHttpClientDestroy(TecsHttpClient *client);

/* Copies the request and schedules it. Returns zero only when the request
 * could not be scheduled; tecsHttpError() then describes why. */
int tecsHttpClientSend(TecsHttpClient *client, const TecsHttpRequest *request);

/* Stops a request. Events already drained by Lua remain Lua's to settle or
 * discard; events still in the Rust queue are discarded when polled. */
void tecsHttpClientCancel(TecsHttpClient *client, uint64_t id);

/* Offers one copied request-body chunk of at most 65536 bytes to the bounded
 * upload queue. A full queue returns BACKPRESSURE without copying. Set
 * finished only with an empty slice to close the body. */
int tecsHttpClientUpload(TecsHttpClient *client, uint64_t id, const uint8_t *data, size_t length, int finished);

/* Answers the next event, waiting for at most waitMs. A zero wait never
 * blocks. The event and every pointer borrowed from it stay valid until
 * tecsHttpEventDestroy(). */
TecsHttpEvent *tecsHttpClientNext(TecsHttpClient *client, uint32_t waitMs);

uint32_t tecsHttpEventKind(const TecsHttpEvent *event);
uint64_t tecsHttpEventId(const TecsHttpEvent *event);
uint16_t tecsHttpEventStatus(const TecsHttpEvent *event);
const uint8_t *tecsHttpEventData(const TecsHttpEvent *event, size_t *length);
const uint8_t *tecsHttpEventHeaders(const TecsHttpEvent *event, size_t *length);
const uint8_t *tecsHttpEventUrl(const TecsHttpEvent *event, size_t *length);
const uint8_t *tecsHttpEventError(const TecsHttpEvent *event, size_t *length);
void tecsHttpEventDestroy(TecsHttpEvent *event);

/* The last synchronous HTTP boundary error on the calling thread. The pointer
 * remains valid until the next such error on this thread. */
const char *tecsHttpError(void);

#endif
