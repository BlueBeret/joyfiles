#!/usr/bin/env bash
# builds the release libraries and exports the Godot presets into build/
set -euo pipefail

usage() {
	cat <<'EOF'
usage: scripts/export.sh [linux|windows|all]

Builds the release libraries, then exports the matching Godot presets
to build/linux and build/windows. The default target is all.
The script downloads the Godot export templates when they are missing.

environment:
  GODOT              godot binary (default godot)
  JF_GODOT_VERSION   godot and template version (default 4.7.2)
  JF_JOBS            cargo job count (default 2)
EOF
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot_bin="${GODOT:-godot}"
version="${JF_GODOT_VERSION:-4.7.2}"
templates_dir="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$version.stable"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/joyfiles"

declare -A preset=([linux]=Linux [windows]=Windows)
declare -A template=([linux]=linux_release.x86_64 [windows]=windows_release_x86_64.exe)
declare -A binary=([linux]=build/linux/joyfiles.x86_64 [windows]=build/windows/joyfiles.exe)
declare -A extension_lib=([linux]=build/linux/libjoyfiles_core.so [windows]=build/windows/joyfiles_core.dll)

case "${1:-all}" in
	linux) targets=(linux) ;;
	windows) targets=(windows) ;;
	all) targets=(linux windows) ;;
	-h | --help) usage; exit 0 ;;
	*) echo "error: unknown target: $1" >&2; usage >&2; exit 2 ;;
esac

work=""
cleanup() {
	if [[ -n "$work" ]]; then
		rm -rf -- "${work:?}"
	fi
}
trap cleanup EXIT

die() {
	echo "error: $*" >&2
	exit 1
}

check_godot_version() {
	local actual
	actual="$("$godot_bin" --version)" || die "cannot run $godot_bin"
	[[ "$actual" == "$version".stable* ]] || die "$godot_bin is $actual, the export templates need $version.stable"
}

templates_present() {
	local f
	for f in version.txt "${template[@]}"; do
		[[ -s "$templates_dir/$f" ]] || return 1
	done
}

ensure_templates() {
	templates_present && return 0

	local base="https://github.com/godotengine/godot/releases/download/$version-stable"
	local tpz="Godot_v$version-stable_export_templates.tpz"
	mkdir -p "$cache_dir" "$templates_dir"
	work="$(mktemp -d "$cache_dir/work.XXXXXX")"

	curl -fsSL --retry 3 -o "$work/SHA512-SUMS.txt" "$base/SHA512-SUMS.txt"
	awk -v f="$tpz" '$2 == f' "$work/SHA512-SUMS.txt" >"$work/tpz.sum"
	[[ -s "$work/tpz.sum" ]] || die "no checksum for $tpz in SHA512-SUMS.txt"

	if [[ ! -s "$cache_dir/$tpz" ]] || ! (cd "$cache_dir" && sha512sum --status -c "$work/tpz.sum"); then
		echo "downloading $tpz"
		curl -fL --retry 3 -C - --progress-bar -o "$cache_dir/$tpz.part" "$base/$tpz"
		mv -f "$cache_dir/$tpz.part" "$cache_dir/$tpz"
		(cd "$cache_dir" && sha512sum --status -c "$work/tpz.sum") || die "checksum mismatch for $tpz"
	fi

	echo "installing templates into $templates_dir"
	unzip -q -j -o "$cache_dir/$tpz" 'templates/version.txt' 'templates/linux_*.x86_64' 'templates/windows_*_x86_64*' -d "$work/stage"
	mv -f "$work"/stage/* "$templates_dir/"
	rm -f -- "${cache_dir:?}/${tpz:?}"
	templates_present || die "templates are still missing after install"
}

check_godot_version
for t in "${targets[@]}"; do
	ensure_templates
	"$root/scripts/build.sh" --release --only "$t"
done

"$root/scripts/import.sh"

for t in "${targets[@]}"; do
	mkdir -p "$root/$(dirname "${binary[$t]}")"
	rm -f -- "${root:?}/${binary[$t]:?}"
	nice -n 19 "$godot_bin" --headless --path "$root/app" --export-release "${preset[$t]}"
	for f in "${binary[$t]}" "${extension_lib[$t]}"; do
		[[ -s "$root/$f" ]] || die "export did not produce $f"
	done
	echo "exported $t: ${binary[$t]}"
done
