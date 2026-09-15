#!/bin/sh
set -eu

bundle=${1:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
rule_src=$bundle/udev/99-duet-touchpad-reprobe.rules
helper_src=$bundle/bin/duet-touchpad-reprobe
uninstaller_src=$bundle/uninstall-current-system.sh
rule_dst=/etc/udev/rules.d/99-duet-touchpad-reprobe.rules
helper_dst=/usr/local/sbin/duet-touchpad-reprobe
uninstaller_dst=/usr/local/sbin/uninstall-duet-touchpad-autofix
root_was_ro=0
root_is_rw=0
rule_created=0
helper_created=0
uninstaller_created=0

restore_root_mode() {
  if [ "$root_was_ro" -eq 1 ] && [ "$root_is_rw" -eq 1 ]; then
    /bin/mount -o remount,ro /
    root_is_rw=0
  fi
}

cleanup() {
  rc=$?
  trap - EXIT HUP INT TERM
  if [ "$rc" -ne 0 ]; then
    if [ "$rule_created" -eq 1 ] && [ "$root_was_ro" -eq 1 ] && [ "$root_is_rw" -eq 0 ]; then
      /bin/mount -o remount,rw / 2>/dev/null && root_is_rw=1 || true
    fi
    [ "$rule_created" -eq 0 ] || /bin/rm -f "$rule_dst"
    [ "$helper_created" -eq 0 ] || /bin/rm -f "$helper_dst"
    [ "$uninstaller_created" -eq 0 ] || /bin/rm -f "$uninstaller_dst"
    /bin/sync
  fi
  restore_root_mode
  exit "$rc"
}
trap cleanup EXIT HUP INT TERM

[ "$(id -u)" -eq 0 ] || { echo 'ERROR: run as root.' >&2; exit 1; }
[ -f /etc/os-release ] && /bin/grep -qx 'ID=FydeOS' /etc/os-release || {
  echo 'REFUSING: current operating system is not FydeOS.' >&2
  exit 1
}

if [ -x /usr/bin/rootdev ]; then
  root_device=$(/usr/bin/rootdev -s)
else
  root_device=$(/bin/findmnt -n -o SOURCE /)
fi
case "$root_device" in
  /dev/nvme[0-9]*n[0-9]*p[0-9]*) ;;
  *)
    echo "REFUSING: physical root is $root_device, not an installed NVMe FydeOS root." >&2
    echo 'Boot the installed FydeOS system from SSD before using this installer.' >&2
    exit 1
    ;;
esac
root_disk=${root_device%p*}
[ "$(/bin/lsblk -dnro TRAN "$root_disk")" = nvme ] || {
  echo "REFUSING: $root_disk is not reported as NVMe." >&2
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

root_options=$(/bin/findmnt -n -o OPTIONS /)
case ",$root_options," in
  *,ro,*)
    root_was_ro=1
    /bin/mount -o remount,rw / || {
      echo 'ERROR: current FydeOS root cannot be remounted read-write.' >&2
      echo 'Rootfs verification was not changed; no files were installed.' >&2
      exit 1
    }
    root_is_rw=1
    ;;
esac

/usr/bin/install -o root -g root -m 0755 "$helper_src" "$helper_dst"
helper_created=1
/usr/bin/install -o root -g root -m 0755 "$uninstaller_src" "$uninstaller_dst"
uninstaller_created=1
/usr/bin/install -o root -g root -m 0644 "$rule_src" "$rule_dst"
rule_created=1
/bin/sync
restore_root_mode

/bin/udevadm control --reload
/bin/udevadm control --ping
trap - EXIT HUP INT TERM

echo "Installed helper: $helper_dst"
echo "Installed rule:   $rule_dst"
echo "Rollback:         sudo $uninstaller_dst"
echo 'No partition was mounted, formatted, or selected by this installer.'
