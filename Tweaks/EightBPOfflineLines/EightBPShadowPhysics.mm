#import "EightBPShadowPhysics.h"

#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

#if !defined(__arm64__)
#error EightBPShadowPhysics requires arm64
#endif

// The query facade mirrors the private ABI used by 56.29.2. Keep every entry
// behind the version/opcode/layout gates below.
#ifndef EIGHTBP_SHADOW_ENABLE_VALIDATED_QUERY_ABI
#define EIGHTBP_SHADOW_ENABLE_VALIDATED_QUERY_ABI 1
#endif

struct NativePoint {
    double x;
    double y;
};

struct NativeNumber {
    double value;
    NativeNumber() : value(0.0) {}
    explicit NativeNumber(double input) : value(input) {}
    NativeNumber(const NativeNumber &other) : value(other.value) {}
    ~NativeNumber() {}
};

struct NativeRect {
    NativePoint origin;
    NativePoint size;
    // MCRect contains non-trivial MCNumber members and is returned indirectly
    // through x8. Without these methods clang treats this as a four-double HFA
    // and returns it in d0-d3, leaving the native caller's x8 buffer unwritten.
    NativeRect() : origin{}, size{} {}
    NativeRect(const NativeRect &other) : origin(other.origin), size(other.size) {}
    ~NativeRect() {}
};

struct NativeVectorHeader {
    const NativePoint *begin;
    const NativePoint *end;
    const NativePoint *capacity;
};

using EightBPShadowPointVector = std::vector<NativePoint>;

#if EIGHTBP_SHADOW_ENABLE_VALIDATED_QUERY_ABI
@interface ECEightBPShadowTableProperties : NSObject {
@public
    EightBPShadowPointVector _pockets;
    double _pocketRadius;
}
- (const EightBPShadowPointVector *)getPockets;
- (NativeNumber)getPocketRadius;
@end

@implementation ECEightBPShadowTableProperties
- (const EightBPShadowPointVector *)getPockets { return &_pockets; }
- (NativeNumber)getPocketRadius { return NativeNumber(_pocketRadius); }
@end

@interface ECEightBPShadowQueryFacade : NSObject {
@public
    NSArray *_shadowBalls;
    EightBPShadowPointVector _tableShape;
    NativeRect _bounds;
    BOOL _fast;
    ECEightBPShadowTableProperties *_properties;
    BOOL _unexpectedRunnerCall;
}
- (NSArray *)balls;
- (BOOL)isFastComputationEnabled;
- (NativeRect)tableBounds;
- (const EightBPShadowPointVector *)tableShape;
- (id)tableProperties;
- (void)addToBallRunner:(id)ball playSound:(BOOL)playSound;
@end

@implementation ECEightBPShadowQueryFacade
- (NSArray *)balls { return _shadowBalls; }
- (BOOL)isFastComputationEnabled { return _fast; }
- (NativeRect)tableBounds { return _bounds; }
- (const EightBPShadowPointVector *)tableShape { return &_tableShape; }
- (id)tableProperties { return _properties; }
- (void)addToBallRunner:(id)ball playSound:(BOOL)playSound {
    (void)ball;
    (void)playSound;
    _unexpectedRunnerCall = YES;
}
@end
#endif

namespace {

constexpr uintptr_t kFindCollision = 0x10000C9C8ULL;
constexpr uintptr_t kIntegrateFriction = 0x10000DB08ULL;
constexpr uintptr_t kBallInitializer = 0x10005B478ULL;
constexpr uintptr_t kBallMove = 0x10005B888ULL;
constexpr uintptr_t kResolveBallBall = 0x1002FB918ULL;
constexpr uintptr_t kResolveCushion = 0x1002FBAB4ULL;

constexpr uintptr_t kBallBallVTable = 0x103B69260ULL;
constexpr uintptr_t kBallLineVTable = 0x103B69288ULL;
constexpr uintptr_t kBallPocketVTable = 0x103B69318ULL;
constexpr uintptr_t kBallPointVTable = 0x103B69358ULL;

constexpr uintptr_t kBallBallVirtualResolver = 0x100064C34ULL;
constexpr uintptr_t kBallLineVirtualResolver = 0x100064F00ULL;
constexpr uintptr_t kBallPocketVirtualResolver = 0x100065178ULL;
constexpr uintptr_t kBallPointVirtualResolver = 0x1000652A4ULL;

constexpr double kLogicalFrameTime = 1.0 / 60.0;
constexpr double kRestSpeed = 1.0e-7;
constexpr double kEventEpsilon = 1.0e-9;
constexpr uint16_t kMaximumFrames = 3600;
constexpr uint16_t kMaximumEvents = 512;
constexpr uint16_t kMaximumZeroTimeEvents = 8;
constexpr auto kWallTimeLimit = std::chrono::milliseconds(60);

struct FrictionProperties {
    double values[7];
    __unsafe_unretained NSObject *table;
};

struct Collision;
using CollisionPtr = std::shared_ptr<Collision>;

struct NativeGate {
    uintptr_t address;
    std::array<uint32_t, 4> opcodes;
};

constexpr NativeGate kCodeGates[] = {
    {kFindCollision, {0xD10543FF, 0x6D0C33ED, 0x6D0D2BEB, 0x6D0E23E9}},
    {kIntegrateFriction, {0xD102C3FF, 0x6D0533ED, 0x6D062BEB, 0x6D0723E9}},
    {kBallInitializer, {0xD101C3FF, 0x6D0223E9, 0xA9035FF8, 0xA90457F6}},
    {kBallMove, {0xD0023048, 0xFD401901, 0x3DC00C00, 0x5E180402}},
    {kResolveBallBall, {0xD102C3FF, 0x6D062BEB, 0x6D0723E9, 0xA90857F6}},
    {kResolveCushion, {0xD102C3FF, 0x6D053BEF, 0x6D0633ED, 0x6D072BEB}},
    {kBallBallVirtualResolver, {0xD10203FF, 0x6D0423E9, 0xA90557F6, 0xA9064FF4}},
    {kBallLineVirtualResolver, {0xD101C3FF, 0xA90457F6, 0xA9054FF4, 0xA9067BFD}},
    {kBallPocketVirtualResolver, {0xD10143FF, 0xA90257F6, 0xA9034FF4, 0xA9047BFD}},
    {kBallPointVirtualResolver, {0xD10243FF, 0x6D0423E9, 0xA9055FF8, 0xA90657F6}},
};

std::mutex gStatusMutex;
std::array<char, EightBPShadowStatusCapacity> gLastStatus = {};
EightBPShadowLogCallback gLogCallback = nullptr;
void *gLogContext = nullptr;

static void SetStatus(char *destination, const char *message) {
    const char *safe = message ? message : "unknown shadow-physics status";
    EightBPShadowLogCallback callback = nullptr;
    void *context = nullptr;
    std::array<char, EightBPShadowStatusCapacity> callbackMessage = {};
    {
        std::lock_guard<std::mutex> lock(gStatusMutex);
        std::snprintf(gLastStatus.data(), gLastStatus.size(), "%s", safe);
        if (destination) {
            std::snprintf(destination, EightBPShadowStatusCapacity, "%s", safe);
        }
        callback = gLogCallback;
        context = gLogContext;
        callbackMessage = gLastStatus;
    }
    if (callback) callback(callbackMessage.data(), context);
}

static intptr_t GameImageSlide(void) {
    Class manager = NSClassFromString(@"GameManager");
    const char *owner = manager ? class_getImageName(manager) : nullptr;
    if (!owner) return INTPTR_MIN;
    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const char *candidate = _dyld_get_image_name(index);
        if (candidate && std::strcmp(candidate, owner) == 0) {
            return _dyld_get_image_vmaddr_slide(index);
        }
    }
    return INTPTR_MIN;
}

static bool ValidateImageUUID(void) {
    constexpr uint8_t expected[16] = {
        0x20, 0xAF, 0x42, 0xCE, 0xEF, 0xAA, 0x3D, 0xAC,
        0x95, 0x94, 0xD1, 0x96, 0x27, 0xDF, 0x43, 0x9C
    };
    Class manager = NSClassFromString(@"GameManager");
    const char *owner = manager ? class_getImageName(manager) : nullptr;
    if (!owner) return false;
    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const char *candidate = _dyld_get_image_name(index);
        if (!candidate || std::strcmp(candidate, owner) != 0) continue;
        const mach_header *header = _dyld_get_image_header(index);
        if (!header || header->magic != MH_MAGIC_64) return false;
        const auto *command = reinterpret_cast<const load_command *>(
            reinterpret_cast<const uint8_t *>(header) + sizeof(mach_header_64));
        for (uint32_t commandIndex = 0; commandIndex < header->ncmds; ++commandIndex) {
            if (!command || command->cmdsize < sizeof(load_command)) return false;
            if (command->cmd == LC_UUID && command->cmdsize >= sizeof(uuid_command)) {
                const auto *uuid = reinterpret_cast<const uuid_command *>(command);
                return std::memcmp(uuid->uuid, expected, sizeof(expected)) == 0;
            }
            command = reinterpret_cast<const load_command *>(
                reinterpret_cast<const uint8_t *>(command) + command->cmdsize);
        }
    }
    return false;
}

static void *SlidAddress(uintptr_t preferred, intptr_t slide) {
    return reinterpret_cast<void *>(preferred + static_cast<uintptr_t>(slide));
}

static bool ValidateCodeGates(intptr_t slide) {
    for (const NativeGate &gate : kCodeGates) {
        const auto *actual = static_cast<const uint32_t *>(SlidAddress(gate.address, slide));
        if (!actual || std::memcmp(actual, gate.opcodes.data(), sizeof(uint32_t) * 4) != 0) {
            return false;
        }
    }
    return true;
}

static bool ValidateVersion(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *shortVersion = info[@"CFBundleShortVersionString"];
    id buildNumber = info[@"CFBundleVersion"];
    return [shortVersion isEqualToString:@"56.29.2"] &&
           [[buildNumber description] isEqualToString:@"5324"];
}

static bool IvarMatches(Class cls, const char *name, ptrdiff_t offset, const char *typePrefix) {
    Ivar ivar = class_getInstanceVariable(cls, name);
    if (!ivar || ivar_getOffset(ivar) != offset) return false;
    const char *type = ivar_getTypeEncoding(ivar);
    return type && std::strncmp(type, typePrefix, std::strlen(typePrefix)) == 0;
}

static bool HasIvarAtOffset(Class cls, ptrdiff_t offset, char requiredType) {
    unsigned count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    bool found = false;
    for (unsigned index = 0; index < count; ++index) {
        const char *type = ivar_getTypeEncoding(ivars[index]);
        if (ivar_getOffset(ivars[index]) == offset && type && type[0] == requiredType) {
            found = true;
            break;
        }
    }
    free(ivars);
    return found;
}

static const char *SkipObjCTypeQualifiers(const char *type) {
    if (!type) return type;
    // ObjC encodings can prefix const/in/out/byref/etc. before the real type.
    // tableShape is encoded as r^v, so the first character is 'r', not '^'.
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        ++type;
    }
    return type;
}

static bool MethodReturns(Class cls, SEL selector, const char *allowedPrefixes) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return false;
    char returnType[64] = {};
    method_getReturnType(method, returnType, sizeof(returnType));
    const char *type = SkipObjCTypeQualifiers(returnType);
    return type && type[0] && std::strchr(allowedPrefixes, type[0]) != nullptr;
}

static bool NamedIvarUsable(Class cls, const char *name, const char *allowedTypes,
                            ptrdiff_t *offsetOut) {
    Ivar ivar = class_getInstanceVariable(cls, name);
    if (!ivar) return false;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || !type[0] || !std::strchr(allowedTypes, type[0])) return false;
    if (offsetOut) *offsetOut = ivar_getOffset(ivar);
    return true;
}

static bool ValidateBallLayout(Class ballClass, intptr_t slide, char *status) {
    if (!ballClass) {
        SetStatus(status, "Ball class missing");
        return false;
    }
    const size_t instanceSize = class_getInstanceSize(ballClass);
    if (instanceSize < 0xB0) {
        SetStatus(status, "Ball instance size gate failed");
        return false;
    }
    Method initializer = class_getInstanceMethod(
        ballClass, NSSelectorFromString(@"initWithNumber:radius:classification:initialPosition:initialVelocity:"));
    Method move = class_getInstanceMethod(ballClass, NSSelectorFromString(@"move:"));
    if (!initializer || !move) {
        SetStatus(status, "Ball initializer/move: selectors missing");
        return false;
    }
    ptrdiff_t visual = 0, physics = 0, classification = 0, state = 0, number = 0;
    if (!NamedIvarUsable(ballClass, "visualBall", "@", &visual) ||
        !NamedIvarUsable(ballClass, "classification", "iIqQ", &classification) ||
        !NamedIvarUsable(ballClass, "state", "iIqQ", &state) ||
        !NamedIvarUsable(ballClass, "number", "iIqQ", &number)) {
        SetStatus(status, "Ball named ivar gate failed");
        return false;
    }
    if (!HasIvarAtOffset(ballClass, 0x20, '{') &&
        !NamedIvarUsable(ballClass, "_physicsProperties", "{", &physics)) {
        SetStatus(status, "Ball physics block gate failed");
        return false;
    }
    (void)slide;
    static bool logged = false;
    if (!logged) {
        logged = true;
        char detail[EightBPShadowStatusCapacity];
        std::snprintf(detail, sizeof(detail),
                      "Ball layout ok size=%zu vis=%ld class=%ld state=%ld num=%ld",
                      instanceSize, (long)visual, (long)classification, (long)state,
                      (long)number);
        SetStatus(status, detail);
    }
    return true;
}

static bool ValidateVTables(intptr_t slide) {
    struct VTableGate { uintptr_t vtable; uintptr_t resolver; };
    constexpr VTableGate gates[] = {
        {kBallBallVTable, kBallBallVirtualResolver},
        {kBallLineVTable, kBallLineVirtualResolver},
        {kBallPocketVTable, kBallPocketVirtualResolver},
        {kBallPointVTable, kBallPointVirtualResolver},
    };
    for (const VTableGate &gate : gates) {
        const auto *addressPoint = static_cast<const uintptr_t *>(SlidAddress(gate.vtable, slide));
        if (!addressPoint) return false;
        // arm64e dyld fixups may sign the function pointer stored in the
        // vtable. Compare canonical address bits rather than the PAC payload.
        constexpr uintptr_t kCanonicalAddressMask = 0x0000FFFFFFFFFFFFULL;
        uintptr_t actual = addressPoint[2] & kCanonicalAddressMask;
        uintptr_t expected = reinterpret_cast<uintptr_t>(
            SlidAddress(gate.resolver, slide)) & kCanonicalAddressMask;
        if (actual != expected) return false;
    }
    return true;
}

static bool FinitePoint(NativePoint point) {
    return std::isfinite(point.x) && std::isfinite(point.y) &&
           std::fabs(point.x) <= 10000.0 && std::fabs(point.y) <= 10000.0;
}

static bool ValidVector(const NativeVectorHeader *header, size_t minimum, size_t maximum) {
    if (!header || !header->begin || !header->end || !header->capacity) return false;
    if (header->begin > header->end || header->end > header->capacity) return false;
    const ptrdiff_t count = header->end - header->begin;
    if (count < static_cast<ptrdiff_t>(minimum) ||
        count > static_cast<ptrdiff_t>(maximum)) return false;
    for (ptrdiff_t index = 0; index < count; ++index) {
        if (!FinitePoint(header->begin[index])) return false;
    }
    return true;
}

static uint32_t ReadUInt32(NSObject *object, ptrdiff_t offset) {
    uint32_t value = 0;
    std::memcpy(&value, reinterpret_cast<const uint8_t *>((__bridge const void *)object) + offset,
                sizeof(value));
    return value;
}

static int32_t ReadInt32(NSObject *object, ptrdiff_t offset) {
    int32_t value = 0;
    std::memcpy(&value, reinterpret_cast<const uint8_t *>((__bridge const void *)object) + offset,
                sizeof(value));
    return value;
}

static NativePoint ReadPoint(NSObject *object, ptrdiff_t offset) {
    NativePoint value = {};
    std::memcpy(&value, reinterpret_cast<const uint8_t *>((__bridge const void *)object) + offset,
                sizeof(value));
    return value;
}

static void WritePoint(NSObject *object, ptrdiff_t offset, NativePoint value) {
    std::memcpy(reinterpret_cast<uint8_t *>((__bridge void *)object) + offset, &value, sizeof(value));
}

static bool ValidateInputSurface(NSObject *table, NSObject *cueBall, const void *guide,
                                 const double friction[7], char *status, intptr_t *slideOut) {
    if (![NSThread isMainThread]) {
        SetStatus(status, "shadow physics requires the main thread");
        return false;
    }
    if (!table || !cueBall || !guide || !friction) {
        SetStatus(status, "shadow physics received a null input");
        return false;
    }
    if (!ValidateVersion() || !ValidateImageUUID()) {
        SetStatus(status, "unsupported game build (requires 56.29.2 build 5324)");
        return false;
    }
    intptr_t slide = GameImageSlide();
    if (slide == INTPTR_MIN || !ValidateCodeGates(slide)) {
        SetStatus(status, "56.29.2 native opcode gate failed");
        return false;
    }
    Class ballClass = NSClassFromString(@"Ball");
    if (![cueBall isKindOfClass:ballClass]) {
        SetStatus(status, "cached cue ball is not a Ball");
        return false;
    }
    if (!ValidateBallLayout(ballClass, slide, status)) return false;
    if (!ValidateVTables(slide)) {
        SetStatus(status, "56.29.2 collision vtable gate failed");
        return false;
    }
    for (size_t index = 0; index < 7; ++index) {
        if (!std::isfinite(friction[index]) || friction[index] < 0.0 ||
            friction[index] > 100000.0) {
            SetStatus(status, "invalid copied friction block");
            return false;
        }
    }
    if (friction[3] <= 0.0 || friction[4] <= 0.0 || friction[5] <= 0.0) {
        SetStatus(status, "friction reduction factors are not positive");
        return false;
    }

    const auto *guideBytes = static_cast<const uint8_t *>(guide);
    __unsafe_unretained NSObject *guideTable = nil;
    __unsafe_unretained NSObject *temporaryCue = nil;
    __unsafe_unretained NSObject *temporaryObject = nil;
    std::memcpy(&guideTable, guideBytes + 0x00, sizeof(guideTable));
    std::memcpy(&temporaryCue, guideBytes + 0x08, sizeof(temporaryCue));
    std::memcpy(&temporaryObject, guideBytes + 0x10, sizeof(temporaryObject));
    if (guideTable != table || ![temporaryCue isKindOfClass:ballClass] ||
        ![temporaryObject isKindOfClass:ballClass] ||
        ReadInt32(temporaryCue, 0xA0) != 9 || ReadInt32(temporaryObject, 0xA0) != 9) {
        SetStatus(status, "VisualGuide ownership/classification gate failed");
        return false;
    }
    __unsafe_unretained NSObject *temporaryVisual = nil;
    std::memcpy(&temporaryVisual,
                reinterpret_cast<const uint8_t *>((__bridge const void *)temporaryCue) + 0x18,
                sizeof(temporaryVisual));
    if (temporaryVisual) {
        SetStatus(status, "VisualGuide temporary Ball unexpectedly has a visualBall");
        return false;
    }

    SEL ballsSelector = NSSelectorFromString(@"balls");
    SEL shapeSelector = NSSelectorFromString(@"tableShape");
    SEL propertiesSelector = NSSelectorFromString(@"tableProperties");
    SEL boundsSelector = NSSelectorFromString(@"tableBounds");
    SEL fastSelector = NSSelectorFromString(@"isFastComputationEnabled");
    Class tableClass = NSClassFromString(@"Table");
    if (!tableClass || ![table isKindOfClass:tableClass]) {
        SetStatus(status, "Table class gate failed");
        return false;
    }
    if (![table respondsToSelector:ballsSelector] ||
        !MethodReturns([table class], ballsSelector, "@")) {
        SetStatus(status, "Table.balls selector gate failed");
        return false;
    }
    if (![table respondsToSelector:shapeSelector] ||
        !MethodReturns([table class], shapeSelector, "^")) {
        SetStatus(status, "Table.tableShape selector gate failed");
        return false;
    }
    if (![table respondsToSelector:propertiesSelector] ||
        !MethodReturns([table class], propertiesSelector, "@")) {
        SetStatus(status, "Table.tableProperties selector gate failed");
        return false;
    }
    if (![table respondsToSelector:boundsSelector] ||
        !MethodReturns([table class], boundsSelector, "{")) {
        SetStatus(status, "Table.tableBounds selector gate failed");
        return false;
    }
    // Fast-computation is optional; VisualGuide uses it when present.
    if ([table respondsToSelector:fastSelector] &&
        !MethodReturns([table class], fastSelector, "Bc")) {
        SetStatus(status, "Table.isFastComputationEnabled selector gate failed");
        return false;
    }
    NSArray *balls = ((id (*)(id, SEL))objc_msgSend)(table, ballsSelector);
    if (![balls isKindOfClass:NSArray.class] || balls.count < 1 ||
        balls.count > EightBPShadowMaxBalls || ![balls containsObject:cueBall]) {
        SetStatus(status, "Table ball collection gate failed");
        return false;
    }
    NSHashTable *identities = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSMutableIndexSet *numbers = [NSMutableIndexSet indexSet];
    for (NSObject *ball in balls) {
        if (![ball isKindOfClass:ballClass] || [identities containsObject:ball] ||
            !FinitePoint(ReadPoint(ball, 0x20))) {
            SetStatus(status, "live Ball identity/value gate failed");
            return false;
        }
        uint32_t number = ReadUInt32(ball, 0xA8);
        if ([numbers containsIndex:number]) {
            SetStatus(status, "live Ball number gate failed");
            return false;
        }
        [identities addObject:ball];
        [numbers addIndex:number];
    }
    if (slideOut) *slideOut = slide;
    return true;
}

#if EIGHTBP_SHADOW_ENABLE_VALIDATED_QUERY_ABI

struct ShadowBall {
    __strong NSObject *live = nil;
    __strong NSObject *clone = nil;
    bool active = true;
    bool potted = false;
    EightBPShadowBallPrediction *output = nullptr;
};

static NSObject *ConstructClone(NSObject *live, Class ballClass) {
    const uint32_t number = ReadUInt32(live, 0xA8);
    double radius = 0.0;
    NativePoint position = ReadPoint(live, 0x20);
    NativePoint velocity = ReadPoint(live, 0x30);
    std::memcpy(&radius, reinterpret_cast<const uint8_t *>((__bridge const void *)live) + 0x40,
                sizeof(radius));
    SEL selector = NSSelectorFromString(
        @"initWithNumber:radius:classification:initialPosition:initialVelocity:");
    // MCNumber/MCNumberPoint parameters in this binary are pointers despite
    // their Objective-C encodings. The initializer reads x3/x5/x6 directly.
    using Initializer = id (*)(id, SEL, uint32_t, const double *, int32_t,
                               const NativePoint *, const NativePoint *);
    NSObject *clone = ((Initializer)objc_msgSend)(
        [ballClass alloc], selector, number, &radius, 9, &position, &velocity);
    if (!clone) return nil;
    __unsafe_unretained NSObject *visual = nil;
    __unsafe_unretained NSObject *highlight = nil;
    __unsafe_unretained NSObject *shine = nil;
    std::memcpy(&visual, reinterpret_cast<const uint8_t *>((__bridge const void *)clone) + 0x18,
                sizeof(visual));
    std::memcpy(&highlight,
                reinterpret_cast<const uint8_t *>((__bridge const void *)clone) + 0x78,
                sizeof(highlight));
    std::memcpy(&shine,
                reinterpret_cast<const uint8_t *>((__bridge const void *)clone) + 0x80,
                sizeof(shine));
    if (visual || highlight || shine) return nil;

    // Copy only the plain native physics values; never copy owning object fields.
    std::memcpy(reinterpret_cast<uint8_t *>((__bridge void *)clone) + 0x20,
                reinterpret_cast<const uint8_t *>((__bridge const void *)live) + 0x20, 0x58);
    std::memcpy(reinterpret_cast<uint8_t *>((__bridge void *)clone) + 0xA0,
                reinterpret_cast<const uint8_t *>((__bridge const void *)live) + 0xA0, 0x12);
    return clone;
}

static void RecordPoint(ShadowBall &ball) {
    if (!ball.output || !ball.clone) return;
    NativePoint point = ReadPoint(ball.clone, 0x20);
    if (!FinitePoint(point)) return;
    EightBPShadowBallPrediction &output = *ball.output;
    if (output.pathPointCount > 0) {
        EightBPShadowPoint last = output.path[output.pathPointCount - 1];
        if (std::fabs(last.x - point.x) <= 1.0e-8 && std::fabs(last.y - point.y) <= 1.0e-8) return;
    }
    // Friction changes speed, not direction. Coalesce points on the same ray so
    // the fixed-step loop cannot fill the path buffer before the first cushion.
    // Direction changes caused by ball/cushion events remain as real vertices.
    if (output.pathPointCount >= 2) {
        EightBPShadowPoint a = output.path[output.pathPointCount - 2];
        EightBPShadowPoint b = output.path[output.pathPointCount - 1];
        double abx = b.x - a.x;
        double aby = b.y - a.y;
        double bpx = point.x - b.x;
        double bpy = point.y - b.y;
        double abLength = std::hypot(abx, aby);
        double bpLength = std::hypot(bpx, bpy);
        if (abLength > 1.0e-9 && bpLength > 1.0e-9) {
            double cross = std::fabs(abx * bpy - aby * bpx) / (abLength * bpLength);
            double dot = (abx * bpx + aby * bpy) / (abLength * bpLength);
            if (cross < 1.0e-6 && dot > 0.999999) {
                output.path[output.pathPointCount - 1] = {point.x, point.y};
                return;
            }
        }
    }
    if (output.pathPointCount < EightBPShadowMaxPathPoints) {
        output.path[output.pathPointCount++] = {point.x, point.y};
    }
}

#if defined(__arm64__)
__attribute__((naked, noinline))
static void InvokeNativeSret(id object, SEL selector, void *result, IMP function) {
    __asm__ volatile(
        "mov x8, x2\n"
        "br x3\n"
    );
}
#endif

static bool SnapshotGeometry(NSObject *table, ECEightBPShadowQueryFacade *facade) {
    SEL shapeSelector = NSSelectorFromString(@"tableShape");
    const auto *shape = ((const NativeVectorHeader *(*)(id, SEL))objc_msgSend)(table, shapeSelector);
    if (!ValidVector(shape, 3, 128)) return false;
    facade->_tableShape.assign(shape->begin, shape->end);

    SEL propertiesSelector = NSSelectorFromString(@"tableProperties");
    NSObject *properties = ((id (*)(id, SEL))objc_msgSend)(table, propertiesSelector);
    if (!properties || ![properties respondsToSelector:NSSelectorFromString(@"getPockets")] ||
        ![properties respondsToSelector:NSSelectorFromString(@"getPocketRadius")]) return false;
    const auto *pockets = ((const NativeVectorHeader *(*)(id, SEL))objc_msgSend)(
        properties, NSSelectorFromString(@"getPockets"));
    if (!ValidVector(pockets, 1, 16)) return false;
    facade->_properties = [ECEightBPShadowTableProperties new];
    facade->_properties->_pockets.assign(pockets->begin, pockets->end);

    SEL radiusSelector = NSSelectorFromString(@"getPocketRadius");
    Method radiusMethod = class_getInstanceMethod([properties class], radiusSelector);
    if (!radiusMethod) return false;
    NativeNumber radius;
    InvokeNativeSret(properties, radiusSelector, &radius,
                     method_getImplementation(radiusMethod));
    if (!std::isfinite(radius.value) || radius.value <= 0.0 || radius.value > 100.0) return false;
    facade->_properties->_pocketRadius = radius.value;

    SEL boundsSelector = NSSelectorFromString(@"tableBounds");
    Method boundsMethod = class_getInstanceMethod([table class], boundsSelector);
    if (!boundsMethod) return false;
    InvokeNativeSret(table, boundsSelector, &facade->_bounds,
                     method_getImplementation(boundsMethod));
    return FinitePoint(facade->_bounds.origin) && FinitePoint(facade->_bounds.size);
}

static CollisionPtr QueryCollision(NSObject *facade, NSObject *ball, double horizon,
                                   intptr_t slide) {
    using Function = CollisionPtr (*)(id, id, const double *, bool);
    auto function = reinterpret_cast<Function>(SlidAddress(kFindCollision, slide));
    return function(facade, ball, &horizon, false);
}

static void MoveBall(NSObject *ball, double delta, intptr_t slide) {
    using Function = void (*)(id, SEL, const double *);
    auto function = reinterpret_cast<Function>(SlidAddress(kBallMove, slide));
    function(ball, NSSelectorFromString(@"move:"), &delta);
}

static void ApplyFriction(NSObject *ball, FrictionProperties *friction, double delta,
                          intptr_t slide) {
    using Function = void (*)(id, FrictionProperties *, const double *);
    reinterpret_cast<Function>(SlidAddress(kIntegrateFriction, slide))(ball, friction, &delta);
}

static uintptr_t EventVTable(const CollisionPtr &event) {
    uintptr_t value = 0;
    if (event) std::memcpy(&value, event.get(), sizeof(value));
    return value;
}

static double EventTime(const CollisionPtr &event) {
    double value = NAN;
    if (event) std::memcpy(&value, reinterpret_cast<const uint8_t *>(event.get()) + 0x18,
                           sizeof(value));
    return value;
}

static NSObject *EventBall(const CollisionPtr &event, ptrdiff_t offset) {
    __unsafe_unretained NSObject *value = nil;
    std::memcpy(&value, reinterpret_cast<const uint8_t *>(event.get()) + offset, sizeof(value));
    return value;
}

#endif

} // namespace

void EightBPShadowSetLogCallback(EightBPShadowLogCallback callback, void *context) {
    std::lock_guard<std::mutex> lock(gStatusMutex);
    gLogCallback = callback;
    gLogContext = context;
}

const char *EightBPShadowLastStatus(void) {
    std::lock_guard<std::mutex> lock(gStatusMutex);
    return gLastStatus.data();
}

bool EightBPShadowValidateRuntime(NSObject *table, NSObject *cueBall, const void *visualGuide,
                                  const double friction[7],
                                  char status[EightBPShadowStatusCapacity]) {
    intptr_t slide = 0;
    if (!ValidateInputSurface(table, cueBall, visualGuide, friction, status, &slide)) return false;
#if EIGHTBP_SHADOW_ENABLE_VALIDATED_QUERY_ABI
    SetStatus(status, "56.29.2 shadow-physics gates passed");
    return true;
#else
    SetStatus(status, "passive gates passed; query-facade ABI is intentionally fail-closed");
    return false;
#endif
}

bool EightBPShadowPredict(NSObject *table, NSObject *cueBall, const void *visualGuide,
                         double initialSpeed, const double frictionValues[7],
                         EightBPShadowPrediction *prediction) {
    if (!prediction) {
        SetStatus(nullptr, "shadow physics received a null prediction output");
        return false;
    }
    std::memset(prediction, 0, sizeof(*prediction));
    intptr_t slide = 0;
    if (!ValidateInputSurface(table, cueBall, visualGuide, frictionValues, prediction->status,
                              &slide)) return false;
    SetStatus(prediction->status, "shadow stage 1/4: input surface validated");
    if (!std::isfinite(initialSpeed) || initialSpeed <= 0.0 || initialSpeed > 100000.0) {
        SetStatus(prediction->status, "invalid initial speed");
        return false;
    }

#if !EIGHTBP_SHADOW_ENABLE_VALIDATED_QUERY_ABI
    SetStatus(prediction->status,
              "prediction disabled: query-facade ABI awaits passive on-device validation");
    return false;
#else
    @autoreleasepool {
        NSArray *liveBalls = ((id (*)(id, SEL))objc_msgSend)(
            table, NSSelectorFromString(@"balls"));
        NSMutableArray *clones = [NSMutableArray arrayWithCapacity:liveBalls.count];
        std::vector<ShadowBall> shadowBalls;
        shadowBalls.reserve(liveBalls.count);
        Class ballClass = NSClassFromString(@"Ball");

        prediction->ballCount = static_cast<uint16_t>(liveBalls.count);
        for (NSUInteger index = 0; index < liveBalls.count; ++index) {
            NSObject *live = liveBalls[index];
            NSObject *clone = ConstructClone(live, ballClass);
            if (!clone) {
                SetStatus(prediction->status, "classification-9 Ball clone gate failed");
                return false;
            }
            [clones addObject:clone];
            EightBPShadowBallPrediction &output = prediction->balls[index];
            output.liveBall = (__bridge const void *)live;
            output.number = ReadUInt32(live, 0xA8);
            output.valid = true;
            ShadowBall state;
            state.live = live;
            state.clone = clone;
            state.output = &output;
            shadowBalls.push_back(std::move(state));
            RecordPoint(shadowBalls.back());
        }
        SetStatus(prediction->status, "shadow stage 2/4: detached balls cloned");

        auto cueIterator = std::find_if(shadowBalls.begin(), shadowBalls.end(),
            [cueBall](const ShadowBall &entry) { return entry.live == cueBall; });
        if (cueIterator == shadowBalls.end()) {
            SetStatus(prediction->status, "cue Ball was not cloned");
            return false;
        }
        const auto *guideBytes = static_cast<const uint8_t *>(visualGuide);
        NativePoint start = {}, end = {};
        std::memcpy(&start, guideBytes + 0xB0, sizeof(start));
        std::memcpy(&end, guideBytes + 0xC0, sizeof(end));
        const double length = std::hypot(end.x - start.x, end.y - start.y);
        if (!FinitePoint(start) || !FinitePoint(end) || length <= kEventEpsilon) {
            SetStatus(prediction->status, "VisualGuide direction gate failed");
            return false;
        }
        WritePoint(cueIterator->clone, 0x30,
                   {(end.x - start.x) * initialSpeed / length,
                    (end.y - start.y) * initialSpeed / length});
        // VisualGuide's temporary cue ball carries the English selected for the
        // pending shot. Copy its angular state; the live cue ball is still at
        // rest while aiming and therefore cannot supply this shot input.
        __unsafe_unretained NSObject *temporaryCue = nil;
        std::memcpy(&temporaryCue, guideBytes + 0x08, sizeof(temporaryCue));
        if (temporaryCue) {
            std::memcpy(reinterpret_cast<uint8_t *>((__bridge void *)cueIterator->clone) + 0x48,
                        reinterpret_cast<const uint8_t *>((__bridge const void *)temporaryCue) + 0x48,
                        24);
        }

        ECEightBPShadowQueryFacade *facade = [ECEightBPShadowQueryFacade new];
        facade->_shadowBalls = [clones copy];
        // Use the full query path. The fast path depends on mutable runner
        // bookkeeping that intentionally is not copied into the detached world.
        facade->_fast = NO;
        if (!SnapshotGeometry(table, facade)) {
            SetStatus(prediction->status, "detached table geometry snapshot gate failed");
            return false;
        }
        SetStatus(prediction->status, "shadow stage 3/4: table geometry copied");
        FrictionProperties friction = {};
        std::memcpy(friction.values, frictionValues, sizeof(friction.values));
        friction.table = table;

        const auto started = std::chrono::steady_clock::now();
        uint16_t zeroTimeEvents = 0;
        bool firstQueryCompleted = false;
        for (uint16_t frame = 0; frame < kMaximumFrames; ++frame) {
            if (std::chrono::steady_clock::now() - started > kWallTimeLimit) {
                SetStatus(prediction->status, "shadow simulation wall-time limit reached");
                return false;
            }
            double remaining = kLogicalFrameTime;
            while (remaining > kEventEpsilon) {
                CollisionPtr earliest;
                double earliestTime = remaining + 1.0;
                std::array<uint8_t, 0x58 * EightBPShadowMaxBalls> beforeQuery = {};
                for (size_t index = 0; index < shadowBalls.size(); ++index) {
                    ShadowBall &ball = shadowBalls[index];
                    if (!ball.active) continue;
                    uint8_t *physics = reinterpret_cast<uint8_t *>(
                        (__bridge void *)ball.clone) + 0x20;
                    std::memcpy(beforeQuery.data() + index * 0x58, physics, 0x58);
                    CollisionPtr candidate = QueryCollision(facade, ball.clone, remaining, slide);
                    if (!firstQueryCompleted) {
                        firstQueryCompleted = true;
                        SetStatus(prediction->status, "shadow stage 4/4: native collision query returned");
                    }
                    std::memcpy(physics, beforeQuery.data() + index * 0x58, 0x58);
                    if (!candidate) continue;
                    double time = EventTime(candidate);
                    if (!std::isfinite(time) || time < -kEventEpsilon ||
                        time > remaining + kEventEpsilon) {
                        SetStatus(prediction->status, "native query returned an invalid event time");
                        return false;
                    }
                    if (time < earliestTime) {
                        earliestTime = std::max(0.0, time);
                        earliest = std::move(candidate);
                    }
                }
                if (!earliest) {
                    for (ShadowBall &ball : shadowBalls) {
                        if (ball.active) MoveBall(ball.clone, remaining, slide);
                    }
                    remaining = 0.0;
                    break;
                }
                for (ShadowBall &ball : shadowBalls) {
                    if (ball.active) {
                        MoveBall(ball.clone, earliestTime, slide);
                        RecordPoint(ball);
                    }
                }
                remaining -= earliestTime;
                if (earliestTime <= kEventEpsilon) {
                    if (++zeroTimeEvents > kMaximumZeroTimeEvents) {
                        SetStatus(prediction->status, "native query entered a zero-time event loop");
                        return false;
                    }
                } else {
                    zeroTimeEvents = 0;
                }
                if (++prediction->resolvedEvents > kMaximumEvents) {
                    SetStatus(prediction->status, "shadow simulation event limit reached");
                    return false;
                }

                const uintptr_t vtable = EventVTable(earliest);
                if (vtable == reinterpret_cast<uintptr_t>(SlidAddress(kBallBallVTable, slide))) {
                    NSObject *a = EventBall(earliest, 0x28);
                    NSObject *b = EventBall(earliest, 0x38);
                    auto owns = [&shadowBalls](NSObject *candidate) {
                        return std::any_of(shadowBalls.begin(), shadowBalls.end(),
                            [candidate](const ShadowBall &entry) { return entry.clone == candidate; });
                    };
                    if (!owns(a) || !owns(b)) {
                        SetStatus(prediction->status, "ball-ball event escaped shadow ownership");
                        return false;
                    }
                    using Resolver = void (*)(id, id, FrictionProperties *, bool);
                    reinterpret_cast<Resolver>(SlidAddress(kResolveBallBall, slide))(
                        a, b, &friction, false);
                } else if (vtable == reinterpret_cast<uintptr_t>(
                               SlidAddress(kBallLineVTable, slide)) ||
                           vtable == reinterpret_cast<uintptr_t>(
                               SlidAddress(kBallPointVTable, slide))) {
                    NSObject *ball = EventBall(earliest, 0x28);
                    double normalAngle = NAN;
                    if (vtable == reinterpret_cast<uintptr_t>(
                                      SlidAddress(kBallLineVTable, slide))) {
                        std::memcpy(&normalAngle,
                            reinterpret_cast<const uint8_t *>(earliest.get()) + 0x30,
                            sizeof(normalAngle));
                    } else {
                        NativePoint point = {};
                        std::memcpy(&point,
                            reinterpret_cast<const uint8_t *>(earliest.get()) + 0x30,
                            sizeof(point));
                        NativePoint position = ReadPoint(ball, 0x20);
                        normalAngle = std::atan2(point.y - position.y, point.x - position.x);
                    }
                    if (!ball || !std::isfinite(normalAngle)) {
                        SetStatus(prediction->status, "invalid cushion collision payload");
                        return false;
                    }
                    using Resolver = void (*)(id, FrictionProperties *, const double *);
                    reinterpret_cast<Resolver>(SlidAddress(kResolveCushion, slide))(
                        ball, &friction, &normalAngle);
                } else if (vtable == reinterpret_cast<uintptr_t>(
                               SlidAddress(kBallPocketVTable, slide))) {
                    NSObject *ball = EventBall(earliest, 0x28);
                    auto entry = std::find_if(shadowBalls.begin(), shadowBalls.end(),
                        [ball](const ShadowBall &candidate) { return candidate.clone == ball; });
                    if (entry == shadowBalls.end()) {
                        SetStatus(prediction->status, "pocket event escaped shadow ownership");
                        return false;
                    }
                    entry->active = false;
                    entry->potted = true;
                    WritePoint(entry->clone, 0x30, {});
                    std::memset(reinterpret_cast<uint8_t *>((__bridge void *)entry->clone) + 0x48,
                                0, 24);
                    RecordPoint(*entry);
                } else {
                    SetStatus(prediction->status, "unknown collision vtable; prediction aborted");
                    return false;
                }
                if (facade->_unexpectedRunnerCall) {
                    SetStatus(prediction->status, "native query attempted a table-runner callback");
                    return false;
                }
            }

            bool moving = false;
            for (ShadowBall &ball : shadowBalls) {
                if (!ball.active) continue;
                ApplyFriction(ball.clone, &friction, kLogicalFrameTime, slide);
                NativePoint velocity = ReadPoint(ball.clone, 0x30);
                double spin[3] = {};
                std::memcpy(spin,
                    reinterpret_cast<const uint8_t *>((__bridge const void *)ball.clone) + 0x48,
                    sizeof(spin));
                if (!FinitePoint(velocity) || !std::isfinite(spin[0]) ||
                    !std::isfinite(spin[1]) || !std::isfinite(spin[2])) {
                    SetStatus(prediction->status, "native friction produced a non-finite Ball");
                    return false;
                }
                moving |= std::hypot(velocity.x, velocity.y) > kRestSpeed ||
                          std::fabs(spin[0]) > kRestSpeed ||
                          std::fabs(spin[1]) > kRestSpeed ||
                          std::fabs(spin[2]) > kRestSpeed;
                RecordPoint(ball);
            }
            prediction->simulatedFrames = frame + 1;
            if (!moving) break;
            if (frame + 1 == kMaximumFrames) {
                SetStatus(prediction->status, "shadow simulation frame limit reached");
                return false;
            }
        }

        for (ShadowBall &ball : shadowBalls) {
            NativePoint final = ReadPoint(ball.clone, 0x20);
            ball.output->finalPosition = {final.x, final.y};
            ball.output->potted = ball.potted;
            RecordPoint(ball);
        }
        prediction->valid = true;
        SetStatus(prediction->status, "shadow prediction completed");
        return true;
    }
#endif
}
