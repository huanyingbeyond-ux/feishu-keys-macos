// FeishuKeys.swift — 飞鼠 XING WEI 2.4G (VID 0x2320 / PID 0x0912) 全按键守护进程
//
// 为什么不用 Karabiner / hidutil:
//   * Karabiner-Elements 14.13.0 只认 113 个登记的 consumer_key_code 名称，
//     飞鼠发出的 AC_Search(0x221) 等被判为 Unknown Event 直接丢弃；
//   * hidutil UserKeyMapping 只作用于 Keyboard Page(0x07)，
//     对 Consumer Page(0x0C) 与 GenericDesktop SystemControl(0x01/0x81) 无效
//     （实测写入读回成功但 Main 页没有 f13/f19 事件）。
//   * 本进程直接注册 IOHIDDeviceRegisterInputReportCallback 读原始报告字节，
//     绕开所有名称表与键映射层，任何 Usage 都能捕获。
//
// 报告描述符实测（119 字节，VID 0x2320 / PID 0x0912）:
//   Report ID 1 (Mouse/触摸板): [ID][buttons 5bit+pad][X int8][Y int8][Wheel int8][AC_Pan 0x238]
//   Report ID 2 (Consumer)    : [ID][usage lo][usage hi]  16-bit little endian，松开为 0x0000
//   Report ID 3 (SystemCtrl)  : [ID][bits]  bit0=0x81 PowerDown, bit1=0x82 Sleep, bit2=0x83 WakeUp
//
// 映射表: ~/.config/feishu-keys/mapping.json  (每次按键时热加载，改完无需重启)
// 日志  : /tmp/feishu_keys.log
//
// 编译: swiftc -O FeishuKeys.swift -o FeishuKeys
// 运行: ./FeishuKeys            (前台常驻；由 LaunchAgent 托管)

import Foundation
import CoreFoundation
import CoreGraphics
import IOKit
import IOKit.hid
import Darwin
import ApplicationServices
import AppKit

let TARGET_VID = 0x2320
let TARGET_PID = 0x0912
let HOME_DIR = NSHomeDirectory()
let MAPPING_FILE = HOME_DIR + "/.config/feishu-keys/mapping.json"
let LOG_FILE = "/tmp/feishu_keys.log"
let POWER_SCRIPT = HOME_DIR + "/.config/karabiner/scripts/power-options.applescript"

let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

func logLine(_ s: String) {
    let line = dateFormatter.string(from: Date()) + " " + s + "\n"
    print(line, terminator: "")
    fflush(stdout)
    let fd = open(LOG_FILE, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd >= 0 {
        line.withCString { _ = write(fd, $0, strlen($0)) }
        close(fd)
    }
}

func shellAsync(_ path: String, _ args: [String]) {
    DispatchQueue.global().async {
        let p = Process()
        p.launchPath = path
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe
        do {
            try p.run()
            p.waitUntilExit()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            if let err = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !err.isEmpty {
                logLine("  shell stderr: \(err)")
            }
            logLine("  shell done: \(path) \((args).joined(separator: " "))")
        } catch {
            logLine("  shell FAILED: \(path) \(error)")
        }
    }
}

// CGEvent 快捷键。WorkBuddy 已获 kTCCServicePostEvent 授权，可直接投递系统级按键。
let FLAG_COMMAND = CGEventFlags(rawValue: 0x00100000)
let FLAG_CONTROL = CGEventFlags(rawValue: 0x00040000)
let FLAG_FN      = CGEventFlags(rawValue: 0x00800000)

func postShortcut(_ keyCode: CGKeyCode, _ flags: CGEventFlags) {
    guard let src = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
          let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
    else {
        logLine("  CGEvent 构造失败")
        return
    }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    usleep(25000)
    up.post(tap: .cghidEventTap)
    logLine("  CGEvent posted keyCode=\(keyCode) flags=0x\(String(flags.rawValue, radix: 16))")
}

// 用辅助功能 API 把键盘焦点放到顶端菜单栏。
// 系统 ^F2 在 macOS 12 当前登录会话不可用：全键盘访问(AppleKeyboardUIMode)由命令行写入后
// 需要注销重登才被 WindowServer 加载，且 fnState=1 与快捷键表里的 Fn 位冲突。
// 直接对菜单栏第一项（Apple 菜单）执行 AXPress：菜单展开后焦点即落在菜单栏，
// 用户可用方向键在所有菜单间导航；pressShutdown=true 时再触发「关机…」项。
func focusMenuBar(pressShutdown: Bool) {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
        logLine("  菜单栏: 取不到前台应用")
        return
    }
    let axApp = AXUIElementCreateApplication(pid)
    var mbRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &mbRef) == .success,
          let mbObj = mbRef else {
        logLine("  菜单栏: AX 读取失败（辅助功能授权?）")
        return
    }
    let bar = mbObj as! AXUIElement
    var chRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &chRef) == .success,
          let items = chRef as? [AXUIElement], !items.isEmpty else {
        logLine("  菜单栏: 无菜单项")
        return
    }
    let apple = items[0]
    let r = AXUIElementPerformAction(apple, kAXPressAction as CFString)
    if r != .success {
        logLine("  菜单栏: AXPress 失败 err=\(r.rawValue)")
        return
    }
    logLine("  菜单栏: 已聚焦（Apple 菜单展开）")

    guard pressShutdown else { return }
    usleep(300000)
    var menuRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(apple, kAXChildrenAttribute as CFString, &menuRef) == .success,
          let menuObj = menuRef,
          let menus = menuObj as? [AXUIElement], !menus.isEmpty else {
        logLine("  关机: 读不到 Apple 菜单子项（菜单已展开，可手动选择）")
        return
    }
    var miRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(menus[0], kAXChildrenAttribute as CFString, &miRef) == .success,
          let menuItems = miRef as? [AXUIElement] else {
        logLine("  关机: 读不到菜单项（菜单已展开，可手动选择）")
        return
    }
    for it in menuItems {
        var tRef: CFTypeRef?
        AXUIElementCopyAttributeValue(it, kAXTitleAttribute as CFString, &tRef)
        let title = (tRef as? String) ?? ""
        if title.contains("关机") || title.contains("Shut Down") {
            let pr = AXUIElementPerformAction(it, kAXPressAction as CFString)
            logLine("  关机: 已触发「\(title)」 err=\(pr.rawValue)")
            return
        }
    }
    logLine("  关机: 未找到关机项（菜单已展开，可手动选择）")
}

func runAction(_ action: String) {
    switch action {
    case "mail":     shellAsync("/usr/bin/open", ["-a", "Mail"])
    case "safari":   shellAsync("/usr/bin/open", ["-a", "Safari"])
    case "music":    shellAsync("/usr/bin/open", ["-a", "Music"])
    case "finder":   shellAsync("/usr/bin/open", ["-a", "Finder"])
    case "spotlight": postShortcut(49, FLAG_COMMAND)                 // ⌘Space
    case "desktop":   postShortcut(103, FLAG_FN)                      // Fn+F11
    case "menubar":   focusMenuBar(pressShutdown: false)   // 聚焦顶端菜单栏（AX，不依赖失效的 ^F2）
    case "shutdown":  focusMenuBar(pressShutdown: true)    // 触发系统 Apple 菜单「关机…」
    case "launchpad": shellAsync("/usr/bin/open", ["-a", "Launchpad"])
    case "power":
        if FileManager.default.fileExists(atPath: POWER_SCRIPT) {
            shellAsync("/usr/bin/osascript", [POWER_SCRIPT])
        } else {
            logLine("  电源脚本缺失: \(POWER_SCRIPT)")
        }
    case "none":     break
    default:
        // 扩展槽位：动作名 → ~/.config/feishu-keys/actions/<action>.sh
        // 以后新增动作只需放一个可执行脚本 + 改 mapping.json，无需重编译。
        if action.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
            let script = HOME_DIR + "/.config/feishu-keys/actions/" + action + ".sh"
            if FileManager.default.isExecutableFile(atPath: script) {
                shellAsync("/bin/bash", [script])
                return
            }
        }
        logLine("  未知动作: \(action)")
    }
}

func loadMapping() -> [String: String] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: MAPPING_FILE)),
          let obj = try? JSONSerialization.jsonObject(with: data, options: []),
          let dict = obj as? [String: String]
    else { return [:] }
    return dict
}

// 同一按键在 300ms 内只触发一次（防连发 / 多 manager 重复上报）
var lastFire: [String: TimeInterval] = [:]
let fireLock = NSLock()

func mapKey(_ page: Int, _ usage: Int) -> String {
    return String(format: "0x%02X:0x%04X", page, usage)
}

func fire(page: Int, usage: Int, source: String) {
    let key = mapKey(page, usage)
    let mapping = loadMapping()
    let action = mapping[key] ?? ""
    let now = Date().timeIntervalSince1970

    let should: Bool = {
        fireLock.lock(); defer { fireLock.unlock() }
        if let t = lastFire[key], now - t < 0.3 { return false }
        lastFire[key] = now
        return true
    }()

    let tag = action.isEmpty ? "UNMAPPED" : "action=\(action)"
    logLine("EVENT \(key) src=\(source) \(tag)\(should ? "" : " (suppressed)")")
    if should && !action.isEmpty {
        runAction(action)
    }
}

// MARK: - 原始报告回调

let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
reportBuffer.initialize(repeating: 0, count: 128)

func hex(_ bytes: [UInt8]) -> String {
    return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

var lastReport3: UInt8 = 0

let reportCallback: IOHIDReportCallback = { _, result, _, _, reportID, report, length in
    guard result == kIOReturnSuccess, length > 0 else { return }
    let count = min(Int(length), 128)
    let bytes = Array(UnsafeBufferPointer(start: report, count: count))
    // 报告字节流可能带 Report ID 前缀，也可能不带；各分支自行兼容两种情况
    let rid = reportID != 0 ? Int(reportID) : Int(bytes[0])

    switch rid {
    case 2:   // Consumer: 16-bit little endian usage
        let lo: Int, hi: Int
        if bytes.count >= 3 && Int(bytes[0]) == 2 {
            lo = Int(bytes[1]); hi = Int(bytes[2])
        } else if bytes.count >= 2 {
            lo = Int(bytes[0]); hi = Int(bytes[1])
        } else { return }
        let usage = lo | (hi << 8)
        logLine("RAW id=2 [\(hex(bytes))] consumer=0x\(String(format: "%04X", usage))")
        // 0x0238 AC_Pan 是触摸板横滑的相对位移，不是按键
        if usage != 0 && usage != 0x0238 { fire(page: 0x0C, usage: usage, source: "report2") }

    case 3:   // SystemControl: bitmap 0x81/0x82/0x83
        guard bytes.count >= 1 else { return }
        let bits: UInt8 = (bytes.count >= 2 && Int(bytes[0]) == 3) ? bytes[1] : bytes[0]
        logLine("RAW id=3 [\(hex(bytes))] bits=0x\(String(format: "%02X", bits))")
        for i in 0..<3 {
            let mask = UInt8(1 << i)
            if bits & mask != 0 && lastReport3 & mask == 0 {
                fire(page: 0x01, usage: 0x81 + i, source: "report3")
            }
        }
        lastReport3 = bits

    case 1:   // Mouse/触摸板：只记录有意义的变化，不动系统原生滚动
        guard bytes.count >= 5 else { return }
        let buttons = bytes[1]
        let wheel = bytes[4]
        let pan = bytes.count > 5 ? bytes[5] : 0
        if buttons != 0 || wheel != 0 || pan != 0 {
            logLine("RAW id=1 [\(hex(bytes))] buttons=0x\(String(format: "%02X", buttons)) wheel=\(Int8(bitPattern: wheel)) pan=\(pan)")
        }

    default:
        // 键盘接口无 Report ID：8 字节 [modifier][reserved][key1..key6]。
        // 飞鼠的 ⏻ / 音乐键 若走键盘页，只会在这一通道出现，
        // 必须把键码喂给 fire()，否则只记录字节、不会执行任何动作。
        if rid == 0 && bytes.count >= 3 {
            let keys = bytes[2..<min(bytes.count, 8)].filter { $0 != 0 }
            let desc = keys.map { String(format: "0x%02X", $0) }.joined(separator: ",")
            logLine("RAW keyboard [\(hex(bytes))] keys=[\(desc)]")
            for k in keys { fire(page: 0x07, usage: Int(k), source: "reportKB") }
        } else {
            logLine("RAW id=\(rid) [\(hex(bytes))]")
        }
    }
}

// MARK: - 解析后的 element 回调（兜底通道：无需逐设备打开）

let valueCallback: IOHIDValueCallback = { _, result, _, value in
    guard result == kIOReturnSuccess else { return }
    let element = IOHIDValueGetElement(value)
    let page = Int(IOHIDElementGetUsagePage(element))
    let elemUsage = Int(IOHIDElementGetUsage(element))
    let intVal = Int(IOHIDValueGetIntegerValue(value))

    // Consumer / SystemControl 是 HID Array：element 的 usage 常为 0 或范围下界，
    // 真正的键码在 integer value 里。两种可能都检查，避免漏码。
    // 必须排除鼠标 X/Y/Wheel（page=0x01, usage=0x30/0x31/0x38）的相对位移值，
    // 否则位移数值会被误当成按键码触发动作。
    let isMouseAxis = (page == 0x01 && [0x30, 0x31, 0x38].contains(elemUsage))
    if isMouseAxis { return }

    var candidates: Set<Int> = []
    if page == 0x0C {
        // 0x0238 AC_Pan 是触摸板横滑的相对位移数据，不是按键，排除以免刷屏
        for u in [elemUsage, intVal] where u >= 0x30 && u <= 0x043C && u != 0x0238 {
            candidates.insert(u)
        }
    } else if page == 0x01 {
        for u in [elemUsage, intVal] where u >= 0x81 && u <= 0x83 { candidates.insert(u) }
    } else if page == 0x07 {
        // 键盘 6-key array：真正的键码在 intVal，elemUsage 常为范围下界。
        // 排除 0..3（ErrorRollOver 等哨兵值）与 0xE0..0xE7（modifier 位图），
        // 否则修饰键位图值 0/1 会被误当成键码。
        for u in [elemUsage, intVal] where u >= 0x04 && u <= 0xFF && !(0xE0...0xE7).contains(u) {
            candidates.insert(u)
        }
    }

    for u in candidates {
        fire(page: page, usage: u, source: "element")
    }
}

// MARK: - 设备枚举

func cfInt(_ v: CFTypeRef?) -> Int? {
    guard let v = v else { return nil }
    return (v as? NSNumber)?.intValue
}

func devicesFromSet(_ set: CFSet) -> [IOHIDDevice] {
    let n = CFSetGetCount(set)
    var ptrs = [UnsafeRawPointer?](repeating: nil, count: n)
    CFSetGetValues(set, &ptrs)
    return ptrs.compactMap { $0 }.map { unsafeBitCast($0, to: IOHIDDevice.self) }
}

func pair(_ page: Int, _ usage: Int) -> [String: Any] {
    return [
        kIOHIDVendorIDKey as String: TARGET_VID,
        kIOHIDProductIDKey as String: TARGET_PID,
        kIOHIDDeviceUsagePairsKey as String: [["DeviceUsagePage": page, "DeviceUsage": usage]],
    ]
}

logLine("=== FeishuKeys 启动 (VID=0x\(String(format: "%04X", TARGET_VID)) PID=0x\(String(format: "%04X", TARGET_PID))) ===")
logLine("映射表: \(MAPPING_FILE) 条目数: \(loadMapping().count)")

// 主 manager：按 VID/PID 宽匹配，拿到 Composite Device 的所有接口
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [
    kIOHIDVendorIDKey as String: TARGET_VID,
    kIOHIDProductIDKey as String: TARGET_PID,
] as CFDictionary)
IOHIDManagerRegisterInputValueCallback(manager, valueCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
logLine("manager open=\(openResult)")

if let set = IOHIDManagerCopyDevices(manager) {
    let devs = devicesFromSet(set)
    logLine("匹配到 \(devs.count) 个 HID 接口")
    for (i, dev) in devs.enumerated() {
        let pup = cfInt(IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString)) ?? -1
        let pu = cfInt(IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString)) ?? -1
        let product = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? "?"
        let dr = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        if dr == kIOReturnSuccess {
            IOHIDDeviceRegisterInputReportCallback(dev, reportBuffer, 128, reportCallback, nil)
            IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            logLine("  #\(i) \(product) page=0x\(String(format: "%02X", pup)) usage=0x\(String(format: "%04X", pu)) report-callback=OK")
        } else {
            logLine("  #\(i) \(product) page=0x\(String(format: "%02X", pup)) usage=0x\(String(format: "%04X", pu)) IOHIDDeviceOpen FAILED \(dr) (可能被其它进程独占)")
        }
    }
} else {
    logLine("IOHIDManagerCopyDevices 返回 nil")
}

// 额外用 UsagePairs 精确匹配再建两个 manager，覆盖嵌套 collection 未被宽匹配命中的情况
for (label, page, usage) in [("Consumer", 0x0C, 0x01), ("SystemControl", 0x01, 0x80)] {
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(m, pair(page, usage) as CFDictionary)
    IOHIDManagerRegisterInputValueCallback(m, valueCallback, nil)
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    var n = 0
    if let s = IOHIDManagerCopyDevices(m) { n = CFSetGetCount(s) }
    logLine("[\(label)] open=\(r) devices=\(n)")
}

// 自检触发：向 /tmp/feishu_keys_trigger 写入动作名即可执行一次，
// 便于在不按物理键的情况下端到端验证动作链路（写入后文件会被立即删除）。
let TRIGGER_FILE = "/tmp/feishu_keys_trigger"
DispatchQueue.global().async {
    while true {
        usleep(200000)
        if let s = try? String(contentsOfFile: TRIGGER_FILE, encoding: .utf8) {
            try? FileManager.default.removeItem(atPath: TRIGGER_FILE)
            let a = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !a.isEmpty {
                logLine("TRIGGER action=\(a)")
                runAction(a)
            }
        }
    }
}

logLine("=== 就绪，等待飞鼠按键 ===")
CFRunLoopRun()
