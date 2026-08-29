//
//  EmberReturnButton.m
//  Ember Connect
//
//  The in-game Ember Connect overlay: a floating flame button that opens a
//  menu of things you can do without leaving the app you are in.
//
//  A guest app replaces the container's UI inside the same process, so there
//  is no navigation stack to pop and nothing on screen belongs to Ember
//  Connect. This button is the only surface we own while a game is running,
//  which makes it the natural home for anything that needs to reach into a
//  live guest.
//
//  ## Why this is a subview and not its own window
//
//  It used to live in a dedicated full-screen `UIWindow`, which broke
//  landscape games. When iOS decides which orientations an app supports it
//  consults a window's root view controller, and a plain `UIViewController`
//  answers `UIInterfaceOrientationMaskAllButUpsideDown`. A full-screen
//  overlay window at a high window level is a candidate for that lookup, so
//  the overlay's answer quietly replaced the game's own landscape-only
//  constraint: the app became freely rotatable, its scene was sized for an
//  orientation the game had not asked for, and the game ended up drawn into a
//  portrait-shaped box in the corner of a landscape screen.
//
//  Hanging everything off the app's existing window removes that whole class
//  of problem — there is no second root view controller for iOS to ask, and
//  the overlay rotates with the app for free.
//

@import UIKit;
@import QuartzCore;
@import Metal;
@import ObjectiveC;
#include <stdatomic.h>
#import "../LiveContainer/LCSharedUtils.h"
#import "../LiveContainer/utils.h"

/// Set to hide the overlay entirely, for someone who would rather force-quit.
static NSString * const kEmberHideReturnButtonKey = @"EmberHideReturnButton";
/// Remembered position, so the button stays where it was dragged.
static NSString * const kEmberReturnButtonYKey = @"EmberReturnButtonY";
static NSString * const kEmberReturnButtonLeftKey = @"EmberReturnButtonOnLeft";
static NSString * const kEmberShowFPSKey = @"EmberShowFPS";
static NSString * const kEmberKeepAwakeKey = @"EmberKeepAwake";

static const CGFloat kButtonSize = 46.0;
static const CGFloat kEdgeInset = 6.0;
static const CGFloat kIdleAlpha = 0.35;
static const CGFloat kActiveAlpha = 1.0;
static const NSTimeInterval kIdleDelay = 3.0;

#pragma mark - Frame counter

/// Counts frames the guest actually presents.
///
/// A `CADisplayLink` would only report the display's refresh rate, which stays
/// at 60 whether or not the game is keeping up — useless as a performance
/// readout. Hooking the two calls that put a rendered frame on screen counts
/// what the game really achieves: `nextDrawable` for Metal (which is what
/// Unity and most modern engines use) and `presentRenderbuffer:` for the
/// older GLES path.
static _Atomic(uint64_t) EmberPresentedFrames = 0;
static BOOL EmberFrameHooksInstalled = NO;

@interface CAMetalLayer (EmberFPS)
@end
@implementation CAMetalLayer (EmberFPS)
- (id<CAMetalDrawable>)ember_nextDrawable {
    atomic_fetch_add(&EmberPresentedFrames, 1);
    return [self ember_nextDrawable];
}
@end

static void EmberInstallFrameHooks(void) {
    if (EmberFrameHooksInstalled) return;
    EmberFrameHooksInstalled = YES;

    Class metal = NSClassFromString(@"CAMetalLayer");
    if (metal) {
        Method original = class_getInstanceMethod(metal, @selector(nextDrawable));
        Method replacement = class_getInstanceMethod(metal, @selector(ember_nextDrawable));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    }

    // GLES games present through -[EAGLContext presentRenderbuffer:]. OpenGL
    // ES is deprecated and the class may be absent entirely, so it is looked
    // up at runtime rather than linked against.
    Class eagl = NSClassFromString(@"EAGLContext");
    SEL present = NSSelectorFromString(@"presentRenderbuffer:");
    if (eagl && [eagl instancesRespondToSelector:present]) {
        Method original = class_getInstanceMethod(eagl, present);
        if (original) {
            __block IMP originalIMP = NULL;
            IMP counting = imp_implementationWithBlock(^BOOL(id target, NSUInteger buffer) {
                atomic_fetch_add(&EmberPresentedFrames, 1);
                return ((BOOL (*)(id, SEL, NSUInteger))originalIMP)(target, present, buffer);
            });
            originalIMP = method_setImplementation(original, counting);
        }
    }
}

#pragma mark - Controller

@interface EmberReturnButtonController : NSObject
@property (nonatomic, weak) UIButton *button;
@property (nonatomic, weak) UILabel *fpsLabel;
@property (nonatomic, weak) UIWindow *host;
@property (nonatomic, strong) NSTimer *idleTimer;
@property (nonatomic, strong) NSTimer *fpsTimer;
@property (nonatomic, assign) uint64_t lastFrameCount;
@property (nonatomic, assign) NSTimeInterval lastFrameSampleAt;
@end

@implementation EmberReturnButtonController

+ (instancetype)shared {
    static EmberReturnButtonController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [EmberReturnButtonController new]; });
    return shared;
}

/// The app's own front-most window. Deliberately picks the app's, and skips
/// windows with no root view controller — a game engine often keeps a spare.
- (UIWindow *)hostWindow {
    UIWindow *best = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || !window.rootViewController) continue;
            if (!best || window.windowLevel >= best.windowLevel) best = window;
        }
    }
    return best;
}

- (void)install {
    UIWindow *host = [self hostWindow];
    if (!host) return;

    if (self.button && self.button.superview == host) {
        [host bringSubviewToFront:self.button];
        if (self.fpsLabel) [host bringSubviewToFront:self.fpsLabel];
        [self clampIntoBounds];
        return;
    }
    [self.button removeFromSuperview];
    [self.fpsLabel removeFromSuperview];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake(0, 0, kButtonSize, kButtonSize);
    button.backgroundColor = [UIColor colorWithRed:0.98 green:0.42 blue:0.13 alpha:1.0];
    button.layer.cornerRadius = kButtonSize / 2.0;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.35;
    button.layer.shadowRadius = 6.0;
    button.layer.shadowOffset = CGSizeMake(0, 2);
    button.tintColor = UIColor.whiteColor;
    button.accessibilityLabel = @"Ember Connect";
    button.autoresizingMask = UIViewAutoresizingNone;

    UIImage *glyph = nil;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold];
        glyph = [UIImage systemImageNamed:@"flame.fill" withConfiguration:config];
    }
    if (glyph) {
        [button setImage:[glyph imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                forState:UIControlStateNormal];
    } else {
        [button setTitle:@"EC" forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    }

    [button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(panned:)]];

    UILabel *fps = [[UILabel alloc] initWithFrame:CGRectZero];
    fps.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightBold];
    fps.textColor = UIColor.whiteColor;
    fps.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    fps.textAlignment = NSTextAlignmentCenter;
    fps.layer.cornerRadius = 5;
    fps.clipsToBounds = YES;
    fps.hidden = YES;
    fps.userInteractionEnabled = NO;

    [host addSubview:button];
    [host addSubview:fps];
    [host bringSubviewToFront:button];
    self.button = button;
    self.fpsLabel = fps;
    self.host = host;

    [self restorePosition];
    [self markActive];
    [self applyKeepAwake];
    if ([NSUserDefaults.lcUserDefaults boolForKey:kEmberShowFPSKey]) [self startFPS];
}

#pragma mark - Position

- (CGRect)hostBounds {
    UIWindow *host = self.host ?: [self hostWindow];
    return host ? host.bounds : UIScreen.mainScreen.bounds;
}

- (void)layoutFPSLabel {
    CGRect button = self.button.frame;
    CGFloat width = 52, height = 18;
    self.fpsLabel.frame = CGRectMake(CGRectGetMidX(button) - width / 2,
                                     CGRectGetMinY(button) - height - 4,
                                     width, height);
}

- (void)restorePosition {
    CGRect bounds = [self hostBounds];
    NSUserDefaults *defaults = NSUserDefaults.lcUserDefaults;
    id storedY = [defaults objectForKey:kEmberReturnButtonYKey];
    CGFloat y = storedY ? [storedY doubleValue] : CGRectGetMidY(bounds) - kButtonSize / 2.0;
    BOOL onLeft = [defaults boolForKey:kEmberReturnButtonLeftKey];

    y = MAX(kEdgeInset, MIN(y, CGRectGetHeight(bounds) - kButtonSize - kEdgeInset));
    CGFloat x = onLeft ? kEdgeInset : CGRectGetWidth(bounds) - kButtonSize - kEdgeInset;
    self.button.frame = CGRectMake(x, y, kButtonSize, kButtonSize);
    [self layoutFPSLabel];
}

/// Keeps the overlay on screen after the app rotates, since the window's
/// bounds swap underneath it.
- (void)clampIntoBounds {
    if (!self.button) return;
    CGRect bounds = [self hostBounds];
    CGRect frame = self.button.frame;
    BOOL onLeft = [NSUserDefaults.lcUserDefaults boolForKey:kEmberReturnButtonLeftKey];

    CGFloat maxY = MAX(kEdgeInset, CGRectGetHeight(bounds) - kButtonSize - kEdgeInset);
    frame.origin.y = MAX(kEdgeInset, MIN(frame.origin.y, maxY));
    frame.origin.x = onLeft ? kEdgeInset : CGRectGetWidth(bounds) - kButtonSize - kEdgeInset;
    self.button.frame = frame;
    [self layoutFPSLabel];
}

- (void)panned:(UIPanGestureRecognizer *)pan {
    UIView *host = self.button.superview;
    if (!host) return;
    CGRect bounds = [self hostBounds];
    CGPoint translation = [pan translationInView:host];
    CGRect frame = self.button.frame;

    frame.origin.x += translation.x;
    frame.origin.y += translation.y;
    [pan setTranslation:CGPointZero inView:host];
    self.button.frame = frame;
    [self layoutFPSLabel];
    [self markActive];

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled) {
        BOOL onLeft = CGRectGetMidX(frame) < CGRectGetMidX(bounds);
        CGFloat y = MAX(kEdgeInset,
                        MIN(frame.origin.y, CGRectGetHeight(bounds) - kButtonSize - kEdgeInset));
        CGFloat x = onLeft ? kEdgeInset : CGRectGetWidth(bounds) - kButtonSize - kEdgeInset;

        [UIView animateWithDuration:0.2 animations:^{
            self.button.frame = CGRectMake(x, y, kButtonSize, kButtonSize);
            [self layoutFPSLabel];
        }];

        NSUserDefaults *defaults = NSUserDefaults.lcUserDefaults;
        [defaults setDouble:y forKey:kEmberReturnButtonYKey];
        [defaults setBool:onLeft forKey:kEmberReturnButtonLeftKey];
    }
}

#pragma mark - Fade

- (void)markActive {
    [self.idleTimer invalidate];
    self.button.alpha = kActiveAlpha;
    __weak typeof(self) weakSelf = self;
    self.idleTimer = [NSTimer scheduledTimerWithTimeInterval:kIdleDelay
                                                     repeats:NO
                                                       block:^(NSTimer *timer) {
        [UIView animateWithDuration:0.4 animations:^{
            weakSelf.button.alpha = kIdleAlpha;
        }];
    }];
}

#pragma mark - Features

- (void)applyKeepAwake {
    BOOL keepAwake = [NSUserDefaults.lcUserDefaults boolForKey:kEmberKeepAwakeKey];
    UIApplication.sharedApplication.idleTimerDisabled = keepAwake;
}

- (void)startFPS {
    EmberInstallFrameHooks();
    self.fpsLabel.hidden = NO;
    self.lastFrameCount = atomic_load(&EmberPresentedFrames);
    self.lastFrameSampleAt = CACurrentMediaTime();
    [self.fpsTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.fpsTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                    repeats:YES
                                                      block:^(NSTimer *timer) {
        [weakSelf sampleFPS];
    }];
}

- (void)stopFPS {
    [self.fpsTimer invalidate];
    self.fpsTimer = nil;
    self.fpsLabel.hidden = YES;
}

- (void)sampleFPS {
    uint64_t now = atomic_load(&EmberPresentedFrames);
    NSTimeInterval at = CACurrentMediaTime();
    NSTimeInterval elapsed = at - self.lastFrameSampleAt;
    if (elapsed <= 0) return;

    double fps = (double)(now - self.lastFrameCount) / elapsed;
    self.lastFrameCount = now;
    self.lastFrameSampleAt = at;

    // A game that presents through neither hooked path leaves the counter at
    // zero forever; say so rather than insisting it is running at 0 fps.
    self.fpsLabel.text = (now == 0) ? @"— fps"
                                    : [NSString stringWithFormat:@"%.0f fps", fps];
}

#pragma mark - Guest app catalogue

/// Guest apps installed in this container, as (folder name, display name).
///
/// Apps live in one of two roots depending on whether they were kept private
/// or converted to shared, so both are scanned. The folder name is what the
/// launcher wants — it is the same "relative bundle path" the app list writes
/// into `selected`.
- (NSArray<NSArray<NSString *> *> *)installedGuestApps {
    NSMutableArray *apps = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    NSFileManager *fm = NSFileManager.defaultManager;

    NSMutableArray<NSString *> *roots = [NSMutableArray new];
    NSString *group = [NSUserDefaults lcAppGroupPath];
    if (group) {
        [roots addObject:[group stringByAppendingPathComponent:@"LiveContainer/Applications"]];
    }
    const char *home = getenv("LC_HOME_PATH");
    if (home) {
        [roots addObject:[[NSString stringWithUTF8String:home]
                          stringByAppendingPathComponent:@"Documents/Applications"]];
    }

    NSString *current = NSBundle.mainBundle.bundlePath.lastPathComponent;

    for (NSString *root in roots) {
        for (NSString *folder in [fm contentsOfDirectoryAtPath:root error:nil]) {
            if ([folder isEqualToString:current] || [seen containsObject:folder]) continue;
            NSString *path = [root stringByAppendingPathComponent:folder];
            NSString *infoPath = [path stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
            if (!info) continue;

            NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: folder;
            [seen addObject:folder];
            [apps addObject:@[folder, name]];
        }
    }

    [apps sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [a[1] localizedCaseInsensitiveCompare:b[1]];
    }];
    return apps;
}

- (void)launchBundleFolder:(NSString *)folder {
    NSString *scheme = NSUserDefaults.lcAppUrlScheme;
    if (!scheme) return;
    NSString *encoded = [folder stringByAddingPercentEncodingWithAllowedCharacters:
                         NSCharacterSet.URLQueryAllowedCharacterSet] ?: folder;
    NSURL *url = [NSURL URLWithString:
                  [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@",
                   scheme, encoded]];
    [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithURL:url];
}

#pragma mark - Menu

- (UIViewController *)presenter {
    UIViewController *presenter = self.button.window.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    return presenter;
}

- (void)present:(UIAlertController *)sheet {
    // An action sheet needs an anchor on iPad or it throws.
    sheet.popoverPresentationController.sourceView = self.button;
    sheet.popoverPresentationController.sourceRect = self.button.bounds;
    [[self presenter] presentViewController:sheet animated:YES completion:nil];
}

- (void)tapped {
    [self markActive];
    if (![self presenter]) return;

    NSUserDefaults *defaults = NSUserDefaults.lcUserDefaults;
    BOOL keepAwake = [defaults boolForKey:kEmberKeepAwakeKey];
    BOOL showFPS = [defaults boolForKey:kEmberShowFPSKey];

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"Ember Connect"
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;

    [sheet addAction:[UIAlertAction actionWithTitle:@"Switch App…"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [weakSelf showAppSwitcher];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:(keepAwake ? @"Allow Screen to Sleep"
                                                              : @"Keep Screen Awake")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [defaults setBool:!keepAwake forKey:kEmberKeepAwakeKey];
        [weakSelf applyKeepAwake];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:(showFPS ? @"Hide FPS" : @"Show FPS")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [defaults setBool:!showFPS forKey:kEmberShowFPSKey];
        if (showFPS) { [weakSelf stopFPS]; } else { [weakSelf startFPS]; }
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Hide This Button"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        [weakSelf confirmHide];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Return to Ember Connect"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [weakSelf confirmReturn];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self present:sheet];
}

- (void)showAppSwitcher {
    NSArray<NSArray<NSString *> *> *apps = [self installedGuestApps];

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"Switch App"
                                            message:(apps.count ? @"The current app will close."
                                                                : @"No other apps are installed.")
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    for (NSArray<NSString *> *app in apps) {
        NSString *folder = app[0];
        [sheet addAction:[UIAlertAction actionWithTitle:app[1]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            [weakSelf launchBundleFolder:folder];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self present:sheet];
}

- (void)confirmReturn {
    NSString *scheme = NSUserDefaults.lcAppUrlScheme;
    if (!scheme) return;
    NSURL *url = [NSURL URLWithString:
                  [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=ui", scheme]];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Return to Ember Connect"
                         message:@"This app will close. Anything it has not saved will be lost."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Return"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithURL:url];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Stay"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [[self presenter] presentViewController:alert animated:YES completion:nil];
}

- (void)confirmHide {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Hide the Ember Connect button?"
                         message:@"It stays hidden in every app until you turn it back on in "
                                  "Ember Connect's settings."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hide"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        [NSUserDefaults.lcUserDefaults setBool:YES forKey:kEmberHideReturnButtonKey];
        [self.button removeFromSuperview];
        [self.fpsLabel removeFromSuperview];
        [self stopFPS];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [[self presenter] presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Installation

static void EmberInstallOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([NSUserDefaults.lcUserDefaults boolForKey:kEmberHideReturnButtonKey]) return;
        [[EmberReturnButtonController shared] install];
    });
}

__attribute__((constructor))
static void EmberReturnButtonInit(void) {
    // Guest processes only. The container's own UI has a tab bar; it does not
    // need a way back to itself.
    if (!NSUserDefaults.lcGuestAppId) return;
    // In multitask mode the app already runs in a dismissable window with the
    // dock, so a second escape hatch would just cover its content.
    if (NSUserDefaults.isLiveProcess) return;
    if ([NSUserDefaults.lcUserDefaults boolForKey:kEmberHideReturnButtonKey]) return;

    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification,
                                      UISceneDidActivateNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
            EmberInstallOverlay();
        }];
    }

    [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        [[EmberReturnButtonController shared] clampIntoBounds];
    }];
}
