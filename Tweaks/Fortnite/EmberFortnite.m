// EmberFortnite.m — Ember Connect player-dot overlay for Fortnite 42.10.
//
// Design:
//  - Polls dyld images for FortniteClient-IOS-Shipping, verifies __text SHA-256.
//  - Follows raw pointer chain (no Fortnite function calls, no memory writes):
//      GEngine@0x1147fe0b0 → viewport → world → GameState → PlayerArray → Pawns → Location
//      world → GameInstance → LocalPlayers[0] → PC → PCM → CameraCachePrivate → POV
//      PC+0x364 normalized render FOV (same source as Windows get_view_point)
//  - EmberMenuPanel (same style as GOI/Subnautica) always appears; shows status.
//  - Dots drawn by EmberFortniteDotView (CADisplayLink, read-only, default OFF).
//  - Diagnostics: host Documents/EmberConnect/Fortnite-diag.log

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <math.h>
#import <objc/runtime.h>
#import <string.h>
#import "../Shared/EmberMenu.h"
#import "EmberFortniteProjection.h"

// ── Build identity ─────────────────────────────────────────────────────────────
// Whole-file SHA-256 0c09c05d… is NOT the __text hash. Live __text is
// 6197060b… (206,163,608 bytes). Runtime lock uses LC_UUID + __text size.
#define EMBER_FN_BUILD_VERSION   "42.10/57581488.1.4"
#define EMBER_FN_GUEST_BINARY    "FortniteClient-IOS-Shipping"
#define EMBER_FN_TEXT_SIZE       206163608ULL
static const uint8_t EmberFnExpectedUUID[16] = {
    0x31,0xd1,0xec,0x91,0x7d,0xde,0x31,0x25,0x8f,0x33,0x75,0xaa,0x02,0x3b,0x83,0x4d
};

// ── Unslid addresses (base 0x100000000) ───────────────────────────────────────
#define FN_GENGINE_GLOBAL_UNSLID    ((uintptr_t)0x1147fe0b0)

#define FN_OFF_ENGINE_VIEWPORT      0xb70
#define FN_OFF_VIEWPORT_WORLD       0x070
#define FN_OFF_WORLD_GAMESTATE      0x278
#define FN_OFF_WORLD_GAMEINSTANCE   0x2f0
#define FN_OFF_GI_LOCALPLAYERS_DATA 0x38
#define FN_OFF_LP_CONTROLLER        0x30
#define FN_OFF_LP_ASPECT_AXIS       0xb8   // EAspectRatioAxisConstraint byte
#define FN_OFF_PC_CAMERA_MANAGER    0x318
#define FN_OFF_PC_CAMERA_FOV        0x364  // normalized FOV; render degrees = value * 90
#define FN_OFF_PCM_CACHE_PRIVATE    0x1540  // inline FCameraCacheEntry
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
#define FN_OFF_POV_ASPECT           0x5c    // FMinimalViewInfo.AspectRatio (float)

#define EMBER_FN_MAX_PLAYERS        100
#define EMBER_FN_DOT_RADIUS_PTS     5.0f
#define EMBER_FN_MAX_DIST_DEFAULT   50000.0
#define EMBER_FN_BUTTON_TAG         0xFB420
#define FN_CAPSULE_HALF_HEIGHT      88.0
#define FN_PLAYER_HEIGHT            176.0   // feet→head estimate (2× half-height)

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
static NSString *g_fn_status          = @"SEARCHING…";
static BOOL      g_fn_dots_enabled    = NO;
static BOOL      g_fn_box_enabled     = YES;
static BOOL      g_fn_snapline_enabled = NO;
static double    g_fn_max_distance    = EMBER_FN_MAX_DIST_DEFAULT;
static BOOL      g_fn_show_labels     = YES;

typedef struct { double x, y, z; BOOL valid; } EmberFnVec3;
typedef struct {
    EmberFnVec3 feet;
    EmberFnVec3 head;
    BOOL is_local;
} EmberFnDot;

static EmberFnDot  g_fn_dots[EMBER_FN_MAX_PLAYERS];
static int         g_fn_dot_count  = 0;
static EmberFnVec3 g_fn_cam_loc    = {0,0,0,NO};
// Stored in DEGREES like the Windows Camera.Rotation (x=pitch, y=yaw, z=roll).
static double      g_fn_cam_pitch  = 0;
static double      g_fn_cam_yaw    = 0;
static double      g_fn_cam_roll   = 0;
static float       g_fn_fov        = 80.0f;
static float       g_fn_pov_fov    = 0.0f;
static float       g_fn_fov_scalar = 0.0f;
static BOOL        g_fn_logged_camera_source = NO;
static uint8_t     g_fn_aspect_axis = 1; // fail-safe: MaintainXFOV
static uint8_t     g_fn_storekit_suppression_mask = 0;

static void EmberFnSuppressStoreKitPrompts(void);

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

static BOOL EmberFnPathLooksLikeFortnite(const char *name) {
    if (!name) return NO;
    if (strcasestr(name, "FortniteClient") != NULL) return YES;
    if (strcasestr(name, "FortniteGame") != NULL) return YES;
    if (strcasestr(name, "fortnite") != NULL) return YES;
    return NO;
}

static void EmberFnLogImageInventory(void) {
    uint32_t n = _dyld_image_count();
    EmberFnLog(@"dyld image count=%u (LiveContainer remaps index 0 to the guest)", n);
    uint32_t limit = n < 24 ? n : 24;
    for (uint32_t i = 0; i < limit; i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header *mh = _dyld_get_image_header(i);
        EmberFnLog(@"  [%u] %s mh=%p", i, name ? name : "(null)", mh);
    }
}

static BOOL EmberFnReadUUID(const struct mach_header_64 *mh, uint8_t uuid[16], uint64_t *textSize) {
    if (!mh || mh->magic != MH_MAGIC_64) return NO;
    memset(uuid, 0, 16);
    if (textSize) *textSize = 0;
    const uint8_t *p = (const uint8_t *)(mh + 1);
    const uint8_t *end = p + mh->sizeofcmds;
    BOOL gotUUID = NO;
    for (uint32_t i = 0; i < mh->ncmds && p + sizeof(struct load_command) <= end; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmdsize < sizeof(*lc) || p + lc->cmdsize > end) break;
        if (lc->cmd == LC_UUID && lc->cmdsize >= sizeof(struct uuid_command)) {
            memcpy(uuid, ((const struct uuid_command *)lc)->uuid, 16);
            gotUUID = YES;
        }
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)p;
            if (strncmp(seg->segname, "__TEXT", 6) == 0) {
                const struct section_64 *sec = (const struct section_64 *)(seg + 1);
                for (uint32_t s = 0; s < seg->nsects; s++, sec++) {
                    if (strncmp(sec->sectname, "__text", 6) == 0) {
                        if (textSize) *textSize = sec->size;
                        break;
                    }
                }
            }
        }
        p += lc->cmdsize;
    }
    return gotUUID;
}

static BOOL EmberFnVerifyBuild(const struct mach_header_64 *mh, uint32_t imageIndex) {
    uint8_t uuid[16];
    uint64_t textSize = 0;
    if (!EmberFnReadUUID(mh, uuid, &textSize)) {
        EmberFnLog(@"verify: no LC_UUID on image %u", imageIndex);
        g_fn_status = @"NO UUID ON IMAGE";
        return NO;
    }
    char hex[33] = {0};
    for (int i = 0; i < 16; i++) snprintf(hex + 2 * i, 3, "%02x", uuid[i]);
    EmberFnLog(@"image %u uuid=%s __text=%llu", imageIndex, hex, (unsigned long long)textSize);
    if (memcmp(uuid, EmberFnExpectedUUID, 16) != 0) {
        EmberFnLog(@"uuid mismatch — not 42.10");
        g_fn_status = [NSString stringWithFormat:@"WRONG UUID %.8s", hex];
        return NO;
    }
    if (textSize && textSize != EMBER_FN_TEXT_SIZE) {
        EmberFnLog(@"__text size mismatch got %llu expected %llu",
                   (unsigned long long)textSize, (unsigned long long)EMBER_FN_TEXT_SIZE);
        g_fn_status = @"WRONG __TEXT SIZE";
        return NO;
    }
    EmberFnLog(@"build OK — %s", EMBER_FN_BUILD_VERSION);
    return YES;
}

// LiveContainer hooks _dyld_get_image_name so index 0 is the guest, not the host.
static const struct mach_header_64 *EmberFnFindBinary(uint32_t *outIndex) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!EmberFnPathLooksLikeFortnite(name)) continue;
        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!mh || mh->magic != MH_MAGIC_64) continue;
        if (outIndex) *outIndex = i;
        return mh;
    }
    if (n > 0) {
        const char *name0 = _dyld_get_image_name(0);
        const struct mach_header_64 *mh0 = (const struct mach_header_64 *)_dyld_get_image_header(0);
        if (mh0 && mh0->magic == MH_MAGIC_64) {
            EmberFnLog(@"no fortnite path; trying hooked image 0: %s", name0 ? name0 : "(null)");
            if (outIndex) *outIndex = 0;
            return mh0;
        }
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

// Contiguous POV header (Location + Rotation + FOV). Copied as one block so a
// concurrent camera update cannot tear Location from Rotation — that tear is
// exactly what makes ESP slide off when you look around.
typedef struct {
    double loc_x, loc_y, loc_z;
    double pitch, yaw, roll;
    float  fov;
} EmberFnPovHeader;

static BOOL fn_pov_header_ok(const EmberFnPovHeader *h) {
    if (!h) return NO;
    if (isnan(h->loc_x)||isnan(h->loc_y)||isnan(h->loc_z)) return NO;
    if (isnan(h->pitch)||isnan(h->yaw)||isnan(h->roll)) return NO;
    if (isnan(h->fov)||h->fov < 5.f||h->fov > 179.f) return NO;
    if (fabs(h->loc_x) > 1e7 || fabs(h->loc_y) > 1e7 || fabs(h->loc_z) > 1e7) return NO;
    if (fabs(h->pitch) > 360.0 || fabs(h->yaw) > 720.0 || fabs(h->roll) > 360.0) return NO;
    return YES;
}

static BOOL fn_apply_pov_header(const EmberFnPovHeader *use) {
    if (!fn_pov_header_ok(use)) return NO;
    g_fn_cam_loc   = (EmberFnVec3){use->loc_x, use->loc_y, use->loc_z, YES};
    g_fn_cam_pitch = use->pitch;
    g_fn_cam_yaw   = use->yaw;
    g_fn_cam_roll  = use->roll;
    g_fn_pov_fov   = use->fov;
    g_fn_fov       = use->fov;
    return YES;
}

static BOOL fn_read_camera_cache(uintptr_t cache) {
    if (cache < 0x100000000ULL || (cache & 7)) return NO;

    // FCameraCacheEntry begins with a double timestamp. Accept the POV only if
    // the timestamp is identical on both sides of the copy, so we never combine
    // fields from two camera updates.
    for (int attempt = 0; attempt < 3; attempt++) {
        uint64_t before = *(volatile uint64_t *)cache;
        EmberFnPovHeader header = {0};
        memcpy(&header, (const void *)(cache + FN_OFF_CACHE_POV), sizeof(header));
        uint64_t after = *(volatile uint64_t *)cache;
        if (before == after &&
            fn_apply_pov_header(&header)) return YES;
    }
    return NO;
}

static BOOL fn_update_camera(uintptr_t world) {
    uintptr_t gi   = fn_ptr(world + FN_OFF_WORLD_GAMEINSTANCE);
    if (gi < 0x100000000ULL) return NO;
    uintptr_t lpd  = fn_ptr(gi + FN_OFF_GI_LOCALPLAYERS_DATA);
    if (lpd < 0x100000000ULL) return NO;
    uintptr_t lp0  = fn_ptr(lpd);
    if (lp0 < 0x100000000ULL) return NO;
    uintptr_t pc   = fn_ptr(lp0 + FN_OFF_LP_CONTROLLER);
    if (pc  < 0x100000000ULL) return NO;
    uint8_t axis = *(volatile uint8_t *)(lp0 + FN_OFF_LP_ASPECT_AXIS);
    g_fn_aspect_axis = axis <= 2 ? axis : 1;
    uintptr_t pcm  = fn_ptr(pc  + FN_OFF_PC_CAMERA_MANAGER);
    if (pcm < 0x100000000ULL) return NO;

    // Location/rotation come from the exact POV returned by Fortnite's PCM
    // camera getters. The Windows source's get_view_point does NOT use POV.FOV:
    // it reads a normalized render FOV from PlayerController and multiplies by
    // 90. Static ARM64 evidence for 42.10 iOS does the same PC+0x364 load while
    // constructing view data, so use that source here as well.
    if (!fn_read_camera_cache(pcm + FN_OFF_PCM_CACHE_PRIVATE)) return NO;
    float scalar = fn_f32(pc + FN_OFF_PC_CAMERA_FOV);
    float renderFov = (float)EmberFnRenderFovDegrees(scalar, g_fn_pov_fov);
    if (!isnan(scalar) && fabsf(renderFov - scalar * 90.0f) < 0.001f) {
        g_fn_fov_scalar = scalar;
        g_fn_fov = renderFov;
    } else {
        g_fn_fov_scalar = 0.0f;
    }
    if (!g_fn_logged_camera_source) {
        g_fn_logged_camera_source = YES;
        EmberFnLog(@"camera source: PCM POV loc/rot; POV.FOV=%.3f PC+0x364=%.6f renderFOV=%.3f axis=%u",
                   g_fn_pov_fov, scalar, g_fn_fov, g_fn_aspect_axis);
    }
    return YES;
}

static float fn_capsule_half_height(uintptr_t root) {
    // UCapsuleComponent::CapsuleHalfHeight candidate on this build.
    float h = fn_f32(root + 0x57c);
    if (!isnan(h) && h > 40.f && h < 120.f) return h;
    return 80.f; // Fortnite players are shorter than the default 88 mannequin
}

static void fn_update_players(uintptr_t world) {
    g_fn_dot_count = 0;
    uintptr_t gs  = fn_ptr(world + FN_OFF_WORLD_GAMESTATE);
    if (gs < 0x100000000ULL) return;
    uintptr_t data = fn_ptr(gs + FN_OFF_GS_PLAYERARRAY_DATA);
    int32_t   num  = fn_i32(gs + FN_OFF_GS_PLAYERARRAY_NUM);
    if (data < 0x100000000ULL || num <= 0 || num > EMBER_FN_MAX_PLAYERS) return;

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
        double half = (double)fn_capsule_half_height(root);
        // Capsule centre → feet / head. Slightly less than full half-height so the
        // marker sits on the soles, not underground (mesh sits inside the capsule).
        EmberFnVec3 feet = { px, py, pz - half * 0.92, YES };
        EmberFnVec3 head = { px, py, pz + half * 0.95, YES };
        g_fn_dots[count].feet = feet;
        g_fn_dots[count].head = head;
        g_fn_dots[count].is_local = (pawn == local_pawn);
        count++;
    }
    g_fn_dot_count = count;
}

static void fn_tick(void) {
    if (!g_fn_binary_verified || !g_fn_dots_enabled) { g_fn_dot_count = 0; return; }
    uintptr_t w = fn_world();
    if (!w) { g_fn_dot_count = 0; return; }
    if (!fn_update_camera(w)) {
        g_fn_cam_loc.valid = NO;
        g_fn_dot_count = 0;
        return;
    }
    fn_update_players(w);
}

// ── Projection ────────────────────────────────────────────────────────────────
// Unreal FRotationMatrix axes (same as Windows to_matrix with roll). FOV is
// horizontal; both axes use (width/2)/tan(halfFov). No 16:9 fudge.
static BOOL fn_project(EmberFnVec3 wl, float width, float height, float *out_x, float *out_y) {
    if (!g_fn_cam_loc.valid || width <= 1.f || height <= 1.f) return NO;
    double x = 0, y = 0;
    BOOL visible = EmberFnProjectWorldPoint(
        (EmberFnProjectionVec3){wl.x, wl.y, wl.z},
        (EmberFnProjectionVec3){g_fn_cam_loc.x, g_fn_cam_loc.y, g_fn_cam_loc.z},
        g_fn_cam_pitch, g_fn_cam_yaw, g_fn_cam_roll, g_fn_fov,
        g_fn_aspect_axis,
        width, height, &x, &y);
    if (!visible) return NO;
    *out_x = (float)x;
    *out_y = (float)y;
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
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _dl = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        _dl.preferredFramesPerSecond = 60;
        [_dl addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}
- (void)dealloc { [_dl invalidate]; }
- (void)tick:(CADisplayLink *)dl { [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)r {
    // Sample camera and actors at draw time, not at CADisplayLink notification
    // time. This minimizes the interval in which Fortnite can advance its view.
    fn_tick();
    if (!g_fn_dots_enabled || !g_fn_cam_loc.valid) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (W<=0||H<=0) return;
    int n = g_fn_dot_count;
    EmberFnDot snap[EMBER_FN_MAX_PLAYERS];
    memcpy(snap, g_fn_dots, n * sizeof(EmberFnDot));
    EmberFnVec3 cam = g_fn_cam_loc;

    for (int i = 0; i < n; i++) {
        if (!snap[i].feet.valid || snap[i].is_local) continue;
        double ddx = snap[i].feet.x-cam.x, ddy = snap[i].feet.y-cam.y, ddz = snap[i].feet.z-cam.z;
        double dist = sqrt(ddx*ddx+ddy*ddy+ddz*ddz);
        if (dist > g_fn_max_distance) continue;

        float bx=0, by=0, hx=0, hy=0;
        if (!fn_project(snap[i].feet, (float)W, (float)H, &bx, &by)) continue;
        if (!fn_project(snap[i].head, (float)W, (float)H, &hx, &hy)) continue;
        if (bx < -50 || bx > W+50 || by < -50 || by > H+50) continue;

        CGFloat box_h = (CGFloat)fabs(by - hy);
        if (box_h < 8.f) box_h = 8.f;
        CGFloat box_w = box_h * 0.45f;
        CGFloat left = bx - box_w * 0.5f;
        CGFloat top = MIN(hy, by);
        CGFloat bottom = MAX(hy, by);
        box_h = bottom - top;

        UIColor *col = [UIColor colorWithRed:1 green:0.18 blue:0.18 alpha:0.95];
        CGContextSetStrokeColorWithColor(ctx, col.CGColor);
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:1 green:0.18 blue:0.18 alpha:0.12].CGColor);
        CGContextSetLineWidth(ctx, 1.5);

        if (g_fn_box_enabled) {
            CGRect box = CGRectMake(left, top, box_w, box_h);
            CGContextFillRect(ctx, box);
            CGContextStrokeRect(ctx, box);
        }

        if (g_fn_snapline_enabled) {
            CGContextMoveToPoint(ctx, W * 0.5, H * 0.5);
            CGContextAddLineToPoint(ctx, bx, by);
            CGContextStrokePath(ctx);
        }

        // Feet marker (Windows LocalOrigin / HumanBase)
        CGFloat rad = EMBER_FN_DOT_RADIUS_PTS;
        CGContextSetFillColorWithColor(ctx, col.CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(bx-rad, by-rad, rad*2, rad*2));
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.75].CGColor);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(bx-rad, by-rad, rad*2, rad*2));

        if (g_fn_show_labels) {
            NSString *lbl = [NSString stringWithFormat:@"%.0fm", dist/100.0];
            NSDictionary *a = @{
                NSFontAttributeName: [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold],
                NSForegroundColorAttributeName: UIColor.whiteColor
            };
            CGSize ts = [lbl sizeWithAttributes:a];
            [lbl drawAtPoint:CGPointMake(bx - ts.width/2, by + rad + 2) withAttributes:a];
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
@property (nonatomic, assign) CGSize              installedWindowSize;
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
    if (!g_fn_binary_verified) return g_fn_status ?: @"SEARCHING…";
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
        CGFloat bx = MAX(55.0, win.bounds.size.width - 60.0);
        CGFloat by = MAX(28.0, win.bounds.size.height * 0.4);
        btn.center = CGPointMake(bx, by);
        btn.backgroundColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.1 alpha:0.85];
        btn.layer.cornerRadius = 11;
        btn.layer.borderWidth = 1;
        btn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
        [btn setTitle:@"🔥 ESP" forState:UIControlStateNormal];
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
    // Fortnite can replace/resize its UIWindow during startup and rotation. A
    // button created against a zero-sized or portrait window otherwise remains
    // off-screen even though the tweak and timer are alive.
    CGSize size = win.bounds.size;
    BOOL sizeChanged = !CGSizeEqualToSize(size, self.installedWindowSize);
    CGRect safe = CGRectInset(win.bounds, 8.0, 8.0);
    if (sizeChanged || !CGRectContainsPoint(safe, self.button.center)) {
        self.button.center = CGPointMake(MAX(55.0, size.width - 60.0),
                                         MAX(28.0, size.height * 0.4));
        self.installedWindowSize = size;
    }
    self.button.hidden = NO;
    self.button.alpha = 1.0;
    self.button.enabled = YES;
    [win bringSubviewToFront:self.button];
    if (self.panel) [win bringSubviewToFront:self.panel];
    [self updateButton];
}

- (void)updateButton {
    NSString *title = g_fn_dots_enabled ? @"🔥 ON" : @"🔥 ESP";
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
    [win bringSubviewToFront:self.button];
    [win bringSubviewToFront:panel];
}

- (void)buildPanel:(EmberMenuPanel *)panel {
    [panel setStatus:[self statusString]];
    __weak EmberMenuPanel *wpanel = panel;
    __weak typeof(self) wself = self;
    [panel setTabs:@[@"ESP", @"Info"] activeTab:0 handler:^(NSInteger idx) {
        if (wpanel) { [wpanel clearRows]; [wself fillTab:idx panel:wpanel]; }
    }];
    [self fillTab:0 panel:panel];
}

- (void)fillTab:(NSInteger)tab panel:(EmberMenuPanel *)panel {
    if (tab == 0) {
        BOOL ready = g_fn_binary_verified;
        [panel addSection:@"ESP"];
        [panel addToggle:@"Enable ESP"
                  detail:(ready ? @"Read-only overlay (Windows-style W2S)" : @"Waiting for Fortnite binary…")
                 enabled:g_fn_dots_enabled
                 handler:^(BOOL on) {
            if (!g_fn_binary_verified) { [panel setStatus:@"Binary not verified yet"]; return; }
            g_fn_dots_enabled = on;
            if (self.dotView) self.dotView.hidden = !on;
            [self updateButton];
            EmberFnLog(@"ESP toggled %@", on?@"ON":@"OFF");
        }];
        [panel addToggle:@"Box"
                  detail:@"Feet→head box"
                 enabled:g_fn_box_enabled
                 handler:^(BOOL on) { g_fn_box_enabled = on; }];
        [panel addToggle:@"Snapline"
                  detail:@"Line from screen centre to feet"
                 enabled:g_fn_snapline_enabled
                 handler:^(BOOL on) { g_fn_snapline_enabled = on; }];
        [panel addToggle:@"Distance labels"
                  detail:@"Show metres below feet"
                 enabled:g_fn_show_labels
                 handler:^(BOOL on) { g_fn_show_labels = on; }];
        [panel addSection:@"Range"];
        [panel addSlider:@"Max distance"
                   value:(float)(g_fn_max_distance/100.0)
                     min:10.0f max:1000.0f
                  format:@"%.0f m"
                 handler:^(float v) {
            g_fn_max_distance = v * 100.0;
        }];
    } else {
        // ── Info tab ──
        BOOL ready = g_fn_binary_verified;
        [panel addSection:@"Build"];
        [panel addAction:(ready ? @"✓ Fortnite 42.10 verified" : (g_fn_status ?: @"⏳ Searching…"))
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
        [panel addAction:[NSString stringWithFormat:@"Render FOV %.2f°", g_fn_fov]
                  detail:[NSString stringWithFormat:@"PC+0x364 %.5f | POV %.2f° | axis %u", g_fn_fov_scalar, g_fn_pov_fov, g_fn_aspect_axis]
                 handler:^{}];
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
        EmberFnSuppressStoreKitPrompts();
        [ws install];
        [ws updateButton];
    }];
}
@end

// ── Fortnite-only StoreKit prompt suppression ───────────────────────────────
// StoreKit receipt refresh / purchase restoration can show the system Apple
// Account password dialog in a sideloaded container. Fortnite's Epic device
// authentication and EpicPurchasingService are separate and remain untouched.
static void EmberFnSuppressStoreKitPrompts(void) {
    if (g_fn_storekit_suppression_mask == 0x7) return;
    uint8_t before = g_fn_storekit_suppression_mask;

    Class receiptRequest = NSClassFromString(@"SKReceiptRefreshRequest");
    SEL start = @selector(start);
    Method startMethod = receiptRequest ? class_getInstanceMethod(receiptRequest, start) : NULL;
    if (!(g_fn_storekit_suppression_mask & 0x1) && startMethod) {
        IMP replacement = imp_implementationWithBlock(^(id request) {
            if ([request respondsToSelector:@selector(cancel)]) [request cancel];
            EmberFnLog(@"suppressed StoreKit receipt refresh (prevents Apple Account prompt)");
        });
        class_replaceMethod(receiptRequest, start, replacement, method_getTypeEncoding(startMethod));
        g_fn_storekit_suppression_mask |= 0x1;
    }

    Class paymentQueue = NSClassFromString(@"SKPaymentQueue");
    NSArray<NSString *> *restoreNames = @[@"restoreCompletedTransactions",
                                          @"restoreCompletedTransactionsWithApplicationUsername:"];
    for (NSUInteger index = 0; index < restoreNames.count; index++) {
        uint8_t bit = (uint8_t)(0x2 << index);
        if (g_fn_storekit_suppression_mask & bit) continue;
        NSString *name = restoreNames[index];
        SEL selector = NSSelectorFromString(name);
        Method method = paymentQueue ? class_getInstanceMethod(paymentQueue, selector) : NULL;
        if (!method) continue;
        IMP replacement;
        if ([name hasSuffix:@":"]) {
            replacement = imp_implementationWithBlock(^(id queue, id username) {
                (void)queue; (void)username;
                EmberFnLog(@"suppressed StoreKit transaction restore");
            });
        } else {
            replacement = imp_implementationWithBlock(^(id queue) {
                (void)queue;
                EmberFnLog(@"suppressed StoreKit transaction restore");
            });
        }
        class_replaceMethod(paymentQueue, selector, replacement, method_getTypeEncoding(method));
        g_fn_storekit_suppression_mask |= bit;
    }
    if (g_fn_storekit_suppression_mask != before || before == 0) {
        EmberFnLog(@"StoreKit prompt suppression mask 0x%x%@",
                   g_fn_storekit_suppression_mask,
                   g_fn_storekit_suppression_mask == 0x7 ? @" ready" : @" (retrying)");
    }
}

// ── Constructor ────────────────────────────────────────────────────────────────
__attribute__((constructor))
static void EmberFortniteInit(void) {
    EmberFnLog(@"constructor — polling for %s", EMBER_FN_GUEST_BINARY);
    // Start the UI immediately (shows "SEARCHING…")
    dispatch_async(dispatch_get_main_queue(), ^{
        EmberFnSuppressStoreKitPrompts();
        [[EmberFnController shared] start];
    });
    // Binary polling on background thread
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        BOOL loggedImages = NO;
        for (int i = 0; i < 240; i++) {   // up to 2 minutes
            [NSThread sleepForTimeInterval:0.5];
            if (!loggedImages && i == 2) {
                EmberFnLogImageInventory();
                loggedImages = YES;
            }
            uint32_t idx = UINT32_MAX;
            const struct mach_header_64 *mh = EmberFnFindBinary(&idx);
            if (!mh) {
                g_fn_status = @"NO FORTNITE IMAGE YET";
                if (i % 20 == 0) EmberFnLog(@"poll %d: binary not found yet", i);
                continue;
            }
            intptr_t slide = (idx != UINT32_MAX)
                ? _dyld_get_image_vmaddr_slide(idx)
                : ((intptr_t)mh - (intptr_t)0x100000000);
            EmberFnLog(@"candidate image %u at %p slide=0x%lx (attempt %d)",
                       idx, mh, (long)slide, i);
            if (slide < 0) {
                g_fn_status = @"NEGATIVE SLIDE";
                continue;
            }
            if (!EmberFnVerifyBuild(mh, idx)) continue;
            g_fn_slide = (uintptr_t)slide;
            g_fn_binary_verified = YES;
            g_fn_status = @"VERIFIED 42.10";
            EmberFnLog(@"ready — dots default OFF, tap 🔥 to open menu");
            return;
        }
        EmberFnLog(@"gave up after 120s — binary not found");
        g_fn_status = @"GAVE UP — SEE LOG";
    });
}
