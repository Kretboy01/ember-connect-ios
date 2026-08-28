#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ECRuntime : NSObject

/// Attempts to load and start the executable inside a guest .app bundle.
///
/// Returns nil on success, or a human-readable explanation of what stopped it.
/// The previous version returned void and logged failures with NSLog, so a tap
/// that could not possibly work looked identical to one that did nothing.
+ (nullable NSString *)launchGuestAppAtPath:(NSString *)appPath;

@end

NS_ASSUME_NONNULL_END
