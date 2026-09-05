// EightBPOfflineLines.m — native guideline extension for local 8 Ball Pool.
// Active in Practice, Play Offline, and Pass and Play / hotseat. Network matches stay locked.

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
static NSInteger gECMultiplier = 8;
static BOOL gECHooksInstalled = NO;
static int gECObservedLowAimRatio = 0;
static int gECObservedHighAimRatio = 0;

static void (*ECOriginalGameManagerOnEnter)(id, SEL) = NULL;
static void (*ECOriginalGameManagerOnExit)(id, SEL) = NULL;
static void (*ECOriginalStartHotSeatGame)(id, SEL) = NULL;
static int (*ECOriginalLowAimRatio)(id, SEL) = NULL;
static int (*ECOriginalHighAimRatio)(id, SEL) = NULL;
static int (*ECOriginalGuidelineRange)(id, SEL) = NULL;
static BOOL (*ECOriginalShowCueBallTrajectory)(id, SEL) = NULL;
static BOOL (*ECOriginalWideGuideline)(id, SEL) = NULL;
static BOOL (*ECOriginalHideGuidelinesMode)(id, SEL) = NULL;
static BOOL (*ECOriginalNoGuidelinesOffline)(id, SEL) = NULL;

static BOOL ECInvokeBool(id object, NSString *selectorName, BOOL fallback) {
    if (!object) return fallback;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return fallback;
    BOOL (*implementation)(id, SEL) = (void *)[object methodForSelector:selector];
    return implementation ? implementation(object, selector) : fallback;
}

static id ECInvokeId(id object, NSString *selectorName) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static void ECLogLine(NSString *line) {
    static NSURL *logURL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!docs) docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        [[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
        logURL = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:@"EmberEightBallLines.log"]];
        [@"" writeToURL:logURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
    if (!logURL) return;
    NSString *row = [NSString stringWithFormat:@"%.3f %@\n", [NSDate.date timeIntervalSince1970], line];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
    [handle seekToEndOfFile];
    [handle writeData:[row dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

static id ECFindGameManager(void) {
    if (gECGameManager) return gECGameManager;
    Class cls = NSClassFromString(@"GameManager");
    if (!cls) return nil;
    for (NSString *name in @[@"sharedManager", @"sharedInstance", @"shared", @"instance", @"getInstance", @"current"]) {
        id found = ECInvokeId(cls, name);
        if (found) {
            gECGameManager = found;
            return found;
        }
    }
    return nil;
}

// Network matches stay locked. Pass and Play is isOnLocalGame / hotseat, not
// isOnOfflineGame, which is why the first build never extended the line.
static BOOL ECIsLocalMatch(void) {
    id manager = ECFindGameManager();
    if (ECInvokeBool(manager, @"isOnNetworkedGame", NO)) return NO;
    if (!manager) {
        // Aim getters only run during a shot. If we cannot read GameManager yet,
        // allow the extension so Pass and Play is not stuck waiting on onEnter.
        return YES;
    }
    if (ECInvokeBool(manager, @"isOnOfflineGame", NO)) return YES;
    if (ECInvokeBool(manager, @"isOnPracticeGame", NO)) return YES;
    if (ECInvokeBool(manager, @"isOnLocalGame", NO)) return YES;
    if (ECInvokeBool(manager, @"isOnOfflineMode", NO)) return YES;
    if (ECInvokeBool(manager, @"isOnHotSeatGame", NO)) return YES;
    if (ECInvokeBool(manager, @"isHotSeat", NO)) return YES;
    if (ECInvokeBool(manager, @"hotSeat", NO)) return YES;
    return YES;
}

static BOOL ECExtensionIsActive(void) {
    return gECMultiplier > 1 && ECIsLocalMatch();
}

static void ECRefreshNativeGuide(void) {
    id manager = ECFindGameManager();
    if (!manager || !ECIsLocalMatch()) return;
    for (NSString *name in @[@"updateCueStatsAndVisualGuide", @"setShowCueBallTrajectory"]) {
        SEL selector = NSSelectorFromString(name);
        if ([manager respondsToSelector:selector]) {
            ((void (*)(id, SEL))objc_msgSend)(manager, selector);
        }
    }
}

static void ECWriteStatus(NSString *state) {
    id manager = ECFindGameManager();
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) return;
    NSDictionary *status = @{
        @"state": state ?: @"unknown",
        @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
        @"hooksInstalled": @(gECHooksInstalled),
        @"localMatch": @(ECIsLocalMatch()),
        @"networked": @(ECInvokeBool(manager, @"isOnNetworkedGame", NO)),
        @"offlineGame": @(ECInvokeBool(manager, @"isOnOfflineGame", NO)),
        @"practiceGame": @(ECInvokeBool(manager, @"isOnPracticeGame", NO)),
        @"localGame": @(ECInvokeBool(manager, @"isOnLocalGame", NO)),
        @"offlineMode": @(ECInvokeBool(manager, @"isOnOfflineMode", NO)),
        @"hasGameManager": @(manager != nil),
        @"requestedMultiplier": @(gECMultiplier),
        @"effectiveMultiplier": @(ECExtensionIsActive() ? gECMultiplier : 1),
        @"observedLowAimRatio": @(gECObservedLowAimRatio),
        @"observedHighAimRatio": @(gECObservedHighAimRatio),
        @"updatedAt": @([NSDate.date timeIntervalSince1970])
    };
    [status writeToFile:[docs stringByAppendingPathComponent:@"EightBPOfflineLinesStatus.plist"] atomically:YES];
    ECLogLine([NSString stringWithFormat:@"%@ hooks=%d local=%d net=%d off=%d prac=%d loc=%d gm=%d low=%d high=%d x%ld",
               state, gECHooksInstalled, ECIsLocalMatch(),
               ECInvokeBool(manager, @"isOnNetworkedGame", NO),
               ECInvokeBool(manager, @"isOnOfflineGame", NO),
               ECInvokeBool(manager, @"isOnPracticeGame", NO),
               ECInvokeBool(manager, @"isOnLocalGame", NO),
               manager != nil, gECObservedLowAimRatio, gECObservedHighAimRatio, (long)gECMultiplier]);
}

static void ECCaptureGameManager(id object) {
    if (object) gECGameManager = object;
}

static void ECGameManagerOnEnter(id self, SEL selector) {
    ECCaptureGameManager(self);
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

static void ECStartHotSeatGame(id self, SEL selector) {
    ECCaptureGameManager(self);
    if (ECOriginalStartHotSeatGame) ECOriginalStartHotSeatGame(self, selector);
    dispatch_async(dispatch_get_main_queue(), ^{
        ECRefreshNativeGuide();
        ECWriteStatus(@"hotseat-started");
    });
}

static int ECScaleAim(int value) {
    if (!ECExtensionIsActive() || value <= 0) return value;
    long long extended = (long long)value * (long long)gECMultiplier;
    if (extended < 32) extended = 32;
    return (int)MIN(extended, INT32_MAX);
}

static int ECLowAimRatio(id self, SEL selector) {
    int value = ECOriginalLowAimRatio ? ECOriginalLowAimRatio(self, selector) : 0;
    gECObservedLowAimRatio = value;
    return ECScaleAim(value);
}

static int ECHighAimRatio(id self, SEL selector) {
    int value = ECOriginalHighAimRatio ? ECOriginalHighAimRatio(self, selector) : 0;
    gECObservedHighAimRatio = value;
    return ECScaleAim(value);
}

static int ECGuidelineRange(id self, SEL selector) {
    int value = ECOriginalGuidelineRange ? ECOriginalGuidelineRange(self, selector) : 0;
    return ECScaleAim(value);
}

static BOOL ECShowCueBallTrajectory(id self, SEL selector) {
    BOOL original = ECOriginalShowCueBallTrajectory ? ECOriginalShowCueBallTrajectory(self, selector) : NO;
    return ECExtensionIsActive() ? YES : original;
}

static BOOL ECWideGuideline(id self, SEL selector) {
    BOOL original = ECOriginalWideGuideline ? ECOriginalWideGuideline(self, selector) : NO;
    return ECExtensionIsActive() ? YES : original;
}

static BOOL ECHideGuidelinesMode(id self, SEL selector) {
    if (ECExtensionIsActive()) return NO;
    return ECOriginalHideGuidelinesMode ? ECOriginalHideGuidelinesMode(self, selector) : NO;
}

static BOOL ECNoGuidelinesOffline(id self, SEL selector) {
    if (ECExtensionIsActive()) return NO;
    return ECOriginalNoGuidelinesOffline ? ECOriginalNoGuidelinesOffline(self, selector) : NO;
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
        ECHookVoidMethod(gameManager, NSSelectorFromString(@"startHotSeatGame"),
                         (IMP)ECStartHotSeatGame, (IMP *)&ECOriginalStartHotSeatGame);
        BOOL lowOK = ECHookIntGetter(userInfo, NSSelectorFromString(@"lowAimRatio"),
                                     (IMP)ECLowAimRatio, (IMP *)&ECOriginalLowAimRatio);
        BOOL highOK = ECHookIntGetter(userInfo, NSSelectorFromString(@"highAimRatio"),
                                      (IMP)ECHighAimRatio, (IMP *)&ECOriginalHighAimRatio);
        ECHookIntGetter(userInfo, NSSelectorFromString(@"guidelineRange"),
                        (IMP)ECGuidelineRange, (IMP *)&ECOriginalGuidelineRange);

        ECHookBoolGetter(settings, NSSelectorFromString(@"showCueBallTrajectory"),
                         (IMP)ECShowCueBallTrajectory, (IMP *)&ECOriginalShowCueBallTrajectory);
        ECHookBoolGetter(settings, NSSelectorFromString(@"wideGuideline"),
                         (IMP)ECWideGuideline, (IMP *)&ECOriginalWideGuideline);
        if (!ECHookBoolGetter(settings, NSSelectorFromString(@"hideGuidelinesMode"),
                              (IMP)ECHideGuidelinesMode, (IMP *)&ECOriginalHideGuidelinesMode)) {
            ECHookBoolGetter(gameManager, NSSelectorFromString(@"hideGuidelinesMode"),
                             (IMP)ECHideGuidelinesMode, (IMP *)&ECOriginalHideGuidelinesMode);
        }
        if (!ECHookBoolGetter(settings, NSSelectorFromString(@"noGuidelinesOffline"),
                              (IMP)ECNoGuidelinesOffline, (IMP *)&ECOriginalNoGuidelinesOffline)) {
            ECHookBoolGetter(gameManager, NSSelectorFromString(@"noGuidelinesOffline"),
                             (IMP)ECNoGuidelinesOffline, (IMP *)&ECOriginalNoGuidelinesOffline);
        }

        gECHooksInstalled = lowOK && highOK;
        ECLogLine([NSString stringWithFormat:@"hook enter=%d exit=%d low=%d high=%d gm=%@ user=%@ settings=%@",
                   enterOK, exitOK, lowOK, highOK, gameManager, userInfo, settings]);
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
            if (window.hidden || window.windowLevel > UIWindowLevelNormal) continue;
            if (!best || window.isKeyWindow) best = window;
        }
    }
    if (best) return best;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.hidden || window.windowLevel > UIWindowLevelNormal) continue;
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Network match"
        message:@"Extended lines stay locked during online matches. Use Pass and Play, Practice, or Play Offline."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)tapped {
    ECFindGameManager();
    if (!ECIsLocalMatch()) {
        [self showOfflineLockedMessage];
        return;
    }
    UIViewController *presenter = [self topViewController];
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Extended lines"
        message:@"Longer native aim line for Pass and Play / practice. Off in online matches."
        preferredStyle:UIAlertControllerStyleActionSheet];
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
    BOOL local = ECIsLocalMatch();
    NSString *title;
    UIColor *color;
    if (!local) {
        title = @"LINES 🔒";
        color = [UIColor colorWithWhite:0.18 alpha:0.88];
    } else if (gECMultiplier <= 1) {
        title = @"LINES Off";
        color = [UIColor colorWithRed:0.55 green:0.25 blue:0.08 alpha:0.9];
    } else {
        title = [NSString stringWithFormat:@"LINES %ldx", (long)gECMultiplier];
        color = [UIColor colorWithRed:0.08 green:0.42 blue:0.25 alpha:0.92];
    }
    [button setTitle:title forState:UIControlStateNormal];
    button.backgroundColor = color;
}

- (void)install {
    ECFindGameManager();
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
    button.bounds = CGRectMake(0, 0, 104, 40);
    CGFloat savedX = [NSUserDefaults.standardUserDefaults doubleForKey:ECButtonXKey];
    CGFloat savedY = [NSUserDefaults.standardUserDefaults doubleForKey:ECButtonYKey];
    CGFloat defaultX = 62;
    CGFloat defaultY = CGRectGetHeight(host.bounds) - MAX(36, host.safeAreaInsets.bottom + 28);
    button.center = CGPointMake(savedX > 0 ? savedX : defaultX, savedY > 0 ? savedY : defaultY);
    button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
    button.layer.cornerRadius = 12;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.35;
    button.layer.shadowRadius = 4;
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold];
    button.accessibilityLabel = @"Extended aim lines";
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

static void EmberEightBPOfflineLinesBoot(void) {
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
    BOOL expectedBundle = [bundleIdentifier containsString:@"8ball"] || [bundleIdentifier isEqualToString:ECBundleIdentifier];
    BOOL expectedRuntime = NSClassFromString(@"GameManager") && NSClassFromString(@"UserInfo");
    ECLogLine([NSString stringWithFormat:@"boot bundle=%@ gm=%@ user=%@",
               bundleIdentifier, NSClassFromString(@"GameManager"), NSClassFromString(@"UserInfo")]);
    if (!expectedBundle && !expectedRuntime) {
        ECWriteStatus(@"wrong-bundle");
        return;
    }
    NSInteger saved = [NSUserDefaults.standardUserDefaults integerForKey:ECMultiplierKey];
    gECMultiplier = (saved == 1 || saved == 2 || saved == 4 || saved == 8) ? saved : 8;
    ECInstallHooks();
    EmberEightBPOfflineLinesController *controller = [EmberEightBPOfflineLinesController sharedController];
    [controller start];
}

__attribute__((constructor))
static void EmberEightBPOfflineLinesInit(void) {
    ECLogLine(@"constructor");
    dispatch_async(dispatch_get_main_queue(), ^{
        EmberEightBPOfflineLinesBoot();
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                EmberEightBPOfflineLinesBoot();
            }];
        for (NSNumber *delay in @[@0.8, @2.0, @5.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ EmberEightBPOfflineLinesBoot(); });
        }
    });
}
