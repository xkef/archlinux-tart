#!/usr/bin/env bash
set -euo pipefail

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

wait_for_ip() {
  local name="$1"
  local resolver="${2:-dhcp}"
  local attempt
  for attempt in $(seq 1 60); do
    if tart ip "$name" --resolver "$resolver" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

wait_for_exec_ready() {
  local name="$1"
  local attempt
  for attempt in $(seq 1 90); do
    if tart exec "$name" true >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

print_guest_diagnostics() {
  local name="$1"
  tart exec "$name" sh -lc '
    echo "--- ip -br link ---"
    ip -br link || true
    echo
    echo "--- ip -br addr ---"
    ip -br addr || true
    echo
    echo "--- lsmod ---"
    lsmod | grep -E "virtio|vmw|e1000|igb|hv" || true
    echo
    echo "--- failed units ---"
    systemctl --no-pager --failed || true
    echo
    echo "--- systemd-networkd ---"
    systemctl status systemd-networkd --no-pager || true
    echo
    echo "--- tart-guest-agent ---"
    systemctl status tart-guest-agent --no-pager || true
    echo
    echo "--- networkd journal ---"
    journalctl -u systemd-networkd -b --no-pager -n 120 || true
    echo
    echo "--- guest-agent journal ---"
    journalctl -u tart-guest-agent -b --no-pager -n 120 || true
  ' || true
}

require tart
require git
mkdir -p "$BUILD_DIR" "$TART_HOME"

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
tart exec "$BUILDER_VM" sudo bash -lc \
  "DEBIAN_FRONTEND=noninteractive apt-get update && \
   DEBIAN_FRONTEND=noninteractive apt-get install -y gdisk dosfstools e2fsprogs libarchive-tools xz-utils curl sudo psmisc"
tart exec "$BUILDER_VM" sudo env \
  DISK_SIZE="$DISK_SIZE" \
  BUILD_DIR="/mnt/workspace/.build" \
  /mnt/workspace/scripts/build-arch-image.sh

tart stop "$BUILDER_VM" --timeout 10 >/dev/null 2>&1 || true
wait "$RUN_PID" 2>/dev/null || true
RUN_PID=""

if tart list | awk '{print $1}' | grep -qx "$VM_NAME"; then
  tart delete "$VM_NAME"
fi

printf 'Creating final VM %s\n' "$VM_NAME"
tart create "$VM_NAME" --linux --disk-size "$DISK_SIZE"
tart set "$VM_NAME" --disk "$BUILD_DIR/disk.raw"
tart set "$VM_NAME" --cpu "$CPU" --memory "$MEMORY"

printf 'Boot-checking final VM %s\n' "$VM_NAME"
tart stop "$VM_NAME" --timeout 2 >/dev/null 2>&1 || true
tart run "$VM_NAME" --no-graphics >"$BUILD_DIR/final-run.log" 2>&1 &
RUN_PID="$!"
if ! wait_for_exec_ready "$VM_NAME"; then
  printf 'VM %s did not become reachable via tart exec.\n' "$VM_NAME" >&2
  tart stop "$VM_NAME" --timeout 10 >/dev/null 2>&1 || true
  wait "$RUN_PID" 2>/dev/null || true
  RUN_PID=""
  if [[ -f "$BUILD_DIR/final-run.log" ]]; then
    printf '\nRun log tail:\n' >&2
    tail -n 120 "$BUILD_DIR/final-run.log" >&2 || true
  fi
  exit 1
fi

if ! wait_for_ip "$VM_NAME" agent; then
  printf 'VM %s did not acquire an IP address via Tart Guest Agent.\n' "$VM_NAME" >&2
  print_guest_diagnostics "$VM_NAME" >&2
  tart stop "$VM_NAME" --timeout 10 >/dev/null 2>&1 || true
  wait "$RUN_PID" 2>/dev/null || true
  RUN_PID=""
  exit 1
fi

if ! wait_for_ip "$VM_NAME" dhcp; then
  printf 'Warning: VM %s is reachable but host DHCP IP lookup did not resolve. Continuing.\n' "$VM_NAME" >&2
fi

tart stop "$VM_NAME" --timeout 10 >/dev/null 2>&1 || true
wait "$RUN_PID" 2>/dev/null || true
RUN_PID=""

printf 'Local VM ready: %s\n' "$VM_NAME"
printf 'Raw disk: %s/disk.raw\n' "$BUILD_DIR"
