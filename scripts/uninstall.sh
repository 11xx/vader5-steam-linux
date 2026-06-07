#!/usr/bin/env bash
# uninstall.sh — remove the SDL HIDAPI Vader 5 Pro override
#
# Removes whichever wiring the install script created:
#   - steam-launcher.service.d override.conf  (service mode)
#   - ~/.local/share/applications/steam.desktop  (desktop mode, if ours)
#   - /etc/udev/rules.d/60-vader5-sdl.rules
#   - /etc/vader5-driver/xpad-unbind.sh
#   - /etc/systemd/system/vader5-xpad-unbind.service
#   - ~/.local/share/vader5-driver/sdl/   (patched SDL)
#   - ~/.local/share/vader5-driver/wrapper.sh
#
# Does NOT remove SDL source or build dirs under ~/sdl-build/SDL.

set -euo pipefail

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    echo "[err ] do NOT run this script with sudo." >&2
    exit 1
fi

GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[info]${NC} $*"; }
ok()   { echo -e "${GREEN}[ ok ]${NC} $*"; }

DEPLOY_DIR="$HOME/.local/share/vader5-driver"
OVERRIDE="$HOME/.config/systemd/user/steam-launcher.service.d/override.conf"
OVERRIDE_BACKUP="$OVERRIDE.vader5-backup"
USER_DESKTOP="$HOME/.local/share/applications/steam.desktop"
USER_DESKTOP_BACKUP="$USER_DESKTOP.vader5-backup"
UDEV_RULE="/etc/udev/rules.d/60-vader5-sdl.rules"
UNBIND_HELPER="/etc/vader5-driver/xpad-unbind.sh"
UNBIND_SERVICE="/etc/systemd/system/vader5-xpad-unbind.service"
OLD_PADCTL_RULE="/etc/udev/rules.d/60-padctl-vader5-userspace.rules"
OLD_PADCTL_RULE_DISABLED="${OLD_PADCTL_RULE}.disabled"

# Service mode wiring
if [[ -f "$OVERRIDE" ]]; then
    if grep -q "vader5-driver" "$OVERRIDE" 2>/dev/null; then
        if [[ -f "$OVERRIDE_BACKUP" ]]; then
            mv "$OVERRIDE_BACKUP" "$OVERRIDE"
            ok "Restored previous systemd override"
        else
            rm -f "$OVERRIDE"
            ok "Removed systemd override"
        fi
    fi
    systemctl --user daemon-reload

    if systemctl --user is-active steam-launcher.service &>/dev/null; then
        info "Restarting Steam without override"
        systemctl --user restart steam-launcher.service
    fi
elif [[ -f "$OVERRIDE_BACKUP" ]]; then
    mv "$OVERRIDE_BACKUP" "$OVERRIDE"
    systemctl --user daemon-reload
    ok "Restored previous systemd override"
fi

# Desktop mode wiring — only remove if it was created by us (contains our wrapper path)
if [[ -f "$USER_DESKTOP" ]] \
        && grep -q "vader5-driver" "$USER_DESKTOP" 2>/dev/null; then
    if [[ -f "$USER_DESKTOP_BACKUP" ]]; then
        mv "$USER_DESKTOP_BACKUP" "$USER_DESKTOP"
        ok "Restored previous .desktop override"
    else
        rm -f "$USER_DESKTOP"
        ok "Removed .desktop override"
    fi
fi

# Udev rule
if [[ -f "$UDEV_RULE" ]]; then
    sudo rm -f "$UDEV_RULE"
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    ok "Removed udev rule"
fi

# Restore old padctl rule if this installer disabled it.
if [[ -f "$OLD_PADCTL_RULE_DISABLED" && ! -f "$OLD_PADCTL_RULE" ]]; then
    sudo mv "$OLD_PADCTL_RULE_DISABLED" "$OLD_PADCTL_RULE" \
        && ok "Restored old padctl udev rule"
    sudo udevadm control --reload-rules
fi

# xpad boot/preflight helper
if command -v systemctl &>/dev/null; then
    sudo systemctl disable --now vader5-xpad-unbind.service 2>/dev/null || true
    if [[ -f "$UNBIND_SERVICE" ]]; then
        sudo rm -f "$UNBIND_SERVICE"
        sudo systemctl daemon-reload
        ok "Removed xpad unbind service"
    fi
fi

if [[ -f "$UNBIND_HELPER" ]]; then
    sudo rm -f "$UNBIND_HELPER"
    sudo rmdir /etc/vader5-driver 2>/dev/null || true
    ok "Removed xpad unbind helper"
fi

# Deployed artifacts
rm -rf "$DEPLOY_DIR/sdl"
rm -f "$DEPLOY_DIR/wrapper.sh"
# Remove artifacts from older installs if present
rm -f "$DEPLOY_DIR/steam-sdl-wrapper.sh" "$DEPLOY_DIR/sdl_intercept32.so" "$DEPLOY_DIR/sdl_intercept64.so"
rmdir "$DEPLOY_DIR" 2>/dev/null || true
ok "Removed deployed SDL and wrapper"

ok "Uninstall complete. Replug the controller to restore default xpad binding."
