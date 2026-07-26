/* A task executor for Box2D's solver. See taskpool.c for why this is native.
 *
 * The cdef the FFI uses is generated from this header, so the two cannot
 * drift.
 */

#ifndef TECS_TASKPOOL_H
#define TECS_TASKPOOL_H

typedef struct TecsTaskPool TecsTaskPool;

/* Creates a pool with `workerCount` worker slots. One slot is the thread that
 * steps the world, so `workerCount - 1` threads are started and a count of one
 * starts none. Returns NULL when the pool itself cannot be allocated; a pool
 * that starts fewer threads than asked for reports the count it reached. */
TecsTaskPool *tecsTaskPoolCreate(int workerCount);

/* Joins every thread and releases the pool. Call with no step in flight. */
void tecsTaskPoolDestroy(TecsTaskPool *pool);

/* Worker slots the pool has, which is what `b2WorldDef.workerCount` carries.
 * Box2D indexes per-worker state by this count, so a def naming more workers
 * than the pool started would index state that does not exist. */
int tecsTaskPoolWorkerCount(TecsTaskPool *pool);

/* A worker count derived from the machine, for a caller that has no reason to
 * choose one. */
int tecsTaskPoolDefaultWorkerCount(void);

/* The two callbacks, as a `b2EnqueueTaskCallback *` and a
 * `b2FinishTaskCallback *`. Returned untyped so this header does not depend on
 * Box2D's, which leaves one description of that ABI rather than two: the
 * caller assigns them straight into a `b2WorldDef`. */
void *tecsTaskPoolEnqueueCallback(void);
void *tecsTaskPoolFinishCallback(void);

/* Pool threads running in this process, across every pool. Returns to its
 * starting value once a pool is destroyed, which is how a test observes that
 * shutdown joined rather than inferring it from a clean exit. */
int tecsTaskPoolLiveThreadCount(void);

#endif
