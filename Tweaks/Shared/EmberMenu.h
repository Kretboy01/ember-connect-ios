#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Touch-friendly, desktop-style overlay shared by Ember game tweaks.
/// The panel is a normal subview of the game's key window; it never creates
/// or takes ownership of a UIWindow.
@interface EmberMenuPanel : UIView

@property (nonatomic, copy, nullable) void (^onClose)(void);
@property (nonatomic, readonly) NSInteger activeTab;

- (instancetype)initWithTitle:(NSString *)title accentColor:(UIColor *)accentColor;
- (void)setStatus:(NSString *)status;
- (void)setFooter:(NSString *)footer;
- (void)setTabs:(NSArray<NSString *> *)tabs
      activeTab:(NSInteger)activeTab
        handler:(void (^)(NSInteger index))handler;
- (void)selectTab:(NSInteger)index notify:(BOOL)notify;

- (void)clearRows;
- (void)addSection:(NSString *)title;
- (void)addAction:(NSString *)title
            detail:(nullable NSString *)detail
           handler:(void (^)(void))handler;
- (void)addToggle:(NSString *)title
           detail:(nullable NSString *)detail
          enabled:(BOOL)enabled
          handler:(void (^)(BOOL enabled))handler;
- (void)addSlider:(NSString *)title
            value:(float)value
              min:(float)minimum
              max:(float)maximum
           format:(NSString *)format
          handler:(void (^)(float value))handler;

- (void)presentInWindow:(UIWindow *)window;

@end

NS_ASSUME_NONNULL_END
