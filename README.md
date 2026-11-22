# Flydigi Vader 5 Pro on Linux & Steam

Native SDL3 HIDAPI support for the Flydigi Vader 5 Pro (`37d7:2401`) on Linux—giving Steam Input direct access to **M1–M4, LM, RM, C, Z, Circle, gyro/accel, 4-motor trigger rumble, and Xbox-compatible ordinary rumble** with **no Windows VM, no Flydigi Space Station, no virtual Xbox controller, and no Steam launcher wrappers**.

## Why this exists

Out of the box on Linux, three gaps keep the Vader 5 Pro from working properly in Steam:

1. **Onboard third-party lock:** Firmware `7.1.x` ships with `ThirdPartyEnabled=0`, which blocks SDL3 from acquiring USB interface 1 and forces Steam back to the generic Xbox controller on interface 0 (`xpad`). Flydigi only exposes that toggle in the Windows Space Station app.
2. **Steam's bundled SDL3 lags upstream:** Even with the flag enabled, Steam's shipped `libSDL3.so.0` can lag behind upstream SDL3 `main` fixes for Vader 5 Pro.
3. **Ordinary game rumble vs. trigger feel:** Games that send standard two-motor Xbox rumble (`SDL_RumbleGamepad`) rely on the controller firmware's `xpad` force-feedback path on interface 0 to engage the trigger motors alongside the grips. Pure Flydigi HID rumble (`0x12`) only shakes the grips unless a game explicitly calls `SDL_RumbleGamepadTriggers`.

| Capability | Stock Linux (`xpad`) | Upstream SDL3 + flag | This setup |
|---|:---:|:---:|:---:|
| Extra buttons (M1–M4, LM, RM, C, Z, Circle) | No | Yes | Yes |
| Gyro / IMU + battery telemetry | No | Yes | Yes |
| Single controller in Steam (no duplicate pad) | Yes | Yes | Yes |
| Ordinary 2-motor game rumble with firmware trigger feel | Yes | Grips only | Yes |
| Independent 4-motor `SDL_RumbleGamepadTriggers` | No | Yes | Yes |
| Enable firmware flag directly from Linux (no Windows) | No | No | Yes |
| Normal Steam launches & self-updates (no wrapper) | Yes | Yes | Yes |

## Architecture

```text
Vader 5 Pro (37d7:2401)
 ├── USB Interface 0 (xpad)
 │    └── /dev/input/event* (hidden from Steam, opened privately for FF_RUMBLE)
 │                                              ▲
 └── USB Interface 1 (vendor HID)               │ ordinary 2-motor rumble
      └── /dev/hidraw* (uaccess via udev rule)  │
           ├── tools/vader5-thirdparty.py  ──► persistent ThirdPartyEnabled=1 (0x11)
           └── steamrt64/libSDL3.so.0      ──► Steam Input (M1–M4, LM/RM, C/Z, O, gyro, 4-motor rumble)
                (Sniper SDK build + xpad FF patch, size-padded to Steam manifest)
```

- **No virtual controller:** Steam talks directly to the physical Flydigi HID interface.
- **No `bwrap` or `.desktop` wrapper:** The built library is compiled inside Valve's Steam Runtime 3 (`sniper`) SDK container (`<= GLIBC_2.31`, `SDL_WAYLAND=OFF` so `steamwebhelper` always receives an X11/XWayland window handle) and padded with trailing zero bytes to match Steam's exact manifest byte size. Steam's startup check (`Verifying file sizes only`) passes untouched, and Steam client updates overwrite the file cleanly without `EBUSY` failures.
- **Pre-deploy safety gates:** Before touching any Steam file, the installer verifies `ELF64`, `SONAME`, `RUNPATH=$ORIGIN`, size headroom, and 100% symbol coverage across every binary in `steamrt64/*`, and saves a receipt-guarded backup of Steam's stock libraries.

## Prerequisites

- Native 64-bit Linux Steam (`~/.local/share/Steam/steamrt64/`; Flatpak Steam is not supported).
- `git`, `patch`, `python3`, `binutils` (`readelf`, `nm`), and `podman` (recommended) or `docker`:
  - **Arch / SteamOS / CachyOS:** `sudo pacman -S --needed git patch python binutils podman`
  - **Fedora / Bazzite:** `sudo dnf install -y git patch python3 binutils podman`
  - **Ubuntu / Debian:** `sudo apt-get install -y git patch python3 binutils podman`

## Install

1. Close Steam completely (`steam -shutdown` or Quit from the tray).
2. Wake or plug in the Vader 5 Pro.
3. Run:
   ```sh
   make install
   ```
4. Launch Steam normally.

In **Steam → Settings → Controller → Detected Controllers**, you should see a single **Flydigi Vader 5 Pro** with the full extended button layout available in Steam Input.

> **Note on the first run:** `make install` pulls the SteamRT Sniper SDK image once (~1.3 GiB), checks out a pinned, tested SDL3 commit so the patch applies cleanly without manual conflict resolution, builds `libSDL3.so.0`, installs `/etc/udev/rules.d/60-vader5-sdl.rules`, and flips `ThirdPartyEnabled=1` in the controller's flash. Subsequent runs reuse the cached image and build and finish in a few seconds.

## Day-to-day commands

Run `make` with no arguments to see all targets:

| Command | When to use it |
|---|---|
| `make install` | First install, or re-applying after a Steam client update |
| `make uninstall` | Restore Steam's stock `libSDL3.so*` and remove installed files |
| `make update-sdl` | Opt into latest upstream SDL3 `main` and rebuild |
| `make rebuild` | Force a clean CMake reconfigure and rebuild |
| `make status` | Check firmware version, battery, `ThirdPartyEnabled`, and current HID owner |
| `make enable` / `make disable` | Toggle `ThirdPartyEnabled` directly over Linux `hidraw` (`7.1.x` firmware) |
| `make check` | Lint `scripts/install.sh` and `scripts/uninstall.sh` |

To force raw Flydigi HID rumble instead of the hidden `xpad` backend for ordinary rumble, set `SDL_JOYSTICK_HIDAPI_FLYDIGI_VADER5_XPAD_RUMBLE=0`.

## Updating & uninstalling

- **After a Steam client update:** Let Steam update normally, close Steam, and run `make install`. The installer detects Steam's new stock binary, refreshes its stock backup automatically, re-pads to the new manifest size, and redeploys.
- **Uninstalling:** Close Steam and run `make uninstall`. It only restores backed-up files if Steam's copy still matches the deployed SHA-256 receipt (so it will never overwrite a newer Steam update unless you pass `--force` to `scripts/uninstall.sh`). The controller's flash flag is left untouched; run `make disable` if you also want to turn `ThirdPartyEnabled` off.

## File layout

```text
~/sdl-build/SDL-main-vader5/                     # SDL3 source and Sniper build tree
~/.local/share/vader5-driver/backups/steamrt64/  # stock Steam libSDL3 backups
~/.local/share/vader5-driver/deployed/steamrt64/ # SHA-256 receipts of deployed files
~/.local/share/vader5-driver/sdl/libSDL3-64.so.0 # unpadded build for standalone probes
/etc/udev/rules.d/60-vader5-sdl.rules            # user hidraw uaccess ACL rule
```

## Companion tools & further reading

- **Desktop hotkeys alongside Steam:** Because `ThirdPartyEnabled=1` streams standard `5a a5 ef` extended reports on `/dev/hidraw*`, an observe-only userspace daemon such as [vader5-actions](https://github.com/11xx/vader5-actions) can bind extra buttons and chords to desktop shortcuts or shell commands concurrently without interfering with Steam Input.
- **Deep dive & diagnostics:** See [FIX.md](FIX.md) for the `7.1.x` HID protocol table, rumble internals, log validation commands, and standalone C probes (`tools/sdl_rumble_probe.c`, `tools/sdl_event_probe.c`).

## Troubleshooting

- **Shows as `Generic X-Box pad`:** Run `make status`. If `Third-party: disabled`, run `make enable` while the pad is awake, then restart Steam.
- **Verify Steam's controller path:**
  ```sh
  grep -n 'Flydigi\|Vader\|HIDAPI\|37d7\|2401' ~/.local/share/Steam/logs/controller.txt | tail -40
  ```
- **Verify `xpad` is still bound for haptics:**
  ```sh
  ls /sys/bus/usb/drivers/xpad/
  ```
- **Don't want containers?** Run `bash scripts/install.sh --native` to compile with host `gcc`/`cmake`/`ninja` and local SDL3 dev headers (Sniper SDK is strongly preferred for exact Steam Runtime 3 ABI parity).
