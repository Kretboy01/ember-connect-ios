// Included only by LCBootstrap.m after litehook.h. Arms before the guest
// is dlopened so Appdome constructors and main see hooked terminate symbols.
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#if defined(__arm64__) && !defined(__arm64e__)
static int Ember8BLogFD = -1;
static atomic_int Ember8BIgnored;
static bool Ember8BArmed;
static void (*Ember8BRealExit)(int);
static void (*Ember8BReal_Exit)(int);
static void (*Ember8BReal_exit)(int);
static void (*Ember8BRealAbort)(void);
static int (*Ember8BRealRaise)(int);
static int (*Ember8BRealKill)(pid_t, int);
static void (*Ember8BRealTerminate)(void);

static void Ember8BLog(const char *message) {
    if (Ember8BLogFD >= 0) {
        write(Ember8BLogFD, message, strlen(message));
        write(Ember8BLogFD, "\n", 1);
    }
}

static void Ember8BLogPtr(const char *prefix, uintptr_t value) {
    char line[96];
    snprintf(line, sizeof(line), "%s 0x%llx", prefix, (unsigned long long)value);
    Ember8BLog(line);
}

static bool Ember8BShouldIgnore(const char *kind, int status, uintptr_t caller) {
    int seen = atomic_fetch_add(&Ember8BIgnored, 1) + 1;
    Ember8BLog(kind);
    Ember8BLogPtr("status", (uintptr_t)(unsigned)status);
    Ember8BLogPtr("caller", caller);
    if (seen <= 16) {
        Ember8BLog("ignoring startup terminate");
        return true;
    }
    Ember8BLog("allowing terminate");
    return false;
}

static void Ember8BAllowExit(int status) {
    syscall(SYS_exit, status);
}

static void Ember8BHookExit(int status) {
    if (Ember8BShouldIgnore("exit", status, (uintptr_t)__builtin_return_address(0))) return;
    Ember8BAllowExit(status);
}

static void Ember8BHook_Exit(int status) {
    if (Ember8BShouldIgnore("_Exit", status, (uintptr_t)__builtin_return_address(0))) return;
    Ember8BAllowExit(status);
}

static void Ember8BHook_exit(int status) {
    if (Ember8BShouldIgnore("_exit", status, (uintptr_t)__builtin_return_address(0))) return;
    Ember8BAllowExit(status);
}

static void Ember8BHookAbort(void) {
    if (Ember8BShouldIgnore("abort", SIGABRT, (uintptr_t)__builtin_return_address(0))) return;
    Ember8BAllowExit(134);
}

static int Ember8BHookRaise(int sig) {
    if (Ember8BShouldIgnore("raise", sig, (uintptr_t)__builtin_return_address(0))) return 0;
    Ember8BAllowExit(128 + (sig & 0x7f));
    return -1;
}

static int Ember8BHookKill(pid_t pid, int sig) {
    if (pid == getpid() || pid == 0) {
        if (Ember8BShouldIgnore("kill-self", sig, (uintptr_t)__builtin_return_address(0))) return 0;
        Ember8BAllowExit(128 + (sig & 0x7f));
    }
    return (int)syscall(SYS_kill, pid, sig);
}

static int Ember8BHookPthreadKill(pthread_t thread, int sig) {
    if (pthread_equal(thread, pthread_self())) {
        if (Ember8BShouldIgnore("pthread_kill-self", sig, (uintptr_t)__builtin_return_address(0))) return 0;
    }
    return -1;
}

static void Ember8BHookTerminate(void) {
    if (Ember8BShouldIgnore("std::terminate", 0, (uintptr_t)__builtin_return_address(0))) return;
    Ember8BAllowExit(134);
}

static void Ember8BRebindImage(const mach_header_u *mh) {
    if (!mh) return;
    litehook_rebind_symbol(mh, exit, Ember8BHookExit, nil);
    litehook_rebind_symbol(mh, _Exit, Ember8BHook_Exit, nil);
    litehook_rebind_symbol(mh, _exit, Ember8BHook_exit, nil);
    litehook_rebind_symbol(mh, abort, Ember8BHookAbort, nil);
    litehook_rebind_symbol(mh, raise, Ember8BHookRaise, nil);
    litehook_rebind_symbol(mh, kill, Ember8BHookKill, nil);
    if (Ember8BRealTerminate) {
        litehook_rebind_symbol(mh, Ember8BRealTerminate, Ember8BHookTerminate, nil);
    }
}

static void Ember8BRebindAllImages(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        Ember8BRebindImage((const mach_header_u *)_dyld_get_image_header(i));
    }
}

static void Ember8BImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    if (!Ember8BArmed) return;
    Ember8BRebindImage((const mach_header_u *)header);
}

static void EmberEightBallCompatibilityPrepare(NSBundle *bundle, NSDictionary *settings, NSString *documents) {
    if (![bundle.bundleIdentifier isEqualToString:@"com.miniclip.8ballpoolmult"] ||
        [settings[@"EmberEightBallCompatibilityDisabled"] boolValue]) return;
    Ember8BLogFD = open([[documents stringByAppendingPathComponent:@"EmberEightBallCompat.log"] fileSystemRepresentation],
                        O_WRONLY | O_CREAT | O_TRUNC, 0600);
    Ember8BRealExit = exit;
    Ember8BReal_Exit = _Exit;
    Ember8BReal_exit = _exit;
    Ember8BRealAbort = abort;
    Ember8BRealRaise = raise;
    Ember8BRealKill = kill;
    Ember8BRealTerminate = dlsym(RTLD_DEFAULT, "_ZSt9terminatev");
    Ember8BArmed = true;
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, exit, Ember8BHookExit, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, _Exit, Ember8BHook_Exit, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, _exit, Ember8BHook_exit, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, abort, Ember8BHookAbort, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, raise, Ember8BHookRaise, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, kill, Ember8BHookKill, nil);
    if (Ember8BRealTerminate) {
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, Ember8BRealTerminate, Ember8BHookTerminate, nil);
    }
    _dyld_register_func_for_add_image(Ember8BImageAdded);
    Ember8BLog("56.29.2 terminate gate armed before guest load");
}

static void EmberEightBallCompatibilityGuestLoaded(void) {
    if (!Ember8BArmed) return;
    Ember8BRebindAllImages();
    Ember8BLog("terminate gate rebound after guest load");
    // GOT rebind misses lazy binds. Overwrite the libc prologues so the
    // first call cannot resolve past the gate.
    Ember8BLogPtr("hook exit", litehook_hook_function(exit, Ember8BHookExit));
    Ember8BLogPtr("hook _Exit", litehook_hook_function(_Exit, Ember8BHook_Exit));
    Ember8BLogPtr("hook _exit", litehook_hook_function(_exit, Ember8BHook_exit));
    Ember8BLogPtr("hook abort", litehook_hook_function(abort, Ember8BHookAbort));
    Ember8BLogPtr("hook raise", litehook_hook_function(raise, Ember8BHookRaise));
    Ember8BLogPtr("hook kill", litehook_hook_function(kill, Ember8BHookKill));
    Ember8BLogPtr("hook pthread_kill", litehook_hook_function(pthread_kill, Ember8BHookPthreadKill));
    if (Ember8BRealTerminate) {
        Ember8BLogPtr("hook terminate", litehook_hook_function(Ember8BRealTerminate, Ember8BHookTerminate));
    }
    Ember8BLog("libc terminate prologues overwritten");
}
#else
static void EmberEightBallCompatibilityPrepare(NSBundle *bundle, NSDictionary *settings, NSString *documents) {}
static void EmberEightBallCompatibilityGuestLoaded(void) {}
#endif
