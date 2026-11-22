#!/usr/bin/env python3
"""Inspect or toggle the Flydigi Vader 5 Pro third-party mapping firmware flag.

Communicates directly with the controller's vendor HID interface (37d7:2401,
USB interface 1) over Linux hidraw without requiring Flydigi Space Station.

Command frames (32-byte unnumbered output reports, prefixed with 0x00 for
Linux hidraw):
  0x01: GET_INFO   -> 5a a5 01 02 03
  0x10: GET_STATUS -> 5a a5 10 02 12
  0x11: SET_STATUS -> 5a a5 11 07 ff ff ff ff <0|1> <checksum>

The 0x11 payload format is validated for firmware 7.1.x (0x7141 <= fw < 0x7200).
"""

from __future__ import annotations

import argparse
import errno
import json
import os
import select
import sys
import time
from pathlib import Path

VENDOR_ID = 0x37D7
PRODUCT_ID = 0x2401
MAGIC = b"\x5a\xa5"
CMD_GET_INFO = 0x01
CMD_GET_STATUS = 0x10
CMD_SET_STATUS = 0x11
MIN_FW = 0x7141
MAX_FW_EXCLUSIVE = 0x7200
REPORT_LEN = 32


def checksum(frame: bytes) -> int:
    return sum(frame) & 0xFF


def build_cmd(cmd_id: int, payload: bytes = b"") -> bytes:
    length = len(payload) + 2
    body = bytes([cmd_id, length]) + payload
    frame = MAGIC + body + bytes([checksum(body)])
    if len(frame) > REPORT_LEN:
        raise ValueError(f"command too long: {len(frame)} bytes")
    return b"\x00" + frame.ljust(REPORT_LEN, b"\x00")


def find_vader5_hidraw() -> Path | None:
    sys_hidraw = Path("/sys/class/hidraw")
    if not sys_hidraw.is_dir():
        return None

    candidates: list[tuple[int, Path]] = []
    for entry in sorted(sys_hidraw.iterdir()):
        uevent_path = entry / "device" / "uevent"
        if not uevent_path.is_file():
            continue
        uevent = uevent_path.read_text(errors="replace")
        vid = pid = None
        for line in uevent.splitlines():
            if line.startswith("HID_ID="):
                parts = line.split("=", 1)[1].split(":")
                if len(parts) == 3:
                    vid = int(parts[1], 16)
                    pid = int(parts[2], 16)
                break
        if vid != VENDOR_ID or pid != PRODUCT_ID:
            continue

        dev_path = Path("/dev") / entry.name
        iface_num = -1
        try:
            usb_iface = (entry / "device").resolve().parent
            iface_file = usb_iface / "bInterfaceNumber"
            if iface_file.is_file():
                iface_num = int(iface_file.read_text().strip(), 16)
        except OSError:
            pass

        # Prefer USB interface 1 (the vendor HID control interface on the dongle).
        priority = 0 if iface_num == 1 else 1
        candidates.append((priority, dev_path))

    if not candidates:
        return None
    candidates.sort(key=lambda item: (item[0], str(item[1])))
    return candidates[0][1]


def open_hidraw(dev_path: Path, writable: bool) -> int:
    flags = (os.O_RDWR if writable else os.O_RDONLY) | os.O_NONBLOCK
    return os.open(str(dev_path), flags)


def drain(fd: int) -> None:
    while True:
        r, _, _ = select.select([fd], [], [], 0.0)
        if not r:
            break
        try:
            if not os.read(fd, 64):
                break
        except BlockingIOError:
            break


def normalize_report(raw: bytes) -> bytes:
    if len(raw) >= 3 and raw[1:3] == MAGIC:
        return raw[1:]
    return raw


def query_reply(fd: int, frame: bytes, expect_cmd: int, timeout: float = 0.8) -> bytes | None:
    drain(fd)
    os.write(fd, frame)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        r, _, _ = select.select([fd], [], [], min(0.05, remaining))
        if not r:
            continue
        try:
            raw = os.read(fd, 64)
        except BlockingIOError:
            continue
        data = normalize_report(raw)
        if len(data) >= 3 and data[0:2] == MAGIC and data[2] == expect_cmd:
            return data
    return None


def parse_info(data: bytes) -> dict[str, object]:
    fw = (data[15] << 8) | data[16]
    fw_str = f"{(fw >> 12) & 0xF}.{(fw >> 8) & 0xF}.{(fw >> 4) & 0xF}.{fw & 0xF}"
    conn_code = data[6]
    conn = {1: "wired", 2: "wireless"}.get(conn_code, f"unknown({conn_code})")
    bat_status = (data[11] >> 4) & 0xF
    bat_level = data[11] & 0xF
    bat_pct = 100 if bat_status == 2 else min(100, bat_level * 20)
    return {
        "device_id": data[5],
        "connection": conn,
        "firmware_hex": f"0x{fw:04x}",
        "firmware": fw_str,
        "firmware_u16": fw,
        "battery_percent": bat_pct,
        "battery_status": bat_status,
    }


def parse_status(data: bytes) -> dict[str, object]:
    flags = list(data[5:10])
    owner = data[10:].split(b"\x00", 1)[0].decode("ascii", errors="replace")
    return {
        "flags": flags,
        "third_party_enabled": data[9] == 1,
        "owner": owner,
    }


def read_state(fd: int) -> tuple[dict[str, object], dict[str, object]]:
    info_raw = None
    for _ in range(3):
        info_raw = query_reply(fd, build_cmd(CMD_GET_INFO), CMD_GET_INFO)
        if info_raw is not None:
            break
    if info_raw is None:
        raise TimeoutError("Controller did not respond to GET_INFO (is it awake?)")

    status_raw = None
    for _ in range(3):
        status_raw = query_reply(fd, build_cmd(CMD_GET_STATUS), CMD_GET_STATUS)
        if status_raw is not None:
            break
    if status_raw is None:
        raise TimeoutError("Controller did not respond to GET_STATUS")

    return parse_info(info_raw), parse_status(status_raw)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Inspect or toggle the Vader 5 Pro third-party mapping firmware flag."
    )
    parser.add_argument(
        "action",
        nargs="?",
        default="status",
        choices=("status", "enable", "disable"),
        help="Action to perform (default: status)",
    )
    parser.add_argument("--device", type=Path, help="Explicit /dev/hidrawN path")
    parser.add_argument(
        "--force",
        action="store_true",
        help="Send write even if firmware is outside 7.1.x or flag already matches",
    )
    parser.add_argument("--json", action="store_true", help="Output JSON")
    args = parser.parse_args()

    dev_path = args.device or find_vader5_hidraw()
    if dev_path is None:
        msg = "Flydigi Vader 5 Pro (37d7:2401) hidraw interface not found (wake or plug in controller)"
        if args.json:
            print(json.dumps({"ok": False, "error": msg}))
        else:
            print(f"[err ] {msg}", file=sys.stderr)
        return 2

    try:
        fd = open_hidraw(dev_path, writable=True)
    except OSError as exc:
        if exc.errno == errno.EACCES:
            msg = f"Permission denied opening {dev_path} — install 60-vader5-sdl.rules and reload udev"
        else:
            msg = f"Failed to open {dev_path}: {exc}"
        if args.json:
            print(json.dumps({"ok": False, "device": str(dev_path), "error": msg}))
        else:
            print(f"[err ] {msg}", file=sys.stderr)
        return 1

    try:
        info, status = read_state(fd)
        changed = False

        if args.action in ("enable", "disable"):
            target = args.action == "enable"
            fw = int(info["firmware_u16"])
            if not args.force and not (MIN_FW <= fw < MAX_FW_EXCLUSIVE):
                raise RuntimeError(
                    f"Refusing to write SET_STATUS on firmware {info['firmware']} ({info['firmware_hex']}); "
                    f"validated range is 0x{MIN_FW:04x}..0x{MAX_FW_EXCLUSIVE - 1:04x} (pass --force to override)"
                )

            if status["third_party_enabled"] != target or args.force:
                payload = bytes([0xFF, 0xFF, 0xFF, 0xFF, 0x01 if target else 0x00])
                os.write(fd, build_cmd(CMD_SET_STATUS, payload))
                time.sleep(0.15)
                _, status = read_state(fd)
                if status["third_party_enabled"] != target:
                    raise RuntimeError(
                        f"SET_STATUS did not persist expected third_party_enabled={target} "
                        f"(readback flags={status['flags']})"
                    )
                changed = True

        result = {
            "ok": True,
            "device": str(dev_path),
            "action": args.action,
            "changed": changed,
            "info": {k: v for k, v in info.items() if k != "firmware_u16"},
            "status": status,
        }
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            print(f"Device:       {dev_path}")
            print(
                f"Controller:   device_id={info['device_id']} connection={info['connection']} "
                f"firmware={info['firmware']} ({info['firmware_hex']}) battery={info['battery_percent']}%"
            )
            print(
                f"Third-party:  {'enabled' if status['third_party_enabled'] else 'disabled'} "
                f"(flags={status['flags']}, owner={status['owner'] or '<none>'})"
            )
            if args.action in ("enable", "disable"):
                print(f"Result:       {'updated' if changed else 'already in requested state'}")
        return 0
    except TimeoutError as exc:
        if args.json:
            print(json.dumps({"ok": False, "device": str(dev_path), "error": str(exc)}))
        else:
            print(f"[err ] {exc}", file=sys.stderr)
        return 2
    except Exception as exc:
        if args.json:
            print(json.dumps({"ok": False, "device": str(dev_path), "error": str(exc)}))
        else:
            print(f"[err ] {exc}", file=sys.stderr)
        return 1
    finally:
        os.close(fd)


if __name__ == "__main__":
    raise SystemExit(main())
