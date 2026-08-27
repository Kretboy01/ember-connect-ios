#import <Foundation/Foundation.h>

@interface ECRuntime : NSObject

// Launches the executable inside the guest .app bundle.
// Note: This requires the host app to have get-task-allow entitlement
// and for JIT to be enabled over the network prior to calling.
+ (void)launchGuestAppAtPath:(NSString *)appPath;

@end
