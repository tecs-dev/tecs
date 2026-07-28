/* libcurl's response callbacks. See http.h for why these are native. */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "http.h"

typedef struct TecsHttpBytes {
    uint8_t *data;
    uint64_t size;
    uint64_t capacity;
    uint64_t limit;
    /* Bytes handed over and dropped, which the limit still counts. */
    uint64_t consumed;
} TecsHttpBytes;

struct TecsHttpResponseBuffer {
    TecsHttpBytes body;
    TecsHttpBytes headers;
    enum TecsHttpBufferError error;
};

static int append(TecsHttpResponseBuffer *buffer, TecsHttpBytes *bytes, const void *data, size_t size,
                  enum TecsHttpBufferError limitError)
{
    uint64_t required;
    uint64_t capacity;
    uint8_t *grown;

    if (buffer == NULL || buffer->error != TECS_HTTP_BUFFER_OK) {
        return 0;
    }
    if ((uint64_t)size > UINT64_MAX - bytes->size) {
        buffer->error = limitError;
        return 0;
    }
    required = bytes->size + (uint64_t)size;
    /* Against everything this body has been, not against what is still held:
     * a ceiling means the same thing whether or not something is draining. */
    if (required > bytes->limit - bytes->consumed) {
        buffer->error = limitError;
        return 0;
    }
    if (required > bytes->capacity) {
        capacity = bytes->capacity == 0 ? 4096 : bytes->capacity;
        while (capacity < required) {
            if (capacity > bytes->limit / 2) {
                capacity = bytes->limit;
                break;
            }
            capacity *= 2;
        }
        grown = (uint8_t *)realloc(bytes->data, (size_t)capacity);
        if (grown == NULL) {
            buffer->error = TECS_HTTP_BUFFER_OOM;
            return 0;
        }
        bytes->data = grown;
        bytes->capacity = capacity;
    }
    if (size != 0) {
        memcpy(bytes->data + bytes->size, data, size);
    }
    bytes->size = required;
    return 1;
}

TecsHttpResponseBuffer *tecsHttpResponseBufferCreate(uint64_t maxBodyBytes, uint64_t maxHeaderBytes)
{
    TecsHttpResponseBuffer *buffer = (TecsHttpResponseBuffer *)calloc(1, sizeof(*buffer));
    if (buffer == NULL) {
        return NULL;
    }
    buffer->body.limit = maxBodyBytes == 0 || maxBodyBytes > SIZE_MAX ? SIZE_MAX : maxBodyBytes;
    buffer->headers.limit = maxHeaderBytes > SIZE_MAX ? SIZE_MAX : maxHeaderBytes;
    return buffer;
}

void tecsHttpResponseBufferDestroy(TecsHttpResponseBuffer *buffer)
{
    if (buffer == NULL) {
        return;
    }
    free(buffer->body.data);
    free(buffer->headers.data);
    free(buffer);
}

size_t tecsHttpWriteCallback(char *data, size_t size, size_t count, void *userdata)
{
    size_t bytes;
    TecsHttpResponseBuffer *buffer = (TecsHttpResponseBuffer *)userdata;

    if (buffer == NULL) {
        return 0;
    }
    if (size != 0 && count > SIZE_MAX / size) {
        buffer->error = TECS_HTTP_BUFFER_BODY_LIMIT;
        return 0;
    }
    bytes = size * count;
    return append(buffer, &buffer->body, data, bytes, TECS_HTTP_BUFFER_BODY_LIMIT) ? bytes : 0;
}

size_t tecsHttpHeaderCallback(char *data, size_t size, size_t count, void *userdata)
{
    size_t bytes;
    TecsHttpResponseBuffer *buffer = (TecsHttpResponseBuffer *)userdata;

    if (buffer == NULL) {
        return 0;
    }
    if (size != 0 && count > SIZE_MAX / size) {
        buffer->error = TECS_HTTP_BUFFER_HEADER_LIMIT;
        return 0;
    }
    bytes = size * count;
    return append(buffer, &buffer->headers, data, bytes, TECS_HTTP_BUFFER_HEADER_LIMIT) ? bytes : 0;
}

const uint8_t *tecsHttpResponseBody(const TecsHttpResponseBuffer *buffer, uint64_t *size)
{
    if (size != NULL) {
        *size = buffer == NULL ? 0 : buffer->body.size;
    }
    return buffer == NULL ? NULL : buffer->body.data;
}

const uint8_t *tecsHttpResponseHeaders(const TecsHttpResponseBuffer *buffer, uint64_t *size)
{
    if (size != NULL) {
        *size = buffer == NULL ? 0 : buffer->headers.size;
    }
    return buffer == NULL ? NULL : buffer->headers.data;
}

uint64_t tecsHttpResponseBodyConsume(TecsHttpResponseBuffer *buffer, uint64_t count)
{
    TecsHttpBytes *bytes;

    if (buffer == NULL) {
        return 0;
    }
    bytes = &buffer->body;
    if (count > bytes->size) {
        count = bytes->size;
    }
    bytes->consumed += count;
    bytes->size -= count;
    if (bytes->size != 0 && count != 0) {
        /* The usual call takes everything, so this moves nothing. It is here
         * for a caller that wrote only part of what had arrived. */
        memmove(bytes->data, bytes->data + count, (size_t)bytes->size);
    }
    /* The capacity stays, so a transfer drained every pump allocates once. */
    return bytes->size;
}

int tecsHttpResponseBufferError(const TecsHttpResponseBuffer *buffer)
{
    /* Answered as `int` rather than as the enum, because the FFI reads a plain
     * integer and an enum's underlying type is the compiler's to choose. Every
     * enumerator is small and non-negative, so the narrowing is exact. */
    return buffer == NULL ? TECS_HTTP_BUFFER_OOM : (int)buffer->error;
}
