// XPPanel.m — 新版浮窗视图层（纯代码 UIKit，无图片资源）
#import "XPPanel.h"
#import "XPTheme.h"

UIColor *XPColor(UInt8 r, UInt8 g, UInt8 b, CGFloat a) {
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}


#pragma mark - 兼容封装

static UIBlurEffect *XPBlurEffect(void) {
    if (@available(iOS 13.0, *)) {
        return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
}

static UIImage *XPSystemIcon(NSString *name) {
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:name];
    }
    return nil;
}

static void XPSetCornerCurve(UIView *v) {
    if (@available(iOS 13.0, *)) {
        XPSetCornerCurve(v);
    }
}

#pragma mark - 通用小工具

static UILabel *XPText(CGFloat size, UIFontWeight w, UIColor *color) {
    UILabel *l = [UILabel new];
    l.font = XPFont(size, w);
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

static UILabel *XPMonoText(CGFloat size, UIFontWeight w, UIColor *color) {
    UILabel *l = XPText(size, w, color);
    l.font = XPMono(size, w);
    return l;
}

static void XPCall(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return;
    IMP imp = [obj methodForSelector:sel];
    ((void (*)(id, SEL))imp)(obj, sel);
}

static id XPGet(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}


static NSString *XPStr(id obj, NSString *key) {
    id v = XPGet(obj, key);
    if ([v isKindOfClass:[UILabel class]]) return [(UILabel *)v text] ?: @"";
    if ([v isKindOfClass:[NSString class]]) return v;
    return @"";
}

/// 状态色：正常=青玉，需要注意=暖沙，未知=灰
static UIColor *XPStateColor(NSString *text) {
    if (!text.length) return XPFaint;
    if ([text containsString:@"已接收"] || [text containsString:@"已连接"] ||
        [text containsString:@"已送出"] || [text containsString:@"稳定"]) return XPJade;
    if ([text containsString:@"等待"] || [text containsString:@"未"] ||
        [text containsString:@"受限"] || [text containsString:@"需"] ||
        [text containsString:@"中断"] || [text containsString:@"异"]) return XPSand;
    return XPFaint;
}

#pragma mark - 胶囊标签

@interface XPChip : UIView
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIView *dot;
- (void)setText:(NSString *)text color:(UIColor *)color;
@end

@implementation XPChip

- (instancetype)init {
    if ((self = [super init])) {
        self.layer.cornerRadius = 7;
        XPSetCornerCurve(self);
        self.backgroundColor = XPChipBG;
        _dot = [UIView new];
        _dot.layer.cornerRadius = 2.5;
        [self addSubview:_dot];
        _label = XPText(XPFmicro, UIFontWeightSemibold, XPBody);
        [self addSubview:_label];
        _dot.translatesAutoresizingMaskIntoConstraints = NO;
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [_dot.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6],
            [_dot.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_dot.widthAnchor constraintEqualToConstant:5],
            [_dot.heightAnchor constraintEqualToConstant:5],
            [_label.leadingAnchor constraintEqualToAnchor:_dot.trailingAnchor constant:4],
            [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-7],
            [_label.topAnchor constraintEqualToAnchor:self.topAnchor constant:3],
            [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-3],
        ]];
    }
    return self;
}

- (void)setText:(NSString *)text color:(UIColor *)color {
    self.label.text = text ?: @"";
    self.dot.backgroundColor = color;
}

@end

#pragma mark - 分段控件（2/3 等分）

@interface XPSeg : UIView
@property (nonatomic, copy) void (^onSelect)(NSInteger index);
@property (nonatomic, assign) NSInteger selected;
@property (nonatomic, strong) NSMutableArray<UIButton *> *buttons;
- (instancetype)initWithTitles:(NSArray<NSString *> *)titles;
@end

@implementation XPSeg

- (instancetype)initWithTitles:(NSArray<NSString *> *)titles {
    if ((self = [super init])) {
        self.backgroundColor = XPCardBG;
        self.layer.cornerRadius = XPRadiusControl;
        _buttons = [NSMutableArray array];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[]];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.distribution = UIStackViewDistributionFillEqually;
        stack.spacing = 4;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:3],
            [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-3],
            [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:3],
            [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-3],
        ]];
        [titles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger idx, BOOL *stop) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            [b setTitle:title forState:UIControlStateNormal];
            b.titleLabel.font = XPFont(XPFbody, UIFontWeightSemibold);
            b.layer.cornerRadius = 8;
            b.tag = (NSInteger)idx;
            [b addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
            [stack addArrangedSubview:b];
            [self.buttons addObject:b];
            [b.heightAnchor constraintEqualToConstant:27].active = YES;
        }];
        [self setSelected:0];
    }
    return self;
}

- (void)tap:(UIButton *)b {
    NSInteger idx = b.tag;
    if (idx == _selected) return;
    [self setSelected:idx];
    if (self.onSelect) self.onSelect(idx);
}

- (void)setSelected:(NSInteger)selected {
    _selected = selected;
    [self.buttons enumerateObjectsUsingBlock:^(UIButton *b, NSUInteger idx, BOOL *stop) {
        BOOL on = (NSInteger)idx == selected;
        b.backgroundColor = on ? XPJadeSoft : [UIColor clearColor];
        [b setTitleColor:on ? XPJade : XPBody forState:UIControlStateNormal];
    }];
}

@end

#pragma mark - 电平条

@interface XPMeter : UIView
@property (nonatomic, strong) NSMutableArray<UIView *> *bars;
@property (nonatomic, assign) CGFloat level;   // 0~1
@end

@implementation XPMeter

- (instancetype)init {
    if ((self = [super init])) {
        _bars = [NSMutableArray array];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[]];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.distribution = UIStackViewDistributionFillEqually;
        stack.spacing = 2.5;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:self.topAnchor],
            [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];
        for (int i = 0; i < 16; i++) {
            UIView *bar = [UIView new];
            bar.backgroundColor = XPHairline;
            bar.layer.cornerRadius = 1.5;
            [stack addArrangedSubview:bar];
            [bar.heightAnchor constraintEqualToConstant:16].active = YES;
            [_bars addObject:bar];
        }
    }
    return self;
}

- (void)setLevel:(CGFloat)level {
    _level = MAX(0, MIN(1, level));
    NSUInteger lit = (NSUInteger)lround(_level * 16);
    [self.bars enumerateObjectsUsingBlock:^(UIView *bar, NSUInteger idx, BOOL *stop) {
        if (idx < lit) {
            bar.backgroundColor = idx > 12 ? XPWarn : XPJade;
        } else {
            bar.backgroundColor = XPHairline;
        }
    }];
}

@end

#pragma mark - 面板

@interface XPPanel ()
// 外壳
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UIView *grip;
// 头部
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *verLabel;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, strong) UIView *statusDot;
@property (nonatomic, strong) UIButton *licenseBtn;
@property (nonatomic, strong) UIButton *collapseBtn;
// 状态
@property (nonatomic, strong) UILabel *statusTitle;
@property (nonatomic, strong) UILabel *statusValue;
@property (nonatomic, strong) UIStackView *chipRow;
@property (nonatomic, strong) XPChip *chipSource;
@property (nonatomic, strong) XPChip *chipRecord;
@property (nonatomic, strong) XPChip *chipLink;
// 画面替换
@property (nonatomic, strong) UISwitch *blendSwitch;
@property (nonatomic, strong) UISlider *blendSlider;
@property (nonatomic, strong) UILabel *blendLeft;
@property (nonatomic, strong) UILabel *blendRight;
// 页签
@property (nonatomic, strong) UIButton *tabVideo;
@property (nonatomic, strong) UIButton *tabAudio;
// 画面页
@property (nonatomic, strong) UIView *videoPane;
@property (nonatomic, strong) XPSeg *sourceSeg;
@property (nonatomic, strong) UIView *localPane;
@property (nonatomic, strong) UILabel *localFile;
@property (nonatomic, strong) UIProgressView *localProgress;
@property (nonatomic, strong) UILabel *localTime;
@property (nonatomic, strong) UIButton *selectBtn;
@property (nonatomic, strong) XPSeg *displaySeg;
@property (nonatomic, strong) UISwitch *loopSwitch;
// 声音页
@property (nonatomic, strong) UIView *audioPane;
@property (nonatomic, strong) UISwitch *recordSwitch;
@property (nonatomic, strong) XPMeter *meter;
@property (nonatomic, strong) UILabel *materialTitle;
@property (nonatomic, strong) UILabel *materialSub;
@property (nonatomic, strong) UILabel *sendTitle;
@property (nonatomic, strong) UILabel *sendSub;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UILabel *warnLabel;
// 诊断 / 底部
@property (nonatomic, strong) UIButton *diagBtn;
@property (nonatomic, strong) UIView *diagBox;
@property (nonatomic, strong) UILabel *diagLog;
@property (nonatomic, strong) UIView *footer;
// 授权页 / 更多页
@property (nonatomic, strong) UIView *licensePage;
@property (nonatomic, strong) UILabel *licTitle;
@property (nonatomic, strong) UILabel *licSub;
@property (nonatomic, strong) UITextField *licField;
@property (nonatomic, strong) UIButton *licSubmit;
@property (nonatomic, strong) UILabel *licMsg;
@property (nonatomic, strong) UIView *morePage;
// 收起态
@property (nonatomic, strong) UIView *pill;
@property (nonatomic, strong) UILabel *pillText;
@property (nonatomic, assign) BOOL collapsed;
@property (nonatomic, strong) NSLayoutConstraint *widthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *heightFit;
@property (nonatomic, strong) NSLayoutConstraint *heightCap;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *expandedCons;
@property (nonatomic, copy) NSArray<NSLayoutConstraint *> *collapsedCons;
@end

@implementation XPPanel

#pragma mark 构建

- (instancetype)initWithController:(id)controller width:(CGFloat)width {
    if ((self = [super initWithFrame:CGRectZero])) {
        _controller = controller;
        [self buildChromeWithWidth:width];
        [self refresh];
    }
    return self;
}

- (UIView *)cardBlock {
    UIView *v = [UIView new];
    v.backgroundColor = XPCardBG;
    v.layer.cornerRadius = XPRadiusCard;
    XPSetCornerCurve(v);
    return v;
}

- (void)buildChromeWithWidth:(CGFloat)width {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    // 外壳
    _card = [UIView new];
    _card.layer.cornerRadius = XPRadiusPanel;
    XPSetCornerCurve(_card);
    _card.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    _card.layer.borderColor = XPBorder.CGColor;
    _card.clipsToBounds = YES;
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_card];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:XPBlurEffect()];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    blur.userInteractionEnabled = NO;
    [_card addSubview:blur];

    _expandedCons = @[
        [_card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_card.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ];
    [NSLayoutConstraint activateConstraints:_expandedCons];
    [NSLayoutConstraint activateConstraints:@[
        (_widthConstraint = [_card.widthAnchor constraintEqualToConstant:width]),
        [blur.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor],
        [blur.topAnchor constraintEqualToAnchor:_card.topAnchor],
        [blur.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor],
    ]];

    _scroll = [UIScrollView new];
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [_card addSubview:_scroll];
    [NSLayoutConstraint activateConstraints:@[
        [_scroll.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor],
        [_scroll.topAnchor constraintEqualToAnchor:_card.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor],
    ]];

    _stack = [[UIStackView alloc] initWithArrangedSubviews:@[]];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = XPGapBlock;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:_stack];
    NSMutableArray<NSLayoutConstraint *> *stackCons = [NSMutableArray array];
    if (@available(iOS 11.0, *)) {
        UILayoutGuide *content = _scroll.contentLayoutGuide;
        UILayoutGuide *frame = _scroll.frameLayoutGuide;
        [stackCons addObject:[_stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:XPPadH]];
        [stackCons addObject:[_stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:8]];
        [stackCons addObject:[_stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-XPPadB]];
        [stackCons addObject:[_stack.widthAnchor constraintEqualToAnchor:frame.widthAnchor constant:-XPPadH * 2]];
        [stackCons addObject:[_stack.centerXAnchor constraintEqualToAnchor:frame.centerXAnchor]];
    } else {
        [stackCons addObject:[_stack.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor constant:XPPadH]];
        [stackCons addObject:[_stack.topAnchor constraintEqualToAnchor:_scroll.topAnchor constant:8]];
        [stackCons addObject:[_stack.bottomAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:-XPPadB]];
        [stackCons addObject:[_stack.widthAnchor constraintEqualToAnchor:_scroll.widthAnchor constant:-XPPadH * 2]];
    }
    [NSLayoutConstraint activateConstraints:stackCons];
    // 内容不高时面板贴合内容；内容超高时停在上限、内部滚动
    _heightFit = [_scroll.heightAnchor constraintEqualToAnchor:_stack.heightAnchor constant:8 + XPPadB];
    _heightFit.priority = 999;
    _heightCap = [_scroll.heightAnchor constraintLessThanOrEqualToConstant:600];
    _heightCap.priority = UILayoutPriorityRequired;
    [NSLayoutConstraint activateConstraints:@[_heightFit, _heightCap]];

    // 抓手
    _grip = [UIView new];
    _grip.backgroundColor = XPColor(255, 255, 255, 0.16);
    _grip.layer.cornerRadius = 1.5;
    _grip.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *gripWrap = [UIView new];
    [gripWrap addSubview:_grip];
    [NSLayoutConstraint activateConstraints:@[
        [_grip.widthAnchor constraintEqualToConstant:34],
        [_grip.heightAnchor constraintEqualToConstant:3],
        [_grip.centerXAnchor constraintEqualToAnchor:gripWrap.centerXAnchor],
        [_grip.topAnchor constraintEqualToAnchor:gripWrap.topAnchor],
        [_grip.bottomAnchor constraintEqualToAnchor:gripWrap.bottomAnchor],
        [gripWrap.heightAnchor constraintEqualToConstant:6],
    ]];
    [_stack addArrangedSubview:gripWrap];

    // 头部
    [_stack addArrangedSubview:[self buildHeader]];

    // 状态区
    [_stack addArrangedSubview:[self buildStatus]];

    // 画面替换
    [_stack addArrangedSubview:[self buildBlend]];

    // 页签
    [_stack addArrangedSubview:[self buildTabs]];

    // 画面页 / 声音页
    _videoPane = [self buildVideoPane];
    _audioPane = [self buildAudioPane];
    [_stack addArrangedSubview:_videoPane];
    [_stack addArrangedSubview:_audioPane];
    _audioPane.hidden = YES;

    // 授权页 / 更多页
    _licensePage = [self buildLicensePage];
    _morePage = [self buildMorePage];
    [_stack addArrangedSubview:_licensePage];
    [_stack addArrangedSubview:_morePage];
    _licensePage.hidden = YES;
    _morePage.hidden = YES;

    // 诊断 + 底部
    [_stack addArrangedSubview:[self buildDiagnostics]];
    [_stack addArrangedSubview:[self buildFooter]];

    // 收起态胶囊
    [self buildPill];
}

- (UIView *)buildHeader {
    UIView *box = [UIView new];

    UIView *logo = [UIView new];
    logo.backgroundColor = XPJadeSoft;
    logo.layer.cornerRadius = 11;
    XPSetCornerCurve(logo);
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *glyph = XPText(15, UIFontWeightBold, XPJade);
    glyph.text = @"潘";
    glyph.textAlignment = NSTextAlignmentCenter;
    glyph.translatesAutoresizingMaskIntoConstraints = NO;
    [logo addSubview:glyph];
    [NSLayoutConstraint activateConstraints:@[
        [logo.widthAnchor constraintEqualToConstant:40],
        [logo.heightAnchor constraintEqualToConstant:40],
        [glyph.centerXAnchor constraintEqualToAnchor:logo.centerXAnchor],
        [glyph.centerYAnchor constraintEqualToAnchor:logo.centerYAnchor],
    ]];

    _nameLabel = XPText(XPFName, UIFontWeightBold, XPInk);
    _nameLabel.text = @"小潘";
    _verLabel = XPMonoText(XPFVer, UIFontWeightMedium, XPFaint);
    _verLabel.text = @"v1.6.30";

    UIStackView *titleRow = [[UIStackView alloc] initWithArrangedSubviews:@[_nameLabel, _verLabel]];
    titleRow.axis = UILayoutConstraintAxisHorizontal;
    titleRow.alignment = UIStackViewAlignmentLastBaseline;
    titleRow.spacing = 5;

    _subLabel = XPText(XPFSub, UIFontWeightMedium, XPMuted);
    _subLabel.text = @"已激活 · 永久授权";

    _statusDot = [UIView new];
    _statusDot.backgroundColor = XPJade;
    _statusDot.layer.cornerRadius = 2.5;
    _statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusDot.widthAnchor constraintEqualToConstant:5].active = YES;
    [_statusDot.heightAnchor constraintEqualToConstant:5].active = YES;

    UIStackView *subRow = [[UIStackView alloc] initWithArrangedSubviews:@[_statusDot, _subLabel]];
    subRow.axis = UILayoutConstraintAxisHorizontal;
    subRow.alignment = UIStackViewAlignmentCenter;
    subRow.spacing = 5;

    UIStackView *textCol = [[UIStackView alloc] initWithArrangedSubviews:@[titleRow, subRow]];
    textCol.axis = UILayoutConstraintAxisVertical;
    textCol.alignment = UIStackViewAlignmentLeading;
    textCol.spacing = 3;

    _licenseBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [_licenseBtn setTitle:@"授权" forState:UIControlStateNormal];
    [_licenseBtn setTitleColor:XPJade forState:UIControlStateNormal];
    _licenseBtn.titleLabel.font = XPFont(XPFbody, UIFontWeightSemibold);
    _licenseBtn.backgroundColor = XPJadeSoft;
    _licenseBtn.layer.cornerRadius = 13;
    _licenseBtn.contentEdgeInsets = UIEdgeInsetsMake(6, 11, 6, 11);
    [_licenseBtn addTarget:self action:@selector(tapLicense) forControlEvents:UIControlEventTouchUpInside];

    _collapseBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [_collapseBtn setImage:XPSystemIcon(@"chevron.up") forState:UIControlStateNormal];
    _collapseBtn.tintColor = XPMuted;
    _collapseBtn.backgroundColor = XPCardBG;
    _collapseBtn.layer.cornerRadius = 8;
    _collapseBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_collapseBtn.widthAnchor constraintEqualToConstant:28].active = YES;
    [_collapseBtn.heightAnchor constraintEqualToConstant:28].active = YES;
    [_collapseBtn addTarget:self action:@selector(tapCollapse) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[logo, textCol, _licenseBtn, _collapseBtn]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 9;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:2],
        [row.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-2],
        [row.topAnchor constraintEqualToAnchor:box.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
    ]];
    return box;
}

- (UIView *)buildStatus {
    UIView *box = [self cardBlock];
    box.layoutMargins = UIEdgeInsetsMake(9, 11, 9, 11);

    _statusTitle = XPText(XPFBlock, UIFontWeightSemibold, XPInk);
    _statusValue = XPMonoText(XPFmicro, UIFontWeightMedium, XPMuted);
    _statusValue.textAlignment = NSTextAlignmentRight;

    UIStackView *main = [[UIStackView alloc] initWithArrangedSubviews:@[_statusTitle, _statusValue]];
    main.axis = UILayoutConstraintAxisHorizontal;
    main.alignment = UIStackViewAlignmentCenter;
    main.spacing = 8;

    _chipSource = [XPChip new];
    _chipRecord = [XPChip new];
    _chipLink = [XPChip new];
    _chipRow = [[UIStackView alloc] initWithArrangedSubviews:@[_chipSource, _chipRecord, _chipLink]];
    _chipRow.axis = UILayoutConstraintAxisHorizontal;
    _chipRow.spacing = 5;

    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[main, _chipRow]];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 7;
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:col];
    [NSLayoutConstraint activateConstraints:@[
        [col.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:11],
        [col.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-11],
        [col.topAnchor constraintEqualToAnchor:box.topAnchor constant:9],
        [col.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-9],
    ]];
    return box;
}

- (UIView *)buildBlend {
    UIView *box = [self cardBlock];

    UILabel *title = XPText(XPFBlock, UIFontWeightSemibold, XPInk);
    title.text = @"画面替换";

    _blendSwitch = [UISwitch new];
    _blendSwitch.onTintColor = XPJade;
    _blendSwitch.transform = CGAffineTransformMakeScale(0.82, 0.82);
    [_blendSwitch addTarget:self action:@selector(tapBlend) forControlEvents:UIControlEventValueChanged];

    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[title, _blendSwitch]];
    head.axis = UILayoutConstraintAxisHorizontal;
    head.alignment = UIStackViewAlignmentCenter;

    _blendLeft = XPMonoText(XPFmicro, UIFontWeightMedium, XPMuted);
    _blendLeft.text = @"OBS 0%";
    _blendRight = XPMonoText(XPFmicro, UIFontWeightMedium, XPMuted);
    _blendRight.text = @"现场 100%";
    _blendRight.textAlignment = NSTextAlignmentRight;

    _blendSlider = [UISlider new];
    _blendSlider.minimumValue = 0;
    _blendSlider.maximumValue = 1;
    _blendSlider.minimumTrackTintColor = XPJade;
    _blendSlider.maximumTrackTintColor = XPHairline;
    [_blendSlider addTarget:self action:@selector(changeBlend) forControlEvents:UIControlEventValueChanged];

    UIStackView *range = [[UIStackView alloc] initWithArrangedSubviews:@[_blendLeft, _blendRight]];
    range.axis = UILayoutConstraintAxisHorizontal;
    range.distribution = UIStackViewDistributionFillEqually;

    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[head, _blendSlider, range]];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 6;
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:col];
    [NSLayoutConstraint activateConstraints:@[
        [col.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:11],
        [col.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-11],
        [col.topAnchor constraintEqualToAnchor:box.topAnchor constant:9],
        [col.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-9],
    ]];
    return box;
}

- (UIView *)buildTabs {
    UIView *box = [self cardBlock];
    _tabVideo = [self tabButton:@"画面" tag:0];
    _tabAudio = [self tabButton:@"声音" tag:1];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_tabVideo, _tabAudio]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 4;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:3],
        [row.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-3],
        [row.topAnchor constraintEqualToAnchor:box.topAnchor constant:3],
        [row.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-3],
    ]];
    [self selectTab:0];
    return box;
}

- (UIButton *)tabButton:(NSString *)title tag:(NSInteger)tag {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = XPFont(XPFbody, UIFontWeightSemibold);
    b.layer.cornerRadius = 8;
    b.tag = tag;
    [b.heightAnchor constraintEqualToConstant:30].active = YES;
    [b addTarget:self action:@selector(tapTab:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIView *)buildVideoPane {
    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[]];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = XPGapBlock;

    // 来源
    UIView *src = [self cardBlock];
    UILabel *t = XPText(XPFBlock, UIFontWeightSemibold, XPInk);
    t.text = @"视频来源";
    _sourceSeg = [[XPSeg alloc] initWithTitles:@[@"局域网", @"直连", @"本地视频"]];
    __weak typeof(self) ws1 = self;
    _sourceSeg.onSelect = ^(NSInteger idx) { [ws1 selectSource:idx]; };
    UIStackView *sc = [[UIStackView alloc] initWithArrangedSubviews:@[t, _sourceSeg]];
    sc.axis = UILayoutConstraintAxisVertical;
    sc.spacing = 8;
    sc.translatesAutoresizingMaskIntoConstraints = NO;
    [src addSubview:sc];
    [NSLayoutConstraint activateConstraints:@[
        [sc.leadingAnchor constraintEqualToAnchor:src.leadingAnchor constant:9],
        [sc.trailingAnchor constraintEqualToAnchor:src.trailingAnchor constant:-9],
        [sc.topAnchor constraintEqualToAnchor:src.topAnchor constant:9],
        [sc.bottomAnchor constraintEqualToAnchor:src.bottomAnchor constant:-9],
    ]];
    [col addArrangedSubview:src];

    // 本地视频
    _localPane = [self cardBlock];
    _localFile = XPText(XPFrowT, UIFontWeightSemibold, XPInk);
    _localFile.text = @"未选择视频";
    _localTime = XPMonoText(XPFmicro, UIFontWeightMedium, XPMuted);
    _localTime.text = @"00:00 / 00:00";
    _localProgress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _localProgress.progressTintColor = XPJade;
    _localProgress.trackTintColor = XPHairline;

    _selectBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [_selectBtn setTitle:@"选择视频" forState:UIControlStateNormal];
    [_selectBtn setTitleColor:XPJadeInk forState:UIControlStateNormal];
    _selectBtn.titleLabel.font = XPFont(XPFbody, UIFontWeightSemibold);
    _selectBtn.backgroundColor = XPJade;
    _selectBtn.layer.cornerRadius = 10;
    [_selectBtn.heightAnchor constraintEqualToConstant:34].active = YES;
    [_selectBtn addTarget:self action:@selector(tapSelectVideo) forControlEvents:UIControlEventTouchUpInside];

    _displaySeg = [[XPSeg alloc] initWithTitles:@[@"完整显示", @"铺满画面"]];
    __weak typeof(self) ws2 = self;
    _displaySeg.onSelect = ^(NSInteger idx) { [ws2 selectDisplay:idx]; };

    _loopSwitch = [UISwitch new];
    _loopSwitch.onTintColor = XPJade;
    _loopSwitch.transform = CGAffineTransformMakeScale(0.82, 0.82);
    [_loopSwitch addTarget:self action:@selector(tapLoop) forControlEvents:UIControlEventValueChanged];
    UILabel *loopLabel = XPText(XPFrowT, UIFontWeightSemibold, XPBody);
    loopLabel.text = @"循环播放";
    UIView *spacer = [UIView new];
    UIStackView *loopRow = [[UIStackView alloc] initWithArrangedSubviews:@[loopLabel, spacer, _loopSwitch]];
    loopRow.axis = UILayoutConstraintAxisHorizontal;
    loopRow.alignment = UIStackViewAlignmentCenter;
    loopRow.spacing = 8;

    UIStackView *lc = [[UIStackView alloc] initWithArrangedSubviews:
                       @[_localFile, _localProgress, _localTime, _selectBtn, _displaySeg, loopRow]];
    lc.axis = UILayoutConstraintAxisVertical;
    lc.spacing = 7;
    lc.translatesAutoresizingMaskIntoConstraints = NO;
    [_localPane addSubview:lc];
    [NSLayoutConstraint activateConstraints:@[
        [lc.leadingAnchor constraintEqualToAnchor:_localPane.leadingAnchor constant:9],
        [lc.trailingAnchor constraintEqualToAnchor:_localPane.trailingAnchor constant:-9],
        [lc.topAnchor constraintEqualToAnchor:_localPane.topAnchor constant:9],
        [lc.bottomAnchor constraintEqualToAnchor:_localPane.bottomAnchor constant:-9],
    ]];
    [col addArrangedSubview:_localPane];
    return col;
}

- (UIView *)buildAudioPane {
    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[]];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = XPGapBlock;

    // 内录
    UIView *rec = [self cardBlock];
    UILabel *rt = XPText(XPFBlock, UIFontWeightSemibold, XPInk);
    rt.text = @"内录";
    UILabel *rs = XPText(XPFnote, UIFontWeightRegular, XPFaint);
    rs.text = @"关闭时默认从手机外放";
    _recordSwitch = [UISwitch new];
    _recordSwitch.onTintColor = XPJade;
    _recordSwitch.transform = CGAffineTransformMakeScale(0.82, 0.82);
    [_recordSwitch addTarget:self action:@selector(tapRecord) forControlEvents:UIControlEventValueChanged];

    UIStackView *textCol = [[UIStackView alloc] initWithArrangedSubviews:@[rt, rs]];
    textCol.axis = UILayoutConstraintAxisVertical;
    textCol.spacing = 2;
    UIView *sp = [UIView new];
    UIStackView *rr = [[UIStackView alloc] initWithArrangedSubviews:@[textCol, sp, _recordSwitch]];
    rr.axis = UILayoutConstraintAxisHorizontal;
    rr.alignment = UIStackViewAlignmentCenter;
    rr.translatesAutoresizingMaskIntoConstraints = NO;
    [rec addSubview:rr];
    [NSLayoutConstraint activateConstraints:@[
        [rr.leadingAnchor constraintEqualToAnchor:rec.leadingAnchor constant:11],
        [rr.trailingAnchor constraintEqualToAnchor:rec.trailingAnchor constant:-11],
        [rr.topAnchor constraintEqualToAnchor:rec.topAnchor constant:9],
        [rr.bottomAnchor constraintEqualToAnchor:rec.bottomAnchor constant:-9],
    ]];
    [col addArrangedSubview:rec];

    // 素材声音
    UIView *mat = [self cardBlock];
    _materialTitle = XPText(XPFrowT, UIFontWeightSemibold, XPInk);
    _materialTitle.text = @"素材声音";
    _materialSub = XPText(XPFnote, UIFontWeightRegular, XPFaint);
    _materialSub.text = @"音轨已连接，当前无声";
    _meter = [XPMeter new];
    UIStackView *mc = [[UIStackView alloc] initWithArrangedSubviews:@[_materialTitle, _materialSub, _meter]];
    mc.axis = UILayoutConstraintAxisVertical;
    mc.spacing = 5;
    mc.translatesAutoresizingMaskIntoConstraints = NO;
    [mat addSubview:mc];
    [NSLayoutConstraint activateConstraints:@[
        [mc.leadingAnchor constraintEqualToAnchor:mat.leadingAnchor constant:11],
        [mc.trailingAnchor constraintEqualToAnchor:mat.trailingAnchor constant:-11],
        [mc.topAnchor constraintEqualToAnchor:mat.topAnchor constant:9],
        [mc.bottomAnchor constraintEqualToAnchor:mat.bottomAnchor constant:-9],
    ]];
    [col addArrangedSubview:mat];

    // 直播送出
    UIView *send = [self cardBlock];
    _sendTitle = XPText(XPFrowT, UIFontWeightSemibold, XPInk);
    _sendTitle.text = @"直播送出";
    _sendSub = XPText(XPFnote, UIFontWeightRegular, XPFaint);
    _sendSub.text = @"插件尚未接管收音";
    UIStackView *sc = [[UIStackView alloc] initWithArrangedSubviews:@[_sendTitle, _sendSub]];
    sc.axis = UILayoutConstraintAxisVertical;
    sc.spacing = 3;
    sc.translatesAutoresizingMaskIntoConstraints = NO;
    [send addSubview:sc];
    [NSLayoutConstraint activateConstraints:@[
        [sc.leadingAnchor constraintEqualToAnchor:send.leadingAnchor constant:11],
        [sc.trailingAnchor constraintEqualToAnchor:send.trailingAnchor constant:-11],
        [sc.topAnchor constraintEqualToAnchor:send.topAnchor constant:9],
        [sc.bottomAnchor constraintEqualToAnchor:send.bottomAnchor constant:-9],
    ]];
    [col addArrangedSubview:send];

    _hintLabel = XPText(XPFnote, UIFontWeightRegular, XPMuted);
    _warnLabel = XPText(XPFnote, UIFontWeightMedium, XPSand);
    [col addArrangedSubview:_hintLabel];
    [col addArrangedSubview:_warnLabel];
    return col;
}

- (UIView *)buildDiagnostics {
    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[]];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 6;

    _diagBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    [_diagBtn setTitle:@"查看运行诊断日志" forState:UIControlStateNormal];
    [_diagBtn setTitleColor:XPBody forState:UIControlStateNormal];
    _diagBtn.titleLabel.font = XPFont(XPFaux, UIFontWeightMedium);
    _diagBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    _diagBtn.backgroundColor = XPCardBG;
    _diagBtn.layer.cornerRadius = XPRadiusControl;
    _diagBtn.contentEdgeInsets = UIEdgeInsetsMake(9, 11, 9, 11);
    [_diagBtn addTarget:self action:@selector(tapDiag) forControlEvents:UIControlEventTouchUpInside];

    _diagBox = [self cardBlock];
    _diagLog = XPMonoText(XPFnote, UIFontWeightRegular, XPMuted);
    _diagLog.text = @"暂无数据";
    _diagLog.translatesAutoresizingMaskIntoConstraints = NO;
    [_diagBox addSubview:_diagLog];
    [NSLayoutConstraint activateConstraints:@[
        [_diagLog.leadingAnchor constraintEqualToAnchor:_diagBox.leadingAnchor constant:10],
        [_diagLog.trailingAnchor constraintEqualToAnchor:_diagBox.trailingAnchor constant:-10],
        [_diagLog.topAnchor constraintEqualToAnchor:_diagBox.topAnchor constant:8],
        [_diagLog.bottomAnchor constraintEqualToAnchor:_diagBox.bottomAnchor constant:-8],
    ]];
    _diagBox.hidden = YES;

    [col addArrangedSubview:_diagBtn];
    [col addArrangedSubview:_diagBox];
    return col;
}

- (UIView *)buildFooter {
    _footer = [UIView new];
    UIButton *more = [self linkButton:@"更多设置" action:@selector(tapMore)];
    UIButton *risk = [self linkButton:@"风险说明" action:@selector(tapRisk)];
    UIButton *close = [self linkButton:@"收起" action:@selector(tapCollapse)];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[more, risk, close]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [_footer addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:_footer.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:_footer.trailingAnchor],
        [row.topAnchor constraintEqualToAnchor:_footer.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:_footer.bottomAnchor],
    ]];
    return _footer;
}

- (UIButton *)linkButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:XPMuted forState:UIControlStateNormal];
    b.titleLabel.font = XPFont(XPFaux, UIFontWeightMedium);
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIView *)buildLicensePage {
    UIView *box = [self cardBlock];

    _licTitle = XPText(16, UIFontWeightBold, XPInk);
    _licTitle.text = @"推流助手已激活";
    _licSub = XPText(XPFaux, UIFontWeightRegular, XPMuted);
    _licSub.text = @"永久授权 · 当前设备可用";

    _licField = [[UITextField alloc] init];
    _licField.placeholder = @"XXXX-XXXX";
    _licField.textAlignment = NSTextAlignmentCenter;
    _licField.font = XPMono(13, UIFontWeightMedium);
    _licField.textColor = XPInk;
    _licField.backgroundColor = XPChipBG;
    _licField.layer.cornerRadius = XPRadiusControl;
    _licField.autocorrectionType = UITextAutocorrectionTypeNo;
    _licField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    [_licField.heightAnchor constraintEqualToConstant:40].active = YES;

    UIButton *paste = [UIButton buttonWithType:UIButtonTypeCustom];
    [paste setTitle:@"粘贴" forState:UIControlStateNormal];
    [paste setTitleColor:XPBody forState:UIControlStateNormal];
    paste.titleLabel.font = XPFont(XPFbody, UIFontWeightSemibold);
    paste.backgroundColor = XPChipBG;
    paste.layer.cornerRadius = XPRadiusControl;
    [paste.heightAnchor constraintEqualToConstant:38].active = YES;
    [paste.widthAnchor constraintEqualToConstant:72].active = YES;
    [paste addTarget:self action:@selector(tapPaste) forControlEvents:UIControlEventTouchUpInside];

    _licSubmit = [UIButton buttonWithType:UIButtonTypeCustom];
    [_licSubmit setTitle:@"立即激活" forState:UIControlStateNormal];
    [_licSubmit setTitleColor:XPJadeInk forState:UIControlStateNormal];
    _licSubmit.titleLabel.font = XPFont(XPFbody, UIFontWeightBold);
    _licSubmit.backgroundColor = XPJade;
    _licSubmit.layer.cornerRadius = XPRadiusControl;
    [_licSubmit.heightAnchor constraintEqualToConstant:38].active = YES;
    [_licSubmit addTarget:self action:@selector(tapActivate) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[paste, _licSubmit]];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.spacing = 8;

    _licMsg = XPText(XPFnote, UIFontWeightRegular, XPFaint);
    _licMsg.text = @"已绑定当前手机；到期前 3 天会在这里提醒。";

    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[_licTitle, _licSub, _licField, actions, _licMsg]];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 8;
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:col];
    [NSLayoutConstraint activateConstraints:@[
        [col.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:11],
        [col.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-11],
        [col.topAnchor constraintEqualToAnchor:box.topAnchor constant:11],
        [col.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-11],
    ]];
    return box;
}

- (UIView *)buildMorePage {
    UIView *box = [self cardBlock];
    UILabel *t = XPText(XPFBlock, UIFontWeightSemibold, XPInk);
    t.text = @"更多设置";

    UIButton *mirror = [self linkRow:@"水平镜像" action:@selector(tapMirror)];
    UIButton *rotate = [self linkRow:@"画面旋转" action:@selector(tapRotate)];
    UIButton *periodic = [self linkRow:@"定时真实镜头" action:@selector(tapPeriodic)];

    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[t, mirror, rotate, periodic]];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 6;
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:col];
    [NSLayoutConstraint activateConstraints:@[
        [col.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:11],
        [col.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-11],
        [col.topAnchor constraintEqualToAnchor:box.topAnchor constant:11],
        [col.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-11],
    ]];
    return box;
}

- (UIButton *)linkRow:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:XPBody forState:UIControlStateNormal];
    b.titleLabel.font = XPFont(XPFaux, UIFontWeightMedium);
    b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    b.backgroundColor = XPCardBG;
    b.layer.cornerRadius = 9;
    b.contentEdgeInsets = UIEdgeInsetsMake(9, 10, 9, 10);
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildPill {
    _pill = [UIView new];
    _pill.backgroundColor = XPCardBG;
    _pill.layer.cornerRadius = XPRadiusPanel;
    _pill.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    _pill.layer.borderColor = XPBorder.CGColor;
    _pill.translatesAutoresizingMaskIntoConstraints = NO;
    _pill.hidden = YES;

    UIView *dot = [UIView new];
    dot.backgroundColor = XPJade;
    dot.layer.cornerRadius = 3;
    dot.translatesAutoresizingMaskIntoConstraints = NO;

    _pillText = XPMonoText(XPFaux, UIFontWeightSemibold, XPInk);
    UIButton *expand = [UIButton buttonWithType:UIButtonTypeCustom];
    [expand setImage:XPSystemIcon(@"chevron.down") forState:UIControlStateNormal];
    expand.tintColor = XPMuted;
    [expand addTarget:self action:@selector(tapExpand) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[dot, _pillText, [UIView new], expand]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 7;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [_pill addSubview:row];
    [self addSubview:_pill];

    [NSLayoutConstraint activateConstraints:@[
        [dot.widthAnchor constraintEqualToConstant:6],
        [dot.heightAnchor constraintEqualToConstant:6],
        [row.leadingAnchor constraintEqualToAnchor:_pill.leadingAnchor constant:12],
        [row.trailingAnchor constraintEqualToAnchor:_pill.trailingAnchor constant:-10],
        [row.topAnchor constraintEqualToAnchor:_pill.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:_pill.bottomAnchor],
        [_pill.heightAnchor constraintEqualToConstant:42],
    ]];
    _collapsedCons = @[
        [_pill.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_pill.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_pill.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_pill.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ];
}

#pragma mark 状态同步

- (void)refresh {
    id c = self.controller;
    if (!c) return;

    NSString *mode = XPStr(c, @"modeSummaryLabel");
    NSString *link = XPStr(c, @"connectionLabel");

    self.statusTitle.text = mode.length ? mode : @"等待画面";
    self.statusValue.text = link.length ? link : @"—";
    self.statusValue.textColor = XPStateColor(link);
    self.statusDot.backgroundColor = XPStateColor(link);

    // 芯片：来源 / 内录 / 连接
    NSString *src = @"局域网";
    NSNumber *modeNum = XPGet(c, @"activeVideoTransportMode");
    if (modeNum) {
        NSInteger v = modeNum.integerValue;
        src = v == 0 ? @"局域网" : (v == 1 ? @"直连" : @"本地视频");
    } else if ([mode containsString:@"本地"]) {
        src = @"本地视频";
    }
    [self.chipSource setText:src color:XPJade];
    BOOL rec = [mode containsString:@"内录开"];
    [self.chipRecord setText:rec ? @"内录开" : @"内录关" color:rec ? XPJade : XPMuted];
    NSString *linkChip = link.length ? link : @"—";
    [self.chipLink setText:linkChip color:XPStateColor(link)];

    // 头部副标题 = 授权态
    NSString *lic = XPStr(c, @"licenseStateLabel");
    NSString *licDetail = XPStr(c, @"licenseDetailLabel");
    if (licDetail.length) self.subLabel.text = licDetail;
    else if (lic.length) self.subLabel.text = lic;
    self.subLabel.textColor = [self.subLabel.text containsString:@"已激活"] ? XPMuted : XPSand;

    // 画面替换
    id bs = XPGet(c, @"blendSwitch");
    if ([bs isKindOfClass:[UISwitch class]]) {
        [self.blendSwitch setOn:[(UISwitch *)bs isOn] animated:NO];
    }
    id slider = XPGet(c, @"blendSlider");
    if ([slider isKindOfClass:[UISlider class]]) {
        CGFloat v = [(UISlider *)slider value];
        self.blendSlider.value = v;
        self.blendLeft.text = [NSString stringWithFormat:@"OBS %.0f%%", v * 100];
        self.blendRight.text = [NSString stringWithFormat:@"现场 %.0f%%", (1 - v) * 100];
    }

    // 本地视频
    id sel = XPGet(c, @"localSelectButton");
    if ([sel isKindOfClass:[UIButton class]]) {
        NSString *t = [(UIButton *)sel titleForState:UIControlStateNormal];
        if (t.length) [self.selectBtn setTitle:t forState:UIControlStateNormal];
    }
    id loop = XPGet(c, @"localLoopSwitch");
    if ([loop isKindOfClass:[UISwitch class]]) {
        [self.loopSwitch setOn:[(UISwitch *)loop isOn] animated:NO];
    }
    // 显示方式分段
    id dctrl = XPGet(c, @"localDisplayControl");
    if ([dctrl isKindOfClass:[UISegmentedControl class]]) {
        NSInteger di = (NSInteger)[(UISegmentedControl *)dctrl selectedSegmentIndex];
        if (di >= 0 && di < 2) [self.displaySeg setSelected:di];
    }

    // 声音
    id recSw = XPGet(c, @"internalRecordingSwitch");
    if ([recSw isKindOfClass:[UISwitch class]]) {
        [self.recordSwitch setOn:[(UISwitch *)recSw isOn] animated:NO];
    }
    NSString *audio = XPStr(c, @"audioLabel");
    NSString *audioWarn = XPStr(c, @"audioWarningLabel");
    if (audio.length) {
        self.materialSub.text = audio;
        self.materialSub.textColor = audioWarn.length ? XPSand : XPFaint;
        self.meter.level = audioWarn.length ? 0.0 : 0.45;
    }
    if (audioWarn.length) {
        self.warnLabel.text = audioWarn;
        self.warnLabel.hidden = NO;
    } else {
        self.warnLabel.hidden = YES;
    }
    self.hintLabel.text = rec ? @"电脑声音送入直播；手机外放已静音" : @"外放用于试听；正式直播建议开启内录";

    self.pillText.text = [NSString stringWithFormat:@"%@ · %@", mode.length ? mode : @"小潘", link.length ? link : @"—"];
}

#pragma mark 交互

- (void)selectTab:(NSInteger)idx {
    BOOL video = (idx == 0);
    self.tabVideo.backgroundColor = video ? XPJadeSoft : [UIColor clearColor];
    [self.tabVideo setTitleColor:video ? XPJade : XPBody forState:UIControlStateNormal];
    self.tabAudio.backgroundColor = video ? [UIColor clearColor] : XPJadeSoft;
    [self.tabAudio setTitleColor:video ? XPBody : XPJade forState:UIControlStateNormal];
    self.videoPane.hidden = !video;
    self.audioPane.hidden = video;
}

- (void)tapTab:(UIButton *)b {
    [self selectTab:b.tag];
    XPCall(self.controller, @selector(changeTab));
    [self refresh];
}

- (void)selectSource:(NSInteger)idx {
    // 原实现是「循环切换」，这里最多点两次对齐到目标档位
    id c = self.controller;
    for (int i = 0; i < 3; i++) {
        NSNumber *modeNum = XPGet(c, @"activeVideoTransportMode");
        if (modeNum && modeNum.integerValue == idx) break;
        XPCall(c, @selector(changeVideoTransport));
    }
    self.localPane.hidden = (idx != 2);
    [self refresh];
}

- (void)selectDisplay:(NSInteger)idx {
    id c = self.controller;
    id ctrl = XPGet(c, @"localDisplayControl");
    if ([ctrl isKindOfClass:[UISegmentedControl class]]) {
        UISegmentedControl *seg = (UISegmentedControl *)ctrl;
        if ((NSInteger)seg.selectedSegmentIndex == idx) return;
        seg.selectedSegmentIndex = idx;
    }
    SEL sel = @selector(localDisplayModeDidChange:);
    if ([c respondsToSelector:sel]) {
        IMP imp = [c methodForSelector:sel];
        ((void (*)(id, SEL, id))imp)(c, sel, ctrl);
    } else {
        XPCall(c, @selector(changeLocalDisplayMode));
    }
    [self refresh];
}

- (void)tapBlend {
    XPCall(self.controller, @selector(toggleBlend));
    [self refresh];
}

- (void)changeBlend {
    id c = self.controller;
    id slider = XPGet(c, @"blendSlider");
    if ([slider isKindOfClass:[UISlider class]]) {
        [(UISlider *)slider setValue:self.blendSlider.value animated:NO];
    }
    XPCall(c, @selector(changeBlendOpacity));
    self.blendLeft.text = [NSString stringWithFormat:@"OBS %.0f%%", self.blendSlider.value * 100];
    self.blendRight.text = [NSString stringWithFormat:@"现场 %.0f%%", (1 - self.blendSlider.value) * 100];
}

- (void)tapSelectVideo {
    XPCall(self.controller, @selector(selectLocalVideo));
}

- (void)tapLoop {
    XPCall(self.controller, @selector(changeLocalLoop));
}

- (void)tapRecord {
    XPCall(self.controller, @selector(changeInternalRecording));
    [self refresh];
    // 守卫失败时原实现会弹回，这里同步回去
    id recSw = XPGet(self.controller, @"internalRecordingSwitch");
    if ([recSw isKindOfClass:[UISwitch class]]) {
        [self.recordSwitch setOn:[(UISwitch *)recSw isOn] animated:YES];
    }
}

- (void)tapLicense {
    self.licensePage.hidden = NO;
    self.videoPane.hidden = YES;
    self.audioPane.hidden = YES;
    XPCall(self.controller, @selector(openLicensePanel));
}

- (void)tapMore {
    self.morePage.hidden = !self.morePage.hidden;
    XPCall(self.controller, @selector(toggleMoreVideoSettings));
}

- (void)tapRisk {
    XPCall(self.controller, @selector(reviewRiskNotice));
}

- (void)tapMirror { XPCall(self.controller, @selector(toggleMirror)); }
- (void)tapRotate { XPCall(self.controller, @selector(changeRotation)); }
- (void)tapPeriodic { XPCall(self.controller, @selector(togglePeriodicCamera)); }

- (void)tapDiag {
    self.diagBox.hidden = !self.diagBox.hidden;
    XPCall(self.controller, @selector(toggleDiagnostics));
}
- (void)setDiagLogText:(NSString *)text { self.diagLog.text = text; }

- (void)tapPaste {
    self.licField.text = [UIPasteboard generalPasteboard].string;
}

- (void)tapActivate {
    id field = XPGet(self.controller, @"licenseCodeField");
    if ([field isKindOfClass:[UITextField class]]) {
        [(UITextField *)field setText:self.licField.text];
    }
    [self.licSubmit setTitle:@"请稍候" forState:UIControlStateNormal];
    XPCall(self.controller, @selector(activateLicense));
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf.licSubmit setTitle:@"立即激活" forState:UIControlStateNormal];
    });
}

- (void)tapCollapse {
    [self setCollapsed:YES];
    XPCall(self.controller, @selector(closePanel));
    if (self.onCollapse) self.onCollapse();
}

- (void)tapExpand {
    [self setCollapsed:NO];
    if (self.onExpand) self.onExpand();
}

- (void)setCollapsed:(BOOL)collapsed {
    if (_collapsed == collapsed && self.card.superview) return;
    _collapsed = collapsed;
    if (collapsed) {
        [self.card setHidden:YES];
        [NSLayoutConstraint deactivateConstraints:self.expandedCons];
        [NSLayoutConstraint activateConstraints:self.collapsedCons];
        [self.pill setHidden:NO];
    } else {
        [self.pill setHidden:YES];
        [NSLayoutConstraint deactivateConstraints:self.collapsedCons];
        [NSLayoutConstraint activateConstraints:self.expandedCons];
        [self.card setHidden:NO];
    }
    [self setNeedsLayout];
}

- (BOOL)isCollapsed { return _collapsed; }

- (void)updateWidth:(CGFloat)width {
    self.widthConstraint.constant = width;
    [self setNeedsLayout];
}

- (void)updateMaxHeight:(CGFloat)height {
    self.heightCap.constant = MAX(320, height);
    [self setNeedsLayout];
}

@end
