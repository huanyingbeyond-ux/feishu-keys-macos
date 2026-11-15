#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
完整解析 USB HID Report Descriptor，判断飞鼠触摸板是否为多点触控设备。

用法:
  ioreg -a -r -c IOHIDDevice -l > /tmp/hid_devices.xml
  python3 parse_descriptor.py [plist文件] [--vid 0x2320] [--pid 0x0912]

判据（HID 1.11 + Windows Precision Touchpad / macOS Multitouch）:
  * 真多点: Usage Page 0x0D (Digitizer) + Usage 0x05 Touch Pad
            + 0x54 Contact Count + 多个 0x22 Finger Logical Collection
            + 每个 Finger 内绝对坐标 X/Y (0x01/0x30,0x31) 与 0x51 Contact ID
  * 伪触摸板: Usage Page 0x01 / Usage 0x02 Mouse，仅 Button(0x09) +
            相对 X/Y(0x30,0x31, Relative 标志) + Wheel(0x38)
"""
import plistlib
import sys
from pathlib import Path

PAGES = {
    0x01: "GenericDesktop", 0x02: "Simulation", 0x06: "GenericDeviceControls",
    0x07: "Keyboard", 0x08: "LED", 0x09: "Button", 0x0A: "Ordinal",
    0x0B: "Telephony", 0x0C: "Consumer", 0x0D: "Digitizer",
    0x0E: "Haptics", 0x0F: "PhysicalInputDevice", 0x10: "Unicode",
    0x14: "AlphanumericDisplay", 0x40: "MedicalInstrument",
    0x80: "Monitor", 0x84: "Power", 0x8C: "BarCodeScanner",
    0x90: "MagneticStripeReader", 0x91: "CameraControl", 0x92: "Arcade",
}
GD = {
    0x01: "Pointer", 0x02: "Mouse", 0x04: "Joystick", 0x05: "GamePad",
    0x06: "Keyboard", 0x07: "Keypad", 0x08: "MultiAxisController",
    0x09: "TabletPCSystemControls", 0x30: "X", 0x31: "Y", 0x32: "Z",
    0x33: "Rx", 0x34: "Ry", 0x35: "Rz", 0x36: "Slider", 0x37: "Dial",
    0x38: "Wheel", 0x39: "HatSwitch", 0x3A: "CountedBuffer",
    0x40: "Vx", 0x41: "Vy", 0x42: "Vz", 0x80: "SystemControl",
    0x81: "SystemPowerDown", 0x82: "SystemSleep", 0x83: "SystemWakeUp",
    0x90: "SystemDock", 0xA1: "SystemDisplayLCDAutoscale",
}
DIGI = {
    0x01: "Digitizer", 0x02: "Pen", 0x03: "LightPen", 0x04: "TouchScreen",
    0x05: "TouchPad", 0x20: "Stylus", 0x21: "Puck", 0x22: "Finger",
    0x30: "TipPressure", 0x31: "BarrelPressure", 0x32: "InRange",
    0x33: "Touch", 0x34: "Untouch", 0x35: "Tap", 0x36: "Quality",
    0x37: "DataValid", 0x38: "TransducerIndex", 0x42: "TipSwitch",
    0x43: "SecondaryTipSwitch", 0x44: "BarrelSwitch", 0x51: "ContactID",
    0x52: "DeviceMode", 0x53: "DeviceIdentifier", 0x54: "ContactCount",
    0x55: "ContactCountMaximum",
}
CONSUMER = {
    0x30: "Power", 0x32: "Sleep", 0x40: "Menu", 0xB5: "ScanNextTrack",
    0xB6: "ScanPrevTrack", 0xCD: "PlayPause", 0xE2: "Mute",
    0xE9: "VolumeIncrement", 0xEA: "VolumeDecrement",
    0x18A: "AL_EmailReader", 0x196: "AL_InternetBrowser",
    0x221: "AC_Search", 0x223: "AC_Home", 0x22A: "AC_Bookmarks",
    0x22D: "AC_ZoomIn", 0x22E: "AC_ZoomOut", 0x238: "AC_Pan",
}


def uname(page, usage):
    table = {0x01: GD, 0x0D: DIGI, 0x0C: CONSUMER}.get(page, {})
    return table.get(usage, "")


def signed(raw, size):
    if not size:
        return 0
    bits = size * 8
    v = int.from_bytes(raw, "little", signed=False)
    if v & (1 << (bits - 1)):
        v -= 1 << bits
    return v


def parse_desc(d):
    """返回 (items, summary)。items 为可读条目列表。"""
    items = []
    g = {"page": 0, "size": 0, "count": 0, "rid": 0,
         "lmin": 0, "lmax": 0, "pmin": 0, "pmax": 0}
    l = {"usage": [], "umin": None, "umax": None, "delim": 0}
    pages_seen = set()
    usages_by_page = {}
    relative_count = 0
    absolute_count = 0
    contact_count_seen = False
    finger_collections = 0
    touchpad_seen = False
    has_wheel = False
    has_button = False
    depth = 0

    i = 0
    while i < len(d):
        b = d[i]
        sz = {0: 0, 1: 1, 2: 2, 3: 4}[b & 0x03]
        typ = (b >> 2) & 0x03
        tag = (b >> 4) & 0x0F
        raw = d[i + 1:i + 1 + sz]
        v = signed(raw, sz) if typ == 1 else int.from_bytes(raw, "little") if sz else 0
        i += 1 + sz

        label = ""
        if typ == 1:  # Global
            name = {0: "UsagePage", 1: "LogicalMin", 2: "LogicalMax",
                    3: "PhysicalMin", 4: "PhysicalMax", 5: "UnitExponent",
                    6: "Unit", 7: "ReportSize", 8: "ReportID", 9: "ReportCount",
                    10: "Push", 11: "Pop"}.get(tag, f"Global{tag}")
            if tag == 0:
                g["page"] = v
                pages_seen.add(v)
            elif tag == 7:
                g["size"] = v
            elif tag == 8:
                g["rid"] = v
            elif tag == 9:
                g["count"] = v
            elif tag == 1:
                g["lmin"] = v
            elif tag == 2:
                g["lmax"] = v
            elif tag == 3:
                g["pmin"] = v
            elif tag == 4:
                g["pmax"] = v
            label = f"{name}={v}" + (f" ({PAGES.get(v,'VendorDefined')})" if tag == 0 else "")

        elif typ == 2:  # Local
            name = {0: "Usage", 1: "UsageMin", 2: "UsageMax",
                    3: "DesignatorIndex", 4: "DesignatorMin", 5: "DesignatorMax",
                    7: "StringIndex", 8: "StringMin", 9: "StringMax",
                    10: "Delimiter"}.get(tag, f"Local{tag}")
            if tag == 0:
                u = v & 0xFFFF if sz == 4 else v
                l["usage"].append(u)
                usages_by_page.setdefault(g["page"], set()).add(u)
                if g["page"] == 0x0D and u == 0x05:
                    touchpad_seen = True
            elif tag == 1:
                l["umin"] = v
                usages_by_page.setdefault(g["page"], set()).add(v)
            elif tag == 2:
                l["umax"] = v
                for u in range(l["umin"] or 0, v + 1):
                    usages_by_page.setdefault(g["page"], set()).add(u)
            elif tag == 10:
                l["delim"] = v
            label = f"{name}=0x{v:04X}" if isinstance(v, int) and v >= 0 else f"{name}={v}"

        elif typ == 0:  # Main
            if tag == 10:  # Collection
                u = (l["usage"][-1] if l["usage"] else 0)
                if g["page"] == 0x0D and u == 0x22:
                    finger_collections += 1
                label = f"Collection(0x{v:02X}={ {0:'Physical',1:'Application',2:'Logical',3:'Report',4:'NamedArray'}.get(v,'?') }) usage=0x{u:04X} {uname(g['page'],u)}"
                depth += 1
            elif tag == 12:
                depth -= 1
                label = "EndCollection"
            elif tag in (8, 9, 11):  # Input / Output / Feature
                flags = v
                kind = {8: "Input", 9: "Output", 11: "Feature"}[tag]
                rel = bool(flags & 0x04)
                variable = bool(flags & 0x02)
                if tag == 8:
                    relative_count += rel and g["count"] or 0
                    absolute_count += (not rel) and g["count"] or 0
                us = l["usage"][:]
                if l["umin"] is not None and l["umax"] is not None:
                    us = list(range(l["umin"], min(l["umax"], l["umin"] + 256) + 1))
                for u in us:
                    if g["page"] == 0x0D and u == 0x54:
                        contact_count_seen = True
                    if g["page"] == 0x09:
                        has_button = True
                    if g["page"] == 0x01 and u == 0x38:
                        has_wheel = True
                unames = ",".join(f"0x{u:04X}{(':'+uname(g['page'],u)) if uname(g['page'],u) else ''}" for u in us[:12])
                label = (f"{kind}(flags=0x{flags:02X} {'RELATIVE' if rel else 'ABSOLUTE'},"
                         f"{'Variable' if variable else 'Array'}) "
                         f"page=0x{g['page']:02X}({PAGES.get(g['page'],'Vendor')}) "
                         f"size={g['size']} count={g['count']} rid={g['rid']} "
                         f"logical=[{g['lmin']},{g['lmax']}] usages=[{unames}]")
            else:
                label = f"Main({tag})={v}"
            # Main item 之后清空 Local
            if tag != 10:
                l = {"usage": [], "umin": None, "umax": None, "delim": 0}
        else:
            label = f"Reserved(tag={tag})"

        items.append("  " * max(depth, 0) + label)

    summary = {
        "pages": sorted(pages_seen),
        "digitizer_page": 0x0D in pages_seen,
        "touchpad_collection": touchpad_seen,
        "contact_count": contact_count_seen,
        "finger_collections": finger_collections,
        "relative_bits": relative_count,
        "absolute_bits": absolute_count,
        "has_button_page": has_button,
        "has_wheel": has_wheel,
        "usages": {f"0x{p:02X}": [f"0x{u:04X}" for u in sorted(us)[:40]]
                   for p, us in usages_by_page.items()},
    }
    return items, summary


def collect(path, vid, pid):
    data = plistlib.loads(Path(path).read_bytes())
    out = []

    def walk(o):
        if isinstance(o, dict):
            if isinstance(o.get("ReportDescriptor"), bytes):
                v = o.get("VendorID")
                p = o.get("ProductID")
                if (vid is None or v == vid) and (pid is None or p == pid):
                    out.append(o)
            for x in o.values():
                walk(x)
        elif isinstance(o, list):
            for x in o:
                walk(x)
    walk(data)
    return out


def main():
    args = sys.argv[1:]
    plist = args[0] if args and not args[0].startswith("--") else "/tmp/hid_devices2.xml"
    vid = pid = None
    for j, a in enumerate(args):
        if a == "--vid" and j + 1 < len(args):
            vid = int(args[j + 1], 0)
        if a == "--pid" and j + 1 < len(args):
            pid = int(args[j + 1], 0)
    if vid is None:
        vid = 0x2320
    if pid is None:
        pid = 0x0912

    devs = collect(plist, vid, pid)
    print(f"HID 接口数（VID=0x{vid:04X} PID=0x{pid:04X}）: {len(devs)}\n")
    seen = set()
    overall = {"digitizer_page": False, "touchpad_collection": False,
               "contact_count": False, "finger_collections": 0,
               "has_wheel": False}
    for idx, o in enumerate(devs):
        d = o["ReportDescriptor"]
        if d in seen:
            continue
        seen.add(d)
        print("=" * 78)
        print(f"接口 #{idx}: Product={o.get('Product')} "
              f"PrimaryUsagePage=0x{(o.get('PrimaryUsagePage') or 0):02X} "
              f"PrimaryUsage=0x{(o.get('PrimaryUsage') or 0):04X} "
              f"Transport={o.get('Transport')} descLen={len(d)}")
        print("=" * 78)
        items, s = parse_desc(d)
        for line in items:
            print(line)
        print("\n-- 判据 --")
        for k in ("pages", "digitizer_page", "touchpad_collection", "contact_count",
                  "finger_collections", "relative_bits", "absolute_bits",
                  "has_button_page", "has_wheel"):
            print(f"   {k}: {s[k]}")
        for k in overall:
            overall[k] = overall[k] or bool(s[k]) if isinstance(overall[k], bool) else overall[k] + s[k]
        print()

    print("=" * 78)
    print("结论")
    print("=" * 78)
    real = (overall["digitizer_page"] and overall["touchpad_collection"]
            and overall["contact_count"] and overall["finger_collections"] >= 2)
    if real:
        print("  ✔ 描述符声明了 Digitizer/TouchPad + ContactCount + 多个 Finger 集合")
        print("    → 硬件上报多指原始坐标，macOS 原生手势或 DEXT 可实现")
    else:
        print("  ✘ 未发现 0x0D Digitizer / TouchPad / ContactCount / 多 Finger 集合")
        print("    → 触摸板是标准 HID Mouse（相对位移 + 按键），硬件不上报触点数/坐标")
        print("    → 真正的多点触控（捏合、旋转、三/四指滑动）在此硬件上无法实现")
    print(f"  滚轮(Wheel) 通道: {'有' if overall['has_wheel'] else '无'}"
          "  ← 若固件把双指滑动合成滚轮，可做软件层『伪手势』")


if __name__ == "__main__":
    main()
