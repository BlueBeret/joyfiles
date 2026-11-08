#!/usr/bin/env bash
# packages the exported builds into build/dist/ for direct download
set -euo pipefail

usage() {
	cat <<'EOF'
usage: scripts/package.sh [--version VERSION] [--no-export]

Runs scripts/export.sh, then writes these files to build/dist/:
  joyfiles-VERSION-x86_64.AppImage
  joyfiles-VERSION-windows-x86_64.zip
  SHA256SUMS

--no-export packages the existing build/linux and build/windows output.
The default VERSION is the version in core/Cargo.toml.
The script downloads appimagetool when it is not on the PATH.

environment:
  JF_APPIMAGETOOL   path to an appimagetool binary
EOF
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/joyfiles/appimage"
tool_url="https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage"
tool_sha256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
runtime_url="https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64"
runtime_sha256=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d

version=""
run_export=1
while (($#)); do
	case "$1" in
		--version)
			shift
			version="${1:-}"
			[[ -n "$version" ]] || { echo "error: --version needs a value" >&2; exit 2; }
			;;
		--no-export) run_export=0 ;;
		-h | --help) usage; exit 0 ;;
		*) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

die() {
	echo "error: $*" >&2
	exit 1
}

if [[ -z "$version" ]]; then
	version="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$root/core/Cargo.toml" | head -n 1)"
	[[ -n "$version" ]] || die "cannot read the version from core/Cargo.toml"
fi

work=""
cleanup() {
	if [[ -n "$work" ]]; then
		rm -rf -- "${work:?}"
	fi
}
trap cleanup EXIT

fetch_pinned() {
	local url="$1" sha="$2" dest="$3"
	if [[ -s "$dest" ]] && echo "$sha  $dest" | sha256sum --status -c -; then
		return 0
	fi
	mkdir -p "$(dirname "$dest")"
	curl -fsSL --retry 3 -o "$dest.part" "$url"
	echo "$sha  $dest.part" | sha256sum --status -c - || die "checksum mismatch for $url"
	mv -f "$dest.part" "$dest"
}

find_appimagetool() {
	if [[ -n "${JF_APPIMAGETOOL:-}" ]]; then
		echo "$JF_APPIMAGETOOL"
	elif command -v appimagetool >/dev/null; then
		command -v appimagetool
	else
		fetch_pinned "$tool_url" "$tool_sha256" "$cache_dir/appimagetool-x86_64.AppImage"
		chmod +x "$cache_dir/appimagetool-x86_64.AppImage"
		echo "$cache_dir/appimagetool-x86_64.AppImage"
	fi
}

package_linux() {
	local appdir="$work/AppDir" tool
	mkdir -p "$appdir/usr/bin"
	install -m 755 "$root/build/linux/joyfiles.x86_64" "$appdir/usr/bin/joyfiles.x86_64"
	install -m 755 "$root/build/linux/libjoyfiles_core.so" "$appdir/usr/bin/libjoyfiles_core.so"
	install -m 755 "$root/packaging/linux/AppRun" "$appdir/AppRun"
	install -m 644 "$root/packaging/linux/joyfiles.desktop" "$appdir/joyfiles.desktop"
	install -m 644 "$root/packaging/linux/joyfiles.svg" "$appdir/joyfiles.svg"

	tool="$(find_appimagetool)"
	fetch_pinned "$runtime_url" "$runtime_sha256" "$cache_dir/runtime-x86_64"
	ARCH=x86_64 "$tool" --appimage-extract-and-run --runtime-file "$cache_dir/runtime-x86_64" \
		"$appdir" "$dist/joyfiles-$version-x86_64.AppImage"
}

package_windows() {
	local stage="$work/windows/joyfiles"
	mkdir -p "$stage"
	install -m 755 "$root/build/windows/joyfiles.exe" "$stage/joyfiles.exe"
	install -m 755 "$root/build/windows/joyfiles_core.dll" "$stage/joyfiles_core.dll"
	install -m 644 "$root/LICENSE" "$stage/LICENSE"
	(cd "$work/windows" && zip -q -r -X "$dist/joyfiles-$version-windows-x86_64.zip" joyfiles)
}

if ((run_export)); then
	"$root/scripts/export.sh" all
fi

for f in build/linux/joyfiles.x86_64 build/linux/libjoyfiles_core.so build/windows/joyfiles.exe build/windows/joyfiles_core.dll; do
	[[ -s "$root/$f" ]] || die "$f is missing, run scripts/export.sh first"
done

dist="$root/build/dist"
rm -rf -- "${dist:?}"
mkdir -p "$dist"
work="$(mktemp -d)"

package_linux
package_windows
(cd "$dist" && sha256sum -- * >SHA256SUMS)
ls -l "$dist"
