# Vader 5 Pro Linux & Steam Technical Notes

Reference notes for the Flydigi Vader 5 Pro (`37d7:2401`) Linux HIDAPI stack, firmware third-party flag, rumble behavior, and validation workflow.

## Architecture Overview

The setup operates directly through Steam's native 64-bit `steamrt64` client and SDL3's `SDL_HIDAPI_DriverFlydigi`:

1. `xpad` stays bound to USB interface 0 (`:1.0`) for kernel Linux `FF_RUMBLE` force feedback.
2. `/etc/udev/rules.d/60-vader5-sdl.rules` grants the active desktop user `uaccess` read/write access to the `37d7:2401` `/dev/hidraw*` vendor interface (`:1.1`).
3. The controller's persistent firmware flag (`ThirdPartyEnabled=1`) allows third-party HIDAPI hosts (including SDL3) to acquire the controller via command `0x1C` (`owner="SDL"`).
4. Upstream SDL3 `main` initializes the device (`0x07`, `0x01`, `0x10`, `0x1C`), decodes the 32-byte `5a a5 ef ...` extended reports (standard buttons, M1–M4, LM, RM, C, Z, Circle, triggers, sticks, gyro/accel, battery), and automatically hides the duplicate Linux `xpad` joystick via `HIDAPI_AddDeviceMatches` / `SDL_RemoveHiddenDevices`.
5. [sdl-flydigi-vader5-linux.patch](sdl-flydigi-vader5-linux.patch) routes `SDL_RumbleGamepad` on Linux through the hidden `xpad` `/dev/input/event*` `FF_RUMBLE` endpoint (with fallback to `HIDAPI_DriverFlydigi_SendRumbleV2`) while leaving `SDL_RumbleGamepadTriggers` on upstream's four-motor Flydigi HID command (`0x12`).
6. The library is built inside Valve's Steam Runtime 3 (`sniper`) SDK container (`registry.gitlab.steamos.cloud/steamrt/sniper/sdk:latest`), stripped, padded with trailing zero bytes to match Steam's manifest byte size, and installed directly into `~/.local/share/Steam/steamrt64/libSDL3.so.0` and `libSDL3.so`.

## Protocol Reference (Firmware `7.1.x`)

Commands on USB interface 1 use unnumbered 32-byte HID output reports (prefixed with a leading `0x00` report ID byte when writing to Linux `/dev/hidraw*`):

- Frame layout: `5a a5 <cmd> <len> <payload...> <checksum>` zero-padded to 32 bytes.
- Checksum: `sum(frame[2 : 2 + len]) & 0xff` (i.e., `cmd + len + sum(payload)` mod 256).

Key commands:

| Command | Payload | Purpose |
|---|---|---|
| `0x01` (`GET_INFO`) | `5a a5 01 02 03` | Reads `deviceID` (`data[5]`), connection type (`data[6]`: `1`=wired, `2`=wireless), battery (`data[11]`), and firmware BCD (`(data[15] << 8) \| data[16]`, e.g. `0x7150` = `7.1.5.0`). |
| `0x07` (`CHECK_ARCH`) | `5a a5 07 00 00` | Architecture query (`versionData[3] == 1 && versionData[4] == 0` indicates new architecture; `7.1.5.0` reports `0`). |
| `0x10` (`GET_STATUS`) | `5a a5 10 02 12` | Returns 5 status bytes in `data[5..9]` and a NUL-terminated owner string at `data[10..]`. `data[9] == 1` is `ThirdPartyEnabled`. |
| `0x11` (`SET_STATUS`) | `5a a5 11 07 ff ff ff ff <0\|1> <csum>` | Updates status flags (`0xff` = leave field unchanged). Setting byte 8 to `0x01` (checksum `0x15`) persists `ThirdPartyEnabled=1`; `0x00` (checksum `0x14`) sets `0`. Validated for `0x7141 <= fw < 0x7200`. |
| `0x12` (`HAPTIC`) | `5a a5 12 06 <lg> <rg> <lt> <rt> 00 00` | Direct four-motor rumble intensities: left grip, right grip, left trigger, right trigger (`0x00`–`0xff`). |
| `0x1C` (`ACQUIRE`) | `5a a5 1c 17 <0\|1> "SDL" ...` | Acquires or releases HIDAPI ownership when `ThirdPartyEnabled=1`. |
| `0xEF` (`INPUT`) | `5a a5 ef ...` | 32-byte extended input + IMU streaming report. |

`tools/vader5-thirdparty.py` implements `status`, `enable`, and `disable` against `0x01`, `0x10`, and `0x11` with firmware-range validation and readback verification.

## Rumble Behavior

USB captures (`usbmon`) of games using ordinary two-motor Xbox rumble show standard `xpad` packets:

```text
00 08 00 <left> <right> 00 00 00
```

On the Vader 5 Pro, the firmware translates ordinary `xpad` force feedback on interface 0 into grip vibration with trigger participation, whereas the raw Flydigi HID command `5a a5 12 06 <lg> <rg> <lt> <rt>` addresses all four motors independently and leaves the trigger motors idle when `<lt>` and `<rt>` are zero.

To preserve both behaviors:

- Ordinary `SDL_RumbleGamepad` calls open the hidden `xpad` `/dev/input/event*` device matching `VID=0x37d7`, `PID=0x2401`, capability `FF_RUMBLE`, and sysfs interface symlink `/sys/class/input/eventN/device/device` ending in `:1.0` (one level deeper than `/sys/class/input/eventN/device`, which points to the intermediate `inputN` node).
- Both `/dev/input/event*` and `/sys/class/input/eventN/device/device` are visible inside Steam's `steamrt3c` Pressure Vessel container, so the `xpad` rumble backend works inside Steam without extra container configuration.
- Set `SDL_JOYSTICK_HIDAPI_FLYDIGI_VADER5_XPAD_RUMBLE=0` to force raw Flydigi HID rumble (`0x12`) for ordinary rumble calls.
- `SDL_RumbleGamepadTriggers` always calls upstream `HIDAPI_DriverFlydigi_SendRumbleV2`, driving slots 2 and 3 directly.

## Validation Commands

### 1. Controller firmware flag

```sh
./tools/vader5-thirdparty.py status
```

Expected output when Steam is running: `Third-party: enabled (flags=[0, 1, 0, 0, 1], owner=SDL)`.

### 2. Steam loaded library check

Verify that the live `steamrt64/steam` process maps the deployed `steamrt64/libSDL3.so.0` and that its SHA-256 matches the installer receipt:

```sh
sha256sum ~/.local/share/Steam/steamrt64/libSDL3.so.0
cat ~/.local/share/vader5-driver/deployed/steamrt64/libSDL3.so.0.sha256
```

### 3. Steam controller log

```sh
grep -n 'Flydigi\|Vader\|HIDAPI\|37d7\|2401' \
  ~/.local/share/Steam/logs/controller.txt | tail -80
```

Expected entries:

- `Product: Flydigi Vader 5 Pro`
- `Controller using HIDAPI driver, vid=0x37d7, pid=0x2401`
- Full mapping containing `paddle1`–`paddle4` and `misc2`–`misc6`
- Only one controller slot active (no duplicate `Generic X-Box pad`)

### 4. Kernel `xpad` binding

```sh
ls /sys/bus/usb/drivers/xpad/ | grep ':1.0'
```

### 5. Standalone probe tools

Close Steam before running hardware probes to avoid concurrent HID reads/writes:

```sh
# Test SDL3 gamepad enumeration, mapping, ordinary xpad rumble, and trigger rumble:
rm -rf /tmp/vader5-sdl-probe-lib && mkdir -p /tmp/vader5-sdl-probe-lib
ln -s "$HOME/.local/share/vader5-driver/sdl/libSDL3-64.so.0" \
  /tmp/vader5-sdl-probe-lib/libSDL3.so.0

cc tools/sdl_rumble_probe.c \
  -I"$HOME/sdl-build/SDL-main-vader5/include" \
  -L/tmp/vader5-sdl-probe-lib \
  -Wl,-rpath,/tmp/vader5-sdl-probe-lib \
  -l:libSDL3.so.0 \
  -o /tmp/sdl_rumble_probe

/tmp/sdl_rumble_probe
```

Additional probes under `tools/`:

- `tools/sdl_event_probe.c` — prints live SDL3 button and axis events.
- `tools/vader5_rumble_probe.c` — sweeps raw `5a a5 12 06 ...` payload slots directly over `/dev/hidrawN`.
- `tools/vader5_raw_probe.c` — dumps raw 32-byte `hidraw` reports.

## Known Caveats

- Flatpak Steam is not supported.
- Steam Input's `Listen` binding helper can emit duplicate subcommands when binding extra buttons to stick clicks; assign those through the visual picker instead.
- Steam's UI display label can briefly show a cached string even when `controller.txt` confirms the HIDAPI Flydigi mapping; trust `controller.txt`.
- Steam client updates overwrite `steamrt64/libSDL3.so*` with new stock files; re-run `bash scripts/install.sh` afterwards to re-apply the patched library cleanly.
- Observe-only companion daemons (such as `vader5-actions` reading `/dev/hidraw*` passively without writing commands) can run alongside Steam cleanly once `ThirdPartyEnabled=1` is active.
