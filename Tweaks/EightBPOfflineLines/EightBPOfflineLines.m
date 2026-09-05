// EightBPOfflineLines.m — native guideline extension for local 8 Ball Pool.
// Active in Practice, Play Offline, and Pass and Play / hotseat. Network matches stay locked.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

#define EC_LINES_BUTTON_TAG 0x8B901
#define EC_LINE_OVERLAY_TAG 0x8B902

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
static void (*ECOriginalUpdateVisualGuide)(id, SEL) = NULL;
static int (*ECOriginalLowAimRatio)(id, SEL) = NULL;
static int (*ECOriginalHighAimRatio)(id, SEL) = NULL;
static int (*ECOriginalGuidelineRange)(id, SEL) = NULL;
static BOOL (*ECOriginalShowCueBallTrajectory)(id, SEL) = NULL;
static BOOL (*ECOriginalWideGuideline)(id, SEL) = NULL;
static BOOL (*ECOriginalHideGuidelinesMode)(id, SEL) = NULL;
static BOOL (*ECOriginalNoGuidelinesOffline)(id, SEL) = NULL;
static BOOL (*ECOriginalFixedGuidelines)(id, SEL) = NULL;

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

static BOOL ECExtensionIsActive(void);

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

static id ECFindUserInfo(void) {
    Class cls = NSClassFromString(@"UserInfo");
    if (cls) {
        for (NSString *name in @[@"sharedUserInfo", @"sharedInstance", @"shared", @"instance", @"currentUser", @"getInstance"]) {
            id found = ECInvokeId(cls, name);
            if (found) return found;
        }
    }
    id manager = ECFindGameManager();
    for (NSString *name in @[@"userInfo", @"getUserInfo", @"currentUser", @"playerInfo"]) {
        id found = ECInvokeId(manager, name);
        if (found) return found;
    }
    return nil;
}

static int ECTargetAimRatio(void) {
    if (gECMultiplier <= 1) return 0;
    if (gECMultiplier >= 8) return 120;
    if (gECMultiplier >= 4) return 50;
    return 20;
}

static BOOL ECSetIntIvar(id object, const char *name, int value) {
    if (!object) return NO;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return NO;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || (type[0] != 'i' && type[0] != 'I' && type[0] != 'q' && type[0] != 'Q')) return NO;
    if (type[0] == 'q' || type[0] == 'Q') {
        *(long long *)((uintptr_t)object + ivar_getOffset(ivar)) = value;
    } else {
        *(int *)((uintptr_t)object + ivar_getOffset(ivar)) = value;
    }
    return YES;
}

static void ECInvokeIntSetter(id object, NSString *selectorName, int value) {
    if (!object) return;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL, int))objc_msgSend)(object, selector, value);
}

static void ECDumpAimIvars(id object, NSString *label) {
    if (!object) {
        ECLogLine([NSString stringWithFormat:@"%@ missing", label]);
        return;
    }
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([object class], &count);
    NSMutableArray *parts = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        const char *name = ivar_getName(ivars[i]);
        if (!name) continue;
        NSString *nsName = @(name);
        if (!([nsName.lowercaseString containsString:@"aim"] ||
              [nsName.lowercaseString containsString:@"guide"] ||
              [nsName.lowercaseString containsString:@"visual"])) continue;
        const char *type = ivar_getTypeEncoding(ivars[i]) ?: "?";
        uintptr_t addr = (uintptr_t)object + ivar_getOffset(ivars[i]);
        if (type[0] == 'i' || type[0] == 'I') {
            [parts addObject:[NSString stringWithFormat:@"%s=%d", name, *(int *)addr]];
        } else if (type[0] == 'B' || type[0] == 'c') {
            [parts addObject:[NSString stringWithFormat:@"%s=%d", name, (int)*(char *)addr]];
        } else {
            [parts addObject:[NSString stringWithFormat:@"%s(%s)", name, type]];
        }
    }
    free(ivars);
    ECLogLine([NSString stringWithFormat:@"%@ %@ %@", label, [object class], [parts componentsJoinedByString:@" "]]);
}

static void ECApplyAimValues(void) {
    if (!ECExtensionIsActive()) return;
    int target = ECTargetAimRatio();
    id user = ECFindUserInfo();
    id manager = ECFindGameManager();
    static BOOL dumped = NO;
    if (!dumped) {
        dumped = YES;
        ECDumpAimIvars(user, @"userInfo");
        ECDumpAimIvars(manager, @"gameManager");
    }
    ECInvokeIntSetter(user, @"setLowAimRatio:", target);
    ECInvokeIntSetter(user, @"setHighAimRatio:", target);
    ECInvokeIntSetter(user, @"setGuidelineRange:", target);
    BOOL wroteLow = ECSetIntIvar(user, "mLowAimRatio", target) || ECSetIntIvar(user, "_lowAimRatio", target);
    BOOL wroteHigh = ECSetIntIvar(user, "mHighAimRatio", target) || ECSetIntIvar(user, "_highAimRatio", target);
    ECSetIntIvar(manager, "mLowAimRatio", target);
    ECSetIntIvar(manager, "mHighAimRatio", target);
    static int lastLogged = -1;
    if (lastLogged != target || !user) {
        lastLogged = target;
        ECLogLine([NSString stringWithFormat:@"apply target=%d user=%@ wroteLow=%d wroteHigh=%d",
                   target, user, wroteLow, wroteHigh]);
    }
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
    ECApplyAimValues();
    id manager = ECFindGameManager();
    if (!manager || !ECIsLocalMatch()) return;
    SEL selector = NSSelectorFromString(@"updateCueStatsAndVisualGuide");
    if ([manager respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(manager, selector);
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
    if (!ECExtensionIsActive()) return value;
    int base = value > 0 ? value : 4;
    long long extended = (long long)base * (long long)gECMultiplier;
    int target = ECTargetAimRatio();
    if (extended < target) extended = target;
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

static BOOL ECFixedGuidelines(id self, SEL selector) {
    if (ECExtensionIsActive()) return NO;
    return ECOriginalFixedGuidelines ? ECOriginalFixedGuidelines(self, selector) : NO;
}

static void ECUpdateVisualGuide(id self, SEL selector) {
    ECCaptureGameManager(self);
    ECApplyAimValues();
    if (ECOriginalUpdateVisualGuide) ECOriginalUpdateVisualGuide(self, selector);
    if (ECExtensionIsActive()) ECApplyAimValues();
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
        ECHookVoidMethod(gameManager, NSSelectorFromString(@"updateCueStatsAndVisualGuide"),
                         (IMP)ECUpdateVisualGuide, (IMP *)&ECOriginalUpdateVisualGuide);
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
        for (Class cls in @[settings, gameManager, userInfo]) {
            if (ECHookBoolGetter(cls, NSSelectorFromString(@"isFixedGameplayGuidelinesFeatureActive"),
                                 (IMP)ECFixedGuidelines, (IMP *)&ECOriginalFixedGuidelines)) break;
        }

        gECHooksInstalled = lowOK && highOK;
        ECLogLine([NSString stringWithFormat:@"hook enter=%d exit=%d low=%d high=%d gm=%@ user=%@ settings=%@",
                   enterOK, exitOK, lowOK, highOK, gameManager, userInfo, settings]);
        ECWriteStatus(gECHooksInstalled ? @"hooks-installed" : @"incompatible-runtime");
    });
}

static id ECFindResponder(id root, NSString *selectorName, int depth) {
    if (!root || depth > 3) return nil;
    @try {
        if ([root respondsToSelector:NSSelectorFromString(selectorName)]) return root;
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList([root class], &count);
        for (unsigned int i = 0; i < count && ivars; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;
            id child = object_getIvar(root, ivars[i]);
            if (!child || child == root) continue;
            id found = ECFindResponder(child, selectorName, depth + 1);
            if (found) {
                free(ivars);
                return found;
            }
        }
        if (ivars) free(ivars);
    } @catch (NSException *exception) {
        ECLogLine([NSString stringWithFormat:@"find %@ failed %@", selectorName, exception]);
    }
    return nil;
}

static float ECReadFloat(id object, NSString *selectorName, float fallback);

static float ECReadMCNumber(id number) {
    if (!number) return NAN;
    float value = ECReadFloat(number, @"value", NAN);
    if (!isnan(value)) return value;
    value = ECReadFloat(number, @"doubleValue", NAN);
    if (!isnan(value)) return value;
    Ivar ivar = class_getInstanceVariable([number class], "mValue");
    if (!ivar) ivar = class_getInstanceVariable([number class], "_value");
    if (!ivar) return NAN;
    const char *type = ivar_getTypeEncoding(ivar) ?: "";
    uintptr_t addr = (uintptr_t)number + ivar_getOffset(ivar);
    if (type[0] == 'd') return (float)*(double *)addr;
    if (type[0] == 'f') return *(float *)addr;
    return NAN;
}

static float ECReadFloat(id object, NSString *selectorName, float fallback) {
    if (!object) return fallback;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return fallback;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) return fallback;
    const char *type = signature.methodReturnType ?: "";
    if (type[0] == 'f') return ((float (*)(id, SEL))objc_msgSend)(object, selector);
    if (type[0] == 'd') return (float)((double (*)(id, SEL))objc_msgSend)(object, selector);
    if (type[0] == '@') {
        id boxed = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        float boxedValue = ECReadMCNumber(boxed);
        return isnan(boxedValue) ? fallback : boxedValue;
    }
    if (type[0] == '{') {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.selector = selector;
        invocation.target = object;
        [invocation invoke];
        double value = 0;
        [invocation getReturnValue:&value];
        return (float)value;
    }
    return fallback;
}

static float ECReadIvarAngle(id object) {
    if (!object) return NAN;
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([object class], &count);
    float found = NAN;
    for (unsigned int i = 0; i < count && ivars; i++) {
        const char *name = ivar_getName(ivars[i]) ?: "";
        NSString *nsName = @(name);
        if (!([nsName.lowercaseString containsString:@"aimangle"] ||
              [nsName isEqualToString:@"_aimAngleBackup"])) continue;
        const char *type = ivar_getTypeEncoding(ivars[i]) ?: "";
        uintptr_t addr = (uintptr_t)object + ivar_getOffset(ivars[i]);
        if (type[0] == 'd') found = (float)*(double *)addr;
        else if (type[0] == 'f') found = *(float *)addr;
        else if (strstr(type, "MCNumber") && type[0] == '{') found = (float)*(double *)addr;
        else if (type[0] == '@') found = ECReadMCNumber(object_getIvar(object, ivars[i]));
        if (!isnan(found)) break;
    }
    if (ivars) free(ivars);
    return found;
}

static CGPoint ECReadPoint(id object, NSString *selectorName) {
    if (!object) return CGPointZero;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return CGPointZero;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature) return CGPointZero;
    const char *type = signature.methodReturnType;
    if (type && type[0] == '{') {
        return ((CGPoint (*)(id, SEL))objc_msgSend)(object, selector);
    }
    return CGPointZero;
}

static id ECIvarObject(id object, const char *name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return nil;
    return object_getIvar(object, ivar);
}

static UIView *ECRenderView(UIWindow *window) {
    __block UIView *best = nil;
    __block CGFloat bestArea = 0;
    void (^walk)(UIView *);
    __block void (^walkBlock)(UIView *) = ^(UIView *view) {
        NSString *name = NSStringFromClass(view.class);
        CGFloat area = CGRectGetWidth(view.bounds) * CGRectGetHeight(view.bounds);
        if (area > bestArea && (CGRectGetWidth(view.bounds) > 200) &&
            ([name containsString:@"EAGL"] || [name containsString:@"Metal"] ||
             [name containsString:@"GLK"] || [name containsString:@"CCGL"] ||
             [name containsString:@"Render"] || [name containsString:@"Cocos"] ||
             [name containsString:@"Director"])) {
            best = view;
            bestArea = area;
        }
        for (UIView *child in view.subviews) walkBlock(child);
    };
    walk = walkBlock;
    if (window) walk(window);
    return best ?: window;
}

static CGPoint ECCueBallScreenPoint(id host, UIView *space) {
    id sprite = ECIvarObject(host, "mCueBallSprite");
    if (!sprite) sprite = ECInvokeId(host, @"getCueBall");
    CGPoint point = CGPointZero;
    if (sprite) {
        point = ECReadPoint(sprite, @"position");
        SEL convert = NSSelectorFromString(@"convertToWorldSpace:");
        if ([sprite respondsToSelector:convert]) {
            point = ((CGPoint (*)(id, SEL, CGPoint))objc_msgSend)(sprite, convert, CGPointZero);
        }
    }
    if (CGPointEqualToPoint(point, CGPointZero)) {
        point = ECReadPoint(host, @"getCueBallPositionTarget");
    }
    UIView *render = ECRenderView(space.window ?: (UIWindow *)space);
    CGRect bounds = render.bounds;
    CGPoint mapped = point;
    if (point.y > 1 && point.y < bounds.size.height * 3) {
        if (point.y <= bounds.size.height && point.x <= bounds.size.width * 1.5) {
            mapped = CGPointMake(point.x, bounds.size.height - point.y);
        }
    }
    return [render convertPoint:mapped toView:space];
}

static void ECBounceRay(CGPoint start, CGPoint direction, CGRect table, NSInteger bounces,
                        void (^emit)(CGPoint, CGPoint)) {
    CGFloat length = (CGRectGetWidth(table) + CGRectGetHeight(table)) * 2.0;
    CGPoint origin = start;
    CGPoint dir = direction;
    CGFloat mag = hypot(dir.x, dir.y);
    if (mag < 0.001) return;
    dir = CGPointMake(dir.x / mag, dir.y / mag);
    for (NSInteger i = 0; i <= bounces; i++) {
        CGFloat tHit = length;
        CGPoint normal = CGPointZero;
        CGFloat left = CGRectGetMinX(table), right = CGRectGetMaxX(table);
        CGFloat top = CGRectGetMinY(table), bottom = CGRectGetMaxY(table);
        if (dir.x > 0.0001) {
            CGFloat t = (right - origin.x) / dir.x;
            if (t > 0.001 && t < tHit) { tHit = t; normal = CGPointMake(-1, 0); }
        } else if (dir.x < -0.0001) {
            CGFloat t = (left - origin.x) / dir.x;
            if (t > 0.001 && t < tHit) { tHit = t; normal = CGPointMake(1, 0); }
        }
        if (dir.y > 0.0001) {
            CGFloat t = (bottom - origin.y) / dir.y;
            if (t > 0.001 && t < tHit) { tHit = t; normal = CGPointMake(0, -1); }
        } else if (dir.y < -0.0001) {
            CGFloat t = (top - origin.y) / dir.y;
            if (t > 0.001 && t < tHit) { tHit = t; normal = CGPointMake(0, 1); }
        }
        CGPoint dest = CGPointMake(origin.x + dir.x * tHit, origin.y + dir.y * tHit);
        emit(origin, dest);
        if (normal.x != 0) dir.x = -dir.x;
        if (normal.y != 0) dir.y = -dir.y;
        origin = dest;
    }
}

@interface EmberEightBPLineOverlay : UIView
@property (nonatomic, strong) CAShapeLayer *stroke;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, assign) BOOL aiming;
@property (nonatomic, assign) NSTimeInterval lastAimLog;
+ (instancetype)sharedOverlay;
- (void)attachToWindow:(UIWindow *)window;
@end

@implementation EmberEightBPLineOverlay

+ (instancetype)sharedOverlay {
    static EmberEightBPLineOverlay *overlay;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        overlay = [[EmberEightBPLineOverlay alloc] initWithFrame:CGRectZero];
        overlay.userInteractionEnabled = NO;
        overlay.opaque = NO;
        overlay.backgroundColor = UIColor.clearColor;
        overlay.tag = EC_LINE_OVERLAY_TAG;
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        CAShapeLayer *stroke = [CAShapeLayer layer];
        stroke.fillColor = UIColor.clearColor.CGColor;
        stroke.strokeColor = [UIColor colorWithWhite:1 alpha:0.92].CGColor;
        stroke.lineWidth = 2.2;
        stroke.lineCap = kCALineCapRound;
        stroke.lineJoin = kCALineJoinRound;
        stroke.shadowColor = [UIColor colorWithRed:0.55 green:0.85 blue:1 alpha:1].CGColor;
        stroke.shadowRadius = 4;
        stroke.shadowOpacity = 0.8;
        [overlay.layer addSublayer:stroke];
        overlay.stroke = stroke;
    });
    return overlay;
}

- (void)attachToWindow:(UIWindow *)window {
    if (!window) return;
    self.frame = window.bounds;
    if (self.superview != window) {
        [self removeFromSuperview];
        [window addSubview:self];
    }
    [window bringSubviewToFront:self];
    if (self.link) return;
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(aimingPan:)];
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;
    [window addGestureRecognizer:pan];
}

- (void)aimingPan:(UIPanGestureRecognizer *)gesture {
    self.aiming = gesture.state == UIGestureRecognizerStateBegan ||
                  gesture.state == UIGestureRecognizerStateChanged;
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled) {
        self.aiming = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gesture.state != UIGestureRecognizerStateChanged) self.aiming = NO;
        });
    }
}

- (void)tick {
    if (!ECExtensionIsActive() || gECMultiplier <= 1) {
        self.hidden = YES;
        self.stroke.path = nil;
        return;
    }
    id manager = ECFindGameManager();
    id host = ECFindResponder(manager, @"aimAngle", 0);
    if (!host) host = ECFindResponder(manager, @"getAimAngleTarget", 0);
    id cueHost = ECFindResponder(manager, @"getCueBallPositionTarget", 0);
    if (!cueHost) cueHost = ECFindResponder(manager, @"getCueBall", 0);
    if (!cueHost) cueHost = ECFindResponder(manager, @"mCueBallSprite", 0);
    if (!host) host = cueHost ?: manager;
    if (!cueHost) cueHost = host;
    float angle = ECReadFloat(host, @"aimAngle", NAN);
    if (isnan(angle)) angle = ECReadFloat(host, @"getAimAngleTarget", NAN);
    if (isnan(angle)) angle = ECReadIvarAngle(host);
    CGPoint cue = ECCueBallScreenPoint(cueHost, self);
    if (cue.x == 0 && cue.y == 0) cue = ECCueBallScreenPoint(host, self);
    id visualCue = host;
    if (![NSStringFromClass([visualCue class]) isEqualToString:@"VisualCue"]) {
        visualCue = ECInvokeId(host, @"visualCue") ?: ECIvarObject(host, "mVisualCue") ?: ECIvarObject(manager, "mVisualCue");
    }
    static BOOL dumped = NO;
    if (!dumped && (host || visualCue)) {
        dumped = YES;
        ECDumpAimIvars(host, @"aimHost");
        ECDumpAimIvars(visualCue, @"visualCue");
        ECDumpAimIvars(cueHost, @"cueHost");
        Ivar guideIvar = visualCue ? class_getInstanceVariable([visualCue class], "mVisualGuide") : NULL;
        if (guideIvar) {
            void *guide = *(void **)((uintptr_t)visualCue + ivar_getOffset(guideIvar));
            if (guide) {
                float *words = (float *)((uintptr_t)guide + 16);
                NSMutableString *dump = [NSMutableString stringWithString:@"guide+16"];
                for (int i = 0; i < 20; i++) [dump appendFormat:@" %d=%.3f", i, words[i]];
                ECLogLine(dump);
            }
        }
        ECLogLine([NSString stringWithFormat:@"overlay host=%@ cueHost=%@ angle=%.3f cue=%.1f,%.1f ivarAngle=%.3f",
                   [host class], [cueHost class], angle, cue.x, cue.y, ECReadIvarAngle(host)]);
        ECInvokeIntSetter(visualCue, @"setMaxLineLength:", 9999);
        ECSetIntIvar(visualCue, "_maxLineLength", 9999);
        ECSetIntIvar(visualCue, "mMaxLineLength", 9999);
    }
    if (isnan(angle) || (cue.x == 0 && cue.y == 0)) {
        self.hidden = YES;
        self.stroke.path = nil;
        return;
    }
    self.hidden = NO;
    CGFloat radians = (fabs(angle) > 8.0) ? (angle * (float)M_PI / 180.0f) : angle;
    CGPoint dir = CGPointMake(cos(radians), -sin(radians));
    CGRect table = CGRectInset(self.bounds, 18, 28);
    NSInteger bounces = gECMultiplier >= 8 ? 3 : (gECMultiplier >= 4 ? 2 : 1);
    UIBezierPath *path = [UIBezierPath bezierPath];
    __block NSInteger parts = 0;
    ECBounceRay(cue, dir, table, bounces, ^(CGPoint from, CGPoint to) {
        if (parts == 0) [path moveToPoint:from];
        [path addLineToPoint:to];
        parts++;
    });
    self.stroke.path = path.CGPath;
    NSTimeInterval now = CACurrentMediaTime();
    if (now - self.lastAimLog > 1.5) {
        self.lastAimLog = now;
        ECLogLine([NSString stringWithFormat:@"draw angle=%.3f cue=%.1f,%.1f parts=%ld x%ld",
                   angle, cue.x, cue.y, (long)parts, (long)gECMultiplier]);
    }
}

@end

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
    [EmberEightBPLineOverlay.sharedOverlay attachToWindow:[self guestWindow]];
    [self.keepAliveTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        ECApplyAimValues();
        [weakSelf install];
        [EmberEightBPLineOverlay.sharedOverlay attachToWindow:[weakSelf guestWindow]];
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
