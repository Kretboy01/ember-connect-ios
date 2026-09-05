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
static BOOL gECInMatch = NO;
static BOOL gECOverlayAllowed = NO;
static NSInteger gECMultiplier = 8;
static BOOL gECHooksInstalled = NO;

@class EmberEightBPLineOverlay;
@class EmberEightBPOfflineLinesController;
static void ECScheduleOverlay(void);
static int gECObservedLowAimRatio = 0;
static int gECObservedHighAimRatio = 0;

static void (*ECOriginalGameManagerOnEnter)(id, SEL) = NULL;
static void (*ECOriginalGameManagerOnExit)(id, SEL) = NULL;
static void (*ECOriginalStartHotSeatGame)(id, SEL) = NULL;
static void (*ECOriginalUpdateVisualGuide)(id, SEL) = NULL;
static int (*ECOriginalLowAimRatio)(id, SEL) = NULL;
static int (*ECOriginalHighAimRatio)(id, SEL) = NULL;
static int (*ECOriginalGuidelineRange)(id, SEL) = NULL;
static void (*ECOriginalSetLowAimRatio)(id, SEL, int) = NULL;
static void (*ECOriginalSetHighAimRatio)(id, SEL, int) = NULL;
static BOOL (*ECOriginalShowCueBallTrajectory)(id, SEL) = NULL;
static BOOL (*ECOriginalWideGuideline)(id, SEL) = NULL;
static BOOL (*ECOriginalHideGuidelinesMode)(id, SEL) = NULL;
static void (*ECOriginalSetHideGuidelinesMode)(id, SEL, BOOL) = NULL;
static BOOL (*ECOriginalNoGuidelinesOffline)(id, SEL) = NULL;
static BOOL (*ECOriginalFixedGuidelines)(id, SEL) = NULL;
static void (*ECOriginalApplyCueStatsForShot)(id, SEL, int, int, int) = NULL;

typedef struct {
    unsigned int force;
    unsigned int aim;
    unsigned int spin;
    unsigned int time;
} ECCueStats;

static ECCueStats (*ECOriginalGetCueStats)(id, SEL, int) = NULL;
static ECCueStats (*ECOriginalGetCueStatsWithBonus)(id, SEL, int) = NULL;

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

// Classic public iOS tweaks did not scale 8/14 by a multiplier.
// 2013 GNSPS: VisualGuide -calculateGuideLength:distanceModifier: → 1000
//   (that selector is gone in 56.29.2; VisualGuide is a C++ pointer now).
// 2017 iOSGods: UserInfo lowAimRatio=-900, highAimRatio=1300 (a SPAN),
//   plus VisualCue hideGuidelinesMode = NO.
// Writing the same positive value to both ivars collapses the range.
static void ECTargetAimSpan(int *lowOut, int *highOut) {
    if (gECMultiplier <= 1) {
        *lowOut = 0;
        *highOut = 0;
        return;
    }
    if (gECMultiplier >= 8) {
        *lowOut = -900;
        *highOut = 1300;
        return;
    }
    if (gECMultiplier >= 4) {
        *lowOut = -450;
        *highOut = 650;
        return;
    }
    *lowOut = -225;
    *highOut = 325;
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
    int low = 0, high = 0;
    ECTargetAimSpan(&low, &high);
    id user = ECFindUserInfo();
    id manager = ECFindGameManager();
    static BOOL dumped = NO;
    if (!dumped) {
        dumped = YES;
        ECDumpAimIvars(user, @"userInfo");
        ECDumpAimIvars(manager, @"gameManager");
    }
    ECInvokeIntSetter(user, @"setLowAimRatio:", low);
    ECInvokeIntSetter(user, @"setHighAimRatio:", high);
    BOOL wroteLow = ECSetIntIvar(user, "mLowAimRatio", low) || ECSetIntIvar(user, "_lowAimRatio", low);
    BOOL wroteHigh = ECSetIntIvar(user, "mHighAimRatio", high) || ECSetIntIvar(user, "_highAimRatio", high);
    ECSetIntIvar(manager, "mLowAimRatio", low);
    ECSetIntIvar(manager, "mHighAimRatio", high);
    static int lastLow = 1, lastHigh = 1;
    if (lastLow != low || lastHigh != high || !user) {
        lastLow = low;
        lastHigh = high;
        ECLogLine([NSString stringWithFormat:@"apply span low=%d high=%d user=%@ wroteLow=%d wroteHigh=%d",
                   low, high, user, wroteLow, wroteHigh]);
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
    gECInMatch = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        ECRefreshNativeGuide();
        ECWriteStatus(@"game-entered");
        ECScheduleOverlay();
    });
}

static void ECGameManagerOnExit(id self, SEL selector) {
    if (ECOriginalGameManagerOnExit) ECOriginalGameManagerOnExit(self, selector);
    if (gECGameManager == self) gECGameManager = nil;
    gECInMatch = NO;
    gECOverlayAllowed = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ ECWriteStatus(@"game-exited"); });
}

static void ECStartHotSeatGame(id self, SEL selector) {
    ECCaptureGameManager(self);
    if (ECOriginalStartHotSeatGame) ECOriginalStartHotSeatGame(self, selector);
    gECInMatch = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        ECRefreshNativeGuide();
        ECWriteStatus(@"hotseat-started");
        ECScheduleOverlay();
    });
}

static int ECLowAimRatio(id self, SEL selector) {
    int value = ECOriginalLowAimRatio ? ECOriginalLowAimRatio(self, selector) : 0;
    gECObservedLowAimRatio = value;
    if (!ECExtensionIsActive()) return value;
    int low = 0, high = 0;
    ECTargetAimSpan(&low, &high);
    return low;
}

static int ECHighAimRatio(id self, SEL selector) {
    int value = ECOriginalHighAimRatio ? ECOriginalHighAimRatio(self, selector) : 0;
    gECObservedHighAimRatio = value;
    if (!ECExtensionIsActive()) return value;
    int low = 0, high = 0;
    ECTargetAimSpan(&low, &high);
    return high;
}

static int ECGuidelineRange(id self, SEL selector) {
    int value = ECOriginalGuidelineRange ? ECOriginalGuidelineRange(self, selector) : 0;
    if (!ECExtensionIsActive()) return value;
    int low = 0, high = 0;
    ECTargetAimSpan(&low, &high);
    return high - low;
}

static void ECSetLowAimRatio(id self, SEL selector, int value) {
    int low = 0, high = 0;
    ECTargetAimSpan(&low, &high);
    int forced = ECExtensionIsActive() ? low : value;
    if (ECOriginalSetLowAimRatio) ECOriginalSetLowAimRatio(self, selector, forced);
}

static void ECSetHighAimRatio(id self, SEL selector, int value) {
    int low = 0, high = 0;
    ECTargetAimSpan(&low, &high);
    int forced = ECExtensionIsActive() ? high : value;
    if (ECOriginalSetHighAimRatio) ECOriginalSetHighAimRatio(self, selector, forced);
}

static void ECSetHideGuidelinesMode(id self, SEL selector, BOOL value) {
    BOOL forced = ECExtensionIsActive() ? NO : value;
    if (ECOriginalSetHideGuidelinesMode) ECOriginalSetHideGuidelinesMode(self, selector, forced);
}

// 56.29.2 builds guide length from CueStats.aim (IIII = force, aim, spin, time),
// applied through applyCueStatsForShot:aim:spin:. UserInfo low/high ratios are unused at draw.
static unsigned int ECTargetCueAim(void) {
    if (gECMultiplier >= 8) return 1000;
    if (gECMultiplier >= 4) return 200;
    if (gECMultiplier >= 2) return 80;
    return 0;
}

static ECCueStats ECBoostCueStats(ECCueStats stats, NSString *label, int cueId) {
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        ECLogLine([NSString stringWithFormat:@"%@ id=%d force=%u aim=%u spin=%u time=%u",
                   label, cueId, stats.force, stats.aim, stats.spin, stats.time]);
    }
    if (ECExtensionIsActive()) {
        unsigned int target = ECTargetCueAim();
        if (target > stats.aim) stats.aim = target;
    }
    return stats;
}

static ECCueStats ECGetCueStats(id self, SEL selector, int cueId) {
    ECCueStats stats = {0, 0, 0, 0};
    if (ECOriginalGetCueStats) stats = ECOriginalGetCueStats(self, selector, cueId);
    return ECBoostCueStats(stats, @"getCueStats", cueId);
}

static ECCueStats ECGetCueStatsWithBonus(id self, SEL selector, int cueId) {
    ECCueStats stats = {0, 0, 0, 0};
    if (ECOriginalGetCueStatsWithBonus) stats = ECOriginalGetCueStatsWithBonus(self, selector, cueId);
    return ECBoostCueStats(stats, @"getCueStatsWithBonus", cueId);
}

static void ECApplyCueStatsForShot(id self, SEL selector, int shot, int aim, int spin) {
    int forcedAim = aim;
    if (ECExtensionIsActive()) {
        unsigned int target = ECTargetCueAim();
        if ((int)target > forcedAim) forcedAim = (int)target;
        static BOOL logged = NO;
        if (!logged) {
            logged = YES;
            ECLogLine([NSString stringWithFormat:@"applyCueStatsForShot shot=%d aim=%d->%d spin=%d",
                       shot, aim, forcedAim, spin]);
        }
    }
    if (ECOriginalApplyCueStatsForShot) ECOriginalApplyCueStatsForShot(self, selector, shot, forcedAim, spin);
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

static BOOL ECHookIntSetter(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 3) return NO;
    *original = method_setImplementation(method, replacement);
    return *original != NULL;
}

static BOOL ECHookBoolSetter(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 3) return NO;
    *original = method_setImplementation(method, replacement);
    return *original != NULL;
}

static BOOL ECHookCueStatsGetter(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 3) return NO;
    const char *encoding = method_getTypeEncoding(method) ?: "";
    if (!strstr(encoding, "CueStats")) return NO;
    *original = method_setImplementation(method, replacement);
    return *original != NULL;
}

static BOOL ECHookApplyCueStats(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 5) return NO;
    *original = method_setImplementation(method, replacement);
    return *original != NULL;
}

static void ECDumpClassSelectors(Class cls, NSString *label) {
    if (!cls) {
        ECLogLine([NSString stringWithFormat:@"%@ missing", label]);
        return;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        NSString *lower = name.lowercaseString;
        if (!([lower containsString:@"guide"] || [lower containsString:@"aim"] ||
              [lower containsString:@"length"] || [lower containsString:@"cue"] ||
              [lower containsString:@"visual"])) continue;
        [names addObject:name];
    }
    free(methods);
    ECLogLine([NSString stringWithFormat:@"%@ %@ %@", label, cls, [names componentsJoinedByString:@" "]]);
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
        BOOL setLowOK = ECHookIntSetter(userInfo, NSSelectorFromString(@"setLowAimRatio:"),
                                        (IMP)ECSetLowAimRatio, (IMP *)&ECOriginalSetLowAimRatio);
        BOOL setHighOK = ECHookIntSetter(userInfo, NSSelectorFromString(@"setHighAimRatio:"),
                                         (IMP)ECSetHighAimRatio, (IMP *)&ECOriginalSetHighAimRatio);
        BOOL statsOK = ECHookCueStatsGetter(userInfo, NSSelectorFromString(@"getCueStats:"),
                                            (IMP)ECGetCueStats, (IMP *)&ECOriginalGetCueStats);
        BOOL bonusOK = ECHookCueStatsGetter(userInfo, NSSelectorFromString(@"getCueStatsWithBonus:"),
                                            (IMP)ECGetCueStatsWithBonus, (IMP *)&ECOriginalGetCueStatsWithBonus);
        BOOL applyOK = ECHookApplyCueStats(gameManager, NSSelectorFromString(@"applyCueStatsForShot:aim:spin:"),
                                           (IMP)ECApplyCueStatsForShot, (IMP *)&ECOriginalApplyCueStatsForShot);

        Class visualCue = NSClassFromString(@"VisualCue");
        ECDumpClassSelectors(visualCue, @"visualCue");
        ECDumpClassSelectors(NSClassFromString(@"VisualCueWide"), @"visualCueWide");
        ECDumpClassSelectors(userInfo, @"userInfoClass");
        ECDumpClassSelectors(gameManager, @"gameManagerClass");

        ECHookBoolGetter(settings, NSSelectorFromString(@"showCueBallTrajectory"),
                         (IMP)ECShowCueBallTrajectory, (IMP *)&ECOriginalShowCueBallTrajectory);
        ECHookBoolGetter(settings, NSSelectorFromString(@"wideGuideline"),
                         (IMP)ECWideGuideline, (IMP *)&ECOriginalWideGuideline);
        if (!ECHookBoolGetter(visualCue, NSSelectorFromString(@"hideGuidelinesMode"),
                              (IMP)ECHideGuidelinesMode, (IMP *)&ECOriginalHideGuidelinesMode) &&
            !ECHookBoolGetter(settings, NSSelectorFromString(@"hideGuidelinesMode"),
                              (IMP)ECHideGuidelinesMode, (IMP *)&ECOriginalHideGuidelinesMode)) {
            ECHookBoolGetter(gameManager, NSSelectorFromString(@"hideGuidelinesMode"),
                             (IMP)ECHideGuidelinesMode, (IMP *)&ECOriginalHideGuidelinesMode);
        }
        ECHookBoolSetter(visualCue, NSSelectorFromString(@"setHideGuidelinesMode:"),
                         (IMP)ECSetHideGuidelinesMode, (IMP *)&ECOriginalSetHideGuidelinesMode);
        if (!ECHookBoolGetter(settings, NSSelectorFromString(@"noGuidelinesOffline"),
                              (IMP)ECNoGuidelinesOffline, (IMP *)&ECOriginalNoGuidelinesOffline)) {
            ECHookBoolGetter(gameManager, NSSelectorFromString(@"noGuidelinesOffline"),
                             (IMP)ECNoGuidelinesOffline, (IMP *)&ECOriginalNoGuidelinesOffline);
        }
        for (Class cls in @[settings, gameManager, userInfo]) {
            if (ECHookBoolGetter(cls, NSSelectorFromString(@"isFixedGameplayGuidelinesFeatureActive"),
                                 (IMP)ECFixedGuidelines, (IMP *)&ECOriginalFixedGuidelines)) break;
        }

        gECHooksInstalled = lowOK && highOK && (statsOK || applyOK);
        ECLogLine([NSString stringWithFormat:@"hook enter=%d exit=%d low=%d high=%d setLow=%d setHigh=%d stats=%d bonus=%d apply=%d gm=%@ user=%@",
                   enterOK, exitOK, lowOK, highOK, setLowOK, setHighOK, statsOK, bonusOK, applyOK, gameManager, userInfo]);
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

typedef struct { double x, y; } ECDPoint;
typedef struct { double minX, minY, maxX, maxY; } ECDBox;
typedef struct {
    BOOL valid;
    BOOL windowSpace;
    CGPoint deviceA;
    ECDPoint tableA;
    double m00, m01, m10, m11;
} ECWorldMap;

static ECDPoint ECMakePoint(double x, double y) {
    return (ECDPoint){x, y};
}

static ECDPoint ECNorm(ECDPoint v) {
    double mag = hypot(v.x, v.y);
    if (mag < 1e-9) return ECMakePoint(0, 0);
    return ECMakePoint(v.x / mag, v.y / mag);
}

static BOOL ECPointValid(ECDPoint p) {
    return !isnan(p.x) && !isnan(p.y) && isfinite(p.x) && isfinite(p.y);
}

static ECDPoint ECReadDPoint(id object, NSString *name) {
    ECDPoint invalid = {NAN, NAN};
    if (!object) return invalid;
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return invalid;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature) return invalid;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = selector;
    invocation.target = object;
    [invocation invoke];
    ECDPoint point = invalid;
    [invocation getReturnValue:&point];
    return point;
}

static ECDBox ECReadTableBox(id table, ECDPoint cue) {
    ECDBox invalid = {NAN, NAN, NAN, NAN};
    SEL selector = NSSelectorFromString(@"tableBounds");
    if (!table || ![table respondsToSelector:selector]) return invalid;
    NSMethodSignature *signature = [table methodSignatureForSelector:selector];
    if (!signature) return invalid;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = selector;
    invocation.target = table;
    [invocation invoke];
    double raw[4] = {0, 0, 0, 0};
    [invocation getReturnValue:raw];
    ECDBox originSize = {raw[0], raw[1], raw[0] + raw[2], raw[1] + raw[3]};
    ECDBox minMax = {MIN(raw[0], raw[2]), MIN(raw[1], raw[3]), MAX(raw[0], raw[2]), MAX(raw[1], raw[3])};
    BOOL originLooksWide = (originSize.maxX - originSize.minX) > 1 && (originSize.maxY - originSize.minY) > 1;
    BOOL cueInOrigin = ECPointValid(cue) &&
        cue.x >= originSize.minX - 4 && cue.x <= originSize.maxX + 4 &&
        cue.y >= originSize.minY - 4 && cue.y <= originSize.maxY + 4;
    BOOL cueInMinMax = ECPointValid(cue) &&
        cue.x >= minMax.minX - 4 && cue.x <= minMax.maxX + 4 &&
        cue.y >= minMax.minY - 4 && cue.y <= minMax.maxY + 4;
    if (cueInOrigin || (originLooksWide && !cueInMinMax)) return originSize;
    if (cueInMinMax) return minMax;
    return originLooksWide ? originSize : minMax;
}

static id ECTableFromManager(id manager) {
    id table = ECInvokeId(manager, @"table");
    return table ?: ECInvokeId(manager, @"getTable");
}

static NSArray *ECBallsOnTable(id table, id cueBall) {
    NSMutableArray *balls = [NSMutableArray array];
    id listed = ECInvokeId(table, @"balls");
    if ([listed isKindOfClass:NSArray.class] || [listed isKindOfClass:NSSet.class]) {
        for (id ball in listed) {
            if (![ball respondsToSelector:NSSelectorFromString(@"position")]) continue;
            if (!ECInvokeBool(ball, @"onTable", YES)) continue;
            [balls addObject:ball];
        }
    }
    if (balls.count >= 1) return balls;
    unsigned count = 16;
    SEL countSel = NSSelectorFromString(@"getNumBallsOnTable");
    if (table && [table respondsToSelector:countSel]) {
        count = ((unsigned (*)(id, SEL))objc_msgSend)(table, countSel);
        if (count < 1 || count > 22) count = 16;
    }
    SEL byNumber = NSSelectorFromString(@"getBallByNumber:");
    if (table && [table respondsToSelector:byNumber]) {
        for (unsigned i = 0; i <= count + 3; i++) {
            id ball = ((id (*)(id, SEL, unsigned))objc_msgSend)(table, byNumber, i);
            if (!ball || ![ball respondsToSelector:NSSelectorFromString(@"position")]) continue;
            if (!ECInvokeBool(ball, @"onTable", YES)) continue;
            [balls addObject:ball];
        }
    }
    if (cueBall && ![balls containsObject:cueBall] && ECInvokeBool(cueBall, @"onTable", YES)) {
        [balls addObject:cueBall];
    }
    return balls;
}

static ECDPoint ECConvertDeviceToTable(id visualCue, ECDPoint device) {
    ECDPoint invalid = {NAN, NAN};
    SEL selector = NSSelectorFromString(@"convertDeviceToTableCoordinates:");
    if (!visualCue || ![visualCue respondsToSelector:selector]) return invalid;
    NSMethodSignature *signature = [visualCue methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 3) return invalid;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = selector;
    invocation.target = visualCue;
    [invocation setArgument:&device atIndex:2];
    [invocation invoke];
    ECDPoint table = invalid;
    [invocation getReturnValue:&table];
    return table;
}

static ECWorldMap ECMapFromSamples(id visualCue, CGPoint a, CGPoint b, CGPoint c, BOOL windowSpace) {
    ECWorldMap map = {0};
    ECDPoint tA = ECConvertDeviceToTable(visualCue, ECMakePoint(a.x, a.y));
    ECDPoint tB = ECConvertDeviceToTable(visualCue, ECMakePoint(b.x, b.y));
    ECDPoint tC = ECConvertDeviceToTable(visualCue, ECMakePoint(c.x, c.y));
    if (!ECPointValid(tA) || !ECPointValid(tB) || !ECPointValid(tC)) return map;
    double dx = (b.x - a.x);
    double dy = (c.y - a.y);
    if (fabs(dx) < 1 || fabs(dy) < 1) return map;
    double col0x = (tB.x - tA.x) / dx;
    double col0y = (tB.y - tA.y) / dx;
    double col1x = (tC.x - tA.x) / dy;
    double col1y = (tC.y - tA.y) / dy;
    double det = col0x * col1y - col0y * col1x;
    if (fabs(det) < 1e-12) return map;
    map.valid = YES;
    map.windowSpace = windowSpace;
    map.deviceA = a;
    map.tableA = tA;
    map.m00 = col1y / det;
    map.m01 = -col1x / det;
    map.m10 = -col0y / det;
    map.m11 = col0x / det;
    return map;
}

static CGPoint ECWorldToOverlay(ECWorldMap map, ECDPoint world, UIView *overlay) {
    double tx = world.x - map.tableA.x;
    double ty = world.y - map.tableA.y;
    CGPoint device = CGPointMake(map.deviceA.x + map.m00 * tx + map.m01 * ty,
                                 map.deviceA.y + map.m10 * tx + map.m11 * ty);
    if (map.windowSpace) return [overlay convertPoint:device fromView:nil];
    return device;
}

static BOOL ECOverlayContains(CGPoint point, UIView *overlay, CGFloat pad) {
    return CGRectContainsPoint(CGRectInset(overlay.bounds, -pad, -pad), point);
}

static ECWorldMap ECBuildWorldMap(id visualCue, ECDPoint cue, UIView *overlay) {
    ECWorldMap map = {0};
    if (!visualCue || !overlay) return map;
    CGPoint mid = CGPointMake(CGRectGetMidX(overlay.bounds), CGRectGetMidY(overlay.bounds));
    ECWorldMap local = ECMapFromSamples(visualCue,
                                        mid,
                                        CGPointMake(mid.x + 80, mid.y),
                                        CGPointMake(mid.x, mid.y + 80),
                                        NO);
    if (local.valid && ECOverlayContains(ECWorldToOverlay(local, cue, overlay), overlay, 80)) return local;
    CGPoint win = [overlay convertPoint:mid toView:nil];
    ECWorldMap windowMap = ECMapFromSamples(visualCue,
                                            win,
                                            CGPointMake(win.x + 80, win.y),
                                            CGPointMake(win.x, win.y + 80),
                                            YES);
    if (windowMap.valid && ECOverlayContains(ECWorldToOverlay(windowMap, cue, overlay), overlay, 80)) return windowMap;
    return local.valid ? local : windowMap;
}

static CGPoint ECWorldToFelt(ECDPoint world, ECDBox box, CGRect felt) {
    double width = box.maxX - box.minX;
    double height = box.maxY - box.minY;
    if (width < 1e-4 || height < 1e-4) return CGPointZero;
    double nx = (world.x - box.minX) / width;
    double ny = (world.y - box.minY) / height;
    return CGPointMake(felt.origin.x + nx * felt.size.width,
                       felt.origin.y + (1.0 - ny) * felt.size.height);
}

static double ECRayCircle(ECDPoint origin, ECDPoint dir, ECDPoint center, double radius) {
    double ox = origin.x - center.x;
    double oy = origin.y - center.y;
    double b = ox * dir.x + oy * dir.y;
    double c = ox * ox + oy * oy - radius * radius;
    double disc = b * b - c;
    if (disc < 0) return -1;
    return -b - sqrt(disc);
}

static void ECTracePath(ECDPoint start, ECDPoint direction, ECDBox box, double radius,
                        NSArray *balls, id ignoreA, id ignoreB, NSInteger maxBounces,
                        void (^emit)(ECDPoint, ECDPoint),
                        id *hitBallOut, ECDPoint *hitPosOut, ECDPoint *hitCenterOut, ECDPoint *inDirOut) {
    ECDPoint dir = ECNorm(direction);
    if (dir.x == 0 && dir.y == 0) return;
    ECDPoint origin = start;
    double left = box.minX + radius;
    double right = box.maxX - radius;
    double bottom = box.minY + radius;
    double top = box.maxY - radius;
    if (right - left < 1 || top - bottom < 1) {
        left = box.minX;
        right = box.maxX;
        bottom = box.minY;
        top = box.maxY;
    }
    double travel = hypot(box.maxX - box.minX, box.maxY - box.minY) * 3.0;
    for (NSInteger bounce = 0; bounce <= maxBounces; bounce++) {
        double tHit = travel;
        int kind = 0;
        ECDPoint normal = ECMakePoint(0, 0);
        id bestBall = nil;
        ECDPoint bestCenter = ECMakePoint(0, 0);
        if (dir.x > 1e-9) {
            double t = (right - origin.x) / dir.x;
            if (t > 1e-4 && t < tHit) { tHit = t; kind = 1; normal = ECMakePoint(-1, 0); }
        } else if (dir.x < -1e-9) {
            double t = (left - origin.x) / dir.x;
            if (t > 1e-4 && t < tHit) { tHit = t; kind = 1; normal = ECMakePoint(1, 0); }
        }
        if (dir.y > 1e-9) {
            double t = (top - origin.y) / dir.y;
            if (t > 1e-4 && t < tHit) { tHit = t; kind = 1; normal = ECMakePoint(0, -1); }
        } else if (dir.y < -1e-9) {
            double t = (bottom - origin.y) / dir.y;
            if (t > 1e-4 && t < tHit) { tHit = t; kind = 1; normal = ECMakePoint(0, 1); }
        }
        for (id ball in balls) {
            if (ball == ignoreA || ball == ignoreB) continue;
            ECDPoint center = ECReadDPoint(ball, @"position");
            if (!ECPointValid(center)) continue;
            double ballRadius = ECReadFloat(ball, @"radius", (float)radius);
            if (ballRadius < 0.01) ballRadius = radius;
            double t = ECRayCircle(origin, dir, center, radius + ballRadius);
            if (t > 1e-3 && t < tHit) {
                tHit = t;
                kind = 2;
                bestBall = ball;
                bestCenter = center;
            }
        }
        ECDPoint dest = ECMakePoint(origin.x + dir.x * tHit, origin.y + dir.y * tHit);
        if (emit) emit(origin, dest);
        if (kind == 2) {
            if (hitBallOut) *hitBallOut = bestBall;
            if (hitPosOut) *hitPosOut = dest;
            if (hitCenterOut) *hitCenterOut = bestCenter;
            if (inDirOut) *inDirOut = dir;
            return;
        }
        if (kind != 1) return;
        if (normal.x != 0) dir.x = -dir.x;
        if (normal.y != 0) dir.y = -dir.y;
        origin = dest;
    }
}

@interface EmberEightBPLineOverlay : UIView
@property (nonatomic, strong) CAShapeLayer *stroke;
@property (nonatomic, strong) CAShapeLayer *objectStroke;
@property (nonatomic, strong) CAShapeLayer *ghost;
@property (nonatomic, strong) CADisplayLink *link;
+ (instancetype)sharedOverlay;
- (void)attachToWindow:(UIWindow *)window;
- (void)clearPaths;
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
        stroke.strokeColor = [UIColor colorWithWhite:1 alpha:0.94].CGColor;
        stroke.lineWidth = 2.4;
        stroke.lineCap = kCALineCapRound;
        stroke.lineJoin = kCALineJoinRound;
        stroke.shadowColor = [UIColor colorWithRed:0.55 green:0.85 blue:1 alpha:1].CGColor;
        stroke.shadowRadius = 4;
        stroke.shadowOpacity = 0.75;
        [overlay.layer addSublayer:stroke];
        overlay.stroke = stroke;
        CAShapeLayer *objectStroke = [CAShapeLayer layer];
        objectStroke.fillColor = UIColor.clearColor.CGColor;
        objectStroke.strokeColor = [UIColor colorWithRed:1 green:0.82 blue:0.28 alpha:0.92].CGColor;
        objectStroke.lineWidth = 2.0;
        objectStroke.lineCap = kCALineCapRound;
        objectStroke.lineJoin = kCALineJoinRound;
        [overlay.layer addSublayer:objectStroke];
        overlay.objectStroke = objectStroke;
        CAShapeLayer *ghost = [CAShapeLayer layer];
        ghost.fillColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
        ghost.strokeColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor;
        ghost.lineWidth = 1.6;
        [overlay.layer addSublayer:ghost];
        overlay.ghost = ghost;
    });
    return overlay;
}

- (void)clearPaths {
    self.hidden = YES;
    self.stroke.path = nil;
    self.objectStroke.path = nil;
    self.ghost.path = nil;
}

- (void)attachToWindow:(UIWindow *)window {
    if (!window || !gECOverlayAllowed) return;
    self.frame = window.bounds;
    if (self.superview != window) {
        [self removeFromSuperview];
        [window addSubview:self];
    }
    [window bringSubviewToFront:self];
    UIView *button = [window viewWithTag:EC_LINES_BUTTON_TAG];
    if (button) [window bringSubviewToFront:button];
    if (self.link) return;
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (CGPoint)mapPoint:(ECDPoint)world map:(ECWorldMap)map box:(ECDBox)box {
    if (map.valid) return ECWorldToOverlay(map, world, self);
    return ECWorldToFelt(world, box, CGRectInset(self.bounds, 22, 36));
}

- (void)tick {
    @try {
        if (!gECOverlayAllowed || !gECInMatch || !ECExtensionIsActive() || gECMultiplier <= 1) {
            [self clearPaths];
            return;
        }
        id manager = gECGameManager ?: ECFindGameManager();
        id table = ECTableFromManager(manager);
        id visualCue = ECInvokeId(manager, @"visualCue");
        if (!table || !visualCue) {
            [self clearPaths];
            return;
        }
        if ([visualCue respondsToSelector:NSSelectorFromString(@"enabled")] &&
            !ECInvokeBool(visualCue, @"enabled", YES)) {
            [self clearPaths];
            return;
        }
        id cueBall = ECInvokeId(table, @"getCueBall");
        ECDPoint cue = ECReadDPoint(cueBall, @"position");
        if (!ECPointValid(cue)) {
            [self clearPaths];
            return;
        }
        float angle = ECReadFloat(visualCue, @"aimAngle", NAN);
        if (isnan(angle)) angle = ECReadFloat(visualCue, @"getAimAngleTarget", NAN);
        if (isnan(angle)) {
            [self clearPaths];
            return;
        }
        double radians = (fabs(angle) > 8.0) ? (angle * M_PI / 180.0) : angle;
        ECDPoint dir = ECMakePoint(cos(radians), sin(radians));
        double cueRadius = ECReadFloat(cueBall, @"radius", NAN);
        if (isnan(cueRadius) || cueRadius < 0.01) cueRadius = 3.6;
        ECDBox box = ECReadTableBox(table, cue);
        if (isnan(box.minX) || (box.maxX - box.minX) < 1 || (box.maxY - box.minY) < 1) {
            [self clearPaths];
            return;
        }
        NSArray *balls = ECBallsOnTable(table, cueBall);
        ECWorldMap map = ECBuildWorldMap(visualCue, cue, self);
        NSInteger bounces = gECMultiplier >= 8 ? 3 : (gECMultiplier >= 4 ? 2 : 1);
        UIBezierPath *cuePath = [UIBezierPath bezierPath];
        UIBezierPath *objectPath = [UIBezierPath bezierPath];
        __block NSInteger cueParts = 0;
        __weak typeof(self) weakSelf = self;
        id hitBall = nil;
        ECDPoint hitPos = ECMakePoint(NAN, NAN);
        ECDPoint hitCenter = ECMakePoint(NAN, NAN);
        ECDPoint inDir = dir;
        ECTracePath(cue, dir, box, cueRadius, balls, cueBall, nil, bounces, ^(ECDPoint from, ECDPoint to) {
            EmberEightBPLineOverlay *strongSelf = weakSelf;
            if (!strongSelf) return;
            CGPoint a = [strongSelf mapPoint:from map:map box:box];
            CGPoint b = [strongSelf mapPoint:to map:map box:box];
            if (cueParts == 0) [cuePath moveToPoint:a];
            [cuePath addLineToPoint:b];
            cueParts++;
        }, &hitBall, &hitPos, &hitCenter, &inDir);
        if (hitBall && ECPointValid(hitPos) && ECPointValid(hitCenter)) {
            ECDPoint normal = ECNorm(ECMakePoint(hitCenter.x - hitPos.x, hitCenter.y - hitPos.y));
            double objectRadius = ECReadFloat(hitBall, @"radius", (float)cueRadius);
            if (objectRadius < 0.01) objectRadius = cueRadius;
            __block NSInteger objectParts = 0;
            ECTracePath(hitCenter, normal, box, objectRadius, balls, cueBall, hitBall, 1, ^(ECDPoint from, ECDPoint to) {
                EmberEightBPLineOverlay *strongSelf = weakSelf;
                if (!strongSelf) return;
                CGPoint a = [strongSelf mapPoint:from map:map box:box];
                CGPoint b = [strongSelf mapPoint:to map:map box:box];
                if (objectParts == 0) [objectPath moveToPoint:a];
                [objectPath addLineToPoint:b];
                objectParts++;
            }, NULL, NULL, NULL, NULL);
            double transferred = inDir.x * normal.x + inDir.y * normal.y;
            ECDPoint leftover = ECMakePoint(inDir.x - normal.x * transferred, inDir.y - normal.y * transferred);
            if (hypot(leftover.x, leftover.y) > 0.08) {
                ECTracePath(hitPos, leftover, box, cueRadius, balls, cueBall, hitBall, 1, ^(ECDPoint from, ECDPoint to) {
                    EmberEightBPLineOverlay *strongSelf = weakSelf;
                    if (!strongSelf) return;
                    CGPoint a = [strongSelf mapPoint:from map:map box:box];
                    CGPoint b = [strongSelf mapPoint:to map:map box:box];
                    [cuePath addLineToPoint:a];
                    [cuePath addLineToPoint:b];
                }, NULL, NULL, NULL, NULL);
            }
            CGPoint ghostCenter = [self mapPoint:hitCenter map:map box:box];
            ECDPoint rim = ECMakePoint(hitCenter.x + objectRadius, hitCenter.y);
            CGPoint ghostRim = [self mapPoint:rim map:map box:box];
            CGFloat ghostR = MAX(6.0, hypot(ghostRim.x - ghostCenter.x, ghostRim.y - ghostCenter.y));
            self.ghost.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(ghostCenter.x - ghostR, ghostCenter.y - ghostR, ghostR * 2, ghostR * 2)].CGPath;
        } else {
            self.ghost.path = nil;
        }
        static BOOL dumped = NO;
        if (!dumped) {
            dumped = YES;
            CGPoint cueScreen = [self mapPoint:cue map:map box:box];
            ECLogLine([NSString stringWithFormat:@"overlay-phys balls=%lu angle=%.3f cue=%.2f,%.2f box=%.1f,%.1f,%.1f,%.1f map=%d screen=%.1f,%.1f hits=%d",
                       (unsigned long)balls.count, angle, cue.x, cue.y, box.minX, box.minY, box.maxX, box.maxY,
                       map.valid, cueScreen.x, cueScreen.y, hitBall != nil]);
        }
        if (cueParts == 0) {
            [self clearPaths];
            return;
        }
        self.hidden = NO;
        self.stroke.path = cuePath.CGPath;
        self.objectStroke.path = objectPath.CGPath;
    } @catch (NSException *exception) {
        [self clearPaths];
        ECLogLine([NSString stringWithFormat:@"overlay tick %@", exception]);
    }
}

@end

@interface EmberEightBPOfflineLinesController : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIButton *button;
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) NSTimer *keepAliveTimer;
+ (instancetype)sharedController;
- (UIWindow *)guestWindow;
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
        ECApplyAimValues();
        [weakSelf install];
    }];
}

- (void)stop {
    [self.keepAliveTimer invalidate];
    self.keepAliveTimer = nil;
}

@end

static void ECScheduleOverlay(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!gECInMatch) return;
        gECOverlayAllowed = YES;
        UIWindow *window = [[EmberEightBPOfflineLinesController sharedController] guestWindow];
        if (!window) return;
        [[EmberEightBPLineOverlay sharedOverlay] attachToWindow:window];
        ECLogLine(@"overlay-attached");
    });
}

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
