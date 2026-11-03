// TWCrack.xm — TianWen 带人脸版 授权绕过（运行时 hook，不改原 dylib 字节）
// 目标：TWLicenseManager（71 方法）/ TWLicensePanel（34 方法），位于 __TW* 段。
// 思路：把「授权判定」钉死为真；吞掉看门狗回写；拒绝服务端租约覆盖；停掉心跳与看门狗计时器。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <stdio.h>

static void TWLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[TWCrack] %@", s);
    NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"twcrack.log"];
    FILE *f = fopen(p.fileSystemRepresentation, "a");
    if (f) { fprintf(f, "%s\n", s.UTF8String); fclose(f); }
}

static Class TWCls(NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) c = objc_getClass(name.UTF8String);
    return c;
}

#pragma mark - 判定：永远已授权

static BOOL TWAuthorized(id self, SEL _cmd) { return YES; }
static void TWSetAuthorized(id self, SEL _cmd, BOOL v) { /* 看门狗回写，吞掉 */ }
static double TWExpires(id self, SEL _cmd) { return 4102444800000.0; }  // ms 口径给足
static void TWSetExpires(id self, SEL _cmd, double v) { /* 不覆盖 */ }

static void TWApplyLease(id self, SEL _cmd, id lease, NSUInteger epoch) {
    TWLog(@"拦截 applyLease epoch=%lu", (unsigned long)epoch);
}

static void TWKillTimer(id self, SEL _cmd, NSTimer *t) {
    if (t) [t invalidate];
}

#pragma mark - 状态文案：让面板显示已激活

static void TWChangeState(id self, SEL _cmd, id state, id message) {
    TWLog(@"面板状态被请求改写 state=%@ msg=%@", state, message);
}

static void TWSwizzle(Class c, SEL sel, IMP newImp) {
    if (!c) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    method_setImplementation(m, newImp);
    TWLog(@"接管 -[%@ %@]", NSStringFromClass(c), NSStringFromSelector(sel));
}

static void TWInstall(void) {
    static BOOL done;
    if (done) return;
    Class mgr = TWCls(@"TWLicenseManager");
    Class panel = TWCls(@"TWLicensePanel");
    if (!mgr) return;
    done = YES;

    TWSwizzle(mgr, @selector(authorized), (IMP)TWAuthorized);
    TWSwizzle(mgr, @selector(setAuthorized:), (IMP)TWSetAuthorized);
    TWSwizzle(mgr, @selector(expires), (IMP)TWExpires);
    TWSwizzle(mgr, @selector(setExpires:), (IMP)TWSetExpires);
    TWSwizzle(mgr, @selector(applyLease:foregroundEpoch:), (IMP)TWApplyLease);
    TWSwizzle(mgr, @selector(setHeartbeatTimer:), (IMP)TWKillTimer);
    TWSwizzle(mgr, @selector(setWatchdog:), (IMP)TWKillTimer);
    if (panel) TWSwizzle(panel, @selector(changeState:message:), (IMP)TWChangeState);

    TWLog(@"安装完成");
}

static void TWBadge(NSString *text, UIColor *color) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = [UIApplication sharedApplication].windows.firstObject;
        if (!w) return;
        UILabel *l = (UILabel *)[w viewWithTag:0x54574301];
        if (!l) {
            l = [UILabel new];
            l.tag = 0x54574301;
            l.font = [UIFont boldSystemFontOfSize:11];
            l.textColor = UIColor.whiteColor;
            l.textAlignment = NSTextAlignmentCenter;
            l.layer.cornerRadius = 4;
            l.clipsToBounds = YES;
            l.frame = CGRectMake(8, w.bounds.size.height - 30, 96, 20);
            l.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
            [w addSubview:l];
        }
        l.text = text;
        l.backgroundColor = color;
    });
}

%ctor {
    TWLog(@"=== TWCrack 载入 pid=%d ===", getpid());
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            @try { TWInstall(); } @catch (NSException *e) { TWLog(@"异常 %@", e.reason); }
            static BOOL badged;
            if (!badged && TWCls(@"TWLicenseManager")) {
                badged = YES;
                TWBadge(@"TW 已破甲", [UIColor colorWithRed:0.85 green:0.15 blue:0.2 alpha:0.92]);
            }
        }];
    });
}
