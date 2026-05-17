#!/usr/bin/env bash
# Build a release Linux bundle and (optionally) wrap it in a tar.gz.
# Run from any directory; the script resolves the repo root from its own path.
#
# Usage:
#   tools/build_linux_release.sh           # builds + packages tarball
#   tools/build_linux_release.sh --no-tar  # builds bundle only
#   tools/build_linux_release.sh --skip-flutter-build
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pubspec="$repo_root/pubspec.yaml"
bundle_dir="$repo_root/build/linux/x64/release/bundle"
cores_dir="$repo_root/tools/cores/linux"

skip_flutter_build=0
make_tarball=1
for arg in "$@"; do
  case "$arg" in
    --skip-flutter-build) skip_flutter_build=1 ;;
    --no-tar) make_tarball=0 ;;
    -h|--help)
      sed -n '2,12p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [ ! -f "$pubspec" ]; then
  echo "pubspec.yaml not found at $pubspec" >&2
  exit 1
fi

if [ ! -d "$cores_dir" ] || [ -z "$(ls -A "$cores_dir" 2>/dev/null || true)" ]; then
  echo "WARNING: $cores_dir is empty. The bundle will have no core binaries." >&2
  echo "         Drop xray and sing-box Linux binaries there and chmod +x them." >&2
fi

if [ "$skip_flutter_build" -ne 1 ]; then
  ( cd "$repo_root" && flutter build linux --release )
fi

if [ ! -d "$bundle_dir" ]; then
  echo "Bundle not found at $bundle_dir" >&2
  exit 1
fi

if [ "$make_tarball" -ne 1 ]; then
  echo "Bundle: $bundle_dir"
  exit 0
fi

# Extract version (drop +N suffix) from pubspec.
app_version="$(grep -E '^version:' "$pubspec" | head -n1 | awk '{print $2}' | cut -d+ -f1)"
if [ -z "$app_version" ]; then
  echo "Could not parse version from $pubspec" >&2
  exit 1
fi

dist_dir="$repo_root/build/linux/dist"
mkdir -p "$dist_dir"
tarball="$dist_dir/entropy_vpn-${app_version}-linux-x64.tar.gz"

# Pack the bundle under a top-level entropy_vpn/ directory so extraction is
# self-contained.
tmp_stage="$(mktemp -d)"
trap 'rm -rf "$tmp_stage"' EXIT
cp -a "$bundle_dir" "$tmp_stage/entropy_vpn"
tar -C "$tmp_stage" -czf "$tarball" entropy_vpn

echo "Tarball: $tarball"
