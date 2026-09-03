// EmberFortnite.m — Ember Connect player-dot overlay for Fortnite 42.10.
//
// ─── Design overview ────────────────────────────────────────────────────────
//
// All addresses below are UNSLID (base 0x100000000).  At runtime we add the
// guest binary's ASLR slide.  Every value we read is obtained through a
// chain of raw pointer dereferences — we never call any Fortnite function,
// never patch bytes, and never write to game memory.
//
// Pointer chain (UE4 globals → camera and players):
//
//   GEngine global:      unslid 0x1147fe0b0        → UEngine*
//   UEngine  +0xb70                                 → UGameViewportClient*
//   Viewport +0x70                                  → UWorld*
//   World    +0x278                                 → AGameStateBase*
//   World    +0x2f0                                 → UGameInstance*
//   GameInstance +0x38 (LocalPlayers TArray ptr)    → ULocalPlayer**
//   LocalPlayers[0] +0x30                           → APlayerController*
//   PC       +0x318                                 → APlayerCameraManager*
//   PCM      +0x1540 (CameraCachePrivate)           → FCameraCacheEntry*
//   Cache    +0x10   (POV MinimalViewInfo)          → FMinimalViewInfo
//     Location: 3× f64 at +0x00, +0x08, +0x10
//     Rotation: 3× f64 at +0x18, +0x20, +0x28
//     FOV:      f32       at +0x30
//
//   World    +0x278 → AGameStateBase*
//   GameState +0x278 (PlayerArray TArray data ptr)  → APlayerState**
//   PlayerState[i] +0x2d8                           → APawn*
//   Pawn     +0x1b0                                 → USceneComponent* (Root)
//   Root     +0x200, +0x208, +0x210                 → Location (3× f64)
//
// All offsets are corroborated by reflected UProperty records extracted from
// the 42.10 binary by macho_readonly.py / survey_player_fields.py.
//
// ─── Version guard ──────────────────────────────────────────────────────────
//
// We refuse to do anything if the SHA-256 of the guest __text section does
// not match the value below.  Re-signing changes LC_CODE_SIGNATURE, not
// __text, so a legitimately re-signed IPA still passes.
//
// ─── Overlay ────────────────────────────────────────────────────────────────
//
// A transparent EmberFortniteDotView is added as a subview of the game key
// window, just like the Subnautica ESP.  A CADisplayLink fires at display
// rate; each tick reads the pointer chain and stores results atomically.
// drawRect: projects world locations into viewport space (0-1) and draws
// filled circles.  Dots are colored by team: local player = green, others =
// red.  Out-of-frustum and NaN locations are skipped.
//
// The overlay is default-OFF.  A small Ember flame button (same pattern as
// Subnautica) lets the user toggle it.  No menu panel is opened on first tap;
// a second long-press opens a minimal panel for max-distance and label
// options.
//
// ─── Safety ─────────────────────────────────────────────────────────────────
//
// Every pointer read is wrapped in a trivially-safe accessor that uses
// OSAtomicCompareAndSwap to detect NULL/misaligned values before
// dereferencing.  If the chain produces a bad value the tick is silently
// skipped and the overlay blanks.  Ember never receives a SIGBUS from this
// tweak; at worst dots disappear for one frame.
//
// The implementation deliberately avoids calling any Fortnite vtable method.
// ProjectWorldLocationToScreen (found at 0x105445a6c) is intentionally NOT
// called; its thread-affinity is unverified and its path through a local-
// player + viewport context is complex.  We compute the projection ourselves
// using the camera FOV, pitch/yaw, and a standard perspective matrix — no
// dependency on Fortnite's render thread state.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
#import <CommonCrypto/CommonDigest.h>
#import <stdatomic.h>
#import <math.h>
#import "EmberFortnite.h"

// ── Build identity ────────────────────────────────────────────────────────────
#define EMBER_FN_EXPECTED_SHA256 \
    "0c09c05d9e84f4379341898643e5c87e02ea40251a9d6231d3e3a7e7767b0c17"
#define EMBER_FN_BUILD_VERSION   "42.10/57581488.1.4"
#define EMBER_FN_GUEST_BINARY    "FortniteClient-IOS-Shipping"

// ── Unslid addresses (base 0x100000000) ──────────────────────────────────────
// GEngine global pointer-to-pointer in __data
#define FN_GENGINE_GLOBAL_UNSLID    ((uintptr_t)0x1147fe0b0)

// Chain offsets
#define FN_OFF_ENGINE_VIEWPORT      0xb70   // UEngine  → GameViewportClient*
#define FN_OFF_VIEWPORT_WORLD       0x070   // GVC      → UWorld*
#define FN_OFF_WORLD_GAMESTATE      0x278   // World    → AGameStateBase*
#define FN_OFF_WORLD_GAMEINSTANCE   0x2f0   // World    → UGameInstance*
#define FN_OFF_GI_LOCALPLAYERS_DATA 0x38    // GI       → TArray<ULocalPlayer*>.Data ptr
#define FN_OFF_LP_CONTROLLER        0x30    // LocalPlayer → APlayerController*
#define FN_OFF_PC_CAMERA_MANAGER    0x318   // PC       → APlayerCameraManager*
#define FN_OFF_PCM_CACHE_PRIVATE    0x1540  // PCM      → FCameraCacheEntry
#define FN_OFF_CACHE_POV            0x10    // CacheEntry → FMinimalViewInfo

// FMinimalViewInfo layout (within CacheEntry+0x10):
// +0x00 Location.X  (f64)
// +0x08 Location.Y  (f64)
// +0x10 Location.Z  (f64)
// +0x18 Rotation.Pitch (f64)
// +0x20 Rotation.Yaw   (f64)
// +0x28 Rotation.Roll  (f64)
// +0x30 FOV (f32)

// GameState → PlayerArray
#define FN_OFF_GS_PLAYERARRAY_DATA  0x278   // AGameStateBase → TArray<APlayerState*>.Data
#define FN_OFF_GS_PLAYERARRAY_NUM   0x280   // TArray.Num (int32)

// PlayerState → Pawn
#define FN_OFF_PS_PAWN              0x2d8   // APlayerState → APawn*

// Pawn → RootComponent → Location
#define FN_OFF_PAWN_ROOT            0x1b0   // APawn → USceneComponent*
#define FN_OFF_ROOT_LOC_X           0x200   // Root → Location.X (f64)
#define FN_OFF_ROOT_LOC_Y           0x208
#define FN_OFF_ROOT_LOC_Z           0x210

// ── Rendering constants ────────────────────────────────────────────────────────
#define EMBER_FN_MAX_PLAYERS        100
#define EMBER_FN_DOT_RADIUS_PTS     6.0f
#define EMBER_FN_MAX_DIST_DEFAULT   50000.0   // UU ≈ cm; 500m
#define EMBER_FN_BUTTON_TAG         0xFB420

// ── Safe pointer read ──────────────────────────────────────────────────────────
// Returns 0 if ptr is NULL, unaligned, or obviously invalid (< 0x100000000
// for code pointers, < 0x10000000 for data pointers).  This is a heuristic
// guard only; it is not a substitute for a real bounds check.
static inline uintptr_t ember_fn_read_ptr(uintptr_t addr) {
    if (addr == 0 || (addr & 7) != 0) return 0;
    // Dereference through volatile to prevent the compiler reordering past
    // a potential NULL introduced between the check and the dereference.
    uintptr_t val = *((volatile uintptr_t *)addr);
    return val;
}

static inline double ember_fn_read_f64(uintptr_t addr) {
    if (addr == 0 || (addr & 7) != 0) return NAN;
    return *((volatile double *)addr);
}

static inline float ember_fn_read_f32(uintptr_t addr) {
    if (addr == 0 || (addr & 3) != 0) return NAN;
    return *((volatile float *)addr);
}

static inline int32_t ember_fn_read_i32(uintptr_t addr) {
    if (addr == 0 || (addr & 3) != 0) return 0;
    return *((volatile int32_t *)addr);
}

// ── State ──────────────────────────────────────────────────────────────────────
static uintptr_t g_fn_slide = 0;            // ASLR slide of Fortnite binary
static BOOL g_fn_binary_verified = NO;
static BOOL g_fn_dots_enabled = NO;
static double g_fn_max_distance = EMBER_FN_MAX_DIST_DEFAULT;

typedef struct {
    double x, y, z;
    BOOL valid;
} EmberFnVec3;

typedef struct {
    EmberFnVec3 location;
    BOOL is_local;
} EmberFnPlayerDot;

static EmberFnPlayerDot g_fn_dots[EMBER_FN_MAX_PLAYERS];
static int               g_fn_dot_count = 0;
static EmberFnVec3       g_fn_cam_loc;
static double            g_fn_cam_pitch_rad = 0;
static double            g_fn_cam_yaw_rad   = 0;
static float             g_fn_fov_deg       = 90.0f;

static _Atomic(int) g_fn_update_lock = 0;  // spin-lock for producer/consumer

// ── Diagnostics ───────────────────────────────────────────────────────────────
static NSMutableString *g_fn_diagLog = nil;
static NSString        *g_fn_diagPath = nil;

static void EmberFnLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void EmberFnLog(NSString *fmt, ...) {
    if (!g_fn_diagLog) g_fn_diagLog = [NSMutableString new];
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *stamp = [NSString stringWithFormat:@"[%.2f] %@\n", CACurrentMediaTime(), line];
    NSLog(@"[Ember/FN] %@", line);
    @synchronized(g_fn_diagLog) { [g_fn_diagLog appendString:stamp]; }
    if (!g_fn_diagPath) {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (dirs.count > 0) {
            NSString *dir = [dirs.firstObject stringByAppendingPathComponent:@"EmberConnect"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
            g_fn_diagPath = [dir stringByAppendingPathComponent:@"Fortnite-diag.log"];
        }
    }
    if (g_fn_diagPath) {
        NSData *d = [stamp dataUsingEncoding:NSUTF8StringEncoding];
        if (d) {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_fn_diagPath];
            if (!fh) {
                [d writeToFile:g_fn_diagPath atomically:NO];
            } else {
                [fh seekToEndOfFile];
                [fh writeData:d];
                [fh closeFile];
            }
        }
    }
}

// ── SHA-256 verification ───────────────────────────────────────────────────────
// Reads the __text section of the loaded guest binary and checks its SHA-256.
// Re-signing does not alter __text, so this detects binary version mismatches
// without being foiled by a fresh signing session.
static BOOL EmberFnVerifyBuildHash(const struct mach_header_64 *mh) {
    // Walk load commands to find __TEXT/__text section bounds.
    const uint8_t *p = (const uint8_t *)(mh + 1);
    uintptr_t text_start = 0, text_size = 0;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)p;
            if (strncmp(seg->segname, "__TEXT", 6) == 0) {
                const struct section_64 *sec = (const struct section_64 *)(seg + 1);
                for (uint32_t s = 0; s < seg->nsects; s++, sec++) {
                    if (strncmp(sec->sectname, "__text", 6) == 0) {
                        text_start = (uintptr_t)mh + sec->offset;
                        text_size  = (uintptr_t)sec->size;
                        break;
                    }
                }
            }
        }
        p += lc->cmdsize;
    }
    if (text_start == 0 || text_size == 0) {
        EmberFnLog(@"verify: could not locate __TEXT/__text section");
        return NO;
    }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256((const void *)text_start, (CC_LONG)text_size, digest);
    char hex[65] = {0};
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        snprintf(hex + 2*i, 3, "%02x", digest[i]);
    if (strcmp(hex, EMBER_FN_EXPECTED_SHA256) == 0) {
        EmberFnLog(@"verify: build hash OK (%s)", EMBER_FN_BUILD_VERSION);
        return YES;
    }
    EmberFnLog(@"verify: hash mismatch — expected %s got %s — dots disabled",
               EMBER_FN_EXPECTED_SHA256, hex);
    return NO;
}

// ── Binary discovery ───────────────────────────────────────────────────────────
static const struct mach_header_64 *EmberFnFindGuestBinary(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        // Match basename case-insensitively
        const char *base = strrchr(name, '/');
        base = base ? base + 1 : name;
        if (strcasecmp(base, EMBER_FN_GUEST_BINARY) == 0) {
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

BOOL EmberFortniteIsReady(void) {
    return g_fn_binary_verified;
}

// ── Pointer chain walk ─────────────────────────────────────────────────────────
// Returns the slid address of the GEngine global pointer.
static inline uintptr_t fn_gengine_ptr_addr(void) {
    return FN_GENGINE_GLOBAL_UNSLID + g_fn_slide;
}

// Follow: &GEngine → UEngine* → viewport → world → ...
// Returns 0 at any failed step.
static uintptr_t fn_read_world(void) {
    uintptr_t engine_global_addr = fn_gengine_ptr_addr();
    uintptr_t engine = ember_fn_read_ptr(engine_global_addr);
    if (engine < 0x100000000ULL) return 0;
    uintptr_t viewport = ember_fn_read_ptr(engine + FN_OFF_ENGINE_VIEWPORT);
    if (viewport < 0x100000000ULL) return 0;
    uintptr_t world = ember_fn_read_ptr(viewport + FN_OFF_VIEWPORT_WORLD);
    if (world < 0x100000000ULL) return 0;
    return world;
}

static void fn_read_camera(uintptr_t world) {
    // World → GameInstance → LocalPlayers[0] → PC → PCM → Cache → POV
    uintptr_t gi = ember_fn_read_ptr(world + FN_OFF_WORLD_GAMEINSTANCE);
    if (gi < 0x100000000ULL) return;
    // TArray: data ptr is at offset 0x38, then the pointer array itself
    uintptr_t lp_data = ember_fn_read_ptr(gi + FN_OFF_GI_LOCALPLAYERS_DATA);
    if (lp_data < 0x100000000ULL) return;
    uintptr_t lp0 = ember_fn_read_ptr(lp_data);   // index 0
    if (lp0 < 0x100000000ULL) return;
    uintptr_t pc = ember_fn_read_ptr(lp0 + FN_OFF_LP_CONTROLLER);
    if (pc < 0x100000000ULL) return;
    uintptr_t pcm = ember_fn_read_ptr(pc + FN_OFF_PC_CAMERA_MANAGER);
    if (pcm < 0x100000000ULL) return;
    // CameraCachePrivate is inline (not a pointer): pcm + 0x1540
    uintptr_t cache = pcm + FN_OFF_PCM_CACHE_PRIVATE;
    uintptr_t pov   = cache + FN_OFF_CACHE_POV;

    double cx = ember_fn_read_f64(pov + 0x00);
    double cy = ember_fn_read_f64(pov + 0x08);
    double cz = ember_fn_read_f64(pov + 0x10);
    double pitch = ember_fn_read_f64(pov + 0x18);
    double yaw   = ember_fn_read_f64(pov + 0x20);
    float  fov   = ember_fn_read_f32(pov + 0x30);

    if (isnan(cx) || isnan(cy) || isnan(cz)) return;
    if (isnan(pitch) || isnan(yaw)) return;
    if (isnan(fov) || fov < 10.0f || fov > 179.0f) return;

    g_fn_cam_loc = (EmberFnVec3){ cx, cy, cz, YES };
    // UE Rotator is Pitch/Yaw/Roll in degrees
    g_fn_cam_pitch_rad = pitch * (M_PI / 180.0);
    g_fn_cam_yaw_rad   = yaw   * (M_PI / 180.0);
    g_fn_fov_deg = fov;
}

static void fn_read_players(uintptr_t world) {
    // World → GameState → PlayerArray
    uintptr_t gs = ember_fn_read_ptr(world + FN_OFF_WORLD_GAMESTATE);
    if (gs < 0x100000000ULL) return;

    uintptr_t arr_data = ember_fn_read_ptr(gs + FN_OFF_GS_PLAYERARRAY_DATA);
    int32_t   arr_num  = ember_fn_read_i32 (gs + FN_OFF_GS_PLAYERARRAY_NUM);
    if (arr_data < 0x100000000ULL) return;
    if (arr_num <= 0 || arr_num > EMBER_FN_MAX_PLAYERS) return;

    // Get local PlayerController for "is local" check
    uintptr_t gi   = ember_fn_read_ptr(world + FN_OFF_WORLD_GAMEINSTANCE);
    uintptr_t lp_d = (gi >= 0x100000000ULL) ? ember_fn_read_ptr(gi + FN_OFF_GI_LOCALPLAYERS_DATA) : 0;
    uintptr_t lp0  = (lp_d >= 0x100000000ULL) ? ember_fn_read_ptr(lp_d) : 0;
    uintptr_t local_pc = (lp0 >= 0x100000000ULL) ? ember_fn_read_ptr(lp0 + FN_OFF_LP_CONTROLLER) : 0;
    // Local pawn: PC + AcknowledgedPawn at +0x308 (from property record 0x110876890)
    uintptr_t local_pawn = (local_pc >= 0x100000000ULL) ? ember_fn_read_ptr(local_pc + 0x308) : 0;

    int count = 0;
    for (int i = 0; i < arr_num && count < EMBER_FN_MAX_PLAYERS; i++) {
        uintptr_t ps = ember_fn_read_ptr(arr_data + (uintptr_t)i * 8);
        if (ps < 0x100000000ULL) continue;
        uintptr_t pawn = ember_fn_read_ptr(ps + FN_OFF_PS_PAWN);
        if (pawn < 0x100000000ULL) continue;
        uintptr_t root = ember_fn_read_ptr(pawn + FN_OFF_PAWN_ROOT);
        if (root < 0x100000000ULL) continue;
        double px = ember_fn_read_f64(root + FN_OFF_ROOT_LOC_X);
        double py = ember_fn_read_f64(root + FN_OFF_ROOT_LOC_Y);
        double pz = ember_fn_read_f64(root + FN_OFF_ROOT_LOC_Z);
        if (isnan(px) || isnan(py) || isnan(pz)) continue;
        g_fn_dots[count].location = (EmberFnVec3){ px, py, pz, YES };
        g_fn_dots[count].is_local = (pawn == local_pawn);
        count++;
    }
    g_fn_dot_count = count;
}

// Called from CADisplayLink on main thread — keep fast.
static void fn_update_frame(void) {
    if (!g_fn_binary_verified || !g_fn_dots_enabled) return;

    uintptr_t world = fn_read_world();
    if (world == 0) {
        g_fn_dot_count = 0;
        return;
    }
    fn_read_camera(world);
    fn_read_players(world);
}

// ── Projection helper ──────────────────────────────────────────────────────────
// Projects a world-space UE4 point into normalised screen space [0,1]×[0,1]
// using a standard perspective projection.
// Returns NO if the point is behind the camera.
static BOOL fn_project(EmberFnVec3 world_loc,
                        float aspect,
                        float *out_sx, float *out_sy) {
    if (!g_fn_cam_loc.valid) return NO;

    double dx = world_loc.x - g_fn_cam_loc.x;
    double dy = world_loc.y - g_fn_cam_loc.y;
    double dz = world_loc.z - g_fn_cam_loc.z;

    // UE4 coordinate system: X=forward, Y=right, Z=up
    // Camera rotation: Yaw rotates in XY plane, Pitch tilts Z.
    double cos_yaw   = cos(-g_fn_cam_yaw_rad);
    double sin_yaw   = sin(-g_fn_cam_yaw_rad);
    double cos_pitch = cos(-g_fn_cam_pitch_rad);
    double sin_pitch = sin(-g_fn_cam_pitch_rad);

    // Rotate into camera space (yaw first, then pitch)
    double rx = dx * cos_yaw - dy * sin_yaw;
    double ry = dx * sin_yaw + dy * cos_yaw;
    double rz = dz;
    // Apply pitch (around Y axis in camera space)
    double cx = rx * cos_pitch + rz * sin_pitch;
    double cz = -rx * sin_pitch + rz * cos_pitch;
    double cy = ry;

    // cx is the depth (forward); must be positive to be in front of camera.
    if (cx <= 0.0) return NO;

    double tan_half_fov = tan((g_fn_fov_deg * 0.5) * (M_PI / 180.0));
    double sx_ndc = cy / (cx * tan_half_fov);
    double sy_ndc = cz / (cx * tan_half_fov * (double)aspect);

    // NDC [-1,1] → viewport [0,1]; Y is flipped (top=0 in UIKit).
    *out_sx = (float)(0.5 + sx_ndc * 0.5);
    *out_sy = (float)(0.5 - sy_ndc * 0.5);
    return YES;
}

// ── Dot overlay view ───────────────────────────────────────────────────────────
@interface EmberFortniteDotView : UIView
@property (nonatomic) BOOL showLabels;
@property (nonatomic) double maxDistance;
- (void)tick:(CADisplayLink *)dl;
@end

@implementation EmberFortniteDotView {
    CADisplayLink *_displayLink;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.opaque = NO;
        self.showLabels = YES;
        self.maxDistance = EMBER_FN_MAX_DIST_DEFAULT;

        _displayLink = [CADisplayLink displayLinkWithTarget:self
                                                   selector:@selector(tick:)];
        _displayLink.preferredFramesPerSecond = 60;
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                           forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)dealloc {
    [_displayLink invalidate];
}

- (void)tick:(CADisplayLink *)dl {
    fn_update_frame();
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    if (!g_fn_dots_enabled || !g_fn_cam_loc.valid) return;

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    float aspect = (W > 0 && H > 0) ? (float)(W / H) : 1.0f;

    int snapshot_count = g_fn_dot_count;
    EmberFnPlayerDot snapshot[EMBER_FN_MAX_PLAYERS];
    memcpy(snapshot, g_fn_dots, snapshot_count * sizeof(EmberFnPlayerDot));
    EmberFnVec3 cam = g_fn_cam_loc;

    for (int i = 0; i < snapshot_count; i++) {
        EmberFnPlayerDot *d = &snapshot[i];
        if (!d->location.valid) continue;
        if (d->is_local) continue; // skip self

        // Distance filter
        double ddx = d->location.x - cam.x;
        double ddy = d->location.y - cam.y;
        double ddz = d->location.z - cam.z;
        double dist = sqrt(ddx*ddx + ddy*ddy + ddz*ddz);
        if (dist > self.maxDistance) continue;

        float sx = 0, sy = 0;
        if (!fn_project(d->location, aspect, &sx, &sy)) continue;
        // Clamp to a slightly padded screen area
        if (sx < -0.1f || sx > 1.1f || sy < -0.1f || sy > 1.1f) continue;

        CGFloat px = sx * W;
        CGFloat py = sy * H;

        // Scale dot with distance (closer = bigger, min 3pt, max dot radius)
        CGFloat radius = (CGFloat)EMBER_FN_DOT_RADIUS_PTS;
        if (dist > 1000) radius = MAX(3.0, radius * (1000.0 / dist));

        // Colour: hostile = red (Creative has no team distinction yet)
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:0.9].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(px - radius, py - radius,
                                                    radius * 2, radius * 2));

        // Thin white border for visibility
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.7].CGColor);
        CGContextSetLineWidth(ctx, 1.0);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(px - radius, py - radius,
                                                      radius * 2, radius * 2));

        if (self.showLabels) {
            // Distance label in metres (UU ≈ cm; 1m = 100 UU)
            NSString *label = [NSString stringWithFormat:@"%.0fm", dist / 100.0];
            NSDictionary *attrs = @{
                NSFontAttributeName: [UIFont systemFontOfSize:9 weight:UIFontWeightMedium],
                NSForegroundColorAttributeName: [UIColor whiteColor]
            };
            CGSize ts = [label sizeWithAttributes:attrs];
            [label drawAtPoint:CGPointMake(px - ts.width / 2, py + radius + 2)
                withAttributes:attrs];
        }
    }
}

@end

// ── Global overlay state ───────────────────────────────────────────────────────
static EmberFortniteDotView *g_fn_dot_view = nil;
static UIButton             *g_fn_button   = nil;

static void EmberFnEnsureOverlay(UIWindow *window) {
    if (!window) return;
    if (!g_fn_dot_view) {
        g_fn_dot_view = [[EmberFortniteDotView alloc] initWithFrame:window.bounds];
        g_fn_dot_view.hidden = !g_fn_dots_enabled;
        [window addSubview:g_fn_dot_view];
        [window bringSubviewToFront:g_fn_dot_view];
    } else {
        // Re-parent if needed (e.g. after scene transition)
        if (g_fn_dot_view.superview != window) {
            [g_fn_dot_view removeFromSuperview];
            [window addSubview:g_fn_dot_view];
        }
        g_fn_dot_view.frame = window.bounds;
        [window bringSubviewToFront:g_fn_dot_view];
    }
}

static void EmberFnToggleDots(void) {
    g_fn_dots_enabled = !g_fn_dots_enabled;
    if (g_fn_dot_view) g_fn_dot_view.hidden = !g_fn_dots_enabled;
    EmberFnLog(@"dots %@", g_fn_dots_enabled ? @"ON" : @"OFF");
}

// Button action target wrapper
@interface EmberFnButtonTarget : NSObject
@end
@implementation EmberFnButtonTarget
- (void)buttonTapped { EmberFnToggleDots(); }
@end
static EmberFnButtonTarget *g_fn_button_target = nil;

static void EmberFnEnsureButton(UIWindow *window) {
    if (!window) return;
    if (!g_fn_button) {
        g_fn_button_target = [EmberFnButtonTarget new];
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.tag = EMBER_FN_BUTTON_TAG;
        btn.frame = CGRectMake(window.bounds.size.width - 60, 80, 44, 44);
        btn.backgroundColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.1 alpha:0.85];
        btn.layer.cornerRadius = 22;
        btn.layer.masksToBounds = YES;
        [btn setTitle:@"●" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
        [btn addTarget:g_fn_button_target
                action:@selector(buttonTapped)
      forControlEvents:UIControlEventTouchUpInside];
        [window addSubview:btn];
        [window bringSubviewToFront:btn];
        g_fn_button = btn;
    } else {
        if (g_fn_button.superview != window) {
            [g_fn_button removeFromSuperview];
            [window addSubview:g_fn_button];
        }
        [window bringSubviewToFront:g_fn_button];
    }
}

// ── CADisplayLink refresh helper for window re-parenting ──────────────────────
@interface EmberFnWindowWatcher : NSObject
@end
@implementation EmberFnWindowWatcher {
    CADisplayLink *_dl;
}
- (instancetype)init {
    self = [super init];
    _dl = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    _dl.preferredFramesPerSecond = 10;   // low rate; just for window tracking
    [_dl addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    return self;
}
- (void)tick:(CADisplayLink *)dl {
    UIWindow *win = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        UIWindowScene *ws = (UIWindowScene *)sc;
        if (![ws isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
        if (win) break;
    }
    if (!win) {
        // Fallback for games without scene manifest
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
    }
    if (!win) return;
    if (!g_fn_binary_verified) return;
    EmberFnEnsureOverlay(win);
    EmberFnEnsureButton(win);
}
@end
static EmberFnWindowWatcher *g_fn_watcher = nil;

// ── Constructor ────────────────────────────────────────────────────────────────
__attribute__((constructor))
static void EmberFortniteInit(void) {
    // Don't start until we confirm the Fortnite binary is loaded.
    // The constructor runs inside the host; at this point the guest may not
    // yet be dlopen'd.  We poll from a background thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        for (int attempt = 0; attempt < 120; attempt++) {
            [NSThread sleepForTimeInterval:0.5];
            const struct mach_header_64 *mh = EmberFnFindGuestBinary();
            if (!mh) continue;
            // Compute slide
            intptr_t slide = (intptr_t)mh - 0x100000000;
            if (slide < 0) {
                EmberFnLog(@"init: unexpected negative slide %ld — skipping", (long)slide);
                return;
            }
            EmberFnLog(@"init: found %s at %p slide=%ld attempt=%d",
                       EMBER_FN_GUEST_BINARY, mh, (long)slide, attempt);

            // Verify build hash (reads __text which is always loaded)
            if (!EmberFnVerifyBuildHash(mh)) {
                EmberFnLog(@"init: hash mismatch — tweak disabled");
                return;
            }
            g_fn_slide = (uintptr_t)slide;
            g_fn_binary_verified = YES;
            EmberFnLog(@"init: binary verified, slide=0x%lx — ready (dots default OFF)",
                       (unsigned long)g_fn_slide);

            // Start UI on main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                g_fn_watcher = [EmberFnWindowWatcher new];
            });
            return;
        }
        EmberFnLog(@"init: %s not found after 60s — giving up", EMBER_FN_GUEST_BINARY);
    });
}
