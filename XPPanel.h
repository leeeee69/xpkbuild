// XPPanel.h
#import <UIKit/UIKit.h>

@interface XPPanel : UIView

@property (nonatomic, weak) id controller;      // 原面板控制器实例（BLK_*）
@property (nonatomic, copy) void (^onCollapse)(void);
@property (nonatomic, copy) void (^onExpand)(void);

- (instancetype)initWithController:(id)controller width:(CGFloat)width;
- (void)refresh;
- (void)setCollapsed:(BOOL)collapsed;
- (BOOL)isCollapsed;
- (void)updateWidth:(CGFloat)width;
- (void)updateMaxHeight:(CGFloat)height;

@end
