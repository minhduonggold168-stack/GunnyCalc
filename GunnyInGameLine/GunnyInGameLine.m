#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <math.h>

static const NSTimeInterval kGunnyFullChargeSeconds = 2.20;
static const CGFloat kGunnyToggleSize = 28.0;
static const CGFloat kGunnyMinAngle = 20.0;
static const CGFloat kGunnyMaxAngle = 75.0;
static const CGFloat kGunnyMinWind = -5.0;
static const CGFloat kGunnyMaxWind = 5.0;

// MARK: - Passive Touch Observer for Game Fire Button

@protocol GunnyFireHoldObserverDelegate <NSObject>
- (BOOL)gunnyObserverShouldTrackTouchAtScreenPoint:(CGPoint)screenPoint;
- (void)gunnyObserverDidBeginFireHold;
- (void)gunnyObserverDidEndFireHold;
@end

/// Gesture recognizer hoàn toàn thụ động: chỉ quan sát thời điểm người dùng nhấn/thả ngón tay,
/// tuyệt đối không chặn, không làm trễ và không can thiệp touch của game.
@interface GunnyFireHoldObserverGesture : UIGestureRecognizer <UIGestureRecognizerDelegate>
@property (nonatomic, weak) id<GunnyFireHoldObserverDelegate> observerDelegate;
@property (nonatomic, strong) UITouch *trackedTouch;
@end

@implementation GunnyFireHoldObserverGesture

- (instancetype)init {
    self = [super initWithTarget:nil action:nil];
    if (self) {
        self.cancelsTouchesInView = NO;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
        self.requiresExclusiveTouchType = NO;
        self.delegate = self;
    }
    return self;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    (void)gestureRecognizer;
    (void)touch;
    return YES;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (self.trackedTouch != nil) {
        return;
    }
    for (UITouch *touch in touches) {
        CGPoint pointInWindow = [touch locationInView:self.view];
        if ([self.observerDelegate gunnyObserverShouldTrackTouchAtScreenPoint:pointInWindow]) {
            self.trackedTouch = touch;
            [self.observerDelegate gunnyObserverDidBeginFireHold];
            break;
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    if (self.trackedTouch != nil && [touches containsObject:self.trackedTouch]) {
        self.trackedTouch = nil;
        [self.observerDelegate gunnyObserverDidEndFireHold];
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    if (self.trackedTouch != nil && [touches containsObject:self.trackedTouch]) {
        self.trackedTouch = nil;
        [self.observerDelegate gunnyObserverDidEndFireHold];
    }
}

- (void)reset {
    [super reset];
    if (self.trackedTouch != nil) {
        self.trackedTouch = nil;
        [self.observerDelegate gunnyObserverDidEndFireHold];
    }
}

@end

// MARK: - Transparent Pass-Through Window & Root View

@interface GunnyPassThroughView : UIView
@end

@implementation GunnyPassThroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || !hitView.userInteractionEnabled) {
        return nil;
    }
    return hitView;
}

@end

@interface GunnyPassThroughWindow : UIWindow
@end

@implementation GunnyPassThroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view || !hitView.userInteractionEnabled) {
        return nil;
    }
    return hitView;
}

@end

// MARK: - Main Overlay View Controller

@interface GunnyInGameOverlayController : UIViewController <GunnyFireHoldObserverDelegate>

@property (nonatomic, weak) UIWindow *overlayWindow;
@property (nonatomic, assign) BOOL aimingEnabled;
@property (nonatomic, assign) BOOL hasInitializedLayout;

@property (nonatomic, assign) CGFloat windValue;
@property (nonatomic, assign) CGFloat angleDeg;
@property (nonatomic, assign) CGFloat calculatedPower;
@property (nonatomic, assign) CGPoint playerPoint;
@property (nonatomic, assign) CGPoint enemyPoint;

@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIView *aimingContainerView;

@property (nonatomic, strong) UIView *playerAnchorView;
@property (nonatomic, strong) UIView *enemyAnchorView;
@property (nonatomic, strong) UIView *controlBarView;
@property (nonatomic, strong) UILabel *windValueLabel;
@property (nonatomic, strong) UILabel *angleValueLabel;
@property (nonatomic, strong) UILabel *powerBadgeLabel;

@property (nonatomic, strong) CAShapeLayer *trajectoryGlowLayer;
@property (nonatomic, strong) CAShapeLayer *trajectoryLineLayer;
@property (nonatomic, strong) CAShapeLayer *travelOrbGlowLayer;
@property (nonatomic, strong) CAShapeLayer *travelOrbCoreLayer;

@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval holdStartTime;
@property (nonatomic, assign) BOOL isHoldingFire;

@property (nonatomic, strong) NSMutableArray<NSValue *> *cachedCurvePoints;
@property (nonatomic, assign) CGFloat cachedFlightTime;
@property (nonatomic, assign) CGPoint cachedV0;
@property (nonatomic, assign) CGFloat cachedAx;
@property (nonatomic, assign) CGFloat cachedEffectiveGravity;
@property (nonatomic, assign) CGFloat cachedPixelsPerUnit;

@property (nonatomic, weak) UIWindow *observedGameWindow;
@property (nonatomic, strong) GunnyFireHoldObserverGesture *fireObserverGesture;

@end

@implementation GunnyInGameOverlayController

- (void)loadView {
    GunnyPassThroughView *root = [[GunnyPassThroughView alloc] initWithFrame:CGRectZero];
    root.backgroundColor = [UIColor clearColor];
    root.opaque = NO;
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.windValue = 0.0;
    self.angleDeg = 65.0;
    self.calculatedPower = 0.0;
    self.aimingEnabled = NO;
    self.cachedCurvePoints = [NSMutableArray arrayWithCapacity:48];

    [self setupAimingOverlay];
    [self setupToggleButton];
    [self attachFireObserverIfNeeded];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.aimingContainerView.frame = self.view.bounds;

    if (!self.hasInitializedLayout && CGRectGetWidth(self.view.bounds) > 0 && CGRectGetHeight(self.view.bounds) > 0) {
        self.hasInitializedLayout = YES;
        [self resetDefaultPositions];
    } else {
        [self clampOverlayControlsToBounds];
    }

    if (self.aimingEnabled) {
        [self recalculateAndRedrawTrajectory];
    }
}

- (void)dealloc {
    [self stopChargeDisplayLink];
    if (self.observedGameWindow != nil && self.fireObserverGesture != nil) {
        [self.observedGameWindow removeGestureRecognizer:self.fireObserverGesture];
    }
}

// MARK: - Setup UI Elements

- (void)setupToggleButton {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(0, 0, kGunnyToggleSize, kGunnyToggleSize);
    btn.layer.cornerRadius = kGunnyToggleSize * 0.5;
    btn.backgroundColor = [UIColor colorWithRed:0.06 green:0.09 blue:0.14 alpha:0.55];
    btn.layer.borderWidth = 1.25;
    btn.layer.borderColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.533 alpha:0.75].CGColor;
    btn.layer.shadowColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.533 alpha:1.0].CGColor;
    btn.layer.shadowRadius = 4.0;
    btn.layer.shadowOpacity = 0.35;
    btn.layer.shadowOffset = CGSizeZero;

    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightBold];
        UIImage *icon = [UIImage systemImageNamed:@"scope" withConfiguration:cfg];
        [btn setImage:icon forState:UIControlStateNormal];
        btn.tintColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.533 alpha:0.95];
    }

    [btn addTarget:self action:@selector(handleToggleAiming:) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *dragEdge = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleTogglePan:)];
    [btn addGestureRecognizer:dragEdge];

    [self.view addSubview:btn];
    self.toggleButton = btn;
}

- (void)setupAimingOverlay {
    GunnyPassThroughView *container = [[GunnyPassThroughView alloc] initWithFrame:self.view.bounds];
    container.backgroundColor = [UIColor clearColor];
    container.opaque = NO;
    container.hidden = YES;
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:container];
    self.aimingContainerView = container;

    // 1. Parabol nét đứt màu xanh lá neon phát sáng (#00FF88).
    CAShapeLayer *glowLayer = [CAShapeLayer layer];
    glowLayer.fillColor = [UIColor clearColor].CGColor;
    glowLayer.strokeColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.533 alpha:0.28].CGColor;
    glowLayer.lineWidth = 6.0;
    glowLayer.lineCap = kCALineCapRound;
    glowLayer.lineDashPattern = @[@8, @6];
    [container.layer addSublayer:glowLayer];
    self.trajectoryGlowLayer = glowLayer;

    CAShapeLayer *lineLayer = [CAShapeLayer layer];
    lineLayer.fillColor = [UIColor clearColor].CGColor;
    lineLayer.strokeColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.533 alpha:0.98].CGColor;
    lineLayer.lineWidth = 2.4;
    lineLayer.lineCap = kCALineCapRound;
    lineLayer.lineDashPattern = @[@8, @6];
    lineLayer.shadowColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.533 alpha:1.0].CGColor;
    lineLayer.shadowRadius = 6.0;
    lineLayer.shadowOpacity = 0.85;
    lineLayer.shadowOffset = CGSizeZero;
    [container.layer addSublayer:lineLayer];
    self.trajectoryLineLayer = lineLayer;

    // 2. Điểm sáng chạy theo parabol khi giữ nút bắn.
    CAShapeLayer *orbGlow = [CAShapeLayer layer];
    orbGlow.bounds = CGRectMake(0, 0, 26, 26);
    orbGlow.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 26, 26)].CGPath;
    orbGlow.fillColor = [UIColor colorWithRed:1.0 green:0.92 blue:0.25 alpha:0.42].CGColor;
    orbGlow.hidden = YES;
    [container.layer addSublayer:orbGlow];
    self.travelOrbGlowLayer = orbGlow;

    CAShapeLayer *orbCore = [CAShapeLayer layer];
    orbCore.bounds = CGRectMake(0, 0, 12, 12);
    orbCore.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 12, 12)].CGPath;
    orbCore.fillColor = [UIColor whiteColor].CGColor;
    orbCore.strokeColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.533 alpha:1.0].CGColor;
    orbCore.lineWidth = 2.0;
    orbCore.shadowColor = [UIColor yellowColor].CGColor;
    orbCore.shadowRadius = 8.0;
    orbCore.shadowOpacity = 1.0;
    orbCore.shadowOffset = CGSizeZero;
    orbCore.hidden = YES;
    [container.layer addSublayer:orbCore];
    self.travelOrbCoreLayer = orbCore;

    // 3. Con số lực bắn hiện ngay trên đường kẻ.
    UILabel *powerLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    powerLabel.userInteractionEnabled = NO;
    powerLabel.backgroundColor = [UIColor colorWithRed:0.04 green:0.06 blue:0.10 alpha:0.84];
    powerLabel.textColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.533 alpha:1.0];
    powerLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightHeavy];
    powerLabel.textAlignment = NSTextAlignmentCenter;
    powerLabel.layer.cornerRadius = 8.0;
    powerLabel.layer.masksToBounds = YES;
    powerLabel.layer.borderWidth = 1.0;
    powerLabel.layer.borderColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.533 alpha:0.75].CGColor;
    [container addSubview:powerLabel];
    self.powerBadgeLabel = powerLabel;

    // 4. Hai điểm neo kéo thả: Điểm Xanh (chân nhân vật) & Tâm Đỏ (vị trí địch).
    self.playerAnchorView = [self createPlayerAnchorView];
    UIPanGestureRecognizer *playerPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePlayerAnchorPan:)];
    [self.playerAnchorView addGestureRecognizer:playerPan];
    [container addSubview:self.playerAnchorView];

    self.enemyAnchorView = [self createEnemyAnchorView];
    UIPanGestureRecognizer *enemyPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleEnemyAnchorPan:)];
    [self.enemyAnchorView addGestureRecognizer:enemyPan];
    [container addSubview:self.enemyAnchorView];

    // 5. Thanh điều chỉnh siêu gọn trong suốt ngay dưới thanh gió của game.
    [self setupCompactControlBarInContainer:container];
}

- (UIView *)createPlayerAnchorView {
    UIView *holder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
    holder.backgroundColor = [UIColor clearColor];

    UIView *halo = [[UIView alloc] initWithFrame:CGRectMake(12, 12, 24, 24)];
    halo.userInteractionEnabled = NO;
    halo.layer.cornerRadius = 12;
    halo.backgroundColor = [UIColor colorWithRed:0.12 green:0.62 blue:1.0 alpha:0.30];
    [holder addSubview:halo];

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(17, 17, 14, 14)];
    dot.userInteractionEnabled = NO;
    dot.layer.cornerRadius = 7;
    dot.backgroundColor = [UIColor colorWithRed:0.12 green:0.62 blue:1.0 alpha:1.0];
    dot.layer.borderColor = [UIColor whiteColor].CGColor;
    dot.layer.borderWidth = 1.8;
    [holder addSubview:dot];

    UILabel *tag = [[UILabel alloc] initWithFrame:CGRectMake(10, 34, 28, 12)];
    tag.userInteractionEnabled = NO;
    tag.text = @"BẠN";
    tag.textAlignment = NSTextAlignmentCenter;
    tag.font = [UIFont systemFontOfSize:8.5 weight:UIFontWeightBold];
    tag.textColor = [UIColor whiteColor];
    tag.backgroundColor = [UIColor colorWithRed:0.06 green:0.35 blue:0.68 alpha:0.85];
    tag.layer.cornerRadius = 4;
    tag.layer.masksToBounds = YES;
    [holder addSubview:tag];

    return holder;
}

- (UIView *)createEnemyAnchorView {
    UIView *holder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
    holder.backgroundColor = [UIColor clearColor];

    CAShapeLayer *crosshair = [CAShapeLayer layer];
    UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(15, 15, 18, 18)];
    [path moveToPoint:CGPointMake(11, 24)];
    [path addLineToPoint:CGPointMake(37, 24)];
    [path moveToPoint:CGPointMake(24, 11)];
    [path addLineToPoint:CGPointMake(24, 37)];
    crosshair.path = path.CGPath;
    crosshair.fillColor = [UIColor colorWithRed:1.0 green:0.20 blue:0.20 alpha:0.25].CGColor;
    crosshair.strokeColor = [UIColor colorWithRed:1.0 green:0.24 blue:0.24 alpha:0.98].CGColor;
    crosshair.lineWidth = 1.8;
    crosshair.shadowColor = [UIColor redColor].CGColor;
    crosshair.shadowRadius = 4.0;
    crosshair.shadowOpacity = 0.75;
    crosshair.shadowOffset = CGSizeZero;
    [holder.layer addSublayer:crosshair];

    UILabel *tag = [[UILabel alloc] initWithFrame:CGRectMake(9, 34, 30, 12)];
    tag.userInteractionEnabled = NO;
    tag.text = @"ĐỊCH";
    tag.textAlignment = NSTextAlignmentCenter;
    tag.font = [UIFont systemFontOfSize:8.5 weight:UIFontWeightBold];
    tag.textColor = [UIColor whiteColor];
    tag.backgroundColor = [UIColor colorWithRed:0.75 green:0.12 blue:0.12 alpha:0.85];
    tag.layer.cornerRadius = 4;
    tag.layer.masksToBounds = YES;
    [holder addSubview:tag];

    return holder;
}

- (void)setupCompactControlBarInContainer:(UIView *)container {
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 348, 34)];
    bar.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.11 alpha:0.65];
    bar.layer.cornerRadius = 11;
    bar.layer.borderWidth = 1.0;
    bar.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.24].CGColor;

    UIPanGestureRecognizer *barPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleControlBarPan:)];
    [bar addGestureRecognizer:barPan];

    CGFloat x = 6.0;
    // Gió: -0.5, -0.1, [Gió], +0.1, +0.5
    UIButton *wMinusHalf = [self compactStepButtonWithTitle:@"−.5" tag:-5 action:@selector(handleWindButton:)];
    wMinusHalf.frame = CGRectMake(x, 4, 28, 26);
    [bar addSubview:wMinusHalf];
    x += 30;

    UIButton *wMinusTenth = [self compactStepButtonWithTitle:@"−.1" tag:-1 action:@selector(handleWindButton:)];
    wMinusTenth.frame = CGRectMake(x, 4, 28, 26);
    [bar addSubview:wMinusTenth];
    x += 30;

    UILabel *windLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, 4, 66, 26)];
    windLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightBold];
    windLabel.textColor = [UIColor colorWithRed:0.35 green:0.88 blue:1.0 alpha:1.0];
    windLabel.textAlignment = NSTextAlignmentCenter;
    windLabel.userInteractionEnabled = YES;
    UITapGestureRecognizer *resetWindTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleResetWind)];
    [windLabel addGestureRecognizer:resetWindTap];
    [bar addSubview:windLabel];
    self.windValueLabel = windLabel;
    x += 68;

    UIButton *wPlusTenth = [self compactStepButtonWithTitle:@"+.1" tag:1 action:@selector(handleWindButton:)];
    wPlusTenth.frame = CGRectMake(x, 4, 28, 26);
    [bar addSubview:wPlusTenth];
    x += 30;

    UIButton *wPlusHalf = [self compactStepButtonWithTitle:@"+.5" tag:5 action:@selector(handleWindButton:)];
    wPlusHalf.frame = CGRectMake(x, 4, 28, 26);
    [bar addSubview:wPlusHalf];
    x += 32;

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(x, 7, 1, 20)];
    sep.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.22];
    [bar addSubview:sep];
    x += 5;

    // Góc: -5, -1, [Góc], +1, +5
    UIButton *aMinusFive = [self compactStepButtonWithTitle:@"-5" tag:-5 action:@selector(handleAngleButton:)];
    aMinusFive.frame = CGRectMake(x, 4, 24, 26);
    [bar addSubview:aMinusFive];
    x += 26;

    UIButton *aMinusOne = [self compactStepButtonWithTitle:@"-1" tag:-1 action:@selector(handleAngleButton:)];
    aMinusOne.frame = CGRectMake(x, 4, 22, 26);
    [bar addSubview:aMinusOne];
    x += 24;

    UILabel *angleLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, 4, 34, 26)];
    angleLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightBold];
    angleLabel.textColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.24 alpha:1.0];
    angleLabel.textAlignment = NSTextAlignmentCenter;
    angleLabel.userInteractionEnabled = YES;
    UITapGestureRecognizer *cycleAngleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleCycleAngle)];
    [angleLabel addGestureRecognizer:cycleAngleTap];
    [bar addSubview:angleLabel];
    self.angleValueLabel = angleLabel;
    x += 36;

    UIButton *aPlusOne = [self compactStepButtonWithTitle:@"+1" tag:1 action:@selector(handleAngleButton:)];
    aPlusOne.frame = CGRectMake(x, 4, 22, 26);
    [bar addSubview:aPlusOne];
    x += 24;

    UIButton *aPlusFive = [self compactStepButtonWithTitle:@"+5" tag:5 action:@selector(handleAngleButton:)];
    aPlusFive.frame = CGRectMake(x, 4, 24, 26);
    [bar addSubview:aPlusFive];

    [container addSubview:bar];
    self.controlBarView = bar;
    [self refreshControlLabels];
}

- (UIButton *)compactStepButtonWithTitle:(NSString *)title tag:(NSInteger)tag action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.tag = tag;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightBold];
    btn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    btn.layer.cornerRadius = 6;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (void)resetDefaultPositions {
    CGRect bounds = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;

    // Nút bật/tắt 28x28pt bám mép phải màn hình.
    self.toggleButton.center = CGPointMake(
        CGRectGetWidth(bounds) - safe.right - (kGunnyToggleSize * 0.5) - 6.0,
        MAX(safe.top + 68.0, CGRectGetHeight(bounds) * 0.35)
    );

    // Thanh Gió & Góc đặt ngay dưới khu vực thanh gió phía trên màn hình game.
    CGFloat barY = MAX(safe.top + 54.0, 56.0);
    self.controlBarView.center = CGPointMake(CGRectGetMidX(bounds), barY);

    self.playerPoint = CGPointMake(CGRectGetWidth(bounds) * 0.25, CGRectGetHeight(bounds) * 0.65);
    self.enemyPoint = CGPointMake(CGRectGetWidth(bounds) * 0.72, CGRectGetHeight(bounds) * 0.62);
    self.playerAnchorView.center = self.playerPoint;
    self.enemyAnchorView.center = self.enemyPoint;
}

- (void)clampOverlayControlsToBounds {
    CGRect bounds = self.view.bounds;
    if (CGRectIsEmpty(bounds)) { return; }

    self.playerPoint = [self clampPoint:self.playerPoint toBounds:bounds margin:16.0];
    self.enemyPoint = [self clampPoint:self.enemyPoint toBounds:bounds margin:16.0];
    self.playerAnchorView.center = self.playerPoint;
    self.enemyAnchorView.center = self.enemyPoint;

    CGFloat halfBarW = CGRectGetWidth(self.controlBarView.bounds) * 0.5;
    CGFloat halfBarH = CGRectGetHeight(self.controlBarView.bounds) * 0.5;
    CGPoint barCenter = self.controlBarView.center;
    barCenter.x = MIN(MAX(barCenter.x, halfBarW + 4.0), CGRectGetWidth(bounds) - halfBarW - 4.0);
    barCenter.y = MIN(MAX(barCenter.y, halfBarH + 4.0), CGRectGetHeight(bounds) - halfBarH - 4.0);
    self.controlBarView.center = barCenter;

    CGPoint toggleCenter = self.toggleButton.center;
    toggleCenter.y = MIN(MAX(toggleCenter.y, 24.0), CGRectGetHeight(bounds) - 24.0);
    if (toggleCenter.x < CGRectGetMidX(bounds)) {
        toggleCenter.x = self.view.safeAreaInsets.left + kGunnyToggleSize * 0.5 + 6.0;
    } else {
        toggleCenter.x = CGRectGetWidth(bounds) - self.view.safeAreaInsets.right - kGunnyToggleSize * 0.5 - 6.0;
    }
    self.toggleButton.center = toggleCenter;
}

- (CGPoint)clampPoint:(CGPoint)pt toBounds:(CGRect)bounds margin:(CGFloat)margin {
    CGFloat x = MIN(MAX(pt.x, margin), CGRectGetWidth(bounds) - margin);
    CGFloat y = MIN(MAX(pt.y, margin), CGRectGetHeight(bounds) - margin);
    return CGPointMake(x, y);
}

// MARK: - Actions & Gestures

- (void)handleToggleAiming:(UIButton *)sender {
    (void)sender;
    self.aimingEnabled = !self.aimingEnabled;
    self.aimingContainerView.hidden = !self.aimingEnabled;

    if (self.aimingEnabled) {
        [self attachFireObserverIfNeeded];
        self.toggleButton.backgroundColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.533 alpha:0.28];
        self.toggleButton.layer.borderColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.533 alpha:1.0].CGColor;
        [self recalculateAndRedrawTrajectory];
    } else {
        [self gunnyObserverDidEndFireHold];
        self.toggleButton.backgroundColor = [UIColor colorWithRed:0.06 green:0.09 blue:0.14 alpha:0.55];
        self.toggleButton.layer.borderColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.533 alpha:0.75].CGColor;
    }
}

- (void)handleTogglePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.view];
    [pan setTranslation:CGPointZero inView:self.view];

    CGPoint next = CGPointMake(self.toggleButton.center.x + translation.x, self.toggleButton.center.y + translation.y);
    CGRect bounds = self.view.bounds;
    next.x = MIN(MAX(next.x, kGunnyToggleSize * 0.5 + 4.0), CGRectGetWidth(bounds) - kGunnyToggleSize * 0.5 - 4.0);
    next.y = MIN(MAX(next.y, kGunnyToggleSize * 0.5 + 4.0), CGRectGetHeight(bounds) - kGunnyToggleSize * 0.5 - 4.0);
    self.toggleButton.center = next;

    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        // Bám lại mép trái hoặc phải gọn gàng.
        CGFloat snapX = (next.x < CGRectGetMidX(bounds))
            ? (self.view.safeAreaInsets.left + kGunnyToggleSize * 0.5 + 6.0)
            : (CGRectGetWidth(bounds) - self.view.safeAreaInsets.right - kGunnyToggleSize * 0.5 - 6.0);
        [UIView animateWithDuration:0.18 animations:^{
            self.toggleButton.center = CGPointMake(snapX, next.y);
        }];
    }
}

- (void)handlePlayerAnchorPan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.view];
    [pan setTranslation:CGPointZero inView:self.view];
    self.playerPoint = [self clampPoint:CGPointMake(self.playerPoint.x + translation.x, self.playerPoint.y + translation.y)
                               toBounds:self.view.bounds
                                 margin:14.0];
    self.playerAnchorView.center = self.playerPoint;
    [self recalculateAndRedrawTrajectory];
}

- (void)handleEnemyAnchorPan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.view];
    [pan setTranslation:CGPointZero inView:self.view];
    self.enemyPoint = [self clampPoint:CGPointMake(self.enemyPoint.x + translation.x, self.enemyPoint.y + translation.y)
                              toBounds:self.view.bounds
                                margin:14.0];
    self.enemyAnchorView.center = self.enemyPoint;
    [self recalculateAndRedrawTrajectory];
}

- (void)handleControlBarPan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.view];
    [pan setTranslation:CGPointZero inView:self.view];
    CGPoint center = self.controlBarView.center;
    center.x += translation.x;
    center.y += translation.y;
    self.controlBarView.center = center;
    [self clampOverlayControlsToBounds];
}

- (void)handleWindButton:(UIButton *)sender {
    CGFloat delta = (CGFloat)sender.tag * 0.1;
    CGFloat raw = self.windValue + delta;
    CGFloat rounded = round(raw * 10.0) / 10.0;
    self.windValue = MIN(MAX(rounded, kGunnyMinWind), kGunnyMaxWind);
    [self refreshControlLabels];
    [self recalculateAndRedrawTrajectory];
}

- (void)handleResetWind {
    self.windValue = 0.0;
    [self refreshControlLabels];
    [self recalculateAndRedrawTrajectory];
}

- (void)handleAngleButton:(UIButton *)sender {
    CGFloat next = round(self.angleDeg + (CGFloat)sender.tag);
    self.angleDeg = MIN(MAX(next, kGunnyMinAngle), kGunnyMaxAngle);
    [self refreshControlLabels];
    [self recalculateAndRedrawTrajectory];
}

- (void)handleCycleAngle {
    static const CGFloat presets[] = {20.0, 30.0, 50.0, 65.0, 75.0};
    CGFloat next = 65.0;
    for (NSUInteger i = 0; i < 5; i++) {
        if (fabs(self.angleDeg - presets[i]) < 0.5) {
            next = presets[(i + 1) % 5];
            break;
        }
    }
    self.angleDeg = next;
    [self refreshControlLabels];
    [self recalculateAndRedrawTrajectory];
}

- (void)refreshControlLabels {
    NSString *sign = self.windValue > 0.01 ? @"+" : @"";
    self.windValueLabel.text = [NSString stringWithFormat:@"Gió %@%.1f", sign, self.windValue];
    self.angleValueLabel.text = [NSString stringWithFormat:@"%.0f°", self.angleDeg];
}

// MARK: - 2D Parabolic Physics & Trajectory Drawing

- (void)recalculateAndRedrawTrajectory {
    CGRect bounds = self.view.bounds;
    if (CGRectIsEmpty(bounds)) { return; }

    CGFloat screenSpan = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    if (screenSpan <= 1.0) { return; }

    // Quy đổi khoảng cách pixel trên trận đấu sang hệ vật lý (1 chiều ngang màn hình ~ 280 đơn vị).
    const CGFloat physicsScale = 280.0 / screenSpan;
    const CGFloat pixelsPerUnit = screenSpan / 280.0;
    const CGFloat gravity = 15.0;
    const CGFloat windAccelerationScale = 1.2;

    CGFloat dxPts = self.enemyPoint.x - self.playerPoint.x;
    CGFloat dyUpPts = self.playerPoint.y - self.enemyPoint.y; // Dương khi mục tiêu nằm cao hơn người chơi.
    CGFloat distancePts = fabs(dxPts);

    CGFloat distancePhys = distancePts * physicsScale;
    CGFloat elevationPhys = dyUpPts * physicsScale;

    if (distancePhys < 0.5 && fabs(elevationPhys) < 0.5) {
        self.calculatedPower = 0.0;
        self.trajectoryGlowLayer.path = nil;
        self.trajectoryLineLayer.path = nil;
        self.powerBadgeLabel.hidden = YES;
        return;
    }

    CGFloat safeAngle = MIN(MAX(self.angleDeg, kGunnyMinAngle), kGunnyMaxAngle);
    CGFloat theta = safeAngle * M_PI / 180.0;
    CGFloat sinTheta = sin(theta);
    CGFloat cosTheta = cos(theta);
    CGFloat shotSign = (dxPts >= 0.0) ? 1.0 : -1.0;

    // Gió theo hướng bắn (+ thuận gió, - ngược gió) dùng tính lực bắn.
    CGFloat directedWind = self.windValue * shotSign;
    CGFloat directedWindAccel = directedWind * windAccelerationScale;

    CGFloat numerator = 2.0 * (distancePhys * sinTheta - elevationPhys * cosTheta);
    CGFloat denominator = gravity * cosTheta + directedWindAccel * sinTheta;

    CGFloat power = 0.0;
    CGFloat flightTime = 0.0;
    CGFloat v0 = 0.0;
    BOOL validPhysicalCurve = NO;

    if (denominator > 0.001 && numerator > 0.0) {
        CGFloat tSquared = numerator / denominator;
        flightTime = sqrt(tSquared);
        if (flightTime > 0.001 && cosTheta > 0.001) {
            CGFloat rawV0 = (distancePhys - 0.5 * directedWindAccel * tSquared) / (flightTime * cosTheta);
            if (isfinite(rawV0) && rawV0 >= 0.0) {
                v0 = rawV0;
                power = MIN(MAX(rawV0, 0.0), 100.0);
                validPhysicalCurve = YES;
            }
        }
    }

    self.calculatedPower = power;

    [self.cachedCurvePoints removeAllObjects];
    UIBezierPath *curvePath = [UIBezierPath bezierPath];
    const NSInteger steps = 36;
    CGPoint apexPoint = self.playerPoint;

    if (validPhysicalCurve) {
        CGFloat vx0 = shotSign * v0 * cosTheta;
        CGFloat vy0 = v0 * sinTheta;
        CGFloat axGlobal = self.windValue * windAccelerationScale;

        self.cachedFlightTime = flightTime;
        self.cachedV0 = CGPointMake(vx0, vy0);
        self.cachedAx = axGlobal;
        self.cachedEffectiveGravity = gravity;
        self.cachedPixelsPerUnit = pixelsPerUnit;

        for (NSInteger i = 0; i <= steps; i++) {
            CGFloat u = (CGFloat)i / (CGFloat)steps;
            CGFloat t = u * flightTime;
            CGFloat pxPhys = vx0 * t + 0.5 * axGlobal * t * t;
            CGFloat pyPhys = vy0 * t - 0.5 * gravity * t * t;

            CGPoint pt = CGPointMake(
                self.playerPoint.x + pxPhys * pixelsPerUnit,
                self.playerPoint.y - pyPhys * pixelsPerUnit
            );
            [self.cachedCurvePoints addObject:[NSValue valueWithCGPoint:pt]];

            if (i == 0) {
                [curvePath moveToPoint:pt];
            } else {
                [curvePath addLineToPoint:pt];
            }

            if (pt.y < apexPoint.y) {
                apexPoint = pt;
            }
        }
    } else {
        // Fallback hình học nếu mục tiêu cao vượt quá tiệm cận góc bắn hiện tại.
        self.calculatedPower = (denominator <= 0.001) ? 100.0 : 0.0;
        self.cachedFlightTime = 0.0;
        CGPoint mid = CGPointMake(
            (self.playerPoint.x + self.enemyPoint.x) * 0.5,
            MIN(self.playerPoint.y, self.enemyPoint.y) - MAX(distancePts * 0.45, 40.0)
        );
        for (NSInteger i = 0; i <= steps; i++) {
            CGFloat u = (CGFloat)i / (CGFloat)steps;
            CGFloat inv = 1.0 - u;
            CGFloat x = inv * inv * self.playerPoint.x + 2.0 * inv * u * mid.x + u * u * self.enemyPoint.x;
            CGFloat y = inv * inv * self.playerPoint.y + 2.0 * inv * u * mid.y + u * u * self.enemyPoint.y;
            CGPoint pt = CGPointMake(x, y);
            [self.cachedCurvePoints addObject:[NSValue valueWithCGPoint:pt]];
            if (i == 0) {
                [curvePath moveToPoint:pt];
            } else {
                [curvePath addLineToPoint:pt];
            }
            if (pt.y < apexPoint.y) {
                apexPoint = pt;
            }
        }
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.trajectoryGlowLayer.path = curvePath.CGPath;
    self.trajectoryLineLayer.path = curvePath.CGPath;
    [CATransaction commit];

    // Hiển thị badge Lực bắn (0 - 100) ngay trên đỉnh đường kẻ parabol.
    NSTimeInterval holdSeconds = (self.calculatedPower / 100.0) * kGunnyFullChargeSeconds;
    self.powerBadgeLabel.hidden = NO;
    self.powerBadgeLabel.text = [NSString stringWithFormat:@" LỰC %.1f • %.2fs ", self.calculatedPower, holdSeconds];
    [self.powerBadgeLabel sizeToFit];

    CGFloat badgeW = CGRectGetWidth(self.powerBadgeLabel.bounds) + 12.0;
    CGFloat badgeH = 22.0;
    CGFloat badgeX = MIN(MAX(apexPoint.x, badgeW * 0.5 + 8.0), CGRectGetWidth(bounds) - badgeW * 0.5 - 8.0);
    CGFloat desiredY = apexPoint.y - 18.0;
    CGFloat minAllowedY = CGRectGetMaxY(self.controlBarView.frame) + badgeH * 0.5 + 6.0;
    CGFloat badgeY = MIN(MAX(desiredY, minAllowedY), CGRectGetHeight(bounds) - badgeH * 0.5 - 8.0);
    self.powerBadgeLabel.bounds = CGRectMake(0, 0, badgeW, badgeH);
    self.powerBadgeLabel.center = CGPointMake(badgeX, badgeY);
}

// MARK: - Passive Game Fire Hold Detection & Traveling Light Orb

- (void)attachFireObserverIfNeeded {
    UIWindowScene *scene = self.overlayWindow.windowScene;
    if (scene == nil) { return; }

    UIWindow *targetGameWindow = nil;
    for (UIWindow *win in scene.windows) {
        if (win != self.overlayWindow && !win.hidden) {
            targetGameWindow = win;
            break;
        }
    }
    if (targetGameWindow == nil) { return; }
    if (self.observedGameWindow == targetGameWindow && self.fireObserverGesture != nil) { return; }

    if (self.observedGameWindow != nil && self.fireObserverGesture != nil) {
        [self.observedGameWindow removeGestureRecognizer:self.fireObserverGesture];
    }

    GunnyFireHoldObserverGesture *observer = [[GunnyFireHoldObserverGesture alloc] init];
    observer.observerDelegate = self;
    [targetGameWindow addGestureRecognizer:observer];

    self.observedGameWindow = targetGameWindow;
    self.fireObserverGesture = observer;
}

- (BOOL)gunnyObserverShouldTrackTouchAtScreenPoint:(CGPoint)screenPoint {
    if (!self.aimingEnabled || self.cachedCurvePoints.count < 2) {
        return NO;
    }

    // Bỏ qua nếu chạm vào các control của chính thước ngắm.
    CGPoint ptInOverlayWindow = [self.overlayWindow convertPoint:screenPoint fromWindow:self.observedGameWindow];
    CGPoint ptInSelf = [self.view convertPoint:ptInOverlayWindow fromView:self.overlayWindow];
    if (CGRectContainsPoint(CGRectInset(self.toggleButton.frame, -8, -8), ptInSelf) ||
        CGRectContainsPoint(CGRectInset(self.controlBarView.frame, -6, -6), ptInSelf) ||
        CGRectContainsPoint(self.playerAnchorView.frame, ptInSelf) ||
        CGRectContainsPoint(self.enemyAnchorView.frame, ptInSelf)) {
        return NO;
    }

    // Nút Bắn của game nằm ở góc dưới bên phải màn hình.
    CGRect bounds = self.view.bounds;
    BOOL inFireButtonZone = (ptInSelf.x >= CGRectGetWidth(bounds) * 0.52) &&
                            (ptInSelf.y >= CGRectGetHeight(bounds) * 0.42);
    return inFireButtonZone;
}

- (void)gunnyObserverDidBeginFireHold {
    if (!self.aimingEnabled || self.calculatedPower <= 0.1) { return; }
    self.isHoldingFire = YES;
    self.holdStartTime = CACurrentMediaTime();

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.travelOrbGlowLayer.hidden = NO;
    self.travelOrbCoreLayer.hidden = NO;
    self.travelOrbGlowLayer.position = self.playerPoint;
    self.travelOrbCoreLayer.position = self.playerPoint;
    [CATransaction commit];

    [self startChargeDisplayLink];
}

- (void)gunnyObserverDidEndFireHold {
    self.isHoldingFire = NO;
    [self stopChargeDisplayLink];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.travelOrbGlowLayer.hidden = YES;
    self.travelOrbCoreLayer.hidden = YES;
    [CATransaction commit];
}

- (void)startChargeDisplayLink {
    [self stopChargeDisplayLink];
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleDisplayLinkTick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopChargeDisplayLink {
    if (self.displayLink != nil) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
}

- (void)handleDisplayLinkTick:(CADisplayLink *)link {
    (void)link;
    if (!self.isHoldingFire || !self.aimingEnabled) {
        [self gunnyObserverDidEndFireHold];
        return;
    }

    CFTimeInterval elapsed = CACurrentMediaTime() - self.holdStartTime;
    // Chu kỳ 2.20s = 100 lực (tự động đảo chiều hoặc giữ max theo thanh lực).
    CGFloat currentPower = MIN((elapsed / kGunnyFullChargeSeconds) * 100.0, 100.0);
    CGFloat targetPower = MAX(self.calculatedPower, 0.5);
    CGFloat progress = currentPower / targetPower; // progress == 1.0 đúng lúc chạm Tâm Đỏ.

    CGPoint orbPos = [self pointAlongTrajectoryForProgress:progress];
    BOOL nearTarget = fabs(progress - 1.0) <= 0.045;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.travelOrbGlowLayer.position = orbPos;
    self.travelOrbCoreLayer.position = orbPos;
    if (nearTarget) {
        self.travelOrbGlowLayer.fillColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.533 alpha:0.65].CGColor;
        self.travelOrbCoreLayer.fillColor = [UIColor colorWithRed:0.0 green:1.0 blue:0.533 alpha:1.0].CGColor;
    } else if (progress > 1.045) {
        self.travelOrbGlowLayer.fillColor = [UIColor colorWithRed:1.0 green:0.22 blue:0.22 alpha:0.55].CGColor;
        self.travelOrbCoreLayer.fillColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.45 alpha:1.0].CGColor;
    } else {
        self.travelOrbGlowLayer.fillColor = [UIColor colorWithRed:1.0 green:0.92 blue:0.25 alpha:0.42].CGColor;
        self.travelOrbCoreLayer.fillColor = [UIColor whiteColor].CGColor;
    }
    [CATransaction commit];
}

- (CGPoint)pointAlongTrajectoryForProgress:(CGFloat)progress {
    CGFloat clamped = MAX(progress, 0.0);

    if (self.cachedFlightTime > 0.001 && self.cachedPixelsPerUnit > 0.001) {
        CGFloat t = MIN(clamped, 1.35) * self.cachedFlightTime;
        CGFloat pxPhys = self.cachedV0.x * t + 0.5 * self.cachedAx * t * t;
        CGFloat pyPhys = self.cachedV0.y * t - 0.5 * self.cachedEffectiveGravity * t * t;
        return CGPointMake(
            self.playerPoint.x + pxPhys * self.cachedPixelsPerUnit,
            self.playerPoint.y - pyPhys * self.cachedPixelsPerUnit
        );
    }

    NSUInteger count = self.cachedCurvePoints.count;
    if (count == 0) { return self.playerPoint; }
    if (count == 1) { return self.cachedCurvePoints[0].CGPointValue; }

    CGFloat u = MIN(clamped, 1.0);
    CGFloat exactIndex = u * (CGFloat)(count - 1);
    NSUInteger idx0 = (NSUInteger)floor(exactIndex);
    NSUInteger idx1 = MIN(idx0 + 1, count - 1);
    CGFloat frac = exactIndex - (CGFloat)idx0;

    CGPoint p0 = self.cachedCurvePoints[idx0].CGPointValue;
    CGPoint p1 = self.cachedCurvePoints[idx1].CGPointValue;
    return CGPointMake(p0.x + (p1.x - p0.x) * frac, p0.y + (p1.y - p0.y) * frac);
}

@end

// MARK: - Singleton Bootstrap & __attribute__((constructor))

static GunnyPassThroughWindow *sOverlayWindow = nil;
static GunnyInGameOverlayController *sOverlayController = nil;

static UIWindowScene *GunnyFindActiveWindowScene(void) {
    NSSet<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes;
    UIWindowScene *fallback = nil;
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
        UIWindowScene *winScene = (UIWindowScene *)scene;
        if (winScene.activationState == UISceneActivationStateForegroundActive) {
            return winScene;
        }
        if (fallback == nil) {
            fallback = winScene;
        }
    }
    return fallback;
}

static void GunnyAttachOverlayWindowIfReady(void) {
    if (sOverlayWindow != nil) { return; }

    UIWindowScene *scene = GunnyFindActiveWindowScene();
    if (scene == nil) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GunnyAttachOverlayWindowIfReady();
        });
        return;
    }

    GunnyInGameOverlayController *vc = [[GunnyInGameOverlayController alloc] init];
    GunnyPassThroughWindow *window = [[GunnyPassThroughWindow alloc] initWithWindowScene:scene];
    window.backgroundColor = [UIColor clearColor];
    window.opaque = NO;
    window.windowLevel = UIWindowLevelStatusBar + 60.0;
    window.rootViewController = vc;
    window.hidden = NO;

    vc.overlayWindow = window;
    sOverlayController = vc;
    sOverlayWindow = window;
}

__attribute__((constructor))
static void GunnyInGameLineConstructor(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        GunnyAttachOverlayWindowIfReady();
    });
}
