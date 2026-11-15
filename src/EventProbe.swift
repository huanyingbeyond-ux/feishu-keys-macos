// EventProbe.swift — 读取飞鼠 (VID 0x2320 / PID 0x0912) 的原始 HID 事件
// 只匹配具体 Usage 接口，避免触发 macOS 输入监控的宽泛匹配拦截。
// 编译: swiftc -O EventProbe.swift -o EventProbe
// 运行: ./EventProbe | tee /tmp/feishu_events.log

import Foundation
import CoreFoundation
import IOKit
import IOKit.hid

let TARGET_VID = 0x2320
let TARGET_PID = 0x0912

let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

let usageNames: [Int: String] = [
    0x30: "Power", 0x31: "Reset", 0x32: "Sleep", 0x40: "Menu",
    0x81: "SystemPowerDown", 0x82: "SystemSleep", 0x83: "SystemWakeUp",
    0xB0: "Play", 0xB1: "Pause", 0xB5: "ScanNextTrack", 0xB6: "ScanPrevTrack",
    0xCD: "PlayPause", 0xE2: "Mute", 0xE9: "VolumeUp", 0xEA: "VolumeDown",
    0x18A: "AL_EmailReader", 0x192: "AL_Calculator", 0x194: "AL_MyComputer",
    0x196: "AL_InternetBrowser", 0x1A7: "AL_Documents",
    0x1B8: "AL_AudioBrowser", 0x1B9: "AL_AudioPlayer",
    0x221: "AC_Search", 0x223: "AC_Home", 0x224: "AC_Back",
    0x225: "AC_Forward", 0x227: "AC_Refresh", 0x22A: "AC_Bookmarks",
    0x238: "AC_Pan",
]

let pageNames: [Int: String] = [
    0x01: "GenericDesktop", 0x07: "Keyboard", 0x0C: "Consumer",
    0x0D: "Digitizer", 0x09: "Button",
]

// CFNumber 必须经 NSNumber 桥接，直接 `as? Int` 在部分系统版本会静默失败，
// 导致所有事件被过滤掉（这是第一版抓不到事件的嫌疑点）。
func cfInt(_ value: CFTypeRef?) -> Int? {
    guard let value = value else { return nil }
    return (value as? NSNumber)?.intValue
}

let logAll = ProcessInfo.processInfo.environment["PROBE_ALL"] == "1"

let valueCallback: IOHIDValueCallback = { _, result, _, value in
    guard result == kIOReturnSuccess else { return }
    let element = IOHIDValueGetElement(value)
    let device = IOHIDElementGetDevice(element)
    let vid = cfInt(IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString)) ?? -1
    let pid = cfInt(IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString)) ?? -1
    if !logAll && !(vid == TARGET_VID && pid == TARGET_PID) { return }

    let page = Int(IOHIDElementGetUsagePage(element))
    let usage = Int(IOHIDElementGetUsage(element))
    let intVal = IOHIDValueGetIntegerValue(value)
    let ts = dateFormatter.string(from: Date())

    // 按键松开(value=0)与相对坐标的 0 值会淹没日志，只保留有意义的变化
    if intVal == 0 && (page == 0x0C || page == 0x01 || page == 0x09) { return }

    let pn = pageNames[page] ?? String(format: "page0x%02X", page)
    let un = usageNames[usage] ?? ""
    print(String(format: "%@ vid=0x%04X pid=0x%04X %-16@ page=0x%02X usage=0x%04X %-20@ value=%d",
                 ts, vid, pid, pn, page, usage, un, intVal))
    fflush(stdout)
}

func makeManager(_ label: String, _ match: [String: Any]) {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
    IOHIDManagerRegisterInputValueCallback(manager, valueCallback, nil)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    var n = 0
    if let devs = IOHIDManagerCopyDevices(manager) { n = CFSetGetCount(devs) }
    print("[\(label)] open=\(r) devices=\(n)  ← \(dateFormatter.string(from: Date()))")
    fflush(stdout)
}

let VID = kIOHIDVendorIDKey as String
let PID = kIOHIDProductIDKey as String
let PAIRS = kIOHIDDeviceUsagePairsKey as String

// 飞鼠的 Consumer / Mouse collection 嵌在 Composite Device 里，PrimaryUsagePage 是 0x01；
// 只有用 DeviceUsagePairs 精确匹配具体 collection 才能免授权打开（实测 open=0）。
func pair(_ page: Int, _ usage: Int) -> [String: Any] {
    return [VID: TARGET_VID, PID: TARGET_PID,
            PAIRS: [["DeviceUsagePage": page, "DeviceUsage": usage]]]
}

print("=== EventProbe 启动，等待飞鼠按键/触摸板事件 ===")
print("=== 目标 VID=0x2320 PID=0x0912 ===")
fflush(stdout)

makeManager("Consumer 多媒体键", pair(0x0C, 0x01))
makeManager("Mouse 触摸板/滚轮", pair(0x01, 0x02))
makeManager("SystemControl", pair(0x01, 0x80))

CFRunLoopRun()
