/* Worker threads and channels. See worker.c for why this is native.
 *
 * The cdef the FFI uses is generated from this header, so the two cannot
 * drift: `make abi-check` compares the generated record layouts against what
 * the C compiler produces.
 */

#ifndef TECS2D_WORKER_H
#define TECS2D_WORKER_H

#include <stdbool.h>
#include <stdint.h>

typedef struct Tecs2dChannel Tecs2dChannel;
typedef struct Tecs2dWorker Tecs2dWorker;

Tecs2dChannel *tecs2dChannelCreate(void);
void tecs2dChannelDestroy(Tecs2dChannel *channel);
void tecs2dChannelClose(Tecs2dChannel *channel);
bool tecs2dChannelPush(Tecs2dChannel *channel, const void *data, uint32_t size);
uint32_t tecs2dChannelPop(Tecs2dChannel *channel, void **out, int32_t timeoutMs);
void *tecs2dChannelData(void *message);
void tecs2dChannelFree(void *message);
uint32_t tecs2dChannelCount(Tecs2dChannel *channel);

Tecs2dWorker *tecs2dWorkerSpawn(const char *source, const char *luaPath,
                                Tecs2dChannel *toWorker,
                                Tecs2dChannel *fromWorker);
int tecs2dWorkerJoin(Tecs2dWorker *worker);

#endif
