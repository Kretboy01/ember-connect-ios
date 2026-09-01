// GettingOverIt.m — Ember Connect practice controls for Getting Over It.
//
// # Why the previous rewrite never worked
//
// The tweak resolved the IL2CPP API (il2cpp_domain_get, icalls, …) from a
// UnityFramework.framework. This game statically links its IL2CPP runtime
// into the stripped main executable — there is no UnityFramework and no
// exported il2cpp symbols at all (verified with Il2CppDumper: the runtime is
// in the main binary, Unity 2020.2, metadata v24.1). Resolution could never
// succeed, so every feature silently did nothing.
//
// # How this version works
//
// Il2CppDumper mapped the compiled managed methods to file offsets inside the
// main binary. At runtime the tweak takes the main executable's load address
// (`_dyld_get_image_header(0)` + slide) and calls the compiled methods
// directly at their offsets:
//
//   UnityEngine.Time.set_timeScale(float)                   @ RVA 0x11954FC
//   UnityEngine.Physics2D.set_gravity_Injected(ref Vector2) @ RVA 0x11BED18
//
// Compiled IL2CPP methods take a trailing MethodInfo* which may be NULL for
// simple engine wrappers. No IL2CPP API, no instance lookups — two direct
// calls per settings change.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

#define EMBER_GOI_BUTTON_TAG 0xFB003

// Offsets produced by Il2CppDumper (goi-binary + global-metadata.dat v24.1).
#define GOI_RVA_TIME_SET_TIMESCALE        0x11954FCUL
#define GOI_RVA_TIME_SET_FIXEDDELTATIME   0x119542CUL
#define GOI_RVA_PHYSICS2D_SET_GRAVITY_INJ 0x11BED18UL
#define GOI_GRAVITY_BASE_Y                (-9.81f)
#define GOI_BASE_FIXED_DELTA              0.02f

static void *g_image_base = NULL;
static BOOL g_binary_verified = NO;
static CFAbsoluteTime g_loadTime = 0;

/// The engine must be fully initialized before our direct calls are safe —
/// an early auto-applied call crashed the process (verified on-device).
/// Settings are only applied from the menu, long after launch, so require
/// the game to have been running for a few seconds.
static BOOL EmberGoiReadyToApply(void) {
    return g_image_base != NULL && (CACurrentMediaTime() - g_loadTime) > 5.0;
}

typedef void (*TimeSetTimeScaleFunc)(float value, void *methodInfo);
typedef void (*TimeSetFixedDeltaTimeFunc)(float value, void *methodInfo);
typedef void (*Physics2DSetGravityInjectedFunc)(void *gravity, void *methodInfo);

#pragma mark - Diagnostics

static NSMutableString *g_diagLog = nil;
static NSString *g_diagPath = nil;

static void EmberGoiLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void EmberGoiLog(NSString *fmt, ...) {
    if (!g_diagLog) g_diagLog = [NSMutableString new];
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *stamp = [NSString stringWithFormat:@"[%.2f] %@\n", CACurrentMediaTime(), line];
    NSLog(@"[Ember/GOI] %@", line);
    @synchronized (g_diagLog) { [g_diagLog appendString:stamp]; }
    if (!g_diagPath) {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (dirs.count > 0) {
            NSString *dir = [dirs.firstObject stringByAppendingPathComponent:@"EmberConnect"];
            [NSFileManager.defaultManager createDirectoryAtPath:dir
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:nil];
            g_diagPath = [dir stringByAppendingPathComponent:@"GettingOverIt-diag.log"];
        }
    }
    if (g_diagPath) {
        @synchronized (g_diagLog) {
            [g_diagLog writeToFile:g_diagPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
}

@class EmberGoiMenuPanel;

@interface EmberGoiController : NSObject
@property (nonatomic, assign) CGFloat speedFactor;       // Time.timeScale
@property (nonatomic, assign) CGFloat gravityFactor;     // Physics2D.gravity scale
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) EmberGoiMenuPanel *panel;
@property (nonatomic, strong) NSTimer *keepAliveTimer;
@property (nonatomic, assign) BOOL appliedOnce;
+ (instancetype)sharedController;
- (void)start;
- (void)stop;
- (UIViewController *)topViewController;
@end

/// The game's own windows come and go, and custom overlay windows get
/// buried, mis-rotated, or swallow touches. LiveContainer's own floating
/// dock solves this the simple way (MultitaskDockView.swift): it adds its
/// view as a plain subview of the GAME'S key window
/// (`windowScene.windows.first`) and calls bringSubviewToFront on every
/// tick. Same window as the game = same orientation, always on top, touches
/// just work.


#pragma mark - Custom menu panel

@interface EmberGoiMenuPanel : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIStackView *rows;
@property (nonatomic, assign) NSUInteger rowCount;
@property (nonatomic, copy) void (^onClose)(void);
@end

@implementation EmberGoiMenuPanel

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.96];
        self.layer.cornerRadius = 14;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
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

static void toast_goi(NSString *message) {
    UIViewController *presenter = [[EmberGoiController sharedController] topViewController];
    if (!presenter) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [[EmberGoiController sharedController] topViewController];
        if (!top) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Ember Connect"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - Runtime + direct calls

/// Verifies the Getting Over It binary is loaded and records its load
/// address. In a LiveContainer guest the game binary is loaded as a dynamic
/// image (image 0 is the host's LiveContainer executable!), so we must scan
/// every image for it. RVAs from the dump are relative to the game's __TEXT
/// vmaddr (0x100000000), and _dyld_get_image_header(i) is exactly
/// slide + vmaddr, so target = header + RVA.
static BOOL EmberGoiEnsureRuntime(void) {
    if (g_image_base) return YES;

    static BOOL loggedFailure = NO;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *imageName = [NSString stringWithUTF8String:name];
        if ([imageName.lastPathComponent.lowercaseString isEqualToString:@"gettingoverit"]) {
            g_image_base = (void *)_dyld_get_image_header(i);
            EmberGoiLog(@"guest binary found (image %u) at %p, slide=%lld",
                        i, g_image_base, (long long)_dyld_get_image_vmaddr_slide(i));
            return YES;
        }
    }
    if (!loggedFailure) {
        EmberGoiLog(@"guest binary not loaded yet");
        loggedFailure = YES;
    }
    return NO;
}

static void EmberGoiApplyTimeScale(CGFloat factor) {
    if (!EmberGoiEnsureRuntime()) return;
    TimeSetTimeScaleFunc setTimeScale =
        (TimeSetTimeScaleFunc)((char *)g_image_base + GOI_RVA_TIME_SET_TIMESCALE);
    float clamped = (float)MAX(0.05, MIN(4.0, factor));
    setTimeScale(clamped, NULL);
    // Scale the physics step with the time scale so slow motion stays smooth
    // instead of stuttering (classic Unity slow-mo trick).
    TimeSetFixedDeltaTimeFunc setFixed =
        (TimeSetFixedDeltaTimeFunc)((char *)g_image_base + GOI_RVA_TIME_SET_FIXEDDELTATIME);
    float fixedDelta = GOI_BASE_FIXED_DELTA * clamped;
    setFixed(fixedDelta, NULL);
    EmberGoiLog(@"timeScale -> %.2f (fixedDeltaTime %.4f)", clamped, fixedDelta);
}

static void EmberGoiApplyGravity(CGFloat factor) {
    if (!EmberGoiEnsureRuntime()) return;
    Physics2DSetGravityInjectedFunc setGravity =
        (Physics2DSetGravityInjectedFunc)((char *)g_image_base + GOI_RVA_PHYSICS2D_SET_GRAVITY_INJ);
    // Base Physics2D gravity is (0, -9.81); scale the Y component and clamp
    // so a fat-fingered value can never launch the player into orbit.
    float clamped = (float)MAX(-3.0, MIN(3.0, factor));
    struct { float x; float y; } gravity = { 0.0f, GOI_GRAVITY_BASE_Y * clamped };
    setGravity(&gravity, NULL);
    EmberGoiLog(@"gravity factor -> %.2f (y=%.2f)", clamped, gravity.y);
}

#pragma mark - Controller

@implementation EmberGoiController

+ (instancetype)sharedController {
    static EmberGoiController *controller = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controller = [[EmberGoiController alloc] init]; });
    return controller;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _speedFactor = 1.0;
        _gravityFactor = 1.0;
    }
    return self;
}

#pragma mark - Host window (LiveContainer dock pattern)

/// The floating button and menu panel are plain subviews of the game's key
/// window, exactly like LiveContainer's own dock
/// (keyWindow.addSubview + bringSubviewToFront). Prefer the scene's actual
/// key window; log the full window inventory so a wrong pick is visible in
/// the diag.
static UIWindow *EmberGoiHostWindow(void) {
    for (__kindof UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState == UISceneActivationStateBackground) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;

        if ([windowScene respondsToSelector:@selector(keyWindow)] &&
            windowScene.keyWindow) {
            return windowScene.keyWindow;
        }

        UIWindow *fallback = windowScene.windows.firstObject;
        if (fallback) {
            EmberGoiLog(@"falling back to windows.first (keyWindow unavailable)");
            return fallback;
        }
    }
    return UIApplication.sharedApplication.keyWindow;
}

static void EmberGoiLogWindowInventory(void) {
    NSMutableString *report = [NSMutableString new];
    [report appendString:@"window inventory:\n"];
    for (__kindof UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        [report appendFormat:@"  scene %@ state=%ld\n",
            windowScene.title ?: @"(untitled)", (long)windowScene.activationState];
        for (UIWindow *window in windowScene.windows) {
            NSString *rootClass = window.rootViewController ?
                NSStringFromClass(window.rootViewController.class) : @"(none)";
            [report appendFormat:@"    %@ level=%.0f key=%d bounds=%@ root=%@\n",
                NSStringFromClass(window.class), (double)window.windowLevel,
                window.isKeyWindow, NSStringFromCGRect(window.bounds), rootClass];
        }
    }
    EmberGoiLog(@"%@", report);
}

- (UIViewController *)topViewController {
    UIWindow *host = EmberGoiHostWindow();
    UIViewController *root = host.rootViewController;
    while (root.presentedViewController) {
        root = root.presentedViewController;
    }
    return root;
}

- (void)clampButton {
    UIWindow *host = EmberGoiHostWindow();
    if (!self.button || !host) return;
    CGRect bounds = host.bounds;
    CGFloat halfW = CGRectGetWidth(self.button.frame) / 2 + 4;
    CGFloat halfH = CGRectGetHeight(self.button.frame) / 2 + 4;
    CGPoint center = self.button.center;
    center.x = MAX(halfW, MIN(CGRectGetWidth(bounds) - halfW, center.x));
    center.y = MAX(halfH, MIN(CGRectGetHeight(bounds) - halfH, center.y));
    if (!CGPointEqualToPoint(center, self.button.center)) {
        self.button.center = center;
    }
}

- (void)saveSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:self.speedFactor forKey:@"EmberGOI.speedFactor"];
    [defaults setDouble:self.gravityFactor forKey:@"EmberGOI.gravityFactor"];
    [defaults setDouble:self.button.center.x forKey:@"EmberGOI.buttonX"];
    [defaults setDouble:self.button.center.y forKey:@"EmberGOI.buttonY"];
}

- (void)loadSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    double speed = [defaults doubleForKey:@"EmberGOI.speedFactor"];
    double gravity = [defaults doubleForKey:@"EmberGOI.gravityFactor"];
    if (speed > 0.04 && speed <= 4.0) self.speedFactor = speed;
    if (gravity >= -3.0 && gravity <= 3.0 && [defaults objectForKey:@"EmberGOI.gravityFactor"]) {
        self.gravityFactor = gravity;
    }
}

- (void)applyAll {
    EmberGoiApplyTimeScale(self.speedFactor);
    EmberGoiApplyGravity(self.gravityFactor);
    self.appliedOnce = YES;
}

- (void)updateButtonTitle {
    NSString *state = EmberGoiEnsureRuntime() ? @"Tools" : @"Waiting…";
    [self.button setTitle:[NSString stringWithFormat:@"GOI %@", state]
                 forState:UIControlStateNormal];
}

- (void)logInventoryOnce {
    EmberGoiLogWindowInventory();
}

- (void)dragged:(UIPanGestureRecognizer *)recognizer {
    UIView *view = recognizer.view;
    CGPoint translation = [recognizer translationInView:view.superview];
    view.center = CGPointMake(view.center.x + translation.x, view.center.y + translation.y);
    [recognizer setTranslation:CGPointZero inView:view.superview];
    if (recognizer.state == UIGestureRecognizerStateEnded) {
        [self clampButton];
        [self saveSettings];
    }
}

- (void)install {
    UIWindow *host = EmberGoiHostWindow();
    if (!host) return;
    static BOOL loggedInventory = NO;
    if (!loggedInventory) {
        loggedInventory = YES;
        [self performSelector:@selector(logInventoryOnce) withObject:nil afterDelay:1.0];
    }
    if (self.button.superview == host) {
        [host bringSubviewToFront:self.button];
        [self clampButton];
        return;
    }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.tag = EMBER_GOI_BUTTON_TAG;
    button.frame = CGRectMake(0, 0, 92, 36);
    button.backgroundColor = [UIColor colorWithRed:0.42 green:0.22 blue:0.05 alpha:0.82];
    CGFloat savedX = [NSUserDefaults.standardUserDefaults doubleForKey:@"EmberGOI.buttonX"];
    CGFloat savedY = [NSUserDefaults.standardUserDefaults doubleForKey:@"EmberGOI.buttonY"];
    CGFloat defaultX = CGRectGetWidth(host.bounds) - 62;
    CGFloat defaultY = CGRectGetHeight(host.bounds) / 2;
    button.center = CGPointMake(savedX > 0 ? savedX : defaultX, savedY > 0 ? savedY : defaultY);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                              UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    button.layer.cornerRadius = 11;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
    button.accessibilityLabel = @"Ember Connect Getting Over It tools";
    [button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
    pan.cancelsTouchesInView = NO;
    [button addGestureRecognizer:pan];

    [host addSubview:button];
    [host bringSubviewToFront:button];
    self.button = button;
    [self clampButton];
    [self updateButtonTitle];
}

- (void)start {
    [self install];
    [self updateButtonTitle];
    [self.keepAliveTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                          repeats:YES
                                                            block:^(NSTimer *timer) {
        [weakSelf install];
    }];
}

- (void)stop {
    [self.keepAliveTimer invalidate];
    self.keepAliveTimer = nil;
}



- (void)closePanel {
    [self.panel removeFromSuperview];
    self.panel = nil;
}

- (void)showPanel:(void (^)(EmberGoiMenuPanel *panel))build {
    UIWindow *host = EmberGoiHostWindow();
    if (!host) return;
    [self closePanel];
    EmberGoiMenuPanel *panel = [[EmberGoiMenuPanel alloc] initWithFrame:CGRectZero];
    panel.onClose = ^{ [self closePanel]; };
    build(panel);
    [panel finalizeLayout];
    panel.center = CGPointMake(CGRectGetMidX(host.bounds),
                               CGRectGetMidY(host.bounds));
    panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                             UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [host addSubview:panel];
    [host bringSubviewToFront:panel];
    self.panel = panel;
}

- (void)showMainPanel {
    __weak typeof(self) weakSelf = self;
    [self showPanel:^(EmberGoiMenuPanel *panel) {
        [panel setHeader:@"Getting Over It Tools"
                subtitle:[NSString stringWithFormat:@"Speed %.2fx · Gravity %.2fx",
                          weakSelf.speedFactor, weakSelf.gravityFactor]];
        [panel addOption:@"Game Speed ▸" handler:^{ [weakSelf showSpeedPanel]; }];
        [panel addOption:@"Gravity ▸" handler:^{ [weakSelf showGravityPanel]; }];
        [panel addOption:@"Profiles ▸" handler:^{ [weakSelf showProfilesPanel]; }];
        [panel addOption:@"Reset to 1x speed / 1x gravity" handler:^{
            weakSelf.speedFactor = 1.0;
            weakSelf.gravityFactor = 1.0;
            [weakSelf saveSettings];
            [weakSelf applyAll];
            [weakSelf updateButtonTitle];
            [weakSelf closePanel];
        }];
    }];
}

- (void)showSpeedPanel {
    __weak typeof(self) weakSelf = self;
    [self showPanel:^(EmberGoiMenuPanel *panel) {
        [panel setHeader:@"Game Speed" subtitle:@"Time.timeScale"];
        void (^apply)(CGFloat) = ^(CGFloat factor) {
            if (!EmberGoiReadyToApply()) {
                toast_goi(@"Give the game a few more seconds to load, then try again.");
                return;
            }
            weakSelf.speedFactor = factor;
            [weakSelf saveSettings];
            EmberGoiApplyTimeScale(factor);
            [weakSelf updateButtonTitle];
            [weakSelf closePanel];
        };
        [panel addOption:@"0.1x — bullet time" handler:^{ apply(0.1); }];
        [panel addOption:@"0.25x — ultra slow" handler:^{ apply(0.25); }];
        [panel addOption:@"0.5x — slow" handler:^{ apply(0.5); }];
        [panel addOption:@"0.65x — easy climb" handler:^{ apply(0.65); }];
        [panel addOption:@"1x — normal" handler:^{ apply(1.0); }];
        [panel addOption:@"1.5x — speed run" handler:^{ apply(1.5); }];
    }];
}


- (void)showGravityPanel {
    __weak typeof(self) weakSelf = self;
    [self showPanel:^(EmberGoiMenuPanel *panel) {
        [panel setHeader:@"Gravity" subtitle:@"Physics2D.gravity scale"];
        void (^apply)(CGFloat) = ^(CGFloat factor) {
            if (!EmberGoiReadyToApply()) {
                toast_goi(@"Give the game a few more seconds to load, then try again.");
                return;
            }
            weakSelf.gravityFactor = factor;
            [weakSelf saveSettings];
            EmberGoiApplyGravity(factor);
            [weakSelf updateButtonTitle];
            [weakSelf closePanel];
        };
        [panel addOption:@"0x — zero-G float" handler:^{ apply(0.0); }];
        [panel addOption:@"0.3x — moon" handler:^{ apply(0.3); }];
        [panel addOption:@"0.45x — easy climb" handler:^{ apply(0.45); }];
        [panel addOption:@"1x — normal" handler:^{ apply(1.0); }];
        [panel addOption:@"1.5x — heavy" handler:^{ apply(1.5); }];
    }];
}


- (void)showProfilesPanel {
    __weak typeof(self) weakSelf = self;
    [self showPanel:^(EmberGoiMenuPanel *panel) {
        [panel setHeader:@"Practice Profiles" subtitle:@"Applies instantly"];
        void (^apply)(CGFloat, CGFloat) = ^(CGFloat s, CGFloat g) {
            if (!EmberGoiReadyToApply()) {
                toast_goi(@"Give the game a few more seconds to load, then try again.");
                return;
            }
            weakSelf.speedFactor = s;
            weakSelf.gravityFactor = g;
            [weakSelf saveSettings];
            EmberGoiApplyTimeScale(s);
            EmberGoiApplyGravity(g);
            [weakSelf updateButtonTitle];
            [weakSelf closePanel];
        };
        [panel addOption:@"Easy Climb — 0.65x speed, 0.45x gravity" handler:^{ apply(0.65, 0.45); }];
        [panel addOption:@"Moon Jump — 1x speed, 0.3x gravity" handler:^{ apply(1.0, 0.3); }];
        [panel addOption:@"Zero-G Float — 1x speed, no gravity" handler:^{ apply(1.0, 0.0); }];
        [panel addOption:@"Speed Run — 1.5x speed, 1x gravity" handler:^{ apply(1.5, 1.0); }];
        [panel addOption:@"Defaults — 1x / 1x" handler:^{ apply(1.0, 1.0); }];
    }];
}

- (void)tapped {
    if (self.panel) {
        [self closePanel];
        return;
    }
    [self showMainPanel];
}

@end

#pragma mark - Bootstrap

__attribute__((constructor))
static void EmberGettingOverItInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        NSString *executable = NSBundle.mainBundle.executablePath.lastPathComponent.lowercaseString;
        BOOL expectedBundle = [bundleIdentifier isEqualToString:@"net.foddy.gettingoverit"];
        BOOL expectedRuntime = [executable isEqualToString:@"gettingoverit"];
        // LiveContainer can briefly expose the host bundle while a guest is
        // being brought up, so accept the executable name as the runtime
        // signature too.
        if (!expectedBundle && !expectedRuntime) {
            EmberGoiLog(@"wrong bundle: %@ (%@)", bundleIdentifier, executable);
            return;
        }
        g_loadTime = CACurrentMediaTime();
        EmberGoiLog(@"tweak loaded in %@", bundleIdentifier);

        EmberGoiController *controller = [EmberGoiController sharedController];
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

