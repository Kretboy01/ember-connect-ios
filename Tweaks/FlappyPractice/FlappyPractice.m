// FlappyPractice.m — Ember Connect practice controls for Brandon Plank's Flappy Bird.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <SpriteKit/SpriteKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// MARK: - Constants & Settings Keys
static NSString *const kEmberSpeedKey = @"EmberFlappyPractice.speed";
static NSString *const kEmberGravityKey = @"EmberFlappyPractice.gravity";
static NSString *const kEmberFlapKey = @"EmberFlappyPractice.flap";
static NSString *const kEmberWideGapsKey = @"EmberFlappyPractice.wideGaps";
static NSString *const kEmberGhostModeKey = @"EmberFlappyPractice.ghostMode";
static NSString *const kEmberAutoPilotKey = @"EmberFlappyPractice.autoPilot";
static NSString *const kEmberScoreMultKey = @"EmberFlappyPractice.scoreMult";
static NSString *const kEmberNightModeKey = @"EmberFlappyPractice.nightMode";
static NSString *const kEmberBirdTrailKey = @"EmberFlappyPractice.birdTrail";
static NSString *const kEmberPipeTintKey = @"EmberFlappyPractice.pipeTint";
static NSString *const kEmberHitboxKey = @"EmberFlappyPractice.hitbox";
static NSString *const kEmberStatsHudKey = @"EmberFlappyPractice.statsHud";

static const CGFloat EmberExtraGap = 34.0;

// MARK: - Global Variables for Hooks
static CGFloat gEmberSpeedFactor = 1.0;
static CGFloat gEmberGravityFactor = 1.0;
static CGFloat gEmberFlapFactor = 1.0;
static void (*OriginalApplyImpulse)(SKPhysicsBody *, SEL, CGVector);

static BOOL EmberIsFlappyBirdBody(SKPhysicsBody *body) {
    SKNode *node = body.node;
    if (!node || body.categoryBitMask != 1) return NO;
    return [NSStringFromClass(node.scene.class) containsString:@"GameScene"];
}

static void HookedApplyImpulse(SKPhysicsBody *body, SEL selector, CGVector impulse) {
    if (EmberIsFlappyBirdBody(body)) {
        if (gEmberSpeedFactor < 0.999) {
            impulse.dx *= gEmberSpeedFactor;
            impulse.dy *= gEmberSpeedFactor;
        }
        if (impulse.dy > 0 && fabs(gEmberFlapFactor - 1.0) > 0.001) {
            impulse.dy *= gEmberFlapFactor;
        }
    }
    OriginalApplyImpulse(body, selector, impulse);
}

static void EmberInstallPhysicsHook(void) {
    Method m = class_getInstanceMethod(SKPhysicsBody.class, @selector(applyImpulse:));
    if (m) {
        OriginalApplyImpulse = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)HookedApplyImpulse);
    }
}

static void EmberWritePracticeStatus(NSString *state) {
    NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!cache) return;
    NSString *folder = [cache stringByAppendingPathComponent:@"EmberConnect"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    [@{
        @"state": state ?: @"unknown",
        @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
        @"speed": @(gEmberSpeedFactor),
        @"gravity": @(gEmberGravityFactor),
        @"flap": @(gEmberFlapFactor),
        @"updatedAt": @([NSDate.date timeIntervalSince1970])
    } writeToFile:[folder stringByAppendingPathComponent:@"FlappyPracticeStatus.plist"] atomically:YES];
}

// MARK: - Main Controller
@interface EmberFlappyPracticeController : NSObject
@property (nonatomic, weak) UIButton *button;
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) UIView *statsHud;
@property (nonatomic, strong) UILabel *statsHudLabel;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) NSTimer *keepAliveTimer;

@property (nonatomic, assign) NSInteger frames;
@property (nonatomic, assign) CFTimeInterval lastFrameTime;
@property (nonatomic, assign) double currentFPS;
@property (nonatomic, assign) NSInteger gamesPlayed;
@property (nonatomic, assign) NSInteger sessionBestScore;

@property (nonatomic, strong) NSMapTable<SKScene *, NSNumber *> *originalSpeeds;
@property (nonatomic, strong) NSMapTable<SKScene *, NSValue *> *originalGravities;
@property (nonatomic, strong) NSMapTable<SKScene *, NSNumber *> *appliedSpeedFactors;
@property (nonatomic, strong) NSMapTable<SKNode *, NSValue *> *originalPipePositions;
@property (nonatomic, strong) NSMapTable<SKPhysicsBody *, NSArray<NSNumber *> *> *originalMasks;

@property (nonatomic, assign) CGFloat speedFactor;
@property (nonatomic, assign) CGFloat gravityFactor;
@property (nonatomic, assign) CGFloat flapFactor;
@property (nonatomic, assign) BOOL wideGapsEnabled;
@property (nonatomic, assign) BOOL ghostModeEnabled;
@property (nonatomic, assign) BOOL autoPilotEnabled;
@property (nonatomic, assign) NSInteger scoreMultiplier;
@property (nonatomic, assign) BOOL nightModeEnabled;
@property (nonatomic, assign) BOOL birdTrailEnabled;
@property (nonatomic, assign) BOOL pipeTintEnabled;
@property (nonatomic, assign) BOOL hitboxVisualizerEnabled;
@property (nonatomic, assign) BOOL statsHudEnabled;

+ (instancetype)sharedController;
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
        NSNumber *savedSpeed = [defaults objectForKey:kEmberSpeedKey];
        controller.speedFactor = savedSpeed ? savedSpeed.doubleValue : 1.0;
        NSNumber *savedGravity = [defaults objectForKey:kEmberGravityKey];
        controller.gravityFactor = savedGravity ? savedGravity.doubleValue : 1.0;
        NSNumber *savedFlap = [defaults objectForKey:kEmberFlapKey];
        controller.flapFactor = savedFlap ? savedFlap.doubleValue : 1.0;
        
        controller.wideGapsEnabled = [defaults boolForKey:kEmberWideGapsKey];
        controller.ghostModeEnabled = [defaults boolForKey:kEmberGhostModeKey];
        controller.autoPilotEnabled = [defaults boolForKey:kEmberAutoPilotKey];
        controller.scoreMultiplier = [defaults objectForKey:kEmberScoreMultKey] ? [defaults integerForKey:kEmberScoreMultKey] : 1;
        controller.nightModeEnabled = [defaults boolForKey:kEmberNightModeKey];
        controller.birdTrailEnabled = [defaults boolForKey:kEmberBirdTrailKey];
        controller.pipeTintEnabled = [defaults boolForKey:kEmberPipeTintKey];
        controller.hitboxVisualizerEnabled = [defaults boolForKey:kEmberHitboxKey];
        controller.statsHudEnabled = [defaults boolForKey:kEmberStatsHudKey];
        
        gEmberSpeedFactor = controller.speedFactor;
        gEmberGravityFactor = controller.gravityFactor;
        gEmberFlapFactor = controller.flapFactor;
        
        controller.displayLink = [CADisplayLink displayLinkWithTarget:controller selector:@selector(tick:)];
        [controller.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
    return controller;
}

- (void)saveSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:self.speedFactor forKey:kEmberSpeedKey];
    [defaults setDouble:self.gravityFactor forKey:kEmberGravityKey];
    [defaults setDouble:self.flapFactor forKey:kEmberFlapKey];
    [defaults setBool:self.wideGapsEnabled forKey:kEmberWideGapsKey];
    [defaults setBool:self.ghostModeEnabled forKey:kEmberGhostModeKey];
    [defaults setBool:self.autoPilotEnabled forKey:kEmberAutoPilotKey];
    [defaults setInteger:self.scoreMultiplier forKey:kEmberScoreMultKey];
    [defaults setBool:self.nightModeEnabled forKey:kEmberNightModeKey];
    [defaults setBool:self.birdTrailEnabled forKey:kEmberBirdTrailKey];
    [defaults setBool:self.pipeTintEnabled forKey:kEmberPipeTintKey];
    [defaults setBool:self.hitboxVisualizerEnabled forKey:kEmberHitboxKey];
    [defaults setBool:self.statsHudEnabled forKey:kEmberStatsHudKey];
}

- (UIWindow *)guestWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (!window.hidden && window.rootViewController) return window;
            }
        }
    }
    return nil;
}

- (NSSet<SKScene *> *)visibleSpriteKitScenes {
    NSMutableSet<SKScene *> *scenes = [NSMutableSet new];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            [self collectSpriteKitScenesInView:window into:scenes];
        }
    }
    return scenes;
}

- (void)collectSpriteKitScenesInView:(UIView *)view into:(NSMutableSet<SKScene *> *)scenes {
    if ([view isKindOfClass:SKView.class] && ((SKView *)view).scene) [scenes addObject:((SKView *)view).scene];
    for (UIView *child in view.subviews) [self collectSpriteKitScenesInView:child into:scenes];
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

- (void)applySpeedAndGravityToScene:(SKScene *)scene {
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
    CGFloat effectiveSpeedSq = self.speedFactor * self.speedFactor;
    scene.physicsWorld.gravity = CGVectorMake(gravity.dx * effectiveSpeedSq, gravity.dy * effectiveSpeedSq * self.gravityFactor);
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

- (void)restorePipePositions {
    for (SKNode *pipe in self.originalPipePositions.keyEnumerator) {
        NSValue *position = [self.originalPipePositions objectForKey:pipe];
        if (pipe && position) pipe.position = position.CGPointValue;
    }
    [self.originalPipePositions removeAllObjects];
}

- (void)applyGhostModeToScene:(SKScene *)scene {
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

- (void)applyVisualsAndAutoPilotToScene:(SKScene *)scene {
    if (self.nightModeEnabled) {
        if (![scene childNodeWithName:@"EmberNightMode"]) {
            SKSpriteNode *night = [SKSpriteNode spriteNodeWithColor:[UIColor colorWithWhite:0 alpha:0.45] size:scene.size];
            night.position = CGPointMake(scene.size.width / 2.0, scene.size.height / 2.0);
            night.zPosition = 900;
            night.name = @"EmberNightMode";
            [scene addChild:night];
        }
    } else {
        [[scene childNodeWithName:@"EmberNightMode"] removeFromParent];
    }
    
    __block SKNode *birdNode = nil;
    __block NSMutableArray<SKNode *> *activePipes = [NSMutableArray new];
    
    [self visitNode:scene block:^(SKNode *node) {
        if (node.physicsBody.categoryBitMask == 1) {
            birdNode = node;
            if (self.birdTrailEnabled) {
                if (![node childNodeWithName:@"EmberTrail"]) {
                    SKEmitterNode *emitter = [SKEmitterNode new];
                    emitter.name = @"EmberTrail";
                    emitter.particleBirthRate = 40;
                    emitter.particleLifetime = 0.6;
                    emitter.particlePositionRange = CGVectorMake(6, 6);
                    emitter.particleColor = [UIColor orangeColor];
                    emitter.particleColorBlendFactor = 1.0;
                    emitter.particleAlpha = 0.8;
                    emitter.particleAlphaSpeed = -1.2;
                    emitter.particleScale = 0.15;
                    emitter.particleScaleSpeed = -0.1;
                    emitter.zPosition = -1;
                    [node addChild:emitter];
                }
            } else {
                [[node childNodeWithName:@"EmberTrail"] removeFromParent];
            }
        }
        if (node.physicsBody.categoryBitMask == 4 && [node isKindOfClass:SKSpriteNode.class]) {
            [activePipes addObject:node];
            SKSpriteNode *sprite = (SKSpriteNode *)node;
            if (self.pipeTintEnabled) {
                sprite.color = [UIColor colorWithRed:0.7 green:0.2 blue:0.9 alpha:1.0];
                sprite.colorBlendFactor = 0.55;
            } else {
                sprite.colorBlendFactor = 0.0;
            }
        }
        if (self.hitboxVisualizerEnabled && node.physicsBody) {
            if (![node childNodeWithName:@"EmberHitbox"]) {
                CGRect rect = CGRectMake(-15, -15, 30, 30);
                SKShapeNode *shape = [SKShapeNode shapeNodeWithRect:rect cornerRadius:4];
                shape.strokeColor = [UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:0.9];
                shape.lineWidth = 1.5;
                shape.name = @"EmberHitbox";
                shape.zPosition = 1500;
                [node addChild:shape];
            }
        } else if (!self.hitboxVisualizerEnabled && node.physicsBody) {
            [[node childNodeWithName:@"EmberHitbox"] removeFromParent];
        }
        if (self.scoreMultiplier > 1 && [node isKindOfClass:SKLabelNode.class]) {
            SKLabelNode *label = (SKLabelNode *)node;
            NSInteger val = [label.text integerValue];
            if (val > 0 && ![label.name containsString:@"EmberScore"]) {
                label.name = @"EmberScoreMod";
                label.text = [NSString stringWithFormat:@"%ld", (long)(val * self.scoreMultiplier)];
            }
        }
    }];
    
    if (self.autoPilotEnabled && birdNode && birdNode.physicsBody) {
        CGFloat targetY = scene.size.height * 0.5;
        SKNode *nearestPipe = nil;
        CGFloat minDistance = 99999.0;
        for (SKNode *pipe in activePipes) {
            CGPoint worldPos = [scene convertPoint:pipe.position fromNode:pipe.parent ?: scene];
            CGPoint birdPos = [scene convertPoint:birdNode.position fromNode:birdNode.parent ?: scene];
            CGFloat dx = worldPos.x - birdPos.x;
            if (dx > -30 && dx < minDistance) {
                minDistance = dx;
                nearestPipe = pipe;
            }
        }
        if (nearestPipe) {
            CGPoint pipeWorld = [scene convertPoint:nearestPipe.position fromNode:nearestPipe.parent ?: scene];
            targetY = pipeWorld.y;
        }
        CGPoint currentBirdPos = [scene convertPoint:birdNode.position fromNode:birdNode.parent ?: scene];
        if (currentBirdPos.y < targetY - 20.0 && birdNode.physicsBody.velocity.dy < 20) {
            birdNode.physicsBody.velocity = CGVectorMake(birdNode.physicsBody.velocity.dx, 0);
            [birdNode.physicsBody applyImpulse:CGVectorMake(0, 9.0 * self.flapFactor)];
        }
    }
}

- (void)maintainEnabledTweaks {
    gEmberSpeedFactor = self.speedFactor;
    gEmberGravityFactor = self.gravityFactor;
    gEmberFlapFactor = self.flapFactor;
    for (SKScene *scene in [self visibleSpriteKitScenes]) {
        [self applySpeedAndGravityToScene:scene];
        if (self.wideGapsEnabled) [self visitNode:scene block:^(SKNode *node) { [self adjustPipeChildrenOfNode:node]; }];
        if (self.ghostModeEnabled) [self applyGhostModeToScene:scene];
        [self applyVisualsAndAutoPilotToScene:scene];
    }
}

- (void)tick:(CADisplayLink *)link {
    CFTimeInterval dt = link.timestamp - self.lastFrameTime;
    self.frames++;
    if (dt >= 1.0) {
        self.currentFPS = self.frames / dt;
        self.frames = 0;
        self.lastFrameTime = link.timestamp;
    }
    [self maintainEnabledTweaks];
    if (self.statsHudEnabled && self.statsHudLabel && self.statsHud) {
        self.statsHud.hidden = NO;
        self.statsHudLabel.text = [NSString stringWithFormat:@"FPS: %.0f\nSpd: %.2gx  Grv: %.2gx\nFlp: %.2gx  Gap: %@",
                                   self.currentFPS, self.speedFactor, self.gravityFactor, self.flapFactor,
                                   self.wideGapsEnabled ? @"Wide" : @"Norm"];
    } else if (self.statsHud) {
        self.statsHud.hidden = YES;
    }
}

- (void)updateButtonTitle {
    if (!self.button) return;
    NSString *title = (fabs(self.speedFactor - 1.0) < 0.01) ? @"EC 1x" : [NSString stringWithFormat:@"EC %.2gx", self.speedFactor];
    [self.button setTitle:title forState:UIControlStateNormal];
    BOOL active = (fabs(self.speedFactor - 1.0) >= 0.01) || (fabs(self.gravityFactor - 1.0) >= 0.01) || (fabs(self.flapFactor - 1.0) >= 0.01) || self.wideGapsEnabled || self.ghostModeEnabled || self.autoPilotEnabled || self.nightModeEnabled || self.birdTrailEnabled || self.pipeTintEnabled || self.hitboxVisualizerEnabled || (self.scoreMultiplier > 1);
    self.button.backgroundColor = active ? [UIColor colorWithRed:0.98 green:0.38 blue:0.10 alpha:0.94] : [UIColor colorWithWhite:0.10 alpha:0.82];
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
    [self updateButtonTitle];
    EmberWritePracticeStatus(@"speed-changed");
}

- (void)setPracticeGravity:(CGFloat)factor {
    self.gravityFactor = factor;
    [self saveSettings];
    [self updateButtonTitle];
    EmberWritePracticeStatus(@"gravity-changed");
}

- (void)setPracticeFlap:(CGFloat)factor {
    self.flapFactor = factor;
    [self saveSettings];
    [self updateButtonTitle];
    EmberWritePracticeStatus(@"flap-changed");
}

- (void)resetAllTweaks {
    self.speedFactor = gEmberSpeedFactor = 1.0;
    self.gravityFactor = gEmberGravityFactor = 1.0;
    self.flapFactor = gEmberFlapFactor = 1.0;
    self.wideGapsEnabled = NO;
    self.ghostModeEnabled = NO;
    self.autoPilotEnabled = NO;
    self.scoreMultiplier = 1;
    self.nightModeEnabled = NO;
    self.birdTrailEnabled = NO;
    self.pipeTintEnabled = NO;
    self.hitboxVisualizerEnabled = NO;
    self.statsHudEnabled = NO;
    [self restorePipePositions];
    [self restoreCollisionMasks];
    [self saveSettings];
    [self updateButtonTitle];
    EmberWritePracticeStatus(@"reset");
}

- (void)showSpeedMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Game Speed" message:@"Coordinates scene speed, gravity, and bird velocity." preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    NSArray *speeds = @[@0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @2.0];
    for (NSNumber *spd in speeds) {
        CGFloat val = spd.doubleValue;
        NSString *name = (fabs(val - 1.0) < 0.01) ? @"1.0x (Normal)" : [NSString stringWithFormat:@"%.2gx", val];
        [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:name selected:fabs(self.speedFactor - val) < 0.01] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf setPracticeSpeed:val]; }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { [weakSelf tapped]; }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)showGravityMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Gravity Multiplier" message:@"Adjusts fall acceleration independently." preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    NSArray *gravities = @[@0.25, @0.5, @0.75, @1.0, @1.5, @2.0];
    for (NSNumber *num in gravities) {
        CGFloat val = num.doubleValue;
        NSString *name = (fabs(val - 1.0) < 0.01) ? @"1.0x (Normal)" : (val < 0.3 ? @"0.25x (Moon Gravity)" : [NSString stringWithFormat:@"%.2gx", val]);
        [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:name selected:fabs(self.gravityFactor - val) < 0.01] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf setPracticeGravity:val]; }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { [weakSelf tapped]; }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)showFlapMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Flap Power Boost" message:@"Scales the impulse applied when tapping to flap." preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    NSArray *flaps = @[@0.75, @1.0, @1.5, @2.0, @3.0];
    for (NSNumber *num in flaps) {
        CGFloat val = num.doubleValue;
        NSString *name = (fabs(val - 1.0) < 0.01) ? @"1.0x (Normal)" : (val >= 2.0 ? [NSString stringWithFormat:@"%.2gx (Super Jump)", val] : [NSString stringWithFormat:@"%.2gx", val]);
        [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:name selected:fabs(self.flapFactor - val) < 0.01] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf setPracticeFlap:val]; }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { [weakSelf tapped]; }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)showVisualsMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Visuals & HUD" message:@"Cosmetic effects and diagnostic overlays." preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Night Mode" selected:self.nightModeEnabled] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { weakSelf.nightModeEnabled = !weakSelf.nightModeEnabled; [weakSelf saveSettings]; [weakSelf updateButtonTitle]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Bird Fire Trail" selected:self.birdTrailEnabled] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { weakSelf.birdTrailEnabled = !weakSelf.birdTrailEnabled; [weakSelf saveSettings]; [weakSelf updateButtonTitle]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Purple Pipe Tint" selected:self.pipeTintEnabled] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { weakSelf.pipeTintEnabled = !weakSelf.pipeTintEnabled; [weakSelf saveSettings]; [weakSelf updateButtonTitle]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Hitbox Visualizer" selected:self.hitboxVisualizerEnabled] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { weakSelf.hitboxVisualizerEnabled = !weakSelf.hitboxVisualizerEnabled; [weakSelf saveSettings]; [weakSelf updateButtonTitle]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Live Stats HUD Overlay" selected:self.statsHudEnabled] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { weakSelf.statsHudEnabled = !weakSelf.statsHudEnabled; [weakSelf saveSettings]; [weakSelf updateButtonTitle]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Score Multiplier: %ldx", (long)self.scoreMultiplier] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (weakSelf.scoreMultiplier == 1) weakSelf.scoreMultiplier = 2;
        else if (weakSelf.scoreMultiplier == 2) weakSelf.scoreMultiplier = 5;
        else if (weakSelf.scoreMultiplier == 5) weakSelf.scoreMultiplier = 10;
        else weakSelf.scoreMultiplier = 1;
        [weakSelf saveSettings]; [weakSelf updateButtonTitle];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { [weakSelf tapped]; }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)showProfilesMenu {
    UIViewController *presenter = [self topViewController];
    if (!presenter) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Practice Profiles" message:@"Quickly apply balanced presets." preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [menu addAction:[UIAlertAction actionWithTitle:@"Easy Mode (0.5x, Low Gravity, Wide Gaps)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        weakSelf.speedFactor = 0.5; weakSelf.gravityFactor = 0.5; weakSelf.flapFactor = 1.5; weakSelf.wideGapsEnabled = YES; weakSelf.ghostModeEnabled = NO; [weakSelf saveSettings]; [weakSelf updateButtonTitle];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Speed Run Mode (1.5x Speed, Normal Physics)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        weakSelf.speedFactor = 1.5; weakSelf.gravityFactor = 1.0; weakSelf.flapFactor = 1.0; weakSelf.wideGapsEnabled = NO; weakSelf.ghostModeEnabled = NO; [weakSelf restorePipePositions]; [weakSelf saveSettings]; [weakSelf updateButtonTitle];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Ghost Practice (0.75x, Wide Gaps, No Crash)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        weakSelf.speedFactor = 0.75; weakSelf.gravityFactor = 0.75; weakSelf.flapFactor = 1.0; weakSelf.wideGapsEnabled = YES; weakSelf.ghostModeEnabled = YES; [weakSelf saveSettings]; [weakSelf updateButtonTitle];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { [weakSelf tapped]; }]];
    menu.popoverPresentationController.sourceView = self.button;
    menu.popoverPresentationController.sourceRect = self.button.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}

- (void)tapped {
    UIViewController *presenter = [self topViewController];
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Flappy Practice" message:@"Ember Connect practice tools & game mods." preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    NSString *spdStr = (fabs(self.speedFactor - 1.0) < 0.01) ? @"Normal (1.0x)" : [NSString stringWithFormat:@"%.2gx", self.speedFactor];
    [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Speed: %@  ▶", spdStr] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf showSpeedMenu]; }]];
    NSString *grvStr = (fabs(self.gravityFactor - 1.0) < 0.01) ? @"Normal (1.0x)" : [NSString stringWithFormat:@"%.2gx", self.gravityFactor];
    [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Gravity: %@  ▶", grvStr] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf showGravityMenu]; }]];
    NSString *flpStr = (fabs(self.flapFactor - 1.0) < 0.01) ? @"Normal (1.0x)" : [NSString stringWithFormat:@"%.2gx", self.flapFactor];
    [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Flap Power: %@  ▶", flpStr] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf showFlapMenu]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Wide pipe gaps" selected:self.wideGapsEnabled] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        weakSelf.wideGapsEnabled = !weakSelf.wideGapsEnabled; if (!weakSelf.wideGapsEnabled) [weakSelf restorePipePositions]; [weakSelf saveSettings]; [weakSelf updateButtonTitle]; EmberWritePracticeStatus(weakSelf.wideGapsEnabled ? @"wide-gaps-on" : @"wide-gaps-off");
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Ghost mode (no crashes)" selected:self.ghostModeEnabled] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        weakSelf.ghostModeEnabled = !weakSelf.ghostModeEnabled; if (!weakSelf.ghostModeEnabled) [weakSelf restoreCollisionMasks]; [weakSelf saveSettings]; [weakSelf updateButtonTitle]; EmberWritePracticeStatus(weakSelf.ghostModeEnabled ? @"ghost-mode-on" : @"ghost-mode-off");
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Auto-Pilot (Auto-flap)" selected:self.autoPilotEnabled] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { weakSelf.autoPilotEnabled = !weakSelf.autoPilotEnabled; [weakSelf saveSettings]; [weakSelf updateButtonTitle]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Visual Effects & HUD  ▶" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf showVisualsMenu]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Preset Profiles  ▶" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf showProfilesMenu]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Reset all mods" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { [weakSelf resetAllTweaks]; }]];
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
        if (self.statsHud) [host bringSubviewToFront:self.statsHud];
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
    if (!self.statsHud) {
        UIView *hud = [[UIView alloc] initWithFrame:CGRectMake(12, 44, 150, 68)];
        hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        hud.layer.cornerRadius = 8;
        hud.layer.borderWidth = 1;
        hud.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
        hud.userInteractionEnabled = NO;
        hud.hidden = YES;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, 134, 60)];
        label.numberOfLines = 0;
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightMedium];
        [hud addSubview:label];
        self.statsHudLabel = label;
        self.statsHud = hud;
        [host addSubview:hud];
    } else {
        [host addSubview:self.statsHud];
        [host bringSubviewToFront:self.statsHud];
    }
    [self updateButtonTitle];
    [self maintainEnabledTweaks];
    EmberWritePracticeStatus(@"practice-menu-installed");
}

- (void)start {
    [self install];
    [self.keepAliveTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { [weakSelf install]; }];
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
