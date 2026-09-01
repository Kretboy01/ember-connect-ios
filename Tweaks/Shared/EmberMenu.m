#import "EmberMenu.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static const void *EmberMenuActionKey = &EmberMenuActionKey;
static const void *EmberMenuToggleKey = &EmberMenuToggleKey;
static const void *EmberMenuSliderKey = &EmberMenuSliderKey;
static const void *EmberMenuSliderLabelKey = &EmberMenuSliderLabelKey;
static const void *EmberMenuSliderFormatKey = &EmberMenuSliderFormatKey;
static const void *EmberMenuTabIndexKey = &EmberMenuTabIndexKey;

@interface EmberMenuPanel ()
@property (nonatomic, strong) UIColor *accentColor;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *footerLabel;
@property (nonatomic, strong) UIView *titleBar;
@property (nonatomic, strong) UIScrollView *tabScroll;
@property (nonatomic, strong) UIStackView *tabStack;
@property (nonatomic, strong) UIScrollView *contentScroll;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, copy) void (^tabHandler)(NSInteger index);
@property (nonatomic, strong) NSArray<UIButton *> *tabButtons;
@property (nonatomic, readwrite) NSInteger activeTab;
@end

@implementation EmberMenuPanel

- (instancetype)initWithTitle:(NSString *)title accentColor:(UIColor *)accentColor {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    _accentColor = accentColor ?: [UIColor colorWithRed:0.25 green:0.82 blue:0.95 alpha:1.0];
    _activeTab = NSNotFound;
    self.backgroundColor = [UIColor colorWithRed:0.035 green:0.043 blue:0.055 alpha:0.985];
    self.layer.cornerRadius = 8.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [_accentColor colorWithAlphaComponent:0.48].CGColor;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.72;
    self.layer.shadowRadius = 18.0;
    self.clipsToBounds = NO;

    _titleBar = [UIView new];
    _titleBar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.035];
    _titleBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_titleBar];

    _titleLabel = [UILabel new];
    _titleLabel.text = title;
    _titleLabel.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightBold];
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_titleBar addSubview:_titleLabel];

    _statusLabel = [UILabel new];
    _statusLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _statusLabel.textColor = [_accentColor colorWithAlphaComponent:0.9];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_titleBar addSubview:_statusLabel];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.titleLabel.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightBold];
    [close setTitle:@"×" forState:UIControlStateNormal];
    close.tintColor = [UIColor colorWithWhite:0.82 alpha:1.0];
    close.backgroundColor = [UIColor colorWithRed:0.55 green:0.12 blue:0.16 alpha:0.35];
    close.layer.cornerRadius = 4.0;
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [_titleBar addSubview:close];

    _tabScroll = [UIScrollView new];
    _tabScroll.showsHorizontalScrollIndicator = NO;
    _tabScroll.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.28];
    _tabScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_tabScroll];

    _tabStack = [UIStackView new];
    _tabStack.axis = UILayoutConstraintAxisHorizontal;
    _tabStack.spacing = 3.0;
    _tabStack.alignment = UIStackViewAlignmentFill;
    _tabStack.translatesAutoresizingMaskIntoConstraints = NO;
    [_tabScroll addSubview:_tabStack];

    _contentScroll = [UIScrollView new];
    _contentScroll.alwaysBounceVertical = YES;
    _contentScroll.showsVerticalScrollIndicator = YES;
    _contentScroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _contentScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_contentScroll];

    _contentStack = [UIStackView new];
    _contentStack.axis = UILayoutConstraintAxisVertical;
    _contentStack.spacing = 6.0;
    _contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [_contentScroll addSubview:_contentStack];

    _footerLabel = [UILabel new];
    _footerLabel.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    _footerLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    _footerLabel.text = @"EMBER CONNECT  •  DRAG TITLE BAR TO MOVE";
    _footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_footerLabel];

    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
    [_titleBar addGestureRecognizer:drag];

    [NSLayoutConstraint activateConstraints:@[
        [_titleBar.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_titleBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_titleBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_titleBar.heightAnchor constraintEqualToConstant:52.0],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_titleBar.leadingAnchor constant:14.0],
        [_titleLabel.topAnchor constraintEqualToAnchor:_titleBar.topAnchor constant:8.0],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_statusLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2.0],
        [_statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-8.0],
        [close.trailingAnchor constraintEqualToAnchor:_titleBar.trailingAnchor constant:-10.0],
        [close.centerYAnchor constraintEqualToAnchor:_titleBar.centerYAnchor],
        [close.widthAnchor constraintEqualToConstant:30.0],
        [close.heightAnchor constraintEqualToConstant:28.0],

        [_tabScroll.topAnchor constraintEqualToAnchor:_titleBar.bottomAnchor],
        [_tabScroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_tabScroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_tabScroll.heightAnchor constraintEqualToConstant:39.0],
        [_tabStack.topAnchor constraintEqualToAnchor:_tabScroll.contentLayoutGuide.topAnchor constant:4.0],
        [_tabStack.bottomAnchor constraintEqualToAnchor:_tabScroll.contentLayoutGuide.bottomAnchor constant:-4.0],
        [_tabStack.leadingAnchor constraintEqualToAnchor:_tabScroll.contentLayoutGuide.leadingAnchor constant:8.0],
        [_tabStack.trailingAnchor constraintEqualToAnchor:_tabScroll.contentLayoutGuide.trailingAnchor constant:-8.0],
        [_tabStack.heightAnchor constraintEqualToAnchor:_tabScroll.frameLayoutGuide.heightAnchor constant:-8.0],

        [_contentScroll.topAnchor constraintEqualToAnchor:_tabScroll.bottomAnchor constant:1.0],
        [_contentScroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:9.0],
        [_contentScroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-9.0],
        [_contentScroll.bottomAnchor constraintEqualToAnchor:_footerLabel.topAnchor constant:-5.0],
        [_contentStack.topAnchor constraintEqualToAnchor:_contentScroll.contentLayoutGuide.topAnchor constant:8.0],
        [_contentStack.bottomAnchor constraintEqualToAnchor:_contentScroll.contentLayoutGuide.bottomAnchor constant:-8.0],
        [_contentStack.leadingAnchor constraintEqualToAnchor:_contentScroll.contentLayoutGuide.leadingAnchor],
        [_contentStack.trailingAnchor constraintEqualToAnchor:_contentScroll.contentLayoutGuide.trailingAnchor],
        [_contentStack.widthAnchor constraintEqualToAnchor:_contentScroll.frameLayoutGuide.widthAnchor],

        [_footerLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12.0],
        [_footerLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12.0],
        [_footerLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-5.0],
        [_footerLabel.heightAnchor constraintEqualToConstant:16.0],
    ]];
    return self;
}

- (void)setStatus:(NSString *)status { self.statusLabel.text = status ?: @""; }
- (void)setFooter:(NSString *)footer { self.footerLabel.text = footer ?: @""; }

- (void)setTabs:(NSArray<NSString *> *)tabs activeTab:(NSInteger)activeTab handler:(void (^)(NSInteger))handler {
    for (UIView *view in self.tabStack.arrangedSubviews.copy) {
        [self.tabStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    self.tabHandler = handler;
    NSMutableArray *buttons = [NSMutableArray arrayWithCapacity:tabs.count];
    [tabs enumerateObjectsUsingBlock:^(NSString *name, NSUInteger index, BOOL *stop) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.titleLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
        [button setTitle:[name uppercaseString] forState:UIControlStateNormal];
        button.contentEdgeInsets = UIEdgeInsetsMake(5, 12, 5, 12);
        button.layer.cornerRadius = 4.0;
        objc_setAssociatedObject(button, EmberMenuTabIndexKey, @(index), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [button addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.tabStack addArrangedSubview:button];
        [buttons addObject:button];
    }];
    self.tabButtons = buttons;
    [self selectTab:activeTab notify:NO];
}

- (void)selectTab:(NSInteger)index notify:(BOOL)notify {
    if (index < 0 || index >= (NSInteger)self.tabButtons.count) return;
    self.activeTab = index;
    [self.tabButtons enumerateObjectsUsingBlock:^(UIButton *button, NSUInteger idx, BOOL *stop) {
        BOOL selected = idx == (NSUInteger)index;
        button.backgroundColor = selected ? [self.accentColor colorWithAlphaComponent:0.25]
                                          : [UIColor colorWithWhite:1.0 alpha:0.045];
        button.tintColor = selected ? self.accentColor : [UIColor colorWithWhite:0.68 alpha:1.0];
        button.layer.borderWidth = selected ? 1.0 : 0.0;
        button.layer.borderColor = [self.accentColor colorWithAlphaComponent:0.62].CGColor;
    }];
    if (notify && self.tabHandler) self.tabHandler(index);
}

- (void)clearRows {
    for (UIView *view in self.contentStack.arrangedSubviews.copy) {
        [self.contentStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    self.contentScroll.contentOffset = CGPointZero;
}

- (UILabel *)detailLabel:(NSString *)detail {
    UILabel *label = [UILabel new];
    label.text = detail;
    label.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    label.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    label.numberOfLines = 1;
    return label;
}

- (void)addSection:(NSString *)title {
    UILabel *label = [UILabel new];
    label.text = [NSString stringWithFormat:@"  %@", title.uppercaseString];
    label.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightBold];
    label.textColor = self.accentColor;
    label.backgroundColor = [self.accentColor colorWithAlphaComponent:0.08];
    label.layer.cornerRadius = 3.0;
    label.clipsToBounds = YES;
    [label.heightAnchor constraintEqualToConstant:24.0].active = YES;
    [self.contentStack addArrangedSubview:label];
}

- (void)addAction:(NSString *)title detail:(NSString *)detail handler:(void (^)(void))handler {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    button.titleLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold];
    button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [button setTitle:detail.length ? [NSString stringWithFormat:@"  %@\n  %@", title, detail]
                                      : [NSString stringWithFormat:@"  %@", title]
            forState:UIControlStateNormal];
    button.titleLabel.numberOfLines = detail.length ? 2 : 1;
    button.tintColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.055];
    button.layer.cornerRadius = 4.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.06].CGColor;
    [button.heightAnchor constraintEqualToConstant:detail.length ? 48.0 : 38.0].active = YES;
    objc_setAssociatedObject(button, EmberMenuActionKey, handler, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [button addTarget:self action:@selector(actionTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.contentStack addArrangedSubview:button];
}

- (void)addToggle:(NSString *)title detail:(NSString *)detail enabled:(BOOL)enabled handler:(void (^)(BOOL))handler {
    UIView *row = [UIView new];
    row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.045];
    row.layer.cornerRadius = 4.0;
    [row.heightAnchor constraintEqualToConstant:50.0].active = YES;
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:label];
    UILabel *sub = [self detailLabel:detail ?: @""];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:sub];
    UISwitch *toggle = [UISwitch new];
    toggle.on = enabled;
    toggle.onTintColor = self.accentColor;
    toggle.transform = CGAffineTransformMakeScale(0.78, 0.78);
    toggle.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(toggle, EmberMenuToggleKey, handler, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    [row addSubview:toggle];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:11.0],
        [label.topAnchor constraintEqualToAnchor:row.topAnchor constant:8.0],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:toggle.leadingAnchor constant:-8.0],
        [sub.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
        [sub.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:2.0],
        [sub.trailingAnchor constraintLessThanOrEqualToAnchor:toggle.leadingAnchor constant:-8.0],
        [toggle.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-8.0],
        [toggle.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
    [self.contentStack addArrangedSubview:row];
}

- (void)addSlider:(NSString *)title value:(float)value min:(float)minimum max:(float)maximum format:(NSString *)format handler:(void (^)(float))handler {
    UIView *row = [UIView new];
    row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.045];
    row.layer.cornerRadius = 4.0;
    [row.heightAnchor constraintEqualToConstant:57.0].active = YES;
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
    label.textColor = [UIColor colorWithWhite:0.88 alpha:1.0];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:label];
    UILabel *valueLabel = [UILabel new];
    valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightBold];
    valueLabel.textColor = self.accentColor;
    valueLabel.textAlignment = NSTextAlignmentRight;
    valueLabel.text = [NSString stringWithFormat:format ?: @"%.2f", value];
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:valueLabel];
    UISlider *slider = [UISlider new];
    slider.minimumValue = minimum;
    slider.maximumValue = maximum;
    slider.value = value;
    slider.minimumTrackTintColor = self.accentColor;
    slider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(slider, EmberMenuSliderKey, handler, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(slider, EmberMenuSliderLabelKey, valueLabel, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(slider, EmberMenuSliderFormatKey, format ?: @"%.2f", OBJC_ASSOCIATION_COPY_NONATOMIC);
    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [row addSubview:slider];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:11.0],
        [label.topAnchor constraintEqualToAnchor:row.topAnchor constant:7.0],
        [valueLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-11.0],
        [valueLabel.centerYAnchor constraintEqualToAnchor:label.centerYAnchor],
        [valueLabel.widthAnchor constraintEqualToConstant:72.0],
        [slider.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:10.0],
        [slider.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10.0],
        [slider.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:3.0],
    ]];
    [self.contentStack addArrangedSubview:row];
}

- (void)presentInWindow:(UIWindow *)window {
    if (!window) return;
    CGFloat width = MIN(570.0, MAX(350.0, CGRectGetWidth(window.bounds) * 0.78));
    CGFloat height = MIN(430.0, MAX(300.0, CGRectGetHeight(window.bounds) * 0.84));
    self.frame = CGRectMake(0, 0, width, height);
    self.center = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
    self.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                            UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [window addSubview:self];
    [window bringSubviewToFront:self];
}

- (void)closeTapped { if (self.onClose) self.onClose(); }
- (void)tabTapped:(UIButton *)sender {
    NSNumber *index = objc_getAssociatedObject(sender, EmberMenuTabIndexKey);
    [self selectTab:index.integerValue notify:YES];
}
- (void)actionTapped:(UIButton *)sender {
    void (^handler)(void) = objc_getAssociatedObject(sender, EmberMenuActionKey);
    if (handler) handler();
}
- (void)toggleChanged:(UISwitch *)sender {
    void (^handler)(BOOL) = objc_getAssociatedObject(sender, EmberMenuToggleKey);
    if (handler) handler(sender.isOn);
}
- (void)sliderChanged:(UISlider *)sender {
    UILabel *label = objc_getAssociatedObject(sender, EmberMenuSliderLabelKey);
    NSString *format = objc_getAssociatedObject(sender, EmberMenuSliderFormatKey);
    label.text = [NSString stringWithFormat:format ?: @"%.2f", sender.value];
    void (^handler)(float) = objc_getAssociatedObject(sender, EmberMenuSliderKey);
    if (handler) handler(sender.value);
}
- (void)dragged:(UIPanGestureRecognizer *)gesture {
    UIView *host = self.superview;
    if (!host) return;
    CGPoint delta = [gesture translationInView:host];
    CGPoint center = self.center;
    center.x += delta.x;
    center.y += delta.y;
    CGFloat halfW = CGRectGetWidth(self.bounds) * 0.5;
    CGFloat halfH = CGRectGetHeight(self.bounds) * 0.5;
    center.x = MAX(halfW * 0.35, MIN(CGRectGetWidth(host.bounds) - halfW * 0.35, center.x));
    center.y = MAX(halfH * 0.35, MIN(CGRectGetHeight(host.bounds) - halfH * 0.35, center.y));
    self.center = center;
    [gesture setTranslation:CGPointZero inView:host];
}

@end
