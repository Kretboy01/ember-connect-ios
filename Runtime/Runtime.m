#import "Runtime.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <objc/runtime.h>

@implementation ECRuntime

/// Reads the Mach-O filetype of `path`, following a fat header if present.
///
/// Worth doing before dlopen because dyld's error text for the common failure
/// here ("not a dylib") does not explain what the user should do about it.
static uint32_t ECMachOFileType(NSString *path, BOOL *found) {
    *found = NO;
    NSData *head = nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) {
        return 0;
    }
    @try {
        head = [handle readDataOfLength:4096];
    } @finally {
        [handle closeFile];
    }
    if (head.length < sizeof(struct mach_header_64)) {
        return 0;
    }

    const uint8_t *bytes = head.bytes;
    uint32_t magic = *(const uint32_t *)bytes;
    size_t offset = 0;

    // A fat binary points at per-architecture slices; read the first one's
    // header rather than the fat header itself.
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        const struct fat_header *fat = (const struct fat_header *)bytes;
        uint32_t archCount = OSSwapBigToHostInt32(fat->nfat_arch);
        if (archCount == 0 ||
            head.length < sizeof(struct fat_header) + sizeof(struct fat_arch)) {
            return 0;
        }
        const struct fat_arch *arch =
            (const struct fat_arch *)(bytes + sizeof(struct fat_header));
        offset = OSSwapBigToHostInt32(arch->offset);
        // The slice lives further into the file than our 4 KB window.
        NSFileHandle *sliceHandle = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!sliceHandle) {
            return 0;
        }
        NSData *slice = nil;
        @try {
            [sliceHandle seekToFileOffset:offset];
            slice = [sliceHandle readDataOfLength:sizeof(struct mach_header_64)];
        } @finally {
            [sliceHandle closeFile];
        }
        if (slice.length < sizeof(struct mach_header_64)) {
            return 0;
        }
        const struct mach_header_64 *sliceHeader = slice.bytes;
        *found = YES;
        return sliceHeader->filetype;
    }

    if (magic == MH_MAGIC_64 || magic == MH_CIGAM_64) {
        const struct mach_header_64 *header = (const struct mach_header_64 *)bytes;
        *found = YES;
        return header->filetype;
    }

    return 0;
}

+ (nullable NSString *)launchGuestAppAtPath:(NSString *)appPath {
    NSString *infoPlistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *infoDict = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
    if (!infoDict) {
        return [NSString stringWithFormat:
                @"No readable Info.plist inside %@.", appPath.lastPathComponent];
    }

    NSString *executableName = infoDict[@"CFBundleExecutable"];
    if (executableName.length == 0) {
        return @"The app bundle does not name an executable (CFBundleExecutable).";
    }

    NSString *executablePath = [appPath stringByAppendingPathComponent:executableName];
    if (![[NSFileManager defaultManager] fileExistsAtPath:executablePath]) {
        return [NSString stringWithFormat:
                @"The bundle is missing its executable (%@).", executableName];
    }

    // Redirect the guest's idea of home so it writes into its own container
    // rather than ours. Harmless if the load below fails.
    NSString *bundleId = infoDict[@"CFBundleIdentifier"] ?: @"unknown.app";
    NSString *documentsPath =
        [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *guestDataPath =
        [[documentsPath stringByAppendingPathComponent:@"Data"] stringByAppendingPathComponent:bundleId];
    [[NSFileManager defaultManager] createDirectoryAtPath:guestDataPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    setenv("HOME", guestDataPath.UTF8String, 1);
    setenv("CFFIXED_USER_HOME", guestDataPath.UTF8String, 1);
    setenv("TMPDIR", [guestDataPath stringByAppendingPathComponent:@"tmp"].UTF8String, 1);

    BOOL haveType = NO;
    uint32_t fileType = ECMachOFileType(executablePath, &haveType);

    // This is the real blocker, and it is structural rather than a bug in the
    // call below: an app's main binary is MH_EXECUTE, and dyld refuses to
    // dlopen those on iOS. Loading one in-process means rewriting the header
    // to MH_DYLIB, stripping the existing signature, re-signing, and then
    // intercepting the guest's own UIApplicationMain so it does not try to
    // start a second application in a process that already has one. That is
    // the entire substance of a container runtime and none of it is here yet.
    if (haveType && fileType == MH_EXECUTE) {
        return [NSString stringWithFormat:
                @"%@ is a normal app binary (MH_EXECUTE), which iOS will not load into "
                @"a running process. Running guest apps in-place needs the container "
                @"runtime, which is not implemented yet — this build can store and "
                @"transfer apps, and mirror the screen, but not launch them.",
                executableName];
    }

    void *handle = dlopen(executablePath.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    if (!handle) {
        const char *reason = dlerror();
        return [NSString stringWithFormat:@"dyld refused the guest binary: %s",
                reason ? reason : "unknown error"];
    }

    int (*guest_main)(int, char **) = dlsym(handle, "main");
    if (!guest_main) {
        dlclose(handle);
        return @"The guest binary exposes no main() symbol to jump to.";
    }

    NSLog(@"[ECRuntime] entering guest main() for %@", executableName);
    char *argv[] = { (char *)executableName.UTF8String, NULL };
    guest_main(1, argv);
    return nil;
}

@end
