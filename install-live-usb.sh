#!/bin/sh
set -eu

bundle=${1:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
rule_src=$bundle/udev/99-duet-touchpad-reprobe.rules
helper_src=$bundle/bin/duet-touchpad-reprobe
uninstaller_src=$bundle/uninstall-current-system.sh
rule_dst=/etc/udev/rules.d/99-duet-touchpad-reprobe.rules
helper_dst=/usr/local/sbin/duet-touchpad-reprobe
uninstaller_dst=/usr/local/sbin/uninstall-duet-touchpad-autofix
root_rw=0
rule_created=0
helper_created=0
uninstaller_created=0

cleanup() {
  rc=$?
  trap - EXIT HUP INT TERM
  if [ "$rc" -ne 0 ]; then
    if [ "$root_rw" -eq 0 ]; then
      /bin/mount -o remount,rw / 2>/dev/null && root_rw=1 || true
    fi
    [ "$rule_created" -eq 0 ] || /bin/rm -f "$rule_dst"
    [ "$helper_created" -eq 0 ] || /bin/rm -f "$helper_dst"
    [ "$uninstaller_created" -eq 0 ] || /bin/rm -f "$uninstaller_dst"
    /bin/sync
  fi
  [ "$root_rw" -eq 0 ] || /bin/mount -o remount,ro /
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

[ "$(id -u)" -eq 0 ] || { echo 'ERROR: run as root.' >&2; exit 1; }
[ "$(/bin/findmnt -n -o SOURCE /)" = /dev/sdb3 ] || {
  echo 'REFUSING: current root is not the expected Live USB /dev/sdb3.' >&2
  exit 1
}
[ "$(/bin/lsblk -dnro TRAN /dev/sdb)" = usb ] || {
  echo 'REFUSING: /dev/sdb is not reported as USB.' >&2
  exit 1
}
[ -f /etc/os-release ] && /bin/grep -qx 'ID=FydeOS' /etc/os-release || {
  echo 'REFUSING: current operating system is not FydeOS.' >&2
  exit 1
}
[ -f "$rule_src" ] && [ -f "$helper_src" ] && [ -f "$uninstaller_src" ] || {
  echo "ERROR: incomplete source bundle: $bundle" >&2
  exit 1
}
[ ! -e "$rule_dst" ] && [ ! -e "$helper_dst" ] && [ ! -e "$uninstaller_dst" ] || {
  echo 'REFUSING: a target file already exists; nothing was overwritten.' >&2
  exit 1
}

/bin/mount -o remount,rw /
root_rw=1
/usr/bin/install -o root -g root -m 0755 "$helper_src" "$helper_dst"
helper_created=1
/usr/bin/install -o root -g root -m 0755 "$uninstaller_src" "$uninstaller_dst"
uninstaller_created=1
/usr/bin/install -o root -g root -m 0644 "$rule_src" "$rule_dst"
rule_created=1
/bin/sync
/bin/mount -o remount,ro /
root_rw=0

/bin/udevadm control --reload
/bin/udevadm control --ping
trap - EXIT HUP INT TERM

echo "Installed helper: $helper_dst"
echo "Installed rule:   $rule_dst"
echo "Rollback:         sudo $uninstaller_dst"
echo 'Root filesystem restored read-only; udev rules reloaded.'
