/* Worker threads and channels. See worker.c for why this is native.
 *
 * The cdef the FFI uses is generated from this header, so the two cannot
 * drift: `cargo xtask abi-check` compares the generated record layouts against what
 * the C compiler produces.
 */

#ifndef TECS_WORKER_H
#define TECS_WORKER_H

#include <stdbool.h>
#include <stdint.h>

typedef struct TecsChannel TecsChannel;
typedef struct TecsWorker TecsWorker;

TecsChannel *tecsChannelCreate(void);
void tecsChannelDestroy(TecsChannel *channel);
void tecsChannelClose(TecsChannel *channel);
bool tecsChannelPush(TecsChannel *channel, const void *data, uint32_t size);
uint32_t tecsChannelPop(TecsChannel *channel, void **out, int32_t timeoutMs);
void *tecsChannelData(void *message);
void tecsChannelFree(void *message);
uint32_t tecsChannelCount(TecsChannel *channel);

TecsWorker *tecsWorkerSpawn(const char *source, const char *luaPath, TecsChannel *toWorker, TecsChannel *fromWorker);
int tecsWorkerJoin(TecsWorker *worker);

#endif
