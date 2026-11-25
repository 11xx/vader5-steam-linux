#!/usr/bin/env bash
# Restore Steam's stock SDL3 libraries and remove Vader 5 Pro driver artifacts.
#
# Does not remove the SDL source/build tree under ~/sdl-build/SDL-main-vader5
# and does not change the controller's onboard third-party firmware flag (use
# tools/vader5-thirdparty.py disable to revert that flag).

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

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${BLUE}[info]${NC} $*"; }
ok()   { echo -e "${GREEN}[ ok ]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[err ]${NC} $*" >&2; }

if pgrep -f '(^|/)steamrt64/steam($| )|(^|/)ubuntu12_32/steam($| )' >/dev/null 2>&1; then
    err "Steam is currently running. Close Steam first (e.g. 'steam -shutdown') and re-run."
    exit 1
fi

DEPLOY_DIR="$HOME/.local/share/vader5-driver"
BACKUP_DIR="$DEPLOY_DIR/backups"
RECEIPT_DIR="$DEPLOY_DIR/deployed"
UDEV_RULE="/etc/udev/rules.d/60-vader5-sdl.rules"

STEAM_ROOT=""
for candidate in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root"; do
    if [[ -d "$candidate/steamrt64" ]]; then
        STEAM_ROOT="$(readlink -f "$candidate")"
        break
    fi
done

_restore_file() {
    local rel_path="$1"
    local backup="$BACKUP_DIR/$rel_path"
    local receipt="$RECEIPT_DIR/$rel_path.sha256"

    if [[ ! -e "$backup" && ! -L "$backup" && ! -e "$receipt" && ! -L "$receipt" ]]; then
        return 0
    fi
    if [[ -z "$STEAM_ROOT" ]]; then
        err "Steam directory not found; cannot restore $rel_path (recovery state retained)"
        return 1
    fi
    if [[ ! -f "$backup" ]]; then
        err "Missing stock backup for $rel_path (recovery state retained)"
        return 1
    fi

    local dst="$STEAM_ROOT/$rel_path"
    if [[ "$FORCE" != "1" && -L "$dst" ]]; then
        info "$rel_path is now a symlink; keeping Steam's current path"
        return 0
    fi
    if [[ -e "$dst" && ! -f "$dst" && ! -L "$dst" ]]; then
        err "Not a regular library: $dst (recovery state retained)"
        return 1
    fi
    if [[ -f "$dst" && "$FORCE" != "1" ]]; then
        local cur_sha rec_sha=""
        cur_sha="$(sha256sum "$dst" | awk '{print $1}')"
        if [[ -e "$receipt" || -L "$receipt" ]]; then
            rec_sha="$(cat "$receipt")"
        fi
        if [[ -z "$rec_sha" ]]; then
            if cmp -s "$dst" "$backup"; then
                info "$rel_path is already stock"
                return 0
            fi
            err "Missing receipt for $rel_path; use --force to restore explicitly (recovery state retained)"
            return 1
        fi
        if grep -qEv '^[0-9a-f]{64}$' <<< "$rec_sha"; then
            err "Invalid receipt for $rel_path; use --force to restore explicitly (recovery state retained)"
            return 1
        fi
        if ! grep -Fxq "$cur_sha" <<< "$rec_sha"; then
            info "$rel_path was already updated by Steam; keeping current file"
            return 0
        fi
    fi

    local tmp_dst
    tmp_dst="$(mktemp "${dst}.vader5-restore.XXXXXX")"
    if ! cp -p "$backup" "$tmp_dst" || ! mv -fT "$tmp_dst" "$dst"; then
        rm -f -- "$tmp_dst"
        err "Could not restore $rel_path (recovery state retained)"
        return 1
    fi
    ok "Restored stock $rel_path"
}

_restore_file "steamrt64/libSDL3.so.0"
_restore_file "steamrt64/libSDL3.so"

if [[ "$KEEP_UDEV" == "0" && -f "$UDEV_RULE" ]]; then
    sudo rm -f "$UDEV_RULE"
    sudo udevadm control --reload-rules
    sudo udevadm trigger --subsystem-match=hidraw
    sudo udevadm settle
    ok "Removed udev rule"
fi

rm -rf "$DEPLOY_DIR/sdl" "$BACKUP_DIR" "$RECEIPT_DIR"
rmdir "$DEPLOY_DIR" 2>/dev/null || true
ok "Removed $DEPLOY_DIR"

ok "Uninstall complete."
