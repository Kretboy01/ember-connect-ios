// GettingOverIt.m — Ember Connect practice controls for Getting Over It.
//
// # What went wrong before this rewrite
//
// The previous build never worked because IL2CPP resolution was a one-shot
// inside a `dispatch_once` in `+sharedController`, and that ran the moment the
// tweak's constructor did. UnityFramework is not loaded that early — Unity's
// framework link is lazy, resolved by the game's own bootstrap after
// `main` — so every icall lookup returned NULL and stayed NULL for the rest
// of the session. The tick then called `applyTimeScale` and `applyGravity`
// with nothing behind them.
//
// It also called `usleep()` on the main thread every frame to fake slow
// motion, which stalls the render loop without actually slowing the Unity
// engine, and used `dlopen("UnityFramework.framework/UnityFramework", …)`,
// which does not resolve at all when the framework is under `@rpath` inside
// the app bundle.
//
// # Design of the new resolver
//
// Resolution is now a **repeating attempt** driven from `tick:`, gated by a
// state flag so it stops as soon as it succeeds. Handles are opened by
// absolute path from `NSBundle.mainBundle.privateFrameworksPath`, which is
// the only place the game's Unity framework actually lives. Once icalls are
// found, `applyTimeScale` / `applyGravity` are pushed once immediately and
// then any time the user changes a setting.
//
// Frame pacing is gone. Slowing time is done through `Time::set_timeScale` on
// the Unity side, which is the only place slow motion actually means anything
// for the game's physics; slowing the render loop achieved neither.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>

#define EMBER_GOI_BUTTON_TAG 0xFB003
#define EMBER_GOI_HUD_TAG    0xFB004

#pragma mark - Unity / IL2CPP surface

typedef void Il2CppDomain;
typedef void Il2CppAssembly;
typedef void Il2CppImage;
typedef void Il2CppClass;
typedef void MethodInfo;
typedef void Il2CppObject;
typedef void Il2CppThread;
typedef void Il2CppString;

typedef struct { float x; float y; float z; } EmberVector3;
typedef struct { float x; float y; } EmberVector2;

typedef void  (*SetTimeScaleFunc)(float);
typedef float (*GetTimeScaleFunc)(void);
typedef void  (*SetFixedDeltaTimeFunc)(float);
typedef void  (*Set3DGravityDirectFunc)(EmberVector3);
typedef void  (*Set3DGravityInjectedFunc)(EmberVector3 *);
typedef void  (*Set2DGravityDirectFunc)(EmberVector2);
typedef void  (*Set2DGravityInjectedFunc)(EmberVector2 *);
typedef void  (*UnitySendMessageFunc)(const char *, const char *, const char *);

static void         *(*g_il2cpp_resolve_icall)(const char *)                              = NULL;
static Il2CppDomain *(*g_il2cpp_domain_get)(void)                                         = NULL;
static Il2CppThread *(*g_il2cpp_thread_attach)(Il2CppDomain *)                            = NULL;
static Il2CppAssembly **(*g_il2cpp_domain_get_assemblies)(const Il2CppDomain *, size_t *) = NULL;
static const Il2CppImage *(*g_il2cpp_assembly_get_image)(const Il2CppAssembly *)          = NULL;
static Il2CppClass *(*g_il2cpp_class_from_name)(const Il2CppImage *, const char *, const char *)   = NULL;
static const MethodInfo *(*g_il2cpp_class_get_method_from_name)(Il2CppClass *, const char *, int)  = NULL;
static Il2CppObject *(*g_il2cpp_runtime_invoke)(const MethodInfo *, void *, void **, Il2CppObject **) = NULL;
static Il2CppString *(*g_il2cpp_string_new)(const char *)                                 = NULL;

// Mono fallback (older Unity). Exposes the same conceptual API under a
// different set of names; we probe for it in case IL2CPP is not present.
static void *(*g_mono_get_root_domain)(void)                     = NULL;
static void *(*g_mono_domain_get)(void)                          = NULL;
static void *(*g_mono_thread_attach)(void *)                     = NULL;

static UnitySendMessageFunc      g_unity_send_message         = NULL;

// Unity C API — often exported from Unity iOS builds even when the
// IL2CPP internals are stripped/hidden. These give us pause/resume
// and, indirectly, the ability to drive game objects.
typedef void (*UnityPauseFunc)(int);
typedef void (*UnitySetTargetFPSFunc)(int);
static UnityPauseFunc        g_unity_pause          = NULL;
static UnitySetTargetFPSFunc g_unity_set_target_fps = NULL;
static SetTimeScaleFunc          g_set_time_scale             = NULL;
static GetTimeScaleFunc          g_get_time_scale             = NULL;
static SetFixedDeltaTimeFunc     g_set_fixed_delta_time       = NULL;
static Set3DGravityInjectedFunc  g_set_3d_gravity_injected    = NULL;
static Set3DGravityDirectFunc    g_set_3d_gravity_direct      = NULL;
static Set2DGravityInjectedFunc  g_set_2d_gravity_injected    = NULL;
static Set2DGravityDirectFunc    g_set_2d_gravity_direct      = NULL;

// Reflection fallback: when icalls are not exported.
static const MethodInfo *g_set_time_scale_method       = NULL;
static const MethodInfo *g_set_fixed_delta_time_method = NULL;
static const MethodInfo *g_set_3d_gravity_method       = NULL;
static const MethodInfo *g_set_2d_gravity_method       = NULL;
static const MethodInfo *g_load_scene_int_method       = NULL;
static const MethodInfo *g_load_scene_string_method    = NULL;

/// Reports whether the icall pointer table is populated enough to control the
/// game. Reflection alone is not counted, since `runtime_invoke` needs a
/// managed thread and much heavier setup.
static BOOL EmberIcallsResolved(void) {
    return g_set_time_scale != NULL || g_set_3d_gravity_direct != NULL || g_set_3d_gravity_injected != NULL;
}

static BOOL EmberReflectionResolved(void) {
    return g_set_time_scale_method != NULL || g_set_3d_gravity_method != NULL;
}

static NSString *g_resolvedSource = @"none";
static NSMutableString *g_diagLog;
static NSString *g_diagPath;
static void EmberLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void EmberLog(NSString *fmt, ...) {
    if (!g_diagLog) g_diagLog = [NSMutableString new];
    va_list args; va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *stamp = [NSString stringWithFormat:@"[%.2f] %@\n",
                       CACurrentMediaTime(), line];
    NSLog(@"[Ember/GOI] %@", line);
    @synchronized(g_diagLog) { [g_diagLog appendString:stamp]; }
    if (!g_diagPath) {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (dirs.count > 0) {
            NSString *dir = [dirs.firstObject stringByAppendingPathComponent:@"EmberConnect"];
            [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            g_diagPath = [dir stringByAppendingPathComponent:@"GettingOverIt-diag.log"];
        }
    }
    if (g_diagPath) {
        @synchronized(g_diagLog) {
            [g_diagLog writeToFile:g_diagPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
}
static NSMutableSet<NSString *> *g_resolvedIcalls;

#pragma mark - Symbol probing

/// Tries to fill in every not-yet-known symbol from `handle`.
///
/// Called for every candidate handle, so unfound symbols get another chance
/// from the next one. `label` is recorded only on the first successful
/// resolution — that is what tells us where the exports actually live.
static void EmberProbeHandle(void *handle, NSString *label) {
    if (!handle) return;

#define TRY(var, name) do { \
    if (!var) { \
        void *sym = dlsym(handle, name); \
        if (sym) { \
            var = sym; \
            if ([g_resolvedSource isEqualToString:@"none"]) g_resolvedSource = label; \
        } \
    } \
} while (0)

    TRY(g_il2cpp_resolve_icall,               "il2cpp_resolve_icall");
    TRY(g_il2cpp_domain_get,                  "il2cpp_domain_get");
    TRY(g_il2cpp_thread_attach,               "il2cpp_thread_attach");
    TRY(g_il2cpp_domain_get_assemblies,       "il2cpp_domain_get_assemblies");
    TRY(g_il2cpp_assembly_get_image,          "il2cpp_assembly_get_image");
    TRY(g_il2cpp_class_from_name,             "il2cpp_class_from_name");
    TRY(g_il2cpp_class_get_method_from_name,  "il2cpp_class_get_method_from_name");
    TRY(g_il2cpp_runtime_invoke,              "il2cpp_runtime_invoke");
    TRY(g_il2cpp_string_new,                  "il2cpp_string_new");
    TRY(g_unity_send_message,                 "UnitySendMessage");
    TRY(g_unity_pause,                        "UnityPause");
    TRY(g_unity_set_target_fps,               "UnitySetTargetFPS");

    TRY(g_mono_get_root_domain,               "mono_get_root_domain");
    TRY(g_mono_domain_get,                    "mono_domain_get");
    TRY(g_mono_thread_attach,                 "mono_thread_attach");

#undef TRY
}

/// Every framework the game bundle carries, at absolute paths.
///
/// `dlopen("UnityFramework.framework/UnityFramework")` — the previous
/// resolver's approach — never finds anything, because the framework lives
/// under `@rpath`. The bundle knows the real path; use it.
static NSArray<NSString *> *EmberFrameworkCandidates(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    NSString *root = NSBundle.mainBundle.privateFrameworksPath;
    if (!root) return out;

    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
    for (NSString *name in names) {
        if (![name.pathExtension isEqualToString:@"framework"]) continue;
        NSString *base = [name stringByDeletingPathExtension];
        [out addObject:[[root stringByAppendingPathComponent:name] stringByAppendingPathComponent:base]];
    }
    return out;
}


// Walks the main executable's Mach-O symbol table looking for hidden
// symbols by name. dlsym only returns *exported* symbols; IL2CPP in a
// stripped Unity build is `private_extern` and dlsym passes it over, but
// LC_SYMTAB still lists it. Adding this recovers those addresses.
static void *EmberFindHiddenSymbol(const char *name) {
    if (!name) return NULL;
    // Main executable is index 0 in dyld's image list.
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!header) return NULL;
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);

    const uint8_t *cmd_ptr = (const uint8_t *)(header + 1);
    const struct symtab_command *symtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct segment_command_64 *text = NULL;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd_ptr;
        if (lc->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg =
                (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, "__LINKEDIT") == 0) linkedit = seg;
            else if (strcmp(seg->segname, "__TEXT") == 0) text = seg;
        }
        cmd_ptr += lc->cmdsize;
    }
    if (!symtab || !linkedit || !text) return NULL;

    // The symbol table and string table live inside __LINKEDIT. Their file
    // offsets are absolute; converting to a runtime address needs the
    // difference between __LINKEDIT's vmaddr and fileoff, plus the slide.
    uintptr_t base = (uintptr_t)linkedit->vmaddr - (uintptr_t)linkedit->fileoff + slide;
    const struct nlist_64 *symbols = (const struct nlist_64 *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);

    // Some Unity toolchains prepend an underscore on iOS.
    char underscored[256];
    snprintf(underscored, sizeof underscored, "_%s", name);

    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        uint32_t strx = symbols[i].n_un.n_strx;
        if (strx == 0) continue;
        const char *sym_name = strings + strx;
        if (strcmp(sym_name, name) == 0 || strcmp(sym_name, underscored) == 0) {
            uint64_t value = symbols[i].n_value;
            if (value == 0) continue;
            return (void *)((uintptr_t)value + slide);
        }
    }
    return NULL;
}

// Fills in the same globals `EmberProbeHandle` fills, but from the symbol
// table walk. Lets IL2CPP work even in Unity builds with stripped exports.
static void EmberFillFromSymbolTable(void) {
#define TRY_SYM(var, name) do { \
    if (!var) { \
        void *sym = EmberFindHiddenSymbol(name); \
        if (sym) { \
            var = sym; \
            if ([g_resolvedSource isEqualToString:@"none"]) g_resolvedSource = @"symtab"; \
        } \
    } \
} while (0)

    TRY_SYM(g_il2cpp_resolve_icall,              "il2cpp_resolve_icall");
    TRY_SYM(g_il2cpp_domain_get,                 "il2cpp_domain_get");
    TRY_SYM(g_il2cpp_thread_attach,              "il2cpp_thread_attach");
    TRY_SYM(g_il2cpp_domain_get_assemblies,      "il2cpp_domain_get_assemblies");
    TRY_SYM(g_il2cpp_assembly_get_image,         "il2cpp_assembly_get_image");
    TRY_SYM(g_il2cpp_class_from_name,            "il2cpp_class_from_name");
    TRY_SYM(g_il2cpp_class_get_method_from_name, "il2cpp_class_get_method_from_name");
    TRY_SYM(g_il2cpp_runtime_invoke,             "il2cpp_runtime_invoke");
    TRY_SYM(g_il2cpp_string_new,                 "il2cpp_string_new");

    TRY_SYM(g_unity_send_message,                "UnitySendMessage");
    TRY_SYM(g_unity_pause,                       "UnityPause");
    TRY_SYM(g_unity_set_target_fps,              "UnitySetTargetFPS");

#undef TRY_SYM
}

static void EmberProbeIL2CPPSymbols(void) {
    // The symtab walk finds hidden Unity/IL2CPP exports first — cheapest and
    // works even when the game strips its dynamic export table. Everything
    // below stays as a fallback and covers Unity/Mono builds that do export.
    EmberFillFromSymbolTable();

    // Any of these may contain the symbols. Try each even after some are
    // found, so a mixed-load process gets its pointers filled in.
    EmberProbeHandle(RTLD_DEFAULT,           @"RTLD_DEFAULT");
    EmberProbeHandle(RTLD_MAIN_ONLY,         @"main executable");
    EmberProbeHandle(RTLD_NEXT,              @"next");

    void *self_handle = dlopen(NULL, RTLD_LAZY | RTLD_NOLOAD);
    EmberProbeHandle(self_handle, @"self (no-load)");
    // dlopen(NULL) does not add a reference, so this dlclose is a no-op —
    // included for the analyser's sake.
    if (self_handle) dlclose(self_handle);

    // First pass: probe every already-loaded dyld image.
    //
    // The bundle-path scan the previous version used returned nothing at
    // all in a LiveContainer guest — see the diag log. Iterating the real
    // image list finds Unity wherever it landed, and does not need us to
    // know the guest's on-disk layout.
    uint32_t imageCount = _dyld_image_count();
    static uint32_t s_lastLogged = 0;
    BOOL logImages = (imageCount != s_lastLogged);
    s_lastLogged = imageCount;
    if (logImages) EmberLog(@"dyld images: %u", imageCount);
    // On the very first attempt, dump every non-system image name so we can
    // see what engine actually shipped with the game -- this is the sanity
    // check for "is it Unity at all?". System paths are filtered out because
    // they add nothing to the diagnosis and would flood the log.
    static BOOL s_dumpedAll = NO;
    if (!s_dumpedAll) {
        s_dumpedAll = YES;
        for (uint32_t i = 0; i < imageCount; i++) {
            const char *cname = _dyld_get_image_name(i);
            if (!cname) continue;
            if (strncmp(cname, "/usr/lib/", 9) == 0 ||
                strncmp(cname, "/System/", 8) == 0 ||
                strstr(cname, "/PrivateFrameworks/") ||
                strstr(cname, "UIKitCore")) continue;
            EmberLog(@"non-system image: %s", cname);
        }

        // Enumerate Objective-C classes defined by the game and its bundled
        // libraries. Filters out anything defined by system images (identified
        // by the class's `class_getImageName`, which points at the dylib the
        // class lives in). What is left is the game's own hooking surface —
        // real classes and methods we can swizzle, in a game that has no
        // Unity runtime for us to reach into.
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        int shown = 0;
        for (unsigned int i = 0; i < classCount && shown < 200; i++) {
            Class cls = classes[i];
            const char *img = class_getImageName(cls);
            if (!img) continue;
            if (strncmp(img, "/usr/lib/", 9) == 0 ||
                strncmp(img, "/System/", 8) == 0 ||
                strstr(img, "/PrivateFrameworks/") ||
                strstr(img, "LiveContainer") ||
                strstr(img, "CydiaSubstrate")) continue;
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(cls, &methodCount);
            if (methods) free(methods);
            EmberLog(@"class: %s (methods=%u img=%s)",
                     class_getName(cls), methodCount, strrchr(img, '/') ?: img);
            shown++;
        }
        if (classes) free(classes);
        EmberLog(@"class dump complete (shown=%d of %u)", shown, classCount);
    }
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *cname = _dyld_get_image_name(i);
        if (!cname) continue;
        NSString *name = [NSString stringWithUTF8String:cname];
        // Only re-open images whose names hint at the runtime we care about;
        // dlsym-scanning every image on every retry would be pointlessly
        // expensive.
        NSString *lower = name.lowercaseString;
        if (![lower containsString:@"unity"]      &&
            ![lower containsString:@"il2cpp"]      &&
            ![lower containsString:@"mono"]        &&
            ![lower containsString:@"gameassembly"] &&
            ![lower containsString:@"getting over"] &&
            ![lower containsString:@"foddy"]) {
            continue;
        }
        void *handle = dlopen(cname, RTLD_LAZY | RTLD_NOLOAD);
        if (logImages) EmberLog(@"probe %@ -> handle=%p", name.lastPathComponent, handle);
        EmberProbeHandle(handle, [NSString stringWithFormat:@"dyld: %@", name.lastPathComponent]);
    }

    // Second pass: framework directory scan, as a fallback in case the
    // engine dylib has an unusual name we did not filter for.
    for (NSString *path in EmberFrameworkCandidates()) {
        void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_NOLOAD);
        BOOL wasLoaded = handle != NULL;
        if (!handle) handle = dlopen(path.UTF8String, RTLD_LAZY);
        if (logImages) EmberLog(@"framework %@: loaded=%d handle=%p",
                                path.lastPathComponent, wasLoaded, handle);
        EmberProbeHandle(handle, [NSString stringWithFormat:@"framework: %@", path.lastPathComponent]);
    }
    if (logImages) {
        EmberLog(@"symbols: il2cpp_resolve_icall=%p domain_get=%p thread_attach=%p"
                  " mono_root=%p mono_domain=%p unitySend=%p unityPause=%p targetFPS=%p",
                 g_il2cpp_resolve_icall, g_il2cpp_domain_get, g_il2cpp_thread_attach,
                 g_mono_get_root_domain, g_mono_domain_get, g_unity_send_message,
                 g_unity_pause, g_unity_set_target_fps);
    }
}

static void EmberResolveMethods(void) {
    if (!g_il2cpp_domain_get || !g_il2cpp_domain_get_assemblies ||
        !g_il2cpp_assembly_get_image || !g_il2cpp_class_from_name ||
        !g_il2cpp_class_get_method_from_name) return;

    Il2CppDomain *domain = g_il2cpp_domain_get();
    if (!domain) return;

    size_t count = 0;
    Il2CppAssembly **assemblies = g_il2cpp_domain_get_assemblies(domain, &count);
    if (!assemblies || count == 0) return;

    for (size_t i = 0; i < count; i++) {
        const Il2CppImage *image = g_il2cpp_assembly_get_image(assemblies[i]);
        if (!image) continue;

        if (!g_set_time_scale_method) {
            Il2CppClass *cls = g_il2cpp_class_from_name(image, "UnityEngine", "Time");
            if (cls) {
                g_set_time_scale_method       = g_il2cpp_class_get_method_from_name(cls, "set_timeScale", 1);
                g_set_fixed_delta_time_method = g_il2cpp_class_get_method_from_name(cls, "set_fixedDeltaTime", 1);
            }
        }
        if (!g_set_3d_gravity_method) {
            Il2CppClass *cls = g_il2cpp_class_from_name(image, "UnityEngine", "Physics");
            if (cls) g_set_3d_gravity_method = g_il2cpp_class_get_method_from_name(cls, "set_gravity", 1);
        }
        if (!g_set_2d_gravity_method) {
            Il2CppClass *cls = g_il2cpp_class_from_name(image, "UnityEngine", "Physics2D");
            if (cls) g_set_2d_gravity_method = g_il2cpp_class_get_method_from_name(cls, "set_gravity", 1);
        }
        if (!g_load_scene_int_method || !g_load_scene_string_method) {
            Il2CppClass *cls = g_il2cpp_class_from_name(image, "UnityEngine.SceneManagement", "SceneManager");
            if (cls) {
                if (!g_load_scene_int_method)
                    g_load_scene_int_method = g_il2cpp_class_get_method_from_name(cls, "LoadScene", 1);
                if (!g_load_scene_string_method) {
                    // Same name, same overload count from IL2CPP's point of
                    // view; the returned pointer might correspond to either
                    // overload depending on which the linker kept. Store it
                    // separately so a caller can prefer the int form.
                    g_load_scene_string_method = g_il2cpp_class_get_method_from_name(cls, "LoadSceneAsync", 1);
                }
            }
        }
    }
}

static void EmberResolveIcalls(void) {
    if (!g_il2cpp_resolve_icall) return;

    void (^tryIcall)(const char *, void **) = ^(const char *name, void **slot) {
        if (*slot) return;
        void *fn = g_il2cpp_resolve_icall(name);
        if (fn) {
            *slot = fn;
            [g_resolvedIcalls addObject:[NSString stringWithUTF8String:name]];
        }
    };

    tryIcall("UnityEngine.Time::set_timeScale(System.Single)",              (void **)&g_set_time_scale);
    tryIcall("UnityEngine.Time::set_timeScale",                             (void **)&g_set_time_scale);
    tryIcall("UnityEngine.Time::get_timeScale()",                           (void **)&g_get_time_scale);
    tryIcall("UnityEngine.Time::get_timeScale",                             (void **)&g_get_time_scale);
    tryIcall("UnityEngine.Time::set_fixedDeltaTime(System.Single)",         (void **)&g_set_fixed_delta_time);
    tryIcall("UnityEngine.Time::set_fixedDeltaTime",                        (void **)&g_set_fixed_delta_time);

    tryIcall("UnityEngine.Physics::set_gravity_Injected(UnityEngine.Vector3&)",
             (void **)&g_set_3d_gravity_injected);
    tryIcall("UnityEngine.Physics::set_gravity(UnityEngine.Vector3)",       (void **)&g_set_3d_gravity_direct);
    tryIcall("UnityEngine.Physics::set_gravity",                            (void **)&g_set_3d_gravity_direct);

    tryIcall("UnityEngine.Physics2D::set_gravity_Injected(UnityEngine.Vector2&)",
             (void **)&g_set_2d_gravity_injected);
    tryIcall("UnityEngine.Physics2D::set_gravity(UnityEngine.Vector2)",     (void **)&g_set_2d_gravity_direct);
    tryIcall("UnityEngine.Physics2D::set_gravity",                          (void **)&g_set_2d_gravity_direct);
}

/// A single attempt at fully resolving. Returns YES once anything useful is in
/// place so the tick can stop retrying.
static BOOL EmberTryResolve(void) {
    EmberProbeIL2CPPSymbols();
    EmberResolveIcalls();
    EmberResolveMethods();
    return EmberIcallsResolved() || EmberReflectionResolved();
}

static void EmberEnsureThreadAttached(void) {
    if (g_il2cpp_thread_attach && g_il2cpp_domain_get) {
        Il2CppDomain *domain = g_il2cpp_domain_get();
        if (domain) g_il2cpp_thread_attach(domain);
    }
}

#pragma mark - Controller

@interface EmberGettingOverItController : NSObject
@property (nonatomic, weak)   UIButton      *button;
@property (nonatomic, weak)   UIWindow      *hostWindow;
@property (nonatomic, strong) UIView        *statsHud;
@property (nonatomic, strong) UILabel       *statsHudLabel;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) NSTimer       *keepAliveTimer;

@property (nonatomic, assign) NSInteger      frames;
@property (nonatomic, assign) CFTimeInterval fpsBucketStart;
@property (nonatomic, assign) double         currentFPS;
@property (nonatomic, assign) BOOL           resolved;
@property (nonatomic, assign) NSTimeInterval nextResolveAttempt;

@property (nonatomic, assign) CGFloat speedFactor;
@property (nonatomic, assign) CGFloat gravityFactor;
@property (nonatomic, assign) BOOL    ghostModeEnabled;
@property (nonatomic, assign) BOOL    superGripEnabled;
@property (nonatomic, assign) BOOL    statsHudEnabled;

+ (instancetype)sharedController;
@end

@implementation EmberGettingOverItController

+ (instancetype)sharedController {
    static EmberGettingOverItController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        controller = [EmberGettingOverItController new];
        g_resolvedIcalls = [NSMutableSet set];
        [controller loadSettings];

        controller.displayLink = [CADisplayLink displayLinkWithTarget:controller selector:@selector(tick:)];
        [controller.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    });
    return controller;
}

#pragma mark Settings

- (void)loadSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.speedFactor      = [defaults objectForKey:@"EmberGettingOverIt.speed"]   ? [defaults doubleForKey:@"EmberGettingOverIt.speed"]   : 1.0;
    self.gravityFactor    = [defaults objectForKey:@"EmberGettingOverIt.gravity"] ? [defaults doubleForKey:@"EmberGettingOverIt.gravity"] : 1.0;
    self.ghostModeEnabled = [defaults boolForKey:@"EmberGettingOverIt.ghostMode"];
    self.superGripEnabled = [defaults boolForKey:@"EmberGettingOverIt.superGrip"];
    self.statsHudEnabled  = [defaults boolForKey:@"EmberGettingOverIt.statsHud"];
}

- (void)saveSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:self.speedFactor   forKey:@"EmberGettingOverIt.speed"];
    [defaults setDouble:self.gravityFactor forKey:@"EmberGettingOverIt.gravity"];
    [defaults setBool:self.ghostModeEnabled forKey:@"EmberGettingOverIt.ghostMode"];
    [defaults setBool:self.superGripEnabled forKey:@"EmberGettingOverIt.superGrip"];
    [defaults setBool:self.statsHudEnabled  forKey:@"EmberGettingOverIt.statsHud"];
}

#pragma mark Applying game state

- (CGFloat)effectiveGravityFactor {
    if (self.ghostModeEnabled)     return 0.0;
    if (self.superGripEnabled)     return MIN(self.gravityFactor, 0.45);
    return self.gravityFactor;
}

- (void)applyTimeScale {
    if (!self.resolved) return;
    EmberEnsureThreadAttached();

    float speed = (float)self.speedFactor;
    float fixed = 0.02f * speed;

    if (g_set_time_scale) {
        g_set_time_scale(speed);
        if (g_set_fixed_delta_time) g_set_fixed_delta_time(fixed);
    } else if (g_set_time_scale_method && g_il2cpp_runtime_invoke) {
        void *args[1] = { &speed };
        Il2CppObject *exc = NULL;
        g_il2cpp_runtime_invoke(g_set_time_scale_method, NULL, args, &exc);
        if (g_set_fixed_delta_time_method) {
            void *dtArgs[1] = { &fixed };
            g_il2cpp_runtime_invoke(g_set_fixed_delta_time_method, NULL, dtArgs, &exc);
        }
    }
}

- (void)applyGravity {
    if (!self.resolved) return;
    EmberEnsureThreadAttached();

    float factor = (float)[self effectiveGravityFactor];

    EmberVector3 g3 = { 0.0f, -9.81f * factor, 0.0f };
    if (g_set_3d_gravity_injected) {
        g_set_3d_gravity_injected(&g3);
    } else if (g_set_3d_gravity_direct) {
        g_set_3d_gravity_direct(g3);
    } else if (g_set_3d_gravity_method && g_il2cpp_runtime_invoke) {
        void *args[1] = { &g3 };
        Il2CppObject *exc = NULL;
        g_il2cpp_runtime_invoke(g_set_3d_gravity_method, NULL, args, &exc);
    }

    // Also apply on the 2D world, in case the game uses it — Getting Over It
    // historically has, and there is no harm in setting both.
    EmberVector2 g2 = { 0.0f, -9.81f * factor };
    if (g_set_2d_gravity_injected) {
        g_set_2d_gravity_injected(&g2);
    } else if (g_set_2d_gravity_direct) {
        g_set_2d_gravity_direct(g2);
    } else if (g_set_2d_gravity_method && g_il2cpp_runtime_invoke) {
        void *args[1] = { &g2 };
        Il2CppObject *exc = NULL;
        g_il2cpp_runtime_invoke(g_set_2d_gravity_method, NULL, args, &exc);
    }
}

- (void)pushAllSettingsNow {
    [self applyTimeScale];
    [self applyGravity];
}

/// Reloads scene 0. Best-effort — Unity may reject a bare integer overload
/// depending on how the game was built.
- (void)reloadActiveScene {
    if (!self.resolved) return;
    EmberEnsureThreadAttached();
    if (g_load_scene_int_method && g_il2cpp_runtime_invoke) {
        int sceneIndex = 0;
        void *args[1] = { &sceneIndex };
        Il2CppObject *exc = NULL;
        g_il2cpp_runtime_invoke(g_load_scene_int_method, NULL, args, &exc);
    }
}

#pragma mark Frame tick

- (void)tick:(CADisplayLink *)link {
    // Frame counter with an initialised bucket start, so the first reading is
    // sane rather than reporting the ridiculous rate that comes from
    // `now - 0` on the very first tick.
    if (self.fpsBucketStart == 0) self.fpsBucketStart = link.timestamp;
    self.frames++;
    CFTimeInterval elapsed = link.timestamp - self.fpsBucketStart;
    if (elapsed >= 1.0) {
        self.currentFPS = self.frames / elapsed;
        self.frames = 0;
        self.fpsBucketStart = link.timestamp;
    }

    // Keep trying to resolve until we succeed. UnityFramework loads lazily
    // after the game's own `main` runs, so the first few hundred milliseconds
    // will nearly always fail — retrying is the whole point. Once resolved,
    // this branch is inert.
    if (!self.resolved && link.timestamp >= self.nextResolveAttempt) {
        if (EmberTryResolve()) {
            self.resolved = YES;
            EmberLog(@"resolved (icalls=%d reflection=%d source=%@)",
                     EmberIcallsResolved(), EmberReflectionResolved(), g_resolvedSource);
            [self pushAllSettingsNow];
        } else {
            // Aggressive early: retry every 150 ms for the first 6 s so Unity's
            // usual "load a few hundred ms after main" case is covered fast.
            // After that, back off to 500 ms to keep the display link out of dlsym.
            NSTimeInterval age = link.timestamp - self.fpsBucketStart;
            self.nextResolveAttempt = link.timestamp + (age < 6.0 ? 0.15 : 0.5);
        }
    }

    // Once a session, iOS may reset scene state (e.g. when the game itself
    // sets Time.timeScale back to 1 on a scene load). Cheap to re-push.
    if (self.resolved) {
        [self applyTimeScale];
        // Gravity is intentionally not pushed every frame — Unity's physics
        // world takes it as authoritative until something writes it again, and
        // pushing it every frame competes with the game's own respawn code.
    }

    if (self.statsHudEnabled && self.statsHudLabel && self.statsHud) {
        self.statsHud.hidden = NO;
        NSString *engine = EmberIcallsResolved()      ? [NSString stringWithFormat:@"icalls (%@)", g_resolvedSource]
                        : EmberReflectionResolved()   ? [NSString stringWithFormat:@"reflection (%@)", g_resolvedSource]
                                                      : @"waiting for Unity…";
        self.statsHudLabel.text = [NSString stringWithFormat:
            @"FPS: %.0f\nSpd: %.2gx  Grv: %.2gx\nEngine: %@\nGrip: %@  Ghost: %@",
            self.currentFPS, self.speedFactor, [self effectiveGravityFactor],
            engine,
            self.superGripEnabled ? @"ON" : @"OFF",
            self.ghostModeEnabled ? @"ON" : @"OFF"];
    } else if (self.statsHud) {
        self.statsHud.hidden = YES;
    }
}

#pragma mark UI plumbing

- (UIWindow *)guestWindow {
    UIWindow *best = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || !window.rootViewController) continue;
            if (window.windowLevel > UIWindowLevelNormal) continue;
            if (!best || window.isKeyWindow) best = window;
        }
    }
    return best ?: UIApplication.sharedApplication.keyWindow;
}

- (UIViewController *)topViewController {
    UIViewController *controller = self.hostWindow.rootViewController ?: [self guestWindow].rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller;
}

- (NSString *)markedTitle:(NSString *)title selected:(BOOL)selected {
    return [NSString stringWithFormat:@"%@ %@", selected ? @"✓" : @"  ", title];
}

- (void)updateButtonTitle {
    if (!self.button) return;
    NSString *title = (fabs(self.speedFactor - 1.0) < 0.01)
        ? @"EC 1x" : [NSString stringWithFormat:@"EC %.2gx", self.speedFactor];
    [self.button setTitle:title forState:UIControlStateNormal];
    BOOL active = fabs(self.speedFactor - 1.0)   >= 0.01
                || fabs(self.gravityFactor - 1.0) >= 0.01
                || self.ghostModeEnabled
                || self.superGripEnabled;
    self.button.backgroundColor = active
        ? [UIColor colorWithRed:0.98 green:0.38 blue:0.10 alpha:0.94]
        : [UIColor colorWithWhite:0.10 alpha:0.82];
}

#pragma mark Menu actions

- (void)setPracticeSpeed:(CGFloat)factor {
    self.speedFactor = factor;
    [self saveSettings];
    [self applyTimeScale];
    [self updateButtonTitle];
}

- (void)setPracticeGravity:(CGFloat)factor {
    self.gravityFactor = factor;
    [self saveSettings];
    [self applyGravity];
    [self updateButtonTitle];
}

- (void)resetAllTweaks {
    self.speedFactor      = 1.0;
    self.gravityFactor    = 1.0;
    self.ghostModeEnabled = NO;
    self.superGripEnabled = NO;
    [self saveSettings];
    [self pushAllSettingsNow];
    [self updateButtonTitle];
}

- (void)showSpeedMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController
        alertControllerWithTitle:@"Game Speed"
                         message:@"Sets UnityEngine.Time.timeScale — the whole simulation runs slower or faster."
                  preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    for (NSNumber *num in @[@0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @2.0]) {
        CGFloat val = num.doubleValue;
        NSString *name = (fabs(val - 1.0) < 0.01) ? @"1.0x (Normal)" : [NSString stringWithFormat:@"%.2gx", val];
        [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:name selected:fabs(self.speedFactor - val) < 0.01]
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) { [weakSelf setPracticeSpeed:val]; }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { [weakSelf tapped]; }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)showGravityMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController
        alertControllerWithTitle:@"Gravity Multiplier"
                         message:@"Scales UnityEngine.Physics.gravity. Ghost mode overrides to zero."
                  preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    for (NSNumber *num in @[@0.0, @0.25, @0.5, @0.75, @1.0, @1.5]) {
        CGFloat val = num.doubleValue;
        NSString *name = (fabs(val - 1.0) < 0.01) ? @"1.0x (Normal)"
                       : (val < 0.01)             ? @"0.0x (Zero-G Float)"
                                                  : [NSString stringWithFormat:@"%.2gx", val];
        [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:name selected:fabs(self.gravityFactor - val) < 0.01]
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) { [weakSelf setPracticeGravity:val]; }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { [weakSelf tapped]; }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)showProfilesMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Practice Profiles"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    void (^apply)(CGFloat, CGFloat, BOOL, BOOL) = ^(CGFloat s, CGFloat g, BOOL grip, BOOL ghost) {
        weakSelf.speedFactor      = s;
        weakSelf.gravityFactor    = g;
        weakSelf.superGripEnabled = grip;
        weakSelf.ghostModeEnabled = ghost;
        [weakSelf saveSettings];
        [weakSelf pushAllSettingsNow];
        [weakSelf updateButtonTitle];
    };

    [menu addAction:[UIAlertAction actionWithTitle:@"Easy Climb — 0.65x speed, 0.45x gravity, grip"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(0.65, 0.45, YES,  NO); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Moon Jump — 0.3x gravity"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(1.0,  0.3,  NO,   NO); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Zero-G Float — no gravity"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(1.0,  1.0,  NO,   YES); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Speed Run — 1.5x speed"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(1.5,  1.0,  NO,   NO); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Ultra Slow — 0.25x for tricky moves"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(0.25, 1.0,  NO,   NO); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { [weakSelf tapped]; }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)tapped {
    UIViewController *presenter = [self topViewController];
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return;

    NSString *header = self.resolved
        ? @"Practice controls & physics mods."
        : @"Waiting for Unity to finish loading. Menu is live but changes only apply once the engine is ready.";

    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Getting Over It Tools"
                                                                  message:header
                                                           preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    NSString *speedText = (fabs(self.speedFactor - 1.0) < 0.01) ? @"Normal (1.0x)" : [NSString stringWithFormat:@"%.2gx", self.speedFactor];
    [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Speed: %@  ▶", speedText]
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { [weakSelf showSpeedMenu]; }]];
    NSString *gravText = (fabs(self.gravityFactor - 1.0) < 0.01) ? @"Normal (1.0x)"
                       : (self.gravityFactor < 0.01)             ? @"Zero-G"
                                                                 : [NSString stringWithFormat:@"%.2gx", self.gravityFactor];
    [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Gravity: %@  ▶", gravText]
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { [weakSelf showGravityMenu]; }]];

    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Ghost Mode (zero-G float)" selected:self.ghostModeEnabled]
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        weakSelf.ghostModeEnabled = !weakSelf.ghostModeEnabled;
        [weakSelf saveSettings]; [weakSelf applyGravity]; [weakSelf updateButtonTitle];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Super Grip (touch assist)" selected:self.superGripEnabled]
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        weakSelf.superGripEnabled = !weakSelf.superGripEnabled;
        [weakSelf saveSettings]; [weakSelf applyGravity]; [weakSelf updateButtonTitle];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Live Stats HUD" selected:self.statsHudEnabled]
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        weakSelf.statsHudEnabled = !weakSelf.statsHudEnabled;
        [weakSelf saveSettings]; [weakSelf updateButtonTitle];
    }]];

    [menu addAction:[UIAlertAction actionWithTitle:@"Practice Profiles  ▶" style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { [weakSelf showProfilesMenu]; }]];

    [menu addAction:[UIAlertAction actionWithTitle:@"Restart / Reload Scene" style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { [weakSelf reloadActiveScene]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Force Re-Resolve Unity" style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        weakSelf.resolved = NO;
        weakSelf.nextResolveAttempt = 0;
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Reset all mods" style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *a) { [weakSelf resetAllTweaks]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];

    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

#pragma mark Attach

- (void)install {
    UIWindow *host = [self guestWindow];
    if (!host) return;

    UIView *existing = [host viewWithTag:EMBER_GOI_BUTTON_TAG];
    if (existing && [existing isKindOfClass:UIButton.class]) {
        self.button = (UIButton *)existing;
        [host bringSubviewToFront:self.button];
        if (self.statsHud) [host bringSubviewToFront:self.statsHud];
        [self updateButtonTitle];
        return;
    }

    [self.button removeFromSuperview];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = EMBER_GOI_BUTTON_TAG;
    button.frame = CGRectMake(MAX(8, CGRectGetWidth(host.bounds) - 84),
                              MAX(8, CGRectGetHeight(host.bounds) - 108), 72, 40);
    button.autoresizingMask  = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    button.layer.cornerRadius = 12;
    button.layer.borderWidth  = 1;
    button.layer.borderColor  = [UIColor colorWithWhite:1 alpha:0.24].CGColor;
    button.layer.shadowColor  = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.3;
    button.layer.shadowRadius  = 4;
    button.tintColor = UIColor.whiteColor;
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font   = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold];
    button.accessibilityLabel = @"Getting Over It Tools menu";
    [button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];

    [host addSubview:button];
    [host bringSubviewToFront:button];
    self.button = button;
    self.hostWindow = host;

    if (!self.statsHud) {
        UIView *hud = [[UIView alloc] initWithFrame:CGRectMake(12, 44, 190, 92)];
        hud.tag = EMBER_GOI_HUD_TAG;
        hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65];
        hud.layer.cornerRadius = 8;
        hud.layer.borderWidth  = 1;
        hud.layer.borderColor  = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
        hud.userInteractionEnabled = NO;
        hud.hidden = YES;

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, 174, 84)];
        label.numberOfLines = 0;
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightMedium];
        [hud addSubview:label];
        self.statsHudLabel = label;
        self.statsHud = hud;
        [host addSubview:hud];
    } else {
        [host addSubview:self.statsHud];
        [host bringSubviewToFront:self.statsHud];
    }

    [self updateButtonTitle];
}

- (void)start {
    [self install];
    [self.keepAliveTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                          repeats:YES
                                                            block:^(NSTimer *timer) { [weakSelf install]; }];
}

- (void)stop {
    [self.keepAliveTimer invalidate];
    self.keepAliveTimer = nil;
}

@end

__attribute__((constructor))
static void EmberGettingOverItInit(void) {
    // Written before the runloop even exists, so its presence proves the
    // dylib got injected — the first thing to check when "nothing works".
    EmberLog(@"constructor ran; bundle=%@ exec=%s bundlePath=%@ frameworksPath=%@",
             NSBundle.mainBundle.bundleIdentifier,
             getprogname(),
             NSBundle.mainBundle.bundlePath,
             NSBundle.mainBundle.privateFrameworksPath);
    dispatch_async(dispatch_get_main_queue(), ^{
        EmberGettingOverItController *controller = [EmberGettingOverItController sharedController];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { [controller start]; }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { [controller stop]; }];
        [controller start];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [controller start]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [controller start]; });
    });
}
