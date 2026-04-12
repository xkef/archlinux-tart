#!/usr/bin/env bash
set -euo pipefail

# Two-stage build:
#   1. Inside a Debian builder VM, produce a minimal bootable disk.raw
#      (scripts/bootstrap-arch-disk.sh).
#   2. Boot that disk as a Tart VM and let Packer's tart-cli plugin SSH in
#      and run provisioners (arch.pkr.hcl). Packer handles SSH-wait and
#      shutdown, which is why this script no longer needs the hand-rolled
#      wait_for_ip / diagnostics / final-run-log logic.

VM_NAME="${VM_NAME:-archlinux-tart}"
BUILDER_VM="${BUILDER_VM:-archlinux-builder}"
BUILDER_BASE="${BUILDER_BASE:-ghcr.io/cirruslabs/debian:latest}"
DISK_SIZE="${DISK_SIZE:-50}"
CPU="${CPU:-4}"
MEMORY="${MEMORY:-8192}"
BUILD_DIR="${BUILD_DIR:-$PWD/.build}"
TART_HOME="${TART_HOME:-$PWD/.tart}"
WORKSPACE="${WORKSPACE:-$PWD}"
RUN_LOG="$BUILD_DIR/builder-run.log"
RUN_PID=""
export TART_HOME

cleanup() {
  if [[ -n "$RUN_PID" ]] && kill -0 "$RUN_PID" 2>/dev/null; then
    tart stop "$BUILDER_VM" --timeout 5 >/dev/null 2>&1 || true
    wait "$RUN_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

wait_for_exec() {
  local attempt
  for attempt in $(seq 1 60); do
    if tart exec "$BUILDER_VM" true >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  printf 'Builder VM did not become ready for tart exec.\n' >&2
  exit 1
}

require tart
require packer
require git
mkdir -p "$BUILD_DIR" "$TART_HOME"

# --- Stage 1: build disk.raw inside the Debian builder VM ---

if ! tart list | awk '{print $1}' | grep -qx "$BUILDER_VM"; then
  printf 'Cloning builder VM from %s\n' "$BUILDER_BASE"
  tart clone "$BUILDER_BASE" "$BUILDER_VM"
fi

printf 'Starting builder VM %s\n' "$BUILDER_VM"
tart stop "$BUILDER_VM" --timeout 2 >/dev/null 2>&1 || true
tart run "$BUILDER_VM" --no-graphics --dir "$WORKSPACE:tag=workspace" >"$RUN_LOG" 2>&1 &
RUN_PID="$!"
wait_for_exec

tart exec "$BUILDER_VM" sudo mkdir -p /mnt/workspace /mnt/arch
tart exec "$BUILDER_VM" sudo bash -lc \
  "mountpoint -q /mnt/workspace || mount -t virtiofs workspace /mnt/workspace"
tart exec "$BUILDER_VM" sudo env \
  DISK_SIZE="$DISK_SIZE" \
  BUILD_DIR=/mnt/workspace/.build \
  /mnt/workspace/scripts/bootstrap-arch-disk.sh

tart stop "$BUILDER_VM" --timeout 10 >/dev/null 2>&1 || true
wait "$RUN_PID" 2>/dev/null || true
RUN_PID=""

# --- Stage 2: create the final VM with that disk, customize via Packer ---

if tart list | awk '{print $1}' | grep -qx "$VM_NAME"; then
  tart delete "$VM_NAME"
fi

printf 'Creating final VM %s\n' "$VM_NAME"
tart create "$VM_NAME" --linux --disk-size "$DISK_SIZE"
tart set "$VM_NAME" --disk "$BUILD_DIR/disk.raw"
tart set "$VM_NAME" --cpu "$CPU" --memory "$MEMORY"

printf 'Running Packer provisioners on %s\n' "$VM_NAME"
cd "$WORKSPACE"
packer init arch.pkr.hcl
packer build \
  -var "vm_name=$VM_NAME" \
  -var "cpu_count=$CPU" \
  -var "memory_gb=$((MEMORY / 1024))" \
  arch.pkr.hcl

printf 'Local VM ready: %s\n' "$VM_NAME"
printf 'Raw disk: %s/disk.raw\n' "$BUILD_DIR"
