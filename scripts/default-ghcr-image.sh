#!/usr/bin/env bash
set -euo pipefail

remote="$(git remote get-url origin 2>/dev/null || true)"

if [[ "$remote" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
  printf 'ghcr.io/%s/%s:latest\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
else
  printf 'ghcr.io/owner/archlinux-tart:latest\n'
fi
