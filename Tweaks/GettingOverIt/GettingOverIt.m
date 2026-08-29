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

static UnitySendMessageFunc      g_unity_send_message         = NULL;
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

static void EmberProbeIL2CPPSymbols(void) {
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

    for (NSString *path in EmberFrameworkCandidates()) {
        // RTLD_NOLOAD first: query without pulling the framework in, so we do
        // not affect the game's own loader sequence.
        void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_NOLOAD);
        if (!handle) {
            handle = dlopen(path.UTF8String, RTLD_LAZY);
        }
        EmberProbeHandle(handle, [NSString stringWithFormat:@"framework: %@", path.lastPathComponent]);
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
            [self pushAllSettingsNow];
        } else {
            // Back off a little to keep the display link out of dlsym.
            self.nextResolveAttempt = link.timestamp + 0.5;
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
