#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dependencies_dir="$repo_dir/.build-dependencies"
muxer_dir="$dependencies_dir/minimuxer"
muxer_commit=12be70dc2627307a16bfd2dc7a009080d5bec909
anisette_dir="$dependencies_dir/AnisetteKit"
anisette_commit=db8b41022697b6c19be8a5f01a1ce834145a2a26
anisette_patch="$repo_dir/scripts/anisette-cleanup.patch"

fetch_checkout() {
  local destination="$1" url="$2" revision="$3" patch="${4:-}"
  if [[ -e "$destination" ]]; then
    return
  fi
  (
    incoming="$(mktemp -d "$dependencies_dir/incoming.XXXXXX")"
    trap 'rm -rf -- "$incoming"' EXIT
    git -C "$incoming" init --quiet
    git -C "$incoming" fetch --quiet --depth 1 "$url" "$revision"
    git -C "$incoming" checkout --quiet --detach FETCH_HEAD
    if [[ -n "$patch" ]]; then
      git -C "$incoming" apply "$patch"
    fi
    mv -- "$incoming" "$destination"
  )
}

mkdir -p "$dependencies_dir"
# minimuxer references Common and DeviceGateway as relative Swift packages.
fetch_checkout "$muxer_dir" https://github.com/SideStore/minimuxer.git "$muxer_commit"
if [[ "$(git -C "$muxer_dir" rev-parse HEAD)" != "$muxer_commit" ]] ||
   [[ -n "$(git -C "$muxer_dir" status --porcelain)" ]]; then
  printf '%s\n' 'The local minimuxer source differs from the pinned checkout.' >&2
  exit 1
fi

fetch_checkout "$anisette_dir" https://github.com/mahee96/AnisetteKit.git "$anisette_commit" "$anisette_patch"
if [[ "$(git -C "$anisette_dir" rev-parse HEAD)" != "$anisette_commit" ]] ||
   [[ -n "$(git -C "$anisette_dir" ls-files --others --exclude-standard)" ]] ||
   ! git -C "$anisette_dir" -c core.abbrev=7 diff --no-color --no-ext-diff HEAD | cmp -s "$anisette_patch" -; then
  printf '%s\n' 'The local AnisetteKit source differs from the pinned checkout with the cleanup patch.' >&2
  exit 1
fi
