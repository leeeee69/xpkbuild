// XPTheme.h — 设计令牌（源自 DESIGN-SPEC.md v1.6.30）
// 颜色、字号、间距、圆角全部集中在此，改皮只改这里。

#import <UIKit/UIKit.h>

UIColor *XPColor(UInt8 r, UInt8 g, UInt8 b, CGFloat a);
#define XPHEX(rgb) XPColor(((rgb) >> 16) & 0xFF, ((rgb) >> 8) & 0xFF, (rgb) & 0xFF, 1.0)

// 主色：青玉
#define XPJade       XPHEX(0x1ED9A9)
#define XPJade2      XPHEX(0x63F2CC)
#define XPJadeInk    XPHEX(0x032A22)
#define XPJadeSoft   XPColor(30, 217, 169, 0.11)
// 语义色
#define XPSand       XPHEX(0xE4C795)
#define XPWarn       XPHEX(0xE8B04B)
#define XPLive       XPHEX(0xFF4D5F)
// 文本
#define XPInk        XPHEX(0xF1F6F4)
#define XPText       XPHEX(0xBFCBC7)
#define XPMuted      XPHEX(0x82928D)
#define XPFaint      XPHEX(0x5A6965)
// 线与底
#define XPHairline   XPColor(255, 255, 255, 0.07)
#define XPBorder     XPColor(30, 217, 169, 0.16)
#define XPChipBG     XPColor(255, 255, 255, 0.06)
#define XPCardBG     XPColor(255, 255, 255, 0.045)

// 圆角
static const CGFloat XPRadiusPanel   = 20.0;
static const CGFloat XPRadiusCard    = 14.0;
static const CGFloat XPRadiusControl = 10.0;
// 间距
static const CGFloat XPPadH          = 12.0;
static const CGFloat XPPadB          = 10.0;
static const CGFloat XPGapBlock      = 9.0;
static const CGFloat XPGapInner      = 10.0;

// 字号（UIFont systemFontOfSize:weight:）
static const CGFloat XPFName    = 16.5;
static const CGFloat XPFVer     = 10.5;
static const CGFloat XPFSub     = 10.5;
static const CGFloat XPFBlock   = 12.5;
static const CGFloat XPFrowT    = 11.5;
static const CGFloat XPFbody    = 11.0;
static const CGFloat XPFaux     = 10.5;
static const CGFloat XPFnote    = 10.0;
static const CGFloat XPFmicro   = 9.5;

static inline UIFont *XPFont(CGFloat size, UIFontWeight w) {
    return [UIFont systemFontOfSize:size weight:w];
}
static inline UIFont *XPMono(CGFloat size, UIFontWeight w) {
    return [UIFont monospacedDigitSystemFontOfSize:size weight:w];
}
