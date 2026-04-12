# archlinux-tart

Local-first Arch Linux ARM Tart image builder for Apple Silicon.

This repo does two things:

1. Boots a disposable Linux Tart VM locally and uses it as the build host.
2. Produces a bootable Arch Linux ARM Tart base image, injects that disk into a local Tart VM, and can push the finished VM to `ghcr.io`.

Build and publish happen from your machine.

## What gets built

- Official Arch Linux ARM aarch64 root filesystem
- EFI boot via systemd-boot
- `cloud-init`, `openssh`, `systemd-networkd`
- `git`, `stow`, `base-devel`, `rust`, `paru`
- Tart Guest Agent
- A generic `dev` user ready for post-boot sync/provisioning

## Requirements

- Apple Silicon Mac
- `tart`
- `packer` (with the `cirruslabs/tart` plugin; `packer init` will fetch it)
- `gh`
- network access to:
  - `os.archlinuxarm.org`
  - GitHub Releases for `tart-guest-agent`
  - `aur.archlinux.org`
  - `ghcr.io`

The build clones a Linux Tart builder VM from `ghcr.io/cirruslabs/debian:latest` the first time and reuses it after that.

## Build locally

```bash
make build
```

Useful overrides:

```bash
make build \
  VM_NAME=archlinux-tart \
  BUILDER_VM=my-linux-builder \
  BUILDER_BASE=ghcr.io/cirruslabs/debian:latest \
  DISK_SIZE=80 \
  CPU=6 \
  MEMORY=12288
```

The build leaves behind:

- local Tart VM: `archlinux-tart` by default
- builder VM: `archlinux-builder` by default
- raw disk: `.build/disk.raw`
- compressed raw disk: `.build/disk.raw.xz`

## Push to GHCR

Authenticate once with `gh` so it has package write access, then run:

```bash
make push
```

After a successful push, the script also:

- installs the image into your normal Tart home as `archlinux-base`
- removes `.build/disk.raw` and `.build/disk.raw.xz`
- deletes the repo-local published VM copy

By default the image name is derived from `origin`, for example:

```bash
ghcr.io/xkef/archlinux-tart:latest
```

Override it when needed:

```bash
make push GHCR_IMAGE=ghcr.io/xkef/archlinux-tart:dev
```

To change where the local installed image lands:

```bash
make push INSTALL_VM_NAME=archlinux-base INSTALL_TART_HOME=$HOME/.tart
```

## Workflow

`make build` runs in two stages:

**Stage 1 — bootstrap** (`scripts/bootstrap-arch-disk.sh`, inside the Debian builder VM)

- clones or reuses the Linux builder VM
- mounts this repo into the builder VM with `virtiofs`
- produces a minimal bootable `disk.raw` — just what's needed to reach SSH: rootfs, systemd-boot, virtio initramfs, `systemd-networkd` DHCP, `openssh`, and a `dev` user with a known password

**Stage 2 — customize** (`arch.pkr.hcl`, driven by Packer against the booted VM)

- recreates the target Tart VM from the bootstrap disk
- boots it and SSHes in as `dev` / `dev`
- `pacman -S git rsync stow base-devel rust cloud-init`
- installs and enables `tart-guest-agent` (binary + systemd unit from `files/tart-guest-agent.service`)
- builds `paru-bin` from the AUR as the `dev` user
- Packer's successful SSH connect is the boot-check — no hand-rolled `wait_for_ip` / diagnostics required

The split means a failing provisioner does not invalidate the bootstrap disk, so you can iterate on stage 2 without rebuilding the base.

`make push`

- reads your GitHub login and token from `gh`
- logs `tart` into `ghcr.io`
- pushes the local Tart VM as an OCI image

## Dotfiles workflow

This image is intentionally generic. It does not bake in your local dotfiles repo.

Use your local `vm` helper after pull/create/start:

```bash
vm pull
vm create
vm start
vm sync
```

That keeps the published image reusable and moves machine-specific setup to a post-boot sync step.
