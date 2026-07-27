/* The frame coordinator between the thread that simulates and the thread that
 * owns the window. See framepipeline.c for why this is native.
 *
 * The cdef the FFI uses is generated from this header, so the two cannot
 * drift.
 */

#ifndef TECS_FRAMEPIPELINE_H
#define TECS_FRAMEPIPELINE_H

#include <stdbool.h>
#include <stdint.h>

/* Slots a pipeline has. One is filled while the other is read, which is the
 * whole of what the producer needs to run a frame ahead. A third slot only
 * lets the producer get further ahead, and every frame it gets ahead is a
 * frame of latency between simulating a packet and presenting it. */
#define TECS_FRAME_SLOTS 2

typedef struct TecsFramePipeline TecsFramePipeline;

/* Where a slot is in its cycle.
 *
 * FREE -> WRITING when the producer acquires it, WRITING -> READY when the
 * producer publishes it, READY -> READING when the consumer acquires it, and
 * READING -> FREE when the consumer releases it. No other move is legal, and
 * an operation that would make one is refused rather than performed. */
typedef enum TecsFrameSlotState {
    TECS_FRAME_SLOT_FREE = 0,
    TECS_FRAME_SLOT_WRITING = 1,
    TECS_FRAME_SLOT_READY = 2,
    TECS_FRAME_SLOT_READING = 3
} TecsFrameSlotState;

/* What the pipeline as a whole is doing.
 *
 * An enum rather than a flag because the reason the pipeline stopped decides
 * what the threads above it do next, and a caller that woke from a blocking
 * acquire has to be able to tell an orderly quit from a thread that died. */
typedef enum TecsFramePipelineState {
    TECS_FRAME_PIPELINE_RUNNING = 0,
    TECS_FRAME_PIPELINE_CRASHED = 1,
    TECS_FRAME_PIPELINE_SHUTTING_DOWN = 2
} TecsFramePipelineState;

/* Creates a pipeline whose packets carry `payloadSize` bytes each.
 *
 * The payload is opaque here: the pipeline allocates it, hands out its address,
 * and never reads it. Returns NULL when the pipeline cannot be allocated, and
 * for a payload size of zero, which would leave the producer and the consumer
 * nothing to exchange. */
TecsFramePipeline *tecsFramePipelineCreate(uint32_t payloadSize);

/* Stops the pipeline, waits for every blocked caller to leave it, and releases
 * it. Safe to call with threads parked inside; not safe to call while a thread
 * may still start a new operation. */
void tecsFramePipelineDestroy(TecsFramePipeline *pipeline);

/* Bytes each packet carries, for a caller that was handed the pipeline rather
 * than having created it. */
uint32_t tecsFramePipelinePayloadSize(TecsFramePipeline *pipeline);

/* Takes a slot for writing and returns its payload address.
 *
 * Blocks while there is no slot to take, which is the back pressure: a
 * producer that has run a frame ahead waits here rather than dropping the
 * frame it was about to build. Returns NULL when the pipeline is no longer
 * running, and when the caller already holds a slot for writing. */
void *tecsFramePipelineAcquireWrite(TecsFramePipeline *pipeline);

/* Publishes the slot held for writing, which is what makes it visible to the
 * consumer, and stamps it with the next frame sequence number.
 *
 * Never blocks. Returns false when no slot is held for writing, and when the
 * pipeline has stopped, in which case the slot is returned unpublished. */
bool tecsFramePipelinePublish(TecsFramePipeline *pipeline);

/* Takes the oldest published slot for reading and returns its payload address,
 * writing its frame sequence number to `sequence` when that is not NULL.
 *
 * Blocks until a published slot exists. Returns NULL when the pipeline is no
 * longer running, and when the caller already holds a slot for reading. */
void *tecsFramePipelineAcquireRead(TecsFramePipeline *pipeline, uint64_t *sequence);

/* Returns the slot held for reading to the pool of free slots, which is what
 * lets the producer reuse it.
 *
 * Never blocks. Returns false when no slot is held for reading. */
bool tecsFramePipelineReleaseRead(TecsFramePipeline *pipeline);

/* Asks the pipeline to stop and wakes every blocked caller so it can observe
 * that rather than staying parked. Does nothing to a pipeline that has already
 * stopped, so the state keeps the first reason it stopped for. */
void tecsFramePipelineShutdown(TecsFramePipeline *pipeline);

/* Stops the pipeline because a thread above it failed, and wakes every blocked
 * caller. Takes precedence over an orderly shutdown: the failure is the part
 * the other thread has to know about. */
void tecsFramePipelineCrash(TecsFramePipeline *pipeline);

/* What the pipeline is doing, which is how a caller that woke from a blocking
 * acquire with nothing to show for it finds out why. */
TecsFramePipelineState tecsFramePipelineGetState(TecsFramePipeline *pipeline);

/* Where a slot is in its cycle, by zero-based index. Reports FREE for an index
 * the pipeline does not have. */
TecsFrameSlotState tecsFramePipelineGetSlotState(TecsFramePipeline *pipeline, int slot);

/* Callers parked inside the pipeline waiting for a slot.
 *
 * This is what destroy waits to reach zero, and it is how another thread can
 * tell that one is parked rather than about to park, which is the difference
 * between a pipeline that is safe to release and one that is not. */
int tecsFramePipelineBlockedCount(TecsFramePipeline *pipeline);

/* Pipelines live in this process. Returns to its starting value once each one
 * is destroyed, which is how a test observes that destroy released rather than
 * inferring it from a clean exit. */
int tecsFramePipelineLiveCount(void);

#endif
