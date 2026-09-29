//
//  Tweak.m
//  XHSLiquidGlass —— 小红书液态玻璃插件
//
//  功能：
//   1) 隐藏原生底栏，换上悬浮液态玻璃胶囊底栏（首页 / 消息 / 我 + 右侧红色发布按钮），还原效果图
//   2) 给 App 内所有 UIButton 自动加上液态玻璃底（可开关）
//  原理：纯 ObjC runtime method swizzling，不依赖 Substrate / ElleKit，
//        打包后通过 @rpath 或越狱插件框架注入小红书进程即可。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - ============ 配置 ============

static NSString * const kLGEnabled   = @"XHSLG_Enabled";        // 总开关，默认 YES
static NSString * const kLGTabBar    = @"XHSLG_TabBarEnabled";  // 悬浮底栏，默认 YES
static NSString * const kLGBtnGlass  = @"XHSLG_ButtonGlass";    // 按钮玻璃化，默认 YES

static BOOL LGBool(NSString *key, BOOL fallback) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id v = [d objectForKey:key];
    return v ? [d boolForKey:key] : fallback;
}

/// 小红书红 #FF2442
static UIColor *LGRed(void) {
    return [UIColor colorWithRed:1.0 green:0.141 blue:0.259 alpha:1.0];
}

#pragma mark - ============ 工具 ============

static void LGSwizzle(Class cls, SEL origSel, SEL newSel) {
    Method orig = class_getInstanceMethod(cls, origSel);
    Method alt  = class_getInstanceMethod(cls, newSel);
    if (!orig || !alt) return;
    if (class_addMethod(cls, origSel, method_getImplementation(alt), method_getTypeEncoding(alt))) {
        class_replaceMethod(cls, newSel, method_getImplementation(orig), method_getTypeEncoding(orig));
    } else {
        method_exchangeImplementations(orig, alt);
    }
}

static UIWindow *LGKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) return w;
                }
            }
        }
        for (UIScene *scene in app.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                NSArray<UIWindow *> *ws = ((UIWindowScene *)scene).windows;
                if (ws.count) return ws.firstObject;
            }
        }
        return nil;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow;
#pragma clang diagnostic pop
}

static void LGHaptic(void) {
    UIImpactFeedbackGenerator *g =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [g impactOccurred];
}

/// 液态玻璃质感视图：系统毛玻璃 + 顶部高光 + 细白边
@interface LGGlassView : UIVisualEffectView
- (instancetype)initWithRadius:(CGFloat)radius;
@end

@implementation LGGlassView

- (instancetype)initWithRadius:(CGFloat)radius {
    self = [super initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    if (self) {
        self.layer.cornerRadius = radius;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.35].CGColor;
        CAGradientLayer *hi = [CAGradientLayer layer];
        hi.name = @"lg_highlight";
        hi.colors = @[(id)[[UIColor whiteColor] colorWithAlphaComponent:0.38].CGColor,
                      (id)[[UIColor whiteColor] colorWithAlphaComponent:0.0].CGColor];
        hi.startPoint = CGPointMake(0.5, 0.0);
        hi.endPoint = CGPointMake(0.5, 0.5);
        [self.contentView.layer addSublayer:hi];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    for (CALayer *l in self.contentView.layer.sublayers) {
        if ([l.name isEqualToString:@"lg_highlight"]) {
            l.frame = self.contentView.bounds;
        }
    }
}

@end

#pragma mark - ============ 底栏按钮 ============

@interface LGTabButton : UIButton
@property (nonatomic, copy) NSString *iconName;
@property (nonatomic, copy) NSString *iconNameSelected;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, strong) UIView *dotView;
@property (nonatomic, copy) void (^tapAction)(void);
- (instancetype)initWithIcon:(NSString *)icon
               selectedIcon:(NSString *)selIcon
                      title:(NSString *)title;
- (void)setBadgeHidden:(BOOL)hidden;
@end

@implementation LGTabButton

- (instancetype)initWithIcon:(NSString *)icon
               selectedIcon:(NSString *)selIcon
                      title:(NSString *)title {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _iconName = [icon copy];
        _iconNameSelected = [selIcon copy];

        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:25
                                                           weight:UIImageSymbolWeightRegular];
        _iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:icon
                                                                withConfiguration:cfg]];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_iconView];

        _subLabel = [[UILabel alloc] init];
        _subLabel.text = title;
        _subLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        _subLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_subLabel];

        _dotView = [[UIView alloc] init];
        _dotView.backgroundColor = LGRed();
        _dotView.layer.cornerRadius = 4;
        _dotView.hidden = YES;
        [self addSubview:_dotView];

        [self addTarget:self action:@selector(didTouchDown) forControlEvents:UIControlEventTouchDown];
        [self addTarget:self action:@selector(didTap) forControlEvents:UIControlEventTouchUpInside];
        [self setSelected:NO];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    self.iconView.frame = CGRectMake((w - 28) / 2.0, 7, 28, 28);
    self.subLabel.frame = CGRectMake(0, 37, w, 14);
    self.dotView.frame = CGRectMake((w + 28) / 2.0 - 2, 5, 8, 8);
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    UIColor *c = selected ? LGRed() : [UIColor labelColor];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:25
                                                       weight:selected ? UIImageSymbolWeightSemibold
                                                                     : UIImageSymbolWeightRegular];
    self.iconView.image = [UIImage systemImageNamed:selected ? self.iconNameSelected : self.iconName
                                   withConfiguration:cfg];
    self.iconView.tintColor = c;
    self.subLabel.textColor = c;
}

- (void)setBadgeHidden:(BOOL)hidden {
    self.dotView.hidden = hidden;
}

- (void)didTouchDown {
    LGHaptic();
}

- (void)didTap {
    if (self.tapAction) self.tapAction();
}

@end

#pragma mark - ============ 悬浮玻璃底栏 ============

@interface LGTabBarView : UIView
@property (nonatomic, weak) UITabBarController *tbc;
@property (nonatomic, strong) UIView *pillHolder;   // 阴影层（毛玻璃本身 masksToBounds，阴影需外包一层）
@property (nonatomic, strong) LGGlassView *pill;
@property (nonatomic, strong) UIView *selBg;        // 选中项淡红底
@property (nonatomic, strong) NSArray<LGTabButton *> *buttons;
@property (nonatomic, strong) NSArray<NSNumber *> *vcIndexForButton; // 每个按钮对应的 VC 下标
@property (nonatomic, assign) NSInteger publishVCIndex;              // 发布页 VC 下标，-1 表示没找到
@property (nonatomic, strong) UIButton *plusButton;
- (instancetype)initWithTabController:(UITabBarController *)tbc;
- (void)refresh;
@end

@implementation LGTabBarView

- (instancetype)initWithTabController:(UITabBarController *)tbc {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _tbc = tbc;
        self.backgroundColor = [UIColor clearColor];

        _pillHolder = [[UIView alloc] init];
        _pillHolder.backgroundColor = [UIColor clearColor];
        _pillHolder.layer.cornerRadius = 32;
        _pillHolder.layer.shadowColor = [UIColor blackColor].CGColor;
        _pillHolder.layer.shadowOpacity = 0.18;
        _pillHolder.layer.shadowRadius = 14;
        _pillHolder.layer.shadowOffset = CGSizeMake(0, 5);
        [self addSubview:_pillHolder];

        _pill = [[LGGlassView alloc] initWithRadius:32];
        [_pillHolder addSubview:_pill];

        _selBg = [[UIView alloc] init];
        _selBg.backgroundColor = [LGRed() colorWithAlphaComponent:0.12];
        _selBg.layer.cornerRadius = 20;
        [_pill.contentView addSubview:_selBg];

        [self resolveTabs];

        NSMutableArray<LGTabButton *> *btns = [NSMutableArray array];
        NSArray<NSDictionary *> *infos = @[
            @{@"icon": @"house",   @"sel": @"house.fill",   @"title": @"首页"},
            @{@"icon": @"message", @"sel": @"message.fill", @"title": @"消息"},
            @{@"icon": @"person",  @"sel": @"person.fill",  @"title": @"我"},
        ];
        for (NSInteger i = 0; i < 3; i++) {
            NSDictionary *info = infos[i];
            LGTabButton *b = [[LGTabButton alloc] initWithIcon:info[@"icon"]
                                                 selectedIcon:info[@"sel"]
                                                        title:info[@"title"]];
            NSInteger vcIdx = [self.vcIndexForButton[i] integerValue];
            __weak typeof(self) ws = self;
            b.tapAction = ^{
                ws.tbc.selectedIndex = vcIdx;
                [ws refresh];
            };
            [_pill.contentView addSubview:b];
            [btns addObject:b];
        }
        _buttons = [btns copy];

        // 右侧红色圆形发布按钮
        _plusButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _plusButton.backgroundColor = LGRed();
        _plusButton.layer.shadowColor = [LGRed() colorWithAlphaComponent:0.5].CGColor;
        _plusButton.layer.shadowOpacity = 0.45;
        _plusButton.layer.shadowRadius = 10;
        _plusButton.layer.shadowOffset = CGSizeMake(0, 4);
        UIImageSymbolConfiguration *pcfg =
            [UIImageSymbolConfiguration configurationWithPointSize:26
                                                           weight:UIImageSymbolWeightSemibold];
        [_plusButton setImage:[UIImage systemImageNamed:@"plus" withConfiguration:pcfg]
                    forState:UIControlStateNormal];
        _plusButton.tintColor = [UIColor whiteColor];
        [_plusButton addTarget:self
                        action:@selector(plusTapped)
              forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_plusButton];

        [self refresh];
    }
    return self;
}

/// 按标题找出 首页 / 消息 / 我 各自对应的 VC 下标，顺带找发布页
- (void)resolveTabs {
    NSArray<UIViewController *> *vcs = self.tbc.viewControllers ?: @[];
    NSInteger home = -1, msg = -1, me = -1, pub = -1;
    for (NSInteger i = 0; i < vcs.count; i++) {
        UIViewController *vc = vcs[i];
        NSString *t = vc.tabBarItem.title ?: vc.title ?: @"";
        NSString *cls = NSStringFromClass([vc class]);
        if ([t containsString:@"首页"]) {
            home = i;
        } else if ([t containsString:@"消息"]) {
            msg = i;
        } else if ([t containsString:@"我"]) {
            me = i;
        } else if (t.length == 0 &&
                   ([cls rangeOfString:@"Publish" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [cls rangeOfString:@"Shoot"   options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [cls rangeOfString:@"Create"  options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [cls rangeOfString:@"Capture" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
            pub = i;
        }
    }
    if (home < 0 || msg < 0 || me < 0) {
        // 兜底：按位置猜（3 个 tab 直接 0/1/2；多 tab 时跳过中间的发布占位）
        if (vcs.count == 3) {
            home = 0; msg = 1; me = 2;
        } else if (vcs.count >= 4) {
            home = 0; msg = vcs.count - 2; me = vcs.count - 1;
        } else if (vcs.count > 0) {
            home = 0; me = vcs.count - 1; msg = vcs.count > 2 ? 1 : 0;
        }
    }
    if (pub < 0) {
        for (NSInteger i = 0; i < vcs.count; i++) {
            if (i != home && i != msg && i != me && vcs[i].tabBarItem.title.length == 0) {
                pub = i;
                break;
            }
        }
    }
    self.vcIndexForButton = @[@(MAX(home, 0)), @(MAX(msg, 0)), @(MAX(me, 0))];
    self.publishVCIndex = pub;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat margin = 16, plusD = 54, gap = 10;
    CGFloat pillW = W - margin * 2 - plusD - gap;

    self.pillHolder.frame = CGRectMake(margin, 0, pillW, H);
    self.pill.frame = self.pillHolder.bounds;

    self.plusButton.frame = CGRectMake(W - margin - plusD, (H - plusD) / 2.0, plusD, plusD);
    self.plusButton.layer.cornerRadius = plusD / 2.0;

    CGFloat bw = pillW / 3.0;
    for (NSInteger i = 0; i < self.buttons.count; i++) {
        self.buttons[i].frame = CGRectMake(i * bw, 0, bw, H);
    }
    [self refreshSelectionBg];
}

- (void)refreshSelectionBg {
    for (NSInteger i = 0; i < self.buttons.count; i++) {
        if (self.buttons[i].selected) {
            self.selBg.frame = CGRectInset(self.buttons[i].frame, 12, 9);
            return;
        }
    }
}

/// 只让胶囊和发布按钮吃触摸，其余区域透过去
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01) return nil;
    if (CGRectContainsPoint(self.plusButton.frame, point)) return self.plusButton;
    CGPoint p = [self convertPoint:point toView:self.pillHolder];
    if (CGRectContainsPoint(self.pillHolder.bounds, p)) {
        return [super hitTest:point withEvent:event];
    }
    return nil;
}

- (void)refresh {
    if (!self.tbc) return;

    // push 进详情页且要求隐藏底栏时，悬浮栏也隐藏
    UIViewController *sel = self.tbc.selectedViewController;
    BOOL hideBar = NO;
    if ([sel isKindOfClass:[UINavigationController class]]) {
        hideBar = ((UINavigationController *)sel).topViewController.hidesBottomBarWhenPushed;
    } else {
        hideBar = sel.hidesBottomBarWhenPushed;
    }
    self.hidden = hideBar;
    if (hideBar) return;

    NSUInteger idx = self.tbc.selectedIndex;
    for (NSInteger i = 0; i < self.buttons.count; i++) {
        NSInteger vcIdx = [self.vcIndexForButton[i] integerValue];
        LGTabButton *b = self.buttons[i];
        b.selected = (vcIdx == (NSInteger)idx);
        // 把原生 tabBarItem 的 badge 同步成消息红点
        NSString *badge = nil;
        if (vcIdx < (NSInteger)self.tbc.viewControllers.count) {
            badge = self.tbc.viewControllers[vcIdx].tabBarItem.badgeValue;
        }
        [b setBadgeHidden:badge.length == 0];
    }
    [self refreshSelectionBg];
}

- (void)plusTapped {
    LGHaptic();
    if (self.publishVCIndex >= 0 &&
        self.publishVCIndex < (NSInteger)self.tbc.viewControllers.count) {
        self.tbc.selectedIndex = self.publishVCIndex;
        [self refresh];
    } else {
        // 没找到发布页时发个通知，方便外部再 hook
        [[NSNotificationCenter defaultCenter] postNotificationName:@"XHSLGPublishTapped"
                                                            object:nil];
    }
}

@end

#pragma mark - ============ 主 TabBar 判定 ============

static BOOL LGIsMainTabBar(UITabBarController *tbc) {
    if (tbc.viewControllers.count < 3) return NO;
    NSString *n = NSStringFromClass([tbc class]);
    if ([n rangeOfString:@"Tabbar" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([n rangeOfString:@"Tab" options:NSCaseInsensitiveSearch].location != NSNotFound &&
        [n rangeOfString:@"Main" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    UIWindow *w = LGKeyWindow();
    return w && w.rootViewController == tbc;
}

#pragma mark - ============ Hook: 底栏替换 ============

@interface UITabBarController (XHSLiquidGlass)
@end

@implementation UITabBarController (XHSLiquidGlass)

- (void)lg_viewDidLayoutSubviews {
    [self lg_viewDidLayoutSubviews];
    if (!LGBool(kLGEnabled, YES) || !LGBool(kLGTabBar, YES)) return;
    if (!LGIsMainTabBar(self)) return;

    self.tabBar.hidden = YES;

    LGTabBarView *bar = objc_getAssociatedObject(self, @selector(lg_viewDidLayoutSubviews));
    if (!bar) {
        bar = [[LGTabBarView alloc] initWithTabController:self];
        objc_setAssociatedObject(self, @selector(lg_viewDidLayoutSubviews),
                                 bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self.view addSubview:bar];
    }
    [self.view bringSubviewToFront:bar];

    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat h = 64;
    bar.frame = CGRectMake(0,
                           self.view.bounds.size.height - safe.bottom - 10 - h,
                           self.view.bounds.size.width,
                           h);
    [bar refresh];
}

- (void)lg_setSelectedIndex:(NSUInteger)index {
    [self lg_setSelectedIndex:index];
    LGTabBarView *bar = objc_getAssociatedObject(self, @selector(lg_viewDidLayoutSubviews));
    [bar refresh];
}

@end

#pragma mark - ============ Hook: push/pop 时刷新底栏显隐 ============

@interface UINavigationController (XHSLiquidGlass)
@end

@implementation UINavigationController (XHSLiquidGlass)

- (void)lg_pushViewController:(UIViewController *)vc animated:(BOOL)animated {
    [self lg_pushViewController:vc animated:animated];
    [self lg_refreshParentTabBar];
}

- (UIViewController *)lg_popViewControllerAnimated:(BOOL)animated {
    UIViewController *vc = [self lg_popViewControllerAnimated:animated];
    // pop 动画结束后再刷新一次，避免闪烁
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self lg_refreshParentTabBar];
    });
    return vc;
}

- (void)lg_refreshParentTabBar {
    UITabBarController *tbc = self.tabBarController;
    if (!tbc) return;
    LGTabBarView *bar = objc_getAssociatedObject(tbc, @selector(lg_viewDidLayoutSubviews));
    [bar refresh];
}

@end

#pragma mark - ============ 功能2：所有按钮玻璃化 ============

static const char kLGButtonGlassKey;

static BOOL LGInsideOurBar(UIView *v) {
    while (v) {
        if ([v isKindOfClass:[LGTabBarView class]]) return YES;
        v = v.superview;
    }
    return NO;
}

static void LGApplyButtonGlass(UIButton *btn) {
    if (LGInsideOurBar(btn)) return;                       // 跳过我们自己的底栏按钮
    CGSize s = btn.bounds.size;
    if (s.width < 26 || s.height < 26) return;             // 太小的按钮跳过
    if ([btn backgroundImageForState:UIControlStateNormal]) return; // 已有背景图的跳过
    if ([btn.superview isKindOfClass:[UIVisualEffectView class]]) return;

    LGGlassView *glass = objc_getAssociatedObject(btn, &kLGButtonGlassKey);
    if (!glass) {
        glass = [[LGGlassView alloc] initWithRadius:12];
        glass.userInteractionEnabled = NO;
        glass.alpha = 0.92;
        [btn insertSubview:glass atIndex:0];
        objc_setAssociatedObject(btn, &kLGButtonGlassKey,
                                 glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glass.frame = btn.bounds;
    // 接近正方形的按圆形处理，宽按钮按胶囊处理
    glass.layer.cornerRadius = (fabs(s.width - s.height) < 10)
        ? MIN(s.width, s.height) / 2.0
        : s.height / 2.0;
}

@interface UIButton (XHSLiquidGlass)
@end

@implementation UIButton (XHSLiquidGlass)

- (void)lg_buttonLayoutSubviews {
    [self lg_buttonLayoutSubviews];
    if (LGBool(kLGEnabled, YES)) {
        LGApplyButtonGlass(self);
    }
}

@end

#pragma mark - ============ 入口 ============

@interface XLGLoader : NSObject
@end

@implementation XLGLoader

+ (void)load {
    // 延迟到主线程，确保 UIApplication 已就绪
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self install];
    });
}

+ (void)install {
    // 只在小红书进程里生效，防止误注入别的 App
    // （小红书各版本 BundleID 有 com.xingin.xiaohongshu / com.xingin.discover 等）
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if (![bid hasPrefix:@"com.xingin."]) return;

    if (!LGBool(kLGEnabled, YES)) return;

    LGSwizzle([UITabBarController class],
              @selector(viewDidLayoutSubviews), @selector(lg_viewDidLayoutSubviews));
    LGSwizzle([UITabBarController class],
              @selector(setSelectedIndex:), @selector(lg_setSelectedIndex:));
    LGSwizzle([UINavigationController class],
              @selector(pushViewController:animated:), @selector(lg_pushViewController:animated:));
    LGSwizzle([UINavigationController class],
              @selector(popViewControllerAnimated:), @selector(lg_popViewControllerAnimated:));

    if (LGBool(kLGBtnGlass, YES)) {
        LGSwizzle([UIButton class],
                  @selector(layoutSubviews), @selector(lg_buttonLayoutSubviews));
    }
}

@end
