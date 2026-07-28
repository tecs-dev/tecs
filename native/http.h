/* Native buffers for the HTTP client.
 *
 * libcurl invokes write and header callbacks while curl_multi_perform is
 * running. Those callbacks have to be C: entering a Lua function through an
 * ffi.cast callback from a compiled trace is not supported by LuaJIT. Lua owns
 * the multi handle and drains it; this bridge owns only the bytes callbacks
 * append while that happens.
 *
 * The cdef the FFI uses is generated from this header, so the declarations and
 * the implementation cannot drift.
 */

#ifndef TECS_HTTP_H
#define TECS_HTTP_H

#include <stddef.h>
#include <stdint.h>

typedef struct TecsHttpResponseBuffer TecsHttpResponseBuffer;

enum TecsHttpBufferError {
    TECS_HTTP_BUFFER_OK = 0,
    TECS_HTTP_BUFFER_BODY_LIMIT = 1,
    TECS_HTTP_BUFFER_HEADER_LIMIT = 2,
    TECS_HTTP_BUFFER_OOM = 3
};

TecsHttpResponseBuffer *tecsHttpResponseBufferCreate(uint64_t maxBodyBytes, uint64_t maxHeaderBytes);
void tecsHttpResponseBufferDestroy(TecsHttpResponseBuffer *buffer);

size_t tecsHttpWriteCallback(char *data, size_t size, size_t count, void *userdata);
size_t tecsHttpHeaderCallback(char *data, size_t size, size_t count, void *userdata);

const uint8_t *tecsHttpResponseBody(const TecsHttpResponseBuffer *buffer, uint64_t *size);
const uint8_t *tecsHttpResponseHeaders(const TecsHttpResponseBuffer *buffer, uint64_t *size);
int tecsHttpResponseBufferError(const TecsHttpResponseBuffer *buffer);

/* Drops the first `count` buffered body bytes, for a caller writing them
 * somewhere as they arrive.
 *
 * Without this a body bound for a file is still a whole body in memory, just
 * in this allocation rather than in Lua's. A caller that reads what
 * tecsHttpResponseBody points at and then consumes it holds one pump's worth
 * of arrival instead of the transfer.
 *
 * The limit is unaffected: what has been consumed still counts against
 * maxBodyBytes, so a ceiling means the same thing whether or not anything is
 * draining. Answers how many bytes remain buffered.
 */
uint64_t tecsHttpResponseBodyConsume(TecsHttpResponseBuffer *buffer, uint64_t count);

#endif
