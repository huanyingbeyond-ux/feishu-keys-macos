// HIDProbe.swift
// macOS 12 Monterey / x86_64 — Apple Swift 5.7 (Xcode CLT)
// 用途：读取飞鼠 2.4G 接收器 (VID 0x2320 / PID 0x0912) 发出的原始 HID Usage，
//       用于把面板上的多媒体按键精确映射到 macOS 动作。
// 编译：swiftc -O HIDProbe.swift -o HIDProbe
// 运行：./HIDProbe   （按 Ctrl-C 结束），日志写入 /tmp/feishu_hid_probe.log

import Foundation
import IOKit
import IOKit.hid

let logPath = "/tmp/feishu_hid_probe.log"

func writeLog(_ s: String) {
    let data = Data(s.utf8)
    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data, attributes: nil)
    }
    print(s, terminator: "")
    fflush(stdout)
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

// 只匹配飞鼠接收器，不触碰内置键盘和其它鼠标
let matching: [String: Any] = [
    kIOHIDVendorIDKey as String: 0x2320,
    kIOHIDProductIDKey as String: 0x0912
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

let callback: IOHIDValueCallback = { _, _, _, value in
    let element = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let intValue = IOHIDValueGetIntegerValue(value)

    // 只记录按下（非零），忽略松开与鼠标位移
    guard intValue != 0 else { return }
    guard page == 0x0C || page == 0x01 || page == 0x07 else { return }
    // 过滤掉鼠标指针/滚轮的常规数据
    if page == 0x01 && usage != 0x81 && usage != 0x82 && usage != 0x83 && usage != 0x80 { return }

    let now = Date().timeIntervalSince1970
    writeLog(String(format: "%.3f  page=0x%02X  usage=0x%04X  value=%lld\n",
                    now, page, usage, intValue))
}

IOHIDManagerRegisterInputValueCallback(manager, callback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
writeLog("IOHIDManagerOpen = \(openResult)  |  listening VID=0x2320 PID=0x0912\n")
writeLog("请依次按下需要识别的按键，每个键按一次即可。Ctrl-C 结束。\n")

CFRunLoopRun()
