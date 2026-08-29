// GettingOverIt.m — Ember Connect practice controls for Getting Over It with Bennett Foddy.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

#define EMBER_GOI_BUTTON_TAG 0xFB003
#define EMBER_GOI_HUD_TAG    0xFB004

// MARK: - Unity / IL2CPP Types
typedef void Il2CppDomain;
typedef void Il2CppAssembly;
typedef void Il2CppImage;
typedef void Il2CppClass;
typedef void MethodInfo;
typedef void FieldInfo;
typedef void Il2CppObject;
typedef void Il2CppThread;

typedef struct { float x; float y; float z; } Vector3;
typedef struct { float x; float y; } Vector2;

typedef void (*SetTimeScaleFunc)(float);
typedef float (*GetTimeScaleFunc)(void);
typedef void (*SetFixedDeltaTimeFunc)(float);

typedef void (*Set3DGravityInjectedFunc)(Vector3*);
typedef void (*Set3DGravityDirectFunc)(Vector3);

typedef void (*Set2DGravityInjectedFunc)(Vector2*);
typedef void (*Set2DGravityDirectFunc)(Vector2);

typedef void (*UnitySendMessageFunc)(const char*, const char*, const char*);

// MARK: - Constants & Settings Keys
static NSString *const kEmberSpeedKey = @"EmberGettingOverIt.speed";
static NSString *const kEmberGravityKey = @"EmberGettingOverIt.gravity";
static NSString *const kEmberGhostModeKey = @"EmberGettingOverIt.ghostMode";
static NSString *const kEmberSuperGripKey = @"EmberGettingOverIt.superGrip";
static NSString *const kEmberStatsHudKey = @"EmberGettingOverIt.statsHud";

// MARK: - IL2CPP Function Pointers
static void* (*g_il2cpp_resolve_icall)(const char*) = NULL;
static Il2CppDomain* (*il2cpp_domain_get)(void) = NULL;
static Il2CppThread* (*il2cpp_thread_attach)(Il2CppDomain* domain) = NULL;
static Il2CppAssembly** (*il2cpp_domain_get_assemblies)(const Il2CppDomain* domain, size_t* size) = NULL;
static const Il2CppImage* (*il2cpp_assembly_get_image)(const Il2CppAssembly* assembly) = NULL;
static Il2CppClass* (*il2cpp_class_from_name)(const Il2CppImage* image, const char* namespaze, const char* name) = NULL;
static const MethodInfo* (*il2cpp_class_get_method_from_name)(Il2CppClass* klass, const char* name, int argsCount) = NULL;
static Il2CppObject* (*il2cpp_runtime_invoke)(const MethodInfo* method, void* obj, void** params, Il2CppObject** exc) = NULL;

static UnitySendMessageFunc g_UnitySendMessage = NULL;

static SetTimeScaleFunc g_setTimeScale = NULL;
static GetTimeScaleFunc g_getTimeScale = NULL;
static SetFixedDeltaTimeFunc g_setFixedDeltaTime = NULL;

static Set3DGravityInjectedFunc g_set3DGravityInjected = NULL;
static Set3DGravityDirectFunc g_set3DGravityDirect = NULL;

static Set2DGravityInjectedFunc g_set2DGravityInjected = NULL;
static Set2DGravityDirectFunc g_set2DGravityDirect = NULL;

static const MethodInfo* set_timeScale_method = NULL;
static const MethodInfo* set_fixedDeltaTime_method = NULL;
static const MethodInfo* set_3d_gravity_method = NULL;
static const MethodInfo* set_2d_gravity_method = NULL;
static const MethodInfo* load_scene_method = NULL;

static BOOL il2cpp_resolved = NO;
static NSString *resolvedSource = @"Native / IL2CPP";
static NSMutableDictionary *classesResolved;

// MARK: - Main Controller
@interface EmberGettingOverItController : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIButton *button;
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) UIView *statsHud;
@property (nonatomic, strong) UILabel *statsHudLabel;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) NSTimer *keepAliveTimer;
@property (nonatomic, strong) UIPanGestureRecognizer *assistPanGesture;

@property (nonatomic, assign) NSInteger frames;
@property (nonatomic, assign) CFTimeInterval lastFrameTime;
@property (nonatomic, assign) double currentFPS;

@property (nonatomic, assign) CGFloat speedFactor;
@property (nonatomic, assign) CGFloat gravityFactor;
@property (nonatomic, assign) BOOL ghostModeEnabled;
@property (nonatomic, assign) BOOL superGripEnabled;
@property (nonatomic, assign) BOOL statsHudEnabled;

+ (instancetype)sharedController;
@end

@implementation EmberGettingOverItController

+ (instancetype)sharedController {
    static EmberGettingOverItController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [EmberGettingOverItController new];
        [controller loadSettings];
        [controller resolveIL2CPP];
        
        controller.displayLink = [CADisplayLink displayLinkWithTarget:controller selector:@selector(tick:)];
        [controller.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
    return controller;
}

- (void)loadSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSNumber *savedSpeed = [defaults objectForKey:kEmberSpeedKey];
    self.speedFactor = savedSpeed ? savedSpeed.doubleValue : 1.0;
    NSNumber *savedGravity = [defaults objectForKey:kEmberGravityKey];
    self.gravityFactor = savedGravity ? savedGravity.doubleValue : 1.0;
    self.ghostModeEnabled = [defaults boolForKey:kEmberGhostModeKey];
    self.superGripEnabled = [defaults boolForKey:kEmberSuperGripKey];
    self.statsHudEnabled = [defaults boolForKey:kEmberStatsHudKey];
}

- (void)saveSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:self.speedFactor forKey:kEmberSpeedKey];
    [defaults setDouble:self.gravityFactor forKey:kEmberGravityKey];
    [defaults setBool:self.ghostModeEnabled forKey:kEmberGhostModeKey];
    [defaults setBool:self.superGripEnabled forKey:kEmberSuperGripKey];
    [defaults setBool:self.statsHudEnabled forKey:kEmberStatsHudKey];
}

static void TryProbeHandle(void *h, const char *sourceLabel) {
    if (!h) return;
    
    if (!g_il2cpp_resolve_icall) {
        g_il2cpp_resolve_icall = dlsym(h, "il2cpp_resolve_icall");
        if (g_il2cpp_resolve_icall) resolvedSource = [NSString stringWithUTF8String:sourceLabel];
    }
    if (!il2cpp_domain_get) {
        il2cpp_domain_get = dlsym(h, "il2cpp_domain_get");
        if (il2cpp_domain_get) resolvedSource = [NSString stringWithUTF8String:sourceLabel];
    }
    if (!il2cpp_thread_attach) il2cpp_thread_attach = dlsym(h, "il2cpp_thread_attach");
    if (!il2cpp_domain_get_assemblies) il2cpp_domain_get_assemblies = dlsym(h, "il2cpp_domain_get_assemblies");
    if (!il2cpp_assembly_get_image) il2cpp_assembly_get_image = dlsym(h, "il2cpp_assembly_get_image");
    if (!il2cpp_class_from_name) il2cpp_class_from_name = dlsym(h, "il2cpp_class_from_name");
    if (!il2cpp_class_get_method_from_name) il2cpp_class_get_method_from_name = dlsym(h, "il2cpp_class_get_method_from_name");
    if (!il2cpp_runtime_invoke) il2cpp_runtime_invoke = dlsym(h, "il2cpp_runtime_invoke");
    if (!g_UnitySendMessage) g_UnitySendMessage = dlsym(h, "UnitySendMessage");
}

static void ProbeIL2CPPSymbols(void) {
    if (g_il2cpp_resolve_icall && il2cpp_domain_get) return;
    
    // Check targeted handles only (avoid scanning entire shared cache)
    TryProbeHandle(RTLD_DEFAULT, "RTLD_DEFAULT");
    TryProbeHandle(dlopen(NULL, RTLD_LAZY), "Main Executable");
    TryProbeHandle(dlopen("UnityFramework.framework/UnityFramework", RTLD_LAZY), "UnityFramework");
    TryProbeHandle(dlopen("@rpath/UnityFramework.framework/UnityFramework", RTLD_LAZY), "UnityFramework");
}

- (void)ensureThreadAttached {
    if (il2cpp_thread_attach && il2cpp_domain_get) {
        Il2CppDomain *domain = il2cpp_domain_get();
        if (domain) {
            il2cpp_thread_attach(domain);
        }
    }
}

- (BOOL)resolveIL2CPP {
    ProbeIL2CPPSymbols();
    [self ensureThreadAttached];
    
    if (!classesResolved) {
        classesResolved = [NSMutableDictionary dictionary];
    }
    
    // 1. Direct icall resolution
    if (g_il2cpp_resolve_icall) {
        if (!g_setTimeScale) {
            g_setTimeScale = (SetTimeScaleFunc)g_il2cpp_resolve_icall("UnityEngine.Time::set_timeScale(System.Single)");
            if (!g_setTimeScale) g_setTimeScale = (SetTimeScaleFunc)g_il2cpp_resolve_icall("UnityEngine.Time::set_timeScale");
            if (g_setTimeScale) classesResolved[@"icall:Time::set_timeScale"] = @YES;
        }
        if (!g_getTimeScale) {
            g_getTimeScale = (GetTimeScaleFunc)g_il2cpp_resolve_icall("UnityEngine.Time::get_timeScale()");
            if (!g_getTimeScale) g_getTimeScale = (GetTimeScaleFunc)g_il2cpp_resolve_icall("UnityEngine.Time::get_timeScale");
            if (g_getTimeScale) classesResolved[@"icall:Time::get_timeScale"] = @YES;
        }
        if (!g_setFixedDeltaTime) {
            g_setFixedDeltaTime = (SetFixedDeltaTimeFunc)g_il2cpp_resolve_icall("UnityEngine.Time::set_fixedDeltaTime(System.Single)");
            if (!g_setFixedDeltaTime) g_setFixedDeltaTime = (SetFixedDeltaTimeFunc)g_il2cpp_resolve_icall("UnityEngine.Time::set_fixedDeltaTime");
            if (g_setFixedDeltaTime) classesResolved[@"icall:Time::set_fixedDeltaTime"] = @YES;
        }
        
        // 3D Physics
        if (!g_set3DGravityInjected && !g_set3DGravityDirect) {
            g_set3DGravityInjected = (Set3DGravityInjectedFunc)g_il2cpp_resolve_icall("UnityEngine.Physics::set_gravity_Injected(UnityEngine.Vector3&)");
            if (!g_set3DGravityInjected) g_set3DGravityDirect = (Set3DGravityDirectFunc)g_il2cpp_resolve_icall("UnityEngine.Physics::set_gravity(UnityEngine.Vector3)");
            if (!g_set3DGravityInjected && !g_set3DGravityDirect) g_set3DGravityDirect = (Set3DGravityDirectFunc)g_il2cpp_resolve_icall("UnityEngine.Physics::set_gravity");
            if (g_set3DGravityInjected || g_set3DGravityDirect) classesResolved[@"icall:Physics::set_gravity"] = @YES;
        }
        
        // 2D Physics
        if (!g_set2DGravityInjected && !g_set2DGravityDirect) {
            g_set2DGravityInjected = (Set2DGravityInjectedFunc)g_il2cpp_resolve_icall("UnityEngine.Physics2D::set_gravity_Injected(UnityEngine.Vector2&)");
            if (!g_set2DGravityInjected) g_set2DGravityDirect = (Set2DGravityDirectFunc)g_il2cpp_resolve_icall("UnityEngine.Physics2D::set_gravity(UnityEngine.Vector2)");
            if (g_set2DGravityInjected || g_set2DGravityDirect) classesResolved[@"icall:Physics2D::set_gravity"] = @YES;
        }
    }
    
    // 2. Reflection fallback via assemblies
    if (il2cpp_domain_get && il2cpp_class_from_name && il2cpp_runtime_invoke) {
        Il2CppDomain* domain = il2cpp_domain_get();
        if (domain) {
            size_t count = 0;
            Il2CppAssembly** assemblies = il2cpp_domain_get_assemblies ? il2cpp_domain_get_assemblies(domain, &count) : NULL;
            if (assemblies && count > 0) {
                for (size_t i = 0; i < count; i++) {
                    const Il2CppImage* image = il2cpp_assembly_get_image ? il2cpp_assembly_get_image(assemblies[i]) : NULL;
                    if (!image) continue;
                    
                    if (!set_timeScale_method) {
                        Il2CppClass* timeClass = il2cpp_class_from_name(image, "UnityEngine", "Time");
                        if (timeClass) {
                            set_timeScale_method = il2cpp_class_get_method_from_name(timeClass, "set_timeScale", 1);
                            set_fixedDeltaTime_method = il2cpp_class_get_method_from_name(timeClass, "set_fixedDeltaTime", 1);
                            if (set_timeScale_method) classesResolved[@"UnityEngine.Time"] = @YES;
                        }
                    }
                    if (!set_3d_gravity_method) {
                        Il2CppClass* physicsClass = il2cpp_class_from_name(image, "UnityEngine", "Physics");
                        if (physicsClass) {
                            set_3d_gravity_method = il2cpp_class_get_method_from_name(physicsClass, "set_gravity", 1);
                            if (set_3d_gravity_method) classesResolved[@"UnityEngine.Physics"] = @YES;
                        }
                    }
                    if (!set_2d_gravity_method) {
                        Il2CppClass* physics2DClass = il2cpp_class_from_name(image, "UnityEngine", "Physics2D");
                        if (physics2DClass) {
                            set_2d_gravity_method = il2cpp_class_get_method_from_name(physics2DClass, "set_gravity", 1);
                            if (set_2d_gravity_method) classesResolved[@"UnityEngine.Physics2D"] = @YES;
                        }
                    }
                    if (!load_scene_method) {
                        Il2CppClass* sceneManagerClass = il2cpp_class_from_name(image, "UnityEngine.SceneManagement", "SceneManager");
                        if (sceneManagerClass) {
                            load_scene_method = il2cpp_class_get_method_from_name(sceneManagerClass, "LoadScene", 1);
                            if (load_scene_method) classesResolved[@"UnityEngine.SceneManagement.SceneManager"] = @YES;
                        }
                    }
                }
            }
        }
    }
    
    il2cpp_resolved = (g_setTimeScale != NULL || set_timeScale_method != NULL || g_set3DGravityInjected != NULL || set_3d_gravity_method != NULL);
    [self updateStatusPlist];
    return il2cpp_resolved;
}

- (void)applyTimeScale {
    [self ensureThreadAttached];
    float speed = (float)self.speedFactor;
    float fixedDt = 0.02f * speed;
    
    if (g_setTimeScale) {
        g_setTimeScale(speed);
        if (g_setFixedDeltaTime) g_setFixedDeltaTime(fixedDt);
    } else if (set_timeScale_method && il2cpp_runtime_invoke) {
        void* args[1] = { &speed };
        Il2CppObject *exc = NULL;
        il2cpp_runtime_invoke(set_timeScale_method, NULL, args, &exc);
        
        if (set_fixedDeltaTime_method) {
            void* dtArgs[1] = { &fixedDt };
            il2cpp_runtime_invoke(set_fixedDeltaTime_method, NULL, dtArgs, &exc);
        }
    }
}

- (void)applyGravity {
    [self ensureThreadAttached];
    CGFloat factor = self.gravityFactor;
    if (self.ghostModeEnabled) {
        factor = 0.0;
    } else if (self.superGripEnabled) {
        factor = MIN(factor, 0.45);
    }
    
    // 3D PhysX Gravity
    Vector3 grav3 = { 0.0f, -9.81f * (float)factor, 0.0f };
    if (g_set3DGravityInjected) {
        g_set3DGravityInjected(&grav3);
    } else if (g_set3DGravityDirect) {
        g_set3DGravityDirect(grav3);
    } else if (set_3d_gravity_method && il2cpp_runtime_invoke) {
        void* args[1] = { &grav3 };
        Il2CppObject *exc = NULL;
        il2cpp_runtime_invoke(set_3d_gravity_method, NULL, args, &exc);
    }
    
    // 2D Box2D Gravity
    Vector2 grav2 = { 0.0f, -9.81f * (float)factor };
    if (g_set2DGravityInjected) {
        g_set2DGravityInjected(&grav2);
    } else if (g_set2DGravityDirect) {
        g_set2DGravityDirect(grav2);
    } else if (set_2d_gravity_method && il2cpp_runtime_invoke) {
        void* args[1] = { &grav2 };
        Il2CppObject *exc = NULL;
        il2cpp_runtime_invoke(set_2d_gravity_method, NULL, args, &exc);
    }
}

- (void)reloadActiveScene {
    [self ensureThreadAttached];
    if (load_scene_method && il2cpp_runtime_invoke) {
        int sceneIndex = 0;
        void* args[1] = { &sceneIndex };
        Il2CppObject *exc = NULL;
        il2cpp_runtime_invoke(load_scene_method, NULL, args, &exc);
    }
}

- (void)maintainEnabledTweaks {
    [self applyTimeScale];
    [self applyGravity];
}

- (void)tick:(CADisplayLink *)link {
    CFTimeInterval dt = link.timestamp - self.lastFrameTime;
    self.frames++;
    if (dt >= 1.0) {
        self.currentFPS = self.frames / dt;
        self.frames = 0;
        self.lastFrameTime = link.timestamp;
    }
    
    // Frame pacing / slow motion throttling
    if (self.speedFactor < 0.99) {
        // Regulate frame pacing when running in slow-mo
        useconds_t sleepTime = (useconds_t)((1.0 - self.speedFactor) * 12000.0);
        if (sleepTime > 0 && sleepTime < 30000) {
            usleep(sleepTime);
        }
    }
    
    [self maintainEnabledTweaks];
    
    if (self.statsHudEnabled && self.statsHudLabel && self.statsHud) {
        self.statsHud.hidden = NO;
        NSString *status = (g_setTimeScale || set_timeScale_method || g_set3DGravityInjected || set_3d_gravity_method) ? @"Active (PhysX)" : @"Active (Pacing)";
        self.statsHudLabel.text = [NSString stringWithFormat:@"FPS: %.0f\nSpd: %.2gx  Grv: %.2gx\nEngine: %@\nGrip: %@  Ghost: %@",
                                   self.currentFPS, self.speedFactor, self.gravityFactor,
                                   status,
                                   self.superGripEnabled ? @"ON" : @"OFF",
                                   self.ghostModeEnabled ? @"ON" : @"OFF"];
    } else if (self.statsHud) {
        self.statsHud.hidden = YES;
    }
}

- (UIWindow *)guestWindow {
    UIWindow *best = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || !window.rootViewController || window.windowLevel > UIWindowLevelNormal) continue;
            if (!best || window.isKeyWindow) best = window;
        }
    }
    if (best) return best;
    
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.hidden || !window.rootViewController || window.windowLevel > UIWindowLevelNormal) continue;
        if (!best || window.isKeyWindow) best = window;
    }
    if (best) return best;
    
    return UIApplication.sharedApplication.keyWindow;
}

- (UIViewController *)topViewController {
    UIViewController *controller = self.hostWindow.rootViewController;
    if (!controller) {
        UIWindow *window = [self guestWindow];
        controller = window.rootViewController;
    }
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller;
}

- (NSString *)markedTitle:(NSString *)title selected:(BOOL)selected {
    return [NSString stringWithFormat:@"%@ %@", selected ? @"✓" : @"  ", title];
}

- (void)updateButtonTitle {
    if (!self.button) return;
    NSString *title = (fabs(self.speedFactor - 1.0) < 0.01) ? @"EC 1x" : [NSString stringWithFormat:@"EC %.2gx", self.speedFactor];
    [self.button setTitle:title forState:UIControlStateNormal];
    BOOL active = (fabs(self.speedFactor - 1.0) >= 0.01) || (fabs(self.gravityFactor - 1.0) >= 0.01) || self.ghostModeEnabled || self.superGripEnabled;
    self.button.backgroundColor = active ? [UIColor colorWithRed:0.98 green:0.38 blue:0.10 alpha:0.94] : [UIColor colorWithWhite:0.10 alpha:0.82];
}

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
    self.speedFactor = 1.0;
    self.gravityFactor = 1.0;
    self.ghostModeEnabled = NO;
    self.superGripEnabled = NO;
    self.statsHudEnabled = NO;
    [self saveSettings];
    [self applyTimeScale];
    [self applyGravity];
    [self updateButtonTitle];
}

- (void)showSpeedMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Game Speed" message:@"Coordinates game simulation speed and frame pacing." preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    NSArray *speeds = @[@0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @2.0];
    for (NSNumber *spd in speeds) {
        CGFloat val = spd.doubleValue;
        NSString *name = (fabs(val - 1.0) < 0.01) ? @"1.0x (Normal)" : [NSString stringWithFormat:@"%.2gx", val];
        [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:name selected:fabs(self.speedFactor - val) < 0.01] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf setPracticeSpeed:val]; }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { [weakSelf tapped]; }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)showGravityMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Gravity Multiplier" message:@"Adjusts 3D PhysX gravity acceleration." preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    NSArray *gravities = @[@0.0, @0.25, @0.5, @0.75, @1.0, @1.5];
    for (NSNumber *num in gravities) {
        CGFloat val = num.doubleValue;
        NSString *name = (fabs(val - 1.0) < 0.01) ? @"1.0x (Normal)" : (val < 0.01 ? @"0.0x (Zero-G Float)" : [NSString stringWithFormat:@"%.2gx", val]);
        [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:name selected:fabs(self.gravityFactor - val) < 0.01] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf setPracticeGravity:val]; }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { [weakSelf tapped]; }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)showProfilesMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Practice Profiles" message:@"Presets for Getting Over It practice." preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [menu addAction:[UIAlertAction actionWithTitle:@"Easy Climb (0.65x Speed, 0.45x Low Gravity, Super Grip)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        weakSelf.speedFactor = 0.65; weakSelf.gravityFactor = 0.45; weakSelf.superGripEnabled = YES; weakSelf.ghostModeEnabled = NO;
        [weakSelf saveSettings]; [weakSelf applyTimeScale]; [weakSelf applyGravity]; [weakSelf updateButtonTitle];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Moon Jump (0.3x Low Gravity)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        weakSelf.speedFactor = 1.0; weakSelf.gravityFactor = 0.3; weakSelf.superGripEnabled = NO; weakSelf.ghostModeEnabled = NO;
        [weakSelf saveSettings]; [weakSelf applyTimeScale]; [weakSelf applyGravity]; [weakSelf updateButtonTitle];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Speed Run Mode (1.5x Speed)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        weakSelf.speedFactor = 1.5; weakSelf.gravityFactor = 1.0; weakSelf.superGripEnabled = NO; weakSelf.ghostModeEnabled = NO;
        [weakSelf saveSettings]; [weakSelf applyTimeScale]; [weakSelf applyGravity]; [weakSelf updateButtonTitle];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { [weakSelf tapped]; }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)tapped {
    UIViewController *presenter = [self topViewController];
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Getting Over It Tools" message:@"Practice controls & physics mods." preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    NSString *spdStr = (fabs(self.speedFactor - 1.0) < 0.01) ? @"Normal (1.0x)" : [NSString stringWithFormat:@"%.2gx", self.speedFactor];
    [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Speed: %@  ▶", spdStr] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf showSpeedMenu]; }]];
    NSString *grvStr = (fabs(self.gravityFactor - 1.0) < 0.01) ? @"Normal (1.0x)" : (self.gravityFactor < 0.01 ? @"Zero-G" : [NSString stringWithFormat:@"%.2gx", self.gravityFactor]);
    [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Gravity: %@  ▶", grvStr] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf showGravityMenu]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Ghost Mode (Zero-G Float)" selected:self.ghostModeEnabled] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        weakSelf.ghostModeEnabled = !weakSelf.ghostModeEnabled; [weakSelf saveSettings]; [weakSelf applyGravity]; [weakSelf updateButtonTitle];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Super Grip (Touch Assist)" selected:self.superGripEnabled] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        weakSelf.superGripEnabled = !weakSelf.superGripEnabled; [weakSelf saveSettings]; [weakSelf applyGravity]; [weakSelf updateButtonTitle];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Live Stats HUD Overlay" selected:self.statsHudEnabled] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        weakSelf.statsHudEnabled = !weakSelf.statsHudEnabled; [weakSelf saveSettings]; [weakSelf updateButtonTitle];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Practice Profiles  ▶" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf showProfilesMenu]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Restart / Reload Scene" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf reloadActiveScene]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Reset all mods" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { [weakSelf resetAllTweaks]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)install {
    UIWindow *host = [self guestWindow];
    if (!host) return;
    
    UIView *existing = [host viewWithTag:EMBER_GOI_BUTTON_TAG];
    if (existing && [existing isKindOfClass:UIButton.class]) {
        self.button = (UIButton *)existing;
        [host bringSubviewToFront:self.button];
        if (self.statsHud) [host bringSubviewToFront:self.statsHud];
        [self updateButtonTitle];
        [self maintainEnabledTweaks];
        return;
    }
    
    [self.button removeFromSuperview];
    
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = EMBER_GOI_BUTTON_TAG;
    button.frame = CGRectMake(MAX(8, CGRectGetWidth(host.bounds) - 84), MAX(8, CGRectGetHeight(host.bounds) - 108), 72, 40);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    button.layer.cornerRadius = 12;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.24].CGColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.3;
    button.layer.shadowRadius = 4;
    button.tintColor = UIColor.whiteColor;
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold];
    button.accessibilityLabel = @"Getting Over It Tools menu";
    [button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    
    [host addSubview:button];
    [host bringSubviewToFront:button];
    self.button = button;
    self.hostWindow = host;
    
    if (!self.statsHud) {
        UIView *hud = [[UIView alloc] initWithFrame:CGRectMake(12, 44, 160, 88)];
        hud.tag = EMBER_GOI_HUD_TAG;
        hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65];
        hud.layer.cornerRadius = 8;
        hud.layer.borderWidth = 1;
        hud.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
        hud.userInteractionEnabled = NO;
        hud.hidden = YES;
        
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, 144, 80)];
        label.numberOfLines = 0;
        label.textColor = [UIColor whiteColor];
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
    [self maintainEnabledTweaks];
}

- (void)start {
    [self install];
    [self.keepAliveTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { [weakSelf install]; }];
}

- (void)stop {
    [self.keepAliveTimer invalidate];
    self.keepAliveTimer = nil;
}

- (void)updateStatusPlist {
    NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    if (!cacheDir) return;
    NSString *emberDir = [cacheDir stringByAppendingPathComponent:@"EmberConnect"];
    [[NSFileManager defaultManager] createDirectoryAtPath:emberDir withIntermediateDirectories:YES attributes:nil error:nil];
    
    NSString *plistPath = [emberDir stringByAppendingPathComponent:@"GettingOverItStatus.plist"];
    NSDictionary *status = @{
        @"state": @"active",
        @"il2cppResolved": @(il2cpp_resolved),
        @"resolvedSource": resolvedSource ?: @"None",
        @"classesResolved": classesResolved ?: @{},
        @"speed": @(self.speedFactor),
        @"gravity": @(self.gravityFactor),
        @"updatedAt": @([NSDate.date timeIntervalSince1970])
    };
    [status writeToFile:plistPath atomically:YES];
}

@end

__attribute__((constructor))
static void EmberGettingOverItInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        EmberGettingOverItController *controller = [EmberGettingOverItController sharedController];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [controller start]; }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [controller stop]; }];
        [controller start];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [controller start]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [controller start]; });
    });
}
