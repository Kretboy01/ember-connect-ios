// CloverPit.m — Ember Connect practice toolkit for Clover Pit.
//
// Verified against the installed iOS build (IL2CPP metadata v31). The game
// code lives in UnityFramework.framework; RVAs below come from Il2CppDumper
// using that exact framework and global-metadata.dat.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
#import "../Shared/EmberMenu.h"

#define EMBER_CLOVER_BUTTON_TAG                  0xC10E4
#define CLOVER_RVA_SPINS_LEFT_SET                0x1737B84UL
#define CLOVER_RVA_SPINS_LEFT_ADD                0x1737C08UL
#define CLOVER_RVA_MAX_SPINS_SET                 0x1738934UL
#define CLOVER_RVA_TICKETS_ADD                   0x1734EF8UL
#define CLOVER_RVA_POWERUP_LUCK_SET              0x1739F60UL
#define CLOVER_RVA_ACTIVATION_LUCK_SET           0x173A2F0UL
#define CLOVER_RVA_STORE_LUCK_SET                0x173A5E4UL
#define CLOVER_RVA_666_SUPPRESSED_SET             0x1743630UL
#define CLOVER_RVA_REMOVE_VISIBLE_666             0x1805288UL
#define CLOVER_RVA_REPLACE_ALL_VISIBLE            0x1803FA8UL
#define CLOVER_RVA_TIME_SET_TIMESCALE             0x4A791A0UL

static void *g_clover_image = NULL;
static CFAbsoluteTime g_clover_load_time = 0;
static NSMutableString *g_clover_log = nil;
static NSString *g_clover_log_path = nil;

static void CloverLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void CloverLog(NSString *fmt, ...) {
    if (!g_clover_log) g_clover_log = [NSMutableString new];
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *entry = [NSString stringWithFormat:@"[%.2f] %@\n", CACurrentMediaTime(), line];
    NSLog(@"[Ember/CloverPit] %@", line);
    @synchronized (g_clover_log) { [g_clover_log appendString:entry]; }
    if (!g_clover_log_path) {
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *folder = [documents stringByAppendingPathComponent:@"EmberConnect"];
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        g_clover_log_path = [folder stringByAppendingPathComponent:@"CloverPit-diag.log"];
    }
    @synchronized (g_clover_log) {
        [g_clover_log writeToFile:g_clover_log_path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static BOOL CloverEnsureRuntime(void) {
    if (g_clover_image) return YES;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if ([path.lastPathComponent isEqualToString:@"UnityFramework"] &&
            [path.lowercaseString containsString:@"cloverpit"]) {
            g_clover_image = (void *)_dyld_get_image_header(i);
            CloverLog(@"UnityFramework found at %p (image %u, slide=%lld)",
                      g_clover_image, i, (long long)_dyld_get_image_vmaddr_slide(i));
            return YES;
        }
    }
    return NO;
}

static BOOL CloverReady(void) {
    return CloverEnsureRuntime() && (CACurrentMediaTime() - g_clover_load_time) > 7.0;
}

static void CloverCallInt(uintptr_t rva, int value) {
    if (!CloverReady()) return;
    ((void (*)(int, void *))((char *)g_clover_image + rva))(value, NULL);
}

static void CloverCallFloat(uintptr_t rva, float value) {
    if (!CloverReady()) return;
    ((void (*)(float, void *))((char *)g_clover_image + rva))(value, NULL);
}

static void CloverAddTickets(long long value) {
    if (!CloverReady()) return;
    ((void (*)(long long, BOOL, void *))((char *)g_clover_image + CLOVER_RVA_TICKETS_ADD))(value, YES, NULL);
    CloverLog(@"tickets add -> %lld", value);
}

static void CloverReplaceSymbols(int kind, int modifier) {
    if (!CloverReady()) return;
    ((void (*)(int, int, BOOL, void *))((char *)g_clover_image + CLOVER_RVA_REPLACE_ALL_VISIBLE))
        (kind, modifier, NO, NULL);
    CloverLog(@"replace visible symbols kind=%d modifier=%d", kind, modifier);
}

@interface EmberCloverController : NSObject
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) EmberMenuPanel *panel;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL infiniteSpins;
@property (nonatomic, assign) BOOL suppress666;
@property (nonatomic, assign) float powerupLuck;
@property (nonatomic, assign) float activationLuck;
@property (nonatomic, assign) float storeLuck;
+ (instancetype)sharedController;
- (void)start;
@end

@implementation EmberCloverController

+ (instancetype)sharedController {
    static EmberCloverController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        controller = [EmberCloverController new];
        controller.powerupLuck = 1.0f;
        controller.activationLuck = 1.0f;
        controller.storeLuck = 1.0f;
    });
    return controller;
}

- (UIWindow *)hostWindow {
    for (__kindof UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState == UISceneActivationStateBackground) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if ([windowScene respondsToSelector:@selector(keyWindow)] && windowScene.keyWindow) return windowScene.keyWindow;
        if (windowScene.windows.firstObject) return windowScene.windows.firstObject;
    }
    return UIApplication.sharedApplication.keyWindow;
}

- (void)closePanel {
    [self.panel removeFromSuperview];
    self.panel = nil;
}

- (void)renderTab:(NSInteger)tab {
    EmberMenuPanel *panel = self.panel;
    if (!panel) return;
    [panel clearRows];
    [panel setStatus:CloverReady() ? @"IL2CPP ONLINE  |  GAMEPLAY DATA READY"
                                  : @"WAITING FOR CLOVER PIT RUNTIME"];
    __weak typeof(self) weakSelf = self;

    if (tab == 0) {
        [panel addSection:@"SPINS"];
        [panel addToggle:@"INFINITE SPINS" detail:@"Keeps available spins at 99" enabled:self.infiniteSpins handler:^(BOOL enabled) {
            weakSelf.infiniteSpins = enabled;
            if (enabled) {
                CloverCallInt(CLOVER_RVA_MAX_SPINS_SET, 99);
                CloverCallInt(CLOVER_RVA_SPINS_LEFT_SET, 99);
            }
        }];
        [panel addAction:@"ADD 5 SPINS" detail:nil handler:^{ CloverCallInt(CLOVER_RVA_SPINS_LEFT_ADD, 5); }];
        [panel addAction:@"ADD 20 SPINS" detail:nil handler:^{ CloverCallInt(CLOVER_RVA_SPINS_LEFT_ADD, 20); }];
        [panel addAction:@"SET MAX SPINS TO 99" detail:nil handler:^{ CloverCallInt(CLOVER_RVA_MAX_SPINS_SET, 99); }];
        [panel addSection:@"CLOVER TICKETS"];
        [panel addAction:@"ADD 10 TICKETS" detail:nil handler:^{ CloverAddTickets(10); }];
        [panel addAction:@"ADD 100 TICKETS" detail:nil handler:^{ CloverAddTickets(100); }];
    } else if (tab == 1) {
        [panel addSection:@"LUCK CHANNELS"];
        [panel addSlider:@"POWERUP LUCK" value:self.powerupLuck min:0.5f max:8.0f format:@"%.2fx" handler:^(float value) {
            weakSelf.powerupLuck = value;
            CloverCallFloat(CLOVER_RVA_POWERUP_LUCK_SET, value);
        }];
        [panel addSlider:@"ACTIVATION LUCK" value:self.activationLuck min:0.5f max:8.0f format:@"%.2fx" handler:^(float value) {
            weakSelf.activationLuck = value;
            CloverCallFloat(CLOVER_RVA_ACTIVATION_LUCK_SET, value);
        }];
        [panel addSlider:@"STORE LUCK" value:self.storeLuck min:0.5f max:8.0f format:@"%.2fx" handler:^(float value) {
            weakSelf.storeLuck = value;
            CloverCallFloat(CLOVER_RVA_STORE_LUCK_SET, value);
        }];
        [panel addAction:@"BOOST ALL TO 5x" detail:@"Applies all three luck channels" handler:^{
            weakSelf.powerupLuck = weakSelf.activationLuck = weakSelf.storeLuck = 5.0f;
            CloverCallFloat(CLOVER_RVA_POWERUP_LUCK_SET, 5.0f);
            CloverCallFloat(CLOVER_RVA_ACTIVATION_LUCK_SET, 5.0f);
            CloverCallFloat(CLOVER_RVA_STORE_LUCK_SET, 5.0f);
            [weakSelf renderTab:1];
        }];
        [panel addAction:@"RESET LUCK" detail:@"Restore all channels to 1x" handler:^{
            weakSelf.powerupLuck = weakSelf.activationLuck = weakSelf.storeLuck = 1.0f;
            CloverCallFloat(CLOVER_RVA_POWERUP_LUCK_SET, 1.0f);
            CloverCallFloat(CLOVER_RVA_ACTIVATION_LUCK_SET, 1.0f);
            CloverCallFloat(CLOVER_RVA_STORE_LUCK_SET, 1.0f);
            [weakSelf renderTab:1];
        }];
    } else if (tab == 2) {
        [panel addSection:@"VISIBLE REEL OVERRIDE"];
        [panel addAction:@"ALL SEVENS" detail:@"Replace visible symbols before scoring" handler:^{ CloverReplaceSymbols(6, 0); }];
        [panel addAction:@"ALL GOLDEN SEVENS" detail:@"Seven symbols with golden modifier" handler:^{ CloverReplaceSymbols(6, 3); }];
        [panel addAction:@"ALL DIAMONDS" detail:nil handler:^{ CloverReplaceSymbols(4, 0); }];
        [panel addAction:@"ALL CLOVERS" detail:nil handler:^{ CloverReplaceSymbols(2, 0); }];
        [panel addAction:@"ALL COINS" detail:nil handler:^{ CloverReplaceSymbols(5, 0); }];
        [panel addAction:@"ALL TICKET CLOVERS" detail:@"Clover symbols with ticket modifier" handler:^{ CloverReplaceSymbols(2, 2); }];
        [panel addSection:@"DANGER CONTROL"];
        [panel addToggle:@"SUPPRESS 666" detail:@"Continuously books 999 safe spins" enabled:self.suppress666 handler:^(BOOL enabled) {
            weakSelf.suppress666 = enabled;
            CloverCallInt(CLOVER_RVA_666_SUPPRESSED_SET, enabled ? 999 : 0);
        }];
        [panel addAction:@"REMOVE VISIBLE 666" detail:nil handler:^{
            if (CloverReady()) ((void (*)(void *))((char *)g_clover_image + CLOVER_RVA_REMOVE_VISIBLE_666))(NULL);
        }];
    } else {
        [panel addSection:@"GAME SPEED"];
        [panel addSlider:@"TIME SCALE" value:1.0f min:0.1f max:3.0f format:@"%.2fx" handler:^(float value) {
            CloverCallFloat(CLOVER_RVA_TIME_SET_TIMESCALE, value);
        }];
        [panel addSection:@"DIAGNOSTICS"];
        [panel addAction:@"WRITE SNAPSHOT" detail:@"Documents/EmberConnect/CloverPit-diag.log" handler:^{
            CloverLog(@"snapshot runtime=%p infinite=%d no666=%d luck=%.2f/%.2f/%.2f",
                      g_clover_image, weakSelf.infiniteSpins, weakSelf.suppress666,
                      weakSelf.powerupLuck, weakSelf.activationLuck, weakSelf.storeLuck);
        }];
    }
}

- (void)showMenu {
    UIWindow *host = [self hostWindow];
    if (!host) return;
    [self closePanel];
    EmberMenuPanel *panel = [[EmberMenuPanel alloc] initWithTitle:@"CLOVER PIT  //  EMBER TOOLKIT"
                                                      accentColor:[UIColor colorWithRed:0.35 green:0.92 blue:0.38 alpha:1.0]];
    __weak typeof(self) weakSelf = self;
    panel.onClose = ^{ [weakSelf closePanel]; };
    [panel setTabs:@[@"Run", @"Luck", @"Reels", @"System"] activeTab:0 handler:^(NSInteger index) {
        [weakSelf renderTab:index];
    }];
    self.panel = panel;
    [self renderTab:0];
    [panel presentInWindow:host];
}

- (void)tapped {
    if (self.panel) [self closePanel]; else [self showMenu];
}

- (void)dragged:(UIPanGestureRecognizer *)gesture {
    UIView *view = gesture.view;
    CGPoint delta = [gesture translationInView:view.superview];
    view.center = CGPointMake(view.center.x + delta.x, view.center.y + delta.y);
    [gesture setTranslation:CGPointZero inView:view.superview];
}

- (void)installButton {
    UIWindow *host = [self hostWindow];
    if (!host) return;
    CloverEnsureRuntime();
    if (self.button.superview == host) {
        [host bringSubviewToFront:self.button];
        if (self.panel) [host bringSubviewToFront:self.panel];
        return;
    }
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.tag = EMBER_CLOVER_BUTTON_TAG;
    button.frame = CGRectMake(0, 0, 102, 36);
    button.center = CGPointMake(CGRectGetWidth(host.bounds) - 65.0, CGRectGetMidY(host.bounds));
    button.backgroundColor = [UIColor colorWithRed:0.08 green:0.34 blue:0.10 alpha:0.88];
    button.layer.cornerRadius = 8.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithRed:0.35 green:0.92 blue:0.38 alpha:0.65].CGColor;
    [button setTitle:@"CLOVER TOOLS" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightBold];
    [button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
    pan.cancelsTouchesInView = NO;
    [button addGestureRecognizer:pan];
    [host addSubview:button];
    self.button = button;
}

- (void)tick {
    [self installButton];
    if (!CloverReady()) return;
    if (self.infiniteSpins) CloverCallInt(CLOVER_RVA_SPINS_LEFT_SET, 99);
    if (self.suppress666) CloverCallInt(CLOVER_RVA_666_SUPPRESSED_SET, 999);
}

- (void)start {
    [self installButton];
    [self.timer invalidate];
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.75 repeats:YES block:^(NSTimer *timer) {
        [weakSelf tick];
    }];
}

@end

__attribute__((constructor))
static void EmberCloverPitInit(void) {
    g_clover_load_time = CACurrentMediaTime();
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier.lowercaseString;
        NSString *executable = NSBundle.mainBundle.executablePath.lastPathComponent.lowercaseString;
        if (![bundle isEqualToString:@"com.panikarcade.cloverpit"] &&
            ![executable isEqualToString:@"cloverpit"]) {
            // Bundle IDs are case-insensitive; executable check is the stable
            // LiveContainer signature if the host bundle is temporarily shown.
            CloverLog(@"wrong guest: %@ (%@)", bundle, executable);
            return;
        }
        CloverLog(@"tweak loaded in %@", bundle);
        [[EmberCloverController sharedController] start];
    });
}
