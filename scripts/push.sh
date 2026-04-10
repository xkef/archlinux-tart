#!/usr/bin/env bash
set -euo pipefail

VM_NAME="${VM_NAME:-archlinux-tart}"
GHCR_IMAGE="${GHCR_IMAGE:-$(dirname "$0")/default-ghcr-image.sh}"
INSTALL_VM_NAME="${INSTALL_VM_NAME:-archlinux-base}"
INSTALL_TART_HOME="${INSTALL_TART_HOME:-$HOME/.tart}"
export TART_HOME="${TART_HOME:-$PWD/.tart}"
TMP_ERR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cleanup() {
  if [[ -n "$TMP_ERR" && -f "$TMP_ERR" ]]; then
    rm -f "$TMP_ERR"
  fi
}
trap cleanup EXIT

if [[ "$GHCR_IMAGE" == */default-ghcr-image.sh ]]; then
  GHCR_IMAGE="$("$GHCR_IMAGE")"
fi

if ! command -v gh >/dev/null 2>&1; then
  printf 'Missing required command: gh\n' >&2
  exit 1
fi

GHCR_USERNAME="$(gh api user --jq .login)"
GHCR_TOKEN="$(gh auth token)"

if [[ -z "$GHCR_USERNAME" || -z "$GHCR_TOKEN" ]]; then
  printf 'Authenticate with gh before pushing.\n' >&2
  exit 1
fi

printf '%s' "$GHCR_TOKEN" | tart login ghcr.io --username "$GHCR_USERNAME" --password-stdin
TMP_ERR="$(mktemp)"

if ! tart push "$VM_NAME" "$GHCR_IMAGE" \
  --label "org.opencontainers.image.title=$VM_NAME" \
  --label "org.opencontainers.image.source=$(git remote get-url origin)" \
  2>"$TMP_ERR"; then
  cat "$TMP_ERR" >&2

  if rg -q 'permission_denied: The token provided does not match expected scopes' "$TMP_ERR"; then
    printf '\nRefresh gh auth with package scope and retry:\n' >&2
    printf '  gh auth refresh -h github.com -s write:packages\n' >&2
    printf 'If that does not work, re-authenticate with gh using a token that has write:packages.\n' >&2
  fi

  exit 1
fi

printf 'Installing %s locally as %s in %s\n' "$GHCR_IMAGE" "$INSTALL_VM_NAME" "$INSTALL_TART_HOME"
mkdir -p "$INSTALL_TART_HOME"
TART_HOME="$INSTALL_TART_HOME" tart delete "$INSTALL_VM_NAME" >/dev/null 2>&1 || true
TART_HOME="$INSTALL_TART_HOME" tart clone "$GHCR_IMAGE" "$INSTALL_VM_NAME"

printf 'Cleaning repo-local build artifacts\n'
rm -f "$REPO_ROOT/.build/disk.raw" "$REPO_ROOT/.build/disk.raw.xz" "$REPO_ROOT/.build/alarm.tar.gz"
TART_HOME="$TART_HOME" tart delete "$VM_NAME" >/dev/null 2>&1 || true
