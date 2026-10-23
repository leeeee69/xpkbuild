// Tweak.xm — 新版浮窗接管层
// 不重写业务逻辑，只替换视图层：
//   1) 找到原始面板控制器类（实现 openPanel / blendSwitch / refreshStatus 的类）
//   2) 原类照常运行，但把它的 card 隐藏（状态机保留）
//   3) 在宿主窗口挂 XPPanel，状态从原控制器 KVC 读取，操作回放原选择子

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "XPPanel.h"

static NSMapTable<id, XPPanel *> *gPanels;
static NSTimer *gSyncTimer;

static NSMapTable<id, XPPanel *> *XPPanels(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gPanels = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory
                                        valueOptions:NSPointerFunctionsStrongMemory];
    });
    return gPanels;
}

static id XPSafeGet(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

#pragma mark - 类探测

static Class XPFindPanelClass(void) {
    static Class found;
    if (found) return found;
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        Class c = classes[i];
        if (!c) continue;
        if (class_getInstanceMethod(c, @selector(openPanel)) &&
            class_getInstanceMethod(c, @selector(blendSwitch)) &&
            class_getInstanceMethod(c, @selector(refreshStatus))) {
            found = c;
            break;
        }
    }
    free(classes);
    return found;
}

#pragma mark - 展示

static void XPPresent(id controller) {
    if (!controller) return;

    UIView *host = XPSafeGet(controller, @"hostWindow");
    if (![host isKindOfClass:[UIView class]]) {
        UIView *card = XPSafeGet(controller, @"card");
        host = [card isKindOfClass:[UIView class]] ? card.superview : nil;
    }
    if (!host) return;

    // 旧面板隐藏，但对象与状态机保留
    UIView *card = XPSafeGet(controller, @"card");
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

        if (!gSyncTimer) {
            gSyncTimer = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
                for (id key in XPPanels()) {
                    [[XPPanels() objectForKey:key] refresh];
                }
            }];
            [[NSRunLoop mainRunLoop] addTimer:gSyncTimer forMode:NSRunLoopCommonModes];
        }
    }

    panel.hidden = NO;
    [host bringSubviewToFront:panel];
    [panel updateWidth:MIN(host.bounds.size.width - 24, 420)];
    [panel refresh];
}

#pragma mark - 钩子

static IMP XPOrigOpenPanel, XPOrigRefreshStatus, XPOrigRefreshMeters,
           XPOrigRefreshLicense, XPOrigRefreshLocal, XPOrigUpdateBlend, XPOrigToggleDiag;

static void XPHookOpenPanel(id self, SEL _cmd) {
    if (XPOrigOpenPanel) ((void (*)(id, SEL))XPOrigOpenPanel)(self, _cmd);
    XPPresent(self);
}

static void XPHookRefreshStatus(id self, SEL _cmd) {
    if (XPOrigRefreshStatus) ((void (*)(id, SEL))XPOrigRefreshStatus)(self, _cmd);
    [[XPPanels() objectForKey:self] refresh];
}

static void XPHookRefreshMeters(id self, SEL _cmd, id snap) {
    if (XPOrigRefreshMeters) ((void (*)(id, SEL, id))XPOrigRefreshMeters)(self, _cmd, snap);
    [[XPPanels() objectForKey:self] refresh];
}

static void XPHookRefreshLicense(id self, SEL _cmd) {
    if (XPOrigRefreshLicense) ((void (*)(id, SEL))XPOrigRefreshLicense)(self, _cmd);
    [[XPPanels() objectForKey:self] refresh];
}

static void XPHookRefreshLocal(id self, SEL _cmd) {
    if (XPOrigRefreshLocal) ((void (*)(id, SEL))XPOrigRefreshLocal)(self, _cmd);
    [[XPPanels() objectForKey:self] refresh];
}

static void XPHookUpdateBlend(id self, SEL _cmd) {
    if (XPOrigUpdateBlend) ((void (*)(id, SEL))XPOrigUpdateBlend)(self, _cmd);
    [[XPPanels() objectForKey:self] refresh];
}

static void XPHookToggleDiag(id self, SEL _cmd) {
    if (XPOrigToggleDiag) ((void (*)(id, SEL))XPOrigToggleDiag)(self, _cmd);
    [[XPPanels() objectForKey:self] refresh];
}

static void XPReplace(Class c, SEL sel, IMP hook, IMP *store) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    if (store) *store = method_getImplementation(m);
    method_setImplementation(m, hook);
}

static void XPInstall(void) {
    static BOOL installed;
    if (installed) return;
    Class c = XPFindPanelClass();
    if (!c) return;
    installed = YES;

    XPReplace(c, @selector(openPanel), (IMP)XPHookOpenPanel, &XPOrigOpenPanel);
    XPReplace(c, @selector(refreshStatus), (IMP)XPHookRefreshStatus, &XPOrigRefreshStatus);
    XPReplace(c, @selector(refreshLicenseUI), (IMP)XPHookRefreshLicense, &XPOrigRefreshLicense);
    XPReplace(c, @selector(refreshLocalVideoControls), (IMP)XPHookRefreshLocal, &XPOrigRefreshLocal);
    XPReplace(c, @selector(updateBlendControls), (IMP)XPHookUpdateBlend, &XPOrigUpdateBlend);
    XPReplace(c, @selector(toggleDiagnostics), (IMP)XPHookToggleDiag, &XPOrigToggleDiag);
    XPReplace(c, @selector(refreshMetersWithSnapshot:), (IMP)XPHookRefreshMeters, &XPOrigRefreshMeters);
}

#pragma mark - 入口

%ctor {
    __block int tries = 0;
    NSTimer *boot = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        XPInstall();
        if (++tries > 40) [t invalidate];
    }];
    [[NSRunLoop mainRunLoop] addTimer:boot forMode:NSRunLoopCommonModes];
}
