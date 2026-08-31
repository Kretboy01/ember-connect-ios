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
#define GOI_RVA_PHYSICS2D_SET_GRAVITY_INJ 0x11BED18UL
#define GOI_GRAVITY_BASE_Y                (-9.81f)

static void *g_image_base = NULL;
static BOOL g_binary_verified = NO;

typedef void (*TimeSetTimeScaleFunc)(float value, void *methodInfo);
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

@interface EmberGoiController : NSObject
@property (nonatomic, assign) CGFloat speedFactor;       // Time.timeScale
@property (nonatomic, assign) CGFloat gravityFactor;     // Physics2D.gravity scale
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UIWindow *overlayWindow;   // our own always-on-top window
@property (nonatomic, strong) UIViewController *overlayRoot;
@property (nonatomic, strong) NSTimer *keepAliveTimer;
@property (nonatomic, assign) BOOL appliedOnce;
+ (instancetype)sharedController;
- (void)start;
- (void)stop;
- (UIViewController *)topViewController;
@end

/// The game's own windows come and go (Unity recreates them on rotation and
/// scene loads), which used to tear the button and any presented menu down
/// with them. The tweak therefore owns a top-level overlay window whose root
/// view swallows no touches — everything falls through to the game except
/// the button itself.
@interface EmberGoiPassthroughView : UIView
@end

@implementation EmberGoiPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *result = [super hitTest:point withEvent:event];
    return result == self ? nil : result;
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

/// Verifies that image 0 is the Getting Over It executable and records its
/// load address. RVAs from the dump are relative to the __TEXT vmaddr
/// (0x100000000), which is exactly what _dyld_get_image_header returns
/// (rebased by the slide), so target = header + RVA.
static BOOL EmberGoiEnsureRuntime(void) {
    if (g_image_base) return YES;

    if (_dyld_image_count() == 0) return NO;
    const char *name = _dyld_get_image_name(0);
    if (!name) return NO;
    NSString *imageName = [NSString stringWithUTF8String:name];
    if (![imageName.lowercaseString containsString:@"gettingoverit"]) {
        EmberGoiLog(@"image 0 is not GettingOverIt: %@", imageName);
        return NO;
    }
    g_binary_verified = YES;
    g_image_base = (void *)_dyld_get_image_header(0);
    EmberGoiLog(@"main binary at %p (%@), slide=%lld",
                g_image_base, imageName.lastPathComponent,
                (long long)_dyld_get_image_vmaddr_slide(0));
    return YES;
}

static void EmberGoiApplyTimeScale(CGFloat factor) {
    if (!EmberGoiEnsureRuntime()) return;
    TimeSetTimeScaleFunc setTimeScale =
        (TimeSetTimeScaleFunc)((char *)g_image_base + GOI_RVA_TIME_SET_TIMESCALE);
    float clamped = (float)MAX(0.05, MIN(4.0, factor));
    setTimeScale(clamped, NULL);
    EmberGoiLog(@"timeScale -> %.2f", clamped);
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

- (UIViewController *)topViewController {
    return self.overlayRoot;
}

- (void)ensureOverlay {
    CGRect frame = [UIScreen.mainScreen bounds];
    if (!self.overlayWindow) {
        self.overlayWindow = [[UIWindow alloc] initWithFrame:frame];
        self.overlayWindow.windowLevel = UIWindowLevelAlert + 100.0;
        self.overlayWindow.backgroundColor = UIColor.clearColor;
        UIViewController *root = [[UIViewController alloc] init];
        root.view = [[EmberGoiPassthroughView alloc] initWithFrame:frame];
        root.view.backgroundColor = UIColor.clearColor;
        self.overlayWindow.rootViewController = root;
        self.overlayWindow.hidden = NO;
        EmberGoiLog(@"overlay window created");
    }
    // Track rotation / resolution changes every tick.
    self.overlayWindow.frame = frame;
    self.overlayRoot = self.overlayWindow.rootViewController;
}

- (void)clampButton {
    UIView *host = self.overlayRoot.view;
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
    NSString *state = self.appliedOnce ? @"Tools" : @"Waiting…";
    [self.button setTitle:[NSString stringWithFormat:@"GOI %@", state]
                 forState:UIControlStateNormal];
}

- (void)dragged:(UIPanGestureRecognizer *)recognizer {
    CGPoint translation = [recognizer translationInView:self.overlayRoot.view];
    UIView *view = recognizer.view;
    view.center = CGPointMake(view.center.x + translation.x, view.center.y + translation.y);
    [recognizer setTranslation:CGPointZero inView:self.overlayRoot.view];
    if (recognizer.state == UIGestureRecognizerStateEnded) {
        [self clampButton];
        [self saveSettings];
    }
}

- (void)install {
    [self ensureOverlay];
    UIView *host = self.overlayRoot.view;
    if (self.button.superview == host) {
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
    if (!self.appliedOnce && EmberGoiEnsureRuntime()) {
        [self loadSettings];
        [self applyAll];
        [self updateButtonTitle];
    }
    [self.keepAliveTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                          repeats:YES
                                                            block:^(NSTimer *timer) {
        [weakSelf install];
        if (!weakSelf.appliedOnce && EmberGoiEnsureRuntime()) {
            [weakSelf loadSettings];
            [weakSelf applyAll];
            [weakSelf updateButtonTitle];
        }
    }];
}

- (void)stop {
    [self.keepAliveTimer invalidate];
    self.keepAliveTimer = nil;
}



- (void)showMainMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return;

    NSString *header = self.appliedOnce
        ? [NSString stringWithFormat:@"Speed %.2fx · Gravity %.2fx",
            self.speedFactor, self.gravityFactor]
        : @"Waiting for the game runtime. Settings apply automatically once it is ready.";

    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Getting Over It Tools"
                                                                  message:header
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;

    [menu addAction:[UIAlertAction actionWithTitle:@"Game Speed…"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf showSpeedMenu]; });
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Gravity…"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf showGravityMenu]; });
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Practice Profiles…"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf showProfilesMenu]; });
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Close"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)showSpeedMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Game Speed (Time.timeScale)"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    void (^apply)(CGFloat) = ^(CGFloat factor) {
        weakSelf.speedFactor = factor;
        [weakSelf saveSettings];
        EmberGoiApplyTimeScale(factor);
        [weakSelf updateButtonTitle];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf showSpeedMenu]; });
    };
    [menu addAction:[UIAlertAction actionWithTitle:@"0.25x — ultra slow"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(0.25); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"0.5x — slow"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(0.5); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"0.65x — easy climb"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(0.65); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"1x — normal"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(1.0); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"1.5x — speed run"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(1.5); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Back"
                                             style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf showMainMenu]; });
    }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}


- (void)showGravityMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Gravity (Physics2D.gravity scale)"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    void (^apply)(CGFloat) = ^(CGFloat factor) {
        weakSelf.gravityFactor = factor;
        [weakSelf saveSettings];
        EmberGoiApplyGravity(factor);
        [weakSelf updateButtonTitle];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf showGravityMenu]; });
    };
    [menu addAction:[UIAlertAction actionWithTitle:@"0x — zero-G float"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(0.0); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"0.3x — moon"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(0.3); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"0.45x — easy climb"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(0.45); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"1x — normal"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(1.0); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"1.5x — heavy"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(1.5); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Back"
                                             style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf showMainMenu]; });
    }]];
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
    void (^apply)(CGFloat, CGFloat) = ^(CGFloat s, CGFloat g) {
        weakSelf.speedFactor = s;
        weakSelf.gravityFactor = g;
        [weakSelf saveSettings];
        EmberGoiApplyTimeScale(s);
        EmberGoiApplyGravity(g);
        [weakSelf updateButtonTitle];
        toast_goi([NSString stringWithFormat:@"Speed %.2fx, gravity %.2fx applied.", s, g]);
    };
    [menu addAction:[UIAlertAction actionWithTitle:@"Easy Climb — 0.65x speed, 0.45x gravity"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(0.65, 0.45); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Moon Jump — 1x speed, 0.3x gravity"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(1.0, 0.3); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Zero-G Float — 1x speed, no gravity"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(1.0, 0.0); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Speed Run — 1.5x speed, 1x gravity"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(1.5, 1.0); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Defaults — 1x / 1x"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { apply(1.0, 1.0); }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Back"
                                             style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction *a) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf showMainMenu]; });
    }]];
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

