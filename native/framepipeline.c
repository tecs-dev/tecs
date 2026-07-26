/* The frame coordinator between the thread that simulates and the thread that
 * owns the window.
 *
 * This is native because the two threads share nothing else. LuaJIT gives each
 * thread its own state with no mutable heap between them, so the mutex, the
 * condition variables and the packets themselves have to live outside every
 * lua_State, and a thread parked in a condition wait cannot be expressed in
 * Lua at all.
 *
 * The shape is two slots behind one lock. A slot is FREE, the producer takes it
 * and fills it, publishing flips it to READY with the next frame sequence
 * number, the consumer takes the oldest READY slot, and releasing it returns it
 * to FREE. What a packet contains is not this file's business: the caller sizes
 * the payload at creation, the pipeline hands out its address, and nothing here
 * reads a byte of it.
 *
 * Publication is atomic with respect to the consumer because a slot is only
 * ever observed under the lock. The sequence number and the flip to READY are
 * written in one critical section, and the consumer's only way to reach a slot
 * is to find it READY in a critical section of its own. Releasing the lock
 * publishes the producer's payload writes to the thread that acquires it next,
 * so the consumer sees either a slot it must wait for or a slot that is
 * complete. There is no third case to observe.
 *
 * Depth is one frame. The producer may hold a slot while a published packet is
 * waiting, so it can build frame N+1 while the consumer presents frame N, and
 * acquiring for writing blocks until the consumer has taken the packet that is
 * waiting. That is what makes the pipeline lossless: a producer that has run a
 * frame ahead waits instead of dropping the frame it was about to build, which
 * a queue that overwrote its oldest entry would do silently.
 *
 * Not a lock-free ring. The producer is expected to block, so the interesting
 * paths are the blocking ones, and a condition variable is how a thread waits
 * without burning the core the other thread needs.
 */

#include <stdbool.h>
#include <stdint.h>

#include <SDL3/SDL.h>

#include "framepipeline.h"

/* Payload stride. Slots share one allocation, so each one starts on an
 * alignment any packet field can be written at rather than wherever the
 * previous payload happened to end. */
#define PAYLOAD_ALIGN 16

typedef struct Slot {
    TecsFrameSlotState state;
    /* The frame this slot carries, while it is published or being read. Zero
     * otherwise: a slot that has been released carries nothing. */
    uint64_t sequence;
} Slot;

struct TecsFramePipeline {
    SDL_Mutex *lock;
    /* A slot can be taken for writing. */
    SDL_Condition *writable;
    /* A slot has been published. */
    SDL_Condition *readable;
    /* The last blocked caller left the pipeline. */
    SDL_Condition *drained;

    Slot slots[TECS_FRAME_SLOTS];
    unsigned char *payloads;
    uint32_t payloadSize;
    uint32_t stride;

    /* The slot each side holds, or -1. A side that holds one touches only that
     * one, and asking for a second is refused rather than granted. */
    int writing;
    int reading;

    /* The last sequence number stamped. Monotonic for the pipeline's lifetime,
     * so the consumer can tell frames apart without the producer telling it. */
    uint64_t published;

    TecsFramePipelineState state;
    /* Callers between their first predicate check and their last, so destroy
     * can release nothing while a thread is still inside. */
    int blocked;
    /* A destroy is waiting for that count to reach zero. */
    bool draining;
};

/* Pipelines created and not yet destroyed, across this process. A counter
 * rather than a per-pipeline field because what it exists to answer is whether
 * destroy released, and a pipeline that leaked is gone by the time anyone could
 * ask it. */
static SDL_AtomicInt livePipelines;

/* -------------------------------------------------------------------- slots */

static void *payloadOf(TecsFramePipeline *pipeline, int slot)
{
    return pipeline->payloads + (size_t)slot * pipeline->stride;
}

/* A slot nobody holds, or -1. Called with the lock held. */
static int freeSlot(TecsFramePipeline *pipeline)
{
    for (int i = 0; i < TECS_FRAME_SLOTS; i++) {
        if (pipeline->slots[i].state == TECS_FRAME_SLOT_FREE) return i;
    }
    return -1;
}

/* The oldest published slot, or -1 when none is published. Called with the lock
 * held.
 *
 * By sequence rather than by index, so consumption order is production order
 * and does not depend on which slot the producer happened to be given. The
 * depth bound keeps one packet published at a time, so there is one candidate
 * to pick. */
static int publishedSlot(TecsFramePipeline *pipeline)
{
    int oldest = -1;
    for (int i = 0; i < TECS_FRAME_SLOTS; i++) {
        if (pipeline->slots[i].state != TECS_FRAME_SLOT_READY) continue;
        if (oldest < 0
            || pipeline->slots[i].sequence < pipeline->slots[oldest].sequence) {
            oldest = i;
        }
    }
    return oldest;
}

/* Accounts for a caller leaving a wait loop. Called with the lock held.
 *
 * Only a destroy that is already waiting is told about it, so a frame that
 * publishes and consumes normally costs a flag test here rather than a
 * condition variable it has no use for. */
static void leaveWait(TecsFramePipeline *pipeline)
{
    pipeline->blocked--;
    if (pipeline->blocked == 0 && pipeline->draining) {
        SDL_BroadcastCondition(pipeline->drained);
    }
}

/* Stops the pipeline and wakes everything parked in it. Called with the lock
 * held. A crash takes precedence, and an orderly shutdown only advances a
 * pipeline that is still running, so the state keeps the first reason. */
static void stop(TecsFramePipeline *pipeline, TecsFramePipelineState reason)
{
    if (reason == TECS_FRAME_PIPELINE_CRASHED
        || pipeline->state == TECS_FRAME_PIPELINE_RUNNING) {
        pipeline->state = reason;
    }
    /* Broadcast even when the state did not move: a caller parked at the
     * moment of a second stop still has to be woken. */
    SDL_BroadcastCondition(pipeline->writable);
    SDL_BroadcastCondition(pipeline->readable);
}

/* --------------------------------------------------------------- production */

void *tecsFramePipelineAcquireWrite(TecsFramePipeline *pipeline)
{
    if (!pipeline) return NULL;

    SDL_LockMutex(pipeline->lock);
    /* One slot per side. A producer already holding one would have two frames
     * open at once and no way to say which it published. */
    if (pipeline->writing >= 0) {
        SDL_UnlockMutex(pipeline->lock);
        return NULL;
    }

    pipeline->blocked++;
    int slot = -1;
    while (pipeline->state == TECS_FRAME_PIPELINE_RUNNING) {
        slot = freeSlot(pipeline);
        /* A free slot is not enough. Starting a frame while a published packet
         * is still waiting would put the producer two frames ahead, so this is
         * where it waits for the consumer instead. */
        if (slot >= 0 && publishedSlot(pipeline) < 0) break;
        slot = -1;
        SDL_WaitCondition(pipeline->writable, pipeline->lock);
    }
    leaveWait(pipeline);

    if (slot < 0) {
        SDL_UnlockMutex(pipeline->lock);
        return NULL;
    }

    pipeline->slots[slot].state = TECS_FRAME_SLOT_WRITING;
    pipeline->writing = slot;
    void *payload = payloadOf(pipeline, slot);
    SDL_UnlockMutex(pipeline->lock);
    return payload;
}

bool tecsFramePipelinePublish(TecsFramePipeline *pipeline)
{
    if (!pipeline) return false;

    SDL_LockMutex(pipeline->lock);
    int slot = pipeline->writing;
    if (slot < 0) {
        SDL_UnlockMutex(pipeline->lock);
        return false;
    }

    /* Nothing will consume it, and a slot left WRITING would keep the producer
     * holding a frame the pipeline no longer has a use for. */
    if (pipeline->state != TECS_FRAME_PIPELINE_RUNNING) {
        pipeline->slots[slot].state = TECS_FRAME_SLOT_FREE;
        pipeline->writing = -1;
        SDL_UnlockMutex(pipeline->lock);
        return false;
    }

    /* The sequence and the state move together, in one critical section, which
     * is what makes a half-published slot unobservable. */
    pipeline->published++;
    pipeline->slots[slot].sequence = pipeline->published;
    pipeline->slots[slot].state = TECS_FRAME_SLOT_READY;
    pipeline->writing = -1;

    SDL_SignalCondition(pipeline->readable);
    SDL_UnlockMutex(pipeline->lock);
    return true;
}

/* -------------------------------------------------------------- consumption */

void *tecsFramePipelineAcquireRead(TecsFramePipeline *pipeline,
                                   uint64_t *sequence)
{
    if (!pipeline) return NULL;

    SDL_LockMutex(pipeline->lock);
    if (pipeline->reading >= 0) {
        SDL_UnlockMutex(pipeline->lock);
        return NULL;
    }

    pipeline->blocked++;
    int slot = -1;
    while (pipeline->state == TECS_FRAME_PIPELINE_RUNNING) {
        slot = publishedSlot(pipeline);
        if (slot >= 0) break;
        SDL_WaitCondition(pipeline->readable, pipeline->lock);
    }
    leaveWait(pipeline);

    if (slot < 0) {
        SDL_UnlockMutex(pipeline->lock);
        return NULL;
    }

    pipeline->slots[slot].state = TECS_FRAME_SLOT_READING;
    pipeline->reading = slot;
    if (sequence) *sequence = pipeline->slots[slot].sequence;
    void *payload = payloadOf(pipeline, slot);

    /* Taking the packet is what lets the producer start the next frame, since
     * it waits on there being no packet still waiting rather than on a slot
     * being free. */
    SDL_SignalCondition(pipeline->writable);
    SDL_UnlockMutex(pipeline->lock);
    return payload;
}

bool tecsFramePipelineReleaseRead(TecsFramePipeline *pipeline)
{
    if (!pipeline) return false;

    SDL_LockMutex(pipeline->lock);
    int slot = pipeline->reading;
    if (slot < 0) {
        SDL_UnlockMutex(pipeline->lock);
        return false;
    }

    pipeline->slots[slot].state = TECS_FRAME_SLOT_FREE;
    pipeline->slots[slot].sequence = 0;
    pipeline->reading = -1;

    SDL_SignalCondition(pipeline->writable);
    SDL_UnlockMutex(pipeline->lock);
    return true;
}

/* ------------------------------------------------------------------ control */

void tecsFramePipelineShutdown(TecsFramePipeline *pipeline)
{
    if (!pipeline) return;
    SDL_LockMutex(pipeline->lock);
    stop(pipeline, TECS_FRAME_PIPELINE_SHUTTING_DOWN);
    SDL_UnlockMutex(pipeline->lock);
}

void tecsFramePipelineCrash(TecsFramePipeline *pipeline)
{
    if (!pipeline) return;
    SDL_LockMutex(pipeline->lock);
    stop(pipeline, TECS_FRAME_PIPELINE_CRASHED);
    SDL_UnlockMutex(pipeline->lock);
}

TecsFramePipelineState tecsFramePipelineGetState(TecsFramePipeline *pipeline)
{
    if (!pipeline) return TECS_FRAME_PIPELINE_SHUTTING_DOWN;
    SDL_LockMutex(pipeline->lock);
    TecsFramePipelineState state = pipeline->state;
    SDL_UnlockMutex(pipeline->lock);
    return state;
}

TecsFrameSlotState tecsFramePipelineGetSlotState(TecsFramePipeline *pipeline,
                                                 int slot)
{
    if (!pipeline || slot < 0 || slot >= TECS_FRAME_SLOTS) {
        return TECS_FRAME_SLOT_FREE;
    }
    SDL_LockMutex(pipeline->lock);
    TecsFrameSlotState state = pipeline->slots[slot].state;
    SDL_UnlockMutex(pipeline->lock);
    return state;
}

int tecsFramePipelineBlockedCount(TecsFramePipeline *pipeline)
{
    if (!pipeline) return 0;
    SDL_LockMutex(pipeline->lock);
    int blocked = pipeline->blocked;
    SDL_UnlockMutex(pipeline->lock);
    return blocked;
}

uint32_t tecsFramePipelinePayloadSize(TecsFramePipeline *pipeline)
{
    return pipeline ? pipeline->payloadSize : 0;
}

int tecsFramePipelineLiveCount(void)
{
    return SDL_GetAtomicInt(&livePipelines);
}

/* --------------------------------------------------------------- life cycle */

static void release(TecsFramePipeline *pipeline)
{
    if (pipeline->drained) SDL_DestroyCondition(pipeline->drained);
    if (pipeline->readable) SDL_DestroyCondition(pipeline->readable);
    if (pipeline->writable) SDL_DestroyCondition(pipeline->writable);
    if (pipeline->lock) SDL_DestroyMutex(pipeline->lock);
    SDL_free(pipeline->payloads);
    SDL_free(pipeline);
}

TecsFramePipeline *tecsFramePipelineCreate(uint32_t payloadSize)
{
    /* A packet with no payload leaves the two sides nothing to exchange, so
     * this is a caller mistake rather than a degenerate pipeline to support. */
    if (payloadSize == 0) return NULL;

    TecsFramePipeline *pipeline =
        (TecsFramePipeline *)SDL_calloc(1, sizeof(TecsFramePipeline));
    if (!pipeline) return NULL;

    pipeline->payloadSize = payloadSize;
    pipeline->stride =
        (payloadSize + (PAYLOAD_ALIGN - 1)) & ~(uint32_t)(PAYLOAD_ALIGN - 1);
    pipeline->writing = -1;
    pipeline->reading = -1;
    pipeline->state = TECS_FRAME_PIPELINE_RUNNING;

    pipeline->payloads =
        (unsigned char *)SDL_calloc(TECS_FRAME_SLOTS, pipeline->stride);
    pipeline->lock = SDL_CreateMutex();
    pipeline->writable = SDL_CreateCondition();
    pipeline->readable = SDL_CreateCondition();
    pipeline->drained = SDL_CreateCondition();
    if (!pipeline->payloads || !pipeline->lock || !pipeline->writable
        || !pipeline->readable || !pipeline->drained) {
        release(pipeline);
        return NULL;
    }

    /* Counted before the pipeline is handed out, so a caller cannot observe a
     * live pipeline the count does not include. */
    SDL_AddAtomicInt(&livePipelines, 1);
    return pipeline;
}

void tecsFramePipelineDestroy(TecsFramePipeline *pipeline)
{
    if (!pipeline) return;

    SDL_LockMutex(pipeline->lock);
    stop(pipeline, TECS_FRAME_PIPELINE_SHUTTING_DOWN);
    /* Nothing is released while a caller is still inside. A blocked consumer at
     * shutdown is the ordinary case, and freeing the lock it is parked on is a
     * use-after-free that will not reproduce on demand. Waiters decrement the
     * count and signal while holding the lock, so reaching zero here means
     * every one of them has left the critical section as well. */
    pipeline->draining = true;
    while (pipeline->blocked > 0) {
        SDL_WaitCondition(pipeline->drained, pipeline->lock);
    }
    SDL_UnlockMutex(pipeline->lock);

    release(pipeline);
    SDL_AddAtomicInt(&livePipelines, -1);
}
