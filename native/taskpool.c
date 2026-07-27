/* A task executor for Box2D's solver.
 *
 * Box2D 3 solves across threads when a world is given an enqueue and a finish
 * callback, and it calls the task function it hands out from whichever thread
 * picks the work up. That is why this is native: a LuaJIT FFI callback invoked
 * from a thread the VM did not create is unsafe, so an enqueue callback written
 * in Lua would be exactly that. Lua installs two function pointers and a
 * context into the world definition, and nothing above this file runs while a
 * step is in flight.
 *
 * The shape is a fixed set of threads over one FIFO queue of chunks. A task is
 * a parallel-for: Box2D gives an item count and a minimum range, this splits it
 * into chunks, and each chunk runs on one worker slot. Slot zero belongs to the
 * thread that called b2World_Step, which helps drain the queue while it waits
 * rather than idling; every other slot belongs to one pool thread for that
 * thread's lifetime, which is what Box2D asks for when it says a worker exists
 * on only one thread at a time.
 *
 * Enqueue never blocks and never waits for a slot: more tasks outstanding than
 * the pool has room for means the task runs in the calling thread, which Box2D
 * accounts for through a NULL result. That is what keeps a step deadlock-free
 * no matter how many tasks it has in flight.
 *
 * One pool serves one world. Slot zero is whichever thread is stepping, so two
 * worlds stepping through one pool at the same time would put two threads on
 * one worker slot.
 */

#include <stdbool.h>
#include <stdint.h>

#include <SDL3/SDL.h>
#include <box2d/box2d.h>

#ifdef __APPLE__
#include <sys/sysctl.h>
#endif

#include "taskpool.h"

/* Worker slots a pool can have, counting the stepping thread. */
#define MAX_WORKERS 64

/* Worker slots a machine-derived count will use at most. The solver's stages
 * are short, so past a handful of workers the coordination between them costs
 * more than the work each one takes. */
#define MAX_DEFAULT_WORKERS 8

/* Tasks that can be outstanding at once. Box2D keeps one per worker in flight
 * while it solves, plus the broadphase rebuild, so this is several times what a
 * step needs and exhausting it is a fallback rather than an expected case. */
#define MAX_TASKS 256

typedef struct Task {
    b2TaskCallback *run;
    void *context;
    int itemCount;
    int chunkCount;
    /* Chunks handed to a thread, and chunks that have finished. Both are
     * touched only under the pool's lock, so a chunk is claimed exactly once
     * and a waiter never reads a torn count. */
    int claimed;
    int finished;
    /* Queue link while chunks remain unclaimed, free-list link otherwise. */
    struct Task *next;
} Task;

typedef struct Thread {
    TecsTaskPool *pool;
    SDL_Thread *thread;
    uint32_t workerIndex;
} Thread;

struct TecsTaskPool {
    SDL_Mutex *lock;
    /* Chunks became claimable. */
    SDL_Condition *queued;
    /* A task finished its last chunk. */
    SDL_Condition *completed;

    /* Tasks with unclaimed chunks, oldest first. */
    Task *head;
    Task *tail;
    Task *free;
    Task slots[MAX_TASKS];

    /* Indexed by worker slot, so entry zero is the stepping thread's and holds
     * no thread of its own. */
    Thread threads[MAX_WORKERS];
    int workerCount;
    int threadCount;
    bool stopping;
};

/* Pool threads started and not yet finished, across this process. A counter
 * rather than a per-pool field because what it exists to answer is whether
 * shutdown joined, and a pool that leaked a thread is gone by the time anyone
 * could ask it.
 *
 * Counted up by the thread that starts one and down by the thread itself, so
 * the count covers a thread that has been created but has not reached its
 * entry point yet. Counting up at the entry point instead would read as a leak
 * cleared for a moment after the pool was created. */
static SDL_AtomicInt liveThreads;

/* --------------------------------------------------------------------- work */

/* Runs one chunk on the worker slot `workerIndex`.
 *
 * The range is derived from the chunk index rather than stored, so a task
 * carries two integers instead of an array of ranges. Multiplying before
 * dividing spreads the remainder across chunks instead of piling it on the
 * last one. */
static void runChunk(Task *task, int chunk, uint32_t workerIndex)
{
    int64_t items = task->itemCount;
    int64_t count = task->chunkCount;
    int start = (int)((items * chunk) / count);
    int end = (int)((items * (chunk + 1)) / count);
    if (end > start) {
        task->run(start, end, workerIndex, task->context);
    }
}

/* Takes the oldest unclaimed chunk, or returns NULL when there is none. Called
 * with the lock held.
 *
 * Oldest first is not a fairness preference. Box2D's solver puts one task per
 * worker in flight and the first of them drives the rest through their stages
 * while they wait on it, so a claim order that could leave that one queued
 * while the others occupy every thread would hang. FIFO makes the chunk the
 * others wait on the first chunk claimed, which puts it on a running thread
 * before any of them starts. */
static Task *claimChunk(TecsTaskPool *pool, int *chunk)
{
    Task *task = pool->head;
    if (!task) return NULL;

    *chunk = task->claimed;
    task->claimed++;
    if (task->claimed == task->chunkCount) {
        pool->head = task->next;
        if (!pool->head) pool->tail = NULL;
        task->next = NULL;
    }
    return task;
}

/* Accounts for a finished chunk and wakes the waiter when the task is done.
 * Called with the lock held. */
static void completeChunk(TecsTaskPool *pool, Task *task)
{
    task->finished++;
    if (task->finished == task->chunkCount) {
        SDL_BroadcastCondition(pool->completed);
    }
}

static int workerThread(void *data)
{
    Thread *self = (Thread *)data;
    TecsTaskPool *pool = self->pool;

    SDL_LockMutex(pool->lock);
    while (true) {
        while (!pool->head && !pool->stopping) {
            SDL_WaitCondition(pool->queued, pool->lock);
        }
        /* Shutdown wins over the queue because a pool is only stopped with no
         * step in flight, so there is nothing queued to abandon. */
        if (pool->stopping) break;

        int chunk = 0;
        Task *task = claimChunk(pool, &chunk);
        SDL_UnlockMutex(pool->lock);
        runChunk(task, chunk, self->workerIndex);
        SDL_LockMutex(pool->lock);
        completeChunk(pool, task);
    }
    SDL_UnlockMutex(pool->lock);

    SDL_AddAtomicInt(&liveThreads, -1);
    return 0;
}

/* ---------------------------------------------------------------- callbacks */

/* Declared through Box2D's own types, so a signature that drifts from what
 * Box2D calls is a compile error here rather than a corrupted stack later. */
static b2EnqueueTaskCallback poolEnqueue;
static b2FinishTaskCallback poolFinish;

static void *poolEnqueue(b2TaskCallback *run, int itemCount, int minRange, void *taskContext, void *userContext)
{
    TecsTaskPool *pool = (TecsTaskPool *)userContext;

    if (itemCount <= 0) return NULL;

    /* Serially, in the calling thread. A NULL result tells Box2D the work is
     * already done and there is nothing to finish, so this is the whole of the
     * one-worker path: a pool with a single slot behaves exactly as a world
     * given no executor at all does. */
    if (!pool || pool->threadCount == 0) {
        run(0, itemCount, 0, taskContext);
        return NULL;
    }

    /* Box2D asks for ranges no shorter than minRange, and splitting further
     * than there are worker slots would only put two chunks of one task on one
     * thread. */
    int chunkCount = minRange > 0 ? itemCount / minRange : itemCount;
    if (chunkCount > pool->workerCount) chunkCount = pool->workerCount;
    if (chunkCount < 1) chunkCount = 1;

    SDL_LockMutex(pool->lock);
    Task *task = pool->free;
    if (task) {
        pool->free = task->next;
        task->run = run;
        task->context = taskContext;
        task->itemCount = itemCount;
        task->chunkCount = chunkCount;
        task->claimed = 0;
        task->finished = 0;
        task->next = NULL;

        if (pool->tail) {
            pool->tail->next = task;
        } else {
            pool->head = task;
        }
        pool->tail = task;
        /* Several chunks became claimable at once, so every waiting thread has
         * work rather than only the first one woken. */
        SDL_BroadcastCondition(pool->queued);
    }
    SDL_UnlockMutex(pool->lock);

    if (!task) {
        run(0, itemCount, 0, taskContext);
        return NULL;
    }
    return task;
}

static void poolFinish(void *userTask, void *userContext)
{
    Task *task = (Task *)userTask;
    TecsTaskPool *pool = (TecsTaskPool *)userContext;
    if (!task || !pool) return;

    SDL_LockMutex(pool->lock);
    while (task->finished < task->chunkCount) {
        int chunk = 0;
        Task *other = claimChunk(pool, &chunk);
        if (other) {
            /* Worker slot zero is this thread's, the one that called
             * b2World_Step: no pool thread uses it, so running a chunk here
             * cannot put two chunks on one worker slot. Helping is also what
             * makes the wait below finite when a step has more chunks
             * outstanding than the pool has threads. */
            SDL_UnlockMutex(pool->lock);
            runChunk(other, chunk, 0);
            SDL_LockMutex(pool->lock);
            completeChunk(pool, other);
            continue;
        }
        /* Nothing left to claim, so every remaining chunk of this task is on a
         * thread that will account for it and wake this one. */
        SDL_WaitCondition(pool->completed, pool->lock);
    }

    task->next = pool->free;
    pool->free = task;
    SDL_UnlockMutex(pool->lock);
}

void *tecsTaskPoolEnqueueCallback(void)
{
    return (void *)poolEnqueue;
}

void *tecsTaskPoolFinishCallback(void)
{
    return (void *)poolFinish;
}

/* --------------------------------------------------------------- life cycle */

static void releasePool(TecsTaskPool *pool)
{
    if (pool->completed) SDL_DestroyCondition(pool->completed);
    if (pool->queued) SDL_DestroyCondition(pool->queued);
    if (pool->lock) SDL_DestroyMutex(pool->lock);
    SDL_free(pool);
}

TecsTaskPool *tecsTaskPoolCreate(int workerCount)
{
    if (workerCount < 1) workerCount = 1;
    if (workerCount > MAX_WORKERS) workerCount = MAX_WORKERS;

    TecsTaskPool *pool = (TecsTaskPool *)SDL_calloc(1, sizeof(TecsTaskPool));
    if (!pool) return NULL;

    pool->workerCount = workerCount;
    pool->lock = SDL_CreateMutex();
    pool->queued = SDL_CreateCondition();
    pool->completed = SDL_CreateCondition();
    if (!pool->lock || !pool->queued || !pool->completed) {
        releasePool(pool);
        return NULL;
    }

    for (int i = MAX_TASKS - 1; i >= 0; i--) {
        pool->slots[i].next = pool->free;
        pool->free = &pool->slots[i];
    }

    /* Slot zero is the stepping thread's, so the threads take the rest. */
    for (int i = 1; i < workerCount; i++) {
        Thread *worker = &pool->threads[i];
        worker->pool = pool;
        worker->workerIndex = (uint32_t)i;
        worker->thread = SDL_CreateThread(workerThread, "tecs.solver", worker);
        if (!worker->thread) {
            /* Fewer threads than asked for still solves correctly, but the
             * count Box2D is told has to be the one that exists. */
            pool->workerCount = i;
            break;
        }
        SDL_AddAtomicInt(&liveThreads, 1);
        pool->threadCount++;
    }
    return pool;
}

void tecsTaskPoolDestroy(TecsTaskPool *pool)
{
    if (!pool) return;

    SDL_LockMutex(pool->lock);
    pool->stopping = true;
    SDL_BroadcastCondition(pool->queued);
    SDL_UnlockMutex(pool->lock);

    /* Every thread is joined before anything it reads is released. A pool
     * freed while a thread is still inside it is a use-after-free that will
     * not reproduce on demand. */
    for (int i = 1; i <= pool->threadCount; i++) {
        SDL_WaitThread(pool->threads[i].thread, NULL);
    }

    releasePool(pool);
}

int tecsTaskPoolWorkerCount(TecsTaskPool *pool)
{
    return pool ? pool->workerCount : 0;
}

/* Cores of the fastest kind, where the platform can say, and zero where it
 * cannot or where they are all the same kind.
 *
 * Box2D asks for these specifically. Its workers wait on each other between
 * solver stages, so a stage that lands on an efficiency core holds every other
 * worker until it finishes, and the slowest core sets the pace of the step. */
static int performanceCores(void)
{
#ifdef __APPLE__
    int cores = 0;
    size_t size = sizeof(cores);
    /* Published only on machines with more than one kind of core. */
    if (sysctlbyname("hw.perflevel0.logicalcpu", &cores, &size, NULL, 0) == 0) {
        return cores;
    }
#endif
    return 0;
}

int tecsTaskPoolDefaultWorkerCount(void)
{
    int cores = performanceCores();
    if (cores < 1) cores = SDL_GetNumLogicalCPUCores();
    if (cores < 1) cores = 1;

    /* Every slot is a thread running solver work, one of them the thread that
     * steps the world, so a count equal to the core count leaves the machine
     * exactly subscribed. Box2D's workers spin while they wait, and a spinning
     * worker on a core the stepping thread needs takes more than it
     * contributes. */
    if (cores > MAX_DEFAULT_WORKERS) cores = MAX_DEFAULT_WORKERS;
    return cores;
}

int tecsTaskPoolLiveThreadCount(void)
{
    return SDL_GetAtomicInt(&liveThreads);
}
