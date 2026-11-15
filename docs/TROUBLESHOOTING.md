# 排障记录、系统授权处理与还原

按问题归类，记录「现象 → 根因 → 处理」。所有结论均在 macOS 12.7.6 / Macmini5,1 实测。

## 1. 授权与进程

### 1.1 `manager open=-536870174`（设备打不开）

- **根因**：未签名的 `FeishuKeys` 二进制缺少「输入监控」授权；或 Karabiner grabber 已 seize 设备。
- **处理**：
  1. 系统设置 → 隐私与安全性 → 输入监控 / 辅助功能，加入 `FeishuKeys` 二进制。
  2. `setup_daemon.py` 会把飞鼠两个接口（`is_keyboard=true/false` × `is_pointing_device=false/true`）写入 `~/.config/karabiner/karabiner.json` 的 `devices` 并设 `ignore: true`，让 Karabiner 释放设备。
  3. 成功后日志为 `manager open=0` + 两行 `report-callback=OK`。

### 1.2 重编译后授权失效（最重要的坑）

- **根因**：TCC 把授权绑定到未签名二进制的 **cdhash**，并缓存于 `/Library/Application Support/com.apple.TCC/AdhocSignatureCache`。每次 `swiftc` 重编译后哈希变化，原授权失效。
- **正确顺序**：**先改 TCC，再替换二进制**（早期反过来做，反复失效）：

```bash
# 需管理员权限；先备份
sudo cp "/Library/Application Support/com.apple.TCC/TCC.db" /tmp/TCC.db.backup

sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "UPDATE access SET csreq=NULL,
                     last_modified=CAST(strftime('%s','now') AS INTEGER)
   WHERE client LIKE '%feishu-keys/FeishuKeys';"

sudo swiftc -O src/FeishuKeys.swift -o FeishuKeys   # 或先编译到临时文件再替换
killall FeishuKeys                                  # KeepAlive 自动拉起
```

`csreq=NULL` 让授权按**路径**匹配而非代码签名哈希。改完用 `setup_daemon.py --check` 确认 `Accessibility -> 2`、`ListenEvent -> 2`。

- **规避原则**：能只改 `mapping.json` 就不要重编译；`runAction` 的 `default` 分支支持 `~/.config/feishu-keys/actions/<动作>.sh` 外部脚本槽位，新增动作零重编译。

### 1.3 查 AppleEvents 授权查错库

- 系统级 `/Library/Application Support/com.apple.TCC/TCC.db` 里**没有** `kTCCServiceAppleEvents`；该服务记录在**用户级** `~/Library/Application Support/com.apple.TCC/TCC.db`。
- 本项目最终不依赖 AppleEvents，但仍记录以免重复踩坑。

## 2. 弹窗与系统服务

### 2.1 System Events 弹窗 `-10004` / `-1712`

- **现象**：重启后 AppleScript 调 System Events 报 `-10004 权限违例`，或挂起 60–120 秒后 `-1712 AppleEvent 已超时`，弹窗根本不出现。
- **附带坑**：System Events 的 `display dialog` 最多 3 个按钮，早期放了 4 个（睡眠/重启/关机/取消）直接报错；改 `choose from list` 也仍受权限问题影响。
- **处理**：**整套对话框方案停用**。改为 `AXUIElement` 直接操作 Apple 菜单（见 2.3），不经过 AppleEvents。

### 2.2 AppleScript 旧电源事件编译失败

- `«event aevtrrst»` / `«event aevtrshdn»` 在现代 macOS 上编译不过 → 先换成 System Events 的 `restart` / `shut down`，后随 2.1 一起停用。

### 2.3 ⏻ 与 ≡ 的最终实现（绕开 ^F2）

- 直接设置 `kAXFocusedUIElementAttribute` 返回 `-25202`（只读），**不可用**。
- 实测可行路径：

```swift
let axApp = AXUIElementCreateApplication(frontmostPID)
AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute, &mbRef)
AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute, &chRef)
AXUIElementPerformAction(items[0], kAXPressAction)   // Apple 菜单展开 → 焦点落到菜单栏
```

- `pressShutdown=true` 时再遍历 Apple 菜单子项，找到标题含「关机」/「Shut Down」的项执行 `AXPress`，走系统原生关机流程（含确认框）。
- 原型工具实测输出：`AXIsProcessTrusted=true` / `menuBar err=0` / `children err=0` / `item[0]=Apple` / `setFocus err=-25202` / `press err=0`。

### 2.4 ^F2 物理快捷键也失效（系统层问题）

用户用**物理键盘**按 ^F2 同样调不出顶端菜单，确认与守护进程无关。叠加原因：

1. `AppleKeyboardUIMode` 原为 `0`（仅文本框和列表），该模式下 Control+F2 类焦点快捷键被系统忽略；命令行改成 `2` 后 macOS 12 需**注销重登**才由 WindowServer 重新加载。
2. `com.apple.keyboard.fnState=1`（F1–F12 已是标准功能键），而系统快捷键表 `AppleSymbolicHotKeys:7` 的 parameters 第三项是 `8650752 = 0x840000`（Control+**Fn**+F2），Fn 位与实际按键不匹配。
3. Karabiner grabber 开机自启占用 HID 设备，其 `fn_function_keys` 里 `f2 → display_brightness_increment` 可能拦截 F2。

尝试过：把 ID 7 modifier 改为 `262144`（纯 Control+F2）+ `activateSettings -u` + `killall cfprefsd` / `SystemUIServer`，当前会话**仍无效** → 判定必须注销重登。最终不依赖 ^F2。

## 3. 按键与动作

### 3.1 一次 ⏻ 触发 3 个动作

- Report 3 位图 + element 兜底把同一次按键拆成 `0x81/0x82/0x83` 三条；三条都映射时并发触发 3 个 AppleScript，互相阻塞直到超时。
- **处理**：`0x82` / `0x83` 设 `none`，只保留 `0x81`；`fire()` 再加 300ms 同码去重。

### 3.2 ≡ 键「完全没反应」

- **根因**：只监听了带 Report ID 的 1/2/3，漏掉键盘接口**无 Report ID 的 8 字节报告**。`0x07:0x0065` 只在这一通道出现。
- **处理**：`reportCallback` 的 `default` 分支解析 `bytes[2..<8]`，喂给 `fire(page: 0x07, ...)`。

### 3.3 启动台「没弹出」

- **根因 A（主因）**：用户实际按下的键上报 `0x0C:0x0183`，而当时只有 `0x0C:0x00CD` 映射到 `launchpad`，`0x0183` 还是 `none` → 动作根本没被触发。把 `0x0183` 改为 `launchpad` 后打通。
- **根因 B**：`/usr/bin/open -a Launchpad` 是 **toggle**，0.8 秒内连按两次会「弹出 → 关闭」，视觉上像没弹出。单次按正常，关闭用 `Esc`。
- **已排除的怀疑**：修复顶端菜单/关机**没有**破坏启动台。组合测试证明 Apple 菜单展开状态下触发 `launchpad`，日志出现 `shell done: /usr/bin/open -a Launchpad`，截图显示启动台正常全屏覆盖；`trigger launchpad` 单独触发也成功。
- **不建议的实现**：`tell application "Launchpad" to activate` 报 `-1712 AppleEvent 已超时`；`tell application "System Events" to key code 53` 报 `-10004 权限违例`。AppleScript 路径在本机不可靠，只有守护进程自己的 `CGEvent` 通道可用。
- **判据提醒**：`pgrep -lx Launchpad` 不可靠 —— Launchpad 由 Dock 托管，是否有独立进程不能作为「是否弹出」的依据，要按屏幕截图判断。

### 3.4 触摸板滑动刷屏

- `0x0C:0x0238` AC Pan 是横滑相对位移，不是按键；在 Consumer 分支显式排除。

## 4. 设备与配置

### 4.1 Karabiner 安装与 DriverKit

- DMG 下载受代理影响，用 `curl --noproxy '*'` + 镜像完成；`pkgutil --check-signature` / `spctl` 通过。
- 扩展激活卡在 `activated waiting for user` 时，需用户在系统设置里点「允许」。
- `grabber.log` 出现 `device_open_forbidden` → 补齐输入监控授权，随后日志变为 `hid queue value monitor is started (grabbed)`。
- Karabiner 配置拒载 `unknown consumer_key_code: "ac_search"`；整数 Usage 同样非法。最终整条 Karabiner 规则链路放弃。

### 4.2 `CFNumber as? Int` 静默失败

- EventProbe 早期用 `CFNumber as? Int` 做设备匹配，永远返回 nil，看起来像「设备不存在」。改为 `(v as? NSNumber)?.intValue` 后恢复。

### 4.3 Swift 编译

- `devs.enumerate()` → 应为 `devs.enumerated()`。
- 用 `CGWindowListCopyWindowInfo` 做窗口枚举的原型，缺 `import Foundation` 时报 `cannot find 'NSArray' / 'NSDictionary' in scope`。

## 5. 系统改动清单与还原（可逆）

| 改动 | 原值 | 现值 | 还原 |
|---|---|---|---|
| `AppleKeyboardUIMode` | `0` | `2` | `defaults write -g AppleKeyboardUIMode -int 0` |
| `AppleSymbolicHotKeys:7:value:parameters:2` | `8650752` | `262144` | 用备份 `/tmp/symbolichotkeys.bak.plist` 还原 |
| `~/.config/karabiner/karabiner.json` devices | 空 | 飞鼠两接口 `ignore: true` | `setup_daemon.py --reset` |
| `hidutil UserKeyMapping` | — | 清空 | `setup_daemon.py --reset` |
| LaunchAgent | — | `com.dean.feishu-keys.plist` | `setup_daemon.py --reset` |

其它备份：`/tmp/TCC.db.backup`、`/tmp/TCC.db.pre15.backup`、`/tmp/mapping.json.bak.*`、`FeishuKeys.stable.bak`。

## 6. 合规与稳定性边界

- 全程**未关闭 SIP、未加载 kext、未绕过 AMFI、未使用 DriverKit 系统扩展**：这是纯用户态 IOKit 旁听方案，崩溃隔离由 LaunchAgent 进程边界保证。
- TCC 数据库刷新属于本机管理员维护操作，用于让**未签名**二进制的授权按路径生效；不是绕过系统安全机制，正式分发仍应走 Apple Developer ID 签名与公证。
- `open -a Launchpad` 属于公开的用户态启动方式；`AXUIElement` 需辅助功能授权，系统会在授权面板中明示。
- 关机动作走系统原生菜单与确认框，不经 `shutdown` 命令强杀，避免误操作；但确认框约 59 秒无操作会自动关机，测试后需按 `Esc`。
