#!/bin/bash
# Stage 2, runs ON the bake host after CML's first-boot setup has finished.
# Shuts the VM down and adapts the installed system for EC2:
#   1. EFI fallback path  - EC2 boots \EFI\BOOT\BOOTX64.EFI, which the CML
#      installer does not create (it only writes \EFI\ubuntu\).
#   2. NIC name           - CML's config refers to enp1s0 (the KVM name); a
#      systemd .link rule renames the ENA interface to match.
#   3. Bridge MAC         - drop the baked-in MAC pin and the DHCP client id
#      derived from it, so each new instance can adopt its own ENI MAC.
#   4. Serial console     - enable a getty on ttyS0 for EC2 serial access.
set -euo pipefail
echo "=== finalize: $(date) ==="

virsh shutdown cmlbake 2>/dev/null || true
for _ in $(seq 1 60); do
  [ "$(virsh domstate cmlbake 2>/dev/null)" = "shut off" ] && break
  sleep 5
done
[ "$(virsh domstate cmlbake 2>/dev/null)" = "shut off" ] || { echo "FATAL: VM still running"; exit 1; }
virsh change-media cmlbake sda --eject --config 2>/dev/null || true

TARGET=$(cat /root/target-disk)
partprobe "$TARGET" || true
sleep 2
lsblk -o NAME,SIZE,FSTYPE "$TARGET"

# --- 1. EFI fallback --------------------------------------------------------
mkdir -p /mnt/esp
mount "${TARGET}p1" /mnt/esp
if [ -d /mnt/esp/EFI/ubuntu ] && [ ! -f /mnt/esp/EFI/BOOT/BOOTX64.EFI ]; then
  mkdir -p /mnt/esp/EFI/BOOT
  cp /mnt/esp/EFI/ubuntu/shimx64.efi /mnt/esp/EFI/BOOT/BOOTX64.EFI 2>/dev/null \
    || cp /mnt/esp/EFI/ubuntu/grubx64.efi /mnt/esp/EFI/BOOT/BOOTX64.EFI
  cp /mnt/esp/EFI/ubuntu/grubx64.efi /mnt/esp/EFI/BOOT/ 2>/dev/null || true
  cp /mnt/esp/EFI/ubuntu/grub.cfg    /mnt/esp/EFI/BOOT/ 2>/dev/null || true
  echo "EFI fallback installed"
else
  echo "EFI fallback already present"
fi
umount /mnt/esp

# --- mount the installed root (CML uses LVM: vg00/lv_root) ------------------
vgchange -ay >/dev/null
mkdir -p /mnt/cmlroot
mount /dev/vg00/lv_root /mnt/cmlroot

# --- 2. NIC naming ----------------------------------------------------------
mkdir -p /mnt/cmlroot/etc/systemd/network
cat > /mnt/cmlroot/etc/systemd/network/10-ena-primary.link <<'LINK'
[Match]
Driver=ena

[Link]
Name=enp1s0
LINK
echo "ENA rename rule written"

# --- 3. un-pin the bridge MAC ----------------------------------------------
BR=$(grep -l 'bridge0:' /mnt/cmlroot/etc/netplan/*.yaml 2>/dev/null | head -1 || true)
if [ -n "$BR" ]; then
  sed -i '/macaddress:/d; /dhcp-client-id/d' "$BR"
  echo "MAC pin removed from $(basename "$BR")"
fi

# --- 4. serial console ------------------------------------------------------
mkdir -p /mnt/cmlroot/etc/systemd/system/getty.target.wants
ln -sf /lib/systemd/system/serial-getty@.service \
  /mnt/cmlroot/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service
echo "serial getty enabled"

umount /mnt/cmlroot
vgchange -an >/dev/null
sync
echo "=== finalize done: $(date) ==="
echo "Snapshot the target volume and register it as an AMI (see docs/BAKING.md)."
