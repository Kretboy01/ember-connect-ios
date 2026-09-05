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
static void (*Ember8BRealObjcTerminate)(void);
static int (*Ember8BRealPthreadKill)(pthread_t, int);
static int (*Ember8BRealPthreadKillNP)(int, int);
static long (*Ember8BRealSyscall)(long, long, long, long, long, long, long, long);
static void *Ember8BAbortPayload;

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
    if (Ember8BRealPthreadKill) return Ember8BRealPthreadKill(thread, sig);
    return -1;
}

static void Ember8BHookTerminate(void) {
    if (Ember8BShouldIgnore("std::terminate", 0, (uintptr_t)__builtin_return_address(0))) return;
    Ember8BAllowExit(134);
}

static void Ember8BHookObjcTerminate(void) {
    if (Ember8BShouldIgnore("objc_terminate", 0, (uintptr_t)__builtin_return_address(0))) return;
    Ember8BAllowExit(134);
}

static long Ember8BHookSyscall(long number, long a1, long a2, long a3, long a4, long a5, long a6, long a7) {
    if (number == SYS_exit) {
        if (Ember8BShouldIgnore("syscall-exit", (int)a1, (uintptr_t)__builtin_return_address(0))) return 0;
        Ember8BAllowExit((int)a1);
    }
    if (number == SYS_kill && (a1 == (long)getpid() || a1 == 0 || a1 == -1)) {
        if (Ember8BShouldIgnore("syscall-kill", (int)a2, (uintptr_t)__builtin_return_address(0))) return 0;
    }
    if (Ember8BRealSyscall) return Ember8BRealSyscall(number, a1, a2, a3, a4, a5, a6, a7);
    return -1;
}

static int Ember8BHookPthreadKillNP(int thread, int sig) {
    if (Ember8BShouldIgnore("__pthread_kill", sig, (uintptr_t)__builtin_return_address(0))) return 0;
    if (Ember8BRealPthreadKillNP) return Ember8BRealPthreadKillNP(thread, sig);
    return -1;
}

static void Ember8BRebindNamed(const mach_header_u *mh, void *replacee, void *replacement) {
    if (mh && replacee && replacement) litehook_rebind_symbol(mh, replacee, replacement, nil);
}

static void Ember8BRebindImage(const mach_header_u *mh) {
    if (!mh) return;
    Ember8BRebindNamed(mh, exit, Ember8BHookExit);
    Ember8BRebindNamed(mh, _Exit, Ember8BHook_Exit);
    Ember8BRebindNamed(mh, _exit, Ember8BHook_exit);
    Ember8BRebindNamed(mh, abort, Ember8BHookAbort);
    Ember8BRebindNamed(mh, raise, Ember8BHookRaise);
    Ember8BRebindNamed(mh, kill, Ember8BHookKill);
    Ember8BRebindNamed(mh, pthread_kill, Ember8BHookPthreadKill);
    Ember8BRebindNamed(mh, Ember8BRealTerminate, Ember8BHookTerminate);
    Ember8BRebindNamed(mh, Ember8BRealObjcTerminate, Ember8BHookObjcTerminate);
    Ember8BRebindNamed(mh, Ember8BRealPthreadKillNP, Ember8BHookPthreadKillNP);
    Ember8BRebindNamed(mh, Ember8BRealSyscall, Ember8BHookSyscall);
    Ember8BRebindNamed(mh, Ember8BAbortPayload, Ember8BHookAbort);
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
    Ember8BRealPthreadKill = pthread_kill;
    Ember8BRealTerminate = dlsym(RTLD_DEFAULT, "_ZSt9terminatev");
    Ember8BRealObjcTerminate = dlsym(RTLD_DEFAULT, "objc_terminate");
    Ember8BRealPthreadKillNP = dlsym(RTLD_DEFAULT, "__pthread_kill");
    Ember8BRealSyscall = dlsym(RTLD_DEFAULT, "syscall");
    Ember8BAbortPayload = dlsym(RTLD_DEFAULT, "abort_with_payload");
    if (!Ember8BAbortPayload) Ember8BAbortPayload = dlsym(RTLD_DEFAULT, "__abort_with_payload");
    Ember8BArmed = true;
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, exit, Ember8BHookExit, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, _Exit, Ember8BHook_Exit, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, _exit, Ember8BHook_exit, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, abort, Ember8BHookAbort, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, raise, Ember8BHookRaise, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, kill, Ember8BHookKill, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, pthread_kill, Ember8BHookPthreadKill, nil);
    if (Ember8BRealTerminate) litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, Ember8BRealTerminate, Ember8BHookTerminate, nil);
    if (Ember8BRealObjcTerminate) litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, Ember8BRealObjcTerminate, Ember8BHookObjcTerminate, nil);
    if (Ember8BRealPthreadKillNP) litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, Ember8BRealPthreadKillNP, Ember8BHookPthreadKillNP, nil);
    if (Ember8BRealSyscall) litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, Ember8BRealSyscall, Ember8BHookSyscall, nil);
    if (Ember8BAbortPayload) litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, Ember8BAbortPayload, Ember8BHookAbort, nil);
    _dyld_register_func_for_add_image(Ember8BImageAdded);
    Ember8BLog("56.29.2 terminate gate armed before guest load");
    Ember8BLogPtr("syscall", (uintptr_t)Ember8BRealSyscall);
    Ember8BLogPtr("pthread_kill_np", (uintptr_t)Ember8BRealPthreadKillNP);
}

static void EmberEightBallCompatibilityGuestLoaded(const char *guestExec) {
    if (!Ember8BArmed) return;
    Ember8BRebindAllImages();
    // Force the guest's remaining lazy binds so GOT slots hold real
    // syscall/exit, then patch those slots. Do not write libsystem TEXT.
    if (guestExec) dlopen(guestExec, RTLD_NOW | RTLD_NOLOAD);
    Ember8BRebindAllImages();
    Ember8BLog("terminate gate rebound after guest load");
}
#else
static void EmberEightBallCompatibilityPrepare(NSBundle *bundle, NSDictionary *settings, NSString *documents) {}
static void EmberEightBallCompatibilityGuestLoaded(const char *guestExec) { (void)guestExec; }
#endif
