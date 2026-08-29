//
// FlappyPractice.m
// Ember Connect example tweak
//
// A deliberately small tweak that demonstrates the complete Ember Connect
// tweak path without relying on private APIs or a specific game's internals.
// It finds SpriteKit scenes in the guest app and lets the player toggle them
// between their original speed and 0.55x speed.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <SpriteKit/SpriteKit.h>
#import <QuartzCore/QuartzCore.h>

static const CGFloat EmberPracticeSlowFactor = 0.55;

static void EmberWritePracticeStatus(NSString *state) {
    NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                           NSUserDomainMask,
                                                           YES).firstObject;
    if (!cache) return;
    NSString *folder = [cache stringByAppendingPathComponent:@"EmberConnect"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    NSDictionary *status = @{
        @"state": state ?: @"unknown",
        @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
        @"updatedAt": @([NSDate.date timeIntervalSince1970])
    };
    [status writeToFile:[folder stringByAppendingPathComponent:@"FlappyPracticeStatus.plist"]
             atomically:YES];
}

@interface EmberFlappyPracticeController : NSObject
@property(nonatomic, weak) UIButton *button;
@property(nonatomic, weak) UIWindow *hostWindow;
@property(nonatomic, strong) NSTimer *keepAliveTimer;
@property(nonatomic, strong) NSMapTable<SKScene *, NSNumber *> *originalSpeeds;
@property(nonatomic, assign, getter=isSlowMotionEnabled) BOOL slowMotionEnabled;
@end

@implementation EmberFlappyPracticeController

+ (instancetype)sharedController {
    static EmberFlappyPracticeController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [EmberFlappyPracticeController new];
        controller.originalSpeeds = [NSMapTable weakToStrongObjectsMapTable];
    });
    return controller;
}

- (UIWindow *)guestWindow {
    UIWindow *best = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || !window.rootViewController) continue;
            if (window.windowLevel > UIWindowLevelNormal) continue;
            if (!best || window.isKeyWindow) best = window;
        }
    }
    return best;
}

- (void)collectSpriteKitScenesInView:(UIView *)view into:(NSMutableSet<SKScene *> *)scenes {
    if ([view isKindOfClass:SKView.class]) {
        SKScene *scene = ((SKView *)view).scene;
        if (scene) [scenes addObject:scene];
    }
    for (UIView *child in view.subviews) {
        [self collectSpriteKitScenesInView:child into:scenes];
    }
}

- (NSSet<SKScene *> *)visibleSpriteKitScenes {
    NSMutableSet<SKScene *> *scenes = [NSMutableSet new];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden) [self collectSpriteKitScenesInView:window into:scenes];
        }
    }
    return scenes;
}

- (BOOL)applySlowMotionToVisibleScenes {
    NSSet<SKScene *> *scenes = [self visibleSpriteKitScenes];
    for (SKScene *scene in scenes) {
        NSNumber *original = [self.originalSpeeds objectForKey:scene];
        if (!original) {
            original = @(scene.speed);
            [self.originalSpeeds setObject:original forKey:scene];
        }
        scene.speed = original.doubleValue * EmberPracticeSlowFactor;
    }
    EmberWritePracticeStatus(scenes.count > 0 ? @"slow-motion-applied" : @"no-spritekit-scene");
    return scenes.count > 0;
}

- (void)restoreOriginalSpeeds {
    for (SKScene *scene in self.originalSpeeds.keyEnumerator) {
        NSNumber *speed = [self.originalSpeeds objectForKey:scene];
        if (scene && speed) scene.speed = speed.doubleValue;
    }
    [self.originalSpeeds removeAllObjects];
}

- (void)updateButtonTitle {
    NSString *title = self.isSlowMotionEnabled ? @"0.55x" : @"1x";
    [self.button setTitle:title forState:UIControlStateNormal];
    self.button.backgroundColor = self.isSlowMotionEnabled
        ? [UIColor colorWithRed:0.98 green:0.38 blue:0.10 alpha:0.94]
        : [UIColor colorWithWhite:0.10 alpha:0.82];
}

- (void)showNoSceneFeedback {
    [self.button setTitle:@"No SK" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self updateButtonTitle];
    });
}

- (void)tapped {
    if (self.isSlowMotionEnabled) {
        self.slowMotionEnabled = NO;
        [self restoreOriginalSpeeds];
        [self updateButtonTitle];
        return;
    }

    if (![self applySlowMotionToVisibleScenes]) {
        [self showNoSceneFeedback];
        return;
    }
    self.slowMotionEnabled = YES;
    [self updateButtonTitle];
}

- (void)install {
    UIWindow *host = [self guestWindow];
    if (!host) return;

    if (self.button.superview == host) {
        [host bringSubviewToFront:self.button];
        if (self.isSlowMotionEnabled) [self applySlowMotionToVisibleScenes];
        return;
    }

    [self.button removeFromSuperview];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(MAX(8, CGRectGetWidth(host.bounds) - 74),
                              MAX(8, CGRectGetHeight(host.bounds) - 108),
                              62, 38);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    button.layer.cornerRadius = 12;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.24].CGColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.3;
    button.layer.shadowRadius = 4;
    button.tintColor = UIColor.whiteColor;
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold];
    button.accessibilityLabel = @"Flappy Practice speed";
    button.accessibilityHint = @"Toggles SpriteKit scene speed between normal and 0.55 times";
    [button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];

    [host addSubview:button];
    [host bringSubviewToFront:button];
    self.button = button;
    self.hostWindow = host;
    [self updateButtonTitle];
    EmberWritePracticeStatus(@"button-installed");
}

- (void)start {
    [self install];
    [self.keepAliveTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf install];
    }];
}

- (void)stop {
    [self.keepAliveTimer invalidate];
    self.keepAliveTimer = nil;
}

@end

__attribute__((constructor))
static void EmberFlappyPracticeInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        EmberWritePracticeStatus(@"constructor-ran");
        EmberFlappyPracticeController *controller = [EmberFlappyPracticeController sharedController];

        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) { [controller start]; }];
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationWillResignActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) { [controller stop]; }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [controller start]; });
    });
}
