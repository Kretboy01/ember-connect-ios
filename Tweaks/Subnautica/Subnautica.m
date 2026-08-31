// Subnautica.m — Ember Connect tools for Subnautica (iOS, IL2CPP).
//
// # Why this works when the Getting Over It tweak did not
//
// Subnautica ships UnityFramework.framework inside its Frameworks directory
// (verified on-device), so the IL2CPP API is resolvable by name. Getting Over
// It statically links its IL2CPP runtime into a stripped main binary with no
// UnityFramework and no exported il2cpp symbols — that resolver can never
// succeed there.
//
// # Design
//
// - The IL2CPP API is resolved from UnityFramework.framework, retrying from a
//   tick until Unity finishes loading — the framework is not present at the
//   moment the tweak's constructor runs.
// - Features are driven through the game's own developer console:
//   DevConsole.SendConsoleCommand(string) dispatches to the same
//   OnConsoleCommand_* handlers the built-in console uses, so cheats like
//   "oxygen", "day", "night", "nodamage", "survival", "nocost", "fastgrow",
//   "fastscan", "fastbuild", "fastswim", "invisible" and "unlockall" apply
//   exactly as the developers implemented them — no game internals patched.
// - Time scale uses the UnityEngine.Time icall directly.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#define EMBER_SN_BUTTON_TAG 0x5301
#define EMBER_SN_METHOD_ATTRIBUTE_STATIC 0x0010

#pragma mark - IL2CPP surface

typedef void Il2CppDomain;
typedef void Il2CppAssembly;
typedef void Il2CppImage;
typedef void Il2CppClass;
typedef void Il2CppMethod;
typedef void Il2CppObject;
typedef void Il2CppThread;
typedef void Il2CppString;
typedef void Il2CppType;
typedef void Il2CppException;

static Il2CppDomain *(*g_il2cpp_domain_get)(void) = NULL;
static Il2CppThread *(*g_il2cpp_thread_attach)(Il2CppDomain *) = NULL;
static Il2CppAssembly **(*g_il2cpp_domain_get_assemblies)(Il2CppDomain *, size_t *) = NULL;
static const Il2CppImage *(*g_il2cpp_assembly_get_image)(Il2CppAssembly *) = NULL;
static const char *(*g_il2cpp_image_get_name)(const Il2CppImage *) = NULL;
static Il2CppClass *(*g_il2cpp_class_from_name)(const Il2CppImage *, const char *, const char *) = NULL;
static const Il2CppMethod *(*g_il2cpp_class_get_method_from_name)(Il2CppClass *, const char *, int) = NULL;
static Il2CppObject *(*g_il2cpp_runtime_invoke)(const Il2CppMethod *, void *, void **, Il2CppException **) = NULL;
static void *(*g_il2cpp_resolve_icall)(const char *) = NULL;
static Il2CppType *(*g_il2cpp_class_get_type)(Il2CppClass *) = NULL;
static Il2CppObject *(*g_il2cpp_type_get_object)(Il2CppType *) = NULL;
static int (*g_il2cpp_method_get_flags)(const Il2CppMethod *, uint32_t *) = NULL;
static Il2CppString *(*g_il2cpp_string_new)(const char *) = NULL;

typedef void (*UnityPauseFunc)(int);
static UnityPauseFunc g_unity_pause = NULL;

static const Il2CppMethod *g_send_console_command_method = NULL;
static BOOL g_send_console_command_is_static = NO;
static Il2CppClass *g_dev_console_class = NULL;
static const void *g_find_object_of_type_icall = NULL;
static const void *g_set_time_scale_icall = NULL;

static BOOL g_resolved = NO;
static BOOL g_attached = NO;

#pragma mark - Diagnostics

static NSMutableString *g_diagLog = nil;
static NSString *g_diagPath = nil;

static void EmberSnLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void EmberSnLog(NSString *fmt, ...) {
    if (!g_diagLog) g_diagLog = [NSMutableString new];
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *stamp = [NSString stringWithFormat:@"[%.2f] %@\n", CACurrentMediaTime(), line];
    NSLog(@"[Ember/Subnautica] %@", line);
    @synchronized (g_diagLog) { [g_diagLog appendString:stamp]; }
    if (!g_diagPath) {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (dirs.count > 0) {
            NSString *dir = [dirs.firstObject stringByAppendingPathComponent:@"EmberConnect"];
            [NSFileManager.defaultManager createDirectoryAtPath:dir
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:nil];
            g_diagPath = [dir stringByAppendingPathComponent:@"Subnautica-diag.log"];
        }
    }
    if (g_diagPath) {
        @synchronized (g_diagLog) {
            [g_diagLog writeToFile:g_diagPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
}

@interface EmberSnController : NSObject
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UIWindow *hostWindow;
@property (nonatomic, strong) NSTimer *keepAliveTimer;
+ (instancetype)sharedController;
- (void)start;
- (void)stop;
- (UIViewController *)topViewController;
@end

static void toast_sn(NSString *message) {
    UIViewController *presenter = [[EmberSnController sharedController] topViewController];
    if (!presenter) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [[EmberSnController sharedController] topViewController];
        if (!top) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Ember Connect"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - Runtime resolution

static void EmberSnProbeHandle(void *handle, NSString *label) {
    if (!handle) return;
    struct Symbol {
        const char *name;
        void **slot;
    };
    const struct Symbol symbols[] = {
        {"il2cpp_domain_get", (void **)&g_il2cpp_domain_get},
        {"il2cpp_thread_attach", (void **)&g_il2cpp_thread_attach},
        {"il2cpp_domain_get_assemblies", (void **)&g_il2cpp_domain_get_assemblies},
        {"il2cpp_assembly_get_image", (void **)&g_il2cpp_assembly_get_image},
        {"il2cpp_image_get_name", (void **)&g_il2cpp_image_get_name},
        {"il2cpp_class_from_name", (void **)&g_il2cpp_class_from_name},
        {"il2cpp_class_get_method_from_name", (void **)&g_il2cpp_class_get_method_from_name},
        {"il2cpp_runtime_invoke", (void **)&g_il2cpp_runtime_invoke},
        {"il2cpp_resolve_icall", (void **)&g_il2cpp_resolve_icall},
        {"il2cpp_class_get_type", (void **)&g_il2cpp_class_get_type},
        {"il2cpp_type_get_object", (void **)&g_il2cpp_type_get_object},
        {"il2cpp_method_get_flags", (void **)&g_il2cpp_method_get_flags},
        {"il2cpp_string_new", (void **)&g_il2cpp_string_new},
        {"UnityPause", (void **)&g_unity_pause},
    };
    for (size_t i = 0; i < sizeof(symbols) / sizeof(symbols[0]); i++) {
        if (*symbols[i].slot) continue;
        void *pointer = dlsym(handle, symbols[i].name);
        if (pointer) {
            *symbols[i].slot = pointer;
            EmberSnLog(@"resolved %@ from %@", [NSString stringWithUTF8String:symbols[i].name], label);
        }
    }
}

static void EmberSnResolveRuntime(void) {
    if (g_resolved) return;

    // Probe process-wide first, then the UnityFramework that this game
    // verifiably ships in its Frameworks directory.
    EmberSnProbeHandle(RTLD_DEFAULT, @"RTLD_DEFAULT");

    if (!g_resolved && !g_il2cpp_domain_get) {
        NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
        if (frameworks) {
            NSString *path = [frameworks stringByAppendingPathComponent:@"UnityFramework.framework/UnityFramework"];
            void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_NOLOAD);
            if (!handle) handle = dlopen(path.UTF8String, RTLD_LAZY);
            if (handle) {
                EmberSnLog(@"UnityFramework loaded from %@", path);
                EmberSnProbeHandle(handle, @"UnityFramework");
            }
        }
    }

    if (!g_il2cpp_domain_get || !g_il2cpp_class_from_name || !g_il2cpp_runtime_invoke) {
        return;
    }

    Il2CppDomain *domain = g_il2cpp_domain_get();
    if (!domain) return;
    if (!g_attached) {
        g_il2cpp_thread_attach(domain);
        g_attached = YES;
    }

    size_t count = 0;
    Il2CppAssembly **assemblies = g_il2cpp_domain_get_assemblies(domain, &count);
    if (!assemblies || count == 0) return;

    const Il2CppImage *gameImage = NULL;
    for (size_t i = 0; i < count; i++) {
        const Il2CppImage *image = g_il2cpp_assembly_get_image(assemblies[i]);
        if (!image || !g_il2cpp_image_get_name) continue;
        const char *name = g_il2cpp_image_get_name(image);
        if (name && strcmp(name, "Assembly-CSharp.dll") == 0) {
            gameImage = image;
            EmberSnLog(@"found Assembly-CSharp image (%zu assemblies scanned)", count);
            break;
        }
    }
    if (!gameImage) {
        EmberSnLog(@"Assembly-CSharp image not found yet (%zu assemblies)", count);
        return;
    }

    Il2CppClass *consoleClass = g_il2cpp_class_from_name(gameImage, "", "DevConsole");
    if (!consoleClass) {
        EmberSnLog(@"DevConsole class not found");
        return;
    }
    g_dev_console_class = consoleClass;

    const Il2CppMethod *send = g_il2cpp_class_get_method_from_name(consoleClass, "SendConsoleCommand", 1);
    if (!send) {
        EmberSnLog(@"DevConsole.SendConsoleCommand(string) not found");
        return;
    }

    uint32_t iflags = 0;
    g_send_console_command_is_static =
        g_il2cpp_method_get_flags &&
        g_il2cpp_method_get_flags(send, &iflags) &&
        (iflags & EMBER_SN_METHOD_ATTRIBUTE_STATIC) != 0;
    g_send_console_command_method = send;
    EmberSnLog(@"SendConsoleCommand resolved (static=%d)", g_send_console_command_is_static ? 1 : 0);

    if (g_il2cpp_resolve_icall) {
        g_find_object_of_type_icall =
            g_il2cpp_resolve_icall("UnityEngine.Object::FindObjectOfType(System.Type)");
        g_set_time_scale_icall =
            g_il2cpp_resolve_icall("UnityEngine.Time::set_timeScale(Single)");
    }

    g_resolved = YES;
    EmberSnLog(@"runtime fully resolved");
}

#pragma mark - Command dispatch

static BOOL EmberSnSendCommand(NSString *command) {
    if (!g_resolved || !g_send_console_command_method || !g_il2cpp_runtime_invoke) {
        return NO;
    }
    if (!g_attached && g_il2cpp_thread_attach && g_il2cpp_domain_get) {
        Il2CppDomain *domain = g_il2cpp_domain_get();
        if (domain) {
            g_il2cpp_thread_attach(domain);
            g_attached = YES;
        }
    }

    void *instance = NULL;
    if (!g_send_console_command_is_static) {
        // Instance method: locate the live console component first.
        if (!g_find_object_of_type_icall || !g_il2cpp_class_get_type || !g_il2cpp_type_get_object ||
            !g_dev_console_class) {
            return NO;
        }
        void *type = g_il2cpp_type_get_object(g_il2cpp_class_get_type(g_dev_console_class));
        if (!type) return NO;
        typedef void *(*FindObjectFunc)(void *);
        instance = ((FindObjectFunc)g_find_object_of_type_icall)(type);
        if (!instance) {
            EmberSnLog(@"no DevConsole instance in the scene yet");
            return NO;
        }
    }

    Il2CppString *managed = g_il2cpp_string_new ? g_il2cpp_string_new(command.UTF8String) : NULL;
    void *args[1] = { (void *)managed };
    Il2CppException *exception = NULL;
    g_il2cpp_runtime_invoke(g_send_console_command_method, instance, args, &exception);
    EmberSnLog(@"sent console command: %@", command);
    return exception == NULL;
}

#pragma mark - Controller

@implementation EmberSnController

+ (instancetype)sharedController {
    static EmberSnController *controller = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controller = [[EmberSnController alloc] init]; });
    return controller;
}

- (UIViewController *)topViewController {
    UIWindow *host = self.hostWindow ?: UIApplication.sharedApplication.keyWindow;
    if (!host) return nil;
    UIViewController *root = host.rootViewController;
    while (root.presentedViewController) {
        root = root.presentedViewController;
    }
    return root;
}

- (void)saveSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:self.button.center.x forKey:@"EmberSubnautica.buttonX"];
    [defaults setDouble:self.button.center.y forKey:@"EmberSubnautica.buttonY"];
}

- (void)updateButtonTitle {
    NSString *state = g_resolved ? @"Tools" : @"Waiting…";
    [self.button setTitle:[NSString stringWithFormat:@"SN %@", state]
                 forState:UIControlStateNormal];
}

- (void)dragged:(UIPanGestureRecognizer *)recognizer {
    UIView *host = self.hostWindow ?: UIApplication.sharedApplication.keyWindow;
    if (!host) return;
    CGPoint translation = [recognizer translationInView:host];
    UIView *view = recognizer.view;
    view.center = CGPointMake(view.center.x + translation.x, view.center.y + translation.y);
    [recognizer setTranslation:CGPointZero inView:host];
    if (recognizer.state == UIGestureRecognizerStateEnded) {
        [self saveSettings];
    }
}

- (void)install {
    UIWindow *host = UIApplication.sharedApplication.keyWindow;
    if (!host) return;
    if (self.button.superview == host) return;
    if (self.hostWindow && self.hostWindow != host) {
        [self.button removeFromSuperview];
        self.button = nil;
    }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.tag = EMBER_SN_BUTTON_TAG;
    button.frame = CGRectMake(0, 0, 92, 36);
    button.backgroundColor = [UIColor colorWithRed:0.05 green:0.32 blue:0.44 alpha:0.82];
    CGFloat savedX = [NSUserDefaults.standardUserDefaults doubleForKey:@"EmberSubnautica.buttonX"];
    CGFloat savedY = [NSUserDefaults.standardUserDefaults doubleForKey:@"EmberSubnautica.buttonY"];
    CGFloat defaultX = CGRectGetWidth(host.bounds) - 62;
    CGFloat defaultY = MAX(52, host.safeAreaInsets.top + 24);
    button.center = CGPointMake(savedX > 0 ? savedX : defaultX, savedY > 0 ? savedY : defaultY);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    button.layer.cornerRadius = 11;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
    button.accessibilityLabel = @"Ember Connect Subnautica tools";
    [button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
    pan.cancelsTouchesInView = NO;
    [button addGestureRecognizer:pan];

    [host addSubview:button];
    [host bringSubviewToFront:button];
    self.button = button;
    self.hostWindow = host;
    [self updateButtonTitle];
}

- (void)start {
    [self install];
    [self.keepAliveTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                          repeats:YES
                                                            block:^(NSTimer *timer) {
        [weakSelf install];
        EmberSnResolveRuntime();
        [weakSelf updateButtonTitle];
    }];
}

- (void)stop {
    [self.keepAliveTimer invalidate];
    self.keepAliveTimer = nil;
}

- (void)dispatchCommand:(NSString *)command {
    if (!EmberSnSendCommand(command)) {
        toast_sn(@"Could not run the command — the game runtime is not ready yet.");
    }
}

- (void)showMainMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return;

    NSString *header = g_resolved
        ? @"Tools run the game's own developer console commands."
        : @"Waiting for Unity to finish loading. The menu is live but commands only work once the engine is ready.";

    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Subnautica Tools"
                                                                  message:header
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    void (^send)(NSString *) = ^(NSString *command) {
        [weakSelf dispatchCommand:command];
    };

    [menu addAction:[UIAlertAction actionWithTitle:@"Refill Oxygen"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { send(@"oxygen"); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Restore Food & Water"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { send(@"survival"); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Set Day"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { send(@"day"); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Set Night"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { send(@"night"); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cheats & Toggles…"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { [weakSelf showCheatsMenu]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Game Speed…"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { [weakSelf showTimeScaleMenu]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Back"
                                             style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction *a) { [weakSelf tapped]; }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)showCheatsMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Cheats (toggle — tap again to undo)"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    void (^sendClose)(NSString *) = ^(NSString *command) {
        [weakSelf dispatchCommand:command];
    };

    [menu addAction:[UIAlertAction actionWithTitle:@"Toggle No Damage"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { sendClose(@"nodamage"); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Toggle No Crafting Costs"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { sendClose(@"nocost"); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Toggle Fast Growth"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { sendClose(@"fastgrow"); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Toggle Fast Scan"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { sendClose(@"fastscan"); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Toggle Fast Build"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { sendClose(@"fastbuild"); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Toggle Fast Swim"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { sendClose(@"fastswim"); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Toggle Invisible (creatures ignore you)"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { sendClose(@"invisible"); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Unlock All Blueprints"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { sendClose(@"unlockall"); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Back"
                                             style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction *a) { [weakSelf showMainMenu]; }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)showTimeScaleMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    if (!g_set_time_scale_icall) {
        toast_sn(@"Time scale is not available in this build.");
        return;
    }
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Game Speed"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    void (^apply)(float) = ^(float scale) {
        ((void (*)(float))g_set_time_scale_icall)(scale);
        EmberSnLog(@"timeScale set to %.2f", scale);
        [weakSelf showTimeScaleMenu];
    };
    [menu addAction:[UIAlertAction actionWithTitle:@"0.5x — slow motion"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(0.5f); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"1x — normal"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(1.0f); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"2x — fast"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(2.0f); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"3x — very fast"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(3.0f); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Back"
                                             style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction *a) { [weakSelf showMainMenu]; }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)tapped {
    UIViewController *presenter = [self topViewController];
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return;
    [self showMainMenu];
}

@end

#pragma mark - Bootstrap

__attribute__((constructor))
static void EmberSubnauticaInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        NSString *executable = NSBundle.mainBundle.executablePath.lastPathComponent.lowercaseString;
        BOOL expectedBundle = [bundleIdentifier isEqualToString:@"com.unknownworlds.subnautica"];
        BOOL expectedRuntime = [executable isEqualToString:@"subnautica"];
        // LiveContainer can briefly expose the host bundle while a guest is
        // being brought up, so accept the executable name as the runtime
        // signature too.
        if (!expectedBundle && !expectedRuntime) {
            EmberSnLog(@"wrong bundle: %@ (%@)", bundleIdentifier, executable);
            return;
        }
        EmberSnLog(@"tweak loaded in %@", bundleIdentifier);

        EmberSnController *controller = [EmberSnController sharedController];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { [controller start]; }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { [controller stop]; }];
        [controller start];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [controller start]; });
    });
}

