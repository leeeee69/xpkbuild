// XPPanel.h
#import <UIKit/UIKit.h>

@class XPPanel;

@interface XPPanel : UIView

@property (nonatomic, weak) id controller;      // 原始面板控制器（BLK_* 实例）
@property (nonatomic, copy) void (^onCollapse)(void);
@property (nonatomic, copy) void (^onExpand)(void);

- (instancetype)initWithController:(id)controller width:(CGFloat)width;
- (void)refresh;                // 从原始控制器同步状态
- (void)setCollapsed:(BOOL)collapsed;
- (void)updateWidth:(CGFloat)width;
- (BOOL)isCollapsed;

@end
