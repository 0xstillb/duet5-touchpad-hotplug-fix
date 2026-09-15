# Engineering handoff: DOKING Duet 5 touchpad hot-plug failure

## Scope

เอกสารนี้บันทึกการวิเคราะห์และ implementation สำหรับปัญหา touchpad ของ
Lenovo IdeaPad Duet 5 12IAU7 ไม่กลับมาหลังถอดและเสียบ keyboard cover ขณะ
FydeOS ทำงานอยู่ เป้าหมายคือ recovery แบบ interface-only โดยไม่ reboot และ
ไม่รบกวน keyboard, touchscreen, autorotate, suspend หรือ storage อื่น

## Tested system

```text
Model:       Lenovo IdeaPad Duet 5 12IAU7
CPU:         Intel Core i5-1235U
OS:          FydeOS 23.0-SP1
Board:       amd64-fydeos_iris
Build:       16700.56.23.51
Kernel:      6.12.54-01180-gb4e10020ba49-dirty
Boot mode:   Live USB
USB root:    /dev/sdb3, ext2, normally read-only
Stateful:    /dev/sdb1
Internal:    /dev/nvme0n1, Windows partitions; intentionally untouched
```

## User-visible failure

Cold boot:

- keyboard works
- touchpad works

Hot-plug sequence:

1. Detach keyboard cover.
2. USB device `1-3` disconnects.
3. Reattach keyboard cover.
4. Keyboard returns.
5. Touchpad remains missing.

Representative kernel messages supplied during diagnosis:

```text
usb 1-3: new full-speed USB device
idVendor=17ef, idProduct=613a
Product: Duet 5 USB Composite Device
Manufacturer: DOKING
hid-generic ... USB HID Keyboard
usbhid 1-3:1.1: can't add hid device: -71
usbhid 1-3:1.1: probe with driver usbhid failed with error -71
```

Linux error `-71` is `EPROTO`.

## Phase 1 evidence

Device-level sysfs values:

```text
/sys/bus/usb/devices/1-3/idVendor      17ef
/sys/bus/usb/devices/1-3/idProduct     613a
/sys/bus/usb/devices/1-3/product       Duet 5 USB Composite Device
/sys/bus/usb/devices/1-3/manufacturer  DOKING
/sys/bus/usb/devices/1-3/authorized    1
```

Interface comparison:

| Property | `1-3:1.0` | `1-3:1.1` after failure |
| --- | --- | --- |
| Interface number | `00` | `01` |
| Class | `03` HID | `03` HID |
| Subclass | `01` boot | `01` boot |
| Protocol | `01` keyboard | `02` mouse/pointing device |
| Authorized | `1` | `1` |
| Driver | `usbhid` | none |

Interface `01` also exposed interrupt-IN endpoint `0x82`. `/proc/bus/input/devices`
contained the DOKING keyboard from interface `00` but no DOKING mouse/touchpad.
This establishes that the missing input path was interface `01`; no event number
was assumed.

## Recovery tests

| Test | Result |
| --- | --- |
| Initial failed state | interface `01` existed, authorized, unbound |
| Device-level authorization reset | previously tested; keyboard reappeared, touchpad did not |
| Direct interface `drivers_probe` | successful |
| Delayed manual reprobe series | skipped because direct reprobe succeeded |
| Interface authorization reset | skipped |
| usbcore quirk `g` | skipped |
| usbcore quirk `gn` | skipped |

Confirmed manual operation:

```sh
printf '%s\n' '1-3:1.1' > /sys/bus/usb/drivers_probe
```

After reprobe, interface `01` bound to `/sys/bus/usb/drivers/usbhid` and created
System Control, Consumer Control, Mouse, Touchpad and Wireless Radio Control
input nodes. The DOKING touchpad node had `PROP=5` and returned functionality.

## Root-cause assessment

Most likely cause is a device-readiness timing race during the first HID probe
after USB hot-plug. A HID descriptor or control transfer fails with `EPROTO`
while the DOKING controller is still initializing. Linux leaves interface `01`
present and authorized but unbound. Reprobing the same interface after the
device settles succeeds, without re-enumeration or device reset.

Evidence supports a timing problem but does not identify the exact failed USB
request because protected `dmesg` required credentials unavailable to the
agent. The supplied kernel log and successful late reprobe are consistent with
this assessment.

## Implemented recovery

Installed Live USB files:

```text
/etc/udev/rules.d/99-duet-touchpad-reprobe.rules
/usr/local/sbin/duet-touchpad-reprobe
/usr/local/sbin/uninstall-duet-touchpad-autofix
```

The udev rule matches only USB interface-add events for:

```text
VID:PID                    17ef:613a
bInterfaceNumber           01
bInterfaceClass            03
bInterfaceSubClass         01
bInterfaceProtocol         02
```

The kernel name is supplied as `%k`, so the implementation does not assume
`1-3:1.1`. The helper validates the parent VID/PID and every interface descriptor
again before doing anything. If a driver is already bound it exits immediately.
Otherwise it waits and requests interface-only reprobes at bounded intervals.

Only this sysfs write is performed:

```text
printf interface-name > /sys/bus/usb/drivers_probe
```

There are no writes to device or interface `authorized`, no unbind, no reset,
no module operation and no power-management change.

## End-to-end validation

After installing and reloading the rule, the keyboard cover was physically
detached and reconnected. The keyboard and touchpad both returned. Read-only
verification showed:

```text
Bus 01 Port 3 Interface 0 Driver=usbhid
Bus 01 Port 3 Interface 1 Driver=usbhid
driver=/sys/bus/usb/drivers/usbhid
Name="DOKING Duet 5 USB Composite Device Touchpad"
```

System log evidence:

```text
duet-touchpad-reprobe: recovered 1-3:1.1 with interface-only drivers_probe
```

This confirms that the udev event, delay, helper validation and `drivers_probe`
write all executed successfully during a real hot-plug.

## Live USB persistence

The Live USB installer has hard safety gates for the observed layout:

- current root must be `/dev/sdb3`
- `/dev/sdb` transport must be USB
- OS must report `ID=FydeOS`
- managed target paths must not already exist

It remounts only `/`, installs the files, calls `sync`, restores `/` read-only,
and reloads udev. A trap restores read-only mode and removes files created by a
failed partial install.

## Installed FydeOS SSD variant

`install-installed-fydeos-ssd.sh` is intended to be run only after booting the
FydeOS installation that lives on NVMe. It does not install FydeOS itself and
cannot target an offline partition.

Safety behavior:

- confirms `ID=FydeOS`
- resolves the physical boot root using `rootdev -s` when available
- accepts only `/dev/nvme…p…` physical roots
- confirms NVMe transport
- has no disk/partition argument
- remounts only the already-mounted `/`
- preserves the original root mount mode
- aborts cleanly if rootfs cannot be remounted read-write
- never changes rootfs verification or boot settings

Compatibility qualification: the recovery rule is hardware-validated, while
the SSD installer has been syntax- and safety-reviewed but cannot be executed
end-to-end until FydeOS is actually booted from NVMe. If the installed image
enforces verified read-only rootfs, the installer intentionally fails rather
than weakening verification. OS updates may replace files stored in rootfs;
reinstall/check after major updates.

## Rollback

Run on the currently booted FydeOS system:

```sh
sudo /usr/local/sbin/uninstall-duet-touchpad-autofix
```

The uninstaller validates identifying content before removing the exact managed
rule/helper, restores the original root mount mode and reloads udev. It does not
reboot.

## Safety boundaries maintained

- Internal Windows/NVMe partitions were not mounted, modified, formatted,
  repaired or written during Live USB diagnosis and implementation.
- FydeOS was not installed internally.
- BIOS/UEFI was not changed.
- Kernel files, modules, bootloader and kernel command line were not changed.
- Auto Rotate and all `duet-autorotate` files/services were untouched.
- Chrome/FydeOS UI was not restarted.
- Suspend/deep-sleep and global autosuspend settings were untouched.
- Touchscreen configuration was untouched.
- No reboot was performed.

## Maintainer follow-up

1. Test `install-installed-fydeos-ssd.sh` only after booting an actual installed
   FydeOS NVMe system.
2. Confirm the root can be remounted without changing verification policy.
3. Re-run physical detach/reconnect and capture full privileged `dmesg` around
   the initial failure and automatic recovery.
4. If multiple units reproduce the same timing bug, consider an upstream,
   device-specific kernel USB/HID quirk for `17ef:613a`.
5. Prefer the interface-only udev recovery while it remains sufficient; do not
   broaden to whole-device reset unless new evidence requires it.

## Diagnostic artifact

The live diagnostic session was recorded locally at:

```text
/tmp/duet_touchpad_hotplug_diag.txt
```

The diagnostic log is intentionally not committed because it may contain
machine-specific runtime details and unrelated kernel/input enumeration.
