#!/bin/sh
# Unbind xpad from the Vader 5 Pro XInput-facing interface.
#
# This is intentionally narrow: it only touches Flydigi 37d7:2401 interface 0
# entries currently bound to xpad. SDL/Steam uses the separate vendor HID
# interface, and leaving xpad bound creates a duplicate generic Xbox pad.

set -eu

XPAD_DRIVER="${VADER5_XPAD_DRIVER:-/sys/bus/usb/drivers/xpad}"
USB_DEVICES="${VADER5_USB_DEVICES:-/sys/bus/usb/devices}"
VID="37d7"
PID="2401"

read_attr()
{
    if [ -r "$1" ]; then
        cat "$1" 2>/dev/null || true
    fi
}

is_vader_interface0()
{
    iface_name="$1"
    usb_name="${iface_name%%:*}"
    iface_dir="$USB_DEVICES/$iface_name"
    usb_dir="$USB_DEVICES/$usb_name"

    [ -d "$iface_dir" ] || return 1
    [ "$(read_attr "$iface_dir/bInterfaceNumber")" = "00" ] || return 1
    [ "$(read_attr "$usb_dir/idVendor")" = "$VID" ] || return 1
    [ "$(read_attr "$usb_dir/idProduct")" = "$PID" ] || return 1

    return 0
}

unbind_one()
{
    iface_name="$1"

    is_vader_interface0 "$iface_name" || return 0
    [ -e "$XPAD_DRIVER/$iface_name" ] || return 0
    [ -w "$XPAD_DRIVER/unbind" ] || return 0

    printf '%s' "$iface_name" > "$XPAD_DRIVER/unbind" 2>/dev/null || true
}

if [ ! -d "$XPAD_DRIVER" ]; then
    exit 0
fi

if [ "$#" -gt 0 ]; then
    for iface_name in "$@"; do
        unbind_one "$iface_name"
    done
    exit 0
fi

for iface_path in "$XPAD_DRIVER"/*; do
    [ -e "$iface_path" ] || continue
    iface_name="${iface_path##*/}"

    case "$iface_name" in
        *:1.0) unbind_one "$iface_name" ;;
    esac
done
