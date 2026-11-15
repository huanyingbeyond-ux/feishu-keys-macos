# 完整按键码表与实测证据

映射键格式 `UsagePage:Usage`，十进制 VID/PID 为 `8992 / 2322`（十六进制 `0x2320 / 0x0912`）。

来源：本机 `/tmp/feishu_keys_stdout.log` 全量日志 + `/tmp/feishu_keys.log` 回归日志 + 屏幕截图。`✅` 表示物理按键实测触发且动作执行成功；`○` 表示日志中出现过但交由系统原生处理；`—` 表示从未触发。

## 1. 已点亮的功能键

| 物理键 | 映射键 | HID Usage 含义 | 通道 | 动作 | 具体行为 | 状态 |
|---|---|---|---|---|---|---|
| ⏻ 电源 | `0x01:0x0081` | Generic Desktop / System Power Down | Report 3 bit0 | `shutdown` | `AXUIElement` 展开前台应用 Apple 菜单 → 找到标题含「关机」/「Shut Down」的菜单项 → `AXPress` → 系统原生确认框 | ✅ |
| ≡ 三条杠 | `0x07:0x0065` | Keyboard / Application (Menu) | 键盘 8 字节报告 | `menubar` | `AXUIElementCreateApplication(frontmostPID)` → `kAXMenuBarAttribute` → `items[0]`（Apple）→ `kAXPressAction` | ✅ |
| 媒体 / ⏯ 键 | `0x0C:0x0183` | Consumer Page AL 区段（飞鼠实际报出的媒体码，标准名未在 Karabiner 名称表登记） | Report 2 | `launchpad` | `/usr/bin/open -a Launchpad` | ✅ 用户最终手动实测成功 |
| ⏯ 播放/暂停 | `0x0C:0x00CD` | Consumer / Play-Pause | Report 2 | `launchpad` | 同上（兼容码双保险） | ✅ 校准期有上报 |
| ✉ 邮件 | `0x0C:0x018A` | Consumer / AL Email Reader | Report 2 | `mail` | `/usr/bin/open -a Mail` | ✅ |
| ✉ 邮件（兼容） | `0x0C:0x0182` | Consumer Page AL 区段 | Report 2 | `mail` | 同上 | — |
| `e` 浏览器 | `0x0C:0x0196` | Consumer / AL Internet Browser | Report 2 | `safari` | `/usr/bin/open -a Safari` | ✅ |
| `e` 浏览器（兼容） | `0x0C:0x0185` | Consumer Page AL 区段 | Report 2 | `safari` | 同上 | — |
| 🔍 放大镜 | `0x0C:0x0221` | Consumer / AC Search | Report 2 | `spotlight` | `CGEvent` 注入 `keyCode=49, flags=0x100000`（⌘Space） | ✅ |
| 🏠 房子 | `0x0C:0x0223` | Consumer / AC Home | Report 2 | `desktop` | `CGEvent` 注入 `keyCode=103, flags=0x800000`（Fn+F11） | ✅ |
| 🔇 静音 | `0x0C:0x00E2` | Consumer / Mute | Report 2 | *不映射* | macOS 原生媒体键，守护进程不拦截 | ○ |
| 触摸板左右键 / 滚轮 | Report 1 | Generic Desktop / Mouse | Report 1 | *不映射* | 原生滚动与点击照常工作，守护进程只记录日志 | ○ |

> 说明：用户最初希望「⏯ 键调出 Apple Music」，后确认该键由 macOS 原生行为即可启动「音乐」App，因此最终改为**启动台**。`music` 动作在 `runAction` 中仍保留，供其他码位调用。

## 2. 主动关闭 / 抑制的码位

| 映射键 | 值 | 原因 |
|---|---|---|
| `0x01:0x0082` | `none` | ⏻ 同一次按键被 report3 与 element 三通道拆成 `0x81 / 0x82 / 0x83` 重复上报，若不关闭会并发触发 3 个动作，早期曾导致 3 个 AppleScript 互相阻塞直到 `-1712` 超时 |
| `0x01:0x0083` | `none` | 同上 |
| `0x0C:0x0238` | `none` | AC Pan 是触摸板横滑的相对位移，不是按键；不排除会在滑动时刷屏/误触发 |
| `0x07:0x0066` | `none` | 键盘页相邻码，未触发 |
| `0x0C:0x0184`、`0x0C:0x022A`、`0x0C:0x01A7`、`0x0C:0x0040`、`0x0C:0x0030`、`0x0C:0x0032`、`0x0C:0x00E9` | `none` | 早期枚举候选，日志中从未触发 |
| 5 条 `music` 码：`0x0C:0x0193`、`0x0C:0x01B7`、`0x0C:0x01B8`、`0x0C:0x01B9`、`0x0C:0x01C7` | `music` | 早期猜测码，**从未触发**；用户明确不再需要映射 Apple Music，属可安全删除的死配置 |

同一按键 300ms 内的重复上报还会被 `fire()` 内的 `lastFire` 去重；日志里带 `(suppressed)` 的条目即被抑制的重复事件，**不是故障**。

## 3. 关键定位过程

`0x0C:0x0183` 一度被误判为「≡ 三条杠」键，后来通过键盘 8 字节报告确认：

```
RAW keyboard [00 00 65 00 00 00 00 00] keys=[0x65]
EVENT 0x07:0x0065 src=reportKB action=menubar
```

即 ≡ 走的是 **Keyboard Page `0x07` / Application `0x65`**，根本不是 Consumer Page。而用户按「启动台键」时反复上报的是：

```
RAW id=2 [02 83 01] consumer=0x0183
EVENT 0x0C:0x0183 src=report2 action=launchpad
```

**「启动台没弹出」的根因**：映射表当时只把 `0x0C:0x00CD` 指向 `launchpad`，而用户实际按下的键报的是 `0x0C:0x0183`，该码仍是 `none`。把 `0x0C:0x0183` 改为 `launchpad` 后，动作链路立即打通。这与「修复顶端菜单 / 关机」无关——组合测试证明即使 Apple 菜单处于展开状态，`open -a Launchpad` 仍能正常全屏弹出。

**次要因素**：`/usr/bin/open -a Launchpad` 是开关（toggle）。日志显示用户曾 0.8 秒内连按两次，第一次弹出、第二次关闭，视觉上像「没弹出」。单次按正常，关闭启动台请用 `Esc`。

## 4. 全键回归日志（2026-11-15 17:27 / 17:34）

```
17:27:12 EVENT 0x0C:0x0183 src=report2 action=launchpad
17:27:24 EVENT 0x01:0x0081 src=report3 action=shutdown
17:27:36 EVENT 0x07:0x0065 src=reportKB action=menubar
17:27:40 EVENT 0x0C:0x0221 src=report2 action=spotlight
17:27:41 EVENT 0x0C:0x0223 src=report2 action=desktop
17:27:43 EVENT 0x0C:0x0196 src=report2 action=safari
17:34:29 EVENT 0x01:0x0081 src=report3 action=shutdown
17:34:42 EVENT 0x0C:0x0183 src=report2 action=launchpad
17:34:47 EVENT 0x0C:0x018A src=report2 action=mail
17:34:54 EVENT 0x0C:0x0221 src=report2 action=spotlight
17:34:56 EVENT 0x0C:0x0223 src=report2 action=desktop
17:34:59 EVENT 0x0C:0x0196 src=report2 action=safari
17:35:02 EVENT 0x07:0x0065 src=reportKB action=menubar
```

全量日志中出现过的事件码统计（次数含被抑制的重复上报）：

| 事件码 | 次数 | 说明 |
|---|---|---|
| `0x0C:0x0183` | 56 | 媒体/启动台键 |
| `0x07:0x0065` | 50 | ≡ 三条杠 |
| `0x0C:0x0223` | 24 | 🏠 房子 |
| `0x0C:0x0221` | 24 | 🔍 放大镜 |
| `0x07:0x004F` | 20 | 键盘方向键右 |
| `0x0C:0x00E2` | 16 | 🔇 静音 |
| `0x07:0x0039` | 13 | Caps Lock |
| `0x07:0x003B` | 12 | F-区键 |
| `0x01:0x0081` | 12 | ⏻ 电源 |
| `0x07:0x0051` | 10 | 方向键下 |
| `0x0C:0x0196` | 8 | `e` / Safari |
| `0x0C:0x00CD` | 8 | ⏯ 播放/暂停 |
| `0x01:0x0083` / `0x01:0x0082` | 各 8 | ⏻ 的重复通道 |
| `0x0C:0x018A` | 4 | ✉ 邮件 |
| `0x0C:0x3B00` | 1 | 一次异常拼包，已忽略 |
