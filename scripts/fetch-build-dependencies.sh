#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dependencies_dir="$repo_dir/.build-dependencies"
muxer_dir="$dependencies_dir/minimuxer"
muxer_commit=12be70dc2627307a16bfd2dc7a009080d5bec909

# minimuxer references Common and DeviceGateway as relative Swift packages.
if [[ ! -e "$muxer_dir" ]]; then
  mkdir -p "$dependencies_dir"
  (
    incoming="$(mktemp -d "$dependencies_dir/minimuxer.XXXXXX")"
    trap 'rm -rf -- "$incoming"' EXIT
    git -C "$incoming" init --quiet
    git -C "$incoming" fetch --quiet --depth 1 https://github.com/SideStore/minimuxer.git "$muxer_commit"
    git -C "$incoming" checkout --quiet --detach FETCH_HEAD
    mv -- "$incoming" "$muxer_dir"
  )
fi

if [[ "$(git -C "$muxer_dir" rev-parse HEAD)" != "$muxer_commit" ]] ||
   [[ -n "$(git -C "$muxer_dir" status --porcelain)" ]]; then
  printf '%s\n' 'The local minimuxer source differs from the pinned checkout.' >&2
  exit 1
fi
