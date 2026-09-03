// Included only by LCBootstrap.m: signed, process-local Fortnite 42.10 support.
// No game code pages are patched, no executable memory is allocated, and no
// kernel entitlements are granted. Unknown builds and unrelated exits are untouched.
#include <CommonCrypto/CommonDigest.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <fcntl.h>
#include <unistd.h>
#include "EmberFortniteGuards.h"

#if defined(__arm64__) && !defined(__arm64e__)
static uintptr_t EmberFNBase;
static bool EmberFNApproved;
static int EmberFNLogFD = -1;
static uintptr_t EmberFNObject;
static void (*EmberFNOriginalFree)(void *, void *);
static uintptr_t EmberFNTable[0x210 / sizeof(uintptr_t)] __attribute__((aligned(16)));
static const uint8_t EmberFNUUID[16] = {
    0x31,0xd1,0xec,0x91,0x7d,0xde,0x31,0x25,0x8f,0x33,0x75,0xaa,0x02,0x3b,0x83,0x4d
};
static const uint8_t EmberFNLoop[] = {
    0xf5,0x01,0x00,0xb4,0x88,0x02,0x40,0xb9,0xe8,0x18,0x00,0x34,
    0x81,0x82,0x5f,0xf8,0xe0,0x83,0x01,0x91,0x24,0x16,0xfe,0x97,
    0xe0,0x77,0x40,0xf9,0xdc,0x00,0x00,0x94,0xf3,0x03,0x00,0xaa,
    0xe0,0x73,0x40,0xf9,0x20,0x18,0x00,0xb5,0x94,0x42,0x00,0x91,
    0xb5,0x42,0x00,0xd1,0x73,0xfe,0x07,0x37,0xd3,0x4a,0x00,0x94
};
static const uint8_t EmberFNFreeBytes[] = {
    0x61,0x00,0x00,0xb4,0xe0,0x03,0x01,0xaa,0xef,0xe8,0x01,0x14,0xc0,0x03,0x5f,0xd6
};

static void EmberFNLog(const char *message) {
    if (EmberFNLogFD >= 0) {
        write(EmberFNLogFD, message, strlen(message));
        write(EmberFNLogFD, "\n", 1);
    }
}

static bool EmberFNRead(uintptr_t address, void *out, size_t size) {
    vm_size_t copied = 0;
    return address && vm_read_overwrite(mach_task_self(), address, size,
        (vm_address_t)out, &copied) == KERN_SUCCESS && copied == size;
}

// This function is ordinary signed host code, not debugger/JIT-generated code.
// Deliberately allocation-free and log-free, including on the recursive path.
static void EmberFNFree(void *object, void *pointer) {
    if (!pointer) return;
    if (malloc_zone_from_ptr(pointer)) free(pointer);
    else EmberFNOriginalFree(object, pointer);
}

static bool EmberFNInstallFree(void) {
    uintptr_t object = 0, table = 0, originalFree = 0;
    uint8_t code[sizeof(EmberFNFreeBytes)];
    if (!EmberFNRead(EmberFNBase + 0x1479f5e8, &object, sizeof(object)) || (object & 7) ||
        !EmberFNRead(object, &table, sizeof(table))) return false;
    if (EmberFNObject) return object == EmberFNObject && table == (uintptr_t)&EmberFNTable[2];
    if (!EmberFNRead(table + 0x50, &originalFree, sizeof(originalFree)) ||
        originalFree != EmberFNBase + 0x483cba4 ||
        !EmberFNRead(originalFree, code, sizeof(code)) ||
        memcmp(code, EmberFNFreeBytes, sizeof(code)) ||
        !EmberFNRead(table - 16, EmberFNTable, sizeof(EmberFNTable))) return false;
    EmberFNOriginalFree = (void (*)(void *, void *))originalFree;
    EmberFNTable[2 + 0x50 / sizeof(uintptr_t)] = (uintptr_t)EmberFNFree;
    // Publish the fully initialized table with a single pointer swap. Preserve
    // RTTI and every other virtual method; do not modify the shared original.
    if (!__atomic_compare_exchange_n((uintptr_t *)object, &table,
            (uintptr_t)&EmberFNTable[2], false, __ATOMIC_RELEASE, __ATOMIC_RELAXED)) return false;
    EmberFNObject = object;
    EmberFNLog("42.10 signed Free dispatcher active (no debugger)");
    return true;
}

// Called only through the assembly entry below. x20 points just past the
// failed FString entry in this exact build's already-advanced startup loop.
__attribute__((used, noinline))
static uintptr_t EmberFortniteExitDecision(int status, uintptr_t caller, uintptr_t cursor) {
    if (!EmberFNBase || status != 0 || caller != EmberFNBase + 0x6287c0 || cursor < 24) return 0;
    uintptr_t string = 0;
    int32_t length = 0;
    uint16_t name[96] = {0};
    if (!EmberFNRead(cursor - 24, &string, sizeof(string)) ||
        !EmberFNRead(cursor - 16, &length, sizeof(length)) || length <= 1 || length > 96 ||
        !EmberFNRead(string, name, (size_t)length * 2) || name[length - 1] != 0) return 0;
    if (!EmberFNAllowedFailure(status, caller, EmberFNBase, name, length)) return 0;
    if (!EmberFNInstallFree()) {
        EmberFNLog("Allocator guard failed; preserving original startup exit");
        return 0;
    }
    EmberFNLog("Continuing verified memory-check loop; kernel permissions unchanged");
    return EmberFNBase + 0x628784;
}

// The guest's _Exit import is a tail call: LR is the loop's return address,
// and SP has no libc _Exit frame yet. Preserve that state around the C check.
// Unknown callers tail-call the real host _Exit, never return from a noreturn API.
__attribute__((naked, used, noreturn))
static void EmberFortniteExitGate(int status) {
    __asm__ volatile(
        "sub sp, sp, #32\n"
        "stp x29, x30, [sp, #16]\n"
        "str x0, [sp]\n"
        "mov x29, sp\n"
        "mov x1, x30\n"
        "mov x2, x20\n"
        "bl _EmberFortniteExitDecision\n"
        "mov x16, x0\n"
        "ldr x0, [sp]\n"
        "ldp x29, x30, [sp, #16]\n"
        "add sp, sp, #32\n"
        "cbz x16, 1f\n"
        "br x16\n"
        "1: b __Exit\n"
    );
}

static void EmberFNImageAdded(const struct mach_header *header, intptr_t slide) {
    if (!EmberFNApproved || EmberFNBase || header->magic != MH_MAGIC_64 ||
        header->cputype != CPU_TYPE_ARM64 || header->cpusubtype != CPU_SUBTYPE_ARM64_ALL) return;
    const struct mach_header_64 *mh = (const void *)header;
    if (mh->sizeofcmds > 65536 || mh->ncmds > 1024) return;
    const uint8_t *p = (const uint8_t *)(mh + 1), *end = p + mh->sizeofcmds;
    bool uuidOK = false;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (p + sizeof(struct load_command) > end) return;
        const struct load_command *lc = (const void *)p;
        if (lc->cmdsize < sizeof(*lc) || lc->cmdsize > (size_t)(end - p)) return;
        if (lc->cmd == LC_UUID && lc->cmdsize == sizeof(struct uuid_command))
            uuidOK = !memcmp(((const struct uuid_command *)lc)->uuid, EmberFNUUID, 16);
        p += lc->cmdsize;
    }
    if (!uuidOK || (uintptr_t)mh != (uintptr_t)slide + 0x100000000ULL) return;
    uintptr_t base = (uintptr_t)mh, original = 0;
    uint8_t loop[sizeof(EmberFNLoop)];
    // Exact __got slot discovered from the __Exit symbol's indirect stub.
    uintptr_t *slot = (uintptr_t *)(base + 0xdb1e340);
    if (!EmberFNRead(base + 0x628784, loop, sizeof(loop)) || memcmp(loop, EmberFNLoop, sizeof(loop)) ||
        !EmberFNRead((uintptr_t)slot, &original, sizeof(original)) || original != (uintptr_t)_Exit) {
        EmberFNLog("Live code/import guard failed; no compatibility changes");
        return;
    }
    vm_address_t region = (uintptr_t)slot;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &region, &size,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (kr != KERN_SUCCESS || region > (uintptr_t)slot || (uintptr_t)slot + 8 > region + size) return;
    vm_address_t page = (uintptr_t)slot & ~((uintptr_t)vm_page_size - 1);
    kr = vm_protect(mach_task_self(), page, vm_page_size, false,
                        info.protection | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) { EmberFNLog("Import data page not writable; no compatibility changes"); return; }
    EmberFNBase = base;
    bool changed = __atomic_compare_exchange_n(slot, &original, (uintptr_t)EmberFortniteExitGate,
        false, __ATOMIC_RELEASE, __ATOMIC_RELAXED);
    if (!changed) EmberFNBase = 0;
    kr = vm_protect(mach_task_self(), page, vm_page_size, false, info.protection);
    if (kr != KERN_SUCCESS) EmberFNLog("Warning: could not restore import data page protection");
    EmberFNLog(changed ? "42.10 startup exit gate armed; signed host code only" : "Import changed concurrently; gate not armed");
}

static void EmberFortniteCompatibilityPrepare(NSBundle *bundle, NSDictionary *settings, NSString *documents) {
    if (![bundle.bundleIdentifier isEqualToString:@"com.epicgames.FortniteGame"] ||
        [settings[@"EmberFortniteCompatibilityDisabled"] boolValue]) return;
    EmberFNLogFD = open([[documents stringByAppendingPathComponent:@"EmberFortniteCompat.log"] fileSystemRepresentation],
                        O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (![bundle.infoDictionary[@"CFBundleShortVersionString"] isEqualToString:@"42.10"] ||
        ![bundle.infoDictionary[@"CFBundleVersion"] isEqualToString:@"57581488.1.4"]) {
        EmberFNLog("Unsupported Fortnite version: automatic workaround disabled"); return;
    }
    // Re-signing changes Mach-O headers/signatures, but not this __text region.
    // Hash the complete approved code section, not just a few matched instructions.
    int fd = open(bundle.executablePath.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) { EmberFNLog("Cannot open guest executable; disabled"); return; }
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    uint8_t buffer[65536], digest[CC_SHA256_DIGEST_LENGTH];
    off_t offset = 0x4000;
    size_t remaining = 0xc49ce98;
    while (remaining) {
        size_t n = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
        ssize_t got = pread(fd, buffer, n, offset);
        if (got <= 0) break;
        CC_SHA256_Update(&hash, buffer, (CC_LONG)got);
        remaining -= (size_t)got;
        offset += got;
    }
    close(fd);
    CC_SHA256_Final(digest, &hash);
    static const uint8_t expected[32] = {
        0x61,0x97,0x06,0x0b,0x14,0x35,0x7f,0x82,0x34,0xf4,0xec,0xb4,0x89,0x20,0x12,0xf8,
        0x94,0x9d,0xe7,0xa6,0x59,0xcb,0x8f,0x9e,0x49,0xef,0xd1,0xd5,0xbb,0xb3,0x86,0xe8
    };
    if (remaining || memcmp(digest, expected, sizeof(expected))) {
        EmberFNLog("Code-section SHA256 mismatch: automatic workaround disabled"); return;
    }
    EmberFNApproved = true;
    EmberFNLog("Approved 42.10 code hash; waiting for guest image");
    _dyld_register_func_for_add_image(EmberFNImageAdded);
}
#else
static void EmberFortniteCompatibilityPrepare(NSBundle *bundle, NSDictionary *settings, NSString *documents) {}
#endif
