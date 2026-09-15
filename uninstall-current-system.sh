#!/bin/sh
set -eu

rule=/etc/udev/rules.d/99-duet-touchpad-reprobe.rules
helper=/usr/local/sbin/duet-touchpad-reprobe
uninstaller=/usr/local/sbin/uninstall-duet-touchpad-autofix
root_changed=0

restore_mount() {
  rc=$?
  trap - EXIT HUP INT TERM
  [ "$root_changed" -eq 0 ] || /bin/mount -o remount,ro /
  exit "$rc"
}
trap restore_mount EXIT HUP INT TERM

[ "$(id -u)" -eq 0 ] || { echo 'ERROR: run as root.' >&2; exit 1; }
[ -f /etc/os-release ] && /bin/grep -qx 'ID=FydeOS' /etc/os-release || {
  echo 'REFUSING: current operating system is not FydeOS.' >&2
  exit 1
}

root_source=$(/bin/findmnt -n -o SOURCE /)
case "$root_source" in
  /dev/sdb3)
    [ "$(/bin/lsblk -dnro TRAN /dev/sdb)" = usb ] || exit 1
    ;;
  /dev/nvme[0-9]*n[0-9]*p[0-9]*)
    root_disk=${root_source%p*}
    [ "$(/bin/lsblk -dnro TRAN "$root_disk")" = nvme ] || exit 1
    ;;
  *)
    echo "REFUSING: unsupported current root: $root_source" >&2
    exit 1
    ;;
esac

[ ! -e "$rule" ] || /bin/grep -q 'DOKING Lenovo Duet 5 keyboard-cover touchpad' "$rule" || exit 1
[ ! -e "$helper" ] || /bin/grep -q 'Reprobe only the unbound DOKING Duet 5' "$helper" || exit 1

root_options=$(/bin/findmnt -n -o OPTIONS /)
case ",$root_options," in
  *,ro,*) /bin/mount -o remount,rw /; root_changed=1 ;;
esac

/bin/rm -f "$rule" "$helper"
/bin/sync
if [ "$root_changed" -eq 1 ]; then
  /bin/mount -o remount,ro /
  root_changed=0
fi
/bin/udevadm control --reload
/bin/udevadm control --ping
/bin/rm -f "$uninstaller"
trap - EXIT HUP INT TERM
echo 'Removed the Duet touchpad autofix; original root mount mode restored.'
