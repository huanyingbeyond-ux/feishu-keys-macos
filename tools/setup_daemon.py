#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
飞鼠按键守护进程安装 / 卸载脚本

用法:
    python3 setup_daemon.py           安装（编译 + 映射表 + LaunchAgent + 清理无效旧配置）
    python3 setup_daemon.py --reset  卸载（停守护进程、删自启、恢复 Karabiner 抓取、清空键映射）

说明:
    Karabiner-Elements 14.13.0 不认识飞鼠发出的 AC_Search(0x221) 等 Consumer Usage，
    hidutil 的 UserKeyMapping 又只作用于 Keyboard Page，对 Consumer / SystemControl 无效。
    因此改由 FeishuKeys 守护进程直接读 HID 原始报告（Report ID 1/2/3）并执行动作。
    为避免 Karabiner 独占(seize)设备导致守护进程收不到报告，安装时会把飞鼠加入
    karabiner.json 的 devices.ignore 列表。

注意（重编译必读）:
    FeishuKeys 是未签名二进制，TCC 的「输入监控 / 辅助功能」授权会绑定它的
    cdhash 并缓存于 /Library/Application Support/com.apple.TCC/AdhocSignatureCache。
    每次重编译后授权都会失效（启动日志出现 manager open=-536870174），
    需以管理员权限刷新一次授权记录，再让 KeepAlive 重启进程：
      sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
        "UPDATE access SET csreq=NULL, last_modified=CAST(strftime('%s','now') AS INTEGER) \
         WHERE client LIKE '%feishu-keys/FeishuKeys';"
      killall FeishuKeys
    只改 mapping.json 不需要这一步（每次按键热加载）。
    调试入口：向 /tmp/feishu_keys_trigger 写入动作名即可执行一次，无需物理按键。
"""

import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
HOME = Path.home()
DAEMON = HERE / "FeishuKeys"
SWIFT = HERE / "FeishuKeys.swift"
MAPPING_SRC = HERE / "mapping.json"
CONFIG_DIR = HOME / ".config/feishu-keys"
MAPPING_DST = CONFIG_DIR / "mapping.json"
KARABINER_JSON = HOME / ".config/karabiner/karabiner.json"
LAUNCH_DIR = HOME / "Library/LaunchAgents"
AGENT_PLIST = LAUNCH_DIR / "com.dean.feishu-keys.plist"
OLD_AGENT_PLIST = LAUNCH_DIR / "com.dean.feishu-hidmap.plist"
LABEL = "com.dean.feishu-keys"
OLD_LABEL = "com.dean.feishu-hidmap"

VID, PID = 8992, 2322  # 0x2320 / 0x0912


def run(args, check=False):
    r = subprocess.run(args, capture_output=True, text=True)
    if check and r.returncode:
        print(f"  ! {args[0]} 返回 {r.returncode}: {r.stderr.strip()[:200]}")
    return r


def agent_plist_bytes():
    data = {
        "Label": LABEL,
        "ProgramArguments": [str(DAEMON)],
        "RunAtLoad": True,
        "KeepAlive": True,
        "LimitLoadToSessionType": "Aqua",
        "StandardOutPath": "/tmp/feishu_keys_stdout.log",
        "StandardErrorPath": "/tmp/feishu_keys_stderr.log",
        "ProcessType": "Interactive",
    }
    return plistlib.dumps(data)


def set_karabiner_ignore(ignore: bool):
    if not KARABINER_JSON.exists():
        return
    try:
        d = json.loads(KARABINER_JSON.read_text(encoding="utf-8"))
        prof = d["profiles"][0]
    except Exception as e:
        print(f"  ! karabiner.json 解析失败，跳过: {e}")
        return
    if ignore:
        prof["devices"] = [
            {
                "identifiers": {
                    "vendor_id": VID, "product_id": PID,
                    "is_keyboard": kb, "is_pointing_device": pt,
                    "is_game_pad": False,
                },
                "ignore": True,
            }
            for kb, pt in [(True, False), (False, True)]
        ]
    else:
        prof["devices"] = []
    KARABINER_JSON.write_text(json.dumps(d, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"  Karabiner devices.ignore = {ignore}")


def clear_hidutil():
    run(["/usr/bin/hidutil", "property", "--set", '{"UserKeyMapping":[]}'])


def stop_old_agent():
    r = run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{OLD_LABEL}"])
    if r.returncode == 0:
        print(f"  已卸载旧自启 {OLD_LABEL}")
    if OLD_AGENT_PLIST.exists():
        OLD_AGENT_PLIST.unlink()
        print("  已删除旧 LaunchAgent plist")


def install():
    print("== 1/6 编译守护进程 ==")
    r = subprocess.run(["/usr/bin/swiftc", "-O", str(SWIFT), "-o", str(DAEMON)],
                       capture_output=True, text=True, cwd=str(HERE))
    if r.returncode:
        print("编译失败:", r.stderr[:800]); return False
    print("  OK ->", DAEMON)

    print("== 2/6 安装映射表 ==")
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    MAPPING_DST.write_text(MAPPING_SRC.read_text(encoding="utf-8"), encoding="utf-8")
    print(f"  OK -> {MAPPING_DST} ({len(json.loads(MAPPING_SRC.read_text()))} 条)")

    print("== 3/6 清除无效的 hidutil 映射 ==")
    clear_hidutil()
    print("  OK (实测证明对 Consumer/SystemControl 页无效)")

    print("== 4/6 让 Karabiner 忽略飞鼠（释放设备独占）==")
    set_karabiner_ignore(True)

    print("== 5/6 安装 LaunchAgent ==")
    stop_old_agent()
    run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"])
    LAUNCH_DIR.mkdir(parents=True, exist_ok=True)
    AGENT_PLIST.write_bytes(agent_plist_bytes())
    r = run(["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", str(AGENT_PLIST)])
    if r.returncode:
        print("  bootstrap 返回", r.returncode, r.stderr.strip()[:200])
        print("  (若受沙箱限制，改用系统授权执行 launchctl bootstrap)")
    else:
        print("  已加载", LABEL)

    print("== 6/6 验证 ==")
    r = run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{LABEL}"])
    print("  launchctl print:", "OK" if r.returncode == 0 else "未注册（下次登录自动加载）")
    return True


def reset():
    print("== 卸载 ==")
    run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"])
    if AGENT_PLIST.exists():
        AGENT_PLIST.unlink(); print("  已删除 LaunchAgent plist")
    run(["/usr/bin/killall", "FeishuKeys"])
    set_karabiner_ignore(False)
    clear_hidutil()
    print("  已恢复 Karabiner 抓取、清空 hidutil 映射")


def check():
    """一键自检：只读，不改动任何配置。"""
    print("== 守护进程 ==")
    r = run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{LABEL}"])
    if r.returncode == 0:
        for line in r.stdout.splitlines():
            if any(k in line for k in ("state =", "pid =", "active count")):
                print(" ", line.strip())
    else:
        print("  LaunchAgent 未注册")
    r = run(["/usr/bin/pgrep", "-fl", "FeishuKeys"])
    print("  进程:", r.stdout.strip() or "无")

    print("== TCC 授权 ==")
    r = subprocess.run(
        ["/usr/bin/sqlite3", "/Library/Application Support/com.apple.TCC/TCC.db",
         "select service||' -> '||auth_value from access where client like '%FeishuKeys%';"],
        capture_output=True, text=True)
    print(" ", r.stdout.strip().replace("\n", "\n  ") or "无记录")

    print("== Karabiner 是否已释放飞鼠 ==")
    try:
        d = json.loads(KARABINER_JSON.read_text(encoding="utf-8"))
        devs = d["profiles"][0].get("devices", [])
        print("  devices.ignore =", all(x.get("ignore") for x in devs) and len(devs) == 2)
    except Exception as e:
        print("  读取失败:", e)

    print("== 映射表 ==")
    try:
        m = json.loads(MAPPING_DST.read_text(encoding="utf-8"))
        print(f"  {MAPPING_DST}  {len(m)} 条")
    except Exception as e:
        print("  读取失败:", e)

    print("== 最近事件日志 ==")
    try:
        lines = Path("/tmp/feishu_keys.log").read_text(encoding="utf-8").splitlines()
        for line in lines[-12:]:
            print(" ", line)
        if not lines:
            print("  (空 —— 尚未按键)")
    except FileNotFoundError:
        print("  (空 —— 尚未按键)")


if __name__ == "__main__":
    if "--reset" in sys.argv:
        reset()
    elif "--check" in sys.argv:
        check()
    else:
        install()
