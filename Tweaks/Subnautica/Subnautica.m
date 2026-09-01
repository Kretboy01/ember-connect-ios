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
#import "../Shared/EmberMenu.h"

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
static Il2CppClass *g_unity_object_class = NULL;
static const Il2CppMethod *g_find_objects_of_type_method = NULL;
static void *g_console_instance = NULL;
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
@property (nonatomic, strong) EmberMenuPanel *panel;
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
    const Il2CppImage *unityImage = NULL;
    for (size_t i = 0; i < count; i++) {
        const Il2CppImage *image = g_il2cpp_assembly_get_image(assemblies[i]);
        if (!image || !g_il2cpp_image_get_name) continue;
        const char *name = g_il2cpp_image_get_name(image);
        if (!name) continue;
        if (strcmp(name, "Assembly-CSharp.dll") == 0) {
            gameImage = image;
            EmberSnLog(@"found Assembly-CSharp image (%zu assemblies scanned)", count);
        } else if (strcmp(name, "UnityEngine.CoreModule.dll") == 0 ||
                   strcmp(name, "UnityEngine.dll") == 0) {
            unityImage = image;
        }
        if (gameImage && unityImage) break;
    }
    if (!gameImage) {
        EmberSnLog(@"Assembly-CSharp image not found yet (%zu assemblies)", count);
        return;
    }

    // UnityEngine.Object.FindObjectsOfType(Type) — managed static — is how we
    // locate the live console: the FindObjectOfType icalls do not exist under
    // those names in this Unity version.
    if (unityImage && !g_unity_object_class) {
        g_unity_object_class = g_il2cpp_class_from_name(unityImage, "UnityEngine", "Object");
        if (g_unity_object_class) {
            g_find_objects_of_type_method =
                g_il2cpp_class_get_method_from_name(g_unity_object_class, "FindObjectsOfType", 1);
            EmberSnLog(@"FindObjectsOfType resolved (%@ image)",
                       g_find_objects_of_type_method ? @"yes" : @"no");
        }
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
        g_set_time_scale_icall =
            g_il2cpp_resolve_icall("UnityEngine.Time::set_timeScale(Single)");
        EmberSnLog(@"icall timeScale: %p", g_set_time_scale_icall);
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

    void *instance = g_console_instance;
    if (!g_send_console_command_is_static && !instance) {
        // Instance method: locate the live console via the managed
        // UnityEngine.Object.FindObjectsOfType(Type) static.
        if (!g_find_objects_of_type_method || !g_il2cpp_class_get_type ||
            !g_il2cpp_type_get_object || !g_il2cpp_runtime_invoke || !g_dev_console_class) {
            EmberSnLog(@"instance path unavailable (reflection pieces missing)");
            return NO;
        }
        void *type = g_il2cpp_type_get_object(g_il2cpp_class_get_type(g_dev_console_class));
        if (!type) {
            EmberSnLog(@"System.Type object creation failed");
            return NO;
        }
        void *args[1] = { type };
        Il2CppException *exception = NULL;
        void *array = (void *)g_il2cpp_runtime_invoke(
            g_find_objects_of_type_method, NULL, args, &exception);
        if (exception || !array) {
            EmberSnLog(@"FindObjectsOfType threw or returned null");
            return NO;
        }
        // Il2CppArray layout (64-bit): klass, monitor, bounds, max_length,
        // then the element vector at 0x20.
        uintptr_t length = *(uintptr_t *)((char *)array + 0x18);
        EmberSnLog(@"FindObjectsOfType found %llu console(s)", (unsigned long long)length);
        if (length == 0) {
            EmberSnLog(@"no DevConsole instance in the scene yet");
            return NO;
        }
        instance = *(void **)((char *)array + 0x20);
        if (instance) {
            g_console_instance = instance; // cache — it persists for the session
        }
    }

    Il2CppString *managed = g_il2cpp_string_new ? g_il2cpp_string_new(command.UTF8String) : NULL;
    void *args[1] = { (void *)managed };
    Il2CppException *exception = NULL;
    g_il2cpp_runtime_invoke(g_send_console_command_method, instance, args, &exception);
    EmberSnLog(@"sent console command: %@", command);
    return exception == NULL;
}

#pragma mark - Custom menu panel (same as GOI)

@interface EmberSnMenuPanel : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIStackView *rows;
@property (nonatomic, assign) NSUInteger rowCount;
@property (nonatomic, copy) void (^onClose)(void);
@end

@implementation EmberSnMenuPanel

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.96];
        self.layer.cornerRadius = 14;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithRed:0.2 green:0.75 blue:0.85 alpha:0.35].CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowRadius = 10;

        self.titleLabel = [UILabel new];
        self.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
        self.titleLabel.textColor = UIColor.whiteColor;
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.titleLabel];

        self.subtitleLabel = [UILabel new];
        self.subtitleLabel.font = [UIFont systemFontOfSize:11];
        self.subtitleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
        self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.subtitleLabel];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        [close setTitle:@"✕" forState:UIControlStateNormal];
        close.tintColor = [UIColor colorWithWhite:1 alpha:0.8];
        close.translatesAutoresizingMaskIntoConstraints = NO;
        [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:close];

        self.rows = [[UIStackView alloc] init];
        self.rows.axis = UILayoutConstraintAxisVertical;
        self.rows.spacing = 6;
        self.rows.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.rows];

        [NSLayoutConstraint activateConstraints:@[
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
            [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
            [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
            [close.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
            [close.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [close.widthAnchor constraintEqualToConstant:24],
            [self.rows.topAnchor constraintEqualToAnchor:self.subtitleLabel.bottomAnchor constant:10],
            [self.rows.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [self.rows.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [self.rows.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-12],
        ]];
    }
    return self;
}

- (void)closeTapped {
    if (self.onClose) self.onClose();
}

- (void)setHeader:(NSString *)title subtitle:(NSString *)subtitle {
    self.titleLabel.text = title;
    self.subtitleLabel.text = subtitle;
}

- (void)addOption:(NSString *)title handler:(void (^)(void))handler {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    button.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    [button setTitle:title forState:UIControlStateNormal];
    button.tintColor = [UIColor colorWithRed:0.55 green:0.9 blue:1 alpha:1];
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    button.layer.cornerRadius = 8;
    button.contentEdgeInsets = UIEdgeInsetsMake(8, 10, 8, 10);
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintEqualToConstant:36].active = YES;
    if (handler) {
        [button addTarget:self action:@selector(optionTapped:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(button, "handler", handler, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    [self.rows addArrangedSubview:button];
    self.rowCount += 1;
}

- (void)optionTapped:(UIButton *)sender {
    void (^handler)(void) = objc_getAssociatedObject(sender, "handler");
    if (handler) handler();
}

- (void)finalizeLayout {
    CGFloat height = 64 + 14 + self.rowCount * 42 + 12;
    CGFloat width = 300;
    CGRect frame = self.frame;
    frame.size = CGSizeMake(width, height);
    self.frame = frame;
}

@end

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

- (void)closeSnPanel {
    [self.panel removeFromSuperview];
    self.panel = nil;
}

- (void)renderSnTab:(NSInteger)tab {
    EmberMenuPanel *panel = self.panel;
    if (!panel) return;
    [panel clearRows];
    [panel setStatus:g_resolved ? @"UNITY ONLINE  |  DEVCONSOLE READY"
                                : @"WAITING FOR UNITY / DEVCONSOLE"];
    __weak typeof(self) weakSelf = self;
    void (^send)(NSString *) = ^(NSString *command) { [weakSelf dispatchCommand:command]; };

    if (tab == 0) {
        [panel addSection:@"SURVIVAL"];
        [panel addAction:@"REFILL OXYGEN" detail:@"Restore the current oxygen supply" handler:^{ send(@"oxygen"); }];
        [panel addAction:@"RESTORE FOOD + WATER" detail:@"Refill survival meters" handler:^{ send(@"survival"); }];
        [panel addSection:@"WORLD"];
        [panel addAction:@"SET DAY" detail:nil handler:^{ send(@"day"); }];
        [panel addAction:@"SET NIGHT" detail:nil handler:^{ send(@"night"); }];
    } else if (tab == 1) {
        [panel addSection:@"PLAYER TOGGLES  //  TAP AGAIN TO DISABLE"];
        [panel addAction:@"NO DAMAGE" detail:@"Toggle player and vehicle damage" handler:^{ send(@"nodamage"); }];
        [panel addAction:@"NO CRAFTING COSTS" detail:@"Toggle free construction and crafting" handler:^{ send(@"nocost"); }];
        [panel addAction:@"INVISIBLE" detail:@"Toggle creature aggro suppression" handler:^{ send(@"invisible"); }];
        [panel addAction:@"NO RADIATION" detail:@"Toggle radiation protection" handler:^{ send(@"radiation"); }];
        [panel addAction:@"CURE INFECTION" detail:nil handler:^{ send(@"playerinfection"); }];
        [panel addSection:@"FAST SYSTEMS"];
        [panel addAction:@"FAST GROW" detail:nil handler:^{ send(@"fastgrow"); }];
        [panel addAction:@"FAST SCAN" detail:nil handler:^{ send(@"fastscan"); }];
        [panel addAction:@"FAST BUILD" detail:nil handler:^{ send(@"fastbuild"); }];
        [panel addAction:@"FAST HATCH" detail:nil handler:^{ send(@"fasthatch"); }];
        [panel addAction:@"FAST FILTER" detail:nil handler:^{ send(@"filterfast"); }];
    } else if (tab == 2) {
        [panel addSection:@"GLOBAL UNLOCKS"];
        [panel addAction:@"BOB THE BUILDER" detail:@"Tools, blueprints, build helpers" handler:^{ send(@"bobthebuilder"); }];
        [panel addAction:@"CREATIVE MODE" detail:@"Switch to creative rules" handler:^{ send(@"creative"); }];
        [panel addAction:@"UNLOCK ALL BLUEPRINTS" detail:nil handler:^{ send(@"unlockall"); }];
        [panel addAction:@"UNLOCK PRECURSOR DOORS" detail:nil handler:^{ send(@"unlockdoors"); }];
        [panel addSection:@"VEHICLES"];
        [panel addAction:@"SEAMOTH UPGRADES" detail:nil handler:^{ send(@"seamothupgrades"); }];
        [panel addAction:@"PRAWN ARMS" detail:nil handler:^{ send(@"exosuitarms"); }];
        [panel addAction:@"PRAWN UPGRADES" detail:nil handler:^{ send(@"exosuitupgrades"); }];
        [panel addAction:@"CYCLOPS UPGRADES" detail:nil handler:^{ send(@"cyclopsupgrades"); }];
        [panel addAction:@"ALL VEHICLE UPGRADES" detail:nil handler:^{ send(@"vehicleupgrades"); }];
    } else {
        [panel addSection:@"WORLD TIME SCALE"];
        [panel addSlider:@"TIME SCALE" value:1.0f min:0.1f max:3.0f format:@"%.2fx" handler:^(float value) {
            if (g_set_time_scale_icall) {
                ((void (*)(float))g_set_time_scale_icall)(value);
                EmberSnLog(@"timeScale set to %.2f", value);
            }
        }];
        [panel addSection:@"SWIM SPEED"];
        [panel addAction:@"NORMAL" detail:@"1x movement" handler:^{ send(@"speed"); }];
        [panel addAction:@"FAST" detail:@"3x movement" handler:^{ send(@"speed 3"); }];
        [panel addAction:@"VERY FAST" detail:@"5x movement" handler:^{ send(@"speed 5"); }];
        [panel addAction:@"EXTREME" detail:@"10x movement" handler:^{ send(@"speed 10"); }];
    }
}

- (void)showMainMenu {
    UIWindow *host = self.hostWindow ?: UIApplication.sharedApplication.keyWindow;
    if (!host) return;
    [self closeSnPanel];
    EmberMenuPanel *panel = [[EmberMenuPanel alloc] initWithTitle:@"SUBNAUTICA  //  EMBER TOOLKIT"
                                                      accentColor:[UIColor colorWithRed:0.10 green:0.78 blue:0.92 alpha:1.0]];
    __weak typeof(self) weakSelf = self;
    panel.onClose = ^{ [weakSelf closeSnPanel]; };
    [panel setTabs:@[@"Survival", @"Cheats", @"Build", @"Speed"] activeTab:0 handler:^(NSInteger index) {
        [weakSelf renderSnTab:index];
    }];
    self.panel = panel;
    [self renderSnTab:0];
    [panel presentInWindow:host];
}

- (void)tapped {
    if (self.panel) {
        [self closeSnPanel];
        return;
    }
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
