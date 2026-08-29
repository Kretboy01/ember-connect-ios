// GettingOverIt.m — Ember Connect practice controls for Getting Over It with Bennett Foddy.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

// MARK: - IL2CPP Types
typedef void Il2CppDomain;
typedef void Il2CppAssembly;
typedef void Il2CppImage;
typedef void Il2CppClass;
typedef void MethodInfo;
typedef void FieldInfo;
typedef void Il2CppObject;
typedef struct { float x; float y; } Vector2;

// MARK: - Constants & Settings Keys
static NSString *const kEmberSpeedKey = @"EmberGettingOverIt.speed";
static NSString *const kEmberGravityKey = @"EmberGettingOverIt.gravity";
static NSString *const kEmberGhostModeKey = @"EmberGettingOverIt.ghostMode";
static NSString *const kEmberSuperGripKey = @"EmberGettingOverIt.superGrip";
static NSString *const kEmberStatsHudKey = @"EmberGettingOverIt.statsHud";

// MARK: - IL2CPP Function Pointers
static Il2CppDomain* (*il2cpp_domain_get)(void) = NULL;
static Il2CppAssembly** (*il2cpp_domain_get_assemblies)(const Il2CppDomain* domain, size_t* size) = NULL;
static const Il2CppImage* (*il2cpp_assembly_get_image)(const Il2CppAssembly* assembly) = NULL;
static Il2CppClass* (*il2cpp_class_from_name)(const Il2CppImage* image, const char* namespaze, const char* name) = NULL;
static const MethodInfo* (*il2cpp_class_get_method_from_name)(Il2CppClass* klass, const char* name, int argsCount) = NULL;
static FieldInfo* (*il2cpp_class_get_field_from_name)(Il2CppClass* klass, const char* name) = NULL;
static void (*il2cpp_field_static_get_value)(FieldInfo* field, void* value) = NULL;
static void (*il2cpp_field_static_set_value)(FieldInfo* field, void* value) = NULL;
static Il2CppObject* (*il2cpp_runtime_invoke)(const MethodInfo* method, void* obj, void** params, Il2CppObject** exc) = NULL;

static BOOL il2cpp_resolved = NO;
static NSMutableDictionary *classesResolved;

// Cached Unity methods
static const MethodInfo* set_timeScale_method = NULL;
static const MethodInfo* get_timeScale_method = NULL;
static const MethodInfo* set_gravity_method = NULL;
static const MethodInfo* get_gravity_method = NULL;
static const MethodInfo* load_scene_method = NULL;

// MARK: - Main Controller
@interface EmberGettingOverItController : NSObject
@property (nonatomic, weak) UIButton *button;
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) UIView *statsHud;
@property (nonatomic, strong) UILabel *statsHudLabel;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) NSTimer *keepAliveTimer;

@property (nonatomic, assign) NSInteger frames;
@property (nonatomic, assign) CFTimeInterval lastFrameTime;
@property (nonatomic, assign) double currentFPS;

// Settings
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
        [controller resolveIL2CPP];
        [controller loadSettings];
        
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

static void ResolveIL2CPPSymbols(void) {
    if (il2cpp_domain_get && il2cpp_class_from_name && il2cpp_runtime_invoke) return;
    
    void *handles[] = {
        RTLD_DEFAULT,
        dlopen(NULL, RTLD_LAZY),
        dlopen("UnityFramework.framework/UnityFramework", RTLD_NOLOAD | RTLD_LAZY),
        dlopen("@rpath/UnityFramework.framework/UnityFramework", RTLD_NOLOAD | RTLD_LAZY),
        dlopen("Frameworks/UnityFramework.framework/UnityFramework", RTLD_NOLOAD | RTLD_LAZY)
    };
    
    for (int i = 0; i < sizeof(handles)/sizeof(handles[0]); i++) {
        void *h = handles[i];
        if (!h) continue;
        if (!il2cpp_domain_get) il2cpp_domain_get = dlsym(h, "il2cpp_domain_get");
        if (!il2cpp_domain_get_assemblies) il2cpp_domain_get_assemblies = dlsym(h, "il2cpp_domain_get_assemblies");
        if (!il2cpp_assembly_get_image) il2cpp_assembly_get_image = dlsym(h, "il2cpp_assembly_get_image");
        if (!il2cpp_class_from_name) il2cpp_class_from_name = dlsym(h, "il2cpp_class_from_name");
        if (!il2cpp_class_get_method_from_name) il2cpp_class_get_method_from_name = dlsym(h, "il2cpp_class_get_method_from_name");
        if (!il2cpp_class_get_field_from_name) il2cpp_class_get_field_from_name = dlsym(h, "il2cpp_class_get_field_from_name");
        if (!il2cpp_field_static_get_value) il2cpp_field_static_get_value = dlsym(h, "il2cpp_field_static_get_value");
        if (!il2cpp_field_static_set_value) il2cpp_field_static_set_value = dlsym(h, "il2cpp_field_static_set_value");
        if (!il2cpp_runtime_invoke) il2cpp_runtime_invoke = dlsym(h, "il2cpp_runtime_invoke");
    }
}

- (void)resolveIL2CPP {
    if (!classesResolved) {
        classesResolved = [NSMutableDictionary dictionary];
    }
    ResolveIL2CPPSymbols();
    [self resolveUnityClasses];
}

- (BOOL)resolveUnityClasses {
    ResolveIL2CPPSymbols();
    if (!il2cpp_domain_get || !il2cpp_class_from_name || !il2cpp_runtime_invoke) {
        return NO;
    }
    
    Il2CppDomain* domain = il2cpp_domain_get();
    if (!domain) {
        return NO; // Domain not yet created by Unity, will retry on next tick
    }
    
    size_t count = 0;
    Il2CppAssembly** assemblies = il2cpp_domain_get_assemblies ? il2cpp_domain_get_assemblies(domain, &count) : NULL;
    if (!assemblies || count == 0) {
        return NO;
    }
    
    if (!classesResolved) {
        classesResolved = [NSMutableDictionary dictionary];
    }
    
    for (size_t i = 0; i < count; i++) {
        const Il2CppImage* image = il2cpp_assembly_get_image ? il2cpp_assembly_get_image(assemblies[i]) : NULL;
        if (!image) continue;
        
        if (!set_timeScale_method) {
            Il2CppClass* timeClass = il2cpp_class_from_name(image, "UnityEngine", "Time");
            if (timeClass) {
                set_timeScale_method = il2cpp_class_get_method_from_name(timeClass, "set_timeScale", 1);
                get_timeScale_method = il2cpp_class_get_method_from_name(timeClass, "get_timeScale", 0);
                if (set_timeScale_method) {
                    classesResolved[@"UnityEngine.Time"] = @YES;
                    NSLog(@"[EmberConnect] Resolved UnityEngine.Time set_timeScale!");
                }
            }
        }
        
        if (!set_gravity_method) {
            Il2CppClass* physicsClass = il2cpp_class_from_name(image, "UnityEngine", "Physics2D");
            if (physicsClass) {
                set_gravity_method = il2cpp_class_get_method_from_name(physicsClass, "set_gravity", 1);
                get_gravity_method = il2cpp_class_get_method_from_name(physicsClass, "get_gravity", 0);
                if (set_gravity_method) {
                    classesResolved[@"UnityEngine.Physics2D"] = @YES;
                    NSLog(@"[EmberConnect] Resolved UnityEngine.Physics2D set_gravity!");
                }
            }
        }
        
        if (!load_scene_method) {
            Il2CppClass* sceneManagerClass = il2cpp_class_from_name(image, "UnityEngine.SceneManagement", "SceneManager");
            if (sceneManagerClass) {
                load_scene_method = il2cpp_class_get_method_from_name(sceneManagerClass, "LoadScene", 1);
                if (load_scene_method) {
                    classesResolved[@"UnityEngine.SceneManagement.SceneManager"] = @YES;
                    NSLog(@"[EmberConnect] Resolved SceneManager.LoadScene!");
                }
            }
        }
    }
    
    il2cpp_resolved = (set_timeScale_method != NULL);
    [self updateStatusPlist];
    return il2cpp_resolved;
}

- (void)applyTimeScale {
    if (!set_timeScale_method) {
        [self resolveUnityClasses];
    }
    if (set_timeScale_method && il2cpp_runtime_invoke) {
        float speed = (float)self.speedFactor;
        void* args[1] = { &speed };
        Il2CppObject *exc = NULL;
        il2cpp_runtime_invoke(set_timeScale_method, NULL, args, &exc);
    }
}

- (void)applyGravity {
    if (!set_gravity_method) {
        [self resolveUnityClasses];
    }
    if (set_gravity_method && il2cpp_runtime_invoke) {
        Vector2 grav = { 0.0f, -9.81f * (float)self.gravityFactor };
        void* args[1] = { &grav };
        Il2CppObject *exc = NULL;
        il2cpp_runtime_invoke(set_gravity_method, NULL, args, &exc);
    }
}

- (void)reloadActiveScene {
    if (!load_scene_method) {
        [self resolveUnityClasses];
    }
    if (load_scene_method && il2cpp_runtime_invoke) {
        int sceneIndex = 0;
        void* args[1] = { &sceneIndex };
        Il2CppObject *exc = NULL;
        il2cpp_runtime_invoke(load_scene_method, NULL, args, &exc);
    }
}

- (void)maintainEnabledTweaks {
    if (!set_timeScale_method) {
        [self resolveUnityClasses];
    }
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
    
    [self maintainEnabledTweaks];
    
    if (self.statsHudEnabled && self.statsHudLabel && self.statsHud) {
        self.statsHud.hidden = NO;
        self.statsHudLabel.text = [NSString stringWithFormat:@"FPS: %.0f\nSpd: %.2gx  Grv: %.2gx\nIL2CPP: %@",
                                   self.currentFPS, self.speedFactor, self.gravityFactor,
                                   il2cpp_resolved ? @"Hooked" : @"Resolving..."];
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
    BOOL active = (fabs(self.speedFactor - 1.0) >= 0.01) ||
                  (fabs(self.gravityFactor - 1.0) >= 0.01) ||
                  self.ghostModeEnabled || self.superGripEnabled;
    self.button.backgroundColor = active ? [UIColor colorWithRed:0.98 green:0.38 blue:0.10 alpha:0.94]
                                         : [UIColor colorWithWhite:0.10 alpha:0.82];
}

// MARK: - Menu Actions

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

// MARK: - Submenus

- (void)showSpeedMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Game Speed (Time.timeScale)"
                                                                   message:@"Controls the game simulation speed."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    NSArray *speeds = @[@0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @2.0];
    for (NSNumber *spd in speeds) {
        CGFloat val = spd.doubleValue;
        NSString *name = (fabs(val - 1.0) < 0.01) ? @"1.0x (Normal)" : [NSString stringWithFormat:@"%.2gx", val];
        [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:name selected:fabs(self.speedFactor - val) < 0.01]
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            [weakSelf setPracticeSpeed:val];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [weakSelf tapped];
    }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)showGravityMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Gravity (Physics2D)"
                                                                   message:@"Modifies 2D physics gravity pull."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    NSArray *gravities = @[@0.0, @0.25, @0.5, @0.75, @1.0, @1.5];
    for (NSNumber *num in gravities) {
        CGFloat val = num.doubleValue;
        NSString *name;
        if (val < 0.01) name = @"0.0x (Zero-G Float)";
        else if (fabs(val - 0.25) < 0.01) name = @"0.25x (Moon Gravity)";
        else if (fabs(val - 0.5) < 0.01) name = @"0.5x (Low Gravity)";
        else if (fabs(val - 1.0) < 0.01) name = @"1.0x (Normal)";
        else name = [NSString stringWithFormat:@"%.2gx", val];
        
        [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:name selected:fabs(self.gravityFactor - val) < 0.01]
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            [weakSelf setPracticeGravity:val];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [weakSelf tapped];
    }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)showProfilesMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Getting Over It Profiles"
                                                                   message:@"Quickly apply balanced practice presets."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    
    [menu addAction:[UIAlertAction actionWithTitle:@"Easy Climb (0.5x Speed, 0.5x Gravity)"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        weakSelf.speedFactor = 0.5;
        weakSelf.gravityFactor = 0.5;
        weakSelf.ghostModeEnabled = NO;
        [weakSelf saveSettings];
        [weakSelf applyTimeScale];
        [weakSelf applyGravity];
        [weakSelf updateButtonTitle];
    }]];
    
    [menu addAction:[UIAlertAction actionWithTitle:@"Moon Jump (0.25x Gravity, 1.0x Speed)"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        weakSelf.speedFactor = 1.0;
        weakSelf.gravityFactor = 0.25;
        weakSelf.ghostModeEnabled = NO;
        [weakSelf saveSettings];
        [weakSelf applyTimeScale];
        [weakSelf applyGravity];
        [weakSelf updateButtonTitle];
    }]];
    
    [menu addAction:[UIAlertAction actionWithTitle:@"Speed Run (1.5x Speed, Normal Gravity)"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        weakSelf.speedFactor = 1.5;
        weakSelf.gravityFactor = 1.0;
        weakSelf.ghostModeEnabled = NO;
        [weakSelf saveSettings];
        [weakSelf applyTimeScale];
        [weakSelf applyGravity];
        [weakSelf updateButtonTitle];
    }]];
    
    [menu addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [weakSelf tapped];
    }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

// MARK: - Main Menu Presentation

- (void)tapped {
    UIViewController *presenter = [self topViewController];
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return;
    
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Getting Over It Tools"
                                                                   message:@"Ember Connect practice tools & IL2CPP mods."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    
    // Speed item
    NSString *spdStr = (fabs(self.speedFactor - 1.0) < 0.01) ? @"Normal (1.0x)" : [NSString stringWithFormat:@"%.2gx", self.speedFactor];
    [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Speed: %@  ▶", spdStr]
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        [weakSelf showSpeedMenu];
    }]];
    
    // Gravity item
    NSString *grvStr = (fabs(self.gravityFactor - 1.0) < 0.01) ? @"Normal (1.0x)" : (self.gravityFactor < 0.01 ? @"Zero-G" : [NSString stringWithFormat:@"%.2gx", self.gravityFactor]);
    [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Gravity: %@  ▶", grvStr]
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        [weakSelf showGravityMenu];
    }]];
    
    // Ghost Mode toggle
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Ghost Mode (No Clip)" selected:self.ghostModeEnabled]
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        weakSelf.ghostModeEnabled = !weakSelf.ghostModeEnabled;
        [weakSelf saveSettings];
        [weakSelf updateButtonTitle];
    }]];
    
    // Super Grip toggle
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Super Grip (Sticky Friction)" selected:self.superGripEnabled]
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        weakSelf.superGripEnabled = !weakSelf.superGripEnabled;
        [weakSelf saveSettings];
        [weakSelf updateButtonTitle];
    }]];
    
    // Stats HUD toggle
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Live Stats HUD Overlay" selected:self.statsHudEnabled]
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        weakSelf.statsHudEnabled = !weakSelf.statsHudEnabled;
        [weakSelf saveSettings];
        [weakSelf updateButtonTitle];
    }]];
    
    // Preset Profiles submenu
    [menu addAction:[UIAlertAction actionWithTitle:@"Practice Profiles  ▶"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        [weakSelf showProfilesMenu];
    }]];
    
    // Reload Scene
    [menu addAction:[UIAlertAction actionWithTitle:@"Restart / Reload Scene"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        [weakSelf reloadActiveScene];
    }]];
    
    // Reset all
    [menu addAction:[UIAlertAction actionWithTitle:@"Reset all mods"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *action) {
        [weakSelf resetAllTweaks];
    }]];
    
    [menu addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
    
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

// MARK: - UI Installation & Lifecycle

- (void)install {
    UIWindow *host = [self guestWindow];
    if (!host) return;
    
    if (self.button.superview == host) {
        [host bringSubviewToFront:self.button];
        if (self.statsHud) [host bringSubviewToFront:self.statsHud];
        [self maintainEnabledTweaks];
        return;
    }
    
    [self.button removeFromSuperview];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
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
    button.accessibilityHint = @"Opens speed, gravity, and practice controls";
    [button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [host addSubview:button];
    [host bringSubviewToFront:button];
    self.button = button;
    self.hostWindow = host;
    
    // Stats HUD view in top-left
    if (!self.statsHud) {
        UIView *hud = [[UIView alloc] initWithFrame:CGRectMake(12, 44, 150, 68)];
        hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        hud.layer.cornerRadius = 8;
        hud.layer.borderWidth = 1;
        hud.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
        hud.userInteractionEnabled = NO;
        hud.hidden = YES;
        
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, 134, 60)];
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
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        [weakSelf install];
    }];
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [controller start]; });
    });
}
