#import "Runtime.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

@implementation ECRuntime

+ (void)launchGuestAppAtPath:(NSString *)appPath {
    // 1. Read Info.plist to find the executable name
    NSString *infoPlistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *infoDict = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
    if (!infoDict) {
        NSLog(@"[ECRuntime] Failed to read Info.plist at %@", infoPlistPath);
        return;
    }
    
    NSString *executableName = infoDict[@"CFBundleExecutable"];
    if (!executableName) {
        NSLog(@"[ECRuntime] No CFBundleExecutable in Info.plist");
        return;
    }
    
    NSString *executablePath = [appPath stringByAppendingPathComponent:executableName];
    
    // 2. Set up environment variables to spoof the sandbox
    // This makes the guest app write to /Documents/Data/<BundleID> instead of our root
    NSString *bundleId = infoDict[@"CFBundleIdentifier"] ?: @"unknown.app";
    NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *guestDataPath = [[documentsPath stringByAppendingPathComponent:@"Data"] stringByAppendingPathComponent:bundleId];
    
    [[NSFileManager defaultManager] createDirectoryAtPath:guestDataPath withIntermediateDirectories:YES attributes:nil error:nil];
    
    setenv("HOME", [guestDataPath UTF8String], 1);
    setenv("CFFIXED_USER_HOME", [guestDataPath UTF8String], 1);
    setenv("TMPDIR", [[guestDataPath stringByAppendingPathComponent:@"tmp"] UTF8String], 1);
    
    // 3. Load the executable via dlopen
    NSLog(@"[ECRuntime] Loading guest executable: %@", executablePath);
    void *handle = dlopen([executablePath UTF8String], RTLD_LAZY | RTLD_GLOBAL);
    if (!handle) {
        NSLog(@"[ECRuntime] dlopen failed: %s", dlerror());
        return;
    }
    
    // 4. Find the main() function of the guest app
    int (*guest_main)(int, char **) = dlsym(handle, "main");
    if (!guest_main) {
        NSLog(@"[ECRuntime] Could not find main() in guest executable");
        return;
    }
    
    // 5. Execute
    NSLog(@"[ECRuntime] Jumping to guest main()...");
    
    // We pass dummy argc/argv. Real implementations might pass the actual launch args.
    char *argv[] = { (char *)[executableName UTF8String], NULL };
    guest_main(1, argv);
}

@end
