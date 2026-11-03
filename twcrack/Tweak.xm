// TWCrack v3 — 依据反汇编补全：直接种全局门控标志
// 反汇编证据（valid @0x138f4b4..0x138f504）：
//   adr x8,#0x13c1d38 ; ldarb w8,[x8] ; cmp w8,#1 ; b.ne fail     ← flagA（信封验签通过）
//   adr x8,#0x13c1d39 ; ldarb w8,[x8] ; cmp w8,#1 ; b.ne fail     ← flagB（租约新鲜）
//   bl  0x138ea88（取当前时间） ; ldar deadline ; fcmp ; cset w0,mi
// 即 valid = flagA && flagB && now < deadline。
// 只 hook 选择子覆盖不到 Swift 内联调用，所以同时把这三个全局量直接写成「已放行」。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>

#define TW_OFF_FLAG_A   0x13C1D38u
#define TW_OFF_FLAG_B   0x13C1D39u
#define TW_OFF_DEADLINE 0x13C1D40u

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

#pragma mark - 种全局门控标志

static const uintptr_t *TWTianWenBase(void) {
    static uintptr_t base;
    if (base) return (const uintptr_t *)base;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        if (!strstr(nm, "TianWen")) continue;
        base = (uintptr_t)_dyld_get_image_header(i);
        TWLog(@"镜像 %s base=%p", nm, (void *)base);
        return (const uintptr_t *)base;
    }
    return NULL;
}

static void TWSeedFlags(void) {
    const uintptr_t *b = TWTianWenBase();
    if (!b) return;
    uintptr_t base = (uintptr_t)b;

    unsigned char *fa = (unsigned char *)(base + TW_OFF_FLAG_A);
    unsigned char *fb = (unsigned char *)(base + TW_OFF_FLAG_B);
    double *dl = (double *)(base + TW_OFF_DEADLINE);

    // 只在该地址看起来还是「0/1 布尔」时才写，避免版本漂移写坏内存
    @try {
        unsigned char va = *fa, vb = *fb;
        if (va <= 1 && vb <= 1) {
            *fa = 1;
            *fb = 1;
            *dl = 4102444800.0;
            TWLog(@"已种标志 flagA=%d flagB=%d deadline=2100", *fa, *fb);
        } else {
            TWLog(@"标志区不像布尔（%d/%d），跳过播种", va, vb);
        }
    } @catch (NSException *e) {
        TWLog(@"播种异常 %@", e.reason);
    }
}

#pragma mark - 替身

static BOOL TWTrue(id s, SEL c) { return YES; }
static void TWSB(id s, SEL c, BOOL v) { }
static void TSD(id s, SEL c, double v) { }
static void TSO(id s, SEL c, id v) { }
static void TSOO(id s, SEL c, id a, id b) { }
static void TSV(id s, SEL c) { }
static void TWKillTimer(id s, SEL c, NSTimer *t) { if (t) [t invalidate]; }
static double TWFuture(id s, SEL c) { return 4102444800.0; }
static double TWRemaining(id s, SEL c) { return 315360000.0; }   // 10 年

static BOOL TWLeaseOK(id s, SEL c, id lease) { TWLog(@"leaseFormatValid: 放行"); return YES; }
static void TWApplyLease(id s, SEL c, id lease, NSUInteger ep) {
    TWLog(@"applyLease 拦截 ep=%lu", (unsigned long)ep);
    TWSeedFlags();
}

static IMP gOrigConsumeFront;
static void TWConsumeFront(id s, SEL c, id picker, NSInteger cnt, BOOL authorized) {
    if (!authorized) TWLog(@"consumeFrontPicker authorized=0 → 强改 YES");
    if (gOrigConsumeFront) ((void (*)(id, SEL, id, NSInteger, BOOL))gOrigConsumeFront)(s, c, picker, cnt, YES);
}

static IMP gOrigReadToken;
static id TWReadToken(id s, SEL c) {
    id v = gOrigReadToken ? ((id (*)(id, SEL))gOrigReadToken)(s, c) : nil;
    return v ?: @"LIC2.crack.local.4102444800.00000000.00000000";
}

static void TWHook(Class c, SEL sel, IMP imp, const char *tag, IMP *store) {
    if (!c) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { TWLog(@"缺方法 %@ (%s)", NSStringFromSelector(sel), tag); return; }
    if (store) *store = method_getImplementation(m);
    method_setImplementation(m, imp);
    TWLog(@"接管 %s %@", tag, NSStringFromSelector(sel));
}

static void TWInstall(void) {
    static BOOL done;
    if (done) return;
    Class mgr = TWCls(@"TWLicenseManager");
    Class panel = TWCls(@"TWLicensePanel");
    Class plugin = TWCls(@"FXPluginPanel");
    if (!mgr && !plugin) return;
    done = YES;

    TWSeedFlags();

    TWHook(mgr, @selector(authorized), (IMP)TWTrue, "A1", NULL);
    TWHook(mgr, @selector(setAuthorized:), (IMP)TWSB, "A2", NULL);
    TWHook(mgr, NSSelectorFromString(@"valid"), (IMP)TWTrue, "A3", NULL);
    TWHook(mgr, @selector(expires), (IMP)TWFuture, "A4", NULL);
    TWHook(mgr, @selector(setExpires:), (IMP)TSD, "A5", NULL);
    TWHook(mgr, NSSelectorFromString(@"remaining"), (IMP)TWRemaining, "A6", NULL);

    TWHook(mgr, NSSelectorFromString(@"refreshAuthorization"), (IMP)TSV, "B1", NULL);
    TWHook(mgr, NSSelectorFromString(@"leaseFormatValid:"), (IMP)TWLeaseOK, "B2", NULL);
    TWHook(mgr, @selector(applyLease:foregroundEpoch:), (IMP)TWApplyLease, "B3", NULL);
    TWHook(mgr, NSSelectorFromString(@"heartbeat"), (IMP)TSV, "B4", NULL);
    TWHook(mgr, NSSelectorFromString(@"tick"), (IMP)TSV, "B5", NULL);

    TWHook(mgr, @selector(setHeartbeatTimer:), (IMP)TWKillTimer, "C1", NULL);
    TWHook(mgr, @selector(setWatchdog:), (IMP)TWKillTimer, "C2", NULL);

    if (panel) TWHook(panel, @selector(changeState:message:), (IMP)TSOO, "D1", NULL);

    TWHook(mgr, @selector(readToken), (IMP)TWReadToken, "E1", &gOrigReadToken);
    TWHook(mgr, @selector(saveToken:), (IMP)TSO, "E2", NULL);

    TWHook(plugin, @selector(consumeFrontPicker:resultCount:authorized:), (IMP)TWConsumeFront, "F1", &gOrigConsumeFront);
    TWHook(plugin, NSSelectorFromString(@"previouslyAuthorized"), (IMP)TWTrue, "F2", NULL);
    TWHook(plugin, NSSelectorFromString(@"setPreviouslyAuthorized:"), (IMP)TWSB, "F3", NULL);

    TWLog(@"安装完成");
}

static void TWBadge(NSString *text, UIColor *color) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = [UIApplication sharedApplication].windows.firstObject;
        if (!w) return;
        UILabel *l = (UILabel *)[w viewWithTag:0x54574303];
        if (!l) {
            l = [UILabel new];
            l.tag = 0x54574303;
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
    TWLog(@"=== TWCrack v3 载入 pid=%d ===", getpid());
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            @try { TWInstall(); } @catch (NSException *e) { TWLog(@"异常 %@", e.reason); }
            static BOOL badged;
            if (!badged && TWCls(@"TWLicenseManager")) {
                badged = YES;
                TWBadge(@"TW 已破甲 v3", [UIColor colorWithRed:0.85 green:0.15 blue:0.2 alpha:0.92]);
            }
        }];
    });
}
