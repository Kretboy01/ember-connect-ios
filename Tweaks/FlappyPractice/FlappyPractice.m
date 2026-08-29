// FlappyPractice.m — Ember Connect practice controls for Brandon Plank's Flappy Bird.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <SpriteKit/SpriteKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString *const EmberSpeedKey = @"EmberFlappyPractice.speed";
static NSString *const EmberWideGapsKey = @"EmberFlappyPractice.wideGaps";
static NSString *const EmberGhostModeKey = @"EmberFlappyPractice.ghostMode";
static const CGFloat EmberExtraGap = 34.0;
static CGFloat EmberCurrentSpeedFactor = 1.0;
static void (*EmberOriginalApplyImpulse)(SKPhysicsBody *, SEL, CGVector);

static BOOL EmberIsFlappyBirdBody(SKPhysicsBody *body) {
    SKNode *node = body.node;
    if (!node || body.categoryBitMask != 1) return NO;
    return [NSStringFromClass(node.scene.class) containsString:@"GameScene"];
}

static void EmberApplyImpulse(SKPhysicsBody *body, SEL selector, CGVector impulse) {
    if (EmberCurrentSpeedFactor < 0.999 && EmberIsFlappyBirdBody(body)) {
        impulse.dx *= EmberCurrentSpeedFactor;
        impulse.dy *= EmberCurrentSpeedFactor;
    }
    EmberOriginalApplyImpulse(body, selector, impulse);
}

static void EmberInstallPhysicsHook(void) {
    Method method = class_getInstanceMethod(SKPhysicsBody.class, @selector(applyImpulse:));
    if (!method) return;
    EmberOriginalApplyImpulse = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)EmberApplyImpulse);
}

static void EmberWritePracticeStatus(NSString *state) {
    NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!cache) return;
    NSString *folder = [cache stringByAppendingPathComponent:@"EmberConnect"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    [@{
        @"state": state ?: @"unknown",
        @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
        @"speed": @(EmberCurrentSpeedFactor),
        @"updatedAt": @([NSDate.date timeIntervalSince1970])
    } writeToFile:[folder stringByAppendingPathComponent:@"FlappyPracticeStatus.plist"] atomically:YES];
}

@interface EmberFlappyPracticeController : NSObject
@property(nonatomic, weak) UIButton *button;
@property(nonatomic, weak) UIWindow *hostWindow;
@property(nonatomic, strong) NSTimer *keepAliveTimer;
@property(nonatomic, strong) NSMapTable<SKScene *, NSNumber *> *originalSpeeds;
@property(nonatomic, strong) NSMapTable<SKScene *, NSValue *> *originalGravities;
@property(nonatomic, strong) NSMapTable<SKScene *, NSNumber *> *appliedSpeedFactors;
@property(nonatomic, strong) NSMapTable<SKNode *, NSValue *> *originalPipePositions;
@property(nonatomic, strong) NSMapTable<SKPhysicsBody *, NSArray<NSNumber *> *> *originalMasks;
@property(nonatomic, assign) CGFloat speedFactor;
@property(nonatomic, assign) BOOL wideGapsEnabled;
@property(nonatomic, assign) BOOL ghostModeEnabled;
@end

@implementation EmberFlappyPracticeController

+ (instancetype)sharedController {
    static EmberFlappyPracticeController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [EmberFlappyPracticeController new];
        controller.originalSpeeds = [NSMapTable weakToStrongObjectsMapTable];
        controller.originalGravities = [NSMapTable weakToStrongObjectsMapTable];
        controller.appliedSpeedFactors = [NSMapTable weakToStrongObjectsMapTable];
        controller.originalPipePositions = [NSMapTable weakToStrongObjectsMapTable];
        controller.originalMasks = [NSMapTable weakToStrongObjectsMapTable];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSNumber *savedSpeed = [defaults objectForKey:EmberSpeedKey];
        controller.speedFactor = savedSpeed ? savedSpeed.doubleValue : 1.0;
        controller.wideGapsEnabled = [defaults boolForKey:EmberWideGapsKey];
        controller.ghostModeEnabled = [defaults boolForKey:EmberGhostModeKey];
        EmberCurrentSpeedFactor = controller.speedFactor;
    });
    return controller;
}

- (UIWindow *)guestWindow {
    UIWindow *best = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || !window.rootViewController || window.windowLevel > UIWindowLevelNormal) continue;
            if (!best || window.isKeyWindow) best = window;
        }
    }
    return best;
}

- (void)collectSpriteKitScenesInView:(UIView *)view into:(NSMutableSet<SKScene *> *)scenes {
    if ([view isKindOfClass:SKView.class] && ((SKView *)view).scene) [scenes addObject:((SKView *)view).scene];
    for (UIView *child in view.subviews) [self collectSpriteKitScenesInView:child into:scenes];
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

- (void)visitNode:(SKNode *)node block:(void (^)(SKNode *node))block {
    block(node);
    for (SKNode *child in node.children) [self visitNode:child block:block];
}

- (void)scaleBirdVelocityInScene:(SKScene *)scene from:(CGFloat)oldFactor to:(CGFloat)newFactor {
    if (oldFactor <= 0 || fabs(oldFactor - newFactor) < 0.001) return;
    CGFloat ratio = newFactor / oldFactor;
    [self visitNode:scene block:^(SKNode *node) {
        SKPhysicsBody *body = node.physicsBody;
        if (!EmberIsFlappyBirdBody(body)) return;
        CGVector velocity = body.velocity;
        body.velocity = CGVectorMake(velocity.dx * ratio, velocity.dy * ratio);
    }];
}

- (void)applySpeedToScene:(SKScene *)scene {
    NSNumber *originalSpeed = [self.originalSpeeds objectForKey:scene];
    if (!originalSpeed) {
        originalSpeed = @(scene.speed);
        [self.originalSpeeds setObject:originalSpeed forKey:scene];
    }
    NSValue *originalGravity = [self.originalGravities objectForKey:scene];
    if (!originalGravity) {
        originalGravity = [NSValue valueWithCGVector:scene.physicsWorld.gravity];
        [self.originalGravities setObject:originalGravity forKey:scene];
    }
    NSNumber *lastFactor = [self.appliedSpeedFactors objectForKey:scene];
    CGFloat previous = lastFactor ? lastFactor.doubleValue : 1.0;
    [self scaleBirdVelocityInScene:scene from:previous to:self.speedFactor];
    [self.appliedSpeedFactors setObject:@(self.speedFactor) forKey:scene];
    scene.speed = originalSpeed.doubleValue * self.speedFactor;
    CGVector gravity = originalGravity.CGVectorValue;
    CGFloat gravityScale = self.speedFactor * self.speedFactor;
    scene.physicsWorld.gravity = CGVectorMake(gravity.dx * gravityScale, gravity.dy * gravityScale);
}

- (void)applySpeedToVisibleScenes {
    EmberCurrentSpeedFactor = self.speedFactor;
    for (SKScene *scene in [self visibleSpriteKitScenes]) [self applySpeedToScene:scene];
}

- (void)adjustPipeChildrenOfNode:(SKNode *)parent {
    NSMutableArray<SKNode *> *pipes = [NSMutableArray new];
    for (SKNode *child in parent.children) if (child.physicsBody.categoryBitMask == 4) [pipes addObject:child];
    if (pipes.count < 2) return;
    [pipes sortUsingComparator:^NSComparisonResult(SKNode *a, SKNode *b) {
        NSValue *aSaved = [self.originalPipePositions objectForKey:a];
        NSValue *bSaved = [self.originalPipePositions objectForKey:b];
        CGFloat aY = (aSaved ?: [NSValue valueWithCGPoint:a.position]).CGPointValue.y;
        CGFloat bY = (bSaved ?: [NSValue valueWithCGPoint:b.position]).CGPointValue.y;
        return aY < bY ? NSOrderedAscending : (aY > bY ? NSOrderedDescending : NSOrderedSame);
    }];
    for (NSUInteger index = 0; index < pipes.count; index++) {
        SKNode *pipe = pipes[index];
        NSValue *saved = [self.originalPipePositions objectForKey:pipe];
        if (!saved) {
            saved = [NSValue valueWithCGPoint:pipe.position];
            [self.originalPipePositions setObject:saved forKey:pipe];
        }
        CGPoint position = saved.CGPointValue;
        position.y += index < pipes.count / 2 ? -EmberExtraGap : EmberExtraGap;
        pipe.position = position;
    }
}

- (void)applyWideGapsToVisibleScenes {
    for (SKScene *scene in [self visibleSpriteKitScenes]) {
        [self visitNode:scene block:^(SKNode *node) { [self adjustPipeChildrenOfNode:node]; }];
    }
}

- (void)restorePipePositions {
    for (SKNode *pipe in self.originalPipePositions.keyEnumerator) {
        NSValue *position = [self.originalPipePositions objectForKey:pipe];
        if (pipe && position) pipe.position = position.CGPointValue;
    }
    [self.originalPipePositions removeAllObjects];
}

- (void)applyGhostModeToVisibleScenes {
    for (SKScene *scene in [self visibleSpriteKitScenes]) {
        [self visitNode:scene block:^(SKNode *node) {
            SKPhysicsBody *body = node.physicsBody;
            uint32_t category = body.categoryBitMask;
            if (!body || (category != 1 && category != 2 && category != 4)) return;
            if (![self.originalMasks objectForKey:body]) {
                [self.originalMasks setObject:@[@(body.collisionBitMask), @(body.contactTestBitMask)] forKey:body];
            }
            body.collisionBitMask = 0;
            body.contactTestBitMask = 0;
        }];
    }
}

- (void)restoreCollisionMasks {
    for (SKPhysicsBody *body in self.originalMasks.keyEnumerator) {
        NSArray<NSNumber *> *masks = [self.originalMasks objectForKey:body];
        if (body && masks.count == 2) {
            body.collisionBitMask = masks[0].unsignedIntValue;
            body.contactTestBitMask = masks[1].unsignedIntValue;
        }
    }
    [self.originalMasks removeAllObjects];
}

- (void)maintainEnabledTweaks {
    [self applySpeedToVisibleScenes];
    if (self.wideGapsEnabled) [self applyWideGapsToVisibleScenes];
    if (self.ghostModeEnabled) [self applyGhostModeToVisibleScenes];
}

- (void)saveSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:self.speedFactor forKey:EmberSpeedKey];
    [defaults setBool:self.wideGapsEnabled forKey:EmberWideGapsKey];
    [defaults setBool:self.ghostModeEnabled forKey:EmberGhostModeKey];
}

- (void)updateButtonTitle {
    NSString *title = self.speedFactor > 0.99 ? @"EC 1x" : [NSString stringWithFormat:@"EC %.2gx", self.speedFactor];
    [self.button setTitle:title forState:UIControlStateNormal];
    BOOL active = self.speedFactor < 0.99 || self.wideGapsEnabled || self.ghostModeEnabled;
    self.button.backgroundColor = active ? [UIColor colorWithRed:0.98 green:0.38 blue:0.10 alpha:0.94]
                                         : [UIColor colorWithWhite:0.10 alpha:0.82];
}

- (UIViewController *)topViewController {
    UIViewController *controller = self.hostWindow.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller;
}

- (NSString *)markedTitle:(NSString *)title selected:(BOOL)selected {
    return [NSString stringWithFormat:@"%@ %@", selected ? @"✓" : @"  ", title];
}

- (void)setPracticeSpeed:(CGFloat)factor {
    self.speedFactor = factor;
    [self saveSettings];
    [self applySpeedToVisibleScenes];
    [self updateButtonTitle];
    EmberWritePracticeStatus(@"speed-changed");
}

- (void)toggleWideGaps {
    self.wideGapsEnabled = !self.wideGapsEnabled;
    if (self.wideGapsEnabled) [self applyWideGapsToVisibleScenes]; else [self restorePipePositions];
    [self saveSettings];
    [self updateButtonTitle];
    EmberWritePracticeStatus(self.wideGapsEnabled ? @"wide-gaps-on" : @"wide-gaps-off");
}

- (void)toggleGhostMode {
    self.ghostModeEnabled = !self.ghostModeEnabled;
    if (self.ghostModeEnabled) [self applyGhostModeToVisibleScenes]; else [self restoreCollisionMasks];
    [self saveSettings];
    [self updateButtonTitle];
    EmberWritePracticeStatus(self.ghostModeEnabled ? @"ghost-mode-on" : @"ghost-mode-off");
}

- (void)resetAllTweaks {
    self.speedFactor = EmberCurrentSpeedFactor = 1.0;
    [self applySpeedToVisibleScenes];
    self.wideGapsEnabled = self.ghostModeEnabled = NO;
    [self restorePipePositions];
    [self restoreCollisionMasks];
    [self saveSettings];
    [self updateButtonTitle];
    EmberWritePracticeStatus(@"reset");
}

- (void)tapped {
    UIViewController *presenter = [self topViewController];
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Flappy Practice"
                                                                   message:@"Speed changes include gravity and flap strength."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSNumber *speed in @[@1.0, @0.75, @0.5]) {
        CGFloat factor = speed.doubleValue;
        NSString *name = factor > 0.99 ? @"Speed: Normal" : [NSString stringWithFormat:@"Speed: %.2gx", factor];
        NSString *title = [self markedTitle:name selected:fabs(self.speedFactor - factor) < 0.01];
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf setPracticeSpeed:factor];
        }]];
    }
    NSString *gaps = [self markedTitle:@"Wide pipe gaps" selected:self.wideGapsEnabled];
    [menu addAction:[UIAlertAction actionWithTitle:gaps style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf toggleWideGaps];
    }]];
    NSString *ghost = [self markedTitle:@"Ghost mode (no crashes)" selected:self.ghostModeEnabled];
    [menu addAction:[UIAlertAction actionWithTitle:ghost style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf toggleGhostMode];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Reset all" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf resetAllTweaks];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)install {
    UIWindow *host = [self guestWindow];
    if (!host) return;
    if (self.button.superview == host) {
        [host bringSubviewToFront:self.button];
        [self maintainEnabledTweaks];
        return;
    }
    [self.button removeFromSuperview];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(MAX(8, CGRectGetWidth(host.bounds) - 84), MAX(8, CGRectGetHeight(host.bounds) - 108), 72, 40);
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
    button.accessibilityLabel = @"Flappy Practice menu";
    button.accessibilityHint = @"Opens speed, wide gap, and ghost mode controls";
    [button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [host addSubview:button];
    [host bringSubviewToFront:button];
    self.button = button;
    self.hostWindow = host;
    [self updateButtonTitle];
    [self maintainEnabledTweaks];
    EmberWritePracticeStatus(@"practice-menu-installed");
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

__attribute__((constructor))
static void EmberFlappyPracticeInit(void) {
    EmberInstallPhysicsHook();
    dispatch_async(dispatch_get_main_queue(), ^{
        EmberWritePracticeStatus(@"constructor-ran");
        EmberFlappyPracticeController *controller = [EmberFlappyPracticeController sharedController];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [controller start]; }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [controller stop]; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [controller start]; });
    });
}
