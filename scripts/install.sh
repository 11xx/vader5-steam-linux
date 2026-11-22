#!/usr/bin/env bash
# Build and deploy patched SDL3 for Flydigi Vader 5 Pro support in Steam on Linux.
#
# Builds upstream SDL3 inside the Steam Runtime 3 (Sniper) SDK container with the
# local Linux xpad FF_RUMBLE patch, zero-pads the stripped shared library to match
# Steam's manifest size, installs it directly into Steam's steamrt64 directory,
# installs the udev hidraw access rule, and enables the controller's third-party
# mapping firmware flag when connected.

set -euo pipefail

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    echo "[err ] do NOT run this script with sudo." >&2
    echo "       It installs into your \$HOME and elevates only for /etc udev rules." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"

SDL_REF="${SDL_REF:-main}"
SDL_SRC="${SDL_SRC:-$HOME/sdl-build/SDL-main-vader5}"
SDL_REPO_URL="https://github.com/libsdl-org/SDL.git"
SNIPER_IMAGE="${SNIPER_IMAGE:-registry.gitlab.steamos.cloud/steamrt/sniper/sdk:latest}"

DEPLOY_DIR="$HOME/.local/share/vader5-driver"
SDL_DEPLOY_DIR="$DEPLOY_DIR/sdl"
BACKUP_DIR="$DEPLOY_DIR/backups"
RECEIPT_DIR="$DEPLOY_DIR/deployed"
UDEV_RULE_SRC="$REPO_ROOT/60-vader5-sdl.rules"
UDEV_RULE_DST="/etc/udev/rules.d/60-vader5-sdl.rules"
PATCH_FILE="$REPO_ROOT/sdl-flydigi-vader5-linux.patch"
THIRDPARTY_TOOL="$REPO_ROOT/tools/vader5-thirdparty.py"

BUILD_MODE="auto"
FORCE_REBUILD=0
SKIP_UDEV=0
SKIP_THIRDPARTY=0

usage() {
    cat <<'EOF'
Usage: scripts/install.sh [options]

Options:
  --sniper         Build inside SteamRT Sniper SDK container (podman/docker)
  --native         Build natively on the host instead of inside Sniper SDK
  --rebuild        Force clean CMake configure and rebuild of SDL3
  --skip-udev      Skip installing /etc/udev/rules.d/60-vader5-sdl.rules
  --no-thirdparty  Skip checking/enabling the Vader 5 Pro firmware flag
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sniper)        BUILD_MODE="sniper" ;;
        --native)        BUILD_MODE="native" ;;
        --rebuild)       FORCE_REBUILD=1 ;;
        --skip-udev)     SKIP_UDEV=1 ;;
        --no-thirdparty) SKIP_THIRDPARTY=1 ;;
        -h|--help)       usage; exit 0 ;;
        *)               echo "[err ] Unknown option: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[info]${NC} $*"; }
ok()   { echo -e "${GREEN}[ ok ]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[err ]${NC} $*" >&2; }

PATCH_SHA="$(sha256sum "$PATCH_FILE" | awk '{print $1}')"

# ── 1. Locate Steam and ensure it is not running ──────────────────────────────

STEAM_ROOT=""
for candidate in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root"; do
    if [[ -d "$candidate/steamrt64" ]]; then
        STEAM_ROOT="$(readlink -f "$candidate")"
        break
    fi
done

if [[ -z "$STEAM_ROOT" ]]; then
    err "Cannot find a native 64-bit Steam installation with steamrt64/ under \$HOME."
    err "Ensure native Steam is installed and has completed its initial update."
    exit 1
fi

STEAM_SDL_PRIMARY="$STEAM_ROOT/steamrt64/libSDL3.so.0"
if [[ ! -f "$STEAM_SDL_PRIMARY" ]]; then
    err "Missing $STEAM_SDL_PRIMARY"
    exit 1
fi

if pgrep -f 'steamrt64/steam |ubuntu12_32/steam ' >/dev/null 2>&1; then
    err "Steam is currently running. Close Steam first (e.g. 'steam -shutdown') and re-run."
    exit 1
fi

ok "Steam root: $STEAM_ROOT"

# ── 2. Select build backend (Sniper SDK container or native) ──────────────────

CONTAINER_BIN=""
if [[ "$BUILD_MODE" != "native" ]]; then
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_BIN="podman"
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_BIN="docker"
    elif [[ "$BUILD_MODE" == "sniper" ]]; then
        err "--sniper requested, but neither podman nor docker was found."
        exit 1
    else
        warn "Neither podman nor docker found; falling back to native host build"
        BUILD_MODE="native"
    fi
fi

if [[ "$BUILD_MODE" == "auto" ]]; then
    BUILD_MODE="sniper"
fi

check_host_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Missing required host tool: $1"
        exit 1
    fi
}

check_host_tool git
check_host_tool patch
check_host_tool python3
check_host_tool readelf
check_host_tool nm
check_host_tool sha256sum

if [[ "$BUILD_MODE" == "native" ]]; then
    check_host_tool gcc
    check_host_tool cmake
    check_host_tool ninja
    check_host_tool strip
    info "Build mode: native host toolchain"
else
    info "Build mode: SteamRT Sniper SDK ($CONTAINER_BIN, $SNIPER_IMAGE)"
fi

# ── 3. Prepare SDL3 source and apply patch ────────────────────────────────────

info "SDL source: $SDL_SRC"

if [[ -d "$SDL_SRC/.git" ]]; then
    info "SDL checkout present at $SDL_SRC"
elif [[ -d "$SDL_SRC" && -n "$(find "$SDL_SRC" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    err "SDL source directory exists but is not a git checkout: $SDL_SRC"
    err "Move or remove it and re-run."
    exit 1
else
    info "Cloning SDL ($SDL_REF) into $SDL_SRC"
    mkdir -p "$(dirname "$SDL_SRC")"
    git clone --quiet --branch "$SDL_REF" --depth 1 "$SDL_REPO_URL" "$SDL_SRC"
    ok "SDL cloned"
fi

PATCH_STAMP="$SDL_SRC/.vader5-patch.sha256"
PREVIOUS_PATCH_SHA="$(cat "$PATCH_STAMP" 2>/dev/null || true)"
PATCH_CHANGED=0

_flydigi_patch_present() {
    grep -q 'HIDAPI_DriverFlydigi_RumbleVader5Xpad' \
        "$1/src/joystick/hidapi/SDL_hidapi_flydigi.c" 2>/dev/null
}

_apply_patch() {
    info "Applying Vader 5 Linux xpad-rumble patch"
    if ! patch -N -p1 -d "$SDL_SRC" < "$PATCH_FILE"; then
        err "Patch failed to apply against $SDL_SRC."
        err "Check $PATCH_FILE against $SDL_SRC/src/joystick/hidapi/SDL_hidapi_flydigi.c"
        exit 1
    fi
    PATCH_CHANGED=1
    ok "Patch applied"
}

if [[ "${VADER5_REFRESH_SDL:-0}" == "1" || "$FORCE_REBUILD" == "1" ]]; then
    info "Resetting Flydigi driver sources from git before applying patch"
    git -C "$SDL_SRC" checkout -- \
        src/joystick/hidapi/SDL_hidapi_flydigi.c \
        src/joystick/hidapi/SDL_hidapijoystick.c 2>/dev/null || true
    _apply_patch
elif _flydigi_patch_present "$SDL_SRC"; then
    if [[ "$PREVIOUS_PATCH_SHA" != "$PATCH_SHA" ]]; then
        info "Patch file changed; resetting Flydigi driver sources and re-applying"
        git -C "$SDL_SRC" checkout -- \
            src/joystick/hidapi/SDL_hidapi_flydigi.c \
            src/joystick/hidapi/SDL_hidapijoystick.c 2>/dev/null || true
        _apply_patch
    else
        ok "Vader 5 Linux xpad-rumble patch already applied"
    fi
else
    _apply_patch
fi

# ── 4. Determine target stock size before building ────────────────────────────

STOCK_BACKUP_PRIMARY="$BACKUP_DIR/steamrt64/libSDL3.so.0"
RECEIPT_PRIMARY="$RECEIPT_DIR/steamrt64/libSDL3.so.0.sha256"

current_primary_sha="$(sha256sum "$STEAM_SDL_PRIMARY" | awk '{print $1}')"
recorded_primary_sha="$(cat "$RECEIPT_PRIMARY" 2>/dev/null || true)"

if [[ -n "$recorded_primary_sha" && "$current_primary_sha" == "$recorded_primary_sha" && -f "$STOCK_BACKUP_PRIMARY" ]]; then
    TARGET_SIZE_64="$(stat -c '%s' "$STOCK_BACKUP_PRIMARY")"
else
    TARGET_SIZE_64="$(stat -c '%s' "$STEAM_SDL_PRIMARY")"
fi

info "Target steamrt64/libSDL3.so.0 size: $TARGET_SIZE_64 bytes"

# ── 5. Build 64-bit SDL3 ──────────────────────────────────────────────────────

SDL_BUILD64="$SDL_SRC/build-${BUILD_MODE}64"
BUILT_LIB64="$SDL_BUILD64/libSDL3-stripped.so.0"

_cmake_flags_array() {
    local build_type="$1"
    # shellcheck disable=SC2016 # Pass literal $ORIGIN to CMake/linker RUNPATH.
    printf '%s\n' \
        -GNinja \
        "-DCMAKE_BUILD_TYPE=$build_type" \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        '-DCMAKE_INSTALL_RPATH=$ORIGIN' \
        -DCMAKE_SKIP_BUILD_RPATH=OFF \
        -DBUILD_SHARED_LIBS=ON \
        -DSDL_SHARED=ON -DSDL_STATIC=OFF \
        -DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF \
        -DSDL_INSTALL_TESTS=OFF -DSDL_INSTALL_DOCS=OFF \
        -DSDL_AUDIO=ON -DSDL_ALSA=ON -DSDL_ALSA_SHARED=ON \
        -DSDL_PULSEAUDIO=ON -DSDL_PULSEAUDIO_SHARED=ON \
        -DSDL_PIPEWIRE=ON -DSDL_PIPEWIRE_SHARED=ON \
        -DSDL_JACK=OFF -DSDL_SNDIO=OFF \
        -DSDL_VIDEO=ON -DSDL_RENDER=ON -DSDL_OPENGL=ON -DSDL_OPENGLES=ON -DSDL_VULKAN=ON \
        -DSDL_X11=ON -DSDL_X11_SHARED=ON \
        -DSDL_WAYLAND=OFF \
        -DSDL_KMSDRM=OFF -DSDL_OFFSCREEN=ON \
        -DSDL_DBUS=ON -DSDL_IBUS=OFF -DSDL_LIBUDEV=ON \
        -DSDL_HIDAPI=ON -DSDL_HIDAPI_JOYSTICK=ON \
        -DSDL_HIDAPI_LIBUSB=ON -DSDL_HIDAPI_LIBUSB_SHARED=ON \
        -DSDL_JOYSTICK=ON -DSDL_VIRTUAL_JOYSTICK=ON \
        -DSDL_HAPTIC=ON -DSDL_SENSOR=ON \
        -DSDL_GPU=ON -DSDL_CAMERA=OFF -DSDL_DIALOG=OFF -DSDL_TRAY=OFF \
        -DSDL_FRIBIDI=OFF -DSDL_LIBTHAI=OFF
}

_run_build64() {
    local build_type="$1"
    local log_file="/tmp/vader5-sdl-build64.log"
    local -a cmake_flags
    mapfile -t cmake_flags < <(_cmake_flags_array "$build_type")

    if [[ "$BUILD_MODE" == "sniper" ]]; then
        if ! "$CONTAINER_BIN" image exists "$SNIPER_IMAGE" >/dev/null 2>&1; then
            info "Pulling $SNIPER_IMAGE (one-time ~1.3 GiB download)"
            "$CONTAINER_BIN" pull "$SNIPER_IMAGE"
        fi

        local mount_opt="/src"
        if [[ "$CONTAINER_BIN" == "podman" ]]; then
            mount_opt="/src:Z"
        fi

        info "Building 64-bit SDL3 ($build_type) in Sniper SDK (log: $log_file)"
        # shellcheck disable=SC2016 # Variables expand inside the container shell.
        "$CONTAINER_BIN" run --rm \
            -v "$SDL_SRC:$mount_opt" \
            -w /src \
            "$SNIPER_IMAGE" \
            bash -ceu '
                build_dir="$1"; shift
                if [[ ! -f "$build_dir/build.ninja" ]]; then
                    cmake -S /src -B "$build_dir" "$@"
                fi
                cmake --build "$build_dir" --target SDL3-shared -j"$(nproc)"
                cp -L "$build_dir/libSDL3.so.0" "$build_dir/libSDL3-stripped.so.0"
                strip --strip-unneeded "$build_dir/libSDL3-stripped.so.0"
            ' _ "/src/build-${BUILD_MODE}64" "${cmake_flags[@]}" \
            >"$log_file" 2>&1 \
            || { err "Sniper SDK build failed — see $log_file"; exit 1; }
    else
        info "Building 64-bit SDL3 ($build_type) natively (log: $log_file)"
        if [[ ! -f "$SDL_BUILD64/build.ninja" ]]; then
            cmake -S "$SDL_SRC" -B "$SDL_BUILD64" "${cmake_flags[@]}" >"$log_file" 2>&1 \
                || { err "Native cmake failed — see $log_file"; exit 1; }
        fi
        cmake --build "$SDL_BUILD64" --target SDL3-shared -j"$(nproc)" >>"$log_file" 2>&1 \
            || { err "Native build failed — see $log_file"; exit 1; }
        cp -L "$SDL_BUILD64/libSDL3.so.0" "$BUILT_LIB64"
        strip --strip-unneeded "$BUILT_LIB64"
    fi
}

if [[ "$FORCE_REBUILD" == "1" ]]; then
    rm -rf "$SDL_BUILD64"
fi

if [[ -f "$BUILT_LIB64" && "$PATCH_CHANGED" != "1" && "$FORCE_REBUILD" != "1" ]]; then
    ok "64-bit SDL3 build already up to date at $BUILT_LIB64"
else
    _run_build64 "Release"
    built_size="$(stat -c '%s' "$BUILT_LIB64")"
    if (( built_size > TARGET_SIZE_64 )); then
        warn "Release build ($built_size bytes) exceeds target size ($TARGET_SIZE_64 bytes); rebuilding with MinSizeRel"
        rm -rf "$SDL_BUILD64"
        _run_build64 "MinSizeRel"
    fi
    ok "64-bit SDL3 built ($(stat -c '%s' "$BUILT_LIB64") bytes stripped)"
fi

# ── 6. Verify ELF metadata, size, and Steam symbol coverage ───────────────────

info "Verifying built SDL3 binary"

elf_class="$(LC_ALL=C readelf -h "$BUILT_LIB64" | awk '/Class:/{print $2}')"
if [[ "$elf_class" != "ELF64" ]]; then
    err "$BUILT_LIB64 is $elf_class, expected ELF64"
    exit 1
fi

# shellcheck disable=SC2016 # Match literal RUNPATH=$ORIGIN.
if ! LC_ALL=C readelf -d "$BUILT_LIB64" | grep -q 'RUNPATH.*\$ORIGIN'; then
    err "$BUILT_LIB64 is missing RUNPATH=\$ORIGIN"
    exit 1
fi

if ! LC_ALL=C readelf -d "$BUILT_LIB64" | grep -q 'SONAME.*\[libSDL3\.so\.0\]'; then
    err "$BUILT_LIB64 is missing SONAME [libSDL3.so.0]"
    exit 1
fi

built_size="$(stat -c '%s' "$BUILT_LIB64")"
if (( built_size > TARGET_SIZE_64 )); then
    err "Built SDL3 ($built_size bytes) exceeds Steam's stock size ($TARGET_SIZE_64 bytes); cannot zero-pad."
    exit 1
fi

tmp_need="$(mktemp)"
tmp_have="$(mktemp)"
trap 'rm -f "$tmp_need" "$tmp_have"' EXIT

for bin in "$STEAM_ROOT/steamrt64"/*; do
    [[ -f "$bin" ]] || continue
    nm -D --undefined-only "$bin" 2>/dev/null | awk '{print $2}' | grep '^SDL_' || true
done | sed 's/@@/@/g' | sort -u > "$tmp_need"

nm -D --defined-only "$BUILT_LIB64" 2>/dev/null | awk '{print $3}' | grep '^SDL_' | sed 's/@@/@/g' | sort -u > "$tmp_have"

missing_syms="$(comm -23 "$tmp_need" "$tmp_have")"
if [[ -n "$missing_syms" ]]; then
    err "Built SDL3 is missing symbols required by steamrt64/*:"
    echo "$missing_syms" >&2
    exit 1
fi

req_count="$(wc -l < "$tmp_need")"
ok "Verified ELF64, SONAME, RUNPATH=\$ORIGIN, size ($built_size <= $TARGET_SIZE_64), and all $req_count required SDL_* symbols"
printf '%s\n' "$PATCH_SHA" > "$PATCH_STAMP"

# ── 7. Back up stock Steam SDL3 and deploy size-padded binary ─────────────────

mkdir -p "$SDL_DEPLOY_DIR" "$BACKUP_DIR/steamrt64" "$RECEIPT_DIR/steamrt64"

install -m 755 "$BUILT_LIB64" "$SDL_DEPLOY_DIR/libSDL3-64.so.0"

_deploy_padded() {
    local rel_path="$1"
    local dst="$STEAM_ROOT/$rel_path"
    local backup="$BACKUP_DIR/$rel_path"
    local receipt="$RECEIPT_DIR/$rel_path.sha256"

    if [[ ! -f "$dst" || -L "$dst" ]]; then
        return 0
    fi

    local cur_sha rec_sha target_size
    cur_sha="$(sha256sum "$dst" | awk '{print $1}')"
    rec_sha="$(cat "$receipt" 2>/dev/null || true)"

    if [[ -n "$rec_sha" && "$cur_sha" == "$rec_sha" && -f "$backup" ]]; then
        target_size="$(stat -c '%s' "$backup")"
        info "Keeping existing stock backup for $rel_path ($target_size bytes)"
    else
        mkdir -p "$(dirname "$backup")"
        cp -p "$dst" "$backup"
        target_size="$(stat -c '%s' "$backup")"
        ok "Backed up stock $rel_path ($target_size bytes)"
    fi

    if (( built_size > target_size )); then
        err "Built SDL3 ($built_size bytes) exceeds $rel_path stock size ($target_size bytes)"
        exit 1
    fi

    local tmp_dst="${dst}.vader5-tmp"
    cp "$BUILT_LIB64" "$tmp_dst"
    python3 - "$tmp_dst" "$target_size" <<'PY'
import os, sys
path, target = sys.argv[1], int(sys.argv[2])
cur = os.path.getsize(path)
if cur > target:
    raise SystemExit(f"size {cur} exceeds target {target}")
pad = target - cur
if pad > 0:
    with open(path, "ab") as f:
        chunk = b"\x00" * 65536
        while pad > 0:
            n = min(pad, len(chunk))
            f.write(chunk[:n])
            pad -= n
PY
    chmod 755 "$tmp_dst"
    mv -f "$tmp_dst" "$dst"

    mkdir -p "$(dirname "$receipt")"
    sha256sum "$dst" | awk '{print $1}' > "$receipt"
    ok "Deployed $rel_path (padded to $target_size bytes, +$((target_size - built_size)) zero bytes)"
}

_deploy_padded "steamrt64/libSDL3.so.0"
_deploy_padded "steamrt64/libSDL3.so"

# ── 8. Clean up legacy wrapper overrides if present ───────────────────────────

USER_DESKTOP="$HOME/.local/share/applications/steam.desktop"
if [[ -f "$USER_DESKTOP" ]] && grep -q 'vader5-driver' "$USER_DESKTOP" 2>/dev/null; then
    if [[ -f "${USER_DESKTOP}.vader5-backup" ]]; then
        mv "${USER_DESKTOP}.vader5-backup" "$USER_DESKTOP"
        ok "Restored previous steam.desktop"
    else
        rm -f "$USER_DESKTOP"
        ok "Removed legacy steam.desktop wrapper override"
    fi
fi

SYSTEMD_OVERRIDE="$HOME/.config/systemd/user/steam-launcher.service.d/override.conf"
if [[ -f "$SYSTEMD_OVERRIDE" ]] && grep -q 'vader5-driver' "$SYSTEMD_OVERRIDE" 2>/dev/null; then
    if [[ -f "${SYSTEMD_OVERRIDE}.vader5-backup" ]]; then
        mv "${SYSTEMD_OVERRIDE}.vader5-backup" "$SYSTEMD_OVERRIDE"
        ok "Restored previous steam-launcher.service override"
    else
        rm -f "$SYSTEMD_OVERRIDE"
        ok "Removed legacy steam-launcher.service wrapper override"
    fi
    systemctl --user daemon-reload 2>/dev/null || true
fi

rm -f "$DEPLOY_DIR/wrapper.sh" \
      "$SDL_DEPLOY_DIR/sdl3_shim64.so" \
      "$SDL_DEPLOY_DIR/sdl3_shim32.so" \
      "$SDL_DEPLOY_DIR/libSDL3-32.so.0"

# ── 9. Udev rule (elevate only if missing or changed) ─────────────────────────

if [[ "$SKIP_UDEV" == "0" ]]; then
    need_udev_reload=0
    OLD_PADCTL_RULE="/etc/udev/rules.d/60-padctl-vader5-userspace.rules"
    if [[ -f "$OLD_PADCTL_RULE" ]]; then
        info "Disabling conflicting padctl udev rule"
        sudo mv "$OLD_PADCTL_RULE" "${OLD_PADCTL_RULE}.disabled"
        need_udev_reload=1
    fi

    if [[ -f "$UDEV_RULE_DST" ]] && cmp -s "$UDEV_RULE_SRC" "$UDEV_RULE_DST"; then
        ok "Udev rule already up to date: $UDEV_RULE_DST"
    else
        info "Installing udev rule: $UDEV_RULE_DST"
        sudo install -m 644 "$UDEV_RULE_SRC" "$UDEV_RULE_DST"
        need_udev_reload=1
    fi

    for legacy_root_file in /etc/systemd/system/vader5-xpad-unbind.service /etc/vader5-driver/xpad-unbind.sh; do
        if [[ -f "$legacy_root_file" ]]; then
            sudo systemctl disable --now vader5-xpad-unbind.service 2>/dev/null || true
            sudo rm -f "$legacy_root_file"
            sudo systemctl daemon-reload 2>/dev/null || true
        fi
    done

    if [[ "$need_udev_reload" == "1" ]]; then
        sudo udevadm control --reload-rules
        sudo udevadm trigger
        ok "Udev rules reloaded"
    fi
fi

# ── 10. Enable Vader 5 Pro third-party mapping flag ───────────────────────────

if [[ "$SKIP_THIRDPARTY" == "0" && -x "$THIRDPARTY_TOOL" ]]; then
    info "Checking Vader 5 Pro third-party mapping firmware flag"
    set +e
    tp_out="$("$THIRDPARTY_TOOL" enable 2>&1)"
    tp_rc=$?
    set -e
    if [[ "$tp_rc" -eq 0 ]]; then
        printf '  %s\n' "${tp_out//$'\n'/$'\n'  }"
        ok "Controller third-party mapping flag is enabled"
    elif [[ "$tp_rc" -eq 2 ]]; then
        warn "Controller not connected or asleep; wake it and run:"
        warn "  $THIRDPARTY_TOOL enable"
    else
        warn "Could not update controller third-party flag:"
        printf '  %s\n' "${tp_out//$'\n'/$'\n'  }" >&2
    fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
ok "Installation complete."
echo ""
echo "  Patched Steam SDL3:  $STEAM_ROOT/steamrt64/libSDL3.so.0"
echo "  Stock backup:        $BACKUP_DIR/steamrt64/libSDL3.so.0"
echo "  Probe SDL3 copy:     $SDL_DEPLOY_DIR/libSDL3-64.so.0"
echo "  Udev rule:           $UDEV_RULE_DST"
echo ""
echo "Launch Steam normally (no wrapper needed). Verify detection with:"
echo "  grep -n 'Flydigi\\|Vader\\|HIDAPI' ~/.local/share/Steam/logs/controller.txt | tail -40"
