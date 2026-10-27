// Tweak.xm — 视图层接管 + 防崩 + 崩溃取证
// 关键约束：
//   1) 所有 UIKit 操作只在主线程做（原插件的 refreshStatus 很可能在后台线程调）
//   2) 钩子体全部 @try/@catch，异常绝不外泄
//   3) 类探测从严：必须同时有 openPanel 与 _card ivar，且排除系统类
//   4) 装未捕获异常 / 信号处理器，崩溃前把现场写进日志

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <stdio.h>
#import <signal.h>
#import <execinfo.h>
#import <fcntl.h>
#import <string.h>
#import <dlfcn.h>
#import "XPPanel.h"

static NSMapTable<id, XPPanel *> *gPanels;
static NSTimer *gSyncTimer;
static NSString *gLogPath;
static Class gPanelClass;
static BOOL gInstalled;
static NSMutableArray<NSString *> *gLines;
static NSMapTable<id, XPPanel *> *XPPanels(void);

#pragma mark - 日志

static void XPWrite(NSString *line) {
    if (!gLogPath) {
        gLogPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"xppanel.log"];
    }
    FILE *f = fopen(gLogPath.fileSystemRepresentation, "a");
    if (!f) return;
    fputs(line.UTF8String, f);
    fclose(f);
}

static void XPLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[XPPanelKit] %@", s);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gLines = [NSMutableArray array]; });
    @synchronized (gLines) {
        [gLines addObject:[NSString stringWithFormat:@"%@ %@",
                           [NSThread isMainThread] ? @"M" : @"B", s]];
        while (gLines.count > 300) [gLines removeObjectAtIndex:0];
    }
    XPWrite([NSString stringWithFormat:@"%.3f [%@] %@\n",
             [NSDate date].timeIntervalSince1970,
             [NSThread isMainThread] ? @"M" : @"B", s]);
}

static void XPLogRaw(const char *text) {
    NSLog(@"[XPPanelKit] %s", text);
    FILE *f = fopen([NSTemporaryDirectory() stringByAppendingPathComponent:@"xppanel.log"].fileSystemRepresentation, "a");
    if (!f) return;
    fputs(text, f);
    fputs("\n", f);
    fclose(f);
}

#pragma mark - 崩溃取证

static void XPUncaughtHandler(NSException *e) {
    XPLog(@"!!! 未捕获异常 %@: %@", e.name, e.reason);
    XPLog(@"调用栈:\n%@", [e.callStackSymbols componentsJoinedByString:@"\n"]);
}

static void XPSignalHandler(int sig) {
    // 只做异步信号安全的操作：backtrace + snprintf + write
    void *frames[48];
    int n = backtrace(frames, 48);
    char buf[2048];
    int off = snprintf(buf, sizeof(buf), "\n!!! signal %d\n", sig);
    for (int i = 0; i < n && off < (int)sizeof(buf) - 32; i++) {
        off += snprintf(buf + off, sizeof(buf) - off, "  %p\n", frames[i]);
    }
    int fd = open([NSTemporaryDirectory() stringByAppendingPathComponent:@"xppanel.log"].fileSystemRepresentation,
                  O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        ssize_t ignored = write(fd, buf, strlen(buf));
        (void)ignored;
        close(fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void XPInstallCrashHandlers(void) {
    NSSetUncaughtExceptionHandler(&XPUncaughtHandler);
    for (int i = 0; i < 4; i++) {
        int sigs[4] = {SIGSEGV, SIGABRT, SIGBUS, SIGILL};
        signal(sigs[i], XPSignalHandler);
    }
}


static double XPNOW(void) { return CACurrentMediaTime(); }
static void XPTimeIt(NSString *label, double t0) {
    double dt = XPNOW() - t0;
    if (dt > 0.05) XPLog(@"慢调用 %@ 耗时 %.0f ms", label, dt * 1000);
}

#pragma mark - 主线程包装

static void XPOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        @try { block(); } @catch (NSException *e) { XPLog(@"主线程块异常: %@ %@", e.name, e.reason); }
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            @try { block(); } @catch (NSException *e) { XPLog(@"主线程块异常: %@ %@", e.name, e.reason); }
        });
    }
}

#pragma mark - 类探测

static BOOL XPIsSystemClass(const char *name) {
    if (!name) return YES;
    const char *bad[] = {"UI", "NS", "CA", "SK", "AV", "_UI", "Web", "GK", "MTL", "CL"};
    for (int i = 0; i < 10; i++) {
        if (strncmp(name, bad[i], strlen(bad[i])) == 0) return YES;
    }
    return NO;
}

static Class XPFindPanelClass(void) {
    // 反查结论：核心 dylib 是 Swift + ObjC 混合，自有类只有 22 个，名字是
    //   BLK_XXXXXXX / CBSignalMeter / CBLocalImportButton / Boleme* / ProgramSurface / _TtC4main*
    // 之前遍历全进程并对每个类调 class_getInstanceMethod，会强制 realize 宿主的类，
    // 微信里直接触发它自己的断言（Property Name should be baseRequest）→ 崩溃。
    // 现在只碰这些自有前缀。
    static const char *prefixes[] = {"BLK_", "CB", "Boleme", "Program", "_TtC4main", "_TtC"};
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;
    Class *list = (Class *)malloc(sizeof(Class) * count);
    objc_getClassList(list, count);

    Class best = Nil;
    int bestScore = 0;
    int scanned = 0;
    for (int i = 0; i < count; i++) {
        Class c = list[i];
        const char *nm = class_getName(c);
        if (!nm) continue;
        BOOL mine = NO;
        for (int k = 0; k < 6; k++) {
            if (strncmp(nm, prefixes[k], strlen(prefixes[k])) == 0) { mine = YES; break; }
        }
        if (!mine) continue;
        scanned++;
        @try {
            int score = 0;
            if (class_getInstanceMethod(c, @selector(openPanel))) score += 6;
            if (class_getInstanceMethod(c, @selector(refreshStatus))) score += 3;
            if (class_getInstanceMethod(c, @selector(installIfNeeded))) score += 2;
            if (class_getInstanceMethod(c, @selector(closePanel))) score += 1;
            BOOL hasCardIvar = class_getInstanceVariable(c, "_card") != NULL;
            BOOL hasHostIvar = class_getInstanceVariable(c, "_hostWindow") != NULL;
            XPLog(@"自有类 %s score=%d card=%d host=%d", nm, score, hasCardIvar, hasHostIvar);
            if (score > bestScore) { bestScore = score; best = c; }
        } @catch (NSException *e) {
            XPLog(@"探测 %s 异常: %@", nm, e.reason);
        }
    }
    free(list);
    XPLog(@"自有类共扫描 %d 个", scanned);
    if (best && bestScore >= 6) {
        XPLog(@"选中 %s (%d)", class_getName(best), bestScore);
        return best;
    }
    return Nil;
}

static id XPSafeGet(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

#pragma mark - 挂载（必须主线程）

static void XPPresent(id controller) {
    if (!controller) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ XPPresent(controller); });
        return;
    }
    @try {
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
            XPLog(@"后台态，跳过挂载");
            return;
        }
        UIView *card = XPSafeGet(controller, @"card");
        // 原面板必须已经上屏，才允许我们建 UI。否则说明插件自己还没显示，
        // 这时候建视图只会踩到未初始化状态（在非直播类 App 里极易崩）。
        if (![card isKindOfClass:[UIView class]] || !card.superview) {
            static BOOL logged;
            if (!logged) { logged = YES; XPLog(@"原面板尚未上屏，暂不创建 UI"); }
            return;
        }
        UIView *host = nil;
        host = card.window ?: card.superview;
        if (!host) {
            id hw = XPSafeGet(controller, @"hostWindow");
            if ([hw isKindOfClass:[UIView class]]) host = hw;
        }
        if (!host) {
            for (UIWindow *w in [UIApplication sharedApplication].windows.reverseObjectEnumerator) {
                if (w.isKeyWindow) { host = w; break; }
            }
        }
        if (!host) host = [UIApplication sharedApplication].windows.firstObject;
        if (!host) return;

        if ([card isKindOfClass:[UIView class]]) card.hidden = YES;

        XPPanel *panel = [XPPanels() objectForKey:controller];
        if (!panel) {
            CGFloat w = MIN(host.bounds.size.width - 24, 420);
            panel = [[XPPanel alloc] initWithController:controller width:w];
            [host addSubview:panel];
            [NSLayoutConstraint activateConstraints:@[
                [panel.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
                [panel.topAnchor constraintEqualToAnchor:host.topAnchor constant:24],
                [panel.bottomAnchor constraintLessThanOrEqualToAnchor:host.bottomAnchor constant:-24],
            ]];
            [XPPanels() setObject:panel forKey:controller];
            XPLog(@"面板已创建 w=%.0f host=%@", w, NSStringFromClass(host.class));
        }
        panel.hidden = NO;
        [host bringSubviewToFront:panel];
        [panel updateWidth:MIN(host.bounds.size.width - 24, 420)];
        [panel updateMaxHeight:host.bounds.size.height - 72];
        [panel refresh];
        XPLog(@"面板 frame=%@", NSStringFromCGRect(panel.frame));
    } @catch (NSException *e) {
        XPLog(@"挂载异常: %@ %@", e.name, e.reason);
    }
}

static NSMapTable<id, XPPanel *> *XPPanels(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gPanels = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory
                                        valueOptions:NSPointerFunctionsStrongMemory];
    });
    return gPanels;
}

#pragma mark - 钩子

static IMP XPOrigOpenPanel, XPOrigRefreshStatus, XPOrigRefreshMeters, XPOrigRefreshLicense,
           XPOrigRefreshLocal, XPOrigUpdateBlend, XPOrigToggleDiag, XPOrigInstall;

static void XPHookOpenPanel(id self, SEL _cmd) {
    double t0 = XPNOW();
    @try {
        XPLog(@"openPanel 被调用");
        if (XPOrigOpenPanel) ((void (*)(id, SEL))XPOrigOpenPanel)(self, _cmd);
    } @catch (NSException *e) {
        XPLog(@"openPanel 原实现异常: %@ %@", e.name, e.reason);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ XPPresent(self); });
    XPTimeIt(@"OpenPanel", t0);
}


static void XPHookInstall(id self, SEL _cmd) {
    double t0 = XPNOW();
    @try {
        XPLog(@"installIfNeeded 被调用");
        if (XPOrigInstall) ((void (*)(id, SEL))XPOrigInstall)(self, _cmd);
    } @catch (NSException *e) {
        XPLog(@"installIfNeeded 原实现异常: %@ %@", e.name, e.reason);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ XPPresent(self); });
    XPTimeIt(@"Install", t0);
}


static void XPHookRefreshStatus(id self, SEL _cmd) {
    double t0 = XPNOW();
    @try {
        if (XPOrigRefreshStatus) ((void (*)(id, SEL))XPOrigRefreshStatus)(self, _cmd);
    } @catch (NSException *e) {
        XPLog(@"refreshStatus 原实现异常: %@ %@", e.name, e.reason);
    }
    XPPanel *p = [XPPanels() objectForKey:self];
    if (p) XPOnMain(^{ [p refresh]; });
    else XPPresent(self);
    XPTimeIt(@"RefreshStatus", t0);
}

static void XPHookRefreshMeters(id self, SEL _cmd, id snap) {
    double t0 = XPNOW();
    @try {
        if (XPOrigRefreshMeters) ((void (*)(id, SEL, id))XPOrigRefreshMeters)(self, _cmd, snap);
    } @catch (NSException *e) { XPLog(@"meters 异常: %@", e.reason); }
    XPPanel *p = [XPPanels() objectForKey:self];
    if (p) XPOnMain(^{ [p refresh]; });
    XPTimeIt(@"RefreshMeters", t0);
}

static void XPHookRefreshLicense(id self, SEL _cmd) {
    double t0 = XPNOW();
    @try {
        if (XPOrigRefreshLicense) ((void (*)(id, SEL))XPOrigRefreshLicense)(self, _cmd);
    } @catch (NSException *e) { XPLog(@"license 异常: %@", e.reason); }
    XPPanel *p = [XPPanels() objectForKey:self];
    if (p) XPOnMain(^{ [p refresh]; });
    XPTimeIt(@"RefreshLicense", t0);
}

static void XPHookRefreshLocal(id self, SEL _cmd) {
    double t0 = XPNOW();
    @try {
        if (XPOrigRefreshLocal) ((void (*)(id, SEL))XPOrigRefreshLocal)(self, _cmd);
    } @catch (NSException *e) { XPLog(@"local 异常: %@", e.reason); }
    XPPanel *p = [XPPanels() objectForKey:self];
    if (p) XPOnMain(^{ [p refresh]; });
    XPTimeIt(@"RefreshLocal", t0);
}

static void XPHookUpdateBlend(id self, SEL _cmd) {
    double t0 = XPNOW();
    @try {
        if (XPOrigUpdateBlend) ((void (*)(id, SEL))XPOrigUpdateBlend)(self, _cmd);
    } @catch (NSException *e) { XPLog(@"blend 异常: %@", e.reason); }
    XPPanel *p = [XPPanels() objectForKey:self];
    if (p) XPOnMain(^{ [p refresh]; });
    XPTimeIt(@"UpdateBlend", t0);
}

static void XPHookToggleDiag(id self, SEL _cmd) {
    double t0 = XPNOW();
    @try {
        if (XPOrigToggleDiag) ((void (*)(id, SEL))XPOrigToggleDiag)(self, _cmd);
    } @catch (NSException *e) { XPLog(@"diag 异常: %@", e.reason); }
    XPPanel *p = [XPPanels() objectForKey:self];
    if (p) XPOnMain(^{ [p refresh]; });
    XPTimeIt(@"ToggleDiag", t0);
}

static void XPReplace(Class c, SEL sel, IMP hook, IMP *store) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    if (store) *store = method_getImplementation(m);
    method_setImplementation(m, hook);
    XPLog(@"已挂钩 %@", NSStringFromSelector(sel));
}

static void XPInstall(void) {
    if (gInstalled) return;
    Class c = XPFindPanelClass();
    if (!c) return;
    gInstalled = YES;
    gPanelClass = c;

    XPReplace(c, @selector(openPanel), (IMP)XPHookOpenPanel, &XPOrigOpenPanel);
    XPReplace(c, @selector(installIfNeeded), (IMP)XPHookInstall, &XPOrigInstall);
    XPReplace(c, @selector(refreshStatus), (IMP)XPHookRefreshStatus, &XPOrigRefreshStatus);
    XPReplace(c, @selector(refreshLicenseUI), (IMP)XPHookRefreshLicense, &XPOrigRefreshLicense);
    XPReplace(c, @selector(refreshLocalVideoControls), (IMP)XPHookRefreshLocal, &XPOrigRefreshLocal);
    XPReplace(c, @selector(updateBlendControls), (IMP)XPHookUpdateBlend, &XPOrigUpdateBlend);
    XPReplace(c, @selector(toggleDiagnostics), (IMP)XPHookToggleDiag, &XPOrigToggleDiag);
    XPReplace(c, @selector(refreshMetersWithSnapshot:), (IMP)XPHookRefreshMeters, &XPOrigRefreshMeters);

    if (!gSyncTimer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gSyncTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
                if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
                double r0 = XPNOW();
                for (id key in XPPanels()) {
                    XPPanel *p = [XPPanels() objectForKey:key];
                    @try { [p refresh]; } @catch (NSException *e) { XPLog(@"刷新异常: %@", e.reason); }
                }
                XPTimeIt(@"sync-refresh", r0);
            }];
            [[NSRunLoop mainRunLoop] addTimer:gSyncTimer forMode:NSRunLoopCommonModes];
        });
    }
}

#pragma mark - 探针徽标

static void XPBadge(NSString *text, UIColor *color) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = nil;
            for (UIWindow *cand in [UIApplication sharedApplication].windows.reverseObjectEnumerator) {
                if (cand.isKeyWindow) { w = cand; break; }
            }
            if (!w) w = [UIApplication sharedApplication].windows.firstObject;
            if (!w) return;
            UILabel *l = (UILabel *)[w viewWithTag:0x58504B01];
            if (!l) {
                l = [UILabel new];
                l.tag = 0x58504B01;
                if (@available(iOS 13.0, *)) l.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightBold];
                else l.font = [UIFont boldSystemFontOfSize:11];
                l.textColor = UIColor.whiteColor;
                l.textAlignment = NSTextAlignmentCenter;
                l.layer.cornerRadius = 4;
                l.clipsToBounds = YES;
                l.userInteractionEnabled = NO;
                l.translatesAutoresizingMaskIntoConstraints = NO;
                [w addSubview:l];
                [NSLayoutConstraint activateConstraints:@[
                    [l.leadingAnchor constraintEqualToAnchor:w.leadingAnchor constant:6],
                    [l.bottomAnchor constraintEqualToAnchor:w.bottomAnchor constant:-6],
                    [l.heightAnchor constraintEqualToConstant:18],
                    [l.widthAnchor constraintGreaterThanOrEqualToConstant:34],
                ]];
            }
            l.text = text;
            l.backgroundColor = color;
        } @catch (NSException *e) { XPLog(@"徽标异常: %@", e.reason); }
    });
}


#pragma mark - 屏幕日志面板（无越狱也能看）

static UIView *gDiagBox;
static UITextView *gDiagText;

static NSString *XPStageName(void) {
    return gInstalled ? @"已接管" : @"等待类";
}

static void XPDiagTick(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = nil;
        for (UIWindow *cand in [UIApplication sharedApplication].windows.reverseObjectEnumerator) {
            if (cand.isKeyWindow) { w = cand; break; }
        }
        if (!w) w = [UIApplication sharedApplication].windows.firstObject;
        if (!w) return;

        if (!gDiagBox) {
            UIView *box = [UIView new];
            box.tag = 0x58504B02;
            box.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
            box.layer.cornerRadius = 8;
            box.translatesAutoresizingMaskIntoConstraints = NO;
            UITextView *tv = [UITextView new];
            tv.backgroundColor = [UIColor clearColor];
            tv.textColor = [UIColor colorWithWhite:0.95 alpha:1];
            tv.font = [UIFont fontWithName:@"Menlo" size:8.5] ?: [UIFont systemFontOfSize:8.5];
            tv.editable = NO;
            tv.scrollEnabled = YES;
            tv.translatesAutoresizingMaskIntoConstraints = NO;
            [box addSubview:tv];
            [NSLayoutConstraint activateConstraints:@[
                [tv.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:5],
                [tv.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-5],
                [tv.topAnchor constraintEqualToAnchor:box.topAnchor constant:5],
                [tv.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-5],
            ]];
            [w addSubview:box];
            [NSLayoutConstraint activateConstraints:@[
                [box.trailingAnchor constraintEqualToAnchor:w.trailingAnchor constant:-6],
                [box.topAnchor constraintEqualToAnchor:w.topAnchor constant:52],
                [box.widthAnchor constraintEqualToConstant:214],
                [box.heightAnchor constraintEqualToConstant:300],
            ]];
            gDiagBox = box;
            gDiagText = tv;
        } else if (gDiagBox.superview != w) {
            [w addSubview:gDiagBox];
        }
        [w bringSubviewToFront:gDiagBox];

        NSMutableString *txt = [NSMutableString string];
        [txt appendFormat:@"host: %@\nstage: %@\n----\n",
             [[NSBundle mainBundle] bundleIdentifier] ?: @"?", XPStageName()];
        NSArray *snap;
        @synchronized (gLines) { snap = [gLines copy]; }
        NSUInteger from = snap.count > 24 ? snap.count - 24 : 0;
        for (NSUInteger i = from; i < snap.count; i++) {
            [txt appendFormat:@"%@\n", snap[i]];
        }
        gDiagText.text = txt;
    });
}

#pragma mark - 入口

%ctor {
    // dyld 加载期只做最轻的事：装崩溃取证 + 一行日志
    XPInstallCrashHandlers();
    XPLog(@"=== 载入 pid=%d host=%@ ===", getpid(), [[NSBundle mainBundle] bundleIdentifier]);

    // 屏幕日志（轻量，1.5s 一刷）
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *t) { XPDiagTick(); }];
    });

    // 等 App 真正起来再开始探测
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        XPLog(@"启动完成，开始探测插件类");
        __block int tries = 0;
        NSTimer *boot = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            @try { XPInstall(); } @catch (NSException *e) { XPLog(@"安装异常: %@", e.reason); }
            if (gInstalled) {
                static BOOL badged;
                if (!badged) {
                    badged = YES;
                    XPBadge(@"XP 已接管", [UIColor colorWithRed:0.05 green:0.6 blue:0.45 alpha:1]);
                }
            }
            if (++tries % 10 == 0) XPLog(@"探测中 %d 次 installed=%d", tries, gInstalled);
            if (tries > 60) {
                [t invalidate];
                XPLog(@"探测结束 installed=%d", gInstalled);
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:boot forMode:NSRunLoopCommonModes];
    }];
}
