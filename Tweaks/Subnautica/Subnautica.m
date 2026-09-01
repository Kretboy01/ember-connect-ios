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
static void *(*g_il2cpp_object_unbox)(Il2CppObject *) = NULL;
static Il2CppClass *(*g_il2cpp_object_get_class)(Il2CppObject *) = NULL;
static const char *(*g_il2cpp_class_get_name)(Il2CppClass *) = NULL;

typedef void (*UnityPauseFunc)(int);
static UnityPauseFunc g_unity_pause = NULL;

static const Il2CppMethod *g_send_console_command_method = NULL;
static BOOL g_send_console_command_is_static = NO;
static Il2CppClass *g_dev_console_class = NULL;
static Il2CppClass *g_unity_object_class = NULL;
static const Il2CppMethod *g_find_objects_of_type_method = NULL;
static void *g_console_instance = NULL;
static const void *g_set_time_scale_icall = NULL;

typedef struct { float x, y, z; } EmberSnVector3;
static Il2CppClass *g_creature_class = NULL;
static const Il2CppMethod *g_component_get_transform_method = NULL;
static const Il2CppMethod *g_transform_get_position_method = NULL;
static const Il2CppMethod *g_camera_get_main_method = NULL;
static const Il2CppMethod *g_camera_world_to_screen_method = NULL;
static const Il2CppMethod *g_screen_get_width_method = NULL;
static const Il2CppMethod *g_screen_get_height_method = NULL;

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
@property (nonatomic, strong) UIView *espView;
@property (nonatomic, assign) BOOL espEnabled;
@property (nonatomic, assign) BOOL espLeviathansOnly;
@property (nonatomic, assign) BOOL espShowNames;
@property (nonatomic, assign) float espMaxDistance;
@property (nonatomic, strong) CADisplayLink *espDisplayLink;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *espEntities;
@property (nonatomic, assign) CFAbsoluteTime espLastRescan;
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
        {"il2cpp_object_unbox", (void **)&g_il2cpp_object_unbox},
        {"il2cpp_object_get_class", (void **)&g_il2cpp_object_get_class},
        {"il2cpp_class_get_name", (void **)&g_il2cpp_class_get_name},
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

    // Hook-free ESP surface: enumerate Creature components and project their
    // Transform positions through Camera.main. All calls go through managed
    // reflection/runtime_invoke, so no executable code is patched.
    g_creature_class = g_il2cpp_class_from_name(gameImage, "", "Creature");
    if (unityImage) {
        Il2CppClass *componentClass = g_il2cpp_class_from_name(unityImage, "UnityEngine", "Component");
        Il2CppClass *transformClass = g_il2cpp_class_from_name(unityImage, "UnityEngine", "Transform");
        Il2CppClass *cameraClass = g_il2cpp_class_from_name(unityImage, "UnityEngine", "Camera");
        Il2CppClass *screenClass = g_il2cpp_class_from_name(unityImage, "UnityEngine", "Screen");
        if (componentClass) g_component_get_transform_method =
            g_il2cpp_class_get_method_from_name(componentClass, "get_transform", 0);
        if (transformClass) g_transform_get_position_method =
            g_il2cpp_class_get_method_from_name(transformClass, "get_position", 0);
        if (cameraClass) {
            g_camera_get_main_method = g_il2cpp_class_get_method_from_name(cameraClass, "get_main", 0);
            g_camera_world_to_screen_method =
                g_il2cpp_class_get_method_from_name(cameraClass, "WorldToScreenPoint", 1);
        }
        if (screenClass) {
            g_screen_get_width_method = g_il2cpp_class_get_method_from_name(screenClass, "get_width", 0);
            g_screen_get_height_method = g_il2cpp_class_get_method_from_name(screenClass, "get_height", 0);
        }
    }
    EmberSnLog(@"ESP reflection creature=%p transform=%p position=%p camera=%p project=%p screen=%p/%p",
               g_creature_class, g_component_get_transform_method, g_transform_get_position_method,
               g_camera_get_main_method, g_camera_world_to_screen_method,
               g_screen_get_width_method, g_screen_get_height_method);

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

#pragma mark - Entity ESP overlay

@interface EmberSnESPView : UIView
@property (nonatomic, copy) NSArray<NSDictionary *> *markers;
@end

@implementation EmberSnESPView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) return;
    CGContextSetLineWidth(context, 1.5);
    for (NSDictionary *marker in self.markers ?: @[]) {
        CGRect box = [marker[@"rect"] CGRectValue];
        BOOL leviathan = [marker[@"leviathan"] boolValue];
        UIColor *color = leviathan
            ? [UIColor colorWithRed:1.0 green:0.20 blue:0.16 alpha:0.95]
            : [UIColor colorWithRed:0.15 green:0.88 blue:1.0 alpha:0.90];
        CGContextSetStrokeColorWithColor(context, color.CGColor);
        CGContextStrokeRect(context, box);

        NSString *label = marker[@"label"];
        if (label.length > 0) {
            NSDictionary *attributes = @{
                NSFontAttributeName: [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightBold],
                NSForegroundColorAttributeName: color,
                NSStrokeColorAttributeName: UIColor.blackColor,
                NSStrokeWidthAttributeName: @(-2.0)
            };
            [label drawAtPoint:CGPointMake(CGRectGetMinX(box), MAX(0, CGRectGetMinY(box) - 13))
                withAttributes:attributes];
        }
    }
}

@end

static Il2CppObject *EmberSnInvoke(const Il2CppMethod *method, void *instance, void **args) {
    if (!method || !g_il2cpp_runtime_invoke) return NULL;
    Il2CppException *exception = NULL;
    Il2CppObject *result = g_il2cpp_runtime_invoke(method, instance, args, &exception);
    return exception ? NULL : result;
}

static BOOL EmberSnUnboxVector3(Il2CppObject *boxed, EmberSnVector3 *value) {
    if (!boxed || !value || !g_il2cpp_object_unbox) return NO;
    void *payload = g_il2cpp_object_unbox(boxed);
    if (!payload) return NO;
    memcpy(value, payload, sizeof(*value));
    return YES;
}

static int EmberSnUnboxInt(Il2CppObject *boxed) {
    if (!boxed || !g_il2cpp_object_unbox) return 0;
    int *payload = (int *)g_il2cpp_object_unbox(boxed);
    return payload ? *payload : 0;
}

static BOOL EmberSnIsLeviathanName(NSString *className) {
    NSString *name = className.lowercaseString;
    return [name containsString:@"leviathan"] ||
           [name containsString:@"reaper"] ||
           [name containsString:@"seadragon"] ||
           [name containsString:@"seatreader"] ||
           [name containsString:@"emperor"];
}

#pragma mark - Controller

@implementation EmberSnController

+ (instancetype)sharedController {
    static EmberSnController *controller = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        controller = [[EmberSnController alloc] init];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        controller.espEnabled = [defaults boolForKey:@"EmberSubnautica.espEnabled"];
        controller.espLeviathansOnly = [defaults boolForKey:@"EmberSubnautica.espLeviathansOnly"];
        controller.espShowNames = [defaults objectForKey:@"EmberSubnautica.espShowNames"]
            ? [defaults boolForKey:@"EmberSubnautica.espShowNames"] : YES;
        float savedRange = [defaults floatForKey:@"EmberSubnautica.espMaxDistance"];
        controller.espMaxDistance = savedRange >= 50.0f ? savedRange : 300.0f;
    });
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
    [defaults setBool:self.espEnabled forKey:@"EmberSubnautica.espEnabled"];
    [defaults setBool:self.espLeviathansOnly forKey:@"EmberSubnautica.espLeviathansOnly"];
    [defaults setBool:self.espShowNames forKey:@"EmberSubnautica.espShowNames"];
    [defaults setFloat:self.espMaxDistance forKey:@"EmberSubnautica.espMaxDistance"];
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

- (void)rescanCreatures {
    // Expensive: full managed enumeration, throttled to ~2x per second.
    if (!g_resolved || !g_creature_class || !g_find_objects_of_type_method ||
        !g_il2cpp_class_get_type || !g_il2cpp_type_get_object) return;

    void *creatureType = g_il2cpp_type_get_object(g_il2cpp_class_get_type(g_creature_class));
    void *findArgs[1] = { creatureType };
    Il2CppObject *array = EmberSnInvoke(g_find_objects_of_type_method, NULL, findArgs);
    if (!array) return;
    uintptr_t count = *(uintptr_t *)((char *)array + 0x18);

    NSMutableArray<NSDictionary *> *entities = [NSMutableArray arrayWithCapacity:MIN(count, (uintptr_t)120)];
    for (uintptr_t i = 0; i < count && entities.count < 120; i++) {
        Il2CppObject *creature = *(Il2CppObject **)((char *)array + 0x20 + i * sizeof(void *));
        if (!creature) continue;
        NSString *className = @"Creature";
        if (g_il2cpp_object_get_class && g_il2cpp_class_get_name) {
            Il2CppClass *klass = g_il2cpp_object_get_class(creature);
            const char *rawName = klass ? g_il2cpp_class_get_name(klass) : NULL;
            if (rawName) className = [NSString stringWithUTF8String:rawName] ?: @"Creature";
        }
        BOOL leviathan = EmberSnIsLeviathanName(className);
        if (self.espLeviathansOnly && !leviathan) continue;
        [entities addObject:@{
            @"obj": [NSValue valueWithPointer:creature],
            @"name": className,
            @"leviathan": @(leviathan)
        }];
    }
    self.espEntities = entities;
    self.espLastRescan = CACurrentMediaTime();
}

- (void)updateESP {
    EmberSnESPView *overlay = (EmberSnESPView *)self.espView;
    if (!self.espEnabled || !overlay || !g_resolved || !g_creature_class ||
        !g_find_objects_of_type_method || !g_il2cpp_class_get_type ||
        !g_il2cpp_type_get_object || !g_component_get_transform_method ||
        !g_transform_get_position_method || !g_camera_get_main_method ||
        !g_camera_world_to_screen_method || !g_screen_get_width_method ||
        !g_screen_get_height_method) {
        overlay.markers = @[];
        [overlay setNeedsDisplay];
        return;
    }

    // Per-frame: camera + projection only. Entity enumeration is cached
    // (rescanCreatures, ~0.5s cadence) so this stays at full frame rate.
    if (CACurrentMediaTime() - self.espLastRescan > 0.5) {
        [self rescanCreatures];
    }

    Il2CppObject *camera = EmberSnInvoke(g_camera_get_main_method, NULL, NULL);
    int screenWidth = EmberSnUnboxInt(EmberSnInvoke(g_screen_get_width_method, NULL, NULL));
    int screenHeight = EmberSnUnboxInt(EmberSnInvoke(g_screen_get_height_method, NULL, NULL));
    if (!camera || screenWidth <= 0 || screenHeight <= 0) return;

    NSMutableArray<NSDictionary *> *markers = [NSMutableArray arrayWithCapacity:self.espEntities.count];
    CGRect bounds = overlay.bounds;
    BOOL unityLandscape = screenWidth > screenHeight;
    BOOL viewLandscape = CGRectGetWidth(bounds) > CGRectGetHeight(bounds);

    for (NSDictionary *entity in self.espEntities) {
        Il2CppObject *creature = [(NSValue *)entity[@"obj"] pointerValue];
        if (!creature) continue;
        NSString *className = entity[@"name"];
        BOOL leviathan = [entity[@"leviathan"] boolValue];

        Il2CppObject *transform = EmberSnInvoke(g_component_get_transform_method, creature, NULL);
        EmberSnVector3 world = {0};
        if (!transform || !EmberSnUnboxVector3(
                EmberSnInvoke(g_transform_get_position_method, transform, NULL), &world)) continue;

        void *projectArgs[1] = { &world };
        EmberSnVector3 screen = {0};
        if (!EmberSnUnboxVector3(
                EmberSnInvoke(g_camera_world_to_screen_method, camera, projectArgs), &screen)) continue;
        if (screen.z <= 0.1f || screen.z > self.espMaxDistance) continue;

        // Unity screen coords: pixels, origin bottom-left, in the game's
        // rendering orientation. Map onto the overlay (points, origin
        // top-left), transposing if the spaces disagree on orientation.
        CGFloat nx = screen.x / (CGFloat)screenWidth;
        CGFloat ny = screen.y / (CGFloat)screenHeight;
        CGFloat x, y;
        if (unityLandscape == viewLandscape) {
            x = nx * CGRectGetWidth(bounds);
            y = (1.0 - ny) * CGRectGetHeight(bounds);
        } else {
            CGFloat swapped = ny;
            ny = nx;
            nx = 1.0 - swapped;
            x = nx * CGRectGetWidth(bounds);
            y = (1.0 - ny) * CGRectGetHeight(bounds);
        }
        if (x < -40 || x > CGRectGetWidth(bounds) + 40 ||
            y < -40 || y > CGRectGetHeight(bounds) + 40) continue;

        CGFloat scale = 15.0 / MAX(screen.z, 5.0f);
        CGFloat width = leviathan ? 220.0 * scale : 80.0 * scale;
        width = MAX(leviathan ? 28.0 : 14.0, MIN(leviathan ? 190.0 : 72.0, width));
        CGFloat height = width * (leviathan ? 0.62 : 0.82);
        CGRect box = CGRectMake(x - width * 0.5, y - height * 0.5, width, height);
        NSString *label = self.espShowNames
            ? [NSString stringWithFormat:@"%@  %.0fm", className, screen.z]
            : @"";
        [markers addObject:@{
            @"rect": [NSValue valueWithCGRect:box],
            @"leviathan": @(leviathan),
            @"label": label
        }];
    }

    overlay.markers = markers;
    [overlay setNeedsDisplay];
}

- (void)espFrame:(CADisplayLink *)displayLink {
    [self updateESP];
}

- (void)startESPDisplayLink {
    if (self.espDisplayLink || !self.espEnabled) return;
    self.espDisplayLink = [CADisplayLink displayLinkWithTarget:self
                                                      selector:@selector(espFrame:)];
    self.espDisplayLink.preferredFramesPerSecond = 60;
    [self.espDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)stopESPDisplayLink {
    [self.espDisplayLink invalidate];
    self.espDisplayLink = nil;
}

- (void)install {
    UIWindow *host = UIApplication.sharedApplication.keyWindow;
    if (!host) return;
    if (self.hostWindow && self.hostWindow != host) {
        [self.button removeFromSuperview];
        [self.espView removeFromSuperview];
        self.button = nil;
        self.espView = nil;
    }

    if (self.espEnabled && self.espView.superview != host) {
        EmberSnESPView *overlay = [[EmberSnESPView alloc] initWithFrame:host.bounds];
        [host addSubview:overlay];
        self.espView = overlay;
    } else if (!self.espEnabled && self.espView) {
        [self.espView removeFromSuperview];
        self.espView = nil;
    }

    if (self.button.superview == host) {
        if (self.espView) [host bringSubviewToFront:self.espView];
        [host bringSubviewToFront:self.button];
        if (self.panel) [host bringSubviewToFront:self.panel];
        return;
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
    if (self.espView) [host bringSubviewToFront:self.espView];
    [host bringSubviewToFront:button];
    self.button = button;
    self.hostWindow = host;
    [self updateButtonTitle];
}

- (void)start {
    [self install];
    [self startESPDisplayLink];
    [self.keepAliveTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                          repeats:YES
                                                            block:^(NSTimer *timer) {
        [weakSelf install];
        EmberSnResolveRuntime();
        [weakSelf updateESP];
        [weakSelf updateButtonTitle];
    }];
}

- (void)stop {
    [self stopESPDisplayLink];
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
    } else if (tab == 3) {
        [panel addSection:@"ENTITY BOX ESP"];
        [panel addToggle:@"ENABLE ESP" detail:@"Cyan fish boxes; red leviathan boxes" enabled:self.espEnabled handler:^(BOOL enabled) {
            weakSelf.espEnabled = enabled;
            [weakSelf saveSettings];
            [weakSelf install];
            if (enabled) {
                [weakSelf startESPDisplayLink];
            } else {
                [weakSelf stopESPDisplayLink];
            }
            [weakSelf updateESP];
        }];
        [panel addToggle:@"LEVIATHANS ONLY" detail:@"Hide ordinary fish and predators" enabled:self.espLeviathansOnly handler:^(BOOL enabled) {
            weakSelf.espLeviathansOnly = enabled;
            [weakSelf saveSettings];
            [weakSelf updateESP];
        }];
        [panel addToggle:@"SHOW TYPE + DISTANCE" detail:@"Labels use each creature's runtime class" enabled:self.espShowNames handler:^(BOOL enabled) {
            weakSelf.espShowNames = enabled;
            [weakSelf saveSettings];
            [weakSelf updateESP];
        }];
        [panel addSlider:@"MAX RANGE" value:self.espMaxDistance min:50.0f max:600.0f format:@"%.0fm" handler:^(float value) {
            weakSelf.espMaxDistance = value;
            [weakSelf saveSettings];
            [weakSelf updateESP];
        }];
        [panel addSection:@"IMPLEMENTATION"];
        [panel addAction:@"REFRESH ENTITIES" detail:@"Re-enumerate active Creature components now" handler:^{
            [weakSelf updateESP];
        }];
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
    [panel setTabs:@[@"Survival", @"Cheats", @"Build", @"ESP", @"Speed"] activeTab:0 handler:^(NSInteger index) {
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
