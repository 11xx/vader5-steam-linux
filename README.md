# Flydigi Vader 5 Pro — native SDL3 HIDAPI on Linux

Enables native Flydigi Vader 5 Pro (`37d7:2401`) support in Steam on Linux with full Steam Input access to M1–M4, LM, RM, C, Z, Circle, gyro, and Xbox-compatible ordinary rumble plus trigger rumble—without Windows, Flydigi Space Station, virtual controllers, or launcher wrappers.

## Install

Close Steam first, wake or plug in the controller, and run:

```sh
bash scripts/install.sh
```

The installer:

1. Clones or updates upstream SDL3 (`main`) and applies the local Linux `xpad` `FF_RUMBLE` patch ([sdl-flydigi-vader5-linux.patch](sdl-flydigi-vader5-linux.patch)).
2. Builds 64-bit `libSDL3.so.0` inside Valve's Steam Runtime 3 (`sniper`) SDK container via `podman` or `docker` (with `--native` available as a host-toolchain option).
3. Verifies ELF metadata, ABI (`SONAME`, `RUNPATH=$ORIGIN`), size headroom, and full symbol coverage against Steam's `steamrt64/` binaries.
4. Backs up Steam's stock `steamrt64/libSDL3.so.0` and `steamrt64/libSDL3.so`, then installs the patched library padded with trailing zero bytes to match Steam's manifest file size.
5. Installs `/etc/udev/rules.d/60-vader5-sdl.rules` for user-level `/dev/hidraw*` access.
6. Enables the controller's persistent third-party mapping firmware flag (`0x11` command) via [tools/vader5-thirdparty.py](tools/vader5-thirdparty.py).

Start Steam normally afterwards. In **Steam → Settings → Controller → Detected Controllers**, the controller appears as **Flydigi Vader 5 Pro** with the full extended button surface visible in Steam Input.

For protocol details, validation commands, and rumble notes, see [FIX.md](FIX.md).

To restore Steam's stock SDL3 libraries and remove installed files:

```sh
bash scripts/uninstall.sh
```

## Firmware third-party mapping switch

Vader 5 Pro firmware (`7.1.x`, `>= 0x7141`) gates its Flydigi HIDAPI acquire handshake (`0x1C`) behind a persistent onboard flag (`ThirdPartyEnabled`, byte 9 of the `0x10` status response). When that flag is `0`, SDL3 leaves the HIDAPI device unavailable and Steam falls back to the generic Xbox controller on interface 0.

`tools/vader5-thirdparty.py` inspects and toggles that flag directly over Linux `hidraw`:

```sh
./tools/vader5-thirdparty.py status
./tools/vader5-thirdparty.py enable
./tools/vader5-thirdparty.py disable
```

The flag persists in the controller's onboard flash across power cycles and reconnects. The `enable`/`disable` write checks that the controller is running validated `7.1.x` firmware (`0x7141`–`0x71ff`) before sending the `0x11` command.

## How it works

### USB interface layout

The Vader 5 Pro exposes two USB interfaces:

| Interface | Driver | Role |
|---|---|---|
| 0 (XInput) | `xpad` kernel module | Standard Xbox input and Linux `FF_RUMBLE` force feedback |
| 1 (Flydigi HID) | SDL3 HIDAPI (`SDL_HIDAPI_DriverFlydigi`) | 32-byte unnumbered reports (`5a a5 ef ...`) carrying M1–M4, LM, RM, C, Z, Circle, IMU, battery, and 4-motor rumble |

Upstream SDL3 `main` handles the Vader 5 Pro HIDAPI protocol, button/axis/IMU decoding, four-motor HID rumble (`0x12`), hotplug reacquire, and automatic hiding of the duplicate Linux `xpad` joystick once the controller's third-party flag is enabled.

### Why the local SDL patch exists

Games that drive ordinary two-motor Xbox rumble (`SDL_RumbleGamepad`) rely on the controller firmware's Xbox-compatible rumble path on interface 0 (`xpad`) to produce trigger participation alongside grip vibration. Sending two-motor rumble exclusively over the raw Flydigi HID command (`5a a5 12 ...`) only drives the grip motors unless the caller explicitly invokes `SDL_RumbleGamepadTriggers`.

[sdl-flydigi-vader5-linux.patch](sdl-flydigi-vader5-linux.patch) keeps `xpad` bound to interface 0, lets upstream SDL3 hide the duplicate `xpad` joystick from applications, and routes ordinary `SDL_RumbleGamepad` calls for `37d7:2401` through that hidden `/dev/input/event*` `FF_RUMBLE` node (matched via `/sys/class/input/eventN/device/device` → `:1.0`). If the `xpad` event node is unavailable—or if `SDL_JOYSTICK_HIDAPI_FLYDIGI_VADER5_XPAD_RUMBLE=0` is set—it falls back to upstream `HIDAPI_DriverFlydigi_SendRumbleV2`. Direct trigger-rumble calls (`SDL_RumbleGamepadTriggers`) always use upstream's 4-motor Flydigi HID path.

### Direct Steam deployment and Sniper SDK ABI

The Linux Steam client runs natively as 64-bit `steamrt64/steam` inside Steam Runtime 3 (`steamrt3c` Pressure Vessel) and links `steamrt64/libSDL3.so.0` via `DT_NEEDED` with `RUNPATH=$ORIGIN`.

- Building inside `registry.gitlab.steamos.cloud/steamrt/sniper/sdk:latest` targets the exact Steam Runtime 3 glibc ABI (`<= GLIBC_2.31`) with the same dynamically loaded SDL3 feature set Valve ships (`*_SHARED=ON` for X11, PipeWire, PulseAudio, ALSA, DBus, libusb, Vulkan, OpenGL, and GPU, with `SDL_WAYLAND=OFF` so `steamwebhelper` always receives an X11/XWayland window handle) while keeping `DT_NEEDED` minimal (`libc`, `libm`, `libdl`, `libpthread`).
- Steam's startup bootstrapper checks manifest file sizes (`Verifying file sizes only`) on normal launches. Padding the stripped `libSDL3.so.0` with trailing zero bytes to match the stock library's exact byte size lets Steam launch directly without wrappers or repair loops; the ELF loader ignores trailing bytes past the loadable segments.
- When Steam ships a client update, Steam replaces `steamrt64/libSDL3.so*` cleanly with its new stock copy. Re-running `bash scripts/install.sh` records the new stock backup and re-applies the patched library for the updated size.

## Prerequisites

- Native Linux Steam installation with `steamrt64/` (Flatpak Steam is not supported).
- `git`, `patch`, `python3`, `binutils` (`readelf`, `nm`), and `podman` or `docker` for Sniper SDK builds (or host `gcc`, `cmake`, `ninja`, and SDL3 dev headers when passing `--native`).

## File layout

```text
~/sdl-build/SDL-main-vader5/                     # SDL3 source and build directory
~/.local/share/vader5-driver/backups/steamrt64/  # stock Steam libSDL3 backups
~/.local/share/vader5-driver/deployed/steamrt64/ # SHA-256 receipts of deployed files
~/.local/share/vader5-driver/sdl/libSDL3-64.so.0 # unpadded build for local probe tools
/etc/udev/rules.d/60-vader5-sdl.rules            # user hidraw ACL rule
```

## Troubleshooting

**Controller shows as Generic X-Box pad:**

1. Confirm the firmware third-party flag is enabled:
   ```sh
   ./tools/vader5-thirdparty.py status
   ```
   If `Third-party: disabled`, run `./tools/vader5-thirdparty.py enable`.
2. Confirm Steam is running with the patched SDL3 and HIDAPI driver:
   ```sh
   grep -n 'Flydigi\|Vader\|HIDAPI\|37d7\|2401' ~/.local/share/Steam/logs/controller.txt | tail -40
   ```
3. Confirm `xpad` is bound to interface 0:
   ```sh
   ls /sys/bus/usb/drivers/xpad/
   ```

**After a Steam client update:**

Steam overwrites `steamrt64/libSDL3.so.0` when updating the client. Close Steam and re-run `bash scripts/install.sh` to re-deploy against the updated client (once Valve bundles the same upstream SDL3 changes, the third-party flag and udev rule alone are enough unless you also want the `xpad` ordinary-rumble backend).
