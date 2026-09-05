// EightBPOfflineLines.m — native guideline extension for local 8 Ball Pool.
// Active in Practice, Play Offline, and Pass and Play / hotseat. Network matches stay locked.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>
#import <string.h>
#import <stdint.h>
#import <stdlib.h>

#define EC_LINES_BUTTON_TAG 0x8B901
#define EC_LINE_OVERLAY_TAG 0x8B902

static NSString *const ECBundleIdentifier = @"com.miniclip.8ballpoolmult";
static NSString *const ECMultiplierKey = @"EmberEightBPOfflineLines.multiplier";
static NSString *const ECButtonXKey = @"EmberEightBPOfflineLines.buttonX";
static NSString *const ECButtonYKey = @"EmberEightBPOfflineLines.buttonY";

static id gECGameManager = nil;
static BOOL gECInMatch = NO;
static BOOL gECOverlayAllowed = NO;
static BOOL gECOverlayDead = NO;
static NSInteger gECMultiplier = 8;
static BOOL gECHooksInstalled = NO;

@class EmberEightBPLineOverlay;
@class EmberEightBPOfflineLinesController;
static void ECScheduleOverlay(void);
static void ECRequestOverlayRedraw(void);
static void ECStripUIKitOverlay(void);
static void ECRemoveBallMarkers(void);
static void ECSyncCocosMarker(id ball, BOOL visualFresh);
static void ECDropBallMarker(id ball);
static void ECClearPotted(id ball);
static int ECSlotForBall(id ball);
static BOOL ECLooksLikeObject(id object);
static id ECIvarObject(id object, const char *name);

typedef struct { double x, y; } ECDPoint;
typedef struct { double minX, minY, maxX, maxY; } ECDBox;
typedef struct { ECDPoint pos; double radius; } ECSnap;

static BOOL ECPointValid(ECDPoint p);

static inline ECDPoint ECMakePoint(double x, double y) { return (ECDPoint){x, y}; }

static float gECCachedAngle = NAN;
static ECDPoint gECAimDir = {NAN, NAN};
static id gECCachedCueBall = nil;
static id gECCachedTable = nil;
static id gECCachedBalls[20];
static ECSnap gECCachedSnaps[20];
static int gECCachedSnapCount = 0;
static CGPoint gECCachedVisualOrigin = {NAN, NAN};
static float gECVisualScale = 0;
// Ball updateVisualBall maps physics -> visual with one scale shared by every
// ball (it picks between two constants from a global render mode), so this is
// latched once from a ball far enough off the table origin to measure cleanly.
static double gECDerivedVisualScale = 0;
static ECDBox gECTableBox = {NAN, NAN, NAN, NAN};
static __weak UIView *gECRenderHost = nil;
static __weak UIView *gECVisualCueView = nil;
static CGPoint gECMapCenter = {NAN, NAN};
static double gECMapScale = 0;
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
static void (*ECOriginalSetAimAngle)(id, SEL, double) = NULL;
static id (*ECOriginalGetCueBall)(id, SEL) = NULL;
static void (*ECOriginalBallSetPosition)(id, SEL, ECDPoint) = NULL;
static void (*ECOriginalBallSpotAt)(id, SEL, ECDPoint) = NULL;
static void (*ECOriginalBallSetRadius)(id, SEL, double) = NULL;
static void (*ECOriginalBallSetVisualOrigin)(id, SEL, CGPoint) = NULL;
static void (*ECOriginalBallSetVisualScale)(id, SEL, float) = NULL;
static void (*ECOriginalUpdateVisualBall)(id, SEL) = NULL;
static void (*ECOriginalRemoveVisualBall)(id, SEL) = NULL;
static CGPoint gECWindowPos[20];
static CGFloat gECWindowRadius[20];
static BOOL gECHasWindow[20];
/** Latches once a ball is potted; cleared only by a respot or a new rack. */
static BOOL gECPotted[20];
static int gECWindowHits = 0;
static __weak UIView *gECGLView = nil;
static id gECRingTexture = nil;
static int gECVisualLog = 0;
static int gECReparentLog = 0;
static int gECHiddenLog = 0;
static const void *kECMarkerKey = &kECMarkerKey;

// Ring geometry. The drawn band stops EC_RING_INSET short of the texture edge,
// so EC_RING_OUTER_FRACTION is how much of the sprite the visible circle uses.
#define EC_RING_TEXTURE_SIZE 128
#define EC_RING_INSET 2.0
#define EC_RING_BAND 9.0
#define EC_RING_OUTER_FRACTION ((EC_RING_TEXTURE_SIZE * 0.5 - EC_RING_INSET) / (EC_RING_TEXTURE_SIZE * 0.5))
#define EC_RING_PADDING 1.18

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

// UserInfo lowAimRatio / highAimRatio are the selected cue's real aim stat
// (observed 8 / 14). The 2017 iOSGods span (-900 / 1300) freezes cue rotation
// on 56.29.2 — the player can still shoot and place ball-in-hand, but the cue
// will not turn. Guide length comes from CueStats.aim instead, so leave the
// aim stats completely alone.
static void ECApplyAimValues(void) {
    static BOOL dumped = NO;
    if (dumped || !ECExtensionIsActive()) return;
    dumped = YES;
    ECDumpAimIvars(ECFindUserInfo(), @"userInfo");
    ECDumpAimIvars(ECFindGameManager(), @"gameManager");
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
        gECOverlayAllowed = YES;
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
    gECOverlayDead = NO;
    gECCachedAngle = NAN;
    gECAimDir = (ECDPoint){NAN, NAN};
    gECCachedCueBall = nil;
    gECCachedSnapCount = 0;
    gECCachedVisualOrigin = CGPointMake(NAN, NAN);
    gECVisualScale = 0;
    gECDerivedVisualScale = 0;
    gECTableBox = (ECDBox){NAN, NAN, NAN, NAN};
    gECRenderHost = nil;
    gECVisualCueView = nil;
    gECMapCenter = CGPointMake(NAN, NAN);
    gECMapScale = 0;
    gECGLView = nil;
    gECWindowHits = 0;
    gECVisualLog = 0;
    gECReparentLog = 0;
    gECHiddenLog = 0;
    gECCachedTable = nil;
    memset(gECHasWindow, 0, sizeof(gECHasWindow));
    memset(gECPotted, 0, sizeof(gECPotted));
    ECRemoveBallMarkers();
    ECStripUIKitOverlay();
    dispatch_async(dispatch_get_main_queue(), ^{ ECWriteStatus(@"game-exited"); });
}

static void ECStartHotSeatGame(id self, SEL selector) {
    ECCaptureGameManager(self);
    if (ECOriginalStartHotSeatGame) ECOriginalStartHotSeatGame(self, selector);
    gECInMatch = YES;
    // A fresh rack puts every ball back in play.
    memset(gECPotted, 0, sizeof(gECPotted));
    dispatch_async(dispatch_get_main_queue(), ^{
        gECOverlayAllowed = YES;
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

static void ECCacheBallPosition(id ball, ECDPoint pos) {
    if (!ball) return;
    for (int i = 0; i < gECCachedSnapCount; i++) {
        if (gECCachedBalls[i] == ball) {
            gECCachedSnaps[i].pos = pos;
            return;
        }
    }
    if (gECCachedSnapCount >= 20) return;
    gECCachedBalls[gECCachedSnapCount] = ball;
    gECCachedSnaps[gECCachedSnapCount].pos = pos;
    gECCachedSnaps[gECCachedSnapCount].radius = 3.6;
    gECCachedSnapCount++;
}

static void ECCacheBallRadius(id ball, double radius) {
    if (!ball || radius < 0.01) return;
    for (int i = 0; i < gECCachedSnapCount; i++) {
        if (gECCachedBalls[i] == ball) {
            gECCachedSnaps[i].radius = radius;
            return;
        }
    }
}

static void ECSetAimAngle(id self, SEL selector, double angle) {
    gECCachedAngle = (float)angle;
    if ([self isKindOfClass:UIView.class]) gECVisualCueView = (UIView *)self;
    if (ECOriginalSetAimAngle) ECOriginalSetAimAngle(self, selector, angle);
}

static id ECGetCueBallHook(id self, SEL selector) {
    id ball = ECOriginalGetCueBall ? ECOriginalGetCueBall(self, selector) : nil;
    if (ball) gECCachedCueBall = ball;
    // This is hooked on Table, so self is the table that owns mBallsPotted.
    if (self) gECCachedTable = self;
    return ball;
}

static void ECBallSetPosition(id self, SEL selector, ECDPoint pos) {
    if (ECOriginalBallSetPosition) ECOriginalBallSetPosition(self, selector, pos);
    ECCacheBallPosition(self, pos);
    if (gECInMatch) {
        // The sphere has not been moved yet, so this cannot be used to measure
        // the visual scale.
        @try { ECSyncCocosMarker(self, NO); }
        @catch (NSException *exception) { }
    }
}

// A respot puts the ball back in play, so it must clear the potted latch.
static void ECBallSpotAt(id self, SEL selector, ECDPoint pos) {
    if (ECOriginalBallSpotAt) ECOriginalBallSpotAt(self, selector, pos);
    ECCacheBallPosition(self, pos);
    ECClearPotted(self);
}

static void ECRemoveVisualBall(id self, SEL selector) {
    @try { ECDropBallMarker(self); }
    @catch (NSException *exception) { }
    if (ECOriginalRemoveVisualBall) ECOriginalRemoveVisualBall(self, selector);
}

static void ECBallSetRadius(id self, SEL selector, double radius) {
    if (ECOriginalBallSetRadius) ECOriginalBallSetRadius(self, selector, radius);
    ECCacheBallRadius(self, radius);
}

static void ECBallSetVisualOrigin(id self, SEL selector, CGPoint origin) {
    gECCachedVisualOrigin = origin;
    if (ECOriginalBallSetVisualOrigin) ECOriginalBallSetVisualOrigin(self, selector, origin);
}

static void ECBallSetVisualScale(id self, SEL selector, float scale) {
    if (scale > 0.05f && scale < 40.0f) gECVisualScale = scale;
    if (ECOriginalBallSetVisualScale) ECOriginalBallSetVisualScale(self, selector, scale);
}

static id ECSharedDirector(void) {
    Class cls = NSClassFromString(@"CCDirector");
    return cls ? ECInvokeId(cls, @"sharedDirector") : nil;
}

static UIView *ECDirectorGLView(void) {
    if (gECGLView && gECGLView.superview) return gECGLView;
    id director = ECSharedDirector();
    id view = ECInvokeId(director, @"view");
    if (![view isKindOfClass:UIView.class]) view = ECInvokeId(director, @"openGLView");
    if ([view isKindOfClass:UIView.class]) gECGLView = (UIView *)view;
    return gECGLView;
}

static id ECVisualSphere(id ball) {
    return ECIvarObject(ball, "visualBall");
}

// CCTexture2D here is Miniclip's fork: initWithData:pixelFormat:... forwards
// the format straight into mc::renderer, so the stock cocos2d enum values do
// not apply. Guessing wrong makes the renderer read the wrong bytes per pixel
// and shears the ring into blades. Probe instead and keep the format that
// reports 32 bits per pixel.
static id ECCircleTexture(void) {
    if (gECRingTexture) return gECRingTexture;
    Class texCls = NSClassFromString(@"CCTexture2D");
    if (!texCls) return nil;
    SEL initSel = @selector(initWithData:pixelFormat:pixelsWide:pixelsHigh:contentSize:);
    const int n = EC_RING_TEXTURE_SIZE;
    uint32_t *pixels = calloc((size_t)n * n, sizeof(uint32_t));
    if (!pixels) return nil;
    float cx = (n - 1) * 0.5f;
    float outer = (float)(n * 0.5 - EC_RING_INSET);
    float inner = (float)(outer - EC_RING_BAND);
    float mid = (outer + inner) * 0.5f;
    float half = (outer - inner) * 0.5f;
    for (int y = 0; y < n; y++) {
        for (int x = 0; x < n; x++) {
            float d = hypotf((float)x - cx, (float)y - cx);
            float edge = half - fabsf(d - mid);
            if (edge <= 0) continue;
            float a = edge < 1.5f ? edge / 1.5f : 1.0f;
            // Premultiplied white so setColor: tints cleanly.
            uint32_t v = (uint32_t)(a * 255.0f);
            pixels[y * n + x] = (v << 24) | (v << 16) | (v << 8) | v;
        }
    }
    static const int formats[] = {1, 0, 2, 3, 6, 7, 8, 4, 5};
    for (size_t i = 0; i < sizeof(formats) / sizeof(formats[0]); i++) {
        id tex = ((id (*)(id, SEL))objc_msgSend)(texCls, @selector(alloc));
        if (![tex respondsToSelector:initSel]) break;
        tex = ((id (*)(id, SEL, const void *, int, unsigned long, unsigned long, CGSize))objc_msgSend)(
            tex, initSel, pixels, formats[i], (unsigned long)n, (unsigned long)n, CGSizeMake(n, n));
        if (!ECLooksLikeObject(tex)) continue;
        unsigned long bits = 0;
        if ([tex respondsToSelector:@selector(bitsPerPixelForFormat)]) {
            bits = ((unsigned long (*)(id, SEL))objc_msgSend)(tex, @selector(bitsPerPixelForFormat));
        }
        unsigned long wide = 0;
        if ([tex respondsToSelector:@selector(pixelsWide)]) {
            wide = ((unsigned long (*)(id, SEL))objc_msgSend)(tex, @selector(pixelsWide));
        }
        CGSize content = CGSizeZero;
        if ([tex respondsToSelector:@selector(contentSize)]) {
            content = ((CGSize (*)(id, SEL))objc_msgSend)(tex, @selector(contentSize));
        }
        ECLogLine([NSString stringWithFormat:@"ring-fmt try=%d bits=%lu wide=%lu content=%.1fx%.1f",
                   formats[i], bits, wide, content.width, content.height]);
        if (bits == 32 && wide == (unsigned long)n) {
            gECRingTexture = tex;
            break;
        }
    }
    free(pixels);
    if (gECRingTexture) {
        if ([gECRingTexture respondsToSelector:@selector(setHasPremultipliedAlpha:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(gECRingTexture, @selector(setHasPremultipliedAlpha:), YES);
        }
        if ([gECRingTexture respondsToSelector:@selector(setAntiAliasTexParameters)]) {
            ((void (*)(id, SEL))objc_msgSend)(gECRingTexture, @selector(setAntiAliasTexParameters));
        }
    } else {
        // No usable raw format. Let the engine build the bitmap itself from a
        // circle glyph — it owns the pixel format on that path.
        SEL glyphSel = @selector(initWithString:dimensions:alignment:fontName:fontSize:);
        id tex = ((id (*)(id, SEL))objc_msgSend)(texCls, @selector(alloc));
        if ([tex respondsToSelector:glyphSel]) {
            tex = ((id (*)(id, SEL, id, CGSize, unsigned char, id, double))objc_msgSend)(
                tex, glyphSel, @"\u25EF", CGSizeMake(n, n), 1, @"Helvetica", 104.0);
        } else {
            tex = nil;
        }
        if (ECLooksLikeObject(tex)) gECRingTexture = tex;
        ECLogLine([NSString stringWithFormat:@"ring-fmt glyph=%d", gECRingTexture != nil]);
    }
    return gECRingTexture;
}

static void ECRemoveBallMarkers(void) {
    for (int i = 0; i < 20; i++) {
        id ball = gECCachedBalls[i];
        if (!ball) continue;
        ECDropBallMarker(ball);
        gECCachedBalls[i] = nil;
        gECPotted[i] = NO;
    }
    gECCachedSnapCount = 0;
}

static void ECStripUIKitOverlay(void) {
    UIView *gl = ECDirectorGLView();
    UIView *found = [gl viewWithTag:EC_LINE_OVERLAY_TAG];
    if (found) [found removeFromSuperview];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIView *overlay = [window viewWithTag:EC_LINE_OVERLAY_TAG];
            if (overlay) [overlay removeFromSuperview];
        }
    }
}

// Neither Ball onTable nor the sphere's visible flag survives a shot: onTable
// is state 1..2 while setState: also uses 2 and 4 just to swap the sphere
// between _clothClippingNode and _notClippingNode, and the visible flag gets
// cleared while the balls are in motion. Table keeps an explicit mBallsPotted
// list, which is the game's own record of what has actually been potted, so it
// says nothing about motion and cannot flip back on its own.
// Latched, because mBallsPotted is the table's working list for a shot and the
// game empties it in processPottedBalls; without the latch the ring would come
// back once the list was cleared. A respot is the only thing that undoes it.
static BOOL ECBallIsPotted(id ball) {
    if (!ball) return NO;
    int slot = ECSlotForBall(ball);
    if (slot >= 0 && gECPotted[slot]) return YES;
    if (!gECCachedTable) return NO;
    id potted = ECIvarObject(gECCachedTable, "mBallsPotted");
    if (![potted isKindOfClass:NSArray.class]) return NO;
    if ([(NSArray *)potted indexOfObjectIdenticalTo:ball] == NSNotFound) return NO;
    if (slot >= 0) gECPotted[slot] = YES;
    return YES;
}

static void ECClearPotted(id ball) {
    int slot = ECSlotForBall(ball);
    if (slot >= 0) gECPotted[slot] = NO;
}

static BOOL ECSphereVisible(id sphere) {
    if (![sphere respondsToSelector:@selector(visible)]) return YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(sphere, @selector(visible));
}

static void ECSetMarkerVisible(id marker, BOOL visible) {
    if (marker && [marker respondsToSelector:@selector(setVisible:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(marker, @selector(setVisible:), visible);
    }
}

// Ball position is a struct of two doubles and radius is an MCNumber wrapping
// one double, so both come back in floating-point registers. Reading them live
// keeps them in step with the sphere position we pair them against.
static ECDPoint ECBallLivePosition(id ball) {
    if (![ball respondsToSelector:@selector(position)]) return (ECDPoint){NAN, NAN};
    return ((ECDPoint (*)(id, SEL))objc_msgSend)(ball, @selector(position));
}

static double ECBallLiveRadius(id ball) {
    if (![ball respondsToSelector:@selector(radius)]) return 0;
    double r = ((double (*)(id, SEL))objc_msgSend)(ball, @selector(radius));
    return (r > 0.5 && r < 20.0) ? r : 0;
}

static void ECDropBallMarker(id ball) {
    if (!ball) return;
    id marker = objc_getAssociatedObject(ball, kECMarkerKey);
    if (marker && [marker respondsToSelector:@selector(removeFromParent)]) {
        ((void (*)(id, SEL))objc_msgSend)(marker, @selector(removeFromParent));
    }
    objc_setAssociatedObject(ball, kECMarkerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ECSyncCocosMarker(id ball, BOOL visualFresh) {
    if (!ECLooksLikeObject(ball)) return;
    id sphere = ECVisualSphere(ball);
    if (!ECLooksLikeObject(sphere)) return;
    id existing = objc_getAssociatedObject(ball, kECMarkerKey);
    if (ECBallIsPotted(ball)) {
        ECSetMarkerVisible(existing, NO);
        return;
    }
    // setState: leaves the sphere parentless until it is re-added, so hide
    // rather than drop: dropping here is what made rings vanish mid-rack.
    id parent = ECInvokeId(sphere, @"parent");
    if (!ECLooksLikeObject(parent)) {
        ECSetMarkerVisible(existing, NO);
        if (existing && gECHiddenLog < 12) {
            gECHiddenLog++;
            ECLogLine([NSString stringWithFormat:@"ring-hidden slot=%d noparent sphereVisible=%d",
                       ECSlotForBall(ball), ECSphereVisible(sphere)]);
        }
        return;
    }
    CGPoint pos = CGPointZero;
    if ([sphere respondsToSelector:@selector(position)]) {
        pos = ((CGPoint (*)(id, SEL))objc_msgSend)(sphere, @selector(position));
    }
    int slot = ECSlotForBall(ball);
    id marker = existing;
    if (!ECLooksLikeObject(marker)) {
        id texture = ECCircleTexture();
        Class spriteCls = NSClassFromString(@"CCSprite");
        if (!texture || !spriteCls) return;
        marker = ((id (*)(id, SEL))objc_msgSend)(spriteCls, @selector(alloc));
        marker = ((id (*)(id, SEL, id))objc_msgSend)(marker, @selector(initWithTexture:), texture);
        if (!ECLooksLikeObject(marker)) return;
        if ([marker respondsToSelector:@selector(setOpacity:)]) {
            ((void (*)(id, SEL, unsigned char))objc_msgSend)(marker, @selector(setOpacity:), 230);
        }
        typedef struct { uint8_t r, g, b; } ECccColor3B;
        ECccColor3B color = (ball == gECCachedCueBall)
            ? (ECccColor3B){255, 255, 255}
            : (ECccColor3B){255, 210, 40};
        if ([marker respondsToSelector:@selector(setColor:)]) {
            ((void (*)(id, SEL, ECccColor3B))objc_msgSend)(marker, @selector(setColor:), color);
        }
        if ([parent respondsToSelector:@selector(addChild:z:)]) {
            ((void (*)(id, SEL, id, long long))objc_msgSend)(parent, @selector(addChild:z:), marker, 800);
        } else if ([parent respondsToSelector:@selector(addChild:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(parent, @selector(addChild:), marker);
        }
        objc_setAssociatedObject(ball, kECMarkerKey, marker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (gECVisualLog < 4) {
            gECVisualLog++;
            CGSize size = CGSizeZero;
            if ([sphere respondsToSelector:@selector(contentSize)]) {
                size = ((CGSize (*)(id, SEL))objc_msgSend)(sphere, @selector(contentSize));
            }
            ECLogLine([NSString stringWithFormat:@"cocos-marker pos=%.1f,%.1f size=%.1fx%.1f parent=%@ cue=%d",
                       pos.x, pos.y, size.width, size.height, [parent class], ball == gECCachedCueBall]);
        }
    }
    ECSetMarkerVisible(marker, YES);
    if ([marker respondsToSelector:@selector(setPosition:)]) {
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(marker, @selector(setPosition:), pos);
    }
    // ProjectedSphere is a 3D node, so its contentSize is 0x0 and cannot size
    // the ring. updateVisualBall builds the sphere position as
    //   visual = mVisualTableOrigin + physics * scale
    // with one scale for every ball, so measure that scale once from a ball far
    // enough from the origin that the division is well conditioned. Measuring
    // per ball is what made some rings tiny and others huge: balls sitting near
    // the origin divide by a near-zero physics coordinate.
    if (visualFresh) {
        ECDPoint phys = ECBallLivePosition(ball);
        CGPoint origin = gECCachedVisualOrigin;
        if (ECPointValid(phys) && isfinite(origin.x) && isfinite(origin.y)) {
            BOOL useX = fabs(phys.x) >= fabs(phys.y);
            double denom = useX ? phys.x : phys.y;
            double delta = useX ? (pos.x - origin.x) : (pos.y - origin.y);
            if (fabs(denom) >= 20.0) {
                double candidate = delta / denom;
                if (candidate > 0.2 && candidate < 20.0) gECDerivedVisualScale = candidate;
            }
        }
    }
    if ([marker respondsToSelector:@selector(contentSize)]) {
        CGSize markSize = ((CGSize (*)(id, SEL))objc_msgSend)(marker, @selector(contentSize));
        double radius = ECBallLiveRadius(ball);
        if (radius <= 0 && slot >= 0) radius = gECCachedSnaps[slot].radius;
        if (radius <= 0.5) radius = 3.6;
        double vscale = gECDerivedVisualScale > 0.2 ? gECDerivedVisualScale : 1.7007874015748;
        // The drawn ring stops short of the sprite edge, so convert the wanted
        // outer diameter into a sprite size instead of scaling the sprite to it.
        double wanted = radius * vscale * 2.0 * EC_RING_PADDING / EC_RING_OUTER_FRACTION;
        if (markSize.width > 1 && wanted > 1 && [marker respondsToSelector:@selector(setScale:)]) {
            ((void (*)(id, SEL, float))objc_msgSend)(marker, @selector(setScale:), (float)(wanted / markSize.width));
            if (gECVisualLog < 6) {
                gECVisualLog++;
                ECLogLine([NSString stringWithFormat:@"ring-size mark=%.1f r=%.2f vscale=%.4f sprite=%.1f fresh=%d",
                           markSize.width, radius, vscale, wanted, visualFresh]);
            }
        }
    }
    // setState: re-parents the sphere between the clipping nodes, so the ring
    // has to be moved across with it or it is left behind on the old node.
    id markerParent = ECInvokeId(marker, @"parent");
    if (markerParent != parent && [parent respondsToSelector:@selector(addChild:z:)]) {
        if ([marker respondsToSelector:@selector(removeFromParent)]) {
            ((void (*)(id, SEL))objc_msgSend)(marker, @selector(removeFromParent));
        }
        ((void (*)(id, SEL, id, long long))objc_msgSend)(parent, @selector(addChild:z:), marker, 800);
        if (gECReparentLog < 12) {
            gECReparentLog++;
            ECLogLine([NSString stringWithFormat:@"ring-reparent slot=%d from=%@ to=%@ sphereVisible=%d",
                       slot, [markerParent class], [parent class], ECSphereVisible(sphere)]);
        }
    }
}

static int ECSlotForBall(id ball) {
    if (!ball) return -1;
    for (int i = 0; i < gECCachedSnapCount; i++) {
        if (gECCachedBalls[i] == ball) return i;
    }
    if (gECCachedSnapCount >= 20) return -1;
    int i = gECCachedSnapCount++;
    gECCachedBalls[i] = ball;
    gECCachedSnaps[i].pos = (ECDPoint){NAN, NAN};
    gECCachedSnaps[i].radius = 3.6;
    gECHasWindow[i] = NO;
    gECPotted[i] = NO;
    return i;
}

static void ECUpdateVisualBall(id self, SEL selector) {
    if (ECOriginalUpdateVisualBall) ECOriginalUpdateVisualBall(self, selector);
    if (!gECInMatch) return;
    @try {
        ECSyncCocosMarker(self, YES);
    } @catch (NSException *exception) {
        ECLogLine([NSString stringWithFormat:@"cocos-marker %@", exception]);
    }
}

static void ECUpdateVisualGuide(id self, SEL selector) {
    ECCaptureGameManager(self);
    ECApplyAimValues();
    if (ECOriginalUpdateVisualGuide) ECOriginalUpdateVisualGuide(self, selector);
    if (ECExtensionIsActive()) {
        ECApplyAimValues();
        ECRequestOverlayRedraw();
    }
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

static BOOL ECHookIMP(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
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
        // No hooks on lowAimRatio / highAimRatio / guidelineRange / setAimAngle: /
        // updateCueStatsAndVisualGuide. Touching the aim stats or the guide
        // rebuild locks the cue so it cannot be rotated by dragging.
        BOOL lowOK = YES, highOK = YES, setLowOK = YES, setHighOK = YES;
        BOOL statsOK = ECHookCueStatsGetter(userInfo, NSSelectorFromString(@"getCueStats:"),
                                            (IMP)ECGetCueStats, (IMP *)&ECOriginalGetCueStats);
        BOOL bonusOK = ECHookCueStatsGetter(userInfo, NSSelectorFromString(@"getCueStatsWithBonus:"),
                                            (IMP)ECGetCueStatsWithBonus, (IMP *)&ECOriginalGetCueStatsWithBonus);
        BOOL applyOK = ECHookApplyCueStats(gameManager, NSSelectorFromString(@"applyCueStatsForShot:aim:spin:"),
                                           (IMP)ECApplyCueStatsForShot, (IMP *)&ECOriginalApplyCueStatsForShot);

        Class visualCue = NSClassFromString(@"VisualCue");
        Class table = NSClassFromString(@"Table");
        Class ball = NSClassFromString(@"Ball");
        BOOL aimOK = NO;
        BOOL cueBallOK = ECHookIMP(table, NSSelectorFromString(@"getCueBall"),
                                  (IMP)ECGetCueBallHook, (IMP *)&ECOriginalGetCueBall);
        BOOL posOK = ECHookIMP(ball, NSSelectorFromString(@"setPosition:"),
                               (IMP)ECBallSetPosition, (IMP *)&ECOriginalBallSetPosition);
        BOOL spotOK = ECHookIMP(ball, NSSelectorFromString(@"spotAt:"),
                                (IMP)ECBallSpotAt, (IMP *)&ECOriginalBallSpotAt);
        BOOL radOK = ECHookIMP(ball, NSSelectorFromString(@"setRadius:"),
                               (IMP)ECBallSetRadius, (IMP *)&ECOriginalBallSetRadius);
        BOOL originOK = ECHookIMP(ball, NSSelectorFromString(@"setVisualTableOrigin:"),
                                  (IMP)ECBallSetVisualOrigin, (IMP *)&ECOriginalBallSetVisualOrigin);
        BOOL scaleOK = ECHookIMP(ball, NSSelectorFromString(@"setVisualBallScale:"),
                                 (IMP)ECBallSetVisualScale, (IMP *)&ECOriginalBallSetVisualScale);
        BOOL visualOK = ECHookVoidMethod(ball, NSSelectorFromString(@"updateVisualBall"),
                                        (IMP)ECUpdateVisualBall, (IMP *)&ECOriginalUpdateVisualBall);
        BOOL rmOK = ECHookVoidMethod(ball, NSSelectorFromString(@"removeVisualBallFromParent"),
                                     (IMP)ECRemoveVisualBall, (IMP *)&ECOriginalRemoveVisualBall);
        ECLogLine([NSString stringWithFormat:@"observe aim=%d cueBall=%d pos=%d spot=%d rad=%d origin=%d scale=%d visual=%d rm=%d",
                   aimOK, cueBallOK, posOK, spotOK, radOK, originOK, scaleOK, visualOK, rmOK]);
        ECDumpClassSelectors(visualCue, @"visualCue");
        ECDumpClassSelectors(NSClassFromString(@"VisualCueWide"), @"visualCueWide");
        ECDumpClassSelectors(userInfo, @"userInfoClass");
        ECDumpClassSelectors(gameManager, @"gameManagerClass");

        // These two are the extended-line switches and they live on
        // UserSettingsManager, not VisualCue/GameManager. They were dropped
        // while chasing the frozen cue, which is what stopped the lines from
        // extending. They are plain getters and never write aim state, so the
        // cue still rotates with them on.
        BOOL trajOK = ECHookBoolGetter(settings, NSSelectorFromString(@"showCueBallTrajectory"),
                                       (IMP)ECShowCueBallTrajectory, (IMP *)&ECOriginalShowCueBallTrajectory);
        BOOL wideOK = ECHookBoolGetter(settings, NSSelectorFromString(@"wideGuideline"),
                                       (IMP)ECWideGuideline, (IMP *)&ECOriginalWideGuideline);
        ECLogLine([NSString stringWithFormat:@"guide-hooks traj=%d wide=%d", trajOK, wideOK]);
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

static BOOL ECIsGLNamed(NSString *name) {
    return [name containsString:@"EAGL"] || [name containsString:@"Metal"] ||
           [name containsString:@"GLK"] || [name containsString:@"CCGL"] ||
           [name containsString:@"Render"] || [name containsString:@"Cocos"] ||
           [name containsString:@"Director"] || [name containsString:@"CCDirector"];
}

static UIView *ECRenderView(UIWindow *window) {
    if (gECVisualCueView && gECVisualCueView.window) return gECVisualCueView;
    __block UIView *best = nil;
    __block double bestScore = -1;
    CGPoint origin = gECCachedVisualOrigin;
    void (^walk)(UIView *);
    __block void (^walkBlock)(UIView *) = ^(UIView *view) {
        CGFloat w = CGRectGetWidth(view.bounds);
        CGFloat h = CGRectGetHeight(view.bounds);
        if (w > 200 && h > 90) {
            NSString *name = NSStringFromClass(view.class);
            double aspect = w / MAX(h, 1);
            double score = 0;
            if (ECIsGLNamed(name)) score += 6;
            if ([name containsString:@"VisualCue"]) score += 12;
            if (aspect > 1.45 && aspect < 2.7) score += 3;
            if (isfinite(origin.x) && isfinite(origin.y)) {
                double dist = hypot(origin.x - w * 0.5, origin.y - h * 0.5);
                double rel = dist / MAX(0.5 * hypot(w, h), 1);
                if (rel < 0.08) score += 30 - rel * 80;
                else if (rel < 0.14) score += 8;
            }
            score += log(w * h) * 0.15;
            if (score > bestScore) {
                best = view;
                bestScore = score;
            }
        }
        for (UIView *child in view.subviews) walkBlock(child);
    };
    walk = walkBlock;
    if (window) walk(window);
    return best;
}

static CGRect ECFeltRectInView(UIView *space, UIView *host) {
    CGRect felt = space.bounds;
    if (host && host != space && host != space.window) {
        CGRect converted = [space convertRect:host.bounds fromView:host];
        if (converted.size.width > 180 && converted.size.height > 80) felt = converted;
    }
    CGFloat insetY = MAX(36, felt.size.height * 0.10);
    felt = CGRectInset(felt, 4, insetY);
    double aspect = 2.0;
    if (felt.size.height > 1 && felt.size.width / felt.size.height > aspect) {
        CGFloat width = felt.size.height * aspect;
        felt.origin.x += (felt.size.width - width) * 0.5;
        felt.size.width = width;
    } else if (felt.size.width > 1) {
        CGFloat height = felt.size.width / aspect;
        felt.origin.y += (felt.size.height - height) * 0.5;
        felt.size.height = height;
    }
    return felt;
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

static ECDBox ECDefaultTableBox(void) {
    return (ECDBox){-127.0, -63.5, 127.0, 63.5};
}

static BOOL ECLooksLikeObject(id object) {
    if (!object) return NO;
    uintptr_t bits = (uintptr_t)object;
    if (bits < 0x10000 || (bits & 1)) return NO;
    Class cls = object_getClass(object);
    return cls && object_getClass(cls);
}

static id ECTableFromManager(id manager) {
    id table = ECInvokeId(manager, @"table");
    if (ECLooksLikeObject(table)) return table;
    table = ECInvokeId(manager, @"getTable");
    return ECLooksLikeObject(table) ? table : nil;
}

static ECDBox ECBoxFromSnaps(const ECSnap *snaps, int count, ECDPoint cue, double cueRadius) {
    double minX = cue.x, maxX = cue.x, minY = cue.y, maxY = cue.y;
    for (int i = 0; i < count; i++) {
        minX = MIN(minX, snaps[i].pos.x);
        maxX = MAX(maxX, snaps[i].pos.x);
        minY = MIN(minY, snaps[i].pos.y);
        maxY = MAX(maxY, snaps[i].pos.y);
    }
    double pad = MAX(cueRadius * 8.0, 12.0);
    minX -= pad;
    maxX += pad;
    minY -= pad;
    maxY += pad;
    double cx = (minX + maxX) * 0.5;
    double cy = (minY + maxY) * 0.5;
    double width = maxX - minX;
    double height = maxY - minY;
    if (width < height * 1.85) width = height * 2.0;
    if (height < width * 0.42) height = width * 0.5;
    return (ECDBox){cx - width * 0.5, cy - height * 0.5, cx + width * 0.5, cy + height * 0.5};
}

static int ECSnapshotBalls(id table, id cueBall, ECSnap *out, int maxCount, ECDPoint *cueOut, double *cueRadiusOut) {
    int count = 0;
    if (ECLooksLikeObject(cueBall)) {
        ECDPoint cue = ECReadDPoint(cueBall, @"position");
        double radius = ECReadFloat(cueBall, @"radius", NAN);
        if (ECPointValid(cue)) {
            if (cueOut) *cueOut = cue;
            if (cueRadiusOut) *cueRadiusOut = (isnan(radius) || radius < 0.01) ? 3.6 : radius;
        }
    }
    SEL byNumber = NSSelectorFromString(@"getBallByNumber:");
    if (!table || ![table respondsToSelector:byNumber]) return count;
    unsigned limit = 16;
    SEL countSel = NSSelectorFromString(@"getNumBallsOnTable");
    if ([table respondsToSelector:countSel]) {
        unsigned reported = ((unsigned (*)(id, SEL))objc_msgSend)(table, countSel);
        if (reported >= 1 && reported <= 22) limit = reported;
    }
    for (unsigned i = 0; i <= limit && count < maxCount; i++) {
        id ball = ((id (*)(id, SEL, unsigned))objc_msgSend)(table, byNumber, i);
        if (!ECLooksLikeObject(ball) || ball == cueBall) continue;
        if (![ball respondsToSelector:NSSelectorFromString(@"position")]) continue;
        if (!ECInvokeBool(ball, @"onTable", YES)) continue;
        ECDPoint pos = ECReadDPoint(ball, @"position");
        if (!ECPointValid(pos)) continue;
        double radius = ECReadFloat(ball, @"radius", cueRadiusOut && *cueRadiusOut > 0 ? (float)*cueRadiusOut : 3.6f);
        if (radius < 0.01) radius = 3.6;
        out[count].pos = pos;
        out[count].radius = radius;
        count++;
    }
    return count;
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

static void ECElasticSplit(ECDPoint inDir, ECDPoint normal, ECDPoint *objectDir, ECDPoint *leftover) {
    double transferred = inDir.x * normal.x + inDir.y * normal.y;
    if (transferred < 0) transferred = 0;
    *objectDir = ECMakePoint(normal.x * transferred, normal.y * transferred);
    *leftover = ECMakePoint(inDir.x - objectDir->x, inDir.y - objectDir->y);
}

static void ECTracePath(ECDPoint start, ECDPoint direction, ECDBox box, double radius,
                        const ECSnap *snaps, int snapCount, int ignoreIndex, NSInteger maxBounces,
                        double minT,
                        void (^emit)(ECDPoint, ECDPoint),
                        int *hitIndexOut, ECDPoint *hitPosOut, ECDPoint *hitCenterOut, ECDPoint *inDirOut) {
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
    if (minT < 1e-4) minT = 1e-4;
    for (NSInteger bounce = 0; bounce <= maxBounces; bounce++) {
        double tHit = travel;
        int kind = 0;
        ECDPoint normal = ECMakePoint(0, 0);
        int bestIndex = -1;
        ECDPoint bestCenter = ECMakePoint(0, 0);
        if (dir.x > 1e-9) {
            double t = (right - origin.x) / dir.x;
            if (t > minT && t < tHit) { tHit = t; kind = 1; normal = ECMakePoint(-1, 0); }
        } else if (dir.x < -1e-9) {
            double t = (left - origin.x) / dir.x;
            if (t > minT && t < tHit) { tHit = t; kind = 1; normal = ECMakePoint(1, 0); }
        }
        if (dir.y > 1e-9) {
            double t = (top - origin.y) / dir.y;
            if (t > minT && t < tHit) { tHit = t; kind = 1; normal = ECMakePoint(0, -1); }
        } else if (dir.y < -1e-9) {
            double t = (bottom - origin.y) / dir.y;
            if (t > minT && t < tHit) { tHit = t; kind = 1; normal = ECMakePoint(0, 1); }
        }
        for (int i = 0; i < snapCount; i++) {
            if (i == ignoreIndex) continue;
            double t = ECRayCircle(origin, dir, snaps[i].pos, radius + snaps[i].radius);
            if (t > minT && t < tHit) {
                tHit = t;
                kind = 2;
                bestIndex = i;
                bestCenter = snaps[i].pos;
            }
        }
        ECDPoint dest = ECMakePoint(origin.x + dir.x * tHit, origin.y + dir.y * tHit);
        if (emit) emit(origin, dest);
        if (kind == 2) {
            if (hitIndexOut) *hitIndexOut = bestIndex;
            if (hitPosOut) *hitPosOut = dest;
            if (hitCenterOut) *hitCenterOut = bestCenter;
            if (inDirOut) *inDirOut = dir;
            return;
        }
        if (kind != 1) return;
        if (normal.x != 0) dir.x = -dir.x;
        if (normal.y != 0) dir.y = -dir.y;
        origin = dest;
        minT = 1e-3;
    }
}

@interface EmberEightBPLineOverlay : UIView
@property (nonatomic, strong) CAShapeLayer *stroke;
@property (nonatomic, strong) CAShapeLayer *objectStroke;
@property (nonatomic, strong) CAShapeLayer *comboStroke;
@property (nonatomic, strong) CAShapeLayer *ghost;
+ (instancetype)sharedOverlay;
- (void)attachToWindow:(UIWindow *)window;
- (void)attachToGameView;
- (void)clearPaths;
- (void)updateFromCache;
@end

static CAShapeLayer *ECMakeLineLayer(UIColor *color, CGFloat width) {
    CAShapeLayer *layer = [CAShapeLayer layer];
    layer.fillColor = UIColor.clearColor.CGColor;
    layer.strokeColor = color.CGColor;
    layer.lineWidth = width;
    layer.lineCap = kCALineCapRound;
    layer.lineJoin = kCALineJoinRound;
    layer.actions = @{@"path": [NSNull null], @"hidden": [NSNull null]};
    return layer;
}

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
        overlay.layer.actions = @{@"hidden": [NSNull null]};
        CAShapeLayer *stroke = ECMakeLineLayer([UIColor colorWithWhite:1 alpha:0.96], 2.6);
        stroke.shadowColor = [UIColor colorWithRed:0.55 green:0.85 blue:1 alpha:1].CGColor;
        stroke.shadowRadius = 3;
        stroke.shadowOpacity = 0.7;
        [overlay.layer addSublayer:stroke];
        overlay.stroke = stroke;
        CAShapeLayer *objectStroke = ECMakeLineLayer([UIColor colorWithRed:1 green:0.82 blue:0.22 alpha:0.95], 2.2);
        [overlay.layer addSublayer:objectStroke];
        overlay.objectStroke = objectStroke;
        CAShapeLayer *comboStroke = ECMakeLineLayer([UIColor colorWithRed:0.25 green:0.95 blue:0.72 alpha:0.95], 2.0);
        [overlay.layer addSublayer:comboStroke];
        overlay.comboStroke = comboStroke;
        CAShapeLayer *ghost = [CAShapeLayer layer];
        ghost.fillColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
        ghost.strokeColor = [UIColor colorWithWhite:1 alpha:0.88].CGColor;
        ghost.lineWidth = 1.5;
        ghost.actions = @{@"path": [NSNull null]};
        [overlay.layer addSublayer:ghost];
        overlay.ghost = ghost;
    });
    return overlay;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return NO;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}

- (void)clearPaths {
    self.hidden = YES;
    self.stroke.path = nil;
    self.objectStroke.path = nil;
    self.comboStroke.path = nil;
    self.ghost.path = nil;
}

- (void)attachToWindow:(UIWindow *)window {
    (void)window;
    [self attachToGameView];
}

- (void)attachToGameView {
    self.userInteractionEnabled = NO;
    if (self.superview) [self removeFromSuperview];
    ECStripUIKitOverlay();
}

- (CGPoint)mapPoint:(ECDPoint)world box:(ECDBox)box {
    (void)box;
    CGPoint origin = gECCachedVisualOrigin;
    double scale = (gECVisualScale > 0.05) ? gECVisualScale : 1.0;
    if (!isfinite(origin.x) || !isfinite(origin.y)) {
        return CGPointMake(CGRectGetMidX(self.bounds) + world.x * scale,
                           CGRectGetMidY(self.bounds) - world.y * scale);
    }
    UIView *host = gECVisualCueView ?: gECRenderHost ?: ECRenderView(self.window);
    gECRenderHost = host;
    CGPoint cocos = CGPointMake(origin.x + world.x * scale, origin.y + world.y * scale);
    if (host && host != self && host != self.window) {
        CGPoint inHost = (host == gECVisualCueView)
            ? CGPointMake(origin.x + world.x * scale, origin.y - world.y * scale)
            : CGPointMake(cocos.x, host.bounds.size.height - cocos.y);
        return [self convertPoint:inHost fromView:host];
    }
    return CGPointMake(cocos.x, self.bounds.size.height - cocos.y);
}

- (CGPoint)overlayPointFromWindow:(CGPoint)ui {
    if (!isfinite(ui.x) || !isfinite(ui.y)) return CGPointMake(NAN, NAN);
    CGRect local = CGRectInset(self.bounds, -48, -48);
    if (CGRectContainsPoint(local, ui)) return ui;
    if (self.window) {
        CGPoint fromWindow = [self convertPoint:ui fromView:self.window];
        if (CGRectContainsPoint(CGRectInset(self.bounds, -80, -80), fromWindow)) return fromWindow;
    }
    UIView *gl = self.superview;
    if (gl && gl != self.window) {
        CGPoint fromGL = [self convertPoint:ui fromView:gl];
        if (CGRectContainsPoint(CGRectInset(self.bounds, -80, -80), fromGL)) return fromGL;
    }
    return ui;
}

- (void)updateFromCache {
    [self attachToGameView];
    [self clearPaths];
}

@end

@interface EmberEightBPOfflineLinesController : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIButton *button;
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) NSTimer *keepAliveTimer;
+ (instancetype)sharedController;
- (UIWindow *)guestWindow;
@end

static void ECRequestOverlayRedraw(void) {
    ECStripUIKitOverlay();
}

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
        ECStripUIKitOverlay();
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
    ECStripUIKitOverlay();
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

static void ECScheduleOverlay(void) {
    gECOverlayAllowed = YES;
    ECStripUIKitOverlay();
    ECLogLine(@"overlay-ready");
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
