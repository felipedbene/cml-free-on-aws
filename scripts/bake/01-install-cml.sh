#!/bin/bash
# Stage 1, runs ON the bake host (Ubuntu 24.04, nested-virt instance).
# Installs KVM, pulls the CML controller ISO from S3, and boots the installer
# in a VM whose disk is the raw EBS volume that becomes the AMI.
#
# Expects: S3_BUCKET, CML_ISO_KEY, AWS_REGION (exported by the operator, see docs/BAKING.md)
set -euo pipefail
exec > /var/log/cml-bake.log 2>&1
export DEBIAN_FRONTEND=noninteractive

: "${S3_BUCKET:?S3_BUCKET not set}"
: "${CML_ISO_KEY:=cml-iso.zip}"
: "${AWS_REGION:=us-east-1}"
TARGET_SIZE="${TARGET_SIZE:-64G}"
VM_RAM_MB="${VM_RAM_MB:-12288}"
# CML's setup refuses to run with fewer than 4 CPUs.
VM_VCPUS="${VM_VCPUS:-4}"

echo "=== CML bake stage 1: $(date) ==="
cloud-init status --wait || true

# Ubuntu's unattended-upgrades holds the apt lock on first boot.
for i in $(seq 1 60); do
  fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1 || break
  echo "apt busy, waiting ($i)"; sleep 10
done

APT="apt-get -o DPkg::Lock::Timeout=600"
$APT update -qq
$APT install -y -qq qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
  ovmf unzip python3-venv

[ -e /dev/kvm ] || { echo "FATAL: /dev/kvm missing; nested virtualization is not enabled"; exit 1; }
echo "KVM present"

command -v aws >/dev/null || snap install aws-cli --classic

# vncdotool lets you drive the installer console headlessly.
python3 -m venv /opt/vnctool && /opt/vnctool/bin/pip install -q vncdotool

TARGET=$(lsblk -dn -o NAME,SIZE | awk -v s="$TARGET_SIZE" '$2==s{print "/dev/"$1}' \
  | grep -v "$(lsblk -no pkname "$(findmnt -no SOURCE /)" 2>/dev/null || echo nvme0n1)" \
  | head -1)
[ -n "$TARGET" ] || TARGET=$(lsblk -dn -o NAME,SIZE | awk -v s="$TARGET_SIZE" '$2==s{print "/dev/"$1}' | tail -1)
[ -n "$TARGET" ] || { echo "FATAL: no $TARGET_SIZE target disk found"; lsblk; exit 1; }
echo "$TARGET" > /root/target-disk
echo "Target disk: $TARGET"

mkdir -p /opt/cml
aws s3 cp "s3://$S3_BUCKET/$CML_ISO_KEY" /opt/cml/cml-iso.zip --region "$AWS_REGION" --only-show-errors
cd /opt/cml && unzip -o -q cml-iso.zip && rm -f cml-iso.zip
ISO=$(find /opt/cml -iname 'cml2*.iso' | head -1)
[ -n "$ISO" ] || { echo "FATAL: no cml2*.iso inside $CML_ISO_KEY"; find /opt/cml -maxdepth 2; exit 1; }
echo "Installer ISO: $ISO"

systemctl enable --now libvirtd
sleep 2
virsh net-start default 2>/dev/null || true
virsh net-autostart default 2>/dev/null || true

virsh destroy cmlbake 2>/dev/null || true
virsh undefine cmlbake --nvram 2>/dev/null || true

# UEFI is mandatory for the CML installer. The VM writes straight to the EBS
# volume, so the installed system lands on the disk we later snapshot.
virt-install \
  --name cmlbake \
  --ram "$VM_RAM_MB" \
  --vcpus "$VM_VCPUS" \
  --cpu host-passthrough \
  --osinfo ubuntu24.04 \
  --disk path="$TARGET",format=raw,bus=virtio,cache=none \
  --cdrom "$ISO" \
  --network network=default,model=virtio \
  --graphics vnc,listen=127.0.0.1 \
  --boot uefi \
  --noautoconsole \
  --wait 0

echo "Installer VM started; it partitions the disk and reboots on its own."
virsh list --all
echo "=== stage 1 done: $(date) ==="
