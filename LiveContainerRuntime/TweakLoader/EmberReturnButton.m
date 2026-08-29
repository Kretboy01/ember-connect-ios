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

#pragma mark - Window

/// Only the button itself is interactive; every other point falls through to
/// the guest app, which is otherwise unaware this window exists.
@interface EmberReturnWindow : UIWindow
@end

@implementation EmberReturnWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self || hit == self.rootViewController.view ? nil : hit;
}

@end

#pragma mark - Controller

@interface EmberReturnButtonController : NSObject
@property (nonatomic, strong) EmberReturnWindow *window;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) NSTimer *idleTimer;
@end

@implementation EmberReturnButtonController

+ (instancetype)shared {
    static EmberReturnButtonController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [EmberReturnButtonController new]; });
    return shared;
}

- (UIWindowScene *)activeScene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
    }
    return nil;
}

- (void)install {
    if (self.window) {
        // The guest may have created windows above ours since last time.
        [self raise];
        return;
    }
    UIWindowScene *scene = [self activeScene];
    if (!scene) return;

    EmberReturnWindow *window = [[EmberReturnWindow alloc] initWithWindowScene:scene];
    window.backgroundColor = UIColor.clearColor;
    window.rootViewController = [UIViewController new];
    window.rootViewController.view.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = YES;
    window.hidden = NO;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake(0, 0, kButtonSize, kButtonSize);
    button.backgroundColor = [UIColor colorWithRed:0.98 green:0.42 blue:0.13 alpha:1.0];
    button.layer.cornerRadius = kButtonSize / 2.0;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.35;
    button.layer.shadowRadius = 6.0;
    button.layer.shadowOffset = CGSizeMake(0, 2);
    button.tintColor = UIColor.whiteColor;
    button.accessibilityLabel = @"Return to Ember Connect";

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

    [window.rootViewController.view addSubview:button];
    self.window = window;
    self.button = button;

    [self restorePosition];
    [self raise];
    [self markActive];
}

- (void)raise {
    // Above everything the guest is likely to create, but below the system
    // alert level so its own dialogs still win.
    self.window.windowLevel = UIWindowLevelAlert - 1;
    self.window.hidden = NO;
}

#pragma mark - Position

- (CGRect)sceneBounds {
    UIWindowScene *scene = self.window.windowScene ?: [self activeScene];
    return scene ? scene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
}

- (void)restorePosition {
    CGRect bounds = [self sceneBounds];
    NSUserDefaults *defaults = NSUserDefaults.lcUserDefaults;
    id storedY = [defaults objectForKey:kEmberReturnButtonYKey];
    CGFloat y = storedY ? [storedY doubleValue] : CGRectGetMidY(bounds) - kButtonSize / 2.0;
    BOOL onLeft = [defaults boolForKey:kEmberReturnButtonLeftKey];

    y = MAX(kEdgeInset, MIN(y, CGRectGetHeight(bounds) - kButtonSize - kEdgeInset));
    CGFloat x = onLeft ? kEdgeInset : CGRectGetWidth(bounds) - kButtonSize - kEdgeInset;
    self.button.frame = CGRectMake(x, y, kButtonSize, kButtonSize);
}

- (void)panned:(UIPanGestureRecognizer *)pan {
    CGRect bounds = [self sceneBounds];
    CGPoint translation = [pan translationInView:self.window.rootViewController.view];
    CGRect frame = self.button.frame;

    frame.origin.x += translation.x;
    frame.origin.y += translation.y;
    [pan setTranslation:CGPointZero inView:self.window.rootViewController.view];
    self.button.frame = frame;
    [self markActive];

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled) {
        // Snap to whichever edge is nearer, so it never floats mid-screen
        // over something the user is trying to tap.
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
    self.idleTimer = [NSTimer scheduledTimerWithTimeInterval:kIdleDelay
                                                     repeats:NO
                                                       block:^(NSTimer *timer) {
        [UIView animateWithDuration:0.4 animations:^{
            self.button.alpha = kIdleAlpha;
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

    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
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
    [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) { EmberInstallReturnButton(); }];
    [NSNotificationCenter.defaultCenter
        addObserverForName:UISceneDidActivateNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) { EmberInstallReturnButton(); }];
}
