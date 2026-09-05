// EightBallLaunch.m — dylib-only backup for the host 8 Ball exit gate.
// Prefer the host hook in EmberEightBallCompatibility.h (runs before
// libloader). This constructor still helps when only the dylib is pushed.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../../LiveContainerRuntime/litehook/src/litehook.h"

#define EIGHTBALL_MAX_IGNORED_EXITS 8

static FILE *gLog;
static void (*gRealExit)(int);
static void (*gReal_Exit)(int);
static void (*gReal_exit)(int);
static atomic_int gIgnoredExits;

static void EightBallLog(const char *message) {
    if (!gLog) return;
    fwrite(message, 1, strlen(message), gLog);
    fwrite("\n", 1, 1, gLog);
    fflush(gLog);
}

static void EightBallLogHex(const char *prefix, uintptr_t value) {
    char line[96];
    snprintf(line, sizeof(line), "%s 0x%llx", prefix, (unsigned long long)value);
    EightBallLog(line);
}

static bool EightBallShouldIgnore(int status, void *caller) {
    int seen = atomic_fetch_add(&gIgnoredExits, 1) + 1;
    EightBallLogHex("startup exit status", (uintptr_t)(unsigned)status);
    EightBallLogHex("startup exit caller", (uintptr_t)caller);
    if (seen <= EIGHTBALL_MAX_IGNORED_EXITS) {
        EightBallLog("ignoring Appdome-style startup exit");
        return true;
    }
    EightBallLog("allowing later exit");
    return false;
}

static void EightBallHookExit(int status) {
    if (EightBallShouldIgnore(status, __builtin_return_address(0))) return;
    if (gRealExit) gRealExit(status);
    else _exit(status);
}

static void EightBallHook_Exit(int status) {
    if (EightBallShouldIgnore(status, __builtin_return_address(0))) return;
    if (gReal_Exit) gReal_Exit(status);
    else _exit(status);
}

static void EightBallHook_exit(int status) {
    if (EightBallShouldIgnore(status, __builtin_return_address(0))) return;
    if (gReal_exit) gReal_exit(status);
    else _exit(status);
}

__attribute__((constructor))
static void EightBallLaunchInit(void) {
    const char *home = getenv("LC_HOME_PATH");
    NSString *docs = home ? [@(home) stringByAppendingPathComponent:@"Documents"]
                          : NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    [[NSFileManager defaultManager] createDirectoryAtPath:[docs stringByAppendingPathComponent:@"EmberConnect"]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    gLog = fopen([[docs stringByAppendingPathComponent:@"EmberConnect/EightBallLaunch.log"] fileSystemRepresentation], "w");
    EightBallLog("EightBallLaunch constructor");

    gRealExit = exit;
    gReal_Exit = _Exit;
    gReal_exit = _exit;
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, exit, EightBallHookExit, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, _Exit, EightBallHook_Exit, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, _exit, EightBallHook_exit, nil);
    EightBallLog("exit hooks installed");
}
