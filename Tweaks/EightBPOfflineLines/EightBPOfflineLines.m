// EightBPOfflineLines.m — native guideline extension for local 8 Ball Pool.
// Active in Practice, Play Offline, and Pass and Play / hotseat. Network matches stay locked.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <math.h>
#import <string.h>
#import <stdint.h>
#import <stdlib.h>
#import "../Shared/EmberMenu.h"
#import "EightBPShadowPhysics.h"

#define EC_LINES_BUTTON_TAG 0x8B901
#define EC_LINE_OVERLAY_TAG 0x8B902

static NSString *const ECBundleIdentifier = @"com.miniclip.8ballpoolmult";
static NSString *const ECMultiplierKey = @"EmberEightBPOfflineLines.multiplier";
static NSString *const ECButtonXKey = @"EmberEightBPOfflineLines.buttonX";
static NSString *const ECButtonYKey = @"EmberEightBPOfflineLines.buttonY";
static NSString *const ECReboundsKey = @"EmberEightBPOfflineLines.rebounds";
static NSString *const ECLandingRingsKey = @"EmberEightBPOfflineLines.landingRings";

static id gECGameManager = nil;
static BOOL gECInMatch = NO;
static BOOL gECOverlayAllowed = NO;
static BOOL gECOverlayDead = NO;
static NSInteger gECMultiplier = 8;
static BOOL gECHooksInstalled = NO;
static __weak id gECActiveVisualCue = nil;
static double gECNativeAimDistance = NAN;
static double gECLastPredictedDistance = NAN;
static BOOL gECShowRebounds = YES;
static BOOL gECShowLandingRings = YES;

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
static void ECUpdatePhysicsGuideForCue(id visualCue);
static void ECCaptureNativeCueStats(void);
static void ECObserveShadowParity(void);
static void ECHideReachedLandingMarker(id ball);

typedef struct { double x, y; } ECDPoint;
typedef struct { double minX, minY, maxX, maxY; } ECDBox;
typedef struct { ECDPoint pos; double radius; } ECSnap;
typedef struct { uint8_t r, g, b; } ECccColor3B;

static BOOL ECPointValid(ECDPoint p);
static BOOL ECReadPointIvar(id object, const char *name, CGPoint *valueOut);
static ECDPoint ECNorm(ECDPoint point);
static ECDBox ECDefaultTableBox(void);

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
static void (*ECOriginalAimChangedCallback)(id, SEL, id) = NULL;
static void (*ECOriginalVisualCueSetPower)(id, SEL, const void *) = NULL;
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
static id gECLineTexture = nil;
static id gECPredictionMarkers[20];
static NSMutableArray *gECReboundSprites = nil;
static EightBPShadowPrediction gECLastShadowPrediction;
static BOOL gECHasShadowPrediction = NO;
static BOOL gECShadowShotMoving = NO;
static CFTimeInterval gECShadowArmedAt = 0;
static double gECShadowMaxPathError[EightBPShadowMaxBalls];
static unsigned int gECShadowPathSamples[EightBPShadowMaxBalls];
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
// Visual-only floor for an unpowered cue. Shot speed and collision reach still
// use the real physical distance.
#define EC_MIN_GUIDE_DISTANCE 40.0

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
// will not turn. The physics guide uses the native shot velocity and table
// friction instead, so leave the aim stats completely alone.
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
    gECActiveVisualCue = nil;
    gECNativeAimDistance = NAN;
    gECLastPredictedDistance = NAN;
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
    gECHasShadowPrediction = NO;
    gECShadowShotMoving = NO;
    memset(&gECLastShadowPrediction, 0, sizeof(gECLastShadowPrediction));
    memset(gECShadowMaxPathError, 0, sizeof(gECShadowMaxPathError));
    memset(gECShadowPathSamples, 0, sizeof(gECShadowPathSamples));
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
    gECHasShadowPrediction = NO;
    gECShadowShotMoving = NO;
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

static ECCueStats ECObserveCueStats(ECCueStats stats, NSString *label, int cueId) {
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        ECLogLine([NSString stringWithFormat:@"%@ id=%d force=%u aim=%u spin=%u time=%u",
                   label, cueId, stats.force, stats.aim, stats.spin, stats.time]);
    }
    return stats;
}

static ECCueStats ECGetCueStats(id self, SEL selector, int cueId) {
    ECCueStats stats = {0, 0, 0, 0};
    if (ECOriginalGetCueStats) stats = ECOriginalGetCueStats(self, selector, cueId);
    return ECObserveCueStats(stats, @"getCueStats", cueId);
}

static ECCueStats ECGetCueStatsWithBonus(id self, SEL selector, int cueId) {
    ECCueStats stats = {0, 0, 0, 0};
    if (ECOriginalGetCueStatsWithBonus) stats = ECOriginalGetCueStatsWithBonus(self, selector, cueId);
    return ECObserveCueStats(stats, @"getCueStatsWithBonus", cueId);
}

static void ECApplyCueStatsForShot(id self, SEL selector, int shot, int aim, int spin) {
    // Preserve the real cue stats. The old implementation replaced `aim` with
    // an out-of-range value; that made a long line but it was unrelated to the
    // shot. The native method writes the selected cue's force/aim/spin values
    // into the physics globals used by both shot execution and VisualGuide.
    if (ECOriginalApplyCueStatsForShot) ECOriginalApplyCueStatsForShot(self, selector, shot, aim, spin);
    ECCaptureNativeCueStats();
}

static void ECVisualCueSetPower(id self, SEL selector, const void *powerValue) {
    if (ECOriginalVisualCueSetPower) ECOriginalVisualCueSetPower(self, selector, powerValue);
    gECActiveVisualCue = self;
    ECUpdatePhysicsGuideForCue(self);
}

static void ECAimChangedCallback(id self, SEL selector, id event) {
    if (ECOriginalAimChangedCallback) ECOriginalAimChangedCallback(self, selector, event);
    id cue = gECActiveVisualCue;
    if (!cue) cue = ECIvarObject(self, "mVisualCue");
    if (!cue) cue = ECIvarObject(self, "_visualCue");
    if (cue) ECUpdatePhysicsGuideForCue(cue);
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

static int ECBallNumber(id ball) {
    if (!ball) return -1;
    if (ball == gECCachedCueBall) return 0;
    // Ball exposes `number` as an ivar in this build, not as an Objective-C
    // getter. Read the runtime-resolved offset instead of falling back to white.
    Ivar ivar = class_getInstanceVariable([ball class], "number");
    if (!ivar) return -1;
    unsigned int number = 0;
    memcpy(&number,
           (const uint8_t *)(__bridge const void *)ball + ivar_getOffset(ivar),
           sizeof(number));
    return number <= 15 ? (int)number : -1;
}

static ECccColor3B ECColorForBallNumber(int number) {
    // Solids and stripes share their actual cloth-visible base colour.
    switch (number == 0 ? 0 : ((number - 1) % 8) + 1) {
        case 0: return (ECccColor3B){255, 255, 255};
        case 1: return (ECccColor3B){250, 210, 35};   // yellow
        case 2: return (ECccColor3B){45, 105, 235};   // blue
        case 3: return (ECccColor3B){225, 48, 48};    // red
        case 4: return (ECccColor3B){135, 65, 185};   // purple
        case 5: return (ECccColor3B){245, 125, 28};   // orange
        case 6: return (ECccColor3B){35, 155, 75};    // green
        case 7: return (ECccColor3B){145, 35, 48};    // maroon
        case 8: return (ECccColor3B){22, 22, 24};     // black
        default: return (ECccColor3B){255, 255, 255};
    }
}

static id ECSolidLineTexture(void) {
    if (gECLineTexture) return gECLineTexture;
    Class texCls = NSClassFromString(@"CCTexture2D");
    if (!texCls) return nil;
    SEL initSel = @selector(initWithData:pixelFormat:pixelsWide:pixelsHigh:contentSize:);
    enum { width = 16, height = 4 };
    uint32_t pixels[width * height];
    for (int i = 0; i < width * height; i++) pixels[i] = 0xffffffffu;
    static const int formats[] = {1, 0, 2, 3, 6, 7, 8, 4, 5};
    for (size_t i = 0; i < sizeof(formats) / sizeof(formats[0]); i++) {
        id tex = ((id (*)(id, SEL))objc_msgSend)(texCls, @selector(alloc));
        if (![tex respondsToSelector:initSel]) break;
        tex = ((id (*)(id, SEL, const void *, int, unsigned long, unsigned long, CGSize))objc_msgSend)(
            tex, initSel, pixels, formats[i], (unsigned long)width, (unsigned long)height,
            CGSizeMake(width, height));
        if (!ECLooksLikeObject(tex)) continue;
        unsigned long bits = [tex respondsToSelector:@selector(bitsPerPixelForFormat)]
            ? ((unsigned long (*)(id, SEL))objc_msgSend)(tex, @selector(bitsPerPixelForFormat)) : 0;
        if (bits == 32) {
            gECLineTexture = tex;
            break;
        }
    }
    if (gECLineTexture && [gECLineTexture respondsToSelector:@selector(setHasPremultipliedAlpha:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(gECLineTexture,
                                                @selector(setHasPremultipliedAlpha:), YES);
    }
    return gECLineTexture;
}

static void ECClearPredictionVisuals(void) {
    for (int i = 0; i < 20; i++) {
        id marker = gECPredictionMarkers[i];
        if (marker && [marker respondsToSelector:@selector(removeFromParent)]) {
            ((void (*)(id, SEL))objc_msgSend)(marker, @selector(removeFromParent));
        }
        gECPredictionMarkers[i] = nil;
    }
    for (id sprite in gECReboundSprites.copy) {
        if ([sprite respondsToSelector:@selector(removeFromParent)]) {
            ((void (*)(id, SEL))objc_msgSend)(sprite, @selector(removeFromParent));
        }
    }
    [gECReboundSprites removeAllObjects];
    gECHasShadowPrediction = NO;
    gECShadowShotMoving = NO;
    gECShadowArmedAt = 0;
}

static void ECRemoveBallMarkers(void) {
    ECClearPredictionVisuals();
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
        if (existing && gECHiddenLog < 12) {
            gECHiddenLog++;
            ECLogLine([NSString stringWithFormat:@"ring-hidden slot=%d potted", ECSlotForBall(ball)]);
        }
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
    // Sit one step above the sphere rather than at a fixed depth. setState:
    // re-adds the sphere to the Table node at a z taken from a global counter,
    // which is well above any constant of ours, so a hardcoded z left the ring
    // buried behind the table art once the ball changed state.
    long long ringZ = 1;
    if ([sphere respondsToSelector:@selector(zOrder)]) {
        ringZ = ((long long (*)(id, SEL))objc_msgSend)(sphere, @selector(zOrder)) + 1;
    }
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
        if ([parent respondsToSelector:@selector(addChild:z:)]) {
            ((void (*)(id, SEL, id, long long))objc_msgSend)(parent, @selector(addChild:z:), marker, ringZ);
        } else if ([parent respondsToSelector:@selector(addChild:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(parent, @selector(addChild:), marker);
        }
        objc_setAssociatedObject(ball, kECMarkerKey, marker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (gECVisualLog < 4) {
            gECVisualLog++;
            ECLogLine([NSString stringWithFormat:@"cocos-marker pos=%.1f,%.1f z=%lld parent=%@ cue=%d",
                       pos.x, pos.y, ringZ, [parent class], ball == gECCachedCueBall]);
        }
    }
    // Retint every sync rather than only at creation: the cue-ball identity is
    // sometimes discovered after the rack's sprites have already been made.
    int ballNumber = ball == gECCachedCueBall ? 0 : ECBallNumber(ball);
    ECccColor3B ballColor = ECColorForBallNumber(ballNumber);
    static int colorLogCount = 0;
    if (colorLogCount < 20) {
        colorLogCount++;
        ECLogLine([NSString stringWithFormat:@"ring-color number=%d rgb=%u,%u,%u",
            ballNumber, ballColor.r, ballColor.g, ballColor.b]);
    }
    if ([marker respondsToSelector:@selector(setColor:)]) {
        ((void (*)(id, SEL, ECccColor3B))objc_msgSend)(marker,
                                                       @selector(setColor:), ballColor);
    }
    ECSetMarkerVisible(marker, YES);
    if ([marker respondsToSelector:@selector(setPosition:)]) {
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(marker, @selector(setPosition:), pos);
    }
    // ProjectedSphere is a 3D node, so its contentSize is 0x0 and cannot size
    // the ring. updateVisualBall builds the sphere position as
    //   visual = mVisualTableOrigin + physics * scale
    // with one scale for the whole table. Lock that scale once per rack, using
    // this ball's own origin. The previous code kept replacing a shared scale
    // while using whichever ball happened to update the global origin last;
    // that drove marker scales from 0.43 down to 0.06-0.10 and made the rings
    // appear to vanish and return as different balls updated.
    if (visualFresh && gECDerivedVisualScale <= 0.2) {
        ECDPoint phys = ECBallLivePosition(ball);
        CGPoint origin = CGPointMake(NAN, NAN);
        if (ECPointValid(phys) && ECReadPointIvar(ball, "mVisualTableOrigin", &origin)) {
            BOOL useX = fabs(phys.x) >= fabs(phys.y);
            double denom = useX ? phys.x : phys.y;
            double delta = useX ? (pos.x - origin.x) : (pos.y - origin.y);
            if (fabs(denom) >= 20.0) {
                double candidate = delta / denom;
                // These are the two scale constants read from updateVisualBall
                // in 56.29.2. Snap only a close live measurement to one of
                // them, then never let moving balls mutate ring size again.
                const double compactScale = 1.7007874015748;
                const double expandedScale = 3.11811023622047;
                double compactError = fabs(candidate - compactScale) / compactScale;
                double expandedError = fabs(candidate - expandedScale) / expandedScale;
                if (compactError < 0.02 || expandedError < 0.02) {
                    gECDerivedVisualScale = compactError <= expandedError ? compactScale : expandedScale;
                    ECLogLine([NSString stringWithFormat:@"ring-scale-locked %.13f measured=%.6f",
                               gECDerivedVisualScale, candidate]);
                }
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
        ((void (*)(id, SEL, id, long long))objc_msgSend)(parent, @selector(addChild:z:), marker, ringZ);
        if (gECReparentLog < 12) {
            gECReparentLog++;
            ECLogLine([NSString stringWithFormat:@"ring-reparent slot=%d from=%@ to=%@ z=%lld visible=%d",
                       slot, [markerParent class], [parent class], ringZ, ECSphereVisible(sphere)]);
        }
    } else if ([marker respondsToSelector:@selector(zOrder)] &&
               [parent respondsToSelector:@selector(reorderChild:z:)]) {
        // The sphere's z moves with its state, so follow it every frame.
        long long markerZ = ((long long (*)(id, SEL))objc_msgSend)(marker, @selector(zOrder));
        if (markerZ != ringZ) {
            ((void (*)(id, SEL, id, long long))objc_msgSend)(parent, @selector(reorderChild:z:), marker, ringZ);
            if (gECReparentLog < 12) {
                gECReparentLog++;
                ECLogLine([NSString stringWithFormat:@"ring-reorder slot=%d z=%lld->%lld parent=%@",
                           slot, markerZ, ringZ, [parent class]]);
            }
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

// Nothing in the hide paths is firing, yet rings still disappear, so dump the
// whole per-ball state once a second and let the log say what is actually
// different about the balls that lose their ring.
static void ECLogRingSnapshot(void) {
    static double last = 0;
    static int emitted = 0;
    if (emitted >= 25) return;
    double now = CFAbsoluteTimeGetCurrent();
    if (now - last < 1.0) return;
    last = now;
    emitted++;

    NSMutableArray *parts = [NSMutableArray array];
    for (int i = 0; i < gECCachedSnapCount; i++) {
        id ball = gECCachedBalls[i];
        if (!ball) continue;
        id marker = objc_getAssociatedObject(ball, kECMarkerKey);
        id sphere = ECVisualSphere(ball);
        id spParent = ECLooksLikeObject(sphere) ? ECInvokeId(sphere, @"parent") : nil;
        long long sz = 0;
        if (ECLooksLikeObject(sphere) && [sphere respondsToSelector:@selector(zOrder)]) {
            sz = ((long long (*)(id, SEL))objc_msgSend)(sphere, @selector(zOrder));
        }
        if (!ECLooksLikeObject(marker)) {
            [parts addObject:[NSString stringWithFormat:@"%d:NOMARK s(v%d z%lld %@)", i,
                              ECSphereVisible(sphere), sz,
                              spParent ? NSStringFromClass([spParent class]) : @"nil"]];
            continue;
        }
        BOOL mv = [marker respondsToSelector:@selector(visible)]
            ? ((BOOL (*)(id, SEL))objc_msgSend)(marker, @selector(visible)) : NO;
        long long mz = [marker respondsToSelector:@selector(zOrder)]
            ? ((long long (*)(id, SEL))objc_msgSend)(marker, @selector(zOrder)) : 0;
        id mParent = ECInvokeId(marker, @"parent");
        float mscale = [marker respondsToSelector:@selector(scale)]
            ? ((float (*)(id, SEL))objc_msgSend)(marker, @selector(scale)) : -1;
        [parts addObject:[NSString stringWithFormat:@"%d:m(v%d z%lld sc%.2f %@) s(v%d z%lld %@) pot%d",
                          i, mv, mz, mscale,
                          mParent ? NSStringFromClass([mParent class]) : @"nil",
                          ECSphereVisible(sphere), sz,
                          spParent ? NSStringFromClass([spParent class]) : @"nil",
                          gECPotted[i]]];
    }

    // mBallsPotted has never matched a ball, so record what it actually holds.
    NSString *pottedInfo = @"table=nil";
    if (gECCachedTable) {
        id potted = ECIvarObject(gECCachedTable, "mBallsPotted");
        if (!potted) {
            pottedInfo = @"mBallsPotted=nil";
        } else {
            id first = [potted respondsToSelector:@selector(firstObject)] ? [potted firstObject] : nil;
            pottedInfo = [NSString stringWithFormat:@"mBallsPotted=%@ n=%lu first=%@",
                          [potted class],
                          [potted respondsToSelector:@selector(count)] ? (unsigned long)[potted count] : 0,
                          first ? NSStringFromClass([first class]) : @"nil"];
        }
    }
    ECLogLine([NSString stringWithFormat:@"ring-snap %@ || %@",
               pottedInfo, [parts componentsJoinedByString:@" | "]]);
}

static void ECUpdateVisualBall(id self, SEL selector) {
    if (ECOriginalUpdateVisualBall) ECOriginalUpdateVisualBall(self, selector);
    if (!gECInMatch) return;
    @try {
        ECSyncCocosMarker(self, YES);
        ECHideReachedLandingMarker(self);
        ECLogRingSnapshot();
        ECObserveShadowParity();
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
        BOOL aimChangedOK = ECHookIMP(gameManager, NSSelectorFromString(@"aimChangedCallback:"),
                                      (IMP)ECAimChangedCallback,
                                      (IMP *)&ECOriginalAimChangedCallback);

        Class visualCue = NSClassFromString(@"VisualCue");
        Class table = NSClassFromString(@"Table");
        Class ball = NSClassFromString(@"Ball");
        BOOL powerOK = ECHookIMP(visualCue, NSSelectorFromString(@"setPower:"),
                                 (IMP)ECVisualCueSetPower, (IMP *)&ECOriginalVisualCueSetPower);
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

        gECHooksInstalled = lowOK && highOK && powerOK && applyOK;
        ECLogLine([NSString stringWithFormat:@"hook enter=%d exit=%d low=%d high=%d setLow=%d setHigh=%d stats=%d bonus=%d apply=%d power=%d aimChanged=%d gm=%@ user=%@",
                   enterOK, exitOK, lowOK, highOK, setLowOK, setHighOK,
                   statsOK, bonusOK, applyOK, powerOK, aimChangedOK, gameManager, userInfo]);
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

// 56.29.2 preferred addresses. These are not guessed rendering constants:
// applyCueStatsForShot writes the selected cue's live force/aim/spin values at
// these locations, and the real shot code reads the force value before it
// applies velocity to the cue ball. ASLR is resolved from GameManager's image.
#define EC_GAME_FORCE_ADDRESS ((uintptr_t)0x10451A7F8ULL)
#define EC_GAME_AIM_ADDRESS ((uintptr_t)0x10451A808ULL)
#define EC_VISUAL_GUIDE_REFRESH_ADDRESS ((uintptr_t)0x100185B24ULL)
#define EC_VISUAL_GUIDE_REFRESH_OPCODE ((uint32_t)0x3940C008U)
#define EC_FRICTION_SLIDING_GETTER_ADDRESS ((uintptr_t)0x100300ECCULL)
#define EC_FRICTION_ROLLING_GETTER_ADDRESS ((uintptr_t)0x100300EFCULL)
#define EC_FRICTION_GETTER_OPCODE ((uint32_t)0xD10083FFU)

static intptr_t ECGameImageSlide(void) {
    static intptr_t slide = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *gameImage = class_getImageName(NSClassFromString(@"GameManager"));
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            const char *candidate = _dyld_get_image_name(i);
            if (gameImage && candidate && strcmp(gameImage, candidate) == 0) {
                slide = _dyld_get_image_vmaddr_slide(i);
                return;
            }
        }
        if (count > 0) slide = _dyld_get_image_vmaddr_slide(0);
    });
    return slide;
}

static void *ECGameAddress(uintptr_t preferredAddress) {
    return (void *)(preferredAddress + (uintptr_t)ECGameImageSlide());
}

static BOOL ECNativePhysicsSurfaceValid(void) {
    uint32_t *refresh = ECGameAddress(EC_VISUAL_GUIDE_REFRESH_ADDRESS);
    uint32_t *slidingGetter = ECGameAddress(EC_FRICTION_SLIDING_GETTER_ADDRESS);
    uint32_t *rollingGetter = ECGameAddress(EC_FRICTION_ROLLING_GETTER_ADDRESS);
    return refresh && *refresh == EC_VISUAL_GUIDE_REFRESH_OPCODE &&
           slidingGetter && *slidingGetter == EC_FRICTION_GETTER_OPCODE &&
           rollingGetter && *rollingGetter == EC_FRICTION_GETTER_OPCODE;
}

#if defined(__arm64__)
// The game's C++ MCNumber return ABI writes the eight-byte result through x8.
// Bridge a normal C call (object/result/function in x0/x1/x2) into that ABI so
// prediction uses the same modifier-aware friction getters as Ball physics.
__attribute__((naked, noinline))
static void ECInvokeMCNumberGetter(void *object, double *result, void *function) {
    __asm__ volatile(
        "mov x8, x1\n"
        "br x2\n"
    );
}
#endif

static BOOL ECEffectiveFrictionFactors(double *friction, double *slidingOut,
                                       double *rollingOut) {
    if (!friction || !slidingOut || !rollingOut || !ECNativePhysicsSurfaceValid()) return NO;
#if defined(__arm64__)
    double sliding = NAN;
    double rolling = NAN;
    ECInvokeMCNumberGetter(friction, &sliding,
                           ECGameAddress(EC_FRICTION_SLIDING_GETTER_ADDRESS));
    ECInvokeMCNumberGetter(friction, &rolling,
                           ECGameAddress(EC_FRICTION_ROLLING_GETTER_ADDRESS));
    if (!isfinite(sliding) || sliding <= 0.0 ||
        !isfinite(rolling) || rolling <= 0.0) return NO;
    *slidingOut = sliding;
    *rollingOut = rolling;
    return YES;
#else
    return NO;
#endif
}

static BOOL ECReadDoubleIvar(id object, const char *name, double *valueOut) {
    if (!object || !name || !valueOut) return NO;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return NO;
    const char *type = ivar_getTypeEncoding(ivar) ?: "";
    if (type[0] != 'd' && !strstr(type, "MCNumber")) return NO;
    const uint8_t *bytes = (const uint8_t *)(__bridge const void *)object;
    memcpy(valueOut, bytes + ivar_getOffset(ivar), sizeof(*valueOut));
    return isfinite(*valueOut);
}

static void *ECRawPointerIvar(id object, const char *name) {
    if (!object || !name) return NULL;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return NULL;
    const uint8_t *bytes = (const uint8_t *)(__bridge const void *)object;
    void *pointer = NULL;
    memcpy(&pointer, bytes + ivar_getOffset(ivar), sizeof(pointer));
    return pointer;
}

static void ECCaptureNativeCueStats(void) {
    if (!ECNativePhysicsSurfaceValid()) return;
    double value = *(double *)ECGameAddress(EC_GAME_AIM_ADDRESS);
    // The game's 56.29.2 aim table spans roughly 10.3–23.3 world units.
    // Keep only sane values written by the original stats method, never one of
    // our prediction values from an earlier frame.
    if (isfinite(value) && value > 0.0 && value < 64.0) gECNativeAimDistance = value;
}

static double ECPhysicsStoppingDistance(double speed, const double *friction,
                                        double slidingReduction, double rollingReduction) {
    if (!friction || !isfinite(speed) || speed <= 0.0) return 0.0;

    // FrictionProperties is constructed by the game as:
    //   +0x18 timeOfequilibriumFactor
    //   +0x20 velocityReductionSlidingFactor
    //   +0x28 velocityReductionRollingFactor
    // These are the exact precomputed factors consumed by the table physics.
    double equilibriumFactor = friction[3];
    if (!isfinite(equilibriumFactor) || equilibriumFactor <= 0.0 ||
        !isfinite(slidingReduction) || slidingReduction <= 0.0 ||
        !isfinite(rollingReduction) || rollingReduction <= 0.0) return NAN;

    // A centre cue strike begins in sliding state, reaches pure roll at the
    // engine's equilibrium time, then decelerates under rolling friction.
    double slideTime = speed * equilibriumFactor;
    double rollingSpeed = fmax(0.0, speed - slidingReduction * slideTime);
    double slidingDistance = 0.5 * (speed + rollingSpeed) * slideTime;
    double rollingDistance = (rollingSpeed * rollingSpeed) / (2.0 * rollingReduction);
    return slidingDistance + rollingDistance;
}

static double ECPhysicsSpeedAfterDistance(double speed, double distance,
                                          const double *friction,
                                          double slidingReduction, double rollingReduction) {
    if (!friction || !isfinite(speed) || speed <= 0.0 ||
        !isfinite(distance) || distance < 0.0) return 0.0;

    double equilibriumFactor = friction[3];
    if (!isfinite(equilibriumFactor) || equilibriumFactor <= 0.0 ||
        !isfinite(slidingReduction) || slidingReduction <= 0.0 ||
        !isfinite(rollingReduction) || rollingReduction <= 0.0) return NAN;

    // Invert the same two phases used by ECPhysicsStoppingDistance. This gives
    // the real translational speed at the first collision instead of treating
    // pre-contact distance as an interchangeable post-contact distance budget.
    double slideTime = speed * equilibriumFactor;
    double rollingSpeed = fmax(0.0, speed - slidingReduction * slideTime);
    double slidingDistance = 0.5 * (speed + rollingSpeed) * slideTime;
    if (distance <= slidingDistance) {
        return sqrt(fmax(0.0, speed * speed - 2.0 * slidingReduction * distance));
    }
    return sqrt(fmax(0.0, rollingSpeed * rollingSpeed -
                           2.0 * rollingReduction * (distance - slidingDistance)));
}

static double ECShotSpeedForCuePower(double cuePower, double cueForce) {
    if (!isfinite(cuePower) || !isfinite(cueForce) || cueForce <= 0.0) return NAN;

    // This is the transfer function in the real 56.29.2 shot routine at
    // 0x10000c318..0x10000c328. The normalized VisualCue power is not applied
    // linearly: the engine turns it into ball velocity before setting the
    // cue-ball velocity vector. Using cuePower * cueForce makes weak pulls
    // nearly twice as fast as the shot the game will actually take.
    double normalizedPower = fmin(1.0, fmax(0.0, cuePower));
    return cueForce * (1.0 - sqrt(1.0 - normalizedPower));
}

static BOOL ECTrimNativeGuideToStoppingDistance(void *guide, double stoppingDistance,
                                                double displayDistance,
                                                double *nativeHitDistanceOut) {
    if (!guide || !isfinite(stoppingDistance) || stoppingDistance < 0.0 ||
        !isfinite(displayDistance) || displayDistance < stoppingDistance) return NO;

    // VisualGuide 56.29.2 stores the distance returned by Table's native
    // collision raycast at +0x48 and the corresponding rendered start/end
    // points at +0xb0/+0xc0.  Both pairs describe the same world-space ray;
    // converting by their ratio preserves the game's own table/camera scale.
    uint8_t *bytes = (uint8_t *)guide;
    if (bytes[0x98] != 1) return NO;

    double hitDistance = NAN;
    ECDPoint start = {NAN, NAN};
    ECDPoint end = {NAN, NAN};
    memcpy(&hitDistance, bytes + 0x48, sizeof(hitDistance));
    memcpy(&start, bytes + 0xb0, sizeof(start));
    memcpy(&end, bytes + 0xc0, sizeof(end));
    if (nativeHitDistanceOut) *nativeHitDistanceOut = hitDistance;
    if (!isfinite(hitDistance) || hitDistance <= 0.0 ||
        !ECPointValid(start) || !ECPointValid(end) ||
        stoppingDistance >= hitDistance) return NO;

    // The minimum affects only what is visible. Collision branches remain
    // suppressed until the real shot distance can reach the contact.
    double visibleDistance = fmin(hitDistance, displayDistance);
    double fraction = fmax(0.0, fmin(1.0, visibleDistance / hitDistance));
    ECDPoint physicalEnd = {
        start.x + (end.x - start.x) * fraction,
        start.y + (end.y - start.y) * fraction,
    };
    memcpy(bytes + 0xc0, &physicalEnd, sizeof(physicalEnd));
    memcpy(bytes + 0x48, &visibleDistance, sizeof(visibleDistance));

    // The collision lies beyond the cue ball's physical stopping point, so
    // suppress the native collision marker and outgoing ball/cue paths while
    // retaining the primary segment (the +0x98 valid-path flag).
    bytes[0x32] = 0;
    bytes[0x33] = 0;
    bytes[0x99] = 0;
    bytes[0x9a] = 0;
    return YES;
}

typedef struct {
    double transfer[2];
    double distance[2];
    double nativeWorldLength[2];
    BOOL applied;
} ECCollisionGuideResult;

static ECCollisionGuideResult ECScaleCollisionGuidePathsToPhysics(
    void *guide, double initialSpeed, double hitDistance, const double *friction,
    double slidingReduction, double rollingReduction) {
    ECCollisionGuideResult result = {
        .transfer = {NAN, NAN},
        .distance = {NAN, NAN},
        .nativeWorldLength = {NAN, NAN},
        .applied = NO,
    };
    if (!guide || !friction || !isfinite(hitDistance) || hitDistance < 0.0) return result;

    uint8_t *bytes = (uint8_t *)guide;
    if (bytes[0x98] != 1 || bytes[0x9a] != 1) return result;

    // refresh() runs the game's own collision response on its two temporary
    // balls. It leaves the resulting translational speed magnitudes here.
    // Their normalized ratio is the exact velocity transfer for this contact
    // angle (including the game's collision implementation), independent of
    // the arbitrary native aim-stat length used to draw the paths.
    double nativeOutgoingSpeed[2] = {NAN, NAN};
    memcpy(&nativeOutgoingSpeed[0], bytes + 0x690, sizeof(double));
    memcpy(&nativeOutgoingSpeed[1], bytes + 0x6a8, sizeof(double));
    double nativeInputSpeed = hypot(nativeOutgoingSpeed[0], nativeOutgoingSpeed[1]);
    if (!isfinite(nativeInputSpeed) || nativeInputSpeed <= 1e-8 ||
        !isfinite(nativeOutgoingSpeed[0]) || nativeOutgoingSpeed[0] < 0.0 ||
        !isfinite(nativeOutgoingSpeed[1]) || nativeOutgoingSpeed[1] < 0.0) return result;

    uint8_t *active = NULL;
    memcpy(&active, bytes + 0x218, sizeof(active));
    if (active != bytes + 0x118 && active != bytes + 0x158 &&
        active != bytes + 0x198 && active != bytes + 0x1d8) return result;

    ECDPoint primaryStart = {NAN, NAN};
    ECDPoint primaryEnd = {NAN, NAN};
    memcpy(&primaryStart, bytes + 0xb0, sizeof(primaryStart));
    memcpy(&primaryEnd, bytes + 0xc0, sizeof(primaryEnd));
    double primaryRenderedLength = hypot(primaryEnd.x - primaryStart.x,
                                         primaryEnd.y - primaryStart.y);
    if (!ECPointValid(primaryStart) || !ECPointValid(primaryEnd) ||
        !isfinite(primaryRenderedLength) || primaryRenderedLength <= 1e-8 ||
        hitDistance <= 1e-8) return result;
    double renderUnitsPerWorldUnit = primaryRenderedLength / hitDistance;

    double impactSpeed = ECPhysicsSpeedAfterDistance(
        initialSpeed, hitDistance, friction, slidingReduction, rollingReduction);
    if (!isfinite(impactSpeed) || impactSpeed <= 0.0) return result;

    for (int path = 0; path < 2; path++) {
        result.transfer[path] = fmax(0.0, fmin(1.0,
            nativeOutgoingSpeed[path] / nativeInputSpeed));
        double outgoingSpeed = impactSpeed * result.transfer[path];
        result.distance[path] = ECPhysicsStoppingDistance(
            outgoingSpeed, friction, slidingReduction, rollingReduction);

        size_t pointOffset = (size_t)path * 0x20;
        ECDPoint start = {NAN, NAN};
        ECDPoint end = {NAN, NAN};
        memcpy(&start, active + pointOffset, sizeof(start));
        memcpy(&end, active + pointOffset + 0x10, sizeof(end));
        if (!ECPointValid(start) || !ECPointValid(end)) continue;

        double dx = end.x - start.x;
        double dy = end.y - start.y;
        double renderedLength = hypot(dx, dy);
        if (!isfinite(renderedLength) || renderedLength <= 1e-8) continue;
        result.nativeWorldLength[path] = renderedLength / renderUnitsPerWorldUnit;

        // Preserve a nearer native cushion/ball intersection. Only shorten a
        // branch when its own physical stopping distance occurs first.
        double physicalRenderedLength = result.distance[path] * renderUnitsPerWorldUnit;
        if (!isfinite(physicalRenderedLength) || physicalRenderedLength >= renderedLength) continue;
        double fraction = fmax(0.0, physicalRenderedLength / renderedLength);
        ECDPoint physicalEnd = {start.x + dx * fraction, start.y + dy * fraction};
        memcpy(active + pointOffset + 0x10, &physicalEnd, sizeof(physicalEnd));
        result.applied = YES;
    }
    return result;
}

#define EC_SIM_MAX_BALLS 20
#define EC_SIM_MAX_POINTS 24

typedef struct {
    id source;
    int number;
    ECDPoint start;
    ECDPoint pos;
    ECDPoint velocity;
    double radius;
    double slidingTime;
    BOOL active;
    BOOL moved;
    BOOL hasRebounded;
    int pointCount;
    ECDPoint points[EC_SIM_MAX_POINTS];
} ECSimBall;

typedef struct { ECDPoint origin; ECDPoint size; } ECRawTableRect;
typedef struct { const ECDPoint *begin, *end, *capacity; } ECPointVector;
typedef struct { int16_t first, second; } ECShortPair;
typedef struct { const ECShortPair *begin, *end, *capacity; } ECShortPairVector;
typedef struct {
    ECDPoint start;
    ECDPoint end;
    ECDPoint inward;
} ECSimCushion;

#define EC_SIM_MAX_CUSHIONS 64

static BOOL ECReadNativeTableBox(id table, ECDBox *boxOut) {
    if (!table || !boxOut) return NO;
    SEL selector = @selector(tableBounds);
    Method method = class_getInstanceMethod([table class], selector);
    if (!method) return NO;
    ECRawTableRect (*implementation)(id, SEL) =
        (ECRawTableRect (*)(id, SEL))method_getImplementation(method);
    if (!implementation) return NO;
    ECRawTableRect rect = implementation(table, selector);
    if (!ECPointValid(rect.origin) || !ECPointValid(rect.size) ||
        rect.size.x < 100.0 || rect.size.y < 40.0 ||
        rect.size.x > 1000.0 || rect.size.y > 1000.0) return NO;
    *boxOut = (ECDBox){rect.origin.x, rect.origin.y,
                      rect.origin.x + rect.size.x, rect.origin.y + rect.size.y};
    return YES;
}

static BOOL ECSimBallInPocket(id table, ECSimBall *ball) {
    if (!table || !ball || !ball->source) return NO;
    SEL selector = NSSelectorFromString(@"isBallOverlappingAnyPocket:position:");
    if (![table respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL, id, ECDPoint))objc_msgSend)(
        table, selector, ball->source, ball->pos);
}

static int ECSnapshotNativeCushions(id table, ECDBox bounds,
                                    ECSimCushion *segments, int capacity) {
    if (!table || !segments || capacity <= 0) return 0;
    Ivar shapeIvar = class_getInstanceVariable([table class], "mTableShape");
    if (!shapeIvar) return 0;
    const uint8_t *tableBytes = (const uint8_t *)(__bridge const void *)table;
    const ECPointVector *shape = (const ECPointVector *)(tableBytes + ivar_getOffset(shapeIvar));
    if (!shape->begin || !shape->end || shape->end < shape->begin) return 0;
    ptrdiff_t pointCount = shape->end - shape->begin;
    if (pointCount < 4 || pointCount > 256) return 0;

    id cushions = nil;
    if ([table respondsToSelector:@selector(getActiveCushions)]) {
        cushions = ((id (*)(id, SEL))objc_msgSend)(table, @selector(getActiveCushions));
    }
    if (![cushions isKindOfClass:NSArray.class]) {
        cushions = ECIvarObject(table, "_tableCushions");
    }
    if (![cushions isKindOfClass:NSArray.class]) return 0;

    ECDPoint center = {(bounds.minX + bounds.maxX) * 0.5,
                       (bounds.minY + bounds.maxY) * 0.5};
    int count = 0;
    for (id cushion in (NSArray *)cushions) {
        if (count >= capacity || !ECLooksLikeObject(cushion)) break;
        if ([cushion respondsToSelector:@selector(cushionActive)] &&
            !((BOOL (*)(id, SEL))objc_msgSend)(cushion, @selector(cushionActive))) continue;
        Ivar linesIvar = class_getInstanceVariable([cushion class], "_cushionLines");
        if (!linesIvar) continue;
        const uint8_t *cushionBytes = (const uint8_t *)(__bridge const void *)cushion;
        const ECShortPairVector *lines =
            (const ECShortPairVector *)(cushionBytes + ivar_getOffset(linesIvar));
        if (!lines->begin || !lines->end || lines->end < lines->begin) continue;
        ptrdiff_t lineCount = lines->end - lines->begin;
        if (lineCount < 0 || lineCount > 64) continue;
        for (ptrdiff_t index = 0; index < lineCount && count < capacity; index++) {
            int first = lines->begin[index].first;
            int second = lines->begin[index].second;
            if (first < 0 || second < 0 || first >= pointCount || second >= pointCount ||
                first == second) continue;
            ECDPoint start = shape->begin[first];
            ECDPoint end = shape->begin[second];
            if (!ECPointValid(start) || !ECPointValid(end)) continue;
            double dx = end.x - start.x;
            double dy = end.y - start.y;
            double length = hypot(dx, dy);
            if (length < 0.1 || length > 1000.0) continue;
            ECDPoint inward = {-dy / length, dx / length};
            ECDPoint midpoint = {(start.x + end.x) * 0.5, (start.y + end.y) * 0.5};
            if ((center.x - midpoint.x) * inward.x +
                (center.y - midpoint.y) * inward.y < 0.0) {
                inward.x = -inward.x;
                inward.y = -inward.y;
            }
            segments[count++] = (ECSimCushion){
                .start = start, .end = end, .inward = inward,
            };
        }
    }
    return count;
}

static BOOL ECResolveNativeCushion(ECSimBall *ball,
                                   const ECSimCushion *segments, int count) {
    if (!ball || !segments || count <= 0) return NO;
    int best = -1;
    double bestPenetration = 0.0;
    ECDPoint bestNormal = {0.0, 0.0};
    for (int index = 0; index < count; index++) {
        ECDPoint start = segments[index].start;
        ECDPoint end = segments[index].end;
        double sx = end.x - start.x;
        double sy = end.y - start.y;
        double lengthSquared = sx * sx + sy * sy;
        if (lengthSquared <= 1e-8) continue;
        double projection = ((ball->pos.x - start.x) * sx +
                             (ball->pos.y - start.y) * sy) / lengthSquared;
        projection = fmax(0.0, fmin(1.0, projection));
        ECDPoint nearest = {start.x + sx * projection, start.y + sy * projection};
        double dx = ball->pos.x - nearest.x;
        double dy = ball->pos.y - nearest.y;
        double distance = hypot(dx, dy);
        if (!isfinite(distance) || distance >= ball->radius) continue;

        ECDPoint normal = distance > 1e-6
            ? (ECDPoint){dx / distance, dy / distance}
            : segments[index].inward;
        if (normal.x * segments[index].inward.x +
            normal.y * segments[index].inward.y < 0.0) {
            normal = segments[index].inward;
        }
        double towardCushion = ball->velocity.x * normal.x +
                               ball->velocity.y * normal.y;
        if (towardCushion >= 0.0) continue;
        double penetration = ball->radius - distance;
        if (penetration > bestPenetration) {
            best = index;
            bestPenetration = penetration;
            bestNormal = normal;
        }
    }
    if (best < 0) return NO;
    ball->pos.x += bestNormal.x * bestPenetration;
    ball->pos.y += bestNormal.y * bestPenetration;
    double normalVelocity = ball->velocity.x * bestNormal.x +
                            ball->velocity.y * bestNormal.y;
    ball->velocity.x -= 2.0 * normalVelocity * bestNormal.x;
    ball->velocity.y -= 2.0 * normalVelocity * bestNormal.y;
    return YES;
}

static void ECRecordSimPoint(ECSimBall *ball, ECDPoint point) {
    if (!ball || !ECPointValid(point) || ball->pointCount >= EC_SIM_MAX_POINTS) return;
    if (ball->pointCount > 0) {
        ECDPoint previous = ball->points[ball->pointCount - 1];
        if (hypot(point.x - previous.x, point.y - previous.y) < 0.2) return;
    }
    ball->points[ball->pointCount++] = point;
}

static int ECSnapshotSimulationBalls(ECSimBall *balls, int capacity) {
    if (!balls || capacity <= 0) return 0;
    int count = 0;
    for (int i = 0; i < gECCachedSnapCount && count < capacity; i++) {
        id ball = gECCachedBalls[i];
        if (!ECLooksLikeObject(ball) || ECBallIsPotted(ball)) continue;
        ECDPoint position = ECBallLivePosition(ball);
        double radius = ECBallLiveRadius(ball);
        if (!ECPointValid(position) || radius <= 0.0) continue;
        balls[count] = (ECSimBall){
            .source = ball,
            .number = ball == gECCachedCueBall ? 0 : ECBallNumber(ball),
            .start = position,
            .pos = position,
            .velocity = {0.0, 0.0},
            .radius = radius,
            .slidingTime = 0.0,
            .active = YES,
        };
        count++;
    }
    return count;
}

static CGPoint ECVisualPointForWorld(ECDPoint world, id referenceBall) {
    CGPoint origin = gECCachedVisualOrigin;
    CGPoint ownOrigin = CGPointMake(NAN, NAN);
    if (referenceBall && ECReadPointIvar(referenceBall, "mVisualTableOrigin", &ownOrigin)) {
        origin = ownOrigin;
    }
    double scale = gECDerivedVisualScale > 0.2 ? gECDerivedVisualScale : 1.7007874015748;
    return CGPointMake(origin.x + world.x * scale, origin.y + world.y * scale);
}

static id ECPredictionParent(void) {
    id sphere = ECVisualSphere(gECCachedCueBall);
    id parent = ECLooksLikeObject(sphere) ? ECInvokeId(sphere, @"parent") : nil;
    return ECLooksLikeObject(parent) ? parent : gECCachedTable;
}

static long long ECPredictionZ(void) {
    id sphere = ECVisualSphere(gECCachedCueBall);
    if (ECLooksLikeObject(sphere) && [sphere respondsToSelector:@selector(zOrder)]) {
        return ((long long (*)(id, SEL))objc_msgSend)(sphere, @selector(zOrder)) + 2;
    }
    return 2;
}

static void ECResetReboundSprites(void) {
    if (!gECReboundSprites) gECReboundSprites = [NSMutableArray array];
    for (id sprite in gECReboundSprites.copy) {
        if ([sprite respondsToSelector:@selector(removeFromParent)]) {
            ((void (*)(id, SEL))objc_msgSend)(sprite, @selector(removeFromParent));
        }
    }
    [gECReboundSprites removeAllObjects];
}

static void ECAddReboundSprite(id parent, ECDPoint from, ECDPoint to,
                               ECccColor3B color, id referenceBall, long long z) {
    if (!parent || !ECPointValid(from) || !ECPointValid(to)) return;
    CGPoint start = ECVisualPointForWorld(from, referenceBall);
    CGPoint end = ECVisualPointForWorld(to, referenceBall);
    double dx = end.x - start.x;
    double dy = end.y - start.y;
    double length = hypot(dx, dy);
    if (!isfinite(length) || length < 1.0) return;
    id texture = ECSolidLineTexture();
    Class spriteClass = NSClassFromString(@"CCSprite");
    if (!texture || !spriteClass) return;
    id sprite = ((id (*)(id, SEL))objc_msgSend)(spriteClass, @selector(alloc));
    sprite = ((id (*)(id, SEL, id))objc_msgSend)(sprite, @selector(initWithTexture:), texture);
    if (!ECLooksLikeObject(sprite)) return;
    CGSize size = [sprite respondsToSelector:@selector(contentSize)]
        ? ((CGSize (*)(id, SEL))objc_msgSend)(sprite, @selector(contentSize)) : CGSizeMake(1, 1);
    if ([sprite respondsToSelector:@selector(setAnchorPoint:)]) {
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(sprite, @selector(setAnchorPoint:), CGPointMake(0, 0.5));
    }
    if ([sprite respondsToSelector:@selector(setPosition:)]) {
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(sprite, @selector(setPosition:), start);
    }
    if ([sprite respondsToSelector:@selector(setRotation:)]) {
        float degrees = (float)(-atan2(dy, dx) * 180.0 / M_PI);
        ((void (*)(id, SEL, float))objc_msgSend)(sprite, @selector(setRotation:), degrees);
    }
    if ([sprite respondsToSelector:@selector(setScaleX:)]) {
        ((void (*)(id, SEL, float))objc_msgSend)(sprite, @selector(setScaleX:),
                                                 (float)(length / MAX(1.0, size.width)));
    }
    if ([sprite respondsToSelector:@selector(setScaleY:)]) {
        ((void (*)(id, SEL, float))objc_msgSend)(sprite, @selector(setScaleY:),
                                                 (float)(1.6 / MAX(1.0, size.height)));
    }
    if ([sprite respondsToSelector:@selector(setColor:)]) {
        ((void (*)(id, SEL, ECccColor3B))objc_msgSend)(sprite, @selector(setColor:), color);
    }
    if ([sprite respondsToSelector:@selector(setOpacity:)]) {
        ((void (*)(id, SEL, unsigned char))objc_msgSend)(sprite, @selector(setOpacity:), 190);
    }
    if ([parent respondsToSelector:@selector(addChild:z:)]) {
        ((void (*)(id, SEL, id, long long))objc_msgSend)(parent, @selector(addChild:z:), sprite, z);
    } else if ([parent respondsToSelector:@selector(addChild:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(parent, @selector(addChild:), sprite);
    }
    [gECReboundSprites addObject:sprite];
}

static void ECSyncLandingMarker(int index, id parent, ECSimBall *ball,
                                id referenceBall, long long z) {
    if (index < 0 || index >= 20 || !ball) return;
    id marker = gECPredictionMarkers[index];
    if (!gECShowLandingRings || !ball->active || !ball->moved) {
        ECSetMarkerVisible(marker, NO);
        return;
    }
    if (!ECLooksLikeObject(marker)) {
        id texture = ECCircleTexture();
        Class spriteClass = NSClassFromString(@"CCSprite");
        if (!texture || !spriteClass) return;
        marker = ((id (*)(id, SEL))objc_msgSend)(spriteClass, @selector(alloc));
        marker = ((id (*)(id, SEL, id))objc_msgSend)(marker, @selector(initWithTexture:), texture);
        if (!ECLooksLikeObject(marker)) return;
        if ([marker respondsToSelector:@selector(setOpacity:)]) {
            ((void (*)(id, SEL, unsigned char))objc_msgSend)(marker, @selector(setOpacity:), 150);
        }
        if ([parent respondsToSelector:@selector(addChild:z:)]) {
            ((void (*)(id, SEL, id, long long))objc_msgSend)(parent, @selector(addChild:z:), marker, z);
        } else if ([parent respondsToSelector:@selector(addChild:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(parent, @selector(addChild:), marker);
        }
        gECPredictionMarkers[index] = marker;
    }
    id markerParent = ECInvokeId(marker, @"parent");
    if (markerParent != parent && [parent respondsToSelector:@selector(addChild:z:)]) {
        if ([marker respondsToSelector:@selector(removeFromParent)]) {
            ((void (*)(id, SEL))objc_msgSend)(marker, @selector(removeFromParent));
        }
        ((void (*)(id, SEL, id, long long))objc_msgSend)(parent, @selector(addChild:z:), marker, z);
    }
    ECccColor3B color = ECColorForBallNumber(ball->number);
    if ([marker respondsToSelector:@selector(setColor:)]) {
        ((void (*)(id, SEL, ECccColor3B))objc_msgSend)(marker, @selector(setColor:), color);
    }
    if ([marker respondsToSelector:@selector(setPosition:)]) {
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(marker, @selector(setPosition:),
                                                   ECVisualPointForWorld(ball->pos, referenceBall));
    }
    CGSize size = [marker respondsToSelector:@selector(contentSize)]
        ? ((CGSize (*)(id, SEL))objc_msgSend)(marker, @selector(contentSize)) : CGSizeZero;
    double visualScale = gECDerivedVisualScale > 0.2 ? gECDerivedVisualScale : 1.7007874015748;
    double wanted = ball->radius * visualScale * 2.0 * EC_RING_PADDING / EC_RING_OUTER_FRACTION;
    if (size.width > 1.0 && [marker respondsToSelector:@selector(setScale:)]) {
        ((void (*)(id, SEL, float))objc_msgSend)(marker, @selector(setScale:),
                                                 (float)(wanted / size.width));
    }
    ECSetMarkerVisible(marker, YES);
}

static void ECShadowLogCallback(const char *message, void *context) {
    (void)context;
    if (!message || !message[0]) return;
    ECLogLine([NSString stringWithFormat:@"shadow %s", message]);
}

static void ECRenderShadowPrediction(const EightBPShadowPrediction *prediction) {
    if (!prediction || !prediction->valid) {
        ECClearPredictionVisuals();
        return;
    }

    gECLastShadowPrediction = *prediction;
    gECHasShadowPrediction = YES;
    gECShadowArmedAt = CACurrentMediaTime();
    if (!gECShadowShotMoving) {
        memset(gECShadowMaxPathError, 0, sizeof(gECShadowMaxPathError));
        memset(gECShadowPathSamples, 0, sizeof(gECShadowPathSamples));
    }

    BOOL usedMarkers[20] = {NO};
    ECResetReboundSprites();
    for (int index = 0;
         index < prediction->ballCount && index < EightBPShadowMaxBalls;
         index++) {
        const EightBPShadowBallPrediction *source = &prediction->balls[index];
        if (!source->valid || !source->liveBall) continue;

        id ball = nil;
        int slot = -1;
        for (int cached = 0; cached < gECCachedSnapCount; cached++) {
            if ((__bridge const void *)gECCachedBalls[cached] == source->liveBall) {
                ball = gECCachedBalls[cached];
                slot = cached;
                break;
            }
        }
        if (!ball || slot < 0 || slot >= 20) continue;
        usedMarkers[slot] = YES;

        ECDPoint start = source->pathPointCount > 0
            ? (ECDPoint){source->path[0].x, source->path[0].y}
            : ECBallLivePosition(ball);
        BOOL moved = hypot(source->finalPosition.x - start.x,
                           source->finalPosition.y - start.y) > 0.25;
        if (source->potted || !gECShowLandingRings || !moved) {
            ECSetMarkerVisible(gECPredictionMarkers[slot], NO);
        } else {
            id sphere = ECVisualSphere(ball);
            id parent = ECLooksLikeObject(sphere) ? ECInvokeId(sphere, @"parent") : nil;
            if (ECLooksLikeObject(parent)) {
                long long z = 2;
                if ([sphere respondsToSelector:@selector(zOrder)]) {
                    z = ((long long (*)(id, SEL))objc_msgSend)(
                        sphere, @selector(zOrder)) + 2;
                }
                ECSimBall landing = {
                    .source = ball,
                    .number = (int)source->number,
                    .pos = {source->finalPosition.x, source->finalPosition.y},
                    .radius = ECBallLiveRadius(ball),
                    .active = YES,
                    .moved = YES,
                };
                ECSyncLandingMarker(slot, parent, &landing, ball, z);
            }
        }

        if (!gECShowRebounds || source->pathPointCount < 2) continue;
        id sphere = ECVisualSphere(ball);
        id parent = ECLooksLikeObject(sphere) ? ECInvokeId(sphere, @"parent") : nil;
        if (!ECLooksLikeObject(parent)) continue;
        long long z = 2;
        if ([sphere respondsToSelector:@selector(zOrder)]) {
            z = ((long long (*)(id, SEL))objc_msgSend)(
                sphere, @selector(zOrder)) + 2;
        }
        ECccColor3B color = ECColorForBallNumber((int)source->number);
        for (int point = 1;
             point < source->pathPointCount && point < EightBPShadowMaxPathPoints;
             point++) {
            ECDPoint from = {source->path[point - 1].x, source->path[point - 1].y};
            ECDPoint to = {source->path[point].x, source->path[point].y};
            ECAddReboundSprite(parent, from, to, color, ball, z);
        }
    }
    for (int slot = 0; slot < 20; slot++) {
        if (!usedMarkers[slot]) ECSetMarkerVisible(gECPredictionMarkers[slot], NO);
    }
}

static double ECDistanceToShadowPath(ECDPoint point,
                                     const EightBPShadowBallPrediction *prediction) {
    if (!prediction || prediction->pathPointCount == 0) return INFINITY;
    double best = INFINITY;
    for (int index = 0; index < prediction->pathPointCount; index++) {
        ECDPoint a = {prediction->path[index].x, prediction->path[index].y};
        if (!ECPointValid(a)) continue;
        if (index == 0) {
            best = fmin(best, hypot(point.x - a.x, point.y - a.y));
            continue;
        }
        ECDPoint b = a;
        a = (ECDPoint){prediction->path[index - 1].x,
                       prediction->path[index - 1].y};
        double dx = b.x - a.x;
        double dy = b.y - a.y;
        double lengthSquared = dx * dx + dy * dy;
        double fraction = lengthSquared > 1e-12
            ? ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
            : 0.0;
        fraction = fmax(0.0, fmin(1.0, fraction));
        ECDPoint nearest = {a.x + dx * fraction, a.y + dy * fraction};
        best = fmin(best, hypot(point.x - nearest.x, point.y - nearest.y));
    }
    return best;
}

static void ECHideReachedLandingMarker(id ball) {
    if (!ball || !gECHasShadowPrediction || !gECLastShadowPrediction.valid) return;
    int slot = -1;
    for (int cached = 0; cached < gECCachedSnapCount; cached++) {
        if (gECCachedBalls[cached] == ball) {
            slot = cached;
            break;
        }
    }
    if (slot < 0 || slot >= 20 || !gECPredictionMarkers[slot]) return;

    const EightBPShadowBallPrediction *prediction = NULL;
    for (int index = 0;
         index < gECLastShadowPrediction.ballCount && index < EightBPShadowMaxBalls;
         index++) {
        const EightBPShadowBallPrediction *candidate = &gECLastShadowPrediction.balls[index];
        if (candidate->valid && candidate->liveBall == (__bridge const void *)ball) {
            prediction = candidate;
            break;
        }
    }
    if (!prediction || prediction->potted) {
        ECSetMarkerVisible(gECPredictionMarkers[slot], NO);
        return;
    }
    ECDPoint actual = ECBallLivePosition(ball);
    if (!ECPointValid(actual)) return;
    double radius = ECBallLiveRadius(ball);
    double hitRadius = fmax(0.35, radius * 0.85);
    if (hypot(actual.x - prediction->finalPosition.x,
              actual.y - prediction->finalPosition.y) <= hitRadius) {
        ECSetMarkerVisible(gECPredictionMarkers[slot], NO);
    }
}

static void ECObserveShadowParity(void) {
    if (!gECHasShadowPrediction || !gECLastShadowPrediction.valid) return;
    static CFTimeInterval lastObservation = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastObservation < (1.0 / 60.0)) return;
    lastObservation = now;
    BOOL anyMoving = NO;
    for (int index = 0;
         index < gECLastShadowPrediction.ballCount &&
         index < EightBPShadowMaxBalls;
         index++) {
        const EightBPShadowBallPrediction *prediction =
            &gECLastShadowPrediction.balls[index];
        if (!prediction->valid || !prediction->liveBall) continue;
        id ball = nil;
        for (int slot = 0; slot < gECCachedSnapCount; slot++) {
            if ((__bridge const void *)gECCachedBalls[slot] == prediction->liveBall) {
                ball = gECCachedBalls[slot];
                break;
            }
        }
        if (!ball) continue;
        BOOL moving = [ball respondsToSelector:@selector(isMovingOrSpinning)] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(ball, @selector(isMovingOrSpinning));
        anyMoving = anyMoving || moving;
        if (moving) {
            ECDPoint position = ECBallLivePosition(ball);
            double pathError = ECDistanceToShadowPath(position, prediction);
            if (isfinite(pathError)) {
                gECShadowMaxPathError[index] =
                    fmax(gECShadowMaxPathError[index], pathError);
                gECShadowPathSamples[index]++;
            }
        }
    }
    if (anyMoving) {
        gECShadowShotMoving = YES;
        return;
    }
    if (!gECShadowShotMoving) return;

    for (int index = 0;
         index < gECLastShadowPrediction.ballCount &&
         index < EightBPShadowMaxBalls;
         index++) {
        const EightBPShadowBallPrediction *prediction =
            &gECLastShadowPrediction.balls[index];
        if (!prediction->valid || !prediction->liveBall) continue;
        id ball = nil;
        for (int slot = 0; slot < gECCachedSnapCount; slot++) {
            if ((__bridge const void *)gECCachedBalls[slot] == prediction->liveBall) {
                ball = gECCachedBalls[slot];
                break;
            }
        }
        if (!ball) continue;
        ECDPoint actual = ECBallLivePosition(ball);
        double finalError = prediction->potted || !ECPointValid(actual)
            ? NAN : hypot(actual.x - prediction->finalPosition.x,
                          actual.y - prediction->finalPosition.y);
        ECLogLine([NSString stringWithFormat:
            @"shadow-parity ball=%u predictedPotted=%d actualPotted=%d finalError=%.5f pathMax=%.5f samples=%u",
            prediction->number, prediction->potted, ECBallIsPotted(ball),
            finalError, gECShadowMaxPathError[index],
            gECShadowPathSamples[index]]);
    }
    gECShadowShotMoving = NO;
    gECHasShadowPrediction = NO;
    ECClearPredictionVisuals();
}

#if 0
static void ECSyncNativeObjectLandingRing(void *guide, BOOL collisionReachable) {
    id marker = gECPredictionMarkers[0];
    if (!guide || !collisionReachable || !gECShowLandingRings) {
        ECSetMarkerVisible(marker, NO);
        return;
    }

    uint8_t *bytes = (uint8_t *)guide;
    if (bytes[0x98] != 1 || bytes[0x9a] != 1) {
        ECSetMarkerVisible(marker, NO);
        return;
    }
    uint8_t *active = NULL;
    memcpy(&active, bytes + 0x218, sizeof(active));
    if (active != bytes + 0x118 && active != bytes + 0x158 &&
        active != bytes + 0x198 && active != bytes + 0x1d8) {
        ECSetMarkerVisible(marker, NO);
        return;
    }

    // The native guide owns two outgoing branches. Match each branch's start
    // against the exact rendered object-ball positions; this identifies the
    // struck ball without guessing which temporary-ball slot is the object.
    id targetBall = nil;
    ECDPoint targetEnd = {NAN, NAN};
    double bestDistance = INFINITY;
    for (int path = 0; path < 2; path++) {
        ECDPoint start = {NAN, NAN};
        ECDPoint end = {NAN, NAN};
        size_t offset = (size_t)path * 0x20;
        memcpy(&start, active + offset, sizeof(start));
        memcpy(&end, active + offset + 0x10, sizeof(end));
        if (!ECPointValid(start) || !ECPointValid(end)) continue;
        for (int slot = 0; slot < gECCachedSnapCount; slot++) {
            id ball = gECCachedBalls[slot];
            if (!ball || ball == gECCachedCueBall || ECBallIsPotted(ball)) continue;
            id sphere = ECVisualSphere(ball);
            if (!ECLooksLikeObject(sphere) ||
                ![sphere respondsToSelector:@selector(position)]) continue;
            CGPoint position =
                ((CGPoint (*)(id, SEL))objc_msgSend)(sphere, @selector(position));
            double distance = hypot(start.x - position.x, start.y - position.y);
            if (distance < bestDistance) {
                bestDistance = distance;
                targetBall = ball;
                targetEnd = end;
            }
        }
    }
    if (!targetBall || !ECPointValid(targetEnd) || bestDistance > 30.0) {
        ECSetMarkerVisible(marker, NO);
        return;
    }

    CGPoint origin = CGPointMake(NAN, NAN);
    if (!ECReadPointIvar(targetBall, "mVisualTableOrigin", &origin)) {
        ECSetMarkerVisible(marker, NO);
        return;
    }
    double visualScale =
        gECDerivedVisualScale > 0.2 ? gECDerivedVisualScale : 1.7007874015748;
    ECSimBall landing = {
        .source = targetBall,
        .number = ECBallNumber(targetBall),
        .pos = {(targetEnd.x - origin.x) / visualScale,
                (targetEnd.y - origin.y) / visualScale},
        .radius = ECBallLiveRadius(targetBall),
        .active = YES,
        .moved = YES,
    };
    id sphere = ECVisualSphere(targetBall);
    id parent = ECLooksLikeObject(sphere) ? ECInvokeId(sphere, @"parent") : nil;
    long long z = 2;
    if (ECLooksLikeObject(sphere) && [sphere respondsToSelector:@selector(zOrder)]) {
        z = ((long long (*)(id, SEL))objc_msgSend)(sphere, @selector(zOrder)) + 2;
    }
    if (!ECLooksLikeObject(parent)) {
        ECSetMarkerVisible(marker, NO);
        return;
    }
    ECSyncLandingMarker(0, parent, &landing, targetBall, z);
}

static void ECRunFullTablePrediction(void *guide, double initialSpeed,
                                     const double *friction,
                                     double slidingReduction, double rollingReduction) {
    static CFTimeInterval lastRun = 0;
    static double lastSpeed = NAN;
    static ECDPoint lastDirection = {NAN, NAN};
    CFTimeInterval now = CACurrentMediaTime();

    if (!guide || initialSpeed <= 0.1 || (!gECShowRebounds && !gECShowLandingRings)) {
        ECClearPredictionVisuals();
        return;
    }
    id table = gECCachedTable;
    id cueBall = gECCachedCueBall;
    id parent = ECPredictionParent();
    if (!table || !cueBall || !parent) return;

    // The game's large tableBounds struct return and private C++ cushion
    // vectors are not ABI-safe to call/read from injected Objective-C. They
    // caused the first powered prediction to terminate the guest. The verified
    // 254 x 127 physics box is stable for this table/version.
    ECDBox bounds = ECDefaultTableBox();
    gECTableBox = bounds;

    uint8_t *guideBytes = (uint8_t *)guide;
    ECDPoint primaryStart = {NAN, NAN};
    ECDPoint primaryEnd = {NAN, NAN};
    memcpy(&primaryStart, guideBytes + 0xb0, sizeof(primaryStart));
    memcpy(&primaryEnd, guideBytes + 0xc0, sizeof(primaryEnd));
    ECDPoint direction = ECNorm((ECDPoint){primaryEnd.x - primaryStart.x,
                                           primaryEnd.y - primaryStart.y});
    if (!ECPointValid(direction) || hypot(direction.x, direction.y) < 0.5) return;
    double directionDelta = isfinite(lastDirection.x)
        ? hypot(direction.x - lastDirection.x, direction.y - lastDirection.y) : INFINITY;
    if (now - lastRun < 0.10 && isfinite(lastSpeed) &&
        fabs(initialSpeed - lastSpeed) < 5.0 && directionDelta < 0.002) return;
    lastRun = now;
    lastSpeed = initialSpeed;
    lastDirection = direction;

    ECSimBall balls[EC_SIM_MAX_BALLS] = {0};
    int count = ECSnapshotSimulationBalls(balls, EC_SIM_MAX_BALLS);
    int cueIndex = -1;
    for (int i = 0; i < count; i++) {
        if (balls[i].source == cueBall) { cueIndex = i; break; }
    }
    if (cueIndex < 0) return;
    balls[cueIndex].velocity = (ECDPoint){direction.x * initialSpeed, direction.y * initialSpeed};
    balls[cueIndex].slidingTime = initialSpeed * friction[3];

    ECSimCushion cushions[EC_SIM_MAX_CUSHIONS] = {0};
    int cushionCount = 0;

    const double dt = 1.0 / 120.0;
    const int maxSteps = 7800;
    for (int step = 0; step < maxSteps; step++) {
        BOOL anyMoving = NO;
        for (int i = 0; i < count; i++) {
            ECSimBall *ball = &balls[i];
            if (!ball->active) continue;
            double speed = hypot(ball->velocity.x, ball->velocity.y);
            if (speed < 0.04) {
                ball->velocity = (ECDPoint){0, 0};
                continue;
            }
            anyMoving = YES;
            ball->moved = ball->moved || hypot(ball->pos.x - ball->start.x,
                                               ball->pos.y - ball->start.y) > 0.25;
            ball->pos.x += ball->velocity.x * dt;
            ball->pos.y += ball->velocity.y * dt;

            if (ECSimBallInPocket(table, ball)) {
                if (ball->hasRebounded) ECRecordSimPoint(ball, ball->pos);
                ball->active = NO;
                ball->velocity = (ECDPoint){0, 0};
                continue;
            }

            BOOL rebound = ECResolveNativeCushion(ball, cushions, cushionCount);
            if (!rebound && cushionCount == 0) {
                // Defensive fallback for an unsupported table implementation.
                double left = bounds.minX + ball->radius;
                double right = bounds.maxX - ball->radius;
                double bottom = bounds.minY + ball->radius;
                double top = bounds.maxY - ball->radius;
                if (ball->pos.x < left && ball->velocity.x < 0) {
                    ball->pos.x = left + (left - ball->pos.x);
                    ball->velocity.x = -ball->velocity.x;
                    rebound = YES;
                } else if (ball->pos.x > right && ball->velocity.x > 0) {
                    ball->pos.x = right - (ball->pos.x - right);
                    ball->velocity.x = -ball->velocity.x;
                    rebound = YES;
                }
                if (ball->pos.y < bottom && ball->velocity.y < 0) {
                    ball->pos.y = bottom + (bottom - ball->pos.y);
                    ball->velocity.y = -ball->velocity.y;
                    rebound = YES;
                } else if (ball->pos.y > top && ball->velocity.y > 0) {
                    ball->pos.y = top - (ball->pos.y - top);
                    ball->velocity.y = -ball->velocity.y;
                    rebound = YES;
                }
            }
            if (rebound) {
                if (!ball->hasRebounded) ball->hasRebounded = YES;
                ECRecordSimPoint(ball, ball->pos);
            }
        }

        for (int i = 0; i < count; i++) {
            if (!balls[i].active) continue;
            for (int j = i + 1; j < count; j++) {
                if (!balls[j].active) continue;
                double dx = balls[j].pos.x - balls[i].pos.x;
                double dy = balls[j].pos.y - balls[i].pos.y;
                double distance = hypot(dx, dy);
                double contact = balls[i].radius + balls[j].radius;
                if (!isfinite(distance) || distance <= 1e-8 || distance >= contact) continue;
                ECDPoint normal = {dx / distance, dy / distance};
                double relative = (balls[i].velocity.x - balls[j].velocity.x) * normal.x +
                                  (balls[i].velocity.y - balls[j].velocity.y) * normal.y;
                double overlap = contact - distance;
                balls[i].pos.x -= normal.x * overlap * 0.5;
                balls[i].pos.y -= normal.y * overlap * 0.5;
                balls[j].pos.x += normal.x * overlap * 0.5;
                balls[j].pos.y += normal.y * overlap * 0.5;
                if (relative <= 0.0) continue;
                balls[i].velocity.x -= normal.x * relative;
                balls[i].velocity.y -= normal.y * relative;
                balls[j].velocity.x += normal.x * relative;
                balls[j].velocity.y += normal.y * relative;
                double speedI = hypot(balls[i].velocity.x, balls[i].velocity.y);
                double speedJ = hypot(balls[j].velocity.x, balls[j].velocity.y);
                balls[i].slidingTime = MAX(balls[i].slidingTime, speedI * friction[3]);
                balls[j].slidingTime = MAX(balls[j].slidingTime, speedJ * friction[3]);
                balls[i].moved = balls[j].moved = YES;
                if (balls[i].hasRebounded) ECRecordSimPoint(&balls[i], balls[i].pos);
                if (balls[j].hasRebounded) ECRecordSimPoint(&balls[j], balls[j].pos);
            }
        }

        for (int i = 0; i < count; i++) {
            ECSimBall *ball = &balls[i];
            if (!ball->active) continue;
            double speed = hypot(ball->velocity.x, ball->velocity.y);
            if (speed <= 0.0) continue;
            double reduction = ball->slidingTime > 0.0 ? slidingReduction : rollingReduction;
            double nextSpeed = fmax(0.0, speed - reduction * dt);
            double ratio = nextSpeed / speed;
            ball->velocity.x *= ratio;
            ball->velocity.y *= ratio;
            ball->slidingTime = fmax(0.0, ball->slidingTime - dt);
        }
        if (!anyMoving) break;
    }

    ECResetReboundSprites();
    long long z = ECPredictionZ();
    for (int i = 0; i < count; i++) {
        ECSimBall *ball = &balls[i];
        if (ball->hasRebounded && ball->active) ECRecordSimPoint(ball, ball->pos);
        if (gECShowRebounds && ball->pointCount >= 2) {
            ECccColor3B color = ECColorForBallNumber(ball->number);
            for (int point = 1; point < ball->pointCount; point++) {
                ECAddReboundSprite(parent, ball->points[point - 1], ball->points[point],
                                   color, cueBall, z);
            }
        }
        ECSyncLandingMarker(i, parent, ball, cueBall, z + 1);
    }
    for (int i = count; i < 20; i++) ECSetMarkerVisible(gECPredictionMarkers[i], NO);

    static CFTimeInterval lastLog = 0;
    if (now - lastLog > 0.75) {
        lastLog = now;
        int moved = 0, potted = 0, reboundLines = 0;
        for (int i = 0; i < count; i++) {
            if (balls[i].moved) moved++;
            if (!balls[i].active) potted++;
            reboundLines += MAX(0, balls[i].pointCount - 1);
        }
        ECLogLine([NSString stringWithFormat:
            @"full-prediction balls=%d moved=%d potted=%d rebounds=%d cushions=%d bounds=%.2f,%.2f..%.2f,%.2f",
            count, moved, potted, reboundLines, cushionCount,
            bounds.minX, bounds.minY, bounds.maxX, bounds.maxY]);
    }
}
#endif

static void ECUpdatePhysicsGuideForCue(id visualCue) {
    static BOOL updating = NO;
    if (updating) return;
    if (!visualCue || !ECExtensionIsActive() || !ECNativePhysicsSurfaceValid()) return;

    double cuePower = 0.0;
    if (!ECReadDoubleIvar(visualCue, "mPower", &cuePower)) return;
    id table = ECIvarObject(visualCue, "mTable");
    if (!table) table = gECCachedTable;
    if (!table) return;

    Ivar frictionIvar = class_getInstanceVariable([table class], "_frictionProperties");
    if (!frictionIvar) return;
    const uint8_t *tableBytes = (const uint8_t *)(__bridge const void *)table;
    const double *friction = (const double *)(tableBytes + ivar_getOffset(frictionIvar));
    double cueForce = *(double *)ECGameAddress(EC_GAME_FORCE_ADDRESS);
    if (!isfinite(cueForce) || cueForce <= 0.0) return;

    double effectiveSliding = NAN;
    double effectiveRolling = NAN;
    if (!ECEffectiveFrictionFactors((double *)friction, &effectiveSliding, &effectiveRolling)) return;

    double initialSpeed = ECShotSpeedForCuePower(cuePower, cueForce);
    double predictedDistance = ECPhysicsStoppingDistance(
        initialSpeed, friction, effectiveSliding, effectiveRolling);
    if (!isfinite(predictedDistance) || predictedDistance < 0.0) return;
    double displayDistance = fmax(predictedDistance, EC_MIN_GUIDE_DISTANCE);
    updating = YES;

    void *guide = ECRawPointerIvar(visualCue, "mVisualGuide");
    double nativeHitDistance = NAN;
    BOOL stoppedBeforeCollision = NO;
    ECCollisionGuideResult collisionResult = {
        .transfer = {NAN, NAN}, .distance = {NAN, NAN},
        .nativeWorldLength = {NAN, NAN}, .applied = NO,
    };
    if (guide) {
        void (*refresh)(void *) = (void (*)(void *))ECGameAddress(EC_VISUAL_GUIDE_REFRESH_ADDRESS);

        // First let the game resolve the real first ball/cushion intersection.
        // Its stock guide always draws that whole segment, regardless of cue
        // power; the physics distance is applied to that exact native ray below.
        *(double *)ECGameAddress(EC_GAME_AIM_ADDRESS) = displayDistance;
        refresh(guide);
        stoppedBeforeCollision = ECTrimNativeGuideToStoppingDistance(
            guide, predictedDistance, displayDistance, &nativeHitDistance);

        if (!stoppedBeforeCollision && isfinite(nativeHitDistance) &&
            nativeHitDistance >= 0.0) {
            // Once the cue ball can reach the collision, only its remaining
            // physical travel budget belongs to the native outgoing paths.
            // Refreshing with that budget prevents the pre-contact distance
            // from being counted again after impact.
            double remainingDistance = fmax(0.0, predictedDistance - nativeHitDistance);
            *(double *)ECGameAddress(EC_GAME_AIM_ADDRESS) = remainingDistance;
            refresh(guide);
            collisionResult = ECScaleCollisionGuidePathsToPhysics(
                guide, initialSpeed, nativeHitDistance, friction,
                effectiveSliding, effectiveRolling);
        }
    }

    // Prediction is detached from the live table. Any failed version, ABI,
    // geometry, ownership, or event gate clears the overlay rather than
    // presenting an approximate endpoint.
    if (guide && initialSpeed > 0.1 &&
        (gECShowRebounds || gECShowLandingRings)) {
        static CFTimeInterval lastShadow = 0;
        static double lastShadowSpeed = NAN;
        static ECDPoint lastShadowDirection = {NAN, NAN};
        CFTimeInterval shadowNow = CACurrentMediaTime();
        ECDPoint shadowDirection = {NAN, NAN};
        ECDPoint start = {NAN, NAN};
        ECDPoint end = {NAN, NAN};
        memcpy(&start, (uint8_t *)guide + 0xb0, sizeof(start));
        memcpy(&end, (uint8_t *)guide + 0xc0, sizeof(end));
        shadowDirection = ECNorm((ECDPoint){end.x - start.x, end.y - start.y});
        double directionDelta = isfinite(lastShadowDirection.x)
            ? hypot(shadowDirection.x - lastShadowDirection.x,
                    shadowDirection.y - lastShadowDirection.y)
            : INFINITY;
        if (shadowNow - lastShadow >= 0.12 || !isfinite(lastShadowSpeed) ||
            fabs(initialSpeed - lastShadowSpeed) >= 8.0 || directionDelta >= 0.008) {
            lastShadow = shadowNow;
            lastShadowSpeed = initialSpeed;
            lastShadowDirection = shadowDirection;
            EightBPShadowPrediction prediction = {0};
            BOOL predictionSucceeded = NO;
            @try {
                predictionSucceeded = EightBPShadowPredict(
                    table, gECCachedCueBall, guide, initialSpeed, friction, &prediction);
            } @catch (NSException *exception) {
                ECLogLine([NSString stringWithFormat:
                    @"shadow-predict Objective-C exception %@: %@",
                    exception.name, exception.reason ?: @"unknown"]);
            }
            if (predictionSucceeded) {
                ECLogLine([NSString stringWithFormat:
                    @"shadow-predict ok frames=%u events=%u balls=%u status=%s",
                    prediction.simulatedFrames, prediction.resolvedEvents,
                    prediction.ballCount, prediction.status]);
                ECRenderShadowPrediction(&prediction);
            } else {
                ECLogLine([NSString stringWithFormat:@"shadow-predict fail %s",
                           prediction.status[0] ? prediction.status
                                                : EightBPShadowLastStatus()]);
                ECClearPredictionVisuals();
            }
        }
    } else {
        // Releasing the power control starts the real shot. Preserve the last
        // prediction while the balls begin moving; updateVisualBall removes
        // each destination ring on arrival and clears the remaining paths when
        // the table settles. A cancelled pull expires after a short grace time.
        BOOL waitingForShot = gECHasShadowPrediction && !gECShadowShotMoving &&
            CACurrentMediaTime() - gECShadowArmedAt < 1.25;
        if (!gECShadowShotMoving && !waitingForShot) ECClearPredictionVisuals();
    }

    static CFTimeInterval lastLogTime = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (!isfinite(gECLastPredictedDistance) || now - lastLogTime > 0.35 ||
        fabs(predictedDistance - gECLastPredictedDistance) > 40.0) {
        lastLogTime = now;
        ECLogLine([NSString stringWithFormat:
            @"physics-guide power=%.5f cueForce=%.3f speed=%.3f distance=%.3f hit=%.3f preStop=%d transfer=%.3f/%.3f branch=%.3f/%.3f nativeBranch=%.3f/%.3f branchTrim=%d eq=%.8f slide=%.3f/%.3f roll=%.3f/%.3f nativeAim=%.3f",
            cuePower, cueForce, initialSpeed, predictedDistance,
            nativeHitDistance, stoppedBeforeCollision,
            collisionResult.transfer[0], collisionResult.transfer[1],
            collisionResult.distance[0], collisionResult.distance[1],
            collisionResult.nativeWorldLength[0], collisionResult.nativeWorldLength[1],
            collisionResult.applied,
            friction[3], friction[4], effectiveSliding,
            friction[5], effectiveRolling, gECNativeAimDistance]);
    }
    gECLastPredictedDistance = predictedDistance;
    updating = NO;
}

// Read a CGPoint value ivar without treating it as an Objective-C object.
// Ball keeps its own mVisualTableOrigin, so using a process-wide copy can pair
// one ball's physics position with another ball's origin while the rack is
// animating and produce a bogus visual scale.
static BOOL ECReadPointIvar(id object, const char *name, CGPoint *valueOut) {
    if (!object || !name || !valueOut) return NO;
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar) return NO;
    const uint8_t *bytes = (const uint8_t *)(__bridge const void *)object;
    memcpy(valueOut, bytes + ivar_getOffset(ivar), sizeof(*valueOut));
    return isfinite(valueOut->x) && isfinite(valueOut->y);
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
@property (nonatomic, strong) EmberMenuPanel *panel;
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
    id cue = gECActiveVisualCue;
    if (!cue) cue = ECIvarObject(ECFindGameManager(), "mVisualCue");
    if (!cue) cue = ECIvarObject(ECFindGameManager(), "_visualCue");
    ECUpdatePhysicsGuideForCue(cue);
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

- (void)closePanel {
    [self.panel removeFromSuperview];
    self.panel = nil;
}

- (void)refreshPrediction {
    id cue = gECActiveVisualCue;
    if (!cue) cue = ECIvarObject(ECFindGameManager(), "mVisualCue");
    if (!cue) cue = ECIvarObject(ECFindGameManager(), "_visualCue");
    ECUpdatePhysicsGuideForCue(cue);
}

- (void)renderMenu {
    EmberMenuPanel *panel = self.panel;
    if (!panel) return;
    [panel clearRows];
    [panel setStatus:ECIsLocalMatch() ? @"OFFLINE PHYSICS READY" : @"NETWORK MODE LOCKED"];
    [panel setFooter:@"EMBER TOOLKIT  |  8 Ball Pool 56.29.2"];
    [panel addSection:@"SHOT PREDICTION"];

    __weak typeof(self) weakSelf = self;
    [panel addToggle:@"PHYSICS GUIDE"
              detail:@"Scale native aim paths from cue force and table friction"
             enabled:gECMultiplier > 1
             handler:^(BOOL enabled) {
        [weakSelf saveMultiplier:enabled ? 8 : 1];
        if (!enabled) ECClearPredictionVisuals();
    }];
    [panel addToggle:@"CUSHION REBOUNDS"
              detail:@"Continue predicted paths after cushion contacts"
             enabled:gECShowRebounds
             handler:^(BOOL enabled) {
        gECShowRebounds = enabled;
        [NSUserDefaults.standardUserDefaults setBool:enabled forKey:ECReboundsKey];
        if (!enabled && !gECShowLandingRings) ECClearPredictionVisuals();
        [weakSelf refreshPrediction];
    }];
    [panel addToggle:@"LANDING RINGS"
              detail:@"Show each moving ball's predicted resting position"
             enabled:gECShowLandingRings
             handler:^(BOOL enabled) {
        gECShowLandingRings = enabled;
        [NSUserDefaults.standardUserDefaults setBool:enabled forKey:ECLandingRingsKey];
        if (!enabled && !gECShowRebounds) ECClearPredictionVisuals();
        [weakSelf refreshPrediction];
    }];

    [panel addSection:@"RINGS FOLLOW EACH BALL'S COLOUR"];
}

- (void)tapped {
    ECFindGameManager();
    if (!ECIsLocalMatch()) {
        [self showOfflineLockedMessage];
        return;
    }
    UIWindow *host = self.hostWindow ?: [self guestWindow];
    if (!host) return;
    [self closePanel];
    EmberMenuPanel *panel = [[EmberMenuPanel alloc]
        initWithTitle:@"8 BALL POOL  //  EMBER TOOLKIT"
        accentColor:[UIColor colorWithRed:0.95 green:0.72 blue:0.12 alpha:1.0]];
    __weak typeof(self) weakSelf = self;
    panel.onClose = ^{ [weakSelf closePanel]; };
    [panel setTabs:@[@"Prediction"] activeTab:0 handler:^(NSInteger index) {
        [weakSelf renderMenu];
    }];
    self.panel = panel;
    [self renderMenu];
    [panel presentInWindow:host];
    [host bringSubviewToFront:self.button];
    [host bringSubviewToFront:panel];
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
        title = @"GUIDE 🔒";
        color = [UIColor colorWithWhite:0.18 alpha:0.88];
    } else if (gECMultiplier <= 1) {
        title = @"GUIDE Off";
        color = [UIColor colorWithRed:0.55 green:0.25 blue:0.08 alpha:0.9];
    } else {
        title = @"GUIDE Auto";
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
    button.accessibilityLabel = @"Physics-based aiming guideline";
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
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    gECShowRebounds = [defaults objectForKey:ECReboundsKey] == nil
        ? YES : [defaults boolForKey:ECReboundsKey];
    gECShowLandingRings = [defaults objectForKey:ECLandingRingsKey] == nil
        ? YES : [defaults boolForKey:ECLandingRingsKey];
    EightBPShadowSetLogCallback(ECShadowLogCallback, NULL);
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
