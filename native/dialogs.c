/* Native file-dialog callback bridge.
 *
 * A Lua function reached through ffi.cast cannot be entered from a thread the
 * VM did not create. SDL explicitly permits its dialog callback to arrive on
 * another thread, so the callback is native and leaves an owned answer for the
 * main thread to poll.
 */

#include <SDL3/SDL.h>

#include "dialogs.h"

struct TecsDialog {
    SDL_Mutex *lock;
    bool ready;
    bool canceled;
    int filter;
    int pathCount;
    char **paths;
    char *error;
    SDL_DialogFileFilter *filters;
    int filterCount;
    char *location;
};

static void freeFilters(TecsDialog *dialog)
{
    if (!dialog->filters) return;
    for (int i = 0; i < dialog->filterCount; i++) {
        SDL_free((void *)dialog->filters[i].name);
        SDL_free((void *)dialog->filters[i].pattern);
    }
    SDL_free(dialog->filters);
    dialog->filters = NULL;
}

static void setError(TecsDialog *dialog, const char *message)
{
    dialog->error = SDL_strdup(message && message[0] ? message : "file dialog failed");
}

static void fileDialogCallback(void *userdata, const char *const *filelist, int filter)
{
    TecsDialog *dialog = (TecsDialog *)userdata;
    SDL_LockMutex(dialog->lock);

    dialog->filter = filter;
    if (!filelist) {
        setError(dialog, SDL_GetError());
    } else {
        int count = 0;
        while (filelist[count]) count++;
        dialog->canceled = count == 0;
        if (count > 0) {
            dialog->paths = (char **)SDL_calloc((size_t)count, sizeof(char *));
            if (!dialog->paths) {
                setError(dialog, "out of memory copying file-dialog result");
            } else {
                dialog->pathCount = count;
                for (int i = 0; i < count; i++) {
                    dialog->paths[i] = SDL_strdup(filelist[i]);
                    if (!dialog->paths[i]) {
                        setError(dialog, "out of memory copying file-dialog path");
                        dialog->pathCount = i;
                        break;
                    }
                }
            }
        }
    }

    dialog->ready = true;
    SDL_UnlockMutex(dialog->lock);
}

static TecsDialog *createDialog(const char *const *names, const char *const *patterns, int filterCount,
                                const char *location)
{
    TecsDialog *dialog = (TecsDialog *)SDL_calloc(1, sizeof(TecsDialog));
    if (!dialog) return NULL;
    dialog->filter = -1;
    dialog->lock = SDL_CreateMutex();
    if (!dialog->lock) {
        SDL_free(dialog);
        return NULL;
    }
    if (location) {
        dialog->location = SDL_strdup(location);
        if (!dialog->location) {
            setError(dialog, "out of memory copying file-dialog location");
            dialog->ready = true;
            return dialog;
        }
    }
    if (filterCount > 0) {
        dialog->filters = (SDL_DialogFileFilter *)SDL_calloc((size_t)filterCount, sizeof(SDL_DialogFileFilter));
        if (!dialog->filters) {
            setError(dialog, "out of memory copying file-dialog filters");
            dialog->ready = true;
            return dialog;
        }
        dialog->filterCount = filterCount;
        for (int i = 0; i < filterCount; i++) {
            dialog->filters[i].name = SDL_strdup(names[i]);
            dialog->filters[i].pattern = SDL_strdup(patterns[i]);
            if (!dialog->filters[i].name || !dialog->filters[i].pattern) {
                setError(dialog, "out of memory copying file-dialog filter");
                dialog->ready = true;
                return dialog;
            }
        }
    }
    return dialog;
}

TecsDialog *tecsDialogOpenFile(SDL_Window *window, const char *const *names, const char *const *patterns,
                               int filterCount, const char *location, bool multiple)
{
    TecsDialog *dialog = createDialog(names, patterns, filterCount, location);
    if (!dialog || dialog->ready) return dialog;
    SDL_ShowOpenFileDialog(fileDialogCallback, dialog, window, dialog->filters, filterCount, dialog->location,
                           multiple);
    return dialog;
}

TecsDialog *tecsDialogSaveFile(SDL_Window *window, const char *const *names, const char *const *patterns,
                               int filterCount, const char *location)
{
    TecsDialog *dialog = createDialog(names, patterns, filterCount, location);
    if (!dialog || dialog->ready) return dialog;
    SDL_ShowSaveFileDialog(fileDialogCallback, dialog, window, dialog->filters, filterCount, dialog->location);
    return dialog;
}

TecsDialog *tecsDialogOpenFolder(SDL_Window *window, const char *location, bool multiple)
{
    TecsDialog *dialog = createDialog(NULL, NULL, 0, location);
    if (!dialog || dialog->ready) return dialog;
    SDL_ShowOpenFolderDialog(fileDialogCallback, dialog, window, dialog->location, multiple);
    return dialog;
}

bool tecsDialogReady(TecsDialog *dialog)
{
    if (!dialog) return true;
    SDL_LockMutex(dialog->lock);
    bool ready = dialog->ready;
    SDL_UnlockMutex(dialog->lock);
    return ready;
}

bool tecsDialogCancelled(TecsDialog *dialog)
{
    return dialog ? dialog->canceled : false;
}

int tecsDialogFilter(TecsDialog *dialog)
{
    return dialog ? dialog->filter : -1;
}

int tecsDialogPathCount(TecsDialog *dialog)
{
    return dialog ? dialog->pathCount : 0;
}

const char *tecsDialogPath(TecsDialog *dialog, int index)
{
    if (!dialog || index < 0 || index >= dialog->pathCount) return NULL;
    return dialog->paths[index];
}

const char *tecsDialogError(TecsDialog *dialog)
{
    return dialog ? dialog->error : "cannot allocate file-dialog state";
}

void tecsDialogDestroy(TecsDialog *dialog)
{
    if (!dialog) return;
    for (int i = 0; i < dialog->pathCount; i++) SDL_free(dialog->paths[i]);
    SDL_free(dialog->paths);
    SDL_free(dialog->error);
    freeFilters(dialog);
    SDL_free(dialog->location);
    SDL_DestroyMutex(dialog->lock);
    SDL_free(dialog);
}
