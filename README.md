# XPPanelKit — 小潘推流助手 · 浮窗视图层重构

把原插件里手写的旧面板（金色、单行状态、卡片套卡片）换成 `DESIGN-SPEC.md` 的青玉主题结构。
**只换视图层**：授权、视频管线、音频接管、诊断逻辑全部沿用原实现。

## 为什么是一个新 dylib，而不是直接改原 dylib

原面板是 ObjC 编译进 `__TEXT` 的 UIKit 代码（`openPanel` 约 2000 条指令，`refreshStatus` 2332 条），
没有任何 nib/storyboard。改设计等于重写这段视图树，只能回到源码层编译——二进制里逐条指令替换做不出新结构。
所以采用**伴随 tweak**：原 dylib 继续跑状态机，这一层接管显示。

## 结构

```
Tweak.xm      类探测 + 7 个方法钩子 + 宿主窗口挂载
XPPanel.m     新视图树（头部/状态/画面替换/页签/画面页/声音页/诊断/底部/授权页/更多页/收起胶囊）
XPPanel.h     面板接口
XPTheme.h     设计令牌（颜色、字号、圆角、间距）
XPPanelKit.plist  注入的宿主 App 白名单
```

## 数据与交互怎么走

- **读**：`[controller valueForKey:@"blendSwitch"]` 等，直接读原控件状态（原控件被隐藏但仍在刷新）。
- **写**：调用原选择子 `toggleBlend` / `changeTab` / `changeVideoTransport` / `selectLocalVideo` /
  `changeLocalDisplayMode` / `changeLocalLoop` / `changeInternalRecording` / `openLicensePanel` /
  `activateLicense` / `toggleDiagnostics` / `toggleMoreVideoSettings` / `toggleMirror` 等。
- **刷新**：钩 `refreshStatus`、`refreshMetersWithSnapshot:`、`refreshLicenseUI`、
  `refreshLocalVideoControls`、`updateBlendControls`、`toggleDiagnostics`，另加 0.3s 兜底同步。

## 构建

### A. 本地（macOS + Theos）

```bash
export THEOS=~/theos
make clean && make package FINALPACKAGE=1
# 产物：packages/com.xiaopan.panelkit_1.0.0_iphoneos-arm.deb
```

### B. 无 Mac：GitHub Actions

仓库里已带 `.github/workflows/build.yml`，推上去即可在 `theos` 容器里编译，产物从 Artifacts 下载。

### C. 只出 dylib（不用 deb）

```bash
make clean && make
# .theos/obj/arm64/XPPanelKit.dylib
```

## 安装

- 越狱：`dpkg -i` 后 respring；过滤器已含抖音/TikTok/小红书/斗鱼/YY/微信。
- TrollStore：用 TrollFools 把 `XPPanelKit.dylib` 注入宿主 App（与原来的 `小潘-v1.6.30.dylib` 一起注入）。

## 验收清单（对应 DESIGN-SPEC 第 7/8 节）

- [ ] 宽度 366 / 420 不溢出，长文案不截断
- [ ] 内容超高时面板内滚动，头部跟随滚动不丢
- [ ] 四种状态（等待画面 / 已接收 / 直连未检测 / 替换关闭）点色与文案正确
- [ ] 未授权：开关不可用、就地说明、不自动跳授权页
- [ ] 内录守卫弹回后，开关状态与原实现一致
- [ ] 诊断默认收起，展开后日志可滚
- [ ] 收起为胶囊，点击恢复，设置不丢
- [ ] 拖动（原实现的头部手势仍作用在隐藏视图上，需要的话在 `XPPanel` 头部补一个 pan 手势并写同一个 UserDefaults 键）

## 已知需要按实机确认的点

1. **KVC 键名**：`hostWindow` / `card` / `blendSwitch` / `blendSlider` / `localLoopSwitch` /
   `internalRecordingSwitch` / `licenseStateLabel` / `licenseDetailLabel` / `licenseCodeField` /
   `localSelectButton` / `audioLabel` / `audioWarningLabel` / `activeVideoTransportMode`。
   这些来自对 `小潘-v1.6.30.dylib` 的方法表还原，**个别键若不存在会走兜底分支**（读不到就保留默认文案，不会崩）。
2. **来源切换**：原实现是「循环切换」，本层用最多 3 次调用对齐目标档位；若原实现改成绝对赋值，这里要跟着简化。
3. **显示方式**：`localDisplayMode` 键若不存在则不做切换（避免误切两次回到原点）。
4. **风险说明**：调用了 `openRiskNotice`，该选择子未在方法表里确认，不存在时静默跳过；需要的话替换为实际的入口选择子。
5. **拖动**：新头部未接 pan 手势（见验收清单最后一条）。

## 回滚

不装这个 tweak 即回到原面板；两者互不修改文件。

---

# twcrack — TianWen 带人脸版破甲

`twcrack/` 是同一套分析流程的产物，目标为 `TianWen带人脸.dylib`（`@rpath/FrameXiang.dylib`，arm64，iOS 14.0+），
授权判定纯本地：**三个全局量 + 两道 C 判据**，签名/证书固定只服务联网验证。

```
twcrack/
  Tweak.xm      运行时 hook（v3：直接种 3 个门控全局量，覆盖 Swift 内联调用不到的选择子）
  Makefile      Theos 构建
  control       deb 包元信息
  REPORT.md     v2 深度复核 × v3 net0 完整报告（判据清单、补丁表、出口穷举）
  patches/      静态补丁脚本（等长字节替换，离线可用）
    patch_tianwen.py        v1：5 处 / 39 字节
    patch_tianwen_net0.py   v3：追加 4 个 HTTP 出口封死 + base URL 黑洞
  evidence/     反汇编证据、方法表、选择子清单、差分证明
  dist/         成品 dylib（未签名，按需自签/注入）
```

## 门控模型

| 全局量 | 偏移 | 语义 |
|---|---|---|
| `_LCGateEnabled` | `0x13c1d38` | Ed25519 信封验签通过 |
| `_LCGateForeground` | `0x13c1d39` | 前台租约新鲜 |
| `_LCGateDeadline` | `0x13c1d40` | 到期时刻（`_LCUptime` 时基） |

`valid = flagA && flagB && now < deadline`。写入侧被 `changeState:message:` 冲掉，所以只改读取侧。
面板 5 条可达路径（`start`/`heartbeat`/`tick`/`logout`/授权按钮）已统一收口到 `-showPanel`。

## 补丁与构建

```bash
# 静态补丁（输出 cracked dylib）
python3 twcrack/patches/patch_tianwen_net0.py TianWen带人脸.dylib -o out.dylib

# 运行时 tweak
cd twcrack && THEOS=~/theos make package FINALPACKAGE=1
```

GitHub Actions 走 macOS runner 自动出 deb/dylib，产物在 Artifacts。

## 边界

- RTMP 推流**不受影响**：走 ffmpeg `libavformat/rtmppkt.c` socket 层，与所改 4 处无关。
- net0 版除 RTMP 外**零 HTTP 请求**（出口穷举见 `evidence/`）。
- `dist/` 为未签名产物，注入前自行 `codesign`/`ldid`。
