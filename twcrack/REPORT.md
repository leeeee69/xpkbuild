# TianWen 带人脸.dylib — 逆向破甲报告（v2 · 深度复核版）

样本：`E:\破甲集\TianWen带人脸.dylib`
成品：`TianWen带人脸-cracked.dylib`（**6 处 / 39 字节** 等长静态补丁，离线可用）

---

## 0. 结论

授权是**纯本地的三个全局量 + 两道 C 判据**，签名/证书固定只服务于联网验证这条路。
本版（v3 / `-net0`）在 v2 破甲基础上，把**除 RTMP 外的全部 HTTP 出口**封死，并给出出口穷举证据。

| 复核项 | 结果 |
|---|---|
| `__TEXT` 主业务能否绕过 C 函数直接读门控字节 | **不能**（ADR 越界、ADRP 目标页仅 1 处且在 `__TWTEXT`），无隐蔽判据 |
| 数据段里有没有函数指针/门控地址的间接引用 | **没有**，仍只有那 4 个读点 |
| 主机侧拿到授权状态的通道 | **就是 `[TWLicenseManager valid]`**（`TWSetAuthorizationHandler` 回调参数），所以 `valid` 必须改 |
| 面板会不会自己弹 | `start`/`heartbeat`/`tick`/`logout`/授权按钮共 5 条路径可达 `-showPanel`，v2 已统一收口 |
| 是否引发网络风暴 | v3 起直接**零 HTTP 请求**：4 个 session/dataTask 出口全封 + base URL 黑洞 |
| HTTP 出口总数 | **4 个**（授权 / 卡包支付 / 更新下载 / **plugin-auth 隐蔽客户端**），已全部封死 |
| RTMP 是否受影响 | **不受影响**：推流走 ffmpeg `libavformat/rtmppkt.c` 的 socket 层，不经过被改的 4 处 |

---

## 1. 样本指纹

| 项 | 值 |
|---|---|
| 大小 | 3,115,376 B |
| SHA-256（原） | `10c87c87110a238b41fa12836127c340898bf6c5fca01223da92fcd86dbb84b6` |
| 格式 | Mach-O 64 / **arm64** 单架构 / `filetype=6` DYLIB |
| ID | `@rpath/FrameXiang.dylib` |
| 平台 | `platform=2`（iOS），minos **14.0**，SDK 18.5 |
| UUID | `1b76267f-8112-86da-3e8d-c6da238390c6` |
| 加密 | `LC_ENCRYPTION_INFO_64 cryptid=0`（未加密） |
| 语言 | ObjC + C（宿主业务约 1.4 MB），Swift 仅作为 CryptoKit/Foundation 依赖 stub 出现 |

段布局：

| 段 | VA | 文件偏移 | 内容 |
|---|---|---|---|
| `__TEXT` | 0x0 | 0x0 | 宿主业务代码（FX\*，`__text` 0x4000+0x1467dc） |
| `__DATA`/`__DATA_CONST` | 0x264000 | — | ObjC 元数据、常量、大段 base64 |
| **`__TWTEXT`** | **0x1388000** | **0x2a0000** | **授权模块，`__text` 仅 0x9bb4（14 个函数）** |
| `__TWCONST` | 0x13bc000 | 0x2d4000 | 授权常量/CFString |
| **`__TWDATA`** | **0x13c0000** | 0x2d8000 | selrefs / objc_data / **`__bss` 门控量（0x13c1d28 起）** |
| `__LINKEDIT` | 0x13c4000 | 0x2dc000 | 符号、签名 |

---

## 2. 授权体系

### 2.1 数据面

| 符号 | VA | 类型 | 语义 | 写入者 |
|---|---|---|---|---|
| `_LCGateEnabled` | `0x13c1d38` | `_Atomic uint8` | 信封（Ed25519）验签通过 | `changeState:message:` 0x138f5d0 / 0x138f5f0 |
| `_LCGateForeground` | `0x13c1d39` | `_Atomic uint8` | 前台租约新鲜 | `applyLease:foregroundEpoch:`、`start`、`enteredBackground`、`becameActive`、activate/heartbeat block |
| `_LCGateDeadline` | `0x13c1d40` | `_Atomic double` | 到期时刻（`_LCUptime` 同一时基） | `changeState:message:` 0x138f5c0 / 0x138f604 |
| `_TWReady` | `0x13c1d58` | `_Atomic uint8` | **hook 是否装成功**（非授权） | `_TWFrameBootstrap` 0x1394fd0 |
| `_TWInstalled` | `0x13c1d59` | `uint8` | 安装 CAS 标志 | `_TWFrameBootstrap` 头部 |
| `_TWPanel` | `0x13c1d88` | `__weak id` | 面板弱引用（未授权时恒 nil） | `_TWLoaded` / `showPanel` |

`changeState:message:`（0x138f510）的写门控片段：

```
0x138f5a0  tbz  w20,0,0x138f5dc       ; state & 1
0x138f5a8  ...  [self deadline]
0x138f5bc  fmov x9,d0
0x138f5c0  stlr x9,[x8]               ; _LCGateDeadline = deadline
0x138f5d0  stlrb w9,[x8]              ; _LCGateEnabled  = 1
   …else…
0x138f5f0  stlrb wzr,[x8]             ; _LCGateEnabled  = 0
0x138f604  stlr xzr,[x8]              ; _LCGateDeadline = 0
```

→ 运行期「播种标志」的破解必然被它冲掉，**必须改读取侧**。

### 2.2 判据全量清单（ADR 引用穷举 + 数据段验证，无遗漏）

| 判据 | VA | 读什么 | 调用者 |
|---|---|---|---|
| `-[TWLicenseManager valid]` | `0x138f4b4` | 3 个量 | **7 处**：heartbeat block 0x13913d0、remaining 0x139157c、displayStatus 0x13916f4、showPanel 0x13921bc、showPanel block 0x1392244、TWLicensePanel.update 0x1393b7c、**`_TWSetAuthorizationHandler` block 0x1394ca8** |
| `_TWIsAuthorized()` | **`0x1394220`** | 3 个量 | `_TWCapture` 0x1395914、`_TWRefreshPanel` 0x1395280、`_TWFrameAllowed` 尾调用 |
| `_TWFrameAllowed()` | **`0x1394d08`** | `_TWReady` + 上面那个 | 主业务 `func.0x87c4 @0x87e8`（写进采集状态快照 `[x20+1]`） |
| `_TWRequireAuthorization()` | `0x13949a8` | 3 个量 | **xref = 0（死代码）**，patch 保留无害 |
| `-[TWLicensePanel proceed]` | `0x13941a0` | 3 个量 | 面板「继续」按钮（通过则 dismiss，纯 UI） |
| `-[TWLicenseManager changeState:message:]` | `0x138f510` | 写 3 个量 | 状态机 |
| `-[TWLicenseManager tick]` | `0x13914b4` | **`authorized` ivar** | 计时驱动器 |
| `-[TWLicenseManager heartbeat]` | `0x1391034` | `busy` / `token` | 心跳 |
| `-[TWLicenseManager start]` | `0x138fce0` | `isMainThread`/`started`/`bundleIdentifier`/URL 校验 | 启动 |

`valid` 的关键反汇编：

```
0x138f4b4 adr x8,#0x13c1d38 / ldarb / cmp #1 / b.ne fail
0x138f4c8 adr x8,#0x13c1d39 / ldarb / cmp #1 / b.ne fail
0x138f4e4 bl  _LCUptime
0x138f4e8 adr x8,#0x13c1d40 / ldar / fmov / fcmp / cset w0,mi / ret
```

`_TWFrameAllowed`（主业务门）：

```
0x1394d08 adr x8,#0x13c1d58 / ldarb / cmp #1 / b.ne 0x1394d20
0x1394d1c b  _TWIsAuthorized
0x1394d20 mov w0,0 ; ret
```

`_TWFresh` 语义澄清（v1 报告曾把它当未知写入者，已补正）：`_TWReady` 由 `_TWFrameBootstrap` 尾部写成：

```
0x1394fc4 bl  _TWReplace
0x1394fc8 adr x8,#0x13c1d58
0x1394fd0 stlrb w22,[x8]        ; = 11 次 TWReplace 是否全部成功
0x1394fd4 tbz w22,0,0x1394fec
```

### 2.3 主机侧拿状态的真实通道（新证据）

`_TWSetAuthorizationHandler` 注册的回调，触发时传的参数**就是 `valid`**：

```
0x1394c8c  [TWLicenseManager shared]
0x1394ca8  ldr x1, selref."valid"
0x1394cac  objc_msgSend            ; w0 = [shared valid]
0x1394cb0  mov x1,x0
0x1394cb4  ldr x8,[x20,#0x10]
0x1394cbc  blr x8                   ; handler(valid)
```

→ 宿主 UI / 功能开关走的是 `valid`，不是 `authorized` ivar。**这解释了为什么只改 `TWIsAuthorized` 不够**：C 采集放行了，但宿主回调仍收到 `NO`，界面依旧显示未授权 / 入口行为异常。

### 2.4 网络面（补：第二个 base URL）

| 项 | 值 |
|---|---|
| 主 base | `https://www.ybdskj.top` |
| **备用 base（新发现）** | **`https://139.196.169.34/tianwen-framexiang-20261030`**（`__TWTEXT.__cstring VA 0x1395f5b`，`start` 里用 `_LCValidHTTPS` + `hasSuffix:` 校验后使用；`request:` 直接用它拼 `/api/v1/*`） |
| 端点 | `/api/v1/{challenge,activate,lease,config,logout}`、`/api/register`、`/api/ios/plugin/`、`/api/ios/update/{check,download}`、`/api/payment_plans?software_id=ios_injection` |
| 令牌 | `LIC2\n<6 段>`（`0x13b6dcf` 区） |
| 验签 | `CryptoKit.Curve25519.Signing.PublicKey.isValidSignature` + `SecKeyCreateSignature`/Keychain 私钥 |
| 租约校验 | `lease_seconds(0,90]`、`heartbeat_seconds(0,30]`、`expires_at ≥ server_time`、`lease_seconds ≤ expires_at − server_time` |
| 证书固定 | `SecTrustSetAnchorCertificates` + `SecTrustEvaluate`（仅联网路径） |

`hasSuffix:` 绑定意味着：改 base URL 而不改后缀会直接落到「授权地址配置无效」并弹面板 —— 这是厂商对换服务器的一种弱防护，与本方案（不联网）无关。

### 2.5 反调试 / 反篡改（补：混淆调用已查清）

| 项 | 结论 |
|---|---|
| 自校验（`SecStaticCodeCheckValidity` / `csops` / 自身哈希） | **无**。`module_text_sha256`/`target_sha256` 是授权载荷绑定字段 |
| 反调试 `ptrace` | 无 |
| `sysctl` | 全二进制仅 1 处（`0x94fe4`），属媒体库，非授权模块 |
| 越狱检测字符串 | 未命中 |
| `_TWFrameBootstrap` 里 `dladdr(&TWFrameBootstrap)+0x13dcbc` 的 `blr` | **不是完整性校验**。目标是本镜像 `__TEXT` 内的 `0x13dcbc`，函数体是「两个 `dispatch_once` + `dispatch_async(main)` 的惰性初始化派发器」，用于强制 Swift 惰性全局初始化。属于取址混淆，不影响打补丁 |

### 2.6 覆盖性证明（三项，缺一不可）

1. **`__TEXT` 无法直视门控字节**
   - 门控字节在 `0x13c1d38`（页 `0x13c1000`）。`__TEXT.__text` 位于 `0x4000–0x14a800`，ADR 偏移上限 ±1 MB → 不可达（0x13c1d38 − 0x14a800 = 0x1275538）。
   - 全二进制扫描：ADRP 命中页 `0x13c1000` 仅 **1 处**（`0x138c060`，在 `__TWTEXT`）；命中页 `0x13c0000` 的 33 处均指向 `__TWDATA` 的 objc 元数据（selrefs/classrefs/const），不含门控偏移。
2. **没有间接引用**：在 `__DATA`/`__DATA_CONST`/`__TWDATA` 全量搜 8 字节常量 `0x13c1d38/39/40/58/59/88`、`0x1394220/0x1394d08/0x13949a8` → **0 命中**（无 GOT 指针、无回调表）。
3. **采集只有一条门**：`_TWVideoCapture`（0x139549c）与 `_TWAudioCapture`（0x13954a8）都是 `b _TWCapture` 的 thunk，分别把原实现塞进 `x5`；`_TWCapture` 内部才是 `_TWReady && _TWIsAuthorized`。

→ 因此「改 4 个判据 + 1 分支」在功能面上是完备的，不存在第五条隐藏判据。

---

## 3. 补丁方案（6 处 / 39 字节）

指令编码：`mov w0,#1` = `52800020` → LE `20 00 80 52`；`ret` = `D65F03C0` → LE `C0 03 5F D6`；`nop` = `D503201F` → LE `1F 20 03 D5`。

| # | 目标 | VA | 文件偏移 | 原字节 | 新字节 | 说明 |
|---|---|---|---|---|---|---|
| 1 | `_TWIsAuthorized` | `0x1394220` | `0x2ac220` | `c8d81610 1f2003d5` | `20008052 c0035fd6` | C 层唯一判据，覆盖 `_TWCapture`/`_TWRefreshPanel`/`_TWFrameAllowed` |
| 2 | `_TWFrameAllowed` | `0x1394d08` | `0x2acd08` | `88821610 1f2003d5` | `20008052 c0035fd6` | 主业务 `0x87e8` 直接调用 |
| 3 | `_TWRequireAuthorization` | `0x13949a8` | `0x2ac9a8` | `fd7bbfa9 fd030091` | `20008052 c0035fd6` | 死代码，防御性置真 |
| 4 | `-[TWLicenseManager valid]` | `0x138f4b4` | `0x2a74b4` | `28441910 1f2003d5` | `20008052 c0035fd6` | **主机回调拿的就是它**（7 个调用点） |
| 5 | `_TWCapture` 的 `_TWReady` 判断 | `0x1395910` | `0x2ad910` | `61010054` | `1f2003d5` | 加固：bootstrap 失败时也不影响采集 |
| 6 | `-[TWLicenseManager showPanel]`（v2 新增） | `0x1391f64` | `0x2a9f64` | `ffc301d1`（`sub sp,sp,#0x70`） | `c0035fd6`（`ret`） | 5 条弹面板路径（start 0x13900b8/0x1390404、heartbeat 0x139144c/0x1391468、tick 0x1391518、logout 0x1391a6c、授权按钮 `_TWShow`）统一收口 |

不改 `_LCGate*` 的原因：它们在 `__bss`（文件偏移 0，运行期清零），且 `changeState:` 会周期性重写。

---

## 4. 验证

### 4.1 字节级 diff

```
len 3115376 == 3115376
diff bytes: 39
offsets:
 0x2a74b4-0x2a74bb   valid
 0x2a9f64-0x2a9f67   showPanel
 0x2ac220-0x2ac227   TWIsAuthorized
 0x2ac9a8-0x2ac9af   TWRequireAuthorization
 0x2acd08-0x2acd0f   TWFrameAllowed
 0x2ad910-0x2ad913   TWCapture(TWReady 分支)
```

### 4.2 反汇编回读

```
0x01394220  20008052  mov w0,1   ← _TWIsAuthorized
0x01394224  c0035fd6  ret
0x01394d08  20008052  mov w0,1   ← _TWFrameAllowed
0x01394d0c  c0035fd6  ret
0x013949a8  20008052  mov w0,1   ← _TWRequireAuthorization
0x013949ac  c0035fd6  ret
0x0138f4b4  20008052  mov w0,1   ← -[TWLicenseManager valid]
0x0138f4b8  c0035fd6  ret
0x01391f64  c0035fd6  ret        ← -[TWLicenseManager showPanel]（原 sub sp,sp,#0x70）
0x01395910  1f2003d5  nop        ← TWCapture 的 TWReady 分支
```
脚本逐条回读：`ALL_OK = True`（6/6）。

### 4.3 产物

| 文件 | 大小 | SHA-256 |
|---|---|---|
| 原样本 | 3,115,376 | `10c87c87110a238b41fa12836127c340898bf6c5fca01223da92fcd86dbb84b6` |
| **`TianWen带人脸-cracked.dylib`（v2，6 处）** | 3,115,376 | `ecfab1bea6417a78c7e17e548672905565ce715004cfa8cee108fd2ee218acea` |
| **`TianWen带人脸-cracked-net0.dylib`（v3：破甲 + 禁网，12 处）** | 3,115,376 | `a537547c5bebba289df7562572608594b7f8bc4e737bf549c4cea9ec19b1365c` |
| `TianWen带人脸-cracked-v1_5处.dylib`（留档） | 3,115,376 | `6a673ff3ed2ad4504c92e007dfc1f533be4905cc9342e459e8df92196dc44a8f` |

---

## 5. 使用

```bash
cp TianWen带人脸.dylib TianWen带人脸.dylib.bak
cp TianWen带人脸-cracked.dylib TianWen带人脸.dylib
ldid -S TianWen带人脸.dylib                    # 越狱 / amfi off
# TrollStore / 非越狱自签：codesign -f -s - TianWen带人脸.dylib
```

换版本重打：`python patch_tianwen.py <原dylib> <输出>`；任一命中不一致会打印 `MISMATCH`，不会静默写坏。

**换版本定位法（不依赖固定偏移）**

```bash
rabin2 -s X.dylib | grep -E '_TWIsAuthorized|_TWFrameAllowed|_TWRequireAuthorization'
radare2 -q -c 'aa; afl~TWLicenseManager\.valid; afl~showPanel' X.dylib
radare2 -q -c 'aa; s <valid_addr>; pdf' X.dylib          # 确认 3 条 ldarb/cmp 结构没变
```

---

## 6. 残留项（更新）

1. **UI 文案**：`displayStatus` 仍按 `expires/remaining` 渲染（未授权时 deadline=0 → 数值区显示异常）。功能不受影响；要彻底干净可把 `-displayStatus @0x13916d4` 也改成 `ret`。
2. **网络噪音**：无 token 时 `heartbeat` 在 `token` 判空处直接返回，`refresh` 仅在 `start` 的成功路径调用一次；断网时有日志，不弹窗（面板已被 #6 关死）。
3. **`_TWReady`**：等于 hook 安装成功，非授权位；patch #5 属加固。
4. **签名**：改字节后 CMS 必然失效，必须重签（iOS 加载机制，非本 dylib 自检）。
5. **未触碰**：Ed25519 验签、Keychain 密钥、证书锚点、6 段 `LIC2` 令牌 —— 若要改走「伪造离线租约」路线，需替换 `prepareKeys`/`verifyEnvelope:` 的公钥，属另一套工作量。

---

## 7. 复现命令（补充 selector 追踪）

```bash
# 结构
python macho_parse.py TianWen.dylib
rabin2 -I X.dylib; rabin2 -c X.dylib

# 门控字节引用（ADR 穷举，r2 会把 selref/adr 都解出来）
radare2 -q -c 'aa; axt sym._LCGateEnabled; axt sym._LCGateForeground; axt sym._LCGateDeadline' X.dylib
radare2 -q -c 'aa; axt sym._TWReady' X.dylib
radare2 -q -c 'aa; axt sym._TWFrameAllowed; axt sym._TWIsAuthorized; axt sym._TWRequireAuthorization' X.dylib

# 选择子级调用点（对 13b 段里的 methname VA 直接 axt）
radare2 -q -c 'aa; axt 0x13b7722' X.dylib     # valid
radare2 -q -c 'aa; axt 0x13b74a9' X.dylib     # showPanel
radare2 -q -c 'aa; axt 0x13b7297' X.dylib     # authorized
radare2 -q -c 'aa; axt 0x13b7ced' X.dylib     # displayStatus

# 关键函数
radare2 -q -c 'aa; s 0x138f510; pdf' X.dylib   # changeState（唯一写门控）
radare2 -q -c 'aa; s 0x1391034; pdf' X.dylib   # heartbeat（busy/token 早退）
radare2 -q -c 'aa; s 0x13914b4; pdf' X.dylib   # tick（authorized 早退）
radare2 -q -c 'aa; s 0x1394c2c; pdf' X.dylib   # 授权回调 = valid

# 打补丁
python patch_tianwen.py TianWen.dylib out.dylib
```

---

## 8. 版本与差异

| 版本 | 补丁 | 说明 |
|---|---|---|
| v1 | 5 处 / 35 B | 功能已通，但 `showPanel` 的 5 条路径未封，特定配置/异常下仍可能弹面板 |
| v2 | 6 处 / 39 B | 追加 `showPanel → ret`，面板彻底不可达 |
| **v3 `-net0`（本版主交付）** | **12 处 / 113 B** | v2 全部 + 封死 4 个 HTTP 出口 + 2 个 base URL 黑洞，**除 RTMP 外零出网**（见 §9） |
| 历史 TWCrack v1–v3（注入式） | 运行期 hook | ① 播种 `_LCGate*` 会被 `changeState:` 冲回 0；② 主判据是 C 函数，选择子 hook 覆盖不到；③ 未覆盖主机回调用的 `valid` |

---

## 9. 禁网（net0）：除 RTMP 外零 HTTP 请求

### 9.1 HTTP 出口穷举（objc stub 级证据）

`__objc_stubs` 里与网络相关、且**存在调用者**的 stub 一共 5 个，调用者合计 4 个函数，这就是全部分 HTTP 出口：

| # | 出口 | 证据 | 用途 |
|---|---|---|---|
| 1 | `-[TWLicenseManager request:body:kind:completion:]` | stub `dataTaskWithRequest:completionHandler:`(0x14d1c0) 唯一使用者：`0x138db64` | 授权（拼 `base + /api/v1/*`） |
| 2 | `+[FXCommerceRequest fetch:limit:completion:]` | `sessionWithConfiguration:delegate:delegateQueue:`(0x1503e0)@0x12ec0c、`dataTaskWithURL:`(0x14d1e0)@0x12ec50、`resume`(0x1501c0)@0x12ec60 | 卡包 / 支付列表 |
| 3 | `+[FXUpdateTransfer start:release:progress:completion:]` | 同组 stub：0x132a28 / 0x132a64 / 0x132a94 | 更新检查与下载 |
| 4 | `func.0x881c`（C++ 对象构造，`operator new(0x240)` 由 `func.0x75b4` 调用） | `sessionWithConfiguration:`(0x1503c0)@0x8924，session 存入 `[x19+0x88]`；同一函数创建的 GCD 队列名 **`app.framexiang.plugin-auth`** | **插件授权客户端（隐蔽回连通道）** |

> 第 4 条是本次深度排查才暴露的：它不拼 `/api/v1/`、不走 `TWLicenseManager`，队列名直接写明 `plugin-auth`，静态扫 URL 字符串根本扫不到。

### 9.2 RTMP 为什么不受影响

推流走 ffmpeg 内置实现，不经 NSURLSession：

- 字符串证据：`libavformat/rtmppkt.c`、`ffrtmpcrypt`、`ffrtmphttp`、`RTMP packet size mismatch`、`rtmp`/`rtmps` 协议名
- 底层出口：`socket`/`connect`/`getaddrinfo` 的调用者集中在 `func.0x23b90`、`func.0x2378c`、`func.0x2c0b8`、`func.0x2c764`、`func.0x2c968`、`func.0x2d394`（libavformat 网络层）
- 这些函数**一个字节都没动**，且与上面 4 个 HTTP 出口无交集

→ 结论：封 HTTP 不影响 RTMP 推流。

### 9.3 补丁表（B 组，6 处）

| # | 目标 | VA | 文件偏移 | 原 → 新 | 说明 |
|---|---|---|---|---|---|
| B1 | `-[TWLicenseManager request:…]` | `0x138d844` | `0x2a5844` | `ffc302d1` → `c0035fd6` | 直接 `ret`，不再建 dataTask |
| B2 | `+[FXCommerceRequest fetch:…]` | `0x12eb20` | `0x12eb20` | `f85fbca9 f65701a9` → `000080d2 c0035fd6` | `mov x0,#0; ret`，返回 nil |
| B3 | `+[FXUpdateTransfer start:…]` | `0x1327d0` | `0x1327d0` | `fc6fbaa9 fa6701a9` → `000080d2 c0035fd6` | 同上 |
| B4 | plugin-auth 的 session 创建 | `0x8924` | `0x8924` | `a71e0594`(`bl sessionWithConfiguration:`) → `000080d2`(`mov x0,#0`) | 该对象 session=nil，后续 `[nil dataTask…]` 全为 nil 消息 |
| B5 | base 常量 `https://139.196.169.34/tianwen-framexiang-20261030` | `0x1395f5b` | `0x2adf5b` | → `https://127.0.0.1:9`（补 `\0` 31 B） | 第二道保险：即使有未识别拼接，连接留在本机 |
| B6 | base 常量 `https://www.ybdskj.top` | `0x156478` | `0x156478` | → `https://127.0.0.1:9`（补 `\0` 3 B） | 同上 |

B2/B3 用 `mov x0,#0` 而不是裸 `ret`，是因为这两个类方法返回 `instancetype`，裸 `ret` 会把 `self`（类对象）当实例返回给调用方，可能触发 unrecognized selector；返回 nil 才是安全语义。

### 9.4 副作用（如实）

- **授权/卡包/更新/插件授权四类 UI 会停在初始态**：`completion` 不再回调，界面可能一直显示"检查中/加载中"。这是"不发请求"的必然代价（静态补丁无法构造 `NSError` 回调）。
- **`busy` 可能保持 YES**：`heartbeat` 入口先判 `busy`，所以反而更安静。
- **不影响**：采集/人脸/推流/本地视频选择/授权状态显示（`valid` 恒 1）。

### 9.5 静态封不到的地方（必须说明）

| 通道 | 状态 |
|---|---|
| AVFoundation 用**网络 URL** 播放（HTTP-FLV/HLS 拉流预览） | 走系统栈，不经本 dylib 的 session；本样本的 `FXFrontPlayer` 使用本地文件选择器（`UIDocumentPickerViewController` + `fileURLWithPath:`），未见网络 URL 构造，但静态无法 100% 排除 |
| WebKit / SFSafariViewController | 二进制内**无** `WKWebView`/`SFSafariViewController`/`UIWebView` 类引用，不存在该通道 |
| `NSURLConnection` / `CFStream` / `NSStream` | 同样**无**引用 |

要做到"物理级零出网"，在越狱机上再叠一层：`pf`/`iptables` 丢弃或黑洞代理（例如把非白名单域名指向 127.0.0.1），只放行 RTMP 目标端口。

### 9.6 怎么自己验

```bash
# 1) 复核 HTTP 出口仍是 4 个（换版本后重跑）
python stub_selectors.py X.dylib | grep -E 'dataTask|sessionWith|resume'
radare2 -q -c 'aa; axt 0x1503e0; axt 0x1503c0; axt 0x14d1a0; axt 0x14d1e0' X.dylib

# 2) 抓包确认零请求（越狱机）
tcpdump -i any -n 'tcp port 80 or tcp port 443' -w /tmp/tw.pcap
#   预期：启动 → 采集 → 面板 → 全程无 80/443 流量；rtmp 端口正常

# 3) 字符串层确认黑洞生效
strings -a X.dylib | grep -E 'ybdskj|139\.196|127\.0\.0\.1:9'
```

---

生成时间：2026-11-03 · 证据目录 `证据\`（含段表、符号全表、字符串全表、各判据反汇编）
