// TWCrack v2 — 全量门控覆盖
// 静态排查出两处门控面：
//   A. TW 模块：authorized / valid / expires / refreshAuthorization / leaseFormatValid: /
//      applyLease:foregroundEpoch: / changeState:message: / activationState / 心跳&看门狗 timer
//   B. 主镜像二次判定：consumeFrontPicker:resultCount:authorized:（人脸导入自带 authorized 参数）、previouslyAuthorized
// 策略：布尔钉真 + 网络刷新禁用 + 租约拒绝 + 强改调用参数 + 停计时器

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

static Class TWCls(NSString *n) {
    Class c = NSClassFromString(n);
    return c ?: objc_getClass(n.UTF8String);
}

#pragma mark - 基础替身

static BOOL TWTrue(id self, SEL _cmd) { return YES; }
static BOOL TWFalse(id self, SEL _cmd) { return NO; }
static void TWSwallowB(id self, SEL _cmd, BOOL v) { }
static void TWSwallowD(id self, SEL _cmd, double v) { }
static void TWSwallowO(id self, SEL _cmd, id v) { }
static void TWSwallowOO(id self, SEL _cmd, id a, id b) { }
static void TWSwallowVoid(id self, SEL _cmd) { }
static void TWKillTimer(id self, SEL _cmd, NSTimer *t) { if (t) [t invalidate]; }
static double TWFuture(id self, SEL _cmd) { return 4102444800000.0; }

static BOOL TWLeaseOK(id self, SEL _cmd, id lease) {
    TWLog(@"leaseFormatValid: 直接放行");
    return YES;
}

static void TWApplyLeaseNoop(id self, SEL _cmd, id lease, NSUInteger epoch) {
    TWLog(@"applyLease 拦截 epoch=%lu", (unsigned long)epoch);
}

static NSUInteger TWActState(id self, SEL _cmd) { return 2; }
static void TWSetActState(id self, SEL _cmd, NSUInteger v) { }

#pragma mark - 主镜像：强改 authorized 参数

static IMP gOrigConsumeFront;
static void TWConsumeFront(id self, SEL _cmd, id picker, NSInteger count, BOOL authorized) {
    if (!authorized) TWLog(@"consumeFrontPicker authorized=0，强制传 YES");
    if (gOrigConsumeFront) {
        ((void (*)(id, SEL, id, NSInteger, BOOL))gOrigConsumeFront)(self, _cmd, picker, count, YES);
    }
}

#pragma mark - token 兜底

static IMP gOrigReadToken;
static id TWReadToken(id self, SEL _cmd) {
    id v = gOrigReadToken ? ((id (*)(id, SEL))gOrigReadToken)(self, _cmd) : nil;
    if (v) return v;
    TWLog(@"readToken 为空 → 占位 LIC2");
    return @"LIC2.crack.local.4102444800000.00000000.00000000";
}

#pragma mark - 安装

static void TWHook(Class c, SEL sel, IMP imp, const char *tag, IMP *store) {
    if (!c) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { TWLog(@"缺方法 %@ (%s)", NSStringFromSelector(sel), tag); return; }
    if (store) *store = method_getImplementation(m);
    method_setImplementation(m, imp);
    TWLog(@"接管 %s -[%@ %@]", tag, NSStringFromClass(c), NSStringFromSelector(sel));
}

static void TWInstall(void) {
    static BOOL done;
    if (done) return;
    Class mgr = TWCls(@"TWLicenseManager");
    Class panel = TWCls(@"TWLicensePanel");
    Class plugin = TWCls(@"FXPluginPanel");
    if (!mgr && !plugin) return;
    done = YES;

    // A. 布尔与时间
    TWHook(mgr, @selector(authorized), (IMP)TWTrue, "A1", NULL);
    TWHook(mgr, @selector(setAuthorized:), (IMP)TWSwallowB, "A2", NULL);
    TWHook(mgr, NSSelectorFromString(@"valid"), (IMP)TWTrue, "A3", NULL);
    TWHook(mgr, NSSelectorFromString(@"isValid"), (IMP)TWTrue, "A3b", NULL);
    TWHook(mgr, NSSelectorFromString(@"setValid:"), (IMP)TWSwallowB, "A4", NULL);
    TWHook(mgr, @selector(expires), (IMP)TWFuture, "A5", NULL);
    TWHook(mgr, @selector(setExpires:), (IMP)TWSwallowD, "A6", NULL);

    // B. 网络 / 租约
    TWHook(mgr, NSSelectorFromString(@"refreshAuthorization"), (IMP)TWSwallowVoid, "B1", NULL);
    TWHook(mgr, NSSelectorFromString(@"leaseFormatValid:"), (IMP)TWLeaseOK, "B2", NULL);
    TWHook(mgr, @selector(applyLease:foregroundEpoch:), (IMP)TWApplyLeaseNoop, "B3", NULL);

    // C. 计时器
    TWHook(mgr, @selector(setHeartbeatTimer:), (IMP)TWKillTimer, "C1", NULL);
    TWHook(mgr, @selector(setWatchdog:), (IMP)TWKillTimer, "C2", NULL);

    // D. 状态枚举 / 面板
    TWHook(mgr, NSSelectorFromString(@"activationState"), (IMP)TWActState, "D1", NULL);
    TWHook(mgr, NSSelectorFromString(@"setActivationState:"), (IMP)TWSetActState, "D2", NULL);
    TWHook(panel, @selector(changeState:message:), (IMP)TWSwallowOO, "D3", NULL);

    // E. token 兜底
    TWHook(mgr, @selector(readToken), (IMP)TWReadToken, "E1", &gOrigReadToken);
    TWHook(mgr, @selector(saveToken:), (IMP)TWSwallowO, "E2", NULL);

    // F. 主镜像二次判定
    TWHook(plugin, @selector(consumeFrontPicker:resultCount:authorized:), (IMP)TWConsumeFront, "F1", &gOrigConsumeFront);
    TWHook(plugin, NSSelectorFromString(@"previouslyAuthorized"), (IMP)TWTrue, "F2", NULL);
    TWHook(plugin, NSSelectorFromString(@"setPreviouslyAuthorized:"), (IMP)TWSwallowB, "F3", NULL);

    TWLog(@"安装完成");
}

static void TWBadge(NSString *text, UIColor *color) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = [UIApplication sharedApplication].windows.firstObject;
        if (!w) return;
        UILabel *l = (UILabel *)[w viewWithTag:0x54574302];
        if (!l) {
            l = [UILabel new];
            l.tag = 0x54574302;
            l.font = [UIFont boldSystemFontOfSize:11];
            l.textColor = UIColor.whiteColor;
            l.textAlignment = NSTextAlignmentCenter;
            l.layer.cornerRadius = 4;
            l.clipsToBounds = YES;
            l.frame = CGRectMake(8, w.bounds.size.height - 30, 110, 20);
            l.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
            [w addSubview:l];
        }
        l.text = text;
        l.backgroundColor = color;
    });
}

%ctor {
    TWLog(@"=== TWCrack v2 载入 pid=%d ===", getpid());
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            @try { TWInstall(); } @catch (NSException *e) { TWLog(@"异常 %@", e.reason); }
            static BOOL badged;
            if (!badged && TWCls(@"TWLicenseManager")) {
                badged = YES;
                TWBadge(@"TW 已破甲 v2", [UIColor colorWithRed:0.85 green:0.15 blue:0.2 alpha:0.92]);
            }
        }];
    });
}
