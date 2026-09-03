// EmberFortnite.m — Ember Connect player-dot overlay for Fortnite 42.10.
//
// Design:
//  - Polls dyld images for FortniteClient-IOS-Shipping, verifies __text SHA-256.
//  - Follows raw pointer chain (no Fortnite function calls, no memory writes):
//      GEngine@0x1147fe0b0 → viewport → world → GameState → PlayerArray → Pawns → Location
//      world → GameInstance → LocalPlayers[0] → PC → PCM → CameraCachePrivate → POV
//  - EmberMenuPanel (same style as GOI/Subnautica) always appears; shows status.
//  - Dots drawn by EmberFortniteDotView (CADisplayLink, read-only, default OFF).
//  - Diagnostics: host Documents/EmberConnect/Fortnite-diag.log

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <CommonCrypto/CommonDigest.h>
#import <math.h>
#import "../Shared/EmberMenu.h"

// ── Build identity ─────────────────────────────────────────────────────────────
#define EMBER_FN_EXPECTED_SHA256 \
    "0c09c05d9e84f4379341898643e5c87e02ea40251a9d6231d3e3a7e7767b0c17"
#define EMBER_FN_BUILD_VERSION   "42.10/57581488.1.4"
#define EMBER_FN_GUEST_BINARY    "FortniteClient-IOS-Shipping"

// ── Unslid addresses (base 0x100000000) ───────────────────────────────────────
#define FN_GENGINE_GLOBAL_UNSLID    ((uintptr_t)0x1147fe0b0)

#define FN_OFF_ENGINE_VIEWPORT      0xb70
#define FN_OFF_VIEWPORT_WORLD       0x070
#define FN_OFF_WORLD_GAMESTATE      0x278
#define FN_OFF_WORLD_GAMEINSTANCE   0x2f0
#define FN_OFF_GI_LOCALPLAYERS_DATA 0x38
#define FN_OFF_LP_CONTROLLER        0x30
#define FN_OFF_PC_CAMERA_MANAGER    0x318
#define FN_OFF_PCM_CACHE_PRIVATE    0x1540   // inline struct, not pointer
#define FN_OFF_CACHE_POV            0x10

// FMinimalViewInfo at cache+0x10:
//   +0x00/08/10 = Location XYZ  (f64)
//   +0x18/20/28 = Rotation Pitch/Yaw/Roll (f64)
//   +0x30       = FOV (f32)

#define FN_OFF_GS_PLAYERARRAY_DATA  0x278
#define FN_OFF_GS_PLAYERARRAY_NUM   0x280
#define FN_OFF_PS_PAWN              0x2d8
#define FN_OFF_PAWN_ROOT            0x1b0
#define FN_OFF_ROOT_LOC_X           0x200
#define FN_OFF_ROOT_LOC_Y           0x208
#define FN_OFF_ROOT_LOC_Z           0x210
#define FN_OFF_PC_ACKNOWLEDGED_PAWN 0x308

#define EMBER_FN_MAX_PLAYERS        100
#define EMBER_FN_DOT_RADIUS_PTS     7.0f
#define EMBER_FN_MAX_DIST_DEFAULT   50000.0
#define EMBER_FN_BUTTON_TAG         0xFB420

// ── Safe reads ────────────────────────────────────────────────────────────────
static inline uintptr_t fn_ptr(uintptr_t addr) {
    if (addr == 0 || (addr & 7)) return 0;
    return *(volatile uintptr_t *)addr;
}
static inline double fn_f64(uintptr_t addr) {
    if (addr == 0 || (addr & 7)) return __builtin_nan("");
    return *(volatile double *)addr;
}
static inline float fn_f32(uintptr_t addr) {
    if (addr == 0 || (addr & 3)) return __builtin_nanf("");
    return *(volatile float *)addr;
}
static inline int32_t fn_i32(uintptr_t addr) {
    if (addr == 0 || (addr & 3)) return 0;
    return *(volatile int32_t *)addr;
}

// ── State ─────────────────────────────────────────────────────────────────────
static uintptr_t g_fn_slide           = 0;
static BOOL      g_fn_binary_verified = NO;
static BOOL      g_fn_dots_enabled    = NO;
static double    g_fn_max_distance    = EMBER_FN_MAX_DIST_DEFAULT;
static BOOL      g_fn_show_labels     = YES;

typedef struct { double x, y, z; BOOL valid; } EmberFnVec3;
typedef struct { EmberFnVec3 loc; BOOL is_local; } EmberFnDot;

static EmberFnDot  g_fn_dots[EMBER_FN_MAX_PLAYERS];
static int         g_fn_dot_count  = 0;
static EmberFnVec3 g_fn_cam_loc    = {0,0,0,NO};
static double      g_fn_cam_pitch  = 0; // radians
static double      g_fn_cam_yaw    = 0;
static float       g_fn_fov        = 90.0f;

// ── Diagnostics ───────────────────────────────────────────────────────────────
static NSMutableString *g_fn_log     = nil;
static NSString        *g_fn_logPath = nil;

static void EmberFnLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void EmberFnLog(NSString *fmt, ...) {
    if (!g_fn_log) g_fn_log = [NSMutableString new];
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%.2f] %@\n", CACurrentMediaTime(), msg];
    NSLog(@"[Ember/FN] %@", msg);
    @synchronized(g_fn_log) { [g_fn_log appendString:line]; }
    if (!g_fn_logPath) {
        // Write to host container Documents — always accessible via ec_device.py
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (dirs.count) {
            NSString *dir = [dirs.firstObject stringByAppendingPathComponent:@"EmberConnect"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            g_fn_logPath = [dir stringByAppendingPathComponent:@"Fortnite-diag.log"];
        }
    }
    if (g_fn_logPath) {
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (d) {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_fn_logPath];
            if (!fh) { [d writeToFile:g_fn_logPath atomically:NO]; }
            else { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; }
        }
    }
}

// ── Window finding (same pattern as GOI) ──────────────────────────────────────
static UIWindow *EmberFnHostWindow(void) {
    for (__kindof UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState == UISceneActivationStateBackground) continue;
        if ([ws respondsToSelector:@selector(keyWindow)] && ws.keyWindow) return ws.keyWindow;
        UIWindow *first = ws.windows.firstObject;
        if (first) return first;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
}

// ── SHA-256 verify ────────────────────────────────────────────────────────────
static BOOL EmberFnVerifyHash(const struct mach_header_64 *mh) {
    const uint8_t *p = (const uint8_t *)(mh + 1);
    uintptr_t start = 0, size = 0;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)p;
            if (strncmp(seg->segname, "__TEXT", 6) == 0) {
                const struct section_64 *sec = (const struct section_64 *)(seg + 1);
                for (uint32_t s = 0; s < seg->nsects; s++, sec++) {
                    if (strncmp(sec->sectname, "__text", 6) == 0) {
                        start = (uintptr_t)mh + sec->offset;
                        size  = sec->size;
                        break;
                    }
                }
            }
        }
        p += lc->cmdsize;
    }
    if (!start || !size) { EmberFnLog(@"hash: __text not found"); return NO; }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256((const void *)start, (CC_LONG)size, digest);
    char hex[65] = {0};
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(hex+2*i, 3, "%02x", digest[i]);
    if (strcmp(hex, EMBER_FN_EXPECTED_SHA256) == 0) {
        EmberFnLog(@"hash OK — %s", EMBER_FN_BUILD_VERSION);
        return YES;
    }
    EmberFnLog(@"hash MISMATCH (got %.16s…)", hex);
    return NO;
}

// ── Binary scan ───────────────────────────────────────────────────────────────
static const struct mach_header_64 *EmberFnFindBinary(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        const char *base = strrchr(name, '/');
        base = base ? base + 1 : name;
        if (strcasecmp(base, EMBER_FN_GUEST_BINARY) == 0)
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
    }
    return NULL;
}

// ── Pointer chain reads ───────────────────────────────────────────────────────
static uintptr_t fn_world(void) {
    uintptr_t eng = fn_ptr(FN_GENGINE_GLOBAL_UNSLID + g_fn_slide);
    if (eng < 0x100000000ULL) return 0;
    uintptr_t vp  = fn_ptr(eng + FN_OFF_ENGINE_VIEWPORT);
    if (vp  < 0x100000000ULL) return 0;
    uintptr_t w   = fn_ptr(vp  + FN_OFF_VIEWPORT_WORLD);
    return (w >= 0x100000000ULL) ? w : 0;
}

static void fn_update_camera(uintptr_t world) {
    uintptr_t gi   = fn_ptr(world + FN_OFF_WORLD_GAMEINSTANCE);
    if (gi < 0x100000000ULL) return;
    uintptr_t lpd  = fn_ptr(gi + FN_OFF_GI_LOCALPLAYERS_DATA);
    if (lpd < 0x100000000ULL) return;
    uintptr_t lp0  = fn_ptr(lpd);
    if (lp0 < 0x100000000ULL) return;
    uintptr_t pc   = fn_ptr(lp0 + FN_OFF_LP_CONTROLLER);
    if (pc  < 0x100000000ULL) return;
    uintptr_t pcm  = fn_ptr(pc  + FN_OFF_PC_CAMERA_MANAGER);
    if (pcm < 0x100000000ULL) return;
    uintptr_t pov  = pcm + FN_OFF_PCM_CACHE_PRIVATE + FN_OFF_CACHE_POV;
    double cx = fn_f64(pov+0x00), cy = fn_f64(pov+0x08), cz = fn_f64(pov+0x10);
    double pitch = fn_f64(pov+0x18), yaw = fn_f64(pov+0x20);
    float  fov   = fn_f32(pov+0x30);
    if (isnan(cx)||isnan(cy)||isnan(cz)||isnan(pitch)||isnan(yaw)) return;
    if (isnan(fov)||fov<5.f||fov>179.f) return;
    g_fn_cam_loc   = (EmberFnVec3){cx, cy, cz, YES};
    g_fn_cam_pitch = pitch * (M_PI/180.0);
    g_fn_cam_yaw   = yaw   * (M_PI/180.0);
    g_fn_fov       = fov;
}

static void fn_update_players(uintptr_t world) {
    uintptr_t gs  = fn_ptr(world + FN_OFF_WORLD_GAMESTATE);
    if (gs < 0x100000000ULL) return;
    uintptr_t data = fn_ptr(gs + FN_OFF_GS_PLAYERARRAY_DATA);
    int32_t   num  = fn_i32(gs + FN_OFF_GS_PLAYERARRAY_NUM);
    if (data < 0x100000000ULL || num <= 0 || num > EMBER_FN_MAX_PLAYERS) return;

    // find local pawn for colouring
    uintptr_t gi = fn_ptr(world + FN_OFF_WORLD_GAMEINSTANCE);
    uintptr_t lpd = (gi>=0x100000000ULL) ? fn_ptr(gi+FN_OFF_GI_LOCALPLAYERS_DATA) : 0;
    uintptr_t lp0 = (lpd>=0x100000000ULL) ? fn_ptr(lpd) : 0;
    uintptr_t lpc = (lp0>=0x100000000ULL) ? fn_ptr(lp0+FN_OFF_LP_CONTROLLER) : 0;
    uintptr_t local_pawn = (lpc>=0x100000000ULL) ? fn_ptr(lpc+FN_OFF_PC_ACKNOWLEDGED_PAWN) : 0;

    int count = 0;
    for (int i = 0; i < num && count < EMBER_FN_MAX_PLAYERS; i++) {
        uintptr_t ps   = fn_ptr(data + (uintptr_t)i * 8);
        if (ps   < 0x100000000ULL) continue;
        uintptr_t pawn = fn_ptr(ps   + FN_OFF_PS_PAWN);
        if (pawn < 0x100000000ULL) continue;
        uintptr_t root = fn_ptr(pawn + FN_OFF_PAWN_ROOT);
        if (root < 0x100000000ULL) continue;
        double px = fn_f64(root+FN_OFF_ROOT_LOC_X);
        double py = fn_f64(root+FN_OFF_ROOT_LOC_Y);
        double pz = fn_f64(root+FN_OFF_ROOT_LOC_Z);
        if (isnan(px)||isnan(py)||isnan(pz)) continue;
        g_fn_dots[count].loc = (EmberFnVec3){px,py,pz,YES};
        g_fn_dots[count].is_local = (pawn == local_pawn);
        count++;
    }
    g_fn_dot_count = count;
}

static void fn_tick(void) {
    if (!g_fn_binary_verified || !g_fn_dots_enabled) { g_fn_dot_count = 0; return; }
    uintptr_t w = fn_world();
    if (!w) { g_fn_dot_count = 0; return; }
    fn_update_camera(w);
    fn_update_players(w);
}

// ── Projection ────────────────────────────────────────────────────────────────
static BOOL fn_project(EmberFnVec3 wl, float aspect, float *sx, float *sy) {
    if (!g_fn_cam_loc.valid) return NO;
    double dx = wl.x - g_fn_cam_loc.x;
    double dy = wl.y - g_fn_cam_loc.y;
    double dz = wl.z - g_fn_cam_loc.z;
    // UE4: X=forward, Y=right, Z=up; yaw rotates XY, pitch tilts forward/up
    double cy = cos(-g_fn_cam_yaw),   sy2 = sin(-g_fn_cam_yaw);
    double cp = cos(-g_fn_cam_pitch), sp  = sin(-g_fn_cam_pitch);
    double rx = dx*cy - dy*sy2;
    double ry = dx*sy2 + dy*cy;
    double rz = dz;
    double fwd   =  rx*cp + rz*sp;
    double right =  ry;
    double up    = -rx*sp + rz*cp;
    if (fwd <= 0.0) return NO;
    double t = tan((g_fn_fov*0.5)*(M_PI/180.0));
    *sx = (float)(0.5 + (right/(fwd*t)) * 0.5);
    *sy = (float)(0.5 - (up   /(fwd*t*aspect)) * 0.5);
    return YES;
}

// ── Dot overlay view ──────────────────────────────────────────────────────────
@interface EmberFortniteDotView : UIView
@end
@implementation EmberFortniteDotView {
    CADisplayLink *_dl;
}
- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        self.opaque = NO;
        _dl = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        _dl.preferredFramesPerSecond = 60;
        [_dl addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}
- (void)dealloc { [_dl invalidate]; }
- (void)tick:(CADisplayLink *)dl { fn_tick(); [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)r {
    if (!g_fn_dots_enabled || !g_fn_cam_loc.valid) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (W<=0||H<=0) return;
    float asp = (float)(W/H);
    int n = g_fn_dot_count;
    EmberFnDot snap[EMBER_FN_MAX_PLAYERS];
    memcpy(snap, g_fn_dots, n * sizeof(EmberFnDot));
    EmberFnVec3 cam = g_fn_cam_loc;
    for (int i = 0; i < n; i++) {
        if (!snap[i].loc.valid || snap[i].is_local) continue;
        double ddx = snap[i].loc.x-cam.x, ddy = snap[i].loc.y-cam.y, ddz = snap[i].loc.z-cam.z;
        double dist = sqrt(ddx*ddx+ddy*ddy+ddz*ddz);
        if (dist > g_fn_max_distance) continue;
        float sx=0, sy=0;
        if (!fn_project(snap[i].loc, asp, &sx, &sy)) continue;
        if (sx<-0.05f||sx>1.05f||sy<-0.05f||sy>1.05f) continue;
        CGFloat px = sx*W, py = sy*H;
        CGFloat rad = MAX(3.0, EMBER_FN_DOT_RADIUS_PTS * (1000.0/(dist>1000?dist:1000)));
        rad = MIN(rad, EMBER_FN_DOT_RADIUS_PTS);
        // red dot
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:1 green:0.18 blue:0.18 alpha:0.92].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(px-rad, py-rad, rad*2, rad*2));
        // white ring
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.75].CGColor);
        CGContextSetLineWidth(ctx, 1.5);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(px-rad, py-rad, rad*2, rad*2));
        if (g_fn_show_labels) {
            NSString *lbl = [NSString stringWithFormat:@"%.0fm", dist/100.0];
            NSDictionary *a = @{
                NSFontAttributeName: [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold],
                NSForegroundColorAttributeName: UIColor.whiteColor
            };
            CGSize ts = [lbl sizeWithAttributes:a];
            [lbl drawAtPoint:CGPointMake(px-ts.width/2, py+rad+2) withAttributes:a];
        }
    }
}
@end

// ── Main controller ───────────────────────────────────────────────────────────
@interface EmberFnController : NSObject
@property (nonatomic, strong) UIButton           *button;
@property (nonatomic, strong) EmberMenuPanel     *panel;
@property (nonatomic, strong) EmberFortniteDotView *dotView;
@property (nonatomic, strong) NSTimer            *keepAliveTimer;
+ (instancetype)shared;
- (void)start;
@end

@implementation EmberFnController

+ (instancetype)shared {
    static EmberFnController *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [EmberFnController new]; });
    return s;
}

- (NSString *)statusString {
    if (!g_fn_binary_verified) return @"SEARCHING…";
    if (!g_fn_dots_enabled)    return @"READY  |  DOTS OFF";
    return [NSString stringWithFormat:@"LIVE  |  %d player%s",
            g_fn_dot_count, g_fn_dot_count==1?"":"s"];
}

- (void)install {
    UIWindow *win = EmberFnHostWindow();
    if (!win) return;

    // ── dot view ──
    if (!self.dotView) {
        self.dotView = [[EmberFortniteDotView alloc] initWithFrame:win.bounds];
        self.dotView.hidden = !g_fn_dots_enabled;
        [win addSubview:self.dotView];
    } else if (self.dotView.superview != win) {
        [self.dotView removeFromSuperview];
        [win addSubview:self.dotView];
    }
    self.dotView.frame = win.bounds;
    [win bringSubviewToFront:self.dotView];

    // ── button ──
    if (!self.button) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = EMBER_FN_BUTTON_TAG;
        btn.frame = CGRectMake(0, 0, 100, 36);
        CGFloat bx = win.bounds.size.width - 60;
        CGFloat by = win.bounds.size.height * 0.4;
        btn.center = CGPointMake(bx, by);
        btn.backgroundColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.1 alpha:0.85];
        btn.layer.cornerRadius = 11;
        btn.layer.borderWidth = 1;
        btn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
        [btn setTitle:@"🔥 Dots" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [btn addTarget:self action:@selector(buttonTapped)
      forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(dragged:)];
        [btn addGestureRecognizer:pan];
        [win addSubview:btn];
        self.button = btn;
    } else if (self.button.superview != win) {
        [self.button removeFromSuperview];
        [win addSubview:self.button];
    }
    [win bringSubviewToFront:self.button];
    if (self.panel) [win bringSubviewToFront:self.panel];
    [self updateButton];
}

- (void)updateButton {
    NSString *title = g_fn_dots_enabled ? @"🔥 ON" : @"🔥 Dots";
    [self.button setTitle:title forState:UIControlStateNormal];
    self.button.backgroundColor = g_fn_dots_enabled
        ? [UIColor colorWithRed:0.15 green:0.85 blue:0.3 alpha:0.9]
        : [UIColor colorWithRed:1.0  green:0.45 blue:0.1 alpha:0.85];
    if (self.panel) [self.panel setStatus:[self statusString]];
}

- (void)buttonTapped {
    [self openPanel];
}

- (void)dragged:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint t = [pan translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [pan setTranslation:CGPointZero inView:v.superview];
}

- (void)openPanel {
    if (self.panel) { [self closePanel]; return; }
    UIWindow *win = EmberFnHostWindow();
    if (!win) return;

    EmberMenuPanel *panel = [[EmberMenuPanel alloc] initWithTitle:@"Ember Fortnite"
                                                      accentColor:[UIColor colorWithRed:1 green:0.45 blue:0.1 alpha:1]];
    __weak typeof(self) ws = self;
    panel.onClose = ^{ [ws closePanel]; };
    [self buildPanel:panel];
    [panel presentInWindow:win];
    self.panel = panel;
    [win bringSubviewToFront:self.dotView];
}

- (void)buildPanel:(EmberMenuPanel *)panel {
    [panel setStatus:[self statusString]];
    __weak EmberMenuPanel *wpanel = panel;
    __weak typeof(self) wself = self;
    [panel setTabs:@[@"Dots", @"Info"] activeTab:0 handler:^(NSInteger idx) {
        if (wpanel) { [wpanel clearRows]; [wself fillTab:idx panel:wpanel]; }
    }];
    [self fillTab:0 panel:panel];
}

- (void)fillTab:(NSInteger)tab panel:(EmberMenuPanel *)panel {
    if (tab == 0) {
        // ── Dots tab ──
        BOOL ready = g_fn_binary_verified;
        [panel addSection:@"Player Dots"];
        [panel addToggle:@"Show dots"
                  detail:(ready ? @"Highlights other players" : @"Waiting for Fortnite binary…")
                 enabled:g_fn_dots_enabled
                 handler:^(BOOL on) {
            if (!g_fn_binary_verified) { [panel setStatus:@"Binary not verified yet"]; return; }
            g_fn_dots_enabled = on;
            if (self.dotView) self.dotView.hidden = !on;
            [self updateButton];
            EmberFnLog(@"dots toggled %@", on?@"ON":@"OFF");
        }];
        [panel addToggle:@"Distance labels"
                  detail:@"Show metres below each dot"
                 enabled:g_fn_show_labels
                 handler:^(BOOL on) {
            g_fn_show_labels = on;
        }];
        [panel addSection:@"Range"];
        [panel addSlider:@"Max distance"
                   value:(float)(g_fn_max_distance/100.0)
                     min:10.0f max:1000.0f
                  format:@"%.0f m"
                 handler:^(float v) {
            g_fn_max_distance = v * 100.0; // m → UU
        }];
    } else {
        // ── Info tab ──
        BOOL ready = g_fn_binary_verified;
        [panel addSection:@"Build"];
        [panel addAction:(ready ? @"✓ Fortnite 42.10 verified" : @"⏳ Searching for binary…")
                  detail:@"" handler:^{}];
        [panel addAction:[NSString stringWithFormat:@"Slide: 0x%lx", (unsigned long)g_fn_slide]
                  detail:@"" handler:^{}];
        [panel addSection:@"Chain status"];
        uintptr_t w = ready ? fn_world() : 0;
        [panel addAction:(w ? @"✓ World found" : @"✗ World not found")
                  detail:@"" handler:^{}];
        [panel addAction:(g_fn_cam_loc.valid ? @"✓ Camera valid" : @"✗ Camera not read yet")
                  detail:@"" handler:^{}];
        [panel addAction:[NSString stringWithFormat:@"%d player(s) in array", g_fn_dot_count]
                  detail:@"" handler:^{}];
    }
}

- (void)closePanel {
    [self.panel removeFromSuperview];
    self.panel = nil;
}

- (void)start {
    [self install];
    __weak typeof(self) ws = self;
    self.keepAliveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                          repeats:YES
                                                            block:^(NSTimer *_) {
        [ws install];
        [ws updateButton];
    }];
}
@end

// ── Constructor ────────────────────────────────────────────────────────────────
__attribute__((constructor))
static void EmberFortniteInit(void) {
    EmberFnLog(@"constructor — polling for %s", EMBER_FN_GUEST_BINARY);
    // Start the UI immediately (shows "SEARCHING…")
    dispatch_async(dispatch_get_main_queue(), ^{
        [[EmberFnController shared] start];
    });
    // Binary polling on background thread
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        for (int i = 0; i < 240; i++) {   // up to 2 minutes
            [NSThread sleepForTimeInterval:0.5];
            const struct mach_header_64 *mh = EmberFnFindBinary();
            if (!mh) {
                if (i % 20 == 0) EmberFnLog(@"poll %d: binary not found yet", i);
                continue;
            }
            intptr_t slide = (intptr_t)mh - (intptr_t)0x100000000;
            EmberFnLog(@"found at %p slide=0x%lx (attempt %d)", mh, (long)slide, i);
            if (slide < 0) { EmberFnLog(@"negative slide — aborting"); return; }
            if (!EmberFnVerifyHash(mh)) return;
            g_fn_slide = (uintptr_t)slide;
            g_fn_binary_verified = YES;
            EmberFnLog(@"ready — dots default OFF, tap 🔥 to open menu");
            return;
        }
        EmberFnLog(@"gave up after 120s — binary not found");
    });
}
