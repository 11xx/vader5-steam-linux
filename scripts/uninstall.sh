#!/usr/bin/env bash
# Restore Steam's stock SDL3 libraries and remove Vader 5 Pro driver artifacts.
#
# Does not remove the SDL source/build tree under ~/sdl-build/SDL-main-vader5
# and does not change the controller's onboard third-party firmware flag (use
# tools/vader5-thirdparty.py disable if you want to revert that flag).

set -euo pipefail

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    echo "[err ] do NOT run this script with sudo." >&2
    exit 1
fi

FORCE=0
KEEP_UDEV=0

usage() {
    cat <<'EOF'
Usage: scripts/uninstall.sh [options]

Options:
  --force      Restore backed-up SDL3 even if Steam's current file differs
               from the recorded patched SHA-256
  --keep-udev  Leave /etc/udev/rules.d/60-vader5-sdl.rules installed
  -h, --help   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)     FORCE=1 ;;
        --keep-udev) KEEP_UDEV=1 ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "[err ] Unknown option: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[info]${NC} $*"; }
ok()   { echo -e "${GREEN}[ ok ]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[err ]${NC} $*" >&2; }

if pgrep -f 'steamrt64/steam |ubuntu12_32/steam ' >/dev/null 2>&1; then
    err "Steam is currently running. Close Steam first (e.g. 'steam -shutdown') and re-run."
    exit 1
fi

DEPLOY_DIR="$HOME/.local/share/vader5-driver"
BACKUP_DIR="$DEPLOY_DIR/backups"
RECEIPT_DIR="$DEPLOY_DIR/deployed"
OVERRIDE="$HOME/.config/systemd/user/steam-launcher.service.d/override.conf"
OVERRIDE_BACKUP="$OVERRIDE.vader5-backup"
USER_DESKTOP="$HOME/.local/share/applications/steam.desktop"
USER_DESKTOP_BACKUP="$USER_DESKTOP.vader5-backup"
UDEV_RULE="/etc/udev/rules.d/60-vader5-sdl.rules"
UNBIND_HELPER="/etc/vader5-driver/xpad-unbind.sh"
UNBIND_SERVICE="/etc/systemd/system/vader5-xpad-unbind.service"
OLD_PADCTL_RULE="/etc/udev/rules.d/60-padctl-vader5-userspace.rules"
OLD_PADCTL_RULE_DISABLED="${OLD_PADCTL_RULE}.disabled"

STEAM_ROOT=""
for candidate in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root"; do
    if [[ -d "$candidate/steamrt64" ]]; then
        STEAM_ROOT="$(readlink -f "$candidate")"
        break
    fi
done

# ── 1. Restore backed-up stock Steam SDL3 files ───────────────────────────────

_restore_file() {
    local rel_path="$1"
    local backup="$BACKUP_DIR/$rel_path"
    local receipt="$RECEIPT_DIR/$rel_path.sha256"

    [[ -f "$backup" ]] || return 0
    if [[ -z "$STEAM_ROOT" ]]; then
        warn "Steam directory not found; cannot restore $rel_path"
        return 0
    fi

    local dst="$STEAM_ROOT/$rel_path"
    if [[ -f "$dst" && "$FORCE" != "1" && -f "$receipt" ]]; then
        local cur_sha rec_sha
        cur_sha="$(sha256sum "$dst" | awk '{print $1}')"
        rec_sha="$(cat "$receipt")"
        if [[ "$cur_sha" != "$rec_sha" ]]; then
            info "$rel_path was already updated by Steam; keeping current file"
            return 0
        fi
    fi

    cp -p "$backup" "${dst}.vader5-restore"
    mv -f "${dst}.vader5-restore" "$dst"
    ok "Restored stock $rel_path"
}

_restore_file "steamrt64/libSDL3.so.0"
_restore_file "steamrt64/libSDL3.so"

# ── 2. Clean up any legacy launcher overrides ─────────────────────────────────

if [[ -f "$OVERRIDE" ]] && grep -q "vader5-driver" "$OVERRIDE" 2>/dev/null; then
    if [[ -f "$OVERRIDE_BACKUP" ]]; then
        mv "$OVERRIDE_BACKUP" "$OVERRIDE"
        ok "Restored previous systemd override"
    else
        rm -f "$OVERRIDE"
        ok "Removed systemd override"
    fi
    systemctl --user daemon-reload 2>/dev/null || true
elif [[ -f "$OVERRIDE_BACKUP" ]]; then
    mv "$OVERRIDE_BACKUP" "$OVERRIDE"
    systemctl --user daemon-reload 2>/dev/null || true
    ok "Restored previous systemd override"
fi

if [[ -f "$USER_DESKTOP" ]] && grep -q "vader5-driver" "$USER_DESKTOP" 2>/dev/null; then
    if [[ -f "$USER_DESKTOP_BACKUP" ]]; then
        mv "$USER_DESKTOP_BACKUP" "$USER_DESKTOP"
        ok "Restored previous .desktop override"
    else
        rm -f "$USER_DESKTOP"
        ok "Removed .desktop override"
    fi
fi

# ── 3. Udev rule and legacy root helpers ──────────────────────────────────────

if [[ "$KEEP_UDEV" == "0" && -f "$UDEV_RULE" ]]; then
    sudo rm -f "$UDEV_RULE"
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    ok "Removed udev rule"
fi

if [[ "$KEEP_UDEV" == "0" && -f "$OLD_PADCTL_RULE_DISABLED" && ! -f "$OLD_PADCTL_RULE" ]]; then
    sudo mv "$OLD_PADCTL_RULE_DISABLED" "$OLD_PADCTL_RULE" \
        && ok "Restored previous padctl udev rule"
    sudo udevadm control --reload-rules
fi

if command -v systemctl >/dev/null 2>&1 && [[ -f "$UNBIND_SERVICE" ]]; then
    sudo systemctl disable --now vader5-xpad-unbind.service 2>/dev/null || true
    sudo rm -f "$UNBIND_SERVICE"
    sudo systemctl daemon-reload
    ok "Removed xpad unbind service"
fi

if [[ -f "$UNBIND_HELPER" ]]; then
    sudo rm -f "$UNBIND_HELPER"
    sudo rmdir /etc/vader5-driver 2>/dev/null || true
    ok "Removed xpad unbind helper"
fi

# ── 4. Remove deployed state ──────────────────────────────────────────────────

rm -rf "$DEPLOY_DIR/sdl" "$BACKUP_DIR" "$RECEIPT_DIR"
rm -f "$DEPLOY_DIR/wrapper.sh" "$DEPLOY_DIR/steam-sdl-wrapper.sh" \
      "$DEPLOY_DIR/sdl_intercept32.so" "$DEPLOY_DIR/sdl_intercept64.so"
rmdir "$DEPLOY_DIR" 2>/dev/null || true
ok "Removed $DEPLOY_DIR"

ok "Uninstall complete."
