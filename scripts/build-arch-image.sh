#!/usr/bin/env bash
set -euo pipefail

DISK_SIZE="${DISK_SIZE:-200}"
VM_USER="${VM_USER:-dev}"
TARBALL="${TARBALL:-http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"
TART_GUEST_AGENT_VERSION="${TART_GUEST_AGENT_VERSION:-v0.9.0}"
TART_GUEST_AGENT_URL="${TART_GUEST_AGENT_URL:-https://github.com/cirruslabs/tart-guest-agent/releases/download/${TART_GUEST_AGENT_VERSION}/tart-guest-agent-linux-arm64.tar.gz}"
BUILD_DIR="${BUILD_DIR:-/mnt/workspace/.build}"
MNT="${MNT:-/mnt/arch}"

cleanup() {
  umount "$MNT"/{sys,proc,dev,boot} 2>/dev/null || true
  umount "$MNT" 2>/dev/null || true
  if [[ -n "${LOOP:-}" ]]; then
    losetup -d "$LOOP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "$BUILD_DIR"
rm -f "$BUILD_DIR/disk.raw" "$BUILD_DIR/disk.raw.xz"

printf 'Creating %sG disk image\n' "$DISK_SIZE"
truncate -s "${DISK_SIZE}G" "$BUILD_DIR/disk.raw"
sgdisk -Z "$BUILD_DIR/disk.raw" >/dev/null 2>&1
sgdisk -n 1:0:+512M -t 1:ef00 -n 2:0:0 -t 2:8300 "$BUILD_DIR/disk.raw" >/dev/null

LOOP="$(losetup --find --show --partscan "$BUILD_DIR/disk.raw")"
mkfs.vfat -F32 "${LOOP}p1" >/dev/null
mkfs.ext4 -qL root "${LOOP}p2" >/dev/null

mkdir -p "$MNT"
mount "${LOOP}p2" "$MNT"
mkdir -p "$MNT/boot"
mount "${LOOP}p1" "$MNT/boot"

if [[ ! -f "$BUILD_DIR/alarm.tar.gz" ]]; then
  printf 'Downloading Arch Linux ARM rootfs\n'
  curl -fSL "$TARBALL" -o "$BUILD_DIR/alarm.tar.gz"
fi
bsdtar -xpf "$BUILD_DIR/alarm.tar.gz" -C "$MNT"

printf 'Installing Tart Guest Agent %s\n' "$TART_GUEST_AGENT_VERSION"
mkdir -p "$BUILD_DIR/tart-guest-agent" "$MNT/usr/local/bin" "$MNT/etc/systemd/system"
curl -fSL "$TART_GUEST_AGENT_URL" -o "$BUILD_DIR/tart-guest-agent-linux-arm64.tar.gz"
tar -xzf "$BUILD_DIR/tart-guest-agent-linux-arm64.tar.gz" -C "$BUILD_DIR/tart-guest-agent"
install -m 0755 "$BUILD_DIR/tart-guest-agent/tart-guest-agent" "$MNT/usr/local/bin/tart-guest-agent"
cat >"$MNT/etc/systemd/system/tart-guest-agent.service" <<'EOF'
[Unit]
Description=Guest agent for Tart VMs
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/tart-guest-agent --run-rpc
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$MNT/boot/loader/entries"
printf 'default arch.conf\ntimeout 0\n' >"$MNT/boot/loader/loader.conf"
printf 'title Arch Linux ARM\nlinux /Image\ninitrd /initramfs-linux.img\noptions root=LABEL=root rw console=hvc0\n' \
  >"$MNT/boot/loader/entries/arch.conf"

printf 'LABEL=root / ext4 defaults 0 1\n' >"$MNT/etc/fstab"

mkdir -p "$MNT/etc/systemd/network"
printf '[Match]\nName=en*\n\n[Network]\nDHCP=yes\n' \
  >"$MNT/etc/systemd/network/20-ethernet.network"
printf '[Match]\nName=eth*\n\n[Network]\nDHCP=yes\n' \
  >"$MNT/etc/systemd/network/21-ethernet-legacy.network"
mkdir -p "$MNT/etc/modules-load.d"
cat >"$MNT/etc/modules-load.d/virtio.conf" <<'EOF'
virtio_pci
virtio_net
virtio_blk
virtio_mmio
virtio_ring
virtio_rng
EOF

mkdir -p "$MNT/etc/ssh/sshd_config.d"
printf 'AcceptEnv ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN\nStreamLocalBindUnlink yes\n' \
  >"$MNT/etc/ssh/sshd_config.d/dev.conf"

printf 'arch\n' >"$MNT/etc/hostname"

sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' "$MNT/etc/locale.gen"
printf 'LANG=en_US.UTF-8\n' >"$MNT/etc/locale.conf"

cat >"$MNT/etc/systemd/system/home-dev-code.mount" <<'EOF'
[Unit]
Description=VirtioFS shared code directory

[Mount]
What=code
Where=/home/dev/code
Type=virtiofs
Options=nofail
TimeoutSec=5

[Install]
WantedBy=multi-user.target
EOF

mount --bind /dev "$MNT/dev"
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"

rm -f "$MNT/etc/resolv.conf"
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"$MNT/etc/resolv.conf"
sed -i 's/^hosts:.*/hosts: files dns/' "$MNT/etc/nsswitch.conf"
touch "$MNT/etc/vconsole.conf"

chroot "$MNT" /bin/bash <<'CHROOT'
set -euo pipefail
useradd -r -d / -s /usr/bin/nologin alpm 2>/dev/null || true
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Syu --noconfirm || true
locale-gen
ldconfig
pacman -S --needed --noconfirm openssh git rsync stow base-devel rust sudo mkinitcpio fish

# Install an actual EFI bootloader into the image's ESP.
bootctl install --esp-path=/boot --no-variables

# Ensure Tart's virtio devices are available during early boot.
sed -i 's/^MODULES=.*/MODULES=(virtio_pci virtio_net virtio_blk virtio_mmio virtio_ring)/' /etc/mkinitcpio.conf
mkinitcpio -P

systemctl enable sshd systemd-networkd systemd-resolved
systemctl enable tart-guest-agent.service home-dev-code.mount

useradd -m -G wheel -s /usr/bin/fish dev
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel
userdel -r alarm 2>/dev/null || true
install -d -m 755 -o dev -g dev /home/dev/code

su - dev -c '
  git clone https://aur.archlinux.org/paru.git /tmp/paru
  cd /tmp/paru && makepkg -si --noconfirm
  rm -rf /tmp/paru
'
paru --version

rm -rf /var/cache/pacman/pkg/*
CHROOT

fuser -km "$MNT" 2>/dev/null || true
sleep 1
umount -l "$MNT"/{sys,proc,dev}
umount "$MNT/boot"
umount "$MNT"
losetup -d "$LOOP"
unset LOOP

printf 'Built %s\n' "$BUILD_DIR/disk.raw"
