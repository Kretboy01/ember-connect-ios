// EightBPOfflineLines.m — offline-only native guideline extension for 8 Ball Pool.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define EC_LINES_BUTTON_TAG 0x8B901

static NSString *const ECBundleIdentifier = @"com.miniclip.8ballpoolmult";
static NSString *const ECMultiplierKey = @"EmberEightBPOfflineLines.multiplier";
static NSString *const ECButtonXKey = @"EmberEightBPOfflineLines.buttonX";
static NSString *const ECButtonYKey = @"EmberEightBPOfflineLines.buttonY";

static id gECGameManager = nil;
static NSInteger gECMultiplier = 4;
static BOOL gECHooksInstalled = NO;
static int gECObservedLowAimRatio = 0;
static int gECObservedHighAimRatio = 0;

static void (*ECOriginalGameManagerOnEnter)(id, SEL) = NULL;
static void (*ECOriginalGameManagerOnExit)(id, SEL) = NULL;
static int (*ECOriginalLowAimRatio)(id, SEL) = NULL;
static int (*ECOriginalHighAimRatio)(id, SEL) = NULL;
static BOOL (*ECOriginalShowCueBallTrajectory)(id, SEL) = NULL;
static BOOL (*ECOriginalWideGuideline)(id, SEL) = NULL;

static BOOL ECInvokeBool(id object, NSString *selectorName, BOOL fallback) {
    if (!object) return fallback;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return fallback;
    BOOL (*implementation)(id, SEL) = (void *)[object methodForSelector:selector];
    return implementation ? implementation(object, selector) : fallback;
}

// Fail closed. A positive offline/practice signal is required and a positive
// network signal always wins. If a future game version removes any of the
// expected selectors, the tweak simply returns the original aim values.
static BOOL ECIsStrictlyOffline(void) {
    id manager = gECGameManager;
    if (!manager) return NO;
    BOOL offline = ECInvokeBool(manager, @"isOnOfflineGame", NO);
    BOOL practice = ECInvokeBool(manager, @"isOnPracticeGame", NO);
    BOOL networked = ECInvokeBool(manager, @"isOnNetworkedGame", YES);
    return (offline || practice) && !networked;
}

static BOOL ECExtensionIsActive(void) {
    return gECMultiplier > 1 && ECIsStrictlyOffline();
}

static void ECRefreshNativeGuide(void) {
    id manager = gECGameManager;
    if (!manager || !ECIsStrictlyOffline()) return;
    for (NSString *name in @[@"updateCueStatsAndVisualGuide", @"setShowCueBallTrajectory"]) {
        SEL selector = NSSelectorFromString(name);
        if ([manager respondsToSelector:selector]) {
            ((void (*)(id, SEL))objc_msgSend)(manager, selector);
        }
    }
}

static void ECWriteStatus(NSString *state) {
    NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!cache) return;
    NSString *folder = [cache stringByAppendingPathComponent:@"EmberConnect"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    NSDictionary *status = @{
        @"state": state ?: @"unknown",
        @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
        @"appVersion": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
        @"hooksInstalled": @(gECHooksInstalled),
        @"strictlyOffline": @(ECIsStrictlyOffline()),
        @"networkGuard": @YES,
        @"requestedMultiplier": @(gECMultiplier),
        @"effectiveMultiplier": @(ECExtensionIsActive() ? gECMultiplier : 1),
        @"observedLowAimRatio": @(gECObservedLowAimRatio),
        @"observedHighAimRatio": @(gECObservedHighAimRatio),
        @"updatedAt": @([NSDate.date timeIntervalSince1970])
    };
    [status writeToFile:[folder stringByAppendingPathComponent:@"EightBPOfflineLinesStatus.plist"]
              atomically:YES];
}

@class EmberEightBPOfflineLinesController;

static void ECGameManagerOnEnter(id self, SEL selector) {
    gECGameManager = self;
    if (ECOriginalGameManagerOnEnter) ECOriginalGameManagerOnEnter(self, selector);
    dispatch_async(dispatch_get_main_queue(), ^{
        ECRefreshNativeGuide();
        ECWriteStatus(@"game-entered");
    });
}

static void ECGameManagerOnExit(id self, SEL selector) {
    if (ECOriginalGameManagerOnExit) ECOriginalGameManagerOnExit(self, selector);
    if (gECGameManager == self) gECGameManager = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ ECWriteStatus(@"game-exited"); });
}

static int ECLowAimRatio(id self, SEL selector) {
    int value = ECOriginalLowAimRatio ? ECOriginalLowAimRatio(self, selector) : 0;
    gECObservedLowAimRatio = value;
    if (!ECExtensionIsActive() || value <= 0) return value;
    long long extended = (long long)value * (long long)gECMultiplier;
    return (int)MIN(extended, INT32_MAX);
}

static int ECHighAimRatio(id self, SEL selector) {
    int value = ECOriginalHighAimRatio ? ECOriginalHighAimRatio(self, selector) : 0;
    gECObservedHighAimRatio = value;
    if (!ECExtensionIsActive() || value <= 0) return value;
    long long extended = (long long)value * (long long)gECMultiplier;
    return (int)MIN(extended, INT32_MAX);
}

static BOOL ECShowCueBallTrajectory(id self, SEL selector) {
    BOOL original = ECOriginalShowCueBallTrajectory ? ECOriginalShowCueBallTrajectory(self, selector) : NO;
    return ECExtensionIsActive() ? YES : original;
}

static BOOL ECWideGuideline(id self, SEL selector) {
    BOOL original = ECOriginalWideGuideline ? ECOriginalWideGuideline(self, selector) : NO;
    return ECExtensionIsActive() ? YES : original;
}

static BOOL ECHookVoidMethod(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2 || method_getTypeEncoding(method)[0] != 'v') return NO;
    *original = method_setImplementation(method, replacement);
    return *original != NULL;
}

static BOOL ECHookIntGetter(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char *returnType = method_copyReturnType(method);
    BOOL compatible = returnType && (returnType[0] == 'i' || returnType[0] == 'I');
    if (returnType) free(returnType);
    if (!compatible) return NO;
    *original = method_setImplementation(method, replacement);
    return *original != NULL;
}

static BOOL ECHookBoolGetter(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char *returnType = method_copyReturnType(method);
    BOOL compatible = returnType && (returnType[0] == 'B' || returnType[0] == 'c');
    if (returnType) free(returnType);
    if (!compatible) return NO;
    *original = method_setImplementation(method, replacement);
    return *original != NULL;
}

static void ECInstallHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class gameManager = NSClassFromString(@"GameManager");
        Class userInfo = NSClassFromString(@"UserInfo");
        Class settings = NSClassFromString(@"UserSettingsManager");

        BOOL enterOK = ECHookVoidMethod(gameManager, NSSelectorFromString(@"onEnter"),
                                        (IMP)ECGameManagerOnEnter, (IMP *)&ECOriginalGameManagerOnEnter);
        BOOL exitOK = ECHookVoidMethod(gameManager, NSSelectorFromString(@"onExit"),
                                       (IMP)ECGameManagerOnExit, (IMP *)&ECOriginalGameManagerOnExit);
        BOOL lowOK = ECHookIntGetter(userInfo, NSSelectorFromString(@"lowAimRatio"),
                                     (IMP)ECLowAimRatio, (IMP *)&ECOriginalLowAimRatio);
        BOOL highOK = ECHookIntGetter(userInfo, NSSelectorFromString(@"highAimRatio"),
                                      (IMP)ECHighAimRatio, (IMP *)&ECOriginalHighAimRatio);

        // These visual helpers are optional. The two aim-ratio hooks above are
        // the actual line extension; these make the game's own line easier to
        // read without changing the player's saved settings.
        ECHookBoolGetter(settings, NSSelectorFromString(@"showCueBallTrajectory"),
                         (IMP)ECShowCueBallTrajectory, (IMP *)&ECOriginalShowCueBallTrajectory);
        ECHookBoolGetter(settings, NSSelectorFromString(@"wideGuideline"),
                         (IMP)ECWideGuideline, (IMP *)&ECOriginalWideGuideline);

        gECHooksInstalled = enterOK && exitOK && lowOK && highOK;
        ECWriteStatus(gECHooksInstalled ? @"hooks-installed" : @"incompatible-runtime");
    });
}

@interface EmberEightBPOfflineLinesController : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIButton *button;
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) NSTimer *keepAliveTimer;
+ (instancetype)sharedController;
@end

@implementation EmberEightBPOfflineLinesController

+ (instancetype)sharedController {
    static EmberEightBPOfflineLinesController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ controller = [EmberEightBPOfflineLinesController new]; });
    return controller;
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
    return best ?: UIApplication.sharedApplication.keyWindow;
}

- (UIViewController *)topViewController {
    UIViewController *controller = self.hostWindow.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    if ([controller isKindOfClass:UINavigationController.class]) {
        controller = ((UINavigationController *)controller).visibleViewController;
    } else if ([controller isKindOfClass:UITabBarController.class]) {
        controller = ((UITabBarController *)controller).selectedViewController;
    }
    return controller;
}

- (void)saveMultiplier:(NSInteger)multiplier {
    gECMultiplier = multiplier;
    [NSUserDefaults.standardUserDefaults setInteger:multiplier forKey:ECMultiplierKey];
    ECRefreshNativeGuide();
    [self updateButton];
    ECWriteStatus(@"setting-changed");
}

- (void)showOfflineLockedMessage {
    UIViewController *presenter = [self topViewController];
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Offline only"
        message:@"Extended lines stay locked during network matches. Start Practice or Play Offline, then open this button again."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)tapped {
    if (!ECIsStrictlyOffline()) {
        [self showOfflineLockedMessage];
        return;
    }
    UIViewController *presenter = [self topViewController];
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return;
    NSString *message = @"Uses 8 Ball's native aim range. It automatically returns to the untouched game values outside offline/practice play.";
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"EC Offline Lines"
        message:message preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSNumber *value in @[@1, @2, @4, @8]) {
        NSInteger multiplier = value.integerValue;
        NSString *label = multiplier == 1 ? @"Off" : [NSString stringWithFormat:@"%ldx length%@", (long)multiplier,
            multiplier == gECMultiplier ? @"  ✓" : @""];
        [menu addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf saveMultiplier:multiplier];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)dragged:(UIPanGestureRecognizer *)gesture {
    UIView *view = gesture.view;
    if (!view || !view.superview) return;
    CGPoint translation = [gesture translationInView:view.superview];
    view.center = CGPointMake(view.center.x + translation.x, view.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:view.superview];
    CGRect bounds = view.superview.bounds;
    CGFloat halfW = CGRectGetWidth(view.bounds) / 2.0;
    CGFloat halfH = CGRectGetHeight(view.bounds) / 2.0;
    view.center = CGPointMake(MIN(MAX(view.center.x, halfW + 4), CGRectGetWidth(bounds) - halfW - 4),
                              MIN(MAX(view.center.y, halfH + 4), CGRectGetHeight(bounds) - halfH - 4));
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        [NSUserDefaults.standardUserDefaults setDouble:view.center.x forKey:ECButtonXKey];
        [NSUserDefaults.standardUserDefaults setDouble:view.center.y forKey:ECButtonYKey];
    }
}

- (void)updateButton {
    UIButton *button = self.button;
    if (!button) return;
    BOOL offline = ECIsStrictlyOffline();
    NSString *title;
    UIColor *color;
    if (!offline) {
        title = @"EC Lines 🔒";
        color = [UIColor colorWithWhite:0.18 alpha:0.88];
    } else if (gECMultiplier <= 1) {
        title = @"EC Lines Off";
        color = [UIColor colorWithRed:0.55 green:0.25 blue:0.08 alpha:0.9];
    } else {
        title = [NSString stringWithFormat:@"EC Lines %ldx", (long)gECMultiplier];
        color = [UIColor colorWithRed:0.08 green:0.42 blue:0.25 alpha:0.92];
    }
    [button setTitle:title forState:UIControlStateNormal];
    button.backgroundColor = color;
}

- (void)install {
    UIWindow *host = [self guestWindow];
    if (!host) return;
    UIView *existing = [host viewWithTag:EC_LINES_BUTTON_TAG];
    if ([existing isKindOfClass:UIButton.class]) {
        self.button = (UIButton *)existing;
        self.hostWindow = host;
        [host bringSubviewToFront:existing];
        [self updateButton];
        return;
    }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = EC_LINES_BUTTON_TAG;
    button.bounds = CGRectMake(0, 0, 96, 38);
    CGFloat savedX = [NSUserDefaults.standardUserDefaults doubleForKey:ECButtonXKey];
    CGFloat savedY = [NSUserDefaults.standardUserDefaults doubleForKey:ECButtonYKey];
    CGFloat defaultX = CGRectGetWidth(host.bounds) - 58;
    CGFloat defaultY = MAX(52, host.safeAreaInsets.top + 24);
    button.center = CGPointMake(savedX > 0 ? savedX : defaultX, savedY > 0 ? savedY : defaultY);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    button.layer.cornerRadius = 11;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.35;
    button.layer.shadowRadius = 4;
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
    button.accessibilityLabel = @"Ember Connect offline extended lines";
    [button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
    pan.cancelsTouchesInView = NO;
    pan.delegate = self;
    [button addGestureRecognizer:pan];

    [host addSubview:button];
    [host bringSubviewToFront:button];
    self.button = button;
    self.hostWindow = host;
    [self updateButton];
    ECWriteStatus(@"menu-installed");
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

@end

__attribute__((constructor))
static void EmberEightBPOfflineLinesInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        BOOL expectedBundle = [bundleIdentifier isEqualToString:ECBundleIdentifier];
        BOOL expectedRuntime = NSClassFromString(@"GameManager") && NSClassFromString(@"UserInfo");
        // LiveContainer can briefly expose the host bundle while a guest is
        // being brought up, so accept the exact 8 Ball runtime signature too.
        // The dylib still lives in an app-specific Ember tweak folder.
        if (!expectedBundle && !expectedRuntime) {
            ECWriteStatus(@"wrong-bundle");
            return;
        }
        NSInteger saved = [NSUserDefaults.standardUserDefaults integerForKey:ECMultiplierKey];
        gECMultiplier = (saved == 1 || saved == 2 || saved == 4 || saved == 8) ? saved : 4;
        ECInstallHooks();

        EmberEightBPOfflineLinesController *controller = [EmberEightBPOfflineLinesController sharedController];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [controller start]; }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [controller stop]; }];
        [controller start];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [controller start]; });
    });
}
