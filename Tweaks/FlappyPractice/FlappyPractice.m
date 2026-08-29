// FlappyPractice.m — Upgraded Ember Connect practice controls for Brandon Plank's Flappy Bird.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <SpriteKit/SpriteKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// MARK: - Constants & Settings Keys
static NSString *const kEmberPrefix = @"EmberFlappyPractice.";
static NSString *const kEmberSpeedKey = @"EmberFlappyPractice.speed";
static NSString *const kEmberGravityKey = @"EmberFlappyPractice.gravity";
static NSString *const kEmberFlapKey = @"EmberFlappyPractice.flap";
static NSString *const kEmberWideGapsKey = @"EmberFlappyPractice.wideGaps";
static NSString *const kEmberGhostModeKey = @"EmberFlappyPractice.ghostMode";
static NSString *const kEmberAutoPilotKey = @"EmberFlappyPractice.autoPilot";
static NSString *const kEmberInstantRestartKey = @"EmberFlappyPractice.instantRestart";
static NSString *const kEmberScoreMultKey = @"EmberFlappyPractice.scoreMult";
static NSString *const kEmberNightModeKey = @"EmberFlappyPractice.nightMode";
static NSString *const kEmberBirdTrailKey = @"EmberFlappyPractice.birdTrail";
static NSString *const kEmberPipeTintKey = @"EmberFlappyPractice.pipeTint";
static NSString *const kEmberHitboxKey = @"EmberFlappyPractice.hitbox";
static NSString *const kEmberStatsHudKey = @"EmberFlappyPractice.statsHud";
static NSString *const kEmberProfilesKey = @"EmberFlappyPractice.profiles";

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
        if (impulse.dy > 0) {
            impulse.dy *= gEmberFlapFactor;
        }
    }
    OriginalApplyImpulse(body, selector, impulse);
}

static void EmberInstallHooks(void) {
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
        @"updatedAt": @([NSDate.date timeIntervalSince1970])
    } writeToFile:[folder stringByAppendingPathComponent:@"FlappyPracticeStatus.plist"] atomically:YES];
}

// MARK: - Main Controller
@interface EmberFlappyPracticeController : NSObject
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, strong) UIVisualEffectView *panelView;
@property (nonatomic, strong) UIView *statsHud;
@property (nonatomic, strong) UILabel *statsHudLabel;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) NSTimer *keepAliveTimer;

@property (nonatomic, assign) NSInteger frames;
@property (nonatomic, assign) CFTimeInterval lastFrameTime;
@property (nonatomic, assign) double currentFPS;
@property (nonatomic, assign) NSInteger gamesPlayed;
@property (nonatomic, assign) NSInteger sessionBestScore;
@property (nonatomic, assign) NSInteger totalSessionScore;

@property (nonatomic, strong) NSMapTable<SKScene *, NSNumber *> *originalSpeeds;
@property (nonatomic, strong) NSMapTable<SKScene *, NSValue *> *originalGravities;
@property (nonatomic, strong) NSMapTable<SKScene *, NSNumber *> *appliedSpeedFactors;
@property (nonatomic, strong) NSMapTable<SKNode *, NSValue *> *originalPipePositions;
@property (nonatomic, strong) NSMapTable<SKPhysicsBody *, NSArray<NSNumber *> *> *originalMasks;

// Settings
@property (nonatomic, assign) CGFloat speedFactor;
@property (nonatomic, assign) CGFloat gravityFactor;
@property (nonatomic, assign) CGFloat flapFactor;
@property (nonatomic, assign) BOOL wideGapsEnabled;
@property (nonatomic, assign) BOOL ghostModeEnabled;
@property (nonatomic, assign) BOOL autoPilotEnabled;
@property (nonatomic, assign) BOOL instantRestartEnabled;
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
        [controller loadSettings];
        
        controller.displayLink = [CADisplayLink displayLinkWithTarget:controller selector:@selector(tick:)];
        [controller.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
    return controller;
}

- (void)loadSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.speedFactor = [defaults objectForKey:kEmberSpeedKey] ? [defaults doubleForKey:kEmberSpeedKey] : 1.0;
    self.gravityFactor = [defaults objectForKey:kEmberGravityKey] ? [defaults doubleForKey:kEmberGravityKey] : 1.0;
    self.flapFactor = [defaults objectForKey:kEmberFlapKey] ? [defaults doubleForKey:kEmberFlapKey] : 1.0;
    self.wideGapsEnabled = [defaults boolForKey:kEmberWideGapsKey];
    self.ghostModeEnabled = [defaults boolForKey:kEmberGhostModeKey];
    self.autoPilotEnabled = [defaults boolForKey:kEmberAutoPilotKey];
    self.instantRestartEnabled = [defaults boolForKey:kEmberInstantRestartKey];
    self.scoreMultiplier = [defaults objectForKey:kEmberScoreMultKey] ? [defaults integerForKey:kEmberScoreMultKey] : 1;
    self.nightModeEnabled = [defaults boolForKey:kEmberNightModeKey];
    self.birdTrailEnabled = [defaults boolForKey:kEmberBirdTrailKey];
    self.pipeTintEnabled = [defaults boolForKey:kEmberPipeTintKey];
    self.hitboxVisualizerEnabled = [defaults boolForKey:kEmberHitboxKey];
    self.statsHudEnabled = [defaults boolForKey:kEmberStatsHudKey];
    
    gEmberSpeedFactor = self.speedFactor;
    gEmberGravityFactor = self.gravityFactor;
    gEmberFlapFactor = self.flapFactor;
}

- (void)saveSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:self.speedFactor forKey:kEmberSpeedKey];
    [defaults setDouble:self.gravityFactor forKey:kEmberGravityKey];
    [defaults setDouble:self.flapFactor forKey:kEmberFlapKey];
    [defaults setBool:self.wideGapsEnabled forKey:kEmberWideGapsKey];
    [defaults setBool:self.ghostModeEnabled forKey:kEmberGhostModeKey];
    [defaults setBool:self.autoPilotEnabled forKey:kEmberAutoPilotKey];
    [defaults setBool:self.instantRestartEnabled forKey:kEmberInstantRestartKey];
    [defaults setInteger:self.scoreMultiplier forKey:kEmberScoreMultKey];
    [defaults setBool:self.nightModeEnabled forKey:kEmberNightModeKey];
    [defaults setBool:self.birdTrailEnabled forKey:kEmberBirdTrailKey];
    [defaults setBool:self.pipeTintEnabled forKey:kEmberPipeTintKey];
    [defaults setBool:self.hitboxVisualizerEnabled forKey:kEmberHitboxKey];
    [defaults setBool:self.statsHudEnabled forKey:kEmberStatsHudKey];
    
    gEmberSpeedFactor = self.speedFactor;
    gEmberGravityFactor = self.gravityFactor;
    gEmberFlapFactor = self.flapFactor;
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

// MARK: - Game Mod Logic

- (void)applyPhysicsModifiersToScene:(SKScene *)scene {
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
    
    scene.speed = originalSpeed.doubleValue * self.speedFactor;
    CGVector grav = originalGravity.CGVectorValue;
    scene.physicsWorld.gravity = CGVectorMake(grav.dx, grav.dy * self.gravityFactor);
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

- (void)restorePipePositions {
    for (SKNode *pipe in self.originalPipePositions.keyEnumerator) {
        NSValue *position = [self.originalPipePositions objectForKey:pipe];
        if (pipe && position) pipe.position = position.CGPointValue;
    }
    [self.originalPipePositions removeAllObjects];
}

- (void)applyVisualEffectsToScene:(SKScene *)scene {
    if (self.nightModeEnabled) {
        if (![scene childNodeWithName:@"EmberNightMode"]) {
            SKSpriteNode *night = [SKSpriteNode spriteNodeWithColor:[UIColor colorWithWhite:0 alpha:0.5] size:scene.size];
            night.position = CGPointMake(scene.size.width/2, scene.size.width/2);
            night.zPosition = 1000;
            night.name = @"EmberNightMode";
            [scene addChild:night];
        }
    } else {
        [[scene childNodeWithName:@"EmberNightMode"] removeFromParent];
    }
    
    [self visitNode:scene block:^(SKNode *node) {
        if (self.birdTrailEnabled && node.physicsBody.categoryBitMask == 1) {
            if (![node childNodeWithName:@"EmberTrail"]) {
                NSString *path = [[NSBundle mainBundle] pathForResource:@"Spark" ofType:@"sks"];
                SKEmitterNode *emitter = path ? [NSKeyedUnarchiver unarchiveObjectWithFile:path] : [SKEmitterNode new];
                emitter.name = @"EmberTrail";
                emitter.particleBirthRate = 50;
                emitter.particleLifetime = 1;
                emitter.particlePositionRange = CGVectorMake(10, 10);
                emitter.particleColor = [UIColor orangeColor];
                emitter.particleColorBlendFactor = 1.0;
                emitter.zPosition = -1;
                [node addChild:emitter];
            }
        } else if (!self.birdTrailEnabled && node.physicsBody.categoryBitMask == 1) {
            [[node childNodeWithName:@"EmberTrail"] removeFromParent];
        }
        
        if (self.pipeTintEnabled && node.physicsBody.categoryBitMask == 4 && [node isKindOfClass:SKSpriteNode.class]) {
            SKSpriteNode *sprite = (SKSpriteNode *)node;
            sprite.color = [UIColor purpleColor];
            sprite.colorBlendFactor = 0.6;
        } else if (!self.pipeTintEnabled && node.physicsBody.categoryBitMask == 4 && [node isKindOfClass:SKSpriteNode.class]) {
            SKSpriteNode *sprite = (SKSpriteNode *)node;
            sprite.colorBlendFactor = 0.0;
        }
        
        if (self.hitboxVisualizerEnabled && node.physicsBody) {
            if (![node childNodeWithName:@"EmberHitbox"]) {
                SKShapeNode *shape = [SKShapeNode shapeNodeWithRectOfSize:CGSizeMake(30, 30)];
                shape.strokeColor = [UIColor redColor];
                shape.lineWidth = 1.0;
                shape.name = @"EmberHitbox";
                shape.zPosition = 2000;
                [node addChild:shape];
            }
        } else if (!self.hitboxVisualizerEnabled && node.physicsBody) {
            [[node childNodeWithName:@"EmberHitbox"] removeFromParent];
        }
        
        // Auto-pilot
        if (self.autoPilotEnabled && node.physicsBody.categoryBitMask == 1) {
            if (node.position.y < scene.size.height * 0.45) {
                // simulate tap via applyImpulse directly since we can't easily synthesize touches
                if (node.physicsBody.velocity.dy < 0) {
                    node.physicsBody.velocity = CGVectorMake(node.physicsBody.velocity.dx, 0);
                    [node.physicsBody applyImpulse:CGVectorMake(0, 10 * gEmberFlapFactor)];
                }
            }
        }
        
        // Score Multiplier (find label nodes with integer names)
        if (self.scoreMultiplier > 1 && [node isKindOfClass:SKLabelNode.class]) {
            SKLabelNode *label = (SKLabelNode *)node;
            NSInteger val = [label.text integerValue];
            if (val > 0 && ![label.name isEqualToString:@"EmberScoreMult"]) {
                label.name = @"EmberScoreMult";
                label.text = [NSString stringWithFormat:@"%ld", (long)(val * self.scoreMultiplier)];
            }
        }
        
        // Instant Restart
        if (self.instantRestartEnabled && [node.name isEqualToString:@"GameOver"]) {
            // Find replay button
            SKNode *replay = [scene childNodeWithName:@"//ReplayButton"] ?: [scene childNodeWithName:@"//PlayButton"];
            if (replay && [scene.view.scene isEqual:scene]) {
                // It's hard to simulate sprite touch, just present new scene
                // (Depends on how game handles it, may just need to wait a sec and transition)
            }
        }
    }];
}

- (void)maintainMods {
    for (SKScene *scene in [self visibleSpriteKitScenes]) {
        [self applyPhysicsModifiersToScene:scene];
        if (self.wideGapsEnabled) [self visitNode:scene block:^(SKNode *n) { [self adjustPipeChildrenOfNode:n]; }];
        if (self.ghostModeEnabled) [self applyGhostModeToScene:scene];
        [self applyVisualEffectsToScene:scene];
    }
}

// MARK: - HUD & Timers
- (void)tick:(CADisplayLink *)link {
    CFTimeInterval dt = link.timestamp - self.lastFrameTime;
    self.frames++;
    if (dt >= 1.0) {
        self.currentFPS = self.frames / dt;
        self.frames = 0;
        self.lastFrameTime = link.timestamp;
    }
    
    [self maintainMods];
    
    if (self.statsHudEnabled && self.statsHudLabel) {
        self.statsHud.hidden = NO;
        self.statsHudLabel.text = [NSString stringWithFormat:@"FPS: %.0f\nSpd: %.2fx Grv: %.2fx Flp: %.2fx\nGames: %ld\nBest: %ld",
                                   self.currentFPS, self.speedFactor, self.gravityFactor, self.flapFactor,
                                   (long)self.gamesPlayed, (long)self.sessionBestScore];
    } else {
        self.statsHud.hidden = YES;
    }
}

// MARK: - UI Interactions
- (void)handlePan:(UIPanGestureRecognizer *)recognizer {
    UIView *view = recognizer.view;
    CGPoint translation = [recognizer translationInView:view.superview];
    view.center = CGPointMake(view.center.x + translation.x, view.center.y + translation.y);
    [recognizer setTranslation:CGPointZero inView:view.superview];
}

- (void)floatingButtonTapped {
    if (self.panelView.superview) {
        [UIView animateWithDuration:0.3 animations:^{ self.panelView.alpha = 0; } completion:^(BOOL finished) { [self.panelView removeFromSuperview]; }];
        return;
    }
    [self showSettingsPanel];
}

- (void)showSettingsPanel {
    UIWindow *host = [self guestWindow];
    if (!host) return;
    
    UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    panel.frame = CGRectMake(20, 40, host.bounds.size.width - 40, host.bounds.size.height - 80);
    panel.layer.cornerRadius = 16;
    panel.layer.masksToBounds = YES;
    panel.alpha = 0;
    
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:panel.bounds];
    [panel.contentView addSubview:scrollView];
    
    CGFloat y = 20;
    CGFloat w = panel.bounds.size.width;
    
    // Title
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, y, w, 30)];
    title.text = @"Ember Practice Mods";
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:20];
    [scrollView addSubview:title];
    y += 40;
    
    // Helper macro to add sliders
    #define ADD_SLIDER(titleText, min, max, targetSel, prop) \
        UILabel *lbl_##prop = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w-40, 20)]; \
        lbl_##prop.text = [NSString stringWithFormat:@"%@: %.2f", titleText, self.prop]; \
        lbl_##prop.textColor = [UIColor lightGrayColor]; \
        lbl_##prop.font = [UIFont systemFontOfSize:14]; \
        [scrollView addSubview:lbl_##prop]; \
        y += 25; \
        UISlider *sld_##prop = [[UISlider alloc] initWithFrame:CGRectMake(20, y, w-40, 30)]; \
        sld_##prop.minimumValue = min; \
        sld_##prop.maximumValue = max; \
        sld_##prop.value = self.prop; \
        [sld_##prop addTarget:self action:@selector(targetSel:) forControlEvents:UIControlEventValueChanged]; \
        [scrollView addSubview:sld_##prop]; \
        y += 40;

    ADD_SLIDER(@"Speed", 0.25, 2.0, speedChanged, speedFactor)
    ADD_SLIDER(@"Gravity", 0.25, 3.0, gravityChanged, gravityFactor)
    ADD_SLIDER(@"Flap Power", 0.5, 3.0, flapChanged, flapFactor)
    
    // Helper macro for switches
    #define ADD_SWITCH(titleText, targetSel, prop) \
        UILabel *lbl_##prop = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w-80, 30)]; \
        lbl_##prop.text = titleText; \
        lbl_##prop.textColor = [UIColor whiteColor]; \
        [scrollView addSubview:lbl_##prop]; \
        UISwitch *sw_##prop = [[UISwitch alloc] initWithFrame:CGRectMake(w-70, y, 50, 30)]; \
        sw_##prop.on = self.prop; \
        [sw_##prop addTarget:self action:@selector(targetSel:) forControlEvents:UIControlEventValueChanged]; \
        [scrollView addSubview:sw_##prop]; \
        y += 40;

    ADD_SWITCH(@"Wide Gaps", wideGapsChanged, wideGapsEnabled)
    ADD_SWITCH(@"Ghost Mode (No Clip)", ghostModeChanged, ghostModeEnabled)
    ADD_SWITCH(@"Auto-Pilot", autoPilotChanged, autoPilotEnabled)
    ADD_SWITCH(@"Stats HUD", statsHudChanged, statsHudEnabled)
    ADD_SWITCH(@"Night Mode", nightModeChanged, nightModeEnabled)
    ADD_SWITCH(@"Bird Trail", birdTrailChanged, birdTrailEnabled)
    ADD_SWITCH(@"Pipe Tint", pipeTintChanged, pipeTintEnabled)
    ADD_SWITCH(@"Hitbox Visualizer", hitboxChanged, hitboxVisualizerEnabled)
    
    // Profiles
    NSArray *profiles = @[@"Easy", @"Speed Run", @"Practice"];
    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:profiles];
    seg.frame = CGRectMake(20, y, w-40, 30);
    [seg addTarget:self action:@selector(profileChanged:) forControlEvents:UIControlEventValueChanged];
    [scrollView addSubview:seg];
    y += 50;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(w/2 - 50, y, 100, 40);
    [close setTitle:@"Close" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.backgroundColor = [UIColor darkGrayColor];
    close.layer.cornerRadius = 8;
    [close addTarget:self action:@selector(floatingButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [scrollView addSubview:close];
    y += 60;
    
    scrollView.contentSize = CGSizeMake(w, y);
    
    self.panelView = panel;
    [host addSubview:panel];
    [UIView animateWithDuration:0.3 animations:^{ panel.alpha = 1; }];
}

// Actions
- (void)speedChanged:(UISlider *)sender { self.speedFactor = sender.value; [self saveSettings]; }
- (void)gravityChanged:(UISlider *)sender { self.gravityFactor = sender.value; [self saveSettings]; }
- (void)flapChanged:(UISlider *)sender { self.flapFactor = sender.value; [self saveSettings]; }
- (void)wideGapsChanged:(UISwitch *)sender {
    self.wideGapsEnabled = sender.on;
    if (!sender.on) [self restorePipePositions];
    [self saveSettings];
}
- (void)ghostModeChanged:(UISwitch *)sender {
    self.ghostModeEnabled = sender.on;
    if (!sender.on) [self restoreCollisionMasks];
    [self saveSettings];
}
- (void)autoPilotChanged:(UISwitch *)sender { self.autoPilotEnabled = sender.on; [self saveSettings]; }
- (void)statsHudChanged:(UISwitch *)sender { self.statsHudEnabled = sender.on; [self saveSettings]; }
- (void)nightModeChanged:(UISwitch *)sender { self.nightModeEnabled = sender.on; [self saveSettings]; }
- (void)birdTrailChanged:(UISwitch *)sender { self.birdTrailEnabled = sender.on; [self saveSettings]; }
- (void)pipeTintChanged:(UISwitch *)sender { self.pipeTintEnabled = sender.on; [self saveSettings]; }
- (void)hitboxChanged:(UISwitch *)sender { self.hitboxVisualizerEnabled = sender.on; [self saveSettings]; }

- (void)profileChanged:(UISegmentedControl *)sender {
    if (sender.selectedSegmentIndex == 0) { // Easy
        self.speedFactor = 0.5; self.gravityFactor = 0.5; self.flapFactor = 2.0;
        self.wideGapsEnabled = YES; self.ghostModeEnabled = NO;
    } else if (sender.selectedSegmentIndex == 1) { // Speed Run
        self.speedFactor = 2.0; self.gravityFactor = 1.0; self.flapFactor = 1.0;
        self.wideGapsEnabled = NO; self.ghostModeEnabled = NO;
    } else if (sender.selectedSegmentIndex == 2) { // Practice
        self.speedFactor = 0.5; self.gravityFactor = 0.75; self.flapFactor = 1.0;
        self.wideGapsEnabled = YES; self.ghostModeEnabled = YES;
    }
    if (!self.wideGapsEnabled) [self restorePipePositions];
    if (!self.ghostModeEnabled) [self restoreCollisionMasks];
    [self saveSettings];
    [self floatingButtonTapped]; // close and reopen or just close
}

- (void)installUI {
    UIWindow *host = [self guestWindow];
    if (!host) return;
    self.hostWindow = host;
    
    if (!self.floatingButton) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(host.bounds.size.width - 70, 100, 50, 50);
        btn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.8];
        btn.layer.cornerRadius = 25;
        btn.layer.borderWidth = 2;
        btn.layer.borderColor = [UIColor orangeColor].CGColor;
        [btn setTitle:@"⚙️" forState:UIControlStateNormal];
        [btn addTarget:self action:@selector(floatingButtonTapped) forControlEvents:UIControlEventTouchUpInside];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [btn addGestureRecognizer:pan];
        
        [host addSubview:btn];
        self.floatingButton = btn;
    } else {
        [host bringSubviewToFront:self.floatingButton];
    }
    
    if (!self.statsHud) {
        self.statsHud = [[UIView alloc] initWithFrame:CGRectMake(10, 40, 150, 100)];
        self.statsHud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
        self.statsHud.layer.cornerRadius = 8;
        self.statsHud.userInteractionEnabled = NO;
        self.statsHudLabel = [[UILabel alloc] initWithFrame:CGRectMake(5, 5, 140, 90)];
        self.statsHudLabel.numberOfLines = 0;
        self.statsHudLabel.textColor = [UIColor whiteColor];
        self.statsHudLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular];
        [self.statsHud addSubview:self.statsHudLabel];
        [host addSubview:self.statsHud];
    } else {
        [host bringSubviewToFront:self.statsHud];
    }
    
    if (self.panelView) {
        [host bringSubviewToFront:self.panelView];
    }
}

- (void)start {
    [self installUI];
    [self.keepAliveTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        [weakSelf installUI];
    }];
}

- (void)stop {
    [self.keepAliveTimer invalidate];
    self.keepAliveTimer = nil;
}

@end

__attribute__((constructor))
static void EmberFlappyPracticeInit(void) {
    EmberInstallHooks();
    dispatch_async(dispatch_get_main_queue(), ^{
        EmberWritePracticeStatus(@"constructor-ran");
        EmberFlappyPracticeController *controller = [EmberFlappyPracticeController sharedController];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [controller start]; }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [controller stop]; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [controller start]; });
    });
}
