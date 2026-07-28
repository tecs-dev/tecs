/* Native file-dialog callback bridge.
 *
 * SDL may invoke a file-dialog callback from a thread LuaJIT did not create.
 * The callback therefore stays in C, copies its answer under a mutex, and Lua
 * polls the state from the main thread.
 */

#ifndef TECS_DIALOGS_H
#define TECS_DIALOGS_H

#include <stdbool.h>

typedef struct SDL_Window SDL_Window;
typedef struct TecsDialog TecsDialog;

TecsDialog *tecsDialogOpenFile(SDL_Window *window, const char *const *names, const char *const *patterns,
                               int filterCount, const char *location, bool multiple);
TecsDialog *tecsDialogSaveFile(SDL_Window *window, const char *const *names, const char *const *patterns,
                               int filterCount, const char *location);
TecsDialog *tecsDialogOpenFolder(SDL_Window *window, const char *location, bool multiple);

bool tecsDialogReady(TecsDialog *dialog);
bool tecsDialogCancelled(TecsDialog *dialog);
int tecsDialogFilter(TecsDialog *dialog);
int tecsDialogPathCount(TecsDialog *dialog);
const char *tecsDialogPath(TecsDialog *dialog, int index);
const char *tecsDialogError(TecsDialog *dialog);
void tecsDialogDestroy(TecsDialog *dialog);

#endif
