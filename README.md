# archlinux-tart

Arch Linux ARM64 base image for [Tart](https://tart.run) on Apple Silicon.

## What's included

- Official Arch Linux ARM aarch64 root filesystem
- EFI boot via systemd-boot, systemd-networkd
- `fish` shell as default for the `dev` user
- `en_US.UTF-8` locale, hostname `arch`
- `git`, `stow`, `base-devel`, `rust`, `paru`
- Tart Guest Agent for IP resolution
- VirtioFS mount unit at `/home/dev/code` (tag `code`, `nofail`)
- 200G sparse disk (actual usage starts at ~2G)

## Quick start

Pull the pre-built image and run it:

```bash
tart clone ghcr.io/xkef/archlinux-tart:latest archlinux
tart run archlinux --no-graphics
```

SSH in (after injecting your key via `tart exec`):

```bash
tart exec archlinux sh -c \
  "install -d -m700 -o dev /home/dev/.ssh \
   && cat >> /home/dev/.ssh/authorized_keys" \
  < ~/.ssh/id_ed25519.pub
ssh dev@$(tart ip archlinux --resolver agent)
```

## VirtioFS code sharing

Pass a host directory with tag `code` to auto-mount at `/home/dev/code`:

```bash
tart run archlinux --no-graphics --dir "$HOME/code:tag=code"
```

The image ships a systemd mount unit (`home-dev-code.mount`) that mounts
the `code` virtiofs tag at boot. If no share is provided the unit times
out after 5 seconds and boot continues normally.

## Build

Requires `tart`, `packer`, and `git`. The build runs in two stages:

1. A Debian builder VM produces a minimal bootable `disk.raw` (rootfs,
   boot, SSH, `dev` user)
2. Packer boots that disk as a Tart VM and provisions packages, tools,
   and configuration over SSH

```bash
make build
```

Overrides:

```bash
make build DISK_SIZE=100 CPU=6 MEMORY=12288
```

## Push to GHCR

Authenticate with `gh` (needs `write:packages` scope), then:

```bash
make push
```

This pushes the local VM as an OCI image, installs it into `~/.tart` as
`archlinux-base`, and cleans up build artifacts.

## Clean

```bash
make clean
```
