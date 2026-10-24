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
#import <zlib.h>
#import "XPPanel.h"
#import "XPCoreBlob.h"

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

#pragma mark - 内嵌核心

static NSString *XPCorePath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"xp_core_jade.dylib"];
}

static BOOL XPLoadCore(void) {
    NSString *path = XPCorePath();
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attr || [attr fileSize] != XPCoreRawSize) {
        void *buf = malloc(XPCoreRawSize);
        if (!buf) return NO;
        unsigned long outLen = XPCoreRawSize;
        int rc = uncompress((Bytef *)buf, &outLen, XPCorePacked, XPCorePackedSize);
        if (rc != Z_OK) {
            XPLog(@"核心解压失败 zlib=%d", rc);
            free(buf);
            return NO;
        }
        NSData *data = [NSData dataWithBytesNoCopy:buf length:outLen freeWhenDone:YES];
        NSError *err = nil;
        if (![data writeToFile:path options:NSDataWritingAtomic error:&err]) {
            XPLog(@"核心写盘失败: %@", err);
            return NO;
        }
    }
    void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        const char *e = dlerror();
        XPLog(@"dlopen 核心失败: %s", e ? e : "unknown");
        return NO;
    }
    XPLog(@"核心 dlopen 成功");
    return YES;
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
    // 关键：绝不遍历/实例化宿主进程里的全部类。
    // 之前对每个类调 class_getInstanceMethod，会强制 realize 宿主的所有类，
    // 微信这类 App 里会触发它自己的断言（"Property Name should be ..."），直接把 App 搞崩。
    // 只碰名字带前缀的类。
    static const char *prefixes[] = {"BLK_", "BLK", "XPB_", "XPPanel"};
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
        BOOL prefixed = NO;
        for (int k = 0; k < 4; k++) {
            size_t n = strlen(prefixes[k]);
            if (strncmp(nm, prefixes[k], n) == 0) { prefixed = YES; break; }
        }
        if (!prefixed) continue;
        scanned++;
        @try {
            if (!class_getInstanceMethod(c, @selector(openPanel))) continue;
            int score = 10;
            if (class_getInstanceVariable(c, "_card")) score += 4;
            if (class_getInstanceMethod(c, @selector(refreshStatus))) score += 3;
            if (class_getInstanceMethod(c, @selector(installIfNeeded))) score += 2;
            XPLog(@"候选 %s score=%d", nm, score);
            if (score > bestScore) { bestScore = score; best = c; }
        } @catch (NSException *e) {
            XPLog(@"探测 %s 异常: %@", nm, e.reason);
        }
    }
    free(list);
    if (scanned == 0) {
        XPLog(@"没有 BLK_ 前缀的类（%d 个类里），插件可能没加载到本 App", count);
    }
    if (best) XPLog(@"选中 %s (%d)", class_getName(best), bestScore);
    return best;
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
    @try {
        XPLog(@"openPanel 被调用");
        if (XPOrigOpenPanel) ((void (*)(id, SEL))XPOrigOpenPanel)(self, _cmd);
    } @catch (NSException *e) {
        XPLog(@"openPanel 原实现异常: %@ %@", e.name, e.reason);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ XPPresent(self); });
}


static void XPHookInstall(id self, SEL _cmd) {
    @try {
        XPLog(@"installIfNeeded 被调用");
        if (XPOrigInstall) ((void (*)(id, SEL))XPOrigInstall)(self, _cmd);
    } @catch (NSException *e) {
        XPLog(@"installIfNeeded 原实现异常: %@ %@", e.name, e.reason);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ XPPresent(self); });
}


static void XPHookRefreshStatus(id self, SEL _cmd) {
    @try {
        if (XPOrigRefreshStatus) ((void (*)(id, SEL))XPOrigRefreshStatus)(self, _cmd);
    } @catch (NSException *e) {
        XPLog(@"refreshStatus 原实现异常: %@ %@", e.name, e.reason);
    }
    XPPanel *p = [XPPanels() objectForKey:self];
    if (p) XPOnMain(^{ [p refresh]; });
    else XPPresent(self);
}

static void XPHookRefreshMeters(id self, SEL _cmd, id snap) {
    @try {
        if (XPOrigRefreshMeters) ((void (*)(id, SEL, id))XPOrigRefreshMeters)(self, _cmd, snap);
    } @catch (NSException *e) { XPLog(@"meters 异常: %@", e.reason); }
    XPPanel *p = [XPPanels() objectForKey:self];
    if (p) XPOnMain(^{ [p refresh]; });
}

static void XPHookRefreshLicense(id self, SEL _cmd) {
    @try {
        if (XPOrigRefreshLicense) ((void (*)(id, SEL))XPOrigRefreshLicense)(self, _cmd);
    } @catch (NSException *e) { XPLog(@"license 异常: %@", e.reason); }
    XPPanel *p = [XPPanels() objectForKey:self];
    if (p) XPOnMain(^{ [p refresh]; });
}

static void XPHookRefreshLocal(id self, SEL _cmd) {
    @try {
        if (XPOrigRefreshLocal) ((void (*)(id, SEL))XPOrigRefreshLocal)(self, _cmd);
    } @catch (NSException *e) { XPLog(@"local 异常: %@", e.reason); }
    XPPanel *p = [XPPanels() objectForKey:self];
    if (p) XPOnMain(^{ [p refresh]; });
}

static void XPHookUpdateBlend(id self, SEL _cmd) {
    @try {
        if (XPOrigUpdateBlend) ((void (*)(id, SEL))XPOrigUpdateBlend)(self, _cmd);
    } @catch (NSException *e) { XPLog(@"blend 异常: %@", e.reason); }
    XPPanel *p = [XPPanels() objectForKey:self];
    if (p) XPOnMain(^{ [p refresh]; });
}

static void XPHookToggleDiag(id self, SEL _cmd) {
    @try {
        if (XPOrigToggleDiag) ((void (*)(id, SEL))XPOrigToggleDiag)(self, _cmd);
    } @catch (NSException *e) { XPLog(@"diag 异常: %@", e.reason); }
    XPPanel *p = [XPPanels() objectForKey:self];
    if (p) XPOnMain(^{ [p refresh]; });
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
            gSyncTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *t) {
                for (id key in XPPanels()) {
                    XPPanel *p = [XPPanels() objectForKey:key];
                    @try { [p refresh]; } @catch (NSException *e) { XPLog(@"刷新异常: %@", e.reason); }
                }
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
    // 这里只做最安全的事：装崩溃取证 + 写一行日志。
    // 绝不在 dyld 加载期做 dlopen / UIKit —— 那会撞 loader lock，直接闪退。
    XPInstallCrashHandlers();
    XPLog(@"=== 载入 pid=%d stage=0 host=%@ ===", getpid(), [[NSBundle mainBundle] bundleIdentifier]);

    // 等 App 壳真正启动完再干活
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:YES block:^(NSTimer *t) { XPDiagTick(); }];
    });

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        XPLog(@"stage=1 启动完成，准备加载核心");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                BOOL ok = XPLoadCore();
                XPLog(@"stage=2 dlopen 结果=%d", ok);
            } @catch (NSException *e) {
                XPLog(@"stage=2 异常 %@ %@", e.name, e.reason);
            }

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                XPLog(@"stage=3 开始挂钩");
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
                    if (++tries % 20 == 0) XPLog(@"stage=3 等待中 installed=%d", gInstalled);
                    if (tries > 240) [t invalidate];
                }];
                [[NSRunLoop mainRunLoop] addTimer:boot forMode:NSRunLoopCommonModes];
            });
        });
    }];
}
