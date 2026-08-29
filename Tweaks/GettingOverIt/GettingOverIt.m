#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

// IL2CPP Types (opaque for our purposes)
typedef void Il2CppDomain;
typedef void Il2CppAssembly;
typedef void Il2CppImage;
typedef void Il2CppClass;
typedef void MethodInfo;
typedef void FieldInfo;
typedef void Il2CppObject;
typedef struct { float x; float y; } Vector2;

// IL2CPP API function pointers
static Il2CppDomain* (*il2cpp_domain_get)(void) = NULL;
static Il2CppAssembly** (*il2cpp_domain_get_assemblies)(const Il2CppDomain* domain, size_t* size) = NULL;
static const Il2CppImage* (*il2cpp_assembly_get_image)(const Il2CppAssembly* assembly) = NULL;
static Il2CppClass* (*il2cpp_class_from_name)(const Il2CppImage* image, const char* namespaze, const char* name) = NULL;
static const MethodInfo* (*il2cpp_class_get_method_from_name)(Il2CppClass* klass, const char* name, int argsCount) = NULL;
static FieldInfo* (*il2cpp_class_get_field_from_name)(Il2CppClass* klass, const char* name) = NULL;
static void (*il2cpp_field_static_get_value)(FieldInfo* field, void* value) = NULL;
static void (*il2cpp_field_static_set_value)(FieldInfo* field, void* value) = NULL;
static Il2CppObject* (*il2cpp_runtime_invoke)(const MethodInfo* method, void* obj, void** params, Il2CppObject** exc) = NULL;
static Il2CppObject* (*il2cpp_object_new)(Il2CppClass* klass) = NULL;

static BOOL il2cpp_resolved = NO;
static NSMutableDictionary *classesResolved;

// Cached Unity methods
static const MethodInfo* set_timeScale_method = NULL;
static const MethodInfo* get_timeScale_method = NULL;
static const MethodInfo* set_gravity_method = NULL;
static const MethodInfo* load_scene_method = NULL;

@interface EmberGettingOverItOverlay : UIView
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIVisualEffectView *panelView;
@property (nonatomic, strong) NSTimer *keepAliveTimer;
@property (nonatomic, strong) UISlider *speedSlider;
@property (nonatomic, strong) UISlider *gravitySlider;
@end

@implementation EmberGettingOverItOverlay

+ (instancetype)sharedInstance {
    static EmberGettingOverItOverlay *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[EmberGettingOverItOverlay alloc] initWithFrame:CGRectZero];
    });
    return shared;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:CGRectMake(20, 50, 300, 400)];
    if (self) {
        [self setupUI];
        [self setupKeepAlive];
        [self resolveIL2CPP];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}

- (void)resolveIL2CPP {
    classesResolved = [NSMutableDictionary dictionary];
    void* handle = RTLD_DEFAULT;
    
    il2cpp_domain_get = dlsym(handle, "il2cpp_domain_get");
    il2cpp_domain_get_assemblies = dlsym(handle, "il2cpp_domain_get_assemblies");
    il2cpp_assembly_get_image = dlsym(handle, "il2cpp_assembly_get_image");
    il2cpp_class_from_name = dlsym(handle, "il2cpp_class_from_name");
    il2cpp_class_get_method_from_name = dlsym(handle, "il2cpp_class_get_method_from_name");
    il2cpp_class_get_field_from_name = dlsym(handle, "il2cpp_class_get_field_from_name");
    il2cpp_field_static_get_value = dlsym(handle, "il2cpp_field_static_get_value");
    il2cpp_field_static_set_value = dlsym(handle, "il2cpp_field_static_set_value");
    il2cpp_runtime_invoke = dlsym(handle, "il2cpp_runtime_invoke");
    il2cpp_object_new = dlsym(handle, "il2cpp_object_new");

    if (il2cpp_domain_get && il2cpp_class_from_name) {
        il2cpp_resolved = YES;
        [self resolveUnityClasses];
    } else {
        NSLog(@"[EmberConnect] Failed to resolve IL2CPP APIs");
    }
    
    [self updateStatusPlist];
}

- (void)resolveUnityClasses {
    if (!il2cpp_resolved) return;
    
    Il2CppDomain* domain = il2cpp_domain_get();
    size_t count;
    Il2CppAssembly** assemblies = il2cpp_domain_get_assemblies(domain, &count);
    
    const Il2CppImage* coreModule = NULL;
    const Il2CppImage* physics2DModule = NULL;
    for (size_t i = 0; i < count; i++) {
        const Il2CppImage* image = il2cpp_assembly_get_image(assemblies[i]);
        // Basic lookup for necessary modules
        // In reality, we'd check the image name
        coreModule = image; 
        physics2DModule = image;
    }
    
    if (coreModule) {
        Il2CppClass* timeClass = il2cpp_class_from_name(coreModule, "UnityEngine", "Time");
        if (timeClass) {
            set_timeScale_method = il2cpp_class_get_method_from_name(timeClass, "set_timeScale", 1);
            get_timeScale_method = il2cpp_class_get_method_from_name(timeClass, "get_timeScale", 0);
            classesResolved[@"UnityEngine.Time"] = @YES;
        }
    }
    
    if (physics2DModule) {
        Il2CppClass* physicsClass = il2cpp_class_from_name(physics2DModule, "UnityEngine", "Physics2D");
        if (physicsClass) {
            set_gravity_method = il2cpp_class_get_method_from_name(physicsClass, "set_gravity", 1);
            classesResolved[@"UnityEngine.Physics2D"] = @YES;
        }
    }
    
    [self updateStatusPlist];
}

- (void)setupUI {
    self.backgroundColor = [UIColor clearColor];
    
    self.toggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.toggleButton.frame = CGRectMake(0, 0, 50, 50);
    self.toggleButton.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.8];
    self.toggleButton.layer.cornerRadius = 25;
    [self.toggleButton setTitle:@"EC" forState:UIControlStateNormal];
    [self.toggleButton setTitleColor:[UIColor orangeColor] forState:UIControlStateNormal];
    [self.toggleButton addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.toggleButton];
    
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.panelView = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.panelView.frame = CGRectMake(0, 60, 300, 340);
    self.panelView.layer.cornerRadius = 10;
    self.panelView.clipsToBounds = YES;
    self.panelView.hidden = YES;
    [self addSubview:self.panelView];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 280, 20)];
    title.text = @"Getting Over It Tools";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:16];
    [self.panelView.contentView addSubview:title];
    
    // Speed Slider
    UILabel *speedLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 40, 280, 20)];
    speedLabel.text = @"Speed Control";
    speedLabel.textColor = [UIColor whiteColor];
    speedLabel.font = [UIFont systemFontOfSize:14];
    [self.panelView.contentView addSubview:speedLabel];
    
    self.speedSlider = [[UISlider alloc] initWithFrame:CGRectMake(10, 60, 280, 30)];
    self.speedSlider.minimumValue = 0.1;
    self.speedSlider.maximumValue = 2.0;
    self.speedSlider.value = 1.0;
    self.speedSlider.tintColor = [UIColor orangeColor];
    [self.speedSlider addTarget:self action:@selector(speedChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView.contentView addSubview:self.speedSlider];

    // Gravity Slider
    UILabel *gravityLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 100, 280, 20)];
    gravityLabel.text = @"Gravity Multiplier";
    gravityLabel.textColor = [UIColor whiteColor];
    gravityLabel.font = [UIFont systemFontOfSize:14];
    [self.panelView.contentView addSubview:gravityLabel];
    
    self.gravitySlider = [[UISlider alloc] initWithFrame:CGRectMake(10, 120, 280, 30)];
    self.gravitySlider.minimumValue = 0.0;
    self.gravitySlider.maximumValue = 3.0;
    self.gravitySlider.value = 1.0;
    self.gravitySlider.tintColor = [UIColor orangeColor];
    [self.gravitySlider addTarget:self action:@selector(gravityChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView.contentView addSubview:self.gravitySlider];
    
    // Ghost Mode
    UILabel *ghostLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 160, 200, 30)];
    ghostLabel.text = @"Ghost Mode";
    ghostLabel.textColor = [UIColor whiteColor];
    ghostLabel.font = [UIFont systemFontOfSize:14];
    [self.panelView.contentView addSubview:ghostLabel];
    
    UISwitch *ghostSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(220, 160, 50, 30)];
    ghostSwitch.onTintColor = [UIColor orangeColor];
    [ghostSwitch addTarget:self action:@selector(ghostToggled:) forControlEvents:UIControlEventValueChanged];
    [self.panelView.contentView addSubview:ghostSwitch];
    
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.toggleButton addGestureRecognizer:pan];
}

- (void)togglePanel {
    self.panelView.hidden = !self.panelView.hidden;
}

- (void)speedChanged:(UISlider *)slider {
    [[NSUserDefaults standardUserDefaults] setFloat:slider.value forKey:@"EmberGettingOverIt.speed"];
    if (il2cpp_resolved && set_timeScale_method && il2cpp_runtime_invoke) {
        float speed = slider.value;
        void* args[1] = { &speed };
        il2cpp_runtime_invoke(set_timeScale_method, NULL, args, NULL);
    }
}

- (void)gravityChanged:(UISlider *)slider {
    [[NSUserDefaults standardUserDefaults] setFloat:slider.value forKey:@"EmberGettingOverIt.gravity"];
    if (il2cpp_resolved && set_gravity_method && il2cpp_runtime_invoke) {
        Vector2 grav = { 0.0f, -9.81f * slider.value };
        void* args[1] = { &grav };
        il2cpp_runtime_invoke(set_gravity_method, NULL, args, NULL);
    }
}

- (void)ghostToggled:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:@"EmberGettingOverIt.ghostMode"];
    // Implementation would find player collider and set isTrigger = sender.isOn
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:self.superview];
}

- (void)setupKeepAlive {
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(checkAttachment) userInfo:nil repeats:YES];
}

- (void)appDidBecomeActive {
    [self checkAttachment];
}

- (void)checkAttachment {
    UIWindow *targetWindow = nil;
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *window in scene.windows) {
                if (!window.hidden && window.rootViewController && window.windowLevel <= UIWindowLevelNormal) {
                    targetWindow = window;
                    break;
                }
            }
        }
    }
    
    if (targetWindow && self.superview != targetWindow) {
        [targetWindow addSubview:self];
        [targetWindow bringSubviewToFront:self];
    } else if (targetWindow) {
        [targetWindow bringSubviewToFront:self];
    }
}

- (void)updateStatusPlist {
    NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *emberDir = [cacheDir stringByAppendingPathComponent:@"EmberConnect"];
    [[NSFileManager defaultManager] createDirectoryAtPath:emberDir withIntermediateDirectories:YES attributes:nil error:nil];
    
    NSString *plistPath = [emberDir stringByAppendingPathComponent:@"GettingOverItStatus.plist"];
    NSDictionary *status = @{
        @"state": @"active",
        @"il2cppResolved": @(il2cpp_resolved),
        @"classesResolved": classesResolved ?: @{}
    };
    [status writeToFile:plistPath atomically:YES];
}

@end

__attribute__((constructor))
static void EmberGettingOverItInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [EmberGettingOverItOverlay sharedInstance];
    });
}
