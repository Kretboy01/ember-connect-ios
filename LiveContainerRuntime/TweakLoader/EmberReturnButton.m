//
//  EmberReturnButton.m
//  Ember Connect
//
//  A floating "back to Ember Connect" control, injected into every guest app.
//
//  A guest app replaces the container's UI inside the same process, so there
//  is no navigation stack to pop and nothing on screen that belongs to Ember
//  Connect. Getting back meant force-quitting from the app switcher and
//  launching again by hand. The switch itself was always possible — opening
//  `<scheme>://livecontainer-launch?bundle-name=ui` sets the next launch
//  target to the UI and restarts — but nothing inside a running game could
//  ask for it. This is that missing trigger.
//
//  The return is not free: `launchToGuestApp` SIGKILLs the process after
//  handing the URL to iOS, so the guest never gets `applicationWillTerminate`
//  and cannot flush unsaved state. That is why a tap asks first.
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
//  Hanging the button off the app's existing window removes the whole class
//  of problem — there is no second root view controller for iOS to ask, and
//  the button rotates with the app for free.
//

@import UIKit;
@import ObjectiveC;
#import "../LiveContainer/LCSharedUtils.h"
#import "../LiveContainer/utils.h"

/// Set to hide the button entirely, for someone who would rather force-quit.
static NSString * const kEmberHideReturnButtonKey = @"EmberHideReturnButton";
/// Remembered position, so the button stays where it was dragged.
static NSString * const kEmberReturnButtonYKey = @"EmberReturnButtonY";
static NSString * const kEmberReturnButtonLeftKey = @"EmberReturnButtonOnLeft";

static const CGFloat kButtonSize = 46.0;
static const CGFloat kEdgeInset = 6.0;
/// Faded once the user stops interacting, so it does not sit on top of a game
/// at full strength forever.
static const CGFloat kIdleAlpha = 0.35;
static const CGFloat kActiveAlpha = 1.0;
static const NSTimeInterval kIdleDelay = 3.0;

@interface EmberReturnButtonController : NSObject
@property (nonatomic, weak) UIButton *button;
@property (nonatomic, weak) UIWindow *host;
@property (nonatomic, strong) NSTimer *idleTimer;
@end

@implementation EmberReturnButtonController

+ (instancetype)shared {
    static EmberReturnButtonController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [EmberReturnButtonController new]; });
    return shared;
}

/// The app's own front-most window. Deliberately picks the app's, never one
/// of ours, and skips windows with no root view controller — a game engine
/// often keeps a spare around.
- (UIWindow *)hostWindow {
    UIWindow *best = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.hidden || !window.rootViewController) continue;
            if (!best || window.windowLevel >= best.windowLevel) best = window;
        }
    }
    return best;
}

- (void)install {
    UIWindow *host = [self hostWindow];
    if (!host) return;

    UIButton *button = self.button;
    if (button && button.superview == host) {
        // Already in place; just make sure the game has not covered it.
        [host bringSubviewToFront:button];
        [self clampIntoBounds];
        return;
    }
    [button removeFromSuperview];

    button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake(0, 0, kButtonSize, kButtonSize);
    button.backgroundColor = [UIColor colorWithRed:0.98 green:0.42 blue:0.13 alpha:1.0];
    button.layer.cornerRadius = kButtonSize / 2.0;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.35;
    button.layer.shadowRadius = 6.0;
    button.layer.shadowOffset = CGSizeMake(0, 2);
    button.tintColor = UIColor.whiteColor;
    button.accessibilityLabel = @"Return to Ember Connect";
    // Pinned to the top-left corner: the button is positioned by frame, and a
    // resizing mask would fight that every time the app rotates.
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

    [host addSubview:button];
    [host bringSubviewToFront:button];
    self.button = button;
    self.host = host;

    [self restorePosition];
    [self markActive];
}

#pragma mark - Position

- (CGRect)hostBounds {
    UIWindow *host = self.host ?: [self hostWindow];
    return host ? host.bounds : UIScreen.mainScreen.bounds;
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
}

/// Keeps the button on screen after the app rotates, since the window's
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
    [self markActive];

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled) {
        // Snap to whichever edge is nearer, so it never floats mid-screen over
        // something the user is trying to tap.
        BOOL onLeft = CGRectGetMidX(frame) < CGRectGetMidX(bounds);
        CGFloat y = MAX(kEdgeInset,
                        MIN(frame.origin.y, CGRectGetHeight(bounds) - kButtonSize - kEdgeInset));
        CGFloat x = onLeft ? kEdgeInset : CGRectGetWidth(bounds) - kButtonSize - kEdgeInset;

        [UIView animateWithDuration:0.2 animations:^{
            self.button.frame = CGRectMake(x, y, kButtonSize, kButtonSize);
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

#pragma mark - Action

- (void)tapped {
    [self markActive];

    NSString *scheme = NSUserDefaults.lcAppUrlScheme;
    if (!scheme) return;
    NSURL *url = [NSURL URLWithString:
                  [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=ui", scheme]];

    UIViewController *presenter = self.button.window.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter) {
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithURL:url];
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Return to Ember Connect"
                         message:@"This app will close. Anything it has not saved will be lost."
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Return"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithURL:url];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Stay"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [presenter presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Installation

static void EmberInstallReturnButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
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

    // The guest has no windows yet at constructor time. Wait for it to come
    // up, then re-assert on every activation: a guest that creates its own
    // window later would otherwise cover the button.
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification,
                                      UISceneDidActivateNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
            EmberInstallReturnButton();
        }];
    }

    // Rotation swaps the host window's bounds underneath the button, which
    // would otherwise leave it pinned to a coordinate that is now off screen.
    [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        [[EmberReturnButtonController shared] clampIntoBounds];
    }];
}
