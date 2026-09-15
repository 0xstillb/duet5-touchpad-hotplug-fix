# Lenovo IdeaPad Duet 5 touchpad hot-plug recovery

การแก้ปัญหา touchpad ของ keyboard cover ไม่กลับมาหลังถอดและเสียบใหม่บน
Lenovo IdeaPad Duet 5 12IAU7 ที่ใช้ FydeOS

## ปัญหา

หลัง cold boot ทั้ง keyboard และ touchpad ทำงานปกติ แต่เมื่อถอด keyboard
cover แล้วเสียบกลับ:

1. USB composite device กลับมา
2. keyboard กลับมาทำงาน
3. touchpad ไม่ปรากฏใน input subsystem
4. kernel รายงานว่า probe ของ HID interface ที่สองล้มเหลวด้วย `-71`
   (`EPROTO`)

อุปกรณ์ที่ตรวจพบ:

```text
VID:PID       17ef:613a
Manufacturer  DOKING
Product       Duet 5 USB Composite Device
USB device    1-3 (ตำแหน่งนี้อาจเปลี่ยนในเครื่องอื่น)
Interface 00  HID 03/01/01, keyboard, bound to usbhid
Interface 01  HID 03/01/02, pointing device, initially unbound after failure
```

ตัวอย่าง kernel log:

```text
usbhid 1-3:1.1: can't add hid device: -71
usbhid 1-3:1.1: probe with driver usbhid failed with error -71
```

## สาเหตุที่เป็นไปได้มากที่สุด

อุปกรณ์ DOKING ยังไม่พร้อมสำหรับ HID/USB control transfer ตอน kernel probe
interface `01` ทันทีหลัง hot-plug จึงเกิด timing race และ `EPROTO` เมื่อเวลา
ผ่านไปแล้ว การสั่งให้ driver core probe เฉพาะ interface เดิมอีกครั้งสำเร็จ
โดยไม่ต้อง reset USB device ทั้งตัว

คำสั่งที่ยืนยันว่าแก้ได้:

```sh
sudo sh -c 'printf "%s\\n" "1-3:1.1" > /sys/bus/usb/drivers_probe'
```

อย่านำชื่อ `1-3:1.1` ไปใช้กับเครื่องอื่นโดยไม่ตรวจ sysfs ก่อน ตำแหน่ง USB
อาจเปลี่ยนได้ กฎ udev ใน repo ไม่ hard-code ตำแหน่งนี้ แต่ใช้ `%k` จาก event

## วิธีแก้อัตโนมัติ

กฎ udev ทำงานเฉพาะเมื่อมี USB interface ที่ตรงเงื่อนไขทั้งหมด:

- `ACTION=add`
- VID:PID `17ef:613a`
- interface number `01`
- HID class/subclass/protocol `03/01/02`
- interface ยังไม่มี driver
- interface ยัง authorized อยู่

helper รอ `0.5`, `1` และ `2` วินาที แล้วเขียนเฉพาะชื่อ interface ไปที่
`/sys/bus/usb/drivers_probe` โดยหยุดทันทีเมื่อ bind สำเร็จ

สิ่งที่ helper **ไม่ทำ**:

- ไม่ unbind keyboard หรือ USB device
- ไม่ reset composite device หรือ xHCI
- ไม่ toggle device/interface authorization
- ไม่แก้ autosuspend, powerd หรือ suspend settings
- ไม่แตะ touchscreen
- ไม่ reload kernel modules
- ไม่แก้ kernel, bootloader หรือ command line
- ไม่ reboot หรือ restart Chrome/FydeOS UI

## ไฟล์ใน repo

```text
bin/duet-touchpad-reprobe
udev/99-duet-touchpad-reprobe.rules
install-live-usb.sh
install-installed-fydeos-ssd.sh
uninstall-current-system.sh
README.md
Handoff.md
```

## ติดตั้งบน Live USB ที่ทดสอบแล้ว

environment ที่ยืนยันแล้วใช้ root `/dev/sdb3` และ stateful partition
`/dev/sdb1` กรณี user storage เป็น `noexec` ให้คัดลอก repo ไป
`/usr/local/src` ก่อน:

```sh
sudo mkdir -p /usr/local/src/duet5-touchpad-hotplug-fix
sudo cp -a . /usr/local/src/duet5-touchpad-hotplug-fix/
sudo /usr/local/src/duet5-touchpad-hotplug-fix/install-live-usb.sh
```

installer จะยอมทำงานเมื่อ:

- `/etc/os-release` ระบุ `ID=FydeOS`
- `/` คือ `/dev/sdb3`
- `/dev/sdb` รายงาน transport เป็น USB
- target files ยังไม่มี เพื่อไม่ overwrite ไฟล์เดิมเงียบ ๆ

มันจะ remount เฉพาะ root ของ Live USB เป็น read-write ชั่วคราว ติดตั้งไฟล์
แล้ว remount กลับ read-only ก่อน reload udev

## ติดตั้งบน FydeOS ที่ติดตั้งบน SSD/NVMe

installer นี้ไม่ได้ติดตั้ง FydeOS และไม่เขียนลง SSD แบบ offline ต้อง boot เข้า
FydeOS ที่ติดตั้งอยู่บน SSD/NVMe ก่อน แล้วจึงรัน:

```sh
sudo mkdir -p /usr/local/src/duet5-touchpad-hotplug-fix
sudo cp -a . /usr/local/src/duet5-touchpad-hotplug-fix/
sudo /usr/local/src/duet5-touchpad-hotplug-fix/install-installed-fydeos-ssd.sh
```

SSD installer:

- ใช้ `rootdev -s` เพื่อ resolve physical root เมื่อเครื่องมือมีอยู่
- ยอมรับเฉพาะ FydeOS root ที่กำลัง boot จาก `/dev/nvme…p…`
- ตรวจ parent device ว่า transport เป็น `nvme`
- ไม่มี argument สำหรับเลือก target disk หรือ partition
- ไม่ mount, format, repair หรือ repartition disk ใด ๆ
- ถ้า rootfs remount เป็น read-write ไม่ได้ จะหยุดโดยไม่ปิด rootfs
  verification และไม่เปลี่ยน boot parameters
- คืน mount mode เดิมหลังติดตั้งหรือเมื่อเกิดข้อผิดพลาด

ดังนั้น SSD version ใช้ได้โดยตรงเมื่อ boot จาก FydeOS บน NVMe และ rootfs
อนุญาตให้ remount ชั่วคราว หาก rootfs verification ป้องกันการเขียน installer
จะ fail-safe; repo นี้ไม่พยายามปิด verification ให้อัตโนมัติ

## ตรวจสอบหลังติดตั้ง

ถอดและเสียบ keyboard cover กลับหนึ่งครั้ง แล้วตรวจ:

```sh
lsusb -t
readlink -f /sys/bus/usb/devices/1-3:1.1/driver
grep -A12 -B2 'DOKING.*Touchpad' /proc/bus/input/devices
```

ผลที่คาดหวัง:

```text
Interface 0 Driver=usbhid
Interface 1 Driver=usbhid
driver=/sys/bus/usb/drivers/usbhid
Name="DOKING Duet 5 USB Composite Device Touchpad"
```

ตรวจ recovery log เมื่อระบบอนุญาต:

```sh
grep duet-touchpad-reprobe /var/log/messages
```

ข้อความสำเร็จ:

```text
recovered 1-3:1.1 with interface-only drivers_probe
```

## Rollback

```sh
sudo /usr/local/sbin/uninstall-duet-touchpad-autofix
```

uninstaller ตรวจว่าไฟล์เป็นไฟล์ที่จัดการโดย project นี้ก่อนลบ ลบเฉพาะ rule
และ helper ที่ระบุ คืน root mount mode เดิม และ reload udev โดยไม่ reboot

## Troubleshooting

### Keyboard กลับมาแต่ touchpad ยังไม่กลับ

ตรวจว่า interface `01` มีอยู่และ driver ยังว่าง:

```sh
lsusb -t
ls -l /sys/bus/usb/devices/1-3:1.1/driver
cat /sys/bus/usb/devices/1-3:1.1/bInterfaceProtocol
```

หาก interface path เปลี่ยน ให้หา interface ที่มี VID:PID `17ef:613a`,
`bInterfaceNumber=01` และ `bInterfaceProtocol=02` ห้ามเดา event number

### ไม่พบ recovery log

ตรวจ rule/helper และ reload rules ด้วย root:

```sh
sudo udevadm control --reload
ls -l /etc/udev/rules.d/99-duet-touchpad-reprobe.rules
ls -l /usr/local/sbin/duet-touchpad-reprobe
```

### SSD installer ปฏิเสธการติดตั้ง

อ่านข้อความ `REFUSING` หรือ `ERROR` ก่อน สาเหตุที่ตั้งใจให้หยุด ได้แก่กำลัง
boot จาก Live USB, physical root ไม่ใช่ NVMe, OS ไม่ใช่ FydeOS, target file
มีอยู่แล้ว หรือ rootfs ไม่อนุญาตให้ remount read-write ห้ามแก้ safety check
เพื่อบังคับเขียนลง partition ที่ยังไม่ได้ยืนยัน

### หลัง FydeOS update rule หาย

ไฟล์ใน rootfs อาจถูกแทนที่เมื่ออัปเดตระบบ ตรวจไฟล์สองตำแหน่งและติดตั้งใหม่
จาก release/source ที่ตรวจสอบแล้วหากจำเป็น

## Environment ที่ยืนยันแล้ว

- Lenovo IdeaPad Duet 5 12IAU7
- Intel Core i5-1235U
- FydeOS 23.0-SP1, board `amd64-fydeos_iris`
- kernel `6.12.54-01180-gb4e10020ba49-dirty`
- DOKING `17ef:613a`
- automatic recovery ผ่านการทดสอบ physical detach/reconnect แล้ว

รายละเอียดการวิเคราะห์และ handoff สำหรับ maintainer อยู่ใน
[`Handoff.md`](Handoff.md)
