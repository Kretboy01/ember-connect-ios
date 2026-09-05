// Included only by LCBootstrap.m. Arms before the guest is dlopened so
// Appdome's libloader constructors and main see hooked exit symbols.
#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "../litehook/src/litehook.h"

#if defined(__arm64__) && !defined(__arm64e__)
static int Ember8BLogFD = -1;
static atomic_int Ember8BIgnored;
static void (*Ember8BRealExit)(int);
static void (*Ember8BReal_Exit)(int);
static void (*Ember8BReal_exit)(int);

static void Ember8BLog(const char *message) {
    if (Ember8BLogFD >= 0) {
        write(Ember8BLogFD, message, strlen(message));
        write(Ember8BLogFD, "\n", 1);
    }
}

static void Ember8BLogPtr(const char *prefix, uintptr_t value) {
    char line[80];
    snprintf(line, sizeof(line), "%s 0x%llx", prefix, (unsigned long long)value);
    Ember8BLog(line);
}

static bool Ember8BShouldIgnore(int status, uintptr_t caller) {
    int seen = atomic_fetch_add(&Ember8BIgnored, 1) + 1;
    Ember8BLogPtr("exit status", (uintptr_t)(unsigned)status);
    Ember8BLogPtr("exit caller", caller);
    if (seen <= 8) {
        Ember8BLog("ignoring startup exit");
        return true;
    }
    Ember8BLog("allowing exit");
    return false;
}

static void Ember8BHookExit(int status) {
    if (Ember8BShouldIgnore(status, (uintptr_t)__builtin_return_address(0))) return;
    if (Ember8BRealExit) Ember8BRealExit(status);
    else _exit(status);
}

static void Ember8BHook_Exit(int status) {
    if (Ember8BShouldIgnore(status, (uintptr_t)__builtin_return_address(0))) return;
    if (Ember8BReal_Exit) Ember8BReal_Exit(status);
    else _exit(status);
}

static void Ember8BHook_exit(int status) {
    if (Ember8BShouldIgnore(status, (uintptr_t)__builtin_return_address(0))) return;
    if (Ember8BReal_exit) Ember8BReal_exit(status);
    else _exit(status);
}

static void EmberEightBallCompatibilityPrepare(NSBundle *bundle, NSDictionary *settings, NSString *documents) {
    if (![bundle.bundleIdentifier isEqualToString:@"com.miniclip.8ballpoolmult"] ||
        [settings[@"EmberEightBallCompatibilityDisabled"] boolValue]) return;
    Ember8BLogFD = open([[documents stringByAppendingPathComponent:@"EmberEightBallCompat.log"] fileSystemRepresentation],
                        O_WRONLY | O_CREAT | O_TRUNC, 0600);
    Ember8BRealExit = exit;
    Ember8BReal_Exit = _Exit;
    Ember8BReal_exit = _exit;
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, exit, Ember8BHookExit, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, _Exit, Ember8BHook_Exit, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, _exit, Ember8BHook_exit, nil);
    Ember8BLog("56.29.2 exit gate armed before guest load");
}
#else
static void EmberEightBallCompatibilityPrepare(NSBundle *bundle, NSDictionary *settings, NSString *documents) {}
#endif
