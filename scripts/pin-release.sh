#!/usr/bin/env bash
# Adds the darwin and linux archive checksums of tsc-rs release(s) to ./checksums.
#   scripts/pin-release.sh <version> [<version>...]
# Each checksum comes from the release's SHA256SUMS and is checked against the
# downloaded archive itself before it is pinned.
set -euo pipefail
cd "$(dirname "$0")/.."
. lib/utils.bash
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for v in "$@"; do
	url="${GH_REPO}/releases/download/v${v}"
	curl "${curl_opts[@]}" -o "$tmp/SHA256SUMS" "$url/SHA256SUMS" || fail "no SHA256SUMS for v$v"
	for os in darwin linux; do
		for arch in arm64 x64; do
			f="tsc-rs-${v}-${os}-${arch}.tar.gz"
			sum="$(awk -v f="$f" '$2 == f || $2 == "*"f {print $1}' "$tmp/SHA256SUMS")"
			[ -n "$sum" ] || { echo "skip $f (not in this release)"; continue; }
			curl "${curl_opts[@]}" -o "$tmp/$f" "$url/$f" || fail "could not download $f"
			[ "$(sha256_of "$tmp/$f")" = "$sum" ] || fail "$f does not match SHA256SUMS"
			rm -f "$tmp/$f"
			if grep -q "  $f\$" checksums; then
				grep -qx "$sum  $f" checksums || fail "$f is already pinned with a different checksum"
				echo "have $f"
			else
				echo "$sum  $f" >>checksums && echo "pin  $f"
			fi
		done
	done
done
{ grep "^#" checksums; grep -v "^#" checksums | LC_ALL=C sort -k2; } >checksums.tmp && mv checksums.tmp checksums
