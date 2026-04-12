#!/usr/bin/env bash
set -euo pipefail

# Stage 1: build a minimal bootable Arch Linux ARM raw disk image.
#
# Only what is required to reach a shell over SSH goes in here:
# rootfs, bootloader, virtio initramfs, systemd-networkd DHCP, openssh,
# a dev user with a known password, and the Tart Guest Agent so the host
# can resolve the VM's IP. Everything else (base-devel, rust, paru, ...)
# is installed by Packer in stage 2 against a real booted VM.

DISK_SIZE="${DISK_SIZE:-50}"
TARBALL="${TARBALL:-http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"
BUILD_DIR="${BUILD_DIR:-/mnt/workspace/.build}"
MNT="${MNT:-/mnt/arch}"
VM_USER="${VM_USER:-dev}"
VM_PASSWORD="${VM_PASSWORD:-dev}"

cleanup() {
  umount "$MNT"/{sys,proc,dev,boot} 2>/dev/null || true
  umount "$MNT" 2>/dev/null || true
  if [[ -n "${LOOP:-}" ]]; then
    losetup -d "$LOOP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  gdisk dosfstools e2fsprogs libarchive-tools xz-utils curl sudo psmisc

mkdir -p "$BUILD_DIR" "$MNT"
rm -f "$BUILD_DIR/disk.raw" "$BUILD_DIR/disk.raw.xz" "$BUILD_DIR/alarm.tar.gz"

printf 'Creating %sG disk image\n' "$DISK_SIZE"
truncate -s "${DISK_SIZE}G" "$BUILD_DIR/disk.raw"
sgdisk -Z "$BUILD_DIR/disk.raw" >/dev/null 2>&1
sgdisk -n 1:0:+512M -t 1:ef00 -n 2:0:0 -t 2:8300 "$BUILD_DIR/disk.raw" >/dev/null

LOOP="$(losetup --find --show --partscan "$BUILD_DIR/disk.raw")"
mkfs.vfat -F32 "${LOOP}p1" >/dev/null
mkfs.ext4 -qL root "${LOOP}p2" >/dev/null

mount "${LOOP}p2" "$MNT"
mkdir -p "$MNT/boot"
mount "${LOOP}p1" "$MNT/boot"

printf 'Downloading Arch Linux ARM rootfs\n'
curl -fSL "$TARBALL" -o "$BUILD_DIR/alarm.tar.gz"
bsdtar -xpf "$BUILD_DIR/alarm.tar.gz" -C "$MNT"

mkdir -p "$MNT/boot/loader/entries"
printf 'default arch.conf\ntimeout 0\n' > "$MNT/boot/loader/loader.conf"
printf 'title Arch Linux ARM\nlinux /Image\ninitrd /initramfs-linux.img\noptions root=LABEL=root rw console=hvc0\n' \
  > "$MNT/boot/loader/entries/arch.conf"

printf 'LABEL=root / ext4 defaults 0 1\n' > "$MNT/etc/fstab"

mkdir -p "$MNT/etc/systemd/network"
printf '[Match]\nName=en*\n\n[Network]\nDHCP=yes\n' \
  > "$MNT/etc/systemd/network/20-ethernet.network"
printf '[Match]\nName=eth*\n\n[Network]\nDHCP=yes\n' \
  > "$MNT/etc/systemd/network/21-ethernet-legacy.network"

mkdir -p "$MNT/etc/modules-load.d"
cat > "$MNT/etc/modules-load.d/virtio.conf" <<'EOF'
virtio_pci
virtio_net
virtio_blk
virtio_mmio
virtio_ring
virtio_rng
EOF

mkdir -p "$MNT/etc/ssh/sshd_config.d"
printf 'AcceptEnv ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN\nStreamLocalBindUnlink yes\n' \
  > "$MNT/etc/ssh/sshd_config.d/dev.conf"

mount --bind /dev "$MNT/dev"
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"

rm -f "$MNT/etc/resolv.conf"
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$MNT/etc/resolv.conf"
sed -i 's/^hosts:.*/hosts: files dns/' "$MNT/etc/nsswitch.conf"
touch "$MNT/etc/vconsole.conf"

chroot "$MNT" /bin/bash <<'UPGRADE'
set -euo pipefail
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Syu --noconfirm || true
UPGRADE

chroot "$MNT" env VM_USER="$VM_USER" VM_PASSWORD="$VM_PASSWORD" /bin/bash <<'CHROOT'
set -euo pipefail
pacman -S --needed --noconfirm openssh sudo mkinitcpio

bootctl install --esp-path=/boot --no-variables

sed -i 's/^MODULES=.*/MODULES=(virtio_pci virtio_net virtio_blk virtio_mmio virtio_ring)/' /etc/mkinitcpio.conf
mkinitcpio -P

systemctl enable sshd systemd-networkd systemd-resolved

useradd -m -G wheel -s /bin/bash "$VM_USER"
printf '%s:%s\n' "$VM_USER" "$VM_PASSWORD" | chpasswd
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel
CHROOT

fuser -km "$MNT" 2>/dev/null || true
sleep 1
umount -l "$MNT"/{sys,proc,dev}
umount "$MNT/boot"
umount "$MNT"
losetup -d "$LOOP"
unset LOOP

printf 'Compressing disk image\n'
xz -T0 -k -f "$BUILD_DIR/disk.raw"

printf 'Built %s and %s\n' "$BUILD_DIR/disk.raw" "$BUILD_DIR/disk.raw.xz"
