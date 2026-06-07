# Vader 5 Pro Steam Fix Notes

This file records the working Linux/Steam approach for the Flydigi Vader 5 Pro
and the debugging findings that led to it.

## Current Result

The controller works through Steam Input using SDL HIDAPI, including:

- Standard controller inputs.
- Extra surface exposed by SDL/Steam: M1-M4, LM, RM, C, Z, and related misc buttons.
- Steam Input remapping for paddles and extra buttons.
- Gyro and extended settings visible in Steam's controller UI.
- Rumble, after routing Vader 5 Pro V2 rumble through the raw interface-1 write path.

Validated manually with:

- Warhammer: Vermintide 2: controller input, Steam Input remapping, paddles, and extra buttons worked.
- Elden Ring Nightreign: initially behaved inconsistently, then worked after the final deployed build.
- Rumble confirmed working after the V2 raw-rumble fix.

Steam may still show a stale or generic UI label in some places. The reliable
validation is the Steam controller log showing the HIDAPI device and full
mapping, not the cached display label.

## What Actually Works

The working stack is:

1. The udev rule unbinds `xpad` from the Vader's interface 0.
2. Steam is launched through `~/.local/share/vader5-driver/wrapper.sh`.
3. The wrapper uses `bubblewrap` to bind-mount patched SDL over Steam's bundled SDL.
4. Patched SDL selects Flydigi HIDAPI on interface 1.
5. Patched SDL sends the same Vader 5 init/test-mode sequence that padctl uses.
6. The controller streams `5a a5 ef ...` extended reports.
7. Steam Input sees the full button surface through SDL HIDAPI.

This is deliberately not a userspace daemon or virtual Xbox/Elite controller.
The controller stays visible to Steam as a real SDL HIDAPI gamepad with extended
buttons.

## Important Validation Commands

Confirm Steam is loading the wrapper-mounted SDL:

```sh
pid=$(pgrep -f 'ubuntu12_32/steam ' | head -1)
grep libSDL3 /proc/$pid/maps | sort -u
```

Inside the wrapper namespace those paths may still print as Steam paths, so
inode comparison is stronger:

```sh
pid=$(pgrep -f 'ubuntu12_32/steam ' | head -1)
stat -c '%i %s %n' \
  ~/.local/share/vader5-driver/sdl/libSDL3-32.so.0 \
  /proc/$pid/root$HOME/.local/share/Steam/ubuntu12_32/libSDL3.so.0 \
  ~/.local/share/vader5-driver/sdl/libSDL3-64.so.0 \
  /proc/$pid/root$HOME/.local/share/Steam/ubuntu12_64/libSDL3.so.0
```

The paired inodes should match.

Confirm Steam's controller path:

```sh
grep -n 'Flydigi\|Vader\|HIDAPI\|37d7\|2401' \
  ~/.local/share/Steam/logs/controller.txt | tail -80
```

Good signs:

- `Product: Flydigi Vader 5 Pro`
- `Controller using HIDAPI driver, vid=0x37d7, pid=0x2401`
- Mapping includes `paddle1` through `paddle4`
- Mapping includes `misc2` through `misc6`

Confirm `xpad` is not owning interface 0:

```sh
ls /sys/bus/usb/drivers/xpad/ | grep ':1.0' || true
```

For the Vader's USB path, interface `:1.0` should not be bound to `xpad`.

## What Not To Trust

`evtest` is not the success test for this setup.

The whole point of the udev rule is to stop the kernel `xpad` path from winning
and let Steam's SDL HIDAPI path own interface 1. When this fix is working, a
normal `/dev/input/event*` Xbox-style controller may be absent or irrelevant.

Steam's display label can also be stale or misleading. A UI label like
`Generic X-Box pad` does not necessarily mean the fix failed if the controller
log shows the Flydigi HIDAPI mapping with paddles and misc buttons.

## padctl Findings

padctl proved the key protocol behavior:

- The useful input path is interface 1, not the generic Xbox-facing interface.
- Vader 5 Pro streams extended input as 32-byte reports beginning with
  `5a a5 ef`.
- The controller needs an init/test-mode sequence before reliable extended
  streaming.
- The important enable command is:

```text
5a a5 11 07 ff 01 ff ff ff 15 00
```

padctl's Vader 5 config sends these init commands before enabling test mode:

```text
5a a5 01 02 03
5a a5 a1 02 a3
5a a5 02 02 04
5a a5 04 02 06
5a a5 11 07 ff 01 ff ff ff 15 00
```

The SDL patch mirrors that behavior, but keeps Steam as the consumer instead of
creating a virtual Xbox Elite Series 2 device.

## Why Not Run padctl Together With This

Running padctl and this SDL fix at the same time is the wrong model. Both want
to open and control the same physical HID interface.

padctl's model:

- Reads the physical Vader interface.
- Blocks kernel drivers as needed.
- Emits a virtual controller through uinput/UHID.

This repo's model:

- Lets Steam's SDL open the physical Vader interface directly.
- Avoids a virtual controller.
- Lets Steam Input see and remap the extended buttons directly.

The second model better matches the desired behavior: a real Steam Input
controller with extra remappable buttons rather than an Xbox Elite emulation.

## Patch Details

The SDL patch currently does the following:

- Forces `37d7:2401` interface 1 to use `SDL_HIDAPI_DriverFlydigi`.
- Converts Flydigi V2 Vader interface-1 writes into raw 32-byte writes.
- Sends the padctl-derived Vader 5 init sequence.
- Replaces the older Flydigi acquire heartbeat with the Vader test-mode enable
  command.
- Keeps the device available instead of hiding it when the older acquire status
  does not match expectations.
- Sends Vader 5 Pro rumble through the same raw 32-byte interface-1 write path.

The rumble bug that was fixed late in testing:

- The first patch put the Vader-specific raw rumble branch inside the V1 rumble
  block.
- Vader 5 Pro is V2, so rumble still used SDL's generic helper.
- Moving that branch into the V2 path made SDL send `5a a5 12 06 ...` directly
  through the raw write helper.

## Installer Findings

Steam's current Linux client expects `SDL_TryLockJoysticks@@SDL3_0.0.0`.
Older upstream SDL releases did not export it, which is why the original
installer carried a shim.

The current working installer builds SDL `main`, which already exports
`SDL_TryLockJoysticks`. The shim is now optional:

- If the built SDL exports `SDL_TryLockJoysticks`, no shim is installed.
- If a user overrides `SDL_REF`/`SDL_SRC` to an older SDL tree, the shim path
  remains available.

The installer also handles a common cache failure:

- If `~/sdl-build/SDL-main-vader5` exists but is not a git checkout, it now
  reports a clear error instead of failing later with Git's generic
  destination-path message.

## Steam Update Behavior

The wrapper bind-mounts patched SDL over Steam's bundled SDL inside a private
mount namespace. Steam's own files on disk are not modified.

Steam may log verifier messages because, inside the wrapper namespace, its SDL
paths resolve to files with different sizes. That is expected. The important
property is that the verifier cannot replace the host files because the patched
files are only mounted over Steam's paths inside the wrapper namespace.

## Known Caveats

- Flatpak Steam is not supported.
- Steam UI labels can be stale; validate with `controller.txt`.
- Replugging the dongle/controller is required after udev rule changes.
- The fix depends on Steam using its bundled SDL path that the wrapper mounts.
- If Steam updates its client SDL ABI again, rebuilding SDL `main` may be needed.
- Game-specific Steam Input quirks can still exist even when the controller path
  is correct.

## Open Rumble Work

The currently validated Vader 5 Pro rumble packet is:

```text
5a a5 12 06 strong weak 00 00 00 00 ...
```

The SDL patch sends that command through the interface-1 raw write path, which
is enough for normal SDL rumble and has been confirmed in Steam.

The controller may have additional physical trigger motors, but the public
padctl and flydigi-vader5 protocol notes only document the two `strong` and
`weak` rumble bytes. The remaining bytes in the `0x12 0x06` payload are not
mapped yet. Do not blindly expose SDL trigger rumble until those bytes are
identified on hardware.

Use `tools/vader5_rumble_probe.c` to sweep the rumble payload slots and record
which physical motor responds:

```sh
cc tools/vader5_rumble_probe.c -o /tmp/vader5_rumble_probe

# Close Steam first so it is not also writing HID packets.
/tmp/vader5_rumble_probe /dev/hidrawN

# If the undocumented slots do nothing, repeat with the checksum variant:
/tmp/vader5_rumble_probe /dev/hidrawN --checksum
```

Report the physical result as slot numbers, for example `slot 0 = left grip`,
`slot 1 = right grip`, `slot 2 = left trigger`. Once the trigger slots are
known, SDL can advertise `SDL_JOYSTICK_CAP_TRIGGER_RUMBLE` and implement
`HIDAPI_DriverFlydigi_RumbleJoystickTriggers()` for Vader 5 Pro only.

## Steam Input UI Quirks

Assigning extra buttons through Steam Input's normal picker writes a clean
mapping and works reliably. The `Listen` assignment path can create redundant
commands for some extra-button-to-stick-click mappings. This appears to be in
Steam Input's layout editor rather than the SDL event stream: normal buttons
map cleanly, while the extra Vader controls pass through Steam's generic
`switches` source group and can be aliased with stick-click commands.

The practical workaround is to use the picker/controller drawing for extra
buttons when targeting stick clicks, then remove any duplicate subcommand if
`Listen` created one.

## Reboot/Dongle Race

If the dongle stays connected across reboot, Steam can sometimes show both the
fixed HIDAPI controller and a generic Xbox controller until the dongle is
replugged. The likely cause is `xpad` binding interface 0 before the local udev
unbind rule has acted on the already-present USB device.

This is separate from the rumble path. A later fix should make the wrapper run
a preflight unbind for the current `37d7:2401` interface 0 before Steam starts,
or strengthen the udev rule to cover the relevant `add`/`bind` timing.

## Useful Diagnostic Tools

`tools/vader5_raw_probe.c` writes the padctl-derived init/test-mode commands to
a chosen `/dev/hidraw*` node and dumps raw reports. It is useful for confirming
that the physical controller streams `5a a5 ef ...`.

`tools/vader5_rumble_probe.c` sweeps the Vader 5 rumble payload bytes so the
physical motor layout can be discovered safely before adding SDL trigger rumble
support.

`tools/sdl_event_probe.c` opens SDL gamepads and prints button/axis events. It
is useful for checking whether SDL sees the extended buttons without relying on
Steam's UI.

Compile examples:

```sh
cc tools/vader5_raw_probe.c -o /tmp/vader5_raw_probe

cc tools/vader5_rumble_probe.c -o /tmp/vader5_rumble_probe

cc tools/sdl_event_probe.c \
  -I$HOME/sdl-build/SDL-main-vader5/include \
  $HOME/.local/share/vader5-driver/sdl/libSDL3-64.so.0 \
  -Wl,-rpath,$HOME/.local/share/vader5-driver/sdl \
  -o /tmp/sdl_event_probe
```

Do not run the raw probe while Steam is actively using the controller unless
you are intentionally testing device contention.
