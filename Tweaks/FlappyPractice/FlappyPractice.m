// FlappyPractice.m — Ember Connect practice controls for Brandon Plank's Flappy Bird.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <SpriteKit/SpriteKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#define EMBER_FLAPPY_BUTTON_TAG 0xFB001
#define EMBER_FLAPPY_HUD_TAG    0xFB002

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
static NSString *const kEmberFreezeKey   = @"EmberFlappyPractice.freeze";
static NSString *const kEmberRainbowKey  = @"EmberFlappyPractice.rainbow";

static const CGFloat EmberExtraGap = 34.0;

// MARK: - Physics hook
//
// The bird's flap goes through -[SKPhysicsBody applyImpulse:], so amplifying
// or damping it is a matter of scaling `impulse.dy` before the call reaches
// the framework. `applyImpulse:atPoint:` is hooked too, for games that use
// the point-anchored variant.
//
// The auto-pilot injects its own flap through this same call. Left alone,
// the hook would then scale that injection by `flapFactor` a second time —
// which is what made auto-pilot fly the bird straight into the ceiling on
// any non-1.0 flap setting. `gEmberBypassScaling` opts the caller out for one
// call, and every internal use goes through `EmberApplyImpulseUnscaled`.

static CGFloat gEmberSpeedFactor    = 1.0;
static CGFloat gEmberGravityFactor  = 1.0;
static CGFloat gEmberFlapFactor     = 1.0;
static _Thread_local BOOL gEmberBypassScaling = NO;
static NSInteger gEmberScoreMultiplier = 1;

static void (*OriginalApplyImpulse)(SKPhysicsBody *, SEL, CGVector) = NULL;
static void (*OriginalApplyImpulseAtPoint)(SKPhysicsBody *, SEL, CGVector, CGPoint) = NULL;

/// Remembered from the player's own flap taps, so auto-play can reproduce
/// them at the same magnitude. Reset each session; the game may recompute
/// its impulse per screen size.
static CGFloat gEmberLearnedFlapDy = 0.0;

static inline void EmberScaleImpulse(SKPhysicsBody *body, CGVector *impulse) {
    if (gEmberBypassScaling) return;
    if (!body || body.categoryBitMask != 1) return;
    // Every non-bypassed upward impulse on the bird is a real tap.
    // Record the largest one seen; the game may issue a small residual
    // impulse for other reasons and we want the actual flap magnitude.
    if (impulse->dy > gEmberLearnedFlapDy) gEmberLearnedFlapDy = impulse->dy;
    if (gEmberSpeedFactor < 0.999) {
        impulse->dx *= gEmberSpeedFactor;
        impulse->dy *= gEmberSpeedFactor;
    }
    if (impulse->dy > 0 && fabs(gEmberFlapFactor - 1.0) > 0.001) {
        impulse->dy *= gEmberFlapFactor;
    }
}

static void HookedApplyImpulse(SKPhysicsBody *body, SEL selector, CGVector impulse) {
    EmberScaleImpulse(body, &impulse);
    if (OriginalApplyImpulse) OriginalApplyImpulse(body, selector, impulse);
}

static void HookedApplyImpulseAtPoint(SKPhysicsBody *body, SEL selector, CGVector impulse, CGPoint point) {
    EmberScaleImpulse(body, &impulse);
    if (OriginalApplyImpulseAtPoint) OriginalApplyImpulseAtPoint(body, selector, impulse, point);
}

/// Applies an impulse from *our* code without triggering the hook's scaling.
///
/// Auto-pilot and one-off nudges have already computed the effective impulse;
/// letting the hook re-scale would double the factor.
static void EmberApplyImpulseUnscaled(SKPhysicsBody *body, CGVector impulse) {
    if (!body) return;
    gEmberBypassScaling = YES;
    [body applyImpulse:impulse];
    gEmberBypassScaling = NO;
}

static void EmberInstallPhysicsHook(void) {
    static dispatch_once_t hookToken;
    dispatch_once(&hookToken, ^{
        Method m = class_getInstanceMethod(SKPhysicsBody.class, @selector(applyImpulse:));
        if (m) {
            OriginalApplyImpulse = (void *)method_getImplementation(m);
            method_setImplementation(m, (IMP)HookedApplyImpulse);
        }
        Method m2 = class_getInstanceMethod(SKPhysicsBody.class, @selector(applyImpulse:atPoint:));
        if (m2) {
            OriginalApplyImpulseAtPoint = (void *)method_getImplementation(m2);
            method_setImplementation(m2, (IMP)HookedApplyImpulseAtPoint);
        }
    });
}

// MARK: - Score multiplier hook
//
// The previous approach walked the scene tree every tick and rewrote label
// text, then flagged the label so we would not touch it again. That fought
// the game's own updates: game writes "5", we multiply to "50" and flag it,
// game writes "6" on the next frame, we skip, so the score stays "6" forever.
//
// Hooking -[SKLabelNode setText:] intercepts the write itself. All-digit text
// with a positive integer value gets multiplied on the way through; anything
// with non-digits ("0:15", "GAME OVER") passes untouched.

static void (*OriginalSetText)(SKLabelNode *, SEL, NSString *) = NULL;

static void HookedSetText(SKLabelNode *self, SEL selector, NSString *text) {
    if (gEmberScoreMultiplier > 1 && text.length > 0 && text.length < 12) {
        BOOL onlyDigits = YES;
        for (NSUInteger i = 0; i < text.length; i++) {
            unichar c = [text characterAtIndex:i];
            if (c < '0' || c > '9') { onlyDigits = NO; break; }
        }
        if (onlyDigits) {
            NSInteger val = [text integerValue];
            if (val > 0) {
                text = [NSString stringWithFormat:@"%lld",
                        (long long)val * (long long)gEmberScoreMultiplier];
            }
        }
    }
    if (OriginalSetText) OriginalSetText(self, selector, text);
}

static void EmberInstallLabelHook(void) {
    static dispatch_once_t hookToken;
    dispatch_once(&hookToken, ^{
        Method m = class_getInstanceMethod(SKLabelNode.class, @selector(setText:));
        if (m) {
            OriginalSetText = (void *)method_getImplementation(m);
            method_setImplementation(m, (IMP)HookedSetText);
        }
    });
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
@property (nonatomic, assign) BOOL freezeEnabled;
@property (nonatomic, assign) BOOL rainbowTrailEnabled;
@property (nonatomic, assign) NSTimeInterval lastAutopilotFlap;
@property (nonatomic, assign) CGFloat rainbowHue;

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
        controller.freezeEnabled       = [defaults boolForKey:kEmberFreezeKey];
        controller.rainbowTrailEnabled = [defaults boolForKey:kEmberRainbowKey];
        controller.rainbowHue          = 0;
        
        gEmberSpeedFactor = controller.speedFactor;
        gEmberGravityFactor = controller.gravityFactor;
        gEmberFlapFactor = controller.flapFactor;
        gEmberScoreMultiplier = controller.scoreMultiplier;
        
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
    [defaults setBool:self.freezeEnabled       forKey:kEmberFreezeKey];
    [defaults setBool:self.rainbowTrailEnabled forKey:kEmberRainbowKey];
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
    if (best) return best;
    
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.hidden || !window.rootViewController || window.windowLevel > UIWindowLevelNormal) continue;
        if (!best || window.isKeyWindow) best = window;
    }
    if (best) return best;
    
    return UIApplication.sharedApplication.keyWindow;
}

- (NSSet<SKScene *> *)visibleSpriteKitScenes {
    NSMutableSet<SKScene *> *scenes = [NSMutableSet new];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            [self collectSpriteKitScenesInView:window into:scenes];
        }
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        [self collectSpriteKitScenesInView:window into:scenes];
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

- (void)applySpeedAndGravityToScene:(SKScene *)scene {
    NSNumber *originalSpeed = [self.originalSpeeds objectForKey:scene];
    if (!originalSpeed) {
        originalSpeed = @(scene.speed > 0.001 ? scene.speed : 1.0);
        [self.originalSpeeds setObject:originalSpeed forKey:scene];
    }
    NSValue *originalGravity = [self.originalGravities objectForKey:scene];
    if (!originalGravity) {
        originalGravity = [NSValue valueWithCGVector:scene.physicsWorld.gravity];
        [self.originalGravities setObject:originalGravity forKey:scene];
    }
    
    // Freeze overrides the speed slider: scene.speed of 0 stops SKAction
    // and the physics simulation, which is exactly what "pause" means for
    // a SpriteKit game like Brandon Plank's Flappy Bird. The original speed
    // is still remembered so unfreezing snaps back to whatever the slider says.
    if (self.freezeEnabled) {
        scene.speed = 0.0;
    } else {
        scene.speed = originalSpeed.doubleValue * self.speedFactor;
    }
    CGVector gravity = originalGravity.CGVectorValue;
    CGFloat effectiveSpeedSq = self.speedFactor * self.speedFactor;
    scene.physicsWorld.gravity = CGVectorMake(gravity.dx * effectiveSpeedSq,
                                              gravity.dy * effectiveSpeedSq * self.gravityFactor);
}

- (void)applySpeedAndGravityToAllScenes {
    for (SKScene *scene in [self visibleSpriteKitScenes]) {
        [self applySpeedAndGravityToScene:scene];
    }
}

- (void)adjustPipeChildrenOfNode:(SKNode *)parent {
    NSMutableArray<SKNode *> *pipes = [NSMutableArray new];
    for (SKNode *child in parent.children) if (child.physicsBody && child.physicsBody.categoryBitMask == 4) [pipes addObject:child];
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
        if (!body) return;
        uint32_t category = body.categoryBitMask;
        if (category != 1 && category != 2 && category != 4) return;
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
        if (node.physicsBody && node.physicsBody.categoryBitMask == 1) {
            birdNode = node;
            if (self.birdTrailEnabled) {
                SKEmitterNode *emitter = (SKEmitterNode *)[node childNodeWithName:@"EmberTrail"];
                if (!emitter) {
                    emitter = [SKEmitterNode new];
                    emitter.name = @"EmberTrail";
                    emitter.particleBirthRate = 40;
                    emitter.particleLifetime = 0.6;
                    emitter.particlePositionRange = CGVectorMake(6, 6);
                    emitter.particleColorBlendFactor = 1.0;
                    emitter.particleAlpha = 0.8;
                    emitter.particleAlphaSpeed = -1.2;
                    emitter.particleScale = 0.15;
                    emitter.particleScaleSpeed = -0.1;
                    emitter.zPosition = -1;
                    [node addChild:emitter];
                }
                emitter.particleColor = self.rainbowTrailEnabled
                    ? [UIColor colorWithHue:self.rainbowHue saturation:0.9 brightness:1.0 alpha:1.0]
                    : [UIColor orangeColor];
            } else {
                [[node childNodeWithName:@"EmberTrail"] removeFromParent];
            }
        }
        if (node.physicsBody && node.physicsBody.categoryBitMask == 4 && [node isKindOfClass:SKSpriteNode.class]) {
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
        // Score multiplier is handled by the setText: hook now.
    }];
    
    if (self.autoPilotEnabled && birdNode && birdNode.physicsBody) {
        // Group pipes into columns by X: Flappy pipes come as top/bottom
        // pairs sharing a scroll column, and the *gap* between them is the
        // safe zone. The previous version aimed at one pipe's centre Y,
        // which put the bird straight through solid geometry.
        CGPoint birdPos = [scene convertPoint:birdNode.position fromNode:birdNode.parent ?: scene];

        typedef struct { CGFloat x; CGFloat topY; CGFloat bottomY; int count; } EmberColumn;
        NSMutableArray<NSValue *> *columns = [NSMutableArray new];
        for (SKNode *pipe in activePipes) {
            CGPoint w = [scene convertPoint:pipe.position fromNode:pipe.parent ?: scene];
            BOOL merged = NO;
            for (NSUInteger i = 0; i < columns.count; i++) {
                EmberColumn c; [columns[i] getValue:&c];
                if (fabs(c.x - w.x) < 30.0) {
                    if (w.y > c.topY)    c.topY    = w.y;
                    if (w.y < c.bottomY) c.bottomY = w.y;
                    c.count++;
                    columns[i] = [NSValue valueWithBytes:&c objCType:@encode(EmberColumn)];
                    merged = YES;
                    break;
                }
            }
            if (!merged) {
                EmberColumn c = { w.x, w.y, w.y, 1 };
                [columns addObject:[NSValue valueWithBytes:&c objCType:@encode(EmberColumn)]];
            }
        }

        // Nearest column whose right edge is still ahead of the bird.
        CGFloat bestDx = CGFLOAT_MAX;
        CGFloat gapCentreY = scene.size.height * 0.5;
        for (NSValue *value in columns) {
            EmberColumn c; [value getValue:&c];
            CGFloat dx = c.x - birdPos.x;
            if (dx < -20.0) continue;
            if (dx < bestDx) {
                bestDx = dx;
                gapCentreY = (c.count >= 2) ? (c.topY + c.bottomY) * 0.5 : c.topY;
            }
        }

        // Learn the flap magnitude from any real tap the player has issued.
        // Falls back to a sensible default until the first real flap is seen.
        CGFloat impulseDy = gEmberLearnedFlapDy > 0.5 ? gEmberLearnedFlapDy : 6.0;

        // Cooldown: a live physics engine will keep meeting the trigger every
        // frame until the impulse has visibly moved the bird up, so without a
        // gap between flaps the bird accumulates absurd upward velocity.
        NSTimeInterval now = CACurrentMediaTime();
        NSTimeInterval cooldown = 0.28 / MAX(self.speedFactor, 0.25);
        BOOL canFlap = (now - self.lastAutopilotFlap) >= cooldown;

        // A small buffer below the gap centre gives the bird room to fall
        // through the middle instead of catching the top pipe on rise.
        CGFloat aimY = gapCentreY - 24.0;
        CGVector velocity = birdNode.physicsBody.velocity;

        if (canFlap && birdPos.y < aimY && velocity.dy < impulseDy * 0.35) {
            // Zero the falling velocity first so a real-sized impulse produces
            // a real-sized flap regardless of how fast we were dropping.
            birdNode.physicsBody.velocity = CGVectorMake(velocity.dx, 0);
            EmberApplyImpulseUnscaled(birdNode.physicsBody, CGVectorMake(0, impulseDy));
            self.lastAutopilotFlap = now;
        }
    }
}

- (void)maintainEnabledTweaks {
    gEmberSpeedFactor = self.speedFactor;
    gEmberGravityFactor = self.gravityFactor;
    gEmberFlapFactor = self.flapFactor;
    if (self.rainbowTrailEnabled) {
        self.rainbowHue += 0.008;
        if (self.rainbowHue > 1.0) self.rainbowHue -= 1.0;
    }
    
    for (SKScene *scene in [self visibleSpriteKitScenes]) {
        [self applySpeedAndGravityToScene:scene];
        if (self.wideGapsEnabled) {
            [self visitNode:scene block:^(SKNode *node) { [self adjustPipeChildrenOfNode:node]; }];
        }
        if (self.ghostModeEnabled) {
            [self applyGhostModeToScene:scene];
        }
        [self applyVisualsAndAutoPilotToScene:scene];
    }
}

- (void)tick:(CADisplayLink *)link {
    if (self.lastFrameTime == 0) self.lastFrameTime = link.timestamp;
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
    BOOL active = (fabs(self.speedFactor - 1.0) >= 0.01) || (fabs(self.gravityFactor - 1.0) >= 0.01) || (fabs(self.flapFactor - 1.0) >= 0.01) || self.wideGapsEnabled || self.ghostModeEnabled || self.autoPilotEnabled || self.nightModeEnabled || self.birdTrailEnabled || self.pipeTintEnabled || self.hitboxVisualizerEnabled || (self.scoreMultiplier > 1) || self.freezeEnabled || self.rainbowTrailEnabled;
    self.button.backgroundColor = active ? [UIColor colorWithRed:0.98 green:0.38 blue:0.10 alpha:0.94] : [UIColor colorWithWhite:0.10 alpha:0.82];
}

- (UIViewController *)topViewController {
    UIViewController *controller = self.hostWindow.rootViewController;
    if (!controller) {
        UIWindow *window = [self guestWindow];
        controller = window.rootViewController;
    }
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller;
}

- (NSString *)markedTitle:(NSString *)title selected:(BOOL)selected {
    return [NSString stringWithFormat:@"%@ %@", selected ? @"✓" : @"  ", title];
}

- (void)setPracticeSpeed:(CGFloat)factor {
    self.speedFactor = factor;
    gEmberSpeedFactor = factor;
    [self saveSettings];
    [self applySpeedAndGravityToAllScenes];
    [self updateButtonTitle];
    EmberWritePracticeStatus(@"speed-changed");
}

- (void)setPracticeGravity:(CGFloat)factor {
    self.gravityFactor = factor;
    gEmberGravityFactor = factor;
    [self saveSettings];
    [self applySpeedAndGravityToAllScenes];
    [self updateButtonTitle];
    EmberWritePracticeStatus(@"gravity-changed");
}

- (void)setPracticeFlap:(CGFloat)factor {
    self.flapFactor = factor;
    gEmberFlapFactor = factor;
    [self saveSettings];
    [self updateButtonTitle];
    EmberWritePracticeStatus(@"flap-changed");
}

- (void)toggleWideGaps {
    self.wideGapsEnabled = !self.wideGapsEnabled;
    if (self.wideGapsEnabled) {
        for (SKScene *scene in [self visibleSpriteKitScenes]) {
            [self visitNode:scene block:^(SKNode *node) { [self adjustPipeChildrenOfNode:node]; }];
        }
    } else {
        [self restorePipePositions];
    }
    [self saveSettings];
    [self updateButtonTitle];
    EmberWritePracticeStatus(self.wideGapsEnabled ? @"wide-gaps-on" : @"wide-gaps-off");
}

- (void)toggleGhostMode {
    self.ghostModeEnabled = !self.ghostModeEnabled;
    if (self.ghostModeEnabled) {
        for (SKScene *scene in [self visibleSpriteKitScenes]) {
            [self applyGhostModeToScene:scene];
        }
    } else {
        [self restoreCollisionMasks];
    }
    [self saveSettings];
    [self updateButtonTitle];
    EmberWritePracticeStatus(self.ghostModeEnabled ? @"ghost-mode-on" : @"ghost-mode-off");
}

- (void)resetAllTweaks {
    self.speedFactor = gEmberSpeedFactor = 1.0;
    self.gravityFactor = gEmberGravityFactor = 1.0;
    self.flapFactor = gEmberFlapFactor = 1.0;
    self.wideGapsEnabled = NO;
    self.ghostModeEnabled = NO;
    self.autoPilotEnabled = NO;
    self.scoreMultiplier = 1;
    gEmberScoreMultiplier = 1;
    self.nightModeEnabled = NO;
    self.birdTrailEnabled = NO;
    self.pipeTintEnabled = NO;
    self.hitboxVisualizerEnabled = NO;
    self.statsHudEnabled = NO;
    self.freezeEnabled = NO;
    self.rainbowTrailEnabled = NO;
    gEmberLearnedFlapDy = 0.0;
    self.lastAutopilotFlap = 0;
    [self restorePipePositions];
    [self restoreCollisionMasks];
    [self applySpeedAndGravityToAllScenes];
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
        gEmberScoreMultiplier = weakSelf.scoreMultiplier;
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
        weakSelf.speedFactor = gEmberSpeedFactor = 0.5;
        weakSelf.gravityFactor = gEmberGravityFactor = 0.5;
        weakSelf.flapFactor = gEmberFlapFactor = 1.5;
        weakSelf.wideGapsEnabled = YES;
        weakSelf.ghostModeEnabled = NO;
        [weakSelf applySpeedAndGravityToAllScenes];
        for (SKScene *scene in [weakSelf visibleSpriteKitScenes]) {
            [weakSelf visitNode:scene block:^(SKNode *node) { [weakSelf adjustPipeChildrenOfNode:node]; }];
        }
        [weakSelf saveSettings];
        [weakSelf updateButtonTitle];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Speed Run Mode (1.5x Speed, Normal Physics)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        weakSelf.speedFactor = gEmberSpeedFactor = 1.5;
        weakSelf.gravityFactor = gEmberGravityFactor = 1.0;
        weakSelf.flapFactor = gEmberFlapFactor = 1.0;
        weakSelf.wideGapsEnabled = NO;
        weakSelf.ghostModeEnabled = NO;
        [weakSelf restorePipePositions];
        [weakSelf applySpeedAndGravityToAllScenes];
        [weakSelf saveSettings];
        [weakSelf updateButtonTitle];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Ghost Practice (0.75x, Wide Gaps, No Crash)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        weakSelf.speedFactor = gEmberSpeedFactor = 0.75;
        weakSelf.gravityFactor = gEmberGravityFactor = 0.75;
        weakSelf.flapFactor = gEmberFlapFactor = 1.0;
        weakSelf.wideGapsEnabled = YES;
        weakSelf.ghostModeEnabled = YES;
        [weakSelf applySpeedAndGravityToAllScenes];
        for (SKScene *scene in [weakSelf visibleSpriteKitScenes]) {
            [weakSelf visitNode:scene block:^(SKNode *node) { [weakSelf adjustPipeChildrenOfNode:node]; }];
            [weakSelf applyGhostModeToScene:scene];
        }
        [weakSelf saveSettings];
        [weakSelf updateButtonTitle];
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
        [weakSelf toggleWideGaps];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:(self.freezeEnabled ? @"Resume Game" : @"Freeze / Pause Game")
                                                        selected:self.freezeEnabled]
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *action) {
        weakSelf.freezeEnabled = !weakSelf.freezeEnabled;
        [weakSelf saveSettings]; [weakSelf applySpeedAndGravityToAllScenes]; [weakSelf updateButtonTitle];
    }]];

    [menu addAction:[UIAlertAction actionWithTitle:[self markedTitle:@"Ghost mode (no crashes)" selected:self.ghostModeEnabled] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf toggleGhostMode];
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
    
    UIView *existing = [host viewWithTag:EMBER_FLAPPY_BUTTON_TAG];
    if (existing && [existing isKindOfClass:UIButton.class]) {
        self.button = (UIButton *)existing;
        [host bringSubviewToFront:self.button];
        if (self.statsHud) [host bringSubviewToFront:self.statsHud];
        [self updateButtonTitle];
        [self maintainEnabledTweaks];
        return;
    }
    
    [self.button removeFromSuperview];
    
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = EMBER_FLAPPY_BUTTON_TAG;
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
    [button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    
    [host addSubview:button];
    [host bringSubviewToFront:button];
    self.button = button;
    self.hostWindow = host;
    
    if (!self.statsHud) {
        UIView *hud = [[UIView alloc] initWithFrame:CGRectMake(12, 44, 150, 68)];
        hud.tag = EMBER_FLAPPY_HUD_TAG;
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
    EmberInstallLabelHook();
    dispatch_async(dispatch_get_main_queue(), ^{
        EmberWritePracticeStatus(@"constructor-ran");
        EmberFlappyPracticeController *controller = [EmberFlappyPracticeController sharedController];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [controller start]; }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [controller stop]; }];
        [controller start];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [controller start]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [controller start]; });
    });
}
