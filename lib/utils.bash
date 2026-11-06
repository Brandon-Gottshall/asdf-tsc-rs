#!/usr/bin/env bash
# Shared helpers for the asdf-tsc-rs plugin.
# Upstream: https://github.com/pingdotgg/ts-rust (release tags vX.Y.Z, assets
# tsc-rs-<version>-<os>-<arch>.tar.gz plus SHA256SUMS).

set -euo pipefail

GH_REPO="https://github.com/pingdotgg/ts-rust"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL_NAME="tsc-rs"

fail() {
	echo "asdf-${TOOL_NAME}: $*" >&2
	exit 1
}

# Release assets are public downloads, so no GitHub token is needed or sent.
curl_opts=(-fsSL --retry 3 --proto '=https' --tlsv1.2)

sort_versions() {
	sed 'h; s/[+-]/./g; s/.p\([[:digit:]]\)/.z\1/; s/$/.z/; G; s/\n/ /' |
		LC_ALL=C sort -t. -k 1,1 -k 2,2n -k 3,3n -k 4,4n -k 5,5n | awk '{print $2}'
}

list_all_versions() {
	git ls-remote --tags --refs "$GH_REPO" |
		grep -o 'refs/tags/v[0-9].*' | sed 's|^refs/tags/v||'
}

platform_os() {
	case "$(uname -s)" in
	Darwin) echo darwin ;;
	Linux) echo linux ;;
	*) fail "unsupported OS $(uname -s); upstream ships darwin, linux and win32 archives" ;;
	esac
}

platform_arch() {
	case "$(uname -m)" in
	arm64 | aarch64) echo arm64 ;;
	x86_64 | amd64) echo x64 ;;
	*) fail "unsupported architecture $(uname -m)" ;;
	esac
}

archive_name() {
	echo "${TOOL_NAME}-$1-$(platform_os)-$(platform_arch).tar.gz"
}

sha256_of() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		sha256sum "$1" | awk '{print $1}'
	fi
}

# download_release <version> <download_dir>
# Fetches the platform archive and SHA256SUMS and refuses anything that does
# not match the published checksum.
download_release() {
	local version="$1" dir="$2" archive url expected actual
	archive="$(archive_name "$version")"
	url="${GH_REPO}/releases/download/v${version}"
	mkdir -p "$dir"

	echo "* Downloading ${TOOL_NAME} ${version} (${archive})" >&2
	curl "${curl_opts[@]}" -o "${dir}/SHA256SUMS" "${url}/SHA256SUMS" ||
		fail "could not download SHA256SUMS for v${version} from ${url}"
	curl "${curl_opts[@]}" -o "${dir}/${archive}" "${url}/${archive}" ||
		fail "could not download ${archive} from ${url}"

	expected="$(awk -v f="$archive" '$2 == f || $2 == "*"f {print $1}' "${dir}/SHA256SUMS")"
	[ -n "$expected" ] || fail "${archive} is not listed in SHA256SUMS for v${version}"
	actual="$(sha256_of "${dir}/${archive}")"
	if [ "$expected" != "$actual" ]; then
		rm -f "${dir}/${archive}"
		fail "checksum mismatch for ${archive}: expected ${expected}, got ${actual}"
	fi
	echo "* Verified ${archive} sha256 ${actual} against SHA256SUMS" >&2

	# A checksum pinned in this repo guards against a replaced release, which a
	# SHA256SUMS from the same release cannot detect. Unknown versions are
	# allowed with a notice, so new releases can be installed before pinning.
	local pinned
	pinned="$(awk -v f="$archive" '$2 == f {print $1}' "${PLUGIN_DIR}/checksums" 2>/dev/null)"
	if [ -n "$pinned" ]; then
		if [ "$pinned" != "$actual" ]; then
			rm -f "${dir}/${archive}"
			fail "checksum mismatch for ${archive}: this plugin pins ${pinned}, release has ${actual}"
		fi
		echo "* Verified ${archive} against the checksum pinned in this plugin" >&2
	else
		echo "* Note: ${archive} has no checksum pinned in this plugin; verified against SHA256SUMS only" >&2
	fi

	# Refuse absolute paths, parent-directory traversal and links in the archive.
	# Names come from the plain listing (whole lines, so spaces are kept); types
	# from the verbose one, where links show as l/h or as "->" / "link to".
	local bad
	bad="$(
		tar -tzf "${dir}/${archive}" | grep -E '^/|(^|/)\.\.(/|$)' | sed 's/^/unsafe path: /'
		tar -tzvf "${dir}/${archive}" | grep -vE '^[-d]' | sed 's/^/link or special: /'
		tar -tzvf "${dir}/${archive}" | grep -E ' -> | link to ' | sed 's/^/link: /'
	)" || true
	if [ -n "$bad" ]; then
		rm -f "${dir}/${archive}"
		fail "refusing ${archive}: ${bad}"
	fi
	tar -xzf "${dir}/${archive}" -C "$dir" --no-same-owner || fail "could not extract ${archive}"
	rm -f "${dir}/${archive}"
}

# install_release <version> <download_dir> <install_path>
# Layout:
#   <install_path>/libexec/  upstream archive contents, unchanged: the `tsc`
#                            executable with its adjacent lib.*.d.ts files
#   <install_path>/bin/tsc-rs -> ../libexec/tsc
# The executable locates its lib files from its resolved path, so the symlink
# keeps them adjacent. Only `tsc-rs` is exposed, so no `tsc` shim is created.
install_release() {
	local version="$1" dl="$2" dest="$3" src
	src="${dl}/${TOOL_NAME}-${version}-$(platform_os)-$(platform_arch)"
	[ -x "${src}/tsc" ] || fail "expected executable ${src}/tsc after extraction"
	[ -f "${src}/lib.d.ts" ] || fail "expected ${src}/lib.d.ts after extraction"

	mkdir -p "${dest}/libexec" "${dest}/bin" || fail "could not create ${dest}"
	cp -R "${src}/." "${dest}/libexec/" || fail "could not copy the release into ${dest}/libexec"
	ln -sf ../libexec/tsc "${dest}/bin/tsc-rs" || fail "could not link ${dest}/bin/tsc-rs"

	local libs
	libs="$(find "${dest}/libexec" -maxdepth 1 -name 'lib*.d.ts' | wc -l | tr -d ' ')"
	[ "$libs" -gt 0 ] || fail "no lib*.d.ts files were installed next to the executable"
	"${dest}/bin/tsc-rs" --version >/dev/null || fail "installed ${TOOL_NAME} ${version} does not run"
	echo "* Installed ${TOOL_NAME} ${version} with ${libs} lib .d.ts files" >&2
}
